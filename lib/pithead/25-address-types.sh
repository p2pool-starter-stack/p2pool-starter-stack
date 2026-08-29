# Classify a Monero MAINNET address:
#   primary/standard  "4…" 95   — the ONLY kind p2pool can pay (coinbase) and XvB credits by.
#   integrated        "4…" 106  — embeds a payment id; p2pool rejects it.
#   subaddress        "8…" 95   — p2pool cannot pay a subaddress.
# Echoes: primary | integrated | subaddress | checksum | invalid  (#250, #829)
#
# Shape (prefix + length) alone is not enough: a well-shaped address with one mistyped character
# passes it, and p2pool then dies on the address at startup (SIGABRT/SIGSEGV) — a crash-looping
# stack that looks healthy from outside (#829). So after the shape gate, verify the address the
# way a wallet does: block-wise base58 decode, the network byte, and the 4-byte checksum — the
# first 4 bytes of the LEGACY Keccak-256 of the payload (Monero predates NIST SHA3; the padding
# differs, so sha3 tools give wrong digests and the hash is vendored below). "checksum" means
# exactly one thing: a character in the address is wrong.
#
# python3 does the math (bash has no 64-bit rotate worth writing): baked into the appliance
# rootfs, present on effectively every host that can run docker. Without it the shape verdict
# stands alone — the pre-#829 behaviour, degraded, not broken. Every config path routes through
# here (setup/apply, the appliance wizard spool, the dashboard control runner), so this is the
# one checksum gate for all of them.
monero_address_type() {
    local shape
    case "$1" in
    4*) case "${#1}" in 95) shape=primary ;; 106) shape=integrated ;; *) shape=invalid ;; esac ;;
    8*) case "${#1}" in 95) shape=subaddress ;; *) shape=invalid ;; esac ;;
    *) shape=invalid ;;
    esac
    if [ "$shape" == "invalid" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "$shape"
        return
    fi
    python3 - "$1" <<'PYEOF' 2>/dev/null || echo "$shape"
import sys

# Monero base58: 8-byte blocks encoded independently to 11 chars (a shorter last block maps by
# this table) — NOT Bitcoin's whole-string base58.
_ALPHA = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
_BLOCK = {11: 8, 10: 7, 9: 6, 7: 5, 6: 4, 5: 3, 3: 2, 2: 1}


def b58_decode(s):
    out = b""
    for i in range(0, len(s), 11):
        blk = s[i : i + 11]
        size = _BLOCK.get(len(blk))
        if size is None:
            return None
        n = 0
        for ch in blk:
            d = _ALPHA.find(ch)
            if d < 0:
                return None
            n = n * 58 + d
        try:
            out += n.to_bytes(size, "big")
        except OverflowError:
            return None
    return out


# Legacy Keccak-256 (pad byte 0x01), not NIST SHA3-256 (0x06) — hashlib.sha3_256 is WRONG here.
# Proven in the stack suite against well-known public addresses (XMRig's and the Monero
# project's donation addresses): a wrong digest fails their checksums.
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]
_M = (1 << 64) - 1


def _rol(v, r):
    return ((v << r) | (v >> (64 - r))) & _M if r else v


