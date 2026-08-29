# shellcheck shell=bash
#
# Abort-safe unwind for the RigForge writable-key legs (#1379).
#
# `e2e.sh` installs `trap restore_all EXIT INT TERM`, which reads as full abort safety for the
# borrowed rig. It is not: `restore_all` puts back the miner's xmrig POOL config and the baseline
# stack, and never touches the rig's RigForge writable config — DONATION, max_temp_c, autotune,
# watchdog, watchdog_interval_min, pools. Those writes are made from run.sh and this directory's
# other modules, in a process that had no trap of any kind. Every writable-key leg was a bare
# apply/revert pair with no unwind path, so a run that died between the two — Ctrl-C, a `set -u`
# abort, a cancelled CI job, an SSH drop — left a borrowed production miner on a probe value while
# the trap that DID exist reported a clean restore of the pool config.
#
# It had not bitten yet for two reasons, neither of them a control: the probes are chosen benign
# (max_temp_c +1; the #1236 legs read each original off the rig and write a near neighbour), and
# almost nobody ran the phase. #1364 removes the second one on purpose by putting the write phase
# into the mandated `--mode targeted` pre-cut run.
#
# THE LEDGER, and why it is a ledger rather than a saved snapshot. A key is recorded when its write
# goes out and cleared only when its revert is CONFIRMED applied — so at the end of a healthy run
# the ledger is empty and the trap restores nothing. That makes the issue's "must be a no-op when
# no writable key was touched" requirement structurally true rather than a guarded special case:
# when nothing was written, no mark ever happened, so no trap was ever installed. It also keeps a
# leg whose revert came back non-applied on the books, so the trap retries it at exit instead of
# trusting an assertion that already red.
#
# THE TRAP IS COMPOSED, NOT STACKED, AND THAT IS THE WHOLE HAZARD IN THIS FILE. `trap … EXIT`
# REPLACES; it does not stack. run.sh calls `rig_lock` (lib.sh), which installs an EXIT trap of its
# own to remove the display-only lock-holder breadcrumb. A naive second `trap … EXIT` here would
# silently produce one of two failures with no output difference either way:
#
#   installed BEFORE rig_lock runs  -> the holder trap replaces ours and NO key is ever restored,
#                                      i.e. this fix reads as shipped and does nothing;
#   installed AFTER                 -> ours replaces the holder cleanup and every run strands the
#                                      breadcrumb, the display side of the shared-bench protocol.
#
# lib.sh predicted exactly this and prescribed the fix in its own words — fold the holder `rm -f`
# into the body of whatever trap is added, rather than trapping twice. `rig_key_atexit` below is
# that fold, and it is the ONLY copy of that removal outside lib.sh's own. Its ordering is asserted
# at tier 1 by driving the real `rig_lock` against sandboxed paths, so if lib.sh's holder-path logic
# ever changes, this copy reds rather than drifting quietly.
#
# WHY `EXIT` ALONE AND NOT `EXIT INT TERM`. Measured on this box rather than assumed: a bare EXIT
# trap DOES run when the shell dies of SIGINT or SIGTERM, so naming the signals adds no coverage.
# What it adds is worse than the second firing it is usually described as — a bash INT/TERM handler
# that RETURNS does not die, so the script RESUMES at the next command, runs on to the end and exits
# 0 (#1401; proof in selftest-abort-traps.sh). `EXIT` covers Ctrl-C, a `kill`, and a cancelled CI job
# with exactly one firing. The unwind is written to be idempotent anyway, because a trap that assumes
# it runs once is a trap nobody can safely change.
#
# ROUTES. Two, because the write surface is not all one path: `dash` is the dashboard's
# /api/control/worker-apply (the #513, #1236 and #1002b legs) and `rig` is a direct dial at the
# rig's own control API (#516's feed leg). A restore has to go back the way its write came, so the
# route travels in the ledger with the key.
#
# Sourced by run.sh, which supplies `_worker_apply`, `_rig_control_apply`, `it_warn` and `jq`.
# Every function here is drivable standalone against stubs — that is the tier the mutation proofs
# live at (selftest-rig-key-ledger.sh), not a bench.

