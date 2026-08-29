# The stack's own HugePages budget: 3072 pages of 2 MiB (~6 GiB) for RandomX — p2pool's dataset
# plus monerod's verify cache. ONE definition: the sysctl write, the GRUB params and the local
# miner's declared headroom (hugepages_reserve_extra_mb in RigForge's config) all derive from it,
# so the reservation and the declaration cannot drift apart.
readonly PITHEAD_HUGEPAGES=3072

# The budget this MACHINE actually gets (#977). On the appliance, the boot-time sizing
# (os/overlay/pithead-hugepages) may have chosen a smaller pool for the fitted RAM and recorded
# the chosen page count as the marker's "pages=N" line — that record is the single authority
# every later writer honours: optimize_kernel caps its grow at it, and render_local_miner_config
# declares it (never the baked constant) as RigForge's headroom. Without the record both writers
# re-inflated the pool the sizing had just shrunk, while the marker and doctor kept saying
# "reduced". No marker — every DIY host, every healthy appliance — means the full budget.
hugepages_decision_pages() {
    local pages
    # || true: no marker means sed fails under pipefail, and that is the normal case everywhere
    # but a degraded appliance — it must read as "full budget", never abort under set -e.
    pages=$(sed -n 's/^pages=\([0-9][0-9]*\)$/\1/p' \
        "${PITHEAD_HUGEPAGES_MARKER:-/run/pithead-hugepages-degraded}" 2>/dev/null | head -n 1) || true
    if [ -n "$pages" ] && [ "$pages" -lt "$PITHEAD_HUGEPAGES" ]; then
        echo "$pages"
    else
        echo "$PITHEAD_HUGEPAGES"
    fi
}

# Kernel boot params pithead appends to GRUB_CMDLINE_LINUX_DEFAULT for RandomX: reserve 6 GiB of
# 2 MiB HugePages and disable Transparent HugePages. NOTE the THP param is SINGULAR
# (transparent_hugepage) — the plural form is an unrecognized param the kernel silently ignores,
# so THP would never actually be disabled (#176). Kept as a function so it has one definition and
# can be unit-tested for valid kernel param names.
randomx_boot_params() {
    echo "hugepagesz=2M hugepages=$PITHEAD_HUGEPAGES transparent_hugepage=never"
}

# Re-generate the bootloader config after a /etc/default/grub edit and flag that a reboot is needed.
# Warns (rather than failing) when update-grub isn't on PATH so the user can run it by hand.
apply_grub_update() {
    if command -v update-grub >/dev/null; then
        sudo update-grub
        REBOOT_REQUIRED=true
    else
        warn "'update-grub' not found. Please manually update your bootloader."
    fi
}

# Self-heal an earlier release's typo: the THP-disable kernel param is singular
# (transparent_hugepage); the plural form is silently ignored, so THP was never disabled (#176).
# Rewrites the plural token to the singular form in grub file $1. Returns 0 if it changed something,
# 1 if there was nothing to heal — so callers only re-run update-grub when needed. Idempotent: a
# no-op once the file already uses the singular form.
heal_grub_thp_typo() {
    local grub="$1"
    grep -q "transparent_hugepages=" "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed 's/transparent_hugepages=/transparent_hugepage=/g' "$grub"
}

# Append the RandomX boot params to the active GRUB_CMDLINE_LINUX_DEFAULT="..." line in grub file $1,
# preserving any leading indentation. Returns 0 on success, 1 when there's no active double-quoted
# line to edit — commented out, single-quoted, or absent — so the caller can warn instead of
# silently running update-grub and claiming a reboot is needed. The leading-^ anchor also ensures a
# commented-out example line is never edited.
append_grub_boot_params() {
    local grub="$1"
    grep -q '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="' "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed "s/^\([[:space:]]*\)GRUB_CMDLINE_LINUX_DEFAULT=\"/\1GRUB_CMDLINE_LINUX_DEFAULT=\"$(randomx_boot_params) /" "$grub"
}

optimize_kernel() {
    if [ "$SKIP_OPTIMIZE" == "1" ]; then
        log "Skipping kernel/HugePages optimization (--skip-optimize)."
        return 0
    fi
    log "Applying RandomX optimizations (HugePages)..."
    if [ "$OS_TYPE" == "Linux" ]; then
        # Grow-only, never shrink: with a co-located RigForge miner the HugePages pool is shared,
        # and whoever writes an absolute value last steals the other side's pages — the kernel
        # shrinks the pool to the in-use floor and leaves zero headroom for a restart on either
        # side. RigForge's own write is grow-only for the same reason, so write ordering between
        # the two products stays safe regardless of who runs first. The grow TARGET is the
        # sizing decision, not the raw constant (#977): on a degraded appliance the wizard-accept
        # path runs setup as root, and growing to the full budget here re-inflated the pool the
        # boot-time sizing had just shrunk. No marker (DIY, healthy appliance) — full budget,
        # exactly the old behavior.
        local current_hugepages hp_target
        hp_target=$(hugepages_decision_pages)
        current_hugepages=$(cat "${PITHEAD_NR_HUGEPAGES_FILE:-/proc/sys/vm/nr_hugepages}" 2>/dev/null || echo 0)
        if [ "${current_hugepages:-0}" -ge "$hp_target" ] 2>/dev/null; then
            log "HugePages pool already holds $current_hugepages pages (>= $hp_target) — leaving it as is."
        else
            sudo sysctl -w vm.nr_hugepages="$hp_target"
        fi

        if [ -f "/etc/default/grub" ]; then
            # Heal an earlier release's invalid plural THP param if present (#176). Runs regardless of
            # the reservation guard below, which would otherwise see hugepages= and skip it forever.
            if heal_grub_thp_typo /etc/default/grub; then
                log "Corrected invalid THP kernel parameter in GRUB (transparent_hugepages -> transparent_hugepage)."
                apply_grub_update
            fi

            if ! grep -q "hugepages=" /etc/default/grub; then
                warn "Persistent HugePages requires editing /etc/default/grub and a reboot."
                if [ -t 0 ]; then
                    read -r -p "Modify GRUB for persistent HugePages now? (y/N): " GRUB_OK || true
                else
                    # Headless: never touch GRUB unattended, but say so — the old EOF-swallow
                    # skipped this silently and the operator never learned the reservation is
                    # boot-only.
                    GRUB_OK=""
                    warn "No terminal attached — skipping the persistent-HugePages GRUB change. Run '$0 setup' from a terminal (or edit /etc/default/grub) to make it permanent."
                fi
                if [[ ! "$GRUB_OK" =~ ^[Yy] ]]; then
                    log "Skipped GRUB edit. HugePages set for this boot only (vm.nr_hugepages=$PITHEAD_HUGEPAGES)."
                    return 0
                fi
                log "Updating GRUB configuration for persistent HugePages..."
                if append_grub_boot_params /etc/default/grub; then
                    apply_grub_update
                else
                    warn "No standard GRUB_CMDLINE_LINUX_DEFAULT=\"...\" line in /etc/default/grub — left it unchanged."
                    warn "Add these kernel params by hand, then run 'sudo update-grub' and reboot:"
                    warn "  $(randomx_boot_params)"
                fi
            else
                log "HugePages already configured in GRUB."
            fi
        fi
    else
        log "Skipping Host HugePages configuration (Not supported on $OS_TYPE)."
    fi
}

prompt_start_stack() {
    read -r -p "Start Pithead now? (Y/n): " START_NOW || true
    if [[ ! "$START_NOW" =~ ^[Nn] ]]; then
        stack_up
    else
        echo "You can start the stack later with: $0 up"
    fi
}

# Per-component free-disk requirement in GiB — the single source of truth for the stack's disk
# budget, shared by setup's preflight_resources and doctor's Disk check. Monero (the blockchain) is
# pruning-aware: ~120 GiB pruned, ~320 GiB full. Tari's chain is the other heavyweight — ~200 GiB and
# growing fast. Summed, this is ~330 GiB pruned / ~530 GiB full, the documented minimum
# (docs/hardware.md). These carry generous growth headroom over usage measured on live nodes
# (August 2026: Monero pruned ~100 GiB / full ~267 GiB, Tari ~149 GiB) because both chains grow
# ~100+ GiB/year combined — for a set-and-forget host the docs recommend a 2–4 TB drive.
# Args: <component> [<prune>] where prune (1 = on, 0 = off) only matters for "monero". Prints GiB.
disk_component_gib() {
    case "$1" in
    monero) if [ "${2:-1}" -eq 1 ] 2>/dev/null; then echo 120; else echo 320; fi ;;
    tari) echo 200 ;;
    p2pool) echo 5 ;;
    dashboard) echo 2 ;;
    tor) echo 1 ;;
    *) echo 0 ;;
    esac
}

# Resolve the filesystem mount point a (possibly not-yet-created) path lives on. Walks up to the
# nearest EXISTING ancestor — df needs a real path — then prints `df -P`'s mount point (field 6).
# Prints nothing (and returns non-zero) if no ancestor resolves, so callers can skip cleanly.
disk_fs_mount() {
    local p="$1"
    while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != "/" ]; do
        p=$(dirname "$p")
    done
    [ -n "$p" ] && [ -e "$p" ] || return 1
    df -P "$p" 2>/dev/null | awk 'NR==2{print $6}'
}

# Shared per-filesystem disk check used by BOTH preflight_resources and doctor. Treats the stack as
# ONE unit: groups the five data dirs by the filesystem they live on and checks each filesystem ONCE
# against the COMBINED requirement of the components that share it — so dirs on the same volume yield
# a single line (not one misleading "N GB free" line per dir). Read-only / never exits; a dir whose
# ancestor can't be resolved is skipped.
#
# Args: <mode> <prune> <monero_dir> <tari_dir> <p2pool_dir> <dashboard_dir> <tor_dir>
#   mode  = "doctor" (emit dr_ok/dr_warn) or "preflight" (emit warn only when under requirement)
#   prune = 1 (pruning on) / 0 (off); only affects the Monero requirement.
check_disk_grouped() {
    local mode="$1" prune="$2"
    shift 2
    local components=(monero tari p2pool dashboard tor)
    local dirs=("$@")

    # Group by mount point: accumulate required GiB and the component list per mount, and remember
    # one representative path per mount so we can read its free space once. Parallel arrays keyed by
    # a positional index (portable to Bash 3.2 on macOS — no associative arrays).
    local mounts=() req_gib=() comp_list=()
    local i mount comp gib idx
    for i in "${!components[@]}"; do
        comp="${components[$i]}"
        local dir="${dirs[$i]:-}"
        [ -n "$dir" ] || continue
        mount=$(disk_fs_mount "$dir") || continue
        [ -n "$mount" ] || continue
        gib=$(disk_component_gib "$comp" "$prune")

        # Find an existing group for this mount.
        idx=-1
        local j
        for j in "${!mounts[@]}"; do
            if [ "${mounts[$j]}" = "$mount" ]; then
                idx="$j"
                break
            fi
        done
        if [ "$idx" -lt 0 ]; then
            mounts+=("$mount")
            req_gib+=("$gib")
            comp_list+=("$comp")
        else
            req_gib[idx]=$((req_gib[idx] + gib))
            comp_list[idx]="${comp_list[idx]}, $comp"
        fi
    done

    if [ "${#mounts[@]}" -eq 0 ]; then
        [ "$mode" = "doctor" ] && dr_info "No data dirs resolved to a filesystem — skipping disk check."
        return 0
    fi

    # One result line per DISTINCT filesystem: read free space once, compare to the summed need.
    local need_kb avail_kb avail_h comps
    for i in "${!mounts[@]}"; do
        mount="${mounts[$i]}"
        comps="${comp_list[$i]}"
        need_kb=$((req_gib[i] * 1048576)) # GiB -> KiB (df -P is 1K-blocks)
        # df the resolved MOUNT POINT (always exists), not the data dir — on first run the dir isn't
        # created yet and `df` on a missing path fails the pipe, tripping `set -Eeuo pipefail` (#179).
        avail_kb=$(df -P "$mount" 2>/dev/null | awk 'NR==2{print $4}')
        avail_h=$(df -Ph "$mount" 2>/dev/null | awk 'NR==2{print $4}')
        if [ "$mode" = "doctor" ]; then
            if [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$need_kb" ] 2>/dev/null; then
                dr_ok "Data on $mount ($comps): ${avail_h:-?} free — needs ~${req_gib[i]} GB."
            else
                dr_warn "Data on $mount ($comps): ${avail_h:-?} free — below the ~${req_gib[i]} GB the stack needs there."
            fi
        else
            if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ] 2>/dev/null; then
                warn "Low disk on $mount (hosts $comps): ${avail_h:-?} free, below the ~${req_gib[i]} GB the stack needs there — free space or move a data_dir to a larger volume."
            fi
        fi
    done
    return 0
}

# Pre-flight resource check (#87). Best-effort, WARN-only: catch the most demoralizing first-run
# failure — an undersized host that fills its disk mid-sync — before we commit to a sync. Never
# blocks or exits: a missing path or unreadable file just skips that check. Call after
# parse_and_validate_config has resolved the data dirs, before starting the stack.
preflight_resources() {
    # Pruning is on unless config explicitly sets monero.prune:false (same derivation as render_env).
    local prune
    prune=$(monero_prune_flag)

    # --- Disk: free space per underlying filesystem ---
    # Treat the stack as one unit: group all five data dirs by the filesystem they live on and warn
    # once per volume that can't hold the combined requirement of the components sharing it (so dirs
    # on the same disk produce a single line, not one per dir). check_disk_grouped is WARN-only here.
    # A remote node (#103) keeps its chain elsewhere: blank its dir so the ~120 GiB (Monero) /
    # ~200 GiB (Tari) budget isn't demanded of THIS host — small disks are exactly why an operator
    # goes remote. check_disk_grouped skips empty dirs.
    local pre_mono_dir="${MONERO_DIR:-}" pre_tari_dir="${TARI_DIR:-}"
    [ "$MONERO_MODE" == "remote" ] && pre_mono_dir=""
    [ "$TARI_MODE" == "remote" ] && pre_tari_dir=""
    check_disk_grouped preflight "$prune" \
        "$pre_mono_dir" "$pre_tari_dir" "${P2POOL_DIR:-}" "${DASHBOARD_DIR:-}" "${TOR_DATA_DIR:-}"

    # --- RAM: total memory (Linux only — /proc/meminfo isn't available on macOS dev hosts) ---
    if [ "$OS_TYPE" == "Linux" ]; then
        local mem_total_kb
        mem_total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
        # 16 GiB in KiB.
        if [ -n "$mem_total_kb" ] && [ "$mem_total_kb" -lt 16777216 ] 2>/dev/null; then
            local mem_total_gb
            mem_total_gb=$((mem_total_kb / 1048576))
            warn "Low total RAM: ${mem_total_gb} GB detected, below the recommended ~16 GB. The stack (Tari especially) may be memory-starved during sync."
        fi
    fi

    return 0
}

# --- Top-level Commands ---

setup() {
    if is_deployed; then
        warn "A previous deployment was detected."
        # An interactive ask with no terminal is an EOF, and `read`'s `|| true` used to swallow
        # that into an empty answer — read as decline, exit 0: a headless caller believed setup
        # succeeded while nothing ran (#924's silent false success). Headless now REFUSES loudly
        # instead of proceeding: an unattended re-provision (Tor container recreate, full
        # re-render, a possible GRUB edit) must never ride on the mere absence of a terminal —
        # `pithead setup` has long been a safe probe on a deployed box for cron/automation, and
        # the appliance's own headless paths never reach this branch (a failed provisioning
        # attempt is not deployed). A real terminal keeps the prompt exactly as before.
        if [ -t 0 ]; then
            local RERUN
            read -r -p "Re-run setup (re-provisions Tor and may modify GRUB)? (y/N): " RERUN || true
            if [[ ! "$RERUN" =~ ^[Yy] ]]; then
                log "Setup skipped. Edit config.json and run '$0 apply' to propagate config changes,"
                log "or '$0 up' to start the stack."
                exit 0
            fi
        else
            error "Already provisioned, and re-running setup re-provisions Tor and may modify GRUB — run '$0 setup' from a terminal to confirm that. For configuration changes use '$0 apply'; to start the stack use '$0 up'."
        fi
    fi

    # After the re-run prompt above, so the hold never spans a human wait. The firstboot
    # wizard runs `(setup)` in a subshell (#1059), so this IS the wizard's hold and it is not one
    # line wider than the provisioning itself — the loop's wait for a submitted form is outside it.
    mutation_lock_acquire setup

    check_prerequisites
    ensure_config_exists
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one
    parse_and_validate_config
    preflight_resources          # WARN-only: low disk/RAM heads-up before committing to a sync (#87)
    check_stratum_exposure setup # WARN-only: public-IP host => unauthenticated stratum :3333 exposed (#113)
    load_preserved_state
    resolve_dashboard_host "interactive"
    prepare_directories
    render_env    # bootstrap .env so Tor (and compose var substitution) have what they need
    provision_tor # populates the real onion addresses
    DEPLOYMENT_COMPLETED=true
    render_env # finalize with real onions + completion flag
    inject_service_configs
    optimize_kernel
    generate_caddyfile
    provision_control_runner  # #33: install/remove the dashboard-control systemd trigger
    render_local_miner_config # #796: the appliance's built-in RigForge worker reads a derived config
    update_current_symlink    # #455: versioned deploy dir -> maintain the `current ->` pointer

    log "Deployment preparation complete!"
    # Provisioning is done. Everything below is either a message or an interactive "start now?",
    # so the hold ends here; the stack_up it may call takes its own.
    mutation_lock_release
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n${C_YELLOW}[!] ATTENTION: System optimization requires a reboot.${C_RESET}"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 up'"
    else
        prompt_start_stack
        # The miner leg comes AFTER the stack: it points at the stack's own stratum, and
        # RigForge starts the service it installs. Appliance-only inside; best-effort — a
        # miner that cannot start must not fail provisioning of the stack that just did.
        provision_local_miner || true
    fi
}

