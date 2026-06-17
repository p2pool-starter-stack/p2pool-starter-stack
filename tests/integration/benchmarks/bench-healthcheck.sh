#!/usr/bin/env bash
#
# bench-healthcheck.sh — read-only health assessment for the Tor-vs-clearnet benchmark (#256).
#
# Runs the checklist that tells us "is the run still valid?" and prints a one-line verdict plus a
# compact JSON blob. NO side effects — the orchestrator calls it every cycle to decide whether to
# self-protect, the cron watchdog calls it to log, and an operator can run it by hand over Tailscale.
#
#   bench-healthcheck.sh [--dir STACK_DIR] [--min-khs N] [--json]
#
# Exit code: 0 = OK, 1 = WARN (degraded but data still usable), 2 = BROKEN (this window is invalid).
#
# Checks (sources match bench-collect.sh so the picture is consistent):
#   stack    — the core containers are running                         (docker compose ps)
#   p2pool   — serving stratum + has sidechain peers + sees our hashrate (/stats/local/{stratum,p2p})
#   hashrate — p2pool's view of our hashrate is >= --min-khs            (miners still connected)
#   egress   — TOR arm only: no persistent clearnet leak                (bench-verify-egress.sh)
#   firewall — TOR arm only: the #270 DOCKER-USER rules are installed
# The current arm is inferred from .env P2POOL_FLAGS (--socks5 present => Tor arm).

set -uo pipefail

DIR="/srv/code/pithead"; MIN_KHS=200; MIN_WORKERS=6; JSON=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dir)         DIR="$2"; shift 2 ;;
        --min-khs)     MIN_KHS="$2"; shift 2 ;;        # accepted for compat; hashrate is display-only (see below)
        --min-workers) MIN_WORKERS="$2"; shift 2 ;;
        --json)        JSON=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pstat() { docker exec p2pool cat "/stats/$1" 2>/dev/null | jq -c . 2>/dev/null || true; }
envv()  { grep -E "^$1=" "$DIR/.env" 2>/dev/null | head -n1 | cut -d= -f2- ; }

problems=""; warns=""

# 1. Core containers running.
running="$(cd "$DIR" && docker compose ps --services --status running 2>/dev/null | sort | tr '\n' ' ')"
core_down=""
for s in monerod p2pool tari xmrig-proxy tor; do
    case " $running " in *" $s "*) ;; *) core_down="${core_down}$s ";; esac
done
[ -z "$core_down" ] || problems="${problems}core-down:[${core_down% }] "

# 2. p2pool serving + peers + our hashrate.
strat="$(pstat local/stratum)"; [ -n "$strat" ] || strat=null
p2p="$(pstat local/p2p)";       [ -n "$p2p" ]   || p2p=null
# 15m average (not 1h) so the check reflects reality within ~15 min of a fleet connect / arm-switch
# p2pool restart, instead of falsely flagging low-hashrate for ~an hour while a 1h average ramps.
hr_hs="$(printf '%s' "$strat" | jq -r '(.hashrate_15m // 0)')"; [ "$hr_hs" = null ] && hr_hs=0
hr_khs=$(awk -v h="${hr_hs:-0}" 'BEGIN{printf "%.0f", h/1000}')
peers="$(printf '%s' "$p2p" | jq -r '(.connections // 0)')"; [ "$peers" = null ] && peers=0
[ "$strat" = null ] && problems="${problems}p2pool-no-stratum "
[ "${peers:-0}" -gt 0 ] 2>/dev/null || warns="${warns}p2pool-0-peers "

# 3. Miners connected — use proxy_workers (reliable). p2pool's hashrate_1h/15m is a SHARE-BASED
# estimate, very jumpy on mini where shares are sparse, so it would false-WARN; it's display-only.
# The dashboard is host-networked, so it's on 127.0.0.1:8000 of the box.
workers="$(curl -fsS --max-time 5 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.proxy_workers // empty' 2>/dev/null)"
if [ -n "$workers" ]; then
    [ "$workers" -ge "$MIN_WORKERS" ] 2>/dev/null || warns="${warns}miners(${workers}/${MIN_WORKERS}+expected) "
else
    workers="?"   # dashboard unreachable; don't WARN on the noisy hashrate estimate
fi

# 4 + 5. Arm-dependent: TOR arm must not leak and must have the firewall.
arm=clearnet
case "$(envv P2POOL_FLAGS)" in *--socks5*) arm=tor ;; esac
egress=n/a; fw=n/a
if [ "$arm" = tor ]; then
    # 3-poll/30s persistence check — matches the switch-time gate's rigor so a brief Tari connection
    # (Tari still attempts some direct dials that the firewall DROPs; the home IP is never exposed)
    # doesn't false-flag BROKEN and trigger an unnecessary recovery. Only a SUSTAINED leak fails.
    if bash "$HERE/bench-verify-egress.sh" tor --dir "$DIR" --polls 3 --interval 10 >/dev/null 2>&1; then
        egress=clean
    else
        egress=LEAK; problems="${problems}clearnet-leak "
    fi
    fwn=$(sudo -n iptables -S DOCKER-USER 2>/dev/null | grep -c pithead-tor-egress || true)
    fw="${fwn:-0}"
    [ "${fwn:-0}" -ge 7 ] 2>/dev/null || warns="${warns}firewall(${fwn:-0}/7) "
fi

# Verdict.
if [ -n "$problems" ]; then verdict=BROKEN; rc=2
elif [ -n "$warns" ]; then verdict=WARN; rc=1
else verdict=OK; rc=0; fi

now="$(date -u +%FT%TZ)"
if [ "$JSON" = 1 ]; then
    jq -cn --arg v "$verdict" --arg arm "$arm" --arg workers "${workers:-?}" --argjson khs "${hr_khs:-0}" --argjson peers "${peers:-0}" \
        --arg egress "$egress" --arg fw "$fw" --arg t "$now" \
        --arg problems "${problems% }" --arg warns "${warns% }" \
        '{ts:$t, verdict:$v, arm:$arm, workers:$workers, hashrate_khs:$khs, peers:$peers, egress:$egress, firewall:$fw, problems:$problems, warns:$warns}'
else
    printf '%s [%s] arm=%s workers=%s hashrate~%skH/s peers=%s egress=%s%s%s\n' \
        "$now" "$verdict" "$arm" "${workers:-?}" "${hr_khs:-0}" "${peers:-0}" "$egress" \
        "${problems:+ problems=[${problems% }]}" "${warns:+ warns=[${warns% }]}"
fi
exit "$rc"
