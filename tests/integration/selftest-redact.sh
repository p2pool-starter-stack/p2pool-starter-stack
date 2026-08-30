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

echo "== redact: the JSON shape, keyed on the field name (#1587) =="
# #1582 was the argv shape. This is the JSON one, and it could not be fixed the same way: a
# view key and a container digest are both 64 hex characters, so nothing in the VALUE separates
# them. The rule is therefore keyed on the field NAME's suffix — the opposite of the argv fix,
# deliberately, because that case had a usable value shape and this one does not.
#
# The population below is DERIVED from config.reference.json rather than listed here, so a
# sensitive field added to the schema later cannot quietly go uncovered. The screen that selects
# it is deliberately BROADER than redact()'s own list: if the two lists were the same, this file
# would be green by construction — the exact defect #1582 was found by.
REF="$(cd "$HERE/../.." && pwd)/config.reference.json"

# Hand-classified, and the classification is the judgement this test encodes. A field the screen
# picks up that appears in NEITHER list fails below by name, so the schema cannot drift past it.
MUST_REDACT="monero.wallet_address monero.node_username monero.node_password monero.view_key
tari.wallet_address tari.view_key tari.spend_public_key p2pool.stratum_password xvb.donor_id
xmrig_proxy.donor_id dashboard.auth.username dashboard.auth.password workers.api_token
ssh.authorized_key healthchecks.ping_url telegram.bot_token notifications.ntfy.token"
# Survivors, each for a stated reason — over-redaction is safe for secrets and not for anything
# else: a bundle with its endpoints stripped is useless for the debugging it exists for.
#   xvb.url / xmrig_proxy.url  public service endpoints
#   workers.api_auth           an auth MODE string ("token"/"none"), not a credential
#   telegram.chat_id           a routing id, not a secret
MUST_SURVIVE="xvb.url xmrig_proxy.url workers.api_auth telegram.chat_id"
# ⛔ NOT a survivor on merit. `notifications.ntfy.url` IS a capability URL and ought to be
# redacted; a line-wise filter cannot reach it, because the key is the bare word "url" and only
# its NESTING distinguishes it from xvb.url. Asserted at its CURRENT behaviour so the gap is
# stated rather than hidden — when someone closes it, this line fails and moves to MUST_REDACT.
KNOWN_GAP="notifications.ntfy.url"

SENTINEL="S3nt1nelVALUE" # short, alphanumeric: reachable by the NAME rule and by no other
SCREENED="$(
    python3 - "$REF" <<'PY'
import json, re, sys

# INVARIANT: this screen must be a SUPERSET of redact()'s JSON name list, or a field carrying
# that suffix is never classified and the drift alarm above cannot fire for it. `wallet` is here
# for exactly that reason — it is in redact() and is reachable by no other alternative.
SCREEN = re.compile(r"(password|passwd|secret|token|login|username|key|wallet|address|seed"
                    r"|mnemonic|credential|url|auth|_id)$")


def walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}" if path else k)
    elif isinstance(node, list):
        for v in node:
            yield from walk(v, path + "[]")
    else:
        yield path, node


for path, value in walk(json.load(open(sys.argv[1], encoding="utf-8"))):
    if isinstance(value, str) and SCREEN.search(path.split(".")[-1]):
        print(path)
PY
)"
[ -n "$SCREENED" ] || it_fail "screen over config.reference.json returns fields" "empty population"

# Word-splitting, not a `case` glob: the lists above wrap across lines, and a space-delimited
# haystack silently misses every entry sitting next to a newline.
in_list() { # <field> <list>
    local needle="$1" item
    for item in $2; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

for field in $SCREENED; do
    key="${field##*.}"
    out="$(printf '  "%s": "%s",\n' "$key" "$SENTINEL" | redact)"
    if ! in_list "$field" "$MUST_REDACT $MUST_SURVIVE $KNOWN_GAP"; then
        it_fail "config.reference.json field $field is classified" \
            "new sensitive-looking field — add it to MUST_REDACT or MUST_SURVIVE with a reason"
        continue
    fi
    if in_list "$field" "$MUST_REDACT"; then
        case "$out" in
        *"$SENTINEL"*) it_fail "$field redacted in JSON" "raw value survived: $out" ;;
        *) it_pass "$field redacted in JSON" ;;
        esac
        continue
    fi
    # The gap gets a label that cannot be misread as approval. A green row saying a secret-bearing
    # field "survives redaction" is exactly the confidence this file exists to refuse.
    if in_list "$field" "$KNOWN_GAP"; then
        assert_contains "KNOWN GAP (#1587) — $field is NOT redacted and should be" "$out" "$SENTINEL"
        continue
    fi
    assert_contains "$field survives redaction" "$out" "$SENTINEL"
done
it_warn "KNOWN GAP (#1587): $KNOWN_GAP is a capability URL and is NOT redacted — nesting is invisible to a line-wise filter"

# A value containing an escaped quote must be replaced WHOLE. A pattern stopping at the first
# quote would leave the tail behind, which is the partial-redaction failure this file exists for.
OUT="$(printf '  "node_password": "ab\\"%s",\n' "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "escaped quote inside a secret value" "tail survived: $OUT" ;; *) it_pass "escaped quote inside a secret value" ;; esac

# Measured read-only against the live stack: `api-state.json` carries both wallet addresses, and
# it carries them under the leaf key `wallet` — not under a secret-sounding name. Before the name
# rule they were reached only by the >=90 length bar, which is the coincidence #1587 objects to.
# A SHORT value under that key is what discriminates: no other rule in redact() can reach it.
SHORTWALLET="4ShortNotAnAddress"
OUT="$(printf '{"stratum":{"wallet":"%s"},"tari":{"wallet":"%s"}}\n' "$SHORTWALLET" "$SHORTWALLET" | redact)"
case "$OUT" in *"$SHORTWALLET"*) it_fail "a short value under a \"wallet\" key is redacted by NAME" "value survived: $OUT" ;; *) it_pass "a short value under a \"wallet\" key is redacted by NAME" ;; esac

# `passwd`, `secret` and `login` have no field in today's schema, so the derived population
# above cannot exercise them. They are forward cover, mirroring the flag-value rule's word list —
# and an unexercised pattern is one typo away from being dead, so they get an explicit case.
OUT="$(printf '{"passwd":"%s","client_secret":"%s","rpc_login":"%s"}\n' "$SENTINEL" "$SENTINEL" "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "the spellings passwd/secret/login redact, though no schema field uses them" "value survived: $OUT" ;; *) it_pass "the spellings passwd/secret/login redact, though no schema field uses them" ;; esac

# Compact JSON on one line — api-state.json is not pretty-printed, and a per-line filter has to
# replace every occurrence on that line, not just the first.
OUT="$(printf '{"username":"%s","mode":"local","view_key":"%s","port":18081}\n' "$SENTINEL" "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "compact JSON: both secrets on one line" "value survived: $OUT" ;; *) it_pass "compact JSON: both secrets on one line" ;; esac
assert_contains "compact JSON: non-secret neighbours survive" "$OUT" '"mode":"local"'

echo "selftest-redact: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
