import asyncio
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
        assert (await client.post("/api/control/upgrade", json={})).status == 404
        assert (await client.get("/api/control/result?id=x")).status == 404
        assert (await client.post("/api/control/backup")).status == 404
        assert (await client.get("/api/control/backup-download?id=x")).status == 404
        assert (await client.post("/api/control/os-update", json={})).status == 404
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

    async def test_get_config_carries_core_keys_from_the_shared_file(
        self, control_client, control_spool, monkeypatch
    ):
        # #529: the Configuration view's core group reads the SAME config.core-keys.json file the
        # wizard reads (config.HOST_CORE_KEYS_PATH), not a hand-maintained duplicate.
        core_keys_path = control_spool / "config.core-keys.json"
        core_keys_path.write_text(json.dumps(["p2pool.pool", "dashboard.auth.username"]))
        monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(core_keys_path))
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["_core_keys"] == ["p2pool.pool", "dashboard.auth.username"]

    async def test_get_config_degrades_to_no_core_keys_when_file_is_missing(self, control_client):
        # control_spool doesn't write config.core-keys.json, so HOST_CORE_KEYS_PATH points nowhere.
        resp = await control_client.get("/api/config")
        assert resp.status == 200
        body = await resp.json()
        assert body["_core_keys"] == []

    async def test_post_without_control_header_forbidden(self, control_client):
        # The custom header forces a CORS preflight cross-site, which is never granted (CSRF).
        for path in (
            "/api/control/preview",
            "/api/control/commit",
            "/api/control/upgrade",
            "/api/control/backup",
        ):
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
        # The spooled request keeps the sentinel (#440): the container never merges live secrets
        # back in — the HOST swaps sentinels for live values when it stages the intent, so the
        # container-readable requests/ spool stays secret-free.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "preview"
        assert req["config"]["dashboard"]["auth"]["password"] == {"__secret__": True}
        assert "correct horse" not in json.dumps(req)

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

    async def test_upgrade_submits_typed_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # 202 straight away: the upgrade recreates this container, so the outcome is polled.
        resp = await control_client.post(
            "/api/control/upgrade",
            json={"version": "v9.9.9"},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no config leg, no free-form target for the runner.
        assert req == {
            "id": body["id"],
            "action": "upgrade",
            "actor": "admin",
            "version": "v9.9.9",
        }

    @pytest.mark.parametrize(
        "version",
        ["", "9.9.9", "latest", "v9.9", "v9.9.9; rm -rf /", "v9.9.9\n", 42, None],
    )
    async def test_upgrade_rejects_malformed_version(self, control_client, control_spool, version):
        # Shape-checked before anything touches the spool (the host re-validates regardless).
        resp = await control_client.post(
            "/api/control/upgrade", json={"version": version}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    async def test_upgrade_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/upgrade", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

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
        # A broken spool (unwritable requests dir) must come back as a sanitized 500, never a
        # traceback.
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/preview", json={"config": {"p2pool": {}}}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_upgrade_spool_failure_is_sanitized(self, control_client, monkeypatch):
        # A broken spool (unwritable requests dir) must come back as a sanitized 500.
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/upgrade", json={"version": "v9.9.9"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_os_update_submits_typed_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # 202 straight away: downloads/installs run long and a reboot takes the machine away —
        # the outcome is polled. The action becomes the os-* verb the host runner dispatches on.
        resp = await control_client.post(
            "/api/control/os-update",
            json={"action": "download", "version": "v9.9.9"},
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no free-form target or path for the runner.
        assert req == {
            "id": body["id"],
            "action": "os-download",
            "actor": "admin",
            "version": "v9.9.9",
        }

    async def test_os_update_actionless_steps_carry_no_version(self, control_client, control_spool):
        resp = await control_client.post(
            "/api/control/os-update", json={"action": "check"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 202
        body = await resp.json()
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        assert req == {"id": body["id"], "action": "os-check", "actor": ""}

    @pytest.mark.parametrize("action", ["", "format-disk", "os-check", "reboot; rm", 42, None])
    async def test_os_update_rejects_unknown_action(self, control_client, control_spool, action):
        # A closed action set, checked before anything touches the spool.
        resp = await control_client.post(
            "/api/control/os-update", json={"action": action}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    @pytest.mark.parametrize("version", ["9.9.9", "latest", "v9.9.9\n", 42])
    async def test_os_update_rejects_malformed_version(
        self, control_client, control_spool, version
    ):
        resp = await control_client.post(
            "/api/control/os-update",
            json={"action": "download", "version": version},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 400
        assert list((control_spool / "requests").iterdir()) == []

    async def test_os_update_requires_the_control_header(self, control_client):
        resp = await control_client.post("/api/control/os-update", json={"action": "check"})
        assert resp.status == 403

    async def test_os_update_rejects_non_json_body(self, control_client):
        resp = await control_client.post(
            "/api/control/os-update", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_os_update_spool_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post(
            "/api/control/os-update", json={"action": "check"}, headers=CONTROL_HEADERS
        )
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_backup_submits_bare_intent_and_returns_pending(
        self, control_client, control_spool
    ):
        # No body, unlike commit/upgrade: the host picks its own passphrase, never the container's.
        resp = await control_client.post(
            "/api/control/backup", headers={**CONTROL_HEADERS, "X-Auth-User": "admin"}
        )
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending"
        req = json.loads((control_spool / "requests" / f"{body['id']}.json").read_text())
        # Closed shape: exactly these keys — no config leg, no passphrase field to smuggle one in.
        assert req == {"id": body["id"], "action": "backup", "actor": "admin"}

    async def test_backup_spool_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", "/nonexistent/requests")
        resp = await control_client.post("/api/control/backup", headers=CONTROL_HEADERS)
        assert resp.status == 500
        assert "nonexistent" not in json.dumps(await resp.json())

    async def test_backup_download_rejects_bad_id(self, control_client):
        resp = await control_client.get("/api/control/backup-download?id=..%2Fx")
        assert resp.status == 400

    async def test_backup_download_404_without_a_result(self, control_client):
        resp = await control_client.get(f"/api/control/backup-download?id={uuid.uuid4()}")
        assert resp.status == 404

    async def test_backup_download_404_when_not_applied(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "failed", "error": "boom"})
        )
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 404

    async def test_backup_download_404_when_archive_missing_on_disk(
        self, control_client, control_spool
    ):
        # The result names an archive but the file itself is gone — 404, not a 500/traceback.
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "applied", "archive": "pithead-backup-x.tar.gz.enc"})
        )
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 404

    async def test_backup_download_streams_the_archive(self, control_client, control_spool):
        rid = str(uuid.uuid4())
        (control_spool / "results" / f"{rid}.json").write_text(
            json.dumps(
                {
                    "status": "applied",
                    "archive": "pithead-backup-20260101-000000.tar.gz.enc",
                    "passphrase": None,  # already redacted; the download must not depend on it
                }
            )
        )
        (control_spool / "results" / f"{rid}.tar.gz.enc").write_bytes(b"ENCRYPTED-ARCHIVE-BYTES")
        resp = await control_client.get(f"/api/control/backup-download?id={rid}")
        assert resp.status == 200
        assert await resp.read() == b"ENCRYPTED-ARCHIVE-BYTES"
        assert (
            'filename="pithead-backup-20260101-000000.tar.gz.enc"'
            in resp.headers["Content-Disposition"]
        )

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

    async def test_access_route_navigation_params_filter_entries(
        self, client, tmp_path, monkeypatch
    ):
        # #823: from/to (epoch seconds, half-open) and q narrow the served entries; the failure
        # counters keep describing the whole tail; malformed bounds read as absent, never a 500.
        log = tmp_path / "access.log"
        rows = [
            {
                "ts": 100.0,
                "status": 200,
                "user_id": "admin",
                "request": {"method": "GET", "uri": "/api/state"},
            },
            {
                "ts": 200.0,
                "status": 401,
                "user_id": "guess",
                "request": {"method": "GET", "uri": "/login"},
            },
        ]
        log.write_text("".join(json.dumps(r) + "\n" for r in rows))
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(log))
        body = await (await client.get("/api/access?from=150")).json()
        assert [e["ts"] for e in body["entries"]] == [200.0]
        body = await (await client.get("/api/access?q=api/state")).json()
        assert [e["ts"] for e in body["entries"]] == [100.0]
        # to is exclusive; and the 401 counter is window-independent (whole-tail semantics).
        body = await (await client.get("/api/access?from=100&to=200")).json()
        assert [e["ts"] for e in body["entries"]] == [100.0]
        assert "failures_24h" in body
        # Malformed bounds degrade to unfiltered, HTTP 200 — including the float()-parseable
        # non-finite spellings, which would otherwise warp the comparisons (nan is never <).
        for bad in ("notanumber", "inf", "-inf", "nan", ""):
            resp = await client.get(f"/api/access?from={bad}&to={bad}&q=")
            assert resp.status == 200
            assert len((await resp.json())["entries"]) == 2

    async def test_audit_route_navigation_params_filter_entries(
        self, control_client, tmp_path, monkeypatch
    ):
        # #823 on the audit side: ISO timestamps land on the same epoch axis, and q searches
        # the sanitized fields.
        log = tmp_path / "control.log"
        rows = [
            {
                "ts": "2026-07-10T12:00:00Z",
                "id": "11111111-1111-4111-8111-111111111111",
                "actor": "admin",
                "action": "commit",
                "status": "applied",
                "keys": "XVB_ENABLED",
            },
            {
                "ts": "2026-07-20T12:00:00Z",
                "id": "22222222-2222-4222-8222-222222222222",
                "actor": "release-smoke",
                "action": "upgrade",
                "status": "upgraded",
                "keys": "",
            },
        ]
        log.write_text("".join(json.dumps(r) + "\n" for r in rows))
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        cutoff = audit_service._entry_epoch("2026-07-15T00:00:00Z")
        body = await (await control_client.get(f"/api/audit?from={cutoff}")).json()
        assert [e["actor"] for e in body["entries"]] == ["release-smoke"]
        body = await (await control_client.get("/api/audit?q=xvb_enabled")).json()
        assert [e["actor"] for e in body["entries"]] == ["admin"]

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

    async def test_audit_route_merges_db_only_entries(self, control_client, monkeypatch):
        # #530: an out-of-band host-edit/rig-edit row lives only in audit_events, never in
        # control.log — it must still appear in the served feed.
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", "/nonexistent/control.log")
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="hostedit-1",
            ts="2026-07-20T12:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="xvb.enabled",
        )
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["source"] == "host-edit"
        assert entries[0]["keys"] == "xvb.enabled"

    async def test_audit_route_shows_a_fresh_commit_before_it_is_mirrored(
        self, control_client, tmp_path, monkeypatch
    ):
        # A commit that just landed in control.log, before the next poll cycle mirrors it to the
        # DB, must still show up immediately — no regression from #530's DB merge.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "11111111-1111-4111-8111-111111111111",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["keys"] == "XVB_ENABLED"

    async def test_audit_route_deduplicates_a_mirrored_row(
        self, control_client, tmp_path, monkeypatch
    ):
        # The same control.log row, present both live (log tail) and mirrored (DB) — one row out,
        # not two.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "22222222-2222-4222-8222-222222222222",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="22222222-2222-4222-8222-222222222222",
            ts="2026-07-20T12:00:00Z",
            source="control",
            actor="admin",
            action="commit",
            status="applied",
            keys="XVB_ENABLED",
        )
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1

    async def test_audit_route_sorts_newest_first_across_sources(
        self, control_client, tmp_path, monkeypatch
    ):
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-01T00:00:00Z",
                    "id": "33333333-3333-4333-8333-333333333333",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="hostedit-2",
            ts="2026-07-20T00:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="xvb.enabled",
        )
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert [e["id"] for e in entries] == ["hostedit-2", "33333333-3333-4333-8333-333333333333"]

    async def test_audit_route_shows_a_no_id_log_row_live(
        self, control_client, tmp_path, monkeypatch
    ):
        # A pre-auth "invalid"/"refused" control.log row (#33) has no id — never mirrored to the
        # DB, but still shown live from the log tail.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "",
                    "actor": "",
                    "action": "invalid",
                    "status": "refused-oversize",
                    "keys": "",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["status"] == "refused-oversize"


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


