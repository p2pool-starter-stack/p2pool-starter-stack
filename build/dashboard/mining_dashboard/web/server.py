import os
import time
from aiohttp import web

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
    
    # Determine color based on mode (Green=P2Pool, Purple=XvB, Blue=Split)
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
        tari_section = f"""
        <div class="card">
            <h3>Tari Merge Mining</h3>
            <div class="stat-grid">
                <div class="stat-item"><h5>Height</h5><p>{tari.get('height', 0)}</p></div>
                <div class="stat-item"><h5>Status</h5><p class="status-ok">{tari.get('status', 'Unknown')}</p></div>
                <div class="stat-item"><h5>Algo</h5><p>Sha3</p></div>
                <div class="stat-item"><h5>Diff</h5><p>{tari.get('difficulty', 0)}</p></div>
            </div>
        </div>
        """

    # 5. Read Template and Inject Data
    try:
        with open(TEMPLATE_PATH, 'r') as f:
            template = f.read()

        html = template.format(
            # --- Header & Algo ---
            mode_name=current_mode,
            mode_color=mode_color,
            total_hr=format_hr(data.get('total_live_h15', 0)),
            xvb_24h=format_hr(xvb.get('24h_avg', 0)),
            xvb_1h=format_hr(xvb.get('1h_avg', 0)),
            xvb_updated=format_time_abs(xvb.get('last_update', 0)),

            # --- Pool ---
            pool_hr=format_hr(data.get('pool', {}).get('hashrate', 0)),
            pool_miners=data.get('pool', {}).get('miners', 0),
            pool_blocks=data.get('pool', {}).get('blocks_found', 0),
            pool_shares=data.get('pool', {}).get('shares_found', 0),

            # --- Network ---
            net_height=data.get('network', {}).get('height', 0),
            net_diff=f"{data.get('network', {}).get('difficulty', 0)/1e9:.2f} G",
            net_reward=f"{data.get('network', {}).get('reward', 0)/1e12:.4f} XMR",
            net_time=format_time_abs(data.get('network', {}).get('timestamp', 0)),

            # --- System ---
            disk_p=data.get('system', {}).get('disk', {}).get('percent_str', '0%'),
            hp_val=data.get('system', {}).get('hugepages', ["?", "?", "0/0"])[2],
            hp_class=data.get('system', {}).get('hugepages', ["?", "status-warn", "0/0"])[1],

            # --- Dynamic Components ---
            worker_rows=worker_rows,
            tari_section=tari_section,
            chart_labels=",".join(chart_labels),
            chart_data=",".join(chart_values)
        )
        return web.Response(text=html, content_type='text/html')
        
    except Exception as e:
        return web.Response(text=f"<h1>Error rendering dashboard</h1><p>{str(e)}</p>", status=500)

def create_app(state_manager, latest_data_ref):
    """Factory to create the web app instance."""
    app = web.Application()
    # Pass shared state objects to the app context
    app['state_manager'] = state_manager
    app['latest_data'] = latest_data_ref
    
    app.add_routes([web.get('/', handle_index)])
    return app