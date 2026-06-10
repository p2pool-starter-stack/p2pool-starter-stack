#!/usr/bin/env bash
#
# Drive the integration mini-stack (issue #54, tier 3) through the control-plane state machine
# and assert the REAL dashboard holds/releases and rejects/readmits the REAL miner containers,
# driven by the controllable fakes. Needs docker (compose v2). Runs in CI; also `make
# test-mini-stack`.
#
# Scenarios:
#   1. boot syncing            → dashboard HOLDS itest-p2pool + itest-xmrig-proxy (#35)
#   2. both chains synced      → dashboard RELEASES them
#   3. monerod down            → dashboard REJECTS workers (stops itest-xmrig-proxy) (#31)
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

# Assert a container STAYS in a state for a window — proves the gate does NOT release/act
# prematurely (e.g. holds while only one required chain is synced). At UPDATE_INTERVAL=2 a
# few seconds spans multiple control-loop cycles.
assert_stays() {  # assert_stays <label> <container> <state> <seconds>
    sleep "$4"
    if [ "$(cstate "$2")" = "$3" ]; then
        c_ok "$1 ($2 stays $3 for ${4}s)"
    else
        c_bad "$1" "$2 became '$(cstate "$2")', expected to stay '$3'"
    fi
}

# POST a new mode to a fake's /control endpoint with a clear failure label. Host ports are
# 28081/28152 (namespaced away from a real monerod/dashboard on the same host).
set_monerod() { ctl "http://127.0.0.1:28081/control" "{\"mode\":\"$1\"}" || c_bad "set monerod $1" "control POST failed"; }
set_tari()    { ctl "http://127.0.0.1:28152/control" "{\"mode\":\"$1\"}" || c_bad "set tari $1" "control POST failed"; }

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

# 1. Booting mid-sync → the gate holds both miner containers (stops them). (#35)
log "scenario 1: holds the miner while both chains sync"
assert_state "held: itest-p2pool stopped"      itest-p2pool      exited  90
assert_state "held: itest-xmrig-proxy stopped" itest-xmrig-proxy exited  90

# 2. Monerod synced but Tari still syncing, Tari REQUIRED → STILL held (the gate needs both).
log "scenario 2: keeps holding while Tari (required) is still syncing"
set_monerod synced
assert_stays "still held on monerod-only" itest-p2pool exited 8

# 3. Tari synced too → release both. (#35)
log "scenario 3: releases the miner once both chains are synced"
set_tari synced
assert_state "released: itest-p2pool running"      itest-p2pool      running 90
assert_state "released: itest-xmrig-proxy running" itest-xmrig-proxy running 90

# 4. Tari down while required → reject workers (stop the proxy); itest-p2pool keeps running. (#31)
#    NOTE: monerod-down failover is deliberately NOT simulated here — the dashboard's monerod
#    down-path falls back to log-scraping a real `monerod` container, which this fake stack has
#    no equivalent of. That path is covered on real hardware by the tier-4 --fault-injection
#    phase. Tari has no such fallback, so its reject/readmit exercises the failover cleanly.
log "scenario 4: rejects workers when required Tari is down"
set_tari down
assert_state "rejected on Tari outage: itest-xmrig-proxy stopped" itest-xmrig-proxy exited 90
if [ "$(cstate itest-p2pool)" = "running" ]; then
    c_ok "rejection leaves itest-p2pool running (only the proxy fails over)"
else
    c_bad "rejection leaves itest-p2pool running" "itest-p2pool is '$(cstate itest-p2pool)'"
fi

# 5. Tari recovers → readmit (after the recovery-hysteresis window).
log "scenario 5: readmits workers when Tari recovers"
set_tari synced
assert_state "readmitted after Tari recovery: itest-xmrig-proxy running" itest-xmrig-proxy running 90

# 6. Dashboard restart after release → the one-way latch is persisted, so the miner is NOT
#    re-held: both containers stay running across the restart. (#35 persistence)
log "scenario 6: a dashboard restart does not re-hold a released miner"
compose restart dashboard >/dev/null 2>&1
for _ in $(seq 1 30); do
    compose exec -T dashboard python3 -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/api/state', timeout=3)" >/dev/null 2>&1 && break
    sleep 2
done
assert_stays "itest-p2pool stays up across restart"      itest-p2pool      running 6
assert_stays "itest-xmrig-proxy stays up across restart" itest-xmrig-proxy running 6

echo ""
log "mini-stack: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
