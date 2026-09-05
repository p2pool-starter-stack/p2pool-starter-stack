#!/usr/bin/env bash
#
# Self-test for tests/stack/lib.sh's sandbox construction (#1661).
#
# THE DEFECT THIS PINS. lib.sh used to build its throwaway sandbox as a single expression:
#
#     SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
#     trap 'rm -rf "$SANDBOX"' EXIT
#
# `mktemp -d` writes its diagnostic to stderr and prints NOTHING on stdout when it fails, so the
# inner substitution collapsed to the empty string; `cd ""` is not an error in bash, it returns 0
# and leaves the working directory where it was, so `&& pwd -P` ran and SANDBOX became the
# directory the suite was invoked from. tests/stack/run.sh documents that as the repo root. The
# next line then armed `rm -rf` on the working tree, via an EXIT trap that fires at the end of a
# run that otherwise looked normal — every downstream "$SANDBOX/..." path resolved fine, because a
# real directory is exactly what SANDBOX held.
#
# WHY THE ASSERTIONS ARE SHAPED THIS WAY. Asserting only that the sourcing "failed", or only that
# some path came back, is green against the defect: the defective form succeeds and yields a real
# path. So the cases below assert the VALUE — that SANDBOX is not the caller's cwd — and assert
# that a sentinel file in that cwd is still on disk after the subshell's trap has run.
#
# The last case drives a reconstruction of the OLD expression against the same fixture and
# requires it to destroy the sentinel. Without it, every row here could be green because the
# fixture never armed rather than because the fix works.
#
# It lives here rather than in tests/stack/ because it is harness self-test, not one of the four
# tiers: the subject is the test harness's own plumbing and no product code is exercised. The
# tests/stack file that would otherwise host it, test-harness-tooling.sh, is not this lane's, and
# test-lifecycle.sh is at its 1032-line budget ceiling with zero headroom.
#
# Run: tests/integration/selftest-stack-sandbox.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

STACK_LIB="$HERE/../stack/lib.sh"

echo "== tests/stack/lib.sh must fail closed when mktemp -d fails, never fall back to the cwd (#1661) =="

# The instrument has to be alive before any verdict below means anything: if this path moved,
# every subshell would fail to source and the refusal rows would go green for the wrong reason.
if [ -f "$STACK_LIB" ]; then
    it_pass "tests/stack/lib.sh is where this test expects it"
else
    it_fail "tests/stack/lib.sh is where this test expects it" "not found at $STACK_LIB"
    echo "selftest-stack-sandbox: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A mktemp that fails the way the real one does: empty stdout, diagnostic on stderr, rc 1.
mkdir -p "$TMP/shim"
cat >"$TMP/shim/mktemp" <<'EOF'
#!/bin/sh
echo "mktemp: failed to create directory via template" >&2
exit 1
EOF
chmod +x "$TMP/shim/mktemp"

# A reconstruction of the pre-fix expression, used only by the final control. Keeping it here
# rather than a copy of the whole library keeps the control honest about what it reproduces.
cat >"$TMP/prefix-lib.sh" <<'EOF'
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
EOF

# seed_victim <dir> — a disposable stand-in for the directory a suite is invoked from.
seed_victim() {
    mkdir -p "$1/subdir"
    echo "sentinel" >"$1/sentinel.txt"
    echo "sentinel" >"$1/subdir/nested.txt"
}

# --- Case 1-3: the fixed library, with mktemp failing. ---
V1="$TMP/v1"
seed_victim "$V1"
out=$(cd "$V1" && PATH="$TMP/shim:$PATH" bash -c "source '$STACK_LIB'; echo \"SANDBOX=\$SANDBOX\"" 2>&1)
rc=$?

if [ "$rc" -ne 0 ]; then
    it_pass "sourcing refuses (rc $rc) when mktemp -d fails"
else
    it_fail "sourcing refuses when mktemp -d fails" "it returned 0 and carried on: $out"
fi

if [ -f "$V1/sentinel.txt" ] && [ -f "$V1/subdir/nested.txt" ]; then
    it_pass "the caller's directory survives the refusal, contents intact"
else
    it_fail "the caller's directory survives the refusal" "the EXIT trap removed the caller's cwd"
fi

# The value assertion. A refusal that still exported the cwd would be caught here and nowhere else.
if printf '%s' "$out" | grep -q "SANDBOX=$V1"; then
    it_fail "SANDBOX is never set to the caller's cwd" "it was: $out"
else
    it_pass "SANDBOX is never set to the caller's cwd"
fi

# --- Case 4-5: the fixed library with a WORKING mktemp must still build a real sandbox.
# Without this, deleting the sandbox logic entirely would pass every row above.
V2="$TMP/v2"
seed_victim "$V2"
out2=$(cd "$V2" && bash -c "source '$STACK_LIB'; echo \"SANDBOX=\$SANDBOX\"; [ -d \"\$SANDBOX\" ] && echo ISDIR" 2>&1)
rc2=$?

if [ "$rc2" -eq 0 ] && printf '%s' "$out2" | grep -q ISDIR; then
    it_pass "a working mktemp still yields a real sandbox directory"
else
    it_fail "a working mktemp still yields a real sandbox directory" "rc $rc2: $out2"
fi

