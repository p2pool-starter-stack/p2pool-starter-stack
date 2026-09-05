"""Out-of-band worker-config change detection that writes to the durable audit trail (#530, #1551).

Both detections here read the SAME unauthenticated enriched worker feed, so both are bounded by the
SAME per-worker flood cap (#724) — see :func:`record_cap_marker`. They live outside ``data_service``
because that cap and its marker now have two callers rather than one, and a single implementation
is what stops the two from drifting apart. They take the ``DataService`` instance rather than
becoming methods on it, so every row still goes through ``_record_audit_event`` and the
``audit_service._clean`` sanitizer it wraps, which is the only path allowed to write this table.

``cap`` is passed in rather than imported: ``data_service`` imports this module, so importing its
``_RIG_EDIT_CAP_PER_HOUR`` back would be a genuine circular import — the constant is defined below
that import and would not exist yet.
"""

import asyncio
import logging
import time

from mining_dashboard.client.rig_config_meta import parse_config_meta
from mining_dashboard.service import audit_service

logger = logging.getLogger("WorkerChangeAudit")

# Ceiling on how many worker names hold a live #724 window at once (#1695). That cap buckets on the
# name the device presents on this same unauthenticated feed, so without a bound here a device that
# varies its name draws a fresh budget per name over an unbounded name space -- bounding a NAME
# rather than a device, and growing ``_rig_edit_window`` without limit in a process that never
# exits. It lives beside the cap's marker for the reason the module docstring gives: one
# implementation, so the two detections cannot drift apart.
#
# NOT one overall row ceiling, and not the retention trim #724 offered beside the per-worker cap.
# #724 preferred the worker-keyed cap because "it also stops one rogue rig from crowding genuine
# audit history out of any bounded table", and the mechanism is worth naming: under a trim-oldest
# bound a flood EVICTS the oldest genuine rows rather than SPENDING a budget. Same harm, different
# verb, which is why an admission ceiling and a retention trim are not interchangeable. #724's own
# root cause -- ``audit_events`` is never pruned -- is untouched by this and still holds (the
# ISSUE is closed; the condition is not).
#
# WHAT THIS PROTECTS IS NARROWER THAN "AN ESTABLISHED RIG", and the gap is the residual worth
# knowing. Membership in ``_rig_edit_window`` means "this NAME produced an out-of-band detection
# inside the current window" -- the sole insert is ``data_service._rig_edit_within_cap``, reached
# only from the two detection paths -- and NOT "this device is known to us". A rig whose config
# changes all go through the dashboard holds no entry at all, so while a flood holds every slot
# that rig's FIRST detection is refused and dropped behind the episode marker: the best-behaved
# rig is the least protected, and a rogue does spend slots on its behalf. That is the price of
# bounding a device-chosen name space with no authenticated identity to key admission on, and it
# is DISCLOSED rather than fixed, the way #1696 disclosed its unstorable-name case. What a flood
# cannot do is displace a name that is already holding a window. Nor is it keyed on something the
# device does not choose: the feed carries exactly ``name`` and ``ip`` per worker
# (``data_helpers._parse_proxy_list_worker`` and its legacy sibling), a LAN device picks its own
# address as freely as its name, and the legacy shape defaults a missing one to ``0.0.0.0`` -- so
# nothing here qualifies.
#
# The value is a judgement, not a measurement, and the arithmetic it turns on is: what a rotating
# device can still make permanent is this ceiling times ``_RIG_EDIT_CAP_PER_HOUR``, so 64 x 12 =
# 768 audit rows an hour, against a feed that was bounded before only by how many names one body
# could carry times the poll rate. 64 stays several times clear of any pithead fleet (an
# xmrig-proxy serving a home or small setup, single-digit to low-tens rigs) while a rotation flood
# reaches it inside a single poll. Lower it and real fleets start losing first sightings; raise it
# and that hourly product rises with it.
_WORKERS_MAX = 64


