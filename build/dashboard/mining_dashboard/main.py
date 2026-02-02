import asyncio
import logging
import time
from aiohttp import web, ClientSession

# --- Import Local Modules ---
# REMOVED XVB_REWARD_URL since it's not used anymore
from config import UPDATE_INTERVAL, HOST_IP, XMRIG_API_PORT, XVB_TIME_ALGO_MS
from storage import StateManager
from algo import XvbAlgorithm
from web.server import create_app

# --- Import Collectors ---
from collectors.miners import get_all_workers_stats
from collectors.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collectors.system import get_disk_usage, get_hugepages_status
# REMOVED: from collectors.xvb import fetch_xvb_tiers  <-- DELETED

# --- Setup Logging ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("Main")

# --- Global Shared Data ---
LATEST_DATA = {
    "workers": [],
    "total_live_h15": 0,
    "pool": {"p2p": {}, "pool": {}},
    "network": {},
    "system": {},
    "tari": {},
    "stratum": {}
}

# --- Initialize Logic ---
state_manager = StateManager()
algorithm = XvbAlgorithm(state_manager)


async def switch_miners(mode, workers):
    """
    Switches pool priority via XMRig API.
    PRIORITY: Hostname -> Hostname.local -> IP
    """
    if not workers: return
    
    p2pool_state = True if mode == "P2POOL" else False
    xvb_state = True if mode == "XVB" else False

    # Only log if we are actually switching modes to reduce spam, 
    # or keep it if you want to see every cycle.
    # logger.info(f"--- SWITCHING {len(workers)} MINERS TO {mode} ---")

    async with ClientSession() as session:
        for w in workers:
            name = w.get('name', '')
            ip = w.get('ip', '')
            
            targets = [
                f"{name}:{XMRIG_API_PORT}",       
                f"{name}.local:{XMRIG_API_PORT}", 
                f"{ip}:{XMRIG_API_PORT}"          
            ]

            payload = {
                "pools": [
                    {"enabled": p2pool_state}, 
                    {"enabled": xvb_state}     
                ]
            }

            switched = False
            for target in targets:
                if target.startswith(":"): continue 

                url = f"http://{target}/1/config"
                
                try:
                    async with session.put(url, json=payload, timeout=2) as resp:
                        if resp.status in [200, 202]:
                            switched = True
                            break 
                except Exception:
                    continue
            
            if not switched:
                logger.warning(f"Failed to switch {name} (Tried: {', '.join(targets)})")


async def data_collection_loop():
    logger.info("Starting Data Collection Loop...")
    while True:
        try:
            stratum_raw, worker_configs = get_stratum_stats()
            workers_stats = await get_all_workers_stats(worker_configs)
            
            total_h15 = sum(w['h15'] for w in workers_stats if w['status'] == 'online')
            
            pool_stats = get_p2pool_stats()
            net_stats = get_network_stats()
            sys_stats = {
                "disk": get_disk_usage(),
                "hugepages": get_hugepages_status()
            }
            
            LATEST_DATA.update({
                "workers": workers_stats,
                "total_live_h15": total_h15,
                "pool": pool_stats,
                "network": net_stats,
                "tari": get_tari_stats(),
                "system": sys_stats,
                "stratum": stratum_raw
            })
            
            state_manager.update_history(total_h15)
            
        except Exception as e:
            logger.error(f"Error in data loop: {e}")
            
        await asyncio.sleep(UPDATE_INTERVAL)


async def algo_control_loop():
    logger.info("Starting Algo Control Loop...")
    await asyncio.sleep(5)
    
    while True:
        try:
            current_hr = LATEST_DATA.get("total_live_h15", 0)
            p2pool_stats = LATEST_DATA.get("pool", {}).get("pool", {}) 
            xvb_stats = state_manager.get_xvb_stats()
            
            decision, xvb_duration = algorithm.get_decision(current_hr, p2pool_stats, xvb_stats)
            workers = LATEST_DATA.get("workers", [])
            
            if decision == "P2POOL":
                state_manager.update_xvb_stats("P2POOL", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("P2POOL", workers)
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "XVB":
                state_manager.update_xvb_stats("XVB", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("XVB", workers)
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "SPLIT":
                state_manager.update_xvb_stats("XVB (Split)", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("XVB", workers)
                await asyncio.sleep(xvb_duration / 1000)
                
                remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                if remainder > 0:
                    state_manager.update_xvb_stats("P2POOL (Split)", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                    await switch_miners("P2POOL", workers)
                    await asyncio.sleep(remainder)

        except Exception as e:
            logger.error(f"Error in algo loop: {e}")
            await asyncio.sleep(10)

async def start_background_tasks(app):
    app['data_task'] = asyncio.create_task(data_collection_loop())
    app['algo_task'] = asyncio.create_task(algo_control_loop())
    # REMOVED app['tier_task']

if __name__ == "__main__":
    app = create_app(state_manager, LATEST_DATA)
    app.on_startup.append(start_background_tasks)
    logger.info(f"Starting Mining Dashboard on port 8080")
    web.run_app(app, port=8000, print=None)