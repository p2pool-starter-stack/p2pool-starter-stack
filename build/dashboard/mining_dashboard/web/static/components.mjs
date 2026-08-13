// Dashboard components. Each is a pure function of the /api/state JSON (see views.build_state
// on the server). The server sends formatted display strings and semantic tokens
// (variant: "ok"/"purple"/"accent"/"muted", level: "high"/"ok"); the client maps those to
// classes — it does no number formatting or business logic of its own.

import { ChartCard } from "./chart.mjs";
import { ConfigView, UpgradeControl } from "./configview.mjs";
import {
  coinFiat,
  coinTriplet,
  computeEarnings,
  computeEnergy,
  computeXvbTier,
  egressRoute,
  fmtHashrate,
  formatAgo,
  formatFiat,
  formatFiatAmount,
  formatFiatPrice,
  formatTimeToShare,
  formatUnit,
  formatXmr,
  formatXtm,
  heroKpis,
  loadPref,
  parseHashrate,
  priceSourceLabel,
  raffleCls,
  savePref,
  sortWorkers,
  THEME_LABELS,
  THEME_ORDER,
  uptimeCell,
  WORKER_COLUMNS,
  xvbDecisionRows,
} from "./logic.mjs";
import { MineCartTrain } from "./minecart.mjs";
import { Component, Fragment, html } from "./preact.mjs";
import { SecurityPanel } from "./securityview.mjs";
import { StackTopology } from "./topology.mjs";
import { WorkerInspect } from "./workerview.mjs";

// Palette token -> text-colour class (defined in dashboard.css).
const cVar = (v) => "c-" + v;

// --- Small shared pieces -------------------------------------------------------------

const StatCard = ({ label, value, cls, span, title }) => html`
    <div class=${"stat-card" + (span ? " col-span-2" : "")} title=${title || ""}>
        <h5>${label}</h5>
        <p class=${cls || ""}>${value}</p>
    </div>`;

// Standardized Day/Month/Year estimate table — the one shape every earnings tab presents its
// estimate in: coin column in accent, a ≈-fiat column appearing once the coin's price is known
// (the same visibility gate the old per-cell fiat cards used). Replaces per-tab stat-grids whose
// two-column flow paired unrelated cells (XMR/year beside ≈/day). The coin triplet shares one
// precision (coinTriplet) so the rows align.
const EstTable = ({ unit, day, month, year, price, currency, title }) => {
  const coins = coinTriplet([day, month, year], unit);
  const haveFiat = Number.isFinite(price) && price > 0;
  const rows = [
    ["Day", day, coins[0]],
    ["Month", month, coins[1]],
    ["Year", year, coins[2]],
  ];
  return html`
    <div class="est-scroll">
    <table class="est-table" title=${title || ""}>
        <thead><tr>
            <th></th>
            <th scope="col">${unit}</th>
            ${haveFiat ? html`<th scope="col">≈ ${currency || "USD"}</th>` : null}
        </tr></thead>
        <tbody>
            ${rows.map(
              ([label, raw, coin]) => html`
            <tr>
                <th scope="row">${label}</th>
                <td class="c-accent">${coin}</td>
                ${haveFiat ? html`<td>${formatFiatAmount(coinFiat(raw, price))}</td>` : null}
            </tr>`,
            )}
        </tbody>
    </table>
    </div>`;
};

// Sign colour for a net figure — the one judgment colour in the calculator: green when the
// operation profits, red when it loses. Everything that is a plain estimate stays accent/plain.
const netCls = (v) => (v !== null && Number.isFinite(v) && v < 0 ? "c-bad" : "c-ok");

const SharesStat = ({ sw, label = "Share in Window" }) => html`
    <div class="stat-card">
        <h5>${label}</h5>
        <p><span class=${sw.ok ? "status-ok" : "status-bad"}>${sw.count}</span></p>
    </div>`;

// Progressive disclosure for a busy stat-grid card ("show more" pattern). A card splits its
// StatCards into `headline` (always visible — the figures an operator actually glances at) and
// `detail` (behind the toggle, collapsed by default); both share one `stat-grid` so the layout is
// identical to the old flat list once expanded. Expansion is persisted per card via
// loadPref/savePref — the same helpers dashboardEarningsTab already uses — keyed on `prefKey` so
// each card remembers its own state independently across a reload. The toggle is a real <button>
// with aria-expanded (not <details>/<summary>): that keeps the expanded/collapsed state explicit
// for assistive tech and gives the label control ("Show all (N)") the native disclosure triangle
// doesn't.
const EXPAND_STATES = ["expanded", "collapsed"];
class MoreStats extends Component {
  constructor(props) {
    super(props);
    this.state = { expanded: loadPref(props.prefKey, EXPAND_STATES, "collapsed") === "expanded" };
    this.toggle = () => {
      const expanded = !this.state.expanded;
      savePref(this.props.prefKey, expanded ? "expanded" : "collapsed");
      this.setState({ expanded });
    };
  }

  render() {
    const { headline, detail, count } = this.props;
    const { expanded } = this.state;
    return html`
        <div class="stat-grid">
            ${headline}
            ${expanded ? detail : null}
        </div>
        <button type="button" class="more-stats-toggle" aria-expanded=${expanded ? "true" : "false"}
                onClick=${this.toggle}>
            ${expanded ? "Show less ▴" : `Show all (${count}) ▾`}
        </button>`;
  }
}

// Tari merge-mine status. The ✔ means the gRPC channel is actually up, so it's gated on `connected`
// (channel_state READY) — NOT on `active` (a chain is merely configured). When configured but the
// channel is down (e.g. TRANSIENT_FAILURE) we show the raw state in a warn style and no ✔, so a dead
// channel can never read as "TRANSIENT_FAILURE ✔".
const TariStatus = ({ tari }) => html`
    <p class=${tari.connected ? "status-ok" : tari.active ? "status-warn" : ""}>
        ${tari.status}${tari.connected ? html` <span class="check-inline">✔</span>` : null}
    </p>`;

const Badges = ({ badges }) => html`
    <div class="badge-row">
        ${badges.map(
          (b) => html`
            <span class=${"badge badge-" + b.variant} title=${b.title || ""}>${b.text}</span>`,
        )}
    </div>`;

// Build-version badge (Issue #58). Muted badge-outline so it reads as informative, not loud;
// shown on every screen (the Header renders on both sync and main). The server resolves a clean
// release to `vX.Y.Z` and any other build to `dev · branch @ hash`, so a dev build is
// unmistakable. `dev` adds a marker class purely as a class hook (text already distinguishes it).
const VersionBadge = ({ version }) =>
  version && version.text
    ? html`<span class=${"badge badge-outline version-badge ml-2" + (version.dev ? " version-dev" : "")}
                     title=${version.title || ""}>${version.text}</span>`
    : null;

// New-release callout (#224). Shown only when the server reports a newer GitHub release is available
// (`dashboard.check_for_updates`). Notify-only — a link to the release notes; the one-click upgrade
// is the separate UpgradeControl (#59). Accent so it's noticeable; opens the release page in a new tab.
const UpdateBadge = ({ update }) =>
  update && update.available && update.url
    ? html`<a class="badge badge-accent version-badge ml-2" href=${update.url}
                  target="_blank" rel="noopener noreferrer"
                  title=${"A newer Pithead release is available: " + update.latest}
               >New release ${update.latest} available ↗</a>`
    : null;

const HighUsage = ({ level }) =>
  level === "high" ? html`<span class="badge badge-bad mx-1">High Usage</span>` : null;

