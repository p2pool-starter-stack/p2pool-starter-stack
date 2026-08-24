#!/usr/bin/env bash
# Failure evidence for the battery's os-update leg (#1060). Sourced by tests/os/run.sh; uses
# its globals (_ssh, SSH_ERR, SERIAL) and prints in its indentation idiom.
#
# The ~60% mid-copy death survived four batteries because the evidence of WHO killed the
# command was discarded at three separate layers: the assertion printed a truncated tail and
# no exit status; _ssh's client stderr went to a scratch file nothing printed; and the serial
# console was truncated by the next VM boot before cleanup()'s end-of-phase copy ran. This
# captures all of it at the moment of failure, from both ends of the transport.

# osupdate_failure_evidence <rc> <full-cli-output>
# rc 124 is timeout(1)'s kill — the harness's own per-call ceiling, not the guest; rc 255 is
# ssh transport death. Both look identical in the remote output, which simply stops.
osupdate_failure_evidence() {
    printf '     os-update rc=%s (124 = harness timeout kill, 255 = ssh transport death)\n' "$1"
    printf '     ssh client stderr: %s\n' "$(tr -d '\r' <"$SSH_ERR" 2>/dev/null | tail -3 | tr '\n' ';')"
    printf '     os-update output:\n'
    printf '%s\n' "$2" | sed 's/^/     | /'
    # The console NOW, not at phase end: later boots truncate $SERIAL, which is how every
    # prior occurrence left no console evidence. cleanup() will not clobber this copy.
    cp -f "$SERIAL" "$SERIAL.failed" 2>/dev/null || true
    # The guest's own account, captured before the guest is recycled: the kernel's word on
    # kills, rauc's own journal, and the memory/writeback picture — the CLI output cannot
    # distinguish a killed command from a failed one, these can.
    printf '     --- guest evidence (#1060) ---\n'
    _ssh "journalctl -k --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -5
          echo '-- rauc unit --'; journalctl -u rauc --no-pager -n 8 2>/dev/null
          echo '-- memory --'; free -m | head -2
          grep -E 'MemAvailable|HugePages_Total|^Dirty|^Writeback:' /proc/meminfo" 2>/dev/null |
        tr -d '\r' | sed 's/^/     · /'
}

# backup_failure_evidence — the restore leg's source backup refused to complete (#1059).
#
# The known occurrence was `tar: data/pithead/config.json: Cannot stat` on a machine whose
# config.json was a present, root-owned regular file seconds earlier, with `.env` beside it
# archiving fine — and the guest was recycled before anyone could look, twice. What the CLI
# log alone cannot say is whether the file was RENAMED and by whom.
#
# The tree is the discriminator. Every path that removes config.json without touching .env
# lives in the firstboot wizard loop, and on an INSTALLED machine that has already accepted a
# config and brought its stack up, one of them is reachable: the setup-failure branch, which
# does `mv -f config.json config.json.failed` and re-mints a token. (The rest are pre-setup
# validator rejections, or installer-STICK paths keyed on an install-request and /boot/efi.)
# `config.json.failed` on disk names that branch outright, and the spool it writes beside it
# (error.txt, last-attempt.json) carries the reason setup failed. Its ABSENCE proves nothing,
# though, and that asymmetry is the whole reason this dump exists: the branch is
# `mv -f config.json config.json.failed 2>/dev/null || rm -f config.json`, so a failed mv
# discards its own stderr and DELETES the file outright, leaving no artifact at all. Read a
# missing config.json.failed as "no evidence either way", never as an alibi. A
# `config.json.tmp` would instead name the credential write-back's atomic sibling.
backup_failure_evidence() {
    printf '     --- guest evidence (#1059) ---\n'
    _ssh "echo '-- backup log --'; cat /tmp/restore-backup.log 2>/dev/null
          echo '-- /data/pithead tree --'; ls -la /data/pithead/ 2>&1
          echo '-- config.json now --'; ls -la /data/pithead/config.json 2>&1; readlink -f /data/pithead/config.json 2>&1
          echo '-- provisioning still in flight? --'
          systemctl is-active pithead-firstboot.service pithead-boot.service 2>&1
          echo '-- wizard spool (the reason setup failed, if it did) --'
          cat /data/pithead/data/firstboot/error.txt 2>/dev/null; echo
          cat /data/pithead/data/firstboot/last-attempt.json 2>/dev/null | head -c 400; echo
          echo '-- firstboot journal --'; journalctl -u pithead-firstboot --no-pager -n 30 2>/dev/null" |
        tr -d '\r' | sed 's/^/     | /'
    backup_watch_report
}

