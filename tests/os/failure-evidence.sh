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