@pytest.fixture
async def worker_client(aiohttp_client, control_spool, monkeypatch):
    """Control channel on, one editable worker descriptor, and a worker in the live snapshot.

    Exposes the StateManager so tests can read back the config history the route records."""
    from mining_dashboard.config import config as cfg_mod
    from mining_dashboard.web import views

    monkeypatch.setattr(
        cfg_mod, "DASHBOARD_WORKERS", [{"name": "rig1", "host": "10.0.0.9", "control_port": 8082}]
    )
    data = {
        "workers": [
            {
                "name": "rig1",
                "ip": "10.0.0.9",
                "status": "online",
                "active_pool": "3333",
                "h60": 5100,
                # Bare rig-reported version (#596/#597) — the upgrade noop guard compares it
                # (parsed) against the v-prefixed proposal.
                "rigforge": {"version": "1.11.0"},
            }
        ]
    }
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, data))
    cli.sm = sm  # for history assertions
    assert views.config is cfg_mod  # both modules share the one config object
    yield cli
    sm.close()


class TestWorkerInspect:
    async def test_worker_detail_reports_editable_and_telemetry(self, worker_client):
        resp = await worker_client.get("/api/worker?name=rig1")
        assert resp.status == 200
        body = await resp.json()
        assert body["found"] is True
        assert body["editable"] is True  # has an operator-set host
        assert body["status"] == "online"
        assert "DONATION" in body["writable_keys"]
        assert body["history"] == []

    async def test_worker_detail_requires_name(self, worker_client):
        assert (await worker_client.get("/api/worker")).status == 400

    async def test_worker_apply_requires_control_header(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-apply", json={"worker": "rig1", "changes": {"DONATION": 2}}
        )
        assert resp.status == 403  # CSRF guard

    async def test_worker_apply_rejects_non_writable_keys(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": {"ACCESS_TOKEN": "x"}},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 400  # not in the writable allowlist

    async def test_worker_apply_spools_tokenless_intent_and_records_history(
        self, worker_client, control_spool, monkeypatch
    ):
        # Pin the id and pre-write the host runner's terminal result so wait_result returns at once.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        result = {
            "status": "applied",
            "change_id": "deadbeefcafef00d",
            "worker": "rig1",
            "changed_keys": ["DONATION"],
            "reason": None,
        }
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))

        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": {"DONATION": 3}},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 200
        body = await resp.json()
        assert body["status"] == "applied" and body["change_id"] == "deadbeefcafef00d"

        # The spooled intent carries ONLY the worker name + changes — never a host, port, or token.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "worker-apply"
        assert req["worker"] == "rig1" and req["changes"] == {"DONATION": 3}
        assert "host" not in req and "port" not in req and "token" not in req

        # The outcome is recorded in the per-worker config history.
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "applied"
        assert history[0]["changes"] == {"DONATION": 3}
        assert worker_client.sm.get_last_applied_worker_config("rig1") == {"DONATION": 3}

    async def test_worker_routes_absent_when_control_disabled(self, client):
        assert (await client.get("/api/worker?name=rig1")).status == 404
        assert (
            await client.post("/api/control/worker-apply", json={}, headers=CONTROL_HEADERS)
        ).status == 404


