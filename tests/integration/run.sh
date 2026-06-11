#!/usr/bin/env bash
#
# Pithead end-to-end integration test runner (issue #54).
#
# Drives a REAL, already-provisioned Pithead server through the config matrix and asserts the
# stack behaves — containers healthy, nodes synced, miners mining, the dashboard reading the
# right live state, status exit codes correct, and secrets preserved across re-applies.
#
# The box is assumed already deployed and synced with miners connected; the harness moves
# between scenarios with non-interactive `pithead apply -y` (recreates only changed
# containers, reuses the synced chain data dirs — never re-syncs, never re-provisions Tor).
# It saves the box's original config.json up front and restores it at the end.
#
#   ./run.sh --host user@1.2.3.4 [--dir ~/pithead] [options]
#   ./run.sh --local             [--dir /path/to/stack] [options]
#
# Read-only against the canonical chain data dirs; safe to run against the live box. See
# docs/integration-testing.md for provisioning, the safety model, and CI/release wiring.
#
set -uo pipefail   # NOT -e: we deliberately continue-on-error to collect the whole matrix.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/scenarios.sh"

# --- Defaults / globals -----------------------------------------------------
IT_MODE="ssh"
IT_SSH_DEST=""
IT_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
IT_REMOTE_DIR="pithead"
IT_PITHEAD="./pithead"
IT_CURRENT_SCENARIO=""
ONLY_SCENARIO=""
CHECK_ONLY=0
READINESS=0
RUN_LIFECYCLE=0
RUN_FAULTS=0
SAFETY_BACKUP=0
SAFETY_ARCHIVE=""
KEEP_STATE=0
EXPECTED_WORKERS=2
REMOTE_MONERO_HOST=""
PRUNED_DATA_DIR=""
FULL_DATA_DIR=""
OUT_DIR="$HERE/results"
BASELINE_CONFIG=""
BASELINE_PRUNE=""
BASELINE_SECRET_FP=""

usage() {
    cat <<'EOF'
Pithead integration test runner

USAGE:
  run.sh --host <user@host> [options]     drive the box over SSH
  run.sh --local            [options]     drive a stack on this machine

CONNECTION:
  --host <user@host>     SSH destination of the test server
  --identity <keyfile>   SSH private key (adds -i <keyfile>)
  --ssh-opt <opt>        extra ssh -o option (repeatable), e.g. --ssh-opt Port=2222
  --local                run against a stack on this machine instead of over SSH
  --dir <path>           the Pithead stack directory ON THE BOX, relative to the SSH login
                         dir or absolute (default: pithead). Avoid a literal ~ — your local
                         shell would expand it before the box sees it.
  --pithead <cmd>        how to invoke pithead on the box (default: ./pithead;
                         use "sudo ./pithead" if docker needs root there)

MATRIX:
  --check                NON-DESTRUCTIVE: assert the box's current live state only — no config
                         changes, no apply, no restore. The safe first run / health check.
  --readiness            NON-DESTRUCTIVE: assess whether the box is fit to be a release/
                         validation server (synced chains reusable, snapshot-capable FS, disk
                         headroom, secrets not world-readable, dashboard localhost-only).
  --scenario <name>      run only one scenario (see --list)
  --workers <n>          miners expected online while mining (default: 2)
  --remote-monero-host <h>  external node endpoint for the remote-mode scenario
                            (e.g. the box's own synced node on its LAN IP)
  --pruned-data-dir <d>  synced PRUNED monero data dir (enables the pruned case when the
                         box's baseline is full)
  --full-data-dir <d>    synced FULL monero data dir (enables the full case when the box's
                         baseline is pruned)
  --lifecycle            also run the lifecycle phase (restart, apply secret-preservation)
  --safety-backup        take a `pithead backup` BEFORE the destructive scenarios; if anything
                         fails, automatically roll the box back to it (down → restore → up).
                         The archive is removed on success. Recommended for the destructive
                         matrix on a precious box. Also exercises backup/restore end-to-end.
  --fault-injection      also run the fault-injection phase: deliberately break monerod
                         (stop / SIGSTOP / remove) and assert pithead's status verdicts
                         (down / unhealthy / missing) and the failover→recovery cycle.
                         DESTRUCTIVE-then-restored; local mode only. Slow (healthcheck +
                         node-health debounce).
  --keep                 do NOT restore the original config.json at the end (leaves the box
                         on the last scenario — useful for debugging)

OUTPUT:
  --out <dir>            where to write artifacts (default: tests/integration/results)
  --list                 print the scenario matrix and axis coverage, then exit
  -h, --help             this help

Scenarios whose prerequisites are missing (a full/pruned alt data dir, or a remote endpoint)
are reported SKIPPED — never silently dropped, never mutating the canonical synced chain.
EOF
}

# --- Arg parsing ------------------------------------------------------------
# shellcheck disable=SC2034  # the data-dir / remote-host globals are consumed by lib.sh:resolve_overrides
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --host)       IT_SSH_DEST="$2"; IT_MODE="ssh"; shift 2 ;;
            --identity)   IT_SSH_OPTS+=(-i "$2"); shift 2 ;;
            --ssh-opt)    IT_SSH_OPTS+=(-o "$2"); shift 2 ;;
            --local)      IT_MODE="local"; shift ;;
            --dir)        IT_REMOTE_DIR="$2"; shift 2 ;;
            --pithead)    IT_PITHEAD="$2"; shift 2 ;;
            --check)      CHECK_ONLY=1; shift ;;
            --readiness)  READINESS=1; shift ;;
            --scenario)   ONLY_SCENARIO="$2"; shift 2 ;;
            --workers)    EXPECTED_WORKERS="$2"; shift 2 ;;
            --remote-monero-host) REMOTE_MONERO_HOST="$2"; shift 2 ;;
            --pruned-data-dir)    PRUNED_DATA_DIR="$2"; shift 2 ;;
            --full-data-dir)      FULL_DATA_DIR="$2"; shift 2 ;;
            --lifecycle)  RUN_LIFECYCLE=1; shift ;;
            --fault-injection) RUN_FAULTS=1; shift ;;
            --safety-backup)   SAFETY_BACKUP=1; shift ;;
            --keep)       KEEP_STATE=1; shift ;;
            --out)        OUT_DIR="$2"; shift 2 ;;
            --list)       print_list; exit 0 ;;
            -h|--help)    usage; exit 0 ;;
            *)            it_err "Unknown option: $1 (try --help)"; exit 2 ;;
        esac
    done

    if [ "$IT_MODE" = "ssh" ] && [ -z "$IT_SSH_DEST" ]; then
        it_err "Provide --host <user@host> or --local. See --help."
        exit 2
    fi
}

