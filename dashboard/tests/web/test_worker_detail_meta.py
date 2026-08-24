"""Config provenance in the Inspect payload (#1345): ``rig_config_meta`` and ``config_origin``.

The question this answers is the one an operator asks when the rig disagrees with their own record
— *did this change come from here, or did something change it underneath me?* Answering it needs
one fact only this side holds: whether the rig's ``last_change_id`` matches a change THIS dashboard
spooled. The rig mints those ids and hands them back in the 202, so an id we have a ``worker_config``
row for is an id we asked for.

New file: ``test_views.py`` is at its file-budget ceiling.

Mutation-kill notes, one per guard — each of these was run and seen to red:
- Returning ``"here"`` unconditionally for ``source == "control"`` (dropping the id comparison)
  flips ``test_control_change_we_never_spooled_is_elsewhere`` — which is the whole feature.
- Folding ``restore`` into ``rig`` flips ``test_restore_is_its_own_verdict_not_a_rig_edit``; that
  fold would tell the operator a person touched the rig when RigForge merely rolled itself back.
- Making an absent block report ``"unrecorded"`` instead of ``None`` flips
  ``test_a_rig_that_cannot_answer_says_nothing``: silence and "we have no record of a change" are
  different claims, and only one of them is true of a rig too old to serve the block.
- Passing the rig's ``source`` through instead of matching the allowlist flips
  ``test_a_source_we_do_not_know_never_reaches_the_verdict``.
- Swapping the worker-scoped history scan back to ``state_mgr.worker_config_change_known`` — which
  is unscoped and fails OPEN, both correct for the #530 audit and both wrong here — flips
  ``test_another_rigs_change_id_is_never_claimed_as_this_rigs`` and
  ``test_a_history_read_that_fails_never_manufactures_trust``.
"""

import pytest

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.worker_detail import build_worker_detail

# What the rig actually serves once RigForge has recorded a change over the control channel.
_META = {
    "revision": "a1b2c3d4e5f60718",
    "changed_at": "2026-08-20T11:22:33Z",
    "source": "control",
    "last_change_id": "0f1e2d3c4b5a6978",
}


def _detail(monkeypatch, rigforge, *, spooled=None):
    """Build the payload for one rig, optionally with ``spooled`` already in our own history."""
    from mining_dashboard.web import views

    monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9"}])
    monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
    sm = StateManager(db_path=":memory:")
    try:
        if spooled:
            sm.add_worker_config_version("rig1", spooled, "applied", {"DONATION": 5}, None)
        workers = [{"name": "rig1", "status": "online", "h60": 1, "rigforge": rigforge}]
        return build_worker_detail("rig1", {"workers": workers}, sm)
    finally:
        sm.close()


