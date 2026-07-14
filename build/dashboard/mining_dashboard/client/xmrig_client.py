import ipaddress
import logging
import time

from mining_dashboard.config.config import (
    API_TIMEOUT,
    DASHBOARD_WORKERS,
    MINING_NET_CIDR,
    XMRIG_API_AUTH,
    XMRIG_API_PORT,
    XMRIG_API_TOKEN,
)

# Per-worker endpoint descriptors (#172): the validated dashboard.workers[] list from config.json.
# Module-level (not from-import at call sites) so tests can swap it per case. Fleets are small, so
# the per-poll lookups below are linear scans — no index to keep in sync.
WORKER_ENDPOINTS = DASHBOARD_WORKERS

# Longest worker-name we'll ever echo back as a Bearer token (#122). xmrig names/tokens are short;
# this just bounds a pathological miner-supplied value before it goes into a header.
_MAX_NAME_TOKEN = 128

# Re-warn about a worker whose API keeps failing at most this often, so a misconfigured fleet logs
# one line per worker per interval — not one per poll (the data loop runs every ~30s).
_WARN_INTERVAL_S = 300

try:
    _INTERNAL_NET = ipaddress.ip_network(MINING_NET_CIDR, strict=False)
except ValueError:
    _INTERNAL_NET = ipaddress.ip_network("172.28.0.0/16")


def parse_rigforge(payload):
    """Normalize the optional ``rigforge`` block off a worker ``/1/summary`` (#235).

    A RigForge rig serves an ENRICHED feed on its ``api_port`` (default 8081): the whole XMRig
    ``/1/summary`` object unchanged, plus one added ``rigforge`` key (rigforge#99). Point the rig's
    descriptor ``port`` at that feed and the block rides in on the existing poll — no new read path.
    A plain-xmrig rig has no ``rigforge`` key, so this returns ``None`` and the UI renders it exactly
    as before (backward compatible).

    Every enriched field is nullable on the wire — no RAPL / non-root → ``power.watts`` null, no
    governor read → ``governor`` null — so each access is defaulted. A present-but-miner-down rig
    (``xmrig_api == "unreachable"``, XMRig keys absent) is flagged via ``miner_down`` so the UI can
    show it as up-but-miner-down rather than offline. Returns a compact dict for the UI, or ``None``.
    """
    rf = payload.get("rigforge") if isinstance(payload, dict) else None
    if not isinstance(rf, dict):
        return None
    tune = rf.get("tune") or {}
    autotune = tune.get("autotune") or {}
    power = rf.get("power") or {}
    health = rf.get("health") or {}
    firmware = health.get("firmware") or {}
    watchdog = rf.get("watchdog") or {}
    wd_on = watchdog.get("mode") == "enabled"
    return {
        "version": rf.get("version"),
        "miner_down": rf.get("xmrig_api") == "unreachable",
        "power": {"watts": power.get("watts"), "hs_per_watt": power.get("hs_per_watt")},
        "tune": {
            "target": tune.get("target"),
            "autotune_enabled": bool(autotune.get("enabled")),
            "autotune_next": autotune.get("next"),
        },
        "health": {
            "governor": health.get("governor"),
            "throttling": health.get("throttling"),
            "board": firmware.get("board"),
            "hugepages_total": health.get("hugepages_total"),
        },
        # thermal_hold/temps are only meaningful while the watchdog is enabled.
        "watchdog": {
            "enabled": wd_on,
            "thermal_hold": watchdog.get("thermal_hold") if wd_on else None,
            "temp_c": watchdog.get("temp_c") if wd_on else None,
            "max_temp_c": watchdog.get("max_temp_c") if wd_on else None,
        },
    }


def _safe_probe_host(ip):
    """Return a safe host string to probe, or None.

    SSRF guard (#122): the dashboard runs ``network_mode: host`` and a connecting miner fully
    controls its worker name/ip via stratum, so the per-worker stats fetch must only ever issue an
    outbound request at a *real, external miner address* — never at a name-as-host or at our own
    infrastructure. We therefore require a bare IP (a worker *name* can never become a request
    host) and reject loopback, link-local (cloud metadata), multicast, unspecified, reserved, and
    the stack's internal docker bridge (the socket proxies, Tor, monerod). LAN/public miner IPs are
    allowed — miners commonly connect from the LAN.
    """
    if not ip or ip == "0.0.0.0":
        return None
    host = str(ip).strip()
    # Tolerate an "ip:port" form (IPv4) that the proxy/stratum occasionally report.
    if host.count(":") == 1:
        head, _, tail = host.rpartition(":")
        if tail.isdigit():
            host = head
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return None  # not a bare IP — never treat a worker name/hostname as a request host
    if (
        addr.is_loopback
        or addr.is_link_local
        or addr.is_multicast
        or addr.is_unspecified
        or addr.is_reserved
    ):
        return None
    if addr.version == _INTERNAL_NET.version and addr in _INTERNAL_NET:
        return None
    return host


def _worker_override(name_token, safe_ip):
    """The dashboard.workers[] entry for this worker, or None (#172).

    Matched by the rig's stratum name first; on a name miss, by the validated connecting IP
    against an operator-set ``host`` (covers a renamed rig that still connects from its declared
    address). config.py already enforces unique names (first-declared wins), so the first list
    hit is the match.
    """
    for entry in WORKER_ENDPOINTS:
        if entry["name"] == name_token:
            return entry
    if safe_ip:
        for entry in WORKER_ENDPOINTS:
            if entry.get("host") == safe_ip:
                return entry
    return None


