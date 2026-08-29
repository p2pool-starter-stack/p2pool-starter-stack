import asyncio
import logging
import math
import mimetypes
import os
import re
import uuid

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service import audit_service, control_service, worker_adopt, worker_refresh
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.update_checker import parse_semver
from mining_dashboard.web.prometheus import CONTENT_TYPE as PROMETHEUS_CONTENT_TYPE
from mining_dashboard.web.prometheus import render_prometheus
from mining_dashboard.web.views import (
    build_state,
    canonical_window,
    get_shell_html,
    parse_window,
)
from mining_dashboard.web.worker_detail import build_worker_detail

logger = logging.getLogger("WebServer")

# Slim/minimal containers (the production image is python:3.11-slim) often lack
# /etc/mime.types, so ES modules (.mjs) — and on some setups .js — would be served as
# application/octet-stream, which browsers refuse to execute as modules. Register the JS
# types explicitly so the /static frontend always loads, regardless of the host's mime db.
mimetypes.add_type("text/javascript", ".mjs")
mimetypes.add_type("text/javascript", ".js")


async def handle_index(request):
    """Serve the static HTML shell. It carries no data — the client fetches ``/api/state``
    and renders the dashboard. Pure transport."""
    return web.Response(text=get_shell_html(), content_type="text/html")


async def handle_state(request):
    """The dashboard's data API. Pull shared state, delegate to the view layer, and return
    the assembled state object as JSON (or a sanitized 500 on failure)."""
    app = request.app
    data = app["latest_data"]
    state_mgr = app["state_manager"]
    range_arg = request.query.get("range", "all")
    # Optional manual-zoom window (Issue #47); malformed from/to falls back to the preset range.
    window = parse_window(request.query.get("from"), request.query.get("to"))
    # Hashrate-averaging window for the chart (#168); unknown/missing falls back to the default.
    avg_window = canonical_window(request.query.get("avg"))

    try:
        return web.json_response(build_state(data, state_mgr, range_arg, window, avg_window))
    except Exception:
        # Log the full error server-side; never leak exception details to the browser.
        logger.exception("Error building dashboard state")
        return web.json_response({"error": "Failed to build dashboard state."}, status=500)


async def handle_xvb_standby(request):
    """The XvB controller state a BACKUP stack pulls to warm its donation split (#249).

    Read-only, behind the same Caddy auth + loopback bind as ``/api/state`` — no new trust boundary
    or egress class. The payload is the minimal warm state: the controller's commanded donation
    fraction, XvB's credited 1h/24h averages (already public per-wallet), the target tier, and the
    current mode. Always registered; on a stack with no backup nothing ever pulls it."""
    state_mgr = request.app["state_manager"]
    try:
        xvb = state_mgr.get_xvb_stats()
        return web.json_response(
            {
                "commanded_fraction": xvb.get("commanded_fraction", 0.0),
                "avg_1h": xvb.get("avg_1h", 0.0),
                "avg_24h": xvb.get("avg_24h", 0.0),
                "mode": xvb.get("current_mode", ""),
                "donation_level": config.XVB_DONATION_LEVEL,
                "ts": xvb.get("last_update", 0.0),
            }
        )
    except Exception:
        logger.exception("Error building XvB standby state")
        return web.json_response({"error": "Failed to build XvB standby state."}, status=500)


