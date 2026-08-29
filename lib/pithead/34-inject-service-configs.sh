inject_service_configs() {
    log "Injecting service configurations..."
    cp build/tari/config.toml.template build/tari/config.toml
    local tari_onion_short="${TARI_ONION%%.*}"
    safe_sed "s/<your_tari_onion_address_no_extension>/$tari_onion_short/g" build/tari/config.toml
    # Rebase the Tor control/SOCKS IPs onto the configured subnet prefix (#180): a no-op at the
    # default 172.28.0, rewrites the .25 Tor IP when network.subnet has been moved.
    safe_sed "s/172\.28\.0/$NETWORK_PREFIX/g" build/tari/config.toml

    # config.toml is always rendered for Tor (onion, transport=tor) — the CANONICAL config. The
    # optional clearnet initial sync (#183) is applied per-start inside the container by
    # build/tari/entrypoint.sh (which copies this file and transforms the copy), gated on the
    # TARI_CLEARNET_SYNC flag AND the dashboard's auto-transition marker (#234) — so once synced the
    # node returns to Tor on its own and `apply` never re-renders clearnet over it. Same idea for
    # monerod, whose entrypoint envsubsts + transforms in-container. Here we only re-arm:

    # Re-arm clearnet auto-sync (#234): clear a chain's "sync complete" marker whenever its flag is
    # OFF, so re-enabling later starts a fresh clearnet sync. While a flag is ON the dashboard owns
    # the marker, so leave it. Markers live in the shared, dashboard-writable clearnet-state dir.
    local _csdir
    _csdir=$(clearnet_state_dir)
    mkdir -p "$_csdir" 2>/dev/null || true
    [ "$(env_get MONERO_CLEARNET_SYNC)" = "true" ] || rm -f "$_csdir/monero.synced" 2>/dev/null || true
    [ "$(env_get TARI_CLEARNET_SYNC)" = "true" ] || rm -f "$_csdir/tari.synced" 2>/dev/null || true
}
