#!/usr/bin/env bash
#
# Self-test for the `KEY=value` shape (#1611). A separate file because selftest-redact.sh sits
# just under lint-file-budget.sh's 400-line target; the runner globs `selftest*.sh`
# (Makefile:29), so a new file needs no registration.
#
# The defect was a DISAGREEMENT, not a missing spelling. redact() already treated `wallet` as a
# secret key name — in its JSON rule. On a `KEY=value` line only two rules could bite: a name
# rule listing three uppercase spellings, and the >=90-character length rule. So the same field
# carrying the same value was classified two ways depending only on the syntax it arrived in:
#
#     {"wallet":"4Short…"}           ->  {"wallet":"<redacted>"}
#     MONERO_WALLET_ADDRESS=4Short…  ->  MONERO_WALLET_ADDRESS=4Short…   (before this change)
#
# The fix keys the `KEY=value` rule on the JSON rule's own suffix vocabulary rather than adding
# one more spelling to a second list. selftest-redact.sh asserts mechanically that the two lists
# still agree, so this cannot drift back apart silently.
#
# MEASURED before it shipped, over `env.redacted.txt` in two archived bundles and the deployed
# `.env` (129 / 127 / 129 keys): the widening newly reaches exactly TEN keys, the same ten in all
# three populations, and changes NOTHING in the other six captured artifacts — zero lines across
# 307 KB of logs.txt, status.txt, doctor.txt, config.json, api-state.json and compose-ps.txt.
# That is the answer to the risk this change had to clear: the replacement takes the whole rest
# of the line, so a widened match could have stripped a debugging value. It reaches none.
# Six of the ten still carried a raw value under the redactor as it stood, a 64-hex Monero view
# key among them.
#
# Every fixture here is synthetic. The binding assertion in each case is that the RAW value is
# ABSENT — never that a `<redacted>` marker appeared, since a marker can come from another field
# on the same line.
#
# Run: tests/integration/selftest-redact-env.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

SENTINEL="S3nt1nelVALUE" # short, alphanumeric: reachable by the NAME rule and by no other

echo "== redact: KEY=value keyed on the JSON rule's vocabulary (#1611) =="
# ATTRIBUTION. Every key below is BELOW the 90-character bar, carries no JSON quoting and no
# `--flag`, so the name rule is the only thing in redact() that can reach it: delete the rule and
# every row reds. ONE key per vocabulary entry that `.env` exercises, deliberately. The corpus
# showed six keys still leaking, but `TARI_SPEND_PUBLIC_KEY` and `DASHBOARD_ONION_CLIENT_PRIVKEY`
# both end in `KEY` like `MONERO_VIEW_KEY` — asserting all three is one measurement printed three
# times, and a single mutation killed all three together. They are named here instead.
# PASSWORD / TOKEN / SECRET stay covered by selftest.sh:202-210 and are not repeated. PASSWD,
# LOGIN and the rest have no `.env` field and need no forward-cover row of their own: the
# vocabulary invariant in selftest-redact.sh asserts this list IS the JSON one, so an entry cannot
# quietly go missing here without that check failing.
for _key in MONERO_VIEW_KEY WALLET_RPC_USERNAME XVB_DONOR_ID HEALTHCHECKS_PING_URL; do
    OUT="$(printf '%s=%s\n' "$_key" "$SENTINEL" | redact)"
    case "$OUT" in
    *"$SENTINEL"*) it_fail "$_key is redacted in a KEY=value line" "value survived: $OUT" ;;
    *) it_pass "$_key is redacted in a KEY=value line" ;;
    esac
done

# The three Tari forms `28-parse-and-validate-config.sh` accepts, as `.env` renders them. The
# base58 form is the one the old length bar reached, by a single character; the other two sat
# below it, and the emoji form is unreachable by any bound because the bar's alphabet is
# alphanumeric. Only the short and emoji rows discriminate — stated, so the base58 row is not
# read as proof of anything the length rule was not already doing.
TARI_B58="12$(printf 'B%.0s' $(seq 1 89))"                # 91 chars — cleared the old bar by ONE
TARI_SINGLE="1224$(printf 'C%.0s' $(seq 1 44))"           # 48 chars — below any usable bar
TARI_EMOJI="$(printf '\xf0\x9f\x90\xa2%.0s' $(seq 1 67))" # 67 glyphs, non-alphanumeric
for _form in "base58:$TARI_B58" "single:$TARI_SINGLE" "emoji:$TARI_EMOJI"; do
    _name="${_form%%:*}"
    _addr="${_form#*:}"
    OUT="$(printf 'TARI_WALLET_ADDRESS=%s\n' "$_addr" | redact)"
    case "$OUT" in
    *"$_addr"*) it_fail "TARI_WALLET_ADDRESS: the $_name form is redacted" "address survived: $OUT" ;;
    *) it_pass "TARI_WALLET_ADDRESS: the $_name form is redacted" ;;
    esac
