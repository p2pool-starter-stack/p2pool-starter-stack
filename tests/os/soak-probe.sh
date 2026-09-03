#!/usr/bin/env bash
# The 7-day unattended soak's daily probe (#1652). Runs on the build host, never on the box, and
# reads the box over ONE non-interactive SSH session whose remote command is fixed below, so a
# reader can audit exactly what the only permitted login did. It appends one line per run to
# LOGDIR/soak.log, keeps the day-0 baseline in LOGDIR/day0.env, and scores the day against the
# pass condition ruled on #1652 — a missing measurement is a FAIL, never a skip.
#
#   tests/os/soak-probe.sh HOST LOGDIR --start     # day 0: write the baseline, open the window
#   tests/os/soak-probe.sh HOST LOGDIR             # every later day (a cron line on the build host)
#   tests/os/soak-probe.sh --self-test             # the verdict over canned readings, no box
#
#   0 6 * * *  $HOME/dev/<worktree>/tests/os/soak-probe.sh <ipv4> $HOME/soak-1652 >>$HOME/soak-1652/cron.log 2>&1
#
# The rules, and the instrument each one reads (#1659 made plain `journalctl -b` unusable on the
# bench for the whole boot, so nothing here depends on it):
#   1 one boot        — /proc/stat btime equals day 0's; the journal-directory count is the
#                       secondary counter (one directory per boot until #1659 lands).
#   2 restarts flat   — every container's RestartCount equals day 0's, AND its StartedAt is day
#                       0's: a supervisor restart moves the first, a hand `podman stop/start`
#                       moves only the second.
#   3 all running     — every day-0 container is `running`; health asserted for all EXCEPT
#                       xmrig-proxy, whose healthcheck is the product defect #1098 (excluded BY
#                       NAME; it must still be running with rules 1-2 holding). The set is DAY 0's:
#                       a container that appears later is outside rule 3 by decision — rule 4
#                       covers the only route by which one could be started.
#   4 no intervention — `journalctl -m -u ssh` counts EXACTLY ONE `Accepted` since the previous
#                       probe's read: this probe's own login. The count starts at the journal
#                       CURSOR the previous read recorded (LOGDIR/ssh.cursor, passed to the remote
#                       command as its one named input), so there is no window edge to straddle
#                       and no clock on either side to trust. With no cursor (day 0, or the file
#                       missing) it falls back to the last 25 h and the line says `window=25h`, so
#                       day 0's line carries a rule-4 FAIL from the setup logins: it is the
#                       baseline, not a soak day. A count of 0 FAILS naming the instrument
#                       (`ssh-journal-blind`): the probe's own login is a positive control the
#                       reading must hold, so 0 means the journal could not be read (cursor
#                       journal split, journald down) — never a quiet day. A cursor names one
#                       entry in one journal file, and a cursor that no longer resolves (journal
#                       vacuumed or reset, box re-flashed) is loud either way, measured both ways
#                       on 2026-09-03: the build host's journalctl refuses the seek (count 0,
#                       `ssh-journal-blind`), the box's seeks to the START and counts every login
#                       on record (457) — a day that fails rule 1 as well, which is the right
#                       answer for it. The read then records a fresh cursor, so the next day
#                       scores normally. journald
#                       writes asynchronously, so a 0 or a 2 on a live box is a rare LOUD flake
#                       to look at, not a silent pass. `last` shows no interactive session; rule
#                       2's StartedAt covers hand-run container verbs. `last` is recorded because
#                       the ruling names it, and it is a NULL instrument on the bench (no wtmp: it
#                       read 0 with 22 logins in the journal) — the journal count is the one that
#                       fires.
#   5 chain recorded  — monerod height / synchronized / peers are RECORDED (a stall is visible)
#                       and never gate. Tari is recorded by container state only: the box has no
#                       gRPC client, so its height is not read — stated, not skipped silently.
# A day whose line is missing, or whose SSH read failed, is a FAIL by the ruling's own terms; a
# failed read keeps the previous cursor, so the next good day also counts the failed day's login.
# The session skips host-key checking on purpose: the box regenerates its host key on every
# provisioning (#1659's churn) and the probe is read-only on a bench LAN, so a pinned key would
# only turn each re-flash into a READ-FAILED day.
set -uo pipefail

