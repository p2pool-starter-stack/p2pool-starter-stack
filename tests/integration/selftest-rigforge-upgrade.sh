#!/usr/bin/env bash
#
# Self-test for the one-click upgrade legs (rigforge-upgrade.sh), driven as pure functions against
# a stubbed TRANSPORT — no rig, no dashboard, no docker.
#
# Only `rx` is replaced. Everything above it — the dispatcher's branch choice, the shape assertions
# on the POST answer, the poll loop's terminal vocabulary, the accepted->applied settle, and
# _pred_rig_version_is reading the feed back — is the real code. Stubbing the higher-level helpers
# instead would have left the functions that carry this fix's whole point untested by the file
# whose job is to test them.
#
# In particular _pred_rig_version_is is NOT overridden. An earlier draft stubbed it to `true`, and
# that single shortcut made four cases report passes the real leg would never have produced: the
# noop follow-on fired after a FAILED upgrade, because the stub asserted the rig was on the new
# version when the whole point of the case was that it was not. The rig's reported version is now
# a file the transport reads, so "the rig came back on the new version" is a thing the fixture has
# to actually make true.
#
# THE BAR (#1237): the leg this replaces was green and proved nothing, so "these tests pass" is not
# the claim being made here. Every case below names the mutation it kills.
#
# Standalone (not sourced by selftest.sh) so it never touches selftest.sh's file-budget ceiling —
# same reasoning as selftest-rigforge-writable-keys.sh.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/rigforge-upgrade.sh
source "${MUT_LEG:-$HERE/rigforge-upgrade.sh}"

# Never wait for real time: _poll_upgrade_result sleeps before its first read, and wait_for sleeps
# between attempts. Overriding the builtin keeps every case sub-second without weakening it — the
# loops still iterate, they just do not idle.
sleep() { :; }

# ...which turns every wait_for into a busy-wait, so the live 300s settle default would spin for
# 300 REAL seconds on any case whose readback is meant to fail. Bound it here. The leg keeps its
# live default (`${IT_UPGRADE_SETTLE_TIMEOUT:-300}` at source time); this only shortens the clock
# the cases run against, and no case distinguishes 2s from 300s -- the predicate is deterministic.
IT_UPGRADE_SETTLE_TIMEOUT=2

# --- Transport stub ---------------------------------------------------------
# One `rx` serves all three URLs the legs touch. Every piece of mutable fixture state is a FILE,
# not a variable, and that is load-bearing rather than tidiness: the legs call rx inside `$(...)`,
# so a subshell's assignment is lost the moment the substitution closes. A queue kept in a shell
# variable would have silently served its first element forever.
VER_F="$(mktemp)"  # what the rig currently reports
UPD_F="$(mktemp)"  # the dashboard's rigforge_update for it
POSTQ="$(mktemp)"  # answers to successive worker-upgrade POSTs
RESQ="$(mktemp)"   # successive /api/control/result statuses
FLIP_F="$(mktemp)" # version the rig starts reporting once an upgrade is POSTed ("" = never)
POST_LOG="$(mktemp)"
trap 'rm -f "$VER_F" "$UPD_F" "$POSTQ" "$RESQ" "$FLIP_F" "$POST_LOG"' EXIT

rig_reports() { printf '%s' "$1" >"$VER_F"; }
offers() { printf '%s' "$1" >"$UPD_F"; }
answers() { printf '%s\n' "$@" >"$POSTQ"; }
queue_results() { printf '%s\n' "$@" >"$RESQ"; }
comes_back_on() { printf '%s' "${1:-}" >"$FLIP_F"; }
posts() { cat "$POST_LOG"; }

_dequeue() { # <file> -> first line, removed
    local n
    n="$(head -1 "$1")"
    sed -i '1d' "$1" 2>/dev/null || true
    printf '%s' "$n"
}

