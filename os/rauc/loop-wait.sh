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

# $1 = loop device (e.g. /dev/loop0). Waits for its p1+p2 nodes — the appliance image is
# exactly ESP + slot A, so both callers want exactly this pair. Returns 0 once both are block
# devices, 1 if they never showed up.
wait_loop_partitions() {
    udevadm settle 2>/dev/null || true
    for _ in {1..25}; do
        [ -b "${1}p1" ] && [ -b "${1}p2" ] && return 0
        sleep 0.2
    done
    [ -b "${1}p1" ] && [ -b "${1}p2" ]
}
