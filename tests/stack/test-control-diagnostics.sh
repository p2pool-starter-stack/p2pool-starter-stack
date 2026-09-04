# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel read-only diagnostics domain (#1745): the two verbs #1736 shipped in
# lib/pithead/46a-control-diagnostics.sh — `diag-doctor` (#913) and `diag-logs` (#943). Both are
# ASKS that report and never mutate, so what has to hold is that their BOUNDS are host properties
# and their output is redacted before it crosses into the container.
#
# What this domain proves, and the one place the issue's wording splits between the two verbs:
# - diag-doctor hands back the doctor document NESTED under .doctor, and a doctor that cannot
#   report is `failed` — never an empty `applied` the panel would render as "no data".
# - diag-doctor's rc is doctor's own FAILURE COUNT, not a run failure, so a non-zero rc with a
#   readable document still applies. That is the inverse of the case above and the easier one to
#   regress, because both look like "doctor exited non-zero" from outside.
# - diag-logs refuses any container name outside the fixed allowlist, BY MEMBERSHIP, before the
#   docker command is built. #1745 asks for that refusal on "both verbs"; diag-doctor takes no
#   container at all — it never reads the request file — so the honest form of that bullet on that
#   verb is that a `container` key is INERT, which is asserted here rather than skipped.
# - the line count is clamped host-side at the boundary AND one past it, and the byte cap holds
#   independently, because a single log line has no length limit and satisfies any line cap.
# - the onion address is REDACTED on both verbs' output, checked as the raw value being ABSENT
#   from the whole result file, not merely as a marker being present.
# Sourced by tests/stack/run.sh.
#
# This domain is standalone-sourceable once tests/stack/lib.sh has been sourced, and needs nothing
# from any sibling domain file. Like the backup domain it is NOT a consumer of the shared control
# sandbox: it never calls build_control_sandbox(), never reads $C, $CTRL_LOG or the request-spool
# globals, and writes only under its own directory below $SANDBOX. So it adds no result files to a
# spool a sibling counts, and it holds no position in run.sh. $SANDBOX is the only name it reads
# without assigning; the guard below states that single requirement.
#
# The self and docker stubs keep this fast and docker-free: what is under test is the verb glue,
# the bounds and the redaction, not doctor's own checks (test-doctor.sh) or the redactor's rule
# table (test-secrets-masking.sh). The doctor document the stub emits is the real shape, taken
# from doctor_json() in lib/pithead/06-doctor.sh, not invented here.

: "${SANDBOX:?}"

DGC="$SANDBOX/ctrl1745"
mkdir -p "$DGC/results" "$DGC/audit" "$DGC/bin"

# A v3 onion of exactly the shape bundle_redact_log's rule matches: 56 chars of [a-z2-7]. A
# fixture one character short would sail past the redactor and make every ABSENT assertion below
# pass for the wrong reason, so its width is asserted rather than trusted.
DIAG_ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion"
assert_eq "the onion fixture is the 56-char v3 shape the redactor keys on, plus .onion" "${#DIAG_ONION}" "62"

cat >"$DGC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${DIAG_SELF_LOG:-/dev/null}"
case "${DIAG_DOCTOR_MODE:-ok}" in
empty) exit 0 ;;                                        # doctor produced nothing at all
garbage) printf 'doctor: cannot read config.json\n' ;;  # output that is not a JSON document
failcount) printf '%s' "$DIAG_DOCTOR_DOC"; exit 3 ;;    # a readable report, rc = failure count
*) printf '%s' "$DIAG_DOCTOR_DOC" ;;
esac
exit 0
EOF
cat >"$DGC/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${DIAG_DOCKER_LOG:-/dev/null}"
case "$*" in
"compose logs"*)
    if [ "${DIAG_LOG_BIG:-0}" = "1" ]; then
        head -c 70000 /dev/zero | tr '\0' 'x' # one line, no newline: defeats any line cap
    else
        printf '%s' "${DIAG_LOG_BODY:-}"
    fi
    ;;
