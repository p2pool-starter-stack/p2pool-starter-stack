import json
import os
import shutil
import time
import asyncio
from aiohttp import web, ClientSession, ClientTimeout
from datetime import timedelta, datetime

# --- CONFIGURATION ---
BASE_STATS_DIR = "/app/stats"
STRATUM_STATS_PATH = f"{BASE_STATS_DIR}/local/stratum"
TARI_STATS_PATH = f"{BASE_STATS_DIR}/local/merge_mining"
P2P_STATS_PATH = f"{BASE_STATS_DIR}/local/p2p"
POOL_STATS_PATH = f"{BASE_STATS_DIR}/pool/stats"
NETWORK_STATS_PATH = f"{BASE_STATS_DIR}/network/stats"

DISK_PATH = '/data'
XMRIG_API_PORT = 8080
API_TIMEOUT = 1         
UPDATE_INTERVAL = 30 

LATEST_DATA = {}
HASHRATE_HISTORY = []

def format_hr(h):
    try:
        val = float(h)
        if val >= 1_000_000: return f"{val/1_000_000:.2f} MH/s"
        if val >= 1000: return f"{val/1000:.2f} KH/s"
        return f"{int(val)} H/s"
    except: return "0 H/s"

def format_big_num(n):
    """Formats large numbers (hashes/weights) into readable k/M/G/T/P format."""
    try:
        n = float(n)
        if n == 0: return "0"
        units = ['', 'k', 'M', 'G', 'T', 'P', 'E', 'Z']
        for unit in units:
            if abs(n) < 1000: return f"{n:.2f}{unit}"
            n /= 1000
        return f"{n:.2f}Y"
    except: return "0"

def format_time_abs(ts):
    """Formats a unix timestamp into HH:MM:SS."""
    try:
        if not ts or int(ts) == 0: return "Never"
        return datetime.fromtimestamp(int(ts)).strftime('%H:%M:%S')
    except: return "Never"

def format_uptime(seconds):
    try: return str(timedelta(seconds=int(seconds)))
    except: return "Unknown"

async def get_worker_live_stats(session, name, ip_with_port):
    ip = ip_with_port.split(':')[0]
    targets = [name, name + ".local", ip]
    timeout = ClientTimeout(total=API_TIMEOUT)
    
    for target in targets:
        url = f"http://{target}:{XMRIG_API_PORT}/1/summary"
        try:
            async with session.get(url, timeout=timeout) as response:
                if response.status == 200:
                    data = await response.json()
                    hr_obj = data.get("hashrate", {})
                    hashrates = hr_obj.get("total", [0, 0, 0]) 
                    return {
                        "h10": hashrates[0] if len(hashrates) > 0 else 0,
                        "h60": hashrates[1] if len(hashrates) > 1 else 0,
                        "h15": hashrates[2] if len(hashrates) > 2 else 0,
                        "uptime": data.get("uptime", 0),
                        "name": data.get("worker_id", "miner")
                    }
        except: continue
    return None

def get_disk_usage(path="/"):
    try:
        usage = shutil.disk_usage(path)
        percent = (usage.used / usage.total) * 100
        return {
            "total": f"{usage.total / (1024**3):.1f} GB",
            "used": f"{usage.used / (1024**3):.1f} GB",
            "percent": f"{percent:.1f}%",
            "percent_val": percent
        }
    except: return {"total": "N/A", "used": "N/A", "percent": "0%", "percent_val": 0}

def detect_pool_type(peers):
    """Detects Main/Mini/Nano based on peer ports."""
    counts = {"Main": 0, "Mini": 0, "Nano": 0}
    for p in peers:
        if "37889" in p: counts["Main"] += 1
        elif "37888" in p: counts["Mini"] += 1
        elif "37890" in p: counts["Nano"] += 1
    winner = max(counts, key=counts.get)
    return winner if counts[winner] > 0 else "Unknown"

