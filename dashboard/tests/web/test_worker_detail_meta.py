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


def _detail(monkeypatch, rigforge, *, spooled=None, status="applied"):
    """Build the payload for one rig, optionally with ``spooled`` already in our own history.

    ``status`` is the outcome our history records for that row — the thing that separates a change
    that held from one the rig rolled back out from under us.
    """
    from mining_dashboard.web import views

    monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9"}])
    monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
    sm = StateManager(db_path=":memory:")
    try:
        if spooled:
            sm.add_worker_config_version("rig1", spooled, status, {"DONATION": 5}, None)
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

    def test_a_rolled_back_change_is_never_claimed_as_the_running_config(self, monkeypatch):
        # RigForge's rollback re-apply re-stamps the change id it just reverted (control_apply
        # keeps ``source=control`` and the same id across both apply attempts), so the rig still
        # names this change while running the config that preceded it. Matching on id alone put a
        # calm "Last changed from this dashboard" directly above a red "Rolled back" history row.
        d = _detail(
            monkeypatch,
            {"config_meta": _META},
            spooled=_META["last_change_id"],
            status="rolled_back",
        )
        assert d["config_origin"] == "reverted"

    def test_a_change_that_failed_its_rollback_is_not_claimed_either(self, monkeypatch):
        # "failed" is the rollback whose own restore did not come back live — the config the rig is
        # running is least knowable here of all, so it is the last case that may read as ours.
        d = _detail(
            monkeypatch, {"config_meta": _META}, spooled=_META["last_change_id"], status="failed"
        )
        assert d["config_origin"] == "reverted"

    def test_a_change_that_held_is_still_ours_to_claim(self, monkeypatch):
        # The guard above must not swallow the ordinary case: an applied row still reads "here".
        d = _detail(
            monkeypatch, {"config_meta": _META}, spooled=_META["last_change_id"], status="applied"
        )
        assert d["config_origin"] == "here"

    def test_a_change_the_rig_only_acknowledged_is_not_claimed_as_the_running_config(
        self, monkeypatch
    ):
        # The reachable half of the allowlist inversion, driven through the real StateManager
        # rather than through config_origin alone. ``accepted`` is what we write on the rig's 202
        # and it is NOT an outcome: ``reconcile_worker_config_status`` is the only thing that ever
        # moves the row off it, and a rollback slower than the host runner's status-poll deadline
        # never gets reconciled. The rig goes on naming the change it reverted (RigForge re-stamps
        # the same id), our row still reads "accepted", and the old denylist printed the calm
        # "Last changed from this dashboard" over a config the rig had already thrown away.
        d = _detail(
            monkeypatch, {"config_meta": _META}, spooled=_META["last_change_id"], status="accepted"
        )
        assert d["config_origin"] == "unconfirmed"

    def test_a_status_this_dashboard_has_never_written_still_fails_closed(self, monkeypatch):
        # The property the inversion buys, asserted end to end: a status no code path here
        # produces today must not reach the reassuring verdict. Under the previous denylist both of
        # these read as "here" purely by not being enumerated. Two samples and not a longer list:
        # through the real StateManager a status is a TEXT column value, so an unanticipated
        # non-empty string and the empty string are the only two paths there are to travel. The
        # full vocabulary is enumerated against ``config_origin`` itself in
        # tests/client/test_rig_config_meta.py, which is the tier that owns it.
        for status in ("pending", ""):
            d = _detail(
                monkeypatch,
                {"config_meta": _META},
                spooled=_META["last_change_id"],
                status=status,
            )
            assert d["config_origin"] == "unconfirmed", status

    def test_control_change_we_never_spooled_is_elsewhere(self, monkeypatch):
        # Same source, same shape — only the id differs. Another host drove this rig, or our
        # record of it is gone. Either way it is not ours to present as ours.
        d = _detail(monkeypatch, {"config_meta": _META}, spooled="9999999999999999")
        assert d["config_origin"] == "elsewhere"

    def test_control_change_with_no_history_at_all_is_elsewhere(self, monkeypatch):
        # Also the REVERSE-direction guard for #1409, which is why it must not be folded into any
        # of the tests above it: a healthy DB holding no rows is a real answer, so this rig keeps
        # `elsewhere` and must never drift to `unread`. Make the storage layer return None for a
        # genuinely empty result and this reds — without it, `unread` could absorb the empty case
        # and the verdict would stop distinguishing anything.
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

    @pytest.mark.parametrize("filler", [48, 49, 50, 120])
    def test_a_change_pushed_out_of_the_history_window_is_not_reported_as_someone_elses(
        self, monkeypatch, filler
    ):
        """#1369, at the boundary. The provenance verdict used to read a bounded window of this
        rig's history: once enough later changes existed, our own `applied` row fell off the end
        and the id stopped being found. The verdict is an exact-id lookup now, so the row is found
        wherever it sits and every row here reads `here`.

        The filler rows are `rejected` on purpose. A rejected change returns before the rig's
        config is touched, so nothing is re-stamped and `last_change_id` stays pinned to the good
        change throughout — which is the situation being modelled. `rolled_back` fillers would be
        the opposite: RigForge's rollback re-apply re-stamps the id it just reverted, so those
        would mostly exercise the `reverted` path and this test could pass for a reason that has
        nothing to do with windowing.

        49 filler rows leaves the good row as the 50th and last readable one; 50 pushes it out;
        120 is well past any off-by-one. The two assertions under the verdict are what stop this
        passing for the wrong reason — the window has to still be BOUNDED and the good row has to
        have really fallen out of it, or `here` at 50 would only mean the window grew.
        """
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            sm.add_worker_config_version(
                "rig1", _META["last_change_id"], "applied", {"DONATION": 5}, None, ts=1000.0
            )
            for i in range(filler):
                sm.add_worker_config_version(
                    "rig1", f"later{i:04d}", "rejected", {"DONATION": 6}, None, ts=2000.0 + i
                )
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert d["config_origin"] == "here"
        # The window really is still bounded, and past 49 fillers the row the verdict just claimed
        # is NOT among the ones rendered — which is precisely the case that used to be unanswerable.
        assert len(d["history"]) == min(filler + 1, 50)
        rendered = [row["change_id"] for row in d["history"]]
        assert (_META["last_change_id"] in rendered) is (filler < 50)

    def test_a_foreign_change_on_a_long_history_rig_is_still_named_as_foreign(self, monkeypatch):
        """#1369's OTHER half, and the dangerous one — a true alarm the window used to silence.

        The issue text only describes the direction where we under-claim our own change. Past the
        window the verdict was unanswerable both ways, so this rig — genuinely driven by another
        host — got the same "we cannot tell" as one whose row had merely aged out. That withdrew a
        warning the read could in fact support. An exact-id lookup answers it: the id is not in
        this rig's rows at all, and no amount of later history makes that less true.
        """
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            for i in range(50):
                sm.add_worker_config_version(
                    "rig1", f"later{i:04d}", "rejected", {"DONATION": 6}, None, ts=2000.0 + i
                )
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert len(d["history"]) == 50  # the window IS full, so the old softening was available...
        assert d["config_origin"] == "elsewhere"  # ...and is no longer reached

    def test_a_rolled_back_change_still_reads_as_reverted_on_a_long_history(self, monkeypatch):
        # The truncation verdict must not swallow the case where we DID find the row. The rig
        # re-stamps the id it reverted, so the id is still matched even on a rig with a full
        # window — and the answer stays `reverted`, not the new "we do not know".
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            for i in range(60):
                sm.add_worker_config_version(
                    "rig1", f"older{i:04d}", "rejected", {"DONATION": 6}, None, ts=1000.0 + i
                )
            sm.add_worker_config_version(
                "rig1", _META["last_change_id"], "rolled_back", {"DONATION": 5}, None, ts=9000.0
            )
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert len(d["history"]) == 50  # the window IS full, so the softening was available...
        assert d["config_origin"] == "reverted"  # ...and correctly not taken

    def test_a_history_read_that_fails_never_manufactures_trust(self, monkeypatch):
        # A DB the dashboard cannot read must not print "you did this". The #530 audit path fails
        # OPEN on a read error (a false "known" there only declines to accuse a rig); the same
        # direction here would hand a hostile rig the one verdict this feature exists to protect.
        #
        # #1409 corrected the OTHER direction of this same test. It used to assert `elsewhere`,
        # which is not neutral — it renders as "Last changed from another dashboard". Failing away
        # from `here` was right; landing on an accusation sourced from our own broken database was
        # not. `unread` fails closed without inventing a culprit.
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
        assert d["config_origin"] == "unread"
        # The mutation target, named: this reds if the storage layer ever returns [] on error.
        assert d["config_origin"] != "elsewhere"

    def test_a_history_read_with_no_connection_at_all_is_the_same_verdict(self, monkeypatch):
        # The second failure path, and the one nobody sees: `if not self._conn` raises nothing and
        # logs nothing. The test above keeps `_conn` SET to reach the `except sqlite3.Error` arm,
        # so it never covers this one — and a fix to only the loud path leaves this one accusing.
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
            sm.close()  # drops the connection; _conn is None from here on
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert d["config_origin"] == "unread"

    def test_a_failed_read_still_hands_the_client_a_list_to_render(self, monkeypatch):
        # None is the storage layer's signal, not a payload value. `history` is iterated by the
        # client, so leaking the None past this boundary would trade a wrong verdict for a broken
        # page — the fix must not be visible anywhere except the verdict.
        from mining_dashboard.web import views

        monkeypatch.setattr(
            views.config, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "1.2.3.4"}]
        )
        monkeypatch.setattr(views.config, "DASHBOARD_CONTROL_ENABLED", True)
        sm = StateManager(db_path=":memory:")
        try:
            sm.close()
            workers = [{"name": "rig1", "status": "online", "rigforge": {"config_meta": _META}}]
            d = build_worker_detail("rig1", {"workers": workers}, sm)
        finally:
            sm.close()
        assert d["history"] == []
        assert d["hashrate_history"]["markers"] == []

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
