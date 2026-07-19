#!/usr/bin/env bash
#
# e2e.sh — one-command Tier-4 end-to-end run of a branch against a live test bench.
#
#   tests/integration/e2e.sh <branch> [options]
#   tests/integration/e2e.sh claude/my-feature --mode matrix
#
# What it does, end to end, then puts everything back the way it found it:
#   1. Provisions a DEDICATED checkout on the test bench (/srv/code/pithead-e2e) — the canonical
#      /srv/code/pithead is the baseline and is never git-touched.
#   2. Fetches + checks out <branch> there, and seeds it with the canonical config.json/.env so
#      it has the same wallet / secrets / onion keys / shared chains (just the branch's code).
#   3. Takes a `pithead backup` of the live stack (the rollback anchor).
#   4. Borrows a miner (set MINER_HOST): backs up its xmrig config and repoints it at the test bench so
#      the live matrix has a real worker mining through this stack.
#   5. Deploys the branch (`pithead upgrade` — re-renders configs AND rebuilds the branch's first-party
#      images from build/, so a Dockerfile/entrypoint change is actually tested #272) and runs the live
#      harness (tests/integration/run.sh) DETACHED on the box so an SSH drop can't kill a long matrix.
#   6. ALWAYS restores: the miner's original pool config, and the canonical baseline stack — even
#      on failure or Ctrl-C (an EXIT trap). The synced chains are never touched.
#
# The Compose project name is pinned to "pithead", so the e2e checkout and the canonical checkout
# drive the SAME containers + the SAME shared chains — they are two code copies of one stack, run
# one at a time, not two stacks. That's why borrow→test→restore is a code/image swap, not a re-sync.
#
# Requires: SSH access to the test bench and the miner (keys, LAN reachable), and `jq` on both.
# See tests/integration/testbench-README.md and docs/dev/integration-testing.md.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# For rig_lock/rig_lock_remote (#430): the shared-bench flock protocol from rigforge#183.
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

# --- Config (override via env or flags) -------------------------------------
BENCH_HOST="${BENCH_HOST:-}"
MINER_HOST="${MINER_HOST:-}"
CANONICAL_DIR="${CANONICAL_DIR:-/srv/code/pithead}"
E2E_DIR="${E2E_DIR:-/srv/code/pithead-e2e}"
MINER_XMRIG_CONFIG="${MINER_XMRIG_CONFIG:-/opt/rigforge/data/worker/xmrig/build/config.json}"
GIT_REMOTE_URL="${GIT_REMOTE_URL:-https://github.com/p2pool-starter-stack/pithead.git}"
MODE="targeted" # targeted (default, lean) | check | matrix (full sweep, opt-in)
WORKERS=1
BORROW_MINER=1
KEEP=0
BRANCH=""

# --- Output -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'
    C_BLUE='\033[1;34m'
    C_DIM='\033[2m'
else
    C_RESET=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_BLUE=''
    C_DIM=''
fi
log() { printf '%b==>%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%b ✓%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b !%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
step() { printf '%b  → %s%b\n' "$C_DIM" "$*" "$C_RESET"; }
die() {
    printf '%b ✗%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Run a branch end-to-end against a live test bench, then restore everything.

USAGE:
  tests/integration/e2e.sh <branch> [options]

OPTIONS:
  --mode <m>        targeted | check | matrix   (default: targeted)
                      targeted — LEAN (default): validate the dashboard + the sync logic against
                                 the EXISTING synced node — no full config sweep, no node re-sync.
                                 = check + lifecycle (one controlled restart exercises the sync
                                 gate / node-down failover) + --auth-fail-closed.
                      check    — non-destructive: readiness + current live state only (pure reads).
                      matrix   — the full destructive config matrix + lifecycle + fault-injection
                                 + auth-fail-closed, with --safety-backup auto-rollback. Opt-in —
                                 a full pre-release sweep; recreates containers across many configs.
  --workers <n>     workers expected mining through the stack (default: 1 — the borrowed miner)
  --bench <host>    SSH host of the test bench to deploy onto (or set BENCH_HOST)
  --miner <host>    SSH host of the miner to borrow (or set MINER_HOST)
  --no-miner        don't borrow a miner (mining assertions will be skipped/limited)
  --keep            don't restore at the end (leave the branch deployed + miner repointed — debugging)
  -h, --help        this help

ENV OVERRIDES: BENCH_HOST, MINER_HOST, CANONICAL_DIR, E2E_DIR, MINER_XMRIG_CONFIG, GIT_REMOTE_URL

EXAMPLES:
  tests/integration/e2e.sh claude/my-feature                 # full matrix, borrow the configured miner
  tests/integration/e2e.sh claude/my-feature --mode check    # safe, non-destructive first run
  tests/integration/e2e.sh main --mode targeted --keep       # quick, leave it deployed to inspect
EOF
}

# --- Arg parsing ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
    --mode)
        MODE="$2"
        shift 2
        ;;
    --workers)
        WORKERS="$2"
        shift 2
        ;;
    --bench)
        BENCH_HOST="$2"
        shift 2
        ;;
    --miner)
        MINER_HOST="$2"
        shift 2
        ;;
    --no-miner)
        BORROW_MINER=0
        shift
        ;;
    --keep)
        KEEP=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)
        [ -z "$BRANCH" ] && BRANCH="$1" || die "Unexpected arg: $1"
        shift
        ;;
    esac
