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
    MONERO_NODE_HOST | MONERO_RPC_PORT | MONERO_ZMQ_PORT | TARI_GRPC_ADDRESS)
        flag=CONFIRM msg="${key%%_*} node endpoint ($key): ${old:-unset} → $new — the stack points its RPC client THERE and trusts the chain data, block templates and share heights that address returns. Confirm-gated, not free-commit, because it moves TRUST rather than disk; the host probes the new endpoint before accepting it, and putting the old address back reverses it."
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