def admit_worker(svc, worker, now, window_sec):
    """Whether ``worker`` may hold a #724 flood-cap window, bounding the name space (#1695).

    Returns ``(admitted, first_over)``. A name already in ``svc._rig_edit_window`` is always
    admitted -- this only ever refuses a name that holds no live budget yet. What that protects is
    NARROWER than "an established rig"; the ceiling comment above states the residual in full. A rig
    whose config changes all go through the dashboard holds no window at all, so during a flood its
    FIRST detection is refused too. Before refusing, every name whose own window has EXPIRED
    is evicted: those hold no live budget either, so dropping them is the same reset
    ``_rig_edit_within_cap`` already does lazily per worker, and it is what lets genuine fleet
    turnover keep admitting names.

    A refused name is deliberately NEVER inserted into that map, and ``record_cap_marker`` reads
    exactly that: absence when a marker is written means this refusal and nothing else can produce
    it. ``first_over`` is True only on the call that opens a saturation episode, so the episode
    gets one marker rather than one per rotated name.
    """
    if worker in svc._rig_edit_window:
        return True, False
    for name, (start, _) in list(svc._rig_edit_window.items()):
        if now - start >= window_sec:
            del svc._rig_edit_window[name]
    if len(svc._rig_edit_window) >= _WORKERS_MAX:
        first_over = svc._rig_edit_names_over is None
        if first_over:
            svc._rig_edit_names_over = now
        return False, first_over
    svc._rig_edit_names_over = None
    return True, False


async def record_cap_marker(svc, worker, cap, tipped_by):
    """Record the single #724 rate-limited marker for ``worker``'s current window.

    Called only on the poll that tips the cap (``first_over``), so a flood is surfaced once per
    window rather than every poll. The row's id is keyed to this worker's window start, which makes
    the write idempotent even if a restart re-trips ``first_over``, while a later window gets its
    own distinct marker.

    ``tipped_by`` names WHICH detection exhausted the budget. The cap is shared, so once it trips
    both detections are suppressed for the rest of the window — and "capped" alone is not
    actionable, where knowing it was drift says look at what is rewriting config underneath
    RigForge, and knowing it was edits says look at who is driving changes. The marker keeps
    ``source="rig-edit"``: it describes the one shared per-worker budget on the one untrusted feed,
    not a second thing for the Security panel to filter on.

    A worker ABSENT from ``svc._rig_edit_window`` is the #1695 names-ceiling refusal rather than
    this worker's own exhausted budget -- see :func:`admit_worker` for why absence means exactly
    that. It gets ONE marker for the saturation episode instead of one per name, because a marker
    naming the rotating name would BE the flood the ceiling exists to stop: it names no worker,
    states the ceiling itself, and keys its id on the episode start. What actually holds it to one
    row is the ``first_over`` gate at BOTH call sites -- ``admit_worker`` returns it True only on
    the refusal that OPENS the episode, so no later refusal in that episode reaches this function.
    The episode-keyed id and the sink's ``INSERT OR IGNORE`` behind it are redundant defence rather
    than the mechanism; they bite only if two episodes open inside one wall-clock second, which the
    truncated stamp cannot tell apart. Episodes RECUR and each gets its own row: the stamp clears the moment
    a new name is admitted, and ``__init__`` clears it too, so after a process restart a later
    re-trip is a new episode and a new row -- the same reset the #724 window itself takes. Size
    marker volume off the episode count, never off the word "one". ``new-workers`` is a
    display label and not a reserved name -- a device may present it, and the action and keys are
    what tell the two rows apart.
    """
    if worker not in svc._rig_edit_window:
        logger.warning(
            "Out-of-band audit windows are held by %d distinct worker names (#1695), tipped by %s "
            "-- a device on the unauthenticated feed may be rotating the name it presents. "
            "rig-edit AND revision-drift rows for names not already seen are dropped until a "
            "window frees.",
            _WORKERS_MAX,
            tipped_by,
        )
        await svc._record_audit_event(
            "rig-edit",
            "new-workers",
            "rate-limited",
            "dropped",
            f"out-of-band audit windows held by {_WORKERS_MAX} worker names; rows for further NEW "
            f"names dropped (tipped by {tipped_by})",
            event_id=audit_service.build_event_id(
                "rig-edit-namescap", int(svc._rig_edit_names_over or 0)
            ),
        )
        return
    window_start = svc._rig_edit_window[worker][0]
    logger.warning(
        "Worker %s exceeded %d out-of-band audit rows this hour (#724), tipped by %s — a rig on "
        "the unauthenticated feed; further rig-edit AND revision-drift rows are dropped for this "
        "worker until the window resets.",
        worker,
        cap,
        tipped_by,
    )
    await svc._record_audit_event(
        "rig-edit",
        worker,
        "rate-limited",
        "dropped",
        f"rig-edit + revision-drift rows capped at {cap}/hour (tipped by {tipped_by})",
        event_id=audit_service.build_event_id("rig-edit-ratelimited", worker, int(window_start)),
    )


