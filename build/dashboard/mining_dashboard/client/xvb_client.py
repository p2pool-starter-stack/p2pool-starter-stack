import logging
import re

import requests

from mining_dashboard.config.config import XVB_SUBMIT_URL, XVB_TOR_PROXY
from mining_dashboard.helper.utils import parse_hashrate


class XvbClient:
    def __init__(self, wallet_address, tor_proxy=None, submit_url=None):
        """
        Initialize the XvB Client.

        :param wallet_address: The Monero wallet address to query stats for.
        :param tor_proxy: SOCKS proxy URL to route the stats fetch through (defaults to the bridge
            Tor SOCKS, so the request can't correlate the operator's IP with the wallet, #163).
        :param submit_url: Raffle-registration endpoint (#263). Deliberately UNPUBLISHED by the XvB
            operator, so it is never hard-coded here — it's injected via XVB_SUBMIT_URL at deploy
            time. Empty => register() is a no-op (we still mine to XvB and read stats).
        """
        self.logger = logging.getLogger("XvbClient")
        self.wallet_address = wallet_address
        self.url = "https://xmrvsbeast.com/cgi-bin/p2pool_bonus_history.cgi"
        self.tor_proxy = tor_proxy if tor_proxy is not None else XVB_TOR_PROXY
        self.submit_url = submit_url if submit_url is not None else XVB_SUBMIT_URL

        # Pre-compile regex patterns
        self.REGEX_FAIL_COUNT = re.compile(r"Fail Count:\s*(\d+)", re.IGNORECASE)
        self.REGEX_HR_1H = re.compile(r"1hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)
        self.REGEX_HR_24H = re.compile(r"24hr avg:\s*([\d\.]+)\s*([kKmMgG]?H/s)?", re.IGNORECASE)

    def get_stats(self):
        """
        Retrieves bonus history statistics from the XMRvsBeast service.

        Returns:
            dict or None: A dictionary containing 'fail_count', 'avg_1h', and 'avg_24h'
                          if successful, otherwise None.
        """
        if not self.wallet_address or self.wallet_address == "placeholder":
            self.logger.warning("Configuration Error: MONERO_WALLET_ADDRESS is missing or invalid.")
            return None

        params = {"address": self.wallet_address}

        # Route through Tor (socks5h) so xmrvsbeast sees a Tor exit, not the operator's home IP —
        # the request carries the wallet, so a clearnet fetch would correlate IP <-> wallet (#163).
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            response = requests.get(self.url, params=params, timeout=20, proxies=proxies)
            if response.status_code == 200:
                return self._parse_html(response.text)
            else:
                self.logger.error(
                    f"XvB API request failed with status code: {response.status_code}"
                )
                return None
        except requests.RequestException as e:
            self.logger.error(f"Network error while fetching XvB stats: {e}")
            return None
        except Exception as e:
            self.logger.error(f"Unexpected error in XvB client: {e}")
            return None

    def register(self):
        """
        Enter the wallet into the XMRvsBeast raffle (#263).

        Mining to the XvB pool isn't enough to be entered — the wallet must be registered against
        the operator's submit endpoint. That endpoint registers the wallet ONLY if it already has a
        share in the P2Pool PPLNS window, so callers must gate this on PPLNS-share eligibility;
        before a share lands server-side the call is a harmless no-op and we just retry next poll.

        Routes over the SAME Tor SOCKS5 proxy as get_stats — the call carries the FULL wallet
        address, so a clearnet request would correlate the operator's IP with the wallet (#163).

        Returns:
            bool: True on a 200 from the endpoint; False otherwise — including when no submit
                  endpoint is configured (XVB_SUBMIT_URL unset) or the wallet is missing/invalid.
        """
        if not self.submit_url:
            # No endpoint injected (public default): we never reach out at all.
            self.logger.debug("XvB registration skipped: no submit endpoint configured.")
            return False

        if not self.wallet_address or self.wallet_address == "placeholder":
            self.logger.warning(
                "XvB registration skipped: MONERO_WALLET_ADDRESS is missing or invalid."
            )
            return False

        params = {"address": self.wallet_address}

        # Same Tor routing as the stats fetch: socks5h so xmrvsbeast sees a Tor exit (not the
        # operator's home IP) and the host is resolved over Tor too. The request carries the full
        # wallet, so a clearnet call would correlate IP <-> wallet (#163).
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            response = requests.get(self.submit_url, params=params, timeout=20, proxies=proxies)
            if response.status_code == 200:
                return True
            self.logger.error(
                f"XvB registration request failed with status code: {response.status_code}"
            )
            return False
        except requests.RequestException as e:
            self.logger.error(f"Network error while registering with XvB: {e}")
            return False
        except Exception as e:
            self.logger.error(f"Unexpected error during XvB registration: {e}")
            return False

    def _parse_html(self, html_text):
        """
        Parses raw HTML content to extract mining statistics.
        """
        try:
            stats = {"fail_count": 0, "avg_1h": 0.0, "avg_24h": 0.0}

            # Extract Fail Count
            fail_match = self.REGEX_FAIL_COUNT.search(html_text)
            if fail_match:
                stats["fail_count"] = int(fail_match.group(1))

            # Extract Hashrate Averages
            hr1_match = self.REGEX_HR_1H.search(html_text)
            hr24_match = self.REGEX_HR_24H.search(html_text)

            if hr1_match:
                stats["avg_1h"] = parse_hashrate(hr1_match.group(1), hr1_match.group(2))

            if hr24_match:
                stats["avg_24h"] = parse_hashrate(hr24_match.group(1), hr24_match.group(2))

            if not fail_match and not hr1_match:
                self.logger.warning(
                    "Parsing Warning: Critical stats not found in XvB response. HTML structure may have changed."
                )
                return None

            return stats

        except Exception as e:
            self.logger.error(f"Parsing Error: Failed to process XvB HTML: {e}")
            return None
