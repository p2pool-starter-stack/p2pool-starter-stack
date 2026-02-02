import aiohttp
import logging
import re
from config import MONERO_WALLET_ADDRESS  # This must be the FULL Monero Wallet Address now
from utils import parse_hashrate

logger = logging.getLogger("XvB_Collector")

async def fetch_xvb_stats():
    """
    Fetches the Fail Count, 1h, and 24h averages using the global MONERO_WALLET_ADDRESS.
    NOTE: MONERO_WALLET_ADDRESS must be the FULL Monero wallet address for this URL.
    """
    if not MONERO_WALLET_ADDRESS or MONERO_WALLET_ADDRESS == "placeholder":
        logger.warning("MONERO_WALLET_ADDRESS is missing or invalid. Skipping check.")
        return None

    url = f"https://xmrvsbeast.com/cgi-bin/p2pool_bonus_history.cgi?address={MONERO_WALLET_ADDRESS}"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, timeout=10) as response:
                if response.status == 200:
                    html_data = await response.text()
                    return _parse_html_stats(html_data)
                else:
                    logger.error(f"XvB returned status {response.status}")
                    return None
    except Exception as e:
        logger.error(f"Failed to fetch XvB stats: {e}")
        return None

def _parse_html_stats(html_text):
    """
    Parses the HTML response to extract Fail Count and Hashrate averages.
    """
    try:
        stats = {
            "fail_count": 0,
            "1h_avg": 0.0,
            "24h_avg": 0.0
        }

        # Parse Fail Count
        fail_match = re.search(r"Fail Count:\s*(\d+)", html_text, re.IGNORECASE)
        if fail_match:
            stats["fail_count"] = int(fail_match.group(1))

        # Parse Hashrates (e.g., "1hr avg: 0.33kH/s")
        hr1_match = re.search(r"1hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", html_text, re.IGNORECASE)
        hr24_match = re.search(r"24hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", html_text, re.IGNORECASE)

        if hr1_match:
            stats["1h_avg"] = parse_hashrate(hr1_match.group(1), hr1_match.group(2))
        
        if hr24_match:
            stats["24h_avg"] = parse_hashrate(hr24_match.group(1), hr24_match.group(2))

        if not fail_match and not hr1_match:
            logger.warning("Could not find stats in XvB HTML. Layout may have changed.")
            return None

        return stats

    except Exception as e:
        logger.error(f"Error parsing XvB HTML: {e}")
        return None