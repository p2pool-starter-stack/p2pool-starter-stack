#!/usr/bin/env bash
#
# Self-test for the #1236 writable-key legs (rigforge-writable-keys.sh), driven as pure functions
# against stubs — no rig, no server, no docker.
#
# This file IS the lane's bar for #1236. A leg that goes SKIPPED -> PASSED without a demonstrated
# failure mode has been silenced, not fixed, so every assertion below is written to DIE if the
# behaviour it covers is removed: each one names the mutation it kills. The three refusals
# (autotune, watchdog, self-derived pools) are asserted the same way — as behaviour, by proving no
# apply payload ever carries those keys — because a refusal that lives only in a comment is a
# refusal one edit away from being undone silently.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's file-budget ceiling —
# same reasoning as selftest-rigforge-apply-settle.sh (#1309) and selftest-compose-profiles.sh
# (#1301). Run directly, or via `make test-integration-selftest`.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/rigforge-writable-keys.sh
source "$HERE/rigforge-writable-keys.sh"

# --- Stubs ------------------------------------------------------------------
# The rig detail the stubbed _worker_detail serves, and the log of every worker-apply payload the
# code under test POSTs. The payload log is what makes the refusals testable: a refusal is "this
# key never appears in an apply", which is a fact about the log, not about a comment.
#
# The log is a FILE, not a variable, and that is load-bearing rather than a style choice: the code
# under test calls _worker_apply inside `$(...)`, so a stub that recorded into a shell variable
# would lose every write to the command-substitution subshell and report an empty log — which
# reads exactly like "the code POSTed nothing", i.e. it would have passed all four refusal
# assertions while proving nothing at all. (It did, on this file's first run.)
STUB_DETAIL='{"rig_config":{}}'
APPLY_LOG="$(mktemp)"
trap 'rm -f "$APPLY_LOG"' EXIT

applies() { cat "$APPLY_LOG"; }
reset_applies() { : >"$APPLY_LOG"; }

# Serve STUB_DETAIL with a history that already carries a terminal row for every change_id the
# apply stub can mint, so the #185 assertion passes by default and can be failed deliberately below.
_worker_detail() {
    printf '%s' "$STUB_DETAIL" | jq -c --argjson h "$STUB_HISTORY" '.history = $h'
}
STUB_HISTORY='[{"change_id":"c-DONATION","status":"applied"},
               {"change_id":"c-watchdog_interval_min","status":"applied"},
               {"change_id":"c-pools","status":"applied"}]'

_worker_apply() { # <rig> <changes-json> — record it, then answer as a converging rig would
    printf '%s\n' "$2" >>"$APPLY_LOG"
    printf '{"status":"accepted","change_id":"c-%s"}' "$(printf '%s' "$2" | jq -r 'keys[0]')"
}
wait_for() { return 0; } # the rig converges; the timeout half is exercised explicitly below

# Drive something whose asserts are expected to red, without polluting this file's own verdict.
# Echoes "<passes>,<fails>" for the drive.
quietly() { # <cmd...>
    local p="$IT_PASS" f="$IT_FAIL" dp df
    "$@" >/dev/null 2>&1
    dp=$((IT_PASS - p))
    df=$((IT_FAIL - f))
    IT_PASS="$p"
    IT_FAIL="$f"
    printf '%s,%s' "$dp" "$df"
}

# Drive something and echo its STDERR — where it_warn writes. Asserting a guard on the one sentence
# only IT writes is the difference between testing a guard and testing a grep: two guards sharing an
# output string silently cover for each other's deletion.
drive_err() { # <cmd...>
    local p="$IT_PASS" f="$IT_FAIL" err
    err="$("$@" 2>&1 >/dev/null)"
    IT_PASS="$p"
    IT_FAIL="$f"
    printf '%s' "$err"
}

echo "== _rig_config_key: a falsy value is a VALUE, not a miss =="
# DONATION is 0 on the bench rig, so this is the shape the headline leg actually reads.
d='{"rig_config":{"DONATION":0,"autotune":"disabled","watchdog_interval_min":5}}'
assert_eq "DONATION=0 reads back as the value 0" "$(_rig_config_key "$d" DONATION)" "0"
# The control that kills `.rig_config[$k] // empty`. It has to be `false`, not `0`: jq's `//` passes
# a 0 through unharmed, so a 0-based control would pass against BOTH forms and prove nothing. The
# first draft of this file used exactly that control, called it a mutation-kill, and the mutation
# survived — a check whose control cannot fail is not a check.
assert_eq "a false value reads back as false, not as a missing key" \
    "$(_rig_config_key '{"rig_config":{"someflag":false}}' someflag)" "false"
