import os
import logging
from aiohttp import web

from mining_dashboard.web.views import render_dashboard

logger = logging.getLogger("WebServer")


async def handle_index(request):
    """Render the dashboard. Pure transport: pull shared state, delegate to the view layer,
    and turn the result (or a failure) into an HTTP response."""
    app = request.app
    data = app['latest_data']
    state_mgr = app['state_manager']
    range_arg = request.query.get('range', 'all')

    try:
        return web.Response(
            text=render_dashboard(data, state_mgr, range_arg),
            content_type='text/html',
        )
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
