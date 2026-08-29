# shellcheck shell=bash
#
# Control-channel confirm-gate domain (#1105 Phase 1, develop-v2 lane): the sections that prove an
# in-scope disruptive change cannot land on a plain commit, and that the typed APPLY token which
# unlocks it is scoped to the change itself rather than to the perimeter. A disruptive edit staged
# without the token is held; the same edit with the typed APPLY applies; and with that token in
# hand a DEST-flagged perimeter change — clearnet exposure, a prune disable — is still refused
# (#719, with #713's refusal wording naming the host apply path rather than the stale #338).
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS DELIBERATELY NOT STANDALONE-SOURCEABLE, AND THAT IS THE CORRECT CALL HERE.
# It follows the shipped add-only-ssrf disclosure precedent — source in place, position-locked,
# dependency disclosed here — rather than the self-arm pattern most domain files use. "It should
# self-arm like its neighbours" is the obvious review note and it is wrong for this domain:
#
# - This domain is a pure CONSUMER of the control sandbox. It never calls build_control_sandbox();
#   run.sh calls that builder once, in a control-core section that stays behind, and $C, $CTRL_LOG
#   and $WALLET reach here from it.
# - This domain is position-locked by what it READS, not by anything a second builder call would
#   overwrite. Calling build_control_sandbox() here would be harmless, and that is why it buys
#   nothing: $C is the fixed path "$SANDBOX/control", its mkdir -p only creates, its copies are
#   static inputs, and seed_control_env/control_config are DEFINED inside it and never called — so
#   the builder writes no config.json and touches nothing under data/control/{requests,staged,
#   results,audit}. It could not establish the state this domain depends on, only running in
#   position after the sections that accumulate it can.
#   This domain drives the control channel repeatedly through `pithead apply -y` and run_pending
#   against the shared spool, and it opens by establishing a clean applied baseline that its own
#   later assertions and the sections after it read back.
#   The coupling that DOES bite here is write-side, and it has a recorded firing: the rig-worker
#   token-mask cluster moved with a re-derived $C, its applies wrote EXTRA result files into the
#   shared results dir, and a still-in-run.sh assertion counting that dir went red. That is
#   pollution of a counted directory — a different mechanism from anything being reset.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $REQS, $RESULTS, $STAGED and $AUDIT are NOT the builder's. They are assigned by the
#   control-run-pending section, which stays in run.sh and runs before this stanza — an ordering
#   dependency, same class as any other. They are deliberately NOT seeded here: each is a plain
#   derivation from $C, so a seed would duplicate run.sh's definitions and could drift from them,
#   and it would buy nothing, because $C itself keeps this file non-standalone either way.
# - $WALLET is NOT a top-level constant, and getting that right matters here. lib.sh assigns it
#   only INSIDE the two sandbox builders, as WALLET="${WALLET:-$VALID_PRIMARY}", and run.sh never
#   assigns it at all — so $WALLET reaches this domain from the same build_control_sandbox call
#   that provides $C, by the same ordering dependency, and belongs in the disclosure above rather
#   than filed as a constant. A defaulting fix retires a coupling only for CALLERS, and a split
#   manufactures non-callers.
# - $VALID_TARI is a lib.sh top-level constant, assigned at column one outside every function.
# - THE DEPENDENCY IS ALSO IN FUNCTION FORM, not only in variables. control_config() is not a
#   top-level lib.sh function: it is defined INSIDE build_control_sandbox(), so it does not exist
#   until that builder has run. This domain calls it, which is a second, independent reason the
#   file cannot stand alone — and one a variable-only sweep cannot see. The other provider
#   functions it calls are top-level: assert_eq, assert_contains, run_pending, and ok/bad beneath
#   the assertions. It does NOT call seed_env or seed_control_env.
# - preview_clearnet() is defined in the moved text and is not unset at its end, so it outlives
#   the source exactly as it outlived its old position in run.sh. No other file under tests/stack/
#   uses that name, so nothing downstream can see a definition it did not see before.
# - $UUID3 is assigned HERE, in the moved text. It is READ BY test-data-management.sh, whose
#   stanza run.sh sources immediately after this one — a dependency this split creates, disclosed
#   on both sides and guarded there.
#
# The source stanza sits at this block's own vacated position, so every assertion runs in the
# order it always ran, and the applied baseline this domain leaves behind still reaches the
# sections that follow it. The anchor is a correctness requirement in this cut, not a preference.
#
# The guard below is the ambient contract made executable: sourced out of position, this file
# stops on a named variable instead of degrading into assertions against an unbuilt sandbox.
: "${C:?}" "${CTRL_LOG:?}" "${WALLET:?}" "${VALID_TARI:?}" "${REQS:?}" "${RESULTS:?}" "${STAGED:?}" "${AUDIT:?}"

