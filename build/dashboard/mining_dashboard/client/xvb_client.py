import logging
import re

import requests

from mining_dashboard.config.config import XVB_SUBMIT_URL, XVB_TOR_PROXY
from mining_dashboard.helper.utils import parse_hashrate

# register() outcomes (#263). The endpoint returns plaintext "ERROR: ..." with a 422 for the error
# cases (not a 200/JSON contract), so success/failure is classified from status + body, not status
# alone. The caller maps these to dashboard state + retry behaviour.
REG_OK = "registered"  # 2xx (fresh) OR "already registered" (idempotent) — wallet is in the raffle
REG_INVALID = "invalid_wallet"  # endpoint rejected the address — permanent, stop retrying
REG_NOT_ELIGIBLE = "not_eligible"  # no PPLNS share server-side yet — retry quietly, don't alarm
REG_ERROR = "error"  # 5xx / network / unknown shape — transient, retry
REG_DISABLED = "disabled"  # no endpoint configured (XVB_SUBMIT_URL disabled) — caller skips


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
        share in the P2Pool PPLNS window, so callers should gate this on PPLNS-share eligibility;
        before a share lands server-side the call is a harmless no-op and we just retry next poll.

        Routes over the SAME Tor SOCKS5 proxy as get_stats — the call carries the FULL wallet
        address, so a clearnet request would correlate the operator's IP with the wallet (#163).

        The endpoint does NOT use a 200/JSON contract — it returns a plaintext ``ERROR: ...`` body
        with HTTP 422 for the error cases — so the outcome is classified from status AND body
        (verified live, see config). Returns one of the module ``REG_*`` strings:
            REG_OK         — 2xx, or "already registered" (idempotent; the wallet is in the raffle)
            REG_INVALID    — endpoint rejected the address (permanent; caller stops retrying)
            REG_NOT_ELIGIBLE — no PPLNS share server-side yet (retry quietly)
            REG_ERROR      — 5xx / network / unrecognised shape (transient; retry)
            REG_DISABLED   — no endpoint configured (XVB_SUBMIT_URL disabled)
        """
        if not self.submit_url:
            # Endpoint disabled (XVB_SUBMIT_URL set to a disable sentinel): we never reach out.
            self.logger.debug("XvB registration skipped: endpoint disabled.")
            return REG_DISABLED

        if not self.wallet_address or self.wallet_address == "placeholder":
            self.logger.warning(
                "XvB registration skipped: MONERO_WALLET_ADDRESS is missing or invalid."
            )
            return REG_INVALID

        params = {"address": self.wallet_address}

        # Same Tor routing as the stats fetch: socks5h so xmrvsbeast sees a Tor exit (not the
        # operator's home IP) and the host is resolved over Tor too. The request carries the full
        # wallet, so a clearnet call would correlate IP <-> wallet (#163).
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            response = requests.get(self.submit_url, params=params, timeout=20, proxies=proxies)
            body = (response.text or "").strip()
            low = body.lower()

            # Fresh registration: the endpoint answers 2xx.
            if 200 <= response.status_code < 300:
                return REG_OK
            # Idempotent: re-registering an entered wallet returns 422 "Already Registered". That's
            # the steady state once we're in — treat it as success so the daily re-register is a
            # no-op rather than a "failure".
            if "already registered" in low:
                return REG_OK
            # Permanent: a wallet the endpoint won't accept (e.g. wrong address type). Don't hammer.
            if "invalid wallet" in low:
                self.logger.warning("XvB registration: endpoint rejected the wallet as invalid.")
                return REG_INVALID
            # Best-effort: the share hasn't propagated to XvB yet. We can't pin the exact wording
            # (we only have the already-registered/invalid samples), so match the obvious tokens and
            # otherwise fall through to a retryable error.
            if "pplns" in low or "share" in low or "window" in low:
                return REG_NOT_ELIGIBLE
            # Anything else (5xx, an unrecognised body) — log it so a contract change surfaces.
            self.logger.warning(
                "XvB registration: unexpected response (HTTP %s): %s",
                response.status_code,
                body[:200],
            )
            return REG_ERROR
        except requests.RequestException as e:
            self.logger.error(f"Network error while registering with XvB: {e}")
            return REG_ERROR
        except Exception as e:
            self.logger.error(f"Unexpected error during XvB registration: {e}")
            return REG_ERROR

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
