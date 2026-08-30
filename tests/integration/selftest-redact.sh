#!/usr/bin/env bash
#
# Self-test for the redaction shapes successive issues found missing: #1582's two to begin with,
# then #1587's JSON form, #1590's casing, and #1596's positional addresses. Sections are labelled.
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

echo "== redact: addresses by POSITION — the shape no length bar reaches (#1596) =="
# The p2pool launch line (docker-compose.yml:416-421) names the Monero address as `--wallet <addr>`
# and gives the Tari one as a BARE POSITIONAL after `--merge-mine tari://host:port`. A positional
# has no name to key on, so the >=90-char SHAPE rule was carrying both — and it reaches only one of
# the three Tari forms `28-parse-and-validate-config.sh` accepts: the base58 form clears 90 by a
# SINGLE character, and the other two sit far below it. Lowering the bar is not the fix — it starts
# matching ordinary log tokens, and no threshold reaches the emoji form at all. Hence POSITION.
#
# The cases below are written from the THREE FORMS the validator accepts, not from what the
# expression happens to handle — the failure #1582 was found by. Which case proves which arm is
# stated at ATTRIBUTION, because two of them are ALSO reachable by the length bar. The Monero
# address is NOT re-asserted per form — the --wallet path is identical on all three lines, so
# that would be one measurement printed three times; the two arms are proven to coexist on one
# line by the quoted COMMAND column case below, which asserts both.
TARI_B58="12$(printf 'B%.0s' $(seq 1 89))"                # 91 chars — cleared the old bar by ONE
TARI_SINGLE="1224$(printf 'C%.0s' $(seq 1 44))"           # 48 chars — below any usable bar
TARI_EMOJI="$(printf '\xf0\x9f\x90\xa2%.0s' $(seq 1 67))" # 67 glyphs, non-alphanumeric
for _form in "base58:$TARI_B58" "single:$TARI_SINGLE" "emoji:$TARI_EMOJI"; do
    _name="${_form%%:*}"
    _addr="${_form#*:}"
    OUT="$(printf -- 'p2pool --wallet %s --merge-mine tari://node:18142 %s --stratum 0.0.0.0:3333\n' \
        "$XMR" "$_addr" | redact)"
    case "$OUT" in
    *"$_addr"*) it_fail "argv positional: Tari $_name address absent" "address survived: $OUT" ;;
    *) it_pass "argv positional: Tari $_name address absent" ;;
    esac
done

# ATTRIBUTION. `single` and `emoji` are the rows that discriminate for the --merge-mine arm; the
# base58 row is 91 characters and the >=90 bar kills it either way. For the --wallet arm the
# discriminating case is a SHORT value — below every length bar and under no JSON key, so the
# POSITION rule is the only thing in redact() that can reach it. Without this row, deleting the
# --wallet pattern leaves this whole file green, the 95-char Monero fixture being caught twice.
SHORT_ARGV_WALLET="4ShortNotAnAddress"
OUT="$(printf -- 'p2pool --wallet %s --stratum 0.0.0.0:3333\n' "$SHORT_ARGV_WALLET" | redact)"
case "$OUT" in
*"$SHORT_ARGV_WALLET"*) it_fail "argv positional: a SHORT value after --wallet is redacted" "value survived: $OUT" ;;
*) it_pass "argv positional: a SHORT value after --wallet is redacted" ;;
esac

# The token match is GREEDY to the next space, deliberately, so it absorbs punctuation attached to
# the address — `compose-ps.txt` quotes its COMMAND column and the closing quote goes with it. The
# tidier alternative (stop the match at a quote) was MEASURED and refused: on `--wallet "<addr>"`
# it declines the leading quote, matches nothing, and the address survives WHOLE. Absorbing a
# quote is cosmetic; leaving one behind is the partial redaction this file exists to catch. Both
# quotings are pinned here so the trade-off cannot be reversed for tidiness without a red row.
OUT="$(printf -- 'itest-p2pool "/entrypoint.sh --wallet %s --merge-mine tari://n:1 %s" Up\n' \
    "$XMR" "$TARI_SINGLE" | redact)"
