import math
import logging
from config import XVB_TIME_ALGO_MS, XVB_MIN_TIME_SEND_MS

class XvbAlgorithm:
    """
    Manages the switching logic between P2Pool and XvB donation mining.
    
    Determines the optimal mining mode (P2POOL, XVB, or SPLIT) based on 
    current hashrate, historical performance, and configured donation tiers.
    """
    def __init__(self, state_manager):
        self.state_manager = state_manager
        self.logger = logging.getLogger("XvB_Algo")
        
        # Safety margin (5%) to ensure the 1h average strictly meets the tier requirement
        # despite network fluctuations.
        self.margin_1h = 0.05 

    def get_decision(self, current_hr, p2pool_stats, xvb_stats):
        """
        Evaluates the current mining state to determine the next operation mode.

        Args:
            current_hr (float): Current 15m average hashrate.
            p2pool_stats (dict): Statistics from the local P2Pool node.
            xvb_stats (dict): Historical statistics for XvB mining.

        Returns:
            tuple: (Mode String ["P2POOL"|"XVB"|"SPLIT"], Duration in ms)
        """
        # Constraint: Enforce P2Pool mode if no shares have been found recently.
        # This prevents potential revenue loss during low-luck periods.
        shares_found = p2pool_stats.get('shares_found', 0)
        if shares_found == 0:
            self.logger.info("Decision Strategy: Force P2POOL (Zero shares in window)")
            return "P2POOL", 0

        # Constraint: Fallback to P2Pool if XvB endpoint failures exceed threshold.
        fail_count = xvb_stats.get('fail_count', 0)
        if fail_count >= 3:
            self.logger.warning(f"Decision Strategy: Force P2POOL (Excessive XvB failures: {fail_count})")
            return "P2POOL", 0

        # Identify the highest qualified donation tier based on hashrate capacity
        target_hr = self._get_target_donation_hr(current_hr)
        
        # If no tier is qualified (Standard/Free tier), default to P2Pool
        if target_hr == 0:
             return "P2POOL", 0

        # Verify if donation targets are currently satisfied
        # Criteria: 24h Avg >= Target AND 1h Avg >= (Target - Margin)
        avg_24h = xvb_stats.get('24h_avg', 0)
        avg_1h = xvb_stats.get('1h_avg', 0)

        is_fulfilled = (avg_24h >= target_hr) and (avg_1h >= (target_hr * (1.0 - self.margin_1h)))

        if not is_fulfilled:
            self.logger.info(f"Decision Strategy: Force XVB (Target {target_hr} not met, 24h: {avg_24h:.0f})")
            return "XVB", XVB_TIME_ALGO_MS
        
        # Split Mode: Calculate precise maintenance duration
        needed_time_ms = self._get_needed_time(current_hr, target_hr)
        
        if needed_time_ms > 0:
            # Clamp duration to configured bounds
            if needed_time_ms < XVB_MIN_TIME_SEND_MS:
                needed_time_ms = XVB_MIN_TIME_SEND_MS
            
            if needed_time_ms > XVB_TIME_ALGO_MS:
                needed_time_ms = XVB_TIME_ALGO_MS
                
            self.logger.info(f"Decision Strategy: Split Mode ({needed_time_ms}ms allocated to XvB)")
            return "SPLIT", int(needed_time_ms)
            
        return "P2POOL", 0

    def _get_target_donation_hr(self, current_hr):
        """
        Identifies the optimal donation tier.
        
        Reserves a 15% safety margin on the current hashrate to ensure
        P2Pool stability before committing to a higher tier.
        """
        safe_capacity = current_hr * 0.85 
        
        # Retrieve tier thresholds from state configuration
        tiers = self.state_manager.state.get("tiers", {})
        limit_mega = tiers.get("donor_mega", 0)
        limit_whale = tiers.get("donor_whale", 0)
        limit_vip = tiers.get("donor_vip", 0)
        limit_mvp = tiers.get("mvp", 0)
        limit_donor = tiers.get("donor", 0)
        
        # Evaluate tiers in descending order of requirement
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
        """
        Computes the precise duration (in milliseconds) required to sustain the target average.
        
        Formula: (Target Hashrate / Current Hashrate) * Cycle Length
        """
        if current_hr == 0: return 0
        needed = (target_hr / current_hr) * XVB_TIME_ALGO_MS
        return math.ceil(needed)