# The #1059 watcher. It caught the mechanism on its first instrumented run, and stays as the
# canary for it: `setup` is still inside `stack_up`'s `compose up -d` when a concurrent
# `pithead backup` calls `stack_down`, which deletes a container out from under that in-flight
# `compose up`; it fails, `stack_up` calls error(), the `(setup)` subshell exits non-zero, and
# the firstboot wizard loop moves config.json aside (pithead:2746 -> :2752). Whether tar then
# reports `Cannot stat` is pure timing.
#
# It reports on PASSING runs too, and that is the load-bearing part rather than a nicety: the run
# that produced the capture above was one where the BACKUP SUCCEEDED and the config was moved
# aside anyway. A failure-only instrument would have printed a green tick. It follows that older
# greens on this leg are not evidence the vanish did not happen — nothing was looking.
#
# The appliance image ships no inotify-tools, no auditd and no lsof (os/rootfs/Dockerfile), so
# this is a poll plus a /proc sweep, read within ~100ms of the file going away while whatever did
# it is still likely to be alive. Deliberately names ANY actor, not just this repo's code: the
# first two static passes over the backup's own call chain found nothing, because the actor is a
# concurrent process rather than anything that call chain invokes.
backup_precapture() {
    _ssh "ls -la /data/pithead/config.json /data/pithead/.env 2>&1; readlink -f /data/pithead/config.json 2>&1" |
        tr -d '\r' | sed 's/^/     · /'
    _ssh 'cat >/tmp/pithead-1059-watch.sh <<"EOS"
# Paths and ceiling come from the environment so the self-test can drive this exact body
# unmodified. The heredoc is quoted, so these expand on the GUEST at run time, where nothing sets
# them and the defaults are what runs. A test that had to sed the constants would be proving a
# respelled copy rather than the script the battery ships.
f=${PITHEAD_1059_WATCH_FILE:-/data/pithead/config.json}
out=${PITHEAD_1059_WATCH_LOG:-/tmp/pithead-1059-watch.log}
: >"$out"
# Written before any polling, so an EMPTY log means the watcher never ran. That is a different
# fact from "nothing vanished" and must never be reported as one.
echo "STARTED at $(date -Is) pid=$$" >>"$out"
watch_seconds=${PITHEAD_1059_WATCH_SECONDS:-1800}
end=$((SECONDS + watch_seconds))
while [ $SECONDS -lt $end ]; do
    if [ ! -e "$f" ]; then
        {
            echo "VANISHED at $(date -Is)"
            ls -la /data/pithead/ 2>&1
            echo "-- the wizard loop, which is the only reachable remover --"
            systemctl is-active pithead-firstboot.service 2>&1
            journalctl -u pithead-firstboot --no-pager -n 20 2>/dev/null
            echo "-- process table at that instant --"
            for p in /proc/[0-9]*; do
                [ -r "$p/cmdline" ] || continue
                c=$(tr "\0" " " <"$p/cmdline")
                [ -n "$c" ] || continue # kernel threads carry no cmdline and no suspicion
                printf "%s\t%s\n" "${p#/proc/}" "$c"
            done
        } >>"$out" 2>&1
        for _ in $(seq 300); do
            [ -e "$f" ] && { echo "REAPPEARED at $(date -Is)" >>"$out"; break; }
            sleep 0.1
        done
        exit 0
    fi
    sleep 0.1
done
# The ceiling reached with the file still there. The backup outlasted the watcher, so only part
# of the window was watched — say so, rather than let a quiet log read as a clean pass.
echo "WINDOW EXPIRED at $(date -Is): the ${watch_seconds}s watch ceiling was reached with the file still present" >>"$out"
EOS
setsid nohup bash /tmp/pithead-1059-watch.sh </dev/null >/dev/null 2>&1 & disown' >/dev/null 2>&1 || true
    # Confirm it took. The launch is detached, so its exit status says nothing about whether the
    # watcher is running, and the line above discards output on purpose. A watcher that never
    # started is the likeliest way this instrument ends up naming nothing while nothing was
    # watching, so it is named HERE — at the start of the window, when there is still time to
    # read it as a warning rather than as a result.
    case "$(_ssh "pgrep -f '[p]ithead-1059-watch.sh' >/dev/null 2>&1 && printf UP" | tr -d '\r')" in
    *UP*) ;;
    *) printf '     --- #1059: WATCHER DID NOT START — this run will collect no evidence either way ---\n' ;;
    esac
}

