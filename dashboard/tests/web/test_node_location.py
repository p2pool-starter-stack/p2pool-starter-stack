"""Local vs remote for the Monero and Tari nodes (#1040).

The two nodes an operator can run either on this machine or somebody else's. A remote node's
health is not theirs to fix, so the dashboard has to say which it is looking at — the diagram and
both node cards read it from ``/api/state``'s ``sync`` block, the only per-node block that covers
BOTH chains (``state.monero`` has no Tari twin).

New file: test_views.py is at its file-budget ceiling.
"""

from types import SimpleNamespace
from unittest.mock import MagicMock

from mining_dashboard.service import metrics as metrics_mod
from mining_dashboard.service.metrics import SyncMetric
from mining_dashboard.web.views import build_sync

_SYNCED = SyncMetric(
    percent=100, current=10, target=10, remaining=0, has_target=True, done=True, down=False
)


def _sync(*, monero_local, tari_local):
    metrics = SimpleNamespace(
        monero=_SYNCED,
        tari=_SYNCED,
        monero_mode="Pruned",
        monero_local=monero_local,
        tari_local=tari_local,
    )
    return build_sync(metrics, "85.0 GB")


def test_each_node_carries_its_own_location():
    # Asserted as a matrix rather than one happy case: the failure that matters is not "no flag",
    # it is one node reported using the OTHER node's answer, which sends an operator to the wrong
    # machine. Only the mixed rows can catch that.
    for monero_local, tari_local in ((True, True), (True, False), (False, True), (False, False)):
        out = _sync(monero_local=monero_local, tari_local=tari_local)
        assert out["monero"]["local"] is monero_local, (monero_local, tari_local)
        assert out["tari"]["local"] is tari_local, (monero_local, tari_local)


def test_the_location_rides_alongside_the_existing_sync_fields():
    # It is added to the per-node block, not swapped in for it: the gauge still needs its state.
    out = _sync(monero_local=False, tari_local=True)
    assert out["monero"]["mode"] == "Pruned"
    assert out["monero"]["db_size"] == "85.0 GB"
    for node in ("monero", "tari"):
        assert out[node]["state"] == "done"
        assert out[node]["percent"] == 100


def test_build_metrics_reads_each_node_from_its_own_config_helper(monkeypatch):
    # The wiring at the source. A swap here — monero_local fed by the Tari helper or vice versa —
    # produces a payload that is well-formed and confidently wrong, and every check downstream of
    # it would still pass. So the two helpers are given DIFFERENT answers on purpose.
    monkeypatch.setattr(metrics_mod, "monero_is_local", lambda: False)
    monkeypatch.setattr(metrics_mod, "tari_is_local", lambda: True)
    mgr = MagicMock()
    mgr.get_history.return_value = []
    mgr.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    m = metrics_mod.build_metrics({"shares": [], "workers": []}, mgr)
    assert m.monero_local is False
    assert m.tari_local is True