assert_eq "a string key reads back as compact JSON, quotes included" \
    "$(_rig_config_key "$d" autotune)" '"disabled"'
assert_eq "a number key reads back unquoted" "$(_rig_config_key "$d" watchdog_interval_min)" "5"

echo "== _rig_config_key: 'could not read' and 'key absent' both read as empty =="
assert_eq "rig_config null (views.py: 'could not read', not empty) yields nothing" \
    "$(_rig_config_key '{"rig_config":null}' DONATION)" ""
assert_eq "a key this RigForge never sends yields nothing" \
    "$(_rig_config_key '{"rig_config":{"max_temp_c":100}}' DONATION)" ""
assert_eq "a detail body with no rig_config at all yields nothing" \
    "$(_rig_config_key '{"found":true}' DONATION)" ""

echo "== _pred_rig_config_key: matches on VALUE and TYPE, not on printed text =="
STUB_DETAIL='{"rig_config":{"watchdog_interval_min":5}}'
_pred_rig_config_key rig1 watchdog_interval_min 5
assert_eq "the rig reporting the wanted value satisfies the predicate" "$?" "0"
_pred_rig_config_key rig1 watchdog_interval_min 6
assert_eq "a different value does NOT satisfy it" "$?" "1"
# Kills a mutation to a text-y comparison (jq -r instead of jq -c): the rig reporting the STRING
# "5" is not the rig reporting the NUMBER 5, and a control path that cannot tell them apart would
# call a rejected string-typed apply "applied".
STUB_DETAIL='{"rig_config":{"watchdog_interval_min":"5"}}'
_pred_rig_config_key rig1 watchdog_interval_min 5
assert_eq "a string \"5\" does not satisfy a wanted number 5" "$?" "1"
STUB_DETAIL='{"rig_config":null}'
_pred_rig_config_key rig1 watchdog_interval_min 5
assert_eq "an unreadable rig_config does not satisfy it (never treat 'cannot read' as 'matches')" "$?" "1"

echo "== _settle_worker_apply_key: fast path (already terminal) =="
res='{"status":"applied","changed_keys":["DONATION"],"change_id":"c1"}'
assert_eq "an immediate 'applied' passes through untouched" \
    "$(_settle_worker_apply_key rig1 DONATION 1 "$res")" "applied|DONATION|c1"

echo "== _settle_worker_apply_key: RigForge #344 async apply (#1309), generic over the key =="
# The load-bearing mutation-kill, inherited from #1309: reading `status` verbatim instead of
# settling would leave every leg at "accepted|" with no changed_keys — 4 reds per key.
res='{"status":"accepted","change_id":"c2"}'
wait_for() { return 0; }
assert_eq "'accepted' that converges settles to 'applied' + the requested key" \
    "$(_settle_worker_apply_key rig1 watchdog_interval_min 6 "$res")" "applied|watchdog_interval_min|c2"

echo "== _settle_worker_apply_key: a change that never lands must NOT read as success =="
res='{"status":"accepted","change_id":"c3"}'
wait_for() { return 1; }
assert_eq "'accepted' that never converges stays 'accepted' (fails the caller's assert_eq)" \
    "$(_settle_worker_apply_key rig1 DONATION 1 "$res")" "accepted||c3"

echo "== _settle_worker_apply_key: a pre-dial reject survives the '|' split with an empty middle =="
res='{"status":"rejected","error":"nope"}'
IFS='|' read -r rstatus rckeys rchange_id <<<"$(_settle_worker_apply_key rig1 DONATION 1 "$res")"
assert_eq "empty middle field (ckeys) does not shift change_id left" \
    "$rstatus,$rckeys,$rchange_id" "rejected,,"
wait_for() { return 0; }

echo "== _writable_key_round_trip: the probe and the revert are both real, well-formed applies =="
STUB_DETAIL='{"rig_config":{"DONATION":1}}'
reset_applies
counts="$(quietly _writable_key_round_trip rig1 DONATION 0 1)"
assert_eq "a clean round trip passes all four of its assertions" "$counts" "4,0"
assert_eq "exactly two applies: the probe and the revert" "$(applies | grep -c .)" "2"
assert_eq "the probe carries the probe value" "$(applies | sed -n 1p)" '{"DONATION":1}'
assert_eq "the revert carries the ORIGINAL value" "$(applies | sed -n 2p)" '{"DONATION":0}'

