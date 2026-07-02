"""Tests for the Healthchecks.io dead-man's-switch client (Issue #79)."""

import logging
from unittest.mock import patch

import requests

import mining_dashboard.service.healthchecks as hc_mod
from mining_dashboard.service.healthchecks import HealthchecksClient, _resolve_ping_url


class _Clock:
    """A controllable monotonic clock for throttle tests."""

    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _client(clock=None, **overrides):
    cfg = dict(
        enabled=True,
        ping_url="https://hc-ping.com/abc",
        base_url="https://hc-ping.com",
        interval_seconds=60,
        fail_on_node_down=True,
    )
    cfg.update(overrides)
    return HealthchecksClient(clock=clock or _Clock(), **cfg)


class TestResolvePingUrl:
    def test_full_https_url_used_as_is(self):
        assert (
            _resolve_ping_url("https://hc-ping.com/uuid", "https://hc-ping.com")
            == "https://hc-ping.com/uuid"
        )

    def test_full_http_url_used_as_is(self):
        assert (
            _resolve_ping_url("http://hc.local/ping/uuid", "https://hc-ping.com")
            == "http://hc.local/ping/uuid"
        )

    def test_trailing_slash_stripped(self):
        assert (
            _resolve_ping_url("https://hc-ping.com/uuid/", "https://hc-ping.com")
            == "https://hc-ping.com/uuid"
        )

    def test_bare_uuid_joined_with_default_base(self):
        assert _resolve_ping_url("abc-123", "https://hc-ping.com") == "https://hc-ping.com/abc-123"

    def test_bare_uuid_joined_with_selfhosted_base(self):
        # base_url override is how a self-hosted instance is supported with a bare uuid.
        assert (
            _resolve_ping_url("abc-123", "https://hc.example.com/ping/")
            == "https://hc.example.com/ping/abc-123"
        )

    def test_blank_and_none_resolve_to_empty(self):
        assert _resolve_ping_url("", "https://hc-ping.com") == ""
        assert _resolve_ping_url("   ", "https://hc-ping.com") == ""
        assert _resolve_ping_url(None, "https://hc-ping.com") == ""


class TestActive:
    def test_active_requires_enabled_and_url(self):
        assert _client().active is True
        assert _client(enabled=False).active is False
        assert _client(ping_url="", base_url="https://hc-ping.com").active is False


class TestPingDisabledOrUnconfigured:
    def test_disabled_is_a_noop(self):
        c = _client(enabled=False)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is False
        get.assert_not_called()

    def test_enabled_without_url_warns_once(self, caplog):
        c = _client(ping_url="", base_url="https://hc-ping.com")
        with (
            patch.object(hc_mod.requests, "get") as get,
            caplog.at_level(logging.WARNING, logger="Healthchecks"),
        ):
            assert c.ping() is False
            assert c.ping() is False
        get.assert_not_called()
        warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
        assert len(warnings) == 1  # warned once, then stayed quiet


class TestPingSuccess:
    def test_healthy_ping_hits_the_url(self):
        c = _client()
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
        get.assert_called_once()
        assert get.call_args.args[0] == "https://hc-ping.com/abc"

    def test_fail_signal_appends_fail(self):
        c = _client()
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping(fail=True) is True
        assert get.call_args.args[0] == "https://hc-ping.com/abc/fail"

    def test_fail_signal_ignored_when_disabled_for_node_down(self):
        # signal_fail_on_node_down off → a node-down still sends a *success* ping (liveness only).
        c = _client(fail_on_node_down=False)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping(fail=True) is True
        assert get.call_args.args[0] == "https://hc-ping.com/abc"


class TestTorRouting:
    def test_ping_over_tor_passes_socks_proxies(self):
        # tor_proxy set → the ping rides the bridge Tor SOCKS (host IP hidden from hc-ping.com).
        proxy = "socks5h://172.28.0.25:9050"
        c = _client(tor_proxy=proxy)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
        assert get.call_args.kwargs["proxies"] == {"http": proxy, "https": proxy}

    def test_ping_without_tor_sends_no_proxies(self):
        # Default (no tor_proxy) → direct clearnet ping, proxies=None.
        c = _client()
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
        assert get.call_args.kwargs["proxies"] is None

    def test_from_config_wires_the_tor_proxy(self):
        with (
            patch.object(hc_mod, "HEALTHCHECKS_ENABLED", True),
            patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"),
            patch.object(hc_mod, "HEALTHCHECKS_TOR_PROXY", "socks5h://172.28.0.25:9050"),
        ):
            c = HealthchecksClient.from_config()
        with patch.object(hc_mod.requests, "get") as get:
            c.ping()
        assert get.call_args.kwargs["proxies"]["https"] == "socks5h://172.28.0.25:9050"


class TestThrottle:
    def test_second_immediate_ping_is_throttled(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True  # first ping goes out
            assert c.ping() is False  # within the interval → skipped
        get.assert_called_once()

    def test_ping_again_after_interval_elapses(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
            clock.t += 61  # interval elapsed
            assert c.ping() is True
        assert get.call_count == 2

    def test_zero_interval_pings_every_call(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=0)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
            assert c.ping() is True
        assert get.call_count == 2


class TestPingFailsSilently:
    def test_network_error_is_swallowed_and_retries(self, caplog):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with (
            patch.object(
                hc_mod.requests, "get", side_effect=requests.exceptions.ConnectionError("offline")
            ) as get,
            caplog.at_level(logging.DEBUG, logger="Healthchecks"),
        ):
            assert c.ping() is False
            # Throttle clock did NOT advance on failure → the very next call retries immediately.
            assert c.ping() is False
        assert get.call_count == 2
        # No noisy WARNING/ERROR — offline is expected and logged at debug only (#59 discipline).
        assert not [r for r in caplog.records if r.levelno >= logging.WARNING]

    def test_success_after_failure_advances_throttle(self):
        clock = _Clock(1000.0)
        c = _client(clock=clock, interval_seconds=60)
        with patch.object(
            hc_mod.requests, "get", side_effect=[requests.exceptions.ConnectionError("x"), None]
        ):
            assert c.ping() is False  # failed, no throttle advance
            assert c.ping() is True  # retried immediately, succeeded → throttle set
            assert c.ping() is False  # now throttled


class TestFromConfig:
    def test_defaults_to_disabled(self):
        # Real config defaults: feature is off out of the box.
        assert HealthchecksClient.from_config().enabled is False

    def test_reads_config_values(self):
        with (
            patch.object(hc_mod, "HEALTHCHECKS_ENABLED", True),
            patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"),
            patch.object(hc_mod, "HEALTHCHECKS_BASE_URL", "https://hc-ping.com"),
            patch.object(hc_mod, "HEALTHCHECKS_INTERVAL_SEC", 120),
            patch.object(hc_mod, "HEALTHCHECKS_FAIL_ON_NODE_DOWN", False),
        ):
            c = HealthchecksClient.from_config()
        assert c.enabled is True
        assert c.url == "https://hc-ping.com/zzz"
        assert c.interval == 120
        assert c.fail_on_node_down is False
