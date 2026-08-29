"""Unit tests for the XvB/earnings/badges cluster (mining_dashboard/web/xvb_views.py).

Moved out of tests/web/test_views.py with the cluster itself (#1105). The test bodies are
verbatim; the only edits are module-alias reads that follow their targets from ``views`` to
``xvb_views``.

The shared builders — ``_SYNC_DONE``/``_BASE`` and the ``_metrics``, ``_sync``, ``_hashrate``,
``_state_mgr`` and ``_data`` factories — are pytest fixtures in ``tests/web/conftest.py`` as of
#1459. Each test that needs one takes it as a parameter; the call itself reads as it always did.
What is deliberately NOT shared, and why, is written in that file.
"""

import json
import subprocess
import sys
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import mining_dashboard.service.metrics as service_metrics
import mining_dashboard.web.views as views
import mining_dashboard.web.xvb_views as xvb_views
from mining_dashboard.config.config import XVB_STATS_STALE_AFTER_S
from mining_dashboard.web.xvb_views import (
    build_badges,
    build_earnings,
    build_earnings_vs_actual,
    build_xvb_calc,
    recent_wallet_change,
    xvb_current_tier_reward_day,
    xvb_expected_wins_day,
    xvb_realization,
    xvb_tempered_day,
)


def _xvb_archive():
    # In a checkout the repo root is three levels up (dashboard/ moved to the repo root, #1106);
    # inside the dashboard image the tests live at /app/tests and there is no repo root at all —
    # parents[3] itself raises there, so the lookup must fail soft for the skipif to see "absent".
    try:
        root = Path(__file__).parents[3]
    except IndexError:
        return None
    return (
        root
        / "docs"
        / "research"
        / "xvb-delivery-study"
        / "data"
        / "sources"
        / "xmrvsbeast-reward_estimate_pub.txt"
    )


_XVB_ARCHIVE = _xvb_archive()


# --- Badges ---------------------------------------------------------------------------


class TestBadges:
    def _texts(self, badges):
        return [b["text"] for b in badges]

    def test_syncing_shows_syncing_only(self, _metrics):
        out = build_badges({}, _metrics(global_syncing=True), "ok")
        assert "Syncing..." in self._texts(out)
        assert not any("P2POOL" in t for t in self._texts(out))

    def test_operational_shows_mode_and_pool(self, _metrics):
        out = build_badges({}, _metrics(mode="P2POOL", pool_type="Mini"), "ok")
        assert "P2POOL" in self._texts(out)
        assert "P2Pool Mini" in self._texts(out)

    def test_low_hr_badge(self, _metrics):
        out = build_badges({}, _metrics(low_hr_warning=True), "ok")
        assert any(b["variant"] == "warn" and "low for tier" in b["text"] for b in out)

    def test_no_share_badge_when_donating_without_a_share(self, _metrics):
        # XvB enabled + no PPLNS share => wins are skipped + a fail, regardless of tier (#158).
        out = build_badges({}, _metrics(xvb_enabled=True, shares_in_window=0), "ok")
        assert any("No PPLNS share" in b["text"] for b in out)

    def test_no_share_badge_absent_when_has_share_or_xvb_off(self, _metrics):
        # Has a share => no badge; XvB off => raffle moot, no badge.
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=True, shares_in_window=3), "ok")
            )
        )
        assert not any(
            "No PPLNS share" in t
            for t in self._texts(
                build_badges({}, _metrics(xvb_enabled=False, shares_in_window=0), "ok")
            )
        )

    def test_xvb_registered_badge(self, _metrics):
        # registered_at set + clean state => a muted "✓" confirmation badge (#263).
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registered_at=1.0), "ok")
        assert any(b["text"] == "XvB raffle ✓" and b["variant"] == "outline" for b in out)

    def test_xvb_invalid_wallet_badge(self, _metrics):
        # Endpoint rejected the wallet => loud "bad" badge so the user fixes MONERO_WALLET_ADDRESS.
        out = build_badges({}, _metrics(xvb_enabled=True, xvb_registration_state="invalid"), "ok")
        assert any(b["variant"] == "bad" and "wallet rejected" in b["text"] for b in out)

    def test_xvb_failing_badge_takes_priority_over_checkmark(self, _metrics):
        # A real problem must not be masked by a stale registered_at.
        out = build_badges(
            {},
            _metrics(xvb_enabled=True, xvb_registration_state="failing", xvb_registered_at=1.0),
            "ok",
        )
        assert any(b["variant"] == "bad" and "failing" in b["text"] for b in out)
        assert not any("✓" in b["text"] for b in out)

    def test_no_xvb_registration_badge_when_disabled(self, _metrics):
        out = build_badges({}, _metrics(xvb_enabled=False, xvb_registered_at=1.0), "ok")
        assert not any("XvB raffle" in b["text"] for b in out)

    def test_node_down_and_rejected(self, _metrics, _sync):
        m = _metrics(monero=_sync(down=True), tari=_sync(down=True))
        out = build_badges({"workers_rejected": True}, m, "ok")
        t = self._texts(out)
        assert "monerod DOWN" in t and "Tari DOWN" in t and "Workers rejected" in t

    def test_miner_held(self, _metrics):
        out = build_badges({"miner_held": True}, _metrics(global_syncing=True), "ok")
        assert "Miner held (sync)" in self._texts(out)

    def test_fail_closed_held(self, _metrics):
        # #490: distinct badge from the sync-gate hold above — fires post-sync, only with
        # dashboard.fail_closed on.
        out = build_badges({"fail_closed_held": True}, _metrics(), "ok")
        assert any(b["variant"] == "bad" and "Miner held (fail-closed)" in b["text"] for b in out)

    def test_no_fail_closed_badge_by_default(self, _metrics):
        out = build_badges({}, _metrics(), "ok")
        assert not any("fail-closed" in b["text"] for b in out)

    def test_passive_tari_with_and_without_percent(self, _metrics, _sync):
        with_pct = build_badges(
            {"tari_syncing_passive": True}, _metrics(tari=_sync(percent=42)), "ok"
        )
        assert "Tari syncing 42%" in self._texts(with_pct)
        no_pct = build_badges({"tari_syncing_passive": True}, _metrics(tari=_sync(percent=0)), "ok")
        assert "Tari syncing" in self._texts(no_pct)

    def test_monero_pruned_badge(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Pruned"), "ok")
        assert any(b["text"] == "XMR Pruned" and b["variant"] == "outline" for b in out)

    def test_monero_full_badge(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Full"), "ok")
        assert any(b["text"] == "XMR Full" and b["variant"] == "outline" for b in out)

    def test_no_prune_badge_when_unknown(self, _metrics):
        out = build_badges({}, _metrics(monero_mode="Unknown"), "ok")
        assert not any("XMR" in b["text"] for b in out)

    def test_disk_badge_critical(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 96}}}, _metrics(), "ok")
        assert any(b["variant"] == "bad" and "Disk 96% full" in b["text"] for b in out)

    def test_disk_badge_warn(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 88}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Disk 88% full" in b["text"] for b in out)

    def test_no_disk_badge_when_ample(self, _metrics):
        out = build_badges({"system": {"disk": {"percent": 50}}}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    def test_no_disk_badge_when_missing(self, _metrics):
        # No system/disk data (e.g. an early poll) must not emit a spurious or crashing badge.
        out = build_badges({}, _metrics(), "ok")
        assert not any("Disk" in b["text"] for b in out)

    # --- Host-perf badges (#104): AVX2 / HugePages / low RAM, from live metrics -------------
    def test_hugepages_disabled_badge(self, _metrics):
        out = build_badges(
            {"system": {"hugepages": ["Disabled", "status-bad", "0/0"]}}, _metrics(), "ok"
        )
        assert any(b["variant"] == "warn" and "HugePages off" in b["text"] for b in out)

    def test_no_hugepages_badge_when_reserved(self, _metrics):
        for status in ("Allocated", "Enabled", "Unknown"):  # only "Disabled" is a problem
            out = build_badges({"system": {"hugepages": [status, "", "1/2"]}}, _metrics(), "ok")
            assert not any("HugePages" in b["text"] for b in out), status

    def test_low_ram_badge_tracks_what_runs_locally(self, _metrics, monkeypatch):
        # The floor is MODE-AWARE: 8 GB is too little for a full-local stack, fine for a
        # coordinator whose nodes are remote — remote nodes take their appetite with them.
        import mining_dashboard.web.xvb_views as xvb_mod

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: True)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: True)
        out = build_badges({"system": {"memory": {"total_gb": 8}}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Low RAM (8 GB)" in b["text"] for b in out)

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: False)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: False)
        out = build_badges({"system": {"memory": {"total_gb": 8}}}, _metrics(), "ok")
        assert not any("Low RAM" in b["text"] for b in out)

    def test_low_ram_badge_counts_the_built_in_miner(self, _metrics, monkeypatch):
        # The Both role's risk case: both nodes local fits a 16 GB box (floor 14) — until the
        # built-in miner's own dataset joins them, when the same box honestly warns (floor 17).
        import mining_dashboard.config.config as cfg_mod
        import mining_dashboard.web.xvb_views as xvb_mod

        monkeypatch.setattr(xvb_mod, "monero_is_local", lambda: True)
        monkeypatch.setattr(xvb_mod, "tari_is_local", lambda: True)
        state = {"system": {"memory": {"total_gb": 15.6}}}
        assert not any("Low RAM" in b["text"] for b in build_badges(state, _metrics(), "ok"))

        monkeypatch.setattr(cfg_mod, "local_miner_enabled", lambda path=None: True)
        out = build_badges(state, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "Low RAM (16 GB)" in b["text"] for b in out)

    def test_no_low_ram_badge_at_or_above_threshold_or_unknown(self, _metrics):
        # 15.6 is what a NOMINAL 16 GB machine actually reports (reserved memory, GiB-vs-GB) —
        # the documented minimum spec must never wear a permanent warning. Bench-reported.
        for total in (15.6, 16, 14):
            assert not any(
                "Low RAM" in b["text"]
                for b in build_badges({"system": {"memory": {"total_gb": total}}}, _metrics(), "ok")
            ), total
        # total 0 = couldn't read /proc/meminfo (not "0 GB of RAM") — no false badge.
        assert not any(
            "Low RAM" in b["text"]
            for b in build_badges({"system": {"memory": {"total_gb": 0}}}, _metrics(), "ok")
        )

    def test_memory_pressure_badge_keys_on_LIVE_availability_not_capacity(self, _metrics):
        # A spec box quietly idling wears nothing; a box down to its last GB warns — whatever
        # its size. Capacity says what it could do; pressure says what is happening.
        out = build_badges(
            {"system": {"memory": {"total_gb": 15.6, "available_gb": 0.8}}}, _metrics(), "ok"
        )
        assert any(b["variant"] == "warn" and "Memory pressure" in b["text"] for b in out)
        out = build_badges(
            {"system": {"memory": {"total_gb": 15.6, "available_gb": 8.0}}}, _metrics(), "ok"
        )
        assert not any("Memory pressure" in b["text"] for b in out)
        # An older payload without available_gb must not fabricate a pressure reading.
        out = build_badges({"system": {"memory": {"total_gb": 15.6}}}, _metrics(), "ok")
        assert not any("Memory pressure" in b["text"] for b in out)

    def test_avx2_missing_badge(self, _metrics):
        out = build_badges({"system": {"avx2": False}}, _metrics(), "ok")
        assert any(b["variant"] == "warn" and "No AVX2" in b["text"] for b in out)

    def test_no_avx2_badge_when_present_or_unknown(self, _metrics):
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": True}}, _metrics(), "ok")
        )
        # None = couldn't determine (non-Linux / unreadable) — stay silent, don't cry wolf.
        assert not any(
            "AVX2" in b["text"] for b in build_badges({"system": {"avx2": None}}, _metrics(), "ok")
        )