print_list() {
    echo "Scenarios:"
    local name rest
    while IFS=$'\t' read -r name rest; do
        printf '  %-32s %s\n' "$name" "$rest"
    done < <(scenario_matrix)
    echo ""
    echo "Axis coverage (every value below must appear at least once):"
    axis_coverage | sed 's/^/  /'
}

# --- Target I/O helpers (depend on globals set above) -----------------------
# Write a config.json onto the box from stdin-less arg.
push_config() {
    local json="$1"
    if [ "$IT_MODE" = "local" ]; then
        printf '%s\n' "$json" > "$IT_REMOTE_DIR/config.json"
    else
        printf '%s\n' "$json" | ssh "${IT_SSH_OPTS[@]}" "$IT_SSH_DEST" \
            "cd $(quote_arg "$IT_REMOTE_DIR") && cat > config.json"
    fi
}

# Read a single (non-secret) .env value off the box.
env_on_box() { rx "grep -E '^$1=' .env 2>/dev/null | head -n1 | cut -d= -f2-"; }

# Services currently running, one per line, sorted. Honours active compose profiles, so
# monerod is absent in remote mode.
running_services() { rx "docker compose ps --services --status running 2>/dev/null | sort"; }

# Print "<state> <health>" for one service, exactly as stack_status reads it: state is the
# container State.Status (running/exited/paused/restarting/…) and health is the healthcheck
# verdict (healthy/unhealthy/starting/none), or "missing none" when absent. The fault-injection
# predicates assert pithead's status verdicts against this.
service_state() {
    rx 'cid=$(docker compose ps -aq '"$1"' 2>/dev/null | head -n1); if [ -z "$cid" ]; then echo "missing none"; else docker inspect --format "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$cid" 2>/dev/null || echo "unknown none"; fi'
}

# A stable fingerprint of the secrets we must preserve across applies (proxy token + onion
# addresses). Hashed ON THE BOX so the plaintext never crosses the wire or hits a log.
secret_fingerprint() {
    rx "grep -E '^(PROXY_AUTH_TOKEN|[A-Z]+_ONION_ADDRESS)=' .env 2>/dev/null | sort | sha256sum | cut -d' ' -f1"
}

# --- Preflight --------------------------------------------------------------
preflight() {
    it_log "Connecting to target ($IT_MODE${IT_SSH_DEST:+ $IT_SSH_DEST}) at $IT_REMOTE_DIR …"
    if ! rx "true" >/dev/null 2>&1; then
        it_err "Cannot reach the target. Check --host/--local, --dir, and SSH access."
        exit 1
    fi

    # The stack dir must contain a deployed pithead.
    if ! rx "test -x $IT_PITHEAD" >/dev/null 2>&1; then
        it_err "pithead not found/executable at $IT_REMOTE_DIR/$IT_PITHEAD (set --dir/--pithead)."
        exit 1
    fi
    if ! rx "grep -q '^DEPLOYMENT_COMPLETED=true' .env" >/dev/null 2>&1; then
        it_err "Box is not fully deployed (.env missing DEPLOYMENT_COMPLETED). Run 'pithead setup' there first."
        exit 1
    fi

    # Tools the harness leans on, on the box.
    local tool
    for tool in jq curl docker sha256sum; do
        if ! rx "command -v $tool" >/dev/null 2>&1; then
            it_err "Required tool '$tool' missing on the box."
            exit 1
        fi
    done

    mkdir -p "$OUT_DIR"
    record_manifest

    # Snapshot the baseline so we can restore it and compare secrets later.
    BASELINE_CONFIG="$(rx 'cat config.json')"
    BASELINE_PRUNE="$(env_on_box MONERO_PRUNE)"   # 1 = pruned, 0 = full
    BASELINE_SECRET_FP="$(secret_fingerprint)"
    if [ -z "$BASELINE_CONFIG" ]; then
        it_err "Could not read baseline config.json from the box."
        exit 1
    fi
    it_log "Baseline captured (prune=$BASELINE_PRUNE). Original config will be restored at the end."
}

