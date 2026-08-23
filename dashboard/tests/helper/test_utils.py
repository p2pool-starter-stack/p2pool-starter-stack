import time
from unittest.mock import patch

from mining_dashboard.config.config import XVB_STATS_STALE_AFTER_S
from mining_dashboard.helper.utils import (
    PPLNS_BLOCK_TIME_DEFAULT,
    PPLNS_BLOCK_TIME_NANO,
    detect_host_ipv4,
    format_disk_size,
    format_duration,
    format_hashrate,
    format_time_abs,
    format_xmr,
    format_xtm,
    get_tier_info,
    is_ip_address,
    parse_hashrate,
    pplns_block_time,
    pplns_weight_in_window,
    resolve_target_threshold,
    shares_in_pplns_window,
    xvb_stats_are_stale,
)


class TestXvbStatsAreStale:
    """#311: the shared freshness predicate used by both the controller and the dashboard."""

    def test_cold_start_never_fetched_is_not_stale(self):
        # No/zero last_update => never fetched => the feedforward-ramp regime, not stale.
        assert xvb_stats_are_stale({}) is False
        assert xvb_stats_are_stale({"last_update": 0}) is False
        assert xvb_stats_are_stale(None) is False

    def test_recent_fetch_is_not_stale(self):
        assert xvb_stats_are_stale({"last_update": time.time()}) is False

    def test_old_fetch_is_stale(self):
        assert (
            xvb_stats_are_stale({"last_update": time.time() - XVB_STATS_STALE_AFTER_S - 1}) is True
        )

    def test_boundary_just_within_threshold_is_not_stale(self):
        # Age just under the threshold is still fresh (strict > comparison).
        assert (
            xvb_stats_are_stale({"last_update": time.time() - XVB_STATS_STALE_AFTER_S + 5}) is False
        )


class TestPplnsWindow:
    """#263: shared PPLNS-window math used by metrics, the controller, and XvB auto-register."""

    def test_block_time_by_pool_type(self):
        assert pplns_block_time("Nano") == PPLNS_BLOCK_TIME_NANO
        assert pplns_block_time("Main") == PPLNS_BLOCK_TIME_DEFAULT
        assert pplns_block_time("Mini") == PPLNS_BLOCK_TIME_DEFAULT
        assert pplns_block_time("anything-else") == PPLNS_BLOCK_TIME_DEFAULT

    def test_counts_only_shares_inside_the_window(self):
        now = 10_000
        # window = 2 blocks * 10 s = 20 s => cutoff at now-20
        shares = [{"ts": now - 5}, {"ts": now - 19}, {"ts": now - 20}, {"ts": now - 21}, {}]
        # ts >= cutoff counts: -5, -19, -20 (boundary inclusive); -21 and the missing-ts drop out.
        assert shares_in_pplns_window(shares, 2, 10, now=now) == 3

    def test_empty_shares_is_zero(self):
        assert shares_in_pplns_window([], 2160, 10, now=10_000) == 0

    def test_weight_sums_difficulty_inside_the_window(self):
        # #84: same cutoff as the count above, but summing the persisted per-share difficulty.
        now = 10_000
        shares = [
            {"ts": now - 5, "difficulty": 100.0},
            {"ts": now - 20, "difficulty": 250.0},  # boundary inclusive
            {"ts": now - 21, "difficulty": 999.0},  # outside — dropped
        ]
        assert pplns_weight_in_window(shares, 2, 10, now=now) == 350.0

    def test_weight_missing_or_null_difficulty_counts_zero(self):
        now = 10_000
        shares = [
            {"ts": now - 1},
            {"ts": now - 2, "difficulty": None},
            {"ts": now - 3, "difficulty": 40},
        ]
        assert pplns_weight_in_window(shares, 2, 10, now=now) == 40

    def test_weight_empty_shares_is_zero(self):
        assert pplns_weight_in_window([], 2160, 10, now=10_000) == 0


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


class TestFormatDiskSize:
    """#677: GB below 1 TB, TB at or above it; both values switch together."""

    def test_stays_gb_below_1024(self):
        assert format_disk_size(408.6, 931.5) == ("408.6", "931.5", "GB")

    def test_switches_to_tb_at_boundary(self):
        assert format_disk_size(512, 1024) == ("0.5", "1.0", "TB")

    def test_large_volume_reads_in_tb(self):
        assert format_disk_size(408.6, 3666.4) == ("0.4", "3.6", "TB")

    def test_bad_data(self):
        assert format_disk_size(None, None) == ("0.0", "0.0", "GB")
        assert format_disk_size("invalid", "invalid") == ("0.0", "0.0", "GB")


class TestFormatXmr:
    """#387: mirrors formatXmr in web/static/logic.mjs so dashboard and Telegram agree."""

    def test_precision_scales_with_magnitude(self):
        assert format_xmr(2.5) == "2.5000 XMR"  # >= 1 -> 4 dp
        assert format_xmr(0.1234567) == "0.123457 XMR"  # >= 0.001 -> 6 dp
        assert format_xmr(0.00000123) == "0.00000123 XMR"  # tiny -> 8 dp, not rounded to 0

    def test_zero_and_bad_data(self):
        assert format_xmr(0) == "0 XMR"
        assert format_xmr(None) == "—"
        assert format_xmr("invalid") == "—"
        assert format_xmr(float("inf")) == "—"


class TestFormatXtm:
    """#387: the Tari sibling — mirrors formatXtm in web/static/logic.mjs, so a confirmed Tari
    total (#787) reads identically in the bot and on the dashboard card."""

    def test_precision_scales_with_magnitude(self):
        assert format_xtm(4552.15) == "4552.1500 XTM"  # >= 1 -> 4 dp
        assert format_xtm(0.1234567) == "0.123457 XTM"  # >= 0.001 -> 6 dp
        assert format_xtm(0.00000123) == "0.00000123 XTM"  # tiny -> 8 dp, not rounded to 0

    def test_zero_and_bad_data(self):
        assert format_xtm(0) == "0 XTM"
        assert format_xtm(None) == "—"
        assert format_xtm("invalid") == "—"
        assert format_xtm(float("inf")) == "—"


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
