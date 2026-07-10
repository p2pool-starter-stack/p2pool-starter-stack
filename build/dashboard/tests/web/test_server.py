import json
from unittest.mock import MagicMock

import pytest

from mining_dashboard.service import control_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web import server as server_module
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


class TestControlRoutesDisabled:
    """With dashboard.control.enabled off (the default) the control routes are never
    registered — the disabled channel has no surface at all (Issue #33)."""

    async def test_all_control_routes_404(self, client):
        for method, path in (
            ("GET", "/api/config"),
            ("POST", "/api/control/preview"),
            ("POST", "/api/control/commit"),
            ("GET", "/api/control/result?id=x"),
            ("GET", "/api/control/audit"),
        ):
            resp = await client.request(method, path, headers={"X-Pithead-Control": "1"})
            assert resp.status == 404, path


CONTROL_HEADERS = {"X-Pithead-Control": "1", "X-Auth-User": "admin"}


@pytest.fixture
def control_dirs(tmp_path, monkeypatch):
    """Enable the channel and point every control path at tmp_path (no container mounts)."""
    for name in ("requests", "results", "audit"):
        (tmp_path / name).mkdir()
    host_cfg = tmp_path / "config.json"
    host_cfg.write_text(
        json.dumps(
            {
                "monero": {"wallet_address": "4AAA", "node_password": "rpc-secret"},
                "dashboard": {"auth": {"password": "hunter2hunter2"}},
            }
        )
    )
    monkeypatch.setattr("mining_dashboard.config.config.DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setattr(control_service, "CONTROL_AUDIT_DIR", str(tmp_path / "audit"))
    monkeypatch.setattr(control_service, "HOST_CONFIG_PATH", str(host_cfg))
    monkeypatch.setattr(control_service, "HOST_REFERENCE_PATH", str(tmp_path / "absent.json"))
    # Don't sit out the full runner-wait in tests; the 202 path is what's under test.
    monkeypatch.setattr(server_module, "CONTROL_RESULT_TIMEOUT_S", 0.2)
    monkeypatch.setattr(server_module, "CONTROL_RESULT_POLL_S", 0.05)
    return tmp_path


@pytest.fixture
async def control_client(aiohttp_client, app_data, control_dirs):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, app_data))
    yield cli
    sm.close()


