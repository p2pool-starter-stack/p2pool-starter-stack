from unittest.mock import patch, MagicMock

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