async def update_data_loop():
    global LATEST_DATA, HASHRATE_HISTORY
    while True:
        data = {
            "host_ip": os.environ.get("HOST_IP", "Unknown Host"),
            "now": time.strftime('%Y-%m-%d %H:%M:%S'),
            "system": {"hp_status": "Unknown", "hp_val": "0/0", "hp_class": "status-warn"},
            "disk": get_disk_usage(DISK_PATH),
            "tari": None,
            "p2p": {
                "pool_type": "Initializing...", "connections": 0, "incoming": 0,
                "peers": 0, "uptime": "0", "zmq": 0
            },
            "pool": {
                "hashrate": "0 H/s", "miners": 0, "blocks": 0, "sidechain_height": 0,
                "total_hashes": 0, "last_block_found": "N/A", "last_block_ts": 0,
                "pplns_weight": 0, "pplns_window": 0, "diff": 0
            },
            "network": {"difficulty": 0, "height": 0, "reward": 0, "hash": "N/A", "ts": 0},
            "stratum": {},
            "workers": [],
            "total_live_h15": 0
        }

        # 1. Huge Pages
        try:
            with open("/proc/meminfo", "r") as f:
                mem = f.read()
            hp_total = int([l for l in mem.split('\n') if "HugePages_Total" in l][0].split()[1])
            hp_free = int([l for l in mem.split('\n') if "HugePages_Free" in l][0].split()[1])
            data["system"]["hp_val"] = f"{hp_total - hp_free} / {hp_total}"
            if (hp_total - hp_free) > 500:
                data["system"]["hp_status"], data["system"]["hp_class"] = "HEALTHY", "status-ok"
            else:
                data["system"]["hp_status"], data["system"]["hp_class"] = "NOT DETECTED", "status-bad"
        except: pass

        # 2. P2P Stats
        if os.path.exists(P2P_STATS_PATH):
            try:
                with open(P2P_STATS_PATH, 'r') as f:
                    p2p_json = json.load(f)
                    peers = p2p_json.get("peers", [])
                    data["p2p"] = {
                        "pool_type": detect_pool_type(peers),
                        "connections": p2p_json.get("connections", 0),
                        "incoming": p2p_json.get("incoming_connections", 0),
                        "peers": p2p_json.get("peer_list_size", 0),
                        "uptime": format_uptime(p2p_json.get("uptime", 0)),
                        "zmq": p2p_json.get("zmq_last_active", 0)
                    }
            except: pass

        # 3. Pool Stats
        if os.path.exists(POOL_STATS_PATH):
            try:
                with open(POOL_STATS_PATH, 'r') as f:
                    pool_json = json.load(f)
                    stats = pool_json.get("pool_statistics", {})
                    data["pool"] = {
                        "hashrate": format_hr(stats.get("hashRate", 0)),
                        "miners": stats.get("miners", 0),
                        "blocks": stats.get("totalBlocksFound", 0),
                        "sidechain_height": f"{stats.get('sidechainHeight', 0):,}",
                        "total_hashes": format_big_num(stats.get("totalHashes", 0)),
                        "last_block_found": stats.get("lastBlockFound", 0),
                        "last_block_ts": stats.get("lastBlockFoundTime", 0),
                        "pplns_weight": format_big_num(stats.get("pplnsWeight", 0)),
                        "pplns_window": stats.get("pplnsWindowSize", 0),
                        "diff": format_big_num(stats.get("sidechainDifficulty", 0))
                    }
            except: pass

        # 4. Network Stats
        if os.path.exists(NETWORK_STATS_PATH):
            try:
                with open(NETWORK_STATS_PATH, 'r') as f:
                    net_json = json.load(f)
                    data["network"] = {
                        "difficulty": f"{net_json.get('difficulty', 0):,}",
                        "height": f"{net_json.get('height', 0):,}",
                        "reward": f"{net_json.get('reward', 0) / 1e12:.4f}",
                        "hash": net_json.get('hash', 'N/A')[:12] + "...",
                        "ts": net_json.get('timestamp', 0)
                    }
            except: pass

        # 5. Tari Stats
        if os.path.exists(TARI_STATS_PATH):
            try:
                with open(TARI_STATS_PATH, 'r') as f:
                    t_json = json.load(f)
                    chains = t_json.get("chains", [])
                    if chains:
                        t = chains[0]
                        data["tari"] = {
                            "status": t.get('channel_state', 'UNKNOWN'),
                            "address": t.get('wallet', 'Unknown'),
                            "height": t.get('height', 0),
                            "reward": t.get('reward', 0) / 1_000_000,
                            "diff": f"{t.get('difficulty', 0):,}"
                        }
            except: pass

        # 6. Stratum & Workers
        if os.path.exists(STRATUM_STATS_PATH):
            try:
                with open(STRATUM_STATS_PATH, 'r') as f:
                    s_json = json.load(f)
                    data["stratum"] = s_json
                    
                    async with ClientSession() as session:
                        tasks = []
                        worker_meta = []
                        for w_entry in s_json.get("workers", []):
                            if isinstance(w_entry, str):
                                parts = w_entry.split(',')
                                ip_label, name = parts[0], (parts[4] if len(parts) >= 5 else "miner")
                                worker_meta.append({'parts': parts, 'ip': ip_label, 'name': name})
                                tasks.append(get_worker_live_stats(session, name, ip_label))
                        
                        results = await asyncio.gather(*tasks)

                        for meta, live in zip(worker_meta, results):
                            if live:
                                w_data = {
                                    "name": meta['name'], "ip": meta['ip'], "status": "online",
                                    "up": format_uptime(live['uptime']),
                                    "h10": format_hr(live['h10']), "h60": format_hr(live['h60']), "h15": format_hr(live['h15'])
                                }
                                data["total_live_h15"] += (live['h15'] or 0)
                            else:
                                raw_h15 = float(meta['parts'][3]) if len(meta['parts']) >= 4 else 0
                                w_data = {
                                    "name": meta['name'], "ip": meta['ip'], "status": "offline",
                                    "up": format_uptime(meta['parts'][1]) if len(meta['parts']) >= 2 else "0",
                                    "h10": "OFFLINE", "h60": "OFFLINE", "h15": format_hr(raw_h15)
                                }
                                data["total_live_h15"] += raw_h15
                            data["workers"].append(w_data)
            except: pass

        HASHRATE_HISTORY.append({"t": time.strftime('%H:%M'), "v": data["total_live_h15"]})
        if len(HASHRATE_HISTORY) > 30: HASHRATE_HISTORY.pop(0)
        
        LATEST_DATA = data
        await asyncio.sleep(UPDATE_INTERVAL)

