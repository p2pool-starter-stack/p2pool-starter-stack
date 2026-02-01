import shutil
from config import DISK_PATH

def get_disk_usage():
    """
    Calculates disk usage for the configured path.
    Returns dict used for the progress bar.
    """
    try:
        usage = shutil.disk_usage(DISK_PATH)
        percent = (usage.used / usage.total) * 100
        return {
            "total_gb": usage.total / (1024**3),
            "used_gb": usage.used / (1024**3),
            "percent": percent,
            "percent_str": f"{percent:.1f}%"
        }
    except Exception:
        # Fallback if path doesn't exist
        return {
            "total_gb": 0, "used_gb": 0, 
            "percent": 0, "percent_str": "0%"
        }

def get_hugepages_status():
    """
    Reads /proc/meminfo to parse HugePage usage.
    Returns a tuple exactly as expected by the web server:
    (Status_Text, CSS_Class, Value_String)
    """
    try:
        with open("/proc/meminfo", "r") as f:
            mem_data = f.read()
            
        # Extract lines
        hp_total_line = [l for l in mem_data.split('\n') if "HugePages_Total" in l]
        hp_free_line = [l for l in mem_data.split('\n') if "HugePages_Free" in l]
        
        if hp_total_line and hp_free_line:
            hp_total = int(hp_total_line[0].split()[1])
            hp_free = int(hp_free_line[0].split()[1])
            hp_used = hp_total - hp_free
            
            val_str = f"{hp_used} / {hp_total}"
            
            # Logic: If total is 0, it's not enabled.
            if hp_total == 0:
                return "Disabled", "status-bad", val_str
            # If we are using them (arbitrary threshold > 10% or just > 0)
            elif hp_used > 0:
                return "Enabled", "status-ok", val_str
            else:
                # Allocated but not used yet
                return "Allocated", "status-warn", val_str
                
    except FileNotFoundError:
        pass
        
    return "Unknown", "status-warn", "0/0"