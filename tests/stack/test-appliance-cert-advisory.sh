# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The certificate remedy and the gate's advisory commit (#1265, the remainder). Two halves, both
# driven with stubs: `apply_refresh_appliance_tls` — the unchanged-config path of `apply` now
# reaches the mint (through generate_caddyfile, idempotent by SAN set) and restarts Caddy only when
# the certificate or the Caddyfile actually moved, so the command doctor prints is true — and
# `gate_cert_advisory` — the boot gate commits a slot held by coverage alone once the narrow
# re-mint could not clear it (render minted nothing, or the budget is spent), recording the drift
# as the verdict's `advisory`. The wiring of both sits below a sourcing boundary or inside `apply`,
# so it is asserted by ORDER in the source and labelled static. Sourced by tests/stack/run.sh.

echo "== unit: apply_refresh_appliance_tls — the unchanged-config apply reaches the mint, and restarts Caddy only on a real change (#1265) =="
# A stubbed generate_caddyfile that moves the certificate, the Caddyfile, both, or neither, and a
# stubbed docker that records its calls. Mutation run: drop the Caddyfile comparison -> the
# "Caddyfile alone" row goes red; drop the is_appliance guard -> the DIY rows go red.
CA="$SANDBOX/cert-advisory"
rm -rf "$CA"
mkdir -p "$CA/tls"
ar_run() { # <PITHEAD_APPLIANCE 0|1> <what the stubbed render moves: none|cert|caddyfile|both> -> "rc=N restart=yes|no renders=N line=yes|no"
    : >"$CA/calls"
    printf 'cert-v1\n' >"$CA/tls/wizard.crt"
    printf 'caddy-v1\n' >"$CA/Caddyfile"
    local out restart=no line=no
    out=$(
        cd "$CA" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        # shellcheck disable=SC2034  # read by the sourced is_appliance guard, unseen here
        PITHEAD_APPLIANCE=$1
        PITHEAD_TLS_DIR="$CA/tls"
        AR_MOVE=$2
        generate_caddyfile() {
            echo render >>"$CA/calls"
            case "$AR_MOVE" in cert | both) printf 'cert-v2\n' >"$CA/tls/wizard.crt" ;; esac
            case "$AR_MOVE" in caddyfile | both) printf 'caddy-v2\n' >"$CA/Caddyfile" ;; esac
        }
        docker() { echo "docker $*" >>"$CA/calls"; }
        apply_refresh_appliance_tls 2>&1
        echo "rc=$?"
    )
    grep -q '^docker compose restart caddy$' "$CA/calls" && restart=yes
    case "$out" in *"restarting caddy so it serves them"*) line=yes ;; esac
    printf '%s restart=%s renders=%s line=%s' "${out##*$'\n'}" "$restart" "$(grep -c '^render$' "$CA/calls")" "$line"
}
assert_eq "appliance, nothing moved: rendered once, no restart, no line" "$(ar_run 1 none)" "rc=0 restart=no renders=1 line=no"
assert_eq "appliance, the certificate moved: restarted, and says so" "$(ar_run 1 cert)" "rc=0 restart=yes renders=1 line=yes"
assert_eq "appliance, the Caddyfile alone moved: restarted (Caddy mounts it read-only)" "$(ar_run 1 caddyfile)" "rc=0 restart=yes renders=1 line=yes"
assert_eq "appliance, both moved: restarted once" "$(ar_run 1 both)" "rc=0 restart=yes renders=1 line=yes"
assert_eq "DIY: never renders and never restarts, even when a render would have moved both" "$(ar_run 0 both)" "rc=0 restart=no renders=0 line=no"
# The idempotent mint keeps an operator's trusted certificate: with nothing moved the file on disk
# is the one that was there before (the stub models the mint's SAN-set short-circuit; the mint
# itself is pinned in test-doctor-appliance.sh / the wizard rows).
ar_run 1 none >/dev/null
assert_eq "…and the untouched certificate is byte for byte the one that was there" "$(cat "$CA/tls/wizard.crt")" "cert-v1"

