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
