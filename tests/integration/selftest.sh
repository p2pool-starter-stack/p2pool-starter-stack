#!/usr/bin/env bash
#
# Self-test for the integration harness's pure logic (config rendering, expectation
# derivation, redaction, matrix coverage, the SSH/local exec wrapper, JSON parsing).
#
# This runs anywhere — no real server needed — so it can gate every PR (unlike the live
# matrix in run.sh, which needs the test box). It dogfoods the very assertion helpers the
# harness ships. Run: tests/integration/selftest.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/scenarios.sh"

echo "== overrides_to_jq: value typing =="
assert_contains "boolean stays unquoted" "$(overrides_to_jq monero.prune=false)" '.monero.prune=false'
assert_contains "string gets quoted"     "$(overrides_to_jq monero.mode=remote)"  '.monero.mode="remote"'
assert_contains "integer stays unquoted"  "$(overrides_to_jq monero.remote.rpc_port=18081)" '.monero.remote.rpc_port=18081'
assert_contains "negative int unquoted"   "$(overrides_to_jq foo=-5)" '.foo=-5'
assert_contains "dotted ip is a string"   "$(overrides_to_jq monero.remote.host=10.0.0.5)" '.monero.remote.host="10.0.0.5"'

echo "== render_scenario_config: applies overrides, stays valid JSON =="
BASE='{"monero":{"mode":"local","prune":true,"wallet_address":"49keep"},"p2pool":{"pool":"main"}}'
RENDERED="$(render_scenario_config "$BASE" monero.mode=remote monero.prune=false p2pool.pool=mini)"
printf '%s' "$RENDERED" | jq empty 2>/dev/null && it_pass "rendered config is valid JSON" || it_fail "rendered config is valid JSON" "jq rejected it"
assert_eq "override: mode"   "$(jq_get "$RENDERED" '.monero.mode')"  "remote"
assert_eq "override: prune"  "$(jq_get "$RENDERED" '.monero.prune')" "false"
assert_eq "override: pool"   "$(jq_get "$RENDERED" '.p2pool.pool')"  "mini"
assert_eq "preserved: wallet" "$(jq_get "$RENDERED" '.monero.wallet_address')" "49keep"

echo "== expected/absent services: profile gating =="
LOCAL='{"monero":{"mode":"local"}}'
REMOTE='{"monero":{"mode":"remote"}}'
assert_contains "local includes monerod"  "$(expected_services "$LOCAL")"  "monerod"
assert_contains "local includes p2pool"   "$(expected_services "$LOCAL")"  "p2pool"
case "$(expected_services "$REMOTE")" in *monerod*) it_fail "remote excludes monerod" "monerod present" ;; *) it_pass "remote excludes monerod" ;; esac
assert_eq "remote marks monerod absent"   "$(absent_services "$REMOTE")" "monerod"
assert_eq "local marks nothing absent"    "$(absent_services "$LOCAL")" ""
assert_eq "pool_label main"  "$(pool_label main)" "Main"
assert_eq "pool_label nano"  "$(pool_label nano)" "Nano"

echo "== redact: secrets never leak into artifacts =="
ONION="$(printf 'a%.0s' $(seq 1 56)).onion"
SECRETS="$(printf 'PROXY_AUTH_TOKEN=deadbeefcafe\nMONERO_NODE_PASSWORD=hunter2\nMONERO_ONION_ADDRESS=%s\nHOST_IP=box.lan\n' "$ONION")"
REDACTED="$(printf '%s' "$SECRETS" | redact)"
assert_contains "token redacted"    "$REDACTED" "PROXY_AUTH_TOKEN=<redacted>"
assert_contains "password redacted"  "$REDACTED" "MONERO_NODE_PASSWORD=<redacted>"
assert_contains "onion redacted"     "$REDACTED" "<redacted>.onion"
assert_contains "non-secret kept"    "$REDACTED" "HOST_IP=box.lan"
case "$REDACTED" in *deadbeefcafe*) it_fail "raw token absent" "token leaked" ;; *) it_pass "raw token absent" ;; esac

echo "== matrix: every axis value is covered =="
CORPUS="$(scenario_matrix | cut -f2 | tr '\n' ' ')"
while IFS= read -r val; do
    [ -z "$val" ] && continue
    case " $CORPUS " in
        *" $val "*) it_pass "axis covered: $val" ;;
        *)          it_fail "axis covered: $val" "no scenario sets $val" ;;
    esac
done < <(axis_coverage)

echo "== scenarios: lookup helpers =="
assert_ne "scenario_names is non-empty" "$(scenario_names | head -n1)" ""
assert_contains "overrides lookup works" "$(scenario_overrides remote-main-secure-tari)" "monero.mode=remote"

echo "== rx: local exec runs in the stack dir =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'marker' > "$TMP/sentinel"
IT_MODE="local"; IT_REMOTE_DIR="$TMP"
assert_eq "rx runs command on target" "$(rx 'cat sentinel')" "marker"
assert_eq "rx cwd is the stack dir"   "$(rx 'pwd')" "$TMP"

echo "== api_state + jq_get: parse a fixture =="
# Stub rx so api_state returns a representative /api/state payload.
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'
rx() { printf '%s' "$FIXTURE"; }
ST="$(api_state)"
assert_eq "parse monero sync state" "$(jq_get "$ST" '.sync.monero.state')" "done"
assert_eq "parse pool type"         "$(jq_get "$ST" '.pool.type')" "Main"
assert_eq "parse worker count"      "$(jq_get "$ST" '.proxy_workers')" "2"
assert_eq "missing key -> empty"    "$(jq_get "$ST" '.nope.nope')" ""

echo "== service_state parsing (fault-injection predicates) =="
assert_eq "state of 'running healthy'"  "$(svc_state_of 'running healthy')"  "running"
assert_eq "health of 'running healthy'" "$(svc_health_of 'running healthy')" "healthy"
assert_eq "state of 'missing none'"     "$(svc_state_of 'missing none')"     "missing"
assert_eq "health of 'running unhealthy'" "$(svc_health_of 'running unhealthy')" "unhealthy"
assert_eq "state of 'exited none'"      "$(svc_state_of 'exited none')"      "exited"

echo "== assertion helpers: counters behave =="
_p="$IT_PASS"; _f="$IT_FAIL"
assert_num_ge "num_ge passes when equal" 5 5
assert_num_gt "num_gt passes when greater" 6 5
[ "$IT_PASS" -gt "$_p" ] && it_pass "passing assertions increment IT_PASS" || it_fail "passing assertions increment IT_PASS" "no increment"

# --- Tally ------------------------------------------------------------------
echo ""
echo "selftest: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