esac
exit 0
EOF
chmod +x "$DGC/self" "$DGC/bin/docker"
export PITHEAD_SELF="$DGC/self"
export DIAG_SELF_LOG="$DGC/self.log"
export DIAG_DOCKER_LOG="$DGC/docker.log"

# The stub is on PATH only for the duration of the call, in a subshell of run_sourced's own, so
# nothing here can leak a stub docker into a sibling domain.
diag_run() { # <request-file>
    (
        export PATH="$DGC/bin:$PATH"
        run_sourced "$SANDBOX" control_process_request "$1" "$DGC"
    ) >/dev/null 2>&1
}
diag_req() { # <id> <action> [extra json body] -> writes and echoes the request path
    printf '{"id":"%s","action":"%s","actor":"admin"%s}\n' "$1" "$2" "${3:-}" >"$DGC/req-$1.json"
    printf '%s\n' "$DGC/req-$1.json"
}

# ---------------------------------------------------------------------------
echo "== control channel: diag-doctor returns a nested, redacted document (#913) =="
export DIAG_DOCTOR_DOC='{"version":"1.19.3","exit":1,"summary":{"ok":7,"warn":2,"fail":1},"checks":[{"status":"ok","message":"Docker is running"},{"status":"fail","message":"Dashboard onion: '"$DIAG_ONION"'"}]}'
did1="b1b1b1b1-0000-4000-8000-000000000001"
: >"$DIAG_SELF_LOG"
: >"$DIAG_DOCKER_LOG"
diag_run "$(diag_req "$did1" diag-doctor)"
assert_eq "diag-doctor applies on a readable report" "$(jq -r .status "$DGC/results/$did1.json")" "applied"
assert_eq "diag-doctor asks for the machine-readable report, not the human one" \
    "$(cat "$DIAG_SELF_LOG")" "doctor --json"
assert_eq "the document is nested under .doctor, which is the key the panel renders" \
    "$(jq -r '.doctor.summary.fail' "$DGC/results/$did1.json")" "1"
assert_eq "the document is not flattened into the result envelope" \
    "$(jq -r 'has("summary")' "$DGC/results/$did1.json")" "false"
assert_eq "the checks array survives the round-trip intact" \
    "$(jq -r '.doctor.checks | length' "$DGC/results/$did1.json")" "2"
assert_contains "the onion in the doctor document is replaced by the redaction marker" \
    "$(cat "$DGC/results/$did1.json")" "[redacted].onion"
assert_not_contains "the raw onion address is ABSENT from the whole result file" \
    "$(cat "$DGC/results/$did1.json")" "$DIAG_ONION"
assert_contains "diag-doctor is audited applied" \
    "$(cat "$DGC/audit/control.log")" '"action":"diag-doctor","status":"applied"'

echo "== control channel: diag-doctor — a failure is a failure, a failure COUNT is not (#913) =="
# doctor's rc is the number of failing checks. A non-zero rc carrying a readable document is a
# successful diagnostic run reporting bad news, and must still apply.
did2="b1b1b1b1-0000-4000-8000-000000000002"
export DIAG_DOCTOR_MODE=failcount
diag_run "$(diag_req "$did2" diag-doctor)"
assert_eq "a non-zero doctor rc with a readable report still applies (rc is a failure count)" \
    "$(jq -r .status "$DGC/results/$did2.json")" "applied"
assert_eq "and the bad news it carries is preserved, not flattened away" \
    "$(jq -r '.doctor.exit' "$DGC/results/$did2.json")" "1"

did3="b1b1b1b1-0000-4000-8000-000000000003"
export DIAG_DOCTOR_MODE=empty
diag_run "$(diag_req "$did3" diag-doctor)"
assert_eq "doctor returning nothing is reported failed, never an empty applied" \
    "$(jq -r .status "$DGC/results/$did3.json")" "failed"
