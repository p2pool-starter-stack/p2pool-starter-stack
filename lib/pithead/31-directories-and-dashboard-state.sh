# Control-channel spool layout (#33). requests/ is the ONLY leg the dashboard container may write
# (chowned to its uid); staged/ stays host-only — the container mounts results/, audit/ and the
# pre-masked masked/ copy (#440) read-only and never sees staged/ at all. That rw/ro split is the
# trust boundary: the container can only ask; it cannot forge a result, rewrite the audit log,
# alter a staged intent between preview and commit, or read a secret out of the live config.
prepare_control_dirs() {
    mkdir -p "$CONTROL_DIR/requests" "$CONTROL_DIR/staged" "$CONTROL_DIR/results" "$CONTROL_DIR/audit"
    ensure_owner "$CONTROL_DIR/requests" "$APP_UID" "$APP_GID"
    # Appliance only: seed the OS-update state file the dashboard reads through the results/
    # mount. Its presence is what tells the container "this is an appliance — render the OS
    # update control"; the os-* verbs and pithead-boot keep it current from then on.
    if is_appliance && [ ! -f "$CONTROL_DIR/results/os-update-state.json" ]; then
        os_state_write "$CONTROL_DIR" '{"step":"idle"}'
    fi
    # Re-render the masked prefill copy on every setup/apply/upgrade (#440) — any path that can
    # change config.json runs through here, so the copy can never serve a stale schema for long.
    render_masked_config "$CONTROL_DIR"
    # Caddy access-log dir (#349): root-owned so the capability-stripped caddy container (uid 0,
    # no CAP_DAC_OVERRIDE) can write it; the dashboard (uid 1000) reads it via a ro mount — the
    # Caddyfile's `mode 0644` keeps the files readable.
    mkdir -p "$CADDY_LOG_DIR"
    ensure_owner "$CADDY_LOG_DIR" 0 0
}

# List "*_DATA_DIR=path" lines from .env whose directory is MISSING — the signature of a relocated
# or copied install, or a second checkout, where the stack would silently start a FRESH sync and
# orphan the dashboard SQLite history (#126). Data dirs are stored as absolute paths in .env, so a
# moved install leaves .env naming the old path; Docker then auto-creates an empty dir and re-syncs.
# Empty unless the stack has been deployed (on first setup the dirs legitimately don't exist yet).
missing_data_dirs() {
    [ "$(env_get DEPLOYMENT_COMPLETED 2>/dev/null)" = "true" ] || return 0
    local var dir
    for var in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR TOR_DATA_DIR; do
        dir=$(env_get "$var" 2>/dev/null)
        [ -n "$dir" ] && [ ! -d "$dir" ] && printf '%s=%s\n' "$var" "$dir"
    done
    return 0
}

# Loud warning (on `up`) when .env names data dirs that don't exist — see missing_data_dirs (#126).
warn_missing_data_dirs() {
    local stale line
    stale=$(missing_data_dirs)
    [ -n "$stale" ] || return 0
    warn "Data directories named in .env are MISSING — did you relocate, copy, or run a different checkout of this install?"
    while IFS= read -r line; do warn "  ${line%%=*} → ${line#*=} (not found)"; done <<<"$stale"
    warn "The stack will start a FRESH sync and the dashboard history will be orphaned. To keep your synced chains,"
    warn "move the data to these paths, or set the data_dir(s) in config.json (absolute) and run './pithead apply'."
}

# chown -R "$dir" to $uid:$gid, but ONLY when something in it isn't already owned by $uid. Keeps a
# routine apply sudo-free in steady state, while migrating an existing install in one pass the first
# time the owning uid changes — e.g. the root->non-root container switch (#255). We scan the whole
# tree, not just the top-level dir: an install upgraded from the root-container era has a user-owned
# data dir but root-owned *contents* (the daemons wrote bitmonero.conf, the SQLite DB, etc. as
# root), and those are exactly what the non-root container can no longer overwrite. `find … -quit`
# stops at the first foreign inode, so a clean dir stays a quick metadata scan with no chown/sudo.
ensure_owner() {
    local d="$1" want_u="$2" want_g="$3"
    [ -d "$d" ] || return 0
    [ -z "$(find "$d" ! -uid "$want_u" -print -quit 2>/dev/null)" ] && return 0
    log "Setting ownership of $d to $want_u:$want_g (non-root containers)..."
    sudo chown -R "$want_u":"$want_g" "$d"
}