done
[ -n "$BRANCH" ] || {
    usage
    die "A <branch> is required."
}
case "$MODE" in check | targeted | matrix) ;; *) die "--mode must be check|targeted|matrix (got '$MODE')." ;; esac

# --- SSH helpers ------------------------------------------------------------
# Keepalives so a quiet (but live) connection isn't dropped; BatchMode so we never hang on a prompt.
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=8 -o StrictHostKeyChecking=accept-new)
# NOTE (testbench README): avoid literal shell parens '()' in remote command strings — they break the
# non-interactive remote shell. jq filters (quoted) are fine; shell subshells are not.
on_bench() { ssh "${SSH_OPTS[@]}" "$BENCH_HOST" "$1"; }
on_miner() { ssh "${SSH_OPTS[@]}" "$MINER_HOST" "$1"; }

# State captured for the restore trap.
SAFETY_ARCHIVE=""
MINER_CFG_BACKUP=""
RESTORED=0
# Where the LIVE stack actually runs from — resolved in preflight (#454). Defaults to CANONICAL_DIR
# so the EXIT trap always has a target even if it fires before preflight refines it.
RESTORE_DIR="$CANONICAL_DIR"

# --- Restore (runs on EXIT, even on failure / Ctrl-C) -----------------------
restore_all() {
    local rc=$?
    [ "$RESTORED" = "1" ] && return
    RESTORED=1
    if [ "$KEEP" = "1" ]; then
        warn "--keep set: leaving the branch deployed on $BENCH_HOST and the miner repointed."
        warn "  Re-run without --keep, or restore by hand: canonical=$CANONICAL_DIR, miner cfg backup=$MINER_CFG_BACKUP"
        return
    fi
    echo ""
    log "Restoring everything to the pre-run state…"

    # 1. Miner: put its original pool config back and nudge xmrig to reconnect.
    if [ -n "$MINER_CFG_BACKUP" ]; then
        step "restoring $MINER_HOST xmrig config from $MINER_CFG_BACKUP"
        if on_miner "cp -a '$MINER_CFG_BACKUP' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG'"; then
            miner_reload && ok "$MINER_HOST repointed to its original pool(s)" || warn "$MINER_HOST config restored; verify xmrig reconnected"
        else
            warn "FAILED to restore $MINER_HOST config — backup kept at $MINER_CFG_BACKUP"
        fi
    fi

    # 2. Stack: stop the branch (e2e checkout) and bring the LIVE baseline back up healthy. Restore
    #    from RESTORE_DIR — the dir the live stack actually ran from (#454), which on a release box is a
    #    per-version bundle dir, not CANONICAL_DIR. Restoring from the wrong dir hands the "pithead"
    #    project locally-built :dev images.
    step "bringing the baseline stack ($RESTORE_DIR) back up"
    on_bench "cd '$E2E_DIR' && ./pithead down >/dev/null 2>&1 || true"
    if on_bench "cd '$RESTORE_DIR' && ./pithead apply -y >/dev/null 2>&1 && ./pithead up >/dev/null 2>&1"; then
        wait_bench_healthy 300 && ok "baseline stack healthy again" || warn "baseline stack came up but isn't reporting healthy yet — check 'pithead status' on $BENCH_HOST"
    else
        warn "baseline 'pithead apply/up' returned non-zero in $RESTORE_DIR — check $BENCH_HOST by hand."
        warn "  Safety backup to roll back to: $SAFETY_ARCHIVE"
    fi

    # 3. Chains sanity: they must be untouched (the whole point).
    local sync
    sync="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '\"\(.sync.monero.state)/\(.sync.tari.state)\"' 2>/dev/null" || true)"
    [ -n "$sync" ] && step "post-restore sync state (monero/tari): $sync"

    if [ "$rc" -eq 0 ]; then ok "restore complete."; else warn "restore complete (the run itself failed — see above)."; fi
}
trap restore_all EXIT INT TERM

