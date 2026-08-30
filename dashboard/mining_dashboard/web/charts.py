"""Chart series for the dashboard: the window/range hub the ``/api/state`` chart payload is
built from (Issues #47, #65).

Split out of ``web/views.py`` (#1105) as the hub every other view cluster leans on: window
parsing and canonicalisation, range filtering, adaptive point-count/tension tiers, bucket
downsampling, and the marker series (shares, degradation events, raffle wins, payouts) that ride
their own hidden 0-1 axis. ``views.py`` stays the facade — it re-exports the names its callers
(``server.py``, ``worker_detail.py``) already import — so this move is invisible to consumers.

Nothing here formats display strings; it emits chart-ready points and lets the client render.
"""

import bisect
import logging
import math
import time

from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    HASHRATE_WINDOW_COLUMNS,
    HASHRATE_WINDOWS,
    UPDATE_INTERVAL,
)
from mining_dashboard.helper.utils import format_hashrate
from mining_dashboard.service.earnings import ATOMIC_PER_XMR

# Deliberately the *views* logger name: _payout_points' marker-cap line is operator-visible, and
# the split must not rename the record it arrives under.
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


def parse_window(from_arg, to_arg) -> tuple[float, float] | None:
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


# --------------------------------------------------------------------------------------
# Chart series (Issue #65: positioned by real time, with outage gaps as breaks).
# --------------------------------------------------------------------------------------


def build_chart(
    history,
    shares,
    range_arg,
    window=None,
    avg_window=DEFAULT_HASHRATE_WINDOW,
    events=None,
    raffle_wins=None,
    payouts=None,
):
    """Build the Chart.js datasets from history. Each point carries its real timestamp as the
    x value (epoch ms) so a linear time axis spaces points to scale; runs of missing samples
    (outages) are split by a ``null`` break so the line doesn't connect across the gap.

    ``window`` is an optional ``(from, to)`` epoch-second pair (a manual zoom) that bounds both
    ends and overrides ``range_arg``. Point density and ``tension`` adapt to the visible window
    duration (Issue #47). ``avg_window`` (#168) selects which hashrate-averaging window's columns
    to plot (1m / 10m / 1h / 12h / 24h); 10m is the default headline series.

    ``payouts`` (#381), when the view-only wallet feature is on, is the stored confirmed-payout
    list — one gold coin marker per Monero payout, on the same hidden 0–1 axis as the raffle
    stars; ``None`` (feature off) yields an empty ``payouts`` list.

    Returns ``{"p2pool": [{x, y}], "xvb": [{x, y}], "shares": [{x, y, r, c}], "events": [...],
    "raffle": [...], "payouts": [...], "tension": float}``
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
        # _filter_events bounds any ts-keyed list, so the raffle wins reuse it as-is.
        "raffle": _raffle_points(_filter_events(raffle_wins or [], range_arg, window)),
        # Confirmed on-chain payout markers (#381); newest-first order is preserved by the filter,
        # so _payout_points' most-recent cap keeps the newest in range.
        "payouts": _payout_points(_filter_events(payouts or [], range_arg, window)),
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


# Raffle-win markers ride the same hidden 0–1 axis as the event markers, one step below them, so a
# win sits at its real time without touching the hashrate y-range.
_RAFFLE_MARKER_Y = 0.70


def _raffle_points(filtered_wins):
    """Sparse XvB raffle-win markers: one gold star per round this wallet won, at the round's
    timestamp, with the tooltip carrying the round type and the credited hashrate."""
    return [
        {
            "x": int(w["ts"] * 1000),
            "y": _RAFFLE_MARKER_Y,
            "label": f"XvB raffle win — {w['tier']} round at {format_hashrate(w['hashrate'])}",
        }
        for w in filtered_wins
    ]


# Confirmed on-chain payout markers ride the same hidden 0–1 axis as the raffle stars, one step
# below them (#381), so a payout sits at its real block time without touching the hashrate y-range.
_PAYOUT_MARKER_Y = 0.58

# A long-lived wallet can accrue many payouts; the chart shows the most-recent-in-range so a busy
# marker row can't bloat every /api/state payload. The EarningsCard totals still count them all.
_PAYOUT_MARKER_LIMIT = 200


def _payout_points(filtered_payouts, divisor=ATOMIC_PER_XMR):
    """Sparse confirmed-payout markers (#381): one gold coin per on-chain Monero payout at its
    block time, the tooltip carrying the whole-XMR amount (atomic→XMR at this edge, ``divisor``)
    and the payout date. ``filtered_payouts`` is the range-bounded stored-payout list, newest
    first (``storage.get_payouts``); capped at ``_PAYOUT_MARKER_LIMIT`` most-recent — the overflow
    is logged, never silently dropped."""
    if len(filtered_payouts) > _PAYOUT_MARKER_LIMIT:
        logger.info(
            "Chart payout markers capped at %d of %d (most recent kept)",
            _PAYOUT_MARKER_LIMIT,
            len(filtered_payouts),
        )
        filtered_payouts = filtered_payouts[:_PAYOUT_MARKER_LIMIT]
    return [
        {
            "x": int(p["ts"] * 1000),
            "y": _PAYOUT_MARKER_Y,
            "label": f"{(p.get('amount_atomic', 0) or 0) / divisor:.6f} XMR — "
            f"{time.strftime('%Y-%m-%d', time.localtime(p.get('ts', 0)))}",
        }
        for p in filtered_payouts
    ]