// Theme icons (Issue #43) — minimal Lucide-style line glyphs drawn with currentColor, so they
// pick up the segment's text colour (muted → full on hover/active). Inline SVG keeps them crisp
// at any DPI and needs no extra asset or CSP allowance.
const svgIcon = (body) => html`
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor"
         stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const THEME_ICON = {
  light: () =>
    svgIcon(
      html`<circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />`,
    ),
  auto: () =>
    svgIcon(html`<rect x="2" y="3" width="20" height="14" rx="2" /><path d="M8 21h8M12 17v4" />`),
  dark: () => svgIcon(html`<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />`),
};

// Fixed bottom-right segmented control to pick light / auto / dark (Issue #43). Icon-only and
// visually quiet, with the active segment raised; the order/labels come from logic.mjs. Rendered
// in every app state (loading / sync / dashboard) so it's always reachable; the choice is
// persisted by the onTheme handler in dashboard.js.
const ThemeSwitcher = ({ theme, onTheme }) => {
  const current = theme || "auto";
  return html`
    <div class="theme-switcher" role="group" aria-label="Theme">
        ${THEME_ORDER.map(
          (id) => html`
            <button type="button" class=${"theme-seg" + (id === current ? " active" : "")}
                    title=${"Theme: " + THEME_LABELS[id]} aria-label=${THEME_LABELS[id]}
                    aria-pressed=${id === current} onClick=${() => onTheme(id)}>
                ${THEME_ICON[id]()}
            </button>`,
        )}
    </div>`;
};

// --- Top bar -------------------------------------------------------------------------

function Header({ state }) {
  const s = state.system,
    hr = state.hashrate;
  const labelCls = (level) => (level === "high" ? "status-bad" : "text-muted");
  const valCls = (level) => (level === "high" ? "status-bad" : "");
  return html`
    <div class="header" id="top-header">
        <div>
            <div class="brand">
                <img class="brand-logo" src="/static/pithead-mark.svg" alt="" width="40" height="40" />
                <div>
                    <div class="flex items-center">
                        <h1 class="brand-name">Pithead</h1>
                        <${Badges} badges=${state.badges} />
                        <${VersionBadge} version=${state.version} />
                        <${UpdateBadge} update=${state.update} />
                        <${UpgradeControl} update=${state.update} enabled=${state.control_enabled} />
                    </div>
                    <div class="brand-host font-mono text-muted">${state.host_ip}${state.host_addr ? html`<span class="brand-host-at">@</span>${state.host_addr}` : null}</div>
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
                    <span class=${s.hugepages.variant === "ok" ? "status-ok" : "status-bad"}>Huge Pages: ${s.hugepages.status} (${s.hugepages.value})</span>
                </div>
                <div class="flex items-center">
                    <span class=${(s.disk.level === "high" ? "status-bad" : "text-muted") + " mr-2"}>Disk: ${s.disk.used} / ${s.disk.total} ${s.disk.unit} (${s.disk.percent})</span> <${HighUsage} level=${s.disk.level} />
                    <div class="disk-bar">
                        <div class="progress-bg">
                            <div class=${"progress-fill " + s.disk.fill} style=${{ width: s.disk.width }}></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <div class="text-right">
            <div class="text-muted text-xs">Last Update: ${state.last_update}</div>
            <div class=${"text-xs mt-1 " + cVar(hr.p2p_variant)}>P2Pool (routed): ${hr.p2p_1h} (1h) / ${hr.p2p_24h} (24h)</div>
            ${
              // The XvB split line earns its header slot only while donation is on — off, it's a
              // permanent row of zeros advertising a feature the operator turned off.
              state.xvb_calc && state.xvb_calc.enabled
                ? html`<div class=${"text-xs mt-xs " + cVar(hr.xvb_variant)}>XvB (routed): ${hr.xvb_routed_1h} (1h) / ${hr.xvb_routed_24h} (24h)</div>`
                : null
            }
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
        ${heroKpis(state).map(
          (k) => html`
            <div class="hero-kpi">
                <div class=${"hero-value " + (k.cls || "")}>${k.value}</div>
                <div class="hero-label">${k.label}</div>
            </div>`,
        )}
    </div>`;

// --- Sync Mode -----------------------------------------------------------------------

function Gauge({ percent, state }) {
  const inner =
    state === "done"
      ? html`<span class="status-ok check-big">✔</span>`
      : state === "loading"
        ? "…"
        : percent + "%";
  return html`
    <div class="loader-container">
        <div class="progress-wheel" style=${{ "--p": percent + "%" }}></div>
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
  const hr = state.hashrate,
    st = state.stratum,
    t = state.tari,
    xvbOn = !!(state.xvb_calc && state.xvb_calc.enabled);
  // Stat order (#159): fleet headline (total / mode / workers) → raffle status (tier / VIP /
  // shares / target) → routed split → reference (last share / Tari / wallets).
  return html`
    <div class="card card-simple" id="card-overview">
        <h3>Overview</h3>
        <div class="stat-grid">
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Workers Alive" value=${state.proxy_workers} />
            ${
              // Five of these tiles are raffle/split state — on a non-donating box they'd all
              // read None / N/A / zeros, a third of the Overview spent saying "off" five ways.
              // The mode tile already says it once.
              xvbOn
                ? html`
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Raffle Eligible" value=${state.raffle_eligible.label} cls=${raffleCls(state.raffle_eligible)} />`
                : null
            }
            <${SharesStat} sw=${state.shares_window} />
            ${xvbOn ? html`<${StatCard} label="Target Tier" value=${hr.target_tier} />` : null}
            <${StatCard} label="P2Pool 1h (routed)" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h (routed)" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            ${
              xvbOn
                ? html`
            <${StatCard} label="XvB 1h (routed)" value=${hr.xvb_routed_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="XvB 24h (routed)" value=${hr.xvb_routed_24h} cls=${cVar(hr.xvb_variant)} />`
                : null
            }
            <${StatCard} label="Last Share" value=${st.last_share} />
            <div class="stat-card"><h5>Tari Mining</h5><${TariStatus} tari=${t} /></div>
            <${StatCard} label="Wallet XMR" value=${st.wallet_short} cls="font-mono text-xs" />
            <${StatCard} label="Wallet TARI" value=${t.wallet_short} cls="font-mono text-xs" />
        </div>
    </div>`;
}

function NodeStats({ state }) {
  const hr = state.hashrate,
    st = state.stratum;
  // Headline = the figures an operator actually checks first (mode, total hashrate, routed
  // averages, share health); stratum windows, connections, effort and the rest are drill-down
  // detail behind the "show more" toggle (progressive disclosure).
  const headline = html`
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="P2Pool 1h Avg" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h Avg" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="Shares (OK/Err)" value=${st.shares} />`;
  const detail = html`
            <div class="stat-card col-span-2">
                <h5>Stratum (15m / 1h / 24h)</h5>
                <p class="text-small">${st.h15} / ${st.h1h} / ${st.h24h}</p>
            </div>
            <${StatCard} label="Connections" value=${st.conns} />
            <${StatCard} label="Effort" value=${st.effort} />
            <${StatCard} label="Reward Share" value=${st.reward_pct} />
            <${StatCard} label="Total Shares" value=${st.total_shares} />
            <${StatCard} label="Last Share" value=${st.last_share} />
            <${StatCard} label="Total Hashes (Node)" value=${st.total_hashes} span=${true} />`;
  return html`
    <div class="card card-advanced" id="card-mynode">
        <h3>My P2Pool Node Stats</h3>
        <${MoreStats} prefKey="dashboardCardNode" headline=${headline} detail=${detail} count=${12} />
        <div class="wallet-text">Wallet: ${st.wallet}</div>
    </div>`;
}

function GlobalStats({ state }) {
  const p = state.pool;
  // Headline = the pool's own money/health figures (hashrate, whether it's finding blocks, when
  // it last did); sidechain internals, peers and uptime are reference detail, not a glance figure.
  const headline = html`
            <${StatCard} label="Pool Hashrate" value=${p.hr} cls="text-accent" />
            <${StatCard} label="Blocks Found" value=${p.blocks} />
            <div class="stat-card"><h5>Last Block</h5><p class="text-small">${p.last_blk}</p></div>`;
  const detail = html`
            <${StatCard} label="Miners" value=${p.miners} />
            <${StatCard} label="Sidechain Height" value=${p.sidechain_height} />
            <${StatCard} label="Difficulty" value=${p.diff} />
            <${StatCard} label="PPLNS Window" value=${p.pplns_win} />
            <${StatCard} label="PPLNS Weight" value=${p.pplns_wgt} />
            <${SharesStat} sw=${state.shares_window} />
            <${StatCard} label="Peers" value=${p.peers} />
            <div class="stat-card"><h5>Uptime</h5><p class="text-small">${p.uptime}</p></div>
            <${StatCard} label="Total Hashes (Pool)" value=${p.total_hashes} />`;
  return html`
    <div class="card card-advanced" id="card-global">
        <h3>Global P2Pool Stats</h3>
        <${MoreStats} prefKey="dashboardCardGlobal" headline=${headline} detail=${detail} count=${12} />
    </div>`;
}

