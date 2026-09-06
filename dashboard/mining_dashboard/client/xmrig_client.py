import ipaddress
import json
import logging
import time

from mining_dashboard.client.rig_config_meta import parse_config_meta
from mining_dashboard.config.config import (
    API_TIMEOUT,
    DASHBOARD_WORKERS,
    MINING_NET_CIDR,
    XMRIG_API_AUTH,
    XMRIG_API_PORT,
    XMRIG_API_TOKEN,
)

# The writable-key allowlist lives with the WRITE path (control_service) and is imported here
# rather than restated: a second literal would be a third copy of the same list, and the existing
# drift guard only compares the dashboard's copy against pithead's. control_service imports only
# `config`, so this does not close an import cycle. SECRET_SENTINEL is the same reuse: one literal
# shape for "masked" shared by the host-config path and this one (#1548).
from mining_dashboard.helper.http import ResponseTooLarge, bounded_read
from mining_dashboard.service.control_service import SECRET_SENTINEL, WORKER_WRITABLE_KEYS

# Per-worker endpoint descriptors (#172): the validated workers.list[] list from config.json.
# Module-level (not from-import at call sites) so tests can swap it per case. Fleets are small, so
# the per-poll lookups below are linear scans — no index to keep in sync.
WORKER_ENDPOINTS = DASHBOARD_WORKERS

# Longest worker-name we'll ever echo back as a Bearer token (#122). xmrig names/tokens are short;
# this just bounds a pathological miner-supplied value before it goes into a header.
_MAX_NAME_TOKEN = 128

# Ceiling on one rig's /1/summary. The poll pulls a device's response straight into the
# dashboard's memory, and since #1235 part of it is forwarded on to the operator's browser;
# nothing else bounds it, so aiohttp would buffer whatever the far end chose to send.
#
# Measured, not guessed — JSON-serialized /1/summary at real rig shapes, RigForge block included:
# ~2.8 KiB for an 8-thread rig, 3.6 KiB for a 32-thread workstation, 8.0 KiB for a 192-thread
# EPYC, and 16.0 KiB for an absurd-but-legitimate 512 threads with 8 pools. The term that actually
# scales is hashrate.threads — one row per mining thread. 1 MiB is ~64x that absurd case, so the
# cap cannot plausibly be reached by a rig telling the truth, which is the failure that would
# matter: a cap set tight enough to bite a real operator is worse than the exhaustion it prevents.
_MAX_SUMMARY_BYTES = 1024 * 1024

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

    ``config`` is the rig's EFFECTIVE writable config (rigforge#253, shipped in RigForge v1.10.0),
    riding this same poll. It is what the Worker Inspect editor prefills from (#1235): the rig's
    own current values, rather than Pithead's record of what it last pushed — which is empty on a
    never-edited rig and stale on one changed directly with ``rigforge.sh apply``. A rig older than
    v1.10.0 sends no ``config`` and this stays ``None``, so the editor falls back to the record.
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
        "config": _rig_writable_config(rf.get("config")),
        "config_meta": parse_config_meta(rf.get("config_meta")),
    }


# Pool keys that are a credential and must never reach the dashboard, let alone an editor box that
# can POST them back. RigForge already deletes both before serving the block (its read is
# token-OPTIONAL, so it masks at the source), but this is the same defence-in-depth posture
# ``mask_secrets`` takes with the host config: the rig is remote, and a rig running an older or
# patched build is exactly the case a single mask would miss.
_POOL_CREDENTIAL_KEYS = ("pass", "tls-fingerprint")

# How deep the strip below will walk before it stops trusting the value. A real writable config is
# three deep at most (pools -> a pool -> its fields); anything past this is not a config we can
# read, and refusing it also keeps a hostile rig from driving the recursion down our own stack.
_MAX_CONFIG_DEPTH = 6


_DROP = object()  # sentinel meaning "leave this key out entirely" -- see _walk_pool_credentials


def _walk_pool_credentials(value, leaf, depth=0):
    """Recurse ``value`` at ANY depth and in ANY container shape, applying ``leaf`` to whatever
    sits behind a credential key (``leaf`` returns ``_DROP`` to omit the key outright).

    Shape-agnostic deliberately. Walking only ``pools`` when it arrived as a list of dicts was a
    filter that assumed the shape of the very input it was defending against: a rig serving
    ``pools`` as a dict, or nesting the credential one level deeper, walked straight past it with
    the credential intact. A hostile or patched rig picks its own response shape, so the only
    assumption safe to make here is none. Shared core for the two passes below -- what happens to
    a credential value differs between them; the shape-agnostic walk itself must not.
    """
    if depth > _MAX_CONFIG_DEPTH:
        return None
    if isinstance(value, dict):
        out = {}
        for k, v in value.items():
            if k in _POOL_CREDENTIAL_KEYS:
                replacement = leaf(v)
                if replacement is not _DROP:
                    out[k] = replacement
            else:
                out[k] = _walk_pool_credentials(v, leaf, depth + 1)
        return out
    if isinstance(value, list):
        return [_walk_pool_credentials(v, leaf, depth + 1) for v in value]
    return value