class TestConfigOrigin:
    def test_control_change_with_an_id_in_our_history_is_here(self, monkeypatch):
        # The id came back to us in the rig's 202 and we wrote a row for it, so this change is
        # ours to claim — the only case where the UI may tell the operator "you did this".
        d = _detail(monkeypatch, {"config_meta": _META}, spooled=_META["last_change_id"])
        assert d["config_origin"] == "here"
        assert d["rig_config_meta"] == _META

    def test_control_change_we_never_spooled_is_elsewhere(self, monkeypatch):
        # Same source, same shape — only the id differs. Another host drove this rig, or our
        # record of it is gone. Either way it is not ours to present as ours.
        d = _detail(monkeypatch, {"config_meta": _META}, spooled="9999999999999999")
        assert d["config_origin"] == "elsewhere"

    def test_control_change_with_no_history_at_all_is_elsewhere(self, monkeypatch):
        d = _detail(monkeypatch, {"config_meta": _META})
        assert d["config_origin"] == "elsewhere"

    def test_local_change_is_a_rig_edit(self, monkeypatch):
        d = _detail(monkeypatch, {"config_meta": dict(_META, source="local")})
        assert d["config_origin"] == "rig"

    def test_restore_is_its_own_verdict_not_a_rig_edit(self, monkeypatch):
        # RigForge stamps `restore` for its OWN automatic rollback after a failed change, so
        # reading it as "someone edited the rig" would accuse a rig that healed itself.
        d = _detail(monkeypatch, {"config_meta": dict(_META, source="restore")})
        assert d["config_origin"] == "restored"

    def test_a_fresh_rig_serves_a_revision_and_nothing_else(self, monkeypatch):
        # A rig that has never had a config change: real revision, no provenance. That is
        # "unrecorded" — and it is NOT the same as a rig that cannot answer at all.
        meta = {
            "revision": "a1b2c3d4e5f60718",
            "changed_at": None,
            "source": None,
            "last_change_id": None,
        }
        d = _detail(monkeypatch, {"config_meta": meta})
        assert d["config_origin"] == "unrecorded"
        assert d["rig_config_meta"]["revision"] == "a1b2c3d4e5f60718"

    @pytest.mark.parametrize(
        "rigforge",
        [
            None,  # plain xmrig, no RigForge at all
            {},  # RigForge, but nothing under config_meta
            {"version": "1.7.0"},  # RigForge older than the block (rigforge#254)
            {"config_meta": None},  # the client layer refused an unreadable block
        ],
    )
    def test_a_rig_that_cannot_answer_says_nothing(self, monkeypatch, rigforge):
        # None, never "unrecorded": an absent block means the rig cannot tell us where its config
        # came from, which is not a claim that no change was recorded.
        d = _detail(monkeypatch, rigforge)
        assert d["rig_config_meta"] is None
        assert d["config_origin"] is None

    def test_a_source_we_do_not_know_never_reaches_the_verdict(self, monkeypatch):
        # The client layer's allowlist already dropped it, so the verdict layer sees a meta with
        # no source and falls to "unrecorded" — a compromised rig cannot write its own provenance
        # in words the operator reads as ours.
        from mining_dashboard.client.rig_config_meta import parse_config_meta

        meta = parse_config_meta(dict(_META, source="applied by the vendor"))
        assert meta["source"] is None
        d = _detail(monkeypatch, {"config_meta": meta}, spooled=_META["last_change_id"])
        assert d["config_origin"] == "unrecorded"

    def test_another_rigs_change_id_is_never_claimed_as_this_rigs(self, monkeypatch):
        # The id IS one this dashboard minted — for a different rig. Scoping is the whole
        # difference between "we sent this change to THIS rig" and "this string appears somewhere
        # in our history", and only the first is a claim worth printing. Found by security review:
        # the #530 audit's own lookup is deliberately unscoped, which is correct for #530 and
        # exactly wrong here.
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            sm.add_worker_config_version(
                "rig2", _META["last_change_id"], "applied", {"DONATION": 5}, None
            )
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert d["config_origin"] == "elsewhere"

    def test_a_history_read_that_fails_never_manufactures_trust(self, monkeypatch):
        # A DB the dashboard cannot read must not print "you did this". The #530 audit path fails
        # OPEN on a read error (a false "known" there only declines to accuse a rig); the same
        # direction here would hand a hostile rig the one verdict this feature exists to protect.
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            sm.add_worker_config_version(
                "rig1", _META["last_change_id"], "applied", {"DONATION": 5}, None
            )
            # Close the sqlite handle but LEAVE ``_conn`` set: every read then raises
            # sqlite3.ProgrammingError, which is what reaches the `except sqlite3.Error` arm. A
            # plain ``_conn = None`` would NOT do — the early `if not self._conn` return short-
            # circuits before the fail-open line, so that version of this test passed against the
            # vulnerable code too.
            sm._conn.close()
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm._conn = None  # already closed above; keep sm.close() from raising on it
            sm.close()
        assert d["config_origin"] == "elsewhere"

    def test_a_hand_edit_underneath_rigforge_is_not_detected_known_gap(self, monkeypatch):
        """CHARACTERIZATION, not an endorsement — this asserts a KNOWN-WRONG answer (#1367).

        A config file edited underneath RigForge is not a *recorded* change, so the marker keeps
        naming whatever came before it. Where that was our own control change, the line says "Last
        changed from this dashboard" over a config we did not set — the one direction the rest of
        this feature exists to avoid. RigForge computes the value that would catch it (the marker's
        stored revision) and then overwrites it with the live one before serving, so the comparison
        needs the last revision we OBSERVED, which is persistence this does not add.

        When #1367 closes, this test SHOULD red. Update it then — do not delete it.
        """
        # Same provenance as the change we really did apply; only `revision` has moved, because
        # the rig recomputes it live from a config nobody recorded a change for.
        meta = dict(_META, revision="ffffffffffffffff")
        d = _detail(monkeypatch, {"config_meta": meta}, spooled=_META["last_change_id"])
        assert d["config_origin"] == "here"  # known-wrong; see #1367

    def test_a_worker_missing_from_the_snapshot_carries_no_provenance(self, monkeypatch):
        from mining_dashboard.web import views

        monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", [])
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            d = build_worker_detail("ghost", {"workers": []}, sm)
        finally:
            sm.close()
        assert d["found"] is False
        assert d["rig_config_meta"] is None
        assert d["config_origin"] is None
