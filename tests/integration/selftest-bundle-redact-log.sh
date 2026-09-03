#!/usr/bin/env bash
#
# Self-test for `support-bundle`'s CONTAINER-LOG redactor (#1585).
#
# THE DEFECT. `stack_support_bundle` scrubbed container logs with one argv pattern naming three
# flags (`--rpc-login`, `--http-access-token`, `--tls-fingerprint`). The p2pool launch line it was
# written for carries three MORE secrets, verified at source in `docker-compose.yml:416-423` and
# `lib/pithead/36-quadlet-units.sh:233`: the Monero address after `--wallet`, the Tari address as
# the bare positional after `--merge-mine tari://<host:port>`, and the service onion after
# `--onion-address`. The same function's `.env` half already redacts WALLET and ONION keys, so one
# artifact shipped two policies — redacting these values out of `env.redacted` and back in through
# `logs/p2pool.log`.
#
# WHY POSITION AND NOT SHAPE (ruled on the issue, comment 5467691003). No length threshold reaches
# the Tari address: the three forms this repo validates are 91, 48 and 67 characters, the last
# non-alphanumeric, so a `{90,}` bar clears one by a single character and reaches neither other.
# Rows 2-4 below are that argument pinned — one row per form, all three killed by ONE positional
# rule that never looks at the value. The onion keeps its own SHAPE rule rather than being folded
# into a positional pattern, because it is the one value that also appears off the launch line.
# Keying on position is what `tests/integration/lib.sh`'s `redact()` has done since #1607, so the
# two redactors now key on the same property instead of drifting apart again (#1586).
#
# HOW THIS FILE MEASURES. It sources the REAL built `pithead` and calls the shipped
# `bundle_redact_log`. Nothing is restated here — a copy of the sed program in a test would be
# green by construction against itself. Sourcing is the shipped contract, not a trick:
# `00-prelude.sh:97-99` sets `_STACK_SOURCED=1` when `BASH_SOURCE[0]` differs from `$0` and skips
# every side effect (the cd, the traps, and `main`).
#
# EVERY ASSERTION HERE IS AN ABSENCE, WHICH IS WHY THE ARMING BLOCK IS NOT OPTIONAL. A source that
# failed would return empty output and green every row silently. The arming block proves the
# function is reachable before a single value is measured, and row 7 is a NEGATIVE control proving
# the filter is not simply blanking the line.
#
# The binding assertion in each row is that the RAW value is ABSENT — never that a marker
# appeared, since a marker can come from another field on the same line. Every fixture is
# synthetic and none is checksum-valid; they exercise LENGTH and SHAPE, which is all these rules
# read.
#
# Run: tests/integration/selftest-bundle-redact-log.sh
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

REPO="$(cd -P "$HERE/../.." && pwd -P)"

# Run the SHIPPED function in a subshell, so sourcing the artifact cannot leak definitions or a
# readonly CONFIG_FILE into this harness. `source` reads from /dev/null so it can never consume
# the payload on stdin.
brl() { (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    bundle_redact_log
); }

# --- ARMING -----------------------------------------------------------------------------------
# Without this, a broken source makes every absence assertion below pass vacuously.
echo "== unit: support-bundle log redactor is reachable (#1585) =="
if (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    declare -F bundle_redact_log >/dev/null
); then
    it_pass "bundle_redact_log is defined by the built pithead"
else
    it_fail "bundle_redact_log is defined by the built pithead" \
        "source failed or the function is absent — every row below would pass vacuously"
    exit 1
fi
if [ -n "$(printf 'sentinel-passthrough\n' | brl)" ]; then
    it_pass "the redactor emits its input (the harness can observe a value at all)"
else
    it_fail "the redactor emits its input (the harness can observe a value at all)" \
        "empty output — an absence assertion against this is meaningless"
    exit 1
fi

# --- FIXTURES ---------------------------------------------------------------------------------
MONERO_ADDR="4SyntheticMoneroAddressNotChecksumValid0000000000000000000000000000000000000000000000000000"
TARI_B58="SyntheticTariBase58AddressNotChecksumValid00000000000000000000000000000000000000000000000"
TARI_SINGLE="SyntheticTariSingleAddress000000000000000000000"
TARI_EMOJI="🐢🍄🌊🎂🐎🦀🍒🌂🎩🐌🐋🍯🌵🐜🦆🌟🎈🐙🍇🌴🐝🎪🍕🌻🐳🎯🍋🌙🐧🎨🍓🌺🐨🎭🍑🌸🐢🍄🌊🎂🐎🦀🍒🌂🎩🐌🐋🍯🌵🐜🦆🌟🎈🐙🍇🌴🐝🎪🍕🌻🐳🎯🍋🌙🐧"
ONION="synthetic2onion4address6base32chars7abcdefghijklmnopqrst.onion"
RPC_USER="bundleuser"
RPC_PASS="Sup3rS3cretRpcPass"

