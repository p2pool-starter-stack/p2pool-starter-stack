# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel spool + audit hardening domain (#1105 Phase 1, appliance lane): the sections
# that prove the control channel's own storage cannot be grown without bound by a caller. The
# audit log is trimmed to its newest entries BEFORE an append once it passes the size cap, so the
# file shrinks instead of growing forever and the fresh entry is always last (#349); and the
# request spool enforces an intake cap per run, refuses symlinked intents, and sweeps stale ones,
# with the overflow left for the next run to drain (#33 hardening).
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS DELIBERATELY NOT STANDALONE-SOURCEABLE, AND THAT IS THE CORRECT CALL HERE.
# It follows the shipped add-only-ssrf disclosure precedent — source in place, position-locked,
# dependency disclosed here — rather than the self-arm pattern most domain files use. "It should
# self-arm like its neighbours" is the obvious review note and it is wrong for this domain:
#
# - This domain is a pure CONSUMER of the control sandbox. It never calls build_control_sandbox();
#   test-control-core.sh calls it once, in the control-core domain sourced ahead, and $C reaches
#   here from it.
#   (That section lived in run.sh until #1105 R12 moved it into its own domain file.)
# - This domain is position-locked by EXECUTION ORDER relative to the sibling sections that
#   accumulate what it counts, not by anything a second builder call would overwrite. Calling
#   build_control_sandbox() here would be harmless, and that is why it buys
#   nothing: $C is the fixed path "$SANDBOX/control", its mkdir -p only creates, its copies are
#   static inputs, and seed_control_env/control_config are DEFINED inside it and never called — so
#   the builder writes no config.json and touches nothing under data/control/{requests,staged,
#   results,audit}. It could not establish the state this domain depends on, only running in
#   position after the sections that accumulate it can.
#   Every assertion here is a COUNT against an exact number — audit lines and bytes either side of
#   a trim, spool files left after a capped run, then zero after the next drain — taken against the
#   shared spool and audit log this run has accumulated. Run out of position it would be counting a
#   spool nothing had written to yet.
#   The coupling that DOES bite here is write-side, and it has a recorded firing: the rig-worker
#   token-mask cluster moved with a re-derived $C, its applies wrote EXTRA result files into the
#   shared results dir, and a still-in-run.sh assertion counting that dir went red. That is
#   pollution of a counted directory — a different mechanism from anything being reset.
#   This domain is the counting side of that same rule.
#   RETRACTED (#1105 R12): that firing's stated MECHANISM does not reproduce at the tip — the
#   apply path writes nothing into results/ unless is_appliance(), which no sandbox run
#   satisfies. The RED was real; WHY is not established, and the full re-derivation is in
#   test-rig-worker.sh's header. This domain's position-lock rests on what it READS, not on it.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $REQS, $RESULTS, $STAGED and $AUDIT are NOT the builder's. They are assigned by the
#   control-run-pending section, in test-control-core.sh, sourced before this stanza — an ordering
#   dependency, same class as any other. They are deliberately NOT seeded here: each is a plain
#   derivation from $C, so a seed would duplicate that file's definitions and could drift from them,
#   and it would buy nothing, because $C itself keeps this file non-standalone either way.
# - $UUID5 IS INHERITED FROM ANOTHER DOMAIN — the approval-gate section assigns it, and this
#   domain reuses that id to post an intent. It is not assigned anywhere in the moved text.
#   (That section lived in run.sh until #1105 R13 reunited it into test-control-add-only-ssrf.sh,
#   whose stanza run.sh still sources ahead of this one.) This is the ambient ordering dependency
#   in its plainest form: nothing about the moved text reveals it, and only the whole-file
#   read-versus-assign audit surfaces it.
# - $UUID4, $out, $audit_lines and $audit_size are assigned HERE, in the moved text.
# - This domain reads NO $WALLET at all, unlike the two sibling domains split out beside it.
#   That is recorded because it was CHECKED rather than assumed: an absence deserves the same
#   whole-file audit as a presence, and `/usr/bin/grep WALLET` over this file, comments
#   stripped, returns nothing.
# - Every provider function this domain calls is top-level in lib.sh: assert_eq, assert_contains,
#   run_pending, and ok/bad beneath the assertions. It calls none of the three functions nested
#   inside the sandbox builders (seed_env, seed_control_env, control_config), so unlike the two
#   sibling domains in this cut its dependency is in variables only. It defines no functions.
#
# The source stanza sits at this block's own vacated position — after the masking domain, before
# the control-deploy stanza — so every count is taken against exactly the spool and audit state it
# was always taken against. The anchor is a correctness requirement in this cut, not a preference.
#
# The guard below is the ambient contract made executable: sourced out of position, this file
# stops on a named variable instead of counting an unbuilt spool and passing.
: "${C:?}" "${UUID5:?}" "${REQS:?}" "${RESULTS:?}" "${STAGED:?}" "${AUDIT:?}"

