"""Presentation / view layer for the dashboard.

Turns the aggregated ``latest_data`` snapshot (plus a little ``state_manager`` state) into
the flat string map that ``index.html`` is ``str.format()``-ed with, and renders it.

Each dashboard section has a frozen ``*Context`` dataclass whose fields ARE that section's
template placeholders — so the template contract is explicit and discoverable, and a
forgotten field fails loudly at construction (a ``TypeError`` here) instead of silently
surviving until a render-time ``KeyError`` in the 500 handler (Issue #38). ``render_dashboard``
is the single assembly point; ``server.py`` stays pure transport (routing + middleware).
"""
import os
import time
import html
import bisect
import json
import logging
from dataclasses import dataclass, asdict

from mining_dashboard.config.config import (
    HOST_IP, ENABLE_XVB, XVB_DONATION_LEVEL, XVB_MAX_DONATION_FRACTION,
    MONERO_PRUNE, MONERO_NODE_HOST,
)
from mining_dashboard.helper.utils import (
    format_hashrate, format_duration, format_time_abs, get_tier_info,
    resolve_target_threshold,
)

logger = logging.getLogger("WebViews")

BADGE_P2POOL = '<span class="badge badge-ok">P2Pool</span>'
BADGE_XVB = '<span class="badge badge-purple">XvB</span>'
BADGE_UNKNOWN = '<span class="badge badge-bad">Unknown</span>'

# Mode colours: the active pool is coloured, the inactive one muted (Issue #27).
_C_GREEN = "#238636"
_C_PURPLE = "#a371f7"
_C_BLUE = "#58a6ff"
_C_MUTED = "#8b949e"

# Only a local monerod's pruning state is knowable to us; a remote node isn't probed.
_LOCAL_MONERO_HOST = "172.28.0.26"

# Cap on chart points sent to the frontend — keeps Chart.js responsive and the HTML small.
_MAX_CHART_POINTS = 800

# Nano sidechain blocks are 30s; Main/Mini are 10s. Drives PPLNS-window durations.
_BLOCK_TIME_NANO = 30
_BLOCK_TIME_DEFAULT = 10


# --------------------------------------------------------------------------------------
# Template-bound context blocks. Field name == template placeholder.
# --------------------------------------------------------------------------------------

@dataclass(frozen=True)
class SyncContext:
    sync_class: str
    page_title: str
    sync_percent: str
    sync_percent_val: int
    sync_current: int
    sync_target: int
    sync_remaining: int
    tari_sync_percent: str
    tari_sync_percent_val: int
    tari_sync_current: int
    tari_sync_target: int
    tari_sync_remaining: int


@dataclass(frozen=True)
class ChartContext:
    chart_labels: str
    chart_p2pool: str
    chart_xvb: str
    chart_shares_y: str
    chart_shares_r: str
    chart_shares_c: str
    cls_1h: str
    cls_24h: str
    cls_1w: str
    cls_1m: str


@dataclass(frozen=True)
class SystemContext:
    hp_status: str
    hp_class: str
    hp_val: str
    disk_used: float
    disk_total: float
    disk_p: str
    disk_width: str
    disk_fill_class: str
    disk_class: str
    disk_badge: str
    mem_p: str
    mem_used: str
    mem_total: str
    mem_label_class: str
    mem_val_class: str
    mem_badge: str
    cpu_load: str
    cpu_percent: str
    cpu_label_class: str
    cpu_val_class: str
    cpu_badge: str


@dataclass(frozen=True)
class PoolNetworkContext:
    strat_h15: str
    strat_h1h: str
    strat_h24h: str
    strat_shares: str
    strat_effort: str
    strat_total_shares: int
    strat_reward_pct: str
    strat_conns: int
    strat_last_share: str
    strat_total_hashes: int
    strat_wallet: str
    strat_wallet_short: str
    proxy_workers: int
    p2p_type: str
    pool_sidechain_height: int
    pool_diff: str
    pool_hr: str
    pool_total_hashes: int
    pool_miners: int
    pplns_win: str
    pplns_wgt: int
    pool_shares_window: str
    pool_blocks: int
    pool_last_blk: str
    p2p_peers: str
    p2p_uptime: str
    net_height: int
    net_reward: str
    net_diff: str
    net_hash: str
    net_ts: str
    monero_mode: str
    monero_db_size: str
    monero_prune_badge: str


