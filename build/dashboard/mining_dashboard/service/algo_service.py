import asyncio
import logging
import time
import math
from config.config import (
    XVB_TIME_ALGO_MS, 
    MONERO_WALLET_ADDRESS, 
    XVB_DONOR_ID,
    P2POOL_URL,
    XVB_POOL_URL,
    XVB_MIN_TIME_SEND_MS,
    ENABLE_XVB,
    ALGO_MARGIN_1H,
    ALGO_TARGET_BUFFER,
    XVB_SWITCH_OVERHEAD_MS
)
from helper.utils import get_tier_info

logger = logging.getLogger("AlgoService")

class AlgoService:
    def __init__(self, state_manager, proxy_client, data_service):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.data_service = data_service
        # Safety margin (15%) to ensure the 1h average strictly meets the tier requirement
        self.margin_1h = ALGO_MARGIN_1H
        self.target_buffer = ALGO_TARGET_BUFFER

    async def switch_miners(self, mode, state_label=None):
        """
        Configures the upstream pool priority for the XMRig Proxy.
        """
        if mode == "P2POOL":
            pools = [
                {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": True, "coin": "monero"},
                {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": False, "coin": "monero"}
            ]
        else:
            pools = [
                {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "enabled": True, "coin": "monero"},
                {"url": P2POOL_URL, "user": MONERO_WALLET_ADDRESS, "pass": "x", "enabled": False, "coin": "monero"}
            ]

        try:
            # Fetch current full configuration to preserve other settings
            current_config = await asyncio.to_thread(self.proxy_client.get_config)
            current_config["pools"] = pools

            # Execute update via Proxy Client with the full configuration
            await asyncio.to_thread(self.proxy_client.update_config, current_config)
            
            # Update state manager with the new active mode
            final_label = state_label if state_label else mode
            await asyncio.to_thread(self.state_manager.update_xvb_stats, mode=final_label)
            logger.info(f"Switched Proxy to mode: {mode} (Label: {final_label})")
        except Exception as e:
            logger.error(f"Failed to switch proxy mode: {e}")

    def get_decision(self, current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares):
        """
        Evaluates the current mining state to determine the next operation mode.

        Args:
            current_hr (float): Current real-time (10s) hashrate for calculation.
            stable_hr (float): Stable (15m) hashrate for tier selection.
            p2pool_stats (dict): Statistics from the local P2Pool node.
            p2p_stats (dict): P2P network statistics (for pool type detection).
            xvb_stats (dict): Historical statistics for XvB mining.
            shares (list): List of recent shares with timestamps.

        Returns:
            tuple: (Mode String ["P2POOL"|"XVB"|"SPLIT"], Duration in ms)
        """
        # Feature Flag: Check if XvB switching is globally disabled
        if not ENABLE_XVB:
            # logger.info("Decision Strategy: Force P2POOL (XvB Switching Disabled)")
            return "P2POOL", 0

        # Constraint: Enforce P2Pool mode if no shares have been found recently.
        # This uses the same logic as the dashboard UI to count shares within the PPLNS window.
        pool_type = p2p_stats.get('type', 'Main')
        pplns_window = p2pool_stats.get('pplns_window', 2160)
        
        block_time = 10  # Default for Main/Mini
        if pool_type == "Nano":
            block_time = 30

        window_duration = pplns_window * block_time
        cutoff = time.time() - window_duration
        shares_in_window_count = sum(1 for s in shares if s.get('ts', 0) >= cutoff)

        if shares_in_window_count == 0:
            logger.info(f"Decision Strategy: Force P2POOL (Zero shares in PPLNS window of {window_duration}s)")
            return "P2POOL", 0

        # Constraint: Fallback to P2Pool if XvB endpoint failures exceed threshold.
        fail_count = xvb_stats.get('fail_count', 0)
        if fail_count >= 3:
            logger.warning(f"Decision Strategy: Force P2POOL (Excessive XvB failures: {fail_count})")
            return "P2POOL", 0

        # Identify the highest qualified donation tier based on STABLE hashrate capacity
        # This prevents the target from jumping around due to short-term variance
        target_hr = self._get_target_donation_hr(stable_hr)
        
        # If no tier is qualified (Standard/Free tier), default to P2Pool
        if target_hr == 0:
             return "P2POOL", 0

        # Verify if donation targets are currently satisfied
        # Criteria: 24h Avg >= Target AND 1h Avg >= (Target - Margin)
        avg_24h = xvb_stats.get('avg_24h', 0)
        avg_1h = xvb_stats.get('avg_1h', 0)

        is_fulfilled = (avg_24h >= target_hr) and (avg_1h >= (target_hr * (1.0 - self.margin_1h)))

        if not is_fulfilled:
            logger.info(f"Decision Strategy: Force XVB (Target {target_hr} not met, 24h: {avg_24h:.0f})")
            return "XVB", XVB_TIME_ALGO_MS
        
        # Split Mode: Calculate precise maintenance duration
        # Uses current_hr (real-time) to adjust donation time dynamically
        needed_time_ms = self._get_needed_time(current_hr, target_hr)
        
        if needed_time_ms > 0:
            # Clamp duration to configured bounds
            if needed_time_ms < XVB_MIN_TIME_SEND_MS:
                needed_time_ms = XVB_MIN_TIME_SEND_MS
            
            # Optimization: If P2Pool remainder is too small (< 30s), commit full cycle to XVB
            # This prevents inefficient short switching cycles.
            if (XVB_TIME_ALGO_MS - needed_time_ms) < 30000:
                needed_time_ms = XVB_TIME_ALGO_MS

            if needed_time_ms >= XVB_TIME_ALGO_MS:
                logger.info(f"Decision Strategy: Split Mode (Full Cycle allocated to XvB)")
                return "XVB", XVB_TIME_ALGO_MS

            logger.info(f"Decision Strategy: Split Mode ({needed_time_ms}ms allocated to XvB)")
            return "SPLIT", int(needed_time_ms)
            
        return "P2POOL", 0

    def _get_target_donation_hr(self, current_hr):
        """
        Identifies the optimal donation tier.
        
        Reserves a 15% safety margin on the current hashrate to ensure
        P2Pool stability before committing to a higher tier.
        """
        safe_capacity = current_hr * 0.85 
        tiers = self.state_manager.get_tiers()
        
        _, threshold = get_tier_info(safe_capacity, tiers)
        return threshold

    def _get_needed_time(self, current_hr, target_hr):
        """
        Computes the precise duration (in milliseconds) required to sustain the target average.
        
        Formula: (Target Hashrate / Current Hashrate) * Cycle Length
        """
        if current_hr == 0: return 0
        # Apply buffer to target hashrate to prevent dropping below threshold
        target_with_buffer = target_hr * (1.0 + self.target_buffer)
        needed = (target_with_buffer / current_hr) * XVB_TIME_ALGO_MS
        
        # Add switching overhead compensation
        needed += XVB_SWITCH_OVERHEAD_MS
        
        return math.ceil(needed)

    async def run(self):
        """
        Periodic task to execute the mining strategy algorithm.
        Determines the optimal mining mode and manages worker switching cycles.
        """
        logger.info("Service Started: Algorithm Control Loop")
        await asyncio.sleep(5) 
        
        while True:
            try:
                # Access latest data from DataService
                latest_data = self.data_service.latest_data
                
                # Use 10s average for immediate reaction to hashrate drops
                current_hr = latest_data.get("total_live_h10", 0)
                if current_hr == 0:
                    current_hr = latest_data.get("total_live_h15", 0)

                # Use 15m average for stable tier selection
                stable_hr = latest_data.get("total_live_h15", 0)
                if stable_hr == 0:
                    stable_hr = current_hr

                p2pool_data = latest_data.get("pool", {})
                p2pool_stats = p2pool_data.get("pool", {})
                p2p_stats = p2pool_data.get("p2p", {})
                xvb_stats = self.state_manager.get_xvb_stats()
                shares = latest_data.get("shares", [])
                
                # Execute decision logic
                decision, xvb_duration = self.get_decision(current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares)
                
                if decision == "P2POOL":
                    await self.switch_miners("P2POOL", state_label="P2POOL")
                    await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                    
                elif decision == "XVB":
                    await self.switch_miners("XVB", state_label="XVB")
                    await asyncio.sleep(XVB_TIME_ALGO_MS / 1000)
                    
                elif decision == "SPLIT":
                    # Split Mode: Allocate time slice to XvB, remainder to P2Pool
                    await self.switch_miners("XVB", state_label="XVB (Split)")
                    await asyncio.sleep(xvb_duration / 1000)
                    
                    remainder = (XVB_TIME_ALGO_MS - xvb_duration) / 1000
                    if remainder > 0:
                        await self.switch_miners("P2POOL", state_label="P2POOL (Split)")
                        await asyncio.sleep(remainder)

            except Exception as e:
                logger.error(f"Algorithm Error: {e}")
                await asyncio.sleep(10)