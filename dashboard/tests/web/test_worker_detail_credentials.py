"""No pool credential leaves the Worker Inspect payload, in ANY of the fields that carry a
``worker_config`` row's ``changes`` (#1543).

The issue this closes named ``last_applied``, and that field really did serve the password. It was
not the only one: ``build_worker_detail`` publishes the same rows' ``changes`` THREE times --
``last_applied`` (the merge), ``history`` (the rendered table), and
``hashrate_history.markers[]`` (the chart tooltips, #1015). A fix at
``get_last_applied_worker_config`` would have cleaned the field the issue named and left the other
two serving the credential, with nothing going red.

So the load-bearing assertion here is deliberately NOT a per-field one:
``test_no_credential_anywhere_in_the_serialized_payload`` scans the whole rendered payload, which
is the only form of the check that does not depend on my having enumerated the fields correctly.
The per-field tests are underneath it to say WHERE, so a future regression names itself.

Every test seeds the row the way a build before the fix wrote it -- the credential in the stored
JSON, inserted around the store's own writer, since that writer now strips.
``test_the_seed_really_carries_the_credential`` is the control that the seed armed.
"""

import json
import time

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.worker_detail import build_worker_detail

_PASSWORD = "s3cret-pool-password"
_FINGERPRINT = "aa:bb:cc:dd"


def _seed_and_build(monkeypatch, *, ts=None):
    """A rig whose one applied change carried a pool password, as an older build stored it."""
    from mining_dashboard.web import views

    monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "r1"}])
    monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
    sm = StateManager(db_path=":memory:")
    changes = {
        "pools": [
            {
                "url": "pool.example:3333",
                "user": "wallet.rig1",
                "pass": _PASSWORD,
                "tls-fingerprint": _FINGERPRINT,
            }
        ]
    }
    sm._conn.execute(
        "INSERT INTO worker_config (worker, change_id, ts, status, changes, reason, type) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        ("rig1", "chg-1", ts or time.time(), "applied", json.dumps(changes), None, "apply"),
    )
    sm._conn.commit()
    try:
        detail = build_worker_detail(
            "rig1", {"workers": [{"name": "rig1", "status": "online"}]}, sm
        )
        raw = sm._conn.execute("SELECT changes FROM worker_config").fetchone()[0]
        return detail, raw
    finally:
        sm.close()


class TestNoCredentialInTheInspectPayload:
    def test_the_seed_really_carries_the_credential(self, monkeypatch):
        # THE CONTROL. Every other assertion in this module is an absence; this is what separates
        # "the strip works" from "the fixture never held a password in the first place".
        _detail, raw = _seed_and_build(monkeypatch)
        assert _PASSWORD in raw
        assert _FINGERPRINT in raw

    def test_no_credential_anywhere_in_the_serialized_payload(self, monkeypatch):
        # The assertion that does not trust my own list of fields. If a future change publishes a
        # row's `changes` through a FOURTH field, this fails and the per-field tests below do not.
        detail, _raw = _seed_and_build(monkeypatch)
        blob = json.dumps(detail, default=str)
        assert _PASSWORD not in blob
        assert _FINGERPRINT not in blob
        # Narrowness: an empty payload would pass the two lines above.
        assert "pool.example:3333" in blob

    def test_last_applied_is_clean(self, monkeypatch):
        detail, _raw = _seed_and_build(monkeypatch)
        pool = detail["last_applied"]["pools"][0]
        assert "pass" not in pool
        assert "tls-fingerprint" not in pool
        assert pool["user"] == "wallet.rig1"

    def test_the_history_rows_are_clean(self, monkeypatch):
        # The field the issue did not name. `history` is the rendered change table.
        detail, _raw = _seed_and_build(monkeypatch)
        pool = detail["history"][0]["changes"]["pools"][0]
        assert "pass" not in pool
        assert "tls-fingerprint" not in pool

    def test_the_chart_markers_are_clean(self, monkeypatch):
        # The other field the issue did not name. markerLabel only renders the KEY names, so
        # nothing on screen ever showed this -- but the values still crossed the wire.
        detail, _raw = _seed_and_build(monkeypatch)
        markers = detail["hashrate_history"]["markers"]
        assert markers, "the seeded row must reach the markers list, or this proves nothing"
        pool = markers[0]["changes"]["pools"][0]
        assert "pass" not in pool
        assert "tls-fingerprint" not in pool
