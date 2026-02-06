import asyncio
import logging
import time
from aiohttp import ClientSession, TCPConnector

from config.config import UPDATE_INTERVAL
from client.xmrig_client import XMRigWorkerClient
from collector.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collector.system import get_disk_usage, get_hugepages_status, get_memory_usage, get_load_average, get_cpu_usage

logger = logging.getLogger("DataService")

class DataService:
    def __init__(self, state_manager, proxy_client, xvb_client):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.xvb_client = xvb_client
        
        self.latest_data = {
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
        loaded_snapshot = self.state_manager.load_snapshot()
        if loaded_snapshot and isinstance(loaded_snapshot, dict):
            self.latest_data.update(loaded_snapshot)

    async def run(self):
        """
        Periodic task to aggregate statistics from local collectors and external APIs.
        Updates the latest_data state and persists historical metrics.
        """
        logger.info("Service Started: Data Collection Loop")
        
        iteration_count = 0 
        
        async with ClientSession(connector=TCPConnector(verify_ssl=False)) as session:
            worker_client = XMRigWorkerClient(session)
            while True:
                try:
                    # 1. Collect Local Statistics (High Frequency)
                    stratum_raw, worker_configs = get_stratum_stats()
                    
                    # Fetch workers from Proxy
                    proxy_workers = []
                    try:
                        proxy_data = await asyncio.to_thread(self.proxy_client.get_workers)
                        if proxy_data and "workers" in proxy_data:
                            for w in proxy_data["workers"]:
                                # Handle list format (XMRig Proxy 6.x+)
                                if isinstance(w, list) and len(w) >= 11:
                                    proxy_workers.append({
                                        "name": w[0],
                                        "ip": w[1],
                                        "status": "online",
                                        "h10": w[8],
                                        "h60": w[9],
                                        "h15": w[10],
                                        "uptime": 0 
                                    })
                                # Handle dict format (Legacy)
                                elif isinstance(w, dict):
                                    hr = w.get("hashrate", [0, 0, 0])
                                    proxy_workers.append({
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

                    # Augment with direct worker stats (Uptime, etc.)
                    tasks = [worker_client.get_stats(w['ip'], w['name']) for w in proxy_workers]
                    worker_results = await asyncio.gather(*tasks)

                    final_workers = []
                    current_mode = self.state_manager.get_xvb_stats().get("current_mode", "P2POOL")
                    
                    # Determine active pool port for UI badges based on current Algo mode
                    active_pool_port = "3344" if "XVB" in current_mode else "3333"

                    for w, extra_stats in zip(proxy_workers, worker_results):
                        if extra_stats:
                            w['uptime'] = extra_stats.get('uptime', w['uptime'])
                        
                        w['active_pool'] = active_pool_port
                        final_workers.append(w)
                    
                    # Aggregate 15-minute average hashrate
                    total_h15 = sum(w.get('h15', 0) for w in final_workers if w.get('status') == 'online')
                    
                    self.latest_data.update({
                        "workers": final_workers,
                        "total_live_h15": total_h15,
                        "pool": get_p2pool_stats(),
                        "network": get_network_stats(),
                        "tari": get_tari_stats(),
                        "system": {
                            "disk": get_disk_usage(),
                            "hugepages": get_hugepages_status(),
                            "memory": get_memory_usage(),
                            "load": get_load_average(),
                            "cpu_percent": get_cpu_usage()
                        },
                        "stratum": stratum_raw,
                        "timestamp": time.time()
                    })
                    
                    # 2. Update Historical Data
                    p2pool_hr = 0 if "XVB" in current_mode else total_h15
                    xvb_hr = total_h15 if "XVB" in current_mode else 0
                    
                    await asyncio.to_thread(self.state_manager.update_history, total_h15, p2pool_hr, xvb_hr)
                    await asyncio.to_thread(self.state_manager.save_snapshot, self.latest_data)

                    # 3. External API Sync (Throttled)
                    if iteration_count % 10 == 0:
                        real_xvb_stats = await asyncio.to_thread(self.xvb_client.get_stats)
                        if real_xvb_stats:
                            await asyncio.to_thread(self.state_manager.update_xvb_stats, **real_xvb_stats)
                            logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['1h_avg']:.0f} H/s)")
                    
                    iteration_count += 1
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                await asyncio.sleep(UPDATE_INTERVAL)