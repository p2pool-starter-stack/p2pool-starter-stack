#!/usr/bin/env bash
# The patch-coverage gate (#286), without the vacuous pass (#1000). diff-cover exits 0 with
# "No lines with coverage information" when the diff and coverage.xml don't overlap — which is
# fine for a shell/docs/compose-only PR but a silent hole when the diff changed measured
# dashboard Python that a stale coverage.xml never saw. This wrapper runs diff-cover, then
# checks that every changed file under the measured tree (dashboard/mining_dashboard/)
# appears in coverage.xml: absent files fail loudly, a diff with nothing measurable passes
# loudly and says so. Run `--self-test` to check the overlap logic against fixtures.
set -euo pipefail

# The base the gate grades against, and #1557: this was a bare `COMPARE=origin/develop` with no
# override. `develop` is FROZEN and all work lands on `develop-v2`, so every lane branch was graded
# over the whole twin divergence instead of its own patch — on one branch, 572 files instead of 2
# and 87 measured dashboard files instead of 0. Green over the wrong set is the same word as green
# over the right one, and there is no rc, no warning and no empty output to notice it.
#
# On a pull_request run GITHUB_BASE_REF is the PR's own base and ci.yml already fetches it; reading
# it here is the whole of #1557's other half, so that shared file needs no change. Off a PR it is
# unset (a local run, or a push build — `push:` only fires on main/develop): prefer develop-v2,
# where work lands, and fall back to develop when develop-v2 was never fetched, which is the push
# case. `COMPARE` in the environment still wins, so a caller can grade against anything.
pick_compare() { # <github-base-ref> <preferred-exists: yes|no> <preferred> <fallback> -> the ref
    [ -n "$1" ] && {
        echo "origin/$1"
        return 0
    }
    [ "$2" = yes ] && {
        echo "origin/$3"
        return 0
    }
    echo "origin/$4"
}
_pref=develop-v2
if git rev-parse --verify --quiet "origin/$_pref" >/dev/null; then _has=yes; else _has=no; fi
COMPARE="${COMPARE:-$(pick_compare "${GITHUB_BASE_REF:-}" "$_has" "$_pref" develop)}"
# The tree the dashboard coverage run measures (pytest --cov=mining_dashboard). Python outside
# it (tests, integration fakes) is never in coverage.xml, so it can't make the gate applicable.
MEASURED='dashboard/mining_dashboard/*.py'

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
        echo "patch coverage: nothing under dashboard/mining_dashboard/ changed in this diff — the >=90% gate is not applicable."
        return 0
    fi
    for f in "$@"; do
        case "$f" in
        # Generated Tari gRPC stubs are coverage-omitted by design (pyproject's omit) — a
        # rename or regeneration must not read as unmeasured changed code.
        */client/tari/generated/*) continue ;;
        esac
        rel="${f#dashboard/mining_dashboard/}" # coverage.xml filenames are source-root-relative
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
    check_overlap "$tmp/coverage.xml" dashboard/mining_dashboard/web/views.py >"$tmp/out" || rc=$?
    expect_rc "changed file present in coverage.xml -> pass" 0 "$rc"

    rc=0
    check_overlap "$tmp/coverage.xml" dashboard/mining_dashboard/web/ghost.py >"$tmp/out" || rc=$?
    expect_rc "changed file absent from coverage.xml -> fail" 1 "$rc"

    grep -q "ghost.py" "$tmp/out" || {
        echo "  self-test FAIL: failure doesn't name the unmeasured file"
        st_fail=1
    }

    rc=0
    check_overlap "$tmp/coverage.xml" dashboard/mining_dashboard/client/tari/generated/foo_pb2.py >"$tmp/out" || rc=$?
    expect_rc "generated stub absent from coverage.xml -> still pass (coverage-omitted by design)" 0 "$rc"

    # #1557: the base is a decision, so it gets fixtures too — a run graded against the wrong
    # branch must be distinguishable from one graded right, or the self-test certifies a behaviour
    # it cannot see. pick_compare is pure for exactly this reason; the git lookup that feeds its
    # second argument stays at the top, where the self-test is not the thing under test.
    expect_eq() { # <desc> <expected> <actual>
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (expected '$2', got '$3')"
            st_fail=1
        fi
    }
    expect_eq "on a PR, GITHUB_BASE_REF is the base" origin/develop-v2 "$(pick_compare develop-v2 no develop-v2 develop)"
    expect_eq "GITHUB_BASE_REF outranks the preference, even naming the frozen branch" origin/develop "$(pick_compare develop yes develop-v2 develop)"
    expect_eq "off a PR, develop-v2 when it is fetched" origin/develop-v2 "$(pick_compare "" yes develop-v2 develop)"
    expect_eq "off a PR, fall back to develop when develop-v2 is absent" origin/develop "$(pick_compare "" no develop-v2 develop)"

    [ "$st_fail" -eq 0 ] && {
        echo "patch-coverage self-test OK"
        exit 0
    }
    echo "patch-coverage self-test FAILED"
    exit 1
fi

# --- main: diff-cover as before, then the overlap check on its green paths ----------------------
# Say which base the number is about, BEFORE diff-cover runs (#1557). Changing the default alone
# leaves the next base change as silent as this one was; the count is carried by check_overlap.
echo "patch coverage: grading changed lines against $COMPARE."
rc=0
(cd dashboard && uv run --locked --extra test \
    diff-cover coverage.xml --compare-branch="$COMPARE" --fail-under=90) || rc=$?
[ "$rc" -ne 0 ] && exit "$rc"

# Same diff diff-cover reads: committed vs the compare branch, plus staged and unstaged.
# --diff-filter=d drops deletions (a deleted file is rightly absent from fresh coverage).
changed=$({
    git diff --name-only --diff-filter=d "$COMPARE...HEAD" -- "$MEASURED"
    git diff --name-only --diff-filter=d HEAD -- "$MEASURED"
} | sort -u)

# shellcheck disable=SC2086  # repo paths are space-free; intentional word-split into args
check_overlap dashboard/coverage.xml $changed