# Report whatever the watcher saw, and stop it. Quiet when the file never went away, so a healthy
# run stays quiet; loud the moment it blinks, pass or fail.
#
# The one thing it must NOT do is stay quiet because it could not look. Silence has to mean one
# thing only, and there are FIVE ways to end up with nothing to name against one way of having
# genuinely seen nothing:
#
#   the guest could not be read        -> no sentinel comes back
#   the watcher never started          -> readable, but the log is empty
#   the watcher was killed mid-window  -> it started, and it is no longer running
#   the watch ceiling was reached      -> it started, and it timed out with the file still there
#   the file went away                 -> the event, reported loudly
#   it watched the whole window        -> the only case that is allowed to be quiet
#
# Reading any of the first four as the last is how a run gets recorded as evidence when it
# collected none — the exact defect this file exists to prevent, one level up. So the fetch
# carries two sentinels: WATCHOK proves the guest answered, ALIVE proves the watcher was still
# running when it was asked, and the log's own STARTED / WINDOW EXPIRED lines carry the rest.
# Each outcome gets a sentence only it writes, so no two can be confused for one another.
backup_watch_report() {
    local raw seen alive=0
    # One round trip for all three facts. The ':' terminates the sentinels — the log's first
    # character is arbitrary, so the boundary has to be explicit rather than positional.
    raw=$(_ssh "printf WATCHOK; pgrep -f '[p]ithead-1059-watch.sh' >/dev/null 2>&1 && printf ALIVE; printf ':'; cat /tmp/pithead-1059-watch.log 2>/dev/null" | tr -d '\r')
    # Bracketed: the remote `bash -c` running this pkill carries the pattern in its OWN cmdline,
    # so an unbracketed one matches the shell issuing it.
    _ssh "pkill -f '[p]ithead-1059-watch.sh'" >/dev/null 2>&1 || true
    case "$raw" in
    WATCHOK*) raw=${raw#WATCHOK} ;;
    *)
        printf '     --- #1059: WATCHER UNREADABLE — this run collected no evidence either way ---\n'
        return 0
        ;;
    esac
    case "$raw" in ALIVE*)
        alive=1
        raw=${raw#ALIVE}
        ;;
    esac
    seen=${raw#:}
    # The event first: on a vanish the watcher exits by design, so it is legitimately not ALIVE
    # here and must not be read as having died.
    case "$seen" in
    *"VANISHED at "*)
        printf '     --- #1059: config.json went away during the backup ---\n'
        printf '%s\n' "$seen" | sed 's/^/     | /'
        return 0
        ;;
    esac
    case "$seen" in
    *"WINDOW EXPIRED at "*)
        printf '     --- #1059: WATCH WINDOW EXPIRED before the backup finished — this run collected no evidence either way ---\n'
        return 0
        ;;
    esac
    case "$seen" in
    *"STARTED at "*) ;;
    *)
        printf '     --- #1059: WATCHER NEVER STARTED — this run collected no evidence either way ---\n'
        return 0
        ;;
    esac
    if [ "$alive" -ne 1 ]; then
        printf '     --- #1059: WATCHER DIED mid-window — this run collected no evidence either way ---\n'
        return 0
    fi
    # Started, still running, nothing recorded: the only case that has actually watched the whole
    # window and seen the file stay put. Quiet, so a healthy battery stays readable.
    return 0
}

# --- self-test (#1059) -----------------------------------------------------------------------
#
# Driven by `tests/os/failure-evidence.sh --self-test`, tier 1, no KVM guest and no transport:
# `_ssh` is stubbed with a canned reply, which is the whole input this logic has.
#
# What it is here to prove is DISCRIMINATION, not that the code runs. The instrument's product is
# that its silence means exactly one thing, and five of the six outcomes above are "no evidence"
# rather than "nothing happened". If any two of them printed the same sentence, a run that watched
# nothing would read as a run that watched cleanly — the defect the instrument exists to detect,
# reappearing inside the instrument.
#
# So every case is asserted twice over: the sentence only that outcome writes must be PRESENT, and
# every other outcome's sentence must be ABSENT. Asserting on the shared
# "collected no evidence either way" tail would pass for any of the four, which is how one guard
# silently covers for another's deletion. Delete any branch below and its case goes red rather
# than falling through to the quiet path.
_fe_selftest_reply=""
_fe_selftest_rc=0

