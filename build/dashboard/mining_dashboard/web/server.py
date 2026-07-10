import asyncio
import logging
import mimetypes
import os

from aiohttp import web

from mining_dashboard.config import config
from mining_dashboard.service.control_service import ControlService
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.web.prometheus import CONTENT_TYPE as PROMETHEUS_CONTENT_TYPE
from mining_dashboard.web.prometheus import render_prometheus
from mining_dashboard.web.views import build_state, canonical_window, get_shell_html, parse_window

logger = logging.getLogger("WebServer")

# How long a preview/commit POST waits for the host runner's result before it hands the client an id
# to poll on its own. The systemd path-unit fires within a second or two; 30 s covers a slow apply.
CONTROL_RESULT_WAIT_S = 30
CONTROL_POLL_INTERVAL_S = 0.5
# Custom header every control POST must carry. A custom request header forces a CORS preflight on any
# cross-site attempt, which the self-only CSP never grants — so a hostile page can't drive the
# channel with the operator's session (a cheap, self-consistent CSRF guard; #33).
CONTROL_CSRF_HEADER = "X-Pithead-Control"

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


# --- Config editor / host-mutation channel (#33) -------------------------------------------------
# These handlers are registered ONLY when DASHBOARD_CONTROL_ENABLED is true, so with the channel off
# every route below is a 404 and the editor is fully inert. The dashboard only ever WRITES a typed
# intent; the host runner re-validates and decides. See control_service.py.


def _require_csrf(request):
    """Reject any control POST that doesn't carry the custom header (the CSRF guard)."""
    if request.headers.get(CONTROL_CSRF_HEADER) != "1":
        raise web.HTTPForbidden(reason="Missing control header")


def _actor(request):
    """The audit actor = the Caddy-authenticated user, passed through as X-Auth-User. Caddy sets it
    (a browser can't spoof it); absent/blank when no login is configured."""
    return request.headers.get("X-Auth-User") or "unknown"


async def _await_result(control, request_id):
    """Poll the read-only results/ dir for the runner's verdict, up to CONTROL_RESULT_WAIT_S."""
    waited = 0.0
    while waited < CONTROL_RESULT_WAIT_S:
        result = control.result(request_id)
        if result is not None:
            return result
        await asyncio.sleep(CONTROL_POLL_INTERVAL_S)
        waited += CONTROL_POLL_INTERVAL_S
    return None


async def handle_get_config(request):
    """The on-disk config with secrets masked, to prefill the editor."""
    try:
        return web.json_response(request.app["control"].read_config())
    except (OSError, ValueError):
        logger.exception("Could not read host config")
        return web.json_response({"error": "Could not read host config."}, status=500)


async def handle_control_preview(request):
    """Stage a proposed config and ask the host to preview it (`apply --dry-run`)."""
    _require_csrf(request)
    control = request.app["control"]
    try:
        body = await request.json()
    except ValueError:
        raise web.HTTPBadRequest(reason="Invalid JSON") from None
    proposed = body.get("config")
    if not isinstance(proposed, dict):
        raise web.HTTPBadRequest(reason="Missing config")
    merged = control.merge_secrets(proposed)
    request_id = control.submit("preview", merged, _actor(request))
    result = await _await_result(control, request_id)
    if result is None:
        return web.json_response({"id": request_id, "status": "pending"}, status=202)
    return web.json_response({"id": request_id, **result})


async def handle_control_commit(request):
    """Apply the config a prior preview staged, referenced by intent_id. The host loads its own
    staged copy — the commit carries no config, so nothing can be swapped after the preview."""
    _require_csrf(request)
    control = request.app["control"]
    try:
        body = await request.json()
    except ValueError:
        raise web.HTTPBadRequest(reason="Invalid JSON") from None
    intent_id = body.get("intent_id")
    if not isinstance(intent_id, str) or not intent_id:
        raise web.HTTPBadRequest(reason="Missing intent_id")
    request_id = control.submit("commit", {}, _actor(request), intent_id=intent_id)
    result = await _await_result(control, request_id)
    if result is None:
        return web.json_response({"id": request_id, "status": "pending"}, status=202)
    return web.json_response({"id": request_id, **result})


async def handle_control_result(request):
    """Poll a specific request's result by id (for the 202 client-side polling path)."""
    request_id = request.query.get("id", "")
    result = request.app["control"].result(request_id)
    if result is None:
        return web.json_response({"id": request_id, "status": "pending"}, status=202)
    return web.json_response({"id": request_id, **result})


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

    # Config editor (#33): opt-in. Register the mutation routes only when the channel is enabled, so
    # they simply don't exist (404) otherwise — the security boundary is "absent", not "guarded".
    if config.DASHBOARD_CONTROL_ENABLED:
        app["control"] = ControlService(
            host_config_path=config.HOST_CONFIG_PATH,
            requests_dir=config.CONTROL_REQUESTS_DIR,
            results_dir=config.CONTROL_RESULTS_DIR,
            audit_log=config.CONTROL_AUDIT_LOG,
        )
        app.add_routes(
            [
                web.get("/api/config", handle_get_config),
                web.post("/api/control/preview", handle_control_preview),
                web.post("/api/control/commit", handle_control_commit),
                web.get("/api/control/result", handle_control_result),
            ]
        )

    static_path = os.path.join(os.path.dirname(__file__), "static")
    app.router.add_static("/static", static_path)

    return app
