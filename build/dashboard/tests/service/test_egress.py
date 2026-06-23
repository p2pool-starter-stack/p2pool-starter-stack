"""Tests for the #170 egress-posture derivation."""

from mining_dashboard.service.egress import (
    CLEARNET,
    INACTIVE,
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