case "$OUT" in
*"$XMR"*) it_fail "quoted COMMAND column: Monero address absent" "address survived: $OUT" ;;
*) it_pass "quoted COMMAND column: Monero address absent" ;;
esac
case "$OUT" in
*"$TARI_SINGLE"*) it_fail "quoted COMMAND column: Tari address absent" "address survived: $OUT" ;;
*) it_pass "quoted COMMAND column: Tari address absent" ;;
esac
OUT="$(printf -- 'cmd --wallet "%s" --stratum 0.0.0.0:3333\n' "$TARI_SINGLE" | redact)"
case "$OUT" in
*"$TARI_SINGLE"*) it_fail "a QUOTED address after --wallet is redacted WHOLE" "address survived: $OUT" ;;
*) it_pass "a QUOTED address after --wallet is redacted WHOLE" ;;
esac

echo "== redact: over-redaction guard — debugging value must survive =="
# "Over-redaction is safe" is true of secrets, not of everything: an artifact with the image
# digests and endpoints stripped is useless for the debugging it exists for. These are the
# near-misses — same alphabet, shorter than an address, or a flag whose name is not a secret.
OUT="$(printf 'sha256:%s\nHOST_IP=box.lan\n--merge-mine tari://node:18142\n' "$SHA" | redact)"
assert_contains "a sha256 digest survives" "$OUT" "$SHA"
assert_contains "a non-secret KEY=value survives" "$OUT" "HOST_IP=box.lan"
assert_contains "a non-secret flag value survives" "$OUT" "--merge-mine tari://node:18142"
# The positional rule replaces the token AFTER the URI, never the URI itself, and refuses a token
# beginning with `-`: a flag is never an address, so a change in argument order cannot silently
# corrupt the line the endpoint explains. The assertion above is the same guard with the URI last.
OUT="$(printf -- 'p2pool --merge-mine tari://node:18142 --local-api --stratum 0.0.0.0:3333\n' | redact)"
assert_contains "the --merge-mine endpoint itself survives" "$OUT" "tari://node:18142"
assert_contains "a FLAG after the endpoint is not taken for an address" "$OUT" "--local-api"

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
# ⛔ THE .env HALF OF THIS VALUE WAS CLOSED (#1626); THIS ONE IS STILL OPEN. `NTFY_URL` fell to a
# specific suffix catching exactly itself. That does not transfer, because this key is the bare
# word `url` and only its nesting separates it from `xvb.url`. `ntfy_url` IS carried in both of
# redact()'s alternations, because #1611's invariant is that the two agree entry-for-entry — but
# measured against config.reference.json it reaches nothing, which is why this pin stays. The
# vocabulary entry is the price of the invariant, not evidence of coverage; this row is the
# evidence, and it asserts the value is NOT reached.
KNOWN_GAP="notifications.ntfy.url"

SENTINEL="S3nt1nelVALUE" # short, alphanumeric: reachable by the NAME rule and by no other
SCREENED="$(
    python3 - "$REF" "$HERE/lib.sh" <<'PY'
import json, re, sys

# INVARIANT: this screen must be a SUPERSET of redact()'s JSON name list, or a field carrying
# that suffix is never classified and the drift alarm above cannot fire for it. `wallet` is here
# for exactly that reason — it is in redact() and is reachable by no other alternative.
SCREEN = re.compile(r"(password|passwd|secret|token|login|username|user|key|wallet|address"
                    r"|seed|mnemonic|credential|urls?|hash_b64|pw_fp|auth|_id)$")


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
# The invariant above, MECHANICALLY (#1590): it shipped as a comment and was already false once,
# at `wallet`. Both lists are READ OUT of lib.sh — a list restated here is the drift this asserts.
lib = open(sys.argv[2], encoding="utf-8").read()
j = re.search(r"\[A-Za-z0-9_\]\*\(([a-z0-9_|]+)\)", lib)
e = re.search(r"\[A-Za-z0-9_\]\*\(([A-Z0-9_|]+)\)", lib)
if not j or not e or len(j.group(1).split("|")) < 8:
    print("!!could not read redact()'s two suffix vocabularies out of lib.sh")
