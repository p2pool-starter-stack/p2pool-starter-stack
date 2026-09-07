// Render smoke tests for the dashboard's Preact components (mining_dashboard/web/static/components.mjs).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// components.mjs exports only the App root by design, so these drive every card *through* App —
// varying the /api/state fixture to reach each branch (loading / syncing / operational) and edge
// case. The fixture is a real build_state() payload (tests/frontend/fixtures/state.json, regenerate
// with fixtures/_gen_state.py), so the components are exercised against the true server contract.
// Rendering uses a dependency-free vnode walker (helpers/render.mjs) — no DOM, no npm deps.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { App } from '../../mining_dashboard/web/static/components.mjs';
import { WORKER_COLUMNS } from '../../mining_dashboard/web/static/logic.mjs';
import { StatsTable } from '../../mining_dashboard/web/static/workerview.mjs';
import { render } from './helpers/render.mjs';
import { cardSlice, clone, renderApp, UI } from './harness.mjs';

// --- App shell / connection states -----------------------------------------------------

test('App without state shows the right connection message', () => {
    assert.match(renderApp({ state: null, connected: true }), /Connecting to the dashboard/);
    assert.match(renderApp({ state: null, connected: false }), /Cannot reach the dashboard/);
});

test('App always renders the theme switcher, even before the first load', () => {
    assert.match(renderApp(), /theme-switcher/);
    assert.match(renderApp({ state: null }), /theme-switcher/);
});

test('operational App shows a disconnected banner when not connected', () => {
    // The banner names the timestamp of the data on screen (#382) — the fixture's last_update.
    assert.match(renderApp({ connected: false }), /Disconnected — showing data from 00:00:00/);
    assert.doesNotMatch(renderApp({ connected: true }), /Disconnected — showing data from/);
});

// --- Header -----------------------------------------------------------------------------

