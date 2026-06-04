#!/usr/bin/env bash
#
# Drive the integration mini-stack (issue #54, tier 3) through the control-plane state machine
# and assert the REAL dashboard holds/releases and rejects/readmits the REAL miner containers,
# driven by the controllable fakes. Needs docker (compose v2). Runs in CI; also `make
# test-mini-stack`.
#
# Scenarios:
#   1. boot syncing            → dashboard HOLDS p2pool + xmrig-proxy (#35)
#   2. both chains synced      → dashboard RELEASES them
#   3. monerod down            → dashboard REJECTS workers (stops xmrig-proxy) (#31)
#   4. monerod back            → dashboard READMITS workers
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$HERE/docker-compose.fake.yml"
PASS=0
FAIL=0

c_ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
c_bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "${2:-}"; }
log()   { printf '\033[1;36m[mini-stack]\033[0m %s\n' "$1"; }

if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP: docker compose not available"
    exit 0
fi

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
cstate()  { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"; }
ctl()     { curl -fsS --max-time 5 "$1" -d "$2" >/dev/null; }   # POST JSON to a fake /control

# Poll a container until it reaches an expected state, or time out.
wait_state() {  # wait_state <container> <expected-state> [timeout_s]
    local c="$1" want="$2" timeout="${3:-60}" end
    end=$(( $(date +%s) + timeout ))
    while :; do
        [ "$(cstate "$c")" = "$want" ] && return 0
        [ "$(date +%s)" -ge "$end" ] && return 1
        sleep 1
    done
}

assert_state() {  # assert_state <label> <container> <expected> [timeout]
    if wait_state "$2" "$3" "${4:-60}"; then
        c_ok "$1 ($2 → $3)"
    else
        c_bad "$1" "$2 is '$(cstate "$2")', expected '$3'"
    fi
}

teardown() {
    log "tearing down"
    compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap teardown EXIT

log "building images"
if ! compose build >/dev/null 2>&1; then
    c_bad "build" "docker compose build failed"
    exit 1
fi

log "starting the mini-stack (fakes boot mid-sync)"
compose up -d >/dev/null 2>&1

# Wait for the dashboard's API to answer (it binds 127.0.0.1:8000 inside the container).
log "waiting for the dashboard API"
api_up=0
for _ in $(seq 1 30); do
    if compose exec -T dashboard python3 -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/state', timeout=3)" >/dev/null 2>&1; then
        api_up=1; break
    fi
    sleep 2
done
[ "$api_up" = 1 ] && c_ok "dashboard API is up" || c_bad "dashboard API is up" "no /api/state after ~60s"

# 1. Booting mid-sync → the gate holds both miner containers (stops them).
log "scenario 1: holds the miner while syncing"
assert_state "held: p2pool stopped"      p2pool      exited  90
assert_state "held: xmrig-proxy stopped" xmrig-proxy exited  90

# 2. Both chains report synced → release.
log "scenario 2: releases the miner once synced"
ctl "http://127.0.0.1:18081/control" '{"mode":"synced"}' || c_bad "set monerod synced" "control POST failed"
ctl "http://127.0.0.1:18152/control" '{"mode":"synced"}' || c_bad "set tari synced" "control POST failed"
assert_state "released: p2pool running"      p2pool      running 90
assert_state "released: xmrig-proxy running" xmrig-proxy running 90

# 3. monerod goes down → reject workers (stop xmrig-proxy); p2pool keeps running.
log "scenario 3: rejects workers when monerod is down"
ctl "http://127.0.0.1:18081/control" '{"mode":"down"}' || c_bad "set monerod down" "control POST failed"
assert_state "rejected: xmrig-proxy stopped" xmrig-proxy exited  90
if [ "$(cstate p2pool)" = "running" ]; then
    c_ok "rejection leaves p2pool running (only the proxy is failed over)"
else
    c_bad "rejection leaves p2pool running" "p2pool is '$(cstate p2pool)'"
fi

# 4. monerod recovers → readmit workers.
log "scenario 4: readmits workers when monerod recovers"
ctl "http://127.0.0.1:18081/control" '{"mode":"synced"}' || c_bad "set monerod synced" "control POST failed"
assert_state "readmitted: xmrig-proxy running" xmrig-proxy running 90

echo ""
log "mini-stack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
