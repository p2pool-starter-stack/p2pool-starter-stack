#!/usr/bin/env bash
#
# Self-test for the p2pool -> Tari merge-mining round-trip probe (#1397) — the verdicts and the
# leg's three outcomes, driven from CAPTURED log bytes with no stack, no container, no network.
#
# The fixtures below were captured on the live stack, 2026-08-30, through the probe's own
# gesture (`docker compose logs --no-color --since <StartedAt> p2pool | head | grep`), escapes
# and service prefix intact. They are captured rather than hand-built for the same reason
# selftest-zmq-probe.sh captures its frames: a hand-built fixture agrees with whatever the
# author believed, so it cannot fail when the real wire format moves.
#
# The case that matters most is the VACUITY control. p2pool's log is ANSI-coloured and the
# escapes sit MID-LINE, between `MergeMiningClientTari ` and `tari://`. So the pattern anyone
# would write from reading the rendered log matches nothing at all — silently, and a probe that
# always says "absent" is indistinguishable from a working one until the day it matters. That
# control is fired in BOTH directions here: zero matches on the raw bytes, one after stripping.
#
# Run: tests/integration/selftest-mergemine-probe.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/mergemine-probe.sh
source "$HERE/mergemine-probe.sh"

# --- CAPTURED fixtures ------------------------------------------------------
# The chain_id is Tari's mainnet chain identifier, a public constant, and the address is the
# loopback literal p2pool's entrypoint rewrites to under Tor (#278). Neither is a secret.
MM_CHAIN_ID=01f0cf665bd4cd31cbb2b2470236389c483522b350335e10a4a5dca34cb85990
MM_LOCAL_1=$(printf 'p2pool  | \x1b[0;36m2026-08-28 23:52:23.3889\x1b[0m \x1b[0;90mMergeMiningClientTari \x1b[0mevent loop started\x1b[0m')
MM_LOCAL_2=$(printf 'p2pool  | \x1b[0;36m2026-08-28 23:52:23.3899\x1b[0m \x1b[0;90mMergeMiningClientTari \x1b[0mworker thread ready\x1b[0m')
MM_ROUNDTRIP=$(printf 'p2pool  | \x1b[0;36m2026-08-28 23:52:23.5636\x1b[0m \x1b[0;90mMergeMiningClientTari \x1b[0mtari://127.0.0.1:18142 uses chain_id \x1b[0;96m%s\x1b[0m' "$MM_CHAIN_ID")

MM_FULL="$MM_LOCAL_1
$MM_LOCAL_2
$MM_ROUNDTRIP"
MM_LOCAL_ONLY="$MM_LOCAL_1
$MM_LOCAL_2"

echo "== the ANSI escapes are real, and stripping them is load-bearing (#1397) =="

# NEGATIVE control. This is the pattern a reader of the rendered log writes, and on the real
# bytes it matches NOTHING. If this case ever passes with a non-zero count, the log has stopped
# being coloured and the strip has become optional — worth knowing, and not silently.
assert_eq "the naive pattern matches ZERO on the raw captured line" \
    "$(printf '%s\n' "$MM_ROUNDTRIP" | grep -ac 'MergeMiningClientTari tari://')" "0"
# POSITIVE control on the same bytes: the only thing that changed is the strip.
assert_eq "the same pattern matches ONCE after stripping" \
    "$(printf '%s\n' "$MM_ROUNDTRIP" | mm_strip_ansi | grep -ac 'MergeMiningClientTari tari://')" "1"
# The strip must not eat payload — the chain_id has to survive it intact.
assert_contains "the chain_id survives the strip" \
    "$(printf '%s\n' "$MM_ROUNDTRIP" | mm_strip_ansi)" "uses chain_id $MM_CHAIN_ID"
assert_eq "the strip leaves no ESC byte behind" \
    "$(printf '%s\n' "$MM_FULL" | mm_strip_ansi | grep -ac "$(printf '\033')")" "0"

echo "== the verdict separates a gRPC round-trip from a client that merely started =="

verdict="$(mm_roundtrip_verdict "$MM_FULL")"
rc=$?
assert_eq "a full startup capture reads roundtrip with the chain_id" "$verdict" "roundtrip $MM_CHAIN_ID"
assert_rc "roundtrip returns 0" "$rc" "0"

# THE NARROWNESS CONTROL, and the reason this file exists. The two local lines land ~175 ms
# BEFORE the chain_id read, so they are present in every capture where Tari is unreachable. A
# probe keyed on `MergeMiningClientTari` alone would pass here — green while merge-mining is
# dead, which is the exact false green this harness exists to kill.
verdict="$(mm_roundtrip_verdict "$MM_LOCAL_ONLY")"
rc=$?
assert_eq "the two LOCAL lines alone read local-only, not roundtrip" "$verdict" "local-only"
assert_rc "local-only returns non-zero" "$rc" "1"

