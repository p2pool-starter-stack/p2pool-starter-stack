#!/usr/bin/env bash
#
# Self-test for the harness's skip accounting (#1365).
#
# The defect this locks down was an ABSENCE. The harness had exactly three counter increments —
# IT_PASS, IT_FAIL, and the scenario skip — so every leg-level and phase-level drop incremented
# nothing and appeared in no column. A run that dropped the entire rigforge-control phase and a
# run that exercised it produced summaries differing only in the pass count, and the pass count
# moves for a dozen unrelated reasons. Nothing in the output could say "this did not run", which
# leaves a reader unable to tell "checked and clean" from "never ran" — the distinction a release
# gate exists to make.
#
# Two halves, and the second is the one that keeps the fix alive:
#   1. the counters and the named list behave (each helper moves its OWN bucket, records what and
#      why), and the REAL summary() out of run.sh renders all three buckets and the names;
#   2. a CENSUS of the shipped harness: no skip may go out through a bare `it_warn` again. That is
#      the regression the fix was for — 34 sites had drifted in one at a time, each individually
#      reasonable, and a test that only checked the helpers would stay green through every one of
#      them coming back.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's file-budget ceiling —
# same reasoning as selftest-e2e-phases.sh. Run directly, or via `make test-integration-selftest`.
# No server, no bench, no rig.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

RUN_SRC="$HERE/run.sh"

echo "== the three counted-skip helpers exist at all (fail closed if one is renamed away) =="
# --- The helpers exist at all -----------------------------------------------------------------
# Fail CLOSED. If a refactor renames or removes one, this file must go red rather than quietly
# stop testing — a self-test whose subject evaporates is the same shape of lie it exists to catch.
for fn in it_skip_scenario it_skip_phase it_skip_leg; do
    assert_eq "lib.sh defines $fn" "$(type -t "$fn")" "function"
done

echo "== each helper moves its OWN bucket, and a helper without its increment counts nothing =="
# --- Each helper moves its OWN bucket, and only its own ----------------------------------------
# Run in a subshell with the warn output discarded: the subject here is the counters, not the text.
counts() { # <helper> -> "<scenarios> <phases> <legs>"
    (
        "$1" "some-name" "some-reason" 2>/dev/null
        printf '%s %s %s' "$IT_SKIPPED" "$IT_SKIPPED_PHASES" "$IT_SKIPPED_LEGS"
    )
}
assert_eq "a scenario skip increments only the scenario bucket" "$(counts it_skip_scenario)" "1 0 0"
assert_eq "a phase skip increments only the phase bucket" "$(counts it_skip_phase)" "0 1 0"
assert_eq "a leg skip increments only the leg bucket" "$(counts it_skip_leg)" "0 0 1"

# Mutation proof for the counting itself: a helper whose increment is removed must NOT still read
# as counted. Without this the three assertions above would pass against a body that only warns.
_mutated="$(
    it_skip_leg() { _it_skip_record "leg     " "$1" "$2" "missing"; } # the increment, deliberately gone
    it_skip_leg "some-name" "some-reason"
    printf '%s' "$IT_SKIPPED_LEGS"
)"
assert_eq "an it_skip_leg with its increment removed counts 0 (mutation proof)" "$_mutated" "0"

echo "== every skip is NAMED with its reason, and a phase drop is louder than a leg drop =="
# --- Every skip is NAMED, with its reason ------------------------------------------------------
# A bare count says how big the hole is and nothing about where. The names are the deliverable.
_names="$(
    it_skip_phase "rigforge-control" "no rig attached" 2>/dev/null
    it_skip_leg "pools write (#1002b)" "no IT_RIG_POOLS_PROBE" 2>/dev/null
    printf '%b' "$IT_SKIPPED_NAMES"
)"
assert_contains "the named list carries the phase name" "$_names" "rigforge-control"
assert_contains "the named list carries the phase reason" "$_names" "no rig attached"
assert_contains "the named list carries the leg name" "$_names" "pools write (#1002b)"
assert_contains "the named list carries the leg reason" "$_names" "no IT_RIG_POOLS_PROBE"
assert_contains "a phase drop is marked louder than a leg drop" "$_names" "PHASE"

