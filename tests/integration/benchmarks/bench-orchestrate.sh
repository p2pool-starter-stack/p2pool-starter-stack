#!/usr/bin/env bash
#
# bench-orchestrate.sh — autonomous driver for the Tor-vs-clearnet benchmark (#256).
#
# Runs ENTIRELY on the mining host (gouda) so the benchmark survives the operator being offline for
# days. It interleaves the two arms on a fixed block schedule (T -> C -> T -> C ...), egress-gates
# every switch, keeps the collector running, health-checks each cycle, and writes a heartbeat the
# operator reads over Tailscale (`bench-status`). All state lives in ~/pithead-bench, so a crash or a
# reboot resumes cleanly (the cron watchdog + an @reboot entry restart it). See
# docs/benchmarks/tor-vs-clearnet.md.
#
# Subcommands:
#   run [--pool mini --block-hours 36 --blocks 8 --settle-hours 6 --interval 300 --min-khs 200]
#                       start (fresh, writes state) or resume (no args, reads state) the interleaved run
#   --calibrate [--pool mini --calibrate-hours 6]   measure our share rate + sidechain fraction, then exit
#   --watchdog          (cron) ensure the run loop + stack are alive; restart/re-up if not; log health
#   --status            print status.json (see also bench-status.sh)
#   --stop              graceful stop: end the loop, restore the develop default (Tor), remove the cron
#   --install-cron      add the */15 watchdog + @reboot entries
#
# NOT `set -e`: a long unattended loop must survive transient command failures.

set -uo pipefail

DIR="${BENCH_STACK_DIR:-/srv/code/pithead}"
BENCH_DIR="${BENCH_DIR:-$HOME/pithead-bench}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$BENCH_DIR/state.env"; STATUS="$BENCH_DIR/status.json"
EVENTS="$BENCH_DIR/events.log"; ORCH_LOG="$BENCH_DIR/orchestrate.log"; PIDF="$BENCH_DIR/run.pid"
STOPF="$BENCH_DIR/stop.flag"
mkdir -p "$BENCH_DIR"