# --- Payout-wallet tripwire banner (#375) ----------------------------------------------


class TestWalletChangedBadge:
    _NEW = "4B" + "b" * 93

    def _kv_mgr(self, **kv):
        sm = MagicMock()
        sm.get_kv.side_effect = kv.get
        return sm

    def test_recent_change_within_72h(self):
        sm = self._kv_mgr(
            payout_wallet_changed_ts="1000",
            payout_wallet=self._NEW,
            payout_wallet_prev8="4Aaaaaaa",
        )
        wc = recent_wallet_change(sm, now=1000 + 71 * 3600)
        assert wc == {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}

    def test_expired_after_72h(self):
        sm = self._kv_mgr(payout_wallet_changed_ts="1000", payout_wallet=self._NEW)
        assert recent_wallet_change(sm, now=1000 + 72 * 3600) is None

    def test_no_change_recorded(self):
        assert recent_wallet_change(self._kv_mgr()) is None

    def test_unreadable_ts_is_no_change(self):
        assert recent_wallet_change(self._kv_mgr(payout_wallet_changed_ts="junk")) is None

    def test_badge_rendered_and_truncated(self, _metrics):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(), "ok", wallet_change=wc)
        badge = next(b for b in out if "Payout wallet changed" in b["text"])
        assert badge["variant"] == "warn"
        assert "4Aaaaaaa…" in badge["title"] and f"{self._NEW[:8]}…" in badge["title"]
        assert self._NEW not in badge["title"]  # never the full address

    def test_shown_even_while_syncing(self, _metrics):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(global_syncing=True), "ok", wallet_change=wc)
        assert any("Payout wallet changed" in b["text"] for b in out)

    def test_no_badge_without_recent_change(self, _metrics):
        out = build_badges({}, _metrics(), "ok", wallet_change=None)
        assert not any("Payout wallet" in b["text"] for b in out)

    def test_build_state_surfaces_the_badge_from_kv(self, _data, _state_mgr):
        sm = _state_mgr()
        sm.get_kv.side_effect = {
            "payout_wallet_changed_ts": str(time.time() - 60),
            "payout_wallet": self._NEW,
            "payout_wallet_prev8": "4Aaaaaaa",
        }.get
        st = views.build_state(_data(), sm, "all")
        assert any("Payout wallet changed" in b["text"] for b in st["badges"])


# --- Expected vs actual earnings summary (#808) ---------------------------------------


def _summary_earnings(**over):
    """A minimal build_earnings-shaped dict — only the keys build_earnings_vs_actual reads."""
    e = {
        "coeff_day": 0.0,
        "confirmed": {"enabled": False},
        "tari_confirmed": {"enabled": False},
        "xvb_day": None,
    }
    e.update(over)
    return e


