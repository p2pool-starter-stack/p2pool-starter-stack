# shellcheck shell=bash
#
# Worker-config domain (#1105 Phase 1, develop-v2 lane): per-worker token masking and host-side
# restore, across the two config shapes that carry rig credentials. A per-rig token lives in a
# VARIABLE-LENGTH array, which puts it outside the fixed CONTROL_SECRET_PATHS walk that covers the
# scalar secrets, so each shape needs its own proof that the property still holds — the masked
# prefill copy must sentinel every set token rather than the first one, and the staging swap must
# restore each sentinel from the live token rather than committing the sentinel itself. The legacy
# dashboard.workers[] shape (#172/#679) and the workers.list[] shape (#506) are tested separately
# because they are read by different code paths, not because the property differs.
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS POSITION-LOCKED AND IS NOT SOURCEABLE ON ITS OWN — both deliberately. It inherits
# the control sandbox that run.sh's black-box control-channel run builds once and then mutates in
# a chain: $C and $CTRL_LOG come from lib.sh's build_control_sandbox, and $AUDIT, $MASKED, $REQS,
# $RESULTS and $STAGED from run.sh's own earlier sections. Nothing here builds a sandbox, and
# nothing here should. The sections commit through the real gate, so they write into the shared
# request spool and append to the shared audit log — and two sections that stay in run.sh AFTER
# this one count exactly that: "audit log growth is bounded (#349)" measures the audit log's
# length, and "spool intake cap + symlink refusal + stale sweep (#33 hardening)" asserts the
# request spool holds exactly ten overflow intents and then none. A fresh sandbox built here, or
# this file sourced at any other point in run.sh's order, moves those counts and reds two domains
# that never changed. Sourcing in place is what keeps them right, so the ordering is a contract
# rather than an accident, and it is stated here because a survived accident and an honoured
# contract look identical from a green suite.
#
# That is the same contract test-control-add-only-ssrf.sh already ships under: split out for the
# file-budget ratchet, inheriting the fixtures of the section it came from.
#
# Every other name the block reads it also assigns — the request UUIDs it drives the gate with are
# its own. From lib.sh it calls assert_eq, run_pending and run_sourced, and also ok and bad
# directly, inside the case blocks that check no secret leaked.
echo "== black-box: per-worker token mask + host-side restore, legacy dashboard.workers (#172/#679) =="
# dashboard.workers[].token is a per-rig credential living in a VARIABLE-LENGTH array — out of the
# fixed CONTROL_SECRET_PATHS walk. The masked prefill copy must sentinel each set token (extends
# the #440 property per-rig), and the staging swap must restore each sentinel from the LIVE token
# matched by worker NAME. Per-worker descriptors are never dashboard-EDITABLE (the commit gate
# refuses any dashboard.workers change, asserted above) — so this restore is exactly what lets an
# operator's OTHER edits round-trip: the workers come back as sentinels and must resolve to the
# live values unchanged, or every dashboard commit on a stack with configured workers would fail.
# Since #679 `apply` MIGRATES the legacy shape, so a live config carries dashboard.workers only
# between a hand-edit and the next apply — exactly the state the preview leg (a dry run, never
# migrates) still serves. Hand-edit to legacy and render the masked copy directly, no apply.
jq '.dashboard.workers=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}] | del(.workers.list)' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears,
#    and a token-less worker stays token-less.
assert_eq "per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less worker stays token-less in the masked copy" "$(jq -r '.dashboard.workers[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no per-worker token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no per-worker token" ;;
esac
# 2) staging swap: a proposal that prefills the workers from the masked copy (sentinel tokens) and
#    changes only an allowlisted key stages with each token restored from live BY NAME.
UUID6="66666666-6666-4666-8666-666666666666"
jq --arg id "$UUID6" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="main")}' "$MASKED" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "previewed"
assert_eq "per-worker sentinel restored to the live token by name" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second per-worker sentinel restored by name" "$(jq -r '.dashboard.workers[2].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig3secret"
assert_eq "token-less worker stays token-less at staging" "$(jq -r '.dashboard.workers[1] | has("token")' "$STAGED/$UUID6.json" 2>/dev/null)" "false"
case "$(cat "$RESULTS/$UUID6.json")$(cat "$AUDIT")" in
*tok_rig1secret* | *tok_rig3secret*) bad "results/audit stay free of the restored per-worker token" "a per-worker token leaked" ;;
*) ok "results/audit stay free of the restored per-worker token" ;;
esac
# 3) commit: workers restored to live == live, so the gate passes on the pool-only change; the
#    commit's `apply -y` then MIGRATES (#679) — the committed config keeps the live per-worker
#    tokens under workers.list[], the legacy key is gone, and the pre-migration copy sits beside.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID6" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live per-worker token (migrated to workers.list, #679)" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "commit migrated the legacy key away (#679)" "$(jq -r '.dashboard | has("workers")' "$C/config.json")" "false"
assert_eq "pre-migration copy kept through the control commit (#679)" "$(jq -r '.dashboard.workers[0].token' "$C/config.json.bak-workers" 2>/dev/null)" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
# 4) duplicate names resolve first-declared-wins (staging only — a duplicate can't round-trip a
#    commit, since the second entry's token would flip and trip the gate). Same hand-edited
#    legacy state as above: masked copy rendered directly, no apply, so no migration yet.
jq 'del(.workers.list) | .dashboard.workers=[{name:"rig1",host:"10.0.0.5",token:"tok_first"},{name:"rig1",token:"tok_second"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
UUID7="77777777-7777-4777-8777-777777777777"
jq --arg id "$UUID7" '{id:$id, action:"preview", actor:"admin", config: .}' "$MASKED" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "duplicate-name sentinel restores the first-declared token" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"
assert_eq "duplicate-name second entry also resolves to first-declared" "$(jq -r '.dashboard.workers[1].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"

echo "== black-box: per-worker token mask + host-side restore, workers.list[] shape (#506) =="
# Same mask/restore/commit round-trip as above, but on the CURRENT workers.list[] shape — proves
# render_masked_config and the control_preview sentinel swap key off whichever shape the live
# config actually uses, not a hardcoded dashboard.workers path. Clear the legacy key first so the
# live config carries only the new shape (both-set is refused at apply, asserted earlier).
jq 'del(.dashboard.workers) | .workers.list=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears.
assert_eq "workers.list token masked to the sentinel" "$(jq -c '.workers.list[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second workers.list token masked to the sentinel" "$(jq -c '.workers.list[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less workers.list worker stays token-less in the masked copy" "$(jq -r '.workers.list[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no workers.list token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no workers.list token" ;;
esac
# 2) staging swap: a proposal that prefills from the masked copy stages with each token restored
#    from live BY NAME.
UUID8="88888888-8888-4888-8888-888888888888"
jq --arg id "$UUID8" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="nano")}' "$MASKED" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "previewed"
assert_eq "workers.list sentinel restored to the live token by name" "$(jq -r '.workers.list[0].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second workers.list sentinel restored by name" "$(jq -r '.workers.list[2].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig3secret"
# 3) commit: workers.list restored to live == live, so the gate passes on the pool-only change, and
#    the committed config KEEPS the live per-worker tokens.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID8" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live workers.list token" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
