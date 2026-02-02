import json
import os
from config import (
    P2P_STATS_PATH, POOL_STATS_PATH, NETWORK_STATS_PATH, 
    STRATUM_STATS_PATH, TARI_STATS_PATH
)

def _read_json(path):
    if os.path.exists(path):
        try:
            with open(path, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    return {}

def detect_pool_type(peers):
    counts = {"Main": 0, "Mini": 0, "Nano": 0}
    if not peers: return "Unknown"
    for p in peers:
        if "37889" in p: counts["Main"] += 1
        elif "37888" in p: counts["Mini"] += 1
        elif "37890" in p: counts["Nano"] += 1
    winner = max(counts, key=counts.get)
    return winner if counts[winner] > 0 else "Unknown"

def get_p2pool_stats():
    """Returns combined Pool and P2P networking stats."""
    raw_p2p = _read_json(P2P_STATS_PATH)
    raw_pool = _read_json(POOL_STATS_PATH)
    
    stats = {
        # P2P Section
        "p2p": {
            "type": detect_pool_type(raw_p2p.get("peers", [])),
            "connections": raw_p2p.get("connections", 0),
            "incoming": raw_p2p.get("incoming_connections", 0),
            "peers_count": raw_p2p.get("peer_list_size", 0),
            "uptime": raw_p2p.get("uptime", 0),
            "zmq_active": raw_p2p.get("zmq_last_active", 0)
        },
        # Pool Statistics Section
        "pool": {
            "hashrate": raw_pool.get("pool_statistics", {}).get("hashRate", 0),
            "miners": raw_pool.get("pool_statistics", {}).get("miners", 0),
            "blocks_found": raw_pool.get("pool_statistics", {}).get("totalBlocksFound", 0),
            "sidechain_height": raw_pool.get("pool_statistics", {}).get("sidechainHeight", 0),
            "last_block_found": raw_pool.get("pool_statistics", {}).get("lastBlockFound", 0),
            "last_block_ts": raw_pool.get("pool_statistics", {}).get("lastBlockFoundTime", 0),
            "pplns_weight": raw_pool.get("pool_statistics", {}).get("pplnsWeight", 0),
            "pplns_window": raw_pool.get("pool_statistics", {}).get("pplnsWindowSize", 0),
            "difficulty": raw_pool.get("pool_statistics", {}).get("sidechainDifficulty", 0),
            "total_hashes": raw_pool.get("pool_statistics", {}).get("totalHashes", 0),
            "shares_found": raw_pool.get("pool_statistics", {}).get("sharesFound", 0), # Important for Algo
        }
    }
    return stats

def get_network_stats():
    raw = _read_json(NETWORK_STATS_PATH)
    return {
        "difficulty": raw.get('difficulty', 0),
        "height": raw.get('height', 0),
        "reward": raw.get('reward', 0),
        "hash": raw.get('hash', 'N/A'),
        "timestamp": raw.get('timestamp', 0)
    }

def get_stratum_stats():
    """
    Returns:
    1. full raw stats (needed for Effort, Reward Share, Wallet, etc.)
    2. list of worker configs (for miners.py)
    """
    raw = _read_json(STRATUM_STATS_PATH)
    
    worker_configs = []
    # Parse workers for the active collector
    for w_entry in raw.get("workers", []):
        if isinstance(w_entry, str):
            parts = w_entry.split(',')
            # Format: ip, uptime, ?, hashrate, name
            if len(parts) >= 1:
                ip = parts[0]
                name = parts[4] if len(parts) >= 5 else "miner"
                # Store parts to allow fallback if API fails
                worker_configs.append({"ip": ip, "name": name, "parts": parts})

    return raw, worker_configs

def get_tari_stats():
    raw = _read_json(TARI_STATS_PATH)
    chains = raw.get("chains", [])
    if chains:
        t = chains[0]
        return {
            "active": True,
            "status": t.get('channel_state', 'UNKNOWN'),
            "address": t.get('wallet', 'Unknown'),
            "height": t.get('height', 0),
            "reward": t.get('reward', 0) / 1_000_000, 
            "difficulty": t.get('difficulty', 0)
        }
    return {"active": False}