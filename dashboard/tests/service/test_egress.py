"""Tests for the #170 egress-posture derivation."""

import itertools

from mining_dashboard.service.egress import (
    CLEARNET,
    INACTIVE,
    LOCAL,
    TOPOLOGY_NODES,
    TOR,
    _sinks_all_private,
    compute_egress_posture,
    compute_topology,
)
from mining_dashboard.service.topology_graph import NODE_ROUTES


def _conn(posture, component, needle):
    comp = next(c for c in posture["components"] if c["name"] == component)
    return next(c for c in comp["conns"] if needle in c["to"])


def test_safe_config_is_all_tor(_posture):
    p = _posture()
    assert p["summary"] == {
        "firewall": True,
        "leaks": 0,
        "blocked_by_firewall": 0,
        "all_tor": True,
        "level": "ok",
        "label": "All egress via Tor",
    }


def test_p2pool_clearnet_blocked_by_firewall_is_not_a_leak(_posture):
    p = _posture(p2pool_clearnet=True, firewall=True)
    assert _conn(p, "p2pool", "sidechain")["route"] == CLEARNET
    assert _conn(p, "p2pool", "sidechain")["blocked_by_firewall"] is True
    assert p["summary"]["leaks"] == 0
    assert p["summary"]["blocked_by_firewall"] == 1
    assert p["summary"]["all_tor"] is True  # fail-closed: configured-clearnet can't actually leave


def test_p2pool_clearnet_without_firewall_is_a_leak(_posture):
    p = _posture(p2pool_clearnet=True, firewall=False)
    assert p["summary"]["leaks"] == 1
    assert p["summary"]["level"] == "warn"
    assert "exposing your IP" in p["summary"]["label"]


def test_dashboard_xvb_stats_stays_tor_when_xvb_tor_is_off(_posture):
    # xvb.tor gates only the xmrig-proxy donation dial (#166); the dashboard's stats fetch is
    # unconditionally socks5h over Tor (#163/#701), so turning xvb.tor off must not show a leak.
    p = _posture(xvb_tor=False, firewall=True)
    assert _conn(p, "dashboard", "XvB stats")["route"] == TOR
    # The donation dial (a container) goes clearnet — but the #270 firewall blocks it.
    assert _conn(p, "xmrig-proxy", "XvB donation")["route"] == CLEARNET
    assert _conn(p, "xmrig-proxy", "XvB donation")["blocked_by_firewall"] is True
    assert p["summary"]["leaks"] == 0
    assert p["summary"]["all_tor"] is True


def test_xvb_disabled_routes_are_inactive(_posture):
    p = _posture(xvb_enabled=False)
    assert _conn(p, "dashboard", "XvB stats")["route"] == INACTIVE
    assert _conn(p, "xmrig-proxy", "XvB donation")["route"] == INACTIVE


def test_healthchecks_ping_is_tor_when_configured_inactive_otherwise(_posture):
    # A configured ping URL adds a dashboard Tor egress (#79); no URL → inactive, never a leak.
    assert (
        _conn(_posture(healthchecks_enabled=False), "dashboard", "Healthchecks")["route"]
        == INACTIVE
    )
    on = _posture(healthchecks_enabled=True, firewall=True)
    assert _conn(on, "dashboard", "Healthchecks")["route"] == TOR
    # It's over Tor, so it never counts as a leak even though the dashboard bypasses the firewall.
    assert on["summary"]["leaks"] == 0


def test_telegram_bot_is_tor_when_enabled_inactive_otherwise(_posture):
    # Enabling Telegram adds a dashboard Tor egress (#121/#340); off → inactive, never a leak.
    assert _conn(_posture(telegram_enabled=False), "dashboard", "Telegram")["route"] == INACTIVE
    on = _posture(telegram_enabled=True, firewall=True)
    assert _conn(on, "dashboard", "Telegram")["route"] == TOR
    assert on["summary"]["leaks"] == 0  # Tor-routed, so never a leak


