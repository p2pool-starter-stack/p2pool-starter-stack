"""View layer for the dashboard: turn the computed :class:`Metrics` (plus a little passthrough
from ``latest_data``) into the structured ``/api/state`` payload the Preact client renders.

Separation of concerns (Issue #61): the *domain* values are computed once in
``service/metrics.py``; this layer only **formats at the edge** — display strings
(``"10.50 kH/s"``) and presentation tokens (``variant: "ok"``, ``level: "high"``) — and never
emits HTML. The client maps tokens to CSS classes and builds the DOM.

``build_state`` is the single assembly point and the contract the ``/api/state`` endpoint and
the client share; ``server.py`` stays pure transport.
"""
import os
import math
import time
import bisect
import logging

from mining_dashboard.config.config import HOST_IP, UPDATE_INTERVAL
from mining_dashboard.helper.utils import format_hashrate, format_duration, format_time_abs
from mining_dashboard.service.metrics import build_metrics
from mining_dashboard.service.earnings import xmr_per_hs_day
from mining_dashboard.version import resolve_version

logger = logging.getLogger("WebViews")

# Preset range -> window length in seconds. 'all'/unknown -> use the data's own extent.
_RANGE_SECONDS = {'1h': 3600, '24h': 86400, '1w': 604800, '1m': 2592000}

# Adaptive chart resolution (Issue #47). Point count and line smoothing are chosen from the
# *visible window duration*: a wide span is a smooth, high-level overview (fewer points, more
# curve smoothing); a short span keeps full 30s detail (choppier but accurate). The point count
# is capped near the canvas pixel width — more points than pixels just slows hit-testing.
# (limit_seconds, target_points); 0 target = send native resolution (no downsampling).
_POINT_TIERS = ((3600, 0), (21600, 360), (86400, 480), (604800, 600))
_MAX_CHART_POINTS = 700   # > 1w, and the hard ceiling (~1 point per canvas pixel)

# (limit_seconds, tension). Chart.js line tension = curve smoothing.
_TENSION_TIERS = ((3600, 0.0), (86400, 0.2), (604800, 0.35))
_MAX_TENSION = 0.4        # > 1w: smooth / high-level


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
_TOKEN_GREEN = "ok"       # P2Pool active
_TOKEN_PURPLE = "purple"  # XvB active
_TOKEN_BLUE = "accent"    # split / neutral mode
_TOKEN_MUTED = "muted"    # inactive pool

_LOW_HR_TITLE = ("Your hashrate can't sustain the selected XvB donation tier; "
                 "donation will fall short of it.")


# --------------------------------------------------------------------------------------
# Chart series (Issue #65: positioned by real time, with outage gaps as breaks).
# --------------------------------------------------------------------------------------

def build_chart(history, shares, range_arg, window=None):
    """Build the Chart.js datasets from history. Each point carries its real timestamp as the
    x value (epoch ms) so a linear time axis spaces points to scale; runs of missing samples
    (outages) are split by a ``null`` break so the line doesn't connect across the gap.

    ``window`` is an optional ``(from, to)`` epoch-second pair (a manual zoom) that bounds both
    ends and overrides ``range_arg``. Point density and ``tension`` adapt to the visible window
    duration (Issue #47).

    Returns ``{"p2pool": [{x, y}], "xvb": [{x, y}], "shares": [{x, y, r, c}], "tension": float}``
    — the P2Pool/XvB series are stacked on the client (they sum to the total hashrate) and may
    contain ``{x, y: None}`` break markers, kept index-aligned across both series so stacking
    stays correct; ``shares`` is a sparse scatter (rendered un-stacked)."""
    filtered_history, filtered_shares = _filter_range(history, shares, range_arg, window)
    duration_s = _window_duration(filtered_history, range_arg, window)
    filtered_history = _downsample_history(filtered_history, duration_s)

    timestamps = [x['timestamp'] for x in filtered_history]
    gap_after = _gap_after_indices(timestamps)

    p2pool = []
    xvb = []
    for i, x in enumerate(filtered_history):
        vp, vx = _split_values(x)
        x_ms = int(timestamps[i] * 1000)
        p2pool.append({"x": x_ms, "y": vp})
        xvb.append({"x": x_ms, "y": vx})
        if i in gap_after:
            mid_ms = int(((timestamps[i] + timestamps[i + 1]) / 2) * 1000)
            p2pool.append({"x": mid_ms, "y": None})
            xvb.append({"x": mid_ms, "y": None})

    return {"p2pool": p2pool, "xvb": xvb,
            "shares": _share_points(filtered_history, filtered_shares),
            "tension": _chart_tension(duration_s)}