@dataclass(frozen=True)
class AlgoContext:
    mode_name: str
    mode_color: str
    p2p_color: str
    xvb_color: str
    total_hr: str
    last_update: str
    xvb_updated: str
    p2p_1h: str
    p2p_24h: str
    xvb_1h: str
    xvb_24h: str
    xvb_routed: str
    tier_name: str
    target_tier_name: str
    low_hr_badge: str
    xvb_fail_count: int


@dataclass(frozen=True)
class TariContext:
    tari_status: str
    tari_status_class: str
    tari_reward: str
    tari_height: str
    tari_diff: str
    tari_wallet: str
    tari_wallet_short: str


# --------------------------------------------------------------------------------------
# Builders: raw snapshot -> context block.
# --------------------------------------------------------------------------------------

def build_chart_context(history, shares, range_arg):
    """Filters history to the selected range, downsamples for performance, and builds the
    Chart.js datasets (P2Pool/XvB hashrate series + share-found markers)."""
    filtered_history = history
    filtered_shares = shares

    if range_arg != 'all':
        target_seconds = {'1h': 3600, '24h': 86400, '1w': 604800, '1m': 2592000}.get(range_arg, 0)
        if target_seconds > 0:
            cutoff_timestamp = time.time() - target_seconds
            filtered_history = [x for x in history if x['timestamp'] >= cutoff_timestamp]
            filtered_shares = [x for x in shares if x['ts'] >= cutoff_timestamp]

    filtered_history = _downsample_history(filtered_history)

    p2pool_data = []
    xvb_data = []
    chart_labels_list = [json.dumps(x['t']) for x in filtered_history]

    for x in filtered_history:
        v = x.get('v', 0)
        vp = x.get('v_p2pool', 0)
        vx = x.get('v_xvb', 0)
        # Fallback for legacy data: if breakdown is missing, assume P2Pool.
        if vp == 0 and vx == 0 and v > 0:
            vp = v
        p2pool_data.append(str(vp))
        xvb_data.append(str(vx))

    share_y_list, share_r_list, share_c_list = _build_share_markers(filtered_history, filtered_shares)

    return ChartContext(
        chart_labels=",".join(chart_labels_list),
        chart_p2pool=",".join(p2pool_data),
        chart_xvb=",".join(xvb_data),
        chart_shares_y=",".join(share_y_list),
        chart_shares_r=",".join(share_r_list),
        chart_shares_c=",".join(share_c_list),
        cls_1h='active' if range_arg == '1h' else '',
        cls_24h='active' if range_arg == '24h' else '',
        cls_1w='active' if range_arg == '1w' else '',
        cls_1m='active' if range_arg == '1m' else '',
    )


def _downsample_history(filtered_history):
    """Bucket-averages history down to ``_MAX_CHART_POINTS`` to cap the HTML payload size."""
    if len(filtered_history) <= _MAX_CHART_POINTS:
        return filtered_history

    chunk_size = len(filtered_history) / _MAX_CHART_POINTS
    downsampled = []
    for i in range(_MAX_CHART_POINTS):
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


def _build_share_markers(filtered_history, filtered_shares):
    """Bucket each share onto its nearest history sample, returning the per-point marker
    arrays (y-offset, radius, count) as parallel string lists."""
    share_y_list = ['null'] * len(filtered_history)
    share_r_list = ['0'] * len(filtered_history)
    share_c_list = ['0'] * len(filtered_history)

    if not (filtered_history and filtered_shares):
        return share_y_list, share_r_list, share_c_list

    hist_ts = [x['timestamp'] for x in filtered_history]
    share_counts = {}
    for s in filtered_shares:
        s_ts = s['ts']
        idx = bisect.bisect_left(hist_ts, s_ts)
        candidates = []
        if idx < len(hist_ts): candidates.append(idx)
        if idx > 0: candidates.append(idx - 1)
        if candidates:
            closest_idx = min(candidates, key=lambda i: abs(hist_ts[i] - s_ts))
            share_counts[closest_idx] = share_counts.get(closest_idx, 0) + 1

    for idx, count in share_counts.items():
        if idx < len(filtered_history):
            v = filtered_history[idx].get('v', 0)
            # Lift the marker 10% above the line so it doesn't sit on the curve; floor to
            # 100 for zero-hashrate samples so it stays visible.
            share_y_list[idx] = str(v * 1.1 if v > 0 else 100)
            share_r_list[idx] = str(min(6 + (count * 3), 15))
            share_c_list[idx] = str(count)

    return share_y_list, share_r_list, share_c_list


