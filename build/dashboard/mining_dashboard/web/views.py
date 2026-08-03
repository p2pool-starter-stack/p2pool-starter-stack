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

from mining_dashboard.config import config
from mining_dashboard.config.config import (
    DEFAULT_HASHRATE_WINDOW,
    DISK_CRITICAL_PERCENT,
    DISK_WARN_PERCENT,
    HASHRATE_WINDOW_COLUMNS,
    HASHRATE_WINDOWS,
    HOST_IP,
    LOW_RAM_AVAILABLE_GB,
    UPDATE_INTERVAL,
    XVB_MAX_DONATION_FRACTION,
    low_ram_floor_gb,
    monero_is_local,
    tari_is_local,
)
from mining_dashboard.helper.utils import (
    detect_host_ipv4,
    format_disk_size,
    format_duration,
    format_hashrate,
    format_time_abs,
    get_tier_info,
    is_ip_address,
    xvb_stats_are_stale,
)
from mining_dashboard.service.control_service import WORKER_WRITABLE_KEYS
from mining_dashboard.service.earnings import (
    ATOMIC_PER_XMR,
    MICRO_PER_XTM,
    SECONDS_PER_DAY,
    confirmed_payouts_summary,
    tari_seconds_to_block_per_hs,
    xmr_per_hs_day,
    xtm_per_hs_day,
)
from mining_dashboard.service.egress import egress_posture_from_config, topology_from_config
from mining_dashboard.service.metrics import build_metrics, share_reject_pct
from mining_dashboard.service.update_checker import compute_update, parse_semver
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


# The XvB card's raffle-wins log shows the most recent wins only; the chart still gets every win
# in the selected range. Keeps a long-lived fleet's history from bloating every /api/state payload.
_RAFFLE_LOG_LIMIT = 20


def build_raffle_log(wins):
    """The XvB card's raffle-wins log: newest first, display-formatted, capped at
    ``_RAFFLE_LOG_LIMIT``. ``wins`` is ``StateManager.get_raffle_wins()`` output (oldest first)."""
    return [
        {
            "time": format_time_abs(w["ts"]),
            "tier": w["tier"],
            "hashrate": format_hashrate(w["hashrate"]),
            "height": w["height"],
        }
        for w in list(reversed(wins))[:_RAFFLE_LOG_LIMIT]
    ]


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


# --------------------------------------------------------------------------------------
# #196 Tier-1 telemetry backbone: blocks / disk_growth / xvb_history surfaced on /api/state.
# The backbone (capture + storage + retention, PR #600) shipped without this exposure step —
# these three formatters are it. network_history and worker_history are Tier-2 (a separate
# slice of the epic) and are not exposed here.
# --------------------------------------------------------------------------------------


def _downsample_gauge_rows(rows, value_cols, target=_MAX_CHART_POINTS):
    """Bucket-average arbitrary point-in-time (gauge) columns down to ``target`` points.

    Mirrors ``_downsample_share_stats``, but averages instead of summing: these rows are
    periodic READINGS (disk size, XvB credited averages), not per-interval deltas, so summing
    them would inflate the series instead of thinning it. A no-op when already at/under target."""
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in value_cols:
            vals = [r.get(col, 0) or 0 for r in chunk]
            bucket[col] = round(sum(vals) / len(vals), 2)
        out.append(bucket)
    return out


def build_blocks(blocks, range_arg, window=None):
    """Persisted P2Pool block-found events (#196) as chart-ready points, restricted to the
    selected range/window (``_filter_events`` bounds any ts-keyed list, so this table reuses
    it as-is). A handful of rows a week — no downsampling needed."""
    return [
        {
            "x": int(b["ts"] * 1000),
            "height": b.get("height", 0),
            "difficulty": b.get("difficulty", 0),
        }
        for b in _filter_events(blocks, range_arg, window)
    ]


def build_payouts(state_mgr, range_arg, window=None):
    """Persisted confirmed payouts per chain as chart-ready points, restricted to the selected
    range/window like ``build_blocks`` (payout rows are ``ts``-keyed too). A confirmed Tari
    coinbase payout is the wallet's proof of a solo-found Tari block, so this series is what
    lets the client mark Tari income on a timeline (the mine cart train's purple coin; a chart
    series can reuse it). Amounts stay atomic (piconero / microTari) — the client only marks
    the moment, it does no coin math. Empty when payout confirmation is off or the wallet
    hasn't scanned yet; a handful of rows a week — no downsampling needed."""
    chains = (
        ("monero", config.PAYOUT_CONFIRM_ENABLED),
        ("tari", config.TARI_PAYOUT_CONFIRM_ENABLED),
    )
    return {
        chain: [
            {"x": int(p["ts"] * 1000), "amount": p.get("amount_atomic", 0)}
            for p in _filter_events(state_mgr.get_payouts(chain), range_arg, window)
        ]
        if enabled and state_mgr is not None
        else []
        for chain, enabled in chains
    }


def _gauge_series(rows, range_arg, window, value_cols):
    """Shared shape for a persisted gauge series (#196): filter to the selected range/window,
    bucket-average past ``_MAX_CHART_POINTS`` like ``share_stats``, and key each row's own
    ``value_cols`` under ``x`` (ms epoch). ``build_disk_growth``/``build_xvb_history`` are this
    with their own column set — the only thing that differs between them."""
    filtered = _downsample_gauge_rows(_filter_events(rows, range_arg, window), value_cols)
    return [{"x": int(r["ts"] * 1000), **{c: r.get(c, 0) for c in value_cols}} for r in filtered]


def build_disk_growth(rows, range_arg, window=None):
    """Persisted hourly monerod-DB-size + host-disk-usage samples (#196) as chart-ready points —
    the table keeps every row (no retention prune), so a long-lived install can otherwise pass
    the chart-point cap ``_gauge_series`` bounds it at."""
    return _gauge_series(
        rows, range_arg, window, ("monero_db_bytes", "disk_used_gb", "disk_total_gb")
    )


