# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel secrets-masking domain (#1105 Phase 1, appliance lane): the four sections that
# prove a secret never leaves the host in the clear. The pre-masked prefill copy and the host-side
# secret merge the dashboard container reads instead of the raw config.json (#440), the per-field
# .env line-injection guard (#33 hardening), the client-auth requirement on a published onion
# (#33 hardening), and telegram.control failing closed on each of its legs (#521).
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS DELIBERATELY NOT STANDALONE-SOURCEABLE, AND THAT IS THE CORRECT CALL HERE.
# It follows the shipped add-only-ssrf disclosure precedent — source in place, position-locked,
# dependency disclosed here — rather than the self-arm pattern most domain files use. "It should
# self-arm like its neighbours" is the obvious review note and it is wrong for this domain:
#
# - This domain is a pure CONSUMER of the control sandbox. It never calls build_control_sandbox();
#   test-control-core.sh calls it once, in the control-core domain sourced ahead, and $C and
#   $CTRL_LOG reach here from it.
#   (That section lived in run.sh until #1105 R12 moved it into its own domain file.)
# - Self-arming would BUILD A SECOND SANDBOX, and that is the defect, not the fix. This domain
#   drives the control channel repeatedly through `pithead apply -y` and run_pending, and sections
#   that run AFTER this one, both in test-spool-audit.sh, count that shared state exactly — the
#   audit log by line count, the request spool by file count, each against an exact expected
#   number. A fresh $C would
#   send these writes to a different results dir than those counters read. That is coupling rule A,
#   and it has a recorded firing: the rig-worker token-mask cluster moved with a re-derived $C, its
#   applies wrote extra result files into the shared results dir, and a still-in-run.sh assertion
#   counting that dir went red.
#   RETRACTED (#1105 R12): that firing's stated MECHANISM does not reproduce at the tip — the
#   apply path writes nothing into results/ unless is_appliance(), which no sandbox run
#   satisfies. The RED was real; WHY is not established, and the full re-derivation is in
#   test-rig-worker.sh's header. This domain's position-lock rests on what it READS, not on it.
#
# Re-derivations (audited over this WHOLE file, header included, with split-name-audit.py):
# - $REQS, $RESULTS, $STAGED and $AUDIT are NOT the builder's. They are assigned by the
#   control-run-pending section, in test-control-core.sh, sourced before this stanza — an ordering
#   dependency, same class as any other. They are deliberately NOT seeded here: each is a plain
#   derivation from $C, so a seed would duplicate that file's definitions and could drift from them,
#   and it would buy nothing, because $C itself keeps this file non-standalone either way.
#   Disclosure is the contract this file offers instead.
# - $MASKED is assigned HERE, in the moved text, not inherited.
# - $VALID_TARI is a lib.sh top-level constant; $PATH is the environment's.
# - $WALLET is NOT a top-level constant, and getting that right matters here. lib.sh assigns it
#   only INSIDE the two sandbox builders, as WALLET="${WALLET:-$VALID_PRIMARY}", and run.sh never
#   assigns it at all — so $WALLET reaches this domain from the same build_control_sandbox call
#   that provides $C, by the same ordering dependency, and belongs in the disclosure above rather
#   than filed as a constant. A defaulting fix retires a coupling only for CALLERS, and a split
#   manufactures non-callers; under run.sh's `set -u` an unset $WALLET would abort outright.
# - Provider functions this domain calls, from lib.sh: assert_eq, assert_contains,
#   assert_not_contains, assert_rc, file_mode, control_config, run_pending, and ok/bad beneath the
#   assertions. It does NOT call seed_control_env.
# - inject_reject(), onion_control_config() and tg_control_config() are defined in the moved text
#   and are not unset at its end, so they outlive the source exactly as they outlived their old
#   position in run.sh. No other file under tests/stack/ uses those names, so nothing downstream
#   can see a definition it did not see before.
#
# The block's own tail is load-bearing for what follows it: its last lines restore the section
# baseline — control on, no telegram — and re-apply, and the in-code comment there says so. The
# source stanza therefore sits at this block's own vacated position, so the tail still runs where
# it always ran. The anchor is a correctness requirement in this cut, not the usual preference.
echo "== black-box: pre-masked prefill copy + host-side secret merge (#440) =="
# The dashboard container never mounts the raw config.json: apply/run-pending render a PRE-MASKED
# copy into the spool's masked/ leg, and the "blank secret keeps the live value" sentinel swap
# happens host-side at staging. Current state: pool mini committed above, node_password "p",
# dashboard password "a control passphrase".
MASKED="$C/data/control/masked/config.json"
[ -f "$MASKED" ] && ok "masked prefill copy rendered by apply" || bad "masked prefill copy rendered by apply" "$MASKED missing"
assert_eq "masked copy is world-readable for the container (644)" "$(file_mode "$MASKED")" "644"
assert_eq "set secret masked to the sentinel" "$(jq -c '.monero.node_password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "dashboard password masked to the sentinel" "$(jq -c '.dashboard.auth.password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "non-secret keys survive the masking" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "mini"
case "$(cat "$MASKED")" in
*"a control passphrase"* | *'"p"'*) bad "masked copy holds no secret values" "a secret leaked into $MASKED" ;;
*) ok "masked copy holds no secret values" ;;
esac

