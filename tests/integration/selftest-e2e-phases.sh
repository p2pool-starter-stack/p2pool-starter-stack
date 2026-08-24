#!/usr/bin/env bash
#
# Self-test for e2e.sh's phase composition (#1364): which run.sh phases each --mode actually
# launches with. The defect this locks down was invisible because it was an ABSENCE — the
# rigforge-control phase was gated on `--mode matrix` while docs/dev/releasing.md mandates
# `--mode targeted` before every cut, so the whole dashboard-to-rig write surface
# (#513/#514/#516/#517/#1002b/#1236) was never even REQUESTED by the gate that decides whether a
# release ships. Nothing in the output mentioned it; there was no skip line to notice.
#
# It runs the REAL run_harness out of e2e.sh (extracted, then evaluated against stubbed ssh) and
# reads the phase list off the command that would have been launched — not off a re-implementation
# of the gate, which would pass happily while the shipped file said something else.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's own file-budget
# ceiling — same reasoning as selftest-rigforge-apply-settle.sh. Run directly, or via
# `make test-integration-selftest`. No server, no bench, no rig.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

E2E_SRC="$HERE/e2e.sh"
RUN_SRC="$HERE/run.sh"

# --- Extract run_harness from the shipped e2e.sh --------------------------------------------
# Fail CLOSED: if a refactor moves or renames the function this must go red, never silently stop
# testing. A self-test whose subject quietly evaporates is the exact shape of gate this file exists
# to catch, so the extraction is asserted before anything is evaluated.
HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$E2E_SRC")"
# An empty extraction fails this too — "" does not open and close — so no separate non-empty guard.
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "
assert_contains "the extracted function still composes the rigforge phases" \
    "$HARNESS_SRC" '--rigforge-control'

# --- Drive it with ssh stubbed out ----------------------------------------------------------
# Every on_bench call is recorded; the harness is told its run finished immediately with rc 0, so
# the poll loop never sleeps. The one call we read back is the `nohup ./.e2e-run.sh` launch, which
# carries the phase list verbatim — the same string the bench would have executed.
compose_phases() { # <mode> <borrow_miner> -> the phase list e2e.sh would launch run.sh with
    local launch
    # SC2034/SC2329: the config vars and the log/step/warn/ok/die/on_bench stubs below are all read
    # and called by the eval'd run_harness, which shellcheck cannot follow into.
    # shellcheck disable=SC2034,SC2329
    launch="$(
        MODE="$1" BORROW_MINER="$2" WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e
        LAUNCH_LINE=""
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() {
            echo "DIE: $*" >&2
            exit 1
        }
        on_bench() {
            case "$1" in
            # The launch command names the done-marker too (it rm -f's it first), so match the
            # launch FIRST — reversing these two makes every phase assertion pass vacuously.
            *nohup*) LAUNCH_LINE="$1" ;;
            *e2e-harness.done*)
                # `test -f <done>` (the poll) and `cat <done>` (the exit code) share this substring;
                # answering 0 to both ends the loop on its first pass with a clean harness result.
                echo 0
                return 0
                ;;
            esac
            return 0
        }
        eval "$HARNESS_SRC"
        run_harness >/dev/null 2>&1
        # The one line worth keeping. A run that never reaches the launch yields an empty capture,
        # which fails the exact-set assertions loudly rather than reporting a stale answer.
        printf '%s\n' "$LAUNCH_LINE"
    )"
    # Everything between the runner's positional args and the trailing redirect is the phase list.
    sed -n 's/.*\.e2e-run\.sh[^ ]* [^ ]* [^ ]* \(.*\) >\/dev\/null.*/\1/p' <<<"$launch"
}

has_phase() { # <phase-list> <flag> -> "yes" | "no"
    case " $1 " in *" $2 "*) echo yes ;; *) echo no ;; esac
}

# The EXACT set a mode launches, order- and whitespace-independent. This is the fail-closed half:
# per-flag has_phase checks are a denylist — they can only catch the absences someone thought of,
# and a mutation that ADDS a destructive phase to --mode check walked straight through them.
phase_set() { # <phase-list> -> the flags, sorted, space-joined
    # shellcheck disable=SC2086  # deliberate word-splitting: the phase list is a flag string
    printf '%s\n' $1 | LC_ALL=C sort | tr '\n' ' '
}

echo "== the mandated pre-cut gate (--mode targeted) reaches the write surface (#1364) =="
TARGETED="$(compose_phases targeted 1)"
assert_eq "targeted requests the rigforge-control WRITE phase (#1364)" \
    "$(has_phase "$TARGETED" --rigforge-control)" "yes"
assert_eq "targeted launches EXACTLY its documented phases, and nothing else" \
    "$(phase_set "$TARGETED")" "--auth-fail-closed --lifecycle --rigforge --rigforge-control "

echo "== --mode matrix keeps everything it had =="
MATRIX="$(compose_phases matrix 1)"
assert_eq "matrix still requests the rigforge-control WRITE phase" \
    "$(has_phase "$MATRIX" --rigforge-control)" "yes"
assert_eq "matrix launches EXACTLY its documented phases, and nothing else" \
    "$(phase_set "$MATRIX")" \
    "--auth-fail-closed --fault-injection --hardening --lifecycle --rigforge --rigforge-control --safety-backup --subnet "

echo "== --mode check stays non-destructive (pure reads) =="
CHECK="$(compose_phases check 1)"
assert_eq "check does NOT request the write phase" \
    "$(has_phase "$CHECK" --rigforge-control)" "no"
assert_eq "check launches EXACTLY --check — no destructive phase may ever join it" \
    "$(phase_set "$CHECK")" "--check "

echo "== --no-miner: no rig means no rig phases, and the mining asserts are skipped (#905) =="
NOMINER="$(compose_phases targeted 0)"
assert_eq "no borrowed miner => no write phase (there is no rig to write to)" \
    "$(has_phase "$NOMINER" --rigforge-control)" "no"
assert_eq "no borrowed miner => EXACTLY the rig-free phases, plus --no-mining-asserts (#905)" \
    "$(phase_set "$NOMINER")" "--auth-fail-closed --lifecycle --no-mining-asserts "

echo "== the flag e2e.sh emits is one run.sh actually parses =="
# run.sh's parser ends in `-*) die "Unknown option"`, so a phase e2e.sh invents is not a no-op —
# it kills the whole harness run. Assert the handshake rather than trusting the two files agree.
for flag in $(printf '%s %s %s %s' "$TARGETED" "$MATRIX" "$CHECK" "$NOMINER" | tr ' ' '\n' | grep . | LC_ALL=C sort -u); do
    assert_eq "run.sh's arg parser accepts '$flag'" \
        "$(grep -cE "^[[:space:]]*(\-\-[a-z-]+ \| )*${flag}\)" "$RUN_SRC" | awk '{print ($1>0)?"yes":"no"}')" "yes"
done

echo ""
echo "selftest-e2e-phases: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