def test_price_feed_is_tor_when_enabled_inactive_otherwise(_posture):
    # Opting into the price feed adds a dashboard Tor egress (#520); off → inactive, never a leak.
    assert _conn(_posture(price_feed_enabled=False), "dashboard", "price feed")["route"] == INACTIVE
    on = _posture(price_feed_enabled=True, firewall=True)
    assert _conn(on, "dashboard", "price feed")["route"] == TOR
    assert on["summary"]["leaks"] == 0  # Tor-routed, so never a leak


def test_alert_sinks_tor_when_configured_inactive_otherwise(_posture):
    # Configuring a webhook/ntfy sink adds a dashboard Tor egress (#380); off → inactive.
    assert _conn(_posture(), "dashboard", "alert sinks")["route"] == INACTIVE
    on = _posture(notify_sinks_enabled=True)
    assert _conn(on, "dashboard", "alert sinks")["route"] == TOR
    assert on["summary"]["leaks"] == 0  # Tor-routed, so never a leak


def test_alert_sinks_clearnet_public_endpoint_leaks_despite_firewall(_posture):
    # notifications.tor=false with a public endpoint: the dashboard is host-networked, so the #270
    # firewall can't cover it — every alert POST exposes the host IP.
    p = _posture(notify_sinks_enabled=True, notify_tor=False, firewall=True)
    conn = _conn(p, "dashboard", "alert sinks")
    assert conn["route"] == CLEARNET
    assert conn.get("blocked_by_firewall") is None
    assert p["summary"]["leaks"] == 1
    assert p["summary"]["all_tor"] is False


def test_alert_sinks_lan_carveout_is_local_not_a_leak(_posture):
    # The LAN carve-out: notifications.tor=false with every sink on a private IP. The POST never
    # leaves your network — route is local, and it must NOT count toward the leak total.
    p = _posture(notify_sinks_enabled=True, notify_tor=False, notify_sinks_private=True)
    assert _conn(p, "dashboard", "alert sinks")["route"] == LOCAL
    assert p["summary"]["leaks"] == 0
    assert p["summary"]["all_tor"] is True


def test_sinks_all_private_requires_ip_literal_proof():
    # Private/loopback IP literals prove the LAN carve-out; hostnames can't (no DNS in a pure
    # derivation), so they classify as public — as does an empty or malformed sink set.
    assert _sinks_all_private(["http://192.168.1.5/hook"]) is True
    assert _sinks_all_private(["http://127.0.0.1:8080/hook", "http://[::1]/ntfy/alerts"]) is True
    assert _sinks_all_private(["http://[fc00::1]/hook"]) is True  # IPv6 ULA — the v6 LAN case
    # The real _shared_knobs shape: webhook configured, NTFY_URL unset ("" must not veto).
    assert _sinks_all_private(["http://192.168.1.5/hook", ""]) is True
    assert _sinks_all_private(["http://192.168.1.5/hook", "https://ntfy.sh/mytopic"]) is False
    assert _sinks_all_private(["http://nas.local/hook"]) is False  # hostname — unknowable
    assert _sinks_all_private(["http://localhost/hook"]) is False  # still a hostname, same rule
    assert _sinks_all_private(["http://8.8.8.8/hook"]) is False
    assert _sinks_all_private(["http://user@8.8.8.8/hook"]) is False  # userinfo can't hide the host
    # IPv4-mapped IPv6 targets a public v4 address — must NOT classify private (needs the
    # CPython >= 3.11.10 mapped-address rules; pinned here so a runtime downgrade can't unlock it).
    assert _sinks_all_private(["http://[::ffff:8.8.8.8]/hook"]) is False
    assert _sinks_all_private(["http://100.64.0.1/hook"]) is False  # CGNAT/Tailscale — documented
    assert _sinks_all_private([]) is False
    assert _sinks_all_private(["", "  "]) is False
    assert _sinks_all_private(["not a url"]) is False