class TestEarningsVsActual:
    NOW = 1_760_000_000

    def test_combined_expected_folds_xvb_and_uses_the_window_average(self, _metrics):
        # ONE combined row (#817): expected = P2Pool linear (coeff_day × 30d-average × 30 — the
        # WINDOW's average, not the current 1h figure) + XvB's published per-day estimate × 30,
        # because the confirmed actual inevitably contains XvB win payouts. pct compares the
        # combined actual against the combined expectation.
        e = _summary_earnings(
            coeff_day=1e-8,
            xvb_day=0.001,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {"30d": False}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        expected = 1e-8 * 8000.0 * 30 + 0.001 * 30
        assert s["xmr"]["available"] is True
        assert s["xmr"]["includes_xvb"] is True
        assert s["xmr"]["expected_30d"] == pytest.approx(expected)
        assert s["xmr"]["actual_30d"] == 0.28
        assert s["xmr"]["pct"] == round(0.28 / expected * 100)
        assert s["xmr"]["partial"] is False

    def test_combined_row_without_a_fresh_xvb_estimate_stays_p2pool_only(self, _metrics):
        # XvB on but no fresh published figure (#712) -> nothing is fabricated: expected stays
        # P2Pool-only and includes_xvb False (the client label drops "+ XvB"; the tooltip owns
        # the fact that win payouts still land in the actual). XvB disabled behaves the same.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.1, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["includes_xvb"] is False
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30)
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0, xvb_enabled=False),
            _summary_earnings(coeff_day=1e-8, xvb_day=0.001),
            [],
            now=self.NOW,
        )
        assert s["xmr"]["includes_xvb"] is False  # disabled XvB never folds its estimate in

    def test_negative_published_estimate_never_folds(self, _metrics):
        # xvb_day is upstream-published — a hostile/corrupt negative must not drag the combined
        # expectation toward (or past) zero while available stays True: it folds as 0, the label
        # stays P2Pool-only, and pct keeps a positive denominator.
        e = _summary_earnings(
            coeff_day=1e-8,
            xvb_day=-5.0,
            # In-range actual (~83% of expected): pct must survive the >999% withhold to prove
            # the denominator stayed positive.
            confirmed={"enabled": True, "xmr_30d": 0.002, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["includes_xvb"] is False
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30)
        assert s["xmr"]["pct"] is not None and s["xmr"]["pct"] > 0

    def test_pct_withheld_when_the_expectation_is_dust(self, _metrics):
        # A box idle for most of the window that still confirmed normal payouts: the ratio
        # against a near-zero expectation is a five-digit figure that reads as a bug (#992).
        # Past 999% the pct is withheld — the client tooltip explains — never capped to a
        # number that would still look like data.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=1.0), e, [], now=self.NOW)
        assert s["xmr"]["available"] is True and s["xmr"]["enabled"] is True
        assert s["xmr"]["pct"] is None
        # At the boundary the figure still shows: 999% is large but legible.
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 1e-8 * 8000.0 * 30 * 9.99, "partial": {}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["pct"] == 999

    def test_xmr_row_degrades_honestly(self, _metrics):
        # Estimate unavailable (no network figures) -> not available, and no pct even with
        # confirmed payouts on; confirmation off -> actual/pct None, never a zero that would
        # read as "earned nothing".
        on = _summary_earnings(confirmed={"enabled": True, "xmr_30d": 0.5, "partial": {}})
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), on, [], now=self.NOW)
        assert s["xmr"]["available"] is False and s["xmr"]["pct"] is None
        off = _summary_earnings(coeff_day=1e-8)
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), off, [], now=self.NOW)
        assert s["xmr"]["enabled"] is False
        assert s["xmr"]["actual_30d"] is None and s["xmr"]["pct"] is None

    def test_xmr_partial_flag_rides_the_confirmed_window(self, _metrics):
        e = _summary_earnings(
            coeff_day=1e-8,
            confirmed={"enabled": True, "xmr_30d": 0.1, "partial": {"30d": True}},
        )
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), e, [], now=self.NOW)
        assert s["xmr"]["partial"] is True

    def test_tari_compares_block_counts_over_30d(self, _metrics):
        # Expected blocks = 30d-average hashrate × 30 days ÷ aux difficulty; actual = the
        # confirmed payout count (solo merge-mining: a payout IS a found block), XTM alongside.
        e = _summary_earnings(
            tari_confirmed={
                "enabled": True,
                "n_30d": 1,
                "xtm_30d": 12_345.0,
                "partial": {"30d": True},
            }
        )
        m = _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=True)
        s = build_earnings_vs_actual(m, e, [], now=self.NOW)
        assert s["tari"]["available"] is True
        assert s["tari"]["expected_blocks_30d"] == pytest.approx(10_000.0 * 30 * 86_400 / 4.0e12)
        assert s["tari"]["blocks_30d"] == 1
        assert s["tari"]["xtm_30d"] == 12_345.0
        assert s["tari"]["partial"] is True

    def test_tari_gates_on_mining_and_difficulty(self, _metrics):
        # A dead merge-mine channel (tari_mining False) or missing difficulty -> unavailable,
        # mirroring the calculator's gate, so no phantom expectation is shown.
        e = _summary_earnings()
        off = _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=False)
        assert build_earnings_vs_actual(off, e, [], now=self.NOW)["tari"]["available"] is False
        nodiff = _metrics(p2pool_30d=10_000.0, tari_difficulty=0.0, tari_mining=True)
        assert build_earnings_vs_actual(nodiff, e, [], now=self.NOW)["tari"]["available"] is False
        # Confirmation off -> counts None, not 0.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=10_000.0, tari_difficulty=4.0e12, tari_mining=True),
            e,
            [],
            now=self.NOW,
        )
        assert s["tari"]["blocks_30d"] is None and s["tari"]["xtm_30d"] is None

    def test_xvb_counts_wins_in_the_trailing_30d_only(self, _metrics):
        wins = [
            {"ts": self.NOW - 40 * 86_400},  # outside the window
            {"ts": self.NOW - 10 * 86_400},
            {"ts": self.NOW - 86_400},
        ]
        s = build_earnings_vs_actual(
            _metrics(), _summary_earnings(xvb_day=0.004), wins, now=self.NOW
        )
        assert s["xvb"]["enabled"] is True
        assert s["xvb"]["wins_30d"] == 2
        assert s["xvb"]["last_win_ts"] == self.NOW - 86_400
        # No published_day here since #817 — the estimate lives in the combined row's expected.
        assert "published_day" not in s["xvb"]
        s = build_earnings_vs_actual(
            _metrics(xvb_enabled=False), _summary_earnings(), [], now=self.NOW
        )
        assert s["xvb"]["enabled"] is False and s["xvb"]["wins_30d"] == 0

    def test_rides_build_state_end_to_end(self, _data, _state_mgr, monkeypatch):
        # The summary must reach the top-level payload the client polls, built from the SAME
        # earnings dict the Earnings card receives — one build, so the two cannot disagree.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        st = views.build_state(_data(), _state_mgr(), "all")
        assert set(st["earnings_summary"]) == {"xmr", "tari", "xvb"}
        assert st["earnings_summary"]["xmr"]["enabled"] is False

    def test_frontend_fixture_matches_payload_shape_at_every_depth(self, tmp_path):
        # Drift guard (#808 post-mortem, deepened for #974): the frontend render tests run against
        # tests/frontend/fixtures/state.json, "a real build_state() payload". When the payload
        # grows a key without the fixture being regenerated, every component gated on that key
        # silently renders its empty state across the whole frontend suite and the visual harness.
        # Top-level pinning missed exactly that one level down (#880: nested keys whose parents
        # exist on both sides), so this compares full dotted key paths — the Python mirror of
        # CONFIG_KEY_PATHS_JQ in tests/integration/lib.sh. Shape only, never values: the fixture
        # is regenerated by running _gen_state.py (deterministic) to a temp file, so value tweaks
        # don't churn the test, and structural drift in either direction fails it.
        def _dotted_paths(node, prefix=""):
            # jq `paths` semantics: every path as a dotted string, array indices included.
            items = node.items() if isinstance(node, dict) else enumerate(node)
            for key, value in items:
                path = f"{prefix}.{key}" if prefix else str(key)
                yield path
                if isinstance(value, (dict, list)):
                    yield from _dotted_paths(value, path)

        fixture = Path(__file__).parent.parent / "frontend" / "fixtures" / "state.json"
        gen = fixture.with_name("_gen_state.py")
        out = tmp_path / "state.json"
        subprocess.run(  # noqa: S603 — fixed argv: our own interpreter + a repo-tracked script
            [sys.executable, str(gen), str(out)], check=True, capture_output=True
        )
        live = set(_dotted_paths(json.loads(out.read_text())))
        pinned = set(_dotted_paths(json.loads(fixture.read_text())))
        missing, removed = sorted(live - pinned), sorted(pinned - live)
        assert not missing and not removed, (
            f"frontend fixture is stale — regenerate with tests/frontend/fixtures/_gen_state.py "
            f"(paths missing from fixture: {missing}; paths gone from payload: {removed})"
        )


