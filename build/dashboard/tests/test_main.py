from aiohttp import web

from mining_dashboard.main import build_app


def test_build_app_returns_wired_application():
    """build_app() must construct the full app graph with no network/DB side effects
    at import time (the DB is redirected to a temp file by the conftest fixture)."""
    app = build_app()
    try:
        assert isinstance(app, web.Application)
        assert app["state_manager"] is not None
        # The index route is registered.
        assert any(getattr(r, "handler", None) for r in app.router.routes())
        # Startup/cleanup hooks are wired for the background tasks.
        assert app.on_startup and app.on_cleanup
    finally:
        app["state_manager"].close()