# Record exactly what's under test, so a run is reproducible (#54 manifest).
record_manifest() {
    local f="$OUT_DIR/manifest.txt"
    {
        echo "# Pithead integration run manifest"
        echo "stack_version: $(rx 'cat VERSION 2>/dev/null' | tr -d '\n')"
        echo "git_rev:       $(rx 'git rev-parse --short HEAD 2>/dev/null' | tr -d '\n')"
        echo "target_mode:   $IT_MODE"
        echo "remote_dir:    $IT_REMOTE_DIR"
        echo "expected_workers: $EXPECTED_WORKERS"
        echo ""
        echo "# docker compose images"
        rx "docker compose images 2>/dev/null"
    } | redact > "$f" 2>/dev/null || true
    it_step "wrote run manifest to $f"
}

# --- Scenario execution -----------------------------------------------------
# resolve_overrides (the prerequisite gate that decides whether a scenario can run on this box,
# and never mutates the canonical chain) lives in lib.sh so the self-test can exercise it. It
# reads BASELINE_PRUNE / PRUNED_DATA_DIR / FULL_DATA_DIR / REMOTE_MONERO_HOST and sets the
# globals RESOLVED / SKIP_REASON.

run_scenario() {
    local name="$1" overrides="$2"
    IT_CURRENT_SCENARIO="$name"
    echo ""
    it_log "── scenario: ${name} ───────────────────────────────"

    if ! resolve_overrides "$overrides"; then
        it_warn "SKIPPED ${name}: ${SKIP_REASON}"
        IT_SKIPPED=$((IT_SKIPPED + 1))
        return 0
    fi

    # Render + push config, then apply non-interactively.
    local config
    # shellcheck disable=SC2086  # RESOLVED is a space-separated list of override tokens, on purpose
    config="$(render_scenario_config "$BASELINE_CONFIG" $RESOLVED)"
    if ! printf '%s' "$config" | jq empty 2>/dev/null; then
        it_fail "rendered config is valid JSON" "jq rejected the rendered config"
        return 0
    fi
    push_config "$config"

    it_step "applying config (pithead apply -y)…"
    if ! pithead apply -y > "$OUT_DIR/${name}.apply.log" 2>&1; then
        it_fail "apply succeeded" "see $OUT_DIR/${name}.apply.log"
        capture_artifacts "$name" "$OUT_DIR"
        return 0
    fi

    # Wait for the stack to settle on real readiness signals before asserting.
    wait_status_ok 240    || true
    wait_monero_synced 120 || true
    wait_miner_running 180 || true
    # p2pool infers its sidechain from connected peers, so after a pool switch it reads "Unknown"
    # until peers on the new chain connect — wait for the dashboard to classify it (issue #54).
    local _pool; _pool="$(jq_get "$config" '.p2pool.pool')"; _pool="${_pool:-main}"
    wait_pool_ready 180 "$(pool_label "$_pool")" || true
    # End-to-end mining: p2pool's stratum hash counter resets on restart and climbs only once the
    # proxy's upstream reconnects and a share lands — wait for it before asserting hashes>0 (issue #54).
    wait_hashes_flowing 300 || true
    # When Tari is a required sync gate, give it the same treatment as Monero: after a restart it
    # must close its offline gap before the .sync.tari.state assertion, or we'd catch it mid-"loading".
    if [ "$(jq_get "$config" '.dashboard.tari_required')" = "true" ]; then
        wait_tari_synced 300 || true
    fi

    local fails_before="$IT_FAIL"
    assert_scenario "$name" "$config"
    # If this scenario turned anything red, grab artifacts for it.
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "$name" "$OUT_DIR"
    return 0
}