echo "== _writable_key_round_trip: a history row still 'accepted' is NOT a pass (#185/#579) =="
# The rig converged, so the settle says applied — but the dashboard never reconciled that change_id's
# history row. Kills the temptation to drop the history assertion as redundant with the settle: they
# read two different surfaces, and #579/#604 is the regression where only the second one moved.
STUB_HISTORY='[{"change_id":"c-DONATION","status":"accepted"}]'
reset_applies
counts="$(quietly _writable_key_round_trip rig1 DONATION 0 1)"
assert_eq "an unreconciled #185 row reds exactly one assertion" "$counts" "3,1"
STUB_HISTORY='[{"change_id":"c-DONATION","status":"applied"},
               {"change_id":"c-watchdog_interval_min","status":"applied"},
               {"change_id":"c-pools","status":"applied"}]'

echo "== _writable_key_round_trip: a failing probe must still RESTORE the rig =="
# The property that matters on borrowed hardware: this runs against a production miner on loan, so
# a mid-leg red must not strand it on a probe value. Kills the natural refactor — an early `return`
# once the apply assertion fails — which would leave DONATION raised and nothing would say so.
STUB_DETAIL='{"rig_config":{"DONATION":0}}' # the rig never reports the probe
STUB_HISTORY='[]'                           # ...and nothing was ever recorded for it either
reset_applies
wait_for() { return 1; } # ...so every settle times out and every assert reds
counts="$(quietly _writable_key_round_trip rig1 DONATION 0 1)"
wait_for() { return 0; }
assert_eq "a probe that never lands reds every assertion in the leg (0 passes)" "$counts" "0,4"
assert_eq "the revert was still POSTed after the failures" "$(applies | sed -n 2p)" '{"DONATION":0}'
STUB_HISTORY='[{"change_id":"c-DONATION","status":"applied"},
               {"change_id":"c-watchdog_interval_min","status":"applied"},
               {"change_id":"c-pools","status":"applied"}]'

echo "== run_rigforge_writable_keys: DONATION only ever moves TOWARD zero =="
# A rig already donating is nudged DOWN to 0, never up: the probe can only reduce what a borrowed
# rig gives away. Only a rig at 0 is nudged to 1 (RigForge's own default). Kills a fixed `orig+1`.
STUB_DETAIL='{"rig_config":{"DONATION":5,"watchdog_interval_min":5}}'
reset_applies
quietly run_rigforge_writable_keys rig1 >/dev/null
assert_eq "a rig donating 5 is probed DOWN to 0" "$(applies | sed -n 1p)" '{"DONATION":0}'
assert_eq "and restored to 5" "$(applies | sed -n 2p)" '{"DONATION":5}'

STUB_DETAIL='{"rig_config":{"DONATION":0,"watchdog_interval_min":5}}'
reset_applies
quietly run_rigforge_writable_keys rig1 >/dev/null
assert_eq "a rig donating 0 is probed to RigForge's default 1" \
    "$(applies | sed -n 1p)" '{"DONATION":1}'
assert_eq "and restored to 0" "$(applies | sed -n 2p)" '{"DONATION":0}'

echo "== run_rigforge_writable_keys: watchdog_interval_min stays inside RigForge's 1-1440 =="
assert_eq "a mid-range interval steps up" "$(applies | sed -n 3p)" '{"watchdog_interval_min":6}'
assert_eq "and is restored" "$(applies | sed -n 4p)" '{"watchdog_interval_min":5}'
# Kills a bare `orig+1`, which would POST 1441 and take a real rejected from the rig (rigforge.sh:556).
STUB_DETAIL='{"rig_config":{"DONATION":0,"watchdog_interval_min":1440}}'
reset_applies
quietly run_rigforge_writable_keys rig1 >/dev/null
assert_eq "a rig already at the 1440 ceiling steps DOWN instead" \
    "$(applies | sed -n 3p)" '{"watchdog_interval_min":1439}'

echo "== run_rigforge_writable_keys: an out-of-contract value FAILS, it does not get written back =="
# A rig reporting a nonsense interval is a real finding, not something to round-trip politely.
STUB_DETAIL='{"rig_config":{"DONATION":0,"watchdog_interval_min":0}}'
reset_applies
counts="$(quietly run_rigforge_writable_keys rig1)"
assert_eq "an interval outside 1-1440 reds, and only it (the DONATION leg is unaffected)" "$counts" "4,1"
assert_eq "and no watchdog_interval_min apply was POSTed at all" \
    "$(applies | grep -c watchdog_interval_min)" "0"

