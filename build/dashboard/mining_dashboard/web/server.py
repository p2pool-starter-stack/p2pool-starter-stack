import os
import time
from aiohttp import web
from config import HOST_IP

# Path to the template file
TEMPLATE_PATH = os.path.join(os.path.dirname(__file__), "templates", "index.html")

# --- Helper Formatting Functions ---

def format_hr(h):
    """Formats hashrate (float) to H/s, kH/s, or MH/s"""
    try:
        val = float(h)
        if val >= 1_000_000: return f"{val/1_000_000:.2f} MH/s"
        if val >= 1_000: return f"{val/1_000:.2f} kH/s"
        return f"{int(val)} H/s"
    except (ValueError, TypeError): return "0 H/s"

def format_duration(seconds):
    """Formats uptime seconds into 2d 4h 30m"""
    try:
        seconds = int(seconds)
        d = seconds // (3600 * 24)
        h = (seconds // 3600) % 24
        m = (seconds // 60) % 60
        s = seconds % 60
        if d > 0: return f"{d}d {h}h {m}m"
        if h > 0: return f"{h}h {m}m"
        return f"{m}m {s}s"
    except: return "0s"

def format_time_abs(ts):
    """Formats unix timestamp to HH:MM:SS"""
    if not ts: return "Never"
    try:
        return time.strftime('%H:%M:%S', time.localtime(ts))
    except: return "Invalid Time"

# --- Request Handler ---

async def handle_index(request):
    """Renders the dashboard with the latest data state."""
    app = request.app
    
    # Retrieve data from Main Loop and State Manager
    data = app['latest_data']
    state_mgr = app['state_manager']
    
    # 1. Get Historical Data for Chart
    history = state_mgr.state.get('hashrate_history', [])
    chart_labels = [f"'{x['t']}'" for x in history]
    chart_values = [str(x['v']) for x in history]

    # 2. Get Algo / XvB Stats
    xvb = state_mgr.get_xvb_stats()
    current_mode = xvb.get('current_mode', 'P2POOL')
    
    # Determine color based on mode
    mode_color = "#238636"  # Green default
    if "XVB" in current_mode: mode_color = "#a371f7"
    if "Split" in current_mode: mode_color = "#58a6ff"

    # 3. Build Worker Table Rows
    worker_rows = ""
    workers = data.get('workers', [])
    # Sort: Online first, then by Name
    workers.sort(key=lambda x: (x['status'] != 'online', x['name']))
    
    for w in workers:
        status_class = "status-ok" if w['status'] == 'online' else "status-bad"
        row = f"""
        <tr class="{status_class}">
            <td>{w['name']}</td>
            <td>{w['ip']}</td>
            <td>{format_duration(w.get('uptime', 0))}</td>
            <td>{format_hr(w.get('h10', 0))}</td>
            <td>{format_hr(w.get('h60', 0))}</td>
            <td>{format_hr(w.get('h15', 0))}</td>
        </tr>
        """
        worker_rows += row

    # 4. Build Tari Section (Conditional)
    tari = data.get('tari', {})
    tari_section = ""
    
    if tari.get('active'):
        # Format difficulty with commas
        tari_diff = f"{int(tari.get('difficulty', 0)):,}"
        tari_section = f"""
        <div class="card">
            <h3>Tari Merge Mining</h3>
            <div class="stat-grid">
                <div class="stat-card"><h5>Status</h5><p class="status-ok">{tari.get('status', 'Unknown')}</p></div>
                <div class="stat-card"><h5>Reward</h5><p>{tari.get('reward', 0):.2f} TARI</p></div>
                <div class="stat-card"><h5>Height</h5><p>{tari.get('height', 0)}</p></div>
                <div class="stat-card"><h5>Difficulty</h5><p>{tari_diff}</p></div>
            </div>
            <div style="font-size:10px; color:#666; margin-top:10px; overflow-wrap: break-word;">Wallet: {tari.get('address', 'Unknown')}</div>
        </div>
        """
    else:
        # Optional: Show a placeholder if Tari is not active, or keep it empty
        tari_section = '<div class="card"><h3>Tari</h3><p>Waiting for data...</p></div>'

    # 5. Safe Data Extraction (Prevents KeyErrors)
    # Disk Usage
    disk = data.get('system', {}).get('disk', {})
    disk_percent = disk.get('percent', 0)
    disk_fill = "critical" if disk_percent > 90 else "warning" if disk_percent > 70 else ""
    
    # Hugepages (Expects tuple: status_text, css_class, val_str)
    hp = data.get('system', {}).get('hugepages', ["Disabled", "status-bad", "0/0"])
    
    # Pool Stats (Deep nested gets)
    pool_stats = data.get('pool', {})
    p2p_stats = pool_stats.get('p2p', {})
    local_pool = pool_stats.get('pool', {})
    
    # Stratum Stats
    strat = data.get('stratum', {})

    # Network Stats
    net = data.get('network', {})

    # 6. Read Template and Inject Data
    try:
        # --- NEW LOGIC: Calculate Split ---
        total_hr_val = data.get('total_live_h15', 0)
        xvb_1h_val = xvb.get('1h_avg', 0)
        xvb_24h_val = xvb.get('24h_avg', 0)

        # Calculate P2Pool portion (Total - XvB)
        # We use max(0, ...) to ensure we don't display negative numbers if averages drift
        p2p_1h_val = max(0, total_hr_val - xvb_1h_val)
        p2p_24h_val = max(0, total_hr_val - xvb_24h_val)
        # ----------------------------------

        with open(TEMPLATE_PATH, 'r') as f:
            template = f.read()

        html = template.format(
            host_ip=HOST_IP,

            # --- Header & Algo ---
            mode_name=current_mode,
            mode_color=mode_color,
            p2p_type=p2p_stats.get('type', 'Unknown'),
            total_hr=format_hr(total_hr_val),
            last_update=format_time_abs(time.time()),
            xvb_updated=format_time_abs(xvb.get('last_update', 0)),
            
            # Updated: Send split values to template
            p2p_1h=format_hr(p2p_1h_val),
            p2p_24h=format_hr(p2p_24h_val),
            xvb_1h=format_hr(xvb_1h_val),
            xvb_24h=format_hr(xvb_24h_val),

            # --- System Resources ---
            hp_status=hp[0],
            hp_class=hp[1],
            hp_val=hp[2],
            disk_used=disk.get('used_gb', 0),
            disk_total=disk.get('total_gb', 0),
            disk_p=disk.get('percent_str', '0%'),
            disk_width=f"{disk_percent}%",
            disk_fill_class=disk_fill,

            # --- Stratum Pool ---
            strat_h15=format_hr(strat.get('hashrate_15m', 0)),
            strat_h1h=format_hr(strat.get('hashrate_1h', 0)),
            strat_h24h=format_hr(strat.get('hashrate_24h', 0)),
            strat_shares=f"{strat.get('shares_valid',0)} / {strat.get('shares_invalid',0)}",
            strat_effort=f"{strat.get('block_effort', 0):.1f}%",
            strat_total_shares=strat.get('total_shares', 0),
            strat_reward_pct=f"{strat.get('reward_share_pct', 0):.4f}%",
            strat_conns=strat.get('connections', 0),
            strat_last_share=format_time_abs(strat.get('last_share_ts', 0)),
            strat_total_hashes=strat.get('total_hashes', 0),
            strat_wallet=strat.get('wallet', 'Unknown'),

            # --- P2Pool Network ---
            pool_height=local_pool.get('height', 0),
            pool_diff=f"{local_pool.get('difficulty', 0)/1e6:.2f} M",
            pool_hr=format_hr(local_pool.get('hashrate', 0)),
            pool_total_hashes=local_pool.get('total_hashes', 0),
            pool_miners=local_pool.get('miners', 0),
            pplns_win=local_pool.get('pplns_window', 0),
            pplns_wgt=local_pool.get('pplns_weight', 0),
            pool_blocks=local_pool.get('blocks_found', 0),
            pool_last_blk=format_time_abs(local_pool.get('last_block_ts', 0)),
            p2p_peers=f"{p2p_stats.get('out_peers',0)} / {p2p_stats.get('in_peers',0)}",
            p2p_uptime=format_duration(p2p_stats.get('uptime', 0)),

            # --- XMR Network ---
            net_height=net.get('height', 0),
            net_reward=f"{net.get('reward', 0)/1e12:.4f} XMR",
            net_diff=f"{net.get('difficulty', 0)/1e9:.2f} G",
            net_hash=net.get('hash', 'N/A'),
            net_ts=format_time_abs(net.get('timestamp', 0)),

            # --- Dynamic Components ---
            worker_rows=worker_rows,
            tari_section=tari_section,
            chart_labels=",".join(chart_labels),
            chart_data=",".join(chart_values)
        )
        return web.Response(text=html, content_type='text/html')
        
    except Exception as e:
        # Improved error logging
        return web.Response(text=f"<h1>Error rendering dashboard</h1><p>{str(e)}</p><pre>{type(e).__name__}</pre>", status=500)

def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application()
    # Pass shared state objects to the app context
    app['state_manager'] = state_manager
    app['latest_data'] = latest_data_ref
    
    app.add_routes([web.get('/', handle_index)])
    return app