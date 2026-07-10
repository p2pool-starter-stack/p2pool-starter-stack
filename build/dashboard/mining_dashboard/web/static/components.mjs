// Dashboard components. Each is a pure function of the /api/state JSON (see views.build_state
// on the server). The server sends formatted display strings and semantic tokens
// (variant: "ok"/"purple"/"accent"/"muted", level: "high"/"ok"); the client maps those to
// classes — it does no number formatting or business logic of its own.

import { ChartCard } from "./chart.mjs";
import { ConfigEditor } from "./config-editor.mjs";
import {
  computeEarnings,
  computeXvbTier,
  egressRoute,
  fmtHashrate,
  formatTimeToShare,
  formatXmr,
  formatXtm,
  heroKpis,
  parseHashrate,
  raffleCls,
  sortWorkers,
  THEME_LABELS,
  THEME_ORDER,
  uptimeCell,
  WORKER_COLUMNS,
  xvbTierComparison,
} from "./logic.mjs";
import { Component, Fragment, html } from "./preact.mjs";
import { StackTopology } from "./topology.mjs";

// Palette token -> text-colour class (defined in dashboard.css).
const cVar = (v) => "c-" + v;

// --- Small shared pieces -------------------------------------------------------------

const StatCard = ({ label, value, cls, span, title }) => html`
    <div class=${"stat-card" + (span ? " col-span-2" : "")} title=${title || ""}>
        <h5>${label}</h5>
        <p class=${cls || ""}>${value}</p>
    </div>`;

const SharesStat = ({ sw, label = "Share In Window" }) => html`
    <div class="stat-card">
        <h5>${label}</h5>
        <p><span class=${sw.ok ? "status-ok" : "status-bad"}>${sw.count}</span></p>
    </div>`;

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
// (opt-in `dashboard.check_for_updates`, off by default). Notify-only — it's a link to the release,
// not an upgrade button (#59). Accent so it's noticeable; opens the release page in a new tab.
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
                    <span class=${(s.disk.level === "high" ? "status-bad" : "text-muted") + " mr-2"}>Disk: ${s.disk.used} / ${s.disk.total} GB (${s.disk.percent})</span> <${HighUsage} level=${s.disk.level} />
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
            <div class=${"text-xs mt-xs " + cVar(hr.xvb_variant)}>XvB (routed): ${hr.xvb_routed_1h} (1h) / ${hr.xvb_routed_24h} (24h)</div>
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
    t = state.tari;
  // Stat order (#159): fleet headline (total / mode / workers) → raffle status (tier / VIP /
  // shares / target) → routed split → reference (last share / Tari / wallets).
  return html`
    <div class="card card-simple" id="card-overview">
        <h3>Overview</h3>
        <div class="stat-grid">
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Workers Alive" value=${state.proxy_workers} />
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Raffle Eligible" value=${state.raffle_eligible.label} cls=${raffleCls(state.raffle_eligible)} />
            <${SharesStat} sw=${state.shares_window} />
            <${StatCard} label="Target Tier" value=${hr.target_tier} />
            <${StatCard} label="P2Pool 1h (routed)" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h (routed)" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="XvB 1h (routed)" value=${hr.xvb_routed_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="XvB 24h (routed)" value=${hr.xvb_routed_24h} cls=${cVar(hr.xvb_variant)} />
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
        <div class=${"text-xs mt-2 " + (hr.xvb_stale ? "status-warn" : "text-muted")} title=${credTitle}>
            ${hr.xvb_stale ? "⚠ Stale — last successful fetch from xmrvsbeast.com: " : "Stats fetched from xmrvsbeast.com (Updated: "}${hr.xvb_updated}${hr.xvb_stale ? "" : ")"}
        </div>
    </div>`;
}

