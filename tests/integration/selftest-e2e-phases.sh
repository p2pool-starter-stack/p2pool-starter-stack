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
# The REAL rig_supply, not a re-spelling of it — same reason run_harness is extracted below (#1378).
# shellcheck source=tests/integration/rig-supply.sh
source "$HERE/rig-supply.sh"

E2E_SRC="$HERE/e2e.sh"
RUN_SRC="$HERE/run.sh"

assert_eq "rig-supply.sh actually defines rig_supply (#1378)" \
    "$(type -t rig_supply)" "function"

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
# Two things bite a stub here, and both cost a debugging pass.
#   * e2e.sh pipes the token INTO the launch call (`printf ... | on_bench ...`), and a pipeline runs
#     its right-hand function in a SUBSHELL — a stub recording into a variable captures nothing.
#     Record into files, which outlive it.
#   * The stub's `cat` must never be able to block. If a mutation removes the pipe, an unredirected
#     `cat` reads the SCRIPT's stdin and hangs forever, which reads as a mutation that "survived"
#     rather than one that killed. The subshell takes its stdin from /dev/null so it gets EOF.
drive_harness() { # <mode> <borrow_miner> [rig-token] -> "LAUNCH\t<cmd>" then "STDIN\t<piped>"
    local launch lf sf
    lf="$(mktemp)" sf="$(mktemp)"
    # SC2034/SC2329: the config vars and the log/step/warn/ok/die/on_bench stubs below are all read
    # and called by the eval'd run_harness, which shellcheck cannot follow into.
    # shellcheck disable=SC2034,SC2329
    launch="$(
        # Nothing in here may read the SCRIPT's stdin: an unpiped `cat` in the stub would hang, and
        # a hang reads as a mutation that survived. A pipeline still supplies its own stdin.
        exec </dev/null
        MODE="$1" BORROW_MINER="$2" WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e
        # rig_supply's inputs (#1378). MINER_HOST is what RIG_HOST defaults to; the token comes off
        # the stubbed on_miner, so the empty-token path is reachable by passing "".
        MINER_HOST=rig1 RIG_HOST="" IT_RIG_TOKEN="" RIGFORGE_CONFIG=/opt/rigforge/config.json
        STUB_TOKEN="${3-s3cr3t-tok3n}"
        LAUNCH_FILE="$lf" STDIN_FILE="$sf"
        on_miner() { printf '%s' "$STUB_TOKEN"; }
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
            *nohup*)
                printf '%s' "$1" >"$LAUNCH_FILE"
                # The launch is the one on_bench call e2e.sh pipes the token into (#1378).
                cat >"$STDIN_FILE"
                ;;
            # rig_supply's proof dial. Succeeds here; the unreachable-rig path is driven separately
            # by rc_of below, which is where the exit-code contract is asserted.
            *curl*Authorization*) return 0 ;;
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
        :
    )"
    # An empty capture means the harness never reached the launch. It is not swallowed: every
    # assertion below is an exact-set or exact-string match, so "" fails loudly rather than reading
    # as a clean answer.
    launch="$(printf 'LAUNCH\t%s\nSTDIN\t%s\n' "$(cat "$lf")" "$(cat "$sf")")"
    rm -f "$lf" "$sf"
    printf '%s\n' "$launch"
}

launch_of() { # <mode> <borrow> [token] -> the raw launch command string
    drive_harness "$@" | sed -n 's/^LAUNCH\t//p'
}

stdin_of() { # <mode> <borrow> [token] -> what e2e.sh piped into the launch call
    drive_harness "$@" | sed -n 's/^STDIN\t//p'
}