# Staleness: a hand-edit to config.json (new BOTSECRET token) is re-masked by the next runner
# pass — run-pending freshens the copy even with an empty request spool.
jq '.telegram = {"bot_token":"BOTSECRET","chat_id":"-100123"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_pending >/dev/null
assert_eq "run-pending re-renders the masked copy" "$(jq -c '.telegram.bot_token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
case "$(cat "$MASKED")" in
*BOTSECRET*) bad "hand-edited secret never reaches the masked copy" "BOTSECRET leaked into $MASKED" ;;
*) ok "hand-edited secret never reaches the masked copy" ;;
esac

# Sync .env with the hand-edited config so the sentinel commit below only changes allowlisted
# P2POOL keys (TELEGRAM_BOT_TOKEN is deliberately NOT dashboard-committable).
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

# Host-side sentinel swap: a proposal carrying {"__secret__":true} for untouched secrets (what the
# dashboard now submits) stages with the LIVE values merged back in, and a sentinel for an UNSET
# secret collapses to "" instead of leaking a dict into config.json.
UUID5="55555555-5555-4555-8555-555555555555"
jq -n --arg w "$WALLET" --arg id "$UUID5" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:{"__secret__":true}},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, workers:{api_token:{"__secret__":true}},
    telegram:{bot_token:{"__secret__":true},chat_id:"-100123"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:{"__secret__":true}},control:{enabled:true}}}}' >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel-carrying preview validates" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_eq "sentinel swapped for the live node password at staging" "$(jq -r '.monero.node_password' "$STAGED/$UUID5.json" 2>/dev/null)" "p"
assert_eq "sentinel swapped for the live dashboard password" "$(jq -r '.dashboard.auth.password' "$STAGED/$UUID5.json" 2>/dev/null)" "a control passphrase"
assert_eq "sentinel swapped for the live telegram token" "$(jq -r '.telegram.bot_token' "$STAGED/$UUID5.json" 2>/dev/null)" "BOTSECRET"
assert_eq "sentinel for an unset secret collapses to empty" "$(jq -r '.workers.api_token' "$STAGED/$UUID5.json" 2>/dev/null)" ""
# The container-visible legs of this round trip stay secret-free (the request carried sentinels,
# the merged copy lives only in host-only staged/).
case "$(cat "$RESULTS/$UUID5.json")$(cat "$AUDIT")" in
*BOTSECRET* | *"a control passphrase"*) bad "results/audit stay secret-free on a sentinel preview" "a live secret leaked" ;;
*) ok "results/audit stay secret-free on a sentinel preview" ;;
esac

# Commit the sentinel intent: the committed config.json carries the LIVE secrets ("blank keeps"),
# and the masked prefill copy is re-rendered to match the new state.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live node password" "$(jq -r '.monero.node_password' "$C/config.json")" "p"
assert_eq "committed config keeps the live telegram token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "BOTSECRET"
assert_eq "committed config never carries a sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
assert_eq "masked copy re-rendered after the commit" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "main"
case "$(cat "$MASKED")" in
*BOTSECRET* | *"a control passphrase"*) bad "re-rendered masked copy still holds no secrets" "a secret leaked into $MASKED" ;;
*) ok "re-rendered masked copy still holds no secrets" ;;
esac

