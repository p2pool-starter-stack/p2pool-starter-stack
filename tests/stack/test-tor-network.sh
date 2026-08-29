# shellcheck shell=bash
#
# Tor-network domain (#1105 Phase 1, develop-v2 lane): the Tor-only egress boundary and the
# Tor<->clearnet transport switch — tor_egress_rules + render_tor_egress_nft (both the legacy
# iptables/DOCKER-USER path and the v2 nftables/podman path, including the IPv6 backstop and its
# refusal when the bridge can't be resolved, #855/#858), apply/remove_tor_egress_firewall end to
# end (#270), the regression that every command installs the firewall BEFORE compose so no
# clearnet-capable container ever starts unguarded (#276/#291), the clearnet-initial-sync helpers
# and render on both chains including the contradiction warning against a firewall that would just
# drop the clearnet dials anyway (#183 — the map's code-read: this is the Tor<->clearnet transport
# switch, kept together with the egress rules rather than split to the monero/tari file), the node
# configs' clearnet-DNS-egress guarantees (#161 monerod, #162 tari), tor.auto_heal (#424), the tor
# container's own entrypoint rendering both the dashboard's opt-in onion vhost and the per-node
# inbound onions (#343/#103), and pithead's onion-provisioning gate that never blocks on a remote
# node's unpublished onion (#103).
# Sourced by tests/stack/run.sh.
#
# Re-derivations (the sandbox-builder WALLET/$V trap — see #1305, still open on this lane):
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; the "config validation" black-box calls
#   it once, ahead of the two sections below that read them — that section lives in test-config.sh,
#   sourced ahead of this file (a generic multi-field validator, not tor-specific).
#   build_val_sandbox() is idempotent (a fixed $SANDBOX/val path, mkdir -p, template copies), so
#   calling it again here is a safe no-op re-affirm as currently sourced, and correct on its own if
#   a future reorder ever moves this file's source line earlier than that section.
# - $DOCKER_LOG: the "apply preserves secrets + propagates" black-box sets it ($V/docker.log); it lives
#   in test-secrets.sh, sourced ahead of this file (a generic multi-key regression, not tor-specific).
# No section here reads $C — the control-channel sandbox is untouched by this cut.
build_val_sandbox
DOCKER_LOG="$V/docker.log"

echo "== unit: tor_egress_rules — fail-closed Tor-only egress ruleset (#270) =="
TER=$(run_sourced "$SANDBOX" tor_egress_rules 172.28.0.0/24 172.28.0.25)
assert_contains "ESTABLISHED/RELATED accepted (published-port replies, ongoing flows)" "$TER" "conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
assert_contains "only Tor (.25) may egress to the internet" "$TER" "-s 172.28.0.25 -j ACCEPT"
assert_contains "inter-container + 172.16/12 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT"
assert_contains "10/8 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT"
assert_contains "192.168/16 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT"
assert_eq "the clearnet DROP is the FINAL rule (fail-closed)" "$(printf '%s\n' "$TER" | tail -1)" "-s 172.28.0.0/24 -j DROP"
assert_contains "honours a custom subnet/prefix (#180)" "$(run_sourced "$SANDBOX" tor_egress_rules 172.30.5.0/24 172.30.5.25)" "-s 172.30.5.0/24 -j DROP"

echo "== unit: render_tor_egress_nft — same allow-set as nftables for the netavark path (#855) =="
# The appliance runs podman+netavark, whose FORWARD hook is served by `table inet netavark`; nothing
# jumps to the iptables DOCKER-USER chain, so the Docker-path rules install into a chain no packet
# traverses (the fail-open bug). This backend puts the DROP in an independent nft table hooked at
# forward, which forwarded packets DO pass through.
NFTR=$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25)
assert_contains "hooks the chain at forward so packets actually traverse it" "$NFTR" "hook forward"
assert_contains "priority -5 runs ahead of netavark's priority-0 blanket accept" "$NFTR" "priority -5"
assert_contains "ESTABLISHED/RELATED accepted (return + ongoing flows)" "$NFTR" "ct state established,related accept"
assert_contains "only Tor (.25) may egress to the internet" "$NFTR" "ip saddr 172.28.0.25 accept"
assert_contains "inter-container + 172.16/12 LAN allowed" "$NFTR" "ip saddr 172.28.0.0/24 ip daddr 172.16.0.0/12 accept"
assert_contains "100.64/10 CGNAT LAN allowed" "$NFTR" "ip saddr 172.28.0.0/24 ip daddr 100.64.0.0/10 accept"
assert_eq "the clearnet DROP is the FINAL rule before the chain closes (fail-closed)" "$(printf '%s\n' "$NFTR" | grep -E 'accept|drop' | tail -1)" "    ip saddr 172.28.0.0/24 drop"
# add+delete before the body is the atomic idempotent-replace — a re-apply can't stack duplicates.
assert_contains "idempotent-replace: add table first" "$NFTR" "add table inet pithead_egress"
assert_contains "idempotent-replace: delete before recreating" "$NFTR" "delete table inet pithead_egress"
assert_contains "honours a custom subnet/prefix (#180)" "$(run_sourced "$SANDBOX" render_tor_egress_nft 172.30.5.0/24 172.30.5.25)" "ip saddr 172.30.5.0/24 drop"