function XvBStats({ state }) {
  const hr = state.hashrate;
  // A non-donating box gets no XvB stats card at all — every figure in it would be a zero or a
  // "None", and the tier calculator alongside already hides itself the same way.
  if (!(state.xvb_calc && state.xvb_calc.enabled)) return null;
  // When the xmrvsbeast.com fetch is stale (#311) the CREDITED figures are frozen —
  // grey them and tag the label so they don't read as live. Routed (our own proxy
  // history) is unaffected. Tooltip explains why.
  const staleTitle =
    "Stale: no successful fetch from xmrvsbeast.com since the time below. The credited " +
    "figures are frozen at the last reading; the controller holds its split until a fresh read lands.";
  const credLabel = (base) => (hr.xvb_stale ? base + " ⚠" : base);
  const credCls = hr.xvb_stale ? "status-warn" : cVar(hr.xvb_variant);
  const credTitle = hr.xvb_stale ? staleTitle : "";
  return html`
    <div class="card card-advanced" id="card-xvb">
        <h3>XvB Donation Stats</h3>
        <div class="stat-grid">
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Target Tier" value=${hr.target_tier} />
            <${StatCard} label="1h Avg (Routed)" value=${hr.xvb_routed_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label=${credLabel("1h Avg (Credited)")} value=${hr.xvb_1h} cls=${credCls} title=${credTitle} />
            <${StatCard} label="24h Avg (Routed)" value=${hr.xvb_routed_24h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label=${credLabel("24h Avg (Credited)")} value=${hr.xvb_24h} cls=${credCls} title=${credTitle} />
            <${StatCard} label="Fail Count" value=${hr.xvb_fail_count} />
        </div>
        <div class="mt-2">
            <div class="text-small text-muted">Raffle Wins</div>
            <div class="raffle-wins-list">
            ${
              (state.raffle_wins || []).length
                ? state.raffle_wins.map(
                    (w) => html`<div class="text-xs" title=${"Round block height " + w.height}>
                        ★ ${w.time} — won a ${w.tier} round, credited ${w.hashrate}</div>`,
                  )
                : html`<div class="text-xs text-muted">No wins recorded yet — a win lands here and as a gold star on the chart.</div>`
            }
            </div>
        </div>
        <div class=${"text-xs mt-2 " + (hr.xvb_stale ? "status-warn" : "text-muted")} title=${credTitle}>
            ${hr.xvb_stale ? "⚠ Stale — last successful fetch from xmrvsbeast.com: " : "Stats fetched from xmrvsbeast.com (Updated: "}${hr.xvb_updated}${hr.xvb_stale ? "" : ")"}
        </div>
    </div>`;
}

function NetworkCard({ state }) {
  const n = state.network,
    m = state.monero;
  // Headline = the chain's own money/health figures (height, difficulty, block reward); node
  // internals (mode, DB size, hash, network time) are reference detail.
  const headline = html`
            <${StatCard} label="Block Height" value=${n.height} />
            <${StatCard} label="Difficulty" value=${n.diff} />
            <${StatCard} label="Reward" value=${n.reward} />`;
  const detail = html`
            <${StatCard} label="Node Mode" value=${m.mode} />
            <${StatCard} label="DB Size" value=${m.db_size} />
            <div class="stat-card col-span-2"><h5>Current Block Hash</h5><p class="font-mono text-xs">${n.hash}</p></div>
            <${StatCard} label="Network Time" value=${n.ts} span=${true} />`;
  return html`
    <div class="card card-advanced" id="card-network">
        <h3>XMR Network</h3>
        <${MoreStats} prefKey="dashboardCardNetwork" headline=${headline} detail=${detail} count=${7} />
    </div>`;
}

// XvB tier decision table (#872, study-final): the analytical tool a miner decides with. Every
// donor tier on one row — draw odds (live winners feed), cost at YOUR hashrate, XvB's published
// face value AND the study estimate (face x the measured on-chain delivery band) side by side,
// and a coloured net verdict. This wallet's own measured wins supersede the study band when they
// exist. Unsustainable tiers stay visible but grayed with the net withheld. No dropdown: the
// comparison IS the decision, so all tiers show at once.
function XvbDecisionTable({ calc, coeffDay, hr, energy }) {
  const rows = xvbDecisionRows(calc, coeffDay, hr);
  if (!rows.length) return null;
  const measured = calc.realization_pct !== null && calc.realization_pct !== undefined;
  const fmtRange = (r) =>
    r === null ? "—" : r[0] === r[1] ? formatXmr(r[0]) : `${formatXmr(r[0])} … ${formatXmr(r[1])}`;
  const estHeader = measured
    ? `Yours (${calc.realization_pct}% × ${calc.realization_wins} wins)`
    : "Study est. / yr";
  // Fiat mirror (#520) for the best sustainable net only — one line, never a fiat number whose
  // XMR figure is hidden.
  const best = rows.filter((r) => r.sustainable && r.net).sort((a, b) => b.net[1] - a.net[1])[0];
  return html`
        <div class="xvb-comparison">
            <label class="xvb-compare-label">Should I donate? — per-tier verdict (per year)</label>
            <p class="text-muted text-xs" id="xvb-study-note">
                XvB's figures are face value. A 25-round single-wallet on-chain audit (Jun–Aug
                2026, all three sidechains) measured winners receiving 33% of face (95% CI
                28–39%), with at most a small margin effect; a 14-winner public crawl
                corroborates (no winner near face value). The
                ${measured ? "Yours" : "Study"} column prices that in; the Net verdict uses it.
            </p>
            <div class="table-scroll">
            <table class="est-table" id="xvb-decision-table">
                <thead><tr>
                    <th>Tier</th>
                    <th scope="col" title="How often this tier's rounds pay out, and among how many qualifiers — from XvB's public winners feed.">Odds / 30d</th>
                    <th scope="col" title="P2Pool earnings forgone by donating the tier threshold for a year, at your current rate.">Cost / yr</th>
                    <th scope="col" title="XvB's own published expected reward — face value: prices every bonus hash at full block reward.">XvB says / yr</th>
                    <th scope="col" title=${
                      measured
                        ? "XvB's figure scaled by what THIS wallet's raffle wins actually paid."
                        : "XvB's figure scaled by the measured delivery band (33%, CI 28–39% — on-chain single-wallet audit, 25 rounds; crawl-corroborated)."
                    }>${estHeader}</th>
                    <th scope="col" title="Estimated reward minus the P2Pool earnings given up. Red: loses even at the optimistic end. Green: profits even at the pessimistic end.">Net / yr</th>
                </tr></thead>
                <tbody>
                ${rows.map((r) => {
                  const est = r.yours !== null ? [r.yours, r.yours] : r.study;
                  return html`<tr class=${r.sustainable ? "" : "text-muted"}
                      title=${r.sustainable ? "" : `Not sustainable at your hashrate — holding this tier needs about ${fmtHashrate(r.threshold)} donated continuously.`}>
                    <th scope="row">${r.name}${r.sustainable ? "" : " ⚠"}</th>
                    <td>${r.oddsPer30d ? `≈ ${Number(r.oddsPer30d.toPrecision(2))} wins · ${Number((r.players || 0).toPrecision(2))} players` : "—"}</td>
                    <td>${r.cost !== null ? formatXmr(r.cost) : "—"}</td>
                    <td class="c-purple">${r.xvbSays !== null ? formatXmr(r.xvbSays) : "—"}</td>
                    <td>${fmtRange(est)}</td>
                    <td class=${r.sustainable ? r.cls : ""}>${r.sustainable ? fmtRange(r.net) : "—"}</td>
                  </tr>`;
                })}
                </tbody>
            </table>
            </div>
            ${
              energy && energy.xmr_price > 0 && best
                ? html`<p class="text-muted text-xs mt-1" id="xvb-fiat-line">
                    ${best.name}: net ≈ ${formatFiat(coinFiat(best.net[0], energy.xmr_price), energy.currency)}
                    … ${formatFiat(coinFiat(best.net[1], energy.xmr_price), energy.currency)} per year at the current XMR price</p>`
                : null
            }
            <p class="text-muted text-xs mt-2">
                ${
                  calc.estimates_available
                    ? "XvB figures fetched over Tor from the operator's published estimates; odds from the public winners feed; the draw is random among qualifiers — donating above a threshold buys no extra odds."
                    : "Expected reward estimate unavailable — tier costs only."
                }
            </p>
        </div>`;
}

