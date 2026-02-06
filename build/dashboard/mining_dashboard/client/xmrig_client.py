import logging
from config.config import XMRIG_API_PORT, API_TIMEOUT

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
        Fetch stats from a worker using its IP and Name (for Auth).
        """
        # Derive auth token from worker name (e.g., "hostname+diff" -> "hostname")
        token = name.split('+')[0].strip()
        headers = {"Authorization": f"Bearer {token}"}
        
        # Try connecting via IP, then Hostname, then Hostname.local
        targets = []
        if ip and ip != "0.0.0.0":
            targets.append(ip)
        if token:
            targets.append(token)
            targets.append(f"{token}.local")

        for target in targets:
            url = f"http://{target}:{XMRIG_API_PORT}/1/summary"
            try:
                async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                    if response.status == 200:
                        return await response.json()
            except Exception as e:
                self.logger.debug(f"Worker API Error ({target}): {e}")
        
        return {}