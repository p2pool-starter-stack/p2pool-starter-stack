# --- Setup Steps ---

# Read the os-release file into OS_ID / OS_VERSION / OS_PRETTY (subshell-sourced to avoid clobber).
# OS_RELEASE_FILE is overridable for testing; defaults to the standard location.
# shellcheck disable=SC1090  # os-release path is dynamic by design
detect_os() {
    local osr="${OS_RELEASE_FILE:-/etc/os-release}"
    OS_ID=""
    OS_VERSION=""
    OS_PRETTY="$OS_TYPE"
    if [ -r "$osr" ]; then
        OS_ID=$(
            . "$osr" 2>/dev/null
            printf '%s' "${ID:-}"
        )
        OS_VERSION=$(
            . "$osr" 2>/dev/null
            printf '%s' "${VERSION_ID:-}"
        )
        OS_PRETTY=$(
            . "$osr" 2>/dev/null
            printf '%s' "${PRETTY_NAME:-$OS_TYPE}"
        )
    fi
}

# True when the four runtime dependencies are all present.
deps_satisfied() {
    command -v jq >/dev/null 2>&1 &&
        command -v openssl >/dev/null 2>&1 &&
        command -v docker >/dev/null 2>&1 &&
        docker compose version >/dev/null 2>&1
}

check_prerequisites() {
    if [ "$SKIP_DEPS" == "1" ]; then
        warn "Skipping dependency checks (--skip-deps). Ensure docker, docker compose (v2), jq and openssl are installed."
        return 0
    fi

    log "Checking dependencies..."
    detect_os
    if [ "$OS_ID" != "ubuntu" ] || [ "$OS_VERSION" != "24.04" ]; then
        warn "Officially supported on Ubuntu Server 24.04 (detected: ${OS_PRETTY:-$OS_TYPE})."
        warn "The stack may still work; install dependencies manually if needed, or re-run with --skip-deps to bypass these checks."
    fi

    # Detect missing dependencies and the apt packages that provide them.
    local missing_cmds=() missing_pkgs=()
    command -v jq >/dev/null 2>&1 || {
        missing_cmds+=("jq")
        missing_pkgs+=("jq")
    }
    command -v openssl >/dev/null 2>&1 || {
        missing_cmds+=("openssl")
        missing_pkgs+=("openssl")
    }
    if ! command -v docker >/dev/null 2>&1; then
        missing_cmds+=("docker")
        missing_pkgs+=("docker.io" "docker-compose-v2")
    elif ! docker compose version >/dev/null 2>&1; then
        missing_cmds+=("docker compose (v2 plugin)")
        missing_pkgs+=("docker-compose-v2")
    fi

    if [ "${#missing_cmds[@]}" -gt 0 ]; then
        warn "Missing dependencies: ${missing_cmds[*]}"
        local apt_cmd="sudo apt-get install -y ${missing_pkgs[*]}"
        if [ "$OS_ID" == "ubuntu" ] && command -v apt-get >/dev/null 2>&1; then
            read -r -p "Install them now with apt? (Y/n): " ANS || true
            if [[ "$ANS" =~ ^[Nn] ]]; then
                error "Dependencies not installed. Install them and re-run setup:\n  $apt_cmd"
            fi
            log "Installing missing packages..."
            sudo apt-get update
            sudo apt-get install -y "${missing_pkgs[@]}"
            deps_satisfied || error "Dependencies still missing after install. Please install manually:\n  $apt_cmd"
        else
            error "Cannot auto-install on this OS. Please install: ${missing_cmds[*]}\n  On Ubuntu:  $apt_cmd\n  Or re-run with --skip-deps if your setup already provides these another way."
        fi
    fi

    # Docker present but daemon not reachable is a separate (non-package) problem.
    docker info >/dev/null 2>&1 || error "Docker daemon is not reachable. Start it (e.g. 'sudo systemctl start docker') and ensure your user can use Docker (add yourself to the 'docker' group, then re-log in)."

    # Verify AVX2 instruction set support (performance only)
    cpu_has_avx2 || warn "AVX2 not detected. Mining performance will be poor."
    log "All dependencies satisfied."
}

# Placeholder credentials shipped in config.minimal.json / config.reference.json. We
# treat them like empty values so a user who copies the template but never edits the node creds
# still gets real, auto-generated ones (rather than working-but-predictable defaults).
readonly PLACEHOLDER_NODE_USER="create_a_username_for_node"
readonly PLACEHOLDER_NODE_PASS="create_a_password_for_node"

# --- Local node RPC credential generation ---
# These creds are internal to the stack (only monerod, p2pool and the dashboard use them), so we
# generate them rather than asking the user to invent some. Security rests on the random password;
# the username is just a label.

# Default username for the local node's RPC.
default_node_username() { printf '%s' "admin"; }

# A random alphanumeric password. Alphanumeric only: special characters (':', '#', ...) break the
# rpc-login=user:pass form rendered into bitmonero.conf, so we strip everything but [A-Za-z0-9].
# 32 chars from openssl is ~190 bits of entropy. No `head` in the pipe (it would SIGPIPE openssl
# under `set -o pipefail`); we over-generate and truncate in the shell instead.
generate_node_password() {
    local raw
    raw=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    printf '%s' "${raw:0:32}"
}

# --- Tor v3 onion client authorization (#343) ---
# Base32-encode a hex string (RFC 4648, no padding, uppercase) — the encoding Tor wants for its
# x25519 client-auth keys. Implemented in awk so it needs no `base32` binary (absent on macOS),
# which keeps it portable and unit-testable everywhere. Input: an even-length hex string.
b32encode_hex() {
    awk -v hex="$1" 'BEGIN {
        alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        bits = ""
        n = length(hex)
        for (i = 1; i <= n; i++) {
            v = index("0123456789abcdef", tolower(substr(hex, i, 1))) - 1
            if (v < 0) { exit 1 }
            for (j = 3; j >= 0; j--) bits = bits ((int(v / (2 ^ j)) % 2))
        }
        out = ""
        for (i = 1; i + 4 <= length(bits); i += 5) {
            val = 0
            for (j = 0; j < 5; j++) val = val * 2 + substr(bits, i + j, 1)
            out = out substr(alpha, val + 1, 1)
        }
        rem = length(bits) % 5
        if (rem > 0) {
            chunk = substr(bits, length(bits) - rem + 1, rem)
            for (k = rem; k < 5; k++) chunk = chunk "0"
            val = 0
            for (j = 1; j <= 5; j++) val = val * 2 + substr(chunk, j, 1)
            out = out substr(alpha, val + 1, 1)
        }
        print out
    }'
}

# Generate an x25519 keypair for Tor v3 onion client auth. Echoes "PUBKEY PRIVKEY", both base32
# (unpadded, uppercase) — the form tor's authorized_clients/ and ClientOnionAuthDir want. The raw
# 32-byte keys are the trailing 32 bytes of the DER encoding (the documented extraction). Returns
# non-zero if openssl lacks x25519. Runs on the host at setup/apply/rotate.
generate_onion_client_keypair() {
    command -v openssl >/dev/null 2>&1 || return 1
    local tmp priv_hex pub_hex
    tmp=$(mktemp) || return 1
    if ! openssl genpkey -algorithm x25519 -out "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    priv_hex=$(openssl pkey -in "$tmp" -outform DER 2>/dev/null | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
    pub_hex=$(openssl pkey -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
    rm -f "$tmp"
    [ "${#priv_hex}" -eq 64 ] && [ "${#pub_hex}" -eq 64 ] || return 1
    printf '%s %s' "$(b32encode_hex "$pub_hex")" "$(b32encode_hex "$priv_hex")"
}

# A stored local-node credential needs (re)generating when it is empty or still the shipped
# template placeholder (an instruction string, not a real secret). Used in `if` conditions.
cred_needs_generating() {
    local value="$1" placeholder="$2"
    [ -z "$value" ] || [ "$value" == "$placeholder" ]
}

# Persist the (possibly just-generated) local node RPC credentials back into config.json so they
# stay stable across re-runs / `apply` and the user can see what was set for them. Atomic (write a
# sibling temp file, then mv) and keeps config.json owner-only. Best-effort: a save failure warns
# rather than aborting, since the in-memory creds still make this run work.
persist_node_credentials() {
    local user="$1" pass="$2" tmp="${CONFIG_FILE}.tmp"
    # A dry run must only read (#556) — the caller already generated the creds in memory for the
    # render/diff; skip the write-back to config.json (or a staged control-channel copy).
    [ "$PITHEAD_DRY_RUN" -eq 1 ] && return 0
    # Subshell umask (#368): the temp file carries the credentials, so it too must be owner-only
    # from creation — mv preserves its mode onto config.json.
    if (
        umask 077
        jq --arg u "$user" --arg p "$pass" \
            '.monero.node_username = $u | .monero.node_password = $p' \
            "$CONFIG_FILE" >"$tmp" 2>/dev/null
    ); then
        mv "$tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
    else
        rm -f "$tmp"
        warn "Could not write generated node credentials back to $CONFIG_FILE (they'll work for this run but may change on the next one)."
    fi
}

# First-run wizard (#502/#529). Split ask/write/pointer into their own functions so the tier-1
# suite can drive the Q&A directly (piped stdin) without ensure_config_exists's tty gate below —
# that gate exists to refuse a non-interactive run, not to block testing the prompts themselves.
# Scope is deliberately narrow: the CORE_KEYS_CONFIG shortlist (wallet addresses, monero.mode,
# p2pool.pool, dashboard auth) plus a few high-level "how should this run" shape questions.
# Everything else keeps its config.reference.json default, silently — see wizard_print_pointer.
# workers.list (also in the shortlist, #529) isn't asked inline: it's a variable-length list of
# per-rig objects, not a single answer, and the standard fleet needs no entries at all (see
# docs/workers.md) — so it's covered by the closing pointer instead of a prompt, matching the
# treatment #502 already prescribes for monero.view_key / dashboard.energy.cost_per_kwh.
# dashboard.host is asked separately, by resolve_dashboard_host "interactive" (setup(), after this
# function returns) — not duplicated here.
ensure_config_exists() {
    [ -f "$CONFIG_FILE" ] && return 0

    if [ ! -t 0 ]; then
        error "$CONFIG_FILE not found and no interactive terminal is available.\n  Create it first (copy config.minimal.json to config.json and edit it), then re-run."
    fi

    log "$CONFIG_FILE not found. Starting interactive setup..."
    # Fail fast if the core-key shortlist didn't ship with this checkout/bundle — the wizard's
    # scope is defined by it (#502/#529), so a missing/corrupt file means the wizard itself is
    # incomplete, not something to silently ignore.
    jq -e . "$CORE_KEYS_CONFIG" >/dev/null 2>&1 ||
        error "$CORE_KEYS_CONFIG is missing or not valid JSON (the wizard's core-key shortlist). Reinstall or redownload the release bundle."
    echo "Please provide the following details to generate a minimal configuration:"

    wizard_ask_core
    wizard_ask_shape
    wizard_write_config
    chmod 600 "$CONFIG_FILE"
    log "$CONFIG_FILE created successfully."
    wizard_print_pointer
}

# Stage 1 (required — only the operator can answer these): wallet addresses, local/remote node
# (+ remote details), pool tier, and an optional dashboard login. Sets globals consumed by
# wizard_write_config: IN_MONERO_WALLET, IN_TARI_WALLET, MONERO_MODE_WIZ, REMOTE_HOST, REMOTE_RPC,
# REMOTE_ZMQ, IN_MONERO_USER, IN_MONERO_PASS, POOL_TIER, IN_DASH_USER, IN_DASH_PASS.
wizard_ask_core() {
    while :; do
        read -r -p "Enter Monero Wallet Address (primary — starts with 4): " IN_MONERO_WALLET || break
        case "$(monero_address_type "$IN_MONERO_WALLET")" in
        primary) break ;;
        subaddress) echo "  ✗ That's a subaddress (8…) — p2pool can't pay it. Use your PRIMARY address (starts with 4)." >&2 ;;
        integrated) echo "  ✗ That's an integrated address — use your plain primary address." >&2 ;;
        checksum) echo "  ✗ Checksum failed — at least one character is mistyped. Re-copy the address from your wallet." >&2 ;;
        *) echo "  ✗ Not a valid Monero primary address (95 chars, starts with 4). Try again." >&2 ;;
        esac
    done
    while :; do
        read -r -p "Enter Tari Wallet Address (base58 or emoji form): " IN_TARI_WALLET || break
        [ -z "$IN_TARI_WALLET" ] && break # the shared required-fields check below owns this
        case "$(tari_address_type "$IN_TARI_WALLET")" in
        ok | unchecked) break ;;
        checksum) echo "  ✗ Checksum failed — at least one character is mistyped. Re-copy the address from your Tari wallet." >&2 ;;
        network) echo "  ✗ That address is for a Tari testnet — this stack mines MAINNET Tari. Use your mainnet address." >&2 ;;
        *) echo "  ✗ Not a valid Tari address (base58 or emoji form). Try again." >&2 ;;
        esac
    done

    if [ -z "$IN_MONERO_WALLET" ] || [ -z "$IN_TARI_WALLET" ]; then
        error "Wallet addresses are required. Aborting."
    fi

    echo ""
    echo "--- Node Configuration ---"
    read -r -p "Use LOCAL Monero node? (Y/n): " USE_LOCAL || true

    IN_MONERO_USER="" IN_MONERO_PASS=""
    if [[ ! "$USE_LOCAL" =~ ^[Nn] ]]; then
        MONERO_MODE_WIZ="local"
        echo "Local node selected."
        # The local node's RPC credentials are internal to the stack, so we generate them rather
        # than asking you to invent some. They're stored in config.json / .env if you ever need
        # them (e.g. to attach a wallet). The same helpers back the auto-fill in
        # parse_and_validate_config, so every path produces the same kind of creds.
        IN_MONERO_USER=$(default_node_username)
        IN_MONERO_PASS=$(generate_node_password)
        log "Generated internal Monero node RPC credentials (saved in $CONFIG_FILE)."
    else
        MONERO_MODE_WIZ="remote"
        echo "Remote node selected."
        read -r -p "Enter Remote Node Host (IP or Domain): " REMOTE_HOST || true
        read -r -p "Enter Remote RPC Port [18081]: " REMOTE_RPC || true
        read -r -p "Enter Remote ZMQ Port [18083]: " REMOTE_ZMQ || true
        REMOTE_RPC=${REMOTE_RPC:-18081}
        REMOTE_ZMQ=${REMOTE_ZMQ:-18083}

        read -r -p "Does the remote node require authentication? (y/N): " REMOTE_AUTH || true
        if [[ "$REMOTE_AUTH" =~ ^[Yy] ]]; then
            read -r -p "Enter Remote Node Username: " IN_MONERO_USER || true
            read -r -s -p "Enter Remote Node Password: " IN_MONERO_PASS || true
            echo ""
        fi
    fi

    # Pool tier (#502's highest-value gap): p2pool's three sidechains are sized by hashrate, so
    # picking the wrong one is silently suboptimal (a small miner on "main" waits days between
    # shares). The old wizard hardcoded "main" and never asked; now it asks, and "mini" is the
    # global default — the reference, the code fallback (`.p2pool.pool // "mini"`), and this
    # Enter-through all agree — because a typical home rig is the common case for this stack.
    echo ""
    echo "--- Pool Tier ---"
    echo "p2pool has three sidechains sized by hashrate, so miners find shares at a similar cadence:"
    echo "  main — high hashrate (large farms); mini — typical home rig; nano — a single low-power rig"
    read -r -p "Pool tier [mini]: " IN_POOL_TIER || true
    case "$(printf '%s' "$IN_POOL_TIER" | tr 'A-Z' 'a-z')" in
    main) POOL_TIER="main" ;;
    nano) POOL_TIER="nano" ;;
    "" | mini) POOL_TIER="mini" ;;
    *)
        echo "  Not main/mini/nano — defaulting to mini (the default for a typical rig)." >&2
        POOL_TIER="mini"
        ;;
    esac

    # Dashboard login (core shortlist, #529) — optional, Enter-through: no login is the safe
    # default on a private LAN, so blank means "skip", not "generate one for me."
    echo ""
    echo "--- Dashboard Login (optional) ---"
    echo "No login by default (fine on a private LAN). Set one if you'd like — Enter to skip."
    read -r -p "Dashboard username [admin]: " IN_DASH_USER || true
    IN_DASH_USER="${IN_DASH_USER:-admin}"
    while :; do
        read -r -s -p "Dashboard password (8+ chars, Enter to skip): " IN_DASH_PASS || break
        echo ""
        [ -z "$IN_DASH_PASS" ] && break
        [ "${#IN_DASH_PASS}" -ge 8 ] && break
        echo "  ✗ Must be at least 8 characters (or blank to skip). Try again." >&2
    done
}

# Stage 2 (#502): a FEW overarching "how should this run" questions, each Enter-through and each
# driving a whole cluster of keys — never one prompt per key. Sets globals consumed by
# wizard_write_config: CLEARNET_SYNC, ONION_ENABLED, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID.
wizard_ask_shape() {
    echo ""
    echo "--- A Few More (Enter for the default) ---"

    read -r -p "First sync: fully private over Tor (days), or faster over clearnet (hours)? (y/N = private): " IN_CLEARNET || true
    CLEARNET_SYNC=false
    [[ "$IN_CLEARNET" =~ ^[Yy] ]] && CLEARNET_SYNC=true

    read -r -p "Reach the dashboard from outside your LAN over Tor? (y/N): " IN_ONION || true
    ONION_ENABLED=false
    [[ "$IN_ONION" =~ ^[Yy] ]] && ONION_ENABLED=true

    # Alerts need an external secret (a bot token), so this is offered, not asked outright — a
    # trusting operator just hits Enter and sees the doc pointer at the end instead.
    TELEGRAM_BOT_TOKEN="" TELEGRAM_CHAT_ID=""
    read -r -p "Set up Telegram alerts (node down, block found, low hashrate) now? (y/N): " IN_TELEGRAM || true
    if [[ "$IN_TELEGRAM" =~ ^[Yy] ]]; then
        read -r -p "Telegram bot token: " TELEGRAM_BOT_TOKEN || true
        read -r -p "Telegram chat id: " TELEGRAM_CHAT_ID || true
    fi

    # Local miner opt-in (#593). A box that runs the stack 24/7 can mine with its spare CPU by
    # co-locating a RigForge worker pointed at the stack's own loopback stratum. Off by default —
    # this only records the intent; setup prints the two values a RigForge install needs (the pool
    # URL and stratum secret) at the end. Pithead never installs or tunes the miner: RigForge owns
    # all host tuning (HugePages/GRUB/MSR) and the miner service.
    read -r -p "Also mine on this machine with its spare CPU (co-locate a RigForge worker)? (y/N): " IN_LOCAL_MINER || true
    LOCAL_MINER=false
    [[ "$IN_LOCAL_MINER" =~ ^[Yy] ]] && LOCAL_MINER=true
}

# Assembles config.json from the globals wizard_ask_core/wizard_ask_shape set, and writes it.
wizard_write_config() {
    local cfg
    cfg=$(jq -n \
        --arg mode "$MONERO_MODE_WIZ" \
        --arg mwallet "$IN_MONERO_WALLET" \
        --arg mu "$IN_MONERO_USER" \
        --arg mp "$IN_MONERO_PASS" \
        --arg twallet "$IN_TARI_WALLET" \
        --arg pool "$POOL_TIER" \
        '{monero: {mode: $mode, wallet_address: $mwallet, node_username: $mu, node_password: $mp},
          tari: {wallet_address: $twallet},
          p2pool: {pool: $pool, stratum_password: "auto"},
          dashboard: {secure: true}}')

    if [ "$MONERO_MODE_WIZ" == "remote" ]; then
        cfg=$(jq --arg h "$REMOTE_HOST" --argjson rpc "${REMOTE_RPC:-18081}" --argjson zmq "${REMOTE_ZMQ:-18083}" \
            '.monero.remote = {host: $h, rpc_port: $rpc, zmq_port: $zmq}' <<<"$cfg")
    fi

    if [ -n "$IN_DASH_PASS" ]; then
        cfg=$(jq --arg u "$IN_DASH_USER" --arg p "$IN_DASH_PASS" '.dashboard.auth = {username: $u, password: $p}' <<<"$cfg")
    fi

    if [ "$CLEARNET_SYNC" = true ]; then
        cfg=$(jq '.monero.clearnet_initial_sync = true | .tari.clearnet_initial_sync = true' <<<"$cfg")
    fi

    if [ "$ONION_ENABLED" = true ]; then
        # Password (if still unset) and client-auth are handled downstream by
        # ensure_onion_password, which setup() runs right after ensure_config_exists.
        cfg=$(jq '.dashboard.onion = {enabled: true}' <<<"$cfg")
    fi

    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        cfg=$(jq --arg t "$TELEGRAM_BOT_TOKEN" --arg c "$TELEGRAM_CHAT_ID" '.telegram = {enabled: true, bot_token: $t, chat_id: $c}' <<<"$cfg")
    fi

    if [ "${LOCAL_MINER:-false}" = true ]; then
        cfg=$(jq '.local_miner = {enabled: true}' <<<"$cfg")
    fi

    # Subshell umask (#368): the file must be owner-only from its FIRST byte — a chmod after the
    # write leaves a world-readable window under the default umask.
    (
        umask 077
        printf '%s\n' "$cfg" >"$CONFIG_FILE"
    )
}

# Closing pointer (#502): names what the wizard deliberately didn't ask, so an operator who wants
# it knows where to look instead of hunting config.reference.json cold.
wizard_print_pointer() {
    echo ""
    echo "That's the core config — everything else (ports, XvB, alerts, energy pricing, per-worker"
    echo "overrides, ...) keeps its default. Want on-chain payout confirmation, a per-kWh cost, or"
    echo "per-worker overrides? Set monero.view_key / dashboard.energy.cost_per_kwh / workers.list in"
    echo "$CONFIG_FILE and run '$0 apply' — see $DOCS_URL/docs/configuration.md, or use the dashboard's config editor."
}

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

# When the dashboard onion is enabled but no password is set, generate a strong one and save it to
# config.json (#343). Keeps the fail-closed onion usable without forcing the operator to invent a
# 16+ char secret; the plaintext lives in owner-only config.json, exactly like a hand-set password
# (login stays "admin"). Runs only on the config-writing paths (setup/apply), before parse validates
# — never on read-only commands, which must not mutate config.json.
ensure_onion_password() {
    [ -f "$CONFIG_FILE" ] || return 0
    [ "$(config_bool '.dashboard.onion.enabled' false)" == "true" ] || return 0
    [ -z "$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE")" ] || return 0
    local gen tmp
    gen=$(generate_node_password) # 32 alnum chars: clears the >=16 floor, no quotes, no weak pattern
    tmp=$(mktemp) || error "Could not create a temp file to save the generated dashboard password."
    jq --arg p "$gen" '.dashboard.auth.password = $p' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE" ||
        error "Could not save the generated dashboard password to $CONFIG_FILE."
    log "Dashboard onion is on but no password was set — generated one and saved it to config.json (login: admin; see dashboard.auth.password)."
}

# Put words in front of a human standing at the machine. /dev/console is only ONE of the
# consoles — whichever the cmdline named last — so a message sent there alone is invisible to an
# operator watching the other. Between power-on and the setup page there is a minute or more of
# image loading, and silence there reads as a broken machine.
_console() { # $1... lines
    local dev line
    # Every line reaches the journal too — a message that lives only on a physical console
    # cost a bench session an hour once (see firstboot's teed setup log for the same lesson).
    for line in "$@"; do
        # if, not '&&': an empty spacer line under set -e must not become the exit status.
        if [ -n "$line" ]; then log "$line"; fi
    done
    for dev in /dev/tty1 /dev/ttyS0; do
        [ -w "$dev" ] || continue
        printf '  %s\n' "$@" >"$dev" 2>/dev/null || true
    done
}

# A self-signed certificate for the setup page, valid for every address the operator might use.
# Echoes the SHA-256 fingerprint so the console can print it beside the token: a browser warning
# nobody can check is theatre, and this page now carries node passwords and bot tokens.
# Regenerated each run — addresses change with the DHCP lease, and the key is disposable.
# The machine's ONE certificate, minted once and kept on /data. The wizard serves it, and Caddy
# serves the same file afterwards — because a second, different self-signed cert for the same
# name is not a second warning, it is a hard refusal in Safari and a scary one everywhere else.
# A bench session hit exactly that: the setup page "died" at the moment provisioning succeeded.
appliance_tls_dir() { printf '%s' "${PITHEAD_TLS_DIR:-$PWD/data/tls}"; }

# The ONE list of names this appliance answers to — the shared builder behind BOTH Caddy's
# site_hosts (generate_caddyfile) and the certificate's SAN list (appliance_mint_cert), so a name
# is either served and certified or neither (#1132). Prints bare host/IP tokens, space-separated;
# each caller formats them for its own consumer (a literal Host for Caddy, a DNS:/IP: SAN entry
# for the certificate).
#
# The base name both appliance_site_names() and check_appliance_cert() start from: $HOST_IP —
# resolve_dashboard_host's own answer, which already carries its "dashboard.host wins, else this
# machine's name" rule — so an operator who pins dashboard.host gets that exact name from both
# consumers, never a certificate for the machine's OTHER names (the #1132 mismatch). Called before
# resolve_dashboard_host has run (the wizard's very first mint, before CONFIG_FILE exists) $HOST_IP
# is empty; fall back to its own "auto" default rather than duplicating that function's
# prompt/env logic here. Pulled out on its own because check_appliance_cert needs to tell this name
# apart from the auto-expanded ones below it — see that function's header for why.
appliance_base_name() {
    if [ -n "${HOST_IP:-}" ]; then
        printf '%s' "$HOST_IP"
    elif is_appliance; then
        printf '%s.local' "$(hostname)"
    else
        hostname
    fi
}

# "auto" (dashboard.host unset) expands to every address the appliance actually answers on — a
# headless box reached by mDNS name, by IP, or from the console must have all three certified. An
# explicit pin stays a single name on purpose: the site list collapsing was never the #1132 bug,
# only the certificate not following suit was.
#
# Deliberately engine-free: this runs from BOTH generate_caddyfile (render, always BEFORE `up`
# creates either compose bridge this boot) and, via check_appliance_cert, from doctor (always
# AFTER `up`, inside pithead-boot's health-gate retry loop). A call here that talked to
# docker/podman would make this function's answer depend on whether the engine happened to be
# reachable at the exact moment it ran — and #1065 reboots the box on a doctor FAIL, so an engine
# hiccup must never change what this reports. mining_net's gateway is excludable without asking
# anything live (${NETWORK_PREFIX}.1, fixed by config) so it stays here; proxy_net's is NOT
# (docker-compose.yml: "Docker auto-assigns the subnet", #345) and asking the engine for it is
# check_appliance_cert's job alone — the ONE caller for whom a stale or unreachable answer would
# otherwise manufacture a FAIL, and so the only one equipped to turn "can't tell" into a WARN
# instead of a guess. See that function's header for the full reasoning.
appliance_site_names() {
    local base
    base=$(appliance_base_name)
    local names="$base"
    if is_appliance && [ -z "${DASHBOARD_HOST:-}" ]; then
        local extra
        for extra in $(hostname -I 2>/dev/null) localhost; do
            case " $names " in *" $extra "*) continue ;; esac
            # `hostname -I` lists EVERY address on every interface, so on any network whose router
            # passes IPv6 through, a SLAAC/DHCPv6 global unicast address lands here exactly like a
            # LAN one — and this list is rebuilt every render. That published the control panel on
            # a globally-routable address, with nothing but the operator's router between it and
            # the internet; the product must not depend on that. The documented way to reach the
            # dashboard off-LAN is the onion service, never a routable address, so nothing
            # supported regresses. Opt back in with dashboard.expose_public_ip if a deployment
            # really does want it.
            if [ "${DASHBOARD_EXPOSE_PUBLIC_IP:-false}" != "true" ] && is_public_ip "$extra"; then
                continue
            fi
            # mining_net's gateway belongs to the ONION vhost, which serves on exactly that
            # address, and never to the LAN list — two site blocks naming the same scheme://address
            # make Caddy refuse the whole file with "ambiguous site definition" (see
            # generate_caddyfile). Excluding it here keeps the certificate honest too: it was never
            # reachable at the bridge gateway by anything except the tor container. proxy_net's
            # gateway is the SAME kind of plumbing address but has no fixed literal to exclude it
            # by — see this function's header for why that exclusion lives in check_appliance_cert
            # instead of here.
            if [ -n "${NETWORK_PREFIX:-}" ] && [ "$extra" = "${NETWORK_PREFIX}.1" ]; then
                continue
            fi
            names="$names $extra"
        done
    fi
    printf '%s' "$names"
}

# appliance_site_names(), formatted as a certificate SAN string ("DNS:a,DNS:b,IP:c,..."). Same
# character-class rule the bind_addrs loop below uses: a colon is an IPv6 literal, any other
# non-digit/non-dot character makes it a name, otherwise it's a dotted-quad IPv4 literal. Always
# succeeds (appliance_site_names never fails) — safe to use in a bare assignment under `set -e`.
appliance_cert_alt_string() {
    local h out=""
    for h in $(appliance_site_names); do
        case "$h" in
        *:*) out="${out:+$out,}IP:$h" ;;
        *[!0-9.]*) out="${out:+$out,}DNS:$h" ;;
        *) out="${out:+$out,}IP:$h" ;;
        esac
    done
    printf '%s' "$out"
}

# The SAN list a certificate FILE actually carries, in the same "DNS:a,IP:b" form
# appliance_cert_alt_string builds — so appliance_mint_cert and doctor can compare what a
# certificate covers against what it should, instead of guessing from a mint date (#1132). Empty
# on any read failure (missing file, corrupt cert, no SAN extension at all) — callers treat that
# as "does not match". Deliberately always exits 0 (`|| true`): a corrupt certificate is data for
# the caller to act on, not a reason for `pithead` itself to abort under `set -e`.
cert_san_string() { # <cert-file>
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null |
        tr -d '[:space:]' | sed -e 's/^X509v3SubjectAlternativeName://' -e 's/IPAddress:/IP:/g' || true
}

# The console login mirrors the dashboard login (operator decision 2026-07-31): one secret per
# machine. Anyone at the physical console with the dashboard password may log in as root —
# consistent with the LAN/physical trust model (the console already shows the setup token, and
# SSH stays key-only regardless: PasswordAuthentication never turns on). Re-asserted on every
# render, so a changed dashboard password propagates and an empty one locks the console again.
provision_console_login() {
    is_appliance || return 0
    command -v chpasswd >/dev/null 2>&1 || return 0
    # /etc/shadow sits on the read-only root, so the password lives in a /run-backed overlay on
    # /etc — DERIVED (#790) in the strictest sense: rewritten from config.json on every boot,
    # persisted nowhere, gone the moment the machine powers off. (A bind-mounted shadow FILE
    # does not survive chpasswd, which replaces the file by rename.)
    if ! findmnt -no FSTYPE /etc 2>/dev/null | grep -q overlay; then
        sudo mkdir -p /run/pithead-etc/upper /run/pithead-etc/work
        sudo mount -t overlay overlay \
            -o lowerdir=/etc,upperdir=/run/pithead-etc/upper,workdir=/run/pithead-etc/work /etc ||
            {
                warn "Could not prepare the console login (no /etc overlay)."
                return 0
            }
    fi
    local pass
    pass=$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$pass" ]; then
        sudo passwd -l root >/dev/null 2>&1 || true
        return 0
    fi
    printf 'root:%s\n' "$pass" | sudo chpasswd 2>/dev/null &&
        log "Console login set: root, with the dashboard password." ||
        warn "Could not set the console login."
}

# SSH per config (ssh.enabled + ssh.authorized_key) — the appliance's opt-in debug and
# recovery path (#786). Key-only, never passwords. Everything it writes is DERIVED (#790) and
# lives on tmpfs: the key under /run/pithead-ssh, sshd's override under /run/systemd/system —
# rebuilt every boot by render, gone on the first boot after the flag turns off, and no key
# material ever rests on disk outside config.json itself. Appliance-only: a DIY host owns its
# own sshd. Deliberately in the HOST-ONLY config class (never dashboard-editable): a dashboard
# session that could enable SSH and choose the key would own the machine.
provision_ssh_access() {
    is_appliance || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit_d="${PITHEAD_UNIT_DIR:-/run/systemd/system}/ssh.service.d"
    local key_d="${PITHEAD_SSH_RUN_DIR:-/run/pithead-ssh}" en key
    en=$(jq -r '.ssh.enabled // false' "$CONFIG_FILE" 2>/dev/null)
    key=$(jq -r '.ssh.authorized_key // ""' "$CONFIG_FILE" 2>/dev/null)
    if [ "$en" != "true" ] || [ -z "$key" ]; then
        if [ -e "$unit_d/pithead.conf" ] || [ -d "$key_d" ]; then
            log "SSH is OFF (ssh.enabled) — removing the runtime access."
            rm -rf "$unit_d" "$key_d"
            sudo systemctl daemon-reload
            sudo systemctl stop ssh >/dev/null 2>&1 || true
        fi
        return 0
    fi
    mkdir -p "$unit_d" "$key_d"
    chmod 755 "$key_d" # sshd's StrictModes walks the path — group/world-writable would refuse
    printf '%s\n' "$key" >"$key_d/authorized_keys"
    chmod 644 "$key_d/authorized_keys"
    cat >"$unit_d/pithead.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/sshd -D -o AuthorizedKeysFile=$key_d/authorized_keys -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password
EOF
    sudo systemctl daemon-reload
    sudo systemctl start ssh >/dev/null 2>&1 ||
        warn "Could not start sshd — ssh.enabled is set but SSH is not running."
    log "SSH is ON (key-only): root@$(hostname).local"
}

# Mint (or keep) the machine's ONE certificate in appliance_tls_dir. Idempotent: an existing
# certificate that still covers the machine's names is reused, because the operator has already
# trusted it and replacing it is indistinguishable from an attack. Re-mints ONLY when the name
# list it was minted for no longer matches (#1132) — compared, not date-guessed: the minted SAN
# list is derived from the certificate itself with openssl (cert_san_string) and set-compared
# against appliance_site_names' current answer, sorted on both sides so a re-ordered (but
# unchanged) `hostname -I` never trips a needless re-mint. An operator who has pinned this
# fingerprint loses that trust on every unnecessary replacement, so the comparison stays as
# conservative as it can — and a real re-mint says so on the console, since the operator's browser
# will need to trust the new certificate.
appliance_mint_cert() { # -> prints the SHA-256 fingerprint
    local d alt need_mint=1 names primary
    d=$(appliance_tls_dir)
    mkdir -p "$d"
    alt=$(appliance_cert_alt_string)
    if [ -s "$d/wizard.crt" ] && [ -s "$d/wizard.key" ] &&
        [ "$(cert_san_string "$d/wizard.crt" | tr ',' '\n' | sort | tr '\n' ',')" = \
            "$(printf '%s' "$alt" | tr ',' '\n' | sort | tr '\n' ',')" ]; then
        need_mint=0
    fi
    if [ "$need_mint" = 1 ]; then
        [ -s "$d/wizard.crt" ] &&
            log "Re-minting the dashboard certificate — the machine now answers to a different set of names than the one it was minted for. Your browser will need to trust the new certificate."
        names=$(appliance_site_names)
        primary="${names%% *}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$d/wizard.key" -out "$d/wizard.crt" \
            -subj "/CN=$primary" -addext "subjectAltName=$alt" \
            -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1 || return 1
    fi
    openssl x509 -in "$d/wizard.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

wizard_mint_cert() { # <spool-dir>  -> prints the fingerprint
    local d spool="$1" fp
    d=$(appliance_tls_dir)
    fp=$(appliance_mint_cert) || return 1
    # The container reads its copy from the spool; the canonical pair stays on /data.
    cp "$d/wizard.crt" "$spool/wizard.crt" 2>/dev/null || return 1
    cp "$d/wizard.key" "$spool/wizard.key" 2>/dev/null || return 1
    chown 1000:1000 "$spool/wizard.key" "$spool/wizard.crt" 2>/dev/null || true
    chmod 640 "$spool/wizard.key" 2>/dev/null || true
    printf '%s' "$fp"
}

# An appliance gets a dashboard login whether or not the onion is on.
#
# ensure_onion_password only fires for the onion, so a LAN appliance shipped an UNAUTHENTICATED
# dashboard — and the setup page told the operator a login had been generated. On DIY that is a
# defensible default: the operator ran the CLI wizard, was asked, and pressed Enter to skip. A
# headless appliance was never asked, so the safe answer is the one it gets. The credential is
# generated on the machine and printed to its console; it never crosses the setup page.
ensure_appliance_dashboard_password() { # [spool-dir]
    [ -f "$CONFIG_FILE" ] || return 0
    [ -z "$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE")" ] || return 0
    # The operator's explicit "no login" is honoured — an empty password is also what "not
    # chosen" looks like, so the choice cannot live in the config and rides beside it.
    if [ -n "${1:-}" ] && [ "$(cat "$1/auth-mode" 2>/dev/null)" = "none" ]; then
        warn "Dashboard login disabled at the operator's request — anyone on this network can open it."
        return 0
    fi
    local gen tmp user
    gen=$(generate_node_password) # 32 alnum: clears the >=16 floor, no quotes, no weak pattern
    user=$(jq -r '.dashboard.auth.username // "admin"' "$CONFIG_FILE")
    tmp=$(mktemp) || return 1
    if jq --arg p "$gen" '.dashboard.auth.password = $p' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"; then
        _console "" "Dashboard login for this machine:" "    user: $user" "    password: $gen" \
            "Write this down — it is also in config.json on the machine."
        return 0
    fi
    rm -f "$tmp"
    warn "Could not save a generated dashboard password; the dashboard will have no login."
    return 1
}

# Defaults an APPLIANCE should carry that a DIY host should not. Applied only where a key is
# ABSENT — an operator who wrote "false" meant it.
#
# tor.auto_heal: opt-in on DIY because restarting Tor drops every circuit, and the stack should
# not reshape an operator's privacy boundary behind their back. On an appliance there is no back
# to go behind: it is headless and unattended, and the failure it heals is SILENT — mining keeps
# working while Healthchecks, Telegram and XvB all go dark at once. Production once sat that way
# for six hours. The heal is probe-driven, rate-limited and bounded, so the risk it guards
# against does not apply the way it does interactively.
apply_appliance_defaults() {
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp
    tmp=$(mktemp) || return 1
    # dashboard.control.enabled: on DIY the operator has a shell, so the config editor is a
    # convenience and stays off. An appliance has NO other way in — no shell, ssh disabled — so
    # without this the machine is unconfigurable after first boot and the only route to a changed
    # payout address is a reflash. Production runs with it on. It sits behind the generated
    # login, which is why the password above is not optional.
    # ...but only behind a password. `strip_defaults` drops any wizard answer equal to the
    # reference default, and the reference has control.enabled false, so the key is absent from
    # EVERY submission — including "No login", which leaves the password empty. Injecting
    # unconditionally therefore built the exact pair parse_and_validate_config refuses, and the
    # machine dead-ended on first boot after the operator had been told provisioning started
    # (#1066). An unauthenticated config editor is what that rule exists to prevent, so the
    # honest resolution is to leave the channel off rather than to weaken the rule.
    if jq '
        if .tor.auto_heal == null then (.tor //= {}) | .tor.auto_heal = true else . end
        | if .dashboard.control.enabled == null and ((.dashboard.auth.password // "") != "")
          then (.dashboard //= {}) | (.dashboard.control //= {}) | .dashboard.control.enabled = true
          else . end' \
        "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# The one selection rule for every reader of the per-worker descriptors (#506): workers.list[]
# wins whenever it is set to anything but an empty array; an empty or absent workers.list falls
# back to the deprecated dashboard.workers[] (#172). An empty array is a schema default, not an
# operator choice — the dashboard config editor merges config.reference.json UNDER the operator's
# config, so a staged editor config always carries BOTH keys with at least one of them empty
# (#679); keying any decision on mere presence picks (or refuses) the wrong shape. A set-but-not-
# an-array workers.list still wins, so validation flags it under its own name.
readonly WORKER_LIST_JQ='def worker_list:
    ((.workers // {}) | .list // []) as $n
    | if ($n | type) == "array" and ($n | length) == 0
      then ((.dashboard // {}) | .workers // []) else $n end;'

# Validate the per-worker endpoint descriptors (#506): a list of {name, host?, port?, token?}
# objects the dashboard uses to override the fleet worker-API defaults per rig. workers.list[] is
# the current sub-key; dashboard.workers[] (#172) is read as a deprecated fallback (removed in
# v1.9, one-time warning below) — POPULATING both is refused outright, since silently picking one
# would leave the other a stale, unnoticed copy of hosts/tokens. Presence alone never refuses
# (#679, see WORKER_LIST_JQ above). Nothing here renders to .env — the
# dashboard reads the list straight off its read-only config.json bind mount (tokens stay in the
# one owner-only file that already holds secrets) — so this validation exists to fail an apply
# LOUDLY on a typo instead of the dashboard silently dropping the entry at runtime. The `host`
# charset matters for #122: it must never be able to smuggle a port, path, or userinfo into the
# dashboard's probe URL.
validate_worker_endpoints() {
    local new_n legacy_n dw_path dw_err dw_dups
    # Length, not presence (#679): 0 = absent or empty array (schema default — never an operator
    # signal), >0 = populated, -1 = set to something that isn't an array (validated below under
    # the right path label). A jq parse hiccup degrades to 0, same as the old has() going silent.
    new_n=$(jq -r '(.workers // {}) | (.list // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    legacy_n=$(jq -r '(.dashboard // {}) | (.workers // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "${new_n:-0}" != "0" ] && [ "${legacy_n:-0}" != "0" ]; then
        error "config.json sets both workers.list[] and dashboard.workers[] — pick one. dashboard.workers[] is a deprecated alias for workers.list[] (removed in v1.9); move its entries to workers.list[] and delete dashboard.workers."
    fi
    if [ "${legacy_n:-0}" != "0" ] && [ -z "${PITHEAD_WORKERS_LEGACY_WARNED:-}" ]; then
        warn "dashboard.workers[] is deprecated — move its entries to workers.list[] (removed in v1.9)."
        PITHEAD_WORKERS_LEGACY_WARNED=1
    fi
    dw_path="workers.list"
    if [ "${new_n:-0}" = "0" ] && [ "${legacy_n:-0}" != "0" ]; then dw_path="dashboard.workers"; fi
    dw_err=$(jq -r --arg path "$dw_path" "$WORKER_LIST_JQ"'
        worker_list as $w
        | if ($w | type) != "array" then "\($path) must be an array of {name, host?, port?, token?} objects."
          else [ $w[] |
              if type != "object" then "\($path) entries must be objects (got a \(type))."
              elif (.name | type) != "string" or (.name | test("^[!-~]{1,128}$") | not)
                then "\($path): every entry needs a \"name\" of 1-128 printable non-space characters (its stratum worker name)."
              elif has("host") and ((.host | type) != "string" or (.host | test("^[A-Za-z0-9._-]{1,253}$") | not))
                then "\($path)[\(.name)].host must be a hostname or IPv4 address (letters, digits, and . _ - only; no port or path)."
              elif has("port") and ((.port | type) != "number" or .port != (.port | floor) or .port < 1 or .port > 65535)
                then "\($path)[\(.name)].port must be an integer between 1 and 65535."
              elif has("control_port") and ((.control_port | type) != "number" or .control_port != (.control_port | floor) or .control_port < 1 or .control_port > 65535)
                then "\($path)[\(.name)].control_port must be an integer between 1 and 65535 (the rig writable control API port, #185)."
              elif has("token") and ((.token | type) != "string" or (.token | test("^[!-~]{1,128}$") | not))
                then "\($path)[\(.name)].token must be 1-128 printable non-space characters."
              elif has("watts") and ((.watts | type) != "number" or .watts <= 0 or .watts >= 1000000)
                then "\($path)[\(.name)].watts must be a positive number of watts (a manual power-draw estimate for the energy calculator, #260)."
              else empty end
          ] | first // empty end' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_err" ] || error "$dw_err"
    # Duplicate names are legal but only the FIRST declaration counts — surface that, once.
    dw_dups=$(jq -r "$WORKER_LIST_JQ"'[worker_list[] | .name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_dups" ] || warn "$dw_path has duplicate names ($dw_dups) — the first-declared entry wins; a renamed rig needs its config entry updated."
}

# Migrate a validated deprecated dashboard.workers[] (#172) to workers.list[] (#506) in place:
# move the entries, drop the old key, keep the pre-migration file as ${CONFIG_FILE}.bak-workers
# (the control channel's .bak-control naming). Runs AFTER validate_worker_endpoints, so only a
# config whose legacy entries already passed validation is ever rewritten. Write-back rules
# follow persist_node_credentials: never on a dry run (#556) — which also covers every
# control-channel preview, since preview dry-runs a staged copy — atomic temp+mv under umask 077,
# and best-effort: a failed write warns and the run continues reading the legacy key via
# worker_list. The pre-migration owner is restored after the mv so a root control-runner apply
# (#33) cannot strand config.json root-owned — the #480 bug class control_reown_operator_files
# exists for, handled here because this write happens mid-apply, before that reown runs.
migrate_legacy_workers() {
    local new_n legacy_n owner tmp="${CONFIG_FILE}.tmp"
    [ "$PITHEAD_DRY_RUN" -eq 1 ] && return 0
    new_n=$(jq -r '(.workers // {}) | (.list // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    legacy_n=$(jq -r '(.dashboard // {}) | (.workers // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    { [ "${legacy_n:-0}" -gt 0 ] && [ "${new_n:-0}" = "0" ]; } || return 0
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak-workers" 2>/dev/null; then
        warn "Could not back up $CONFIG_FILE before migrating dashboard.workers[] — leaving the deprecated key in place."
        return 0
    fi
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    if (
        umask 077
        jq '.workers = ((.workers // {}) + {list: .dashboard.workers}) | .dashboard |= del(.workers)' \
            "$CONFIG_FILE" >"$tmp" 2>/dev/null
    ); then
        mv "$tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        if [ -n "$owner" ]; then chown "$owner" "$CONFIG_FILE" 2>/dev/null || true; fi
        log "Migrated dashboard.workers[] to workers.list[] — the old copy is at ${CONFIG_FILE}.bak-workers."
    else
        rm -f "$tmp"
        warn "Could not migrate dashboard.workers[] to workers.list[] — continuing on the deprecated key (backup left at ${CONFIG_FILE}.bak-workers)."
    fi
}

# Validate the dashboard.energy block for the energy/profit calculator (#260). Like the worker
# descriptors, this renders nothing to .env — the dashboard reads it off the read-only config.json
# bind mount — so validation exists only to fail an apply loudly on a typo. Prices are operator-set
# non-negative numbers and the currency a short label; price_feed (#520) opts into fetching both
# prices live from CoinGecko over Tor instead (the static numbers stay as the fallback).
validate_energy_config() {
    local en_err
    en_err=$(jq -r '
        (.dashboard.energy // {}) as $e
        | if ($e | type) != "object" then "dashboard.energy must be an object {cost_per_kwh, currency?, xmr_price?, tari_price?, price_feed?}."
          elif (($e | keys) - ["cost_per_kwh", "currency", "xmr_price", "tari_price", "price_feed"]) != []
            then "dashboard.energy has an unknown key (\(($e | keys) - ["cost_per_kwh", "currency", "xmr_price", "tari_price", "price_feed"] | join(", "))). Only cost_per_kwh, currency, xmr_price, tari_price and price_feed are allowed."
          elif ($e | has("cost_per_kwh")) and (($e.cost_per_kwh | type) != "number" or $e.cost_per_kwh < 0)
            then "dashboard.energy.cost_per_kwh must be a non-negative number (your electricity price per kWh; 0 or unset hides the profit math)."
          elif ($e | has("xmr_price")) and (($e.xmr_price | type) != "number" or $e.xmr_price < 0)
            then "dashboard.energy.xmr_price must be a non-negative number (the fiat price of 1 XMR in your currency; 0 or unset hides net profit)."
          elif ($e | has("tari_price")) and (($e.tari_price | type) != "number" or $e.tari_price < 0)
            then "dashboard.energy.tari_price must be a non-negative number (the fiat price of 1 XTM in your currency; 0 or unset excludes Tari from net profit)."
          elif ($e | has("currency")) and (($e.currency | type) != "string" or ($e.currency | test("^[!-~]{1,128}$") | not))
            then "dashboard.energy.currency must be a short currency label (e.g. USD, EUR)."
          elif ($e | has("price_feed")) and (($e.price_feed | type) != "boolean")
            then "dashboard.energy.price_feed must be true or false (fetch live XMR/XTM prices from CoinGecko over Tor; default false, no clearnet egress)."
          else empty end' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$en_err" ] || error "$en_err"
}

parse_and_validate_config() {
    log "Parsing configuration..."
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE is not valid JSON."
    fi

    # Central .env line-injection guard (#33 hardening). No config string value may carry a
    # control character (newline, CR, tab, …). A raw newline in a value that renders into .env
    # unquoted — e.g. monero.node_password, telegram.bot_token, workers.api_token — would inject
    # a SECOND KEY=value line such as PITHEAD_REGISTRY=evil.tld/attacker; every compose image: is
    # ${PITHEAD_REGISTRY:-…}, so the root `apply -y` would then pull attacker images for the whole
    # stack (RCE). Now that the dashboard control channel lets a full config cross the trust
    # boundary, these fields are attacker-influenceable. Check EVERY string leaf here — the shared
    # chokepoint both `apply --dry-run` (preview) and `apply -y` (commit) run — so no current or
    # future field is missed. No legitimate config value contains a control character.
    if jq -e 'any(.. | strings; test("[[:cntrl:]]"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE has a config value containing a control character or newline. That is not allowed — it could inject an extra line into the stack's .env. Remove the newline/control character (check secrets like node_password, bot_token, api_token)."
    fi

    # ssh.enabled without a key is a lockout-shaped mistake: sshd would run with nothing to
    # accept. Key-only by design — password auth never turns on.
    if [ "$(jq -r '.ssh.enabled // false' "$CONFIG_FILE")" = "true" ]; then
        case "$(jq -r '.ssh.authorized_key // ""' "$CONFIG_FILE")" in
        ssh-* | ecdsa-* | sk-*) ;;
        *) error "ssh.enabled is true but ssh.authorized_key is not a public key (expected it to start with ssh-, ecdsa- or sk-). Paste the PUBLIC key (e.g. ~/.ssh/id_ed25519.pub)." ;;
        esac
    fi

    # Required fields
    MONERO_WALLET=$(jq -r '.monero.wallet_address // empty' "$CONFIG_FILE")
    TARI_WALLET=$(jq -r '.tari.wallet_address // empty' "$CONFIG_FILE")
    if [ -z "$MONERO_WALLET" ] || [ -z "$TARI_WALLET" ]; then
        error "Missing required wallet addresses in $CONFIG_FILE."
    fi
    # tari.wallet_address gets no shape regex: Tari addresses come in base58 AND emoji forms,
    # single/dual, with optional payment IDs — length and charset both vary (RFC-0155), so a
    # regex would false-reject valid addresses. Instead the real gate is tari_address_type below
    # (full decode + DammSum checksum, #845). Whitespace still gets its own message here — it's
    # the likeliest paste error, a space isn't a control char so the central guard above misses
    # it, and "invalid" alone wouldn't say where to look.
    case "$TARI_WALLET" in
    *[[:space:]]*) error "tari.wallet_address contains whitespace — a Tari address (base58 or emoji) has none. Check for a stray space or line break in $CONFIG_FILE." ;;
    esac
    if [ "$MONERO_WALLET" == "your_monero_wallet_address" ] || [ "$TARI_WALLET" == "your_tari_wallet_address" ]; then
        error "Wallet addresses in $CONFIG_FILE are still the template placeholders. Set your real addresses."
    fi
    # p2pool pays out via coinbase, which CANNOT go to a subaddress or integrated address — it requires a
    # PRIMARY/standard address (XvB credits by the same address too). A wrong type mines but is NEVER
    # paid, silently — so hard-fail here rather than let someone lose rewards (#250).
    case "$(monero_address_type "$MONERO_WALLET")" in
    primary) ;;
    subaddress) error "monero.wallet_address is a SUBADDRESS (starts with 8). p2pool cannot pay subaddresses — use your PRIMARY/standard Monero address (starts with 4)." ;;
    integrated) error "monero.wallet_address is an INTEGRATED address. p2pool needs your plain PRIMARY address (95 chars, starts with 4)." ;;
    checksum) error "monero.wallet_address ('${MONERO_WALLET:0:6}…') fails its checksum — at least one character is mistyped, and p2pool crashes on a mistyped address instead of mining. Re-copy the address from your wallet and try again." ;;
    *) error "monero.wallet_address ('${MONERO_WALLET:0:6}…', ${#MONERO_WALLET} chars) is not a valid Monero primary address (expected 95 chars starting with 4)." ;;
    esac

    # The Tari sibling of the gate above (#845): full decode + DammSum verdict, both address
    # forms. "unchecked" (no usable python3) passes — degraded to the pre-gate behaviour,
    # never a false reject.
    case "$(tari_address_type "$TARI_WALLET")" in
    ok | unchecked) ;;
    checksum) error "tari.wallet_address fails its checksum — at least one character is mistyped, and a mistyped address means Tari rewards are silently lost. Re-copy the address (base58 or emoji form) from your Tari wallet and try again." ;;
    network) error "tari.wallet_address is for a different Tari network (a testnet). This stack mines MAINNET Tari — use your mainnet address." ;;
    *) error "tari.wallet_address (${#TARI_WALLET} chars) is not a valid Tari address in either the base58 or the emoji form. Copy it from your Tari wallet." ;;
    esac

    MONERO_MODE=$(jq -r '.monero.mode // "local"' "$CONFIG_FILE")
    case "$MONERO_MODE" in
    local | remote) ;;
    *) error "monero.mode must be \"local\" or \"remote\" (got \"$MONERO_MODE\")." ;;
    esac

    # tari.mode (#103), the same explicit local/remote switch as monero.mode above. Read here (not
    # only inside the view-key gate below) so an invalid value fails validation regardless of
    # whether a view key is even set.
    TARI_MODE=$(jq -r '.tari.mode // "local"' "$CONFIG_FILE")
    case "$TARI_MODE" in
    local | remote) ;;
    *) error "tari.mode must be \"local\" or \"remote\" (got \"$TARI_MODE\")." ;;
    esac

    # On-chain payout confirmation (#381). The operator supplies the PRIVATE VIEW KEY for
    # monero.wallet_address; the stack runs a view-only monero-wallet-rpc against the LOCAL node to
    # confirm payouts actually landed. The view key is a SECRET (it reveals all incoming amounts and
    # timing to anyone who can read config.json/.env) — handled like node_password: never logged or
    # echoed. Empty (the default) = feature off, nothing new runs. Phase 1 is LOCAL NODE ONLY:
    # scanning through a third-party daemon changes the trust story, so a view key set on a remote
    # node is refused, loudly — the wrong way to fail is silent.
    MONERO_VIEW_KEY=$(jq -r '.monero.view_key // empty' "$CONFIG_FILE")
    PAYOUT_SCAN_HEIGHT=$(jq -r '.monero.payout_scan_height // "auto"' "$CONFIG_FILE")
    PAYOUT_CONFIRM_ENABLED=false
    if [ -n "$MONERO_VIEW_KEY" ]; then
        if [ "$MONERO_MODE" != "local" ]; then
            error "monero.view_key is set but monero.mode is \"$MONERO_MODE\". On-chain payout confirmation scans against the LOCAL node only — a remote/third-party daemon changes the trust story. Unset monero.view_key, or switch to a local node."
        fi
        # A view key is 64 lowercase hex chars. Reject a malformed value before it reaches the wallet.
        if ! printf '%s' "$MONERO_VIEW_KEY" | grep -qE '^[0-9a-f]{64}$'; then
            error "monero.view_key must be the 64-character hex PRIVATE VIEW KEY for monero.wallet_address (get it from your wallet: 'View Key' / 'wallet_secret_view_key'). Got ${#MONERO_VIEW_KEY} chars."
        fi
        case "$PAYOUT_SCAN_HEIGHT" in
        '' | auto | [0-9]*) ;;
        *) error "monero.payout_scan_height must be \"auto\" or a block height (integer). Got \"$PAYOUT_SCAN_HEIGHT\"." ;;
        esac
        PAYOUT_CONFIRM_ENABLED=true
    fi

    # Tari on-chain payout confirmation (#462), the sibling of #381 for the merge-mine half. The
    # operator supplies the PRIVATE VIEW KEY plus the PUBLIC SPEND KEY for the Tari payout address;
    # the stack runs a view-only minotari_console_wallet against the LOCAL Tari node to confirm a
    # merge-mine coinbase actually landed. The view key is a SECRET (reveals all incoming amounts and
    # timing) — handled like node_password: never logged or echoed, delivered to the container via a
    # tmpfs-mounted compose secret, never the command line or `docker inspect`. Empty (the default) =
    # feature off. Phase 1 is LOCAL NODE ONLY: a view key with a remote Tari node (#103) is refused,
    # mirroring monero.mode — scanning through a third-party node changes the trust story.
    # tari.payout_scan_birthday is Tari's restore point: DAYS SINCE THE UNIX EPOCH (a u16, not a
    # block height), so a fresh wallet doesn't rescan from genesis. TARI_MODE was already parsed and
    # validated above.
    TARI_VIEW_KEY=$(jq -r '.tari.view_key // empty' "$CONFIG_FILE")
    TARI_SPEND_PUBLIC_KEY=$(jq -r '.tari.spend_public_key // empty' "$CONFIG_FILE")
    TARI_WALLET_BIRTHDAY=$(jq -r '.tari.payout_scan_birthday // "auto"' "$CONFIG_FILE")
    TARI_PAYOUT_CONFIRM_ENABLED=false
    if [ -n "$TARI_VIEW_KEY" ]; then
        if [ "$TARI_MODE" != "local" ]; then
            error "tari.view_key is set but tari.mode is \"$TARI_MODE\". Payout confirmation needs the LOCAL Tari node — unsupported with tari.mode: remote, since scanning through a third-party node changes the trust story. Unset tari.view_key, or use a local Tari node."
        fi
        # Tari view / public-spend keys are 64 lowercase hex chars (32-byte Ristretto scalar / point).
        if ! printf '%s' "$TARI_VIEW_KEY" | grep -qE '^[0-9a-f]{64}$'; then
            error "tari.view_key must be the 64-character hex PRIVATE VIEW KEY for the Tari payout address (from your Tari wallet: 'export-view-key-and-spend-key'). Got ${#TARI_VIEW_KEY} chars."
        fi
        # A view-only Tari wallet needs the PUBLIC spend key too — require both together.
        if ! printf '%s' "$TARI_SPEND_PUBLIC_KEY" | grep -qE '^[0-9a-f]{64}$'; then
            error "tari.spend_public_key must be the 64-character hex PUBLIC SPEND KEY for the Tari payout address (exported alongside the view key). Set it whenever tari.view_key is set."
        fi
        # Birthday is "auto" (resolved to today's days-since-epoch at wallet creation) or an explicit
        # u16 days-since-epoch (0–65535). Reject anything else before it reaches the wallet.
        case "$TARI_WALLET_BIRTHDAY" in
        '' | auto) ;;
        *[!0-9]*) error "tari.payout_scan_birthday must be \"auto\" or DAYS SINCE THE UNIX EPOCH (an integer 0–65535, NOT a block height). Got \"$TARI_WALLET_BIRTHDAY\"." ;;
        *) [ "$TARI_WALLET_BIRTHDAY" -le 65535 ] || error "tari.payout_scan_birthday must be ≤ 65535 (days since the Unix epoch, a u16). Got \"$TARI_WALLET_BIRTHDAY\"." ;;
        esac
        TARI_PAYOUT_CONFIRM_ENABLED=true
    fi

    # Bridge network subnet (#180): configurable so the stack can avoid colliding with a 172.28.0.0/24
    # already in use on the host (Docker else errors "Pool overlaps with other one on this address
    # space" and the install fails). The structured fixed-IP layout is preserved — services keep their
    # .25–.31 host octets, the host-networked dashboard reaches them by IP, and the #122 SSRF guard
    # keys off the CIDR — only the /24 base moves. Everything derives from NETWORK_PREFIX (the first
    # three octets). Must be an X.Y.Z.0/24 block.
    NETWORK_SUBNET=$(jq -r '.network.subnet // "172.28.0.0/24"' "$CONFIG_FILE")
    case "$NETWORK_SUBNET" in
    *.0/24) NETWORK_PREFIX="${NETWORK_SUBNET%.0/24}" ;;
    *) error "network.subnet must be an X.Y.Z.0/24 block (got \"$NETWORK_SUBNET\")." ;;
    esac
    is_ipv4 "${NETWORK_PREFIX}.0" || error "network.subnet is not a valid IPv4 /24 (got \"$NETWORK_SUBNET\")."
    # Fail-closed Tor-only egress firewall (#270); default on. Renders to .env so `up` can read it.
    # config_bool (not a plain `// true`) so an explicit false actually disables it — see #294.
    TOR_EGRESS_FIREWALL=$(normalize_bool "$(config_bool '.network.tor_egress_firewall' true)")
    # Clearnet initial sync vs. the egress firewall: a clearnet_initial_sync flag asks a daemon's
    # first sync to dial out over clearnet (fast); the egress firewall (default on) DROPs every
    # non-Tor dial, so that clearnet sync is silently defeated — the daemon just falls back to
    # syncing over Tor at ordinary speed instead of failing. Nothing leaks (the firewall did its
    # job), so this is WARN not FAIL — refusing would block a config that is merely slower than
    # the operator intended, not one that's unsafe. Checked here (not just in render_env, which
    # only runs for `up`/`apply`) so the contradiction surfaces on every command that validates
    # config, including `doctor` and `edit`.
    if [ "$TOR_EGRESS_FIREWALL" = "true" ]; then
        local _cn_sync=""
        [ "$(config_bool '.monero.clearnet_initial_sync' false)" = "true" ] && _cn_sync="Monero"
        [ "$(config_bool '.tari.clearnet_initial_sync' false)" = "true" ] && _cn_sync="${_cn_sync:+$_cn_sync + }Tari"
        if [ -n "$_cn_sync" ]; then
            warn "$_cn_sync clearnet_initial_sync is on, but network.tor_egress_firewall is also on — the firewall drops the clearnet dials, so the sync will not actually leave Tor. Either turn off tor_egress_firewall for a real clearnet sync, or turn off clearnet_initial_sync and accept the normal Tor-speed sync."
        fi
    fi
    # Tor guard self-heal (#424); OPT-IN, default off — a tor restart drops all circuits, so the
    # stack never restarts its privacy boundary unbidden. Renders to .env for the dashboard,
    # which owns the probe/restart loop (dashboard .../service/tor_heal.py).
    TOR_AUTO_HEAL=$(normalize_bool "$(config_bool '.tor.auto_heal' false)")
    # Surfaced for the dashboard's egress-posture panel (#170); mirrors what p2pool_outbound_flags reads.
    P2POOL_CLEARNET=$(normalize_bool "$(config_bool '.p2pool.clearnet' false)")
    # Remote-node host/port validation (#103). The central control-char guard above already stops a
    # newline forging an .env line, but a remote.host also flows into shell/URL sinks it doesn't
    # cover: monero's into the p2pool `--host` arg, tari's into `--merge-mine tari://…` AND the socat
    # bridge command `TCP:$_mmhost:$_mmport` (build/p2pool/entrypoint.sh), where a comma is read as a
    # socat address-option separator (`TCP:host,fork,…`). So charset-guard both with the same
    # is_valid_host/is_valid_port used for dashboard.host/.port — no comma/space/`{` reaches a sink.
    # These resolve once here and are reused verbatim by render_env (globals, like MONERO_MODE above),
    # so the value that passes validation is exactly the value rendered — no second jq read, no drift.
    # Cleared to empty first (defensive): each real `apply` is a fresh process so these start unset,
    # but clearing them keeps the invariant "globals reflect only the current config" true even if a
    # future caller ever parses twice in one process — a stale remote host must never survive into a
    # later local-mode render.
    MONERO_REMOTE_HOST="" MONERO_REMOTE_RPC_PORT="" MONERO_REMOTE_ZMQ_PORT=""
    TARI_REMOTE_HOST="" TARI_REMOTE_GRPC_PORT=""
    if [ "$MONERO_MODE" == "remote" ]; then
        MONERO_REMOTE_HOST=$(jq -r '.monero.remote.host // empty' "$CONFIG_FILE")
        [ -n "$MONERO_REMOTE_HOST" ] || error "monero.mode is \"remote\" but monero.remote.host is not set in $CONFIG_FILE."
        is_valid_host "$MONERO_REMOTE_HOST" || error "monero.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got \"$MONERO_REMOTE_HOST\"."
        MONERO_REMOTE_RPC_PORT=$(jq -r '.monero.remote.rpc_port // 18081' "$CONFIG_FILE")
        is_valid_port "$MONERO_REMOTE_RPC_PORT" || error "monero.remote.rpc_port must be a TCP port 1–65535. Got \"$MONERO_REMOTE_RPC_PORT\"."
        MONERO_REMOTE_ZMQ_PORT=$(jq -r '.monero.remote.zmq_port // 18083' "$CONFIG_FILE")
        is_valid_port "$MONERO_REMOTE_ZMQ_PORT" || error "monero.remote.zmq_port must be a TCP port 1–65535. Got \"$MONERO_REMOTE_ZMQ_PORT\"."
    fi
    # tari.mode remote (#103), mirroring monero.mode above: a third-party (or fleet-shared) Tari
    # base node needs a host — an empty one would render an empty TARI_GRPC_ADDRESS and mining can't
    # merge-mine, so abort at validation rather than let that reach the containers silently.
    if [ "$TARI_MODE" == "remote" ]; then
        TARI_REMOTE_HOST=$(jq -r '.tari.remote.host // empty' "$CONFIG_FILE")
        [ -n "$TARI_REMOTE_HOST" ] || error "tari.mode is \"remote\" but tari.remote.host is not set in $CONFIG_FILE."
        is_valid_host "$TARI_REMOTE_HOST" || error "tari.remote.host must be a hostname or IP literal (letters, digits, and . : _ - only, ≤253 chars). Got \"$TARI_REMOTE_HOST\"."
        TARI_REMOTE_GRPC_PORT=$(jq -r '.tari.remote.grpc_port // 18142' "$CONFIG_FILE")
        is_valid_port "$TARI_REMOTE_GRPC_PORT" || error "tari.remote.grpc_port must be a TCP port 1–65535. Got \"$TARI_REMOTE_GRPC_PORT\"."
    fi

    POOL_TYPE=$(jq -r '.p2pool.pool // "mini"' "$CONFIG_FILE")
    case "$POOL_TYPE" in
    main | mini | nano) ;;
    *) error "p2pool.pool must be \"main\", \"mini\", or \"nano\" (got \"$POOL_TYPE\")." ;;
    esac

    # Host interface the stratum port (:3333) publishes on. Default 0.0.0.0 so LAN rigs can
    # reach it out of the box; narrow it (e.g. a specific LAN IP, or 127.0.0.1 to disable LAN
    # access) on a public-IP host. Validate it's an IPv4 literal so a typo can't produce an
    # unparseable compose port binding. Rendered to STRATUM_BIND in .env.
    STRATUM_BIND=$(jq -r '.p2pool.stratum_bind // "0.0.0.0"' "$CONFIG_FILE")
    if ! is_ipv4 "$STRATUM_BIND"; then
        error "p2pool.stratum_bind must be an IPv4 address like \"0.0.0.0\", \"127.0.0.1\", or your LAN IP (got \"$STRATUM_BIND\")."
    fi

    # Operator-facing stratum port (#172), default 3333 — the host port xmrig-proxy binds and
    # publishes, i.e. what every rig dials. Rendered to STRATUM_PORT in .env; RigForge rigs must
    # point at the same port (rigforge pool.port). p2pool's container-INTERNAL stratum stays fixed
    # at :3333 (only xmrig-proxy dials it on the bridge), so P2POOL_URL is untouched by this knob.
    STRATUM_PORT=$(jq -r '.p2pool.stratum_port // 3333' "$CONFIG_FILE")
    if ! printf '%s' "$STRATUM_PORT" | grep -qE '^[0-9]{1,5}$' || [ "$STRATUM_PORT" -lt 1 ] || [ "$STRATUM_PORT" -gt 65535 ]; then
        error "p2pool.stratum_port must be an integer between 1 and 65535 (got \"$STRATUM_PORT\")."
    fi

    validate_worker_endpoints
    migrate_legacy_workers
    validate_energy_config

    # Optional miner authentication on the stratum port (#152). xmrig-proxy's --access-password
    # rejects rigs whose stratum 'pass' doesn't match, so only devices that know the secret can
    # mine through the proxy (this also shrinks the #122 SSRF surface). Three modes:
    #   ""/absent → disabled (default): any rig that can reach :3333 may mine; 'pass' is ignored.
    #   "auto"    → generate a secret once and PERSIST it in .env (reused across apply, exactly like
    #               PROXY_AUTH_TOKEN); set the same value as every rig's stratum 'pass'.
    #   <literal> → use exactly this password.
    # Rendered to PROXY_STRATUM_PASSWORD. The password travels CLEARTEXT over stratum, so this is
    # access control ("who may mine"), not encryption — pair it with a LAN-only bind / firewall.
    STRATUM_PASSWORD=$(jq -r '.p2pool.stratum_password // ""' "$CONFIG_FILE")
    if [ "$STRATUM_PASSWORD" = "auto" ]; then
        STRATUM_PASSWORD=$(env_get PROXY_STRATUM_PASSWORD) # reuse a previously generated one
        [ -n "$STRATUM_PASSWORD" ] || STRATUM_PASSWORD=$(openssl rand -hex 12)
    fi
    # A non-empty password is written to .env and substituted into the proxy's CLI args, so restrict
    # it to a shell/.env-safe charset — a space, quote, or '$' could break .env parsing or the
    # compose command. (The auto-generated hex always passes.)
    if [ -n "$STRATUM_PASSWORD" ] && ! printf '%s' "$STRATUM_PASSWORD" | grep -qE '^[A-Za-z0-9._:@-]{1,128}$'; then
        error "p2pool.stratum_password must be \"auto\", empty, or 1–128 chars of letters, digits, and . _ : @ - (no spaces or quotes)."
    fi

    # Stratum-over-TLS (#261): confidentiality on the miner↔stack leg, on top of the access
    # control above — orthogonal, usable together. Single-port model: with a cert configured,
    # xmrig-proxy AUTODETECTS TLS on the same stratum bind (verified against the pinned 6.26.0
    # binary), so cleartext rigs keep mining while rigs opt in one at a time (pools[].tls +
    # fingerprint pinning, rigforge#115). Rigs authenticate the server by pinning the cert's
    # SHA-256 fingerprint — xmrig does no CA validation for stratum — so the cert is self-signed
    # and long-lived, and enforcing TLS-only is deliberately NOT a v1.9 knob (rigs first, posture
    # flip later — the same discipline as the #208 default).
    STRATUM_TLS=$(normalize_bool "$(config_bool '.p2pool.stratum_tls' false)")

    # xmrig-proxy dev-fee donation level (#173). xmrig-proxy's own compiled default is 0% (no
    # donation) — which the stack inherited silently; expose it so operators can both SEE it and
    # opt in. Default 0 (off); set N to donate N% of submitted hashrate to the xmrig developers
    # (integer 0–99). Rendered to PROXY_DONATE_LEVEL and passed verbatim as --donate-level so the
    # effective level is always visible. NOTE: this is NOT the XvB donation — that is xvb.* steered
    # by the decision engine, never the proxy dev fee.
    DONATE_LEVEL=$(jq -r '.proxy.donate_level // 0' "$CONFIG_FILE")
    if ! printf '%s' "$DONATE_LEVEL" | grep -qE '^[0-9]+$' || [ "$DONATE_LEVEL" -gt 99 ]; then
        error "proxy.donate_level must be an integer 0–99 (percent); default 0 (got \"$DONATE_LEVEL\")."
    fi

    MONERO_USER=$(jq -r '.monero.node_username // empty' "$CONFIG_FILE")
    MONERO_PASS=$(jq -r '.monero.node_password // empty' "$CONFIG_FILE")

    # A local node always needs working RPC creds. If they're missing — empty, or still the
    # template placeholder — generate them and persist back to config.json, so an unedited/partial
    # config never produces a broken "rpc-login=:" and the creds stay stable across `apply`.
    # Remote mode is left untouched: empty creds there mean "no auth", and we can't invent
    # credentials for someone else's node.
    if [ "$MONERO_MODE" == "local" ]; then
        local creds_generated=0
        if cred_needs_generating "$MONERO_USER" "$PLACEHOLDER_NODE_USER"; then
            MONERO_USER=$(default_node_username)
            creds_generated=1
        fi
        if cred_needs_generating "$MONERO_PASS" "$PLACEHOLDER_NODE_PASS"; then
            MONERO_PASS=$(generate_node_password)
            creds_generated=1
        fi
        if [ "$creds_generated" -eq 1 ]; then
            persist_node_credentials "$MONERO_USER" "$MONERO_PASS"
            log "Auto-generated missing local Monero node RPC credentials (saved in $CONFIG_FILE)."
        fi
    fi

    # Resolve data directories ("auto"/empty/legacy DYNAMIC_DATA → the stack default under ./data)
    MONERO_DIR=$(resolve_default "$(jq -r '.monero.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/monero")
    TARI_DIR=$(resolve_default "$(jq -r '.tari.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/tari")
    P2POOL_DIR=$(resolve_default "$(jq -r '.p2pool.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/p2pool")
    TOR_DATA_DIR=$(resolve_default "$(jq -r '.tor.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/tor")
    # Shared data root (#455): when monero/tari/p2pool/tor all resolve under ONE parent, that
    # parent is the box's data root and the dashboard's DEFAULT joins it — before this, the
    # dashboard DB was the only data living inside the (per-version) install dir, moving with the
    # code on every versioned deploy. An all-default install (or scattered custom dirs) keeps the
    # classic ./data default, so nothing changes unless the chain data was deliberately co-located.
    local _data_root _dash_cfg
    _data_root=$(dirname "$MONERO_DIR")
    { [ "$(dirname "$TARI_DIR")" == "$_data_root" ] &&
        [ "$(dirname "$P2POOL_DIR")" == "$_data_root" ] &&
        [ "$(dirname "$TOR_DATA_DIR")" == "$_data_root" ]; } || _data_root="$PWD/data"
    _dash_cfg=$(jq -r '.dashboard.data_dir // empty' "$CONFIG_FILE")
    DASHBOARD_DIR=$(resolve_default "$_dash_cfg" "$_data_root/dashboard")
    # Global, read by migrate_dashboard_data: the #455 migration only ever moves a DEFAULT
    # location — an operator-pinned dashboard.data_dir is theirs, never touched.
    DASHBOARD_DIR_IS_DEFAULT=1
    [ "$DASHBOARD_DIR" == "$_dash_cfg" ] && DASHBOARD_DIR_IS_DEFAULT=0
    # Stratum TLS keypair home (#261): joins the shared data root when one exists — the cert's
    # FINGERPRINT is what every rig pins, so it must survive versioned deploys like the chain
    # data does, not move with the code. Internal (not config-driven), like CONTROL_DIR.
    PROXY_TLS_DIR="$_data_root/proxy-tls"
    # Internal shared state dir (#234): the dashboard (rw) drops a per-chain "clearnet sync complete"
    # marker here and the monerod/tari entrypoints (ro) read it to decide Tor-vs-clearnet. Not a
    # user-facing data dir, so it's fixed under ./data rather than config-driven.
    CLEARNET_STATE_DIR="$PWD/data/clearnet-state"
    # Control-channel spool (#33): requests/ (container rw) + staged/results/audit (host-only /
    # container ro). Fixed under ./data like CLEARNET_STATE_DIR — not a user-facing data dir.
    # Deliberately NOT inside DASHBOARD_DIR, which is mounted rw wholesale into the container.
    CONTROL_DIR="$PWD/data/control"
    # Caddy access log (#349): Caddy (rw) writes access.log here, the dashboard mounts it
    # read-only. Fixed under ./data like the spool above — internal, not a user-facing data dir.
    CADDY_LOG_DIR="$PWD/data/caddy-logs"

    # Guard every data dir against catastrophic chown -R / rm -rf targets before we touch them.
    local d
    for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" "$CLEARNET_STATE_DIR" "$CONTROL_DIR" "$CADDY_LOG_DIR" "$PROXY_TLS_DIR"; do
        assert_safe_dir "$d"
    done

    # "auto"/empty/DYNAMIC_HOST here means "decide later" (preserved value, prompt, or hostname)
    DASHBOARD_HOST=$(resolve_default "$(jq -r '.dashboard.host // empty' "$CONFIG_FILE")" "")
    # A non-"auto" host is rendered verbatim into the Caddyfile site address (generate_caddyfile),
    # so reject anything that isn't a bare hostname/IP — a space, newline, or `{`/`}` would break
    # the Caddyfile (or inject directives). Mirrors the stratum_bind validation above (#130).
    if [ -n "$DASHBOARD_HOST" ] && ! is_valid_host "$DASHBOARD_HOST"; then
        error "dashboard.host must be a hostname or IP address — only letters, digits, dots, hyphens, and colons (got \"$DASHBOARD_HOST\")."
    fi
    # Caddy LAN listen port (#740). "auto"/empty keeps the scheme default (443 secure / 80 plain) —
    # today's behavior. An explicit port moves the LAN vhost so an existing reverse proxy on the host
    # can keep 80/443 (co-hosting, #181). Rendered into the Caddyfile site address (generate_caddyfile),
    # so validate it is a bare 1–65535 port before it lands there.
    HOST_PORT=$(resolve_default "$(jq -r '.dashboard.port // empty' "$CONFIG_FILE")" "")
    if [ -n "$HOST_PORT" ] && ! is_valid_port "$HOST_PORT"; then
        error "dashboard.port must be a whole number between 1 and 65535, or \"auto\" (got \"$HOST_PORT\")."
    fi
    # Ensure a strict true/false string is returned, defaulting to true
    DASHBOARD_SECURE=$(jq -r 'if .dashboard.secure != null then .dashboard.secure | tostring else "true" end' "$CONFIG_FILE")
    # Deliberate opt-in to serving the dashboard on a globally-routable address. Default false:
    # the appliance auto-publishes every address it holds, and on any network passing IPv6 through
    # that silently included a public one. The supported off-LAN route is the onion service.
    DASHBOARD_EXPOSE_PUBLIC_IP=$(config_bool '.dashboard.expose_public_ip' false)
    # Timezone for the dashboard's timestamps/charts. "auto"/empty -> the host's timezone
    # (auto-detected; falls back to Etc/UTC). Set an IANA name (e.g. America/Chicago) to
    # override. Rendered into .env as DASHBOARD_TZ.
    DASHBOARD_TZ=$(resolve_default "$(jq -r '.dashboard.timezone // empty' "$CONFIG_FILE")" "$(detect_host_timezone)")

    # Optional dashboard login (#8): Caddy basic_auth in front of the dashboard. OPT-IN — an empty
    # password (the default) leaves it open, today's behavior, which is fine for the LAN appliance;
    # turn it on before exposing/co-hosting the dashboard. The plaintext lives only in config.json
    # (owner-only); pithead bcrypt-hashes it with the pinned Caddy image and stores the hash
    # base64-encoded in .env (raw bcrypt's '$' spams compose interpolation warnings). A sha256
    # fingerprint of the plaintext keeps the hash STABLE across applies — re-hash only when the
    # password actually changes (bcrypt is salted, so re-hashing every apply would churn the Caddyfile).
    DASHBOARD_AUTH_USER=$(jq -r '.dashboard.auth.username // "admin"' "$CONFIG_FILE")
    DASHBOARD_AUTH_HASH_B64=""
    DASHBOARD_AUTH_PW_FP=""
    local dash_pw
    dash_pw=$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE")
    if [ -n "$dash_pw" ]; then
        if ! printf '%s' "$DASHBOARD_AUTH_USER" | grep -qE '^[A-Za-z0-9._@-]{1,64}$'; then
            error "dashboard.auth.username must be 1–64 chars of letters, digits, and . _ @ - (got \"$DASHBOARD_AUTH_USER\")."
        fi
        if ! printf '%s' "$dash_pw" | grep -qE '^[[:print:]]{8,128}$' || printf '%s' "$dash_pw" | grep -q '"'; then
            error "dashboard.auth.password must be 8–128 printable characters with no double-quotes."
        fi
        DASHBOARD_AUTH_PW_FP=$(printf '%s' "$dash_pw" | sha256_hex)
        local prev_fp prev_hash
        prev_fp=$(env_get DASHBOARD_AUTH_PW_FP)
        prev_hash=$(env_get DASHBOARD_AUTH_HASH_B64)
        if [ "$DASHBOARD_AUTH_PW_FP" = "$prev_fp" ] && [ -n "$prev_hash" ]; then
            DASHBOARD_AUTH_HASH_B64="$prev_hash" # password unchanged — keep the stable hash
        else
            DASHBOARD_AUTH_HASH_B64=$(caddy_hash_password_b64 "$dash_pw") ||
                error "Could not hash dashboard.auth.password (is Docker running and the Caddy image pulled? Run '$0 setup' first)."
        fi
        # basic_auth credentials are only safe over TLS; warn (don't fail) on plain HTTP. This is
        # about the LAN vhost — the onion vhost (#343) serves plain HTTP by design (Tor is the
        # transport), so it is exempt and does not trip this.
        if [ "$DASHBOARD_SECURE" != "true" ] && [ "$(config_bool '.dashboard.onion.enabled' false)" != "true" ]; then
            warn "dashboard.auth is set but dashboard.secure is false — login credentials would travel over plain HTTP. Set dashboard.secure: true for HTTPS."
        fi
    fi

    # Optional dashboard onion (#343). Opt-in, default off. When on, pithead publishes the dashboard
    # as a Tor v3 hidden service — reachable from anywhere over Tor, no exposed ports, no public IP.
    # Because that puts a CONTROL PANEL at a stable address, FAIL CLOSED: refuse to enable it without
    # a login, and demand a stronger password than the LAN 8-char floor — a published .onion is
    # online-brute-forceable (per-IP throttling is meaningless over Tor; every request arrives from
    # the local tor daemon, so there is no source IP to rate-limit against).
    DASHBOARD_ONION_ENABLED=$(normalize_bool "$(config_bool '.dashboard.onion.enabled' false)")
    # Tor v3 client authorization (#343): the strong PRIMARY gate. Default ON whenever the onion is
    # on — a client-auth'd onion does not respond at all without the operator's client key, which
    # defeats address-scanning and brute force entirely (the password becomes a second factor behind
    # it). Set dashboard.onion.client_auth:false only for a deliberately password-only onion.
    DASHBOARD_ONION_CLIENT_AUTH=false
    if [ "$DASHBOARD_ONION_ENABLED" == "true" ]; then
        DASHBOARD_ONION_CLIENT_AUTH=$(normalize_bool "$(config_bool '.dashboard.onion.client_auth' true)")
        if [ -z "$dash_pw" ]; then
            error "dashboard.onion.enabled is true but dashboard.auth.password is empty. Publishing the dashboard as a Tor onion exposes a control panel at a stable address — it must sit behind a login. Set a strong dashboard.auth.password (16+ characters) and re-run."
        fi
        if [ "$(printf '%s' "$dash_pw" | wc -c)" -lt 16 ]; then
            error "dashboard.auth.password must be at least 16 characters when dashboard.onion.enabled is true (a published .onion is online-brute-forceable and per-IP throttling is meaningless over Tor). Use a passphrase."
        fi
        # Reject obviously weak 16+ char choices the length floor alone would pass: a single repeated
        # character, or a well-known weak pattern. Not a full dictionary — the floor handles the rest.
        if [ "$(printf '%s' "$dash_pw" | fold -w1 | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then
            error "dashboard.auth.password is a single repeated character — choose a real passphrase."
        fi
        case "$(printf '%s' "$dash_pw" | tr 'A-Z' 'a-z')" in
        *passwordpassword* | *0123456789* | *qwertyuiop* | *changeme* | *letmein*)
            error "dashboard.auth.password contains a well-known weak pattern — choose a real passphrase (16+ characters)."
            ;;
        esac
    fi

    # Dashboard control channel (#33). Opt-in, default off. When on, the dashboard's Configuration
    # view can stage config changes that the host-side runner (control-run-pending) validates and
    # applies. That is a host-mutation channel that can change the payout wallet, so FAIL CLOSED:
    # refuse to enable it on a dashboard with no login (mirrors the onion-without-password refusal).
    DASHBOARD_CONTROL_ENABLED=$(normalize_bool "$(config_bool '.dashboard.control.enabled' false)")
    if [ "$DASHBOARD_CONTROL_ENABLED" == "true" ] && [ -z "$dash_pw" ]; then
        error "dashboard.control.enabled is true but dashboard.auth.password is empty. Config editing from the dashboard can change the payout wallet and run '$0 apply' — it must sit behind a login. Set dashboard.auth.password and re-run."
    fi
    # And on a PUBLISHED onion, refuse the control channel unless Tor v3 client authorization is on
    # (mirrors the onion-without-password refusal above). The control channel is a root-capable,
    # funds-redirecting mutation surface; a password alone on an anonymously-reachable .onion is
    # online-brute-forceable (per-IP throttling is meaningless over Tor). Client-auth means the onion
    # does not respond at all without the operator's key — the real primary gate. Set it before
    # exposing config editing to the internet.
    if [ "$DASHBOARD_CONTROL_ENABLED" == "true" ] && [ "$DASHBOARD_ONION_ENABLED" == "true" ] && [ "$DASHBOARD_ONION_CLIENT_AUTH" != "true" ]; then
        error "dashboard.control.enabled is true on a published onion (dashboard.onion.enabled) but dashboard.onion.client_auth is false. A root-capable config-mutation channel must not sit behind only a brute-forceable password on an anonymously-reachable .onion. Set dashboard.onion.client_auth: true (the default) and re-run."
    fi

    # Telegram two-way control commands (#338). Opt-in, default off. This is a REMOTELY-REACHABLE
    # host-control surface, so it fails closed on every leg — refuse to enable it unless the whole
    # chain is present:
    #   - It rides the #33 spool + root runner, so dashboard.control.enabled must be on (the spool and
    #     the systemd path unit that drains it only exist then); otherwise a /restart intent would
    #     pile up unprocessed.
    #   - The bot must actually be polling for commands (telegram.commands.enabled), which itself
    #     needs telegram.enabled plus a bot_token and chat_id (guarded by the dashboard too).
    #   - At least one allow-listed Telegram user id, or nobody could ever confirm an action and the
    #     feature would be inert — better to say so at apply time than to fail silently at runtime.
    if [ "$(normalize_bool "$(config_bool '.telegram.control.enabled' false)")" == "true" ]; then
        [ "$DASHBOARD_CONTROL_ENABLED" == "true" ] ||
            error "telegram.control.enabled is true but dashboard.control.enabled is false. The Telegram /restart and /apply commands ride the host-control spool, which only exists when the dashboard control channel is on. Enable dashboard.control (and its login) first, or turn telegram.control off."
        [ "$(normalize_bool "$(config_bool '.telegram.commands.enabled' false)")" == "true" ] ||
            error "telegram.control.enabled is true but telegram.commands.enabled is false. The control commands are handled by the same bot that answers the read-only commands — enable telegram.commands (and telegram itself) first."
        [ "$(jq -r '(.telegram.control.allowed_ids // []) | length' "$CONFIG_FILE")" -gt 0 ] ||
            error "telegram.control.enabled is true but telegram.control.allowed_ids is empty. A remotely-reachable host-control command must be gated to specific operator Telegram user ids — with none listed every command is refused. Add your numeric Telegram user id to telegram.control.allowed_ids."
    fi
}

# Load secrets and one-time-provisioned values from an existing .env so that re-rendering
# (apply, or a re-run setup) never rotates the proxy token or loses the Tor onion addresses.
# Generates a fresh proxy token only when none exists yet.
load_preserved_state() {
    PROXY_AUTH_TOKEN=$(env_get PROXY_AUTH_TOKEN)
    # View-only wallet-rpc login (#381): the dashboard→wallet-rpc password. Generated once and
    # preserved across applies (like PROXY_AUTH_TOKEN) so both containers keep matching creds.
    WALLET_RPC_PASSWORD=$(env_get WALLET_RPC_PASSWORD)
    # View-only Tari wallet password (#462): encrypts the wallet DB on its named volume. MUST stay
    # stable across applies or the existing wallet file can't be reopened — preserve like the above.
    TARI_WALLET_PASSWORD=$(env_get TARI_WALLET_PASSWORD)
    MONERO_ONION=$(env_get MONERO_ONION_ADDRESS)
    TARI_ONION=$(env_get TARI_ONION_ADDRESS)
    P2POOL_ONION=$(env_get P2POOL_ONION_ADDRESS)
    DASHBOARD_ONION=$(env_get DASHBOARD_ONION_ADDRESS)
    DASHBOARD_ONION_CLIENT_PUBKEY=$(env_get DASHBOARD_ONION_CLIENT_PUBKEY)
    DASHBOARD_ONION_CLIENT_PRIVKEY=$(env_get DASHBOARD_ONION_CLIENT_PRIVKEY)
    PRESERVED_HOST_IP=$(env_get HOST_IP)

    [ -n "$PROXY_AUTH_TOKEN" ] || PROXY_AUTH_TOKEN=$(openssl rand -hex 12)
    [ -n "$WALLET_RPC_PASSWORD" ] || WALLET_RPC_PASSWORD=$(openssl rand -hex 12)
    [ -n "$TARI_WALLET_PASSWORD" ] || TARI_WALLET_PASSWORD=$(openssl rand -hex 16)
    [ -n "$MONERO_ONION" ] || MONERO_ONION="placeholder"
    [ -n "$TARI_ONION" ] || TARI_ONION="placeholder"
    [ -n "$P2POOL_ONION" ] || P2POOL_ONION="placeholder"
    [ -n "$DASHBOARD_ONION" ] || DASHBOARD_ONION="placeholder"
    [ -n "$DASHBOARD_ONION_CLIENT_PUBKEY" ] || DASHBOARD_ONION_CLIENT_PUBKEY="placeholder"
    [ -n "$DASHBOARD_ONION_CLIENT_PRIVKEY" ] || DASHBOARD_ONION_CLIENT_PRIVKEY="placeholder"
    return 0
}

prepare_directories() {
    log "Initializing data directories..."
    mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" "$CLEARNET_STATE_DIR" "$PROXY_TLS_DIR"
    mkdir -p "$P2POOL_DIR/stats"

    # Enforce permissions. Each data dir is owned by the uid its container runs as: Tor keeps its
    # alpine 'tor' user (100:101); the built images + tari run non-root as APP_UID:APP_GID (#255).
    # mkdir runs first (above) and chown last (#550) — an unprivileged mkdir into an already
    # chown -R'd tree EACCESes for any operator uid != APP_UID.
    sudo chown -R 100:101 "$TOR_DATA_DIR"
    sudo chown -R "$APP_UID":"$APP_GID" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$DASHBOARD_DIR"
    sudo chmod -R 755 "$P2POOL_DIR/stats"
    # World-writable so the dashboard container (its own uid) can drop the clearnet auto-transition
    # marker (#234) while monerod/tari mount it read-only. It holds only non-secret state markers.
    sudo chmod 777 "$CLEARNET_STATE_DIR" 2>/dev/null || chmod 777 "$CLEARNET_STATE_DIR" 2>/dev/null || true
    prepare_control_dirs
    # #261: setup reaches compose through THIS function (stack_up never runs ensure_directories),
    # so a hand-written config with stratum_tls:true at first setup must get its keypair here —
    # otherwise the mount is root-created empty and no fingerprint is ever announced.
    ensure_stratum_tls_cert
}

# Secret leaves in config.json, as jq path arrays. The single host-side source for BOTH control-
# channel maskings (#440): the pre-masked prefill copy (render_masked_config) and the sentinel
# swap at staging (control_preview). Mirrors the dashboard's control_service.SECRET_PATHS — keep
# the two lists in step.
readonly CONTROL_SECRET_PATHS='[
    ["dashboard","auth","password"],
    ["telegram","bot_token"],
    ["workers","api_token"],
    ["monero","node_username"],
    ["monero","node_password"],
    ["monero","view_key"],
    ["tari","view_key"],
    ["p2pool","stratum_password"],
    ["healthchecks","ping_url"],
    ["notifications","ntfy","url"],
    ["notifications","ntfy","token"],
    ["xvb","standby","source"]]'

# #690: bound every host-runner curl so a hostile/MITM'd rig or release response can't stream an
# unbounded body into memory ($( )) or onto disk (-o) inside the --max-time window. --max-filesize
# aborts BOTH before the transfer (when Content-Length is honest) AND mid-stream once received
# bytes cross the cap (verified curl 8.7 → exit 63), so a lying or absent Content-Length is covered
# too — every runner curl already treats a non-zero exit as failure and cleans its partial file.
# Two envelopes: JSON dials + the cosign sig are tiny; the release BUNDLE is a whole-stack tarball.
readonly CURL_CAP_SMALL=1048576 # 1 MiB — GitHub release JSON, rig control responses, cosign sig
# ponytail: 16 MiB, ~128× today's ~126 KB bundle; bump if a real bundle ever approaches it (a
# cap-hit surfaces as _upg_fail's "could not download over Tor", loud but network-flavoured).
readonly CURL_CAP_BUNDLE=16777216 # 16 MiB — the pithead.tar.gz release bundle (code + configs)
# The signed OS image bundle (.raucb) is a whole rootfs — its own envelope, ~3× today's size so a
# grown release still downloads while a runaway stream is still cut off.
readonly CURL_CAP_OS_BUNDLE=3221225472 # 3 GiB — the pithead-os .raucb A/B update bundle

# The latest-release JSON for a GitHub repo, over the stack's own Tor SOCKS like every other
# stack egress. Prints the JSON and returns 0; on failure prints nothing, returns 1, and leaves
# GH_RELEASE_HINT holding the sentence the operator should actually be told.
#
# The reason this is a function and not two `curl -fsS` calls: `-f` collapses every non-2xx into
# one exit code, so a 403 came out as "could not reach GitHub over Tor" and sent the operator to a
# doctor run that correctly reports Tor healthy. GitHub's unauthenticated limit is 60 requests an
# hour PER IP, and a Tor exit is shared with everyone else using it, so a spent budget is a normal
# condition with nothing wrong with this machine — and a different remedy (pick a new exit) from a
# dial that genuinely failed.
# NOT stdout, deliberately: the JSON lands in GH_RELEASE_JSON and the caller runs this as a plain
# command. Assigning it through a command substitution reads naturally and is WRONG — that is a
# subshell, so the hint set here would never reach the caller and every rejection would carry an
# empty message. Two globals, one call, no subshell.
GH_RELEASE_HINT=""
GH_RELEASE_JSON=""
# The SOCKS address this fetch used, published so a caller that goes on to download the release over
# the same Tor path derives it ONCE rather than twice. Folding the lookup into a function deleted the
# caller's own derivation, and `set -u` then killed the runner at its first download — the upgrade
# result sat at "running" for ever with a single dial in the log. One derivation, one truth.
GH_SOCKS=""
gh_release_fetch() { # <owner/repo>; sets GH_RELEASE_JSON on success, GH_RELEASE_HINT on failure; rc 2 = never reached the server at all (#1050)
    local repo="$1" prefix out code retry_hint
    prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
    [ -n "$prefix" ] || prefix="172.28.0"
    GH_SOCKS="${prefix}.25:9050"
    GH_RELEASE_HINT=""
    GH_RELEASE_JSON=""
    # Every caller of this fetch is reachable from the dashboard on an appliance (os-check, the
    # RigForge worker-upgrade) — which has no shell to run 'doctor' from, the product's defining
    # property (#1139). The one caller that DOES want the CLI hint (the DIY one-click upgrade)
    # already refuses before it ever dials on an appliance host, so keying this off is_appliance
    # — a fact about the machine, not the caller — gets every call site right with one seam.
    if is_appliance; then
        retry_hint="Retry from the dashboard in a few minutes."
    else
        retry_hint="Check './pithead doctor' and retry."
    fi
    # -w appends the status on its own line, so a non-2xx keeps its BODY — which is where GitHub
    # says the limit was exceeded. Without -f, curl's own non-zero exit now means only a transport
    # failure, which is exactly the distinction that was missing.
    if ! out=$(curl -sS --max-time 60 --max-filesize "$CURL_CAP_SMALL" -w '\n%{http_code}' \
        --socks5-hostname "$GH_SOCKS" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null); then
        GH_RELEASE_HINT="could not reach the GitHub release API over Tor — nothing was changed. $retry_hint"
        # rc 2, not 1: no HTTP response came back from GitHub, so this is distinct from every
        # failure below, which DID reach the server and keeps the ordinary rc 1. rc 2 does NOT
        # mean no real attempt happened, though — through Tor a circuit-build timeout or an
        # exit-relay refusal returns this exact same curl exit for a dial that genuinely went
        # out on the wire, indistinguishable here from a purely local "Tor daemon down" (#1050).
        # A caller that throttles on this rc must bound the retry rate with a short cooldown,
        # not skip the cooldown outright.
        return 2
    fi
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    # No status line at all means the response is not one we can reason about — and without this the
    # WHOLE BODY becomes "$code" and gets echoed into an operator-facing message, which is both
    # nonsense to read and a way for a remote body to land verbatim in the dashboard.
    case "$code" in
    [0-9][0-9][0-9]) ;;
    *)
        GH_RELEASE_HINT="the GitHub release API answered in a shape this cannot read — nothing was changed. $retry_hint"
        return 1
        ;;
    esac
    case "$code" in
    2*)
        GH_RELEASE_JSON="$out"
        return 0
        ;;
    403 | 429)
        if printf '%s' "$out" | grep -qi 'rate limit'; then
            GH_RELEASE_HINT="the Tor exit this machine is currently using has spent GitHub's shared hourly request budget — nothing is wrong with this box, and 'doctor' will say so. Run './pithead restart tor' to pick a new exit, then retry."
            return 1
        fi
        ;;
    esac
    GH_RELEASE_HINT="the GitHub release API answered HTTP $code — nothing was changed. Retry in a few minutes."
    return 1
}

# Render the pre-masked prefill copy (#440): the live config with every SET secret leaf replaced
# by the {"__secret__":true} sentinel, written atomically to <control-dir>/masked/config.json.
# The dashboard serves the Configuration form from THIS file (mounted read-only) — the raw
# config.json is never mounted into the container, so a full container compromise reads masked
# config, results, and the audit log, nothing more. An EMPTY secret stays empty, so the UI can
# tell "set — leave blank to keep" from "not set". World-readable on purpose (it holds no secret
# values; the container reads it as $APP_UID); best-effort, so a render hiccup degrades to a
# stale prefill, never a failed apply.
render_masked_config() { # <control-dir>
    local mdir="$1/masked" tmp
    mkdir -p "$mdir" 2>/dev/null || true
    tmp="$mdir/.config.json.tmp"
    # Per-worker tokens (#172) live in the variable-length descriptor array, out of reach of the
    # fixed-path walk above — mask each SET .token entry by entry. workers.list[] is current
    # (#506); dashboard.workers[] is the deprecated fallback — mask BOTH shapes unconditionally
    # (validate_worker_endpoints refuses a config that populates both, but empty schema defaults
    # may sit alongside the populated one, #679, and masking an empty array is a no-op).
    if jq --argjson paths "$CONTROL_SECRET_PATHS" '
        reduce $paths[] as $p (.;
            if ((try getpath($p) catch null) // "") == "" then .
            else setpath($p; {"__secret__": true}) end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token // "") == "" then . else .token = {"__secret__": true} end)
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token // "") == "" then . else .token = {"__secret__": true} end)
          else . end
        # notifications.webhooks[] (#848): the whole URL is the bearer secret (query strings carry
        # tokens), and there is no fixed leaf path — mask each set entry, like the worker tokens.
        | if (.notifications | type) == "object" and (.notifications.webhooks | type) == "array"
          then .notifications.webhooks |= map(
              if (. // "") == "" then . else {"__secret__": true} end)
          else . end' "$CONFIG_FILE" >"$tmp" 2>/dev/null; then
        chmod 644 "$tmp" 2>/dev/null || true
        mv "$tmp" "$mdir/config.json" 2>/dev/null ||
            warn "Could not write $mdir/config.json — the dashboard editor prefill may be stale."
    else
        rm -f "$tmp"
        warn "Could not render the masked config copy — the dashboard editor prefill may be stale."
    fi
}

# Control-channel spool layout (#33). requests/ is the ONLY leg the dashboard container may write
# (chowned to its uid); staged/ stays host-only — the container mounts results/, audit/ and the
# pre-masked masked/ copy (#440) read-only and never sees staged/ at all. That rw/ro split is the
# trust boundary: the container can only ask; it cannot forge a result, rewrite the audit log,
# alter a staged intent between preview and commit, or read a secret out of the live config.
prepare_control_dirs() {
    mkdir -p "$CONTROL_DIR/requests" "$CONTROL_DIR/staged" "$CONTROL_DIR/results" "$CONTROL_DIR/audit"
    ensure_owner "$CONTROL_DIR/requests" "$APP_UID" "$APP_GID"
    # Appliance only: seed the OS-update state file the dashboard reads through the results/
    # mount. Its presence is what tells the container "this is an appliance — render the OS
    # update control"; the os-* verbs and pithead-boot keep it current from then on.
    if is_appliance && [ ! -f "$CONTROL_DIR/results/os-update-state.json" ]; then
        os_state_write "$CONTROL_DIR" '{"step":"idle"}'
    fi
    # Re-render the masked prefill copy on every setup/apply/upgrade (#440) — any path that can
    # change config.json runs through here, so the copy can never serve a stale schema for long.
    render_masked_config "$CONTROL_DIR"
    # Caddy access-log dir (#349): root-owned so the capability-stripped caddy container (uid 0,
    # no CAP_DAC_OVERRIDE) can write it; the dashboard (uid 1000) reads it via a ro mount — the
    # Caddyfile's `mode 0644` keeps the files readable.
    mkdir -p "$CADDY_LOG_DIR"
    ensure_owner "$CADDY_LOG_DIR" 0 0
}

# List "*_DATA_DIR=path" lines from .env whose directory is MISSING — the signature of a relocated
# or copied install, or a second checkout, where the stack would silently start a FRESH sync and
# orphan the dashboard SQLite history (#126). Data dirs are stored as absolute paths in .env, so a
# moved install leaves .env naming the old path; Docker then auto-creates an empty dir and re-syncs.
# Empty unless the stack has been deployed (on first setup the dirs legitimately don't exist yet).
missing_data_dirs() {
    [ "$(env_get DEPLOYMENT_COMPLETED 2>/dev/null)" = "true" ] || return 0
    local var dir
    for var in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR TOR_DATA_DIR; do
        dir=$(env_get "$var" 2>/dev/null)
        [ -n "$dir" ] && [ ! -d "$dir" ] && printf '%s=%s\n' "$var" "$dir"
    done
    return 0
}

# Loud warning (on `up`) when .env names data dirs that don't exist — see missing_data_dirs (#126).
warn_missing_data_dirs() {
    local stale line
    stale=$(missing_data_dirs)
    [ -n "$stale" ] || return 0
    warn "Data directories named in .env are MISSING — did you relocate, copy, or run a different checkout of this install?"
    while IFS= read -r line; do warn "  ${line%%=*} → ${line#*=} (not found)"; done <<<"$stale"
    warn "The stack will start a FRESH sync and the dashboard history will be orphaned. To keep your synced chains,"
    warn "move the data to these paths, or set the data_dir(s) in config.json (absolute) and run './pithead apply'."
}

# chown -R "$dir" to $uid:$gid, but ONLY when something in it isn't already owned by $uid. Keeps a
# routine apply sudo-free in steady state, while migrating an existing install in one pass the first
# time the owning uid changes — e.g. the root->non-root container switch (#255). We scan the whole
# tree, not just the top-level dir: an install upgraded from the root-container era has a user-owned
# data dir but root-owned *contents* (the daemons wrote bitmonero.conf, the SQLite DB, etc. as
# root), and those are exactly what the non-root container can no longer overwrite. `find … -quit`
# stops at the first foreign inode, so a clean dir stays a quick metadata scan with no chown/sudo.
ensure_owner() {
    local d="$1" want_u="$2" want_g="$3"
    [ -d "$d" ] || return 0
    [ -z "$(find "$d" ! -uid "$want_u" -print -quit 2>/dev/null)" ] && return 0
    log "Setting ownership of $d to $want_u:$want_g (non-root containers)..."
    sudo chown -R "$want_u":"$want_g" "$d"
}

# Lightweight directory check for `apply`/`upgrade`: create any missing data dir, then ensure each is
# owned by the uid its container runs as. ensure_owner is conditional, so a routine apply stays
# sudo-free once ownership is correct; the first run after the non-root switch migrates the data.
ensure_directories() {
    local d created=()
    for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR" "$PROXY_TLS_DIR"; do
        [ -d "$d" ] || { mkdir -p "$d" && created+=("$d"); }
    done
    mkdir -p "$P2POOL_DIR/stats"
    ensure_owner "$TOR_DATA_DIR" 100 101
    ensure_owner "$MONERO_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$TARI_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$P2POOL_DIR" "$APP_UID" "$APP_GID"
    ensure_owner "$DASHBOARD_DIR" "$APP_UID" "$APP_GID"
    prepare_control_dirs    # #33: spool dirs exist + requests/ writable by the dashboard uid
    ensure_stratum_tls_cert # #261: keypair exists before compose mounts $PROXY_TLS_DIR
    [ "${#created[@]}" -gt 0 ] && sudo chmod -R 755 "$P2POOL_DIR/stats"
    return 0
}

# Generate the stratum TLS keypair once (#261). Self-signed and long-lived (3650 days): rigs
# authenticate the server by PINNING the certificate's SHA-256 fingerprint (xmrig does no CA
# validation for stratum), so CA trust and expiry play no part in the model — regenerating the
# cert IS the rotation, and every rig re-pins. The key is created under umask 077 and handed to
# the proxy uid read-only; the dir is mounted :ro into the container. No-op while the knob is
# off, and idempotent while the keypair exists — the fingerprint stays stable across applies.
ensure_stratum_tls_cert() {
    [ "${STRATUM_TLS:-false}" = "true" ] || return 0
    [ -f "$PROXY_TLS_DIR/cert.pem" ] && [ -f "$PROXY_TLS_DIR/key.pem" ] && return 0
    command -v openssl >/dev/null 2>&1 ||
        error "p2pool.stratum_tls is true but openssl is not installed — it is needed once, to generate the stratum certificate."
    log "Generating the stratum TLS certificate — self-signed; rigs pin its fingerprint..."
    (
        umask 077
        openssl req -x509 -newkey rsa:2048 -keyout "$PROXY_TLS_DIR/key.pem" \
            -out "$PROXY_TLS_DIR/cert.pem" -days 3650 -nodes -subj "/CN=pithead-stratum" 2>/dev/null
    ) || error "OpenSSL could not generate the stratum TLS certificate in $PROXY_TLS_DIR."
    # The proxy runs as the unprivileged app uid (#255) and must read the key through the :ro
    # mount; the umask above already keeps both files owner-only until this narrows them.
    ensure_owner "$PROXY_TLS_DIR" "$APP_UID" "$APP_GID"
    chmod 600 "$PROXY_TLS_DIR/key.pem" 2>/dev/null || sudo chmod 600 "$PROXY_TLS_DIR/key.pem"
    chmod 644 "$PROXY_TLS_DIR/cert.pem" 2>/dev/null || sudo chmod 644 "$PROXY_TLS_DIR/cert.pem"
    announce_stratum_tls
}

# Surface the stratum TLS state + the fingerprint rigs must pin (#261) — the companion to
# announce_stratum_auth: the fingerprint is what RigForge setup asks for (pools[].tls-fingerprint).
# Public data (it's the cert's own digest), so printing it is safe anywhere.
announce_stratum_tls() {
    # Callable with or without a prior parse (status vs apply): fall back to the rendered .env.
    local enabled="${STRATUM_TLS:-}" dir="${PROXY_TLS_DIR:-}"
    [ -n "$enabled" ] || enabled=$(env_get PROXY_STRATUM_TLS)
    [ -n "$dir" ] || dir=$(env_get PROXY_TLS_DIR)
    [ "$enabled" = "true" ] && [ -n "$dir" ] && [ -f "$dir/cert.pem" ] || return 0
    command -v openssl >/dev/null 2>&1 || return 0
    local fp
    fp=$(openssl x509 -in "$dir/cert.pem" -noout -fingerprint -sha256 2>/dev/null |
        cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')
    [ -n "$fp" ] || return 0
    log "Stratum TLS is ON: rigs may connect with TLS on the same stratum port (cleartext still accepted). Pin this fingerprint on each rig (pools[].tls-fingerprint): $fp"
}

# One-time dashboard-data migration (#455): the dashboard DB used to default INSIDE the install
# dir (./data/dashboard) — the one data dir that moved with the code on every versioned deploy.
# When the resolved default now lives under the shared data root, move the old in-install data
# there once. Move-then-verify and idempotent: a no-op when the old default holds nothing (fresh
# install, or already migrated), a warning-only when the operator pinned dashboard.data_dir, and
# a hard stop when BOTH locations hold data — never guess which DB is live. Runs after the config
# is committed (apply) / right before the containers are recreated (upgrade), so a failed move is
# retried on the next run and the recreated dashboard always mounts the migrated directory.
migrate_dashboard_data() {
    local old="$PWD/data/dashboard" new="${DASHBOARD_DIR:-}"
    [ -n "$new" ] && [ "$old" != "$new" ] || return 0   # classic layout — nothing to move
    [ -n "$(ls -A "$old" 2>/dev/null)" ] || return 0    # old default empty/absent — nothing to move
    if [ "${DASHBOARD_DIR_IS_DEFAULT:-1}" -eq 0 ]; then # operator-pinned path: their data, their call
        warn "Dashboard data found at the old default $old, but dashboard.data_dir is set explicitly ($new) — leaving both alone. Move or remove $old yourself."
        return 0
    fi
    if [ -n "$(ls -A "$new" 2>/dev/null)" ]; then
        error "Dashboard data exists at BOTH the old default ($old) and the new one ($new) — refusing to guess which is live. Keep one, delete the other, then re-run."
    fi
    log "Moving the dashboard data to the shared data root: $old → $new..."
    # The dashboard writes its SQLite DB continuously — stop it for the move; the compose up that
    # follows every apply/upgrade brings it back on the new mount. Best-effort: already stopped is fine.
    docker compose stop dashboard >/dev/null 2>&1 || true
    local had_db=0
    [ -f "$old/mining_data.db" ] && had_db=1
    rmdir "$new" 2>/dev/null || true # drop a pre-created EMPTY target so mv renames instead of nesting
    mkdir -p "$(dirname "$new")"
    mv "$old" "$new" || error "Could not move $old to $new — the data is still at $old, nothing was lost. Move it yourself (or set dashboard.data_dir), then re-run."
    if [ "$had_db" -eq 1 ] && [ ! -f "$new/mining_data.db" ]; then
        error "The dashboard DB is missing after the move — check $new and $old before starting the stack."
    fi
    log "Dashboard data migrated to $new."
}

# One authoritative pointer to the live install (#455): when this install lives in a versioned
# deploy dir (pithead-vX.Y.Z), keep a `current` symlink beside it pointing here — updated with
# `ln -sfn` on every successful setup/upgrade, so the live version dir is discoverable without
# docker inspect (the dashboard one-click upgrade, #59, runs `upgrade` and gets this for free).
# Relative target, so the whole tree can move. Any other layout (source checkout, plain
# `pithead/` extract) is left alone, and nothing here ever fails the surrounding command.
update_current_symlink() {
    local name parent
    name=$(basename "$PWD")
    [[ "$name" =~ ^pithead-v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    parent=$(dirname "$PWD")
    if [ -e "$parent/current" ] && [ ! -L "$parent/current" ]; then
        warn "$parent/current exists but is not a symlink — leaving it alone. Point it at $name yourself."
        return 0
    fi
    if ln -sfn "$name" "$parent/current" 2>/dev/null; then
        log "Updated $parent/current -> $name."
    else
        warn "Could not update $parent/current -> $name (permissions?) — the stack is fine; fix the symlink by hand."
    fi
    return 0
}

# Decide the hostname the dashboard is reached at: an explicit dashboard.host wins; otherwise
# "auto"/unset means this machine's hostname, re-derived each run (so reverting to "auto" takes
# effect). Interactive setup prompts, defaulting to any previously-set value then the hostname.
resolve_dashboard_host() {
    local allow_prompt="${1:-}"
    # An interactive ask with no terminal is an EOF that silently picks the bare hostname —
    # exactly what happened on the appliance's headless pre-seed boot, whose dashboard then
    # served a name no LAN client resolves. No tty → the non-interactive rules decide.
    [ "$allow_prompt" == "interactive" ] && ! [ -t 0 ] && allow_prompt=""
    if [ -n "${DASHBOARD_HOST:-}" ]; then
        HOST_IP="$DASHBOARD_HOST"
        log "Using dashboard hostname '$HOST_IP' from $CONFIG_FILE."
    elif [ "$allow_prompt" == "interactive" ]; then
        local default_host
        default_host="${PRESERVED_HOST_IP:-$(hostname)}"
        echo "The stack needs to know what hostname you will use to access the dashboard in your browser."
        read -r -p "Enter Hostname [$default_host]: " input_host || true
        HOST_IP="${input_host:-$default_host}"
    else
        # "auto"/unset on a non-interactive run (e.g. apply): always the machine hostname, so
        # setting dashboard.host back to "auto" reverts HOST_IP instead of keeping a stale value.
        # On the appliance the browsable name is what avahi publishes — <hostname>.local — not the
        # bare hostname, which no client on the LAN can resolve.
        if is_appliance; then
            HOST_IP="$(hostname).local"
        else
            HOST_IP=$(hostname)
        fi
    fi
}

# Poll the running tor container for one hidden service's hostname file and echo the address.
# $1 = the HiddenServiceDir name under /var/lib/tor. Polls instead of sleeping a fixed 15s — Tor
# can take more or less than that to publish, especially on first run. Returns 1 on timeout so the
# caller decides whether a missing address is fatal.
wait_for_onion() {
    local svc="$1" elapsed=0 timeout=60
    until docker exec tor test -f "/var/lib/tor/$svc/hostname"; do
        if [ "$elapsed" -ge "$timeout" ]; then
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    docker exec tor cat "/var/lib/tor/$svc/hostname"
}

provision_tor() {
    log "Initializing Tor service to generate onion addresses..."
    # Client-auth keys must be in place before tor starts, since it reads authorized_clients then (#343).
    provision_onion_client_auth
    docker compose up --pull "$(resolve_pull_policy)" -d tor
    log "Waiting for Tor hidden services to be generated..."
    P2POOL_ONION=$(wait_for_onion p2pool) ||
        error "Timed out waiting for the P2Pool Tor hidden-service hostname."
    # A node's inbound onion is only published while that node is local (build/tor/entrypoint.sh
    # gates each block on its compose profile), so in remote mode there is nothing to wait for and
    # the address stays a placeholder — provision_node_onions mints it if the node ever goes local.
    if [ "$MONERO_MODE" == "local" ]; then
        MONERO_ONION=$(wait_for_onion monero) ||
            error "Timed out waiting for the Monero Tor hidden-service hostname."
    fi
    if [ "$TARI_MODE" == "local" ]; then
        TARI_ONION=$(wait_for_onion tari) ||
            error "Timed out waiting for the Tari Tor hidden-service hostname."
    fi
    provision_dashboard_onion # #343: reads the dashboard onion too, but only when it's enabled
}

# Mint and capture a node's inbound onion when that node has just switched remote → local (#103).
# Its hidden service exists only while the node is local, so a stack first set up in remote mode
# has no address for it yet. Recreating tor against the freshly committed .env publishes the
# service; the address must then be in .env BEFORE the node container starts, because monerod
# templates `anonymous-inbound` from it and the Tari config takes the onion at render time.
# No-op — and no docker call — whenever both nodes' addresses are already in hand.
provision_node_onions() {
    local want_monero=false want_tari=false
    if [ "${MONERO_MODE:-}" == "local" ] && onion_missing "${MONERO_ONION:-}"; then want_monero=true; fi
    if [ "${TARI_MODE:-}" == "local" ] && onion_missing "${TARI_ONION:-}"; then want_tari=true; fi
    [ "$want_monero" == "true" ] || [ "$want_tari" == "true" ] || return 0

    log "Publishing the Tor hidden service for the node that just became local..."
    docker compose up -d tor
    if [ "$want_monero" == "true" ]; then
        MONERO_ONION=$(wait_for_onion monero) ||
            error "Timed out waiting for the Monero Tor hidden-service hostname."
    fi
    if [ "$want_tari" == "true" ]; then
        TARI_ONION=$(wait_for_onion tari) ||
            error "Timed out waiting for the Tari Tor hidden-service hostname."
    fi
    render_env # commit the new address before the node container is (re)created against it
}

# An onion address that was never provisioned: empty, or the placeholder render_env writes until
# the real hostname is captured.
onion_missing() {
    [ -z "${1:-}" ] || [ "${1:-}" == "placeholder" ]
}

# Prepare Tor v3 client authorization for the dashboard onion (#343). Generates the client keypair
# once (preserved across applies) and writes the PUBLIC key into the hidden service's
# authorized_clients/ dir, so the onion is unreachable without the matching private key. MUST run
# BEFORE the tor container (re)starts — tor reads authorized_clients at startup. No-op unless the
# onion is on. When the onion is on but client-auth is off, it clears any prior authorized_clients so
# the onion falls back to password-only.
provision_onion_client_auth() {
    [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] || return 0
    local hs_dir="$TOR_DATA_DIR/dashboard"
    # TOR_DATA_DIR is owned by the tor container's own uid (100 in the Alpine tor image, NOT the
    # first-party APP_UID). If we can't write it directly, elevate — the same sudo ensure_owner uses.
    # (Tests point TOR_DATA_DIR at a user-owned temp dir, so `run` stays empty and no sudo is used.)
    local run=""
    [ -w "$TOR_DATA_DIR" ] || run="sudo"
    if [ "${DASHBOARD_ONION_CLIENT_AUTH:-false}" != "true" ]; then
        if $run test -d "$hs_dir/authorized_clients"; then
            log "Disabling Tor onion client-auth for the dashboard — the onion becomes password-only."
            $run rm -rf "$hs_dir/authorized_clients"
        fi
        return 0
    fi
    if onion_missing "$DASHBOARD_ONION_CLIENT_PUBKEY"; then
        local kp
        kp=$(generate_onion_client_keypair) ||
            error "Could not generate the Tor onion client-auth keypair (need openssl built with x25519, plus od + awk)."
        DASHBOARD_ONION_CLIENT_PUBKEY="${kp%% *}"
        DASHBOARD_ONION_CLIENT_PRIVKEY="${kp##* }"
        log "Generated a Tor onion client-auth key for the dashboard."
    fi
    $run mkdir -p "$hs_dir/authorized_clients"
    printf 'descriptor:x25519:%s\n' "$DASHBOARD_ONION_CLIENT_PUBKEY" | $run tee "$hs_dir/authorized_clients/dashboard.auth" >/dev/null
    # Tor refuses a HiddenServiceDir that is group/other-accessible; keep it 0700/0600 and owned by
    # whatever uid already owns the tor data dir, so tor can read authorized_clients.
    $run chmod 700 "$hs_dir" "$hs_dir/authorized_clients"
    $run chmod 600 "$hs_dir/authorized_clients/dashboard.auth"
    local owner
    # GNU stat first, BSD fallback (macOS dev checkouts). With neither, skip the chown — and do it
    # with `if`, not `[ ] &&`, so an empty owner doesn't become the function's (nonzero) return
    # value and abort the whole apply under set -e after .env is already committed.
    owner=$($run stat -c '%u:%g' "$TOR_DATA_DIR" 2>/dev/null || $run stat -f '%u:%g' "$TOR_DATA_DIR" 2>/dev/null) || owner=""
    if [ -n "$owner" ]; then $run chown -R "$owner" "$hs_dir"; fi
}

# Read the dashboard onion hostname from the running tor container into DASHBOARD_ONION (#343).
# No-op unless the onion is enabled. Its HiddenServiceDir is rendered conditionally
# (build/tor/entrypoint.sh), so poll for the hostname — Tor publishes it a few seconds after
# (re)start. Used by both first-time setup (provision_tor) and a later `apply` that turns it on.
provision_dashboard_onion() {
    [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] || return 0
    log "Waiting for the dashboard Tor hidden service..."
    local elapsed=0 timeout=60
    until docker exec tor test -f /var/lib/tor/dashboard/hostname; do
        if [ "$elapsed" -ge "$timeout" ]; then
            # Non-fatal: the onion still serves; the address just isn't captured for `status` yet.
            warn "Timed out after ${timeout}s waiting for the dashboard Tor hidden-service hostname; run './pithead status' later to see the address."
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    DASHBOARD_ONION=$(docker exec tor cat /var/lib/tor/dashboard/hostname)
}

# `onion-client-key` (#343): print the operator's Tor client-auth line for the dashboard onion. Its
# own command — deliberately NOT part of `status`, which is a shareable report — because it prints
# the client PRIVATE key. The operator drops this line into their Tor client's ClientOnionAuthDir.
onion_client_key() {
    require_env
    [ "$(env_get DASHBOARD_ONION_ENABLED)" == "true" ] ||
        error "The dashboard onion is not enabled (set dashboard.onion.enabled: true, then '$0 apply')."
    [ "$(env_get DASHBOARD_ONION_CLIENT_AUTH)" == "true" ] ||
        error "Client authorization is off for the dashboard onion (dashboard.onion.client_auth: false) — it is password-only, so there is no client key."
    local onion privkey
    onion=$(env_get DASHBOARD_ONION_ADDRESS)
    privkey=$(env_get DASHBOARD_ONION_CLIENT_PRIVKEY)
    { [ -n "$onion" ] && [ "$onion" != "placeholder" ] && [ -n "$privkey" ] && [ "$privkey" != "placeholder" ]; } ||
        error "The dashboard onion isn't fully provisioned yet — run '$0 apply' first."
    cat <<EOF
Tor onion client-auth for the dashboard — KEEP THIS PRIVATE, it is a secret key.
Dashboard onion address:  http://$onion

Pick whichever Tor client you use to reach it:

• Tor Browser (easiest): open  http://$onion  (Tor Browser upgrades it to https;
  accept the one-time self-signed-cert prompt, same as the LAN dashboard). It
  prompts for the onion's private key. Paste JUST this key:

    $privkey

• System Tor / Orbot (persistent): put this one line in a file (e.g.
  dashboard.auth_private) inside the directory set by ClientOnionAuthDir in your
  torrc (create it mode 0700), then reload Tor:

    ${onion%.onion}:descriptor:x25519:$privkey
EOF
}

# `rotate-dashboard-onion` (#343): mint a fresh .onion address and a fresh client-auth key. A leaked
# address or client key is otherwise permanent. Wipes only the dashboard hidden-service dir (the
# mining onions are untouched), then re-provisions and restarts caddy.
rotate_dashboard_onion() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for rotate-dashboard-onion: $arg. Run '$0 help'." ;;
        esac
    done
    require_env
    parse_and_validate_config
    load_preserved_state
    [ "$DASHBOARD_ONION_ENABLED" == "true" ] ||
        error "The dashboard onion is not enabled — nothing to rotate."
    warn "This regenerates the dashboard's .onion ADDRESS and its client-auth key. The old address and any client keys you handed out stop working immediately."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Rotate the dashboard onion now? (y/N): " CONFIRM || true
        [[ "$CONFIRM" =~ ^[Yy] ]] || {
            log "Rotation cancelled."
            return 0
        }
    fi
    local hs_dir="$TOR_DATA_DIR/dashboard"
    [ -n "$TOR_DATA_DIR" ] && [ "${hs_dir##*/}" == "dashboard" ] ||
        error "Refusing to wipe an unexpected path (\"$hs_dir\")."
    log "Stopping tor and wiping the dashboard hidden service..."
    docker compose stop tor >/dev/null 2>&1 || true
    sudo rm -rf "$hs_dir" 2>/dev/null || rm -rf "$hs_dir" 2>/dev/null || true
    # Force fresh keys + address on the next provision.
    DASHBOARD_ONION="placeholder"
    DASHBOARD_ONION_CLIENT_PUBKEY="placeholder"
    DASHBOARD_ONION_CLIENT_PRIVKEY="placeholder"
    provision_tor          # rewrites authorized_clients (fresh key), starts tor, reads the new address
    resolve_dashboard_host # #356: sets HOST_IP for render_env — rotate skipped it, so render_env died
    # on the unbound HOST_IP under `set -u` (setup/apply/upgrade all resolve the host before rendering).
    # #356: render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and load_preserved_state
    # doesn't carry it, so preserve the current value — otherwise rotate silently reset the flag to false
    # and the next apply/upgrade errored "Stack is not fully provisioned. Run setup first."
    DEPLOYMENT_COMPLETED=$(env_get DEPLOYMENT_COMPLETED)
    render_env         # persist the new address + keys
    generate_caddyfile # #546: without this the Caddyfile still points at the retired address's vhost
    docker compose restart caddy >/dev/null 2>&1 || true
    log "Dashboard onion rotated."
    if [ "$DASHBOARD_ONION_CLIENT_AUTH" == "true" ]; then
        onion_client_key
    else
        log "New dashboard onion: http://$(env_get DASHBOARD_ONION_ADDRESS)"
    fi
}

# `rotate-secrets` (#378): regenerate the stack's internal credentials in one command. After a
# suspected leak (a backup that left the box, a `.env` pasted into a bug report) the only
# alternative is hand-editing files and knowing which containers to recreate. Rotates the local
# Monero RPC password (skipped in remote mode — that credential belongs to the remote node), the
# stratum access-password when p2pool.stratum_password is "auto" (a literal lives in config.json;
# empty means auth is off), and PROXY_AUTH_TOKEN (always). The dashboard onion keys/address have
# their own command (rotate-dashboard-onion) and are not touched. The old values stay recoverable
# in timestamped owner-only copies of config.json and .env taken before anything changes.
rotate_secrets() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        *) error "Unknown option for rotate-secrets: $arg. Run '$0 help'." ;;
        esac
    done
    require_deployed
    parse_and_validate_config
    load_preserved_state

    # Compute the "what will rotate" preview from the PARSED config, not by grepping .env — the
    # stratum mode in config.json (auto vs literal vs empty) decides the behavior, not the rendered value.
    local stratum_mode rotate_stratum=0
    stratum_mode=$(jq -r '.p2pool.stratum_password // ""' "$CONFIG_FILE")

    log "This rotates the stack's internal credentials:"
    if [ "$MONERO_MODE" == "local" ]; then
        log "  • Monero node RPC password — internal to the stack; no follow-up needed."
    else
        log "  • Monero RPC password: skipped — monero.mode is \"remote\", so the credential belongs to the remote node, not this stack."
    fi
    if [ "$stratum_mode" == "auto" ]; then
        warn "  • Stratum access-password — EVERY RIG must update its stratum 'pass' to the new value or it is rejected."
    elif [ -n "$stratum_mode" ]; then
        log "  • Stratum access-password: skipped — p2pool.stratum_password is set explicitly in config.json; change it there and run '$0 apply'."
    fi
    log "  • xmrig-proxy control-API token — internal to the stack; no follow-up needed."
    log "The containers that consume them are recreated (brief restart; chain data and dashboard history are untouched)."
    if [ "$assume_yes" -eq 0 ]; then
        read -r -p "Rotate these secrets now? (y/N): " CONFIRM || true
        [[ "$CONFIRM" =~ ^[Yy] ]] || {
            log "Rotation cancelled."
            return 0
        }
    fi

    # Keep the OLD values recoverable before anything changes: timestamped owner-only copies of the
    # two files that carry them. Refuse to rotate at all if the safety copies can't be written.
    local stamp
    stamp=$(date +%Y%m%d-%H%M%S)
    (
        umask 077
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-${stamp}" &&
            cp "$ENV_FILE" "${ENV_FILE}.bak-${stamp}"
    ) || error "Could not write the pre-rotation safety copies — nothing was rotated."
    log "Pre-rotation copies saved (${CONFIG_FILE}.bak-${stamp}, ${ENV_FILE}.bak-${stamp}) — they hold the OLD secrets; delete them once the stack is confirmed healthy."

    # Regenerate, overriding what parse_and_validate_config / load_preserved_state just preserved.
    # Same generators as the originals, so every consumer's validation keeps holding.
    if [ "$MONERO_MODE" == "local" ]; then
        MONERO_PASS=$(generate_node_password)
        persist_node_credentials "$MONERO_USER" "$MONERO_PASS" # atomic write-back to config.json
    fi
    if [ "$stratum_mode" == "auto" ]; then
        STRATUM_PASSWORD=$(openssl rand -hex 12)
        rotate_stratum=1
    fi
    PROXY_AUTH_TOKEN=$(openssl rand -hex 12)

    resolve_dashboard_host # #356: sets HOST_IP for render_env, which dies unbound without it
    # #356: render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and
    # load_preserved_state doesn't carry it — preserve it or the next apply errors "run setup".
    DEPLOYMENT_COMPLETED=$(env_get DEPLOYMENT_COMPLETED)
    render_env
    inject_service_configs # keep the generated service configs current before the recreate
    # Recreate marker (#125): .env is committed now, so if the recreate below fails, a plain
    # `apply` would diff no changes and no-op — the marker makes it retry the recreate instead.
    local apply_marker="${ENV_FILE}.apply-incomplete"
    : >"$apply_marker"
    log "Recreating the containers that consume the rotated secrets..."
    # `up` recreates exactly the services whose env/args changed (monerod, p2pool, xmrig-proxy,
    # dashboard). Never `compose restart` here: restart reuses the OLD container args, so p2pool
    # would keep dialing monerod with the retired --rpc-login.
    if ! compose_up_checked -d; then
        warn "Secrets were rotated in config.json/.env but the containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause above, then run '$0 apply' to retry the recreate — or restore the pre-rotation copies (${CONFIG_FILE}.bak-${stamp}, ${ENV_FILE}.bak-${stamp}) and run '$0 apply'."
        exit 1 # leave $apply_marker so the retry re-attempts the recreate
    fi
    rm -f "$apply_marker"

    log "Secrets rotated. The old values are invalid; only the safety copies above still hold them."
    if [ "$rotate_stratum" -eq 1 ]; then
        announce_stratum_auth
        warn "The stratum access-password CHANGED — every rig is rejected until its stratum 'pass' is updated to the value above."
    fi
}

# Single writer for the env file. Derives every value from the parsed config plus the preserved
# secrets/onions/host, so it is safe to call repeatedly (bootstrap, finalize, or apply).
# $1 = target file (defaults to $ENV_FILE); apply renders to a temp file first to diff it.
render_env() {
    local target="${1:-$ENV_FILE}"
    log "Rendering environment configuration ($target)..."

    # Mode → host / ports / compose profile
    local mono_host rpc_port zmq_port profiles
    if [ "$MONERO_MODE" == "local" ]; then
        mono_host="${NETWORK_PREFIX}.26"
        rpc_port="18081"
        zmq_port="18083"
        profiles="local_node"
    else
        # Reuse the parse-time validated globals — the validated value IS the rendered value.
        mono_host="$MONERO_REMOTE_HOST"
        rpc_port="$MONERO_REMOTE_RPC_PORT"
        zmq_port="$MONERO_REMOTE_ZMQ_PORT"
        profiles="" # Empty profile disables local monerod
    fi

    # Tari mode → gRPC address / compose profile (#103), mirroring Monero above. local -> the
    # bundled Tari node at its fixed bridge IP, plus the local_tari profile so compose starts it.
    # remote -> a third-party (or fleet-shared) node's host:port; local_tari stays out of $profiles
    # so the bundled node never starts (parse_and_validate_config already required
    # tari.remote.host to be set).
    local tari_grpc_addr
    if [ "$TARI_MODE" == "local" ]; then
        tari_grpc_addr="${NETWORK_PREFIX}.27:18142"
        profiles="${profiles:+$profiles,}local_tari"
    else
        # Reuse the parse-time validated globals (see Monero above) — single source of truth.
        tari_grpc_addr="${TARI_REMOTE_HOST}:${TARI_REMOTE_GRPC_PORT}"
    fi

    # Tari gRPC LAN exposure (#760), mirroring monerod's rpc_lan_access above. Default
    # localhost-only: in-stack consumers reach the node over the internal Docker network
    # regardless, so the published port only serves other machines — the serving side of the
    # remote mode (#103). The gRPC is plaintext and unauthenticated: trusted LAN only (#754
    # trust model). N/A in remote mode (the tari service is profile-gated off; nothing binds).
    local tari_grpc_bind tari_grpc_lan
    tari_grpc_lan=$(jq -r '.tari.grpc_lan_access // false' "$CONFIG_FILE")
    if [ "$tari_grpc_lan" == "true" ]; then tari_grpc_bind="0.0.0.0"; else tari_grpc_bind="127.0.0.1"; fi

    # On-chain payout confirmation (#381): the view-only wallet-rpc service only starts when its
    # compose profile is active, which is only when a view key is set on a local node. Off = no
    # container, dashboard unchanged. PAYOUT_CONFIRM_ENABLED is set by parse_and_validate_config
    # (which also refuses a view key on a remote node and validates the key/height).
    if [ "${PAYOUT_CONFIRM_ENABLED:-false}" == "true" ]; then
        profiles="${profiles:+$profiles,}payout_confirm"
    fi

    # Tari on-chain payout confirmation (#462): the view-only tari-wallet service only starts when
    # its own compose profile is active, which is only when a tari view key is set on the local Tari
    # node. Separate from monero's payout_confirm so the two features toggle independently.
    # TARI_PAYOUT_CONFIRM_ENABLED is set by parse_and_validate_config (which also refuses a view key
    # on a remote Tari node and validates the key/spend key/birthday).
    if [ "${TARI_PAYOUT_CONFIRM_ENABLED:-false}" == "true" ]; then
        profiles="${profiles:+$profiles,}tari_payout_confirm"
    fi

    # Pruning is on unless config explicitly sets monero.prune:false (config_bool honours that
    # explicit false rather than coercing it back to the default — see #294).
    local prune
    prune=$(monero_prune_flag)

    # Optional clearnet initial sync (#183). DEFAULT OFF (privacy-first). When on for a daemon, its
    # initial blockchain download runs over CLEARNET (fast) instead of Tor — briefly exposing this
    # host's IP to that P2P network. Per-component, since Monero and Tari sync independently.
    # config_bool honours an explicit false; normalize_bool then maps the result to true/false.
    # Monero keeps tx-proxy=tor the whole time. Flip back to false + `apply` once synced.
    local monero_clearnet tari_clearnet
    monero_clearnet=$(normalize_bool "$(config_bool '.monero.clearnet_initial_sync' false)")
    tari_clearnet=$(normalize_bool "$(config_bool '.tari.clearnet_initial_sync' false)")

    # Block-verification threads — hardware-dependent, so derive from THIS host's core count
    # rather than hardcoding (more cores = faster initial-sync verification). Reserve 2 cores
    # and cap at 8 (diminishing returns past that). Override with monero.prep_blocks_threads.
    local prep_threads cores
    prep_threads=$(jq -r '.monero.prep_blocks_threads // "auto"' "$CONFIG_FILE")
    if ! [[ "$prep_threads" =~ ^[0-9]+$ ]]; then
        cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
        prep_threads=$((cores - 2))
        [ "$prep_threads" -lt 4 ] && prep_threads=4
        [ "$prep_threads" -gt 8 ] && prep_threads=8
    fi

    # Outbound peer target (#595): over Tor, each outbound peer is roughly one long-lived circuit,
    # so out-peers is the biggest steady-state knob on Tor's CPU (circuit maintenance + rebuild).
    # The default STAYS 48 — more peers means more aggregate bandwidth during a Tor initial sync,
    # and a new operator's first run is exactly that. Once synced, 32 (P2Pool's clearnet
    # recommendation) cuts monerod's circuit count by a third with no mining impact.
    local out_peers
    out_peers=$(jq -r '.monero.out_peers // 48' "$CONFIG_FILE")
    if ! [[ "$out_peers" =~ ^[0-9]+$ ]] || [ "$out_peers" -lt 8 ] || [ "$out_peers" -gt 1024 ]; then
        error "monero.out_peers must be an integer between 8 and 1024 (got \"$out_peers\")."
    fi

    # monerod RPC LAN exposure. Default localhost-only: p2pool reaches monerod over the internal
    # Docker network regardless, so the published port is only for external wallets.
    local rpc_bind rpc_lan
    rpc_lan=$(jq -r '.monero.rpc_lan_access // false' "$CONFIG_FILE")
    if [ "$rpc_lan" == "true" ]; then rpc_bind="0.0.0.0"; else rpc_bind="127.0.0.1"; fi

    # monerod ZMQ LAN exposure (#760). A separate key from rpc_lan_access on purpose: that key's
    # documented use is wallets (RPC only), and widening it to also open ZMQ would change the
    # exposure of existing deployments. A node SERVING remote stacks (#103's other half) needs
    # both: rpc_lan_access for the RPC, zmq_lan_access for the block-notification feed p2pool
    # requires. ZMQ pub has no auth — trusted LAN only.
    local zmq_bind zmq_lan
    zmq_lan=$(jq -r '.monero.zmq_lan_access // false' "$CONFIG_FILE")
    if [ "$zmq_lan" == "true" ]; then zmq_bind="0.0.0.0"; else zmq_bind="127.0.0.1"; fi

    # P2Pool pool type → flags + p2p port
    local pool_type p2pool_flags p2pool_port
    pool_type=$(jq -r '.p2pool.pool // "mini"' "$CONFIG_FILE")
    p2pool_flags=""
    p2pool_port="37889"
    if [ "$pool_type" == "mini" ]; then
        p2pool_flags="--mini"
        p2pool_port="37888"
    elif [ "$pool_type" == "nano" ]; then
        p2pool_flags="--nano"
        p2pool_port="37890"
    fi

    # Route outbound sidechain P2P through Tor by default (#165); p2pool.clearnet opts out for yield.
    # See p2pool_outbound_flags + docs/privacy.md. Uses the configured subnet so a custom NETWORK_PREFIX
    # (#180) still points at the Tor container (.25).
    local p2pool_socks
    p2pool_socks=$(p2pool_outbound_flags "$(jq -r '.p2pool.clearnet // false' "$CONFIG_FILE")" "$NETWORK_PREFIX")
    [ -n "$p2pool_socks" ] && p2pool_flags="${p2pool_flags:+$p2pool_flags }$p2pool_socks"

    # XvB config (accepts legacy xmrig_proxy.* keys)
    local xvb_enabled xvb_url xvb_donor xvb_donation_level xvb_tor
    xvb_enabled=$(jq -r 'if .xvb.enabled != null then .xvb.enabled elif .xmrig_proxy.enabled != null then .xmrig_proxy.enabled else "true" end' "$CONFIG_FILE")
    # Route XvB donation mining through Tor by default (#166); xvb.tor:false opts out for max yield.
    # config_bool so xvb.tor=false (route XvB over clearnet) is honoured rather than coerced to Tor (#294).
    xvb_tor=$(normalize_bool "$(config_bool '.xvb.tor' true)")
    xvb_url=$(jq -r '.xvb.url // .xmrig_proxy.url // empty' "$CONFIG_FILE")
    [ -z "$xvb_url" ] && xvb_url="na.xmrvsbeast.com:4247"
    xvb_donor=$(jq -r '.xvb.donor_id // .xmrig_proxy.donor_id // empty' "$CONFIG_FILE")
    case "$xvb_donor" in
    "" | auto | DYNAMIC_ID) xvb_donor="${MONERO_WALLET:0:8}" ;;
    esac
    # Donation tier target: auto (default) / donor|vip|whale|mega
    xvb_donation_level=$(jq -r '.xvb.donation_level // empty' "$CONFIG_FILE")
    [ -z "$xvb_donation_level" ] && xvb_donation_level="auto"

    # How much Tari blocks the stack (#31/#35/#51/#897). monerod is required and not
    # configurable (a monerod outage always rejects workers; the miner always waits for
    # monerod's sync). A Tari outage never rejects workers, regardless of this flag — p2pool
    # keeps mining Monero through it. tari_required (default true) still decides the rest:
    # the miner waits for Tari's sync too, and a Tari-only sync drives full Sync Mode. false =
    # non-blocking Tari for those two.
    local tari_required
    tari_required=$(jq -r 'if .dashboard.tari_required != null then .dashboard.tari_required | tostring else "true" end' "$CONFIG_FILE")

    # Opt-in fail-closed miner hold on an unrecoverable dashboard health failure (#490), default
    # false. The dashboard is an observability layer, not the mining datapath, so the default is
    # alert-only (loud Telegram/Healthchecks alert + badge; mining continues). true reuses the #35
    # sync-gate's own hold to stop p2pool+xmrig-proxy until a DB-recovery failure or a
    # crash-looping dashboard container clears — see dashboard .../service/data_service.py
    # DataService._apply_fail_closed_gate for the exact "unrecoverable" set.
    local fail_closed
    fail_closed=$(normalize_bool "$(config_bool '.dashboard.fail_closed' false)")

    # Healthchecks.io dead-man's switch (#79). Optional external liveness monitor: a ping URL is the
    # on/off switch (blank = off), and the ping always rides Tor. The URL is a capability secret, so
    # it lives in the owner-only .env (chmod 600 below), never a world-readable file. docs/monitoring.md.
    local hc_ping_url
    hc_ping_url=$(jq -r '.healthchecks.ping_url // empty' "$CONFIG_FILE")

    # XvB warm-standby source (#249). On a backup stack this is the PRIMARY dashboard's read-only
    # /api/xvb-standby URL; the backup pulls it so a failover resumes the donation split warm.
    # Blank (default) = off. A capability URL (it can carry the primary's dashboard basic-auth as
    # userinfo), so like the ping URL above it lives in the owner-only .env, never a world-readable
    # file. docs/configuration.md.
    local xvb_standby_source
    xvb_standby_source=$(jq -r '.xvb.standby.source // empty' "$CONFIG_FILE")

    # check_for_updates (#224, default TRUE): the dashboard checks GitHub for a newer release and shows
    # a header badge linking to it (notify-only — no upgrade). On by default because the check is
    # Tor-routed (socks5h), so it leaks neither the host IP nor a DNS lookup to GitHub; set false to opt
    # out entirely (see docs/privacy.md). Only an explicit `false` disables it.
    local check_for_updates
    check_for_updates=$(jq -r 'if .dashboard.check_for_updates == false then "false" else "true" end' "$CONFIG_FILE")

    # Per-worker xmrig API probe (#171/#172). The dashboard enriches each proxy-reported worker by
    # reading that miner's own xmrig /1/summary for uptime + per-miner hashrate — ONE configured
    # way, no auto-detection. Defaults match the stock RigForge worker: an open, read-only API
    # (xmrig http.restricted, no access-token) on port 8080, so the standard stack needs no config.
    #   workers.api_auth: none (default) | name (Bearer = the worker's stratum name) | token
    #                     (Bearer = workers.api_token, a single shared token for every worker).
    # Upgrade note: a stack whose miners still set an xmrig access-token should set api_auth "name",
    # else the no-auth probe 401s and those workers read api_ok=false (see docs/configuration.md).
    local worker_api_port worker_api_auth worker_api_token
    worker_api_port=$(jq -r '.workers.api_port // 8080' "$CONFIG_FILE")
    worker_api_auth=$(jq -r '.workers.api_auth // "none"' "$CONFIG_FILE")
    worker_api_token=$(jq -r '.workers.api_token // ""' "$CONFIG_FILE")

    # Telegram operator bot (#121 alerts, #45 commands). Disabled by default. bot_token is a
    # secret: it lives only in this owner-only .env (chmod 600 below) and the dashboard never logs
    # it. Per-event toggles default to on, so enabling Telegram turns on the full set and an
    # operator only opts *out* of the noisy ones. The interactive command interface is a separate
    # opt-in (telegram.commands.enabled, default false). A blank chat_id/bot_token keeps everything
    # off even if enabled=true (the dashboard guards that too). See docs/telegram.md.
    local tg_enabled tg_token tg_chat tg_commands
    tg_enabled=$(jq -r 'if .telegram.enabled != null then .telegram.enabled | tostring else "false" end' "$CONFIG_FILE")
    tg_token=$(jq -r '.telegram.bot_token // empty' "$CONFIG_FILE")
    tg_chat=$(jq -r '.telegram.chat_id // empty' "$CONFIG_FILE")
    tg_commands=$(jq -r 'if .telegram.commands.enabled != null then .telegram.commands.enabled | tostring else "false" end' "$CONFIG_FILE")
    # Two-way control commands (#338): /restart, /apply from the bot, through the #33 host channel.
    # Default off; gated to specific operator Telegram user ids (numbers → comma list) and validated
    # above (needs dashboard.control + telegram.commands). confirm_timeout is the deny-on-timeout window.
    local tg_control tg_control_ids tg_control_confirm
    tg_control=$(jq -r 'if .telegram.control.enabled != null then .telegram.control.enabled | tostring else "false" end' "$CONFIG_FILE")
    tg_control_ids=$(jq -r '(.telegram.control.allowed_ids // []) | map(tostring) | join(",")' "$CONFIG_FILE")
    tg_control_confirm=$(jq -r '.telegram.control.confirm_timeout // 60' "$CONFIG_FILE")
    # One toggle per event, defaulting to true when the key is absent.
    tg_event() { jq -r --arg k "$1" 'if .telegram.events[$k] != null then .telegram.events[$k] | tostring else "true" end' "$CONFIG_FILE"; }
    local tg_ev_node_down tg_ev_node_recovered tg_ev_worker_offline tg_ev_worker_recovered
    local tg_ev_worker_joined tg_ev_worker_left tg_ev_sync_finished tg_ev_disk_space tg_ev_db_unhealthy tg_ev_db_reset
    local tg_ev_xvb_no_share tg_ev_clearnet_exposed tg_ev_xvb_registration tg_ev_new_release tg_ev_stack_online
    local tg_ev_daily_summary tg_summary_time tg_ev_hashrate_low tg_ev_hashrate_loss
    local tg_ev_hugepages tg_ev_low_ram tg_ev_wallet_changed tg_ev_high_reject_rate
    local tg_ev_block_found tg_ev_payout_found tg_ev_payout_confirmed tg_ev_container_unhealthy
    local tg_ev_raffle_win
    local hr_drop_threshold hr_drop_minutes
    tg_ev_node_down=$(tg_event node_down)
    tg_ev_node_recovered=$(tg_event node_recovered)
    tg_ev_worker_offline=$(tg_event worker_offline)
    tg_ev_worker_recovered=$(tg_event worker_recovered)
    tg_ev_worker_joined=$(tg_event worker_joined)
    tg_ev_worker_left=$(tg_event worker_left)
    tg_ev_sync_finished=$(tg_event sync_finished)
    tg_ev_disk_space=$(tg_event disk_space)
    tg_ev_db_unhealthy=$(tg_event db_unhealthy)
    tg_ev_db_reset=$(tg_event db_reset)
    tg_ev_xvb_no_share=$(tg_event xvb_no_share)
    tg_ev_clearnet_exposed=$(tg_event clearnet_exposed)
    tg_ev_xvb_registration=$(tg_event xvb_registration)
    tg_ev_new_release=$(tg_event new_release)
    tg_ev_stack_online=$(tg_event stack_online)
    tg_ev_daily_summary=$(tg_event daily_summary)
    tg_ev_hashrate_low=$(tg_event hashrate_low)
    tg_ev_hashrate_loss=$(tg_event hashrate_loss)
    tg_ev_hugepages=$(tg_event hugepages)
    tg_ev_low_ram=$(tg_event low_ram)
    tg_ev_wallet_changed=$(tg_event wallet_changed)
    tg_ev_high_reject_rate=$(tg_event high_reject_rate)
    tg_ev_block_found=$(tg_event block_found)
    tg_ev_payout_found=$(tg_event payout_found)
    tg_ev_payout_confirmed=$(tg_event payout_confirmed)
    tg_ev_container_unhealthy=$(tg_event container_unhealthy)
    tg_ev_raffle_win=$(tg_event raffle_win)
    # Degradation detector (#99): drop-below-% and sustained-minutes; defaults 50 / 10.
    hr_drop_threshold=$(jq -r '.dashboard.hashrate_drop_threshold // 50' "$CONFIG_FILE")
    hr_drop_minutes=$(jq -r '.dashboard.hashrate_drop_minutes // 10' "$CONFIG_FILE")
    # Local time (HH:MM) for the daily digest; default 08:00.
    tg_summary_time=$(jq -r '.telegram.daily_summary_time // "08:00"' "$CONFIG_FILE")

    # Webhook + ntfy alert sinks (#380). Push-only siblings of the Telegram alerter: every alert
    # also POSTs to each notifications.webhooks URL (as JSON) and to the notifications.ntfy.url
    # topic (as the message body). All off by default — no URLs, nothing runs. The URLs and the
    # ntfy token are secrets (webhook query strings often carry tokens): they live only in the
    # owner-only .env and are never echoed or logged. notifications.tor (default true) keeps the
    # POSTs on Tor so endpoints see a Tor exit, not this host's IP; false is the LAN carve-out.
    local notify_webhooks ntfy_url ntfy_token notify_tor
    notify_webhooks=$(jq -r '(.notifications.webhooks // []) | join(" ")' "$CONFIG_FILE")
    ntfy_url=$(jq -r '.notifications.ntfy.url // empty' "$CONFIG_FILE")
    ntfy_token=$(jq -r '.notifications.ntfy.token // empty' "$CONFIG_FILE")
    notify_tor=$(jq -r 'if .notifications.tor != null then .notifications.tor | tostring else "true" end' "$CONFIG_FILE")

    # Tari memory cap (#55). Tari officially needs only a few GB (min 4 GB host, 8 GB+ recommended),
    # but its memory grows unbounded over time — one 32 GB host was seen at ~11 GB while staying
    # healthy. Uncapped, that growth can OOM the whole host on small machines. So the cap is a SAFETY
    # CEILING, not a tight leash: it lets Tari use what it wants and only OOM-restarts it (cleanly,
    # since memswap_limit in compose disables swap) on a genuine runaway that would otherwise take the
    # host down.
    #
    # "auto" sizes the ceiling from RAM that is actually free for normal use. Two big chunks are NOT:
    #   - HugePages: this stack reserves vm.nr_hugepages=3072 (~6 GB) for RandomX (used by p2pool).
    #     That RAM is carved out of the buddy allocator and is invisible to container memory stats,
    #     so we subtract it up front — otherwise Tari's cap + HugePages + the rest of the stack can
    #     exceed physical RAM and the host OOMs before Tari's own limit ever fires.
    #   - a ~25% reserve (>=2 GB) of what's left, for monerod/p2pool/Tor/the dashboard/the OS/page
    #     cache. Tari gets the remainder, floored at 2 GB. Those other services now also carry their
    #     own mem_limit CEILINGS in docker-compose.yml (#132) — runaway protection, not reservations,
    #     so actual steady-state still fits this reserve while a leak in any one of them OOM-restarts
    #     just that container instead of letting the host OOM-killer reach monerod.
    # Net: with HugePages on, ~7.5 GB on a 16 GB host, ~19 GB on 32 GB; with HugePages off
    # (--skip-optimize) it's ~75% of RAM. Override with tari.mem_limit (any Docker value, e.g. "8g").
    local tari_mem_limit ram_mb huge_mb avail_mb reserve_mb monero_mem_limit
    if [ "$TARI_MODE" == "remote" ]; then
        # No local Tari container to cap in remote mode (#103) — the RAM-sniffing auto-calc below is
        # about THIS host's memory, irrelevant to a third-party node, so skip it entirely. Render a
        # fixed placeholder so the (profiled-off) tari service's compose interpolation still
        # resolves; it is never applied to a running container.
        tari_mem_limit="0m"
    else
        tari_mem_limit=$(jq -r '.tari.mem_limit // "auto"' "$CONFIG_FILE")
        case "$tari_mem_limit" in
        "" | auto)
            huge_mb=0
            if [ "$OS_TYPE" == "Darwin" ]; then
                ram_mb=$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576))
            else
                ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
                # HugePages_Total (pages) * Hugepagesize (kB) -> MiB reserved out of RAM.
                huge_mb=$(awk '/HugePages_Total/{t=$2} /Hugepagesize/{s=$2} END{print int(t*s/1024)}' /proc/meminfo 2>/dev/null || echo 0)
            fi
            [ "${ram_mb:-0}" -gt 0 ] 2>/dev/null || ram_mb=16384 # unknown host => assume 16 GB
            [ "${huge_mb:-0}" -ge 0 ] 2>/dev/null || huge_mb=0
            avail_mb=$((ram_mb - huge_mb)) # RAM left after HugePages
            [ "$avail_mb" -lt 2048 ] && avail_mb=2048
            reserve_mb=$((avail_mb / 4)) # rest of the stack + OS + cache
            [ "$reserve_mb" -lt 2048 ] && reserve_mb=2048
            tari_mem_limit=$((avail_mb - reserve_mb))
            [ "$tari_mem_limit" -lt 2048 ] && tari_mem_limit=2048 # never starve Tari below 2 GB
            tari_mem_limit="${tari_mem_limit}m"
            ;;
        esac
    fi

    # monerod memory ceiling (#132): a generous default so heavy initial-sync verification never trips
    # it (monerod's LMDB is reclaimable page cache, so its capped RSS stays low). Tunable for low-RAM
    # hosts that OOM during IBD, or to give a big host more LMDB-cache headroom.
    monero_mem_limit=$(jq -r '.monero.mem_limit // "auto"' "$CONFIG_FILE")
    case "$monero_mem_limit" in "" | auto) monero_mem_limit="6g" ;; esac

    log "Monero block-prep threads: $prep_threads | pool: $pool_type | mode: $MONERO_MODE"

    # Tari view-only wallet secret delivery (#462). The view key, public spend key, and wallet
    # password must NOT ride the tari-wallet's compose `environment:` (those show in `docker
    # inspect`). Instead render them into a dedicated owner-only file that compose mounts as a
    # `secrets:` entry — Docker serves it on a tmpfs at /run/secrets, owner-readable only, and the
    # wrapper entrypoint exports them into the wallet child process only. Kept under data/ (gitignored
    # like .env). Written for the REAL .env target only, so a dry-run render never mutates it; the
    # values are empty (harmless) when the feature is off, so the compose secret always resolves.
    local tari_secret_file="$PWD/data/tari-wallet-secret.env"
    if [ "$target" != "${ENV_FILE}.dryrun" ]; then
        mkdir -p "$PWD/data"
        (
            umask 077
            cat >"$tari_secret_file" <<EOF
MINOTARI_WALLET_VIEW_PRIVATE_KEY=$TARI_VIEW_KEY
MINOTARI_WALLET_SPEND_KEY=$TARI_SPEND_PUBLIC_KEY
MINOTARI_WALLET_PASSWORD=$TARI_WALLET_PASSWORD
EOF
        )
    fi

    # Subshell umask (#368): .env carries the RPC, stratum, and Telegram secrets — it must be
    # owner-only from its FIRST byte, not after a post-write chmod window.
    (
        umask 077
        cat <<EOF >"$target"
MONERO_DATA_DIR=$MONERO_DIR
TARI_DATA_DIR=$TARI_DIR
P2POOL_DATA_DIR=$P2POOL_DIR
DASHBOARD_DATA_DIR=$DASHBOARD_DIR
TOR_DATA_DIR=$TOR_DATA_DIR
MONERO_NODE_USERNAME=$MONERO_USER
MONERO_NODE_PASSWORD=$MONERO_PASS
MONERO_WALLET_ADDRESS=$MONERO_WALLET
MONERO_VIEW_KEY=$MONERO_VIEW_KEY
PAYOUT_SCAN_HEIGHT=$PAYOUT_SCAN_HEIGHT
PAYOUT_CONFIRM_ENABLED=$PAYOUT_CONFIRM_ENABLED
WALLET_RPC_USERNAME=wallet
WALLET_RPC_PASSWORD=$WALLET_RPC_PASSWORD
MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc
TARI_WALLET_ADDRESS=$TARI_WALLET
TARI_VIEW_KEY=$TARI_VIEW_KEY
TARI_SPEND_PUBLIC_KEY=$TARI_SPEND_PUBLIC_KEY
TARI_WALLET_PASSWORD=$TARI_WALLET_PASSWORD
TARI_WALLET_BIRTHDAY=$TARI_WALLET_BIRTHDAY
TARI_PAYOUT_CONFIRM_ENABLED=$TARI_PAYOUT_CONFIRM_ENABLED
TARI_WALLET_GRPC_ADDRESS=127.0.0.1:18143
TARI_WALLET_SECRET_FILE=$tari_secret_file
MONERO_ONION_ADDRESS=$MONERO_ONION
TARI_ONION_ADDRESS=$TARI_ONION
P2POOL_ONION_ADDRESS=$P2POOL_ONION
DASHBOARD_ONION_ADDRESS=$DASHBOARD_ONION
DASHBOARD_ONION_CLIENT_PUBKEY=$DASHBOARD_ONION_CLIENT_PUBKEY
DASHBOARD_ONION_CLIENT_PRIVKEY=$DASHBOARD_ONION_CLIENT_PRIVKEY
P2POOL_FLAGS=$p2pool_flags
P2POOL_PORT=$p2pool_port
STRATUM_BIND=$STRATUM_BIND
STRATUM_PORT=$STRATUM_PORT
PROXY_STRATUM_PASSWORD=$STRATUM_PASSWORD
PROXY_STRATUM_TLS=$STRATUM_TLS
PROXY_TLS_DIR=$PROXY_TLS_DIR
XVB_POOL_URL=$xvb_url
XVB_DONOR_ID=$xvb_donor
XVB_ENABLED=$xvb_enabled
XVB_TOR_ENABLED=$xvb_tor
XVB_DONATION_LEVEL=$xvb_donation_level
TARI_REQUIRED=$tari_required
DASHBOARD_FAIL_CLOSED=$fail_closed
DASHBOARD_CHECK_UPDATES=$check_for_updates
TARI_MEM_LIMIT=$tari_mem_limit
HEALTHCHECKS_PING_URL=$hc_ping_url
XVB_STANDBY_SOURCE=$xvb_standby_source
TELEGRAM_ENABLED=$tg_enabled
TELEGRAM_BOT_TOKEN=$tg_token
TELEGRAM_CHAT_ID=$tg_chat
TELEGRAM_COMMANDS_ENABLED=$tg_commands
TELEGRAM_CONTROL_ENABLED=$tg_control
TELEGRAM_CONTROL_ALLOWED_IDS=$tg_control_ids
TELEGRAM_CONTROL_CONFIRM_S=$tg_control_confirm
TELEGRAM_EVENT_NODE_DOWN=$tg_ev_node_down
TELEGRAM_EVENT_NODE_RECOVERED=$tg_ev_node_recovered
TELEGRAM_EVENT_WORKER_OFFLINE=$tg_ev_worker_offline
TELEGRAM_EVENT_WORKER_RECOVERED=$tg_ev_worker_recovered
TELEGRAM_EVENT_WORKER_JOINED=$tg_ev_worker_joined
TELEGRAM_EVENT_WORKER_LEFT=$tg_ev_worker_left
TELEGRAM_EVENT_SYNC_FINISHED=$tg_ev_sync_finished
TELEGRAM_EVENT_DISK_SPACE=$tg_ev_disk_space
TELEGRAM_EVENT_DB_UNHEALTHY=$tg_ev_db_unhealthy
TELEGRAM_EVENT_DB_RESET=$tg_ev_db_reset
TELEGRAM_EVENT_XVB_NO_SHARE=$tg_ev_xvb_no_share
TELEGRAM_EVENT_CLEARNET_EXPOSED=$tg_ev_clearnet_exposed
TELEGRAM_EVENT_XVB_REGISTRATION=$tg_ev_xvb_registration
TELEGRAM_EVENT_NEW_RELEASE=$tg_ev_new_release
TELEGRAM_EVENT_STACK_ONLINE=$tg_ev_stack_online
TELEGRAM_EVENT_DAILY_SUMMARY=$tg_ev_daily_summary
TELEGRAM_EVENT_HASHRATE_LOW=$tg_ev_hashrate_low
TELEGRAM_EVENT_HASHRATE_LOSS=$tg_ev_hashrate_loss
TELEGRAM_EVENT_HUGEPAGES=$tg_ev_hugepages
TELEGRAM_EVENT_LOW_RAM=$tg_ev_low_ram
TELEGRAM_EVENT_WALLET_CHANGED=$tg_ev_wallet_changed
TELEGRAM_EVENT_HIGH_REJECT_RATE=$tg_ev_high_reject_rate
TELEGRAM_EVENT_BLOCK_FOUND=$tg_ev_block_found
TELEGRAM_EVENT_PAYOUT_FOUND=$tg_ev_payout_found
TELEGRAM_EVENT_PAYOUT_CONFIRMED=$tg_ev_payout_confirmed
TELEGRAM_EVENT_CONTAINER_UNHEALTHY=$tg_ev_container_unhealthy
TELEGRAM_EVENT_RAFFLE_WIN=$tg_ev_raffle_win
HASHRATE_DROP_THRESHOLD_PCT=$hr_drop_threshold
HASHRATE_DROP_MINUTES=$hr_drop_minutes
TELEGRAM_DAILY_SUMMARY_TIME=$tg_summary_time
NOTIFY_WEBHOOK_URLS=$notify_webhooks
NTFY_URL=$ntfy_url
NTFY_TOKEN=$ntfy_token
NOTIFY_TOR=$notify_tor
MONERO_MEM_LIMIT=$monero_mem_limit
P2POOL_URL=${NETWORK_PREFIX}.28:3333
NETWORK_SUBNET=$NETWORK_SUBNET
NETWORK_PREFIX=$NETWORK_PREFIX
TOR_EGRESS_FIREWALL=$TOR_EGRESS_FIREWALL
TOR_AUTO_HEAL=$TOR_AUTO_HEAL
P2POOL_CLEARNET=$P2POOL_CLEARNET
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=$PROXY_AUTH_TOKEN
XMRIG_API_PORT=$worker_api_port
XMRIG_API_AUTH=$worker_api_auth
XMRIG_API_TOKEN=$worker_api_token
PROXY_DONATE_LEVEL=$DONATE_LEVEL
MONERO_PRUNE=$prune
MONERO_CLEARNET_SYNC=$monero_clearnet
TARI_CLEARNET_SYNC=$tari_clearnet
CLEARNET_STATE_DIR=$CLEARNET_STATE_DIR
MONERO_PREP_THREADS=$prep_threads
MONERO_OUT_PEERS=$out_peers
MONERO_RPC_BIND=$rpc_bind
MONERO_ZMQ_BIND=$zmq_bind
MONERO_NODE_HOST=$mono_host
MONERO_RPC_PORT=$rpc_port
MONERO_ZMQ_PORT=$zmq_port
TARI_GRPC_ADDRESS=$tari_grpc_addr
TARI_GRPC_BIND=$tari_grpc_bind
COMPOSE_PROFILES=$profiles
DASHBOARD_SECURE=$DASHBOARD_SECURE
DASHBOARD_EXPOSE_PUBLIC_IP=$DASHBOARD_EXPOSE_PUBLIC_IP
DASHBOARD_ONION_ENABLED=$DASHBOARD_ONION_ENABLED
DASHBOARD_ONION_CLIENT_AUTH=$DASHBOARD_ONION_CLIENT_AUTH
DASHBOARD_TZ=$DASHBOARD_TZ
DASHBOARD_AUTH_USER=$DASHBOARD_AUTH_USER
DASHBOARD_AUTH_HASH_B64=$DASHBOARD_AUTH_HASH_B64
DASHBOARD_AUTH_PW_FP=$DASHBOARD_AUTH_PW_FP
DASHBOARD_CONTROL_ENABLED=$DASHBOARD_CONTROL_ENABLED
CONTROL_DIR=$CONTROL_DIR
CADDY_LOG_DIR=$CADDY_LOG_DIR
HOST_IP=$HOST_IP
PITHEAD_TLS_DIR=$(appliance_tls_dir)
HOST_PORT=$HOST_PORT
DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false}
EOF
    )
    # Contains the node RPC password; keep it owner-only (belt-and-braces — the umask above
    # already created it 600; a chmod failure now aborts loudly instead of passing silently).
    chmod 600 "$target"
}

inject_service_configs() {
    log "Injecting service configurations..."
    cp build/tari/config.toml.template build/tari/config.toml
    local tari_onion_short="${TARI_ONION%%.*}"
    safe_sed "s/<your_tari_onion_address_no_extension>/$tari_onion_short/g" build/tari/config.toml
    # Rebase the Tor control/SOCKS IPs onto the configured subnet prefix (#180): a no-op at the
    # default 172.28.0, rewrites the .25 Tor IP when network.subnet has been moved.
    safe_sed "s/172\.28\.0/$NETWORK_PREFIX/g" build/tari/config.toml

    # config.toml is always rendered for Tor (onion, transport=tor) — the CANONICAL config. The
    # optional clearnet initial sync (#183) is applied per-start inside the container by
    # build/tari/entrypoint.sh (which copies this file and transforms the copy), gated on the
    # TARI_CLEARNET_SYNC flag AND the dashboard's auto-transition marker (#234) — so once synced the
    # node returns to Tor on its own and `apply` never re-renders clearnet over it. Same idea for
    # monerod, whose entrypoint envsubsts + transforms in-container. Here we only re-arm:

    # Re-arm clearnet auto-sync (#234): clear a chain's "sync complete" marker whenever its flag is
    # OFF, so re-enabling later starts a fresh clearnet sync. While a flag is ON the dashboard owns
    # the marker, so leave it. Markers live in the shared, dashboard-writable clearnet-state dir.
    local _csdir
    _csdir=$(clearnet_state_dir)
    mkdir -p "$_csdir" 2>/dev/null || true
    [ "$(env_get MONERO_CLEARNET_SYNC)" = "true" ] || rm -f "$_csdir/monero.synced" 2>/dev/null || true
    [ "$(env_get TARI_CLEARNET_SYNC)" = "true" ] || rm -f "$_csdir/tari.synced" 2>/dev/null || true
}

# sha256 of stdin as lowercase hex — portable across the sha256sum / shasum split.
sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# bcrypt-hash a dashboard password with the PINNED Caddy image (read straight from docker-compose.yml
# so it tracks the digest), returned base64-encoded so the raw bcrypt '$' never lands in .env (#8).
# Returns non-zero if Docker / the image isn't available.
caddy_hash_password_b64() {
    local pw="$1" img hash
    img=$(grep -oE 'caddy:[0-9.]+@sha256:[a-f0-9]+' docker-compose.yml | head -1)
    [ -n "$img" ] || return 1
    # Fully qualified, because `docker run` here may be podman's shim: docker IMPLIES docker.io
    # for a short name, podman's native path refuses one outright — the compose pull worked (the
    # compat API keeps docker semantics) while this exact line killed appliance provisioning.
    img="docker.io/library/$img"
    hash=$(docker run --rm "$img" caddy hash-password --plaintext "$pw" 2>/dev/null) || return 1
    [ -n "$hash" ] || return 1
    printf '%s' "$hash" | openssl base64 -A
}

generate_caddyfile() {
    # Every vhost forwards the authenticated basic_auth username as X-Auth-User (#33) — the audit
    # `actor` for control-channel requests. header_up SETS the header, so a client-supplied
    # X-Auth-User can never spoof it; with auth off the placeholder renders empty.
    #
    # Optional basic_auth block (#8), rendered only when a dashboard password is configured. The
    # hash is decoded from its base64 .env form back to the raw bcrypt string Caddy expects; it
    # protects every route, so the dashboard prompts for login before anything is served.
    local auth=""
    if [ -n "$DASHBOARD_AUTH_HASH_B64" ]; then
        local hash
        hash=$(printf '%s' "$DASHBOARD_AUTH_HASH_B64" | openssl base64 -d -A)
        auth=$(printf '    basic_auth {\n        %s %s\n    }' "$DASHBOARD_AUTH_USER" "$hash")
    fi
    # Access log (#349): every vhost writes a JSON line per request (timestamp, status, method,
    # URI, authenticated user) to one shared file under the host-mounted CADDY_LOG_DIR; the
    # dashboard tails it read-only, and repeated 401s there are the operator's "someone is
    # guessing the password" signal. Caddy redacts credential headers (Authorization, Cookie)
    # unless the log_credentials global option is set — it never is here — so no password material
    # lands in the log. Growth is bounded by Caddy's native rolling: 4 MiB per file, the current
    # file plus 2 rolled ones. mode 0644 lets the non-root dashboard read what root-run Caddy
    # writes (Caddy's default is 0600).
    local logblk='    log {
        output file /var/log/caddy/access.log {
            roll_size 4MiB
            roll_keep 2
            mode 0644
        }
        format json
    }'
    # Caddy LAN listen port (#740). An empty HOST_PORT — or a value that equals the scheme's own
    # default (443 for HTTPS, 80 for HTTP) — keeps the standard port and renders today's Caddyfile
    # verbatim. A custom port is appended to the site address so an existing reverse proxy on the
    # host can keep 80/443 (co-hosting, #181). In HTTPS mode a custom port also disables Caddy's
    # automatic :80 -> HTTPS redirect (a global option emitted once at the top of the file) so port
    # 80 is left free for that proxy; the fronting proxy owns any http->https bounce instead.
    local dport="${HOST_PORT:-}" port_suffix="" global_block="" own_plain_port=0
    if [ "$DASHBOARD_SECURE" == "true" ]; then
        [ "$dport" == "443" ] && dport=""
        if [ -n "$dport" ]; then
            port_suffix=":$dport"
            global_block='{
    auto_https disable_redirects
}

'
        else
            # Caddy's own HTTP->HTTPS redirect is a CATCH-ALL, and its target is the Host header the
            # request carried: :80 answered `Host: evil.example` with `308 -> https://evil.example`
            # (#1123, measured against the running bench appliance, not read off the config). Same
            # open redirector #1118 closed in the setup wizard, except this one is the state the
            # machine spends its life in, and it lands the operator on the dashboard login — the
            # screen where they type the dashboard password.
            #
            # So take :80 over rather than leaving it to auto_https. The site is built below, once
            # $site_hosts and the bind list exist: this is the port decision, that is the address
            # decision, and the bind list is what keeps the new block from reopening the addresses
            # #1021 closed.
            own_plain_port=1
            global_block='{
    auto_https disable_redirects
}

'
        fi
    else
        [ "$dport" == "80" ] && dport=""
        [ -n "$dport" ] && port_suffix=":$dport"
    fi

    # The site addresses — and the certificate's SAN list — now come from ONE shared builder
    # (appliance_site_names, #1132): a name Caddy serves and a name the certificate covers can no
    # longer drift apart the way they did when each kept its own copy of this expansion. DIY
    # serves the one host the operator reaches it by; the appliance expands to every address it
    # answers on unless dashboard.host is pinned, in which case it stays single on purpose — see
    # appliance_site_names for the full rule, the SLAAC-leak guard, and the bridge-gateway
    # exclusion (a stray site block on that address makes Caddy refuse the whole file).
    local site_hosts
    site_hosts=$(appliance_site_names)
    _site_addresses() { # $1 scheme — "https://a, https://b" from $site_hosts
        local h out=""
        for h in $site_hosts; do
            out="${out:+$out, }$1://$h$port_suffix"
        done
        printf '%s' "$out"
    }
    # Trimming the address list is necessary but is NOT a boundary on its own. Caddy runs with
    # network_mode: host and opens ONE WILDCARD listener (verified on the bench: `ss -lnt` shows
    # `*:443`, not per-address sockets), so a client that reaches the box on a global address still
    # completes the connection — it only has to send a Host header naming an address that IS in the
    # list, and Caddy matches on content, never on which interface the connection arrived over.
    # `bind` is what actually closes the socket: Caddy then listens on these addresses only, so the
    # global one is never accepted at all.
    #
    # LITERAL addresses only. A name would be resolved by Caddy at startup, and the appliance's
    # mDNS name resolves to every address it has — including the one being excluded, which would
    # re-open exactly what this closes. Loopback is always added: the host-networked dashboard and
    # Caddy's own admin healthcheck both arrive that way.
    # Built from the BOX's own addresses, never from $site_hosts. The two are different questions:
    # site_hosts is which Host values Caddy vhost-matches, this is which sockets it opens. Deriving
    # the bind from site_hosts tied it to the auto-expansion, so an operator who pinned
    # dashboard.host — a documented, supported choice — got a single-host site list and NO bind at
    # all, which is the wildcard listener and the whole exposure, back again for exactly the
    # operators who configured the box most deliberately.
    local bind_addrs="" _bh
    if is_appliance && [ "${DASHBOARD_EXPOSE_PUBLIC_IP:-false}" != "true" ]; then
        for _bh in $(hostname -I 2>/dev/null); do
            is_public_ip "$_bh" && continue
            case "$_bh" in
            *:*) ;;                # IPv6 literal
            *[!0-9.]*) continue ;; # not an address literal
            esac
            bind_addrs="${bind_addrs:+$bind_addrs }$_bh"
        done
        # Loopback unconditionally, appended OUTSIDE the loop so it survives a box that reports no
        # usable non-public address at render time: the host-networked dashboard and Caddy's own
        # admin healthcheck both arrive this way, and a bind that dropped them would be worse than
        # no bind at all.
        bind_addrs="${bind_addrs:+$bind_addrs }127.0.0.1 ::1"
    fi
    # NO trailing newline: consumed as $(_bind_line) on its own heredoc line, and command
    # substitution strips trailing newlines anyway — emitting one here produced
    # `bind ... ::1    basic_auth {` on a single line, which Caddy will not parse. Same convention
    # as $auth above. Empty when binding is off, which collapses to a blank line, like $auth.
    _bind_line() {
        [ -n "$bind_addrs" ] || return 0
        printf '    bind %s' "$bind_addrs"
    }
    # BOTH onion vhosts bind exactly when the LAN vhost does — the plain-HTTP one AND the HTTPS one
    # on the .onion name. A site block with NO bind asks Caddy for a WILDCARD listener, and that is
    # the whole reason this matters: an unbound block reopens every address the bound blocks were
    # written to exclude, including the globally-routable one #1021 exists to close. Verified
    # against the pinned caddy image: with `bind 127.0.0.1 ::1` on the LAN block and no bind on the
    # onion block, a request to an address OUTSIDE the bind list carrying the .onion name in Host/SNI
    # is served. For a Tor-first product that confirms the clearnet address behind the hidden
    # service and puts the login page back on the internet.
    #
    # Note what does NOT happen: a wildcard and a specific listener on one port do NOT collide.
    # Caddy sets SO_REUSEPORT, so `[::]:443` and `127.0.0.1:443` listen happily side by side —
    # measured, not assumed. The hazard is the reopened socket, never a startup crash.
    #
    # The HTTPS block is the one this originally missed: it renders only after provisioning lands a
    # real .onion address, so every render before that looked correct.
    _onion_bind_line() {
        [ -n "$bind_addrs" ] || return 0
        printf '    bind %s' "${NETWORK_PREFIX}.1"
    }

    # The :80 and :443 catch-alls that replace Caddy's own defaults for an unmatched Host. Built
    # here because both need everything that is only settled by now ($site_hosts, the bind list).
    #
    #  - the KNOWN hosts keep the address the operator typed, so browsing by mDNS name and browsing
    #    by IP each land on the name they used and match the certificate minted for it;
    #  - the trailing catch-alls answer everything else — including a forged Host or SNI — with
    #    THIS box's canonical address, never with what the request asked for. Unmatched, Caddy's
    #    own default is a reflecting redirect on :80 (closed by #1123) and an empty 200 on :443 —
    #    `content-length: 0`, no body, so a browser just shows a blank page (#1132's third bullet:
    #    the certificate/site-list mismatch this closes made that page's Host land HERE, not on the
    #    real vhost, and this was the only piece of the mismatch that stayed silent). Refusing
    #    outright would read as a dead machine, same reasoning as the :80 catch-all.
    #  - the :443 catch-all carries NO `tls` line of its own: it has no hostname in its address for
    #    Caddy to manage a certificate against, and needs none — proven with `caddy adapt` against
    #    the rendered file, a catch-all with no per-block TLS policy falls through to the file's
    #    default connection policy, which serves whatever certificate the named vhost below already
    #    loads (the appliance's minted file, or DIY's `tls internal`). A matching SNI never sees
    #    this block at all; an unmatched one completes the handshake against that same certificate
    #    (a name mismatch the browser will flag, honestly) and gets the redirect below instead of
    #    a silent 200.
    #  - and ALL of these carry the same bind list as the vhosts above. A site block with no bind
    #    asks Caddy for a WILDCARD listener, which would reopen every address the bound blocks were
    #    written to exclude — the globally-routable one included (#1021). That is the whole hazard
    #    here.
    #
    # A literal, NOT $(printf ...): command substitution strips the trailing newlines and the next
    # site block lands on the same line as this one's closing brace, which Caddy refuses.
    local redirect_block=""
    if [ "$own_plain_port" = 1 ]; then
        redirect_block="$(_site_addresses http) {
$(_bind_line)
    redir https://{host}{uri} 308
}

http:// {
$(_bind_line)
    redir https://$HOST_IP{uri} 308
}

https:// {
$(_bind_line)
    redir https://$HOST_IP{uri} 308
}

"
    fi

    : >"Caddyfile"
    [ -n "$global_block" ] && printf '%s' "$global_block" >>"Caddyfile"
    [ -n "$redirect_block" ] && printf '%s' "$redirect_block" >>"Caddyfile"
    # The appliance hands its ONE certificate to Caddy — the same file the setup page served, so
    # the operator's trust decision survives the handoff. Without this the wizard's cert is
    # replaced by Caddy's own at the exact moment provisioning succeeds, and the browser that
    # trusted the first one refuses the second: the setup page appears to die on success.
    local tls_line="    tls internal" tlsd
    if is_appliance; then
        # MINT IT HERE, every render — never gated on "missing". The certificate was previously
        # created only by the setup wizard, so any machine that skips the wizard (a pre-seeded
        # config, or a reinstall whose preserved /data already held config.json) reached this point
        # with the Caddyfile naming a file that did not exist; Caddy then answered :443 without a
        # usable certificate and the dashboard failed the TLS handshake outright
        # (ERR_SSL_PROTOCOL_ERROR), which covered the missing-file case. But site_hosts above is
        # rebuilt fresh on every render while a file-exists gate would leave an EXISTING certificate
        # untouched forever — so the moment the machine's addresses changed (a DHCP lease, a pinned
        # host), Caddy would serve names the certificate never heard of (#1132). Calling
        # unconditionally hands that decision to appliance_mint_cert itself, which is idempotent
        # by comparison, not by "already have a file": it re-mints only when the name list it was
        # minted for no longer matches, and reuses the operator's already-trusted certificate
        # otherwise.
        tlsd=$(appliance_tls_dir)
        appliance_mint_cert >/dev/null 2>&1 || true
        if [ -s "$tlsd/wizard.crt" ] && [ -s "$tlsd/wizard.key" ]; then
            tls_line="    tls /pithead-tls/wizard.crt /pithead-tls/wizard.key"
        else
            warn "Could not provide a certificate for the dashboard — falling back to Caddy's own."
        fi
    fi
    if [ "$DASHBOARD_SECURE" == "true" ]; then
        log "Generating Caddyfile for automatic HTTPS ($site_hosts$port_suffix)$([ -n "$auth" ] && echo ' with login')..."
        cat <<EOF >>"Caddyfile"
$(_site_addresses https) {
$tls_line
$(_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
    else
        log "Generating Caddyfile for HTTP ($site_hosts$port_suffix)$([ -n "$auth" ] && echo ' with login')..."
        cat <<EOF >>"Caddyfile"
$(_site_addresses http) {
$(_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
    fi

    # Onion vhost (#343): a second site reachable ONLY from the tor container, via the bridge gateway
    # (NETWORK_PREFIX.1 — the /24's first host, where host-networked Caddy binds and bridge containers
    # route out). It is never on the LAN. Plain HTTP: Tor provides the transport encryption inside the
    # tunnel, so no `tls internal` here. It MUST carry the same auth block — refuse to publish an
    # unauthenticated control panel (config validation already fails closed; this is belt-and-suspenders).
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ]; then
        if [ -z "$auth" ]; then
            error "Refusing to render the dashboard onion vhost without a login: dashboard.onion.enabled is on but no auth hash is set."
        fi
        log "Adding onion vhost for the dashboard (${NETWORK_PREFIX}.1, login required)..."
        cat <<EOF >>"Caddyfile"

http://${NETWORK_PREFIX}.1 {
$(_onion_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
        # Also serve HTTPS on the .onion name so Tor Browser's default http->https upgrade lands on a
        # working :443 instead of a refused connection (#343). The cert is self-signed (Caddy's internal
        # CA) for the .onion — a .onion can't get a browser-trusted cert without a manual CA process, and
        # Tor already encrypts the tunnel, so the browser shows a one-time "accept the risk" prompt. SNI
        # (the .onion name) routes this apart from the LAN vhost, both on host-networked :443. Rendered
        # only once the address is provisioned; a fresh enable serves HTTP immediately, and apply,
        # upgrade, and rotate-dashboard-onion regenerate this Caddyfile (and restart caddy) the moment
        # the capture step lands the real address, so HTTPS appears in that same run (#546).
        if [ -n "${DASHBOARD_ONION:-}" ] && [ "${DASHBOARD_ONION:-}" != "placeholder" ]; then
            log "Adding HTTPS onion vhost (self-signed cert for the .onion)..."
            cat <<EOF >>"Caddyfile"

https://${DASHBOARD_ONION} {
    tls internal
$(_onion_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
        fi
    fi
}

# Appliance unit rendering (#77 phase 1). Emits Podman Quadlet units from a rendered .env — the
# second render target beside docker-compose (docs/dev/dual-distribution-plan.md § Runtime
# architecture). The os/quadlet/ fixtures pin this output byte-for-byte at tier 1: they are the
# unit set the #78 spike ran live, so a change here that drifts from them needs a bench re-proof,
# not just a green diff. Spike-proven rules baked in: Notify=healthy services carry
# TimeoutStartSec=infinity (a finite timeout KILLS a not-yet-healthy service — compose's
# start_period never does); plain depends_on maps to After=+Wants= (Requires= would stop-couple);
# tmpfs options use mode= (podman rejects uid=/gid=).
render_quadlet_units() {
    local envf="$1" outdir="$2"
    [ -f "$envf" ] || error "render-quadlet: env file not found: $envf"
    mkdir -p "$outdir"

    _qenv() { env_get_file "$envf" "$1"; }

    # Every emitted unit has run on the bench (render-then-prove): the remote set in the #78
    # spike, the local-node units 2026-07-24, and the payout-wallet units the same day (real
    # throwaway monero wallet; tari view-only wallet on a canonical scalar). A new profile or
    # service starts life refused here until it has a bench run behind it.
    local profiles
    profiles=$(_qenv COMPOSE_PROFILES)

    local reg ver prefix subnet
    reg=$(_qenv PITHEAD_REGISTRY)
    ver=$(_qenv STACK_VERSION)
    prefix=$(_qenv NETWORK_PREFIX)
    subnet=$(_qenv NETWORK_SUBNET)

    cat >"$outdir/mining.network" <<EOF
[Network]
NetworkName=mining_net
Subnet=$subnet
EOF
    cat >"$outdir/proxy.network" <<EOF
[Network]
NetworkName=proxy_net
EOF

    cat >"$outdir/tor.container" <<EOF
[Unit]
Description=pithead tor
[Container]
ContainerName=tor
Image=$reg/pithead-tor:$ver
Network=mining.network
IP=$prefix.25
Environment=NETWORK_PREFIX=$prefix COMPOSE_PROFILES=$profiles DASHBOARD_ONION_ENABLED=$(_qenv DASHBOARD_ONION_ENABLED) DASHBOARD_ONION_CLIENT_AUTH=$(_qenv DASHBOARD_ONION_CLIENT_AUTH)
Volume=$(_qenv TOR_DATA_DIR):/var/lib/tor
Tmpfs=/tmp:size=64m,mode=1777
ReadOnly=true
HealthCmd=/usr/local/bin/tor-healthcheck.sh
HealthInterval=30s
HealthTimeout=10s
HealthRetries=5
HealthStartPeriod=90s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF

    # Local-node units, emitted only when their profile is active (bench-proven 2026-07-24).
    # monerod: tor-gated via the same Requires+Notify=healthy edge compose expresses with
    # depends_on service_healthy; healthy = RPC responding, NOT synced (the stack could never
    # cold-start otherwise). tari: the upstream digest-pinned image with pithead's wrapper
    # entrypoint; its config.toml is rendered by inject_service_configs before units start.
    case ",$profiles," in
    *,local_node,*)
        cat >"$outdir/monerod.container" <<EOF
[Unit]
Description=pithead monerod
After=tor.service
Requires=tor.service
[Container]
ContainerName=monerod
Image=$reg/pithead-monero:$ver
Network=mining.network
IP=$prefix.26
Environment=MONERO_NODE_USERNAME=$(_qenv MONERO_NODE_USERNAME) MONERO_NODE_PASSWORD=$(_qenv MONERO_NODE_PASSWORD) MONERO_ONION_ADDRESS=$(_qenv MONERO_ONION_ADDRESS) MONERO_PRUNE=$(_qenv MONERO_PRUNE) MONERO_CLEARNET_SYNC=$(_qenv MONERO_CLEARNET_SYNC) MONERO_PREP_THREADS=$(_qenv MONERO_PREP_THREADS) MONERO_OUT_PEERS=$(_qenv MONERO_OUT_PEERS) NETWORK_PREFIX=$prefix
Volume=$(_qenv MONERO_DATA_DIR):/home/ubuntu/.bitmonero
Volume=/dev/hugepages:/dev/hugepages
Volume=$(_qenv QUADLET_HOST_CONFIG_DIR)/build/monero/bitmonero.conf.template:/home/ubuntu/bitmonero.conf.template:ro
Volume=$(_qenv CLEARNET_STATE_DIR):/clearnet-state:ro
Tmpfs=/tmp:size=64m,mode=1777
PublishPort=$(_qenv MONERO_RPC_BIND):18081:18081
PublishPort=$(_qenv MONERO_ZMQ_BIND):18083:18083
ReadOnly=true
NoNewPrivileges=true
StopTimeout=60
PodmanArgs=--memory $(_qenv MONERO_MEM_LIMIT) --memory-swap $(_qenv MONERO_MEM_LIMIT)
HealthCmd=/usr/local/bin/monerod-healthcheck.sh
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=60s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF
        ;;
    esac
    case ",$profiles," in
    *,local_tari,*)
        cat >"$outdir/tari.container" <<EOF
[Unit]
Description=pithead tari
After=tor.service
Requires=tor.service
[Container]
ContainerName=tari
Image=quay.io/tarilabs/minotari_node:v5.3.1-mainnet@sha256:824fd6ec21d618805317d7eede374d6782906eeae17d2fc8aaad4df6205f94e0
Network=mining.network
IP=$prefix.27
User=1000:1000
DNS=127.0.0.1
Environment=WAIT_FOR_TOR=1 TARI_CLEARNET_SYNC=$(_qenv TARI_CLEARNET_SYNC)
Entrypoint=/var/tari/config/entrypoint.sh
Exec=--disable-splash-screen --non-interactive
Volume=$(_qenv TARI_DATA_DIR):/var/tari/node
Volume=$(_qenv QUADLET_HOST_CONFIG_DIR)/build/tari:/var/tari/config
Volume=$(_qenv CLEARNET_STATE_DIR):/clearnet-state:ro
Tmpfs=/tmp:size=64m,mode=1777
PublishPort=$(_qenv TARI_GRPC_BIND):18142:18142
ReadOnly=true
NoNewPrivileges=true
StopTimeout=60
PodmanArgs=--memory $(_qenv TARI_MEM_LIMIT) --memory-swap $(_qenv TARI_MEM_LIMIT)
HealthCmd=ps | grep '[m]inotari_node' || exit 1
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=120s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF
        ;;
    esac

    case ",$profiles," in
    *,payout_confirm,*)
        cat >"$outdir/wallet-rpc.container" <<EOF
[Unit]
Description=pithead wallet-rpc
After=monerod.service
Requires=monerod.service
[Container]
ContainerName=wallet-rpc
Image=$reg/pithead-monero:$ver
Network=mining.network
IP=$prefix.30
Entrypoint=/usr/local/bin/wallet-entrypoint.sh
Environment=MONERO_NODE_USERNAME=$(_qenv MONERO_NODE_USERNAME) MONERO_NODE_PASSWORD=$(_qenv MONERO_NODE_PASSWORD) MONERO_NODE_HOST=$prefix.26 MONERO_RPC_PORT=18081 WALLET_RPC_USERNAME=wallet WALLET_RPC_PASSWORD=$(_qenv WALLET_RPC_PASSWORD) MONERO_WALLET_ADDRESS=$(_qenv MONERO_WALLET_ADDRESS) MONERO_VIEW_KEY=$(_qenv MONERO_VIEW_KEY) PAYOUT_SCAN_HEIGHT=$(_qenv PAYOUT_SCAN_HEIGHT)
Volume=pithead-wallet-data:/home/ubuntu/wallets
Tmpfs=/tmp:size=16m,mode=1777
PublishPort=127.0.0.1:18082:18082
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 2g --memory-swap 2g
HealthCmd=/usr/local/bin/wallet-healthcheck.sh
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=120s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF
        ;;
    esac
    case ",$profiles," in
    *,tari_payout_confirm,*)
        cat >"$outdir/tari-wallet.container" <<EOF
[Unit]
Description=pithead tari-wallet
After=tari.service
Requires=tari.service
[Container]
ContainerName=tari-wallet
Image=quay.io/tarilabs/minotari_console_wallet:v5.3.1-mainnet@sha256:886ce60b1cf2a28bd01fb9ce21533bb3be834215e5bbe918533869e3d2a43622
Network=mining.network
IP=$prefix.31
User=1000:1000
Entrypoint=/wallet-config/entrypoint.sh
Environment=TARI_BASE_NODE_GRPC_ADDRESS=$(_qenv TARI_GRPC_ADDRESS) TARI_WALLET_BIRTHDAY=$(_qenv TARI_WALLET_BIRTHDAY) TARI_WALLET_GRPC_BIND=/ip4/0.0.0.0/tcp/18143 WALLET_DIR=/home/ubuntu/wallet
Volume=pithead-tari-wallet-data:/home/ubuntu/wallet
Volume=$(_qenv QUADLET_HOST_CONFIG_DIR)/build/tari-wallet:/wallet-config:ro
Volume=$(_qenv TARI_WALLET_SECRET_FILE):/run/secrets/tari_wallet_secret:ro
Tmpfs=/tmp:size=32m,mode=1777
PublishPort=127.0.0.1:18143:18143
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 512m --memory-swap 512m
HealthCmd=ps | grep '[m]inotari_consol' || exit 1
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=120s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF
        ;;
    esac

    cat >"$outdir/p2pool.container" <<EOF
[Unit]
Description=pithead p2pool
After=tor.service
Requires=tor.service
[Container]
ContainerName=p2pool
Image=$reg/pithead-p2pool:$ver
Network=mining.network
IP=$prefix.28
Environment=P2POOL_FLAGS=$(_qenv P2POOL_FLAGS)
Exec=--host $(_qenv MONERO_NODE_HOST) --rpc-port $(_qenv MONERO_RPC_PORT) --rpc-login $(_qenv MONERO_NODE_USERNAME):$(_qenv MONERO_NODE_PASSWORD) --zmq-port $(_qenv MONERO_ZMQ_PORT) --wallet $(_qenv MONERO_WALLET_ADDRESS) --merge-mine tari://$(_qenv TARI_GRPC_ADDRESS) $(_qenv TARI_WALLET_ADDRESS) --onion-address $(_qenv P2POOL_ONION_ADDRESS) --local-api --stratum 0.0.0.0:3333 --p2p 0.0.0.0:$(_qenv P2POOL_PORT) --data-api /stats
Volume=$(_qenv P2POOL_DATA_DIR):/home/ubuntu
Volume=$(_qenv P2POOL_DATA_DIR)/stats:/stats
Volume=/dev/hugepages:/dev/hugepages
Tmpfs=/tmp:size=64m,mode=1777
ReadOnly=true
DropCapability=all
AddCapability=IPC_LOCK SYS_NICE
NoNewPrivileges=true
Ulimit=memlock=-1:-1
PodmanArgs=--memory 1g --memory-swap 1g
HealthCmd=/usr/local/bin/p2pool-healthcheck.sh
HealthInterval=30s
HealthTimeout=5s
HealthRetries=3
HealthStartPeriod=60s
Notify=healthy
[Service]
Restart=always
TimeoutStartSec=infinity
[Install]
WantedBy=multi-user.target
EOF

    cat >"$outdir/xmrig-proxy.container" <<EOF
[Unit]
Description=pithead xmrig-proxy
After=p2pool.service
Wants=p2pool.service
[Container]
ContainerName=xmrig-proxy
Image=$reg/pithead-xmrig-proxy:$ver
Network=mining.network
IP=$prefix.29
Environment=PROXY_API_PORT=$(_qenv PROXY_API_PORT) PROXY_AUTH_TOKEN=$(_qenv PROXY_AUTH_TOKEN) PROXY_STRATUM_PASSWORD=$(_qenv PROXY_STRATUM_PASSWORD) PROXY_STRATUM_TLS=$(_qenv PROXY_STRATUM_TLS) PROXY_DONATE_LEVEL=$(_qenv PROXY_DONATE_LEVEL)
Exec=-o $(_qenv P2POOL_URL) -u $(_qenv MONERO_WALLET_ADDRESS) -b 0.0.0.0:$(_qenv STRATUM_PORT) -m simple --coin monero --verbose --http-host 0.0.0.0 --http-port $(_qenv PROXY_API_PORT) --http-access-token $(_qenv PROXY_AUTH_TOKEN) --http-no-restricted --donate-level $(_qenv PROXY_DONATE_LEVEL)
Volume=$(_qenv PROXY_TLS_DIR):/tls:ro
Tmpfs=/tmp:size=64m,mode=1777
Tmpfs=/home/ubuntu:size=64m,mode=1777
PublishPort=$(_qenv STRATUM_BIND):$(_qenv STRATUM_PORT):$(_qenv STRATUM_PORT)
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 512m --memory-swap 512m
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    cat >"$outdir/caddy.container" <<EOF
[Unit]
Description=pithead caddy
[Container]
ContainerName=caddy
Image=docker.io/library/caddy:2.11.4
Network=host
Volume=$(_qenv QUADLET_CADDYFILE):/etc/caddy/Caddyfile:ro
Volume=pithead-caddy-data:/data
Volume=$(_qenv CADDY_LOG_DIR):/var/log/caddy
Tmpfs=/tmp
Tmpfs=/config
ReadOnly=true
DropCapability=all
AddCapability=NET_BIND_SERVICE
NoNewPrivileges=true
PodmanArgs=--memory 128m --memory-swap 128m
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    local proxy_sock
    proxy_sock=$(_qenv QUADLET_ENGINE_SOCK)
    cat >"$outdir/docker-proxy.container" <<EOF
[Unit]
Description=pithead read socket proxy
[Container]
ContainerName=docker-proxy
Image=docker.io/tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459
Network=proxy.network
Environment=CONTAINERS=1 LOGS=1
Volume=$proxy_sock:/var/run/docker.sock:ro
Tmpfs=/run
Tmpfs=/tmp
PublishPort=127.0.0.1:12375:2375
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 128m --memory-swap 128m
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    cat >"$outdir/docker-control.container" <<EOF
[Unit]
Description=pithead control socket proxy
[Container]
ContainerName=docker-control
Image=docker.io/tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459
Network=proxy.network
Environment=CONTAINERS=1 POST=1 ALLOW_START=1 ALLOW_STOP=1
Volume=$proxy_sock:/var/run/docker.sock:ro
Tmpfs=/run
Tmpfs=/tmp
PublishPort=127.0.0.1:12376:2375
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 128m --memory-swap 128m
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    # Payout-confirmation env reaches the dashboard only when a payout profile is active —
    # emitted conditionally so the payout-off unit stays byte-identical to the proven fixtures.
    local payout_env=""
    case ",$profiles," in
    *,payout_confirm,*) payout_env=" PAYOUT_CONFIRM_ENABLED=true MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc WALLET_RPC_USERNAME=wallet WALLET_RPC_PASSWORD=$(_qenv WALLET_RPC_PASSWORD)" ;;
    esac
    case ",$profiles," in
    *,tari_payout_confirm,*) payout_env="$payout_env TARI_PAYOUT_CONFIRM_ENABLED=true TARI_WALLET_GRPC_ADDRESS=127.0.0.1:18143" ;;
    esac
    cat >"$outdir/dashboard.container" <<EOF
[Unit]
Description=pithead dashboard
[Container]
ContainerName=dashboard
Image=$reg/pithead-dashboard:$ver
Network=host
Environment=HOST_IP=$(_qenv HOST_IP) TZ=$(_qenv DASHBOARD_TZ) MONERO_NODE_HOST=$(_qenv MONERO_NODE_HOST) MONERO_NODE_USERNAME=$(_qenv MONERO_NODE_USERNAME) MONERO_NODE_PASSWORD=$(_qenv MONERO_NODE_PASSWORD) MONERO_PRUNE=$(_qenv MONERO_PRUNE) MONERO_CLEARNET_SYNC=$(_qenv MONERO_CLEARNET_SYNC) TARI_CLEARNET_SYNC=$(_qenv TARI_CLEARNET_SYNC) CLEARNET_STATE_DIR=/clearnet-state TOR_EGRESS_FIREWALL=$(_qenv TOR_EGRESS_FIREWALL) TOR_AUTO_HEAL=$(_qenv TOR_AUTO_HEAL) P2POOL_CLEARNET=$(_qenv P2POOL_CLEARNET) P2POOL_URL=$(_qenv P2POOL_URL) MONERO_WALLET_ADDRESS=$(_qenv MONERO_WALLET_ADDRESS) STRATUM_PORT=$(_qenv STRATUM_PORT) TARI_REQUIRED=$(_qenv TARI_REQUIRED) TARI_GRPC_ADDRESS=$(_qenv TARI_GRPC_ADDRESS) XVB_ENABLED=$(_qenv XVB_ENABLED) XVB_TOR_ENABLED=$(_qenv XVB_TOR_ENABLED) XVB_DONATION_LEVEL=$(_qenv XVB_DONATION_LEVEL) PROXY_HOST=$prefix.29 PROXY_API_PORT=$(_qenv PROXY_API_PORT) PROXY_AUTH_TOKEN=$(_qenv PROXY_AUTH_TOKEN) DOCKER_PROXY_URL=tcp://127.0.0.1:12375 DOCKER_CONTROL_URL=tcp://127.0.0.1:12376 LOCAL_MONERO_HOST=$prefix.26 MINING_NET_CIDR=$subnet TOR_SOCKS_PROXY=socks5h://$prefix.25:9050${payout_env} DASHBOARD_CHECK_UPDATES=$(_qenv DASHBOARD_CHECK_UPDATES) DASHBOARD_CONTROL_ENABLED=$(_qenv DASHBOARD_CONTROL_ENABLED) DASHBOARD_FAIL_CLOSED=$(_qenv DASHBOARD_FAIL_CLOSED) TELEGRAM_ENABLED=$(_qenv TELEGRAM_ENABLED)
Volume=$(_qenv P2POOL_DATA_DIR)/stats:/app/stats:ro
Volume=$(_qenv DASHBOARD_DATA_DIR):/data
Volume=$(_qenv CLEARNET_STATE_DIR):/clearnet-state
Volume=$(_qenv CONTROL_DIR)/requests:/control/requests
Volume=$(_qenv CONTROL_DIR)/results:/control/results:ro
Volume=$(_qenv CONTROL_DIR)/audit:/control/audit:ro
Volume=$(_qenv CONTROL_DIR)/masked:/control/masked:ro
Volume=$(_qenv CADDY_LOG_DIR):/access-log:ro
Volume=$(_qenv QUADLET_HOST_CONFIG_DIR)/config.reference.json:/host-config/config.reference.json:ro
Volume=$(_qenv QUADLET_HOST_CONFIG_DIR)/config.core-keys.json:/host-config/config.core-keys.json:ro
Tmpfs=/tmp:size=64m,mode=1777
ReadOnly=true
DropCapability=all
NoNewPrivileges=true
PodmanArgs=--memory 512m --memory-swap 512m
[Service]
Restart=always
[Install]
WantedBy=multi-user.target
EOF

    log "Rendered Quadlet units to $outdir ($(find "$outdir" -maxdepth 1 \( -name '*.container' -o -name '*.network' \) | wc -l | tr -d ' ') files)."
}

# The stack's own HugePages budget: 3072 pages of 2 MiB (~6 GiB) for RandomX — p2pool's dataset
# plus monerod's verify cache. ONE definition: the sysctl write, the GRUB params and the local
# miner's declared headroom (hugepages_reserve_extra_mb in RigForge's config) all derive from it,
# so the reservation and the declaration cannot drift apart.
readonly PITHEAD_HUGEPAGES=3072

# The budget this MACHINE actually gets (#977). On the appliance, the boot-time sizing
# (os/overlay/pithead-hugepages) may have chosen a smaller pool for the fitted RAM and recorded
# the chosen page count as the marker's "pages=N" line — that record is the single authority
# every later writer honours: optimize_kernel caps its grow at it, and render_local_miner_config
# declares it (never the baked constant) as RigForge's headroom. Without the record both writers
# re-inflated the pool the sizing had just shrunk, while the marker and doctor kept saying
# "reduced". No marker — every DIY host, every healthy appliance — means the full budget.
hugepages_decision_pages() {
    local pages
    # || true: no marker means sed fails under pipefail, and that is the normal case everywhere
    # but a degraded appliance — it must read as "full budget", never abort under set -e.
    pages=$(sed -n 's/^pages=\([0-9][0-9]*\)$/\1/p' \
        "${PITHEAD_HUGEPAGES_MARKER:-/run/pithead-hugepages-degraded}" 2>/dev/null | head -n 1) || true
    if [ -n "$pages" ] && [ "$pages" -lt "$PITHEAD_HUGEPAGES" ]; then
        echo "$pages"
    else
        echo "$PITHEAD_HUGEPAGES"
    fi
}

# Kernel boot params pithead appends to GRUB_CMDLINE_LINUX_DEFAULT for RandomX: reserve 6 GiB of
# 2 MiB HugePages and disable Transparent HugePages. NOTE the THP param is SINGULAR
# (transparent_hugepage) — the plural form is an unrecognized param the kernel silently ignores,
# so THP would never actually be disabled (#176). Kept as a function so it has one definition and
# can be unit-tested for valid kernel param names.
randomx_boot_params() {
    echo "hugepagesz=2M hugepages=$PITHEAD_HUGEPAGES transparent_hugepage=never"
}

# Re-generate the bootloader config after a /etc/default/grub edit and flag that a reboot is needed.
# Warns (rather than failing) when update-grub isn't on PATH so the user can run it by hand.
apply_grub_update() {
    if command -v update-grub >/dev/null; then
        sudo update-grub
        REBOOT_REQUIRED=true
    else
        warn "'update-grub' not found. Please manually update your bootloader."
    fi
}

# Self-heal an earlier release's typo: the THP-disable kernel param is singular
# (transparent_hugepage); the plural form is silently ignored, so THP was never disabled (#176).
# Rewrites the plural token to the singular form in grub file $1. Returns 0 if it changed something,
# 1 if there was nothing to heal — so callers only re-run update-grub when needed. Idempotent: a
# no-op once the file already uses the singular form.
heal_grub_thp_typo() {
    local grub="$1"
    grep -q "transparent_hugepages=" "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed 's/transparent_hugepages=/transparent_hugepage=/g' "$grub"
}

# Append the RandomX boot params to the active GRUB_CMDLINE_LINUX_DEFAULT="..." line in grub file $1,
# preserving any leading indentation. Returns 0 on success, 1 when there's no active double-quoted
# line to edit — commented out, single-quoted, or absent — so the caller can warn instead of
# silently running update-grub and claiming a reboot is needed. The leading-^ anchor also ensures a
# commented-out example line is never edited.
append_grub_boot_params() {
    local grub="$1"
    grep -q '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT="' "$grub" || return 1
    sudo cp "$grub" "$grub.bak"
    sudo_sed "s/^\([[:space:]]*\)GRUB_CMDLINE_LINUX_DEFAULT=\"/\1GRUB_CMDLINE_LINUX_DEFAULT=\"$(randomx_boot_params) /" "$grub"
}

optimize_kernel() {
    if [ "$SKIP_OPTIMIZE" == "1" ]; then
        log "Skipping kernel/HugePages optimization (--skip-optimize)."
        return 0
    fi
    log "Applying RandomX optimizations (HugePages)..."
    if [ "$OS_TYPE" == "Linux" ]; then
        # Grow-only, never shrink: with a co-located RigForge miner the HugePages pool is shared,
        # and whoever writes an absolute value last steals the other side's pages — the kernel
        # shrinks the pool to the in-use floor and leaves zero headroom for a restart on either
        # side. RigForge's own write is grow-only for the same reason, so write ordering between
        # the two products stays safe regardless of who runs first. The grow TARGET is the
        # sizing decision, not the raw constant (#977): on a degraded appliance the wizard-accept
        # path runs setup as root, and growing to the full budget here re-inflated the pool the
        # boot-time sizing had just shrunk. No marker (DIY, healthy appliance) — full budget,
        # exactly the old behavior.
        local current_hugepages hp_target
        hp_target=$(hugepages_decision_pages)
        current_hugepages=$(cat "${PITHEAD_NR_HUGEPAGES_FILE:-/proc/sys/vm/nr_hugepages}" 2>/dev/null || echo 0)
        if [ "${current_hugepages:-0}" -ge "$hp_target" ] 2>/dev/null; then
            log "HugePages pool already holds $current_hugepages pages (>= $hp_target) — leaving it as is."
        else
            sudo sysctl -w vm.nr_hugepages="$hp_target"
        fi

        if [ -f "/etc/default/grub" ]; then
            # Heal an earlier release's invalid plural THP param if present (#176). Runs regardless of
            # the reservation guard below, which would otherwise see hugepages= and skip it forever.
            if heal_grub_thp_typo /etc/default/grub; then
                log "Corrected invalid THP kernel parameter in GRUB (transparent_hugepages -> transparent_hugepage)."
                apply_grub_update
            fi

            if ! grep -q "hugepages=" /etc/default/grub; then
                warn "Persistent HugePages requires editing /etc/default/grub and a reboot."
                if [ -t 0 ]; then
                    read -r -p "Modify GRUB for persistent HugePages now? (y/N): " GRUB_OK || true
                else
                    # Headless: never touch GRUB unattended, but say so — the old EOF-swallow
                    # skipped this silently and the operator never learned the reservation is
                    # boot-only.
                    GRUB_OK=""
                    warn "No terminal attached — skipping the persistent-HugePages GRUB change. Run '$0 setup' from a terminal (or edit /etc/default/grub) to make it permanent."
                fi
                if [[ ! "$GRUB_OK" =~ ^[Yy] ]]; then
                    log "Skipped GRUB edit. HugePages set for this boot only (vm.nr_hugepages=$PITHEAD_HUGEPAGES)."
                    return 0
                fi
                log "Updating GRUB configuration for persistent HugePages..."
                if append_grub_boot_params /etc/default/grub; then
                    apply_grub_update
                else
                    warn "No standard GRUB_CMDLINE_LINUX_DEFAULT=\"...\" line in /etc/default/grub — left it unchanged."
                    warn "Add these kernel params by hand, then run 'sudo update-grub' and reboot:"
                    warn "  $(randomx_boot_params)"
                fi
            else
                log "HugePages already configured in GRUB."
            fi
        fi
    else
        log "Skipping Host HugePages configuration (Not supported on $OS_TYPE)."
    fi
}

prompt_start_stack() {
    read -r -p "Start Pithead now? (Y/n): " START_NOW || true
    if [[ ! "$START_NOW" =~ ^[Nn] ]]; then
        stack_up
    else
        echo "You can start the stack later with: $0 up"
    fi
}

# Per-component free-disk requirement in GiB — the single source of truth for the stack's disk
# budget, shared by setup's preflight_resources and doctor's Disk check. Monero (the blockchain) is
# pruning-aware: ~120 GiB pruned, ~320 GiB full. Tari's chain is the other heavyweight — ~200 GiB and
# growing fast. Summed, this is ~330 GiB pruned / ~530 GiB full, the documented minimum
# (docs/hardware.md). These carry generous growth headroom over usage measured on live nodes
# (August 2026: Monero pruned ~100 GiB / full ~267 GiB, Tari ~149 GiB) because both chains grow
# ~100+ GiB/year combined — for a set-and-forget host the docs recommend a 2–4 TB drive.
# Args: <component> [<prune>] where prune (1 = on, 0 = off) only matters for "monero". Prints GiB.
disk_component_gib() {
    case "$1" in
    monero) if [ "${2:-1}" -eq 1 ] 2>/dev/null; then echo 120; else echo 320; fi ;;
    tari) echo 200 ;;
    p2pool) echo 5 ;;
    dashboard) echo 2 ;;
    tor) echo 1 ;;
    *) echo 0 ;;
    esac
}

# Resolve the filesystem mount point a (possibly not-yet-created) path lives on. Walks up to the
# nearest EXISTING ancestor — df needs a real path — then prints `df -P`'s mount point (field 6).
# Prints nothing (and returns non-zero) if no ancestor resolves, so callers can skip cleanly.
disk_fs_mount() {
    local p="$1"
    while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != "/" ]; do
        p=$(dirname "$p")
    done
    [ -n "$p" ] && [ -e "$p" ] || return 1
    df -P "$p" 2>/dev/null | awk 'NR==2{print $6}'
}

# Shared per-filesystem disk check used by BOTH preflight_resources and doctor. Treats the stack as
# ONE unit: groups the five data dirs by the filesystem they live on and checks each filesystem ONCE
# against the COMBINED requirement of the components that share it — so dirs on the same volume yield
# a single line (not one misleading "N GB free" line per dir). Read-only / never exits; a dir whose
# ancestor can't be resolved is skipped.
#
# Args: <mode> <prune> <monero_dir> <tari_dir> <p2pool_dir> <dashboard_dir> <tor_dir>
#   mode  = "doctor" (emit dr_ok/dr_warn) or "preflight" (emit warn only when under requirement)
#   prune = 1 (pruning on) / 0 (off); only affects the Monero requirement.
check_disk_grouped() {
    local mode="$1" prune="$2"
    shift 2
    local components=(monero tari p2pool dashboard tor)
    local dirs=("$@")

    # Group by mount point: accumulate required GiB and the component list per mount, and remember
    # one representative path per mount so we can read its free space once. Parallel arrays keyed by
    # a positional index (portable to Bash 3.2 on macOS — no associative arrays).
    local mounts=() req_gib=() comp_list=()
    local i mount comp gib idx
    for i in "${!components[@]}"; do
        comp="${components[$i]}"
        local dir="${dirs[$i]:-}"
        [ -n "$dir" ] || continue
        mount=$(disk_fs_mount "$dir") || continue
        [ -n "$mount" ] || continue
        gib=$(disk_component_gib "$comp" "$prune")

        # Find an existing group for this mount.
        idx=-1
        local j
        for j in "${!mounts[@]}"; do
            if [ "${mounts[$j]}" = "$mount" ]; then
                idx="$j"
                break
            fi
        done
        if [ "$idx" -lt 0 ]; then
            mounts+=("$mount")
            req_gib+=("$gib")
            comp_list+=("$comp")
        else
            req_gib[idx]=$((req_gib[idx] + gib))
            comp_list[idx]="${comp_list[idx]}, $comp"
        fi
    done

    if [ "${#mounts[@]}" -eq 0 ]; then
        [ "$mode" = "doctor" ] && dr_info "No data dirs resolved to a filesystem — skipping disk check."
        return 0
    fi

    # One result line per DISTINCT filesystem: read free space once, compare to the summed need.
    local need_kb avail_kb avail_h comps
    for i in "${!mounts[@]}"; do
        mount="${mounts[$i]}"
        comps="${comp_list[$i]}"
        need_kb=$((req_gib[i] * 1048576)) # GiB -> KiB (df -P is 1K-blocks)
        # df the resolved MOUNT POINT (always exists), not the data dir — on first run the dir isn't
        # created yet and `df` on a missing path fails the pipe, tripping `set -Eeuo pipefail` (#179).
        avail_kb=$(df -P "$mount" 2>/dev/null | awk 'NR==2{print $4}')
        avail_h=$(df -Ph "$mount" 2>/dev/null | awk 'NR==2{print $4}')
        if [ "$mode" = "doctor" ]; then
            if [ -n "$avail_kb" ] && [ "$avail_kb" -ge "$need_kb" ] 2>/dev/null; then
                dr_ok "Data on $mount ($comps): ${avail_h:-?} free — needs ~${req_gib[i]} GB."
            else
                dr_warn "Data on $mount ($comps): ${avail_h:-?} free — below the ~${req_gib[i]} GB the stack needs there."
            fi
        else
            if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$need_kb" ] 2>/dev/null; then
                warn "Low disk on $mount (hosts $comps): ${avail_h:-?} free, below the ~${req_gib[i]} GB the stack needs there — free space or move a data_dir to a larger volume."
            fi
        fi
    done
    return 0
}

# Pre-flight resource check (#87). Best-effort, WARN-only: catch the most demoralizing first-run
# failure — an undersized host that fills its disk mid-sync — before we commit to a sync. Never
# blocks or exits: a missing path or unreadable file just skips that check. Call after
# parse_and_validate_config has resolved the data dirs, before starting the stack.
preflight_resources() {
    # Pruning is on unless config explicitly sets monero.prune:false (same derivation as render_env).
    local prune
    prune=$(monero_prune_flag)

    # --- Disk: free space per underlying filesystem ---
    # Treat the stack as one unit: group all five data dirs by the filesystem they live on and warn
    # once per volume that can't hold the combined requirement of the components sharing it (so dirs
    # on the same disk produce a single line, not one per dir). check_disk_grouped is WARN-only here.
    # A remote node (#103) keeps its chain elsewhere: blank its dir so the ~120 GiB (Monero) /
    # ~200 GiB (Tari) budget isn't demanded of THIS host — small disks are exactly why an operator
    # goes remote. check_disk_grouped skips empty dirs.
    local pre_mono_dir="${MONERO_DIR:-}" pre_tari_dir="${TARI_DIR:-}"
    [ "$MONERO_MODE" == "remote" ] && pre_mono_dir=""
    [ "$TARI_MODE" == "remote" ] && pre_tari_dir=""
    check_disk_grouped preflight "$prune" \
        "$pre_mono_dir" "$pre_tari_dir" "${P2POOL_DIR:-}" "${DASHBOARD_DIR:-}" "${TOR_DATA_DIR:-}"

    # --- RAM: total memory (Linux only — /proc/meminfo isn't available on macOS dev hosts) ---
    if [ "$OS_TYPE" == "Linux" ]; then
        local mem_total_kb
        mem_total_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
        # 16 GiB in KiB.
        if [ -n "$mem_total_kb" ] && [ "$mem_total_kb" -lt 16777216 ] 2>/dev/null; then
            local mem_total_gb
            mem_total_gb=$((mem_total_kb / 1048576))
            warn "Low total RAM: ${mem_total_gb} GB detected, below the recommended ~16 GB. The stack (Tari especially) may be memory-starved during sync."
        fi
    fi

    return 0
}

# --- Top-level Commands ---

setup() {
    if is_deployed; then
        warn "A previous deployment was detected."
        # An interactive ask with no terminal is an EOF, and `read`'s `|| true` used to swallow
        # that into an empty answer — read as decline, exit 0: a headless caller believed setup
        # succeeded while nothing ran (#924's silent false success). Headless now REFUSES loudly
        # instead of proceeding: an unattended re-provision (Tor container recreate, full
        # re-render, a possible GRUB edit) must never ride on the mere absence of a terminal —
        # `pithead setup` has long been a safe probe on a deployed box for cron/automation, and
        # the appliance's own headless paths never reach this branch (a failed provisioning
        # attempt is not deployed). A real terminal keeps the prompt exactly as before.
        if [ -t 0 ]; then
            local RERUN
            read -r -p "Re-run setup (re-provisions Tor and may modify GRUB)? (y/N): " RERUN || true
            if [[ ! "$RERUN" =~ ^[Yy] ]]; then
                log "Setup skipped. Edit config.json and run '$0 apply' to propagate config changes,"
                log "or '$0 up' to start the stack."
                exit 0
            fi
        else
            error "Already provisioned, and re-running setup re-provisions Tor and may modify GRUB — run '$0 setup' from a terminal to confirm that. For configuration changes use '$0 apply'; to start the stack use '$0 up'."
        fi
    fi

    # After the re-run prompt above, so the hold never spans a human wait. The firstboot
    # wizard runs `(setup)` in a subshell (#1059), so this IS the wizard's hold and it is not one
    # line wider than the provisioning itself — the loop's wait for a submitted form is outside it.
    mutation_lock_acquire setup

    check_prerequisites
    ensure_config_exists
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one
    parse_and_validate_config
    preflight_resources          # WARN-only: low disk/RAM heads-up before committing to a sync (#87)
    check_stratum_exposure setup # WARN-only: public-IP host => unauthenticated stratum :3333 exposed (#113)
    load_preserved_state
    resolve_dashboard_host "interactive"
    prepare_directories
    render_env    # bootstrap .env so Tor (and compose var substitution) have what they need
    provision_tor # populates the real onion addresses
    DEPLOYMENT_COMPLETED=true
    render_env # finalize with real onions + completion flag
    inject_service_configs
    optimize_kernel
    generate_caddyfile
    provision_control_runner  # #33: install/remove the dashboard-control systemd trigger
    render_local_miner_config # #796: the appliance's built-in RigForge worker reads a derived config
    update_current_symlink    # #455: versioned deploy dir -> maintain the `current ->` pointer

    log "Deployment preparation complete!"
    # Provisioning is done. Everything below is either a message or an interactive "start now?",
    # so the hold ends here; the stack_up it may call takes its own.
    mutation_lock_release
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n${C_YELLOW}[!] ATTENTION: System optimization requires a reboot.${C_RESET}"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 up'"
    else
        prompt_start_stack
        # The miner leg comes AFTER the stack: it points at the stack's own stratum, and
        # RigForge starts the service it installs. Appliance-only inside; best-effort — a
        # miner that cannot start must not fail provisioning of the stack that just did.
        provision_local_miner || true
    fi
}

# Describe a changed env key for the apply preview. Prints "FLAG\tmessage" where FLAG is
# DEST (disruptive — apply should confirm) or INFO. Always returns 0 (safe in $()).
describe_change() {
    local key="$1" old="$2" new="$3" flag="INFO" msg
    case "$key" in
    MONERO_PRUNE)
        # #719: ENABLE (off → on) is confirm-gated — it reclaims disk by pruning blocks, an
        # operator-intent op with an expensive-but-recoverable cost. DISABLE (on → off) stays a
        # host-only DEST: pruned data can't be restored, so it needs a full re-sync from a shell.
        case "$new" in
        true | 1)
            flag=CONFIRM
            msg="Monero pruning ENABLED ($old → $new) — prunes existing blocks to reclaim disk; monerod is recreated. Restoring the full chain later needs a wipe + re-sync."
            ;;
        *)
            flag=DEST
            msg="Monero pruning DISABLED ($old → $new) — pruned data can't be restored, so the full chain must RE-SYNC from scratch. Apply this from the host."
            ;;
        esac
        ;;
    COMPOSE_PROFILES)
        # #552: COMPOSE_PROFILES also carries payout_confirm/tari_payout_confirm (#381/#462) and
        # local_tari (#103), so an empty-vs-non-empty check misreads those toggles as a node switch.
        # Decide by presence of the local_node / local_tari tokens instead — only a real flip of
        # either token is a node switch (DEST). Monero is checked first; a same-apply flip of BOTH
        # nodes is rare and either message alone is enough to make the change obvious.
        local old_local=false new_local=false old_tari_local=false new_tari_local=false
        case ",$old," in *,local_node,*) old_local=true ;; esac
        case ",$new," in *,local_node,*) new_local=true ;; esac
        case ",$old," in *,local_tari,*) old_tari_local=true ;; esac
        case ",$new," in *,local_tari,*) new_tari_local=true ;; esac
        if [ "$old_local" = false ] && [ "$new_local" = true ]; then
            flag=DEST
            msg="Switching to a LOCAL Monero node — monerod will start and SYNC the blockchain (large download / disk use)."
        elif [ "$old_local" = true ] && [ "$new_local" = false ]; then
            flag=DEST
            msg="Switching to a REMOTE Monero node — the local monerod container will be STOPPED and removed (its on-disk data is kept)."
        elif [ "$old_tari_local" = false ] && [ "$new_tari_local" = true ]; then
            flag=DEST
            msg="Switching to a LOCAL Tari node — the tari container will start and SYNC the chain (large download / disk use)."
        elif [ "$old_tari_local" = true ] && [ "$new_tari_local" = false ]; then
            flag=DEST
            msg="Switching to a REMOTE Tari node — the local tari container will be STOPPED and removed (its on-disk data is kept)."
        else
            msg="Payout confirmation profile changed ($old → $new)."
        fi
        ;;
    MONERO_WALLET_ADDRESS)
        flag=DEST
        msg="Monero payout address is changing — future mining rewards go to the new address."
        ;;
    TARI_WALLET_ADDRESS)
        flag=DEST
        msg="Tari payout address is changing — future merge-mining rewards go to the new address."
        ;;
    MONERO_RPC_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Monero RPC will be EXPOSED on your LAN ($old → $new) — make sure this is intended."
        else
            msg="Monero RPC bind address: $old → $new."
        fi
        ;;
    MONERO_ZMQ_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Monero ZMQ will be EXPOSED on your LAN ($old → $new) — it has no auth, trusted networks only."
        else
            msg="Monero ZMQ bind address: $old → $new."
        fi
        ;;
    TARI_GRPC_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="Tari gRPC will be EXPOSED on your LAN ($old → $new) — it is plaintext and unauthenticated, trusted networks only."
        else
            msg="Tari gRPC bind address: $old → $new."
        fi
        ;;
    STRATUM_BIND)
        if [ "$new" == "0.0.0.0" ]; then
            flag=DEST
            msg="The stratum port will be published on ALL interfaces ($old → $new) — keep it firewalled to your LAN."
        else
            msg="Stratum bind address: $old → $new (workers must reach this address)."
        fi
        ;;
    STRATUM_PORT)
        if [ -z "$old" ]; then
            # First render of the key (upgrade from a pre-#172 .env) — the port isn't changing.
            msg="Stratum port recorded (:$new) — no rig change needed."
        else
            # #719: confirm-gated — repointing every rig is disruptive but operator-intent, not a
            # breach; the typed confirmation makes the operator acknowledge the fleet-wide repoint.
            flag=CONFIRM
            msg="Stratum port: $old → $new — EVERY RIG must repoint at the new port (RigForge: pool.port) or it can't connect; the xmrig-proxy container is recreated."
        fi
        ;;
    PROXY_STRATUM_TLS)
        if [ "$new" = "true" ]; then
            msg="Stratum TLS ENABLED — the proxy serves TLS and cleartext on the same port; rigs opt in by pinning the cert fingerprint (shown after apply). xmrig-proxy is recreated."
        else
            msg="Stratum TLS DISABLED — rigs with pools[].tls:true will fail to connect until switched back to cleartext. xmrig-proxy is recreated."
        fi
        ;;
    PROXY_TLS_DIR)
        msg="Stratum TLS keypair directory: $old → $new — the cert (and its pinned fingerprint) does NOT move with it; rigs re-pin if a new cert is generated."
        ;;
    PROXY_STRATUM_PASSWORD)
        # Secret — never echo the value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Stratum access-password DISABLED — any rig that can reach :3333 may mine again."
        elif [ -z "$old" ]; then
            flag=DEST
            # The DIY hint points at .env / 'status' to recover an auto-generated password; the
            # appliance has neither a shell nor a dashboard surface that reveals a secret value
            # (#33's own trust boundary — masked config never round-trips a secret to the
            # container), so there is no remedy to name here. Drop the instruction rather than
            # invent one (#1139).
            if is_appliance; then
                msg="Stratum access-password ENABLED — rigs must now send the matching 'pass' or they're rejected; the xmrig-proxy container is recreated."
            else
                msg="Stratum access-password ENABLED — rigs must now send the matching 'pass' (find it in .env / './pithead status') or they're rejected; the xmrig-proxy container is recreated."
            fi
        else
            flag=DEST
            msg="Stratum access-password CHANGED — update every rig's 'pass' to match or they're rejected; the xmrig-proxy container is recreated."
        fi
        ;;
    PROXY_DONATE_LEVEL)
        msg="xmrig-proxy dev-fee donation level: ${old:-0}% → ${new}% — the xmrig-proxy container is recreated (brief restart)."
        ;;
    DASHBOARD_DATA_DIR)
        # #719: confirm-gated — a data-dir move is operator-intent (an expensive re-home / re-sync),
        # not a security boundary. Only the four service data dirs below are in scope.
        flag=CONFIRM
        msg="$key: $old → $new — data at the old DEFAULT location (./data/dashboard) is moved there automatically; any other old path is left in place."
        ;;
    MONERO_DATA_DIR | TARI_DATA_DIR | P2POOL_DATA_DIR)
        # #719: confirm-gated data-dir moves — the service re-syncs from the new (empty) dir.
        flag=CONFIRM
        msg="$key: $old → $new — the service will use the new (empty) directory and RE-SYNC from scratch; old data is left in place."
        ;;
    *_DATA_DIR)
        # Every OTHER data dir (e.g. TOR_DATA_DIR) stays host-only — not in the #719 in-scope set.
        flag=DEST
        msg="$key: $old → $new — the service will use the new (empty) directory and re-sync; old data is left in place."
        ;;
    P2POOL_FLAGS | P2POOL_PORT)
        msg="P2Pool sidechain changing ($key: '$old' → '$new') — p2pool re-syncs the new sidechain and your PPLNS window resets."
        ;;
    MONERO_NODE_HOST | MONERO_RPC_PORT | MONERO_ZMQ_PORT)
        msg="Monero node endpoint ($key): $old → $new."
        ;;
    MONERO_NODE_USERNAME | MONERO_NODE_PASSWORD)
        msg="Monero node RPC credential updated ($key)."
        ;;
    XVB_ENABLED | XVB_POOL_URL | XVB_DONOR_ID | XVB_DONATION_LEVEL)
        msg="XMRvsBeast setting ($key): $old → $new."
        ;;
    TARI_REQUIRED)
        if [ "$new" == "true" ]; then
            msg="Tari → required — a Tari outage rejects workers, the miner waits for Tari's sync, and a Tari-only sync takes over the dashboard."
        else
            msg="Tari → non-blocking — keep mining Monero through a Tari outage, start as soon as Monero is synced, and keep the operational dashboard while Tari syncs."
        fi
        ;;
    DASHBOARD_FAIL_CLOSED)
        if [ "$new" == "true" ]; then
            msg="Fail-closed ENABLED — an unrecoverable dashboard health failure (DB recovery itself failing, or the dashboard container crash-looping) now HOLDS p2pool and xmrig-proxy until it clears, instead of only alerting."
        else
            msg="Fail-closed DISABLED — an unrecoverable dashboard health failure now only alerts (Telegram/Healthchecks + badge); mining is never held for it."
        fi
        ;;
    DASHBOARD_CHECK_UPDATES)
        if [ "$new" == "true" ]; then
            msg="Dashboard update check ENABLED — the dashboard will check GitHub (over Tor) for a newer release and show a link badge; the dashboard container is recreated."
        else
            msg="Dashboard update check DISABLED — the dashboard no longer contacts GitHub; the dashboard container is recreated."
        fi
        ;;
    TARI_MEM_LIMIT)
        msg="Tari memory cap: $old → $new — the tari container is recreated (brief restart; on-disk chain data is preserved)."
        ;;
    MONERO_MEM_LIMIT)
        msg="Monero memory cap: $old → $new — the monerod container is recreated (brief restart; the blockchain on disk is preserved)."
        ;;
    DASHBOARD_SECURE)
        msg="Dashboard scheme → $([ "$new" == "true" ] && echo HTTPS || echo HTTP) (secure=$new)."
        ;;
    DASHBOARD_AUTH_HASH_B64)
        # Secret — never echo the hash into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Dashboard login DISABLED — the dashboard is reachable without a password again."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Dashboard login ENABLED — Caddy now requires the configured username/password; the caddy container is recreated."
        else
            flag=DEST
            msg="Dashboard login password CHANGED — use the new credentials; the caddy container is recreated."
        fi
        ;;
    DASHBOARD_AUTH_USER)
        msg="Dashboard login username: $old → $new."
        ;;
    DASHBOARD_AUTH_PW_FP)
        # Internal fingerprint — always co-changes with DASHBOARD_AUTH_HASH_B64, which already
        # carries the user-facing message. Emit no message so the preview shows one line, not two.
        msg=""
        ;;
    DASHBOARD_CONTROL_ENABLED)
        if [ "$new" == "true" ]; then
            flag=DEST
            msg="Dashboard configuration editing ENABLED — the dashboard can stage config changes that a host-side runner validates and applies; the dashboard container is recreated."
        else
            msg="Dashboard configuration editing disabled — the control runner units are removed; the dashboard container is recreated."
        fi
        ;;
    CLEARNET_STATE_DIR | CONTROL_DIR | CADDY_LOG_DIR)
        # Fixed paths under ./data — internal, change only when the checkout moves (#695).
        msg=""
        ;;
    DASHBOARD_ONION_ENABLED)
        flag=DEST
        if [ "$new" == "true" ]; then
            msg="Dashboard Tor onion ENABLED — the dashboard is published as a hidden service reachable over Tor; tor and caddy are recreated."
        else
            msg="Dashboard Tor onion DISABLED — the onion is withdrawn; tor and caddy are recreated."
        fi
        ;;
    DASHBOARD_ONION_CLIENT_AUTH)
        msg="Dashboard onion client-auth → $([ "$new" == "true" ] && echo ON || echo OFF)$([ "$new" == "true" ] && echo " — the onion won't respond without your client key" || echo " — the onion is password-only")."
        ;;
    DASHBOARD_ONION_ADDRESS | DASHBOARD_ONION_CLIENT_PUBKEY)
        # Provisioned values that co-change with the toggle above; keep the preview to one line.
        msg=""
        ;;
    DASHBOARD_ONION_CLIENT_PRIVKEY)
        # Secret client key — never echo it into the change preview / logs.
        msg=""
        ;;
    HOST_IP)
        msg="Dashboard hostname: $old → $new."
        ;;
    HOST_PORT)
        # #740: Caddy's LAN listen port. Empty means the scheme default (443/80). Stay silent when
        # both sides are empty — a fresh binary just adds the key with no value on the first apply
        # (comm flags the added line); that is not a real change worth previewing.
        if [ -z "$old" ] && [ -z "$new" ]; then
            msg=""
        else
            msg="Dashboard Caddy port: ${old:-default (443/80)} → ${new:-default (443/80)} — the caddy container is recreated."
        fi
        ;;
    MONERO_PREP_THREADS)
        msg="Monero block-prep threads: $old → $new."
        ;;
    MONERO_OUT_PEERS)
        # Confirm-gated (2026-08 security review): bounded 8-1024 and instantly reversible, but
        # the biggest steady-state knob on the shared Tor daemon's CPU — one typed confirm, not
        # free-commit.
        flag=CONFIRM
        msg="Monero outbound peer target: $old → $new — monerod restarts; over Tor each outbound peer is roughly one circuit."
        ;;
    HEALTHCHECKS_PING_URL)
        # The ping URL is both the on/off switch and a capability secret — report the change
        # (enable/disable/update) WITHOUT printing the value.
        if [ -z "$new" ]; then
            msg="Healthchecks.io dead-man's switch DISABLED — ping URL cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="Healthchecks.io dead-man's switch ENABLED — ping URL set (pings over Tor); the dashboard container is recreated."
        else
            msg="Healthchecks.io ping URL updated — the dashboard container is recreated."
        fi
        ;;
    TOR_AUTO_HEAL)
        if [ "$new" == "true" ]; then
            msg="Tor guard self-heal ENABLED — when clearnet egress through Tor stays broken for 15 min (a failing guard), the dashboard restarts the tor container to pick fresh guards (max 3 restarts per outage, 30-min cooldown; each restart drops ALL Tor circuits, mining onions included, which then rebuild); the dashboard container is recreated."
        # The DIY fix names 'doctor' + a scoped tor restart, both CLI-only; the appliance has no
        # shell to run either from, and there is no dashboard control that restarts tor alone
        # (#1139) — so this side just states the fact instead of a remedy it cannot offer.
        elif is_appliance; then
            msg="Tor guard self-heal DISABLED — a stuck guard is back to WARN-only, with no dashboard control to restart Tor manually; the dashboard container is recreated."
        else
            msg="Tor guard self-heal DISABLED — a stuck guard is back to WARN-only ('./pithead doctor', fix with './pithead restart tor'); the dashboard container is recreated."
        fi
        ;;
    TELEGRAM_ENABLED)
        msg="Telegram operator bot → $([ "$new" == "true" ] && echo on || echo off) — the dashboard container is recreated."
        ;;
    TELEGRAM_BOT_TOKEN)
        # Secret — never echo the token value into the change preview / logs.
        msg="Telegram bot token updated — the dashboard container is recreated."
        ;;
    TELEGRAM_CHAT_ID)
        msg="Telegram chat id: $old → $new."
        ;;
    TELEGRAM_COMMANDS_ENABLED)
        msg="Telegram command interface → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now answers" || echo "no longer answers") /status, /hashrate, /workers, /sync from the configured chat; the dashboard container is recreated."
        ;;
    TELEGRAM_CONTROL_ENABLED)
        msg="Telegram control commands → $([ "$new" == "true" ] && echo on || echo off) — the bot $([ "$new" == "true" ] && echo "now accepts" || echo "no longer accepts") /restart and /apply from allow-listed operator ids, each with an in-chat confirmation; the dashboard container is recreated."
        ;;
    TELEGRAM_CONTROL_ALLOWED_IDS)
        # Telegram user ids are not secret, but they are the control-command allow-list — report the change.
        msg="Telegram control allow-list: [$old] → [$new] — only these operator user ids may run /restart or /apply."
        ;;
    TELEGRAM_CONTROL_CONFIRM_S)
        msg="Telegram control confirmation timeout: ${old}s → ${new}s — an unconfirmed control command is denied after this."
        ;;
    TELEGRAM_EVENT_*)
        msg="Telegram alert toggle ($key): $old → $new."
        ;;
    TELEGRAM_DAILY_SUMMARY_TIME)
        msg="Telegram daily summary time: $old → $new (local time)."
        ;;
    NOTIFY_WEBHOOK_URLS)
        # Webhook URLs often carry tokens in the query string — report the change WITHOUT
        # printing the values (same rule as HEALTHCHECKS_PING_URL).
        if [ -z "$new" ]; then
            msg="Webhook alert sink(s) DISABLED — URL list cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="Webhook alert sink(s) ENABLED — every alert now also POSTs as JSON to the configured URL(s), over Tor by default; the dashboard container is recreated."
        else
            msg="Webhook alert URL(s) updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_URL)
        # The topic URL is a capability secret (whoever knows it can read/post the topic) —
        # never print it.
        if [ -z "$new" ]; then
            msg="ntfy alert sink DISABLED — topic URL cleared; the dashboard container is recreated."
        elif [ -z "$old" ]; then
            msg="ntfy alert sink ENABLED — every alert now also POSTs to the configured ntfy topic, over Tor by default; the dashboard container is recreated."
        else
            msg="ntfy topic URL updated — the dashboard container is recreated."
        fi
        ;;
    NTFY_TOKEN)
        # Secret — never echo the token value into the change preview / logs.
        msg="ntfy access token updated — the dashboard container is recreated."
        ;;
    NOTIFY_TOR)
        if [ "$new" == "true" ]; then
            msg="Webhook/ntfy alerts back on Tor — endpoints see a Tor exit, not this host's IP; the dashboard container is recreated."
        else
            msg="⚠ Webhook/ntfy alerts OFF Tor — POSTs go out directly, so clearnet endpoints see this host's IP (the LAN/self-hosted carve-out; Tor exits can't reach private addresses); the dashboard container is recreated."
        fi
        ;;
    MONERO_CLEARNET_SYNC)
        # #183/#719: ENABLING exposes the host IP during IBD (auto-reverts to Tor) — confirm-gated
        # (CONFIRM), not host-only. DISABLING returns to Tor, a plain INFO change.
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ Monero CLEARNET initial sync ENABLED — monerod P2P will run over CLEARNET (this host's IP becomes visible to the Monero P2P network) so the chain syncs fast. Transaction broadcast STAYS on Tor; wallets are never exposed. The dashboard switches monerod back to Tor automatically once the chain is synced. monerod is recreated."
        else
            msg="Monero clearnet sync DISABLED — monerod P2P returns to Tor-only. monerod is recreated."
        fi
        ;;
    TARI_CLEARNET_SYNC)
        # #183/#719: ENABLING exposes the host IP during IBD (auto-reverts to Tor) — confirm-gated.
        if [ "$new" == "true" ]; then
            flag=CONFIRM
            msg="⚠ Tari CLEARNET initial sync ENABLED — the Tari base node will sync over CLEARNET (TCP transport + seeds.tari.com DNS seed; this host's IP becomes visible to the Tari P2P network) so its large chain syncs fast. The dashboard switches Tari back to Tor automatically once the chain is synced. tari is recreated."
        else
            msg="Tari clearnet sync DISABLED — the Tari base node returns to Tor-only transport. tari is recreated."
        fi
        ;;
    MONERO_VIEW_KEY)
        # Secret (#381): the private view key reveals every incoming payout amount/time — never
        # echo its value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Payout confirmation view key CLEARED — the view-only wallet-rpc is removed."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Payout confirmation view key SET — a view-only monero-wallet-rpc starts and scans the local node for confirmed payouts (it can see incoming amounts, never spend)."
        else
            flag=DEST
            msg="Payout confirmation view key CHANGED — the view-only wallet-rpc is recreated and rescans."
        fi
        ;;
    WALLET_RPC_PASSWORD)
        # Secret (#381): auto-generated wallet-rpc login — never echo the value.
        msg="Payout wallet-rpc credential updated."
        ;;
    PAYOUT_CONFIRM_ENABLED)
        msg="On-chain payout confirmation → $([ "$new" == "true" ] && echo on || echo off)."
        ;;
    PAYOUT_SCAN_HEIGHT)
        msg="Payout wallet restore height: $old → $new — only affects a first-time wallet creation."
        ;;
    WALLET_RPC_USERNAME | MONERO_WALLET_RPC_URL)
        # Fixed internal values that co-change with the view key toggle; keep the preview to one line.
        msg=""
        ;;
    TARI_VIEW_KEY)
        # Secret (#462): the Tari private view key reveals every incoming payout amount/time — never
        # echo its value into the change preview / logs.
        if [ -z "$new" ]; then
            msg="Tari payout confirmation view key CLEARED — the view-only tari-wallet is removed."
        elif [ -z "$old" ]; then
            flag=DEST
            msg="Tari payout confirmation view key SET — a view-only minotari_console_wallet starts and scans the local Tari node for confirmed payouts (it can see incoming amounts, never spend)."
        else
            flag=DEST
            msg="Tari payout confirmation view key CHANGED — the view-only tari-wallet is recreated and rescans."
        fi
        ;;
    TARI_WALLET_PASSWORD)
        # Secret (#462): auto-generated wallet-DB password — never echo the value.
        msg="Tari payout wallet credential updated."
        ;;
    TARI_PAYOUT_CONFIRM_ENABLED)
        msg="Tari on-chain payout confirmation → $([ "$new" == "true" ] && echo on || echo off)."
        ;;
    TARI_WALLET_BIRTHDAY)
        msg="Tari payout wallet birthday: $old → $new (days since the Unix epoch) — only affects a first-time wallet creation."
        ;;
    TARI_SPEND_PUBLIC_KEY | TARI_WALLET_GRPC_ADDRESS | TARI_WALLET_SECRET_FILE)
        # Public/fixed internal values that co-change with the Tari view key toggle; keep to one line.
        msg=""
        ;;
    *)
        msg="$key: $old → $new."
        ;;
    esac
    printf '%s\t%s' "$flag" "$msg"
}

# Preview what `apply` would change without touching .env, generated files, or containers (#33).
# Runs apply's own render-and-diff preamble against a throwaway staging file, prints the same
# describe_change preview, and stops before the commit. --porcelain prints machine-readable
# "FLAG<TAB>KEY<TAB>MSG" lines for the control runner. Progress logs go to stderr so stdout
# carries only the preview. Reads $CONFIG_FILE, so PITHEAD_CONFIG_FILE can point one invocation
# at a staged candidate config.
apply_dry_run() {
    local porcelain="$1"
    local newenv="${ENV_FILE}.dryrun"
    PITHEAD_DRY_RUN=1 # #556: parse_and_validate_config -> persist_node_credentials checks this
    {
        # NOTE: no ensure_onion_password here — it would write an auto-generated password into
        # the candidate config. A dry run must only read; an invalid candidate fails validation.
        parse_and_validate_config
        load_preserved_state
        # P2Pool's onion is the provisioning marker (see apply) — a node's may be a placeholder.
        if onion_missing "$P2POOL_ONION" || ! is_deployed; then
            error "Stack is not fully provisioned. Run '$0 setup' first."
        fi
        resolve_dashboard_host # non-interactive
        DEPLOYMENT_COMPLETED=true
        render_env "$newenv"
    } >&2

    local changed=() key old new line flag msg
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    if [ "${#changed[@]}" -eq 0 ]; then
        [ "$porcelain" -eq 0 ] && log "No configuration changes detected."
        rm -f "$newenv"
        return 0
    fi
    for key in "${changed[@]}"; do
        old=$(env_get_file "$ENV_FILE" "$key")
        new=$(env_get_file "$newenv" "$key")
        line=$(describe_change "$key" "$old" "$new")
        flag=${line%%$'\t'*}
        msg=${line#*$'\t'}
        [ -z "$msg" ] && continue # internal-only keys stay silent, same as apply
        if [ "$porcelain" -eq 1 ]; then
            printf '%s\t%s\t%s\n' "$flag" "$key" "$msg"
        elif [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
            # #719: CONFIRM is disruptive on the host too — warn, same as DEST.
            echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
        else
            echo "  • ${msg}"
        fi
    done
    rm -f "$newenv"
}

# Regenerate every DERIVED file — .env, Caddyfile, service configs, host units — from
# config.json plus THIS program, touching no containers. The appliance's boot path runs this
# every boot (#790): derived files must never outlive the program that rendered them, and an
# A/B update swaps the whole program, so the derived layer is rebuilt by construction instead
# of inspected for staleness. Same preservation guarantees as apply: load_preserved_state
# keeps Tor onions, RPC credentials and the proxy token across the rewrite.
render_derived() {
    require_env
    ensure_onion_password
    parse_and_validate_config
    load_preserved_state
    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true
    render_env "$ENV_FILE"
    provision_node_onions
    inject_service_configs
    generate_caddyfile
    provision_onion_client_auth
    provision_control_runner
    provision_ssh_access
    provision_console_login
    render_local_miner_config
    log "Derived configuration regenerated from config.json."
}

apply() {
    # apply reaches its mutating window down two different paths (a normal change, and the retry
    # after a previous apply committed the config but did not finish recreating containers), so it
    # tracks its own hold rather than acquiring twice — the depth counter would then never reach
    # zero and the lock would outlive the verb inside a single process.
    local lock_held=0
    local assume_yes=0 dry_run=0 porcelain=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --dry-run) dry_run=1 ;;
        --porcelain) porcelain=1 ;;
        *) error "Unknown option for apply: $arg. Run '$0 help'." ;;
        esac
    done
    [ "$porcelain" -eq 1 ] && [ "$dry_run" -eq 0 ] && error "--porcelain only makes sense with --dry-run."

    require_env
    if [ "$dry_run" -eq 1 ]; then
        apply_dry_run "$porcelain"
        return 0
    fi
    ensure_onion_password # #343: auto-generate a dashboard password if the onion is on without one
    parse_and_validate_config
    load_preserved_state
    # P2Pool's onion is the provisioning marker, not Monero's: p2pool always runs, while a node's
    # onion is legitimately a placeholder in remote mode (#103).
    if onion_missing "$P2POOL_ONION" || ! is_deployed; then
        error "Stack is not fully provisioned. Run '$0 setup' first."
    fi

    ensure_directories
    resolve_dashboard_host # non-interactive
    DEPLOYMENT_COMPLETED=true

    # Render the new config to a staging file and diff it against the live .env, so we can
    # preview the changes and confirm anything disruptive before touching running containers.
    local newenv="${ENV_FILE}.new"
    render_env "$newenv"

    local changed=() key
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    # A marker left by a previous apply whose `docker compose up` failed AFTER the new config was
    # committed (#125): the stack then runs OLD containers against NEW config files, and because a
    # re-apply diffs the (already-committed) .env it would see no change and silently no-op. While
    # the marker is present, re-apply re-attempts the recreate even when the rendered config matches.
    local apply_marker="${ENV_FILE}.apply-incomplete" incomplete=0
    [ -f "$apply_marker" ] && incomplete=1

    local destructive=0 caddy_changed=0 caddy_before="" caddy_had=0 wallet_keys=() line flag msg old new
    if [ "${#changed[@]}" -gt 0 ]; then
        echo ""
        log "The following changes will be applied:"
        for key in "${changed[@]}"; do
            old=$(env_get_file "$ENV_FILE" "$key")
            new=$(env_get_file "$newenv" "$key")
            # Payout-wallet change (#375): remember WHICH wallet keys change for the typed
            # confirmation below — one prompt per key, so a Monero+Tari double change can't
            # ride through on a single typed prefix.
            case "$key" in MONERO_WALLET_ADDRESS | TARI_WALLET_ADDRESS) wallet_keys+=("$key") ;; esac
            line=$(describe_change "$key" "$old" "$new")
            flag=${line%%$'\t'*}
            msg=${line#*$'\t'}
            [ -z "$msg" ] && continue # internal-only keys (e.g. the auth fingerprint) stay silent
            # CONFIRM (#719) is the dashboard's confirm-gated class, but on the HOST CLI it is just
            # as disruptive as DEST — warn and fold it into the y/N confirmation, same as before.
            if [ "$flag" == "DEST" ] || [ "$flag" == "CONFIRM" ]; then
                echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
                destructive=1
            else
                echo "  • ${msg}"
            fi
        done
        echo ""

        if [ "${#wallet_keys[@]}" -gt 0 ] && [ "$assume_yes" -eq 0 ]; then
            # A payout-wallet change upgrades the generic y/N to a typed confirmation (#375):
            # every future reward goes to the new address, so the operator must type its first
            # 8 characters — once PER changed wallet key (a Monero and a Tari change are two
            # separate redirects; each needs its own typed confirm). This is the strongest
            # confirm, so it stands in for the y/N even when other disruptive changes ride
            # along. --yes keeps working for automation.
            local wkey wnew wallet_new8 wlabel
            for wkey in "${wallet_keys[@]}"; do
                wnew=$(env_get_file "$newenv" "$wkey")
                wallet_new8="${wnew:0:8}" # never the full address — previews and prompts stay truncated
                [ "$wkey" == "MONERO_WALLET_ADDRESS" ] && wlabel="Monero" || wlabel="Tari"
                warn "The $wlabel payout wallet address is changing — ALL future $wlabel rewards go to the new address."
                warn "Confirm by typing the first 8 characters of the new address ($wallet_new8)."
                read -r -p "Confirm: " CONFIRM || true
                if [ "$CONFIRM" != "$wallet_new8" ]; then
                    rm -f "$newenv"
                    log "Apply cancelled. No changes were made."
                    return 0
                fi
            done
        elif [ "$destructive" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
            warn "Some of the changes above (⚠) are disruptive."
            read -r -p "Proceed with applying these changes? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                rm -f "$newenv"
                log "Apply cancelled. No changes were made."
                return 0
            fi
        fi

        # After every confirm above (the typed wallet redirect, the disruptive-change y/N):
        # committing the rendered .env is where apply starts mutating.
        mutation_lock_acquire apply
        lock_held=1
        mv "$newenv" "$ENV_FILE"
        provision_node_onions # #103: a node that just went local needs its onion before it starts
        inject_service_configs
        # Whether caddy needs a restart is decided by COMPARING the rendered file, never by a list
        # of keys someone has to remember to extend (#1052). The list had drifted:
        # dashboard.expose_public_ip was missing from it, so turning OFF the opt-in that serves the
        # dashboard on a globally-routable address re-rendered the Caddyfile without its bind lines
        # and left caddy holding the wildcard listener — the operator sees the setting saved, sees
        # the file change, and the box stays exposed.
        #
        # An absent previous file is a fresh install: compose starts caddy on the new one below, so
        # there is no old configuration to displace. Emptiness is not absence — a zero-byte file
        # left by a crashed render is a box whose caddy serves nothing, and that wants the restart.
        if [ -f "Caddyfile" ]; then
            caddy_had=1
            caddy_before=$(cat "Caddyfile")
        fi
        generate_caddyfile
        if [ "$caddy_had" -eq 1 ] && [ "$caddy_before" != "$(cat "Caddyfile" 2>/dev/null)" ]; then
            caddy_changed=1
        fi
    else
        rm -f "$newenv"
        if [ "$incomplete" -eq 0 ]; then
            # #33: converge the control-runner units BEFORE returning. A box whose units point at
            # a dead install has an unchanged config by definition — the fault is in the unit
            # files, not config.json — so returning here first made `apply` the one thing that
            # could not repair it, while doctor was telling the operator to run exactly that.
            # Idempotent and sudo-free when the units already match.
            mutation_lock_acquire apply
            provision_control_runner
            log "No configuration changes detected. Nothing to apply."
            mutation_lock_release
            return 0
        fi
        warn "A previous apply updated the config but did not finish recreating containers — retrying."
    fi

    # The retry branch reaches here without a hold; the changed branch already has one.
    if [ "$lock_held" -eq 0 ]; then
        mutation_lock_acquire apply
        lock_held=1
    fi
    # Client-auth keys must be written before tor is recreated below, so an onion just turned on (or a
    # client-auth toggle) takes effect on this apply rather than the next (#343).
    provision_onion_client_auth
    provision_control_runner
    provision_ssh_access
    provision_console_login   # #33: converge the control-runner units on the (new) toggle
    render_local_miner_config # #796: the built-in miner's config is derived — keep it current

    log "Updating containers..."
    migrate_compose_project
    # (Re)assert the Tor-only egress firewall BEFORE compose recreates anything — same ordering as
    # up/upgrade (#276/#291), for the same reason: if it isn't already installed (e.g. `down` then
    # `apply`), recreating containers first opens a startup window where a clearnet app dials out and
    # the leading ESTABLISHED rule grandfathers it past the DROP. Idempotent, so the common case
    # (already installed from `up`) is a cheap re-assert; the .env it reads was committed just above.
    apply_tor_egress_firewall
    # Mark the recreate in-flight: cleared only after a SUCCESSFUL `up`, so a failure here (image
    # build error, a port already bound, a failed health/dependency gate, daemon hiccup) leaves the
    # marker for the next apply to retry instead of no-opping on the already-committed config (#125).
    : >"$apply_marker"
    # One-time move of the dashboard data out of the install dir (#455) — after the confirmed
    # commit above (never before the operator said yes) and under the marker, so a failed move is
    # retried; the recreate below then mounts the migrated directory.
    migrate_dashboard_data
    # Compose recreates only the services whose resolved config changed. --remove-orphans covers
    # services that left the compose file entirely; a profile-deactivated service is NOT an orphan
    # to compose, so compose_up_checked removes those containers itself before the up (#795).
    if ! compose_up_checked -d --remove-orphans; then
        warn "Config files were updated but containers were NOT recreated ('docker compose up' failed)."
        warn "Fix the cause shown above, then re-run '$0 apply' (it will retry the recreate) — or '$0 up'."
        exit 1 # leave $apply_marker in place so the retry re-attempts the recreate
    fi
    # Caddy mounts the Caddyfile read-only, so a content change alone won't recreate it.
    if [ "$caddy_changed" -eq 1 ]; then
        docker compose restart caddy
    fi
    # If the dashboard onion was just turned on, the recreated tor container generated its hostname;
    # read it back into .env so `pithead status` can surface the address (#343) — and regenerate the
    # Caddyfile + restart caddy so the HTTPS onion vhost (#360) actually appears this run instead of
    # never (#546): a re-render off the committed .env sees no change and no-ops before ever reaching
    # generate_caddyfile above.
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ] && onion_missing "${DASHBOARD_ONION:-}"; then
        if provision_dashboard_onion && render_env; then
            generate_caddyfile
            docker compose restart caddy
        fi
    fi
    rm -f "$apply_marker"
    # Converge the built-in miner on a toggle without waiting for a reboot (#796): start it when
    # local_miner just turned on, stop it when it turned off. After the recreate above so the
    # stratum the miner dials is the freshly-applied one. Best-effort, same posture as setup.
    provision_local_miner || true
    log "Configuration applied."
    announce_dashboard_url
    mutation_lock_release
}

# --- Subcommand chaining (#94) ---

# Every dispatchable subcommand, in help order. main's dispatch, the chain validator, and the
# tab-completion script (pithead-completion.bash) key off this one list; tests/stack/run.sh fails
# if any of the three drift apart.
readonly PITHEAD_COMMANDS="setup apply render up down restart upgrade logs status doctor support-bundle reset-dashboard config-reset factory-reset backup restore uninstall firstboot-wizard load-images local-miner os-update control-run-pending onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"
# The subset allowed in a chain: commands that take no positional argument and terminate on their
# own. Excluded: setup (interactive first-run), logs (follows until Ctrl+C), restore (needs an
# archive path), reset-dashboard (destructive — run it deliberately, alone), and the one-shot
# info/maintenance commands (version, help, onion-client-key, rotate-dashboard-onion).
readonly PITHEAD_CHAINABLE="apply up down restart upgrade status doctor backup"

is_pithead_command() { case " $PITHEAD_COMMANDS " in *" $1 "*) ;; *) return 1 ;; esac }

# Reject a nonsensical chain BEFORE any step runs (#94): chainable commands only, no duplicates,
# at most one of up/down/restart (two run-state commands in one chain contradict or repeat each
# other), and `down` only as the final step (anything after it would act on a stopped stack).
validate_chain() {
    local c seen="" runstate=0 last="${!#}"
    for c in "$@"; do
        case " $PITHEAD_CHAINABLE " in
        *" $c "*) ;;
        *) error "Invalid chain: '$c' can't be chained — run it on its own. Chainable commands: $PITHEAD_CHAINABLE. Nothing was run." ;;
        esac
        case " $seen " in
        *" $c "*) error "Invalid chain: '$c' appears twice. Nothing was run." ;;
        esac
        seen="$seen $c"
        case "$c" in up | down | restart) runstate=$((runstate + 1)) ;; esac
    done
    if [ "$runstate" -gt 1 ]; then
        error "Invalid chain: up/down/restart contradict each other in one invocation. Nothing was run."
    fi
    if [ "$last" != "down" ]; then
        case " $* " in
        *" down "*) error "Invalid chain: 'down' must be the last step — the commands after it would run against a stopped stack. Nothing was run." ;;
        esac
    fi
}

# Run an all-subcommand argv left-to-right, validating the whole chain first. Each step is its own
# pithead invocation, so a step's `exit` can't skip the accounting here. Fails fast: the first
# non-zero step stops the chain, the report says what ran and what didn't, and that step's exit
# code is propagated.
run_chain() {
    validate_chain "$@"
    local total=$# i=0 c rc
    for c in "$@"; do
        i=$((i + 1))
        log "── chain step $i/$total: $c"
        rc=0
        bash "${PITHEAD_SELF:-$0}" "$c" || rc=$?
        if [ "$rc" -ne 0 ]; then
            warn "Chain stopped: step $i/$total ('$c') failed with exit code $rc."
            if [ "$i" -gt 1 ]; then warn "Already ran: ${*:1:$((i - 1))}."; fi
            if [ "$i" -lt "$total" ]; then warn "Did not run: ${*:$((i + 1))}."; fi
            exit "$rc"
        fi
    done
}

# --- Dashboard control channel (#33) ---
# The dashboard container can only ASK: it drops typed JSON intents into $CONTROL_DIR/requests
# (its single writable spool mount). This host-side runner claims each request, validates it, and
# dispatches a FIXED set of actions, each a hardcoded host command the request's `action` string
# only SELECTS between — `apply --dry-run --porcelain` (preview), `apply -y` (commit), `upgrade`
# to the latest published release (#59, target re-derived host-side), `restart`/`apply` (the
# Telegram lifecycle verbs, #338), `worker-apply`/`worker-upgrade` (a rig's own control API,
# #185/#597), and `backup` (an encrypted archive + one-time emergency kit, #908).
# Outcomes land in results/ and an audit line in audit/, both mounted read-only in the container —
# as is masked/, the pre-masked config copy the editor form prefills from (#440); the raw
# config.json is never mounted, so the container holds no secret it wasn't given.
# No string from the container is ever executed or interpolated into a command; the candidate
# config crosses the boundary only as a FILE handed to `apply` via PITHEAD_CONFIG_FILE.

# Approval gate for a commit (#33). The client-side typed-APPLY modal is NOT a security control:
# a compromised/XSS'd container writes the request spool directly and never renders that modal, so
# the only trustworthy gate is here, host-side. FAIL CLOSED, two independent checks:
#
#   1. TRUE DEFAULT-DENY: a commit that changes ANY env key NOT in
#      CONTROL_DASHBOARD_EDITABLE_KEYS — in EITHER direction (enable, change, or DISABLE) — is
#      refused. An allowlist, not a blocklist: a key added to render_env tomorrow is
#      un-committable from the dashboard until someone deliberately lists it here. Deliberately
#      decoupled from describe_change's cosmetic INFO/DEST flag: that flag labels only the
#      disruptive direction (enabling auth is DEST, disabling is INFO), so a compromised
#      container could otherwise switch security controls OFF with zero DEST rows.
#   2. Anything describe_change still flags DEST (pruning, data dirs, node-mode switch, ...) is
#      refused as disruptive, even for allowlisted keys.
#
# Both checks re-derive the changed keys from the staged config via the SAME dry-run path a preview
# runs — nothing is trusted from the container's request or its (host-written but container-visible)
# result file — so a forged "destructive:false" cannot slip a wallet swap or an auth-disable
# through. Out-of-band approval with deny-on-timeout is #338 (Telegram approve/deny) — it drops in
# here, replacing the refusal with a real second factor. Until then, these edits must be made from
# the host CLI. Echoes a reason on stdout when it refuses.

# The env keys committable from the dashboard: operational tuning only, and only keys whose value
# is derived from a validated enum, boolean, or number — never a free-form string that reaches a
# command line, URL, or credential. Everything else — wallets, auth, onion exposure, the control
# channel itself, Tor egress/clearnet toggles, binds and ports, node endpoints, the XvB pool URL
# and donor id, tokens and passwords, the #381 payout-confirmation secrets (MONERO_VIEW_KEY,
# WALLET_RPC_PASSWORD) plus PAYOUT_CONFIRM_ENABLED, and their #462 Tari siblings (TARI_VIEW_KEY,
# TARI_WALLET_PASSWORD, TARI_SPEND_PUBLIC_KEY) plus TARI_PAYOUT_CONFIRM_ENABLED /
# TARI_WALLET_GRPC_ADDRESS / TARI_WALLET_SECRET_FILE — stays host-CLI-only. PAYOUT_SCAN_HEIGHT and
# TARI_WALLET_BIRTHDAY moved to the confirm-gated set below (2026-08 audit reclassification):
# they're wallet-creation metadata, not a secret, and a wrong value only re-scans from a different
# height on the wallet's NEXT creation — recoverable, not destructive.
# Each view key reveals every incoming payout amount/time, so it is never dashboard-committable
# (default-deny already refuses it; named here deliberately). The WALLET_CHANGED and
# CLEARNET_EXPOSED alert toggles are excluded on purpose: they are the tamper-evidence alarms on
# the Telegram channel (the future #338 approval channel), so the dashboard must not silence
# them. Space-separated exact env-key names.
#
# NOTE (2026-08 audit): TELEGRAM_EVENT_RAFFLE_WIN was missing from this list for a while — the one
# event toggle out of step with its 24 siblings, all otherwise editable. If you add a new event
# toggle, list it here AND in control_service.EDITABLE_ENV_KEY_PATHS (dashboard) — the drift
# guard only catches a mismatch between the two, not an omission from both.
CONTROL_DASHBOARD_EDITABLE_KEYS='P2POOL_FLAGS P2POOL_PORT
    XVB_ENABLED XVB_DONATION_LEVEL TARI_REQUIRED DASHBOARD_FAIL_CLOSED
    DASHBOARD_CHECK_UPDATES DASHBOARD_TZ
    MONERO_MEM_LIMIT TARI_MEM_LIMIT MONERO_PREP_THREADS
    HASHRATE_DROP_THRESHOLD_PCT HASHRATE_DROP_MINUTES TELEGRAM_DAILY_SUMMARY_TIME
    TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED
    TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
    TELEGRAM_EVENT_WORKER_JOINED TELEGRAM_EVENT_WORKER_LEFT
    TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_DISK_SPACE
    TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_XVB_NO_SHARE
    TELEGRAM_EVENT_XVB_REGISTRATION TELEGRAM_EVENT_NEW_RELEASE
    TELEGRAM_EVENT_STACK_ONLINE TELEGRAM_EVENT_DAILY_SUMMARY
    TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HASHRATE_LOSS
    TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM
    TELEGRAM_EVENT_HIGH_REJECT_RATE TELEGRAM_EVENT_BLOCK_FOUND
    TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_PAYOUT_CONFIRMED TELEGRAM_EVENT_CONTAINER_UNHEALTHY
    TELEGRAM_EVENT_RAFFLE_WIN'

# The confirm-gated editable set (#719): operationally-disruptive env keys the dashboard MAY commit
# behind a type-to-confirm — NOT the security perimeter (wallets, keys, credentials, onion,
# tor_egress_firewall, dashboard.control.enabled, stratum password, per-rig hosts/tokens all stay
# host-only DEST). Type-to-confirm is UX FRICTION, not a security control: a compromised dashboard
# that can set a field can also fill the confirm box, so this set is strictly the "expensive but
# recoverable, not a breach" class — a data-dir move (re-sync), a stratum-port repoint (rigs
# reconnect), a clearnet-sync enable (host IP exposed during IBD, auto-reverts), a prune enable
# (reclaims disk), or a Tor-load repoint (MONERO_OUT_PEERS: bounded 8-1024 at validation and
# instantly reversible, but the biggest steady-state knob on the shared Tor daemon's CPU — 2026-08
# security review placed it here, not free-commit). The same review REVERTED three keys the
# configurability audit had proposed: PROXY_DONATE_LEVEL (docs/privacy.md's own words — donate
# traffic bypasses the Tor socks5, and a self-approving container could divert up to 99% of
# revenue silently), and PAYOUT_SCAN_HEIGHT / TARI_WALLET_BIRTHDAY (a future-dated value lands at
# the NEXT wallet creation and silently defeats the payout-confirmation tamper evidence — not the
# recoverable class this tier is for). All three stay host-only. describe_change flags
# each CONFIRM only in its in-scope DIRECTION — the flag carries the direction (prune DISABLE, TOR
# data-dir move, etc. still emit DEST and stay refused); this list is the static allowlist the
# gate's default-deny pass consults and the UI mirrors (control_service.CONFIRM_ENV_KEY_PATHS,
# drift-guarded like CONTROL_DASHBOARD_EDITABLE_KEYS).
CONTROL_DASHBOARD_CONFIRM_KEYS='MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR
    STRATUM_PORT MONERO_CLEARNET_SYNC TARI_CLEARNET_SYNC MONERO_PRUNE
    MONERO_OUT_PEERS'

# True if $1 is EXACTLY a canonical dotted-decimal IPv4 literal — four decimal octets 0-255, none
# with a leading zero (a bare "0" is fine; "010"/"0177" are not). curl/glibc's numeric-address
# parsing also accepts a bare decimal integer ("2130706433"), octal per-octet ("0177.0.0.1", AND
# bash's own arithmetic tests would misread "010" as octal 8), hex ("0x7f000001"), and
# short/collapsed forms ("127.1" == 127.0.0.1) — none of those are "canonical" by this definition,
# on purpose. Used two ways below: to fast-path an already-clean literal straight to a
# classification with no resolver round trip, and to recognize a RESOLVED answer's own shape
# (getent's output is always canonical, so this always matches there).
_is_canonical_ipv4() {
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
    return 0
}

# True if a CANONICAL IPv4 address (already _is_canonical_ipv4-shaped) is inside this host's own
# reach: loopback/this-network (0.x/127.x — all of 127.0.0.0/8, not just 127.0.0.1, so a box's own
# non-default loopback alias is caught too), link-local (169.254.0.0/16, which also covers the
# 169.254.169.254 cloud-metadata address), multicast/reserved (224-255), or the stack's own
# docker-bridge /24 (network.subnet, read from the LIVE config — a same-commit network.subnet
# change is refused elsewhere, on neither editable allowlist, so the live value is the honest
# baseline either way). RFC1918 LAN ranges (10/8, 172.16/12, 192.168/16) are deliberately NOT on
# this list — dialing a LAN rig is this feature's whole purpose.
_ipv4_is_sensitive() {
    local a b prefix
    IFS=. read -r a b _ _ <<<"$1"
    case "$a" in
    0 | 127) return 0 ;;
    169) [ "$b" = 254 ] && return 0 ;;
    esac
    [ "$a" -ge 224 ] && return 0
    prefix=$(jq -r '.network.subnet // "172.28.0.0/24"' "$CONFIG_FILE" 2>/dev/null)
    case "$prefix" in
    *.0/24) prefix="${prefix%.0/24}" ;;
    *) prefix="172.28.0" ;;
    esac
    [ "${1%.*}" = "$prefix" ]
}

# True if $1 is shaped like an IPv6 literal — loose on purpose (a bare colon check): this only
# routes the value to the right classifier below, it doesn't itself decide safety.
_is_ipv6_literal() {
    case "$1" in
    *:*) return 0 ;;
    esac
    return 1
}

# True if an IPv6 literal is inside this host's own reach: loopback (::1), unspecified (::),
# link-local (fe80::/10 — the fixed first 10 bits always print as "fe8"/"fe9"/"fea"/"feb" in
# RFC 5952's canonical form, since none of those leading hex digits is ever zero-suppressed),
# multicast (ff00::/8 — this is what actually closes the /etc/hosts multicast aliases
# ip6-allnodes/ip6-allrouters/ip6-localnet/ip6-mcastprefix; a spelling denylist could only ever
# cover the aliases someone thought to type in, never the address CLASS), or an IPv4-mapped IPv6
# literal (::ffff:a.b.c.d) whose EMBEDDED v4 address is itself sensitive — curl dials the
# embedded address, so the v6 wrapper syntax must not launder it.
_ipv6_is_sensitive() {
    local v6
    v6=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    v6="${v6%%%*}" # strip a zone ID (fe80::1%eth0) — irrelevant to which block it's in
    case "$v6" in
    "::1" | "::") return 0 ;;
    fe8[0-9a-f]:* | fe9[0-9a-f]:* | fea[0-9a-f]:* | feb[0-9a-f]:*) return 0 ;;
    ff[0-9a-f][0-9a-f]:*) return 0 ;;
    ::ffff:*.*.*.*)
        _is_canonical_ipv4 "${v6##*:}" && _ipv4_is_sensitive "${v6##*:}" && return 0
        ;;
    esac
    return 1
}

# Resolves $1 to its numeric addresses (both A and AAAA) via the system resolver — once, at
# commit time; this write path is operator-confirmed, never a hot loop, so a real DNS round trip
# here is the right cost for the safety it buys. `getent ahosts` also resolves any numeric-address
# ATTEMPT that isn't the exact canonical form (decimal integer, octal, hex, short/collapsed —
# _is_canonical_ipv4's own comment) using the SAME numeric parsing glibc's getaddrinfo (and
# therefore curl) uses, so routing those through here too gets an exact answer instead of a
# guess. Prints one deduplicated IP per line; a non-zero exit (including a 5s timeout) means
# resolution failed, which the caller treats as FAIL CLOSED — an unresolved name can never be
# proven safe. This is the one seam a test replaces: point $PATH at a directory carrying a fake
# `getent` ahead of the real one (see tests/stack/test-control-add-only-ssrf.sh) to supply canned
# answers without needing real DNS.
_resolve_host_ips() {
    timeout 5 getent ahosts "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

# True if $1 — a workers.list[] host the add-only exception is about to let a commit introduce —
# resolves inside THIS host's own reach. Mirrors the READ-path SSRF guard a miner-claimed IP
# already gets (_safe_probe_host, dashboard/mining_dashboard/client/xmrig_client.py, #122) for the
# WRITE path: an add-only append is DASHBOARD-chosen (the operator confirms it in the browser, but
# the actual HTTP request is built and sent by the — possibly compromised — dashboard container),
# so without this a malicious/compromised dashboard could append a phantom descriptor pointed at
# its own host's loopback services or a sibling container, then immediately dial it (with an
# attacker-chosen bearer) via the pre-existing worker-apply/worker-upgrade path, which resolves and
# dials strictly from the HOST's own config. An ordinary LAN or public rig address is unaffected.
#
# #893 round 5: an earlier version of this function classified by STRING SHAPE alone — a denylist
# of "localhost" and its known /etc/hosts aliases. An independent review found that a spelling
# denylist can never answer "does this name reach my own loopback": this host's own Debian
# self-entry (e.g. a box named "gouda" resolving to 127.0.1.1 — every Debian install's own
# /etc/hosts gives its hostname a loopback entry) and, worse, ANY attacker-controlled DNS name
# pointed at 127.0.0.1 both looked like "a genuine hostname, therefore safe" to a string
# classifier — but a live curl dial to either one lands on loopback all the same. There is no
# spelling to denylist against an attacker who controls the DNS answer.
#
# The fix is RESOLVE, THEN CHECK: a canonical IPv4 literal (the exact form _is_canonical_ipv4
# recognizes) is classified directly, since it already IS the address that would be dialed and
# has exactly one meaning. Everything else — including an IPv6 literal, which unlike IPv4 has
# many equally-valid spellings of the same address ("::1" == "0:0:0:0:0:0:0:1") that a hand-rolled
# shortcut classifier could under-recognize the same way the old denylist did — goes through the
# resolver, which normalizes any of those the same way glibc's own numeric-address parsing would.
# EVERY returned address must clear the check — an attacker's own DNS answer can mix one public IP
# with one loopback IP in the same response, so checking only the first would miss it.
# DNS-rebinding (the resolved-at-commit
# address differing from the address at a later dial) is an accepted residual risk, same as
# before resolve-and-check existed: it requires a SEPARATE capability (DNS control) beyond a
# compromised dashboard, and the operator-confirmed write boundary this whole check lives behind
# is why that's acceptable without also adding a dial-time re-check (see the PR's "Dial-time
# re-check" note).
_control_host_is_internal() {
    local host resolved ip
    host=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    host="${host%.}" # a trailing dot is DNS's "FQDN root" marker; getent treats it identically
    if _is_canonical_ipv4 "$host"; then
        # A canonical dotted-decimal literal is unambiguous — it IS the address that would be
        # dialed, so classify it directly with no resolver round trip.
        _ipv4_is_sensitive "$host"
        return
    fi
    # Everything else — a genuine hostname, an IPv6 literal in ANY of its many equally-valid
    # spellings ("::1" and "0:0:0:0:0:0:0:1" are the identical address; a hand-rolled
    # canonicalizer here would just reopen the same bug class this fix closed for IPv4 — a
    # classifier that only recognizes ONE shape and silently treats every other shape as safe), or
    # an IPv4-shaped-but-non-canonical numeric-address ATTEMPT (decimal integer, octal, hex,
    # short/collapsed form) — goes through the resolver. `getent ahosts` normalizes ALL of those
    # into canonical addresses using the SAME parsing glibc's getaddrinfo (and therefore curl)
    # uses, including a bare literal (no network round trip needed for one), so this is correct
    # for a typed literal and a real hostname alike.
    resolved=$(_resolve_host_ips "$host") || return 0 # resolution failed/timed out -> FAIL CLOSED
    [ -n "$resolved" ] || return 0                    # an empty answer -> FAIL CLOSED
    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if _is_canonical_ipv4 "$ip"; then
            _ipv4_is_sensitive "$ip" && return 0
        elif _is_ipv6_literal "$ip"; then
            _ipv6_is_sensitive "$ip" && return 0
        else
            return 0 # an answer shape we don't recognize -> FAIL CLOSED, never wave it through
        fi
    done <<<"$resolved"
    return 1
}

control_approval_gate() { # <staged-file> [confirm-token]
    local staged="$1" confirm="${2:-}" porcelain
    # Fail closed if we cannot re-derive the change set (the staged config was validated at
    # preview, so a dry-run failure here means something changed — refuse).
    if ! porcelain=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>/dev/null); then
        printf 'could not re-validate the staged change host-side — refusing to commit'
        return 1
    fi
    # Two config.json blocks never render to .env — the dashboard reads them straight off its
    # config.json mount (load_worker_endpoints + load_energy_config; these are the ONLY two), so the
    # env-diff allowlist below can't see either. Each config.json-only block must be handled here by
    # name or a commit could silently change it: the worker descriptors are REFUSED, dashboard.energy
    # is ALLOWED (#504). Every OTHER config path renders to .env and is gated by the allowlist, so a
    # change there is caught below — a NEW config.json-only block, though, MUST add its own line.
    #
    # The per-worker descriptors — workers.list[] (#506) or its deprecated fallback
    # dashboard.workers[] (#172) — carry per-rig hosts and API tokens (exactly the "free-form string
    # that reaches a URL or credential" class the allowlist exists to keep host-CLI-only). The
    # legacy dashboard.workers[] shape stays refused outright, whatever it changes to: any commit
    # touching it goes back to a host edit.
    #
    # workers.list[] gets ONE narrow ADD-ONLY exception (the click-to-adopt flow): a commit may
    # APPEND a brand-new descriptor to the end of the array, but every entry already live must
    # reappear byte-for-byte, in the same order — so an adopt commit can add rig #4 without ever
    # being able to repoint rig #1's host or token. That asymmetry is deliberate: first adoption
    # gets a human confirming a freshly-observed address (the miner-advertised value is a PREFILL
    # only), but a REPOINT of an already-trusted descriptor is the #122-class escalation an adopt
    # confirmation was never designed to cover, so it stays a host edit like any other change here.
    # Checked as a prefix match: staged.workers.list, cut back to live's own length, must equal
    # live.workers.list exactly. An empty live list makes every staged entry "new" by definition
    # (first adoption); a shorter/reordered/edited staged list can never match and is refused.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        (.dashboard.workers // []) == ($live[0].dashboard.workers // [])
        and ((($live[0].workers.list // []) | length) as $n
             | (.workers.list // [])[0:$n] == ($live[0].workers.list // []))
        ' "$staged" >/dev/null 2>&1; then
        printf 'this change alters an existing per-worker descriptor (workers.list[] / dashboard.workers[], a per-rig host/token) rather than only adding a new one, which is not committable from the dashboard. Edit config.json on the host and run `%s apply`.' "$0"
        return 1
    fi
    # SSRF floor on what an add-only append may point at (see _control_host_is_internal): every
    # NEWLY appended entry's host — never an already-live one, already covered above — must clear
    # this host's own loopback/link-local/internal-bridge reach. Read the live length fresh (not
    # cached from the check above) so this stays correct however the prefix check above evolves.
    local live_n new_host
    live_n=$(jq -r --slurpfile live "$CONFIG_FILE" '($live[0].workers.list // []) | length' "$staged" 2>/dev/null) || live_n=0
    while IFS= read -r new_host; do
        [ -n "$new_host" ] || continue
        if _control_host_is_internal "$new_host"; then
            printf 'a new worker descriptor points at %s, which resolves inside this host'"'"'s own network — a rig'"'"'s control address must be a distinct machine on your LAN, not this host or one of its own containers.' "$new_host"
            return 1
        fi
    done < <(jq -r --argjson n "${live_n:-0}" '(.workers.list // [])[$n:] | .[] | select(has("host")) | .host' "$staged" 2>/dev/null)
    # Closed-schema guard (#33 hardening). A config.json key the stack doesn't recognize renders to
    # NO env var, so it emits zero porcelain rows and slips past the allowlist below — yet the
    # commit's `cp "$staged" "$CONFIG_FILE"` would still persist it. So refuse any staged path that
    # isn't in the canonical schema (config.reference.json). Numeric path components are dropped so a
    # populated known scalar array (notifications.webhooks, telegram.control.allowed_ids) collapses
    # onto its schema-listed key instead of false-rejecting, while a smuggled OBJECT inside such an
    # array still surfaces its unknown sub-key. Both worker-descriptor shapes are exempt: their
    # per-rig object elements aren't enumerated in the reference and the array is already fully
    # guarded above. Fail closed — an unreadable reference or a jq error refuses the commit.
    # INVARIANT: config.reference.json MUST stay a complete superset of every config path this script
    # reads (grep the config_bool/`jq ... "$CONFIG_FILE"` sites), or a legit config carrying a
    # read-but-unlisted path is false-rejected on every commit. That includes backward-compat aliases
    # like xmrig_proxy.* (read at the XvB block) and dashboard.workers[] (read at
    # validate_worker_endpoints, #506). Guarded two ways in tests/stack/run.sh: the
    # legacy-xmrig_proxy round-trip case above, and (#561) an automated drift guard that walks this
    # script's own config_bool/`jq ... "$CONFIG_FILE"` read sites with a conservative fixed-shape
    # extractor and fails loud ("extend the extractor") on a shape it doesn't recognize, rather than
    # risking the false-alarms a naive grep-based path diff would hit on jq-internal and filename
    # dotted tokens.
    local unknown
    if ! unknown=$(jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile cfg "$staged" '
        def norm: [.[] | strings] | join(".");
        ([$cfg[0] | paths | select(.[0:2] != ["dashboard", "workers"] and .[0:2] != ["workers", "list"]) | norm]
         - [$ref[0] | paths | norm])
        | unique | join(", ")' 2>/dev/null); then
        printf 'could not validate the staged config against the schema (%s) — refusing to commit' "$REFERENCE_CONFIG"
        return 1
    fi
    if [ -n "$unknown" ]; then
        printf 'this change adds config keys not in the schema (%s) — refusing to commit. Edit config.json on the host and run `%s apply`.' "$unknown" "$0"
        return 1
    fi
    # Default-deny: refuse if any changed env key is NOT on the editable allowlist, whatever its
    # flag says. Refusal keys off a violation COUNT, not the matched text, so a blank or
    # malformed porcelain row (empty KEY column) still refuses instead of slipping past an
    # emptiness test.
    # The allowlist now spans BOTH the free-to-commit editable set and the confirm-gated set (#719):
    # a change to any other key still fails closed here. The CONFIRM set only gets PAST this pass —
    # it still has to clear the DEST perimeter and satisfy the typed-confirmation check below.
    local editable_re bad hit
    editable_re=$(printf '%s %s' "$CONTROL_DASHBOARD_EDITABLE_KEYS" "$CONTROL_DASHBOARD_CONFIRM_KEYS" | tr -s ' \n' '|')
    bad=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$editable_re" || true)
    if [ "${bad:-0}" -gt 0 ]; then
        hit=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -m1 -vxE "$editable_re" || true)
        printf 'this change alters a security-sensitive setting (%s) that is not committable from the dashboard. Edit config.json on the host and run `%s apply`.' "${hit:-unparseable change row}" "$0"
        return 1
    fi
    # Perimeter: any DEST row is refused outright — the confirm-gate never covers a destructive
    # host-only change. A data-dir MOVE is CONFIRM (below); a prune DISABLE or a TOR data-dir move
    # still emits DEST and is caught here even though its key is on the confirm allowlist.
    if printf '%s\n' "$porcelain" | grep -qE $'^DEST\t'; then
        printf 'this change is destructive and cannot be committed from the dashboard. Edit config.json on the host and run `%s apply`.' "$0"
        return 1
    fi
    # Data-dir destination allowlist (#728). #719 made the four *_DATA_DIR moves confirm-gated, so a
    # dashboard operator who types APPLY can now RELOCATE a service's data dir. assert_safe_dir — the
    # host-shell guard — is a BLOCKLIST: it refuses the catastrophic roots (/, $HOME, bare mounts, …)
    # but passes any OTHER absolute path. At host-shell trust that is proportionate (a shell already
    # has filesystem-wide reach); at dashboard trust it would let a confirmed move target another
    # user's home or another service's data volume and have pithead mkdir/chown -R it and bind-mount
    # it into a recreated container — a destination trust-escalation. This gate runs ONLY for
    # dashboard commits (the host `apply` path never calls control_approval_gate), so it is exactly
    # where the tighter, control-only rule belongs: for a control-channel move, narrow the
    # DESTINATION from a blocklist to an ALLOWLIST — permit only a path under the stack's own data
    # root ($PWD/data, the install dir's data/) or a parent the stack ALREADY keeps data in (each
    # live *_DATA_DIR's parent — a root a host operator already opted into, which covers a co-located
    # shared data root, #455). Anything else is refused EVEN with the APPLY token: that move stays
    # host-CLI-only. Only EXPLICIT absolute paths are checked — "auto"/empty resolves to a stack
    # default that is under a data root by construction. assert_safe_dir still runs at apply time.
    local -a allowed_roots=("$PWD/data")
    local dvar cur
    for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR; do
        cur=$(env_get "$dvar")
        [ -n "$cur" ] && allowed_roots+=("$(dirname "$cur")")
    done
    local ddpath dest root ok_root
    for ddpath in monero.data_dir tari.data_dir p2pool.data_dir dashboard.data_dir; do
        dest=$(jq -r --arg p "$ddpath" 'getpath($p/".") // empty' "$staged" 2>/dev/null)
        # Skip only values resolve_default turns into an in-root stack default — its EXACT set,
        # not a DYNAMIC_* wildcard (which would also swallow a bogus DYNAMIC_FOO that resolve_default
        # passes through literally). A non-absolute/traversal dest never reaches here anyway:
        # assert_safe_dir (called in the dry-run re-derivation at the top of this gate) refuses
        # `..`/relative paths first — keep that ordering.
        case "$dest" in "" | auto | DYNAMIC_DATA | DYNAMIC_HOST | DYNAMIC_ID) continue ;; esac
        ok_root=0
        # Trailing slash on both sides so a root prefix can't false-match a sibling (/data vs
        # /database); an exact-root dest matches too (harmless — still the stack's own dir).
        for root in "${allowed_roots[@]}"; do
            case "$dest/" in "$root"/*) ok_root=1 && break ;; esac
        done
        if [ "$ok_root" -eq 0 ]; then
            printf 'this move sends %s to %s, which is outside the stack data root(s) — a dashboard-confirmed data-dir move must stay under the stack data directory (%s) or a parent it already uses. Apply it from the host with `%s apply`.' "$ddpath" "$dest" "$PWD/data" "$0"
            return 1
        fi
    done
    # Confirm-gate (#719): an in-scope CONFIRM row PROCEEDS only with the operator's typed
    # confirmation. The token is a fixed literal ("APPLY"), orthogonal to the value being set — it
    # is friction that forces the operator to acknowledge an expensive/disruptive op, NOT a security
    # control (the perimeter above is the boundary). control_commit records a confirmed change
    # distinctly in the audit log via the marker file touched here.
    if printf '%s\n' "$porcelain" | grep -qE $'^CONFIRM\t'; then
        if [ "$confirm" != "APPLY" ]; then
            hit=$(printf '%s\n' "$porcelain" | grep -m1 -E $'^CONFIRM\t' | cut -f3-)
            printf 'this change is disruptive (%s) — type APPLY in the dashboard to confirm.' "${hit:-disruptive change}"
            return 1
        fi
        touch "${staged}.confirmed" 2>/dev/null || true
    fi
    # Approved: echo the changed key NAMES so the commit's audit entry can record WHAT changed
    # (#349) without a third dry-run. Names only, never values. dashboard.energy (#504) is
    # config.json-only, so it never appears in the env porcelain — fold a synthetic DASHBOARD_ENERGY
    # name into the list when that block changed, else an energy-only commit would audit no key.
    # Reference defaults merged into both sides (#696), same as the preview leg: the editor
    # round-trips the reference-merged form, and materialized defaults are not a change.
    local keys
    keys=$(porcelain_keys "$porcelain")
    if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
        '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
         == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
        keys="${keys:+$keys }DASHBOARD_ENERGY"
    fi
    printf '%s' "$keys"
    return 0
}

control_write_result() { # <results-dir> <id> <json>
    printf '%s\n' "$3" >"$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}

# One JSON line per handled request. `keys` (optional 6th arg) is the space-separated list of
# changed env-key NAMES from the same dry-run porcelain the approval gate re-derives — names only,
# NEVER values: several allowlist-adjacent keys are secrets host-side, and the audit log is mounted
# into the (semi-trusted) dashboard container. Every free-form field is charset-stripped at write
# time (below) so none can forge a second JSON line — `action` in particular can arrive raw from a
# container-supplied intent on the unknown-action path, so it is NOT a fixed string.
control_audit() { # <audit-file> <id> <actor> <action> <status> [keys]
    # Size bound (#349, same posture as #123): once the log passes 512 KiB, keep the newest 2000
    # entries. Trim-before-append, so the file is complete JSONL at all times and the entry being
    # written is never the one trimmed.
    if [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 524288 ]; then
        tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
    # Sanitize the free-form fields at the write chokepoint so nothing can forge a second JSON line
    # into this tamper-evidence log: `action` may arrive straight from a container-supplied intent
    # on the unknown-action path (a newline + `{...}` would otherwise inject an entry), and `keys`
    # is defense-in-depth over its upstream guard. `id` is a validated uuid4, `status` is
    # code-set, and `actor` is regex-whitelisted upstream — but strip them here too, cheaply.
    printf '{"ts":"%s","id":"%s","actor":"%s","action":"%s","status":"%s","keys":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')" \
        "$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._@-')" \
        "$(printf '%s' "$4" | tr -cd 'a-z-')" \
        "$(printf '%s' "$5" | tr -cd 'a-z-')" \
        "$(printf '%s' "${6:-}" | tr -cd 'A-Z0-9_ ')" >>"$1"
}

# The unique changed env-key names in a dry-run porcelain, one space-separated line (for the
# audit `keys` field). Key NAMES only — the porcelain MSG column is dropped here.
porcelain_keys() {
    printf '%s' "$1" | awk -F'\t' 'NF' | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Preview: stage the candidate config host-side, dry-run it, report the describe_change rows.
control_preview() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local staged="$cdir/staged/$id.json" errf="$cdir/staged/.$id.err" out result
    if [ "$(jq -r '.config | type' "$file")" != "object" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"config must be a JSON object",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # The "blank secret keeps the live value" merge happens HERE, host-side (#440): the request
    # arrives with {"__secret__":true} sentinels for untouched secrets (the container never held
    # the real values — it prefills from the pre-masked copy), and each sentinel is swapped for
    # the live config.json value at staging. A sentinel for a secret that is not actually set
    # collapses to "" rather than leaking a dict into config.json. The staged copy therefore
    # carries merged secrets: it lives in host-only staged/ — never mounted — and is pinned
    # owner-only so a co-tenant on the host can't read secrets from it (#33 hardening). Created
    # under umask 077 so it is never even briefly world-readable (create-then-chmod race); the
    # chmod stays as belt-and-suspenders.
    # Per-worker token sentinels (#172) get the same swap, but out of the fixed-path walk: they
    # live in the variable-length descriptor array — workers.list[] (#506) or its deprecated
    # fallback dashboard.workers[] — so restore each from the LIVE token matched by worker name
    # (first-declared wins on duplicate names, matching the container's probe; whichever shape the
    # live config actually uses). A sentinel for a rig with no live token collapses to "" too, and
    # the sentinel is restored into whichever shape the submitted doc carries.
    (umask 077 && jq --argjson paths "$CONTROL_SECRET_PATHS" --slurpfile live "$CONFIG_FILE" "$WORKER_LIST_JQ"'
        (reduce (($live[0] | worker_list) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = ($w.token // "") else . end)) as $livetok
        | reduce $paths[] as $p (.config;
            (try getpath($p) catch null) as $v
            | if ($v | type) == "object" and $v.__secret__ == true
              then setpath($p; (($live[0] | try getpath($p) catch null) // ""))
              else . end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end' "$file" >"$staged")
    chmod 600 "$staged" 2>/dev/null || true
    if out=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>"$errf"); then
        result=$(printf '%s\n' "$out" | jq -R -s '
            [split("\n")[] | select(length > 0) | split("\t") | {flag: .[0], key: .[1], msg: (.[2:] | join("\t"))}]
            | {status: "previewed", changes: .,
               destructive: (map(.flag == "DEST" or .flag == "CONFIRM") | any), ts: (now | floor)}')
        # #504: dashboard.energy is config.json-only (never rendered to .env), so an energy-only
        # edit produces no porcelain row. Surface it as a normal committable INFO change so the UI
        # arms Apply and the commit lands it in config.json. The approval gate allowlists exactly
        # this config.json-only block; any OTHER config.json-only delta still refuses (see
        # control_approval_gate). INFO never flips destructive, so the existing verdict stands.
        # Compare with the reference defaults merged into BOTH sides (#696): the editor round-trips
        # the reference-merged form, so on a config.json that never set dashboard.energy the staged
        # copy carries the materialized defaults — an absent block and explicit defaults are the
        # same settings, not a change.
        if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
            '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
             == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"dashboard.energy",msg:"Energy calculator settings (dashboard.energy) — electricity price / currency / XMR price updated."}]')
        fi
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "previewed" "$(porcelain_keys "$out")"
    else
        # Validation failed — reject with pithead's own error tail; nothing stays staged.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$errf")" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
    fi
    rm -f "$errf"
}

# Hand the operator-facing stack files that the ROOT control-runner just wrote back to the stack
# owner (#33 v1.4). control_run_pending is root (User=root in pithead-control.service), so its
# `apply` renders `.env` under `umask 077` as root:root 0600 and rewrites the Caddyfile as root —
# but pithead runs a NON-ROOT operator model ($REAL_USER), and a normal operator-run apply leaves
# these files owned by the operator. Without this, the operator's next `status`/`apply` can't even
# read .env (Permission denied), which is what the tier-4 gate caught. The target owner is DERIVED
# from config.json's on-disk owner — an operator-owned file the dashboard container CANNOT write
# (its raw config.json mount was dropped in #440; control_commit's `cp` also preserves its inode/
# owner), so nothing from the request or spool can steer the chown. $USER/$SUDO_USER are NOT usable
# here — the runner is root, so they read as root. The control-dir (staged/results/audit) is
# deliberately host-owned and is NOT touched: that rw/ro split is the #33 trust boundary.
control_reown_operator_files() {
    local owner f
    # GNU stat first, BSD fallback (see the provision_onion_client_auth note). No owner → skip.
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    [ -n "$owner" ] || return 0
    for f in "$ENV_FILE" "Caddyfile" "${CONFIG_FILE}.bak-control" "${CONFIG_FILE}.bak-workers"; do
        [ -e "$f" ] || continue
        # Fail safe: a chown that can't complete leaves the pre-existing bug, never corrupts state.
        chown "$owner" "$f" 2>/dev/null ||
            warn "Could not re-own $f to $owner after the control apply — the operator may need to chown it by hand."
    done
}

# Commit: apply the HOST-SIDE staged copy from the matching preview. A tampered second request
# can't swap the config — commit carries only the id; the config it applies is the one previewed.
control_commit() { # <id> <actor> <control-dir> [confirm-token]
    local id="$1" actor="$2" cdir="$3" confirm="${4:-}"
    local staged="$cdir/staged/$id.json" logf="$cdir/staged/.$id.log" rc=0
    if [ ! -f "$staged" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"no staged intent for this id — preview first",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    if [ -z "$(find "$staged" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"staged intent expired (older than 10 minutes) — preview again",ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    # On refusal the gate's stdout is the reason; on approval it is the changed key names, which
    # the audit entries below record — WHAT changed, by name only (#349).
    local gate_out keys=""
    if ! gate_out=$(control_approval_gate "$staged" "$confirm"); then
        [ -n "$gate_out" ] || gate_out="approval denied"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$gate_out" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged" "${staged}.confirmed"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    keys="$gate_out"
    # A confirm-gated destructive change (#719) is logged AS SUCH — the gate touches this marker
    # when a typed confirmation carried an in-scope CONFIRM row past the perimeter. The distinct
    # `commit-confirmed` action separates a dashboard-confirmed disruptive apply from an ordinary
    # (INFO-only) dashboard commit in the tamper-evidence log. Host-CLI applies never reach this log.
    local audit_action="commit"
    if [ -f "${staged}.confirmed" ]; then
        audit_action="commit-confirmed"
        rm -f "${staged}.confirmed"
    fi
    # Keep a pre-change backup; on failure it is named in the result and left in place. The
    # `apply -y` below re-renders the pre-masked prefill copy (#440), so the dashboard's editor
    # form reflects the committed config on the next load.
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-control"
    cp "$staged" "$CONFIG_FILE"
    "$0" apply -y >"$logf" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        control_reown_operator_files # the root apply wrote .env/Caddyfile as root — give them back (#33)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"applied",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "applied" "$keys"
    else
        # apply's own .apply-incomplete marker handles the container-recreate retry; the config
        # backup lets the operator revert by hand if the new config itself is the problem.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" --arg b "${CONFIG_FILE}.bak-control" '{status:"failed",error:$e,backup:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "failed" "$keys"
    fi
    rm -f "$staged" "$logf" "${staged}.confirmed"
}

# True when SemVer $1 is strictly newer than $2 (either may carry a leading `v`). Both arguments
# are shape-checked (vX.Y.Z) before the call. Pure bash/awk — macOS sort has no -V.
semver_newer() {
    local a b
    a=$(printf '%s' "${1#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    b=$(printf '%s' "${2#v}" | awk -F. '{printf "%d%05d%05d",$1,$2,$3}')
    [ "$a" -gt "$b" ]
}

# Upgrade the install to the latest published release (#59). The container only PROPOSES ("the
# operator confirmed vX.Y.Z"); this host side re-derives the target itself: it asks the GitHub
# release API — over the stack's own Tor SOCKS, like every other stack egress — for the latest
# tag, refuses unless the proposed version matches that tag exactly AND the tag is strictly newer
# than the running VERSION, then downloads the release bundle for the HOST-derived tag and runs
# `pithead upgrade`: the same two steps docs/operations.md documents for a manual update. No
# container string ever reaches a command line or URL — the proposed version is shape-checked and
# used only in an equality comparison, so a container-supplied tag/registry cannot steer what is
# installed (the image-swap RCE the #33 review closed). Source checkouts are refused: their
# update is `git pull`, a judgment the operator makes at a shell. One attempt per 10 minutes,
# so a compromised container cannot use the root runner as an egress beacon or grind GitHub.
control_upgrade() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    _upg_reject() { # <reason> — refuse before anything changed on the host
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "rejected"
    }
    _upg_fail() { # <reason> — the attempt started and did not finish
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    }
    if is_source_checkout; then
        _upg_reject "this install builds from source — upgrade from the host with 'git pull' then './pithead upgrade'."
        return 0
    fi
    # Ordered BEFORE the cosign precondition on purpose: an appliance cannot take a tarball
    # upgrade at all, whatever the host holds, so the appliance answer is the informative one.
    if is_appliance; then
        _upg_reject "this machine is a Pithead OS appliance — it updates through signed OS images, not release tarballs, and a tarball upgrade would silently revert at the next reboot. Use the OS update control in the dashboard header; nothing was changed."
        return 0
    fi
    # #376/#1023: the verifier is a PRECONDITION of a one-click upgrade, not a consequence of already
    # holding a key. Every release bundle ships cosign.pub (make_bundle copies the committed key
    # unconditionally), so the `pithead upgrade` this runner ends up calling will demand the
    # verifier at its image gate whatever the current install holds. Testing the LOCAL cosign.pub
    # instead — what this guard used to do — was blind to the one upgrade that needs it most: an
    # install cut before signing engaged moving to a signed release, which every fielded install
    # makes exactly once. That sailed past here and aborted inside the new CLI, after the download,
    # the extraction, and a full config re-render. Since #1072 the verifier is a container, so this
    # can only fail on a box whose docker is gone — which would also mean nothing is mining. Kept
    # anyway: checked with the source-checkout refusal above, both are "this install cannot take a
    # one-click upgrade at all", and neither claims the throttle or dials out, so a refusal here
    # costs the operator nothing.
    if ! cosign_available; then
        _upg_reject "docker is not available to run the release verifier — every image is verified against the shipped signing key before it is pulled, so this upgrade would fail partway through. Check the Docker daemon and retry."
        return 0
    fi
    # Throttle: one attempt per 10 minutes, checked before any network dial.
    local stamp="$cdir/staged/.upgrade-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        _upg_reject "an upgrade was attempted less than 10 minutes ago — wait for it to finish, then retry."
        return 0
    fi
    # The proposed version must LOOK like a release tag before it is even compared.
    local proposed
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    if [ -z "${PITHEAD_VERSION:-}" ]; then
        _upg_reject "cannot determine the running version (VERSION file missing) — upgrade from the host."
        return 0
    fi
    # Claim the throttle now — BEFORE the network dial — so every well-formed attempt costs the
    # 10-minute window, even one that will be rejected as non-latest. Otherwise a compromised
    # container floods well-formed-but-stale version intents and turns the root runner into an
    # unthrottled GitHub-API / Tor-egress beacon (each fails only at the proposed!=tag check, past
    # the dial). A genuine probe that fails to reach GitHub costing the operator a 10-minute wait
    # is the right trade.
    touch "$stamp"
    # Host-side re-derivation of the target: the latest tag according to GitHub, not the request.
    local rel tag
    if ! gh_release_fetch p2pool-starter-stack/pithead; then
        _upg_reject "$GH_RELEASE_HINT"
        return 0
    fi
    rel=$GH_RELEASE_JSON
    tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _upg_reject "the GitHub release API returned no usable release tag — nothing was changed."
        return 0
    fi
    if [ "$proposed" != "$tag" ]; then
        _upg_reject "requested version $proposed is not the latest published release ($tag) — reload the dashboard and retry."
        return 0
    fi
    if ! semver_newer "$tag" "v$PITHEAD_VERSION"; then
        _upg_reject "already up to date (running v$PITHEAD_VERSION; latest release is $tag)."
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"running",version:$v,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "started"
    # Bundle URL built from the HOST-derived tag only; fetched over the same Tor SOCKS.
    local bundle="$cdir/staged/.$id.tar.gz" logf="$cdir/staged/.$id.log"
    if ! curl -fsSL --max-time 900 --max-filesize "$CURL_CAP_BUNDLE" --socks5-hostname "$GH_SOCKS" -o "$bundle" \
        "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz" 2>/dev/null; then
        rm -f "$bundle"
        _upg_fail "could not download the $tag release bundle over Tor — the stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #376: verify the bundle against the cosign.pub ALREADY on disk before a byte of it is
    # extracted. The new bundle ships its own cosign.pub, but a key that arrives inside the
    # artifact it vouches for proves nothing — trust anchors at the key installed with the
    # release this host already runs. No local key (an older install) keeps today's behaviour —
    # TLS to GitHub plus tag pinning — with one loud line in the journal.
    if [ -f cosign.pub ]; then
        local sig="$cdir/staged/.$id.tar.gz.sig"
        if ! curl -fsSL --max-time 120 --max-filesize "$CURL_CAP_SMALL" --socks5-hostname "$GH_SOCKS" -o "$sig" \
            "https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead.tar.gz.sig" 2>/dev/null; then
            rm -f "$bundle" "$sig"
            _upg_fail "the $tag release carries no bundle signature (pithead.tar.gz.sig) — refusing to install it unverified; the stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        # The verifier is a container that sees the install dir at /w (#1072), so it needs the two
        # staged files named as IT sees them. Translated with a guard rather than a blind prefix
        # strip: a path that fell outside the mount would make cosign fail to open the file, and
        # this call reports any failure as "signature FAILED" — a mount bug must not be able to
        # masquerade as a tampered download and burn a legitimate release.
        local cbundle csig
        if ! cbundle=$(cosign_container_path "$bundle") || ! csig=$(cosign_container_path "$sig"); then
            rm -f "$bundle" "$sig"
            _upg_fail "the staged $tag bundle landed outside the install dir, where the release verifier cannot read it — refusing to install it unverified. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        if ! cosign_run verify-blob --key cosign.pub --signature "$csig" --insecure-ignore-tlog=true "$cbundle" >/dev/null 2>&1; then
            rm -f "$bundle" "$sig"
            _upg_fail "bundle signature verification FAILED for $tag — the download does not match the release key; refusing to extract it. The stack keeps running v$PITHEAD_VERSION."
            return 0
        fi
        rm -f "$sig"
    else
        warn "No cosign.pub next to pithead — bundle authenticity rests on TLS to GitHub plus tag pinning only."
    fi
    # Rollback guard (#376): a cosign signature binds BYTES, not a version — an attacker who
    # controls the release response could serve an OLDER genuinely-signed bundle at the $tag URL
    # and silently downgrade the stack to a patched-vulnerable version, and the signature would
    # still verify. Refuse unless the bundle's own top-level VERSION matches the host-derived
    # $tag, read WITHOUT extracting (the bundle unpacks to a fixed `pithead/` dir) so a mismatch
    # touches nothing on disk.
    # #548: the extraction above is a plain assignment, so under errexit a tar failure (a bundle
    # missing pithead/VERSION — corrupt download or a hostile non-pithead archive) would kill the
    # runner outright instead of reaching _upg_fail below, leaving this result stuck at "running"
    # and the claim never released. Guard it like every other dial/extract in this function.
    local bundle_version
    if ! bundle_version=$(tar -xzOf "$bundle" pithead/VERSION 2>/dev/null | tr -d '[:space:]') ||
        [ -z "$bundle_version" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag bundle is missing pithead/VERSION (corrupt or not a pithead bundle) — refusing to install it. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    if [ "v$bundle_version" != "$tag" ]; then
        rm -f "$bundle"
        _upg_fail "the $tag download actually contains version ${bundle_version:-unknown} — refusing a version-mismatched (possible rollback) release. The stack keeps running v$PITHEAD_VERSION."
        return 0
    fi
    # #629: pick the extraction target. A versioned install (pithead-vX.Y.Z dir) whose data dirs
    # all resolve OUTSIDE the install dir gets the documented bundle-deploy layout
    # (docs/operations.md § A recommended layout): extract into a fresh sibling pithead-<tag>/,
    # seed the operator's config + the install-local state, and run the NEW dir's upgrade — on
    # success its update_current_symlink repoints `current`, and this dir survives untouched as
    # the rollback copy. Anything else falls back to the historical in-place extraction: a plain
    # `pithead/` extract has no versioned layout to maintain, and data living under this dir
    # (the pre-#455 default) would be stranded by a dir swap — the new render would re-derive
    # its default paths under the NEW dir and the stack would come up beside its own data.
    local new_dir="" cwd
    cwd=$(pwd -P) # physical path: the guard below compares canonicalized values on BOTH sides
    if is_versioned_install_dir "$cwd"; then
        new_dir="$(dirname "$cwd")/pithead-$tag"
        local dvar dval
        for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do
            dval=$(env_get "$dvar")
            [ -n "$dval" ] || continue
            # Canonicalize: the .env value may reach the same place through the `current` symlink.
            dval=$( (cd "$dval" 2>/dev/null && pwd -P) || printf '%s' "$dval")
            case "$dval" in
            "$cwd" | "$cwd"/*)
                warn "$dvar resolves inside the install dir — upgrading in place; move the data to a shared root outside the version dir to get per-version rollback dirs."
                new_dir=""
                break
                ;;
            esac
        done
    fi
    # Atomic create, no -p and no pre-check: root must never extract into (or follow a symlink
    # planted at) a path some other local account pre-created — mkdir fails on ANY existing
    # entry, closing the check-to-use race outright (#629 security review). A leftover dir from
    # an earlier failed attempt therefore also lands here: fall back to in-place and say why.
    if [ -n "$new_dir" ] && ! mkdir "$new_dir" 2>/dev/null; then
        warn "$new_dir already exists (a previous attempt, or not ours to create) — upgrading in place. Remove it to get the fresh-dir layout back."
        new_dir=""
    fi
    if [ -n "$new_dir" ]; then
        # Fresh-dir deploy (#629). Plain tar throughout: nothing in $new_dir is running.
        if ! tar -xzf "$bundle" --strip-components=1 -C "$new_dir" 2>"$logf"; then
            rm -f "$bundle"
            _upg_fail "could not extract the $tag bundle into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        rm -f "$bundle"
        # Seed what only the running install has: the operator's config, the rendered .env
        # (preserved secrets — onions, RPC creds; cp -p keeps it 0600), and the install-local
        # state dirs — the control spool (so the audit trail and results history carry over,
        # and the result written below is visible to the RECREATED dashboard, which mounts the
        # new dir's spool), the clearnet sync markers, and the caddy access log. Chain and
        # dashboard data live outside this dir (guarded above) and carry over by path.
        local sdir
        if ! cp -p "$CONFIG_FILE" "$new_dir/config.json" 2>"$logf" ||
            ! cp -p "$ENV_FILE" "$new_dir/.env" 2>>"$logf" ||
            ! mkdir -p "$new_dir/data" 2>>"$logf"; then
            _upg_fail "could not seed config into $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
            rm -f "$logf"
            return 0
        fi
        for sdir in control clearnet-state caddy-logs; do
            [ -d "$PWD/data/$sdir" ] || continue
            if ! cp -a "$PWD/data/$sdir" "$new_dir/data/" 2>"$logf"; then
                _upg_fail "could not carry data/$sdir over to $new_dir: $(tail -c 500 "$logf") — the running install is untouched; the stack keeps running v$PITHEAD_VERSION."
                rm -f "$logf"
                return 0
            fi
        done
        # Run the NEW release's upgrade from the NEW dir: it re-renders the generated config
        # (recomputing every $PWD-derived path, including CONTROL_DIR), re-provisions the
        # control-runner units onto the new path, pulls the $tag images, and repoints
        # `current ->` on success. The outcome goes to BOTH spools: the recreated dashboard
        # mounts the new one, a failure before the recreate is read from the old one.
        # #637: this dir — untouched by the whole deploy — is the restore point; name it in the
        # result so the operator learns it exists without reading docs/operations.md first.
        local rdir
        if (cd "$new_dir" && ./pithead upgrade) >"$logf" 2>&1; then
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg r "$cwd" '{status:"upgraded",version:$v,rollback:$r,ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
            done
        else
            for rdir in "$cdir" "$new_dir/data/control"; do
                control_write_result "$rdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" --arg d "$new_dir" --arg r "$cwd" \
                    '{status:"failed",version:$v,rollback:$r,error:($e + " — finish the upgrade from the host: cd " + $d + " && ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
                control_audit "$rdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
            done
        fi
        rm -f "$logf"
        return 0
    fi
    # #637: unlike the fresh-dir path, this one has no surviving previous dir — and the new
    # release's `upgrade` below re-renders .env (and may migrate config.json). Keep a timestamped
    # pre-upgrade copy of both next to the originals before a byte changes (cp -p keeps .env's
    # 0600; a fresh stamp per attempt so a failed try never overwrites the good copy) and refuse
    # to overwrite the install without one. The destination name is predictable, so root must
    # never write through a symlink a co-tenant planted there (the #629 mkdir guard's attack
    # class): copy to an unpredictable mktemp name first, then rename onto the final name —
    # rename(2) replaces a planted entry without following it.
    _upg_snapshot() { # <src> <dst>
        local tmp
        tmp=$(mktemp "$PWD/.bak-upgrade.XXXXXX") || return 1
        if ! cp -p "$1" "$tmp"; then
            rm -f "$tmp"
            return 1
        fi
        mv -f "$tmp" "$2"
    }
    local bak
    bak="bak-upgrade-$(date +%Y%m%d-%H%M%S)"
    if ! _upg_snapshot "$CONFIG_FILE" "$CONFIG_FILE.$bak" 2>"$logf" ||
        ! _upg_snapshot "$ENV_FILE" "$ENV_FILE.$bak" 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "could not keep a pre-upgrade copy of config.json/.env: $(tail -c 500 "$logf") — refusing to overwrite the install without a restore point; the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    # Older snapshots hold yesterday's secrets: keep the newest three pairs, prune the rest.
    # Lexical order IS chronological for this stamp format; `|| true` — an empty glob under
    # pipefail must not kill the runner.
    ls -1r "$CONFIG_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    ls -1r "$ENV_FILE".bak-upgrade-* 2>/dev/null | tail -n +4 | while IFS= read -r f; do rm -f "$f"; done || true
    # The reported paths: CONFIG_FILE is cwd-relative unless the (test-only) override made it
    # absolute — don't prepend $PWD onto an already-absolute path.
    local bak_paths
    case "$CONFIG_FILE" in
    /*) bak_paths="$CONFIG_FILE.$bak" ;;
    *) bak_paths="$PWD/$CONFIG_FILE.$bak" ;;
    esac
    bak_paths="$bak_paths $PWD/$ENV_FILE.$bak"
    # In-place extraction over the running install, in two passes. Pass 1 lays down everything
    # EXCEPT the running script with plain tar, which MERGES existing directories — a release
    # install already carries the non-empty build/* config-template mounts — and overwrites files.
    # A single `-U` (unlink-first) pass over the whole tree instead tries to unlink those non-empty
    # build/* dirs first and aborts ("Cannot unlink: Directory not empty"), leaving the install
    # half-written. Pass 2 is the ONE file that needs -U: the pithead script, unlinked-first so it
    # lands on a NEW inode and the copy executing this very function keeps running from the old one
    # (an in-place overwrite would corrupt it mid-run).
    if ! tar -xzf "$bundle" --strip-components=1 -C "$PWD" --exclude='pithead/pithead' 2>"$logf" ||
        ! tar -xzUf "$bundle" --strip-components=1 -C "$PWD" pithead/pithead 2>>"$logf"; then
        rm -f "$bundle"
        _upg_fail "the $tag release bundle failed to extract: $(tail -c 500 "$logf") — the stack keeps running v$PITHEAD_VERSION."
        rm -f "$logf"
        return 0
    fi
    rm -f "$bundle"
    # The extraction replaced this script on disk (the running copy keeps executing from its old
    # inode); run the NEW pithead's `upgrade`, which re-renders the generated config and pulls the
    # $tag images — exactly what the manual bundle update does.
    if "$PWD/pithead" upgrade >"$logf" 2>&1; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"upgraded",version:$v,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "upgraded"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg e "$(tail -c 2000 "$logf")" \
            --arg b "$bak_paths" \
            '{status:"failed",version:$v,backup:$b,error:($e + " — finish the upgrade from the host with ./pithead upgrade; containers not yet recreated keep running the previous images."),ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "upgrade" "failed"
    fi
    rm -f "$logf"
}

# Validate + dispatch one CLAIMED request file. Trusts no byte of it: must be JSON, only the keys
# id/action/config/actor/version, the id must be a UUID (it becomes the result/staged FILENAME —
# anything else is rejected before it can touch a path), and the action one of the three known verbs.
# Lifecycle verbs for the Telegram control commands (#338): the only two host actions the bot can
# trigger, both FIXED — `restart` runs `$0 restart` (recreate the running stack) and `apply` runs
# `$0 apply -y` (re-render + re-apply the CURRENT on-disk config.json). The container's `action`
# string only SELECTS between these two hardcoded commands; nothing from the request is ever
# interpolated into a command, and `apply` here carries no config change (the default-deny config
# allowlist is only relevant to a config-editing commit, not a re-apply of the source of truth).
# Access control + the deny-on-timeout confirmation are enforced dashboard-side before the intent is
# ever spooled; this side records the actor and outcome in the same tamper-evidence audit log.
control_lifecycle() { # <verb: restart|apply> <id> <actor> <control-dir>
    local verb="$1" id="$2" actor="$3" cdir="$4" rc=0
    local logf="$cdir/staged/.$id.log"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "started"
    # ${PITHEAD_SELF:-$0} is this script (run_chain uses the same handle); the verb is a FIXED
    # literal picked by the case, never a string from the request.
    local self="${PITHEAD_SELF:-$0}"
    case "$verb" in
    restart) "$self" restart >"$logf" 2>&1 || rc=$? ;;
    apply) "$self" apply -y >"$logf" 2>&1 || rc=$? ;;
    *) return 0 ;; # unreachable: the dispatch already gated the verb
    esac
    if [ "$rc" -eq 0 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" '{status:"applied",action:$a,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "applied"
    else
        control_write_result "$cdir/results" "$id" "$(jq -n --arg a "$verb" --arg e "$(tail -c 2000 "$logf")" '{status:"failed",action:$a,error:$e,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$verb" "failed"
    fi
    rm -f "$logf"
}

# One-shot encrypted backup + one-time "emergency kit" (#908). Reuses stack_backup UNCHANGED
# (~L2793), encrypted ONLY — no request field can pick --no-encrypt (it stays CLI-only), and a
# failure to mint a passphrase refuses before anything is touched, never falls back to plaintext.
# The passphrase is generated HOST-SIDE (generate_node_password: the same 32-char-alnum strength
# already used for the local node RPC creds) and crosses to stack_backup only through its existing
# PITHEAD_BACKUP_PASSPHRASE env-var input — the same channel an unattended cron backup already
# uses — never argv (what the support bundle's redaction targets, #77) and never a file.
#
# One-time handoff lifecycle: the kit (passphrase + archive name + contents + created-at/`ts`)
# rides back through the SAME results/ leg every other verb uses, keyed by the request id — but
# results/ is mounted READ-ONLY into the dashboard container (#33's trust boundary: it can only
# ASK, via requests/), so the container can never itself delete or ack this file the way the
# first-boot wizard's handoff/handoff-ack does (that spool is mounted read-write end to end). The
# deliberate substitute here: a bounded, blocking TTL. Short enough that a stuck backup doesn't
# stall the single-threaded runner's other queued verbs for long; generous next to the dashboard's
# own long-poll window (CONTROL_WAIT_S) so an ordinary page load always sees it. Once it elapses
# the passphrase is overwritten with null — read or not, it is gone. The archive/filename/contents
# stay: it is ciphertext, useless without the passphrase, so it remains downloadable.
# ponytail: TTL, not a container->host ack request (a "backup-ack" verb through requests/ would be
# more precise but is a whole extra verb) — add one if this window proves too tight/loose live.
# Backstop for control_backup's one-time kit: null the passphrase in any kit JSON whose `ts` is
# older than the TTL but which still carries one — the case where the runner was killed during the
# self-redaction sleep (a reboot racing the window) and left a wallet-grade secret in plaintext on
# /data. Run at the top of every drain, so the fresh runner after such a reboot cleans it up. A
# generous margin over the TTL (2x, floor 120s) so this never races the in-band redaction of a kit
# whose window is still open.
control_redact_stale_kits() { # <results-dir>
    local results="$1" f now cutoff ts
    [ -d "$results" ] || return 0
    now=$(date +%s)
    cutoff=$((2 * ${CONTROL_BACKUP_KIT_TTL_S:-20}))
    [ "$cutoff" -lt 120 ] && cutoff=120
    for f in "$results"/*.json; do
        [ -f "$f" ] || continue
        # Cheap gate first: only kits that still hold a passphrase are candidates.
        jq -e '.passphrase // "" | length > 0' "$f" >/dev/null 2>&1 || continue
        ts=$(jq -r '.ts // 0' "$f" 2>/dev/null)
        [ "$((now - ts))" -ge "$cutoff" ] || continue
        jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
            "$f" >"$results/.$(basename "$f").tmp" 2>/dev/null &&
            mv "$results/.$(basename "$f").tmp" "$f"
    done
}

control_backup() { # <id> <actor> <control-dir>
    local id="$1" actor="$2" cdir="$3" rc=0
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "backup" "started"
    # Throttle (mirrors control_upgrade's #59 stamp): a compromised container flooding this verb
    # would repeatedly stop/start the whole mining stack, not just burn CPU — one attempt per 10
    # minutes, checked before the passphrase is even generated.
    local stamp="$cdir/staged/.backup-stamp"
    if [ -n "$(find "$stamp" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"a backup was started less than 10 minutes ago — wait for it to finish, then retry.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    { set +x; } 2>/dev/null # xtrace would print the passphrase assignment below
    local pass
    pass=$(generate_node_password)
    if [ -z "$pass" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"rejected",error:"could not generate a backup passphrase — nothing was backed up.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "rejected"
        return 0
    fi
    touch "$stamp" 2>/dev/null || true # claim the throttle before the disruptive part starts
    control_write_result "$results" "$id" "$(jq -n '{status:"running",ts:(now|floor)}')"
    local self="${PITHEAD_SELF:-$0}" logf="$cdir/staged/.$id.log"
    # Run as a CHILD PROCESS, like control_lifecycle/control_commit's own re-invocations:
    # stack_backup's error() exits its whole process on failure, which must not take the drain
    # loop's other pending requests down with it.
    export PITHEAD_BACKUP_PASSPHRASE="$pass"
    "$self" backup -y >"$logf" 2>&1 || rc=$?
    unset PITHEAD_BACKUP_PASSPHRASE
    if [ "$rc" -ne 0 ]; then
        control_write_result "$results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        rm -f "$logf"
        pass=""
        return 0
    fi
    local archive
    archive=$(sed -n 's/^\[pithead\] Backup written to: //p' "$logf" | tail -n1)
    rm -f "$logf"
    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        control_write_result "$results" "$id" "$(jq -n '{status:"failed",error:"the backup ran but the archive could not be located afterward.",ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "backup" "failed"
        pass=""
        return 0
    fi
    # Place it on the ALREADY-shared results/ leg (#33) — no new bind mount, keyed by the same id
    # as its own result. Tighter perms than the rest of results/ (which relies on default,
    # effectively world-readable perms — fine, nothing there is a secret): root-owned,
    # group-readable by the dashboard's own uid/gid only (APP_UID/APP_GID, #255), because this
    # file briefly shares a directory with its own passphrase below.
    local fname dest
    fname=$(basename "$archive")
    dest="$results/$id.tar.gz.enc"
    mv "$archive" "$dest"
    chown "0:$APP_GID" "$dest" 2>/dev/null || true
    chmod 640 "$dest" 2>/dev/null || true
    (umask 077 && control_write_result "$results" "$id" "$(jq -n --arg p "$pass" --arg f "$fname" '
        {status:"applied", passphrase:$p, archive:$f,
         contents:["config.json","the stack .env (secrets)","Caddyfile, if present",
                   "the Tor onion-service key directory, if present","the dashboard database"],
         note:"This passphrase is shown once and cannot be recovered — save it now.",
         ts:(now|floor)}')")
    pass=""
    chown "0:$APP_GID" "$results/$id.json" 2>/dev/null || true
    chmod 640 "$results/$id.json" 2>/dev/null || true
    control_audit "$auditf" "$id" "$actor" "backup" "applied"
    # The blocking TTL described above the function. Overridable so tests don't sit through it.
    sleep "${CONTROL_BACKUP_KIT_TTL_S:-20}"
    jq '.passphrase = null | .note = "The passphrase was shown once and is no longer available on this host — back up again if you did not save it."' \
        "$results/$id.json" >"$results/.$id.json.tmp" 2>/dev/null &&
        mv "$results/.$id.json.tmp" "$results/$id.json"
}

# Resolve a worker name to its dial target (host + control_port + token) from the HOST's OWN
# config.json — never the caller's intent (#122 SSRF). Shared by control_worker_apply and
# control_worker_upgrade, which had drifted this whole resolution+validation block out of sync
# line-for-line: the worker-name charset pin, the three WORKER_LIST_JQ lookups, and the
# host/port/token guards. On success sets RESOLVED_HOST/RESOLVED_CPORT/RESOLVED_TOKEN and returns
# 0. On failure sets RESOLVE_WORKER_ERR to the operator-facing rejection message (leaving the
# RESOLVED_* vars empty) and returns 1 — the caller writes its own rejected result/audit line with
# that message, since worker-apply and worker-upgrade audit under different action names.
resolve_worker_target() { # <worker-name> <verb-for-the-host-missing-message, e.g. "edit"/"upgrade">
    local worker="$1" verb="$2"
    RESOLVED_HOST="" RESOLVED_CPORT="" RESOLVED_TOKEN="" RESOLVE_WORKER_ERR=""
    # The worker name is a config.json lookup key AND (in name-auth) a bearer; pin its charset.
    # LC_ALL=C so [!-~] is the printable-ASCII BYTE range: under a UTF-8 locale GNU grep reads the
    # range by collation order and rejects ordinary names like "rig1" (caught by the release gate on a
    # UTF-8 box; CI runs under C and missed it). jq's test() above is codepoint-based and unaffected.
    if ! printf '%s' "$worker" | LC_ALL=C grep -qE '^[!-~]{1,128}$'; then
        RESOLVE_WORKER_ERR="malformed or missing 'worker' name in the request."
        return 1
    fi
    # Resolve the rig's ADDRESS + BEARER from the HOST's config.json — never the intent. A rig with no
    # host or no token cannot be a target (fail closed): the rig's control path is bearer-mandatory and
    # we only ever dial an operator-set host.
    local host cport token
    host=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .host // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    cport=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .control_port // 8082' "$CONFIG_FILE" 2>/dev/null | head -1)
    token=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .token // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -z "$host" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no configured host in workers.list[] (or the deprecated dashboard.workers[]) — set host + control_port + token to $verb it."
        return 1
    fi
    # host charset guard (#122): no port/path/userinfo can be smuggled into the URL below.
    if ! printf '%s' "$host" | grep -qE '^[A-Za-z0-9._-]{1,253}$'; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid host."
        return 1
    fi
    if ! is_valid_port "$cport"; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid control_port."
        return 1
    fi
    if [ -z "$token" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no token in workers.list[] (or the deprecated dashboard.workers[]) — the rig's control API is bearer-mandatory."
        return 1
    fi
    RESOLVED_HOST="$host" RESOLVED_CPORT="$cport" RESOLVED_TOKEN="$token"
    return 0
}

# Worker config apply (#185): POST an operator's writable-key change to a RigForge rig's control API
# and record the outcome for the dashboard's config history. The intent carries ONLY the worker NAME
# and the CHANGES — never a host, port, or token: the runner resolves the rig's real address + bearer
# from the HOST's own config.json (workers.list[] / the deprecated dashboard.workers[], #506), so a
# tampered intent can at most target another ALREADY-configured rig, never an arbitrary host (#122
# SSRF), and the rig's access token —
# masked out of the container (#440) — never leaves the host. Changes are re-validated against the
# same writable allowlist the rig enforces (defence in depth). Every result/audit line the container
# reads back carries the change_id + status only, never the token.
control_worker_apply() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "started"
    _wa_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "rejected"
    }
    _wa_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "failed"
    }
    local worker changes
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-upgrade uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "edit"; then
        _wa_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    # Changes must be a non-empty object whose keys are ALL writable via the rig's control path (the
    # rig re-validates; this is the host-side gate — mirrors rigforge WRITABLE, #185/#236).
    changes=$(jq -c '.changes // {}' "$file")
    local badkeys
    badkeys=$(printf '%s' "$changes" | jq -r '
        (["pools","DONATION","autotune","watchdog","watchdog_interval_min","max_temp_c"]) as $ok
        | if (type) != "object" or (length) == 0 then "__empty__"
          else [keys[] | select(. as $k | $ok | index($k) | not)] | join(",") end' 2>/dev/null)
    if [ "$badkeys" = "__empty__" ]; then
        _wa_reject "'changes' must be a non-empty object of writable config keys."
        return 0
    fi
    if [ -n "$badkeys" ]; then
        _wa_reject "keys not writable via the control path: $badkeys"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    # Per-drain dial budget (hardening): worker-apply is the only control action that blocks the
    # single-threaded root runner on a network round-trip (a dial + a status poll, tens of seconds).
    # Cap how many actually dial per drain so a compromised container can't queue a flood of valid
    # worker-applies and starve legitimate commit/restart/upgrade intents. The counter lives in the
    # runner's shell (control_run_pending seeds it), so it persists across the drain loop. Over-budget
    # intents are rejected with a retry hint — the operator just re-applies; a real fleet edit is a
    # handful of rigs, never dozens at once.
    if [ "${CONTROL_WA_BUDGET:-0}" -le 0 ]; then
        _wa_reject "too many worker config changes in one cycle — retry in a moment."
        return 0
    fi
    CONTROL_WA_BUDGET=$((CONTROL_WA_BUDGET - 1))
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" '{status:"running",worker:$w,ts:(now|floor)}')"
    # POST the change to the rig's control API. Direct LAN dial (like the read path) — NOT Tor: the rig
    # is an operator-set host on the mining LAN, not clearnet. The token rides one header, never the
    # URL, the result, or the audit log.
    local url="http://$host:$cport/apply" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$changes" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wa_fail "could not reach worker '$worker' control API at $host:$cport — nothing was applied."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # The rig's error string is attacker-influenceable (a compromised rig or a LAN MITM); cap it
        # before it lands in a result the container reads and the dashboard renders.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wa_reject "worker '$worker' refused the change (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The rig stages → validates →
    # applies → liveness-checks → rolls back if the miner doesn't return live, seconds later. The 20s
    # deadline (plus the 15s dial above) stays under the dashboard's CONTROL_WAIT_S POST wait, so the
    # dashboard always catches a terminal-ish result and records it in the config history. Terminals
    # are applied / rejected / rolled_back / failed — failed is the rig unable to restore its own
    # rollback backup (present since the v1.11.2 fleet floor), a real fault the result must carry
    # with its reason, never a deadline-burned "accepted".
    local sbody scode status reason ckeys deadline=$((SECONDS + 20))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 2
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours (a concurrent change could be newer).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | rejected | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            ckeys=$(jq -c '.changed_keys // []' "$sbody")
            rm -f "$sbody"
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --argjson k "$ckeys" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,changed_keys:$k,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-apply" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status in time — the change is staged on the rig and will apply; the
    # container can keep polling the rig via the next read. Record accepted-but-pending, not a failure.
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" \
        '{status:"accepted",change_id:$c,worker:$w,note:"queued on the rig; outcome not yet observed",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "accepted"
}

control_worker_upgrade() { # <claimed-file> <id> <actor> <control-dir>
    # One-click RigForge upgrade for a single rig (#597) — fuses the two existing templates:
    # resolve_worker_target's rig resolution/guards (address + bearer from the HOST config, never
    # the intent, shared with control_worker_apply) and control_upgrade's throttled host-side
    # target re-derivation over Tor (the container proposes a version; GitHub decides the real
    # target; a mismatch is refused).
    # The rig bounds whatever tag we send with its own monotonic + ancestry guards and rolls back
    # a build that doesn't come back live — rollback coverage is rig-side (rigforge#322).
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "started"
    _wu_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "rejected"
    }
    _wu_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "failed"
    }
    local worker proposed
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-apply uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "upgrade"; then
        _wu_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _wu_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    # Per-drain budget: an upgrade blocks the single-threaded root runner on the rig's build
    # (minutes, vs seconds for worker-apply), so exactly ONE dials per drain. v1 is per-worker
    # only — no "upgrade all" — and a real fleet upgrade is one rig at a time by design.
    if [ "${CONTROL_WU_BUDGET:-0}" -le 0 ]; then
        _wu_reject "another worker upgrade is already in this cycle — retry in a moment."
        return 0
    fi
    CONTROL_WU_BUDGET=$((CONTROL_WU_BUDGET - 1))
    # Host-side re-derivation of the target from the RigForge release API over Tor — load-bearing:
    # the rig deliberately computes no "latest" itself (ADR 0002 D4), it bounds the tag we send.
    # The derived tag is cached for 10 minutes and the dial itself is stamp-throttled to one per
    # 10 minutes (claimed BEFORE the dial, control_upgrade's anti-beacon lesson): a compromised
    # container flooding well-formed intents costs at most one GitHub/Tor egress per window,
    # while a legitimate rig-after-rig fleet upgrade reuses the cached tag.
    local tagf="$cdir/staged/.rigforge-latest-tag" stampf="$cdir/staged/.rigforge-latest-stamp" tag=""
    if [ -n "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        tag=$(cat "$tagf" 2>/dev/null)
    fi
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            _wu_reject "a RigForge release lookup was attempted less than 10 minutes ago and no usable tag is cached — retry in a few minutes."
            return 0
        fi
        touch "$stampf"
        local rel
        if ! gh_release_fetch p2pool-starter-stack/rigforge; then
            _wu_reject "$GH_RELEASE_HINT"
            return 0
        fi
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            _wu_reject "the GitHub release API returned no usable RigForge release tag — nothing was changed."
            return 0
        fi
        printf '%s' "$tag" >"$tagf"
    fi
    if [ "$proposed" != "$tag" ]; then
        _wu_reject "requested version $proposed is not the latest published RigForge release ($tag) — reload the dashboard and retry."
        return 0
    fi
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" --arg v "$tag" '{status:"running",worker:$w,version:$v,ts:(now|floor)}')"
    # POST the upgrade to the rig's control API — direct LAN dial like worker-apply, NOT Tor. The
    # body carries the HOST-derived tag only; the token rides one header, never the URL or result.
    local url="http://$host:$cport/upgrade" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$(jq -n --arg v "$tag" '{version:$v}')" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wu_fail "could not reach worker '$worker' control API at $host:$cport — nothing was changed."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # Rig-supplied text is attacker-influenceable (a compromised rig / LAN MITM); cap it.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wu_reject "worker '$worker' refused the upgrade (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The cap is a deliberate
    # trade: a no-rebuild upgrade (the common case — git checkout + restart) reaches terminal in
    # well under 90s, while a pin-change rebuild (~10 min) times out to "accepted" below and the
    # badge (#596) clears on its own when the rig reports the new version. Polling the full build
    # would hand a hostile/hung rig 12 minutes of the single-threaded root drain per intent
    # (sec-review finding) — 90s keeps the stall bound in worker-apply's envelope. Since
    # rigforge#320 (v1.12.0) the rig writes an in-progress "started" plus first-class noop
    # (already on the target) and throttled (its own 6h anti-beacon window) terminals; "started",
    # like a non-matching change_id, just means keep polling. Terminals are applied / noop /
    # throttled / rolled_back / failed. The cap is overridable (CONTROL_WU_POLL_CAP) so the stack
    # tests can prove the timeout→accepted fallback in seconds.
    local sbody scode status reason deadline=$((SECONDS + ${CONTROL_WU_POLL_CAP:-90}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 5
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours — the rig may still be showing a
        # PREVIOUS change's terminal state (no in-progress status, rigforge#320).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | noop | throttled | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            rm -f "$sbody"
            # Legacy remap: a pre-rigforge#320 rig (≤ v1.11.2, the supported floor) collapses its
            # 6h anti-beacon throttle into failed+"throttled — ..." free text, and retry-later
            # must render calm, not red. Anchored to that leading word on purpose: a modern rig's
            # genuine failed can mention the throttle too ("throttle state unavailable",
            # rigforge#321's fail-closed refusal) and must STAY a fault. Drop the remap once the
            # fleet floor reaches rigforge v1.12.0 (first-class throttled) — the v2 appliance
            # bakes v1.15.0, so post-v2 fleets are already past it.
            if [ "$status" = "failed" ] && printf '%s' "$reason" | grep -qiE '^throttled'; then
                status="throttled"
            fi
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --arg v "$tag" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,version:$v,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-upgrade" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status inside the cap — the upgrade is running on the rig. Record
    # accepted, not failure: the badge (#596) clears on its own when the rig's next summary poll
    # reports the new version ('applied' echoes no version, rigforge#320 — the summary is the
    # confirmation of record either way).
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" --arg v "$tag" \
        '{status:"accepted",change_id:$c,worker:$w,version:$v,note:"upgrade still running on the rig — check the rig if the badge has not cleared in a while",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "accepted"
}

# --- OS update over the control channel (appliance A/B slots, dashboard-driven) ---------------
# The dashboard container only ASKS; every verb below re-derives, re-verifies and executes on the
# HOST, and every one refuses outright on a non-appliance host (no RAUC, nothing to update).
# The flow is deliberately staged — check, download (resumable, to /data), verify the LOCAL file,
# install the verified local bundle, then an EXPLICIT reboot — so every network step is separated
# from every destructive step and a bundle is never stream-installed over Tor.

os_update_staging_dir() { printf '%s' "${PITHEAD_OS_UPDATE_DIR:-$PWD/data/os-update}"; }
os_update_inflight_file() { printf '%s/in-flight.json' "$(os_update_staging_dir)"; }
os_update_target_file() { printf '%s/target.json' "$(os_update_staging_dir)"; }

# The persistent OS-update state the dashboard renders (step across reloads and reboots, and the
# post-reboot verdict). Lives in the results/ leg of the control spool under a fixed non-uuid
# name, so it rides the existing read-only mount into the container — its presence is also how
# the dashboard knows it runs on an appliance at all. Atomic like control_write_result.
os_state_write() { # <control-dir> <json>
    mkdir -p "$1/results" 2>/dev/null || true
    printf '%s\n' "$2" >"$1/results/.os-update-state.tmp" &&
        mv "$1/results/.os-update-state.tmp" "$1/results/os-update-state.json"
}

# ponytail: test seam for the KVM battery — a root-owned `os-update-test-base` file beside the
# checkout redirects the release lookup and the bundle download to a local URL (and drops the
# Tor SOCKS, which cannot reach the bench). The ownership check stops a non-root plant from
# steering root's downloads; verification still runs for real against the slot keyring either
# way, so the seam can redirect WHERE the bytes come from but never what installs.
os_update_test_base() {
    local f="$PWD/os-update-test-base"
    { [ -f "$f" ] && [ -O "$f" ]; } || return 1
    tr -d ' \t\r\n' <"$f"
}

# The latest-release JSON, over the stack's own Tor SOCKS like every other stack egress.
#
# The real lookup is gh_release_fetch's, not a third copy of it. This one used `curl -fsS`, and
# `-f` collapses every non-2xx into one exit code — so a spent GitHub rate limit came out of
# os-check as "could not reach the release API over Tor" and sent the operator to a doctor run
# that correctly reports Tor healthy (#1081, which fixed the two DIY lookups and never saw this
# one). Only the bench seam keeps its own dial: it points at a local URL with no Tor in the path.
# Sets GH_RELEASE_JSON on success and GH_RELEASE_HINT on failure, like the shared fetch, so the
# caller must run it as a plain command — a command substitution is a subshell and would discard
# both. rc 2 = never reached the server at all, same convention as gh_release_fetch (#1050).
os_release_fetch() {
    local base
    if base=$(os_update_test_base); then
        GH_RELEASE_HINT=""
        GH_RELEASE_JSON=""
        if ! GH_RELEASE_JSON=$(curl -fsS --max-time 60 --max-filesize "$CURL_CAP_SMALL" \
            "$base/releases-latest.json" 2>/dev/null); then
            GH_RELEASE_HINT="could not reach the release API — nothing was changed."
            return 2
        fi
        return 0
    fi
    gh_release_fetch p2pool-starter-stack/pithead
}

# One shared refusal writer for the os-* verbs (they share one result/audit shape).
control_os_refuse() { # <cdir> <id> <actor> <action> <status rejected|failed> <reason>
    control_write_result "$1/results" "$2" "$(jq -n --arg s "$5" --arg e "$6" '{status:$s,error:$e,ts:(now|floor)}')"
    control_audit "$1/audit/control.log" "$2" "$3" "$4" "$5"
}

# The gate every os-* verb opens with: appliance only, and at most ONE os verb per drain — a
# download or install holds the single-threaded root runner for minutes, so a compromised
# container queueing a flood must not starve commit/restart intents (the worker-upgrade lesson).
control_os_gate() { # <cdir> <id> <actor> <action> — rc 0 = proceed (budget consumed)
    if ! is_appliance; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "OS updates apply only to a Pithead OS appliance — this install updates through release tarballs (the header upgrade button). Nothing was changed."
        return 1
    fi
    if [ "${CONTROL_OS_BUDGET:-0}" -le 0 ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "another OS-update step is already running in this cycle — retry in a moment."
        return 1
    fi
    CONTROL_OS_BUDGET=$((CONTROL_OS_BUDGET - 1))
    return 0
}

# The local-bundle refusals shared by os-verify and os-install (install re-runs them so a result
# can never go stale between the two clicks). Echoes the refusal reason; empty = pass. Returns 0
# for a real verdict — the caller deletes a refused bundle, only bundles that verify may sit
# staged — and 3 when rauc itself could not run, where the caller KEEPS the bundle: deleting a
# multi-GB Tor download is a verdict too, and a tool that never ran has not earned one.
os_verify_bundle_reason() { # <bundle> <target-tag>
    local bundle="$1" tag="$2" rc=0
    # Signature first: `rauc info` verifies the bundle signature against the system keyring
    # before it prints anything, so an unsigned or mis-signed file fails here, before any
    # metadata is trusted. A nonzero exit is only a signature verdict when rauc actually ran
    # and judged the file — an exec failure or a crash (rc 126/127, or death by signal) gets
    # one retry and then its own honest reason instead of masquerading as a bad signature.
    rauc info "$bundle" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ge 126 ]; then
        rc=0
        rauc info "$bundle" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -ge 126 ]; then
            printf '%s' "rauc could not run to judge the downloaded bundle — the file was kept; retry, and check the host journal if this repeats."
            return 3
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%s' "the downloaded file failed signature verification against this machine's release keys — it was deleted; check for updates and download again."
        return 0
    fi
    # Compatible: refuse a definite mismatch early. `rauc install` re-enforces this
    # authoritatively either way, so an unparseable value falls through rather than refusing.
    local sys_compat bundle_compat
    sys_compat=$(sed -n 's/^compatible=//p' "${PITHEAD_RAUC_SYSTEM_CONF:-/etc/rauc/system.conf}" 2>/dev/null | head -1)
    bundle_compat=$(rauc info --output-format=shell "$bundle" 2>/dev/null |
        sed -n "s/^RAUC_MF_COMPATIBLE='\(.*\)'\$/\1/p" | head -1)
    if [ -n "$sys_compat" ] && [ -n "$bundle_compat" ] && [ "$sys_compat" != "$bundle_compat" ]; then
        printf '%s' "the bundle is built for '$bundle_compat' but this machine is '$sys_compat' — it cannot install here and was deleted."
        return 0
    fi
    # Variant: a bundle that would flip the machine's SSH/shell posture needs the CLI's explicit
    # consent flow, never a dashboard click — no override is surfaced here on purpose.
    local bundle_version
    if os_update_needs_confirmation "$(os_running_variant)" "$(os_bundle_variant "$bundle")"; then
        printf '%s' "this bundle would change the machine's shell/SSH build variant — that consent belongs at the machine, not on the dashboard. The bundle was deleted; nothing was changed."
        return 0
    fi
    # Version floor + downgrade: the same refusals `pithead os-update` enforces (shared code) —
    # a valid signature does not stop replaying an old vulnerable release.
    bundle_version=$(os_bundle_meta "$bundle" version)
    local reason
    reason=$(os_update_version_guard "$bundle_version" 0)
    if [ -n "$reason" ]; then
        printf '%s' "$reason"
        return 0
    fi
    # Equality passes the shared guard on purpose — the CLI keeps same-version installs for
    # manual slot repair at the machine — but on the dashboard door an equal bundle is only a
    # lever for looped reinstall-and-reboot downtime, so it refuses here.
    if os_semver_ok "$bundle_version" && [ "$bundle_version" = "$(os_running_version)" ]; then
        printf '%s' "already on v$bundle_version, nothing to update — the bundle was deleted."
        return 0
    fi
    # The bundle's own stamp must match the host-derived target — a mirror serving an OLDER
    # genuinely-signed bundle at the newest tag's URL would otherwise still pass the floor.
    if [ "v$bundle_version" != "$tag" ]; then
        printf '%s' "the downloaded bundle stamps itself '${bundle_version:-unstamped}' but the published release is $tag — refusing a version-mismatched file; it was deleted."
        return 0
    fi
    return 0
}

# os-check: re-derive the latest release + its .raucb asset on the HOST, over Tor. The container
# proposes nothing here; the cached derivation is what os-download later holds the container's
# proposal against. Claim-before-dial throttle (one lookup per 10 minutes), the anti-beacon
# lesson from the one-click upgrade; a fresh cache answers without dialing at all.
control_os_check() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-check" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "started"
    local osdir tagf stampf shortstampf tag size notes rel
    osdir=$(os_update_staging_dir)
    mkdir -p "$osdir"
    tagf=$(os_update_target_file)
    stampf="$osdir/.check-stamp"
    shortstampf="$osdir/.check-stamp-short"
    if [ -z "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "an update check ran less than 10 minutes ago — retry in a few minutes."
            return 0
        fi
        if [ -n "$(find "$shortstampf" -mmin -1 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the last check could not confirm it reached the network — retry in about a minute."
            return 0
        fi
        # The throttle stamp is claimed AFTER the dial, and its window depends on whether the
        # dial confirmed it reached the release API (#1050, revised after review). rc 2 from
        # os_release_fetch does NOT mean "no real attempt": through Tor a circuit-build
        # timeout, an exit-relay refusal, or a mid-handshake TLS failure comes back as the
        # exact same curl nonzero as a purely local "no route" — and those DID put a real dial
        # on the wire. So rc 2 still claims a stamp, just a SHORT one (60s, "$shortstampf")
        # instead of the full 10 minutes: this bounds how often a dashboard-authenticated actor
        # can force another real Tor dial while the transport is degraded, without making an
        # operator who fixes a genuinely-down Tor daemon wait a full 10 minutes to find out. A
        # fetch that DID definitively reach GitHub — success, or a definitive refusal like the
        # rate limit below — still claims the full stamp exactly as before; that dial happened
        # and #1081 relies on it staying throttled (releasing it there would restore the
        # unthrottled beacon that guard exists to stop). Every other nonzero rc reached the
        # server.
        local fetch_rc=0
        os_release_fetch || fetch_rc=$?
        if [ "$fetch_rc" -ne 0 ]; then
            if [ "$fetch_rc" -eq 2 ]; then
                touch "$shortstampf"
            else
                touch "$stampf"
            fi
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "$GH_RELEASE_HINT"
            return 0
        fi
        touch "$stampf"
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the release API returned no usable release tag — nothing was changed."
            return 0
        fi
        size=$(printf '%s' "$rel" | jq -r --arg n "pithead-os-$tag.raucb" \
            '[.assets[]? | select(.name == $n)][0].size // 0' 2>/dev/null)
        notes=$(printf '%s' "$rel" | jq -r '.html_url // ""' 2>/dev/null | head -c 300)
        if ! printf '%s' "$size" | grep -qE '^[0-9]+$' || [ "$size" -le 0 ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the latest release ($tag) publishes no appliance OS bundle — nothing to download."
            return 0
        fi
        jq -n --arg t "$tag" --argjson s "$size" --arg n "$notes" \
            '{tag:$t,size:$s,notes:$n,ts:(now|floor)}' >"$tagf.tmp" && mv "$tagf.tmp" "$tagf"
    fi
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    notes=$(jq -r '.notes // ""' "$tagf" 2>/dev/null) || notes=""
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        rm -f "$tagf"
        control_os_refuse "$cdir" "$id" "$actor" "os-check" failed "the cached update target is unreadable — it was cleared; check again in a few minutes."
        return 0
    fi
    local newer=false running
    running=$(os_running_version)
    if os_semver_ok "$running" && os_semver_ok "$tag" && semver_newer "$tag" "v$running"; then
        newer=true
    fi
    # A manual check moves the operator on — drop any leftover verdict banner with it.
    if [ -f "$cdir/results/os-update-state.json" ] &&
        [ "$(jq -r '.step // "idle"' "$cdir/results/os-update-state.json" 2>/dev/null)" = "idle" ]; then
        os_state_write "$cdir" '{"step":"idle"}'
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson s "$size" --arg n "$notes" --argjson nw "$newer" \
        '{status:"checked",version:$v,size:$s,notes:$n,newer:$nw,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "checked"
}

# os-download: fetch the .raucb for the HOST-derived target to /data, resumable (`curl -C -`).
# Each intent is one bounded attempt — the dashboard resubmits on a "partial" result and the
# transfer resumes, so a Tor-slow gigabyte arrives across attempts while the runner is never
# held longer than the attempt cap. Mining is untouched throughout; nothing installs from here.
control_os_download() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-download" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "started"
    local osdir tagf tag size proposed final part
    osdir=$(os_update_staging_dir)
    tagf=$(os_update_target_file)
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "no update target is known — check for updates first."
        return 0
    fi
    proposed=$(jq -r '.version // ""' "$file")
    if [ "$proposed" != "$tag" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "requested version ${proposed:-none} is not the checked release ($tag) — check for updates first, then retry."
        return 0
    fi
    # An equal version is nothing to update — refused before a byte moves, or a compromised
    # container could loop a same-version download (gigabytes over Tor) into install and reboot
    # for forced downtime and flash wear. Same-version slot repair stays with `pithead
    # os-update` at the machine, which allows equality on purpose.
    if [ "$tag" = "v$(os_running_version)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "already on $tag, nothing to update."
        return 0
    fi
    mkdir -p "$osdir"
    final="$osdir/pithead-os-$tag.raucb"
    part="$final.partial"
    # One update at a time: a partial or staged bundle for any OTHER version is superseded.
    find "$osdir" -maxdepth 1 -name 'pithead-os-*.raucb*' \
        ! -name "pithead-os-$tag.raucb" ! -name "pithead-os-$tag.raucb.partial" -delete 2>/dev/null || true
    local have=0
    [ -f "$part" ] && have=$(wc -c <"$part" | tr -d ' ')
    if [ -f "$final" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$(wc -c <"$final" | tr -d ' ')" \
            '{status:"downloaded",version:$v,bytes:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    # Disk headroom for the REMAINDER plus a 1 GiB margin, refused up front — a download that
    # fills /data would starve the chain databases mid-write, which is far worse than waiting,
    # and the LMDB chain stores degrade well before the disk actually fills. The margin has to
    # absorb the .partial in flight plus results growth for the whole transfer.
    local avail_kb need
    avail_kb=$(df -Pk "$osdir" 2>/dev/null | awk 'NR==2{print $4}') || avail_kb=0
    need=$(((size - have) / 1024 + 1048576))
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "not enough free space on /data for the update bundle (need about $((need / 1024)) MiB free, have $((${avail_kb:-0} / 1024)) MiB) — free space and retry."
        return 0
    fi
    local url socks="" base prefix
    if base=$(os_update_test_base); then
        url="$base/pithead-os-$tag.raucb"
    else
        prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
        [ -n "$prefix" ] || prefix="172.28.0"
        socks="${prefix}.25:9050"
        url="https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead-os-$tag.raucb"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$have" --argjson t "$size" \
        '{status:"downloading",version:$v,bytes:$b,total:$t,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloading",version:$v}')"
    # Bounded attempt in the background; the loop surfaces live progress into the result the
    # dashboard is polling. curl -C - resumes from whatever the partial file already holds.
    # (Two invocations, not a conditional argument array — macOS's bash 3.2 rejects an empty
    # array expansion under set -u, and the tier-1 suite runs this function there.)
    local attempt="${PITHEAD_OS_DL_ATTEMPT:-600}" pid rc=0 bytes
    if [ -n "$socks" ]; then
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            --socks5-hostname "$socks" -o "$part" "$url" >/dev/null 2>&1 &
    else
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            -o "$part" "$url" >/dev/null 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        bytes=0
        [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"downloading",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
    done
    # Not `if ! wait`: inside that branch $? is the negation's status (always 0), which silently
    # ate every curl exit code the first time the tier-1 suite ran this.
    wait "$pid" && rc=0 || rc=$?
    bytes=0
    [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
    if [ "$rc" -eq 0 ] && [ "$bytes" -eq "$size" ]; then
        mv "$part" "$final"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson r "$have" \
            '{status:"downloaded",version:$v,bytes:$b,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        # The server sent a complete-but-wrong-sized body — not resumable, not trustworthy.
        rm -f "$part"
        control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download completed at $bytes bytes but the release publishes $size — the file was discarded; retry, and check for updates again if this repeats."
        return 0
    fi
    # rc 28 is curl's --max-time: the attempt window closed mid-transfer. The partial file is
    # kept either way — the next attempt resumes from it.
    if [ "$rc" -eq 28 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"partial",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "partial"
        return 0
    fi
    control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download failed over Tor at $bytes of $size bytes — nothing was installed; Retry resumes from where it stopped."
}

# os-verify: judge the fully-downloaded LOCAL file before anything touches a slot — signature,
# compatible, variant posture, version floor and downgrade, and the stamp-vs-tag match. A refused
# bundle is deleted; there is no override. Read-only otherwise: verifying changes nothing.
control_os_verify() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-verify" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "no fully downloaded update bundle is staged — download it first."
        return 0
    fi
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # rc 3 = rauc never ran, so no verdict was reached: the download stays staged for the
        # retry instead of being deleted on a broken tool.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "$reason"
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg va "$(os_bundle_variant "$bundle")" \
        '{status:"verified",version:$v,variant:$va,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "verified"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"verified",version:$v}')"
}

# os-install: write the verified local bundle into the inactive slot via the SAME `os_update`
# path the CLI takes (guards, floor raise, migration marker — one code path, two doors). Mining
# keeps running: RAUC writes the slot the machine is not using. On success the in-flight flag is
# persisted so the boot after the operator's explicit reboot can render an honest verdict.
control_os_install() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-install" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "no fully downloaded update bundle is staged — download and verify it first."
        return 0
    fi
    # Re-run the whole verify gate: a result can go stale between the verify click and this one,
    # and the install must never trust a judgment it did not just make itself.
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # Same keep rule as os-verify: only a real verdict deletes the staged download.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "$reason"
        return 0
    fi
    local running logf pid rc=0 pct
    running=$(os_running_version)
    logf="$osdir/.install.log"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"installing",version:$v,percent:0,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"installing",version:$v}')"
    # os_update -y in a subshell: error() exits the subshell, never this runner, and the -y only
    # waives a variant confirmation the gate above has already refused to reach. RAUC's progress
    # lines land in the log; the loop surfaces the latest percentage to the polling dashboard.
    (os_update "$bundle" -y </dev/null) >"$logf" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        pct=$(grep -oE '[0-9]+%' "$logf" 2>/dev/null | tail -1 | tr -d '%') || pct=""
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson p "${pct:-0}" \
            '{status:"installing",version:$v,percent:$p,ts:(now|floor)}')"
    done
    # Same wait shape as the download's: `if ! wait` would eat the subshell's exit code.
    wait "$pid" && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        # The raw install log is a host detail (staging paths, slot devices) and stays host-side:
        # the full tail goes to the journal, and the container-visible result carries only the
        # final error line whitelist-extracted from the log — rauc's own last word, or nothing.
        local detail
        detail=$(grep -aE '^LastError: |^\[ERROR\] |[Ff]ailed' "$logf" 2>/dev/null |
            grep -av 'pithead aborted unexpectedly' |
            tail -1 | tr -d '[:cntrl:]' | head -c 300) || detail=""
        warn "OS install failed (rc=$rc); log tail: $(tail -c 500 "$logf" 2>/dev/null | tr -d '[:cntrl:]')"
        control_os_refuse "$cdir" "$id" "$actor" "os-install" failed "the install did not complete — the running system is untouched and mining continues.${detail:+ $detail} The full install log is in the host journal."
        rm -f "$logf"
        # #1050: a terminal-failure transition. Without this the persisted step stayed
        # "installing" forever — nothing ever moved it off that value on a failed install — so
        # the dashboard kept showing an install in progress that had already ended and would
        # never finish or fail again. idle matches the state a fresh appliance starts in: Check
        # and Download are offered again on the next open.
        os_state_write "$cdir" '{"step":"idle"}'
        return 0
    fi
    local bundle_version
    bundle_version="${tag#v}"
    jq -n --arg f "$running" --arg t "$bundle_version" '{from:$f,to:$t,ts:(now|floor)}' \
        >"$(os_update_inflight_file)"
    # The staged bundle did its job — free the space before the reboot the operator will order.
    rm -f "$bundle" "$(os_update_target_file)" "$logf"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg f "$running" \
        '{status:"installed",version:$v,from:$f,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "installed"
    os_state_write "$cdir" "$(jq -n --arg v "$bundle_version" --arg f "$running" \
        '{step:"reboot-pending",version:$v,from:$f}')"
}

# os-reboot: the ONLY verb that interrupts mining, in its own allowlisted intent so rebooting the
# machine never rides implicitly on any other action. Refused unless an installed update is
# actually waiting — the dashboard must never be a general reboot lever.
control_os_reboot() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-reboot" || return 0
    if [ ! -f "$(os_update_inflight_file)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "no installed update is waiting for a reboot — nothing to finish."
        return 0
    fi
    # The install result authorizes the reboot for 24 hours, then goes stale. The gate proves
    # "an installed update is waiting", never "the operator asked just now" — within the window
    # a spool writer can still time the reboot, so the TTL bounds how long that lever stays
    # armed rather than pretending it does not exist. An unreadable timestamp is not proof of
    # freshness and refuses too; a fresh verify and install re-arms it.
    local armed_ts
    armed_ts=$(jq -r '.ts // 0' "$(os_update_inflight_file)" 2>/dev/null) || armed_ts=0
    printf '%s' "$armed_ts" | grep -qE '^[0-9]+$' || armed_ts=0
    if [ "$armed_ts" -le 0 ] || [ $(($(date +%s) - armed_ts)) -gt 86400 ]; then
        # #1050: the re-arm transition the comment above always promised but never performed.
        # The flag alone used to survive this refusal, so the persisted step stayed
        # "reboot-pending" forever — the dashboard kept offering only "Reboot now", which kept
        # refusing, with no button that ever led back to Check/Download. Clearing the expired
        # flag and the step together is what actually re-arms it: the next open finds an
        # ordinary idle appliance, exactly as the message already claimed.
        rm -f "$(os_update_inflight_file)"
        os_state_write "$cdir" '{"step":"idle"}'
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "the installed update has been waiting more than a day and has expired — check for updates again; a fresh verify and install re-arms the reboot."
        return 0
    fi
    # The result must land BEFORE the reboot order or the page never learns the reboot is real.
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rebooting",ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-reboot" "rebooting"
    systemctl reboot 2>/dev/null || true
}

control_process_request() { # <claimed-file> <control-dir>
    local file="$1" cdir="$2" id action actor size
    # Refuse a symlinked / non-regular claimed file (graft #437): a symlink dropped in requests/
    # could point the root runner at any host file. Skip + audit, never follow it.
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        warn "Control request is a symlink or not a regular file — refused."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-nonregular"
        return 0
    fi
    # Bound the root-runner DoS (#33 hardening): reject an oversized intent BEFORE jq parses it. A
    # real config.json is a few KB; 64 KB is generous headroom for the full schema plus edits.
    size=$(wc -c <"$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 65536 ]; then
        warn "Control request exceeds 64 KB ($size bytes) — refused before parsing."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-oversize"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        warn "Control request is not valid JSON — discarded."
        return 0
    fi
    id=$(jq -r '.id // ""' "$file")
    # Strict canonical uuid4 (version nibble 4, variant nibble 8/9/a/b) — the id becomes a result/
    # staged FILENAME, so pin it hard (defense-in-depth, from #438). submit() mints str(uuid4()).
    if ! printf '%s' "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        warn "Control request has a malformed id — discarded (no result can be addressed)."
        return 0
    fi
    if [ "$(jq -r '[keys[] | select(. != "id" and . != "action" and . != "config" and . != "actor" and . != "version" and . != "worker" and . != "changes" and . != "confirm")] | length' "$file")" != "0" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unexpected keys in request",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "" "invalid" "rejected"
        return 0
    fi
    actor=$(jq -r '.actor // ""' "$file")
    # The actor rides into the audit log; it originates from Caddy's X-Auth-User but the container
    # writes the file, so re-validate it against the basic_auth username charset.
    printf '%s' "$actor" | grep -qE '^[A-Za-z0-9._@-]{0,64}$' || actor="untrusted"
    action=$(jq -r '.action // ""' "$file")
    case "$action" in
    preview) control_preview "$file" "$id" "$actor" "$cdir" ;;
    commit) control_commit "$id" "$actor" "$cdir" "$(jq -r '.confirm // ""' "$file")" ;;
    upgrade) control_upgrade "$file" "$id" "$actor" "$cdir" ;;
    worker-apply) control_worker_apply "$file" "$id" "$actor" "$cdir" ;;
    worker-upgrade) control_worker_upgrade "$file" "$id" "$actor" "$cdir" ;;
    restart | apply) control_lifecycle "$action" "$id" "$actor" "$cdir" ;;
    backup) control_backup "$id" "$actor" "$cdir" ;;
    # Appliance OS update, one verb per step so every network move stays separate from every
    # destructive one; each refuses outright off the appliance.
    os-check) control_os_check "$file" "$id" "$actor" "$cdir" ;;
    os-download) control_os_download "$file" "$id" "$actor" "$cdir" ;;
    os-verify) control_os_verify "$file" "$id" "$actor" "$cdir" ;;
    os-install) control_os_install "$file" "$id" "$actor" "$cdir" ;;
    os-reboot) control_os_reboot "$file" "$id" "$actor" "$cdir" ;;
    *)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unknown action",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "${action:-none}" "rejected"
        ;;
    esac
}

# `control-run-pending`: drain the request spool, oldest first. Each request is CLAIMED (moved out
# of requests/) before a byte of it is parsed, so the container can never mutate or replay a
# request the runner is working on. Fired by the pithead-control systemd path unit.
control_run_pending() {
    [ "$(env_get DASHBOARD_CONTROL_ENABLED)" == "true" ] ||
        error "The dashboard control channel is not enabled (dashboard.control.enabled)."
    local cdir
    cdir=$(env_get CONTROL_DIR)
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/staged" "$cdir/results" "$cdir/audit"
    # Freshen the pre-masked prefill copy (#440) before draining: hand-edits to config.json since
    # the last apply show up in the editor form. A commit re-renders it again via its `apply -y`.
    render_masked_config "$cdir"
    # Time-bounded DoS sweep (#33 hardening): drop staged/ copies and stray requests/ files older
    # than an hour that no commit ever claimed, so a burst that is never committed cannot pile up
    # (staged intents already expire per-commit at 10 min; this bounds accumulation regardless).
    find "$cdir/staged" "$cdir/requests" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true
    # Orphaned claims (#548): a claimed request whose handler died before the loop's own `rm -f
    # "$claim"` below (an errexit gap, e.g.) leaves a `.claim.<pid>` file sitting directly in
    # $cdir forever. Same age cutoff — a claim in flight never lives past a single drain.
    find "$cdir" -maxdepth 1 -type f -name '.claim.*' -mmin +60 -delete 2>/dev/null || true
    # Stale backup-kit passphrases: control_backup's one-time kit self-redacts after a blocking
    # TTL, but a runner killed mid-sleep (a reboot racing the window) would leave a wallet-grade
    # passphrase in results/ in plaintext on /data indefinitely. This backstop — a fresh runner
    # after that reboot runs it — nulls the passphrase in any kit older than the TTL that still
    # carries one. Belt to the TTL's braces; the passphrase is only ever meant for the live window.
    control_redact_stale_kits "$cdir/results"
    local names name req claim n=0
    # Per-run cap (#33 hardening): a single trigger drains at most this many intents, so a flood in
    # the spool can't hold the root runner for an unbounded stretch — the leftovers wait for the
    # next path-unit fire.
    local max=50
    # Per-drain worker-apply DIAL budget (#185 hardening): worker-apply is the only action that blocks
    # the runner on a network round-trip, so cap how many dial per drain (the rest reject with a retry
    # hint). control_worker_apply reads + decrements this in the same shell.
    CONTROL_WA_BUDGET=5
    # Worker-upgrade budget (#597): an upgrade blocks the runner on a rig build (minutes), so
    # exactly one runs per drain; the rest reject with a retry hint.
    CONTROL_WU_BUDGET=1
    # OS-update budget: a bundle download attempt or a slot install holds the runner for minutes
    # too, so exactly one os-* verb runs per drain; the rest reject with a retry hint.
    CONTROL_OS_BUDGET=1
    names=$(cd "$cdir/requests" 2>/dev/null && ls -1tr -- *.json 2>/dev/null) || true
    if [ -z "$names" ]; then
        log "No pending control requests."
        return 0
    fi
    while IFS= read -r name; do
        if [ "$n" -ge "$max" ]; then
            warn "Reached the $max-request per-run cap — remaining intents wait for the next run."
            break
        fi
        req="$cdir/requests/$name"
        [ -f "$req" ] || continue
        claim="$cdir/.claim.$$"
        mv "$req" "$claim" 2>/dev/null || continue
        control_process_request "$claim" "$cdir"
        rm -f "$claim"
        n=$((n + 1))
    done <<<"$names"
    log "Processed $n control request(s)."
}

# The directory the dashboard control units live in — ONE rule, shared by the writer and both
# readers. The appliance's root is read-only by design, so /etc/systemd/system cannot take the unit
# (#791); /run/systemd/system is a first-class unit path, writable, and cleared every boot, which is
# fine because these units are derived and the boot path re-renders them. A DIY host keeps /etc.
# This was two rules until #1151: `provision_control_runner` knew about /run and `doctor` did not,
# so on a PROVISIONED appliance doctor reported "no runner units are installed" about units that
# were installed and running. That is the half of the boot health gate that never passed, so the
# slot never committed — and after #1065 the box reboots a healthy, correctly-updated appliance.
control_unit_dir() {
    if [ -n "${PITHEAD_UNIT_DIR:-}" ]; then
        printf '%s' "$PITHEAD_UNIT_DIR"
    elif is_appliance; then
        printf '%s' /run/systemd/system
    else
        printf '%s' /etc/systemd/system
    fi
}

# Physical directory the installed control units name, or "" when there is no service unit or its
# ExecStart is unparseable. One checkout has two spellings — the `current` symlink and the versioned
# dir it points at (production units carry the versioned spelling) — so this resolves to a PHYSICAL
# path; comparing the literal string would call our own unit foreign. A stranded unit usually names
# a directory that no longer exists, so resolve the deepest existing ancestor and keep the rest
# verbatim: the caller still gets a comparable, printable path instead of an empty answer.
control_units_owner_dir() {
    local unit_dir owner_dir dir tail
    unit_dir=$(control_unit_dir)
    owner_dir=$(sed -n 's|^ExecStart=\(/.*\)/pithead control-run-pending$|\1|p' \
        "$unit_dir/pithead-control.service" 2>/dev/null | head -n 1)
    [ -n "$owner_dir" ] || return 0
    dir="$owner_dir" tail=""
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        tail="/$(basename "$dir")$tail"
        dir=$(dirname "$dir")
    done
    printf '%s' "$(cd "$dir" 2>/dev/null && pwd -P)$tail"
}

# Install (or remove) the systemd trigger for the runner (#33): a path unit that fires
# `pithead control-run-pending` whenever a request file lands in the spool. Root, because `apply`
# needs iptables/chown; the service is a FIXED ExecStart with no parameter from the container, so
# a compromised dashboard cannot steer it into anything but the two known verbs. No-op on hosts
# without systemd (macOS/dev checkouts run the runner by hand).
provision_control_runner() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit_dir
    unit_dir=$(control_unit_dir)
    # Enablement must be --runtime wherever the units are runtime units: on the appliance's
    # read-only root, systemd cannot write the /etc symlink a persistent enable needs.
    local -a enable_args=(enable --now)
    case "$unit_dir" in /run/*) enable_args=(enable --runtime --now) ;; esac
    if [ "${DASHBOARD_CONTROL_ENABLED:-false}" != "true" ]; then
        if [ -e "$unit_dir/pithead-control.path" ] || [ -e "$unit_dir/pithead-control.service" ]; then
            # The unit names are box-global but a box can hold several checkouts (release bench:
            # live stack + e2e harness + bundle-smoke tmp dirs). Only remove units whose ExecStart
            # points at THIS checkout — deleting a sibling's runner strands its dashboard control
            # requests unprocessed (the editor hangs at "Previewing…" until that stack's next
            # apply/upgrade reinstalls the units).
            # Ownership compares PHYSICAL paths: one checkout has two spellings — the `current`
            # symlink and the versioned dir it points at (production units carry the versioned
            # spelling). A literal $PWD compare would call our own unit foreign and never remove
            # it. If the unit's dir is gone, resolve the deepest existing ancestor and keep the
            # rest verbatim; an unparseable ExecStart is foreign (fail safe, leave it alone).
            if [ -e "$unit_dir/pithead-control.service" ]; then
                local owner_dir
                owner_dir=$(control_units_owner_dir)
                if [ -z "$owner_dir" ] || [ "$owner_dir" != "$(pwd -P)" ]; then
                    log "Leaving the dashboard control runner units alone — they belong to another checkout."
                    return 0
                fi
            fi
            log "Removing the dashboard control runner units..."
            sudo systemctl disable --now pithead-control.path >/dev/null 2>&1 || true
            sudo rm -f "$unit_dir/pithead-control.path" "$unit_dir/pithead-control.service"
            sudo systemctl daemon-reload
        fi
        return 0
    fi
    # Already installed for this checkout — keep the routine apply sudo-free. (-F: both paths
    # are literals — versioned dirs carry dots (pithead-v1.9.3), and the glob star must not
    # read as a regex repeat.)
    if grep -qsF "PathExistsGlob=$CONTROL_DIR/requests/*.json" "$unit_dir/pithead-control.path" &&
        grep -qsF "ExecStart=$PWD/pithead control-run-pending" "$unit_dir/pithead-control.service"; then
        return 0
    fi
    # The grep above is an idempotence skip, not an ownership check. The removal branch got its
    # ownership guard when a disable-apply deleted the live stack's units; the install branch had
    # none, so any sibling checkout's apply/up (e2e harness, bundle-smoke tmp dir, disposable
    # install) silently repointed the box-global units at itself — the exact mechanism behind the
    # production control-channel stranding. A unit naming a DIFFERENT install that still exists on
    # disk is someone's live runner: refuse. A unit whose directory is gone is adoptable (the
    # failed-upgrade repair), our own unit converges (the post-restore proof depends on it), and an
    # unparseable ExecStart is left alone, fail-safe, like the removal branch. Deliberate takeover
    # has two spellings: the upgrade callsite passes the `steal` argument (after a successful
    # upgrade the units MUST repoint here — the old versioned dir still exists as the rollback, so
    # without the escape every one-click upgrade would refuse and strand the control channel), and
    # PITHEAD_STEAL_CONTROL_UNITS=1 is the operator's escape (manual migration, repair).
    if [ -e "$unit_dir/pithead-control.service" ] && [ "${1:-}" != "steal" ] &&
        [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != "1" ]; then
        local install_owner
        install_owner=$(control_units_owner_dir)
        if [ -z "$install_owner" ]; then
            warn "Not installing the dashboard control runner: $unit_dir/pithead-control.service exists but its ExecStart is not one this tool wrote. Inspect it, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to overwrite it; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
        if [ "$install_owner" != "$(pwd -P)" ] && [ -d "$install_owner" ]; then
            warn "Not installing the dashboard control runner: the box-global units belong to the install at $install_owner. Run this from that checkout, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to take the units over; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
    fi
    log "Installing the dashboard control runner (systemd path unit)..."
    sudo tee "$unit_dir/pithead-control.service" >/dev/null <<EOF
[Unit]
Description=pithead dashboard control runner (#33)

[Service]
Type=oneshot
User=root
WorkingDirectory=$PWD
ExecStart=$PWD/pithead control-run-pending
EOF
    sudo tee "$unit_dir/pithead-control.path" >/dev/null <<EOF
[Unit]
Description=Watch the pithead control spool for dashboard requests (#33)

[Path]
PathExistsGlob=$CONTROL_DIR/requests/*.json

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl "${enable_args[@]}" pithead-control.path >/dev/null 2>&1 ||
        warn "Could not enable pithead-control.path — dashboard config changes will not be applied until it is enabled."
}

# --- Main Execution ---

# #493: a subcommand's -h/--help must print usage and exit 0 BEFORE any side effect, and a
# subcommand that takes no options must reject an unrecognized flag instead of silently ignoring it
# and running anyway. `pithead upgrade --help` used to run a full upgrade (image pull + container
# recreation) — on the v1.4.0 deploy that recreation collided with the real upgrade and corrupted
# the dashboard DB (#489). A --help must never mutate the host.
_help_requested() { # "$@" — return 0 if any argument is -h/--help
    local a
    for a in "$@"; do
        case "$a" in
        -h | --help) return 0 ;;
        esac
    done
    return 1
}
_reject_options() { # <verb> "$@" — this verb takes no options; error on any leftover argument
    local verb="$1"
    shift
    [ "$#" -eq 0 ] || error "Unknown option for $verb: '$1'. This command takes no options. Run '$0 $verb -h' or '$0 help'."
}

main() {
    # Chained subcommands (#94): when every argument is a bare subcommand name, run them
    # left-to-right as a chain. Any other token (a flag, a service name, an archive path) keeps
    # the invocation on the single-command path below, unchanged.
    if [ "$#" -ge 2 ]; then
        local _tok _chain=1
        for _tok in "$@"; do
            if ! is_pithead_command "$_tok"; then
                _chain=0
                break
            fi
        done
        if [ "$_chain" -eq 1 ]; then
            run_chain "$@"
            return 0
        fi
    fi

    local cmd="${1:-}"
    if [ -n "$cmd" ]; then shift; fi

    # #493: -h/--help on any subcommand prints help and exits 0 before ANY side effect. `logs` is the
    # one deliberate passthrough (its args go to `docker compose logs`), so it opts out and forwards
    # -h/--help downstream. The bare `pithead -h/--help/help` is its own command in the case below.
    case "$cmd" in
    "" | help | -h | --help | logs) ;;
    *) if _help_requested "$@"; then
        show_help
        exit 0
    fi ;;
    esac

    # Make the stack version + build provenance available to any `docker compose [up] build` this
    # invocation runs, so the dashboard image bakes in its version badge (Issue #58).
    export_build_provenance

    case "$cmd" in
    "")
        # No command: first-time users get setup, deployed users get help.
        if is_deployed; then show_help; else setup; fi
        ;;
    setup)
        for arg in "$@"; do
            case "$arg" in
            --skip-optimize) SKIP_OPTIMIZE=1 ;;
            --skip-deps) SKIP_DEPS=1 ;;
            *) error "Unknown option for setup: $arg. Run '$0 help'." ;;
            esac
        done
        setup
        ;;
    apply) apply "$@" ;;
    render)
        _reject_options render "$@"
        render_derived
        ;;
    up)
        _reject_options up "$@"
        require_deployed
        stack_up
        ;;
    down)
        _reject_options down "$@"
        require_env
        stack_down
        ;;
    restart)
        require_deployed
        stack_restart "$@"
        ;;
    upgrade)
        _reject_options upgrade "$@"
        require_deployed
        stack_upgrade
        ;;
    logs)
        require_env
        log "Following logs (Ctrl+C to exit)..."
        docker compose logs -f "$@"
        ;;
    status)
        _reject_options status "$@"
        require_env
        stack_status || exit 1
        ;;
    doctor)
        case "${1:-}" in
        "") doctor || exit 1 ;;
        --json)
            [ "$#" -eq 1 ] || error "doctor --json takes no further options. Run '$0 help'."
            doctor_json || exit 1
            ;;
        *) error "Unknown option for doctor: '$1'. Run '$0 help'." ;;
        esac
        ;;
    support-bundle) stack_support_bundle "$@" ;;
    reset-dashboard)
        require_deployed
        reset_dashboard "$@"
        ;;
    config-reset) config_reset "$@" ;;
    factory-reset) factory_reset "$@" ;;
    backup) stack_backup "$@" ;;
    restore) stack_restore "$@" ;;
    uninstall) stack_uninstall "$@" ;;
    firstboot-wizard) firstboot_wizard "$@" ;;
    load-images)
        _reject_options load-images "$@"
        load_baked_images
        ;;
    local-miner)
        _reject_options local-miner "$@"
        # A rig has no .env and never will — there is no stack on it to render one.
        [ "$(machine_role)" = "rig" ] || require_env
        provision_local_miner
        ;;
    os-update) os_update "$@" ;;
    control-run-pending)
        _reject_options control-run-pending "$@"
        require_deployed
        control_run_pending
        ;;
    onion-client-key)
        _reject_options onion-client-key "$@"
        onion_client_key
        ;;
    rotate-dashboard-onion) rotate_dashboard_onion "$@" ;;
    rotate-secrets) rotate_secrets "$@" ;;
    render-quadlet)
        rq_env=".env" rq_out="./quadlet"
        while [ $# -gt 0 ]; do
            case "$1" in
            --env)
                [ -n "${2:-}" ] || error "render-quadlet: --env needs a file argument."
                rq_env="$2"
                shift 2
                ;;
            --out)
                [ -n "${2:-}" ] || error "render-quadlet: --out needs a directory argument."
                rq_out="$2"
                shift 2
                ;;
            *) error "Unknown option for render-quadlet: $1. Run '$0 help'." ;;
            esac
        done
        render_quadlet_units "$rq_env" "$rq_out"
        ;;
    version | -V | --version) show_version ;;
    help | -h | --help) show_help ;;
    *) error "Unknown command: $cmd. Run '$0 help'." ;;
    esac
}

if [ "$_STACK_SOURCED" = "0" ]; then
    main "$@"
fi
