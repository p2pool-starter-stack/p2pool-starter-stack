import json
from unittest.mock import MagicMock

import pytest

from mining_dashboard.service.control_service import SECRET_SENTINEL
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server
from mining_dashboard.web.server import _apply_security_headers, create_app

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


class TestShellRoute:
    async def test_index_serves_shell(self, client):
        resp = await client.get("/")
        assert resp.status == 200
        assert resp.content_type == "text/html"
        body = await resp.text()
        # Static shell: no data, just the app mount point + the module entry.
        assert 'id="app"' in body
        assert "/static/dashboard.js" in body


class TestStateApi:
    async def test_get_state_ok_json(self, client):
        resp = await client.get("/api/state")
        assert resp.status == 200
        assert resp.content_type == "application/json"
        body = await resp.json()
        for key in ("badges", "hashrate", "system", "sync", "workers", "chart", "tari"):
            assert key in body

    async def test_range_query_accepted(self, client):
        resp = await client.get("/api/state?range=24h")
        assert resp.status == 200
        assert (await resp.json())["range"] == "24h"

    async def test_from_to_window_accepted(self, client):
        # A manual-zoom window (Issue #47) is parsed and echoed back in the payload.
        resp = await client.get("/api/state?from=1000&to=2000")
        assert resp.status == 200
        assert (await resp.json())["window"] == {"from": 1000.0, "to": 2000.0}

    async def test_malformed_from_to_falls_back(self, client):
        # Garbage from/to must not 500 — it falls back to the preset range, window null.
        resp = await client.get("/api/state?from=foo&to=2000")
        assert resp.status == 200
        assert (await resp.json())["window"] is None

    async def test_window_filters_history_end_to_end(self, aiohttp_client):
        # Functionality through the whole stack (Issue #47): a from/to window restricts the
        # chart series to that span. 20 minute-spaced points; a window over 5 of them returns 5.
        sm = StateManager(db_path=":memory:")
        base = 1_000_000
        for i in range(20):
            sm.state["hashrate_history"].append(
                {"t": "x", "v": 100, "v_p2pool": 100, "v_xvb": 0, "timestamp": base + i * 60}
            )
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 1, "target": 1},
            "tari_sync": {"percent": 100, "current": 1, "target": 1},
        }
        cli = await aiohttp_client(create_app(sm, data))
        resp = await cli.get(f"/api/state?from={base + 300}&to={base + 540}")  # indices 5..9
        body = await resp.json()
        sm.close()
        pts = [p for p in body["chart"]["p2pool"] if p["y"] is not None]
        assert len(pts) == 5
        assert body["window"] == {"from": base + 300, "to": base + 540}

    async def test_node_down_badges_in_state(self, aiohttp_client):
        # When a node is down / workers rejected, the state surfaces it (Issue #31).
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10, "down": True},
            "tari_sync": {"percent": 100, "current": 10, "target": 10, "down": False},
            "workers_rejected": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        texts = [b["text"] for b in (await (await cli.get("/api/state")).json())["badges"]]
        sm.close()
        assert "monerod DOWN" in texts
        assert "Tari DOWN" not in texts
        assert "Workers rejected" in texts

    async def test_passive_tari_badge_in_state(self, aiohttp_client):
        # Non-blocking Tari (Issue #51): operational, with a top-bar "Tari syncing" badge.
        data = {
            "shares": [],
            "workers": [],
            "global_sync": False,
            "monero_sync": {"percent": 100, "current": 10, "target": 10},
            "tari_sync": {"percent": 42, "current": 42, "target": 100},
            "tari_syncing_passive": True,
        }
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, data))
        texts = [b["text"] for b in (await (await cli.get("/api/state")).json())["badges"]]
        sm.close()
        assert "Tari syncing 42%" in texts

    async def test_state_error_is_sanitized_json(self, aiohttp_client, app_data):
        # A state manager whose get_history blows up forces the except branch -> JSON 500.
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("SECRET internal detail")
        cli = await aiohttp_client(create_app(bad_sm, app_data))
        resp = await cli.get("/api/state")
        assert resp.status == 500
        body = await resp.json()
        assert "error" in body
        assert "SECRET internal detail" not in str(body)  # no leak
        assert "X-Frame-Options" in resp.headers  # headers still applied


