#!/usr/bin/env bash
# Fixtures for the file-budget ratchet gate — every failure mode it has, each against a throwaway
# git repo built for it. Split out of scripts/lint-file-budget.sh for issue #1464: the gate was
# 407 lines at a recorded ceiling of 407, so it was closed to any addition, and the gate's own
# header rule says a file back under the 400 target must drop its budget entry. Splitting is
# therefore the remedy the gate itself documents, not a way around it.
#
# Run it directly, or as `scripts/lint-file-budget.sh --self-test`, which execs this file.
# The gate is SOURCED for its functions, so it carries a guard that keeps sourcing from running
# anything; see the bottom of that script.
set -euo pipefail

# readlink -f for the same reason the gate's --self-test dispatch uses it: through a symlink the
# bare dirname would point at the link's directory and the source below would miss.
HERE=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=scripts/lint-file-budget.sh
source "$HERE/lint-file-budget.sh"

# --- self-test: every failure mode against fixtures, in an isolated throwaway git repo ----------
self_test() {
    local tmp out st_fail=0 rc=0
    tmp=$(mktemp -d)
    out=$(mktemp)
    # Double-quoted so $tmp/$out are embedded now, as literal paths — the trap still fires after
    # self_test's own locals have gone out of scope, so a deferred expansion would see them unset.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp' '$out'" EXIT
    git -C "$tmp" init -q -b develop
    git -C "$tmp" config user.email test@example.invalid
    git -C "$tmp" config user.name test

    expect() { # <desc> <expected-rc> <actual-rc>
        if [ "$2" -eq "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (expected rc $2, got $3)"
            st_fail=1
        fi
    }
    seq 1 500 >"$tmp/budgeted.sh"
    mkdir -p "$tmp/$(dirname "$BUDGET_FILE")"
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp/$BUDGET_FILE"
    git -C "$tmp" add budgeted.sh "$BUDGET_FILE"
    git -C "$tmp" commit -q -m base

    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "calibration: budgeted file at its ceiling passes" 0 "$rc"

    seq 1 501 >"$tmp/budgeted.sh"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "growing a budgeted file past its ceiling FAILS" 1 "$rc"
    if grep -q "budgeted.sh is 501" "$out"; then
        echo "  self-test ok: names the offending file"
    else
        echo "  self-test FAIL: did not name the offending file"
        st_fail=1
    fi

    seq 1 500 >"$tmp/budgeted.sh"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "reverting the growth passes again" 0 "$rc"

    seq 1 800 >"$tmp/new.sh"
    git -C "$tmp" add new.sh
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "an over-target file with NO entry FAILS (800, inside the hard ceiling)" 1 "$rc"
    if grep -q "new.sh is 800 lines (> 400 target) but has no" "$out"; then
        echo "  self-test ok: names the missing entry, not the hard ceiling"
    else
        echo "  self-test FAIL: did not name the missing entry"
        st_fail=1
    fi
    printf '# test budget\nbudgeted.sh\t500\nnew.sh\t800\n' >"$tmp/$BUDGET_FILE"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "recording the entry is the fix — the same file then passes" 0 "$rc"
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp/$BUDGET_FILE"
    seq 1 801 >"$tmp/new.sh"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a new 801-line file FAILS the hard ceiling" 1 "$rc"
    rm -f "$tmp/new.sh"
    git -C "$tmp" rm -q --cached new.sh >/dev/null 2>&1 || true

    # #1486 — `git ls-files` alone only sees the INDEX; an untracked new file must be a
    # candidate too, or the gate reads a skip as a pass on exactly the file it exists to catch.
    seq 1 500 >"$tmp/untracked.sh"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "an over-target file that is untracked (never git add'ed) still FAILS (#1486)" 1 "$rc"
    if grep -q "untracked.sh is 500 lines (> 400 target) but has no" "$out"; then
        echo "  self-test ok: names the untracked file, not a vacuous pass"
    else
        echo "  self-test FAIL: did not name the untracked file"
        st_fail=1
    fi
    rm -f "$tmp/untracked.sh"

    printf '# test budget\nbudgeted.sh\t400\n' >"$tmp/$BUDGET_FILE"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "lowering a ceiling below the file's real size FAILS (reality check)" 1 "$rc"

    printf '# test budget\nbudgeted.sh\t900\n' >"$tmp/$BUDGET_FILE"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "raising a ceiling FAILS (monotonicity, vs the committed base)" 1 "$rc"
    if grep -q "raises budgeted.sh's ceiling" "$out"; then
        echo "  self-test ok: names the ceiling raise"
    else
        echo "  self-test FAIL: did not name the ceiling raise"
        st_fail=1
    fi
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp/$BUDGET_FILE"

    seq 1 300 >"$tmp/budgeted.sh"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a budgeted file dropped below target still listed FAILS (stale entry)" 1 "$rc"
    seq 1 500 >"$tmp/budgeted.sh"

    # Complement of the case above, and the one #1430 found untested: the base entry is not just
    # stale, it is GONE from the new tsv. check_monotonic walks the working-tree rows, so a base
    # row absent here is never visited — the file legitimately shrank to <= target — and the gate
    # must PASS, not FAIL. Without this case, a regression that made that skip fail open again
    # (#1375's construct) would go uncaught by this suite.
    seq 1 300 >"$tmp/budgeted.sh"
    printf '# test budget\n' >"$tmp/$BUDGET_FILE"
    rc=0
    (cd "$tmp" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a shrunk file whose entry was correctly removed PASSES (legitimate removal, #1430)" 0 "$rc"
    seq 1 500 >"$tmp/budgeted.sh"
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp/$BUDGET_FILE"

    # Two-lane shape: a develop-v2 branch cut BEFORE the lane tip advanced must still
    # ratchet against develop-v2, not fall back to develop and read this lane's larger
    # ceiling as a raise — the false RED that bit two live PRs the day the tip moved.
    local tmp3
    tmp3=$(mktemp -d)
    git -C "$tmp3" init -q -b develop
    git -C "$tmp3" config user.email test@example.invalid
    git -C "$tmp3" config user.name test
    mkdir -p "$tmp3/$(dirname "$BUDGET_FILE")"
    seq 1 500 >"$tmp3/budgeted.sh"
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp3/$BUDGET_FILE"
    git -C "$tmp3" add -A && git -C "$tmp3" commit -q -m dev-base
    git -C "$tmp3" checkout -q -b develop-v2
    seq 1 600 >"$tmp3/budgeted.sh"
    printf '# test budget\nbudgeted.sh\t600\n' >"$tmp3/$BUDGET_FILE"
    git -C "$tmp3" add -A && git -C "$tmp3" commit -q -m v2-larger
    git -C "$tmp3" checkout -q -b feature
    git -C "$tmp3" checkout -q develop-v2
    echo x >"$tmp3/other.txt"
    git -C "$tmp3" add other.txt && git -C "$tmp3" commit -q -m v2-advances
    git -C "$tmp3" checkout -q feature
    seq 1 580 >"$tmp3/budgeted.sh"
    printf '# test budget\nbudgeted.sh\t580\n' >"$tmp3/$BUDGET_FILE"
    rc=0
    (cd "$tmp3" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a v2-lane branch behind the moved lane tip still ratchets against develop-v2" 0 "$rc"
    rc=0
    (cd "$tmp3" && [ "$(resolve_base_ref)" = develop-v2 ]) || rc=1
    expect "lane detection reads history, not tip-levelness" 0 "$rc"
    git -C "$tmp3" checkout -q -f develop
    rc=0
    (cd "$tmp3" && [ "$(resolve_base_ref)" = develop ]) || rc=1
    expect "a develop-lane checkout still resolves to develop" 0 "$rc"
    rm -rf "$tmp3"

    # #1464 — the un-split-remainder row is the one ceiling allowed to RISE, because it measures
    # what of the generated pithead artifact is not split out YET rather than the size of a file
    # anyone writes. Three cases in their own repo, so they cannot perturb what the cases above
    # prove: the exempt row rising, a firing control, and the ratchet still biting from the
    # other side.
    local tmp4
    tmp4=$(mktemp -d)
    git -C "$tmp4" init -q -b develop
    git -C "$tmp4" config user.email test@example.invalid
    git -C "$tmp4" config user.name test
    mkdir -p "$tmp4/$(dirname "$BUDGET_FILE")" "$tmp4/lib/pithead"
    seq 1 500 >"$tmp4/budgeted.sh"
    seq 1 500 >"$tmp4/lib/pithead/99-remainder.sh"
    # A SIBLING SLICE, and it is the reason this fixture has three files rather than two.
    # #1105 Phase 2 keeps adding real source files under lib/pithead/, so the plausible future
    # mistake is not deleting the exemption — it is widening its pattern to lib/pithead/*.
    # With only the remainder here, that widening kept every case green.
    seq 1 500 >"$tmp4/lib/pithead/01-prelude.sh"
    printf '# test budget\nbudgeted.sh\t500\nlib/pithead/01-prelude.sh\t500\nlib/pithead/99-remainder.sh\t500\n' \
        >"$tmp4/$BUDGET_FILE"
    git -C "$tmp4" add -A && git -C "$tmp4" commit -q -m remainder-base
    # The shape a pithead bug fix produces: the artifact grows, the row is updated to match.
    seq 1 600 >"$tmp4/lib/pithead/99-remainder.sh"
    printf '# test budget\nbudgeted.sh\t500\nlib/pithead/01-prelude.sh\t500\nlib/pithead/99-remainder.sh\t600\n' \
        >"$tmp4/$BUDGET_FILE"
    rc=0
    (cd "$tmp4" && run_gate) >"$out" 2>&1 || rc=$?
    expect "the un-split-remainder ceiling may rise with the artifact it measures (#1464)" 0 "$rc"

    # THE LOAD-BEARING CASE. Without it the pass above is indistinguishable from a monotonic
    # check that stopped checking: same raise, a row that is NOT exempt, in the same run.
    printf '# test budget\nbudgeted.sh\t900\nlib/pithead/01-prelude.sh\t500\nlib/pithead/99-remainder.sh\t600\n' \
        >"$tmp4/$BUDGET_FILE"
    rc=0
    (cd "$tmp4" && run_gate) >"$out" 2>&1 || rc=$?
    expect "control: a NON-exempt ceiling raise still FAILS in the same run" 1 "$rc"
    if grep -q "raises budgeted.sh's ceiling" "$out" &&
        ! grep -q "raises lib/pithead/99-remainder.sh's ceiling" "$out"; then
        echo "  self-test ok: refuses the non-exempt raise, and only that one"
    else
        echo "  self-test FAIL: named the wrong row, or refused the exempt row too"
        st_fail=1
    fi

    # NARROWNESS CONTROL: the sibling slice is a real source file that happens to live in the
    # same directory. Raising ITS ceiling must still be refused — the exemption is one row, not
    # a directory. This is the case that reddens if the pattern is ever widened to lib/pithead/*.
    seq 1 600 >"$tmp4/lib/pithead/01-prelude.sh"
    printf '# test budget\nbudgeted.sh\t500\nlib/pithead/01-prelude.sh\t600\nlib/pithead/99-remainder.sh\t600\n' \
        >"$tmp4/$BUDGET_FILE"
    rc=0
    (cd "$tmp4" && run_gate) >"$out" 2>&1 || rc=$?
    expect "control: the exemption is ONE row, not lib/pithead/ — a sibling slice still FAILS" 1 "$rc"
    if grep -q "raises lib/pithead/01-prelude.sh's ceiling" "$out"; then
        echo "  self-test ok: names the sibling slice, so the exemption did not leak to it"
    else
        echo "  self-test FAIL: the exemption leaked to a sibling lib/pithead slice"
        st_fail=1
    fi
    seq 1 500 >"$tmp4/lib/pithead/01-prelude.sh"

    # A rise must RECORD the artifact, never reserve headroom. Otherwise one PR sets the row to
    # any number it likes and nothing objects again until the file reaches it — a ratchet in
    # name only. The file is 600 here, so a row of 999999 is a headroom grant, not a measurement.
    printf '# test budget\nbudgeted.sh\t500\nlib/pithead/01-prelude.sh\t500\nlib/pithead/99-remainder.sh\t999999\n' \
        >"$tmp4/$BUDGET_FILE"
    rc=0
    (cd "$tmp4" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a rise on the exempt row must match the file, not reserve headroom" 1 "$rc"
    if grep -q "but the file is 600 lines" "$out"; then
        echo "  self-test ok: names the count the row should have stated"
    else
        echo "  self-test FAIL: did not name the mismatch between row and file"
        st_fail=1
    fi

    # The exempt row is still a real per-PR measurement: run_gate's `lines > ceiling` rule is
    # untouched, so growing the artifact without recording the new count still REDs.
    seq 1 700 >"$tmp4/lib/pithead/99-remainder.sh"
    printf '# test budget\nbudgeted.sh\t500\nlib/pithead/01-prelude.sh\t500\nlib/pithead/99-remainder.sh\t600\n' \
        >"$tmp4/$BUDGET_FILE"
    rc=0
    (cd "$tmp4" && run_gate) >"$out" 2>&1 || rc=$?
    expect "the exempt row is not a free pass: growing past it still FAILS" 1 "$rc"
    if grep -q "99-remainder.sh is 700 lines, over its recorded ceiling of 600" "$out"; then
        echo "  self-test ok: names the unrecorded growth"
    else
        echo "  self-test FAIL: did not name the unrecorded growth"
        st_fail=1
    fi
    rm -rf "$tmp4"

    # #1470 — a row with NO counterpart on the base ref is a first appearance, not a raise, so
    # the monotonic loop above never visits it. Its own repo, so the 500/900 base state above
    # cannot leak into it.
    local tmp5
    tmp5=$(mktemp -d)
    git -C "$tmp5" init -q -b develop
    git -C "$tmp5" config user.email test@example.invalid
    git -C "$tmp5" config user.name test
    mkdir -p "$tmp5/$(dirname "$BUDGET_FILE")"
    seq 1 500 >"$tmp5/budgeted.sh"
    printf '# test budget\nbudgeted.sh\t500\n' >"$tmp5/$BUDGET_FILE"
    git -C "$tmp5" add -A && git -C "$tmp5" commit -q -m base

    seq 1 500 >"$tmp5/newfile.sh"
    printf '# test budget\nbudgeted.sh\t500\nnewfile.sh\t900\n' >"$tmp5/$BUDGET_FILE"
    rc=0
    (cd "$tmp5" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a new row reserving headroom above the file's real size FAILS (#1470)" 1 "$rc"
    if grep -q "adds newfile.sh as a new row at ceiling 900, but the file is 500 lines" "$out"; then
        echo "  self-test ok: names the reserved headroom"
    else
        echo "  self-test FAIL: did not name the reserved headroom"
        st_fail=1
    fi

    printf '# test budget\nbudgeted.sh\t500\nnewfile.sh\t500\n' >"$tmp5/$BUDGET_FILE"
    rc=0
    (cd "$tmp5" && run_gate) >"$out" 2>&1 || rc=$?
    expect "control: a new row stating the file's real count on first appearance passes" 0 "$rc"
    rm -rf "$tmp5"

    rc=0
    (
        cd "$tmp" || exit 90
        list_candidates() { :; }
        run_gate
    ) >"$out" 2>&1 || rc=$?
    expect "an empty candidate scan FAILS loudly, never a vacuous pass" 1 "$rc"

    local tmp2
    tmp2=$(mktemp -d)
    git -C "$tmp2" init -q -b develop
    git -C "$tmp2" config user.email test@example.invalid
    git -C "$tmp2" config user.name test
    rc=0
    (cd "$tmp2" && run_gate) >"$out" 2>&1 || rc=$?
    expect "a repo with zero tracked files FAILS loudly (enumeration guard)" 1 "$rc"
    rm -rf "$tmp2"

    if [ "$st_fail" -eq 0 ]; then
        echo "lint-file-budget self-test OK"
        return 0
    fi
    echo "lint-file-budget self-test FAILED"
    return 1
}

self_test
exit $?