# The read-only assertion battery (infrastructure-level). Asserts the live running state of
# the stack for a given config WITHOUT changing anything — so it backs both a post-apply
# scenario check and the non-destructive `--check` mode. Calibrated against real hardware:
# it trusts monerod's own sync flag (the dashboard's UI state reads "loading" for a synced
# local node) and proxy_workers for mining liveness (stratum.conns can read 0 while mining).
assert_running_state() {
    local name="$1" config="$2"
    local st mode pool secure tari_req xvb rpc_lan
    mode="$(jq_get "$config" '.monero.mode')";          mode="${mode:-local}"
    pool="$(jq_get "$config" '.p2pool.pool')";          pool="${pool:-main}"
    secure="$(jq_get "$config" '.dashboard.secure')"
    tari_req="$(jq_get "$config" '.dashboard.tari_required')"
    xvb="$(jq_get "$config" '.xvb.enabled')"
    rpc_lan="$(jq_get "$config" '.monero.rpc_lan_access')"

    # 1. Expected containers up; unexpected ones absent.
    local running expected svc
    running="$(running_services)"
    expected="$(expected_services "$config")"
    while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        case "$running" in
            *"$svc"*) it_pass "container up: $svc" ;;
            *)        it_fail "container up: $svc" "not in running services" ;;
        esac
    done <<< "$expected"
    if [ "$mode" = "remote" ]; then
        case "$running" in
            *monerod*) it_fail "monerod absent in remote mode" "monerod is running" ;;
            *)         it_pass "monerod absent in remote mode" ;;
        esac
    fi

    # 2. pithead status is green for a healthy config.
    pithead status >/dev/null 2>&1; assert_rc "status exit code is 0 (healthy)" "$?" "0"

    # 3. Dashboard reachable and reading live state.
    st="$(api_state)"
    if [ -z "$st" ]; then
        it_fail "dashboard /api/state reachable" "empty response"
        return 0
    fi
    it_pass "dashboard /api/state reachable"

    # 4. Monero caught up — per monerod's own get_info, not the dashboard UI field.
    if monero_caught_up; then it_pass "monerod reports synced (RPC)"; else it_fail "monerod reports synced (RPC)" "get_info not synchronized"; fi
    # The dashboard's sync panel must also read "done" for a synced node — not stay stuck at
    # "loading". A synced monerod reports target_height 0, so the panel has to trust the caught-up
    # flag, not percent-vs-target; getting that wrong left a synced node "loading" forever (the real
    # bug found in the #180 gouda validation). Local only: we control + know the node is synced.
    if [ "$mode" = "local" ]; then
        assert_eq "monero sync panel reads done (dashboard)" "$(jq_get "$st" '.sync.monero.state')" "done"
    fi
    # Pruned/full panel (#32): determinate (Pruned|Full) for a local node; remote is often Unknown.
    local dmode; dmode="$(jq_get "$st" '.monero.mode')"
    if [ "$mode" = "remote" ]; then
        it_pass "monero display mode present ($dmode)"
    else
        case "$dmode" in Pruned|Full) it_pass "monero display mode determinate ($dmode)" ;;
                         *)            it_fail "monero display mode determinate" "got [$dmode], want Pruned|Full" ;; esac
    fi

    # 5. Sidechain selection matches the pool axis.
    assert_eq "pool type" "$(jq_get "$st" '.pool.type')" "$(pool_label "$pool")"

    # 6. End-to-end mining: workers online + hashes accumulating (#28). proxy_workers is the
    #    reliable liveness signal; stratum.conns is reported but informational (can be 0).
    local workers conns hashes
    workers="$(jq_get "$st" '.proxy_workers')"
    conns="$(jq_get "$st" '.stratum.conns')"
    hashes="$(jq_get "$st" '.stratum.total_hashes')"
    assert_num_ge "workers online (>= $EXPECTED_WORKERS)" "${workers:-0}" "$EXPECTED_WORKERS"
    assert_num_gt "stratum total hashes > 0" "${hashes:-0}" 0
    it_step "stratum conns=${conns:-?} (informational)"

    # 7. Tari sync-gate posture matches tari_required.
    assert_eq "TARI_REQUIRED env matches config" "$(env_on_box TARI_REQUIRED)" "${tari_req:-true}"
    if [ "$tari_req" = "true" ]; then
        assert_eq "tari synced (required)" "$(jq_get "$st" '.sync.tari.state')" "done"
    fi

    # 8. Security/posture axes propagated to .env.
    local want_bind; [ "$rpc_lan" = "true" ] && want_bind="0.0.0.0" || want_bind="127.0.0.1"
    assert_eq "MONERO_RPC_BIND matches rpc_lan_access" "$(env_on_box MONERO_RPC_BIND)" "$want_bind"
    assert_eq "DASHBOARD_SECURE matches config" "$(env_on_box DASHBOARD_SECURE)" "${secure:-true}"
    assert_eq "XVB_ENABLED matches config" "$(env_on_box XVB_ENABLED)" "${xvb:-true}"

    # 8b. Resource + privacy posture (LOCAL only). These regress silently and would otherwise only
    # be caught at tier 1 (compose/config), never live: a dropped mem_limit (#132) lets a leak
    # OOM-kill monerod instead of the offender; a reverted node-DNS setting (#161/#162) leaks
    # "this IP runs Monero/Tari" to the clearnet.
    if [ "$mode" = "local" ]; then
        local svc memlim
        for svc in monerod tari p2pool dashboard; do
            memlim="$(rx "docker inspect $svc --format '{{.HostConfig.Memory}}' 2>/dev/null")"
            assert_num_gt "memory ceiling live on $svc (#132)" "${memlim:-0}" 0
        done
        assert_num_ge "monerod DNS checkpoints disabled (#161)" \
            "$(rx "docker exec monerod grep -c '^disable-dns-checkpoints=1' /root/.bitmonero/bitmonero.conf 2>/dev/null")" 1
        assert_eq "monerod has no clearnet priority-node hostnames (#161)" \
            "$(rx "docker exec monerod grep -cE 'xmrvsbeast.com|hashvault.pro' /root/.bitmonero/bitmonero.conf 2>/dev/null")" "0"
        case "$(rx "docker inspect tari --format '{{.HostConfig.Dns}}' 2>/dev/null")" in
            *1.1.1.1*|*8.8.8.8*) it_fail "tari DNS sinkholed — no clearnet resolver (#162)" "clearnet nameserver present" ;;
            *127.0.0.1*)         it_pass "tari DNS sinkholed — no clearnet resolver (#162)" ;;
            *)                   it_fail "tari DNS sinkholed — no clearnet resolver (#162)" "unexpected HostConfig.Dns" ;;
        esac
        # The xmrig-proxy config knobs must reach the RUNNING proxy's argv, not just the compose
        # render. donate-level is rendered explicitly so it's always visible (#173). The matrix
        # deploys the default config (no p2pool.stratum_password) → stratum auth OFF, which must
        # render NO --access-password flag at all: a literal empty '--access-password=' would demand
        # an empty password and reject every rig (the bug verified + guarded for #152).
        local proxy_args; proxy_args="$(rx "docker inspect xmrig-proxy --format '{{json .Args}}' 2>/dev/null")"
        case "$proxy_args" in
            *'--donate-level='*) it_pass "xmrig-proxy dev-fee donate-level is explicit + live (#173)" ;;
            *)                   it_fail "xmrig-proxy dev-fee donate-level is explicit + live (#173)" "no --donate-level in proxy argv" ;;
        esac
        case "$proxy_args" in
            *'--access-password='*) it_fail "default-off stratum: no --access-password live (#152)" "found --access-password with no stratum_password set — would reject rigs" ;;
            *)                      it_pass "default-off stratum: no --access-password live (#152)" ;;
        esac
    fi

    # 9. Caddy scheme matches dashboard.secure.
    local scheme; [ "$secure" = "false" ] && scheme="http://" || scheme="https://"
    assert_contains "Caddyfile uses correct scheme" "$(rx 'head -n1 Caddyfile 2>/dev/null')" "$scheme"

    # 10. Secrets intact (proxy token + onions unchanged vs the baseline we captured).
    assert_eq "secrets intact (token + onions)" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"
}