class TestMetricsEndpoint:
    async def test_metrics_ok_text_plain(self, client):
        # /metrics (#379): Prometheus exposition text from the same snapshot as /api/state.
        resp = await client.get("/metrics")
        assert resp.status == 200
        assert resp.content_type == "text/plain"
        # Exposition version parameter so scrapers negotiate the 0.0.4 text format.
        assert "version=0.0.4" in resp.headers["Content-Type"]
        body = await resp.text()
        assert "pithead_workers_total" in body
        assert "# TYPE pithead_workers_total gauge" in body
        # The batch's own signals ride the same endpoint: staleness + cumulative counters.
        assert "pithead_snapshot_age_seconds" in body
        assert "# TYPE pithead_shares_accepted_total counter" in body

    async def test_metrics_error_is_sanitized(self, aiohttp_client, app_data):
        # A blowing-up state manager forces the except branch -> 500, no traceback body.
        bad_sm = MagicMock()
        bad_sm.get_history.side_effect = RuntimeError("SECRET internal detail")
        cli = await aiohttp_client(create_app(bad_sm, app_data))
        resp = await cli.get("/metrics")
        assert resp.status == 500
        body = await resp.text()
        assert "SECRET internal detail" not in body
        assert "Traceback" not in body


class TestControlChannelOff:
    """With dashboard.control disabled (the default), the mutation routes must not exist at all —
    the boundary is "absent", not "guarded" (#33)."""

    async def test_config_route_404_when_disabled(self, aiohttp_client, app_data, monkeypatch):
        monkeypatch.setattr(server.config, "DASHBOARD_CONTROL_ENABLED", False)
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, app_data))
        for path in ("/api/config", "/api/control/result?id=x"):
            assert (await cli.get(path)).status == 404, path
        assert (await cli.post("/api/control/preview")).status == 404
        assert (await cli.post("/api/control/commit")).status == 404
        sm.close()


HOST_CONFIG = {
    "monero": {"wallet_address": "4W", "node_password": "rpcpass"},
    "p2pool": {"pool": "main"},
    "dashboard": {"auth": {"password": "hunter2hunter2"}},
}


@pytest.fixture
async def control_client(aiohttp_client, app_data, tmp_path, monkeypatch):
    """A client with the control channel enabled, wired to a tmp spool + host config."""
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps(HOST_CONFIG))
    reqs, results, audit = tmp_path / "requests", tmp_path / "results", tmp_path / "audit"
    reqs.mkdir()
    results.mkdir()
    audit.mkdir()
    monkeypatch.setattr(server.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(server.config, "HOST_CONFIG_PATH", str(cfg))
    monkeypatch.setattr(server.config, "CONTROL_REQUESTS_DIR", str(reqs))
    monkeypatch.setattr(server.config, "CONTROL_RESULTS_DIR", str(results))
    monkeypatch.setattr(server.config, "CONTROL_AUDIT_LOG", str(audit / "control.log"))
    # Don't block the test 30s waiting for a runner that isn't there — fall straight to the 202 path.
    monkeypatch.setattr(server, "CONTROL_RESULT_WAIT_S", 0)
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, app_data))
    cli._pithead_dirs = (reqs, results)
    yield cli
    sm.close()