# --- Small waiters / helpers ------------------------------------------------
wait_bench_healthy() { # <timeout_s>
    local deadline=$(($(date +%s) + ${1:-300}))
    while :; do
        on_bench "cd '$RESTORE_DIR' && ./pithead status >/dev/null 2>&1" && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 10
    done
}

# After a deploy recreates monerod/tari, they reload the EXISTING synced chain and re-confirm their
# tip (seconds — NOT a re-sync). Wait for the dashboard to report both back to "done" before running
# the harness, so the readiness pre-check doesn't flap on the brief post-restart "loading". Doubles as
# a direct check that the sync-detection logic settles correctly against the reused chains.
wait_synced() { # <timeout_s>
    local deadline=$(($(date +%s) + ${1:-300})) st
    while :; do
        st="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '\"\(.sync.monero.state)/\(.sync.tari.state)\"' 2>/dev/null" || true)"
        [ "$st" = "done/done" ] && {
            ok "monero + tari re-confirmed synced ($st) — existing chains reused, no re-sync"
            return 0
        }
        [ "$(date +%s)" -ge "$deadline" ] && {
            warn "sync panels still '$st' after $((${1:-300}))s — the harness will wait further on real sync signals"
            return 1
        }
        sleep 8
    done
}

# Nudge the miner's xmrig to reload its (rewritten) config. xmrig watches its config file and
# reloads on change; the systemctl/SIGHUP fallbacks cover builds that don't. Whichever works, we
# verify by polling the test bench for the worker — so the exact mechanism doesn't matter.
miner_reload() {
    on_miner "sudo -n systemctl restart xmrig >/dev/null 2>&1 || systemctl --user restart xmrig >/dev/null 2>&1 || pkill -HUP -x xmrig >/dev/null 2>&1 || true"
    return 0
}

# Poll the test bench's dashboard for at least <n> workers connected.
wait_workers() { # <n> <timeout_s>
    local want="$1" deadline=$(($(date +%s) + ${2:-180})) got
    while :; do
        got="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.proxy_workers // 0' 2>/dev/null" || echo 0)"
        [ -n "$got" ] && [ "$got" -ge "$want" ] 2>/dev/null && {
            ok "$got worker(s) mining through the test bench"
            return 0
        }
        [ "$(date +%s)" -ge "$deadline" ] && {
            warn "only $got worker(s) connected after $((${2:-180}))s (wanted $want)"
            return 1
        }
        sleep 8
    done
}