def _keccak_f(st):
    for rc in _RC:
        c = [st[x][0] ^ st[x][1] ^ st[x][2] ^ st[x][3] ^ st[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        st = [[st[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(st[x][y], _ROT[x][y])
        st = [
            [b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)]
            for x in range(5)
        ]
        st[0][0] ^= rc
    return st


def keccak256(data):
    rate = 136  # bytes absorbed per permutation at 256-bit output
    st = [[0] * 5 for _ in range(5)]
    pad = bytearray(data)
    pad.append(0x01)
    while len(pad) % rate:
        pad.append(0)
    pad[-1] |= 0x80
    for off in range(0, len(pad), rate):
        for i in range(rate // 8):
            st[i % 5][i // 5] ^= int.from_bytes(pad[off + 8 * i : off + 8 * i + 8], "little")
        st = _keccak_f(st)
    return b"".join(st[i % 5][i // 5].to_bytes(8, "little") for i in range(4))


raw = b58_decode(sys.argv[1])
if raw is None or len(raw) < 5:
    print("invalid")
    sys.exit(0)
body, want = raw[:-4], raw[-4:]
if keccak256(body)[:4] != want:
    print("checksum")
    sys.exit(0)
# Mainnet network bytes, each with its one valid payload length (tag + spend key + view key,
# integrated adds an 8-byte payment id). Any other tag is another network (testnet/stagenet).
kind = {18: ("primary", 65), 19: ("integrated", 73), 42: ("subaddress", 65)}.get(body[0])
if kind is None or len(body) != kind[1]:
    print("invalid")
    sys.exit(0)
print(kind[0])
PYEOF
}

# Tari payout-address verdict: ok | checksum | network | invalid | unchecked. Tari addresses come
# in base58 AND emoji forms, single or dual, with an optional embedded payment id (RFC-0155) —
# but every form carries a 1-byte DammSum checksum, so a mistyped character is detectable here
# instead of at the Tari node at merge-mine time, or never visibly at all (#845). The decode and
# the check order (length, checksum, network byte, feature bits) mirror tari's own from_bytes.
#
# python3 does the math, same as the Monero gate above. Without it the address is "unchecked" —
# accepted, the pre-gate behaviour, degraded, never a false reject.
tari_address_type() {
    command -v python3 >/dev/null 2>&1 || {
        echo "unchecked"
        return
    }
    python3 - "$1" <<'PYEOF' 2>/dev/null || echo "unchecked"
import os
import sys

# Bitcoin base58 (Tari uses the bs58 crate) — NOT Monero's block-wise scheme. In Tari's base58
# form the network byte and the features byte are each encoded ALONE (one character each), then
# the remaining bytes as one base58 string.
_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

# The 256-emoji alphabet from tari's emoji.rs, index = byte value. Every entry is a single
# codepoint, and tari's own parser matches codepoints exactly — so exact .find() is faithful.
_EMOJI = (
    "🐢📟🌈🌊🎯🐋🌙🤔🌕⭐🎋🌰🌴🌵🌲🌸🌹🌻🌽🍀🍁🍄🥑🍆🍇🍈🍉🍊🍋🍌🍍🍎"
    "🍐🍑🍒🍓🍔🍕🍗🍚🍞🍟🥝🍣🍦🍩🍪🍫🍬🍭🍯🥐🍳🥄🍵🍶🍷🍸🍾🍺🍼🎀🎁🎂"
    "🎃🤖🎈🎉🎒🎓🎠🎡🎢🎣🎤🎥🎧🎨🎩🎪🎬🎭🎮🎰🎱🎲🎳🎵🎷🎸🎹🎺🎻🎼🎽🎾"
    "🎿🏀🏁🏆🏈⚽🏠🏥🏦🏭🏰🐀🐉🐊🐌🐍🦁🐐🐑🐔🙈🐗🐘🐙🐚🐛🐜🐝🐞🦋🐣🐨"
    "🦀🐪🐬🐭🐮🐯🐰🦆🦂🐴🐵🐶🐷🐸🐺🐻🐼🐽🐾👀👅👑👒🧢💅👕👖👗👘👙💃👛"
    "👞👟👠🥊👢👣🤡👻👽👾🤠👃💄💈💉💊💋👂💍💎💐💔🔒🧩💡💣💤💦💨💩➕💯"
    "💰💳💵💺💻💼📈📜📌📎📖📿📡⏰📱📷🔋🔌🚰🔑🔔🔥🔦🔧🔨🔩🔪🔫🔬🔭🔮🔱"
    "🗽😂😇😈🤑😍😎😱😷🤢👍👶🚀🚁🚂🚚🚑🚒🚓🛵🚗🚜🚢🚦🚧🚨🚪🚫🚲🚽🚿🧲"
)


def b58_decode(s):
    n = 0
    for ch in s:
        d = _B58.find(ch)
        if d < 0:
            return None
        n = n * 58 + d
    body = n.to_bytes((n.bit_length() + 7) // 8, "big") if n else b""
    return b"\x00" * (len(s) - len(s.lstrip("1"))) + body


def dammsum(data):
    # DammSum over base 256 with coefficients [4,3,1] (mask 27); a valid array sums to 0.
    r = 0
    for d in data:
        r ^= d
        overflow = r & 0x80
        r = (r << 1) & 0xFF
        if overflow:
            r ^= 27
    return r


try:
    # Re-decode argv as strict UTF-8: under a C locale the interpreter may have decoded the
    # emoji bytes with surrogateescape, which would silently miss the alphabet.
    s = os.fsencode(sys.argv[1]).decode("utf-8")
except UnicodeDecodeError:
    print("invalid")
    sys.exit(0)

if all(ord(c) < 128 for c in s):
    if len(s) < 45:  # tari's own minimum encoded length for the base58 form
        print("invalid")
        sys.exit(0)
    parts = [b58_decode(s[0]), b58_decode(s[1]), b58_decode(s[2:])]
    raw = None if any(p is None for p in parts) else b"".join(parts)
else:
    raw = bytearray()
    for c in s:
        i = _EMOJI.find(c)
        if i < 0:
            raw = None
            break
        raw.append(i)

# A single address is exactly 35 bytes; a dual one 67, plus up to 256 payment-id bytes.
if raw is None or not (len(raw) == 35 or 67 <= len(raw) <= 67 + 256):
    print("invalid")
elif dammsum(raw) != 0:
    print("checksum")
elif raw[0] != 0x00:
    # 0x00 is mainnet — the only network this stack mines. The other assigned network bytes
    # mean a real address for the wrong network, which deserves its own message; anything
    # else is no Tari address at all.
    print("network" if raw[0] in (0x01, 0x02, 0x10, 0x24, 0x26) else "invalid")
elif raw[1] & ~0b111:  # unknown feature bits (known: one-sided 1, interactive 2, payment-id 4)
    print("invalid")
else:
    print("ok")
PYEOF
}