echo "== unit: render_tor_egress_nft — IPv6 backstop only when the mining bridge is passed (#858) =="
# mining_net is IPv4-only by design, so a bare render (no bridge arg) must stay v4-only — no ip6
# rule can appear, or it would fence traffic that doesn't exist and risk the host's own v6.
assert_not_contains "no bridge arg → no IPv6 rule at all (v4-only, the normal case)" "$NFTR" "ip6"
# When mining_net gains v6 the caller resolves the bridge and passes it; the v6 fail-closed drop is
# keyed on that interface (there's no v6 range to source-match) and mirrors the v4 LAN allow-set.
NFTR6=$(run_sourced "$SANDBOX" render_tor_egress_nft 172.28.0.0/24 172.28.0.25 podman1)
assert_contains "v6 drop is scoped to the mining bridge, never the whole forward path" "$NFTR6" 'iifname "podman1" meta nfproto ipv6 drop'
assert_contains "v6 LAN ULA (fc00::/7) allowed off the bridge" "$NFTR6" 'iifname "podman1" ip6 daddr fc00::/7 accept'
assert_contains "v6 link-local (fe80::/10) allowed off the bridge" "$NFTR6" 'iifname "podman1" ip6 daddr fe80::/10 accept'
assert_eq "the IPv6 drop is the FINAL rule before the chain closes (fail-closed)" "$(printf '%s\n' "$NFTR6" | grep -E 'accept|drop' | tail -1)" '    iifname "podman1" meta nfproto ipv6 drop'
assert_contains "the v4 allow-set is unchanged when v6 is added" "$NFTR6" "ip saddr 172.28.0.0/24 drop"

echo "== unit: mining_net_ipv6_bridge — resolve bridge only when mining_net has a v6 subnet (#858) =="
# Both the v6 subnet and the interface name come from the SAME `podman network inspect`, so whenever
# v6 is present the bridge is too. Stub podman to answer network inspect; jq is real.
NB="$SANDBOX/netbr"
mkdir -p "$NB/bin"
# v4-only mining_net → no bridge emitted, rc 0 (the normal appliance state).
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
[ "$1" = "network" ] && [ "$2" = "inspect" ] || { echo "[]"; exit 0; }
echo '[{"name":"mining_net","network_interface":"podman1","subnets":[{"subnet":"172.28.0.0/24"}]}]'
PM
chmod +x "$NB/bin/podman"
assert_eq "v4-only mining_net → no bridge (stays v4-only), rc 0" "$(
    PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge
    echo " rc=$?"
)" " rc=0"
# dual-stack mining_net → the bridge name is emitted for the v6 backstop.
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
echo '[{"name":"mining_net","network_interface":"podman4","subnets":[{"subnet":"172.28.0.0/24"},{"subnet":"fd00:dead:beef::/64"}]}]'
PM
assert_eq "dual-stack mining_net → emits the resolved bridge name" "$(PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge)" "podman4"
# pathological: v6 subnet present but no resolvable interface → rc 3, so apply refuses (fail-closed).
cat >"$NB/bin/podman" <<'PM'
#!/usr/bin/env bash
echo '[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'
PM
assert_eq "v6 present but no interface → rc 3 (caller refuses, never installs a v4-only firewall)" "$(
    PATH="$NB/bin:$PATH" run_sourced "$NB" mining_net_ipv6_bridge >/dev/null
    echo $?
)" "3"

echo "== black-box: apply_tor_egress_firewall routes to nftables under podman (#855) =="
# PITHEAD_ENGINE=podman must send apply down the nft path (loaded via `nft -f -`), NOT the orphaned
# DOCKER-USER path. Capture what gets piped to nft and assert the fail-closed ruleset landed.
NFW="$SANDBOX/nfw"
mkdir -p "$NFW/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$NFW/bin/sudo"
# nft -f -: record stdin (the ruleset). Any other invocation (e.g. remove's delete) just logs args.
cat >"$NFW/bin/nft" <<NFT
#!/usr/bin/env bash
if [ "\$1" = "-f" ]; then cat >>"$NFW/nft.ruleset"; else printf '%s\n' "\$*" >>"$NFW/nft.log"; fi
exit 0
NFT
# an iptables that FAILS loudly if apply ever calls it under podman — proves we took the nft branch.
printf '#!/usr/bin/env bash\necho "ILLEGAL iptables call on podman path: $*" >>"%s/nft.log"\nexit 1\n' "$NFW" >"$NFW/bin/iptables"
chmod +x "$NFW/bin/sudo" "$NFW/bin/nft" "$NFW/bin/iptables"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
: >"$NFW/nft.log"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
assert_contains "podman path loads the nft table with the fail-closed DROP" "$(cat "$NFW/nft.ruleset")" "ip saddr 172.28.0.0/24 drop"
assert_contains "podman path hooks the chain at forward" "$(cat "$NFW/nft.ruleset")" "hook forward"
assert_not_contains "podman path never touches the orphaned DOCKER-USER chain" "$(cat "$NFW/nft.log")" "ILLEGAL iptables"
# opt-out on the podman path installs no table either.
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opt-out on the podman path loads no nft ruleset" "$(cat "$NFW/nft.ruleset")" ""
# The two blocks above never stub podman, so mining_net_ipv6_bridge finds no v6 → the loaded ruleset
# stays strictly v4 (no over-block of IPv6 that doesn't exist yet).
assert_not_contains "v4-only mining_net → the loaded ruleset carries no IPv6 rule" "$(
    printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
    : >"$NFW/nft.ruleset"
    PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
    cat "$NFW/nft.ruleset"
)" "ip6"