test('Header renders the brand, server badges, version + update badges', () => {
    const html = renderApp();
    assert.match(html, /brand-name">Pithead/);
    assert.match(html, /P2POOL/); // a server-provided mode badge
    assert.match(html, /Tor-only egress/); // the #170 egress badge rides in the header
    assert.match(html, /dev build/); // version badge text
    assert.match(html, /New release v9\.9\.9 available/); // update badge (#224)
});

test('Header surfaces a High Usage badge only when a resource is hot', () => {
    assert.doesNotMatch(renderApp(), /High Usage/); // base fixture is all "ok"
    const s = clone();
    s.system.cpu.level = 'high';
    assert.match(renderApp({ state: s }), /High Usage/);
});

// --- Hero band + operational cards ------------------------------------------------------

test('operational App renders the hero band and the headline cards', () => {
    const html = renderApp();
    assert.match(html, /hero-band/);
    assert.match(html, /Workers Alive/);
    assert.match(html, /Overview/);
    assert.match(html, /My P2Pool Node Stats/);
    assert.match(html, /XvB Donation Stats/);
    assert.match(html, /Stack Topology & Egress/);
    // One casing everywhere (#659): the Overview card matches the hero KPI's lowercase "in".
    assert.match(html, /Share in Window/);
    assert.doesNotMatch(html, /Share In Window/);
});

test('toggle groups carry the ARIA affordances of the theme-switcher pattern (#657)', () => {
    // The vnode walker serializes boolean true as a bare attribute and drops false, so a bare
    // `aria-pressed` marks the pressed control (in the browser Preact writes true/false strings).
    const html = renderApp({ ui: { ...UI, range: '1w' } });
    // Range row: real buttons in a labelled group; the active preset is pressed and titled.
    assert.match(html, /aria-label="Chart range"/);
    assert.match(html, /class="btn-range active" aria-pressed title="Chart range: 1 Wk">1 Wk</);
    // View toggle: labelled group; the active view's button is pressed.
    assert.match(html, /aria-label="Dashboard view"/);
    assert.match(html, /class="btn-toggle active" aria-pressed title="[^"]+">Advanced</);
    // Topology mesh toggle explains itself without hovering the diagram.
    assert.match(html, /class="topo-toggle" title="Container-to-container links inside the stack"/);
});

test('chart range buttons include All, active on the default full-history view (#655)', () => {
    // Default UI state is range 'all' — without an All button no range reads as selected,
    // and after picking a preset there is no way back to full history.
    assert.match(renderApp(), /class="btn-range active"[^>]*>All</);
    const weekly = renderApp({ ui: { ...UI, range: '1w' } });
    assert.match(weekly, /class="btn-range active"[^>]*>1 Wk</);
    assert.doesNotMatch(weekly, /class="btn-range active"[^>]*>All</);
});

test('chart legend renders a toggle for every layer, including the marker datasets (#652)', () => {
    const html = renderApp();
    for (const label of ['P2Pool (routed)', 'XvB (routed)', 'Shares', 'Events', 'Raffle wins']) {
        assert.match(html, new RegExp(`legend-item[^>]*>.*?${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}</button>`),
            `missing legend toggle: ${label}`);
    }
    // A hidden marker layer renders its button in the off state, like the line series do.
    const hidden = renderApp({ ui: { ...UI, series: { events: false } } });
    assert.match(hidden, /class="legend-item off"[^>]*title="Show Events"/);
    assert.match(hidden, /class="legend-item"[^>]*title="Hide Raffle wins"/);
});

test('operational App renders the remaining advanced cards', () => {
    const html = renderApp();
    assert.match(html, /Global P2Pool Stats/);
    assert.match(html, /XMR Network/);
    assert.match(html, /Tari Merge-Mining/);
    assert.match(html, /P2Pool Earnings \(estimated\)/);
});

// --- Progressive disclosure ("show more") on stat-grid cards ---------------------------
//
// Global P2Pool Stats, My P2Pool Node Stats and XMR Network share the MoreStats pattern
// (components.mjs): headline stats always show, the rest sits collapsed behind a real <button>
// until toggled. Several sibling cards reuse the same labels (Overview and My P2Pool Node Stats
// both have a "Mining Mode" stat, for instance), so `cardSlice` scopes assertions to one card's
// own markup — from its id up to the next card's id — rather than matching against the whole page.
test('Global P2Pool Stats collapses to the headline stats by default (progressive disclosure)', () => {
    const card = cardSlice(renderApp(), 'card-global');
    // Headline: the pool's own money/health figures.
    assert.match(card, /Pool Hashrate/);
    assert.match(card, /Blocks Found/);
    assert.match(card, /<h5>Last Block<\/h5>/);
    // Detail (sidechain internals, peers, uptime, ...) stays out of the DOM until expanded.
    assert.doesNotMatch(card, /Sidechain Height/);
    assert.doesNotMatch(card, /PPLNS Window/);
    assert.doesNotMatch(card, /PPLNS Weight/);
    assert.doesNotMatch(card, /<h5>Uptime<\/h5>/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(12\)/);
});

test('My P2Pool Node Stats collapses to the headline stats by default', () => {
    const card = cardSlice(renderApp(), 'card-mynode');
    assert.match(card, /Total Hashrate/);
    assert.match(card, /P2Pool 1h Avg/);
    assert.match(card, /P2Pool 24h Avg/);
    assert.match(card, /Shares \(OK\/Err\)/);
    assert.doesNotMatch(card, /Stratum \(15m/);
    assert.doesNotMatch(card, /Connections/);
    assert.doesNotMatch(card, /Effort/);
    assert.doesNotMatch(card, /Reward Share/);
    assert.doesNotMatch(card, /Total Shares/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(12\)/);
});

test('XMR Network collapses to the headline stats by default', () => {
    const card = cardSlice(renderApp(), 'card-network');
    assert.match(card, /Block Height/);
    assert.match(card, /Difficulty/);
    assert.match(card, /Reward/);
    assert.doesNotMatch(card, /Node Mode/);
    assert.doesNotMatch(card, /DB Size/);
    assert.doesNotMatch(card, /Current Block Hash/);
    assert.doesNotMatch(card, /Network Time/);
    assert.match(card, /class="more-stats-toggle" aria-expanded="false"/);
    assert.match(card, /Show all \(8\)/); // 7 + the node's local/remote location (#1040)
});

test('MoreStats expands to show every stat when toggled, and persists the choice per card, independently of siblings', () => {
    // There is no localStorage under node --test (see logic.test.mjs's loadPref/savePref test) —
    // stub a minimal one so MoreStats's loadPref/savePref calls (the same helpers
    // dashboardEarningsTab already uses) have somewhere to read from, exactly as a real browser
    // would provide. Only dashboardCardNetwork is pre-seeded "expanded"; dashboardCardGlobal is
    // absent, so it must still fall back to collapsed — expansion is per-card, not global.
    const store = new Map([['dashboardCardNetwork', 'expanded']]);
    globalThis.localStorage = {
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
    };
    try {
        const html = renderApp();
        const network = cardSlice(html, 'card-network');
        assert.match(network, /Node Mode/); // detail now visible
        assert.match(network, /Current Block Hash/);
        assert.match(network, /class="more-stats-toggle" aria-expanded="true"/);
        assert.match(network, /Show less/);
        const global = cardSlice(html, 'card-global');
        assert.doesNotMatch(global, /Sidechain Height/);
        assert.match(global, /class="more-stats-toggle" aria-expanded="false"/);
        assert.match(global, /Show all \(12\)/);
    } finally {
        delete globalThis.localStorage;
    }
});

test('Simple view shows the calculators hint until dismissed, never elsewhere (#425)', () => {
    // Fresh browser on the default Simple view: the pointer to the Advanced-only calculators shows.
    const simple = renderApp({ ui: { ...UI, view: 'simple', hintDismissed: false } });
    assert.match(simple, /advanced-hint/);
    assert.match(simple, /earnings estimates or the XvB tier calculator/);
    assert.match(simple, /Advanced view/);
    // Dismissed (dashboard.js persists it): gone from Simple view.
    const dismissed = renderApp({ ui: { ...UI, view: 'simple', hintDismissed: true } });
    assert.doesNotMatch(dismissed, /advanced-hint/);
    // Never shown outside Simple view — Advanced already has the calculators on screen.
    const advanced = renderApp({ ui: { ...UI, view: 'advanced', hintDismissed: false } });
    assert.doesNotMatch(advanced, /advanced-hint/);
    const config = renderApp({ ui: { ...UI, view: 'config', hintDismissed: false } });
    assert.doesNotMatch(config, /advanced-hint/);
});

test('EarningsCard shows the fallback when stats are down, the calculator when available', () => {
    // The base fixture has earnings.available === false → the fallback copy, no what-if input.
    const down = renderApp();
    assert.match(down, /the estimate can't be computed right now/);
    assert.doesNotMatch(down, /whatif-hr/);
    // With stats available, the class component renders its what-if input (local UI state).
    const s = clone();
    s.earnings.available = true;
    const up = renderApp({ state: s });
    assert.match(up, /Your P2Pool Hashrate/);
    assert.match(up, /id="whatif-hr"/);
});

test('EarningsCard leads with solo time-to-block + per-block reward, day as avg (#117)', () => {
    // Merge-mining live: the honest solo headline is time-to-block and the whole per-block reward.
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 2e-3;   // × p2pool_hr (8050) → 16.1 XTM/day (long-run avg)
    s.earnings.tari_difficulty = 1.677e12;  // seconds-to-block per H/s; ÷ 8050 → ~2410 days
    s.earnings.tari_reward = 10_709;
    const up = renderApp({ state: s });
    assert.match(up, /Est\. Time to Tari Block/);
    assert.match(up, /XTM per Block/);
    assert.match(up, /10709\.0000 XTM/);   // the full block reward
    // Per-day/month/year kept, in the standardized table under a not-steady-income heading.
    assert.match(up, /Long-run Average — not steady income/);
    assert.match(up, /16\.1000 XTM/);       // the long-run daily average figure still shown
    assert.match(up, /483\.0000 XTM/);      // ... spanned to month
    assert.match(up, /5876\.5000 XTM/);     // ... and year, same shared precision
    // Merge-mining inactive/syncing: the estimates degrade to "—", but a KNOWN per-block
    // reward keeps showing — it is a fact about the chain (the Tari Merge-Mining card prints
    // the same figure), not a function of this box's hashrate or channel state.
    const off = clone();
    off.earnings.available = true;
    off.earnings.tari_available = false;
    off.earnings.tari_reward = 10_709;
    const down = renderApp({ state: off });
    assert.match(down, /Est\. Time to Tari Block/);
    assert.match(down, /—/);
    assert.match(down, /10709\.0000 XTM/);
    assert.doesNotMatch(down, /NaN/);
});

test('EarningsCard renders the XvB tier (raffle) block on and off — off drops the live-credit cards (#938)', () => {
    const s = clone();
    s.earnings.available = true;
    s.xvb_calc = {
        enabled: true,
        max_fraction: 0.85,
        tiers: [
            { name: 'Donor (1.00 kH/s+)', threshold: 1000 },
            { name: 'Vip (10.00 kH/s+)', threshold: 10000 },
        ],
        current_tier: 'None',
        target_tier: 'Donor (1.00 kH/s+)',
        target_threshold: 1000,
        sustainable: true,
        note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null,
    };
    const up = renderApp({ state: s });
    assert.match(up, /XvB Tier \(raffle\)/);
    // Default what-if hashrate (p2pool_hr ≈ 8k) × 0.85 sustains the Donor tier, not Vip —
    // the client-side transcription of the server's auto rule, with cost = the threshold.
    assert.match(up, /Sustainable Tier/);
    assert.match(up, /Donor \(1\.00 kH\/s\+\)/);
    assert.match(up, /Hashrate Cost/);
    assert.match(up, /1\.00 kH\/s/);
    assert.match(up, /not an XMR payout/);   // the required labelling rides on the card
    assert.doesNotMatch(up, /id="xvb-disabled-note"/); // the off-explainer only shows off
    // XvB disabled (#938): the decision aid stays — what-if cards, table, note — but the
    // live-credit cards (Current/Target tier) stand down and the off-explainer appears.
    s.xvb_calc = { ...s.xvb_calc, enabled: false, current_tier: 'Disabled', target_tier: 'Disabled' };
    const off = renderApp({ state: s });
    assert.match(off, /XvB Tier \(raffle\)/);
    assert.match(off, /Sustainable Tier/);
    assert.match(off, /Hashrate Cost/);
    assert.match(off, /id="xvb-disabled-note"/);
    assert.match(off, /not an XMR payout/);
    assert.doesNotMatch(off, /Current Tier/);
    assert.doesNotMatch(off, /Target Tier/);
    assert.match(off, /Your P2Pool Hashrate/);
});

test('EarningsCard splits into Monero / Tari / XvB tabs, Monero active by default (#118)', () => {
    const s = clone();
    s.earnings.available = true;
    // XvB on → three tabs; the XvB tab only exists when XvB is enabled.
    const html = renderApp({ state: s });
    assert.match(html, /role="tablist"/);
    assert.match(html, /id="etab-monero"[^>]*>Monero</);
    assert.match(html, /id="etab-tari"[^>]*>Tari</);
    assert.match(html, /id="etab-xvb"[^>]*>XvB</);
    // Default active tab = Monero: it is aria-selected and its panel is visible; the others hidden.
    assert.match(html, /id="etab-monero"[^>]*aria-selected="true"/);
    assert.match(html, /id="etab-tari"[^>]*aria-selected="false"/);
    assert.match(html, /id="epanel-monero"[^>]*aria-labelledby="etab-monero">/); // no `hidden` → shown
    assert.match(html, /id="epanel-tari"[^>]*hidden>/); // inactive panel hidden
    assert.match(html, /id="epanel-xvb"[^>]*hidden>/);
    // The shared what-if input sits above the tab strip, so it drives all three tabs.
    assert.match(html, /id="whatif-hr"/);
    // The Monero panel carries the XMR estimate table, the Tari panel the solo time-to-block,
    // the XvB panel the tier block — all present in the DOM (inactive ones just hidden).
    assert.match(html, /class="est-table"/);
    assert.match(html, /scope="row">Day</);
    assert.match(html, /scope="row">Month</);
    assert.match(html, /scope="row">Year</);
    assert.match(html, /Est\. Time to Tari Block/);
    assert.match(html, /XvB Tier \(raffle\)/);
});

test('EarningsCard keeps the XvB tab when disabled; only a tier-less payload drops it (#938)', () => {
    const s = clone();
    s.earnings.available = true;
    // Disabled with a tier table (what the server now always sends): the tab stays — it holds
    // the enable/don't-enable decision aid.
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85,
        tiers: [{ name: 'Donor (1.00 kH/s+)', threshold: 1000 }],
        current_tier: 'Disabled', target_tier: 'Disabled',
        note: 'raffle status', mode_note: null,
    };
    let html = renderApp({ state: s });
    assert.match(html, /id="etab-xvb"/);
    assert.match(html, /id="epanel-xvb"/);
    assert.match(html, /XvB Tier \(raffle\)/);
    // A pre-#938 disabled payload carries no tiers — nothing to price, so no tab either.
    s.xvb_calc = { enabled: false };
    html = renderApp({ state: s });
    assert.match(html, /id="etab-monero"/);
    assert.match(html, /id="etab-tari"/);
    assert.doesNotMatch(html, /id="etab-xvb"/);
    assert.doesNotMatch(html, /id="epanel-xvb"/);
    assert.doesNotMatch(html, /XvB Tier \(raffle\)/);
});

test('EarningsCard shows an Energy tab only when the fleet reports power (#260)', () => {
    const s = clone();
    s.earnings.available = true;
    // Fixture has an available energy block → the Energy tab and panel exist.
    let html = renderApp({ state: s });
    assert.match(html, /id="etab-energy"[^>]*>Energy</);
    assert.match(html, /id="epanel-energy"[^>]*hidden>/); // present but inactive (Monero default)
    assert.match(html, /Fleet Power/);
    assert.match(html, /285\.0 W/); // measured fleet draw from the fixture
    // No electricity price set → the prompt to set cost_per_kwh, and no net-profit figures.
    assert.match(html, /cost_per_kwh/);
    assert.doesNotMatch(html, /Net \/ day/);
    // With no power at all, the Energy tab disappears entirely.
    s.energy = { available: false };
    html = renderApp({ state: s });
    assert.doesNotMatch(html, /id="etab-energy"/);
    assert.doesNotMatch(html, /id="epanel-energy"/);
});

test('EarningsCard Energy tab shows cost then net as prices are set (#260)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8; // small XMR/H/s/day so gross stays sane
    s.energy.cost_per_kwh = 0.2;
    s.energy.currency = 'EUR';
    // Only the electricity price set → the Power Cost column shows, revenue/net still gated on
    // xmr_price (with the hint naming the config key to set).
    let html = renderApp({ state: s });
    assert.match(html, /Power Cost/);
    assert.match(html, /dashboard\.energy\.xmr_price/);
    assert.doesNotMatch(html, /scope="col"[^>]*>Net</);
    assert.doesNotMatch(html, /Revenue \(est\.\)/);
    // Both prices set → the Revenue and Net columns appear, labelled P2Pool-only since
    // tari_price is still unset.
    s.energy.xmr_price = 150;
    html = renderApp({ state: s });
    assert.match(html, /Revenue \(est\.\)/);
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool XMR only, after power/);
    assert.doesNotMatch(html, /P2Pool \+ Tari, after power/);
});

