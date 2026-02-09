# High-Performance XMRig Worker Provisioning Kit

This script automates the deployment of a high-performance [XMRig](https://github.com/xmrig/xmrig) worker on Ubuntu/Debian and macOS. It's designed to be a satellite miner for the **P2Pool Starter Stack**, handling everything from dependency installation and source code compilation to kernel-level tuning for maximum hashrate.

## ✨ Capabilities

*   **Automated Setup:** Installs all necessary dependencies (`cmake`, `libuv`, etc.) and compiles XMRig from the latest source.
*   **Hardware-Aware Optimization:** Automatically detects CPU architecture (e.g., AMD EPYC, Ryzen X3D) and applies specific, performance-enhancing tuning profiles.
*   **Kernel & System Tuning (Linux):**
    *   Configures GRUB and system limits for HugePages (1GB and 2MB) to minimize memory latency.
    *   Enables Model-Specific Register (MSR) access for direct hardware control.
    *   Disables CPU hardware prefetchers on AMD Zen architectures where beneficial.
*   **Service Management (Linux):** Deploys XMRig as a systemd service for reliable, unattended operation, complete with `cpupower` performance governor settings and automatic log rotation.
*   **Interactive Configuration:** If no config file is found, an interactive prompt will guide you through the minimal setup required.

## 🛠 Prerequisites

*   **OS:** Ubuntu 22.04+, Debian 12, or macOS.
*   **Hardware:** A CPU with AVX2 support is strongly recommended.
*   **Network:** The worker machine must be able to reach your main **P2Pool Starter Stack** server over the network.

## 🚀 Deployment Guide

### 1. Clone the Repository
On the machine you want to provision as a worker:
```bash
git clone https://github.com/VijitSingh97/p2pool-starter-stack.git
cd p2pool-starter-stack/worker
```

### 2. Configuration
The script uses a `config.json` file for setup. You have two options:

**A) Interactive Setup (Recommended for first-timers):**
Simply run the script. It will detect that `config.json` is missing and launch an interactive prompt to create one for you. You will only need to provide the hostname or IP address of your main P2Pool Starter Stack.

**B) Manual Configuration:**
You can create a `config.json` file manually. A template is provided in `config.json.template`.
```json
{
    "HOME_DIR": "DYNAMIC_HOME",
    "DONATION": 1,
    "WORKER_CONFIG_FILE": "./worker-config/example-config.json.template",
    "P2POOL_NODE_HOSTNAME": "YOUR_MAIN_STACK_IP_OR_HOSTNAME"
}
```
*   `P2POOL_NODE_HOSTNAME`: The only mandatory field you need to change.
*   `HOME_DIR`: Where the worker files will be stored. `DYNAMIC_HOME` defaults to a `data/` directory inside the `worker` folder.
*   `WORKER_CONFIG_FILE`: The template to use for generating the final `xmrig` config. The default is suitable for most use cases.

### 3. Execute the Script
The script requires root privileges to install software and tune the system.
```bash
chmod +x p2pool-starter-worker.sh
sudo ./p2pool-starter-worker.sh
```
The script will now perform all setup steps automatically.

### 4. Reboot (Linux Only)
To apply critical kernel optimizations like HugePages, a system reboot is **mandatory** on Linux. The script will notify you when it's time to do so.
```bash
sudo reboot
```
On macOS, a reboot is not required.

After the reboot, the `xmrig` service will start automatically on Linux.

## 🛠️ Maintenance & Logging (Linux)

*   **Service Control:**
    ```bash
    # Check status
    sudo systemctl status xmrig
    # Stop the miner
    sudo systemctl stop xmrig
    # Start the miner
    sudo systemctl start xmrig
    # View live logs
    sudo journalctl -u xmrig -f
    ```
*   **Log Location:** The primary log file is located at `<WORKER_ROOT>/xmrig.log` (e.g., `data/worker/xmrig.log`).
*   **Log Rotation:** The script automatically installs a `logrotate` policy to compress and archive logs daily, preventing your disk from filling up.

## 🔍 Verification (Linux)
After rebooting, you can verify that the optimizations were applied correctly.

**1. HugePages:**
```bash
grep Huge /proc/meminfo
```
Look for `HugePages_Total`, `HugePages_Free`, and `Hugepagesize`. The values should be non-zero and match what the script configured.

**2. MSR (Model-Specific Registers):**
Check the `xmrig` log for messages indicating MSR has been initialized.
```bash
cat <WORKER_ROOT>/xmrig.log | grep "msr"
```
If you see errors related to MSR, you may need to **disable Secure Boot** in your system's BIOS/UEFI.

## 📝 License
This project is provided "as-is" under the MIT License.