async def note_revision_drift(svc, worker_row, extra_stats, cap):
    """Record the revision ``worker_row`` serves now, and audit a config change nothing else sees.

    This is the #1551 wiring, for the door #1542 leaves open. ``last_applied`` is a merge of the
    diffs THIS dashboard authored, so a hand-edit to a key we never set has no left-hand side to
    compare against: it moves the rig's own ``revision``, stamps no ``last_change_id``, and every
    existing check keeps reading "changed from this dashboard". The rig's earlier revision against
    the one it serves now is the only signal that case produces.

    Runs BEFORE the caller's terminal-control-status guard, deliberately — a rig can serve a real
    ``revision`` with no terminal outcome beside it (a fresh RigForge rig that has never had a
    change), and that is exactly the case this exists to catch. It takes the whole enriched body and
    does its own VALIDATION so the call site stays one line, exactly as its sibling
    ``parse_worker_control_status`` does on that same line: ``worker_results`` here is the RAW rig
    body, straight off ``get_stats``, and nothing has parsed it yet — the merge that calls
    ``parse_rigforge`` runs later in the poll and on a different object. So the block goes through
    ``parse_config_meta`` before the store sees it, which is the store's own stated precondition.
    Without it a rig chooses its own primary key: ``revision`` reaches ``event_id``. The sink bounds
    and whitelists that field (#1561) and escapes it into its own slot before the join (#1566), so
    neither an oversized value nor a collision survives it — but both of those are salvage. What
    validating here buys is that a ``rig-drift`` row's id is a SHORT OPAQUE TOKEN rather than
    whatever the rig sent, which is the difference between a readable key and a digest.

    Bounded by the shared #724 cap, because ``revision`` rides the same unauthenticated feed as
    ``change_id`` and has the same property: the store's dedup collapses a revision that has NOT
    changed and does nothing about one that changes every poll, so a rogue rig emitting a fresh
    revision each poll would otherwise write one permanent ``audit_events`` row per poll. The
    deterministic id below is worth having and is NOT that bound — it collapses a rig ALTERNATING
    between two revisions and does nothing about one incrementing.

    A quiet no-op whenever there is nothing to say: no body, no ``config_meta``, an unnamed worker,
    or a store that returned None — a first sighting, an unmoved revision, a move something already
    recorded, or a read/write error, since ``note_worker_revision`` fails closed and accuses nobody.
    """
    worker = (worker_row or {}).get("name") or ""
    meta = parse_config_meta(((extra_stats or {}).get("rigforge") or {}).get("config_meta"))
    if not worker or not meta:
        return
    drift = await asyncio.to_thread(svc.state_manager.note_worker_revision, worker, meta)
    if not drift:
        return
    allowed, first_over = svc._rig_edit_within_cap(worker, time.time())
    if not allowed:
        if first_over:
            await record_cap_marker(svc, worker, cap, "revision-drift")
        return
    await svc._record_audit_event(
        "rig-drift",
        worker,
        "rig-drift",
        "detected",
        f"revision {drift['before']} -> {drift['after']} with no new change_id",
        event_id=audit_service.build_event_id("rig-drift", worker, drift["after"]),
    )
