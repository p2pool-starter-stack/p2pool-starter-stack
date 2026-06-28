"""Tests for the #170 egress-posture derivation."""

import itertools

from mining_dashboard.service.egress import (
    CLEARNET,
    INACTIVE,
    LOCAL,
    TOPOLOGY_NODES,
    TOR,
    compute_egress_posture,
    compute_topology,
)

# The privacy-safe resting config: firewall on, p2pool over Tor, XvB over Tor, local node, no sync.
SAFE = {
    "firewall": True,
    "p2pool_clearnet": False,
    "xvb_enabled": True,
    "xvb_tor": True,
    "monero_clearnet_sync": False,
    "tari_clearnet_sync": False,
    "remote_monero": False,
}


def _posture(**overrides):
    return compute_egress_posture(**{**SAFE, **overrides})


def _conn(posture, component, needle):
    comp = next(c for c in posture["components"] if c["name"] == component)
    return next(c for c in comp["conns"] if needle in c["to"])


def test_safe_config_is_all_tor():
    p = _posture()
    assert p["summary"] == {
        "firewall": True,
        "leaks": 0,
        "blocked_by_firewall": 0,
        "all_tor": True,
        "level": "ok",
        "label": "All egress via Tor",
    }


def test_p2pool_clearnet_blocked_by_firewall_is_not_a_leak():
    p = _posture(p2pool_clearnet=True, firewall=True)
    assert _conn(p, "p2pool", "sidechain")["route"] == CLEARNET
    assert _conn(p, "p2pool", "sidechain")["blocked_by_firewall"] is True
    assert p["summary"]["leaks"] == 0
    assert p["summary"]["blocked_by_firewall"] == 1
    assert p["summary"]["all_tor"] is True  # fail-closed: configured-clearnet can't actually leave


def test_p2pool_clearnet_without_firewall_is_a_leak():
    p = _posture(p2pool_clearnet=True, firewall=False)
    assert p["summary"]["leaks"] == 1
    assert p["summary"]["level"] == "warn"
    assert "exposing your IP" in p["summary"]["label"]


def test_host_networked_dashboard_leaks_despite_firewall():
    # The dashboard's XvB stats fetch is host-networked, so the #270 container firewall can't cover
    # it — disabling XvB-over-Tor leaks the host IP even with the firewall on. This is the key nuance.
    p = _posture(xvb_tor=False, firewall=True)
    assert _conn(p, "dashboard", "XvB stats")["route"] == CLEARNET
    assert _conn(p, "dashboard", "XvB stats").get("blocked_by_firewall") is None
    # The xmrig-proxy donation dial (a container) IS blocked by the firewall, but the dashboard isn't.
    assert _conn(p, "xmrig-proxy", "XvB donation")["blocked_by_firewall"] is True
    assert p["summary"]["leaks"] >= 1
    assert p["summary"]["all_tor"] is False


def test_xvb_disabled_routes_are_inactive():
    p = _posture(xvb_enabled=False)
    assert _conn(p, "dashboard", "XvB stats")["route"] == INACTIVE
    assert _conn(p, "xmrig-proxy", "XvB donation")["route"] == INACTIVE
    assert p["summary"]["leaks"] == 0


def test_remote_monerod_rpc_is_clearnet():
    assert _conn(_posture(remote_monero=False), "p2pool", "monerod RPC")["route"] != CLEARNET
    assert _conn(_posture(remote_monero=True), "p2pool", "monerod RPC")["route"] == CLEARNET


def test_clearnet_initial_sync_surfaces_only_when_enabled():
    base = _posture()
    assert not any(
        "initial" in c["to"]
        for c in next(x for x in base["components"] if x["name"] == "monerod")["conns"]
    )
    synced = _posture(monero_clearnet_sync=True, firewall=False)
    assert _conn(synced, "monerod", "initial block download")["route"] == CLEARNET


def test_monerod_p2p_always_tor():
    assert _conn(_posture(firewall=False), "monerod", "Monero P2P")["route"] == TOR


# --- Topology (#170 trust-boundary view) -----------------------------------------------


def _topo(**overrides):
    return compute_topology(**{**SAFE, **overrides})


def _edge(topo, src, dst):
    return next(e for e in topo["edges"] if e["from"] == src and e["to"] == dst)


def _from(topo, src):
    return [e for e in topo["edges"] if e["from"] == src]