# Full per-scenario battery: the read-only state assertions, plus the apply-only idempotency
# check (a second apply with no config change is a clean no-op).
assert_scenario() {
    local name="$1" config="$2"
    assert_running_state "$name" "$config"
    local again; again="$(pithead apply -y 2>&1)"
    assert_contains "re-apply is a no-op" "$again" "No configuration changes detected"
}

# Non-destructive --check: assert the box's CURRENT live state (its own config), no apply.
assert_current_state() {
    IT_CURRENT_SCENARIO="check"
    echo ""
    it_log "── read-only check against the live stack ──────────"
    local fails_before="$IT_FAIL"
    assert_running_state "check" "$BASELINE_CONFIG"
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "check" "$OUT_DIR"
}

# --- Release-server readiness (--readiness) ---------------------------------
# Read-only assessment of whether the box is fit to be a RELEASE / validation server: it must
# reuse already-synced chains, vary configs cheaply, and keep its keys/secrets and dashboard
# from leaking. Complements `pithead doctor` (stack health) — this checks the server's fitness
# for the integration harness's job. A WARN is "works, but not ideal"; a FAIL is "fix before
# using as a release gate".
box_fstype()   { rx "df --output=fstype $(quote_arg "$1") 2>/dev/null | tail -n1 | tr -d ' '"; }
box_avail_gb() { rx "df -BG --output=avail $(quote_arg "$1") 2>/dev/null | tail -n1 | tr -dc '0-9'"; }
box_mode()     { rx "stat -c %a $(quote_arg "$1") 2>/dev/null"; }

assert_release_readiness() {
    IT_CURRENT_SCENARIO="readiness"
    echo ""
    it_log "── release-server readiness ────────────────────────"

    # 1. The whole point of a release server: chains already synced, reused in minutes.
    if monero_caught_up; then it_pass "Monero is synced (chain reusable by the matrix)"; else it_fail "Monero is synced" "monerod not caught up — the matrix would have to re-sync"; fi
    pithead status >/dev/null 2>&1; assert_rc "stack is healthy (pithead status)" "$?" "0"

    # 2. The prune axis must vary the DB without re-syncing or mutating the canonical chain. The
    #    OTHER prune mode is unlocked either by (a) a snapshot/reflink-capable live FS (so a
    #    variant can be made cheaply) or (b) supplying a pre-built chain of the OPPOSITE mode
    #    (--full-data-dir when the box is pruned, --pruned-data-dir when it's full). A SAME-mode
    #    copy on a CoW volume is also useful: it lets destructive scenarios run off the live chain.
    #    gouda is a pruned box (MONERO_PRUNE=1) with a pruned copy on a btrfs CoW loopback, so it
    #    exercises pruned mode live with snapshot isolation; full mode is covered by the fakes.
    local mdir fstype="" cow_live=0 baseline_mode="full" bp
    mdir="$(env_on_box MONERO_DATA_DIR)"
    bp="${BASELINE_PRUNE:-$(env_on_box MONERO_PRUNE)}"   # so standalone --readiness sees it too
    [ -n "$mdir" ] && fstype="$(box_fstype "$mdir")"
    case "$fstype" in btrfs|zfs|xfs) cow_live=1 ;; esac
    [ "$bp" = "1" ] && baseline_mode="pruned"
    it_log "   live chain: ${mdir:-?} (${fstype:-unknown}, ${baseline_mode})"

    # Classify any supplied chains by prune mode relative to the live baseline.
    local opp_dir opp_label same_dir
    if [ "$bp" = "1" ]; then opp_dir="${FULL_DATA_DIR:-}"; opp_label="full"; same_dir="${PRUNED_DATA_DIR:-}"
    else opp_dir="${PRUNED_DATA_DIR:-}"; opp_label="pruned"; same_dir="${FULL_DATA_DIR:-}"; fi

    # A same-mode copy (e.g. the CoW pruned chain) — snapshot isolation for destructive scenarios.
    if [ -n "$same_dir" ]; then
        local sfs; sfs="$(box_fstype "$same_dir")"
        if rx "test -e $(quote_arg "$same_dir")/lmdb/data.mdb" >/dev/null 2>&1; then
            case "$sfs" in
                btrfs|zfs|xfs) it_pass "snapshot-isolated $baseline_mode chain on a CoW FS ($same_dir, $sfs) — destructive scenarios needn't touch the live chain" ;;
                *)             it_log "   same-mode copy at $same_dir ($sfs — not CoW)" ;;
            esac
        else
            it_warn "supplied same-mode dir has no lmdb/data.mdb ($same_dir)"
        fi
    fi

    # The opposite-mode chain is what unlocks the OTHER value of the prune axis.
    if [ -n "$opp_dir" ]; then
        if rx "test -e $(quote_arg "$opp_dir")/lmdb/data.mdb" >/dev/null 2>&1; then
            it_pass "both prune modes exercisable (live=$baseline_mode + supplied $opp_label chain at $opp_dir)"
        else
            it_fail "supplied $opp_label chain present" "$opp_dir has no lmdb/data.mdb"
        fi
    elif [ "$cow_live" -eq 1 ]; then
        it_pass "prune axis: live FS is snapshot-capable ($fstype) — the $opp_label variant can be built cheaply"
    else
        it_warn "prune axis: only $baseline_mode is testable live — no $opp_label chain supplied, so $opp_label scenarios skip (cover that mode via the fake mini-stack, or build one)"
    fi

    # 3. Disk headroom on the live chain FS (room to operate + hold a co-located second chain).
    if [ -n "$mdir" ]; then
        local avail; avail="$(box_avail_gb "$mdir")"
        if [ -n "$avail" ] && [ "$avail" -ge 100 ] 2>/dev/null; then
            it_pass "disk headroom on the live chain FS (${avail} GiB free)"
        else
            it_warn "low disk headroom on the live chain FS (${avail:-?} GiB free) — snapshots / a full+pruned matrix may not fit"
        fi
    fi

    # 4. Secrets must not be world/group readable (the box holds wallet/RPC creds + onion keys).
    local envmode; envmode="$(box_mode .env)"
    case "$envmode" in
        ""|*[!0-9]*) it_warn ".env permissions unknown" ;;
        ?00)         it_pass ".env is owner-only (mode $envmode)" ;;
        *)           it_fail ".env is owner-only" "mode is $envmode — group/other can read RPC creds & onions; run: chmod 600 .env" ;;
    esac

    # 5. The dashboard must sit behind Caddy on localhost, never bound to a public interface.
    local d_addrs exposed=0 st _q1 _q2 laddr
    d_addrs="$(rx "ss -tlnH 'sport = :8000' 2>/dev/null")"
    if [ -z "$d_addrs" ]; then
        it_warn "nothing listening on :8000 (dashboard) — can't assess exposure"
    else
        while read -r st _q1 _q2 laddr _; do
            [ -n "$laddr" ] || continue
            case "$laddr" in 127.0.0.1:*|"[::1]:"*) : ;; *) exposed=1 ;; esac
        done <<< "$d_addrs"
        if [ "$exposed" -eq 0 ]; then it_pass "dashboard bound to localhost only (Caddy fronts it)"; else it_fail "dashboard bound to localhost only" "it is listening on a non-loopback address — do not expose the dashboard directly"; fi
    fi

    # 6. The backup/rollback safety net must be usable (writable backups dir + tar).
    if rx "mkdir -p backups && touch backups/.itest-rw 2>/dev/null && rm -f backups/.itest-rw && command -v tar" >/dev/null 2>&1; then
        it_pass "backup/rollback prerequisites present (writable backups/, tar)"
    else
        it_fail "backup prerequisites present" "backups/ not writable or tar missing — --safety-backup won't work"
    fi
}