def test_xvb_standby_route_classification(_posture):
    # The #249 backup→primary pull: onion or any non-private source → Tor (socks5h, no IP leak);
    # a private-IP-literal primary → local (LAN hop); unset → inactive. Never clearnet.
    def route(src):
        return _conn(_posture(xvb_standby_source=src), "dashboard", "XvB standby pull")["route"]

    assert route("") == INACTIVE
    assert route("http://abc.onion/api/xvb-standby") == TOR
    assert route("http://192.168.1.5:8000/api/xvb-standby") == LOCAL
    assert route("http://10.0.0.2/api/xvb-standby") == LOCAL
    assert route("http://127.0.0.1:8000/api/xvb-standby") == LOCAL
    assert route("http://[::1]/api/xvb-standby") == LOCAL
    assert route("http://8.8.8.8:8000/api/xvb-standby") == TOR  # public IP — never direct (#160)
    assert route("http://primary.example.com/api/xvb-standby") == TOR  # hostname — unprovable
    # No source classification ever routes clearnet, so it can never count as a leak.
    for src in ("", "http://abc.onion/x", "http://192.168.1.5/x", "http://8.8.8.8/x"):
        assert _posture(xvb_standby_source=src)["summary"]["leaks"] == 0


def test_xvb_standby_topology_edge_tracks_route(_topo):
    # onion/public source → an edge into the tor hub (never the internet node); a private-IP
    # primary is a LAN hop with no placeable node, so it draws no edge (like the alert-sink case).
    def standby_edges(topo):
        return [e for e in topo["edges"] if e["label"] == "XvB standby"]

    tor = _topo(xvb_standby_source="http://8.8.8.8/api/xvb-standby")
    assert standby_edges(tor)[0]["to"] == "tor" and standby_edges(tor)[0]["route"] == TOR
    assert not any(e.get("leak") for e in tor["edges"])
    assert standby_edges(_topo(xvb_standby_source="http://abc.onion/x"))[0]["route"] == TOR
    assert standby_edges(_topo(xvb_standby_source=""))[0]["route"] == INACTIVE
    assert standby_edges(_topo(xvb_standby_source="http://192.168.1.5/x")) == []  # LAN, no node


def test_the_monerod_rpc_conn_carries_the_route_it_was_given(_posture):
    assert _conn(_posture(monero_route=LOCAL), "p2pool", "monerod RPC")["route"] == LOCAL
    assert _conn(_posture(monero_route=CLEARNET), "p2pool", "monerod RPC")["route"] == CLEARNET


def test_clearnet_initial_sync_surfaces_only_when_enabled(_posture):
    base = _posture()
    assert not any(
        "initial" in c["to"]
        for c in next(x for x in base["components"] if x["name"] == "monerod")["conns"]
    )
    synced = _posture(monero_clearnet_sync=True, firewall=False)
    assert _conn(synced, "monerod", "initial block download")["route"] == CLEARNET


def test_monerod_p2p_always_tor(_posture):
    assert _conn(_posture(firewall=False), "monerod", "Monero P2P")["route"] == TOR


# --- Topology (#170 trust-boundary view) -----------------------------------------------


def _from(topo, src):
    return [e for e in topo["edges"] if e["from"] == src]


def test_topology_summary_is_shared_with_egress_list(_posture, _topo):
    # The badge can never disagree with the map: same knobs in, identical summary out.
    for overrides in ({}, {"xvb_tor": False}, {"p2pool_clearnet": True, "firewall": False}):
        assert _topo(**overrides)["summary"] == _posture(**overrides)["summary"]


def test_topology_safe_has_no_leaks_and_hub_nodes(_topo):
    topo = _topo()
    ids = {n["id"] for n in topo["nodes"]}
    assert {"tor", "internet", "rigs", "browser"} <= ids
    assert not any(e.get("leak") for e in topo["edges"])
    assert topo["summary"]["all_tor"] is True


def test_topology_lan_ingress_edges(_edge, _topo):
    # Both hops LEAVE this box, so the legend's own split makes them LAN, never Local (#1856).
    topo = _topo()
    for e in (_edge(topo, "rigs", "xmrig-proxy"), _edge(topo, "browser", "caddy")):
        assert e["kind"] == "ingress" and e["route"] == "lan", e


