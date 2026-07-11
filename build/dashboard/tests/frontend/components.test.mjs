// Render smoke tests for the dashboard's Preact components (mining_dashboard/web/static/components.mjs).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
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
import { render } from './helpers/render.mjs';

const BASE = JSON.parse(readFileSync(new URL('./fixtures/state.json', import.meta.url)));
const clone = () => structuredClone(BASE);

// Default client UI state; the handlers are no-ops (the renderer never invokes them).
const UI = {
    view: 'advanced', range: 'all', window: null, series: {}, avg: '10m',
    theme: 'auto', sortIndex: null, sortAsc: true,
};
const noop = () => {};
const HANDLERS = {
    onRange: noop, onSort: noop, onView: noop, onTheme: noop,
    onZoom: noop, onResetZoom: noop, onToggleSeries: noop, onAvgWindow: noop,
    onDismissHint: noop,
};

function renderApp({ state = BASE, connected = true, ui = UI } = {}) {
    return render(App, { state, connected, ui, ...HANDLERS });
}

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
});

test('operational App renders the remaining advanced cards', () => {
    const html = renderApp();
    assert.match(html, /Global P2Pool Stats/);
    assert.match(html, /XMR Network/);
    assert.match(html, /Tari Merge-Mining/);
    assert.match(html, /P2Pool Earnings \(estimated\)/);
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
    assert.match(up, /XTM \/ day \(avg\)/); // per-day kept, but labelled an average
    assert.match(up, /16\.1000 XTM/);       // the long-run average figure still shown
    // Merge-mining inactive/syncing: the rows stay, the figures degrade to "—".
    const off = clone();
    off.earnings.available = true;
    off.earnings.tari_available = false;
    const down = renderApp({ state: off });
    assert.match(down, /Est\. Time to Tari Block/);
    assert.match(down, /—/);
    assert.doesNotMatch(down, /NaN/);
});

test('EarningsCard renders the XvB tier (raffle) block when XvB is on, hides it when off (#118)', () => {
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
    // XvB disabled → the whole block disappears; the XMR calculator stays.
    s.xvb_calc = { enabled: false };
    const off = renderApp({ state: s });
    assert.doesNotMatch(off, /XvB Tier \(raffle\)/);
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
    // The Monero panel carries the XMR figures, the Tari panel the solo time-to-block, the XvB
    // panel the tier block — all present in the DOM (inactive ones just hidden).
    assert.match(html, /XMR \/ day/);
    assert.match(html, /Est\. Time to Tari Block/);
    assert.match(html, /XvB Tier \(raffle\)/);
});

test('EarningsCard drops the XvB tab entirely when XvB is disabled (#118)', () => {
    const s = clone();
    s.earnings.available = true;
    s.xvb_calc = { enabled: false };
    const html = renderApp({ state: s });
    assert.match(html, /id="etab-monero"/);
    assert.match(html, /id="etab-tari"/);
    assert.doesNotMatch(html, /id="etab-xvb"/); // no XvB tab
    assert.doesNotMatch(html, /id="epanel-xvb"/);
    assert.doesNotMatch(html, /XvB Tier \(raffle\)/);
});

test('XvB comparison dropdown shows Expected/Cost/Net per tier, degrades on a stale estimate (#118)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7; // XMR per H/s per day → cost = threshold × this × 365
    // A Whale-capable what-if default (200k × 0.85 ≥ 100k threshold) so the target tier's Net shows;
    // the unsustainable path is asserted separately below.
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true,
        max_fraction: 0.85,
        estimates_available: true,
        estimates_stale: false,
        current_tier: 'None',
        target_tier: 'Whale (100.00 kH/s+)',
        target_threshold: 100000,
        sustainable: true,
        note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null,
        tiers: [
            { name: 'Donor (1.00 kH/s+)', threshold: 1000, expected_reward_year: 0.06 },
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81 },
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17 },
            { name: 'Mega (1.00 MH/s+)', threshold: 1000000, expected_reward_year: 56.9 },
        ],
    };
    const up = renderApp({ state: base });
    // The dropdown renders all four tiers as options.
    assert.match(up, /id="xvb-tier-select"/);
    for (const name of ['Donor', 'Vip', 'Whale', 'Mega']) {
        assert.match(up, new RegExp(`<option[^>]*>${name}`), `missing tier option: ${name}`);
    }
    // Default selection = the target tier (Whale): Expected is XvB's figure, Cost = 100000 × 1e-7 ×
    // 365 = 3.65 XMR/yr, Net = 6.17 − 3.65 = 2.52.
    assert.match(up, /Expected \(XvB\)/);
    assert.match(up, /6\.1700 XMR/);   // expected
    assert.match(up, /3\.6500 XMR/);   // cost
    assert.match(up, /2\.5200 XMR/);   // net
    assert.match(up, /From XvB's published per-tier estimate/);
    assert.doesNotMatch(up, /estimate unavailable/);

    // Stale/unavailable estimate: the note replaces the Expected number, cost still shows.
    const stale = clone();
    stale.earnings.available = true;
    stale.earnings.coeff_day = 1e-7;
    stale.xvb_calc = {
        ...base.xvb_calc,
        estimates_available: false,
        estimates_stale: true,
        tiers: base.xvb_calc.tiers.map((t) => ({ ...t, expected_reward_year: null })),
    };
    const sHtml = renderApp({ state: stale });
    assert.match(sHtml, /estimate unavailable/);
    assert.match(sHtml, /Expected reward estimate unavailable/);
    assert.match(sHtml, /3\.6500 XMR/); // cost still stands

    // Unsustainable tier: at the fixture's small default hashrate (~8 kH/s), the Whale target
    // can't be held (8k × 0.85 < 100k) — the comparison must SAY so and withhold the Net rather
    // than imply an unreachable +2.52 XMR/yr payout.
    const small = clone();
    small.earnings.available = true;
    small.earnings.coeff_day = 1e-7;
    small.xvb_calc = { ...base.xvb_calc };
    const uHtml = renderApp({ state: small });
    assert.match(uHtml, /Not sustainable at your hashrate/);
    assert.match(uHtml, /6\.1700 XMR/); // XvB's expected figure still shown (it's their number)
    assert.doesNotMatch(uHtml, /2\.5200 XMR/); // but no reachable-looking Net
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
    s.workers[0].api_ok = false; // xmrig API unreadable -> "api ⚠"
    s.workers[0].reject_flag = { text: '90% rejected', title: 'high reject rate' };
    s.workers[0].pool = 'xvb'; // purple XvB badge
    s.workers[1].pool = 'somethingelse'; // unrecognised -> Unknown (bad) badge
    const html = renderApp({ state: s });
    assert.match(html, /api ⚠/); // api_ok===false badge (only UI signal a rig's API is unreadable)
    assert.match(html, /90% rejected/); // per-row reject badge (how you spot a problem rig)
    assert.match(html, /badge-purple">XvB/);
    assert.match(html, /badge-bad">Unknown/);
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