test('EarningsCard Energy tab folds Tari into net profit once tari_price is set and Tari is merge-mining (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 1e-6;
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool \+ Tari, after power/);
    assert.doesNotMatch(html, /P2Pool XMR only, after power/);
});

test('EarningsCard Energy tab keeps the P2Pool-only label when tari_price is set but Tari is not merge-mining (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = false; // no Tari estimate to fold in
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool XMR only, after power/);
    assert.doesNotMatch(html, /P2Pool \+ Tari, after power/);
});

test('EarningsCard Energy tab folds the current-tier XvB estimate into net, labelled an estimate (#712)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.xvb_day = 0.02; // server-derived current-tier expected reward, XMR/day
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    const html = renderApp({ state: s });
    assert.match(html, /scope="col"[^>]*>Net</);
    assert.match(html, /P2Pool \+ XvB \(est\.\), after power/);
    // Tooltip drops the "Excludes XvB" clause and states it's an estimate — tempered by
    // measured delivery, never face value (#902).
    assert.match(html, /XvB is an estimate, tempered by measured delivery/);
    assert.match(html, /never XvB(?:'|&#39;)s face value/);
    assert.doesNotMatch(html, /Excludes XvB/);
    assert.doesNotMatch(html, /P2Pool XMR only, after power/);
});

test('EarningsCard Energy tab: net label/tooltip byte-identical to pre-#712 when no XvB estimate', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.xvb_day = null; // no fresh estimate → XvB not folded in
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    const html = renderApp({ state: s });
    assert.match(html, /P2Pool XMR only, after power/);
    // The exact pre-#712 tooltip, XvB still called out as excluded.
    assert.match(
        html,
        /Excludes Tari \(set dashboard\.energy\.tari_price to include it\) and XvB \(raffle status, not a per-day income estimate\)\./,
    );
    assert.doesNotMatch(html, /XvB \(est\.\)/);
    assert.doesNotMatch(html, /XvB is an estimate/);
});