# --- Lifecycle + edge phase (--lifecycle) -----------------------------------
run_lifecycle() {
    IT_CURRENT_SCENARIO="lifecycle"
    echo ""
    it_log "── lifecycle + failover phase ──────────────────────"

    # restart brings the stack back healthy.
    it_step "pithead restart…"
    pithead restart >/dev/null 2>&1
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1; assert_rc "status OK after restart" "$?" "0"

    # apply that changes the sidechain recreates only the affected containers, preserving
    # secrets. We flip main<->mini and assert the token/onions are untouched, then revert.
    local cur_pool fp_before
    cur_pool="$(jq_get "$BASELINE_CONFIG" '.p2pool.pool')"; cur_pool="${cur_pool:-main}"
    local other; [ "$cur_pool" = "mini" ] && other="main" || other="mini"
    fp_before="$(secret_fingerprint)"
    push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")"
    it_step "apply pool $cur_pool -> $other…"
    pithead apply -y >/dev/null 2>&1
    wait_status_ok 180 || true
    assert_eq "secrets preserved across pool change" "$(secret_fingerprint)" "$fp_before"
    # .pool.type lags a sidechain switch until peers on the new chain connect — wait, don't assert cold (#54).
    wait_pool_ready 180 "$(pool_label "$other")" || true
    assert_eq "pool actually changed" "$(jq_get "$(api_state)" '.pool.type')" "$(pool_label "$other")"

    # Node-down failover (#31): stop monerod -> status non-zero (node down), dashboard rejects
    # workers (xmrig-proxy stopped) -> start monerod -> readmitted -> status 0 again.
    if [ "$(env_on_box COMPOSE_PROFILES)" = "local_node" ]; then
        it_step "stopping monerod to exercise node-down failover…"
        rx "docker compose stop monerod" >/dev/null 2>&1
        wait_for 120 5 "status to report node down" _pred_status_down || true
        pithead status >/dev/null 2>&1; assert_rc "status non-zero when node down" "$?" "1"
        it_step "starting monerod and waiting for readmit…"
        rx "docker compose start monerod" >/dev/null 2>&1
        wait_status_ok 240 || true
        pithead status >/dev/null 2>&1; assert_rc "status OK after node recovery" "$?" "0"
    else
        it_warn "skipping node-down failover (remote mode: no local monerod to stop)"
    fi

    # backup → restore round-trip (#102): a backup archives config/.env/onions/dashboard; a
    # restore brings them back. We change the pool, restore, and assert the pool reverted and
    # secrets survived — exercising both CLI verbs end-to-end (not just the rollback net).
    it_step "backup → restore round-trip…"
    if pithead backup -y >/dev/null 2>&1; then
        local arch; arch="$(rx 'ls -t backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1')"
        if [ -n "$arch" ]; then
            local fp_b; fp_b="$(secret_fingerprint)"
            local backed_pool; backed_pool="$(jq_get "$(api_state)" '.pool.type')"
            # Diverge from the backed-up state, then restore it back.
            push_config "$(render_scenario_config "$BASELINE_CONFIG" "p2pool.pool=$other")"
            pithead apply -y >/dev/null 2>&1
            pithead down >/dev/null 2>&1
            pithead restore -y "$arch" >/dev/null 2>&1
            pithead up >/dev/null 2>&1
            wait_status_ok 240 || true
            # pool.type lags peer reconnect after restore+up — wait for classification before asserting (#54).
            wait_pool_ready 180 "$backed_pool" || true
            assert_eq "restore reverts the pool to the backed-up value" "$(jq_get "$(api_state)" '.pool.type')" "$backed_pool"
            assert_eq "restore preserves secrets" "$(secret_fingerprint)" "$fp_b"
            rx "rm -f $(quote_arg "$arch")" >/dev/null 2>&1 || true
        else
            it_fail "backup produced an archive" "no backups/pithead-backup-*.tar.gz"
        fi
    else
        it_fail "pithead backup succeeded" "backup returned non-zero"
    fi
}