# The warn text a live run actually shows must say which kind of drop it was — the operator reads
# the stream, not the summary, while the run is still going.
_warned="$(
    it_skip_phase "rigforge-control" "no rig attached" 2>&1
    it_skip_leg "pools write (#1002b)" "no IT_RIG_POOLS_PROBE" 2>&1
)"
assert_contains "a phase drop announces itself as a whole phase" "$_warned" "SKIPPED WHOLE PHASE rigforge-control"
assert_contains "a leg drop announces itself as one leg" "$_warned" "skipped leg pools write (#1002b)"

echo "== the REAL summary() out of run.sh reports all three buckets and names the omissions =="
# --- The REAL summary() out of run.sh renders all three buckets --------------------------------
# Extracted rather than re-spelled: a re-implementation would pass happily while the shipped file
# printed something else, which is precisely the class of green this lane exists to remove.
SUMMARY_SRC="$(sed -n '/^summary() {$/,/^}$/p' "$RUN_SRC")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$SUMMARY_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "summary() { } "

render_summary() { # -> summary output, both streams, with the given counters
    (
        eval "$SUMMARY_SRC"
        # Read by the eval'd summary(), which shellcheck cannot see into.
        # shellcheck disable=SC2034
        OUT_DIR="/nonexistent"
        # summary() reads the same globals this file's own assertions write, so a failure HERE
        # would otherwise surface as a failure of the simulated run. Isolate the pass/fail state;
        # the skip counters are what is under test and stay as the caller set them.
        IT_FAIL=0
        IT_FAILED_NAMES=""
        summary 2>&1
    )
}

_rendered="$(
    {
        it_skip_scenario "prune-remote" "no pruned chain supplied"
        it_skip_phase "rigforge-control" "no rig attached"
        it_skip_leg "pools write (#1002b)" "no IT_RIG_POOLS_PROBE"
        it_skip_leg "rig upgrade (#1002a)" "rig reports no clean version"
    } 2>/dev/null
    IT_PASS=7
    render_summary
)"
assert_contains "the summary reports all three buckets separately" "$_rendered" "skipped: 1 scenarios, 1 phases, 2 legs"
assert_contains "the summary still reports the pass count" "$_rendered" "passed:  7"
assert_contains "the summary lists what did NOT run" "$_rendered" "did NOT run:"
assert_contains "the summary names the dropped phase" "$_rendered" "rigforge-control"
assert_contains "the summary names a dropped leg" "$_rendered" "pools write (#1002b)"
assert_contains "the summary names the second dropped leg" "$_rendered" "rig upgrade (#1002a)"

# A clean run must not grow a hollow "did NOT run:" header with nothing under it.
_clean="$(
    IT_PASS=3
    render_summary
)"
assert_contains "a clean run reports zeroes in every bucket" "$_clean" "skipped: 0 scenarios, 0 phases, 0 legs"
case "$_clean" in
*"did NOT run"*) it_fail "a run that skipped nothing prints no omissions block" "got [$_clean]" ;;
*) it_pass "a run that skipped nothing prints no omissions block" ;;
esac

echo "== census: no skip may leave the harness through a bare it_warn, by wording OR by shape =="
# --- CENSUS: no skip may leave through a bare it_warn again ------------------------------------
# The counted helpers are the only sanctioned exit for a skip. This is the half that holds: the 34
# converted sites drifted in one at a time over the harness's life, and each looked reasonable on
# its own. `it_warn` stays for genuine warnings — a cleanup that did not fully land, a degraded
# input — which is why the census matches on skip WORDING rather than banning the call.
census_wording() { # <file> -> skip warnings that never reach a counter
    grep -n 'it_warn' "$1" |
        grep -Ei 'skipp(ed|ing)' |
        grep -v 'it_warn "SKIPPED scenario' |
        grep -v 'it_warn "▲ SKIPPED WHOLE PHASE' |
        grep -v 'it_warn "skipped leg'
}

