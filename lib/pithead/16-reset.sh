reset_dashboard() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for reset-dashboard: $arg. Run '$0 help'." ;;
        esac
    done

    echo -e "${C_RED}[WARNING] This is a DESTRUCTIVE action.${C_RESET}"
    echo "It will stop the dashboard/p2pool containers and WIPE their data directories."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Are you sure you want to continue? (y/N): " CONFIRM || true
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            log "Reset cancelled."
            return
        fi
    fi

    # After the confirmation, never before it: the hold must not span a human wait, which is the
    # placement rule `setup` already follows (#1391). Everything below this line mutates — the
    # containers are removed and both data directories are deleted — so a lock timeout here has
    # genuinely changed nothing, which is exactly what the timeout message promises the operator.
    mutation_lock_acquire reset-dashboard

    log "Resetting dashboard and p2pool..."
    # Resolve what to delete from .env (the LIVE deployment's data dirs), NOT a fresh config.json
    # parse — otherwise editing a *.data_dir in config.json before `reset-dashboard` (without an
    # `apply`) would wipe a directory the running stack never used, possibly one the user just
    # pointed at. Refuse to guess if .env doesn't name them, and re-check they're safe to rm (#139).
    local dashboard_dir p2pool_dir
    dashboard_dir=$(env_get DASHBOARD_DATA_DIR)
    p2pool_dir=$(env_get P2POOL_DATA_DIR)
    if [ -z "$dashboard_dir" ] || [ -z "$p2pool_dir" ]; then
        error "Could not read DASHBOARD_DATA_DIR / P2POOL_DATA_DIR from .env — refusing to guess what to delete. Run '$0 setup' or '$0 apply' first."
    fi
    assert_safe_dir "$dashboard_dir"
    assert_safe_dir "$p2pool_dir"

    log "Stopping dashboard and p2pool containers..."
    docker compose rm -s -f -v dashboard p2pool

    log "Removing data directories..."
    [ -d "$dashboard_dir" ] && sudo rm -rf "$dashboard_dir"
    [ -d "$p2pool_dir" ] && sudo rm -rf "$p2pool_dir"

    log "Recreating data directories..."
    mkdir -p "$dashboard_dir" "$p2pool_dir"
    mkdir -p "$p2pool_dir/stats"
    # Owned by the non-root uid the dashboard + p2pool containers run as (#255). mkdir runs first
    # (above) and chown last (#550) — an unprivileged mkdir into an already chown -R'd tree
    # EACCESes for any operator uid != APP_UID, and here that abort would land AFTER the data wipe.
    sudo chown -R "$APP_UID":"$APP_GID" "$p2pool_dir" "$dashboard_dir"
    sudo chmod -R 755 "$p2pool_dir/stats"

    log "Bringing services back up..."
    # p2pool can dial clearnet, so assert the Tor-only egress firewall BEFORE it starts (#270/#291).
    # Idempotent if it's already present from `up`; closes the gap where running reset-dashboard on a
    # `down` stack would otherwise bring p2pool up with no firewall installed at all.
    apply_tor_egress_firewall
    # Route through compose_up_checked so a subnet collision (#180) gets explained, like every other
    # up-path. #557: wrapped in `if !` (mirroring the apply call site) — a bare call lets a compose
    # failure trip errexit inside compose_up_checked's own pipeline, before the #180 explanation
    # prints and before the mktemp temp file is cleaned up.
    if ! compose_up_checked -d dashboard p2pool; then
        warn "Data directories were reset, but dashboard/p2pool did NOT come back up ('docker compose up' failed)."
        warn "Fix the cause shown above, then re-run '$0 up' to bring them back."
        exit 1
    fi
    mutation_lock_release
}

# --- Two-tier reset (config / factory) -----------------------------------------------------------
# The appliance has no uninstall — its equivalents are these two reset tiers. A full wipe costs
# days of chain resync, so config-reset is the cheap tier: clear the configuration, keep every
# data directory. factory-reset is the deep one: wipe /data back to a blank machine.

# On the appliance, reboot into the first-boot path; elsewhere, just say what to run by hand. The
# reboot command is overridable so the test suite can assert it fires without rebooting the runner.
reset_reboot_or_hint() {
    if is_appliance; then
        _console "Rebooting into first-boot setup..."
        ${PITHEAD_REBOOT_CMD:-systemctl reboot} ||
            warn "Reboot command failed — reboot the machine by hand to reach the setup wizard."
    else
        log "Reconfigure with '$0 firstboot-wizard' (or '$0 setup') when you're ready."
    fi
}

