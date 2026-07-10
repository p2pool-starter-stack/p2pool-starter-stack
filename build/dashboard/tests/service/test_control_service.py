"""Unit tests for the dashboard side of the control channel (#33): secret masking round-trip,
atomic request submission, result reads, and the UUID gate on ids that become host filenames."""

import json
import os
import uuid

import pytest

from mining_dashboard.service import control_service

CONFIG = {
    "monero": {
        "mode": "local",
        "wallet_address": "4AAAA",
        "node_username": "admin",
        "node_password": "hunter2",
        "prune": True,
    },
    "p2pool": {"pool": "mini", "stratum_password": ""},
    "dashboard": {"auth": {"username": "admin", "password": "correct horse"}},
    "telegram": {"bot_token": "123:abc"},
    "workers": {"api_token": ""},
    "healthchecks": {"ping_url": "https://hc-ping.com/SECRET-UUID"},
}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    """Point the service at throwaway host-config + spool dirs."""
    host_config = tmp_path / "config.json"
    host_config.write_text(json.dumps(CONFIG))
    requests_dir = tmp_path / "requests"
    results_dir = tmp_path / "results"
    requests_dir.mkdir()
    results_dir.mkdir()
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_config))
    # Hermetic default: no reference file, so read_config degrades to the host config alone unless a
    # test opts in by writing one and repointing HOST_REFERENCE_PATH.
    monkeypatch.setattr(
        control_service.config, "HOST_REFERENCE_PATH", str(tmp_path / "no-reference.json")
    )
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(requests_dir))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(results_dir))
    monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.1)
    return tmp_path


class TestSecretMasking:
    def test_set_secrets_masked_to_sentinel(self, spool):
        cfg = control_service.read_config()
        assert cfg["dashboard"]["auth"]["password"] == {"__secret__": True}
        assert cfg["telegram"]["bot_token"] == {"__secret__": True}
        assert cfg["monero"]["node_password"] == {"__secret__": True}
        # healthchecks.ping_url is a capability secret (#33 hardening): masked, never served raw.
        assert cfg["healthchecks"]["ping_url"] == {"__secret__": True}
        # No raw secret value anywhere in the served payload.
        assert "hunter2" not in json.dumps(cfg)
        assert "correct horse" not in json.dumps(cfg)
        assert "SECRET-UUID" not in json.dumps(cfg)

    def test_empty_secret_stays_empty(self, spool):
        # An UNSET secret is served as-is so the UI can tell "set" from "not set".
        cfg = control_service.read_config()
        assert cfg["workers"]["api_token"] == ""
        assert cfg["p2pool"]["stratum_password"] == ""

    def test_non_secret_values_untouched(self, spool):
        cfg = control_service.read_config()
        assert cfg["monero"]["prune"] is True
        assert cfg["p2pool"]["pool"] == "mini"

    def test_merge_secrets_round_trip(self, spool):
        # Sentinel in → live value out; an actually-edited secret passes through.
        proposed = control_service.read_config()
        proposed["p2pool"]["pool"] = "main"
        proposed["telegram"]["bot_token"] = "456:new"  # explicit new value
        merged = control_service.merge_secrets(proposed)
        assert merged["dashboard"]["auth"]["password"] == "correct horse"
        assert merged["monero"]["node_password"] == "hunter2"
        assert merged["telegram"]["bot_token"] == "456:new"
        assert merged["p2pool"]["pool"] == "main"

    def test_merge_sentinel_for_unset_secret_collapses_to_empty(self, spool):
        # A forged sentinel where no secret exists must not leak a dict into config.json.
        proposed = {"workers": {"api_token": {"__secret__": True}}}
        assert control_service.merge_secrets(proposed)["workers"]["api_token"] == ""

    def test_merge_missing_sections_tolerated(self, spool):
        # A proposed config that omits whole sections merges without KeyErrors.
        assert control_service.merge_secrets({"p2pool": {"pool": "nano"}}) == {
            "p2pool": {"pool": "nano"}
        }


