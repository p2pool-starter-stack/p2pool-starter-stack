import logging
import mimetypes
import os
import re

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service import audit_service, control_service
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.update_checker import parse_semver
from mining_dashboard.web.prometheus import CONTENT_TYPE as PROMETHEUS_CONTENT_TYPE
from mining_dashboard.web.prometheus import render_prometheus
from mining_dashboard.web.views import (
    build_state,
    build_worker_detail,
    canonical_window,
    get_shell_html,
    parse_window,
)

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
# Every mutating POST must carry this custom header: a cross-site request with a custom header
# forces a CORS preflight, which the self-only CSP origin never grants — a cheap CSRF guard in
# the same spirit as the CSP below. The actor is Caddy's authenticated X-Auth-User (header_up
# overwrites any client-supplied value), threaded through to the host-side audit log.

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


def _record_worker_result(state_mgr, worker, changes, res):
    """Log a worker-apply outcome to the per-worker config history (#185). Only terminal-ish
    statuses are kept; ``changes`` carries no secret (the rig token stays host-side)."""
    status = res.get("status", "unknown")
    if status in ("applied", "rejected", "rolled_back", "accepted", "failed"):
        state_mgr.add_worker_config_version(
            worker,
            res.get("change_id"),
            status,
            changes,
            res.get("reason") or res.get("error"),
        )


async def handle_worker_detail(request):
    """Per-worker inspect data (#185): the rig's current enriched telemetry, the writable config the
    dashboard last applied (the prefill — the rig's feed does not expose the writable config values),
    and the change history with per-change diffs."""
    name = request.query.get("name", "")
    if not name:
        raise web.HTTPBadRequest(text="'name' is required.")
    app = request.app
    data = app["latest_data"] or {}
    state_mgr = app["state_manager"]
    try:
        return web.json_response(build_worker_detail(name, data, state_mgr))
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


async def handle_worker_upgrade(request):
    """One-click RigForge upgrade for a single rig (#597), via the HOST-side control runner.

    Mirrors the stack's own upgrade (#59) at the per-worker level: the body's version is only what
    the operator confirmed seeing (the badge's latest, #596); the host re-derives the real target
    from the RigForge release API over Tor and refuses a mismatch, then resolves the rig's address
    + bearer from config.json — this container never holds the token and cannot choose what gets
    installed. Returns 202 + the request id immediately (a rig build can take minutes); the client
    polls /api/control/result. A rig already reporting the requested version short-circuits to a
    no-op without spooling — a dial would just burn the rig's own 6h upgrade throttle."""
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


async def handle_audit_log(request):
    """Recent config-change audit entries, from the read-only /control/audit mount. Registered
    only alongside the control channel — the log is a #33 artifact."""
    try:
        return web.json_response({"entries": audit_service.recent_changes()})
    except Exception:
        logger.exception("Error reading the control audit log")
        return web.json_response({"error": "Failed to read the audit log."}, status=500)


async def handle_access_log(request):
    """Recent dashboard accesses + failed-login count, from Caddy's JSON access log. Always
    registered (Caddy always writes the log); behind the same Caddy basic_auth as every route."""
    try:
        return web.json_response(audit_service.access_summary())
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


def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application(middlewares=[security_headers_middleware])
    # Pass shared state objects to the app context
    app["state_manager"] = state_manager
    app["latest_data"] = latest_data_ref

    app.add_routes(
        [
            web.get("/", handle_index),
            web.get("/api/state", handle_state),
            web.get("/metrics", handle_metrics),
            web.get("/api/access", handle_access_log),
        ]
    )
    # Control channel (#33): routes exist only when the feature is on — off means 404, not 403,
    # so a disabled stack exposes no hint that the endpoints exist. Read at call time (not
    # import) so tests can flip the flag per-app.
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
            ]
        )

    static_path = os.path.join(os.path.dirname(__file__), "static")
    app.router.add_static("/static", static_path)

    return app
