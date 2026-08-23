import logging
import re
from datetime import UTC, datetime

import requests

from mining_dashboard.config.config import TOR_SOCKS_PROXY, XVB_SUBMIT_URL
from mining_dashboard.helper.http import bounded_get
from mining_dashboard.helper.utils import parse_hashrate

# The four donor tiers XvB publishes an expected per-player reward for. These are exactly the tier
# keys in TIER_DEFAULTS, so build_xvb_calc maps a tier straight to its estimate by key (#118).
DONOR_ROUND_TYPES = ("donor", "donor_vip", "donor_whale", "donor_mega")

# XvB publishes its own reward_calc.sh output as plain text — one "Round: <type> Player: <X>
# XMR/year" line per tier, kept current. We parse the four donor-tier Player figures and ignore the
# non-donor (vip/mvp) and pool-total ("Round: donor: N") rows; the "Player:" keyword disambiguates.
_REGEX_REWARD_LINE = re.compile(r"Round:\s*(\S+)\s+Player:\s*([\d.]+)\s*XMR/year", re.IGNORECASE)


def parse_reward_estimates(text):
    """Parse XvB's published per-tier expected rewards (XMR/year) from ``reward_estimate_pub.txt``.

    Returns ``{round_type: xmr_per_year}`` for the recognised donor tiers only — an EMPTY dict when
    the text is missing, empty, or has no parseable donor lines (a malformed file must never raise,
    just yield nothing). A tolerant regex keys off the ``Player:`` figure so the pool-total rows and
    the non-donor vip/mvp rows are skipped.
    """
    out = {}
    for round_type, value in _REGEX_REWARD_LINE.findall(text or ""):
        key = round_type.lower()
        if key in DONOR_ROUND_TYPES:
            try:
                out[key] = float(value)
            except (ValueError, TypeError):
                continue
    return out


# XvB's public raffle-winners log (`winners_recent_full_pub.txt`): one row per won round, newest
# first, covering roughly the last four days of hourly rounds. Wallets are masked to their first
# and last 8 characters, so matching our own wallet uses the same masked form. Splitting a row on
# whitespace yields 9 stable tokens — masked-wallet, date, time, hashrate, height, block-id,
# paid-ratio, position, round-type — which sidesteps the file's empty tab-separated column.
_WINNERS_FIELD_COUNT = 9

# Bounds on the UNTRUSTED winners file (security review): the legit file is ~4 days of hourly
# rounds (~100 lines), so these are ~50x headroom — a hostile/compromised response can neither
# make the parser chew an arbitrarily long body nor flood the permanent raffle_wins table with
# fabricated rows for our (publicly derivable) masked wallet in a single sync.
_WINNERS_MAX_LINES = 5000
_WINNERS_MAX_WINS = 200

# The hashrate token in a winners row, e.g. "4203.5kH/s" — value and unit, no space between them.
_REGEX_WINNER_HASHRATE = re.compile(r"([\d.]+)\s*([kKmMgG]?H/s)?$")


def mask_wallet(address):
    """The ``first8...last8`` masked form XvB uses for wallet addresses in its public files."""
    return f"{address[:8]}...{address[-8:]}"


def parse_winners(text, wallet_address):
    """Parse XvB's ``winners_recent_full_pub.txt`` and return THIS wallet's wins, oldest first.

    Each win is ``{ts, hashrate, height, block_id, tier}`` — ``ts`` in epoch seconds (the file's
    timestamps are UTC: its newest row tracks the hourly round cadence against UTC wall-clock),
    ``hashrate`` the credited rate XvB published for the win in H/s, ``tier`` the round type
    (e.g. ``donor_whale``). Rows for other wallets and malformed rows are skipped; a garbage file
    yields an empty list, never a raise (same tolerance as ``parse_reward_estimates``).
    """
    masked = mask_wallet(wallet_address or "")
    wins = []
    for line in (text or "").splitlines()[:_WINNERS_MAX_LINES]:
        if len(wins) >= _WINNERS_MAX_WINS:
            break
        fields = line.split()
        if len(fields) != _WINNERS_FIELD_COUNT or fields[0] != masked:
            continue
        try:
            ts = (
                datetime.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")
                .replace(tzinfo=UTC)
                .timestamp()
            )
            height = int(fields[4])
        except ValueError:
            continue
        hr_match = _REGEX_WINNER_HASHRATE.match(fields[3])
        hashrate = parse_hashrate(hr_match.group(1), hr_match.group(2)) if hr_match else 0.0
        wins.append(
            {
                "ts": ts,
                "hashrate": hashrate,
                "height": height,
                "block_id": fields[5],
                "tier": fields[8],
            }
        )
    wins.reverse()  # the file is newest-first; callers store/plot oldest-first
    return wins


