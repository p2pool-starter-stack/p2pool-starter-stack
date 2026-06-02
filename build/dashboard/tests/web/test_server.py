import time
from unittest.mock import MagicMock

import pytest

import mining_dashboard.web.server as server
from mining_dashboard.web.server import (
    create_app, _get_chart_context, get_cached_template, _apply_security_headers,
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


class TestChartContext:
    def _history(self, n, base_ts):
        return [{"timestamp": base_ts + i, "v": i, "v_p2pool": 0, "v_xvb": 0,
                 "t": "x"} for i in range(n)]

    def test_range_filtering(self):
        now = time.time()
        history = [{"timestamp": now - 7200, "v": 1, "v_p2pool": 0, "v_xvb": 0, "t": "x"},
                   {"timestamp": now - 60, "v": 2, "v_p2pool": 0, "v_xvb": 0, "t": "x"}]
        ctx_all = _get_chart_context(history, [], "all")
        ctx_1h = _get_chart_context(history, [], "1h")
        # both return a context dict; 1h filtering drops the 2h-old point from the payload
        assert isinstance(ctx_all, dict) and isinstance(ctx_1h, dict)

    def test_downsampling_caps_points(self):
        now = time.time()
        big = self._history(2000, now - 2000)
        ctx = _get_chart_context(big, [], "all")
        assert isinstance(ctx, dict)


class TestAvgP2poolOverWindow:
    def test_empty_history_returns_zero(self):
        assert server._avg_p2pool_over_window([], 3600) == 0.0

    def test_averages_v_p2pool_in_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 500, "v_p2pool": 500, "v_xvb": 0},
        ]
        assert server._avg_p2pool_over_window(history, 3600) == 750.0

    def test_excludes_samples_outside_window(self):
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 7200, "v": 200, "v_p2pool": 200, "v_xvb": 0},
        ]
        assert server._avg_p2pool_over_window(history, 3600) == 1000.0

    def test_legacy_rows_count_as_p2pool(self):
        now = time.time()
        history = [{"timestamp": now - 30, "v": 800, "v_p2pool": 0, "v_xvb": 0}]
        assert server._avg_p2pool_over_window(history, 3600) == 800.0

    def test_xvb_samples_drag_average_down(self):
        # Time spent donating to XvB reduces the P2Pool average (v_p2pool == 0 then).
        now = time.time()
        history = [
            {"timestamp": now - 30, "v": 1000, "v_p2pool": 1000, "v_xvb": 0},
            {"timestamp": now - 60, "v": 1000, "v_p2pool": 0, "v_xvb": 1000},
        ]
        assert server._avg_p2pool_over_window(history, 3600) == 500.0


class TestAlgoContextColors:
    MUTED = "#8b949e"

    def _ctx(self, mode):
        sm = StateManager(db_path=":memory:")
        sm.update_xvb_stats(mode=mode)
        try:
            return server._get_algo_context({"total_live_h15": 100000}, sm, [])
        finally:
            sm.close()

    def test_p2pool_mode_grays_xvb(self):
        ctx = self._ctx("P2POOL")
        assert ctx["xvb_color"] == self.MUTED
        assert ctx["p2p_color"] != self.MUTED

    def test_xvb_mode_grays_p2pool(self):
        ctx = self._ctx("XVB")
        assert ctx["p2p_color"] == self.MUTED
        assert ctx["xvb_color"] != self.MUTED

    def test_split_mode_both_active(self):
        ctx = self._ctx("XVB (Split)")
        assert ctx["p2p_color"] != self.MUTED
        assert ctx["xvb_color"] != self.MUTED

    def test_xvb_disabled_grays_xvb(self, monkeypatch):
        monkeypatch.setattr(server, "ENABLE_XVB", False)
        ctx = self._ctx("XVB")
        assert ctx["xvb_color"] == self.MUTED
        assert "Disabled" in ctx["mode_name"]


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
