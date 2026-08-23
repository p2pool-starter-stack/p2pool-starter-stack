#!/usr/bin/env bash
#
# Tier-1 proof for #1050: three of the four dashboard OS-update dead-end states. The fourth
# (the idle modal offering Download before any check has run) was already fixed by f617dee and
# is covered by build/dashboard/tests/frontend/osupdate.test.mjs's "Download with only a
# passive badge..." tests — not repeated here.
#
# tests/stack/run.sh already drives the whole check -> download -> verify -> install -> reboot
# chain end-to-end through the real control-file/subprocess door (the "black-box: control
# os-update verbs" block). This file is a sibling that calls the three fixed functions
# DIRECTLY (run_sourced), the same way the render_local_miner_config unit tests do, so it lives
# on its own rather than growing a file mid-split (#1105 Phase 1). It proves the three specific
# regressions the issue reported, not the whole flow again.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"

# A minimal appliance sandbox: stubbed rauc/curl/systemctl, no docker, no network. Every test
# below calls one control_os_* function directly with its own <cdir>, so nothing here needs the
# request-file staging or the control-run-pending drain loop.
OSB="$SANDBOX/os-update-recovery"
mkdir -p "$OSB/bin" "$OSB/osdir" "$OSB/cdir/results" "$OSB/cdir/audit"
: >"$OSB/cdir/audit/control.log"

cat >"$OSB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${SYSCTL_LOG:?}"
exit 0
EOF
cat >"$OSB/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    exit 0
    ;;
install)
    [ "${RAUC_INSTALL_FAIL:-0}" = "1" ] && {
        echo "slot device /dev/hostdisk3 staging $PWD" # host detail that must stay out of the result
        echo "installing failed"
        exit 1
    }
    echo "installing bundle: 100%"
    exit 0
    ;;
esac
exit 0
EOF
# Serves the release API by URL, exactly like run.sh's stub — plus a connection-failure knob
# this file adds: CURL_CONNFAIL=1 makes curl itself fail, the transport case #1050 cares about,
# distinct from a real (possibly non-2xx) answer from the server.
cat >"$OSB/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
[ "${CURL_CONNFAIL:-0}" = "1" ] && exit 7
case "$*" in
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n%s' "${GH_STUB_CODE:-200}"
    ;;
*) exit 22 ;;
esac
exit 0
EOF
chmod +x "$OSB/bin/systemctl" "$OSB/bin/rauc" "$OSB/bin/curl"

printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSB/info-good.txt"
printf 'compatible=pithead-os\n' >"$OSB/system.conf"
printf 'release\n' >"$OSB/variant-release"
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-v9.9.9.raucb","size":1000}]}' >"$OSB/api.json"
printf '%s' '{"message":"API rate limit exceeded for this IP.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}' >"$OSB/api-403.json"

# Shared appliance env for every call below. Exported (not `env`-prefixed): run_sourced spawns
# a subshell that inherits the exported environment, but `env` cannot invoke a bash FUNCTION
# like run_sourced at all — it can only exec a real binary, so an earlier version of this file
# that piped everything through `env` silently ran nothing (every call exited 127 before
# control_os_check et al. ever started, and every assertion read an absent result file).
export PATH="$OSB/bin:$PATH" PITHEAD_APPLIANCE=1 PITHEAD_VERSION=1.3.1 CONTROL_OS_BUDGET=5
export PITHEAD_OS_UPDATE_DIR="$OSB/osdir" RAUC_LOG="$OSB/rauc.log" CURL_LOG="$OSB/curl.log"
export SYSCTL_LOG="$OSB/sysctl.log" RAUC_INFO_OUT="$OSB/info-good.txt"
export PITHEAD_RAUC_SYSTEM_CONF="$OSB/system.conf" PITHEAD_VARIANT_FILE="$OSB/variant-release"
export CURL_API_RESPONSE="$OSB/api.json"
UOS="66666666-6666-4666-8666-666666666666"

