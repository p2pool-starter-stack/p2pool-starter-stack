#!/usr/bin/env bash
#
# Self-test for verify-image.sh's baked-RigForge-ref check (#1414).
#
# The check it covers asserted only that a `ref=` line EXISTED, so it was green for the whole
# time the appliance shipped a pin two rigforge releases stale. These cases drive the real
# comparison over a synthetic root tree — no image, no loop mount, no root, no bench.
#
# It lives here rather than beside verify-image.sh because that file is 398 lines against the
# 400-line target, and crossing it would force a docs/dev/file-budget.tsv entry.
#
# Run: tests/integration/selftest-verify-image-ref.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# Sourcing verify-image.sh defines rigforge_ref_matches and runs nothing (its sourced-guard).
# Driving the SHIPPED function is the point: a copy of the comparison here could only prove the
# test agrees with itself.
# shellcheck source=tests/os/verify-image.sh
source "$HERE/../os/verify-image.sh"

echo "== verify-image: the baked rigforge ref must EQUAL the pin, not merely exist (#1414) =="

# The instrument has to be alive before any of its verdicts mean anything: if the source above
# silently failed, every case below would call a missing function and report the same rc.
if declare -F rigforge_ref_matches >/dev/null; then
    it_pass "rigforge_ref_matches is defined (verify-image.sh sourced without running)"
else
    it_fail "rigforge_ref_matches is defined" "not defined — the sourced-guard or the source path moved"
    echo "selftest-verify-image-ref: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PIN=4ce29b3daf063fd1b45e050649e93aa9592618e1
OLD=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d

# The fixture Dockerfile carries the same shape as the real one: prose lines that MENTION
# RIGFORGE_REF sit above the single `ARG RIGFORGE_REF=` that actually pins it. os/rootfs/Dockerfile
# has four such mentions, so an unanchored read would take a comment for the pin.
mkdockerfile() { # <path> <pinned-ref>
    {
        echo "# RIGFORGE_REF below pins a commit, not a tag."
        echo "ARG RIGFORGE_REF=$2"
        echo '        "https://example.invalid/${RIGFORGE_REF}.tar.gz" \'
    } >"$1"
}

mkroot() { # <dir> <recorded-ref>  — omit the ref to leave the record file out entirely
    mkdir -p "$1/opt/rigforge"
    [ "$#" -ge 2 ] && printf 'ref=%s version=v1.16.0\n' "$2" >"$1/opt/rigforge/RIGFORGE_REF"
}

check() { # <name> <root> <dockerfile> <want-rc>
    local name="$1" root="$2" df="$3" want="$4" got
    rigforge_ref_matches "$root" "$df"
    got=$?
    if [ "$got" = "$want" ]; then it_pass "$name"; else it_fail "$name" "want rc=$want, got rc=$got"; fi
}

mkdockerfile "$TMP/Dockerfile" "$PIN"
mkroot "$TMP/match" "$PIN"
mkroot "$TMP/stale" "$OLD"
mkroot "$TMP/empty" ""
mkroot "$TMP/norecord"

check "the recorded ref IS the pin -> pass" "$TMP/match" "$TMP/Dockerfile" 0
# The case the old assertion could not see, and the reason this issue exists.
check "a stale recorded ref -> FAIL" "$TMP/stale" "$TMP/Dockerfile" 1
check "a present but empty ref -> FAIL" "$TMP/empty" "$TMP/Dockerfile" 1
check "no record file at all -> FAIL" "$TMP/norecord" "$TMP/Dockerfile" 1
# The call site SKIPS on an unreadable Dockerfile and exit refuses a skip (#1064). The function
# must still refuse to say "match" — an absent pin is never equal to a present ref.
check "an unreadable Dockerfile -> FAIL, never a silent pass" "$TMP/match" "$TMP/nope" 1
# The only case where the -n guard is the mechanism that acts: with no record AND no Dockerfile
# both sides read empty, and a bare equality calls that a MATCH — a clean verdict on an image
# carrying no record at all. Every other row here survives the guard's deletion.
check "no record AND no Dockerfile -> FAIL (the -n guard's only case)" "$TMP/norecord" "$TMP/nope" 1
# Narrowness: the pin is read from `^ARG RIGFORGE_REF=` alone. Seeded here because a prose line
# is the near-miss that an unanchored read would take, and the real Dockerfile has four of them.
mkdockerfile "$TMP/Dockerfile.prose" "$PIN"
sed -i '1s/.*/# RIGFORGE_REF=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef is NOT the pin/' "$TMP/Dockerfile.prose"
check "a commented RIGFORGE_REF= is not read as the pin" "$TMP/match" "$TMP/Dockerfile.prose" 0

# THE DIFFERENTIAL, and the only thing here that proves the defect is closed rather than restated:
# on the SAME fixtures the assertion this replaced is green and the new comparison is red. Without
# it, every row above is consistent with a check that was never weak in the first place.
#
# BOTH fixtures are needed, and that is what earns the empty-ref row its place: `grep -q "^ref="`
# matches a `ref=` carrying NO VALUE just as happily as a stale one, so the empty case is a second
# thing the old check waved through, not a restatement of the missing-file case. No mutation of the
# comparison reds those two rows — this is the arm they are attributable to.
for fx in stale empty; do
    if grep -q "^ref=" "$TMP/$fx/opt/rigforge/RIGFORGE_REF"; then
        it_pass "the OLD 'grep -q ^ref=' assertion passes on the $fx fixture (the defect, reproduced)"
    else
        it_fail "the OLD assertion passes on the $fx fixture" "it did not — that fixture is not the defect's shape"
    fi
done

echo ""
echo "selftest-verify-image-ref: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
