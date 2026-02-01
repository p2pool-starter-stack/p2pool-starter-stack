#!/usr/bin/env bash
set -e

# --- Helper Functions ---
log() { echo -e "\033[1;32m[DEPLOY]\033[0m $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- 1. Pre-flight Checks ---
command -v jq >/dev/null || error "jq is required. Run: sudo apt install jq"
command -v docker >/dev/null || error "docker is required."
[ -f "config.json" ] || error "config.json not found."

if ! grep -q "avx2" /proc/cpuinfo; then
    echo "WARNING: AVX2 not detected. Mining performance will be poor."
fi

# Flag to track if a reboot is needed
REBOOT_REQUIRED=false

# --- 2. Initialize Paths & Preliminary .env ---
log "Reading configuration and initializing paths..."

# Determine Data Directories
MONERO_DIR=$(jq -r '.monero.data_dir // "DYNAMIC_DATA"' config.json)
[ "$MONERO_DIR" == "DYNAMIC_DATA" ] && MONERO_DIR="$PWD/data/monero"

TARI_DIR=$(jq -r '.tari.data_dir // "DYNAMIC_DATA"' config.json)
[ "$TARI_DIR" == "DYNAMIC_DATA" ] && TARI_DIR="$PWD/data/tari"

P2POOL_DIR=$(jq -r '.p2pool.data_dir // "DYNAMIC_DATA"' config.json)
[ "$P2POOL_DIR" == "DYNAMIC_DATA" ] && P2POOL_DIR="$PWD/data/p2pool"

TOR_DATA_DIR=$(jq -r '.tor.data_dir // "DYNAMIC_DATA"' config.json)
[ "$TOR_DATA_DIR" == "DYNAMIC_DATA" ] && TOR_DATA_DIR="$PWD/data/tor"

DASHBOARD_DIR=$(jq -r '.dashboard.data_dir // "DYNAMIC_DATA"' config.json)
[ "$DASHBOARD_DIR" == "DYNAMIC_DATA" ] && DASHBOARD_DIR="$PWD/data/dashboard"

# Create directories immediately to prevent Docker volume errors
mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"
sudo chown -R 100:101 "$TOR_DATA_DIR" # Tor user inside container is UID 100
sudo chown -R $USER:$USER "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR"
mkdir -p "$P2POOL_DIR/stats"
sudo chmod -R 755 "$P2POOL_DIR/stats"

# Write a preliminary .env so 'docker compose' has valid volume paths
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
EOF

# --- 3. Start Tor & Generate Onion Addresses ---
log "Starting Tor to generate Onion addresses..."
docker compose up -d tor
log "Waiting for Tor hidden services to populate (15s)..."
sleep 15

# Get Onion Addresses (fetch from container)
MONERO_ONION=$(docker exec tor cat /var/lib/tor/monero/hostname)
TARI_ONION=$(docker exec tor cat /var/lib/tor/tari/hostname)
P2POOL_ONION=$(docker exec tor cat /var/lib/tor/p2pool/hostname)

# --- 4. Finalize .env File ---
log "Gathering remaining credentials and finalizing .env..."
MONERO_USER=$(jq -r .monero.node_username config.json)
MONERO_PASS=$(jq -r .monero.node_password config.json)
MONERO_WALLET=$(jq -r .monero.wallet_address config.json)
TARI_WALLET=$(jq -r .tari.wallet_address config.json)
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
EOF

# --- 5. Apply Templates ---
log "Applying configuration templates..."
cp build/tari/config.toml.template build/tari/config.toml
TARI_ONION_SHORT=$(echo "$TARI_ONION" | cut -d'.' -f1)
sed -i "s/<your_tari_onion_address_no_extension>/$TARI_ONION_SHORT/g" build/tari/config.toml

# --- 6. Kernel & GRUB Optimization (HugePages) ---
log "Optimizing system for RandomX (HugePages)..."

# 6a. Apply immediately
sudo sysctl -w vm.nr_hugepages=3072

# 6b. Update GRUB for permanence
if [ -f "/etc/default/grub" ]; then
    if ! grep -q "hugepages=" /etc/default/grub; then
        log "Updating /etc/default/grub..."
        sudo cp /etc/default/grub /etc/default/grub.bak
        sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never /' /etc/default/grub
        sudo update-grub
        REBOOT_REQUIRED=true
    else
        log "HugePages already configured in GRUB."
    fi
fi

# --- 7. Final Status ---
log "Deployment preparation complete!"
if [ "$REBOOT_REQUIRED" = true ]; then
    echo -e "\n\033[1;33m[!] ATTENTION: System optimization requires a reboot.\033[0m"
    echo "Please run: 'sudo reboot' now."
    echo "After reboot, start the stack with: 'docker compose up -d'"
else
    echo "You can now start the stack: docker compose up -d"
fi