// Dashboard components. Each is a pure function of the /api/state JSON (see views.build_state
// on the server). The server sends formatted display strings and semantic tokens
// (variant: "ok"/"purple"/"accent"/"muted", level: "high"/"ok"); the client maps those to
// classes — it does no number formatting or business logic of its own.
import { Component, Fragment, html } from './preact.mjs';
import { ChartCard } from './chart.mjs';
import { WORKER_COLUMNS, sortWorkers, THEME_ORDER, THEME_LABELS, heroKpis } from './logic.mjs';

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

// Theme icons (Issue #43) — minimal Lucide-style line glyphs drawn with currentColor, so they
// pick up the segment's text colour (muted → full on hover/active). Inline SVG keeps them crisp
// at any DPI and needs no extra asset or CSP allowance.
const svgIcon = (body) => html`
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor"
         stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const THEME_ICON = {
    light: () => svgIcon(html`<circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />`),
    auto: () => svgIcon(html`<rect x="2" y="3" width="20" height="14" rx="2" /><path d="M8 21h8M12 17v4" />`),
    dark: () => svgIcon(html`<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />`),
};

// Fixed bottom-right segmented control to pick light / auto / dark (Issue #43). Icon-only and
// visually quiet, with the active segment raised; the order/labels come from logic.mjs. Rendered
// in every app state (loading / sync / dashboard) so it's always reachable; the choice is
// persisted by the onTheme handler in dashboard.js.
const ThemeSwitcher = ({ theme, onTheme }) => {
    const current = theme || 'auto';
    return html`
    <div class="theme-switcher" role="group" aria-label="Theme">
        ${THEME_ORDER.map((id) => html`
            <button type="button" class=${'theme-seg' + (id === current ? ' active' : '')}
                    title=${'Theme: ' + THEME_LABELS[id]} aria-label=${THEME_LABELS[id]}
                    aria-pressed=${id === current} onClick=${() => onTheme(id)}>
                ${THEME_ICON[id]()}
            </button>`)}
    </div>`;
};

// --- Top bar -------------------------------------------------------------------------

function Header({ state }) {
    const s = state.system, hr = state.hashrate;
    const labelCls = (level) => (level === 'high' ? 'status-bad' : 'text-muted');
    const valCls = (level) => (level === 'high' ? 'status-bad' : '');
    return html`
    <div class="header" id="top-header">
        <div>
            <div class="brand">
                <img class="brand-logo" src="/static/pithead-mark.svg" alt="" width="40" height="40" />
                <div>
                    <div class="flex items-center">
                        <h1 class="brand-name">Pithead</h1>
                        <${Badges} badges=${state.badges} />
                    </div>
                    <div class="brand-host font-mono text-muted">${state.host_ip}</div>
                </div>
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
            <div class="text-muted text-xs">Last Update: ${state.last_update}</div>
            <div class=${'text-xs mt-1 ' + cVar(hr.p2p_variant)}>P2Pool: ${hr.p2p_1h} (1h) / ${hr.p2p_24h} (24h)</div>
            <div class=${'text-xs mt-xs ' + cVar(hr.xvb_variant)}>XvB: ${hr.xvb_1h} (1h) / ${hr.xvb_24h} (24h)</div>
        </div>
    </div>`;
}

// --- Hero KPI band -------------------------------------------------------------------

// A prominent strip of the headline numbers (total hashrate, shares in window, blocks found, XvB
// tier, mining mode) shown above the operational view (Issue #81). heroKpis (logic.mjs,
// unit-tested) does the selection/labelling/colouring; this only renders the list. Rendered only
// when operational — during sync the numbers aren't meaningful yet.
const HeroBand = ({ state }) => html`
    <div class="hero-band" id="hero-band">
        ${heroKpis(state).map((k) => html`
            <div class="hero-kpi">
                <div class=${'hero-value ' + (k.cls || '')}>${k.value}</div>
                <div class="hero-label">${k.label}</div>
            </div>`)}
    </div>`;

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
            <${StatCard} label="Donating (routed)" value=${hr.xvb_routed} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="1h Avg (Credited)" value=${hr.xvb_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="24h Avg (Credited)" value=${hr.xvb_24h} cls=${cVar(hr.xvb_variant)} />
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

// --- Workers table (WORKER_COLUMNS + sortWorkers live in logic.mjs, unit-tested) -----

function PoolBadge({ pool }) {
    if (pool === 'p2pool') return html`<span class="badge badge-ok">P2Pool</span>`;
    if (pool === 'xvb') return html`<span class="badge badge-purple">XvB</span>`;
    return html`<span class="badge badge-bad">Unknown</span>`;
}

// Pool-wide proxy share totals (Issue #82) — a footer under the table. Hidden until the proxy
// has reported any shares so it isn't an all-zero line on a fresh start.
const ProxyTotals = ({ summary }) => {
    if (!summary || !summary.has_data) return null;
    // htm trims whitespace that wraps across a newline at an element boundary, so the spaces
    // around the rejected <span> are added explicitly via ${' '} rather than left to indentation.
    const rejCls = summary.reject_level === 'high' ? 'status-bad' : '';
    return html`
    <div class="proxy-totals text-small text-muted">
        Proxy totals: <span class="status-ok">${summary.accepted}</span> accepted ·${' '}
        <span class=${rejCls}>${summary.rejected}</span> rejected (${summary.reject_pct}) ·${' '}
        ${summary.invalid} invalid · Best diff ${summary.best}
    </div>`;
};

function WorkersTable({ workers, summary, ui, onSort }) {
    const rows = sortWorkers(workers, ui.sortIndex, ui.sortAsc);
    return html`
    <div class="card">
        <h3>Workers Alive</h3>
        <div class="table-scroll">
            <table id="workers-table">
                <thead>
                    <tr>${WORKER_COLUMNS.map((c, i) => html`<th onClick=${() => onSort(i)}>${c.label}</th>`)}</tr>
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
                            <td>${w.accepted_str}</td>
                            <td>${w.rejected_str}${w.reject_flag
                                ? html` <span class="badge badge-bad" title=${w.reject_flag.title}>${w.reject_flag.text}</span>`
                                : null}</td>
                        </tr>`)}
                </tbody>
            </table>
        </div>
        <${ProxyTotals} summary=${summary} />
    </div>`;
}

