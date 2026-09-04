# --- Diagnostics (doctor) ---
#
# A strictly READ-ONLY health report: the "run this and paste the output" command for support
# threads. It never modifies files or the system, and never hard-exits mid-run — every check is
# guarded so a missing tool or unreachable service can't abort it. Each check prints one
# OK/WARN/FAIL line with a short hint; a summary follows. It works whether or not the stack is
# deployed (env-dependent checks degrade gracefully when .env is absent), and Linux-only probes
# (e.g. /proc/meminfo) are skipped on macOS dev hosts.

# Per-run tallies for the closing summary. Reset at the top of doctor().
DR_OK=0
DR_WARN=0
DR_FAIL=0

dr_ok() {
    DR_OK=$((DR_OK + 1))
    dr_record ok "$1"
    printf '  %b✓ OK%b   %s\n' "$C_GREEN" "$C_RESET" "$1"
}
dr_warn() {
    DR_WARN=$((DR_WARN + 1))
    dr_record warn "$1"
    printf '  %b⚠ WARN%b %s\n' "$C_YELLOW" "$C_RESET" "$1"
}
dr_fail() {
    DR_FAIL=$((DR_FAIL + 1))
    dr_record fail "$1"
    printf '  %b✗ FAIL%b %s\n' "$C_RED" "$C_RESET" "$1"
}
# Neutral note for context lines that aren't pass/fail (e.g. a skipped Linux-only check).
dr_info() {
    dr_record info "$1"
    printf '  %b•%b      %s\n' "$C_YELLOW" "$C_RESET" "$1"
}
# One verdict, worded for the surface the operator is actually on (#1213). Doctor's messages reach
# the dashboard verbatim since the diagnostics verbs landed -- control_diag_doctor runs
# `doctor --json` and every dr_fail/dr_warn message ships as {status, message} -- so a remedial
# string naming a CLI verb is a dead end on an appliance, which has no shell. That is the defect
# class the refusal strings were already fixed for; these are the same treatment for doctor.
# First argument is the DIY/host wording, byte for byte what it always was. The second is what an
# appliance operator is told instead, and it NEVER invents a remedy: it names a dashboard surface
# only where one exists (the setup page, the one-click upgrade, the per-container log view) and
# otherwise states the diagnosis and stops -- the same choice describe_change makes when there is
# no remedy to offer. is_appliance resolves at call time, as it already does elsewhere here.
dr_fail_surface() { if is_appliance; then dr_fail "$2"; else dr_fail "$1"; fi; }
dr_warn_surface() { if is_appliance; then dr_warn "$2"; else dr_warn "$1"; fi; }
dr_info_surface() { if is_appliance; then dr_info "$2"; else dr_info "$1"; fi; }
# `doctor --json` capture (#77 phase 1): every check verdict lands as a status<TAB>message line in
# DR_JSON_FILE when set; doctor assembles the machine report from it. TSV keeps this a plain
# append — messages are prose and never carry tabs.
dr_record() { [ -n "${DR_JSON_FILE:-}" ] && printf '%s\t%s\n' "$1" "$2" >>"$DR_JSON_FILE" || true; }

# Best-effort system-clock sync status. Mining is time-sensitive — P2Pool/Monero stamp shares and
# blocks, so a skewed clock gets shares/blocks rejected ("strongly recommended to synchronize your
# system clock before you start mining"). Prints: synced | unsynced | unknown. Pure given the
# timedatectl output, so a stubbed timedatectl makes the classification unit-testable.
clock_sync_status() {
    command -v timedatectl >/dev/null 2>&1 || {
        echo unknown
        return
    }
    case "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" in
    yes) echo synced ;;
    no) echo unsynced ;;
    *) echo unknown ;;
    esac
}

# Container engine for doctor's host checks (#77 phase 2): docker on the DIY channel, podman on
# the appliance. PITHEAD_ENGINE overrides (the appliance image sets it); auto-detect otherwise —
# docker wins when both are present, matching the DIY default.
container_engine() {
    case "${PITHEAD_ENGINE:-}" in
    docker | podman)
        printf '%s' "$PITHEAD_ENGINE"
        return
        ;;
    esac
    if command -v docker >/dev/null 2>&1; then
        printf 'docker'
    elif command -v podman >/dev/null 2>&1; then
        printf 'podman'
    else
        printf 'docker'
    fi
}

