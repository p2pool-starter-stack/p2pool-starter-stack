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
f=/data/pithead/config.json
out=/tmp/pithead-1059-watch.log
: >"$out"
end=$((SECONDS + 1800))
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
EOS
setsid nohup bash /tmp/pithead-1059-watch.sh </dev/null >/dev/null 2>&1 & disown' >/dev/null 2>&1 || true
}

# Report whatever the watcher saw, and stop it. Quiet when the file never went away, so a healthy
# run stays quiet; loud the moment it blinks, pass or fail.
#
# The one thing it must NOT do is stay quiet because it could not look. A silent "no vanish" and a
# silent "the guest never answered" are the same output and opposite meanings, and reading the
# second as the first is how a run gets recorded as evidence when it collected none. So the log is
# fetched with a sentinel: no sentinel back means the watcher could not be read, and that is said
# out loud rather than passed off as a clean result.
backup_watch_report() {
    local raw seen
    raw=$(_ssh "printf WATCHOK; cat /tmp/pithead-1059-watch.log 2>/dev/null" | tr -d '\r')
    # Bracketed: the remote `bash -c` running this pkill carries the pattern in its OWN cmdline,
    # so an unbracketed one matches the shell issuing it.
    _ssh "pkill -f '[p]ithead-1059-watch.sh'" >/dev/null 2>&1 || true
    case "$raw" in
    WATCHOK*) seen=${raw#WATCHOK} ;;
    *)
        printf '     --- #1059: WATCHER UNREADABLE — this run collected no evidence either way ---\n'
        return 0
        ;;
    esac
    [ -n "$seen" ] || return 0
    printf '     --- #1059: config.json went away during the backup ---\n'
    printf '%s\n' "$seen" | sed 's/^/     | /'
}