# Predicate: status reports a problem (non-zero) — used to detect node-down deterministically.
_pred_status_down() { ! pithead status >/dev/null 2>&1; }

# --- Fault-injection phase (--fault-injection) ------------------------------
# Deliberately break monerod three ways and assert pithead's status verdicts plus the
# dashboard's failover, then restore. Local mode only (needs a local monerod to break).
# These are destructive-then-restored and slow (healthcheck + node-health debounce), so the
# phase is opt-in.
_monerod_is() {  # _monerod_is <state> [<health>]
    local s; s="$(service_state monerod)"
    [ "$(svc_state_of "$s")" = "$1" ] && { [ -z "${2:-}" ] || [ "$(svc_health_of "$s")" = "$2" ]; }
}
_pred_monerod_missing()   { _monerod_is missing; }
_pred_monerod_unhealthy() { _monerod_is running unhealthy; }
_pred_monerod_healthy()   { _monerod_is running healthy; }
_pred_proxy_stopped()     { [ "$(svc_state_of "$(service_state xmrig-proxy)")" != "running" ]; }

fault_node_down() {
    it_step "fault: stop monerod (required node down)…"
    rx "docker compose stop monerod" >/dev/null 2>&1
    wait_for 60 5 "status to report a problem" _pred_status_down || true
    pithead status >/dev/null 2>&1; assert_rc "status non-zero when monerod is down" "$?" "1"
    # The dashboard rejects workers (stops xmrig-proxy) after its node-health debounce so they
    # fail over to backup pools (#31).
    wait_for 180 10 "xmrig-proxy stopped by failover" _pred_proxy_stopped || true
    assert_eq "xmrig-proxy stopped for failover" "$(svc_state_of "$(service_state xmrig-proxy)")" "exited"
    it_step "recover: start monerod…"
    rx "docker compose start monerod" >/dev/null 2>&1
    wait_for 240 5 "monerod healthy" _pred_monerod_healthy || true
    wait_status_ok 240 || true
    pithead status >/dev/null 2>&1; assert_rc "status OK after monerod recovery" "$?" "0"
}

fault_unhealthy() {
    it_step "fault: freeze monerod (SIGSTOP) so its healthcheck fails…"
    rx "docker compose kill -s SIGSTOP monerod" >/dev/null 2>&1
    # The get_info healthcheck now times out; after its retries the container flips to
    # running-but-unhealthy — the verdict stack_status flags as a problem.
    wait_for 200 10 "monerod to report unhealthy" _pred_monerod_unhealthy || true
    assert_eq "monerod running-but-unhealthy" "$(service_state monerod)" "running unhealthy"
    pithead status >/dev/null 2>&1; assert_rc "status non-zero when monerod unhealthy" "$?" "1"
    it_step "recover: thaw monerod (SIGCONT)…"
    rx "docker compose kill -s SIGCONT monerod" >/dev/null 2>&1
    wait_for 120 5 "monerod healthy" _pred_monerod_healthy || true
}

fault_missing() {
    it_step "fault: remove the monerod container…"
    rx "docker compose rm -sf monerod" >/dev/null 2>&1
    wait_for 30 3 "monerod to be missing" _pred_monerod_missing || true
    assert_eq "monerod reported missing" "$(svc_state_of "$(service_state monerod)")" "missing"
    pithead status >/dev/null 2>&1; assert_rc "status non-zero when monerod missing" "$?" "1"
    it_step "recover: recreate monerod…"
    rx "docker compose up -d monerod" >/dev/null 2>&1
    wait_for 240 5 "monerod healthy" _pred_monerod_healthy || true
}

run_fault_injection() {
    # shellcheck disable=SC2034  # read by lib.sh:it_fail to label captured failures
    IT_CURRENT_SCENARIO="fault-injection"
    echo ""
    it_log "── fault-injection phase ───────────────────────────"
    if [ "$(env_on_box COMPOSE_PROFILES)" != "local_node" ]; then
        it_warn "skipping fault injection (remote mode: no local monerod to break)"
        return 0
    fi

    local fails_before="$IT_FAIL"
    fault_node_down
    fault_unhealthy
    fault_missing
    [ "$IT_FAIL" -gt "$fails_before" ] && capture_artifacts "fault-injection" "$OUT_DIR"

    # Belt-and-braces: whatever happened above, leave monerod up and the stack healthy.
    rx "docker compose up -d monerod" >/dev/null 2>&1 || true
    wait_for 240 5 "monerod healthy after fault phase" _pred_monerod_healthy || true
    wait_status_ok 240 || true
}

