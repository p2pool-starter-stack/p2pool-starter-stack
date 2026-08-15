# shellcheck shell=bash
#
# The physical appliance bench reservation (#1022's Gap 1). Sourced, never executed.
#
# Design constraint that makes this different from the rig-e2e lock (tests/integration/lib.sh
# rig_lock, mirrored below): a rig survives the tests that use it, but the appliance is
# REFLASHED and factory-reset BY the tests that use it (tests/os/hw-battery.sh installs bundles,
# reboots into fresh slots, and the manual battery's M1/M4/M8/M10 legs flash and power-cycle the
# board directly). A lock or holder marker stored ON the appliance would be destroyed by the exact
# work it is meant to guard, and a lock that silently vanishes mid-run is worse than no lock. So
# the reservation lives on the stable bench COORDINATOR — wherever this file is sourced from, i.e.
# the same host that drives the appliance over ssh, not the appliance itself. That is also why
# there is no rig_lock_remote-style ssh-tunnelled variant here: rig_lock_remote exists because a
# rig's lock has to be taken ON the rig; the appliance's lock is already local to the box that
# takes it.
#
# The mechanism otherwise mirrors rig_lock deliberately: a flock held on an inherited FD so the
# kernel releases it the moment the holding process dies (kill -9 included, no stale-lock
# heuristics), a best-effort holder sidecar naming who/what/when, and shared (read-only probing)
# vs exclusive (mutating/reflashing) modes. It is a distinct resource with a distinct protocol —
# see docs/dev/release-server.md's "Appliance bench reservation" section for the box contract
# (what is safe to destroy, what must be preserved) and the off-box check recipe.
#
# BENCH_LOCK_ID names WHICH resource (default "appliance" — the one physical box this repo has
# today; a second appliance would pass a different id). BENCH_LOCK_FILE / BENCH_LOCK_HOLDER
# override the paths outright, which is what lets the tier-1 self-test in tests/stack/run.sh
# sandbox them with no real /var/lock involved.

# _bench_holder_line <label> <mode> <who> <pid> <started-iso8601> — pure formatter for the holder
# sidecar's one line. Split out from bench_lock() (which supplies the live values) so it is
# independently testable without touching a filesystem or a real process.
_bench_holder_line() {
    printf '%s mode=%s who=%s pid=%s started=%s' "$1" "$2" "$3" "$4" "$5"
}

# bench_lock_classify <rc> <holder-content> — pure. <rc> is the exit code of a non-blocking
# `flock -n -x LOCKFILE true` probe (0 = nothing holds it, nonzero = something does). Turns that
# plus the holder sidecar's content into a human-readable verdict; used by both bench_lock_status
# (below) and the off-box check recipe so the wording can't drift between them.
bench_lock_classify() {
    if [ "$1" -eq 0 ]; then
        printf 'free'
    else
        printf 'busy: %s' "${2:-unknown holder}"
    fi
}

# bench_lock <label> [shared] — take the reservation and hold it for the lifetime of THIS
# process (kill -9 included). Mutating/reflashing work takes it exclusive (the default);
# read-only probing (e.g. checking the box is reachable before deciding to run) passes "shared" so
# concurrent readers coexist while still excluding an exclusive (mutating) run. Exits 75
# (EX_TEMPFAIL) when busy so callers can tell "retry later" from a real failure, matching
# rig_lock's convention; set BENCH_LOCK_WAIT=1 to queue instead of failing fast.
bench_lock() {
    local mode_flag=-x mode_name=exclusive
    [ "${2:-}" = shared ] && mode_flag=-s && mode_name=shared
    local lf="${BENCH_LOCK_FILE:-/var/lock/pithead-bench-${BENCH_LOCK_ID:-appliance}.lock}"
    # Holder breadcrumb defaults BESIDE the lock, not under root-owned /run — a non-root run can't
    # write /run's default, and the lock must still hold even if the sidecar write can't (#244-style
    # lesson, mirrored from rig_lock).
    local hf="${BENCH_LOCK_HOLDER:-$lf.holder}"
    # Refuse a symlinked lock/holder path so a planted symlink on a shared coordinator can't
    # redirect our create/chmod/holder-write onto another file.
    { [ -L "$lf" ] || [ -L "$hf" ]; } && {
        echo "bench_lock: lock/holder path is a symlink — refusing" >&2
        exit 1
    }
    # Open READ-only (9<), same reasoning as rig_lock: a lock file first created by a different
    # non-root user (e.g. after /var/lock is on a tmpfs that was cleared by a reboot) is owned by
    # that user, and fs.protected_regular then blocks even a root O_CREAT-write (9>) of it with
    # EACCES. A read-open is never guarded, and flock -x/-s both work fine on a read fd.
    [ -e "$lf" ] || : >"$lf" 2>/dev/null || true
    chmod 666 "$lf" 2>/dev/null || true # best-effort world-writable; a read-open only needs o+r
    exec 9<"$lf"
    if ! flock -n $mode_flag 9; then
        if [ "${BENCH_LOCK_WAIT:-0}" = 1 ]; then
            echo "appliance bench busy ($(cat "$hf" 2>/dev/null || echo unknown)) — waiting..." >&2
            flock $mode_flag 9
        else
            echo "appliance bench busy: $(cat "$hf" 2>/dev/null || echo unknown). Retry with BENCH_LOCK_WAIT=1 to queue." >&2
            exit 75 # EX_TEMPFAIL — retry later, not a real failure
        fi
    fi
    # DISPLAY-ONLY and best-effort, exactly like rig_lock: the flock above is already held on FD 9;
    # a holder write that fails (root-owned sidecar, non-root runner) must never abort under set -e
    # and drop the lock.
    local _line
    _line="$(_bench_holder_line "$1" "$mode_name" \
        "${USER:-unknown}@$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)" \
        "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    { printf '%s\n' "$_line" >"$hf" || printf '%s\n' "$_line" | sudo -n tee "$hf" >/dev/null; } 2>/dev/null || true
    # Re-derive the paths from env/default rather than closing over the locals — a later
    # `trap … EXIT` in the caller REPLACES this one, it doesn't stack, so fold this rm -f into it
    # instead of trapping twice if the caller ever adds its own EXIT trap.
    trap 'rm -f "${BENCH_LOCK_HOLDER:-${BENCH_LOCK_FILE:-/var/lock/pithead-bench-${BENCH_LOCK_ID:-appliance}.lock}.holder}" 2>/dev/null || sudo -n rm -f "${BENCH_LOCK_HOLDER:-${BENCH_LOCK_FILE:-/var/lock/pithead-bench-${BENCH_LOCK_ID:-appliance}.lock}.holder}" 2>/dev/null || true' EXIT
}

# bench_lock_status — non-blocking, takes nothing. Prints "free" or "busy: <holder line>" (see
# bench_lock_classify) and returns 0/1 to match. This is the local half of the off-box check; the
# off-box recipe (documented in docs/dev/release-server.md) is the same flock probe run over ssh.
bench_lock_status() {
    local lf="${BENCH_LOCK_FILE:-/var/lock/pithead-bench-${BENCH_LOCK_ID:-appliance}.lock}"
    local hf="${BENCH_LOCK_HOLDER:-$lf.holder}"
    [ -e "$lf" ] || {
        bench_lock_classify 0 ""
        return 0
    }
    if flock -n -x "$lf" true 2>/dev/null; then
        bench_lock_classify 0 ""
        return 0
    fi
    bench_lock_classify 1 "$(cat "$hf" 2>/dev/null || true)"
    return 1
}
