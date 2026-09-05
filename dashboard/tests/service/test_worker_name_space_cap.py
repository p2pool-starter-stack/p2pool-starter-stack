"""The #724 flood cap's bound on the DEVICE-CHOSEN name space (#1695).

Split from ``test_worker_change_audit.py`` rather than folded into it: that file proves the
per-worker rate bound, this one proves the bound on how many names may hold such a window at once
— a different defect class, and the one that decides whether the cap bounds a name or a device.

Tier 1, against a real in-memory ``StateManager``, through the real caller, and reusing that
file's harness so both halves of one cap are exercised the same way.
"""

from mining_dashboard.service import worker_change_audit as wca
from mining_dashboard.service.data_service import _RIG_EDIT_WINDOW_SEC
from tests.service.test_worker_change_audit import _rig_edit, _rows, _svc


class TestTheNameSpaceIsBounded:
    """#1695. The #724 cap buckets on a name the DEVICE chooses, so without a ceiling on how many
    names hold a window at once it bounds a NAME rather than a device — a rotating device draws a
    fresh budget per name, over a name space nothing bounds."""

    def test_the_shipped_ceiling(self):
        # Pinned as a LITERAL beside the symbol: a test that reads its bound only from the module
        # under test cannot fail when the bound itself regresses.
        assert wca._WORKERS_MAX == 64

    def test_a_rotating_device_is_bounded_to_the_ceiling(self, monkeypatch):
        monkeypatch.setattr(wca, "_WORKERS_MAX", 3)
        svc, sm = _svc()
        try:
            for i in range(10):
                _rig_edit(svc, f"rogue-{i}", "cid")
            # Three names were admitted and hold a window; the other seven wrote nothing at all.
            assert len(_rows(sm, "rig-edit")) == 3
            assert len(svc._rig_edit_window) == 3
        finally:
            sm.close()

    def test_the_refusal_is_one_marker_that_names_no_rotated_name(self, monkeypatch):
        # A marker naming the rotating name would BE the flood the ceiling exists to stop, so the
        # episode gets exactly one row and it names no worker the device chose.
        monkeypatch.setattr(wca, "_WORKERS_MAX", 3)
        svc, sm = _svc()
        try:
            for i in range(10):
                _rig_edit(svc, f"rogue-{i}", "cid")
            markers = _rows(sm, "rate-limited")
            assert len(markers) == 1
            assert markers[0]["actor"] == "new-workers"
            assert markers[0]["status"] == "dropped"
            assert "rogue-" not in markers[0]["keys"]
        finally:
            sm.close()

    def test_an_established_worker_keeps_its_own_budget_under_a_name_flood(self, monkeypatch):
        # What the ceiling DOES protect: a name that already holds a live window. The fixture
        # ARMS the victim on purpose -- goodrig's cid-1 detection below is what puts it in the
        # map -- so read this as a claim about an ACTIVELY AUDITED name, never about "a genuine
        # rig". Drop that first call and this test fails; the sibling below pins exactly that.
        monkeypatch.setattr(wca, "_WORKERS_MAX", 3)
        svc, sm = _svc()
        try:
            _rig_edit(svc, "goodrig", "cid-1")
            for i in range(10):
                _rig_edit(svc, f"rogue-{i}", "cid")
            _rig_edit(svc, "goodrig", "cid-2")
            good = [e for e in sm.get_audit_events() if e["actor"] == "goodrig"]
            assert len(good) == 2
            assert {e["keys"] for e in good} == {"change_id=cid-1", "change_id=cid-2"}
        finally:
            sm.close()

    def test_a_quiet_rig_holds_no_window_so_its_first_detection_is_dropped(self, monkeypatch):
        # The RESIDUAL, pinned rather than described. "Holds a live window" is not "is an
        # established rig": a rig whose config changes all go through the dashboard never enters
        # the map, so during a flood its FIRST detection is refused. The sibling above passes only
        # because its victim was armed first. SECURITY.md and docs/operations.md both state this
        # case. This pins the BEHAVIOUR; it cannot police the prose -- no test reds on a comment,
        # and the admit_worker docstring drifted back to "established rigs" with this test green.
        monkeypatch.setattr(wca, "_WORKERS_MAX", 3)
        svc, sm = _svc()
        try:
            for i in range(10):
                _rig_edit(svc, f"rogue-{i}", "cid")
            # The flood ALREADY opened the episode and wrote the marker, so a bare "== 1" after
            # quietrig polls is satisfied whether or not quietrig did anything. Take the count
            # before and after: what this proves is that quietrig's refusal lands BEHIND the
            # existing marker instead of minting a second one -- one marker per episode, not one
            # per refused name.
            before = len(_rows(sm, "rate-limited"))
            assert before == 1
            _rig_edit(svc, "quietrig", "cid-first")
            assert [e for e in sm.get_audit_events() if e["actor"] == "quietrig"] == []
            assert len(_rows(sm, "rate-limited")) == before
        finally:
            sm.close()

    def test_an_expired_window_frees_a_slot_for_a_genuinely_new_worker(self, monkeypatch):
        # Fleet turnover has to keep working: a name whose own window has run out holds no live
        # budget, so evicting it is the same reset the per-worker cap already does lazily.
        monkeypatch.setattr(wca, "_WORKERS_MAX", 3)
        svc, sm = _svc()
        try:
            for i in range(3):
                _rig_edit(svc, f"old-{i}", "cid")
            _rig_edit(svc, "refused", "cid")
            assert [e for e in sm.get_audit_events() if e["actor"] == "refused"] == []
            svc._rig_edit_window = {
                w: (s - _RIG_EDIT_WINDOW_SEC - 1, c) for w, (s, c) in svc._rig_edit_window.items()
            }
            _rig_edit(svc, "newrig", "cid")
            newrig = [e for e in sm.get_audit_events() if e["actor"] == "newrig"]
            assert len(newrig) == 1 and newrig[0]["action"] == "rig-edit"
        finally:
            sm.close()
