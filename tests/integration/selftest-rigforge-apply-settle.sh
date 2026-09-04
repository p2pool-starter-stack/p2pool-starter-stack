#!/usr/bin/env bash
#
# Self-test for _settle_worker_apply_maxt (#1309): the worker-apply "accepted" (RigForge #344
# async apply) settle-to-terminal logic run.sh's #513 reversible-edit legs use. Standalone (not
# sourced by selftest.sh) so it never touches selftest.sh's own file-budget ceiling — same
# reasoning as selftest-compose-profiles.sh (#1301). Run directly, or via
# `make test-integration-selftest` (which runs this after selftest.sh). No server needed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/rigforge-apply-settle.sh
source "$HERE/rigforge-apply-settle.sh"

echo "== _settle_worker_apply_maxt: fast path (already terminal) =="
res='{"status":"applied","changed_keys":["max_temp_c"],"change_id":"c1"}'
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "an immediate 'applied' passes through untouched" "$out" "applied|max_temp_c|c1"

echo "== _settle_worker_apply: wait_for's banner must not reach the RESULT (#1454) =="
# The one case in this file that does NOT stub wait_for, and that is the whole point. Every other
# case replaces it with a silent `return 0` / `return 1`, and that silence is what let #1454 ship:
# the real wait_for opens with an it_step banner on stdout, and this function's stdout is its
# return value. Drop the `>&2` in rigforge-apply-settle.sh and the capture becomes two lines, so
# `read` takes the banner as $status — the exact four reds the 2026-08-28 gate run printed.
# Driven through the generic _settle_worker_apply with a trivially-true predicate so it stays
# hermetic (no dashboard, no rig) while still running the genuine lib.sh wait_for.
_pred_settles_now() { return 0; }
res='{"status":"accepted","change_id":"c-banner"}'
out="$(_settle_worker_apply max_temp_c "the rig to report max_temp_c=101 applied" "$res" _pred_settles_now)"
assert_eq "the settle's stdout is the result and nothing else" "$out" "applied|max_temp_c|c-banner"
# Second conjunct, and a DIFFERENT mechanism on purpose: the wrong fix for the above is to delete
# the banner from wait_for, which would silence progress reporting for every other wait in the
# harness. Assert it is still emitted — on stderr, where wait_for's own timeout warning goes.
err="$(_settle_worker_apply max_temp_c "the rig to report max_temp_c=101 applied" "$res" _pred_settles_now 2>&1 >/dev/null)"
assert_contains "the progress banner is redirected, not deleted" "$err" "waiting for the rig to report max_temp_c=101 applied"

echo "== _history_row_status: the row is read by change_id, never 'the newest' (#1471) =="
# _worker_detail is the CALLER's, injected exactly like the readback predicates this module already
# takes as arguments; these cases supply it directly rather than through a rig or a server.
# The wanted row is deliberately NOT first, and the ordering is the whole case: with c-mine first
# a `first(.history[]?)` mutation — matching the newest row instead of the change_id — returns it
# anyway, and this assertion goes green against the very defect it names. The status values differ
# too, so the mutation is caught on the VALUE and not only on the row's absence.
STUB_HIST='[{"change_id":"c-newer","status":"failed"},{"change_id":"c-mine","status":"applied"}]'
_worker_detail() { printf '{"history":%s}' "$STUB_HIST"; }
assert_eq "the row for THIS change_id is read, not the newest one" \
    "$(_history_row_status r c-mine)" "applied"
assert_eq "a change_id with no row of its own reads back empty" \
    "$(_history_row_status r c-absent)" ""
STUB_HIST='null'
assert_eq "a detail body carrying no history at all reads back empty, not an error" \
    "$(_history_row_status r c-mine)" ""

echo "== _pred_history_row_terminal: terminal is the COMPLEMENT of accepted/absent (#1471) =="
STUB_HIST='[{"change_id":"c1","status":"accepted"}]'
_pred_history_row_terminal r c1
assert_eq "a still-'accepted' row is NOT terminal — that is the whole point of waiting" "$?" "1"
STUB_HIST='[]'
_pred_history_row_terminal r c1
assert_eq "no row yet is NOT terminal" "$?" "1"
STUB_HIST='[{"change_id":"c1","status":"applied"}]'
_pred_history_row_terminal r c1
assert_eq "'applied' is terminal" "$?" "0"
STUB_HIST='[{"change_id":"c1","status":"rejected"}]'
_pred_history_row_terminal r c1
assert_eq "'rejected' is terminal — a real refusal must not burn the 90s bound" "$?" "0"
# The complement form, asserted rather than assumed. #1009's vocabulary is six names TODAY, and the
# allowlist spelling of this predicate passes every case above while turning a newly added rig
# status into a 90s timeout reported as "the row never settled" — the wrong diagnosis, reached at
# the most expensive possible price. This is the case that kills that spelling.
STUB_HIST='[{"change_id":"c1","status":"quarantined"}]'
_pred_history_row_terminal r c1
assert_eq "a status this harness has never seen reads as terminal, not as 'keep waiting'" "$?" "0"

echo "== _settle_history_row: wait_for's banner must not reach the RESULT (#1454, #1471) =="
# The same trap as the settle above and for the same reason — this function's stdout is its return
# value, and the real wait_for opens with an it_step banner on stdout. Run with the GENUINE wait_for
# against a row that is already terminal, so it costs nothing: drop the `>&2` in
# rigforge-apply-settle.sh and this capture gains the banner as its first line.
STUB_HIST='[{"change_id":"c-t","status":"applied"}]'
assert_eq "the settle's stdout is the row status and nothing else" \
    "$(_settle_history_row r c-t)" "applied"

