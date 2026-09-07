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
    # The three dashboard-onion values ride on the dashboard unit as they do on the compose
    # service (#1880): the header shows the .onion URL from them (#1853). Display-only; the
    # client keys are never passed in, so the container cannot hand out what opens the onion (#1896).
    cat >"$outdir/dashboard.container" <<EOF
[Unit]
Description=pithead dashboard
[Container]
ContainerName=dashboard
Image=$reg/pithead-dashboard:$ver
Network=host
Environment=HOST_IP=$(_qenv HOST_IP) TZ=$(_qenv DASHBOARD_TZ) MONERO_NODE_HOST=$(_qenv MONERO_NODE_HOST) MONERO_NODE_USERNAME=$(_qenv MONERO_NODE_USERNAME) MONERO_NODE_PASSWORD=$(_qenv MONERO_NODE_PASSWORD) MONERO_PRUNE=$(_qenv MONERO_PRUNE) MONERO_CLEARNET_SYNC=$(_qenv MONERO_CLEARNET_SYNC) TARI_CLEARNET_SYNC=$(_qenv TARI_CLEARNET_SYNC) CLEARNET_STATE_DIR=/clearnet-state TOR_EGRESS_FIREWALL=$(_qenv TOR_EGRESS_FIREWALL) TOR_AUTO_HEAL=$(_qenv TOR_AUTO_HEAL) P2POOL_CLEARNET=$(_qenv P2POOL_CLEARNET) P2POOL_URL=$(_qenv P2POOL_URL) MONERO_WALLET_ADDRESS=$(_qenv MONERO_WALLET_ADDRESS) STRATUM_PORT=$(_qenv STRATUM_PORT) TARI_REQUIRED=$(_qenv TARI_REQUIRED) TARI_GRPC_ADDRESS=$(_qenv TARI_GRPC_ADDRESS) XVB_ENABLED=$(_qenv XVB_ENABLED) XVB_TOR_ENABLED=$(_qenv XVB_TOR_ENABLED) XVB_DONATION_LEVEL=$(_qenv XVB_DONATION_LEVEL) PROXY_HOST=$prefix.29 PROXY_API_PORT=$(_qenv PROXY_API_PORT) PROXY_AUTH_TOKEN=$(_qenv PROXY_AUTH_TOKEN) DOCKER_PROXY_URL=tcp://127.0.0.1:12375 DOCKER_CONTROL_URL=tcp://127.0.0.1:12376 LOCAL_MONERO_HOST=$prefix.26 MINING_NET_CIDR=$subnet TOR_SOCKS_PROXY=socks5h://$prefix.25:9050${payout_env} DASHBOARD_CHECK_UPDATES=$(_qenv DASHBOARD_CHECK_UPDATES) DASHBOARD_CONTROL_ENABLED=$(_qenv DASHBOARD_CONTROL_ENABLED) DASHBOARD_FAIL_CLOSED=$(_qenv DASHBOARD_FAIL_CLOSED) DASHBOARD_ONION_ENABLED=$(_qenv DASHBOARD_ONION_ENABLED) DASHBOARD_ONION_ADDRESS=$(_qenv DASHBOARD_ONION_ADDRESS) DASHBOARD_ONION_CLIENT_AUTH=$(_qenv DASHBOARD_ONION_CLIENT_AUTH) TELEGRAM_ENABLED=$(_qenv TELEGRAM_ENABLED)
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
