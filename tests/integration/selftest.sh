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
assert_contains "string gets quoted" "$(overrides_to_jq monero.mode=remote)" '.monero.mode="remote"'
assert_contains "integer stays unquoted" "$(overrides_to_jq monero.remote.rpc_port=18081)" '.monero.remote.rpc_port=18081'
assert_contains "negative int unquoted" "$(overrides_to_jq foo=-5)" '.foo=-5'
assert_contains "dotted ip is a string" "$(overrides_to_jq monero.remote.host=10.0.0.5)" '.monero.remote.host="10.0.0.5"'
assert_eq "no overrides is identity" "$(overrides_to_jq)" '.'
assert_eq "empty token is skipped" "$(overrides_to_jq '' a=1)" '. | .a=1'

echo "== resolve_overrides: prerequisite gate (never mutates the canonical chain) =="
# Happy path: a scenario needing no alt resources resolves unchanged.
BASELINE_PRUNE=1
PRUNED_DATA_DIR=""
FULL_DATA_DIR=""
REMOTE_MONERO_HOST=""
resolve_overrides "monero.mode=local monero.prune=true p2pool.pool=main"
rc=$?
assert_rc "no-prereq scenario resolves" "$rc" "0"
assert_eq "RESOLVED unchanged when no prereq" "$RESOLVED" "monero.mode=local monero.prune=true p2pool.pool=main"
# prune=false (full) on a pruned box: SKIP without a dir, augment with one — never flips the canonical DB.
BASELINE_PRUNE=1
FULL_DATA_DIR=""
resolve_overrides "monero.prune=false"
rc=$?
assert_rc "full-on-pruned-box skips without dir" "$rc" "1"
assert_contains "skip names --full-data-dir" "$SKIP_REASON" "--full-data-dir"
FULL_DATA_DIR="/srv/full"
resolve_overrides "monero.prune=false"
rc=$?
assert_rc "full-on-pruned-box ok with dir" "$rc" "0"
assert_contains "augments full data_dir" "$RESOLVED" "monero.data_dir=/srv/full"
# prune=true (pruned) on a full box: SKIP without a dir.
BASELINE_PRUNE=0
PRUNED_DATA_DIR=""
resolve_overrides "monero.prune=true"
rc=$?
assert_rc "pruned-on-full-box skips without dir" "$rc" "1"
assert_contains "skip names --pruned-data-dir" "$SKIP_REASON" "--pruned-data-dir"
# remote mode: SKIP without an endpoint, augment with one.
BASELINE_PRUNE=1
REMOTE_MONERO_HOST=""
resolve_overrides "monero.mode=remote"
rc=$?
assert_rc "remote skips without endpoint" "$rc" "1"
assert_contains "skip names --remote-monero-host" "$SKIP_REASON" "--remote-monero-host"
REMOTE_MONERO_HOST="10.0.0.5:18081"
resolve_overrides "monero.mode=remote"
rc=$?
assert_rc "remote ok with endpoint" "$rc" "0"
assert_contains "augments remote host" "$RESOLVED" "monero.remote.host=10.0.0.5:18081"
# Compound prerequisites both augment.
BASELINE_PRUNE=1
FULL_DATA_DIR="/srv/full"
REMOTE_MONERO_HOST="10.0.0.5:18081"
resolve_overrides "monero.mode=remote monero.prune=false"
rc=$?
assert_rc "compound prereqs resolve" "$rc" "0"
assert_contains "compound: data_dir" "$RESOLVED" "monero.data_dir=/srv/full"
assert_contains "compound: remote host" "$RESOLVED" "monero.remote.host=10.0.0.5:18081"
unset BASELINE_PRUNE PRUNED_DATA_DIR FULL_DATA_DIR REMOTE_MONERO_HOST

