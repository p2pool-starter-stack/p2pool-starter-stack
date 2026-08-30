#!/usr/bin/env bash
#
# Self-test for the ZMTP PUB probe (#1497) — the verdicts, driven from captured and hand-built
# wire fixtures, with no socket and no stack.
#
# The probe exists because a bare TCP dial cannot tell a live ZMQ publisher from a
# docker-published port with nothing behind it. Proven on the bench 2026-08-29, one host, three
# targets, the preflight's exact gesture (`timeout 5 bash -c "</dev/tcp/host/port"`) beside it:
#
#   live monerod ZMQ 18083     preflight rc=0   probe: ok … Socket-Type XPUB
#   published-but-dead 28099   preflight rc=0   probe: no-greeting            <- the finding
#   closed 28098               preflight rc=1   probe: connect-refused
#
# The middle row is the whole point: the dial passes, the probe reds.
#
# These cases live in their own file because selftest.sh sits exactly on its recorded budget
# ceiling, and ceilings only go down.
#
# Run: tests/integration/selftest-zmq-probe.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/zmq-probe.sh
source "$HERE/zmq-probe.sh"

# CAPTURED from the live monerod on the bench, 2026-08-29 — not hand-built, so these two cases
# fail if the real wire format ever moves out from under the parser.
LIVE_GREETING=ff00000000000000017f03014e554c4c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
LIVE_READY=041a0552454144590b536f636b65742d547970650000000458505542
# Hand-built frames for the cases a live node will not produce.
READY_SUB=04190552454144590b536f636b65742d5479706500000003535542
READY_NO_SOCKET_TYPE=0413055245414459084964656e7469747900000000
READY_DECOY=043005524541445906582d4e6f74650000000b536f636b65742d547970650b536f636b65742d547970650000000458505542
READY_LONG=06000000000000001a0552454144590b536f636b65742d547970650000000458505542
GREETING_ZMTP2=ff00000000000000007f01004e554c4c000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
GREETING_HTTP=485454502f312e312034303020426164205265717565737400000000000000000000000000000000000000000000000000000000000000000000000000000000

echo "== wire constants are the shape ZMTP 3.x demands (#1497) =="

# A greeting that is not exactly 64 bytes is rejected by the peer, and the failure would look
# like a dead node. Assert the literal rather than trusting a hand count.
assert_eq "greeting is 64 bytes" "$(printf "$ZMQ_GREETING_BYTES" | wc -c)" "64"
assert_eq "READY frame is 27 bytes" "$(printf "$ZMQ_READY_BYTES" | wc -c)" "27"
assert_eq "READY frame declares its 25-byte body" \
    "$(printf "$ZMQ_READY_BYTES" | head -c 2 | tail -c 1 | od -An -tu1 | tr -d ' ')" "25"

echo "== greeting verdict =="

v=$(zmq_greeting_verdict "$LIVE_GREETING")
rc=$?
assert_rc "live monerod greeting is accepted" "$rc" "0"
assert_eq "live greeting reports ZMTP 3.1 / NULL" "$v" "ok 3.1 NULL"

# The class that matters: an accept() with no bytes. This is what the preflight's dial cannot see.
v=$(zmq_greeting_verdict "")
rc=$?
assert_rc "silent peer is refused" "$rc" "1"
assert_contains "silent peer is named no-greeting" "$v" "no-greeting"

v=$(zmq_greeting_verdict "ff00000000")
rc=$?
assert_rc "truncated greeting is refused" "$rc" "1"
assert_contains "truncated greeting is named short-greeting" "$v" "short-greeting"

# A full-length reply from a listener that is not ZMQ at all must not slip through on length.
v=$(zmq_greeting_verdict "$GREETING_HTTP")
rc=$?
assert_rc "non-ZMTP listener is refused" "$rc" "1"
assert_contains "non-ZMTP listener is named bad-signature" "$v" "bad-signature"

