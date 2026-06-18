import ipaddress
import socket
import time

from mining_dashboard.config.config import TIER_DEFAULTS


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

        if "gh" in unit:
            return val * 1_000_000_000
        if "mh" in unit:
            return val * 1_000_000
        if "kh" in unit:
            return val * 1_000

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
            return f"{val:.2f} H/s"

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
        return time.strftime("%H:%M:%S", time.localtime(timestamp))
    except (ValueError, OSError, TypeError):
        return "Invalid Time"


def get_tier_info(hashrate, tiers=None):
    """
    Determines the donation tier based on hashrate.
    Returns (tier_name, tier_threshold).
    """
    if tiers is None:
        tiers = TIER_DEFAULTS

    # Sort tiers by threshold descending to find the highest matching tier first
    sorted_tiers = sorted(tiers.items(), key=lambda x: x[1], reverse=True)

    for key, threshold in sorted_tiers:
        if threshold > 0 and hashrate >= threshold:
            # Format key for display (e.g., "donor_mega" -> "Mega")
            display_name = key.replace("donor_", "").replace("_", " ").title()
            return f"{display_name} ({format_hashrate(threshold)}+)", float(threshold)

    return "None", 0.0


def _configured_tier_threshold(tiers, donation_level):
    """
    Maps a configured donation level to a tier threshold (H/s).

    Accepts "lowest", "auto"/"highest", a tier name ("donor"/"vip"/"whale"/"mega",
    matched against the tier keys with the "donor_" prefix stripped), or a raw
    numeric H/s value. Unknown values fall back to the lowest tier.
    """
    positive = sorted(t for t in tiers.values() if t > 0)
    if not positive:
        return 0.0

    level = (donation_level or "lowest").strip().lower()
    if level == "lowest":
        return float(positive[0])
    if level in ("auto", "highest"):
        return float(positive[-1])

    # Named tier (e.g. "vip" -> "donor_vip", "donor" -> "donor")
    for key, threshold in tiers.items():
        name = key.replace("donor_", "").replace("_", "").lower() or "donor"
        if level in (name, key.lower()):
            return float(threshold)

    # Raw numeric threshold
    try:
        return float(level)
    except (ValueError, TypeError):
        return float(positive[0])


def resolve_target_threshold(tiers, stable_hr, donation_level, max_fraction):
    """
    Resolves the donation tier to aim for. Returns ``(threshold_hs, sustainable)``.

    "auto"/"highest" targets the highest tier the hashrate can sustain (leaving
    `max_fraction` headroom for p2pool); the threshold is 0 when none is
    sustainable (donate nothing). A specific tier ("donor"/"vip"/"whale"/"mega" or
    a numeric H/s) is honored as-is and is NOT downgraded — a user may deliberately
    target a tier above their capacity, in which case `sustainable` is False so the
    dashboard can warn.
    """
    _, sustainable_threshold = get_tier_info(stable_hr * max_fraction, tiers)

    level = (donation_level or "auto").strip().lower()
    if level in ("auto", "highest"):
        target = sustainable_threshold
    else:
        target = _configured_tier_threshold(tiers, level)

    sustainable = target > 0 and (stable_hr * max_fraction) >= target
    return target, sustainable


def is_ip_address(value):
    """True if ``value`` is a literal IP address (IPv4 or IPv6), False for a hostname.

    Used to decide whether the configured ``dashboard.host`` already *is* an address, in
    which case there's no separate numeric IP worth showing beside it (Issue #119).
    """
    try:
        ipaddress.ip_address(value.strip())
        return True
    except (ValueError, AttributeError):
        return False


def detect_host_ipv4():
    """Best-effort primary LAN IPv4 of the host this dashboard runs on.

    Opens a UDP socket toward an off-link sentinel address so the kernel selects the source
    address of the default-route interface — UDP ``connect`` only fixes the route, no packets
    are sent and the sentinel is never contacted (it's RFC 5737 TEST-NET-1, guaranteed not a
    real endpoint). The dashboard runs with ``network_mode: host``, so the address picked is the
    host's own LAN IP, not a Docker bridge address. Returns ``None`` when it can't be determined
    (e.g. no default route), so callers fall back to showing the hostname alone.
    """
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("192.0.2.1", 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()