KEY="${PITHEAD_SOAK_KEY:-$HOME/.ssh/pithead-os-test}"
EXCLUDED_HEALTH="xmrig-proxy"

# The one remote command. Read-only by construction: every line is a read, and the .env is
# consulted for monerod's RPC credentials without ever printing them.
read_box() { # $1 = host, $2 = previous read's journal cursor or empty; prints key=value lines
    timeout 120 ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$1" "SOAK_CURSOR='$2' bash -s" <<'REMOTE'
set -u
printf 'btime=%s\n' "$(awk '/^btime/{print $2}' /proc/stat)"
printf 'jdirs=%s\n' "$(ls /var/log/journal 2>/dev/null | wc -l)"
printf 'uptime_s=%s\n' "$(awk '{print int($1)}' /proc/uptime)"
printf 'load=%s\n' "$(cut -d' ' -f1-3 /proc/loadavg | tr ' ' ',')"
printf 'data_free_mb=%s\n' "$(df -Pk /data 2>/dev/null | awk 'NR==2{print int($4/1024)}')"
printf 'rauc=%s\n' "$(rauc status --output-format=shell 2>/dev/null | awk -F= '/^RAUC_SYSTEM_BOOTED_BOOTNAME=/{b=$2} /^RAUC_BOOT_PRIMARY=/{p=$2} END{gsub(/\x27/,"",b); gsub(/\x27/,"",p); printf "%s/%s", b, p}')"
for c in $(podman ps -aq 2>/dev/null); do
    podman inspect -f 'container={{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}' "$c" 2>/dev/null
done
if [ -n "${SOAK_CURSOR:-}" ]; then
    printf 'ssh_window=cursor\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --after-cursor="$SOAK_CURSOR" --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
else
    printf 'ssh_window=25h\n'
    printf 'ssh_accepted=%s\n' "$(journalctl -m -u ssh --since '-25h' --no-pager -q 2>/dev/null | grep -c 'Accepted ')"
fi
printf 'ssh_cursor=%s\n' "$(journalctl -m -u ssh -n1 --no-pager -q -o cat --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')"
printf 'last_sessions=%s\n' "$(last -F 2>/dev/null | grep -v -c -E '^(reboot|wtmp|$)')"
env_get() { sed -n "s/^$1=//p" /data/pithead/.env 2>/dev/null | head -1 | tr -d '"'; }
mu=$(env_get MONERO_NODE_USERNAME); mp=$(env_get MONERO_NODE_PASSWORD); murl=$(env_get MONERO_RPC_URL); [ -n "$murl" ] || murl=http://127.0.0.1:18081
if [ -n "$mu" ]; then body=$(curl -fsS --max-time 8 --digest -u "$mu:$mp" "$murl/get_info" 2>/dev/null); else body=$(curl -fsS --max-time 8 "$murl/get_info" 2>/dev/null); fi
printf 'monero=%s\n' "$(printf '%s' "${body:-null}" | jq -r '"h:\(.height // "?") sync:\(.synchronized // "?") peers:\(.incoming_connections_count // "?")/\(.outgoing_connections_count // "?")"' 2>/dev/null || echo 'h:? sync:? peers:?/?')"
REMOTE
}

# Pure over the readings: $1 = day-0 baseline (key=value lines), $2 = today's readings. Prints
# `VERDICT=PASS|FAIL fails=<rule list>` on stdout; exit 0 on PASS. Every rule that cannot be
# measured today FAILS, so an empty reading can never pass.
soak_day_verdict() {
    local base="$1" today="$2" fails="" b t
    rd() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; } # a reading, not the top-level kv
    b=$(rd "$base" btime)
    t=$(rd "$today" btime)
    { [ -n "$b" ] && [ "$b" = "$t" ]; } || fails="$fails 1:boot(btime $b->${t:-?})"
    b=$(rd "$base" jdirs)
    t=$(rd "$today" jdirs)
    { [ -n "$t" ] && [ "${t:-0}" -le "${b:-0}" ]; } 2>/dev/null || fails="$fails 1:journal-dirs($b->${t:-?})"
    local name brc bstarted tstate trc thealth tstarted tline
    while IFS='|' read -r name _ brc _ bstarted; do
        [ -n "$name" ] || continue
        tline=$(printf '%s\n' "$today" | sed -n "s/^container=$name|//p" | head -1)
        if [ -z "$tline" ]; then
            fails="$fails 3:$name-missing"
            continue
        fi
        IFS='|' read -r tstate trc thealth tstarted <<<"$tline"
        [ "$tstate" = running ] || fails="$fails 3:$name-$tstate"
        [ "$trc" = "$brc" ] || fails="$fails 2:$name-restarts($brc->$trc)"
        [ "$tstarted" = "$bstarted" ] || fails="$fails 2:$name-started-anew"
        if [ "$name" != "$EXCLUDED_HEALTH" ] && [ "$thealth" != none ] && [ "$thealth" != healthy ]; then fails="$fails 3:$name-$thealth"; fi
    done < <(printf '%s\n' "$base" | sed -n 's/^container=//p')
    t=$(rd "$today" ssh_accepted)
    case "$t" in
    '' | *[!0-9]*) fails="$fails 4:ssh-accepted(${t:-?})" ;;
    0) fails="$fails 4:ssh-journal-blind(0)" ;; # the probe's own login is missing: the instrument, not the day
    1) ;;
    *) fails="$fails 4:ssh-accepted($t)" ;;
    esac
    t=$(rd "$today" last_sessions)
    { [ -n "$t" ] && [ "$t" -eq 0 ]; } 2>/dev/null || fails="$fails 4:last-sessions(${t:-?})"
    if [ -z "$fails" ]; then
        echo "VERDICT=PASS"
        return 0
    fi
    echo "VERDICT=FAIL fails=${fails# }"
    return 1
}

