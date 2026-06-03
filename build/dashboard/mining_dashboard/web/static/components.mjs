// Dashboard components. Each is a pure function of the /api/state JSON (see views.build_state
// on the server). The server sends formatted display strings and semantic tokens
// (variant: "ok"/"purple"/"accent"/"muted", level: "high"/"ok"); the client maps those to
// classes — it does no number formatting or business logic of its own.
import { Component, Fragment, html } from './preact.mjs';
import { ChartCard } from './chart.mjs';

// Palette token -> text-colour class (defined in dashboard.css).
const cVar = (v) => 'c-' + v;

// --- Small shared pieces -------------------------------------------------------------

const StatCard = ({ label, value, cls, span }) => html`
    <div class=${'stat-card' + (span ? ' col-span-2' : '')}>
        <h5>${label}</h5>
        <p class=${cls || ''}>${value}</p>
    </div>`;

const SharesStat = ({ sw, label = 'Share In Window' }) => html`
    <div class="stat-card">
        <h5>${label}</h5>
        <p><span class=${sw.ok ? 'status-ok' : 'status-bad'}>${sw.count}</span></p>
    </div>`;

// Tari status with the ✔ the server signals via `active`.
const TariStatus = ({ tari }) => html`
    <p class=${tari.active ? 'status-ok' : ''}>
        ${tari.status}${tari.active ? html` <span class="check-inline">✔</span>` : null}
    </p>`;

const Badges = ({ badges }) => html`
    <div class="badge-row">
        ${badges.map((b) => html`
            <span class=${'badge badge-' + b.variant} title=${b.title || ''}>${b.text}</span>`)}
    </div>`;

const HighUsage = ({ level }) =>
    level === 'high' ? html`<span class="badge badge-bad mx-1">High Usage</span>` : null;

// --- Top bar -------------------------------------------------------------------------

function Header({ state }) {
    const s = state.system, hr = state.hashrate;
    const labelCls = (level) => (level === 'high' ? 'status-bad' : 'text-muted');
    const valCls = (level) => (level === 'high' ? 'status-bad' : '');
    return html`
    <div class="header" id="top-header">
        <div>
            <div class="flex items-center">
                <h2>${state.host_ip}</h2>
                <${Badges} badges=${state.badges} />
            </div>
            <div class="text-small mt-2">
                <div class="mb-1">
                    <span class=${labelCls(s.cpu.level)}>CPU:</span>
                    <span class=${valCls(s.cpu.level)}>${s.cpu.percent}</span> <${HighUsage} level=${s.cpu.level} />
                    <span class="text-muted ml-2">Load:</span> ${s.cpu.load}
                </div>
                <div class="mb-1">
                    <span class=${labelCls(s.mem.level)}>RAM:</span>
                    <span class=${valCls(s.mem.level)}>${s.mem.used} / ${s.mem.total} GB (${s.mem.percent})</span> <${HighUsage} level=${s.mem.level} />
                    <span class=${s.hugepages.variant === 'ok' ? 'status-ok' : 'status-bad'}>Huge Pages: ${s.hugepages.status} (${s.hugepages.value})</span>
                </div>
                <div class="flex items-center">
                    <span class=${(s.disk.level === 'high' ? 'status-bad' : 'text-muted') + ' mr-2'}>Disk: ${s.disk.used} / ${s.disk.total} GB (${s.disk.percent})</span> <${HighUsage} level=${s.disk.level} />
                    <div class="disk-bar">
                        <div class="progress-bg">
                            <div class=${'progress-fill ' + s.disk.fill} style=${{ width: s.disk.width }}></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <div class="text-right">
            <div class="text-accent font-bold hashrate-total">${hr.total}</div>
            <div class="text-muted text-xs">Last Update: ${state.last_update}</div>
            <div class=${'text-xs mt-1 ' + cVar(hr.p2p_variant)}>P2Pool: ${hr.p2p_1h} (1h) / ${hr.p2p_24h} (24h)</div>
            <div class=${'text-xs mt-xs ' + cVar(hr.xvb_variant)}>XvB: ${hr.xvb_1h} (1h) / ${hr.xvb_24h} (24h)</div>
        </div>
    </div>`;
}

// --- Sync Mode -----------------------------------------------------------------------

function Gauge({ percent, state }) {
    const inner = state === 'done'
        ? html`<span class="status-ok check-big">✔</span>`
        : state === 'loading' ? '…' : percent + '%';
    return html`
    <div class="loader-container">
        <div class="progress-wheel" style=${{ '--p': percent + '%' }}></div>
        <div class="progress-text">${inner}</div>
    </div>`;
}

