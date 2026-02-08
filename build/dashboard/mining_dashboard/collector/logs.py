import aiohttp
import logging
import re
import struct

from config.config import DOCKER_PROXY_URL, LOG_TAIL_LINES, DOCKER_TIMEOUT

logger = logging.getLogger("LogCollector")

async def fetch_docker_logs(container_name, tail=None):
    """
    Fetches logs from a container via the Docker Socket Proxy.
    Handles the Docker binary stream format (multiplexed stdout/stderr).
    """
    if tail is None:
        tail = LOG_TAIL_LINES

    # Ensure URL scheme is http for aiohttp, even if env var is tcp://
    base_url = DOCKER_PROXY_URL
    if base_url.startswith("tcp://"):
        base_url = base_url.replace("tcp://", "http://")
    
    # Docker Engine API: /containers/{id}/logs
    url = f"{base_url}/containers/{container_name}/logs"
    params = {
        "stdout": 1,
        "stderr": 1,
        "tail": tail
    }

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, params=params, timeout=DOCKER_TIMEOUT) as response:
                if response.status == 200:
                    raw_data = await response.read()
                    return _parse_docker_stream(raw_data)
                else:
                    logger.error(f"Failed to fetch logs for {container_name}. Status: {response.status}")
                    return [f"Error: Could not retrieve logs (Status {response.status})"]
    except Exception as e:
        logger.error(f"Error connecting to Docker Proxy at {base_url}: {e}")
        return [f"Error: Connection to Docker Proxy failed."]

def _parse_docker_stream(data):
    """
    Parses the Docker raw stream format.
    Header format (8 bytes): [STREAM_TYPE] [0 0 0] [SIZE (Big Endian uint32)]
    """
    logs = []
    i = 0
    n = len(data)
    
    while i < n:
        if i + 8 > n:
            break
        
        # header = data[i:i+8]
        # stream_type = header[0] # 1=stdout, 2=stderr
        payload_size = struct.unpack('>I', data[i+4:i+8])[0]
        
        i += 8
        if i + payload_size > n:
            break
            
        line = data[i:i+payload_size].decode('utf-8', errors='replace').strip()
        if line:
            logs.append(line)
        
        i += payload_size
        
    return logs

async def get_monero_logs(tail=None):
    return await fetch_docker_logs("monerod", tail=tail)

async def get_monero_sync_status():
    """
    Parses monerod logs to determine if the node is currently syncing.
    Returns a dict with sync status and progress if syncing, else {'is_syncing': False}.
    """
    logs = await get_monero_logs(tail=100)
    if not logs or (len(logs) == 1 and logs[0].startswith("Error")):
        return {"is_syncing": False}

    # Iterate backwards to find the most recent sync status
    for line in reversed(logs):
        if "You are now synchronized" in line:
            return {"is_syncing": False}

        # Match "Synced <current>/<target>" with optional percentage
        match = re.search(r"Synced\s+(\d+)/(\d+)", line)
        if match:
            current = int(match.group(1))
            target = int(match.group(2))

            if current >= target:
                return {"is_syncing": False}

            # If we are behind, check for percentage or calculate it
            percent = 0
            pct_match = re.search(r"\((\d+)%", line)
            if pct_match:
                percent = int(pct_match.group(1))
            elif target > 0:
                percent = int((current / target) * 100)

            return {
                "is_syncing": True,
                "current": current,
                "target": target,
                "percent": percent
            }
            
    return {"is_syncing": False}