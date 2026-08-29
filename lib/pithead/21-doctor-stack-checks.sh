# True if the named container is currently running. State only, no sudo — safe for doctor.
container_is_running() { # <name>
    [ -n "$(docker ps -q --filter "name=^${1}$" --filter status=running 2>/dev/null)" ]
}

# True when a revenue container is running — i.e. the stack is UP, not cleanly `down`. Used to tell
# "tor is down because everything is down" (fine, rules are removed at `down`) apart from "tor is
# down while mining keeps going" (a privacy emergency: the egress backbone is dead but the stack is
# still live). p2pool/monerod/xmrig-proxy are the revenue path; any one up means the stack is up.
mining_stack_running() {
    container_is_running p2pool || container_is_running monerod || container_is_running xmrig-proxy
}

# doctor (#563): the tor container is unconditional (no compose profile gates it — it's the
# Tor-first backbone in every deployment, remote-node mode included). So "revenue containers up
# but tor down" is never a legitimate state: it means tor crashed or was stopped individually
# while the stack kept mining, leaving clearnet dials no longer fail-closed and every off-box
# connection (Healthchecks, Telegram, XvB, p2pool/Tari peers) without its Tor path. FAIL loudly so
# doctor can't report all-clear on a silent privacy outage. A clean `down` (nothing running) is
# fine — nothing to guard.
check_tor_running() {
    if container_is_running tor; then
        dr_ok "Tor container is running — the privacy backbone is up."
    elif mining_stack_running; then
        dr_fail "The Tor container is DOWN while the mining stack is still running — the privacy backbone is dead: clearnet dials are no longer fail-closed and off-box connections (Healthchecks, Telegram, XvB, peers) have lost their Tor path. Restart it ('./pithead restart tor'; set tor.auto_heal:true to self-heal), or bring the stack down ('./pithead down')."
    else
        dr_info "Tor container isn't running — the stack is down (expected after './pithead down')."
    fi
    return 0
}

# doctor (#383): verify the #270 fail-closed egress rules are ACTUALLY installed while the stack
# runs. `down` removes them, and a host reboot silently drops them while `restart: unless-stopped`
# brings every container back — that reboot gap is the state this catches. Read-only: `sudo -n`
# never prompts; every can't-check path degrades to an info line, only a confirmed absence FAILs.
check_egress_firewall_installed() {
    local enabled
    enabled=$(env_get TOR_EGRESS_FIREWALL 2>/dev/null)
    [ -n "$enabled" ] || enabled=true
    if [ "$(normalize_bool "$enabled")" != "true" ]; then
        dr_info "Tor-egress firewall check skipped — opted out (network.tor_egress_firewall=false)."
        return 0
    fi
    if ! container_is_running tor; then
        # tor down while the stack runs is caught by check_tor_running (a dedicated, loud verdict);
        # here it's just an info-skip either way — a clean `down` removed the rules, and a tor-only
        # outage is already being FAILed above.
        dr_info "Tor-egress firewall check skipped — the tor container isn't running."
        return 0
    fi
    if [ "$(container_engine)" = "podman" ]; then
        check_egress_firewall_nft
    else
        check_egress_firewall_iptables
    fi
    return 0
}

# Appliance/netavark probe. The failure this whole fix is about — a DROP that exists in a chain no
# packet traverses — is exactly what a base chain hooked at forward CANNOT be: if the table carries a
# `hook forward` chain with a `drop`, forwarded packets DO pass through it. So we assert the hook and
# the drop, not merely that some rule exists somewhere.
check_egress_firewall_nft() {
    local ruleset
    if ! command -v nft >/dev/null 2>&1; then
        dr_info "Tor-egress firewall check skipped — no nftables."
        return 0
    fi
    # `nft list table` returns rc 1 both when the table is missing AND when sudo -n is refused; a
    # cheap `list tables` probe (succeeds whether or not our table exists) tells the two apart, so a
    # sudo refusal can't masquerade as a missing firewall (a false FAIL).
    if ! sudo -n nft list tables >/dev/null 2>&1; then
        dr_info "Tor-egress firewall check skipped — reading nftables needs passwordless sudo. Verify manually: 'sudo nft list table inet $TOR_EGRESS_NFT_TABLE'."
        return 0
    fi
    ruleset=$(sudo -n nft list table inet "$TOR_EGRESS_NFT_TABLE" 2>/dev/null) || ruleset=""
    if printf '%s\n' "$ruleset" | grep -q 'hook forward' && printf '%s\n' "$ruleset" | grep -qw drop; then
        dr_ok "Tor-only egress firewall is installed — clearnet dials from the stack are fail-closed via nftables (inet $TOR_EGRESS_NFT_TABLE)."
    else
        dr_fail "Tor-only egress firewall is MISSING while the stack runs — clearnet egress is NOT fail-closed. This happens after a host reboot (the rules are gone but the containers auto-restarted). Run './pithead up' to reinstall them."
    fi
}

