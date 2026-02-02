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
        # Safety: Force P2Pool if no shares found in window to prevent revenue loss.
        shares_found = p2pool_stats.get('shares_found', 0)
        
        if shares_found == 0:
            self.logger.info("Decision: Force P2POOL (No shares in window)")
            return "P2POOL", 0

        # Determine highest qualified XvB tier
        target_hr = self._get_target_donation_hr(current_hr)
        
        # If no tier qualified (standard donor), default to P2Pool
        if target_hr == 0:
             return "P2POOL", 0

        # Check if donation targets are met (24h avg >= target AND 1h avg within margin)
        avg_24h = xvb_stats.get('24h_avg', 0)
        avg_1h = xvb_stats.get('1h_avg', 0)

        is_fulfilled = (avg_24h >= target_hr) and (avg_1h >= (target_hr * (1.0 - self.margin_1h)))

        if not is_fulfilled:
            self.logger.info(f"Decision: Force XVB (Target {target_hr} not met, 24h: {avg_24h:.0f})")
            return "XVB", XVB_TIME_ALGO_MS
        
        # Split Cycle (Maintenance Mode)
        needed_time_ms = self._get_needed_time(current_hr, target_hr)
        
        if needed_time_ms > 0:
            if needed_time_ms < XVB_MIN_TIME_SEND_MS:
                needed_time_ms = XVB_MIN_TIME_SEND_MS
            
            if needed_time_ms > XVB_TIME_ALGO_MS:
                needed_time_ms = XVB_TIME_ALGO_MS
                
            self.logger.info(f"Decision: Split Mode ({needed_time_ms}ms to XvB)")
            return "SPLIT", int(needed_time_ms)
            
        return "P2POOL", 0

    def _get_target_donation_hr(self, current_hr):
        """
        Finds best tier, reserving 15% hashrate for P2Pool safety.
        """
        safe_capacity = current_hr * 0.85 
        
        limit_mega = self.state.get_tier_limit("donor_mega")   # 1,000,000
        limit_whale = self.state.get_tier_limit("donor_whale") # 100,000
        limit_vip = self.state.get_tier_limit("donor_vip")     # 10,000
        limit_mvp = self.state.get_tier_limit("mvp")           # 5,000
        limit_donor = self.state.get_tier_limit("donor")       # 1,000
        
        # Check tiers against SAFE capacity
        if limit_mega > 0 and safe_capacity >= limit_mega:
            return float(limit_mega)
        elif limit_whale > 0 and safe_capacity >= limit_whale:
            return float(limit_whale)
        elif limit_vip > 0 and safe_capacity >= limit_vip:
            return float(limit_vip)
        elif limit_mvp > 0 and safe_capacity >= limit_mvp:
            return float(limit_mvp)
        elif limit_donor > 0 and safe_capacity >= limit_donor:
            return float(limit_donor)
            
        return 0.0

    def _get_needed_time(self, current_hr, target_hr):
        """Calculates exact milliseconds needed to maintain average."""
        if current_hr == 0: return 0
        # Formula: (Target / Current) * Cycle_Length
        needed = (target_hr / current_hr) * XVB_TIME_ALGO_MS
        return math.ceil(needed)