import asyncio
import logging
import time
from aiohttp import ClientSession

from mining_dashboard.config.config import (
    UPDATE_INTERVAL,
    REJECT_WORKERS_ON_NODE_DOWN,
    REJECT_WORKERS_CONTAINER,
)
from mining_dashboard.client.xmrig_client import XMRigWorkerClient
from mining_dashboard.client.tari.tari_client import TariClient
from mining_dashboard.client.docker.docker_control import DockerControl
from mining_dashboard.collector.pools import get_p2pool_stats, get_network_stats, get_stratum_stats, get_tari_stats
from mining_dashboard.collector.logs import get_monero_sync_status
from mining_dashboard.collector.system import get_disk_usage, get_hugepages_status, get_memory_usage, get_load_average, get_cpu_usage
from mining_dashboard.service.node_health import NodeHealthMonitor

logger = logging.getLogger("DataService")

class DataService:
    """
    Core service responsible for aggregating mining statistics from various sources
    (Local collectors, XMRig Proxy, Tari Node, etc.) and maintaining the application state.
    """
    def __init__(self, state_manager, proxy_client, xvb_client):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.xvb_client = xvb_client
        
        self.latest_data = {
            "workers": [],
            "total_live_h15": 0,
            "total_live_h10": 0,
            "pool": {"p2p": {}, "pool": {}},
            "network": {},
            "system": {},
            "tari": {},
            "stratum": {},
            "monero_sync": {},
            "tari_sync": {},
            "global_sync": False,
            "workers_rejected": False,
            "timestamp": 0
        }

        # Node-down detection + optional worker rejection (Issue #31).
        self.docker_control = DockerControl()
        self.monero_health = NodeHealthMonitor()
        self.tari_health = NodeHealthMonitor()
        # True while we've stopped the proxy to reject workers. Persisted in the snapshot so
        # a dashboard restart mid-outage still readmits workers once the node recovers.
        self.workers_rejected = False

        # Restore persistent state from DB to prevent empty dashboard on service restart
        loaded_snapshot = self.state_manager.load_snapshot()
        if loaded_snapshot and isinstance(loaded_snapshot, dict):
            self.latest_data.update(loaded_snapshot)
            self.workers_rejected = bool(self.latest_data.get("workers_rejected", False))

    async def _apply_worker_rejection(self, nodes_down):
        """
        Reject workers (stop the proxy) when a node is DOWN so miners fail over to their
        backup pools; readmit them (start the proxy) once nodes are confirmed healthy.

        Opt-in via REJECT_WORKERS_ON_NODE_DOWN; a no-op otherwise. Only acts on transitions
        (tracked by `workers_rejected`), and Docker treats a repeat stop/start as
        already-done (HTTP 304), so this is safe to call every cycle.
        """
        if not REJECT_WORKERS_ON_NODE_DOWN:
            return

        if nodes_down and not self.workers_rejected:
            logger.warning(
                f"Node unreachable — stopping {REJECT_WORKERS_CONTAINER} so workers fail "
                f"over to their backup pools."
            )
            if await self.docker_control.stop(REJECT_WORKERS_CONTAINER):
                self.workers_rejected = True
            return

        # Readmit only once BOTH nodes are confirmed healthy (not merely 'not down'), so a
        # dashboard restart mid-outage doesn't bring workers back to a still-down stack.
        if self.workers_rejected and self.monero_health.healthy and self.tari_health.healthy:
            logger.info(
                f"Nodes recovered — starting {REJECT_WORKERS_CONTAINER} to readmit workers."
            )
            if await self.docker_control.start(REJECT_WORKERS_CONTAINER):
                self.workers_rejected = False

    async def run(self):
        """
        Main execution loop: Aggregates statistics from local collectors and external APIs.
        Updates the `latest_data` state and persists historical metrics to the database.
        """
        logger.info("Service Started: Data Collection Loop")
        
        iteration_count = 0 
        
        async with ClientSession() as session:
            worker_client = XMRigWorkerClient(session)
            tari_client = TariClient(session)
            
            # Initialize share tracking
            last_known_share_ts = 0
            
            # Get latest share timestamp from DB if available
            db_shares = self.state_manager.get_shares()
            if db_shares:
                last_known_share_ts = db_shares[-1].get("ts", 0)

            while True:
                try:
                    # 1. Collect Local Statistics (High Frequency Polling)
                    stratum_raw, worker_configs = get_stratum_stats()
                    
                    # 2. Fetch Worker Statistics from XMRig Proxy
                    proxy_workers = []
                    try:
                        proxy_data = await asyncio.to_thread(self.proxy_client.get_workers)
                        if proxy_data and "workers" in proxy_data:
                            for w in proxy_data["workers"]:
                                # Handle list format (XMRig Proxy 6.x+)
                                if isinstance(w, list) and len(w) >= 13:
                                    # w[7] = last share timestamp (ms). Use it as a fallback
                                    # "seconds since last share" for uptime when the direct
                                    # worker API isn't reachable.
                                    last_share_ms = w[7] if w[7] else 0
                                    uptime_estimate = int(time.time() - last_share_ms / 1000) if last_share_ms > 0 else 0
                                    # w[2] = active connection count. xmrig-proxy keeps a worker
                                    # in /workers (with a decaying hashrate) after it disconnects,
                                    # so mere presence != connected — use the connection count, or
                                    # a stopped miner stays green and inflates the total.
                                    connections = w[2] if len(w) > 2 else 0
                                    proxy_workers.append({
                                        "name": w[0],
                                        "ip": w[1],
                                        "status": "online" if connections > 0 else "offline",
                                        # Proxy returns kH/s, convert to H/s
                                        # Mapping: 1m(idx8)->10s & 60s (Proxy lacks 10s), 10m(idx9)->15m
                                        "h10": w[8] * 1000,
                                        "h60": w[8] * 1000,
                                        "h15": w[9] * 1000,
                                        "uptime": uptime_estimate
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

                    # 3. Augment with Direct Worker Stats (Uptime, Hashrate) via Local API
                    tasks = [worker_client.get_stats(w['ip'], w['name']) for w in proxy_workers]
                    worker_results = await asyncio.gather(*tasks)

                    final_workers = []
                    current_mode = self.state_manager.get_xvb_stats().get("current_mode", "P2POOL")
                    
                    # Determine active pool port for UI badges based on current Algo mode
                    active_pool_port = "3344" if "XVB" in current_mode else "3333"

                    for w, extra_stats in zip(proxy_workers, worker_results):
                        if extra_stats:
                            w['uptime'] = extra_stats.get('uptime', w['uptime'])

                            # xmrig-proxy /1/summary reports hashrate in kH/s; an xmrig miner
                            # reports H/s. The 'kind' field distinguishes them, so scale to H/s.
                            is_proxy = extra_stats.get('kind') == 'proxy'
                            hr_scale = 1000 if is_proxy else 1

                            hr_total = extra_stats.get('hashrate', {}).get('total', [])
                            if isinstance(hr_total, list) and len(hr_total) >= 3:
                                w['h10'] = (hr_total[0] or 0) * hr_scale
                                w['h60'] = (hr_total[1] or 0) * hr_scale
                                w['h15'] = (hr_total[2] or 0) * hr_scale
                        # If the direct worker API is unreachable, keep the worker 'online' with
                        # the proxy-derived hashrate/uptime (the proxy already confirmed it's
                        # connected and submitting shares) instead of marking it 'unreachable',
                        # which would drop it from the hashrate total and read zero. (Fixes #28.)

                        w['active_pool'] = active_pool_port
                        final_workers.append(w)
                    
                    # 4. Calculate Aggregates (Priority: 15m > 60s > 10s)
                    total_hr = 0
                    total_h10 = 0
                    for w in final_workers:
                        if w.get('status') == 'online':
                            w_hr = w.get('h15', 0)
                            if w_hr == 0:
                                w_hr = w.get('h60', 0)
                            if w_hr == 0:
                                w_hr = w.get('h10', 0)
                            total_hr += w_hr
                            total_h10 += w.get('h10', 0)
                    
                    # 5. Fetch Network & Sync Status
                    network_stats = get_network_stats()
                    tari_stats = get_tari_stats()
                    p2pool_stats = get_p2pool_stats()

                    # Track P2Pool Shares in DB
                    current_share_ts = p2pool_stats["pool"].get("last_share_time", 0)
                    if current_share_ts > last_known_share_ts:
                        if current_share_ts > 0:
                            difficulty = p2pool_stats["pool"].get("difficulty", 0)
                            await asyncio.to_thread(self.state_manager.add_share, current_share_ts, difficulty)
                        last_known_share_ts = current_share_ts

                    monero_sync = await get_monero_sync_status()
                    tari_sync = await tari_client.get_sync_status()

                    # Determine effective Tari status for UI display
                    tari_active = tari_stats.get('active', False)
                    tari_status_str = tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...'

                    # Apply Sync Logic Overrides
                    # 1. Monero Sync Check
                    if network_stats.get('height', 0) == 0:
                        monero_sync['is_syncing'] = True
                        if 'percent' not in monero_sync:
                            monero_sync.update({'percent': 0, 'current': 0, 'target': 1})
                    
                    # 2. Global Sync Logic
                    is_monero_syncing = monero_sync.get('is_syncing', False)
                    is_tari_syncing = tari_sync.get('is_syncing', False)
                    global_sync = is_monero_syncing or is_tari_syncing

                    if global_sync:
                        if not is_monero_syncing and 'percent' not in monero_sync:
                            h = network_stats.get('height', 1)
                            monero_sync.update({'percent': 100, 'current': h, 'target': h})
                        if not is_tari_syncing and 'percent' not in tari_sync:
                            h = tari_stats.get('height', 0)
                            tari_sync.update({'percent': 100, 'current': h, 'target': h})

                    # 3. Node-down detection + optional worker rejection (Issue #31).
                    # Debounce each node's live reachability into a stable DOWN flag, then
                    # (if enabled) stop the proxy so workers fail over to their backups.
                    monero_down = self.monero_health.update(monero_sync.get('reachable', True))
                    tari_down = self.tari_health.update(tari_sync.get('reachable', True))
                    monero_sync['down'] = monero_down
                    tari_sync['down'] = tari_down
                    await self._apply_worker_rejection(monero_down or tari_down)

                    # Fetch fresh shares list to populate UI
                    shares_list = await asyncio.to_thread(self.state_manager.get_shares)

                    self.latest_data.update({
                        "workers": final_workers,
                        "shares": shares_list,
                        "total_live_h15": total_hr,
                        "total_live_h10": total_h10,
                        "pool": p2pool_stats,
                        "network": network_stats,
                        "tari": tari_stats,
                        "monero_sync": monero_sync,
                        "tari_sync": tari_sync,
                        "global_sync": global_sync,
                        "workers_rejected": self.workers_rejected,
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
                    
                    # 6. Persist Historical Data
                    p2pool_hr = 0 if "XVB" in current_mode else total_hr
                    xvb_hr = total_hr if "XVB" in current_mode else 0
                    
                    await asyncio.to_thread(self.state_manager.update_history, total_hr, p2pool_hr, xvb_hr)
                    
                    # Create a lightweight snapshot (exclude shares entirely as they are safely in DB)
                    snapshot_data = self.latest_data.copy()
                    snapshot_data.pop("shares", None)
                    await asyncio.to_thread(self.state_manager.save_snapshot, snapshot_data)

                    # 7. External API Sync (Throttled to every 10th iteration)
                    if iteration_count % 10 == 0:
                        real_xvb_stats = await asyncio.to_thread(self.xvb_client.get_stats)
                        if real_xvb_stats:
                            await asyncio.to_thread(self.state_manager.update_xvb_stats, **real_xvb_stats)
                            logger.info(f"External Sync: XvB Stats Updated (1h={real_xvb_stats['avg_1h']:.0f} H/s)")
                    
                    iteration_count += 1
                except Exception as e:
                    logger.error(f"Data Collection Error: {e}")
                await asyncio.sleep(UPDATE_INTERVAL)