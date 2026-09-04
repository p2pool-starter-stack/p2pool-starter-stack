# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Differential test (#944): docs/tools/recovery-config-builder.html carries JS ports of the two
# address gates in lib/pithead/25-address-types.sh, so an operator authoring a recovery config on
# a laptop finds a mistyped payout address there instead of after a boot cycle.
#
# That is duplication across a language boundary, and nothing but this test can see it drift: the
# page is static, offline and has no server to defer to. So the two sides are driven over ONE
# corpus and their verdicts compared string for string. The page exposes the seam deliberately — a
# `module.exports` of both gate functions, guarded by `typeof module`, inert in a browser.
#
# The corpus covers every verdict BOTH gates can return (monero: primary/subaddress/integrated/
# checksum/invalid; tari: ok/checksum/network/invalid). An enumeration where every row came back
# the same way would not have been shown able to say anything else.
#
# Two mutation controls at the end make the comparison FAIL on purpose, because a comparison that
# has never disagreed is not evidence that the two sides agree.

echo "== unit: the recovery page's address gates agree with lib/pithead/25-address-types.sh (#944) =="

_rag_page="$ROOT/docs/tools/recovery-config-builder.html"

# node is not optional here and must never degrade to a silent skip: `make test` already runs
# `node --test` for the frontend domain, so its absence is a broken environment, not a platform
# this suite tolerates. Asserting (rather than returning quietly) also keeps domain_ran happy —
# a domain file that contributes no assertions is itself a failure (#1400).
if ! command -v node >/dev/null 2>&1 || [ ! -f "$_rag_page" ]; then
    bad "recovery page gates: prerequisites present" \
        "need node on PATH and $_rag_page — the JS ports went UNCHECKED"
    return 0
fi

# A wrong-network Tari address, in the emoji form so it needs no base58 encoder to state: network
# byte 0x01 (a testnet), the interactive feature bit, filler, and a last byte solved so DammSum
# reads 0. Without it the corpus never reaches tari_address_type's `network` branch and the port's
# copy of that branch would be carried untested.
_rag_tari_net="📟📟🐢🤔🌲🍄🍋🍓🥝🍭🍷🎂🎠🎨🎱🎺🏁🏭🦁🐙🐣🐯🐷👀👖👟👽💊🔒💩💻📿🚰🔩🥐"

# Mainnet, DammSum-valid, but its feature byte sets a bit tari defines no feature for (known:
# one-sided 1, interactive 2, payment-id 4) — the last thing tari_address_type checks, and the
# only fixture here that reaches it. Both sides must call it invalid.
_rag_tari_bits="🐢🌕🐢🌰🥑🍑🍦🍶🎈🎨🎷🏆🐌🐛🐮🐻👖👣💋💦📈🔌🔬😱🚓🚽🌕🍀🍍🍟🍳🎂🎤🎲🥑"

# Shape-valid (4…, 95 chars) but its second 11-character block is all 'z': 58^11-1 exceeds the
# 8 bytes a block decodes to, so the block-wise decode must refuse it before any checksum runs.
# Monero's base58 is block-wise, NOT Bitcoin's whole-string scheme, and this overflow guard is
# the part of that difference a port is most likely to drop. Both sides must call it invalid.
_rag_mon_overflow="4$(printf '1%.0s' $(seq 10))$(printf 'z%.0s' $(seq 11))$(printf '1%.0s' $(seq 73))"

# label<TAB>kind<TAB>address. Mutations are derived from the fixtures rather than pasted, so a
# fixture change cannot leave a stale hand-typed near-copy behind claiming to be its mutant.
_rag_cases=$(
    printf '%s\t%s\t%s\n' \
        "monero primary" monero "$VALID_PRIMARY" \
        "monero subaddress" monero "$VALID_SUBADDR" \
        "monero integrated" monero "$VALID_INTEGRATED" \
        "monero one char flipped" monero "${VALID_PRIMARY:0:50}B${VALID_PRIMARY:51}" \
        "monero shape ok checksum bad" monero "4$(printf 'A%.0s' $(seq 94))" \
        "monero truncated" monero "${VALID_PRIMARY:0:94}" \
        "monero not an address" monero "1abc" \
        "monero block overflows" monero "$_rag_mon_overflow" \
        "tari base58" tari "$VALID_TARI" \
        "tari emoji" tari "$VALID_TARI_EMOJI" \
        "tari single" tari "$VALID_TARI_SINGLE" \
        "tari one char flipped" tari "${VALID_TARI:0:20}B${VALID_TARI:21}" \
        "tari wrong network" tari "$_rag_tari_net" \
        "tari truncated" tari "${VALID_TARI:0:44}" \
        "tari not an address" tari "notanaddress" \
        "tari unknown feature bits" tari "$_rag_tari_bits"
)