rx() {
    case "$1" in
    *"/api/state"*)
        printf '{"workers":[{"name":"rig1","rigforge":{"version":"%s"},"rigforge_update":%s}]}' \
            "$(cat "$VER_F")" "$(cat "$UPD_F")"
        ;;
    *"worker-upgrade"*)
        # Record the payload so "which version was proposed" is a fact about the wire rather than
        # something inferred from the leg passing.
        printf '%s\n' "$1" | tr -d '\\\n' >>"$POST_LOG"
        # A POSTed upgrade is what makes the rig come back on the new version, when the case says
        # it does. Modelling that here (not in the assertions) keeps the leg's own readback honest.
        local flip
        flip="$(cat "$FLIP_F")"
        [ -n "$flip" ] && printf '%s' "$flip" >"$VER_F"
        _dequeue "$POSTQ"
        ;;
    *"control/result"*)
        local next
        next="$(_dequeue "$RESQ")"
        [ -n "$next" ] && printf '{"status":"%s"}' "$next"
        ;;
    *) ;;
    esac
}

# --- Case scaffolding -------------------------------------------------------
# Each case reports on the COUNTERS the harness itself keeps, because that is what a gate run
# reads. Asserting on stdout text instead would pass on a leg that printed the right words while
# recording the wrong verdict.
CASES=0
BAD=0
P0=0 F0=0 S0=0 SM0=0 SD0=0
snap() {
    P0=$IT_PASS
    F0=$IT_FAIL
    S0=$IT_SKIPPED_LEGS
    SM0=$IT_SKIPPED_MISSING
    SD0=$IT_SKIPPED_BY_DESIGN
    : >"$POST_LOG"
    comes_back_on ""
    queue_results
    answers
}
# want: <desc> <passes> <fails> <skips> <missing> <by-design>
want() {
    CASES=$((CASES + 1))
    local d="$1" gp=$((IT_PASS - P0)) gf=$((IT_FAIL - F0)) gs=$((IT_SKIPPED_LEGS - S0))
    local gm=$((IT_SKIPPED_MISSING - SM0)) gd=$((IT_SKIPPED_BY_DESIGN - SD0))
    if [ "$gp" = "$2" ] && [ "$gf" = "$3" ] && [ "$gs" = "$4" ] && [ "$gm" = "$5" ] && [ "$gd" = "$6" ]; then
        printf '  ok   %s\n' "$d"
    else
        BAD=$((BAD + 1))
        printf '  FAIL %s\n       want pass/fail/skip/missing/by-design=%s/%s/%s/%s/%s got %s/%s/%s/%s/%s\n' \
            "$d" "$2" "$3" "$4" "$5" "$6" "$gp" "$gf" "$gs" "$gm" "$gd"
    fi
}
# `[ ... ]` sets $? from a CONDITION, not a command, and reading it one line later is the SC2319
# shape — so the negation lives in a helper rather than in an inline $((1 - $?)).
check_no_posts() { # <desc>
    if [ -s "$POST_LOG" ]; then check "$1" 1; else check "$1" 0; fi
}
check() { # <desc> <condition-rc>
    CASES=$((CASES + 1))
    if [ "$2" = 0 ]; then printf '  ok   %s\n' "$1"; else
        BAD=$((BAD + 1))
        printf '  FAIL %s\n' "$1"
    fi
}

UPD_AVAIL='{"available":true,"latest":"v1.16.0","url":"https://example.invalid"}'
PENDING='{"id":"abc-123","status":"pending"}'
SYNC_NOOP='{"status":"noop","note":"already on v1.16.0"}'

echo "== rigforge-upgrade.sh — dispatcher =="

# KILLS: deleting the clean-version guard. A rig with no RigForge (plain xmrig) must skip, not
# propose "v" and dial with it.
snap
rig_reports ""
offers null
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "a plain-xmrig worker -> by-design skip, no assertions" 0 0 1 0 1
check_no_posts "and it POSTed nothing"
# The REASON is the discriminator, not the count. Both dispatcher skips record one leg-skip, so a
# count-only case cannot tell "no RigForge here" from "no newer release" and a mutation that
# deletes this guard survives by falling through to the other skip. (It did.)
printf '%s' "$IT_SKIPPED_NAMES" | grep -q 'reports no RigForge version at all'
check "and it says WHICH absence it is" $?

# KILLS: treating a null rigforge_update as "on latest" and running the noop leg anyway — which is
# exactly the tautology this file exists to stop coming back.
snap
rig_reports "1.16.0"
offers null
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "no update offered -> skip, classified missing" 0 0 1 1 0
check_no_posts "and it POSTed nothing"