def test_topology_daemon_p2p_is_bidirectional_over_tor(_edge, _topo):
    topo = _topo()
    for daemon in ("monerod", "tari", "p2pool"):
        edge = _edge(topo, daemon, "tor")
        assert edge["kind"] == "p2p", daemon  # egress + onion ingress
        assert edge["route"] == TOR, daemon


def test_topology_clearnet_link_bypasses_the_tor_hub(_edge, _topo):
    # A clearnet route must land on `internet`, not `tor`, so a leak visibly skips the hub.
    topo = _topo(p2pool_clearnet=True, firewall=False)
    edge = _edge(topo, "p2pool", "internet")
    assert edge["route"] == CLEARNET and edge["leak"] is True
    assert not any(e["to"] == "tor" and e["from"] == "p2pool" for e in topo["edges"])


def test_topology_clearnet_blocked_by_firewall_is_not_a_leak(_edge, _topo):
    topo = _topo(p2pool_clearnet=True, firewall=True)
    edge = _edge(topo, "p2pool", "internet")
    assert edge.get("blocked_by_firewall") is True and edge.get("leak") is None
    assert topo["summary"]["all_tor"] is True


def test_topology_dashboard_xvb_stats_stays_on_the_tor_hub_when_xvb_tor_is_off(_edge, _topo):
    topo = _topo(xvb_tor=False, firewall=True)
    # The dashboard's stats fetch is unconditionally Tor (#163/#701) — it must terminate at the
    # tor hub, never bypass to the internet node.
    xvb_stats = next(e for e in topo["edges"] if e["label"] == "XvB stats")
    assert xvb_stats["to"] == "tor" and xvb_stats["route"] == TOR
    assert not any(e["from"] == "dashboard" and e["to"] == "internet" for e in topo["edges"])
    # The xmrig-proxy XvB dial IS clearnet here — a container, so the firewall blocks it.
    assert _edge(topo, "xmrig-proxy", "internet").get("blocked_by_firewall") is True
    assert not any(e.get("leak") for e in topo["edges"])


def test_topology_xvb_disabled_is_inactive_not_a_leak(_edge, _topo):
    topo = _topo(xvb_enabled=False)
    assert _edge(topo, "xmrig-proxy", "tor")["route"] == INACTIVE
    assert next(e for e in topo["edges"] if e["label"] == "XvB stats")["route"] == INACTIVE
    assert _edge(topo, "dashboard", "tor")  # update check still present
    assert not any(e.get("leak") for e in topo["edges"])


def test_topology_internal_mesh_is_flagged_and_includes_merge_mining(_edge, _topo):
    topo = _topo()
    merge = _edge(topo, "p2pool", "tari")
    assert merge["kind"] == "internal" and "merge-mine" in merge["label"]
    docker = next(n for n in topo["nodes"] if n["id"] == "docker")
    assert docker.get("internal") is True


def test_topology_alert_sinks_edge_tracks_the_route(_topo):
    # Tor (or unconfigured) → an edge into the tor hub, same as healthchecks.
    def sink_edges(topo):
        return [e for e in topo["edges"] if e["label"] == "alert sinks"]

    assert sink_edges(_topo(notify_sinks_enabled=True))[0]["route"] == TOR
    assert sink_edges(_topo())[0]["route"] == INACTIVE
    # Public clearnet endpoint → straight to the internet node, tagged as a real leak.
    clearnet = _topo(notify_sinks_enabled=True, notify_tor=False, firewall=True)
    (edge,) = sink_edges(clearnet)
    assert edge["to"] == "internet" and edge["route"] == CLEARNET and edge["leak"] is True
    # LAN carve-out: no placeable node for a LAN appliance, so no edge — but the shared summary
    # still reports no leak, so the badge and the egress list stay honest.
    local = _topo(notify_sinks_enabled=True, notify_tor=False, notify_sinks_private=True)
    assert sink_edges(local) == []
    assert local["summary"]["leaks"] == 0 and local["summary"]["all_tor"] is True


