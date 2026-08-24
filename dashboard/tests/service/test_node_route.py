"""How a hop to a relocatable node is routed, and what that route does to the leak count (#1350).

New file: egress.py's own test module sits at its file-budget ceiling, and this covers the piece
#1350 adds — the address-shape classifier and the two route states it introduces.

The four edges this is really about (`p2pool`->`monerod`, `p2pool`->`tari`, `dashboard`->`monerod`,
`dashboard`->`tari`) all claimed `local` before this, three of them hardcoded. One render could
already contradict itself: with a remote monerod the node was marked `remote` and p2pool's hop to
it said `clearnet`, while the dashboard's hop to the SAME daemon still said `local`.
"""

import pytest

from mining_dashboard.service.egress import (
    CLEARNET,
    LOCAL,
    compute_egress_posture,
    compute_topology,
)
from mining_dashboard.service.topology_graph import LAN, NODE_ROUTES, UNKNOWN, node_route

# The resting config, mirroring test_egress.SAFE: everything private-by-default, so any leak the
# assertions below see was caused by the route under test and not by an unrelated knob.
SAFE = {
    "firewall": True,
    "p2pool_clearnet": False,
    "xvb_enabled": True,
    "xvb_tor": True,
    "monero_clearnet_sync": False,
    "tari_clearnet_sync": False,
    "monero_route": LOCAL,
    "healthchecks_enabled": False,
    "telegram_enabled": False,
}


def _posture(**overrides):
    return compute_egress_posture(**{**SAFE, **overrides})


def _topo(**overrides):
    return compute_topology(**{**SAFE, **overrides})


def _edge(topo, src, dst):
    return next(e for e in topo["edges"] if e["from"] == src and e["to"] == dst)


# --- The classifier ----------------------------------------------------------------------


@pytest.mark.parametrize(
    "address",
    [
        "192.168.1.10",  # RFC1918
        "10.0.0.9",
        "172.16.4.4",
        "127.0.0.1",  # loopback
        "169.254.7.7",  # link-local
        "fc00::1",  # RFC4193 unique-local
        "::1",  # IPv6 loopback, and it keeps its colons through the port split
        "10.0.0.9:18081",  # host:port, the TARI_GRPC_ADDRESS shape
    ],
)
def test_a_private_address_literal_is_a_lan_hop(address):
    assert node_route(address, is_local=False) == LAN


@pytest.mark.parametrize(
    "address",
    [
        "8.8.8.8",
        "1.1.1.1:18081",
        "2001:4860:4860::8888",
        # CGNAT — routable beyond your LAN, so not provably yours. Version-dependent: CPython
        # treats 100.64.0.0/10 as public through 3.12 and private from 3.13, so this row moves on
        # an interpreter bump. test_egress's `_sinks_all_private` pins the same address the same
        # way, so both move together and neither can drift alone.
        "100.64.0.1",
        "::ffff:8.8.8.8",  # IPv4-mapped: the mapped address is public, and that is what counts
    ],
)
def test_a_public_address_literal_is_clearnet(address):
    assert node_route(address, is_local=False) == CLEARNET


@pytest.mark.parametrize(
    "address",
    [
        "monerod.example.com",
        "nas.local",
        "localhost",  # a NAME for the loopback, and we do not resolve names — so still unknown
        "node.example.com:18081",
        "",
        "   ",
        None,
        "not an address at all",
        "[::1]:18081",  # bracketed IPv6 is not a shape these knobs produce; unproven, so unknown
    ],
)
def test_anything_that_is_not_an_address_literal_is_unknown(address):
    # Allowlist-shaped and fail-closed: an address nobody anticipated lands on the state that
    # admits we do not know, never on LAN's or clearnet's. The reassuring answer has to be earned.
    assert node_route(address, is_local=False) == UNKNOWN


def test_a_local_node_is_local_whatever_its_address_looks_like():
    # `is_local` is the operator's own configuration answer and it outranks the address shape:
    # a local node reached over the container bridge is not a LAN hop, it is this machine.
    for address in ("172.28.0.26", "8.8.8.8", "monerod.example.com", ""):
        assert node_route(address, is_local=True) == LOCAL


class _DnsAttempted(BaseException):
    """Raised if the classifier reaches for a resolver.

    Deliberately a BaseException, and that is the whole point of it. A mutation that DOES resolve
    the hostname will realistically wrap the lookup in `except Exception` and fall back to UNKNOWN
    on failure — which produces the correct RESULT and leaves an assertion on the return value
    green. This sentinel is not catchable by that handler, so the attempt itself fails the test
    rather than the answer it happened to arrive at. (Found by mutating this test's own guard: an
    AssertionError sentinel was swallowed exactly that way and the mutant survived.)
    """


def test_the_classifier_never_resolves_a_hostname(monkeypatch):
    # The decisive constraint, and the one with no other way to check it. A DNS lookup at
    # diagram-build time is ITSELF an egress, so in a Tor-routed stack the diagram would cause the
    # exact exposure it exists to warn about, on every render. Poison every resolver path: if the
    # classifier reaches for one, this raises instead of quietly succeeding on the test host.
    import socket

    def _boom(*a, **kw):
        raise _DnsAttempted("node_route performed a DNS lookup")

    for name in ("getaddrinfo", "gethostbyname", "gethostbyname_ex", "getnameinfo"):
        monkeypatch.setattr(socket, name, _boom)
    assert node_route("monerod.example.com", is_local=False) == UNKNOWN
    assert node_route("localhost", is_local=False) == UNKNOWN
    assert node_route("192.168.1.10", is_local=False) == LAN


