#!/usr/bin/env bash
#
# Self-test for the harness's ABORT TRAPS (#1401): every `trap` in tests/integration/ that exists to
# unwind on an abort must name `EXIT` and nothing else. Standalone (not sourced by selftest.sh) so it
# never touches that file's budget ceiling — the #1258/#1301 "moved into its own file" precedent. Run
# directly, or via `make test-integration-selftest`. No server needed.
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

# The signal list of a `trap` line: everything after the handler argument.
trap_signals() { # <file> <extended-regex matching the whole trap line>
    local line
    line="$(grep -hE "$2" "$1" | head -n1)"
    [ -n "$line" ] || {
        echo "__NO_TRAP_LINE_MATCHED__"
        return
    }
    # Strip the leading `trap` and the handler (quoted or bare), leaving the signal names.
    printf '%s\n' "$line" | sed -E "s/^trap[[:space:]]+('[^']*'|\"[^\"]*\"|[^[:space:]]+)[[:space:]]*//"
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

echo "== the shipped abort traps name EXIT and nothing else =="
# e2e.sh: restore_all is the borrowed rig's only unwind. If this reds, read the block above before
# "fixing" it by re-adding the signals — that is the change this file exists to refuse.
sigs="$(trap_signals "$HERE/e2e.sh" '^trap[[:space:]]+restore_all[[:space:]]')"
assert_ne "e2e.sh's restore_all trap line was found at all" "$sigs" "__NO_TRAP_LINE_MATCHED__"
assert_eq "e2e.sh traps restore_all on EXIT alone (#1401)" "$sigs" "EXIT"

# tor-client/probe.sh: same class, different consequence — naming the signals would kill tor and
# then carry on into the bootstrap wait, spending BOOT_TIMEOUT to report a wrong diagnosis.
sigs="$(trap_signals "$HERE/tor-client/probe.sh" "^trap[[:space:]]+'kill")"
assert_ne "probe.sh's tor-kill trap line was found at all" "$sigs" "__NO_TRAP_LINE_MATCHED__"
assert_eq "probe.sh traps the tor kill on EXIT alone (#1401)" "$sigs" "EXIT"

echo ""
echo "selftest-abort-traps: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
