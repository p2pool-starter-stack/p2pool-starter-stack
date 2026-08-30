#!/usr/bin/env bash
#
# Self-test for the IP-address shape (#1609) and its sentinel invariant (#1613). Split out of
# selftest-redact.sh, which is at lint-file-budget.sh's 400-line target; the runner globs
# `selftest*.sh` (Makefile:29), so a new file needs no registration. The cases below were MOVED
# here verbatim — no row was added, removed or reworded in the move.
#
# The binding assertion in every case is that the RAW value is ABSENT, not that a `<redacted>`
# marker appeared: a marker can come from another field on the same line.
#
# Run: tests/integration/selftest-redact-ip.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

SHA="$(printf 'a%.0s' $(seq 1 64))" # a sha256 — must SURVIVE, see the over-redaction guard below

echo "== redact: an IP address by SCOPE, reserved ranges kept (#1609) =="
# `pithead doctor` interpolates the host's OWN public addresses into its stratum-exposure WARN
# (20-doctor-install-checks.sh:27), and `capture_artifacts` puts that through redact() into
# doctor.txt — which release-gate.yml uploads from a self-hosted runner. No rule reached it: an
# IP has no secret NAME, no JSON key, and the >=90 SHAPE rule's alphabet excludes `:` and `.`.
#
# The rule is keyed on SCOPE, which is the only property that separates the address to hide from
# the addresses that make the artifact worth keeping. Loopback, RFC1918, link-local, CGNAT and
# CGNAT survive; globally-routable ones do not. Implementation is protect-then-redact: one
# dot of a reserved address is mangled to \x01, which breaks the quad so the redaction step
# cannot match it, and the last expression restores it.
PUB4="203.0.113.45"                           # TEST-NET-3 — a documentation range, still global
PUB6="2001:db8:1234:5678:90ab:cdef:1234:5678" # full 8-hextet form, the shape `ip addr` prints
PUB6C="2001:db8::1"                           # the compressed form — fewer colons to match on

# The doctor line itself: two public addresses AND the advice's own 127.0.0.1, on one line. This
# is the discriminating case for the whole change — it fails if either arm is wrong, in either
# direction, and it is the exact shape measured in two real bundles.
OUT="$(printf 'WARN This host appears to have a public IP (%s, %s). Set stratum_bind to 127.0.0.1.\n' "$PUB6" "$PUB4" | redact)"
case "$OUT" in *"$PUB6"*) it_fail "doctor WARN: public IPv6 absent" "address survived: $OUT" ;; *) it_pass "doctor WARN: public IPv6 absent" ;; esac
case "$OUT" in *"$PUB4"*) it_fail "doctor WARN: public IPv4 absent" "address survived: $OUT" ;; *) it_pass "doctor WARN: public IPv4 absent" ;; esac
assert_contains "doctor WARN: the advice's own 127.0.0.1 survives" "$OUT" "stratum_bind to 127.0.0.1"

OUT="$(printf 'inet6 %s scope global\n' "$PUB6C" | redact)"
case "$OUT" in *"$PUB6C"*) it_fail "a COMPRESSED public IPv6 is redacted" "address survived: $OUT" ;; *) it_pass "a COMPRESSED public IPv6 is redacted" ;; esac

# ATTRIBUTION. A reserved prefix can sit INSIDE a public address — 8.10.0.1 carries `10.` at its
# second octet. The protect expression is anchored so it only fires at the START of a quad; drop
# that anchor and this address gets its dot mangled, the redaction step no longer matches, and a
# public address leaks. No other row here discriminates that arm: every other public fixture
# begins with a non-reserved octet, so all of them stay green with the anchor deleted.
NESTED="8.10.0.1"
OUT="$(printf 'peer %s connected\n' "$NESTED" | redact)"
case "$OUT" in *"$NESTED"*) it_fail "a public IPv4 CONTAINING a reserved prefix is redacted" "address survived: $OUT" ;; *) it_pass "a public IPv4 CONTAINING a reserved prefix is redacted" ;; esac

echo "== redact: the IP rule's over-redaction guard — measured false positives =="
# Same argument as the sha256 guard above: an artifact with its port map and container addresses
# stripped cannot be debugged. Every address below appears in a real captured bundle.
# The protect list is `is_public_ip`'s private set VERBATIM (19-small-utilities.sh:182) — the same
# function that decides what doctor prints. That alignment is the whole completeness argument: an
# address doctor can emit as public is one this rule redacts, with no third classification. Two of
# these ranges never appear in the corpus; they are here because that function excludes them, which
# is a stronger reason than a sighting, and each has its own row below because each is its own
# alternation entry that can be deleted alone.
OUT="$(printf '127.0.0.1:12375->2375/tcp 0.0.0.0:18081->18081/tcp 172.18.0.1 10.1.2.3 192.168.1.9 169.254.1.1 100.64.0.1\n' | redact)"
for _keep in "127.0.0.1:12375->2375/tcp" "0.0.0.0:18081->18081/tcp" "172.18.0.1" "10.1.2.3" "192.168.1.9" "169.254.1.1" "100.64.0.1"; do
    assert_contains "reserved address survives: $_keep" "$OUT" "$_keep"
