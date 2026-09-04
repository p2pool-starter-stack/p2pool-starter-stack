#!/usr/bin/env bash
#
# Self-test for `support-bundle`'s CONTAINER-LOG redactor (#1585, #1750).
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

# --- BODY TEXT (#1750) --------------------------------------------------------------------------
# THE SECOND DEFECT, and why it needs a different KIND of rule. Every row above is a LAUNCH-LINE
# row: the redactor reaches those values by their POSITION in argv. #1736 gave this same and only
# redactor a second consumer — `diag-logs` and `diag-doctor` stream its output to a browser over
# the network — and p2pool also writes the payout wallet in ordinary body text (`Your wallet
# <ADDR> got a payout of ...`), where there is no argv position to key on. Demonstrated on the dev
# stack 2026-09-04.
#
# WHY A MONERO-ONLY SHAPE RULE IS TRACTABLE WHERE THE GENERAL ONE IS NOT. #1585 ruled out a length
# bar because the three Tari forms are 91, 48 and 67 characters and the last is non-alphanumeric,
# so no single bar reaches them without eating ordinary log tokens. Monero is the case that ruling
# leaves open, because its form is EXACT: prefix `4` or `8`, length 95 or 106, and the 58-character
# base58 alphabet that excludes `0`, `O`, `I` and `l`. That is precisely the shape gate
# `monero_address_type` applies before it decodes (25-address-types.sh), and the two have to stay
# in step — the "classifier agrees" rows below drive BOTH off the same three real addresses.
#
# NOT CLOSED HERE: a TARI address in body text still survives, by the ruling above. The launch-line
# rows keep their reach over the launch line; nothing in this section widens to Tari, and nothing
# should be read as though it did.
#
# LENGTH-EXACTNESS IS THE WHOLE SAFETY ARGUMENT, so it gets controls of its own: 94 characters, 96
# characters and a wrong prefix all SURVIVE. That is the same argument the onion row makes with its
# 55-character label. A rule that over-matched here would blank container ids and digests out of
# the one artifact support reads to find out what the stack was doing.

# Padded with `1`, which IS in the base58 alphabet — `0` is NOT, and a fixture carrying an
# out-of-alphabet character would make the SURVIVES rows pass for the wrong reason (the rule would
# miss it for a reason the row does not name). The arming block below measures alphabet AND length
# for every fixture before a single row runs.
b58pad() {
    local s="$1" n="$2"
    while [ "${#s}" -lt "$n" ]; do s="${s}1"; done
    printf '%s' "${s:0:$n}"
}

XMR_BODY_PRIMARY="$(b58pad 4SyntheticMoneroBodyAddressNotChecksumSafe 95)"
XMR_BODY_SUB="$(b58pad 8SyntheticMoneroSubaddressNotChecksumSafe 95)"
XMR_BODY_INTEGRATED="$(b58pad 4SyntheticMoneroPaymentEmbeddedNotChecksumSafe 106)"
XMR_NEAR_SHORT="$(b58pad 4SyntheticMoneroNinetyFourCharsNotAnAddress 94)"
XMR_NEAR_LONG="$(b58pad 4SyntheticMoneroNinetySixCharsNotAnAddress 96)"
XMR_NEAR_PREFIX="$(b58pad 5SyntheticMoneroWrongPrefixNotAnAddress 95)"
SHA256_HEX="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Well-known PUBLIC donation addresses, never ours: XMRig's (primary), the Monero project's
# (subaddress), and that project's integrated fixture. The same three tests/stack/lib.sh carries,
# repeated rather than sourced because that file belongs to another tier. They are here so ONE row
# can drive the classifier and the redactor off the SAME value — a synthetic address cannot do
# that, since none of ours passes a checksum.
# shellcheck disable=SC2034  # read by NAME through ${!_name} in the loops below, which shellcheck
# cannot follow. Naming them is the point: the arming row and the classifier row have to print WHICH
# fixture moved, and a bare value in a list cannot say that.
XMR_REAL_PRIMARY="48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"
# shellcheck disable=SC2034  # same: read through ${!_name}
XMR_REAL_SUBADDR="888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
# shellcheck disable=SC2034  # same: read through ${!_name}
XMR_REAL_INTEGRATED="4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijGDpDGTWtLM516v46mB"

# The shipped classifier, run the same way brl() runs the shipped redactor.
mat() { (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    monero_address_type "$1"
); }

# One line in, one verdict out. The binding assertion stays an ABSENCE, as everywhere above.
body_redacted() { # <name> <line> <secret>
    local name="$1" out
    out="$(printf '%s\n' "$2" | brl)"
    case "$out" in
    *"$3"*) it_fail "$name" "value survived: $out" ;;
    *) it_pass "$name" ;;
    esac
}

body_kept() { # <name> <line> <token-that-must-survive>
    local name="$1" out
    out="$(printf '%s\n' "$2" | brl)"
    case "$out" in
    *"$3"*) it_pass "$name" ;;
    *) it_fail "$name" "over-redacted: $out" ;;
    esac
}

