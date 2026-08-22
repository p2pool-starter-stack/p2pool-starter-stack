"""Unit tests for the dashboard side of the control channel (#33): defense-in-depth secret
masking, atomic request submission, result reads, and the UUID gate on ids that become host
filenames. The host serves a PRE-MASKED config copy (#440); read_config's own masking pass is
the second layer, so these tests feed it raw values on purpose."""

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

    def test_pre_masked_host_copy_served_as_is(self, spool):
        # The production shape (#440): the host copy already carries sentinels; read_config
        # serves them unchanged (its own masking pass is an idempotent second layer).
        pre_masked = json.loads(json.dumps(CONFIG))
        pre_masked["monero"]["node_password"] = {"__secret__": True}
        pre_masked["dashboard"]["auth"]["password"] = {"__secret__": True}
        (spool / "config.json").write_text(json.dumps(pre_masked))
        cfg = control_service.read_config()
        assert cfg["monero"]["node_password"] == {"__secret__": True}
        assert cfg["dashboard"]["auth"]["password"] == {"__secret__": True}
        assert cfg["p2pool"]["pool"] == "mini"


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

    def test_upgrade_intent_carries_version_only(self, spool):
        # The upgrade intent (#59) proposes a version and nothing else — no config leg, no
        # free-form target; the host runner re-derives what actually gets installed.
        rid = control_service.submit("upgrade", actor="admin", version="v9.9.9")
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req == {"id": rid, "action": "upgrade", "actor": "admin", "version": "v9.9.9"}

    def test_garbage_intent_id_rejected(self, spool):
        # The id becomes a host-side filename; anything that isn't a UUID never leaves the app.
        with pytest.raises(ValueError):
            control_service.submit("commit", intent_id="../../etc/passwd")

    def test_read_config_metadata_stripped_from_the_intent(self, spool):
        # The editor round-trips the fetched doc wholesale, so read_config's own metadata
        # injections (_core_keys/_editable_keys/_confirm_keys) ride back with the POST; the host
        # gate's closed-schema check refuses a commit carrying them (#679). submit is the choke point.
        rid = control_service.submit(
            "preview",
            {
                "p2pool": {"pool": "main"},
                "_core_keys": ["a"],
                "_editable_keys": ["b"],
                "_confirm_keys": ["c"],
            },
            actor="admin",
        )
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req["config"] == {"p2pool": {"pool": "main"}}

    def test_commit_carries_the_typed_confirmation(self, spool):
        # #719: an in-scope disruptive commit rides its typed confirmation; the host gate requires
        # the exact literal before a CONFIRM row proceeds. A commit without it omits the field.
        intent = str(uuid.uuid4())
        rid = control_service.submit("commit", actor="admin", intent_id=intent, confirm="APPLY")
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req["confirm"] == "APPLY"
        rid2 = control_service.submit("commit", actor="admin", intent_id=str(uuid.uuid4()))
        req2 = json.loads((spool / "requests" / f"{rid2}.json").read_text())
        assert "confirm" not in req2

    def test_non_dict_config_passes_through_for_the_host_to_reject(self, spool):
        # Malformed client payloads keep their host-side rejection ("config must be a JSON
        # object") instead of dying in the container on the metadata strip.
        rid = control_service.submit("preview", ["not", "a", "config"], actor="admin")
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req["config"] == ["not", "a", "config"]


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


class TestCoreKeys:
    """read_config's ``_core_keys`` field (#502/#529): the SAME config.core-keys.json file the
    wizard reads, surfaced to the browser so the Configuration view's core group is never a second
    hand-maintained list. Underscore-prefixed like config.reference.json's own ``_docs``, so
    buildSections on the frontend already skips it as a config section for free."""

    def test_core_keys_served_from_the_shared_file(self, spool, monkeypatch):
        core_keys_path = spool / "config.core-keys.json"
        core_keys_path.write_text(json.dumps(["monero.wallet_address", "p2pool.pool"]))
        monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(core_keys_path))
        cfg = control_service.read_config()
        assert cfg["_core_keys"] == ["monero.wallet_address", "p2pool.pool"]

    def test_missing_core_keys_file_degrades_to_empty_list(self, spool, monkeypatch):
        monkeypatch.setattr(
            control_service.config, "HOST_CORE_KEYS_PATH", str(spool / "does-not-exist.json")
        )
        cfg = control_service.read_config()
        assert cfg["_core_keys"] == []

    def test_malformed_core_keys_file_degrades_to_empty_list(self, spool, monkeypatch):
        core_keys_path = spool / "config.core-keys.json"
        core_keys_path.write_text("{not json")
        monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(core_keys_path))
        cfg = control_service.read_config()
        assert cfg["_core_keys"] == []

    def test_core_keys_file_not_a_list_degrades_to_empty_list(self, spool, monkeypatch):
        core_keys_path = spool / "config.core-keys.json"
        core_keys_path.write_text(json.dumps({"not": "a list"}))
        monkeypatch.setattr(control_service.config, "HOST_CORE_KEYS_PATH", str(core_keys_path))
        cfg = control_service.read_config()
        assert cfg["_core_keys"] == []


