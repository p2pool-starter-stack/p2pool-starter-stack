"""Tests for the Healthchecks.io dead-man's-switch client (Issue #79)."""

import logging
from unittest.mock import patch

import requests

import mining_dashboard.service.healthchecks as hc_mod
from mining_dashboard.service.healthchecks import HealthchecksClient


class _Clock:
    """A controllable monotonic clock for throttle tests."""

    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _client(clock=None, **overrides):
    cfg = dict(
        ping_url="https://hc-ping.com/abc",
        interval_seconds=60,
    )
    cfg.update(overrides)
    return HealthchecksClient(clock=clock or _Clock(), **cfg)


class TestUrlResolution:
    # Paste the full URL Healthchecks.io shows you (hosted or self-hosted); anything that isn't an
    # http(s) URL is treated as unset (base_url / bare-uuid support was dropped as redundant).
    def test_full_url_used_as_is(self):
        assert _client(ping_url="https://hc-ping.com/uuid").url == "https://hc-ping.com/uuid"

    def test_self_hosted_full_url_used_as_is(self):
        assert _client(ping_url="http://hc.local/ping/uuid").url == "http://hc.local/ping/uuid"

    def test_trailing_slash_stripped(self):
        assert _client(ping_url="https://hc-ping.com/uuid/").url == "https://hc-ping.com/uuid"

    def test_blank_or_none_is_unset(self):
        assert _client(ping_url="").url == ""
        assert _client(ping_url="   ").url == ""
        assert _client(ping_url=None).url == ""

    def test_bare_uuid_rejected_as_unset(self):
        assert _client(ping_url="abc-123").url == ""

    def test_enabled_is_derived_from_the_url(self):
        # No separate on/off flag: a URL means on, blank means off.
        assert _client(ping_url="https://hc-ping.com/abc").enabled is True
        assert _client(ping_url="").enabled is False


class TestPingUnconfigured:
    def test_no_url_is_a_silent_noop(self, caplog):
        # A blank ping URL is simply "off" — ping() does nothing, opens no socket, logs nothing.
        c = _client(ping_url="")
        with (
            patch.object(hc_mod.requests, "get") as get,
            caplog.at_level(logging.DEBUG, logger="Healthchecks"),
        ):
            assert c.ping() is False
            assert c.ping() is False
        get.assert_not_called()
        assert not caplog.records


class TestPingSuccess:
    def test_healthy_ping_hits_the_url(self):
        # Pure liveness: every ping hits the configured URL (no /fail path — health-aware was
        # dropped; node-health alerting is the Telegram alerter's job, #121).
        c = _client()
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
        get.assert_called_once()
        assert get.call_args.args[0] == "https://hc-ping.com/abc"


class TestTorRouting:
    def test_ping_passes_socks_proxies(self):
        # tor_proxy set → the ping rides the bridge Tor SOCKS (host IP hidden from the endpoint).
        proxy = "socks5h://172.28.0.25:9050"
        c = _client(tor_proxy=proxy)
        with patch.object(hc_mod.requests, "get") as get:
            assert c.ping() is True
        assert get.call_args.kwargs["proxies"] == {"http": proxy, "https": proxy}

    def test_from_config_always_routes_over_tor(self):
        # from_config wires the bridge Tor SOCKS unconditionally — there is no clearnet mode.
        with (
            patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"),
            patch.object(hc_mod, "TOR_SOCKS_PROXY", "socks5h://172.28.0.25:9050"),
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
        # Real config defaults: no ping URL out of the box → off.
        assert HealthchecksClient.from_config().enabled is False

    def test_reads_config_values(self):
        with patch.object(hc_mod, "HEALTHCHECKS_PING_URL", "https://hc-ping.com/zzz"):
            c = HealthchecksClient.from_config()
        assert c.enabled is True  # a URL is configured
        assert c.url == "https://hc-ping.com/zzz"
        assert c.interval == hc_mod._PING_INTERVAL_SEC  # fixed throttle floor, not configurable