log()   { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$ORCH_LOG" >&2; }
event() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$EVENTS"; }
now()   { date -u +%s; }
pstat() { docker exec p2pool cat "/stats/$1" 2>/dev/null | jq -c . 2>/dev/null || true; }

# --- config edits (only the two transport toggles; never touches wallets/tier/other secrets) -------
set_arm() {  # <tor|clearnet>  — flip p2pool.clearnet + xvb.tor (XvB stays DISABLED), then apply (recreates p2pool+dashboard, reasserts firewall)
    local arm="$1" cn xt
    if [ "$arm" = tor ]; then cn=false; xt=true; else cn=true; xt=false; fi
    log "switching to arm=$arm (p2pool.clearnet=$cn, xvb.tor=$xt, xvb.enabled=false) — pithead apply"
    # XvB is disabled for the whole benchmark. With donation_level=auto the optimizer routes most of
    # the fleet into XvB to climb tiers (observed: ~96 kH/s to XvB vs ~18 kH/s to p2pool, target=Whale),
    # which starves p2pool and confounds reward_share — the exact metric we measure. Re-asserted on
    # every apply so a switch/recovery can't let it drift back on.
    ( cd "$DIR" && jq ".p2pool.clearnet=$cn | .xvb.tor=$xt | .xvb.enabled=false" config.json > config.json.bench && mv config.json.bench config.json )
    ( cd "$DIR" && ./pithead apply -y ) >>"$ORCH_LOG" 2>&1 || log "WARN: pithead apply returned non-zero"
}

gate_egress() {  # <arm> — Tor arm must pass the rigorous multi-poll leak check; retry once after re-applying the firewall
    local arm="$1"
    [ "$arm" = tor ] || { event "arm=$arm egress-gate=skip(clearnet)"; return 0; }
    sleep 20  # let p2pool/tari re-dial under the firewall before judging
    if bash "$HERE/bench-verify-egress.sh" tor --dir "$DIR" --polls 4 --interval 10 >>"$ORCH_LOG" 2>&1; then
        event "arm=tor egress-gate=PASS"; return 0
    fi
    log "egress gate FAILED on tor arm — re-applying firewall + re-checking"
    ( cd "$DIR" && ./pithead apply -y ) >>"$ORCH_LOG" 2>&1 || true
    sleep 20
    if bash "$HERE/bench-verify-egress.sh" tor --dir "$DIR" --polls 4 --interval 10 >>"$ORCH_LOG" 2>&1; then
        event "arm=tor egress-gate=PASS(after-firewall-retry)"; return 0
    fi
    # Last resort: a grandfathered Tari clearnet connection (#271 residue, survives via ESTABLISHED).
    # Restarting tari makes it re-dial under the firewall + proxy_bypass=false (SOCKS) → clean.
    log "still leaking — restarting tari to clear grandfathered clearnet connections (#271 residue)"
    ( cd "$DIR" && docker compose restart tari ) >>"$ORCH_LOG" 2>&1 || true
    sleep 30
    if bash "$HERE/bench-verify-egress.sh" tor --dir "$DIR" --polls 4 --interval 10 >>"$ORCH_LOG" 2>&1; then
        event "arm=tor egress-gate=PASS(after-tari-restart)"; return 0
    fi
    event "arm=tor egress-gate=FAIL — window flagged invalid"; log "ERROR: tor arm still leaking; window flagged invalid"
    return 1
}

collector_running() { pgrep -f "bench-collect.sh ${1} " >/dev/null 2>&1; }
start_collector() {  # <arm>
    local arm="$1"
    pkill -f "bench-collect.sh " 2>/dev/null || true; sleep 1
    nohup bash "$HERE/bench-collect.sh" "$arm" --interval "$INTERVAL" --out "$BENCH_DIR/${arm}.jsonl" >/dev/null 2>&1 &
    log "collector started for arm=$arm -> $BENCH_DIR/${arm}.jsonl"
}

write_status() {  # <verdict-json>
    local hc="$1" elapsed day
    elapsed=$(( $(now) - RUN_START ))
    day=$(awk -v e="$elapsed" 'BEGIN{printf "%.1f", e/86400}')
    local sh; sh="$(printf '%s' "$(pstat local/stratum)" | jq -r '(.shares_found // 0)' 2>/dev/null)"; [ -n "$sh" ] && [ "$sh" != null ] || sh=0
    local settling=false; [ "$(now)" -lt "$SETTLE_UNTIL" ] && settling=true
    jq -n --arg updated "$(date -u +%FT%TZ)" --arg arm "$ARM" \
        --argjson block "$BLOCK_IDX" --argjson blocks "$BLOCKS" --arg day "$day" \
        --arg started "$(date -u -d "@$RUN_START" +%FT%TZ 2>/dev/null || echo "")" \
        --argjson block_shares "$sh" --arg pool "$POOL" --argjson settling "$settling" \
        --argjson stopped "$([ -f "$STOPF" ] && echo true || echo false)" \
        --argjson hc "$hc" '
        {updated:$updated, pool:$pool, arm:$arm, block:$block, blocks:$blocks, day:($day|tonumber),
         started:$started, block_shares:$block_shares, settling:$settling, stopped:$stopped, health:$hc}' \
        > "$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS"
}

save_state() {
    cat > "$STATE" <<EOF
POOL=$POOL
BLOCK_HOURS=$BLOCK_HOURS
BLOCK_SECS=$BLOCK_SECS
BLOCKS=$BLOCKS
INTERVAL=$INTERVAL
SETTLE_HOURS=$SETTLE_HOURS
SETTLE_SECS=$SETTLE_SECS
MIN_KHS=$MIN_KHS
ARM=$ARM
BLOCK_IDX=$BLOCK_IDX
BLOCK_START=$BLOCK_START
RUN_START=$RUN_START
SETTLE_UNTIL=$SETTLE_UNTIL
EOF
}

# --- the run loop -----------------------------------------------------------------------------------
cmd_run() {
    # Fresh start writes state from args; a bare `run` (watchdog/reboot) resumes from state.
    POOL=mini; BLOCK_HOURS=36; BLOCKS=8; INTERVAL=300; SETTLE_HOURS=6; MIN_KHS=200; local fresh=0
    while [ $# -gt 0 ]; do case "$1" in
        --pool) POOL="$2"; fresh=1; shift 2 ;;
        --block-hours) BLOCK_HOURS="$2"; shift 2 ;;
        --blocks) BLOCKS="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --settle-hours) SETTLE_HOURS="$2"; shift 2 ;;
        --min-khs) MIN_KHS="$2"; shift 2 ;;
        *) shift ;;
    esac; done

    # bash arithmetic is integer-only — convert hours to seconds up front (float-safe).
    BLOCK_SECS=$(awk -v h="$BLOCK_HOURS" 'BEGIN{printf "%d", h*3600}')
    SETTLE_SECS=$(awk -v h="$SETTLE_HOURS" 'BEGIN{printf "%d", h*3600}')
    rm -f "$STOPF"
    if [ "$fresh" = 1 ] || [ ! -f "$STATE" ]; then
        ARM=tor; BLOCK_IDX=1; BLOCK_START=$(now); RUN_START=$(now); SETTLE_UNTIL=$(( $(now) + SETTLE_SECS ))
        save_state; event "RUN START pool=$POOL block-hours=$BLOCK_HOURS blocks=$BLOCKS settle-hours=$SETTLE_HOURS"
        ( cd "$DIR" && jq ".p2pool.pool=\"$POOL\" | .xvb.enabled=false" config.json > config.json.bench && mv config.json.bench config.json )
        set_arm tor; gate_egress tor || true; start_collector tor
    else
        # shellcheck disable=SC1090
        . "$STATE"; log "resuming: arm=$ARM block=$BLOCK_IDX/$BLOCKS"
        collector_running "$ARM" || start_collector "$ARM"
    fi
    echo $$ > "$PIDF"

    while :; do
        [ -f "$STOPF" ] && { log "stop flag seen — exiting loop"; break; }

        # time to switch arms?
        if [ $(( $(now) - BLOCK_START )) -ge "$BLOCK_SECS" ]; then
            if [ "$BLOCK_IDX" -ge "$BLOCKS" ]; then
                event "RUN COMPLETE — $BLOCKS blocks done"; log "all $BLOCKS blocks complete — stopping"
                cmd_stop; break
            fi
            BLOCK_IDX=$(( BLOCK_IDX + 1 ))
            [ "$ARM" = tor ] && ARM=clearnet || ARM=tor
            BLOCK_START=$(now); SETTLE_UNTIL=$(( $(now) + SETTLE_SECS ))
            event "BLOCK $BLOCK_IDX/$BLOCKS arm=$ARM (settle ${SETTLE_HOURS}h)"
            save_state
            set_arm "$ARM"; gate_egress "$ARM" || true; start_collector "$ARM"
        fi

        # health + self-heal + heartbeat
        collector_running "$ARM" || { log "collector died — restarting"; start_collector "$ARM"; }
        local hc verdict
        hc="$(bash "$HERE/bench-healthcheck.sh" --dir "$DIR" --min-khs "$MIN_KHS" --json 2>/dev/null)"; [ -n "$hc" ] || hc='{"verdict":"UNKNOWN"}'
        verdict="$(printf '%s' "$hc" | jq -r '.verdict // "UNKNOWN"')"
        if [ "$verdict" = BROKEN ]; then
            event "HEALTH BROKEN: $(printf '%s' "$hc" | jq -r '.problems')"
            log "BROKEN — attempting recovery (stack up + re-gate egress)"
            ( cd "$DIR" && ./pithead up >>"$ORCH_LOG" 2>&1 ) || true
            gate_egress "$ARM" || true
        fi
        save_state; write_status "$hc"
        sleep "$INTERVAL"
    done
}

