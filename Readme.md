# Monero + Tari Merge Mining Stack (P2Pool)

![Dashboard](./images/dashboard.png)

A professional-grade, containerized mining stack for running a private Monero full node, P2Pool, and Tari merge mining. This stack is optimized for security, privacy (via Tor), and ease of monitoring.

## 🌟 Features
* **Security First:** Binaries verified via SHA256. Services run as non-root users where possible.
* **Privacy:** Integrated Tor daemon to anonymize P2P traffic.
* **Merge Mining:** Mine Tari alongside Monero automatically via P2Pool.
* **Real-time Dashboard:** Custom Python UI to track hashrate, worker health, and sync status.
* **Hardware Optimization:** Compatible with specialized kernel-tuning worker scripts.

## 🏗️ Architecture
The stack consists of five primary services:
1.  **Monerod:** The Monero daemon (verified binary).
2.  **P2Pool:** Decentralized mining pool (verified binary).
3.  **Tari Node:** Minotari base node for merge mining.
4.  **Tor:** Provides hidden services for P2P connectivity.
5.  **Dashboard:** A Python/Aiohttp interface for monitoring.



## 🚀 Getting Started

### 1. Prerequisites
* Ubuntu 24.04 (recommended)
* Docker & Docker Compose V2
* `jq` installed (`sudo apt install jq`)

### 2. Deployment
1.  **Configure:** Edit `config.json` with your wallet addresses and desired node credentials.
2.  **Deploy:** Run the automated setup. This creates data directories, sets up Tor, and configures the kernel.
    ```bash
    chmod +x deploy.sh
    ./deploy.sh
    ```
3.  **Reboot:** HugePages are allocated at the kernel level. For maximum performance, you **must** reboot:
    ```bash
    sudo reboot
    ```
3.  **Launch:**
    ```bash
    docker compose up -d
    ```

## ⛏️ Adding Workers (Hardware Provisioning)
To connect hardware miners (CPUs) to this stack with maximum efficiency, use the **Worker Starter** repository. It handles kernel tuning, HugePages allocation, and MSR registers for Ryzen CPUs.

**Repo:** [p2pool-worker-starter](https://github.com/VijitSingh97/p2pool-worker-starter)

**Quick Setup for Workers:**
```bash
git clone [https://github.com/VijitSingh97/p2pool-worker-starter](https://github.com/VijitSingh97/p2pool-worker-starter)
cd p2pool-worker-starter
# Edit configuration.json to point to your Stack's IP/Hostname
sudo ./deploy.sh
sudo reboot
```

## 📈 Monitoring
-------------

Access the dashboard at:

*   **Local:** http://localhost:8000
    
*   **Network:** http://\<your-server-ip\>:8000 (or \<hostname\>.local:8000)
    

## 🛠️ Maintenance
---------------

**Check Logs:**

    ```bash
    docker compose logs -f monerod  # Monitor blockchain sync  docker compose logs -f p2pool   # Monitor pool shares
    ```

**Update Stack:** Modify the ARG versions in the Dockerfiles and rebuild:

    ```bash
    docker compose build --no-cache && docker compose up -d
    ```

📄 License
----------

This project is provided "as-is" under the MIT License.