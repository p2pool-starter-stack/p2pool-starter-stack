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
        url = f"http://{ip}:{XMRIG_API_PORT}/1/summary"
        
        try:
            async with self.session.get(url, headers=headers, timeout=API_TIMEOUT) as response:
                if response.status == 200:
                    return await response.json()
        except Exception as e:
            self.logger.debug(f"Worker API Error ({ip}): {e}")
        
        return {}