#!/usr/bin/env bash
#
# Self-test for the harness's ABORT TRAPS (#1401): WALKS every `*.sh` under tests/integration/ and
# asserts that each `trap` statement names `EXIT` and nothing else. It checked two hardcoded (file,
# handler) pairs until #1515, and the walk is the fix: measured, the two-site version stayed green
# against all three shapes that reintroduce the defect — a signal added to a file the change never
# touched, a brand-new selftest, and a second handler beside the guarded one inside e2e.sh itself.
# The scan is `*.sh` only; verified at the time of writing that no shell file under this directory
# lacks that extension, so nothing is currently out of reach, but one added later would be.
# The scan finds the population; a CLASSIFIER then reads each hit, and #1567 was two faults in
# that half — a handler strip that could not span the `'\''` idiom, and a `trap …` literal held
# as test data being asserted against as though this tree installed it. Both are fixed below, at
# `trap_line_signals` and `trap_hit_is_data`, which carry the rules rather than have them
# restated here — a recipe written in two places is one that drifts apart.
# Standalone (not sourced by selftest.sh) so it never touches that file's budget ceiling — the
# #1258/#1301 "moved into its own file" precedent. Run directly, or via
# `make test-integration-selftest`. No server needed.
#
# WHAT THIS EXISTS TO STOP, and why a comment alone would not have. `trap handler EXIT INT TERM` is
# the common idiom and it READS as more careful than bare `EXIT`, so it gets re-added by anyone who
# has not measured it. Measured here rather than assumed: a bare EXIT trap already runs when the
# shell dies of SIGINT or SIGTERM, so naming the signals adds no coverage — what it adds is that
# **a bash INT/TERM handler that RETURNS does not die.** The shell resumes at the next command.
#
# For e2e.sh that was a FALSE GREEN, not a redundant teardown: on a Ctrl-C or a cancelled CI job,
# restore_all ran the full unwind (miner pool restored, baseline stack redeployed), set its RESTORED
# guard, returned — and the run CARRIED ON, measuring the restored baseline stack instead of the
# branch under test, then exited 0. The guard is what made the second firing a no-op, so nothing
# unwound the continuation either. An aborted release-gate run reporting success is this harness's
# founding defect class, which is why the guard is a behavioural test and not a comment.
#
# THE CONTROLS ARE THE POINT. "Did the signal kill it" is unmeasurable without a row whose only
# correct answer is death: two plausible harnesses each reported a confident, wrong "it survived"
# before this one. An async job inherits SIGINT **ignored** and `trap - INT` cannot undo it (a signal
# ignored at shell entry stays ignored), and a bash waiting on a foreground child **swallows** a
# SIGINT the child never received — so signalling the shell's pid alone does not model a Ctrl-C.
# `set -m` fixes both: it puts each background job in its own process group AND leaves its signal
# dispositions at default, so the trial can signal the GROUP, as a terminal does. If the no-trap
# rows below ever stop dying, the instrument is broken and nothing under it means anything.
#
set -m -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

TRIAL_DIR="$(mktemp -d)"
TRIAL_FIRED=0
TRIAL_CONTINUED=0
TRIAL_RC=0
trap 'rm -rf "$TRIAL_DIR"' EXIT # bare EXIT, for the reason this whole file is about

