import ipaddress
import logging

from mining_dashboard.config.config import (
    XMRIG_API_PORT,
    PROXY_API_PORT,
    PROXY_AUTH_TOKEN,
    API_TIMEOUT,
    MINING_NET_CIDR,
)

# Longest worker-name we'll ever echo back as a Bearer token (#122). xmrig names/tokens are short;
# this just bounds a pathological miner-supplied value before it goes into a header.
_MAX_NAME_TOKEN = 128

try:
    _INTERNAL_NET = ipaddress.ip_network(MINING_NET_CIDR, strict=False)
except ValueError:
    _INTERNAL_NET = ipaddress.ip_network("172.28.0.0/16")


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


class XMRigWorkerClient:
    def __init__(self, session):
        """
        Initialize the XMRig Worker Client.
        :param session: An active aiohttp.ClientSession.
        """
        self.session = session
        self.logger = logging.getLogger("WorkerClient")

    async def get_stats(self, ip, name):
        """
        Fetch /1/summary from a worker. Works for both XMRig miners and upstream
        XMRig Proxy instances, trying the most likely credential first:

          1. No auth on XMRIG_API_PORT      — open xmrig-proxy (restricted=true, no token)
          2. PROXY_AUTH_TOKEN on PROXY_API_PORT — secured proxy on a non-standard port
          3. Name-derived token on XMRIG_API_PORT — direct XMRig miner (name = access token)

        Callers use the returned 'kind' field ('proxy' vs 'miner') to handle any
        unit differences (xmrig-proxy reports hashrate in kH/s; miner reports H/s).

        Only the worker's validated IP is ever used as the request host (SSRF guard, #122): a
        miner-controlled worker *name* is never a host, it's only offered back to that same IP as
        the "name = access token" Bearer for direct XMRig miners.
        """
        host = _safe_probe_host(ip)
        if host is None:
            # No safe target: ip is missing/internal/not a bare address. Never fall back to the
            # miner-controlled name as a host — that is the SSRF this guard exists to prevent (#122).
            return {}

        name_token = name.split("+")[0].strip()[:_MAX_NAME_TOKEN] if name else ""

        attempts = [
            # 1. Open proxy — no auth header at all
            (f"http://{host}:{XMRIG_API_PORT}/1/summary", {}),
        ]
        # 2. Secured proxy on a custom port (only if distinct from XMRIG_API_PORT)
        if PROXY_AUTH_TOKEN and PROXY_API_PORT != XMRIG_API_PORT:
            attempts.append(
                (
                    f"http://{host}:{PROXY_API_PORT}/1/summary",
                    {"Authorization": f"Bearer {PROXY_AUTH_TOKEN}"},
                )
            )
        # 3. Direct XMRig miner: the name doubles as the access token, sent only to its own IP.
        if name_token:
            attempts.append(
                (
                    f"http://{host}:{XMRIG_API_PORT}/1/summary",
                    {"Authorization": f"Bearer {name_token}"},
                )
            )

        for url, headers in attempts:
            try:
                async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                    if response.status == 200:
                        return await response.json()
            except Exception as e:
                self.logger.debug(f"Worker API Error ({url}): {e}")

        return {}