// XvB tier / raffle block (#118), inside the earnings card and driven by the same what-if
// hashrate: the highest XMRvsBeast tier that hashrate sustains (computeXvbTier — the server's
// own auto rule), what holding it costs, and the current vs target tier for context. Labelled
// raffle status, never a payout. The draw is random above the threshold — donating more within
// a tier buys nothing — but the odds themselves ARE knowable (#872: qualifier counts from XvB's
// winners file), so the comparison dropdown shows them. Hidden entirely while XvB is disabled.
// `coeffDay` (earnings.coeff_day) feeds the per-tier payout comparison dropdown below.
function XvbTierBlock({ calc, hr, coeffDay, energy, est }) {
  if (!calc || !calc.enabled) return null;
  const t = computeXvbTier(hr, calc);
  return html`
    <div class="xvb-tier-block">
        <h4>XvB Tier (raffle)</h4>
        <div class="stat-grid">
            <${StatCard} label="Sustainable Tier" value=${t ? t.tier : "None"} cls="c-purple"
                         title="The highest XvB donor tier this hashrate sustains while leaving P2Pool its share — the same auto rule the donation controller uses." />
            <${StatCard} label="Hashrate Cost" value=${t ? fmtHashrate(t.cost) : "—"}
                         title="Holding the tier means continuously donating about its threshold — hashrate that earns no P2Pool shares while donated." />
            <${StatCard} label="Current Tier" value=${calc.current_tier}
                         title="The tier your credited XvB donation clears right now (the lower of XvB's 1h and 24h averages)." />
            <${StatCard} label="Target Tier" value=${calc.target_tier}
                         title=${"The tier the donation controller is configured to aim for" + (calc.sustainable ? "." : " — currently NOT sustainable at your hashrate.")} />
        </div>
        ${
          // Current-tier expected reward (#712's published per-day figure) in the same
          // standardized Day/Month/Year table every other tab shows. Only when the server sent a
          // fresh estimate — never fabricated; a fixed published figure, NOT scaled by the
          // what-if hashrate, and the heading says so.
          est && est.xvbDay !== null
            ? html`
        <h4 class="est-heading" title="XvB's published expected reward for the tier your fleet holds now — a raffle expectation across all qualifiers, not scaled by the what-if hashrate above.">
            Current Tier Expected Reward — published by XvB</h4>
        <${EstTable} unit="XMR" day=${est.xvbDay} month=${est.xvbMonth} year=${est.xvbYear}
                     price=${energy ? energy.xmr_price : 0} currency=${energy ? energy.currency : "USD"} />`
            : null
        }
        <${XvbDecisionTable} calc=${calc} coeffDay=${coeffDay} hr=${hr} energy=${energy} />
        <p class="text-muted text-xs mt-2">${calc.note}${calc.mode_note ? " " + calc.mode_note : ""}</p>
    </div>`;
}

