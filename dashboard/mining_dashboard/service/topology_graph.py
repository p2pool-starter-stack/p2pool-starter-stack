"""The stack's topology graph: the zones each component sits in, the fixed node list, the route
vocabulary every hop is coloured by, and the per-request marking of which nodes are this
machine's own (#1040).

Split out of ``egress.py`` because that module sits at its file-budget ceiling and this is the
part of it that is data rather than logic. ``egress`` imports back from here; the dependency runs
one way, and re-exporting ``TOPOLOGY_NODES`` keeps every existing importer working unchanged.
The route constants live here for the same reason ``ZONE_LAN`` does — ``node_route`` needs them
and ``egress`` has no room — and ``egress`` re-exports them, so every existing importer of
``egress.LOCAL`` and friends keeps working unchanged.
"""

import ipaddress

# Zones, left-to-right by trust: your LAN, the host's container bridge, the Tor hub, the Internet.
ZONE_LAN = "lan"
ZONE_HOST = "host"
ZONE_TOR = "tor"
ZONE_NET = "internet"

# Routes a hop can take. LOCAL is this machine (loopback or the container bridge); LAN is a hop
# that leaves the host but provably stays on the operator's own network; CLEARNET leaves it for
# the internet; UNKNOWN is an address we cannot classify without resolving it, and we never do.
TOR = "tor"
CLEARNET = "clearnet"
LOCAL = "local"
LAN = "lan"
UNKNOWN = "unknown"
INACTIVE = "inactive"

# Exactly the routes ``node_route`` can return, in increasing order of exposure. Named so the
# sweep in test_egress and the frontend's palette contract both pin against one list instead of
# each restating it — a new route added here fails both until it is coloured and labelled.
NODE_ROUTES = (LOCAL, LAN, CLEARNET, UNKNOWN)

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


def edge(src, dst, route, label, kind):
    """One hop in the diagram. Lives here, not in ``egress``, for the same reason the route
    constants do: ``egress`` sits at its file-budget ceiling and this is graph vocabulary."""
    return {"from": src, "to": dst, "route": route, "label": label, "kind": kind}


def ext_node(route):
    # Where a component's external link lands in the diagram: a Tor-routed link terminates at the
    # `tor` hub; a clearnet link goes STRAIGHT to the internet node, so a leak visibly bypasses Tor.
    return "internet" if route == CLEARNET else "tor"


def node_route(address, *, is_local):
    """Route of a hop to a relocatable node, from its configured address SHAPE alone (#1350).

    ``address`` is a bare host or a ``host:port`` pair — the two forms the node knobs come in
    (``MONERO_NODE_HOST`` and ``TARI_GRPC_ADDRESS`` respectively), so the caller never has to
    split one and the two call sites cannot drift in how they do it.

    Same #160 reasoning as ``egress._xvb_standby_route`` and ``egress._sinks_all_private``, and
    deliberately the same shape: only an IP literal can be *proven* to stay on the operator's
    network. A private/loopback/link-local literal is a LAN hop; any other literal is clearnet.

    **A hostname is never resolved.** A DNS lookup at diagram-build time would itself be an
    egress, so in a Tor-routed stack the diagram would cause the exact exposure it exists to warn
    about, on every render. An address we cannot classify is therefore ``UNKNOWN`` — its own
    visible state, never quietly borrowing LAN's or CLEARNET's colour. Allowlist-shaped, so an
    address nobody anticipated fails to the state that admits we do not know.
    """
    if is_local:
        return LOCAL
    host = (address or "").strip()
    if host.count(":") == 1:  # host:port — a bare IPv6 literal has more, so it keeps its colons
        host = host.rsplit(":", 1)[0]
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:  # not an IP literal (a hostname) — unprovable, and we will not resolve it
        return UNKNOWN
    return LAN if (ip.is_private or ip.is_loopback or ip.is_link_local) else CLEARNET


def topology_nodes(*, monero_route, tari_route):
    """``TOPOLOGY_NODES`` with the two relocatable nodes marked local or remote (#1040).

    monerod and tari are the only nodes an operator can run somewhere else; every other node in
    the graph is always this machine's own, so it carries no ``remote`` key at all rather than a
    redundant ``False`` the diagram would then have to decide not to draw.

    Takes the hop's ROUTE rather than a bool (#1350): "remote" is now every route that is not
    ``LOCAL``, so a LAN or unclassifiable node still reads as remote in the caption while the
    edge carries the finer distinction.

    Returns a COPY. The graph is built per request and the node list is a module-level constant —
    marking it in place would leak one call's topology into the next.
    """
    relocatable = {"monerod": monero_route, "tari": tari_route}
    return [
        {**n, "remote": relocatable[n["id"]] != LOCAL} if n["id"] in relocatable else n
        for n in TOPOLOGY_NODES
    ]
