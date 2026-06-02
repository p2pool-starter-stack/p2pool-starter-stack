from unittest.mock import MagicMock

import pytest

import mining_dashboard.web.server as server
from mining_dashboard.web.server import (
    create_app, get_cached_template, _apply_security_headers,
)
from mining_dashboard.service.storage_service import StateManager


SECURITY_HEADERS = [
    "X-Content-Type-Options",
    "X-Frame-Options",
    "Referrer-Policy",
    "Content-Security-Policy",
]


@pytest.fixture
def app_data():
    """A realistic-ish latest_data snapshot."""
    return {
        "shares": [],
        "workers": [],
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
        "global_sync": False,
    }


@pytest.fixture
async def client(aiohttp_client, app_data):
    sm = StateManager(db_path=":memory:")
    app = create_app(sm, app_data)
    cli = await aiohttp_client(app)
    yield cli
    sm.close()


class TestIndexRoute:
    async def test_get_index_ok(self, client):
        resp = await client.get("/")
        assert resp.status == 200
        assert resp.content_type == "text/html"

    async def test_security_headers_present(self, client):
        resp = await client.get("/")
        for h in SECURITY_HEADERS:
            assert h in resp.headers
        assert resp.headers["X-Frame-Options"] == "DENY"

    async def test_range_query_accepted(self, client):
        resp = await client.get("/?range=24h")
        assert resp.status == 200

    async def test_node_down_badges_rendered(self, aiohttp_client):
        # When a node is down / workers rejected, the header surfaces it (Issue #31).
        data = {
            "shares": [], "workers": [], "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10, "down": True},
            "tari_sync": {"percent": 100, "current": 10, "target": 10, "down": False},
            "workers_rejected": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        html = await (await cli.get("/")).text()
        sm.close()
        assert "monerod DOWN" in html
        assert "Tari DOWN" not in html
        assert "Workers rejected" in html

    async def test_passive_tari_syncing_badge_rendered(self, aiohttp_client):
        # Non-blocking Tari (Issue #51): the operational view stays up and shows a top-bar
        # "Tari syncing" badge with the live percentage instead of the Sync-Mode takeover.
        data = {
            "shares": [], "workers": [], "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_sync": {"percent": 42, "current": 42, "target": 100, "is_syncing": True},
            "tari_syncing_passive": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        html = await (await cli.get("/")).text()
        sm.close()
        assert "Tari syncing 42%" in html

    async def test_no_passive_tari_badge_when_not_syncing(self, aiohttp_client):
        # Default (Tari synced / blocking): no passive badge in the operational view.
        data = {
            "shares": [], "workers": [], "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_syncing_passive": False,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        html = await (await cli.get("/")).text()
        sm.close()
        assert "Tari syncing" not in html


class TestErrorHandling:
    async def test_render_error_is_sanitized(self, aiohttp_client, app_data):
        # A state manager whose get_history blows up forces the except branch.
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("SECRET internal detail")
        app = create_app(bad_sm, app_data)
        cli = await aiohttp_client(app)
        resp = await cli.get("/")
        assert resp.status == 500
        body = await resp.text()
        assert "Dashboard error" in body
        assert "SECRET internal detail" not in body  # no leak
        assert "X-Frame-Options" in resp.headers  # headers still applied


class TestHelpers:
    def test_get_cached_template_returns_str(self):
        assert isinstance(get_cached_template(), str)
        assert len(get_cached_template()) > 0

    def test_template_error_fallback(self, monkeypatch):
        server._TEMPLATE_CACHE = None
        monkeypatch.setattr(server.os.path, "getmtime", lambda p: (_ for _ in ()).throw(OSError()))
        assert get_cached_template() == "<h1>Template Error</h1>"

    def test_apply_security_headers(self):
        resp = MagicMock()
        resp.headers = {}
        _apply_security_headers(resp)
        for h in SECURITY_HEADERS:
            assert h in resp.headers