class TestControlChannelOn:
    async def test_get_config_masks_secrets(self, control_client):
        body = await (await control_client.get("/api/config")).json()
        assert body["monero"]["node_password"] == SECRET_SENTINEL
        assert body["dashboard"]["auth"]["password"] == SECRET_SENTINEL
        assert "rpcpass" not in json.dumps(body)
        assert body["p2pool"]["pool"] == "main"  # non-secret passes through

    async def test_preview_without_csrf_header_is_403(self, control_client):
        resp = await control_client.post("/api/control/preview", json={"config": {}})
        assert resp.status == 403

    async def test_commit_without_csrf_header_is_403(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", json={"intent_id": "11111111-2222-4333-8444-555555555555"}
        )
        assert resp.status == 403

    async def test_preview_writes_request_and_returns_id(self, control_client):
        resp = await control_client.post(
            "/api/control/preview",
            headers={"X-Pithead-Control": "1", "X-Auth-User": "alice"},
            json={"config": {"p2pool": {"pool": "mini"}}},
        )
        # No runner in this tier, so it hands back a pollable id (202).
        assert resp.status == 202
        body = await resp.json()
        rid = body["id"]
        reqs, _ = control_client._pithead_dirs
        intent = json.loads((reqs / (rid + ".json")).read_text())
        assert intent["action"] == "preview"
        assert intent["actor"] == "alice"  # X-Auth-User carried through as the audit actor
        assert intent["config"]["p2pool"]["pool"] == "mini"

    async def test_preview_bad_body_is_400(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", headers={"X-Pithead-Control": "1"}, json={"nope": 1}
        )
        assert resp.status == 400

    async def test_commit_requires_intent_id(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", headers={"X-Pithead-Control": "1"}, json={}
        )
        assert resp.status == 400

    async def test_result_returns_written_verdict(self, control_client):
        _, results = control_client._pithead_dirs
        rid = "11111111-2222-4333-8444-555555555555"
        (results / (rid + ".json")).write_text(json.dumps({"status": "applied"}))
        resp = await control_client.get("/api/control/result?id=" + rid)
        assert resp.status == 200
        assert (await resp.json())["status"] == "applied"

    async def test_result_pending_is_202(self, control_client):
        resp = await control_client.get(
            "/api/control/result?id=deadbeef-0000-4000-8000-000000000000"
        )
        assert resp.status == 202

    async def test_preview_returns_result_when_runner_answers(self, control_client, monkeypatch):
        # When the host runner has written a result within the wait window, the POST returns it (200).
        control = control_client.app["control"]
        _, results = control_client._pithead_dirs
        rid = "22222222-3333-4444-8555-666666666666"
        (results / (rid + ".json")).write_text(
            json.dumps({"status": "previewed", "changes": [], "destructive": False})
        )
        monkeypatch.setattr(control, "submit", lambda *a, **k: rid)
        monkeypatch.setattr(server, "CONTROL_RESULT_WAIT_S", 1)
        resp = await control_client.post(
            "/api/control/preview",
            headers={"X-Pithead-Control": "1"},
            json={"config": {"p2pool": {"pool": "mini"}}},
        )
        assert resp.status == 200
        body = await resp.json()
        assert body["status"] == "previewed"
        assert body["id"] == rid

    async def test_commit_returns_result_when_runner_answers(self, control_client, monkeypatch):
        control = control_client.app["control"]
        _, results = control_client._pithead_dirs
        rid = "33333333-4444-4555-8666-777777777777"
        (results / (rid + ".json")).write_text(json.dumps({"status": "applied", "output": "ok"}))
        monkeypatch.setattr(control, "submit", lambda *a, **k: rid)
        monkeypatch.setattr(server, "CONTROL_RESULT_WAIT_S", 1)
        resp = await control_client.post(
            "/api/control/commit",
            headers={"X-Pithead-Control": "1"},
            json={"intent_id": "22222222-3333-4444-8555-666666666666"},
        )
        assert resp.status == 200
        assert (await resp.json())["status"] == "applied"

    async def test_get_config_error_is_500(self, control_client):
        control_client.app["control"].host_config_path = "/no/such/config.json"
        resp = await control_client.get("/api/config")
        assert resp.status == 500

    async def test_poll_waits_for_a_slow_runner(self, control_client, monkeypatch):
        # The result isn't there on the first poll but appears on the second — the handler must sleep
        # and re-check rather than give up (the apply-then-write can lag the submit by a moment).
        control = control_client.app["control"]
        monkeypatch.setattr(server, "CONTROL_RESULT_WAIT_S", 2)
        monkeypatch.setattr(server, "CONTROL_POLL_INTERVAL_S", 0.01)
        calls = {"n": 0}

        def slow_result(_id):
            calls["n"] += 1
            return {"status": "previewed"} if calls["n"] >= 2 else None

        monkeypatch.setattr(control, "result", slow_result)
        monkeypatch.setattr(control, "submit", lambda *a, **k: "id")
        resp = await control_client.post(
            "/api/control/preview", headers={"X-Pithead-Control": "1"}, json={"config": {}}
        )
        assert resp.status == 200
        assert calls["n"] >= 2


class TestSecurityHeaders:
    async def test_security_headers_present(self, client):
        resp = await client.get("/")
        for h in SECURITY_HEADERS:
            assert h in resp.headers
        assert resp.headers["X-Frame-Options"] == "DENY"

    async def test_csp_has_no_unsafe_inline_or_eval(self, client):
        # The whole app (HTML shell, ES modules, JSON API) is same-origin, so the CSP needs
        # neither 'unsafe-inline' nor 'unsafe-eval' (Issue #60 + rearchitecture).
        csp = (await client.get("/")).headers["Content-Security-Policy"]
        assert "'unsafe-inline'" not in csp
        assert "'unsafe-eval'" not in csp
        assert "script-src 'self'" in csp
        assert "style-src 'self'" in csp

    async def test_state_response_also_carries_headers(self, client):
        # Security headers are applied by middleware to every response, JSON included.
        resp = await client.get("/api/state")
        for h in SECURITY_HEADERS:
            assert h in resp.headers

    def test_apply_security_headers_unit(self):
        resp = MagicMock()
        resp.headers = {}
        _apply_security_headers(resp)
        for h in SECURITY_HEADERS:
            assert h in resp.headers


