"""Unit tests for the expected-earnings model (mining_dashboard/service/earnings.py).

The model is one linear rate — XMR per H/s per day — derived from the live block reward and
network difficulty. These tests pin the math (including the worked field example), the units, and
the graceful-degradation behaviour when inputs are missing. The client scales this rate to the
what-if hashrate; that scaling/formatting is tested in tests/frontend/logic.test.mjs.
"""

import os
import time

import pytest

from mining_dashboard.service.earnings import (
    ATOMIC_PER_XMR,
    SECONDS_PER_DAY,
    confirmed_payouts_summary,
    previous_local_day,
    tari_seconds_to_block_per_hs,
    xmr_per_hs_day,
    xtm_per_hs_day,
)


class TestXmrPerHsDay:
    def test_matches_closed_form(self):
        # reward_xmr / difficulty * seconds_per_day, with reward given in atomic units.
        reward_atomic = 0.6 * ATOMIC_PER_XMR  # 0.6 XMR block reward
        difficulty = 400_000_000_000  # 400 G
        expected = 0.6 / difficulty * SECONDS_PER_DAY
        assert xmr_per_hs_day(reward_atomic, difficulty) == pytest.approx(expected)

    def test_worked_field_example(self):
        # A 50 kH/s rig at 0.6 XMR / 400 G difficulty earns ~0.00648 XMR/day. This cross-checks
        # the rate against the independent "share of daily emission" derivation:
        #   network_hr = diff/120 = 3.33 GH/s; share = 50k/3.33e9; emission = 0.6 * 86400/120.
        rate = xmr_per_hs_day(0.6 * ATOMIC_PER_XMR, 400_000_000_000)
        assert rate * 50_000 == pytest.approx(0.00648, rel=1e-3)

    def test_linear_in_inputs(self):
        # Double the reward -> double the rate; double the difficulty -> half the rate.
        base = xmr_per_hs_day(ATOMIC_PER_XMR, 1_000_000)
        assert xmr_per_hs_day(2 * ATOMIC_PER_XMR, 1_000_000) == pytest.approx(2 * base)
        assert xmr_per_hs_day(ATOMIC_PER_XMR, 2_000_000) == pytest.approx(base / 2)

    @pytest.mark.parametrize(
        "reward,diff",
        [
            (0, 400_000_000_000),  # no reward collected yet
            (0.6 * ATOMIC_PER_XMR, 0),  # no difficulty yet
            (0, 0),  # nothing collected
            (-1, 400_000_000_000),  # defensive: negative reward
            (0.6 * ATOMIC_PER_XMR, -5),  # defensive: negative difficulty
        ],
    )
    def test_missing_or_bad_inputs_are_zero(self, reward, diff):
        # A zero rate is the dashboard's "unavailable" signal (shows "—"); never raise or divide
        # by zero on incomplete live data.
        assert xmr_per_hs_day(reward, diff) == 0.0


class TestXtmPerHsDay:
    """Tari merge-mining rate (#117) — same linear expectation, reward already in XTM."""

    def test_matches_closed_form(self):
        # reward_xtm / difficulty * seconds_per_day — no atomic conversion (the collector already
        # converts p2pool's µT figure to XTM).
        assert xtm_per_hs_day(13_000, 400_000_000_000) == pytest.approx(
            13_000 / 400_000_000_000 * SECONDS_PER_DAY
        )

    def test_linear_in_inputs(self):
        # Double the reward -> double the rate; double the difficulty -> half the rate.
        base = xtm_per_hs_day(10_000, 1_000_000)
        assert xtm_per_hs_day(20_000, 1_000_000) == pytest.approx(2 * base)
        assert xtm_per_hs_day(10_000, 2_000_000) == pytest.approx(base / 2)

    @pytest.mark.parametrize(
        "reward,diff",
        [
            (0, 400_000_000_000),  # Tari inactive / still syncing: no reward collected
            (13_000, 0),  # no difficulty yet
            (0, 0),  # nothing collected
            (-1, 400_000_000_000),  # defensive: negative reward
            (13_000, -5),  # defensive: negative difficulty
        ],
    )
    def test_missing_or_bad_inputs_are_zero(self, reward, diff):
        # Zero is the "unavailable" signal — the card shows "—" and Telegram omits the line.
        assert xtm_per_hs_day(reward, diff) == 0.0