test('EarningsCard grows fiat rows + a price provenance line once a price is known (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 1e-6;
    // No price anywhere → no fiat columns, no provenance line (nothing to attribute).
    let html = renderApp({ state: s });
    assert.doesNotMatch(html, /≈ USD/);
    assert.doesNotMatch(html, /id="earnings-price-source"/);
    // Static prices set → the Monero + Tari estimate tables grow a ≈-fiat column, XvB gets its
    // fiat mirror line, and the footer attributes the prices to config.json.
    s.energy.xmr_price = 150;
    s.energy.tari_price = 2;
    html = renderApp({ state: s });
    assert.match(html, /≈ USD/); // fiat column header in the estimate tables
    assert.match(html, /≈ per Block/); // Tari tab per-block fiat card
    assert.match(html, /id="xvb-fiat-line"/); // XvB tab fiat mirror
    assert.match(html, /id="earnings-price-source"/);
    assert.match(html, /USD 150\.00/); // the XMR price in use, stated
    assert.match(html, /static, set in config\.json/);
});

test('EarningsCard shows Confirmed on-chain under the estimates on both tabs when payout confirmation is on (#381)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_available = true;
    s.earnings.tari_coeff_day = 2e-3;
    s.earnings.confirmed = {
        enabled: true, count: 3, xmr_24h: 0.25, xmr_yesterday: 0.5, xmr_7d: 0.75,
        xmr_30d: 1.25, xmr_all: 1.75,
        last_ts: Math.floor(Date.now() / 1000) - 3600,
        since_ts: Math.floor(Date.now() / 1000) - 90 * 86400,
        partial: { yesterday: false, '7d': false, '30d': false },
    };
    s.earnings.tari_confirmed = {
        enabled: true, count: 1, xtm_24h: 0, xtm_yesterday: 0, xtm_7d: 4552.15,
        xtm_30d: 4552.15, xtm_all: 4552.15,
        last_ts: Math.floor(Date.now() / 1000) - 7200,
        since_ts: Math.floor(Date.now() / 1000) - 90 * 86400,
        partial: { yesterday: false, '7d': false, '30d': false },
    };
    let html = renderApp({ state: s });
    // One confirmed block per tab (counted by the sub-panel's own class — the phrase also
    // appears in the #808 card's tooltip prose), populated through the coin formatters.
    assert.equal(html.split('confirmed-subhead').length - 1, 2);
    assert.match(html, /0\.250000 XMR/);   // xmr_24h
    assert.match(html, /1\.7500 XMR/);     // xmr_all
    assert.match(html, /4552\.1500 XTM/);  // xtm_all
    assert.match(html, /Last payout/);
    // Running windows (#787): yesterday / 7d / 30d beside the existing 24h and all-time figures.
    assert.match(html, /Yesterday/);
    assert.match(html, /Running 7d/);
    assert.match(html, /Running 30d/);
    assert.match(html, /0\.500000 XMR/);   // xmr_yesterday
    assert.match(html, /1\.2500 XMR/);     // xmr_30d
    // History predates every window here, so nothing is marked partial and no footnote appears.
    assert.doesNotMatch(html, /Partial/);
    // Estimates first, confirmed reality after — on the Tari tab the block follows the
    // Long-run Average table, mirroring the Monero tab's order.
    const tari = html.slice(html.indexOf('id="epanel-tari"'), html.indexOf('id="epanel-xvb"'));
    assert.ok(tari.indexOf('Long-run Average') < tari.indexOf('Confirmed on-chain'));
    // Confirmation off (the default) -> no confirmed block anywhere, estimates stand alone.
    s.earnings.confirmed = { enabled: false };
    s.earnings.tari_confirmed = { enabled: false };
    html = renderApp({ state: s });
    // Scoped to the sub-panel class — the #808 card's tooltip prose reuses the phrase.
    assert.doesNotMatch(html, /confirmed-subhead/);
});

test('EarningsCard marks running windows the payout history does not fully cover (#787)', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.tari_confirmed = { enabled: false };
    // History starts 3 days ago: yesterday is covered, 7d and 30d reach behind it.
    s.earnings.confirmed = {
        enabled: true, count: 1, xmr_24h: 0, xmr_yesterday: 0.5, xmr_7d: 0.5,
        xmr_30d: 0.5, xmr_all: 0.5,
        last_ts: Math.floor(Date.now() / 1000) - 3 * 86400,
        since_ts: Math.floor(Date.now() / 1000) - 3 * 86400,
        partial: { yesterday: false, '7d': true, '30d': true },
    };
    let html = renderApp({ state: s });
    // Only the flagged windows carry the marker — a covered window must not be hedged.
    assert.match(html, /Running 7d \*/);
    assert.match(html, /Running 30d \*/);
    assert.doesNotMatch(html, /Yesterday \*/);
    // One footnote states where the recorded history starts, so a short window never reads as full.
    assert.match(html, /payout history starts/);
    assert.match(html, /covers only the history on record/);
    // Nothing confirmed at all: every running window is flagged and the footnote says so instead
    // of naming a date it doesn't have.
    s.earnings.confirmed = {
        enabled: true, count: 0, xmr_24h: 0, xmr_yesterday: 0, xmr_7d: 0, xmr_30d: 0, xmr_all: 0,
        last_ts: 0, since_ts: 0,
        partial: { yesterday: true, '7d': true, '30d': true },
    };
    html = renderApp({ state: s });
    assert.match(html, /Yesterday \*/);
    assert.match(html, /no payouts on record yet/);
});

