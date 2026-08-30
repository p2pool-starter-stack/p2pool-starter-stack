"""Live XMR/XTM price feed (#520's deferred auto half) — opt-in, over Tor.

When ``dashboard.energy.price_feed`` is enabled (default OFF), the dashboard periodically fetches
the spot price of Monero and Tari in the operator's ``dashboard.energy.currency`` from CoinGecko
and uses them in place of the static ``xmr_price`` / ``tari_price`` numbers, so the calculator's
fiat figures track the market instead of going stale. CoinGecko is the one source that quotes both
coins in one call with no API key (CoinDesk doesn't list XTM; Yahoo has no stable free JSON API).

Privacy: the fetch is **opt-in (default off)** and routed over the bridge **Tor SOCKS** (reusing
``TOR_SOCKS_PROXY``, the same path as the update check #224 and XvB stats #163), so enabling it
never reveals the host IP to CoinGecko. Every failure path is silent: a failed fetch keeps the last
good prices (the UI marks their age) and the static config prices remain the fallback until the
first fetch lands.
"""

import logging
import math
import re

import requests

from mining_dashboard.helper.http import bounded_get

logger = logging.getLogger("PriceFeed")

COINGECKO_SIMPLE_PRICE = "https://api.coingecko.com/api/v3/simple/price"
# CoinGecko coin ids for the two chains this stack mines. Tari is listed as "minotari" (XTM).
COINGECKO_IDS = {"xmr": "monero", "tari": "minotari"}


def parse_prices(data, currency) -> dict | None:
    """``{"xmr": float, "tari": float}`` from a CoinGecko ``simple/price`` payload, or ``None``
    when either coin (or the requested currency) is missing/invalid. Both-or-nothing on purpose:
    a pair from two different fetches could disagree on the exchange rate. Pure + unit-tested."""
    cur = currency.lower()
    try:
        xmr = float(data[COINGECKO_IDS["xmr"]][cur])
        tari = float(data[COINGECKO_IDS["tari"]][cur])
    except (KeyError, TypeError, ValueError):
        return None
    # Reject non-finite explicitly: json.loads accepts the NaN/Infinity tokens, NaN <= 0 is False,
    # and a NaN reaching /api/state would serialize as invalid JSON and break the whole dashboard
    # fetch — a hostile response must degrade to "no fetch", never past this gate.
    if not (math.isfinite(xmr) and math.isfinite(tari)) or xmr <= 0 or tari <= 0:
        return None
    return {"xmr": xmr, "tari": tari}


class CoinGeckoClient:
    """Fetches the XMR + XTM spot prices from CoinGecko, fail-silent over Tor."""

    def __init__(self, currency, tor_proxy=None):
        self.currency = currency
        self.tor_proxy = tor_proxy

    def fetch(self) -> dict | None:
        """Return ``{"xmr": ..., "tari": ...}`` in ``self.currency``, or ``None`` on any failure
        (network, non-200, malformed JSON, unsupported currency). Routed through Tor when set."""
        # ``currency`` doubles as a free-form display label (any printable ASCII passes pithead's
        # validation, and dashboard.energy is dashboard-committable, #504) — but only a plain
        # alphabetic code may leave the host as a query parameter, so a committed label can never
        # become an exfil channel through the feed's URL. Anything else: no fetch, static fallback.
        if not re.fullmatch(r"[A-Za-z]{2,5}", self.currency):
            return None
        proxies = {"http": self.tor_proxy, "https": self.tor_proxy} if self.tor_proxy else None
        try:
            resp = bounded_get(
                COINGECKO_SIMPLE_PRICE,
                params={
                    "ids": ",".join(COINGECKO_IDS.values()),
                    "vs_currencies": self.currency.lower(),
                },
                timeout=20,
                proxies=proxies,
                headers={"User-Agent": "pithead-dashboard"},
            )
            if resp.status_code != 200:
                return None
            return parse_prices(resp.json(), self.currency)
        except (requests.RequestException, ValueError) as e:
            logger.debug("Price fetch failed (kept silent): %s", e)
            return None


class PriceFeed:
    """Throttled wrapper around the client (the ``UpdateChecker`` pattern, #224). ``maybe_fetch``
    hits the network at most once per ``interval`` and otherwise returns the cached result; a
    failed fetch keeps the previous prices (the UI shows their age) rather than dropping them."""

    def __init__(self, client, enabled, interval=900):
        self.client = client
        self.enabled = enabled
        self.interval = interval
        self._last = 0.0
        self.result = None

    def maybe_fetch(self, now):
        """Return the cached ``{xmr, tari, currency, fetched_at}`` (or ``None`` before the first
        successful fetch). Performs the (blocking) fetch only when enabled and the throttle window
        has elapsed — call via ``asyncio.to_thread``."""
        if not self.enabled:
            self.result = None
            return None
        if self._last and (now - self._last) < self.interval:
            return self.result
        self._last = now
        prices = self.client.fetch()
        if prices:
            self.result = {**prices, "currency": self.client.currency, "fetched_at": now}
        return self.result