echo "== unit: the unchanged branch of apply calls the refresh under the lock, before it reports nothing to apply (#1265, static) =="
# apply()'s unchanged branch is inline, so its wiring is asserted by ORDER in the slice: the hold,
# the control-runner convergence (#33), the refresh, the "nothing to apply" line, the release.
# Mutation run: delete the refresh call -> the presence row goes red; move it after the log -> the
# order row goes red.
AP="$ROOT/lib/pithead/40-apply-and-render.sh"
ap_line() { grep -n -F -- "$1" "$AP" | head -1 | cut -d: -f1; }
l_hold=$(ap_line '            mutation_lock_acquire apply')
l_units=$(ap_line '            provision_control_runner')
l_refresh=$(ap_line '            apply_refresh_appliance_tls')
l_nothing=$(ap_line '            log "No configuration changes detected. Nothing to apply."')
l_release=$(ap_line '            mutation_lock_release')
assert_eq "every anchor of the unchanged branch is present" \
    "$([ -n "$l_hold" ] && [ -n "$l_units" ] && [ -n "$l_refresh" ] && [ -n "$l_nothing" ] && [ -n "$l_release" ] && echo all)" "all"
assert_eq "the refresh runs under the hold, after the units converge and before 'nothing to apply' and the release" \
    "$([ "${l_hold:-0}" -lt "${l_units:-0}" ] && [ "${l_units:-0}" -lt "${l_refresh:-0}" ] && [ "${l_refresh:-0}" -lt "${l_nothing:-0}" ] && [ "${l_nothing:-0}" -lt "${l_release:-0}" ] && echo ordered)" "ordered"
assert_eq "the shipped pithead carries the refresh (parity is the gate; this is the reader's check)" \
    "$(grep -c '^apply_refresh_appliance_tls() {' "$STACK")" "1"

echo "== unit: gate_cert_advisory — a coverage hold the re-mint could not clear commits as advisory, nothing else does (#1265) =="
# Sourced pithead-boot, a fixture doctor JSON, and gate_remint_state set by hand to each of the
# values gate_remint_cert records. Mutation run: accept `failed` in the case -> the failed row goes
# red; drop the message read -> the "carries the message" rows go red.
GA="$SANDBOX/gate-advisory"
rm -rf "$GA"
mkdir -p "$GA"
COVER="The dashboard certificate does not cover: fd00::1 — Caddy serves those names without a certificate for them."
ga_run() { # <state> <doctor json or "">  -> "rc=N adv=<message or ->"
    if [ -n "$2" ]; then printf '%s\n' "$2" >"$GA/doctor.json"; else rm -f "$GA/doctor.json"; fi
    (
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$GA/doctor.json"
        gate_remint_state=$1
        gate_cert_advisory
        printf 'rc=%s adv=%s' "$?" "${gate_advisory:--}"
    )
}
DJ_COVER='{"version":"t","exit":1,"summary":{"ok":1,"warn":0,"fail":1},"checks":[{"status":"ok","message":"monerod is running"},{"status":"fail","message":"'"$COVER"'"}]}'
assert_eq "render minted nothing (unchanged): commits, and carries doctor's coverage message" "$(ga_run unchanged "$DJ_COVER")" "rc=0 adv=$COVER"
assert_eq "the re-mint budget is spent (exhausted): commits, and carries the message" "$(ga_run exhausted "$DJ_COVER")" "rc=0 adv=$COVER"
assert_eq "a re-mint that changed the certificate (reminted): does NOT — the next round re-judges" "$(ga_run reminted "$DJ_COVER")" "rc=1 adv=-"
assert_eq "render FAILED: does NOT — a slot that cannot render is the slot's health" "$(ga_run failed "$DJ_COVER")" "rc=1 adv=-"
assert_eq "no re-mint attempted yet (empty state): does NOT" "$(ga_run "" "$DJ_COVER")" "rc=1 adv=-"
assert_eq "unchanged, but no doctor file to quote: does NOT (nothing to record is nothing to commit on)" "$(ga_run unchanged "")" "rc=1 adv=-"
assert_eq "unchanged, but doctor reports no failing check: does NOT" "$(ga_run unchanged '{"checks":[{"status":"ok","message":"a"}]}')" "rc=1 adv=-"

