# `uninstall` (#77 phase 1): the clean exit for the DIY channel — stop and remove what pithead
# created on this host, keep what the operator owns. Kept: config.json, the data dirs (chains,
# Tor onion keys, dashboard DB), backups/. Removed: containers, the stack's images, the rendered
# .env and Caddyfile, this checkout's control-runner units, the egress firewall rules. The
# appliance has no uninstall — its equivalents are the reset tiers.
stack_uninstall() {
    local yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) yes=1 ;;
        *) error "Unknown option for uninstall: $arg. Run '$0 help'." ;;
        esac
    done
    [ -f .env ] || error "No .env here — nothing deployed to uninstall. A never-deployed checkout is just a directory: remove it."
    detect_os
    # The keep-list is read from .env BEFORE it is removed.
    local data_dirs
    data_dirs=$(grep -E '^(MONERO|TARI|P2POOL|DASHBOARD|TOR)_DATA_DIR=' .env | cut -d= -f2- | sort -u | tr '\n' ' ')
    warn "DESTRUCTIVE: stops the stack, removes its containers and images, and deletes the rendered .env and Caddyfile."
    log "Kept (yours): config.json, backups/, and the data dirs: ${data_dirs:-none recorded}"
    if [ "$yes" -ne 1 ]; then
        printf "Type 'uninstall' to continue: "
        read -r arg
        [ "$arg" == "uninstall" ] || {
            log "Aborted — nothing changed."
            return 1
        }
    fi
    remove_tor_egress_firewall 2>/dev/null || true
    docker compose down --remove-orphans 2>/dev/null ||
        warn "compose down failed (engine not running?) — continuing with cleanup."
    # Exact image refs from the compose config; failures (image shared/in use) are non-fatal.
    docker compose config --images 2>/dev/null | sort -u | while read -r img; do
        [ -n "$img" ] && docker rmi "$img" >/dev/null 2>&1 || true
    done
    # Removes only THIS checkout's pithead-control units (the ownership check inside).
    DASHBOARD_CONTROL_ENABLED=false provision_control_runner 2>/dev/null || true
    rm -f .env Caddyfile
    log "Uninstalled. Still on disk: config.json, backups/, data dirs (${data_dirs:-none}) — remove them yourself for a full wipe."
    log "Kernel HugePages/GRUB tuning from setup persists; revert in GRUB config if you want it gone."
}

# --- First-boot wizard (#77 phase 3) -------------------------------------------------------------
# The browser-first setup path for BOTH channels: a token-gated form (the dashboard image in
# wizard mode) collects the CLI wizard's answers pre-sync; THIS host validates and applies them.
# Container asks, host provisions — the #33 trust shape. Plain HTTP on the trusted LAN with
# secret minimization: addresses and shape choices only (docs/dev/dual-distribution-plan.md § 3).