echo "== black-box: .env line-injection guard (#33 hardening, per field) =="
# A newline in any config string that renders into .env unquoted would inject a SECOND KEY=value
# line — e.g. PITHEAD_REGISTRY=evil.tld — which the root apply then trusts for every image: pull
# (RCE). parse_and_validate_config (the chokepoint both preview dry-run and real commit run) must
# reject a control character in EVERY string leaf. Build a full valid config, then poison one field.
inject_reject() { # <label> <jq-setter expr using $v>
    jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}
         | '"$2" >"$C/config.json"
    out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
    rc=$?
    assert_rc "$1 with a newline is rejected by parse_and_validate_config" "$rc" "1"
    assert_contains "$1 rejection names the control-char guard" "$out" "control character"
}
inject_reject "node_password" '.monero.node_password=$v'
inject_reject "node_username" '.monero.node_username=$v'
inject_reject "bot_token" '(.telegram={bot_token:$v})'
inject_reject "api_token" '(.workers={api_token:$v})'
inject_reject "ping_url" '(.healthchecks={ping_url:$v})'
inject_reject "chat_id" '(.telegram={chat_id:$v})'
# Positive: legitimate tokens (no control chars) still validate.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
      telegram:{bot_token:"123456:legit-ABC_def"}, workers:{api_token:"tok_legit123"},
      healthchecks:{ping_url:"https://hc-ping.com/abc-123"},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "legitimate secrets still validate" "$?" "0"
# No second line reaches .env: a poisoned config rejected at `apply -y` never renders the attacker key.
jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, telegram:{bot_token:$v},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
if grep -q 'PITHEAD_REGISTRY' "$C/.env"; then bad "no injected line in .env" "PITHEAD_REGISTRY landed in .env"; else ok "rejected config injects no second .env line"; fi

echo "== black-box: control channel on a published onion requires client-auth (#33 hardening) =="
# A root-capable, funds-redirecting mutation channel must not sit behind only a brute-forceable
# password on an anonymously-reachable onion. control+onion+client_auth=false → refused.
onion_control_config() { # <onion-enabled> <client-auth> -> writes config.json
    jq -n --arg w "$WALLET" --argjson onion "$1" --argjson ca "$2" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a strong control passphrase"},
                     onion:{enabled:$onion,client_auth:$ca}, control:{enabled:true}}}' >"$C/config.json"
}
onion_control_config true false
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion without client_auth is refused" "$?" "1"
assert_contains "refusal names client_auth" "$out" "client_auth"
onion_control_config true true
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion WITH client_auth validates" "$?" "0"
assert_not_contains "allowed combo raises no client_auth error" "$out" "client_auth"
# control without an onion (LAN) stays allowed — client-auth only gates the published onion.
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control without an onion is allowed" "$?" "0"

echo "== black-box: telegram.control fails closed on each leg (#521) =="
# telegram.control (the #338 remote /restart /apply surface) is a remotely-reachable host-control
# channel, so it refuses to enable unless the whole chain is present: dashboard.control on (the #33
# spool it rides), telegram.commands on (the bot that answers it), and at least one allow-listed
# operator id (or every command is refused and the feature is inert). Each leg must fail closed.
tg_control_config() { # <dashboard.control.enabled> <telegram.commands.enabled> <allowed_ids-json>
    jq -n --arg w "$WALLET" --argjson ctl "$1" --argjson cmds "$2" --argjson ids "$3" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111",
                    commands:{enabled:$cmds}, control:{enabled:true,allowed_ids:$ids}},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
                     control:{enabled:$ctl}}}' >"$C/config.json"
}
# Leg 1: dashboard.control off — the spool the commands ride does not exist.
tg_control_config false true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without dashboard.control is refused" "$?" "1"
assert_contains "refusal names dashboard.control.enabled" "$out" "dashboard.control.enabled is false"
# Leg 2: telegram.commands off — no bot is polling for the commands.
tg_control_config true false '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without telegram.commands is refused" "$?" "1"
assert_contains "refusal names telegram.commands.enabled" "$out" "telegram.commands.enabled is false"
# Leg 3: allowed_ids empty — no operator could ever confirm, the feature is inert.
tg_control_config true true '[]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control with an empty allowed_ids is refused" "$?" "1"
assert_contains "refusal names allowed_ids" "$out" "telegram.control.allowed_ids is empty"
# All three legs present — validates.
tg_control_config true true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "fully-configured telegram.control validates" "$?" "0"
assert_not_contains "fully-configured control raises no telegram.control error" "$out" "telegram.control.enabled is true but"
# Restore the section baseline (control on, no telegram) for the tests that follow.
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
