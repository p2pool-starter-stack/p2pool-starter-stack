#!/usr/bin/env bash
#
# Self-test for the abort-safe writable-key unwind (rig-key-ledger.sh, #1379) — no rig, no server,
# no docker.
#
# This file IS the lane's bar for #1379, and the bar is higher than usual because the thing under
# test is an INSTRUMENT: a trap that silently does nothing is indistinguishable from a trap that
# works, in a run whose whole point is that it did not reach its own cleanup. So every assertion
# below is written to die if the behaviour it covers is removed, and the two that matter most are
# driven in a REAL child process that REALLY dies — one by a non-zero exit, one by SIGINT — because
# a trap asserted by calling its handler by hand proves only that the handler is a function.
#
# The composition assertion (`rig_lock` + our trap) drives lib.sh's ACTUAL rig_lock against
# sandboxed RIG_LOCK_FILE/RIG_LOCK_HOLDER paths (rigforge#183 note 6), not a copy of it. That is
# deliberate: `rig_key_atexit` carries the only other copy of the holder-breadcrumb removal, and a
# test against a re-implementation would keep passing while the two copies drifted apart.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's file-budget ceiling —
# same reasoning as selftest-rigforge-writable-keys.sh and selftest-rigforge-apply-settle.sh.
# Run directly, or via `make test-integration-selftest`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APPLY_LOG="$WORK/applies.log"
SCEN_OUT="$WORK/out.txt"
# Exported, not passed as prefix assignments: a prefix assignment is visible only to the forked
# process, so `$WORK` in the same command line would still expand to the caller's value (SC2097).
export INT_DIR="$HERE"
export APPLY_LOG WORK

# --- The scenario harness ---------------------------------------------------
# Each scenario is a fresh bash CHILD. That is the point: an EXIT trap can only be honestly
# observed from outside the process it fires in, and the failure this issue is about is a process
# that dies before its cleanup. The stubs record every restore attempt as "<route>|<payload>" so a
# scenario's effect is a fact about a FILE, not about a shell variable — a stub recording into a
# variable would lose every write made inside a `$( … )` and read exactly like "nothing was
# restored", which is the passing-for-the-wrong-reason shape this directory has already been bitten
# by once.
cat >"$WORK/prelude.sh" <<'PRELUDE'
set -uo pipefail
# shellcheck source=/dev/null
source "$INT_DIR/lib.sh"
# shellcheck source=/dev/null
source "$INT_DIR/rig-key-ledger.sh"
_worker_apply() { printf 'dash|%s\n' "$2" >>"$APPLY_LOG"; }
_rig_control_apply() { printf 'rig|%s\n' "$1" >>"$APPLY_LOG"; }
PRELUDE

# scenario <body...> — run it in a fresh child; echo the child's rc. Stdout+stderr land in SCEN_OUT,
# restore attempts in APPLY_LOG, both reset per scenario.
scenario() {
    : >"$APPLY_LOG"
    : >"$SCEN_OUT"
    {
        cat "$WORK/prelude.sh"
        printf '%s\n' "$@"
    } >"$WORK/scen.sh"
    bash "$WORK/scen.sh" >"$SCEN_OUT" 2>&1
    printf '%s' "$?"
}

restores() { cat "$APPLY_LOG"; }
n_restores() { grep -c . "$APPLY_LOG"; }

echo "== no write, no trap, no restore: the no-op is structural, not a guarded special case =="
rc="$(scenario 'echo "TRAP=[$(trap -p EXIT)]"' 'exit 0')"
assert_eq "a run that marks nothing exits cleanly" "$rc" "0"
# The load-bearing half of the issue's no-op requirement. Not "the trap ran and did nothing" —
# NO TRAP EXISTS. Mutating _rig_key_arm to install eagerly at source time kills this.
assert_eq "no EXIT trap is installed when no writable key was touched (#1379)" \
    "$(grep -c 'TRAP=\[\]' "$SCEN_OUT")" "1"
assert_eq "and nothing is POSTed at the rig" "$(n_restores)" "0"

echo "== a run that dies mid-change restores the outstanding key =="
rc="$(scenario 'rig_key_mark dash rig1 DONATION 5' 'exit 9')"
assert_eq "the child really died non-zero" "$rc" "9"
assert_eq "the outstanding key is restored to its original, via the dash route (#1379)" \
    "$(restores)" 'dash|{"DONATION":5}'

echo "== Ctrl-C — the failure mode the issue leads with =="
# Measured, not assumed: a bare EXIT trap DOES run when bash dies of SIGINT, and `EXIT INT TERM`
# would both fire the handler twice AND let the run resume past the signal (#1401; the matrix is in
# selftest-abort-traps.sh). This asserts both halves at once — the restore happened, and it happened
# exactly once.
scenario 'rig_key_mark dash rig1 max_temp_c 100' 'kill -INT $$' 'sleep 30' >/dev/null
assert_eq "SIGINT mid-change restores the key (#1379)" \
    "$(restores)" 'dash|{"max_temp_c":100}'