# --- Safety backup / rollback (--safety-backup) -----------------------------
# Take a real `pithead backup` before the destructive scenarios so a failed run can be rolled
# all the way back (config, .env, Caddyfile, Tor onion keys, dashboard DB). This both protects
# a precious box AND exercises backup/restore end-to-end (#102) — closing that CLI-breadth gap.
safety_backup() {
    [ "$SAFETY_BACKUP" = "1" ] || return 0
    it_log "Taking a safety backup before destructive scenarios (pithead backup -y)…"
    if ! pithead backup -y > "$OUT_DIR/backup.log" 2>&1; then
        it_fail "safety backup created" "see $OUT_DIR/backup.log"
        return 0
    fi
    SAFETY_ARCHIVE="$(rx 'ls -t backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1')"
    if [ -z "$SAFETY_ARCHIVE" ]; then
        it_fail "safety backup archive located" "no backups/pithead-backup-*.tar.gz on the box"
        return 0
    fi
    it_log "Safety backup: $SAFETY_ARCHIVE"
    # Exercise backup as an assertion: the archive must list the core files we'd roll back to.
    local listing; listing="$(rx "tar -tzf $(quote_arg "$SAFETY_ARCHIVE") 2>/dev/null")"
    assert_contains "backup archive contains config.json" "$listing" "config.json"
    assert_contains "backup archive contains .env"        "$listing" ".env"
}

# On a failed run, roll the box back to the pre-test safety backup.
safety_rollback_if_failed() {
    [ "$SAFETY_BACKUP" = "1" ] && [ -n "$SAFETY_ARCHIVE" ] || return 0
    [ "$IT_FAIL" -gt 0 ] || return 0
    it_warn "failures detected — rolling back to the safety backup ($SAFETY_ARCHIVE)…"
    pithead down >/dev/null 2>&1 || true
    if pithead restore -y "$SAFETY_ARCHIVE" >/dev/null 2>&1; then
        pithead up >/dev/null 2>&1 || true
        wait_status_ok 240 || true
        it_log "rollback complete — config/.env/onions/dashboard restored from the pre-test backup."
    else
        it_err "restore FAILED — the box may be in a partial state; archive kept at $SAFETY_ARCHIVE"
        return 0
    fi
}

# Remove the generated safety archive once we're done (kept on --keep, or if restore failed).
safety_cleanup() {
    [ -n "$SAFETY_ARCHIVE" ] || return 0
    if [ "$KEEP_STATE" = "1" ]; then
        it_warn "--keep: leaving the safety backup at $SAFETY_ARCHIVE"
        return 0
    fi
    rx "rm -f $(quote_arg "$SAFETY_ARCHIVE")" >/dev/null 2>&1 || true
    it_step "removed the safety backup archive"
}

# --- Restore + summary ------------------------------------------------------
restore_baseline() {
    [ "$KEEP_STATE" = "1" ] && { it_warn "--keep set: leaving the box on the last scenario."; return; }
    [ -z "$BASELINE_CONFIG" ] && return
    it_log "Restoring original config.json and re-applying…"
    push_config "$BASELINE_CONFIG"
    pithead apply -y >/dev/null 2>&1 || it_warn "restore apply reported a non-zero exit; check the box."
    wait_status_ok 240 || true
    assert_eq "secrets intact after restore" "$(secret_fingerprint)" "$BASELINE_SECRET_FP"
}

summary() {
    echo ""
    it_log "════════════════ summary ════════════════"
    it_log "passed:  $IT_PASS"
    it_log "skipped: $IT_SKIPPED"
    if [ "$IT_FAIL" -gt 0 ]; then
        it_err "failed:  $IT_FAIL"
        echo -e "$IT_FAILED_NAMES" >&2
        it_err "Artifacts for failed scenarios are under $OUT_DIR/"
        return 1
    fi
    it_log "failed:  0"
    it_log "All assertions passed. Artifacts/manifest under $OUT_DIR/"
    return 0
}

# --- Main -------------------------------------------------------------------
IT_SKIPPED=0

main() {
    parse_args "$@"
    preflight

    # Non-destructive release-server fitness assessment.
    if [ "$READINESS" = "1" ]; then
        assert_release_readiness
        summary
        return
    fi

    # Non-destructive health check: assert the current live state and stop.
    if [ "$CHECK_ONLY" = "1" ]; then
        assert_current_state
        summary
        return
    fi

    # Optional rollback net for the destructive phases that follow.
    safety_backup

    local name rest
    if [ -n "$ONLY_SCENARIO" ]; then
        rest="$(scenario_overrides "$ONLY_SCENARIO")" || { it_err "Unknown scenario: $ONLY_SCENARIO"; exit 2; }
        run_scenario "$ONLY_SCENARIO" "$rest"
    else
        while IFS=$'\t' read -r name rest; do
            [ -z "$name" ] && continue
            # </dev/null: never let a child (ssh inside run_scenario) drain the loop's stdin and
            # silently skip the remaining scenarios. rx already uses `ssh -n`; this is belt-and-suspenders.
            run_scenario "$name" "$rest" </dev/null
        done < <(scenario_matrix)
    fi

    [ "$RUN_LIFECYCLE" = "1" ] && run_lifecycle
    [ "$RUN_FAULTS" = "1" ] && run_fault_injection

    # Failure → roll the box back to the safety backup; success → leave it (restore_baseline
    # just puts config.json back to where we found it). Then drop the generated archive.
    safety_rollback_if_failed
    restore_baseline
    safety_cleanup
    summary
}

main "$@"
