# Poll the running tor container for one hidden service's hostname file and echo the address.
# $1 = the HiddenServiceDir name under /var/lib/tor. Polls instead of sleeping a fixed 15s — Tor
# can take more or less than that to publish, especially on first run. Returns 1 on timeout so the
# caller decides whether a missing address is fatal.
wait_for_onion() {
    local svc="$1" elapsed=0 timeout=60
    until docker exec tor test -f "/var/lib/tor/$svc/hostname"; do
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    docker exec tor cat "/var/lib/tor/$svc/hostname"
}

provision_tor() {
    log "Initializing Tor service to generate onion addresses..."
    # Client-auth keys must be in place before tor starts, since it reads authorized_clients then (#343).
    provision_onion_client_auth
    docker compose up --pull "$(resolve_pull_policy)" -d tor
    log "Waiting for Tor hidden services to be generated..."
    P2POOL_ONION=$(wait_for_onion p2pool) ||
        error "Timed out waiting for the P2Pool Tor hidden-service hostname."
    # A node's inbound onion is only published while that node is local (build/tor/entrypoint.sh
    # gates each block on its compose profile), so in remote mode there is nothing to wait for and
    # the address stays a placeholder — provision_node_onions mints it if the node ever goes local.
    if [ "$MONERO_MODE" == "local" ]; then
        MONERO_ONION=$(wait_for_onion monero) ||
            error "Timed out waiting for the Monero Tor hidden-service hostname."
    fi
    if [ "$TARI_MODE" == "local" ]; then
        TARI_ONION=$(wait_for_onion tari) ||
            error "Timed out waiting for the Tari Tor hidden-service hostname."
    fi
    provision_dashboard_onion # #343: reads the dashboard onion too, but only when it's enabled
}

# Mint and capture a node's inbound onion when that node has just switched remote → local (#103).
# Its hidden service exists only while the node is local, so a stack first set up in remote mode
# has no address for it yet. Recreating tor against the freshly committed .env publishes the
# service; the address must then be in .env BEFORE the node container starts, because monerod
# templates `anonymous-inbound` from it and the Tari config takes the onion at render time.
# No-op — and no docker call — whenever both nodes' addresses are already in hand.
provision_node_onions() {
    local want_monero=false want_tari=false
    if [ "${MONERO_MODE:-}" == "local" ] && onion_missing "${MONERO_ONION:-}"; then want_monero=true; fi
    if [ "${TARI_MODE:-}" == "local" ] && onion_missing "${TARI_ONION:-}"; then want_tari=true; fi
    [ "$want_monero" == "true" ] || [ "$want_tari" == "true" ] || return 0

    log "Publishing the Tor hidden service for the node that just became local..."
    docker compose up -d tor
    if [ "$want_monero" == "true" ]; then
        MONERO_ONION=$(wait_for_onion monero) ||
            error "Timed out waiting for the Monero Tor hidden-service hostname."
    fi
    if [ "$want_tari" == "true" ]; then
        TARI_ONION=$(wait_for_onion tari) ||
            error "Timed out waiting for the Tari Tor hidden-service hostname."
    fi
    render_env # commit the new address before the node container is (re)created against it
}

# An onion address that was never provisioned: empty, or the placeholder render_env writes until
# the real hostname is captured.
onion_missing() {
    [ -z "${1:-}" ] || [ "${1:-}" == "placeholder" ]
}

