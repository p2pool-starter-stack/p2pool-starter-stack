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
# tests/stack/run.sh and the standalone tests/stack/test_*.sh are NOT covered and still carry the
# old form. They belong to other lanes, so #1705's conversion stopped at the grant boundary. They
# are excluded by name rather than by silence, so that this row says what it does not check —
# and the row after the next one PINS that excluded population, so the exclusion cannot rot.
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

found=$(grep -El "$BARE" "$STACK_DIR/lib.sh" "$STACK_DIR"/test-*.sh 2>/dev/null | tr '\n' ' ')
if [ -z "$found" ]; then
    it_pass "no bare mktemp -d assignment survives in lib.sh or the test-*.sh domain files"
else
    it_fail "no bare mktemp -d assignment survives in lib.sh or the test-*.sh domain files" \
        "still bare in: $found"
fi

echo ""
echo "== the by-name exclusion above is PINNED to the four sites #1725 documented =="

# A by-name exclusion rots silently. run.sh and the standalone test_*.sh are named out of the
# invariant above, so a FIFTH bare site added to either would sit outside it with nothing saying
# so — that gap, rather than the four known sites, is what #1725 is about (none of the four has a
# downstream `rm -rf "$VAR/sub"`, so an empty value gives `rm -rf ""`, which errors and removes
# nothing; re-derived at ef3942d0). Pinning the excluded population makes the exclusion a ratchet
# in both directions: a new bare site reds this row, and so does converting the four, which is the
# signal to delete the exclusion and widen the invariant above to cover these files too.
#
# ⛔ THAT SECOND RED IS EXPECTED AND IS NOT A DEFECT — DO NOT SWITCH THIS ROW OFF TO CLEAR IT.
# The conversion lives in tests/stack/ (the tests lane) and this pin lives here (e2e), so the
# two halves of #1725 merge separately and the pin reds in between. The remedy is in the
# failure message: delete the by-name exclusion above, widen the invariant to these files,
# and delete this row with it. Deleting only this row leaves run.sh covered by nothing.
#
# Keyed on file and VARIABLE NAME, never line numbers: #1725's body cites run.sh 104/118/124 and
# the sites had already drifted to 107/121/127 by the time this row was written.
# C collation fixes the order, and uniq -c leaves each file+var key unique, so nothing after it
# can reorder the result.
gap_census() { # <stack dir> -> "<file> <var> <count>" per line
    local f b
    for f in "$1/run.sh" "$1"/test_*.sh; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        grep -E "$BARE" "$f" 2>/dev/null | sed -E "s|^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*|$b \1|"
    done | LC_ALL=C sort | uniq -c | awk '{print $2, $3, $1}'
}

EXPECTED_GAP='run.sh XPTLS 1
run.sh d 2
test_data_reset.sh WORK 1'

# The census has to be shown able to report a set OTHER than the pin, or "it equalled the pin" is
# not a measurement — a census that silently returned nothing would agree with an all-converted
# population just as loudly. This fixture carries one bare site under a name that appears nowhere
# in the real population, so only a census that actually reads the file can produce it.
mkdir -p "$TMP/gapctl"
printf 'ZCTL="$(mktemp -d)"\nrm -rf "$ZCTL"\n' >"$TMP/gapctl/run.sh"
ctl_census="$(gap_census "$TMP/gapctl")"
if [ "$ctl_census" = "run.sh ZCTL 1" ]; then
    it_pass "the excluded-population census reports a site the pin does not contain (control arms)"
else
    it_fail "the excluded-population census reports a site the pin does not contain" \
        "expected 'run.sh ZCTL 1', got: ${ctl_census:-<empty>}"
fi

actual_gap="$(gap_census "$STACK_DIR")"
if [ "$actual_gap" = "$EXPECTED_GAP" ]; then
    it_pass "the excluded files carry exactly the four bare sites #1725 documented"
else
    it_fail "the excluded files carry exactly the four bare sites #1725 documented" \
        "#1725: the excluded population moved, which this row exists to announce — it is not a defect in this file. If the four were CONVERTED (tests lane, tests/stack/), the fix is to delete the by-name exclusion above, widen the invariant to run.sh and test_*.sh, and delete this row with it; do not delete this row alone, that leaves run.sh covered by nothing. If a NEW bare site appeared, it is outside every check in this suite. Expected [$(printf '%s' "$EXPECTED_GAP" | tr '\n' '|')] got [$(printf '%s' "${actual_gap:-<empty>}" | tr '\n' '|')]"
fi

echo ""
echo "selftest-stack-sandbox: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
