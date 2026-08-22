import asyncio
import logging
import math
import time

from mining_dashboard.config.config import (
    ENABLE_XVB,
    MONERO_WALLET_ADDRESS,
    P2POOL_URL,
    UPDATE_INTERVAL,
    XVB_CONTROL_GAIN,
    XVB_DONATION_LEVEL,
    XVB_DONOR_ID,
    XVB_MAINT_MARGIN_ABS_CAP,
    XVB_MAINT_MARGIN_PCT,
    XVB_MAX_DONATION_FRACTION,
    XVB_MIN_TIME_SEND_MS,
    XVB_P2POOL_RESERVE_FACTOR,
    XVB_POOL_URL,
    XVB_PROJECTION_HORIZON_S,
    XVB_STALE_DECAY_AFTER_S,
    XVB_STATS_STALE_AFTER_S,
    XVB_SWITCH_OVERHEAD_MS,
    XVB_TIME_ALGO_MS,
    XVB_TOR_ENABLED,
    XVB_TOR_SOCKS5,
    XVB_WIN_ROUND_HOLD_S,
)
from mining_dashboard.helper.utils import (
    DEFAULT_PPLNS_WINDOW,
    pplns_block_time,
    resolve_target_threshold,
    shares_in_pplns_window,
    xvb_stats_are_stale,
)
from mining_dashboard.service.steering_projection import (
    max_donation_fraction,
    projected_avg_1h,
    record_avg1h_sample,
    reference_hr,
    won_round_live,
)

logger = logging.getLogger("AlgoService")

# Prolonged-staleness fail-safe (see XVB_STALE_DECAY_AFTER_S). Once past the decay grace,
# multiply the held donation fraction by this each advance cycle so it geometrically bleeds
# toward 0, and snap to 0 below the floor (a tiny residual would otherwise be floored back
# up to XVB_MIN_TIME_SEND_MS, never actually stopping). 0.5 halves the blind donation every
# cycle — a fast, obvious retreat when we can't confirm the donation is still needed.
XVB_STALE_DECAY_FACTOR = 0.5
XVB_STALE_DECAY_FLOOR = 0.005