# Describe a changed env key for the apply preview. Prints "FLAG\tmessage" where FLAG is
# DEST (disruptive — apply should confirm) or INFO. Always returns 0 (safe in $()).
describe_change() {
    local key="$1" old="$2" new="$3" flag="INFO" msg
    case "$key" in
    MONERO_PRUNE)
        # #719: ENABLE (off → on) is confirm-gated — it reclaims disk by pruning blocks, an
        # operator-intent op with an expensive-but-recoverable cost. DISABLE (on → off) stays a
        # host-only DEST: pruned data can't be restored, so it needs a full re-sync from a shell.
        case "$new" in
        true | 1)
            flag=CONFIRM
            msg="Monero pruning ENABLED ($old → $new) — prunes existing blocks to reclaim disk; monerod is recreated. Restoring the full chain later needs a wipe + re-sync."
            ;;
        *)
            flag=DEST
            msg="Monero pruning DISABLED ($old → $new) — pruned data can't be restored, so the full chain must RE-SYNC from scratch. Apply this from the host."
            ;;
        esac
        ;;
    COMPOSE_PROFILES)
        # #552: COMPOSE_PROFILES also carries payout_confirm/tari_payout_confirm (#381/#462) and
        # local_tari (#103), so an empty-vs-non-empty check misreads those toggles as a node switch.
        # Decide by presence of the local_node / local_tari tokens instead — only a real flip of
        # either token is a node switch (DEST). Monero is checked first; a same-apply flip of BOTH
        # nodes is rare and either message alone is enough to make the change obvious.
        local old_local=false new_local=false old_tari_local=false new_tari_local=false
        case ",$old," in *,local_node,*) old_local=true ;; esac
        case ",$new," in *,local_node,*) new_local=true ;; esac
        case ",$old," in *,local_tari,*) old_tari_local=true ;; esac
        case ",$new," in *,local_tari,*) new_tari_local=true ;; esac
        if [ "$old_local" = false ] && [ "$new_local" = true ]; then
            flag=DEST
            msg="Switching to a LOCAL Monero node — monerod will start and SYNC the blockchain (large download / disk use)."
        elif [ "$old_local" = true ] && [ "$new_local" = false ]; then
            flag=DEST
            msg="Switching to a REMOTE Monero node — the local monerod container will be STOPPED and removed (its on-disk data is kept)."
        elif [ "$old_tari_local" = false ] && [ "$new_tari_local" = true ]; then
            flag=DEST
            msg="Switching to a LOCAL Tari node — the tari container will start and SYNC the chain (large download / disk use)."
        elif [ "$old_tari_local" = true ] && [ "$new_tari_local" = false ]; then
            flag=DEST
            msg="Switching to a REMOTE Tari node — the local tari container will be STOPPED and removed (its on-disk data is kept)."
        else
            msg="Payout confirmation profile changed ($old → $new)."
        fi
        ;;
    MONERO_WALLET_ADDRESS)
        flag=DEST
        msg="Monero payout address is changing — future mining rewards go to the new address."
        ;;
    TARI_WALLET_ADDRESS)
        flag=DEST
        msg="Tari payout address is changing — future merge-mining rewards go to the new address."
        ;;
    MONERO_RPC_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Monero RPC will be EXPOSED on your LAN ($old → $new) — make sure this is intended."
        else
            msg="Monero RPC bind address: $old → $new."
        fi
        ;;
    MONERO_ZMQ_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Monero ZMQ will be EXPOSED on your LAN ($old → $new) — it has no auth, trusted networks only."
        else
            msg="Monero ZMQ bind address: $old → $new."
        fi
        ;;
    TARI_GRPC_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Tari gRPC will be EXPOSED on your LAN ($old → $new) — it is plaintext and unauthenticated, trusted networks only."
        else
            msg="Tari gRPC bind address: $old → $new."
        fi
        ;;
    STRATUM_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="The stratum port will be published on ALL interfaces ($old → $new) — keep it firewalled to your LAN."
        else
            msg="Stratum bind address: $old → $new (workers must reach this address)."
        fi
        ;;
    STRATUM_PORT)
        if [ -z "$old" ]; then
            # First render of the key (upgrade from a pre-#172 .env) — the port isn't changing.
            msg="Stratum port recorded (:$new) — no rig change needed."
        else
            # #719: confirm-gated — repointing every rig is disruptive but operator-intent, not a
            # breach; the typed confirmation makes the operator acknowledge the fleet-wide repoint.
            flag=CONFIRM
            msg="Stratum port: $old → $new — EVERY RIG must repoint at the new port (RigForge: pool.port) or it can't connect; the xmrig-proxy container is recreated."
        fi
        ;;
    PROXY_STRATUM_TLS)
        if [ "$new" = "true" ]; then
            msg="Stratum TLS ENABLED — the proxy serves TLS and cleartext on the same port; rigs opt in by pinning the cert fingerprint (shown after apply). xmrig-proxy is recreated."
        else
            msg="Stratum TLS DISABLED — rigs with pools[].tls:true will fail to connect until switched back to cleartext. xmrig-proxy is recreated."
        fi
        ;;
    PROXY_TLS_DIR)
        msg="Stratum TLS keypair directory: $old → $new — the cert (and its pinned fingerprint) does NOT move with it; rigs re-pin if a new cert is generated."
        ;;
    PROXY_STRATUM_PASSWORD)
        # Secret — never echo the value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Stratum access-password DISABLED — any rig that can reach :3333 may mine again."
        elif [ -z "$old" ]; then
            flag=DEST
            # The DIY hint points at .env / 'status' to recover an auto-generated password; the
            # appliance has neither a shell nor a dashboard surface that reveals a secret value
            # (#33's own trust boundary — masked config never round-trips a secret to the
            # container), so there is no remedy to name here. Drop the instruction rather than
            # invent one (#1139).
            if is_appliance; then
                msg="Stratum access-password ENABLED — rigs must now send the matching 'pass' or they're rejected; the xmrig-proxy container is recreated."
            else
                msg="Stratum access-password ENABLED — rigs must now send the matching 'pass' (find it in .env / './pithead status') or they're rejected; the xmrig-proxy container is recreated."
            fi
        else
            flag=DEST
            msg="Stratum access-password CHANGED — update every rig's 'pass' to match or they're rejected; the xmrig-proxy container is recreated."
        fi
        ;;
    PROXY_DONATE_LEVEL)
        msg="xmrig-proxy dev-fee donation level: ${old:-0}% → ${new}% — the xmrig-proxy container is recreated (brief restart)."
        ;;
    DASHBOARD_DATA_DIR)
        # #719: confirm-gated — a data-dir move is operator-intent (an expensive re-home / re-sync),
        # not a security boundary. Only the four service data dirs below are in scope.
        flag=CONFIRM
        msg="$key: $old → $new — data at the old DEFAULT location (./data/dashboard) is moved there automatically; any other old path is left in place."
        ;;
    MONERO_DATA_DIR | TARI_DATA_DIR | P2POOL_DATA_DIR)
        # #719: confirm-gated data-dir moves — the service re-syncs from the new (empty) dir.
        flag=CONFIRM
        msg="$key: $old → $new — the service will use the new (empty) directory and RE-SYNC from scratch; old data is left in place."
        ;;
    *_DATA_DIR)
        # Every OTHER data dir (e.g. TOR_DATA_DIR) stays host-only — not in the #719 in-scope set.
        flag=DEST
        msg="$key: $old → $new — the service will use the new (empty) directory and re-sync; old data is left in place."
        ;;
    P2POOL_FLAGS | P2POOL_PORT)
        msg="P2Pool sidechain changing ($key: '$old' → '$new') — p2pool re-syncs the new sidechain and your PPLNS window resets."
        ;;
    MONERO_NODE_HOST | MONERO_RPC_PORT | MONERO_ZMQ_PORT)
        msg="Monero node endpoint ($key): $old → $new."
        ;;
    MONERO_NODE_USERNAME | MONERO_NODE_PASSWORD)
        msg="Monero node RPC credential updated ($key)."
        ;;
    XVB_ENABLED | XVB_POOL_URL | XVB_DONOR_ID | XVB_DONATION_LEVEL)
        msg="XMRvsBeast setting ($key): $old → $new."
        ;;
    TARI_REQUIRED)
        if [ "$new" == "true" ]; then
            msg="Tari → required — a Tari outage rejects workers, the miner waits for Tari's sync, and a Tari-only sync takes over the dashboard."
        else
            msg="Tari → non-blocking — keep mining Monero through a Tari outage, start as soon as Monero is synced, and keep the operational dashboard while Tari syncs."
        fi
        ;;
    DASHBOARD_FAIL_CLOSED)
        if [ "$new" == "true" ]; then
            msg="Fail-closed ENABLED — an unrecoverable dashboard health failure (DB recovery itself failing, or the dashboard container crash-looping) now HOLDS p2pool and xmrig-proxy until it clears, instead of only alerting."
        else
            msg="Fail-closed DISABLED — an unrecoverable dashboard health failure now only alerts (Telegram/Healthchecks + badge); mining is never held for it."
        fi
        ;;
    DASHBOARD_CHECK_UPDATES)
        if [ "$new" == "true" ]; then
            msg="Dashboard update check ENABLED — the dashboard will check GitHub (over Tor) for a newer release and show a link badge; the dashboard container is recreated."
        else
            msg="Dashboard update check DISABLED — the dashboard no longer contacts GitHub; the dashboard container is recreated."
        fi
        ;;
    TARI_MEM_LIMIT)
        msg="Tari memory cap: $old → $new — the tari container is recreated (brief restart; on-disk chain data is preserved)."
        ;;
    MONERO_MEM_LIMIT)
        msg="Monero memory cap: $old → $new — the monerod container is recreated (brief restart; the blockchain on disk is preserved)."
        ;;
    DASHBOARD_SECURE)
        msg="Dashboard scheme → $([ "$new" == "true" ] && echo HTTPS || echo HTTP) (secure=$new)."
        ;;
    DASHBOARD_AUTH_HASH_B64)
        # Secret — never echo the hash into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Dashboard login DISABLED — the dashboard is reachable without a password again."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Dashboard login ENABLED — Caddy now requires the configured username/password; the caddy container is recreated."
        else
            flag=DEST
            msg="Dashboard login password CHANGED — use the new credentials; the caddy container is recreated."
        fi
        ;;
    DASHBOARD_AUTH_USER)
        msg="Dashboard login username: $old → $new."
        ;;
    DASHBOARD_AUTH_PW_FP)
        # Internal fingerprint — always co-changes with DASHBOARD_AUTH_HASH_B64, which already
        # carries the user-facing message. Emit no message so the preview shows one line, not two.
        msg=""
        ;;
    DASHBOARD_CONTROL_ENABLED)
        if [ "$new" == "true" ]; then
            flag=DEST
            msg="Dashboard configuration editing ENABLED — the dashboard can stage config changes that a host-side runner validates and applies; the dashboard container is recreated."
        else
            msg="Dashboard configuration editing disabled — the control runner units are removed; the dashboard container is recreated."
        fi
        ;;
    CLEARNET_STATE_DIR | CONTROL_DIR | CADDY_LOG_DIR)
        # Fixed paths under ./data — internal, change only when the checkout moves (#695).
        msg=""
        ;;
    DASHBOARD_ONION_ENABLED)
        flag=DEST
        if [ "$new" == "true" ]; then
            msg="Dashboard Tor onion ENABLED — the dashboard is published as a hidden service reachable over Tor; tor and caddy are recreated."
        else
            msg="Dashboard Tor onion DISABLED — the onion is withdrawn; tor and caddy are recreated."
        fi
        ;;
    DASHBOARD_ONION_CLIENT_AUTH)
        msg="Dashboard onion client-auth → $([ "$new" == "true" ] && echo ON || echo OFF)$([ "$new" == "true" ] && echo " — the onion won't respond without your client key" || echo " — the onion is password-only")."
        ;;
    DASHBOARD_ONION_ADDRESS | DASHBOARD_ONION_CLIENT_PUBKEY)
        # Provisioned values that co-change with the toggle above; keep the preview to one line.
        msg=""
        ;;
    DASHBOARD_ONION_CLIENT_PRIVKEY)
        # Secret client key — never echo it into the change preview / logs.
        msg=""
        ;;
    HOST_IP)
        msg="Dashboard hostname: $old → $new."
        ;;
    HOST_PORT)
        # #740: Caddy's LAN listen port. Empty means the scheme default (443/80). Stay silent when
        # both sides are empty — a fresh binary just adds the key with no value on the first apply
        # (comm flags the added line); that is not a real change worth previewing.
        if [ -z "$old" ] && [ -z "$new" ]; then
            msg=""
        else
            msg="Dashboard Caddy port: ${old:-default (443/80)} → ${new:-default (443/80)} — the caddy container is recreated."
        fi
        ;;
    MONERO_PREP_THREADS)
        msg="Monero block-prep threads: $old → $new."
        ;;
    MONERO_OUT_PEERS)
        # Confirm-gated (2026-08 security review): bounded 8-1024 and instantly reversible, but
        # the biggest steady-state knob on the shared Tor daemon's CPU — one typed confirm, not
        # free-commit.
        flag=CONFIRM
        msg="Monero outbound peer target: $old → $new — monerod restarts; over Tor each outbound peer is roughly one circuit."
        ;;
    HEALTHCHECKS_PING_URL)
        # The ping URL is both the on/off switch and a capability secret — report the change
        # (enable/disable/update) WITHOUT printing the value.
        if [ -z "$new" ]; then
            msg="Healthchecks.io dead-man's switch DISABLED — ping URL cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="Healthchecks.io dead-man's switch ENABLED — ping URL set (pings over Tor); the dashboard container is recreated."
        else
            msg="Healthchecks.io ping URL updated — the dashboard container is recreated."
        fi
        ;;
    TOR_AUTO_HEAL)
        if [ "$new" == "true" ]; then
            msg="Tor guard self-heal ENABLED — when clearnet egress through Tor stays broken for 15 min (a failing guard), the dashboard restarts the tor container to pick fresh guards (max 3 restarts per outage, 30-min cooldown; each restart drops ALL Tor circuits, mining onions included, which then rebuild); the dashboard container is recreated."
        # The DIY fix names 'doctor' + a scoped tor restart, both CLI-only; the appliance has no
        # shell to run either from, and there is no dashboard control that restarts tor alone
        # (#1139) — so this side just states the fact instead of a remedy it cannot offer.
        elif is_appliance; then
            msg="Tor guard self-heal DISABLED — a stuck guard is back to WARN-only, with no dashboard control to restart Tor manually; the dashboard container is recreated."
        else
            msg="Tor guard self-heal DISABLED — a stuck guard is back to WARN-only ('./pithead doctor', fix with './pithead restart tor'); the dashboard container is recreated."
        fi
        ;;
    TELEGRAM_ENABLED)
        msg="Telegram operator bot → $([ "$new" == "true" ] && echo on || echo off) — the dashboard container is recreated."
        ;;
    TELEGRAM_BOT_TOKEN)
        # Secret — never echo the token value into the change preview / logs.
        msg="Telegram bot token updated — the dashboard container is recreated."
        ;;
    TELEGRAM_CHAT_ID)
        msg="Telegram chat id: $old → $new."
        ;;
    TELEGRAM_COMMANDS_ENABLED)
        msg="Telegram command interface → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now answers" || echo "no longer answers") /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."
        ;;
    TELEGRAM_CONTROL_ENABLED)
        msg="Telegram control commands → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now accepts" || echo "no longer accepts") /restart and /apply from allow-listed operator ids, each with an in-chat confirmation; the dashboard container is recreated."
        ;;
    TELEGRAM_CONTROL_ALLOWED_IDS)
        # Telegram user ids are not secret, but they are the control-command allow-list — report the change.
        msg="Telegram control allow-list: [$old] → [$new] — only these operator user ids may run /restart or /apply."
        ;;
    TELEGRAM_CONTROL_CONFIRM_S)
        msg="Telegram control confirmation timeout: ${old}s → ${new}s — an unconfirmed control command is denied after this."
        ;;
    TELEGRAM_EVENT_*)
        msg="Telegram alert toggle ($key): $old → $new."
        ;;
    TELEGRAM_DAILY_SUMMARY_TIME)
        msg="Telegram daily summary time: $old → $new (local time)."
        ;;
    NOTIFY_WEBHOOK_URLS)
        # Webhook URLs often carry tokens in the query string — report the change WITHOUT
        # printing the values (same rule as HEALTHCHECKS_PING_URL).
        if [ -z "$new" ]; then
            msg="Webhook alert sink(s) DISABLED — URL list cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="Webhook alert sink(s) ENABLED — every alert now also POSTs as JSON to the configured URL(s), over Tor by default; the dashboard container is recreated."
        else
            msg="Webhook alert URL(s) updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_URL)
        # The topic URL is a capability secret (whoever knows it can read/post the topic) —
        # never print it.
        if [ -z "$new" ]; then
            msg="ntfy alert sink DISABLED — topic URL cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="ntfy alert sink ENABLED — every alert now also POSTs to the configured ntfy topic, over Tor by default; the dashboard container is recreated."
        else
            msg="ntfy topic URL updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_TOKEN)
        # Secret — never echo the token value into the change preview / logs.
        msg="ntfy access token updated — the dashboard container is recreated."
        ;;
    NOTIFY_TOR)
        if [ "$new" == "true" ]; then
            msg="Webhook/ntfy alerts back on Tor — endpoints see a Tor exit, not this host's IP; the dashboard container is recreated."
        else
            msg="⚠ Webhook/ntfy alerts OFF Tor — POSTs go out directly, so clearnet endpoints see this host's IP (the LAN/self-hosted carve-out; Tor exits can't reach private addresses); the dashboard container is recreated."
        fi
        ;;
    MONERO_CLEARNET_SYNC)
        # #183/#719: ENABLING exposes the host IP during IBD (auto-reverts to Tor) — confirm-gated
        # (CONFIRM), not host-only. DISABLING returns to Tor, a plain INFO change.
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ Monero CLEARNET initial sync ENABLED — monerod P2P will run over CLEARNET (this host's IP becomes visible to the Monero P2P network) so the chain syncs fast. Transaction broadcast STAYS on Tor; wallets are never exposed. The dashboard switches monerod back to Tor automatically once the chain is synced. monerod is recreated."
        else
            msg="Monero clearnet sync DISABLED — monerod P2P returns to Tor-only. monerod is recreated."
        fi
        ;;
    TARI_CLEARNET_SYNC)
        # #183/#719: ENABLING exposes the host IP during IBD (auto-reverts to Tor) — confirm-gated.
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ Tari CLEARNET initial sync ENABLED — the Tari base node will sync over CLEARNET (TCP transport + seeds.tari.com DNS seed; this host's IP becomes visible to the Tari P2P network) so its large chain syncs fast. The dashboard switches Tari back to Tor automatically once the chain is synced. tari is recreated."
        else
            msg="Tari clearnet sync DISABLED — the Tari base node returns to Tor-only transport. tari is recreated."
        fi
        ;;
    MONERO_VIEW_KEY)
        # Secret (#381): the private view key reveals every incoming payout amount/time — never
        # echo its value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Payout confirmation view key CLEARED — the view-only wallet-rpc is removed."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Payout confirmation view key SET — a view-only monero-wallet-rpc starts and scans the local node for confirmed payouts (it can see incoming amounts, never spend)."
        else
            flag=DEST
            msg="Payout confirmation view key CHANGED — the view-only wallet-rpc is recreated and rescans."
        fi
        ;;
    WALLET_RPC_PASSWORD)
        # Secret (#381): auto-generated wallet-rpc login — never echo the value.
        msg="Payout wallet-rpc credential updated."
        ;;
    PAYOUT_CONFIRM_ENABLED)
        msg="On-chain payout confirmation → $([ "$new" == "true" ] && echo on || echo off)."
        ;;
    PAYOUT_SCAN_HEIGHT)
        msg="Payout wallet restore height: $old → $new — only affects a first-time wallet creation."
        ;;
    WALLET_RPC_USERNAME | MONERO_WALLET_RPC_URL)
        # Fixed internal values that co-change with the view key toggle; keep the preview to one line.
        msg=""
        ;;
    TARI_VIEW_KEY)
        # Secret (#462): the Tari private view key reveals every incoming payout amount/time — never
        # echo its value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Tari payout confirmation view key CLEARED — the view-only tari-wallet is removed."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Tari payout confirmation view key SET — a view-only minotari_console_wallet starts and scans the local Tari node for confirmed payouts (it can see incoming amounts, never spend)."
        else
            flag=DEST
            msg="Tari payout confirmation view key CHANGED — the view-only tari-wallet is recreated and rescans."
        fi
        ;;
    TARI_WALLET_PASSWORD)
        # Secret (#462): auto-generated wallet-DB password — never echo the value.
        msg="Tari payout wallet credential updated."
        ;;
    TARI_PAYOUT_CONFIRM_ENABLED)
        msg="Tari on-chain payout confirmation → $([ "$new" == "true" ] && echo on || echo off)."
        ;;
    TARI_WALLET_BIRTHDAY)
        msg="Tari payout wallet birthday: $old → $new (days since the Unix epoch) — only affects a first-time wallet creation."
        ;;
    TARI_SPEND_PUBLIC_KEY | TARI_WALLET_GRPC_ADDRESS | TARI_WALLET_SECRET_FILE)
        # Public/fixed internal values that co-change with the Tari view key toggle; keep to one line.
        msg=""
        ;;
    *)
        msg="$key: $old → $new."
        ;;
    esac
    printf '%s\t%s' "$flag" "$msg"
}

