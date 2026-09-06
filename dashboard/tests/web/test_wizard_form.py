"""The no-JavaScript form fallback's optional branches (#77 phase 3, moved out under #1318).

``test_wizard.py`` pins what ``build_config`` does with the questions every operator answers:
the wallets, the ports and their defaults, the alert pair, the timezone. What it never reached
is the set of switches an operator turns ON — remote Tari, node credentials, a pruned local
chain, healthchecks, the local miner, the clearnet first sync. Each writes a key that changes
what the stack runs, and each was reachable only by a form nothing submitted, so this file
exercises the ON side of every one of them.

The rule the whole function is built on: a key is written only when the operator actually asked
for it, because an absent key inherits the documented default while an empty one overrides it.
Every test here therefore checks BOTH that turning a switch on writes the key and that leaving
it alone does not.
"""

from mining_dashboard import wizard
from mining_dashboard.wizard_form import build_config

# The two wallets are always present; every switch below is an addition to this.
BASE = {"monero_wallet": "4" + "A" * 94, "tari_wallet": "t"}


def test_the_wizard_module_still_serves_the_same_function():
    # ``submit`` and test_wizard.py both reach it as ``wizard.build_config``. The move is only
    # safe while that name is this function and not a copy of it.
    assert wizard.build_config is build_config


def test_a_remote_node_that_needs_a_login_carries_one():
    cfg = build_config(
        {
            **BASE,
            "monero_mode": "remote",
            "monero_remote_host": "10.0.0.5",
            "monero_remote_auth": "on",
            "monero_remote_user": "reader",
            "monero_remote_pass": "hunter2",
        }
    )
    assert cfg["monero"]["node_username"] == "reader"
    assert cfg["monero"]["node_password"] == "hunter2"


def test_a_remote_node_without_the_box_ticked_carries_no_credential_keys():
    # An empty username is a value, and writing one would override a node that needs none.
    cfg = build_config(
        {
            **BASE,
            "monero_mode": "remote",
            "monero_remote_host": "10.0.0.5",
            "monero_remote_user": "typed-then-unticked",
        }
    )
    assert "node_username" not in cfg["monero"]
    assert "node_password" not in cfg["monero"]


def test_remote_tari_carries_its_host_and_defaults_its_port():
    cfg = build_config({**BASE, "tari_mode": "remote", "tari_remote_host": "10.0.0.9"})
    assert cfg["tari"]["mode"] == "remote"
    assert cfg["tari"]["remote"] == {"host": "10.0.0.9", "grpc_port": 18142}


def test_remote_tari_takes_the_port_it_is_given():
    cfg = build_config(
        {**BASE, "tari_mode": "remote", "tari_remote_host": "h", "tari_remote_grpc": "9999"}
    )
    assert cfg["tari"]["remote"]["grpc_port"] == 9999


def test_a_local_tari_node_is_left_at_its_default_shape():
    # The sibling that keeps the two above narrow: the same reader, given no mode, writes
    # neither key rather than writing "local" and a remote block.
    cfg = build_config(BASE)
    assert "mode" not in cfg["tari"]
    assert "remote" not in cfg["tari"]


def test_declining_a_pruned_chain_is_recorded_for_a_node_we_run():
    # Pruning is the default for a local node, so "false" is the only answer worth writing.
    cfg = build_config({**BASE, "prune": "false"})
    assert cfg["monero"]["prune"] is False


def test_accepting_the_pruned_default_writes_nothing():
    assert "prune" not in build_config({**BASE, "prune": "true"})["monero"]


def test_a_healthchecks_url_is_written_only_when_given():
    cfg = build_config({**BASE, "healthchecks_url": "https://hc.example/ping/abc"})
    assert cfg["healthchecks"] == {"ping_url": "https://hc.example/ping/abc"}
    # Whitespace is not a URL. An empty ping_url disables the dead-man's switch the operator
    # believes they configured, which is the failure this branch exists to avoid.
    assert "healthchecks" not in build_config({**BASE, "healthchecks_url": "   "})


def test_the_local_miner_is_opt_in():
    assert build_config({**BASE, "local_miner": "on"})["local_miner"] == {"enabled": True}
    assert "local_miner" not in build_config(BASE)


def test_the_clearnet_first_sync_applies_to_both_chains_or_neither():
    # One chain syncing over clearnet while the other waits on Tor is not a state the operator
    # asked for; the question is asked once and answers for both.
    cfg = build_config({**BASE, "clearnet_sync": "true"})
    assert cfg["monero"]["clearnet_initial_sync"] is True
    assert cfg["tari"]["clearnet_initial_sync"] is True
    plain = build_config({**BASE, "clearnet_sync": "false"})
    assert "clearnet_initial_sync" not in plain["monero"]
    assert "clearnet_initial_sync" not in plain["tari"]
