# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# RAUC loop-partition wait domain (#1105 Phase 1, develop-v2 lane): the one section covering
# os/rauc/loop-wait.sh's wait_loop_partitions. It proves the negative half of that contract, which
# is all a non-root tier honestly can: partition nodes that never appear exhaust the poll and
# return 1, and regular files sitting at the p1/p2 paths do NOT satisfy the wait — block devices
# are required. sleep and udevadm are function-stubbed inside a subshell, so the full 25-try budget
# runs instantly and the sleep count is itself asserted, which is what distinguishes a real poll
# from a single-shot check. The positive half (real nodes appearing) runs for real on every image
# build — mkimage.sh and verify-image.sh both call this.
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# NAMED FOR WHAT IT TESTS, deliberately. The cut map filed this section under a "boot-provisioning"
# heading; there is no such domain, and the neighbouring test-appliance-boot.sh covers something
# else. This file is small — smaller than any other domain file in the suite — and that is
# preferred here over the alternative, which was to fold it into test-appliance-defaults.sh: the
# two blocks are separated by NINE domain source stanzas, so folding them would have reordered
# this section ahead of all nine. A zero-reorder cut is worth more than a round file count.
#
# Re-derivations. $ROOT and $SANDBOX come from lib.sh, both assigned at COLUMN 1 at top level,
# outside every function body — so neither is the ordering dependency the $WALLET case turned out
# to be. (Re-derive by reading the indent in lib.sh, not by line number.) $LW is assigned here, as is the lw_run helper; the udevadm and sleep stubs and
# wait_loop_partitions itself live inside lw_run's subshell, sourced from
# $ROOT/os/rauc/loop-wait.sh per call rather than relying on an ambient one. Provider functions
# called: assert_rc, assert_eq. Every write lands under $LW ($SANDBOX/loop-wait), and a sweep of
# all of tests/stack/ finds that path named ONLY in this block.

: "${ROOT:?}" "${SANDBOX:?}"

echo "== unit: os/rauc/loop-wait.sh — the partition wait demands block devices and polls its budget =="
# The negative half of the contract — all a non-root tier can prove: absent nodes and
# regular-file impostors both exhaust the poll and return 1. sleep/udevadm are function-stubbed
# so the 25-poll budget runs instantly. The positive half (real nodes appearing) runs for real
# on every image build — mkimage.sh and verify-image.sh both call this.
LW="$SANDBOX/loop-wait"
mkdir -p "$LW"
lw_run() { # $1 device path
    (
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/rauc/loop-wait.sh"
        udevadm() { :; }
        sleep() { echo x >>"$LW/sleeps"; }
        wait_loop_partitions "$1"
    )
}
: >"$LW/sleeps"
lw_run "$LW/loop0"
assert_rc "nodes that never appear -> rc 1" "$?" "1"
assert_eq "the wait polls its full 25-try budget, not a single-shot check" "$(wc -l <"$LW/sleeps" | tr -d ' ')" "25"
touch "$LW/loop0p1" "$LW/loop0p2"
lw_run "$LW/loop0"
assert_rc "regular files at p1/p2 do not satisfy the wait — block devices required" "$?" "1"
