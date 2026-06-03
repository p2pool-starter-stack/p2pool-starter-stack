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

## 🛠 Hardware Requirements

A worker is where the actual RandomX hashing happens, so its **CPU is what determines your
hashrate**. The requirements themselves are modest — most of the performance comes from tuning,
which this script applies for you.

| Resource | Requirement | Recommended |
|---|---|---|
| **CPU** | 64-bit x86 with **AVX2** support | A high-core-count CPU (e.g. AMD Ryzen / EPYC) — more and faster cores mean more hashrate. The script auto-detects the CPU and applies a matching profile. |
| **RAM** | **~2.3 GB free** for RandomX *fast mode* — a 2080 MB dataset + 256 MB cache — plus **~2 MB of L3 cache per mining thread** | **4 GB+**; budget more on high-core-count CPUs |
| **HugePages** | Optional, but a significant speedup | The script configures **2 MB and 1 GB** HugePages (plus MSR access) for you — Linux only, and it needs a **reboot** to take effect |
| **OS** | Ubuntu 22.04+, Debian 12, or macOS | — |
| **Network** | Reach your stack host on port **3333** | Local network; workers do **not** need Tor |

> RandomX *light mode* needs only 256 MB of RAM but is far slower — **fast mode** (the default) is
> what you want for real hashrate. These memory figures are from XMRig's own
> [RandomX optimization guide](https://xmrig.com/docs/miner/randomx-optimization-guide).

The stack host these workers connect to is sized separately — see
[docs/hardware.md](../docs/hardware.md).

## 🔌 Connecting to the Stack

A worker connects to your **P2Pool Starter Stack** through a **single endpoint** — the stack's
`xmrig-proxy` on port **3333**. The stack handles pool selection, payouts, and the P2Pool/XvB split
centrally, so the worker config stays minimal, and you **never put a wallet address in it**.

To connect any [XMRig](https://github.com/xmrig/xmrig) instance by hand, this is the whole config:

```json
{
    "pools": [
        {
            "url": "YOUR_STACK_IP:3333",
            "user": "my-rig-01"
        }
    ]
}
```

*   The `user` field is just a label for the rig — use its hostname so you can tell workers apart on the dashboard.
*   Port **3333** must be reachable from the worker to the stack host; if the host has a firewall, allow inbound `3333` on the LAN.
*   Workers talk to the stack over plain stratum on your local network — they do **not** need Tor.

The provisioning kit below automates this connection (and all the performance tuning) for you. The
manual config above is the fallback if you'd rather run XMRig yourself.

## 🚀 Deployment Guide

### 1. Clone the Repository
On the machine you want to provision as a worker:
```bash
git clone https://github.com/p2pool-starter-stack/p2pool-starter-stack.git
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