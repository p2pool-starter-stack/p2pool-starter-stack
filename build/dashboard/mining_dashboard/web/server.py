import os
import time
import html
import logging
from aiohttp import web
from config.config import HOST_IP, BLOCK_PPLNS_WINDOW_MAIN, ENABLE_XVB
from helper.utils import format_hashrate, format_duration, format_time_abs, get_tier_info

logger = logging.getLogger("WebServer")

# Path to the template file
TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")

BADGE_P2POOL = '<span class="badge badge-ok">P2Pool</span>'
BADGE_XVB = '<span class="badge badge-purple">XvB</span>'
BADGE_UNKNOWN = '<span class="badge badge-bad">Unknown</span>'

# Template Caching Configuration
_TEMPLATE_CACHE = None
_TEMPLATE_MTIME = 0

def get_cached_template():
    """Retrieves and caches the HTML template, injecting dynamic components only when the file is modified."""
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

def _get_chart_context(history, range_arg):
    """Filters history and prepares chart data and control classes."""
    filtered_history = history
    
    if range_arg != 'all':
        target_seconds = 0
        if range_arg == '1h': target_seconds = 3600
        elif range_arg == '24h': target_seconds = 86400
        elif range_arg == '1w': target_seconds = 604800
        elif range_arg == '1m': target_seconds = 2592000 # 30 Days
        
        if target_seconds > 0:
            cutoff_timestamp = time.time() - target_seconds
            filtered_history = [x for x in history if x['timestamp'] >= cutoff_timestamp]

    return {
        'chart_labels': ",".join([f"'{x['t']}'" for x in filtered_history]),
        'chart_data': ",".join([str(x['v']) for x in filtered_history]),
        'chart_p2pool': ",".join([str(x.get('v_p2pool', 0)) for x in filtered_history]),
        'chart_xvb': ",".join([str(x.get('v_xvb', 0)) for x in filtered_history]),
        'cls_1h': 'active' if range_arg == '1h' else '',
        'cls_24h': 'active' if range_arg == '24h' else '',
        'cls_1w': 'active' if range_arg == '1w' else '',
        'cls_1m': 'active' if range_arg == '1m' else ''
    }

def _get_worker_rows(workers):
    """Generates HTML rows for the worker table."""
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
    """Extracts Tari specific metrics."""
    tari_stats = data.get('tari', {})
    tari_active = tari_stats.get('active', False)
    return {
        'tari_status': tari_stats.get('status', 'Waiting...') if tari_active else 'Waiting...',
        'tari_status_class': "status-ok" if tari_active else "",
        'tari_reward': f"{tari_stats.get('reward', 0):.2f} TARI",
        'tari_height': str(tari_stats.get('height', 0)),
        'tari_diff': f"{int(tari_stats.get('difficulty', 0)):,}",
        'tari_wallet': tari_stats.get('address', 'Unknown')
    }

def _get_system_context(data):
    """Extracts and formats system resource metrics."""
    system = data.get('system', {})
    disk_usage = system.get('disk', {})
    disk_percent = disk_usage.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""
    
    mem_usage = system.get('memory', {})
    load_raw = system.get('load', "0.00 0.00 0.00")
    load_parts = load_raw.split()
    load_avg = f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}" if len(load_parts) == 3 else load_raw

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
        'mem_p': mem_usage.get('percent_str', '0%'),
        'mem_used': f"{mem_usage.get('used_gb', 0):.1f}",
        'mem_total': f"{mem_usage.get('total_gb', 0):.1f}",
        'cpu_load': load_avg,
        'cpu_percent': system.get('cpu_percent', "0.0%"),
    }

def _get_pool_network_context(data):
    """Extracts and formats pool, stratum, and network metrics."""
    pool_stats = data.get('pool', {})
    p2p_stats = pool_stats.get('p2p', {})
    local_pool = pool_stats.get('pool', {})
    stratum_stats = data.get('stratum', {})
    network_stats = data.get('network', {})

    net_hash_val = str(network_stats.get('hash', 'N/A'))
    if len(net_hash_val) > 20:
        net_hash_val = f"{net_hash_val[:8]}...{net_hash_val[-8:]}"

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
        'strat_wallet': stratum_stats.get('wallet', 'Unknown'),
        'p2p_type': p2p_stats.get('type', 'Unknown'),
        'pool_height': local_pool.get('height', 0),
        'pool_diff': f"{local_pool.get('difficulty', 0)/1e6:.2f} M",
        'pool_hr': format_hashrate(local_pool.get('hashrate', 0)),
        'pool_total_hashes': local_pool.get('total_hashes', 0),
        'pool_miners': local_pool.get('miners', 0),
        'pplns_win': f"{local_pool.get('pplns_window', 0)} ({format_duration(local_pool.get('pplns_window', 0) * 10)})",
        'pplns_wgt': local_pool.get('pplns_weight', 0),
        'pool_shares_window': f"<span class='status-ok'>True</span>" if local_pool.get('shares_in_window', 0) > 0 else f"<span class='status-bad'>False</span>",
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
    """Calculates algorithm switching logic, tiers, and hashrate averages."""
    xvb_stats = state_mgr.get_xvb_stats() or {}
    current_mode = xvb_stats.get('current_mode', 'P2POOL')
    mode_color = "#238636"
    if "XVB" in current_mode: mode_color = "#a371f7"
    if "Split" in current_mode: mode_color = "#58a6ff"
    if not ENABLE_XVB: current_mode = "P2POOL (XvB Disabled)"

    total_hr_val = data.get('total_live_h15', 0)
    xvb_1h_val = xvb_stats.get('avg_1h', 0)
    xvb_24h_val = xvb_stats.get('avg_24h', 0)

    if history:
        cutoff_1h = time.time() - 3600
        recent_p2p = [x.get('v_p2pool', 0) for x in history if x.get('timestamp', 0) > cutoff_1h]
        p2p_1h_val = sum(recent_p2p) / len(recent_p2p) if recent_p2p else max(0, total_hr_val - xvb_1h_val)
    else:
        p2p_1h_val = max(0, total_hr_val - xvb_1h_val)
    p2p_24h_val = max(0, total_hr_val - xvb_24h_val)

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
    Request handler for the dashboard index page.
    Aggregates data and renders the HTML template.
    """
    app = request.app
    data = app['latest_data']
    state_mgr = app['state_manager']
    
    try:
        history = state_mgr.get_history()
        range_arg = request.query.get('range', 'all')

        # Build Contexts
        chart_ctx = _get_chart_context(history, range_arg)
        system_ctx = _get_system_context(data)
        pool_net_ctx = _get_pool_network_context(data)
        algo_ctx = _get_algo_context(data, state_mgr, history)
        tari_ctx = _get_tari_context(data)
        
        # Dynamic Components
        worker_rows = _get_worker_rows(data.get('workers', []))

        template = get_cached_template()
        
        response_html = template.format(
            host_ip=HOST_IP,
            worker_rows=worker_rows,
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