class XMRigWorkerClient:
    def __init__(self, session):
        """
        Initialize the XMRig Worker Client.
        :param session: An active aiohttp.ClientSession.
        """
        self.session = session
        self.logger = logging.getLogger("WorkerClient")
        # host -> monotonic timestamp of the last failure we logged, so a persistently-broken
        # worker doesn't spam a WARNING every poll. The client outlives the poll loop, so this
        # state survives across iterations.
        self._warned = {}

    def _auth_header(self, name_token, override_token=""):
        """Build the single Authorization header for the configured auth mode (or no header).

        A per-worker token (#172) implies token-auth for that worker only, whatever the
        fleet-wide mode says.
        """
        # Only a real STRING token overrides the fleet auth. The container reads the MASKED config
        # (#440), where a per-worker token is the {"__secret__": true} sentinel — it means "a token
        # exists but the container doesn't hold it", so fall through to the fleet auth mode (e.g. name)
        # for the read probe. The host-side runner still uses the real token for control (#508/#440).
        if isinstance(override_token, str) and override_token:
            return {"Authorization": f"Bearer {override_token}"}
        mode = XMRIG_API_AUTH
        if mode == "name":
            return {"Authorization": f"Bearer {name_token}"} if name_token else {}
        if mode == "token":
            return {"Authorization": f"Bearer {XMRIG_API_TOKEN}"} if XMRIG_API_TOKEN else {}
        # "none" (default) and any unrecognized value -> open, unauthenticated API
        return {}

    def _fix_hint(self):
        """A short, actionable remedy tailored to the configured auth mode."""
        mode = XMRIG_API_AUTH
        if mode == "name":
            return (
                "expected the miner's xmrig access-token to equal its stratum name; verify that, "
                f"or that the API is on XMRIG_API_PORT ({XMRIG_API_PORT})"
            )
        if mode == "token":
            return (
                "expected XMRIG_API_TOKEN to match the miner's xmrig access-token; verify that, "
                f"or that the API is on XMRIG_API_PORT ({XMRIG_API_PORT})"
            )
        return (
            "expected an open (http.restricted, no access-token) miner API; if this miner sets an "
            "access-token, set XMRIG_API_AUTH=name (or =token with XMRIG_API_TOKEN), or check "
            f"XMRIG_API_PORT ({XMRIG_API_PORT})"
        )

    def _warn(self, host, name, url, detail):
        now = time.monotonic()
        if now - self._warned.get(host, float("-inf")) < _WARN_INTERVAL_S:
            return
        self._warned[host] = now
        self.logger.warning(
            "Worker %r (%s): xmrig API probe failed at %s — %s. %s.",
            name,
            host,
            url,
            detail,
            self._fix_hint(),
        )

    async def get_stats(self, ip, name):
        """
        Fetch /1/summary from a worker's xmrig API — exactly ONE way, derived from config.

        The auth method is chosen by ``XMRIG_API_AUTH`` (``none`` default / ``name`` / ``token``);
        the port by ``XMRIG_API_PORT``. There is no auto-detection fallback: if the configured probe
        fails, we return ``{"api_ok": False}`` and log a single (rate-limited) WARNING with a fix
        hint, rather than silently trying alternatives or swallowing the error. On success the parsed
        summary is returned with ``api_ok`` set to ``True``.

        Per-worker overrides (#172, ``dashboard.workers[]``) merge on top: per-worker field >
        fleet default > inherit. An operator-set ``host`` replaces the connecting IP as the probe
        target; a per-worker ``token`` becomes the Bearer for that worker only.

        Only two things are ever used as the request host (SSRF guard, #122): the worker's
        validated IP, or a host the OPERATOR wrote into config.json. A miner-controlled worker
        *name* is never a host — in ``name`` auth it is only offered back as the Bearer token —
        and a per-worker token is never sent anywhere a miner-advertised value could point it.
        """
        name_token = name.split("+")[0].strip()[:_MAX_NAME_TOKEN] if name else ""
        safe_ip = _safe_probe_host(ip)
        override = _worker_override(name_token, safe_ip)
        if override and "host" in override:
            # Operator-set in config.json — never miner-advertised (#122). Pinning the host also
            # means an imposter claiming this rig's name can't pull the rig's token to its own
            # address; docs recommend host+token together for exactly that reason.
            host = override["host"]
        elif safe_ip:
            host = safe_ip
        else:
            # No safe target: ip is missing/internal/not a bare address, and no operator-set host.
            # This isn't a misconfigured miner — it's a worker we deliberately won't probe — so
            # stay quiet and leave api_ok unset (unknown) rather than flagging a failure. Never
            # fall back to the miner-controlled name as a host: that is the SSRF this guard exists
            # to prevent (#122).
            return {}

        port = override.get("port", XMRIG_API_PORT) if override else XMRIG_API_PORT
        url = f"http://{host}:{port}/1/summary"
        headers = self._auth_header(name_token, override.get("token", "") if override else "")

        try:
            async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                if response.status == 200:
                    payload = await response.json()
                    if isinstance(payload, dict):
                        self._warned.pop(host, None)  # recovered — allow the next failure to log
                        payload["api_ok"] = True
                        return payload
                    self._warn(host, name, url, f"HTTP 200 but body was {type(payload).__name__}")
                    return {"api_ok": False}
                self._warn(host, name, url, f"HTTP {response.status}")
                return {"api_ok": False}
        except Exception as e:
            self._warn(host, name, url, f"{type(e).__name__}: {e}")
            return {"api_ok": False}
