import asyncio
import aiohttp
from aiohttp import ClientTimeout
from config import XMRIG_API_PORT, API_TIMEOUT

async def fetch_xmrig_summary(session, ip, name):
    """
    Connects to a single XMRig instance.
    PRIORITY: Hostname -> Hostname.local -> IP
    """
    # Define connection targets in your preferred order of reliability
    targets = [
        f"{name}:{XMRIG_API_PORT}",       # 1. Hostname (Fastest if DNS works)
        f"{name}.local:{XMRIG_API_PORT}", # 2. Avahi/mDNS (Good for LAN)
        f"{ip}:{XMRIG_API_PORT}"          # 3. IP Fallback (Last resort)
    ]
    
    timeout = ClientTimeout(total=API_TIMEOUT)
    
    # Iterate through targets until one works
    for target in targets:
        # Skip invalid targets (e.g. if name is missing)
        if target.startswith(":"): continue
            
        url = f"http://{target}/1/summary"
        
        try:
            async with session.get(url, timeout=timeout) as response:
                if response.status == 200:
                    data = await response.json()
                    
                    hr_total = data.get("hashrate", {}).get("total", [0, 0, 0])
                    
                    return {
                        "name": name,
                        "ip": ip, 
                        "status": "online",
                        # We save the 'working_addr' so main.py *could* use it if needed
                        "working_addr": target, 
                        "uptime": data.get("uptime", 0),
                        "h10": hr_total[0] if len(hr_total) > 0 else 0,
                        "h60": hr_total[1] if len(hr_total) > 1 else 0,
                        "h15": hr_total[2] if len(hr_total) > 2 else 0,
                        "results": data.get("results", {})
                    }
        except (aiohttp.ClientError, asyncio.TimeoutError, OSError):
            # If this target failed, immediately try the next one in the list
            continue
            
    # If all attempts fail
    return {
        "name": name,
        "ip": ip,
        "status": "offline",
        "uptime": 0,
        "h10": 0, "h60": 0, "h15": 0, "results": {}
    }

async def get_all_workers_stats(worker_configs):
    """
    Fetches stats for all workers in parallel.
    
    worker_configs: List of dicts [{"ip": "192.168.1.50", "name": "miner01"}, ...]
    (Usually provided by collectors.pools.get_stratum_stats)
    """
    if not worker_configs:
        return []

    async with aiohttp.ClientSession() as session:
        tasks = []
        for w in worker_configs:
            # Launch a fetch task for every worker
            tasks.append(fetch_xmrig_summary(session, w['ip'], w['name']))
        
        # Wait for all requests to finish concurrently
        results = await asyncio.gather(*tasks)
        return results