# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The boot gate's certificate re-mint and the rollback verdict that names its cause (#1265).
# render mints the dashboard certificate BEFORE `up`, from the box's address list as it stands
# then; doctor re-checks coverage inside the gate loop AFTER `up`, when the list has settled. An
# address arriving between the two (a SLAAC/ULA prefix) failed doctor on all 90 rounds, nothing
# on the boot path re-minted, and a good update rolled back — reaching the dashboard as "rolled
# back" with no cause. Two pieces, both sourceable from pithead-boot and driven here with stubs:
# the trigger (`gate_blocked_only_by_cert`, coverage alone and nothing else), the bounded re-mint
# (`gate_remint_cert`, Caddy restarted only when the certificate changed), and the verdict's
# `blocking` list that fail_boot writes into the in-flight flag for os_update_rollback_verdict
# to name on the fallback boot. The loop's wiring is asserted by ORDER in the script, since the
# loop itself is below the sourcing boundary. A fourth unit from the same harness, at the end:
# `provisioning_settled` (#1945), the restore leg's wait on the provisioning units before it backs
# up. Sourced by tests/stack/run.sh.

echo "== unit: gate_blocked_only_by_cert — the re-mint triggers on coverage alone, never on anything else (#1265) =="
# Any other failing check is a slot-health question the gate must not paper over, so the trigger
# is "exactly one fail, and it is the coverage check". Mutation run: drop the `length == 1` ->
# the coverage-plus-another row goes red; drop the startswith -> the any-single-fail row goes red.
BR="$SANDBOX/boot-remint"
rm -rf "$BR"
mkdir -p "$BR"
COVER="The dashboard certificate does not cover: fd00::1 — Caddy serves those names without a certificate for them."
dj() { # <status> <message> [<status> <message>]... -> a doctor --json document
    local checks="" s m
    while [ $# -ge 2 ]; do
        s=$1
        m=$2
        shift 2
        checks="$checks${checks:+,}{\"status\":\"$s\",\"message\":\"$m\"}"
    done
    printf '{"version":"t","exit":1,"summary":{"ok":0,"warn":0,"fail":0},"checks":[%s]}\n' "$checks"
}
bc_run() { # <doctor json, or "" for no file> -> cert-only|not
    if [ -n "$1" ]; then printf '%s\n' "$1" >"$BR/doctor.json"; else rm -f "$BR/doctor.json"; fi
    (
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$BR/doctor.json"
        gate_blocked_only_by_cert && echo cert-only || echo not
    )
}
assert_eq "coverage as the only failing check triggers" "$(bc_run "$(dj ok 'monerod is running' fail "$COVER")")" "cert-only"
assert_eq "coverage plus another failing check does NOT (the other check is the slot's health)" \
    "$(bc_run "$(dj fail "$COVER" fail 'monerod is not running')")" "not"
assert_eq "any other single failing check does NOT" "$(bc_run "$(dj fail 'monerod is not running')")" "not"
assert_eq "no failing check does NOT (warns are not fails)" "$(bc_run "$(dj ok 'a' warn 'b')")" "not"
assert_eq "coverage reported as a WARN does NOT" "$(bc_run "$(dj warn "$COVER")")" "not"
assert_eq "coverage plus a certificate-expiry fail does NOT (two fails)" \
    "$(bc_run "$(dj fail "$COVER" fail 'The dashboard certificate expires in 12 days')")" "not"
assert_eq "no doctor file at all does NOT" "$(bc_run "")" "not"
assert_eq "a malformed doctor file does NOT" "$(bc_run 'not json')" "not"
# The prefix the trigger matches must be the one doctor prints, or a reworded doctor silently
# disarms the re-mint while every row above stays green: both sides are pinned to the source.
# BOTH ARMS, since #1213 split this check into host and appliance wording: this gate runs ONLY on
# an appliance, so the arm it actually reads is the SECOND one. A pin naming one arm would leave a
# reworded appliance arm free to disarm the re-mint with this row still green.
assert_eq "the trigger's prefix is doctor's own coverage message, verbatim at source" \
    "$(grep -c 'dr_fail_surface "The dashboard certificate does not cover: ' "$ROOT/lib/pithead/20-doctor-install-checks.sh")" "1"
assert_eq "…and the appliance arm — the only one this gate ever reads — carries it too" \
    "$(grep -o 'The dashboard certificate does not cover: ' "$ROOT/lib/pithead/20-doctor-install-checks.sh" | grep -c .)" "2"
assert_eq "…and the boot script matches exactly that prefix" \
    "$(grep -c 'startswith("The dashboard certificate does not cover")' "$ROOT/os/overlay/pithead-boot")" "1"

echo "== unit: gate_remint_cert — bounded, and Caddy restarts only when the certificate changed (#1265) =="
# A stubbed `pithead` whose `render` writes wizard.crt (or does not), and a restart command that
# leaves a file. ONE subshell for the whole sequence, because the bound is a counter that must
# persist across calls: changed -> restart; unchanged -> no restart and a line saying render and
# doctor disagree (and that the gate commits on it — test-appliance-cert-advisory.sh drives that
# half); render failing -> no restart; a fourth call -> refused before render runs.
# Mutation run: drop the before/after comparison -> the unchanged row's restart goes red; drop
# the BOOT_REMINT_MAX check -> the fourth-call row and the render count go red.
RM="$BR/remint"
mkdir -p "$RM/tls"
cat >"$RM/pithead" <<'STUB'
#!/usr/bin/env bash
echo "$1" >>"$STUB_CALLS"
[ "$1" = render ] || exit 0
[ -n "${STUB_MINT:-}" ] && printf '%s\n' "$STUB_MINT" >"$STUB_TLS/wizard.crt"
exit "${STUB_RENDER_RC:-0}"
STUB
chmod +x "$RM/pithead"
printf 'cert-v1\n' >"$RM/tls/wizard.crt"
rm_out=$(
    cd "$RM" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    export STUB_CALLS="$RM/calls" STUB_TLS="$RM/tls" PITHEAD_TLS_DIR="$RM/tls"
    export PITHEAD_CADDY_RESTART_CMD="touch $RM/restarted"
    restarted() {
        if [ -f "$RM/restarted" ]; then echo yes; else echo no; fi
        rm -f "$RM/restarted"
    }
    export STUB_MINT=cert-v2 STUB_RENDER_RC=0
    gate_remint_cert
    echo "call1 rc=$? restarted=$(restarted)"
    export STUB_MINT=
    gate_remint_cert
    echo "call2 rc=$? restarted=$(restarted)"
    export STUB_MINT=cert-v3 STUB_RENDER_RC=1
    gate_remint_cert
    echo "call3 rc=$? restarted=$(restarted)"
    export STUB_MINT=cert-v4 STUB_RENDER_RC=0
    gate_remint_cert
    echo "call4 rc=$? restarted=$(restarted)"
    echo "renders=$(grep -c '^render$' "$RM/calls")"
)
assert_contains "a changed certificate: rc 0 and Caddy restarted" "$rm_out" "call1 rc=0 restarted=yes"
assert_contains "  …saying so on the console, with the count" "$rm_out" "re-minted the dashboard certificate for an address that arrived after render (1/3)"
assert_contains "an unchanged certificate: rc 1 and NO restart" "$rm_out" "call2 rc=1 restarted=no"
assert_contains "  …saying render and doctor disagree, and that the gate records it and commits" "$rm_out" "render minted no new certificate (2/3) — render and doctor disagree about the names; that is this machine's address list, not the slot, so the gate records it and commits"
assert_contains "render failing: rc 1 and NO restart, even though the file moved" "$rm_out" "call3 rc=1 restarted=no"
assert_contains "the fourth call is refused (BOOT_REMINT_MAX=3)" "$rm_out" "call4 rc=1 restarted=no"
assert_contains "  …before render runs: three renders for four calls" "$rm_out" "renders=3"

echo "== unit: the gate loop is wired — the re-mint sits between this round's ready check and the sleep (#1265) =="
# The loop is below the sourcing boundary, so its wiring is asserted by ORDER in the script:
# the per-round reset of gate_doctor_ran, the ready check, the re-mint branch keyed on THIS
# round's doctor run, then the sleep and the fail. Mutation run: delete the elif -> red; move the
# reset above the loop -> the reset row goes red (a stale verdict file could then re-mint).
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
bl_line() { grep -n -F -- "$1" "$BOOTSCRIPT" | head -1 | cut -d: -f1; }
l_loop=$(bl_line 'for _ in $(seq 90); do')
l_reset=$(bl_line '    gate_doctor_ran=0')
l_ready=$(bl_line '    if gate_ready "')
l_elif=$(bl_line '    elif [ "$gate_doctor_ran" = 1 ] && gate_blocked_only_by_cert; then')
l_remint=$(bl_line '        gate_remint_cert || true')
l_sleep=$(bl_line '    sleep 10')
l_fail=$(bl_line 'fail_boot "the stack never became healthy (serving + doctor)"')
assert_eq "every anchor is present exactly where a reader would look" \
    "$([ -n "$l_loop" ] && [ -n "$l_reset" ] && [ -n "$l_ready" ] && [ -n "$l_elif" ] && [ -n "$l_remint" ] && [ -n "$l_sleep" ] && [ -n "$l_fail" ] && echo all)" "all"
assert_eq "gate_doctor_ran is reset INSIDE the loop, before the ready check" \
    "$([ "${l_loop:-0}" -lt "${l_reset:-0}" ] && [ "${l_reset:-0}" -lt "${l_ready:-0}" ] && echo ordered)" "ordered"
assert_eq "the re-mint branch follows the ready check and precedes the sleep and the fail" \
    "$([ "${l_ready:-0}" -lt "${l_elif:-0}" ] && [ "${l_elif:-0}" -lt "${l_remint:-0}" ] && [ "${l_remint:-0}" -lt "${l_sleep:-0}" ] && [ "${l_sleep:-0}" -lt "${l_fail:-0}" ] && echo ordered)" "ordered"
l_gr=$(bl_line 'gate_ready() {')
l_set=$(bl_line '    gate_doctor_ran=1')
l_doc=$(bl_line '    ./pithead doctor --json >"$BOOT_DOCTOR_JSON"')
assert_eq "gate_ready marks the round BEFORE it runs doctor, so a quiet round can never act on last round's file" \
    "$([ "${l_gr:-0}" -lt "${l_set:-0}" ] && [ "${l_set:-0}" -lt "${l_doc:-0}" ] && echo ordered)" "ordered"

echo "== unit: fail_boot records the blocking checks on the in-flight flag, and the fallback verdict names them (#1265) =="
# The failing slot's last doctor run is on /run when fail_boot runs; it copies the failing
# messages into the in-flight flag, which survives the reboot on /data. The fallback boot's
# os_update_rollback_verdict then carries them into the verdict and names the first on the
# console. Mutation run: drop fail_boot's jq -> the flag rows go red; drop `--argjson b` -> the
# verdict rows go red.
FV="$BR/verdict"
fv_run() { # <doctor json, or ""> -> "flag=<json> verdict=<json> outcome=<..> console=<tail>"
    local flag verdict outcome console
    rm -rf "$FV"
    mkdir -p "$FV/data/os-update" "$FV/data/control/results"
    printf '{"from":"1.0.0","to":"1.0.1"}\n' >"$FV/data/os-update/in-flight.json"
    [ -n "$1" ] && printf '%s\n' "$1" >"$FV/doctor.json"
    (
        cd "$FV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        BOOT_DOCTOR_JSON="$FV/doctor.json"
        PITHEAD_REBOOT_CMD=true fail_boot "the stack never became healthy (serving + doctor)" 2>/dev/null
    )
    flag=$(jq -rc '.blocking // "absent"' "$FV/data/os-update/in-flight.json" 2>/dev/null)
    printf '1.0.0\n' >"$FV/VERSION" # the fallback boot runs the OLD version
    console=$(
        cd "$FV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_rollback_verdict
    )
    verdict=$(jq -c '.verdict.blocking' "$FV/data/control/results/os-update-state.json" 2>/dev/null)
    outcome=$(jq -r '.verdict.outcome' "$FV/data/control/results/os-update-state.json" 2>/dev/null)
    printf 'flag=%s verdict=%s outcome=%s console=%s' "$flag" "$verdict" "$outcome" "${console##*previous version}"
}
fv_one=$(fv_run "$(dj ok 'monerod is running' fail "$COVER")")
assert_contains "one failing check lands on the flag" "$fv_one" "flag=[\"$COVER\"]"
assert_contains "…and in the verdict" "$fv_one" "verdict=[\"$COVER\"] outcome=rolled_back"
assert_contains "…and the console names it" "$fv_one" "console= (its gate was held by: The dashboard certificate does not cover: fd00::1"
fv_two=$(fv_run "$(dj fail "$COVER" fail 'monerod is not running')")
assert_contains "two failing checks: both on the flag, in doctor's order" "$fv_two" "flag=[\"$COVER\",\"monerod is not running\"]"
assert_contains "…the console names the first" "$fv_two" "held by: The dashboard certificate"
fv_none=$(fv_run "")
assert_contains "no doctor file: nothing added to the flag" "$fv_none" "flag=absent"
assert_contains "…the verdict carries an empty list and is still rolled_back" "$fv_none" "verdict=[] outcome=rolled_back"
assert_not_contains "…and the console line is the plain one" "$fv_none" "held by"
unset -f dj bc_run bl_line fv_run
unset BR RM FV COVER rm_out BOOTSCRIPT l_loop l_reset l_ready l_elif l_remint l_sleep l_fail l_gr l_set l_doc fv_one fv_two fv_none

echo "== unit: provisioning_settled — the restore leg waits on the provisioning UNITS, not on podman ps (#1945) =="
# The wizard's `up` holds the mutation lock through its tor-health wait for minutes after `podman ps`
# shows a live stack; the helper settles only when neither pithead-firstboot nor pithead-boot is
# `activating`. Driven with a stubbed `_ssh` answering the two probes the helper makes; PS_FLIP=1
# turns the first `activating` reading into `inactive` on the next, so the poll itself is exercised.
PS="$SANDBOX/ps1945"
mkdir -p "$PS"
ps_run() { # $1 is-active output (printf %b), $2 seconds, $3 settled|state
    rm -f "$PS/seen"
    (
        PS_ACT="$1" PROVISIONING_POLL_S=0
        _ssh() {
            case "$*" in
            *is-active*)
                if [ "${PS_FLIP:-0}" = 1 ] && [ -f "$PS/seen" ]; then printf 'inactive\ninactive\n'; else
                    touch "$PS/seen"
                    printf '%b' "$PS_ACT"
                fi
                ;;
            *error.txt*) printf '%s' "${PS_ERR:-}" ;;
            esac
        }
        source "$ROOT/tests/os/provisioning-settled.sh"
        case "$3" in settled) provisioning_settled "$2" ;; state) provisioning_state ;; esac
    )
}
ps_run 'inactive\ninactive\n' 5 settled
assert_rc "both units done: settled at once" "$?" "0"
ps_run 'activating\ninactive\n' 1 settled
assert_rc "the wizard still activating at the deadline: not settled" "$?" "1"
ps_run 'inactive\nactivating\n' 1 settled
assert_rc "pithead-boot's up still activating at the deadline: not settled" "$?" "1"
ps_run 'deactivating\ninactive\n' 5 settled
assert_rc "deactivating is a unit on its way OUT, not in: settled (the match is word-anchored)" "$?" "0"
ps_run 'failed\ninactive\n' 5 settled
assert_rc "a failed wizard unit has let go of the lock: settled" "$?" "0"
ps_run '' 1 settled
assert_rc "an unanswered probe is not a settled machine" "$?" "1"
PS_FLIP=1 ps_run 'activating\ninactive\n' 5 settled
assert_rc "activating on the first read, inactive on the next: settled after one poll" "$?" "0"
ps_out=$(PS_ERR='[ERROR] Stack failed to start — see the error above.' ps_run 'activating\ninactive\n' 0 state)
assert_contains "the verdict names both units" "$ps_out" "units: activating inactive"
assert_contains "…and the wizard's spooled error when there is one" "$ps_out" "setup error: [ERROR] Stack failed to start"
ps_out=$(ps_run 'inactive\ninactive\n' 0 state)
assert_not_contains "an empty spool: no error claimed" "$ps_out" "setup error"
unset -f ps_run
unset PS ps_out