def test_topology_summary_is_shared_with_egress_list():
    # The badge can never disagree with the map: same knobs in, identical summary out.
    for overrides in ({}, {"xvb_tor": False}, {"p2pool_clearnet": True, "firewall": False}):
        assert _topo(**overrides)["summary"] == _posture(**overrides)["summary"]


def test_topology_safe_has_no_leaks_and_hub_nodes():
    topo = _topo()
    ids = {n["id"] for n in topo["nodes"]}
    assert {"tor", "internet", "rigs", "browser"} <= ids
    assert not any(e.get("leak") for e in topo["edges"])
    assert topo["summary"]["all_tor"] is True


def test_topology_lan_ingress_edges():
    topo = _topo()
    rigs = _edge(topo, "rigs", "xmrig-proxy")
    assert rigs["kind"] == "ingress" and rigs["route"] == "local"
    assert _edge(topo, "browser", "caddy")["kind"] == "ingress"


def test_topology_daemon_p2p_is_bidirectional_over_tor():
    topo = _topo()
    for daemon in ("monerod", "tari", "p2pool"):
        edge = _edge(topo, daemon, "tor")
        assert edge["kind"] == "p2p", daemon  # egress + onion ingress
        assert edge["route"] == TOR, daemon


def test_topology_clearnet_link_bypasses_the_tor_hub():
    # A clearnet route must land on `internet`, not `tor`, so a leak visibly skips the hub.
    topo = _topo(p2pool_clearnet=True, firewall=False)
    edge = _edge(topo, "p2pool", "internet")
    assert edge["route"] == CLEARNET and edge["leak"] is True
    assert not any(e["to"] == "tor" and e["from"] == "p2pool" for e in topo["edges"])


def test_topology_clearnet_blocked_by_firewall_is_not_a_leak():
    topo = _topo(p2pool_clearnet=True, firewall=True)
    edge = _edge(topo, "p2pool", "internet")
    assert edge.get("blocked_by_firewall") is True and edge.get("leak") is None
    assert topo["summary"]["all_tor"] is True


def test_topology_host_networked_dashboard_xvb_leaks_but_proxy_is_blocked():
    topo = _topo(xvb_tor=False, firewall=True)
    # The dashboard's XvB stats fetch is host-networked → the #270 firewall can't cover it.
    assert _edge(topo, "dashboard", "internet")["leak"] is True
    # The xmrig-proxy XvB dial IS a container → the firewall blocks its clearnet route.
    assert _edge(topo, "xmrig-proxy", "internet").get("blocked_by_firewall") is True


def test_topology_xvb_disabled_is_inactive_not_a_leak():
    topo = _topo(xvb_enabled=False)
    assert _edge(topo, "xmrig-proxy", "tor")["route"] == INACTIVE
    assert _edge(topo, "dashboard", "tor")  # update check still present
    assert not any(e.get("leak") for e in topo["edges"])


def test_topology_internal_mesh_is_flagged_and_includes_merge_mining():
    topo = _topo()
    merge = _edge(topo, "p2pool", "tari")
    assert merge["kind"] == "internal" and "merge-mine" in merge["label"]
    docker = next(n for n in topo["nodes"] if n["id"] == "docker")
    assert docker.get("internal") is True


def test_topology_clearnet_sync_adds_bypass_edge():
    topo = _topo(monero_clearnet_sync=True, firewall=False)
    edge = _edge(topo, "monerod", "internet")
    assert edge["route"] == CLEARNET and edge["leak"] is True


def test_tari_clearnet_sync_surfaces_in_egress_and_topology():
    # The Tari clearnet-sync branch is symmetric with Monero's — exercise it explicitly so the
    # tari path can't regress unnoticed (only the monerod one was covered before).
    base = _posture()
    tari_conns = next(c for c in base["components"] if c["name"] == "tari")["conns"]
    assert not any("initial sync" in c["to"] for c in tari_conns)

    p = _posture(tari_clearnet_sync=True, firewall=False)
    assert _conn(p, "tari", "initial sync")["route"] == CLEARNET
    topo = _topo(tari_clearnet_sync=True, firewall=False)
    edge = _edge(topo, "tari", "internet")
    assert edge["route"] == CLEARNET and edge["leak"] is True


# --- Exhaustive config sweep + frontend contract ---------------------------------------
# The diagram must hold for ANY operator config, not just the hand-picked cases above.

_KNOBS = (
    "firewall",
    "p2pool_clearnet",
    "xvb_enabled",
    "xvb_tor",
    "monero_clearnet_sync",
    "tari_clearnet_sync",
    "remote_monero",
)


