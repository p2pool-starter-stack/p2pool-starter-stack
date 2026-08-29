# --- Lifecycle Helpers ---

# The Compose project name is pinned to "pithead" (docker-compose.yml `name:`). A stack first
# deployed under the old directory-derived project name still has containers holding our
# container_names (tor, monerod, …) under that old project — they'd block `up` with a name
# clash. Remove ONLY those — the containers belonging to the exact project THIS directory used
# to create — so the renamed project can take over. We never touch a container that merely
# shares a service name with us (e.g. someone else's `caddy` from an unrelated project). Chain
# data lives in the bind-mounted data dirs and the Tor onion keys in a bind mount too, so
# nothing is lost; Caddy re-issues its local TLS cert once under the new name.
migrate_compose_project() {
    local cfg our_project dir_project names name cid proj
    # Best-effort and must never abort pithead, so every substitution is guarded (a bare
    # `var=$(failing)` would trip `set -e`).
    cfg=$(docker compose config --format json 2>/dev/null) || return 0
    [ -n "$cfg" ] || return 0
    our_project=$(printf '%s' "$cfg" | jq -r '.name // "pithead"' 2>/dev/null) || our_project="pithead"
    [ -n "$our_project" ] || our_project="pithead"
    # The old project name is the one Compose derived from this directory's basename (lowercased,
    # sanitised to [a-z0-9_-]). Matching it exactly is what keeps us from removing an unrelated
    # container. If it already equals our pinned name there's nothing to migrate.
    dir_project=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    { [ -n "$dir_project" ] && [ "$dir_project" != "$our_project" ]; } || return 0
    names=$(printf '%s' "$cfg" | jq -r '.services[].container_name // empty' 2>/dev/null) || return 0
    [ -n "$names" ] || return 0

    local stale=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        cid=$(docker ps -aq --filter "name=^${name}$" 2>/dev/null | head -n1) || cid=""
        [ -n "$cid" ] || continue
        proj=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null) || proj=""
        [ "$proj" = "$dir_project" ] && stale+=("$name")
    done <<<"$names"

    [ "${#stale[@]}" -gt 0 ] || return 0
    warn "Migrating this stack from the old Compose project '$dir_project' to '$our_project'."
    log "Removing the old-named containers so the renamed project can take over. Chain data dirs"
    log "and Tor onion keys are bind-mounted (untouched); Caddy re-issues its local TLS cert."
    docker rm -f "${stale[@]}" >/dev/null 2>&1 || true
}

# Turn Docker's cryptic bridge-subnet overlap error into an actionable fix (#180). $1 = compose
# output. A no-op unless Docker rejected the subnet ("Pool overlaps with other one on this address
# space"), which happens when the host already uses the stack's /24.
explain_subnet_collision() {
    case "$1" in
    *"overlaps with other one"* | *"Pool overlaps"*)
        local sub
        sub="$(env_get NETWORK_SUBNET 2>/dev/null || true)"
        [ -n "$sub" ] || sub="172.28.0.0/24"
        warn "Docker refused the stack's bridge subnet ($sub): it overlaps a network already on this host."
        warn "Pick a free /24 and set it in ${CONFIG_FILE:-config.json} — e.g.  \"network\": { \"subnet\": \"172.30.0.0/24\" }  — then re-run '$0 apply' && '$0 up' (see $DOCS_URL/docs/configuration.md, network.subnet)."
        ;;
    esac
}

# A source checkout has the image build CONTEXTS (Dockerfiles) and builds the first-party images
# locally; a release install ships only the runtime bits (compose, pithead, and build/tari/'s config
# template that inject_service_configs renders at setup) and pulls the published images. Key off a
# Dockerfile, NOT `build/` — a release bundle still contains build/tari/, so `[ -d build ]` is true (#44).
is_source_checkout() { [ -f dashboard/Dockerfile ]; }

# `docker compose up` pull policy (#44): a source checkout builds the first-party images locally —
# `never`, so up doesn't attempt (and warn about) a registry pull for an unpublished `:dev` tag —
# while a release install pulls them: `missing`. Override with PITHEAD_PULL (e.g. `always` to force a
# re-pull on upgrade).
resolve_pull_policy() {
    if [ -n "${PITHEAD_PULL:-}" ]; then
        printf '%s' "$PITHEAD_PULL"
    elif is_source_checkout; then
        printf 'never'
    else printf 'missing'; fi
}