class TestEditableKeys:
    """read_config's ``_editable_keys`` field (#613): the config paths the control gate will
    actually commit, derived from EDITABLE_ENV_KEY_PATHS (mirroring pithead's
    CONTROL_DASHBOARD_EDITABLE_KEYS) plus the dashboard.energy special-case (#504). Surfaced the
    same underscore-metadata way ``_core_keys`` is, so the Configuration view can grey out
    everything else up front instead of edit-then-reject."""

    def test_editable_keys_served_on_read_config(self, spool):
        cfg = control_service.read_config()
        assert "p2pool.pool" in cfg["_editable_keys"]
        assert "xvb.donation_level" in cfg["_editable_keys"]
        assert cfg["_editable_keys"] == sorted(cfg["_editable_keys"])  # stable, deterministic order

    def test_dashboard_energy_is_the_special_case_addition(self, spool):
        # dashboard.energy.* never renders to .env (control.approval reads it straight off
        # config.json), so it can't come from the env-var map — it's allowed by name (#504).
        cfg = control_service.read_config()
        assert "dashboard.energy.cost_per_kwh" in cfg["_editable_keys"]
        assert "dashboard.energy.currency" in cfg["_editable_keys"]
        assert "dashboard.energy.xmr_price" in cfg["_editable_keys"]

    def test_host_only_security_fields_are_not_editable(self, spool):
        # Wallets, auth, remote-node RPC creds, and worker descriptors are exactly the class of
        # field #613 exists to grey out — never on the list.
        cfg = control_service.read_config()
        for path in (
            "monero.wallet_address",
            "monero.view_key",
            "dashboard.auth.password",
            "monero.node_password",
            "workers.api_token",
            "workers.list",
        ):
            assert path not in cfg["_editable_keys"], path

    def test_telegram_tamper_evidence_alarms_stay_host_only(self, spool):
        # wallet_changed / clearnet_exposed are the alarms a compromised container must not be
        # able to silence from the very channel it would use to do it.
        cfg = control_service.read_config()
        assert "telegram.events.wallet_changed" not in cfg["_editable_keys"]
        assert "telegram.events.clearnet_exposed" not in cfg["_editable_keys"]
        assert "telegram.events.node_down" in cfg["_editable_keys"]  # a normal event IS editable


def test_editable_keys_have_no_intra_repo_drift():
    """#613 (mirrors #515's WORKER_WRITABLE_KEYS check): EDITABLE_ENV_KEY_PATHS is a second copy of
    pithead's CONTROL_DASHBOARD_EDITABLE_KEYS, kept in sync only by this test. Drift means the
    dashboard either greys out something the gate would actually commit, or — worse — shows
    something editable that the gate silently refuses at Save, exactly the edit-then-reject
    experience #613 exists to remove."""
    import re
    from pathlib import Path

    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()
    m = re.search(r"CONTROL_DASHBOARD_EDITABLE_KEYS='([^']*)'", pithead)
    assert m, "could not find CONTROL_DASHBOARD_EDITABLE_KEYS in pithead"
    pithead_keys = set(m.group(1).split())
    assert pithead_keys, "extracted an empty allowlist — the regex likely stopped matching"
    assert set(control_service.EDITABLE_ENV_KEY_PATHS.keys()) == pithead_keys


class TestConfirmKeys:
    """read_config's ``_confirm_keys`` field (#719): the operationally-disruptive config paths the
    control gate commits behind a type-to-confirm, mirroring pithead's CONTROL_DASHBOARD_CONFIRM_KEYS
    the same underscore-metadata way ``_editable_keys`` mirrors the editable allowlist. The UI marks
    these editable-with-confirm instead of greying them host-only."""

    def test_confirm_keys_served_on_read_config(self, spool):
        cfg = control_service.read_config()
        for path in (
            "monero.data_dir",
            "tari.data_dir",
            "p2pool.data_dir",
            "dashboard.data_dir",
            "p2pool.stratum_port",
            "monero.clearnet_initial_sync",
            "tari.clearnet_initial_sync",
            "monero.prune",
        ):
            assert path in cfg["_confirm_keys"], path
        assert cfg["_confirm_keys"] == sorted(cfg["_confirm_keys"])  # stable, deterministic order

    def test_perimeter_stays_out_of_the_confirm_set(self, spool):
        # The confirm-gated set is strictly the "expensive but recoverable" class — never the
        # security perimeter, and never a plain editable key (that would demand needless friction).
        cfg = control_service.read_config()
        for path in (
            "monero.wallet_address",
            "monero.view_key",
            "dashboard.auth.password",
            "network.tor_egress_firewall",
            "dashboard.control.enabled",
            "tor.data_dir",  # only the four SERVICE data dirs are in scope, not tor's
            "p2pool.pool",  # a freely-editable key, not confirm-gated
        ):
            assert path not in cfg["_confirm_keys"], path

    def test_confirm_and_editable_sets_are_disjoint(self, spool):
        # A key is either free-to-commit or confirm-gated, never both — the UI picks one affordance.
        cfg = control_service.read_config()
        assert not (set(cfg["_confirm_keys"]) & set(cfg["_editable_keys"]))