# Human-typable one-time token: 6 chars from an unambiguous alphabet (no 0/O/1/I/l).
wizard_mint_token() {
    local alphabet="23456789ABCDEFGHJKMNPQRSTUVWXYZ" out="" i idx
    for i in 1 2 3 4 5 6; do
        idx=$(($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % ${#alphabet}))
        out="$out${alphabet:$idx:1}"
    done
    printf 'pit-%s' "$out"
}

# Consume one wizard submission: validate the candidate with the same parser setup/apply use; on
# success install it as ./config.json and mark the spool applied (the wizard page polls for it).
# On failure surface a short error into the spool for the form. rc: 0 applied, 1 rejected, 2 none.
firstboot_consume_spool() { # <spool-dir>
    local spool="$1" cand="$1/config.json" err
    [ -f "$cand" ] || return 2
    # CONFIG_FILE is readonly after sourcing; validate the candidate in a fresh process via the
    # PITHEAD_CONFIG_FILE override (the same parser setup/apply run, against the same file).
    if err=$(PITHEAD_CONFIG_FILE="$cand" bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        cp "$cand" "$PWD/config.json"
        rm -f "$cand"
        touch "$spool/applied"
        return 0
    fi
    printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 >"$spool/error.txt"
    rm -f "$cand"
    return 1
}

# --- the machine role (one stick, three machines) -------------------------------------------
# What a machine IS is the wizard's first question: a Pithead coordinator, a coordinator that
# also mines (Both), or a RigForge rig. config.json states the coordinator roles exactly — Both
# IS local_miner.enabled — so the marker is derived from it there. The rig role has no
# config.json at all, which is why the marker, with rig.json beside it, exists: the boot path
# reads machine-role to know which leg to start. Absent marker = pithead (every machine
# provisioned before this contract).

record_machine_role() { # <pithead|both|rig>
    printf '%s\n' "$1" >"$PWD/machine-role" 2>/dev/null || true
}

# The wizard's response to a failed (setup), as one step so it can be driven directly (#1059).
#
# It KEEPS the machine's configuration. A non-zero (setup) says something went wrong, never that
# the submitted config is what went wrong — the capture that found this was a concurrent `backup`
# calling stack_down out from under setup's in-flight `compose up`, on a config valid enough to
# have rendered .env, provisioned Tor and started containers.
#
# This used to MOVE the file, to re-arm the setup wizard. It cannot, on any path that reaches it:
# pithead-firstboot.service ANDs !config.json with !machine-role, and record_machine_role above
# has already run, so the second condition holds the window shut whatever this does with the
# first. Keeping the file also keeps the next boot working — pithead-boot.service's conditions
# are ORed so it runs regardless, and os/overlay/pithead-boot's `./pithead render` reads exactly
# the file the move used to take away.
#
# The removal therefore happens only where it can still buy something: a machine-role that never
# landed (record_machine_role is best-effort). It lives INSIDE the success branch on purpose —
# the defect this replaced was `mv ... 2>/dev/null || rm -f config.json`, which deleted the
# operator's configuration outright whenever the mv failed, for a reason it had already
# discarded. Structurally, nothing here can remove the file without a copy already on disk.
#
# install -m 600, not cp: config.json holds the dashboard password and the wallet address, and
# the copy must not widen its mode.
#
# rc 0 = a copy was kept, 1 = it could not be.
wizard_keep_failed_config() {
    if install -m 600 "$PWD/config.json" "$PWD/config.json.failed" 2>/dev/null; then
        [ -f "$PWD/machine-role" ] || rm -f "$PWD/config.json"
        return 0
    fi
    warn "Could not keep a copy of the failed configuration as config.json.failed."
    return 1
}

# CONTENTION IS NOT A BAD CONFIG — the wizard's half of #1342's routing, and it was missing.
#
# os/overlay/pithead-boot has the boot leg's half (fail_boot_contended): a lock timeout there is
# contention, not a bad A/B slot, so the fallback is not spent. `setup` runs inside a mutating
# window too, and can lose exactly the same race — but every non-zero (setup) was routed as a
# provisioning failure, which tells the operator their configuration is wrong and asks them to
# correct it. On a first boot there is no shell to contradict it with.
#
# Worse than misleading. That path calls wizard_keep_failed_config, which removes config.json
# whenever the machine-role marker never landed — and record_machine_role is best-effort
# (`printf ... || true`). So contention could take a VALID configuration away from the operator
# and then blame them for it: #1059's own shape, on the one leg #1059's fix did not route.
#
# Kept as a function rather than inline at the call site, for the reason boot_up_failed gives on
# the other leg: the two halves of one decision drift apart when they are written twice.
#
# rc 0 = a config.json.failed copy was kept (so the reopened page prefills from it), 1 = not.
# Contention deliberately returns 1 WITHOUT calling wizard_keep_failed_config: nothing is copied,
# nothing is removed, and the live config.json the operator submitted is what prefills the retry.
wizard_setup_failed() { # <exit status of setup>
    if [ "$1" = "$PITHEAD_EX_LOCK_TIMEOUT" ]; then
        warn "Another pithead operation still held the machine, and provisioning timed out waiting for it."
        warn "That is contention, NOT a problem with the configuration you submitted — it is kept exactly as it is."
        warn "Reopening the setup window so it can be resubmitted once the other operation has finished."
        return 1
    fi
    warn "Provisioning failed. A copy of the submitted configuration is kept as config.json.failed;"
    warn "reopening the setup window so it can be corrected."
    wizard_keep_failed_config
}

# The marker, read back. Anything unrecognised (or absent) is a coordinator: every machine
# provisioned before this contract existed had no marker and was one.
machine_role() { # echoes pithead|both|rig
    local r=""
    if [ -f "$PWD/machine-role" ]; then
        r=$(tr -d '[:space:]' <"$PWD/machine-role" 2>/dev/null) || r=""
    fi
    case "$r" in rig | both | pithead) printf '%s' "$r" ;; *) printf 'pithead' ;; esac
}

machine_role_from_config() { # <config-file>
    if [ "$(jq -r '.local_miner.enabled // false' "$1" 2>/dev/null)" = "true" ]; then
        printf 'both'
    else
        printf 'pithead'
    fi
}

# The rig role's pool pre-fill: a Pithead on the LAN answers pithead.local:3333. The HOST
# dials — the container never touches the network — and publishes the finding to the spool the
# way the disk inventory travels. Fail open: no answer publishes only this machine's name, and
# the pool field opens empty. PITHEAD_RIG_PROBE overrides the target for tests.
publish_rig_defaults() { # <spool-dir>
    local probe="${PITHEAD_RIG_PROBE:-pithead.local:3333}" tmp="$1/.rig-defaults.json.$$" pool=""
    if timeout 3 bash -c "</dev/tcp/${probe%:*}/${probe##*:}" 2>/dev/null; then
        pool="$probe"
    fi
    jq -n --arg pool "$pool" --arg worker "$(hostname)" \
        '{worker: $worker} + (if $pool == "" then {} else {pool: $pool} end)' >"$tmp" 2>/dev/null || : >"$tmp"
    chown 1000:1000 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$1/rig-defaults.json"
}

# Consume one rig-role submission: shape-check the pool address, dial it BEFORE anything
# irreversible — the same validate-before-erase discipline the coordinator flow gets — and
# land the accepted answers as $PWD/rig.json, host-side and outside the spool (the same trust
# move firstboot_consume_spool makes: what got validated is what gets used, whatever the
# container writes afterwards). rc: 0 accepted, 1 rejected, 2 none.
firstboot_consume_rig() { # <spool-dir>
    local spool="$1" req="$1/rig-request.json" pool worker host port
    [ -f "$req" ] || return 2
    pool=$(jq -r '.pool // ""' "$req" 2>/dev/null | tr -d '[:cntrl:]')
    worker=$(jq -r '.worker // ""' "$req" 2>/dev/null | tr -d '[:cntrl:]')
    host="${pool%:*}"
    port="${pool##*:}"
    if [ -z "$host" ] || [ "$host" = "$pool" ] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
        printf 'the pool address must look like host:port — a Pithead answers on port 3333' >"$spool/error.txt"
        rm -f "$req"
        return 1
    fi
    if ! timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        printf 'cannot reach a pool at %s:%s — check the address, and that the Pithead is up' "$host" "$port" >"$spool/error.txt"
        rm -f "$req"
        return 1
    fi
    if ! jq --arg w "${worker:-$(hostname)}" '{pool: .pool, worker: $w}
        + (if (.stratum_password // "") == "" then {} else {stratum_password: .stratum_password} end)' \
        "$req" >"$PWD/rig.json" 2>/dev/null; then
        rm -f "$req" "$PWD/rig.json"
        printf 'could not record the rig settings — submit again' >"$spool/error.txt"
        return 1
    fi
    chmod 600 "$PWD/rig.json" 2>/dev/null || true
    rm -f "$req"
    return 0
}
