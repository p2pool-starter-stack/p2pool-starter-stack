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
OS_TYPE="$(uname -s)"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REAL_USER="${SUDO_USER:-$USER}"
CONFIG_JSON="$SCRIPT_DIR/config.json"
TEMPLATE_JSON="$SCRIPT_DIR/config.json.template"
REBOOT_REQUIRED=false
SERVICE_INSTALLED=false

# --- Helper Functions ---

check_prerequisites() {
    log "Verifying system prerequisites..."
    if ! command -v jq &> /dev/null; then
        if [ "$OS_TYPE" == "Darwin" ]; then
            if command -v brew &> /dev/null; then
                log "Installing prerequisite: jq..."
                brew install jq
            else
                error "Homebrew is required on macOS to install dependencies."
            fi
        else
            log "Installing prerequisite: jq..."
            if command -v apt-get &> /dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq jq
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y -q jq
            elif command -v pacman &> /dev/null; then
                sudo pacman -Sy --noconfirm jq
            else
                error "jq is required and no supported package manager was found. Please install jq manually."
            fi
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
    
    if [ ! -d "$WORKER_ROOT" ]; then
        mkdir -p "$WORKER_ROOT" 2>/dev/null || sudo mkdir -p "$WORKER_ROOT"
    fi

    # Fix permissions to ensure the current user can write
    if [ "${EUID:-$(id -u)}" -eq 0 ] || [ ! -w "$WORKER_ROOT" ]; then
        if [ "$OS_TYPE" == "Darwin" ]; then
            sudo chown -R "$REAL_USER" "$WORKER_ROOT"
        else
            sudo chown -R "$REAL_USER":"$REAL_USER" "$WORKER_ROOT"
        fi
    fi

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
    if [ "$OS_TYPE" == "Darwin" ]; then
        log "Installing macOS dependencies..."
        if command -v brew &> /dev/null; then
            if [ "${EUID:-$(id -u)}" -eq 0 ]; then
                # Drop privileges for Homebrew if running as root
                sudo -u "$REAL_USER" brew install cmake libuv openssl hwloc
            else
                brew install cmake libuv openssl hwloc
            fi
        else
            error "Homebrew not found."
        fi
    else
        local dependencies=""
        local install_cmd=""
        local check_cmd=""

        if command -v apt-get &> /dev/null; then
            dependencies="git build-essential cmake libuv1-dev libssl-dev libhwloc-dev avahi-daemon gettext-base"
            if [ "$OS_TYPE" == "Linux" ]; then
                dependencies="$dependencies linux-tools-common"
                if apt-cache show "linux-tools-$(uname -r)" &> /dev/null; then
                    dependencies="$dependencies linux-tools-$(uname -r)"
                fi
            fi
            install_cmd="sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'"
            check_cmd="dpkg -s"
        elif command -v dnf &> /dev/null; then
            dependencies="git cmake libuv-devel openssl-devel hwloc-devel avahi gettext gcc gcc-c++ make automake kernel-devel"
            install_cmd="sudo dnf install -y"
            check_cmd="rpm -q"
        elif command -v pacman &> /dev/null; then
            dependencies="git cmake libuv openssl hwloc avahi gettext base-devel"
            install_cmd="sudo pacman -Sy --noconfirm --needed"
            check_cmd="pacman -Qi"
        else
            warn "No supported package manager found. Please install dependencies manually."
            return
        fi

        local missing_deps=""
        for dep in $dependencies; do
            if ! command -v "$dep" &> /dev/null && ! $check_cmd "$dep" &> /dev/null; then
                missing_deps="$missing_deps $dep"
            fi
        done

        if [ -n "$missing_deps" ]; then
            log "The following system dependencies are required:"
            echo -e "  ${C_YELLOW}$missing_deps${C_RESET}"

            read -r -p "Install these dependencies now? (y/N): " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                log "Installing dependencies..."
                eval "$install_cmd $missing_deps"
            else
                warn "Dependency installation skipped. Proceeding at your own risk."
            fi
        else
            log "All system dependencies are already installed."
        fi
    fi
}

