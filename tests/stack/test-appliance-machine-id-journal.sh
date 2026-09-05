# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# pithead-machine-id's journald hand-off (#1659). Sourced by tests/stack/run.sh.
#
# SCOPE. test-appliance-identity-boot.sh proves the RESTORE — the persisted id lands in
# /etc/machine-id, an empty /data adopts this boot's id, nothing-anywhere refuses — and sits at its
# ceiling. Asserted here is the one decision that file does not cover: whether the script restarts
# journald, which must happen EXACTLY when PID 1 bound a transient id (a mountpoint at
# /etc/machine-id) AND the restored id differs from it. journald reads the id once at its own
# start: on a first boot the adopted id is that id, so a restart would cost early-boot log
# continuity for nothing, and off the appliance there is no transient id to move off. The
# restart's EFFECT — journald writing under the restored id — is the KVM battery's
# (journal_boot_verdict on the #895 reboot); the verdict function itself is fixture-tested below.
#
# mountpoint, findmnt, mount and systemctl are PATH-stubbed: the suite is not root and mounts
# nothing. systemctl records its argv so the assertion is on the CALL, and a failing stub proves
# the failure policy (warn on stderr, keep the id, exit 0).

echo "== unit: pithead-machine-id — journald restarted exactly when the restored id differs from the boot-time one (#1659) =="
MJ="$SANDBOX/machine-id-journal"
mkdir -p "$MJ/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$MJ/bin/mountpoint"    # PID 1 bound a transient id
printf '#!/usr/bin/env bash\necho overlay\n' >"$MJ/bin/findmnt" # the /etc overlay is already up
printf '#!/usr/bin/env bash\nexit 0\n' >"$MJ/bin/mount"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$MJ_LOG"\nexit "${MJ_RC:-0}"\n' >"$MJ/bin/systemctl"
chmod +x "$MJ/bin/"*
mj_run() { # $1 = persisted id ('' = none on /data), $2 = the id this boot already has
    : >"$MJ/systemctl.log"
    rm -f "$MJ/data-id"
    [ -n "$1" ] && printf '%s\n' "$1" >"$MJ/data-id"
    printf '%s\n' "$2" >"$MJ/etc-id"
    (
        export PATH="$MJ/bin:$PATH" PITHEAD_MACHINE_ID_FILE="$MJ/data-id" PITHEAD_MACHINE_ID_ETC="$MJ/etc-id"
        export MJ_LOG="$MJ/systemctl.log" MJ_RC="${MJ_RC:-0}"
        sh "$ROOT/os/overlay/pithead-machine-id" 2>&1
    )
}
out=$(mj_run fa85bfc69f0b451d95bbacf897e431ce ffffffffffffffffffffffffffffffff)
assert_rc "restore onto a different transient id exits 0" "$?" "0"
assert_eq "…and restarts journald exactly once" "$(cat "$MJ/systemctl.log")" "restart systemd-journald.service"
assert_contains "…and says so" "$out" "journald restarted"
assert_eq "…and the restored id landed" "$(cat "$MJ/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"
out=$(mj_run "" abc0000000000000000000000000def0)
assert_rc "adopt (first boot) exits 0" "$?" "0"
assert_eq "adopt does NOT restart journald — the adopted id is the one it started on" "$(cat "$MJ/systemctl.log")" ""
out=$(mj_run fa85bfc69f0b451d95bbacf897e431ce fa85bfc69f0b451d95bbacf897e431ce)
assert_eq "a persisted id equal to the boot-time one does NOT restart journald" "$(cat "$MJ/systemctl.log")" ""
# Off the appliance (no transient bind) nothing is restarted even when the ids differ.
printf '#!/usr/bin/env bash\nexit 1\n' >"$MJ/bin/mountpoint"
out=$(mj_run fa85bfc69f0b451d95bbacf897e431ce ffffffffffffffffffffffffffffffff)
assert_eq "no transient bind: no restart, ids differing or not" "$(cat "$MJ/systemctl.log")" ""
assert_eq "…and the restore itself still lands" "$(cat "$MJ/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"
printf '#!/usr/bin/env bash\nexit 0\n' >"$MJ/bin/mountpoint"
# Failure policy: a journald that will not restart is warned about, never fatal.
out=$(MJ_RC=1 mj_run fa85bfc69f0b451d95bbacf897e431ce ffffffffffffffffffffffffffffffff)
assert_rc "a failed journald restart is not fatal" "$?" "0"
assert_contains "…and is named on stderr" "$out" "journald restart failed"
assert_eq "…and the restored id still landed" "$(cat "$MJ/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"

echo "== unit: journal_boot_verdict — the second-boot journal discrimination (#1659) =="
jbv() { (source "$ROOT/tests/os/journal-boot-verdict.sh" && journal_boot_verdict "$@"); }
out=$(jbv 1 1 3)
assert_rc "one directory before and after, -b sees the unit: pass" "$?" "0"
out=$(jbv 1 2 3)
assert_rc "a second directory appeared: fail" "$?" "1"
assert_contains "…naming the transient id" "$out" "transient machine-id"
out=$(jbv 1 1 0)
assert_rc "-b blind to the unit's record: fail even with one directory" "$?" "1"
out=$(jbv "" 1 3)
assert_rc "unreadable before-count: fail, never a vacuous pass" "$?" "1"
out=$(jbv 1 x 3)
assert_rc "garbage after-count: fail" "$?" "1"

echo "== unit: journal_home_verdict — one persistent home for the journal across the reboot (#1791) =="
jhv() { (source "$ROOT/tests/os/journal-boot-verdict.sh" && journal_home_verdict "$@"); }
out=$(jhv $'/var/log/journal 1310722\n1310722\next2/ext3\nyes\n2')
assert_rc "the bind tops /var/log/journal, journald flushed under it, two boots listed: pass" "$?" "0"
out=$(jhv $'/var 4\n1310722\noverlayfs\nno\n4')
assert_rc "the /var overlay tops it (the kept guest's own reading): fail" "$?" "1"
assert_contains "…naming the overlay" "$out" "overlay covered it"
out=$(jhv $'/var/log/journal 1310722\n1310722\next2/ext3\nno\n2')
assert_rc "the bind is up but journald flushed nothing under it: fail" "$?" "1"
out=$(jhv $'/var/log/journal 1310722\n1310722\next2/ext3\nyes\n1')
assert_rc "one boot listed after a reboot: fail" "$?" "1"
assert_contains "…naming the split" "$out" "other home"
out=$(jhv "")
assert_rc "unreadable probe: fail, never a vacuous pass" "$?" "1"
out=$(jhv $'/var/log/journal 1310722\nmissing\next2/ext3\nyes\n2')
assert_rc "the /data directory missing: fail" "$?" "1"
out=$(jhv $'/var/log/journal 999\n1310722\next2/ext3\nyes\n2')
assert_rc "something else is bound at /var/log/journal (the two inodes differ): fail" "$?" "1"
# The probe and the verdict agree on field ORDER: run the real probe on this host (no appliance
# /data here, so it must fail) and check the failure names the fields it read, not garbage.
out=$(jhv "$(bash -c "$(source "$ROOT/tests/os/journal-boot-verdict.sh" && printf '%s' "$JOURNAL_HOME_PROBE")" 2>/dev/null)")
assert_rc "the probe's own output on a non-appliance host: fail" "$?" "1"
assert_contains "…as unreadable, with the missing /data inode in the right field" "$out" "/missing"
