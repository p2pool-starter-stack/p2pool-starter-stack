#!/usr/bin/env bash
# The patch-coverage gate (#286), without the vacuous pass (#1000). diff-cover exits 0 with
# "No lines with coverage information" when the diff and coverage.xml don't overlap — which is
# fine for a shell/docs/compose-only PR but a silent hole when the diff changed measured
# dashboard Python that a stale coverage.xml never saw. This wrapper runs diff-cover, then
# checks that every changed file under the measured tree (build/dashboard/mining_dashboard/)
# appears in coverage.xml: absent files fail loudly, a diff with nothing measurable passes
# loudly and says so. Run `--self-test` to check the overlap logic against fixtures.
set -euo pipefail

COMPARE=origin/develop
# The tree the dashboard coverage run measures (pytest --cov=mining_dashboard). Python outside
# it (tests, integration fakes) is never in coverage.xml, so it can't make the gate applicable.
MEASURED='build/dashboard/mining_dashboard/*.py'

# Decide the gate's verdict from the changed measured files vs coverage.xml. Args: <coverage.xml>
# then the changed files (repo-relative). No changed files -> loud not-applicable pass. Every
# changed file present in the XML -> pass, saying exactly what was checked (a comment-only
# change legitimately reports no measurable lines). Any file absent -> fail: coverage never saw
# it, so the >=90% number above proved nothing about it.
# ponytail: file-level overlap only — added lines a stale XML lacks inside a known file still
# slip through (catching those needs coverage's own statement analysis). The gate's contract is
# a fresh coverage.xml: run right after `make test-dashboard`, the order CI enforces.
check_overlap() {
    local xml="$1" f rel missing=()
    shift
    if [ "$#" -eq 0 ]; then
        echo "patch coverage: nothing under build/dashboard/mining_dashboard/ changed in this diff — the >=90% gate is not applicable."
        return 0
    fi
    for f in "$@"; do
        case "$f" in
        # Generated Tari gRPC stubs are coverage-omitted by design (pyproject's omit) — a
        # rename or regeneration must not read as unmeasured changed code.
        */client/tari/generated/*) continue ;;
        esac
        rel="${f#build/dashboard/mining_dashboard/}" # coverage.xml filenames are source-root-relative
        grep -q "filename=\"$rel\"" "$xml" || missing+=("$f")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "patch coverage: FAIL — changed dashboard Python that coverage.xml never measured:"
        printf '  %s\n' "${missing[@]}"
        echo "A stale coverage.xml makes the gate above vacuous. Re-run 'make test-dashboard', then this gate."
        return 1
    fi
    echo "patch coverage: all ${#} changed file(s) under the measured tree are present in coverage.xml."
    return 0
}

# --- self-test: drive the overlap decision through fixtures (both branches + the quiet pass) ----
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    st_fail=0
    expect_rc() { # <desc> <expected-rc> <actual-rc>
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (expected rc $2, got $3)"
            st_fail=1
        fi
    }

    printf '%s\n' '<coverage><class filename="web/views.py"/></coverage>' >"$tmp/coverage.xml"

    rc=0
    check_overlap "$tmp/coverage.xml" >"$tmp/out" || rc=$?
    expect_rc "no measured changes -> pass" 0 "$rc"
    grep -q "not applicable" "$tmp/out" || {
        echo "  self-test FAIL: not-applicable pass is silent"
        st_fail=1
    }

    rc=0
    check_overlap "$tmp/coverage.xml" build/dashboard/mining_dashboard/web/views.py >"$tmp/out" || rc=$?
    expect_rc "changed file present in coverage.xml -> pass" 0 "$rc"

    rc=0
    check_overlap "$tmp/coverage.xml" build/dashboard/mining_dashboard/web/ghost.py >"$tmp/out" || rc=$?
    expect_rc "changed file absent from coverage.xml -> fail" 1 "$rc"

    grep -q "ghost.py" "$tmp/out" || {
        echo "  self-test FAIL: failure doesn't name the unmeasured file"
        st_fail=1
    }

    rc=0
    check_overlap "$tmp/coverage.xml" build/dashboard/mining_dashboard/client/tari/generated/foo_pb2.py >"$tmp/out" || rc=$?
    expect_rc "generated stub absent from coverage.xml -> still pass (coverage-omitted by design)" 0 "$rc"

    [ "$st_fail" -eq 0 ] && {
        echo "patch-coverage self-test OK"
        exit 0
    }
    echo "patch-coverage self-test FAILED"
    exit 1
fi

# --- main: diff-cover as before, then the overlap check on its green paths ----------------------
rc=0
(cd build/dashboard && uv run --locked --extra test \
    diff-cover coverage.xml --compare-branch="$COMPARE" --fail-under=90) || rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

# Same diff diff-cover reads: committed vs the compare branch, plus staged and unstaged.
# --diff-filter=d drops deletions (a deleted file is rightly absent from fresh coverage).
changed=$({
    git diff --name-only --diff-filter=d "$COMPARE...HEAD" -- "$MEASURED"
    git diff --name-only --diff-filter=d HEAD -- "$MEASURED"
} | sort -u)

# shellcheck disable=SC2086  # repo paths are space-free; intentional word-split into args
check_overlap build/dashboard/coverage.xml $changed