test('EarningsCard XvB tab shows the tempered current-tier reward as a day/month/year table', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.xvb_day = 0.002; // fresh (server-tempered, #902) estimate → the standardized table
    let html = renderApp({ state: s });
    // The heading says the figure is tempered by measured delivery, not XvB's face value (#902).
    assert.match(html, /Current Tier Expected Reward — tempered by measured delivery/);
    assert.match(html, /tempered by measured delivery: scaled to what this wallet/);
    assert.match(html, /0\.002000 XMR/);  // day
    assert.match(html, /0\.060000 XMR/);  // month, same shared precision
    assert.match(html, /0\.730000 XMR/);  // year
    // No fresh estimate → no table, nothing fabricated.
    s.earnings.xvb_day = null;
    html = renderApp({ state: s });
    assert.doesNotMatch(html, /Current Tier Expected Reward/);
});

test('EarningsCard Energy tab: revenue in accent, net carries the green/red sign colour', () => {
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-8;
    s.energy.cost_per_kwh = 0.2;
    s.energy.xmr_price = 150;
    // Fixture fleet earns less than power costs at these figures → net is negative → c-bad.
    let html = renderApp({ state: s });
    assert.match(html, /class="c-bad"[^>]*>-/);
    // A richer rate flips the net positive → c-ok, revenue stays accent either way.
    s.earnings.coeff_day = 1e-5;
    html = renderApp({ state: s });
    assert.match(html, /class="c-ok"/);
    assert.match(html, /class="c-accent"/);
});

test('EarningsCard provenance line reflects the live price feed (#520)', () => {
    const s = clone();
    s.earnings.available = true;
    s.energy.xmr_price = 333.97;
    s.energy.tari_price = 0.0004;
    s.energy.price_source = { feed: true, live: true, age_sec: 720 };
    const html = renderApp({ state: s });
    assert.match(html, /live from CoinGecko over Tor/);
    assert.match(html, /12m ago/);
    assert.match(html, /USD 0\.000400/); // tiny XTM price keeps its precision
});

