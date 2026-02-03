#!/bin/bash
#
# XMRig Worker Deployment Script
# Automates the provisioning of a high-performance Monero mining worker.
# Handles dependency installation, kernel tuning (HugePages/MSR), and service configuration.
#

# Terminate execution immediately upon any command failure
set -e

# --- Logging Utilities ---
log_info() { echo -e "\033[1;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

# --- 1. Environment Initialization ---
SCRIPT_DIR=$(dirname "$(realpath "$0")")
CONFIG_JSON="$SCRIPT_DIR/config.json"

if [ ! -f "$CONFIG_JSON" ]; then
    log_error "Configuration file not found: $CONFIG_JSON"
fi

# Ensure 'jq' is available for configuration parsing
if ! command -v jq &> /dev/null; then
    log_info "Installing prerequisite: jq..."
    sudo apt-get update -qq && sudo apt-get install -y -qq jq
fi

# Parse Configuration
RAW_HOME=$(jq -r '.HOME_DIR // "DYNAMIC_HOME"' "$CONFIG_JSON")
if [ "$RAW_HOME" == "DYNAMIC_HOME" ]; then
    HOME_DIR=$HOME
else
    HOME_DIR=$RAW_HOME
fi
DONATION=$(jq -r .DONATION "$CONFIG_JSON")
WORKER_CONFIG_FILE=$(jq -r .WORKER_CONFIG_FILE "$CONFIG_JSON")
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
TEMPLATE_CONFIG="$SCRIPT_DIR/$WORKER_CONFIG_FILE"

# --- 2. Workspace Preparation ---
WORKER_ROOT="$HOME_DIR/worker"
mkdir -p "$WORKER_ROOT"
cd "$WORKER_ROOT"

GIT_DIR="xmrig"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Archive existing installation if present
if [ -d "$GIT_DIR" ]; then
    log_info "Archiving existing worker installation..."
    mv "$GIT_DIR" "${GIT_DIR}-${TIMESTAMP}"
fi

# --- 3. System Dependencies ---
log_info "Installing system dependencies (Build tools, HWLOC, SSL)..."
sudo apt update -qq
sudo DEBIAN_FRONTEND=noninteractive apt install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" git build-essential cmake libuv1-dev libssl-dev libhwloc-dev avahi-daemon gettext-base linux-tools-common linux-tools-$(uname -r)

# Enable Model Specific Registers (MSR) for hardware prefetcher tuning
sudo modprobe msr
echo "msr" | sudo tee -a /etc/modules > /dev/null || true

# --- 4. XMRig Compilation ---
log_info "Cloning and patching XMRig source code..."
git clone --quiet https://github.com/xmrig/xmrig.git
sed -i "s/DonateLevel = 1;/DonateLevel = $DONATION;/g" xmrig/src/donate.h

log_info "Compiling binary (Concurrency: $(nproc) threads)..."
mkdir -p xmrig/build && cd xmrig/build
cmake .. -DWITH_HWLOC=ON &> /dev/null
make -j$(nproc) &> /dev/null

# --- 5. Configuration Generation ---
log_info "Generating hardware-optimized configuration..."

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

# Profile: AMD EPYC (Server)
if [[ "$CPU_MODEL" == *"EPYC"* ]]; then
    log_info "Hardware Detected: AMD EPYC. Applying NUMA binding and server optimizations."
    NUMA="true"
    YIELD="true"
    ASM="auto"
    THREADS="-1"
    DIFFICULTY="1350000"
    WRMSR="true"
fi

# Profile: AMD Ryzen X3D (Desktop)
if [[ "$CPU_MODEL" == *"X3D"* ]]; then
    log_info "Hardware Detected: AMD Ryzen X3D. Applying 'Golden' prefetch and MSR tuning."
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

# Set defaults for optional fields if unset
: "${JIT:=false}"
: "${INIT_AVX2:=-1}"

# Construct User ID (Hostname + Difficulty)
FULL_USER="$(hostname)+${DIFFICULTY}"

# Generate config.json via jq
jq --arg url "$P2POOL_NODE_ADDRESS:3333" \
   --arg proxy_url "$P2POOL_NODE_ADDRESS:3344" \
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
    .pools[1] = .pools[0] |
    .pools[1].url = $proxy_url |
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

log_info "Configuring log rotation policy..."
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

# --- 6. Service Installation (Systemd) ---
log_info "Installing systemd service..."
export BUILD_DIR="$WORKER_ROOT/xmrig/build"
export CPUPOWER_PATH=$(which cpupower || echo "/usr/bin/cpupower")

# Overwrite the existing file
envsubst '$BUILD_DIR $CPUPOWER_PATH' < "$SCRIPT_DIR/systemd/xmrig.service.template" | sudo tee /etc/systemd/system/xmrig.service > /dev/null

# Reload systemd daemon
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable xmrig.service

# Restart service to apply new configuration
log_info "Restarting XMRig service..."
sudo systemctl restart xmrig.service

# --- 7. Kernel Tuning (GRUB) ---
log_info "Calculating optimal HugePages configuration..."
if [ -f "$SCRIPT_DIR/util/proposed-grub.sh" ]; then
    NEW_PARAMS=$("$SCRIPT_DIR/util/proposed-grub.sh" -q)
    sudo cp /etc/default/grub /etc/default/grub.bak
    sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_PARAMS\"|" /etc/default/grub
    sudo update-grub
else
    log_warn "Utility 'proposed-grub.sh' not found. Skipping GRUB updates."
fi

# --- 8. Resource Limits & Mounts ---
log_info "Configuring persistent HugePage mounts and memory limits..."
sudo mkdir -p /dev/hugepages1G

# Configure fstab for HugePage mounts (Idempotent)
FSTAB_LINES="hugetlbfs /dev/hugepages hugetlbfs defaults 0 0
hugetlbfs_1g /dev/hugepages1G hugetlbfs pagesize=1G 0 0"

echo "$FSTAB_LINES" | while read -r line; do
    grep -qF "$line" /etc/fstab || echo "$line" | sudo tee -a /etc/fstab > /dev/null
done

sudo mount -a || log_warn "Mount operation returned errors. Check 'dmesg' for details."

# Configure security limits for memlock (Idempotent)
LIMITS="* soft memlock unlimited
* hard memlock unlimited"

echo "$LIMITS" | while read -r line; do
    grep -qF "$line" /etc/security/limits.conf || echo "$line" | sudo tee -a /etc/security/limits.conf > /dev/null
done

echo ""
log_info "--------------------------------------------------------"
log_info "Deployment Complete."
log_info "ACTION REQUIRED: A system reboot is mandatory to enable HugePages."
log_info "--------------------------------------------------------"