function SyncView({ sync }) {
    return html`
    <div id="sync-view">
        <div class="header-placeholder"><p>System is currently synchronizing with the network.</p></div>
        <div class="grid">
            <div class="card">
                <h2 class="text-accent text-center">Monero Sync</h2>
                <${Gauge} percent=${sync.monero.percent} state=${sync.monero.state} />
                <div class="status-text">
                    Synced: ${sync.monero.current} / ${sync.monero.target}<br/>
                    <small>(${sync.monero.remaining} blocks left)</small><br/>
                    <small class="text-muted">${sync.monero.mode} · DB ${sync.monero.db_size}</small>
                </div>
            </div>
            <div class="card">
                <h2 class="text-accent text-center">Tari Sync</h2>
                <${Gauge} percent=${sync.tari.percent} state=${sync.tari.state} />
                <div class="status-text">
                    Synced: ${sync.tari.current} / ${sync.tari.target}<br/>
                    <small>(${sync.tari.remaining} blocks left)</small>
                </div>
            </div>
        </div>
    </div>`;
}

// --- Operational cards ---------------------------------------------------------------

function Overview({ state }) {
    const hr = state.hashrate, st = state.stratum, t = state.tari;
    return html`
    <div class="card card-simple" id="card-overview">
        <h3>Overview</h3>
        <div class="stat-grid">
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${SharesStat} sw=${state.shares_window} />
            <${StatCard} label="Last Share" value=${st.last_share} />
            <${StatCard} label="P2Pool 1h Avg" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h Avg" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="XvB 1h Avg" value=${hr.xvb_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="XvB 24h Avg" value=${hr.xvb_24h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Target Tier" value=${hr.target_tier} />
            <div class="stat-card"><h5>Tari Mining</h5><${TariStatus} tari=${t} /></div>
            <${StatCard} label="Workers Alive" value=${state.proxy_workers} />
            <${StatCard} label="Wallet XMR" value=${st.wallet_short} cls="font-mono text-xs" />
            <${StatCard} label="Wallet TARI" value=${t.wallet_short} cls="font-mono text-xs" />
        </div>
    </div>`;
}

function NodeStats({ state }) {
    const hr = state.hashrate, st = state.stratum;
    return html`
    <div class="card card-advanced" id="card-mynode">
        <h3>My P2Pool Node Stats</h3>
        <div class="stat-grid">
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="P2Pool 1h Avg" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h Avg" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            <div class="stat-card col-span-2">
                <h5>Stratum (15m / 1h / 24h)</h5>
                <p class="text-small">${st.h15} / ${st.h1h} / ${st.h24h}</p>
            </div>
            <${StatCard} label="Shares (OK/Err)" value=${st.shares} />
            <${StatCard} label="Effort" value=${st.effort} />
            <${StatCard} label="Connections" value=${st.conns} />
            <${StatCard} label="Reward Share" value=${st.reward_pct} />
            <${StatCard} label="Total Shares" value=${st.total_shares} />
            <${StatCard} label="Last Share" value=${st.last_share} />
            <${StatCard} label="Total Hashes" value=${st.total_hashes} span=${true} />
        </div>
        <div class="wallet-text">Wallet: ${st.wallet}</div>
    </div>`;
}

function GlobalStats({ state }) {
    const p = state.pool;
    return html`
    <div class="card card-advanced" id="card-global">
        <h3>Global P2Pool Stats</h3>
        <div class="stat-grid">
            <${StatCard} label="Pool Hashrate" value=${p.hr} />
            <${StatCard} label="Miners" value=${p.miners} />
            <${StatCard} label="Sidechain Height" value=${p.sidechain_height} />
            <${StatCard} label="Difficulty" value=${p.diff} />
            <${StatCard} label="Blocks Found" value=${p.blocks} />
            <${StatCard} label="PPLNS Window" value=${p.pplns_win} />
            <${StatCard} label="PPLNS Weight" value=${p.pplns_wgt} />
            <${SharesStat} sw=${state.shares_window} />
            <div class="stat-card"><h5>Last Block</h5><p class="text-small">${p.last_blk}</p></div>
            <${StatCard} label="Peers" value=${p.peers} />
            <div class="stat-card"><h5>Uptime</h5><p class="text-small">${p.uptime}</p></div>
            <${StatCard} label="Total Hashes" value=${p.total_hashes} />
        </div>
    </div>`;
}

function XvBStats({ state }) {
    const hr = state.hashrate;
    return html`
    <div class="card card-advanced" id="card-xvb">
        <h3>XvB Donation Stats</h3>
        <div class="stat-grid">
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Target Tier" value=${hr.target_tier} />
            <${StatCard} label="1h Avg (Pool)" value=${hr.xvb_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="24h Avg (Pool)" value=${hr.xvb_24h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="Fail Count" value=${hr.xvb_fail_count} />
        </div>
        <div class="text-xs text-muted mt-2">Stats fetched from xmrvsbeast.com (Updated: ${hr.xvb_updated})</div>
    </div>`;
}

