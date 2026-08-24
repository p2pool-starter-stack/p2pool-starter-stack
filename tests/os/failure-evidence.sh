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

# The #1059 watcher. Two static passes over this repo — a 12-candidate adversarial fan-out and a
# hand trace of every path that removes config.json — agree that NOTHING in the backup's own call
# chain touches the file: compose never mounts it, remove_tor_egress_firewall only edits nftables,
# and the one remover reachable on an installed machine is the firstboot wizard loop's
# `mv config.json config.json.failed`. That branch is NOT ruled out: it is gated on the exit
# status of `(setup)` (pithead:2746), and under `set -Eeuo pipefail` any failing command,
# unbound variable or ERR trap exits that subshell — calling error() is one route to a non-zero
# status, not the gate. So the actor may be in this tree or outside it, and an instrument that
# can only name this repo's code would miss half the possibilities by construction.
#
# Hence a watcher that names ANY actor. The appliance image ships no inotify-tools, no auditd and
# no lsof (os/rootfs/Dockerfile), so this is a poll plus a /proc sweep — the process table read
# within ~100ms of the file going away, while whatever did it is still likely to be alive. It
# also survives the case that has bitten this issue twice: a run where the backup SUCCEEDS but
# the file still blinked, which every previous capture would have recorded as an uneventful pass.
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

# Report whatever the watcher saw, and stop it. Silent when the file never went away, so a healthy
# run stays quiet; loud the moment it blinks, pass or fail.
backup_watch_report() {
    local seen
    seen=$(_ssh "cat /tmp/pithead-1059-watch.log 2>/dev/null" | tr -d '\r')
    _ssh "pkill -f pithead-1059-watch.sh" >/dev/null 2>&1 || true
    [ -n "$seen" ] || return 0
    printf '     --- #1059: config.json went away during the backup ---\n'
    printf '%s\n' "$seen" | sed 's/^/     | /'
}