assert_eq "a failed diag-doctor result carries no doctor field for the panel to half-render" \
    "$(jq -r 'has("doctor")' "$DGC/results/$did3.json")" "false"
assert_contains "the failure says the host could not produce a report" \
    "$(jq -r .error "$DGC/results/$did3.json")" "did not return a readable report"

did4="b1b1b1b1-0000-4000-8000-000000000004"
export DIAG_DOCTOR_MODE=garbage
diag_run "$(diag_req "$did4" diag-doctor)"
assert_eq "output that is not a JSON document is failed, not shipped as half an object" \
    "$(jq -r .status "$DGC/results/$did4.json")" "failed"
assert_contains "the unreadable-report attempt is audited failed" \
    "$(cat "$DGC/audit/control.log")" '"action":"diag-doctor","status":"failed"'
unset DIAG_DOCTOR_MODE

# #1745 asks that both verbs refuse a name outside the allowlist. diag-doctor takes no container:
# it is called with <id> <actor> <control-dir> and never opens the request file, so the field is
# inert rather than refused. Asserted here so the difference is recorded, not assumed.
did5="b1b1b1b1-0000-4000-8000-000000000005"
: >"$DIAG_DOCKER_LOG"
diag_run "$(diag_req "$did5" diag-doctor ',"container":"wallet-rpc"')"
assert_eq "a container key on diag-doctor is inert — the verb never reads the request file" \
    "$(jq -r .status "$DGC/results/$did5.json")" "applied"
assert_eq "and no docker command is built for it" "$(cat "$DIAG_DOCKER_LOG")" ""

# ---------------------------------------------------------------------------
echo "== control channel: diag-logs refuses anything off the allowlist, by membership (#943) =="
export DIAG_LOG_BODY="tor: bootstrapped 100%"
# wallet-rpc and tari-wallet are real compose services this verb deliberately refuses: their
# ordinary output carries key and address material in shapes outside the redactor's launch-line
# class, and this verb streams to a browser rather than to a chmod-600 tarball.
for _pair in "wallet-rpc:b1b1b1b1-0000-4000-8000-000000000011" \
    "tari-wallet:b1b1b1b1-0000-4000-8000-000000000012"; do
    _c="${_pair%%:*}"
    _id="${_pair#*:}"
    : >"$DIAG_DOCKER_LOG"
    diag_run "$(diag_req "$_id" diag-logs ',"container":"'"$_c"'","lines":10')"
    assert_eq "diag-logs refuses the compose service $_c" \
        "$(jq -r .status "$DGC/results/$_id.json")" "rejected"
    assert_contains "the refusal of $_c names the reason" \
        "$(jq -r .error "$DGC/results/$_id.json")" "not a container this dashboard may read logs for"
    assert_eq "no docker command is built for $_c — the refusal precedes it" \
        "$(cat "$DIAG_DOCKER_LOG")" ""
done
lid1="b1b1b1b1-0000-4000-8000-000000000021"
diag_run "$(diag_req "$lid1" diag-logs ',"container":"tor p2pool","lines":10')"
assert_eq "two allowlisted names in one string is not a member — membership, not pattern-matching" \
    "$(jq -r .status "$DGC/results/$lid1.json")" "rejected"
assert_contains "a refused container is audited rejected" \
    "$(cat "$DGC/audit/control.log")" '"action":"diag-logs","status":"rejected"'
# The control that makes the three refusals above mean something: an allowlisted name is NOT
# refused. Without it they would all pass against a verb that refused everything.
lid2="b1b1b1b1-0000-4000-8000-000000000022"
diag_run "$(diag_req "$lid2" diag-logs ',"container":"tor","lines":10')"
assert_eq "an allowlisted container is served (the control on the refusals above)" \
    "$(jq -r .status "$DGC/results/$lid2.json")" "applied"
assert_eq "the tail it returns is the container's output" \
    "$(jq -r .lines "$DGC/results/$lid2.json")" "tor: bootstrapped 100%"

