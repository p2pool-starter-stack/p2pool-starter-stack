# AlgoService's closed-loop steering helpers (extracted to keep algo_service.py under its
# file-budget ceiling, #1285): the reference target, the live-won-round hold, the VIP/PPLNS
# donation-fraction reserve, and the protective trend projection. Each function here is
# called from a same-named thin wrapper method on AlgoService, which supplies the
# per-instance/config state these need.
import time


def reference_hr(target_hr, maint_margin_pct, maint_margin_abs_cap):
    """Hashrate the controller holds XvB's 1h average at: the tier threshold
    plus a noise-covering cushion (capped in absolute H/s). The raffle
    terminates a win if the 1h average dips below the round minimum, so the
    cushion must clear the credited average's measured noise (#769) — while
    the cap keeps a flat percentage from wasting p2pool hashrate at high tiers."""
    return target_hr + min(target_hr * maint_margin_pct, maint_margin_abs_cap)


def won_round_live(state_manager, hold_s, now=None, logger=None) -> bool:
    """Whether a won raffle round may still be running: any recorded win newer
    than ``hold_s``. Steering the donation down during a live won round can sag
    the credited 1h average through the round minimum and terminate the round
    (#769), so ``AlgoService._advance_controller`` skips downward steps while
    this holds. Fails open to False (normal steering) on any read error — the
    hold is a yield optimization, never a safety path."""
    try:
        since = (now if now is not None else time.time()) - hold_s
        wins = state_manager.get_raffle_wins(since=since)
    except Exception as e:
        if logger is not None:
            logger.debug(f"Raffle-win read failed; steering normally: {e}")
        return False
    return isinstance(wins, list) and len(wins) > 0


def max_donation_fraction(current_hr, window_duration, p2pool_stats, reserve_factor, max_fraction):
    """
    Largest fraction of the cycle we may donate while keeping p2pool eligible
    for "VIP" — i.e. still finding shares within the PPLNS window. A miner that
    wins while non-VIP is skipped and gains a fail, so this reserve is a hard
    constraint, not a preference.

    p2pool needs ~``sidechain_difficulty / window_seconds`` H/s to land one
    expected share per window; we reserve ``reserve_factor`` times that for
    headroom against variance. When difficulty is unknown (stats not ready),
    fall back to the flat hard cap (``max_fraction``).
    """
    difficulty = p2pool_stats.get("difficulty", 0) or 0
    if current_hr <= 0 or difficulty <= 0 or window_duration <= 0:
        return max_fraction

    min_p2pool_hr = (difficulty / window_duration) * reserve_factor
    sparable_fraction = max(0.0, 1.0 - (min_p2pool_hr / current_hr))
    return min(sparable_fraction, max_fraction)


# Protective projection of the credited 1h average (see XVB_PROJECTION_HORIZON_S in config.py).
# The trend is measured across genuine fetches only, needs at least MIN_SPAN of history before
# it says anything (two adjacent noisy samples make a wild slope), forgets samples older than
# MAX_LOOKBACK (the trend that matters is the fresh one; a long tail of pre-decay samples
# dilutes it), and may lower the effective reading by at most MAX_DROP_FRACTION of the measured
# value (a pathological sample must not slam the loop).
XVB_PROJECTION_MIN_SPAN_S = 600.0
XVB_PROJECTION_MAX_LOOKBACK_S = 1500.0
XVB_PROJECTION_MAX_DROP_FRACTION = 0.25


def record_avg1h_sample(trend, xvb_stats):
    """Remember (fetch time, avg_1h) for the trend projection. Only a genuine
    fetch appends (``last_update`` moved — the same signal the staleness guard
    trusts), so a frozen read repeated across cycles adds nothing."""
    last_update = (xvb_stats or {}).get("last_update", 0) or 0
    if not last_update:
        return trend
    if trend and trend[-1][0] >= last_update:
        return trend
    trend.append((float(last_update), float(xvb_stats.get("avg_1h", 0) or 0)))
    cutoff = last_update - XVB_PROJECTION_MAX_LOOKBACK_S
    return [(t, v) for t, v in trend if t >= cutoff]


def projected_avg_1h(trend, avg_1h, horizon_s, logger=None):
    """Where the credited 1h average is HEADING, never above where it IS.

    The reactive loop steers off a reading that lags the routed rate by up to
    the whole rolling window; at a margin-riding equilibrium that lag is how a
    decaying credited average sags through a live round's minimum before the
    loop reacts. Extrapolate the measured trend one horizon forward and steer
    off ``min(measured, projected)`` — a falling trend tightens steering early,
    a rising trend changes nothing (never slacken on a forecast). Needs a real
    baseline (span >= the minimum) and caps the drop, so noise cannot slam the
    loop; disabled entirely when the horizon is 0."""
    if horizon_s <= 0 or len(trend) < 2:
        return avg_1h
    t_new, v_new = trend[-1]
    t_old, v_old = trend[0]
    span = t_new - t_old
    if span < XVB_PROJECTION_MIN_SPAN_S:
        return avg_1h
    slope = (v_new - v_old) / span
    projected = avg_1h + slope * horizon_s
    floor = avg_1h * (1.0 - XVB_PROJECTION_MAX_DROP_FRACTION)
    effective = max(min(avg_1h, projected), floor)
    if effective < avg_1h and logger is not None:
        logger.info(
            "Credited 1h average trending down: steering off projected "
            f"{effective:.0f} H/s instead of measured {avg_1h:.0f} H/s"
        )
    return effective