verdict="$(mm_roundtrip_verdict "")"
rc=$?
assert_eq "an empty capture reads absent" "$verdict" "absent"
assert_rc "absent returns non-zero" "$rc" "1"
assert_eq "unrelated p2pool output reads absent" \
    "$(mm_roundtrip_verdict 'p2pool  | 2026-08-28 23:52:23.0000 SideChain new chain tip')" "absent"

echo "== near misses that must NOT be read as a round-trip =="

# Each of these differs from the passing fixture in exactly ONE token. A boundary asserted only
# by the case that passes is not asserted at all.
mm_near() { mm_roundtrip_verdict "$(printf 'p2pool  | 2026-08-28 23:52:23.5636 MergeMiningClientTari %s\n' "$1")"; }
assert_eq "a chain_id too short to be one is not a round-trip" \
    "$(mm_near 'tari://127.0.0.1:18142 uses chain_id 01f0cf')" "local-only"
assert_eq "a chain_id line with no tari:// endpoint is not a round-trip" \
    "$(mm_near 'uses chain_id '"$MM_CHAIN_ID")" "local-only"
assert_eq "a non-hex chain_id is not a round-trip" \
    "$(mm_near 'tari://127.0.0.1:18142 uses chain_id ZZZZZZZZZZZZZZZZZZZZ')" "local-only"
assert_eq "an endpoint with no chain_id at all is not a round-trip" \
    "$(mm_near 'tari://127.0.0.1:18142 connecting')" "local-only"
# Two startup epochs in one capture — what `docker compose logs` returns if the `--since` bound
# below ever stops holding. The NEWEST chain_id must win: an old epoch's line standing in for a
# live client that never reached Tari is the same false green, arriving by a different door.
MM_OLD_ID=00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_contains "with two startup epochs, the NEWEST chain_id wins" \
    "$(mm_roundtrip_verdict "$(printf 'p2pool  | MergeMiningClientTari tari://127.0.0.1:18142 uses chain_id %s\n%s\n' "$MM_OLD_ID" "$MM_ROUNDTRIP")")" \
    "roundtrip $MM_CHAIN_ID"

# And the positive sibling of those four: the unprefixed form, as `docker logs` renders it,
# must still pass. The probe must not be accidentally keyed on the compose service prefix.
assert_contains "the unprefixed docker logs form still reads roundtrip" \
    "$(mm_roundtrip_verdict "${MM_ROUNDTRIP#p2pool  | }")" "roundtrip $MM_CHAIN_ID"

echo "== the capture is bounded to the current container run, and leaks nothing =="

# Stubbing `rx` rather than `mm_capture_startup` is what reaches the two bounds inside it. Both
# are invisible to a test that stubs the whole function: dropping `--since` or swapping the head
# window for a tail leaves every other case in this file green, which is exactly how a bound
# rots. Recording the composed command asserts WHICH command is sent to the target — a claim
# about the gesture, not about docker's behaviour, and it is named that way below.
# The recorder writes to a FILE, not a variable. `mm_capture_startup` is called through `$(...)`,
# and a command substitution is a subshell: a variable assigned inside it is gone by the time the
# assertion reads it. That is not hypothetical here — it was the first version of this block, and
# it left the two negative checks below passing over an empty string, which is a vacuous green of
# exactly the kind this file exists to refuse.
MM_RX_LOG_FILE="$(mktemp)"
trap 'rm -f "$MM_RX_LOG_FILE"' EXIT
rx() {
    printf '%s\n' "$*" >>"$MM_RX_LOG_FILE"
    case "$*" in
    *"docker inspect"*) printf '%s\n' "$MM_RX_STARTED" ;;
    *) printf '%s\n' "$MM_RX_LOGS" ;;
    esac
}

MM_RX_STARTED="2026-08-28T23:52:05.827654553Z"
MM_RX_LOGS="$MM_FULL"
: >"$MM_RX_LOG_FILE"
cap="$(mm_capture_startup)"
cap_rc=$?
MM_RX_LOG="$(cat "$MM_RX_LOG_FILE")"

