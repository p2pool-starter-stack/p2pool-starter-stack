#!/usr/bin/env bash
#
# Self-test for verify-image.sh's data-reset repair-tools check (#1069 W11).
#
# pithead-data-reset's repair chain (os/overlay/pithead-data-reset) runs
# `fsck`/`e2fsck`/`mkfs.ext4` behind `|| true`, so a rootfs that shipped without e2fsprogs
# would look exactly like a partition fsck refused to touch — nothing distinguishes "the tool
# is missing" from "the tool ran and said no". The check this covers catches that class of
# regression on the built artifact, driven here over a synthetic root tree — no image, no loop
# mount, no root, no bench.
#
# It lives here rather than beside verify-image.sh for the same reason selftest-verify-image-ref.sh
# does: that file sits at the 400-line target and a same-file test would cross it.
#
# Run: tests/integration/selftest-verify-image-repair-tools.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# Sourcing verify-image.sh defines data_reset_repair_tools_present and runs nothing (its
# sourced-guard). Driving the SHIPPED function is the point: a copy of the checks here could
# only prove the test agrees with itself.
# shellcheck source=tests/os/verify-image.sh
source "$HERE/../os/verify-image.sh"

echo "== verify-image: data-reset's repair tools must be BAKED, not merely installable (#1069 W11) =="

if declare -F data_reset_repair_tools_present >/dev/null; then
    it_pass "data_reset_repair_tools_present is defined (verify-image.sh sourced without running)"
else
    it_fail "data_reset_repair_tools_present is defined" "not defined — the sourced-guard or the source path moved"
    echo "selftest-verify-image-repair-tools: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkbin() { # <path> — a stand-in executable at the given path, parents created
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\n' >"$1"
    chmod +x "$1"
}

check() { # <name> <root> <want-rc>
    local name="$1" root="$2" want="$3" got
    data_reset_repair_tools_present "$root"
    got=$?
    if [ "$got" = "$want" ]; then it_pass "$name"; else it_fail "$name" "want rc=$want, got rc=$got"; fi
}

# Both baked, merged-usr layout — the real shape a current Debian rootfs ships.
mkbin "$TMP/both/usr/sbin/e2fsck"
mkbin "$TMP/both/usr/sbin/mkfs.ext4"
check "both tools present (merged /usr) -> pass" "$TMP/both" 0

# Both baked, legacy /sbin layout — the fallback path the check also accepts.
mkbin "$TMP/legacy/sbin/e2fsck"
mkbin "$TMP/legacy/sbin/mkfs.ext4"
check "both tools present (legacy /sbin) -> pass" "$TMP/legacy" 0

# THE DEFECT: e2fsprogs dropped from the image. Neither tool is there.
mkdir -p "$TMP/neither/usr/sbin"
check "e2fsprogs missing entirely -> FAIL" "$TMP/neither" 1

# Partial install: e2fsck present, mkfs.ext4 missing (or vice versa) — the repair chain would
# run fsck/e2fsck fine and then fail to reformat, or the reverse. Either half missing must
# refuse; this is the case a single-tool check would miss.
mkbin "$TMP/half-e2fsck/usr/sbin/e2fsck"
check "e2fsck present, mkfs.ext4 missing -> FAIL" "$TMP/half-e2fsck" 1
mkbin "$TMP/half-mkfs/usr/sbin/mkfs.ext4"
check "mkfs.ext4 present, e2fsck missing -> FAIL" "$TMP/half-mkfs" 1

# A present but non-executable file (e.g. a stripped/corrupted package extraction) is the same
# as absent for this purpose — pithead-data-reset invokes it directly, not through a PATH lookup
# that could fall back.
mkdir -p "$TMP/not-exec/usr/sbin"
: >"$TMP/not-exec/usr/sbin/e2fsck"
: >"$TMP/not-exec/usr/sbin/mkfs.ext4"
check "present but not executable -> FAIL" "$TMP/not-exec" 1

# THE DIFFERENTIAL: on the fixture above (e2fsprogs missing), the existing `fsck ... || true`
# shape in os/overlay/pithead-data-reset would swallow the resulting "command not found" and
# proceed as if the tool ran and refused — silently reformatting a partition e2fsck was never
# actually asked about. Without the "e2fsprogs missing entirely" check above, verify-image.sh has
# nothing that would go red on that rootfs.

echo ""
echo "selftest-verify-image-repair-tools: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
