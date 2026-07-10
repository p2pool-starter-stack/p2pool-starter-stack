"""View layer for the dashboard: turn the computed :class:`Metrics` (plus a little passthrough
from ``latest_data``) into the structured ``/api/state`` payload the Preact client renders.

Separation of concerns (Issue #61): the *domain* values are computed once in
``service/metrics.py``; this layer only **formats at the edge** — display strings
(``"10.50 kH/s"``) and presentation tokens (``variant: "ok"``, ``level: "high"``) — and never
emits HTML. The client maps tokens to CSS classes and builds the DOM.

``build_state`` is the single assembly point and the contract the ``/api/state`` endpoint and
the client share; ``server.py`` stays pure transport.
"""

import bisect
import logging
import math
import os
import time

from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
    HASHRATE_WINDOW_COLUMNS,
    HASHRATE_WINDOWS,
    HOST_IP,
    LOW_RAM_GB,
    UPDATE_INTERVAL,
)
from mining_dashboard.helper.utils import (
    detect_host_ipv4,
    format_duration,
    format_hashrate,
    format_time_abs,
    is_ip_address,
)
from mining_dashboard.service.earnings import xmr_per_hs_day, xtm_per_hs_day
from mining_dashboard.service.egress import egress_posture_from_config, topology_from_config
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.version import resolve_version

logger = logging.getLogger("WebViews")

# Preset range -> window length in seconds. 'all'/unknown -> use the data's own extent.
_RANGE_SECONDS = {"1h": 3600, "24h": 86400, "1w": 604800, "1m": 2592000}

# Adaptive chart resolution (Issue #47). Point count and line smoothing are chosen from the
# *visible window duration*: a wide span is a smooth, high-level overview (fewer points, more
# curve smoothing); a short span keeps full 30s detail (choppier but accurate). The point count
# is capped near the canvas pixel width — more points than pixels just slows hit-testing.
# (limit_seconds, target_points); 0 target = send native resolution (no downsampling).
_POINT_TIERS = ((3600, 0), (21600, 360), (86400, 480), (604800, 600))
_MAX_CHART_POINTS = 700  # > 1w, and the hard ceiling (~1 point per canvas pixel)

# (limit_seconds, tension). Chart.js line tension = curve smoothing.
_TENSION_TIERS = ((3600, 0.0), (86400, 0.2), (604800, 0.35))
_MAX_TENSION = 0.4  # > 1w: smooth / high-level


def _target_points(duration_s):
    """Target chart-point count for a window of ``duration_s`` seconds (0 = native resolution)."""
    for limit, points in _POINT_TIERS:
        if duration_s <= limit:
            return points
    return _MAX_CHART_POINTS


def _chart_tension(duration_s):
    """Chart.js line tension (curve smoothing) for a window of ``duration_s`` seconds."""
    for limit, tension in _TENSION_TIERS:
        if duration_s <= limit:
            return tension
    return _MAX_TENSION


def parse_window(from_arg, to_arg):
    """Parse optional ``from``/``to`` query params (epoch seconds) into a ``(from, to)`` window,
    or ``None`` if absent or malformed. Defensive — any bad input falls back to ``None`` so the
    caller uses the preset ``range`` instead of erroring (Issue #47)."""
    if from_arg is None or to_arg is None:
        return None
    try:
        lo, hi = float(from_arg), float(to_arg)
    except (TypeError, ValueError):
        return None
    if not (math.isfinite(lo) and math.isfinite(hi)) or lo <= 0 or hi <= 0 or lo >= hi:
        return None
    return (lo, hi)


# A run of missing samples longer than this is drawn as a real break in the line rather than a
# segment spanning the outage (Issue #65). Adaptive: a multiple of the series' own median
# spacing (so it works for both live 30s samples and heavily downsampled long ranges), floored
# at a couple of sample intervals so ordinary jitter doesn't fragment the line.
_GAP_FACTOR = 3

# Pool/mode palette *tokens* -> CSS colour classes on the client (``.c-<token>``/``.bg-<token>``).
# The active pool is coloured, the inactive one muted (Issue #27).
_TOKEN_GREEN = "ok"  # P2Pool active  # noqa: S105 — CSS palette token, not a secret
_TOKEN_PURPLE = "purple"  # XvB active  # noqa: S105
_TOKEN_BLUE = "accent"  # split / neutral mode  # noqa: S105
_TOKEN_MUTED = "muted"  # inactive pool  # noqa: S105

_LOW_HR_TITLE = (
    "Your hashrate can't sustain the selected XvB donation tier; donation will fall short of it."
)

_NOT_ELIGIBLE_TITLE = (
    "You have no share in the P2Pool PPLNS window, so you're not eligible to collect "
    'an XvB raffle win (what XvB calls being a "VIP"). If you win a round you\'re '
    "skipped and take a fail (removed from the raffle after the 3rd) — regardless of "
    "your donation tier. Keep enough hashrate on P2Pool to keep landing shares."
)

# XvB raffle auto-registration status (#263).
_XVB_REGISTERED_TITLE = (
    "This wallet is auto-registered with the XMRvsBeast raffle. Re-registration runs periodically; "
    "no manual signup is needed."
)
_XVB_INVALID_TITLE = (
    "The XvB raffle endpoint rejected your wallet as invalid, so you won't be entered. The raffle "
    "needs a standard primary Monero address (starts with 4). Check MONERO_WALLET_ADDRESS."
)
_XVB_FAILING_TITLE = (
    "XvB raffle registration keeps failing despite a PPLNS share — the endpoint may be unreachable "
    "or erroring. Check the dashboard logs and the XvB egress (Tor) path."
)


def build_raffle_eligibility(metrics):
    """Raffle-eligibility status — are you set up to both WIN and COLLECT an XvB payout? (#158)

    Green "Yes" requires XvB to be on plus BOTH gates:
    - **In a donor tier** — your CREDITED donation (XvB's avg_1h *and* avg_24h, via ``current_tier``,
      which clears on the lower of the two) has reached at least the lowest donor threshold, so you
      qualify for a donor round; and
    - **A P2Pool PPLNS share** — XvB calls this being a "VIP"; without it a win is skipped and you
      take a fail, regardless of tier.

    Shows "N/A (XvB off)" when XvB is disabled — there's no raffle to be eligible for. This is
    intentionally stricter than XvB's bare "VIP = just a share" so a green Yes means a win is paid.
    """
    if not metrics.xvb_enabled:
        return {"applies": False, "eligible": False, "label": "N/A (XvB off)"}
    # current_tier is get_tier_info(min(credited_1h, credited_24h)); "None" => below the lowest tier.
    in_tier = metrics.current_tier not in ("None", "Disabled")
    eligible = in_tier and metrics.shares_in_window > 0
    return {"applies": True, "eligible": eligible, "label": "Yes" if eligible else "No"}