# --- Phase 0: preflight -----------------------------------------------------
preflight() {
    log "Preflight"
    [ -n "$BENCH_HOST" ] || die "Set BENCH_HOST to your test-bench SSH host (env BENCH_HOST or --bench)."
    [ "$BORROW_MINER" != "1" ] || [ -n "$MINER_HOST" ] || die "Set MINER_HOST to a miner to borrow, or pass --no-miner."
    on_bench 'echo ok >/dev/null' || die "Cannot SSH to test-bench host '$BENCH_HOST'."
    ok "SSH to $BENCH_HOST"
    on_bench "test -x '$CANONICAL_DIR/pithead'" || die "No pithead at $CANONICAL_DIR on $BENCH_HOST."
    on_bench "cd '$CANONICAL_DIR' && ./pithead status >/dev/null 2>&1" &&
        ok "canonical stack is currently healthy" ||
        warn "canonical stack is NOT healthy right now — continuing, but check the box."
    # Resolve where the LIVE stack actually runs from (#454). The "pithead" Compose project name is
    # fixed, so exactly one project runs on the box; read its working_dir off a running container's
    # label. On a release box that's a per-version bundle dir (e.g. /srv/code/pithead-v1.3.1), NOT
    # CANONICAL_DIR — the restore must target it or it hands the project locally-built :dev images.
    # Captured NOW, before deploy_branch rewrites the label to E2E_DIR.
    local live_cid live_dir=""
    live_cid="$(on_bench "docker ps -q --filter label=com.docker.compose.project=pithead 2>/dev/null | head -n1" || true)"
    [ -n "$live_cid" ] && live_dir="$(on_bench "docker inspect --format '{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}' '$live_cid' 2>/dev/null" || true)"
    if [ -n "$live_dir" ] && [ "$live_dir" != "$E2E_DIR" ] && on_bench "test -x '$live_dir/pithead'"; then
        RESTORE_DIR="$live_dir"
        [ "$RESTORE_DIR" = "$CANONICAL_DIR" ] &&
            ok "live stack runs from $RESTORE_DIR" ||
            warn "live stack runs from $RESTORE_DIR (not CANONICAL_DIR=$CANONICAL_DIR) — restore will target it (#454)."
    else
        warn "couldn't resolve the live stack's working dir — restore will use CANONICAL_DIR=$CANONICAL_DIR."
    fi
    if [ "$BORROW_MINER" = "1" ]; then
        on_miner 'echo ok >/dev/null' || die "Cannot SSH to miner '$MINER_HOST' (use --no-miner to skip)."
        on_miner "test -f '$MINER_XMRIG_CONFIG'" || die "No xmrig config at $MINER_XMRIG_CONFIG on $MINER_HOST."
        ok "SSH to $MINER_HOST + xmrig config found"
        # Loaner-rig lock (#430/rigforge#183): the borrow repoints (and may restart) the rig's
        # xmrig, so claim the rig's EXCLUSIVE flock now — before anything is mutated — and hold it
        # until this process dies. rigforge's gates on the same rig refuse (exit 75, holder named)
        # instead of colliding mid-borrow, and a busy rig fails us fast, before the bench is
        # touched. The kernel releases the lock on exit, AFTER the EXIT-trap restore has run.
        rig_lock_remote pithead "e2e.sh loaner-borrow" "" "$MINER_HOST" "${SSH_OPTS[@]}"
        ok "rig lock held on $MINER_HOST (loaner) for the life of this run"
    fi
}

# --- Phase 1: provision the dedicated e2e checkout + check out the branch ---
provision() {
    log "Provisioning the dedicated e2e checkout ($E2E_DIR) on $BENCH_HOST"
    # Clone from the local canonical checkout (fast, no network) the first time, then point origin
    # at GitHub so we can fetch arbitrary branches.
    on_bench "
        set -e
        if [ ! -d '$E2E_DIR/.git' ]; then
            git clone --quiet '$CANONICAL_DIR' '$E2E_DIR'
            git -C '$E2E_DIR' remote set-url origin '$GIT_REMOTE_URL'
        fi
        git -C '$E2E_DIR' remote set-url origin '$GIT_REMOTE_URL'
        git -C '$E2E_DIR' fetch --quiet origin '$BRANCH'
        # The e2e checkout is DEDICATED and disposable, so force a pristine tree instead of assuming
        # one (#454): drop stray untracked files (e.g. a leftover bench script) that would otherwise
        # abort 'checkout' with \"would be overwritten\". -x clears ignored build cruft too; the
        # -e excludes keep data/backups and the harness's own results/, so the shared chains and
        # rollback anchors are never touched. config.json/.env ARE wiped (gitignored, no -e) but the
        # next step re-seeds them from CANONICAL_DIR — don't drop that seed thinking clean spares them.
        git -C '$E2E_DIR' checkout -q -f -B '$BRANCH' FETCH_HEAD
        git -C '$E2E_DIR' reset -q --hard FETCH_HEAD
        git -C '$E2E_DIR' clean -qfdx -e /results -e /backups -e /data
    " || die "Failed to provision/checkout '$BRANCH' in $E2E_DIR."
    local head
    head="$(on_bench "git -C '$E2E_DIR' rev-parse --short HEAD")"
    ok "e2e checkout on $BRANCH @ $head"

    step "seeding the e2e checkout with the canonical config.json/.env (same wallet/secrets/chains)"
    on_bench "cp -a '$CANONICAL_DIR/config.json' '$E2E_DIR/config.json' && cp -a '$CANONICAL_DIR/.env' '$E2E_DIR/.env'" ||
        die "Failed to seed config.json/.env into $E2E_DIR."
    ok "config seeded (data dirs point at the shared chains)"
}