async def handle_get(request):
    d = LATEST_DATA
    if not d: return web.Response(text="Initializing data...", status=503)

    rows = "".join([f"""
        <tr>
            <td><span class="dot {w['status']}"></span>{w['name']}</td>
            <td>{w['ip']}</td>
            <td>{w['up']}</td>
            <td>{w['h10']}</td>
            <td>{w['h60']}</td>
            <td class="bold">{w['h15']}</td>
        </tr>""" for w in d["workers"]])

    tari_section = f"""
        <div class="card">
            <h3>Tari Merge Mining</h3>
            <div class="stat-grid">
                <div class="stat-card"><h5>Status</h5><p>{d['tari']['status']}</p></div>
                <div class="stat-card"><h5>Reward</h5><p>{d['tari']['reward']:.2f} TARI</p></div>
                <div class="stat-card"><h5>Height</h5><p>{d['tari']['height']}</p></div>
                <div class="stat-card"><h5>Difficulty</h5><p>{d['tari']['diff']}</p></div>
            </div>
            <div style="font-size:10px; color:#666; margin-top:10px; overflow-wrap: break-word;">Wallet: {d['tari']['address']}</div>
        </div>""" if d['tari'] else '<div class="card"><h3>Tari</h3><p>Waiting for data...</p></div>'

    html = f"""
    <!DOCTYPE html><html><head><title>Mining Dashboard</title><meta http-equiv="refresh" content="30">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        :root {{ --bg: #0d1117; --card: #161b22; --border: #30363d; --text: #c9d1d9; --accent: #58a6ff; --ok: #238636; --bad: #da3633; --warn: #d29922; }}
        body {{ font-family: -apple-system, sans-serif; background: var(--bg); color: var(--text); padding: 20px; }}
        .container {{ max-width: 1200px; margin: auto; }}
        .header {{ display: flex; justify-content: space-between; border-bottom: 1px solid var(--border); padding-bottom: 10px; margin-bottom: 20px; }}
        .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(350px, 1fr)); gap: 20px; margin-bottom: 20px; }}
        .card {{ background: var(--card); border: 1px solid var(--border); border-radius: 6px; padding: 15px; }}
        h3 {{ margin: 0 0 15px 0; font-size: 14px; text-transform: uppercase; color: #8b949e; }}
        .stat-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }}
        .stat-card {{ background: #0d1117; padding: 10px; border-radius: 4px; border: 1px solid var(--border); }}
        .stat-card h5 {{ margin: 0; font-size: 10px; color: #8b949e; }}
        .stat-card p {{ margin: 5px 0 0 0; font-weight: bold; font-size: 16px; }}
        table {{ width: 100%; border-collapse: collapse; }}
        th {{ text-align: left; font-size: 12px; color: #8b949e; padding: 10px; border-bottom: 1px solid var(--border); }}
        td {{ padding: 10px; border-bottom: 1px solid #21262d; font-size: 13px; }}
        .dot {{ height: 8px; width: 8px; border-radius: 50%; display: inline-block; margin-right: 8px; }}
        .online {{ background: var(--ok); box-shadow: 0 0 5px var(--ok); }} .offline {{ background: var(--bad); }}
        .status-ok {{ color: var(--ok); }} .status-bad {{ color: var(--bad); }} .status-warn {{ color: var(--warn); }}
        .bold {{ font-weight: bold; color: var(--accent); }}
        .progress-bg {{ background: var(--border); border-radius: 4px; height: 10px; width: 100%; margin-top: 5px; }}
        .progress-fill {{ background: var(--accent); height: 100%; border-radius: 4px; transition: width 0.5s; }}
        .progress-fill.warning {{ background: var(--warn); }} .progress-fill.critical {{ background: var(--bad); }}
        .pool-badge {{ background: var(--accent); color: #000; padding: 2px 6px; border-radius: 4px; font-size: 12px; vertical-align: middle; margin-left: 10px; font-weight: bold; }}
    </style></head>
    <body><div class="container">
        <div class="header">
            <div>
                <div style="display:flex; align-items:center;">
                    <h2 style="margin:0">{d['host_ip']}</h2>
                    <span class="pool-badge">P2Pool {d['p2p']['pool_type']}</span>
                </div>
                <span class="{d['system']['hp_class']}">Huge Pages: {d['system']['hp_status']} ({d['system']['hp_val']})</span>
                <div style="margin-top: 5px; font-size: 12px; color: #8b949e;">
                    Disk: {d['disk']['used']} / {d['disk']['total']} ({d['disk']['percent']})
                    <div class="progress-bg"><div class="progress-fill {'critical' if d['disk']['percent_val'] > 90 else 'warning' if d['disk']['percent_val'] > 75 else ''}" style="width: {d['disk']['percent']}"></div></div>
                </div>
            </div>
            <div style="text-align: right">
                <div style="font-size: 18px; font-weight: bold;">{format_hr(d['total_live_h15'])}</div>
                <small style="color:#8b949e">Last Update: {d['now']}</small>
            </div>
        </div>
        <div class="grid">
            <div class="card"><canvas id="hChart" height="180"></canvas></div>
            
            <div class="card">
                <h3>Stratum Pool</h3>
                <div class="stat-grid">
                    <div class="stat-card" style="grid-column: span 2;">
                        <h5>Hashrate (15m / 1h / 24h)</h5>
                        <p style="font-size: 11px; line-height: 1.4;">
                            {format_hr(d['stratum'].get('hashrate_15m'))} / 
                            {format_hr(d['stratum'].get('hashrate_1h'))} / 
                            {format_hr(d['stratum'].get('hashrate_24h'))}
                        </p>
                    </div>
                    <div class="stat-card"><h5>Shares (OK/Err)</h5><p>{d['stratum'].get('shares_found', 0)} / {d['stratum'].get('shares_failed',0)}</p></div>
                    <div class="stat-card"><h5>Effort (Curr/Avg)</h5><p>{d['stratum'].get('current_effort',0):.2f}% / {d['stratum'].get('average_effort',0):.2f}%</p></div>
                    <div class="stat-card"><h5>Total Shares</h5><p>{format_big_num(d['stratum'].get('total_stratum_shares',0))}</p></div>
                    <div class="stat-card"><h5>Reward Share</h5><p>{d['stratum'].get('block_reward_share_percent',0):.3f}%</p></div>
                    <div class="stat-card"><h5>Connections</h5><p>In: {d['stratum'].get('incoming_connections',0)} / Out: {d['stratum'].get('connections',0)}</p></div>
                    <div class="stat-card"><h5>Last Share</h5><p>{format_time_abs(d['stratum'].get('last_share_found_time', 0))}</p></div>
                    <div class="stat-card" style="grid-column: span 2;"><h5>Total Hashes</h5><p>{format_big_num(d['stratum'].get('total_hashes',0))}</p></div>
                </div>
                <div style="font-size:10px; color:#666; margin-top:10px; overflow-wrap: break-word;">Wallet: {d['stratum'].get('wallet', 'N/A')}</div>
            </div>

            <div class="card">
                <h3>P2Pool Network</h3>
                <div class="stat-grid">
                    <div class="stat-card"><h5>Sidechain Height</h5><p>{d['pool']['sidechain_height']}</p></div>
                    <div class="stat-card"><h5>Difficulty</h5><p>{d['pool']['diff']}</p></div>
                    <div class="stat-card"><h5>Pool Hashrate</h5><p>{d['pool']['hashrate']}</p></div>
                    <div class="stat-card"><h5>Total Hashes</h5><p>{d['pool']['total_hashes']}</p></div>
                    <div class="stat-card"><h5>Miners</h5><p>{d['pool']['miners']}</p></div>
                    <div class="stat-card"><h5>PPLNS (Win/Wt)</h5><p>{d['pool']['pplns_window']} / {d['pool']['pplns_weight']}</p></div>
                    <div class="stat-card"><h5>Blocks Found</h5><p>{d['pool']['blocks']}</p></div>
                    <div class="stat-card"><h5>Last Block</h5><p>{d['pool']['last_block_found']} ({format_time_abs(d['pool']['last_block_ts'])})</p></div>
                    <div class="stat-card"><h5>Peers (Out/In/All)</h5><p>{d['p2p']['connections']} / {d['p2p']['incoming']} / {d['p2p']['peers']}</p></div>
                    <div class="stat-card"><h5>Status</h5><p>Up: {d['p2p']['uptime']} (ZMQ: {d['p2p']['zmq']}s)</p></div>
                </div>
            </div>

            <div class="card">
                <h3>XMR Network</h3>
                <div class="stat-grid">
                    <div class="stat-card"><h5>Block Height</h5><p>{d['network']['height']}</p></div>
                    <div class="stat-card"><h5>Reward</h5><p>{d['network']['reward']} XMR</p></div>
                    <div class="stat-card" style="grid-column: span 2;"><h5>Difficulty</h5><p>{d['network']['difficulty']}</p></div>
                    <div class="stat-card" style="grid-column: span 2;">
                        <h5>Current Block Hash</h5>
                        <p style="font-size:10px; font-family:monospace;">{d['network']['hash']}</p>
                    </div>
                    <div class="stat-card" style="grid-column: span 2;"><h5>Network Time</h5><p>{format_time_abs(d['network']['ts'])}</p></div>
                </div>
            </div>
            
            {tari_section}
        </div>
        <div class="card">
            <h3>Workers Alive: {len(d['workers'])}</h3>
            <table><thead><tr><th>Worker</th><th>IP</th><th>Uptime</th><th>10s</th><th>60s</th><th>15m</th></tr></thead><tbody>{rows}</tbody></table>
        </div>
    </div>
    <script>
        new Chart(document.getElementById('hChart'), {{
            type: 'line',
            data: {{
                labels: {[x['t'] for x in HASHRATE_HISTORY]},
                datasets: [{{ label: 'H/s', data: {[x['v'] for x in HASHRATE_HISTORY]}, borderColor: '#58a6ff', tension: 0.3, fill: true, backgroundColor: 'rgba(88,166,255,0.1)' }}]
            }},
            options: {{ responsive: true, maintainAspectRatio: false, plugins: {{ legend: {{ display: false }} }}, scales: {{ y: {{ grid: {{ color: '#30363d' }} }}, x: {{ display: false }} }} }}
        }});
    </script></body></html>
    """
    return web.Response(text=html, content_type='text/html')

async def start_background_tasks(app):
    app['data_task'] = asyncio.create_task(update_data_loop())

if __name__ == "__main__":
    app = web.Application()
    app.add_routes([web.get('/', handle_get)])
    app.on_startup.append(start_background_tasks)
    print("Dashboard running on port 8000 with Background Worker...", flush=True)
    web.run_app(app, host='0.0.0.0', port=8000)