if printf '%s' "$out2" | grep -q "SANDBOX=$V2"; then
    it_fail "the sandbox is distinct from the caller's cwd" "it was the cwd: $out2"
else
    it_pass "the sandbox is distinct from the caller's cwd"
fi

# --- Case 6: the fixture must be able to catch the defect. ---
# The pre-fix expression against the same shim and the same fixture. If the sentinel survives here,
# the fixture is not reproducing the failure and every row above is green for the wrong reason.
V3="$TMP/v3"
seed_victim "$V3"
(cd "$V3" && PATH="$TMP/shim:$PATH" bash -c "source '$TMP/prefix-lib.sh'" >/dev/null 2>&1)

if [ -f "$V3/sentinel.txt" ]; then
    it_fail "the pre-fix expression destroys the caller's cwd (fixture arms)" \
        "the sentinel survived — this fixture cannot catch the defect, so the rows above prove nothing"
else
    it_pass "the pre-fix expression destroys the caller's cwd (fixture arms)"
fi

echo ""
echo "== every tests/stack sandbox is built through mk_tmpdir, not a bare assignment (#1705) =="

# The constructor is only half the fix. The other half is that the call sites in the domain files
# actually reach it, and a list of the converted names would rot on the next file added. So this
# is the invariant instead: in the files #1705 covered, `mktemp -d` may appear only inside a
# guarded expression, never as a bare `VAR=$(mktemp -d)` whose failure leaves VAR set-but-empty
# for a later `rm -rf "$VAR/store"` to expand against /store.
#
# #1705's conversion stopped at a grant boundary: tests/stack/run.sh and the standalone
# tests/stack/test_*.sh belonged to another lane and kept the old form, so this row named them out
# of itself and a second row PINNED that excluded population against the four known sites, keeping
# the exclusion from rotting. #1725 converted those four, so both halves are gone: the glob below
# covers every file the constructor reaches, and the pin has nothing left to hold. That pin reddens
# on exactly this change, which is why the two halves cannot merge one at a time — they land here
# together or the row is red in between. The glob is lib.sh, run.sh and both test-file spellings,
# which today is every .sh under tests/stack except fixtures/rauc-info/capture.sh — a capture
# helper the suite does not source, named here so the one file outside is stated, not implied.
BARE='^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$\(mktemp -d\)"?[[:space:]]*$'
STACK_DIR="$HERE/../stack"

# The pattern must be shown able to match before its absence anywhere means anything.
CTRL="$TMP/bare-control.sh"
printf 'RSB=$(mktemp -d)\nrm -rf "$RSB/store"\n' >"$CTRL"
if grep -Eq "$BARE" "$CTRL"; then
    it_pass "the bare-assignment pattern matches the pre-fix form (control arms)"
else
    it_fail "the bare-assignment pattern matches the pre-fix form" \
        "it matched nothing, so the absence checked below proves nothing"
fi

# Every entry goes through the same existence filter, the two fixed names included. Seeding those
# in unconditionally would make the check below a tautology — it would read back the list it had
# just been handed, and a stack directory missing run.sh entirely would still report it as covered.
#
# The set is built per SPELLING, not per filename. The deleted pin was not only a pin: it was the
# only thing proving this row read real files, and with it gone a file set that resolved to nothing
# would report the same clean absence as a fully converted tree. So the set is measured before the
# absence below is read as evidence, and this refuses rather than records — a vacuous invariant row
# is worse than no row, it reads as proof. Counting each spelling's matches is what lets the refusal
# name the spelling that failed. The first form asserted three filenames instead, which put another
# lane's test_data_reset.sh inside this lane's assertion and emitted the same red whether that one
# file had been renamed or the whole test_*.sh spelling had drained away — two failures, one
# message (#1796).
#
# The spellings are quoted in the list deliberately: unquoted, test-*.sh and test_*.sh would glob
# against the working directory at this line rather than against $STACK_DIR below, and the control
# would quietly stop meaning what it says.
COVERED=()
missing=""
for spelling in "lib.sh" "run.sh" "test-*.sh" "test_*.sh"; do
    n=0
    # shellcheck disable=SC2086  # $spelling is a glob; quoting it would defeat the match
    for f in "$STACK_DIR"/$spelling; do
        [ -f "$f" ] || continue
        COVERED+=("$f")
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || missing="$missing $spelling"
done

# All four spellings matching means COVERED holds at least four entries, so the empty-expansion
# guard the grep below needs is implied by this refusal rather than asserted separately beside it.
if [ -z "$missing" ]; then
    it_pass "the invariant's file set resolves for every spelling (control arms)"
else
    it_fail "the invariant's file set resolves for every spelling" \
        "the absence below would be vacuous — ${#COVERED[@]} files, unmatched:$missing"
    echo "selftest-stack-sandbox: $IT_PASS passed, $IT_FAIL failed"
    exit 1
fi

found=$(grep -El "$BARE" "${COVERED[@]}" 2>/dev/null | tr '\n' ' ')
if [ -z "$found" ]; then
    it_pass "no bare mktemp -d assignment survives in any tests/stack suite file"
else
    it_fail "no bare mktemp -d assignment survives in any tests/stack suite file" \
        "still bare in: $found"
fi

echo ""
echo "selftest-stack-sandbox: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
