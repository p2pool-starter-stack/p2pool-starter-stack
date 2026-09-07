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

    # tari.mode (#103/#1855): monero.mode's local/remote switch plus "off" — no merge-mining at all.
    # Read BEFORE the required-fields gate below, which depends on it, and ahead of everything else
    # so a bad value fails first. MISSING-KEY DEFAULT STAYS "local": 1.x never wrote it (#1855).
    TARI_MODE=$(jq -r '.tari.mode // "local"' "$CONFIG_FILE")
    case "$TARI_MODE" in
    local | remote | off) ;;
    *) error "tari.mode must be \"local\", \"remote\" or \"off\" (got \"$TARI_MODE\")." ;;
    esac

    # Required fields. "off" needs no Tari address: nothing merge-mines, so nothing is paid (#1855).
    MONERO_WALLET=$(jq -r '.monero.wallet_address // empty' "$CONFIG_FILE")
    TARI_WALLET=$(jq -r '.tari.wallet_address // empty' "$CONFIG_FILE")
    if [ -z "$MONERO_WALLET" ] || { [ -z "$TARI_WALLET" ] && [ "$TARI_MODE" != "off" ]; }; then
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
    # forms. "unchecked" (no usable python3) passes — never a false reject. "off" merge-mines
    # nothing, so an absent or stale payout address is inert and must not block apply (#1855).
    case "$TARI_MODE:$(tari_address_type "$TARI_WALLET")" in
    off:* | *:ok | *:unchecked) ;;
    *:checksum) error "tari.wallet_address fails its checksum — at least one character is mistyped, and a mistyped address means Tari rewards are silently lost. Re-copy the address (base58 or emoji form) from your Tari wallet and try again." ;;
    *:network) error "tari.wallet_address is for a different Tari network (a testnet). This stack mines MAINNET Tari — use your mainnet address." ;;
    *) error "tari.wallet_address (${#TARI_WALLET} chars) is not a valid Tari address in either the base58 or the emoji form. Copy it from your Tari wallet." ;;
    esac

    MONERO_MODE=$(jq -r '.monero.mode // "local"' "$CONFIG_FILE")
    case "$MONERO_MODE" in
    local | remote) ;;
    *) error "monero.mode must be \"local\" or \"remote\" (got \"$MONERO_MODE\")." ;;
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
            error "tari.view_key is set but tari.mode is \"$TARI_MODE\". Payout confirmation scans the LOCAL Tari node, so it needs tari.mode: local — unset tari.view_key, or use a local Tari node."
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

    migrate_legacy_workers
    validate_worker_endpoints
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