echo "== run_rigforge_writable_keys: THE REFUSALS, asserted as behaviour =="
# autotune, watchdog and a self-derived pools are refused for reasons in the module header — a real
# tuning run, removing thermal protection from a rig at max_temp_c=100, and a credential-stripped
# pools value that cannot be written back without stranding the rig (#113 stratum auth). A comment
# cannot enforce any of that. These assertions can: if someone adds a leg for one of them, the
# payload log grows a key it must never contain, and this reds.
STUB_DETAIL='{"rig_config":{"pools":[{"url":"a:1"},{"url":"b:2"}],"DONATION":0,"autotune":"disabled","watchdog":"enabled","watchdog_interval_min":5,"max_temp_c":100}}'
reset_applies
unset IT_RIG_POOLS_PROBE
quietly run_rigforge_writable_keys rig1 >/dev/null
assert_eq "autotune is never applied — it would start a real tuning run" \
    "$(applies | grep -c autotune)" "0"
assert_eq "watchdog is never applied — it would drop thermal protection" \
    "$(applies | grep -cw '"watchdog"')" "0"
assert_eq "pools is never derived from the rig's own credential-stripped read (#113)" \
    "$(applies | grep -c pools)" "0"
assert_eq "max_temp_c is not duplicated here — the #513 leg already round-trips it" \
    "$(applies | grep -c max_temp_c)" "0"
assert_eq "only DONATION and watchdog_interval_min are driven (2 keys, 4 applies)" \
    "$(applies | grep -c .)" "4"

echo "== run_rigforge_writable_keys: an unreadable rig skips LOUDLY and writes nothing =="
STUB_DETAIL='{"rig_config":null}'
reset_applies
counts="$(quietly run_rigforge_writable_keys rig1)"
assert_eq "a rig whose config could not be read produces no passes and no fails" "$counts" "0,0"
assert_eq "and nothing is POSTed to it" "$(applies | grep -c .)" "0"
# Counters alone cannot tell the up-front guard from the per-key skips falling through one by one —
# both are silent and both POST nothing, so deleting the guard outright left this section green.
# Assert it on the one sentence ONLY it writes, and assert the other guards' sentence is ABSENT.
err="$(drive_err run_rigforge_writable_keys rig1)"
assert_contains "the up-front 'could not read' guard is what refused it, in its own words" \
    "$err" "reports no writable config"
assert_eq "the per-key skips did not fire (they would misreport a silent rig as one that answered)" \
    "$(printf '%s' "$err" | grep -c 'skipping that leg')" "0"

echo "== run_rigforge_pools: still operator-gated, and it restores from last_applied =="
STUB_DETAIL='{"rig_config":{"pools":[{"url":"stripped:1"}]},"last_applied":{"pools":[{"url":"real:1","pass":"secret"}]}}'
reset_applies
unset IT_RIG_POOLS_PROBE
counts="$(quietly run_rigforge_pools rig1)"
assert_eq "no IT_RIG_POOLS_PROBE: the leg self-skips, no pass and no fail" "$counts" "0,0"
assert_eq "and POSTs nothing" "$(applies | grep -c .)" "0"

export IT_RIG_POOLS_PROBE='[{"url":"probe:1"}]'
reset_applies
quietly run_rigforge_pools rig1 >/dev/null
# The load-bearing half: the restore target is last_applied (which still carries `pass`), NEVER the
# rig's own .rig_config.pools, which arrives with `pass` and `tls-fingerprint` deleted twice over.
assert_eq "the restore uses last_applied, credential intact" \
    "$(applies | sed -n 2p)" '{"pools":[{"url":"real:1","pass":"secret"}]}'
assert_eq "the restore is NOT the rig's credential-stripped self-read" \
    "$(applies | grep -c 'stripped:1')" "0"

export IT_RIG_POOLS_PROBE='not json'
reset_applies
counts="$(quietly run_rigforge_pools rig1)"
assert_eq "a malformed probe reds rather than being POSTed at a rig" "${counts#*,}" "1"
assert_eq "and nothing is POSTed" "$(applies | grep -c .)" "0"
unset IT_RIG_POOLS_PROBE

echo ""
echo "selftest-rigforge-writable-keys: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
