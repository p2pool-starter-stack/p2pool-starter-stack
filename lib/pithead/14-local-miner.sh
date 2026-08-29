# --- local miner on the appliance (#796) ----------------------------------------------------
# The appliance honours "Mine on this machine too?" itself: the image bakes a pinned RigForge
# tree (plus a prebuilt XMRig), pithead-sync delivers it to /data/rigforge, render below writes
# its config, and the boot path runs its setup in appliance mode after the stack is up. On DIY,
# none of this fires — the operator installs RigForge by hand (announce_local_miner's values).

rigforge_dir() { printf '%s' "${PITHEAD_RIGFORGE_DIR:-/data/rigforge}"; }

# RigForge's config.json is a DERIVED file on the appliance — a pure function of pithead's
# config.json + .env + the boot-time sizing decision, rebuilt on every render like the
# Caddyfile. It carries the three values the miner needs: the stack's own stratum over
# loopback, the stratum password when one is set, and the stack's ACTUAL reservation as
# hugepages_reserve_extra_mb — the hand-off that makes RigForge the pool's single writer. Its
# grow-only sysctl sizes the whole pool (miner need + this headroom); pithead's own write
# never grows past the same decision (optimize_kernel). Declaring the budget beats maxing the
# two reservations: both sides hold pages at the same time, so only the sum survives one side
# growing into its own reservation.
#
# BE PRECISE ABOUT WHAT THIS NUMBER IS: it is the STACK's share, not a ceiling on the pool.
# RigForge adds it to its own requirement, so the pool it writes is miner-need + this value —
# larger than the sizing decision by construction, and intentionally so on the supported 16 GB
# machine, which is the case #305 co-location was measured on. On the REDUCED tier that is a
# real over-reservation, because the tier's 2560 pages were sized for the stack's two RandomX
# datasets alone with no co-resident miner in the budget. No value here fixes that: RigForge's
# grow-only write counts the stack's already-held pages as unavailable while this headroom is
# already inside its requirement, so the co-resident's pages are counted twice and no declared
# number bounds the result. Whether a degraded box should co-locate a miner at all is a product
# decision, tracked in #1103 — out of scope for the sizing fix here, which is what stopped the
# constant 6144 from re-inflating a pool the boot had just shrunk.
#
# The headroom follows hugepages_decision_pages, NOT the
# baked constant (#977): on a degraded box a constant 6144 had RigForge's sysctl re-inflate
# the shrunk pool every boot — and not the live HugePages_Total either, because a mid-run
# `apply` re-renders after RigForge has already grown the pool, and handing the grown pool
# back as headroom would ratchet it up on every apply. Healthy hardware has no marker, so the
# declared value is the same 6144 MB it has always been.

# #1103's product decision: on the REDUCED tier, do not co-locate the built-in miner at all.
# The tier's 2560 pages were budgeted for the stack's own two RandomX datasets alone, with no
# co-resident miner in the sum, and no headroom value declared here can fix that — RigForge's
# grow-only pool write counts the stack's already-held pages as unavailable while this same
# headroom sits inside its own requirement, so the co-resident's pages are counted twice and the
# result is unbounded (see the comment above render_local_miner_config for the arithmetic). The
# RELEASED tier (0 pages) is not affected: it declares zero headroom, so there is nothing left to
# double-count, and the full tier is the measured, supported case this was never wrong for.
# Blocking co-location is therefore scoped to exactly the tier where the double-count is real —
# never the two tiers either side of it, so a normal 16 GB box keeps its full reservation and a
# released box keeps mining solo exactly as it does today.
local_miner_hugepages_blocked() {
    local pages
    pages=$(hugepages_decision_pages)
    [ "$pages" -gt 0 ] && [ "$pages" -lt "$PITHEAD_HUGEPAGES" ]
}

