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

# The pool's SECOND writer (#1724). xmrig runs as root and, before every large-page allocation,
# grows nr_hugepages through sysfs when free pages fall short — so the ceiling the miner render
# declares (PITHEAD_HUGEPAGES_POOL_CEILING_MB, 9216 MB = 4608 pages of 2 MiB) bounds the sizer's
# write and nothing else. The image ships a drop-in that makes both subtrees read-only to the
# miner unit. THREE readings, because no one of them is enough on its own: the pool alone cannot
# say WHY it is at 4608 (the sizer may legitimately land there), the drop-in alone proves what
# was shipped and not what systemd loaded, and the 1 GiB pool is the write the sizer never makes
# at all — non-zero there can only be the miner, whatever the 2 MiB count reads.
#
# ARMING — read this before quoting a clean verdict from this function. xmrig only writes the pool
# when it actually ALLOCATES, and on a guest the product's own sync gate (#35) holds the stratum,
# so the miner may never get a job and never attempt a write. A passing verdict then says the unit
# is fenced, which is true and checkable from the unit's loaded settings, but says NOTHING about a
# write having been refused: it is the fence UNEXERCISED, not the fence proven. The success line
# below is the strongest claim in this area and goes straight into the battery log, so the
# qualification belongs here, next to it, and not only in the strategy table.
HUGEPAGES_CEILING_PAGES=4608

# $1 = HugePages_Total from /proc/meminfo   $2 = `systemctl show xmrig -p ReadOnlyPaths --value`
# $3 = /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ("" when the kernel reserves no
#      1 GiB pool at all — the appliance's cmdline carries no hugepagesz, so "" is the normal read)
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
hugepages_miner_verdict() {
    local hp="$1" ro="$2" onegb="$3"
    case "$ro" in
    *"/sys/devices/system/node"*) case "$ro" in
        *"/sys/kernel/mm/hugepages"*) ;;
        *)
            echo "the miner unit can still write the global hugepage pool (ReadOnlyPaths: ${ro:-unset}) — #1724"
            return 1
            ;;
        esac ;;
    *)
        echo "the miner unit can still write the per-node hugepage pools (ReadOnlyPaths: ${ro:-unset}) — #1724"
        return 1
        ;;
    esac
    case "$hp" in '' | *[!0-9]*)
        echo "hugepage pool unreadable with the miner up (HugePages_Total: ${hp:-unreadable})"
        return 1
        ;;
    esac
    if [ "$hp" -gt "$HUGEPAGES_CEILING_PAGES" ]; then
        echo "the hugepage pool grew past the ceiling with the miner up ($hp pages, ceiling $HUGEPAGES_CEILING_PAGES) — #1724"
        return 1
    fi
    case "$onegb" in
    '' | 0) ;;
    *)
        echo "a 1 GiB hugepage pool was reserved ($onegb pages) — only the miner writes that one; the fence did not hold (#1724)"
        return 1
        ;;
    esac
    echo "the miner unit is fenced off both hugepage subtrees and the pool held ($hp pages, ceiling $HUGEPAGES_CEILING_PAGES, 1 GiB pool ${onegb:-none})"
    return 0
}