compile_xmrig() {
    log "Cloning and patching XMRig source code..."
    git clone --quiet https://github.com/xmrig/xmrig.git
    
    if [ "$OS_TYPE" == "Darwin" ]; then
        sed -i '' "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h
        CORES=$(sysctl -n hw.ncpu)
        log "Compiling binary (Concurrency: $CORES threads)..."
        mkdir -p xmrig/build && cd xmrig/build
        # macOS often needs explicit OpenSSL root for cmake if installed via brew
        cmake .. -DWITH_HWLOC=ON -DOPENSSL_ROOT_DIR=$(brew --prefix openssl) &> /dev/null
    else
        sed -i "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h
        CORES=$(nproc)
        log "Compiling binary (Concurrency: $CORES threads)..."
        mkdir -p xmrig/build && cd xmrig/build
        cmake .. -DWITH_HWLOC=ON &> /dev/null
    fi

    make -j$CORES &> /dev/null
}

generate_xmrig_config() {
    log "Generating hardware-optimized configuration using template: $(basename "$TEMPLATE_CONFIG")..."

    # Identify CPU Topology
    if [ "$OS_TYPE" == "Darwin" ]; then
        CPU_MODEL=$(sysctl -n machdep.cpu.brand_string)
    else
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d':' -f2 | xargs)
    fi
    LOG_FILE_PATH="$WORKER_ROOT/xmrig.log"

    # Default Optimization Profile
    YIELD="true"
    PRIORITY="null"
    ASM="\"auto\""
    THREADS="-1"
    NUMA="false"
    PREFETCH=1
    WRMSR="true"
    RDMSR="true"
    HUGE_PAGES="true"
    MEMORY_POOL="true"
    ONE_GB_PAGES="true"
    JIT="true"
    INIT_AVX2="-1"
    HTTP_RESTRICTED="false"
    HTTP_HOST="0.0.0.0"

    # macOS Specific Overrides
    if [ "$OS_TYPE" == "Darwin" ]; then
        YIELD="false"
        PRIORITY="5"
        ASM="true"
        WRMSR="false"
        RDMSR="false"
        HUGE_PAGES="false"
        MEMORY_POOL="false"
        ONE_GB_PAGES="false"
        NUMA="true"
        HTTP_RESTRICTED="true"
        HTTP_HOST="::"
        JIT="false"
        
        # Generate rx array [-1, -1, ...] based on core count
        CORES=$(sysctl -n hw.ncpu)
        THREADS="["
        for ((i=0; i<CORES; i++)); do
            THREADS="${THREADS}-1"
            if [ $i -lt $((CORES-1)) ]; then THREADS="${THREADS},"; fi
        done
        THREADS="${THREADS}]"
    fi

    # Profile: AMD EPYC (Server)
    if [[ "$CPU_MODEL" == *"EPYC"* ]]; then
        log "Hardware Detected: AMD EPYC. Applying NUMA binding and server optimizations."
        NUMA="true"
        YIELD="true"
        ASM="\"auto\""
        THREADS="-1"
        WRMSR="true"
        JIT="true"
    fi

    # Profile: AMD Ryzen X3D (Desktop)
    if [[ "$CPU_MODEL" == *"X3D"* ]]; then
        log "Hardware Detected: AMD Ryzen X3D. Applying 'Golden' prefetch and MSR tuning."
        YIELD="false"
        PRIORITY="4"
        ASM="\"ryzen\""

        CORES=$(nproc)
        THREADS="["
        for ((i=0; i<CORES; i++)); do
            THREADS="${THREADS}$i"
            if [ $i -lt $((CORES-1)) ]; then THREADS="${THREADS}, "; fi
        done
        THREADS="${THREADS}]"

        PREFETCH=1 
        WRMSR="true"
        JIT="true"
        INIT_AVX2=1
    fi

    # Construct User ID (Hostname)
    FULL_USER="$(hostname)"

    # Generate config.json via jq
    jq --arg url "$P2POOL_NODE_ADDRESS:3333" \
       --arg user "$FULL_USER" \
       --arg access_token "$ACCESS_TOKEN" \
       --arg log "$LOG_FILE_PATH" \
       --argjson yield "$YIELD" \
       --argjson prio "$PRIORITY" \
       --argjson numa "$NUMA" \
       --argjson asm "$ASM" \
       --argjson rx "$THREADS" \
       --argjson prefetch "$PREFETCH" \
       --argjson jit "$JIT" \
       --argjson wrmsr "$WRMSR" \
       --argjson rdmsr "$RDMSR" \
       --argjson huge_pages "$HUGE_PAGES" \
       --argjson memory_pool "$MEMORY_POOL" \
       --argjson one_gb_pages "$ONE_GB_PAGES" \
       --argjson avx2 "$INIT_AVX2" \
       --argjson restricted "$HTTP_RESTRICTED" \
       --argjson donation "$DONATION" \
       --arg host "$HTTP_HOST" \
       '.pools[0].url = $url | 
        .pools[0].user = $user | 
        .pools[0].enabled = true |
        .pools = [.pools[0]] |
        ."log-file" = $log | 
        .cpu.yield = $yield | 
        .cpu.priority = $prio | 
        .cpu.asm = $asm | 
        .cpu.rx = $rx |
        ."cpu"."huge-pages" = $huge_pages |
        ."cpu"."huge-pages-jit" = $jit |
        ."cpu"."memory-pool" = $memory_pool |
        ."cpu"."msr" = $wrmsr |
        ."donate-level" = $donation |
        ."donate-over-proxy" = $donation |
        .randomx.numa = $numa |
        .randomx."init-avx2" = $avx2 |
        .randomx.wrmsr = $wrmsr |
        .randomx.rdmsr = $rdmsr |
        .randomx."1gb-pages" = $one_gb_pages |
        .randomx.scratchpad_prefetch_mode = $prefetch |
        (if $access_token != "" then ."http"."access-token" = $access_token else . end) | 
        ."http"."restricted" = $restricted |
        ."http"."host" = $host' \
       "$TEMPLATE_CONFIG" > config.json

    if [ "$OS_TYPE" == "Linux" ]; then
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
    fi
}