render_local_miner_config() {
    is_appliance || return 0
    # Not on a rig, ever. This function's "switched off" branch DELETES the miner's config, and
    # a rig with no config.json reads as switched off — so a stray render there would take out
    # the very file the rig mines from. render_rig_miner_config owns that machine's copy.
    if [ "$(machine_role)" = "rig" ]; then return 0; fi
    local dir
    dir=$(rigforge_dir)
    if [ "$(config_bool '.local_miner.enabled' false 2>/dev/null || echo false)" != "true" ]; then
        # Derived means derived: switched off, the config goes away — the boot leg then has
        # nothing to start, and a stale stratum password does not linger on /data.
        rm -f "$dir/config.json"
        return 0
    fi
    if local_miner_hugepages_blocked; then
        # Same treatment as switched off (#1103): a reduced-RAM box cannot also fit a co-located
        # miner without double-counting the stack's own reservation. provision_local_miner is
        # the one that warns the operator; this only keeps the derived file from existing.
        rm -f "$dir/config.json"
        return 0
    fi
    if [ ! -d "$dir" ]; then
        warn "Local mining is on, but there is no RigForge tree at $dir — this image does not carry the built-in miner."
        return 0
    fi
    local port secret
    port=$(stratum_port_effective)
    secret=$(env_get PROXY_STRATUM_PASSWORD 2>/dev/null || true)
    jq -n --arg url "127.0.0.1:$port" --arg pass "$secret" --argjson reserve "$(($(hugepages_decision_pages) * 2))" \
        '{pools: [({url: $url} + (if $pass != "" then {pass: $pass} else {} end))], hugepages_reserve_extra_mb: $reserve}' \
        >"$dir/config.json"
    log "Local miner config rendered to $dir/config.json (pool 127.0.0.1:$port)."
}

# The one place RigForge's setup is ever invoked, shared by both roles that run a miner. Same
# appliance flag, same tree on /data, same first-run narration — a rig and a coordinator that
# also mines differ in where the miner's config came from, never in how it is started.
#
# Prebuilt-first is the whole reason this is instant: pithead-sync seeds the image's baked XMRig
# into the workspace, so the binary already exists and RigForge's setup re-renders rather than
# compiles. A build here means the operator's own native rebuild replaced it or the cached one
# failed its integrity check — minutes of silence on a console with nothing else to look at, so
# say what the machine is doing. Nothing on this path clones: a Tor-only box could not.
rigforge_setup_run() {
    local dir
    dir=$(rigforge_dir)
    if [ ! -x "$dir/rigforge.sh" ]; then
        warn "There is no RigForge tree at $dir — this image does not carry the built-in miner."
        return 1
    fi
    if [ ! -x "$dir/data/worker/xmrig/build/xmrig" ]; then
        _console "Preparing the miner — building it once. This can take several minutes."
    fi
    (cd "$dir" && RIGFORGE_APPLIANCE=1 ./rigforge.sh setup)
}

# The run leg: converge the on-box miner to what this machine says it is. Runs after the stack
# is up (the miner needs the stratum listening; RigForge's setup restarts the service it
# installs), from pithead-boot on every boot and from setup on first provisioning. RigForge's
# appliance mode makes the whole run idempotent on the read-only root: units in /run with
# --runtime enablement, no package installs, GRUB untouched, grow-only HugePages.
#
# The role forks here rather than in the boot path, so both boot owners — pithead-boot on a
# provisioned machine, the first-boot wizard on the boot that accepts a role — get the right leg
# from the one command.
provision_local_miner() {
    is_appliance || return 0
    if [ "$(machine_role)" = "rig" ]; then
        provision_rig_miner
        return
    fi
    local dir
    dir=$(rigforge_dir)
    if [ "$(config_bool '.local_miner.enabled' false 2>/dev/null || echo false)" != "true" ]; then
        # Switched off: stop a still-running miner now rather than waiting for the reboot that
        # would drop its runtime unit anyway. Best-effort — absent unit, absent systemctl (tests)
        # and DIY hosts all land in the same quiet no-op.
        systemctl stop xmrig.service >/dev/null 2>&1 || true
        return 0
    fi
    if local_miner_hugepages_blocked; then
        # #1103: this machine's reduced HugePages reservation cannot also fit a co-located
        # miner without double-counting the stack's own share — refuse to start it, the same
        # way a switched-off opt-in does, rather than let RigForge's grow-only sysctl chase an
        # unbounded target on hardware already running squeezed.
        warn "Local mining opt-in is ON, but this machine's reduced HugePages reservation cannot also fit a co-located miner without risking the stack itself — the built-in miner is not started. Use a 16 GB machine for the built-in miner."
        systemctl stop xmrig.service >/dev/null 2>&1 || true
        return 0
    fi
    [ -f "$dir/config.json" ] || render_local_miner_config
    if rigforge_setup_run; then
        log "Local miner is up — it appears in the dashboard's Workers view."
    else
        warn "Local miner setup failed — the stack itself is unaffected. Details are in the log above."
        return 1
    fi
}

