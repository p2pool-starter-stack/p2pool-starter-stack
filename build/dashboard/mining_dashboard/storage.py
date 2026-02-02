import json
import logging
import os
import time
from config import STATE_FILE_PATH, TIER_DEFAULTS

class StateManager:
    """
    Manages persistent application state including hashrate history and mining mode statistics.
    
    Handles atomic file I/O to prevent data corruption and ensures state consistency
    across application restarts.
    """
    def __init__(self):
        self.logger = logging.getLogger("StateManager")
        self.filepath = STATE_FILE_PATH
        self.state = {
            "hashrate_history": [],
            "xvb": {
                "total_donated_time": 0,
                "current_mode": "P2POOL",
                "24h_avg": 0.0,
                "1h_avg": 0.0,
                "fail_count": 0,
                "last_update": 0
            },
            # Initialize state with default values from configuration
            "tiers": TIER_DEFAULTS.copy()
        }
        self.load()

    def load(self):
        """
        Loads state from the JSON file on disk.
        
        Merges loaded data with default structure to ensure backward compatibility
        if new keys are added to the application state in future versions.
        """
        if os.path.exists(self.filepath):
            try:
                with open(self.filepath, 'r') as f:
                    data = json.load(f)
                    
                    # Perform deep update to preserve structure for missing keys
                    if "hashrate_history" in data:
                        self.state["hashrate_history"] = data["hashrate_history"]
                    
                    if "xvb" in data:
                        # Only update keys that exist in the loaded data, preserving defaults for others
                        self.state["xvb"].update(data["xvb"])
                        
                    self.logger.info(f"State successfully loaded from {self.filepath}")
            except (json.JSONDecodeError, OSError) as e:
                self.logger.error(f"State Persistence Error: Failed to load state: {e}")

    def save(self):
        """
        Persists current state to disk using atomic write operations.
        
        Writes to a temporary file first, then performs an atomic rename to
        prevent data corruption in the event of a crash or power failure.
        """
        try:
            # Write to temporary file first
            temp_path = f"{self.filepath}.tmp"
            with open(temp_path, 'w') as f:
                json.dump(self.state, f, indent=2)
            # Atomic rename
            os.replace(temp_path, self.filepath)
        except OSError as e:
            self.logger.error(f"State Persistence Error: Failed to save state: {e}")

    def update_history(self, hashrate, p2pool_hr=0, xvb_hr=0):
        """Appends a new hashrate data point to the history buffer (capped at 60 entries)."""
        history = self.state["hashrate_history"]
        
        # Append new data point with timestamp
        history.append({
            "t": time.strftime('%H:%M'),
            "v": round(hashrate, 2),
            "v_p2pool": round(p2pool_hr, 2),
            "v_xvb": round(xvb_hr, 2)
        })
        
        # Enforce rolling window size (Max 60 entries)
        if len(history) > 60:
            history.pop(0)
            
        self.save()

    def get_xvb_stats(self):
        """Returns the current XvB mining statistics dictionary."""
        return self.state["xvb"]

    def update_xvb_stats(self, mode=None, donation_avg_24h=None, donation_avg_1h=None, fail_count=None):
        """
        Updates specific fields within the XvB statistics state.
        
        Allows partial updates to decouple mode switching from statistical updates.
        
        Args:
            mode (str, optional): The current mining mode (e.g., "P2POOL", "XVB").
            donation_avg_24h (float, optional): 24-hour average hashrate on XvB.
            donation_avg_1h (float, optional): 1-hour average hashrate on XvB.
            fail_count (int, optional): Consecutive failure count for XvB endpoint.
        """
        if mode is not None:
            self.state["xvb"]["current_mode"] = mode

        stats_updated = False
        if donation_avg_24h is not None:
            self.state["xvb"]["24h_avg"] = donation_avg_24h
            stats_updated = True
            
        if donation_avg_1h is not None:
            self.state["xvb"]["1h_avg"] = donation_avg_1h
            stats_updated = True
        if fail_count is not None:
            self.state["xvb"]["fail_count"] = fail_count
            stats_updated = True
            
        # Update timestamp only if statistical data changed
        if stats_updated:
            self.state["xvb"]["last_update"] = time.time()
            
        self.save()