function NetworkCard({ state }) {
  const n = state.network,
    m = state.monero;
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

// XvB per-tier payout comparison dropdown (#118). Picks one of the four donor tiers and weighs XvB's
// OWN published expected reward for it (server-fetched over Tor) against the P2Pool earnings donating
// that tier costs, and the net. Defaults to the operator's target tier. When XvB's estimate is
// stale/unavailable it shows the tier cost with an "estimate unavailable" note — never a fabricated
// number. Selection is local UI state; the whole block is a raffle comparison, not a claim that
// donating above a tier threshold pays more (it does not — the draw is random among qualifiers).
class XvbComparison extends Component {
  constructor(props) {
    super(props);
    this.state = { selected: null };
    this.onSelect = (e) => this.setState({ selected: e.target.value });
  }

  render() {
    const { calc, coeffDay, hr } = this.props;
    const tiers = (calc && calc.tiers) || [];
    if (!tiers.length) return null;
    const { selected } = this.state;
    // Default the dropdown to the operator's configured target tier; fall back to the lowest.
    const sel =
      tiers.find((t) => t.name === selected) ||
      tiers.find((t) => t.name === calc.target_tier) ||
      tiers[0];
    const cmp = xvbTierComparison(sel, coeffDay);
    // The same sustains rule the tier block states: donating the threshold must fit inside the
    // donateable share of the what-if hashrate. An unsustainable tier's Net is "—" — showing,
    // say, Mega's +56 XMR/yr to a 269 kH/s fleet would imply an unreachable payout.
    const sustainable = hr > 0 && sel.threshold <= hr * (calc.max_fraction || 0);
    const expected =
      calc.estimates_available && cmp.expected !== null
        ? formatXmr(cmp.expected)
        : "estimate unavailable";
    return html`
        <div class="xvb-comparison">
            <label class="xvb-compare-label" for="xvb-tier-select">Compare tier payout (per year)</label>
            <select id="xvb-tier-select" class="xvb-tier-select" value=${sel.name} onChange=${this.onSelect}>
                ${tiers.map((t) => html`<option value=${t.name}>${t.name}</option>`)}
            </select>
            <div class="stat-grid mt-2">
                <${StatCard} label="Expected (XvB)" value=${expected} cls="c-purple"
                             title="XvB's own published expected reward for this tier per year (their reward_calc figures, fetched over Tor). This is the raffle expectation across all qualifiers — donating above the tier threshold does NOT raise it." />
                <${StatCard} label="Cost / yr" value=${cmp.cost !== null ? formatXmr(cmp.cost) : "—"}
                             title="P2Pool earnings foregone by donating the tier threshold for a year (threshold × the P2Pool daily rate × 365)." />
                <${StatCard} label="Net / yr" value=${sustainable && cmp.net !== null ? formatXmr(cmp.net) : "—"}
                             title=${
                               sustainable
                                 ? "Expected XvB reward minus the P2Pool earnings given up. Shown only when XvB's estimate is available."
                                 : "Not shown — this tier isn't sustainable at your hashrate, so its payout isn't reachable."
} />
            </div>
            ${
              !sustainable
                ? html`<p class="status-warn text-xs mt-1">Not sustainable at your hashrate — holding this tier needs about ${fmtHashrate(sel.threshold)} donated continuously, more than your hashrate can spare.</p>`
                : null
            }
            <p class="text-muted text-xs mt-2">
                ${
                  calc.estimates_available
                    ? "From XvB's published per-tier estimate, fetched over Tor."
                    : "Expected reward estimate unavailable — showing tier cost only."
                }
            </p>
        </div>`;
  }
}

// XvB tier / raffle block (#118), inside the earnings card and driven by the same what-if
// hashrate: the highest XMRvsBeast tier that hashrate sustains (computeXvbTier — the server's
// own auto rule), what holding it costs, and the current vs target tier for context. Labelled
// raffle status, never a payout; deliberately no entry counts or win odds — the draw is random
// above the threshold. Hidden entirely while XvB is disabled. `coeffDay` (earnings.coeff_day)
// feeds the per-tier payout comparison dropdown below.
function XvbTierBlock({ calc, hr, coeffDay }) {
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
        <${XvbComparison} calc=${calc} coeffDay=${coeffDay} hr=${hr} />
        <p class="text-muted text-xs mt-2">${calc.note}${calc.mode_note ? " " + calc.mode_note : ""}</p>
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
class EarningsCard extends Component {
  constructor(props) {
    super(props);
    // `input` (what-if hashrate) is SHARED across tabs — it lives above the tab strip so switching
    // tabs keeps the entered value. `tab` is the active earnings tab (Monero / Tari / XvB).
    this.state = { input: null, tab: "monero" };
    this.onInput = (e) => this.setState({ input: e.target.value });
    this.onTab = (tab) => this.setState({ tab });
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
    // Tabs split the (now three-domain) card body. XvB only appears when it's enabled — there's no
    // tier to show otherwise. The one what-if input above the strip drives every tab's estimate.
    const tabs = [
      { id: "monero", label: "Monero" },
      { id: "tari", label: "Tari" },
    ];
    if (xvb && xvb.enabled) tabs.push({ id: "xvb", label: "XvB" });
    const active = tabs.some((t) => t.id === tab) ? tab : "monero";
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
                <div class="stat-grid">
                    <${StatCard} label="XMR / day" value=${formatXmr(est.day)} cls="text-accent" />
                    <${StatCard} label="XMR / month" value=${formatXmr(est.month)} cls="text-accent" />
                    <${StatCard} label="XMR / year" value=${formatXmr(est.year)} cls="text-accent" />
                    <${StatCard} label="Time / Share" value=${formatTimeToShare(est.timeToShareSec)} />
                    <${StatCard} label="XMR Block Reward" value=${e.block_reward} />
                </div>
            </div>

            <div role="tabpanel" id="epanel-tari" aria-labelledby="etab-tari" hidden=${active !== "tari"}>
                <div class="stat-grid">
                    <${StatCard} label="Est. Time to Tari Block" value=${formatTimeToShare(est.tariTimeToBlockSec)}
                                 title="Tari is merge-mined SOLO: the whole block reward lands at once when your hashrate finds a Tari block, roughly this often (difficulty ÷ your hashrate). Shows — while merge-mining is inactive or syncing." />
                    <${StatCard} label="XTM per Block" value=${formatXtm(est.tariRewardPerBlock)}
                                 title="The full Tari block reward paid when you solo-find a block — you get all of it at once, not spread over time." />
                    <${StatCard} label="XTM / day (avg)" value=${formatXtm(est.tariDay)}
                                 title="Long-run average, NOT steady income. Solo merge-mining pays the whole block reward at once, roughly every 'time to Tari block' — this per-day figure just spreads that lumpy payout out on paper." />
                </div>
            </div>

            ${
              xvb && xvb.enabled
                ? html`
            <div role="tabpanel" id="epanel-xvb" aria-labelledby="etab-xvb" hidden=${active !== "xvb"}>
                <${XvbTierBlock} calc=${xvb} hr=${hr} coeffDay=${e.coeff_day} />
            </div>`
                : null
            }
            <p class="earnings-disclaimer text-muted text-xs mt-2">${e.disclaimer}</p>
        </div>`;
  }
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

function WorkersTable({ workers, summary, ui, onSort, hostIp }) {
  // First-run empty state (#385): until the proxy has ever reported a worker, the table would be
  // eight headers over nothing — show the one action the operator must take instead. `workers`
  // includes offline rigs, so a fleet that is temporarily all-offline keeps its (red) table.
  if ((workers || []).length === 0) {
    const addr = hostIp && hostIp !== "Unknown Host" ? hostIp : "YOUR_STACK_IP";
    return html`
        <div class="card">
            <h3>Workers Alive</h3>
            <div class="workers-empty">
                <p>No workers connected yet.</p>
                <p class="text-muted">Point each rig at <code>${addr}:3333</code> and it appears here —${" "}
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
                    <tr>${WORKER_COLUMNS.map((c, i) => html`<th onClick=${() => onSort(i)}>${c.label}</th>`)}</tr>
                </thead>
                <tbody id="workers-tbody">
                    ${rows.map(
                      (w) => html`
                        <tr class=${w.status === "online" ? "status-ok" : "status-bad"}>
                            <td>${w.name} <${PoolBadge} pool=${w.pool} />${
                              w.api_ok === false
                                ? html` <span class="badge badge-bad" title="The dashboard couldn't read this worker's xmrig API, so uptime and per-miner hashrate are unavailable (it still mines — figures come from the proxy). Check workers.api_auth / api_port, or the miner's xmrig http settings.">api ⚠</span>`
                                : null
                            }</td>
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

function DashboardView({
  state,
  ui,
  controlEnabled,
  onRange,
  onSort,
  onView,
  onPage,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
}) {
  const advanced = ui.view === "advanced";
  // Layout by operator relevance (#159): the at-a-glance chart and the rigs themselves lead (this
  // stack may drive many machines), then this stack's own detail cards, then pool-wide and network
  // context as reference at the bottom — "mine" first, "the world" last.
  return html`
    <div id="dashboard-view" class=${advanced ? "mode-advanced" : ""}>
        <div class="view-controls">
            <div class="toggle-group">
                <button class=${"btn-toggle" + (!advanced ? " active" : "")} onClick=${() => onView("simple")}>Simple</button>
                <button class=${"btn-toggle" + (advanced ? " active" : "")} onClick=${() => onView("advanced")}>Advanced</button>
                ${
                  // Config editor entry point (#33): only rendered when the control channel is on
                  // (the probe 404s otherwise, so most stacks never see this button).
                  controlEnabled
                    ? html`<button class="btn-toggle" onClick=${() => onPage("config")}>Config</button>`
                    : null
                }
            </div>
        </div>
        <div class="grid">
            <${ChartCard} chart=${state.chart} range=${ui.range} window=${ui.window} series=${ui.series}
                          avgWindow=${ui.avg}
                          onRange=${onRange} onZoom=${onZoom} onResetZoom=${onResetZoom}
                          onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
        </div>
        <div class="grid">
            <${WorkersTable} workers=${state.workers} summary=${state.proxy_summary} ui=${ui} onSort=${onSort} hostIp=${state.host_ip} />
        </div>
        <div class="grid">
            <${Overview} state=${state} />
            <${NodeStats} state=${state} />
            <${XvBStats} state=${state} />
            <${EarningsCard} earnings=${state.earnings} xvb=${state.xvb_calc} />
            <${CadenceCard} cadence=${state.cadence} />
            <${TariCard} tari=${state.tari} />
            <${GlobalStats} state=${state} />
            <${NetworkCard} state=${state} />
            <${ComponentHealth} topology=${state.topology} egress=${state.egress} />
        </div>
    </div>`;
}

// --- Root ----------------------------------------------------------------------------

export function App({
  state,
  connected,
  ui,
  controlEnabled,
  onRange,
  onSort,
  onView,
  onTheme,
  onZoom,
  onResetZoom,
  onToggleSeries,
  onAvgWindow,
  onPage,
}) {
  // The theme toggle is fixed-position and always available, even before the first data load.
  const switcher = html`<${ThemeSwitcher} theme=${ui.theme} onTheme=${onTheme} />`;
  if (!state) {
    return html`<${Fragment}>
            <div class="loading">${connected ? "Connecting to the dashboard…" : "Cannot reach the dashboard."}</div>
            ${switcher}
        <//>`;
  }
  // The configuration editor (#33) replaces the dashboard body; header/banner/theme stay.
  if (ui.page === "config") {
    return html`<${Fragment}>
        <${Header} state=${state} />
        ${!connected ? html`<div class="disconnected-banner">Disconnected — showing data from ${state.last_update}. Retrying…</div>` : null}
        <${ConfigEditor} onBack=${() => onPage("dashboard")} />
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
                <${DashboardView} state=${state} ui=${ui} controlEnabled=${controlEnabled}
                                  onRange=${onRange} onSort=${onSort}
                                  onView=${onView} onPage=${onPage} onZoom=${onZoom} onResetZoom=${onResetZoom}
                                  onToggleSeries=${onToggleSeries} onAvgWindow=${onAvgWindow} />
              <//>`
        }
        ${switcher}
    <//>`;
}
