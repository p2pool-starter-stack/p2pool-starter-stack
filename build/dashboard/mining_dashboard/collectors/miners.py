import asyncio
import aiohttp
from aiohttp import ClientTimeout
from config import XMRIG_API_PORT, API_TIMEOUT

async def fetch_xmrig_summary(session, ip, name):
    """
    Retrieves operational statistics from a single XMRig instance.
    
    Implements a failover connection strategy:
    1. Hostname resolution
    2. mDNS (Bonjour/Avahi)
    3. Direct IP address
    
    Returns:
        dict: Normalized worker statistics including hashrate and connection status.
    """
    targets = [
        f"{name}:{XMRIG_API_PORT}",       # Priority 1: Standard Hostname
        f"{name}.local:{XMRIG_API_PORT}", # Priority 2: mDNS (Local Network)
        f"{ip}:{XMRIG_API_PORT}"          # Priority 3: Direct IP Fallback
    ]
    
    timeout = ClientTimeout(total=API_TIMEOUT)
    
    for target in targets:
        # Skip invalid targets where hostname/IP might be missing
        if target.startswith(":"): continue
            
        url = f"http://{target}/1/summary"
        
        try:
            async with session.get(url, timeout=timeout) as response:
                if response.status == 200:
                    data = await response.json()
                    
                    # Validate hashrate structure (expected: [10s, 60s, 15m])
                    hr_total = data.get("hashrate", {}).get("total")
                    if not isinstance(hr_total, list): 
                        hr_total = [0, 0, 0]
                    
                    active_pool = data.get("connection", {}).get("pool", "Unknown")
                    return {
                        "name": name,
                        "ip": ip, 
                        "status": "online",
                        "working_addr": target, 
                        "uptime": data.get("uptime", 0),
                        "h10": hr_total[0] if len(hr_total) > 0 and hr_total[0] is not None else 0,
                        "h60": hr_total[1] if len(hr_total) > 1 and hr_total[1] is not None else 0,
                        "h15": hr_total[2] if len(hr_total) > 2 and hr_total[2] is not None else 0,
                        "results": data.get("results", {}), # Share submission statistics
                        "active_pool": active_pool
                    }
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            # Connection failed for this target; proceed to next fallback
            continue
            
    # Return default offline state if all connection attempts fail
    return {
        "name": name,
        "ip": ip,
        "status": "offline",
        "uptime": 0,
        "h10": 0, "h60": 0, "h15": 0, "results": {},
        "active_pool": "N/A"
    }

async def get_all_workers_stats(worker_configs):
    """
    Orchestrates concurrent data retrieval from all registered worker nodes.
    
    Args:
        worker_configs (list): List of dicts containing 'ip' and 'name' for each worker.
        
    Returns:
        list: Aggregated list of worker statistic dictionaries.
    """
    if not worker_configs:
        return []

    async with aiohttp.ClientSession() as session:
        tasks = []
        for w in worker_configs:
            # Schedule asynchronous fetch task for each worker
            tasks.append(fetch_xmrig_summary(session, w['ip'], w['name']))
        
        # Execute all tasks concurrently and wait for completion
        results = await asyncio.gather(*tasks)
        return results