async def handle_metrics(request):
    """Prometheus text exposition (#379), rendered from the same ``build_metrics`` snapshot
    ``/api/state`` uses — live gauges only, no history. Same trust boundary as the state API:
    bound to loopback behind Caddy, covered by the optional dashboard basic_auth."""
    app = request.app
    data = app["latest_data"]
    state_mgr = app["state_manager"]
    try:
        data = data or {}
        metrics = build_metrics(data, state_mgr)
        # Raw disk percent from the system snapshot; same or-{} chain as the views badge lookup.
        disk_percent = (data.get("system", {}).get("disk", {}) or {}).get("percent", 0) or 0
        # The batch's own signals (#379 follow-up): trailing reject rate from the persisted
        # delta series, the proxy's cumulative share counters, p2pool's blocks-found counter,
        # and the snapshot timestamp (age = staleness of everything above).
        summary = data.get("proxy_summary", {}) or {}
        pool_local = (data.get("pool", {}) or {}).get("pool", {}) or {}
        body = render_prometheus(
            metrics,
            disk_percent,
            state_mgr.is_db_healthy(),
            reject_pct_1h=share_reject_pct(state_mgr.get_share_stats(), 3600),
            shares_accepted=summary.get("accepted", 0) or 0,
            shares_rejected=summary.get("rejected", 0) or 0,
            pool_blocks_found=pool_local.get("blocks_found", 0) or 0,
            snapshot_ts=data.get("timestamp", 0) or 0,
        )
        response = web.Response(text=body)
        response.headers["Content-Type"] = PROMETHEUS_CONTENT_TYPE
        return response
    except Exception:
        # Log the full error server-side; never leak exception details to the scraper.
        logger.exception("Error rendering Prometheus metrics")
        return web.Response(text="Failed to render metrics.", status=500, content_type="text/plain")


# --- Dashboard control channel (#33) ---------------------------------------------------------
# Registered only when DASHBOARD_CONTROL_ENABLED (absent routes 404 when the feature is off).
# Every mutating POST must carry this custom header: a cross-site header forces a CORS preflight,
# which the self-only CSP origin never grants (a cheap CSRF guard, same spirit as the CSP below).
# The actor is Caddy's authenticated X-Auth-User (header_up overwrites any client value).

CONTROL_HEADER = "X-Pithead-Control"


def _require_control_header(request):
    if request.headers.get(CONTROL_HEADER) != "1":
        raise web.HTTPForbidden(text="Missing X-Pithead-Control header.")


async def handle_config(request):
    """The live config for form prefill, every set secret masked to the sentinel."""
    try:
        return web.json_response(control_service.read_config())
    except Exception:
        logger.exception("Error reading host config")
        return web.json_response({"error": "Failed to read the stack config."}, status=500)


async def handle_control_preview(request):
    """Stage a proposed config for a host-side dry-run preview. Returns the runner's result,
    or 202 + the request id if the runner hasn't answered within the wait window."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    proposed = body.get("config")
    if not isinstance(proposed, dict):
        raise web.HTTPBadRequest(text="'config' must be a JSON object.")
    # Click-to-adopt (#893): pre-validate any newly-appended workers.list[] entry before spooling.
    adopt_err = worker_adopt.validate_new_worker_entries(control_service.read_config(), proposed)
    if adopt_err:
        raise web.HTTPBadRequest(text=adopt_err)
    actor = request.headers.get("X-Auth-User", "")
    try:
        # The proposal ships as-is: an untouched secret rides as the {"__secret__": true}
        # sentinel, and the HOST swaps it for the live value when it stages the intent (#440) —
        # this container never holds a secret the operator didn't just type.
        rid = control_service.submit("preview", proposed, actor)
        res = await control_service.wait_result(rid)
    except Exception:
        logger.exception("Error submitting control preview")
        return web.json_response({"error": "Failed to submit the preview request."}, status=500)
    if res is None:
        return web.json_response({"id": rid, "status": "pending"}, status=202)
    return web.json_response({"id": rid, **res})


async def handle_control_commit(request):
    """Ask the runner to apply a previously previewed intent, by id only — the config it applies
    is the host-side staged copy, so a tampered commit can't swap it."""
    _require_control_header(request)
    try:
        body = await request.json()
        rid = control_service.submit(
            "commit",
            actor=request.headers.get("X-Auth-User", ""),
            intent_id=body.get("id"),
            # #719: the operator's typed confirmation for an in-scope disruptive change. It is
            # friction, not a secret — the host gate requires it before a CONFIRM row proceeds.
            confirm=body.get("confirm"),
        )
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON with a valid intent 'id'.") from None
    # The preview result (same id) is still on disk; wait for the runner to overwrite it.
    res = await control_service.wait_result(rid, done=lambda r: r.get("status") != "previewed")
    if res is None:
        return web.json_response({"id": rid, "status": "pending"}, status=202)
    return web.json_response({"id": rid, **res})