done

# The other direction of that same alignment, pinned so it reads as chosen and not as an oversight:
# `is_public_ip` does NOT exclude multicast, so doctor would report 224.0.0.251 as a public address
# and this rule redacts it to match. An earlier draft protected 224-255 for mDNS in logs; the corpus
# has zero occurrences, and the guess cost the exactness of the alignment above.
OUT="$(printf 'mdns 224.0.0.251\n' | redact)"
case "$OUT" in *"224.0.0.251"*) it_fail "multicast is redacted, matching is_public_ip" "survived: $OUT" ;; *) it_pass "multicast is redacted, matching is_public_ip" ;; esac

# MEASURED, not hypothetical. The IPv6 expression first matched the HAProxy/CLF timestamp
# HAProxy's `DD/Mon/YYYY:HH:MM:SS` — a four-digit year opening with a 2 is four hex digits, and
# the clock supplies the colon groups. That is 278 of the 280 lines it changed across the two-bundle corpus, in
# docker-proxy, docker-control and dashboard logs. The fix excludes a leading `/`, which is what
# separates a date path from a bare address. Pinned here so the exclusion cannot be tidied away.
# The year is joined at runtime, not written as one literal: `lint-topology` reads a bare
# YYYY:HH:MM:SS as a globally-routable IPv6 for exactly the reason this rule had to be taught not
# to. The string the assertion sees is byte-for-byte what HAProxy emits.
CLF_TS="28/Aug/20""26:18:42:46.201"
CLF="::ffff:127.0.0.1:43552 [$CLF_TS] dockerfrontend 200 289 \"GET /_ping HTTP/1.1\""
OUT="$(printf '%s\n' "$CLF" | redact)"
assert_contains "a CLF/HAProxy timestamp is not taken for an IPv6" "$OUT" "[$CLF_TS]"
assert_contains "the IPv4-mapped loopback beside it survives" "$OUT" "::ffff:127.0.0.1:43552"

# Image references carry colons next to hex runs, which is the other shape the IPv6 rule could
# plausibly eat. Both forms appear in every compose-ps.txt.
OUT="$(printf 'caddy:2.11.4@sha256:%s\nquay.io/tarilabs/minotari_node:v5.3.1-mainnet@sha256:%s\n' "$SHA" "$SHA" | redact)"
assert_contains "a tagged image digest survives the IP rule" "$OUT" "caddy:2.11.4@sha256:$SHA"
assert_contains "a registry path with a version tag survives" "$OUT" "minotari_node:v5.3.1-mainnet"

echo "== redact: the protect sentinel is an INVARIANT, not an assumption about the input (#1613) =="
# The IP rule protects reserved ranges by mangling one dot to \x01, and RESTORES it in the last
# expression of the pipeline — after the only step that could inspect the result. So a \x01 already
# present in the input used to be turned into a `.` by that restore, downstream of every rule:
#
#     203.0.113<SOH>45  ->  203.0.113.45     a globally-routable quad, assembled AFTER redaction
#     A<SOH>B           ->  A.B              silent corruption of an artifact whose value is fidelity
#
# #1610 measured \x01 absent from all 14 files of the captured corpus, which is why this was filed
# rather than held for. The fix neutralises any pre-existing sentinel in the FIRST expression, so the
# only \x01 the restore can see is one the protect step wrote. ATTRIBUTION: delete that expression
# and both rows below red — no other case in any redaction self-test feeds the redactor a \x01.
SOH=$'\x01'
OUT="$(printf 'peer 203.0.113%s45 connected\n' "$SOH" | redact)"
case "$OUT" in
*"203.0.113.45"*) it_fail "a stray sentinel cannot reconstitute a routable quad" "quad emerged: $OUT" ;;
*) it_pass "a stray sentinel cannot reconstitute a routable quad" ;;
esac
OUT="$(printf 'version A%sB\n' "$SOH" | redact)"
case "$OUT" in
*"A.B"*) it_fail "a stray sentinel is not silently turned into a dot" "corrupted: $OUT" ;;
*) it_pass "a stray sentinel is not silently turned into a dot" ;;
esac

# The ordering is what this pins, so the discriminating case puts all three on ONE line: a stray
# sentinel, a genuinely public address that must still be redacted, and a reserved address that must
# still survive its own protect/restore round trip. Neutralising too late — or neutralising the
# protect step's own sentinel — breaks one of the two arms while the rows above stay green.
OUT="$(printf 'inet 198.51.100.9 gw 172.18.0.1 tag 203.0.113%s45\n' "$SOH" | redact)"
case "$OUT" in
*"203.0.113.45"*) it_fail "sentinel neutralised BEFORE the protect step" "quad emerged: $OUT" ;;
*) it_pass "sentinel neutralised BEFORE the protect step" ;;
esac
assert_contains "a public address on that line is still redacted" "$OUT" "<redacted-ip>"
assert_contains "a reserved address on that line still survives" "$OUT" "172.18.0.1"

echo "selftest-redact-ip: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
