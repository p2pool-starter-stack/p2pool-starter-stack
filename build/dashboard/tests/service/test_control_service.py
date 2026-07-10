"""Tests for the dashboard side of the config-editor channel (Issue #33).

The service only reads the (masked) host config, writes typed intents into the requests spool,
and polls results — every filesystem path is injected, so these run against tmp_path with no
container mounts.
"""

import json
import os

import pytest

from mining_dashboard.service import control_service
from mining_dashboard.service.control_service import (
    SECRET_SENTINEL,
    merge_secrets,
    read_audit,
    read_config,
    result,
    submit,
)

HOST_CONFIG = {
    "monero": {
        "mode": "local",
        "wallet_address": "4AAAA",
        "node_username": "admin",
        "node_password": "rpc-secret",
        "prune": True,
    },
    "p2pool": {"pool": "mini", "stratum_password": ""},
    "dashboard": {"auth": {"username": "admin", "password": "hunter2hunter2"}},
    "telegram": {"bot_token": "123:abc", "chat_id": "42"},
}


@pytest.fixture
def host_config(tmp_path):
    path = tmp_path / "config.json"
    path.write_text(json.dumps(HOST_CONFIG))
    return str(path)


@pytest.fixture
def reference(tmp_path):
    path = tmp_path / "config.reference.json"
    path.write_text(
        json.dumps(
            {
                "_docs": "reference",
                "monero": {"mode": "local", "prune": True, "rpc_lan_access": False},
                "xvb": {"enabled": True, "donation_level": "auto"},
            }
        )
    )
    return str(path)


class TestReadConfig:
    def test_masks_set_secrets_with_sentinel(self, host_config, reference):
        cfg = read_config(host_config, reference)
        assert cfg["dashboard"]["auth"]["password"] == SECRET_SENTINEL
        assert cfg["telegram"]["bot_token"] == SECRET_SENTINEL
        assert cfg["monero"]["node_password"] == SECRET_SENTINEL
        assert cfg["monero"]["node_username"] == SECRET_SENTINEL

    def test_unset_secret_stays_empty(self, host_config, reference):
        # "" is not masked, so the form can tell "set — leave blank to keep" from "not set".
        cfg = read_config(host_config, reference)
        assert cfg["p2pool"]["stratum_password"] == ""

    def test_no_raw_secret_anywhere_in_payload(self, host_config, reference):
        # The whole point: raw secrets never reach the browser.
        blob = json.dumps(read_config(host_config, reference))
        for secret in ("hunter2hunter2", "rpc-secret", "123:abc"):
            assert secret not in blob

    def test_reference_defaults_merged_under_host_config(self, host_config, reference):
        cfg = read_config(host_config, reference)
        assert cfg["xvb"]["donation_level"] == "auto"  # reference-only key appears
        assert cfg["monero"]["rpc_lan_access"] is False  # nested merge
        assert cfg["p2pool"]["pool"] == "mini"  # host config wins over reference
        assert "_docs" not in cfg

    def test_missing_reference_degrades_to_host_config(self, host_config, tmp_path):
        cfg = read_config(host_config, str(tmp_path / "nope.json"))
        assert cfg["p2pool"]["pool"] == "mini"