async def handle_control_upgrade(request):
    """Ask the host runner to upgrade the stack to the latest release (#59). The body's version
    is only what the operator confirmed seeing ("upgrade to vX.Y.Z"); the host re-derives the real
    target from the GitHub release API and refuses a mismatch — the container cannot choose what
    gets installed. Returns 202 immediately: the upgrade recreates this very container, so the
    client polls /api/control/result and rides out the restart."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    version = body.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise web.HTTPBadRequest(text="'version' must look like vX.Y.Z.")
    try:
        rid = control_service.submit(
            "upgrade", actor=request.headers.get("X-Auth-User", ""), version=version
        )
    except Exception:
        logger.exception("Error submitting control upgrade")
        return web.json_response({"error": "Failed to submit the upgrade request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)


# The appliance OS-update steps, one closed set — anything else 400s before it reaches the
# spool. The host runner re-validates each verb and refuses them all on a non-appliance host.
OS_UPDATE_ACTIONS = frozenset({"check", "download", "verify", "install", "reboot"})


async def handle_control_os_update(request):
    """Ask the host runner to run one step of the appliance OS-update flow. The body's action
    picks the step (check/download/verify/install/reboot); ``version`` is only what the operator
    confirmed seeing — the host re-derives the real target over Tor, refuses a mismatch, and makes
    every destructive judgment (signature, compatible, downgrade floor) against the local file.
    Returns 202 immediately; the client polls /api/control/result and rides out the long steps."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    action = body.get("action")
    if action not in OS_UPDATE_ACTIONS:
        raise web.HTTPBadRequest(
            text="'action' must be one of: " + ", ".join(sorted(OS_UPDATE_ACTIONS))
        )
    version = body.get("version")
    if version is not None and (
        not isinstance(version, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", version)
    ):
        raise web.HTTPBadRequest(text="'version' must look like vX.Y.Z.")
    try:
        rid = control_service.submit(
            f"os-{action}", actor=request.headers.get("X-Auth-User", ""), version=version
        )
    except Exception:
        logger.exception("Error submitting OS-update step")
        return web.json_response({"error": "Failed to submit the OS-update request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)


async def handle_control_backup(request):
    """Ask the host runner for an encrypted backup archive + a one-time emergency kit (#908).

    No body: unlike commit/upgrade this verb takes no operator input — the host generates its own
    passphrase and never accepts one from the container (encrypted-only, refused otherwise). Like
    upgrade, this returns 202 immediately and the client polls /api/control/result."""
    _require_control_header(request)
    try:
        rid = control_service.submit("backup", actor=request.headers.get("X-Auth-User", ""))
    except Exception:
        logger.exception("Error submitting backup request")
        return web.json_response({"error": "Failed to submit the backup request."}, status=500)
    return web.json_response({"id": rid, "status": "pending"}, status=202)


async def handle_backup_download(request):
    """Stream the archive an applied backup produced (#908).

    Read-only, no CSRF header required (matches the other GET routes) — a cross-site GET can
    trigger this but can't read a cross-origin response, and the archive is useless without the
    passphrase shown once in the kit. Any id not resolving to an "applied" archive 404s."""
    try:
        rid = str(uuid.UUID(request.query.get("id", "")))
    except ValueError:
        raise web.HTTPBadRequest(text="'id' must be a UUID.") from None
    res = control_service.result(rid)
    archive_name = (res or {}).get("archive")
    if not res or res.get("status") != "applied" or not archive_name:
        raise web.HTTPNotFound(text="No completed backup for that id.")
    # FileResponse stats the path itself and answers 404 if the archive isn't there — no need to
    # check twice.
    path = os.path.join(config.CONTROL_RESULTS_DIR, f"{rid}.tar.gz.enc")
    return web.FileResponse(
        path, headers={"Content-Disposition": f'attachment; filename="{archive_name}"'}
    )


# Terminal-ish outcomes worth a history row — shared by worker-apply and worker-upgrade (#1014).
# noop/throttled are upgrade-only (the host runner's control_worker_upgrade case statement); the
# rest are common to both actions. "accepted" is genuinely non-terminal (still running on the rig
# past the wait budget) but IS the runner's final write for that request id, so it's recorded too
# — the alternative is a change the operator made that the dashboard never mentions again.
_RECORDABLE_WORKER_STATUSES = (
    "applied",
    "rejected",
    "rolled_back",
    "accepted",
    "failed",
    "noop",
    "throttled",
)


def _record_worker_result(state_mgr, worker, changes, res, change_type="apply"):
    """Log a worker-apply or worker-upgrade outcome to the per-worker config history (#185/#1014).
    Only terminal-ish statuses are kept. ``changes`` is the operator's own POST, so a pool ``pass``
    can be in it; ``add_worker_config_version`` strips it before the INSERT (#1543). ``worker``/
    ``changes`` are the caller's own, never ``res``: a pre-dial reject omits ``worker`` there."""
    status = res.get("status", "unknown")
    if status in _RECORDABLE_WORKER_STATUSES:
        state_mgr.add_worker_config_version(
            worker,
            res.get("change_id"),
            status,
            changes,
            res.get("reason") or res.get("error"),
            change_type=change_type,
        )


async def handle_worker_detail(request):
    """Per-worker inspect data (#185): the rig's current enriched telemetry, the writable config the
    dashboard last applied (the prefill — the rig's feed does not expose the writable config values),
    the change history with per-change diffs, and (#1013) its own hashrate-over-time chart — same
    ``range``/``from``/``to`` query params as ``/api/state``, so the per-rig chart can offer its own
    range control."""
    name = request.query.get("name", "")
    if not name:
        raise web.HTTPBadRequest(text="'name' is required.")
    app = request.app
    data = app["latest_data"] or {}
    state_mgr = app["state_manager"]
    range_arg = request.query.get("range", "all")
    window = parse_window(request.query.get("from"), request.query.get("to"))
    try:
        return web.json_response(build_worker_detail(name, data, state_mgr, range_arg, window))
    except Exception:
        logger.exception("Error building worker detail")
        return web.json_response({"error": "Failed to build worker detail."}, status=500)


async def handle_worker_apply(request):
    """Push a writable-key config change to a worker's rig via the HOST-side control runner (#185).

    This container never holds the rig's token: it spools ``{worker, changes}`` and the host resolves
    the rig's address + bearer from config.json (dashboard.workers[]), POSTs, and polls the rig's
    ``/status``. Fail-closed — the route only exists when the control channel is on, which itself
    requires a dashboard password. The change surface is the writable allowlist only. Records the
    terminal outcome in the per-worker config history."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    worker = body.get("worker")
    changes = body.get("changes")
    if not isinstance(worker, str) or not worker:
        raise web.HTTPBadRequest(text="'worker' must be a non-empty string.")
    err = control_service.validate_worker_changes(changes)
    if err:
        raise web.HTTPBadRequest(text=err)
    actor = request.headers.get("X-Auth-User", "")
    state_mgr = request.app["state_manager"]
    try:
        rid = control_service.submit_worker_apply(worker, changes, actor)
        # Wait for a TERMINAL outcome (skip the runner's interim "running"), using the shared
        # CONTROL_WAIT_S window. The host runner bounds its own rig dial + status poll well under that
        # window, so it always writes a terminal-ish result the wait catches — and we record it below.
        res = await control_service.wait_result(rid, done=lambda r: r.get("status") != "running")
    except Exception:
        logger.exception("Error submitting worker-apply")
        return web.json_response(
            {"error": "Failed to submit the worker config change."}, status=500
        )
    if res is None:
        return web.json_response({"id": rid, "status": "pending"}, status=202)
    _record_worker_result(state_mgr, worker, changes, res)
    return web.json_response({"id": rid, **res})


async def _finalize_worker_upgrade(state_mgr, worker, version, rid, latest_data=None):
    """The server-side half of recording a worker-upgrade attempt (#1014): ``handle_worker_upgrade``
    returns 202 before any result exists (a rig rebuild can take minutes, so it never waits inline
    like ``handle_worker_apply`` does), so this runs as its own background task and records the
    terminal outcome once the host runner writes it — independent of whether the operator's browser
    tab stays open to see it land. One row per upgrade attempt, same shape as an apply's (#185)."""
    try:
        res = await control_service.wait_result(
            rid,
            done=lambda r: r.get("status") != "running",
            timeout_s=config.CONTROL_WORKER_UPGRADE_WAIT_S,
        )
    except Exception:
        logger.exception("Error waiting for worker-upgrade result (id=%s)", rid)
        return
    if res is not None:
        _record_worker_result(state_mgr, worker, {"version": version}, res, change_type="upgrade")
        await worker_refresh.maybe_refresh_after_upgrade(latest_data, worker, version, res)


async def handle_worker_upgrade(request):
    """One-click RigForge upgrade for a single rig (#597), via the HOST-side control runner.

    Mirrors the stack's own upgrade (#59) at the per-worker level: the body's version is only what
    the operator confirmed seeing (the badge's latest, #596); the host re-derives the real target
    from the RigForge release API over Tor, refuses a mismatch, then resolves the rig's address +
    bearer from config.json — this container never holds the token or picks what gets installed.
    Returns 202 immediately (a build can take minutes); the client polls /api/control/result and a
    background task records the terminal outcome to the per-worker history (#1014). A rig already
    on the requested version short-circuits to a no-op — a dial would just burn its own throttle."""
    _require_control_header(request)
    try:
        body = await request.json()
    except Exception:
        raise web.HTTPBadRequest(text="Body must be JSON.") from None
    worker = body.get("worker")
    version = body.get("version")
    if not isinstance(worker, str) or not worker:
        raise web.HTTPBadRequest(text="'worker' must be a non-empty string.")
    if not isinstance(version, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", version):
        raise web.HTTPBadRequest(text="'version' must look like vX.Y.Z.")
    data = request.app["latest_data"] or {}
    live = next((w for w in data.get("workers", []) if w.get("name") == worker), None)
    running = ((live or {}).get("rigforge") or {}).get("version")
    # The rig reports bare "1.11.2", the badge proposes tag "v1.11.2" — compare parsed (#596).
    if running and parse_semver(running) and parse_semver(running) == parse_semver(version):
        return web.json_response(
            {"status": "noop", "worker": worker, "note": f"already on {version}"}
        )
    try:
        rid = control_service.submit_worker_upgrade(
            worker, version, request.headers.get("X-Auth-User", "")
        )
    except Exception:
        logger.exception("Error submitting worker-upgrade")
        return web.json_response({"error": "Failed to submit the worker upgrade."}, status=500)
    state_mgr = request.app["state_manager"]
    bg_tasks = request.app["_bg_tasks"]
    task = asyncio.create_task(
        _finalize_worker_upgrade(state_mgr, worker, version, rid, request.app["latest_data"])
    )
    bg_tasks.add(task)
    task.add_done_callback(bg_tasks.discard)
    return web.json_response({"id": rid, "status": "pending"}, status=202)


async def handle_control_result(request):
    """Client-side polling endpoint for a 202'd preview/commit."""
    try:
        res = control_service.result(request.query.get("id", ""))
    except ValueError:
        raise web.HTTPBadRequest(text="'id' must be a UUID.") from None
    if res is None:
        return web.json_response({"status": "pending"}, status=202)
    return web.json_response(res)


# --- Security logs (#349) ---------------------------------------------------------------------
# Read-only views over host-written files; audit_service sanitizes every field (whitelisted
# charset) before it reaches the browser — log content is attacker-influenceable input.


def _merged_audit_entries(state_mgr):
    """The Security panel's full audit feed (#530): the #33 log's live tail (read directly, so a
    commit that landed since the last poll cycle shows immediately — no mirror lag) UNION the
    durable ``audit_events`` table (the mirrored log history PLUS the out-of-band host-edit/rig-edit
    detections, which never appear in control.log at all). Deduplicated by ``id`` — a control.log
    row already mirrored to the DB is identical either way, so the DB copy wins and the direct log
    read is skipped for it. Entries with no ``id`` (a handful of pre-auth "invalid"/"refused" rows,
    #33) are never mirrored and so appear only while still in the log's own tail — a disclosed, minor
    gap, not a bug. Sorted newest first by ``ts`` (both sources share one string format, so this is a
    plain lexical sort, no parsing)."""
    merged = {e["id"]: e for e in state_mgr.get_audit_events() if e.get("id")}
    for e in audit_service.recent_changes():
        eid = e.get("id")
        if eid and eid not in merged:
            merged[eid] = {**e, "source": "control"}
        elif not eid:
            # No stable id to dedupe on — always shown live from the log tail (never mirrored).
            merged[f"log-{id(e)}"] = {**e, "source": "control"}
    return sorted(merged.values(), key=lambda e: e.get("ts", ""), reverse=True)


def _log_filters(request):
    """The #823 navigation params, parsed defensively: ``from``/``to`` as epoch seconds (anything
    non-numeric reads as absent — a malformed bound must never 500 a log view) and ``q`` trimmed
    and length-capped (it's compared, never stored or echoed unsanitized)."""

    def _num(name):
        v = request.query.get(name)
        if v in (None, ""):
            return None
        try:
            f = float(v)
        except ValueError:
            return None
        # float() happily parses "inf"/"nan", which would silently warp the window comparisons
        # (nan compares False with everything) — a non-finite bound is malformed, so it's absent.
        return f if math.isfinite(f) else None

    q = (request.query.get("q") or "").strip()[:200]
    return _num("from"), _num("to"), q or None


async def handle_audit_log(request):
    """Config-change audit entries — the #33 control-channel log plus the out-of-band host-edit /
    rig-edit detections (#530), merged and persisted so the Security panel can filter and page
    deeper than the log's own trimmed tail. Registered only alongside the control channel —
    the log is a #33 artifact and the out-of-band watchers only run when it's on.
    Accepts the #823 navigation params (``from``/``to`` epoch seconds, ``q`` substring)."""
    try:
        state_mgr = request.app["state_manager"]
        frm, to, q = _log_filters(request)
        entries = audit_service.filter_log_entries(_merged_audit_entries(state_mgr), frm, to, q)
        return web.json_response({"entries": entries})
    except Exception:
        logger.exception("Error reading the control audit log")
        return web.json_response({"error": "Failed to read the audit log."}, status=500)


# How deep the access log is read when the operator is NAVIGATING it (#823) vs the default
# glance. The tail read is byte-bounded either way (audit_service._TAIL_BYTES) — this only stops
# a filtered view from being quietly truncated to the glance depth before the filter even runs.
_ACCESS_NAV_LIMIT = 1000


async def handle_access_log(request):
    """Recent dashboard accesses + failed-login count, from Caddy's JSON access log. Always
    registered (Caddy always writes the log); behind the same Caddy basic_auth as every route.
    Accepts the #823 navigation params; the failure counters always describe the whole tail,
    never the filtered slice."""
    try:
        frm, to, q = _log_filters(request)
        filtering = frm is not None or to is not None or q is not None
        summary = audit_service.access_summary(limit=_ACCESS_NAV_LIMIT if filtering else 50)
        if filtering:
            summary["entries"] = audit_service.filter_log_entries(summary["entries"], frm, to, q)
        return web.json_response(summary)
    except Exception:
        logger.exception("Error reading the access log")
        return web.json_response({"error": "Failed to read the access log."}, status=500)


def _apply_security_headers(response):
    """Baseline hardening headers. CSP is self-only: HTML shell, CSS/JS (the vendored Preact,
    htm and Chart.js, plus the dashboard's own modules) and the JSON API are all same-origin,
    so no 'unsafe-inline' or 'unsafe-eval' is needed (Issue #60). The frontend libraries are
    eval-free ES modules; dynamic styling is applied via the CSSOM, which style-src doesn't
    govern."""
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; "
        "script-src 'self'; connect-src 'self'; frame-ancestors 'none'; "
        "base-uri 'self'; form-action 'self'"
    )
    # Make browsers revalidate instead of holding a stale copy under heuristic freshness. The
    # static CSS/JS is baked into the image, so a `pithead upgrade` changes the served bytes;
    # without this, a browser (notably iOS Safari) can keep serving the pre-upgrade dashboard.css
    # for an unpredictable while (Issue #83). 'no-cache' still allows a conditional request, so an
    # unchanged asset costs only a 304 — no re-download of the vendored libs on each page load.
    response.headers["Cache-Control"] = "no-cache"
    return response


@web.middleware
async def security_headers_middleware(request, handler):
    """Apply security headers to every response, including aiohttp error responses."""
    try:
        return _apply_security_headers(await handler(request))
    except web.HTTPException as exc:
        raise _apply_security_headers(exc) from exc


async def _cancel_bg_tasks(app):
    """Cancel any still-pending worker-upgrade recorder tasks (#1014) on shutdown — otherwise a
    task waiting out its up-to-5-minute budget outlives the app and asyncio logs a "Task was
    destroyed but it is pending" warning at interpreter exit."""
    tasks = list(app["_bg_tasks"])
    for t in tasks:
        t.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application(middlewares=[security_headers_middleware])
    app["state_manager"] = state_manager
    app["latest_data"] = latest_data_ref
    # Fire-and-forget recorder tasks (worker-upgrade, #1014) — tracked so they can't be
    # garbage-collected mid-flight and so shutdown can cancel any still in progress.
    app["_bg_tasks"] = set()
    app.on_cleanup.append(_cancel_bg_tasks)

    app.add_routes(
        [
            web.get("/", handle_index),
            web.get("/api/state", handle_state),
            # Warm-standby state a backup stack pulls on failover (#249). Read-only, same auth as
            # /api/state; harmless (and unread) on a stack with no backup.
            web.get("/api/xvb-standby", handle_xvb_standby),
            web.get("/metrics", handle_metrics),
            web.get("/api/access", handle_access_log),
        ]
    )
    # Control channel (#33): routes exist only when the feature is on — off means 404, not 403.
    # Read at call time (not import) so tests can flip the flag per-app.
    if config.DASHBOARD_CONTROL_ENABLED:
        app.add_routes(
            [
                web.get("/api/config", handle_config),
                web.post("/api/control/preview", handle_control_preview),
                web.post("/api/control/commit", handle_control_commit),
                web.post("/api/control/upgrade", handle_control_upgrade),
                web.get("/api/control/result", handle_control_result),
                web.get("/api/audit", handle_audit_log),
                # Worker Inspect (#185): read a worker's detail + config history, and push a
                # writable-key change to its rig. Gated with the rest of the control channel.
                web.get("/api/worker", handle_worker_detail),
                web.post("/api/control/worker-apply", handle_worker_apply),
                # One-click rig upgrade (#597): spools name + confirmed version only; the host
                # re-derives the real target and dials the rig. Same gate as the rest.
                web.post("/api/control/worker-upgrade", handle_worker_upgrade),
                # Encrypted backup + one-time emergency kit (#908): trigger, then stream the
                # archive the host produced for the id it names in its result.
                web.post("/api/control/backup", handle_control_backup),
                web.get("/api/control/backup-download", handle_backup_download),
                # Appliance OS update: one route, a closed action set, every judgment host-side.
                web.post("/api/control/os-update", handle_control_os_update),
            ]
        )

    static_path = os.path.join(os.path.dirname(__file__), "static")
    app.router.add_static("/static", static_path)

    return app
