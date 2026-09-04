doctor() {
    DR_OK=0
    DR_WARN=0
    DR_FAIL=0
    detect_os

    log "Running pithead diagnostics (read-only)..."
    echo "  Host: ${OS_PRETTY:-$OS_TYPE}"
    echo "  Version: $(show_version)"
    echo ""

    # --- Dependencies ---
    echo "Dependencies:"
    if command -v jq >/dev/null 2>&1; then
        dr_ok "jq found ($(jq --version 2>/dev/null || echo 'unknown version'))."
    else
        dr_fail_surface "jq not found — install it (Ubuntu: 'sudo apt-get install -y jq')." "jq is not present, so doctor cannot read this machine's configuration. The appliance image ships it, so this system copy is faulty."
    fi
    if command -v openssl >/dev/null 2>&1; then
        dr_ok "openssl found."
    else
        dr_fail_surface "openssl not found — install it (Ubuntu: 'sudo apt-get install -y openssl')." "openssl is not present, so the dashboard certificate cannot be checked. The appliance image ships it, so this system copy is faulty."
    fi
    if command -v docker >/dev/null 2>&1; then
        dr_ok "docker found ($(docker --version 2>/dev/null || echo 'unknown version'))."
    else
        dr_fail_surface "docker not found — install Docker and the compose v2 plugin." "The container engine is not present, so the mining stack cannot start. The appliance image ships it, so this system copy is faulty."
    fi
    if docker compose version >/dev/null 2>&1; then
        dr_ok "docker compose (v2 plugin) found."
    else
        dr_fail_surface "docker compose (v2 plugin) not found — install 'docker-compose-v2'." "The container engine's compose plugin is not present, so the mining stack cannot start. The appliance image ships it, so this system copy is faulty."
    fi
    check_release_verification

    # --- Docker daemon ---
    echo ""
    echo "Docker daemon:"
    if [ "$(container_engine)" = "podman" ]; then
        if podman info >/dev/null 2>&1; then
            dr_ok "Container engine (podman) is reachable."
        else
            dr_fail "Container engine (podman) is not reachable — check 'systemctl status podman.socket' (rootful podman has no daemon; the socket serves the API)."
        fi
    elif ! command -v docker >/dev/null 2>&1; then
        dr_info "Skipped — docker is not installed."
    elif docker info >/dev/null 2>&1; then
        dr_ok "Docker daemon is reachable."
    else
        dr_fail_surface "Docker daemon is not reachable — start it (e.g. 'sudo systemctl start docker') and ensure your user is in the 'docker' group." "The container engine is not reachable, so the mining stack cannot run. This machine starts it at boot, so this system copy is faulty."
    fi

    # --- Docker boot persistence (Linux/systemd) ---
    # `restart: unless-stopped` only brings the stack back after a reboot if the Docker daemon
    # itself starts at boot. Ubuntu's docker.io/docker-ce enables it by default, but --skip-deps,
    # rootless, or a manually-disabled unit won't come back after a power loss — surface that, since
    # the documented use case is an unattended miner (#137).
    if [ "$OS_TYPE" != "Darwin" ] && command -v systemctl >/dev/null 2>&1; then
        echo ""
        echo "Boot persistence:"
        if docker_boot_enabled; then
            dr_ok "Docker is enabled to start at boot — the stack will come back after a reboot."
        else
            dr_warn_surface "The container engine is NOT enabled to start at boot — after a power loss/reboot the stack won't restart. Fix: 'sudo systemctl enable --now docker' (docker) or 'sudo systemctl enable --now podman.socket' (podman)." "The container engine is NOT enabled to start at boot — after a power loss or reboot the mining stack won't restart. This machine enables it at install time, so this system copy is faulty."
        fi
    fi

    check_control_units

    # --- CPU: AVX2 (performance only) ---
    echo ""
    echo "CPU:"
    if cpu_has_avx2; then
        dr_ok "AVX2 supported."
    else
        dr_warn "AVX2 not detected — mining performance will be poor (performance only, not fatal)."
    fi

    # --- Time sync (mining is time-sensitive; P2Pool strongly recommends NTP before mining) ---
    case "$(clock_sync_status)" in
    synced) dr_ok "System clock is NTP-synchronized." ;;
    unsynced) dr_warn_surface "System clock is NOT NTP-synchronized — clock skew gets shares/blocks rejected. Enable time sync: 'sudo timedatectl set-ntp true' (or run chrony/systemd-timesyncd/ntpd)." "System clock is NOT NTP-synchronized — clock skew gets shares and blocks rejected. There is no dashboard control that sets the clock." ;;
    *) dr_info "Could not verify system-clock sync (no timedatectl) — make sure NTP is running; mining is time-sensitive." ;;
    esac

    # --- Monero payout address must be a PRIMARY address (p2pool can't pay subaddresses/integrated) (#250) ---
    if [ -f "$CONFIG_FILE" ]; then
        local _mw
        _mw=$(jq -r '.monero.wallet_address // empty' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$_mw" ] && [ "$_mw" != "your_monero_wallet_address" ]; then
            case "$(monero_address_type "$_mw")" in
            primary) dr_ok "Monero payout address is a primary address (p2pool/XvB can pay it)." ;;
            subaddress) dr_fail_surface "Monero payout address is a SUBADDRESS (8…) — p2pool CANNOT pay it, so you are NOT being paid. Set monero.wallet_address to your PRIMARY address (4…) and run './pithead apply'." "Monero payout address is a SUBADDRESS (8…) — p2pool CANNOT pay it, so you are NOT being paid. It must be your PRIMARY address (4…). A payout address is not editable from the dashboard: changing it needs console access to this machine." ;;
            integrated) dr_fail "Monero payout address is an INTEGRATED address — p2pool can't pay it. Use your plain PRIMARY address (4…)." ;;
            checksum) dr_fail_surface "Monero payout address FAILS its checksum — at least one character is mistyped, and p2pool crashes on it at startup. Re-copy the address from your wallet into monero.wallet_address and run './pithead apply'." "Monero payout address FAILS its checksum — at least one character is mistyped, and p2pool crashes on it at startup. Re-copy it from your wallet rather than fixing it by eye. A payout address is not editable from the dashboard: changing it needs console access to this machine." ;;
            *) dr_warn "Monero payout address doesn't look like a primary address (expected 95 chars starting with 4)." ;;
            esac
        fi
        # Same class of check for the Tari payout address: both forms carry a DammSum checksum.
        local _tw
        _tw=$(jq -r '.tari.wallet_address // empty' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$_tw" ] && [ "$_tw" != "your_tari_wallet_address" ]; then
            case "$(tari_address_type "$_tw")" in
            ok) dr_ok "Tari payout address passes its checksum." ;;
            unchecked) dr_info "Could not verify the Tari payout address checksum (no usable python3)." ;;
            checksum) dr_fail_surface "Tari payout address FAILS its checksum — at least one character is mistyped, and Tari rewards are silently lost. Re-copy the address from your Tari wallet into tari.wallet_address and run './pithead apply'." "Tari payout address FAILS its checksum — at least one character is mistyped, and Tari rewards are silently lost. Re-copy it from your Tari wallet rather than fixing it by eye. A payout address is not editable from the dashboard: changing it needs console access to this machine." ;;
            network) dr_fail_surface "Tari payout address is for a different Tari network — this stack mines MAINNET Tari. Set tari.wallet_address to your mainnet address and run './pithead apply'." "Tari payout address is for a different Tari network — this machine mines MAINNET Tari, and this address came from a testnet wallet. A payout address is not editable from the dashboard: changing it needs console access to this machine." ;;
            *) dr_warn "Tari payout address doesn't look like a valid Tari address (base58 or emoji form)." ;;
            esac
        fi
    fi

    # --- Memory (Linux only) ---
    echo ""
    echo "Memory:"
    if [ "$OS_TYPE" != "Linux" ]; then
        dr_info "Skipped HugePages / free-RAM checks — not supported on $OS_TYPE (Linux-only)."
    else
        local huge_total huge_free
        huge_total=$(awk '/^HugePages_Total/{print $2}' /proc/meminfo 2>/dev/null || true)
        huge_free=$(awk '/^HugePages_Free/{print $2}' /proc/meminfo 2>/dev/null || true)
        if [ -z "$huge_total" ]; then
            dr_warn "Could not read HugePages from /proc/meminfo."
        elif [ "$huge_total" -gt 0 ] 2>/dev/null; then
            dr_ok "HugePages reserved: ${huge_total} total, ${huge_free:-?} free (RandomX uses these)."
        else
            dr_warn_surface "HugePages_Total is 0 — RandomX mining is slower. Run './pithead setup' (kernel optimization) to reserve them." "HugePages_Total is 0 — RandomX mining is slower. There is no dashboard control that reserves them."
        fi
        check_hugepages_degraded
        check_local_miner_hugepages_blocked

        # Runtime counterpart to setup's capacity pre-flight: preflight_resources checks MemTotal
        # (does the host have enough RAM at all), this checks MemAvailable (is enough free right
        # now). The split is intentional — keep both.
        local mem_avail_kb mem_avail_mb
        mem_avail_kb=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || true)
        if [ -z "$mem_avail_kb" ]; then
            dr_warn "Could not read MemAvailable from /proc/meminfo."
        else
            mem_avail_mb=$((mem_avail_kb / 1024))
            if [ "$mem_avail_mb" -ge 2048 ] 2>/dev/null; then
                dr_ok "Free RAM: ${mem_avail_mb} MiB available."
            else
                dr_warn "Free RAM low: ${mem_avail_mb} MiB available — the stack (Tari especially) may be memory-starved."
            fi
        fi
    fi

    # --- Network: public-IP exposure of the unauthenticated stratum port (#113) ---
    echo ""
    echo "Network:"
    check_stratum_exposure doctor
    check_stratum_listening
    check_tor_running
    check_egress_firewall_installed
    check_tor_clearnet_egress
    # Clearnet initial sync (#183): a deliberate, privacy-relevant opt-in. Warn whenever it's on so
    # an operator who forgot to switch back after syncing is reminded their node IP is exposed.
    if [ -f "$ENV_FILE" ] && clearnet_sync_active; then
        local _cn=""
        monero_clearnet_exposed && _cn="Monero"
        tari_clearnet_exposed && _cn="${_cn:+$_cn + }Tari"
        dr_warn "CLEARNET initial sync is ON for $_cn — P2P runs over clearnet and this host's IP is exposed to that network (Monero tx-broadcast still on Tor). See $DOCS_URL/docs/privacy.md#optional-clearnet-initial-sync-off-by-default. The dashboard switches each node back to Tor automatically once it's synced; this WARN clears when the transition completes."
    else
        dr_ok "No clearnet initial sync active — all node P2P is Tor-only."
    fi

    # p2pool Tor-routing fail-safe (#273): with clearnet off, P2POOL_FLAGS carries the #165 --socks5;
    # the RUNNING p2pool must actually carry it. A STALE p2pool image (pre-#165 entrypoint) ignores the
    # env var and dials sidechain peers directly — over CLEARNET, exposing the home IP. The #270 firewall
    # now DROPs that dial (so a stale p2pool just can't peer rather than leaking), but surface the cause
    # loudly so the fix — rebuild with 'pithead upgrade' — is obvious instead of a silent leak/stall.
    # Read the EXEC'd args from /proc/1/cmdline (the env flags are word-split in the entrypoint, so they
    # never appear in the container's Args). Empty = p2pool not running (often an intentional sync hold
    # #31/#35) — don't flag.
    if printf '%s' "$(env_get P2POOL_FLAGS 2>/dev/null)" | grep -q -- '--socks5'; then
        local _p2args
        _p2args=$(docker exec p2pool cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')
        case "$_p2args" in
        "") : ;;
        *--socks5*) dr_ok "p2pool routes outbound sidechain P2P via Tor (#165)." ;;
        *) dr_fail_surface "p2pool is NOT routing over Tor despite p2pool.clearnet=false — its sidechain P2P would hit CLEARNET (exposing your IP). Almost certainly a STALE p2pool image not applying P2POOL_FLAGS (#165/#273): run './pithead upgrade' to rebuild it. (#270's egress firewall blocks the dial meanwhile, so p2pool can't peer until you do.)" "p2pool is NOT routing over Tor despite p2pool.clearnet=false — its sidechain P2P would hit CLEARNET (exposing your IP). Almost certainly a STALE p2pool image not applying its Tor flags: install the latest update from the dashboard to rebuild it. (The Tor-only egress firewall blocks the dial meanwhile, so p2pool cannot peer until you do.)" ;;
        esac
    fi

    # --- Disk: free space per underlying filesystem ---
    echo ""
    echo "Disk:"
    # Treat the stack as one unit: group the five data dirs by the filesystem they live on and check
    # each filesystem ONCE against the combined requirement of the dirs sharing it (so dirs on the
    # same volume yield a single line, not one redundant "N GB free" line per dir). Dirs come from
    # .env when present, else the default ./data layout. check_disk_grouped is read-only (df -P only,
    # on existing ancestors) and never creates anything. The component order MUST match its arg list:
    # monero, tari, p2pool, dashboard, tor.
    local mono_dir tari_dir p2pool_dir dash_dir tor_dir doctor_prune
    if [ -f "$ENV_FILE" ]; then
        mono_dir=$(env_get MONERO_DATA_DIR)
        [ -n "$mono_dir" ] || mono_dir="$PWD/data/monero"
        tari_dir=$(env_get TARI_DATA_DIR)
        [ -n "$tari_dir" ] || tari_dir="$PWD/data/tari"
        p2pool_dir=$(env_get P2POOL_DATA_DIR)
        [ -n "$p2pool_dir" ] || p2pool_dir="$PWD/data/p2pool"
        dash_dir=$(env_get DASHBOARD_DATA_DIR)
        [ -n "$dash_dir" ] || dash_dir="$PWD/data/dashboard"
        tor_dir=$(env_get TOR_DATA_DIR)
        [ -n "$tor_dir" ] || tor_dir="$PWD/data/tor"
        # .env renders MONERO_PRUNE as 1 (pruning on) / 0 (off); default to pruned if unset.
        doctor_prune=$(env_get MONERO_PRUNE)
        [ -n "$doctor_prune" ] || doctor_prune=1
        # A remote node (#103) keeps its chain elsewhere, so its dir must not count toward THIS
        # host's disk budget — otherwise doctor demands ~120 GiB (Monero) / ~200 GiB (Tari) for a
        # container that never runs, on exactly the small-disk hosts remote mode exists for. Read
        # the mode from the profile tokens like the container checks above; a pre-#103 .env has no
        # local_tari token yet, so require a rendered TARI_GRPC_ADDRESS (also new in #103) before
        # trusting its absence — old installs keep the local budget until the next apply re-renders.
        local doctor_profiles
        doctor_profiles=$(env_get COMPOSE_PROFILES)
        if [[ ",$doctor_profiles," != *",local_node,"* ]]; then
            mono_dir=""
        fi
        if [ -n "$(env_get TARI_GRPC_ADDRESS)" ] && [[ ",$doctor_profiles," != *",local_tari,"* ]]; then
            tari_dir=""
        fi
    else
        mono_dir="$PWD/data/monero"
        tari_dir="$PWD/data/tari"
        p2pool_dir="$PWD/data/p2pool"
        dash_dir="$PWD/data/dashboard"
        tor_dir="$PWD/data/tor"
        doctor_prune=1
        dr_info "No data dirs in $ENV_FILE — checking the default ./data location."
    fi
    check_disk_grouped doctor "$doctor_prune" \
        "$mono_dir" "$tari_dir" "$p2pool_dir" "$dash_dir" "$tor_dir"

    # Data dirs named in .env that don't exist => a relocated/copied install (or a second checkout)
    # will re-sync from scratch and orphan the dashboard history (#126).
    local _stale _l
    _stale=$(missing_data_dirs)
    if [ -n "$_stale" ]; then
        while IFS= read -r _l; do
            dr_warn "Data dir from .env not found: ${_l%%=*}=${_l#*=} — a relocated/copied install re-syncs from scratch. Move the data here, or set the data_dir in config.json and run 'apply'."
        done <<<"$_stale"
    elif [ "$(env_get DEPLOYMENT_COMPLETED 2>/dev/null)" = "true" ]; then
        dr_ok "Data directories named in .env are present."
    fi

    # --- .env / deployment state ---
    echo ""
    echo "Deployment:"
    if [ ! -f "$ENV_FILE" ]; then
        dr_warn_surface "No $ENV_FILE found — the stack has not been set up. Run './pithead setup'. (Skipping env-dependent checks.)" "The stack has not been set up — finish setup from this machine's setup page. (Skipping the checks that depend on it.)"
    else
        dr_ok "$ENV_FILE present."
        if [ "$(env_get DEPLOYMENT_COMPLETED)" == "true" ]; then
            dr_ok "DEPLOYMENT_COMPLETED=true — setup finished."
        else
            dr_warn_surface "DEPLOYMENT_COMPLETED is not true — setup may be incomplete. Run './pithead setup'." "Setup did not finish — complete it from this machine's setup page."
        fi

        # --- Tor onion addresses ---
        echo ""
        echo "Tor onion addresses:"
        local k onion onion_profiles needs
        onion_profiles=",$(env_get COMPOSE_PROFILES),"
        for k in MONERO_ONION_ADDRESS TARI_ONION_ADDRESS P2POOL_ONION_ADDRESS; do
            # A node's inbound onion only exists while that node is local (#103) — key off the same
            # profile tokens as the container checks above, so remote mode reports "not needed"
            # instead of an address that was never meant to be provisioned. P2Pool always runs.
            case "$k" in
            MONERO_ONION_ADDRESS) needs="local_node" ;;
            TARI_ONION_ADDRESS) needs="local_tari" ;;
            *) needs="" ;;
            esac
            if [ -n "$needs" ] && [[ "$onion_profiles" != *",$needs,"* ]]; then
                dr_ok "$k not needed — that node runs elsewhere, so it has no inbound hidden service."
                continue
            fi
            onion=$(env_get "$k")
            if onion_missing "$onion"; then
                dr_warn_surface "$k is not provisioned (value: '${onion:-empty}') — re-run './pithead setup' to generate Tor hidden services." "$k is not provisioned (value: '${onion:-empty}') — the Tor hidden services have not been generated. Run setup again from this machine's setup page."
            else
                dr_ok "$k set."
            fi
        done
        # Dashboard onion (#343): only meaningful when opted in. Print the address — the operator needs
        # it to reach the panel — but never the client PRIVATE key: this status is a paste-able report,
        # so the key lives behind the explicit 'onion-client-key' command instead.
        if [ "$(env_get DASHBOARD_ONION_ENABLED)" == "true" ]; then
            local onion_line
            if onion_line=$(dashboard_onion_status); then
                dr_ok "Dashboard onion: $onion_line"
            else
                dr_warn_surface "DASHBOARD_ONION_ADDRESS is not provisioned yet — re-run './pithead setup' or './pithead apply'." "DASHBOARD_ONION_ADDRESS is not provisioned yet — run setup again from this machine's setup page."
            fi
        fi
    fi

    check_appliance_cert

    # --- Containers (best-effort) ---
    echo ""
    echo "Containers:"
    if ! command -v docker >/dev/null 2>&1; then
        dr_info "Skipped — docker is not installed."
    elif ! docker info >/dev/null 2>&1; then
        dr_info "Skipped — Docker daemon is not reachable."
    else
        local ps_out
        ps_out=$(docker compose ps 2>/dev/null || true)
        if [ -n "$ps_out" ]; then
            printf '%s\n' "$ps_out" | while IFS= read -r line; do
                printf '    %s\n' "$line"
            done
            dr_ok "Read container status from 'docker compose ps' (review the table above)."
        else
            dr_warn_surface "No containers reported by 'docker compose ps' — the stack may be stopped (run './pithead up') or run from a different directory." "No containers are running — the mining stack is stopped on this machine."
        fi
        check_revenue_containers
        check_dashboard_answers
        check_monerod_synchronized
    fi

    check_data_wipe_note

    # --- Summary ---
    echo ""
    log "Diagnostics summary: ${DR_OK} OK, ${DR_WARN} warning(s), ${DR_FAIL} failure(s)."
    if [ "$DR_FAIL" -gt 0 ]; then
        warn "One or more critical checks FAILED — address the ✗ lines above."
    elif [ "$DR_WARN" -gt 0 ]; then
        log "No critical failures. Review the ⚠ warnings above."
    else
        log "All checks passed."
    fi
    # Propagate a non-zero exit when any critical check FAILED, so `doctor` is usable as a health
    # gate in cron/CI/monitoring (mirrors `status`). Warnings alone still exit 0 (#127).
    [ "$DR_FAIL" -gt 0 ] && return 1
    return 0
}

# `doctor --json` (#77 phase 1): the machine-readable doctor — same checks, same exit semantics.
# JSON on stdout, the human report on stderr, so `pithead doctor --json | jq` works while a
# watching operator still sees progress. This is the appliance commit gate's input (phase 2) and
# rides inside every support bundle; the appliance's engine-aware check variants land behind the
# same shape (plan § phase 2).
doctor_json() {
    local rc=0
    DR_JSON_FILE=$(mktemp)
    doctor >&2 || rc=$?
    jq -Rs --arg version "$PITHEAD_VERSION" --argjson rc "$rc" \
        'split("\n") | map(select(length > 0) | split("\t") | {status: .[0], message: .[1]})
         | {version: $version, exit: $rc,
            summary: {ok: map(select(.status == "ok")) | length,
                      warn: map(select(.status == "warn")) | length,
                      fail: map(select(.status == "fail")) | length},
            checks: .}' "$DR_JSON_FILE"
    rm -f "$DR_JSON_FILE"
    unset DR_JSON_FILE
    return "$rc"
}