# Prepare Tor v3 client authorization for the dashboard onion (#343). Generates the client keypair
# once (preserved across applies) and writes the PUBLIC key into the hidden service's
# authorized_clients/ dir, so the onion is unreachable without the matching private key. MUST run
# BEFORE the tor container (re)starts — tor reads authorized_clients at startup. No-op unless the
# onion is on. When the onion is on but client-auth is off, it clears any prior authorized_clients so
# the onion falls back to password-only.
provision_onion_client_auth() {
    [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] || return 0
    local hs_dir="$TOR_DATA_DIR/dashboard"
    # TOR_DATA_DIR is owned by the tor container's own uid (100 in the Alpine tor image, NOT the
    # first-party APP_UID). If we can't write it directly, elevate — the same sudo ensure_owner uses.
    # (Tests point TOR_DATA_DIR at a user-owned temp dir, so `run` stays empty and no sudo is used.)
    local run=""
    [ -w "$TOR_DATA_DIR" ] || run="sudo"
    if [ "${DASHBOARD_ONION_CLIENT_AUTH:-false}" != "true" ]; then
        if $run test -d "$hs_dir/authorized_clients"; then
            log "Disabling Tor onion client-auth for the dashboard — the onion becomes password-only."
            $run rm -rf "$hs_dir/authorized_clients"
        fi
        return 0
    fi
    if onion_missing "$DASHBOARD_ONION_CLIENT_PUBKEY"; then
        local kp
        kp=$(generate_onion_client_keypair) ||
            error "Could not generate the Tor onion client-auth keypair (need openssl built with x25519, plus od + awk)."
        DASHBOARD_ONION_CLIENT_PUBKEY="${kp%% *}"
        DASHBOARD_ONION_CLIENT_PRIVKEY="${kp##* }"
        log "Generated a Tor onion client-auth key for the dashboard."
    fi
    $run mkdir -p "$hs_dir/authorized_clients"
    printf 'descriptor:x25519:%s\n' "$DASHBOARD_ONION_CLIENT_PUBKEY" | $run tee "$hs_dir/authorized_clients/dashboard.auth" >/dev/null
    # Tor refuses a HiddenServiceDir that is group/other-accessible; keep it 0700/0600 and owned by
    # whatever uid already owns the tor data dir, so tor can read authorized_clients.
    $run chmod 700 "$hs_dir" "$hs_dir/authorized_clients"
    $run chmod 600 "$hs_dir/authorized_clients/dashboard.auth"
    local owner
    # GNU stat first, BSD fallback (macOS dev checkouts). With neither, skip the chown — and do it
    # with `if`, not `[ ] &&`, so an empty owner doesn't become the function's (nonzero) return
    # value and abort the whole apply under set -e after .env is already committed.
    owner=$($run stat -c '%u:%g' "$TOR_DATA_DIR" 2>/dev/null || $run stat -f '%u:%g' "$TOR_DATA_DIR" 2>/dev/null) || owner=""
    if [ -n "$owner" ]; then $run chown -R "$owner" "$hs_dir"; fi
}

# Read the dashboard onion hostname from the running tor container into DASHBOARD_ONION (#343).
# No-op unless the onion is enabled. Its HiddenServiceDir is rendered conditionally
# (build/tor/entrypoint.sh), so poll for the hostname — Tor publishes it a few seconds after
# (re)start. Used by both first-time setup (provision_tor) and a later `apply` that turns it on.
provision_dashboard_onion() {
    [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] || return 0
    log "Waiting for the dashboard Tor hidden service..."
    local elapsed=0 timeout=60
    until docker exec tor test -f /var/lib/tor/dashboard/hostname; do
        if [ "$elapsed" -ge "$timeout" ]; then
            # Non-fatal: the onion still serves; the address just isn't captured for `status` yet.
            warn "Timed out after ${timeout}s waiting for the dashboard Tor hidden-service hostname; run './pithead status' later to see the address."
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    DASHBOARD_ONION=$(docker exec tor cat /var/lib/tor/dashboard/hostname)
}

# `onion-client-key` (#343): print the operator's Tor client-auth line for the dashboard onion. Its
# own command — deliberately NOT part of `status`, which is a shareable report — because it prints
# the client PRIVATE key. The operator drops this line into their Tor client's ClientOnionAuthDir.
onion_client_key() {
    require_env
    [ "$(env_get DASHBOARD_ONION_ENABLED)" == "true" ] ||
        error "The dashboard onion is not enabled (set dashboard.onion.enabled: true, then '$0 apply')."
    [ "$(env_get DASHBOARD_ONION_CLIENT_AUTH)" == "true" ] ||
        error "Client authorization is off for the dashboard onion (dashboard.onion.client_auth: false) — it is password-only, so there is no client key."
    local onion privkey
    onion=$(env_get DASHBOARD_ONION_ADDRESS)
    privkey=$(env_get DASHBOARD_ONION_CLIENT_PRIVKEY)
    { [ -n "$onion" ] && [ "$onion" != "placeholder" ] && [ -n "$privkey" ] && [ "$privkey" != "placeholder" ]; } ||
        error "The dashboard onion isn't fully provisioned yet — run '$0 apply' first."
    cat <<EOF
Tor onion client-auth for the dashboard — KEEP THIS PRIVATE, it is a secret key.
Dashboard onion address:  http://$onion

Pick whichever Tor client you use to reach it:

• Tor Browser (easiest): open  http://$onion  (Tor Browser upgrades it to https;
  accept the one-time self-signed-cert prompt, same as the LAN dashboard). It
  prompts for the onion's private key. Paste JUST this key:

    $privkey