// Expected vs actual (#808, reshaped by #817): the comparison the operator otherwise assembles
// by hand across the Earnings tabs, compact enough to be the Simple view's one earnings card.
// Deliberately carries NEITHER view class — card-simple and card-advanced are disjoint (each
// hides in the other's mode), and this is the one earnings surface both views share.
// The server rolls the rows up (build_earnings_vs_actual — window-matched hashrate, same
// confirmed roll-up as the Earnings card); this renders them. ONE shared 30d window for every
// stream (#817). Monero and XvB are ONE combined row: a win pays out through ordinary small
// payouts the payout table cannot attribute, so the confirmed actual already contains XvB XMR —
// the expectation folds XvB's published estimate in so pct compares like with like. Tari stays
// BLOCKS (solo merge-mining pays whole blocks — a count, not a percent); the XvB row keeps only
// its win count, its XMR lives in the combined row by construction. A stream with payout
// confirmation off shows the config key to set instead of a zero that would read as "earned
// nothing"; the card yields to nothing when no stream has anything to compare. The table wraps
// (eva-table) instead of panning — this card never scrolls in either view (#817).
function ExpectedVsActualCard({ summary }) {
  if (!summary) return null;
  const { xmr, tari, xvb } = summary;
  if (!xmr.available && !tari.available && !xvb.enabled) return null;
  const partialMark = (row, text) => (row.partial ? text + " *" : text);
  const anyPartial = (xmr.enabled && xmr.partial) || (tari.enabled && tari.partial);
  const rows = [];
  rows.push({
    label: xmr.includes_xvb ? "Monero + XvB (30d)" : "Monero (30d)",
    expected: xmr.available ? formatXmr(xmr.expected_30d) : "—",
    actual: !xmr.enabled
      ? "set monero.view_key"
      : partialMark(xmr, formatXmr(xmr.actual_30d) + (xmr.pct !== null ? ` (${xmr.pct}%)` : "")),
    dim: !xmr.enabled,
    title: xmr.includes_xvb
      ? "Confirmed on-chain payouts over the trailing 30 days vs the P2Pool linear expectation " +
        "at your 30-day average hashrate PLUS XvB's estimate for your tier — combined " +
        "on both sides, because an XvB win pays out through ordinary payouts that cannot be " +
        "told apart from P2Pool payouts. " +
        (xmr.xvb_realization_pct !== null
          ? `The XvB share is tempered to this wallet's measured win payouts — ` +
            `${xmr.xvb_realization_pct}% of XvB's published face value over the last ` +
            `${xmr.xvb_wins_measured} wins. `
          : "The XvB share is XvB's published face-value estimate — an upper bound: it prices " +
            "every bonus hash at full block reward and assumes every won round runs to " +
            "completion. ") +
        "Payouts swing with luck; a sustained gap is the signal worth checking, not one window."
      : "Confirmed on-chain payouts over the trailing 30 days vs the linear expectation at " +
        "your 30-day average P2Pool hashrate. Any XvB win payouts land in the actual too — " +
        "they cannot be told apart from P2Pool payouts. Payouts swing with luck; a sustained " +
        "gap is the signal worth checking, not one window.",
  });
  rows.push({
    label: "Tari (30d)",
    // Two significant digits, not a fixed decimal: at real Tari difficulty the expectation is a
    // FRACTION of a block per month, and "0.0" would erase exactly the number this row exists
    // to show (≈ 0.0052 blocks is the honest, legible form).
    expected: tari.available ? `≈ ${Number(tari.expected_blocks_30d.toPrecision(2))} blocks` : "—",
    actual: !tari.enabled
      ? "set tari.view_key"
      : partialMark(
          tari,
          `${tari.blocks_30d} block${tari.blocks_30d === 1 ? "" : "s"} · ${formatXtm(tari.xtm_30d)}`,
        ),
    dim: !tari.enabled,
    title:
      "Tari is merge-mined SOLO: a confirmed payout IS a found block, all at once. Expected is " +
      "your 30-day average hashrate × 30 days ÷ the Tari difficulty — at fractions of a block " +
      "per month, zero found is the normal case, not a fault.",
  });
  if (xvb.enabled) {
    rows.push({
      label: "XvB wins (30d)",
      // Forecast from XvB's own winners file (#866): round-type frequency ÷ qualifier count for
      // the held tier. Two significant digits, same honesty rule as the Tari row. "—" while the
      // aggregate is missing or stale — never a guess.
      expected:
        xvb.expected_wins_30d != null
          ? `≈ ${Number(xvb.expected_wins_30d.toPrecision(2))} wins`
          : "—",
      actual:
        `${xvb.wins_30d} win${xvb.wins_30d === 1 ? "" : "s"}` +
        (xvb.last_win_ts ? ` · last ${formatAgo(xvb.last_win_ts)}` : ""),
      dim: false,
      title:
        "Raffle wins recorded in the last 30 days (last-win recency can predate the window). " +
        "Expected is computed from XvB's public winners file: how often your tier's rounds are " +
        "drawn ÷ how many qualifiers they have — for the tier you hold, or the tier you're " +
        "targeting while none is held yet. A win's XMR arrives through ordinary payouts, " +
        "so its value is counted in the Monero + XvB row above — this row tracks the draw.",
    });
  }
  return html`
    <div class="card" id="card-expected-vs-actual">
        <h3>Earnings — Expected vs Actual</h3>
        <table class="est-table eva-table">
            <thead><tr>
                <th></th>
                <th scope="col">Expected</th>
                <th scope="col">Actual</th>
            </tr></thead>
            <tbody>
                ${rows.map(
                  (r) => html`
                <tr title=${r.title}>
                    <th scope="row">${r.label}</th>
                    <td class="c-accent">${r.expected}</td>
                    <td class=${r.dim ? "text-muted" : ""}>${r.actual}</td>
                </tr>`,
                )}
            </tbody>
        </table>
        ${
          anyPartial
            ? html`<p class="text-muted text-xs">* covers only the payout history on record, not the window's full span.</p>`
            : null
        }
    </div>`;
}

// P2Pool earnings calculator (Issue #12). A power-user card (Advanced view) over the metrics
// layer that estimates XMR from *P2Pool mining only* — explicitly not XvB — plus the Tari the
// same hashrate merge-mines alongside it (#117; "—" while merge-mining is inactive). The server
// sends the daily XMR and XTM rates per H/s; this card scales both to a what-if hashrate.
// Stateful because the what-if input is local UI: `input` is null until the user edits it, so
// the field tracks the live P2Pool 1h-average hashrate (the same `p2pool_hr` figure the header /
// Overview show, which already excludes the XvB-donated slice) until they take control, then
// holds their raw text.
// Confirmed on-chain payouts (#381), shown beside the estimate when the view-only wallet feature
// is on (`c.enabled`). Reads the unit-prefixed totals the server rolls up in
// confirmed_payouts_summary (`xmr_*` for Monero, `xtm_*` for Tari); `fmt` is the matching coin
// formatter and `unit` (XMR / XTM) picks the key prefix. Renders nothing when the feature is off,
// so the estimate stands alone.
// The running windows (#787) — yesterday, 7d, 30d — are what an operator checks against the
// estimate above; they carry a `*` and a footnote when the server flagged them partial, so a
// window summed over less history than its label claims never reads as a complete one. The date
// comes from `since_ts` (oldest payout on record) formatted in the VIEWER's locale, while the
// day boundaries were cut in the dashboard container's timezone — close enough to place the
// history, and the footnote says "starts", not a to-the-hour claim.
function confirmedBlock(c, fmt, unit) {
  if (!c || !c.enabled) return null;
  const k = unit.toLowerCase();
  const n = c.count || 0;
  const partial = c.partial || {};
  const anyPartial = ["yesterday", "7d", "30d"].some((w) => partial[w]);
  const since = c.since_ts ? new Date(c.since_ts * 1000).toLocaleDateString() : null;
  const hint = since
    ? `Partial — payout history starts ${since}`
    : "Partial — no payouts on record yet";
  const running = (key, label) => html`
    <${StatCard} label=${partial[key] ? `${label} *` : label}
                 value=${fmt(c[`${k}_${key}`])}
                 title=${partial[key] ? hint : ""} />`;
  const note = `* ${hint.replace("Partial — ", "")} — the window covers only the history on record, not its full span.`;
  return html`
    <div class="confirmed-block">
      <h4 class="confirmed-subhead">Confirmed on-chain</h4>
      <div class="stat-grid">
        ${running("yesterday", "Yesterday")}
        <${StatCard} label="Confirmed 24h" value=${fmt(c[`${k}_24h`])} />
        ${running("7d", "Running 7d")}
        ${running("30d", "Running 30d")}
        <${StatCard} label="Confirmed all-time" value=${fmt(c[`${k}_all`])} />
        <${StatCard} label="Last payout" value=${formatAgo(c.last_ts)}
                     title=${"Across " + n + " confirmed payout" + (n === 1 ? "" : "s")} />
      </div>
      ${anyPartial ? html`<p class="text-muted text-xs">${note}</p>` : null}
    </div>`;
}

class EarningsCard extends Component {
  constructor(props) {
    super(props);
    // `input` (what-if hashrate) is SHARED across tabs — it lives above the tab strip so switching
    // tabs keeps the entered value. `tab` is the active earnings tab (Monero / Tari / XvB),
    // persisted (#658); render() already falls back to monero when the saved tab isn't available.
    this.state = {
      input: null,
      tab: loadPref("dashboardEarningsTab", ["monero", "tari", "xvb", "energy"], "monero"),
    };
    this.onInput = (e) => this.setState({ input: e.target.value });
    this.onTab = (tab) => {
      savePref("dashboardEarningsTab", tab);
      this.setState({ tab });
    };
  }

  render() {
    const e = this.props.earnings;
    if (!e || !e.available) {
      return html`
            <div class="card card-advanced" id="card-earnings">
                <h3>P2Pool Earnings (estimated)</h3>
                <p class="text-muted text-small">Network stats unavailable — the estimate can't be computed right now.</p>
            </div>`;
    }
    const { input, tab } = this.state;
    const useDefault = input === null;
    // Default to your P2Pool 1h-average hashrate (the figure shown in the header / Overview,
    // already excluding the XvB-donated slice); once edited, use the parsed what-if value.
    const hr = useDefault ? e.p2pool_hr : parseHashrate(input);
    const est = computeEarnings(hr, e);
    const xvb = this.props.xvb;
    const energy = this.props.energy;
    // Tabs split the (now multi-domain) card body. XvB only appears when it's enabled and Energy only
    // when the fleet reports any power — there's nothing to show otherwise. The one what-if input
    // above the strip drives every tab's estimate.
    const tabs = [
      { id: "monero", label: "Monero" },
      { id: "tari", label: "Tari" },
    ];
    if (xvb && xvb.enabled) tabs.push({ id: "xvb", label: "XvB" });
    if (energy && energy.available) tabs.push({ id: "energy", label: "Energy" });
    const active = tabs.some((t) => t.id === tab) ? tab : "monero";
    // Fiat estimates (#520): each tab grows ≈-fiat rows once its coin's price is known — static
    // from config.json or live from the opt-in CoinGecko-over-Tor feed. The footer line below
    // states which price the figures are valued at, so a fiat number is never unattributed.
    const priceSrc = priceSourceLabel(energy);
    const priceTitle = "At the price shown in the Prices line below — an estimate, not a payout.";
    return html`
        <div class="card card-advanced" id="card-earnings">
            <h3>P2Pool Earnings (estimated)</h3>
            <p class="text-muted text-xs earnings-subtitle">Estimated XMR from P2Pool mining plus the Tari merge-mined alongside it — excludes XvB donations.</p>
            <div class="earnings-input">
                <label for="whatif-hr">Your P2Pool Hashrate</label>
                <input id="whatif-hr" type="text" inputmode="decimal" spellcheck="false"
                       autocomplete="off" value=${useDefault ? e.p2pool_hr_str : input}
                       onInput=${this.onInput} />
            </div>
            <div class="earnings-tabs" role="tablist" aria-label="Earnings breakdown">
                ${tabs.map(
                  (t) => html`
                    <button role="tab" type="button"
                            id=${"etab-" + t.id} aria-controls=${"epanel-" + t.id}
                            aria-selected=${active === t.id ? "true" : "false"}
                            class=${"earnings-tab" + (active === t.id ? " is-active" : "")}
                            onClick=${() => this.onTab(t.id)}>${t.label}</button>`,
                )}
            </div>

            <div role="tabpanel" id="epanel-monero" aria-labelledby="etab-monero" hidden=${active !== "monero"}>
                <${EstTable} unit="XMR" day=${est.day} month=${est.month} year=${est.year}
                             price=${energy ? energy.xmr_price : 0} currency=${energy ? energy.currency : "USD"}
                             title=${priceTitle} />
                <div class="stat-grid">
                    <${StatCard} label="Time / Share" value=${formatTimeToShare(est.timeToShareSec)} />
                    <${StatCard} label="XMR Block Reward" value=${e.block_reward} />
                </div>
                ${confirmedBlock(e.confirmed, formatXmr, "XMR")}
            </div>

            <div role="tabpanel" id="epanel-tari" aria-labelledby="etab-tari" hidden=${active !== "tari"}>
                <div class="stat-grid">
                    <${StatCard} label="Est. Time to Tari Block" value=${formatTimeToShare(est.tariTimeToBlockSec)}
                                 title="Tari is merge-mined SOLO: the whole block reward lands at once when your hashrate finds a Tari block, roughly this often (difficulty ÷ your hashrate). Shows — while merge-mining is inactive or syncing." />
                    <${StatCard} label="XTM per Block" value=${formatXtm(est.tariRewardPerBlock)} cls="text-accent"
                                 title="The full Tari block reward paid when you solo-find a block — you get all of it at once, not spread over time." />
                    ${
                      energy && energy.tari_price > 0
                        ? html`
                    <${StatCard} label="≈ per Block" value=${formatFiat(coinFiat(est.tariRewardPerBlock, energy.tari_price), energy.currency)} title=${priceTitle} />`
                        : null
                    }
                </div>
                <h4 class="est-heading" title="Long-run average, NOT steady income. Solo merge-mining pays the whole block reward at once, roughly every 'time to Tari block' — these figures just spread that lumpy payout out on paper.">
                    Long-run Average — not steady income</h4>
                <${EstTable} unit="XTM" day=${est.tariDay} month=${est.tariMonth} year=${est.tariYear}
                             price=${energy ? energy.tari_price : 0} currency=${energy ? energy.currency : "USD"}
                             title=${priceTitle} />
                ${confirmedBlock(e.tari_confirmed, formatXtm, "XTM")}
            </div>

            ${
              xvb && xvb.enabled
                ? html`
            <div role="tabpanel" id="epanel-xvb" aria-labelledby="etab-xvb" hidden=${active !== "xvb"}>
                <${XvbTierBlock} calc=${xvb} hr=${hr} coeffDay=${e.coeff_day} energy=${energy} est=${est} />
            </div>`
                : null
            }
            ${
              energy && energy.available
                ? html`
            <div role="tabpanel" id="epanel-energy" aria-labelledby="etab-energy" hidden=${active !== "energy"}>
                <${EnergyPanel} energy=${energy} est=${est} />
            </div>`
                : null
            }
            ${
              priceSrc
                ? html`<p class="text-muted text-xs mt-2" id="earnings-price-source">
                    Prices: XMR ${formatFiatPrice(energy.xmr_price, energy.currency)} · XTM ${formatFiatPrice(energy.tari_price, energy.currency)} — ${priceSrc}
                </p>`
                : null
            }
            <p class="earnings-disclaimer text-muted text-xs mt-2">${e.disclaimer}</p>
        </div>`;
  }
}

// Energy & profit tab body (#260). Fleet power draw + efficiency (always, when any power is known),
// then energy cost once an electricity price is set, then net profit once an XMR price is also set —
// each layer appears only when its inputs exist, so the operator never sees a fabricated figure.
// Setting a Tari price too (#520) folds the Tari merge-mining estimate into gross, and the current
// XvB tier's published expected reward folds in when XvB sends a fresh one (#712); the heading and
// the Net/day tooltip say exactly what's counted — including that XvB is an estimate — so the net
// is never silently partial or over-confident. `est` is the earnings for the shared what-if
// hashrate; the client does the kWh/cost/net math.
function EnergyPanel({ energy, est }) {
  const en = computeEnergy(energy, est);
  const cur = energy.currency;
  const haveCost = energy.cost_per_kwh > 0;
  const haveNet = haveCost && energy.xmr_price > 0;
  // Honest label (#520, #712): say exactly what gross counts so the net figure is never silently
  // partial. XvB is tagged "(est.)" — it's the current tier's published expected reward, and the
  // raffle draw is probabilistic. When XvB isn't folded in, the strings are byte-identical to the
  // pre-#712 label/tooltip.
  const netLabel = en.includesXvb
    ? en.includesTari
      ? "P2Pool + Tari + XvB (est.), after power"
      : "P2Pool + XvB (est.), after power"
    : en.includesTari
      ? "P2Pool + Tari, after power"
      : "P2Pool XMR only, after power";
  const netTitle = en.includesXvb
    ? en.includesTari
      ? "P2Pool XMR + Tari (merge-mined) earnings at your set prices, plus the current XvB tier's published expected reward valued at your XMR price, minus power cost. XvB is an estimate — the raffle draw is random among qualifiers."
      : "P2Pool XMR earnings at your XMR price plus the current XvB tier's published expected reward valued at your XMR price, minus power cost. Excludes Tari (set dashboard.energy.tari_price to include it). XvB is an estimate — the raffle draw is random among qualifiers."
    : en.includesTari
      ? "P2Pool XMR + Tari (merge-mined) earnings at your set prices, minus power cost. Excludes XvB (raffle status, not a per-day income estimate)."
      : "P2Pool XMR earnings at your XMR price, minus power cost. Excludes Tari (set dashboard.energy.tari_price to include it) and XvB (raffle status, not a per-day income estimate).";
  // One standardized Day/Month/Year table for the whole money side: kWh always, then Revenue /
  // Cost / Net columns as their inputs exist (same appearance gates as before — never a
  // fabricated figure). Revenue is the gross the net starts from, so the estimate is no longer
  // implicit; Net keeps the one judgment colour (green profit / red loss).
  const rows = [
    ["Day", en.kwhDay, en.grossDay, en.costDay, en.netDay],
    ["Month", en.kwhMonth, en.grossMonth, en.costMonth, en.netMonth],
    ["Year", en.kwhYear, en.grossYear, en.costYear, en.netYear],
  ];
  return html`
    <div class="stat-grid">
        <${StatCard} label="Fleet Power" value=${formatUnit(energy.total_watts, "W")}
                     cls=${energy.incomplete ? "status-warn" : ""}
                     title=${
                       energy.incomplete
                         ? "Summed draw of the workers that report power (RAPL) or have a configured estimate — a lower bound: some workers report neither and are excluded."
                         : "Summed measured/estimated draw across the fleet."
} />
        <${StatCard} label="Efficiency" value=${formatUnit(energy.hs_per_watt, "H/s·W", 2)}
                     title="Fleet hashrate ÷ fleet watts." />
    </div>
    <h4 class="est-heading">Energy${haveCost ? ` — Cost${haveNet ? ` & Net Profit, ${netLabel}` : ""} (${cur})` : ""}</h4>
    <div class="est-scroll">
    <table class="est-table">
        <thead><tr>
            <th></th>
            <th scope="col">kWh</th>
            ${haveNet ? html`<th scope="col" title=${netTitle}>Revenue (est.)</th>` : null}
            ${haveCost ? html`<th scope="col">Power Cost</th>` : null}
            ${haveNet ? html`<th scope="col" title=${netTitle}>Net</th>` : null}
        </tr></thead>
        <tbody>
            ${rows.map(
              ([label, kwh, gross, cost, net]) => html`
            <tr>
                <th scope="row">${label}</th>
                <td>${formatUnit(kwh, "")}</td>
                ${haveNet ? html`<td class="c-accent">${formatFiatAmount(gross)}</td>` : null}
                ${haveCost ? html`<td>${formatFiatAmount(cost)}</td>` : null}
                ${haveNet ? html`<td class=${netCls(net)} title=${netTitle}>${formatFiatAmount(net)}</td>` : null}
            </tr>`,
            )}
        </tbody>
    </table>
    </div>
    ${
      haveCost
        ? haveNet
          ? null
          : html`<p class="text-muted text-xs mt-2">Set <code>dashboard.energy.xmr_price</code> (in your currency), or <code>dashboard.energy.price_feed: true</code> to fetch live prices from CoinGecko over Tor (opt-in — off by default, no clearnet egress), to see revenue and net profit.</p>`
        : html`<p class="text-muted text-xs mt-2">Set <code>dashboard.energy.cost_per_kwh</code> to see energy cost and net profit after power.</p>`
    }`;
}

// Pool cadence & luck (#84). Read-only Advanced card over server-formatted figures: time since the
// pool's last block (pool-wide, not a payout to you), the expected time for your hashrate to find a
// sidechain share, luck, and YOUR PPLNS share-weight (sum of your share difficulty in the window —
// not p2pool's pool-wide pplnsWeight shown in the node stats).
function CadenceCard({ cadence }) {
  if (!cadence) return null;
  return html`
    <div class="card card-advanced" id="card-cadence">
        <h3>Pool Cadence & Luck</h3>
        <div class="stat-grid">
            <${StatCard} label="Since Pool's Last Block" value=${cadence.since_block}
                         title=${"Last block the pool found (" + cadence.last_block + ") — pool-wide, not a payout to you."} />
            <${StatCard} label="Est. Time / Share" value=${cadence.tts}
                         title="Expected time for your P2Pool hashrate to find one sidechain share (share difficulty ÷ your 1h average)." />
            <${StatCard} label="Luck" value=${cadence.luck}
                         title="Actual vs expected shares in the PPLNS window, as a percentage. Over 100% = running lucky." />
            <${StatCard} label="Your PPLNS Weight" value=${cadence.weight}
                         title="Sum of your share difficulty inside the PPLNS window — your slice of the next payout. Not the pool-wide PPLNS weight." />
        </div>
    </div>`;
}

function TariCard({ tari }) {
  return html`
    <div class="card card-advanced" id="card-tari">
        <h3>Tari Merge-Mining</h3>
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
  if (pool === "p2pool") return html`<span class="badge badge-ok">P2Pool</span>`;
  if (pool === "xvb") return html`<span class="badge badge-purple">XvB</span>`;
  return html`<span class="badge badge-bad">Unknown</span>`;
}