function NetworkCard({ state }) {
    const n = state.network, m = state.monero;
    return html`
    <div class="card card-advanced" id="card-network">
        <h3>XMR Network</h3>
        <div class="stat-grid">
            <${StatCard} label="Block Height" value=${n.height} />
            <${StatCard} label="Reward" value=${n.reward} />
            <${StatCard} label="Node Mode" value=${m.mode} />
            <${StatCard} label="DB Size" value=${m.db_size} />
            <${StatCard} label="Difficulty" value=${n.diff} span=${true} />
            <div class="stat-card col-span-2"><h5>Current Block Hash</h5><p class="font-mono text-xs">${n.hash}</p></div>
            <${StatCard} label="Network Time" value=${n.ts} span=${true} />
        </div>
    </div>`;
}

function TariCard({ tari }) {
    return html`
    <div class="card card-advanced" id="card-tari">
        <h3>Tari Merge Mining</h3>
        <div class="stat-grid">
            <div class="stat-card"><h5>Status</h5><${TariStatus} tari=${tari} /></div>
            <${StatCard} label="Reward" value=${tari.reward} />
            <${StatCard} label="Height" value=${tari.height} />
            <${StatCard} label="Difficulty" value=${tari.diff} />
        </div>
        <div class="wallet-text">Wallet: ${tari.wallet}</div>
    </div>`;
}

// --- Workers table -------------------------------------------------------------------

// Columns carry the state key they sort on. Hashrate/uptime/IP sort numerically (raw values
// the server includes alongside the formatted strings); name sorts as text.
const COLUMNS = [
    { label: 'Worker', key: 'name' },
    { label: 'IP', key: 'ip_sort' },
    { label: 'Uptime', key: 'uptime' },
    { label: '10s', key: 'h10' },
    { label: '60s', key: 'h60' },
    { label: '15m', key: 'h15' },
];

function sortWorkers(workers, idx, asc) {
    if (idx === null) return workers;
    const key = COLUMNS[idx].key;
    const sorted = [...workers].sort((a, b) => {
        const va = a[key], vb = b[key];
        if (typeof va === 'number' && typeof vb === 'number') return va - vb;
        return String(va).localeCompare(String(vb));
    });
    return asc ? sorted : sorted.reverse();
}

function PoolBadge({ pool }) {
    if (pool === 'p2pool') return html`<span class="badge badge-ok">P2Pool</span>`;
    if (pool === 'xvb') return html`<span class="badge badge-purple">XvB</span>`;
    return html`<span class="badge badge-bad">Unknown</span>`;
}

function WorkersTable({ workers, ui, onSort }) {
    const rows = sortWorkers(workers, ui.sortIndex, ui.sortAsc);
    return html`
    <div class="card">
        <h3>Workers Alive</h3>
        <table id="workers-table">
            <thead>
                <tr>${COLUMNS.map((c, i) => html`<th onClick=${() => onSort(i)}>${c.label}</th>`)}</tr>
            </thead>
            <tbody id="workers-tbody">
                ${rows.map((w) => html`
                    <tr class=${w.status === 'online' ? 'status-ok' : 'status-bad'}>
                        <td>${w.name} <${PoolBadge} pool=${w.pool} /></td>
                        <td>${w.ip}</td>
                        <td>${w.uptime_str}</td>
                        <td>${w.h10_str}</td>
                        <td>${w.h60_str}</td>
                        <td>${w.h15_str}</td>
                    </tr>`)}
            </tbody>
        </table>
    </div>`;
}

// --- Operational view ----------------------------------------------------------------

function DashboardView({ state, ui, onRange, onSort, onView }) {
    const advanced = ui.view === 'advanced';
    return html`
    <div id="dashboard-view" class=${advanced ? 'mode-advanced' : ''}>
        <div class="view-controls">
            <div class="toggle-group">
                <button class=${'btn-toggle' + (!advanced ? ' active' : '')} onClick=${() => onView('simple')}>Simple</button>
                <button class=${'btn-toggle' + (advanced ? ' active' : '')} onClick=${() => onView('advanced')}>Advanced</button>
            </div>
        </div>
        <div class="grid">
            <${ChartCard} chart=${state.chart} range=${ui.range} onRange=${onRange} />
            <${Overview} state=${state} />
            <${NodeStats} state=${state} />
            <${GlobalStats} state=${state} />
            <${XvBStats} state=${state} />
            <${NetworkCard} state=${state} />
            <${TariCard} tari=${state.tari} />
        </div>
        <${WorkersTable} workers=${state.workers} ui=${ui} onSort=${onSort} />
    </div>`;
}

// --- Root ----------------------------------------------------------------------------

export function App({ state, connected, ui, onRange, onSort, onView }) {
    if (!state) {
        return html`<div class="loading">${connected ? 'Connecting to the dashboard…' : 'Cannot reach the dashboard.'}</div>`;
    }
    return html`<${Fragment}>
        <${Header} state=${state} />
        ${!connected ? html`<div class="disconnected-banner">Disconnected — showing last known data. Retrying…</div>` : null}
        ${state.syncing
            ? html`<${SyncView} sync=${state.sync} />`
            : html`<${DashboardView} state=${state} ui=${ui} onRange=${onRange} onSort=${onSort} onView=${onView} />`}
    <//>`;
}
