import os

# --- System Paths ---
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
API_TIMEOUT = 1         
UPDATE_INTERVAL = 30    

# --- XvB Algorithm Constants ---
XVB_TIME_ALGO_MS = 60000        
XVB_MIN_TIME_SEND_MS = 15000     

# --- CORRECTED TIER REQUIREMENTS ---
# Based on official rules: Mega=1M, Whale=100k, VIP=10k, Donor=1k
TIER_DEFAULTS = {
    "donor_mega": 1000000, 
    "donor_whale": 100000, # UPDATED: Was 50k, now 100k
    "donor_vip": 10000,    
    "mvp": 5000,           
    "donor": 1000          # UPDATED: Was 0, now 1k
}

# P2Pool PPLNS Math Constants 
BLOCK_PPLNS_WINDOW_MAIN = 2160  
SECOND_PER_BLOCK_MAIN = 120