from unittest.mock import MagicMock, patch

import requests

import mining_dashboard.client.xvb_client as xvb_mod
from mining_dashboard.client.xvb_client import (
    REG_DISABLED,
    REG_ERROR,
    REG_INVALID,
    REG_NOT_ELIGIBLE,
    REG_OK,
    XvbClient,
)

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


def test_get_stats_unexpected_error_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", side_effect=ValueError("kaboom")):
        assert client.get_stats() is None


_SUBMIT = (
    "https://xmrvsbeast.example/submit.cgi"  # placeholder; real endpoint is unpublished (#263)
)


def _resp(status, text=""):
    return MagicMock(status_code=status, text=text)


class TestRegister:
    """register() classifies the endpoint's real contract (status + body), verified live (#263)."""

    def test_disabled_when_no_endpoint(self):
        # Disable sentinel => empty submit_url => never reach out at all.
        client = XvbClient("49abc", submit_url="")
        with patch.object(xvb_mod.requests, "get") as mock_get:
            assert client.register() == REG_DISABLED
        mock_get.assert_not_called()

    def test_missing_wallet_is_invalid(self):
        client = XvbClient("", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get") as mock_get:
            assert client.register() == REG_INVALID
        mock_get.assert_not_called()
        assert XvbClient("placeholder", submit_url=_SUBMIT).register() == REG_INVALID

    def test_2xx_is_registered_and_sends_full_wallet(self):
        client = XvbClient("49fullwalletaddress", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", return_value=_resp(200, "OK")) as mock_get:
            assert client.register() == REG_OK
        # Registration takes the FULL wallet address as ?address=...
        assert mock_get.call_args.kwargs["params"] == {"address": "49fullwalletaddress"}
        assert mock_get.call_args.args[0] == _SUBMIT

    def test_already_registered_422_is_idempotent_success(self):
        # The real steady state for an entered wallet (verified live): 422 + this body.
        client = XvbClient("49abc", submit_url=_SUBMIT)
        resp = _resp(422, "ERROR: Wallet Address Already Registered")
        with patch.object(xvb_mod.requests, "get", return_value=resp):
            assert client.register() == REG_OK

    def test_invalid_wallet_422(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        resp = _resp(422, "ERROR: Invalid Wallet Address")
        with patch.object(xvb_mod.requests, "get", return_value=resp):
            assert client.register() == REG_INVALID

    def test_no_share_body_is_not_eligible(self):
        # Best-effort: a body mentioning the PPLNS share => retry quietly, not a failure.
        client = XvbClient("49abc", submit_url=_SUBMIT)
        resp = _resp(422, "ERROR: No share in PPLNS window")
        with patch.object(xvb_mod.requests, "get", return_value=resp):
            assert client.register() == REG_NOT_ELIGIBLE

    def test_5xx_is_transient_error(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", return_value=_resp(500, "Server error!")):
            assert client.register() == REG_ERROR

    def test_unrecognised_body_is_error(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", return_value=_resp(418, "teapot")):
            assert client.register() == REG_ERROR

    def test_routes_through_tor_proxy(self):
        # #163: the call carries the full wallet, so it must ride the Tor SOCKS proxy like get_stats.
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", return_value=_resp(200, "OK")) as mock_get:
            client.register()
        proxies = mock_get.call_args.kwargs["proxies"]
        assert proxies["https"].startswith("socks5h://")
        assert proxies["http"] == proxies["https"]

    def test_network_error_is_transient_error(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", side_effect=requests.RequestException("boom")):
            assert client.register() == REG_ERROR

    def test_unexpected_error_is_transient_error(self):
        client = XvbClient("49abc", submit_url=_SUBMIT)
        with patch.object(xvb_mod.requests, "get", side_effect=ValueError("kaboom")):
            assert client.register() == REG_ERROR


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