self_test() {
    local base today out
    base=$'btime=100\njdirs=1\ncontainer=monerod|running|0|healthy|2026-09-03T06:00:00Z\ncontainer=xmrig-proxy|running|0|unhealthy|2026-09-03T06:00:00Z\nssh_window=cursor\nssh_accepted=1\nlast_sessions=0\nmonero=h:100 sync:true peers:1/2'
    n=0
    f=0
    chk() { if [ "$2" = "$3" ]; then n=$((n + 1)); else
        f=$((f + 1))
        echo "  ✗ $1: [$2] wanted [$3]"
    fi; }
    out=$(soak_day_verdict "$base" "$base")
    chk "identical day passes (xmrig-proxy unhealthy is excluded by name)" "$?" 0
    today=${base/btime=100/btime=200}
    out=$(soak_day_verdict "$base" "$today")
    chk "a new btime fails rule 1" "$?" 1
    chk "  …named" "${out#*fails=}" "1:boot(btime 100->200)"
    today=${base/jdirs=1/jdirs=2}
    out=$(soak_day_verdict "$base" "$today")
    chk "a new journal directory fails rule 1" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|running|1|healthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "a supervisor restart fails rule 2" "$?" 1
    chk "  …named" "${out#*fails=}" "2:monerod-restarts(0->1)"
    today=${base/monerod|running|0|healthy|2026-09-03T06:00:00Z/monerod|running|0|healthy|2026-09-04T06:00:00Z}
    out=$(soak_day_verdict "$base" "$today")
    chk "a hand stop/start (StartedAt moved, RestartCount not) fails rule 2" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|exited|0|none}
    out=$(soak_day_verdict "$base" "$today")
    chk "a container not running fails rule 3" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|running|0|unhealthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "monerod unhealthy fails rule 3 (only xmrig-proxy is excluded)" "$?" 1
    today=${base/xmrig-proxy|running|0|unhealthy/xmrig-proxy|exited|0|unhealthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "xmrig-proxy NOT running still fails rule 3 (the exclusion is health only)" "$?" 1
    today=$(printf '%s\n' "$base" | grep -v '^container=monerod')
    out=$(soak_day_verdict "$base" "$today")
    chk "a day-0 container missing from today fails rule 3" "$?" 1
    today=${base/ssh_accepted=1/ssh_accepted=2}
    out=$(soak_day_verdict "$base" "$today")
    chk "a second SSH login fails rule 4" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-accepted(2)"
    today=${base/ssh_accepted=1/ssh_accepted=0}
    out=$(soak_day_verdict "$base" "$today")
    chk "zero logins fails rule 4 naming the instrument (the probe's own login is the positive control)" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-journal-blind(0)"
    today=$(printf '%s\n' "$base" | grep -v '^ssh_accepted=')
    out=$(soak_day_verdict "$base" "$today")
    chk "no ssh reading at all fails rule 4" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-accepted(?)"
    today=${base/monero=h:100 sync:true peers:1\/2/monero=h:50 sync:false peers:0\/0}
    out=$(soak_day_verdict "$base" "$today")
    chk "a changed chain reading still passes (rule 5 records, never gates)" "$?" 0
    today=${base/last_sessions=0/last_sessions=1}
    out=$(soak_day_verdict "$base" "$today")
    chk "an interactive session fails rule 4" "$?" 1
    out=$(soak_day_verdict "$base" "")
    chk "an empty reading FAILS every rule, never passes" "$?" 1
    echo "soak-probe self-test: $n ok, $f failed"
    [ "$f" -eq 0 ]
}

