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
