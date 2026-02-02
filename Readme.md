# Monero & Tari Merge Mining Stack (Privacy-Focused)

![Dashboard](./images/dashboard.png)

A professional-grade, containerized infrastructure for running a private [Monero](https://www.getmonero.org/) full node, [P2Pool](https://github.com/SChernykh/p2pool), and [Tari](https://www.tari.com/) merge mining. This stack is engineered for maximum privacy ([Tor](https://www.torproject.org/)-only networking), hardware efficiency (HugePages/RandomX optimization), and ease of management via a bespoke dashboard.

## 🌟 Features
*   **Privacy by Design:** Integrated Tor daemon provides hidden services (Onion addresses) for Monero, Tari, and P2Pool. No public IPv4 port forwarding required.
*   **Merge Mining:** Automatically mines Tari (Minotari) alongside Monero via P2Pool sidechain integration.
*   **Smart Yield Optimization:** Includes an algorithmic switching engine (`algo.py`) that optimizes donation tiers (XMRvsBeast) vs. P2Pool mining based on real-time hashrate.
*   **Connection Aggregation:** Built-in **XMRig Proxy** reduces network overhead by aggregating multiple workers into a single connection.
*   **Real-time Dashboard:** Custom Python/Aiohttp interface featuring mDNS worker discovery, historical hashrate charting, and PPLNS window tracking.
*   **Security:** All binaries are verified via SHA256 hashes during build. Services run with least-privilege users where applicable.

## 🏗️ Architecture
The stack orchestrates six primary services via Docker Compose:
1.  **Monerod:** The Monero daemon (Full Node). Configured for restricted RPC and Tor transaction broadcasting.
2.  **P2Pool:** Decentralized mining sidechain. Supports Main, Mini, and Nano chains.
3.  **Tari Base Node:** Minotari node configured for merge mining with Monero.
4.  **XMRig Proxy:** Aggregates downstream workers to optimize difficulty and connection management.
5.  **Tor:** Centralized anonymity layer providing SOCKS5 proxies and Hidden Services for all containers.
6.  **Dashboard:** Web-based monitoring UI.

### High-Level Diagram

```mermaid
graph TD
    subgraph "Docker Stack"
        Dashboard[Dashboard & Algo Engine]
        Tor[Tor Anonymity Service]
        
        subgraph "Mining Core"
            Monerod[Monero Daemon]
            P2Pool[P2Pool Node]
            Tari[Tari Base Node]
            Proxy[XMRig Proxy]
        end
    end

    subgraph "External"
        Workers[Hardware Workers\n(XMRig)]
        XvB[XMRvsBeast Pool]
        Internet[Tor Network / Internet]
    end

    Workers -- "Stratum (3333)" --> P2Pool
    Workers -- "Stratum (3344)" --> Proxy
    Dashboard -.->|API Control (8080)| Workers
    
    Proxy -->|Donation Traffic| XvB
    
    P2Pool <-->|RPC/ZMQ| Monerod
    P2Pool -->|Merge Mine| Tari
    
    Monerod <-->|Tx Broadcast| Tor
    Tari <-->|P2P Traffic| Tor
    P2Pool <-->|P2P Traffic| Tor
    
    Tor <--> Internet
```

## 🧠 Algorithmic Switching & Port Logic

This stack employs a smart switching strategy to maximize yield by leveraging the XMRvsBeast bonus rounds while maintaining P2Pool stability.

### Port Configuration
Workers must be configured with two upstream pools (handled automatically by the included **Worker Starter** kit):
*   **Pool 0 (Primary):** Connects to **Port 3333** (P2Pool Stratum). This yields Monero + Tari.
*   **Pool 1 (Bonus):** Connects to **Port 3344** (XMRig Proxy). This forwards hashrate to the XMRvsBeast pool.

### Decision Engine (`algo.py`)
The Dashboard monitors your total aggregate hashrate and controls your workers via their local API (Port 8080):
1.  **Tier Calculation:** It calculates which XvB donation tier you qualify for (e.g., Whale @ 100 kH/s).
2.  **Dynamic Switching:**
    *   If your XvB average drops below the target, it temporarily switches workers to **Pool 1** (Port 3344).
    *   Once the target is met, it switches workers back to **Pool 0** (Port 3333) to resume P2Pool mining.
3.  **Split Mode:** If you have excess hashrate, it calculates the precise time split required to maintain the bonus tier while maximizing P2Pool uptime.

## 🚀 Getting Started

### 1. Prerequisites
*   **OS:** Ubuntu 24.04 LTS (Recommended)
*   **Hardware:** CPU with AVX2 support (Required for RandomX performance).
*   **Software:** Docker Engine & Docker Compose V2.
*   **Utilities:** `jq` (JSON processor).
    ```bash
    sudo apt update && sudo apt install -y jq docker.io docker-compose-v2
    ```

### 2. Configuration
Create a `config.json` file in the root directory. This file drives the deployment script.

**Example `config.json`:**
```bash
{
  "monero": {
    "data_dir": "DYNAMIC_DATA",
    "wallet_address": "48...",
    "node_username": "admin",
    "node_password": "supersecretpassword"
  },
  "tari": {
    "data_dir": "DYNAMIC_DATA",
    "wallet_address": "54..."
  },
  "p2pool": {
    "data_dir": "DYNAMIC_DATA",
    "pool": "mini" 
  },
  "tor": {
    "data_dir": "DYNAMIC_DATA"
  },
  "dashboard": {
    "data_dir": "DYNAMIC_DATA"
  },
  "xmrig_proxy": {
    "port": "3344",
    "url": "na.xmrvsbeast.com:4247",
    "donor_id": "DYNAMIC_ID"
  }
}
```
*Note: `DYNAMIC_DATA` defaults to `./data/<service>`. `DYNAMIC_ID` uses the first 8 chars of your Monero wallet.*

### 3. Deployment
1.  **Initialize:** Run the deployment script. This handles directory permissions, Tor service provisioning, and kernel tuning.
    ```bash
    chmod +x deploy.sh
    ./deploy.sh
    ```
2.  **Reboot:** The script configures HugePages (3072 pages) in GRUB for optimal mining performance. A reboot is required for these kernel changes to persist.
    ```bash
    sudo reboot
    ```
3.  **Launch:** Start the stack.
    ```bash
    docker compose up -d
    ```

## ⛏️ Adding Workers (Hardware Provisioning)
To connect external hardware miners (CPUs) to this stack, they must be able to reach the **Dashboard IP** on ports **3333** (P2Pool) and **3344** (Proxy).

For maximum efficiency on worker nodes (Ryzen MSR mods, HugePages) and automatic dual-pool configuration, use the included **Worker Starter** kit located in the `worker/` directory.

**Quick Setup on Worker Machine:**
```bash
git clone https://github.com/VijitSingh97/p2pool-starter-stack.git
cd p2pool-starter-stack/worker
# Edit configuration.json to point to your Stack's IP
sudo ./deploy.sh
sudo reboot
```

## 📈 Monitoring
-------------

Access the dashboard at:

*   **Local:** `http://localhost:8000`
*   **Network:** `http://<your-server-ip>:8000` (or `<hostname>.local:8000`)

## 🛠️ Maintenance
---------------

**Check Logs:**

    ```bash
    docker compose logs -f monerod  # Monitor blockchain sync  docker compose logs -f p2pool   # Monitor pool shares
    ```

**Update Stack:** Modify the `ARG` versions in the Dockerfiles and rebuild:

    ```bash
    docker compose build --no-cache && docker compose up -d
    ```

📄 License
----------

This project is provided "as-is" under the MIT License.