# --- XvB honest economics: forecast win rate + measured realization (#866/#872) -------


_WINS_TIERS = {"donor": 1_000.0, "donor_vip": 10_000.0, "donor_whale": 100_000.0}
_WINS_STATS = {
    "stats": {
        "types": {
            "donor": {"rounds": 7, "players_avg": 70.0},
            "donor_vip": {"rounds": 28, "players_avg": 28.0},
            "donor_whale": {"rounds": 56, "players_avg": 8.0},
        },
        "span_days": 7.0,
    },
    "last_update": None,  # set fresh per test
}


def _round_state(stale=False):
    ts = time.time() - (XVB_STATS_STALE_AFTER_S + 1 if stale else 0)
    return {**_WINS_STATS, "last_update": ts}


class TestXvbExpectedWinsDay:
    def test_sums_every_donor_round_type_the_held_tier_qualifies_for(self):
        # A whale qualifier also plays the vip and donor rounds beneath it: the forecast is the
        # sum of each round type's frequency ÷ its qualifier count, not the whale rounds alone.
        out = xvb_expected_wins_day(_round_state(), "donor_whale", _WINS_TIERS)
        assert out == pytest.approx((56 / 7.0) / 8.0 + (28 / 7.0) / 28.0 + (7 / 7.0) / 70.0)
        # A donor-tier fleet only plays the donor rounds.
        assert xvb_expected_wins_day(_round_state(), "donor", _WINS_TIERS) == pytest.approx(
            (7 / 7.0) / 70.0
        )

    def test_missing_stale_or_empty_aggregate_yields_none(self):
        assert xvb_expected_wins_day(None, "donor_whale", _WINS_TIERS) is None
        assert xvb_expected_wins_day(_round_state(stale=True), "donor_whale", _WINS_TIERS) is None
        empty = {"stats": {"types": {}, "span_days": 0.0}, "last_update": time.time()}
        assert xvb_expected_wins_day(empty, "donor_whale", _WINS_TIERS) is None
        assert xvb_expected_wins_day(_round_state(), None, _WINS_TIERS) is None


_REALIZATION_NOW = 1_760_000_000


class TestXvbForecastTierKey:
    def test_held_tier_wins_over_target(self, _metrics):
        m = _metrics(xvb_1h=100_000.0, xvb_24h=100_000.0, target_threshold=10_000.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) == "donor_whale"

    def test_falls_back_to_the_target_tier_while_none_is_held(self, _metrics):
        # A fleet still ramping (or weighing whether to enable donation at all) has zero credited
        # average — the forecast speaks to the TARGET tier instead of dashing out (#866).
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=1_000.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) == "donor"

    def test_none_when_neither_held_nor_targeted(self, _metrics):
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=0.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) is None
        # A target threshold matching no tier (drifted config) stays None, never a KeyError.
        m = _metrics(xvb_1h=0.0, xvb_24h=0.0, target_threshold=123.0)
        assert xvb_views.xvb_forecast_tier_key(m, _WINS_TIERS) is None


class TestXvbRealization:
    NOW = _REALIZATION_NOW
    # 6 settled wins, hourly; face value 0.016 XMR/day at 1 expected win/day => 16 mXMR face/win.
    WINS = [{"ts": _REALIZATION_NOW - 86_400 - i * 3_600} for i in range(6)]

    def _payouts(self, per_win_atomic):
        # One payout landing 30 min after each win — squarely inside the attribution window.
        return [{"ts": w["ts"] + 1_800, "amount_atomic": per_win_atomic} for w in self.WINS]

    def test_measures_the_fraction_of_face_value_wins_actually_paid(self):
        # 3.2 mXMR realized per win against a 16 mXMR face => 0.2, with the sample size.
        out = xvb_realization(self._payouts(3_200_000_000), self.WINS, 0.016, 1.0, now=self.NOW)
        assert out == (pytest.approx(0.2), 6)

    def test_clamps_at_face_value_and_floors_at_zero(self):
        # A lucky window can overshoot face value — the factor is a discount, never a bonus.
        out = xvb_realization(self._payouts(32_000_000_000), self.WINS, 0.016, 1.0, now=self.NOW)
        assert out[0] == 1.0

    def test_too_few_wins_is_none_not_noise(self):
        out = xvb_realization(self._payouts(3_200_000_000), self.WINS[:4], 0.016, 1.0, now=self.NOW)
        assert out is None

    def test_unsettled_wins_are_left_out_of_the_sample(self):
        # A win still inside the settle window has payouts in flight — counting it would drag
        # the factor down for no reason. With it excluded the sample drops below the minimum.
        fresh = [{"ts": self.NOW - 600}] + self.WINS[:4]
        assert (
            xvb_realization(self._payouts(3_200_000_000), fresh, 0.016, 1.0, now=self.NOW) is None
        )

    def test_a_payout_in_two_overlapping_windows_counts_once(self):
        # Back-to-back wins share attribution windows; the payout sum iterates payouts, not
        # windows, so an overlapped payout cannot double-count.
        payout = {"ts": self.WINS[0]["ts"] + 900, "amount_atomic": 3_200_000_000}
        out = xvb_realization([payout], self.WINS, 0.016, 1.0, now=self.NOW)
        assert out == (pytest.approx(3.2e-3 / 6 / 0.016), 6)

    def test_missing_inputs_yield_none(self):
        assert xvb_realization(None, self.WINS, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization([], self.WINS, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), None, 0.016, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, None, 1.0, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, 0.016, None, now=self.NOW) is None
        assert xvb_realization(self._payouts(1), self.WINS, 0.016, 0.0, now=self.NOW) is None
        # A hostile/corrupt negative published figure gives a negative face value — no factor.
        assert xvb_realization(self._payouts(1), self.WINS, -0.016, 1.0, now=self.NOW) is None

    def test_baseline_subtraction_removes_ordinary_p2pool_leak(self):
        # Ordinary P2Pool payouts land inside win windows too; the box's linear rate over the
        # windowed hours is subtracted so the factor measures only the wins' excess. Here the
        # 4.8 mXMR gross per win contains 1.6 mXMR of baseline (6.4 mXMR/day × 6h): excess
        # 3.2 mXMR against a 16 mXMR face => 0.2, not the inflated 0.3.
        out = xvb_realization(
            self._payouts(4_800_000_000), self.WINS, 0.016, 1.0, now=self.NOW, p2pool_day=0.0064
        )
        assert out == (pytest.approx(0.2), 6)