echo "== black-box: confirm-gate — an in-scope disruptive change needs a typed APPLY (#719) =="
UUID3="33333333-3333-4333-8333-333333333333"
# Clean baseline: pool mini, clearnet off, applied.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# Candidate turns on Monero clearnet initial sync — describe_change flags this CONFIRM (#719): an
# in-scope disruptive change (host IP exposed during IBD), confirm-gated rather than host-only DEST.
preview_clearnet() {
    jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",clearnet_initial_sync:true},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
    run_pending >/dev/null
}
preview_clearnet
assert_eq "confirm-gated candidate previews destructive:true" "$(jq -r '.destructive' "$RESULTS/$UUID3.json" 2>/dev/null)" "true"
assert_contains "confirm-gated preview carries a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID3.json" 2>/dev/null)" "CONFIRM"
# Commit WITHOUT the typed confirmation is refused — and points at the confirm step, NOT a flat
# host-only #338 refusal. The in-scope change is NOT hard-refused; it just needs the acknowledgement.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit without a token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "refusal asks for the typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "type APPLY"
assert_eq "unconfirmed commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# A WRONG token is refused too — only the exact literal proceeds.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"apply"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with the wrong token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_eq "wrong-token commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# Commit WITH the exact typed APPLY proceeds and lands the change.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "confirmed change landed in config.json" "$(jq -r '.monero.clearnet_initial_sync' "$C/config.json")" "true"
# The audit log records it AS a dashboard-confirmed destructive change (#719): the distinct
# commit-confirmed action, carrying the changed key NAME (never a value).
assert_contains "confirmed commit audits as commit-confirmed with the key name" \
    "$(grep '"action":"commit-confirmed","status":"applied"' "$AUDIT" | tail -n 1)" "MONERO_CLEARNET_SYNC"

echo "== black-box: the typed APPLY does NOT unlock the perimeter — DEST stays host-only (#719) =="
# Type-to-confirm is UX friction, not a security control: it must never carry a PERIMETER change.
# (a) A perimeter key that never touches an allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND,
# DEST) is refused even WITH the token, on the security-sensitive gate.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "perimeter RPC-LAN change is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "perimeter refusal is the security-sensitive gate, not the confirm step" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "security-sensitive"
assert_eq "perimeter change did not touch config.json" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
# (b) A confirm-KEY in its HEAVY direction (monero.prune DISABLE → full re-sync) still emits DEST
# and is refused even WITH the token — the confirm allowlist is not a blanket unlock for the key.
jq -n --arg w "$WALLET" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "prune DISABLE is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
# #713 removed the stale #338 reference from the destructive refusal; it now names the host path.
assert_contains "prune-disable refusal names the host apply path, not stale #338 (#713)" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "Edit config.json on the host"
assert_eq "prune stays enabled after the refusal" "$(jq -r '.monero.prune' "$C/config.json")" "true"
[ ! -f "$STAGED/$UUID3.json" ] && ok "refused destructive intent cleared from staged" || bad "refused destructive intent cleared from staged" "still staged"