• System Tor / Orbot (persistent): put this one line in a file (e.g.
  dashboard.auth_private) inside the directory set by ClientOnionAuthDir in your
  torrc (create it mode 0700), then reload Tor:

    ${onion%.onion}:descriptor:x25519:$privkey
EOF
}

# `rotate-dashboard-onion` (#343): mint a fresh .onion address and a fresh client-auth key. A leaked
# address or client key is otherwise permanent. Wipes only the dashboard hidden-service dir (the
# mining onions are untouched), then re-provisions and restarts caddy.
rotate_dashboard_onion() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for rotate-dashboard-onion: $arg. Run '$0 help'." ;;
        esac
    done
    require_env
    parse_and_validate_config
    load_preserved_state
    [ "$DASHBOARD_ONION_ENABLED" == "true" ] ||
        error "The dashboard onion is not enabled — nothing to rotate."
    warn "This regenerates the dashboard's .onion ADDRESS and its client-auth key. The old address and any client keys you handed out stop working immediately."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Rotate the dashboard onion now? (y/N): " CONFIRM || true
        [[ "$CONFIRM" =~ ^[Yy] ]] || {
            log "Rotation cancelled."
            return 0
        }
    fi
    local hs_dir="$TOR_DATA_DIR/dashboard"
    [ -n "$TOR_DATA_DIR" ] && [ "${hs_dir##*/}" == "dashboard" ] ||
        error "Refusing to wipe an unexpected path (\"$hs_dir\")."
    log "Stopping tor and wiping the dashboard hidden service..."
    docker compose stop tor >/dev/null 2>&1 || true
    sudo rm -rf "$hs_dir" 2>/dev/null || rm -rf "$hs_dir" 2>/dev/null || true
    # Force fresh keys + address on the next provision.
    DASHBOARD_ONION="placeholder"
    DASHBOARD_ONION_CLIENT_PUBKEY="placeholder"
    DASHBOARD_ONION_CLIENT_PRIVKEY="placeholder"
    provision_tor          # rewrites authorized_clients (fresh key), starts tor, reads the new address
    resolve_dashboard_host # #356: sets HOST_IP for render_env — rotate skipped it, so render_env died
    # on the unbound HOST_IP under `set -u` (setup/apply/upgrade all resolve the host before rendering).
    # #356: render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and load_preserved_state
    # doesn't carry it, so preserve the current value — otherwise rotate silently reset the flag to false
    # and the next apply/upgrade errored "Stack is not fully provisioned. Run setup first."
    DEPLOYMENT_COMPLETED=$(env_get DEPLOYMENT_COMPLETED)
    render_env         # persist the new address + keys
    generate_caddyfile # #546: without this the Caddyfile still points at the retired address's vhost
    docker compose restart caddy >/dev/null 2>&1 || true
    log "Dashboard onion rotated."
    if [ "$DASHBOARD_ONION_CLIENT_AUTH" == "true" ]; then
        onion_client_key
    else
        log "New dashboard onion: http://$(env_get DASHBOARD_ONION_ADDRESS)"
    fi
}

