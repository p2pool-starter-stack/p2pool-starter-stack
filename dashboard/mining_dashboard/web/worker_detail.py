"""The Worker Inspect payload (#185) — one rig's telemetry, its writable config, and its change
history — assembled for ``/api/worker/{name}``.

Split out of ``views.py`` when #1345 added the config-provenance keys below. The direction of the
import is deliberate and one-way: this module reads ``views``' formatting helpers, and ``views``
never reads this one, so the split cannot become a cycle. Everything here still obeys the view
layer's rule from Issue #61 — format at the edge, emit tokens and display strings, never HTML.

**Provenance (#1345).** ``rig_config_meta`` is the rig's own account of when its writable config
last changed and what changed it, already validated against RigForge's vocabulary in
``client/rig_config_meta.py``. ``config_origin`` is the verdict the operator actually wants: did
this change come from here, or did something change it underneath me? Answering that needs one
fact only this side holds — whether the rig's ``last_change_id`` matches a change *this* dashboard
spooled *for this rig*. The rig mints those ids in its control server and hands them back in the
202, so an id in this rig's own history is an id we asked for.

The comparison is evidence, not proof, and one case escapes it entirely. RigForge serves ``revision``
recomputed live but takes the other three from a marker file it writes only when a change is
*recorded* (``_stamp_config_meta``), and the marker's own stored revision is overwritten by the live
one before it goes on the wire. So a config hand-edited underneath RigForge moves the revision while
the provenance stays stale, and this reports the change before it — reading as "here" over a config
we did not set. Catching that needs the last revision we OBSERVED per rig, which is persistence this
does not add; see the follow-up issue.

A rig that is lying can also replay an id we really did send it. Within what a rig reports honestly,
the dashboard's own half errs one way only: every input it cannot vouch for lands on "not ours".

This is not a new capability from nothing: #530 already notices a rig-applied change, but only
while a poll is watching a terminal report go by, and only ever as a change_id. The keys here make
the same answer persistent and specific — it survives a restart, and it survives nobody watching.
"""

from mining_dashboard.client.rig_config_meta import config_origin
from mining_dashboard.config import config
from mining_dashboard.helper.utils import format_hashrate, format_time_abs
from mining_dashboard.service.control_service import WORKER_WRITABLE_KEYS
from mining_dashboard.web.views import (
    _filter_events,
    _gauge_series,
    _rigforge_display,
    rigforge_update_for,
)

# How far back the provenance match may look. Named rather than left to the storage layer's default
# because the verdict depends on it TWICE: once to find the id, and once to know whether not finding
# it meant anything (#1369). A bare call would leave the second use comparing against a number
# written down somewhere else, which is how the two drift apart.
_HISTORY_LIMIT = 50


def build_worker_hashrate_history(state_mgr, worker, range_arg, window=None):
    """Per-worker hashrate-over-time chart (#1013): ``worker_history.h15`` for one rig, same
    range/window/downsampling idiom as the telemetry backbone's other gauge series (``_gauge_series``
    — reused as-is, not reimplemented). Markers (#1015) are the SAME range/window slice of this rig's
    change history — config applies and rig upgrades (#1014) — so a step in the line has a visible
    cause; kept as raw tokens (status/type/changes/reason), not display strings, so the client builds
    the tooltip label the same way it already builds the history table's Outcome column."""
    hashrate = [
        {"x": p["x"], "y": p["h15"]}
        for p in _gauge_series(
            state_mgr.get_worker_history(name=worker), range_arg, window, ("h15",)
        )
    ]
    markers = [
        {
            "x": int(row["ts"] * 1000),
            "status": row.get("status"),
            "type": row.get("type", "apply"),
            "changes": row.get("changes") or {},
            "reason": row.get("reason"),
        }
        for row in _filter_events(
            state_mgr.get_worker_config_history(worker, limit=200) or [], range_arg, window
        )
    ]
    return {"hashrate": hashrate, "markers": markers}