class TestXvbTemperedDay:
    """The calculator/energy figure ships tempered — never XvB's raw published number (#902)."""

    def test_measured_realization_beats_the_prior(self):
        assert xvb_tempered_day(0.016, (0.19, 15)) == pytest.approx(0.016 * 0.19)

    def test_unmeasured_falls_back_to_the_prior_midpoint(self):
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert xvb_tempered_day(0.016, None) == pytest.approx(0.016 * (lo + hi) / 2)

    def test_never_the_raw_published_figure(self):
        # Whichever branch resolves, face value must not survive the tempering.
        assert xvb_tempered_day(0.016, None) < 0.016
        assert xvb_tempered_day(0.016, (0.99, 5)) < 0.016

    def test_nothing_published_passes_through(self):
        # None (no fresh estimate / XvB off) and 0 stay as-is — nothing fabricated either way.
        assert xvb_tempered_day(None, None) is None
        assert xvb_tempered_day(None, (0.19, 15)) is None
        assert xvb_tempered_day(0.0, (0.19, 15)) == 0.0

    def test_build_state_ships_tempered_while_the_summary_keeps_face_value(
        self, _data, _state_mgr, monkeypatch
    ):
        # The wiring the issue is about: est.xvbDay (earnings.xvb_day) leaves build_state
        # tempered, while the expected-vs-actual summary still works from the face value (it
        # applies the measured factor itself — feeding it the tempered figure would double-count).
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(service_metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(views, "xvb_current_tier_reward_day", lambda m, s: 0.016)
        monkeypatch.setattr(views, "xvb_realization", lambda *a, **k: (0.25, 6))
        st = views.build_state(_data(), _state_mgr(), "all")
        assert st["earnings"]["xvb_day"] == pytest.approx(0.016 * 0.25)
        # Measured tempering applied exactly ONCE on the summary side (0.016 × 30 × 0.25).
        assert st["earnings_summary"]["xmr"]["expected_30d"] == pytest.approx(0.016 * 30 * 0.25)

    def test_build_state_unmeasured_box_ships_the_prior_midpoint(
        self, _data, _state_mgr, monkeypatch
    ):
        # No measured wins: the calculator figure drops to the prior midpoint; the summary keeps
        # the face value (its tooltip labels it an upper bound) — asymmetric by design.
        monkeypatch.setattr(views.config, "PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(views.config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
        monkeypatch.setattr(service_metrics, "ENABLE_XVB", True)
        monkeypatch.setattr(views, "xvb_current_tier_reward_day", lambda m, s: 0.016)
        monkeypatch.setattr(views, "xvb_realization", lambda *a, **k: None)
        st = views.build_state(_data(), _state_mgr(), "all")
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert st["earnings"]["xvb_day"] == pytest.approx(0.016 * (lo + hi) / 2)
        assert st["earnings_summary"]["xmr"]["expected_30d"] == pytest.approx(0.016 * 30)


class TestEarningsVsActualTempering:
    NOW = 1_760_000_000

    def _e(self):
        return _summary_earnings(
            coeff_day=1e-8,
            xvb_day=0.016,
            confirmed={"enabled": True, "xmr_30d": 0.28, "partial": {"30d": False}},
        )

    def test_measured_realization_tempers_the_xvb_leg(self, _metrics):
        # The published leg (0.016 × 30 = 0.48) scales to the measured fraction; the factor and
        # its sample ride along for the tooltip. The P2Pool leg is untouched.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW, realization=(0.19, 15)
        )
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30 + 0.016 * 30 * 0.19)
        assert s["xmr"]["xvb_realization_pct"] == 19
        assert s["xmr"]["xvb_wins_measured"] == 15
        assert s["xmr"]["includes_xvb"] is True

    def test_without_a_measured_factor_the_published_figure_stands(self, _metrics):
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW)
        assert s["xmr"]["expected_30d"] == pytest.approx(1e-8 * 8000.0 * 30 + 0.016 * 30)
        assert s["xmr"]["xvb_realization_pct"] is None
        assert s["xmr"]["xvb_wins_measured"] is None

    def test_realization_without_an_xvb_leg_is_ignored(self, _metrics):
        # XvB off (or no fresh estimate): there is no leg to temper — the factor must not leak
        # into the payload as if one existed.
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0, xvb_enabled=False),
            self._e(),
            [],
            now=self.NOW,
            realization=(0.19, 15),
        )
        assert s["xmr"]["xvb_realization_pct"] is None

    def test_expected_wins_fill_the_xvb_row(self, _metrics):
        s = build_earnings_vs_actual(
            _metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW, expected_wins_day=0.84
        )
        assert s["xvb"]["expected_wins_30d"] == pytest.approx(25.2)
        s = build_earnings_vs_actual(_metrics(p2pool_30d=8000.0), self._e(), [], now=self.NOW)
        assert s["xvb"]["expected_wins_30d"] is None


# --- Earnings calculator (Issue #12) --------------------------------------------------