echo "== render_scenario_config: applies overrides, stays valid JSON =="
BASE='{"monero":{"mode":"local","prune":true,"wallet_address":"49keep"},"p2pool":{"pool":"main"}}'
RENDERED="$(render_scenario_config "$BASE" monero.mode=remote monero.prune=false p2pool.pool=mini)"
printf '%s' "$RENDERED" | jq empty 2>/dev/null && it_pass "rendered config is valid JSON" || it_fail "rendered config is valid JSON" "jq rejected it"
assert_eq "override: mode" "$(jq_get "$RENDERED" '.monero.mode')" "remote"
assert_eq "override: prune" "$(jq_get "$RENDERED" '.monero.prune')" "false"
assert_eq "override: pool" "$(jq_get "$RENDERED" '.p2pool.pool')" "mini"
assert_eq "preserved: wallet" "$(jq_get "$RENDERED" '.monero.wallet_address')" "49keep"

echo "== clearnet initial sync overrides + matrix (#183) =="
# Per-component flags render as JSON booleans (overrides_to_jq types true/false), so pithead's
# `// false` + normalize_bool read them correctly. Default baseline omits the key entirely.
CN="$(render_scenario_config "$BASE" monero.clearnet_initial_sync=true tari.clearnet_initial_sync=true)"
printf '%s' "$CN" | jq empty 2>/dev/null && it_pass "clearnet config is valid JSON" || it_fail "clearnet config is valid JSON" "jq rejected it"
assert_eq "monero clearnet renders boolean true" "$(jq_get "$CN" '.monero.clearnet_initial_sync')" "true"
assert_eq "tari clearnet renders boolean true" "$(jq_get "$CN" '.tari.clearnet_initial_sync')" "true"
assert_eq "clearnet absent in baseline (default off)" "$(jq_get "$BASE" '.monero.clearnet_initial_sync')" ""
# The matrix carries a dedicated clearnet scenario so the live suite exercises the on-state on a box.
assert_contains "matrix has a clearnet scenario" "$(scenario_names)" "local-pruned-main-clearnet-sync"
assert_contains "clearnet scenario enables monero" "$(scenario_overrides local-pruned-main-clearnet-sync)" "monero.clearnet_initial_sync=true"
assert_contains "clearnet scenario enables tari" "$(scenario_overrides local-pruned-main-clearnet-sync)" "tari.clearnet_initial_sync=true"

echo "== expected/absent services: profile gating =="
LOCAL='{"monero":{"mode":"local"}}'
REMOTE='{"monero":{"mode":"remote"}}'
assert_contains "local includes monerod" "$(expected_services "$LOCAL")" "monerod"
assert_contains "local includes p2pool" "$(expected_services "$LOCAL")" "p2pool"
case "$(expected_services "$REMOTE")" in *monerod*) it_fail "remote excludes monerod" "monerod present" ;; *) it_pass "remote excludes monerod" ;; esac
assert_eq "remote marks monerod absent" "$(absent_services "$REMOTE")" "monerod"
assert_eq "local marks nothing absent" "$(absent_services "$LOCAL")" ""
assert_eq "pool_label main" "$(pool_label main)" "Main"
assert_eq "pool_label mini" "$(pool_label mini)" "Mini"
assert_eq "pool_label nano" "$(pool_label nano)" "Nano"
assert_eq "pool_label unknown passes through" "$(pool_label custom)" "custom"

echo "== redact: secrets never leak into artifacts =="
ONION="$(printf 'a%.0s' $(seq 1 56)).onion"
SECRETS="$(printf 'PROXY_AUTH_TOKEN=deadbeefcafe\nMONERO_NODE_PASSWORD=hunter2\nMONERO_RPC_PASSWORD=p\nBACKUP_SECRET=s3kr3t\nMONERO_ONION_ADDRESS=%s\nHOST_IP=box.lan\n' "$ONION")"
REDACTED="$(printf '%s' "$SECRETS" | redact)"
assert_contains "token redacted" "$REDACTED" "PROXY_AUTH_TOKEN=<redacted>"
assert_contains "password redacted" "$REDACTED" "MONERO_NODE_PASSWORD=<redacted>"
assert_contains "*_PASSWORD redacted" "$REDACTED" "MONERO_RPC_PASSWORD=<redacted>"
assert_contains "*_SECRET redacted" "$REDACTED" "BACKUP_SECRET=<redacted>"
assert_contains "onion redacted" "$REDACTED" "<redacted>.onion"
assert_contains "non-secret kept" "$REDACTED" "HOST_IP=box.lan"
case "$REDACTED" in *deadbeefcafe*) it_fail "raw token absent" "token leaked" ;; *) it_pass "raw token absent" ;; esac
case "$REDACTED" in *s3kr3t*) it_fail "raw secret absent" "secret leaked" ;; *) it_pass "raw secret absent" ;; esac