# The page's verdicts, one per corpus line. Loads the shipped HTML, runs its WHOLE script under a
# DOM stub — so the file as shipped is what executes, not an extract of the parts under test — and
# reads the gates back off the export seam. $1 optionally names a mutation to apply to the page's
# own copy first; that is how the controls below make this disagree.
_rag_js_verdicts() { # [damm|keccak] < label\tkind\taddr lines
    RAG_MUTATE="${1:-}" node -e '
const fs = require("fs");
const html = fs.readFileSync(process.env.RAG_PAGE, "utf8");
const m = html.match(/<script>\n([\s\S]*?)\n<\/script>/);
if (!m) { console.error("no <script> block in the page"); process.exit(2); }
let src = m[1];
if (process.env.RAG_MUTATE === "damm")   src = src.replace("if (overflow) r ^= 27;", "if (overflow) r ^= 29;");
if (process.env.RAG_MUTATE === "keccak") src = src.replace("pad.push(0x01);", "pad.push(0x06);");
const stub = () => ({ value:"", checked:false, className:"", textContent:"", disabled:false,
  style:{}, setAttribute(){}, addEventListener(){}, appendChild(){}, removeChild(){}, select(){}, click(){} });
const els = {};
const document = { getElementById: id => els[id] || (els[id] = stub()), createElement: stub,
  body: stub(), addEventListener(){}, execCommand: () => false };
const mod = { exports: {} };
new Function("document","navigator","URL","Blob","module", src)(
  document, {}, { createObjectURL: () => "", revokeObjectURL(){} }, class {}, mod);
if (typeof mod.exports.moneroAddressType !== "function" || typeof mod.exports.tariAddressType !== "function") {
  console.error("the page did not export both gates"); process.exit(2);
}
for (const line of fs.readFileSync(0, "utf8").split("\n")) {
  if (!line) continue;
  const [, kind, addr] = line.split("\t");
  console.log(kind === "monero" ? mod.exports.moneroAddressType(addr) : mod.exports.tariAddressType(addr));
}
'
}

RAG_PAGE="$_rag_page"
export RAG_PAGE

_rag_js=$(printf '%s\n' "$_rag_cases" | _rag_js_verdicts)
assert_eq "recovery page gates: the page ran and answered every case" \
    "$(printf '%s\n' "$_rag_js" | grep -c .)" "$(printf '%s\n' "$_rag_cases" | grep -c .)"

# The shipped gate, called the way every other caller calls it.
_rag_shipped() { # <kind> <addr>
    if [ "$1" = monero ]; then
        run_sourced "$SANDBOX" monero_address_type "$2"
    else
        run_sourced "$SANDBOX" tari_address_type "$2"
    fi
}

_rag_seen_monero="" _rag_seen_tari=""
_rag_i=0
while IFS=$'\t' read -r label kind addr; do
    [ -n "$label" ] || continue
    _rag_i=$((_rag_i + 1))
    js=$(printf '%s\n' "$_rag_js" | sed -n "${_rag_i}p")
    sh=$(_rag_shipped "$kind" "$addr")
    assert_eq "recovery page gates agree — $label" "$js" "$sh"
    if [ "$kind" = monero ]; then
        _rag_seen_monero="$_rag_seen_monero $sh"
    else
        _rag_seen_tari="$_rag_seen_tari $sh"
    fi
done <<RAGEOF
$_rag_cases
RAGEOF

# Both gates' whole verdict space, from the SHIPPED side. A corpus that only ever produced one
# verdict would agree perfectly and prove nothing about the branches it never reached.
for _rag_v in primary subaddress integrated checksum invalid; do
    assert_contains "recovery page gates: the corpus reaches monero verdict '$_rag_v'" \
        "$_rag_seen_monero" "$_rag_v"
done
for _rag_v in ok checksum network invalid; do
    assert_contains "recovery page gates: the corpus reaches tari verdict '$_rag_v'" \
        "$_rag_seen_tari" "$_rag_v"
done

# --- controls: the comparison above must be able to FAIL ------------------------------------
# Each mutates ONE constant in the page's copy of an algorithm and asserts the verdict moves. If a
# control ever goes quiet, the comparison above has stopped measuring the port and is passing for
# some other reason.

# DammSum's coefficient: every checksum-valid Tari address should stop verifying.
_rag_damm=$(printf '%s\ttari\t%s\n' "control" "$VALID_TARI" | _rag_js_verdicts damm)
assert_eq "recovery page gates CONTROL: a wrong DammSum coefficient breaks a valid tari address" \
    "$_rag_damm" "checksum"
assert_eq "recovery page gates CONTROL: ... and the shipped gate still calls it ok" \
    "$(run_sourced "$SANDBOX" tari_address_type "$VALID_TARI")" "ok"

# Monero uses LEGACY Keccak-256 (pad byte 0x01), not NIST SHA3-256 (0x06) — the single mistake
# most likely to be made porting this, and it is silent: hashlib.sha3_256 and a stray 0x06 both
# produce a digest, just the wrong one.
_rag_keccak=$(printf '%s\tmonero\t%s\n' "control" "$VALID_PRIMARY" | _rag_js_verdicts keccak)
assert_eq "recovery page gates CONTROL: NIST SHA3 padding instead of legacy Keccak breaks a valid primary" \
    "$_rag_keccak" "checksum"
assert_eq "recovery page gates CONTROL: ... and the shipped gate still calls it primary" \
    "$(run_sourced "$SANDBOX" monero_address_type "$VALID_PRIMARY")" "primary"

unset _rag_page _rag_cases _rag_js _rag_i _rag_v _rag_damm _rag_keccak _rag_tari_net
unset _rag_tari_bits _rag_mon_overflow
unset _rag_seen_monero _rag_seen_tari RAG_PAGE