def build_worker_rows(workers):
    """Generates HTML table rows for worker statistics, including status badges and hashrate metrics."""
    worker_rows = ""
    sorted_workers = sorted(workers, key=lambda x: (x['status'] != 'online', x['name']))

    for worker in sorted_workers:
        try:
            status_class = "status-ok" if worker['status'] == 'online' else "status-bad"

            # Identify and assign pool badge based on port
            active_pool = worker.get('active_pool', '')
            pool_badge = BADGE_UNKNOWN
            if any(p in active_pool for p in ['3333', '37889', '37888', '37890']):
                pool_badge = BADGE_P2POOL
            elif any(p in active_pool for p in ['3344', '4247']):
                pool_badge = BADGE_XVB

            name_display = f"{html.escape(worker['name'])} {pool_badge}"

            uptime_val = worker.get('uptime', 0)
            h10_val = worker.get('h10', 0)
            h60_val = worker.get('h60', 0)
            h15_val = worker.get('h15', 0)
            ip_sort_val = _ip_to_sort_int(worker.get('ip', '0.0.0.0'))

            worker_rows += f"""
            <tr class="{status_class}">
                <td data-sort="{html.escape(worker['name'])}">{name_display}</td>
                <td data-sort="{ip_sort_val}">{html.escape(worker['ip'])}</td>
                <td data-sort="{uptime_val}">{format_duration(uptime_val)}</td>
                <td data-sort="{h10_val}">{format_hashrate(h10_val)}</td>
                <td data-sort="{h60_val}">{format_hashrate(h60_val)}</td>
                <td data-sort="{h15_val}">{format_hashrate(h15_val)}</td>
            </tr>
            """
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return worker_rows


def _ip_to_sort_int(ip):
    """Pack a dotted-quad IP into an int for client-side numeric sorting; 0 on malformed input."""
    try:
        a, b, c, d = (int(part) for part in ip.split('.'))
        return (a << 24) + (b << 16) + (c << 8) + d
    except (ValueError, IndexError, AttributeError):
        return 0


def build_tari_context(data):
    """Extracts and formats Tari merge mining metrics for the dashboard."""
    tari_stats = data.get('tari', {})
    tari_active = tari_stats.get('active', False)
    t_addr = tari_stats.get('address', 'Unknown')

    status_val = tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...'
    if tari_active:
        status_val = f'{status_val} <span style="font-size: 1.2em;">✔</span>'

    return TariContext(
        tari_status=status_val,
        tari_status_class="status-ok" if tari_active else "",
        tari_reward=f"{tari_stats.get('reward', 0):.2f} TARI",
        tari_height=str(tari_stats.get('height', 0)),
        tari_diff=f"{int(tari_stats.get('difficulty', 0)):,}",
        tari_wallet=t_addr,
        tari_wallet_short=_shorten(t_addr),
    )


def _shorten(addr, keep=8, threshold=16):
    """Elide a long address to ``head...tail`` for compact display; short ones pass through."""
    return addr if len(addr) <= threshold else f"{addr[:keep]}...{addr[-keep:]}"


def _usage_flag(percent, threshold=80, label="High Usage"):
    """Return the (status class, badge HTML) pair for a resource gauge over ``threshold``."""
    if percent > threshold:
        badge = (f'<span class="badge badge-bad" style="margin-left:5px; margin-right:5px;">'
                 f'{label}</span>')
        return "status-bad", badge
    return "", ""


