"""Typed metrics/domain layer (Issue #61).

``build_metrics`` turns the untyped ``latest_data`` snapshot (plus a little ``state_manager``
state) into a frozen ``Metrics`` dataclass of **computed, unformatted domain values** —
effective hashrate, P2Pool/XvB averages, XvB tiers, shares-in-PPLNS-window, worker counts,
per-node sync/down state, and the raw pool/network figures a payout calculator needs.

This is the single place those values are derived. The web view layer formats display strings
*from* ``Metrics`` (format at the edge); other consumers — e.g. the planned Telegram notifier
(#45) and XvB/P2Pool calculator (#12) — read the same ``Metrics`` instead of re-deriving from
the raw dict or scraping rendered HTML. Nothing here formats or emits markup.
"""

import time
from dataclasses import dataclass

from mining_dashboard.config.config import (
    ENABLE_XVB,
    LOCAL_MONERO_HOST,
    MONERO_NODE_HOST,
    MONERO_PRUNE,
    XVB_DONATION_LEVEL,
    XVB_MAX_DONATION_FRACTION,
)
from mining_dashboard.helper.utils import (
    DEFAULT_PPLNS_WINDOW,
    get_tier_info,
    pplns_block_time,
    resolve_target_threshold,
    shares_in_pplns_window,
    xvb_stats_are_stale,
)


@dataclass(frozen=True)
class SyncMetric:
    """One chain's sync/health state (Issues #31, #51)."""

    percent: int
    current: int
    target: int
    remaining: int
    has_target: bool  # a real target height is known (vs. still discovering it)
    done: bool  # fully synced
    down: bool  # debounced unreachable (node-health monitor)


@dataclass(frozen=True)
class Metrics:
    """Computed dashboard domain values. All hashrates are raw H/s; no display formatting."""

    # Effective hashrate (H/s).
    total_h15: float
    p2pool_1h: float
    p2pool_24h: float
    xvb_1h: float  # credited (XvB API avg_1h) — controller input + Advanced card only
    xvb_24h: float  # credited (XvB API avg_24h)
    xvb_routed_1h: float  # routed (proxy v_xvb, time-weighted 1h) — header / Simple / chart (#156)
    xvb_routed_24h: float  # routed (proxy v_xvb, time-weighted 24h)
    stratum_h15: float
    stratum_h1h: float
    stratum_h24h: float
    # Mode + XvB tiers.
    mode: str
    xvb_enabled: bool
    current_tier: str
    target_tier: str
    target_threshold: float
    target_sustainable: bool
    low_hr_warning: bool  # an explicit tier was chosen that the hashrate can't sustain
    xvb_fail_count: int
    xvb_last_update: float  # epoch seconds of the last XvB stats fetch
    # Workers.
    workers_online: int
    workers_total: int
    # Shares / PPLNS.
    shares_in_window: int
    pplns_window: int  # blocks
    block_time: int  # seconds per sidechain block
    # Pool / network (raw figures; e.g. payout-calculator inputs, #12).
    pool_type: str
    pool_hashrate: float
    pool_difficulty: float
    network_difficulty: float
    network_height: int
    # Sync / node health.
    global_syncing: bool
    monero: SyncMetric
    tari: SyncMetric
    monero_mode: str  # "Pruned" / "Full" / "Unknown"
    tari_mining: bool  # Tari merge-mining active
    # XvB raffle registration (#263). Defaulted so direct Metrics(...) constructors needn't set them.
    xvb_registered_at: float = 0.0  # epoch secs of last successful registration; 0.0 = never
    xvb_registration_state: str = ""  # ""|registered|invalid|failing — drives the badge
    # True when the xmrvsbeast.com fetch has gone quiet (#311) — credited 1h/24h are frozen,
    # so the UI greys them and the controller holds its split. Same predicate as the controller.
    xvb_stale: bool = False