assert_eq "and fires exactly once, not twice" "$(n_restores)" "1"

echo "== SIGTERM — a cancelled CI job or a reaped run =="
scenario 'rig_key_mark dash rig1 DONATION 0' 'kill -TERM $$' 'sleep 30' >/dev/null
assert_eq "SIGTERM mid-change restores the key (#1379)" "$(restores)" 'dash|{"DONATION":0}'

echo "== a CONFIRMED revert retires the entry; the trap then has nothing to do =="
rc="$(scenario 'rig_key_mark dash rig1 DONATION 5' 'rig_key_clear dash rig1 DONATION' 'exit 0')"
assert_eq "a cleared ledger leaves the rig alone at exit" "$(n_restores)" "0"
assert_eq "and the run still exits clean" "$rc" "0"

echo "== clear is exact: route, rig and key must ALL match =="
# Three separate near-miss clears. Each one alone catches a different sloppy predicate — a clear
# keyed on the key alone, on the rig alone, or ignoring the route — and none of them may retire it.
scenario 'rig_key_mark dash rig1 DONATION 5' \
    'rig_key_clear rig rig1 DONATION' \
    'rig_key_clear dash rig2 DONATION' \
    'rig_key_clear dash rig1 max_temp_c' \
    'exit 1' >/dev/null
assert_eq "a near-miss clear does NOT retire the entry (#1379)" \
    "$(restores)" 'dash|{"DONATION":5}'

echo "== the rig route restores by direct dial, never through the dashboard =="
scenario 'rig_key_mark rig rig1 max_temp_c 100' 'exit 1' >/dev/null
assert_eq "#516's rig-side write is restored the way it was made (#1379)" \
    "$(restores)" 'rig|{"max_temp_c":100}'
assert_eq "and the dashboard route is not used for it" "$(restores | grep -c '^dash|')" "0"

echo "== several outstanding keys: every one restored, and only the outstanding ones =="
scenario 'rig_key_mark dash rig1 DONATION 5' \
    'rig_key_mark dash rig1 watchdog_interval_min 5' \
    'rig_key_mark rig rig2 max_temp_c 90' \
    'rig_key_clear dash rig1 watchdog_interval_min' \
    'exit 1' >/dev/null
assert_eq "two outstanding, one retired" "$(n_restores)" "2"
assert_eq "the retired key is not re-POSTed" "$(restores | grep -c watchdog_interval_min)" "0"
assert_eq "the DONATION entry survives" "$(restores | grep -c 'dash|{"DONATION":5}')" "1"
assert_eq "the other rig's entry survives, on its own route" \
    "$(restores | grep -c 'rig|{"max_temp_c":90}')" "1"

echo "== the unwind is idempotent — a second firing must not re-POST over a healthy rig =="
scenario 'rig_key_mark dash rig1 DONATION 5' 'rig_key_unwind' 'rig_key_unwind' 'exit 0' >/dev/null
assert_eq "restored once despite two explicit unwinds and the EXIT trap (#1379)" "$(n_restores)" "1"

echo "== a non-scalar original round-trips as JSON, not as a mangled string =="
scenario 'rig_key_mark dash rig1 pools '"'"'[{"url":"real:1","pass":"secret"}]'"'"'' 'exit 1' >/dev/null
assert_eq "a pools original is restored intact, credential and all (#1002b/#1379)" \
    "$(restores)" 'dash|{"pools":[{"url":"real:1","pass":"secret"}]}'

echo "== COMPOSITION: our trap replaces rig_lock's, so it must do rig_lock's job too =="
# Drives lib.sh's REAL rig_lock against sandboxed paths. This is the assertion that catches the
# hazard the whole design is shaped around: `trap … EXIT` replaces rather than stacks, so arming
# ours after rig_lock's would strand the shared-bench holder breadcrumb on every run.
scenario 'export RIG_LOCK_FILE="$WORK/rig.lock" RIG_LOCK_HOLDER="$WORK/rig.holder"' \
    'rig_lock selftest "rig-key-ledger #1379"' \
    '[ -s "$RIG_LOCK_HOLDER" ] && echo HOLDER-WRITTEN' \
    'rig_key_mark dash rig1 DONATION 5' \
    'exit 0' >/dev/null
assert_eq "rig_lock really wrote its holder breadcrumb (the control for the next assertion)" \
    "$(grep -c HOLDER-WRITTEN "$SCEN_OUT")" "1"
assert_eq "arming the ledger trap AFTER rig_lock still removes the holder breadcrumb (#1379)" \
    "$([ -e "$WORK/rig.holder" ] && echo STRANDED || echo gone)" "gone"
assert_eq "and the writable key is restored in the same firing" \
    "$(restores)" 'dash|{"DONATION":5}'
rm -f "$WORK/rig.lock" "$WORK/rig.holder"