def parse_round_stats(text):
    """Aggregate EVERY round in ``winners_recent_full_pub.txt`` — not just ours (#866/#872).

    The file's ``players`` column is the qualifier count for each round, which makes two honest
    figures computable that XvB's published estimates gloss over: how often a tier is drawn
    (rounds of that type per day) and against how many qualifiers (players average). Returns
    ``{"types": {round_type: {"rounds": n, "players_avg": x}}, "span_days": d}`` — an empty
    ``types`` dict for a garbage/empty file, never a raise (same tolerance and input bounds as
    ``parse_winners``; the two parse the SAME fetched body, one request)."""
    types = {}
    first_ts = last_ts = None
    for line in (text or "").splitlines()[:_WINNERS_MAX_LINES]:
        fields = line.split()
        if len(fields) != _WINNERS_FIELD_COUNT:
            continue
        try:
            ts = (
                datetime.strptime(f"{fields[1]} {fields[2]}", "%Y-%m-%d %H:%M:%S")
                .replace(tzinfo=UTC)
                .timestamp()
            )
            players = int(fields[7])
        except ValueError:
            continue
        if players <= 0:
            continue
        first_ts = ts if first_ts is None else max(first_ts, ts)
        last_ts = ts if last_ts is None else min(last_ts, ts)
        agg = types.setdefault(fields[8], {"rounds": 0, "players_sum": 0})
        agg["rounds"] += 1
        agg["players_sum"] += players
    span_days = (first_ts - last_ts) / 86400.0 if first_ts is not None else 0.0
    return {
        "types": {
            t: {"rounds": a["rounds"], "players_avg": a["players_sum"] / a["rounds"]}
            for t, a in types.items()
        },
        "span_days": span_days,
    }


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
        # XvB's pre-computed per-tier expected rewards (their own reward_calc.sh output, kept
        # current). Fetched over the SAME Tor proxy as the stats so the dashboard never reimplements
        # reward_calc or needs Monero difficulty/reward (#118). Carries no wallet, so no IP<->wallet
        # correlation risk — but routed over Tor anyway to keep all XvB egress on one path.
        self.reward_estimate_url = "https://xmrvsbeast.com/p2pool/reward_estimate_pub.txt"
        # XvB's public raffle-winners log (see parse_winners). Carries no full wallet (masked
        # rows only) and our request sends none — but routed over Tor with the rest anyway.
        self.winners_url = "https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt"
        self.tor_proxy = tor_proxy if tor_proxy is not None else TOR_SOCKS_PROXY
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
            response = bounded_get(self.url, params=params, timeout=20, proxies=proxies)
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

    def get_reward_estimates(self):
        """Fetch XvB's published per-tier expected rewards (XMR/year) over Tor (#118).

        Returns ``{round_type: xmr_per_year}`` for the donor tiers on success, or ``None`` on a
        failed fetch OR an unparseable body — same "None means keep the last good reading frozen"
        contract as ``get_stats`` (the caller writes nothing on None, so a stale/failed fetch can be
        detected via a frozen ``last_update`` and never implied fresh, #311).
        """
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            response = bounded_get(self.reward_estimate_url, timeout=20, proxies=proxies)
            if response.status_code != 200:
                self.logger.error(
                    f"XvB reward-estimate fetch failed with status code: {response.status_code}"
                )
                return None
            estimates = parse_reward_estimates(response.text)
            if not estimates:
                self.logger.warning(
                    "XvB reward-estimate parse found no donor tiers — file format may have changed."
                )
                return None
            return estimates
        except requests.RequestException as e:
            self.logger.error(f"Network error while fetching XvB reward estimates: {e}")
            return None
        except Exception as e:
            self.logger.error(f"Unexpected error fetching XvB reward estimates: {e}")
            return None

    def get_recent_wins(self):
        """Fetch XvB's public raffle-winners log over Tor — ONE request, both parses.

        Returns ``{"wins": [...], "round_stats": {...}}``: ``wins`` is THIS wallet's wins oldest
        first (``parse_winners``; an empty list is a normal read — no wins in the file's ~4-day
        window), ``round_stats`` the all-rounds aggregate (``parse_round_stats``, #866/#872).
        ``None`` means the fetch failed — same "None means keep what you have" contract as
        ``get_stats``, so the caller writes nothing and retries later. The file carries only
        masked wallets and the request carries none, so there's no IP<->wallet correlation
        risk — but it rides the same Tor proxy as every other XvB fetch to keep all XvB
        egress on one path (#163).
        """
        if not self.wallet_address or self.wallet_address == "placeholder":
            self.logger.warning("Configuration Error: MONERO_WALLET_ADDRESS is missing or invalid.")
            return None

        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            response = bounded_get(self.winners_url, timeout=20, proxies=proxies)
            if response.status_code != 200:
                self.logger.error(
                    f"XvB winners fetch failed with status code: {response.status_code}"
                )
                return None
            return {
                "wins": parse_winners(response.text, self.wallet_address),
                "round_stats": parse_round_stats(response.text),
            }
        except requests.RequestException as e:
            self.logger.error(f"Network error while fetching XvB winners: {e}")
            return None
        except Exception as e:
            self.logger.error(f"Unexpected error fetching XvB winners: {e}")
            return None

    def register(self):
        """
        Enter the wallet into the XMRvsBeast raffle (#263).

        Mining to the XvB pool isn't enough to be entered — the wallet must be registered against
        the operator's submit endpoint. That endpoint registers the wallet ONLY if it already has a
        share in the P2Pool PPLNS window, so callers should gate this on PPLNS-share eligibility;
        before a share lands server-side the call is a harmless no-op and we just retry next poll.

        ALWAYS routes over the SAME Tor SOCKS5 proxy as get_stats (TOR_SOCKS_PROXY) — the call carries
        the FULL wallet address, so a clearnet request would correlate the operator's IP with the
        wallet (#163). Like the stats fetch, this is NOT subject to the xvb.tor donation opt-out.

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
            response = bounded_get(self.submit_url, params=params, timeout=20, proxies=proxies)
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