# Every outcome's unique sentence. The keys are the assertion vocabulary: a case names the one it
# wants and is checked against all the others.
_FE_SENTENCES="WATCHER UNREADABLE
WATCHER NEVER STARTED
WATCHER DIED mid-window
WATCH WINDOW EXPIRED
config.json went away during the backup"

_fe_case() { # <label> <want-sentence|QUIET> <canned _ssh reply>
    local label="$1" want="$2" got line headers
    _fe_selftest_reply="$3"
    got=$(backup_watch_report)
    if [ "$want" = "QUIET" ]; then
        if [ -n "$got" ]; then
            printf 'FAIL: %s — a fully-watched clean window must print nothing, got: %s\n' "$label" "$got"
            _fe_selftest_rc=1
            return
        fi
        printf 'ok: %s (silent)\n' "$label"
        return
    fi
    case "$got" in
    *"$want"*) ;;
    *)
        printf 'FAIL: %s — expected "%s", got: %s\n' "$label" "$want" "${got:-<silence>}"
        _fe_selftest_rc=1
        return
        ;;
    esac
    # ...and none of the others, so this case cannot be satisfied by a neighbouring branch.
    #
    # Compared against the HEADER lines only. The vanish branch prints its captured evidence
    # below its header, and that evidence is a process table — arbitrary text, which can contain
    # anything including this file's own vocabulary. It does: a leftover log-follower from an
    # earlier session was running with "WATCHER UNREADABLE" inside its grep pattern, the sweep
    # captured its cmdline, and a whole-output match called that a second outcome. The header is
    # what NAMES the outcome, so the header is what has to be unambiguous.
    headers=$(printf '%s\n' "$got" | grep -- '--- #1059:' || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [ "$line" = "$want" ] && continue
        case "$headers" in
        *"$line"*)
            printf 'FAIL: %s — its header also names another outcome, "%s": %s\n' "$label" "$line" "$headers"
            _fe_selftest_rc=1
            ;;
        esac
    done <<<"$_FE_SENTENCES"
    printf 'ok: %s\n' "$label"
}

# The other half of the contract. Everything above drives the REPORT against a canned reply; it
# cannot tell whether the watcher actually writes the lines the report keys on. A mismatch there
# (the watcher writing "STARTED:" while the report looks for "STARTED at ") would leave every
# clean run reporting NEVER STARTED, and no amount of report-side testing would show it.
#
# So this runs the watcher body EXACTLY as backup_precapture ships it — extracted from the
# heredoc, not retyped — against a sandbox file, and then feeds its real output back through
# backup_watch_report. The two halves are proven against each other rather than each against my
# idea of the other.
_fe_watcher_body() {
    awk '/cat >\/tmp\/pithead-1059-watch.sh <<"EOS"/{flag = 1; next} flag && /^EOS$/{exit} flag' "${BASH_SOURCE[0]}"
}