echo "== unit: gate_remint_cert records what it did — reminted, unchanged, failed, exhausted (#1265) =="
# The same stubbed `pithead render` and restart command the remint rows use, in ONE subshell so
# the bound persists: changed -> reminted; unchanged -> unchanged; failing -> failed; the fourth
# call -> exhausted before render runs. Mutation run: drop any one assignment -> its row goes red.
RS="$GA/state"
mkdir -p "$RS/tls"
cat >"$RS/pithead" <<'STUB'
#!/usr/bin/env bash
[ "$1" = render ] || exit 0
case "$(cat "$STUB_MODE")" in
change) printf '%s\n' "$RANDOM$RANDOM" >"$STUB_CRT" ;;
fail) exit 1 ;;
esac
STUB
chmod +x "$RS/pithead"
rs_out=$(
    cd "$RS" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    export STUB_MODE="$RS/mode" STUB_CRT="$RS/tls/wizard.crt"
    PITHEAD_TLS_DIR="$RS/tls"
    PITHEAD_CADDY_RESTART_CMD=true
    printf 'seed\n' >"$RS/tls/wizard.crt"
    echo change >"$RS/mode"
    gate_remint_cert >/dev/null
    printf 'call1=%s ' "$gate_remint_state"
    echo keep >"$RS/mode"
    gate_remint_cert >/dev/null
    printf 'call2=%s ' "$gate_remint_state"
    echo fail >"$RS/mode"
    gate_remint_cert >/dev/null
    printf 'call3=%s ' "$gate_remint_state"
    gate_remint_cert >/dev/null
    printf 'call4=%s' "$gate_remint_state"
)
assert_eq "the four outcomes, in order" "$rs_out" "call1=reminted call2=unchanged call3=failed call4=exhausted"

echo "== unit: the gate loop commits on the advisory and the verdict carries it (#1265, static) =="
# The loop and the commit block are below the sourcing boundary: asserted by ORDER — the re-mint,
# then the advisory check, then the single commit condition, then the advisory console line —
# and by the `updated` verdict's jq naming `advisory`. Mutation run: delete the advisory line ->
# red; write the verdict without `advisory` -> red.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
bl_line() { grep -n -F -- "$1" "$BOOTSCRIPT" | head -1 | cut -d: -f1; }
l_remint=$(bl_line '        gate_remint_cert || true')
l_adv=$(bl_line '        gate_cert_advisory && gate_pass=1')
l_pass=$(bl_line '    if [ "$gate_pass" = 1 ]; then')
l_say=$(bl_line "with that recorded as advisory; run './pithead apply' on the machine to re-mint")
l_verdict=$(bl_line 'advisory:(if $a == "" then [] else [$a] end)')
assert_eq "every anchor is present" \
    "$([ -n "$l_remint" ] && [ -n "$l_adv" ] && [ -n "$l_pass" ] && [ -n "$l_say" ] && [ -n "$l_verdict" ] && echo all)" "all"
assert_eq "re-mint, then the advisory check, then the one commit condition, then the console line, then the verdict" \
    "$([ "${l_remint:-0}" -lt "${l_adv:-0}" ] && [ "${l_adv:-0}" -lt "${l_pass:-0}" ] && [ "${l_pass:-0}" -lt "${l_say:-0}" ] && [ "${l_say:-0}" -lt "${l_verdict:-0}" ] && echo ordered)" "ordered"
assert_eq "the console line reports the advisory only when there is one, and names the remedy that now works" \
    "$(grep -c "doctor reports \${gate_advisory:-healthy}\${gate_advisory:+ as its only failing check} — booted slot committed\${gate_advisory:+ with that recorded as advisory; run './pithead apply' on the machine to re-mint}" "$BOOTSCRIPT")" "1"
assert_eq "there is exactly ONE commit path — the advisory does not duplicate the commit block" "$(grep -c 'rauc status mark-good' "$BOOTSCRIPT")" "2"
unset -f ar_run ap_line ga_run bl_line
unset CA AP GA RS COVER DJ_COVER rs_out BOOTSCRIPT l_hold l_units l_refresh l_nothing l_release l_remint l_adv l_pass l_say l_verdict