echo "== _settle_history_row: a row that goes terminal LATE is waited for (#1471) =="
# THE mutation-kill for #1471, and it drives the genuine lib.sh wait_for. Delete the wait from
# _settle_history_row and this reads "accepted" — which is exactly the race the issue documents:
# RigForge commits the new config at the START of a control-apply and writes the terminal status
# only at the END, after the miner restart, so the row is still "accepted" when the config settle
# that precedes this returns.
#
# The read counter is a FILE, not a shell variable, and that is load-bearing rather than a style
# choice: the call under test is captured with `$(...)`, so a stub counting into a variable would
# lose every increment to the command-substitution subshell and report "converged on the first
# read" — passing against BOTH the waited and the unwaited form, proving nothing. (The same lesson
# APPLY_LOG carries in selftest-rigforge-writable-keys.sh.)
TICKS="$(mktemp)"
trap 'rm -f "$TICKS"' EXIT
printf '1' >"$TICKS"
_worker_detail() { # "accepted" on the first read, "applied" from the second onwards
    local n
    n="$(cat "$TICKS")"
    printf '%s' $((n + 1)) >"$TICKS"
    if [ "$n" -ge 2 ]; then
        printf '{"history":[{"change_id":"c-late","status":"applied"}]}'
    else
        printf '{"history":[{"change_id":"c-late","status":"accepted"}]}'
    fi
}
assert_eq "a row still 'accepted' at settle time is waited to its terminal status" \
    "$(_settle_history_row r c-late)" "applied"
# Second conjunct, a DIFFERENT mechanism on purpose: the status assertion alone would also pass a
# function that read the row once and got lucky on ordering. The unwaited form reads exactly twice
# (predicate never runs; one read for the result); the waited form re-reads after the interval.
assert_num_ge "the wait re-read the row rather than settling on one look" "$(cat "$TICKS")" "3"
# What this case does NOT discriminate, said so it is not read as covering more than it does: a
# predicate that treats "accepted" as TERMINAL passes both assertions above. It returns on the
# first read, and the result read is then the second — the one that converges — so the status
# comes back "applied" for the wrong reason and the tick count still reaches 3. That mutation is
# owned by the "a still-'accepted' row is NOT terminal" case in the block above; delete that case
# and nothing here replaces it. Converging on the third read instead would cover it twice at the
# price of a second real interval, which is not worth paying for a mutation already killed.

echo "== _settle_history_row: a row that never settles must not read as 'applied' (#1471) =="
# The other half, stubbed rather than real so it costs nothing — the 90s bound is the function's
# point, not something to spend here. What must hold is that a timeout reports what the row is
# STUCK at: not empty, which would report a missing row for what is really an unsettled one, and
# never "applied", which would be #1471's false pass with extra steps. The section below re-stubs
# wait_for for its own case, so this stub does not reach it.
STUB_HIST='[{"change_id":"c-stuck","status":"accepted"}]'
_worker_detail() { printf '{"history":%s}' "$STUB_HIST"; }
wait_for() { return 1; }
assert_eq "a timed-out settle reports the status the row is stuck at, so the caller can name it" \
    "$(_settle_history_row r c-stuck)" "accepted"

echo "== _settle_worker_apply_maxt: RigForge #344 async apply (#1309) =="
# This is the load-bearing mutation-kill: if the "accepted is terminal" bug (#1309) were
# reintroduced — treating status verbatim instead of polling for it to settle — this would still
# read "accepted|" with no changed_keys, exactly the 4 reds the issue documents.
res='{"status":"accepted","change_id":"c2"}'
wait_for() { return 0; }
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "'accepted' that converges settles to 'applied' + the requested key" "$out" "applied|max_temp_c|c2"

echo "== _settle_worker_apply_maxt: timeout / real failure must NOT read as success =="
# Mutation proof, the other half: a change that genuinely never lands (broken apply path, or the
# #579 feed/reconciler regressed) must fail loudly, not silently pass as "applied" because we saw
# a "the change is at least accepted" event once.
res='{"status":"accepted","change_id":"c3"}'
wait_for() { return 1; }
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "'accepted' that never converges stays 'accepted' (fails the caller's assert_eq)" "$out" "accepted||c3"

echo "== _settle_worker_apply_maxt: a pre-dial reject carries no change_id/changed_keys =="
res='{"status":"rejected","error":"nope"}'
out="$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "rejected passes through with both trailing fields genuinely empty" "$out" "rejected||"

echo "== _settle_worker_apply_maxt: '|'-joined output survives an empty MIDDLE field =="
# The regression this delimiter choice guards: IFS=tab is bash's IFS-WHITESPACE class, so `read`
# SQUASHES a run of tabs instead of treating an empty middle field as a real field — a change_id
# with no changed_keys (exactly the "accepted"/"rejected" shapes above) would shift change_id into
# the ckeys variable instead of leaving it empty. Splits the REAL function's output with the SAME
# `IFS='|' read` run.sh's call sites use, so reverting the function to a tab-joined output (no '|'
# to split on at all) fails this: the whole string lands in rstatus instead of just "rejected".
IFS='|' read -r rstatus rckeys rchange_id <<<"$(_settle_worker_apply_maxt rig1 101 "$res")"
assert_eq "empty middle field (ckeys) does not shift change_id left" "$rstatus,$rckeys,$rchange_id" "rejected,,"

echo ""
echo "selftest-rigforge-apply-settle: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
