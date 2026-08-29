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

echo "== rig_supply REPORTS which case it took, and says the right thing (#1378) =="
# The gap this closes was found by the reviewer lane on this PR, and it was the sharpest kind: rc_of
# above stubs warn() and ok() to `:`, so it is structurally incapable of seeing whether any message
# fires. "The harness does not report which case it took" is half of what #1378 is about, and until
# these assertions existed that half could be deleted outright with every gate still green — the worst
# mutation being an UNREACHABLE rig reported to the operator as "reached the rig control API".
#
# Same subshell as rc_of, but the helpers RECORD instead of discarding. Each branch is asserted on the
# sentence only it writes AND on not writing the other's, because two branches sharing one output
# string means either can silently cover for the other's deletion.
report_of() { # <miner-host> <token-from-rig> <dial-rc> -> "WARN <msg>" / "OK <msg>" lines
    (
        MINER_HOST="$1" TOKEN_OUT="$2" DIAL_RC="$3"
        RIG_HOST="" IT_RIG_TOKEN="" RIGFORGE_CONFIG=/opt/rigforge/config.json BENCH_HOST=bench
        warn() { printf 'WARN %s\n' "$*"; }
        ok() { printf 'OK %s\n' "$*"; }
        on_miner() { printf '%s' "$TOKEN_OUT"; }
        on_bench() {
            cat >/dev/null
            return "$DIAL_RC"
        }
        rig_supply
    ) </dev/null
}
R_NOTOKEN="$(report_of rig1 "" 0)"
R_NOHOST="$(report_of "" tok 0)"
R_UNREACH="$(report_of rig1 tok 7)"
R_OK="$(report_of rig1 tok 0)"
assert_eq "no token => the operator is TOLD the phase is under-supplied" \
    "$(contains "$R_NOTOKEN" 'WARN write phase UNDER-SUPPLIED')" "yes"
assert_eq "no token => the report names the leg that cannot run at all (#516)" \
    "$(contains "$R_NOTOKEN" 'feed leg cannot run')" "yes"
assert_eq "no rig host => the operator is TOLD the phase is under-supplied" \
    "$(contains "$R_NOHOST" 'WARN write phase UNDER-SUPPLIED')" "yes"
assert_eq "an UNREACHABLE rig is reported as supplied-but-UNPROVEN" \
    "$(contains "$R_UNREACH" 'WARN write phase supplied but UNPROVEN')" "yes"
# The mutation this exists for: turning that warn into ok would tell the operator the harness reached
# a rig it never reached, and every other assertion here would still pass.
assert_eq "an UNREACHABLE rig is NEVER reported as reached" \
    "$(contains "$R_UNREACH" 'OK write phase supplied:')" "no"
assert_eq "a rig that answers IS reported as supplied" \
    "$(contains "$R_OK" 'OK write phase supplied:')" "yes"
assert_eq "a rig that answers produces NO warning" "$(contains "$R_OK" 'WARN')" "no"

echo "== a root-owned rig config is READ, not mistaken for an empty one (#1466) =="
# The defect: RigForge's control service runs as root and rewrites /opt/rigforge/config.json when a
# control-apply lands, so the file is root-owned from a rig's FIRST successful write onwards. The
# unprivileged read then failed, `2>/dev/null` swallowed the error, the token came back empty, and
# run.sh dropped the whole rigforge-control phase while the gate still printed `✓ E2E PASSED`. The
# run that works is the one that breaks the next run — #1178's shape in a different file.
#
# Both halves are asserted because either alone is a fix that reads as complete and is not: a sudo
# fallback with the error still swallowed leaves every OTHER read failure indistinguishable from an
# empty file, and honest reporting with no fallback leaves the gate under-supplied.
#
# The stub dispatches on the command the shipped code actually builds, and TRACES every read, so
# "the fallback fired" and "the fallback fired in the right order, and only when it should" are
# separate observations rather than one inference off the final token.
#
# The subshell's STDERR joins that trace, which is what makes the unswallowing observable: warn() and
# ok() are stubbed onto stdout here, so the only thing that can reach stderr is what rig_supply let
# through from the read itself. Asserting `2>/dev/null` is absent from the source would instead pass
# on a fix that merely moved the redirection somewhere else.
supply_of() { # <unpriv-out> <unpriv-rc> <sudo-out> <sudo-rc> -> report lines, final token, read trace
    local f
    f="$(mktemp)"
    (
        MINER_HOST=rig1 RIG_HOST="" IT_RIG_TOKEN="" RIGFORGE_CONFIG=/opt/rigforge/config.json
        BENCH_HOST=bench U_OUT="$1" U_RC="$2" S_OUT="$3" S_RC="$4" TRACE="$f"
        warn() { printf 'WARN %s\n' "$*"; }
        ok() { printf 'OK %s\n' "$*"; }
        on_miner() {
            printf 'READ[%s]\n' "$1" >>"$TRACE"
            case "$1" in
            "sudo -n"*)
                printf '%s' "$S_OUT"
                return "$S_RC"
                ;;
            *)
                # What a denied jq really writes, on the channel it really writes it on.
                [ "$U_RC" = 0 ] || printf 'jq: error: %s: Permission denied\n' "$RIGFORGE_CONFIG" >&2
                printf '%s' "$U_OUT"
                return "$U_RC"
                ;;
            esac
        }
        on_bench() { cat >/dev/null; }
        rig_supply
        printf 'TOKEN[%s]\nRC[%s]\n' "$IT_RIG_TOKEN" "$?"
    ) </dev/null 2>>"$f"
    cat "$f"
    rm -f "$f"
}