def build_system_context(data):
    """Extracts and formats system resource metrics (CPU, RAM, Disk, HugePages)."""
    system = data.get('system', {})

    # Disk
    disk_usage = system.get('disk', {})
    disk_percent = disk_usage.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""
    disk_status, disk_badge = _usage_flag(disk_percent)
    disk_class = disk_status or "text-muted"

    # Memory
    mem_usage = system.get('memory', {})
    mem_percent = mem_usage.get('percent', 0)
    mem_status, mem_badge = _usage_flag(mem_percent)
    mem_label_class = mem_status or "text-muted"

    # CPU
    cpu_str = system.get('cpu_percent', "0.0%")
    try:
        cpu_val = float(cpu_str.strip('%'))
    except ValueError:
        cpu_val = 0.0
    cpu_status, cpu_badge = _usage_flag(cpu_val)
    cpu_label_class = cpu_status or "text-muted"

    load_raw = system.get('load', "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = (f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}"
                if len(load_parts) == 3 else load_raw)

    hp_status, hp_class, hp_val = system.get('hugepages', ["Disabled", "status-bad", "0/0"])

    return SystemContext(
        hp_status=hp_status,
        hp_class=hp_class,
        hp_val=hp_val,
        disk_used=disk_usage.get('used_gb', 0),
        disk_total=disk_usage.get('total_gb', 0),
        disk_p=disk_usage.get('percent_str', '0%'),
        disk_width=f"{disk_percent}%",
        disk_fill_class=disk_fill,
        disk_class=disk_class,
        disk_badge=disk_badge,
        mem_p=mem_usage.get('percent_str', '0%'),
        mem_used=f"{mem_usage.get('used_gb', 0):.1f}",
        mem_total=f"{mem_usage.get('total_gb', 0):.1f}",
        mem_label_class=mem_label_class,
        mem_val_class=mem_status,
        mem_badge=mem_badge,
        cpu_load=load_avg,
        cpu_percent=cpu_str,
        cpu_label_class=cpu_label_class,
        cpu_val_class=cpu_status,
        cpu_badge=cpu_badge,
    )


def build_pool_network_context(data):
    """Extracts and formats P2Pool, Stratum, and Monero Network metrics."""
    pool_stats = data.get('pool', {})
    p2p_stats = pool_stats.get('p2p', {})
    local_pool = pool_stats.get('pool', {})
    stratum_stats = data.get('stratum', {})
    network_stats = data.get('network', {})

    s_addr = stratum_stats.get('wallet', 'Unknown')

    workers_list = data.get('workers', [])
    proxy_count = sum(1 for w in workers_list if w.get('status') == 'online')

    pool_type = p2p_stats.get('type', 'Main')
    block_time = _BLOCK_TIME_NANO if pool_type == 'Nano' else _BLOCK_TIME_DEFAULT

    # Shares within the PPLNS window
    shares_list = data.get('shares', [])
    pplns_window = local_pool.get('pplns_window', 2160)
    cutoff = time.time() - pplns_window * block_time
    shares_count = sum(1 for s in shares_list if s.get('ts', 0) >= cutoff)
    cls = 'status-ok' if shares_count > 0 else 'status-bad'
    shares_display = f"<span class='{cls}'>{shares_count}</span>"

    monero_mode, monero_db_size, monero_prune_badge = _monero_panel(data.get('monero_sync', {}))

    return PoolNetworkContext(
        strat_h15=format_hashrate(stratum_stats.get('hashrate_15m', 0)),
        strat_h1h=format_hashrate(stratum_stats.get('hashrate_1h', 0)),
        strat_h24h=format_hashrate(stratum_stats.get('hashrate_24h', 0)),
        strat_shares=f"{stratum_stats.get('shares_found',0)} / {stratum_stats.get('shares_failed',0)}",
        strat_effort=f"{stratum_stats.get('current_effort', 0):.1f}%",
        strat_total_shares=stratum_stats.get('total_stratum_shares', 0),
        strat_reward_pct=f"{stratum_stats.get('block_reward_share_percent', 0):.4f}%",
        strat_conns=stratum_stats.get('connections', 0),
        strat_last_share=format_time_abs(stratum_stats.get('last_share_found_time', 0)),
        strat_total_hashes=stratum_stats.get('total_hashes', 0),
        strat_wallet=s_addr,
        strat_wallet_short=_shorten(s_addr),
        proxy_workers=proxy_count,
        p2p_type=p2p_stats.get('type', 'Unknown'),
        pool_sidechain_height=local_pool.get('sidechain_height', 0),
        pool_diff=f"{local_pool.get('difficulty', 0)/1e6:.2f} M",
        pool_hr=format_hashrate(local_pool.get('hashrate', 0)),
        pool_total_hashes=local_pool.get('total_hashes', 0),
        pool_miners=local_pool.get('miners', 0),
        pplns_win=f"{local_pool.get('pplns_window', 0)} ({format_duration(local_pool.get('pplns_window', 0) * block_time)})",
        pplns_wgt=local_pool.get('pplns_weight', 0),
        pool_shares_window=shares_display,
        pool_blocks=local_pool.get('blocks_found', 0),
        pool_last_blk=format_time_abs(local_pool.get('last_block_ts', 0)),
        p2p_peers=f"{p2p_stats.get('out_peers',0)} / {p2p_stats.get('in_peers',0)}",
        p2p_uptime=format_duration(p2p_stats.get('uptime', 0)),
        net_height=network_stats.get('height', 0),
        net_reward=f"{network_stats.get('reward', 0)/1e12:.4f} XMR",
        net_diff=f"{network_stats.get('difficulty', 0)/1e9:.2f} G",
        net_hash=_shorten(str(network_stats.get('hash', 'N/A')), threshold=20),
        net_ts=format_time_abs(network_stats.get('timestamp', 0)),
        monero_mode=monero_mode,
        monero_db_size=monero_db_size,
        monero_prune_badge=monero_prune_badge,
    )