class TestTariSecondsToBlockPerHs:
    """Solo merge-mining time-to-block rate (#117): seconds-to-block per H/s == difficulty."""

    def test_is_difficulty_per_hs(self):
        # The per-H/s figure is difficulty itself; the client divides by the what-if hashrate to get
        # expected seconds to a block. Prod field numbers: diff ~1.677e12, fleet ~269 kH/s.
        rate = tari_seconds_to_block_per_hs(1_677_000_000_000)
        assert rate == pytest.approx(1_677_000_000_000)
        seconds = rate / 269_000
        assert seconds / SECONDS_PER_DAY == pytest.approx(72.2, rel=0.02)  # ~72 days, not steady

    @pytest.mark.parametrize("diff", [0, -5])
    def test_missing_or_bad_difficulty_is_zero(self, diff):
        # Zero difficulty -> zero rate -> the card shows "—" (graceful degradation).
        assert tari_seconds_to_block_per_hs(diff) == 0.0


# --- Confirmed payouts summary (#381/#462, running windows #787) -----------------------


def _local(year, month, day, hh=0, mm=0, ss=0):
    """Unix seconds for a LOCAL wall-clock time. The summary cuts calendar days in the dashboard
    container's timezone, so the fixtures are built the same way — the assertions then hold under
    whatever TZ the suite happens to run in, instead of only under UTC."""
    return time.mktime((year, month, day, hh, mm, ss, 0, 0, -1))


class TestPreviousLocalDay:
    def test_is_yesterdays_midnight_to_todays(self):
        start, end = previous_local_day(_local(2026, 7, 28, 15, 30))
        assert (start, end) == (_local(2026, 7, 27), _local(2026, 7, 28))

    def test_is_stable_across_the_whole_day(self):
        # Any hour of today must resolve to the same "yesterday" — including the two boundaries.
        expected = (_local(2026, 7, 27), _local(2026, 7, 28))
        assert previous_local_day(_local(2026, 7, 28, 0, 0, 0)) == expected
        assert previous_local_day(_local(2026, 7, 28, 23, 59, 59)) == expected

    def test_short_dst_day_still_lands_on_yesterday(self):
        # Europe/London springs forward on 2026-03-29 (01:00 -> 02:00), making that day 23h long.
        # Subtracting a flat 86_400 from 2026-03-30 midnight would land at 23:00 on the 28th — the
        # WRONG date. Stepping back through noon keeps it on the 29th.
        prev_tz = os.environ.get("TZ")
        os.environ["TZ"] = "Europe/London"
        time.tzset()
        try:
            start, end = previous_local_day(_local(2026, 3, 30, 12, 0))
            assert (start, end) == (_local(2026, 3, 29), _local(2026, 3, 30))
            assert end - start == 23 * 3_600  # the short day, proving it isn't a flat 24h subtract
        finally:
            if prev_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = prev_tz
            time.tzset()


