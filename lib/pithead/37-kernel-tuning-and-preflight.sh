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
    [ "$TARI_MODE" != "local" ] && pre_tari_dir=""
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
