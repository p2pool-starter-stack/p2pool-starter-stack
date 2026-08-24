"""The stack's topology graph: the zones each component sits in, the fixed node list, and the
per-request marking of which nodes are this machine's own (#1040).

Split out of ``egress.py`` because that module sits at its file-budget ceiling and this is the
part of it that is data rather than logic. ``egress`` imports back from here; the dependency runs
one way, and re-exporting ``TOPOLOGY_NODES`` keeps every existing importer working unchanged.
"""

# Zones, left-to-right by trust: your LAN, the host's container bridge, the Tor hub, the Internet.
ZONE_LAN = "lan"
ZONE_HOST = "host"
ZONE_TOR = "tor"
ZONE_NET = "internet"

# Nodes bracket the host components with the external actors they actually talk to. ``internal``
# nodes (the socket proxies) only appear when the operator expands the internal mesh.
TOPOLOGY_NODES = [
    {"id": "rigs", "label": "Mining rigs", "zone": ZONE_LAN},
    {"id": "browser", "label": "Browser", "zone": ZONE_LAN},
    {"id": "xmrig-proxy", "label": "xmrig-proxy", "zone": ZONE_HOST},
    {"id": "caddy", "label": "caddy", "zone": ZONE_HOST},
    {"id": "dashboard", "label": "dashboard", "zone": ZONE_HOST},
    {"id": "p2pool", "label": "p2pool", "zone": ZONE_HOST},
    {"id": "monerod", "label": "monerod", "zone": ZONE_HOST},
    {"id": "tari", "label": "tari", "zone": ZONE_HOST},
    {"id": "docker", "label": "docker-proxy", "zone": ZONE_HOST, "internal": True},
    {"id": "tor", "label": "tor", "zone": ZONE_TOR},
    {"id": "internet", "label": "Tor network", "zone": ZONE_NET},
]


def topology_nodes(*, remote_monero, remote_tari):
    """``TOPOLOGY_NODES`` with the two relocatable nodes marked local or remote (#1040).

    monerod and tari are the only nodes an operator can run somewhere else; every other node in
    the graph is always this machine's own, so it carries no ``remote`` key at all rather than a
    redundant ``False`` the diagram would then have to decide not to draw.

    Returns a COPY. The graph is built per request and the node list is a module-level constant —
    marking it in place would leak one call's topology into the next.
    """
    relocatable = {"monerod": remote_monero, "tari": remote_tari}
    return [
        {**n, "remote": bool(relocatable[n["id"]])} if n["id"] in relocatable else n
        for n in TOPOLOGY_NODES
    ]