def test_confirm_keys_have_no_intra_repo_drift():
    """#719 (mirrors the #613 EDITABLE_ENV_KEY_PATHS check): CONFIRM_ENV_KEY_PATHS is a second copy
    of pithead's CONTROL_DASHBOARD_CONFIRM_KEYS, kept in sync only by this test. Drift means the
    dashboard either greys out a field the gate would confirm-commit, or shows one editable-with-
    confirm that the gate silently refuses at Save."""
    import re
    from pathlib import Path

    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()
    m = re.search(r"CONTROL_DASHBOARD_CONFIRM_KEYS='([^']*)'", pithead)
    assert m, "could not find CONTROL_DASHBOARD_CONFIRM_KEYS in pithead"
    pithead_keys = set(m.group(1).split())
    assert pithead_keys, "extracted an empty confirm allowlist — the regex likely stopped matching"
    assert set(control_service.CONFIRM_ENV_KEY_PATHS.keys()) == pithead_keys


# The security perimeter (#1094): env keys that must never be dashboard-committable at all — auth,
# onion exposure, the bind/host, the control channel itself, Tor egress, and wallet/node
# credentials. The two drift tests above only catch the editable/confirm allowlists' two hand-kept
# copies disagreeing with EACH OTHER; a key added to BOTH copies at once (#1094's mutation proof:
# DASHBOARD_AUTH_HASH_B64, or DASHBOARD_HOST, added to pithead's list and EDITABLE_ENV_KEY_PATHS
# together) leaves them in perfect agreement and both drift tests stay green. This list is the
# claim those tests can't make: not "do the two copies match" but "is this key committable at all".
NEVER_COMMITTABLE_ENV_KEYS = frozenset(
    {
        "DASHBOARD_AUTH_USER",
        "DASHBOARD_AUTH_HASH_B64",
        "DASHBOARD_AUTH_PW_FP",
        "DASHBOARD_HOST",
        "DASHBOARD_CONTROL_ENABLED",
        "DASHBOARD_ONION_ENABLED",
        "DASHBOARD_ONION_ADDRESS",
        "DASHBOARD_ONION_CLIENT_AUTH",
        "TOR_EGRESS_FIREWALL",
        "MONERO_WALLET_ADDRESS",
        "MONERO_VIEW_KEY",
        "MONERO_NODE_USERNAME",
        "MONERO_NODE_PASSWORD",
        "WALLET_RPC_PASSWORD",
        "TARI_VIEW_KEY",
        # Node endpoints (SECURITY.md's "node endpoints"): where the stack points its Monero/Tari
        # RPC clients. Dashboard-committable, this repoints mining traffic to an attacker's node.
        "MONERO_NODE_HOST",
        "MONERO_RPC_PORT",
        "MONERO_ZMQ_PORT",
        "TARI_GRPC_ADDRESS",
        # Binds (SECURITY.md's "binds"): the RPC/gRPC listen addresses. DASHBOARD_HOST (above)
        # covers the dashboard's own bind; these are the merge-mined services' local listeners.
        "MONERO_RPC_BIND",
        "MONERO_ZMQ_BIND",
        "TARI_GRPC_BIND",
        "TARI_WALLET_PASSWORD",
    }
)