# --------------------------------------------------------------------------------------
# Chart series (Issue #65: positioned by real time, with outage gaps as breaks).
# --------------------------------------------------------------------------------------


def build_chart(
    history, shares, range_arg, window=None, avg_window=DEFAULT_HASHRATE_WINDOW, events=None
):
    """Build the Chart.js datasets from history. Each point carries its real timestamp as the
    x value (epoch ms) so a linear time axis spaces points to scale; runs of missing samples
    (outages) are split by a ``null`` break so the line doesn't connect across the gap.

    ``window`` is an optional ``(from, to)`` epoch-second pair (a manual zoom) that bounds both
    ends and overrides ``range_arg``. Point density and ``tension`` adapt to the visible window
    duration (Issue #47). ``avg_window`` (#168) selects which hashrate-averaging window's columns
    to plot (1m / 10m / 1h / 12h / 24h); 10m is the default headline series.

    Returns ``{"p2pool": [{x, y}], "xvb": [{x, y}], "shares": [{x, y, r, c}], "tension": float}``
    — the P2Pool/XvB series are stacked on the client (they sum to the total hashrate) and may
    contain ``{x, y: None}`` break markers, kept index-aligned across both series so stacking
    stays correct; ``shares`` is a sparse scatter (rendered un-stacked)."""
    filtered_history, filtered_shares = _filter_range(history, shares, range_arg, window)
    duration_s = _window_duration(filtered_history, range_arg, window)
    filtered_history = _downsample_history(filtered_history, duration_s)

    timestamps = [x["timestamp"] for x in filtered_history]
    gap_after = _gap_after_indices(timestamps)

    p2pool = []
    xvb = []
    for i, x in enumerate(filtered_history):
        vp, vx = _split_values(x, avg_window)
        x_ms = int(timestamps[i] * 1000)
        p2pool.append({"x": x_ms, "y": vp})
        xvb.append({"x": x_ms, "y": vx})
        if i in gap_after:
            mid_ms = int(((timestamps[i] + timestamps[i + 1]) / 2) * 1000)
            p2pool.append({"x": mid_ms, "y": None})
            xvb.append({"x": mid_ms, "y": None})

    return {
        "p2pool": p2pool,
        "xvb": xvb,
        "shares": _share_points(filtered_history, filtered_shares),
        "events": _event_points(_filter_events(events or [], range_arg, window)),
        "tension": _chart_tension(duration_s),
    }


def _filter_range(history, shares, range_arg, window=None):
    """Restrict history/shares to the selected window. A custom ``window`` (from, to) epoch
    seconds bounds both ends; otherwise the preset ``range`` bounds only the lower end (``all``
    keeps everything)."""
    if window is not None:
        lo, hi = window
        return (
            [x for x in history if lo <= x["timestamp"] <= hi],
            [s for s in shares if lo <= s["ts"] <= hi],
        )
    if range_arg == "all":
        return history, shares
    target_seconds = _RANGE_SECONDS.get(range_arg, 0)
    if target_seconds <= 0:
        return history, shares
    cutoff = time.time() - target_seconds
    return (
        [x for x in history if x["timestamp"] >= cutoff],
        [s for s in shares if s["ts"] >= cutoff],
    )


def _filter_events(events, range_arg, window=None):
    """Restrict degradation events (#99) to the selected window — same bounds as ``_filter_range``,
    but for the ``ts``-keyed events list."""
    if window is not None:
        lo, hi = window
        return [e for e in events if lo <= e["ts"] <= hi]
    if range_arg == "all":
        return events
    secs = _RANGE_SECONDS.get(range_arg, 0)
    if secs <= 0:
        return events
    cutoff = time.time() - secs
    return [e for e in events if e["ts"] >= cutoff]


def build_share_stats(share_stats, range_arg, window=None):
    """The persisted per-poll share-health deltas (#116) as chart-ready points, restricted to the
    selected range/window — same bounds as ``_filter_events`` — and bounded at
    ``_MAX_CHART_POINTS`` like the hashrate series (the default "all" range over the 30-day
    retention is ~86k rows, which /api/state would otherwise ship every poll). Each point is
    ``{x: ms epoch, a, r, i, e}`` (accepted/rejected/invalid/expired deltas for that interval).
    ``reject_pct_24h`` stays exact — it is computed from the raw rows, never this thinned series."""
    return [
        {
            "x": int(s["ts"] * 1000),
            "a": s.get("accepted", 0),
            "r": s.get("rejected", 0),
            "i": s.get("invalid", 0),
            "e": s.get("expired", 0),
        }
        for s in _downsample_share_stats(_filter_share_stats(share_stats, range_arg, window))
    ]


def _downsample_share_stats(rows, target=_MAX_CHART_POINTS):
    """Bucket the delta rows down to ``target`` points. Unlike ``_downsample_history`` (which
    averages a rate), the counts are per-interval DELTAS, so each bucket is **summed** — totals
    and the reject ratio survive thinning exactly. The bucket's mid-row timestamp positions the
    point, matching the hashrate downsampler."""
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in ("accepted", "rejected", "invalid", "expired"):
            bucket[col] = sum(r.get(col, 0) or 0 for r in chunk)
        out.append(bucket)
    return out


def _filter_share_stats(rows, range_arg, window=None):
    """Restrict share-stat deltas (#116) to the selected window — same bounds as
    ``_filter_events``, for the ``ts``-keyed delta rows."""
    if window is not None:
        lo, hi = window
        return [s for s in rows if lo <= s["ts"] <= hi]
    if range_arg == "all":
        return rows
    secs = _RANGE_SECONDS.get(range_arg, 0)
    if secs <= 0:
        return rows
    cutoff = time.time() - secs
    return [s for s in rows if s["ts"] >= cutoff]


def _window_reject_pct(rows, seconds):
    """Trailing reject rate over ``seconds`` from the delta series (#116), as a display string.
    "—" when no shares were submitted in the window (a 0% would read as falsely healthy)."""
    pct = share_reject_pct(rows, seconds)
    return "—" if pct is None else f"{pct:.2f}%"