def build_metrics(latest_data, state_mgr, history=None):
    """Derive :class:`Metrics` from the aggregated snapshot and shared state.

    ``history`` (the hashrate DB history) is fetched from ``state_mgr`` when not supplied —
    callers that already hold it (e.g. the dashboard, which also charts it) can pass it to
    avoid a second read.
    """
    data = latest_data or {}
    if history is None:
        history = state_mgr.get_history()
    xvb_stats = state_mgr.get_xvb_stats() or {}
    tiers = state_mgr.get_tiers()

    mode = xvb_stats.get("current_mode", "P2POOL")
    if not ENABLE_XVB:
        mode = "P2POOL (XvB Disabled)"

    total_h15 = data.get("total_live_h15", 0) or 0
    # Credited — XvB's own verdict (avg_1h/24h). The controller steers off this (#9/#70) and the
    # Advanced card shows it next to routed so the credit factor is visible; nowhere else (#156).
    xvb_1h = xvb_stats.get("avg_1h", 0) or 0
    xvb_24h = xvb_stats.get("avg_24h", 0) or 0
    # Routed — what the proxy ACTUALLY sent to XvB, time-weighted from our own DB history (v_xvb),
    # mirroring P2Pool's v_p2pool averaging so the two sum to total. This is the at-a-glance display
    # figure (header / Simple / chart), NOT the controller's intended donation_fraction (#156).
    xvb_routed_1h = _avg_xvb_over_window(history, 3600)
    xvb_routed_24h = _avg_xvb_over_window(history, 86400)

    # P2Pool 1h/24h from our own DB history (time-weighted v_p2pool), not p2pool's noisy
    # stratum estimate or a total-minus-XvB subtraction (Issue #27).
    p2pool_1h = _avg_p2pool_over_window(history, 3600)
    p2pool_24h = _avg_p2pool_over_window(history, 86400)

    # The XvB raffle qualifies a tier on BOTH the 1h and 24h credited average, and terminates a win
    # if the 1h average drops below the round minimum — so Current Tier is the one cleared by the
    # LOWER of the two (#157). On a hashrate drop the 1h falls first, so this surfaces the tier the
    # miner has effectively already lost (and whose win would terminate) right when it matters; on
    # ramp-up min == 24h, the conservative read, so behavior there is unchanged.
    current_tier, _ = get_tier_info(min(xvb_1h, xvb_24h), tiers)
    target_threshold, sustainable = resolve_target_threshold(
        tiers, total_h15, XVB_DONATION_LEVEL, XVB_MAX_DONATION_FRACTION
    )
    target_tier, _ = get_tier_info(target_threshold, tiers)
    low_hr_warning = bool(
        ENABLE_XVB
        and XVB_DONATION_LEVEL not in ("auto", "highest")
        and target_threshold > 0
        and not sustainable
    )
    if not ENABLE_XVB:
        current_tier = "Disabled"
        target_tier = "Disabled"
        low_hr_warning = False

    stratum = data.get("stratum", {})
    pool_stats = data.get("pool", {})
    p2p = pool_stats.get("p2p", {})
    local_pool = pool_stats.get("pool", {})
    network = data.get("network", {})

    pool_type = p2p.get("type", "Main")
    block_time = pplns_block_time(pool_type)
    pplns_window = local_pool.get("pplns_window", DEFAULT_PPLNS_WINDOW)
    shares_in_window = shares_in_pplns_window(data.get("shares", []), pplns_window, block_time)

    workers = data.get("workers", [])
    workers_online = sum(1 for w in workers if w.get("status") == "online")

    return Metrics(
        total_h15=total_h15,
        p2pool_1h=p2pool_1h,
        p2pool_24h=p2pool_24h,
        xvb_1h=xvb_1h,
        xvb_24h=xvb_24h,
        xvb_routed_1h=xvb_routed_1h,
        xvb_routed_24h=xvb_routed_24h,
        stratum_h15=stratum.get("hashrate_15m", 0) or 0,
        stratum_h1h=stratum.get("hashrate_1h", 0) or 0,
        stratum_h24h=stratum.get("hashrate_24h", 0) or 0,
        mode=mode,
        xvb_enabled=bool(ENABLE_XVB),
        current_tier=current_tier,
        target_tier=target_tier,
        target_threshold=target_threshold,
        target_sustainable=sustainable,
        low_hr_warning=low_hr_warning,
        xvb_fail_count=xvb_stats.get("fail_count", 0) or 0,
        xvb_last_update=xvb_stats.get("last_update", 0) or 0,
        workers_online=workers_online,
        workers_total=len(workers),
        shares_in_window=shares_in_window,
        pplns_window=pplns_window,
        block_time=block_time,
        pool_type=pool_type,
        pool_hashrate=local_pool.get("hashrate", 0) or 0,
        pool_difficulty=local_pool.get("difficulty", 0) or 0,
        network_difficulty=network.get("difficulty", 0) or 0,
        network_height=network.get("height", 0) or 0,
        global_syncing=bool(data.get("global_sync", False)),
        monero=_sync_metric(data.get("monero_sync", {})),
        tari=_sync_metric(data.get("tari_sync", {})),
        monero_mode=_monero_mode(),
        tari_mining=bool(data.get("tari", {}).get("active", False)),
        xvb_registered_at=xvb_stats.get("registered_at", 0) or 0,
        xvb_registration_state=xvb_stats.get("registration_state", "") or "",
        xvb_stale=bool(ENABLE_XVB and xvb_stats_are_stale(xvb_stats)),
    )


