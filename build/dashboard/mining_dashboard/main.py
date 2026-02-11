import asyncio
import logging
from aiohttp import web

from config.config import PROXY_AUTH_TOKEN, PROXY_HOST, PROXY_API_PORT, MONERO_WALLET_ADDRESS
from service.storage_service import StateManager
from web.server import create_app
from client.xmrig_proxy_client import XMRigProxyClient
from client.xvb_client import XvbClient
from service.data_service import DataService
from service.algo_service import AlgoService

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("Main")

state_manager = StateManager()

# Initialize Proxy Client
proxy_client = XMRigProxyClient(host=PROXY_HOST, port=PROXY_API_PORT, access_token=PROXY_AUTH_TOKEN)

# Initialize XvB Client
xvb_client = XvbClient(wallet_address=MONERO_WALLET_ADDRESS)

# Initialize Services
data_service = DataService(state_manager, proxy_client, xvb_client)
algo_service = AlgoService(state_manager, proxy_client, data_service)


async def start_background_tasks(app):
    """Initializes background services upon web application startup."""
    app['data_task'] = asyncio.create_task(data_service.run())
    app['algo_task'] = asyncio.create_task(algo_service.run())

if __name__ == "__main__":
    app = create_app(state_manager, data_service.latest_data)
    app.on_startup.append(start_background_tasks)
    logger.info("Initializing Dashboard Web Server on Port 8000")
    web.run_app(app, port=8000, print=None)