import os
import time
import html
import logging
import bisect
from aiohttp import web
from config.config import HOST_IP, BLOCK_PPLNS_WINDOW_MAIN, ENABLE_XVB
from helper.utils import format_hashrate, format_duration, format_time_abs, get_tier_info

logger = logging.getLogger("WebServer")

# Absolute path to the HTML template file
TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")

BADGE_P2POOL = '<span class="badge badge-ok">P2Pool</span>'
BADGE_XVB = '<span class="badge badge-purple">XvB</span>'
BADGE_UNKNOWN = '<span class="badge badge-bad">Unknown</span>'

# Template Caching Mechanism
_TEMPLATE_CACHE = None
_TEMPLATE_MTIME = 0

def get_cached_template():
    """Retrieves and caches the HTML template, reloading from disk only if the file has been modified."""
    global _TEMPLATE_CACHE, _TEMPLATE_MTIME
    try:
        mtime = os.path.getmtime(TEMPLATE_PATH)
        if _TEMPLATE_CACHE is None or mtime > _TEMPLATE_MTIME:
            with open(TEMPLATE_PATH, 'r') as f:
                content = f.read()
            _TEMPLATE_CACHE = content
            _TEMPLATE_MTIME = mtime
    except Exception as e:
        logger.error(f"Error loading template: {e}")
    return _TEMPLATE_CACHE or "<h1>Template Error</h1>"

def _get_chart_context(history, shares, range_arg):
    """Filters historical data based on the selected time range and prepares Chart.js datasets."""
    filtered_history = history
    filtered_shares = shares
    
    if range_arg != 'all':
        target_seconds = 0
        if range_arg == '1h': target_seconds = 3600
        elif range_arg == '24h': target_seconds = 86400
        elif range_arg == '1w': target_seconds = 604800
        elif range_arg == '1m': target_seconds = 2592000 # 30 Days
        
        if target_seconds > 0:
            cutoff_timestamp = time.time() - target_seconds
            filtered_history = [x for x in history if x['timestamp'] >= cutoff_timestamp]
            filtered_shares = [x for x in shares if x['ts'] >= cutoff_timestamp]

    p2pool_data = []
    xvb_data = []
    for x in filtered_history:
        v = x.get('v', 0)
        vp = x.get('v_p2pool', 0)
        vx = x.get('v_xvb', 0)
        
        # Fallback for legacy data: if breakdown is missing, assume P2Pool
        if vp == 0 and vx == 0 and v > 0:
            vp = v
            
        p2pool_data.append(str(vp))
        xvb_data.append(str(vx))

    share_data = ['null'] * len(filtered_history)
    if filtered_history and filtered_shares:
        hist_ts = [x['timestamp'] for x in filtered_history]
        share_counts = {}

        for s in filtered_shares:
            s_ts = s['ts']
            # Optimize search using bisect
            idx = bisect.bisect_left(hist_ts, s_ts)
            candidates = []
            if idx < len(hist_ts): candidates.append(idx)
            if idx > 0: candidates.append(idx - 1)
            
            if candidates:
                closest_idx = min(candidates, key=lambda i: abs(hist_ts[i] - s_ts))
                share_counts[closest_idx] = share_counts.get(closest_idx, 0) + 1

        for idx, count in share_counts.items():
            item = filtered_history[idx]
            v = item.get('v', 0)
            vp = item.get('v_p2pool', 0)
            vx = item.get('v_xvb', 0)
            
            # Fallback logic: if breakdown is missing, assume P2Pool
            if vp == 0 and vx == 0 and v > 0:
                vp = v
            
            # Dynamic radius: Base 6 + 2 per share, max 20
            r = min(6 + (count * 2), 20)
            t_label = item.get('t', '')
            share_data[idx] = f"{{x: '{t_label}', y: {vp}, shares: {count}, r: {r}}}"

    return {
        'chart_labels': ",".join([f"'{x['t']}'" for x in filtered_history]),
        'chart_data': ",".join([str(x['v']) for x in filtered_history]),
        'chart_p2pool': ",".join(p2pool_data),
        'chart_xvb': ",".join(xvb_data),
        'chart_shares': ",".join(share_data),
        'cls_1h': 'active' if range_arg == '1h' else '',
        'cls_24h': 'active' if range_arg == '24h' else '',
        'cls_1w': 'active' if range_arg == '1w' else '',
        'cls_1m': 'active' if range_arg == '1m' else ''
    }

