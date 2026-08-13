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
# A network.subnet move can't be hot-applied (#201) — the hot-apply loop must SKIP it (loud, not
# silent), leaving the real coverage to run.sh's --subnet phase.
BASELINE_PRUNE=1
resolve_overrides "monero.prune=true network.subnet=10.84.0.0/24"
rc=$?
assert_rc "subnet move skipped in the hot-apply loop" "$rc" "1"
assert_contains "subnet skip names the --subnet phase" "$SKIP_REASON" "--subnet phase"
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

echo "== moved-subnet matrix scenario (#201/#180) =="
# The matrix documents the subnet axis for coverage; the --subnet phase runs it for real (a subnet
# move can't be hot-applied), so the scenario is skipped by the hot-apply loop above.
assert_contains "matrix has a moved-subnet scenario" "$(scenario_names)" "local-pruned-main-subnet"
assert_contains "subnet scenario sets a non-default /24" "$(scenario_overrides local-pruned-main-subnet)" "network.subnet=10.84.0.0/24"

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

echo "== pool_flags_correct: P2POOL_FLAGS ground truth (#746) =="
# rx here serves the .env grep, not /api/state — return a P2POOL_FLAGS value directly.
rx() { printf '%s' "$FLAGS"; }
FLAGS='--mini --socks5 172.28.0.25:9050'
if pool_flags_correct "Mini"; then it_pass "flags --mini match Mini"; else it_fail "flags --mini match Mini" "returned non-zero"; fi
if pool_flags_correct "Main"; then it_fail "flags --mini reject Main" "passed"; else it_pass "flags --mini reject Main"; fi
FLAGS='--nano --socks5 172.28.0.25:9050'
if pool_flags_correct "Nano"; then it_pass "flags --nano match Nano"; else it_fail "flags --nano match Nano" "returned non-zero"; fi
FLAGS='--socks5 172.28.0.25:9050'
if pool_flags_correct "Main"; then it_pass "no sidechain flag matches Main"; else it_fail "no sidechain flag matches Main" "returned non-zero"; fi
if pool_flags_correct "Mini"; then it_fail "no sidechain flag rejects Mini" "passed"; else it_pass "no sidechain flag rejects Mini"; fi

echo "== assert_pool_type: four-way verdict (#454/#687/#746) =="
# Subshell-stub the emitters so the verdict under test can't touch this selftest's counters.
pool_verdict() { # <got> <want> <flags> -> PASS|WARN|FAIL
    (
        it_pass() { printf 'PASS'; }
        it_warn() { printf 'WARN'; }
        it_fail() { printf 'FAIL'; }
        FLAGS="$3"
        rx() { printf '%s' "$FLAGS"; }
        assert_pool_type "t" "$1" "$2"
    )
}
assert_eq "match -> PASS" "$(pool_verdict Mini Mini '--mini')" "PASS"
assert_eq "Unknown -> WARN (peer timing, #454)" "$(pool_verdict Unknown Mini '--mini')" "WARN"
assert_eq "empty -> WARN (peer timing)" "$(pool_verdict '' Mini '--mini')" "WARN"
assert_eq "wrong type, flags CORRECT -> WARN (classifier lag, #746)" "$(pool_verdict Main Mini '--mini --socks5 x')" "WARN"
assert_eq "wrong type, flags WRONG -> FAIL (render bug)" "$(pool_verdict Main Mini '--socks5 x')" "FAIL"

echo "== assert_tari_synced_required: earned lag tolerance (#746) =="
tari_verdict() { # <state> <seen> -> PASS|WARN|FAIL
    (
        it_pass() { printf 'PASS'; }
        it_warn() { printf 'WARN'; }
        it_fail() { printf 'FAIL'; }
        TARI_SEEN_DONE="$2"
        assert_tari_synced_required "$1"
    )
}
assert_eq "done -> PASS" "$(tari_verdict "done" 0)" "PASS"
assert_eq "loading BEFORE any done -> FAIL (never synced must fail)" "$(tari_verdict loading 0)" "FAIL"
assert_eq "loading AFTER a done -> WARN (post-restart re-discovery)" "$(tari_verdict loading 1)" "WARN"
assert_eq "syncing AFTER a done -> WARN" "$(tari_verdict syncing 1)" "WARN"
assert_eq "garbage state -> FAIL even after a done" "$(tari_verdict '' 1)" "FAIL"
# And the proof is recorded: a done sets TARI_SEEN_DONE for the caller's shell.
(
    it_pass() { :; }
    TARI_SEEN_DONE=0
    assert_tari_synced_required "done"
    [ "$TARI_SEEN_DONE" = "1" ]
) && it_pass "done records TARI_SEEN_DONE" || it_fail "done records TARI_SEEN_DONE" "flag not set"
rx() { printf '%s' "$FIXTURE"; } # restore the /api/state stub for later sections