def _monero_panel(monero_sync):
    """Monero node mode label, on-disk DB size, and header badge (Issue #32).

    Pruned/Full comes from config; the DB size from get_info sits alongside so a config/DB
    mismatch is visible. Only meaningful for a local node — a remote node's pruning state
    isn't something we probe, so it reads 'Unknown' with no badge.
    """
    db_bytes = monero_sync.get('db_size', 0) or 0
    if MONERO_NODE_HOST == _LOCAL_MONERO_HOST:
        mode = "Pruned" if MONERO_PRUNE else "Full"
    else:
        mode = "Unknown"
    db_size = f"{db_bytes / 1e9:.1f} GB" if db_bytes > 0 else "—"

    if mode == "Pruned":
        badge = ('<span class="badge badge-outline" '
                 'title="Monero blockchain is pruned">XMR Pruned</span>')
    elif mode == "Full":
        badge = ('<span class="badge badge-outline" '
                 'title="Monero blockchain is full (not pruned)">XMR Full</span>')
    else:
        badge = ''
    return mode, db_size, badge


def _avg_p2pool_over_window(history, window_seconds):
    """Time-weighted P2Pool hashrate over the trailing window, from DB history.

    Averages the per-sample ``v_p2pool`` (hashrate attributed to P2Pool) for samples within
    the window. Samples are written at a fixed cadence (UPDATE_INTERVAL), so a simple mean
    approximates a time-weighted average. Mirrors the chart's legacy-data fallback: rows
    predating the p2pool/xvb split (v_p2pool == v_xvb == 0 but v > 0) count as P2Pool. (Issue #27)
    """
    if not history:
        return 0.0

    cutoff = time.time() - window_seconds
    total = 0.0
    count = 0
    for x in history:
        if x.get('timestamp', 0) < cutoff:
            continue
        vp = x.get('v_p2pool', 0) or 0
        vx = x.get('v_xvb', 0) or 0
        v = x.get('v', 0) or 0
        if vp == 0 and vx == 0 and v > 0:
            vp = v
        total += vp
        count += 1

    return total / count if count else 0.0


def _mode_colors(current_mode):
    """Resolve (mode_color, p2p_color, xvb_color) from the algo mode string.

    The active pool is coloured, the inactive one muted — symmetric between P2Pool and XvB
    (Issue #27). Checked most-specific first: "XVB (Split)" contains both "Split" and "XVB".
    """
    if "Split" in current_mode:
        # Split cycle alternates pools within the window — both are active.
        return _C_BLUE, _C_GREEN, _C_PURPLE
    if "XVB" in current_mode:
        return _C_PURPLE, _C_MUTED, _C_PURPLE
    return _C_GREEN, _C_GREEN, _C_MUTED  # P2POOL