def _filter_range(history, shares, range_arg, window=None):
    """Restrict history/shares to the selected window. A custom ``window`` (from, to) epoch
    seconds bounds both ends; otherwise the preset ``range`` bounds only the lower end (``all``
    keeps everything)."""
    if window is not None:
        lo, hi = window
        return ([x for x in history if lo <= x['timestamp'] <= hi],
                [s for s in shares if lo <= s['ts'] <= hi])
    if range_arg == 'all':
        return history, shares
    target_seconds = _RANGE_SECONDS.get(range_arg, 0)
    if target_seconds <= 0:
        return history, shares
    cutoff = time.time() - target_seconds
    return ([x for x in history if x['timestamp'] >= cutoff],
            [s for s in shares if s['ts'] >= cutoff])


def _window_duration(filtered_history, range_arg, window):
    """Seconds the chart currently spans — drives adaptive resolution/smoothing. From the
    window if zoomed, else the preset length, else (``all``/unknown) the actual data extent."""
    if window is not None:
        return max(0, window[1] - window[0])
    secs = _RANGE_SECONDS.get(range_arg, 0)
    if secs > 0:
        return secs
    if len(filtered_history) >= 2:
        return filtered_history[-1]['timestamp'] - filtered_history[0]['timestamp']
    return 0


def _split_values(x):
    """(p2pool, xvb) hashrate for a history row, with the legacy-data P2Pool fallback."""
    v = x.get('v', 0)
    vp = x.get('v_p2pool', 0)
    vx = x.get('v_xvb', 0)
    if vp == 0 and vx == 0 and v > 0:
        vp = v
    return vp, vx