def _window_duration(filtered_history, range_arg, window):
    """Seconds the chart currently spans — drives adaptive resolution/smoothing. From the
    window if zoomed, else the preset length, else (``all``/unknown) the actual data extent."""
    if window is not None:
        return max(0, window[1] - window[0])
    secs = _RANGE_SECONDS.get(range_arg, 0)
    if secs > 0:
        return secs
    if len(filtered_history) >= 2:
        return filtered_history[-1]["timestamp"] - filtered_history[0]["timestamp"]
    return 0


def _split_values(x, avg_window=DEFAULT_HASHRATE_WINDOW):
    """(p2pool, xvb) hashrate for a history row at the selected averaging window (#168).

    Defaults to 10m — the original headline series — which also keeps the legacy-data fallback
    (older rows stored only the un-split total ``v``). The other windows read their own columns,
    which are 0 on pre-#168 rows (per-window capture is forward-only)."""
    p_col, x_col = HASHRATE_WINDOW_COLUMNS.get(
        avg_window, HASHRATE_WINDOW_COLUMNS[DEFAULT_HASHRATE_WINDOW]
    )
    vp = x.get(p_col, 0) or 0
    vx = x.get(x_col, 0) or 0
    # The fallback only makes sense for the default window, where ``v`` is that window's total.
    if avg_window == DEFAULT_HASHRATE_WINDOW and vp == 0 and vx == 0:
        v = x.get("v", 0)
        if v > 0:
            vp = v
    return vp, vx


def canonical_window(avg_arg):
    """Validate an ``avg`` query param against the known windows (#168), falling back to the default
    for anything unknown or missing — a stale bookmark or bad input can't break the chart."""
    return avg_arg if avg_arg in HASHRATE_WINDOWS else DEFAULT_HASHRATE_WINDOW


