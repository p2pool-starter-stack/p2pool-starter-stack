import shutil
import os
from config import DISK_PATH

BYTES_IN_GB = 1024 ** 3

def get_disk_usage():
    """
    Calculates storage utilization for the configured data directory.

    Returns:
        dict: A dictionary containing total/used GB and percentage strings
              formatted for dashboard visualization.
    """
    try:
        usage = shutil.disk_usage(DISK_PATH)
        percent = (usage.used / usage.total) * 100
        return {
            "total_gb": usage.total / BYTES_IN_GB,
            "used_gb": usage.used / BYTES_IN_GB,
            "percent": percent,
            "percent_str": f"{percent:.1f}%"
        }
    except Exception:
        # Return zeroed metrics if the path is inaccessible
        return {
            "total_gb": 0, "used_gb": 0, 
            "percent": 0, "percent_str": "0%"
        }

def get_memory_usage():
    """
    Calculates system memory usage using /proc/meminfo.
    Returns dict with total_gb, used_gb, percent, percent_str.
    """
    try:
        mem_total = 0
        mem_available = 0
        with open('/proc/meminfo', 'r') as f:
            for line in f:
                if line.startswith('MemTotal:'):
                    mem_total = int(line.split()[1]) * 1024 # kB to bytes
                elif line.startswith('MemAvailable:'):
                    mem_available = int(line.split()[1]) * 1024 # kB to bytes
        
        if mem_total > 0:
            used = mem_total - mem_available
            percent = (used / mem_total) * 100
            return {
                "total_gb": mem_total / BYTES_IN_GB,
                "used_gb": used / BYTES_IN_GB,
                "percent": percent,
                "percent_str": f"{percent:.1f}%"
            }
    except Exception:
        pass
    return {"total_gb": 0, "used_gb": 0, "percent": 0, "percent_str": "0%"}

def get_load_average():
    """
    Returns system load average (1m, 5m, 15m) as a string.
    """
    try:
        load = os.getloadavg()
        return f"{load[0]:.2f} {load[1]:.2f} {load[2]:.2f}"
    except Exception:
        return "0.00 0.00 0.00"

def get_hugepages_status():
    """
    Analyzes system memory configuration to determine HugePage availability.
    
    Parses /proc/meminfo to check if HugePages are allocated and actively used
    by the mining process (RandomX optimization).

    Returns:
        tuple: (Status Label, CSS Class, Usage String "Used / Total")
    """
    try:
        mem_stats = {}
        with open("/proc/meminfo", "r") as f:
            for line in f:
                if line.startswith("HugePages_Total"):
                    mem_stats["total"] = int(line.split()[1])
                elif line.startswith("HugePages_Free"):
                    mem_stats["free"] = int(line.split()[1])

        # Ensure we found the necessary keys
        if "total" in mem_stats and "free" in mem_stats:
            hp_total = mem_stats["total"]
            hp_free = mem_stats["free"]
            hp_used = hp_total - hp_free
            
            val_str = f"{hp_used} / {hp_total}"
            
            # Status Logic:
            # 1. Total == 0: Feature not enabled in kernel/GRUB.
            if hp_total == 0:
                return "Disabled", "status-bad", val_str
            
            # 2. Used > 0: Feature enabled and actively utilized by miner.
            elif hp_used > 0:
                return "Enabled", "status-ok", val_str
            
            # 3. Total > 0 but Used == 0: Enabled but miner not using it yet.
            else:
                return "Allocated", "status-warn", val_str
                
    except (FileNotFoundError, ValueError, IndexError):
        # Gracefully handle non-Linux systems or parsing errors
        pass
        
    return "Unknown", "status-warn", "0/0"