def _gap_after_indices(timestamps):
    """Indices ``i`` after which the gap to ``i+1`` is large enough to be an outage break."""
    if len(timestamps) < 2:
        return set()
    deltas = [timestamps[i + 1] - timestamps[i] for i in range(len(timestamps) - 1)]
    median = sorted(deltas)[len(deltas) // 2]
    threshold = max(_GAP_FACTOR * median, 2 * UPDATE_INTERVAL)
    return {i for i, d in enumerate(deltas) if d > threshold}


def _downsample_history(filtered_history, duration_s):
    """Bucket-averages history down to the duration's target point count (Issue #47). A target
    of 0, or a series already at/under target, is returned untouched — so short/zoomed-in
    windows keep their native 30s detail."""
    target = _target_points(duration_s)
    if target <= 0 or len(filtered_history) <= target:
        return filtered_history

    chunk_size = len(filtered_history) / target
    downsampled = []
    for i in range(target):
        chunk = filtered_history[int(i * chunk_size):int((i + 1) * chunk_size)]
        if not chunk:
            continue
        mid = chunk[len(chunk) // 2]
        downsampled.append({
            't': mid['t'],
            'timestamp': mid['timestamp'],
            'v': round(sum(x.get('v', 0) for x in chunk) / len(chunk), 2),
            'v_p2pool': round(sum(x.get('v_p2pool', 0) for x in chunk) / len(chunk), 2),
            'v_xvb': round(sum(x.get('v_xvb', 0) for x in chunk) / len(chunk), 2),
        })
    return downsampled


def _share_points(filtered_history, filtered_shares):
    """Sparse share markers: bucket each share onto its nearest history sample and emit one
    ``{x, y, r, c}`` point per sample that has shares (x = sample time ms, y = lifted above the
    line, r = radius scaled by count, c = count)."""
    if not (filtered_history and filtered_shares):
        return []

    hist_ts = [x['timestamp'] for x in filtered_history]
    counts = {}
    for s in filtered_shares:
        s_ts = s['ts']
        idx = bisect.bisect_left(hist_ts, s_ts)
        candidates = []
        if idx < len(hist_ts): candidates.append(idx)
        if idx > 0: candidates.append(idx - 1)
        if candidates:
            closest_idx = min(candidates, key=lambda i: abs(hist_ts[i] - s_ts))
            counts[closest_idx] = counts.get(closest_idx, 0) + 1

    points = []
    for idx in sorted(counts):
        count = counts[idx]
        v = filtered_history[idx].get('v', 0)
        # Lift the marker 10% above the line so it doesn't sit on the curve; floor to 100 for
        # zero-hashrate samples so it stays visible.
        points.append({
            "x": int(hist_ts[idx] * 1000),
            "y": v * 1.1 if v > 0 else 100,
            "r": min(6 + (count * 3), 15),
            "c": count,
        })
    return points


# --------------------------------------------------------------------------------------
# Section builders: Metrics (+ passthrough) -> display data.
# --------------------------------------------------------------------------------------

def _mode_palette(current_mode):
    """(mode, p2p, xvb) palette tokens for the algo mode. Checked most-specific first:
    "XVB (Split)" contains both "Split" and "XVB"."""
    if "Split" in current_mode:
        return _TOKEN_BLUE, _TOKEN_GREEN, _TOKEN_PURPLE   # both pools active
    if "XVB" in current_mode:
        return _TOKEN_PURPLE, _TOKEN_MUTED, _TOKEN_PURPLE
    return _TOKEN_GREEN, _TOKEN_GREEN, _TOKEN_MUTED        # P2POOL


def build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok):
    """The hashrate/mode/tier values shown across the dashboard, formatted from Metrics."""
    return {
        "mode_name": metrics.mode,
        "mode_variant": mode_tok,
        "total": format_hashrate(metrics.total_h15),
        "p2p_1h": format_hashrate(metrics.p2pool_1h),
        "p2p_24h": format_hashrate(metrics.p2pool_24h),
        "p2p_variant": p2p_tok,
        "xvb_1h": format_hashrate(metrics.xvb_1h),
        "xvb_24h": format_hashrate(metrics.xvb_24h),
        "xvb_routed": format_hashrate(metrics.xvb_routed),
        "xvb_variant": xvb_tok,
        "tier": metrics.current_tier,
        "target_tier": metrics.target_tier,
        "xvb_fail_count": metrics.xvb_fail_count,
        "xvb_updated": format_time_abs(metrics.xvb_last_update),
        "low_hr": {"text": "⚠ Hashrate low for tier", "title": _LOW_HR_TITLE} if metrics.low_hr_warning else None,
    }


def build_pool_network(data, metrics):
    """P2Pool / Stratum / Monero-network display values (computed bits come from Metrics)."""
    stratum = data.get('stratum', {})
    local_pool = data.get('pool', {}).get('pool', {})
    p2p = data.get('pool', {}).get('p2p', {})
    network = data.get('network', {})
    s_addr = stratum.get('wallet', 'Unknown')

    return {
        "stratum": {
            "h15": format_hashrate(metrics.stratum_h15),
            "h1h": format_hashrate(metrics.stratum_h1h),
            "h24h": format_hashrate(metrics.stratum_h24h),
            "shares": f"{stratum.get('shares_found',0)} / {stratum.get('shares_failed',0)}",
            "effort": f"{stratum.get('current_effort', 0):.1f}%",
            "total_shares": stratum.get('total_stratum_shares', 0),
            "reward_pct": f"{stratum.get('block_reward_share_percent', 0):.4f}%",
            "conns": stratum.get('connections', 0),
            "last_share": format_time_abs(stratum.get('last_share_found_time', 0)),
            "total_hashes": stratum.get('total_hashes', 0),
            "wallet": s_addr,
            "wallet_short": _shorten(s_addr),
        },
        "pool": {
            "type": metrics.pool_type,
            "sidechain_height": local_pool.get('sidechain_height', 0),
            "diff": f"{metrics.pool_difficulty/1e6:.2f} M",
            "hr": format_hashrate(metrics.pool_hashrate),
            "total_hashes": local_pool.get('total_hashes', 0),
            "miners": local_pool.get('miners', 0),
            "pplns_win": f"{metrics.pplns_window} ({format_duration(metrics.pplns_window * metrics.block_time)})",
            "pplns_wgt": local_pool.get('pplns_weight', 0),
            "blocks": local_pool.get('blocks_found', 0),
            "last_blk": format_time_abs(local_pool.get('last_block_ts', 0)),
            "peers": f"{p2p.get('out_peers',0)} / {p2p.get('in_peers',0)}",
            "uptime": format_duration(p2p.get('uptime', 0)),
        },
        "network": {
            "height": metrics.network_height,
            "reward": f"{network.get('reward', 0)/1e12:.4f} XMR",
            "diff": f"{metrics.network_difficulty/1e9:.2f} G",
            "hash": _shorten(str(network.get('hash', 'N/A')), threshold=20),
            "ts": format_time_abs(network.get('timestamp', 0)),
        },
        "monero": {"mode": metrics.monero_mode, "db_size": _monero_db_size(data.get('monero_sync', {}))},
        "shares_window": {"count": metrics.shares_in_window, "ok": metrics.shares_in_window > 0},
    }


def _monero_db_size(monero_sync):
    """Human-readable on-disk Monero DB size (Issue #32); em-dash when unknown."""
    db_bytes = monero_sync.get('db_size', 0) or 0
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
_REJECT_FLAG_RATE = 0.05   # >= 5% of submitted shares rejected
_REJECT_FLAG_MIN = 3       # and at least this many rejects


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
    system = data.get('system', {})

    disk_usage = system.get('disk', {})
    disk_percent = disk_usage.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""

    mem_usage = system.get('memory', {})
    cpu_str = system.get('cpu_percent', "0.0%")
    try:
        cpu_val = float(cpu_str.strip('%'))
    except ValueError:
        cpu_val = 0.0

    load_raw = system.get('load', "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = (f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}"
                if len(load_parts) == 3 else load_raw)

    hp_status, hp_class, hp_val = system.get('hugepages', ["Disabled", "status-bad", "0/0"])

    return {
        "cpu": {"percent": cpu_str, "load": load_avg, "level": _usage_level(cpu_val)},
        "mem": {
            "used": f"{mem_usage.get('used_gb', 0):.1f}",
            "total": f"{mem_usage.get('total_gb', 0):.1f}",
            "percent": mem_usage.get('percent_str', '0%'),
            "level": _usage_level(mem_usage.get('percent', 0)),
        },
        "disk": {
            "used": f"{disk_usage.get('used_gb', 0):.1f}",
            "total": f"{disk_usage.get('total_gb', 0):.1f}",
            "percent": disk_usage.get('percent_str', '0%'),
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
    sorted_workers = sorted(workers, key=lambda x: (x['status'] != 'online', x['name']))

    for worker in sorted_workers:
        try:
            active_pool = worker.get('active_pool', '')
            if any(p in active_pool for p in ['3333', '37889', '37888', '37890']):
                pool = "p2pool"
            elif any(p in active_pool for p in ['3344', '4247']):
                pool = "xvb"
            else:
                pool = "unknown"

            uptime = worker.get('uptime', 0)
            h10 = worker.get('h10', 0)
            h60 = worker.get('h60', 0)
            h15 = worker.get('h15', 0)
            # Per-worker share health (Issue #82). Raw counts for client-side sorting; a display
            # string that appends invalid only when it's non-zero (keeps the common case clean);
            # and an optional warning flag the client renders when the reject rate is high.
            accepted = worker.get('accepted', 0)
            rejected = worker.get('rejected', 0)
            invalid = worker.get('invalid', 0)
            rejected_str = f"{rejected:,} (+{invalid:,} inv)" if invalid else f"{rejected:,}"
            rows.append({
                "name": worker['name'],
                "ip": worker['ip'],
                "ip_sort": _ip_to_sort_int(worker.get('ip', '0.0.0.0')),
                "pool": pool,
                "status": "online" if worker['status'] == 'online' else "offline",
                "uptime": uptime, "uptime_str": format_duration(uptime),
                "h10": h10, "h10_str": format_hashrate(h10),
                "h60": h60, "h60_str": format_hashrate(h60),
                "h15": h15, "h15_str": format_hashrate(h15),
                "accepted": accepted, "accepted_str": f"{accepted:,}",
                "rejected": rejected, "rejected_str": rejected_str,
                "invalid": invalid,
                "reject_flag": _reject_flag(accepted, rejected),
            })
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return rows


def build_proxy_summary(data):
    """Pool-wide share-health totals from the xmrig-proxy ``/summary`` (Issue #82): cumulative
    accepted/rejected/invalid/expired shares submitted to the upstream pool, the aggregate reject
    rate, and the best difficulty found. ``has_data`` is False until the proxy has been polled (no
    shares yet) so the client can hide an all-zero footer."""
    summary = data.get('proxy_summary', {}) or {}
    accepted = summary.get('accepted', 0) or 0
    rejected = summary.get('rejected', 0) or 0
    invalid = summary.get('invalid', 0) or 0
    expired = summary.get('expired', 0) or 0
    best = summary.get('best', 0) or 0

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
        a, b, c, d = (int(part) for part in ip.split('.'))
        return (a << 24) + (b << 16) + (c << 8) + d
    except (ValueError, IndexError, AttributeError):
        return 0


def build_tari(data):
    """Tari merge-mining display values. ``status`` is plain text; the client adds the ✔."""
    tari_stats = data.get('tari', {})
    tari_active = tari_stats.get('active', False)
    t_addr = tari_stats.get('address', 'Unknown')

    return {
        "active": tari_active,
        "status": tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...',
        "reward": f"{tari_stats.get('reward', 0):.2f} TARI",
        "height": str(tari_stats.get('height', 0)),
        "diff": f"{int(tari_stats.get('difficulty', 0)):,}",
        "wallet": t_addr,
        "wallet_short": _shorten(t_addr),
    }


def build_sync(metrics, monero_db_size):
    """Sync-screen state for both chains, mapping each SyncMetric to the client's 3-state
    gauge: 'loading' (no target yet), 'done' (fully synced), else 'syncing'."""
    def section(sm, extra=None):
        state = "loading" if not sm.has_target else ("done" if sm.done else "syncing")
        out = {"state": state, "percent": sm.percent, "current": sm.current,
               "target": sm.target, "remaining": sm.remaining}
        if extra:
            out.update(extra)
        return out

    return {
        "monero": section(metrics.monero, {"mode": metrics.monero_mode, "db_size": monero_db_size}),
        "tari": section(metrics.tari),
    }


def build_badges(data, metrics, mode_variant):
    """Top-bar status badges as data: ``{text, variant, title?}`` (Issues #27/#31/#35/#51/#32).
    The client renders them (variant -> ``badge-<variant>``)."""
    badges = []
    if metrics.global_syncing:
        badges.append({"text": "Syncing...", "variant": "warn"})
    else:
        badges.append({"text": metrics.mode, "variant": mode_variant})
        badges.append({"text": f"P2Pool {metrics.pool_type}", "variant": "outline"})
        if metrics.low_hr_warning:
            badges.append({"text": "⚠ Hashrate low for tier", "variant": "warn", "title": _LOW_HR_TITLE})

    # Node-down badges (Issue #31) — shown whenever a node is unreachable, regardless of sync.
    if metrics.monero.down:
        badges.append({"text": "monerod DOWN", "variant": "bad"})
    if metrics.tari.down:
        badges.append({"text": "Tari DOWN", "variant": "bad"})
    if data.get('workers_rejected'):
        badges.append({"text": "Workers rejected", "variant": "bad",
                       "title": "Workers rejected so they fail over to their backup pools"})
    # Miner held until required chain(s) finish their initial sync (Issue #35).
    if data.get('miner_held'):
        badges.append({"text": "Miner held (sync)", "variant": "warn",
                       "title": "p2pool and xmrig-proxy are held until the required chains finish syncing"})
    # Non-blocking Tari (Issue #51): stay operational, surface a top-bar badge with the live
    # percentage once known (omitted early so it isn't a stale "0%").
    if data.get('tari_syncing_passive'):
        t_pct = metrics.tari.percent
        label = f'Tari syncing {t_pct}%' if t_pct > 0 else 'Tari syncing'
        badges.append({"text": label, "variant": "warn",
                       "title": "Tari is still syncing — merge mining resumes when it catches up; Monero mining continues"})
    # Monero pruned/full badge (Issue #32) — only when known (local node).
    if metrics.monero_mode == "Pruned":
        badges.append({"text": "XMR Pruned", "variant": "outline", "title": "Monero blockchain is pruned"})
    elif metrics.monero_mode == "Full":
        badges.append({"text": "XMR Full", "variant": "outline", "title": "Monero blockchain is full (not pruned)"})

    return badges


# --------------------------------------------------------------------------------------
# Earnings calculator (Issue #12): expected-XMR inputs for the Advanced view.
# --------------------------------------------------------------------------------------

_EARNINGS_DISCLAIMER = (
    "Estimated XMR from P2Pool mining only — excludes XvB donations (donated hashrate earns no "
    "P2Pool payout) and Tari merge-mining. Expected values only; mining is variance-heavy, so "
    "real payouts swing well above and below these figures. Estimates, not guarantees."
)


def build_earnings(data, metrics):
    """Expected-XMR-from-P2Pool calculator inputs for the Advanced view (Issue #12).

    This is a **P2Pool** mining calculator: it estimates the XMR earned by the hashrate that is
    actually mining on your P2Pool node — *not* the rig's total output. The what-if default is
    ``p2pool_1h`` — the **same P2Pool 1h-average hashrate shown in the header / Overview / My Node
    cards** (a time-weighted average of the recorded P2Pool hashrate), so the figure here matches
    those exactly. That recorded average already excludes any XvB-donated slice (XvB hashrate is a
    separate series), which is why an active XvB split doesn't inflate the estimate. Tari
    merge-mining earnings are a separate thing entirely (deferred, #117).

    Publishes the earnings **rate** (XMR per H/s per day, from ``service/earnings``) plus that
    P2Pool hashrate and the P2Pool share difficulty. The client scales the rate to the entered
    *what-if* hashrate and formats the day/month/year figures + expected time-to-share — sending
    a rate (not pre-formatted earnings) keeps the live recompute a single source of truth with no
    duplicated math (see ``web/static/logic.mjs``).

    ``available`` is False when the network figures needed for the rate are missing; the client
    then shows ``—`` instead of a bogus estimate (graceful degradation)."""
    reward_atomic = (data.get('network', {}) or {}).get('reward', 0) or 0
    coeff_day = xmr_per_hs_day(reward_atomic, metrics.network_difficulty)
    # Reuse the displayed P2Pool 1h average (header / Overview / My Node) so the calculator's
    # hashrate is consistent with the rest of the dashboard — and because that recorded average
    # already excludes the XvB-donated portion, it's the honest basis for a P2Pool estimate.
    p2pool_hr = metrics.p2pool_1h
    return {
        "available": coeff_day > 0,
        "p2pool_hr": p2pool_hr,                             # raw H/s — the what-if default
        "p2pool_hr_str": format_hashrate(p2pool_hr),
        "coeff_day": coeff_day,                              # XMR per H/s per day
        "pool_difficulty": metrics.pool_difficulty,         # for expected time-to-share (diff/hr)
        "block_reward": f"{reward_atomic / 1e12:.4f} XMR",  # context, server-formatted like NetworkCard
        "disclaimer": _EARNINGS_DISCLAIMER,
    }


# --------------------------------------------------------------------------------------
# Assembly.
# --------------------------------------------------------------------------------------

def build_state(data, state_mgr, range_arg, window=None):
    """Assemble the full ``/api/state`` payload — the contract the client renders against.

    ``window`` is an optional ``(from, to)`` epoch-second manual-zoom window (Issue #47) that
    overrides ``range_arg`` for the chart. Computes domain values once (``build_metrics``), then
    formats each section. Every value is a JSON-serializable primitive, list or dict. May raise
    (e.g. ``state_mgr.get_history`` failing); the caller turns that into a sanitized 500."""
    data = data or {}
    history = state_mgr.get_history()
    metrics = build_metrics(data, state_mgr, history)

    mode_tok, p2p_tok, xvb_tok = _mode_palette(metrics.mode)
    pool_net = build_pool_network(data, metrics)

    return {
        "syncing": metrics.global_syncing,
        "page_title": "Mining Dashboard - Syncing" if metrics.global_syncing else "Mining Dashboard",
        "host_ip": HOST_IP,
        "version": resolve_version(),
        "last_update": format_time_abs(time.time()),
        "range": range_arg,
        "window": {"from": window[0], "to": window[1]} if window else None,
        "badges": build_badges(data, metrics, mode_tok),
        "hashrate": build_hashrate(metrics, mode_tok, p2p_tok, xvb_tok),
        "system": build_system(data),
        "sync": build_sync(metrics, pool_net["monero"]["db_size"]),
        "stratum": pool_net["stratum"],
        "pool": pool_net["pool"],
        "network": pool_net["network"],
        "monero": pool_net["monero"],
        "shares_window": pool_net["shares_window"],
        "proxy_workers": metrics.workers_online,
        "earnings": build_earnings(data, metrics),
        "tari": build_tari(data),
        "workers": build_workers(data.get('workers', [])),
        "proxy_summary": build_proxy_summary(data),
        "chart": build_chart(history, data.get('shares', []), range_arg, window),
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
            with open(SHELL_PATH, 'r') as f:
                _SHELL_CACHE = f.read()
            _SHELL_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading shell: {e}")
    return _SHELL_CACHE or "<h1>Dashboard shell error</h1>"