def _get_worker_rows(workers):
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

            # Add data-sort attributes for client-side sorting
            uptime_val = worker.get('uptime', 0)
            h10_val = worker.get('h10', 0)
            h60_val = worker.get('h60', 0)
            h15_val = worker.get('h15', 0)

            # Convert IP address to integer for sorting purposes
            try:
                ip_parts = [int(part) for part in worker.get('ip', '0.0.0.0').split('.')]
                ip_sort_val = (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3]
            except (ValueError, IndexError, AttributeError):
                ip_sort_val = 0

            row = f"""
            <tr class="{status_class}">
                <td data-sort="{html.escape(worker['name'])}">{name_display}</td>
                <td data-sort="{ip_sort_val}">{html.escape(worker['ip'])}</td>
                <td data-sort="{uptime_val}">{format_duration(uptime_val)}</td>
                <td data-sort="{h10_val}">{format_hashrate(h10_val)}</td>
                <td data-sort="{h60_val}">{format_hashrate(h60_val)}</td>
                <td data-sort="{h15_val}">{format_hashrate(h15_val)}</td>
            </tr>
            """
            worker_rows += row
        except Exception as e:
            logger.error(f"Error processing worker {worker.get('name', 'unknown')}: {e}")
            continue
    return worker_rows

def _get_tari_context(data):
    """Extracts and formats Tari merge mining metrics for the dashboard."""
    tari_stats = data.get('tari', {})
    tari_active = tari_stats.get('active', False)
    t_addr = tari_stats.get('address', 'Unknown')
    t_short = t_addr if len(t_addr) <= 16 else f"{t_addr[:8]}...{t_addr[-8:]}"
    
    status_val = tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...'
    if tari_active:
        status_val = f'{status_val} <span style="font-size: 1.2em;">✔</span>'

    return {
        'tari_status': status_val,
        'tari_status_class': "status-ok" if tari_active else "",
        'tari_reward': f"{tari_stats.get('reward', 0):.2f} TARI",
        'tari_height': str(tari_stats.get('height', 0)),
        'tari_diff': f"{int(tari_stats.get('difficulty', 0)):,}",
        'tari_wallet': t_addr,
        'tari_wallet_short': t_short
    }