def strip_credentials(value, depth=0):
    """Drop the credential keys from ``value`` at ANY depth and in ANY container shape.

    Used for surfaces that never round-trip back into an editable form -- the change-history
    store and the worker-detail page -- so there is nothing a placeholder would need to preserve
    a slot for; dropping the key is simplest and safest.
    """
    return _walk_pool_credentials(value, lambda v: _DROP, depth)


def mask_pool_credentials(value, depth=0):
    """Replace a SET credential leaf with ``SECRET_SENTINEL`` at ANY depth/shape; leave an
    empty/falsy one alone (mirrors ``control_service.mask_secrets`` -- "not set" must stay
    distinguishable from "set but hidden"). Used for the round-trip EDITABLE prefill (#1548):
    ``strip_credentials`` used to run here too, but deleting the key outright gives the Worker
    Inspect editor nothing to recognise as a secret, so an Apply that never touched the credential
    still sent a pool entry with no password -- wiping it. Masking extends the same blank-keeps-it
    contract the Configuration view already has for a top-level secret down to one nested inside
    ``pools`` -- once the rig actually serves ``pass``; a stock feed never does (rigforge#415).
    """
    return _walk_pool_credentials(value, lambda v: dict(SECRET_SENTINEL) if v else v, depth)


def _is_secret_sentinel(v):
    """Structural check mirroring ``configlogic.isSecretSentinel`` -- a marker, not a value the
    dashboard ever wrote."""
    return isinstance(v, dict) and v.get("__secret__") is True


def strip_sentinel_credentials(value, depth=0):
    """Drop a pool-credential key wherever its incoming value is literally ``SECRET_SENTINEL``,
    leaving a real typed value untouched. Server-side backstop for a worker-apply request (#1548):
    the browser is expected to have already scrubbed a leftover sentinel out of what it sends
    (``workerlogic.mjs``'s ``stripNestedSecrets``), but this dashboard never held a real value to
    substitute back in for one -- unlike the host config's top-level secrets, which the HOST swaps
    for their live value on commit (#440), nothing here retains a pool password to swap in. So a
    sentinel that reaches this point has no honest destination but the one ``mask_pool_credentials``
    already gives every OTHER untouched credential: absent from what gets sent, never forwarded to
    the rig as if it were a real password. This is what keeps ``mask_pool_credentials`` safe to use
    for the editable prefill at all -- without it, a client bug, a stale cached page, or a hand-built
    request could write the literal marker over the rig's real credential.
    """
    return _walk_pool_credentials(value, lambda v: _DROP if _is_secret_sentinel(v) else v, depth)


def _rig_writable_config(cfg):
    """The rig's own values for the writable keys, filtered to the keys we would ever write (#1235).

    Filtered rather than passed through: this is remote-supplied data that prefills an editor whose
    contents can be POSTed straight back at the rig. Anything outside ``WORKER_WRITABLE_KEYS`` would
    be a key the apply path rejects anyway, so carrying it can only mislead the operator or widen
    what a compromised rig can put in front of them. Returns ``None`` when the rig sent nothing
    usable, which the UI must render as "could not read" rather than as an empty value.
    """
    if not isinstance(cfg, dict):
        return None
    out = {k: v for k, v in cfg.items() if k in WORKER_WRITABLE_KEYS}
    return mask_pool_credentials(out) or None


# Terminal control outcomes the rig may mirror: applied/rejected/rolled_back/failed from a
# control-apply (pithead control_worker_apply / rigforge#236), plus noop/throttled from a
# control-upgrade (rigforge#320, v1.12.0). "started" (rigforge#320's in-flight upgrade marker) and
# "accepted"/"running" (this dashboard's own still-polling placeholders) are non-terminal — never
# reconciled from a read poll, only ever written while a change is still in flight. Mirrors
# pithead's own control_worker_apply/control_worker_upgrade poll cases (#1001) so the mirror-side
# and poll-side vocabularies can't drift apart again.
_CONTROL_TERMINAL = ("applied", "rejected", "rolled_back", "failed", "noop", "throttled")


