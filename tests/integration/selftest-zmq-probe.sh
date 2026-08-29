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

echo ""
echo "selftest-zmq-probe: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