case "${1:-}" in
--self-test)
    self_test
    exit $?
    ;;
'' | -h | --help)
    awk 'NR > 1 && /^set -/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
if [ -z "${2:-}" ]; then # HOST without LOGDIR would mkdir "" and write day0.env at /
    echo "usage: $0 HOST LOGDIR [--start] | --self-test" >&2
    exit 2
fi
HOST="$1"
LOGDIR="$2"
MODE="${3:-}"
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# The previous read's journal cursor is the one input the fixed remote command takes. --start
# opens a new window and ignores any cursor a previous window left behind.
cursor=""
if [ "$MODE" != "--start" ] && [ -s "$LOGDIR/ssh.cursor" ]; then
    cursor=$(head -1 "$LOGDIR/ssh.cursor")
    case "$cursor" in *[!A-Za-z0-9\;=]*) cursor="" ;; esac # anything else never came from journalctl
fi
today=$(read_box "$HOST" "$cursor")
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$today" ]; then
    printf '%s day=? READ-FAILED ssh rc=%s VERDICT=FAIL fails=read\n' "$now" "$rc" | tee -a "$LOGDIR/soak.log"
    exit 1
fi
if [ "$MODE" = "--start" ]; then
    printf '%s\n' "$today" >"$LOGDIR/day0.env"
    printf '%s\n' "$now" >"$LOGDIR/started"
fi
[ -s "$LOGDIR/day0.env" ] || {
    printf '%s day=? NO-BASELINE VERDICT=FAIL fails=baseline (run with --start first)\n' "$now" | tee -a "$LOGDIR/soak.log"
    exit 1
}
day=$((($(date -u +%s) - $(date -u -d "$(cat "$LOGDIR/started")" +%s)) / 86400))
kv() { printf '%s\n' "$today" | sed -n "s/^$1=//p" | head -1; }
running=$(printf '%s\n' "$today" | grep -c '^container=.*|running|')
total=$(printf '%s\n' "$today" | grep -c '^container=')
unhealthy=$(printf '%s\n' "$today" | sed -n 's/^container=\([^|]*\)|[^|]*|[^|]*|unhealthy|.*/\1/p' | tr '\n' ',' | sed 's/,$//')
verdict=$(soak_day_verdict "$(cat "$LOGDIR/day0.env")" "$today")
printf '%s day=%s btime=%s jdirs=%s up=%ss running=%s/%s unhealthy=%s ssh_accepted=%s window=%s last=%s monero=%s rauc=%s data_free_mb=%s load=%s %s\n' \
    "$now" "$day" "$(kv btime)" "$(kv jdirs)" "$(kv uptime_s)" "$running" "$total" "${unhealthy:-none}" "$(kv ssh_accepted)" "$(kv ssh_window)" "$(kv last_sessions)" "$(kv monero)" "$(kv rauc)" "$(kv data_free_mb)" "$(kv load)" "$verdict" |
    tee -a "$LOGDIR/soak.log"
printf '%s\n' "$today" >"$LOGDIR/day$day.env"
[ -n "$(kv ssh_cursor)" ] && printf '%s\n' "$(kv ssh_cursor)" >"$LOGDIR/ssh.cursor"
case "$verdict" in VERDICT=PASS*) exit 0 ;; *) exit 1 ;; esac
