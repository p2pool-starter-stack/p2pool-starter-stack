"""Shared builders for the ``dashboard/tests/web/`` view-layer tests (#1459).

Until now ``tests/web/test_views.py``, ``test_xvb_views.py``, ``test_infra_views.py`` and
``test_series_views.py`` each carried its own copy of these builders. That was deliberate: the
#1105 cuts proved themselves by moving test bodies verbatim, and converting the builders to
fixtures would have rewritten every call site inside the same change. The cuts are finished, so
the copies are consolidated here — the exit #1459 was filed to be.

``_SYNC_DONE`` and ``_BASE`` stay module constants rather than fixtures because no test asks for
either directly; they are read only by the two ``replace``-based factories.

The five fixtures are FACTORIES: each yields the callable the modules used to define for
themselves, so every call site reads exactly as it did before and only the test signature changes.

Deliberately NOT consolidated — the name is shared, the code is not:

* ``tests/service/test_telegram_commands.py`` defines a ``_metrics`` that is byte-identical to
  this one, but its ``_BASE`` differs (``current_tier``/``target_tier`` are ``"Donor"`` there,
  not ``"Donor (1.00 kH/s+)"``, and it closes over a ``_SYNCED`` of its own). Same source, a
  different object — and it is under ``tests/service/`` anyway, out of this conftest's reach.
* ``tests/web/test_prometheus.py`` and ``tests/web/test_node_location.py`` keep their own
  ``_metrics``/``_sync``; both bodies differ. They sit under this conftest and are unaffected,
  because a fixture reaches a test only through a parameter and neither module declares one.
* ``tests/service/test_metrics.py`` keeps its own ``_state_mgr``/``_data`` pair. Its per-module
  defaults differ on purpose (``tari_sync``, the ``get_tiers``/xvb shapes); a builder shared with
  this one would need enough parameters to read worse than either copy. That note used to sit
  above ``_state_mgr`` in ``test_views.py`` and ``test_series_views.py``; it is restated here
  because this is where the pair now lives.
"""

from dataclasses import replace
from unittest.mock import MagicMock

import pytest

from mining_dashboard.service.metrics import Metrics, SyncMetric
from mining_dashboard.web.series_views import _mode_palette, build_hashrate

_SYNC_DONE = SyncMetric(
    percent=100, current=10, target=10, remaining=0, has_target=True, done=True, down=False
)

_BASE = Metrics(
    total_h15=10500.0,
    p2pool_1h=8000.0,
    p2pool_24h=8100.0,
    xvb_1h=2100.0,
    xvb_24h=2300.0,
    xvb_routed_1h=2000.0,
    xvb_routed_24h=2050.0,
    stratum_h15=10300.0,
    stratum_h1h=10400.0,
    stratum_h24h=10200.0,
    mode="P2POOL",
    xvb_enabled=True,
    current_tier="Donor (1.00 kH/s+)",
    target_tier="Donor (1.00 kH/s+)",
    target_threshold=1000.0,
    target_sustainable=True,
    low_hr_warning=False,
    xvb_fail_count=0,
    xvb_last_update=0,
    workers_online=2,
    workers_total=3,
    shares_in_window=5,
    pplns_window=2160,
    block_time=10,
    pool_type="Mini",
    pool_hashrate=120_000_000.0,
    pool_difficulty=250_000_000.0,
    network_difficulty=380_000_000_000.0,
    network_height=3210001,
    global_syncing=False,
    monero=_SYNC_DONE,
    tari=_SYNC_DONE,
    monero_mode="Unknown",
    tari_mining=True,
)


@pytest.fixture
def _metrics():
    """Factory for the ``_metrics`` the four view-test modules each used to define."""

    def _metrics(**over):
        return replace(_BASE, **over)

    return _metrics


@pytest.fixture
def _sync():
    """Factory for the ``_sync`` the four view-test modules each used to define."""

    def _sync(**over):
        return replace(_SYNC_DONE, **over)

    return _sync


@pytest.fixture
def _hashrate():
    """Factory for the ``_hashrate`` the four view-test modules each used to define."""

    def _hashrate(metrics):
        """build_hashrate with palette tokens derived as build_state does."""
        return build_hashrate(metrics, *_mode_palette(metrics.mode))

    return _hashrate


@pytest.fixture
def _state_mgr():
    """Factory for the ``_state_mgr`` the four view-test modules each used to define."""

    def _state_mgr(
        history=None,
        mode="P2POOL",
        share_stats=None,
        blocks=None,
        disk_growth=None,
        xvb_history=None,
    ):
        sm = MagicMock()
        sm.get_history.return_value = history or []
        sm.get_xvb_stats.return_value = {"current_mode": mode}
        sm.get_tiers.return_value = {}
        sm.get_xvb_reward_estimates.return_value = {"estimates": {}, "last_update": 0.0}
        sm.get_xvb_round_stats.return_value = {"stats": {}, "last_update": 0.0}
        sm.get_share_stats.return_value = share_stats or []
        sm.get_raffle_wins.return_value = []
        sm.get_xvb_standby.return_value = None  # no backup standby held (#249)
        sm.is_db_healthy.return_value = True
        # #196 Tier-1 telemetry backbone exposure.
        sm.get_blocks.return_value = blocks or []
        sm.get_disk_growth.return_value = disk_growth or []
        sm.get_xvb_history.return_value = xvb_history or []
        return sm

    return _state_mgr


@pytest.fixture
def _data():
    """Factory for the ``_data`` the four view-test modules each used to define."""

    def _data(**over):
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "total_live_h15": 0,
            "monero_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_sync": {"percent": 50, "current": 5, "target": 10},
        }
        data.update(over)
        return data

    return _data
