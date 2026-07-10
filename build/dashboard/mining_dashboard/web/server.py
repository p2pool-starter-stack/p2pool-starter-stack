import asyncio
import logging
import mimetypes
import os

from aiohttp import web

from mining_dashboard.config import config as app_config
from mining_dashboard.service import control_service
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.web.prometheus import CONTENT_TYPE as PROMETHEUS_CONTENT_TYPE
from mining_dashboard.web.prometheus import render_prometheus
from mining_dashboard.web.views import build_state, canonical_window, get_shell_html, parse_window

logger = logging.getLogger("WebServer")

# Config editor (#33): every mutating control POST must carry this custom header. A custom
# header forces a CORS preflight on any cross-site request, which is never granted (same-origin
# only, consistent with the self-only CSP below) — a cheap CSRF guard with no session state.
CONTROL_CSRF_HEADER = "X-Pithead-Control"
# How long a preview/commit handler waits for the host-side runner's result before answering
# 202 (the client then polls GET /api/control/result). Module-level so tests can shrink it.
CONTROL_RESULT_TIMEOUT_S = 30
CONTROL_RESULT_POLL_S = 0.5

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


# --- Config editor / host-mutation channel routes (#33) ---
# Registered ONLY when DASHBOARD_CONTROL_ENABLED is true (create_app below) — when the channel
# is off these paths 404 like any unknown route, so the disabled channel has no surface at all.
# The dashboard side only stages typed intents and polls results; validation and execution
# happen host-side (`pithead control-run-pending`). See docs/dashboard.md and SECURITY.md.


def _control_forbidden(request):
    """The CSRF guard for mutating control requests; None when the request may proceed."""
    if request.headers.get(CONTROL_CSRF_HEADER) != "1":
        return web.json_response({"error": f"Missing {CONTROL_CSRF_HEADER} header."}, status=403)
    return None


def _actor(request):
    """The audit actor: Caddy sets X-Auth-User to the authenticated basic_auth username and
    always overwrites a client-sent value, so this is trustworthy (empty when auth is off,
    which pithead refuses to combine with the control channel anyway)."""
    return request.headers.get("X-Auth-User", "") or "unknown"


async def _await_result(request_id):
    """Poll the read-only results mount for the runner's answer; 202 + id on timeout so the
    client keeps polling GET /api/control/result — a commit can recreate this very container,
    so the result must be retrievable after a restart (it is: results/ persists on the host)."""
    deadline = asyncio.get_event_loop().time() + CONTROL_RESULT_TIMEOUT_S
    while asyncio.get_event_loop().time() < deadline:
        res = control_service.result(request_id)
        if res is not None:
            return web.json_response(res)
        await asyncio.sleep(CONTROL_RESULT_POLL_S)
    return web.json_response({"id": request_id, "status": "pending"}, status=202)


async def handle_get_config(request):
    """The host's config.json for form prefill, with every secret leaf masked to the
    ``__secret__`` sentinel — raw secrets never reach the browser."""
    try:
        return web.json_response(control_service.read_config())
    except Exception:
        logger.exception("Error reading the host config")
        return web.json_response({"error": "Failed to read the host config."}, status=500)


async def handle_control_preview(request):
    """Stage a proposed config as a typed 'preview' intent for the host runner to validate."""
    forbidden = _control_forbidden(request)
    if forbidden:
        return forbidden
    try:
        proposed = await request.json()
    except ValueError:
        return web.json_response({"error": "Request body is not valid JSON."}, status=400)
    if not isinstance(proposed, dict):
        return web.json_response({"error": "Expected a config object."}, status=400)
    try:
        merged = control_service.merge_secrets(proposed)
        rid = control_service.submit("preview", config=merged, actor=_actor(request))
    except Exception:
        logger.exception("Error submitting a preview intent")
        return web.json_response({"error": "Failed to submit the preview."}, status=500)
    return await _await_result(rid)


async def handle_control_commit(request):
    """Ask the host runner to apply a previously previewed intent (by its id). The runner
    only ever applies its own host-side staged copy — the config can't be swapped here."""
    forbidden = _control_forbidden(request)
    if forbidden:
        return forbidden
    try:
        body = await request.json()
    except ValueError:
        return web.json_response({"error": "Request body is not valid JSON."}, status=400)
    intent_id = body.get("intent_id") if isinstance(body, dict) else None
    if not isinstance(intent_id, str) or control_service.result(intent_id) is None:
        # No previewed result for that id => nothing staged worth committing (also rejects
        # malformed ids before they go anywhere near a filename).
        return web.json_response({"error": "Unknown intent_id — preview first."}, status=400)
    try:
        rid = control_service.submit("commit", intent_id=intent_id, actor=_actor(request))
    except Exception:
        logger.exception("Error submitting a commit intent")
        return web.json_response({"error": "Failed to submit the commit."}, status=500)
    return await _await_result(rid)


async def handle_control_result(request):
    """Poll one runner result by request id; 202 while it's still pending."""
    rid = request.query.get("id", "")
    res = control_service.result(rid)
    if res is None:
        return web.json_response({"id": rid, "status": "pending"}, status=202)
    return web.json_response(res)


async def handle_control_audit(request):
    """The host-written audit trail (read-only mount) — what changed, when, approved by whom."""
    return web.json_response(control_service.read_audit())


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
        ]
    )

    # Config editor (#33): the control routes exist ONLY when the channel is enabled — off
    # (the default) means 404, not 403, so the disabled channel has no probeable surface.
    if app_config.DASHBOARD_CONTROL_ENABLED:
        app.add_routes(
            [
                web.get("/api/config", handle_get_config),
                web.post("/api/control/preview", handle_control_preview),
                web.post("/api/control/commit", handle_control_commit),
                web.get("/api/control/result", handle_control_result),
                web.get("/api/control/audit", handle_control_audit),
            ]
        )

    static_path = os.path.join(os.path.dirname(__file__), "static")
    app.router.add_static("/static", static_path)

    return app