# Run one trial: a victim script with trap spec $1, signalled with $2 delivered to its process
# GROUP, as a terminal does. Sets TRIAL_FIRED / TRIAL_CONTINUED / TRIAL_RC.
#
# It must run in THIS shell and hand its results back through globals rather than through $(...),
# because command substitution is a SUBSHELL and job control does not cross into one: measured, a
# background child started inside $(...) is left in the PARENT's process group even with `set -m`
# re-issued there. Two ways that matters. The group kill then finds no such group and every trial
# reports "it survived" — which is what the controls below caught when this file was first written.
# And had the group existed, `kill -- -$pid` would have signalled THIS suite instead of the victim.
abort_trial() { # <trap-spec, "" for none> <signal>
    local spec="$1" sig="$2" tag out src pid spun
    tag="$(printf '%s.%s' "${spec// /_}" "$sig")"
    out="$TRIAL_DIR/${tag:-none}.out"
    src="$TRIAL_DIR/${tag:-none}.sh"
    printf 'h() { echo FIRED >>"%s"; }\n' "$out" >"$src"
    [ -n "$spec" ] && printf 'trap h %s\n' "$spec" >>"$src"
    printf 'echo READY >>"%s"\n' "$out" >>"$src"
    printf 'for _ in $(seq 150); do sleep 0.02; done\n' >>"$src"
    printf 'echo CONTINUED >>"%s"\n' "$out" >>"$src"
    : >"$out"
    bash "$src" &
    pid=$!
    spun=0
    while ! grep -q READY "$out" 2>/dev/null; do
        sleep 0.01
        spun=$((spun + 1))
        [ "$spun" -gt 1000 ] && break # never hang the suite on a victim that failed to start
    done
    # The victim is a process-group leader (`set -m`, top of file) so this reaches it and nothing
    # else. Job-control notices for the reap are noise; the caller drops them.
    kill -"$sig" -- "-$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    TRIAL_RC=$?
    TRIAL_FIRED="$(grep -c FIRED "$out")"
    TRIAL_CONTINUED="$(grep -c CONTINUED "$out")"
}

# THE HANDLER IS ONE SHELL WORD, AND A SHELL WORD IS A RUN OF CONCATENATED PIECES (#1567). Reading
# it as a single quoted run was the bug: `'echo it'\''s here'` is not one `'…'` but THREE pieces
# glued together with no whitespace between them — a quoted run, a backslash escape, a quoted run —
# because that escape is the only way bash lets an apostrophe inside single quotes. A one-alternative
# strip stops at the first inner quote and reads the remainder as the signal list, which reds a
# compliant line. The same fault hit `"echo \"hi\""`, a shape #1567 did not name.
#
# THE DIRECTION THAT MATTERS: this is more permissive than what it replaces, and a strip that goes
# too far eats the signals and reports `EXIT` for a line naming three — the #1401 false green, from
# inside the guard against it. It cannot: none of the four pieces matches whitespace outside quotes,
# so the run always ends at the space before the signal list. The cases below pin that with a row for
# every shape carrying BOTH an escaped quote and extra signals; each must still come back flagged.
_TRAP_SQ="'[^']*'"             # a single-quoted run — bash allows no escapes at all inside one
_TRAP_DQ='"([^"\]|\\.)*"'      # a double-quoted run, which may carry \" and \\
_TRAP_ESC='\\.'                # a bare backslash escape, the glue in the `'\''` idiom
_TRAP_BARE="[^[:space:]'\"\\]" # any other single character that is not whitespace or quoting
_TRAP_WORD="($_TRAP_SQ|$_TRAP_DQ|$_TRAP_ESC|$_TRAP_BARE)+"

# The signal list of one `trap` line: everything after the handler argument. The handler is stripped
# FIRST, so a `#` inside a quoted handler can never be read as a comment; only then is a trailing
# comment cut, which is safe because signal names contain no `#`. An optional `--` is skipped: that
# is the form `trap -p` itself prints, so it is what anyone round-tripping a captured handler writes.
# Leading indentation is allowed — two of the shipped traps are installed inside functions, and
# anchoring on a bare `^trap` would silently skip both, reporting a clean sweep over a population it
# never looked at.
trap_line_signals() { # <the text of one trap line>
    printf '%s\n' "$1" |
        sed -E "s/^[[:space:]]*trap[[:space:]]+(--[[:space:]]+)?${_TRAP_WORD}[[:space:]]*//" |
        sed -E 's/#.*$//; s/[[:space:]]+$//'
}

# A `trap …` line that is DATA — a literal inside a quoted heredoc or a string, written for some
# other process to execute — still sits at the start of a line, so the text scan finds it and the
# walk asserts against a trap nothing in this tree installs (#1567). The exemption is EXPLICIT and
# never inferred: the line immediately above must carry the marker. Inferring it instead — tracking
# heredoc regions, say — is how a REAL trap escapes the walk with nothing printed, and a silent hole
# in this guard is strictly worse than the false red it removes. Exempted lines are not asserted;
# they are printed and counted into the summary, because a limit that lives only in a source comment
# is invisible to whoever reads the output.
TRAP_DATA_MARKER='# selftest-abort-traps: data'
trap_hit_is_data() { # <file> <line number of the trap line>
    local above
    [ "$2" -gt 1 ] || return 1
    above="$(sed -n "$(($2 - 1))p" "$1")"
    # The marker must be the WHOLE line, indentation aside — never a substring. This file names the
    # marker in its own header and in the assignment above, and under a substring match any trap line
    # that came to follow one of those would be exempted: the guard reading its own documentation as
    # permission to stop looking. Same family as the literal-scanned-as-installed fault it fixes.
    [ "$(printf '%s' "$above" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')" = "$TRAP_DATA_MARKER" ]
}

echo "== CONTROLS: with no trap at all, the signal MUST kill the victim (#1401) =="
# Without these two rows a "survived" reading cannot be told from a signal that never landed.
for sig in INT TERM; do
    abort_trial "" "$sig" 2>/dev/null
    if [ "$TRIAL_CONTINUED" = "0" ] && [ "$TRIAL_FIRED" = "0" ]; then
        it_pass "control: SIG$sig kills an untrapped script, so the signal really lands"
    else
        it_fail "control: SIG$sig kills an untrapped script, so the signal really lands" \
            "the instrument is broken (fired=$TRIAL_FIRED continued=$TRIAL_CONTINUED) — every case below is meaningless"
    fi
done

echo "== a bare EXIT trap: fires ONCE and the script still dies (#1401) =="
for sig in INT TERM; do
    abort_trial "EXIT" "$sig" 2>/dev/null
    assert_eq "bare EXIT still runs the handler on SIG$sig — naming the signal adds no coverage" \
        "$TRIAL_FIRED" "1"
    assert_eq "and the script does NOT survive SIG$sig" "$TRIAL_CONTINUED" "0"
done

echo "== EXIT INT TERM: the handler returns, so the script RESUMES — the #1401 defect =="
for sig in INT TERM; do
    abort_trial "EXIT INT TERM" "$sig" 2>/dev/null
    assert_eq "EXIT INT TERM lets the script carry on past SIG$sig" "$TRIAL_CONTINUED" "1"
    assert_eq "  ...and exit 0, so an aborted run reports SUCCESS" "$TRIAL_RC" "0"
    assert_eq "  ...having fired the handler twice, the second a no-op behind any guard" \
        "$TRIAL_FIRED" "2"
done

echo "== the classifier reads one trap line correctly, and stays FAIL-LOUD doing it (#1567) =="
# Direct cases against trap_line_signals, because the walk can only ever exercise the shapes this
# tree happens to contain and the shapes that broke it are the ones nobody had written here yet. The
# expected value comes FIRST on each row so the row does not itself start with `trap` — otherwise the
# walk below would scan its own fixtures. Every escaped-quote shape appears TWICE, once compliant and
# once naming extra signals: the second row is the control, and it is the whole reason a more
# permissive strip is safe here. If a shape ever parses to `EXIT` in BOTH rows the guard has been
# switched off rather than fixed, which is the one outcome worse than the false red #1567 reports.
while IFS='|' read -r want line; do
    [ -n "$want" ] || continue
    assert_eq "signals of [$line]" "$(trap_line_signals "$line")" "$want"
done <<'CASES'
EXIT|trap cleanup EXIT
EXIT INT TERM|trap cleanup EXIT INT TERM
EXIT|trap 'rm -f $f' EXIT
EXIT|trap 'echo it'\''s here' EXIT
EXIT INT TERM|trap 'echo it'\''s here' EXIT INT TERM
EXIT|trap "echo \"hi\"" EXIT
EXIT TERM|trap "echo \"hi\"" EXIT TERM
EXIT|    trap rig_key_atexit EXIT
EXIT|trap 'rm -rf "$D"' EXIT # a trailing comment, cut only after the handler
EXIT|trap -- 'h' EXIT
EXIT INT|trap -- 'h' EXIT INT
CASES

echo "== an exemption is DECLARED, never inferred — and it is not blanket (#1567) =="
marker_fixture="$TRIAL_DIR/marker.sh"
{
    echo "$TRAP_DATA_MARKER"                                  # 1
    echo 'trap h EXIT INT TERM'                               # 2 — marked
    echo 'trap h EXIT INT TERM'                               # 3 — identical text, unmarked
    echo "# prose that mentions $TRAP_DATA_MARKER in passing" # 4
    echo 'trap h EXIT INT TERM'                               # 5 — under prose, not under a marker
    echo "    $TRAP_DATA_MARKER"                              # 6 — indented, as in a heredoc
    echo 'trap h EXIT INT TERM'                               # 7 — marked
} >"$marker_fixture"
assert_data() { # <description> <line number> <expected yes|no>
    local got=no
    trap_hit_is_data "$marker_fixture" "$2" && got=yes
    assert_eq "$1" "$got" "$3"
}
assert_data "a trap line under the marker is classified DATA, so the walk leaves it alone" 2 yes
# The negative control. Byte-identical text one line further down with no marker above it: were this
# also DATA the exemption would be blanket, and the walk would be asserting over nothing at all.
assert_data "control: the SAME line with no marker above it is NOT data" 3 no
# And the control for a SUBSTRING match, which is what a marker check reaches for first. Line 4 only
# mentions the marker — the shape this file's own header and assignment already have — so a
# substring match would exempt line 5 and the walk would stop looking wherever it was documented.
assert_data "control: a line that only MENTIONS the marker does not exempt the next line" 5 no
# Indentation is allowed: a marker inside an indented heredoc is the ordinary case, not an exception.
assert_data "an indented marker still declares the line under it data" 7 yes
# A hit on line 1 has no line above it to read; without the guard this is `sed -n 0p`, which errors.
assert_data "control: a trap on line 1 is not data, and asking does not error" 1 no

# ONE REAL MARKED LINE IN THIS TREE, deliberately. Nothing else proves the walk below actually
# CONSULTS trap_hit_is_data: a regression dropping that call stays green over a tree in which no line
# is marked. Here it is load-bearing both ways — drop the call and the walk reds on this literal, and
# the declared-data count asserted after it goes to zero.
noncompliant_literal="$(
    cat <<'LITERAL'
# selftest-abort-traps: data
trap h EXIT INT TERM
LITERAL
)"
assert_eq "the literal below is genuinely non-compliant — an exemption over nothing proves nothing" \
    "$(trap_line_signals "${noncompliant_literal##*$'\n'}")" "EXIT INT TERM"

echo "== every trap under tests/integration/ names EXIT and nothing else (#1401/#1515) =="
# A WALK, not a list of known sites: #1401's second live instance was found by enumerating the class,
# and a check wired to named sites cannot enumerate anything. If one of these reds, read the block at
# the top of this file before "fixing" it by re-adding the signals — that is the change this file
# exists to refuse.
#
# The scan reads the WORKING TREE, not `git ls-files`, so a file not yet `git add`ed is still swept;
# #1486 is this same kind of check made blind in exactly that way.
trap_scan="$(grep -rnE '^[[:space:]]*trap[[:space:]]' --include='*.sh' "$HERE")"

# Fed by a heredoc rather than a pipe on purpose: `grep ... | while` runs the loop body in a
# SUBSHELL, so every it_pass/it_fail it recorded would be discarded when the pipeline ended and the
# summary below would count zero of them while printing green.
TRAP_DATA_HITS=0
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    hit_file="${hit%%:*}"
    hit_rest="${hit#*:}"
    hit_line="${hit_rest%%:*}"
    if trap_hit_is_data "$hit_file" "$hit_line"; then
        TRAP_DATA_HITS=$((TRAP_DATA_HITS + 1))
        it_warn "declared DATA, NOT asserted (#1567): ${hit_file#"$HERE"/}:$hit_line"
        continue
    fi
    assert_eq "${hit_file#"$HERE"/}:$hit_line traps on EXIT alone (#1401)" \
        "$(trap_line_signals "${hit_rest#*:}")" "EXIT"
done <<EOF
$trap_scan
EOF

# Pinned exactly, not `>= 0`: every declared-data line is a hole in this walk, so one appearing or
# disappearing must red and be looked at rather than pass quietly. The one expected here is the
# literal above. If you added a marked line legitimately, raise this by one and say so on the PR.
assert_eq "exactly one line in this tree is declared data — a new one is a new hole in the walk" \
    "$TRAP_DATA_HITS" "1"

# The walk alone is silently green over a tree whose traps were all DELETED, and green is the wrong
# answer there: restore_all is the borrowed rig's only unwind, and probe.sh's kill is what stops a
# leaked tor. So require the two load-bearing sites to still be present, read out of the same scan
# rather than re-derived by a second mechanism that could drift from it.
assert_num_ge "the walk found trap statements at all — a 0 here is a broken scan, not a clean tree" \
    "$(printf '%s\n' "$trap_scan" | grep -c .)" "2"
assert_contains "e2e.sh's restore_all trap is still installed — the borrowed rig's only unwind" \
    "$trap_scan" "trap restore_all"
assert_contains "probe.sh's tor-kill trap is still installed (#1401's second site)" \
    "$trap_scan" "trap 'kill "

echo ""
# The declared-data count is in the SUMMARY, not just in a comment: it is the walk's own
# admission of what it did not look at, and the summary line is the only part anyone reads.
echo "selftest-abort-traps: $IT_PASS passed, $IT_FAIL failed, $TRAP_DATA_HITS declared data (not asserted)"
[ "$IT_FAIL" -eq 0 ] || exit 1