# DIY/Docker probe: the tagged rules in DOCKER-USER, which Docker's FORWARD jump traverses.
check_egress_firewall_iptables() {
    local rules
    if ! command -v iptables >/dev/null 2>&1; then
        dr_info "Tor-egress firewall check skipped — no iptables."
        return 0
    fi
    if ! rules=$(sudo -n iptables -S DOCKER-USER 2>/dev/null); then
        dr_info "Tor-egress firewall check skipped — reading iptables needs passwordless sudo. Verify manually: 'sudo iptables -S DOCKER-USER | grep $TOR_EGRESS_TAG'."
        return 0
    fi
    if printf '%s\n' "$rules" | grep -qF -- "$TOR_EGRESS_TAG"; then
        dr_ok "Tor-only egress firewall rules are installed — clearnet dials from the stack are fail-closed."
    else
        dr_fail "Tor-only egress firewall rules are MISSING while the stack runs — clearnet egress is NOT fail-closed. This happens after a host reboot (the rules are gone but the containers auto-restarted). Run './pithead up' to reinstall them."
    fi
}

# doctor (#383): something must actually LISTEN on the stratum port while xmrig-proxy runs — the
# top documented "workers don't show up" cause. check_stratum_exposure answers "who can reach
# :3333"; this answers "is it there at all". A held miner (sync hold, #35) isn't running, so the
# check never fires against an intentional hold.
check_stratum_listening() {
    if ! container_is_running xmrig-proxy; then
        dr_info "Stratum listen check skipped — xmrig-proxy isn't running (normal during a sync hold)."
        return 0
    fi
    if ! command -v ss >/dev/null 2>&1; then
        dr_info "Stratum listen check skipped — no 'ss' command (Linux-only)."
        return 0
    fi
    local port
    port=$(stratum_port_effective)
    if ss -Hltn 2>/dev/null | grep -q ":$port "; then
        dr_ok "Stratum :$port is listening — workers can connect."
    else
        dr_fail "xmrig-proxy is running but NOTHING is listening on :$port — workers can't connect. Check './pithead logs xmrig-proxy' and $DOCS_URL/docs/workers.md."
    fi
    return 0
}

# The operator-facing stratum port (#172): the env wins (already-parsed config), then the rendered
# .env, then the 3333 default — mirrors how check_stratum_exposure resolves STRATUM_BIND.
stratum_port_effective() {
    local port="${STRATUM_PORT:-}"
    if [ -z "$port" ] && [ -f "${ENV_FILE:-.env}" ]; then port="$(env_get STRATUM_PORT 2>/dev/null || true)"; fi
    printf '%s' "${port:-3333}"
}

# doctor (#383): a "running" dashboard container doesn't mean the app inside answers. Probe the
# app where it binds (127.0.0.1:8000 — Caddy fronts it, but the app is the part that wedges).
# WARN not FAIL: the stack mines fine without the panel.
check_dashboard_answers() {
    if ! container_is_running dashboard; then
        dr_info "Dashboard probe skipped — the dashboard container isn't running."
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        dr_info "Dashboard probe skipped — no curl."
        return 0
    fi
    if curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:8000/api/state" 2>/dev/null; then
        dr_ok "Dashboard app answers on 127.0.0.1:8000."
    else
        dr_warn "Dashboard container is running but the app isn't answering on 127.0.0.1:8000 — check './pithead logs dashboard'."
    fi
    return 0
}

# The revenue-path containers, split by how they behave during a fresh node's DAYS-LONG initial
# sync (#35). This split is the whole reason the commit gate can tell "still syncing" (fine, commit)
# from "crashed" (revert):
#   chain nodes  — monerod/tari and their payout wallets. They RUN throughout the initial sync (they
#                  ARE what is syncing), and their healthchecks are liveness probes (RPC answers /
#                  process alive / #718 scan-grace), so they report healthy from early on regardless
#                  of sync height. A chain node that is down or unhealthy is a real crash, never
#                  "just syncing".
#   sync-gated miners — p2pool/xmrig-proxy. The dashboard deliberately STOPS these until the node
#                  finishes syncing (#35), so a DOWN miner is the expected steady state on a fresh
#                  box, not a fault. Only a miner that is running yet failing its healthcheck is one.
REVENUE_CHAIN_CONTAINERS="monerod tari wallet-rpc tari-wallet"
REVENUE_MINER_CONTAINERS="p2pool xmrig-proxy"