# config-reset: back to unprovisioned, chains kept. Removing config.json is the whole mechanism —
# pithead-firstboot's ConditionPathExists=!config.json re-arms the wizard, and pithead-boot's
# opposite condition stands down. Every data directory (chains, Tor onion keys, wallets, dashboard
# history) stays: only config.json and the files rendered from it go, so reconfiguring costs no
# resync and the onion address survives.
config_reset() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for config-reset: $arg. Run '$0 help'." ;;
        esac
    done
    [ -f "$CONFIG_FILE" ] ||
        error "No $CONFIG_FILE here — already unprovisioned. The setup wizard opens on its own when config.json is absent."

    echo -e "${C_RED}[WARNING] This is a DESTRUCTIVE action.${C_RESET}"
    echo "It clears your configuration and reopens the setup wizard."
    log "Kept: chains, wallets, Tor onion keys, dashboard history — every data directory stays. Only config.json and the files rendered from it go."
    if [ "$assume_yes" -eq 0 ]; then
        printf "Type 'config-reset' to continue: "
        read -r arg || true
        [ "$arg" = "config-reset" ] || {
            log "Aborted — nothing changed."
            return 1
        }
    fi

    # After the typed confirmation, so the hold never spans a human wait (#1391), and before the
    # first mutation below — this verb REMOVES config.json, so a window taken any later would let a
    # timeout abandon a box whose configuration was already half gone.
    mutation_lock_acquire config-reset

    detect_os 2>/dev/null || true
    docker compose down --remove-orphans 2>/dev/null ||
        warn "compose down failed (engine not running?) — continuing with the config wipe."
    remove_tor_egress_firewall 2>/dev/null || true
    rm -f "$CONFIG_FILE" "$ENV_FILE" Caddyfile
    log "Configuration cleared — the first-boot wizard owns the next boot."
    # The reboot stays INSIDE the window on purpose. Releasing after the wipe but before the reboot
    # would leave a gap in which another verb could start against a box that has no config.json yet
    # still has its old containers' state — the half-reset window this lock exists to prevent.
    reset_reboot_or_hint
    mutation_lock_release
}

# factory-reset: the deep wipe. /data cannot be reformatted while it is mounted and holding the
# container store and the /var overlay, so the wipe runs one layer down: a marker on the ESP (which
# survives the wipe) arms pithead-data-reset, which reformats /data before it mounts on the next
# boot, then the box comes up blank into the wizard. Appliance-only — a normal install's clean exit
# is 'uninstall', where the operator owns the data dirs and can remove them deliberately.
factory_reset() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for factory-reset: $arg. Run '$0 help'." ;;
        esac
    done
    is_appliance ||
        error "factory-reset wipes the appliance data partition and only runs on the appliance. On a normal install, 'uninstall' is the clean exit — it keeps your data dirs for you to remove yourself."

    echo -e "${C_RED}[WARNING] This ERASES EVERYTHING on the data partition.${C_RESET}"
    echo "Chains, wallets, Tor onion keys, dashboard history, and all settings go. The box reboots"
    echo "to a blank setup wizard, and the chain resync that follows costs days."
    if [ "$assume_yes" -eq 0 ]; then
        printf "Type 'factory-reset' to continue: "
        read -r arg || true
        [ "$arg" = "factory-reset" ] || {
            log "Aborted — nothing changed."
            return 1
        }
    fi

    # Taken after the typed confirmation so the hold never spans a human wait (#1391). The marker
    # write below is a single line, but it is not the mutation that matters: arming it commits the
    # machine to a reboot that reformats /data, and an operation already holding the window would
    # otherwise be rebooted out from under itself mid-write.
    mutation_lock_acquire factory-reset

    # Arm the boot-time wipe. The marker lives on the ESP, not /data, precisely because /data is
    # what gets erased. If the ESP is not writable the wipe cannot be armed, so refuse loudly
    # rather than reboot into a box that quietly did nothing.
    local marker="$PRESEED_DIR/pithead-reset"
    : >"$marker" 2>/dev/null ||
        error "Could not arm the reset marker at $marker (ESP not mounted?) — nothing was wiped."
    log "Reset armed. Rebooting to reformat /data and reopen the wizard..."
    # Held across the reboot for the same reason as config-reset: the gap between arming the wipe
    # and the reboot is precisely when another verb must not start.
    reset_reboot_or_hint
    mutation_lock_release
}
