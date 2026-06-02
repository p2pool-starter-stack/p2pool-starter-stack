import os
import logging
from aiohttp import web
from mining_dashboard.config.config import HOST_IP
from mining_dashboard.web.views import (
    _get_chart_context, _get_system_context, _get_pool_network_context,
    _get_algo_context, _get_tari_context, _get_worker_rows,
    build_sync_context, build_header_badges,
)

logger = logging.getLogger("WebServer")

# Absolute path to the HTML template file
TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")

# Template Caching Mechanism
_TEMPLATE_CACHE = None
_TEMPLATE_MTIME = 0

def get_cached_template():
    """Retrieves and caches the HTML template, reloading from disk only if the file has been modified."""
    global _TEMPLATE_CACHE, _TEMPLATE_MTIME
    try:
        mtime = os.path.getmtime(TEMPLATE_PATH)
        if _TEMPLATE_CACHE is None or mtime > _TEMPLATE_MTIME:
            with open(TEMPLATE_PATH, 'r') as f:
                content = f.read()
            _TEMPLATE_CACHE = content
            _TEMPLATE_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading template: {e}")
    return _TEMPLATE_CACHE or "<h1>Template Error</h1>"

async def handle_index(request):
    """
    Primary Request Handler: Aggregates all context data and renders the Dashboard HTML.
    Handles view modes (Sync vs. Dashboard) and time-range filtering.
    """
    app = request.app
    data = app['latest_data']
    state_mgr = app['state_manager']

    try:
        history = state_mgr.get_history()
        shares = data.get('shares', [])
        range_arg = request.query.get('range', 'all')

        # Use global_sync flag from DataService to trigger dashboard sync mode
        is_syncing = data.get('global_sync', False)

        # Build Contexts (presentation logic lives in web/views.py)
        sync_ctx = build_sync_context(
            data.get('monero_sync', {}), data.get('tari_sync', {}), is_syncing
        )
        chart_ctx = _get_chart_context(history, shares, range_arg)
        system_ctx = _get_system_context(data)
        pool_net_ctx = _get_pool_network_context(data)
        algo_ctx = _get_algo_context(data, state_mgr, history)
        tari_ctx = _get_tari_context(data)

        # Dynamic Components
        worker_rows = _get_worker_rows(data.get('workers', []))
        header_badges = build_header_badges(data, is_syncing, algo_ctx, pool_net_ctx)

        template = get_cached_template()

        response_html = template.format(
            host_ip=HOST_IP,
            header_badges=header_badges,
            worker_rows=worker_rows,
            **sync_ctx,
            **algo_ctx,
            **system_ctx,
            **pool_net_ctx,
            **tari_ctx,
            **chart_ctx
        )

        return web.Response(text=response_html, content_type='text/html')

    except Exception:
        # Log the full error server-side; never leak exception details to the browser.
        logger.exception("Error rendering dashboard")
        return web.Response(
            text="<h1>Dashboard error</h1><p>Something went wrong rendering the page. "
                 "See the dashboard container logs for details.</p>",
            status=500,
            content_type='text/html',
        )

def _apply_security_headers(response):
    """Baseline hardening headers. CSP is self-only (Chart.js is vendored locally);
    'unsafe-inline' is required because the template has inline <style>/<script> blocks."""
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['Referrer-Policy'] = 'no-referrer'
    response.headers['Content-Security-Policy'] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
        "script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; "
        "base-uri 'self'; form-action 'self'"
    )
    return response


@web.middleware
async def security_headers_middleware(request, handler):
    """Apply security headers to every response, including aiohttp error responses."""
    try:
        return _apply_security_headers(await handler(request))
    except web.HTTPException as exc:
        raise _apply_security_headers(exc)


def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application(middlewares=[security_headers_middleware])
    # Pass shared state objects to the app context
    app['state_manager'] = state_manager
    app['latest_data'] = latest_data_ref

    app.add_routes([web.get('/', handle_index)])

    static_path = os.path.join(os.path.dirname(__file__), "static")
    app.router.add_static('/static', static_path)

    return app
