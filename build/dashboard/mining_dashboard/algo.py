import math
import logging
from config import XVB_TIME_ALGO_MS, XVB_MIN_TIME_SEND_MS

class XvbAlgorithm:
    def __init__(self, state_manager):
        self.state = state_manager
        self.logger = logging.getLogger("XvB_Algo")
        
        # Margin for 1h average (from Rust: XVB_SIDE_MARGIN_1H)
        # Allows for 20% variance in the short term without forcing a switch
        self.margin_1h = 0.2 

    def get_decision(self, current_hr, p2pool_stats, xvb_stats):
        """
        Main decision loop.
        Returns: ("MODE_NAME", duration_ms_for_xvb)
        """
        # 1. Safety Check: Do we have a share in P2Pool?
        # If not, we MUST mine P2Pool to avoid losing revenue.
        shares_found = p2pool_stats.get('shares_found', 0)
        
        if shares_found == 0:
            self.logger.info("Algo: No shares found in P2Pool window. Forcing P2POOL.")
            return "P2POOL", 0

        # 2. Determine Target
        # "What is the highest XvB tier I qualify for right now?"
        target_hr = self._get_target_donation_hr(current_hr)
        
        # If we don't qualify for any tier (standard donor), defaults to 0
        if target_hr == 0:
             return "P2POOL", 0

        # 3. Check Current Averages
        avg_24h = xvb_stats.get('24h_avg', 0)
        avg_1h = xvb_stats.get('1h_avg', 0)

        # Logic: Are we meeting our donation target?
        # We need to satisfy the 24h average AND be within 20% of the 1h average.
        is_fulfilled = (avg_24h >= target_hr) and (avg_1h >= (target_hr * (1.0 - self.margin_1h)))

        if not is_fulfilled:
            # We are behind. Send a full cycle to XvB to catch up.
            self.logger.info(f"Algo: Target {target_hr} H/s not met (24h: {avg_24h:.0f}). Forcing XVB.")
            return "XVB", XVB_TIME_ALGO_MS
        
        # 4. Split Cycle (Maintenance Mode)
        # We are on target, but need to donate a small slice to STAY on target.
        needed_time_ms = self._get_needed_time(current_hr, target_hr)
        
        if needed_time_ms > 0:
            # Enforce minimum switch time to avoid spamming the miner
            if needed_time_ms < XVB_MIN_TIME_SEND_MS:
                needed_time_ms = XVB_MIN_TIME_SEND_MS
            
            # Don't exceed the total cycle time
            if needed_time_ms > XVB_TIME_ALGO_MS:
                needed_time_ms = XVB_TIME_ALGO_MS
                
            self.logger.info(f"Algo: Maintenance. Sending {needed_time_ms}ms to XvB.")
            return "SPLIT", int(needed_time_ms)
            
        return "P2POOL", 0

    def _get_target_donation_hr(self, current_hr):
        """
        Automatically finds the best tier based on current hashrate.
        Queries the limits scraped from the XvB website (stored in state).
        """
        # Retrieve dynamic limits (defaults used if scraping hasn't run yet)
        limit_mega = self.state.get_tier_limit("donor_mega")
        limit_whale = self.state.get_tier_limit("donor_whale")
        limit_vip = self.state.get_tier_limit("donor_vip")
        limit_mvp = self.state.get_tier_limit("mvp")
        
        # Check tiers in descending order (Highest priority first)
        if limit_mega > 0 and current_hr > limit_mega:
            return float(limit_mega)
        elif limit_whale > 0 and current_hr > limit_whale:
            return float(limit_whale)
        elif limit_vip > 0 and current_hr > limit_vip:
            return float(limit_vip)
        elif limit_mvp > 0 and current_hr > limit_mvp:
            return float(limit_mvp)
            
        # Fallback: Standard Donor. 
        # Usually 0 enforced requirement, but you can change this to 
        # return current_hr * 0.01 if you always want to donate 1%.
        return 0.0

    def _get_needed_time(self, current_hr, target_hr):
        """Calculates exact milliseconds needed to maintain average."""
        if current_hr == 0: return 0
        # Formula: (Target / Current) * Cycle_Length
        needed = (target_hr / current_hr) * XVB_TIME_ALGO_MS
        return math.ceil(needed)