# --- the rig role's boot leg (one stick, three machines) -------------------------------------
# A rig has no config.json, no containers, no dashboard and no chains: its entire product is the
# miner. So it rides the SAME leg the Both role rides, sourced from rig.json instead of
# config.json — one invocation contract, one prebuilt, one appliance mode.

# RigForge's config for a rig, derived from rig.json exactly the way the Both role's is derived
# from config.json — rebuilt every boot, never repaired. Three values and no more: the pool the
# operator gave, the worker name that labels this rig at that pool (RigForge's pools[].user,
# which falls back to the hostname when empty), and the stratum password when one was set.
# No hugepages_reserve_extra_mb: there is no stack on this machine to leave headroom for, so
# RigForge sizes the HugePages pool for the miner alone.
render_rig_miner_config() {
    local dir
    dir=$(rigforge_dir)
    if [ ! -d "$dir" ]; then
        warn "This machine is a rig, but there is no RigForge tree at $dir — this image does not carry the miner."
        return 1
    fi
    jq '{pools: [({url: .pool, user: (.worker // "")}
        + (if (.stratum_password // "") == "" then {} else {pass: .stratum_password} end))]}' \
        "$PWD/rig.json" >"$dir/config.json" 2>/dev/null || return 1
    chmod 600 "$dir/config.json" 2>/dev/null || true
}

# Write minimization for a removable root. The rig role's stick can BE the system it runs from —
# that is the point of the run-from-USB choice — and the image's journald ships
# Storage=persistent with a 200 MB cap, whose files land on the /var overlay, whose upper lives
# on that same medium. A rig holds almost no state and its logs are read within the boot that
# produced them, so volatile is the honest setting: the journal lives in RAM and the stick sees
# no rotating writes at all.
#
# Converged every boot rather than baked, because it cannot be baked: /etc and /run are BOTH
# volatile on this appliance, so no drop-in survives a reboot and journald always starts
# persistent again. The existing-directory guard makes this one restart per boot, not a loop.
# Swap needs no code at all: the appliance declares no swap partition and creates none, so
# "no swap" is already true in every role — see os/rootfs/repart.d.
rig_minimize_writes() {
    is_appliance || return 0
    local dropin="${PITHEAD_JOURNALD_DROPIN_DIR:-/run/systemd/journald.conf.d}"
    local journal="${PITHEAD_JOURNAL_DIR:-/var/log/journal}"
    mkdir -p "$dropin" 2>/dev/null || return 0
    # Sorts after the image's own pithead.conf, and later file wins: that is how a drop-in
    # overrides a drop-in.
    printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=32M\n' >"$dropin/zz-rig-volatile.conf" 2>/dev/null || return 0
    [ -d "$journal" ] || return 0
    rm -rf "${journal:?}"
    systemctl restart systemd-journald >/dev/null 2>&1 || true
    log "Rig write minimization: the journal is in memory for this boot — the root may be the stick the miner runs from."
}

provision_rig_miner() {
    if [ ! -f "$PWD/rig.json" ]; then
        warn "This machine is marked as a rig, but its settings are missing — install it again from the stick to choose a role."
        return 1
    fi
    rig_minimize_writes
    render_rig_miner_config || return 1
    if rigforge_setup_run; then
        log "The rig is mining: $(jq -r '.worker // "this machine"' "$PWD/rig.json" 2>/dev/null) -> $(jq -r '.pool // "no pool recorded"' "$PWD/rig.json" 2>/dev/null)."
        return 0
    fi
    warn "The rig's miner did not start. Details are in the log above."
    return 1
}
