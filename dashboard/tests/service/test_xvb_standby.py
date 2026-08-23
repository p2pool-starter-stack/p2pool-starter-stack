import asyncio
from unittest.mock import MagicMock, patch

import pytest
import requests

from mining_dashboard.config.config import TOR_SOCKS_PROXY
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.service.xvb_standby import XvbStandbyPuller, parse_standby


class _Resp:
    """Minimal bounded_get-style response for the puller tests."""

    def __init__(self, status_code, payload):
        self.status_code = status_code
        self._payload = payload

    def json(self):
        return self._payload


class TestParseStandby:
    def test_valid_payload(self):
        out = parse_standby(
            {
                "commanded_fraction": 0.3,
                "avg_1h": 1200.0,
                "avg_24h": 900.0,
                "donation_level": "vip",
                "mode": "SPLIT",
            }
        )
        assert out == {
            "commanded_fraction": 0.3,
            "avg_1h": 1200.0,
            "avg_24h": 900.0,
            "donation_level": "vip",
            "mode": "SPLIT",
        }

    def test_non_dict_is_none(self):
        assert parse_standby([1, 2, 3]) is None
        assert parse_standby(None) is None

    def test_bad_numeric_is_none(self):
        assert parse_standby({"commanded_fraction": "not-a-number"}) is None

    def test_missing_fields_default(self):
        out = parse_standby({})
        assert out["commanded_fraction"] == 0.0
        assert out["donation_level"] == ""
        assert out["mode"] == ""


class TestPuller:
    def test_disabled_when_source_blank(self):
        puller = XvbStandbyPuller(MagicMock(), source="")
        assert puller.enabled is False
        assert puller.fetch_once() is None  # never touches the network

    def test_disabled_run_returns_immediately(self):
        # An unconfigured single stack must pay nothing — run() exits instead of looping.
        puller = XvbStandbyPuller(MagicMock(), source="")
        asyncio.run(asyncio.wait_for(puller.run(), timeout=1))

    def test_fetch_once_stores_standby(self):
        sm = StateManager(db_path=":memory:")
        try:
            puller = XvbStandbyPuller(sm, source="http://10.0.0.2:8000/api/xvb-standby")
            payload = {"commanded_fraction": 0.42, "avg_1h": 1500.0, "mode": "XVB"}
            with patch(
                "mining_dashboard.service.xvb_standby.bounded_get",
                return_value=_Resp(200, payload),
            ):
                stored = puller.fetch_once()
            assert stored["commanded_fraction"] == 0.42
            assert "pulled_at" in stored
            assert sm.get_xvb_standby()["commanded_fraction"] == 0.42
        finally:
            sm.close()

    def test_fetch_once_non_200_keeps_last(self):
        sm = MagicMock()
        puller = XvbStandbyPuller(sm, source="http://10.0.0.2:8000/api/xvb-standby")
        with patch("mining_dashboard.service.xvb_standby.bounded_get", return_value=_Resp(503, {})):
            assert puller.fetch_once() is None
        sm.set_xvb_standby.assert_not_called()

    def test_fetch_once_network_error_kept_silent(self):
        sm = MagicMock()
        puller = XvbStandbyPuller(sm, source="http://10.0.0.2:8000/api/xvb-standby")
        with patch(
            "mining_dashboard.service.xvb_standby.bounded_get",
            side_effect=requests.ConnectionError("boom"),
        ):
            assert puller.fetch_once() is None
        sm.set_xvb_standby.assert_not_called()

    def test_fetch_once_bad_payload_stores_nothing(self):
        # A 200 with an unusable body (parse_standby -> None) keeps the last-held standby.
        sm = MagicMock()
        puller = XvbStandbyPuller(sm, source="http://10.0.0.2:8000/api/xvb-standby")
        with patch(
            "mining_dashboard.service.xvb_standby.bounded_get",
            return_value=_Resp(200, {"commanded_fraction": "nope"}),
        ):
            assert puller.fetch_once() is None
        sm.set_xvb_standby.assert_not_called()

    async def test_run_polls_then_sleeps(self):
        # One loop iteration: fetch runs (via to_thread), then the interval sleep — patched to
        # break out so the otherwise-infinite loop terminates.
        puller = XvbStandbyPuller(MagicMock(), source="http://x/api/xvb-standby", interval=0)
        puller.fetch_once = MagicMock(return_value=None)
        with patch("asyncio.sleep", side_effect=Exception("stop")):
            with pytest.raises(Exception, match="stop"):
                await puller.run()
        puller.fetch_once.assert_called_once()

    def test_onion_source_routes_over_tor(self):
        puller = XvbStandbyPuller(MagicMock(), source="http://abc.onion/api/xvb-standby")
        assert puller._proxies() == {"http": TOR_SOCKS_PROXY, "https": TOR_SOCKS_PROXY}

    @pytest.mark.parametrize(
        "host",
        ["192.168.1.5:8000", "10.0.0.2:8000", "127.0.0.1:8000", "[::1]:8000", "[fc00::1]"],
    )
    def test_private_ip_source_dials_direct(self, host):
        # Only a provably-private/loopback/link-local IP *literal* is a LAN hop — dial direct.
        puller = XvbStandbyPuller(MagicMock(), source=f"http://{host}/api/xvb-standby")
        assert puller._proxies() is None

    def test_public_ip_source_routes_over_tor(self):
        # A public IP literal is NOT provably private — it must ride Tor, not leak the backup's IP
        # by dialing direct (#160). This is the clearnet-egress leak the review flagged.
        puller = XvbStandbyPuller(MagicMock(), source="http://8.8.8.8:8000/api/xvb-standby")
        assert puller._proxies() == {"http": TOR_SOCKS_PROXY, "https": TOR_SOCKS_PROXY}

    def test_hostname_source_routes_over_tor(self):
        # A hostname can't be proven private without a DNS lookup, so it rides Tor — never direct.
        puller = XvbStandbyPuller(MagicMock(), source="http://primary.example.com/api/xvb-standby")
        assert puller._proxies() == {"http": TOR_SOCKS_PROXY, "https": TOR_SOCKS_PROXY}

    def test_startup_log_does_not_leak_source_url(self, caplog):
        # The source URL can embed basic-auth userinfo (a capability secret) — the startup log must
        # only announce enabled-state, never the URL/userinfo (mirrors healthchecks.py).
        secret = "http://user:s3cr3t@primary.example.com/api/xvb-standby"
        puller = XvbStandbyPuller(MagicMock(), source=secret, interval=0)
        puller.fetch_once = MagicMock(return_value=None)  # no network in this test
        with caplog.at_level("INFO", logger="XvbStandby"):
            with patch("asyncio.sleep", side_effect=Exception("stop")):
                with pytest.raises(Exception, match="stop"):
                    asyncio.run(puller.run())
        joined = " ".join(r.getMessage() for r in caplog.records)
        assert "s3cr3t" not in joined
        assert "user:" not in joined
        assert secret not in joined
        assert "primary.example.com" not in joined  # not even the bare host