echo "== _pred_hashes_flowing: gates on stratum.total_hashes > 0 =="
if _pred_hashes_flowing; then it_pass "_pred_hashes_flowing true when hashes>0"; else it_fail "_pred_hashes_flowing true when hashes>0" "returned non-zero on 12345"; fi
# total_hashes resets to 0 on a p2pool restart; the gate must hold there (the live-validation regression).
FIXTURE='{"stratum":{"conns":0,"total_hashes":0}}'
if _pred_hashes_flowing; then it_fail "_pred_hashes_flowing false when hashes==0" "passed on 0"; else it_pass "_pred_hashes_flowing false when hashes==0"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== _pred_db_healthy_is: gates on the top-level db_healthy flag (#202) =="
FIXTURE='{"db_healthy":true}'
if _pred_db_healthy_is true; then it_pass "_pred_db_healthy_is true on a healthy flag"; else it_fail "_pred_db_healthy_is true on a healthy flag" "returned non-zero on db_healthy:true"; fi
if _pred_db_healthy_is false; then it_fail "_pred_db_healthy_is holds the false edge on a healthy flag" "passed on db_healthy:true"; else it_pass "_pred_db_healthy_is holds the false edge on a healthy flag"; fi
# Boolean false must read as the real false edge — jq_get's `values` keeps it (a `// empty`
# fallback would swallow it and the fault wait would never trip).
FIXTURE='{"db_healthy":false}'
if _pred_db_healthy_is false; then it_pass "_pred_db_healthy_is true on an unhealthy flag"; else it_fail "_pred_db_healthy_is true on an unhealthy flag" "returned non-zero on db_healthy:false"; fi
# A payload missing the key entirely must match NEITHER edge — absent is not evidence.
FIXTURE='{"sync":{}}'
if _pred_db_healthy_is true; then it_fail "_pred_db_healthy_is holds when the key is missing" "passed on a missing key"; else it_pass "_pred_db_healthy_is holds when the key is missing"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== _pred_share_stats_nonempty: gates on .share_stats rows (#116) =="
FIXTURE='{"share_stats":[{"total":10,"rejected":0}]}'
if _pred_share_stats_nonempty; then it_pass "_pred_share_stats_nonempty true on a populated series"; else it_fail "_pred_share_stats_nonempty true on a populated series" "returned non-zero on 1 row"; fi
# Empty right after a dashboard recreate — the gate must hold so callers keep polling.
FIXTURE='{"share_stats":[]}'
if _pred_share_stats_nonempty; then it_fail "_pred_share_stats_nonempty false on an empty series" "passed on []"; else it_pass "_pred_share_stats_nonempty false on an empty series"; fi
# A payload missing the key entirely must not pass — absent is not evidence.
FIXTURE='{"sync":{}}'
if _pred_share_stats_nonempty; then it_fail "_pred_share_stats_nonempty false when the key is missing" "passed on a missing key"; else it_pass "_pred_share_stats_nonempty false when the key is missing"; fi
FIXTURE='{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}},"monero":{"mode":"Pruned"},"pool":{"type":"Main"},"proxy_workers":2,"stratum":{"conns":2,"total_hashes":12345}}'

echo "== metrics_has_pithead_sample: samples vs comments (#379) =="
if metrics_has_pithead_sample $'# HELP pithead_workers_online Workers online\npithead_workers_online 2'; then it_pass "sample line counts"; else it_fail "sample line counts" "missed a real sample"; fi
# '# HELP pithead_…' alone is a registered route with no data — must NOT count.
if metrics_has_pithead_sample '# HELP pithead_workers_online Workers online'; then it_fail "comment-only body does not count" "passed on HELP-only"; else it_pass "comment-only body does not count"; fi
if metrics_has_pithead_sample ''; then it_fail "empty body does not count" "passed on empty"; else it_pass "empty body does not count"; fi

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

echo "== rig_lock: the shared-bench flock (#430 / rigforge#183) =="
# The canonical rig lock, exercised in a sandbox via the env-overridable paths — no root, no
# /var/lock. Holders run as background subshells that acquire, signal readiness, then block on
# a fifo until released; probes run in their own subshells (rig_lock exits 75 when busy).
if ! command -v flock >/dev/null 2>&1; then
    it_warn "flock not found on this host (macOS?) — skipping; CI and the boxes run this section"
else
    RL="$TMP/rig-lock"
    mkdir -p "$RL"
    RIG_LOCK_FILE="$RL/lock"
    RIG_LOCK_HOLDER="$RL/holder"
    mkfifo "$RL/hold-x" "$RL/hold-s"

    # An exclusive holder (a stand-in for a running matrix).
    (rig_lock pithead "run.sh matrix" && : >"$RL/ready-x" && read -r _ <"$RL/hold-x") &
    _rl_x=$!
    wait_for 30 0.2 "exclusive holder to acquire" test -f "$RL/ready-x" || it_fail "exclusive holder acquired" "never signalled ready"
    if [ -f "$RIG_LOCK_HOLDER" ]; then it_pass "holder sidecar written on acquire"; else it_fail "holder sidecar written on acquire" "no $RIG_LOCK_HOLDER"; fi

    # (a) A second exclusive acquire fails fast: exit 75, message names the holder.
    out="$( (rig_lock rigforge e2e-real) 2>&1)"
    rc=$?
    assert_rc "second exclusive acquire exits 75 (EX_TEMPFAIL)" "$rc" "75"
    assert_contains "busy message names the holder" "$out" "pithead run.sh matrix"
    assert_contains "busy message points at RIG_LOCK_WAIT=1" "$out" "RIG_LOCK_WAIT=1"

    # (b) Shared vs an exclusive holder is excluded too.
    (rig_lock rigforge poll shared) >/dev/null 2>&1
    rc=$?
    assert_rc "shared acquire vs exclusive holder exits 75" "$rc" "75"

    # (c) RIG_LOCK_WAIT=1 queues: it blocks while the lock is held (gated on its own waiting
    # notice — a real signal, not a sleep), then acquires the moment the holder exits.
    (RIG_LOCK_WAIT=1 rig_lock pithead queued 2>"$RL/waiter.err") &
    _rl_q=$!
    wait_for 30 0.2 "queued waiter to block on the held lock" grep -qs waiting "$RL/waiter.err" ||
        kill "$_rl_q" 2>/dev/null # never acquired-nor-blocked: reap it so wait below fails loudly
    printf 'go\n' >"$RL/hold-x"   # release the exclusive holder
    wait "$_rl_q"
    rc=$?
    assert_rc "RIG_LOCK_WAIT=1 blocks, then acquires on release" "$rc" "0"
    wait "$_rl_x"

    # (d) Shared + shared coexist; exclusive vs a shared holder is excluded.
    (rig_lock pithead "run.sh --check" shared && : >"$RL/ready-s" && read -r _ <"$RL/hold-s") &
    _rl_s=$!
    wait_for 30 0.2 "shared holder to acquire" test -f "$RL/ready-s" || it_fail "shared holder acquired" "never signalled ready"
    (rig_lock rigforge poll shared) >/dev/null 2>&1
    rc=$?
    assert_rc "shared + shared coexist (rc 0)" "$rc" "0"
    (rig_lock rigforge e2e-real) >/dev/null 2>&1
    rc=$?
    assert_rc "exclusive vs shared holder exits 75" "$rc" "75"
    printf 'go\n' >"$RL/hold-s"
    wait "$_rl_s"

    # (e) Every holder exited normally, so the display-only sidecar is gone (EXIT-trap rm).
    if [ ! -f "$RIG_LOCK_HOLDER" ]; then it_pass "holder sidecar removed on normal exit"; else it_fail "holder sidecar removed on normal exit" "sidecar still present"; fi

    # (f) The KERNEL flock is genuinely held for the lifetime of a --local run, and released after —
    # probed DIRECTLY with flock (not via rig_lock) so we assert the real lock state a colliding
    # RigForge/pithead run on the box would see. Crucially the holder-marker path is deliberately
    # UNWRITABLE here (root-owned /run is unwritable for a non-root runner): this proves the marker
    # write is best-effort and can NEVER stop the flock from being held — the Bug-1 regression where a
    # failed holder-write left the box unreserved. If acquisition were coupled to the marker, the
    # holder below would never signal ready and we reap it, so the test FAILS FAST (never hangs).
    mkfifo "$RL/hold-f"
    mkdir -p "$RL/noholder" && chmod 000 "$RL/noholder" # unwritable marker dir, mimics /run for non-root
    (RIG_LOCK_HOLDER="$RL/noholder/x" rig_lock pithead "run.sh matrix" && : >"$RL/ready-f" && read -r _ <"$RL/hold-f") &
    _rl_f=$!
    if wait_for 30 0.2 "run holds the flock despite an unwritable marker path" test -f "$RL/ready-f"; then
        if flock -n -x "$RIG_LOCK_FILE" true 2>/dev/null; then
            it_fail "flock GENUINELY held mid --local run" "a second exclusive flock succeeded — the box is unreserved (Bug 1)"
        else
            it_pass "flock GENUINELY held mid --local run (unwritable marker notwithstanding)"
        fi
        printf 'go\n' >"$RL/hold-f" # release the holder (safe: it is alive, reading the fifo)
        wait "$_rl_f"
        if flock -n -x "$RIG_LOCK_FILE" true 2>/dev/null; then
            it_pass "flock released after the --local run exits (kernel drops the FD-held lock)"
        else
            it_fail "flock released after the --local run exits" "lock still held after the holder process exited"
        fi
    else
        # Never acquired: the marker write blocked acquisition (the Bug-1 coupling). Fail fast — reap
        # the holder rather than blocking forever on a fifo write nothing will read.
        it_fail "flock GENUINELY held mid --local run" "holder never acquired — a failed marker write blocked lock acquisition (Bug 1)"
        kill "$_rl_f" 2>/dev/null
        wait "$_rl_f" 2>/dev/null
    fi
    chmod 755 "$RL/noholder" # restore so the TMP-dir EXIT cleanup can remove it

    unset RIG_LOCK_FILE RIG_LOCK_HOLDER
fi

echo "== provision: force-clean checkout tolerates untracked leftovers, keeps results/backups/data (#454) =="
# Mirrors e2e.sh provision(): the disposable e2e checkout must survive a stray untracked file at a
# path the target branch tracks (the reported abort), while never wiping the harness's results/ or
# the shared chains' data/ + rollback backups/. The FLAGS are what's under test.
_gt="$(mktemp -d)"
(
    cd "$_gt" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    git commit -q --allow-empty -m base
    mkdir -p tests/integration/benchmarks
    echo tracked >tests/integration/benchmarks/bench.sh
    git add -A && git commit -q -m feature
    _feat="$(git rev-parse HEAD)"
    git checkout -q -B other HEAD~1 # a tree WITHOUT bench.sh
    # A leftover untracked file at the colliding path + cruft + the dirs the harness must keep.
    mkdir -p tests/integration/benchmarks results backups data
    echo leftover >tests/integration/benchmarks/bench.sh
    printf x >results/keep
    printf x >backups/keep
    printf x >data/keep
    printf x >stray-cruft
    git checkout -q -f -B feature "$_feat"
    git reset -q --hard "$_feat"
    git clean -qfdx -e /results -e /backups -e /data
) >/dev/null 2>&1
assert_eq "-f overwrites the untracked leftover instead of aborting" "$(cat "$_gt/tests/integration/benchmarks/bench.sh" 2>/dev/null)" "tracked"
for _d in results backups data; do
    if [ -f "$_gt/$_d/keep" ]; then it_pass "clean keeps $_d/"; else it_fail "clean keeps $_d/" "$_d/keep was removed"; fi
done
if [ ! -e "$_gt/stray-cruft" ]; then it_pass "clean removes untracked cruft"; else it_fail "clean removes untracked cruft" "stray-cruft survived"; fi
rm -rf "$_gt"

echo "== provision: seeds from the live bundle when one exists, else falls back to canonical (#880) =="
# Mirrors e2e.sh provision()'s config-seeding selection + drift check, with plain dirs standing in
# for the on_bench SSH calls — the selection/diff logic itself is pure and needs no bench.
_sd="$(mktemp -d)"
_canon="$_sd/canonical"
_live="$_sd/current"
_e2e="$_sd/e2e"
mkdir -p "$_canon" "$_live" "$_e2e"
echo '{"monero":{},"dashboard":{}}' >"$_canon/config.json"
echo canon-env >"$_canon/.env"
echo '{"monero":{},"dashboard":{},"telegram":{}}' >"$_live/config.json" # live has a key canonical lacks
echo live-env >"$_live/.env"

seed_from() { # <cfg_dir> -> copies into $_e2e, mirroring the cp -a pair in provision()
    cp -a "$1/config.json" "$_e2e/config.json" && cp -a "$1/.env" "$_e2e/.env"
}

# Live bundle present: seeds from it, and a top-level-key diff is non-empty (the drift signal).
seed_from "$_live"
assert_eq "seeds config.json from the live bundle" "$(cat "$_e2e/config.json")" "$(cat "$_live/config.json")"
assert_eq "seeds .env from the live bundle" "$(cat "$_e2e/.env")" "live-env"
_kd="$(diff <(jq -r 'keys[]' "$_live/config.json" | sort) <(jq -r 'keys[]' "$_canon/config.json" | sort))"
if [ -n "$_kd" ]; then it_pass "drift check flags canonical missing a live key"; else it_fail "drift check flags canonical missing a live key" "no diff reported"; fi

# No live bundle (symlink missing/broken): falls back to canonical, and there's nothing to diff.
rm -rf "$_live"
[ -e "$_live/config.json" ] && [ -e "$_live/.env" ] && it_fail "no-live-bundle detection" "should be absent" || it_pass "no-live-bundle detection treats missing dir as absent"
seed_from "$_canon"
assert_eq "falls back to seeding config.json from canonical" "$(cat "$_e2e/config.json")" "$(cat "$_canon/config.json")"
assert_eq "falls back to seeding .env from canonical" "$(cat "$_e2e/.env")" "canon-env"
rm -rf "$_sd"

# --- Tally ------------------------------------------------------------------
echo ""
echo "selftest: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
