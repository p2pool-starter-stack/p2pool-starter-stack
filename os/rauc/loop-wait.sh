# shellcheck shell=bash
#
# Shared by mkimage.sh (builds a slot image) and tests/os/verify-image.sh (checks one): the wait
# for a loop device's partition nodes to exist. `losetup -P` returns before the kernel/udev
# publish them, and the gap widens under loop-device churn (a KVM battery running beside a release
# build) — without the wait, the first mkfs/mount fails with "No such device or address" and a
# plain retry succeeds, which is exactly how it stays invisible until release day. This started as
# two copies of the same nine lines and drifted in wording; the callers keep their own error
# message (mkimage.sh's build failure reads differently from verify-image.sh's "broken image"
# verdict), only the polling loop is shared.

# $1 = loop device (e.g. /dev/loop0), $2.. = partition suffixes to wait for (e.g. p1 p2).
# Returns 0 once every "${loop}${suffix}" is a block device, 1 if none ever showed up.
wait_loop_partitions() {
    local loop="$1"
    shift
    udevadm settle 2>/dev/null || true
    local part all_present
    for _ in {1..25}; do
        all_present=1
        for part in "$@"; do
            [ -b "${loop}${part}" ] || all_present=0
        done
        [ "$all_present" -eq 1 ] && return 0
        sleep 0.2
    done
    for part in "$@"; do
        [ -b "${loop}${part}" ] || return 1
    done
    return 0
}
