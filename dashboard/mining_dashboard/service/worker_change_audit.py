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

logger = logging.getLogger("WorkerChangeAudit")


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
    """
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
        event_id=f"rig-edit-ratelimited-{worker}-{int(window_start)}",
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
    Without it a rig chooses its own primary key: ``revision`` reaches ``event_id``, and ``event_id``
    is the ONE field ``_record_audit_event`` does not put through ``audit_service._clean``.

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
        event_id=f"rig-drift-{worker}-{drift['after']}",
    )
