import pytest
from unittest.mock import patch
from mining_dashboard.helper.utils import (
    parse_hashrate,
    format_hashrate,
    format_duration,
    format_time_abs,
    get_tier_info,
    resolve_target_threshold,
    is_ip_address,
    detect_host_ipv4,
)


class TestParseHashrate:
    def test_plain_numbers(self):
        assert parse_hashrate("100") == 100.0
        assert parse_hashrate(150.5) == 150.5
        assert parse_hashrate("10", None) == 10.0

    def test_unit_suffixes_case_insensitive(self):
        assert parse_hashrate("1.5", "kH/s") == 1500.0
        assert parse_hashrate("2", "MH") == 2_000_000.0
        assert parse_hashrate("0.5", "gh/s") == 500_000_000.0

    def test_unrecognized_suffix_is_raw(self):
        assert parse_hashrate("500", "H/s") == 500.0
        assert parse_hashrate("500", "Unknown") == 500.0

    def test_bad_data_returns_zero(self):
        assert parse_hashrate("not-a-number") == 0.0
        assert parse_hashrate(None) == 0.0


class TestFormatHashrate:
    def test_unit_boundaries(self):
        assert format_hashrate(1_500_000_000) == "1.50 GH/s"
        assert format_hashrate(2_500_000) == "2.50 MH/s"
        assert format_hashrate(1_500) == "1.50 kH/s"
        assert format_hashrate(500) == "500.00 H/s"

    def test_bad_data(self):
        assert format_hashrate(0) == "0.00 H/s"
        assert format_hashrate("invalid") == "0 H/s"
        assert format_hashrate(None) == "0 H/s"


class TestFormatDuration:
    def test_branches(self):
        assert format_duration(90000) == "1d 1h 0m"
        assert format_duration(3660) == "1h 1m"
        assert format_duration(65) == "1m 5s"
        assert format_duration(45) == "0m 45s"

    def test_bad_data(self):
        assert format_duration(0) == "0m 0s"
        assert format_duration("invalid") == "0s"
        assert format_duration(None) == "0s"


class TestFormatTimeAbs:
    def test_formats_localtime(self):
        with patch("mining_dashboard.helper.utils.time.strftime", return_value="12:00:00"):
            assert format_time_abs(1600000000) == "12:00:00"

    def test_falsy_is_never(self):
        assert format_time_abs(0) == "Never"
        assert format_time_abs(None) == "Never"

    def test_invalid_type_does_not_crash(self):
        # Characterization: a non-numeric timestamp must degrade, not raise.
        assert format_time_abs("invalid") == "Invalid Time"


class TestGetTierInfo:
    def test_default_tiers(self):
        assert get_tier_info(1_500_000)[0].startswith("Mega")
        assert get_tier_info(150_000)[0].startswith("Whale")
        assert get_tier_info(15_000)[0].startswith("Vip")
        assert get_tier_info(1_500)[0].startswith("Donor")
        assert get_tier_info(500) == ("None", 0.0)

    def test_custom_tiers(self):
        custom = {"custom_god": 5_000_000, "custom_pleb": 10}
        name, threshold = get_tier_info(6_000_000, tiers=custom)
        assert name == "Custom God (5.00 MH/s+)"
        assert threshold == 5_000_000.0

    def test_zero_threshold_ignored(self):
        assert get_tier_info(100, tiers={"donor_zero": 0}) == ("None", 0.0)


class TestResolveTargetThreshold:
    TIERS = {"donor_mega": 1_000_000, "donor_whale": 100_000, "donor_vip": 10_000, "donor": 1_000}

    def test_auto_picks_highest_sustainable(self):
        # 15_000 * 0.85 = 12_750 -> VIP (10_000) is the highest we can hold.
        assert resolve_target_threshold(self.TIERS, 15_000, "auto", 0.85) == (10_000, True)
        assert resolve_target_threshold(self.TIERS, 15_000, "highest", 0.85) == (10_000, True)

    def test_auto_zero_when_nothing_sustainable(self):
        assert resolve_target_threshold(self.TIERS, 100, "auto", 0.85) == (0.0, False)

    def test_named_tier_honored(self):
        assert resolve_target_threshold(self.TIERS, 1_000_000, "whale", 0.85) == (100_000, True)
        assert resolve_target_threshold(self.TIERS, 1_000_000, "vip", 0.85) == (10_000, True)

    def test_named_tier_not_downgraded_but_flagged_unsustainable(self):
        # Request Mega with only 50k -> honored (1M) but flagged not sustainable.
        assert resolve_target_threshold(self.TIERS, 50_000, "mega", 0.85) == (1_000_000, False)

    def test_cannot_sustain_named_tier_is_flagged(self):
        # VIP needs 10k; 5k * 0.85 = 4250 < 10k -> honored but not sustainable.
        assert resolve_target_threshold(self.TIERS, 5_000, "vip", 0.85) == (10_000, False)

    def test_numeric_level_honored(self):
        target, sustainable = resolve_target_threshold(self.TIERS, 1_000_000, "5000", 0.85)
        assert target == 5_000 and sustainable is True

    def test_unknown_level_falls_back_to_lowest(self):
        target, _ = resolve_target_threshold(self.TIERS, 1_000_000, "bogus", 0.85)
        assert target == 1_000


class TestIsIpAddress:
    def test_ipv4_is_an_address(self):
        assert is_ip_address("192.168.1.42") is True
        assert is_ip_address("127.0.0.1") is True

    def test_ipv6_is_an_address(self):
        assert is_ip_address("::1") is True
        assert is_ip_address("fe80::1") is True

    def test_hostname_is_not_an_address(self):
        assert is_ip_address("pithead.local") is False
        assert is_ip_address("my-rig") is False
        assert is_ip_address("256.256.256.256") is False

    def test_surrounding_whitespace_tolerated(self):
        assert is_ip_address("  10.0.0.5  ") is True

    def test_non_string_and_empty_are_not_addresses(self):
        assert is_ip_address("") is False
        assert is_ip_address(None) is False


class TestDetectHostIpv4:
    def test_returns_socket_source_address(self):
        # UDP connect only fixes the route; getsockname() then exposes the chosen source IP.
        sock = patch("mining_dashboard.helper.utils.socket.socket").start()
        try:
            sock.return_value.getsockname.return_value = ("192.168.1.42", 54321)
            assert detect_host_ipv4() == "192.168.1.42"
        finally:
            patch.stopall()

    def test_none_when_no_route(self):
        with patch("mining_dashboard.helper.utils.socket.socket") as sock:
            sock.return_value.connect.side_effect = OSError("network unreachable")
            assert detect_host_ipv4() is None

    def test_socket_is_closed_even_on_error(self):
        with patch("mining_dashboard.helper.utils.socket.socket") as sock:
            inst = sock.return_value
            inst.connect.side_effect = OSError("boom")
            detect_host_ipv4()
            inst.close.assert_called_once()
