import asyncio
import logging
import time
from aiohttp import ClientSession, TCPConnector

from config.config import UPDATE_INTERVAL
from client.xmrig_client import XMRigWorkerClient
from client.tari.tari_client import TariClient
from collector.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from collector.logs import get_monero_sync_status
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
            "monero_sync": {},
            "tari_sync": {},
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
            tari_client = TariClient(session)
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
                                if isinstance(w, list) and len(w) >= 13:
                                    proxy_workers.append({
                                        "name": w[0],
                                        "ip": w[1],
                                        "status": "online",
                                        # Proxy returns kH/s, convert to H/s
                                        # Mapping: 1m(idx8)->10s & 60s (Proxy lacks 10s), 10m(idx9)->15m
                                        "h10": w[8] * 1000,
                                        "h60": w[8] * 1000,
                                        "h15": w[9] * 1000,
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
                            
                            # Prefer direct worker stats for hashrate if available
                            hr_total = extra_stats.get('hashrate', {}).get('total', [])
                            if isinstance(hr_total, list) and len(hr_total) >= 3:
                                w['h10'] = hr_total[0] if hr_total[0] is not None else 0
                                w['h60'] = hr_total[1] if hr_total[1] is not None else 0
                                w['h15'] = hr_total[2] if hr_total[2] is not None else 0
                        else:
                            w['status'] = 'unreachable'
                        
                        w['active_pool'] = active_pool_port
                        final_workers.append(w)
                    
                    # Aggregate 15-minute average hashrate
                    total_h15 = sum(w.get('h15', 0) for w in final_workers if w.get('status') == 'online')
                    
                    # Fetch stats for sync logic
                    network_stats = get_network_stats()
                    tari_stats = get_tari_stats()
                    monero_sync = await get_monero_sync_status()
                    tari_sync = await tari_client.get_sync_status()

                    # Determine effective Tari status (matching UI logic)
                    tari_active = tari_stats.get('active', False)
                    tari_status_str = tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...'

                    # Apply Sync Logic Overrides
                    # 1. Monero Sync Check
                    if network_stats.get('height', 0) == 0:
                        monero_sync['is_syncing'] = True
                        if 'percent' not in monero_sync:
                            monero_sync.update({'percent': 0, 'current': 0, 'target': 1})
                    
                    # 2. Tari Sync Check (Force dashboard sync mode if Tari is syncing)
                    if tari_sync.get('is_syncing', False):
                        monero_sync['is_syncing'] = True
                        # Ensure Monero shows as "Synced" if it actually is, while Tari spins
                        if 'percent' not in monero_sync:
                            h = network_stats.get('height', 1)
                            monero_sync.update({'percent': 100, 'current': h, 'target': h})

                    self.latest_data.update({
                        "workers": final_workers,
                        "total_live_h15": total_h15,
                        "pool": get_p2pool_stats(),
                        "network": network_stats,
                        "tari": tari_stats,
                        "monero_sync": monero_sync,
                        "tari_sync": tari_sync,
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
                            logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['avg_1h']:.0f} H/s)")
                    
                    iteration_count += 1
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                await asyncio.sleep(UPDATE_INTERVAL)