class TestMergeSecrets:
    def test_sentinel_means_keep_current_value(self, host_config):
        proposed = json.loads(json.dumps(HOST_CONFIG))
        proposed["dashboard"]["auth"]["password"] = dict(SECRET_SENTINEL)
        proposed["telegram"]["bot_token"] = dict(SECRET_SENTINEL)
        merged = merge_secrets(proposed, host_config)
        assert merged["dashboard"]["auth"]["password"] == "hunter2hunter2"
        assert merged["telegram"]["bot_token"] == "123:abc"

    def test_new_value_and_explicit_clear_pass_through(self, host_config):
        proposed = json.loads(json.dumps(HOST_CONFIG))
        proposed["dashboard"]["auth"]["password"] = "a-brand-new-pass"
        proposed["telegram"]["bot_token"] = ""  # explicit clear
        merged = merge_secrets(proposed, host_config)
        assert merged["dashboard"]["auth"]["password"] == "a-brand-new-pass"
        assert merged["telegram"]["bot_token"] == ""

    def test_sentinel_for_an_unset_secret_collapses_to_empty(self, host_config):
        proposed = json.loads(json.dumps(HOST_CONFIG))
        proposed["p2pool"]["stratum_password"] = dict(SECRET_SENTINEL)
        merged = merge_secrets(proposed, host_config)
        assert merged["p2pool"]["stratum_password"] == ""

    def test_round_trip_read_then_merge_restores_secrets(self, host_config, reference):
        # The full editor loop: masked out, sentinels back in, real values restored.
        masked = read_config(host_config, reference)
        merged = merge_secrets(masked, host_config)
        assert merged["dashboard"]["auth"]["password"] == "hunter2hunter2"
        assert merged["monero"]["node_password"] == "rpc-secret"
        assert "__secret__" not in json.dumps(merged)  # no sentinel survives the merge


class TestSubmit:
    def test_writes_a_typed_intent_named_by_uuid(self, tmp_path):
        rid = submit("preview", config={"a": 1}, actor="admin", requests_dir=str(tmp_path))
        intent = json.loads((tmp_path / f"{rid}.json").read_text())
        assert intent == {"id": rid, "action": "preview", "actor": "admin", "config": {"a": 1}}

    def test_commit_intent_carries_intent_id_not_config(self, tmp_path):
        rid = submit("commit", intent_id="abc", actor="", requests_dir=str(tmp_path))
        intent = json.loads((tmp_path / f"{rid}.json").read_text())
        assert intent == {"id": rid, "action": "commit", "actor": "unknown", "intent_id": "abc"}

    def test_write_is_atomic_no_tmp_left_behind(self, tmp_path):
        rid = submit("preview", config={}, requests_dir=str(tmp_path))
        names = os.listdir(tmp_path)
        # Only the renamed .json remains; the temp name never matched the runner's *.json glob.
        assert names == [f"{rid}.json"]
        assert rid  # a uuid4 string


class TestResult:
    def test_reads_a_result_by_id(self, tmp_path):
        rid = "12345678-1234-1234-1234-123456789abc"
        (tmp_path / f"{rid}.json").write_text(json.dumps({"id": rid, "status": "previewed"}))
        assert result(rid, str(tmp_path))["status"] == "previewed"

    def test_pending_result_is_none(self, tmp_path):
        assert result("12345678-1234-1234-1234-123456789abc", str(tmp_path)) is None

    @pytest.mark.parametrize(
        "bad", ["", "../../../etc/passwd", "x" * 36, "12345678-1234-1234-1234-12345678", None]
    )
    def test_malformed_id_never_touches_the_filesystem(self, tmp_path, bad):
        # The id comes from the browser and becomes a filename — anything but the uuid shape
        # is treated as "no result" without a path lookup.
        assert result(bad, str(tmp_path)) is None


class TestReadAudit:
    def test_returns_last_entries_and_skips_garbage(self, tmp_path):
        log = tmp_path / "audit.log"
        lines = [json.dumps({"n": i}) for i in range(5)] + ["not-json"]
        log.write_text("\n".join(lines) + "\n")
        entries = read_audit(limit=3, audit_dir=str(tmp_path))
        assert entries == [{"n": 3}, {"n": 4}]  # garbage skipped, newest kept

    def test_no_trail_yet_is_empty(self, tmp_path):
        assert read_audit(audit_dir=str(tmp_path)) == []


class TestDefaultPaths:
    def test_module_defaults_point_at_the_container_mounts(self):
        # The compose file pins these container paths; the env overrides exist for tests only.
        assert control_service.CONTROL_REQUESTS_DIR == "/control/requests"
        assert control_service.CONTROL_RESULTS_DIR == "/control/results"
        assert control_service.CONTROL_AUDIT_DIR == "/control/audit"
        assert control_service.HOST_CONFIG_PATH == "/host-config/config.json"
