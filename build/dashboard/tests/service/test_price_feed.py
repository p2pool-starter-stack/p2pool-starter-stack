"""Tests for the opt-in XMR/XTM price feed over Tor (#520)."""

from unittest.mock import MagicMock, patch

import requests

from mining_dashboard.service.price_feed import CoinGeckoClient, PriceFeed, parse_prices


class TestParsePrices:
    def test_parses_both_coins_in_currency(self):
        data = {"monero": {"usd": 333.97}, "minotari": {"usd": 0.0004}}
        assert parse_prices(data, "USD") == {"xmr": 333.97, "tari": 0.0004}

    def test_currency_is_case_insensitive(self):
        data = {"monero": {"eur": 292.0}, "minotari": {"eur": 0.0003}}
        assert parse_prices(data, "EUR") == {"xmr": 292.0, "tari": 0.0003}

    def test_missing_either_coin_is_none(self):
        # Both-or-nothing: a lone XMR price must not half-update the pair.
        assert parse_prices({"monero": {"usd": 333.0}}, "USD") is None
        assert parse_prices({"minotari": {"usd": 0.0004}}, "USD") is None

    def test_unsupported_currency_is_none(self):
        data = {"monero": {"usd": 333.0}, "minotari": {"usd": 0.0004}}
        assert parse_prices(data, "XYZ") is None

    def test_garbage_and_nonpositive_are_none(self):
        assert parse_prices({"monero": None, "minotari": None}, "USD") is None
        assert parse_prices({"monero": {"usd": "x"}, "minotari": {"usd": 1}}, "USD") is None
        assert parse_prices({"monero": {"usd": 0}, "minotari": {"usd": 0.0004}}, "USD") is None
        assert parse_prices({"monero": {"usd": -1}, "minotari": {"usd": 0.0004}}, "USD") is None

    def test_nonfinite_is_none(self):
        # json.loads accepts the NaN/Infinity tokens and NaN <= 0 is False — a hostile response
        # must never push a non-finite number into /api/state (it would serialize as invalid JSON).
        for evil in (float("nan"), float("inf"), float("-inf")):
            assert parse_prices({"monero": {"usd": evil}, "minotari": {"usd": 1}}, "USD") is None
            assert parse_prices({"monero": {"usd": 1}, "minotari": {"usd": evil}}, "USD") is None


class TestCoinGeckoClient:
    def _resp(self, status=200, payload=None):
        r = MagicMock()
        r.status_code = status
        r.json.return_value = payload if payload is not None else {}
        return r

    def test_fetches_both_coins_over_tor(self):
        c = CoinGeckoClient("USD", tor_proxy="socks5h://t:9050")
        payload = {"monero": {"usd": 333.97}, "minotari": {"usd": 0.0004}}
        with patch(
            "mining_dashboard.service.price_feed.requests.get",
            return_value=self._resp(200, payload),
        ) as g:
            assert c.fetch() == {"xmr": 333.97, "tari": 0.0004}
            # routed through the Tor proxy, asking for both coin ids in the operator's currency
            assert g.call_args.kwargs["proxies"] == {
                "http": "socks5h://t:9050",
                "https": "socks5h://t:9050",
            }
            assert g.call_args.kwargs["params"] == {
                "ids": "monero,minotari",
                "vs_currencies": "usd",
            }

    def test_non_200_is_silent_none(self):
        c = CoinGeckoClient("USD")
        with patch(
            "mining_dashboard.service.price_feed.requests.get", return_value=self._resp(429)
        ):
            assert c.fetch() is None

    def test_network_error_is_silent_none(self):
        c = CoinGeckoClient("USD")
        with patch(
            "mining_dashboard.service.price_feed.requests.get",
            side_effect=requests.RequestException("offline"),
        ):
            assert c.fetch() is None

    def test_non_alphabetic_currency_never_dials_out(self):
        # `currency` is a free-form display label elsewhere (and dashboard-committable, #504);
        # only a plain alphabetic code may leave the host as a query parameter — anything else
        # must mean NO request at all, not a sanitized one.
        for label in ("US Dollar$", "usd&x=exfil", "a" * 6, ""):
            c = CoinGeckoClient(label, tor_proxy="socks5h://t:9050")
            with patch("mining_dashboard.service.price_feed.requests.get") as g:
                assert c.fetch() is None
                g.assert_not_called()


class _FakeClient:
    def __init__(self, prices=None, currency="USD"):
        self.prices = prices
        self.currency = currency
        self.calls = 0

    def fetch(self):
        self.calls += 1
        return self.prices


class TestPriceFeed:
    def test_disabled_never_calls_and_returns_none(self):
        c = _FakeClient({"xmr": 300.0, "tari": 0.0004})
        pf = PriceFeed(c, enabled=False)
        assert pf.maybe_fetch(1000) is None
        assert c.calls == 0

    def test_enabled_returns_prices_with_stamp(self):
        pf = PriceFeed(_FakeClient({"xmr": 300.0, "tari": 0.0004}), enabled=True)
        assert pf.maybe_fetch(1000) == {
            "xmr": 300.0,
            "tari": 0.0004,
            "currency": "USD",
            "fetched_at": 1000,
        }

    def test_throttles_to_interval(self):
        c = _FakeClient({"xmr": 300.0, "tari": 0.0004})
        pf = PriceFeed(c, enabled=True, interval=900)
        pf.maybe_fetch(1000)
        pf.maybe_fetch(1000 + 600)  # within window -> cached, no network
        assert c.calls == 1
        pf.maybe_fetch(1000 + 901)  # past window -> network again
        assert c.calls == 2

    def test_failed_fetch_keeps_previous_prices(self):
        c = _FakeClient({"xmr": 300.0, "tari": 0.0004})
        pf = PriceFeed(c, enabled=True, interval=0)
        pf.maybe_fetch(1000)
        c.prices = None  # feed goes dark
        out = pf.maybe_fetch(2000)
        # a blip must not drop the last good prices — the UI shows their age instead
        assert out["xmr"] == 300.0
        assert out["fetched_at"] == 1000

    def test_no_result_before_first_success(self):
        pf = PriceFeed(_FakeClient(None), enabled=True, interval=0)
        assert pf.maybe_fetch(1000) is None