# The wording rule only catches a drop that SAYS "skipping". It missed one worded "not exposed
# here" that returned 0 immediately after — so this second rule matches the SHAPE instead: a
# warning followed straight away by `return 0` is a leg that did not run, whatever its prose.
# Between them they cover both the drops that announce themselves and the ones that do not.
#
# One legitimate warn-then-return exists and is allowlisted by name rather than by a looser
# regex: `--keep:` reports a deliberate cleanup that was skipped on purpose, not coverage lost.
# Keeping the allowlist explicit means a NEW warn-then-return has to be looked at by a human
# before it can be waved through, which is the whole point.
census_shape() { # <file> -> warn-then-return-0 sites that are not counted skips
    awk '
        /it_warn/ { w = NR; t = $0; next }
        w && NF {
            if ($0 ~ /^[[:space:]]*return 0[[:space:]]*$/ && t !~ /--keep:/) print w ": " t
            w = 0
        }
    ' "$1"
}
census() { # <file> -> every uncounted skip, by either rule
    census_wording "$1"
    census_shape "$1"
}
# Globbed, not enumerated, for the same reason the Makefile target is: an enumerated list
# silently omits any harness file added later, and a check that never runs reads exactly like one
# that passed. Self-tests are excluded — they stub and assert ON this wording.
for f in "$HERE"/*.sh; do
    case "$(basename "$f")" in selftest*) continue ;; esac
    _stray="$(census "$f")"
    assert_eq "no uncounted skip survives in $(basename "$f")" "${_stray:-none}" "none"
done

# And the census can actually FIRE — a guard nobody has seen go red is a guard nobody should
# trust. Feed it a file holding exactly the shape it must catch.
_tmp="$(mktemp)"
printf '%s\n' 'it_warn "skipping the pools write leg (no probe)"' >"$_tmp"
assert_ne "the wording rule fires on a bare-warn skip (positive control)" "$(census_wording "$_tmp")" ""
printf '%s\n' '    it_warn "not exposed here"' '    return 0' >"$_tmp"
assert_ne "the shape rule fires on a warn-then-return with no skip wording (positive control)" \
    "$(census_shape "$_tmp")" ""
assert_eq "the wording rule alone would MISS that one (this is why both rules exist)" \
    "$(census_wording "$_tmp")" ""
printf '%s\n' 'it_warn "restore apply reported a non-zero exit; check the box."' >"$_tmp"
assert_eq "the wording rule leaves a genuine non-skip warning alone (negative control)" "$(census_wording "$_tmp")" ""
printf '%s\n' '    it_warn "--keep: leaving the safety backup"' '    return 0' >"$_tmp"
assert_eq "the shape rule leaves the allowlisted --keep cleanup alone (negative control)" \
    "$(census_shape "$_tmp")" ""
rm -f "$_tmp"

echo "== every skip carries a CLASS, and only \"missing\" is a gap (#1083) =="
# --- The class axis (#1083) --------------------------------------------------------------------
# #1365 made the harness say WHAT did not run. It still could not say whether a hole was one we
# had accepted or one we could have filled that day, which is exactly why five stable scenario
# skips read as "known and fine" for months. The class is that missing axis, and its whole value
# is that ONE of the three buckets is a gap and the other two are not.
classes() { # <helper> <class...> -> "<by-design> <covered> <missing>"
    (
        "$1" "some-name" "some-reason" ${2+"$2"} 2>/dev/null
        printf '%s %s %s' "$IT_SKIPPED_BY_DESIGN" "$IT_SKIPPED_COVERED" "$IT_SKIPPED_MISSING"
    )
}
assert_eq "an unclassified skip defaults to missing, the pessimistic bucket" "$(classes it_skip_leg)" "0 0 1"
assert_eq "an explicit by-design skip lands in by-design only" "$(classes it_skip_leg by-design)" "1 0 0"
assert_eq "an explicit covered skip lands in covered only" "$(classes it_skip_phase covered)" "0 1 0"
assert_eq "a scenario skip is classified too, not just legs" "$(classes it_skip_scenario by-design)" "1 0 0"

# The default is the load-bearing half: if it ever flips to a non-gap bucket, every unannotated
# skip in the harness silently stops counting as a hole — the #1083 failure mode, one level up.
# Mutation proof, so the assertion above cannot pass against a body that defaults the other way.
_mutdefault="$(
    it_skip_leg() {
        IT_SKIPPED_LEGS=$((IT_SKIPPED_LEGS + 1))
        _it_skip_record "leg     " "$1" "$2" "${3:-covered}"
    }
    it_skip_leg "some-name" "some-reason" 2>/dev/null
    printf '%s %s' "$IT_SKIPPED_COVERED" "$IT_SKIPPED_MISSING"
)"
assert_eq "a default flipped to covered is visible (mutation proof)" "$_mutdefault" "1 0"

# An unknown class must be LOUD and must still be counted. Counting it nowhere would break the
# reconciliation below, and a summary whose own totals do not add up misleads more than a bad label.
_unknown="$(
    it_skip_leg "some-name" "some-reason" "bydesign" 2>&1
    printf '|%s %s %s' "$IT_SKIPPED_BY_DESIGN" "$IT_SKIPPED_COVERED" "$IT_SKIPPED_MISSING"
)"
assert_contains "an unknown class is reported, not silently bucketed" "$_unknown" "unknown skip class 'bydesign'"
assert_contains "an unknown class still lands in the pessimistic bucket" "$_unknown" "|0 0 1"

# Reconciliation: the three class totals must always sum to the three bucket totals. This is what
# makes the breakdown citable — without it the two lines could drift apart and both look fine.
_recon="$(
    {
        it_skip_scenario "s" "r" by-design
        it_skip_phase "p" "r" covered
        it_skip_leg "l1" "r"
        it_skip_leg "l2" "r" by-design
    } 2>/dev/null
    printf '%s %s' "$((IT_SKIPPED + IT_SKIPPED_PHASES + IT_SKIPPED_LEGS))" \
        "$((IT_SKIPPED_BY_DESIGN + IT_SKIPPED_COVERED + IT_SKIPPED_MISSING))"
)"
assert_eq "class totals reconcile with bucket totals" "$_recon" "4 4"

echo "== the REAL summary() renders the class breakdown, and the named list tags each drop =="
_rendered_cls="$(
    {
        it_skip_scenario "prune-remote" "no pruned chain supplied"
        it_skip_phase "hardening" "remote mode: no local containers" by-design
        it_skip_leg "Worker Inspect read/write (#185)" "covered by the hardening phase" covered
    } 2>/dev/null
    IT_PASS=7
    render_summary
)"
assert_contains "the summary breaks the skips down by class" "$_rendered_cls" \
    "of which: 1 missing (an input would have run it), 1 by-design"
assert_contains "the breakdown names the covered bucket too" "$_rendered_cls" "1 covered elsewhere"
assert_contains "the named list tags a by-design drop" "$_rendered_cls" "[by-design]"
assert_contains "the named list tags a covered drop" "$_rendered_cls" "[covered]"
assert_contains "the named list tags an unannotated drop as missing" "$_rendered_cls" "[missing]"

echo "== census: every class argument in the shipped harness is one of the three (#1083) =="
# --- CENSUS: no call site may invent a class ---------------------------------------------------
# The runtime guard above only fires on a path that actually RUNS, and most of these skip sites
# fire only on a bench with a rig attached. A typo like "bydesign" on a leg that skips once a
# quarter would sit in the tree unnoticed. This census is static, so it sees every site every run.
census_class() { # <file> -> call sites whose trailing class argument is not one of the three
    grep -nE 'it_skip_(scenario|phase|leg) .*"[a-z-]+"[[:space:]]*$' "$1" |
        grep -vE '"(by-design|covered|missing)"[[:space:]]*$'
}
for f in "$HERE"/*.sh; do
    case "$(basename "$f")" in selftest*) continue ;; esac
    _badcls="$(census_class "$f")"
    assert_eq "no invented skip class in $(basename "$f")" "${_badcls:-none}" "none"
done

# ...and it can fire. A near-miss is the case that matters: an obviously-wrong class would be
# caught by eye, a missing hyphen would not.
_tmp2="$(mktemp)"
printf '%s\n' '    it_skip_leg "some leg" "some reason" "bydesign"' >"$_tmp2"
assert_ne "the class census fires on a near-miss class (positive control)" "$(census_class "$_tmp2")" ""
printf '%s\n' '    it_skip_leg "some leg" "some reason" "by-design"' >"$_tmp2"
assert_eq "the class census leaves a valid class alone (negative control)" "$(census_class "$_tmp2")" ""
printf '%s\n' '    it_skip_leg "some leg" "a reason ending in a word"' >"$_tmp2"
assert_eq "the class census leaves a plain two-argument call alone (negative control)" "$(census_class "$_tmp2")" ""
rm -f "$_tmp2"

echo "selftest-skip-accounting: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