def _get_system_context(data):
    """Extracts and formats system resource metrics (CPU, RAM, Disk, HugePages)."""
    system = data.get('system', {})
    
    # Disk Usage
    disk_usage = system.get('disk', {})
    disk_percent = disk_usage.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""
    
    disk_class = "text-muted"
    disk_badge = ""
    if disk_percent > 80:
        disk_class = "status-bad"
        disk_badge = '<span class="badge badge-bad" style="margin-left:5px; margin-right:5px;">High Usage</span>'

    # Memory Usage
    mem_usage = system.get('memory', {})
    mem_percent = mem_usage.get('percent', 0)
    
    mem_label_class = "text-muted"
    mem_val_class = ""
    mem_badge = ""
    if mem_percent > 80:
        mem_label_class = "status-bad"
        mem_val_class = "status-bad"
        mem_badge = '<span class="badge badge-bad" style="margin-left:5px; margin-right:5px;">High Usage</span>'

    # CPU Usage
    cpu_str = system.get('cpu_percent', "0.0%")
    try:
        cpu_val = float(cpu_str.strip('%'))
    except ValueError:
        cpu_val = 0.0
        
    load_raw = system.get('load', "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}" if len(load_parts) == 3 else load_raw
    
    cpu_label_class = "text-muted"
    cpu_val_class = ""
    cpu_badge = ""
    if cpu_val > 80:
        cpu_label_class = "status-bad"
        cpu_val_class = "status-bad"
        cpu_badge = '<span class="badge badge-bad" style="margin-left:5px; margin-right:5px;">High Usage</span>'

    hugepages_info = system.get('hugepages', ["Disabled", "status-bad", "0/0"])
    hp_status, hp_class, hp_val = hugepages_info

    return {
        'hp_status': hp_status,
        'hp_class': hp_class,
        'hp_val': hp_val,
        'disk_used': disk_usage.get('used_gb', 0),
        'disk_total': disk_usage.get('total_gb', 0),
        'disk_p': disk_usage.get('percent_str', '0%'),
        'disk_width': f"{disk_percent}%",
        'disk_fill_class': disk_fill,
        'disk_class': disk_class,
        'disk_badge': disk_badge,
        'mem_p': mem_usage.get('percent_str', '0%'),
        'mem_used': f"{mem_usage.get('used_gb', 0):.1f}",
        'mem_total': f"{mem_usage.get('total_gb', 0):.1f}",
        'mem_label_class': mem_label_class,
        'mem_val_class': mem_val_class,
        'mem_badge': mem_badge,
        'cpu_load': load_avg,
        'cpu_percent': cpu_str,
        'cpu_label_class': cpu_label_class,
        'cpu_val_class': cpu_val_class,
        'cpu_badge': cpu_badge,
    }

def _get_pool_network_context(data):
    """Extracts and formats P2Pool, Stratum, and Monero Network metrics."""
    pool_stats = data.get('pool', {})
    p2p_stats = pool_stats.get('p2p', {})
    local_pool = pool_stats.get('pool', {})
    stratum_stats = data.get('stratum', {})
    network_stats = data.get('network', {})

    net_hash_val = str(network_stats.get('hash', 'N/A'))
    if len(net_hash_val) > 20:
        net_hash_val = f"{net_hash_val[:8]}...{net_hash_val[-8:]}"

    s_addr = stratum_stats.get('wallet', 'Unknown')
    s_short = s_addr if len(s_addr) <= 16 else f"{s_addr[:8]}...{s_addr[-8:]}"

    workers_list = data.get('workers', [])
    proxy_count = sum(1 for w in workers_list if w.get('status') == 'online')

    # Calculate shares in window
    shares_list = data.get('shares', [])
    pplns_window = local_pool.get('pplns_window', 2160)
    window_duration = pplns_window * 10
    cutoff = time.time() - window_duration
    shares_count = sum(1 for s in shares_list if s.get('ts', 0) >= cutoff)
    shares_display = f"<span class='status-ok'>{shares_count}</span>" if shares_count > 0 else f"<span class='status-bad'>0</span>"

    return {
        'strat_h15': format_hashrate(stratum_stats.get('hashrate_15m', 0)),
        'strat_h1h': format_hashrate(stratum_stats.get('hashrate_1h', 0)),
        'strat_h24h': format_hashrate(stratum_stats.get('hashrate_24h', 0)),
        'strat_shares': f"{stratum_stats.get('shares_found',0)} / {stratum_stats.get('shares_failed',0)}",
        'strat_effort': f"{stratum_stats.get('current_effort', 0):.1f}%",
        'strat_total_shares': stratum_stats.get('total_stratum_shares', 0),
        'strat_reward_pct': f"{stratum_stats.get('block_reward_share_percent', 0):.4f}%",
        'strat_conns': stratum_stats.get('connections', 0),
        'strat_last_share': format_time_abs(stratum_stats.get('last_share_found_time', 0)),
        'strat_total_hashes': stratum_stats.get('total_hashes', 0),
        'strat_wallet': s_addr,
        'strat_wallet_short': s_short,
        'proxy_workers': proxy_count,
        'p2p_type': p2p_stats.get('type', 'Unknown'),
        'pool_height': local_pool.get('height', 0),
        'pool_diff': f"{local_pool.get('difficulty', 0)/1e6:.2f} M",
        'pool_hr': format_hashrate(local_pool.get('hashrate', 0)),
        'pool_total_hashes': local_pool.get('total_hashes', 0),
        'pool_miners': local_pool.get('miners', 0),
        'pplns_win': f"{local_pool.get('pplns_window', 0)} ({format_duration(local_pool.get('pplns_window', 0) * 10)})",
        'pplns_wgt': local_pool.get('pplns_weight', 0),
        'pool_shares_window': shares_display,
        'pool_blocks': local_pool.get('blocks_found', 0),
        'pool_last_blk': format_time_abs(local_pool.get('last_block_ts', 0)),
        'p2p_peers': f"{p2p_stats.get('out_peers',0)} / {p2p_stats.get('in_peers',0)}",
        'p2p_uptime': format_duration(p2p_stats.get('uptime', 0)),
        'net_height': network_stats.get('height', 0),
        'net_reward': f"{network_stats.get('reward', 0)/1e12:.4f} XMR",
        'net_diff': f"{network_stats.get('difficulty', 0)/1e9:.2f} G",
        'net_hash': net_hash_val,
        'net_ts': format_time_abs(network_stats.get('timestamp', 0)),
    }

def _get_algo_context(data, state_mgr, history):
    """Calculates algorithm switching logic, donation tiers, and hashrate averages."""
    xvb_stats = state_mgr.get_xvb_stats() or {}
    current_mode = xvb_stats.get('current_mode', 'P2POOL')
    
    # Colors
    c_green = "#238636"
    c_purple = "#a371f7"
    c_blue = "#58a6ff"
    c_muted = "#8b949e"

    mode_color = c_green
    p2p_color = c_green
    xvb_color = c_muted

    if "XVB" in current_mode: 
        mode_color = c_purple
        p2p_color = c_muted
        xvb_color = c_purple
    if "Split" in current_mode: 
        mode_color = c_blue
        p2p_color = c_green
        xvb_color = c_purple
    if not ENABLE_XVB: 
        current_mode = "P2POOL (XvB Disabled)"
        p2p_color = c_green
        xvb_color = c_muted

    total_hr_val = data.get('total_live_h15', 0)
    xvb_1h_val = xvb_stats.get('avg_1h', 0)
    xvb_24h_val = xvb_stats.get('avg_24h', 0)

    stratum_stats = data.get('stratum', {})
    p2p_1h_val = stratum_stats.get('hashrate_1h', 0)
    p2p_24h_val = stratum_stats.get('hashrate_24h', 0)

    tiers = state_mgr.get_tiers()
    tier_name, _ = get_tier_info(xvb_24h_val, tiers)
    safe_capacity = total_hr_val * 0.85
    target_tier_name, _ = get_tier_info(safe_capacity, tiers)

    if not ENABLE_XVB:
        tier_name = "Disabled"
        target_tier_name = "Disabled"

    return {
        'mode_name': current_mode,
        'mode_color': mode_color,
        'p2p_color': p2p_color,
        'xvb_color': xvb_color,
        'total_hr': format_hashrate(total_hr_val),
        'last_update': format_time_abs(time.time()),
        'xvb_updated': format_time_abs(xvb_stats.get('last_update', 0)),
        'p2p_1h': format_hashrate(p2p_1h_val),
        'p2p_24h': format_hashrate(p2p_24h_val),
        'xvb_1h': format_hashrate(xvb_1h_val),
        'xvb_24h': format_hashrate(xvb_24h_val),
        'tier_name': tier_name,
        'target_tier_name': target_tier_name,
        'xvb_fail_count': xvb_stats.get('fail_count', 0),
    }

async def handle_index(request):
    """
    Primary Request Handler: Aggregates all context data and renders the Dashboard HTML.
    Handles view modes (Sync vs. Dashboard) and time-range filtering.
    """
    app = request.app
    data = app['latest_data']
    state_mgr = app['state_manager']
    
    try:
        history = state_mgr.get_history()
        shares = data.get('shares', [])
        range_arg = request.query.get('range', 'all')
        
        # Prepare Sync Context
        monero_sync = data.get('monero_sync', {})
        tari_sync = data.get('tari_sync', {})
        
        # Use global_sync flag from DataService to trigger dashboard sync mode
        is_syncing = data.get('global_sync', False)
        
        # Format Monero Sync Display (Checkmark if 100%)
        m_pct = monero_sync.get('percent', 0)
        if m_pct >= 100:
            m_disp = '<span class="status-ok" style="font-size: 3.5em; line-height: 1;">✔</span>'
        else:
            m_disp = f"{m_pct}%"

        # Format Tari Sync Display (Checkmark if 100%)
        t_pct = tari_sync.get('percent', 0)
        if t_pct >= 100:
            t_disp = '<span class="status-ok" style="font-size: 3.5em; line-height: 1;">✔</span>'
        else:
            t_disp = f"{t_pct}%"
        
        sync_ctx = {
            'sync_class': 'mode-sync' if is_syncing else '',
            'page_title': 'Mining Dashboard - Syncing' if is_syncing else 'Mining Dashboard',
            'sync_percent': m_disp,
            'sync_percent_val': m_pct,
            'sync_current': monero_sync.get('current', 0),
            'sync_target': monero_sync.get('target', 0),
            'sync_remaining': monero_sync.get('target', 0) - monero_sync.get('current', 0),
            'tari_sync_percent': t_disp,
            'tari_sync_percent_val': t_pct,
            'tari_sync_current': tari_sync.get('current', 0),
            'tari_sync_target': tari_sync.get('target', 0),
            'tari_sync_remaining': tari_sync.get('target', 0) - tari_sync.get('current', 0)
        }

        # Build Contexts
        chart_ctx = _get_chart_context(history, shares, range_arg)
        system_ctx = _get_system_context(data)
        pool_net_ctx = _get_pool_network_context(data)
        algo_ctx = _get_algo_context(data, state_mgr, history)
        tari_ctx = _get_tari_context(data)
        
        # Dynamic Components
        worker_rows = _get_worker_rows(data.get('workers', []))

        # Dynamic Header Badges
        if is_syncing:
            header_badges = '<span class="badge badge-warn badge-pool">Syncing...</span>'
        else:
            m_color = algo_ctx.get('mode_color', '')
            m_name = algo_ctx.get('mode_name', '')
            p_type = pool_net_ctx.get('p2p_type', '')
            header_badges = f'<span class="badge badge-pool" style="background-color: {m_color};">{m_name}</span>'
            header_badges += f'<span class="badge badge-outline">P2Pool {p_type}</span>'

        template = get_cached_template()
        
        response_html = template.format(
            host_ip=HOST_IP,
            header_badges=header_badges,
            worker_rows=worker_rows,
            **sync_ctx,
            **algo_ctx,
            **system_ctx,
            **pool_net_ctx,
            **tari_ctx,
            **chart_ctx
        )

        return web.Response(text=response_html, content_type='text/html')
        
    except Exception as e:
        # Handle rendering errors gracefully
        return web.Response(text=f"<h1>Error rendering dashboard</h1><p>{str(e)}</p><pre>{type(e).__name__}</pre>", status=500)

def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application()
    # Pass shared state objects to the app context
    app['state_manager'] = state_manager
    app['latest_data'] = latest_data_ref
    
    app.add_routes([web.get('/', handle_index)])
    return app