import requests
import logging
import re
from helper.utils import parse_hashrate

class XvbClient:
    def __init__(self, wallet_address):
        """
        Initialize the XvB Client.
        
        :param wallet_address: The Monero wallet address to query stats for.
        """
        self.logger = logging.getLogger("XvbClient")
        self.wallet_address = wallet_address
        self.url = "https://xmrvsbeast.com/cgi-bin/p2pool_bonus_history.cgi"
        
        # Pre-compile regex patterns
        self.REGEX_FAIL_COUNT = re.compile(r"Fail Count:\s*(\d+)", re.IGNORECASE)
        self.REGEX_HR_1H = re.compile(r"1hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)
        self.REGEX_HR_24H = re.compile(r"24hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)

    def get_stats(self):
        """
        Retrieves bonus history statistics from the XMRvsBeast service.
        
        Returns:
            dict or None: A dictionary containing 'fail_count', '1h_avg', and '24h_avg' 
                          if successful, otherwise None.
        """
        if not self.wallet_address or self.wallet_address == "placeholder":
            self.logger.warning("Configuration Error: MONERO_WALLET_ADDRESS is missing or invalid.")
            return None

        params = {"address": self.wallet_address}

        try:
            response = requests.get(self.url, params=params, timeout=10)
            if response.status_code == 200:
                return self._parse_html(response.text)
            else:
                self.logger.error(f"XvB API request failed with status code: {response.status_code}")
                return None
        except requests.RequestException as e:
            self.logger.error(f"Network error while fetching XvB stats: {e}")
            return None
        except Exception as e:
            self.logger.error(f"Unexpected error in XvB client: {e}")
            return None

    def _parse_html(self, html_text):
        """
        Parses raw HTML content to extract mining statistics.
        """
        try:
            stats = {
                "fail_count": 0,
                "1h_avg": 0.0,
                "24h_avg": 0.0
            }

            # Extract Fail Count
            fail_match = self.REGEX_FAIL_COUNT.search(html_text)
            if fail_match:
                stats["fail_count"] = int(fail_match.group(1))

            # Extract Hashrate Averages
            hr1_match = self.REGEX_HR_1H.search(html_text)
            hr24_match = self.REGEX_HR_24H.search(html_text)

            if hr1_match:
                stats["1h_avg"] = parse_hashrate(hr1_match.group(1), hr1_match.group(2))
            
            if hr24_match:
                stats["24h_avg"] = parse_hashrate(hr24_match.group(1), hr24_match.group(2))

            if not fail_match and not hr1_match:
                self.logger.warning("Parsing Warning: Critical stats not found in XvB response. HTML structure may have changed.")
                return None

            return stats

        except Exception as e:
            self.logger.error(f"Parsing Error: Failed to process XvB HTML: {e}")
            return None