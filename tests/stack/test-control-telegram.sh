# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel Telegram lifecycle domain (#1105 Phase 1, appliance lane): the bounded Telegram
# control verbs (#338). The #33 runner dispatches each accepted verb to a FIXED pithead command and
# audits it; an unknown verb is rejected, and no host command runs on the rejection path.
# Sourced by tests/stack/run.sh.
#
# This domain IS standalone-sourceable once tests/stack/lib.sh has been sourced, and it needs
# nothing from any sibling domain file. It is not a consumer of the shared control sandbox: it
# never calls build_control_sandbox(), and it never reads $C, $CTRL_LOG or the request-spool
# globals. It builds its own control directory under $SANDBOX instead. So the add-only-ssrf
# disclosure precedent that governs the pure-consumer control domains does not apply here, and
# neither does the position lock that comes with it: this domain reads no state a sibling leaves
# behind, writes nothing outside its own directory under $SANDBOX, and unsets the environment it
# exports before it ends. Both directions were checked, and both are re-derivable with grep here.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $SANDBOX is the ONLY name this file reads without assigning. It is a lib.sh top-level constant,
#   assigned at column 1 rather than inside a function — the distinction that matters, because a
#   name a provider assigns only inside a function reaches a domain file as an ordering dependency
#   and not as a constant. The guard below states that single requirement explicitly.
# - $CC is assigned here, in the moved text, not inherited.
# - The lib.sh helpers this domain calls (assert_contains, assert_eq, run_sourced) are likewise
#   defined at lib.sh's top level.

: "${SANDBOX:?}"

echo "== control channel: Telegram lifecycle verbs (#338) =="
# The #33 runner dispatches the two bounded Telegram control verbs to FIXED pithead commands and
# audits them; an unknown verb is rejected and no host command runs. PITHEAD_SELF points the runner
# at a stub that only records the literal verb it was handed, so nothing real is applied/restarted.
CC="$SANDBOX/ctrl338"
mkdir -p "$CC/staged" "$CC/results" "$CC/audit"
cat >"$CC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SELF_LOG"
exit 0
EOF
chmod +x "$CC/self"
export SELF_LOG="$CC/self.log"
export PITHEAD_SELF="$CC/self"
uid_r="11111111-1111-4111-8111-111111111111"
uid_a="22222222-2222-4222-8222-222222222222"
uid_x="33333333-3333-4333-8333-333333333333"

: >"$SELF_LOG"
printf '{"id":"%s","action":"restart","actor":"tg-7"}\n' "$uid_r" >"$CC/req_r.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_r.json" "$CC" >/dev/null 2>&1
assert_eq "restart intent runs the fixed 'restart' verb" "$(cat "$SELF_LOG")" "restart"
assert_eq "restart result is applied" "$(jq -r .status "$CC/results/$uid_r.json")" "applied"
assert_contains "restart is audited with the actor + action" \
    "$(cat "$CC/audit/control.log")" '"actor":"tg-7","action":"restart","status":"applied"'

: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tg-7"}\n' "$uid_a" >"$CC/req_a.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "apply intent runs the fixed 'apply -y' verb (config re-apply, no edit)" "$(cat "$SELF_LOG")" "apply -y"
assert_eq "apply result is applied" "$(jq -r .status "$CC/results/$uid_a.json")" "applied"

: >"$SELF_LOG"
printf '{"id":"%s","action":"frobnicate","actor":"tg-7"}\n' "$uid_x" >"$CC/req_x.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_x.json" "$CC" >/dev/null 2>&1
assert_eq "unknown verb rejected (bounded action set)" "$(jq -r .error "$CC/results/$uid_x.json")" "unknown action"
assert_eq "unknown verb never runs a host command" "$(cat "$SELF_LOG")" ""
unset PITHEAD_SELF SELF_LOG