class TestControlRoutesEnabled:
    async def test_get_config_masks_secrets(self, control_client):
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["dashboard"]["auth"]["password"] == {"__secret__": True}
        assert "hunter2hunter2" not in json.dumps(body)
        assert "rpc-secret" not in json.dumps(body)

    async def test_post_without_csrf_header_is_403(self, control_client):
        # A custom-header check: cross-site requests can't add it without a CORS preflight,
        # which is never granted — and same-site posts without it are refused too.
        for path in ("/api/control/preview", "/api/control/commit"):
            resp = await control_client.post(path, json={})
            assert resp.status == 403, path

    async def test_preview_stages_intent_and_answers_202(self, control_client, control_dirs):
        # No runner in this tier, so the handler times out to 202 + id for client polling —
        # and the staged intent in requests/ carries the merged secret, actor and action.
        resp = await control_client.post(
            "/api/control/preview",
            json={"dashboard": {"auth": {"password": {"__secret__": True}}}},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        rid = (await resp.json())["id"]
        intent = json.loads((control_dirs / "requests" / f"{rid}.json").read_text())
        assert intent["action"] == "preview"
        assert intent["actor"] == "admin"  # Caddy's X-Auth-User is the audit actor
        assert intent["config"]["dashboard"]["auth"]["password"] == "hunter2hunter2"

    async def test_preview_answers_result_when_runner_is_fast(self, control_client, control_dirs):
        # Pre-write the runner's answer for whatever id the handler mints: patch submit's uuid
        # source is overkill — instead poll-write from a task. Simpler: post, get 202, drop the
        # result file, poll the result route like the client would.
        resp = await control_client.post("/api/control/preview", json={}, headers=CONTROL_HEADERS)
        rid = (await resp.json())["id"]
        result = {"id": rid, "status": "previewed", "changes": [], "destructive": False}
        (control_dirs / "results" / f"{rid}.json").write_text(json.dumps(result))
        polled = await control_client.get(f"/api/control/result?id={rid}")
        assert polled.status == 200
        assert (await polled.json())["status"] == "previewed"

    async def test_result_pending_is_202(self, control_client):
        resp = await control_client.get(
            "/api/control/result?id=12345678-1234-1234-1234-123456789abc"
        )
        assert resp.status == 202
        assert (await resp.json())["status"] == "pending"

    async def test_result_traversal_id_reads_nothing(self, control_client):
        resp = await control_client.get("/api/control/result?id=../../etc/passwd")
        assert resp.status == 202  # treated as "no result", never a file read

    async def test_commit_requires_a_previewed_intent(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", json={"intent_id": "nope"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_stages_intent_for_previewed_id(self, control_client, control_dirs):
        prev_id = "12345678-1234-1234-1234-123456789abc"
        (control_dirs / "results" / f"{prev_id}.json").write_text(
            json.dumps({"id": prev_id, "status": "previewed"})
        )
        resp = await control_client.post(
            "/api/control/commit", json={"intent_id": prev_id}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202  # no runner in this tier
        rid = (await resp.json())["id"]
        intent = json.loads((control_dirs / "requests" / f"{rid}.json").read_text())
        assert intent == {"id": rid, "action": "commit", "actor": "admin", "intent_id": prev_id}

    async def test_preview_bad_json_is_400(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", data="not-json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_audit_serves_the_host_written_trail(self, control_client, control_dirs):
        (control_dirs / "audit" / "audit.log").write_text(
            json.dumps({"action": "commit", "status": "applied"}) + "\n"
        )
        resp = await control_client.get("/api/control/audit")
        assert resp.status == 200
        assert (await resp.json()) == [{"action": "commit", "status": "applied"}]

    async def test_get_config_read_failure_is_sanitized_500(self, control_client, monkeypatch):
        monkeypatch.setattr(
            control_service, "HOST_CONFIG_PATH", "/nonexistent/definitely/config.json"
        )
        resp = await control_client.get("/api/config")
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())  # no path leak

    async def test_preview_non_object_body_is_400(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", json=[1, 2], headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_bad_json_is_400(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", data="not-json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_preview_returns_result_the_moment_it_lands(
        self, control_client, control_dirs, monkeypatch
    ):
        # Pin the request id so the runner's answer can be pre-written: the handler's wait loop
        # must return the result (200), not the 202 fallback.
        rid = "12345678-1234-1234-1234-123456789abc"
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: rid)
        (control_dirs / "results" / f"{rid}.json").write_text(
            json.dumps({"id": rid, "status": "previewed", "changes": []})
        )
        resp = await control_client.post("/api/control/preview", json={}, headers=CONTROL_HEADERS)
        assert resp.status == 200
        assert (await resp.json())["status"] == "previewed"

    async def test_spool_write_failure_is_sanitized_500(
        self, control_client, control_dirs, monkeypatch
    ):
        # An unwritable requests/ mount must surface as a sanitized 500 on both POST routes.
        monkeypatch.setattr(control_service, "CONTROL_REQUESTS_DIR", "/nonexistent/spool")
        resp = await control_client.post("/api/control/preview", json={}, headers=CONTROL_HEADERS)
        assert resp.status == 500
        prev_id = "12345678-1234-1234-1234-123456789abc"
        (control_dirs / "results" / f"{prev_id}.json").write_text(
            json.dumps({"id": prev_id, "status": "previewed"})
        )
        resp = await control_client.post(
            "/api/control/commit", json={"intent_id": prev_id}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())