def parse_worker_control_status(payload):
    """The rig's last control-apply/control-upgrade outcome, mirrored read-only into the SAME
    enriched feed body under ``rigforge.control`` (#579, rigforge#346) — no new port, no token, it
    rides the poll that already fetches the ``rigforge`` block for :func:`parse_rigforge`.

    The host runner's synchronous ``/status`` poll after a worker-apply is capped at 20s
    (rigforge#236's auto-rollback can take minutes); a change still mid-flight past that deadline
    is honestly recorded ``accepted`` and nothing re-polls it. Rather than a new authenticated dial
    to the rig's control port (the dashboard container never holds that token), a RigForge rig
    mirrors its own last outcome into the already-open, unauthenticated read feed so the next
    routine poll can catch up.

    Returns ``{"change_id", "status", "reason"}`` only for a TERMINAL outcome: applied / rejected /
    rolled_back / failed (rigforge#236), or noop (already on the target)/throttled (the rig's own
    anti-beacon window — retry-later, not a fault) from rigforge#320. Returns ``None`` for a
    still-in-flight change (``started``/``accepted``/``running``), a malformed block, or a rig that
    doesn't mirror this yet (older RigForge, plain xmrig) — so a #185 history row is never
    force-terminaled on bad or absent data.
    """
    rf = payload.get("rigforge") if isinstance(payload, dict) else None
    ctrl = rf.get("control") if isinstance(rf, dict) else None
    if not isinstance(ctrl, dict):
        return None
    change_id, status = ctrl.get("change_id"), ctrl.get("status")
    if not isinstance(change_id, str) or not change_id or status not in _CONTROL_TERMINAL:
        return None
    return {"change_id": change_id, "status": status, "reason": ctrl.get("reason")}


def _safe_probe_host(ip) -> str | None:
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
    """The workers.list[] entry for this worker, or None (#506).

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
        fails, we return ``{"api_ok": False, "adopted": bool}`` and log a single (rate-limited)
        WARNING with a fix hint, rather than silently trying alternatives or swallowing the error.
        ``adopted`` — does the descriptor we resolved carry a control token — lets the row read
        "not adopted" rather than blame config (#1857); it rides the success payload too.

        Per-worker overrides (#506, ``workers.list[]``) merge on top: per-worker field >
        fleet default > inherit. An operator-set ``host`` replaces the connecting IP as the probe
        target; a per-worker ``token`` becomes the Bearer for that worker only.

        Only two things are ever used as the request host (SSRF guard, #122): the worker's
        validated IP, or a host the OPERATOR wrote into config.json. A miner-controlled worker
        *name* is never a host — in ``name`` auth it is only offered back as the Bearer token —
        and a per-worker token is never sent anywhere a miner-advertised value could point it.
        """
        name_token = name.split("+")[0].strip()[:_MAX_NAME_TOKEN] if name else ""
        safe_ip = _safe_probe_host(ip)
        override = _worker_override(name_token, safe_ip) or {}
        # Adoption (#1836/#1857): decided HERE so it reuses the probe's own name-then-host
        # descriptor match — a name-only lookup downstream would miss a `+suffix` stratum name.
        # It rides BOTH verdicts, so the field cannot contradict itself between two polls.
        adopted = bool(override.get("token"))
        if "host" in override:
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

        port = override.get("port", XMRIG_API_PORT)
        url = f"http://{host}:{port}/1/summary"
        headers = self._auth_header(name_token, override.get("token", ""))

        try:
            async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                if response.status == 200:
                    # The bounded async read was worked out here (#1347) and lifted into
                    # ``bounded_read`` by #1360 — one contract, one implementation; the
                    # ``bytearray``/short-read rationale lives in ``helper/http.py``. Overflow is a
                    # refusal for THIS rig only, never an exception that takes the poll down for
                    # every other worker, so it is caught here, not by the blanket handler below.
                    try:
                        body = await bounded_read(
                            response.content,
                            max_bytes=_MAX_SUMMARY_BYTES,
                            what=f"{name} summary",
                        )
                    except ResponseTooLarge:
                        self._warn(host, name, url, f"body over {_MAX_SUMMARY_BYTES} bytes")
                        return {"api_ok": False, "adopted": adopted}
                    payload = json.loads(body)
                    if isinstance(payload, dict):
                        self._warned.pop(host, None)  # recovered — allow the next failure to log
                        payload["api_ok"], payload["adopted"] = True, adopted
                        return payload
                    self._warn(host, name, url, f"HTTP 200 but body was {type(payload).__name__}")
                    return {"api_ok": False, "adopted": adopted}
                self._warn(host, name, url, f"HTTP {response.status}")
                return {"api_ok": False, "adopted": adopted}
        except Exception as e:
            self._warn(host, name, url, f"{type(e).__name__}: {e}")
            return {"api_ok": False, "adopted": adopted}