# Denied unprivileged read, sudo -n succeeds — the real post-control-apply rig.
S_DENIED="$(supply_of "" 5 "recovered-tok3n" 0)"
assert_eq "a root-owned config is recovered through the sudo -n fallback (#1466)" \
    "$(contains "$S_DENIED" 'TOKEN[recovered-tok3n]')" "yes"
assert_eq "a recovered token means the phase is SUPPLIED, not under-supplied" \
    "$(contains "$S_DENIED" 'UNDER-SUPPLIED')" "no"
assert_eq "the unprivileged read is still tried FIRST — sudo is the fallback, not the route" \
    "$(printf '%s\n' "$S_DENIED" | grep -c 'READ\[jq ')" "1"
assert_eq "and the fallback does reach the same file under sudo" \
    "$(contains "$S_DENIED" "READ[sudo -n jq -r '.ACCESS_TOKEN // empty' /opt/rigforge/config.json]")" "yes"

# Readable config that genuinely holds no token: rc 0, empty output. Escalating here would answer a
# permissions question nobody asked and print a sudo error into a case with nothing wrong with it.
S_EMPTY="$(supply_of "" 0 "must-not-be-read" 0)"
assert_eq "a READABLE config with no token does not escalate to sudo (#1466)" \
    "$(contains "$S_EMPTY" 'READ[sudo -n')" "no"
assert_eq "and it is reported as a file with no token in it" \
    "$(contains "$S_EMPTY" 'no token in')" "yes"
assert_eq "and never as a read that failed" \
    "$(contains "$S_EMPTY" 'could NOT READ')" "no"

# BOTH reads fail, and the LAST one drops after printing part of its answer — ssh cut mid-transfer.
# Half a token is worse than none: it dials, 401s, and the operator is told the phase was supplied.
# The `|| IT_RIG_TOKEN=""` the old single read carried has to survive on the last read in the chain,
# and this is the only case that can see it: on any earlier read the next assignment overwrites a
# partial answer anyway. Written against that case deliberately — the obvious version of this test,
# a partial FIRST read rescued by a working sudo, passes whether the guard is there or not.
S_PARTIAL="$(supply_of "half-a-tok" 255 "half-a-sudo-tok" 1)"
assert_eq "the last read's partial output is discarded, not used as the token (#1466)" \
    "$(contains "$S_PARTIAL" 'half-a-sudo-tok')" "no"
assert_eq "and a run that read only fragments is reported UNDER-SUPPLIED, never as supplied" \
    "$(contains "$S_PARTIAL" 'could NOT READ')" "yes"

# Denied both ways — no passwordless sudo either. The phase is still under-supplied, but the
# operator must be told WHICH under-supply it is, because the two have different fixes.
S_BOTH="$(supply_of "" 5 "" 1)"
assert_eq "a read that failed both ways is reported as a failed READ (#1466)" \
    "$(contains "$S_BOTH" 'could NOT READ')" "yes"
