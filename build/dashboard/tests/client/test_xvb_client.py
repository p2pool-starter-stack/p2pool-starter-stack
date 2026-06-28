from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.client.xvb_client as xvb_mod
from mining_dashboard.client.xvb_client import XvbClient

SAMPLE_HTML = "Fail Count: 2\n1hr avg: 1.5 kH/s\n24hr avg: 3.0 kH/s\n"


def test_missing_wallet_returns_none():
    assert XvbClient("").get_stats() is None
    assert XvbClient("placeholder").get_stats() is None


def test_get_stats_success_parses_html():
    client = XvbClient("49abc")
    resp = MagicMock(status_code=200, text=SAMPLE_HTML)
    with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
        stats = client.get_stats()
    assert stats == {"fail_count": 2, "avg_1h": 1500.0, "avg_24h": 3000.0}
    assert mock_get.call_args.kwargs["params"] == {"address": "49abc"}


def test_get_stats_routes_through_tor_proxy():
    # #163: the fetch must go through the Tor SOCKS proxy so xmrvsbeast sees a Tor exit, not the
    # operator's home IP — the request carries the wallet, so a clearnet fetch would correlate them.
    client = XvbClient("49abc")
    resp = MagicMock(status_code=200, text=SAMPLE_HTML)
    with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
        client.get_stats()
    proxies = mock_get.call_args.kwargs["proxies"]
    assert proxies["https"].startswith("socks5h://")  # socks5h resolves the host via Tor too
    assert proxies["http"] == proxies["https"]


def test_get_stats_honours_explicit_proxy():
    client = XvbClient("49abc", tor_proxy="socks5h://127.0.0.1:9999")
    resp = MagicMock(status_code=200, text=SAMPLE_HTML)
    with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
        client.get_stats()
    assert mock_get.call_args.kwargs["proxies"]["https"] == "socks5h://127.0.0.1:9999"


def test_get_stats_non_200_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", return_value=MagicMock(status_code=503)):
        assert client.get_stats() is None


def test_get_stats_network_error_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", side_effect=requests.RequestException("boom")):
        assert client.get_stats() is None


_SUBMIT = (
    "https://xmrvsbeast.example/submit.cgi"  # placeholder; real endpoint is unpublished (#263)
)


class TestRegister:
    def test_no_endpoint_configured_is_noop(self):
        # Public default: XVB_SUBMIT_URL unset => never reach out at all (no clearnet/Tor call).
        client = XvbClient("49abc", submit_url="")
        with patch.object(xvb_mod.requests, "get") as mock_get:
            assert client.register() is False
        mock_get.assert_not_called()

    def test_missing_wallet_is_noop(self):
        client = XvbClient("", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get") as mock_get:
            assert client.register() is False
        mock_get.assert_not_called()
        assert XvbClient("placeholder", submit_url=_SUBMIT).register() is False

    def test_success_sends_full_wallet(self):
        client = XvbClient("49fullwalletaddress", submit_url=_SUBMIT)
        resp = MagicMock(status_code=200, text="ok")
        with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
            assert client.register() is True
        # Registration takes the FULL wallet address as ?address=...
        assert mock_get.call_args.kwargs["params"] == {"address": "49fullwalletaddress"}
        assert mock_get.call_args.args[0] == _SUBMIT

    def test_routes_through_tor_proxy(self):
        # #163: the call carries the full wallet, so it must ride the Tor SOCKS proxy like get_stats.
        client = XvbClient("49abc", submit_url=_SUBMIT)
        resp = MagicMock(status_code=200, text="ok")
        with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
            client.register()
        proxies = mock_get.call_args.kwargs["proxies"]
        assert proxies["https"].startswith("socks5h://")
        assert proxies["http"] == proxies["https"]

    def test_non_200_returns_false(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", return_value=MagicMock(status_code=503)):
            assert client.register() is False

    def test_network_error_returns_false(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", side_effect=requests.RequestException("boom")):
            assert client.register() is False

    def test_unexpected_error_returns_false(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", side_effect=ValueError("kaboom")):
            assert client.register() is False


class TestParseHtml:
    def test_fail_count_only(self):
        client = XvbClient("49abc")
        stats = client._parse_html("Fail Count: 5\n1hr avg: 0 H/s")
        assert stats["fail_count"] == 5

    def test_no_critical_stats_returns_none(self):
        client = XvbClient("49abc")
        assert client._parse_html("<html>nothing useful</html>") is None

    def test_hashrate_units(self):
        client = XvbClient("49abc")
        stats = client._parse_html("1hr avg: 2 MH/s\n24hr avg: 1 GH/s")
        assert stats["avg_1h"] == 2_000_000.0
        assert stats["avg_24h"] == 1_000_000_000.0
