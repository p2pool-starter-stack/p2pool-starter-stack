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

    # Tari mode → gRPC address / compose profile (#103/#1855), mirroring Monero above. local -> the
    # bundled node at its bridge IP plus the local_tari profile. remote -> a third-party node's
    # host:port. off -> neither profile nor merge-mining, so the address stays the stock local
    # default as an INERT placeholder: the profiled-off tari service still interpolates it, and
    # p2pool's entrypoint is to drop the --merge-mine triple from argv on TARI_MODE=off (#1903).
    local tari_grpc_addr="${NETWORK_PREFIX}.27:18142"
    if [ "$TARI_MODE" == "local" ]; then
        profiles="${profiles:+$profiles,}local_tari"
    elif [ "$TARI_MODE" == "remote" ]; then
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

    # XvB config. The xmrig_proxy.* alias is gone (#1832) — migrated to xvb.* before any read.
    local xvb_enabled xvb_url xvb_donor xvb_donation_level xvb_tor
    xvb_enabled=$(jq -r 'if .xvb.enabled != null then .xvb.enabled else "true" end' "$CONFIG_FILE")
    # Route XvB donation mining through Tor by default (#166); xvb.tor:false opts out for max yield.
    # config_bool so xvb.tor=false (route XvB over clearnet) is honoured rather than coerced to Tor (#294).
    xvb_tor=$(normalize_bool "$(config_bool '.xvb.tor' true)")
    xvb_url=$(jq -r '.xvb.url // empty' "$CONFIG_FILE")
    [ -z "$xvb_url" ] && xvb_url="na.xmrvsbeast.com:4247"
    xvb_donor=$(jq -r '.xvb.donor_id // empty' "$CONFIG_FILE")
    case "$xvb_donor" in
    "" | auto | DYNAMIC_ID) xvb_donor="${MONERO_WALLET:0:8}" ;;
    esac
    # Donation tier target: auto (default) / donor|vip|whale|mega
    xvb_donation_level=$(jq -r '.xvb.donation_level // empty' "$CONFIG_FILE")
    [ -z "$xvb_donation_level" ] && xvb_donation_level="auto"

    # How much Tari blocks the stack (#31/#35/#51/#897). monerod is required and not
    # configurable. A Tari outage never rejects workers regardless of this flag — p2pool keeps
    # mining Monero through it — but tari_required (default true) makes the miner wait for Tari's
    # sync, and the dashboard's sync gate STOPS p2pool and xmrig-proxy while it waits. TARI_MODE
    # off therefore decides this outright (#1855): there is no Tari node to wait for, and a
    # machine that declined merge-mining must still mine Monero. local/remote keep the override.
    local tari_required
    tari_required=$(jq -r --arg m "$TARI_MODE" 'if $m == "off" then "false" elif .dashboard.tari_required != null then .dashboard.tari_required | tostring else "true" end' "$CONFIG_FILE")

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
    if [ "$TARI_MODE" != "local" ]; then
        # No local Tari container to cap in remote or off mode (#103/#1855) — the auto-calc below is
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
TARI_WALLET_ADDRESS=${TARI_WALLET:-your_tari_wallet_address}
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
TARI_MODE=$TARI_MODE
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
