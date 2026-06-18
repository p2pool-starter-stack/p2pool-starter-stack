"""Tests for the #170 egress-posture derivation."""

from mining_dashboard.service.egress import CLEARNET, INACTIVE, TOR, compute_egress_posture

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
