"""Click-to-adopt (#893): ``build_worker_detail``'s ``ip`` field is the adopt-form's PREFILL
source. It must be the miner-observed address (never the operator-confirmed ``host`` already in
config.json, once adopted) — that distinction IS the trust model: a prefill can be wrong or
adversarial, an ``editable`` host cannot. New file (test_views.py is at its file-budget ceiling).

Mutation-kill notes: swapping ``worker.get("ip")`` for the descriptor's ``host`` (or dropping the
``if worker else None`` guard so a not-found worker crashes or fabricates a value) would flip
``test_ip_is_the_observed_value_even_when_a_different_host_is_configured`` /
``test_ip_is_none_when_worker_not_in_snapshot``.
"""

import pytest

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.worker_detail import build_worker_detail


def _detail(monkeypatch, name, workers=None, descriptors=None):
    from mining_dashboard.web import views

    monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", descriptors or [])
    monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
    sm = StateManager(db_path=":memory:")
    try:
        return build_worker_detail(name, {"workers": workers or []}, sm)
    finally:
        sm.close()


class TestWorkerDetailIp:
    def test_ip_present_for_an_unadopted_worker(self, monkeypatch):
        # The whole point of the field: a rig with NO descriptor yet still carries the observed
        # address, so the adopt form has something to prefill.
        d = _detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "ip": "10.0.0.9"}],
            descriptors=[],
        )
        assert d["editable"] is False
        assert d["ip"] == "10.0.0.9"

    def test_ip_is_the_observed_value_even_when_a_different_host_is_configured(self, monkeypatch):
        # Once adopted, the operator-confirmed host lives in the descriptor (and drives `editable`
        # + the actual dial target) — `ip` stays the raw proxy-observed value regardless, so it
        # never masquerades as the trusted address.
        d = _detail(
            monkeypatch,
            "rig1",
            workers=[{"name": "rig1", "status": "online", "ip": "10.0.0.9"}],
            descriptors=[{"name": "rig1", "host": "rig1.internal", "control_port": 8082}],
        )
        assert d["editable"] is True
        assert d["ip"] == "10.0.0.9"
        assert d["ip"] != "rig1.internal"

    def test_ip_is_none_when_worker_not_in_snapshot(self, monkeypatch):
        d = _detail(monkeypatch, "ghost", workers=[])
        assert d["found"] is False
        assert d["ip"] is None


# --- Rig-sourced editor prefill (#1235) ---------------------------------------------------


@pytest.mark.parametrize(
    "rigforge,expected",
    [
        ({"config": {"DONATION": 9, "max_temp_c": 85}}, {"DONATION": 9, "max_temp_c": 85}),
        (None, None),  # plain-xmrig rig
        ({}, None),
        ({"version": "1.9.0"}, None),  # RigForge too old to publish the block
    ],
)
def test_rig_config_is_surfaced_for_the_editor_prefill(monkeypatch, rigforge, expected):
    # #1235: the rig's own writable values ride the enriched feed, so the editor can show what
    # the rig is RUNNING rather than what we last pushed at it. None means the editor must fall
    # back to the last-applied record, never render empty boxes as if they were rig values.
    d = _detail(
        monkeypatch,
        "rig1",
        workers=[{"name": "rig1", "status": "online", "h60": 1, "rigforge": rigforge}],
        descriptors=[{"name": "rig1", "host": "10.0.0.9"}],
    )
    assert d["rig_config"] == expected


def test_rig_config_is_none_for_a_worker_that_is_not_in_the_snapshot(monkeypatch):
    d = _detail(monkeypatch, "ghost", workers=[], descriptors=[])
    assert d["rig_config"] is None