# `rotate-secrets` (#378): regenerate the stack's internal credentials in one command. After a
# suspected leak (a backup that left the box, a `.env` pasted into a bug report) the only
# alternative is hand-editing files and knowing which containers to recreate. Rotates the local
# Monero RPC password (skipped in remote mode — that credential belongs to the remote node), the
# stratum access-password when p2pool.stratum_password is "auto" (a literal lives in config.json;
# empty means auth is off), and PROXY_AUTH_TOKEN (always). The dashboard onion keys/address have
# their own command (rotate-dashboard-onion) and are not touched. The old values stay recoverable
# in timestamped owner-only copies of config.json and .env taken before anything changes.
rotate_secrets() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for rotate-secrets: $arg. Run '$0 help'." ;;
        esac
    done
    require_deployed
    parse_and_validate_config
    load_preserved_state

    # Compute the "what will rotate" preview from the PARSED config, not by grepping .env — the
    # stratum mode in config.json (auto vs literal vs empty) decides the behavior, not the rendered value.
    local stratum_mode rotate_stratum=0
    stratum_mode=$(jq -r '.p2pool.stratum_password // ""' "$CONFIG_FILE")

    log "This rotates the stack's internal credentials:"
    if [ "$MONERO_MODE" == "local" ]; then
        log "  • Monero node RPC password — internal to the stack; no follow-up needed."
    else
        log "  • Monero RPC password: skipped — monero.mode is \"remote\", so the credential belongs to the remote node, not this stack."
    fi
    if [ "$stratum_mode" == "auto" ]; then
        warn "  • Stratum access-password — EVERY RIG must update its stratum 'pass' to the new value or it is rejected."
    elif [ -n "$stratum_mode" ]; then
        log "  • Stratum access-password: skipped — p2pool.stratum_password is set explicitly in config.json; change it there and run '$0 apply'."
    fi
    log "  • xmrig-proxy control-API token — internal to the stack; no follow-up needed."
    log "The containers that consume them are recreated (brief restart; chain data and dashboard history are untouched)."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Rotate these secrets now? (y/N): " CONFIRM || true
        [[ "$CONFIRM" =~ ^[Yy] ]] || {
            log "Rotation cancelled."
            return 0
        }
    fi

    # Serialise the mutating half against every other pithead operation (#1482). Taken HERE, after
    # the confirmation and before the first write: everything above is read-only — the preview is
    # computed from the parsed config rather than the rendered .env — and the prompt above blocks on
    # the operator's keystroke, so a window opened any earlier would park every other verb for as
    # long as nobody answers. Everything below mutates, starting with the safety copies, so a
    # timeout here has genuinely changed nothing, which is what the timeout message promises. A
    # timeout exits PITHEAD_EX_LOCK_TIMEOUT, distinct from this verb's own failure exit below.
    mutation_lock_acquire rotate-secrets

    # Keep the OLD values recoverable before anything changes: timestamped owner-only copies of the
    # two files that carry them. Refuse to rotate at all if the safety copies can't be written.
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    (
        umask 077
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-${stamp}" &&
            cp "$ENV_FILE" "${ENV_FILE}.bak-${stamp}"
    ) || error "Could not write the pre-rotation safety copies — nothing was rotated."
    log "Pre-rotation copies saved (${CONFIG_FILE}.bak-${stamp}, ${ENV_FILE}.bak-${stamp}) — they hold the OLD secrets; delete them once the stack is confirmed healthy."

    # Regenerate, overriding what parse_and_validate_config / load_preserved_state just preserved.
    # Same generators as the originals, so every consumer's validation keeps holding.
    if [ "$MONERO_MODE" == "local" ]; then
        MONERO_PASS=$(generate_node_password)
        persist_node_credentials "$MONERO_USER" "$MONERO_PASS" # atomic write-back to config.json
    fi
    if [ "$stratum_mode" == "auto" ]; then
        STRATUM_PASSWORD=$(openssl rand -hex 12)
        rotate_stratum=1
    fi
    PROXY_AUTH_TOKEN=$(openssl rand -hex 12)

    resolve_dashboard_host # #356: sets HOST_IP for render_env, which dies unbound without it
    # #356: render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and
    # load_preserved_state doesn't carry it — preserve it or the next apply errors "run setup".
    DEPLOYMENT_COMPLETED=$(env_get DEPLOYMENT_COMPLETED)
    render_env
    inject_service_configs # keep the generated service configs current before the recreate
    # Recreate marker (#125): .env is committed now, so if the recreate below fails, a plain
    # `apply` would diff no changes and no-op — the marker makes it retry the recreate instead.
    local apply_marker="${ENV_FILE}.apply-incomplete"
    : >"$apply_marker"
    log "Recreating the containers that consume the rotated secrets..."
    # `up` recreates exactly the services whose env/args changed (monerod, p2pool, xmrig-proxy,
    # dashboard). Never `compose restart` here: restart reuses the OLD container args, so p2pool
    # would keep dialing monerod with the retired --rpc-login.
    if ! compose_up_checked -d; then
        warn "Secrets were rotated in config.json/.env but the containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause above, then run '$0 apply' to retry the recreate — or restore the pre-rotation copies (${CONFIG_FILE}.bak-${stamp}, ${ENV_FILE}.bak-${stamp}) and run '$0 apply'."
        exit 1 # leave $apply_marker so the retry re-attempts the recreate
    fi
    rm -f "$apply_marker"

    log "Secrets rotated. The old values are invalid; only the safety copies above still hold them."
    if [ "$rotate_stratum" -eq 1 ]; then
        announce_stratum_auth
        warn "The stratum access-password CHANGED — every rig is rejected until its stratum 'pass' is updated to the value above."
    fi
    mutation_lock_release
}
