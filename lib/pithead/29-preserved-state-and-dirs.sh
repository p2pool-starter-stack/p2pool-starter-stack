# Load secrets and one-time-provisioned values from an existing .env so that re-rendering
# (apply, or a re-run setup) never rotates the proxy token or loses the Tor onion addresses.
# Generates a fresh proxy token only when none exists yet.
load_preserved_state() {
    PROXY_AUTH_TOKEN=$(env_get PROXY_AUTH_TOKEN)
    # View-only wallet-rpc login (#381): the dashboard→wallet-rpc password. Generated once and
    # preserved across applies (like PROXY_AUTH_TOKEN) so both containers keep matching creds.
    WALLET_RPC_PASSWORD=$(env_get WALLET_RPC_PASSWORD)
    # View-only Tari wallet password (#462): encrypts the wallet DB on its named volume. MUST stay
    # stable across applies or the existing wallet file can't be reopened — preserve like the above.
    TARI_WALLET_PASSWORD=$(env_get TARI_WALLET_PASSWORD)
    MONERO_ONION=$(env_get MONERO_ONION_ADDRESS)
    TARI_ONION=$(env_get TARI_ONION_ADDRESS)
    P2POOL_ONION=$(env_get P2POOL_ONION_ADDRESS)
    DASHBOARD_ONION=$(env_get DASHBOARD_ONION_ADDRESS)
    DASHBOARD_ONION_CLIENT_PUBKEY=$(env_get DASHBOARD_ONION_CLIENT_PUBKEY)
    DASHBOARD_ONION_CLIENT_PRIVKEY=$(env_get DASHBOARD_ONION_CLIENT_PRIVKEY)
    PRESERVED_HOST_IP=$(env_get HOST_IP)

    [ -n "$PROXY_AUTH_TOKEN" ] || PROXY_AUTH_TOKEN=$(openssl rand -hex 12)
    [ -n "$WALLET_RPC_PASSWORD" ] || WALLET_RPC_PASSWORD=$(openssl rand -hex 12)
    [ -n "$TARI_WALLET_PASSWORD" ] || TARI_WALLET_PASSWORD=$(openssl rand -hex 16)
    [ -n "$MONERO_ONION" ] || MONERO_ONION="placeholder"
    [ -n "$TARI_ONION" ] || TARI_ONION="placeholder"
    [ -n "$P2POOL_ONION" ] || P2POOL_ONION="placeholder"
    [ -n "$DASHBOARD_ONION" ] || DASHBOARD_ONION="placeholder"
    [ -n "$DASHBOARD_ONION_CLIENT_PUBKEY" ] || DASHBOARD_ONION_CLIENT_PUBKEY="placeholder"
    [ -n "$DASHBOARD_ONION_CLIENT_PRIVKEY" ] || DASHBOARD_ONION_CLIENT_PRIVKEY="placeholder"
    return 0
}

prepare_directories() {
    log "Initializing data directories..."
    mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" "$CLEARNET_STATE_DIR" "$PROXY_TLS_DIR"
    mkdir -p "$P2POOL_DIR/stats"

    # Enforce permissions. Each data dir is owned by the uid its container runs as: Tor keeps its
    # alpine 'tor' user (100:101); the built images + tari run non-root as APP_UID:APP_GID (#255).
    # mkdir runs first (above) and chown last (#550) — an unprivileged mkdir into an already
    # chown -R'd tree EACCESes for any operator uid != APP_UID.
    sudo chown -R 100:101 "$TOR_DATA_DIR"
    sudo chown -R "$APP_UID":"$APP_GID" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$DASHBOARD_DIR"
    sudo chmod -R 755 "$P2POOL_DIR/stats"
    # World-writable so the dashboard container (its own uid) can drop the clearnet auto-transition
    # marker (#234) while monerod/tari mount it read-only. It holds only non-secret state markers.
    sudo chmod 777 "$CLEARNET_STATE_DIR" 2>/dev/null || chmod 777 "$CLEARNET_STATE_DIR" 2>/dev/null || true
    prepare_control_dirs
    # #261: setup reaches compose through THIS function (stack_up never runs ensure_directories),
    # so a hand-written config with stratum_tls:true at first setup must get its keypair here —
    # otherwise the mount is root-created empty and no fingerprint is ever announced.
    ensure_stratum_tls_cert
}