assert_rc "a readable start time makes the capture succeed" "$cap_rc" "0"
# ARM CHECK, before any assertion reads $MM_RX_LOG. Every check below it — including two phrased
# as absences — is satisfiable by an empty recording, so an unarmed recorder would report a clean
# sweep over nothing.
assert_num_gt "the command recorder actually captured something" "$(printf '%s' "$MM_RX_LOG" | wc -c)" 0
assert_contains "the log read is bounded by the container's OWN start time" "$MM_RX_LOG" "--since 2026-08-28T23:52:05.827654553Z"
assert_contains "the window is a HEAD read — the signal is startup-only" "$MM_RX_LOG" "head -n 2000"
# The negative sibling. A tail cannot contain a line that lands 17.5s into an hours-old log, and
# the swap is silent: every fixture case above stays green through it.
case "$MM_RX_LOG" in
*--tail*) it_fail "the window is never a tail read" "the composed command asked for a tail" ;;
*) it_pass "the window is never a tail read" ;;
esac
# Leak safety, as a checked claim rather than a comment: the filter runs ON THE TARGET, so the
# argv line — which carries both wallets, the RPC credential and the onion (#1582/#1585/#1586) —
# is never transferred. And `docker inspect` names ONE field, so it cannot print .Args.
assert_contains "only merge-mining lines are asked to cross the wire" "$MM_RX_LOG" "grep -a MergeMiningClientTari"
assert_contains "docker inspect names a single field, never the whole object" "$MM_RX_LOG" "--format '{{.State.StartedAt}}'"
# End to end through the real capture: canned log bytes in, verdict out.
assert_contains "a captured startup window reads roundtrip end to end" "$(mm_roundtrip_verdict "$cap")" "roundtrip $MM_CHAIN_ID"

# An unreadable start time must refuse rather than read an unbounded log.
MM_RX_STARTED=""
: >"$MM_RX_LOG_FILE"
mm_capture_startup >/dev/null 2>&1
assert_rc "an unreadable start time refuses the capture" "$?" "1"
MM_RX_LOG="$(cat "$MM_RX_LOG_FILE")"
assert_num_gt "the recorder saw the inspect call it did make" "$(printf '%s' "$MM_RX_LOG" | wc -c)" 0
case "$MM_RX_LOG" in
*"compose logs"*) it_fail "no log is read when the start time is unknown" "it read the log anyway" ;;
*) it_pass "no log is read when the start time is unknown" ;;
esac
unset -f rx

echo "== the leg reports PASS, FAIL or a COUNTED skip — never a silent green =="

# Run the leg in a SUBSHELL with its two collaborators stubbed and the harness counters zeroed,
# and report the counters as a line. Three of the four cases below provoke a leg FAILURE on
# purpose; left in this file's own totals they would make a working self-test report red, which
# is how a suite learns to be read past.
#
# The stubs live INSIDE the subshell, not at the top level of this file. The capture section
# above calls the REAL `mm_capture_startup`, so a top-level stub of the same name has to come
# after those calls — and shellcheck 0.9.0 reads a call that precedes a same-file definition as
# use-before-definition (SC2218), which is what stopped the #1653 release rehearsal (#1679).
# Scoping the stubs to the subshell is the same behaviour: nothing outside it ever called them.
mm_leg_outcome() { # <synced-rc> <capture> -> "<pass> <fail> <skipped-legs> <by-design> <names>"
    (
        # The leg is driven with its two collaborators stubbed, so all three outcomes are
        # reachable without a stack. Stubbing is what makes the skip path testable at all: on the
        # boxes this harness runs on monerod IS synced, so that branch would otherwise never be
        # exercised here.
        monero_caught_up() { return "$MM_STUB_SYNCED"; }
        # The sentinel matters. `mm_capture_startup` has TWO distinct empty outcomes in production
        # and the leg treats them differently: it returns non-zero when the container's start time
        # cannot be read at all, and returns ZERO with empty output when the log simply held no
        # MergeMiningClientTari line (its `grep` is `|| true`). A stub keyed only on emptiness
        # collapses them, and the case named for the second silently exercises the first — which
        # is how the `absent` branch survived a mutation to `it_pass` here.
        mm_capture_startup() {
            [ "$MM_STUB_CAPTURE" = "@FAIL" ] && return 1
            printf '%s' "$MM_STUB_CAPTURE"
        }
        MM_STUB_SYNCED="$1"
        MM_STUB_CAPTURE="$2"
        IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_NAMES=""
        assert_mergemine_roundtrip >/dev/null 2>&1
        printf '%s %s %s %s %s\n' "$IT_PASS" "$IT_FAIL" "$IT_SKIPPED_LEGS" "$IT_SKIPPED_BY_DESIGN" "$IT_SKIPPED_NAMES"
    )
}

