# --- Tor-only egress enforcement (#270) ---------------------------------------------------------
# Fail-closed host firewall so a misconfigured/buggy bridge daemon (monerod/p2pool/tari/xmrig-proxy)
# CAN'T leak the home IP: each may reach the LAN, the other containers and the Tor SOCKS, but any
# DIRECT clearnet dial is DROPPED — only the `tor` container reaches the internet. Rules live in
# Docker's DOCKER-USER chain (preserved across Docker restarts), installed BEFORE containers start on
# every path that brings a clearnet-capable app up — `up`, `upgrade`, `apply`, `reset-dashboard` (so
# there is no startup window to grandfather a leak past) — and removed at `down`. Needs
# root (sudo), like the GRUB/HugePages steps. The allow-set is IPv4 (mining_net is IPv4-only by
# design); the nft backend also fences IPv6 off the mining bridge if mining_net ever gains a v6
# subnet, so the backstop can't silently fail open. Opt out with
# network.tor_egress_firewall=false. Proven by tests/integration/benchmarks/bench-verify-egress.sh.
# See docs/privacy.md.
#
# Two enforcement backends, one allow-set. Docker adds a `FORWARD -> DOCKER-USER` jump when it
# creates a network, so on the DIY/Docker channel the rules live in DOCKER-USER (iptables). The
# appliance runs podman + netavark, which never adds that jump — DOCKER-USER is orphaned there and
# the DROP never fires. On the podman path we instead install an independent `inet pithead_egress`
# nftables table hooked at forward priority -5 (ahead of netavark's priority-0 accept), owning no
# chain shared with netavark so it survives netavark reprogramming its own table. apply/remove/doctor
# all branch on container_engine.
TOR_EGRESS_TAG="pithead-tor-egress"
TOR_EGRESS_NFT_TABLE="pithead_egress"

# Ordered iptables rule bodies (no chain/comment) for <subnet> <tor_ip>. Pure (args only) so it
# unit-tests; ACCEPTs first, DROP last — the order is load-bearing.
tor_egress_rules() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2"
    printf '%s\n' \
        "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" \
        "-s $tor_ip -j ACCEPT" \
        "-s $subnet -d 10.0.0.0/8 -j ACCEPT" \
        "-s $subnet -d 172.16.0.0/12 -j ACCEPT" \
        "-s $subnet -d 192.168.0.0/16 -j ACCEPT" \
        "-s $subnet -d 100.64.0.0/10 -j ACCEPT" \
        "-s $subnet -j DROP"
}

# Full `nft -f` ruleset for the appliance/netavark path — same allow-set as tor_egress_rules, in
# native nftables. Pure (args only) so it unit-tests. `add`+`delete` before the table body is the
# canonical atomic idempotent-replace: `add table` no-ops if it already exists, `delete` then clears
# it, and the block recreates it fresh — the whole file loads as one transaction. The base chain is
# hooked at forward priority -5 so it evaluates before netavark's priority-0 blanket accept; a `drop`
# there is terminal across the ruleset. accepts come first so LAN/Tor/established traffic skips the
# final subnet-wide drop, mirroring the iptables order.
#
# The optional third arg is the mining bridge interface. mining_net is IPv4-only by design, so it is
# empty on every normal apply and the ruleset stays v4-only. If mining_net ever gains an IPv6 subnet
# the caller resolves the bridge and passes it here, which appends the v6 fail-closed backstop: there
# is no assigned v6 range to source-match, so the drop is keyed on the mining bridge INTERFACE — the
# host's own IPv6 forwarding on every other interface is left untouched.
render_tor_egress_nft() { # <subnet> <tor_ip> [<mining_bridge>]
    local subnet="$1" tor_ip="$2" br="${3:-}"
    printf '%s\n' \
        "add table inet $TOR_EGRESS_NFT_TABLE" \
        "delete table inet $TOR_EGRESS_NFT_TABLE" \
        "table inet $TOR_EGRESS_NFT_TABLE {" \
        "  chain forward {" \
        "    type filter hook forward priority -5; policy accept;" \
        "    ct state established,related accept" \
        "    ip saddr $tor_ip accept" \
        "    ip saddr $subnet ip daddr 10.0.0.0/8 accept" \
        "    ip saddr $subnet ip daddr 172.16.0.0/12 accept" \
        "    ip saddr $subnet ip daddr 192.168.0.0/16 accept" \
        "    ip saddr $subnet ip daddr 100.64.0.0/10 accept" \
        "    ip saddr $subnet drop"
    # IPv6 backstop, only when mining_net actually has v6 (br set). ct established,related above is
    # family-agnostic and already spares return traffic; here we allow the v6 LAN (ULA fc00::/7 +
    # link-local fe80::/10) off the mining bridge and drop everything else it originates. Scoped to
    # iifname so it can never touch v6 forwarded from any other interface.
    if [ -n "$br" ]; then
        printf '%s\n' \
            "    iifname \"$br\" ip6 daddr fc00::/7 accept" \
            "    iifname \"$br\" ip6 daddr fe80::/10 accept" \
            "    iifname \"$br\" meta nfproto ipv6 drop"
    fi
    printf '%s\n' \
        "  }" \
        "}"
}

# Resolve the mining bridge interface IFF mining_net carries an IPv6 subnet — both come from the same
# `podman network inspect`, so whenever v6 is present the interface name is too. Prints the bridge
# name for the v6 backstop; prints nothing when mining_net is IPv4-only (the normal case) or absent
# (a first-ever `up`, where the firewall installs before compose creates the network). Sole tricky
# case — a v6 subnet present but no resolvable interface — is signalled by rc 3 so the caller can
# refuse rather than install a v4-only firewall it would wrongly call fail-closed.
mining_net_ipv6_bridge() {
    local inspect v6 br
    inspect=$(podman network inspect mining_net 2>/dev/null) || return 0
    v6=$(printf '%s' "$inspect" | jq -r '[.[0].subnets[]?.subnet | select(test(":"))][0] // empty' 2>/dev/null)
    [ -n "$v6" ] || return 0
    br=$(printf '%s' "$inspect" | jq -r '.[0].network_interface // empty' 2>/dev/null)
    [ -n "$br" ] || return 3
    printf '%s' "$br"
}

