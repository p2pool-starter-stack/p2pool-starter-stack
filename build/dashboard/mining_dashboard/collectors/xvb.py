import aiohttp
import re
import logging
from config import XVB_REWARD_URL, API_TIMEOUT

logger = logging.getLogger("XvB_Collector")

async def fetch_xvb_tiers():
    """
    Scrapes the XvB Estimated Reward page to find dynamic tier limits.
    Returns a dict with hashrate requirements in H/s.
    """
    # Default structure based on your provided list
    tiers = {
        "donor_mega": 0,
        "donor_whale": 0,
        "donor_vip": 0,
        "mvp": 0,
        "vip": 0,
        "donor": 0
    }
    
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(XVB_REWARD_URL, timeout=API_TIMEOUT) as response:
                if response.status != 200:
                    logger.error(f"Failed to fetch XvB page: {response.status}")
                    return None
                
                html = await response.text()
                html_lower = html.lower()

                # Regex patterns to find requirements. 
                # Looks for the tier name followed eventually by a number and a unit.
                # Example matching: "Mega ... > 1 MH/s" or "Mega ... 1000 kH/s"
                patterns = {
                    "donor_mega":  r"mega.*?>\s*(\d+(?:\.\d+)?)\s*(mh/s|kh/s|h/s)",
                    "donor_whale": r"whale.*?>\s*(\d+(?:\.\d+)?)\s*(mh/s|kh/s|h/s)",
                    "donor_vip":   r"vip.*?>\s*(\d+(?:\.\d+)?)\s*(mh/s|kh/s|h/s)",
                    "mvp":         r"mvp.*?>\s*(\d+(?:\.\d+)?)\s*(mh/s|kh/s|h/s)",
                    "donor":       r"donor.*?>\s*(\d+(?:\.\d+)?)\s*(mh/s|kh/s|h/s)"
                }

                found_any = False
                for tier_key, regex in patterns.items():
                    match = re.search(regex, html_lower)
                    if match:
                        val = float(match.group(1))
                        unit = match.group(2)
                        
                        # Normalize to H/s
                        if "mh/s" in unit: val *= 1_000_000
                        elif "kh/s" in unit: val *= 1_000
                        
                        tiers[tier_key] = int(val)
                        found_any = True
                        logger.info(f"XvB: Detected {tier_key} limit: {int(val)} H/s")
                
                # If scraping fails completely (page layout change), return None to keep old defaults
                if not found_any:
                    logger.warning("XvB: Could not parse any tier limits from page.")
                    return None

                return tiers

    except Exception as e:
        logger.error(f"Error scraping XvB tiers: {e}")
        return None