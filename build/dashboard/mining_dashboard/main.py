import asyncio
import logging
import time
from aiohttp import web

from config import (
    UPDATE_INTERVAL, 
    XVB_TIME_ALGO_MS, 
    MONERO_WALLET_ADDRESS, 
    XVB_DONOR_ID,
    P2POOL_URL,
    XVB_POOL_URL,
    PROXY_AUTH_TOKEN,
    PROXY_HOST,
    PROXY_API_PORT
)
from storage import StateManager
from algo import XvbAlgorithm
from web.server import create_app
from client.xmrig_proxy_client import XMRigProxyClient
from client.xvb_client import XvbClient
from collectors.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collectors.system import get_disk_usage, get_hugepages_status, get_memory_usage, get_load_average, get_cpu_usage

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("Main")

state_manager = StateManager()
algorithm = XvbAlgorithm(state_manager)

# Initialize Proxy Client
proxy_client = XMRigProxyClient(host=PROXY_HOST, port=PROXY_API_PORT, access_token=PROXY_AUTH_TOKEN)

# Initialize XvB Client
xvb_client = XvbClient(wallet_address=MONERO_WALLET_ADDRESS)

# Global shared state for the latest aggregated metrics
DEFAULT_DATA = {
    "workers": [],
    "total_live_h15": 0,
    "pool": {"p2p": {}, "pool": {}},
    "network": {},
    "system": {},
    "tari": {},
    "stratum": {},
    "timestamp": 0
}

# Attempt to restore state from DB to prevent empty dashboard on restart
loaded_snapshot = state_manager.load_snapshot()
if loaded_snapshot and isinstance(loaded_snapshot, dict):
    LATEST_DATA = {**DEFAULT_DATA, **loaded_snapshot}
else:
    LATEST_DATA = DEFAULT_DATA.copy()


