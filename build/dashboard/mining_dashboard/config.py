import os

# --- System Paths ---
# Adjust these if your Docker container paths differ
BASE_STATS_DIR = "/app/stats"
DISK_PATH = '/data'
STATE_FILE_PATH = os.path.join(DISK_PATH, "mining_state.json")

# --- Data Source File Paths ---
STRATUM_STATS_PATH = f"{BASE_STATS_DIR}/local/stratum"
TARI_STATS_PATH = f"{BASE_STATS_DIR}/local/merge_mining"
P2P_STATS_PATH = f"{BASE_STATS_DIR}/local/p2p"
POOL_STATS_PATH = f"{BASE_STATS_DIR}/pool/stats"
NETWORK_STATS_PATH = f"{BASE_STATS_DIR}/network/stats"

# --- Network & API Configuration ---
HOST_IP = os.environ.get("HOST_IP", "Unknown Host")
XMRIG_API_PORT = 8080
API_TIMEOUT = 1         # Seconds to wait for miner response
UPDATE_INTERVAL = 30    # Seconds between data refresh cycles

# --- XvB Algorithm Constants ---
# Controls the mining logic cycles
XVB_TIME_ALGO_MS = 60000        # Total cycle length (1 minute / 60,000 ms)
XVB_MIN_TIME_SEND_MS = 15000     # Minimum time to force a switch (5 seconds)
XVB_REWARD_URL = "https://xmrvsbeast.com/p2pool/estimated_reward.html"

# Default Fallbacks (Used if scraping fails or on first boot)
# These act as safe baselines until the scraper runs
TIER_DEFAULTS = {
    "donor_mega": 1000000, # 1 MH/s
    "donor_whale": 50000,  # 50 kH/s
    "donor_vip": 10000,    # 10 kH/s
    "mvp": 5000,           # 5 kH/s
    "donor": 0             # 0 kH/s
}

# P2Pool PPLNS Math Constants (for Mainnet)
# Used to calculate if you have enough hashrate to hold a share
BLOCK_PPLNS_WINDOW_MAIN = 2160  
SECOND_PER_BLOCK_MAIN = 120     

# --- Donation Auto-Levels ---
# Hashrate thresholds (H/s) to trigger different donation tiers
DONOR_LEVEL_VIP = 10000    # 10 kH/s
DONOR_LEVEL_WHALE = 50000  # 50 kH/s