def _gap_after_indices(timestamps):
    """Indices ``i`` after which the gap to ``i+1`` is large enough to be an outage break."""
    if len(timestamps) < 2:
        return set()
    deltas = [timestamps[i + 1] - timestamps[i] for i in range(len(timestamps) - 1)]
    median = sorted(deltas)[len(deltas) // 2]
    threshold = max(_GAP_FACTOR * median, 2 * UPDATE_INTERVAL)
    return {i for i, d in enumerate(deltas) if d > threshold}


# Value columns carried through downsampling: the legacy total ``v`` plus every per-window
# p2pool/xvb column (#168), derived from the window map so a newly-added averaging window is
# bucket-averaged automatically instead of being silently dropped. (Bug: the old downsampler kept
# only v/v_p2pool/v_xvb, so the 1m/1h/12h/24h Avg series went flat at 0 on any range wide enough to
# downsample — e.g. the 24h/1w/1mo ranges — while the default 10m window happened to survive.)
_DOWNSAMPLE_VALUE_COLUMNS = tuple(
    dict.fromkeys(("v",) + tuple(col for cols in HASHRATE_WINDOW_COLUMNS.values() for col in cols))
)


def _downsample_history(filtered_history, duration_s):
    """Bucket-averages history down to the duration's target point count (Issue #47). A target
    of 0, or a series already at/under target, is returned untouched — so short/zoomed-in
    windows keep their native 30s detail. Every per-window hashrate column (#168) is carried
    through, so the selected Avg window plots correctly even on downsampled wide ranges."""
    target = _target_points(duration_s)
    if target <= 0 or len(filtered_history) <= target:
        return filtered_history

    chunk_size = len(filtered_history) / target
    downsampled = []
    for i in range(target):
        chunk = filtered_history[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        mid = chunk[len(chunk) // 2]
        row = {"t": mid["t"], "timestamp": mid["timestamp"]}
        for col in _DOWNSAMPLE_VALUE_COLUMNS:
            row[col] = round(sum(x.get(col, 0) or 0 for x in chunk) / len(chunk), 2)
        downsampled.append(row)
    return downsampled


# Where the share markers ride on their own hidden 0–1 axis on the client: a constant near the
# top, so they form a "rug" along the top edge instead of riding the hashrate line. Pinning them
# off the hashrate axis keeps a single tall marker from inflating the y-range and burying a flat
# line at the bottom of the card (Issue #145).
_SHARE_MARKER_Y = 0.93


def _share_points(filtered_history, filtered_shares):
    """Sparse share markers: bucket each share onto its nearest history sample and emit one
    ``{x, y, r, c}`` point per sample that has shares (x = sample time ms, y = the fixed top-of-
    chart position on the client's dedicated share axis, r = radius scaled by count, c = count)."""
    if not (filtered_history and filtered_shares):
        return []

    hist_ts = [x["timestamp"] for x in filtered_history]
    counts = {}
    for s in filtered_shares:
        s_ts = s["ts"]
        idx = bisect.bisect_left(hist_ts, s_ts)
        candidates = []
        if idx < len(hist_ts):
            candidates.append(idx)
        if idx > 0:
            candidates.append(idx - 1)
        if candidates:
            closest_idx = min(candidates, key=lambda i: abs(hist_ts[i] - s_ts))
            counts[closest_idx] = counts.get(closest_idx, 0) + 1

    points = []
    for idx in sorted(counts):
        count = counts[idx]
        # y is fixed (a fraction of the dedicated 0–1 share axis): the marker no longer tracks the
        # hashrate, so it never stretches the y-range. Radius still scales with the share count.
        points.append(
            {
                "x": int(hist_ts[idx] * 1000),
                "y": _SHARE_MARKER_Y,
                "r": min(6 + (count * 3), 15),
                "c": count,
            }
        )
    return points


# Event markers ride just below the share rug on their own hidden 0–1 axis (#99), so a "something
# went wrong" marker sits at the event's real time without touching the hashrate y-range.
_EVENT_MARKER_Y = 0.82


def _event_points(filtered_events):
    """Sparse degradation/recovery markers (#99): one point per event at its timestamp, carrying the
    tooltip ``label`` and ``kind`` (e.g. ``hashrate_loss`` vs ``hashrate_recovered``) so the client
    can colour a loss vs a recovery."""
    return [
        {
            "x": int(e["ts"] * 1000),
            "y": _EVENT_MARKER_Y,
            "kind": e.get("type", ""),
            "label": e.get("detail") or e.get("type", "event"),
        }
        for e in filtered_events
    ]


# --------------------------------------------------------------------------------------
# Section builders: Metrics (+ passthrough) -> display data.
# --------------------------------------------------------------------------------------


def _mode_palette(current_mode):
    """(mode, p2p, xvb) palette tokens for the algo mode. Checked most-specific first:
    "XVB (Split)" contains both "Split" and "XVB"."""
    if "Split" in current_mode:
        return _TOKEN_BLUE, _TOKEN_GREEN, _TOKEN_PURPLE  # both pools active
    if "XVB" in current_mode:
        return _TOKEN_PURPLE, _TOKEN_MUTED, _TOKEN_PURPLE
    return _TOKEN_GREEN, _TOKEN_GREEN, _TOKEN_MUTED  # P2POOL


def build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok):
    """The hashrate/mode/tier values shown across the dashboard, formatted from Metrics."""
    return {
        "mode_name": metrics.mode,
        "mode_variant": mode_tok,
        "total": format_hashrate(metrics.total_h15),
        "p2p_1h": format_hashrate(metrics.p2pool_1h),
        "p2p_24h": format_hashrate(metrics.p2pool_24h),
        "p2p_variant": p2p_tok,
        # Credited (XvB API) — Advanced card only (#156).
        "xvb_1h": format_hashrate(metrics.xvb_1h),
        "xvb_24h": format_hashrate(metrics.xvb_24h),
        # Routed (proxy v_xvb) — header / Simple / chart.
        "xvb_routed_1h": format_hashrate(metrics.xvb_routed_1h),
        "xvb_routed_24h": format_hashrate(metrics.xvb_routed_24h),
        "xvb_variant": xvb_tok,
        "tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "xvb_fail_count": metrics.xvb_fail_count,
        "xvb_updated": format_time_abs(metrics.xvb_last_update),
        # Credited 1h/24h are frozen while the fetch is stale (#311) — the UI greys
        # them and flags the "Updated" line so the operator isn't misled by stale data.
        "xvb_stale": metrics.xvb_stale,
        "low_hr": {"text": "⚠ Hashrate low for tier", "title": _LOW_HR_TITLE}
        if metrics.low_hr_warning
        else None,
    }


def build_cadence(metrics):
    """Pool cadence & luck display values (#84). Formatting only — the figures live on Metrics.

    Durations (not localtime stamps) for the "since" figure so no timezone appears; ``available``
    gates luck/time-to-share, which are meaningless until there is hashrate history AND a pool
    difficulty (0 for the first samples after a wipe — never show inf/0s). ``weight`` is the
    miner's OWN PPLNS share-weight, not p2pool's pool-wide ``pplnsWeight``.
    """
    available = metrics.expected_share_sec > 0
    return {
        "last_block": format_time_abs(metrics.last_block_ts),
        "since_block": format_duration(time.time() - metrics.last_block_ts)
        if metrics.last_block_ts
        else "—",
        "tts": format_duration(metrics.expected_share_sec) if available else "—",
        "luck": f"{metrics.luck_pct:.0f}%" if available else "—",
        "weight": f"{metrics.own_pplns_weight:,.0f}",
        "available": available,
    }


def build_pool_network(data, metrics):
    """P2Pool / Stratum / Monero-network display values (computed bits come from Metrics)."""
    stratum = data.get("stratum", {})
    local_pool = data.get("pool", {}).get("pool", {})
    p2p = data.get("pool", {}).get("p2p", {})
    network = data.get("network", {})
    s_addr = stratum.get("wallet", "Unknown")

    return {
        "stratum": {
            "h15": format_hashrate(metrics.stratum_h15),
            "h1h": format_hashrate(metrics.stratum_h1h),
            "h24h": format_hashrate(metrics.stratum_h24h),
            "shares": f"{stratum.get('shares_found', 0)} / {stratum.get('shares_failed', 0)}",
            "effort": f"{stratum.get('current_effort', 0):.1f}%",
            "total_shares": stratum.get("total_stratum_shares", 0),
            "reward_pct": f"{stratum.get('block_reward_share_percent', 0):.4f}%",
            "conns": stratum.get("connections", 0),
            "last_share": format_time_abs(stratum.get("last_share_found_time", 0)),
            "total_hashes": stratum.get("total_hashes", 0),
            "wallet": s_addr,
            "wallet_short": _shorten(s_addr),
        },
        "pool": {
            "type": metrics.pool_type,
            "sidechain_height": local_pool.get("sidechain_height", 0),
            "diff": f"{metrics.pool_difficulty / 1e6:.2f} M",
            "hr": format_hashrate(metrics.pool_hashrate),
            "total_hashes": local_pool.get("total_hashes", 0),
            "miners": local_pool.get("miners", 0),
            "pplns_win": f"{metrics.pplns_window} ({format_duration(metrics.pplns_window * metrics.block_time)})",
            "pplns_wgt": local_pool.get("pplns_weight", 0),
            "blocks": local_pool.get("blocks_found", 0),
            "last_blk": format_time_abs(local_pool.get("last_block_ts", 0)),
            "peers": f"{p2p.get('out_peers', 0)} / {p2p.get('in_peers', 0)}",
            "uptime": format_duration(p2p.get("uptime", 0)),
        },
        "network": {
            "height": metrics.network_height,
            "reward": f"{network.get('reward', 0) / 1e12:.4f} XMR",
            "diff": f"{metrics.network_difficulty / 1e9:.2f} G",
            "hash": _shorten(str(network.get("hash", "N/A")), threshold=20),
            "ts": format_time_abs(network.get("timestamp", 0)),
        },
        "monero": {
            "mode": metrics.monero_mode,
            "db_size": _monero_db_size(data.get("monero_sync", {})),
        },
        "shares_window": {"count": metrics.shares_in_window, "ok": metrics.shares_in_window > 0},
    }


def _monero_db_size(monero_sync):
    """Human-readable on-disk Monero DB size (Issue #32); em-dash when unknown."""
    db_bytes = monero_sync.get("db_size", 0) or 0
    return f"{db_bytes / 1e9:.1f} GB" if db_bytes > 0 else "—"


def _shorten(addr, keep=8, threshold=16):
    """Elide a long address to ``head...tail`` for compact display; short ones pass through."""
    return addr if len(addr) <= threshold else f"{addr[:keep]}...{addr[-keep:]}"


def _usage_level(percent, threshold=80):
    """'high' once a resource gauge crosses ``threshold``, else 'ok'."""
    return "high" if percent > threshold else "ok"


# Per-worker reject flag (Issue #82). Purely presentational: flag a worker once its rejected-share
# rate crosses _REJECT_FLAG_RATE *and* it has enough rejects to not just be early-run noise, so an
# operator can spot a misbehaving rig. A worker submitting all-rejects (rate 100%) still trips the
# noise floor, so it flags as soon as the floor is reached.
_REJECT_FLAG_RATE = 0.05  # >= 5% of submitted shares rejected
_REJECT_FLAG_MIN = 3  # and at least this many rejects


def _reject_flag(accepted, rejected):
    """A ``{text, title}`` warning flag for a high per-worker reject rate, or ``None``."""
    total = accepted + rejected
    if total <= 0 or rejected < _REJECT_FLAG_MIN:
        return None
    rate = rejected / total
    if rate < _REJECT_FLAG_RATE:
        return None
    return {"text": "⚠", "title": f"High reject rate: {rate * 100:.1f}% ({rejected} rejected)"}


def build_system(data):
    """System resource metrics (CPU, RAM, Disk, HugePages) as formatted values + level tokens.

    These thresholds are purely presentational (how to colour a gauge), so they live here
    rather than in the domain metrics layer."""
    system = data.get("system", {})

    disk_usage = system.get("disk", {})
    disk_percent = disk_usage.get("percent", 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""

    mem_usage = system.get("memory", {})
    cpu_str = system.get("cpu_percent", "0.0%")
    try:
        cpu_val = float(cpu_str.strip("%"))
    except ValueError:
        cpu_val = 0.0

    load_raw = system.get("load", "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = (
        f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}"
        if len(load_parts) == 3
        else load_raw
    )

    hp_status, hp_class, hp_val = system.get("hugepages", ["Disabled", "status-bad", "0/0"])

    return {
        "cpu": {"percent": cpu_str, "load": load_avg, "level": _usage_level(cpu_val)},
        "mem": {
            "used": f"{mem_usage.get('used_gb', 0):.1f}",
            "total": f"{mem_usage.get('total_gb', 0):.1f}",
            "percent": mem_usage.get("percent_str", "0%"),
            "level": _usage_level(mem_usage.get("percent", 0)),
        },
        "disk": {
            "used": f"{disk_usage.get('used_gb', 0):.1f}",
            "total": f"{disk_usage.get('total_gb', 0):.1f}",
            "percent": disk_usage.get("percent_str", "0%"),
            "width": f"{disk_percent}%",
            "fill": disk_fill,
            "level": _usage_level(disk_percent),
        },
        "hugepages": {
            "status": hp_status,
            "value": hp_val,
            "variant": "ok" if hp_class == "status-ok" else "bad",
        },
    }


def build_workers(workers):
    """Worker rows as data: raw numeric fields (for client-side sorting) alongside their
    formatted display strings, plus a pool token for the badge. Online first, then by name."""
    rows = []
    sorted_workers = sorted(workers, key=lambda x: (x["status"] != "online", x["name"]))

    for worker in sorted_workers:
        try:
            active_pool = worker.get("active_pool", "")
            if any(p in active_pool for p in ["3333", "37889", "37888", "37890"]):
                pool = "p2pool"
            elif any(p in active_pool for p in ["3344", "4247"]):
                pool = "xvb"
            else:
                pool = "unknown"

            uptime = worker.get("uptime", 0)
            h60 = worker.get("h60", 0)
            h15 = worker.get("h15", 0)
            # Per-worker share health (Issue #82). Raw counts for client-side sorting; a display
            # string that appends invalid only when it's non-zero (keeps the common case clean);
            # and an optional warning flag the client renders when the reject rate is high.
            accepted = worker.get("accepted", 0)
            rejected = worker.get("rejected", 0)
            invalid = worker.get("invalid", 0)
            rejected_str = f"{rejected:,} (+{invalid:,} inv)" if invalid else f"{rejected:,}"
            rows.append(
                {
                    "name": worker["name"],
                    "ip": worker["ip"],
                    "ip_sort": _ip_to_sort_int(worker.get("ip", "0.0.0.0")),
                    "pool": pool,
                    "status": "online" if worker["status"] == "online" else "offline",
                    "uptime": uptime,
                    "uptime_str": format_duration(uptime),
                    # No h10 here: the table shows the 1m (h60) and 10m (h15) windows — via the
                    # proxy the legacy h10 field is just a second copy of the 1m rate (#387).
                    "h60": h60,
                    "h60_str": format_hashrate(h60),
                    "h15": h15,
                    "h15_str": format_hashrate(h15),
                    "accepted": accepted,
                    "accepted_str": f"{accepted:,}",
                    "rejected": rejected,
                    "rejected_str": rejected_str,
                    "invalid": invalid,
                    "reject_flag": _reject_flag(accepted, rejected),
                    # Worker-API probe verdict: False = configured probe failed (uptime/per-miner
                    # hashrate unavailable; the client badges it), True = ok, None = not probed
                    # (internal/invalid IP per the SSRF guard) — don't flag the unknown case.
                    "api_ok": worker.get("api_ok"),
                }
            )
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return rows


def build_proxy_summary(data):
    """Pool-wide share-health totals from the xmrig-proxy ``/summary`` (Issue #82): cumulative
    accepted/rejected/invalid/expired shares submitted to the upstream pool, the aggregate reject
    rate, and the best difficulty found. ``has_data`` is False until the proxy has been polled (no
    shares yet) so the client can hide an all-zero footer."""
    summary = data.get("proxy_summary", {}) or {}
    accepted = summary.get("accepted", 0) or 0
    rejected = summary.get("rejected", 0) or 0
    invalid = summary.get("invalid", 0) or 0
    expired = summary.get("expired", 0) or 0
    best = summary.get("best", 0) or 0

    total = accepted + rejected
    reject_pct = (rejected / total * 100) if total > 0 else 0.0
    return {
        "accepted": f"{accepted:,}",
        "rejected": f"{rejected:,}",
        "invalid": f"{invalid:,}",
        "expired": f"{expired:,}",
        "best": f"{int(best):,}" if best else "—",
        "reject_pct": f"{reject_pct:.2f}%",
        "reject_level": _usage_level(reject_pct, threshold=_REJECT_FLAG_RATE * 100),
        "has_data": (accepted + rejected + invalid) > 0,
    }


def _ip_to_sort_int(ip):
    """Pack a dotted-quad IP into an int for client-side numeric sorting; 0 on malformed input."""
    try:
        a, b, c, d = (int(part) for part in ip.split("."))
        return (a << 24) + (b << 16) + (c << 8) + d
    except (ValueError, IndexError, AttributeError):
        return 0


def build_tari(data):
    """Tari merge-mining display values. ``status`` is plain text; the client adds the ✔ only when
    ``connected`` (the gRPC merge-mine channel is actually READY), never merely when ``active``."""
    # This is the SINGLE place the effective Tari UI status is derived — `active`, the "Waiting..."
    # fallback, and the connected-gates-the-✔ rule. A duplicate that computed the same thing and then
    # discarded it lived (dead) in data_service and was removed in #280; keep this the only source so
    # the panel can't drift or go stale (#295).
    tari_stats = data.get("tari", {})
    tari_active = tari_stats.get("active", False)
    t_addr = tari_stats.get("address", "Unknown")

    return {
        "active": tari_active,
        "connected": bool(tari_stats.get("connected", False)) and tari_active,
        "status": tari_stats.get("status", "Waiting...") if tari_active else "Waiting...",
        "reward": f"{tari_stats.get('reward', 0):.2f} TARI",
        "height": str(tari_stats.get("height", 0)),
        "diff": f"{int(tari_stats.get('difficulty', 0)):,}",
        "wallet": t_addr,
        "wallet_short": _shorten(t_addr),
    }


def build_sync(metrics, monero_db_size):
    """Sync-screen state for both chains, mapping each SyncMetric to the client's 3-state
    gauge: 'done' (caught up — checked first, since a synced node may have no target height),
    'loading' (no target/data yet), else 'syncing'."""

    def section(sm, extra=None):
        state = "done" if sm.done else ("loading" if not sm.has_target else "syncing")
        out = {
            "state": state,
            "percent": sm.percent,
            "current": sm.current,
            "target": sm.target,
            "remaining": sm.remaining,
        }
        if extra:
            out.update(extra)
        return out

    return {
        "monero": section(metrics.monero, {"mode": metrics.monero_mode, "db_size": monero_db_size}),
        "tari": section(metrics.tari),
    }


# How long the "payout wallet changed" banner stays in the top bar after a change (#375).
WALLET_CHANGED_BADGE_SEC = 72 * 3600


def recent_wallet_change(state_mgr, now=None):
    """The payout-wallet tripwire's change record (#375) if one happened within the banner
    window: ``{"old8", "new8", "ts"}`` (addresses pre-truncated to 8 chars by the alerter),
    else ``None``. Reads the kv_store keys AlertService persists; any unreadable value reads
    as "no recent change" rather than breaking ``/api/state``."""
    try:
        ts = float(state_mgr.get_kv("payout_wallet_changed_ts") or 0)
    except (TypeError, ValueError):
        return None
    if not ts or (now if now is not None else time.time()) - ts >= WALLET_CHANGED_BADGE_SEC:
        return None
    return {
        "old8": state_mgr.get_kv("payout_wallet_prev8") or "?",
        "new8": (state_mgr.get_kv("payout_wallet") or "")[:8],
        "ts": ts,
    }


def build_badges(data, metrics, mode_variant, db_healthy=True, wallet_change=None):
    """Top-bar status badges as data: ``{text, variant, title?}`` (Issues #27/#31/#35/#51/#32/#131).
    The client renders them (variant -> ``badge-<variant>``). ``wallet_change`` is the
    payout-wallet tripwire's recent-change record (#375) from :func:`recent_wallet_change`, or
    ``None``."""
    badges = []
    # Payout wallet changed within the last 72h (#375): the loudest possible tamper signal, shown
    # even during sync. Addresses are truncated to 8 chars — full addresses stay off the wire.
    if wallet_change:
        badges.append(
            {
                "text": "⚠ Payout wallet changed",
                "variant": "warn",
                "title": f"{wallet_change['old8']}… → {wallet_change['new8']}… at "
                f"{format_time_abs(wallet_change['ts'])}",
            }
        )
    # Persistence health (#131): the dashboard keeps serving live data even if its SQLite DB can't
    # be written, but history/shares/stats would silently vanish on restart — surface it loudly.
    if not db_healthy:
        badges.append(
            {
                "text": "⚠ DB write failing",
                "variant": "bad",
                "title": "The dashboard can't persist to its database — hashrate history, shares, and stats will be lost on restart. Check disk space and permissions on the dashboard data directory.",
            }
        )
    if metrics.global_syncing:
        badges.append({"text": "Syncing...", "variant": "warn"})
    else:
        badges.append({"text": metrics.mode, "variant": mode_variant})
        badges.append({"text": f"P2Pool {metrics.pool_type}", "variant": "outline"})
        if metrics.low_hr_warning:
            badges.append(
                {"text": "⚠ Hashrate low for tier", "variant": "warn", "title": _LOW_HR_TITLE}
            )
        # No PPLNS share while donating (#158): XvB wins are skipped + accrue a fail, regardless of
        # tier. A make-or-break gate worth surfacing loudly so donations aren't wasted. (This is the
        # share half of Raffle Eligible; the tier half is shown by the XvB Tier field.)
        if metrics.xvb_enabled and metrics.shares_in_window == 0:
            badges.append(
                {
                    "text": "⚠ No PPLNS share — XvB wins skipped",
                    "variant": "warn",
                    "title": _NOT_ELIGIBLE_TITLE,
                }
            )

        # XvB raffle auto-registration status (#263). Warnings take priority over the ✓ so a real
        # problem (invalid wallet / persistently failing) is never masked by a stale timestamp.
        if metrics.xvb_enabled:
            if metrics.xvb_registration_state == "invalid":
                badges.append(
                    {
                        "text": "⚠ XvB wallet rejected",
                        "variant": "bad",
                        "title": _XVB_INVALID_TITLE,
                    }
                )
            elif metrics.xvb_registration_state == "failing":
                badges.append(
                    {
                        "text": "⚠ XvB registration failing",
                        "variant": "bad",
                        "title": _XVB_FAILING_TITLE,
                    }
                )
            elif metrics.xvb_registered_at > 0:
                badges.append(
                    {
                        "text": "XvB raffle ✓",
                        "variant": "outline",
                        "title": _XVB_REGISTERED_TITLE,
                    }
                )

    # Node-down badges (Issue #31) — shown whenever a node is unreachable, regardless of sync.
    if metrics.monero.down:
        badges.append({"text": "monerod DOWN", "variant": "bad"})
    if metrics.tari.down:
        badges.append({"text": "Tari DOWN", "variant": "bad"})
    if data.get("workers_rejected"):
        badges.append(
            {
                "text": "Workers rejected",
                "variant": "bad",
                "title": "Workers rejected so they fail over to their backup pools",
            }
        )
    # Miner held until required chain(s) finish their initial sync (Issue #35).
    if data.get("miner_held"):
        badges.append(
            {
                "text": "Miner held (sync)",
                "variant": "warn",
                "title": "p2pool and xmrig-proxy are held until the required chains finish syncing",
            }
        )
    # Non-blocking Tari (Issue #51): stay operational, surface a top-bar badge with the live
    # percentage once known (omitted early so it isn't a stale "0%").
    if data.get("tari_syncing_passive"):
        t_pct = metrics.tari.percent
        label = f"Tari syncing {t_pct}%" if t_pct > 0 else "Tari syncing"
        badges.append(
            {
                "text": label,
                "variant": "warn",
                "title": "Tari is still syncing — merge-mining resumes when it catches up; Monero mining continues",
            }
        )
    # Monero pruned/full badge (Issue #32) — only when known (local node).
    if metrics.monero_mode == "Pruned":
        badges.append(
            {"text": "XMR Pruned", "variant": "outline", "title": "Monero blockchain is pruned"}
        )
    elif metrics.monero_mode == "Full":
        badges.append(
            {
                "text": "XMR Full",
                "variant": "outline",
                "title": "Monero blockchain is full (not pruned)",
            }
        )

    # Low-disk badge (Issue #138). The data filesystem fills as the chains grow and logs accumulate;
    # a full disk corrupts monerod's DB mid-write. The disk *bar* shows the percentage, but it's easy
    # to miss — surface a prominent top-bar badge near full, on both the sync and main screens.
    disk_percent = (data.get("system", {}).get("disk", {}) or {}).get("percent", 0) or 0
    if disk_percent >= DISK_CRITICAL_PERCENT:
        badges.append(
            {
                "text": f"⚠ Disk {disk_percent:.0f}% full",
                "variant": "bad",
                "title": "The data disk is almost full — free space now; a full disk can corrupt the Monero database.",
            }
        )
    elif disk_percent >= DISK_WARN_PERCENT:
        badges.append(
            {
                "text": f"Disk {disk_percent:.0f}% full",
                "variant": "warn",
                "title": "The data disk is filling up — free space or move a data_dir before it runs out.",
            }
        )

    # Persistent host/performance conditions (#104), derived from live metrics so they self-correct
    # (HugePages appear after a reboot, etc.). These mirror the thresholds setup/doctor pre-flight on.
    system = data.get("system", {}) or {}
    hp_status = (system.get("hugepages") or ["Unknown"])[0]
    if hp_status == "Disabled":
        badges.append(
            {
                "text": "⚠ HugePages off",
                "variant": "warn",
                "title": "HugePages aren't reserved — RandomX hashrate is capped until they are. Run setup's tuning (or edit GRUB) and reboot to apply.",
            }
        )
    ram_total = (system.get("memory") or {}).get("total_gb", 0) or 0
    if 0 < ram_total < LOW_RAM_GB:
        badges.append(
            {
                "text": f"⚠ Low RAM ({ram_total:.0f} GB)",
                "variant": "warn",
                "title": f"Under {LOW_RAM_GB} GB of RAM — syncing (Tari especially) is memory-heavy and can OOM. Add RAM for a stable node.",
            }
        )
    if system.get("avx2") is False:
        badges.append(
            {
                "text": "⚠ No AVX2",
                "variant": "warn",
                "title": "This CPU lacks AVX2 — RandomX mining will be significantly slower. A hardware limit; nothing to change at runtime.",
            }
        )

    return badges


# --------------------------------------------------------------------------------------
# Earnings calculator (Issue #12): expected-XMR inputs for the Advanced view.
# --------------------------------------------------------------------------------------

_EARNINGS_DISCLAIMER = (
    "Estimated XMR from P2Pool mining only — excludes XvB donations (donated hashrate earns no "
    "P2Pool payout). Tari is earned alongside the XMR by the same hashrate (merge-mining), and "
    "its estimate assumes the merge-mine channel stays connected. Expected values only; mining "
    "is variance-heavy, so real payouts swing well above and below these figures. Estimates, "
    "not guarantees."
)


def build_earnings(data, metrics):
    """Expected-XMR-from-P2Pool calculator inputs for the Advanced view (Issue #12).

    This is a **P2Pool** mining calculator: it estimates the XMR earned by the hashrate that is
    actually mining on your P2Pool node — *not* the rig's total output. The what-if default is
    ``p2pool_1h`` — the **same P2Pool 1h-average hashrate shown in the header / Overview / My Node
    cards** (a time-weighted average of the recorded P2Pool hashrate), so the figure here matches
    those exactly. That recorded average already excludes any XvB-donated slice (XvB hashrate is a
    separate series), which is why an active XvB split doesn't inflate the estimate.

    Tari merge-mining rides along (#117): the same P2Pool hashrate simultaneously works the Tari
    aux chain, so the payload carries a second rate — XTM per H/s per day, over the Tari
    difficulty and block reward p2pool's merge-mine stats report. ``tari_available`` is gated on
    ``tari_mining`` as well as the rate, so a dead merge-mine channel can't show phantom XTM.

    Publishes the earnings **rate** (XMR per H/s per day, from ``service/earnings``) plus that
    P2Pool hashrate and the P2Pool share difficulty. The client scales the rate to the entered
    *what-if* hashrate and formats the day/month/year figures + expected time-to-share — sending
    a rate (not pre-formatted earnings) keeps the live recompute a single source of truth with no
    duplicated math (see ``web/static/logic.mjs``).

    ``available`` is False when the network figures needed for the rate are missing; the client
    then shows ``—`` instead of a bogus estimate (graceful degradation)."""
    reward_atomic = (data.get("network", {}) or {}).get("reward", 0) or 0
    coeff_day = xmr_per_hs_day(reward_atomic, metrics.network_difficulty)
    # Reuse the displayed P2Pool 1h average (header / Overview / My Node) so the calculator's
    # hashrate is consistent with the rest of the dashboard — and because that recorded average
    # already excludes the XvB-donated portion, it's the honest basis for a P2Pool estimate.
    p2pool_hr = metrics.p2pool_1h
    # Tari rate (#117). We take p2pool's aux `reward` field as the current Tari block reward —
    # it refreshes every poll, so the linear model tracks the decaying emission.
    tari_coeff_day = xtm_per_hs_day(metrics.tari_reward, metrics.tari_difficulty)
    return {
        "available": coeff_day > 0,
        "p2pool_hr": p2pool_hr,  # raw H/s — the what-if default
        "p2pool_hr_str": format_hashrate(p2pool_hr),
        "coeff_day": coeff_day,  # XMR per H/s per day
        "tari_available": tari_coeff_day > 0 and metrics.tari_mining,
        "tari_coeff_day": tari_coeff_day,  # XTM per H/s per day (merge-mined alongside)
        "pool_difficulty": metrics.pool_difficulty,  # for expected time-to-share (diff/hr)
        "block_reward": f"{reward_atomic / 1e12:.4f} XMR",  # context, server-formatted like NetworkCard
        "disclaimer": _EARNINGS_DISCLAIMER,
    }


# --------------------------------------------------------------------------------------
# Assembly.
# --------------------------------------------------------------------------------------


def host_display_addr(host):
    """The numeric IP to show *beside* the configured host in the header, or ``None`` (Issue #119).

    The configured ``dashboard.host`` is often a hostname that won't resolve from another machine
    on the LAN (flaky mDNS/``.local``, no DNS entry), so we surface the host's primary IP next to
    it as a fallback way in. Returns ``None`` — meaning "show the host alone" — when there's
    nothing useful to add: the host is already an IP, the address can't be determined, or it just
    duplicates the host.
    """
    if is_ip_address(host):
        return None
    addr = detect_host_ipv4()
    if not addr or addr == host:
        return None
    return addr


def _egress_badge(summary):
    """Glanceable header badge for the egress posture (#170): green when Tor-only, red on a leak."""
    ok = summary["level"] == "ok"
    return {
        "variant": "ok" if ok else "bad",
        "text": "🛡️ Tor-only egress" if ok else f"⚠️ {summary['leaks']} clearnet egress",
        "title": summary["label"],
    }


def build_state(data, state_mgr, range_arg, window=None, avg_window=DEFAULT_HASHRATE_WINDOW):
    """Assemble the full ``/api/state`` payload — the contract the client renders against.

    ``window`` is an optional ``(from, to)`` epoch-second manual-zoom window (Issue #47) that
    overrides ``range_arg`` for the chart. ``avg_window`` (#168) picks which hashrate-averaging
    window the chart plots. Computes domain values once (``build_metrics``), then
    formats each section. Every value is a JSON-serializable primitive, list or dict. May raise
    (e.g. ``state_mgr.get_history`` failing); the caller turns that into a sanitized 500."""
    data = data or {}
    history = state_mgr.get_history()
    share_stats = state_mgr.get_share_stats()  # per-poll share-health deltas (#116)
    metrics = build_metrics(data, state_mgr, history)
    db_healthy = state_mgr.is_db_healthy()

    mode_tok, p2p_tok, xvb_tok = _mode_palette(metrics.mode)
    pool_net = build_pool_network(data, metrics)

    egress = egress_posture_from_config()  # per-component egress route + privacy roll-up (#170)
    topology = (
        topology_from_config()
    )  # full stack wiring for the topology panel (#170); shares summary
    badges = build_badges(
        data, metrics, mode_tok, db_healthy, wallet_change=recent_wallet_change(state_mgr)
    )
    badges.append(_egress_badge(egress["summary"]))  # glanceable Tor-only / leak header badge

    return {
        "syncing": metrics.global_syncing,
        "page_title": "Pithead Dashboard - Syncing"
        if metrics.global_syncing
        else "Pithead Dashboard",
        "host_ip": HOST_IP,
        "host_addr": host_display_addr(HOST_IP),
        "version": resolve_version(),
        "update": data.get("update"),  # {available, latest, url} | None — new-release badge (#224)
        "last_update": format_time_abs(time.time()),
        "range": range_arg,
        "window": {"from": window[0], "to": window[1]} if window else None,
        "avg_window": avg_window,
        "avg_windows": HASHRATE_WINDOWS,
        "badges": badges,
        "db_healthy": db_healthy,
        "hashrate": build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok),
        "system": build_system(data),
        "sync": build_sync(metrics, pool_net["monero"]["db_size"]),
        "stratum": pool_net["stratum"],
        "pool": pool_net["pool"],
        "network": pool_net["network"],
        "monero": pool_net["monero"],
        "shares_window": pool_net["shares_window"],
        "cadence": build_cadence(metrics),
        "raffle_eligible": build_raffle_eligibility(metrics),
        "proxy_workers": metrics.workers_online,
        "earnings": build_earnings(data, metrics),
        "tari": build_tari(data),
        "workers": build_workers(data.get("workers", [])),
        "proxy_summary": build_proxy_summary(data),
        # Persisted per-poll share-health deltas + trailing 24h reject rate (#116). Kept out of
        # proxy_summary so its (cumulative) shape stays unchanged for existing clients.
        "share_stats": build_share_stats(share_stats, range_arg, window),
        "reject_pct_24h": _window_reject_pct(share_stats, 24 * 3600),
        "egress": egress,
        "topology": topology,
        "chart": build_chart(
            history,
            data.get("shares", []),
            range_arg,
            window,
            avg_window,
            events=state_mgr.get_events(),
        ),
    }


# --------------------------------------------------------------------------------------
# Static HTML shell (served at ``/``). No templated data — the client fetches ``/api/state``
# and renders. Cached, reloaded only if the file changes.
# --------------------------------------------------------------------------------------

SHELL_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")
_SHELL_CACHE = None
_SHELL_MTIME = 0


def get_shell_html():
    """Return the cached index.html shell, reloading from disk only if it changed."""
    global _SHELL_CACHE, _SHELL_MTIME
    try:
        mtime = os.path.getmtime(SHELL_PATH)
        if _SHELL_CACHE is None or mtime > _SHELL_MTIME:
            with open(SHELL_PATH) as f:
                _SHELL_CACHE = f.read()
            _SHELL_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading shell: {e}")
    return _SHELL_CACHE or "<h1>Dashboard shell error</h1>"