# ZMTP 2.0 carries a correct signature, so only the version check rejects it.
v=$(zmq_greeting_verdict "$GREETING_ZMTP2")
rc=$?
assert_rc "ZMTP 2.0 peer is refused" "$rc" "1"
assert_contains "ZMTP 2.0 peer is named bad-version" "$v" "bad-version"

echo "== READY / Socket-Type verdict =="

v=$(zmq_ready_socket_type "$LIVE_READY")
rc=$?
assert_rc "live monerod READY parses" "$rc" "0"
assert_eq "live monerod advertises XPUB" "$v" "ok XPUB"

# Reads the VALUE, not a constant: the same parser must report a different socket type.
assert_eq "a SUB peer is reported as SUB" "$(zmq_ready_socket_type "$READY_SUB")" "ok SUB"

# Long-frame encoding is legal ZMTP and no live node here produces it, so it needs its own case.
assert_eq "a LONG-framed READY parses" "$(zmq_ready_socket_type "$READY_LONG")" "ok XPUB"

# The near-miss sibling: a property whose VALUE is the literal "Socket-Type" precedes the real
# one. A substring match would answer with the decoy; walking the metadata answers XPUB.
assert_eq "a decoy Socket-Type VALUE does not win" "$(zmq_ready_socket_type "$READY_DECOY")" "ok XPUB"

v=$(zmq_ready_socket_type "")
rc=$?
assert_rc "greeting-then-silence is refused" "$rc" "1"
assert_contains "greeting-then-silence is named no-ready" "$v" "no-ready"

v=$(zmq_ready_socket_type "$READY_NO_SOCKET_TYPE")
rc=$?
assert_rc "READY without Socket-Type is refused" "$rc" "1"
assert_contains "missing Socket-Type is named" "$v" "no-socket-type"

v=$(zmq_ready_socket_type "0019$(printf '%s' "$READY_SUB" | cut -c5-)")
rc=$?
assert_rc "a non-COMMAND first frame is refused" "$rc" "1"
assert_contains "non-COMMAND frame is named malformed-ready" "$v" "malformed-ready"

echo "== the composed verdict, over raw target output (pure — no socket) =="