# ---------------------------------------------------------------------------
echo "== control channel: diag-logs is bounded host-side, at the boundary and past it (#943) =="
# A bound the caller asks for is not a bound. Each case reads the --tail the verb actually built.
diag_tail() { # <id> <requested lines> -> echoes the --tail value that reached docker
    : >"$DIAG_DOCKER_LOG"
    diag_run "$(diag_req "$1" diag-logs ',"container":"tor","lines":'"$2"'')"
    sed -E 's/.*--tail ([^ ]+).*/\1/' "$DIAG_DOCKER_LOG"
}
assert_eq "the cap itself passes through unchanged" \
    "$(diag_tail b1b1b1b1-0000-4000-8000-000000000031 200)" "200"
assert_eq "one past the cap is clamped to the cap, not refused" \
    "$(diag_tail b1b1b1b1-0000-4000-8000-000000000032 201)" "200"
assert_eq "a count below one is raised to one" \
    "$(diag_tail b1b1b1b1-0000-4000-8000-000000000033 0)" "1"
assert_eq "a non-numeric count falls to the cap" \
    "$(diag_tail b1b1b1b1-0000-4000-8000-000000000034 '"abc"')" "200"
# The width guard: `[ N -gt M ]` does not compare a digit string past 64 bits, it errors, and as
# the left operand of && that error is swallowed — so without the width check the clamp silently
# no-ops and the request reaches --tail uncapped. This is the case that regresses invisibly.
assert_eq "a digit string too wide for arithmetic is clamped, not passed through" \
    "$(diag_tail b1b1b1b1-0000-4000-8000-000000000035 99999999999999999999999)" "200"

echo "== control channel: diag-logs redacts and caps its bytes independently (#943) =="
lid3="b1b1b1b1-0000-4000-8000-000000000041"
export DIAG_LOG_BODY="tor: opened hidden service $DIAG_ONION on port 80"
diag_run "$(diag_req "$lid3" diag-logs ',"container":"tor","lines":10')"
assert_contains "the onion in the log tail is replaced by the redaction marker" \
    "$(cat "$DGC/results/$lid3.json")" "[redacted].onion"
assert_not_contains "the raw onion address is ABSENT from the whole result file" \
    "$(cat "$DGC/results/$lid3.json")" "$DIAG_ONION"
# The byte cap is the bound that actually protects the runner: a single log line has no length
# limit, so 70000 bytes on ONE line satisfies any line cap and only the byte cap stops it.
lid4="b1b1b1b1-0000-4000-8000-000000000042"
export DIAG_LOG_BIG=1
diag_run "$(diag_req "$lid4" diag-logs ',"container":"tor","lines":1')"
assert_eq "one 70000-byte line is cut at the byte cap, which no line cap could have bounded" \
    "$(jq -r '.lines | length' "$DGC/results/$lid4.json")" "65536"
unset DIAG_LOG_BIG
# No output is not a failure: the container may simply not be running on this host.
lid5="b1b1b1b1-0000-4000-8000-000000000043"
export DIAG_LOG_BODY=""
diag_run "$(diag_req "$lid5" diag-logs ',"container":"tor","lines":10')"
assert_eq "a container with no output applies rather than failing" \
    "$(jq -r .status "$DGC/results/$lid5.json")" "applied"
assert_contains "and says why the tail is empty" \
    "$(jq -r .note "$DGC/results/$lid5.json")" "may not be running on this host"
assert_contains "a served container is audited applied" \
    "$(cat "$DGC/audit/control.log")" '"action":"diag-logs","status":"applied"'

unset PITHEAD_SELF DIAG_SELF_LOG DIAG_DOCKER_LOG DIAG_DOCTOR_DOC DIAG_LOG_BODY
unset -f diag_run diag_req diag_tail
unset DGC DIAG_ONION did1 did2 did3 did4 did5 lid1 lid2 lid3 lid4 lid5 _c _id _pair
