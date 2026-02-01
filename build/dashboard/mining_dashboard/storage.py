import json
import os
import time
from config import STATE_FILE_PATH

class StateManager:
    def __init__(self):
        self.filepath = STATE_FILE_PATH
        self.state = {
            "hashrate_history": [],
            "xvb": {
                "total_donated_time": 0,
                "current_mode": "P2POOL",
                "24h_avg": 0.0,
                "1h_avg": 0.0,
                "last_update": 0
            },
            # Initialize with defaults from config.py
            "tiers": TIER_DEFAULTS.copy()
        }
        self.load()

    def load(self):
        if os.path.exists(self.filepath):
            try:
                with open(self.filepath, 'r') as f:
                    data = json.load(f)
                    # Deep update to preserve structure if keys are missing in file
                    if "hashrate_history" in data:
                        self.state["hashrate_history"] = data["hashrate_history"]
                    if "xvb" in data:
                        self.state["xvb"].update(data["xvb"])
                    print(f"State loaded from {self.filepath}")
            except Exception as e:
                print(f"Failed to load state: {e}")

    def save(self):
        try:
            # Atomic write to prevent corruption
            temp_path = f"{self.filepath}.tmp"
            with open(temp_path, 'w') as f:
                json.dump(self.state, f, indent=2)
            os.replace(temp_path, self.filepath)
        except Exception as e:
            print(f"Failed to save state: {e}")

    def update_history(self, hashrate):
        """Adds a data point to the graph history (max 60 points)"""
        history = self.state["hashrate_history"]
        
        # Add new point
        history.append({
            "t": time.strftime('%H:%M'),
            "v": round(hashrate, 2)
        })
        
        # Keep last 60 entries (approx 30 mins if updating every 30s)
        if len(history) > 60:
            history.pop(0)
            
        self.save()

    def get_xvb_stats(self):
        return self.state["xvb"]

    def update_xvb_stats(self, mode, donation_avg_24h, donation_avg_1h):
        self.state["xvb"]["current_mode"] = mode
        self.state["xvb"]["24h_avg"] = donation_avg_24h
        self.state["xvb"]["1h_avg"] = donation_avg_1h
        self.state["xvb"]["last_update"] = time.time()
        self.save()

    def update_tiers(self, new_tiers):
        """Updates tier limits from scraper"""
        if not new_tiers: return
        changed = False
        for k, v in new_tiers.items():
            # Only update if key exists (security) and value is different
            if k in self.state["tiers"] and self.state["tiers"][k] != v:
                self.state["tiers"][k] = v
                changed = True
        if changed:
            self.save()

    def get_tier_limit(self, name):
        return self.state["tiers"].get(name, 0)