echo "== black-box: apply on a dual-stack mining_net loads the IPv6 backstop (#858) =="
# Same harness, now with a podman that reports mining_net carrying a v6 subnet. apply must resolve
# the bridge and pipe an interface-scoped v6 drop into nft alongside the v4 rules.
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","network_interface":"podman4","subnets":[{"subnet":"172.28.0.0/24"},{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$NFW/bin/podman"
chmod +x "$NFW/bin/podman"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$NFW/.env"
: >"$NFW/nft.ruleset"
PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall >/dev/null 2>&1
dsrules="$(cat "$NFW/nft.ruleset")"
assert_contains "dual-stack apply keeps the v4 fail-closed DROP" "$dsrules" "ip saddr 172.28.0.0/24 drop"
assert_contains "dual-stack apply adds the bridge-scoped IPv6 DROP" "$dsrules" 'iifname "podman4" meta nfproto ipv6 drop'

echo "== black-box: apply REFUSES a v4-only firewall when mining_net has un-resolvable v6 (#858) =="
# v6 subnet present but no interface name → mining_net_ipv6_bridge returns rc 3. apply must warn and
# load NOTHING rather than install a v4-only table it would wrongly report as fail-closed.
printf '#!/usr/bin/env bash\necho '"'"'[{"name":"mining_net","subnets":[{"subnet":"fd00:dead:beef::/64"}]}]'"'"'\n' >"$NFW/bin/podman"
: >"$NFW/nft.ruleset"
refuse_out="$(PITHEAD_ENGINE=podman PATH="$NFW/bin:$PATH" run_sourced "$NFW" apply_tor_egress_firewall 2>&1)"
assert_contains "warns loudly that it is REFUSING (fail-closed by refusal)" "$refuse_out" "REFUSING"
assert_eq "refusal loads no nft ruleset at all (no half-open v4-only firewall)" "$(cat "$NFW/nft.ruleset")" ""
rm -f "$NFW/bin/podman" # restore the v4-only harness for anything downstream

echo "== black-box: apply/remove_tor_egress_firewall via stubbed iptables (Docker path, #270) =="
FW="$SANDBOX/fw"
mkdir -p "$FW/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FW/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$FW" >"$FW/bin/iptables"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/iptables-save" # no pre-existing rules
# remove_tor_egress_firewall probes nft on every path (it clears BOTH backends); stub it inert so the
# Docker-path black-box stays hermetic and never touches the host's real nftables.
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/nft"
chmod +x "$FW/bin/sudo" "$FW/bin/iptables" "$FW/bin/iptables-save" "$FW/bin/nft"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FW/.env"
: >"$FW/ipt.log"
PITHEAD_ENGINE=docker PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
iptlog="$(cat "$FW/ipt.log" 2>/dev/null)"
assert_contains "installs the fail-closed clearnet DROP, tagged" "$iptlog" "-I DOCKER-USER 7 -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "exempts the Tor container" "$iptlog" "-m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
# Pre-creates DOCKER-USER so the BEFORE-compose install at `up` can't miss on a first-ever start where
# Docker hasn't created the chain yet — closes the startup window that grandfathered leaks (#276).
assert_contains "pre-creates the DOCKER-USER chain (idempotently)" "$iptlog" "-N DOCKER-USER"
# opt-out: TOR_EGRESS_FIREWALL=false installs nothing
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$FW/.env"
: >"$FW/ipt.log"
PITHEAD_ENGINE=docker PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opt-out (network.tor_egress_firewall=false) installs no DROP" "$(grep -c 'DROP' "$FW/ipt.log" 2>/dev/null)" "0"
# install-failure rollback (#270): if an `iptables -I` insert fails partway, apply must NOT leave a
# half-open firewall it believes is fail-closed — it warns and rolls back via remove_tor_egress_firewall.
# Stub: -N/-D succeed but every -I insert fails (rc 1). remove runs once up-front (idempotent clear)
# and again on rollback, so iptables-save fires TWICE — that second call is the proof the rollback ran.
FF="$SANDBOX/fwfail"
mkdir -p "$FF/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FF/bin/sudo"
cat >"$FF/bin/iptables" <<'IPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IPT_LOG"
case "$1" in -I) exit 1 ;; esac # every insert fails midway
exit 0
IPT
printf '#!/usr/bin/env bash\nprintf "save\\n" >>"$IPT_LOG"\nexit 0\n' >"$FF/bin/iptables-save"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FF/bin/nft" # inert: remove probes nft on the Docker path too
chmod +x "$FF/bin/sudo" "$FF/bin/iptables" "$FF/bin/iptables-save" "$FF/bin/nft"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FF/.env"
: >"$FF/ipt.log"
fwfail_out="$(PITHEAD_ENGINE=docker PATH="$FF/bin:$PATH" IPT_LOG="$FF/ipt.log" run_sourced "$FF" apply_tor_egress_firewall 2>&1)"
fwfail_rc=$?
assert_rc "insert failure degrades gracefully (stack still runs, rc 0)" "$fwfail_rc" "0"
assert_contains "insert failure warns clearnet is NOT fail-closed" "$fwfail_out" "NOT fail-closed"
assert_eq "insert failure rolls back the partial firewall (remove reruns -> save x2)" "$(grep -c '^save$' "$FF/ipt.log")" "2"
# remove: `down` (and every re-apply) strips ONLY our tagged rules — this removal is the precondition
# for the #291 down->upgrade/apply window, so prove it deletes the tags and spares foreign DOCKER-USER
# rules. iptables-save replays two tagged rules + one foreign rule; remove must -D the tagged pair only.
RM="$SANDBOX/rm"
mkdir -p "$RM/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$RM/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$RM" >"$RM/bin/iptables"
cat >"$RM/bin/iptables-save" <<'SAVE'
#!/usr/bin/env bash
cat <<'RULES'
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT
-A DOCKER-USER -j RETURN
RULES
SAVE
# remove is engine-agnostic: it drops the nft table AND strips the iptables tags, so a stale set can't
# survive a re-apply or an engine change. Log nft calls to prove it tears down the netavark backend too.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/nft.log"\nexit 0\n' "$RM" >"$RM/bin/nft"
chmod +x "$RM/bin/sudo" "$RM/bin/iptables" "$RM/bin/iptables-save" "$RM/bin/nft"
: >"$RM/ipt.log"
: >"$RM/nft.log"
PATH="$RM/bin:$PATH" run_sourced "$RM" remove_tor_egress_firewall >/dev/null 2>&1
rmlog="$(cat "$RM/ipt.log" 2>/dev/null)"
assert_contains "down removes the tagged clearnet DROP" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "down removes the tagged Tor-exempt ACCEPT" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
assert_not_contains "down leaves foreign DOCKER-USER rules untouched" "$rmlog" "RETURN"
assert_contains "down also drops the nft egress table (netavark backend)" "$(cat "$RM/nft.log" 2>/dev/null)" "delete table inet pithead_egress"