# The skip that REMAINS after #1597: the window was READ and held no merge-mining line, so
# p2pool built no client, so the header download did not complete. That is what earns the
# `by-design` class — not the predicate's bit, which on its own cannot tell "behind" from
# "unanswerable". The reason string must therefore stop asserting monerod's state as known.
out="$(mm_leg_outcome 1 "")"
assert_eq "no client AND no caught-up confirmation skips the leg — 0 pass, 0 fail, 1 counted skip" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 0 1"
assert_eq "and the skip is classed by-design, not missing" "$(printf '%s' "$out" | cut -d' ' -f4)" "1"
assert_contains "and the skip names itself and #1397" "$out" "#1397"
assert_contains "and the reason hedges monerod's state rather than asserting it (#1597)" \
    "$out" "could not be confirmed caught up"
# The negative sibling of that assert_contains. A reason can carry the new hedge and the old
# claim at once, which would read as fixed while still telling a reader the node is behind.
case "$out" in
*"monerod is not caught up"*) it_fail "the skip reason never states the unanswerable bit as fact (#1597)" "the reason still asserts monerod is not caught up" ;;
*) it_pass "the skip reason never states the unanswerable bit as fact (#1597)" ;;
esac

out="$(mm_leg_outcome 0 "$MM_FULL")"
assert_eq "a synced node with a chain_id line PASSES — 1 pass, 0 fail, 0 skips" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "1 0 0"

out="$(mm_leg_outcome 0 "$MM_LOCAL_ONLY")"
assert_eq "a client that never read a chain_id FAILS — 0 pass, 1 fail, 0 skips" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 1 0"

# The startup window read cleanly and held no merge-mining line at all: p2pool never built the
# client. That is a FAILURE, never a skip — a skip would announce a hole that is really a dead
# merge-mining leg.
out="$(mm_leg_outcome 0 "")"
assert_eq "no merge-mining client at all FAILS, and is never a skip — 0 pass, 1 fail, 0 skips" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 1 0"

# Its sibling, and the reason the two must not share a case: an unreadable container start time
# is a different failure with a different cause, and it must not be able to stand in for the one
# above.
out="$(mm_leg_outcome 0 "@FAIL")"
assert_eq "an unreadable container start time FAILS separately — 0 pass, 1 fail, 0 skips" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 1 0"

echo "== an unanswerable monerod RPC cannot book a covered leg as an accepted hole (#1597) =="

# `monero_caught_up` REDUCED several independent conditions to ONE bit: its `curl -fsS` discards
# stderr, so an unreachable host, a refused connection and a 401 all leave the body empty, and
# `jq -e` over an empty body answered exactly as it does for a node that is genuinely behind.
# #1605 split that bit three ways (0 / 1 / any other rc); the stub below still returns a single
# not-caught-up bit because this leg deliberately treats both nonzero doors alike — see the note
# above `assert_mergemine_roundtrip`. Its three answers are covered in selftest-monero-caught-up.sh. The
# stub below returns that not-caught-up bit — which is what a perfectly synced monerod produces
# behind a broken credential. `lib.sh`'s own env_bake_verdict comment records a day of that state.
#
# All three cases were a counted `by-design` skip before the capture was moved ahead of the
# predicate. `by-design` on the skip ledger means an ACCEPTED HOLE, so each was an uncovered — or
# in the first case a demonstrably WORKING — leg, filed as a hole the project had agreed to.
# These assert the direction of the whole change: cases leave the skip ledger, never enter it.

# The one that matters most. A chain_id line is proof monerod caught up, taken from p2pool rather
# than from the RPC we could not reach: p2pool constructs no MergeMiningClientTari at all until
# its block-header download succeeds. A working merge-mining round-trip must not be filed as a
# hole because a credential broke.
out="$(mm_leg_outcome 1 "$MM_FULL")"
assert_eq "a chain_id line PASSES though the RPC says not-caught-up — the log outranks the predicate" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "1 0 0"

# Its sharper sibling: here the leg is genuinely BROKEN — the client is up and Tari is not
# answering — and the old order hid that red behind an accepted hole.
out="$(mm_leg_outcome 1 "$MM_LOCAL_ONLY")"
assert_eq "a client that never read a chain_id FAILS though the RPC says not-caught-up" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 1 0"

# And the harness-fault case. p2pool is in EXPECTED_ALWAYS (lib.sh), so a container with no
# readable start time is a broken measurement, not a hole in coverage.
out="$(mm_leg_outcome 1 "@FAIL")"
assert_eq "an unreadable container start time FAILS though the RPC says not-caught-up" \
    "$(printf '%s' "$out" | cut -d' ' -f1-3)" "0 1 0"

echo ""
echo "selftest-mergemine-probe: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