def test_perimeter_env_keys_never_committable_from_either_copy():
    """#1094 / #1069 W9: names the security perimeter directly (SECURITY.md:99-100) and checks each
    of the four allowlists (pithead's editable + confirm sets, EDITABLE_ENV_KEY_PATHS +
    CONFIRM_ENV_KEY_PATHS) against it independently, so a key added to every copy at once still
    fails — unlike the drift tests above, which compare the copies only to each other."""
    import re
    from pathlib import Path

    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()
    editable_m = re.search(r"CONTROL_DASHBOARD_EDITABLE_KEYS='([^']*)'", pithead)
    confirm_m = re.search(r"CONTROL_DASHBOARD_CONFIRM_KEYS='([^']*)'", pithead)
    assert editable_m and confirm_m, "could not find pithead's editable/confirm allowlists"
    pithead_editable = set(editable_m.group(1).split())
    pithead_confirm = set(confirm_m.group(1).split())
    py_editable = set(control_service.EDITABLE_ENV_KEY_PATHS.keys())
    py_confirm = set(control_service.CONFIRM_ENV_KEY_PATHS.keys())

    for key in NEVER_COMMITTABLE_ENV_KEYS:
        # A perimeter entry whose spelling no longer exists in the codebase guards nothing: the
        # real (renamed) key could be added to every allowlist while this list stays green. Anchor
        # each entry to the pithead text so a rename kills the test, not the protection.
        assert key in pithead, (
            f"{key} appears nowhere in pithead — dead perimeter entry (key renamed?)"
        )
        assert key not in pithead_editable, f"{key} in pithead's CONTROL_DASHBOARD_EDITABLE_KEYS"
        assert key not in pithead_confirm, f"{key} in pithead's CONTROL_DASHBOARD_CONFIRM_KEYS"
        assert key not in py_editable, f"{key} in control_service.EDITABLE_ENV_KEY_PATHS"
        assert key not in py_confirm, f"{key} in control_service.CONFIRM_ENV_KEY_PATHS"


class TestWorkerApply:
    """Worker config-apply spooling + validation (#185). The intent carries only the worker name +
    writable-key changes — never a host, port, or token (those stay host-side, #440)."""

    def test_validate_worker_changes(self):
        assert control_service.validate_worker_changes({"DONATION": 2}) == ""
        assert control_service.validate_worker_changes({"pools": [], "max_temp_c": 80}) == ""
        # Empty / wrong type.
        assert "non-empty" in control_service.validate_worker_changes({})
        assert "non-empty" in control_service.validate_worker_changes([])
        assert "non-empty" in control_service.validate_worker_changes("nope")
        # A key outside the writable allowlist (escalation attempt).
        err = control_service.validate_worker_changes({"ACCESS_TOKEN": "x", "DONATION": 1})
        assert "ACCESS_TOKEN" in err and "not writable" in err

    def test_submit_worker_apply_spools_tokenless_intent(self, spool):
        rid = control_service.submit_worker_apply("rig1", {"DONATION": 4}, actor="admin")
        uuid.UUID(rid)
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req == {
            "id": rid,
            "action": "worker-apply",
            "actor": "admin",
            "worker": "rig1",
            "changes": {"DONATION": 4},
        }
        # No secret / addressing leaks into the container-writable spool.
        assert "host" not in req and "port" not in req and "token" not in req

    def test_submit_worker_upgrade_spools_name_and_version_only(self, spool):
        # #597: same tokenless contract as worker-apply — the version is a proposal the host
        # re-derives; the rig's address + bearer never enter the container-writable spool.
        rid = control_service.submit_worker_upgrade("rig1", "v1.11.2", actor="admin")
        uuid.UUID(rid)
        req = json.loads((spool / "requests" / f"{rid}.json").read_text())
        assert req == {
            "id": rid,
            "action": "worker-upgrade",
            "actor": "admin",
            "worker": "rig1",
            "version": "v1.11.2",
        }
        assert "host" not in req and "port" not in req and "token" not in req


def test_writable_key_allowlist_has_no_intra_repo_drift():
    """#515: the worker writable-key allowlist is hardcoded in THREE places kept in sync only by
    comments — the dashboard (WORKER_WRITABLE_KEYS), the pithead host runner
    (control_worker_apply's jq allowlist), and rigforge's control-server.py WRITABLE (the authority
    the rig enforces, #236). Drift means edits for the drifted key silently fail closed. Guard the
    two pithead-repo copies here; rigforge#236 carries the reciprocal check on the rig side."""
    import re
    from pathlib import Path

    canonical = {"pools", "DONATION", "autotune", "watchdog", "watchdog_interval_min", "max_temp_c"}
    assert set(control_service.WORKER_WRITABLE_KEYS) == canonical

    # The pithead CLI lives at the repo root; the dashboard-only Docker test image doesn't ship it.
    # Verify the cross-file drift where pithead is reachable (full checkout / CI shell tests), and
    # skip cleanly where it isn't.
    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()
    # [^\]]* (not .*?) so the match survives the jq array being reflowed across multiple lines.
    m = re.search(r"\(\[([^\]]*)\]\)\s*as\s*\$ok", pithead)
    assert m, "could not find the writable-key allowlist in pithead's control_worker_apply"
    pithead_keys = set(re.findall(r'"([^"]+)"', m.group(1)))
    assert pithead_keys == canonical, f"pithead allowlist {pithead_keys} drifted from {canonical}"