def _all_configs():
    """Every one of the 2**7 combinations of the boolean knobs."""
    for combo in itertools.product((False, True), repeat=len(_KNOBS)):
        yield dict(zip(_KNOBS, combo, strict=True))


# Canonical node ids — MUST stay in lockstep with the frontend's POS map in
# web/static/topology.mjs (the SVG silently drops any edge whose endpoint it can't place, so a
# drift here would make a real connection vanish from the diagram with no error). The frontend
# half of this contract is asserted in tests/frontend/topology.test.mjs.
TOPOLOGY_NODE_IDS = {
    "rigs",
    "browser",
    "xmrig-proxy",
    "caddy",
    "dashboard",
    "p2pool",
    "monerod",
    "tari",
    "docker",
    "tor",
    "internet",
}


def test_topology_nodes_match_the_canonical_set():
    assert {n["id"] for n in TOPOLOGY_NODES} == TOPOLOGY_NODE_IDS


def test_every_edge_endpoint_is_a_placeable_node_for_all_configs():
    # No config may emit an edge to/from a node the diagram can't place — that edge would silently
    # disappear from the SVG. This is the contract that keeps "various configs show correctly".
    for cfg in _all_configs():
        topo = compute_topology(**cfg)
        assert {n["id"] for n in topo["nodes"]} == TOPOLOGY_NODE_IDS, cfg
        for e in topo["edges"]:
            assert e["from"] in TOPOLOGY_NODE_IDS, (cfg, e)
            assert e["to"] in TOPOLOGY_NODE_IDS, (cfg, e)


def test_every_edge_is_well_formed_for_all_configs():
    routes = {TOR, CLEARNET, LOCAL, INACTIVE}
    kinds = {"ingress", "egress", "p2p", "internal"}
    for cfg in _all_configs():
        for e in compute_topology(**cfg)["edges"]:
            assert e["route"] in routes, (cfg, e)
            assert e["kind"] in kinds, (cfg, e)
            assert e["label"], (cfg, e)
            # A link is either a real leak or firewall-blocked, never tagged both at once.
            assert not (e.get("leak") and e.get("blocked_by_firewall")), (cfg, e)
            # Only clearnet links may carry a leak / blocked tag.
            if e.get("leak") or e.get("blocked_by_firewall"):
                assert e["route"] == CLEARNET, (cfg, e)


def test_topology_summary_matches_egress_for_all_configs():
    # The header badge (built from the egress summary) can never disagree with the map: the two are
    # derived from the same knobs and must return a byte-identical summary for every combination.
    for cfg in _all_configs():
        assert compute_topology(**cfg)["summary"] == compute_egress_posture(**cfg)["summary"], cfg


def test_firewall_off_counts_every_clearnet_path_as_a_leak():
    # Firewall down + every clearnet knob on: there's no backstop, so each clearnet path is a real,
    # counted leak — leaks must equal the number of clearnet connections, with nothing "blocked".
    p = _posture(
        firewall=False,
        p2pool_clearnet=True,
        xvb_tor=False,
        monero_clearnet_sync=True,
        tari_clearnet_sync=True,
        remote_monero=True,
    )
    clearnet = sum(1 for comp in p["components"] for c in comp["conns"] if c["route"] == CLEARNET)
    assert clearnet >= 5  # sidechain, RPC, monero IBD, tari IBD, XvB donation, XvB stats...
    assert p["summary"]["leaks"] == clearnet
    assert p["summary"]["blocked_by_firewall"] == 0
    assert p["summary"]["all_tor"] is False
    assert "exposing your IP" in p["summary"]["label"]


def test_firewall_on_blocks_containers_but_not_the_host_dashboard():
    # Same clearnet-everywhere config with the firewall ON: every container path is blocked, leaving
    # exactly the host-networked dashboard's XvB stats fetch as the sole real leak (the #270 nuance).
    p = _posture(
        firewall=True,
        p2pool_clearnet=True,
        xvb_tor=False,
        monero_clearnet_sync=True,
        tari_clearnet_sync=True,
        remote_monero=True,
    )
    assert p["summary"]["leaks"] == 1
    assert _conn(p, "dashboard", "XvB stats")["route"] == CLEARNET
    assert _conn(p, "dashboard", "XvB stats").get("blocked_by_firewall") is None
    assert p["summary"]["blocked_by_firewall"] >= 4
    assert p["summary"]["all_tor"] is False