assert_eq "a failed read is NEVER reported as the file having no token" \
    "$(contains "$S_BOTH" 'no token in')" "no"
assert_eq "the report carries both rcs, so the operator can tell which half refused" \
    "$(contains "$S_BOTH" 'read rc=5, sudo -n rc=1')" "yes"
assert_eq "an unreadable config still leaves the phase requested — rc 0 (#1378)" \
    "$(contains "$S_BOTH" 'RC[0]')" "yes"
assert_eq "and the under-supply still names the leg that cannot run at all (#516)" \
    "$(contains "$S_BOTH" 'feed leg cannot run')" "yes"

assert_eq "the denied read's OWN error reaches the operator, unswallowed (#1466)" \
    "$(contains "$S_BOTH" 'jq: error: /opt/rigforge/config.json: Permission denied')" "yes"
# The same error must survive the path where the FALLBACK rescues the run: an operator who gets a
# token still wants to know the unprivileged read is now failing, because that is the rig telling
# them it has been written to.
assert_eq "and it survives even when sudo goes on to recover the token" \
    "$(contains "$S_DENIED" 'Permission denied')" "yes"
# Positive control for the two lines above: a read that never failed writes nothing on that channel,
# so they are reading rig_supply's behaviour and not a string the stub emits unconditionally.
assert_eq "a read that did NOT fail produces no such error" \
    "$(contains "$S_EMPTY" 'Permission denied')" "no"

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
        # Record BOTH channels. The token now travels in curl's stdin config (-K -) rather than its
        # argv, so a stub that captured only "$*" would see a dial with no credential in it and could
        # not tell "the bearer moved to stdin" from "the bearer was dropped".
        curl() { printf 'CURL_ARGV=[%s]\nCURL_STDIN=[%s]' "$*" "$(cat)" >"$DIAL_FILE"; }
        # eval, so the dial's own redirection reaches the stub exactly as it would on the bench. The
        # stub deliberately does NOT re-implement the command it is checking.
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
# The two halves that make the -K form a hygiene FIX rather than a rearrangement. Both are needed:
# argv-only would pass on a dial that simply lost the credential, and stdin-only would pass on a dial
# that sent it twice. /proc/<curl>/cmdline is mode 444 on the bench for the life of the dial.
assert_eq "the token is NOT in curl's world-readable argv" \
    "$(contains "${DIAL%%$'\n'CURL_STDIN=*}" 's3cr3t-tok3n')" "no"
assert_eq "the token reaches curl on stdin, as a -K config" \
    "$(contains "$DIAL" 'CURL_STDIN=[header = "Authorization: Bearer s3cr3t-tok3n"')" "yes"
assert_eq "the dial tells curl to read that config from stdin" "$(contains "$DIAL" '-K -')" "yes"

echo "== the flag e2e.sh emits is one run.sh actually parses =="
# run.sh's parser ends in `-*) die "Unknown option"`, so a phase e2e.sh invents is not a no-op —
# it kills the whole harness run. Assert the handshake rather than trusting the two files agree.
# grep '^--' so the loop reads FLAGS only: since #1378 the list also carries their VALUES
# (--rig-host <host>, --rig-control-port <port>), and a value is not something run.sh's parser sees.
for flag in $(printf '%s %s %s %s' "$TARGETED" "$MATRIX" "$CHECK" "$NOMINER" | tr ' ' '\n' | grep '^--' | LC_ALL=C sort -u); do
    assert_eq "run.sh's arg parser accepts '$flag'" \
        "$(grep -cE "^[[:space:]]*(\-\-[a-z-]+ \| )*${flag}\)" "$RUN_SRC" | awk '{print ($1>0)?"yes":"no"}')" "yes"
done

echo "== borrow_miner's recovery block, fired on known instances (#1178) =="
# F2 of the #1415 review: nothing in the repo ever fired this detector, so its only evidence was
# PR-body prose from a harness never committed. Drives the REAL block out of the shipped e2e.sh with
# on_miner running each command LOCALLY against a temp config — ssh is the only substitution, and it
# is the whole of on_miner (e2e.sh:172). Extraction is asserted first, so a refactor reds.
RECOVERY_SRC="$(sed -n '/^    local leftover borrowed/,/^    esac$/p' "$E2E_SRC")"
assert_eq "the recovery-block extraction opens and closes" \
    "$(printf '%s\n' "$RECOVERY_SRC" | sed -n '1p;$p' | awk '{print $1}' | tr '\n' ' ')" "local esac "

