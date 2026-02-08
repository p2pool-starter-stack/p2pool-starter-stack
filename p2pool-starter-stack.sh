#!/usr/bin/env bash
#
# Deployment Script for Monero + Tari Merge Mining Stack
# Orchestrates directory initialization, configuration generation, Tor service provisioning,
# and system-level kernel optimizations (HugePages) for high-performance mining.
#
set -Eeuo pipefail

# --- Logging Utilities ---
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'

log() { echo -e "${C_GREEN}[DEPLOY]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; exit 1; }

# Detect Operating System
readonly OS_TYPE="$(uname -s)"
readonly CONFIG_FILE="config.json"
readonly ENV_FILE=".env"
readonly REAL_USER="${SUDO_USER:-$USER}"

REBOOT_REQUIRED=false

# --- Helper Functions ---

stack_up() {
    log "Starting stack..."
    docker compose up -d
    log "Stack started successfully!"
    log "Dashboard is available at: http://$(hostname):8000"
}

stack_down() {
    log "Stopping stack..."
    docker compose down
    log "Stack stopped."
}

stack_restart() {
    log "Restarting stack..."
    docker compose restart
    log "Stack restarted."
}

ask_yes_no() {
    local prompt="$1"
    local action="$2"
    read -r -p "$prompt (y/N): " RESPONSE
    if [[ "$RESPONSE" =~ ^[Yy] ]]; then
        $action
    else
        log "Action cancelled."
    fi
}

show_help() {
    echo "Usage: $0 [OPTION]"
    echo "Deploy and manage the P2Pool Starter Stack."
    echo ""
    echo "Options:"
    echo "  -s              Interactive start (ask to bring up stack)"
    echo "  -sf             Force start (bring up stack immediately)"
    echo "  -d              Interactive stop (ask to bring down stack)"
    echo "  -df             Force stop (bring down stack immediately)"
    echo "  -r              Interactive restart (ask to restart stack)"
    echo "  -rf             Force restart (restart stack immediately)"
    echo "  -l, --logs      Follow container logs"
    echo "  -st, --status   Show stack status"
    echo "  -h, --help      Show this help message"
}

prompt_start_stack() {
    read -r -p "Start the P2Pool Starter Stack now? (y/N): " START_NOW
    if [[ "$START_NOW" =~ ^[Yy] ]]; then
        stack_up
    else
        echo "You can start the stack later with: $0 -s"
    fi
}

safe_sed() {
    local pattern="$1"
    local file="$2"
    if [ "$OS_TYPE" == "Darwin" ]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# --- Deployment Steps ---

check_previous_deployment() {
    if [ -f "$ENV_FILE" ] && grep -q "DEPLOYMENT_COMPLETED=true" "$ENV_FILE"; then
        warn "Previous deployment detected."
        read -r -p "Rerun deployment script? (y/N): " RERUN
        if [[ ! "$RERUN" =~ ^[Yy] ]]; then
            log "Skipping deployment steps."
            log "Deployment preparation complete!"
            prompt_start_stack
            exit 0
        fi
    fi
}

check_prerequisites() {
    log "Verifying system prerequisites..."
    command -v jq >/dev/null || error "jq is required. Run: sudo apt install jq"
    command -v docker >/dev/null || error "docker is required."
    docker compose version >/dev/null 2>&1 || error "Docker Compose V2 is required (command: 'docker compose')."
    command -v openssl >/dev/null || error "openssl is required for generating secure tokens."
    docker info >/dev/null 2>&1 || error "Docker daemon is not reachable. Ensure Docker is running and your user has permissions."

    # Verify AVX2 instruction set support
    if [ "$OS_TYPE" == "Darwin" ]; then
        if ! sysctl -a | grep "machdep.cpu" | grep -q "AVX2"; then
            warn "AVX2 not detected. Mining performance will be poor."
        fi
    else
        if ! grep -q "avx2" /proc/cpuinfo; then
            warn "AVX2 not detected. Mining performance will be poor."
        fi
    fi
}

ensure_config_exists() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "$CONFIG_FILE not found. Starting interactive setup..."
        echo "Please provide the following details to generate a minimal configuration:"

        read -r -p "Enter Monero Wallet Address: " IN_MONERO_WALLET
        read -r -p "Enter Monero Node Username: " IN_MONERO_USER
        read -r -s -p "Enter Monero Node Password: " IN_MONERO_PASS
        echo ""
        read -r -p "Enter Tari Wallet Address: " IN_TARI_WALLET

        if [ -z "$IN_MONERO_WALLET" ] || [ -z "$IN_MONERO_USER" ] || [ -z "$IN_MONERO_PASS" ] || [ -z "$IN_TARI_WALLET" ]; then
            error "All fields are required. Aborting."
        fi

        cat <<EOF > "$CONFIG_FILE"
{
    "monero": {
        "wallet_address": "$IN_MONERO_WALLET",
        "node_username": "$IN_MONERO_USER",
        "node_password": "$IN_MONERO_PASS"
    },
    "tari": {
        "wallet_address": "$IN_TARI_WALLET"
    }
}
EOF
        log "$CONFIG_FILE created successfully."
    fi
}

parse_and_validate_config() {
    log "Parsing configuration..."
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE is not valid JSON."
    fi

    # Extract Required Fields
    MONERO_USER=$(jq -r '.monero.node_username // empty' "$CONFIG_FILE")
    MONERO_PASS=$(jq -r '.monero.node_password // empty' "$CONFIG_FILE")
    MONERO_WALLET=$(jq -r '.monero.wallet_address // empty' "$CONFIG_FILE")
    TARI_WALLET=$(jq -r '.tari.wallet_address // empty' "$CONFIG_FILE")

    if [ -z "$MONERO_USER" ] || [ -z "$MONERO_PASS" ] || [ -z "$MONERO_WALLET" ] || [ -z "$TARI_WALLET" ]; then
        error "Missing required configuration in $CONFIG_FILE."
    fi

    # Resolve Directories
    MONERO_DIR=$(jq -r '.monero.data_dir // empty' "$CONFIG_FILE")
    [ -z "$MONERO_DIR" ] || [ "$MONERO_DIR" == "DYNAMIC_DATA" ] && MONERO_DIR="$PWD/data/monero"

    TARI_DIR=$(jq -r '.tari.data_dir // empty' "$CONFIG_FILE")
    [ -z "$TARI_DIR" ] || [ "$TARI_DIR" == "DYNAMIC_DATA" ] && TARI_DIR="$PWD/data/tari"

    P2POOL_DIR=$(jq -r '.p2pool.data_dir // empty' "$CONFIG_FILE")
    [ -z "$P2POOL_DIR" ] || [ "$P2POOL_DIR" == "DYNAMIC_DATA" ] && P2POOL_DIR="$PWD/data/p2pool"

    TOR_DATA_DIR=$(jq -r '.tor.data_dir // empty' "$CONFIG_FILE")
    [ -z "$TOR_DATA_DIR" ] || [ "$TOR_DATA_DIR" == "DYNAMIC_DATA" ] && TOR_DATA_DIR="$PWD/data/tor"

    DASHBOARD_DIR=$(jq -r '.dashboard.data_dir // empty' "$CONFIG_FILE")
    [ -z "$DASHBOARD_DIR" ] || [ "$DASHBOARD_DIR" == "DYNAMIC_DATA" ] && DASHBOARD_DIR="$PWD/data/dashboard"
}

prepare_directories() {
    log "Initializing data directories..."
    mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"

    # Enforce permissions
    sudo chown -R 100:101 "$TOR_DATA_DIR"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR"
    mkdir -p "$P2POOL_DIR/stats"
    sudo chmod -R 755 "$P2POOL_DIR/stats"
}

generate_preliminary_env() {
    PROXY_AUTH_TOKEN=$(openssl rand -hex 12)
    cat <<EOF > "$ENV_FILE"
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
}

provision_tor() {
    log "Initializing Tor service to generate Onion addresses..."
    docker compose up -d tor
    log "Waiting for Hidden Services to propagate (15s)..."
    sleep 15

    MONERO_ONION=$(docker exec tor cat /var/lib/tor/monero/hostname)
    TARI_ONION=$(docker exec tor cat /var/lib/tor/tari/hostname)
    P2POOL_ONION=$(docker exec tor cat /var/lib/tor/p2pool/hostname)
}

finalize_env() {
    log "Finalizing environment configuration (.env)..."

    # Pruning
    MONERO_PRUNE_BOOL=$(jq -r '.monero.prune // "true"' "$CONFIG_FILE")
    if [ "$MONERO_PRUNE_BOOL" == "true" ]; then
        MONERO_PRUNE=1
    else
        MONERO_PRUNE=0
    fi

    # P2Pool Config
    POOL_TYPE=$(jq -r '.p2pool.pool // "main"' "$CONFIG_FILE")
    P2POOL_FLAGS=""
    P2POOL_PORT="37889"
    if [ "$POOL_TYPE" == "mini" ]; then
        P2POOL_FLAGS="--mini"
        P2POOL_PORT="37888"
    elif [ "$POOL_TYPE" == "nano" ]; then
        P2POOL_FLAGS="--nano"
        P2POOL_PORT="37890"
    fi

    # XvB Config
    XVB_ENABLED=$(jq -r '.xvb.enabled // .xmrig_proxy.enabled // "true"' "$CONFIG_FILE")
    XVB_POOL_URL=$(jq -r '.xvb.url // .xmrig_proxy.url // empty' "$CONFIG_FILE")
    [ -z "$XVB_POOL_URL" ] && XVB_POOL_URL="na.xmrvsbeast.com:4247"

    XVB_DONOR_ID=$(jq -r '.xvb.donor_id // .xmrig_proxy.donor_id // empty' "$CONFIG_FILE")
    if [ -z "$XVB_DONOR_ID" ] || [ "$XVB_DONOR_ID" == "DYNAMIC_ID" ]; then
        log "Configuring Donor ID using first 8 characters of Monero wallet."
        XVB_DONOR_ID=$(echo "$MONERO_WALLET" | cut -c 1-8)
    fi

    cat <<EOF > "$ENV_FILE"
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
}

inject_service_configs() {
    log "Injecting service configurations..."
    cp build/tari/config.toml.template build/tari/config.toml
    TARI_ONION_SHORT=$(echo "$TARI_ONION" | cut -d'.' -f1)
    safe_sed "s/<your_tari_onion_address_no_extension>/$TARI_ONION_SHORT/g" build/tari/config.toml
}

optimize_kernel() {
    log "Applying RandomX optimizations (HugePages)..."
    if [ "$OS_TYPE" == "Linux" ]; then
        sudo sysctl -w vm.nr_hugepages=3072

        if [ -f "/etc/default/grub" ]; then
            if ! grep -q "hugepages=" /etc/default/grub; then
                log "Updating GRUB configuration for persistent HugePages..."
                sudo cp /etc/default/grub /etc/default/grub.bak
                sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never /' /etc/default/grub
                if command -v update-grub >/dev/null; then
                    sudo update-grub
                    REBOOT_REQUIRED=true
                else
                    warn "'update-grub' not found. Please manually update your bootloader."
                fi
            else
                log "HugePages already configured in GRUB."
            fi
        fi
    else
        log "Skipping Host HugePages configuration (Not supported on $OS_TYPE)."
    fi
}

finish_deployment() {
    echo "DEPLOYMENT_COMPLETED=true" >> "$ENV_FILE"
    log "Deployment preparation complete!"
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n\033[1;33m[!] ATTENTION: System optimization requires a reboot.\033[0m"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 -s'"
    else
        prompt_start_stack
    fi
}

# --- Main Execution ---

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            -s)  ask_yes_no "Start the stack?" stack_up ;;
            -sf) stack_up ;;
            -d)  ask_yes_no "Stop the stack?" stack_down ;;
            -df) stack_down ;;
            -r)  ask_yes_no "Restart the stack?" stack_restart ;;
            -rf) stack_restart ;;
            -l|--logs)
                log "Following logs (Ctrl+C to exit)..."
                docker compose logs -f
                ;;
            -st|--status)
                docker compose ps
                ;;
            -h|--help) show_help ;;
            *)
                error "Unknown option: $1. Use -h for help."
                ;;
        esac
        exit 0
    fi

    check_previous_deployment
    check_prerequisites
    ensure_config_exists
    parse_and_validate_config
    prepare_directories
    generate_preliminary_env
    provision_tor
    finalize_env
    inject_service_configs
    optimize_kernel
    finish_deployment
}

main "$@"