# Lightweight directory check for `apply`/`upgrade`: create any missing data dir, then ensure each is
# owned by the uid its container runs as. ensure_owner is conditional, so a routine apply stays
# sudo-free once ownership is correct; the first run after the non-root switch migrates the data.
ensure_directories() {
    local d created=()
    for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" "$PROXY_TLS_DIR"; do
        [ -d "$d" ] || { mkdir -p "$d" && created+=("$d"); }
    done
    mkdir -p "$P2POOL_DIR/stats"
    ensure_owner "$TOR_DATA_DIR" 100 101
    ensure_owner "$MONERO_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$TARI_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$P2POOL_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$DASHBOARD_DIR" "$APP_UID" "$APP_GID"
    prepare_control_dirs    # #33: spool dirs exist + requests/ writable by the dashboard uid
    ensure_stratum_tls_cert # #261: keypair exists before compose mounts $PROXY_TLS_DIR
    [ "${#created[@]}" -gt 0 ] && sudo chmod -R 755 "$P2POOL_DIR/stats"
    return 0
}

# Generate the stratum TLS keypair once (#261). Self-signed and long-lived (3650 days): rigs
# authenticate the server by PINNING the certificate's SHA-256 fingerprint (xmrig does no CA
# validation for stratum), so CA trust and expiry play no part in the model — regenerating the
# cert IS the rotation, and every rig re-pins. The key is created under umask 077 and handed to
# the proxy uid read-only; the dir is mounted :ro into the container. No-op while the knob is
# off, and idempotent while the keypair exists — the fingerprint stays stable across applies.
ensure_stratum_tls_cert() {
    [ "${STRATUM_TLS:-false}" = "true" ] || return 0
    [ -f "$PROXY_TLS_DIR/cert.pem" ] && [ -f "$PROXY_TLS_DIR/key.pem" ] && return 0
    command -v openssl >/dev/null 2>&1 ||
        error "p2pool.stratum_tls is true but openssl is not installed — it is needed once, to generate the stratum certificate."
    log "Generating the stratum TLS certificate — self-signed; rigs pin its fingerprint..."
    (
        umask 077
        openssl req -x509 -newkey rsa:2048 -keyout "$PROXY_TLS_DIR/key.pem" \
            -out "$PROXY_TLS_DIR/cert.pem" -days 3650 -nodes -subj "/CN=pithead-stratum" 2>/dev/null
    ) || error "OpenSSL could not generate the stratum TLS certificate in $PROXY_TLS_DIR."
    # The proxy runs as the unprivileged app uid (#255) and must read the key through the :ro
    # mount; the umask above already keeps both files owner-only until this narrows them.
    ensure_owner "$PROXY_TLS_DIR" "$APP_UID" "$APP_GID"
    chmod 600 "$PROXY_TLS_DIR/key.pem" 2>/dev/null || sudo chmod 600 "$PROXY_TLS_DIR/key.pem"
    chmod 644 "$PROXY_TLS_DIR/cert.pem" 2>/dev/null || sudo chmod 644 "$PROXY_TLS_DIR/cert.pem"
    announce_stratum_tls
}