def build_xvb_history(rows, range_arg, window=None):
    """Persisted ~5-minute XvB-credited scalar samples (#196) as chart-ready points — the 30-day
    retention at this cadence is ~8.6k rows, well past the chart-point cap ``_gauge_series``
    bounds it at."""
    return _gauge_series(
        rows, range_arg, window, ("avg_1h", "avg_24h", "fail_count", "donation_fraction")
    )


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


def _num(v):
    """A number for display, or None for anything non-numeric (incl. bools, which JSON booleans
    would otherwise pass as 0/1). Every enriched RigForge field is nullable on the wire (#235)."""
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _fmt_num(v):
    """Trim a display number: drop a pointless ``.0`` so ``142.0 W`` reads ``142 W``."""
    return str(int(v)) if isinstance(v, float) and v.is_integer() else str(v)


def _rigforge_display(rf):
    """A ``{version, miner_down, chips, stats}`` view of a worker's parsed ``rigforge`` block, or
    ``None`` for a plain-xmrig worker (#235). Each metric is emitted ONLY when its data is present —
    a rig with no RAPL shows no power row, a disabled watchdog shows no watchdog row.

    Both outputs come from one pass so they can't drift: ``chips`` is the merged ``{text, variant,
    title}`` badge shape the compact Workers-Alive list renders, and ``stats`` is the same metrics
    split into ``{label, value, variant, title}`` for the Worker Inspect detail table (#507).
    Building the set (and its thresholds) here keeps the client a dumb renderer, matching the
    ``_reject_flag`` precedent."""
    if not rf:
        return None
    rows = []

    def add(label, value, chip, variant, title):
        rows.append(
            {"label": label, "value": value, "chip": chip, "variant": variant, "title": title}
        )

    if rf.get("miner_down"):
        add(
            "Miner",
            "down",
            "miner down",
            "bad",
            "RigForge is up but its XMRig API is unreachable — the rig is present but not mining. "
            "Live hashrate and uptime come from the proxy.",
        )

    health = rf.get("health") or {}
    if health.get("throttling") is True:
        add("CPU", "throttling", "throttling", "bad", "CPU is thermal/power throttling.")
    gov = health.get("governor")
    if gov:
        ok = gov == "performance"
        add(
            "Governor",
            gov,
            f"gov: {gov}",
            "ok" if ok else "warn",
            "CPU frequency governor"
            + ("" if ok else " — 'performance' is recommended for mining."),
        )
    hp = _num(health.get("hugepages_total"))
    if hp is not None:
        add(
            "HugePages",
            _fmt_num(hp),
            f"HP {_fmt_num(hp)}",
            "outline",
            f"HugePages allocated: {_fmt_num(hp)}.",
        )
    board = health.get("board")
    if board:
        add("Mainboard", board, board, "outline", "Mainboard (firmware).")

    power = rf.get("power") or {}
    watts = _num(power.get("watts"))
    hspw = _num(power.get("hs_per_watt"))
    if watts is not None or hspw is not None:
        parts = []
        if watts is not None:
            parts.append(f"{_fmt_num(round(watts, 1))} W")
        if hspw is not None:
            parts.append(f"{_fmt_num(round(hspw, 1))} H/s·W")
        text = " · ".join(parts)
        add("Power / efficiency", text, text, "outline", "Power draw / efficiency.")

    tune = rf.get("tune") or {}
    if tune.get("target"):
        add(
            "Tuning target",
            tune["target"],
            f"tune: {tune['target']}",
            "outline",
            "Active tuning target.",
        )
    if tune.get("autotune_enabled") and tune.get("autotune_next"):
        add(
            "Autotune",
            tune["autotune_next"],
            f"autotune → {tune['autotune_next']}",
            "outline",
            "Next scheduled autotune run.",
        )

    wd = rf.get("watchdog") or {}
    if wd.get("enabled"):
        temp = _num(wd.get("temp_c"))
        maxt = _num(wd.get("max_temp_c"))
        if wd.get("thermal_hold") is True:
            add(
                "Watchdog",
                "thermal hold",
                "thermal hold",
                "bad",
                "Watchdog is holding the rig back — temperature above its ceiling.",
            )
        elif temp is not None:
            text = f"{_fmt_num(round(temp, 1))}°C"
            if maxt is not None:
                text += f" / {_fmt_num(maxt)}°C"
            add("Temp / max", text, text, "outline", "Watchdog temperature / ceiling.")

    chips = [{"text": r["chip"], "variant": r["variant"], "title": r["title"]} for r in rows]
    stats = [
        {"label": r["label"], "value": r["value"], "variant": r["variant"], "title": r["title"]}
        for r in rows
    ]
    return {
        "version": rf.get("version"),
        "miner_down": bool(rf.get("miner_down")),
        "chips": chips,
        "stats": stats,
    }


def build_system(data):
    """System resource metrics (CPU, RAM, Disk, HugePages) as formatted values + level tokens.

    These thresholds are purely presentational (how to colour a gauge), so they live here
    rather than in the domain metrics layer."""
    system = data.get("system", {})

    disk_usage = system.get("disk", {})
    disk_used, disk_total, disk_unit = format_disk_size(
        disk_usage.get("used_gb", 0), disk_usage.get("total_gb", 0)
    )
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
            "used": disk_used,
            "total": disk_total,
            "unit": disk_unit,
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


def rigforge_update_for(worker, release):
    """The per-worker RigForge new-release callout (#596): ``{available, latest, url}`` or ``None``.

    Derived at the render seam from the rig's live reported version and the fleet-wide cached
    latest release — never stored, so it can't outlive its inputs (the #664 lesson: a rig running
    X must never badge "X available"). ``compute_update`` normalizes the rig's bare ``1.11.2``
    against the release tag's ``v1.11.2``. No reported version (plain xmrig, sister API off) or no
    cached release → ``None``, an honest "unknown", not a false "up to date"."""
    if not worker or not release:
        return None
    version = (worker.get("rigforge") or {}).get("version")
    if not version:
        return None
    return compute_update(version, release.get("tag"), release.get("url"))