v=$(zmq_pub_verdict "GREETING $LIVE_GREETING
READY $LIVE_READY" 10.0.0.5 18083)
rc=$?
assert_rc "a real XPUB publisher passes" "$rc" "0"
assert_contains "the pass names the socket type" "$v" "XPUB"

v=$(zmq_pub_verdict "GREETING $LIVE_GREETING
READY $READY_SUB" 10.0.0.5 18083)
rc=$?
assert_rc "a ZMTP peer that is not a publisher is refused" "$rc" "1"
assert_contains "non-publisher is named socket-type-mismatch" "$v" "socket-type-mismatch"

v=$(zmq_pub_verdict "CONNECT-FAIL" 10.0.0.5 28098)
rc=$?
assert_rc "an unreachable port is refused" "$rc" "1"
assert_contains "unreachable port is named connect-refused" "$v" "connect-refused"

# The published-but-dead port, end to end: the snippet ran and the peer sent nothing. This is
# the row the preflight's dial reports as reachable.
v=$(zmq_pub_verdict "GREETING
READY" 10.0.0.5 28099)
rc=$?
assert_rc "a published-but-dead port is refused" "$rc" "1"
assert_contains "published-but-dead port is named no-greeting" "$v" "no-greeting"

# The verdict must name the endpoint it judged — a bare reason in a matrix log is unattributable.
assert_contains "the verdict names host:port" "$v" "28099"

echo "== a truncated or hostile frame is NAMED, not fatal (#1500) =="

# The defect this section guards is a parser that DIES on a short read: every length field is read
# with `16#`, and `16#` on an EMPTY string is a bash arithmetic error, so the function exits with
# an interpreter message on stderr and an empty verdict instead of a reason. It fails noisy rather
# than false-green, but an instrument that cannot say WHY is barely an instrument.
#
# Each case therefore asserts three things TOGETHER, and the stderr half is the load-bearing one:
# rc=1 alone was already true of the broken parser, so a case that checked only rc would have
# passed against the bug it exists to catch.
assert_clean_verdict() { # <label> <hex> <expected reason>
    local out err rc
    err=$(zmq_ready_socket_type "$2" 2>&1 >/dev/null)
    out=$(zmq_ready_socket_type "$2" 2>/dev/null)
    rc=$?
    assert_rc "$1 is refused" "$rc" "1"
    assert_contains "$1 is named" "$out" "$3"
    assert_eq "$1 costs no interpreter error" "$err" ""
}

# Found by fuzzing the parser over even-length hex, which is the only shape od can produce.
# A COMMAND frame that stops after its flags byte: the short-form size slice is empty.
assert_clean_verdict "a 1-byte short header" "2d" "malformed-ready"
# The same, long form (flags bit 0x02 set): the 8-byte size slice is empty.
assert_clean_verdict "a 1-byte long header" "2f" "malformed-ready"
# A long frame declaring 0xc40aba3454cc6862 bytes. That overflows the shell's own arithmetic and
# comes back NEGATIVE, which makes the body substring fatal in its own right — so the bound has to
# compare the declared size against what ARRIVED, not against a doubled length.
assert_clean_verdict "a long frame whose size overflows" "47c40aba3454cc6862" "malformed-ready"
# A COMMAND frame declaring a zero-length body: nothing left to read the command name from.
assert_clean_verdict "a frame declaring an empty body" "0400" "malformed-ready"
# THE ONE #1500 NAMES, and the only one reachable from a WELL-FORMED READY prefix: 18 bytes of
# "READY" + the "Socket-Type" key and nothing after it. `p` crosses `size` inside the iteration,
# so the loop test above cannot bound the 4-byte value-length read that follows.
assert_clean_verdict "a property length on the frame boundary" \
    "04120552454144590b536f636b65742d54797065" "malformed-ready"

# The guards must not have been bought by rejecting good frames: re-assert the live capture here,
# so a bound that is one byte too tight reds in this section rather than passing quietly above.
assert_eq "the live monerod frame still parses after the guards" \
    "$(zmq_ready_socket_type "$LIVE_READY")" "ok XPUB"
assert_eq "the long-framed READY still parses after the guards" \
    "$(zmq_ready_socket_type "$READY_LONG")" "ok XPUB"

echo "== the connect is bounded, and named apart from a refusal (#1500) =="

# A refusal is an ANSWER — host up, port closed. A timeout is the absence of one, and it points at
# a firewall, a partition or a wrong address rather than at the node. Collapsing them would send a
# remote-mode operator to debug the wrong box.
v=$(zmq_pub_verdict "CONNECT-TIMEOUT" 10.0.0.5 18083)
rc=$?
assert_rc "a filtered host is refused" "$rc" "1"
assert_contains "a filtered host is named connect-timeout" "$v" "connect-timeout"
assert_ne "a filtered host is NOT reported as a refusal" "${v%% *}" "connect-refused"

# Behavioural, not a text match on the snippet: run the real snippet against a closed loopback
# port. A bound that always waits the full budget would satisfy a text check and red here, and the
# elapsed half is what proves the added pre-connect did not become the new cost. The TIMEOUT class
# itself needs a black-holed address and so is proven live on the bench, not in this file.
start=$SECONDS
snippet_out=$(bash -c "$(zmq_probe_snippet 127.0.0.1 1 9)" 2>/dev/null)
elapsed=$((SECONDS - start))
assert_contains "a closed port still reports CONNECT-FAIL" "$snippet_out" "CONNECT-FAIL"
if [ "$elapsed" -lt 3 ]; then
    it_pass "a closed port returns in ${elapsed}s, well inside the 9s budget"
else
    it_fail "a closed port returns well inside the budget" "took ${elapsed}s of 9s"
fi

echo "== tier B: the peer must actually PUBLISH, not merely hold a socket open (#1497) =="

# The live half of this pair cannot run here (no node, no socket), so it is recorded rather than
# re-run. MEASURED on the bench 2026-08-30, one host, the SAME probe against both targets:
#
#   live monerod ZMQ 18083    tier A: ok … XPUB    tier B: ok, published in ~2s
#   silent XPUB 28100         tier A: ok … XPUB    tier B: silent, red at the budget
#
# The first column is the defect: tier A cannot tell those two apart, and says PASS for both. The
# silent XPUB is ~30 lines of python3 raw sockets — it completes the greeting and the READY
# exchange advertising XPUB, then publishes nothing, forever.

# Tier A must not have moved: it never subscribes, so its cost and its wire text are what shipped.
tier_a_snippet=$(zmq_probe_snippet 127.0.0.1 18083 8)
assert_eq "tier A sends no subscription" "$(printf '%s' "$tier_a_snippet" | grep -c 'x00.x01.x01')" "0"
assert_eq "tier A reads no PUBLISH" "$(printf '%s' "$tier_a_snippet" | grep -c 'PUBLISH')" "0"
# ...and asking for tier B must actually arm it. A budget that silently failed to appear would
# make every tier-B row pass for the wrong reason — the arming check, not a text preference.
tier_b_snippet=$(zmq_probe_snippet 127.0.0.1 18083 8 90)
assert_eq "tier B sends a subscription frame" "$(printf '%s' "$tier_b_snippet" | grep -c 'x00.x01.x01')" "1"
assert_contains "tier B bounds its wait at the budget it was given" "$tier_b_snippet" "timeout 90 head -c 1"

PUB_LIVE="GREETING $LIVE_GREETING
READY $LIVE_READY
PUBLISH 04"
PUB_SILENT="GREETING $LIVE_GREETING
READY $LIVE_READY
PUBLISH "
PUB_UNASKED="GREETING $LIVE_GREETING
READY $LIVE_READY"

zmq_publish_verdict "$PUB_LIVE" 127.0.0.1 18083 >/dev/null
assert_rc "a peer that sent a byte after subscribing is publishing" "$?" "0"
v=$(zmq_publish_verdict "$PUB_SILENT" 127.0.0.1 18083)
assert_rc "a peer that sent NOTHING is silent, not healthy" "$?" "1"
assert_contains "the silent verdict names what it could not see" "$v" "published NOTHING within the budget"
# Distinct from silence ON PURPOSE. A snippet run without a publish budget never asked the
# question, and reporting that as a silent node would be a fabricated failure.
v=$(zmq_publish_verdict "$PUB_UNASKED" 127.0.0.1 18083)
assert_rc "an un-asked question is not a silent node" "$?" "1"
assert_contains "the un-asked verdict says so" "$v" "not-probed"

# MUTATION PROOF: the emptiness guard is the whole assertion. Remove it and the silent fixture —
# the exact shape of an offline node — passes. Without this the cases above could all be green
# against a verdict that can never fail.
_mutated=$(
    zmq_publish_verdict() {
        local pub
        pub=$(printf '%s\n' "$1" | sed -n 's/^PUBLISH //p') # the [ -z "$pub" ] test, deliberately gone
        echo "ok published $pub"
    }
    zmq_publish_verdict "$PUB_SILENT" 127.0.0.1 18083 >/dev/null
    echo "$?"
)
assert_eq "without the emptiness guard the SILENT node passes (mutation proof)" "$_mutated" "0"

# Behavioural: a publish budget must not become the cost of an unreachable port. The connect
# fails first, so the 90s wait is never entered — a regression here would add 90s per scenario
# to a gate that is already failing.
start=$SECONDS
snippet_out=$(bash -c "$(zmq_probe_snippet 127.0.0.1 1 9 90)" 2>/dev/null)
elapsed=$((SECONDS - start))
assert_contains "a closed port still reports CONNECT-FAIL with tier B armed" "$snippet_out" "CONNECT-FAIL"
if [ "$elapsed" -lt 3 ]; then
    it_pass "a closed port with a 90s publish budget returns in ${elapsed}s"
else
    it_fail "a closed port does not pay the publish budget" "took ${elapsed}s"
fi

echo ""
echo "selftest-zmq-probe: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