echo "== black-box: audit log growth is bounded (#349) =="
# Seed the log past the 512 KiB cap, then let the runner audit one more event: the writer trims
# to the newest 2000 lines BEFORE appending, so the file shrinks instead of growing forever and
# the fresh entry is always the last line.
for _ in $(seq 1 6000); do
    printf '{"ts":"old","id":"","actor":"filler","action":"preview","status":"previewed","keys":""}\n'
done >>"$AUDIT"
[ "$(wc -c <"$AUDIT" | tr -d ' ')" -gt 524288 ] || bad "audit log seeded past the cap" "seed too small"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json" # no staged intent -> rejected, still audited
run_pending >/dev/null
audit_size="$(wc -c <"$AUDIT" | tr -d ' ')"
if [ "$audit_size" -lt 300000 ]; then
    ok "audit log trimmed back under the cap ($audit_size bytes)"
else
    bad "audit log trimmed back under the cap" "$audit_size bytes"
fi
assert_eq "trim keeps the newest entries (fresh entry is the last line)" "$(tail -n 1 "$AUDIT" | jq -r '.action')" "commit"
# Pin the line count too, not just the byte size: control_audit trims to `tail -n 2000` BEFORE
# appending the triggering entry, so the file must land at <= 2001 lines (2000 kept + the new one) —
# the "newest ~2000 lines" behavior the byte-size check above doesn't directly prove.
audit_lines="$(wc -l <"$AUDIT" | tr -d ' ')"
if [ "$audit_lines" -le 2001 ]; then
    ok "audit log trim caps the line count near the newest 2000 entries ($audit_lines lines)"
else
    bad "audit log trim caps the line count near the newest 2000 entries" "$audit_lines lines"
fi

echo "== black-box: spool intake cap + symlink refusal + stale sweep (#33 hardening) =="
UUID4="44444444-4444-4444-8444-444444444444"
# Oversized intent: refused BEFORE jq parses it (bounded root-runner DoS), no result addressed.
: >"$AUDIT"
{
    printf '{"id":"%s","action":"preview","pad":"' "$UUID4"
    head -c 70000 /dev/zero | tr '\0' a
    printf '"}\n'
} >"$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "oversized intent refused before parsing" "$(cat "$AUDIT" 2>/dev/null)" "refused-oversize"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "oversized intent gets no result file" || bad "oversized intent gets no result file" "result written"
[ ! -f "$REQS/$UUID4.json" ] && ok "oversized intent claimed out of requests/" || bad "oversized intent claimed out of requests/" "still present"
# Symlinked request: a symlink dropped in requests/ could point the root runner at any host file —
# refused, never followed (graft #437).
: >"$AUDIT"
ln -s "$C/config.json" "$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "symlinked request refused" "$(cat "$AUDIT" 2>/dev/null)" "refused-nonregular"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "symlinked request gets no result" || bad "symlinked request gets no result" "result written"
rm -f "$REQS/$UUID4.json"
# Stale sweep: staged/ + requests/ files older than an hour are removed at run start.
jq -n '{}' >"$STAGED/stale.json"
touch -t 202001010000 "$STAGED/stale.json"
printf '{}' >"$REQS/stale-req.json"
touch -t 202001010000 "$REQS/stale-req.json"
run_pending >/dev/null
[ ! -f "$STAGED/stale.json" ] && ok "aged staged file swept" || bad "aged staged file swept" "still present"
[ ! -f "$REQS/stale-req.json" ] && ok "aged request file swept" || bad "aged request file swept" "still present"
# Orphaned claim sweep (#548): a `.claim.<pid>` left behind by a runner that died mid-dispatch
# (the errexit gap this issue closes) is swept the same way as stale staged/request files.
touch -t 202001010000 "$C/data/control/.claim.12345"
run_pending >/dev/null
[ ! -f "$C/data/control/.claim.12345" ] && ok "stale orphaned claim swept" || bad "stale orphaned claim swept" "still present"
# Per-run intake cap: 60 pending intents → one run claims exactly 50 and LEAVES the remainder in
# requests/ for the next path-unit fire (deterministic overflow — nothing is dropped). Invalid
# JSON bodies keep each of the 60 on the cheap discard path; they still count against the cap.
for i in $(seq 1 60); do printf 'notjson' >"$REQS/cap-$i.json"; done
out="$(run_pending)"
assert_contains "per-run cap announced after 50 intents" "$out" "per-run cap"
assert_contains "exactly 50 intents processed in one run" "$out" "Processed 50 control request(s)"
assert_eq "overflow intents left for the next run" "$(ls "$REQS" | wc -l | tr -d ' ')" "10"
out="$(run_pending)"
assert_contains "next run drains the remainder" "$out" "Processed 10 control request(s)"
assert_eq "spool empty after the second run" "$(ls "$REQS" | wc -l | tr -d ' ')" "0"