class TestSubmit:
    def test_submit_writes_request_json(self, spool):
        rid = control_service.submit("preview", {"p2pool": {"pool": "main"}}, actor="admin")
        uuid.UUID(rid)  # the id is a real UUID
        path = spool / "requests" / f"{rid}.json"
        req = json.loads(path.read_text())
        assert req == {
            "id": rid,
            "action": "preview",
            "actor": "admin",
            "config": {"p2pool": {"pool": "main"}},
        }
        # Atomic write: no temp file left behind.
        assert os.listdir(spool / "requests") == [f"{rid}.json"]

    def test_commit_reuses_intent_id_and_omits_config(self, spool):
        intent = str(uuid.uuid4())
        rid = control_service.submit("commit", actor="admin", intent_id=intent)
        assert rid == intent
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert "config" not in req

    def test_garbage_intent_id_rejected(self, spool):
        # The id becomes a host-side filename; anything that isn't a UUID never leaves the app.
        with pytest.raises(ValueError):
            control_service.submit("commit", intent_id="../../etc/passwd")


class TestResult:
    def test_result_pending_then_ready(self, spool):
        rid = str(uuid.uuid4())
        assert control_service.result(rid) is None
        (spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "applied"}))
        assert control_service.result(rid) == {"status": "applied"}

    def test_result_rejects_non_uuid_id(self, spool):
        with pytest.raises(ValueError):
            control_service.result("../audit/control.log")

    def test_result_tolerates_half_written_json(self, spool):
        rid = str(uuid.uuid4())
        (spool / "results" / f"{rid}.json").write_text('{"status": "app')
        assert control_service.result(rid) is None

    async def test_wait_result_returns_when_ready(self, spool):
        rid = str(uuid.uuid4())
        (spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "previewed"}))
        res = await control_service.wait_result(rid)
        assert res["status"] == "previewed"

    async def test_wait_result_times_out_to_none(self, spool):
        assert await control_service.wait_result(str(uuid.uuid4()), timeout_s=0.05) is None

    async def test_wait_result_done_predicate_skips_stale_preview(self, spool):
        # Commit polling must not accept the still-present preview result under the same id.
        rid = str(uuid.uuid4())
        (spool / "results" / f"{rid}.json").write_text(json.dumps({"status": "previewed"}))
        res = await control_service.wait_result(
            rid, done=lambda r: r.get("status") != "previewed", timeout_s=0.05
        )
        assert res is None


class TestReferenceMerge:
    """read_config merges config.reference.json UNDER the sparse config so the form shows the whole
    schema (#33 acceptance: "edit every setting"); a missing reference degrades gracefully (#437)."""

    def test_reference_fills_missing_keys_operator_overrides_win(self, spool, monkeypatch):
        reference = {
            "_docs": "human notes that must not reach the form",
            "monero": {"pool": "main", "mode": "remote", "new_key": "default"},
            "brand_new_section": {"knob": 7},
        }
        ref_path = spool / "config.reference.json"
        ref_path.write_text(json.dumps(reference))
        monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(ref_path))
        cfg = control_service.read_config()
        # Reference-only keys/sections appear...
        assert cfg["monero"]["new_key"] == "default"
        assert cfg["brand_new_section"] == {"knob": 7}
        # ...the operator's config.json overrides the reference default where both set it...
        assert cfg["monero"]["mode"] == "local"
        # ...secrets are still masked AFTER the merge...
        assert cfg["monero"]["node_password"] == {"__secret__": True}
        # ...and the _docs blob never leaks into the served form.
        assert "human notes" not in json.dumps(cfg)
        assert "_docs" not in cfg

    def test_missing_reference_degrades_to_host_config(self, spool, monkeypatch):
        monkeypatch.setattr(
            control_service.config, "HOST_REFERENCE_PATH", str(spool / "does-not-exist.json")
        )
        cfg = control_service.read_config()
        # Still serves the host config (masked) rather than raising.
        assert cfg["p2pool"]["pool"] == "mini"
        assert cfg["monero"]["node_password"] == {"__secret__": True}