class AlgoService:
    def __init__(self, state_manager, proxy_client, data_service):
        self.state_manager = state_manager
        self.proxy_client = proxy_client
        self.data_service = data_service
        # XvB donation controller tuning (see config.py).
        self.donation_level = XVB_DONATION_LEVEL
        self.max_donation_fraction = XVB_MAX_DONATION_FRACTION
        self.maint_margin_pct = XVB_MAINT_MARGIN_PCT
        self.maint_margin_abs_cap = XVB_MAINT_MARGIN_ABS_CAP
        self.control_gain = XVB_CONTROL_GAIN
        self.p2pool_reserve_factor = XVB_P2POOL_RESERVE_FACTOR
        # Closed-loop state: the fraction of each cycle currently donated to XvB.
        # Advanced once per real cycle by the calibration loop (not in _smart_sleep).
        # None until the first decision seeds it from the feedforward estimate.
        self.donation_fraction = None
        # (fetch-timestamp, avg_1h) history for the protective projection — appended
        # only when a genuine fetch lands (last_update moved), pruned to the lookback.
        self._avg1h_trend = []

    async def switch_miners(self, mode, state_label=None):
        """
        Configures the upstream pool priority for the XMRig Proxy.
        """
        # The local p2pool pool dials direct (it's on the bridge). The XvB pool routes through Tor by
        # default (#166) — its per-pool `socks5` makes the proxy reach na.xmrvsbeast.com via Tor
        # (DNS resolved proxy-side), so donation mining doesn't expose the home IP. `xvb.tor: false`
        # opts out. Only the XvB pool gets `socks5`; the local pool never does.
        p2pool_pool = {
            "url": P2POOL_URL,
            "user": MONERO_WALLET_ADDRESS,
            "pass": "x",
            "coin": "monero",
        }
        xvb_pool = {"url": XVB_POOL_URL, "user": XVB_DONOR_ID, "pass": "x", "coin": "monero"}
        if XVB_TOR_ENABLED:
            xvb_pool["socks5"] = XVB_TOR_SOCKS5

        if mode == "P2POOL":
            pools = [{**p2pool_pool, "enabled": True}, {**xvb_pool, "enabled": False}]
        else:
            pools = [{**xvb_pool, "enabled": True}, {**p2pool_pool, "enabled": False}]

        try:
            # Fetch current full configuration to preserve other settings
            current_config = await asyncio.to_thread(self.proxy_client.get_config)
            if not current_config or not isinstance(current_config, dict):
                logger.error("Failed to fetch valid proxy config, aborting switch.")
                return

            current_config["pools"] = pools

            # Execute update via Proxy Client with the full configuration
            await asyncio.to_thread(self.proxy_client.update_config, current_config)

            # Update state manager with the new active mode
            final_label = state_label if state_label else mode
            await asyncio.to_thread(self.state_manager.update_xvb_stats, mode=final_label)
            logger.info(f"Switched Proxy to mode: {mode} (Label: {final_label})")
        except Exception as e:
            logger.error(f"Failed to switch proxy mode: {e}")

    def get_decision(
        self, current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares, advance=True
    ):
        """
        Evaluates the current mining state to determine the next operation mode.

        The donated fraction is held in ``self.donation_fraction`` and steered by a
        closed-loop calibration on XvB's reported 1h average (see
        ``_advance_controller``). This method reads that state and turns it into a
        concrete time-slice, applying the VIP/PPLNS reserve and the dwell rules.

        Args:
            current_hr (float): Current real-time (10s) hashrate.
            stable_hr (float): Stable (15m) hashrate for tier selection.
            p2pool_stats (dict): Local P2Pool stats (pplns_window, difficulty).
            p2p_stats (dict): P2P network stats (pool type detection).
            xvb_stats (dict): XvB API stats (avg_1h, avg_24h, fail_count).
            shares (list): Recent shares with timestamps.
            advance (bool): Advance the calibration loop this call. True from the
                main per-cycle loop; False from _smart_sleep, which only re-reads.

        Returns:
            tuple: (Mode String ["P2POOL"|"XVB"|"SPLIT"], Duration in ms)
        """
        # Feature Flag: Check if XvB switching is globally disabled
        if not ENABLE_XVB:
            return "P2POOL", 0

        # Constraint: Enforce P2Pool mode if no shares have been found recently.
        # This uses the same logic as the dashboard UI to count shares within the PPLNS window.
        pool_type = p2p_stats.get("type", "Main")
        pplns_window = p2pool_stats.get("pplns_window", DEFAULT_PPLNS_WINDOW)
        block_time = pplns_block_time(pool_type)
        window_duration = pplns_window * block_time
        shares_in_window_count = shares_in_pplns_window(shares, pplns_window, block_time)

        if shares_in_window_count == 0:
            logger.info(
                f"Decision Strategy: Force P2POOL (Zero shares in PPLNS window of {window_duration}s)"
            )
            return "P2POOL", 0

        # Constraint: Fallback to P2Pool if XvB endpoint failures exceed threshold.
        fail_count = xvb_stats.get("fail_count", 0)
        if fail_count >= 3:
            logger.warning(
                f"Decision Strategy: Force P2POOL (Excessive XvB failures: {fail_count})"
            )
            return "P2POOL", 0

        # Highest tier we can sustain, capped by the configured donation level.
        # Uses STABLE hashrate so the target doesn't jump with short-term variance.
        target_hr = self._get_target_donation_hr(stable_hr)

        # If no tier qualifies (can't sustain even the lowest), stay on P2Pool.
        if target_hr == 0:
            return "P2POOL", 0

        # Cap the donated fraction so p2pool keeps finding shares (VIP status).
        max_fraction = self._max_donation_fraction(current_hr, window_duration, p2pool_stats)
        avg_1h = xvb_stats.get("avg_1h", 0)
        avg_24h = xvb_stats.get("avg_24h", 0)

        # Advance the calibration loop once per real cycle (not during _smart_sleep).
        # But never steer off a stale read (#311): if the xmrvsbeast.com fetch has gone
        # quiet, avg_1h is frozen and stepping the loop would wind the fraction up
        # against a target we can't refresh. Hold the last split until a fresh read lands.
        if advance:
            if self._stats_are_stale(xvb_stats):
                if self._stats_age(xvb_stats) > XVB_STALE_DECAY_AFTER_S:
                    # Prolonged outage: the hold has run long enough that donating blind is
                    # the bigger risk (over-donation if staleness began mid-ramp, #70). Bleed
                    # the held fraction toward 0 — a fresh read below resumes normal control.
                    before = self.donation_fraction or 0.0
                    decayed = before * XVB_STALE_DECAY_FACTOR
                    self.donation_fraction = decayed if decayed >= XVB_STALE_DECAY_FLOOR else 0.0
                    logger.warning(
                        "XvB stats stale >%.0fs (fetch age %.0fs): decaying donation fraction "
                        "%.3f -> %.3f toward 0 — not donating blind through a prolonged outage",
                        XVB_STALE_DECAY_AFTER_S,
                        self._stats_age(xvb_stats),
                        before,
                        self.donation_fraction,
                    )
                else:
                    logger.warning(
                        "XvB stats stale (no fetch in >%.0fs): holding donation fraction at %.3f "
                        "(frozen 1h %.0f)",
                        XVB_STATS_STALE_AFTER_S,
                        self.donation_fraction or 0.0,
                        avg_1h,
                    )
            else:
                self._record_avg1h_sample(xvb_stats)
                self._advance_controller(current_hr, target_hr, avg_1h, max_fraction)

        fraction = min(self.donation_fraction or 0.0, max_fraction)
        needed_time_ms = self._fraction_to_ms(fraction)
        if needed_time_ms <= 0:
            return "P2POOL", 0

        # Enforce the minimum dwell so a slice is long enough to submit shares.
        if needed_time_ms < XVB_MIN_TIME_SEND_MS:
            needed_time_ms = XVB_MIN_TIME_SEND_MS

        # If the P2Pool remainder would be tiny (< 30s), commit the whole cycle to
        # XvB to avoid inefficient short switches.
        if (XVB_TIME_ALGO_MS - needed_time_ms) < 30000:
            needed_time_ms = XVB_TIME_ALGO_MS

        # The decision log is what a live soak watches converge: keep target and the
        # credited 1h/24h averages on one line, plus the instantaneous donated rate
        # (fraction * current hashrate) — the gap between "inst" and "1h/24h" is the
        # routed-vs-credited gap, the crux of any over-donation diagnosis (#423).
        if needed_time_ms >= XVB_TIME_ALGO_MS:
            logger.info(
                f"Decision: Full XVB cycle (inst ~{current_hr:.0f} H/s; "
                f"target {target_hr:.0f}; 1h {avg_1h:.0f} / 24h {avg_24h:.0f})"
            )
            return "XVB", XVB_TIME_ALGO_MS

        logger.info(
            f"Decision: Split ({needed_time_ms}ms to XvB; frac {fraction:.3f}; "
            f"inst ~{fraction * current_hr:.0f} H/s; "
            f"target {target_hr:.0f}; 1h {avg_1h:.0f} / 24h {avg_24h:.0f})"
        )
        return "SPLIT", int(needed_time_ms)

    def _get_target_donation_hr(self, stable_hr):
        """
        Resolves the donation tier threshold to target for the given (stable)
        hashrate. "auto" picks the highest sustainable tier; an explicit tier is
        honored as-is (not downgraded). Returns 0 to donate nothing.
        """
        tiers = self.state_manager.get_tiers()
        target, _ = resolve_target_threshold(
            tiers, stable_hr, self.donation_level, self.max_donation_fraction
        )
        return target

    def _stats_are_stale(self, xvb_stats):
        """A stale XvB read freezes ``avg_1h`` (#311); holding the split beats steering
        off a frozen number. Shared with the dashboard via ``xvb_stats_are_stale`` so
        the controller and the UI agree on staleness. Cold start (no fetch yet) is NOT
        stale — the feedforward ramp must be left to seed and climb to tier."""
        return xvb_stats_are_stale(xvb_stats)

    def _stats_age(self, xvb_stats):
        """Seconds since the last genuine XvB fetch (``last_update``, #136). 0.0 when we've
        never fetched (cold start) — the decay grace only fires on a real, aged fetch."""
        last_update = (xvb_stats or {}).get("last_update", 0) or 0
        return time.time() - last_update if last_update else 0.0

    def _record_avg1h_sample(self, xvb_stats):
        """See ``steering_projection.record_avg1h_sample``."""
        self._avg1h_trend = record_avg1h_sample(self._avg1h_trend, xvb_stats)

    def _projected_avg_1h(self, avg_1h):
        """See ``steering_projection.projected_avg_1h``."""
        return projected_avg_1h(self._avg1h_trend, avg_1h, XVB_PROJECTION_HORIZON_S, logger)

    def _reference_hr(self, target_hr):
        """See ``steering_projection.reference_hr``."""
        return reference_hr(target_hr, self.maint_margin_pct, self.maint_margin_abs_cap)

    def _won_round_live(self, now=None):
        """See ``steering_projection.won_round_live``."""
        return won_round_live(self.state_manager, XVB_WIN_ROUND_HOLD_S, now, logger)

    def _max_donation_fraction(self, current_hr, window_duration, p2pool_stats):
        """See ``steering_projection.max_donation_fraction``."""
        return max_donation_fraction(
            current_hr,
            window_duration,
            p2pool_stats,
            self.p2pool_reserve_factor,
            self.max_donation_fraction,
        )

    def _advance_controller(self, current_hr, target_hr, avg_1h, max_fraction):
        """
        One step of the closed-loop calibration. Nudges the donated fraction so
        XvB's *reported* 1h average tracks the reference (tier + cushion):

            fraction += gain * (reference - avg_1h) / current_hr

        Because it steers off XvB's authoritative number rather than assuming
        ``credited == fraction * current_hr``, it holds the tier no matter how XvB
        scales our donation. The number it steers off is the protective projection
        (``_projected_avg_1h``): the measured 1h average, lowered — never raised —
        by its own recent trend, so a credited decay is answered before it reaches
        the round minimum instead of after — and it can't wind up: the gain is small and the
        fraction is clamped to ``[0, max_fraction]`` (the VIP reserve), so a
        still-ramping or stale 1h read can only drift it slowly within bounds.

        While a won raffle round may still be live (``_won_round_live``), downward
        steps are skipped so the controller never helps the 1h average sag through
        the round minimum (#769). Upward steps and the clamp still apply.
        """
        if current_hr <= 0:
            return

        # Seed the closed-loop state on the first real cycle — warm if we can, cold otherwise.
        if self.donation_fraction is None:
            self.donation_fraction = self._seed_donation_fraction(
                target_hr, current_hr, max_fraction
            )
            return

        error = self._reference_hr(target_hr) - self._projected_avg_1h(avg_1h)
        step = self.control_gain * error / current_hr
        if step < 0 and self._won_round_live():
            # A won round is (possibly) live: easing off now is how the credited 1h
            # average sags through the round minimum and forfeits the round (#769).
            # Hold the fraction; normal steering resumes once the hold window passes.
            logger.info(
                "Won raffle round may still be live: holding donation fraction at "
                f"{self.donation_fraction:.3f} instead of easing off"
            )
            return
        self.donation_fraction += step
        self.donation_fraction = max(0.0, min(self.donation_fraction, max_fraction))

    def _seed_donation_fraction(self, target_hr, current_hr, max_fraction):
        """The starting donated fraction for the closed loop, warm when we can prove it (#249).

        Precedence, highest first — each clamped to the VIP reserve (``max_fraction``):

        1. **This host's own persisted commanded fraction.** Once the controller has steered and
           persisted a non-zero fraction, a plain process restart resumes from it rather than
           re-ramping cold. It also wins over standby: a stack that has been authoritative owns its
           state, so a stale standby from a since-departed primary can't override it.
        2. **Standby state pulled from the primary** (backup failover). The first time a backup
           actually donates — its workers just failed over — it adopts the primary's last-known
           commanded fraction so the split resumes warm instead of restarting from zero (the whole
           point of #249). While idle the backup never steers, so its own persisted fraction stays
           0.0 and this branch is what fires at handover.
        3. **Feedforward estimate** (cold start). A fresh install with no history and no standby —
           the original behaviour, converging from a sane point via the closed loop.
        """
        feedforward = min(self._reference_hr(target_hr) / current_hr, max_fraction)

        own = (self.state_manager.get_xvb_stats() or {}).get("commanded_fraction", 0.0) or 0.0
        if own > 0:
            return min(own, max_fraction)

        standby = self.state_manager.get_xvb_standby() or {}
        standby_fraction = standby.get("commanded_fraction", 0.0) or 0.0
        if standby_fraction > 0:
            logger.info(
                "Warm-resume: adopting primary's standby donation fraction %.3f on failover "
                "(#249) instead of cold-seeding %.3f",
                standby_fraction,
                feedforward,
            )
            return min(standby_fraction, max_fraction)

        return feedforward

    def _fraction_to_ms(self, fraction):
        """Convert a donated fraction of the cycle to a slice length (ms), adding
        the fixed switch/ramp-up overhead. Returns 0 for a non-positive fraction."""
        if fraction <= 0:
            return 0
        return math.ceil(fraction * XVB_TIME_ALGO_MS + XVB_SWITCH_OVERHEAD_MS)

    @staticmethod
    def _routed_fraction(decision, xvb_duration_ms):
        """Fraction of this cycle actually routed to XvB, for the routed-vs-credited
        instrumentation: 0 on p2pool, 1 on a full XvB cycle, the time-slice on SPLIT."""
        if decision == "XVB":
            return 1.0
        if decision == "SPLIT":
            return xvb_duration_ms / XVB_TIME_ALGO_MS
        return 0.0

    def _dwell_should_end(
        self, held_decision, current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares
    ):
        """
        Whether a p2pool dwell should end early. Re-runs the decision WITHOUT
        advancing the calibration loop and ends the dwell only when it *changed*
        from the decision the dwell was started under, or when a fresh 1h average
        has slipped below the tier (catch-up — undershoot loses the tier, which is
        worse than waste).

        Comparing against ``held_decision`` is the #423 fix. The old test —
        "would we donate at all?" (``decision in ("XVB", "SPLIT")``) — is a
        tautology during a SPLIT remainder: the fraction is static while
        ``advance=False``, so the recomputed decision is SPLIT by construction and
        every remainder collapsed to a single check tick. The actuated donation
        duty became slice/(slice + tick) instead of slice/cycle — an order of
        magnitude above the commanded fraction at small fractions — and the
        controller could not unwind it (its command was already near 0). That is
        the sustained credited overshoot of #423.
        """
        decision, _ = self.get_decision(
            current_hr,
            stable_hr,
            p2pool_stats,
            p2p_stats,
            xvb_stats,
            shares,
            advance=False,
        )
        # The "under tier -> catch up early" override acts directly on avg_1h,
        # so suppress it when the read is stale (#311): a frozen below-tier
        # number would otherwise cut every p2pool dwell short and drift the
        # effective split far past the computed fraction. A *changed* decision
        # still ends the dwell — only the avg-driven override pauses.
        target_hr = self._get_target_donation_hr(stable_hr)
        # Catch up only toward what the donation cap allows (#898). Against an explicit target
        # the fleet cannot sustain, the raw target comparison reads avg_1h as permanently
        # "under tier", ends every p2pool dwell at its first check tick, and the actuated
        # donation pins near 100% of allowed time — the cap never binds (measured live:
        # ~94% of the fleet routed under a 0.65 cap). The achievable donation is the ceiling
        # worth catching up to; beyond it, cutting dwells short only burns the p2pool side.
        achievable_hr = min(target_hr, stable_hr * self.max_donation_fraction)
        under_tier = (
            not self._stats_are_stale(xvb_stats)
            and achievable_hr > 0
            and xvb_stats.get("avg_1h", 0) < achievable_hr
        )
        return decision != held_decision or under_tier

    async def _smart_sleep(self, duration_sec, check_interval_sec=None, held_decision="P2POOL"):
        """
        Sleep through a p2pool dwell in chunks, re-running the decision each chunk.
        Returns early if the decision changed from ``held_decision`` (hashrate
        dropped, a constraint tripped) or a trailing average fell below tier, so
        the next cycle reacts in seconds instead of waiting out the full window.
        Uses only cached state — no extra external API calls.

        ``held_decision`` names the decision this dwell belongs to: "P2POOL" for a
        full no-donation cycle, "SPLIT" for the p2pool remainder of a split cycle
        (which must run its course, or the actuated donation exceeds the commanded
        fraction — #423).
        """
        if check_interval_sec is None:
            check_interval_sec = UPDATE_INTERVAL

        elapsed = 0
        while elapsed < duration_sec:
            tick = min(check_interval_sec, duration_sec - elapsed)
            await asyncio.sleep(tick)
            elapsed += tick

            try:
                latest = self.data_service.latest_data
                stable_hr = latest.get("total_live_h15", 0) or latest.get("total_live_h10", 0)
                current_hr = latest.get("total_live_h10", 0) or stable_hr
                xvb_stats = self.state_manager.get_xvb_stats()
                shares = latest.get("shares", [])
                p2pool_stats = latest.get("pool", {}).get("pool", {})
                p2p_stats = latest.get("pool", {}).get("p2p", {})

                if self._dwell_should_end(
                    held_decision, current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares
                ):
                    logger.info(
                        "Smart-sleep: donation target needs attention — ending P2Pool dwell early."
                    )
                    return
            except Exception as e:
                logger.debug(f"Smart-sleep check error: {e}")

    async def run(self):
        """
        Periodic task to execute the mining strategy algorithm.
        Determines the optimal mining mode and manages worker switching cycles.
        """
        logger.info("Service Started: Algorithm Control Loop")
        await asyncio.sleep(5)

        while True:
            try:
                # While workers are rejected (a node is down, Issue #31) the proxy is
                # stopped — don't try to reconfigure its pools; just wait for recovery.
                if getattr(self.data_service, "workers_rejected", False):
                    await asyncio.sleep(UPDATE_INTERVAL)
                    continue

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
                decision, xvb_duration = self.get_decision(
                    current_hr, stable_hr, p2pool_stats, p2p_stats, xvb_stats, shares
                )

                # Record the fraction of this cycle actually routed to XvB so the
                # dashboard can show routed-vs-credited (the live credit factor), and persist
                # the controller's own commanded fraction so a restart / backup failover resumes
                # warm rather than re-seeding cold (#249).
                await asyncio.to_thread(
                    self.state_manager.update_xvb_stats,
                    donation_fraction=self._routed_fraction(decision, xvb_duration),
                    commanded_fraction=self.donation_fraction or 0.0,
                )

                if decision == "P2POOL":
                    await self.switch_miners("P2POOL", state_label="P2POOL")
                    # Poll during the dwell so a hashrate/average drop is caught
                    # within seconds instead of after the full cycle.
                    await self._smart_sleep(XVB_TIME_ALGO_MS / 1000)

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
                        # held_decision="SPLIT": the remainder belongs to the split we
                        # just decided — a re-read that still says SPLIT must NOT end
                        # it (#423); only a changed decision or under-tier does.
                        await self._smart_sleep(remainder, held_decision="SPLIT")

            except Exception as e:
                logger.error(f"Algorithm Error: {e}")
                await asyncio.sleep(10)