echo "== unit: support-bundle redacts every secret on p2pool's launch line (#1585) =="

# ATTRIBUTION, rows 1-4. The bundle redactor has NO length or shape rule, so a positional rule is
# the only thing in it that can reach any of these four values: delete the `--wallet` rule and row
# 1 reds alone; delete the `--merge-mine` rule and rows 2-4 red together, which is correct — they
# are three forms through ONE arm, named separately because the issue's ruling turns on the claim
# that no single shape rule covers all three.
OUT="$(printf -- '--wallet %s --stratum 0.0.0.0:3333\n' "$MONERO_ADDR" | brl)"
case "$OUT" in
*"$MONERO_ADDR"*) it_fail "the Monero address after --wallet is redacted" "value survived: $OUT" ;;
*) it_pass "the Monero address after --wallet is redacted" ;;
esac

for _form in B58 SINGLE EMOJI; do
    case "$_form" in
    B58) _addr="$TARI_B58" ;;
    SINGLE) _addr="$TARI_SINGLE" ;;
    EMOJI) _addr="$TARI_EMOJI" ;;
    esac
    OUT="$(printf -- '--merge-mine tari://172.28.0.27:18142 %s --local-api\n' "$_addr" | brl)"
    case "$OUT" in
    *"$_addr"*) it_fail "the Tari address ($_form form) after --merge-mine is redacted" "value survived: $OUT" ;;
    *) it_pass "the Tari address ($_form form) after --merge-mine is redacted" ;;
    esac
done

# ATTRIBUTION, row 5: reached by the `.onion` SHAPE rule alone — no positional pattern names
# `--onion-address`, deliberately, so the same rule also covers an onion logged anywhere else.
OUT="$(printf -- '--onion-address %s --local-api\n' "$ONION" | brl)"
case "$OUT" in
*"$ONION"*) it_fail "the service onion after --onion-address is redacted" "value survived: $OUT" ;;
*) it_pass "the service onion after --onion-address is redacted" ;;
esac

# ATTRIBUTION, row 6: the PRE-EXISTING credential rule. Pinned so this change cannot regress the
# one class the redactor already covered.
OUT="$(printf -- '--rpc-login %s:%s --zmq-port 18083\n' "$RPC_USER" "$RPC_PASS" | brl)"
case "$OUT" in
*"$RPC_PASS"*) it_fail "the --rpc-login credential is redacted" "value survived: $OUT" ;;
*) it_pass "the --rpc-login credential is redacted" ;;
esac

# --- NEGATIVE CONTROL -------------------------------------------------------------------------
# The bundle exists to give support the STRUCTURE — ports, hosts, modes. A redactor that ate the
# whole line would pass every row above. This row fails if it does.
echo "== unit: support-bundle keeps the structure support actually needs (#1585) =="
OUT="$(printf -- '--stratum 0.0.0.0:3333 --p2p 0.0.0.0:37889 --data-api /stats\n' | brl)"
_kept=1
for _tok in "--stratum" "0.0.0.0:3333" "--p2p" "0.0.0.0:37889" "--data-api" "/stats"; do
    case "$OUT" in *"$_tok"*) : ;; *) _kept=0 ;; esac
done
if [ "$_kept" = 1 ]; then
    it_pass "non-secret launch-line structure survives redaction"
else
    it_fail "non-secret launch-line structure survives redaction" "over-redacted: $OUT"
fi

# --- THE WHOLE LINE ---------------------------------------------------------------------------
# The rows above each isolate one arm. This one is the artifact the operator is asked to send us:
# every secret on the real launch line, in the real order, measured together — because a rule that
# works alone can be shadowed by an earlier `-e` that already consumed its separator.
echo "== unit: no secret survives the full p2pool launch line (#1585) =="
OUT="$(printf -- '--host 172.28.0.26 --rpc-port 18081 --rpc-login %s:%s --zmq-port 18083 --wallet %s --merge-mine tari://172.28.0.27:18142 %s --onion-address %s --local-api --stratum 0.0.0.0:3333\n' \
    "$RPC_USER" "$RPC_PASS" "$MONERO_ADDR" "$TARI_B58" "$ONION" | brl)"
_leaked=""
for _v in "$RPC_PASS" "$MONERO_ADDR" "$TARI_B58" "$ONION"; do
    case "$OUT" in *"$_v"*) _leaked="$_leaked $_v" ;; esac
done
if [ -z "$_leaked" ]; then
    it_pass "the full launch line leaves no secret in the bundle"
else
    it_fail "the full launch line leaves no secret in the bundle" "survived:$_leaked"
fi

echo "selftest-bundle-redact-log: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