done

# The name rule runs before the length rule, so a wallet line that both reach now reports
# `<redacted>` where it used to report `<redacted-address>`. Pinned because it is a deliberate
# trade and not an oversight: one vocabulary across both syntaxes is worth more than the hint
# that the value happened to be an address, and the JSON rule already emitted the plain marker.
XMR="4$(printf 'A%.0s' $(seq 1 94))" # 95 chars, Monero standard-address length
OUT="$(printf 'MONERO_WALLET_ADDRESS=%s\n' "$XMR" | redact)"
assert_contains "a wallet KEY=value reports the plain marker, as JSON does" "$OUT" "=<redacted>"

# The old rule's prefix was `.*`, which is GREEDY: on a line carrying two secret keys it matched
# the LAST one and left the first value in place. This is a real shape — `docker inspect` and
# `pithead status` print several assignments on one line. The vocabulary prefix is
# `[A-Za-z0-9_]*`, which cannot cross the space, so the match starts at the FIRST key and the
# replacement takes the rest of the line with it. Restore the `.*` prefix and this row reds.
OUT="$(printf 'A_TOKEN=%s B_TOKEN=%s\n' "$SENTINEL" "$SENTINEL" | redact)"
case "$OUT" in
*"$SENTINEL"*) it_fail "two secret keys on ONE line: neither value survives" "value survived: $OUT" ;;
*) it_pass "two secret keys on ONE line: neither value survives" ;;
esac

echo "== redact: the KEY=value over-redaction guard — debugging value must survive =="
# The scalar fields selftest-redact.sh pins as JSON survivors, in the spelling `.env` uses.
# Holding the two syntaxes to one vocabulary means holding them to the same survivors too: a
# bundle with its endpoints and routing ids stripped is useless for the triage it exists for.
# `XVB_URL` is the sharp one — only `PING_URL` is in the vocabulary, so a bare `_URL` survives.
OUT="$(printf 'XVB_URL=https://xvb.example\nWORKERS_API_AUTH=token\nTELEGRAM_CHAT_ID=12345\nSTACK_VERSION=v1.20.0\n' | redact)"
assert_contains "a public endpoint survives" "$OUT" "XVB_URL=https://xvb.example"
assert_contains "an auth MODE string survives" "$OUT" "WORKERS_API_AUTH=token"
assert_contains "a routing id survives" "$OUT" "TELEGRAM_CHAT_ID=12345"
assert_contains "an ordinary setting survives" "$OUT" "STACK_VERSION=v1.20.0"

# Over-redaction that IS chosen, pinned so it cannot be filed later as a bug: any key ending in
# `KEY` is replaced, `CACHE_KEY` included. That is the JSON rule's documented behaviour (#1590)
# and narrowing it would mean guessing which `*_KEY` is a secret from its name. This row shares
# the `KEY` arm with the loop above and adds no coverage — it records the POLICY, so that a later
# reader meeting a redacted `CACHE_KEY` finds it chosen rather than filing it.
OUT="$(printf 'CACHE_KEY=%s\n' "$SENTINEL" | redact)"
case "$OUT" in
*"$SENTINEL"*) it_fail "an innocuous *_KEY is redacted too, as in JSON" "value survived: $OUT" ;;
*) it_pass "an innocuous *_KEY is redacted too, as in JSON" ;;
esac

# ⛔ STATED, not approved. Unlike the JSON rule this one is CASE-SENSITIVE, so a lowercase
# assignment is not reached. `.env` is generated by `pithead` from config.json and is uppercase
# throughout — #1590 measured all 129 keys — so nothing in the captured population needs it, and
# a case-insensitive `key=.*` would eat the rest of any log line containing `key=`. If a
# lowercase secret assignment ever needs covering, this row fails and names the shape.
OUT="$(printf 'monero_view_key=%s\n' "$SENTINEL" | redact)"
assert_contains "KNOWN GAP (#1611) — a lowercase KEY=value is NOT reached" "$OUT" "$SENTINEL"
it_warn "KNOWN GAP (#1611): the KEY=value rule is uppercase-only — .env is generated uppercase, and a case-insensitive rule would eat log lines"

echo "selftest-redact-env: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
