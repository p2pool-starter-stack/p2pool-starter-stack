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