# Pure verdict for one revenue container, given its run state and status string exactly as
# podman/docker `ps` report them (state = running/exited/created/…, status = "Up 3m (healthy)").
# Prints "ok" or "fail:<reason>". Kept pure — no engine calls — so the commit gate's honesty is
# unit-testable without a running stack (tests/stack/run.sh). A non-revenue name is always "ok":
# the rest of doctor covers those, and this must not judge containers outside its remit.
#
# chain_hold=1 is the migration hold (#851): pithead-boot deliberately withholds the chain
# containers until the slot commits, so — exactly like the miners' sync hold — a DOWN chain node
# is then the expected state, not a crash, and only a running-but-unhealthy one is a fault.
# Without this arm the commit gate would fail on the very hold it is gating, a deadlock.
revenue_container_verdict() { # <name> <state> <status> [chain_hold]
    local name="$1" state="$2" status="$3" chain_hold="${4:-0}" running=0
    # "running" from EITHER signal: podman and docker both print an "Up …" status for a live
    # container, and `.State` is "running". Reading both is belt-and-suspenders — some docker CLI
    # versions leave the `.State` ps field empty, and a chain node judged down on that alone would
    # wrongly block the commit.
    if [ "$state" = running ]; then
        running=1
    else
        case "$status" in Up*) running=1 ;; esac
    fi
    case " $REVENUE_CHAIN_CONTAINERS " in
    *" $name "*)
        # Under the migration hold, judge a chain node by the miners' rule: down is deliberate.
        if [ "$chain_hold" = 1 ]; then
            case "$status" in
            *'(unhealthy)'*)
                if [ "$running" = 1 ]; then
                    printf 'fail:%s is running but unhealthy (%s)\n' "$name" "$status"
                else printf 'ok\n'; fi
                ;;
            *) printf 'ok\n' ;;
            esac
            return
        fi
        # Chain node: it must be running and PAST its healthcheck. "starting"/"unhealthy" and any
        # stopped/exited/created state all mean not-ready-or-crashed. The boot gate loops, so a node
        # that is only starting simply gets retried rather than committed early.
        case "$status" in
        *'(unhealthy)'* | *'(starting)'*)
            printf 'fail:%s is not ready (%s) — a chain node must be up and healthy to commit\n' "$name" "$status"
            ;;
        *)
            if [ "$running" = 1 ]; then
                printf 'ok\n'
            else printf 'fail:%s is down (%s) — a chain node down means the slot is not healthy to commit\n' "$name" "${status:-$state}"; fi
            ;;
        esac
        ;;
    *)
        case " $REVENUE_MINER_CONTAINERS " in
        *" $name "*)
            # Sync-gated miner: down is the normal sync hold, so only a RUNNING-but-unhealthy miner
            # is a fault. This is the rule that keeps a days-long initial sync from blocking commit.
            case "$status" in
            *'(unhealthy)'*)
                if [ "$running" = 1 ]; then
                    printf 'fail:%s is running but unhealthy (%s)\n' "$name" "$status"
                else printf 'ok\n'; fi
                ;;
            *) printf 'ok\n' ;;
            esac
            ;;
        *) printf 'ok\n' ;;
        esac
        ;;
    esac
}

# doctor (#852): the commit-gate-critical container check the plan always assumed doctor did. The
# blanket "read the ps table" line in the Containers section proves nothing about WHETHER the
# revenue path is alive — a slot whose monerod/p2pool crashed while caddy+dashboard keep serving
# still read "OK", and the appliance A/B commit gate (os/overlay/pithead-boot) would mark-good a
# mining-dead slot. This FAILs on a crashed revenue container so `doctor --json`'s exit code is an
# honest gate: it rejects the healthy-looking-but-dead slot while staying quiet on the sync hold and
# the long initial sync. Engine-aware (docker on DIY, podman on the appliance) and read-only.
check_revenue_containers() {
    local engine rows name state status verdict failed=0 chain_hold=0
    engine=$(container_engine)
    command -v "$engine" >/dev/null 2>&1 || return 0
    rows=$("$engine" ps -a --format '{{.Names}}\t{{.State}}\t{{.Status}}' 2>/dev/null) || return 0
    [ -n "$rows" ] || return 0
    # The migration hold (#851): while pithead-boot withholds the chain services pre-commit,
    # their absence is deliberate — the gate must not deadlock on the hold it is gating.
    if os_migration_hold_active; then
        chain_hold=1
        dr_info "A data migration is pending — chain services are deliberately held until this slot commits."
    fi
    # A here-string (not a pipe) keeps the loop in this shell, so `failed` survives it.
    while IFS=$'\t' read -r name state status; do
        [ -n "$name" ] || continue
        verdict=$(revenue_container_verdict "$name" "$state" "$status" "$chain_hold")
        case "$verdict" in
        fail:*)
            dr_fail "${verdict#fail:}"
            failed=1
            ;;
        esac
    done <<<"$rows"
    [ "$failed" -eq 0 ] && dr_ok "Revenue containers are healthy or holding for sync — none crashed."
    return 0
}

