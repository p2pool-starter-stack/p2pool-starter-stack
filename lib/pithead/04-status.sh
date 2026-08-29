# Per-chain "is this node EXPOSED on clearnet right now?" (#183/#234): the flag is on AND the
# dashboard's auto-transition marker is absent (so it hasn't been switched back to Tor yet). Once
# the marker appears the node is Tor-only again and this reads false — which is why the status/doctor
# warnings clear on their own. Read-only; safe from status/doctor/up.
clearnet_state_dir() {
    local sdir
    sdir=$(env_get CLEARNET_STATE_DIR 2>/dev/null)
    [ -n "$sdir" ] && printf '%s' "$sdir" || printf '%s' "$PWD/data/clearnet-state"
}
monero_clearnet_exposed() {
    [ "$(env_get MONERO_CLEARNET_SYNC 2>/dev/null)" = "true" ] && [ ! -f "$(clearnet_state_dir)/monero.synced" ]
}
tari_clearnet_exposed() {
    [ "$(env_get TARI_CLEARNET_SYNC 2>/dev/null)" = "true" ] && [ ! -f "$(clearnet_state_dir)/tari.synced" ]
}
clearnet_sync_active() { monero_clearnet_exposed || tari_clearnet_exposed; }

# Loud, persistent CLEARNET-SYNC banner (#183). Names exactly which daemon(s) are currently exposed
# on clearnet so the operator can never forget. Prints nothing once both are back on Tor.
print_clearnet_banner() {
    local who=""
    monero_clearnet_exposed && who="Monero"
    tari_clearnet_exposed && who="${who:+$who + }Tari"
    [ -n "$who" ] || return 0
    echo -e "${C_YELLOW}========================================================================${C_RESET}" >&2
    echo -e "${C_YELLOW}[!] CLEARNET INITIAL SYNC ACTIVE — node IP exposed${C_RESET}" >&2
    echo "    $who P2P is running over CLEARNET to sync faster, so this host's IP is" >&2
    echo "    visible to that P2P network. Monero tx-broadcast stays on Tor; wallets are" >&2
    echo "    never exposed. The dashboard switches each node back to Tor automatically" >&2
    echo "    once it finishes syncing — no action needed." >&2
    echo -e "${C_YELLOW}========================================================================${C_RESET}" >&2
}

# The dashboard onion (#343) as a single human line for `status`/`doctor`: the URL plus how to reach
# it. Prints nothing and returns non-zero when the onion is off or not yet provisioned. NEVER includes
# the client PRIVATE key — that lives behind the explicit 'onion-client-key' command, since these
# reports are meant to be paste-able.
dashboard_onion_status() {
    [ "$(env_get DASHBOARD_ONION_ENABLED)" == "true" ] || return 1
    local onion
    onion=$(env_get DASHBOARD_ONION_ADDRESS)
    { [ -n "$onion" ] && [ "$onion" != "placeholder" ]; } || return 1
    if [ "$(env_get DASHBOARD_ONION_CLIENT_AUTH)" == "true" ]; then
        printf "http://%s (client-auth ON + login; get your client key with '%s onion-client-key')" "$onion" "$0"
    else
        printf 'http://%s (login required)' "$onion"
    fi
}