class TestEarnings:
    _NET = {"network": {"reward": 600_000_000_000}}  # 0.6 XMR block reward (atomic units)

    def test_publishes_rate_and_inputs(self, _metrics):
        # The server sends the daily XMR-per-H/s *rate* + the raw inputs the client scales/inverts
        # (the P2Pool hashrate, P2Pool share difficulty) — not pre-formatted earnings.
        e = build_earnings(
            self._NET,
            _metrics(
                p2pool_1h=10500, network_difficulty=400_000_000_000, pool_difficulty=250_000_000
            ),
        )
        assert e["available"] is True
        assert e["p2pool_hr"] == 10500
        assert e["p2pool_hr_str"] == "10.50 kH/s"
        assert e["pool_difficulty"] == 250_000_000
        assert e["block_reward"] == "0.6000 XMR"
        # The disclaimer makes the P2Pool-only scope explicit (not XvB / not Tari).
        assert e["disclaimer"] and "P2Pool mining only" in e["disclaimer"]
        # Rate matches reward_xmr / difficulty * 86400.
        assert e["coeff_day"] == pytest.approx(0.6 / 400_000_000_000 * 86_400)

    def test_default_hashrate_is_the_displayed_p2pool_1h(self, _hashrate, _metrics):
        # Consistency: the calculator's default must be the *same* P2Pool 1h average shown in the
        # header / Overview (metrics.p2pool_1h) — not the total, and not a bespoke total-minus-routed
        # figure. That recorded average already excludes the XvB-donated slice, so the value here
        # (and its display string) matches build_hashrate's "p2p_1h" exactly.
        m = _metrics(total_h15=46_300, xvb_routed_1h=10_000, p2pool_1h=35_000)
        e = build_earnings(self._NET, m)
        assert e["p2pool_hr"] == 35_000  # p2pool_1h, independent of total/routed
        assert (
            e["p2pool_hr_str"] == _hashrate(m)["p2p_1h"]
        )  # identical display string to the header

    def test_no_p2pool_hashrate_when_average_is_zero(self, _metrics):
        # E.g. fresh start (no history) or full-XvB: p2pool_1h is 0 -> client shows 0 / "—" (honest).
        e = build_earnings(self._NET, _metrics(p2pool_1h=0))
        assert e["p2pool_hr"] == 0.0

    def test_unavailable_when_network_reward_missing(self, _metrics):
        # No reward collected yet -> rate is unavailable; the card degrades to "—" (no crash).
        e = build_earnings({}, _metrics(network_difficulty=400_000_000_000))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0
        assert e["block_reward"] == "0.0000 XMR"

    def test_unavailable_when_difficulty_missing(self, _metrics):
        e = build_earnings(self._NET, _metrics(network_difficulty=0))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0

    def test_p2pool_hr_passthrough_is_raw(self, _metrics):
        # The what-if default must be the exact P2Pool H/s (not the rounded display string), so
        # the client's default estimate isn't skewed by display rounding.
        e = build_earnings(self._NET, _metrics(p2pool_1h=10543.7))
        assert e["p2pool_hr"] == 10543.7

    def test_tari_rate_published_when_merge_mining(self, _metrics):
        # #117: with live Tari figures + merge-mining active, the payload carries the XTM rate
        # (reward_xtm / difficulty * 86400) for the client to scale — same shape as coeff_day.
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=True, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is True
        assert e["tari_coeff_day"] == pytest.approx(13_000.0 / 420_000_000_000 * 86_400)
        # Solo merge-mining headline (#117 v1.3.1): the seconds-to-block-per-H/s figure (== the
        # Tari difficulty, so the client does diff / hashrate) and the full per-block reward.
        assert e["tari_difficulty"] == pytest.approx(420_000_000_000)
        assert e["tari_reward"] == pytest.approx(13_000.0)

    def test_tari_unavailable_without_figures_or_mining(self, _metrics):
        # No difficulty collected (inactive/syncing) → unavailable; and a positive rate with
        # merge-mining OFF must also read unavailable (a dead channel earns no phantom XTM).
        e = build_earnings(self._NET, _metrics(tari_mining=True, tari_reward=13_000.0))
        assert e["tari_available"] is False
        assert e["tari_coeff_day"] == 0.0
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=False, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is False

    def test_tari_unavailability_leaves_xmr_estimate_intact(self, _metrics):
        # Tari degrading to "—" must not drag the XMR side down: available stays True.
        e = build_earnings(self._NET, _metrics(tari_mining=False))
        assert e["available"] is True
        assert e["coeff_day"] > 0

    def test_confirmed_disabled_by_default(self, _metrics):
        # No payouts passed (feature off) → the confirmed block reports disabled; UI shows only estimate.
        e = build_earnings(self._NET, _metrics())
        assert e["confirmed"] == {"enabled": False}

    # ponytail: the yesterday/24h/7d/30d/all windowing math is proven once, in
    # tests/service/test_earnings.py::TestConfirmedPayoutsSummary — this class only asserts
    # build_earnings passes payouts through (enabled/empty/disabled).

    def test_confirmed_enabled_but_empty(self, _metrics):
        # Feature on, nothing confirmed yet → enabled with zeroed totals (shows 0.000000, not "—").
        # No history on record, so every running window is flagged partial (#787).
        e = build_earnings(self._NET, _metrics(), payouts=[])
        assert e["confirmed"] == {
            "enabled": True,
            "count": 0,
            "xmr_24h": 0.0,
            "xmr_yesterday": 0.0,
            "xmr_7d": 0.0,
            "xmr_30d": 0.0,
            "xmr_all": 0.0,
            "n_30d": 0,
            "last_ts": 0,
            "since_ts": 0,
            "partial": {"yesterday": True, "7d": True, "30d": True},
        }

    def test_tari_confirmed_disabled_by_default(self, _metrics):
        # No tari_payouts passed (Tari feature off) → tari_confirmed reports disabled.
        e = build_earnings(self._NET, _metrics())
        assert e["tari_confirmed"] == {"enabled": False}

    def test_tari_confirmed_enabled_but_empty(self, _metrics):
        e = build_earnings(self._NET, _metrics(), tari_payouts=[])
        assert e["tari_confirmed"] == {
            "enabled": True,
            "count": 0,
            "xtm_24h": 0.0,
            "xtm_yesterday": 0.0,
            "xtm_7d": 0.0,
            "xtm_30d": 0.0,
            "xtm_all": 0.0,
            "n_30d": 0,
            "last_ts": 0,
            "since_ts": 0,
            "partial": {"yesterday": True, "7d": True, "30d": True},
        }


# --- XvB tier / raffle calculator (Issue #118) -----------------------------------------