class TestWorkerUpgrade:
    """The one-click rig upgrade route (#597): spool-only, name + confirmed version, no waiting."""

    async def test_requires_control_header(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-upgrade", json={"worker": "rig1", "version": "v1.11.2"}
        )
        assert resp.status == 403  # CSRF guard

    async def test_malformed_worker_or_version_rejected(self, worker_client):
        for body in (
            {"version": "v1.11.2"},  # missing worker
            {"worker": "", "version": "v1.11.2"},  # empty worker
            {"worker": "rig1"},  # missing version
            {"worker": "rig1", "version": "1.11.2"},  # bare — the intent carries the tag form
            {"worker": "rig1", "version": "v1.11.2;rm"},  # junk after the tag
        ):
            resp = await worker_client.post(
                "/api/control/worker-upgrade", json=body, headers=CONTROL_HEADERS
            )
            assert resp.status == 400, body

    async def test_spools_name_and_version_only_and_returns_202(
        self, worker_client, control_spool, monkeypatch
    ):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        # Always 202 — a rig build can run minutes, so the client polls /api/control/result.
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending" and body["id"] == rid
        # The intent carries ONLY the worker name + proposed version — never host/port/token.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "worker-upgrade"
        assert req["worker"] == "rig1" and req["version"] == "v1.11.2"
        assert "host" not in req and "port" not in req and "token" not in req
        assert "changes" not in req

    async def test_non_json_body_is_a_400(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-upgrade", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert "must be JSON" in await resp.text()

    async def test_submit_failure_is_a_500_without_detail(self, worker_client, monkeypatch):
        def boom(*a, **k):
            raise OSError("spool dir gone")

        monkeypatch.setattr(control_service, "submit_worker_upgrade", boom)
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 500
        # The body carries a generic message, never the exception text.
        assert "spool dir gone" not in await resp.text()

    async def test_noop_when_rig_already_reports_the_version(self, worker_client, control_spool):
        # The fixture rig reports bare "1.11.0"; proposing tag v1.11.0 must short-circuit —
        # no spool, no host dial, no burn of the rig's own 6h upgrade throttle.
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.0"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 200
        assert (await resp.json())["status"] == "noop"
        assert list((control_spool / "requests").glob("*.json")) == []
        # Nothing was ever asked of a rig — a local version comparison, not an upgrade attempt —
        # so it gets no history row (#1014 is about recording real attempts, not every click).
        assert worker_client.sm.get_worker_config_history("rig1") == []

    async def test_route_absent_when_control_disabled(self, client):
        resp = await client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 404


class TestWorkerUpgradeRecordsHistory:
    """#1014: a one-click rig upgrade is 202-then-poll (a rebuild can run minutes), so the
    terminal outcome is recorded by a background task, not inline like worker-apply's. These pin
    that task down directly (`await asyncio.gather(*app["_bg_tasks"])`) rather than sleeping."""

    async def _upgrade(self, worker_client, control_spool, monkeypatch, result):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])
        return rid

    async def test_applied_upgrade_recorded_as_its_own_type(
        self, worker_client, control_spool, monkeypatch
    ):
        result = {
            "status": "applied",
            "change_id": "deadbeef",
            "worker": "rig1",
            "version": "v1.11.2",
            "reason": None,
        }
        await self._upgrade(worker_client, control_spool, monkeypatch, result)
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "applied"
        assert history[0]["type"] == "upgrade"
        assert history[0]["changes"] == {"version": "v1.11.2"}
        assert history[0]["change_id"] == "deadbeef"
        # An applied upgrade must never leak into the config-editor prefill (#1014's own guard).
        assert worker_client.sm.get_last_applied_worker_config("rig1") == {}

    async def test_noop_and_throttled_terminals_from_a_real_dial_are_recorded(
        self, worker_client, control_spool, monkeypatch
    ):
        # Distinct from the synchronous short-circuit noop above: this is the RIG's own /status
        # terminal for a dial that actually happened (rigforge#320's first-class noop/throttled).
        for status in ("noop", "throttled"):
            result = {
                "status": status,
                "change_id": f"cid-{status}",
                "worker": "rig1",
                "version": "v1.11.2",
                "reason": "already current" if status == "noop" else "throttled: retry later",
            }
            await self._upgrade(worker_client, control_spool, monkeypatch, result)
        statuses = {h["status"] for h in worker_client.sm.get_worker_config_history("rig1")}
        assert statuses == {"noop", "throttled"}

    async def test_pre_dial_rejection_recorded_with_the_requesters_worker_name(
        self, worker_client, control_spool, monkeypatch
    ):
        # The host runner's pre-dial _wu_reject writes NO 'worker' key at all — the row must still
        # land under the right worker, from the request itself, not from the result body.
        result = {"status": "rejected", "error": "worker has no configured host", "ts": 1.0}
        await self._upgrade(worker_client, control_spool, monkeypatch, result)
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "rejected"
        assert history[0]["type"] == "upgrade"
        assert history[0]["reason"] == "worker has no configured host"
        assert history[0]["changes"] == {"version": "v1.11.2"}  # the operator-proposed target

    async def test_runner_never_answering_records_nothing(
        self, worker_client, control_spool, monkeypatch
    ):
        monkeypatch.setattr(control_service.config, "CONTROL_WORKER_UPGRADE_WAIT_S", 0.05)
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])
        assert worker_client.sm.get_worker_config_history("rig1") == []

    async def test_wait_result_error_is_swallowed_not_raised(
        self, worker_client, control_spool, monkeypatch
    ):
        # A crash while polling for the terminal result (e.g. a spool read error) must not blow up
        # the background task or take the app down with it — logged and dropped, like every other
        # exception boundary in this module.
        async def boom(*a, **k):
            raise OSError("spool read failed")

        monkeypatch.setattr(control_service, "wait_result", boom)
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])  # must not raise
        assert worker_client.sm.get_worker_config_history("rig1") == []