def build_workers(workers, rigforge_release=None):
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
                    # RigForge enriched feed (#235): version badge + health/power/tune/watchdog
                    # chips, or None for a plain-xmrig worker (renders nothing extra).
                    "rigforge": _rigforge_display(worker.get("rigforge")),
                    # {available, latest, url} | None — this rig runs an older RigForge (#596).
                    "rigforge_update": rigforge_update_for(worker, rigforge_release),
                }
            )
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return rows


# --------------------------------------------------------------------------------------
# Energy & profit calculator (Issue #260, Tari revenue #520): fleet power draw + efficiency, and —
# once the operator sets an electricity price (and an XMR price) — the net profit after power.
# Setting a Tari price too folds the estimated Tari merge-mining revenue into gross so a Tari
# merge-miner's net profit isn't silently undercounted (P2Pool-only was the #520 bug). The server
# totals the measured draw and publishes the prices; the client does the per-day/month/year
# arithmetic and the net = gross − cost, scaling gross with the same what-if hashrate the earnings
# card already uses (one source of truth, #61). Deliberately NO price feed for either coin: fetching
# one is a clearnet egress this privacy-first stack avoids (#160) — an opt-in Tor-routed feed is
# deferred, see #520 — so all prices are operator-supplied.
# --------------------------------------------------------------------------------------

_ENERGY_DISCLAIMER = (
    "Power draw is measured (RAPL, 15s sample) or your per-worker estimate; a worker reporting "
    "neither is excluded and the fleet total is marked incomplete. kWh and cost extrapolate the "
    "current draw at a constant rate — a naive projection, not a metered bill. Net profit is "
    "P2Pool XMR earnings valued at the XMR price in use (your configured price, or the live "
    "CoinGecko-over-Tor feed when dashboard.energy.price_feed is on), plus Tari merge-mining "
    "earnings valued at the Tari price when one is set (0/unset counts P2Pool XMR only) — minus "
    "power cost. XvB stays excluded: it's raffle status, not a clean per-day income estimate. "
    "Estimates, not guarantees."
)


def _worker_watts_config(name):
    """The operator's manual watts estimate for a worker name (#172 descriptor ``watts``), or None."""
    for entry in config.DASHBOARD_WORKERS:
        if entry["name"] == name:
            return entry.get("watts")
    return None