# Remove every rule we previously installed — idempotent, config-agnostic, engine-agnostic. Clears
# BOTH backends so a re-apply (or an engine change) can't leave a stale set behind: drop the nft
# table if present, then delete the tagged DOCKER-USER rules if present.
remove_tor_egress_firewall() {
    if command -v nft >/dev/null 2>&1; then
        sudo nft delete table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null || true
    fi
    command -v iptables >/dev/null 2>&1 || return 0
    local saved match line
    saved=$(sudo iptables-save 2>/dev/null) || return 0
    # Our tagged DOCKER-USER rules (empty if none). `|| true` so a no-match grep (rc 1, under
    # `set -e`/pipefail) doesn't abort — removal is best-effort + idempotent.
    match=$(printf '%s\n' "$saved" | grep -- '^-A DOCKER-USER' | grep -F -- "$TOR_EGRESS_TAG") || true
    [ -n "$match" ] || return 0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086  # intentional word-splitting of the saved rule spec
        sudo iptables -D DOCKER-USER ${line#-A DOCKER-USER } 2>/dev/null || true
    done <<<"$match"
    return 0
}

# Install (or re-install, idempotently) the fail-closed Tor-only egress rules. Reads the toggle +
# subnet from .env so it works in the `up` path (where config.json isn't re-parsed). Branches to the
# engine's forward-hook mechanism: nftables under podman/netavark, DOCKER-USER under Docker.
apply_tor_egress_firewall() {
    local enabled subnet tor_ip
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    [ -n "$enabled" ] || enabled=true
    remove_tor_egress_firewall # clear stale rules so a re-apply is idempotent
    if [ "$(normalize_bool "$enabled")" != "true" ]; then
        warn "Tor-only egress firewall is OFF (network.tor_egress_firewall=false) — a misconfigured app could reach clearnet."
        return 0
    fi
    subnet=$(env_get NETWORK_SUBNET 2>/dev/null)
    [ -n "$subnet" ] || subnet="172.28.0.0/24"
    tor_ip=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$tor_ip" ] || tor_ip="172.28.0"
    tor_ip="${tor_ip}.25"
    if [ "$(container_engine)" = "podman" ]; then
        apply_tor_egress_nft "$subnet" "$tor_ip"
    else
        apply_tor_egress_iptables "$subnet" "$tor_ip"
    fi
}

# Appliance/netavark path: load the independent nft table (atomic, idempotent-replace).
apply_tor_egress_nft() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" br rc
    if ! command -v nft >/dev/null 2>&1; then
        warn "nftables not found — cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 0
    fi
    # mining_net is IPv4-only by design, so br is empty and the ruleset stays v4-only. If it ever
    # gains an IPv6 subnet we key a v6 fail-closed drop on its bridge interface. rc 3 means v6 is
    # present but the bridge couldn't be resolved — refuse rather than load a v4-only firewall we'd
    # then wrongly report as fail-closed (a v6 clearnet leak would fall through policy accept).
    br=$(mining_net_ipv6_bridge)
    rc=$?
    if [ "$rc" -eq 3 ]; then
        warn "mining_net has an IPv6 subnet but its bridge interface could not be resolved — REFUSING to install a v4-only egress firewall that would leave IPv6 clearnet un-fenced. Recreate mining_net or set network.tor_egress_firewall=false to acknowledge."
        return 0
    fi
    if ! render_tor_egress_nft "$subnet" "$tor_ip" "$br" | sudo nft -f - 2>/dev/null; then
        warn "Could not install the Tor-egress firewall (needs root + nftables). Stack runs, but clearnet egress is NOT fail-closed."
        return 0
    fi
    log "Tor-only egress enforced: clearnet dials from $subnet${br:+ (IPv4) and via $br (IPv6)} dropped except via Tor ($tor_ip)."
}

# DIY/Docker path: insert the tagged rules into DOCKER-USER, which Docker jumps to from FORWARD.
apply_tor_egress_iptables() { # <subnet> <tor_ip>
    local subnet="$1" tor_ip="$2" pos=1 rule
    if ! command -v iptables >/dev/null 2>&1; then
        warn "iptables not found — cannot enforce Tor-only egress. The stack runs, but clearnet egress is NOT fail-closed."
        return 0
    fi
    # DOCKER-USER may not exist yet on a first-ever `up` (Docker creates it with its first network).
    # Pre-create it so installing here — before compose runs — succeeds; Docker adopts the existing
    # chain and adds the FORWARD jump. Harmless (-N fails with rc 1) once the chain is already there.
    sudo iptables -N DOCKER-USER 2>/dev/null || true
    while IFS= read -r rule; do
        # shellcheck disable=SC2086  # intentional word-splitting of the rule body
        if ! sudo iptables -I DOCKER-USER "$pos" -m comment --comment "$TOR_EGRESS_TAG" $rule 2>/dev/null; then
            warn "Could not install the Tor-egress firewall (needs root + iptables). Stack runs, but clearnet egress is NOT fail-closed."
            remove_tor_egress_firewall
            return 0
        fi
        pos=$((pos + 1))
    done < <(tor_egress_rules "$subnet" "$tor_ip")
    log "Tor-only egress enforced: clearnet dials from $subnet dropped except via Tor ($tor_ip)."
}