echo "== regression: every command installs the Tor-egress firewall BEFORE compose (#291) =="
# The firewall must go in BEFORE any clearnet-capable container starts, on EVERY path that brings one
# up (#276 closed the window for stack_up; #291 + this change close it for upgrade/apply/reset). If a
# container starts first, the leading ESTABLISHED rule grandfathers its clearnet dial past the DROP.
# Each case neutralises the command's preamble and records the order of the two load-bearing ops; the
# firewall sentinel MUST precede the compose sentinel. fw_then_compose() extracts just those two from
# whatever else the function prints (warnings, banners) so the assert is exact.

# up: the reference path #276 fixed — pin it too so a future reorder of stack_up is caught here.
up_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    stack_up
)
assert_eq "up applies the firewall before 'compose up' (#276)" "$(fw_then_compose "$up_order")" "firewall,compose,"

upg_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$upg_order")" "firewall,compose,"

# #355: `upgrade` must run ensure_onion_password BEFORE parse_and_validate_config, so enabling the
# dashboard onion (#343) with no password auto-generates one (login: admin) instead of failing the
# "onion needs a 16+ char password" validation. setup/apply already do; upgrade didn't (prod hit it).
# This exercises the command-flow ORDER — the wiring the unit test of ensure_onion_password can't see.
upg_onion_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { echo onionpw; }
    parse_and_validate_config() { echo validate; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    stack_upgrade
)
assert_eq "upgrade runs ensure_onion_password before config validation (#355)" \
    "$(printf '%s\n' "$upg_onion_order" | grep -xE 'onionpw|validate' | tr '\n' ',')" "onionpw,validate,"

# #376: on a release install, `upgrade` must verify the image signatures BEFORE anything is pulled
# or recreated. If a refactor drops or reorders the verify_release_images call, "verify" goes
# missing or lands after "compose" and this fails — the wiring half of the fail-closed guarantee
# (the decision itself is black-boxed below).
upg_sig_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade verifies release-image signatures before 'compose up' (#376)" \
    "$(printf '%s\n' "$upg_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

# #452: the FIRST-install `up` must also verify before it pulls — the same wiring guarantee as
# upgrade. A fresh release install's first `up` is where the 5 images are first fetched; if verify
# goes missing or lands after "compose", this fails.
up_sig_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    print_first_run_epilogue() { :; }
    log() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    stack_up
)
assert_eq "first-install up verifies release-image signatures before 'compose up' (#452)" \
    "$(printf '%s\n' "$up_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

# apply had the same after-compose ordering bug as #272's stack_upgrade — fixed alongside #291. Take
# the no-change-but-incomplete-marker retry path so apply recreates containers without the interactive
# diff (env_changed_keys returns nothing; a pre-seeded .apply-incomplete marker forces the retry).
apply_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034  # read by the sourced apply()'s "not provisioned" guard, unseen here
    P2POOL_ONION=onion
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    is_deployed() { return 0; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    env_changed_keys() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    : >".env.apply-incomplete" # force the retry path
    apply
)
assert_eq "apply applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$apply_order")" "firewall,compose,"

# reset-dashboard recreates p2pool (clearnet-capable); on a `down` stack it must install the firewall
# first or p2pool comes up with no firewall at all. -y skips the destructive confirm; the docker stub
# emits the compose sentinel only for the `compose up` it ends on.
rd_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    env_get() { echo "/nonexistent/reset-$1"; } # non-existent dirs -> rm skipped
    assert_safe_dir() { :; }
    mkdir() { :; }
    sudo() { :; }
    log() { :; }
    docker() {
        [ "$1 $2" = "compose up" ] && echo compose
        return 0
    }
    apply_tor_egress_firewall() { echo firewall; }
    reset_dashboard -y
)
assert_eq "reset-dashboard applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$rd_order")" "firewall,compose,"