# Re-render the dashboard's live per-chain initial-sync progress (#384) as human lines for `status`,
# so a held miner shows real numbers instead of only "check the dashboard". Reads the same /api/state
# the UI does (127.0.0.1:8000 — host-local, no auth) and prints one line per chain that isn't synced
# yet. No ETA: the block rate isn't sampled here, so 'remaining' blocks is the honest figure. Prints
# nothing and returns non-zero when every chain is done, the dashboard app isn't answering yet (stack
# still starting, or down), or jq is missing — so `status` degrades quietly.
dashboard_sync_progress() {
    command -v jq >/dev/null 2>&1 || return 1
    local body rows
    body=$(curl -fsS --max-time 3 "http://127.0.0.1:8000/api/state" 2>/dev/null) || return 1
    rows=$(printf '%s' "$body" | jq -r '
        (.sync // {}) | to_entries[]
        | select(.value.state != "done")
        | [.key,
           (.value.state // "loading"),
           (.value.percent // 0),
           (.value.current // 0),
           (.value.target // 0),
           (.value.remaining // 0)]
        | @tsv' 2>/dev/null) || return 1
    [ -n "$rows" ] || return 1
    log "Chain sync in progress — the miner is held until it completes:"
    local chain state percent current target remaining
    while IFS=$'\t' read -r chain state percent current target remaining; do
        [ -z "$chain" ] && continue
        if [ "$state" = "syncing" ]; then
            printf '  %b…%b %-13s %s%% (%s / %s blocks, %s to go)\n' \
                "$C_YELLOW" "$C_RESET" "$chain" "$percent" "$current" "$target" "$remaining"
        else
            printf '  %b…%b %-13s discovering the target height…\n' \
                "$C_YELLOW" "$C_RESET" "$chain"
        fi
    done <<<"$rows"
}

# Show the compose table, then health-check every service we expect to be running and warn
# about anything that isn't. Returns non-zero if any service needs attention (handy for cron).
# Profile-aware (the bundled monerod only counts in local-node mode), and aware that a stopped
# p2pool/xmrig-proxy can be intentional: reject-workers (#31) stops xmrig-proxy when a node is
# down, and the sync hold (#35) stops both until the required chains finish their initial sync.
stack_status() {
    docker compose ps || true
    echo ""
    log "Service health check:"

    local expected profiles
    expected=$(docker compose config --services 2>/dev/null | sort || true)
    profiles=$(env_get COMPOSE_PROFILES)
    if [ -z "$expected" ]; then
        warn "Could not read the service list from compose — is Docker running?"
        return 1
    fi

    local problems=0 proxy_state="" p2pool_state="" node_down=0
    local s cid info state health
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        # The bundled monerod only runs under the local_node profile; in remote mode it's
        # not expected, so don't flag it missing.
        if [ "$s" = "monerod" ] && [[ ",$profiles," != *",local_node,"* ]]; then
            continue
        fi
        # Same for the bundled Tari node under local_tari (#103): tari.mode remote means it's
        # never expected to be running, so don't flag it missing either.
        if [ "$s" = "tari" ] && [[ ",$profiles," != *",local_tari,"* ]]; then
            continue
        fi

        cid=$(docker compose ps -aq "$s" 2>/dev/null | head -n1 || true)
        if [ -z "$cid" ]; then
            state="missing"
            health="none"
        else
            info=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown none")
            state=${info%% *}
            health=${info##* }
        fi

        # Track required-node health (monerod/tari) to interpret a stopped proxy below.
        if [ "$s" = "monerod" ] || [ "$s" = "tari" ]; then
            if [ "$state" != "running" ] || { [ "$health" != "healthy" ] && [ "$health" != "none" ]; }; then
                node_down=1
            fi
        fi

        # Defer the verdict for the miner containers until we know whether a node is down /
        # the sync hold is on: a stopped p2pool or xmrig-proxy is often intentional (#31/#35).
        if [ "$s" = "xmrig-proxy" ] && [ "$state" != "running" ]; then
            proxy_state="$state"
            continue
        fi
        if [ "$s" = "p2pool" ] && [ "$state" != "running" ]; then
            p2pool_state="$state"
            continue
        fi

        case "$state" in
        running)
            case "$health" in
            healthy | none) printf '  %b✓%b %-13s running\n' "$C_GREEN" "$C_RESET" "$s" ;;
            starting) printf '  %b…%b %-13s starting (health check pending)\n' "$C_YELLOW" "$C_RESET" "$s" ;;
            *)
                printf '  %b⚠%b %-13s running but UNHEALTHY\n' "$C_YELLOW" "$C_RESET" "$s"
                problems=$((problems + 1))
                ;;
            esac
            ;;
        restarting)
            printf '  %b✗%b %-13s restarting (possible crash loop — check logs)\n' "$C_RED" "$C_RESET" "$s"
            problems=$((problems + 1))
            ;;
        *)
            printf '  %b✗%b %-13s %s\n' "$C_RED" "$C_RESET" "$s" "$state"
            problems=$((problems + 1))
            ;;
        esac
    done <<<"$expected"

    # A stopped p2pool/xmrig-proxy is normally intentional: the dashboard stops xmrig-proxy to
    # fail workers over a node-down (#31), and holds the miner until the required chains finish
    # syncing (#35). We can't tell those apart from a genuine fault here (a healthy node can
    # still be syncing), so report it as likely-intentional and point at the dashboard.
    local held name st why
    for held in "p2pool=$p2pool_state" "xmrig-proxy=$proxy_state"; do
        name=${held%%=*}
        st=${held#*=}
        [ -z "$st" ] && continue
        if [ "$node_down" -eq 1 ]; then
            why="a node is down, so workers were rejected to fail over to backups"
        else
            why="held until the required chains finish syncing — check the dashboard"
        fi
        printf '  %b⚠%b %-13s %s — likely intentional: %s\n' "$C_YELLOW" "$C_RESET" "$name" "$st" "$why"
    done

    # Turn "check the dashboard" into real numbers (#384): re-render the dashboard's own per-chain
    # sync progress from /api/state. Self-skips when both chains are synced or the app isn't up yet.
    dashboard_sync_progress || true

    echo ""
    # A clearnet initial sync (#183) is a privacy-relevant state, not a fault — surface it
    # prominently every time the operator checks status, separate from the service verdict.
    print_clearnet_banner
    # When the remote-access onion (#343) is on, show its URL here too — `status` is where an operator
    # looks first, not just `doctor`. The client key stays behind 'onion-client-key'.
    local onion_line
    if onion_line=$(dashboard_onion_status); then
        log "Dashboard onion (remote access): $onion_line"
    fi
    # #208: RigForge's setup prompt (and docs/workers.md) tell the operator the stratum
    # access-password is "shown by 'pithead status'" — honor that contract here. No-op when
    # auth is off; the same secret already lives in the owner-only .env.
    announce_stratum_auth
    announce_stratum_tls # #261: same contract for the TLS pin — status repeats the fingerprint
    if [ "$problems" -eq 0 ]; then
        log "All expected services are up."
    else
        warn "$problems service(s) need attention (see above)."
        return 1
    fi
}