test('CadenceCard shows the — placeholders on a cold stack, real figures when available (#84)', () => {
    // The base fixture has no pool difficulty → cadence.available === false → server-sent dashes.
    const cold = renderApp();
    assert.match(cold, /Pool Cadence & Luck/);
    assert.match(cold, /Since Pool's Last Block/);
    assert.match(cold, /Est\. Time \/ Share/);
    assert.match(cold, /Your PPLNS Weight/);
    assert.match(cold, /—/);
    // With server-computed figures, the card renders them verbatim (no client-side math).
    const s = clone();
    s.cadence = {
        last_block: '12:34:56', since_block: '5m 0s', tts: '1h 0m',
        luck: '123%', weight: '1,234,567', available: true,
    };
    const up = renderApp({ state: s });
    assert.match(up, /5m 0s/);
    assert.match(up, /1h 0m/);
    assert.match(up, /123%/);
    assert.match(up, /1,234,567/);
});

test('XvBStats greys the credited figures and flags the footer when the fetch is stale (#311)', () => {
    // Fresh (base fixture, xvb_stale false): the normal "Stats fetched" footer, no stale marks.
    const fresh = renderApp();
    assert.match(fresh, /Stats fetched from xmrvsbeast\.com \(Updated:/);
    assert.doesNotMatch(fresh, /Stale —/);
    assert.doesNotMatch(fresh, /Credited\) ⚠/);
    // Stale: credited labels get a ⚠, the footer flips to the stale warning, status-warn applied.
    const s = clone();
    s.hashrate.xvb_stale = true;
    const stale = renderApp({ state: s });
    assert.match(stale, /1h Avg \(Credited\) ⚠/);
    assert.match(stale, /24h Avg \(Credited\) ⚠/);
    assert.match(stale, /⚠ Stale — last successful fetch from xmrvsbeast\.com/);
    assert.match(stale, /status-warn/);
});

test('XvBStats lists recorded raffle wins, with a placeholder when there are none', () => {
    // The base fixture carries one recorded win → the wins log shows it, no placeholder.
    const withWin = renderApp();
    assert.match(withWin, /Raffle Wins/);
    assert.match(withWin, /won a donor_whale round, credited 4\.20 MH\/s/);
    assert.doesNotMatch(withWin, /No wins recorded yet/);
    // No wins → the muted placeholder pointing at the chart's gold-star marker.
    const s = clone();
    s.raffle_wins = [];
    const empty = renderApp({ state: s });
    assert.match(empty, /No wins recorded yet/);
    assert.doesNotMatch(empty, /won a donor_whale round/);
});

// --- Workers table ----------------------------------------------------------------------

test('WorkersTable renders headers and a row per worker with status classes', () => {
    const html = renderApp();
    for (const label of ['Worker', 'IP', 'Uptime', 'Accepted', 'Rejected']) {
        assert.match(html, new RegExp(`>${label}<`), `missing column: ${label}`);
    }
    assert.match(html, /rig-alpha/);
    assert.match(html, /rig-bravo/);
    assert.match(html, /status-ok/); // the online worker's row
    assert.match(html, /status-bad/); // the offline worker's row
    assert.match(html, /badge-ok">P2Pool/); // PoolBadge for a p2pool worker
});

test('WorkersTable marks the sorted column, visibly and via aria-sort (#656)', () => {
    // No sort chosen (server order): no column claims a direction.
    assert.doesNotMatch(renderApp(), /aria-sort/);
    const asc = renderApp({ ui: { ...UI, sortIndex: 0, sortAsc: true } });
    assert.match(asc, /<th[^>]*class="sorted"[^>]*aria-sort="ascending"[^>]*><button[^>]*>Worker<span class="sort-arrow"> ▲<\/span>/);
    const desc = renderApp({ ui: { ...UI, sortIndex: 0, sortAsc: false } });
    assert.match(desc, /aria-sort="descending"[^>]*><button[^>]*>Worker<span class="sort-arrow"> ▼<\/span>/);
});

test('WorkersTable sort headers are real buttons, so keyboard can sort (#671)', () => {
    // A native <button> is focusable and activates on Enter/Space, firing the same onClick
    // (onSort) path the mouse takes — keyboard operability rides on the element choice, so
    // the component-tier assertion is that every header's click target IS a native button.
    const html = renderApp();
    const btns = html.match(/<button type="button" class="th-sort-btn" title="Sort by /g) || [];
    assert.equal(btns.length, WORKER_COLUMNS.length);
    assert.match(html, /<th><button type="button" class="th-sort-btn" title="Sort by Worker">Worker</);
});

test('WorkersTable with no workers shows the connect hint instead of a bare table (#385)', () => {
    // The fixture's host_ip is "Unknown Host" — the hint must fall back to the docs placeholder.
    const s = clone();
    s.workers = [];
    const html = renderApp({ state: s });
    assert.match(html, /Workers Alive/);
    assert.match(html, /No workers connected yet/);
    assert.match(html, /YOUR_STACK_IP:3333/);
    assert.match(html, /docs\/workers\.md/); // links the workers guide
    assert.doesNotMatch(html, /workers-table/); // no empty table skeleton
    assert.doesNotMatch(html, /rig-alpha/);
});

test('WorkersTable connect hint uses the real host IP when known (#385)', () => {
    const s = clone();
    s.workers = [];
    s.host_ip = '192.168.1.10';
    const html = renderApp({ state: s });
    assert.match(html, /192\.168\.1\.10:3333/);
    assert.doesNotMatch(html, /Unknown Host:3333/);
    // A custom p2pool.stratum_port (#172) flows into the hint — the UI never lies about where
    // rigs must point.
    const custom = clone();
    custom.workers = [];
    custom.host_ip = '192.168.1.10';
    custom.stratum_port = 4444;
    assert.match(renderApp({ state: custom }), /192\.168\.1\.10:4444/);
    // A populated fleet — even all-offline — keeps the table, never the hint.
    const offline = clone();
    offline.workers = offline.workers.map((w) => ({ ...w, status: 'offline' }));
    assert.doesNotMatch(renderApp({ state: offline }), /No workers connected yet/);
});

test('ProxyTotals footer is hidden until the proxy reports data', () => {
    assert.doesNotMatch(renderApp(), /Proxy totals/); // fixture has has_data:false
    const s = clone();
    s.proxy_summary.has_data = true;
    s.proxy_summary.accepted = '1200';
    assert.match(renderApp({ state: s }), /Proxy totals/);
});

test('ProxyTotals reddens the rejected figure only when reject_level is high', () => {
    // The base fixture's workers are all clean, so nothing reaches the styled-rejects branch.
    const s = clone();
    Object.assign(s.proxy_summary, {
        has_data: true, accepted: '1200', rejected: '50', reject_pct: '4%',
        reject_level: 'high', invalid: '0', best: '123',
    });
    assert.match(renderApp({ state: s }), /status-bad">50/); // high -> rejected total is reddened
    s.proxy_summary.reject_level = 'ok';
    assert.doesNotMatch(renderApp({ state: s }), /status-bad">50/); // ok -> plain, not reddened
});

test('WorkersTable surfaces the per-rig api-unreadable and reject badges, and the pool badge variants', () => {
    // The single fixture pins both workers to pool=p2pool, api_ok=null, reject_flag=null, so these
    // three problem-rig signals — the whole point of the pool/api/rejected columns — never render.
    const s = clone();
    Object.assign(s.workers[0], { api_ok: false, adopted: true }); // adopted rig, dead feed
    s.workers[0].reject_flag = { text: '90% rejected', title: 'high reject rate' };
    s.workers[0].pool = 'xvb'; // purple XvB badge
    s.workers[1].pool = 'somethingelse'; // unrecognised -> Unknown (bad) badge
    const html = renderApp({ state: s });
    assert.match(html, /api ⚠/); // api_ok===false badge (only UI signal a rig's API is unreadable)
    assert.match(html, /90% rejected/); // per-row reject badge (how you spot a problem rig)
    assert.match(html, /badge-purple">XvB/);
    assert.match(html, /badge-bad">Unknown/);
});

test('WorkersTable renders the RigForge version badge + chips when present, nothing when absent (#235)', () => {
    // A plain-xmrig worker has no `rigforge` (the server sends null) -> no chips, no error.
    const plain = clone();
    plain.workers.forEach((w) => (w.rigforge = null));
    const plainHtml = renderApp({ state: plain });
    assert.doesNotMatch(plainHtml, /rf 1\.7\.0/);
    assert.doesNotMatch(plainHtml, /throttling/);

    // A RigForge worker carries the server-built {version, chips} view.
    const rf = clone();
    rf.workers[0].rigforge = {
        version: '1.7.0',
        miner_down: false,
        chips: [
            { text: 'throttling', variant: 'bad', title: 'hot' },
            { text: 'gov: performance', variant: 'ok', title: '' },
            { text: '142 W · 86.9 H/s·W', variant: 'outline', title: 'power' },
        ],
    };
    rf.workers[1].rigforge = null; // the other rig is plain xmrig
    const html = renderApp({ state: rf });
    assert.match(html, /rf 1\.7\.0/); // version badge
    assert.match(html, /badge-bad" title="hot">throttling/); // a bad chip
    assert.match(html, /gov: performance/);
    assert.match(html, /142 W · 86.9 H\/s·W/);
});

test('WorkersTable badges a rig running an older RigForge — and only that rig (#596)', () => {
    const s = clone();
    s.workers[0].rigforge_update = { available: true, latest: 'v1.11.2', url: 'https://h/v1.11.2' };
    s.workers[1].rigforge_update = null; // current / plain-xmrig rig -> no badge
    const html = renderApp({ state: s });
    assert.match(html, /rf v1\.11\.2 available/); // the accent callout renders
    assert.match(html, /A newer RigForge release is available: v1\.11\.2/); // tooltip
    assert.equal(html.match(/rf v1\.11\.2 available/g).length, 1); // exactly one rig badged

    const none = clone();
    none.workers.forEach((w) => (w.rigforge_update = null));
    assert.doesNotMatch(renderApp({ state: none }), /RigForge release is available/);
});

test('Tari status gates the ✔ on a live gRPC channel, never on active-but-dead (#278/#313)', () => {
    // The ✔ must mean the merge-mine channel is actually up. A dead channel that still reads "active"
    // must show status-warn and NO check — otherwise a TRANSIENT_FAILURE reads as healthy (#278/#313).
    const connected = clone();
    Object.assign(connected.tari, { connected: true, active: true, status: 'Merge mining' });
    const cHtml = renderApp({ state: connected });
    assert.match(cHtml, /status-ok">Merge mining/);
    assert.match(cHtml, /check-inline/); // connected -> the ✔ shows

    const deadButActive = clone();
    Object.assign(deadButActive.tari, { connected: false, active: true, status: 'Merge mining' });
    const dHtml = renderApp({ state: deadButActive });
    assert.match(dHtml, /status-warn">Merge mining/);
    assert.doesNotMatch(dHtml, /check-inline/); // active-but-dead -> NO ✔ (the invariant)
});

test('Sync gauge shows a ✔ for a done chain and a live percent while syncing', () => {
    const s = clone();
    s.syncing = true;
    s.sync.monero.state = 'syncing';
    s.sync.monero.percent = 42;
    assert.match(renderApp({ state: s }), /42%/); // syncing chain shows its percent
    s.sync.monero.state = 'done';
    assert.match(renderApp({ state: s }), /check-big/); // done chain shows the ✔, not a percent
});

// --- Component Health & Egress (#170) ---------------------------------------------------

test('ComponentHealth shows a Tor-only summary, the topology nodes, and the egress drawer', () => {
    const html = renderApp();
    assert.match(html, /Stack Topology & Egress/);
    assert.match(html, /🛡️/); // safe shield, not the warning triangle
    assert.match(html, /All egress via Tor/);
    // the StackTopology SVG renders its node labels...
    assert.match(html, /Mining rigs/);
    assert.match(html, /monerod/);
    // ...and the per-component egress drawer lists each component.
    assert.match(html, /All connections \(per component\)/);
    assert.match(html, /xmrig-proxy/);
});

test('StackTopology marks live routes with marching ants, never a dashed edge', () => {
    const html = renderApp();
    // The fixture carries tor-routed edges -> at least one ants-marked path...
    assert.match(html, /class="topo-edge-ants"/);
    // ...but never on an edge whose dash pattern is already spoken for (internal mesh /
    // firewall-blocked), where the animation would fight the static dashes.
    assert.doesNotMatch(html, /class="topo-edge-ants"[^>]*stroke-dasharray="[^"]/);
});

test('ComponentHealth flips to a warning summary when the posture leaks', () => {
    const s = clone();
    s.topology.summary.level = 'warn';
    s.topology.summary.label = '2 clearnet egress path(s) exposing your IP';
    assert.match(renderApp({ state: s }), /⚠️/);
    assert.match(renderApp({ state: s }), /exposing your IP/);
    assert.match(renderApp({ state: s }), /egress-summary c-bad/);
});

test('ComponentHealth still renders the panel but omits the drawer when egress is absent', () => {
    const s = clone();
    s.egress = null;
    const html = renderApp({ state: s });
    assert.match(html, /Stack Topology & Egress/); // the map still renders
    assert.doesNotMatch(html, /All connections \(per component\)/); // no drawer
});

// --- Sync mode --------------------------------------------------------------------------

test('syncing App renders the sync gauges instead of the dashboard', () => {
    const s = clone();
    s.syncing = true;
    const html = renderApp({ state: s });
    assert.match(html, /synchronizing with the network/);
    assert.match(html, /Monero Sync/);
    assert.match(html, /Tari Sync/);
    assert.doesNotMatch(html, /Workers Alive/);
});


// --- Worker Inspect (#185) ---------------------------------------------------------------

test('worker names are inspect buttons only when the control channel is on (#185)', () => {
    // Control off (base fixture): the name is plain text, no inspect affordance.
    const off = renderApp();
    assert.doesNotMatch(off, /worker-name-link/);
    // Control on: each worker name becomes an inspect button.
    const s = clone();
    s.control_enabled = true;
    const on = renderApp({ state: s });
    assert.match(on, /worker-name-link/);
    assert.match(on, />rig-alpha</);
});

test('WorkerInspect dialog renders for the selected worker (#185, native <dialog> since #518)', () => {
    const s = clone();
    s.control_enabled = true;
    // ui.inspectWorker drives the dialog; the render harness runs no effects (no showModal()),
    // so it's the pre-fetch loading state (the fetch itself is covered by the server tests).
    const html = renderApp({ state: s, ui: { ...UI, inspectWorker: 'rig-alpha' } });
    assert.match(html, /<dialog class="worker-inspect/);
    assert.match(html, /Worker · rig-alpha/);
    assert.match(html, /Loading/);
});

test('no WorkerInspect dialog when none is selected (#185)', () => {
    const s = clone();
    s.control_enabled = true;
    assert.doesNotMatch(renderApp({ state: s }), /<dialog class="worker-inspect/);
});

test('StatsTable renders the enriched feed as a label/value table, colouring warn/bad values (#507)', () => {
    // The detail view swaps the compact list's badge row for a table: label cell + value cell,
    // driven by the server-built {label, value, variant, title} stats. warn/bad colour the value.
    const html = render(StatsTable, {
        stats: [
            { label: 'Governor', value: 'powersave', variant: 'warn', title: 'CPU governor' },
            { label: 'HugePages', value: '1280', variant: 'outline', title: '' },
            { label: 'CPU', value: 'throttling', variant: 'bad', title: 'hot' },
        ],
    });
    assert.match(html, /class="worker-history"/); // reuses the existing detail-table styling
    assert.doesNotMatch(html, /badge-row/); // NOT the compact list's badge row
    assert.match(html, /Governor<\/td>/);
    assert.match(html, /class="stat-value status-warn">powersave/); // warn colours its value
    assert.match(html, /class="stat-value status-bad">throttling/); // bad colours its value
    assert.match(html, /<td class="stat-value">1280/); // outline metric stays plain
});

test('StatsTable renders nothing when a rig reports no metrics (#507)', () => {
    assert.equal(render(StatsTable, { stats: [] }), '');
    assert.equal(render(StatsTable, { stats: undefined }), '');
});

// --- ExpectedVsActualCard (#808) -------------------------------------------------------

test('ExpectedVsActualCard renders in BOTH views and yields to nothing when empty (#808)', () => {
    // The base fixture has XvB on (one recorded win) → the card renders, Simple and Advanced.
    assert.match(renderApp({ ui: { ...UI, view: 'simple' } }), /card-expected-vs-actual/);
    assert.match(renderApp({ ui: { ...UI, view: 'advanced' } }), /card-expected-vs-actual/);
    // Nothing to compare on any stream → the card yields entirely (no empty shell).
    const s = clone();
    s.earnings_summary = {
        xmr: { available: false, enabled: false },
        tari: { available: false, enabled: false },
        xvb: { enabled: false },
    };
    assert.doesNotMatch(renderApp({ state: s }), /card-expected-vs-actual/);
    // A stale payload without the key (mid-upgrade poll) must not take the App down.
    delete s.earnings_summary;
    assert.match(renderApp({ state: s }), /Overview/);
});

test('ExpectedVsActualCard compares combined Monero+XvB with a percent and partial marks (#817)', () => {
    const s = clone();
    s.earnings_summary.xmr = {
        available: true, expected_30d: 0.0123, includes_xvb: true, enabled: true,
        actual_30d: 0.0101, partial: true, pct: 82,
    };
    const out = renderApp({ state: s });
    assert.match(out, /Monero \+ XvB \(30d\)/);    // combined label when the estimate is folded
    assert.match(out, /0\.012300 XMR/);            // expected, formatXmr precision
    assert.match(out, /0\.010100 XMR \(82%\) \*/); // actual + pct + the partial asterisk
    assert.match(out, /covers only the payout history on record/); // the footnote appears
    // The card never pans (#817): wrapping table, and the scroll wrapper must stay gone —
    // scoped to this card's own markup, since other cards legitimately keep est-scroll.
    assert.match(out, /eva-table/);
    assert.doesNotMatch(cardSlice(out, 'card-expected-vs-actual'), /est-scroll/);
    // Without a fresh published estimate the label honestly drops the "+ XvB".
    s.earnings_summary.xmr.includes_xvb = false;
    assert.match(renderApp({ state: s }), /Monero \(30d\)/);
});

test('ExpectedVsActualCard drops the percent when the server withholds it, tooltip explains (#992)', () => {
    // A near-zero expectation makes the server withhold pct (xvb_views.py caps at 999%) — the
    // actual figure stands alone and the row tooltip owns the missing percent.
    const s = clone();
    s.earnings_summary.xmr = {
        available: true, expected_30d: 1e-6, includes_xvb: false, enabled: true,
        actual_30d: 0.28, partial: false, pct: null,
        xvb_realization_pct: null, xvb_wins_measured: null,
    };
    const out = renderApp({ state: s });
    assert.match(out, /0\.280000 XMR/);
    assert.doesNotMatch(out, /0\.280000 XMR \(/); // no percent appended
    assert.match(out, /No percentage shown: the expected figure is near zero/);
    // A present percent keeps the old rendering and drops the explanation.
    s.earnings_summary.xmr.pct = 82;
    const withPct = renderApp({ state: s });
    assert.match(withPct, /\(82%\)/);
    assert.doesNotMatch(withPct, /No percentage shown/);
});

test('ExpectedVsActualCard shows the config key when confirmation is off, never a zero (#808)', () => {
    const s = clone();
    s.earnings_summary.xmr = { available: true, expected_30d: 0.0123, includes_xvb: false,
        enabled: false, actual_30d: null, partial: false, pct: null };
    s.earnings_summary.tari = { available: true, expected_blocks_30d: 0.0052, enabled: false,
        blocks_30d: null, xtm_30d: null, partial: false };
    const out = renderApp({ state: s });
    assert.match(out, /set monero\.view_key/);
    assert.match(out, /set tari\.view_key/);
    assert.doesNotMatch(out, /0\.000000 XMR \(/); // no zero-actual masquerading as a figure
    // Tari expectation keeps two significant digits — a fraction of a block must never read 0.0.
    assert.match(out, /≈ 0\.0052 blocks/);
});

test('ExpectedVsActualCard counts Tari blocks and windows XvB wins (#808)', () => {
    const s = clone();
    s.earnings_summary.tari = { available: true, expected_blocks_30d: 0.41, enabled: true,
        blocks_30d: 1, xtm_30d: 12345.0, partial: false };
    s.earnings_summary.xvb = { enabled: true, wins_30d: 2, last_win_ts: 1735689000 };
    const out = renderApp({ state: s });
    assert.match(out, /≈ 0\.41 blocks/);
    assert.match(out, /1 block · 12345\.0000 XTM/); // singular block, XTM alongside
    assert.match(out, /2 wins · last /);
    // Since #817 the wins row carries NO XMR figure — its value lives in the combined row.
    assert.doesNotMatch(out, /XMR\/day/);
    // XvB off → the row disappears (no invented raffle framing on a non-XvB box).
    s.earnings_summary.xvb = { enabled: false, wins_30d: 0, last_win_ts: 0 };
    assert.doesNotMatch(renderApp({ state: s }), /XvB wins \(30d\)/);
});

test('disabled XvB de-emphasizes: no stats card, no header split line, no hero raffle slots', () => {
    // One mention — the mode badge — is enough on a non-donating box. The stats card, the
    // header's routed-split line, and the two hero raffle KPIs all stand down with it.
    const s = clone();
    assert.match(renderApp({ state: s }), /XvB Donation Stats/); // fixture has XvB on
    assert.match(renderApp({ state: s }), /XvB \(routed\):/);
    s.xvb_calc = { enabled: false };
    const off = renderApp({ state: s });
    assert.doesNotMatch(off, /XvB Donation Stats/);
    assert.doesNotMatch(off, /XvB \(routed\):/);
    assert.doesNotMatch(off, /Raffle Eligible/);
    assert.doesNotMatch(off, /XvB Tier</);
});

test('raffle wins render inside the scroll-capped list wrapper', () => {
    // The wins log is what made the XvB card the tallest in its grid row (whitespace under every
    // neighbour) — the wrapper carries the max-height cap.
    assert.match(renderApp({ state: clone() }), /class="raffle-wins-list"/);
});

test('ExpectedVsActualCard forecasts XvB wins from the winners feed, dash when unmeasured (#866)', () => {
    const s = clone();
    s.earnings_summary.xvb = {
        enabled: true, wins_30d: 13, last_win_ts: 1735689000, expected_wins_30d: 25.2,
    };
    assert.match(renderApp({ state: s }), /≈ 25 wins/); // two significant digits
    // No aggregate (missing/stale) → the dash, never a guess.
    s.earnings_summary.xvb.expected_wins_30d = null;
    assert.doesNotMatch(renderApp({ state: s }), /≈ .* wins<\/td>/);
});

test('ExpectedVsActualCard tooltip owns the tempered vs face-value XvB share (#866)', () => {
    const s = clone();
    s.earnings_summary.xmr.includes_xvb = true;
    s.earnings_summary.xmr.xvb_realization_pct = 19;
    s.earnings_summary.xmr.xvb_wins_measured = 15;
    assert.match(renderApp({ state: s }), /19% of XvB(?:'|&#39;)s published face value/);
    s.earnings_summary.xmr.xvb_realization_pct = null;
    s.earnings_summary.xmr.xvb_wins_measured = null;
    assert.match(renderApp({ state: s }), /face-value estimate — an upper bound/);
});
