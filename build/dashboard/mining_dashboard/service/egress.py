"""Egress posture (#170) — for each stack component, its outbound connections and their network
route (Tor / clearnet / local / inactive), plus a privacy roll-up.

Routes are *derived from the live config*, never hardcoded, so the panel can't drift from reality or
lie after a regression — the #160 audit's lesson (``--onion-address`` *looked* like Tor but wasn't).

Two backstops matter for whether a clearnet route is actually an IP leak:

* The **#270 egress firewall** (``DOCKER-USER``, fail-closed) DROPs non-Tor egress from the *container*
  subnet — so a container's clearnet route can't actually leave while it's on.
* It does **not** cover the **host-networked dashboard** (``network_mode: host``), whose own egress
  (XvB stats fetch, update check) bypasses ``DOCKER-USER`` entirely. Those rely solely on their
  SOCKS config — a clearnet route there is a real leak regardless of the firewall.

So a connection is a *leak* only when its route is clearnet AND it isn't neutralised by a backstop.
"""

from mining_dashboard.config import config

TOR = "tor"
CLEARNET = "clearnet"
LOCAL = "local"
INACTIVE = "inactive"


def _xvb_route(xvb_enabled, xvb_tor):
    if not xvb_enabled:
        return INACTIVE
    return TOR if xvb_tor else CLEARNET


def compute_egress_posture(
    *,
    firewall,
    p2pool_clearnet,
    xvb_enabled,
    xvb_tor,
    monero_clearnet_sync,
    tari_clearnet_sync,
    remote_monero,
):
    """Pure derivation of the egress posture from config knobs. Returns ``{components, summary}``."""
    xvb = _xvb_route(xvb_enabled, xvb_tor)

    # ``firewalled``: is this component's egress on the container subnet the #270 firewall guards?
    # The dashboard is host-networked, so its own outbound traffic is NOT covered.
    components = [
        {
            "name": "monerod",
            "firewalled": True,
            "conns": [
                {"to": "Monero P2P / tx relay", "route": TOR},
                *(
                    [{"to": "initial block download (clearnet sync)", "route": CLEARNET}]
                    if monero_clearnet_sync
                    else []
                ),
            ],
        },
        {
            "name": "p2pool",
            "firewalled": True,
            "conns": [
                {"to": "sidechain P2P peers", "route": CLEARNET if p2pool_clearnet else TOR},
                {"to": "monerod RPC/ZMQ", "route": CLEARNET if remote_monero else LOCAL},
            ],
        },
        {
            "name": "tari",
            "firewalled": True,
            "conns": [
                {"to": "Tari P2P transport", "route": TOR},
                # dns_seeds=[] (#162); onion peer seeds resolve via Tor — no clearnet DNS.
                {"to": "DNS resolution", "route": LOCAL},
                *(
                    [{"to": "initial sync (clearnet)", "route": CLEARNET}]
                    if tari_clearnet_sync
                    else []
                ),
            ],
        },
        {
            "name": "xmrig-proxy",
            "firewalled": True,
            "conns": [
                {"to": "upstream pool (local p2pool stratum)", "route": LOCAL},
                # XvB donation mining dials na.xmrvsbeast.com via the proxy's per-pool socks5 (#166).
                {"to": "XvB donation pool", "route": xvb},
                {"to": "dev donation", "route": INACTIVE},  # --donate-level 0 (#166)
            ],
        },
        {
            "name": "dashboard",
            "firewalled": False,  # host-networked — bypasses the #270 DOCKER-USER firewall
            "conns": [
                {"to": "XvB stats (xmrvsbeast.com)", "route": xvb},  # socks5h when on (#163)
                {"to": "update check (github)", "route": TOR},  # socks5h, #224
            ],
        },
        {
            "name": "caddy",
            "firewalled": True,
            "conns": [{"to": "TLS (internal CA, no ACME)", "route": LOCAL}],
        },
    ]

    leaks = 0  # clearnet egress that actually exposes the host IP
    blocked = 0  # clearnet route a container is configured for, but the firewall DROPs it
    for comp in components:
        for conn in comp["conns"]:
            if conn["route"] != CLEARNET:
                continue
            if comp["firewalled"] and firewall:
                conn["blocked_by_firewall"] = True
                blocked += 1
            else:
                leaks += 1

    if leaks:
        label = f"{leaks} clearnet egress path(s) exposing your IP"
    elif blocked:
        label = f"All egress via Tor ({blocked} clearnet path(s) blocked by the egress firewall)"
    else:
        label = "All egress via Tor"

    return {
        "components": components,
        "summary": {
            "firewall": firewall,
            "leaks": leaks,
            "blocked_by_firewall": blocked,
            "all_tor": leaks == 0,
            "level": "ok" if leaks == 0 else "warn",
            "label": label,
        },
    }


def egress_posture_from_config():
    """Build the posture from the live dashboard config (values pithead rendered into the env)."""
    return compute_egress_posture(
        firewall=config.TOR_EGRESS_FIREWALL,
        p2pool_clearnet=config.P2POOL_CLEARNET,
        xvb_enabled=config.ENABLE_XVB,
        xvb_tor=config.XVB_TOR_ENABLED,
        monero_clearnet_sync=config.MONERO_CLEARNET_SYNC,
        tari_clearnet_sync=config.TARI_CLEARNET_SYNC,
        remote_monero=config.MONERO_NODE_HOST != config.LOCAL_MONERO_HOST,
    )