_fe_watcher_cases() {
    local sandbox body target log out wpid i
    sandbox=$(mktemp -d)
    body="$sandbox/watch.sh"
    _fe_watcher_body >"$body"
    if [ ! -s "$body" ]; then
        printf 'FAIL: could not extract the watcher body from the heredoc\n'
        _fe_selftest_rc=1
        rm -rf "$sandbox"
        return
    fi
    # A watcher that does not parse never starts, and the run collects nothing. Cheap to check
    # here; on the guest it would only show up as a silent absence.
    if ! bash -n "$body" 2>"$sandbox/syntax"; then
        printf 'FAIL: the shipped watcher body does not parse: %s\n' "$(cat "$sandbox/syntax")"
        _fe_selftest_rc=1
        rm -rf "$sandbox"
        return
    fi
    printf 'ok: the shipped watcher body parses\n'

    # --- the file goes away and comes back ---
    target="$sandbox/config.json"
    log="$sandbox/vanish.log"
    : >"$target"
    PITHEAD_1059_WATCH_FILE="$target" PITHEAD_1059_WATCH_LOG="$log" \
        PITHEAD_1059_WATCH_SECONDS=30 bash "$body" &
    wpid=$!
    i=0
    while [ ! -s "$log" ] && [ "$i" -lt 200 ]; do
        sleep 0.05
        i=$((i + 1))
    done
    rm -f "$target"
    sleep 1 # the poll is 0.1s, so this is detection with margin, not a race
    : >"$target"
    wait "$wpid" 2>/dev/null || true
    out=$(cat "$log" 2>/dev/null)
    case "$(printf '%s' "$out" | head -1)" in
    "STARTED at "*) printf 'ok: the watcher announces STARTED before it polls\n' ;;
    *)
        printf 'FAIL: the watcher log does not open with STARTED: %s\n' "$(printf '%s' "$out" | head -1)"
        _fe_selftest_rc=1
        ;;
    esac
    case "$out" in
    *"VANISHED at "*) printf 'ok: the watcher records a real disappearance\n' ;;
    *)
        printf 'FAIL: the watcher missed a file that actually went away\n'
        _fe_selftest_rc=1
        ;;
    esac
    # The contract, closed: the watcher's OWN output, through the real report.
    _fe_case "a real vanish log reports as a vanish" "config.json went away during the backup" "WATCHOK:$out"

    # --- the ceiling is reached with the file still there ---
    log="$sandbox/expired.log"
    PITHEAD_1059_WATCH_FILE="$target" PITHEAD_1059_WATCH_LOG="$log" \
        PITHEAD_1059_WATCH_SECONDS=1 bash "$body"
    out=$(cat "$log" 2>/dev/null)
    case "$out" in
    *"WINDOW EXPIRED at "*) printf 'ok: the watcher records its own expiry\n' ;;
    *)
        printf 'FAIL: the watcher expired without saying so: %s\n' "${out:-<empty>}"
        _fe_selftest_rc=1
        ;;
    esac
    case "$out" in
    *"VANISHED at "*)
        printf 'FAIL: the watcher reported a vanish for a file that stayed put\n'
        _fe_selftest_rc=1
        ;;
    *) printf 'ok: a file that stayed put produces no vanish\n' ;;
    esac
    _fe_case "a real expired log reports as an expired window" "WATCH WINDOW EXPIRED" "WATCHOK:$out"

    rm -rf "$sandbox"
}

_fe_self_test() {
    # The stub transport. backup_watch_report calls _ssh twice — the fetch and the pkill — and
    # discards the second's output, so one canned reply serves both.
    _ssh() { printf '%s' "$_fe_selftest_reply"; }

    printf '== unit: #1059 watch-report discrimination ==\n'
    # No sentinel at all: ssh failed, the guest is gone, the command died. Nothing is known.
    _fe_case "guest unreadable is not a clean run" "WATCHER UNREADABLE" ""
    # The guest answered and the log is empty: the launch never took.
    _fe_case "a watcher that never started is not a clean run" "WATCHER NEVER STARTED" "WATCHOK:"
    # It started, and it is not running now, with nothing recorded: it was killed mid-window.
    _fe_case "a watcher killed mid-window is not a clean run" "WATCHER DIED mid-window" \
        "WATCHOK:STARTED at 2026-08-24T01:00:00+00:00 pid=1234"
    # It started and timed out with the file still present: the backup outlasted the watch.
    _fe_case "an expired watch window is not a clean run" "WATCH WINDOW EXPIRED" \
        "WATCHOK:STARTED at 2026-08-24T01:00:00+00:00 pid=1234
WINDOW EXPIRED at 2026-08-24T01:30:00+00:00: the 1800s watch ceiling was reached with config.json still present"
    # The event. The watcher exits by design after recording it, so it is legitimately not ALIVE
    # here — this case is what proves that is not misread as a death.
    _fe_case "a vanish is reported even though the watcher has exited" \
        "config.json went away during the backup" \
        "WATCHOK:STARTED at 2026-08-24T01:00:00+00:00 pid=1234
VANISHED at 2026-08-24T01:25:57+00:00
config.json.failed"
    # ...and the same, with the watcher still in its reappear wait.
    _fe_case "a vanish is reported while the watcher is still alive" \
        "config.json went away during the backup" \
        "WATCHOKALIVE:STARTED at 2026-08-24T01:00:00+00:00 pid=1234
VANISHED at 2026-08-24T01:25:57+00:00"
    # The ONLY quiet case: started, still watching, nothing seen.
    _fe_case "a fully-watched window with no vanish stays quiet" "QUIET" \
        "WATCHOKALIVE:STARTED at 2026-08-24T01:00:00+00:00 pid=1234"

    printf '== unit: #1059 watcher body, run for real against a sandbox file ==\n'
    _fe_watcher_cases

    if [ "$_fe_selftest_rc" -ne 0 ]; then
        printf '#1059 watch-report self-test FAILED\n'
        return 1
    fi
    printf '#1059 watch-report self-test passed\n'
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = "--self-test" ]; then
    _fe_self_test
    exit $?
fi
