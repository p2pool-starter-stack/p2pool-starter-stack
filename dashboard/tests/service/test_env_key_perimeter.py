"""The dashboard-committability security perimeter (#1094 / #1069 W9): checks pithead's
editable/confirm allowlists and the dashboard's EDITABLE/CONFIRM_ENV_KEY_PATHS independently
against the keys that must never be dashboard-committable at all."""

import pytest

from mining_dashboard.service import control_service

# The security perimeter (#1094, #1069 W9): env keys that must never be dashboard-committable at
# all. SECURITY.md:99-100 is the authority for what belongs here — "wallets and view keys,
# dashboard auth and onion exposure, the control channel itself, the Tor egress firewall, node
# endpoints, binds, every credential, and the per-rig hosts and tokens" (the last category is
# enforced elsewhere: worker descriptors are refused outright, per control_service.py's
# EDITABLE_ENV_KEY_PATHS docstring, so they never reach this env-key-path list at all). The two
# drift tests above only catch the editable/confirm allowlists' two hand-kept copies disagreeing
# with EACH OTHER; a key added to BOTH copies at once (#1094's mutation proof: DASHBOARD_AUTH_HASH_B64,
# or DASHBOARD_HOST, added to pithead's list and EDITABLE_ENV_KEY_PATHS together) leaves them in
# perfect agreement and both drift tests stay green. This list is the claim those tests can't make:
# not "do the two copies match" but "is this key committable at all".
#
# THIS LIST AND SECURITY.md:99-100 MUST STAY IN SYNC: a perimeter category added to the doc without
# a matching entry here is a silent gap; an entry here with no textual basis in SECURITY.md is
# scope creep on a security-critical list. SECURITY.md's enumeration is prose, not a machine-
# readable key list, so the sync is manual — re-read both on any change to either.
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
        # NODE ENDPOINTS LEFT THIS LIST ON 2026-09-06 (#1888, operator ruling) — MONERO_NODE_HOST,
        # MONERO_RPC_PORT, MONERO_ZMQ_PORT and TARI_GRPC_ADDRESS. The threat they were listed for is
        # unchanged and still real: "where the stack points its Monero/Tari RPC clients —
        # dashboard-committable, this repoints mining traffic to an attacker's node." What changed
        # is that refusing them outright was not a defence on an appliance, it was a dead end: there
        # is no host shell there, so the setting became unchangeable for the life of the machine
        # (#786/#1821). They are now the confirm-gated tier, behind the control channel's own auth
        # plus a host-side reachability probe on the staged endpoint (43-control-approval-and-
        # preview.sh). Their RPC LOGIN CREDENTIALS — MONERO_NODE_USERNAME / MONERO_NODE_PASSWORD,
        # still above — did NOT move, and neither did the binds below: address identity is not a
        # secret, and a listen address is not an endpoint.
        # Binds (SECURITY.md's "binds"): the RPC/gRPC listen addresses. DASHBOARD_HOST (above)
        # covers the dashboard's own bind; these are the merge-mined services' local listeners.
        "MONERO_RPC_BIND",
        "MONERO_ZMQ_BIND",
        "TARI_GRPC_BIND",
        "TARI_WALLET_PASSWORD",
    }
)


def _pithead_key_sets():
    """pithead's three hand-kept key lists, read out of the BUILT CLI. Skips where the CLI is not in
    the tree at all (the dashboard-only image), the same degradation the perimeter test has always
    made — a missing CLI is not a passing perimeter."""
    import re
    from pathlib import Path

    here = Path(__file__).resolve()
    pithead_path = next((p / "pithead" for p in here.parents if (p / "pithead").is_file()), None)
    if pithead_path is None:
        pytest.skip("pithead CLI not present in this test context (dashboard-only image)")
    pithead = pithead_path.read_text()
    found = {}
    for name in ("EDITABLE", "CONFIRM"):
        m = re.search(rf"CONTROL_DASHBOARD_{name}_KEYS='([^']*)'", pithead)
        assert m, f"could not find pithead's {name.lower()} allowlist"
        found[name.lower()] = set(m.group(1).split())
    m = re.search(r"CONTROL_NODE_ENDPOINT_KEYS='([^']*)'", pithead)
    assert m, "could not find pithead's CONTROL_NODE_ENDPOINT_KEYS (#1888)"
    found["node_endpoints"] = set(m.group(1).split())
    return pithead, found


def test_node_endpoint_keys_are_confirm_gated_and_probed():
    """#1888: the node endpoints left the never-committable perimeter for the confirm tier, and the
    approval gate's reachability probe fires on CONTROL_NODE_ENDPOINT_KEYS. Those are two separate
    hand-kept lists, so the failure this guards is not hypothetical: a node key added to the confirm
    allowlist but NOT to the endpoint list would be dashboard-committable with NO probe behind it —
    the one thing the operator ruling traded the perimeter entry for. The Python copy is checked the
    same way, because the browser renders its fields from that one."""
    pithead, keys = _pithead_key_sets()
    assert keys["node_endpoints"], "the node-endpoint list is empty — nothing would ever be probed"
    for key in keys["node_endpoints"]:
        assert key in keys["confirm"], f"{key} is probed but not confirm-gated in pithead"
        assert key not in keys["editable"], f"{key} is free-commit in pithead — it must be CONFIRM"
        assert key in control_service.CONFIRM_ENV_KEY_PATHS, (
            f"{key} missing from CONFIRM_ENV_KEY_PATHS"
        )
    # The half that matters, and it needs a source the endpoint list itself cannot supply, or the
    # check is a tautology: a confirm key whose CONFIG PATH lives under a chain's `remote.` block IS
    # a node endpoint, whatever any hand-kept list says. Derived from the paths, compared to the
    # list — so a node key added to the confirm allowlist and forgotten here reds instead of
    # shipping committable with no probe behind it.
    by_path = {
        k
        for k, target in control_service.CONFIRM_ENV_KEY_PATHS.items()
        if any(".remote." in p for p in target)
    }
    assert by_path == keys["node_endpoints"], (
        f"confirm keys pointing at a remote node endpoint {sorted(by_path)} do not match the probe "
        f"list {sorted(keys['node_endpoints'])} — one of them would commit with no reachability probe"
    )


def test_confirm_paths_offers_a_node_endpoint_only_while_that_chain_is_remote():
    """#1888: a local (or, after #1855, an "off") chain derives its endpoint from the stack, so the
    field would edit nothing — do not render it. The MIXED config is the row that discriminates: a
    rule keyed on "any chain is remote" would pass a both-remote and a both-local check alike."""
    mixed = {"monero": {"mode": "remote"}, "tari": {"mode": "local"}}
    offered = control_service._confirm_paths(mixed)
    assert "monero.remote.host" in offered
    assert "tari.remote.host" not in offered
    assert "p2pool.stratum_port" in offered, "a non-endpoint confirm path must be unaffected"
    assert "monero.remote.host" not in control_service._confirm_paths({})


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