// RigForge enriched feed (#235): a monospace version badge plus health / power / tune / watchdog
// chips, all built server-side (views._rigforge_display) so the client stays a dumb renderer. A
// plain-xmrig worker has no `rigforge` block and renders nothing extra — no chips, no error, no
// empty placeholder, exactly as today. Each chip is a {text, variant, title}; only present-data
// chips are emitted, so a rig with no RAPL shows no power chip.
function RigForgeChips({ rf }) {
  if (!rf) return null;
  return html`${
    rf.version
      ? html` <span class="badge badge-outline version-badge" title="RigForge version">rf ${rf.version}</span>`
      : null
  }${(rf.chips || []).map(
    (c) => html` <span class=${"badge badge-" + c.variant} title=${c.title || ""}>${c.text}</span>`,
  )}`;
}

// Per-worker RigForge new-release callout (#596) — the worker-level twin of UpdateBadge. Shown
// only when the server derived that this rig's reported RigForge version is older than the latest
// release (same dashboard.check_for_updates gate). Notify-only — a link to the release notes; the
// one-click rig upgrade is the separate #597.
const RigUpdateBadge = ({ up }) =>
  up && up.available && up.url
    ? html` <a class="badge badge-accent" href=${up.url} target="_blank" rel="noopener noreferrer"
              title=${"A newer RigForge release is available: " + up.latest}>rf ${up.latest} available ↗</a>`
    : null;