echo "== matrix: every axis value is covered =="
CORPUS="$(scenario_matrix | cut -f2 | tr '\n' ' ')"
while IFS= read -r val; do
    [ -z "$val" ] && continue
    case " $CORPUS " in
    *" $val "*) it_pass "axis covered: $val" ;;
    *) it_fail "axis covered: $val" "no scenario sets $val" ;;
    esac
done < <(axis_coverage)

echo "== scenarios: lookup helpers =="
assert_ne "scenario_names is non-empty" "$(scenario_names | head -n1)" ""
assert_eq "scenario count matches matrix" "$(scenario_names | grep -c .)" "$(scenario_matrix | grep -c .)"
assert_contains "overrides lookup works" "$(scenario_overrides remote-main-secure-tari)" "monero.mode=remote"
# An unknown scenario name must fail (return 1) and print nothing — never silently resolve.
miss="$(scenario_overrides no-such-scenario)"
rc=$?
assert_rc "unknown scenario returns 1" "$rc" "1"
assert_eq "unknown scenario prints nothing" "$miss" ""

echo "== rx: local exec runs in the stack dir =="
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf 'marker' >"$TMP/sentinel"
IT_MODE="local"
IT_REMOTE_DIR="$TMP"
assert_eq "rx runs command on target" "$(rx 'cat sentinel')" "marker"
assert_eq "rx cwd is the stack dir" "$(rx 'pwd')" "$TMP"

echo "== api_state + jq_get: parse a fixture =="
# Stub rx so api_state returns a representative /api/state payload.
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'
rx() { printf '%s' "$FIXTURE"; }
ST="$(api_state)"
assert_eq "parse monero sync state" "$(jq_get "$ST" '.sync.monero.state')" "done"
assert_eq "parse pool type" "$(jq_get "$ST" '.pool.type')" "Main"
assert_eq "parse worker count" "$(jq_get "$ST" '.proxy_workers')" "2"
assert_eq "missing key -> empty" "$(jq_get "$ST" '.nope.nope')" ""