else:
    for entry in j.group(1).split("|"):
        if not SCREEN.search(entry):
            print("!!the screen does not reach redact()'s JSON suffix: " + entry)
    d = set(j.group(1).split("|")) ^ {x.lower() for x in e.group(1).split("|")}
    if d:
        print("!!KEY=value and JSON vocabularies disagree (#1611): " + " ".join(sorted(d)))
PY
)"
# Violations are prefixed, so one python run reports both the population and the invariant.
VOCAB_BAD="$(printf '%s\n' "$SCREENED" | sed -n 's/^!!//p')"
SCREENED="$(printf '%s\n' "$SCREENED" | grep -v '^!!')"
[ -n "$SCREENED" ] || it_fail "screen over config.reference.json returns fields" "empty population"
if [ -n "$VOCAB_BAD" ]; then
    it_fail "redact()'s two suffix vocabularies agree, and the screen covers them" "$VOCAB_BAD"
else
    it_pass "redact()'s two suffix vocabularies agree, and the screen covers them"
fi

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

echo "== redact: the JSON name rule is CASE-INSENSITIVE (#1590) =="
# The suffix alternation shipped lowercase-only, so `apiKey`, `PASSWORD` and `Api_Token` were all
# unreachable — and redact()'s own comment ("add the spelling you meet") could NOT fix it: the
# failure is CASE, not spelling, so a contributor following that instruction adds more lowercase
# entries and still misses every camelCase key. `config.reference.json` is snake_case throughout,
# so the schema-derived population above cannot exercise this either. Hence explicit cases.
OUT="$(printf '{"apiKey":"%s","authToken":"%s","viewKey":"%s","PASSWORD":"%s","Api_Token":"%s"}\n' \
    "$SENTINEL" "$SENTINEL" "$SENTINEL" "$SENTINEL" "$SENTINEL" | redact)"
case "$OUT" in *"$SENTINEL"*) it_fail "camelCase and UPPERCASE secret keys redact" "value survived: $OUT" ;; *) it_pass "camelCase and UPPERCASE secret keys redact" ;; esac

# The other direction — the one the case widening could break. A non-secret key must not start
# redacting merely because a service spelled it in a different case. These are the MUST_SURVIVE
# fields above, in casings a service could plausibly emit; each would be a debugging value lost.
OUT="$(printf '{"URL":"https://xvb.example","Api_Auth":"token","Chat_Id":"12345","Mode":"local"}\n' | redact)"
assert_contains "case widening keeps a non-secret URL" "$OUT" '"URL":"https://xvb.example"'
assert_contains "case widening keeps an auth MODE string" "$OUT" '"Api_Auth":"token"'
assert_contains "case widening keeps a routing id" "$OUT" '"Chat_Id":"12345"'

echo "== redact: the two JSON shapes #1590 MEASURED and did not close =="
# Recorded at CURRENT behaviour with a label that cannot be misread as approval — the KNOWN_GAP
# convention above. Both were measured absent from every artifact `capture_artifacts` puts through
# redact() before the decision not to build them: ~48,400 JSON keys across the live container-log
# corpus (48 distinct; a PER-CONTAINER partition puts every one in caddy, the only service here
# that logs JSON — the other nine contribute exactly zero), 16,107 in a live `api-state.json`, 62
# in a deployed `config.json`, and two archived bundles. The log corpus is live, so those two
# counts are a snapshot and moved between captures; the distinct-key set did not. Not
# one key in any of them carries a secret suffix in ANY casing, escaped or with a non-string value.
# Fixing an unreachable shape that never occurs is cost with no benefit; if one ever occurs, these
# two rows fail and say which shape arrived.
OUT="$(printf '{"msg":"{\\"password\\":\\"%s\\"}"}\n' "$SENTINEL" | redact)"
assert_contains "KNOWN GAP (#1590) — JSON escaped inside a log string is NOT reached" "$OUT" "$SENTINEL"
OUT="$(printf '{"api_token":12345678,"password":null}\n' | redact)"
assert_contains "KNOWN GAP (#1590) — a non-string secret value is NOT reached" "$OUT" "12345678"
it_warn "KNOWN GAPS (#1590): escaped-JSON and non-string values are unreachable by the name rule — measured absent from every captured artifact, not fixed"

echo "selftest-redact: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
