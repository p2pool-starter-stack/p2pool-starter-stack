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
    parse_reward_estimates,
)

SAMPLE_HTML = "Fail Count: 2\n1hr avg: 1.5 kH/s\n24hr avg: 3.0 kH/s\n"

# A verbatim sample of XvB's reward_estimate_pub.txt (#118): pool-total rows, the non-donor vip/mvp
# rows, and the four donor-tier Player rows we keep. Real values captured 2026-07-10.
SAMPLE_REWARD_TXT = (
    "Raffle HR: 4535.41 kH/s\n"
    "Raffle Reward: 128.15 XMR/year\n\n"
    "Round vip: 1.00 XMR/year\n"
    "Round: vip Player: 0.0036 XMR/year\n\n"
    "Round mvp: 0.33 XMR/year\n"
    "Round: mvp Player: 0.083 XMR/year\n\n"
    "Round: donor: 4.00 XMR/year\n"
    "Round: donor Player: 0.060 XMR/year\n\n"
    "Round: donor_vip: 23.36 XMR/year\n"
    "Round: donor_vip Player: 0.81 XMR/year\n\n"
    "Round: donor_whale: 48.72 XMR/year\n"
    "Round: donor_whale Player: 6.17 XMR/year\n\n"
    "Round: donor_mega: 50.73 XMR/year\n"
    "Round: donor_mega Player: 56.90 XMR/year\n\n"
)


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


# --- Reward-estimate parser + fetch (#118) --------------------------------------------------


def test_parse_reward_estimates_keeps_four_donor_tiers():
    est = parse_reward_estimates(SAMPLE_REWARD_TXT)
    # Only the donor Player rows, keyed by round-type; pool totals and vip/mvp rows are dropped.
    assert est == {"donor": 0.06, "donor_vip": 0.81, "donor_whale": 6.17, "donor_mega": 56.9}


def test_parse_reward_estimates_malformed_or_empty_is_empty_dict():
    assert parse_reward_estimates("") == {}
    assert parse_reward_estimates(None) == {}
    assert parse_reward_estimates("total garbage with no rounds") == {}
    # Pool-total rows alone (no Player figure) yield nothing — the Player keyword is required.
    assert parse_reward_estimates("Round: donor: 4.00 XMR/year\n") == {}
    # A donor row whose value isn't a clean float is skipped, not fatal.
    assert parse_reward_estimates("Round: donor Player: 1.2.3 XMR/year\n") == {}


def test_get_reward_estimates_success_routes_over_tor():
    client = XvbClient("49abc")
    resp = MagicMock(status_code=200, text=SAMPLE_REWARD_TXT)
    with patch.object(xvb_mod.requests, "get", return_value=resp) as mock_get:
        est = client.get_reward_estimates()
    assert est["donor_whale"] == 6.17
    proxies = mock_get.call_args.kwargs["proxies"]
    assert proxies["https"].startswith("socks5h://")  # same Tor path as the stats fetch


def test_get_reward_estimates_non_200_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", return_value=MagicMock(status_code=503)):
        assert client.get_reward_estimates() is None


def test_get_reward_estimates_unparseable_body_returns_none():
    # A 200 with a garbage body must degrade like a failure (None) so the cache stays frozen — a
    # stale/empty estimate must never overwrite the last-good reading (#311 contract).
    client = XvbClient("49abc")
    with patch.object(
        xvb_mod.requests, "get", return_value=MagicMock(status_code=200, text="junk")
    ):
        assert client.get_reward_estimates() is None


def test_get_reward_estimates_network_error_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", side_effect=requests.RequestException("boom")):
        assert client.get_reward_estimates() is None


def test_get_reward_estimates_unexpected_error_returns_none():
    client = XvbClient("49abc")
    with patch.object(xvb_mod.requests, "get", side_effect=ValueError("kaboom")):
        assert client.get_reward_estimates() is None


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

    def test_routes_through_configured_tor_proxy_by_default(self):
        # #163: the call carries the full wallet, so it ALWAYS rides the bridge Tor SOCKS like
        # get_stats — a default-constructed client (as main.py builds it) uses TOR_SOCKS_PROXY.
        client = XvbClient("49abc", submit_url=_SUBMIT)  # no tor_proxy => the configured default
        with patch.object(xvb_mod.requests, "get", return_value=_resp(200, "OK")) as mock_get:
            client.register()
        proxies = mock_get.call_args.kwargs["proxies"]
        assert proxies["https"] == xvb_mod.TOR_SOCKS_PROXY
        assert proxies["https"].startswith("socks5h://")  # resolves the host over Tor too
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
