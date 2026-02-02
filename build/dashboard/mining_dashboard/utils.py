import time

def parse_hashrate(val_str, unit_str=None):
    """
    Converts a value string and optional unit string into raw H/s (float).
    Supports: H/s, kH/s, MH/s, GH/s (case insensitive).
    """
    try:
        val = float(val_str)
        if not unit_str:
            return val
        
        u = unit_str.lower()
        if "gh" in u: return val * 1_000_000_000
        if "mh" in u: return val * 1_000_000
        if "kh" in u: return val * 1_000
        return val
    except (ValueError, TypeError):
        return 0.0

def format_hashrate(h):
    """
    Formats raw hashrate (float) to a readable string (H/s, kH/s, MH/s, GH/s).
    """
    try:
        val = float(h)
        if val >= 1_000_000_000: return f"{val/1_000_000_000:.2f} GH/s"
        if val >= 1_000_000: return f"{val/1_000_000:.2f} MH/s"
        if val >= 1_000: return f"{val/1_000:.2f} kH/s"
        return f"{int(val)} H/s"
    except (ValueError, TypeError):
        return "0 H/s"

def format_duration(seconds):
    """Formats uptime seconds into 2d 4h 30m"""
    try:
        seconds = int(seconds)
        d = seconds // (3600 * 24)
        h = (seconds // 3600) % 24
        m = (seconds // 60) % 60
        s = seconds % 60
        if d > 0: return f"{d}d {h}h {m}m"
        if h > 0: return f"{h}h {m}m"
        return f"{m}m {s}s"
    except (ValueError, TypeError): return "0s"

def format_time_abs(ts):
    """Formats unix timestamp to HH:MM:SS"""
    if not ts: return "Never"
    try:
        return time.strftime('%H:%M:%S', time.localtime(ts))
    except: return "Invalid Time"