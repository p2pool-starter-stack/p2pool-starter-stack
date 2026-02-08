#!/usr/bin/env bash
#
# Deployment Script for Monero + Tari Merge Mining Stack
# Orchestrates directory initialization, configuration generation, Tor service provisioning,
# and system-level kernel optimizations (HugePages) for high-performance mining.
#
set -e

# --- Logging Utilities ---
log() { echo -e "\033[1;32m[DEPLOY]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- 1. System Prerequisite Verification ---
# Validates that all necessary dependencies and environment conditions are met.
command -v jq >/dev/null || error "jq is required. Run: sudo apt install jq"
command -v docker >/dev/null || error "docker is required."
docker compose version >/dev/null 2>&1 || error "Docker Compose V2 is required (command: 'docker compose')."
[ -f "config.json" ] || error "config.json not found."

# Determine the invoking user to maintain correct file ownership when running via sudo
REAL_USER="${SUDO_USER:-$USER}"

# Verify AVX2 instruction set support (Critical for RandomX mining efficiency)
if ! grep -q "avx2" /proc/cpuinfo; then
    warn "AVX2 not detected. Mining performance will be poor."
fi

# State flag to track if a system reboot is required due to kernel parameter updates
REBOOT_REQUIRED=false

# --- 2. Directory Initialization & Configuration Parsing ---
# Parses 'config.json' to establish persistent data volumes and directory structures.
log "Parsing configuration and initializing data directories..."

# Resolve data directories from config.json, defaulting to local ./data if unspecified
MONERO_DIR=$(jq -r '.monero.data_dir // empty' config.json)
if [ -z "$MONERO_DIR" ] || [ "$MONERO_DIR" == "DYNAMIC_DATA" ]; then
    MONERO_DIR="$PWD/data/monero"
fi

TARI_DIR=$(jq -r '.tari.data_dir // empty' config.json)
if [ -z "$TARI_DIR" ] || [ "$TARI_DIR" == "DYNAMIC_DATA" ]; then
    TARI_DIR="$PWD/data/tari"
fi

P2POOL_DIR=$(jq -r '.p2pool.data_dir // empty' config.json)
if [ -z "$P2POOL_DIR" ] || [ "$P2POOL_DIR" == "DYNAMIC_DATA" ]; then
    P2POOL_DIR="$PWD/data/p2pool"
fi

TOR_DATA_DIR=$(jq -r '.tor.data_dir // empty' config.json)
if [ -z "$TOR_DATA_DIR" ] || [ "$TOR_DATA_DIR" == "DYNAMIC_DATA" ]; then
    TOR_DATA_DIR="$PWD/data/tor"
fi

DASHBOARD_DIR=$(jq -r '.dashboard.data_dir // empty' config.json)
if [ -z "$DASHBOARD_DIR" ] || [ "$DASHBOARD_DIR" == "DYNAMIC_DATA" ]; then
    DASHBOARD_DIR="$PWD/data/dashboard"
fi

# Create directory hierarchy
mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"

# Enforce permissions for Tor container (UID 100 / GID 101 matches standard Alpine/Debian Tor packages)
sudo chown -R 100:101 "$TOR_DATA_DIR"
sudo chown -R "$REAL_USER":"$REAL_USER" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR"
mkdir -p "$P2POOL_DIR/stats"
sudo chmod -R 755 "$P2POOL_DIR/stats"

# Generate a cryptographically secure token for XMRig Proxy API authentication
PROXY_AUTH_TOKEN=$(openssl rand -hex 12)

# Generate preliminary environment configuration (.env)
# Required to bootstrap the Tor service and generate Onion addresses prior to full stack initialization.
cat <<EOF > .env
MONERO_ONION_ADDRESS=placeholder
P2POOL_ONION_ADDRESS=placeholder
MONERO_DATA_DIR=$MONERO_DIR
TARI_DATA_DIR=$TARI_DIR
P2POOL_DATA_DIR=$P2POOL_DIR
DASHBOARD_DATA_DIR=$DASHBOARD_DIR
TOR_DATA_DIR=$TOR_DATA_DIR
P2POOL_PORT=37889
P2POOL_FLAGS=
MONERO_NODE_USERNAME=placeholder
MONERO_NODE_PASSWORD=placeholder
MONERO_WALLET_ADDRESS=placeholder
TARI_WALLET_ADDRESS=placeholder
XVB_POOL_URL=na.xmrvsbeast.com:4247
XVB_DONOR_ID=placeholder
XVB_ENABLED=true
P2POOL_URL=172.28.0.28:3333
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=$PROXY_AUTH_TOKEN
MONERO_PRUNE=1
EOF

# --- 3. Tor Hidden Service Provisioning ---
# Bootstraps the Tor container to generate persistent Onion hostnames.
log "Initializing Tor service to generate Onion addresses..."
docker compose up -d tor
log "Waiting for Hidden Services to propagate (15s)..."
sleep 15

# Retrieve generated Onion Hostnames from the running Tor container
MONERO_ONION=$(docker exec tor cat /var/lib/tor/monero/hostname)
TARI_ONION=$(docker exec tor cat /var/lib/tor/tari/hostname)
P2POOL_ONION=$(docker exec tor cat /var/lib/tor/p2pool/hostname)

# --- 4. Environment Configuration Finalization ---
# Re-generates the final .env file with populated Onion addresses and user credentials.
log "Finalizing environment configuration (.env)..."
MONERO_USER=$(jq -r .monero.node_username config.json)
MONERO_PASS=$(jq -r .monero.node_password config.json)
MONERO_WALLET=$(jq -r .monero.wallet_address config.json)
TARI_WALLET=$(jq -r .tari.wallet_address config.json)

# Pruning Configuration
MONERO_PRUNE_BOOL=$(jq -r '.monero.prune // "true"' config.json)
if [ "$MONERO_PRUNE_BOOL" == "true" ]; then
    MONERO_PRUNE=1
else
    MONERO_PRUNE=0
fi

# P2Pool Network Configuration (Main/Mini/Nano)
POOL_TYPE=$(jq -r '.p2pool.pool // "main"' config.json)
P2POOL_FLAGS=""
P2POOL_PORT="37889"
if [ "$POOL_TYPE" == "mini" ]; then
    P2POOL_FLAGS="--mini"
    P2POOL_PORT="37888"
elif [ "$POOL_TYPE" == "nano" ]; then
    P2POOL_FLAGS="--nano"
    P2POOL_PORT="37890"
fi

# XMRig Proxy Settings
XVB_POOL_URL=$(jq -r '.xmrig_proxy.url // empty' config.json)
[ -z "$XVB_POOL_URL" ] && XVB_POOL_URL="na.xmrvsbeast.com:4247"

XVB_ENABLED=$(jq -r '.xmrig_proxy.enabled // "true"' config.json)

# Smart Donor ID: Automatically derives ID from wallet address if not explicitly configured.
XVB_DONOR_ID=$(jq -r '.xmrig_proxy.donor_id // empty' config.json)
if [ -z "$XVB_DONOR_ID" ] || [ "$XVB_DONOR_ID" == "DYNAMIC_ID" ]; then
    log "Configuring Donor ID using first 8 characters of Monero wallet."
    XVB_DONOR_ID=$(echo "$MONERO_WALLET" | cut -c 1-8)
fi

cat <<EOF > .env
MONERO_DATA_DIR=$MONERO_DIR
TARI_DATA_DIR=$TARI_DIR
P2POOL_DATA_DIR=$P2POOL_DIR
DASHBOARD_DATA_DIR=$DASHBOARD_DIR
TOR_DATA_DIR=$TOR_DATA_DIR
MONERO_NODE_USERNAME=$MONERO_USER
MONERO_NODE_PASSWORD=$MONERO_PASS
MONERO_WALLET_ADDRESS=$MONERO_WALLET
TARI_WALLET_ADDRESS=$TARI_WALLET
MONERO_ONION_ADDRESS=$MONERO_ONION
TARI_ONION_ADDRESS=$TARI_ONION
P2POOL_ONION_ADDRESS=$P2POOL_ONION
P2POOL_FLAGS=$P2POOL_FLAGS
P2POOL_PORT=$P2POOL_PORT
XVB_POOL_URL=$XVB_POOL_URL
XVB_DONOR_ID=$XVB_DONOR_ID
XVB_ENABLED=$XVB_ENABLED
P2POOL_URL=172.28.0.28:3333
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=$PROXY_AUTH_TOKEN
MONERO_PRUNE=$MONERO_PRUNE
EOF

# --- 5. Service Configuration Injection ---
# Injects dynamic configuration into service templates (e.g., Tari config.toml).
log "Injecting service configurations..."
cp build/tari/config.toml.template build/tari/config.toml
TARI_ONION_SHORT=$(echo "$TARI_ONION" | cut -d'.' -f1)
sed -i "s/<your_tari_onion_address_no_extension>/$TARI_ONION_SHORT/g" build/tari/config.toml

# --- 6. Kernel Optimization (HugePages) ---
# Configures system HugePages to optimize RandomX memory access latency.
log "Applying RandomX optimizations (HugePages)..."

# 6a. Apply runtime configuration (Non-persistent)
sudo sysctl -w vm.nr_hugepages=3072

# 6b. Persist configuration via Bootloader (GRUB)
if [ -f "/etc/default/grub" ]; then
    if ! grep -q "hugepages=" /etc/default/grub; then
        log "Updating GRUB configuration for persistent HugePages..."
        sudo cp /etc/default/grub /etc/default/grub.bak
        sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never /' /etc/default/grub
        if command -v update-grub >/dev/null; then
            sudo update-grub
            REBOOT_REQUIRED=true
        else
            warn "'update-grub' not found. Please manually update your bootloader to enable HugePages."
        fi
    else
        log "HugePages already configured in GRUB."
    fi
fi

# --- 7. Deployment Summary ---
log "Deployment preparation complete!"
if [ "$REBOOT_REQUIRED" = true ]; then
    echo -e "\n\033[1;33m[!] ATTENTION: System optimization requires a reboot.\033[0m"
    echo "Please run: 'sudo reboot' now."
    echo "After reboot, start the stack with: 'docker compose up -d'"
else
    echo "You can now start the stack: docker compose up -d"
fi