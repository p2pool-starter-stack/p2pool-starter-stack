import os
import time
from aiohttp import web
from config import HOST_IP, BLOCK_PPLNS_WINDOW_MAIN
from utils import format_hashrate, format_duration, format_time_abs

# Path to the template file
TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")

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
            # Perform template injection only upon file modification
            if "{stats_card}" not in content and "{tari_section}" in content:
                content = content.replace("{tari_section}", "{stats_card}\n{tari_section}")
            
            # Inject CPU/Mem cards before Disk if missing
            if "{cpu_load}" not in content and "<h5>Disk</h5>" in content:
                content = content.replace("<h5>Disk</h5>", "<h5>CPU Load</h5><p>{cpu_load}</p></div><div class=\"stat-card\"><h5>Memory</h5><p>{mem_p}</p></div><div class=\"stat-card\"><h5>Disk</h5>")
            _TEMPLATE_CACHE = content
            _TEMPLATE_MTIME = mtime
    except Exception as e:
        print(f"Error loading template: {e}")
    return _TEMPLATE_CACHE or "<h1>Template Error</h1>"

async def handle_index(request):
    """
    Request handler for the dashboard index page.
    
    Aggregates data from the state manager and latest data reference,
    processes statistics for display, and renders the HTML template.
    """
    app = request.app
    
    data = app['latest_data']
    state_mgr = app['state_manager']
    
    # Historical Data
    history = state_mgr.state.get('hashrate_history', [])
    chart_labels = [f"'{x['t']}'" for x in history]
    chart_values = [str(x['v']) for x in history]
    chart_p2pool = [str(x.get('v_p2pool', 0)) for x in history]
    chart_xvb = [str(x.get('v_xvb', 0)) for x in history]

    # --- Algorithm & XvB Statistics ---
    xvb_stats = state_mgr.get_xvb_stats() or {}
    current_mode = xvb_stats.get('current_mode', 'P2POOL')
    
    mode_color = "#238636"  # Default color (Green)
    if "XVB" in current_mode: mode_color = "#a371f7"
    if "Split" in current_mode: mode_color = "#58a6ff"

    # --- Worker Status & Table Generation ---
    worker_rows = ""
    workers = data.get('workers', [])
    workers.sort(key=lambda x: (x['status'] != 'online', x['name']))
    
    for worker in workers:
        status_class = "status-ok" if worker['status'] == 'online' else "status-bad"
        
        # Identify and assign pool badge based on port
        active_pool = worker.get('active_pool', '')
        pool_badge = "Unknown"
        if any(p in active_pool for p in ['3333', '37889', '37888', '37890']):
            pool_badge = "<span style='background:#238636; color:white; padding:2px 5px; border-radius:4px; font-size:0.8em;'>P2Pool</span>"
        elif any(p in active_pool for p in ['3344', '4247']):
            pool_badge = "<span style='background:#a371f7; color:white; padding:2px 5px; border-radius:4px; font-size:0.8em;'>XvB</span>"
        
        name_display = f"{worker['name']} {pool_badge}"

        # Add data-sort attributes for client-side sorting
        uptime_val = worker.get('uptime', 0)
        h10_val = worker.get('h10', 0)
        h60_val = worker.get('h60', 0)
        h15_val = worker.get('h15', 0)

        # Convert IP address to integer for sorting purposes
        try:
            ip_parts = [int(part) for part in worker.get('ip', '0.0.0.0').split('.')]
            ip_sort_val = (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3]
        except:
            ip_sort_val = 0

        row = f"""
        <tr class="{status_class}">
            <td data-sort="{worker['name']}">{name_display}</td>
            <td data-sort="{ip_sort_val}">{worker['ip']}</td>
            <td data-sort="{uptime_val}">{format_duration(uptime_val)}</td>
            <td data-sort="{h10_val}">{format_hashrate(h10_val)}</td>
            <td data-sort="{h60_val}">{format_hashrate(h60_val)}</td>
            <td data-sort="{h15_val}">{format_hashrate(h15_val)}</td>
        </tr>
        """
        worker_rows += row

    # --- Tari Merge Mining Section ---
    tari_stats = data.get('tari', {})
    tari_section = ""
    
    if tari_stats.get('active'):
        # Format difficulty with comma separators
        tari_diff = f"{int(tari_stats.get('difficulty', 0)):,}"
        tari_section = f"""
        <div class="card">
            <h3>Tari Merge Mining</h3>
            <div class="stat-grid">
                <div class="stat-card"><h5>Status</h5><p class="status-ok">{tari_stats.get('status', 'Unknown')}</p></div>
                <div class="stat-card"><h5>Reward</h5><p>{tari_stats.get('reward', 0):.2f} TARI</p></div>
                <div class="stat-card"><h5>Height</h5><p>{tari_stats.get('height', 0)}</p></div>
                <div class="stat-card"><h5>Difficulty</h5><p>{tari_diff}</p></div>
            </div>
            <div style="font-size:10px; color:#666; margin-top:10px; overflow-wrap: break-word;">Wallet: {tari_stats.get('address', 'Unknown')}</div>
        </div>
        """
    else:
        tari_section = '<div class="card"><h3>Tari</h3><p>Waiting for data...</p></div>'

    # --- System and Pool Metrics ---
    disk_usage = data.get('system', {}).get('disk', {})
    disk_percent = disk_usage.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""
    
    mem_usage = data.get('system', {}).get('memory', {})
    load_raw = data.get('system', {}).get('load', "0.00 0.00 0.00")
    
    # Format load average with labels
    load_parts = load_raw.split()
    if len(load_parts) == 3:
        load_avg = f"1m: {load_parts[0]} 5m: {load_parts[1]} 15m: {load_parts[2]}"
    else:
        load_avg = load_raw

    cpu_percent = data.get('system', {}).get('cpu_percent', "0.0%")
    
    hugepages_info = data.get('system', {}).get('hugepages', ["Disabled", "status-bad", "0/0"])
    hp_status, hp_class, hp_val = hugepages_info
    
    pool_stats = data.get('pool', {})
    p2p_stats = pool_stats.get('p2p', {})
    local_pool = pool_stats.get('pool', {})
    
    # Stratum Statistics
    stratum_stats = data.get('stratum', {})

    # Network Statistics
    network_stats = data.get('network', {})

    try:
        # --- Split Mining Calculations ---
        total_hr_val = data.get('total_live_h15', 0)
        xvb_1h_val = xvb_stats.get('1h_avg', 0)
        xvb_24h_val = xvb_stats.get('24h_avg', 0)

        # Derive P2Pool 1h average from history for improved accuracy
        if history:
            p2p_vals = [x.get('v_p2pool', 0) for x in history]
            p2p_1h_val = sum(p2p_vals) / len(p2p_vals) if p2p_vals else 0
        else:
            p2p_1h_val = max(0, total_hr_val - xvb_1h_val)
            
        p2p_24h_val = max(0, total_hr_val - xvb_24h_val)

        # --- Status Card Construction ---
        mode_card = f"""
        <div class="card">
            <h3>P2Pool Status</h3>
            <div class="stat-grid">
                <div class="stat-card"><h5>Current Mode</h5><p style="color:{mode_color}">{current_mode}</p></div>
                <div class="stat-card"><h5>1h Avg</h5><p>{format_hashrate(p2p_1h_val)}</p></div>
                <div class="stat-card"><h5>24h Avg (Est.)</h5><p>{format_hashrate(p2p_24h_val)}</p></div>
                <div class="stat-card"><h5>Total Hashrate</h5><p>{format_hashrate(total_hr_val)}</p></div>
            </div>
        </div>
        """

        # Determine Donation Tier based on 24h average hashrate
        tier_name = "Standard"
        if xvb_24h_val >= 1_000_000: tier_name = "Mega (1 MH/s+)"
        elif xvb_24h_val >= 100_000: tier_name = "Whale (100 kH/s+)"
        elif xvb_24h_val >= 10_000: tier_name = "VIP (10 kH/s+)"
        elif xvb_24h_val >= 5_000: tier_name = "MVP (5 kH/s+)"
        elif xvb_24h_val >= 1_000: tier_name = "Donor (1 kH/s+)"

        xvb_card = f"""
        <div class="card">
            <h3>XvB Donation Status</h3>
            <div class="stat-grid">
                <div class="stat-card"><h5>Donation Tier</h5><p>{tier_name}</p></div>
                <div class="stat-card"><h5>1h Avg (Pool)</h5><p>{format_hashrate(xvb_1h_val)}</p></div>
                <div class="stat-card"><h5>24h Avg (Pool)</h5><p>{format_hashrate(xvb_24h_val)}</p></div>
                <div class="stat-card"><h5>Fail Count</h5><p>{xvb_stats.get('fail_count', 0)}</p></div>
            </div>
            <div style="font-size:10px; color:#666; margin-top:10px;">Stats fetched from xmrvsbeast.com</div>
        </div>
        """

        stats_card = mode_card + xvb_card

        template = get_cached_template()

        # Format Block Hash
        net_hash_val = str(network_stats.get('hash', 'N/A'))
        if len(net_hash_val) > 20:
            net_hash_val = f"{net_hash_val[:8]}...{net_hash_val[-8:]}"

        html = template.format(
            host_ip=HOST_IP,

            # --- Header & Algo ---
            mode_name=current_mode,
            mode_color=mode_color,
            p2p_type=p2p_stats.get('type', 'Unknown'),
            total_hr=format_hashrate(total_hr_val),
            last_update=format_time_abs(time.time()),
            xvb_updated=format_time_abs(xvb_stats.get('last_update', 0)),
            
            # Pass split mining metrics to the template context
            p2p_1h=format_hashrate(p2p_1h_val),
            p2p_24h=format_hashrate(p2p_24h_val),
            xvb_1h=format_hashrate(xvb_1h_val),
            xvb_24h=format_hashrate(xvb_24h_val),

            # --- System Resources ---
            hp_status=hp_status,
            hp_class=hp_class,
            hp_val=hp_val,
            disk_used=disk_usage.get('used_gb', 0),
            disk_total=disk_usage.get('total_gb', 0),
            disk_p=disk_usage.get('percent_str', '0%'),
            disk_width=f"{disk_percent}%",
            disk_fill_class=disk_fill,
            mem_p=mem_usage.get('percent_str', '0%'),
            mem_used=f"{mem_usage.get('used_gb', 0):.1f}",
            mem_total=f"{mem_usage.get('total_gb', 0):.1f}",
            cpu_load=load_avg,
            cpu_percent=cpu_percent,

            # --- Stratum Pool ---
            strat_h15=format_hashrate(stratum_stats.get('hashrate_15m', 0)),
            strat_h1h=format_hashrate(stratum_stats.get('hashrate_1h', 0)),
            strat_h24h=format_hashrate(stratum_stats.get('hashrate_24h', 0)),
            strat_shares=f"{stratum_stats.get('shares_valid',0)} / {stratum_stats.get('shares_invalid',0)}",
            strat_effort=f"{stratum_stats.get('block_effort', 0):.1f}%",
            strat_total_shares=stratum_stats.get('total_shares', 0),
            strat_reward_pct=f"{stratum_stats.get('reward_share_pct', 0):.4f}%",
            strat_conns=stratum_stats.get('connections', 0),
            strat_last_share=format_time_abs(stratum_stats.get('last_share_ts', 0)),
            strat_total_hashes=stratum_stats.get('total_hashes', 0),
            strat_wallet=stratum_stats.get('wallet', 'Unknown'),

            # --- P2Pool Network ---
            pool_height=local_pool.get('height', 0),
            pool_diff=f"{local_pool.get('difficulty', 0)/1e6:.2f} M",
            pool_hr=format_hashrate(local_pool.get('hashrate', 0)),
            pool_total_hashes=local_pool.get('total_hashes', 0),
            pool_miners=local_pool.get('miners', 0),
            pplns_win=f"{local_pool.get('pplns_window', 0)} ({format_duration(local_pool.get('pplns_window', 0) * 10)})",
            pplns_wgt=local_pool.get('pplns_weight', 0),
            pool_blocks=local_pool.get('blocks_found', 0),
            pool_last_blk=format_time_abs(local_pool.get('last_block_ts', 0)),
            p2p_peers=f"{p2p_stats.get('out_peers',0)} / {p2p_stats.get('in_peers',0)}",
            p2p_uptime=format_duration(p2p_stats.get('uptime', 0)),

            # --- XMR Network ---
            net_height=network_stats.get('height', 0),
            net_reward=f"{network_stats.get('reward', 0)/1e12:.4f} XMR",
            net_diff=f"{network_stats.get('difficulty', 0)/1e9:.2f} G",
            net_hash=net_hash_val,
            net_ts=format_time_abs(network_stats.get('timestamp', 0)),

            # --- Dynamic Components ---
            worker_rows=worker_rows,
            tari_section=tari_section,
            stats_card=stats_card,
            chart_labels=",".join(chart_labels),
            chart_data=",".join(chart_values),
            chart_p2pool=",".join(chart_p2pool),
            chart_xvb=",".join(chart_xvb)
        )

        # Inject client-side table sorting logic (appended to body)
        sorting_script = """
<script>
document.addEventListener('DOMContentLoaded', function() {
    const getCellValue = (tr, idx) => tr.children[idx].getAttribute('data-sort') || tr.children[idx].innerText || tr.children[idx].textContent;

    const comparer = (idx, asc) => (a, b) => ((v1, v2) => 
        v1 !== '' && v2 !== '' && !isNaN(v1) && !isNaN(v2) ? v1 - v2 : v1.toString().localeCompare(v2)
    )(getCellValue(asc ? a : b, idx), getCellValue(asc ? b : a, idx));

    document.querySelectorAll('th').forEach(th => {
        th.style.cursor = 'pointer';
        th.addEventListener('click', (() => {
            const table = th.closest('table');
            if (!table) return;
            const tbody = table.querySelector('tbody');
            Array.from(tbody.querySelectorAll('tr'))
                .sort(comparer(Array.from(th.parentNode.children).indexOf(th), this.asc = !this.asc))
                .forEach(tr => tbody.appendChild(tr) );
        }));
    });
});
</script>
"""
        if "</body>" in html:
            html = html.replace("</body>", sorting_script + "</body>")
        else:
            html += sorting_script

        return web.Response(text=html, content_type='text/html')
        
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