install_service() {
    if [ "$OS_TYPE" == "Linux" ]; then
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
        SERVICE_INSTALLED=true
    else
        warn "Service installation is not supported on $OS_TYPE."
    fi
}

tune_kernel() {
    if [ "$OS_TYPE" != "Linux" ]; then
        log "Skipping kernel tuning (Not supported on $OS_TYPE)."
        return
    fi

    if [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "i686" ]]; then
        log "Enabling MSR module for hardware prefetcher tuning..."
        sudo modprobe msr 2>/dev/null || true
        if [ -d "/etc/modules-load.d" ]; then
            echo "msr" | sudo tee /etc/modules-load.d/msr.conf > /dev/null
        elif [ -f "/etc/modules" ]; then
            grep -qFx "msr" /etc/modules || echo "msr" | sudo tee -a /etc/modules > /dev/null
        fi
    fi

    log "Applying runtime memory tuning..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
        # Calculate exact requirement based on hardware and current 1GB page status
        REQUIRED_PAGES=$("$SCRIPT_DIR/util/proposed-grub.sh" --runtime)
        log "Hardware-optimized HugePages: $REQUIRED_PAGES (2MB pages) calculated."
        sudo sysctl -w vm.nr_hugepages="$REQUIRED_PAGES"
    else
        warn "Utility script not found. Fallback to safe default (3072)."
        sudo sysctl -w vm.nr_hugepages=3072
    fi

    log "Configuring bootloader (GRUB) for persistent HugePages..."
    if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ] && [ -f "/etc/default/grub" ]; then
        NEW_PARAMS=$("$SCRIPT_DIR/util/proposed-grub.sh" -q)
        
        # Check if GRUB is already configured
        if grep -Fq "GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_PARAMS\"" /etc/default/grub; then
            log "GRUB is already configured with optimal HugePages settings."
        else
            sudo cp /etc/default/grub /etc/default/grub.bak
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_PARAMS\"|" /etc/default/grub
            if command -v update-grub >/dev/null; then
                sudo update-grub
                REBOOT_REQUIRED=true
            else
                warn "'update-grub' not found. Please manually update your bootloader."
            fi
        fi
    else
        warn "Skipping GRUB updates (Utility not found or non-GRUB system)."
    fi
}

configure_limits() {
    if [ "$OS_TYPE" != "Linux" ]; then
        return
    fi

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
    echo ""
    if [ "$SERVICE_INSTALLED" = true ]; then
        log "Service created. xmrig running in background."
    else
        log "You can run the miner manually:"
        echo "sudo screen -S xmrig $WORKER_ROOT/xmrig/build/xmrig --config=$WORKER_ROOT/config.json"
    fi
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
    tune_kernel
    configure_limits
    install_service
    finish_deployment
}

main "$@"