// Pool-wide proxy share totals (Issue #82) — a footer under the table. Hidden until the proxy
// has reported any shares so it isn't an all-zero line on a fresh start.
const ProxyTotals = ({ summary }) => {
  if (!summary || !summary.has_data) return null;
  // htm trims whitespace that wraps across a newline at an element boundary, so the spaces
  // around the rejected <span> are added explicitly via ${' '} rather than left to indentation.
  const rejCls = summary.reject_level === "high" ? "status-bad" : "";
  return html`
    <div class="proxy-totals text-small text-muted">
        Proxy totals: <span class="status-ok">${summary.accepted}</span> accepted ·${" "}
        <span class=${rejCls}>${summary.rejected}</span> rejected (${summary.reject_pct}) ·${" "}
        ${summary.invalid} invalid · Best diff ${summary.best}
    </div>`;
};

function WorkersTable({ workers, summary, ui, onSort, hostIp, stratumPort, onInspect }) {
  // First-run empty state (#385): until the proxy has ever reported a worker, the table would be
  // eight headers over nothing — show the one action the operator must take instead. `workers`
  // includes offline rigs, so a fleet that is temporarily all-offline keeps its (red) table.
  if ((workers || []).length === 0) {
    const addr = hostIp && hostIp !== "Unknown Host" ? hostIp : "YOUR_STACK_IP";
    const port = stratumPort || 3333; // configurable via p2pool.stratum_port (#172)
    return html`
        <div class="card">
            <h3>Workers Alive</h3>
            <div class="workers-empty">
                <p>No workers connected yet.</p>
                <p class="text-muted">Point each rig at <code>${addr}:${port}</code> and it appears here —${" "}
                    see the <a href="https://github.com/p2pool-starter-stack/pithead/blob/main/docs/workers.md"
                        target="_blank" rel="noopener noreferrer">workers guide</a>.</p>
            </div>
        </div>`;
  }
  const rows = sortWorkers(workers, ui.sortIndex, ui.sortAsc);
  return html`
    <div class="card">
        <h3>Workers Alive</h3>
        <div class="table-scroll">
            <table id="workers-table">
                <thead>
                    <tr>${WORKER_COLUMNS.map(
                      // Sorted column carries the direction, visibly (arrow) and for AT (aria-sort);
                      // the title makes clickability discoverable without hovering rows (#656).
                      // The click target is a real <button> so keyboard users can sort too (#671):
                      // native buttons are focusable and activate on Enter/Space without extra wiring.
                      (c, i) => html`<th
                            class=${i === ui.sortIndex ? "sorted" : null}
                            aria-sort=${i === ui.sortIndex ? (ui.sortAsc ? "ascending" : "descending") : null}><button
                              type="button" class="th-sort-btn" onClick=${() => onSort(i)}
                              title=${"Sort by " + c.label}>${c.label}${
                                i === ui.sortIndex
                                  ? html`<span class="sort-arrow">${ui.sortAsc ? " ▲" : " ▼"}</span>`
                                  : ""
                              }</button></th>`,
                    )}</tr>
                </thead>
                <tbody id="workers-tbody">
                    ${rows.map(
                      (w) => html`
                        <tr class=${w.status === "online" ? "status-ok" : "status-bad"}>
                            <td>${
                              onInspect
                                ? html`<button type="button" class="worker-name-link" onClick=${() => onInspect(w.name)}
                                                title="Inspect / edit this worker's config">${w.name}</button>`
                                : w.name
                            } <${PoolBadge} pool=${w.pool} />${
                              w.api_ok === false
                                ? html` <span class="badge badge-bad" title="The dashboard couldn't read this worker's xmrig API, so uptime and per-miner hashrate are unavailable (it still mines — figures come from the proxy). Check workers.api_auth / api_port, or the miner's xmrig http settings.">api ⚠</span>`
                                : null
                            }<${RigForgeChips} rf=${w.rigforge} /><${RigUpdateBadge} up=${w.rigforge_update} /></td>
                            <td>${w.ip}</td>
                            <td>${uptimeCell(w)}</td>
                            <td>${w.h60_str}</td>
                            <td>${w.h15_str}</td>
                            <td>${w.accepted_str}</td>
                            <td>${w.rejected_str}${
                              w.reject_flag
                                ? html` <span class="badge badge-bad" title=${w.reject_flag.title}>${w.reject_flag.text}</span>`
                                : null
                            }</td>
                        </tr>`,
                    )}
                </tbody>
            </table>
        </div>
        <${ProxyTotals} summary=${summary} />
    </div>`;
}