# --- calibration ------------------------------------------------------------------------------------
cmd_calibrate() {
    POOL=mini; local CH=6
    while [ $# -gt 0 ]; do case "$1" in --pool) POOL="$2"; shift 2 ;; --calibrate-hours) CH="$2"; shift 2 ;; *) shift ;; esac; done
    log "calibration: pool=$POOL window=${CH}h — setting Tor arm + sampling share rate"
    ( cd "$DIR" && jq ".p2pool.pool=\"$POOL\" | .p2pool.clearnet=false | .xvb.tor=true | .xvb.enabled=false" config.json > config.json.bench && mv config.json.bench config.json )
    set_arm tor; gate_egress tor || true; start_collector tor
    log "warming up 600s for p2pool to connect + start finding shares..."; sleep 600
    local s0 t0 s1 t1 secs spd frac poolhr ourhr
    s0="$(printf '%s' "$(pstat local/stratum)" | jq -r '(.shares_found // 0)')"; t0=$(now)
    log "baseline shares_found=$s0; sampling for ${CH}h..."; sleep "$(awk -v h="$CH" 'BEGIN{print int(h*3600)}')"
    s1="$(printf '%s' "$(pstat local/stratum)" | jq -r '(.shares_found // 0)')"; t1=$(now)
    ourhr="$(printf '%s' "$(pstat local/stratum)" | jq -r '(.hashrate_1h // 0)')"
    poolhr="$(printf '%s' "$(pstat pool/stats)" | jq -r '(.pool_statistics.hashRate // 0)')"
    secs=$(( t1 - t0 ))
    spd="$(awk -v a="$s0" -v b="$s1" -v s="$secs" 'BEGIN{ if(s>0) printf "%.1f", (b-a)*86400/s; else print "0"}')"
    frac="$(awk -v o="$ourhr" -v p="$poolhr" 'BEGIN{ if(p>0) printf "%.2f", o*100/p; else print "0"}')"
    log "CALIBRATION RESULT: ~${spd} shares/day | our hashrate=${ourhr} H/s = ${frac}% of the ${POOL} sidechain (pool=${poolhr} H/s)"
    printf 'shares/day=%s our_pct=%s pool_hr=%s our_hr=%s\n' "$spd" "$frac" "$poolhr" "$ourhr" | tee -a "$EVENTS"
}

# --- watchdog (cron) --------------------------------------------------------------------------------
cmd_watchdog() {
    [ -f "$STOPF" ] && { exit 0; }   # intentionally stopped
    [ -f "$STATE" ] || { exit 0; }   # nothing to supervise yet
    if ! pgrep -f "bench-orchestrate.sh run" >/dev/null 2>&1; then
        log "watchdog: run loop not alive — restarting (resume from state)"
        nohup bash "$HERE/bench-orchestrate.sh" run >>"$ORCH_LOG" 2>&1 &
    fi
    local running; running="$(cd "$DIR" && docker compose ps --services --status running 2>/dev/null | wc -l)"
    if [ "${running:-0}" -lt 5 ] 2>/dev/null; then log "watchdog: stack down (${running:-0} svc) — pithead up"; ( cd "$DIR" && ./pithead up >>"$ORCH_LOG" 2>&1 ) || true; fi
    bash "$HERE/bench-healthcheck.sh" --dir "$DIR" --min-khs "$(grep -E '^MIN_KHS=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 200)" >> "$BENCH_DIR/health.log" 2>&1 || true
}

cmd_stop() {
    touch "$STOPF"; log "stop requested"
    pkill -f "bench-collect.sh " 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v "bench-orchestrate.sh" | crontab - 2>/dev/null || true
    # Restore the resting config: Tor default + XvB re-enabled (gouda's normal pre-benchmark state).
    ( cd "$DIR" && jq '.p2pool.clearnet=false | .xvb.tor=true | .xvb.enabled=true' config.json > config.json.bench && mv config.json.bench config.json && ./pithead apply -y ) >>"$ORCH_LOG" 2>&1 || true
    log "stopped: collector killed, cron removed, restored Tor default + re-enabled XvB. Data kept in $BENCH_DIR."
}

cmd_install_cron() {
    local self="$HERE/bench-orchestrate.sh" tmp; tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -v "bench-orchestrate.sh" > "$tmp" || true
    echo "*/15 * * * * BENCH_STACK_DIR=$DIR bash $self --watchdog" >> "$tmp"
    echo "@reboot BENCH_STACK_DIR=$DIR bash $self --watchdog" >> "$tmp"
    crontab "$tmp" && rm -f "$tmp" && log "watchdog cron installed (*/15 + @reboot)"
}

case "${1:-}" in
    run)            shift; cmd_run "$@" ;;
    --calibrate)    shift; cmd_calibrate "$@" ;;
    --watchdog)     cmd_watchdog ;;
    --status)       cat "$STATUS" 2>/dev/null || echo "no status yet" ;;
    --stop)         cmd_stop ;;
    --install-cron) cmd_install_cron ;;
    *) echo "usage: bench-orchestrate.sh {run|--calibrate|--watchdog|--status|--stop|--install-cron} [opts]" >&2; exit 2 ;;
esac