def test_topology_clearnet_sync_adds_bypass_edge(_edge, _topo):
    topo = _topo(monero_clearnet_sync=True, firewall=False)
    edge = _edge(topo, "monerod", "internet")
    assert edge["route"] == CLEARNET and edge["leak"] is True


def test_tari_clearnet_sync_surfaces_in_egress_and_topology(_edge, _posture, _topo):
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
    "healthchecks_enabled",
    "telegram_enabled",
    "notify_sinks_enabled",
    "notify_tor",
    "notify_sinks_private",
)


def _all_configs():
    """Every boolean-knob combination, run once per route the monerod hop can take (#1350)."""
    for r, *c in itertools.product(NODE_ROUTES, *[(False, True)] * len(_KNOBS)):
        yield {"monero_route": r, **dict(zip(_KNOBS, c, strict=True))}


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
    routes = {TOR, INACTIVE, *NODE_ROUTES}
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


def test_firewall_off_counts_every_clearnet_path_as_a_leak(_posture):
    # Firewall down + every clearnet knob on: there's no backstop, so each clearnet path is a real,
    # counted leak — leaks must equal the number of clearnet connections, with nothing "blocked".
    p = _posture(
        firewall=False,
        p2pool_clearnet=True,
        xvb_tor=False,
        monero_clearnet_sync=True,
        tari_clearnet_sync=True,
        monero_route=CLEARNET,
    )
    clearnet = sum(1 for comp in p["components"] for c in comp["conns"] if c["route"] == CLEARNET)
    assert clearnet >= 5  # sidechain, RPC, monero IBD, tari IBD, XvB donation
    assert p["summary"]["leaks"] == clearnet
    assert p["summary"]["blocked_by_firewall"] == 0
    assert p["summary"]["all_tor"] is False
    assert "exposing your IP" in p["summary"]["label"]


def test_firewall_on_blocks_every_clearnet_path(_posture):
    # Same clearnet-everywhere config with the firewall ON: every clearnet path belongs to a
    # container, so all are blocked and nothing leaks — the dashboard's own egress is Tor-only
    # (#163/#701), so the host-networked firewall bypass has nothing clearnet to expose.
    p = _posture(
        firewall=True,
        p2pool_clearnet=True,
        xvb_tor=False,
        monero_clearnet_sync=True,
        tari_clearnet_sync=True,
        monero_route=CLEARNET,
    )
    assert p["summary"]["leaks"] == 0
    assert _conn(p, "dashboard", "XvB stats")["route"] == TOR
    assert p["summary"]["blocked_by_firewall"] >= 5
    assert p["summary"]["all_tor"] is True


# The dashboard clients hard-wired through Tor SOCKS — no knob points any of them at clearnet
# (#163 XvB stats, #224 update check, #79 Healthchecks, #121/#340 Telegram, #520 price feed).
# Scoped by name, not "all dashboard conns", so a future dashboard egress with a legitimate
# clearnet mode (e.g. the #380 alert-sink LAN carve-out) doesn't silently widen this invariant.
_TOR_HARDWIRED = ("XvB stats", "update check", "Healthchecks", "Telegram", "price feed")


def test_tor_hardwired_dashboard_clients_never_clearnet_for_any_config():
    # The panel's own #160 lesson: the dashboard bypasses the #270 firewall, so a clearnet route
    # here would be a real leak — no knob combination may ever derive one for these clients (#701).
    # next()/_conn raise StopIteration if a name drifts, so a rename can't hollow out the sweep.
    for cfg in _all_configs():
        p = compute_egress_posture(**cfg)
        for name in _TOR_HARDWIRED:
            assert _conn(p, "dashboard", name)["route"] != CLEARNET, (cfg, name)
        dash_edges = [e for e in compute_topology(**cfg)["edges"] if e["from"] == "dashboard"]
        for name in _TOR_HARDWIRED:
            edge = next(e for e in dash_edges if name in e["label"])
            assert edge["route"] != CLEARNET, (cfg, name)
