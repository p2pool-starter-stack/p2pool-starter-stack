import time
from config import TIER_DEFAULTS

def parse_hashrate(val_str, unit_str=None):
    """
    Converts a numeric string and an optional unit suffix into raw hashes per second (H/s).
    
    Args:
        val_str (str|float): The numeric value (e.g., "1.5").
        unit_str (str, optional): The unit suffix (e.g., "MH/s", "kH/s").
        
    Returns:
        float: The standardized hashrate in H/s. Returns 0.0 on parsing failure.
    """
    try:
        val = float(val_str)
        if not unit_str:
            return val
        
        # Normalize unit string for case-insensitive comparison
        unit = unit_str.lower()
        
        if "gh" in unit: return val * 1_000_000_000
        if "mh" in unit: return val * 1_000_000
        if "kh" in unit: return val * 1_000
        
        return val
    except (ValueError, TypeError):
        return 0.0

def format_hashrate(hashrate):
    """
    Formats a raw hashrate value into a human-readable string with appropriate units.
    
    Args:
        hashrate (float): The raw hashrate in H/s.
        
    Returns:
        str: Formatted string (e.g., "1.25 MH/s").
    """
    try:
        val = float(hashrate)
        
        if val >= 1_000_000_000:
            return f"{val / 1_000_000_000:.2f} GH/s"
        elif val >= 1_000_000:
            return f"{val / 1_000_000:.2f} MH/s"
        elif val >= 1_000:
            return f"{val / 1_000:.2f} kH/s"
        else:
            return f"{int(val)} H/s"
            
    except (ValueError, TypeError):
        return "0 H/s"

def format_duration(seconds):
    """
    Formats a duration in seconds into a concise human-readable string.
    
    Format logic:
    - > 1 day: "Xd Xh Xm"
    - > 1 hour: "Xh Xm"
    - < 1 hour: "Xm Xs"
    
    Args:
        seconds (int|float): Duration in seconds.
        
    Returns:
        str: Formatted duration string.
    """
    try:
        seconds = int(seconds)
        days = seconds // 86400
        hours = (seconds // 3600) % 24
        minutes = (seconds // 60) % 60
        secs = seconds % 60
        
        if days > 0:
            return f"{days}d {hours}h {minutes}m"
        if hours > 0:
            return f"{hours}h {minutes}m"
            
        return f"{minutes}m {secs}s"
        
    except (ValueError, TypeError):
        return "0s"

def format_time_abs(timestamp):
    """
    Converts a Unix timestamp into a localized time string (HH:MM:SS).
    
    Args:
        timestamp (float): Unix timestamp.
        
    Returns:
        str: Formatted time string or error placeholder.
    """
    if not timestamp:
        return "Never"
        
    try:
        return time.strftime('%H:%M:%S', time.localtime(timestamp))
    except (ValueError, OSError):
        return "Invalid Time"

def get_tier_info(hashrate, tiers=None):
    """
    Determines the donation tier based on hashrate.
    Returns (tier_name, tier_threshold).
    """
    if tiers is None:
        tiers = TIER_DEFAULTS

    limit_mega = tiers.get("donor_mega", 0)
    limit_whale = tiers.get("donor_whale", 0)
    limit_vip = tiers.get("donor_vip", 0)
    limit_donor = tiers.get("donor", 0)

    if limit_mega > 0 and hashrate >= limit_mega: return "Mega (1 MH/s+)", float(limit_mega)
    if limit_whale > 0 and hashrate >= limit_whale: return "Whale (100 kH/s+)", float(limit_whale)
    if limit_vip > 0 and hashrate >= limit_vip: return "VIP (10 kH/s+)", float(limit_vip)
    if limit_donor > 0 and hashrate >= limit_donor: return "Donor (1 kH/s+)", float(limit_donor)

    return "Standard", 0.0