// --- Operational view ----------------------------------------------------------------

// Component Health & egress posture (#170). The topology map (StackTopology) is the panel: every
// component and the route of each link, derived from live config (service/egress.py), so it can't
// drift from reality. The glanceable summary rides in the header badges + the line below; the older
// per-component egress list lives on as an expandable drawer for the full text detail / a11y.
function ComponentHealth({ topology, egress }) {
  if (!topology) return null;
  const ok = topology.summary.level === "ok";
  return html`
    <div class="card card-advanced" id="card-egress">
        <h3>Stack Topology & Egress</h3>
        <div class=${"egress-summary c-" + (ok ? "ok" : "bad")}>
            ${ok ? "🛡️" : "⚠️"} ${topology.summary.label}
        </div>
        <${StackTopology} topology=${topology} />
        ${
          egress
            ? html`<details class="egress-details">
                <summary>All connections (per component)</summary>
                <div class="egress-list">
                    ${egress.components.map(
                      (comp) => html`
                        <div class="egress-component">
                            <div class="egress-name">${comp.name}</div>
                            <ul class="egress-conns">
                                ${comp.conns.map((conn) => {
                                  const r = egressRoute(conn.route);
                                  return html`
                                    <li class="egress-conn">
                                        <span class=${"egress-route c-" + r.cls}>${r.icon} ${r.label}</span>
                                        <span class="egress-to"
                                            >${conn.to}${
                                              conn.blocked_by_firewall
                                                ? html` <span class="egress-note">(firewall-blocked)</span>`
                                                : ""
                                            }</span
                                        >
                                    </li>`;
                                })}
                            </ul>
                        </div>`,
                    )}
                </div>
              </details>`
            : ""
        }
    </div>`;
}

// One-time discoverability hint (#425). The earnings + XvB tier calculators are Advanced-view
// cards, so an operator on the default Simple view never sees them and concludes they don't
// exist. This banner points at Advanced view until the operator acts on it: the inline button
// switches views (dashboard.js retires the hint on any visit to Advanced), and the × dismisses
// it outright. `ui.hintDismissed` is persisted in localStorage by dashboard.js like the other
// UI state, so the hint shows once per browser, not once per reload.
function AdvancedHint({ ui, onView, onDismissHint }) {
  if (ui.view !== "simple" || ui.hintDismissed) return null;
  return html`
    <div class="advanced-hint" id="advanced-hint">
        <span>Looking for earnings estimates or the XvB tier calculator? They live in${" "}
            <button type="button" class="btn-link" onClick=${() => onView("advanced")}>Advanced view</button>.</span>
        <button type="button" class="advanced-hint-dismiss" aria-label="Dismiss hint"
                title="Dismiss" onClick=${onDismissHint}>×</button>
    </div>`;
}

function DashboardView({
  state,
  ui,
  onRange,
  onSort,
  onView,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onDismissHint,
  onInspect,
}) {
  const advanced = ui.view === "advanced";
  const configView = ui.view === "config";
  // Layout by operator relevance (#159): the at-a-glance chart and the rigs themselves lead (this
  // stack may drive many machines), then this stack's own detail cards, then pool-wide and network
  // context as reference at the bottom — "mine" first, "the world" last.
  return html`
    <div id="dashboard-view" class=${advanced ? "mode-advanced" : ""}>
        <div class="view-controls">
            <div class="toggle-group" role="group" aria-label="Dashboard view">
                <button class=${"btn-toggle" + (!advanced && !configView ? " active" : "")} aria-pressed=${!advanced && !configView}
                    title="Chart, workers and the headline numbers" onClick=${() => onView("simple")}>Simple</button>
                <button class=${"btn-toggle" + (advanced ? " active" : "")} aria-pressed=${advanced}
                    title="Every stats card, calculators and diagnostics" onClick=${() => onView("advanced")}>Advanced</button>
                <button class=${"btn-toggle" + (configView ? " active" : "")} aria-pressed=${configView}
                    title="View or edit the stack configuration" onClick=${() => onView("config")}>Configuration</button>
            </div>
        </div>
        <${AdvancedHint} ui=${ui} onView=${onView} onDismissHint=${onDismissHint} />
        ${
          configView
            ? html`<div class="card-stack"><${ConfigView} /><${SecurityPanel} /></div>`
            : null
        }
        ${
          configView
            ? null
            : html`
        <div class="grid">
            <${ChartCard} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
                          xvbHistory=${state.xvb_history} avgWindow=${ui.avg}
                          onRange=${onRange} onZoom=${onZoom} onResetZoom=${onResetZoom}
                          onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
        </div>
        <div class="grid">
            <${WorkersTable} workers=${state.workers} summary=${state.proxy_summary} ui=${ui} onSort=${onSort} hostIp=${state.host_ip} stratumPort=${state.stratum_port}
                             onInspect=${state.control_enabled ? onInspect : null} />
        </div>
        <div class="grid">
            <div class="grid-section-label">Your Stack</div>
            <${Overview} state=${state} />
            <${ExpectedVsActualCard} summary=${state.earnings_summary} />
            <${NodeStats} state=${state} />
            <${XvBStats} state=${state} />
            <${EarningsCard} earnings=${state.earnings} xvb=${state.xvb_calc} energy=${state.energy} />
            <${CadenceCard} cadence=${state.cadence} />
            <${TariCard} tari=${state.tari} />
            <div class="grid-section-label">The Wider Pool</div>
            <${GlobalStats} state=${state} />
            <${NetworkCard} state=${state} />
            <${ComponentHealth} topology=${state.topology} egress=${state.egress} />
        </div>`
        }
    </div>`;
}

// --- Root ----------------------------------------------------------------------------

export function App({
  state,
  connected,
  ui,
  onRange,
  onSort,
  onView,
  onTheme,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onDismissHint,
  onInspect,
  onCloseInspect,
}) {
  // The theme toggle is fixed-position and always available, even before the first data load.
  const switcher = html`<${ThemeSwitcher} theme=${ui.theme} onTheme=${onTheme} />`;
  // Worker Inspect overlay (#185): opened from a worker name in the table; the panel does its own
  // fetch/apply/poll. `key` remounts it when a different worker is picked. Only reachable when the
  // control channel is on (the trigger is gated on state.control_enabled).
  const inspect =
    state && ui.inspectWorker
      ? html`<${WorkerInspect} name=${ui.inspectWorker} onClose=${onCloseInspect} key=${ui.inspectWorker} />`
      : null;
  if (!state) {
    return html`<${Fragment}>
            <div class="loading">${
              connected
                ? "Connecting to the dashboard… If this machine is still syncing its first chain, progress appears here in a moment."
                : "Cannot reach the dashboard."
            }</div>
            ${switcher}
        <//>`;
  }
  return html`<${Fragment}>
        <${Header} state=${state} />
        ${!connected ? html`<div class="disconnected-banner">Disconnected — showing data from ${state.last_update}. Retrying…</div>` : null}
        ${
          state.syncing
            ? html`<${SyncView} sync=${state.sync} />`
            : html`<${Fragment}>
                <${HeroBand} state=${state} />
                <${MineCartTrain} chart=${state.chart} blocks=${state.blocks} payouts=${state.payouts} />
                <${DashboardView} state=${state} ui=${ui} onRange=${onRange} onSort=${onSort}
                                  onView=${onView} onZoom=${onZoom} onResetZoom=${onResetZoom}
                                  onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow}
                                  onDismissHint=${onDismissHint} onInspect=${onInspect} />
              <//>`
        }
        ${inspect}
        ${switcher}
    <//>`;
}