# Preview what `apply` would change without touching .env, generated files, or containers (#33).
# Runs apply's own render-and-diff preamble against a throwaway staging file, prints the same
# describe_change preview, and stops before the commit. --porcelain prints machine-readable
# "FLAG<TAB>KEY<TAB>MSG" lines for the control runner. Progress logs go to stderr so stdout
# carries only the preview. Reads $CONFIG_FILE, so PITHEAD_CONFIG_FILE can point one invocation
# at a staged candidate config.
apply_dry_run() {
    local porcelain="$1"
    local newenv="${ENV_FILE}.dryrun"
    PITHEAD_DRY_RUN=1 # #556: parse_and_validate_config -> persist_node_credentials checks this
    {
        # NOTE: no ensure_onion_password here — it would write an auto-generated password into
        # the candidate config. A dry run must only read; an invalid candidate fails validation.
        parse_and_validate_config
        load_preserved_state
        # P2Pool's onion is the provisioning marker (see apply) — a node's may be a placeholder.
        if onion_missing "$P2POOL_ONION" || ! is_deployed; then
            error "Stack is not fully provisioned. Run '$0 setup' first."
        fi
        resolve_dashboard_host # non-interactive
        DEPLOYMENT_COMPLETED=true
        render_env "$newenv"
    } >&2

    local changed=() key old new line flag msg
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    if [ "${#changed[@]}" -eq 0 ]; then
        [ "$porcelain" -eq 0 ] && log "No configuration changes detected."
        rm -f "$newenv"
        return 0
    fi
    for key in "${changed[@]}"; do
        old=$(env_get_file "$ENV_FILE" "$key")
        new=$(env_get_file "$newenv" "$key")
        line=$(describe_change "$key" "$old" "$new")
        flag=${line%%$'\t'*}
        msg=${line#*$'\t'}
        [ -z "$msg" ] && continue # internal-only keys stay silent, same as apply
        if [ "$porcelain" -eq 1 ]; then
            printf '%s\t%s\t%s\n' "$flag" "$key" "$msg"
        elif [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
            # #719: CONFIRM is disruptive on the host too — warn, same as DEST.
            echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
        else
            echo "  • ${msg}"
        fi
    done
    rm -f "$newenv"
}

# Regenerate every DERIVED file — .env, Caddyfile, service configs, host units — from
# config.json plus THIS program, touching no containers. The appliance's boot path runs this
# every boot (#790): derived files must never outlive the program that rendered them, and an
# A/B update swaps the whole program, so the derived layer is rebuilt by construction instead
# of inspected for staleness. Same preservation guarantees as apply: load_preserved_state
# keeps Tor onions, RPC credentials and the proxy token across the rewrite.
render_derived() {
    require_env
    ensure_onion_password
    parse_and_validate_config
    load_preserved_state
    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true
    render_env "$ENV_FILE"
    provision_node_onions
    inject_service_configs
    generate_caddyfile
    provision_onion_client_auth
    provision_control_runner
    provision_ssh_access
    provision_console_login
    render_local_miner_config
    log "Derived configuration regenerated from config.json."
}

apply() {
    # apply reaches its mutating window down two different paths (a normal change, and the retry
    # after a previous apply committed the config but did not finish recreating containers), so it
    # tracks its own hold rather than acquiring twice — the depth counter would then never reach
    # zero and the lock would outlive the verb inside a single process.
    local lock_held=0
    local assume_yes=0 dry_run=0 porcelain=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --porcelain) porcelain=1 ;;
        *) error "Unknown option for apply: $arg. Run '$0 help'." ;;
        esac
    done
    [ "$porcelain" -eq 1 ] && [ "$dry_run" -eq 0 ] && error "--porcelain only makes sense with --dry-run."

    require_env
    if [ "$dry_run" -eq 1 ]; then
        apply_dry_run "$porcelain"
        return 0
    fi
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one
    parse_and_validate_config
    load_preserved_state
    # P2Pool's onion is the provisioning marker, not Monero's: p2pool always runs, while a node's
    # onion is legitimately a placeholder in remote mode (#103).
    if onion_missing "$P2POOL_ONION" || ! is_deployed; then
        error "Stack is not fully provisioned. Run '$0 setup' first."
    fi

    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true

    # Render the new config to a staging file and diff it against the live .env, so we can
    # preview the changes and confirm anything disruptive before touching running containers.
    local newenv="${ENV_FILE}.new"
    render_env "$newenv"

    local changed=() key
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    # A marker left by a previous apply whose `docker compose up` failed AFTER the new config was
    # committed (#125): the stack then runs OLD containers against NEW config files, and because a
    # re-apply diffs the (already-committed) .env it would see no change and silently no-op. While
    # the marker is present, re-apply re-attempts the recreate even when the rendered config matches.
    local apply_marker="${ENV_FILE}.apply-incomplete" incomplete=0
    [ -f "$apply_marker" ] && incomplete=1

    local destructive=0 caddy_changed=0 caddy_before="" caddy_had=0 wallet_keys=() line flag msg old new
    if [ "${#changed[@]}" -gt 0 ]; then
        echo ""
        log "The following changes will be applied:"
        for key in "${changed[@]}"; do
            old=$(env_get_file "$ENV_FILE" "$key")
            new=$(env_get_file "$newenv" "$key")
            # Payout-wallet change (#375): remember WHICH wallet keys change for the typed
            # confirmation below — one prompt per key, so a Monero+Tari double change can't
            # ride through on a single typed prefix.
            case "$key" in MONERO_WALLET_ADDRESS | TARI_WALLET_ADDRESS) wallet_keys+=("$key") ;; esac
            line=$(describe_change "$key" "$old" "$new")
            flag=${line%%$'\t'*}
            msg=${line#*$'\t'}
            [ -z "$msg" ] && continue # internal-only keys (e.g. the auth fingerprint) stay silent
            # CONFIRM (#719) is the dashboard's confirm-gated class, but on the HOST CLI it is just
            # as disruptive as DEST — warn and fold it into the y/N confirmation, same as before.
            if [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
                echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
                destructive=1
            else
                echo "  • ${msg}"
            fi
        done
        echo ""

        if [ "${#wallet_keys[@]}" -gt 0 ] && [ "$assume_yes" -eq 0 ]; then
            # A payout-wallet change upgrades the generic y/N to a typed confirmation (#375):
            # every future reward goes to the new address, so the operator must type its first
            # 8 characters — once PER changed wallet key (a Monero and a Tari change are two
            # separate redirects; each needs its own typed confirm). This is the strongest
            # confirm, so it stands in for the y/N even when other disruptive changes ride
            # along. --yes keeps working for automation.
            local wkey wnew wallet_new8 wlabel
            for wkey in "${wallet_keys[@]}"; do
                wnew=$(env_get_file "$newenv" "$wkey")
                wallet_new8="${wnew:0:8}" # never the full address — previews and prompts stay truncated
                [ "$wkey" == "MONERO_WALLET_ADDRESS" ] && wlabel="Monero" || wlabel="Tari"
                warn "The $wlabel payout wallet address is changing — ALL future $wlabel rewards go to the new address."
                warn "Confirm by typing the first 8 characters of the new address ($wallet_new8)."
                read -r -p "Confirm: " CONFIRM || true
                if [ "$CONFIRM" != "$wallet_new8" ]; then
                    rm -f "$newenv"
                    log "Apply cancelled. No changes were made."
                    return 0
                fi
            done
        elif [ "$destructive" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
            warn "Some of the changes above (⚠) are disruptive."
            read -r -p "Proceed with applying these changes? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                rm -f "$newenv"
                log "Apply cancelled. No changes were made."
                return 0
            fi
        fi

        # After every confirm above (the typed wallet redirect, the disruptive-change y/N):
        # committing the rendered .env is where apply starts mutating.
        mutation_lock_acquire apply
        lock_held=1
        mv "$newenv" "$ENV_FILE"
        provision_node_onions # #103: a node that just went local needs its onion before it starts
        inject_service_configs
        # Whether caddy needs a restart is decided by COMPARING the rendered file, never by a list
        # of keys someone has to remember to extend (#1052). The list had drifted:
        # dashboard.expose_public_ip was missing from it, so turning OFF the opt-in that serves the
        # dashboard on a globally-routable address re-rendered the Caddyfile without its bind lines
        # and left caddy holding the wildcard listener — the operator sees the setting saved, sees
        # the file change, and the box stays exposed.
        #
        # An absent previous file is a fresh install: compose starts caddy on the new one below, so
        # there is no old configuration to displace. Emptiness is not absence — a zero-byte file
        # left by a crashed render is a box whose caddy serves nothing, and that wants the restart.
        if [ -f "Caddyfile" ]; then
            caddy_had=1
            caddy_before=$(cat "Caddyfile")
        fi
        generate_caddyfile
        if [ "$caddy_had" -eq 1 ] && [ "$caddy_before" != "$(cat "Caddyfile" 2>/dev/null)" ]; then
            caddy_changed=1
        fi
    else
        rm -f "$newenv"
        if [ "$incomplete" -eq 0 ]; then
            # #33: converge the control-runner units BEFORE returning. A box whose units point at
            # a dead install has an unchanged config by definition — the fault is in the unit
            # files, not config.json — so returning here first made `apply` the one thing that
            # could not repair it, while doctor was telling the operator to run exactly that.
            # Idempotent and sudo-free when the units already match.
            mutation_lock_acquire apply
            provision_control_runner
            log "No configuration changes detected. Nothing to apply."
            mutation_lock_release
            return 0
        fi
        warn "A previous apply updated the config but did not finish recreating containers — retrying."
    fi

    # The retry branch reaches here without a hold; the changed branch already has one.
    if [ "$lock_held" -eq 0 ]; then
        mutation_lock_acquire apply
        lock_held=1
    fi
    # Client-auth keys must be written before tor is recreated below, so an onion just turned on (or a
    # client-auth toggle) takes effect on this apply rather than the next (#343).
    provision_onion_client_auth
    provision_control_runner
    provision_ssh_access
    provision_console_login   # #33: converge the control-runner units on the (new) toggle
    render_local_miner_config # #796: the built-in miner's config is derived — keep it current

    log "Updating containers..."
    migrate_compose_project
    # (Re)assert the Tor-only egress firewall BEFORE compose recreates anything — same ordering as
    # up/upgrade (#276/#291), for the same reason: if it isn't already installed (e.g. `down` then
    # `apply`), recreating containers first opens a startup window where a clearnet app dials out and
    # the leading ESTABLISHED rule grandfathers it past the DROP. Idempotent, so the common case
    # (already installed from `up`) is a cheap re-assert; the .env it reads was committed just above.
    apply_tor_egress_firewall
    # Mark the recreate in-flight: cleared only after a SUCCESSFUL `up`, so a failure here (image
    # build error, a port already bound, a failed health/dependency gate, daemon hiccup) leaves the
    # marker for the next apply to retry instead of no-opping on the already-committed config (#125).
    : >"$apply_marker"
    # One-time move of the dashboard data out of the install dir (#455) — after the confirmed
    # commit above (never before the operator said yes) and under the marker, so a failed move is
    # retried; the recreate below then mounts the migrated directory.
    migrate_dashboard_data
    # Compose recreates only the services whose resolved config changed. --remove-orphans covers
    # services that left the compose file entirely; a profile-deactivated service is NOT an orphan
    # to compose, so compose_up_checked removes those containers itself before the up (#795).
    if ! compose_up_checked -d --remove-orphans; then
        warn "Config files were updated but containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause shown above, then re-run '$0 apply' (it will retry the recreate) — or '$0 up'."
        exit 1 # leave $apply_marker in place so the retry re-attempts the recreate
    fi
    # Caddy mounts the Caddyfile read-only, so a content change alone won't recreate it.
    if [ "$caddy_changed" -eq 1 ]; then
        docker compose restart caddy
    fi
    # If the dashboard onion was just turned on, the recreated tor container generated its hostname;
    # read it back into .env so `pithead status` can surface the address (#343) — and regenerate the
    # Caddyfile + restart caddy so the HTTPS onion vhost (#360) actually appears this run instead of
    # never (#546): a re-render off the committed .env sees no change and no-ops before ever reaching
    # generate_caddyfile above.
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] && onion_missing "${DASHBOARD_ONION:-}"; then
        if provision_dashboard_onion && render_env; then
            generate_caddyfile
            docker compose restart caddy
        fi
    fi
    rm -f "$apply_marker"
    # Converge the built-in miner on a toggle without waiting for a reboot (#796): start it when
    # local_miner just turned on, stop it when it turned off. After the recreate above so the
    # stratum the miner dials is the freshly-applied one. Best-effort, same posture as setup.
    provision_local_miner || true
    log "Configuration applied."
    announce_dashboard_url
    mutation_lock_release
}

# --- Subcommand chaining (#94) ---

# Every dispatchable subcommand, in help order. main's dispatch, the chain validator, and the
# tab-completion script (pithead-completion.bash) key off this one list; tests/stack/run.sh fails
# if any of the three drift apart.
readonly PITHEAD_COMMANDS="setup apply render up down restart upgrade logs status doctor support-bundle reset-dashboard config-reset factory-reset backup restore uninstall firstboot-wizard load-images local-miner os-update control-run-pending onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"
# The subset allowed in a chain: commands that take no positional argument and terminate on their
# own. Excluded: setup (interactive first-run), logs (follows until Ctrl+C), restore (needs an
# archive path), reset-dashboard (destructive — run it deliberately, alone), and the one-shot
# info/maintenance commands (version, help, onion-client-key, rotate-dashboard-onion).
readonly PITHEAD_CHAINABLE="apply up down restart upgrade status doctor backup"

is_pithead_command() { case " $PITHEAD_COMMANDS " in *" $1 "*) ;; *) return 1 ;; esac }

# Reject a nonsensical chain BEFORE any step runs (#94): chainable commands only, no duplicates,
# at most one of up/down/restart (two run-state commands in one chain contradict or repeat each
# other), and `down` only as the final step (anything after it would act on a stopped stack).
validate_chain() {
    local c seen="" runstate=0 last="${!#}"
    for c in "$@"; do
        case " $PITHEAD_CHAINABLE " in
        *" $c "*) ;;
        *) error "Invalid chain: '$c' can't be chained — run it on its own. Chainable commands: $PITHEAD_CHAINABLE. Nothing was run." ;;
        esac
        case " $seen " in
        *" $c "*) error "Invalid chain: '$c' appears twice. Nothing was run." ;;
        esac
        seen="$seen $c"
        case "$c" in up | down | restart) runstate=$((runstate + 1)) ;; esac
    done
    if [ "$runstate" -gt 1 ]; then
        error "Invalid chain: up/down/restart contradict each other in one invocation. Nothing was run."
    fi
    if [ "$last" != "down" ]; then
        case " $* " in
        *" down "*) error "Invalid chain: 'down' must be the last step — the commands after it would run against a stopped stack. Nothing was run." ;;
        esac
    fi
}

# Run an all-subcommand argv left-to-right, validating the whole chain first. Each step is its own
# pithead invocation, so a step's `exit` can't skip the accounting here. Fails fast: the first
# non-zero step stops the chain, the report says what ran and what didn't, and that step's exit
# code is propagated.
run_chain() {
    validate_chain "$@"
    local total=$# i=0 c rc
    for c in "$@"; do
        i=$((i + 1))
        log "── chain step $i/$total: $c"
        rc=0
        bash "${PITHEAD_SELF:-$0}" "$c" || rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "Chain stopped: step $i/$total ('$c') failed with exit code $rc."
            if [ "$i" -gt 1 ]; then warn "Already ran: ${*:1:$((i - 1))}."; fi
            if [ "$i" -lt "$total" ]; then warn "Did not run: ${*:$((i + 1))}."; fi
            exit "$rc"
        fi
    done
}

# --- Dashboard control channel (#33) ---
# The dashboard container can only ASK: it drops typed JSON intents into $CONTROL_DIR/requests
# (its single writable spool mount). This host-side runner claims each request, validates it, and
# dispatches a FIXED set of actions, each a hardcoded host command the request's `action` string
# only SELECTS between — `apply --dry-run --porcelain` (preview), `apply -y` (commit), `upgrade`
# to the latest published release (#59, target re-derived host-side), `restart`/`apply` (the
# Telegram lifecycle verbs, #338), `worker-apply`/`worker-upgrade` (a rig's own control API,
# #185/#597), and `backup` (an encrypted archive + one-time emergency kit, #908).
# Outcomes land in results/ and an audit line in audit/, both mounted read-only in the container —
# as is masked/, the pre-masked config copy the editor form prefills from (#440); the raw
# config.json is never mounted, so the container holds no secret it wasn't given.
# No string from the container is ever executed or interpolated into a command; the candidate
# config crosses the boundary only as a FILE handed to `apply` via PITHEAD_CONFIG_FILE.

# Approval gate for a commit (#33). The client-side typed-APPLY modal is NOT a security control:
# a compromised/XSS'd container writes the request spool directly and never renders that modal, so
# the only trustworthy gate is here, host-side. FAIL CLOSED, two independent checks:
#
#   1. TRUE DEFAULT-DENY: a commit that changes ANY env key NOT in
#      CONTROL_DASHBOARD_EDITABLE_KEYS — in EITHER direction (enable, change, or DISABLE) — is
#      refused. An allowlist, not a blocklist: a key added to render_env tomorrow is
#      un-committable from the dashboard until someone deliberately lists it here. Deliberately
#      decoupled from describe_change's cosmetic INFO/DEST flag: that flag labels only the
#      disruptive direction (enabling auth is DEST, disabling is INFO), so a compromised
#      container could otherwise switch security controls OFF with zero DEST rows.
#   2. Anything describe_change still flags DEST (pruning, data dirs, node-mode switch, ...) is
#      refused as disruptive, even for allowlisted keys.
#
# Both checks re-derive the changed keys from the staged config via the SAME dry-run path a preview
# runs — nothing is trusted from the container's request or its (host-written but container-visible)
# result file — so a forged "destructive:false" cannot slip a wallet swap or an auth-disable
# through. Out-of-band approval with deny-on-timeout is #338 (Telegram approve/deny) — it drops in
# here, replacing the refusal with a real second factor. Until then, these edits must be made from
# the host CLI. Echoes a reason on stdout when it refuses.

# The env keys committable from the dashboard: operational tuning only, and only keys whose value
# is derived from a validated enum, boolean, or number — never a free-form string that reaches a
# command line, URL, or credential. Everything else — wallets, auth, onion exposure, the control
# channel itself, Tor egress/clearnet toggles, binds and ports, node endpoints, the XvB pool URL
# and donor id, tokens and passwords, the #381 payout-confirmation secrets (MONERO_VIEW_KEY,
# WALLET_RPC_PASSWORD) plus PAYOUT_CONFIRM_ENABLED, and their #462 Tari siblings (TARI_VIEW_KEY,
# TARI_WALLET_PASSWORD, TARI_SPEND_PUBLIC_KEY) plus TARI_PAYOUT_CONFIRM_ENABLED /
# TARI_WALLET_GRPC_ADDRESS / TARI_WALLET_SECRET_FILE — stays host-CLI-only. PAYOUT_SCAN_HEIGHT and
# TARI_WALLET_BIRTHDAY moved to the confirm-gated set below (2026-08 audit reclassification):
# they're wallet-creation metadata, not a secret, and a wrong value only re-scans from a different
# height on the wallet's NEXT creation — recoverable, not destructive.
# Each view key reveals every incoming payout amount/time, so it is never dashboard-committable
# (default-deny already refuses it; named here deliberately). The WALLET_CHANGED and
# CLEARNET_EXPOSED alert toggles are excluded on purpose: they are the tamper-evidence alarms on
# the Telegram channel (the future #338 approval channel), so the dashboard must not silence
# them. Space-separated exact env-key names.
#
# NOTE (2026-08 audit): TELEGRAM_EVENT_RAFFLE_WIN was missing from this list for a while — the one
# event toggle out of step with its 24 siblings, all otherwise editable. If you add a new event
# toggle, list it here AND in control_service.EDITABLE_ENV_KEY_PATHS (dashboard) — the drift
# guard only catches a mismatch between the two, not an omission from both.
CONTROL_DASHBOARD_EDITABLE_KEYS='P2POOL_FLAGS P2POOL_PORT
    XVB_ENABLED XVB_DONATION_LEVEL TARI_REQUIRED DASHBOARD_FAIL_CLOSED
    DASHBOARD_CHECK_UPDATES DASHBOARD_TZ
    MONERO_MEM_LIMIT TARI_MEM_LIMIT MONERO_PREP_THREADS
    HASHRATE_DROP_THRESHOLD_PCT HASHRATE_DROP_MINUTES TELEGRAM_DAILY_SUMMARY_TIME
    TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED
    TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
    TELEGRAM_EVENT_WORKER_JOINED TELEGRAM_EVENT_WORKER_LEFT
    TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_DISK_SPACE
    TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_XVB_NO_SHARE
    TELEGRAM_EVENT_XVB_REGISTRATION TELEGRAM_EVENT_NEW_RELEASE
    TELEGRAM_EVENT_STACK_ONLINE TELEGRAM_EVENT_DAILY_SUMMARY
    TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HASHRATE_LOSS
    TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM
    TELEGRAM_EVENT_HIGH_REJECT_RATE TELEGRAM_EVENT_BLOCK_FOUND
    TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_PAYOUT_CONFIRMED TELEGRAM_EVENT_CONTAINER_UNHEALTHY
    TELEGRAM_EVENT_RAFFLE_WIN'

# The confirm-gated editable set (#719): operationally-disruptive env keys the dashboard MAY commit
# behind a type-to-confirm — NOT the security perimeter (wallets, keys, credentials, onion,
# tor_egress_firewall, dashboard.control.enabled, stratum password, per-rig hosts/tokens all stay
# host-only DEST). Type-to-confirm is UX FRICTION, not a security control: a compromised dashboard
# that can set a field can also fill the confirm box, so this set is strictly the "expensive but
# recoverable, not a breach" class — a data-dir move (re-sync), a stratum-port repoint (rigs
# reconnect), a clearnet-sync enable (host IP exposed during IBD, auto-reverts), a prune enable
# (reclaims disk), or a Tor-load repoint (MONERO_OUT_PEERS: bounded 8-1024 at validation and
# instantly reversible, but the biggest steady-state knob on the shared Tor daemon's CPU — 2026-08
# security review placed it here, not free-commit). The same review REVERTED three keys the
# configurability audit had proposed: PROXY_DONATE_LEVEL (docs/privacy.md's own words — donate
# traffic bypasses the Tor socks5, and a self-approving container could divert up to 99% of
# revenue silently), and PAYOUT_SCAN_HEIGHT / TARI_WALLET_BIRTHDAY (a future-dated value lands at
# the NEXT wallet creation and silently defeats the payout-confirmation tamper evidence — not the
# recoverable class this tier is for). All three stay host-only. describe_change flags
# each CONFIRM only in its in-scope DIRECTION — the flag carries the direction (prune DISABLE, TOR
# data-dir move, etc. still emit DEST and stay refused); this list is the static allowlist the
# gate's default-deny pass consults and the UI mirrors (control_service.CONFIRM_ENV_KEY_PATHS,
# drift-guarded like CONTROL_DASHBOARD_EDITABLE_KEYS).
CONTROL_DASHBOARD_CONFIRM_KEYS='MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR
    STRATUM_PORT MONERO_CLEARNET_SYNC TARI_CLEARNET_SYNC MONERO_PRUNE
    MONERO_OUT_PEERS'

# True if $1 is EXACTLY a canonical dotted-decimal IPv4 literal — four decimal octets 0-255, none
# with a leading zero (a bare "0" is fine; "010"/"0177" are not). curl/glibc's numeric-address
# parsing also accepts a bare decimal integer ("2130706433"), octal per-octet ("0177.0.0.1", AND
# bash's own arithmetic tests would misread "010" as octal 8), hex ("0x7f000001"), and
# short/collapsed forms ("127.1" == 127.0.0.1) — none of those are "canonical" by this definition,
# on purpose. Used two ways below: to fast-path an already-clean literal straight to a
# classification with no resolver round trip, and to recognize a RESOLVED answer's own shape
# (getent's output is always canonical, so this always matches there).
_is_canonical_ipv4() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
    return 0
}

# True if a CANONICAL IPv4 address (already _is_canonical_ipv4-shaped) is inside this host's own
# reach: loopback/this-network (0.x/127.x — all of 127.0.0.0/8, not just 127.0.0.1, so a box's own
# non-default loopback alias is caught too), link-local (169.254.0.0/16, which also covers the
# 169.254.169.254 cloud-metadata address), multicast/reserved (224-255), or the stack's own
# docker-bridge /24 (network.subnet, read from the LIVE config — a same-commit network.subnet
# change is refused elsewhere, on neither editable allowlist, so the live value is the honest
# baseline either way). RFC1918 LAN ranges (10/8, 172.16/12, 192.168/16) are deliberately NOT on
# this list — dialing a LAN rig is this feature's whole purpose.
_ipv4_is_sensitive() {
    local a b prefix
    IFS=. read -r a b _ _ <<<"$1"
    case "$a" in
    0 | 127) return 0 ;;
    169) [ "$b" = 254 ] && return 0 ;;
    esac
    [ "$a" -ge 224 ] && return 0
    prefix=$(jq -r '.network.subnet // "172.28.0.0/24"' "$CONFIG_FILE" 2>/dev/null)
    case "$prefix" in
    *.0/24) prefix="${prefix%.0/24}" ;;
    *) prefix="172.28.0" ;;
    esac
    [ "${1%.*}" = "$prefix" ]
}