def build_worker_detail(name, data, state_mgr, range_arg="all", window=None):
    """Per-worker Inspect payload (#185): the rig's current enriched telemetry, the writable config (the editor
    prefills from the rig's own current values (#1235), falling back to Pithead's last-applied record when the
    rig has none), and the change history (each row's ``changes`` is a diff by construction, since we only ever
    record deltas we authored). ``hashrate_by_config`` (#492) is that same version timeline with each version's
    measured hashrate (worker_history) aggregated over its active window, so an operator can compare config
    versions empirically. ``hashrate_history`` (#1013) is the same rig's hashrate as a chartable time series,
    honoring the same ``range_arg``/``window`` ``/api/state`` already uses.
    ``editable`` is whether the worker has an operator-set ``host`` in ``dashboard.workers[]`` — the
    precondition for the host-side write path. The rig's token is masked out of this container (#440),
    so the container cannot verify it; the host runner re-checks it and fails closed if it is missing.
    """
    workers = data.get("workers", []) if data else []
    worker = next((w for w in workers if w.get("name") == name), None)
    descriptor = next((e for e in config.DASHBOARD_WORKERS if e["name"] == name), None)
    history = state_mgr.get_worker_config_history(name, limit=_HISTORY_LIMIT)
    # None means the read FAILED; [] means the rig genuinely has no recorded changes (#1409). The
    # two are the same object downstream, so the distinction has to be captured HERE or it is gone.
    history_unread = history is None
    history = history or []
    for row in history:
        ts = row.get("ts")
        row["applied_at"] = format_time_abs(ts) if ts else ""
    hashrate_by_config = state_mgr.get_worker_hashrate_by_config(name)
    for row in hashrate_by_config:
        ts = row.get("ts")
        row["applied_at"] = format_time_abs(ts) if ts else ""
        for key in ("avg_h15", "min_h15", "max_h15"):
            row[key] = format_hashrate(row[key]) if row[key] is not None else None
    # Already filtered to RigForge's own vocabulary by the client layer, so this is a read, not a
    # second parse — re-validating here would be a second place to get the allowlist wrong.
    rig_meta = (worker.get("rigforge") or {}).get("config_meta") if worker else None
    # Looked up by id against THIS rig's own ``worker_config`` rows, unbounded — NOT searched for
    # among the ``history`` rows already in hand (#1369). Those are the 50 the page renders, and a
    # rig with more changes than that pushed its own row off the end: past the window the verdict
    # stopped working in BOTH directions at once, unable to claim a change that was ours and
    # unable to name one that was not. The window is a rendering limit; it was never a fact about
    # what this dashboard spooled, and letting it bound the verdict made it one. The extra query
    # is an index seek on `worker` — `EXPLAIN QUERY PLAN` reports `SEARCH worker_config USING
    # INDEX idx_worker_config (worker=?)` — walking that rig's own rows in the order the index
    # already supplies, so it costs no sort. On a MISS it walks all of them, and the miss is the
    # foreign-change case this line exists to catch: bounded by one rig's history rather than by
    # nothing. Reusing a list already in hand was the only thing the old shape actually bought.
    #
    # Deliberately NOT ``worker_config_change_known``, which the #530 rig-edit audit uses. That
    # lookup is unscoped — it asks whether ANY rig's change carried this id — and it fails OPEN
    # (True) on a DB error, both correct for #530, where a false "known" merely declines to accuse
    # a rig. Here the same two properties invert into the one answer this feature must never give
    # wrongly: a change id spooled for a DIFFERENT rig, or a transient DB error, would print "Last
    # changed from this dashboard" over a change this dashboard never made.
    # ``get_worker_config_change`` is worker-scoped by construction and fails closed, returning a
    # ``None`` the verdict answers separately (#1409) rather than a ``{}`` it cannot tell from a miss.
    #
    # The matched ROW, not merely whether one exists: RigForge's rollback re-apply re-stamps the id
    # it just reverted, so a rolled-back change still matches by id. The row's status is the only
    # thing separating a change that held from one the rig threw away (``REVERTED_STATUSES``).
    last_change_id = (rig_meta or {}).get("last_change_id")
    matched = state_mgr.get_worker_config_change(name, last_change_id)
    return {
        "name": name,
        "found": worker is not None,
        # Editable needs an operator-pinned host in config.json, never a miner-advertised one (#122).
        "editable": bool(descriptor and descriptor.get("host")),
        "control_enabled": config.DASHBOARD_CONTROL_ENABLED,
        "ip": worker.get("ip") if worker else None,  # OBSERVED only — the adopt-form prefill (#893)
        "status": worker.get("status") if worker else None,
        "hashrate": format_hashrate(worker.get("h60", 0)) if worker else None,
        "rigforge": _rigforge_display(worker.get("rigforge")) if worker else None,
        # {available, latest, url} | None — this rig runs an older RigForge (#596).
        "rigforge_update": rigforge_update_for(worker, (data or {}).get("rigforge_release")),
        "writable_keys": sorted(WORKER_WRITABLE_KEYS),
        # Rig's own current writable-key values (#1235); None means "could not read", not empty.
        "rig_config": (worker.get("rigforge") or {}).get("config") if worker else None,
        # The rig's own record of its last config change, and our verdict on it (#1345). Both None
        # for a rig that cannot answer — the client renders that as silence, not as "unknown".
        "rig_config_meta": rig_meta,
        # ``matched``: a row = found, ``{}`` = no such row, ``None`` = the lookup itself failed.
        # Either failed read still fails closed — the rendered list going unread does not make the
        # verdict trustworthy, and both come off the same handle, so they fail together in practice.
        "config_origin": config_origin(
            rig_meta,
            bool(matched),
            (matched or {}).get("status"),
            history_unread=matched is None or history_unread,
        ),
        "last_applied": state_mgr.get_last_applied_worker_config(name),
        "history": history,
        "hashrate_by_config": hashrate_by_config,
        "hashrate_history": build_worker_hashrate_history(state_mgr, name, range_arg, window),
    }