# True if Docker is set to start at boot (docker.service OR docker.socket enabled). systemd only —
# the caller checks that systemctl exists. Checking docker.socket too covers socket-activated
# installs where docker.service is "static" but Docker still comes up at boot.
docker_boot_enabled() {
    if [ "$(container_engine)" = "podman" ]; then
        # Rootful podman has no daemon; boot persistence = the socket-activated API (the proxies
        # mount it) plus systemd starting the Quadlet units, which [Install] handles per-unit.
        systemctl is-enabled podman.socket >/dev/null 2>&1
        return
    fi
    systemctl is-enabled docker.service >/dev/null 2>&1 || systemctl is-enabled docker.socket >/dev/null 2>&1
}

# Appliance low-RAM degrade: the boot-time sizing (os/overlay/pithead-hugepages) leaves its
# marker in /run when it shrank or released the RandomX reservation — the plain-words message
# first, then the machine-readable "pages=N" record hugepages_decision_pages reads — and doctor
# repeats the words here, not the record. WARN, not FAIL, on purpose — the appliance's A/B
# commit gate takes doctor's exit code, and a degraded-but-serving box must still commit its
# slot. The file never exists off the appliance, so this is a no-op everywhere else. A separate
# function so the marker read is unit-testable; the marker path override matches the overlay's.
check_hugepages_degraded() {
    local marker="${PITHEAD_HUGEPAGES_MARKER:-/run/pithead-hugepages-degraded}"
    [ -f "$marker" ] || return 0
    dr_warn "$(head -n 1 "$marker" | tr '\t' ' ')"
}

# #1103: on the REDUCED tier, render_local_miner_config and provision_local_miner both refuse to
# co-locate the built-in miner even though local_miner.enabled is on (see the comment above
# local_miner_hugepages_blocked for why no headroom value could make that safe). Say so here too,
# the same way the reduced reservation itself is announced above — an operator staring at an empty
# Workers view otherwise has nothing telling them the opt-in was refused rather than just slow.
check_local_miner_hugepages_blocked() {
    is_appliance || return 0
    [ "$(config_bool '.local_miner.enabled' false 2>/dev/null || echo false)" = "true" ] || return 0
    local_miner_hugepages_blocked || return 0
    dr_warn "Local mining opt-in is ON, but this machine's reduced HugePages reservation cannot also fit a co-located miner — the built-in RigForge worker is not started. Use a 16 GB machine for the built-in miner."
}

# True (rc 0) when the host CPU advertises AVX2 — RandomX wants it, but it's performance-only,
# not fatal. Linux reads /proc/cpuinfo; macOS reads sysctl's machdep CPU features.
cpu_has_avx2() {
    if [ "$OS_TYPE" == "Darwin" ]; then
        sysctl -a 2>/dev/null | grep "machdep.cpu" | grep -q "AVX2"
    else
        grep -q "avx2" /proc/cpuinfo 2>/dev/null
    fi
}

# Release-signature verification (#376): the state the next pull — `up` or `upgrade` — will act on.
# Extracted from doctor() so each branch is unit-testable, like the other doctor checks. Every branch
# mirrors a refusal the one-click upgrade runner makes, so this answers "can this box take an
# upgrade" BEFORE one is attempted rather than during it (#1108). Read-only: nothing is pulled.
check_release_verification() {
    if is_source_checkout; then
        dr_info "Source checkout — images build locally and are not signature-verified, and the dashboard's one-click upgrade does not apply: upgrade with 'git pull' then './pithead upgrade'." # appliance-unreachable: is_source_checkout excludes is_appliance
    elif [ ! -f cosign.pub ]; then
        dr_warn "No cosign.pub next to pithead — image pulls are NOT signature-verified. Release bundles ship the key from the first signed release."
    elif ! cosign_available; then
        dr_warn_surface "cosign.pub is present but docker is not available to run the verifier — 'up'/'upgrade' refuse to pull until it is. Start the Docker daemon." "The container engine is not available to run the release verifier, so no image can be pulled until it is back. The appliance image ships that engine, so this system copy is faulty."
    elif docker image inspect "$COSIGN_IMAGE" >/dev/null 2>&1; then
        dr_ok "'up' and 'upgrade' verify the release images against cosign.pub; the pinned verifier image is already here, nothing to install."
    else
        # The verifier is fetched on demand, so a box that has never run a verified operation simply
        # does not have it yet. Worth saying plainly: if that one fetch fails, the operation reports a
        # *signature* failure — which reads as a tampered release rather than as an image this host
        # could not pull (#1084).
        dr_warn_surface "The pinned release verifier image is not on this host yet — the next 'up' or 'upgrade' fetches it. If that fetch fails, the operation reports a signature failure even though nothing was tampered with. Pre-fetch it with: docker pull $COSIGN_IMAGE" "The pinned release verifier image is not on this machine yet — the next update fetches it. If that fetch fails, the update reports a signature failure even though nothing was tampered with."
    fi
}