def _avg_p2pool_over_window(history, window_seconds):
    """Time-weighted P2Pool hashrate over the trailing window, from DB history.

    Averages the per-sample ``v_p2pool`` for samples within the window. Samples are written at
    a fixed cadence, so a simple mean approximates a time-weighted average. Mirrors the chart's
    legacy-data fallback: rows predating the p2pool/xvb split (v_p2pool == v_xvb == 0 but
    v > 0) count as P2Pool. (Issue #27)
    """
    if not history:
        return 0.0

    cutoff = time.time() - window_seconds
    total = 0.0
    count = 0
    for x in history:
        if x.get("timestamp", 0) < cutoff:
            continue
        vp = x.get("v_p2pool", 0) or 0
        vx = x.get("v_xvb", 0) or 0
        v = x.get("v", 0) or 0
        if vp == 0 and vx == 0 and v > 0:
            vp = v
        total += vp
        count += 1

    return total / count if count else 0.0


def _avg_xvb_over_window(history, window_seconds):
    """Time-weighted XvB *routed* hashrate over the trailing window, from DB history (#156).

    Mirrors :func:`_avg_p2pool_over_window` but sums ``v_xvb`` — what the proxy actually routed to
    XvB per sample — over the same in-window samples, so XvB-routed + P2Pool-routed average to the
    total. No legacy fallback: rows predating the p2pool/xvb split count as P2Pool (their ``v_xvb``
    is 0), which correctly reads XvB-routed as 0 for that old data.
    """
    if not history:
        return 0.0

    cutoff = time.time() - window_seconds
    total = 0.0
    count = 0
    for x in history:
        if x.get("timestamp", 0) < cutoff:
            continue
        total += x.get("v_xvb", 0) or 0
        count += 1

    return total / count if count else 0.0


def _sync_metric(sync):
    """Build a :class:`SyncMetric` from a chain's raw ``*_sync`` dict."""
    percent = sync.get("percent", 0) or 0
    current = sync.get("current", 0) or 0
    target = sync.get("target", 0) or 0
    has_target = target > 0
    return SyncMetric(
        percent=percent,
        current=current,
        target=target,
        remaining=target - current,
        has_target=has_target,
        # "done" = the chain reports itself caught up. A synced monerod returns target_height: 0, so
        # the percent>=100 path never fires for it — which left a fully-synced node stuck at "loading"
        # (found in the #180 live validation). Trust the authoritative reachable + not-is_syncing
        # signal too; Tari already reports current==target/percent=100, so it's unaffected.
        done=(sync.get("reachable", False) and not sync.get("is_syncing", True))
        or (has_target and percent >= 100),
        down=bool(sync.get("down", False)),
    )


def _monero_mode():
    """Monero node pruning mode (Issue #32). Only meaningful for a local node — a remote
    node's pruning state isn't something we probe, so it reads 'Unknown'.

    Only a local monerod's pruning state is knowable; the local bridge IP tracks the
    configurable subnet prefix (#180)."""
    if MONERO_NODE_HOST == LOCAL_MONERO_HOST:
        return "Pruned" if MONERO_PRUNE else "Full"
    return "Unknown"


def share_reject_pct(rows, window_sec, now=None):
    """Trailing reject rate (percent) from the per-poll share-health deltas (#116).

    ``rows`` are StateManager.get_share_stats() rows (per-interval deltas, ts-keyed). Sums the
    accepted/rejected deltas over the trailing ``window_sec`` and returns
    ``rejected / (accepted + rejected) * 100``, or ``None`` when the window has no submitted
    shares (proxy idle or held) — callers must not read that as 0% healthy."""
    cutoff = (now if now is not None else time.time()) - window_sec
    accepted = rejected = 0
    for r in rows:
        if r["ts"] >= cutoff:
            accepted += r.get("accepted", 0) or 0
            rejected += r.get("rejected", 0) or 0
    total = accepted + rejected
    return (rejected / total * 100) if total > 0 else None