# #795: `compose up --remove-orphans` never removes the container of a service whose profile just
# went inactive — the service is still in the compose file, so compose does not count it as an
# orphan and leaves it running (a tari local→remote switch left the old minotari_node up, offline
# and re-syncing, against a remote-mode config). Reconcile from the committed .env instead: every
# profile-gated service whose profile token is absent gets its container stopped and removed.
# `compose rm` resolves an explicitly named service whatever the active profiles, and exits 0 when
# no container exists, so running this before every up is a cheap no-op in the steady state and
# also heals a box already stuck with a stale node container.
remove_deactivated_profile_containers() {
    local profiles gone=()
    profiles=",$(env_get COMPOSE_PROFILES),"
    [[ "$profiles" == *,local_node,* ]] || gone+=(monerod)
    [[ "$profiles" == *,local_tari,* ]] || gone+=(tari)
    [[ "$profiles" == *,payout_confirm,* ]] || gone+=(wallet-rpc)
    [[ "$profiles" == *,tari_payout_confirm,* ]] || gone+=(tari-wallet)
    [ "${#gone[@]}" -eq 0 ] && return 0
    docker compose rm -sf "${gone[@]}" >/dev/null 2>&1 ||
        warn "Could not remove the deactivated container(s): ${gone[*]} — remove them manually with 'docker rm -f ${gone[*]}'."
}

# Run `docker compose up` with live output; on failure, explain a bridge-subnet collision (#180) if
# that's what Docker rejected. Returns compose's own exit code.
compose_up_checked() {
    local tmp out rc
    # Deactivated-profile containers go BEFORE the up (#795): the old local node must stop before
    # p2pool (re)starts against the remote one, not linger beside it.
    remove_deactivated_profile_containers
    tmp="$(mktemp)"
    docker compose up --pull "$(resolve_pull_policy)" "$@" 2>&1 | tee "$tmp"
    rc=${PIPESTATUS[0]}
    out="$(<"$tmp")"
    rm -f "$tmp"
    [ "$rc" -ne 0 ] && explain_subnet_collision "$out"
    return "$rc"
}

stack_up() {
    mutation_lock_acquire up
    log "Starting stack..."
    warn_missing_data_dirs
    migrate_compose_project
    # Install the Tor-only egress firewall BEFORE the containers start (#270). DOCKER-USER is a static
    # chain whose rules reference the fixed subnet/Tor IP, so they can go in before the network exists;
    # Docker preserves DOCKER-USER and (re)adds the FORWARD jump when it creates the network. Doing this
    # first closes the startup window in which a clearnet app (e.g. Tari) could open a connection that
    # the ESTABLISHED rule would then grandfather past the DROP.
    apply_tor_egress_firewall
    # #452: a fresh release install's first `up` pulls the 5 first-party images (pull policy
    # `missing`) — gate that pull on the same cosign check `upgrade` uses, so first install is not
    # the one unverified pull. Same guard: source checkouts skip, a missing cosign.pub warns and
    # proceeds (#461 — an install predating the first signed release has no key to verify against),
    # a present key that fails aborts before anything starts.
    verify_release_images
    # Docker Compose automatically picks up COMPOSE_PROFILES from .env
    #
    # PITHEAD_HOLD_CHAIN=1 is the migration hold (#851), set only by the appliance boot path on
    # the first boot of a data_migration bundle: bring up everything EXCEPT the chain services
    # (monerod/tari and their wallets — the holders of forward-only lmdb migrations, and the
    # only containers anything depends on together), so the A/B commit decision is made before
    # any migration touches /data. The chain services start with a plain `up` after the commit.
    if [ "${PITHEAD_HOLD_CHAIN:-0}" = 1 ]; then
        local services c
        local filter=()
        for c in $REVENUE_CHAIN_CONTAINERS; do filter+=(-e "$c"); done
        services=$(docker compose config --services 2>/dev/null)
        [ -n "$services" ] || error "Could not list compose services for the chain hold."
        log "Data migration pending — holding chain services ($REVENUE_CHAIN_CONTAINERS) until the slot commits."
        services=$(printf '%s\n' "$services" | grep -vxF "${filter[@]}")
        # shellcheck disable=SC2086 # word-splitting the service list is the point
        if ! compose_up_checked -d $services; then
            error "Stack failed to start — see the error above."
        fi
    elif ! compose_up_checked -d; then
        error "Stack failed to start — see the error above."
    fi
    log "Stack started successfully!"
    # Remind the operator at start-time if a node is coming up on clearnet (#183).
    print_clearnet_banner
    announce_dashboard_url
    print_first_run_epilogue
    mutation_lock_release
}

