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
