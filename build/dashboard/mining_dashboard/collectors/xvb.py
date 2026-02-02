import asyncio
import aiohttp
import logging
import re
from config import MONERO_WALLET_ADDRESS  # Requires the full Monero Wallet Address
from utils import parse_hashrate

logger = logging.getLogger("XvB_Collector")

# Pre-compile regex patterns for performance and readability
REGEX_FAIL_COUNT = re.compile(r"Fail Count:\s*(\d+)", re.IGNORECASE)
REGEX_HR_1H = re.compile(r"1hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)
REGEX_HR_24H = re.compile(r"24hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)

XVB_API_URL = "https://xmrvsbeast.com/cgi-bin/p2pool_bonus_history.cgi"

async def fetch_xvb_stats():
    """
    Retrieves bonus history statistics from the XMRvsBeast service.

    Validates the configured Monero wallet address and parses the HTML response
    to extract mining performance metrics.

    Returns:
        dict or None: A dictionary containing 'fail_count', '1h_avg', and '24h_avg' 
                      if successful, otherwise None.
    """
    if not MONERO_WALLET_ADDRESS or MONERO_WALLET_ADDRESS == "placeholder":
        logger.warning("Configuration Error: MONERO_WALLET_ADDRESS is missing or invalid.")
        return None

    params = {"address": MONERO_WALLET_ADDRESS}

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(XVB_API_URL, params=params, timeout=10) as response:
                if response.status == 200:
                    html_data = await response.text()
                    return _parse_html_stats(html_data)
                else:
                    logger.error(f"XvB API request failed with status code: {response.status}")
                    return None
    except (aiohttp.ClientError, asyncio.TimeoutError) as e:
        logger.error(f"Network error while fetching XvB stats: {e}")
        return None
    except Exception as e:
        logger.error(f"Unexpected error in XvB collector: {e}")
        return None

def _parse_html_stats(html_text):
    """
    Parses raw HTML content to extract mining statistics.
    
    Args:
        html_text (str): The raw HTML response from the XvB service.
        
    Returns:
        dict or None: Parsed statistics or None if parsing fails.
    """
    try:
        stats = {
            "fail_count": 0,
            "1h_avg": 0.0,
            "24h_avg": 0.0
        }

        # Extract Fail Count
        fail_match = REGEX_FAIL_COUNT.search(html_text)
        if fail_match:
            stats["fail_count"] = int(fail_match.group(1))

        # Extract Hashrate Averages
        hr1_match = REGEX_HR_1H.search(html_text)
        hr24_match = REGEX_HR_24H.search(html_text)

        if hr1_match:
            stats["1h_avg"] = parse_hashrate(hr1_match.group(1), hr1_match.group(2))
        
        if hr24_match:
            stats["24h_avg"] = parse_hashrate(hr24_match.group(1), hr24_match.group(2))

        if not fail_match and not hr1_match:
            logger.warning("Parsing Warning: Critical stats not found in XvB response. HTML structure may have changed.")
            return None

        return stats

    except Exception as e:
        logger.error(f"Parsing Error: Failed to process XvB HTML: {e}")
        return None