def build_algo_context(data, state_mgr, history):
    """Calculates algorithm switching logic, donation tiers, and hashrate averages."""
    xvb_stats = state_mgr.get_xvb_stats() or {}
    current_mode = xvb_stats.get('current_mode', 'P2POOL')

    if not ENABLE_XVB:
        current_mode = "P2POOL (XvB Disabled)"
    mode_color, p2p_color, xvb_color = _mode_colors(
        "P2POOL" if not ENABLE_XVB else current_mode
    )

    total_hr_val = data.get('total_live_h15', 0)
    xvb_24h_val = xvb_stats.get('avg_24h', 0)
    # What we currently route to XvB (fraction of our hashrate this cycle). Shown
    # next to the credited averages so the gap — the live credit factor — is
    # visible: routed is our input, avg_1h/24h is XvB's authoritative output.
    routed_hr_val = (xvb_stats.get('donation_fraction', 0) or 0) * total_hr_val

    # P2Pool 1h/24h averages from our own DB history: the time-weighted hashrate actually
    # delivered to P2Pool (v_p2pool), rather than p2pool's noisy stratum estimate or a
    # total-minus-XvB subtraction. The raw stratum reading is shown separately. (Issue #27)
    p2p_1h_val = _avg_p2pool_over_window(history, 3600)
    p2p_24h_val = _avg_p2pool_over_window(history, 86400)

    tiers = state_mgr.get_tiers()
    # Current tier = what XvB actually credits us (drives qualification).
    tier_name, _ = get_tier_info(xvb_24h_val, tiers)
    # Target tier = what the algo aims for, from the configured donation level (Issue #40).
    # "auto" = highest sustainable; an explicit tier is honored even if unsustainable, in
    # which case we flag a low-hashrate warning.
    target_threshold, sustainable = resolve_target_threshold(
        tiers, total_hr_val, XVB_DONATION_LEVEL, XVB_MAX_DONATION_FRACTION
    )
    target_tier_name, _ = get_tier_info(target_threshold, tiers)

    low_hr_badge = ''
    if (ENABLE_XVB and XVB_DONATION_LEVEL not in ("auto", "highest")
            and target_threshold > 0 and not sustainable):
        low_hr_badge = (
            '<span class="badge badge-warn" style="margin-left: 8px;" '
            'title="Your hashrate can\'t sustain the selected XvB donation tier; '
            'donation will fall short of it.">⚠ Hashrate low for tier</span>'
        )

    if not ENABLE_XVB:
        tier_name = "Disabled"
        target_tier_name = "Disabled"
        low_hr_badge = ''

    return AlgoContext(
        mode_name=current_mode,
        mode_color=mode_color,
        p2p_color=p2p_color,
        xvb_color=xvb_color,
        total_hr=format_hashrate(total_hr_val),
        last_update=format_time_abs(time.time()),
        xvb_updated=format_time_abs(xvb_stats.get('last_update', 0)),
        p2p_1h=format_hashrate(p2p_1h_val),
        p2p_24h=format_hashrate(p2p_24h_val),
        xvb_1h=format_hashrate(xvb_stats.get('avg_1h', 0)),
        xvb_24h=format_hashrate(xvb_24h_val),
        xvb_routed=format_hashrate(routed_hr_val),
        tier_name=tier_name,
        target_tier_name=target_tier_name,
        low_hr_badge=low_hr_badge,
        xvb_fail_count=xvb_stats.get('fail_count', 0),
    )


def _sync_display(sync):
    """Render one chain's sync progress: a loading ellipsis until real data arrives
    (target > 0), a checkmark at 100%, else the raw percentage."""
    pct = sync.get('percent', 0)
    if sync.get('target', 0) <= 0:
        return '…'
    if pct >= 100:
        return '<span class="status-ok" style="font-size: 3.5em; line-height: 1;">✔</span>'
    return f"{pct}%"


def build_sync_context(monero_sync, tari_sync, is_syncing):
    """Builds the sync-mode template fields (Monero + Tari progress)."""
    return SyncContext(
        sync_class='mode-sync' if is_syncing else '',
        page_title='Mining Dashboard - Syncing' if is_syncing else 'Mining Dashboard',
        sync_percent=_sync_display(monero_sync),
        sync_percent_val=monero_sync.get('percent', 0),
        sync_current=monero_sync.get('current', 0),
        sync_target=monero_sync.get('target', 0),
        sync_remaining=monero_sync.get('target', 0) - monero_sync.get('current', 0),
        tari_sync_percent=_sync_display(tari_sync),
        tari_sync_percent_val=tari_sync.get('percent', 0),
        tari_sync_current=tari_sync.get('current', 0),
        tari_sync_target=tari_sync.get('target', 0),
        tari_sync_remaining=tari_sync.get('target', 0) - tari_sync.get('current', 0),
    )


def _badge(cls, text, title=None):
    title_attr = f' title="{title}"' if title else ''
    return f'<span class="{cls}"{title_attr}>{text}</span>'


