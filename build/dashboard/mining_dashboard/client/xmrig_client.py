import logging
from config.config import XMRIG_API_PORT, PROXY_API_PORT, PROXY_AUTH_TOKEN, API_TIMEOUT

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
        """
        name_token = name.split('+')[0].strip()

        # IP is the most reliable target for remote proxies.
        # Hostname variants are fallbacks for LAN miners with mDNS.
        hosts = []
        if ip and ip != "0.0.0.0":
            hosts.append(ip)
        if name_token:
            hosts.append(name_token)
            hosts.append(f"{name_token}.local")

        attempts = []
        for host in hosts:
            # 1. Open proxy — no auth header at all
            attempts.append((f"http://{host}:{XMRIG_API_PORT}/1/summary", {}))

            # 2. Secured proxy on a custom port (only if distinct from XMRIG_API_PORT)
            if PROXY_AUTH_TOKEN and PROXY_API_PORT != XMRIG_API_PORT:
                attempts.append((
                    f"http://{host}:{PROXY_API_PORT}/1/summary",
                    {"Authorization": f"Bearer {PROXY_AUTH_TOKEN}"}
                ))

            # 3. Direct XMRig miner: name doubles as the access token
            if name_token:
                attempts.append((
                    f"http://{host}:{XMRIG_API_PORT}/1/summary",
                    {"Authorization": f"Bearer {name_token}"}
                ))

        for url, headers in attempts:
            try:
                async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                    if response.status == 200:
                        return await response.json()
            except Exception as e:
                self.logger.debug(f"Worker API Error ({url}): {e}")

        return {}