echo "== _pred_tari_synced: gates on .sync.tari.state =="
# rx is still stubbed to FIXTURE above (sync.tari.state == "done").
if _pred_tari_synced; then it_pass "_pred_tari_synced true when tari done"; else it_fail "_pred_tari_synced true when tari done" "returned non-zero on done"; fi
# A still-loading Tari must hold the gate (this regression was caught by live validation: asserting cold caught it here).
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"loading"}}}'
if _pred_tari_synced; then it_fail "_pred_tari_synced false when tari loading" "passed on loading"; else it_pass "_pred_tari_synced false when tari loading"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== _pred_monero_panel_done: gates on .sync.monero.state =="
# rx is stubbed to FIXTURE above (sync.monero.state == "done").
if _pred_monero_panel_done; then it_pass "_pred_monero_panel_done true when monero done"; else it_fail "_pred_monero_panel_done true when monero done" "returned non-zero on done"; fi
# A still-"loading" panel must hold the settle wait — the v1.0.0 release-gate flake: a cold single-shot
# read raced the dashboard's first poll after a restart and spuriously failed a synced node.
FIXTURE='{"sync":{"monero":{"state":"loading"},"tari":{"state":"done"}}}'
if _pred_monero_panel_done; then it_fail "_pred_monero_panel_done false when monero loading" "passed on loading"; else it_pass "_pred_monero_panel_done false when monero loading"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== _pred_pool_ready: gates on .pool.type matching expected =="
if _pred_pool_ready "Main"; then it_pass "_pred_pool_ready true when pool matches"; else it_fail "_pred_pool_ready true when pool matches" "returned non-zero on Main==Main"; fi
if _pred_pool_ready "Mini"; then it_fail "_pred_pool_ready false when pool differs" "passed on Main!=Mini"; else it_pass "_pred_pool_ready false when pool differs"; fi
# "Unknown" right after a pool switch must hold the gate (the live-validation regression caught here).
FIXTURE='{"pool":{"type":"Unknown"}}'
if _pred_pool_ready "Main"; then it_fail "_pred_pool_ready false when pool Unknown" "passed on Unknown"; else it_pass "_pred_pool_ready false when pool Unknown"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== _pred_hashes_flowing: gates on stratum.total_hashes > 0 =="
if _pred_hashes_flowing; then it_pass "_pred_hashes_flowing true when hashes>0"; else it_fail "_pred_hashes_flowing true when hashes>0" "returned non-zero on 12345"; fi
# total_hashes resets to 0 on a p2pool restart; the gate must hold there (the live-validation regression).
FIXTURE='{"stratum":{"conns":0,"total_hashes":0}}'
if _pred_hashes_flowing; then it_fail "_pred_hashes_flowing false when hashes==0" "passed on 0"; else it_pass "_pred_hashes_flowing false when hashes==0"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== dispatch loop: a stdin-draining child must not skip iterations =="
# Reproduces the matrix bug class: an ssh inside `while read … done < <(…)` that inherits stdin
# drains the loop and silently runs only the first scenario. The guard is `</dev/null` on the
# child (plus `ssh -n` in rx). Verify the technique keeps every iteration alive.
_seen=0
_drainer() { cat >/dev/null 2>&1 || true; } # stands in for ssh inheriting + draining stdin
while IFS= read -r _l; do
    [ -z "$_l" ] && continue
    _seen=$((_seen + 1))
    _drainer </dev/null
done < <(printf 'one\ntwo\nthree\n')
assert_eq "loop visits every line with </dev/null guard" "$_seen" "3"

echo "== service_state parsing (fault-injection predicates) =="
assert_eq "state of 'running healthy'" "$(svc_state_of 'running healthy')" "running"
assert_eq "health of 'running healthy'" "$(svc_health_of 'running healthy')" "healthy"
assert_eq "state of 'missing none'" "$(svc_state_of 'missing none')" "missing"
assert_eq "health of 'running unhealthy'" "$(svc_health_of 'running unhealthy')" "unhealthy"
assert_eq "state of 'exited none'" "$(svc_state_of 'exited none')" "exited"

echo "== egress_verdict: clean / leak / verifier-couldn't-run are distinct =="
assert_eq "OK marker -> ok" "$(egress_verdict $'poll 1/3\n[verify-egress] OK')" "ok"
assert_eq "leak line -> leak" "$(egress_verdict $'  ✗ p2pool: 2 PERSISTENT PUBLIC connection(s) — CLEARNET LEAK:')" "leak"
assert_eq "script-not-found -> inconclusive" "$(egress_verdict $'bash: bench-verify-egress.sh: No such file or directory')" "inconclusive"
assert_eq "empty output -> inconclusive" "$(egress_verdict '')" "inconclusive"

echo "== assertion helpers: counters behave =="
_p="$IT_PASS"
_f="$IT_FAIL"
assert_num_ge "num_ge passes when equal" 5 5
assert_num_gt "num_gt passes when greater" 6 5
[ "$IT_PASS" -gt "$_p" ] && it_pass "passing assertions increment IT_PASS" || it_fail "passing assertions increment IT_PASS" "no increment"

# --- Tally ------------------------------------------------------------------
echo ""
echo "selftest: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
