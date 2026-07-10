"""Unit tests for the Prometheus exposition renderer (#379).

Feeds a hand-built ``Metrics`` (direct constructor) and asserts exact output lines — the
renderer is a pure function, so tier 1 proves it completely.
"""

import re

from mining_dashboard.service.metrics import Metrics, SyncMetric
from mining_dashboard.web.prometheus import CONTENT_TYPE, render_prometheus


def _sync(percent=100, down=False):
    return SyncMetric(
        percent=percent,
        current=10,
        target=10,
        remaining=0,
        has_target=True,
        done=True,
        down=down,
    )


def _metrics(**overrides):
    kwargs = dict(
        total_h15=12500.0,
        p2pool_1h=1500.0,
        p2pool_24h=1400.5,
        xvb_1h=900.0,
        xvb_24h=800.0,
        xvb_routed_1h=950.0,
        xvb_routed_24h=850.0,
        stratum_h15=12000.0,
        stratum_h1h=11000.0,
        stratum_h24h=10000.0,
        mode="SPLIT",
        xvb_enabled=True,
        current_tier="Donor",
        target_tier="Donor VIP",
        target_threshold=1000.0,
        target_sustainable=True,
        low_hr_warning=False,
        xvb_fail_count=0,
        xvb_last_update=0.0,
        workers_online=3,
        workers_total=4,
        shares_in_window=2,
        pplns_window=2160,
        block_time=10,
        pool_type="Mini",
        pool_hashrate=21_000_000.0,
        pool_difficulty=1_000_000.0,
        network_difficulty=413245678901.0,
        network_height=3200000,
        global_syncing=False,
        monero=_sync(percent=100, down=True),
        tari=_sync(percent=42, down=False),
        monero_mode="Pruned",
        tari_mining=True,
        xvb_stale=False,
    )
    kwargs.update(overrides)
    return Metrics(**kwargs)


class TestRenderPrometheus:
    def test_gauge_lines_exact(self):
        body = render_prometheus(_metrics(), disk_percent=63.2, db_healthy=True)
        lines = body.splitlines()
        for expected in (
            "pithead_hashrate_15m_hs 12500.0",
            'pithead_p2pool_hashrate_hs{window="1h"} 1500.0',
            'pithead_p2pool_hashrate_hs{window="24h"} 1400.5',
            'pithead_xvb_routed_hashrate_hs{window="1h"} 950.0',
            'pithead_xvb_routed_hashrate_hs{window="24h"} 850.0',
            'pithead_xvb_credited_hashrate_hs{window="1h"} 900.0',
            'pithead_xvb_credited_hashrate_hs{window="24h"} 800.0',
            'pithead_stratum_hashrate_hs{window="15m"} 12000.0',
            'pithead_stratum_hashrate_hs{window="1h"} 11000.0',
            'pithead_stratum_hashrate_hs{window="24h"} 10000.0',
            "pithead_workers_online 3",
            "pithead_workers_total 4",
            "pithead_shares_in_window 2",
            "pithead_pplns_window_blocks 2160",
            "pithead_pool_hashrate_hs 21000000.0",
            "pithead_pool_difficulty 1000000.0",
            # repr(float) keeps full precision — no :g-style truncation of the difficulty.
            "pithead_network_difficulty 413245678901.0",
            "pithead_network_height 3200000",
            'pithead_node_sync_percent{chain="monero"} 100',
            'pithead_node_sync_percent{chain="tari"} 42',
            'pithead_node_down{chain="monero"} 1',
            'pithead_node_down{chain="tari"} 0',
            "pithead_syncing 0",
            "pithead_tari_mining 1",
            "pithead_xvb_stale 0",
            "pithead_xvb_enabled 1",
            "pithead_disk_used_percent 63.2",
            "pithead_db_healthy 1",
        ):
            assert expected in lines

    def test_type_header_once_per_family_before_samples(self):
        body = render_prometheus(_metrics(), disk_percent=0, db_healthy=True)
        lines = body.splitlines()
        assert lines.count("# TYPE pithead_stratum_hashrate_hs gauge") == 1
        # The TYPE line precedes the family's first sample (exposition format requirement).
        assert lines.index("# TYPE pithead_stratum_hashrate_hs gauge") < lines.index(
            'pithead_stratum_hashrate_hs{window="15m"} 12000.0'
        )

    def test_flags_render_as_zero_one(self):
        body = render_prometheus(
            _metrics(global_syncing=True, xvb_enabled=False, xvb_stale=True, tari_mining=False),
            disk_percent=0,
            db_healthy=False,
        )
        lines = body.splitlines()
        assert "pithead_syncing 1" in lines
        assert "pithead_xvb_enabled 0" in lines
        assert "pithead_xvb_stale 1" in lines
        assert "pithead_tari_mining 0" in lines
        assert "pithead_db_healthy 0" in lines

    def test_output_matches_exposition_grammar(self):
        # Every line is either a TYPE comment or `name[{labels}] value`; body ends in \n.
        body = render_prometheus(_metrics(), disk_percent=12, db_healthy=True)
        assert body.endswith("\n")
        sample = re.compile(r'^[a-z0-9_]+(\{[a-z]+="[^"]+"\})? -?\d+(\.\d+)?(e[+-]?\d+)?$')
        for line in body.splitlines():
            assert line.startswith("# TYPE pithead_") or sample.match(line), line