echo "== unit: clearnet initial sync helpers (#183) =="
# normalize_bool: 1/true/yes/on (any case) => true; everything else (incl. empty) => false, matching
# the dashboard's MONERO_PRUNE truthiness so a config bool reads the same on both sides.
for v in true 1 YES On TRUE; do
    assert_eq "normalize_bool '$v' => true" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "true"
done
for v in false 0 no off "" garbage; do
    assert_eq "normalize_bool '${v:-<empty>}' => false" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "false"
done
# Monero render transform (#183): exercise the REAL container entrypoint function. Sourced with
# PITHEAD_TEST_SOURCE=1 it defines the helpers and stops before envsubst/exec. The transform must
# strip the Tor P2P proxy + lower out-peers, while KEEPING tx-proxy on Tor.
MONT="$SANDBOX/mon-clearnet.conf"
cp "$ROOT/build/monero/bitmonero.conf.template" "$MONT"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/entrypoint.sh"
    apply_clearnet_initial_sync "$MONT"
)
case "$(grep -E '^proxy=' "$MONT" || true)" in
"") ok "monero clearnet: P2P proxy= line stripped (#183)" ;;
*) bad "monero clearnet: P2P proxy= line stripped (#183)" "still present" ;;
esac
assert_contains "monero clearnet: tx-proxy stays on Tor (#183)" "$(cat "$MONT")" "tx-proxy=tor"
# P2Pool v4.18 clearnet recommendation: out-peers 32 + the recommended priority nodes (added only in
# the clearnet window; the Tor template has neither — the #161 check below guards that).
assert_contains "monero clearnet: out-peers=32 (p2pool v4.18 rec)" "$(cat "$MONT")" "out-peers=32"
assert_contains "monero clearnet: xmrvsbeast priority node (v4.18)" "$(cat "$MONT")" "add-priority-node=p2pmd.xmrvsbeast.com:18080"
assert_contains "monero clearnet: hashvault priority node (v4.18)" "$(cat "$MONT")" "add-priority-node=nodes.hashvault.pro:18080"
# The committed template (the Tor-only default) keeps the proxy line + the Tor-tuned out-peers.
assert_contains "monero default: Tor P2P proxy present (#183)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'proxy=${NETWORK_PREFIX}.25:9050'
# #595: the template's out-peers is now config-driven (monero.out_peers, default 48 in the render).
assert_contains "monero default: out-peers config-driven for Tor (#183/#595)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'out-peers=${MONERO_OUT_PEERS}'
# Compose wires both flags into container env: monerod reads MONERO_CLEARNET_SYNC in its entrypoint;
# TARI_CLEARNET_SYNC is inert in the container but its presence makes a flag change recreate tari so
# it re-reads the host-rendered config.toml (a bind-mount content change alone won't recreate it).
assert_contains "compose passes MONERO_CLEARNET_SYNC to monerod (#183)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_CLEARNET_SYNC=${MONERO_CLEARNET_SYNC'
assert_contains "compose passes TARI_CLEARNET_SYNC to tari (#183)" "$(cat "$ROOT/docker-compose.yml")" 'TARI_CLEARNET_SYNC=${TARI_CLEARNET_SYNC'
# #595: the render chain for the out-peers knob is only complete if compose forwards it.
assert_contains "compose passes MONERO_OUT_PEERS to monerod (#595)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_OUT_PEERS=${MONERO_OUT_PEERS'

# --- Auto-transition (#234): the entrypoints gate clearnet on flag AND the absence of the
# dashboard-written marker, so a node returns to Tor on its own once synced. ---
# Monero entrypoint marker gate.
mono_active() { (
    export PITHEAD_TEST_SOURCE=1 MONERO_CLEARNET_SYNC="$1" CLEARNET_MARKER="$2"
    source "$ROOT/build/monero/entrypoint.sh"
    clearnet_sync_active
); }
if mono_active true "$SANDBOX/absent-marker"; then ok "monero clearnet ACTIVE when flag on + no marker (#234)"; else bad "monero clearnet active gate (#234)" "expected active"; fi
: >"$SANDBOX/mono.marker"
if mono_active true "$SANDBOX/mono.marker"; then bad "monero clearnet inactive once marker present (#234)" "still active"; else ok "monero clearnet INACTIVE once marker present → Tor (#234)"; fi
if mono_active false "$SANDBOX/absent-marker"; then bad "monero clearnet off when flag off (#234)" "active with flag off"; else ok "monero clearnet OFF when flag off (#234)"; fi

# Tari entrypoint renders a runtime config from the canonical Tor config; transform only when active.
TARISRC="$SANDBOX/tari-src.toml"
cp "$ROOT/build/tari/config.toml.template" "$TARISRC"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/absent-marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt.toml"
)
assert_contains "tari entrypoint clearnet: TCP transport (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'type = "tcp"'
assert_contains "tari entrypoint clearnet: DNS seed enabled (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'dns_seeds = ["seeds.tari.com"]'
: >"$SANDBOX/tari.marker"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/tari.marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt2.toml"
)
assert_contains "tari entrypoint marker→Tor: transport tor (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" 'type = "tor"'
assert_contains "tari entrypoint marker→Tor: DNS seeds empty (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" "dns_seeds = []"
assert_contains "tari entrypoint never mutates the canonical config (#234)" "$(cat "$TARISRC")" 'type = "tor"'
# Compose wires the shared marker dir into all three: dashboard rw, monerod + tari ro, + the tari
# wrapper entrypoint that chains to the upstream start_tari_app.sh.
assert_contains "compose mounts clearnet-state into monerod (#234)" "$(cat "$ROOT/docker-compose.yml")" ':/clearnet-state:ro'
assert_contains "compose wires the tari wrapper entrypoint (#234)" "$(cat "$ROOT/docker-compose.yml")" '/var/tari/config/entrypoint.sh'