# True if $1 is shaped like an IPv6 literal — loose on purpose (a bare colon check): this only
# routes the value to the right classifier below, it doesn't itself decide safety.
_is_ipv6_literal() {
    case "$1" in
    *:*) return 0 ;;
    esac
    return 1
}

# True if an IPv6 literal is inside this host's own reach: loopback (::1), unspecified (::),
# link-local (fe80::/10 — the fixed first 10 bits always print as "fe8"/"fe9"/"fea"/"feb" in
# RFC 5952's canonical form, since none of those leading hex digits is ever zero-suppressed),
# multicast (ff00::/8 — this is what actually closes the /etc/hosts multicast aliases
# ip6-allnodes/ip6-allrouters/ip6-localnet/ip6-mcastprefix; a spelling denylist could only ever
# cover the aliases someone thought to type in, never the address CLASS), or an IPv4-mapped IPv6
# literal (::ffff:a.b.c.d) whose EMBEDDED v4 address is itself sensitive — curl dials the
# embedded address, so the v6 wrapper syntax must not launder it.
_ipv6_is_sensitive() {
    local v6
    v6=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    v6="${v6%%%*}" # strip a zone ID (fe80::1%eth0) — irrelevant to which block it's in
    case "$v6" in
    "::1" | "::") return 0 ;;
    fe8[0-9a-f]:* | fe9[0-9a-f]:* | fea[0-9a-f]:* | feb[0-9a-f]:*) return 0 ;;
    ff[0-9a-f][0-9a-f]:*) return 0 ;;
    ::ffff:*.*.*.*)
        _is_canonical_ipv4 "${v6##*:}" && _ipv4_is_sensitive "${v6##*:}" && return 0
        ;;
    esac
    return 1
}