def build_header_badges(data, is_syncing, algo, pool_net):
    """Builds the top-bar status badges (mode/pool, node-down, sync-hold, passive-Tari)."""
    monero_sync = data.get('monero_sync', {})
    tari_sync = data.get('tari_sync', {})

    badges = []
    if is_syncing:
        badges.append(_badge("badge badge-warn badge-pool", "Syncing..."))
    else:
        badges.append(f'<span class="badge badge-pool" style="background-color: '
                      f'{algo.mode_color};">{algo.mode_name}</span>')
        badges.append(_badge("badge badge-outline", f"P2Pool {pool_net.p2p_type}"))
        if algo.low_hr_badge:
            badges.append(algo.low_hr_badge)

    # Node-down badges (Issue #31) — shown whenever a node is unreachable, regardless of
    # sync state, plus a notice when workers have been rejected to fail over.
    if monero_sync.get('down'):
        badges.append(_badge("badge badge-bad badge-pool", "monerod DOWN"))
    if tari_sync.get('down'):
        badges.append(_badge("badge badge-bad badge-pool", "Tari DOWN"))
    if data.get('workers_rejected'):
        badges.append(_badge("badge badge-bad badge-pool", "Workers rejected",
                             "Workers rejected so they fail over to their backup pools"))
    # Miner held until the required chain(s) finish their initial sync (Issue #35).
    if data.get('miner_held'):
        badges.append(_badge("badge badge-warn badge-pool", "Miner held (sync)",
                             "p2pool and xmrig-proxy are held until the required chains finish syncing"))
    # Non-blocking Tari (Issue #51): Tari is (re)syncing but we stay in the operational view
    # — surface it as a top-bar badge instead of the full-screen takeover. Show the progress
    # percentage once known (omitted early, before a target height, so it isn't a stale "0%").
    if data.get('tari_syncing_passive'):
        t_pct = tari_sync.get('percent', 0)
        label = f'Tari syncing {t_pct}%' if t_pct > 0 else 'Tari syncing'
        badges.append(_badge(
            "badge badge-warn badge-pool", label,
            "Tari is still syncing — merge mining resumes when it catches up; Monero mining continues"))

    return "".join(badges)


# --------------------------------------------------------------------------------------
# Template loading + render assembly.
# --------------------------------------------------------------------------------------

TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")
_TEMPLATE_CACHE = None
_TEMPLATE_MTIME = 0


def get_cached_template():
    """Retrieves and caches the HTML template, reloading from disk only if it has changed."""
    global _TEMPLATE_CACHE, _TEMPLATE_MTIME
    try:
        mtime = os.path.getmtime(TEMPLATE_PATH)
        if _TEMPLATE_CACHE is None or mtime > _TEMPLATE_MTIME:
            with open(TEMPLATE_PATH, 'r') as f:
                _TEMPLATE_CACHE = f.read()
            _TEMPLATE_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading template: {e}")
    return _TEMPLATE_CACHE or "<h1>Template Error</h1>"


def build_view_model(data, state_mgr, range_arg):
    """Assemble every context block into the flat field map the dashboard needs.

    Each block's dataclass fields are flattened into a single dict, alongside the host IP,
    pre-rendered worker rows, and header badges. The values are all JSON-serializable
    primitives/strings — so this is the single source of truth for both the HTML render
    (``render_dashboard``) and a future ``fetch()`` partial/JSON endpoint (Issue #30),
    without either re-deriving the other's data. May raise (e.g. ``state_mgr.get_history``
    failing) — callers wrap this and return a sanitized 500.
    """
    history = state_mgr.get_history()
    is_syncing = data.get('global_sync', False)

    sync = build_sync_context(data.get('monero_sync', {}), data.get('tari_sync', {}), is_syncing)
    chart = build_chart_context(history, data.get('shares', []), range_arg)
    system = build_system_context(data)
    pool_net = build_pool_network_context(data)
    algo = build_algo_context(data, state_mgr, history)
    tari = build_tari_context(data)

    fields = {}
    for block in (sync, chart, system, pool_net, algo, tari):
        fields.update(asdict(block))
    fields.update(
        host_ip=HOST_IP,
        worker_rows=build_worker_rows(data.get('workers', [])),
        header_badges=build_header_badges(data, is_syncing, algo, pool_net),
    )
    return fields


def render_dashboard(data, state_mgr, range_arg):
    """Render the dashboard HTML — the one place the template contract is satisfied."""
    return get_cached_template().format(**build_view_model(data, state_mgr, range_arg))
