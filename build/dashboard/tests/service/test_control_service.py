"""Unit tests for the dashboard side of the #33 control channel (control_service.py).

These prove the two security-load-bearing behaviours the dashboard is responsible for: it never
hands a raw secret to the browser (masking), and a masked secret round-trips back to its real value
unchanged (so editing a non-secret field can't wipe the wallet password). Plus the atomic intent
write and the read-only result/audit reads.
"""

import json

import pytest

from mining_dashboard.service.control_service import SECRET_SENTINEL, ControlService

CONFIG = {
    "monero": {
        "wallet_address": "4WALLET",
        "node_username": "rpcuser",
        "node_password": "rpcpass",
    },
    "p2pool": {"pool": "main", "stratum_password": "s3cr3t"},
    "dashboard": {"auth": {"username": "admin", "password": "hunter2hunter2"}},
    "telegram": {"bot_token": "BOTSECRET", "chat_id": "-100"},
    "workers": {"api_token": "", "api_port": 8080},
}


@pytest.fixture
def svc(tmp_path):
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps(CONFIG))
    reqs = tmp_path / "requests"
    results = tmp_path / "results"
    audit = tmp_path / "audit" / "control.log"
    reqs.mkdir()
    results.mkdir()
    audit.parent.mkdir()
    return ControlService(str(cfg), str(reqs), str(results), str(audit))


class TestSecretMasking:
    def test_set_secrets_masked_out(self, svc):
        masked = svc.read_config()
        assert masked["monero"]["node_password"] == SECRET_SENTINEL
        assert masked["p2pool"]["stratum_password"] == SECRET_SENTINEL
        assert masked["dashboard"]["auth"]["password"] == SECRET_SENTINEL
        assert masked["telegram"]["bot_token"] == SECRET_SENTINEL
        # A real secret value must NEVER appear in what the browser receives.
        blob = json.dumps(masked)
        for leaked in ("rpcpass", "s3cr3t", "hunter2hunter2", "BOTSECRET"):
            assert leaked not in blob

    def test_empty_secret_not_masked(self, svc):
        # An unset (empty) secret stays "" so the form shows it as blank, not "set — keep".
        masked = svc.read_config()
        assert masked["workers"]["api_token"] == ""

    def test_nonsecret_values_pass_through(self, svc):
        masked = svc.read_config()
        assert masked["p2pool"]["pool"] == "main"
        assert masked["monero"]["wallet_address"] == "4WALLET"

    def test_sentinel_round_trips_to_original(self, svc):
        # The core guarantee: edit the pool, leave the password as the sentinel — merge_secrets must
        # restore the ORIGINAL secret so the commit doesn't silently clear it.
        proposed = svc.read_config()
        proposed["p2pool"]["pool"] = "mini"
        merged = svc.merge_secrets(proposed)
        assert merged["p2pool"]["pool"] == "mini"
        assert merged["monero"]["node_password"] == "rpcpass"
        assert merged["dashboard"]["auth"]["password"] == "hunter2hunter2"
        assert merged["telegram"]["bot_token"] == "BOTSECRET"

    def test_new_secret_value_is_kept(self, svc):
        # A real string coming back (operator typed a new password) is a genuine change, kept as-is.
        proposed = svc.read_config()
        proposed["dashboard"]["auth"]["password"] = "a-brand-new-passphrase"
        merged = svc.merge_secrets(proposed)
        assert merged["dashboard"]["auth"]["password"] == "a-brand-new-passphrase"


class TestSubmit:
    def test_submit_writes_atomic_intent(self, svc, tmp_path):
        rid = svc.submit("preview", {"p2pool": {"pool": "mini"}}, "admin")
        path = tmp_path / "requests" / (rid + ".json")
        assert path.exists()
        # No half-written temp file left behind.
        assert not (tmp_path / "requests" / (rid + ".json.tmp")).exists()
        intent = json.loads(path.read_text())
        assert intent["id"] == rid
        assert intent["action"] == "preview"
        assert intent["actor"] == "admin"
        assert intent["config"] == {"p2pool": {"pool": "mini"}}
        assert "intent_id" not in intent

    def test_submit_commit_carries_intent_id(self, svc, tmp_path):
        rid = svc.submit("commit", {}, "admin", intent_id="the-preview-id")
        intent = json.loads((tmp_path / "requests" / (rid + ".json")).read_text())
        assert intent["intent_id"] == "the-preview-id"

    def test_submit_blank_actor_defaults(self, svc, tmp_path):
        rid = svc.submit("preview", {}, "")
        intent = json.loads((tmp_path / "requests" / (rid + ".json")).read_text())
        assert intent["actor"] == "unknown"


class TestReads:
    def test_result_missing_is_none(self, svc):
        assert svc.result("00000000-0000-4000-8000-000000000000") is None

    def test_result_rejects_bad_id(self, svc, tmp_path):
        # A non-uuid id must never be turned into a path (defence against traversal via the id).
        assert svc.result("../etc/passwd") is None

    def test_result_reads_written_file(self, svc, tmp_path):
        rid = "11111111-2222-4333-8444-555555555555"
        (tmp_path / "results" / (rid + ".json")).write_text(json.dumps({"status": "applied"}))
        assert svc.result(rid) == {"status": "applied"}

    def test_read_audit_tail(self, svc, tmp_path):
        log = tmp_path / "audit" / "control.log"
        log.write_text(
            "\n".join(json.dumps({"id": str(i), "outcome": "applied"}) for i in range(5)) + "\n"
        )
        rows = svc.read_audit(limit=2)
        assert [r["id"] for r in rows] == ["3", "4"]

    def test_read_audit_missing_log(self, svc):
        assert svc.read_audit() == []

    def test_read_audit_skips_garbage_lines(self, svc, tmp_path):
        (tmp_path / "audit" / "control.log").write_text('not json\n{"id":"1"}\n\n')
        rows = svc.read_audit()
        assert rows == [{"id": "1"}]
