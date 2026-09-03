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
echo "selftest-stack-sandbox: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