class TestStaticAssets:
    def test_js_mimetypes_registered(self):
        # Importing server registers these so .mjs/.js always serve as JS, even on slim
        # images with no /etc/mime.types (browsers refuse non-JS MIME for modules).
        import mimetypes

        assert "javascript" in (mimetypes.guess_type("app.mjs")[0] or "")
        assert "javascript" in (mimetypes.guess_type("app.js")[0] or "")

    async def test_frontend_modules_served(self, client):
        for path, ctype in (
            ("/static/dashboard.css", "text/css"),
            ("/static/dashboard.js", "javascript"),
            ("/static/components.mjs", "javascript"),
            ("/static/logic.mjs", "javascript"),
            ("/static/vendor/preact.module.js", "javascript"),
            ("/static/vendor/htm.module.js", "javascript"),
            ("/static/vendor/chartjs-plugin-zoom.min.js", "javascript"),
            ("/static/vendor/hammer.min.js", "javascript"),
        ):
            resp = await client.get(path)
            assert resp.status == 200, path
            assert ctype in resp.headers["Content-Type"], path

    async def test_static_assets_revalidate(self, client):
        # Cache-Control: no-cache makes the browser revalidate, so a rebuilt dashboard's new
        # CSS/JS is picked up on the next load instead of a stale copy lingering (Issue #83).
        resp = await client.get("/static/dashboard.css")
        assert resp.headers.get("Cache-Control") == "no-cache"

    async def test_shell_revalidates(self, client):
        resp = await client.get("/")
        assert resp.headers.get("Cache-Control") == "no-cache"


class TestResponsiveLayout:
    """The mobile/responsive layout (Issue #83) is pure CSS + a markup wrapper, with no DOM
    test harness in this repo (rendering is covered by the manual browser smoke test). These
    guard the pieces that have to be present and wired together so the feature can't silently
    regress: the served CSS must carry a phone breakpoint and the horizontal-scroll rule, and
    the workers-table markup must opt into that scroll wrapper."""

    async def test_css_has_phone_breakpoint(self, client):
        css = await (await client.get("/static/dashboard.css")).text()
        # A max-width media query is what makes the layout reflow on phones; without one the
        # only @media block left would be the prefers-color-scheme theme query.
        assert "@media" in css and "max-width" in css

    async def test_css_has_horizontal_scroll_rule(self, client):
        css = await (await client.get("/static/dashboard.css")).text()
        assert ".table-scroll" in css and "overflow-x" in css

    async def test_workers_table_opts_into_scroll_wrapper(self, client):
        # The CSS rule only helps if the markup actually wraps the table in it.
        mjs = await (await client.get("/static/components.mjs")).text()
        assert "table-scroll" in mjs

    async def test_css_lets_stat_values_wrap(self, client):
        # The stat-card grid is `1fr 1fr`; without overflow-wrap on the value a long unbroken
        # string (a shortened wallet/hash, "Donor (1.00 kH/s+)") keeps the grid wider than the
        # card and overflows it on a phone. Guard that the wrap rule stays present.
        css = await (await client.get("/static/dashboard.css")).text()
        assert "overflow-wrap" in css

    async def test_css_lets_hostname_wrap(self, client):
        # HOST_IP is arbitrary user input; a long unbroken hostname would push the header (and
        # the page) wider than a phone without a wrap rule. Since #81 the host IP lives in the
        # brand subtitle (`.brand-host`), which carries the overflow-wrap protection.
        css = await (await client.get("/static/dashboard.css")).text()
        assert ".brand-host" in css and "overflow-wrap" in css

    async def test_host_at_separator_styled_and_rendered(self, client):
        # The "hostname @ ip" subtitle (#119) renders the @ as a dimmed connector span, so the
        # markup must emit `.brand-host-at` and the CSS must carry a matching dimming rule.
        mjs = await (await client.get("/static/components.mjs")).text()
        css = await (await client.get("/static/dashboard.css")).text()
        assert "brand-host-at" in mjs and "state.host_addr" in mjs
        assert ".brand-host-at" in css and "opacity" in css