# One outstanding write per line: <route>\t<rig>\t<key>\t<original-value-as-json>. A newline-
# delimited string, deliberately not an associative array: there are none anywhere in this
# directory and lib.sh:438 shows the bash 3.2 awareness this harness is written to.
# This variable is deliberately not named after the writable keys it holds. gitleaks'
# generic-api-key rule reads an identifier containing that word, together with whatever the
# next line starts with, as one credential, and reds the secret scan on this file. The finding
# is anchored in the commit that introduces it, so renaming back cannot be undone at the tip.
_RIG_LEDGER=""
_RIG_KEY_TRAP_ARMED=0

# The EXIT handler: restore everything still outstanding, THEN do lib.sh's holder cleanup. Ordering
# matters — the rig restore is the thing worth doing, so it goes first and the breadcrumb removal
# cannot be skipped by it (no `set -e` here, and every step is best-effort).
rig_key_atexit() {
    rig_key_unwind
    # The fold lib.sh:rig_lock's comment prescribes. Re-derived from the durable env/default rather
    # than a local, exactly as the trap it replaces did, and best-effort in the same two steps: a
    # holder marker we cannot remove must never be fatal. (#244/#249)
    local h="${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}"
    rm -f "$h" 2>/dev/null || sudo -n rm -f "$h" 2>/dev/null || true
}

# Install the composed trap, once, at the FIRST mark. Lazy on purpose: see the no-op reasoning above.
_rig_key_arm() {
    [ "$_RIG_KEY_TRAP_ARMED" = "1" ] && return 0
    _RIG_KEY_TRAP_ARMED=1
    trap rig_key_atexit EXIT
    return 0
}

# Record an outstanding write. Call this BEFORE the apply goes out, not after — the window this
# exists to cover includes the apply itself.
rig_key_mark() { # <route: dash|rig> <rig> <key> <original-value-as-json>
    _rig_key_arm
    _RIG_LEDGER="${_RIG_LEDGER}$1	$2	$3	$4
"
    return 0
}

# Retire an outstanding write. Call this only once the revert is CONFIRMED applied; a revert that
# came back anything else stays on the books so the trap retries it.
rig_key_clear() { # <route> <rig> <key>
    local out="" r w k v
    # `<<<` and not a pipe: a pipeline runs its right-hand side in a SUBSHELL, and the assignment
    # to _RIG_LEDGER would be discarded with it — leaving every entry permanently outstanding
    # and the trap re-applying originals over a healthy rig at the end of a clean run.
    while IFS=$'\t' read -r r w k v; do
        [ -n "$r" ] || continue
        { [ "$r" = "$1" ] && [ "$w" = "$2" ] && [ "$k" = "$3" ]; } && continue
        out="$out$r	$w	$k	$v
"
    done <<<"$_RIG_LEDGER"
    _RIG_LEDGER="$out"
    return 0
}

# How many writes are outstanding. The self-test's handle on the no-op requirement, and a cheap way
# for a caller to say something true in the run output.
rig_key_outstanding() { printf '%s' "$_RIG_LEDGER" | grep -c .; }

# Restore every outstanding write, by the route that made it. Best-effort and idempotent: this runs
# at EXIT, frequently while the run is already dying, so nothing here may abort and nothing may
# depend on the dashboard or the rig still answering. The ledger is emptied whatever happened —
# a second firing must not re-POST originals over a rig that already took them.
rig_key_unwind() {
    local r w k v payload
    [ -n "$_RIG_LEDGER" ] || return 0
    while IFS=$'\t' read -r r w k v; do
        [ -n "$r" ] || continue
        # it_warn, not it_step: this is a run that did not end the way it meant to, and the operator
        # reading the log needs to know the rig was left mid-change and what we did about it. (It is
        # invisible in the summary counters — #1365 — which is why it says the whole story here.)
        it_warn "aborted mid-change: restoring $k=$v on rig '$w' via the $r route (#1379)"
        payload="$(jq -nc --arg k "$k" --argjson v "$v" '{($k): $v}' 2>/dev/null)" || continue
        [ -n "$payload" ] || continue
        case "$r" in
        dash) _worker_apply "$w" "$payload" >/dev/null 2>&1 || true ;;
        rig) _rig_control_apply "$payload" >/dev/null 2>&1 || true ;;
        *) it_warn "unknown restore route '$r' for $k on rig '$w' — NOT restored (#1379)" ;;
        esac
    done <<<"$_RIG_LEDGER"
    _RIG_LEDGER=""
    return 0
}