class TestXvbCalc:
    # Includes a zero-threshold entry to prove it's filtered out of the published table.
    _TIERS = {
        "donor_mega": 1_000_000,
        "donor_whale": 100_000,
        "donor_vip": 10_000,
        "donor": 1_000,
        "off": 0,
    }

    # XvB's published per-tier expected rewards, keyed by round-type == tier key (#118).
    _ESTIMATES = {"donor": 0.06, "donor_vip": 0.81, "donor_whale": 6.17, "donor_mega": 56.9}

    # All-rounds aggregate from the winners file (#872): frequencies + qualifier counts over
    # a one-week span, shaped like parse_round_stats' output.
    _ROUND_STATS = {
        "types": {
            "donor": {"rounds": 7, "players_avg": 70.0},
            "donor_vip": {"rounds": 28, "players_avg": 28.0},
            "donor_whale": {"rounds": 56, "players_avg": 8.0},
            "donor_mega": {"rounds": 63, "players_avg": 1.0},
        },
        "span_days": 7.0,
    }

    def _sm(self, estimates=None, last_update=None, round_stats=None, round_ts=None):
        sm = MagicMock()
        sm.get_tiers.return_value = self._TIERS
        est = self._ESTIMATES if estimates is None else estimates
        ts = time.time() if last_update is None else last_update
        sm.get_xvb_reward_estimates.return_value = {"estimates": est, "last_update": ts}
        stats = self._ROUND_STATS if round_stats is None else round_stats
        sm.get_xvb_round_stats.return_value = {
            "stats": stats,
            "last_update": time.time() if round_ts is None else round_ts,
        }
        return sm

    def test_disabled_still_publishes_the_decision_table(self, _metrics):
        # #938: XvB off no longer collapses the payload to the bare flag — the table is the
        # enable/don't-enable decision aid, so the tiers, draw odds, and prior band publish
        # either way (from local config + the cached feeds; the flag stops the fetches, so a
        # never-enabled box degrades through the same staleness rules as always). enabled=False
        # still rides along: the client's live-donation surfaces key off it.
        out = build_xvb_calc(
            _metrics(xvb_enabled=False, current_tier="Disabled", target_tier="Disabled"),
            self._sm(),
        )
        assert out["enabled"] is False
        assert [t["threshold"] for t in out["tiers"]] == [1_000, 10_000, 100_000, 1_000_000]
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        assert whale["win_odds_day"] == pytest.approx((56 / 7.0) / 8.0)
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert whale["assumed_reward_year_range"] == pytest.approx([6.17 * lo, 6.17 * hi])
        assert out["max_fraction"] == xvb_views.XVB_MAX_DONATION_FRACTION
        # Live-credit context passes through what Metrics reports on a disabled box; realization
        # is never computed while off (build_state's gate), so the measured fields stay None.
        assert out["current_tier"] == "Disabled"
        assert out["realization_pct"] is None

    def test_tier_table_sorted_ascending_and_zero_thresholds_dropped(self, _metrics):
        out = build_xvb_calc(_metrics(), self._sm())
        assert [t["threshold"] for t in out["tiers"]] == [1_000, 10_000, 100_000, 1_000_000]
        # Names come from get_tier_info, threshold already embedded — same string as everywhere.
        assert out["tiers"][1]["name"] == "Vip (10.00 kH/s+)"

    def test_mirrors_metrics_and_config(self, _metrics):
        # Current/target state is passed straight through from Metrics — no tier math re-derived
        # here — and max_fraction is the configured sustainability headroom rule.
        m = _metrics(
            current_tier="Donor (1.00 kH/s+)",
            target_tier="Vip (10.00 kH/s+)",
            target_threshold=10_000.0,
            target_sustainable=False,
        )
        out = build_xvb_calc(m, self._sm())
        assert out["enabled"] is True
        assert out["current_tier"] == "Donor (1.00 kH/s+)"
        assert out["target_tier"] == "Vip (10.00 kH/s+)"
        assert out["target_threshold"] == 10_000.0
        assert out["sustainable"] is False
        assert out["max_fraction"] == xvb_views.XVB_MAX_DONATION_FRACTION
        # The labelling the issue demands: tier = raffle status, never a payout.
        assert "not an XMR payout" in out["note"]

    def test_sidechain_mode_note_only_off_main(self, _metrics):
        # #33 context: off the Main sidechain, a pool switch resets PPLNS shares (and with them
        # XvB win collectability) — display-only text, absent on Main.
        assert build_xvb_calc(_metrics(pool_type="Main"), self._sm())["mode_note"] is None
        note = build_xvb_calc(_metrics(pool_type="Mini"), self._sm())["mode_note"]
        assert "PPLNS" in note

    def test_fresh_estimates_expose_per_tier_expected_reward(self, _metrics):
        # #118: each tier carries XvB's own published XMR/year figure, mapped by the tier key
        # (== round-type), and the estimates_available flag is set on a fresh fetch.
        out = build_xvb_calc(_metrics(), self._sm())
        assert out["estimates_available"] is True
        assert out["estimates_stale"] is False
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == 0.06  # donor
        assert by_threshold[10_000] == 0.81  # donor_vip
        assert by_threshold[100_000] == 6.17  # donor_whale
        assert by_threshold[1_000_000] == 56.9  # donor_mega

    def test_enabled_stale_estimates_do_not_use_the_fallback(self, _metrics):
        # #1214 regression: an ENABLED box whose fetch is merely failing right now (a transient
        # bot-challenge, a network blip — the sync loop writes only on success) must NOT get the
        # vendored fallback. That box isn't "off"; claiming "published, not live because XvB is
        # off" would be a straight lie. It keeps exactly the pre-#1214 honest degradation: no
        # per-tier number implied fresh, estimates_available False, estimates_source "none".
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=True), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is True
        assert out["estimates_source"] == "none"
        assert out["estimates_published_date"] is None
        assert all(t["expected_reward_year"] is None for t in out["tiers"])
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])

    def test_disabled_stale_falls_back_to_the_published_table(self, _metrics):
        # A DISABLED box whose cache aged out while off — "just-disabled" in the issue's terms —
        # gets the vendored fallback: no per-tier number implied FRESH (estimates_available stays
        # False), but expected_reward_year fills in from XvB's own last-published table (never a
        # live number, and labelled as such via estimates_source).
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is True
        assert out["estimates_source"] == "published"
        assert out["estimates_published_date"] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK_DATE
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[100_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]

    def test_disabled_never_fetched_falls_back_to_the_published_table(self, _metrics):
        # #1214's actual bug report: a box that has NEVER enabled XvB has no cache at all (never
        # fetched, not merely stale). Same fallback, same labelling.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is False
        assert out["estimates_source"] == "published"
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[10_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_vip"]
        assert by_threshold[100_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]
        assert by_threshold[1_000_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_mega"]

    @pytest.mark.skipif(
        _XVB_ARCHIVE is None or not _XVB_ARCHIVE.exists(),
        reason="the delivery-study archive lives outside the dashboard image's build context; "
        "this parity guard runs in the checkout-based dashboard CI job, which fails loudly "
        "if the fallback and the archive ever disagree",
    )
    def test_fallback_values_match_the_archived_source_files_player_rows(self):
        # #1214 guard: the vendored fallback must be the PER-PLAYER row XvB publishes, exactly
        # what the live parser would extract — never the pool-total row just above it (that
        # figure is the whole round's payout, not one qualifier's share, and is 7-70x larger).
        # Parses the archived source with the real live parser
        # (mining_dashboard.client.xvb_client.parse_reward_estimates, the exact regex a live
        # fetch uses) so a future re-vendor from the wrong column fails this test immediately
        # instead of silently drifting from what a live fetch would ever show.
        from mining_dashboard.client.xvb_client import DONOR_ROUND_TYPES, parse_reward_estimates

        parsed = parse_reward_estimates(_XVB_ARCHIVE.read_text())
        assert set(parsed) == set(DONOR_ROUND_TYPES)  # the archive still names all four tiers
        assert xvb_views.XVB_PUBLISHED_REWARD_FALLBACK == parsed

    def test_round_stats_expose_per_tier_draw_odds(self, _metrics):
        # #872: the winners file's players column makes the draw knowable — each tier carries its
        # OWN round type's frequency ÷ qualifiers (the earnings card's forecast, by contrast,
        # sums the lower tiers a qualifier also plays in).
        out = build_xvb_calc(_metrics(), self._sm())
        by_threshold = {t["threshold"]: t for t in out["tiers"]}
        assert by_threshold[100_000]["win_odds_day"] == pytest.approx((56 / 7.0) / 8.0)
        assert by_threshold[100_000]["players_avg"] == 8.0
        # The single-qualifier artifact is self-evident: one Mega player, one win per draw.
        assert by_threshold[1_000_000]["players_avg"] == 1.0

    def test_stale_or_missing_round_stats_null_the_odds(self, _metrics):
        stale = self._sm(round_ts=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        assert all(t["win_odds_day"] is None for t in build_xvb_calc(_metrics(), stale)["tiers"])
        empty = self._sm(round_stats={"types": {}, "span_days": 0.0}, round_ts=0.0)
        assert all(t["win_odds_day"] is None for t in build_xvb_calc(_metrics(), empty)["tiers"])

    def test_realization_scales_published_rewards_into_realized(self, _metrics):
        # #872: with a measured factor, every tier carries published × factor — the figure whose
        # net can honestly be acted on — plus the factor and its sample size for the label.
        out = build_xvb_calc(_metrics(), self._sm(), realization=(0.19, 15))
        by_threshold = {t["threshold"]: t for t in out["tiers"]}
        assert by_threshold[100_000]["realized_reward_year"] == pytest.approx(6.17 * 0.19)
        assert out["realization_pct"] == 19
        assert out["realization_wins"] == 15

    def test_unmeasured_boxes_get_the_prior_band_measured_boxes_do_not(self, _metrics):
        # #872: no local measurement -> published × the measured prior band, so "should I enable
        # this" is answerable everywhere. A measured factor supersedes it (never both).
        out = build_xvb_calc(_metrics(), self._sm())
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        lo, hi = xvb_views.XVB_REALIZATION_PRIOR
        assert whale["assumed_reward_year_range"] == pytest.approx([6.17 * lo, 6.17 * hi])
        out = build_xvb_calc(_metrics(), self._sm(), realization=(0.19, 15))
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])
        # A measured factor still wins even on a DISABLED, stale box where #1214's vendored
        # fallback is otherwise eligible — "yours" always supersedes the band, fallback or not.
        stale = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(xvb_enabled=False), stale, realization=(0.19, 15))
        assert all(t["assumed_reward_year_range"] is None for t in out["tiers"])
        # Same DISABLED, stale box with NO measured factor: #1214's fallback fills the band from
        # the published face value instead of leaving it null — the whole point of the fallback.
        # (An ENABLED, stale box must NOT do this — see test_enabled_stale_estimates_do_not_use_
        # the_fallback — the fallback is gated on the box being off, not merely stale.)
        out = build_xvb_calc(_metrics(xvb_enabled=False), stale)
        whale = next(t for t in out["tiers"] if t["threshold"] == 100_000)
        face = xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor_whale"]
        assert whale["assumed_reward_year_range"] == pytest.approx([face * lo, face * hi])

    def test_no_realization_leaves_realized_none(self, _metrics):
        # Unmeasured (too few wins / payout confirmation off): realized stays None so the client
        # falls back to face value AND says so — never a fabricated factor.
        out = build_xvb_calc(_metrics(), self._sm())
        assert all(t["realized_reward_year"] is None for t in out["tiers"])
        assert out["realization_pct"] is None
        # Stale estimates null realized too — a factor cannot resurrect a stale face value.
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        out = build_xvb_calc(_metrics(), sm, realization=(0.5, 9))
        assert all(t["realized_reward_year"] is None for t in out["tiers"])

    def test_empty_estimates_available_false_no_crash(self, _metrics):
        # Never fetched / unparseable cache on an ENABLED box (e.g. mid cold-start right after
        # enabling, or persistently-failing fetches — never "off"): available False, not "stale"
        # (last_update 0), and #1214's fallback must NOT fire here — same gate as the stale case,
        # see test_enabled_stale_estimates_do_not_use_the_fallback. The never-enabled-XvB box the
        # issue is actually about is test_disabled_never_fetched_falls_back_to_the_published_table.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=True), sm)
        assert out["estimates_available"] is False
        assert out["estimates_stale"] is False
        assert out["estimates_source"] == "none"
        assert all(t["expected_reward_year"] is None for t in out["tiers"])

    def test_fallback_never_backs_realized_reward_year(self, _metrics):
        # #1214: THIS wallet's own measured delivery factor must never be applied to a dated,
        # generic fallback figure — that would overstate precision the wallet has no basis for.
        # realized_reward_year keeps requiring a LIVE, fresh estimate even when realization is
        # (unusually) supplied alongside a disabled box's empty cache.
        sm = self._sm(estimates={}, last_update=0.0)
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm, realization=(0.5, 9))
        assert all(t["realized_reward_year"] is None for t in out["tiers"])
        # expected_reward_year still gets the fallback — only realized_reward_year is withheld.
        assert any(t["expected_reward_year"] is not None for t in out["tiers"])

    def test_fallback_skips_tiers_the_published_table_does_not_name(self, _metrics):
        # A custom TIER_CONFIG round-type the archived table never named degrades to None, same
        # as before this fix — the fallback is a fixed vendored table, never invented per key.
        sm = self._sm(estimates={}, last_update=0.0)
        sm.get_tiers.return_value = {"donor": 1_000, "custom_tier": 5_000}
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        by_threshold = {t["threshold"]: t["expected_reward_year"] for t in out["tiers"]}
        assert by_threshold[1_000] == xvb_views.XVB_PUBLISHED_REWARD_FALLBACK["donor"]
        assert by_threshold[5_000] is None

    def test_live_estimates_report_source_live_no_fallback_date(self, _metrics):
        # A fresh live fetch must be labelled "live", never "published" — the two must never be
        # ambiguous to the client, which uses this to decide the disabled-note wording.
        out = build_xvb_calc(_metrics(), self._sm())
        assert out["estimates_source"] == "live"
        assert out["estimates_published_date"] is None

    def test_never_fetched_and_fallback_missing_reports_source_none(self, _metrics):
        # A DISABLED box whose future TIER_CONFIG names nothing the fallback recognises must
        # still report "none" rather than falsely claiming "published" — isolates the "fallback
        # dict has no matching key" case from the enabled/disabled gate (test above).
        sm = self._sm(estimates={}, last_update=0.0)
        sm.get_tiers.return_value = {"custom_tier": 5_000}
        out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        assert out["estimates_source"] == "none"
        assert out["estimates_published_date"] is None

    def test_disabled_path_never_touches_the_network_layer(self, _metrics):
        # #163's no-egress-when-disabled contract, at this tier: filling the decision table's
        # reward columns from #1214's vendored fallback must never make an outbound HTTP call —
        # build_xvb_calc only reads state_mgr (local) and the static XVB_PUBLISHED_REWARD_FALLBACK
        # dict. Patches BOTH the chokepoint every real XvB fetch goes through
        # (mining_dashboard.helper.http.bounded_get) AND requests' own low-level entry point
        # (requests.sessions.Session.request, what requests.get ultimately calls), so a
        # regression that wires an on-demand fetch into this path — through the shared helper or
        # straight through requests — fails this test immediately rather than passing quietly.
        import requests

        import mining_dashboard.helper.http as http_mod

        def _dial(*a, **k):
            raise AssertionError("build_xvb_calc must never dial out while XvB is disabled")

        sm = self._sm(estimates={}, last_update=0.0)
        with (
            patch.object(http_mod, "bounded_get", side_effect=_dial),
            patch.object(requests.sessions.Session, "request", side_effect=_dial),
        ):
            out = build_xvb_calc(_metrics(xvb_enabled=False), sm)
        # And the fallback did its job — the dashes are gone, not just "no crash".
        assert out["estimates_source"] == "published"
        assert all(t["expected_reward_year"] is not None for t in out["tiers"])

    # --- current-tier reward folded into net profit (#712) ---------------------------

    def test_reward_day_is_current_tier_estimate_over_365(self, _metrics):
        # Base metrics credit min(xvb_1h=2100, xvb_24h=2300)=2100 → the donor tier (>=1000, <10k);
        # its published 0.06 XMR/year becomes 0.06/365 XMR/day. The estimate feeds est.xvbDay.
        out = xvb_current_tier_reward_day(_metrics(), self._sm())
        assert out == pytest.approx(0.06 / 365)

    def test_reward_day_uses_lower_of_1h_24h_not_the_higher(self, _metrics):
        # The current tier is the LOWER of the two credited averages (not target): a 1h dip to the
        # donor tier holds there even while 24h still clears whale — the honest "what you hold now".
        out = xvb_current_tier_reward_day(_metrics(xvb_1h=2100, xvb_24h=200_000), self._sm())
        assert out == pytest.approx(0.06 / 365)  # donor, not whale (6.17)

    def test_reward_day_maps_higher_tier_to_its_own_estimate(self, _metrics):
        # min(150k, 200k)=150k clears donor_whale (100k) → its 6.17/year, proving the tier→key→
        # estimate mapping picks the right round-type, not always the lowest.
        out = xvb_current_tier_reward_day(_metrics(xvb_1h=150_000, xvb_24h=200_000), self._sm())
        assert out == pytest.approx(6.17 / 365)

    def test_reward_day_none_when_xvb_disabled(self, _metrics):
        assert xvb_current_tier_reward_day(_metrics(xvb_enabled=False), self._sm()) is None

    def test_reward_day_none_below_lowest_donor_tier(self, _metrics):
        # min(500, 800)=500 < the 1000 donor threshold → "None" tier, nothing published to credit.
        assert xvb_current_tier_reward_day(_metrics(xvb_1h=500, xvb_24h=800), self._sm()) is None

    def test_reward_day_none_when_estimate_stale(self, _metrics):
        # Same staleness gate as the XvB card (#311): never surface a frozen number implied fresh.
        sm = self._sm(last_update=time.time() - XVB_STATS_STALE_AFTER_S - 1)
        assert xvb_current_tier_reward_day(_metrics(), sm) is None

    def test_reward_day_none_when_estimate_absent(self, _metrics):
        # Held a tier, but XvB never published a figure for it → None, never a fabricated 0.
        sm = self._sm(estimates={"donor_vip": 0.81}, last_update=time.time())
        assert xvb_current_tier_reward_day(_metrics(), sm) is None
