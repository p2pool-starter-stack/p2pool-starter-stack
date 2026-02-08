#!/usr/bin/env bash
#
# XMRig Worker Deployment Script
# Automates the provisioning of a high-performance Monero mining worker.
# Handles dependency installation, kernel tuning (HugePages/MSR), and service configuration.
#

set -Eeuo pipefail

# --- Logging Utilities ---
readonly C_RESET='\033[0m'
readonly C_GREEN='\033[1;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_RED='\033[1;31m'

log() { echo -e "${C_GREEN}[INFO]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1"; exit 1; }

# --- Global Variables ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_JSON="$SCRIPT_DIR/config.json"
TEMPLATE_JSON="$SCRIPT_DIR/config.json.template"
REBOOT_REQUIRED=false

# --- Helper Functions ---

check_prerequisites() {
    log "Verifying system prerequisites..."
    if ! command -v jq &> /dev/null; then
        log "Installing prerequisite: jq..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y -qq jq
        else
            error "jq is required and apt-get was not found. Please install jq manually."
        fi
    fi
}

ensure_config_exists() {
    if [ ! -f "$CONFIG_JSON" ]; then
        warn "Configuration file not found: $CONFIG_JSON"
        read -r -p "Create a minimal configuration now? (y/N): " CREATE_CONF
        if [[ "$CREATE_CONF" =~ ^[Yy] ]]; then
            log "Starting interactive setup..."
            
            # Load defaults from template if available
            local default_home="DYNAMIC_HOME"
            local default_donation=1
            local default_config_file="./worker-config/example-config.json.template"
            
            if [ -f "$TEMPLATE_JSON" ]; then
                default_home=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$TEMPLATE_JSON")
                default_donation=$(jq -r '.DONATION // 1' "$TEMPLATE_JSON")
                default_config_file=$(jq -r '.WORKER_CONFIG_FILE // "./worker-config/example-config.json.template"' "$TEMPLATE_JSON")
            fi

            read -r -p "Enter P2Pool Node Hostname/IP: " IN_HOSTNAME
            
            if [ -z "$IN_HOSTNAME" ]; then
                error "Hostname is required. Aborting."
            fi

            cat <<EOF > "$CONFIG_JSON"
{
    "HOME_DIR": "$default_home",
    "DONATION": $default_donation,
    "WORKER_CONFIG_FILE": "$default_config_file",
    "P2POOL_NODE_HOSTNAME": "$IN_HOSTNAME"
}
EOF
            log "Created $CONFIG_JSON successfully."
        else
            error "Configuration file required to proceed."
        fi
    fi
}

parse_config() {
    log "Parsing configuration..."
    if ! jq -e . "$CONFIG_JSON" >/dev/null 2>&1; then
        error "$CONFIG_JSON is not valid JSON."
    fi

    RAW_HOME=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON")
    if [ "$RAW_HOME" == "DYNAMIC_HOME" ]; then
        WORKER_ROOT="$SCRIPT_DIR/data/worker"
    else
        WORKER_ROOT="$RAW_HOME/worker"
    fi
    DONATION=$(jq -r .DONATION "$CONFIG_JSON")
    WORKER_CONFIG_FILE=$(jq -r .WORKER_CONFIG_FILE "$CONFIG_JSON")
    if [ "$WORKER_CONFIG_FILE" == "null" ] || [ -z "$WORKER_CONFIG_FILE" ]; then
        error "WORKER_CONFIG_FILE is not defined in $CONFIG_JSON."
    fi
    P2POOL_NODE_HOSTNAME=$(jq -r .P2POOL_NODE_HOSTNAME "$CONFIG_JSON")
    ACCESS_TOKEN=$(jq -r '.ACCESS_TOKEN // empty' "$CONFIG_JSON")
    if [ -z "$ACCESS_TOKEN" ]; then
        ACCESS_TOKEN=$(hostname)
    fi

    # Smart Address Handling: Only append .local if it looks like a short hostname (no dots)
    if [[ "$P2POOL_NODE_HOSTNAME" != *.* ]]; then
        P2POOL_NODE_ADDRESS="${P2POOL_NODE_HOSTNAME}.local"
    else
        P2POOL_NODE_ADDRESS="$P2POOL_NODE_HOSTNAME"
    fi

    # Resolve Template Path (Handle absolute vs relative paths)
    if [[ "$WORKER_CONFIG_FILE" = /* ]]; then
        TEMPLATE_CONFIG="$WORKER_CONFIG_FILE"
    else
        TEMPLATE_CONFIG="$SCRIPT_DIR/$WORKER_CONFIG_FILE"
    fi

    if [ ! -f "$TEMPLATE_CONFIG" ]; then
        error "XMRig configuration template not found at: $TEMPLATE_CONFIG\nPlease ensure 'WORKER_CONFIG_FILE' in $CONFIG_JSON points to a valid file."
    fi
}

prepare_workspace() {
    log "Preparing workspace at $WORKER_ROOT..."
    mkdir -p "$WORKER_ROOT"
    cd "$WORKER_ROOT"

    GIT_DIR="xmrig"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)

    # Archive existing installation if present
    if [ -d "$GIT_DIR" ]; then
        log "Archiving existing worker installation..."
        mv "$GIT_DIR" "${GIT_DIR}-${TIMESTAMP}"
    fi
}

install_dependencies() {
    local dependencies="git build-essential cmake libuv1-dev libssl-dev libhwloc-dev avahi-daemon gettext-base linux-tools-common linux-tools-$(uname -r)"

    log "The following system dependencies are required:"
    echo -e "  ${C_YELLOW}$dependencies${C_RESET}"

    read -r -p "Install these dependencies now? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy] ]]; then
        log "Installing dependencies..."
        sudo apt update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" $dependencies
    else
        warn "Dependency installation skipped. Proceeding at your own risk."
    fi

    # Enable Model Specific Registers (MSR) for hardware prefetcher tuning
    sudo modprobe msr
    echo "msr" | sudo tee -a /etc/modules > /dev/null || true
}

compile_xmrig() {
    log "Cloning and patching XMRig source code..."
    git clone --quiet https://github.com/xmrig/xmrig.git
    sed -i "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h

    log "Compiling binary (Concurrency: $(nproc) threads)..."
    mkdir -p xmrig/build && cd xmrig/build
    cmake .. -DWITH_HWLOC=ON &> /dev/null
    make -j$(nproc) &> /dev/null
}

generate_xmrig_config() {
    log "Generating hardware-optimized configuration using template: $(basename "$TEMPLATE_CONFIG")..."

    # Identify CPU Topology
    CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | xargs)
    LOG_FILE_PATH="$WORKER_ROOT/xmrig.log"

    # Default Optimization Profile
    YIELD="true"
    PRIORITY="null"
    ASM="auto"
    THREADS="-1"
    NUMA="false"
    PREFETCH=1
    WRMSR="true"
    DIFFICULTY="10000"
    JIT="false"
    INIT_AVX2="-1"

    # Profile: AMD EPYC (Server)
    if [[ "$CPU_MODEL" == *"EPYC"* ]]; then
        log "Hardware Detected: AMD EPYC. Applying NUMA binding and server optimizations."
        NUMA="true"
        YIELD="true"
        ASM="auto"
        THREADS="-1"
        DIFFICULTY="1350000"
        WRMSR="true"
    fi

    # Profile: AMD Ryzen X3D (Desktop)
    if [[ "$CPU_MODEL" == *"X3D"* ]]; then
        log "Hardware Detected: AMD Ryzen X3D. Applying 'Golden' prefetch and MSR tuning."
        YIELD="false"
        PRIORITY="4"
        ASM="ryzen"
        THREADS="[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]"
        PREFETCH=1 
        WRMSR="true"
        DIFFICULTY="324000"
        JIT="false"
        INIT_AVX2=1
    fi

    # Construct User ID (Hostname + Difficulty)
    FULL_USER="$(hostname)+${DIFFICULTY}"

    # Generate config.json via jq
    jq --arg url "$P2POOL_NODE_ADDRESS:3333" \
       --arg user "$FULL_USER" \
       --arg access_token "$ACCESS_TOKEN" \
       --arg log "$LOG_FILE_PATH" \
       --argjson yield "$YIELD" \
       --argjson prio "$PRIORITY" \
       --argjson numa "$NUMA" \
       --arg asm "$ASM" \
       --argjson rx "$THREADS" \
       --argjson prefetch "$PREFETCH" \
       --argjson jit "$JIT" \
       --argjson wrmsr "$WRMSR" \
       --argjson avx2 "$INIT_AVX2" \
       '.pools[0].url = $url | 
        .pools[0].user = $user | 
        .pools[0].enabled = true |
        .pools = [.pools[0]] |
        ."log-file" = $log | 
        .cpu.yield = $yield | 
        .cpu.priority = $prio | 
        .cpu.asm = $asm | 
        .cpu.rx = $rx |
        ."cpu"."huge-pages-jit" = $jit |
        .randomx.numa = $numa |
        .randomx."init-avx2" = $avx2 |
        .randomx.wrmsr = $wrmsr |
        .randomx.scratchpad_prefetch_mode = $prefetch |
        (if $access_token != "" then ."http"."access-token" = $access_token else . end) | 
        ."http"."restricted" = false' \
       "$TEMPLATE_CONFIG" > config.json

    log "Configuring log rotation policy..."
    # Install logrotate configuration
    sudo tee /etc/logrotate.d/xmrig > /dev/null <<EOF
$LOG_FILE_PATH {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
    minsize 50M
    create 0644 $(whoami) $(whoami)
}
EOF
}

install_service() {
    log "Installing systemd service..."
    export BUILD_DIR="$WORKER_ROOT/xmrig/build"
    export CPUPOWER_PATH=$(which cpupower || echo "/usr/bin/cpupower")

    # Overwrite the existing file
    envsubst '$BUILD_DIR $CPUPOWER_PATH' < "$SCRIPT_DIR/systemd/xmrig.service.template" | sudo tee /etc/systemd/system/xmrig.service > /dev/null

    # Reload systemd daemon
    sudo systemctl daemon-reload

    # Enable service to start on boot
    sudo systemctl enable xmrig.service

    # Restart service to apply new configuration
    log "Restarting XMRig service..."
    sudo systemctl restart xmrig.service
}

tune_kernel() {
    log "Calculating optimal HugePages configuration..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
        NEW_PARAMS=$("$SCRIPT_DIR/util/proposed-grub.sh" -q)
        sudo cp /etc/default/grub /etc/default/grub.bak
        sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_PARAMS\"|" /etc/default/grub
        if command -v update-grub >/dev/null; then
            sudo update-grub
            REBOOT_REQUIRED=true
        else
            warn "'update-grub' not found. Please manually update your bootloader."
        fi
    else
        warn "Utility 'proposed-grub.sh' not found. Skipping GRUB updates."
    fi
}

configure_limits() {
    log "Configuring persistent HugePage mounts and memory limits..."
    sudo mkdir -p /dev/hugepages1G

    # Configure fstab for HugePage mounts (Idempotent)
    FSTAB_LINES="hugetlbfs /dev/hugepages hugetlbfs defaults 0 0
hugetlbfs_1g /dev/hugepages1G hugetlbfs pagesize=1G 0 0"

    echo "$FSTAB_LINES" | while read -r line; do
        grep -qF "$line" /etc/fstab || echo "$line" | sudo tee -a /etc/fstab > /dev/null
    done

    sudo mount -a || warn "Mount operation returned errors. Check 'dmesg' for details."

    # Configure security limits for memlock (Idempotent)
    LIMITS="* soft memlock unlimited
* hard memlock unlimited"

    echo "$LIMITS" | while read -r line; do
        grep -qF "$line" /etc/security/limits.conf || echo "$line" | sudo tee -a /etc/security/limits.conf > /dev/null
    done
}

finish_deployment() {
    echo ""
    log "--------------------------------------------------------"
    log "Deployment Complete."
    if [ "$REBOOT_REQUIRED" = true ]; then
        warn "ACTION REQUIRED: A system reboot is mandatory to enable HugePages."
        echo "Please run: 'sudo reboot' now."
    else
        log "Worker configured successfully. No reboot required."
    fi
    log "--------------------------------------------------------"
}

# --- Main Execution ---

main() {
    check_prerequisites
    ensure_config_exists
    parse_config
    prepare_workspace
    install_dependencies
    compile_xmrig
    generate_xmrig_config
    install_service
    tune_kernel
    configure_limits
    finish_deployment
}

main "$@"