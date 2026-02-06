import json
import os
import time
from config.config import (
    P2P_STATS_PATH, POOL_STATS_PATH, NETWORK_STATS_PATH, 
    STRATUM_STATS_PATH, TARI_STATS_PATH, SECOND_PER_BLOCK_MAIN,
    BLOCK_PPLNS_WINDOW_MAIN, BLOCK_PPLNS_WINDOW_MINI, BLOCK_PPLNS_WINDOW_NANO,
    SECOND_PER_BLOCK_P2POOL_MAIN, SECOND_PER_BLOCK_P2POOL_MINI, SECOND_PER_BLOCK_P2POOL_NANO
)

def _read_json(path):
    """
    Safely loads a JSON file, returning an empty dictionary on failure.
    Designed to prevent application crashes during transient file I/O operations.
    """
    if os.path.exists(path):
        try:
            with open(path, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            # Fail silently to allow the dashboard to continue running
            # even if a stats file is currently being written to.
            pass
    return {}

def detect_pool_type(peers):
    """
    Heuristically detects the P2Pool network type (Main, Mini, Nano) based on peer ports.
    
    Args:
        peers (list): List of peer connection strings (e.g., "1.2.3.4:37889").
    """
    counts = {"Main": 0, "Mini": 0, "Nano": 0}
    if not peers: 
        return "Unknown"
        
    for p in peers:
        if "37889" in p: counts["Main"] += 1
        elif "37888" in p: counts["Mini"] += 1
        elif "37890" in p: counts["Nano"] += 1
        
    winner = max(counts, key=counts.get)
    return winner if counts[winner] > 0 else "Unknown"

def get_p2pool_stats():
    """Aggregates P2Pool local statistics and P2P network health data."""
    raw_p2p = _read_json(P2P_STATS_PATH)
    raw_pool = _read_json(POOL_STATS_PATH)
    raw_stratum = _read_json(STRATUM_STATS_PATH)
    pool_stats = raw_pool.get("pool_statistics", {})
    
    pool_type = detect_pool_type(raw_p2p.get("peers", []))

    # Determine Window Duration based on Chain Type
    window_blocks = BLOCK_PPLNS_WINDOW_MAIN
    block_time = SECOND_PER_BLOCK_P2POOL_MAIN
    
    if pool_type == "Nano":
        window_blocks = BLOCK_PPLNS_WINDOW_NANO
        block_time = SECOND_PER_BLOCK_P2POOL_NANO
    elif pool_type == "Mini":
        window_blocks = BLOCK_PPLNS_WINDOW_MINI
        block_time = SECOND_PER_BLOCK_P2POOL_MINI
    
    window_duration = window_blocks * block_time
    
    # Calculate Shares in Window
    last_share_time = raw_stratum.get("last_share_found_time", 0)
    shares_total = raw_stratum.get("shares_found", 0)
    shares_in_window = 1 if (shares_total > 0 and (time.time() - last_share_time) < window_duration) else 0

    stats = {
        "p2p": {
            "type": pool_type,
            "out_peers": raw_p2p.get("connections", 0),
            "in_peers": raw_p2p.get("incoming_connections", 0),
            "peers_count": raw_p2p.get("peer_list_size", 0),
            "uptime": raw_p2p.get("uptime", 0),
            "zmq_active": raw_p2p.get("zmq_last_active", 0)
        },
        "pool": {
            "hashrate": pool_stats.get("hashRate", 0),
            "miners": pool_stats.get("miners", 0),
            "blocks_found": pool_stats.get("totalBlocksFound", 0),
            "sidechain_height": pool_stats.get("sidechainHeight", 0),
            "last_block_found": pool_stats.get("lastBlockFound", 0),
            "last_block_ts": pool_stats.get("lastBlockFoundTime", 0),
            "pplns_weight": pool_stats.get("pplnsWeight", 0),
            "pplns_window": pool_stats.get("pplnsWindowSize", 0),
            "difficulty": pool_stats.get("sidechainDifficulty", 0),
            "total_hashes": pool_stats.get("totalHashes", 0),
            "shares_found": shares_total,
            "shares_in_window": shares_in_window, # Critical metric for Algo switching
        }
    }
    return stats

def get_network_stats():
    """Retrieves Monero network statistics (Difficulty, Height, Reward)."""
    raw = _read_json(NETWORK_STATS_PATH)
    
    diff = raw.get('difficulty', 0)
    hashrate = raw.get('hash', 'N/A')
    
    # Calculate hashrate if missing (Difficulty / Target Time)
    if (hashrate == 'N/A' or hashrate == 0) and diff > 0:
        hashrate = diff / SECOND_PER_BLOCK_MAIN
        
    return {
        "difficulty": diff,
        "height": raw.get('height', 0),
        "reward": raw.get('reward', 0),
        "hash": hashrate,
        "timestamp": raw.get('timestamp', 0)
    }

def get_stratum_stats():
    """
    Parses local stratum statistics to extract worker configurations.
    
    Returns:
        tuple: (Raw JSON dict, List of worker config dicts)
    """
    raw = _read_json(STRATUM_STATS_PATH)
    
    worker_configs = []
    # Iterate through worker entries (Format: "IP, ..., ..., ..., Name, ...")
    for w_entry in raw.get("workers", []):
        if isinstance(w_entry, str):
            parts = w_entry.split(',')
            if len(parts) >= 1:
                ip = parts[0].split(':')[0].strip()
                # Default to "miner" if name field (index 4) is missing
                name = parts[4].strip() if len(parts) >= 5 else "miner"
                worker_configs.append({"ip": ip, "name": name, "parts": parts})

    return raw, worker_configs

def get_tari_stats():
    """Retrieves Tari merge mining status and rewards."""
    raw = _read_json(TARI_STATS_PATH)
    chains = raw.get("chains", [])
    if chains:
        t = chains[0]
        return {
            "active": True,
            "status": t.get('channel_state', 'UNKNOWN'),
            "address": t.get('wallet', 'Unknown'),
            "height": t.get('height', 0),
            "reward": t.get('reward', 0) / 1_000_000, # Convert uTari to Tari
            "difficulty": t.get('difficulty', 0)
        }
    return {"active": False}