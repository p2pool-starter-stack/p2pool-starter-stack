# High-Performance Worker Provisioning Kit

A professional-grade deployment engine for [XMRig](https://github.com/xmrig/xmrig) on [Ubuntu](https://ubuntu.com/)/[Debian](https://www.debian.org/). Designed to integrate seamlessly with the **P2Pool Starter Stack**, this tool automates the provisioning of dedicated mining hardware, ensuring maximum hashrate efficiency via kernel-level tuning.

## 🧠 Algorithmic Integration & Port Logic

This worker is engineered to function as a satellite node for the main stack's **Smart Yield Optimization** engine.

### Dual-Pool Configuration
The deployment script automatically configures XMRig with two upstream destinations:
1.  **P2Pool Stratum (Port 3333):** The default mining destination for [Monero](https://www.getmonero.org/) and [Tari](https://www.tari.com/) merge mining.
2.  **XMRig Proxy (Port 3344):** A consolidated gateway for [XMRvsBeast](https://xmrvsbeast.com/) bonus rounds.

### Automated Switching
The **Dashboard** on your main stack monitors your aggregate hashrate. When your hashrate qualifies for a higher yield tier (e.g., Whale Tier), the algorithm sends a command to this worker's local API (Port `8080`) to seamlessly toggle traffic from P2Pool to the Proxy, maximizing profitability without manual intervention.

## ✨ Capabilities

*   **Hardware-Aware Optimization:** Automatically detects CPU topology (EPYC vs. Ryzen X3D) and applies specific tuning profiles.
*   **L3 Cache Calculation:** Dynamically calculates optimal thread counts based on the RandomX 2MB L3 cache requirement.
*   **Kernel Tuning:** Configures **GRUB** with 1GB and 2MB HugePages based on physical socket count to minimize TLB misses.
*   **MSR Registers:** Applies Model Specific Register tweaks (e.g., disabling hardware prefetchers) for Zen architectures.
*   **Service Management:** Deploys XMRig as a systemd service with `cpupower` performance governance and log rotation.

## 🛠 Prerequisites

*   **OS:** Ubuntu 22.04+ or Debian 12.
*   **Network:** Connectivity to your P2Pool Starter Stack on ports **3333** (P2Pool) and **3344** (Proxy).
*   **Hardware:** CPU with AVX2 support.

## 🚀 Deployment Guide

### 1. Clone & Initialize
On the worker machine:

```bash
git clone https://github.com/VijitSingh97/p2pool-starter-stack.git
cd p2pool-starter-stack/worker
```

### 2. Configuration
Edit **configuration.json** to connect to your main stack.
*   **P2POOL_NODE_HOSTNAME:** Enter the IP address or Hostname of your P2Pool Starter Stack.
*   **P2POOL_NODE_PORT:** Default is `3333` (P2Pool Stratum).
*   **P2POOL_PROXY_PORT:** Default is `3344` (XMRig Proxy).

### 3. Execution
Run the deployment script. This will install dependencies, compile XMRig from source, and apply system configurations.

```bash
chmod +x deploy.sh util/proposed-grub.sh
sudo ./deploy.sh
```

### 4. Reboot
A system reboot is **mandatory** to apply kernel parameters (HugePages) and load MSR modules.

```bash
sudo reboot
```

## 🛠️ Maintenance & Logging

*   **Logs:** Located at `~/worker/xmrig.log`.
*   **Auto-Cleanup:** The script installs a `logrotate` policy in `/etc/logrotate.d/xmrig`.
*   **Retention:** Keeps 7 days of compressed logs and triggers rotation once the file exceeds 50MB, preventing disk exhaustion.

## 📊 Optimization Logic

The script performs a deep analysis of `lscpu` output to satisfy RandomX requirements:

1.  **HugePages Strategy:**
    *   **1GB Pages:** Reserves 3GB per NUMA node (Socket) to hold the RandomX dataset (~2080MB) in contiguous memory.
    *   **2MB Pages:** Allocates sufficient pages for the JIT compiler and thread scratchpads.
2.  **Architecture Profiles:**
    *   **AMD EPYC:** Enables NUMA binding and server-grade optimizations.
    *   **Ryzen X3D:** Applies "Golden" prefetch settings and specific thread affinity.

## 🔍 Verification

After rebooting, verify the optimizations:

**1. HugePages:**
```bash
grep Huge /proc/meminfo
```
*Target: `HugePages_Total` should match the calculated value from the deploy script output.*

**2. MSR Status:**
Check the logs to confirm MSR registers were set successfully.
```bash
tail -f ~/worker/xmrig.log
```
*Note: If MSR writes fail, ensure **Secure Boot** is disabled in your BIOS.*

## 📝 License

MIT