class TestBatchSignals:
    """The batch's own signals: luck/cadence, reject rate, cumulative counters, snapshot age."""

    def test_luck_and_expected_share_seconds(self):
        body = render_prometheus(
            _metrics(luck_pct=105.5, expected_share_sec=3600.0), disk_percent=0, db_healthy=True
        )
        lines = body.splitlines()
        assert "pithead_luck_pct 105.5" in lines
        assert "pithead_expected_share_seconds 3600.0" in lines

    def test_reject_rate_present_when_known(self):
        body = render_prometheus(_metrics(), disk_percent=0, db_healthy=True, reject_pct_1h=2.5)
        assert 'pithead_share_reject_pct{window="1h"} 2.5' in body.splitlines()

    def test_reject_rate_omitted_when_no_shares(self):
        # None = no shares submitted in the window; omit the sample rather than lying 0%.
        body = render_prometheus(_metrics(), disk_percent=0, db_healthy=True, reject_pct_1h=None)
        assert "pithead_share_reject_pct" not in body

    def test_cumulative_counters_typed_counter(self):
        body = render_prometheus(
            _metrics(),
            disk_percent=0,
            db_healthy=True,
            shares_accepted=12345,
            shares_rejected=67,
            pool_blocks_found=9,
        )
        lines = body.splitlines()
        assert "# TYPE pithead_shares_accepted_total counter" in lines
        assert "pithead_shares_accepted_total 12345" in lines
        assert "# TYPE pithead_shares_rejected_total counter" in lines
        assert "pithead_shares_rejected_total 67" in lines
        assert "# TYPE pithead_pool_blocks_found_total counter" in lines
        assert "pithead_pool_blocks_found_total 9" in lines

    def test_snapshot_age_from_timestamp(self):
        # now − snapshot timestamp: a wedged data loop shows a growing age instead of
        # scraping as healthy forever.
        body = render_prometheus(
            _metrics(), disk_percent=0, db_healthy=True, snapshot_ts=1000.0, now=1030.0
        )
        assert "pithead_snapshot_age_seconds 30.0" in body.splitlines()

    def test_snapshot_age_never_negative_and_honest_at_zero_ts(self):
        # Clock skew clamps at 0; a never-written snapshot (ts 0) reads as maximally stale.
        skew = render_prometheus(
            _metrics(), disk_percent=0, db_healthy=True, snapshot_ts=2000.0, now=1000.0
        )
        assert "pithead_snapshot_age_seconds 0.0" in skew.splitlines()
        cold = render_prometheus(
            _metrics(), disk_percent=0, db_healthy=True, snapshot_ts=0, now=5000.0
        )
        assert "pithead_snapshot_age_seconds 5000.0" in cold.splitlines()

    def test_content_type_carries_exposition_version(self):
        assert "version=0.0.4" in CONTENT_TYPE
        assert CONTENT_TYPE.startswith("text/plain")