def test_the_classifier_returns_only_declared_routes():
    # NODE_ROUTES is what the frontend's palette contract pins against; a route the classifier can
    # return but that list does not name would reach the diagram with no colour and no arrowhead.
    seen = {
        node_route(a, is_local=loc)
        for loc in (True, False)
        for a in ("192.168.1.10", "8.8.8.8", "example.com", "", "fc00::1", "10.0.0.9:1")
    }
    assert seen <= set(NODE_ROUTES)
    assert seen == {LOCAL, LAN, CLEARNET, UNKNOWN}  # and all four are actually reachable


# --- What a route does to the security summary -------------------------------------------


@pytest.mark.parametrize("firewall", [True, False])
@pytest.mark.parametrize("route", [LAN, UNKNOWN])
def test_a_lan_or_unknown_node_hop_moves_neither_security_counter(route, firewall):
    # `leaks` is defined at its own declaration as "clearnet egress that actually exposes the host
    # IP". A node on your own LAN does not expose it, so counting one would be inventing a leak —
    # and inventing a leak is as wrong as hiding one. `unknown` must not be counted either: we do
    # not know that it leaks, and the diagram carries that doubt where the count cannot.
    #
    # Asserted with the firewall BOTH ways on purpose. `blocked_by_firewall` is the other half of
    # the same branch, so a route that wrongly counted as clearnet would show up in exactly one of
    # these two rows depending on the firewall — one row alone would miss half the mistake.
    summary = _posture(monero_route=route, firewall=firewall)["summary"]
    assert summary["leaks"] == 0
    assert summary["blocked_by_firewall"] == 0
    assert summary["all_tor"] is True
    assert summary["level"] == "ok"


@pytest.mark.parametrize("firewall", [True, False])
def test_a_clearnet_node_hop_still_moves_a_counter(firewall):
    # The control for the test above. Without this, "the counters did not move" would be equally
    # consistent with the monerod hop having stopped reaching the counter at all — which is what
    # a careless edit to the conn at egress.py's p2pool component would actually do.
    summary = _posture(monero_route=CLEARNET, firewall=firewall)["summary"]
    assert summary["leaks"] == (0 if firewall else 1)
    assert summary["blocked_by_firewall"] == (1 if firewall else 0)


def test_a_lan_node_visibly_changes_the_count_that_used_to_be_charged(monkeypatch):
    # The behaviour change this PR ships, stated as a test rather than left for an operator to
    # notice. A remote monerod on a private address was charged to the security summary before
    # this (blocked with the firewall on, a LEAK with it off); it now moves neither counter.
    assert _posture(monero_route=CLEARNET, firewall=False)["summary"]["leaks"] == 1
    assert _posture(monero_route=LAN, firewall=False)["summary"]["leaks"] == 0


# --- What a route does to the diagram ----------------------------------------------------


@pytest.mark.parametrize("route", NODE_ROUTES)
def test_every_hop_to_a_relocatable_node_carries_that_node_s_route(route):
    # All four edges, including the three that were hardcoded `local`. Parametrised over every
    # route so a fix that special-cases one state and drops the others cannot pass.
    topo = _topo(monero_route=route, tari_route=route)
    assert _edge(topo, "p2pool", "monerod")["route"] == route
    assert _edge(topo, "dashboard", "monerod")["route"] == route
    assert _edge(topo, "p2pool", "tari")["route"] == route
    assert _edge(topo, "dashboard", "tari")["route"] == route


def test_the_two_hops_to_one_daemon_can_never_disagree():
    # The self-contradiction #1350 is really about: before this, `p2pool`->`monerod` followed the
    # remote knob while `dashboard`->`monerod` was hardcoded local, so one render described the
    # SAME daemon as two different things. They are now derived from one value and cannot drift.
    for route in NODE_ROUTES:
        topo = _topo(monero_route=route)
        hops = {e["from"]: e["route"] for e in topo["edges"] if e["to"] == "monerod"}
        assert hops == {"p2pool": route, "dashboard": route}, route


def test_a_lan_or_unknown_edge_is_never_tagged_as_a_leak():
    # `leak` / `blocked_by_firewall` are the diagram's own red-flag tags, set by a separate loop
    # from the summary counters — so they need their own assertion, not an inference from the
    # count. Only clearnet may carry either.
    for route in (LAN, UNKNOWN):
        for firewall in (True, False):
            topo = _topo(monero_route=route, tari_route=route, firewall=firewall)
            for src, dst in (("p2pool", "monerod"), ("dashboard", "tari")):
                edge = _edge(topo, src, dst)
                assert edge.get("leak") is None, (route, firewall, src)
                assert edge.get("blocked_by_firewall") is None, (route, firewall, src)


def test_a_lan_node_still_reads_as_remote_in_the_diagram():
    # The node caption and the edge colour answer different questions and must not be conflated:
    # "is it on this machine" (no) and "does reaching it expose me" (no). An operator needs both.
    nodes = {n["id"]: n for n in _topo(monero_route=LAN, tari_route=UNKNOWN)["nodes"]}
    assert nodes["monerod"]["remote"] is True
    assert nodes["tari"]["remote"] is True
    assert _edge(_topo(monero_route=LAN), "p2pool", "monerod")["route"] == LAN
