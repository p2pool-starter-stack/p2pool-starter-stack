# shellcheck shell=bash
#
# Shared by tests/os/run.sh's phase_boot (drives it against a real KVM guest's systemd + /proc
# state) and tests/stack/run.sh's fixture unit test (drives it against canned strings): the
# boot-phase hugepages verdict, #1212. HugePages_Total alone cannot tell "the sizing unit ran
# and correctly left the full pool alone" from "the unit never ran at all" — the rootfs bakes
# vm.nr_hugepages=3072 into /etc/sysctl.d/ regardless, so a pool-only check reads identically
# either way. Pairing it with the unit's own record — `systemctl is-active`, "active" only once
# the RemainAfterExit=yes oneshot has actually run and returned 0 — makes the two cases tell
# apart. A bare-boot guest cannot honestly assert more than that: unlike phase_provision (which
# reboots a machine that already has a live marker file to compare before/after), this is the
# image's very first boot, so there is no "before" state and no reason to expect a degraded
# marker on a 16 GiB guest beyond what the page count already shows.

# $1 = HugePages_Total from /proc/meminfo (may be empty/unreadable)
# $2 = `systemctl is-active pithead-hugepages.service` output, trimmed (e.g. "active", "inactive")
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
hugepages_boot_verdict() {
    local hp="$1" active="$2"
    if [ "$active" != "active" ]; then
        echo "hugepages sizing unit did not run this boot (is-active: ${active:-unreadable}) — a full pool alone cannot prove the no-op (#1212)"
        return 1
    fi
    case "$hp" in '' | *[!0-9]*)
        echo "hugepage pool unreadable at boot (HugePages_Total: ${hp:-unreadable}, want >= 3072)"
        return 1
        ;;
    esac
    if [ "$hp" -lt 3072 ]; then
        echo "hugepages sizing unit ran but the pool is short (HugePages_Total: $hp, want >= 3072)"
        return 1
    fi
    echo "hugepages sizing unit ran this boot and left the full pool intact ($hp pages)"
    return 0
}