echo "== unit: the body-text fixtures are base58-shaped and exactly as long as they claim (#1750) =="
for _f in "XMR_BODY_PRIMARY:95" "XMR_BODY_SUB:95" "XMR_BODY_INTEGRATED:106" \
    "XMR_NEAR_SHORT:94" "XMR_NEAR_LONG:96" "XMR_NEAR_PREFIX:95" \
    "XMR_REAL_PRIMARY:95" "XMR_REAL_SUBADDR:95" "XMR_REAL_INTEGRATED:106"; do
    _name="${_f%%:*}"
    _want="${_f##*:}"
    _val="${!_name}"
    if [ "${#_val}" != "$_want" ]; then
        it_fail "$_name is $_want base58 characters" "length is ${#_val}"
        continue
    fi
    case "$_val" in
    *[!1-9A-HJ-NP-Za-km-z]*)
        it_fail "$_name is $_want base58 characters" \
            "out-of-alphabet character — a SURVIVES row against this would pass for the wrong reason"
        ;;
    *) it_pass "$_name is $_want base58 characters" ;;
    esac
done

echo "== unit: a Monero address in log BODY text is redacted (#1750) =="

# ATTRIBUTION: not one of these lines carries an argv position, so the shape rule is the only thing
# in the redactor that can reach them — delete it and every row in this section reds together.
body_redacted "the payout line p2pool actually writes is redacted" \
    "P2Pool SideChain Your wallet $XMR_BODY_PRIMARY got a payout of 0.001 XMR" "$XMR_BODY_PRIMARY"
body_redacted "an address after a 'Wallet address:' label is redacted" \
    "P2Pool SideChain  Wallet address: $XMR_BODY_PRIMARY" "$XMR_BODY_PRIMARY"
body_redacted "an address alone on a line is redacted" \
    "$XMR_BODY_PRIMARY" "$XMR_BODY_PRIMARY"
body_redacted "an address inside a JSON string value is redacted" \
    "{\"address\":\"$XMR_BODY_PRIMARY\",\"ok\":true}" "$XMR_BODY_PRIMARY"
body_redacted "a SUBADDRESS (8..., 95) in body text is redacted" \
    "credited $XMR_BODY_SUB today" "$XMR_BODY_SUB"
body_redacted "an INTEGRATED address (4..., 106) in body text is redacted" \
    "credited $XMR_BODY_INTEGRATED today" "$XMR_BODY_INTEGRATED"

# The doctor document goes through this same redactor as TEXT (46a-control-diagnostics.sh), and
# `control_diag_doctor` refuses anything that stops parsing as JSON. This row is that backstop's
# other half: the value goes, the structure stays.
body_kept "redacting inside JSON leaves the structure parseable" \
    "{\"address\":\"$XMR_BODY_PRIMARY\",\"ok\":true}" '","ok":true}'

# TWO addresses separated by ONE space. The rule has to CONSUME a boundary character on each side
# (POSIX ERE has no lookaround, and BSD sed — a supported host, see safe_sed — has no \b), so the
# first match eats the space that is the second address's left boundary and a single pass leaves
# the second value standing. This row is why bundle_redact_log applies the shape rule TWICE; drop
# either `-e` and it reds while every other row here stays green.
echo "== unit: adjacent addresses on one line are both redacted (#1750) =="
OUT="$(printf 'paid %s %s\n' "$XMR_BODY_PRIMARY" "$XMR_BODY_SUB" | brl)"
_leaked=""
for _v in "$XMR_BODY_PRIMARY" "$XMR_BODY_SUB"; do
    case "$OUT" in *"$_v"*) _leaked="$_leaked $_v" ;; esac
done
if [ -z "$_leaked" ]; then
    it_pass "two addresses one space apart are both redacted"
else
    it_fail "two addresses one space apart are both redacted" "survived:$_leaked"
fi

# The redactor's shape rule and the classifier's shape gate are two statements of one form. These
# rows drive both off the same real value, so a change to either that breaks the agreement reds
# here rather than being discovered on a live stack.
echo "== unit: the shape rule covers what monero_address_type accepts (#1750) =="
for _f in "XMR_REAL_PRIMARY:primary" "XMR_REAL_SUBADDR:subaddress" "XMR_REAL_INTEGRATED:integrated"; do
    _name="${_f%%:*}"
    _want="${_f##*:}"
    _val="${!_name}"
    assert_eq "monero_address_type calls $_name a $_want address" "$(mat "$_val")" "$_want"
    body_redacted "the address the classifier calls '$_want' is redacted in body text" \
        "p2pool: payout sent to $_val, height 3210987" "$_val"
done

# --- NEGATIVE CONTROLS FOR THE SHAPE RULE -------------------------------------------------------
# Length-exact and prefix-anchored, or the rule is a general length bar by another name — the exact
# thing #1585 ruled out. Each of these is one step off a real address and must survive untouched.
echo "== unit: the Monero shape rule is length-exact and prefix-anchored (#1750) =="
body_kept "a 94-character base58 token survives" \
    "candidate $XMR_NEAR_SHORT accepted" "$XMR_NEAR_SHORT"
body_kept "a 96-character base58 token survives" \
    "candidate $XMR_NEAR_LONG accepted" "$XMR_NEAR_LONG"
body_kept "a 95-character token with a non-address prefix survives" \
    "candidate $XMR_NEAR_PREFIX accepted" "$XMR_NEAR_PREFIX"
body_kept "a sha256 digest survives" \
    "image sha256:$SHA256_HEX pulled" "$SHA256_HEX"

echo "selftest-bundle-redact-log: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