def build_energy(workers, prices=None):
    """Fleet energy inputs for the earnings card's Energy tab (Issue #260).

    Sums each worker's power draw — measured watts from the RigForge enriched feed (#235) first, else
    the operator's per-worker ``watts`` estimate (marked ``estimated``). A worker with neither is
    excluded and flips ``incomplete`` so the UI shows the total as a lower bound rather than counting
    it as zero. Fleet efficiency (H/s per watt) is the summed hashrate of the powered workers over
    their summed watts, so a worker with unknown draw skews neither number.

    Publishes the summed watts + prices; the client scales to kWh / cost / net per day·month·year
    (``computeEnergy`` in ``logic.mjs``). ``available`` is False only when no worker reports or is
    configured with any power — the card then shows nothing rather than a zero-watt fleet.

    ``prices`` is the live feed result (#520, ``state.prices`` — ``{xmr, tari, currency,
    fetched_at}`` or None). When the feed is enabled and has fetched, the live prices replace the
    static config numbers and ``price_source`` says so (with their age) — the calculator always
    states which price it's using. Until the first fetch (or with the feed off) the static config
    prices stand."""
    cfg = config.DASHBOARD_ENERGY
    live = prices if cfg["price_feed"] else None
    price_source = {
        # feed: the operator turned dashboard.energy.price_feed on; live: a fetch has landed.
        "feed": cfg["price_feed"],
        "live": bool(live),
        "age_sec": round(time.time() - live["fetched_at"]) if live else None,
    }
    xmr_price = live["xmr"] if live else cfg["xmr_price"]
    tari_price = live["tari"] if live else cfg["tari_price"]
    per_worker = []
    total_watts = 0.0
    powered_hs = 0.0
    incomplete = False
    for worker in workers:
        name = worker.get("name", "")
        rf = worker.get("rigforge") or {}
        power = rf.get("power") or {}
        watts = _num(power.get("watts"))
        estimated = False
        if watts is None or watts <= 0:
            cfg_watts = _worker_watts_config(name)
            watts = cfg_watts if (cfg_watts and cfg_watts > 0) else None
            estimated = watts is not None
        hs = _num(worker.get("h60")) or 0.0
        if watts is None:
            incomplete = True
            per_worker.append(
                {"name": name, "watts": None, "estimated": False, "hs": hs, "hs_per_watt": None}
            )
            continue
        total_watts += watts
        powered_hs += hs
        per_worker.append(
            {
                "name": name,
                "watts": round(watts, 1),
                "estimated": estimated,
                "hs": hs,
                "hs_per_watt": round(hs / watts, 2) if watts > 0 else None,
            }
        )
    have_power = total_watts > 0
    return {
        "available": have_power,
        "total_watts": round(total_watts, 1) if have_power else None,
        "hs_per_watt": round(powered_hs / total_watts, 2) if have_power else None,
        "incomplete": incomplete,
        "cost_per_kwh": cfg["cost_per_kwh"],
        "xmr_price": xmr_price,
        "tari_price": tari_price,
        "currency": cfg["currency"],
        "price_source": price_source,
        "per_worker": per_worker,
        "disclaimer": _ENERGY_DISCLAIMER,
    }


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
    # Fail-closed miner hold on an unrecoverable health failure (Issue #490), opt-in via
    # dashboard.fail_closed. Distinct from the sync-gate badge above — this fires post-sync.
    if data.get("fail_closed_held"):
        badges.append(
            {
                "text": "Miner held (fail-closed)",
                "variant": "bad",
                "title": "dashboard.fail_closed is on and an unrecoverable health failure is "
                "holding p2pool and xmrig-proxy until it clears",
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
    memory = system.get("memory") or {}
    ram_total = memory.get("total_gb", 0) or 0
    ram_avail = memory.get("available_gb")
    # The floor tracks what THIS machine runs locally: remote nodes take their appetite with
    # them, and a light coordinator must not be told to buy RAM for a node it does not run.
    floor = low_ram_floor_gb(monero_is_local(), tari_is_local())
    if 0 < ram_total < floor:
        badges.append(
            {
                "text": f"⚠ Low RAM ({ram_total:.0f} GB)",
                "variant": "warn",
                "title": f"Under {floor:g} GB of usable RAM for what this machine runs locally — syncing (Tari especially) is memory-heavy and can OOM. Add RAM for a stable node.",
            }
        )
    # Pressure is a LIVE signal, separate from capacity: a big box can still be out of memory,
    # and a spec box quietly idling must not wear a warning it has not earned.
    if ram_avail is not None and 0 < ram_avail < LOW_RAM_AVAILABLE_GB:
        badges.append(
            {
                "text": f"⚠ Memory pressure ({ram_avail:.1f} GB free)",
                "variant": "warn",
                "title": f"Under {LOW_RAM_AVAILABLE_GB:g} GB of memory is actually available right now — the next spike can OOM a container. Check which service is growing on the System panel.",
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
    "P2Pool payout). Tari is merge-mined SOLO by the same hashrate: you get the whole block reward "
    "at once when your hashrate finds a Tari block — roughly every 'time to Tari block' shown — so "
    "the per-day XTM figure is a long-run average, not steady income. Expected values only; mining "
    "is variance-heavy, so real payouts swing well above and below these figures. Estimates, "
    "not guarantees."
)


def xvb_current_tier_reward_day(metrics, state_mgr):
    """XvB's published expected reward for the tier the fleet is CURRENTLY holding, as XMR/day (#712).

    Feeds the net-profit calculator (``est.xvbDay``): the whole net is already probabilistic, so
    blending the raffle's expected reward into the single figure is coherent — but it's an
    *estimate* (the draw is random among qualifiers), so the UI labels it as one.

    Uses the **current** tier (``min(xvb_1h, xvb_24h)`` — the same lower-of-two rule as
    ``metrics.current_tier``), not the target: what the fleet is actually credited now. Returns
    ``None`` — never a fabricated figure — unless XvB is on AND the fleet clears a donor tier AND
    that tier has a fresh, published ``expected_reward_year`` (same staleness gate as the XvB card,
    #311, so the two never disagree). ``expected_reward_year`` is keyed by round-type
    (``donor``/``donor_vip``/…), exactly the ``get_tiers()`` keys."""
    if not metrics.xvb_enabled:
        return None
    tiers = state_mgr.get_tiers()
    key = xvb_current_tier_key(metrics, tiers)
    if key is None:
        return None
    est_state = state_mgr.get_xvb_reward_estimates()
    estimates = (est_state or {}).get("estimates") or {}
    if xvb_stats_are_stale(est_state) or key not in estimates:
        return None
    reward_year = estimates[key]
    # 365-day year, matching logic.mjs DAYS_PER_YEAR. Guard non-positive so a zero/garbage estimate
    # degrades to None rather than folding a bogus 0 into gross.
    return float(reward_year) / 365 if reward_year and reward_year > 0 else None


def xvb_current_tier_key(metrics, tiers):
    """Round-type key of the tier the fleet is CURRENTLY credited for, or None below the lowest.

    The highest-threshold key that ``min(xvb_1h, xvb_24h)`` clears — the same lower-of-two rule as
    ``metrics.current_tier``, but yielding the KEY (``donor``/``donor_vip``/…) the estimate and
    round-stats tables are indexed by."""
    hr = min(metrics.xvb_1h, metrics.xvb_24h)
    key, best = None, 0.0
    for k, threshold in tiers.items():
        if threshold > 0 and hr >= threshold and threshold > best:
            key, best = k, threshold
    return key


# Measuring what a raffle win actually pays (#866/#872). A win's bonus round mines for up to an
# hour and lands as ordinary small P2Pool payouts shortly after; production measurement put the
# attributable payout mass inside 2h of the win timestamp. A win younger than the settle window
# may still have payouts in flight, so it is left out of the sample rather than dragging the
# factor down. Below the minimum sample the factor is noise — callers fall back to the published
# figure and the UI labels it face value.
_XVB_WIN_PAYOUT_WINDOW_S = 2 * 3600
_XVB_WIN_SETTLE_S = 12 * 3600
_XVB_REALIZATION_MIN_WINS = 5
_XVB_REALIZATION_WINDOW_S = 45 * SECONDS_PER_DAY


def xvb_expected_wins_day(round_stats_state, tier_key, tiers):
    """Expected raffle wins per day for the held tier (#866), from XvB's own winners file.

    The file's players column is the qualifier count per round, so the honest forecast is
    mechanical: for each donor round type the fleet qualifies for (threshold at or under the held
    tier's), rounds-per-day ÷ average qualifiers, summed. Verified against production: predicted
    0.84 whale wins/day, measured 0.84/day over the same stretch. None when the aggregate is
    missing, stale (#311 rule), or spans no measurable time — the card shows "—", never a guess."""
    if not tier_key:
        return None
    stats = (round_stats_state or {}).get("stats") or {}
    types = stats.get("types") or {}
    span_days = stats.get("span_days") or 0.0
    if xvb_stats_are_stale(round_stats_state) or not types or span_days <= 0:
        return None
    held = tiers.get(tier_key, 0.0)
    total = 0.0
    for key, threshold in tiers.items():
        if 0 < threshold <= held:
            agg = types.get(key)
            if agg and agg.get("players_avg", 0) > 0 and agg.get("rounds", 0) > 0:
                total += (agg["rounds"] / span_days) / agg["players_avg"]
    return total if total > 0 else None


def xvb_realization(payouts, raffle_wins, xvb_day, expected_wins_day, now=None):
    """Measured fraction of XvB's published expectation this wallet actually collects (#866/#872).

    Numerator: mean confirmed XMR landing within the attribution window after each settled win in
    the trailing measurement window. Denominator: face value per win — the published per-day figure
    spread over the expected win rate. Production measured ~0.19 on a Whale-tier box whose credited
    average rode the round minimum; the published figures assume 1.0. Returns
    ``(fraction clamped to [0, 1], wins measured)``, or None (callers fall back to the published
    number, labeled face value) when either side is missing or fewer than
    ``_XVB_REALIZATION_MIN_WINS`` wins are measurable."""
    # ponytail: one factor across tiers and eras — per-tier factors if a tier change muddies it.
    if not payouts or not raffle_wins or not xvb_day or not expected_wins_day:
        return None
    now = now if now is not None else time.time()
    lo = now - _XVB_REALIZATION_WINDOW_S
    stamps = [
        t for t in ((w.get("ts") or 0) for w in raffle_wins) if lo <= t <= now - _XVB_WIN_SETTLE_S
    ]
    if len(stamps) < _XVB_REALIZATION_MIN_WINS:
        return None
    face_per_win = xvb_day / expected_wins_day
    if face_per_win <= 0:
        return None
    # Each payout counts once even when two win windows overlap (back-to-back wins).
    realized = (
        sum(
            (p.get("amount_atomic") or 0)
            for p in payouts
            if any(0 <= (p.get("ts") or 0) - t <= _XVB_WIN_PAYOUT_WINDOW_S for t in stamps)
        )
        / ATOMIC_PER_XMR
    )
    frac = (realized / len(stamps)) / face_per_win
    return (max(0.0, min(1.0, frac)), len(stamps))


def build_earnings(data, metrics, payouts=None, tari_payouts=None, xvb_day=None):
    """Expected-XMR-from-P2Pool calculator inputs for the Advanced view (Issue #12).

    ``payouts`` (#381), when the view-only wallet feature is on, is the stored confirmed-payout
    list; it's rolled into a ``confirmed`` block (yesterday / 24h / 7d / 30d / all-time XMR, #787)
    shown beside this estimate — the estimate is a model, the confirmed figure is ground truth from
    the wallet. ``tari_payouts`` (#462) is the same for the Tari side, rolled into
    ``tari_confirmed`` (XTM) beside the Tari time-to-block estimate.

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
    # Solo merge-mining pays the whole block at once (#117): the honest headline is the expected
    # time to a Tari block (difficulty / hashrate) and the per-block reward, with the per-day rate
    # kept only as a long-run average. `tari_difficulty` carries the seconds-to-block-per-H/s figure
    # (== difficulty, guarded); the client divides it by the what-if hashrate.
    tari_seconds_per_hs = tari_seconds_to_block_per_hs(metrics.tari_difficulty)
    return {
        "available": coeff_day > 0,
        "p2pool_hr": p2pool_hr,  # raw H/s — the what-if default
        "p2pool_hr_str": format_hashrate(p2pool_hr),
        "coeff_day": coeff_day,  # XMR per H/s per day
        "tari_available": tari_coeff_day > 0 and metrics.tari_mining,
        "tari_coeff_day": tari_coeff_day,  # XTM per H/s per day (long-run AVERAGE, not steady income)
        "tari_difficulty": tari_seconds_per_hs,  # seconds-to-block per H/s (client: diff / hashrate)
        "tari_reward": metrics.tari_reward,  # full XTM paid per Tari block (solo, lumpy)
        # Current-tier XvB expected reward, XMR/day, folded into the net-profit estimate (#712).
        # None unless XvB is on with a fresh published estimate for the tier the fleet holds now.
        "xvb_day": xvb_day,
        "pool_difficulty": metrics.pool_difficulty,  # for expected time-to-share (diff/hr)
        "block_reward": f"{reward_atomic / 1e12:.4f} XMR",  # context, server-formatted like NetworkCard
        "disclaimer": _EARNINGS_DISCLAIMER,
        # Confirmed on-chain payouts (#381), beside the estimate above. {"enabled": False} when the
        # view-only wallet feature is off — the UI then shows only the estimate.
        "confirmed": confirmed_payouts_summary(payouts),
        # Confirmed Tari payouts (#462), beside the Tari time-to-block estimate. XTM (microTari),
        # {"enabled": False} when the Tari view-only wallet feature is off.
        "tari_confirmed": confirmed_payouts_summary(
            tari_payouts, divisor=MICRO_PER_XTM, unit="xtm"
        ),
    }


def build_earnings_vs_actual(
    metrics, earnings, raffle_wins, now=None, expected_wins_day=None, realization=None
):
    """Expected-vs-actual summary — one row per income stream, for both views (#808).

    The comparison the operator otherwise assembles by hand across the Earnings tabs: the linear
    expectation over a trailing window beside what the view-only wallets confirmed over the SAME
    window (#381/#462). Expected uses the time-weighted routed P2Pool average over the window
    itself (``metrics.p2pool_7d``/``p2pool_30d``), not the current 1h figure — a fleet that grew
    or shrank mid-window would otherwise be judged against the wrong baseline.

    Every stream shares ONE trailing 30d window (#817 — mixed windows read as inconsistent, and
    30d is the shortest span that means something for all three). **Monero + XvB** is ONE
    combined row: an XvB win pays out through ordinary small payouts the payout table cannot
    attribute, so the confirmed actual already contains XvB XMR — comparing it against a
    P2Pool-only expectation overshoots on a winning box (#817). Both sides count XvB instead:
    expected = the P2Pool linear model + XvB's published per-day estimate × 30 (folded only when
    fresh; ``includes_xvb`` tells the client which label to draw), actual = every confirmed
    payout; ``pct`` compares like with like, and ``partial`` carries the confirmed window's
    may-be-incomplete flag. The XvB addend is TEMPERED by this wallet's measured win realization
    when enough wins exist to measure it (#866 — see ``xvb_realization``); the published face
    value stays in the tooltip via ``xvb_realization_pct``/``xvb_wins_measured``. **Tari** compares BLOCK COUNTS: solo merge-mining pays whole blocks,
    so the honest unit is blocks (expected = hashrate × window ÷ aux difficulty; actual =
    confirmed payout count, each payout being a found block), with the XTM sum alongside — no
    percent, a count that small is luck either way. **XvB** keeps only its win count and last-win
    recency — its XMR value lives in the combined row by construction.

    Raw numbers out; the client formats. ``actual``/``blocks``/``xtm`` are None while the matching
    payout-confirmation feature is off — the card then hints at the view key instead of showing a
    zero that would read as "earned nothing"."""
    now = now if now is not None else time.time()
    conf = earnings["confirmed"]
    tari_conf = earnings["tari_confirmed"]
    expected_p2pool = earnings["coeff_day"] * metrics.p2pool_30d * 30
    # Clamped: xvb_day is upstream-published (XvB's API); a hostile/corrupt negative would drag
    # the combined expectation to <= 0 while `available` stays True — an inverted pct at best, a
    # zero denominator at worst. A negative estimate is meaningless, so it folds as 0.
    expected_xvb = max(0.0, earnings["xvb_day"] or 0.0) * 30 if metrics.xvb_enabled else 0.0
    # Temper the XvB leg by what THIS wallet's wins measurably paid (#866): the published figure
    # prices bonus hashes at face value, which a production wallet realized ~19% of — folding it
    # untempered made the combined pct blame the P2Pool leg for XvB's optimism. With enough
    # measured wins (``realization``, computed once in build_state via ``xvb_realization``) the
    # leg scales down to the measured fraction; without them the published figure stands and the
    # client labels it face value.
    if realization and expected_xvb > 0:
        expected_xvb *= realization[0]
    else:
        realization = None
    xmr = {
        "available": expected_p2pool > 0,
        "expected_30d": expected_p2pool + expected_xvb,
        # True when XvB's published estimate is folded into expected — drives the row label. The
        # actual ALWAYS contains any win payouts; when XvB is on but the published figure is
        # stale, the tooltip owns the asymmetry rather than a fabricated estimate filling it.
        "includes_xvb": expected_xvb > 0,
        # Tempering context for the tooltip: the measured fraction and its sample size, or None
        # when the leg is the untempered published figure (or XvB is off).
        "xvb_realization_pct": round(realization[0] * 100) if realization else None,
        "xvb_wins_measured": realization[1] if realization else None,
        "enabled": bool(conf.get("enabled")),
        "actual_30d": conf.get("xmr_30d") if conf.get("enabled") else None,
        "partial": bool((conf.get("partial") or {}).get("30d")),
        "pct": None,
    }
    if xmr["available"] and xmr["enabled"]:
        xmr["pct"] = round((xmr["actual_30d"] or 0.0) / xmr["expected_30d"] * 100)
    # Expected Tari blocks over the window: hashrate × seconds ÷ difficulty (hashes-per-block).
    # Gated on tari_mining like the calculator, so a dead merge-mine channel shows "—", not 0.
    expected_blocks = (
        metrics.p2pool_30d * 30 * SECONDS_PER_DAY / metrics.tari_difficulty
        if metrics.tari_mining and metrics.tari_difficulty > 0
        else 0.0
    )
    tari = {
        "available": expected_blocks > 0,
        "expected_blocks_30d": expected_blocks,
        "enabled": bool(tari_conf.get("enabled")),
        "blocks_30d": tari_conf.get("n_30d") if tari_conf.get("enabled") else None,
        "xtm_30d": tari_conf.get("xtm_30d") if tari_conf.get("enabled") else None,
        "partial": bool((tari_conf.get("partial") or {}).get("30d")),
    }
    stamps = [w.get("ts", 0) or 0 for w in (raffle_wins or [])]
    xvb = {
        "enabled": metrics.xvb_enabled,
        "wins_30d": sum(1 for t in stamps if t >= now - 30 * SECONDS_PER_DAY),
        "last_win_ts": max(stamps, default=0),
        # The forecast the "—" used to stand in for (#866): win odds are computable from XvB's
        # own winners file (round-type frequency ÷ qualifier count), so publish them. None while
        # the aggregate is missing/stale — the client keeps the dash.
        "expected_wins_30d": expected_wins_day * 30 if expected_wins_day else None,
    }
    return {"xmr": xmr, "tari": tari, "xvb": xvb}


# XvB tier calculator copy (#118). A tier is RAFFLE status, never an XMR payout, and the winner is
# drawn at random among qualifiers — donating above the threshold buys zero extra win chance, so
# the honest framing is cost, not reward.
_XVB_TIER_NOTE = (
    "An XvB tier is raffle status, not an XMR payout. Donated hashrate earns no P2Pool shares; "
    "holding a tier costs about its threshold in continuous donation (XvB qualifies a tier on "
    "both the 1h and 24h credited averages), and donating above the threshold adds nothing — "
    "the raffle winner is drawn at random among qualifiers."
)

_XVB_SIDECHAIN_NOTE = (
    "Note: switching the P2Pool sidechain resets your PPLNS shares, and collecting an XvB win "
    "needs a share in the window."
)


def build_xvb_calc(metrics, state_mgr, realization=None):
    """XvB tier/raffle calculator inputs for the Advanced view (Issue #118).

    Same pattern as ``build_earnings``'s ``coeff_day``: the server publishes the tier table and
    the sustainability rule once (single source of truth — ``state_mgr.get_tiers()``, so a
    ``TIER_CONFIG`` override flows through, plus ``XVB_MAX_DONATION_FRACTION``), and the client
    does the what-if math (``computeXvbTier`` in ``logic.mjs``, a transcription of
    ``resolve_target_threshold``'s auto rule). Current/target tier state comes straight off
    ``Metrics`` — no tier math is re-derived here.

    The draw is random among qualifiers, but the winners file publishes the qualifier count per
    round (#872), so each tier carries its measurable draw context: ``win_odds_day`` (that round
    type's frequency ÷ its average qualifiers — per-round-type, unlike the earnings card's
    cumulative forecast) and ``players_avg`` (which also makes a single-qualifier artifact like
    Mega's self-evident). ``realized_reward_year`` scales the published figure by this wallet's
    measured win realization (``realization``, from ``xvb_realization``) — None when unmeasured,
    so the client falls back to face value and says so. Returns ``{"enabled": False}`` alone when
    XvB is off — there is no tier to calculate."""
    if not metrics.xvb_enabled:
        return {"enabled": False}
    tiers = state_mgr.get_tiers()
    round_state = state_mgr.get_xvb_round_stats()
    round_types = (
        {}
        if xvb_stats_are_stale(round_state)
        else ((round_state.get("stats") or {}).get("types") or {})
    )
    span_days = ((round_state.get("stats") or {}).get("span_days") or 0.0) if round_types else 0.0

    def _odds_day(key):
        agg = round_types.get(key)
        if not agg or span_days <= 0 or agg.get("players_avg", 0) <= 0:
            return None
        return (agg["rounds"] / span_days) / agg["players_avg"]

    # XvB's published per-tier expected reward (XMR/year), fetched over Tor and cached (#118). The
    # tier KEY is exactly the round-type in the file (donor / donor_vip / donor_whale / donor_mega),
    # so a tier maps to its estimate by key. A stale or empty cache degrades to None per tier +
    # estimates_available False — the client shows "estimate unavailable", never a frozen number
    # implied fresh (reusing the stats staleness rule so the two never disagree, #311).
    est_state = state_mgr.get_xvb_reward_estimates()
    estimates = (est_state or {}).get("estimates") or {}
    estimates_stale = xvb_stats_are_stale(est_state)
    estimates_available = bool(estimates) and not estimates_stale
    return {
        "enabled": True,
        # Ascending tier table for the client's what-if; names via get_tier_info so they read
        # exactly like the tier strings everywhere else (threshold already embedded in the name).
        # expected_reward_year is XvB's own figure for the tier, or None when unavailable/stale.
        "tiers": sorted(
            (
                {
                    "name": get_tier_info(t, tiers)[0],
                    "threshold": float(t),
                    "expected_reward_year": (
                        float(estimates[key]) if estimates_available and key in estimates else None
                    ),
                    # Published figure × measured realization (#872) — the net the panel can
                    # honestly act on. None until enough wins measure the factor.
                    "realized_reward_year": (
                        float(estimates[key]) * realization[0]
                        if estimates_available and key in estimates and realization
                        else None
                    ),
                    "win_odds_day": _odds_day(key),
                    "players_avg": (round_types.get(key) or {}).get("players_avg"),
                }
                for key, t in tiers.items()
                if t > 0
            ),
            key=lambda entry: entry["threshold"],
        ),
        "estimates_available": estimates_available,
        "estimates_stale": estimates_stale,
        # Measurement context for the realized figures: the factor and its sample size, or None
        # while unmeasured (the client then labels the published number face value).
        "realization_pct": round(realization[0] * 100) if realization else None,
        "realization_wins": realization[1] if realization else None,
        "max_fraction": XVB_MAX_DONATION_FRACTION,  # donation headroom rule (sustainability)
        "current_tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "target_threshold": metrics.target_threshold,
        "sustainable": metrics.target_sustainable,
        "note": _XVB_TIER_NOTE,
        # #33 mode context, display-only: off the Main sidechain a pool switch costs your PPLNS
        # shares — and with them XvB win collectability. None on Main (nothing to warn about).
        "mode_note": _XVB_SIDECHAIN_NOTE if metrics.pool_type != "Main" else None,
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


def build_worker_detail(name, data, state_mgr):
    """Per-worker Inspect payload (#185): the rig's current enriched telemetry, the writable config
    the dashboard last applied (the editor prefill — the rig's feed does not expose the writable
    config values, so Pithead's own last-applied record is the honest source), and the change history
    (each row's ``changes`` is a diff by construction, since we only ever record deltas we authored).
    ``hashrate_by_config`` (#492) is that same version timeline with each version's measured
    hashrate (worker_history) aggregated over its active window, so an operator can compare config
    versions empirically.

    ``editable`` is whether the worker has an operator-set ``host`` in ``dashboard.workers[]`` — the
    precondition for the host-side write path. The rig's token is masked out of this container (#440),
    so the container cannot verify it; the host runner re-checks it and fails closed if it is missing.
    """
    workers = data.get("workers", []) if data else []
    worker = next((w for w in workers if w.get("name") == name), None)
    descriptor = next((e for e in config.DASHBOARD_WORKERS if e["name"] == name), None)
    history = state_mgr.get_worker_config_history(name)
    for row in history:
        ts = row.get("ts")
        row["applied_at"] = format_time_abs(ts) if ts else ""
    hashrate_by_config = state_mgr.get_worker_hashrate_by_config(name)
    for row in hashrate_by_config:
        ts = row.get("ts")
        row["applied_at"] = format_time_abs(ts) if ts else ""
        for key in ("avg_h15", "min_h15", "max_h15"):
            row[key] = format_hashrate(row[key]) if row[key] is not None else None
    return {
        "name": name,
        "found": worker is not None,
        # A worker is editable only if the operator pinned its host in config.json — never a
        # miner-advertised address (#122). control_enabled gates whether the write path exists at all.
        "editable": bool(descriptor and descriptor.get("host")),
        "control_enabled": config.DASHBOARD_CONTROL_ENABLED,
        "status": worker.get("status") if worker else None,
        "hashrate": format_hashrate(worker.get("h60", 0)) if worker else None,
        "rigforge": _rigforge_display(worker.get("rigforge")) if worker else None,
        # {available, latest, url} | None — this rig runs an older RigForge (#596).
        "rigforge_update": rigforge_update_for(worker, (data or {}).get("rigforge_release")),
        "writable_keys": sorted(WORKER_WRITABLE_KEYS),
        "last_applied": state_mgr.get_last_applied_worker_config(name),
        "history": history,
        "hashrate_by_config": hashrate_by_config,
    }


def visible_update(update, running=None):
    """The new-release badge, only when it is self-consistent (#664).

    A restored snapshot can resurrect a pre-upgrade ``{available, latest, url}`` right after the
    upgrade it advertised — and "new release X available" while *running* X is contradictory by
    definition, whatever put it in the state. Suppress the badge whenever ``latest`` is not
    strictly newer than the running version. A dev build (unparseable running version) keeps the
    badge, mirroring ``compute_update``'s own semantics. Pure + unit-tested."""
    if not update:
        return None
    if running is None:
        running = (resolve_version() or {}).get("text")
    rv = parse_semver(running)
    lv = parse_semver(update.get("latest"))
    if rv and lv and lv <= rv:
        return None
    return update


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
    raffle_wins = state_mgr.get_raffle_wins()  # rounds this wallet won, from XvB's winners file
    # Confirmed on-chain payouts (#381): fetched once when the view-only wallet feature is on (else
    # None), fed to both the earnings totals and the chart markers. config read at call time so
    # tests can flip the flag per-app.
    monero_payouts = state_mgr.get_payouts("monero") if config.PAYOUT_CONFIRM_ENABLED else None
    metrics = build_metrics(data, state_mgr, history)
    db_healthy = state_mgr.is_db_healthy()

    mode_tok, p2p_tok, xvb_tok = _mode_palette(metrics.mode)
    pool_net = build_pool_network(data, metrics)

    # Built once, consumed twice: the Earnings card reads the full payload, the expected-vs-actual
    # summary (#808) rolls the same figures up — one build, so the two can't disagree.
    earnings = build_earnings(
        data,
        metrics,
        payouts=monero_payouts,
        tari_payouts=(
            state_mgr.get_payouts("tari") if config.TARI_PAYOUT_CONFIRM_ENABLED else None
        ),
        xvb_day=xvb_current_tier_reward_day(metrics, state_mgr),
    )

    # XvB honesty figures (#866/#872), computed once and shared by the earnings summary and the
    # tier calculator so the two can never disagree: the forecast win rate from XvB's own winners
    # file, and the measured fraction of the published reward this wallet's wins actually paid.
    xvb_wins_day = xvb_realized = None
    if metrics.xvb_enabled:
        xvb_tiers = state_mgr.get_tiers()
        xvb_wins_day = xvb_expected_wins_day(
            state_mgr.get_xvb_round_stats(), xvb_current_tier_key(metrics, xvb_tiers), xvb_tiers
        )
        xvb_realized = xvb_realization(
            monero_payouts, raffle_wins, earnings["xvb_day"], xvb_wins_day
        )

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
        # The operator-facing stratum port (#172) — feeds the "point your rigs at host:PORT" hint.
        "stratum_port": config.STRATUM_PORT,
        "version": resolve_version(),
        # {available, latest, url} | None — new-release badge (#224), self-consistency-guarded:
        # never advertise the version already running (#664).
        "update": visible_update(data.get("update")),
        # Whether the control channel is on (#33) — gates the header Upgrade button (#59). The
        # routes 404 when off, so this is display gating only, not a security control. Read at
        # call time (module attribute, not from-import) so tests can flip the flag per-app.
        "control_enabled": config.DASHBOARD_CONTROL_ENABLED,
        # #559: use the snapshot's own timestamp, not now — a restored stale snapshot must
        # report its true age; falls back to now only when timestamp is missing/0.
        "last_update": format_time_abs(data.get("timestamp") or time.time()),
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
        "raffle_wins": build_raffle_log(raffle_wins),
        "proxy_workers": metrics.workers_online,
        # Confirmed payouts (#381): the stored list rides in when the feature is on, else None
        # (feature off → earnings shows only the estimate). Built above, before the payload.
        "earnings": earnings,
        # Expected vs actual, one row per stream (#808) — the Simple view's earnings figure.
        "earnings_summary": build_earnings_vs_actual(
            metrics,
            earnings,
            raffle_wins,
            expected_wins_day=xvb_wins_day,
            realization=xvb_realized,
        ),
        "xvb_calc": build_xvb_calc(metrics, state_mgr, realization=xvb_realized),
        # On a backup stack, the XvB controller state last pulled from the primary (#249) — held as
        # standby, adopted only at failover. None on a single stack (nothing pulls). Inspectable so
        # an operator can confirm the backup is warm before it takes over.
        "xvb_standby": state_mgr.get_xvb_standby(),
        "tari": build_tari(data),
        "workers": build_workers(data.get("workers", []), data.get("rigforge_release")),
        # Fleet power draw / efficiency and (once a price is set) net profit after power (#260),
        # with live feed prices (#520) when dashboard.energy.price_feed is on.
        "energy": build_energy(data.get("workers", []), data.get("prices")),
        "proxy_summary": build_proxy_summary(data),
        # Persisted per-poll share-health deltas + trailing 24h reject rate (#116). Kept out of
        # proxy_summary so its (cumulative) shape stays unchanged for existing clients.
        "share_stats": build_share_stats(share_stats, range_arg, window),
        "reject_pct_24h": _window_reject_pct(share_stats, 24 * 3600),
        # #196 Tier-1 telemetry backbone exposure: block-found events, hourly disk-growth
        # samples, and ~5-min XvB-credited samples. No chart renders these yet — that's the
        # deliberate next slice — the payload just carries the persisted series.
        "blocks": build_blocks(state_mgr.get_blocks(), range_arg, window),
        # Confirmed payouts per chain as timeline points ({x: ms, amount: atomic}), same
        # range/window bounds as blocks. Feeds the mine cart train's Tari marker; empty lists
        # while payout confirmation is off.
        "payouts": build_payouts(state_mgr, range_arg, window),
        "disk_growth": build_disk_growth(state_mgr.get_disk_growth(), range_arg, window),
        "xvb_history": build_xvb_history(state_mgr.get_xvb_history(), range_arg, window),
        "egress": egress,
        "topology": topology,
        "chart": build_chart(
            history,
            data.get("shares", []),
            range_arg,
            window,
            avg_window,
            events=state_mgr.get_events(),
            raffle_wins=raffle_wins,
            payouts=monero_payouts,
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
