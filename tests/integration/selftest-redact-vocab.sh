#!/usr/bin/env bash
#
# Self-test for redact()'s coverage of the RENDERED `.env` population (#1621). A separate file
# because selftest-redact.sh sits just under lint-file-budget.sh's 400-line target; the runner
# globs `selftest*.sh` (Makefile:29), so a new file needs no registration.
#
# WHY THIS EXISTS, and why it is not "one more spelling". #1596 was a redactor keyed to a LENGTH,
# failing on the input that was short. #1609 had no rule for an IP at all. #1611 was two
# vocabularies keyed to spellings that had drifted apart. #1616 unified them onto one list, which
# is the right fix and also means a name absent from that single list is now unreached by BOTH
# rules at once. Every one of those was found by someone looking; none was found by a test.
#
# A vocabulary is a denylist over a key set someone else keeps extending, so it fails silently and
# in the unsafe direction. This file is the check that fires instead: the population is DERIVED
# from the single heredoc `render_env` writes (33-render-env.sh), so a `.env` key added later
# cannot quietly go unclassified. The screen that selects candidates is deliberately BROADER than
# redact()'s own vocabulary — if the two were the same list, this file would be green by
# construction, which is the defect #1582 was found by and the one selftest-redact.sh guards
# against for config.reference.json. This is that guard, for the other population.
#
# MEASURED before it shipped, over all 129 rendered keys with both live rules: 19 redacted, 110
# surviving. Of the survivors, four carried a credential and were reached by nothing —
# DASHBOARD_AUTH_HASH_B64 (base64 of a caddy bcrypt hash, 80 chars), DASHBOARD_AUTH_PW_FP (an
# unsalted sha256 of the password, 64 hex), NOTIFY_WEBHOOK_URLS (webhook URLs, token-in-path) and
# DASHBOARD_AUTH_USER. That last one is the sharp one: three username fields, and two were reached
# only because the vocabulary carries `USERNAME` while this one ends in `USER`.
#
# ⛔ TWO ROWS THAT LOOK LIKE GAPS AND ARE NOT. `XMRIG_API_AUTH` renders `.workers.api_auth`, the
# enum none|name|token, and `DASHBOARD_ONION_CLIENT_AUTH` renders a normalize_bool() result, so it
# is literally `true` or `false`. Neither can carry a secret. They are pinned as SURVIVORS below,
# because adding a bare `AUTH` suffix would redact both and protect nothing — it would strip
# diagnostic state out of the bundle for no gain. Same for a bare `URL`, which would take the four
# public endpoints the bundle exists to carry and STILL miss NOTIFY_WEBHOOK_URLS (it ends `URLS`).
#
# Every fixture here is synthetic. The binding assertion for a redacted key is that the RAW value
# is ABSENT — never that a `<redacted>` marker appeared, since a marker can come from another
# field on the same line.
#
# Run: tests/integration/selftest-redact-vocab.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

RENDER="$(cd "$HERE/../.." && pwd)/lib/pithead/33-render-env.sh"

# Hand-classified, and the classification IS the judgement this file encodes. A screened key in
# none of these lists fails below BY NAME, so the rendered schema cannot drift past it.
MUST_REDACT="DASHBOARD_AUTH_HASH_B64 DASHBOARD_AUTH_PW_FP DASHBOARD_AUTH_USER
DASHBOARD_ONION_CLIENT_PRIVKEY DASHBOARD_ONION_CLIENT_PUBKEY HEALTHCHECKS_PING_URL
MONERO_NODE_PASSWORD MONERO_NODE_USERNAME MONERO_VIEW_KEY MONERO_WALLET_ADDRESS
NOTIFY_WEBHOOK_URLS NTFY_TOKEN NTFY_URL PROXY_AUTH_TOKEN PROXY_STRATUM_PASSWORD TARI_SPEND_PUBLIC_KEY
TARI_VIEW_KEY TARI_WALLET_ADDRESS TARI_WALLET_PASSWORD TELEGRAM_BOT_TOKEN WALLET_RPC_PASSWORD
WALLET_RPC_USERNAME XMRIG_API_TOKEN XVB_DONOR_ID"

# Survivors, each for a stated reason. Over-redaction is safe for a secret and unsafe for anything
# else: a bundle with its endpoints and routing ids stripped is useless for the triage it exists
# for. The two AUTH rows are the ones #1621's own table mislabelled as credentials — see above.
#   XMRIG_API_AUTH               an auth MODE enum (none|name|token), not a credential
#   DASHBOARD_ONION_CLIENT_AUTH  a normalize_bool() result — literally `true` or `false`
#   TELEGRAM_CHAT_ID             a routing id
#   P2POOL_URL / XVB_POOL_URL    public service endpoints
#   MONERO_WALLET_RPC_URL        an in-stack endpoint the bundle is read against
#   TARI_GRPC_ADDRESS / TARI_WALLET_GRPC_ADDRESS  host:port endpoints the bundle is read against
# ⛔ STATED, not settled, for that last pair: in LOCAL mode they are bridge addresses inside the
# stack and the IP rule's private-range protect keeps them readable, which is what a reader needs.
# In REMOTE mode (#103) TARI_GRPC_ADDRESS is a third-party host, so a bundle discloses it. That is
# a topology question rather than a credential one, it is not what #1621 asked, and narrowing it
# here would strip the local-mode value that makes a bundle worth reading. Left surviving and named
# so the next reader meets a decision rather than an oversight.
MUST_SURVIVE="XMRIG_API_AUTH DASHBOARD_ONION_CLIENT_AUTH TELEGRAM_CHAT_ID P2POOL_URL XVB_POOL_URL
MONERO_WALLET_RPC_URL TARI_GRPC_ADDRESS TARI_WALLET_GRPC_ADDRESS"