echo "== dying DURING the apply is covered — which is what mark-before-write buys =="
# The window the ordering exists for, and the only thing that makes it falsifiable at this tier: a
# stub that never returns, because the process dies inside the apply itself. Move the mark below
# the write in any leg and this is the assertion that reds — with an instantaneous stub, every
# other assertion here passes either way. The stub's sleep only has to outlast the command
# substitution the parent is blocked in — the SIGINT is already pending by then — so 0.2s does the
# job 2s did and gives the file back ~1.8s. Checked at both values against the mutation above.
scenario 'source "$INT_DIR/rigforge-apply-settle.sh"' \
    'source "$INT_DIR/rigforge-writable-keys.sh"' \
    '_worker_detail() { printf "%s" "{\"rig_config\":{\"DONATION\":7}}"; }' \
    '_worker_apply() { printf "dash|%s\n" "$2" >>"$APPLY_LOG"; kill -INT $$; sleep 0.2; }' \
    'run_rigforge_writable_keys rig1 >/dev/null 2>&1' \
    'sleep 5' >/dev/null
assert_eq "a death inside the apply still restores the original (#1379)" \
    "$(restores | tail -1)" 'dash|{"DONATION":7}'
assert_eq "the probe went out and the original came back — two POSTs, in that order" \
    "$(restores | head -1)" 'dash|{"DONATION":0}'

echo "== the operator is TOLD, on stderr, that the rig was left mid-change =="
# A silent restore is nearly as bad as none: the run's summary counters cannot see it (#1365), so
# the sentence is the only signal that a borrowed production miner was touched and put back.
scenario 'rig_key_mark dash rig1 DONATION 5' 'exit 1' >/dev/null
assert_eq "the unwind names the key, the value and the rig (#1379)" \
    "$(grep -c "aborted mid-change: restoring DONATION=5 on rig 'rig1'" "$SCEN_OUT")" "1"

echo "== an unknown route is refused loudly rather than POSTed somewhere arbitrary =="
scenario 'rig_key_mark bogus rig1 DONATION 5' 'exit 1' >/dev/null
assert_eq "an unknown route POSTs nothing at all" "$(n_restores)" "0"
assert_eq "and says so" "$(grep -c "unknown restore route 'bogus'" "$SCEN_OUT")" "1"

echo "== integration with the #1236 legs: a confirmed round trip leaves nothing outstanding =="
# The legs' own stubs, driven end to end, so the mark/clear pairing is asserted where it is USED
# rather than only where it is defined.
scenario 'source "$INT_DIR/rigforge-apply-settle.sh"' \
    'source "$INT_DIR/rigforge-writable-keys.sh"' \
    '_worker_detail() { printf "%s" "{\"rig_config\":{\"DONATION\":7},\"history\":[{\"change_id\":\"c1\",\"status\":\"applied\"}]}"; }' \
    '_worker_apply() { printf "dash|%s\n" "$2" >>"$APPLY_LOG"; printf "{\"status\":\"applied\",\"change_id\":\"c1\",\"changed_keys\":[\"DONATION\"]}"; }' \
    'wait_for() { return 0; }' \
    'run_rigforge_writable_keys rig1 >/dev/null 2>&1' \
    'echo "OUTSTANDING=$(rig_key_outstanding)"' \
    'exit 0' >/dev/null
assert_eq "a healthy DONATION round trip retires its own ledger entry (#1236/#1379)" \
    "$(grep -c 'OUTSTANDING=0' "$SCEN_OUT")" "1"
assert_eq "so the EXIT trap POSTs no restore of its own" \
    "$(restores | grep -c '{"DONATION":7}')" "1"

echo "== and a round trip whose REVERT never lands stays on the books for the trap =="
# The case an assertion cannot rescue: the leg's own "reverted" assert has already red, so trusting
# it to have restored the rig would be trusting the thing that just said it did not.
scenario 'source "$INT_DIR/rigforge-apply-settle.sh"' \
    'source "$INT_DIR/rigforge-writable-keys.sh"' \
    '_worker_detail() { printf "%s" "{\"rig_config\":{\"DONATION\":7},\"history\":[{\"change_id\":\"c1\",\"status\":\"applied\"}]}"; }' \
    '_worker_apply() { printf "dash|%s\n" "$2" >>"$APPLY_LOG"; printf "{\"status\":\"failed\",\"change_id\":\"c1\"}"; }' \
    'wait_for() { return 1; }' \
    'run_rigforge_writable_keys rig1 >/dev/null 2>&1' \
    'echo "OUTSTANDING=$(rig_key_outstanding)"' \
    'exit 1' >/dev/null
assert_eq "a revert that never confirmed leaves the key outstanding (#1379)" \
    "$(grep -c 'OUTSTANDING=1' "$SCEN_OUT")" "1"
assert_eq "and the trap retries it at exit" \
    "$(restores | tail -1)" 'dash|{"DONATION":7}'

echo ""
echo "selftest-rig-key-ledger: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