# --- Phase 2: safety backup of the live stack -------------------------------
backup_stack() {
    log "Taking a safety backup of the live stack (the rollback anchor)"
    # ponytail: --no-encrypt because v1.4 refuses to write a plaintext archive unattended without
    # PITHEAD_BACKUP_PASSPHRASE; this rollback anchor never leaves the bench, so plaintext is fine here.
    on_bench "cd '$CANONICAL_DIR' && ./pithead backup -y --no-encrypt >/dev/null 2>&1" || die "pithead backup failed."
    SAFETY_ARCHIVE="$(on_bench "ls -t '$CANONICAL_DIR'/backups/pithead-backup-*.tar.gz 2>/dev/null | head -n1")"
    [ -n "$SAFETY_ARCHIVE" ] || die "Backup ran but produced no archive."
    ok "safety backup: $SAFETY_ARCHIVE"
}

# --- Phase 3: borrow the miner ----------------------------------------------
borrow_miner() {
    [ "$BORROW_MINER" = "1" ] || {
        warn "--no-miner: not borrowing a miner."
        return 0
    }
    log "Borrowing $MINER_HOST → pointing it at $BENCH_HOST"
    MINER_CFG_BACKUP="$MINER_XMRIG_CONFIG.e2e-orig.$(on_miner 'date +%Y%m%d-%H%M%S')"
    on_miner "cp -a '$MINER_XMRIG_CONFIG' '$MINER_CFG_BACKUP'" || die "Failed to back up the miner config."
    step "miner config backed up → $MINER_CFG_BACKUP"
    # Point the rig at the bench: inject a bench pool if the config has none (clone pool[0] so
    # user/pass/keepalive carry over, override url→bench and force plain stratum), then reorder so the
    # bench pool is primary and the rest stay as failover. Non-destructive, fully reversible from the
    # backup above. ponytail: hardcodes :3333 (the seeded canonical stratum_port default, which the bench runs).
    on_miner "
        jq --arg b '$BENCH_HOST' '
            (if any(.pools[]?; .url | ascii_downcase | contains(\$b)) then .
             else .pools = ([ (.pools[0]) + {url: (\$b + \":3333\"), tls: false, daemon: false} ] + .pools) end)
            | .pools |= ([.[] | select(.url | ascii_downcase | contains(\$b))] + [.[] | select(.url | ascii_downcase | contains(\$b) | not)])' \
            '$MINER_XMRIG_CONFIG' > '$MINER_XMRIG_CONFIG.e2e.tmp' \
        && mv '$MINER_XMRIG_CONFIG.e2e.tmp' '$MINER_XMRIG_CONFIG' && chmod 600 '$MINER_XMRIG_CONFIG'
    " || die "Failed to repoint the miner config."
    local primary
    primary="$(on_miner "jq -r '.pools[0].url' '$MINER_XMRIG_CONFIG'")"
    [ -n "$primary" ] && step "miner primary pool is now: $primary"
    case "$primary" in *"$BENCH_HOST"*) ;; *) warn "primary pool ($primary) doesn't look like the test bench — does the miner config have a test-bench pool?" ;; esac
    miner_reload
    wait_workers "$WORKERS" 180 || warn "proceeding, but the matrix's mining assertions may not pass with too few workers"
}

# --- Phase 4: deploy the branch ---------------------------------------------
deploy_branch() {
    # #272: `pithead apply` runs `compose up --pull` (never --build), so it would test whatever images
    # were last built on the box, not this branch. `pithead upgrade` re-renders the generated configs
    # (inject_service_configs) AND rebuilds the first-party images from build/ (--build) before
    # recreating — so a Dockerfile/entrypoint change in the branch is actually under test.
    log "Deploying the branch on $BENCH_HOST (pithead upgrade — re-render configs + rebuild first-party images)"
    on_bench "cd '$E2E_DIR' && ./pithead upgrade" || die "pithead upgrade failed in $E2E_DIR — branch did not deploy."
    # Record what was actually built, so "what did we test" is unambiguous in the run log (#272).
    on_bench "cd '$E2E_DIR' && docker compose images --format '{{.Service}} {{.Repository}}:{{.Tag}} {{.ID}}' 2>/dev/null | grep -E 'p2pool|dashboard|monero|tor|xmrig' || true" | while IFS= read -r l; do step "image: $l"; done
    wait_bench_healthy 300 || warn "stack applied but not yet healthy; the harness will wait on real readiness signals"
    wait_synced 300 || true # let the recreated monerod/tari re-confirm their tip before the harness pre-check
    ok "branch deployed; stack reconciled"
}

# --- Phase 5: run the live harness (detached on the box) --------------------
run_harness() {
    local phases
    case "$MODE" in
    check) phases="--check" ;;
    targeted) phases="--auth-fail-closed --lifecycle" ;; # readiness/check run inline first (below); NOT here — run.sh returns after --readiness
    matrix) phases="--safety-backup --lifecycle --fault-injection --auth-fail-closed --hardening --subnet" ;;
    esac
    # RigForge integration (#185/#235/#260) is only meaningful with a REAL rig mining through the stack.
    # The phase self-skips if no rigforge rig is connected, so this gate is just to avoid the noise.
    [ "$BORROW_MINER" = "1" ] && [ "$MODE" != "check" ] && phases="$phases --rigforge"
    # RigForge control WRITE paths (#513/#514/#516/#517) need the rig pinned in dashboard.workers[] and
    # its control API opted in. matrix only (it mutates config + dials the rig); each leg self-skips
    # loudly when its prerequisite is missing, so this stays safe on a bench without the descriptor.
    [ "$BORROW_MINER" = "1" ] && [ "$MODE" = "matrix" ] && phases="$phases --rigforge-control"
    log "Running the live harness on $BENCH_HOST (mode=$MODE, detached so an SSH drop can't kill it)"
    step "phases: $phases  (workers=$WORKERS)"

    # Push a tiny runner that captures the harness exit code into a done-marker, then nohup it.
    local runner
    runner="$(mktemp)"
    cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
dir="$1"; workers="$2"; shift 2
mkdir -p "$dir/results"
bash "$dir/tests/integration/run.sh" --local --dir "$dir" --workers "$workers" "$@" \
    > "$dir/results/e2e-harness.log" 2>&1
echo $? > "$dir/results/e2e-harness.done"
RUNNER
    on_bench "cat > '$E2E_DIR/.e2e-run.sh' && chmod +x '$E2E_DIR/.e2e-run.sh'" <"$runner"
    rm -f "$runner"

    # For non-check modes, run the safe readiness + current-state assertions inline first (fast,
    # gives early signal), then the destructive phases detached.
    if [ "$MODE" != "check" ]; then
        on_bench "cd '$E2E_DIR' && bash tests/integration/run.sh --local --dir '$E2E_DIR' --readiness --check" ||
            warn "readiness/check reported issues (see above) — continuing to the destructive phases"
    fi

    on_bench "rm -f '$E2E_DIR/results/e2e-harness.done'; cd '$E2E_DIR' && nohup ./.e2e-run.sh '$E2E_DIR' '$WORKERS' $phases >/dev/null 2>&1 & echo launched" ||
        die "Failed to launch the harness."

    # Poll the done-marker, printing a heartbeat tail of the log.
    local rc="" waited=0
    while :; do
        if on_bench "test -f '$E2E_DIR/results/e2e-harness.done'"; then
            rc="$(on_bench "cat '$E2E_DIR/results/e2e-harness.done'")"
            break
        fi
        sleep 20
        waited=$((waited + 20))
        step "harness running… ${waited}s — latest:"
        on_bench "tail -n 2 '$E2E_DIR/results/e2e-harness.log' 2>/dev/null" | sed 's/^/      /' || true
    done

    echo ""
    log "Harness finished (exit $rc). Full log:"
    on_bench "cat '$E2E_DIR/results/e2e-harness.log' 2>/dev/null" | sed 's/^/  /'
    return "${rc:-1}"
}

# --- Main -------------------------------------------------------------------
main() {
    log "Pithead e2e — branch '$BRANCH' → $BENCH_HOST (mode=$MODE)$([ "$KEEP" = 1 ] && echo '  [--keep: no restore]')"
    preflight
    provision
    backup_stack
    borrow_miner
    deploy_branch
    local hrc=0
    run_harness || hrc=$?
    # restore_all runs via the EXIT trap.
    echo ""
    if [ "$hrc" -eq 0 ]; then
        ok "E2E PASSED for '$BRANCH' (mode=$MODE)."
    else
        die "E2E FAILED for '$BRANCH' (harness exit $hrc). Artifacts under $E2E_DIR/results on $BENCH_HOST."
    fi
}

main