# Surface the stratum TLS state + the fingerprint rigs must pin (#261) — the companion to
# announce_stratum_auth: the fingerprint is what RigForge setup asks for (pools[].tls-fingerprint).
# Public data (it's the cert's own digest), so printing it is safe anywhere.
announce_stratum_tls() {
    # Callable with or without a prior parse (status vs apply): fall back to the rendered .env.
    local enabled="${STRATUM_TLS:-}" dir="${PROXY_TLS_DIR:-}"
    [ -n "$enabled" ] || enabled=$(env_get PROXY_STRATUM_TLS)
    [ -n "$dir" ] || dir=$(env_get PROXY_TLS_DIR)
    [ "$enabled" = "true" ] && [ -n "$dir" ] && [ -f "$dir/cert.pem" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0
    local fp
    fp=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    [ -n "$fp" ] || return 0
    log "Stratum TLS is ON: rigs may connect with TLS on the same stratum port (cleartext still accepted). Pin this fingerprint on each rig (pools[].tls-fingerprint): $fp"
}

# One-time dashboard-data migration (#455): the dashboard DB used to default INSIDE the install
# dir (./data/dashboard) — the one data dir that moved with the code on every versioned deploy.
# When the resolved default now lives under the shared data root, move the old in-install data
# there once. Move-then-verify and idempotent: a no-op when the old default holds nothing (fresh
# install, or already migrated), a warning-only when the operator pinned dashboard.data_dir, and
# a hard stop when BOTH locations hold data — never guess which DB is live. Runs after the config
# is committed (apply) / right before the containers are recreated (upgrade), so a failed move is
# retried on the next run and the recreated dashboard always mounts the migrated directory.
migrate_dashboard_data() {
    local old="$PWD/data/dashboard" new="${DASHBOARD_DIR:-}"
    [ -n "$new" ] && [ "$old" != "$new" ] || return 0   # classic layout — nothing to move
    [ -n "$(ls -A "$old" 2>/dev/null)" ] || return 0    # old default empty/absent — nothing to move
    if [ "${DASHBOARD_DIR_IS_DEFAULT:-1}" -eq 0 ]; then # operator-pinned path: their data, their call
        warn "Dashboard data found at the old default $old, but dashboard.data_dir is set explicitly ($new) — leaving both alone. Move or remove $old yourself."
        return 0
    fi
    if [ -n "$(ls -A "$new" 2>/dev/null)" ]; then
        error "Dashboard data exists at BOTH the old default ($old) and the new one ($new) — refusing to guess which is live. Keep one, delete the other, then re-run."
    fi
    log "Moving the dashboard data to the shared data root: $old → $new..."
    # The dashboard writes its SQLite DB continuously — stop it for the move; the compose up that
    # follows every apply/upgrade brings it back on the new mount. Best-effort: already stopped is fine.
    docker compose stop dashboard >/dev/null 2>&1 || true
    local had_db=0
    [ -f "$old/mining_data.db" ] && had_db=1
    rmdir "$new" 2>/dev/null || true # drop a pre-created EMPTY target so mv renames instead of nesting
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new" || error "Could not move $old to $new — the data is still at $old, nothing was lost. Move it yourself (or set dashboard.data_dir), then re-run."
    if [ "$had_db" -eq 1 ] && [ ! -f "$new/mining_data.db" ]; then
        error "The dashboard DB is missing after the move — check $new and $old before starting the stack."
    fi
    log "Dashboard data migrated to $new."
}

# One authoritative pointer to the live install (#455): when this install lives in a versioned
# deploy dir (pithead-vX.Y.Z), keep a `current` symlink beside it pointing here — updated with
# `ln -sfn` on every successful setup/upgrade, so the live version dir is discoverable without
# docker inspect (the dashboard one-click upgrade, #59, runs `upgrade` and gets this for free).
# Relative target, so the whole tree can move. Any other layout (source checkout, plain
# `pithead/` extract) is left alone, and nothing here ever fails the surrounding command.
update_current_symlink() {
    local name parent
    name=$(basename "$PWD")
    [[ "$name" =~ ^pithead-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    parent=$(dirname "$PWD")
    if [ -e "$parent/current" ] && [ ! -L "$parent/current" ]; then
        warn "$parent/current exists but is not a symlink — leaving it alone. Point it at $name yourself."
        return 0
    fi
    if ln -sfn "$name" "$parent/current" 2>/dev/null; then
        log "Updated $parent/current -> $name."
    else
        warn "Could not update $parent/current -> $name (permissions?) — the stack is fine; fix the symlink by hand."
    fi
    return 0
}

# Decide the hostname the dashboard is reached at: an explicit dashboard.host wins; otherwise
# "auto"/unset means this machine's hostname, re-derived each run (so reverting to "auto" takes
# effect). Interactive setup prompts, defaulting to any previously-set value then the hostname.
resolve_dashboard_host() {
    local allow_prompt="${1:-}"
    # An interactive ask with no terminal is an EOF that silently picks the bare hostname —
    # exactly what happened on the appliance's headless pre-seed boot, whose dashboard then
    # served a name no LAN client resolves. No tty → the non-interactive rules decide.
    [ "$allow_prompt" == "interactive" ] && ! [ -t 0 ] && allow_prompt=""
    if [ -n "${DASHBOARD_HOST:-}" ]; then
        HOST_IP="$DASHBOARD_HOST"
        log "Using dashboard hostname '$HOST_IP' from $CONFIG_FILE."
    elif [ "$allow_prompt" == "interactive" ]; then
        local default_host
        default_host="${PRESERVED_HOST_IP:-$(hostname)}"
        echo "The stack needs to know what hostname you will use to access the dashboard in your browser."
        read -r -p "Enter Hostname [$default_host]: " input_host || true
        HOST_IP="${input_host:-$default_host}"
    else
        # "auto"/unset on a non-interactive run (e.g. apply): always the machine hostname, so
        # setting dashboard.host back to "auto" reverts HOST_IP instead of keeping a stale value.
        # On the appliance the browsable name is what avahi publishes — <hostname>.local — not the
        # bare hostname, which no client on the LAN can resolve.
        if is_appliance; then
            HOST_IP="$(hostname).local"
        else
            HOST_IP=$(hostname)
        fi
    fi
}