echo "== the real upgrade leg (#1237) =="

# The happy path: 202+id, applied terminal, the rig comes back on the new version, then the noop
# follow-on on a precondition this run established. 3 passes + 2 = 5.
snap
rig_reports "1.15.1"
offers "$UPD_AVAIL"
answers "$PENDING" "$SYNC_NOOP"
queue_results applied
comes_back_on "1.16.0"
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "behind latest -> real upgrade + version readback + noop follow-on" 5 0 0 0 0
printf '%s' "$(posts)" | grep -q 'version.*v1[.]16[.]0'
check "and it proposed the dashboard's latest, not the rig's own version" $?

# KILLS: dropping the "did it leave the dashboard?" assertion. THE case the old leg could not
# fail: the dashboard answers a synchronous noop, nothing reaches the host or the rig, and a
# status-only assertion would have called that a pass.
snap
rig_reports "1.15.1"
answers "$SYNC_NOOP"
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "shortcut fires on a rig that is behind -> FAIL, not a pass" 0 1 0 0 0

# KILLS: accepting a pending answer that carries no pollable id.
snap
rig_reports "1.15.1"
answers '{"status":"pending"}'
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "pending with no id -> FAIL" 0 1 0 0 0

# KILLS: reading the rig's own 6h anti-beacon window as a product fault. It is rig state; no input
# to this harness changes it, so it is a by-design skip and must not red the gate.
snap
rig_reports "1.15.1"
answers "$PENDING"
queue_results throttled
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "rig throttled -> by-design skip after the hand-off pass" 1 0 1 0 1

# KILLS: collapsing the host's 90s poll cap into a failure. "accepted" means still running; the
# rig's own report is the confirmation of record, so it promotes to applied once the rig settles.
snap
rig_reports "1.15.1"
answers "$PENDING" "$SYNC_NOOP"
queue_results accepted
comes_back_on "1.16.0"
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "accepted (host poll cap) settles to applied against the rig" 5 0 0 0 0

# KILLS: treating any terminal as success, and KILLS double-counting one cause: a refusal reds
# ONCE, it does not also red the version readback it made impossible.
snap
rig_reports "1.15.1"
answers "$PENDING"
queue_results rejected
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "rejected terminal -> exactly one FAIL" 1 1 0 0 0

# KILLS: asserting the terminal without asserting the rig came back — #1237's own complaint. The
# host says applied; the rig never reports the new version.
snap
rig_reports "1.15.1"
offers "$UPD_AVAIL"
answers "$PENDING"
queue_results applied
# The poll loop and the version wait share this timeout, so it must stay non-zero: 0 starves the
# poll before it reaches its terminal and the case would test the wrong failure.
run_rigforge_upgrade rig1 >/dev/null 2>&1
want "applied but the rig never reports the new version -> FAIL" 2 1 0 0 0

echo "== the noop leg (#1002a) =="

# KILLS: dropping the absent-id assertion. A noop that carried an id took the long way round and
# spent the rig's throttle — the opposite of what the leg claims to prove.
snap
answers '{"id":"xyz-9","status":"noop"}'
_rigforge_upgrade_noop_leg rig1 v1.16.0 >/dev/null 2>&1
want "noop carrying a pollable id -> FAIL (it dialed the rig)" 1 1 0 0 0

# The honest pass: synchronous, no id.
snap
answers "$SYNC_NOOP"
_rigforge_upgrade_noop_leg rig1 v1.16.0 >/dev/null 2>&1
want "synchronous noop with no id -> two passes" 2 0 0 0 0

# KILLS: accepting anything that is not noop.
snap
answers '{"status":"pending","id":"q-1"}'
_rigforge_upgrade_noop_leg rig1 v1.16.0 >/dev/null 2>&1
want "a non-noop answer to a repeat click -> FAIL" 0 2 0 0 0

printf '\n%s: %d case(s), %d bad\n' "$([ "$BAD" -eq 0 ] && echo PASS || echo FAIL)" "$CASES" "$BAD"
[ "$BAD" -eq 0 ]
