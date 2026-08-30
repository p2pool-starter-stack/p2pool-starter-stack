#!/usr/bin/env bash
#
# Self-test for the two redaction shapes #1582 found missing.
#
# redact() guarded two shapes — `KEY=value` for *_PASSWORD/*_TOKEN/*_SECRET, and v3 onion
# hostnames — and selftest.sh asserted exactly those four cases. So the coverage matched the
# implementation rather than the threat, and both gaps below were green by construction:
#
#   1. a credential passed as a FLAG value (`--rpc-login user:pass`). The KEY=value pattern
#      needs an `=`, so a colon-separated flag argument was never reachable by it.
#   2. a wallet address in JSON (`"wallet": "4…"`). Same reason — `"key": "value"` has no `=`.
#
# Both are live in `capture_artifacts`' bundle: the p2pool container logs its own argv, and
# `cat config.json` is captured verbatim. That bundle is what release-gate.yml uploads under
# the step name "Upload artifacts (redacted)".
#
# What makes this worth a file rather than a line: the artifact LOOKED redacted. The onion in
# that same argv line does get replaced, so a reader sees redaction visibly happening and reads
# the whole line as clean. A partial redaction is more dangerous than none, because it buys
# confidence it has not earned.
#
# The binding assertion in every case below is that the RAW value is ABSENT — not that a
# `<redacted>` marker appeared. A marker can appear because some OTHER field on the line was
# replaced, which is precisely the failure this file exists to catch.
#
# The pre-existing shapes stay covered by selftest.sh:202-210 and are deliberately not repeated
# here; that suite runs from the same Makefile glob.
#
# Run: tests/integration/selftest-redact.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

# Synthetic values throughout — nothing here is a real credential or a real address. The
# addresses only need the LENGTH and alphabet of the real thing for the shape rule to bite.
CRED="notARealPassword0123456789abcdef"
XMR="4$(printf 'A%.0s' $(seq 1 94))"   # 95 chars, Monero standard-address length
TARI="12$(printf 'B%.0s' $(seq 1 90))" # 92 chars, Tari address length
SHA="$(printf 'a%.0s' $(seq 1 64))"    # a sha256 — must SURVIVE, see over-redaction below

echo "== redact: a credential passed as a flag value =="
OUT="$(printf -- '--rpc-login admin:%s\n' "$CRED" | redact)"
assert_contains "flag credential is replaced" "$OUT" "--rpc-login <redacted>"
case "$OUT" in *"$CRED"*) it_fail "raw flag credential absent" "credential leaked" ;; *) it_pass "raw flag credential absent" ;; esac

# The `=` spelling of the same flag, and a differently-named secret flag: the rule is keyed on
# the flag's NAME ending in a secret word, so both must be reached by one pattern.
OUT="$(printf -- '--rpc-password=%s --api-token %s\n' "$CRED" "$CRED" | redact)"
case "$OUT" in *"$CRED"*) it_fail "raw credential absent for = and second flag" "credential leaked" ;; *) it_pass "raw credential absent for = and second flag" ;; esac

echo "== redact: wallet addresses, in JSON and as flag values =="
OUT="$(printf '  "wallet": "%s",\n  "tari_wallet": "%s",\n' "$XMR" "$TARI" | redact)"
case "$OUT" in *"$XMR"*) it_fail "raw Monero address absent from JSON" "address leaked" ;; *) it_pass "raw Monero address absent from JSON" ;; esac
case "$OUT" in *"$TARI"*) it_fail "raw Tari address absent from JSON" "address leaked" ;; *) it_pass "raw Tari address absent from JSON" ;; esac

# The shape that actually appears in logs.txt: an argv line carrying a credential, a wallet and
# an onion at once. This is the regression case — the onion alone used to be replaced, which is
# what made the rest look handled.
ONION="$(printf 'a%.0s' $(seq 1 56)).onion"
OUT="$(printf -- 'launching: p2pool --rpc-login admin:%s --wallet %s --onion-address %s --stratum 0.0.0.0:3333\n' "$CRED" "$XMR" "$ONION" | redact)"
case "$OUT" in *"$CRED"*) it_fail "argv line: credential absent" "credential leaked" ;; *) it_pass "argv line: credential absent" ;; esac
case "$OUT" in *"$XMR"*) it_fail "argv line: wallet absent" "wallet leaked" ;; *) it_pass "argv line: wallet absent" ;; esac
assert_contains "argv line: onion still redacted" "$OUT" "<redacted>.onion"
assert_contains "argv line: non-secret argument kept" "$OUT" "--stratum 0.0.0.0:3333"

echo "== redact: over-redaction guard — debugging value must survive =="
# "Over-redaction is safe" is true of secrets, not of everything: an artifact with the image
# digests and endpoints stripped is useless for the debugging it exists for. These are the
# near-misses — same alphabet, shorter than an address, or a flag whose name is not a secret.
OUT="$(printf 'sha256:%s\nHOST_IP=box.lan\n--merge-mine tari://node:18142\n' "$SHA" | redact)"
assert_contains "a sha256 digest survives" "$OUT" "$SHA"
assert_contains "a non-secret KEY=value survives" "$OUT" "HOST_IP=box.lan"
assert_contains "a non-secret flag value survives" "$OUT" "--merge-mine tari://node:18142"

echo "selftest-redact: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