class TestWorkerApplyEdgeCases:
    async def test_apply_bad_body_and_missing_worker(self, worker_client):
        # Non-JSON body → 400.
        resp = await worker_client.post(
            "/api/control/worker-apply", data="not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        # Missing / empty worker name → 400.
        resp = await worker_client.post(
            "/api/control/worker-apply", json={"changes": {"DONATION": 1}}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_apply_pending_when_runner_silent(
        self, worker_client, control_spool, monkeypatch
    ):
        # No result file is written, so wait_result times out → 202 pending, nothing recorded.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.05)
        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": {"DONATION": 1}},
            headers={**CONTROL_HEADERS},
        )
        assert resp.status == 202
        assert (await resp.json())["status"] == "pending"
        assert worker_client.sm.get_worker_config_history("rig1") == []  # no terminal outcome yet


class TestXvbStandbyApi:
    """The read-only endpoint a backup stack pulls to warm its donation split (#249)."""

    async def test_get_xvb_standby_ok_json(self, client):
        resp = await client.get("/api/xvb-standby")
        assert resp.status == 200
        assert resp.content_type == "application/json"
        body = await resp.json()
        for key in ("commanded_fraction", "avg_1h", "avg_24h", "mode", "donation_level", "ts"):
            assert key in body

    async def test_error_is_sanitized_500(self, aiohttp_client, app_data):
        sm = MagicMock()
        sm.get_xvb_stats.side_effect = RuntimeError("boom")
        cli = await aiohttp_client(create_app(sm, app_data))
        resp = await cli.get("/api/xvb-standby")
        assert resp.status == 500
        body = await resp.json()
        assert body == {"error": "Failed to build XvB standby state."}  # no internals leaked

    async def test_reflects_controller_state(self, aiohttp_client, app_data):
        sm = StateManager(db_path=":memory:")
        sm.update_xvb_stats(mode="XVB", avg_1h=1500.0, commanded_fraction=0.37)
        cli = await aiohttp_client(create_app(sm, app_data))
        try:
            body = await (await cli.get("/api/xvb-standby")).json()
            assert body["commanded_fraction"] == 0.37
            assert body["avg_1h"] == 1500.0
            assert body["mode"] == "XVB"
        finally:
            sm.close()