# One-time onboarding after the stack first comes up (#384): explain that mining doesn't start until
# both chains finish their initial sync, and where to watch progress. Keyed on a marker file beside
# .env so it shows once (fresh setup/up) and not on every restart of an already-running box. The
# dashboard itself drives the sync-then-mine handoff (#35) — this is just the "what happens next".
print_first_run_epilogue() {
    [ -f "$FIRST_RUN_MARKER" ] && return 0
    : >"$FIRST_RUN_MARKER" 2>/dev/null || true
    log "What happens next:"
    log "  The miner is held until Monero and Tari finish their first sync, then starts automatically."
    log "  Watch progress with '$0 status' or live on the dashboard."
    log "  First-time sync of both chains can take several hours to a few days, depending on disk and network."
}

stack_down() {
    mutation_lock_acquire down
    log "Stopping stack..."
    remove_tor_egress_firewall
    docker compose down
    log "Stack stopped."
    mutation_lock_release
}

stack_restart() { # [tor|monerod]
    # Reject a bad argument BEFORE taking the lock (#1342). Validating inside the window makes a
    # typo wait out someone else's backup — up to PITHEAD_LOCK_TIMEOUT — only to be told it was a
    # typo all along. Nothing here mutates, so there is nothing to serialise yet.
    case "${1:-}" in
    "" | tor | monerod) ;;
    *) error "restart takes no argument, 'tor' (fresh Tor guards when clearnet egress is stuck), or 'monerod' (re-dial peers after a Tor restart left the node out of sync). Got: '$1'." ;;
    esac
    mutation_lock_acquire restart
    case "${1:-}" in
    "")
        log "Restarting stack..."
        docker compose restart
        log "Stack restarted."
        ;;
    tor)
        # Manual leg of the #424 guard self-heal: restart ONLY tor so it picks fresh guards
        # when clearnet exits are stuck (the doctor Tor clearnet-egress check WARNs on this).
        # Tor takes no args from .env, so a plain restart is safe (other containers go
        # through apply/upgrade, whose recreate applies current args, #273). Compose then
        # restarts monerod right after tor is healthy again (depends_on restart: true, #972):
        # monerod does NOT re-peer on its own after a tor restart kills its SOCKS
        # connections — it can sit at 0 in / 0 out peers for hours; p2pool re-peers fine.
        log "Restarting the tor container to pick fresh guards — ALL Tor circuits drop and rebuild (mining onions included; p2pool re-peers on its own, and a local monerod is restarted alongside so it re-dials)..."
        docker compose restart tor
        log "tor restarted. Verify egress recovered: './pithead doctor' (Tor clearnet-egress check)."
        ;;
    monerod)
        # Peer-loss recovery (#972): a tor restart/recreate outside compose (docker itself, or
        # the #424 auto-heal when its coupled monerod restart could not be issued) leaves
        # monerod holding dead SOCKS sockets — reachable, healthcheck green, but
        # `synchronized: false` with 0 peers for hours. A plain restart re-dials through the
        # running tor and recovers in about a minute. Safe under the #273 recreate-only rule
        # for the same reason as tor: re-peering wants the container's args EXACTLY as they
        # are — config changes still go through apply.
        log "Restarting the monerod container so it re-dials its peers through Tor..."
        docker compose restart monerod
        log "monerod restarted. It should report synchronized again within a few minutes — verify: './pithead doctor' (Monero sync check)."
        ;;
    # Unreachable: the validation above admits only the three cases. Kept so that adding a value
    # there and forgetting to handle it here fails loudly instead of restarting nothing.
    *) error "Internal error: restart accepted '$1' but does not handle it." ;;
    esac
    mutation_lock_release
}