drive_recovery() { # <pools-json> <n-backups> -> $OUT (the warn lines), $CFGDIR (the resulting tree)
    local i=1
    CFGDIR="$(mktemp -d)"
    printf '%s' "$1" >"$CFGDIR/config.json"
    while [ "$i" -le "$2" ]; do
        printf '{"pools":[{"url":"orig%s.example:3333"},{"url":"bench.example:3333"}]}' "$i" >"$CFGDIR/config.json.e2e-orig.$i"
        i=$((i + 1))
    done
    OUT="$(
        exec </dev/null
        # SC2034/SC2329: the config vars and the stubs are read and called by the eval'd block,
        # which shellcheck cannot follow into.
        # shellcheck disable=SC2034,SC2329
        MINER_HOST=rig1 BENCH_HOST=bench.example MINER_XMRIG_CONFIG="$CFGDIR/config.json"
        on_miner() { eval "$1"; }
        warn() { echo "WARN $*"; }
        die() { echo "DIE $*" && exit 1; }
        eval "recovery() { $RECOVERY_SRC; }"
        recovery
    )"
}

# The case the review named: a rig that merely KEEPS a permanent bench pool, at index 1, untagged.
# `.pools[0]` positionality is the only reason that reads as clean, and nothing said so. Broaden that
# jq to any(.pools[]?; ...) and arm 1 cp's a stale backup over the operator's live config, every gate
# still green. Asserting the BYTES catches it; a message assert would not, because arm 1 warns too.
BEFORE='{"pools":[{"url":"pithead.example:3333"},{"url":"bench.example:3333"}]}'
drive_recovery "$BEFORE" 1
assert_eq "a permanent bench pool at [1] is not treated as a leftover borrow" "$(cat "$CFGDIR/config.json")" "$BEFORE"
assert_eq "  its stale backup is cleared, so 'oldest' keeps meaning the original" "$(ls -1 "$CFGDIR" | wc -l)" "1"
assert_eq "  and it is reported as the rig's own permanent bench pool" "$(contains "$OUT" "permanent bench pool")" "yes"

# F1: the unrecoverable arm must not be followed by the reassuring verdict that cancels it.
drive_recovery '{"pools":[{"url":"bench.example:3333"}]}' 0
assert_eq "an un-undoable reorder says so" "$(contains "$OUT" "HAND-REPAIR")" "yes"
assert_eq "  and does NOT also report there was no un-restored borrow to undo (#1415 F1)" "$(contains "$OUT" "found no un-restored borrow to undo")" "no"

# Arm 1: a borrow WITH surviving backups restores from the OLDEST, then prunes them all.
drive_recovery '{"pools":[{"url":"pithead.example:3333"},{"url":"bench.example:3333","rig-id":"pithead-e2e"}]}' 2
assert_eq "a leftover borrow is restored from the oldest backup" "$(jq -r '.pools[0].url' "$CFGDIR/config.json")" "orig1.example:3333"
assert_eq "  and every backup is pruned once the bytes are back" "$(ls -1 "$CFGDIR" | wc -l)" "1"
assert_eq "  and the report does NOT then deny the borrow it just undid (#1415 F1, arm 1)" "$(contains "$OUT" "found no un-restored borrow to undo")" "no"
assert_eq "  positive control for the line above: the report DOES fire here" "$(contains "$OUT" "untagged pool(s)")" "yes"

# Unreadable must cost nothing — a config half-written by a run that died mid-restore looks like this.
drive_recovery 'not json at all' 1
assert_eq "an unreadable config leaves the only surviving backup alone" "$(ls -1 "$CFGDIR" | wc -l)" "2"
assert_eq "  and the silence is not reported as clean" "$(contains "$OUT" "leaving the config AND any backup(s) untouched")" "yes"
assert_eq "  and the REPORT block says so in its own words, which is a SECOND guard" "$(contains "$OUT" "do NOT read the silence as clean")" "yes"
assert_eq "  and the config bytes are untouched too — that message claims BOTH halves" "$(cat "$CFGDIR/config.json")" "not json at all"

echo ""
echo "selftest-e2e-phases: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