# Resolves $1 to its numeric addresses (both A and AAAA) via the system resolver — once, at
# commit time; this write path is operator-confirmed, never a hot loop, so a real DNS round trip
# here is the right cost for the safety it buys. `getent ahosts` also resolves any numeric-address
# ATTEMPT that isn't the exact canonical form (decimal integer, octal, hex, short/collapsed —
# _is_canonical_ipv4's own comment) using the SAME numeric parsing glibc's getaddrinfo (and
# therefore curl) uses, so routing those through here too gets an exact answer instead of a
# guess. Prints one deduplicated IP per line; a non-zero exit (including a 5s timeout) means
# resolution failed, which the caller treats as FAIL CLOSED — an unresolved name can never be
# proven safe. This is the one seam a test replaces: point $PATH at a directory carrying a fake
# `getent` ahead of the real one (see tests/stack/test-control-add-only-ssrf.sh) to supply canned
# answers without needing real DNS.
_resolve_host_ips() {
    timeout 5 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# True if $1 — a workers.list[] host the add-only exception is about to let a commit introduce —
# resolves inside THIS host's own reach. Mirrors the READ-path SSRF guard a miner-claimed IP
# already gets (_safe_probe_host, dashboard/mining_dashboard/client/xmrig_client.py, #122) for the
# WRITE path: an add-only append is DASHBOARD-chosen (the operator confirms it in the browser, but
# the actual HTTP request is built and sent by the — possibly compromised — dashboard container),
# so without this a malicious/compromised dashboard could append a phantom descriptor pointed at
# its own host's loopback services or a sibling container, then immediately dial it (with an
# attacker-chosen bearer) via the pre-existing worker-apply/worker-upgrade path, which resolves and
# dials strictly from the HOST's own config. An ordinary LAN or public rig address is unaffected.
#
# #893 round 5: an earlier version of this function classified by STRING SHAPE alone — a denylist
# of "localhost" and its known /etc/hosts aliases. An independent review found that a spelling
# denylist can never answer "does this name reach my own loopback": this host's own Debian
# self-entry (e.g. a box named "gouda" resolving to 127.0.1.1 — every Debian install's own
# /etc/hosts gives its hostname a loopback entry) and, worse, ANY attacker-controlled DNS name
# pointed at 127.0.0.1 both looked like "a genuine hostname, therefore safe" to a string
# classifier — but a live curl dial to either one lands on loopback all the same. There is no
# spelling to denylist against an attacker who controls the DNS answer.
#
# The fix is RESOLVE, THEN CHECK: a canonical IPv4 literal (the exact form _is_canonical_ipv4
# recognizes) is classified directly, since it already IS the address that would be dialed and
# has exactly one meaning. Everything else — including an IPv6 literal, which unlike IPv4 has
# many equally-valid spellings of the same address ("::1" == "0:0:0:0:0:0:0:1") that a hand-rolled
# shortcut classifier could under-recognize the same way the old denylist did — goes through the
# resolver, which normalizes any of those the same way glibc's own numeric-address parsing would.
# EVERY returned address must clear the check — an attacker's own DNS answer can mix one public IP
# with one loopback IP in the same response, so checking only the first would miss it.
# DNS-rebinding (the resolved-at-commit
# address differing from the address at a later dial) is an accepted residual risk, same as
# before resolve-and-check existed: it requires a SEPARATE capability (DNS control) beyond a
# compromised dashboard, and the operator-confirmed write boundary this whole check lives behind
# is why that's acceptable without also adding a dial-time re-check (see the PR's "Dial-time
# re-check" note).
_control_host_is_internal() {
    local host resolved ip
    host=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    host="${host%.}" # a trailing dot is DNS's "FQDN root" marker; getent treats it identically
    if _is_canonical_ipv4 "$host"; then
        # A canonical dotted-decimal literal is unambiguous — it IS the address that would be
        # dialed, so classify it directly with no resolver round trip.
        _ipv4_is_sensitive "$host"
        return
    fi
    # Everything else — a genuine hostname, an IPv6 literal in ANY of its many equally-valid
    # spellings ("::1" and "0:0:0:0:0:0:0:1" are the identical address; a hand-rolled
    # canonicalizer here would just reopen the same bug class this fix closed for IPv4 — a
    # classifier that only recognizes ONE shape and silently treats every other shape as safe), or
    # an IPv4-shaped-but-non-canonical numeric-address ATTEMPT (decimal integer, octal, hex,
    # short/collapsed form) — goes through the resolver. `getent ahosts` normalizes ALL of those
    # into canonical addresses using the SAME parsing glibc's getaddrinfo (and therefore curl)
    # uses, including a bare literal (no network round trip needed for one), so this is correct
    # for a typed literal and a real hostname alike.
    resolved=$(_resolve_host_ips "$host") || return 0 # resolution failed/timed out -> FAIL CLOSED
    [ -n "$resolved" ] || return 0                    # an empty answer -> FAIL CLOSED
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if _is_canonical_ipv4 "$ip"; then
            _ipv4_is_sensitive "$ip" && return 0
        elif _is_ipv6_literal "$ip"; then
            _ipv6_is_sensitive "$ip" && return 0
        else
            return 0 # an answer shape we don't recognize -> FAIL CLOSED, never wave it through
        fi
    done <<<"$resolved"
    return 1
}

control_approval_gate() { # <staged-file> [confirm-token]
    local staged="$1" confirm="${2:-}" porcelain
    # Fail closed if we cannot re-derive the change set (the staged config was validated at
    # preview, so a dry-run failure here means something changed — refuse).
    if ! porcelain=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>/dev/null); then
        printf 'could not re-validate the staged change host-side — refusing to commit'
        return 1
    fi
    # Two config.json blocks never render to .env — the dashboard reads them straight off its
    # config.json mount (load_worker_endpoints + load_energy_config; these are the ONLY two), so the
    # env-diff allowlist below can't see either. Each config.json-only block must be handled here by
    # name or a commit could silently change it: the worker descriptors are REFUSED, dashboard.energy
    # is ALLOWED (#504). Every OTHER config path renders to .env and is gated by the allowlist, so a
    # change there is caught below — a NEW config.json-only block, though, MUST add its own line.
    #
    # The per-worker descriptors — workers.list[] (#506) or its deprecated fallback
    # dashboard.workers[] (#172) — carry per-rig hosts and API tokens (exactly the "free-form string
    # that reaches a URL or credential" class the allowlist exists to keep host-CLI-only). The
    # legacy dashboard.workers[] shape stays refused outright, whatever it changes to: any commit
    # touching it goes back to a host edit.
    #
    # workers.list[] gets ONE narrow ADD-ONLY exception (the click-to-adopt flow): a commit may
    # APPEND a brand-new descriptor to the end of the array, but every entry already live must
    # reappear byte-for-byte, in the same order — so an adopt commit can add rig #4 without ever
    # being able to repoint rig #1's host or token. That asymmetry is deliberate: first adoption
    # gets a human confirming a freshly-observed address (the miner-advertised value is a PREFILL
    # only), but a REPOINT of an already-trusted descriptor is the #122-class escalation an adopt
    # confirmation was never designed to cover, so it stays a host edit like any other change here.
    # Checked as a prefix match: staged.workers.list, cut back to live's own length, must equal
    # live.workers.list exactly. An empty live list makes every staged entry "new" by definition
    # (first adoption); a shorter/reordered/edited staged list can never match and is refused.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        (.dashboard.workers // []) == ($live[0].dashboard.workers // [])
        and ((($live[0].workers.list // []) | length) as $n
             | (.workers.list // [])[0:$n] == ($live[0].workers.list // []))
        ' "$staged" >/dev/null 2>&1; then
        printf 'this change alters an existing per-worker descriptor (workers.list[] / dashboard.workers[], a per-rig host/token) rather than only adding a new one, which is not committable from the dashboard. Edit config.json on the host and run `%s apply`.' "$0"
        return 1
    fi
    # SSRF floor on what an add-only append may point at (see _control_host_is_internal): every
    # NEWLY appended entry's host — never an already-live one, already covered above — must clear
    # this host's own loopback/link-local/internal-bridge reach. Read the live length fresh (not
    # cached from the check above) so this stays correct however the prefix check above evolves.
    local live_n new_host
    live_n=$(jq -r --slurpfile live "$CONFIG_FILE" '($live[0].workers.list // []) | length' "$staged" 2>/dev/null) || live_n=0
    while IFS= read -r new_host; do
        [ -n "$new_host" ] || continue
        if _control_host_is_internal "$new_host"; then
            printf 'a new worker descriptor points at %s, which resolves inside this host'"'"'s own network — a rig'"'"'s control address must be a distinct machine on your LAN, not this host or one of its own containers.' "$new_host"
            return 1
        fi
    done < <(jq -r --argjson n "${live_n:-0}" '(.workers.list // [])[$n:] | .[] | select(has("host")) | .host' "$staged" 2>/dev/null)
    # Closed-schema guard (#33 hardening). A config.json key the stack doesn't recognize renders to
    # NO env var, so it emits zero porcelain rows and slips past the allowlist below — yet the
    # commit's `cp "$staged" "$CONFIG_FILE"` would still persist it. So refuse any staged path that
    # isn't in the canonical schema (config.reference.json). Numeric path components are dropped so a
    # populated known scalar array (notifications.webhooks, telegram.control.allowed_ids) collapses
    # onto its schema-listed key instead of false-rejecting, while a smuggled OBJECT inside such an
    # array still surfaces its unknown sub-key. Both worker-descriptor shapes are exempt: their
    # per-rig object elements aren't enumerated in the reference and the array is already fully
    # guarded above. Fail closed — an unreadable reference or a jq error refuses the commit.
    # INVARIANT: config.reference.json MUST stay a complete superset of every config path this script
    # reads (grep the config_bool/`jq ... "$CONFIG_FILE"` sites), or a legit config carrying a
    # read-but-unlisted path is false-rejected on every commit. That includes backward-compat aliases
    # like xmrig_proxy.* (read at the XvB block) and dashboard.workers[] (read at
    # validate_worker_endpoints, #506). Guarded two ways in tests/stack/run.sh: the
    # legacy-xmrig_proxy round-trip case above, and (#561) an automated drift guard that walks this
    # script's own config_bool/`jq ... "$CONFIG_FILE"` read sites with a conservative fixed-shape
    # extractor and fails loud ("extend the extractor") on a shape it doesn't recognize, rather than
    # risking the false-alarms a naive grep-based path diff would hit on jq-internal and filename
    # dotted tokens.
    local unknown
    if ! unknown=$(jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile cfg "$staged" '
        def norm: [.[] | strings] | join(".");
        ([$cfg[0] | paths | select(.[0:2] != ["dashboard", "workers"] and .[0:2] != ["workers", "list"]) | norm]
         - [$ref[0] | paths | norm])
        | unique | join(", ")' 2>/dev/null); then
        printf 'could not validate the staged config against the schema (%s) — refusing to commit' "$REFERENCE_CONFIG"
        return 1
    fi
    if [ -n "$unknown" ]; then
        printf 'this change adds config keys not in the schema (%s) — refusing to commit. Edit config.json on the host and run `%s apply`.' "$unknown" "$0"
        return 1
    fi
    # Default-deny: refuse if any changed env key is NOT on the editable allowlist, whatever its
    # flag says. Refusal keys off a violation COUNT, not the matched text, so a blank or
    # malformed porcelain row (empty KEY column) still refuses instead of slipping past an
    # emptiness test.
    # The allowlist now spans BOTH the free-to-commit editable set and the confirm-gated set (#719):
    # a change to any other key still fails closed here. The CONFIRM set only gets PAST this pass —
    # it still has to clear the DEST perimeter and satisfy the typed-confirmation check below.
    local editable_re bad hit
    editable_re=$(printf '%s %s' "$CONTROL_DASHBOARD_EDITABLE_KEYS" "$CONTROL_DASHBOARD_CONFIRM_KEYS" | tr -s ' \n' '|')
    bad=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$editable_re" || true)
    if [ "${bad:-0}" -gt 0 ]; then
        hit=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -m1 -vxE "$editable_re" || true)
        printf 'this change alters a security-sensitive setting (%s) that is not committable from the dashboard. Edit config.json on the host and run `%s apply`.' "${hit:-unparseable change row}" "$0"
        return 1
    fi
    # Perimeter: any DEST row is refused outright — the confirm-gate never covers a destructive
    # host-only change. A data-dir MOVE is CONFIRM (below); a prune DISABLE or a TOR data-dir move
    # still emits DEST and is caught here even though its key is on the confirm allowlist.
    if printf '%s\n' "$porcelain" | grep -qE $'^DEST\t'; then
        printf 'this change is destructive and cannot be committed from the dashboard. Edit config.json on the host and run `%s apply`.' "$0"
        return 1
    fi
    # Data-dir destination allowlist (#728). #719 made the four *_DATA_DIR moves confirm-gated, so a
    # dashboard operator who types APPLY can now RELOCATE a service's data dir. assert_safe_dir — the
    # host-shell guard — is a BLOCKLIST: it refuses the catastrophic roots (/, $HOME, bare mounts, …)
    # but passes any OTHER absolute path. At host-shell trust that is proportionate (a shell already
    # has filesystem-wide reach); at dashboard trust it would let a confirmed move target another
    # user's home or another service's data volume and have pithead mkdir/chown -R it and bind-mount
    # it into a recreated container — a destination trust-escalation. This gate runs ONLY for
    # dashboard commits (the host `apply` path never calls control_approval_gate), so it is exactly
    # where the tighter, control-only rule belongs: for a control-channel move, narrow the
    # DESTINATION from a blocklist to an ALLOWLIST — permit only a path under the stack's own data
    # root ($PWD/data, the install dir's data/) or a parent the stack ALREADY keeps data in (each
    # live *_DATA_DIR's parent — a root a host operator already opted into, which covers a co-located
    # shared data root, #455). Anything else is refused EVEN with the APPLY token: that move stays
    # host-CLI-only. Only EXPLICIT absolute paths are checked — "auto"/empty resolves to a stack
    # default that is under a data root by construction. assert_safe_dir still runs at apply time.
    local -a allowed_roots=("$PWD/data")
    local dvar cur
    for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR; do
        cur=$(env_get "$dvar")
        [ -n "$cur" ] && allowed_roots+=("$(dirname "$cur")")
    done
    local ddpath dest root ok_root
    for ddpath in monero.data_dir tari.data_dir p2pool.data_dir dashboard.data_dir; do
        dest=$(jq -r --arg p "$ddpath" 'getpath($p/".") // empty' "$staged" 2>/dev/null)
        # Skip only values resolve_default turns into an in-root stack default — its EXACT set,
        # not a DYNAMIC_* wildcard (which would also swallow a bogus DYNAMIC_FOO that resolve_default
        # passes through literally). A non-absolute/traversal dest never reaches here anyway:
        # assert_safe_dir (called in the dry-run re-derivation at the top of this gate) refuses
        # `..`/relative paths first — keep that ordering.
        case "$dest" in "" | auto | DYNAMIC_DATA | DYNAMIC_HOST | DYNAMIC_ID) continue ;; esac
        ok_root=0
        # Trailing slash on both sides so a root prefix can't false-match a sibling (/data vs
        # /database); an exact-root dest matches too (harmless — still the stack's own dir).
        for root in "${allowed_roots[@]}"; do
            case "$dest/" in "$root"/*) ok_root=1 && break ;; esac
        done
        if [ "$ok_root" -eq 0 ]; then
            printf 'this move sends %s to %s, which is outside the stack data root(s) — a dashboard-confirmed data-dir move must stay under the stack data directory (%s) or a parent it already uses. Apply it from the host with `%s apply`.' "$ddpath" "$dest" "$PWD/data" "$0"
            return 1
        fi
    done
    # Confirm-gate (#719): an in-scope CONFIRM row PROCEEDS only with the operator's typed
    # confirmation. The token is a fixed literal ("APPLY"), orthogonal to the value being set — it
    # is friction that forces the operator to acknowledge an expensive/disruptive op, NOT a security
    # control (the perimeter above is the boundary). control_commit records a confirmed change
    # distinctly in the audit log via the marker file touched here.
    if printf '%s\n' "$porcelain" | grep -qE $'^CONFIRM\t'; then
        if [ "$confirm" != "APPLY" ]; then
            hit=$(printf '%s\n' "$porcelain" | grep -m1 -E $'^CONFIRM\t' | cut -f3-)
            printf 'this change is disruptive (%s) — type APPLY in the dashboard to confirm.' "${hit:-disruptive change}"
            return 1
        fi
        touch "${staged}.confirmed" 2>/dev/null || true
    fi
    # Approved: echo the changed key NAMES so the commit's audit entry can record WHAT changed
    # (#349) without a third dry-run. Names only, never values. dashboard.energy (#504) is
    # config.json-only, so it never appears in the env porcelain — fold a synthetic DASHBOARD_ENERGY
    # name into the list when that block changed, else an energy-only commit would audit no key.
    # Reference defaults merged into both sides (#696), same as the preview leg: the editor
    # round-trips the reference-merged form, and materialized defaults are not a change.
    local keys
    keys=$(porcelain_keys "$porcelain")
    if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
        '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
         == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
        keys="${keys:+$keys }DASHBOARD_ENERGY"
    fi
    printf '%s' "$keys"
    return 0
}

control_write_result() { # <results-dir> <id> <json>
    printf '%s\n' "$3" >"$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}

# One JSON line per handled request. `keys` (optional 6th arg) is the space-separated list of
# changed env-key NAMES from the same dry-run porcelain the approval gate re-derives — names only,
# NEVER values: several allowlist-adjacent keys are secrets host-side, and the audit log is mounted
# into the (semi-trusted) dashboard container. Every free-form field is charset-stripped at write
# time (below) so none can forge a second JSON line — `action` in particular can arrive raw from a
# container-supplied intent on the unknown-action path, so it is NOT a fixed string.
control_audit() { # <audit-file> <id> <actor> <action> <status> [keys]
    # Size bound (#349, same posture as #123): once the log passes 512 KiB, keep the newest 2000
    # entries. Trim-before-append, so the file is complete JSONL at all times and the entry being
    # written is never the one trimmed.
    if [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 524288 ]; then
        tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
    # Sanitize the free-form fields at the write chokepoint so nothing can forge a second JSON line
    # into this tamper-evidence log: `action` may arrive straight from a container-supplied intent
    # on the unknown-action path (a newline + `{...}` would otherwise inject an entry), and `keys`
    # is defense-in-depth over its upstream guard. `id` is a validated uuid4, `status` is
    # code-set, and `actor` is regex-whitelisted upstream — but strip them here too, cheaply.
    printf '{"ts":"%s","id":"%s","actor":"%s","action":"%s","status":"%s","keys":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')" \
        "$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._@-')" \
        "$(printf '%s' "$4" | tr -cd 'a-z-')" \
        "$(printf '%s' "$5" | tr -cd 'a-z-')" \
        "$(printf '%s' "${6:-}" | tr -cd 'A-Z0-9_ ')" >>"$1"
}

# The unique changed env-key names in a dry-run porcelain, one space-separated line (for the
# audit `keys` field). Key NAMES only — the porcelain MSG column is dropped here.
porcelain_keys() {
    printf '%s' "$1" | awk -F'\t' 'NF' | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Preview: stage the candidate config host-side, dry-run it, report the describe_change rows.
control_preview() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local staged="$cdir/staged/$id.json" errf="$cdir/staged/.$id.err" out result
    if [ "$(jq -r '.config | type' "$file")" != "object" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"config must be a JSON object",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # The "blank secret keeps the live value" merge happens HERE, host-side (#440): the request
    # arrives with {"__secret__":true} sentinels for untouched secrets (the container never held
    # the real values — it prefills from the pre-masked copy), and each sentinel is swapped for
    # the live config.json value at staging. A sentinel for a secret that is not actually set
    # collapses to "" rather than leaking a dict into config.json. The staged copy therefore
    # carries merged secrets: it lives in host-only staged/ — never mounted — and is pinned
    # owner-only so a co-tenant on the host can't read secrets from it (#33 hardening). Created
    # under umask 077 so it is never even briefly world-readable (create-then-chmod race); the
    # chmod stays as belt-and-suspenders.
    # Per-worker token sentinels (#172) get the same swap, but out of the fixed-path walk: they
    # live in the variable-length descriptor array — workers.list[] (#506) or its deprecated
    # fallback dashboard.workers[] — so restore each from the LIVE token matched by worker name
    # (first-declared wins on duplicate names, matching the container's probe; whichever shape the
    # live config actually uses). A sentinel for a rig with no live token collapses to "" too, and
    # the sentinel is restored into whichever shape the submitted doc carries.
    (umask 077 && jq --argjson paths "$CONTROL_SECRET_PATHS" --slurpfile live "$CONFIG_FILE" "$WORKER_LIST_JQ"'
        (reduce (($live[0] | worker_list) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = ($w.token // "") else . end)) as $livetok
        | reduce $paths[] as $p (.config;
            (try getpath($p) catch null) as $v
            | if ($v | type) == "object" and $v.__secret__ == true
              then setpath($p; (($live[0] | try getpath($p) catch null) // ""))
              else . end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end' "$file" >"$staged")
    chmod 600 "$staged" 2>/dev/null || true
    if out=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>"$errf"); then
        result=$(printf '%s\n' "$out" | jq -R -s '
            [split("\n")[] | select(length > 0) | split("\t") | {flag: .[0], key: .[1], msg: (.[2:] | join("\t"))}]
            | {status: "previewed", changes: .,
               destructive: (map(.flag == "DEST" or .flag == "CONFIRM") | any), ts: (now | floor)}')
        # #504: dashboard.energy is config.json-only (never rendered to .env), so an energy-only
        # edit produces no porcelain row. Surface it as a normal committable INFO change so the UI
        # arms Apply and the commit lands it in config.json. The approval gate allowlists exactly
        # this config.json-only block; any OTHER config.json-only delta still refuses (see
        # control_approval_gate). INFO never flips destructive, so the existing verdict stands.
        # Compare with the reference defaults merged into BOTH sides (#696): the editor round-trips
        # the reference-merged form, so on a config.json that never set dashboard.energy the staged
        # copy carries the materialized defaults — an absent block and explicit defaults are the
        # same settings, not a change.
        if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
            '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
             == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"dashboard.energy",msg:"Energy calculator settings (dashboard.energy) — electricity price / currency / XMR price updated."}]')
        fi
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "previewed" "$(porcelain_keys "$out")"
    else
        # Validation failed — reject with pithead's own error tail; nothing stays staged.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$errf")" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
    fi
    rm -f "$errf"
}

# Hand the operator-facing stack files that the ROOT control-runner just wrote back to the stack
# owner (#33 v1.4). control_run_pending is root (User=root in pithead-control.service), so its
# `apply` renders `.env` under `umask 077` as root:root 0600 and rewrites the Caddyfile as root —
# but pithead runs a NON-ROOT operator model ($REAL_USER), and a normal operator-run apply leaves
# these files owned by the operator. Without this, the operator's next `status`/`apply` can't even
# read .env (Permission denied), which is what the tier-4 gate caught. The target owner is DERIVED
# from config.json's on-disk owner — an operator-owned file the dashboard container CANNOT write
# (its raw config.json mount was dropped in #440; control_commit's `cp` also preserves its inode/
# owner), so nothing from the request or spool can steer the chown. $USER/$SUDO_USER are NOT usable
# here — the runner is root, so they read as root. The control-dir (staged/results/audit) is
# deliberately host-owned and is NOT touched: that rw/ro split is the #33 trust boundary.
control_reown_operator_files() {
    local owner f
    # GNU stat first, BSD fallback (see the provision_onion_client_auth note). No owner → skip.
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    [ -n "$owner" ] || return 0
    for f in "$ENV_FILE" "Caddyfile" "${CONFIG_FILE}.bak-control" "${CONFIG_FILE}.bak-workers"; do
        [ -e "$f" ] || continue
        # Fail safe: a chown that can't complete leaves the pre-existing bug, never corrupts state.
        chown "$owner" "$f" 2>/dev/null ||
            warn "Could not re-own $f to $owner after the control apply — the operator may need to chown it by hand."
    done
}

# Commit: apply the HOST-SIDE staged copy from the matching preview. A tampered second request
# can't swap the config — commit carries only the id; the config it applies is the one previewed.
control_commit() { # <id> <actor> <control-dir> [confirm-token]
    local id="$1" actor="$2" cdir="$3" confirm="${4:-}"
    local staged="$cdir/staged/$id.json" logf="$cdir/staged/.$id.log" rc=0
    if [ ! -f "$staged" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"no staged intent for this id — preview first",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    if [ -z "$(find "$staged" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"staged intent expired (older than 10 minutes) — preview again",ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    # On refusal the gate's stdout is the reason; on approval it is the changed key names, which
    # the audit entries below record — WHAT changed, by name only (#349).
    local gate_out keys=""
    if ! gate_out=$(control_approval_gate "$staged" "$confirm"); then
        [ -n "$gate_out" ] || gate_out="approval denied"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$gate_out" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged" "${staged}.confirmed"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    keys="$gate_out"
    # A confirm-gated destructive change (#719) is logged AS SUCH — the gate touches this marker
    # when a typed confirmation carried an in-scope CONFIRM row past the perimeter. The distinct
    # `commit-confirmed` action separates a dashboard-confirmed disruptive apply from an ordinary
    # (INFO-only) dashboard commit in the tamper-evidence log. Host-CLI applies never reach this log.
    local audit_action="commit"
    if [ -f "${staged}.confirmed" ]; then
        audit_action="commit-confirmed"
        rm -f "${staged}.confirmed"
    fi
    # Keep a pre-change backup; on failure it is named in the result and left in place. The
    # `apply -y` below re-renders the pre-masked prefill copy (#440), so the dashboard's editor
    # form reflects the committed config on the next load.
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-control"
    cp "$staged" "$CONFIG_FILE"
    "$0" apply -y >"$logf" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        control_reown_operator_files # the root apply wrote .env/Caddyfile as root — give them back (#33)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"applied",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "applied" "$keys"
    else
        # apply's own .apply-incomplete marker handles the container-recreate retry; the config
        # backup lets the operator revert by hand if the new config itself is the problem.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" --arg b "${CONFIG_FILE}.bak-control" '{status:"failed",error:$e,backup:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "failed" "$keys"
    fi
    rm -f "$staged" "$logf" "${staged}.confirmed"
}

# True when SemVer $1 is strictly newer than $2 (either may carry a leading `v`). Both arguments
# are shape-checked (vX.Y.Z) before the call. Pure bash/awk — macOS sort has no -V.
semver_newer() {
    local a b
    a=$(printf '%s' "${1#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    b=$(printf '%s' "${2#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    [ "$a" -gt "$b" ]
}

# Upgrade the install to the latest published release (#59). The container only PROPOSES ("the
# operator confirmed vX.Y.Z"); this host side re-derives the target itself: it asks the GitHub
# release API — over the stack's own Tor SOCKS, like every other stack egress — for the latest
# tag, refuses unless the proposed version matches that tag exactly AND the tag is strictly newer
# than the running VERSION, then downloads the release bundle for the HOST-derived tag and runs
# `pithead upgrade`: the same two steps docs/operations.md documents for a manual update. No
# container string ever reaches a command line or URL — the proposed version is shape-checked and
# used only in an equality comparison, so a container-supplied tag/registry cannot steer what is
# installed (the image-swap RCE the #33 review closed). Source checkouts are refused: their
# update is `git pull`, a judgment the operator makes at a shell. One attempt per 10 minutes,
# so a compromised container cannot use the root runner as an egress beacon or grind GitHub.
control_upgrade() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    _upg_reject() { # <reason> — refuse before anything changed on the host
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "rejected"
    }
    _upg_fail() { # <reason> — the attempt started and did not finish
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    }
    if is_source_checkout; then
        _upg_reject "this install builds from source — upgrade from the host with 'git pull' then './pithead upgrade'."
        return 0
    fi
    # Ordered BEFORE the cosign precondition on purpose: an appliance cannot take a tarball
    # upgrade at all, whatever the host holds, so the appliance answer is the informative one.
    if is_appliance; then
        _upg_reject "this machine is a Pithead OS appliance — it updates through signed OS images, not release tarballs, and a tarball upgrade would silently revert at the next reboot. Use the OS update control in the dashboard header; nothing was changed."
        return 0
    fi
    # #376/#1023: the verifier is a PRECONDITION of a one-click upgrade, not a consequence of already
    # holding a key. Every release bundle ships cosign.pub (make_bundle copies the committed key
    # unconditionally), so the `pithead upgrade` this runner ends up calling will demand the
    # verifier at its image gate whatever the current install holds. Testing the LOCAL cosign.pub
    # instead — what this guard used to do — was blind to the one upgrade that needs it most: an
    # install cut before signing engaged moving to a signed release, which every fielded install
    # makes exactly once. That sailed past here and aborted inside the new CLI, after the download,
    # the extraction, and a full config re-render. Since #1072 the verifier is a container, so this
    # can only fail on a box whose docker is gone — which would also mean nothing is mining. Kept
    # anyway: checked with the source-checkout refusal above, both are "this install cannot take a
    # one-click upgrade at all", and neither claims the throttle or dials out, so a refusal here
    # costs the operator nothing.
    if ! cosign_available; then
        _upg_reject "docker is not available to run the release verifier — every image is verified against the shipped signing key before it is pulled, so this upgrade would fail partway through. Check the Docker daemon and retry."
        return 0
    fi
    # Throttle: one attempt per 10 minutes, checked before any network dial.
    local stamp="$cdir/staged/.upgrade-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        _upg_reject "an upgrade was attempted less than 10 minutes ago — wait for it to finish, then retry."
        return 0
    fi
    # The proposed version must LOOK like a release tag before it is even compared.
    local proposed
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    if [ -z "${PITHEAD_VERSION:-}" ]; then
        _upg_reject "cannot determine the running version (VERSION file missing) — upgrade from the host."
        return 0
    fi
    # Claim the throttle now — BEFORE the network dial — so every well-formed attempt costs the
    # 10-minute window, even one that will be rejected as non-latest. Otherwise a compromised
    # container floods well-formed-but-stale version intents and turns the root runner into an
    # unthrottled GitHub-API / Tor-egress beacon (each fails only at the proposed!=tag check, past
    # the dial). A genuine probe that fails to reach GitHub costing the operator a 10-minute wait
    # is the right trade.
    touch "$stamp"
    # Host-side re-derivation of the target: the latest tag according to GitHub, not the request.
    local rel tag
    if ! gh_release_fetch p2pool-starter-stack/pithead; then
        _upg_reject "$GH_RELEASE_HINT"
        return 0
    fi
    rel=$GH_RELEASE_JSON
    tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "the GitHub release API returned no usable release tag — nothing was changed."
        return 0
    fi
    if [ "$proposed" != "$tag" ]; then
        _upg_reject "requested version $proposed is not the latest published release ($tag) — reload the dashboard and retry."
        return 0
    fi
    if ! semver_newer "$tag" "v$PITHEAD_VERSION"; then
        _upg_reject "already up to date (running v$PITHEAD_VERSION; latest release is $tag)."
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"running",version:$v,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "started"
    # Bundle URL built from the HOST-derived tag only; fetched over the same Tor SOCKS.
    local bundle="$cdir/staged/.$id.tar.gz" logf="$cdir/staged/.$id.log"
    if ! curl -fsSL --max-time 900 --max-filesize "$CURL_CAP_BUNDLE" --socks5-hostname "$GH_SOCKS" -o "$bundle" \
        "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz" 2>/dev/null; then
        rm -f "$bundle"
        _upg_fail "could not download the $tag release bundle over Tor — the stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #376: verify the bundle against the cosign.pub ALREADY on disk before a byte of it is
    # extracted. The new bundle ships its own cosign.pub, but a key that arrives inside the
    # artifact it vouches for proves nothing — trust anchors at the key installed with the
    # release this host already runs. No local key (an older install) keeps today's behaviour —
    # TLS to GitHub plus tag pinning — with one loud line in the journal.
    if [ -f cosign.pub ]; then
        local sig="$cdir/staged/.$id.tar.gz.sig"
        if ! curl -fsSL --max-time 120 --max-filesize "$CURL_CAP_SMALL" --socks5-hostname "$GH_SOCKS" -o "$sig" \
            "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz.sig" 2>/dev/null; then
            rm -f "$bundle" "$sig"
            _upg_fail "the $tag release carries no bundle signature (pithead.tar.gz.sig) — refusing to install it unverified; the stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        # The verifier is a container that sees the install dir at /w (#1072), so it needs the two
        # staged files named as IT sees them. Translated with a guard rather than a blind prefix
        # strip: a path that fell outside the mount would make cosign fail to open the file, and
        # this call reports any failure as "signature FAILED" — a mount bug must not be able to
        # masquerade as a tampered download and burn a legitimate release.
        local cbundle csig
        if ! cbundle=$(cosign_container_path "$bundle") || ! csig=$(cosign_container_path "$sig"); then
            rm -f "$bundle" "$sig"
            _upg_fail "the staged $tag bundle landed outside the install dir, where the release verifier cannot read it — refusing to install it unverified. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        if ! cosign_run verify-blob --key cosign.pub --signature "$csig" --insecure-ignore-tlog=true "$cbundle" >/dev/null 2>&1; then
            rm -f "$bundle" "$sig"
            _upg_fail "bundle signature verification FAILED for $tag — the download does not match the release key; refusing to extract it. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        rm -f "$sig"
    else
        warn "No cosign.pub next to pithead — bundle authenticity rests on TLS to GitHub plus tag pinning only."
    fi
    # Rollback guard (#376): a cosign signature binds BYTES, not a version — an attacker who
    # controls the release response could serve an OLDER genuinely-signed bundle at the $tag URL
    # and silently downgrade the stack to a patched-vulnerable version, and the signature would
    # still verify. Refuse unless the bundle's own top-level VERSION matches the host-derived
    # $tag, read WITHOUT extracting (the bundle unpacks to a fixed `pithead/` dir) so a mismatch
    # touches nothing on disk.
    # #548: the extraction above is a plain assignment, so under errexit a tar failure (a bundle
    # missing pithead/VERSION — corrupt download or a hostile non-pithead archive) would kill the
    # runner outright instead of reaching _upg_fail below, leaving this result stuck at "running"
    # and the claim never released. Guard it like every other dial/extract in this function.
    local bundle_version
    if ! bundle_version=$(tar -xzOf "$bundle" pithead/VERSION 2>/dev/null | tr -d '[:space:]') ||
        [ -z "$bundle_version" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag bundle is missing pithead/VERSION (corrupt or not a pithead bundle) — refusing to install it. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    if [ "v$bundle_version" != "$tag" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag download actually contains version ${bundle_version:-unknown} — refusing a version-mismatched (possible rollback) release. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #629: pick the extraction target. A versioned install (pithead-vX.Y.Z dir) whose data dirs
    # all resolve OUTSIDE the install dir gets the documented bundle-deploy layout
    # (docs/operations.md § A recommended layout): extract into a fresh sibling pithead-<tag>/,
    # seed the operator's config + the install-local state, and run the NEW dir's upgrade — on
    # success its update_current_symlink repoints `current`, and this dir survives untouched as
    # the rollback copy. Anything else falls back to the historical in-place extraction: a plain
    # `pithead/` extract has no versioned layout to maintain, and data living under this dir
    # (the pre-#455 default) would be stranded by a dir swap — the new render would re-derive
    # its default paths under the NEW dir and the stack would come up beside its own data.
    local new_dir="" cwd
    cwd=$(pwd -P) # physical path: the guard below compares canonicalized values on BOTH sides
    if is_versioned_install_dir "$cwd"; then
        new_dir="$(dirname "$cwd")/pithead-$tag"
        local dvar dval
        for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do
            dval=$(env_get "$dvar")
            [ -n "$dval" ] || continue
            # Canonicalize: the .env value may reach the same place through the `current` symlink.
            dval=$( (cd "$dval" 2>/dev/null && pwd -P) || printf '%s' "$dval")
            case "$dval" in
            "$cwd" | "$cwd"/*)
                warn "$dvar resolves inside the install dir — upgrading in place; move the data to a shared root outside the version dir to get per-version rollback dirs."
                new_dir=""
                break
                ;;
            esac
        done
    fi
    # Atomic create, no -p and no pre-check: root must never extract into (or follow a symlink
    # planted at) a path some other local account pre-created — mkdir fails on ANY existing
    # entry, closing the check-to-use race outright (#629 security review). A leftover dir from
    # an earlier failed attempt therefore also lands here: fall back to in-place and say why.
    if [ -n "$new_dir" ] && ! mkdir "$new_dir" 2>/dev/null; then
        warn "$new_dir already exists (a previous attempt, or not ours to create) — upgrading in place. Remove it to get the fresh-dir layout back."
        new_dir=""
    fi
    if [ -n "$new_dir" ]; then
        # Fresh-dir deploy (#629). Plain tar throughout: nothing in $new_dir is running.
        if ! tar -xzf "$bundle" --strip-components=1 -C "$new_dir" 2>"$logf"; then
            rm -f "$bundle"
            _upg_fail "could not extract the $tag bundle into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        rm -f "$bundle"
        # Seed what only the running install has: the operator's config, the rendered .env
        # (preserved secrets — onions, RPC creds; cp -p keeps it 0600), and the install-local
        # state dirs — the control spool (so the audit trail and results history carry over,
        # and the result written below is visible to the RECREATED dashboard, which mounts the
        # new dir's spool), the clearnet sync markers, and the caddy access log. Chain and
        # dashboard data live outside this dir (guarded above) and carry over by path.
        local sdir
        if ! cp -p "$CONFIG_FILE" "$new_dir/config.json" 2>"$logf" ||
            ! cp -p "$ENV_FILE" "$new_dir/.env" 2>>"$logf" ||
            ! mkdir -p "$new_dir/data" 2>>"$logf"; then
            _upg_fail "could not seed config into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        for sdir in control clearnet-state caddy-logs; do
            [ -d "$PWD/data/$sdir" ] || continue
            if ! cp -a "$PWD/data/$sdir" "$new_dir/data/" 2>"$logf"; then
                _upg_fail "could not carry data/$sdir over to $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
                rm -f "$logf"
                return 0
            fi
        done
        # Run the NEW release's upgrade from the NEW dir: it re-renders the generated config
        # (recomputing every $PWD-derived path, including CONTROL_DIR), re-provisions the
        # control-runner units onto the new path, pulls the $tag images, and repoints
        # `current ->` on success. The outcome goes to BOTH spools: the recreated dashboard
        # mounts the new one, a failure before the recreate is read from the old one.
        # #637: this dir — untouched by the whole deploy — is the restore point; name it in the
        # result so the operator learns it exists without reading docs/operations.md first.
        local rdir
        if (cd "$new_dir" && ./pithead upgrade) >"$logf" 2>&1; then
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg r "$cwd" '{status:"upgraded",version:$v,rollback:$r,ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
            done
        else
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" --arg d "$new_dir" --arg r "$cwd" \
                    '{status:"failed",version:$v,rollback:$r,error:($e + " — finish the upgrade from the host: cd " + $d + " && ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
            done
        fi
        rm -f "$logf"
        return 0
    fi
    # #637: unlike the fresh-dir path, this one has no surviving previous dir — and the new
    # release's `upgrade` below re-renders .env (and may migrate config.json). Keep a timestamped
    # pre-upgrade copy of both next to the originals before a byte changes (cp -p keeps .env's
    # 0600; a fresh stamp per attempt so a failed try never overwrites the good copy) and refuse
    # to overwrite the install without one. The destination name is predictable, so root must
    # never write through a symlink a co-tenant planted there (the #629 mkdir guard's attack
    # class): copy to an unpredictable mktemp name first, then rename onto the final name —
    # rename(2) replaces a planted entry without following it.
    _upg_snapshot() { # <src> <dst>
        local tmp
        tmp=$(mktemp "$PWD/.bak-upgrade.XXXXXX") || return 1
        if ! cp -p "$1" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$2"
    }
    local bak
    bak="bak-upgrade-$(date +%Y%m%d-%H%M%S)"
    if ! _upg_snapshot "$CONFIG_FILE" "$CONFIG_FILE.$bak" 2>"$logf" ||
        ! _upg_snapshot "$ENV_FILE" "$ENV_FILE.$bak" 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "could not keep a pre-upgrade copy of config.json/.env: $(tail -c 500 "$logf") — refusing to overwrite the install without a restore point; the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    # Older snapshots hold yesterday's secrets: keep the newest three pairs, prune the rest.
    # Lexical order IS chronological for this stamp format; `|| true` — an empty glob under
    # pipefail must not kill the runner.
    ls -1r "$CONFIG_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    ls -1r "$ENV_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    # The reported paths: CONFIG_FILE is cwd-relative unless the (test-only) override made it
    # absolute — don't prepend $PWD onto an already-absolute path.
    local bak_paths
    case "$CONFIG_FILE" in
    /*) bak_paths="$CONFIG_FILE.$bak" ;;
    *) bak_paths="$PWD/$CONFIG_FILE.$bak" ;;
    esac
    bak_paths="$bak_paths $PWD/$ENV_FILE.$bak"
    # In-place extraction over the running install, in two passes. Pass 1 lays down everything
    # EXCEPT the running script with plain tar, which MERGES existing directories — a release
    # install already carries the non-empty build/* config-template mounts — and overwrites files.
    # A single `-U` (unlink-first) pass over the whole tree instead tries to unlink those non-empty
    # build/* dirs first and aborts ("Cannot unlink: Directory not empty"), leaving the install
    # half-written. Pass 2 is the ONE file that needs -U: the pithead script, unlinked-first so it
    # lands on a NEW inode and the copy executing this very function keeps running from the old one
    # (an in-place overwrite would corrupt it mid-run).
    if ! tar -xzf "$bundle" --strip-components=1 -C "$PWD" --exclude='pithead/pithead' 2>"$logf" ||
        ! tar -xzUf "$bundle" --strip-components=1 -C "$PWD" pithead/pithead 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "the $tag release bundle failed to extract: $(tail -c 500 "$logf") — the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    rm -f "$bundle"
    # The extraction replaced this script on disk (the running copy keeps executing from its old
    # inode); run the NEW pithead's `upgrade`, which re-renders the generated config and pulls the
    # $tag images — exactly what the manual bundle update does.
    if "$PWD/pithead" upgrade >"$logf" 2>&1; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"upgraded",version:$v,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" \
            --arg b "$bak_paths" \
            '{status:"failed",version:$v,backup:$b,error:($e + " — finish the upgrade from the host with ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    fi
    rm -f "$logf"
}

# Validate + dispatch one CLAIMED request file. Trusts no byte of it: must be JSON, only the keys
# id/action/config/actor/version, the id must be a UUID (it becomes the result/staged FILENAME —
# anything else is rejected before it can touch a path), and the action one of the three known verbs.
# Lifecycle verbs for the Telegram control commands (#338): the only two host actions the bot can
# trigger, both FIXED — `restart` runs `$0 restart` (recreate the running stack) and `apply` runs
# `$0 apply -y` (re-render + re-apply the CURRENT on-disk config.json). The container's `action`
# string only SELECTS between these two hardcoded commands; nothing from the request is ever
# interpolated into a command, and `apply` here carries no config change (the default-deny config
# allowlist is only relevant to a config-editing commit, not a re-apply of the source of truth).
# Access control + the deny-on-timeout confirmation are enforced dashboard-side before the intent is
# ever spooled; this side records the actor and outcome in the same tamper-evidence audit log.
control_lifecycle() { # <verb: restart|apply> <id> <actor> <control-dir>
    local verb="$1" id="$2" actor="$3" cdir="$4" rc=0
    local logf="$cdir/staged/.$id.log"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "started"
    # ${PITHEAD_SELF:-$0} is this script (run_chain uses the same handle); the verb is a FIXED
    # literal picked by the case, never a string from the request.
    local self="${PITHEAD_SELF:-$0}"
    case "$verb" in
    restart) "$self" restart >"$logf" 2>&1 || rc=$? ;;
    apply) "$self" apply -y >"$logf" 2>&1 || rc=$? ;;
    *) return 0 ;; # unreachable: the dispatch already gated the verb
    esac
    if [ "$rc" -eq 0 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" '{status:"applied",action:$a,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "applied"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" --arg e "$(tail -c 2000 "$logf")" '{status:"failed",action:$a,error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "failed"
    fi
    rm -f "$logf"
}

# One-shot encrypted backup + one-time "emergency kit" (#908). Reuses stack_backup UNCHANGED
# (~L2793), encrypted ONLY — no request field can pick --no-encrypt (it stays CLI-only), and a
# failure to mint a passphrase refuses before anything is touched, never falls back to plaintext.
# The passphrase is generated HOST-SIDE (generate_node_password: the same 32-char-alnum strength
# already used for the local node RPC creds) and crosses to stack_backup only through its existing
# PITHEAD_BACKUP_PASSPHRASE env-var input — the same channel an unattended cron backup already
# uses — never argv (what the support bundle's redaction targets, #77) and never a file.
#
# One-time handoff lifecycle: the kit (passphrase + archive name + contents + created-at/`ts`)
# rides back through the SAME results/ leg every other verb uses, keyed by the request id — but
# results/ is mounted READ-ONLY into the dashboard container (#33's trust boundary: it can only
# ASK, via requests/), so the container can never itself delete or ack this file the way the
# first-boot wizard's handoff/handoff-ack does (that spool is mounted read-write end to end). The
# deliberate substitute here: a bounded, blocking TTL. Short enough that a stuck backup doesn't
# stall the single-threaded runner's other queued verbs for long; generous next to the dashboard's
# own long-poll window (CONTROL_WAIT_S) so an ordinary page load always sees it. Once it elapses
# the passphrase is overwritten with null — read or not, it is gone. The archive/filename/contents
# stay: it is ciphertext, useless without the passphrase, so it remains downloadable.
# ponytail: TTL, not a container->host ack request (a "backup-ack" verb through requests/ would be
# more precise but is a whole extra verb) — add one if this window proves too tight/loose live.
# Backstop for control_backup's one-time kit: null the passphrase in any kit JSON whose `ts` is
# older than the TTL but which still carries one — the case where the runner was killed during the
# self-redaction sleep (a reboot racing the window) and left a wallet-grade secret in plaintext on
# /data. Run at the top of every drain, so the fresh runner after such a reboot cleans it up. A
# generous margin over the TTL (2x, floor 120s) so this never races the in-band redaction of a kit
# whose window is still open.
control_redact_stale_kits() { # <results-dir>
    local results="$1" f now cutoff ts
    [ -d "$results" ] || return 0
    now=$(date +%s)
    cutoff=$((2 * ${CONTROL_BACKUP_KIT_TTL_S:-20}))
    [ "$cutoff" -lt 120 ] && cutoff=120
    for f in "$results"/*.json; do
        [ -f "$f" ] || continue
        # Cheap gate first: only kits that still hold a passphrase are candidates.
        jq -e '.passphrase // "" | length > 0' "$f" >/dev/null 2>&1 || continue
        ts=$(jq -r '.ts // 0' "$f" 2>/dev/null)
        [ "$((now - ts))" -ge "$cutoff" ] || continue
        jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
            "$f" >"$results/.$(basename "$f").tmp" 2>/dev/null &&
            mv "$results/.$(basename "$f").tmp" "$f"
    done
}

control_backup() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3" rc=0
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "backup" "started"
    # Throttle (mirrors control_upgrade's #59 stamp): a compromised container flooding this verb
    # would repeatedly stop/start the whole mining stack, not just burn CPU — one attempt per 10
    # minutes, checked before the passphrase is even generated.
    local stamp="$cdir/staged/.backup-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"a backup was started less than 10 minutes ago — wait for it to finish, then retry.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    { set +x; } 2>/dev/null # xtrace would print the passphrase assignment below
    local pass
    pass=$(generate_node_password)
    if [ -z "$pass" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"could not generate a backup passphrase — nothing was backed up.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    touch "$stamp" 2>/dev/null || true # claim the throttle before the disruptive part starts
    control_write_result "$results" "$id" "$(jq -n '{status:"running",ts:(now|floor)}')"
    local self="${PITHEAD_SELF:-$0}" logf="$cdir/staged/.$id.log"
    # Run as a CHILD PROCESS, like control_lifecycle/control_commit's own re-invocations:
    # stack_backup's error() exits its whole process on failure, which must not take the drain
    # loop's other pending requests down with it.
    export PITHEAD_BACKUP_PASSPHRASE="$pass"
    "$self" backup -y >"$logf" 2>&1 || rc=$?
    unset PITHEAD_BACKUP_PASSPHRASE
    if [ "$rc" -ne 0 ]; then
        control_write_result "$results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        rm -f "$logf"
        pass=""
        return 0
    fi
    local archive
    archive=$(sed -n 's/^\[pithead\] Backup written to: //p' "$logf" | tail -n1)
    rm -f "$logf"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the backup ran but the archive could not be located afterward.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        pass=""
        return 0
    fi
    # Place it on the ALREADY-shared results/ leg (#33) — no new bind mount, keyed by the same id
    # as its own result. Tighter perms than the rest of results/ (which relies on default,
    # effectively world-readable perms — fine, nothing there is a secret): root-owned,
    # group-readable by the dashboard's own uid/gid only (APP_UID/APP_GID, #255), because this
    # file briefly shares a directory with its own passphrase below.
    local fname dest
    fname=$(basename "$archive")
    dest="$results/$id.tar.gz.enc"
    mv "$archive" "$dest"
    chown "0:$APP_GID" "$dest" 2>/dev/null || true
    chmod 640 "$dest" 2>/dev/null || true
    (umask 077 && control_write_result "$results" "$id" "$(jq -n --arg p "$pass" --arg f "$fname" '
        {status:"applied", passphrase:$p, archive:$f,
         contents:["config.json","the stack .env (secrets)","Caddyfile, if present",
                   "the Tor onion-service key directory, if present","the dashboard database"],
         note:"This passphrase is shown once and cannot be recovered — save it now.",
         ts:(now|floor)}')")
    pass=""
    chown "0:$APP_GID" "$results/$id.json" 2>/dev/null || true
    chmod 640 "$results/$id.json" 2>/dev/null || true
    control_audit "$auditf" "$id" "$actor" "backup" "applied"
    # The blocking TTL described above the function. Overridable so tests don't sit through it.
    sleep "${CONTROL_BACKUP_KIT_TTL_S:-20}"
    jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
        "$results/$id.json" >"$results/.$id.json.tmp" 2>/dev/null &&
        mv "$results/.$id.json.tmp" "$results/$id.json"
}

# Resolve a worker name to its dial target (host + control_port + token) from the HOST's OWN
# config.json — never the caller's intent (#122 SSRF). Shared by control_worker_apply and
# control_worker_upgrade, which had drifted this whole resolution+validation block out of sync
# line-for-line: the worker-name charset pin, the three WORKER_LIST_JQ lookups, and the
# host/port/token guards. On success sets RESOLVED_HOST/RESOLVED_CPORT/RESOLVED_TOKEN and returns
# 0. On failure sets RESOLVE_WORKER_ERR to the operator-facing rejection message (leaving the
# RESOLVED_* vars empty) and returns 1 — the caller writes its own rejected result/audit line with
# that message, since worker-apply and worker-upgrade audit under different action names.
resolve_worker_target() { # <worker-name> <verb-for-the-host-missing-message, e.g. "edit"/"upgrade">
    local worker="$1" verb="$2"
    RESOLVED_HOST="" RESOLVED_CPORT="" RESOLVED_TOKEN="" RESOLVE_WORKER_ERR=""
    # The worker name is a config.json lookup key AND (in name-auth) a bearer; pin its charset.
    # LC_ALL=C so [!-~] is the printable-ASCII BYTE range: under a UTF-8 locale GNU grep reads the
    # range by collation order and rejects ordinary names like "rig1" (caught by the release gate on a
    # UTF-8 box; CI runs under C and missed it). jq's test() above is codepoint-based and unaffected.
    if ! printf '%s' "$worker" | LC_ALL=C grep -qE '^[!-~]{1,128}$'; then
        RESOLVE_WORKER_ERR="malformed or missing 'worker' name in the request."
        return 1
    fi
    # Resolve the rig's ADDRESS + BEARER from the HOST's config.json — never the intent. A rig with no
    # host or no token cannot be a target (fail closed): the rig's control path is bearer-mandatory and
    # we only ever dial an operator-set host.
    local host cport token
    host=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .host // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    cport=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .control_port // 8082' "$CONFIG_FILE" 2>/dev/null | head -1)
    token=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .token // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -z "$host" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no configured host in workers.list[] (or the deprecated dashboard.workers[]) — set host + control_port + token to $verb it."
        return 1
    fi
    # host charset guard (#122): no port/path/userinfo can be smuggled into the URL below.
    if ! printf '%s' "$host" | grep -qE '^[A-Za-z0-9._-]{1,253}$'; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid host."
        return 1
    fi
    if ! is_valid_port "$cport"; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid control_port."
        return 1
    fi
    if [ -z "$token" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no token in workers.list[] (or the deprecated dashboard.workers[]) — the rig's control API is bearer-mandatory."
        return 1
    fi
    RESOLVED_HOST="$host" RESOLVED_CPORT="$cport" RESOLVED_TOKEN="$token"
    return 0
}

# Worker config apply (#185): POST an operator's writable-key change to a RigForge rig's control API
# and record the outcome for the dashboard's config history. The intent carries ONLY the worker NAME
# and the CHANGES — never a host, port, or token: the runner resolves the rig's real address + bearer
# from the HOST's own config.json (workers.list[] / the deprecated dashboard.workers[], #506), so a
# tampered intent can at most target another ALREADY-configured rig, never an arbitrary host (#122
# SSRF), and the rig's access token —
# masked out of the container (#440) — never leaves the host. Changes are re-validated against the
# same writable allowlist the rig enforces (defence in depth). Every result/audit line the container
# reads back carries the change_id + status only, never the token.
control_worker_apply() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "started"
    _wa_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "rejected"
    }
    _wa_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "failed"
    }
    local worker changes
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-upgrade uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "edit"; then
        _wa_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    # Changes must be a non-empty object whose keys are ALL writable via the rig's control path (the
    # rig re-validates; this is the host-side gate — mirrors rigforge WRITABLE, #185/#236).
    changes=$(jq -c '.changes // {}' "$file")
    local badkeys
    badkeys=$(printf '%s' "$changes" | jq -r '
        (["pools","DONATION","autotune","watchdog","watchdog_interval_min","max_temp_c"]) as $ok
        | if (type) != "object" or (length) == 0 then "__empty__"
          else [keys[] | select(. as $k | $ok | index($k) | not)] | join(",") end' 2>/dev/null)
    if [ "$badkeys" = "__empty__" ]; then
        _wa_reject "'changes' must be a non-empty object of writable config keys."
        return 0
    fi
    if [ -n "$badkeys" ]; then
        _wa_reject "keys not writable via the control path: $badkeys"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    # Per-drain dial budget (hardening): worker-apply is the only control action that blocks the
    # single-threaded root runner on a network round-trip (a dial + a status poll, tens of seconds).
    # Cap how many actually dial per drain so a compromised container can't queue a flood of valid
    # worker-applies and starve legitimate commit/restart/upgrade intents. The counter lives in the
    # runner's shell (control_run_pending seeds it), so it persists across the drain loop. Over-budget
    # intents are rejected with a retry hint — the operator just re-applies; a real fleet edit is a
    # handful of rigs, never dozens at once.
    if [ "${CONTROL_WA_BUDGET:-0}" -le 0 ]; then
        _wa_reject "too many worker config changes in one cycle — retry in a moment."
        return 0
    fi
    CONTROL_WA_BUDGET=$((CONTROL_WA_BUDGET - 1))
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" '{status:"running",worker:$w,ts:(now|floor)}')"
    # POST the change to the rig's control API. Direct LAN dial (like the read path) — NOT Tor: the rig
    # is an operator-set host on the mining LAN, not clearnet. The token rides one header, never the
    # URL, the result, or the audit log.
    local url="http://$host:$cport/apply" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$changes" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wa_fail "could not reach worker '$worker' control API at $host:$cport — nothing was applied."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # The rig's error string is attacker-influenceable (a compromised rig or a LAN MITM); cap it
        # before it lands in a result the container reads and the dashboard renders.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wa_reject "worker '$worker' refused the change (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The rig stages → validates →
    # applies → liveness-checks → rolls back if the miner doesn't return live, seconds later. The 20s
    # deadline (plus the 15s dial above) stays under the dashboard's CONTROL_WAIT_S POST wait, so the
    # dashboard always catches a terminal-ish result and records it in the config history. Terminals
    # are applied / rejected / rolled_back / failed — failed is the rig unable to restore its own
    # rollback backup (present since the v1.11.2 fleet floor), a real fault the result must carry
    # with its reason, never a deadline-burned "accepted".
    local sbody scode status reason ckeys deadline=$((SECONDS + 20))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 2
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours (a concurrent change could be newer).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | rejected | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            ckeys=$(jq -c '.changed_keys // []' "$sbody")
            rm -f "$sbody"
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --argjson k "$ckeys" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,changed_keys:$k,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-apply" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status in time — the change is staged on the rig and will apply; the
    # container can keep polling the rig via the next read. Record accepted-but-pending, not a failure.
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" \
        '{status:"accepted",change_id:$c,worker:$w,note:"queued on the rig; outcome not yet observed",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "accepted"
}

control_worker_upgrade() { # <claimed-file> <id> <actor> <control-dir>
    # One-click RigForge upgrade for a single rig (#597) — fuses the two existing templates:
    # resolve_worker_target's rig resolution/guards (address + bearer from the HOST config, never
    # the intent, shared with control_worker_apply) and control_upgrade's throttled host-side
    # target re-derivation over Tor (the container proposes a version; GitHub decides the real
    # target; a mismatch is refused).
    # The rig bounds whatever tag we send with its own monotonic + ancestry guards and rolls back
    # a build that doesn't come back live — rollback coverage is rig-side (rigforge#322).
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "started"
    _wu_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "rejected"
    }
    _wu_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "failed"
    }
    local worker proposed
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-apply uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "upgrade"; then
        _wu_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _wu_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    # Per-drain budget: an upgrade blocks the single-threaded root runner on the rig's build
    # (minutes, vs seconds for worker-apply), so exactly ONE dials per drain. v1 is per-worker
    # only — no "upgrade all" — and a real fleet upgrade is one rig at a time by design.
    if [ "${CONTROL_WU_BUDGET:-0}" -le 0 ]; then
        _wu_reject "another worker upgrade is already in this cycle — retry in a moment."
        return 0
    fi
    CONTROL_WU_BUDGET=$((CONTROL_WU_BUDGET - 1))
    # Host-side re-derivation of the target from the RigForge release API over Tor — load-bearing:
    # the rig deliberately computes no "latest" itself (ADR 0002 D4), it bounds the tag we send.
    # The derived tag is cached for 10 minutes and the dial itself is stamp-throttled to one per
    # 10 minutes (claimed BEFORE the dial, control_upgrade's anti-beacon lesson): a compromised
    # container flooding well-formed intents costs at most one GitHub/Tor egress per window,
    # while a legitimate rig-after-rig fleet upgrade reuses the cached tag.
    local tagf="$cdir/staged/.rigforge-latest-tag" stampf="$cdir/staged/.rigforge-latest-stamp" tag=""
    if [ -n "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        tag=$(cat "$tagf" 2>/dev/null)
    fi
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            _wu_reject "a RigForge release lookup was attempted less than 10 minutes ago and no usable tag is cached — retry in a few minutes."
            return 0
        fi
        touch "$stampf"
        local rel
        if ! gh_release_fetch p2pool-starter-stack/rigforge; then
            _wu_reject "$GH_RELEASE_HINT"
            return 0
        fi
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            _wu_reject "the GitHub release API returned no usable RigForge release tag — nothing was changed."
            return 0
        fi
        printf '%s' "$tag" >"$tagf"
    fi
    if [ "$proposed" != "$tag" ]; then
        _wu_reject "requested version $proposed is not the latest published RigForge release ($tag) — reload the dashboard and retry."
        return 0
    fi
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" --arg v "$tag" '{status:"running",worker:$w,version:$v,ts:(now|floor)}')"
    # POST the upgrade to the rig's control API — direct LAN dial like worker-apply, NOT Tor. The
    # body carries the HOST-derived tag only; the token rides one header, never the URL or result.
    local url="http://$host:$cport/upgrade" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$(jq -n --arg v "$tag" '{version:$v}')" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wu_fail "could not reach worker '$worker' control API at $host:$cport — nothing was changed."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # Rig-supplied text is attacker-influenceable (a compromised rig / LAN MITM); cap it.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wu_reject "worker '$worker' refused the upgrade (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The cap is a deliberate
    # trade: a no-rebuild upgrade (the common case — git checkout + restart) reaches terminal in
    # well under 90s, while a pin-change rebuild (~10 min) times out to "accepted" below and the
    # badge (#596) clears on its own when the rig reports the new version. Polling the full build
    # would hand a hostile/hung rig 12 minutes of the single-threaded root drain per intent
    # (sec-review finding) — 90s keeps the stall bound in worker-apply's envelope. Since
    # rigforge#320 (v1.12.0) the rig writes an in-progress "started" plus first-class noop
    # (already on the target) and throttled (its own 6h anti-beacon window) terminals; "started",
    # like a non-matching change_id, just means keep polling. Terminals are applied / noop /
    # throttled / rolled_back / failed. The cap is overridable (CONTROL_WU_POLL_CAP) so the stack
    # tests can prove the timeout→accepted fallback in seconds.
    local sbody scode status reason deadline=$((SECONDS + ${CONTROL_WU_POLL_CAP:-90}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 5
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours — the rig may still be showing a
        # PREVIOUS change's terminal state (no in-progress status, rigforge#320).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | noop | throttled | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            rm -f "$sbody"
            # Legacy remap: a pre-rigforge#320 rig (≤ v1.11.2, the supported floor) collapses its
            # 6h anti-beacon throttle into failed+"throttled — ..." free text, and retry-later
            # must render calm, not red. Anchored to that leading word on purpose: a modern rig's
            # genuine failed can mention the throttle too ("throttle state unavailable",
            # rigforge#321's fail-closed refusal) and must STAY a fault. Drop the remap once the
            # fleet floor reaches rigforge v1.12.0 (first-class throttled) — the v2 appliance
            # bakes v1.15.0, so post-v2 fleets are already past it.
            if [ "$status" = "failed" ] && printf '%s' "$reason" | grep -qiE '^throttled'; then
                status="throttled"
            fi
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --arg v "$tag" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,version:$v,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-upgrade" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status inside the cap — the upgrade is running on the rig. Record
    # accepted, not failure: the badge (#596) clears on its own when the rig's next summary poll
    # reports the new version ('applied' echoes no version, rigforge#320 — the summary is the
    # confirmation of record either way).
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" --arg v "$tag" \
        '{status:"accepted",change_id:$c,worker:$w,version:$v,note:"upgrade still running on the rig — check the rig if the badge has not cleared in a while",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "accepted"
}

# --- OS update over the control channel (appliance A/B slots, dashboard-driven) ---------------
# The dashboard container only ASKS; every verb below re-derives, re-verifies and executes on the
# HOST, and every one refuses outright on a non-appliance host (no RAUC, nothing to update).
# The flow is deliberately staged — check, download (resumable, to /data), verify the LOCAL file,
# install the verified local bundle, then an EXPLICIT reboot — so every network step is separated
# from every destructive step and a bundle is never stream-installed over Tor.

os_update_staging_dir() { printf '%s' "${PITHEAD_OS_UPDATE_DIR:-$PWD/data/os-update}"; }
os_update_inflight_file() { printf '%s/in-flight.json' "$(os_update_staging_dir)"; }
os_update_target_file() { printf '%s/target.json' "$(os_update_staging_dir)"; }

# The persistent OS-update state the dashboard renders (step across reloads and reboots, and the
# post-reboot verdict). Lives in the results/ leg of the control spool under a fixed non-uuid
# name, so it rides the existing read-only mount into the container — its presence is also how
# the dashboard knows it runs on an appliance at all. Atomic like control_write_result.
os_state_write() { # <control-dir> <json>
    mkdir -p "$1/results" 2>/dev/null || true
    printf '%s\n' "$2" >"$1/results/.os-update-state.tmp" &&
        mv "$1/results/.os-update-state.tmp" "$1/results/os-update-state.json"
}

# ponytail: test seam for the KVM battery — a root-owned `os-update-test-base` file beside the
# checkout redirects the release lookup and the bundle download to a local URL (and drops the
# Tor SOCKS, which cannot reach the bench). The ownership check stops a non-root plant from
# steering root's downloads; verification still runs for real against the slot keyring either
# way, so the seam can redirect WHERE the bytes come from but never what installs.
os_update_test_base() {
    local f="$PWD/os-update-test-base"
    { [ -f "$f" ] && [ -O "$f" ]; } || return 1
    tr -d ' \t\r\n' <"$f"
}

# The latest-release JSON, over the stack's own Tor SOCKS like every other stack egress.
#
# The real lookup is gh_release_fetch's, not a third copy of it. This one used `curl -fsS`, and
# `-f` collapses every non-2xx into one exit code — so a spent GitHub rate limit came out of
# os-check as "could not reach the release API over Tor" and sent the operator to a doctor run
# that correctly reports Tor healthy (#1081, which fixed the two DIY lookups and never saw this
# one). Only the bench seam keeps its own dial: it points at a local URL with no Tor in the path.
# Sets GH_RELEASE_JSON on success and GH_RELEASE_HINT on failure, like the shared fetch, so the
# caller must run it as a plain command — a command substitution is a subshell and would discard
# both. rc 2 = never reached the server at all, same convention as gh_release_fetch (#1050).
os_release_fetch() {
    local base
    if base=$(os_update_test_base); then
        GH_RELEASE_HINT=""
        GH_RELEASE_JSON=""
        if ! GH_RELEASE_JSON=$(curl -fsS --max-time 60 --max-filesize "$CURL_CAP_SMALL" \
            "$base/releases-latest.json" 2>/dev/null); then
            GH_RELEASE_HINT="could not reach the release API — nothing was changed."
            return 2
        fi
        return 0
    fi
    gh_release_fetch p2pool-starter-stack/pithead
}

# One shared refusal writer for the os-* verbs (they share one result/audit shape).
control_os_refuse() { # <cdir> <id> <actor> <action> <status rejected|failed> <reason>
    control_write_result "$1/results" "$2" "$(jq -n --arg s "$5" --arg e "$6" '{status:$s,error:$e,ts:(now|floor)}')"
    control_audit "$1/audit/control.log" "$2" "$3" "$4" "$5"
}

# The gate every os-* verb opens with: appliance only, and at most ONE os verb per drain — a
# download or install holds the single-threaded root runner for minutes, so a compromised
# container queueing a flood must not starve commit/restart intents (the worker-upgrade lesson).
control_os_gate() { # <cdir> <id> <actor> <action> — rc 0 = proceed (budget consumed)
    if ! is_appliance; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "OS updates apply only to a Pithead OS appliance — this install updates through release tarballs (the header upgrade button). Nothing was changed."
        return 1
    fi
    if [ "${CONTROL_OS_BUDGET:-0}" -le 0 ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "another OS-update step is already running in this cycle — retry in a moment."
        return 1
    fi
    CONTROL_OS_BUDGET=$((CONTROL_OS_BUDGET - 1))
    return 0
}

# The local-bundle refusals shared by os-verify and os-install (install re-runs them so a result
# can never go stale between the two clicks). Echoes the refusal reason; empty = pass. Returns 0
# for a real verdict — the caller deletes a refused bundle, only bundles that verify may sit
# staged — and 3 when rauc itself could not run, where the caller KEEPS the bundle: deleting a
# multi-GB Tor download is a verdict too, and a tool that never ran has not earned one.
os_verify_bundle_reason() { # <bundle> <target-tag>
    local bundle="$1" tag="$2" rc=0
    # Signature first: `rauc info` verifies the bundle signature against the system keyring
    # before it prints anything, so an unsigned or mis-signed file fails here, before any
    # metadata is trusted. A nonzero exit is only a signature verdict when rauc actually ran
    # and judged the file — an exec failure or a crash (rc 126/127, or death by signal) gets
    # one retry and then its own honest reason instead of masquerading as a bad signature.
    rauc info "$bundle" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ge 126 ]; then
        rc=0
        rauc info "$bundle" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -ge 126 ]; then
            printf '%s' "rauc could not run to judge the downloaded bundle — the file was kept; retry, and check the host journal if this repeats."
            return 3
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%s' "the downloaded file failed signature verification against this machine's release keys — it was deleted; check for updates and download again."
        return 0
    fi
    # Compatible: refuse a definite mismatch early. `rauc install` re-enforces this
    # authoritatively either way, so an unparseable value falls through rather than refusing.
    local sys_compat bundle_compat
    sys_compat=$(sed -n 's/^compatible=//p' "${PITHEAD_RAUC_SYSTEM_CONF:-/etc/rauc/system.conf}" 2>/dev/null | head -1)
    bundle_compat=$(rauc info --output-format=shell "$bundle" 2>/dev/null |
        sed -n "s/^RAUC_MF_COMPATIBLE='\(.*\)'\$/\1/p" | head -1)
    if [ -n "$sys_compat" ] && [ -n "$bundle_compat" ] && [ "$sys_compat" != "$bundle_compat" ]; then
        printf '%s' "the bundle is built for '$bundle_compat' but this machine is '$sys_compat' — it cannot install here and was deleted."
        return 0
    fi
    # Variant: a bundle that would flip the machine's SSH/shell posture needs the CLI's explicit
    # consent flow, never a dashboard click — no override is surfaced here on purpose.
    local bundle_version
    if os_update_needs_confirmation "$(os_running_variant)" "$(os_bundle_variant "$bundle")"; then
        printf '%s' "this bundle would change the machine's shell/SSH build variant — that consent belongs at the machine, not on the dashboard. The bundle was deleted; nothing was changed."
        return 0
    fi
    # Version floor + downgrade: the same refusals `pithead os-update` enforces (shared code) —
    # a valid signature does not stop replaying an old vulnerable release.
    bundle_version=$(os_bundle_meta "$bundle" version)
    local reason
    reason=$(os_update_version_guard "$bundle_version" 0)
    if [ -n "$reason" ]; then
        printf '%s' "$reason"
        return 0
    fi
    # Equality passes the shared guard on purpose — the CLI keeps same-version installs for
    # manual slot repair at the machine — but on the dashboard door an equal bundle is only a
    # lever for looped reinstall-and-reboot downtime, so it refuses here.
    if os_semver_ok "$bundle_version" && [ "$bundle_version" = "$(os_running_version)" ]; then
        printf '%s' "already on v$bundle_version, nothing to update — the bundle was deleted."
        return 0
    fi
    # The bundle's own stamp must match the host-derived target — a mirror serving an OLDER
    # genuinely-signed bundle at the newest tag's URL would otherwise still pass the floor.
    if [ "v$bundle_version" != "$tag" ]; then
        printf '%s' "the downloaded bundle stamps itself '${bundle_version:-unstamped}' but the published release is $tag — refusing a version-mismatched file; it was deleted."
        return 0
    fi
    return 0
}

# os-check: re-derive the latest release + its .raucb asset on the HOST, over Tor. The container
# proposes nothing here; the cached derivation is what os-download later holds the container's
# proposal against. Claim-before-dial throttle (one lookup per 10 minutes), the anti-beacon
# lesson from the one-click upgrade; a fresh cache answers without dialing at all.
control_os_check() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-check" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "started"
    local osdir tagf stampf shortstampf tag size notes rel
    osdir=$(os_update_staging_dir)
    mkdir -p "$osdir"
    tagf=$(os_update_target_file)
    stampf="$osdir/.check-stamp"
    shortstampf="$osdir/.check-stamp-short"
    if [ -z "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "an update check ran less than 10 minutes ago — retry in a few minutes."
            return 0
        fi
        if [ -n "$(find "$shortstampf" -mmin -1 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the last check could not confirm it reached the network — retry in about a minute."
            return 0
        fi
        # The throttle stamp is claimed AFTER the dial, and its window depends on whether the
        # dial confirmed it reached the release API (#1050, revised after review). rc 2 from
        # os_release_fetch does NOT mean "no real attempt": through Tor a circuit-build
        # timeout, an exit-relay refusal, or a mid-handshake TLS failure comes back as the
        # exact same curl nonzero as a purely local "no route" — and those DID put a real dial
        # on the wire. So rc 2 still claims a stamp, just a SHORT one (60s, "$shortstampf")
        # instead of the full 10 minutes: this bounds how often a dashboard-authenticated actor
        # can force another real Tor dial while the transport is degraded, without making an
        # operator who fixes a genuinely-down Tor daemon wait a full 10 minutes to find out. A
        # fetch that DID definitively reach GitHub — success, or a definitive refusal like the
        # rate limit below — still claims the full stamp exactly as before; that dial happened
        # and #1081 relies on it staying throttled (releasing it there would restore the
        # unthrottled beacon that guard exists to stop). Every other nonzero rc reached the
        # server.
        local fetch_rc=0
        os_release_fetch || fetch_rc=$?
        if [ "$fetch_rc" -ne 0 ]; then
            if [ "$fetch_rc" -eq 2 ]; then
                touch "$shortstampf"
            else
                touch "$stampf"
            fi
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "$GH_RELEASE_HINT"
            return 0
        fi
        touch "$stampf"
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the release API returned no usable release tag — nothing was changed."
            return 0
        fi
        size=$(printf '%s' "$rel" | jq -r --arg n "pithead-os-$tag.raucb" \
            '[.assets[]? | select(.name == $n)][0].size // 0' 2>/dev/null)
        notes=$(printf '%s' "$rel" | jq -r '.html_url // ""' 2>/dev/null | head -c 300)
        if ! printf '%s' "$size" | grep -qE '^[0-9]+$' || [ "$size" -le 0 ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the latest release ($tag) publishes no appliance OS bundle — nothing to download."
            return 0
        fi
        jq -n --arg t "$tag" --argjson s "$size" --arg n "$notes" \
            '{tag:$t,size:$s,notes:$n,ts:(now|floor)}' >"$tagf.tmp" && mv "$tagf.tmp" "$tagf"
    fi
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    notes=$(jq -r '.notes // ""' "$tagf" 2>/dev/null) || notes=""
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        rm -f "$tagf"
        control_os_refuse "$cdir" "$id" "$actor" "os-check" failed "the cached update target is unreadable — it was cleared; check again in a few minutes."
        return 0
    fi
    local newer=false running
    running=$(os_running_version)
    if os_semver_ok "$running" && os_semver_ok "$tag" && semver_newer "$tag" "v$running"; then
        newer=true
    fi
    # A manual check moves the operator on — drop any leftover verdict banner with it.
    if [ -f "$cdir/results/os-update-state.json" ] &&
        [ "$(jq -r '.step // "idle"' "$cdir/results/os-update-state.json" 2>/dev/null)" = "idle" ]; then
        os_state_write "$cdir" '{"step":"idle"}'
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson s "$size" --arg n "$notes" --argjson nw "$newer" \
        '{status:"checked",version:$v,size:$s,notes:$n,newer:$nw,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "checked"
}

# os-download: fetch the .raucb for the HOST-derived target to /data, resumable (`curl -C -`).
# Each intent is one bounded attempt — the dashboard resubmits on a "partial" result and the
# transfer resumes, so a Tor-slow gigabyte arrives across attempts while the runner is never
# held longer than the attempt cap. Mining is untouched throughout; nothing installs from here.
control_os_download() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-download" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "started"
    local osdir tagf tag size proposed final part
    osdir=$(os_update_staging_dir)
    tagf=$(os_update_target_file)
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "no update target is known — check for updates first."
        return 0
    fi
    proposed=$(jq -r '.version // ""' "$file")
    if [ "$proposed" != "$tag" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "requested version ${proposed:-none} is not the checked release ($tag) — check for updates first, then retry."
        return 0
    fi
    # An equal version is nothing to update — refused before a byte moves, or a compromised
    # container could loop a same-version download (gigabytes over Tor) into install and reboot
    # for forced downtime and flash wear. Same-version slot repair stays with `pithead
    # os-update` at the machine, which allows equality on purpose.
    if [ "$tag" = "v$(os_running_version)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "already on $tag, nothing to update."
        return 0
    fi
    mkdir -p "$osdir"
    final="$osdir/pithead-os-$tag.raucb"
    part="$final.partial"
    # One update at a time: a partial or staged bundle for any OTHER version is superseded.
    find "$osdir" -maxdepth 1 -name 'pithead-os-*.raucb*' \
        ! -name "pithead-os-$tag.raucb" ! -name "pithead-os-$tag.raucb.partial" -delete 2>/dev/null || true
    local have=0
    [ -f "$part" ] && have=$(wc -c <"$part" | tr -d ' ')
    if [ -f "$final" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$(wc -c <"$final" | tr -d ' ')" \
            '{status:"downloaded",version:$v,bytes:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    # Disk headroom for the REMAINDER plus a 1 GiB margin, refused up front — a download that
    # fills /data would starve the chain databases mid-write, which is far worse than waiting,
    # and the LMDB chain stores degrade well before the disk actually fills. The margin has to
    # absorb the .partial in flight plus results growth for the whole transfer.
    local avail_kb need
    avail_kb=$(df -Pk "$osdir" 2>/dev/null | awk 'NR==2{print $4}') || avail_kb=0
    need=$(((size - have) / 1024 + 1048576))
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "not enough free space on /data for the update bundle (need about $((need / 1024)) MiB free, have $((${avail_kb:-0} / 1024)) MiB) — free space and retry."
        return 0
    fi
    local url socks="" base prefix
    if base=$(os_update_test_base); then
        url="$base/pithead-os-$tag.raucb"
    else
        prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
        [ -n "$prefix" ] || prefix="172.28.0"
        socks="${prefix}.25:9050"
        url="https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead-os-$tag.raucb"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$have" --argjson t "$size" \
        '{status:"downloading",version:$v,bytes:$b,total:$t,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloading",version:$v}')"
    # Bounded attempt in the background; the loop surfaces live progress into the result the
    # dashboard is polling. curl -C - resumes from whatever the partial file already holds.
    # (Two invocations, not a conditional argument array — macOS's bash 3.2 rejects an empty
    # array expansion under set -u, and the tier-1 suite runs this function there.)
    local attempt="${PITHEAD_OS_DL_ATTEMPT:-600}" pid rc=0 bytes
    if [ -n "$socks" ]; then
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            --socks5-hostname "$socks" -o "$part" "$url" >/dev/null 2>&1 &
    else
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            -o "$part" "$url" >/dev/null 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        bytes=0
        [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"downloading",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
    done
    # Not `if ! wait`: inside that branch $? is the negation's status (always 0), which silently
    # ate every curl exit code the first time the tier-1 suite ran this.
    wait "$pid" && rc=0 || rc=$?
    bytes=0
    [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
    if [ "$rc" -eq 0 ] && [ "$bytes" -eq "$size" ]; then
        mv "$part" "$final"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson r "$have" \
            '{status:"downloaded",version:$v,bytes:$b,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        # The server sent a complete-but-wrong-sized body — not resumable, not trustworthy.
        rm -f "$part"
        control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download completed at $bytes bytes but the release publishes $size — the file was discarded; retry, and check for updates again if this repeats."
        return 0
    fi
    # rc 28 is curl's --max-time: the attempt window closed mid-transfer. The partial file is
    # kept either way — the next attempt resumes from it.
    if [ "$rc" -eq 28 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"partial",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "partial"
        return 0
    fi
    control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download failed over Tor at $bytes of $size bytes — nothing was installed; Retry resumes from where it stopped."
}

# os-verify: judge the fully-downloaded LOCAL file before anything touches a slot — signature,
# compatible, variant posture, version floor and downgrade, and the stamp-vs-tag match. A refused
# bundle is deleted; there is no override. Read-only otherwise: verifying changes nothing.
control_os_verify() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-verify" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "no fully downloaded update bundle is staged — download it first."
        return 0
    fi
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # rc 3 = rauc never ran, so no verdict was reached: the download stays staged for the
        # retry instead of being deleted on a broken tool.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "$reason"
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg va "$(os_bundle_variant "$bundle")" \
        '{status:"verified",version:$v,variant:$va,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "verified"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"verified",version:$v}')"
}

# os-install: write the verified local bundle into the inactive slot via the SAME `os_update`
# path the CLI takes (guards, floor raise, migration marker — one code path, two doors). Mining
# keeps running: RAUC writes the slot the machine is not using. On success the in-flight flag is
# persisted so the boot after the operator's explicit reboot can render an honest verdict.
control_os_install() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-install" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "no fully downloaded update bundle is staged — download and verify it first."
        return 0
    fi
    # Re-run the whole verify gate: a result can go stale between the verify click and this one,
    # and the install must never trust a judgment it did not just make itself.
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # Same keep rule as os-verify: only a real verdict deletes the staged download.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "$reason"
        return 0
    fi
    local running logf pid rc=0 pct
    running=$(os_running_version)
    logf="$osdir/.install.log"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"installing",version:$v,percent:0,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"installing",version:$v}')"
    # os_update -y in a subshell: error() exits the subshell, never this runner, and the -y only
    # waives a variant confirmation the gate above has already refused to reach. RAUC's progress
    # lines land in the log; the loop surfaces the latest percentage to the polling dashboard.
    (os_update "$bundle" -y </dev/null) >"$logf" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        pct=$(grep -oE '[0-9]+%' "$logf" 2>/dev/null | tail -1 | tr -d '%') || pct=""
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson p "${pct:-0}" \
            '{status:"installing",version:$v,percent:$p,ts:(now|floor)}')"
    done
    # Same wait shape as the download's: `if ! wait` would eat the subshell's exit code.
    wait "$pid" && rc=0 || rc=$?
    # Contention, not a failed install: os_update timed out waiting for another pithead operation
    # and exited before it reached rauc, so no slot was written. Falling through to the generic
    # branch below would report a FAILED install whose message asserts the running system is
    # untouched — true, and misleading, because nothing was attempted at all. Same shape and the
    # same reasoning as the firstboot wizard's contention branch (wizard_setup_failed). "rejected"
    # rather than "failed" matches this runner's own vocabulary for a request that never ran.
    if [ "$rc" -eq "$PITHEAD_EX_LOCK_TIMEOUT" ]; then
        warn "OS install could not start: another pithead operation still held the machine."
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "another pithead operation was already running, so the install was not started — nothing was changed. Try again once it has finished."
        rm -f "$logf"
        os_state_write "$cdir" '{"step":"idle"}'
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        # The raw install log is a host detail (staging paths, slot devices) and stays host-side:
        # the full tail goes to the journal, and the container-visible result carries only the
        # final error line whitelist-extracted from the log — rauc's own last word, or nothing.
        local detail
        detail=$(grep -aE '^LastError: |^\[ERROR\] |[Ff]ailed' "$logf" 2>/dev/null |
            grep -av 'pithead aborted unexpectedly' |
            tail -1 | tr -d '[:cntrl:]' | head -c 300) || detail=""
        warn "OS install failed (rc=$rc); log tail: $(tail -c 500 "$logf" 2>/dev/null | tr -d '[:cntrl:]')"
        control_os_refuse "$cdir" "$id" "$actor" "os-install" failed "the install did not complete — the running system is untouched and mining continues.${detail:+ $detail} The full install log is in the host journal."
        rm -f "$logf"
        # #1050: a terminal-failure transition. Without this the persisted step stayed
        # "installing" forever — nothing ever moved it off that value on a failed install — so
        # the dashboard kept showing an install in progress that had already ended and would
        # never finish or fail again. idle matches the state a fresh appliance starts in: Check
        # and Download are offered again on the next open.
        os_state_write "$cdir" '{"step":"idle"}'
        return 0
    fi
    local bundle_version
    bundle_version="${tag#v}"
    jq -n --arg f "$running" --arg t "$bundle_version" '{from:$f,to:$t,ts:(now|floor)}' \
        >"$(os_update_inflight_file)"
    # The staged bundle did its job — free the space before the reboot the operator will order.
    rm -f "$bundle" "$(os_update_target_file)" "$logf"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg f "$running" \
        '{status:"installed",version:$v,from:$f,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "installed"
    os_state_write "$cdir" "$(jq -n --arg v "$bundle_version" --arg f "$running" \
        '{step:"reboot-pending",version:$v,from:$f}')"
}

# os-reboot: the ONLY verb that interrupts mining, in its own allowlisted intent so rebooting the
# machine never rides implicitly on any other action. Refused unless an installed update is
# actually waiting — the dashboard must never be a general reboot lever.
control_os_reboot() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-reboot" || return 0
    if [ ! -f "$(os_update_inflight_file)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "no installed update is waiting for a reboot — nothing to finish."
        return 0
    fi
    # The install result authorizes the reboot for 24 hours, then goes stale. The gate proves
    # "an installed update is waiting", never "the operator asked just now" — within the window
    # a spool writer can still time the reboot, so the TTL bounds how long that lever stays
    # armed rather than pretending it does not exist. An unreadable timestamp is not proof of
    # freshness and refuses too; a fresh verify and install re-arms it.
    local armed_ts
    armed_ts=$(jq -r '.ts // 0' "$(os_update_inflight_file)" 2>/dev/null) || armed_ts=0
    printf '%s' "$armed_ts" | grep -qE '^[0-9]+$' || armed_ts=0
    if [ "$armed_ts" -le 0 ] || [ $(($(date +%s) - armed_ts)) -gt 86400 ]; then
        # #1050: the re-arm transition the comment above always promised but never performed.
        # The flag alone used to survive this refusal, so the persisted step stayed
        # "reboot-pending" forever — the dashboard kept offering only "Reboot now", which kept
        # refusing, with no button that ever led back to Check/Download. Clearing the expired
        # flag and the step together is what actually re-arms it: the next open finds an
        # ordinary idle appliance, exactly as the message already claimed.
        rm -f "$(os_update_inflight_file)"
        os_state_write "$cdir" '{"step":"idle"}'
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "the installed update has been waiting more than a day and has expired — check for updates again; a fresh verify and install re-arms the reboot."
        return 0
    fi
    # The result must land BEFORE the reboot order or the page never learns the reboot is real.
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rebooting",ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-reboot" "rebooting"
    systemctl reboot 2>/dev/null || true
}

control_process_request() { # <claimed-file> <control-dir>
    local file="$1" cdir="$2" id action actor size
    # Refuse a symlinked / non-regular claimed file (graft #437): a symlink dropped in requests/
    # could point the root runner at any host file. Skip + audit, never follow it.
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        warn "Control request is a symlink or not a regular file — refused."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-nonregular"
        return 0
    fi
    # Bound the root-runner DoS (#33 hardening): reject an oversized intent BEFORE jq parses it. A
    # real config.json is a few KB; 64 KB is generous headroom for the full schema plus edits.
    size=$(wc -c <"$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 65536 ]; then
        warn "Control request exceeds 64 KB ($size bytes) — refused before parsing."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-oversize"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        warn "Control request is not valid JSON — discarded."
        return 0
    fi
    id=$(jq -r '.id // ""' "$file")
    # Strict canonical uuid4 (version nibble 4, variant nibble 8/9/a/b) — the id becomes a result/
    # staged FILENAME, so pin it hard (defense-in-depth, from #438). submit() mints str(uuid4()).
    if ! printf '%s' "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        warn "Control request has a malformed id — discarded (no result can be addressed)."
        return 0
    fi
    if [ "$(jq -r '[keys[] | select(. != "id" and . != "action" and . != "config" and . != "actor" and . != "version" and . != "worker" and . != "changes" and . != "confirm")] | length' "$file")" != "0" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unexpected keys in request",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "" "invalid" "rejected"
        return 0
    fi
    actor=$(jq -r '.actor // ""' "$file")
    # The actor rides into the audit log; it originates from Caddy's X-Auth-User but the container
    # writes the file, so re-validate it against the basic_auth username charset.
    printf '%s' "$actor" | grep -qE '^[A-Za-z0-9._@-]{0,64}$' || actor="untrusted"
    action=$(jq -r '.action // ""' "$file")
    case "$action" in
    preview) control_preview "$file" "$id" "$actor" "$cdir" ;;
    commit) control_commit "$id" "$actor" "$cdir" "$(jq -r '.confirm // ""' "$file")" ;;
    upgrade) control_upgrade "$file" "$id" "$actor" "$cdir" ;;
    worker-apply) control_worker_apply "$file" "$id" "$actor" "$cdir" ;;
    worker-upgrade) control_worker_upgrade "$file" "$id" "$actor" "$cdir" ;;
    restart | apply) control_lifecycle "$action" "$id" "$actor" "$cdir" ;;
    backup) control_backup "$id" "$actor" "$cdir" ;;
    # Appliance OS update, one verb per step so every network move stays separate from every
    # destructive one; each refuses outright off the appliance.
    os-check) control_os_check "$file" "$id" "$actor" "$cdir" ;;
    os-download) control_os_download "$file" "$id" "$actor" "$cdir" ;;
    os-verify) control_os_verify "$file" "$id" "$actor" "$cdir" ;;
    os-install) control_os_install "$file" "$id" "$actor" "$cdir" ;;
    os-reboot) control_os_reboot "$file" "$id" "$actor" "$cdir" ;;
    *)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unknown action",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "${action:-none}" "rejected"
        ;;
    esac
}

# `control-run-pending`: drain the request spool, oldest first. Each request is CLAIMED (moved out
# of requests/) before a byte of it is parsed, so the container can never mutate or replay a
# request the runner is working on. Fired by the pithead-control systemd path unit.
control_run_pending() {
    [ "$(env_get DASHBOARD_CONTROL_ENABLED)" == "true" ] ||
        error "The dashboard control channel is not enabled (dashboard.control.enabled)."
    local cdir
    cdir=$(env_get CONTROL_DIR)
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/staged" "$cdir/results" "$cdir/audit"
    # Freshen the pre-masked prefill copy (#440) before draining: hand-edits to config.json since
    # the last apply show up in the editor form. A commit re-renders it again via its `apply -y`.
    render_masked_config "$cdir"
    # Time-bounded DoS sweep (#33 hardening): drop staged/ copies and stray requests/ files older
    # than an hour that no commit ever claimed, so a burst that is never committed cannot pile up
    # (staged intents already expire per-commit at 10 min; this bounds accumulation regardless).
    find "$cdir/staged" "$cdir/requests" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true
    # Orphaned claims (#548): a claimed request whose handler died before the loop's own `rm -f
    # "$claim"` below (an errexit gap, e.g.) leaves a `.claim.<pid>` file sitting directly in
    # $cdir forever. Same age cutoff — a claim in flight never lives past a single drain.
    find "$cdir" -maxdepth 1 -type f -name '.claim.*' -mmin +60 -delete 2>/dev/null || true
    # Stale backup-kit passphrases: control_backup's one-time kit self-redacts after a blocking
    # TTL, but a runner killed mid-sleep (a reboot racing the window) would leave a wallet-grade
    # passphrase in results/ in plaintext on /data indefinitely. This backstop — a fresh runner
    # after that reboot runs it — nulls the passphrase in any kit older than the TTL that still
    # carries one. Belt to the TTL's braces; the passphrase is only ever meant for the live window.
    control_redact_stale_kits "$cdir/results"
    local names name req claim n=0
    # Per-run cap (#33 hardening): a single trigger drains at most this many intents, so a flood in
    # the spool can't hold the root runner for an unbounded stretch — the leftovers wait for the
    # next path-unit fire.
    local max=50
    # Per-drain worker-apply DIAL budget (#185 hardening): worker-apply is the only action that blocks
    # the runner on a network round-trip, so cap how many dial per drain (the rest reject with a retry
    # hint). control_worker_apply reads + decrements this in the same shell.
    CONTROL_WA_BUDGET=5
    # Worker-upgrade budget (#597): an upgrade blocks the runner on a rig build (minutes), so
    # exactly one runs per drain; the rest reject with a retry hint.
    CONTROL_WU_BUDGET=1
    # OS-update budget: a bundle download attempt or a slot install holds the runner for minutes
    # too, so exactly one os-* verb runs per drain; the rest reject with a retry hint.
    CONTROL_OS_BUDGET=1
    names=$(cd "$cdir/requests" 2>/dev/null && ls -1tr -- *.json 2>/dev/null) || true
    if [ -z "$names" ]; then
        log "No pending control requests."
        return 0
    fi
    while IFS= read -r name; do
        if [ "$n" -ge "$max" ]; then
            warn "Reached the $max-request per-run cap — remaining intents wait for the next run."
            break
        fi
        req="$cdir/requests/$name"
        [ -f "$req" ] || continue
        claim="$cdir/.claim.$$"
        mv "$req" "$claim" 2>/dev/null || continue
        control_process_request "$claim" "$cdir"
        rm -f "$claim"
        n=$((n + 1))
    done <<<"$names"
    log "Processed $n control request(s)."
}

# The directory the dashboard control units live in — ONE rule, shared by the writer and both
# readers. The appliance's root is read-only by design, so /etc/systemd/system cannot take the unit
# (#791); /run/systemd/system is a first-class unit path, writable, and cleared every boot, which is
# fine because these units are derived and the boot path re-renders them. A DIY host keeps /etc.
# This was two rules until #1151: `provision_control_runner` knew about /run and `doctor` did not,
# so on a PROVISIONED appliance doctor reported "no runner units are installed" about units that
# were installed and running. That is the half of the boot health gate that never passed, so the
# slot never committed — and after #1065 the box reboots a healthy, correctly-updated appliance.
control_unit_dir() {
    if [ -n "${PITHEAD_UNIT_DIR:-}" ]; then
        printf '%s' "$PITHEAD_UNIT_DIR"
    elif is_appliance; then
        printf '%s' /run/systemd/system
    else
        printf '%s' /etc/systemd/system
    fi
}

# Physical directory the installed control units name, or "" when there is no service unit or its
# ExecStart is unparseable. One checkout has two spellings — the `current` symlink and the versioned
# dir it points at (production units carry the versioned spelling) — so this resolves to a PHYSICAL
# path; comparing the literal string would call our own unit foreign. A stranded unit usually names
# a directory that no longer exists, so resolve the deepest existing ancestor and keep the rest
# verbatim: the caller still gets a comparable, printable path instead of an empty answer.
control_units_owner_dir() {
    local unit_dir owner_dir dir tail
    unit_dir=$(control_unit_dir)
    owner_dir=$(sed -n 's|^ExecStart=\(/.*\)/pithead control-run-pending$|\1|p' \
        "$unit_dir/pithead-control.service" 2>/dev/null | head -n 1)
    [ -n "$owner_dir" ] || return 0
    dir="$owner_dir" tail=""
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        tail="/$(basename "$dir")$tail"
        dir=$(dirname "$dir")
    done
    printf '%s' "$(cd "$dir" 2>/dev/null && pwd -P)$tail"
}

# Install (or remove) the systemd trigger for the runner (#33): a path unit that fires
# `pithead control-run-pending` whenever a request file lands in the spool. Root, because `apply`
# needs iptables/chown; the service is a FIXED ExecStart with no parameter from the container, so
# a compromised dashboard cannot steer it into anything but the two known verbs. No-op on hosts
# without systemd (macOS/dev checkouts run the runner by hand).
provision_control_runner() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit_dir
    unit_dir=$(control_unit_dir)
    # Enablement must be --runtime wherever the units are runtime units: on the appliance's
    # read-only root, systemd cannot write the /etc symlink a persistent enable needs.
    local -a enable_args=(enable --now)
    case "$unit_dir" in /run/*) enable_args=(enable --runtime --now) ;; esac
    if [ "${DASHBOARD_CONTROL_ENABLED:-false}" != "true" ]; then
        if [ -e "$unit_dir/pithead-control.path" ] || [ -e "$unit_dir/pithead-control.service" ]; then
            # The unit names are box-global but a box can hold several checkouts (release bench:
            # live stack + e2e harness + bundle-smoke tmp dirs). Only remove units whose ExecStart
            # points at THIS checkout — deleting a sibling's runner strands its dashboard control
            # requests unprocessed (the editor hangs at "Previewing…" until that stack's next
            # apply/upgrade reinstalls the units).
            # Ownership compares PHYSICAL paths: one checkout has two spellings — the `current`
            # symlink and the versioned dir it points at (production units carry the versioned
            # spelling). A literal $PWD compare would call our own unit foreign and never remove
            # it. If the unit's dir is gone, resolve the deepest existing ancestor and keep the
            # rest verbatim; an unparseable ExecStart is foreign (fail safe, leave it alone).
            if [ -e "$unit_dir/pithead-control.service" ]; then
                local owner_dir
                owner_dir=$(control_units_owner_dir)
                if [ -z "$owner_dir" ] || [ "$owner_dir" != "$(pwd -P)" ]; then
                    log "Leaving the dashboard control runner units alone — they belong to another checkout."
                    return 0
                fi
            fi
            log "Removing the dashboard control runner units..."
            sudo systemctl disable --now pithead-control.path >/dev/null 2>&1 || true
            sudo rm -f "$unit_dir/pithead-control.path" "$unit_dir/pithead-control.service"
            sudo systemctl daemon-reload
        fi
        return 0
    fi
    # Already installed for this checkout — keep the routine apply sudo-free. (-F: both paths
    # are literals — versioned dirs carry dots (pithead-v1.9.3), and the glob star must not
    # read as a regex repeat.)
    if grep -qsF "PathExistsGlob=$CONTROL_DIR/requests/*.json" "$unit_dir/pithead-control.path" &&
        grep -qsF "ExecStart=$PWD/pithead control-run-pending" "$unit_dir/pithead-control.service"; then
        return 0
    fi
    # The grep above is an idempotence skip, not an ownership check. The removal branch got its
    # ownership guard when a disable-apply deleted the live stack's units; the install branch had
    # none, so any sibling checkout's apply/up (e2e harness, bundle-smoke tmp dir, disposable
    # install) silently repointed the box-global units at itself — the exact mechanism behind the
    # production control-channel stranding. A unit naming a DIFFERENT install that still exists on
    # disk is someone's live runner: refuse. A unit whose directory is gone is adoptable (the
    # failed-upgrade repair), our own unit converges (the post-restore proof depends on it), and an
    # unparseable ExecStart is left alone, fail-safe, like the removal branch. Deliberate takeover
    # has two spellings: the upgrade callsite passes the `steal` argument (after a successful
    # upgrade the units MUST repoint here — the old versioned dir still exists as the rollback, so
    # without the escape every one-click upgrade would refuse and strand the control channel), and
    # PITHEAD_STEAL_CONTROL_UNITS=1 is the operator's escape (manual migration, repair).
    if [ -e "$unit_dir/pithead-control.service" ] && [ "${1:-}" != "steal" ] &&
        [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != "1" ]; then
        local install_owner
        install_owner=$(control_units_owner_dir)
        if [ -z "$install_owner" ]; then
            warn "Not installing the dashboard control runner: $unit_dir/pithead-control.service exists but its ExecStart is not one this tool wrote. Inspect it, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to overwrite it; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
        if [ "$install_owner" != "$(pwd -P)" ] && [ -d "$install_owner" ]; then
            warn "Not installing the dashboard control runner: the box-global units belong to the install at $install_owner. Run this from that checkout, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to take the units over; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
    fi
    log "Installing the dashboard control runner (systemd path unit)..."
    sudo tee "$unit_dir/pithead-control.service" >/dev/null <<EOF
[Unit]
Description=pithead dashboard control runner (#33)

[Service]
Type=oneshot
User=root
WorkingDirectory=$PWD
ExecStart=$PWD/pithead control-run-pending
EOF
    sudo tee "$unit_dir/pithead-control.path" >/dev/null <<EOF
[Unit]
Description=Watch the pithead control spool for dashboard requests (#33)

[Path]
PathExistsGlob=$CONTROL_DIR/requests/*.json

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl "${enable_args[@]}" pithead-control.path >/dev/null 2>&1 ||
        warn "Could not enable pithead-control.path — dashboard config changes will not be applied until it is enabled."
}

# --- Main Execution ---

# #493: a subcommand's -h/--help must print usage and exit 0 BEFORE any side effect, and a
# subcommand that takes no options must reject an unrecognized flag instead of silently ignoring it
# and running anyway. `pithead upgrade --help` used to run a full upgrade (image pull + container
# recreation) — on the v1.4.0 deploy that recreation collided with the real upgrade and corrupted
# the dashboard DB (#489). A --help must never mutate the host.
_help_requested() { # "$@" — return 0 if any argument is -h/--help
    local a
    for a in "$@"; do
        case "$a" in
        -h | --help) return 0 ;;
        esac
    done
    return 1
}
_reject_options() { # <verb> "$@" — this verb takes no options; error on any leftover argument
    local verb="$1"
    shift
    [ "$#" -eq 0 ] || error "Unknown option for $verb: '$1'. This command takes no options. Run '$0 $verb -h' or '$0 help'."
}

main() {
    # Chained subcommands (#94): when every argument is a bare subcommand name, run them
    # left-to-right as a chain. Any other token (a flag, a service name, an archive path) keeps
    # the invocation on the single-command path below, unchanged.
    if [ "$#" -ge 2 ]; then
        local _tok _chain=1
        for _tok in "$@"; do
            if ! is_pithead_command "$_tok"; then
                _chain=0
                break
            fi
        done
        if [ "$_chain" -eq 1 ]; then
            run_chain "$@"
            return 0
        fi
    fi

    local cmd="${1:-}"
    if [ -n "$cmd" ]; then shift; fi

    # #493: -h/--help on any subcommand prints help and exits 0 before ANY side effect. `logs` is the
    # one deliberate passthrough (its args go to `docker compose logs`), so it opts out and forwards
    # -h/--help downstream. The bare `pithead -h/--help/help` is its own command in the case below.
    case "$cmd" in
    "" | help | -h | --help | logs) ;;
    *) if _help_requested "$@"; then
        show_help
        exit 0
    fi ;;
    esac

    # Make the stack version + build provenance available to any `docker compose [up] build` this
    # invocation runs, so the dashboard image bakes in its version badge (Issue #58).
    export_build_provenance

    case "$cmd" in
    "")
        # No command: first-time users get setup, deployed users get help.
        if is_deployed; then show_help; else setup; fi
        ;;
    setup)
        for arg in "$@"; do
            case "$arg" in
            --skip-optimize) SKIP_OPTIMIZE=1 ;;
            --skip-deps) SKIP_DEPS=1 ;;
            *) error "Unknown option for setup: $arg. Run '$0 help'." ;;
            esac
        done
        setup
        ;;
    apply) apply "$@" ;;
    render)
        _reject_options render "$@"
        render_derived
        ;;
    up)
        _reject_options up "$@"
        require_deployed
        stack_up
        ;;
    down)
        _reject_options down "$@"
        require_env
        stack_down
        ;;
    restart)
        require_deployed
        stack_restart "$@"
        ;;
    upgrade)
        _reject_options upgrade "$@"
        require_deployed
        stack_upgrade
        ;;
    logs)
        require_env
        log "Following logs (Ctrl+C to exit)..."
        docker compose logs -f "$@"
        ;;
    status)
        _reject_options status "$@"
        require_env
        stack_status || exit 1
        ;;
    doctor)
        case "${1:-}" in
        "") doctor || exit 1 ;;
        --json)
            [ "$#" -eq 1 ] || error "doctor --json takes no further options. Run '$0 help'."
            doctor_json || exit 1
            ;;
        *) error "Unknown option for doctor: '$1'. Run '$0 help'." ;;
        esac
        ;;
    support-bundle) stack_support_bundle "$@" ;;
    reset-dashboard)
        require_deployed
        reset_dashboard "$@"
        ;;
    config-reset) config_reset "$@" ;;
    factory-reset) factory_reset "$@" ;;
    backup) stack_backup "$@" ;;
    restore) stack_restore "$@" ;;
    uninstall) stack_uninstall "$@" ;;
    firstboot-wizard) firstboot_wizard "$@" ;;
    load-images)
        _reject_options load-images "$@"
        load_baked_images
        ;;
    local-miner)
        _reject_options local-miner "$@"
        # A rig has no .env and never will — there is no stack on it to render one.
        [ "$(machine_role)" = "rig" ] || require_env
        provision_local_miner
        ;;
    os-update) os_update "$@" ;;
    control-run-pending)
        _reject_options control-run-pending "$@"
        require_deployed
        control_run_pending
        ;;
    onion-client-key)
        _reject_options onion-client-key "$@"
        onion_client_key
        ;;
    rotate-dashboard-onion) rotate_dashboard_onion "$@" ;;
    rotate-secrets) rotate_secrets "$@" ;;
    render-quadlet)
        rq_env=".env" rq_out="./quadlet"
        while [ $# -gt 0 ]; do
            case "$1" in
            --env)
                [ -n "${2:-}" ] || error "render-quadlet: --env needs a file argument."
                rq_env="$2"
                shift 2
                ;;
            --out)
                [ -n "${2:-}" ] || error "render-quadlet: --out needs a directory argument."
                rq_out="$2"
                shift 2
                ;;
            *) error "Unknown option for render-quadlet: $1. Run '$0 help'." ;;
            esac
        done
        render_quadlet_units "$rq_env" "$rq_out"
        ;;
    version | -V | --version) show_version ;;
    help | -h | --help) show_help ;;
    *) error "Unknown command: $cmd. Run '$0 help'." ;;
    esac
}

if [ "$_STACK_SOURCED" = "0" ]; then
    main "$@"
fi
