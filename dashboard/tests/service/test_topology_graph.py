"""The topology graph's node list and its local/remote marking (#1040).

New file: egress.py's own test module is at its file-budget ceiling, and this covers the piece
split out of it — the graph as data, plus the per-request marking of which nodes are this
machine's own.
"""

from mining_dashboard.service import egress
from mining_dashboard.service.topology_graph import TOPOLOGY_NODES, topology_nodes

_COMBOS = ((False, False), (True, False), (False, True), (True, True))


def test_only_the_relocatable_nodes_carry_a_location():
    # monerod and tari are the only nodes an operator can run somewhere else. Every other node is
    # always this machine's own, so it carries no `remote` key at all — the diagram then has one
    # thing to draw rather than a redundant "local" on nine boxes it would have to skip.
    #
    # The mixed rows are the point: the failure that matters is not a missing flag, it is one node
    # reported using the OTHER node's answer, which sends an operator to the wrong machine.
    for mono, tari in _COMBOS:
        nodes = {n["id"]: n for n in topology_nodes(remote_monero=mono, remote_tari=tari)}
        assert nodes["monerod"]["remote"] is mono, (mono, tari)
        assert nodes["tari"]["remote"] is tari, (mono, tari)
        assert sorted(i for i, n in nodes.items() if "remote" in n) == ["monerod", "tari"]


def test_marking_never_mutates_the_shared_node_list():
    # The node list is a module-level constant and the graph is rebuilt per request: marking it in
    # place would leak one caller's topology into the next one's diagram.
    for mono, tari in _COMBOS:
        topology_nodes(remote_monero=mono, remote_tari=tari)
    assert all("remote" not in n for n in TOPOLOGY_NODES)


def test_the_served_graph_carries_each_node_s_real_location(monkeypatch):
    # compute_topology defaults remote_tari, so a signature alone would not catch topology_from_config
    # forgetting to pass it — the diagram would then call every Tari node local, forever and quietly.
    # Both helpers are given different answers so a swapped wire-up fails too.
    # Tari must come out REMOTE here. remote_tari defaults to False, so asserting a local Tari
    # would pass whether or not the value was ever passed — the assertion has to differ from the
    # default to mean anything. Monero is given the opposite answer so a swapped wiring fails too.
    monkeypatch.setattr(egress.config, "monero_is_local", lambda: True)
    monkeypatch.setattr(egress.config, "tari_is_local", lambda: False)
    nodes = {n["id"]: n for n in egress.topology_from_config()["nodes"]}
    assert nodes["monerod"]["remote"] is False
    assert nodes["tari"]["remote"] is True