# doctor (#424): Tor can bootstrap to 100% yet sit on a FAILING GUARD — circuits build but
# clearnet exits time out, silently killing Healthchecks pings, Telegram, and XvB stats while
# mining (onion/established circuits) keeps working, so the stack otherwise looks healthy. One
# SOCKS request through the tor container to a robust no-content endpoint distinguishes "Tor
# down" (container health already shows that) from "Tor up but exits failing" — the state that
# needs a tor restart to pick fresh guards. WARN not FAIL: Tor weather is transient and this
# must not fail cron health gates on a slow circuit.
check_tor_clearnet_egress() {
    if ! container_is_running tor; then
        # A tor-only outage is FAILed by check_tor_running; this test can't probe egress without a
        # live tor either way, so it just info-skips.
        dr_info "Tor clearnet-egress check skipped — the tor container isn't running."
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        dr_info "Tor clearnet-egress check skipped — no curl."
        return 0
    fi
    local prefix
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null)
    [ -n "$prefix" ] || prefix="172.28.0"
    if curl -fsS --max-time 15 --socks5-hostname "${prefix}.25:9050" -o /dev/null \
        "https://www.google.com/generate_204" 2>/dev/null; then
        dr_ok "Tor clearnet egress works — Healthchecks, Telegram, and XvB can reach their services."
    else
        dr_warn "Tor is up but a clearnet request through its SOCKS timed out — Healthchecks pings, Telegram, and XvB stats are likely down while mining still works (a failing Tor guard does this). Fix: './pithead restart tor' picks fresh guards; set tor.auto_heal:true in config.json to have the stack do this itself."
    fi
    return 0
}

# doctor (#972): a monerod that survived a tor restart with every SOCKS peer dead looks healthy —
# container up, healthcheck green (it only probes the RPC), height even creeping on occasional
# lucky dials — while `get_info` reports `synchronized: false` and mining sits on a stale tip.
# Probe from the host with the .env digest creds (the monerod image carries no curl) and trust
# the RAW `synchronized` flag, like the dashboard's out-of-sync alert: a stranded node can report
# a stale target_height of 0, so any height math reads it as caught up — the flag is the node's
# own verdict. WARN not FAIL: a node mid-initial-sync legitimately reports the same thing for
# days. Silently skips when no monerod container runs (remote mode, stack down).
check_monerod_synchronized() {
    container_is_running monerod || return 0
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        dr_info "Monero sync check skipped — needs curl and jq."
        return 0
    fi
    local user pass url body
    user=$(env_get MONERO_NODE_USERNAME 2>/dev/null)
    pass=$(env_get MONERO_NODE_PASSWORD 2>/dev/null)
    url=$(env_get MONERO_RPC_URL 2>/dev/null)
    [ -n "$url" ] || url="http://127.0.0.1:18081"
    if [ -n "$user" ]; then
        body=$(curl -fsS --max-time 8 --digest -u "$user:$pass" "$url/get_info" 2>/dev/null)
    else
        body=$(curl -fsS --max-time 8 "$url/get_info" 2>/dev/null)
    fi
    if [ -z "$body" ]; then
        dr_info "Monero sync check skipped — monerod's RPC did not answer (the container table above shows whether it is still starting)."
        return 0
    fi
    if printf '%s' "$body" | jq -e '(.status == "OK") and (.synchronized == true)' >/dev/null 2>&1; then
        dr_ok "monerod reports synchronized with the Monero network."
    else
        dr_warn "monerod is running but reports NOT synchronized — normal during initial sync; if it stays like this on a previously-synced node (peers lost after a Tor restart), './pithead restart monerod' re-dials and recovers in about a minute."
    fi
    return 0
}
