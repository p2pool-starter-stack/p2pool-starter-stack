# shellcheck shell=bash
#
# Shared by tests/os/run.sh's phase_boot (across the real KVM guest's #895 reboot) and
# tests/stack's fixture test: the second-boot journal verdict, #1659. journald reads the
# machine-id once, at its own start — the transient one PID 1 binds on an empty-baked image — and
# before the fix kept writing under it all boot, so every boot after the first opened a new
# persistent journal directory and `journalctl -b`, which resolves the directory by the RESTORED
# id, read a stale one. The first boot cannot show this (the adopted id IS the transient one); the
# reboot the #895 check already makes is the first boot that can, which is why the verdict rides it.

# $1 = journal directories under /var/log/journal before the reboot
# $2 = the same count after it
# $3 = lines `journalctl -b -u pithead-machine-id` prints after it (0 = the unit's own record
#      landed under another id and a plain -b cannot see it)
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
journal_boot_verdict() {
    local before="$1" after="$2" lines="$3" v
    for v in "$before" "$after" "$lines"; do
        case "$v" in '' | *[!0-9]*)
            echo "journal state unreadable across the reboot (dirs before: ${before:-?}, after: ${after:-?}, -b lines: ${lines:-?})"
            return 1
            ;;
        esac
    done
    if [ "$after" -gt "$before" ]; then
        echo "journald opened a new journal directory on the second boot ($before -> $after): it kept the transient machine-id (#1659)"
        return 1
    fi
    if [ "$lines" -eq 0 ]; then
        echo "journalctl -b shows nothing from pithead-machine-id on the second boot — this boot's journal is under another id (#1659)"
        return 1
    fi
    echo "journald follows the restored machine-id across a reboot (journal directories: $after, -b sees this boot's unit record)"
    return 0
}