class TestConfirmedPayoutsSummary:
    # Local noon, so "yesterday" is unambiguously the previous calendar day.
    NOW = _local(2026, 7, 28, 12, 0)
    ONE_XMR = ATOMIC_PER_XMR

    def test_disabled_when_payouts_none(self):
        # Feature off (storage returns None) -> only the enabled flag, no totals.
        assert confirmed_payouts_summary(None) == {"enabled": False}

    def test_empty_list_is_on_with_zeros(self):
        # On, nothing confirmed yet: enabled, count 0, every window 0.0, no last payout — and every
        # running window flagged partial, because no history means no proof the windows are covered.
        s = confirmed_payouts_summary([], now=self.NOW)
        assert s == {
            "enabled": True,
            "count": 0,
            "xmr_24h": 0.0,
            "xmr_yesterday": 0.0,
            "xmr_7d": 0.0,
            "xmr_30d": 0.0,
            "xmr_all": 0.0,
            "last_ts": 0,
            "since_ts": 0,
            "partial": {"yesterday": True, "7d": True, "30d": True},
        }

    def test_trailing_windows_bucket_by_age(self):
        # One payout in each band; 1 XMR = 1e12 piconero. 24h ⊆ 7d ⊆ 30d ⊆ all-time.
        payouts = [
            {"ts": self.NOW - 3_600, "amount_atomic": self.ONE_XMR},  # 1h -> 24h, 7d, 30d, all
            {"ts": self.NOW - 3 * 86_400, "amount_atomic": 2 * self.ONE_XMR},  # 3d -> 7d, 30d, all
            {"ts": self.NOW - 10 * 86_400, "amount_atomic": 4 * self.ONE_XMR},  # 10d -> 30d, all
            {"ts": self.NOW - 40 * 86_400, "amount_atomic": 8 * self.ONE_XMR},  # 40d -> all only
        ]
        s = confirmed_payouts_summary(payouts, now=self.NOW)
        assert s["count"] == 4
        assert s["xmr_24h"] == 1.0
        assert s["xmr_7d"] == 3.0
        assert s["xmr_30d"] == 7.0
        assert s["xmr_all"] == 15.0
        assert s["last_ts"] == self.NOW - 3_600
        assert s["since_ts"] == self.NOW - 40 * 86_400

    def test_yesterday_is_the_previous_calendar_day(self):
        # A calendar day, NOT a trailing 24h: both edges of yesterday count, today's midnight and
        # the day before's last second do not. Half-open [start, end) — midnight belongs to the day
        # it opens, so a payout is never counted into two days.
        payouts = [
            {"ts": _local(2026, 7, 26, 23, 59, 59), "amount_atomic": self.ONE_XMR},  # day before
            {"ts": _local(2026, 7, 27, 0, 0, 0), "amount_atomic": 2 * self.ONE_XMR},  # yesterday
            {"ts": _local(2026, 7, 27, 23, 59, 59), "amount_atomic": 4 * self.ONE_XMR},  # yesterday
            {"ts": _local(2026, 7, 28, 0, 0, 0), "amount_atomic": 8 * self.ONE_XMR},  # today
        ]
        s = confirmed_payouts_summary(payouts, now=self.NOW)
        assert s["xmr_yesterday"] == 6.0
        # The trailing 24h is a different span and deliberately disagrees: it reaches back into
        # yesterday noon and includes today's midnight payout.
        assert s["xmr_24h"] == 12.0

    def test_partial_flags_track_recorded_history(self):
        # History starts 10 days back: the 30d window reaches behind it (partial), 7d and yesterday
        # sit inside it (complete).
        payouts = [{"ts": self.NOW - 10 * 86_400, "amount_atomic": self.ONE_XMR}]
        s = confirmed_payouts_summary(payouts, now=self.NOW)
        assert s["partial"] == {"yesterday": False, "7d": False, "30d": True}

    def test_history_starting_today_marks_every_running_window(self):
        # First payout landed this morning — nothing on record covers yesterday, 7d or 30d.
        payouts = [{"ts": _local(2026, 7, 28, 9, 0), "amount_atomic": self.ONE_XMR}]
        s = confirmed_payouts_summary(payouts, now=self.NOW)
        assert s["partial"] == {"yesterday": True, "7d": True, "30d": True}

    def test_zero_timestamp_row_cannot_date_the_history(self):
        # A row with no usable ts must not win the since_ts minimum and declare every window
        # complete on the strength of a broken record.
        payouts = [
            {"ts": 0, "amount_atomic": self.ONE_XMR},
            {"ts": self.NOW - 2 * 86_400, "amount_atomic": self.ONE_XMR},
        ]
        s = confirmed_payouts_summary(payouts, now=self.NOW)
        assert s["since_ts"] == self.NOW - 2 * 86_400
        assert s["partial"]["30d"] is True

    def test_tari_unit_and_divisor(self):
        # Tari reuses the helper with the microTari divisor (1e6) and xtm_* keys.
        payouts = [{"ts": self.NOW, "amount_atomic": 2_500_000}]
        s = confirmed_payouts_summary(payouts, now=self.NOW, divisor=1_000_000, unit="xtm")
        assert s["xtm_all"] == 2.5
        assert "xtm_30d" in s and "xtm_yesterday" in s and "xmr_all" not in s