compose_phases() { # <mode> <borrow_miner> [token] -> the phase list e2e.sh would launch run.sh with
    # Everything between the runner's positional args and the trailing redirect is the phase list.
    launch_of "$@" | sed -n 's/.*\.e2e-run\.sh[^ ]* [^ ]* [^ ]* \(.*\) >\/dev\/null.*/\1/p'
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
    "$(phase_set "$TARGETED")" \
    "--auth-fail-closed --lifecycle --rig-control-port --rig-host --rigforge --rigforge-control 8082 rig1 "

echo "== --mode matrix keeps everything it had =="
MATRIX="$(compose_phases matrix 1)"
assert_eq "matrix still requests the rigforge-control WRITE phase" \
    "$(has_phase "$MATRIX" --rigforge-control)" "yes"
assert_eq "matrix launches EXACTLY its documented phases, and nothing else" \
    "$(phase_set "$MATRIX")" \
    "--auth-fail-closed --fault-injection --hardening --lifecycle --rig-control-port --rig-host --rigforge --rigforge-control --safety-backup --subnet 8082 rig1 "

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

contains() { # <haystack> <needle> -> "yes" | "no"
    case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

echo "== the write phase is SUPPLIED, not just requested (#1378) =="
# #1364 made the phase REACHABLE. Reachable is not covered: unsupplied, run.sh drops the whole phase
# unless the bench baseline happens to pin a descriptor (run.sh:2135-2139), #516's enriched-feed leg
# can NEVER run (run.sh:2294-2296), and #517 loses the settle fallback that keeps a correct rollback
# on a slow rig from asserting red (run.sh:2373). None of that is visible in a green verdict.
assert_eq "targeted passes --rig-host, defaulted off the borrowed miner" \
    "$(has_phase "$TARGETED" --rig-host)" "yes"
assert_eq "targeted passes the rig host VALUE, not just the flag" \
    "$(has_phase "$TARGETED" rig1)" "yes"
assert_eq "targeted passes --rig-control-port so e2e.sh and run.sh cannot dial different ports" \
    "$(has_phase "$TARGETED" --rig-control-port)" "yes"

echo "== an UNSUPPLIED rig still gets the phase — a gap must not become a dropped phase (#1378) =="
# Driving with an empty token takes rig_supply's no-token branch. The phase must still be requested:
# its dashboard-side legs are real coverage, and silently dropping it is the #1364 defect returning.
UNSUPPLIED="$(compose_phases targeted 1 "")"
assert_eq "no token => the write phase is STILL requested" \
    "$(has_phase "$UNSUPPLIED" --rigforge-control)" "yes"
assert_eq "no token => nothing is piped to the launch" \
    "$(stdin_of targeted 1 "")" ""

echo "== the token never lands in the detached runner's argv (#1378) =="
# /proc/PID/cmdline is world-readable and the nohup'd runner lives for the whole run, so the token
# travels on stdin and arrives as an ENVIRONMENT entry (/proc/PID/environ is owner-only). run.sh
# already puts it in a short-lived bench-side curl argv via rx(); a long-lived one is the new risk.
LAUNCH="$(launch_of targeted 1)"
assert_eq "the launch command does NOT contain the token" \
    "$(contains "$LAUNCH" "s3cr3t-tok3n")" "no"
assert_eq "the launch passes the token as an environment entry, not an argument" \
    "$(contains "$LAUNCH" 'IT_RIG_TOKEN="$t" nohup')" "yes"
assert_eq "the token is what e2e.sh pipes to the launch call" \
    "$(stdin_of targeted 1)" "s3cr3t-tok3n"

echo "== rig_supply's rc-0 contract, which e2e.sh's && chain depends on (#1378) =="
# e2e.sh appends the phase flags with `... && rig_supply && phases=...`. A rig_supply that returned
# non-zero on any path would silently drop the whole write phase — #1364, reopened and invisible.
# So the contract is asserted on every branch, not just the happy one.
#
# The host is a PARAMETER, not an env prefix on the call: rc_of assigns MINER_HOST inside its own
# subshell, so a `MINER_HOST="" rc_of ...` prefix would be overwritten and the no-host case would
# silently re-test the happy path — green, and proving nothing.
rc_of() { # <miner-host> <token-from-rig> <dial-rc> -> rig_supply's exit code
    (
        MINER_HOST="$1" TOKEN_OUT="$2" DIAL_RC="$3"
        RIG_HOST="" IT_RIG_TOKEN="" RIGFORGE_CONFIG=/opt/rigforge/config.json BENCH_HOST=bench
        warn() { :; }
        ok() { :; }
        on_miner() { printf '%s' "$TOKEN_OUT"; }
        on_bench() {
            cat >/dev/null
            return "$DIAL_RC"
        }
        rig_supply
        echo $?
    ) </dev/null
}
assert_eq "rc 0 when the rig answers the proof dial" "$(rc_of rig1 tok 0)" "0"
assert_eq "rc 0 when the rig is UNREACHABLE (supplied but unproven)" "$(rc_of rig1 tok 7)" "0"
assert_eq "rc 0 when the rig yields no token" "$(rc_of rig1 "" 0)" "0"
assert_eq "rc 0 when there is no rig host at all" "$(rc_of "" tok 0)" "0"

echo "== the proof dial actually proves something (#1378) =="
# rig_supply's whole value over a bare default is that it DIALS before claiming the phase is
# supplied. A dial carrying no credential would 401 against a real rig and "prove" only that
# something is listening — a check whose control cannot fail. So assert what the dial contains.
# EXECUTE the dial with curl stubbed, and record the argv curl ACTUALLY received. Asserting on the
# source text instead would miss the sharpest failure: a dial that builds the header correctly but
# binds an EMPTY token still reads as "Authorization: Bearer" at the text level, 401s on a real rig,
# and turns the proof into something that can never succeed — the mirror of a check that can never
# fail, and just as worthless.
dial_of() { # -> the argv rig_supply's proof dial hands to curl on the bench
    local f
    f="$(mktemp)"
    (
        MINER_HOST=rig1 RIG_HOST="" IT_RIG_TOKEN="" RIGFORGE_CONFIG=/opt/rigforge/config.json
        BENCH_HOST=bench DIAL_FILE="$f"
        warn() { :; }
        ok() { :; }
        on_miner() { printf '%s' "s3cr3t-tok3n"; }
        curl() { printf 'CURL_ARGV=[%s]' "$*" >"$DIAL_FILE"; }
        # eval, so the dial's own `read` consumes the token off the pipe exactly as it would on the
        # bench. The stub deliberately does NOT re-implement the command it is checking.
        on_bench() { eval "$1"; }
        rig_supply
    ) </dev/null
    cat "$f"
    rm -f "$f"
}
DIAL="$(dial_of)"
assert_eq "the dial reaches curl at all" "$(contains "$DIAL" 'CURL_ARGV=[')" "yes"
assert_eq "the dial presents the REAL token — an empty bearer would 401 and prove nothing" \
    "$(contains "$DIAL" 'Authorization: Bearer s3cr3t-tok3n')" "yes"
assert_eq "the dial targets exactly the host and port handed to run.sh" \
    "$(contains "$DIAL" 'http://rig1:8082/status')" "yes"
assert_eq "the dial fails on a non-2xx (curl -f), so a 401 cannot read as proof" \
    "$(contains "$DIAL" '-fsS')" "yes"

echo "== the flag e2e.sh emits is one run.sh actually parses =="
# run.sh's parser ends in `-*) die "Unknown option"`, so a phase e2e.sh invents is not a no-op —
# it kills the whole harness run. Assert the handshake rather than trusting the two files agree.
# grep '^--' so the loop reads FLAGS only: since #1378 the list also carries their VALUES
# (--rig-host <host>, --rig-control-port <port>), and a value is not something run.sh's parser sees.
for flag in $(printf '%s %s %s %s' "$TARGETED" "$MATRIX" "$CHECK" "$NOMINER" | tr ' ' '\n' | grep '^--' | LC_ALL=C sort -u); do
    assert_eq "run.sh's arg parser accepts '$flag'" \
        "$(grep -cE "^[[:space:]]*(\-\-[a-z-]+ \| )*${flag}\)" "$RUN_SRC" | awk '{print ($1>0)?"yes":"no"}')" "yes"
done

echo ""
echo "selftest-e2e-phases: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
