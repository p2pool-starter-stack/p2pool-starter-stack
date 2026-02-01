import asyncio
import logging
import time
from aiohttp import web, ClientSession

# --- Import Local Modules ---
from config import UPDATE_INTERVAL, HOST_IP, XMRIG_API_PORT, XVB_TIME_ALGO_MS
from storage import StateManager
from algo import XvbAlgorithm
from web.server import create_app

# --- Import Collectors ---
from collectors.miners import get_all_workers_stats
from collectors.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collectors.system import get_disk_usage, get_hugepages_status
from collectors.xvb import fetch_xvb_tiers

# --- Setup Logging ---
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("Main")

# --- Global Shared Data ---
# This dictionary is updated by the Data Loop and read by the Web Server
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
    
    # Define state based on target mode
    # P2POOL: Pool 0=True, Pool 1=False
    # XVB:    Pool 0=False, Pool 1=True
    p2pool_state = True if mode == "P2POOL" else False
    xvb_state = True if mode == "XVB" else False

    logger.info(f"--- SWITCHING {len(workers)} MINERS TO {mode} ---")

    async with ClientSession() as session:
        for w in workers:
            name = w.get('name', '')
            ip = w.get('ip', '')
            
            # 1. Define targets in order of reliability/preference
            targets = [
                f"{name}:{XMRIG_API_PORT}",       # Hostname (Fastest)
                f"{name}.local:{XMRIG_API_PORT}", # mDNS (Best for dynamic IPs)
                f"{ip}:{XMRIG_API_PORT}"          # IP (Fallback)
            ]

            # 2. Define the payload
            payload = {
                "pools": [
                    {"enabled": p2pool_state}, # Index 0
                    {"enabled": xvb_state}     # Index 1
                ]
            }

            # 3. Try each target until one works
            switched = False
            for target in targets:
                # Skip if name was empty and resulted in ":8080"
                if target.startswith(":"): continue 

                url = f"http://{target}/1/config"
                
                try:
                    # Short timeout (2s) so we don't hang if a hostname is unresolvable
                    async with session.put(url, json=payload, timeout=2) as resp:
                        if resp.status in [200, 202]:
                            logger.debug(f"Switched {name} via {target}")
                            switched = True
                            break # Success! Stop trying other addresses for this miner
                except Exception:
                    # If this target failed, silently try the next one
                    continue
            
            if not switched:
                logger.warning(f"Failed to switch {name} (Tried: {', '.join(targets)})")


async def data_collection_loop():
    """Gathers statistics from all sources every UPDATE_INTERVAL"""
    logger.info("Starting Data Collection Loop...")
    while True:
        try:
            # 1. Stratum & Worker Configs
            stratum_raw, worker_configs = get_stratum_stats()
            
            # 2. Miner Stats (Parallel Fetch)
            workers_stats = await get_all_workers_stats(worker_configs)
            
            # 3. Aggregate Total Hashrate (15m avg)
            total_h15 = sum(w['h15'] for w in workers_stats if w['status'] == 'online')
            
            # 4. Other Stats
            pool_stats = get_p2pool_stats()
            net_stats = get_network_stats()
            sys_stats = {
                "disk": get_disk_usage(),
                "hugepages": get_hugepages_status()
            }
            
            # 5. Update Global State
            LATEST_DATA.update({
                "workers": workers_stats,
                "total_live_h15": total_h15,
                "pool": pool_stats,
                "network": net_stats,
                "tari": get_tari_stats(),
                "system": sys_stats,
                "stratum": stratum_raw
            })
            
            # 6. Save History to Disk
            state_manager.update_history(total_h15)
            
            logger.debug(f"Data updated. Total HR: {total_h15}")
            
        except Exception as e:
            logger.error(f"Error in data loop: {e}")
            
        await asyncio.sleep(UPDATE_INTERVAL)


async def algo_control_loop():
    """Executes the XvB mining strategy"""
    logger.info("Starting Algo Control Loop...")
    
    # Wait a bit for the first data collection to finish
    await asyncio.sleep(5)
    
    while True:
        try:
            # Inputs
            current_hr = LATEST_DATA.get("total_live_h15", 0)
            p2pool_stats = LATEST_DATA.get("pool", {}).get("pool", {}) # Access inner pool dict
            xvb_stats = state_manager.get_xvb_stats()
            
            # Decide
            decision, xvb_duration = algorithm.get_decision(current_hr, p2pool_stats, xvb_stats)
            
            workers = LATEST_DATA.get("workers", [])
            
            # Execute
            if decision == "P2POOL":
                state_manager.update_xvb_stats("P2POOL", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("P2POOL", workers)
                # Sleep for full cycle
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "XVB":
                state_manager.update_xvb_stats("XVB", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("XVB", workers)
                # Sleep for full cycle
                await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                
            elif decision == "SPLIT":
                # 1. Mine XvB for calculated duration
                state_manager.update_xvb_stats("XVB (Split)", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                await switch_miners("XVB", workers)
                await asyncio.sleep(xvb_duration / 1000)
                
                # 2. Switch back to P2Pool for remainder
                remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                if remainder > 0:
                    state_manager.update_xvb_stats("P2POOL (Split)", xvb_stats['24h_avg'], xvb_stats['1h_avg'])
                    await switch_miners("P2POOL", workers)
                    await asyncio.sleep(remainder)

        except Exception as e:
            logger.error(f"Error in algo loop: {e}")
            await asyncio.sleep(10)


async def tier_update_loop():
    """Scrapes XvB website periodically to keep tier limits fresh"""
    logger.info("Starting Tier Update Loop...")
    while True:
        # Fetch latest requirements
        new_tiers = await fetch_xvb_tiers()
        
        if new_tiers:
            state_manager.update_tiers(new_tiers)
            logger.info(f"XvB Tiers Updated: {new_tiers}")
        
        # Run every 4 hours (4 * 3600 seconds)
        await asyncio.sleep(14400)


async def start_background_tasks(app):
    """Launches all background loops when Web Server starts"""
    app['data_task'] = asyncio.create_task(data_collection_loop())
    app['algo_task'] = asyncio.create_task(algo_control_loop())
    app['tier_task'] = asyncio.create_task(tier_update_loop())


if __name__ == "__main__":
    # Create Web App
    app = create_app(state_manager, LATEST_DATA)
    
    # Attach background tasks
    app.on_startup.append(start_background_tasks)
    
    logger.info(f"Starting Mining Dashboard on port 8080")
    
    # Run
    web.run_app(app, port=8080, print=None)