echo "== node configs: no clearnet DNS egress (#161 monerod, #162 tari) =="
MONC="$ROOT/build/monero/bitmonero.conf.template"
TARC="$ROOT/build/tari/config.toml.template"
# monerod (#161): hostname priority-nodes dropped; DNS checkpoints + update check off.
case "$(cat "$MONC")" in
*xmrvsbeast.com:18080* | *nodes.hashvault.pro*) bad "monerod: priority-node hostnames dropped (#161)" "still present" ;;
*) ok "monerod: priority-node hostnames dropped (#161)" ;;
esac
case "$(grep -E '^enforce-dns-checkpointing' "$MONC" || true)" in
"") ok "monerod: enforce-dns-checkpointing removed (#161)" ;;
*) bad "monerod: enforce-dns-checkpointing removed (#161)" "still present" ;;
esac
assert_contains "monerod: DNS checkpoints disabled (#161)" "$(cat "$MONC")" "disable-dns-checkpoints=1"
assert_contains "monerod: update check disabled (#161)" "$(cat "$MONC")" "check-updates=disabled"
# tari (#162): no DNS seeds; peer_seeds onion-only; the inert check_for_updates gRPC method dropped.
assert_contains "tari: DNS seeds disabled (#162)" "$(cat "$TARC")" "dns_seeds = []"
# #271: minotari defaults proxy_bypass_for_outbound_tcp=true → it direct-dials peers advertising a bare
# /ip4 (clearnet) address, bypassing Tor. false routes every dial through the SOCKS proxy (reach those
# peers via Tor exits) — so Tari is functional AND never touches clearnet directly.
assert_contains "tari: outbound TCP dials routed via Tor SOCKS, not direct (#271)" "$(cat "$TARC")" "proxy_bypass_for_outbound_tcp = false"
case "$(grep -E '::/ip4/|::/ip6/' "$TARC" || true)" in
"") ok "tari: peer_seeds are onion-only (#162)" ;;
*) bad "tari: peer_seeds are onion-only (#162)" "clearnet /ip4//ip6/ peer seeds present" ;;
esac
case "$(grep -E 'check_for_updates' "$TARC" || true)" in
"") ok "tari: check_for_updates dropped from gRPC allow-list (#162)" ;;
*) bad "tari: check_for_updates dropped from gRPC allow-list (#162)" "still present" ;;
esac
# The Pulse (checkpoints.tari.com TXT, ~120s) is the last clearnet DNS path: the tari container's
# resolver is pointed at a dead local address so the lookup fails without a packet leaving the host
# (Tari tolerates it — returns "passed"). The container already overrode Docker's 127.0.0.11, so no
# service-discovery dependency is broken. Assert no clearnet resolvers remain on the tari service.
TARI_SVC="$(awk '/^  tari:/{f=1;print;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")"
case "$TARI_SVC" in
*1.1.1.1* | *8.8.8.8*) bad "tari: clearnet DNS resolvers removed from compose (#162)" "1.1.1.1/8.8.8.8 present" ;;
*) ok "tari: clearnet DNS resolvers removed from compose (#162)" ;;
esac
assert_contains "tari: resolver pointed at dead local sinkhole (#162)" "$TARI_SVC" "127.0.0.1"

echo "== black-box: tor.auto_heal renders to .env (#424) =="
# The dashboard's healer reads TOR_AUTO_HEAL from .env. Key absent -> off (the stack never
# restarts its privacy boundary unbidden); explicit true -> on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal defaults to off" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "false"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "tor":{"auto_heal":true}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal opt-in renders true" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "true"

echo "== black-box: clearnet initial sync render (#183) =="
# Default (no flags): both daemons stay Tor-only — .env flags are false and the rendered Tari config
# keeps the Tor transport, empty DNS seeds, and an onion public address.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "false"
assert_eq "tari clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari default: Tor transport" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "tari default: DNS seeds empty" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari default: advertises onion" "$(cat "$V/build/tari/config.toml")" "/onion3/"

# Monero clearnet ON (Tari left off): only the Monero flag flips; Tari stays Tor. The apply preview
# must spell out the clearnet exposure (a CONFIRM change — disruptive, warned ⚠ on the host CLI).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"
assert_eq "tari clearnet still false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari stays Tor when only monero is clearnet" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "apply preview warns clearnet exposure" "$out" "CLEARNET"

