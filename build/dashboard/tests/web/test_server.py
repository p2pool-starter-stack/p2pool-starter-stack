import json
import uuid
from unittest.mock import MagicMock

import pytest

from mining_dashboard.service import audit_service, control_service
from mining_dashboard.service.storage_service import StateManager
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


class TestControlRoutesDisabled:
    """With dashboard.control.enabled off (the default) the control routes must not exist at
    all — 404, not 403, so a disabled stack gives no hint the endpoints are there (#33)."""

    async def test_control_routes_absent_when_disabled(self, client):
        assert (await client.get("/api/config")).status == 404
        assert (await client.post("/api/control/preview", json={})).status == 404
        assert (await client.post("/api/control/commit", json={})).status == 404
        assert (await client.get("/api/control/result?id=x")).status == 404
        # The config-change audit view is a control-channel artifact — absent with it (#349).
        assert (await client.get("/api/audit")).status == 404


@pytest.fixture
def control_spool(tmp_path, monkeypatch):
    """Enable the control channel and point the service at throwaway spool dirs."""
    host_config = tmp_path / "config.json"
    host_config.write_text(
        json.dumps(
            {
                "p2pool": {"pool": "mini"},
                "dashboard": {"auth": {"username": "admin", "password": "correct horse"}},
                "healthchecks": {"ping_url": "https://hc-ping.com/SECRET-UUID"},
            }
        )
    )
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_config))
    monkeypatch.setattr(
        control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "no-reference.json")
    )
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.1)
    return tmp_path


@pytest.fixture
async def control_client(aiohttp_client, app_data, control_spool):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, app_data))
    yield cli
    sm.close()


CONTROL_HEADERS = {"X-Pithead-Control": "1"}


class TestControlRoutesEnabled:
    async def test_get_config_masks_secrets(self, control_client):
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["dashboard"]["auth"]["password"] == {"__secret__": True}
        # healthchecks.ping_url is a capability secret — masked at the route, never served raw (#33).
        assert body["healthchecks"]["ping_url"] == {"__secret__": True}
        assert "correct horse" not in json.dumps(body)
        assert "SECRET-UUID" not in json.dumps(body)

    async def test_post_without_control_header_forbidden(self, control_client):
        # The custom header forces a CORS preflight cross-site, which is never granted (CSRF).
        for path in ("/api/control/preview", "/api/control/commit"):
            resp = await control_client.post(path, json={"config": {}})
            assert resp.status == 403, path

    async def test_preview_submits_request_and_returns_result(
        self, control_client, control_spool, monkeypatch
    ):
        # Pin the request id and pre-write the runner's answer, so wait_result returns at once.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        result = {"status": "previewed", "changes": [], "destructive": False}
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))

        proposed = {
            "p2pool": {"pool": "main"},
            "dashboard": {"auth": {"password": {"__secret__": True}}},
        }
        resp = await control_client.post(
            "/api/control/preview", json={"config": proposed}, headers=CONTROL_HEADERS
        )
        assert resp.status == 200
        body = await resp.json()
        assert body["id"] == rid
        assert body["status"] == "previewed"
        # The spooled request carries the merged config: the sentinel became the live secret.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "preview"
        assert req["config"]["dashboard"]["auth"]["password"] == "correct horse"

    async def test_preview_actor_taken_from_caddy_header(self, control_client, control_spool):
        resp = await control_client.post(
            "/api/control/preview",
            json={"config": {"p2pool": {"pool": "nano"}}},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202  # no runner in this test — pending
        rid = (await resp.json())["id"]
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["actor"] == "admin"

    async def test_preview_rejects_non_object_config(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", json={"config": "rm -rf /"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_preview_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/preview", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_requires_valid_intent_id(self, control_client):
        resp = await control_client.post(
            "/api/control/commit", json={"id": "../etc/passwd"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_commit_waits_past_stale_preview_result(self, control_client, control_spool):
        # The preview result under the same id must not be mistaken for the commit outcome:
        # with only the preview result present, commit times out to 202 pending.
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "previewed", "changes": []})
        )
        resp = await control_client.post(
            "/api/control/commit", json={"id": rid}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
        assert (await resp.json())["status"] == "pending"

    async def test_commit_returns_applied_result(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "applied"}))
        resp = await control_client.post(
            "/api/control/commit", json={"id": rid}, headers=CONTROL_HEADERS
        )
        assert resp.status == 200
        assert (await resp.json())["status"] == "applied"

    async def test_result_endpoint_polling(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        resp = await control_client.get(f"/api/control/result?id={rid}")
        assert resp.status == 202
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "failed"}))
        resp = await control_client.get(f"/api/control/result?id={rid}")
        assert resp.status == 200
        assert (await resp.json())["status"] == "failed"

    async def test_result_endpoint_rejects_bad_id(self, control_client):
        assert (await control_client.get("/api/control/result?id=..%2Fx")).status == 400

    async def test_preview_spool_failure_is_sanitized(self, control_client, monkeypatch):
        # A broken spool (here: the host config can't be read for the secret merge) must come
        # back as a sanitized 500, never a traceback.
        monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        resp = await control_client.post(
            "/api/control/preview", json={"config": {"p2pool": {}}}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_config_read_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        resp = await control_client.get("/api/config")
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())


class TestSecurityLogRoutes:
    """/api/access (always on) and /api/audit (with the control channel) — #349. Both are GET-only
    reads over host-written, read-only-mounted files; every served field is sanitized because log
    content is attacker-influenceable (the access log echoes attacker-chosen URIs/usernames)."""

    async def test_access_route_reports_unavailable_without_log(self, client, monkeypatch):
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", "/nonexistent/access.log")
        resp = await client.get("/api/access")
        assert resp.status == 200
        body = await resp.json()
        assert body["available"] is False
        assert body["entries"] == []

    async def test_access_route_serves_sanitized_entries(self, client, tmp_path, monkeypatch):
        log = tmp_path / "access.log"
        log.write_text(
            json.dumps(
                {
                    "ts": 100.0,
                    "status": 401,
                    "user_id": "<script>alert(1)</script>",
                    "request": {"method": "GET", "uri": "/<svg onload=alert(1)>"},
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(log))
        resp = await client.get("/api/access")
        assert resp.status == 200
        text = json.dumps(await resp.json())
        # A hostile log line must arrive inert — no markup survives to the browser.
        assert "<" not in text and ">" not in text
        assert (await client.get("/api/access")).status == 200

    async def test_audit_route_serves_sanitized_entries(
        self, control_client, tmp_path, monkeypatch
    ):
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-10T12:00:00Z",
                    "id": "11111111-1111-4111-8111-111111111111",
                    "actor": "<img src=x onerror=alert(1)>",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        body = await resp.json()
        assert body["entries"][0]["keys"] == "XVB_ENABLED"
        assert "<" not in json.dumps(body) and ">" not in json.dumps(body)

    async def test_audit_route_missing_log_is_empty(self, control_client, monkeypatch):
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", "/nonexistent/control.log")
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        assert (await resp.json())["entries"] == []

    async def test_access_route_failure_is_sanitized(self, client, monkeypatch):
        monkeypatch.setattr(
            audit_service, "access_summary", MagicMock(side_effect=RuntimeError("/host/secret"))
        )
        resp = await client.get("/api/access")
        assert resp.status == 500
        assert "secret" not in json.dumps(await resp.json())

    async def test_audit_route_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(
            audit_service, "recent_changes", MagicMock(side_effect=RuntimeError("/host/secret"))
        )
        resp = await control_client.get("/api/audit")
        assert resp.status == 500
        assert "secret" not in json.dumps(await resp.json())


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