async def switch_miners(mode):
    """
    Configures the upstream pool priority for the XMRig Proxy.
    
    Args:
        mode (str): The target mining mode ("P2POOL" or "XVB").
    """

    # Construct pool configuration based on mode
    # Note: The first pool in the list is the primary.
    if mode == "P2POOL":
        pools = [
            {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": True, "coin": "monero"},
            {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": False, "coin": "monero"}
        ]
    else:
        pools = [
            {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": True, "coin": "monero"},
            {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": False, "coin": "monero"}
        ]

    try:
        # Fetch current full configuration to preserve other settings
        current_config = await asyncio.to_thread(proxy_client.get_config)
        current_config["pools"] = pools

        # Execute update via Proxy Client with the full configuration
        await asyncio.to_thread(proxy_client.update_config, current_config)
        logger.info(f"Switched Proxy to mode: {mode}")
    except Exception as e:
        logger.error(f"Failed to switch proxy mode: {e}")


async def data_collection_loop():
    """
    Periodic task to aggregate statistics from local collectors and external APIs.
    Updates the global LATEST_DATA state and persists historical metrics.
    """
    logger.info("Service Started: Data Collection Loop")
    
    iteration_count = 0 
    
    while True:
        try:
            # 1. Collect Local Statistics (High Frequency)
            stratum_raw, worker_configs = get_stratum_stats()
            
            # Fetch workers from Proxy
            try:
                proxy_data = await asyncio.to_thread(proxy_client.get_workers)
                workers_stats = []
                if proxy_data and "workers" in proxy_data:
                    for w in proxy_data["workers"]:
                        hr = w.get("hashrate", [0, 0, 0])
                        workers_stats.append({
                            "name": w.get("id", "Unknown"),
                            "ip": w.get("ip", "0.0.0.0"),
                            "status": "online",
                            "h10": hr[0] if len(hr) > 0 else 0,
                            "h60": hr[1] if len(hr) > 1 else 0,
                            "h15": hr[2] if len(hr) > 2 else 0,
                            "uptime": w.get("uptime", 0)
                        })
            except Exception as e:
                logger.error(f"Proxy Data Fetch Error: {e}")
                workers_stats = []
            
            # Aggregate 15-minute average hashrate for stable algorithmic input
            total_h15 = sum(w.get('h15', 0) for w in workers_stats if w.get('status') == 'online')
            
            pool_stats = get_p2pool_stats()
            net_stats = get_network_stats()
            sys_stats = {
                "disk": get_disk_usage(),
                "hugepages": get_hugepages_status(),
                "memory": get_memory_usage(),
                "load": get_load_average(),
                "cpu_percent": get_cpu_usage()
            }
            
            LATEST_DATA.update({
                "workers": workers_stats,
                "total_live_h15": total_h15,
                "pool": pool_stats,
                "network": net_stats,
                "tari": get_tari_stats(),
                "system": sys_stats,
                "stratum": stratum_raw,
                "timestamp": time.time()
            })
            
            # 2. Update Historical Data
            # Attribute hashrate to the active mode for visualization
            current_mode = state_manager.get_xvb_stats().get("current_mode", "P2POOL")
            p2pool_hr = 0
            xvb_hr = 0
            if "XVB" in current_mode:
                xvb_hr = total_h15
            else:
                p2pool_hr = total_h15
            
            await asyncio.to_thread(state_manager.update_history, total_h15, p2pool_hr, xvb_hr)

            # Persist the latest snapshot to DB for crash recovery
            await asyncio.to_thread(state_manager.save_snapshot, LATEST_DATA)

            # 3. External API Sync (Throttled: Every 5 minutes / 10 cycles)
            if iteration_count % 10 == 0:
                real_xvb_stats = await asyncio.to_thread(xvb_client.get_stats)
                if real_xvb_stats:
                    await asyncio.to_thread(state_manager.update_xvb_stats,
                        donation_avg_24h=real_xvb_stats["24h_avg"],
                        donation_avg_1h=real_xvb_stats["1h_avg"],
                        fail_count=real_xvb_stats.get("fail_count", 0)
                    )
                    logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['1h_avg']:.0f} H/s | 24h={real_xvb_stats['24h_avg']:.0f} H/s)")
            
            iteration_count += 1
            
        except Exception as e:
            logger.error(f"Data Collection Error: {e}")
            
        await asyncio.sleep(UPDATE_INTERVAL)


async def algo_control_loop():
    """
    Periodic task to execute the mining strategy algorithm.
    Determines the optimal mining mode and manages worker switching cycles.
    """
    logger.info("Service Started: Algorithm Control Loop")
    await asyncio.sleep(5) 
    
    while True:
        try:
            current_hr = LATEST_DATA.get("total_live_h15", 0)
            p2pool_stats = LATEST_DATA.get("pool", {}).get("pool", {}) 
            xvb_stats = state_manager.get_xvb_stats()
            
            # Execute decision logic
            decision, xvb_duration = algorithm.get_decision(current_hr, p2pool_stats, xvb_stats)
            
            if decision == "P2POOL":
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="P2POOL")
                await switch_miners("P2POOL")
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "XVB":
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="XVB")
                await switch_miners("XVB")
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "SPLIT":
                # Split Mode: Allocate time slice to XvB, remainder to P2Pool
                await asyncio.to_thread(state_manager.update_xvb_stats, mode="XVB (Split)")
                await switch_miners("XVB")
                await asyncio.sleep(xvb_duration / 1000)
                
                remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                if remainder > 0:
                    await asyncio.to_thread(state_manager.update_xvb_stats, mode="P2POOL (Split)")
                    await switch_miners("P2POOL")
                    await asyncio.sleep(remainder)

        except Exception as e:
            logger.error(f"Algorithm Error: {e}")
            await asyncio.sleep(10)

async def start_background_tasks(app):
    """Initializes background services upon web application startup."""
    app['data_task'] = asyncio.create_task(data_collection_loop())
    app['algo_task'] = asyncio.create_task(algo_control_loop())

if __name__ == "__main__":
    app = create_app(state_manager, LATEST_DATA)
    app.on_startup.append(start_background_tasks)
    logger.info("Initializing Dashboard Web Server on Port 8000")
    web.run_app(app, port=8000, print=None)