// --- Operational view ----------------------------------------------------------------

function DashboardView({ state, ui, onRange, onSort, onView, onZoom, onResetZoom, onToggleSeries }) {
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
            <${ChartCard} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
                          onRange=${onRange} onZoom=${onZoom} onResetZoom=${onResetZoom}
                          onToggleSeries=${onToggleSeries} />
            <${Overview} state=${state} />
            <${NodeStats} state=${state} />
            <${GlobalStats} state=${state} />
            <${XvBStats} state=${state} />
            <${NetworkCard} state=${state} />
            <${TariCard} tari=${state.tari} />
        </div>
        <${WorkersTable} workers=${state.workers} summary=${state.proxy_summary} ui=${ui} onSort=${onSort} />
    </div>`;
}

// --- Root ----------------------------------------------------------------------------

export function App({ state, connected, ui, onRange, onSort, onView, onTheme, onZoom, onResetZoom, onToggleSeries }) {
    // The theme toggle is fixed-position and always available, even before the first data load.
    const switcher = html`<${ThemeSwitcher} theme=${ui.theme} onTheme=${onTheme} />`;
    if (!state) {
        return html`<${Fragment}>
            <div class="loading">${connected ? 'Connecting to the dashboard…' : 'Cannot reach the dashboard.'}</div>
            ${switcher}
        <//>`;
    }
    return html`<${Fragment}>
        <${Header} state=${state} />
        ${!connected ? html`<div class="disconnected-banner">Disconnected — showing last known data. Retrying…</div>` : null}
        ${state.syncing
            ? html`<${SyncView} sync=${state.sync} />`
            : html`<${Fragment}>
                <${HeroBand} state=${state} />
                <${DashboardView} state=${state} ui=${ui} onRange=${onRange} onSort=${onSort}
                                  onView=${onView} onZoom=${onZoom} onResetZoom=${onResetZoom}
                                  onToggleSeries=${onToggleSeries} />
              <//>`}
        ${switcher}
    <//>`;
}