echo "== unit: control_os_check claims the throttle only when the dial reaches the server (#1050) =="
: >"$OSB/curl.log"
rm -f "$OSB/osdir/target.json" "$OSB/osdir/.check-stamp"
CURL_CONNFAIL=1 run_sourced "$OSB" control_os_check "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "a transport failure is rejected" "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names Tor, not a server answer" "$(jq -r '.error' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "could not reach"
[ -f "$OSB/osdir/.check-stamp" ] && bad "a connectivity failure does not claim the throttle" "stamp exists" ||
    ok "a connectivity failure does not claim the throttle"
rm -f "$OSB/cdir/results/$UOS.json"
# The operator fixes their connectivity and retries immediately — must NOT be told to wait,
# because the failed attempt above never actually claimed the window.
run_sourced "$OSB" control_os_check "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "an immediate retry after a connectivity failure is NOT throttled" \
    "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "checked"
rm -f "$OSB/cdir/results/$UOS.json" "$OSB/osdir/target.json" "$OSB/osdir/.check-stamp"

# A rate-limited check DID reach GitHub (#1081) — the throttle must stay held, exactly as
# before. This is the regression guard: a naive "never touch the stamp on failure" fix would
# have broken this deliberate #1081 behaviour.
CURL_API_RESPONSE="$OSB/api-403.json" GH_STUB_CODE=403 \
    run_sourced "$OSB" control_os_check "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "a rate-limited check is rejected" "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "rejected"
[ -f "$OSB/osdir/.check-stamp" ] && ok "a rate-limited check still claims the throttle (#1081, unchanged)" ||
    bad "a rate-limited check still claims the throttle (#1081, unchanged)" "stamp missing"
rm -f "$OSB/cdir/results/$UOS.json"
run_sourced "$OSB" control_os_check "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "immediately retrying a REACHED failure is still throttled" \
    "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "and the refusal names the throttle window" \
    "$(jq -r '.error' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "10 minutes"
rm -f "$OSB/cdir/results/$UOS.json" "$OSB/osdir/target.json" "$OSB/osdir/.check-stamp"

echo "== unit: control_os_install writes a terminal-failure state, not a stuck 'installing' (#1050) =="
jq -n '{tag:"v9.9.9",size:1000,notes:"",ts:(now|floor)}' >"$OSB/osdir/target.json"
: >"$OSB/osdir/pithead-os-v9.9.9.raucb"
: >"$OSB/rauc.log"
RAUC_INSTALL_FAIL=1 run_sourced "$OSB" control_os_install "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "a failing install reports failed" "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "failed"
assert_eq "the persisted step is idle, not stuck on installing" \
    "$(jq -r '.step' "$OSB/cdir/results/os-update-state.json" 2>/dev/null)" "idle"
rm -f "$OSB/cdir/results/$UOS.json" "$OSB/cdir/results/os-update-state.json" "$OSB/osdir/target.json"

echo "== unit: control_os_reboot re-arms on a stale install instead of dead-ending (#1050) =="
jq -n '{from:"1.3.1",to:"9.9.9",ts:((now|floor) - 90000)}' >"$OSB/osdir/in-flight.json"
: >"$OSB/sysctl.log"
run_sourced "$OSB" control_os_reboot "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "a stale install still refuses the reboot" "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal still names the re-arm path" \
    "$(jq -r '.error' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "re-arms the reboot"
assert_eq "no reboot was ordered" "$(grep -c reboot "$OSB/sysctl.log" || true)" "0"
[ -f "$OSB/osdir/in-flight.json" ] && bad "the stale authorization is cleared, not left dangling" "in-flight.json still present" ||
    ok "the stale authorization is cleared, not left dangling"
assert_eq "the persisted step re-arms to idle (Check/Download offered again)" \
    "$(jq -r '.step' "$OSB/cdir/results/os-update-state.json" 2>/dev/null)" "idle"
rm -f "$OSB/cdir/results/$UOS.json" "$OSB/cdir/results/os-update-state.json"

# Regression guard: a FRESH install still reboots normally — only the stale path changed.
jq -n '{from:"1.3.1",to:"9.9.9",ts:(now|floor)}' >"$OSB/osdir/in-flight.json"
: >"$OSB/sysctl.log"
run_sourced "$OSB" control_os_reboot "" "$UOS" admin "$OSB/cdir" >/dev/null 2>&1
assert_eq "a fresh install still authorizes the reboot" "$(jq -r '.status' "$OSB/cdir/results/$UOS.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$OSB/sysctl.log")" "reboot"

echo ""
printf 'os-update recovery tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