# Tari clearnet ON: pithead always renders the CANONICAL Tor config — the clearnet transform is
# applied per-start INSIDE the container (marker-gated, #234), so the host-rendered config.toml
# stays Tor even with the flag on. That's what lets the node return to Tor on its own after sync
# without pithead re-rendering clearnet over it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","clearnet_initial_sync":true}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "true"
assert_contains "tari host-render stays Tor even with flag on (#234)" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "tari host-render keeps DNS seeds empty (#234)" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari host-render still advertises the onion (#234)" "$(cat "$V/build/tari/config.toml")" "/onion3/"

# Truthy parse consistency (#183): a JSON string "yes" reads as enabled, like normalize_bool/MONERO_PRUNE.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":"yes"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet truthy 'yes' => true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"

# doctor flags the active clearnet sync (read-only). Re-render Tor-only first so later sections see a
# clean default, then assert doctor's WARN/OK both ways.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "doctor: OK when Tor-only (#183)" "$(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor 2>&1)" "Tor-only"

echo "== black-box: clearnet_initial_sync vs. tor_egress_firewall contradiction warning =="
# A clearnet_initial_sync flag asks a daemon to sync off-Tor; the egress firewall (default on) DROPs
# every non-Tor dial, so that combination is self-defeating (the sync just runs over Tor anyway,
# slower than intended) rather than unsafe (nothing leaks — the firewall still holds). WARN, not
# FAIL: apply must still succeed, but say so loudly. Covers the contradictory pair and all three
# non-contradictory combinations so the warning fires only where it's actually true.
CN_WARN_NEEDLE="the firewall drops the clearnet dials"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero clearnet + firewall on: apply still succeeds (warn, not fail)" "$?" "0"
assert_contains "monero clearnet + firewall on: warns" "$out" "$CN_WARN_NEEDLE"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","clearnet_initial_sync":true}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari clearnet + firewall on: apply still succeeds (warn, not fail)" "$?" "0"
assert_contains "tari clearnet + firewall on: warns" "$out" "$CN_WARN_NEEDLE"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "network":{"tor_egress_firewall":false}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_not_contains "clearnet sync + firewall OFF: no warning (not contradictory)" "$out" "$CN_WARN_NEEDLE"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_not_contains "no clearnet sync + firewall on: no warning (not contradictory)" "$out" "$CN_WARN_NEEDLE"

# p2pool compose↔image coupling fail-safe (#273): clearnet is off, so apply renders P2POOL_FLAGS with
# the #165 --socks5. doctor reads the RUNNING p2pool argv (/proc/1/cmdline, stubbed via P2POOL_PROC1)
# and must FAIL loudly if --socks5 is absent (a stale pre-#165 image silently dropping the env flags),
# and pass when it IS present. The config above (p2pool.pool=mini, clearnet default off) is reused.
dr273() { cd "$V" && P2POOL_PROC1="$1" PATH="$V/bin:$PATH" ./pithead doctor 2>&1; }
assert_contains "doctor FAILs when p2pool isn't on Tor — stale image (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --rpc-port 18081 --mini')" "STALE p2pool image"
assert_contains "doctor OK when p2pool IS routed over Tor (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor')" "routes outbound sidechain P2P via Tor"

# tor wrapper entrypoint: opt-in dashboard hidden service (#343). The HiddenService block is appended
# to the rendered torrc ONLY when DASHBOARD_ONION_ENABLED=true, targeting the bridge gateway
# (NETWORK_PREFIX.1) where Caddy binds the auth-gated onion vhost. pithead's caddy/client-auth side is
# covered above; this exercises the real container entrypoint's branch + the .1 substitution with a
# stub `tor` on PATH and the repo torrc.template (via the TORRC_TEMPLATE seam).
TOR_ENTRY="$ROOT/build/tor/entrypoint.sh"
tor_torrc() { # <DASHBOARD_ONION_ENABLED> [COMPOSE_PROFILES] -> the torrc the entrypoint would hand to `tor -f`
    local d
    d="$(mktemp -d)"
    # The stub cats the SANDBOX path, not /tmp/torrc (#1104). That is what makes the TORRC_OUT seam
    # load-bearing: if the entrypoint ignored it and wrote the host-global file, this prints nothing
    # and every assertion below goes red. Catting /tmp/torrc instead would keep passing off a stale
    # file left by an earlier run — the vacuous version of this check.
    printf '#!/bin/sh\ncat "%s"\n' "$d/torrc" >"$d/tor" # stub tor: ignore -f, print the rendered file
    chmod +x "$d/tor"
    PATH="$d:$PATH" DASHBOARD_ONION_ENABLED="$1" COMPOSE_PROFILES="${2-local_node,local_tari}" NETWORK_PREFIX=10.9.0 \
        TORRC_TEMPLATE="$ROOT/build/tor/torrc.template" TORRC_OUT="$d/torrc" sh "$TOR_ENTRY"
    rm -rf "$d"
}
# The suite's only host-global fixture path, now sandboxed: two concurrent runs used to race on one
# /tmp/torrc and redden the hidden-service assertions, and the natural remedy for that flake is
# "re-run until green" — the habit this repo has been removing. The container default is unchanged
# and MUST stay /tmp/torrc, because tier-3 assertions read that path inside the running container.
assert_eq "tor entrypoint keeps /tmp/torrc as its container default (#1104)" \
    "$(grep -c '^: "${TORRC_OUT:=/tmp/torrc}"$' "$TOR_ENTRY")" "1"
assert_eq "tor entrypoint writes NO bare /tmp/torrc outside that default (#1104)" \
    "$(grep -vE '^\s*#' "$TOR_ENTRY" | grep -cF '/tmp/torrc')" "1"
tor_onion_on="$(tor_torrc true)"
assert_contains "tor entrypoint: dashboard HiddenService appended when enabled (#343)" \
    "$tor_onion_on" "HiddenServiceDir /var/lib/tor/dashboard/"
assert_contains "tor entrypoint: onion vhost targets the bridge gateway .1 (#343)" \
    "$tor_onion_on" "HiddenServicePort 80 10.9.0.1:80"
assert_contains "tor entrypoint: onion also exposes :443 for the Tor-Browser https upgrade (#343)" \
    "$tor_onion_on" "HiddenServicePort 443 10.9.0.1:443"
assert_not_contains "tor entrypoint: no dashboard onion when disabled (default off) (#343)" \
    "$(tor_torrc false)" "Dashboard Hidden Service"

# Node inbound onions (#103): each is published only while its node is local, so a remote node
# leaves no onion pointing at a container that never starts. The gate is the compose profile list,
# passed through from the rendered .env — same tokens that decide whether the node runs at all.
tor_both_local="$(tor_torrc false local_node,local_tari)"
assert_contains "tor entrypoint: Monero HS present when local_node is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/monero/"
assert_contains "tor entrypoint: Monero HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18080 10.9.0.26:18084"
assert_contains "tor entrypoint: Tari HS present when local_tari is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/tari/"
assert_contains "tor entrypoint: Tari HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18189 10.9.0.27:18189"
tor_remote_tari="$(tor_torrc false local_node)"
assert_contains "tor entrypoint: Monero HS still present with only local_node (#103)" \
    "$tor_remote_tari" "HiddenServiceDir /var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS when local_tari is omitted (remote tari, #103)" \
    "$tor_remote_tari" "/var/lib/tor/tari/"
tor_both_remote="$(tor_torrc false "")"
assert_not_contains "tor entrypoint: no Monero HS with no profiles (remote monero, #103)" \
    "$tor_both_remote" "/var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS with no profiles (remote tari, #103)" \
    "$tor_both_remote" "/var/lib/tor/tari/"
assert_contains "tor entrypoint: P2Pool HS is unconditional — p2pool always runs (#103)" \
    "$tor_both_remote" "HiddenServiceDir /var/lib/tor/p2pool/"
unset tor_both_local tor_remote_tari tor_both_remote

echo "== unit: onion provisioning follows node mode (#103) =="
# pithead's half of the same gate: a hidden service that is never published has no hostname to wait
# for, so provision_tor must not block on a remote node's onion (a 60s timeout, then a fatal error),
# and the address stays a placeholder. wait_for_onion is stubbed — the polling itself is the docker
# layer, and it runs in a command substitution, so the probe records asks in a file.
ONP="$SANDBOX/onion-prov"
mkdir -p "$ONP"
prov_probe() { # <MONERO_MODE> <TARI_MODE> -> "<onions asked for>|<MONERO_ONION>|<TARI_ONION>|<P2POOL_ONION>"
    (
        cd "$ONP" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        : >asked
        log() { :; }
        docker() { :; }
        resolve_pull_policy() { echo missing; }
        provision_onion_client_auth() { :; }
        provision_dashboard_onion() { :; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        MONERO_MODE="$1"
        TARI_MODE="$2"
        MONERO_ONION=placeholder
        TARI_ONION=placeholder
        P2POOL_ONION=placeholder
        provision_tor
        printf '%s|%s|%s|%s' "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$P2POOL_ONION"
    )
}
assert_eq "provision_tor waits for both node onions when both nodes are local (#103)" \
    "$(prov_probe local local)" "p2pool,monero,tari,|monero.onion|tari.onion|p2pool.onion"
assert_eq "provision_tor skips a remote node's onion and leaves it a placeholder (#103)" \
    "$(prov_probe remote remote)" "p2pool,|placeholder|placeholder|p2pool.onion"
assert_eq "provision_tor waits for the local node only in a mixed setup (#103)" \
    "$(prov_probe local remote)" "p2pool,monero,|monero.onion|placeholder|p2pool.onion"

# provision_node_onions: the remote → local switch. A stack first set up in remote mode has no
# address for that node, so apply/upgrade recreate tor against the committed profiles, capture the
# freshly minted hostname, and re-render .env BEFORE the node container starts against it. It must
# cost nothing (no docker, no render) once every local node's address is in hand.
node_onion_probe() { # <MONERO_MODE> <MONERO_ONION> <TARI_MODE> <TARI_ONION> -> "<docker calls>|<asked>|<MONERO_ONION>|<TARI_ONION>|<renders>"
    (
        cd "$ONP" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        : >asked
        : >dockerlog
        : >renders
        log() { :; }
        docker() { printf '%s ' "$*" >>dockerlog; }
        render_env() { printf 'x' >>renders; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        # shellcheck disable=SC2034  # read by the sourced provision_node_onions, unseen here
        MONERO_MODE="$1"
        MONERO_ONION="$2"
        # shellcheck disable=SC2034  # read by the sourced provision_node_onions, unseen here
        TARI_MODE="$3"
        TARI_ONION="$4"
        provision_node_onions
        printf '%s|%s|%s|%s|%s' "$(cat dockerlog)" "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$(cat renders)"
    )
}
assert_eq "provision_node_onions is a free no-op once every local node has its onion (#103)" \
    "$(node_onion_probe local mona.onion local taria.onion)" "||mona.onion|taria.onion|"
assert_eq "provision_node_onions ignores a remote node with no onion (#103)" \
    "$(node_onion_probe remote placeholder remote placeholder)" "||placeholder|placeholder|"
assert_eq "provision_node_onions mints + captures the onion of a node that just went local (#103)" \
    "$(node_onion_probe local placeholder remote placeholder)" "compose up -d tor |monero,|monero.onion|placeholder|x"
assert_eq "provision_node_onions treats an empty address as missing, and re-renders once (#103)" \
    "$(node_onion_probe local '' local '')" "compose up -d tor |monero,tari,|monero.onion|tari.onion|x"
unset ONP prov_probe node_onion_probe