# ⛔ `NTFY_URL` WAS pinned here as a known gap, on the reason that the bare word `URL` could not be
# added without taking every public endpoint above with it. True, and it was never the technique
# this file uses: a SPECIFIC suffix, measured against the whole rendered population. `NTFY_URL`
# catches exactly itself across all 129 keys, so it is now a MUST_REDACT row (#1626).
#
# ⛔ ITS JSON SIBLING DID NOT MOVE WITH IT, AND THAT IS NOT AN OVERSIGHT. `notifications.ntfy.url`
# stays a known gap in selftest-redact.sh for a DIFFERENT reason that measurement confirms: that
# key is the bare word `url`, and only its NESTING separates it from `xvb.url`, which a line-wise
# filter cannot see. `ntfy_url` is carried in BOTH alternations regardless, because #1611's
# invariant is that they agree entry-for-entry; on the JSON side it reaches nothing today. The
# two are the same VALUE and no longer the same GAP.

# Redacted, but by a SHAPE rule rather than the name rule — so a name-shaped sentinel would report
# them as leaking and be wrong. Listed separately BECAUSE that difference is invisible otherwise:
# a synthetic value cannot reach a shape rule, which is how a sweep over key NAMES reports a false
# gap. Each is asserted at the shape redact() actually keys on.
SHAPE_COVERED="DASHBOARD_ONION_ADDRESS MONERO_ONION_ADDRESS P2POOL_ONION_ADDRESS TARI_ONION_ADDRESS"

SENTINEL="S3nt1nelVALUE"                                               # short, alphanumeric: reachable by the NAME rule and by no other
ONION="abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion" # 56-char v3, the shape rule

# Word-splitting, not a `case` glob: the lists above wrap across lines, and a space-delimited
# haystack silently misses every entry sitting next to a newline (#1611's sibling defect).
in_list() { # <key> <list>
    local needle="$1" item
    for item in $2; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

echo "== redact: every credential-shaped .env key is classified and reached (#1621) =="

# The population is READ OUT of the renderer, never restated here — a list copied into this file
# is exactly the drift it exists to catch. The screen is broader than redact()'s vocabulary.
SCREENED="$(
    python3 - "$RENDER" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read().split("\n")
try:
    start = next(i for i, l in enumerate(src) if l.strip() == 'cat <<EOF >"$target"')
    end = next(i for i, l in enumerate(src) if i > start and l == "EOF")
except StopIteration:
    print("!!could not locate render_env's .env heredoc in 33-render-env.sh")
    raise SystemExit(0)

keys = sorted({m.group(1) for l in src[start + 1:end] if (m := re.match(r"^([A-Z][A-Z0-9_]*)=", l))})
if len(keys) < 100:
    print(f"!!the .env population read as only {len(keys)} keys — the heredoc bounds moved")
    raise SystemExit(0)

# INVARIANT: this screen must be a SUPERSET of redact()'s KEY=value vocabulary, or a key carrying
# one of those suffixes is never classified and the drift alarm below cannot fire for it.
SCREEN = re.compile(r"(password|passwd|secret|token|login|username|user|key|wallet|address|seed"
                    r"|mnemonic|credential|urls?|auth|hash|hash_b64|pw_fp|fp|_id|onion)$", re.I)
for k in keys:
    if SCREEN.search(k):
        print(k)
PY
)"
POP_BAD="$(printf '%s\n' "$SCREENED" | sed -n 's/^!!//p')"
SCREENED="$(printf '%s\n' "$SCREENED" | grep -v '^!!')"
if [ -n "$POP_BAD" ]; then
    it_fail "the .env population is derived from render_env" "$POP_BAD"
elif [ -z "$SCREENED" ]; then
    it_fail "the .env population is derived from render_env" "screen returned nothing"
else
    it_pass "the .env population is derived from render_env"
fi

for key in $SCREENED; do
    if ! in_list "$key" "$MUST_REDACT $MUST_SURVIVE $SHAPE_COVERED"; then
        it_fail ".env key $key is classified" \
            "new credential-shaped key — add it to MUST_REDACT or MUST_SURVIVE with a reason"
        continue
    fi
    if in_list "$key" "$MUST_REDACT"; then
        OUT="$(printf '%s=%s\n' "$key" "$SENTINEL" | redact)"
        case "$OUT" in
        *"$SENTINEL"*) it_fail "$key is redacted" "raw value survived: $OUT" ;;
        *) it_pass "$key is redacted" ;;
        esac
        continue
    fi
    if in_list "$key" "$SHAPE_COVERED"; then
        OUT="$(printf '%s=%s\n' "$key" "$ONION" | redact)"
        case "$OUT" in
        *"$ONION"*) it_fail "$key is redacted by the .onion shape rule" "raw value survived: $OUT" ;;
        *) it_pass "$key is redacted by the .onion shape rule" ;;
        esac
        continue
    fi
    OUT="$(printf '%s=%s\n' "$key" "$SENTINEL" | redact)"
    case "$OUT" in
    *"$SENTINEL"*) it_pass "$key survives, as a bundle needs it to" ;;
    *) it_fail "$key survives, as a bundle needs it to" "over-redacted: $OUT" ;;
    esac
done

it_warn "STILL OPEN (#1626): notifications.ntfy.url is the same capability URL in the other syntax and stays unreached — its key is the bare word url, separated from xvb.url only by NESTING. Pinned in selftest-redact.sh."

echo "selftest-redact-vocab: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
