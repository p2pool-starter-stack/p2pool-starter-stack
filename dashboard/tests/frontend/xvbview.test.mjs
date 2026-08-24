// Unit + render tests for the XvB (XMRvsBeast raffle) domain: the pure decision logic
// (mining_dashboard/web/static/xvblogic.mjs — computeXvbTier, xvbDecisionRows) and its Preact
// view (mining_dashboard/web/static/xvbview.mjs — XvbTierBlock, exercised here through the full
// App root exactly as components.test.mjs drives every other card). Split out of logic.test.mjs
// and components.test.mjs (#1316) to keep those files under their file-budget ceilings.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { computeXvbTier, xvbDecisionRows } from '../../mining_dashboard/web/static/xvblogic.mjs';
import { formatXmr } from '../../mining_dashboard/web/static/logic.mjs';
import { App } from '../../mining_dashboard/web/static/components.mjs';
import { render } from './helpers/render.mjs';

// --- computeXvbTier (#118) — transcription of resolve_target_threshold's auto rule ------

const XVB_CALC = {
    enabled: true,
    max_fraction: 0.85,
    tiers: [
        { name: 'Donor (1.00 kH/s+)', threshold: 1_000 },
        { name: 'Vip (10.00 kH/s+)', threshold: 10_000 },
        { name: 'Whale (100.00 kH/s+)', threshold: 100_000 },
        { name: 'Mega (1.00 MH/s+)', threshold: 1_000_000 },
    ],
};

test('computeXvbTier: pinned against the Python resolve_target_threshold auto case', () => {
    // Same inputs as tests/helper/test_utils.py::test_auto_picks_highest_sustainable:
    // 15,000 H/s × 0.85 = 12,750 sustains exactly the 10k (Vip) tier — the transcription
    // cross-check that keeps the JS and helper/utils.py rules from drifting silently.
    const t = computeXvbTier(15_000, XVB_CALC);
    assert.equal(t.threshold, 10_000);
    assert.equal(t.cost, 10_000);    // cost = the threshold itself (continuous donation)
    assert.match(t.tier, /Vip/);
});

test('computeXvbTier: below the lowest tier → null', () => {
    assert.equal(computeXvbTier(100, XVB_CALC), null);  // 100 × 0.85 = 85 < 1,000
});

test('computeXvbTier: exactly threshold / max_fraction clears the tier (boundary)', () => {
    assert.equal(computeXvbTier(10_000 / 0.85, XVB_CALC).threshold, 10_000);
});

test('computeXvbTier: between tiers picks the lower one', () => {
    // 60,000 × 0.85 = 51,000 — clears 10k, not 100k.
    assert.equal(computeXvbTier(60_000, XVB_CALC).threshold, 10_000);
});

test('computeXvbTier: null when calc missing, empty tiers, or bad hashrate', () => {
    assert.equal(computeXvbTier(15_000, null), null);
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, tiers: [] }), null);
    assert.equal(computeXvbTier(0, XVB_CALC), null);
    assert.equal(computeXvbTier(null, XVB_CALC), null);
});

test('computeXvbTier: still computes with XvB disabled — the what-if is the decision aid (#938)', () => {
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, enabled: false }).threshold, 10_000);
});

// --- xvbDecisionRows (#872) — the per-tier decision table's pure math -------------------

const _CALC = {
    enabled: true, max_fraction: 0.85, realization_pct: null, realization_wins: null,
    tiers: [
        { name: 'Vip (10.00 kH/s+)', threshold: 10_000, expected_reward_year: 0.81,
          realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.27, 0.81 * 0.38],
          win_odds_day: 0.12, players_avg: 31.4 },
        { name: 'Whale (100.00 kH/s+)', threshold: 100_000, expected_reward_year: 6.17,
          realized_reward_year: null, assumed_reward_year_range: [6.17 * 0.27, 6.17 * 0.38],
          win_odds_day: 0.84, players_avg: 8.2 },
    ],
};

test('xvbDecisionRows: study band prices the measured delivery into the net verdict', () => {
    const rows = xvbDecisionRows(_CALC, 1e-7, 200_000); // whale cost 3.65, vip cost 0.365
    const whale = rows[1];
    assert.equal(whale.mode, 'study');
    assert.ok(Math.abs(whale.cost - 3.65) < 1e-9);
    assert.ok(Math.abs(whale.net[0] - (6.17 * 0.27 - 3.65)) < 1e-9);
    assert.ok(Math.abs(whale.net[1] - (6.17 * 0.38 - 3.65)) < 1e-9);
    assert.equal(whale.cls, 'status-bad'); // even the optimistic end loses
    assert.equal(whale.sustainable, true);
    assert.ok(Math.abs(whale.oddsPer30d - 25.2) < 1e-9);
});

test('xvbDecisionRows: a wallet\'s own measured wins supersede the study band', () => {
    const calc = structuredClone(_CALC);
    calc.realization_pct = 32; calc.realization_wins = 9;
    calc.tiers[1].realized_reward_year = 6.17 * 0.32;
    const whale = xvbDecisionRows(calc, 1e-7, 200_000)[1];
    assert.equal(whale.mode, 'yours');
    assert.ok(Math.abs(whale.net[0] - (6.17 * 0.32 - 3.65)) < 1e-9);
    assert.equal(whale.net[0], whale.net[1]); // a point, not a band
});

test('xvbDecisionRows: unsustainable tiers are flagged; face-only falls back labeled', () => {
    const rows = xvbDecisionRows(_CALC, 1e-7, 20_000); // whale needs 100k > 20k x 0.85
    assert.equal(rows[1].sustainable, false);
    assert.equal(rows[0].sustainable, true);
    // no band and no measured -> face-value mode, net still computed (component labels it)
    const calc = structuredClone(_CALC);
    calc.tiers[1].assumed_reward_year_range = null;
    const whale = xvbDecisionRows(calc, 1e-7, 200_000)[1];
    assert.equal(whale.mode, 'face');
    assert.ok(Math.abs(whale.net[0] - (6.17 - 3.65)) < 1e-9);
});

test('xvbDecisionRows: no coeff (network stats down) -> no cost, no net, never a guess', () => {
    const whale = xvbDecisionRows(_CALC, 0, 200_000)[1];
    assert.equal(whale.cost, null);
    assert.equal(whale.net, null);
    assert.equal(whale.mode, 'none');
    assert.equal(xvbDecisionRows(null, 1e-7, 200_000).length, 0);
});

test('xvbDecisionRows: XvB disabled still prices the table (#938)', () => {
    // The rows are the enable/don't-enable comparison, so the flag doesn't empty them —
    // a disabled payload with tiers prices identically to an enabled one.
    const rows = xvbDecisionRows({ ..._CALC, enabled: false }, 1e-7, 200_000);
    assert.equal(rows.length, 2);
    assert.ok(Math.abs(rows[1].cost - 3.65) < 1e-9);
});

// --- coinDp / net verdict (#1316) ---------------------------------------------------------

test('formatXmr: decimal places follow MAGNITUDE, so a loss is not longer than a gain (#1316)', () => {
    // coinDp compared the signed value, so every negative failed both `>= ` tests and fell
    // through to 8 dp: the Net column's losses carried four trailing zeros that said nothing,
    // and were always the widest string in their row.
    assert.equal(formatXmr(21.2706), '21.2706 XMR');
    assert.equal(formatXmr(-21.2706), '-21.2706 XMR');
    assert.equal(formatXmr(-1.3802), '-1.3802 XMR');
    assert.equal(formatXmr(-0.01858), '-0.018580 XMR');
    // A genuinely tiny magnitude still earns 8 dp — the fix is about sign, not about rounding
    // small figures away.
    assert.equal(formatXmr(-0.0000912), '-0.00009120 XMR');
    assert.equal(formatXmr(0.0000912), '0.00009120 XMR');
    // Mirror-image precision: a gain and the same-sized loss are the same length.
    assert.equal(formatXmr(-1.5).length, formatXmr(1.5).length + 1);
});

test('xvbDecisionRows: a band straddling zero is a WARN verdict, not uncoloured text (#1316)', () => {
    const calc = structuredClone(_CALC);
    // Vip: cost = 10000 x 1e-9 x 365 = 0.00365; band [0.003, 0.005] straddles it.
    calc.tiers[0].assumed_reward_year_range = [0.003, 0.005];
    const vip = xvbDecisionRows(calc, 1e-9, 200_000)[0];
    assert.ok(vip.net[0] < 0 && vip.net[1] > 0, 'band must straddle zero for this test to mean anything');
    assert.equal(vip.cls, 'status-warn');
    // The other two verdicts keep their existing meaning.
    calc.tiers[0].assumed_reward_year_range = [0.01, 0.02];
    assert.equal(xvbDecisionRows(calc, 1e-9, 200_000)[0].cls, 'status-ok');
    calc.tiers[0].assumed_reward_year_range = [0.0001, 0.0002];
    assert.equal(xvbDecisionRows(calc, 1e-9, 200_000)[0].cls, 'status-bad');
});

test('xvbDecisionRows: the face-value net is computed in its own right, not only as a fallback (#1316)', () => {
    // Study mode: `net` prices the study band, `netFace` prices XvB's published figure. The
    // reader had to subtract the Cost and XvB-says columns by eye to get this second number.
    const whale = xvbDecisionRows(_CALC, 1e-7, 200_000)[1]; // cost 3.65, face 6.17
    assert.equal(whale.mode, 'study');
    assert.ok(Math.abs(whale.netFace[0] - (6.17 - 3.65)) < 1e-9);
    assert.equal(whale.netFace[0], whale.netFace[1]); // a point, not a band
    assert.equal(whale.clsFace, 'status-ok'); // XvB's own figure profits...
    assert.equal(whale.cls, 'status-bad'); // ...while the measured study band does not
    // No cost (network stats down) means no face net either — never a guess.
    assert.equal(xvbDecisionRows(_CALC, 0, 200_000)[1].netFace, null);
    assert.equal(xvbDecisionRows(_CALC, 0, 200_000)[1].clsFace, '');
});

// --- XvbTierBlock / XvbDecisionTable (rendered through the full App root) ----------------

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
    onDismissHint: noop, onInspect: noop, onCloseInspect: noop,
};

function renderApp({ state = BASE, connected = true, ui = UI } = {}) {
    return render(App, { state, connected, ui, ...HANDLERS });
}

test('XvB decision table: all tiers at once, study column, coloured net verdict (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7;
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'None', target_tier: 'Whale (100.00 kH/s+)', target_threshold: 100000,
        sustainable: true, note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null, realization_pct: null, realization_wins: null,
        tiers: [
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.27, 0.81 * 0.38],
              win_odds_day: 0.12, players_avg: 31.4 },
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: null, assumed_reward_year_range: [6.17 * 0.27, 6.17 * 0.38],
              win_odds_day: 0.84, players_avg: 8.2 },
            { name: 'Mega (1.00 MH/s+)', threshold: 1000000, expected_reward_year: 56.9,
              realized_reward_year: null, assumed_reward_year_range: [56.9 * 0.27, 56.9 * 0.38],
              win_odds_day: 9.4, players_avg: 1.0 },
        ],
    };
    const up = renderApp({ state: base });
    // One block per tier, no dropdown, every tier carrying odds, both estimates and a verdict.
    assert.match(up, /id="xvb-decision-tiers"/);
    assert.doesNotMatch(up, /id="xvb-tier-select"/);
    assert.match(up, /XvB says/);
    assert.match(up, /Study est\./);
    assert.match(up, /winners receiving 33% of face/);
    // Whale: cost 3.65; study band 1.6659…2.3446 collapses to its midpoint 2.0053, and the net
    // band (negative at both ends -> red) to -1.6448. Four dp, not eight: the negative no longer
    // falls through coinDp's magnitude test (#1316).
    assert.match(up, /2\.0053 XMR/);
    assert.match(up, /-1\.6447 XMR/);
    assert.doesNotMatch(up, /-1\.64470000/); // the old 8-dp negative
    // The band the midpoint came from is not lost — it moves into the cell's tooltip.
    assert.match(up, /Range: 1\.6659 XMR … 2\.3446 XMR/);
    // Both nets are named and answerable without subtracting two figures by eye.
    assert.match(up, /Net \(XvB says\)/);
    assert.match(up, /Net \(study\)/);
    // Mega is unsustainable at 200k×0.85: flagged, net withheld.
    assert.match(up, /Mega \(1\.00 MH\/s\+\) ⚠/);
    // Draw odds render per row.
    assert.match(up, /≈ 25 wins · 8\.2 players/);
    // XvB's face value stays visible as XvB's own number.
    assert.match(up, /6\.1700 XMR/);
});

test('XvB decision table: local measured wins supersede the study column (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-7;
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'Whale (100.00 kH/s+)', target_tier: 'Whale (100.00 kH/s+)',
        target_threshold: 100000, sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: 32, realization_wins: 9,
        tiers: [
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: 6.17 * 0.32, assumed_reward_year_range: null,
              win_odds_day: 0.84, players_avg: 8.2 },
        ],
    };
    const up = renderApp({ state: base });
    assert.match(up, /Yours \(32% × 9 wins\)/);
    assert.match(up, /1\.9744[0-9]* XMR/); // 6.17 × 0.32
    assert.match(up, /-1\.6756[0-9]* XMR/); // net = 1.9744 − 3.65, single point
});

test('XvB decision table: verdict colours cover green and zero-spanning bands, stale degrades honestly (#872)', () => {
    const base = clone();
    base.earnings.available = true;
    base.earnings.coeff_day = 1e-9; // tiny cost so a positive band is constructible
    base.earnings.p2pool_hr = 200000;
    base.earnings.p2pool_hr_str = '200.00 kH/s';
    base.xvb_calc = {
        enabled: true, max_fraction: 0.85, estimates_available: true, estimates_stale: false,
        current_tier: 'None', target_tier: 'Vip (10.00 kH/s+)', target_threshold: 10000,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            // cost = 10000 × 1e-9 × 365 = 0.00365; band well above -> green at both ends
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.22, 0.31],
              win_odds_day: 0.12, players_avg: 31.4 },
            // band straddles cost -> neutral (no class)
            { name: 'Whale (100.00 kH/s+)', threshold: 100000, expected_reward_year: 6.17,
              realized_reward_year: null, assumed_reward_year_range: [0.03, 0.05],
              win_odds_day: 0.84, players_avg: 8.2 },
        ],
    };
    const up = renderApp({ state: base });
    // Green: even the pessimistic end profits. Band [0.21635, 0.30635] -> midpoint 0.261350.
    assert.match(up, /class="status-ok">0\.261350 XMR/);
    // Zero-spanning band [-0.0065, 0.0135] -> midpoint 0.003500, and an explicit WARN class.
    // It used to render as plain uncoloured text, indistinguishable from a cell carrying no
    // verdict at all (#1316); "could go either way" is a verdict and now says so.
    assert.match(up, /class="status-warn">0\.003500 XMR/);
    assert.doesNotMatch(up, /class="">0\.003500 XMR/);
    // Stale estimates: costs still render, estimate/net columns dash, footer says costs only.
    const stale = clone();
    stale.earnings.available = true;
    stale.earnings.coeff_day = 1e-7;
    stale.earnings.p2pool_hr = 200000;
    stale.xvb_calc = { ...base.xvb_calc, estimates_available: false, estimates_stale: true,
        tiers: base.xvb_calc.tiers.map((t) => ({ ...t, expected_reward_year: null,
            assumed_reward_year_range: null, realized_reward_year: null })) };
    const sh = renderApp({ state: stale });
    assert.match(sh, /tier costs only/);
    assert.match(sh, /0\.365\d* XMR/); // vip cost at 1e-7
});

test('XvB decision table: the vendored-fallback reward columns render values and say so, not the bare "tier costs only" footer (#1214)', () => {
    // #1214: with XvB disabled and never enabled (no live cache), the server fills the reward
    // columns from its published-table fallback and labels it estimates_source: 'published'
    // plus a date. The table must show real figures (not dashes) and the footer must say the
    // numbers are the last-published table, not a live fetch — never the old bare "tier costs
    // only" wording, which reads as "we have no idea" when the real answer is available.
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-9;
    s.earnings.p2pool_hr = 200000;
    // expected_reward_year/assumed_reward_year_range mirror what build_xvb_calc's corrected
    // fallback (views.XVB_PUBLISHED_REWARD_FALLBACK["donor_vip"] = 0.81, the archived file's
    // PER-PLAYER row, not the much larger pool-total row) would actually emit for a disabled box.
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85, estimates_available: false, estimates_stale: false,
        estimates_source: 'published', estimates_published_date: '2026-08-10',
        current_tier: 'Disabled', target_tier: 'Disabled', target_threshold: 10000,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            { name: 'Vip (10.00 kH/s+)', threshold: 10000, expected_reward_year: 0.81,
              realized_reward_year: null, assumed_reward_year_range: [0.81 * 0.28, 0.81 * 0.39],
              win_odds_day: null, players_avg: null },
        ],
    };
    const up = renderApp({ state: s });
    // XvB says and Study est. are no longer dashed.
    assert.match(up, /0\.810000 XMR/); // "XvB says", face value straight from the fallback
    // Study est. = fallback face × the SAME prior, shown as the band's midpoint with the band
    // itself kept in the tooltip (#1316).
    assert.match(up, /0\.271350 XMR/);
    assert.match(up, /Range: 0\.226800 XMR … 0\.315900 XMR/);
    assert.doesNotMatch(up, /tier costs only/);
    assert.match(up, /last published table \(2026-08-10\)/);
    // Odds have no such fallback — same root cause, still honestly empty (#1214).
    assert.match(up, /Odds \/ 30d —/);
});

test('XvB decision block: in the operator\'s render state (XvB OFF) no figure is a sideways-panning range (#1316)', () => {
    // The state this issue was reported from, and the one a previous layout fix was NOT measured
    // in: XvB disabled, so build_xvb_calc falls back to the vendored published table, the odds
    // feed has nothing, and realization is never computed. Every tier priced, nothing live.
    const PRIOR = [0.28, 0.39];
    const FALLBACK = { donor: 0.064, donor_vip: 0.81, donor_whale: 4.67, donor_mega: 54.54 };
    const s = clone();
    s.earnings.available = true;
    s.earnings.coeff_day = 1e-7;
    s.earnings.p2pool_hr = 200000;
    s.xvb_calc = {
        enabled: false, max_fraction: 0.85, estimates_available: false, estimates_stale: false,
        estimates_source: 'published', estimates_published_date: '2026-08-10',
        current_tier: 'Disabled', target_tier: 'Disabled', target_threshold: 0,
        sustainable: true, note: 'raffle status', mode_note: null,
        realization_pct: null, realization_wins: null,
        tiers: [
            ['Donor (1.00 kH/s+)', 1000, 'donor'], ['Vip (10.00 kH/s+)', 10000, 'donor_vip'],
            ['Whale (100.00 kH/s+)', 100000, 'donor_whale'], ['Mega (1.00 MH/s+)', 1000000, 'donor_mega'],
        ].map(([name, threshold, key]) => ({
            name, threshold, expected_reward_year: FALLBACK[key], realized_reward_year: null,
            assumed_reward_year_range: [FALLBACK[key] * PRIOR[0], FALLBACK[key] * PRIOR[1]],
            win_odds_day: null, players_avg: null,
        })),
    };
    const up = renderApp({ state: s });
    // Bound the slice to the decision block itself — the page has other cards with real tables.
    const from = up.indexOf('id="xvb-decision-tiers"');
    assert.ok(from > 0, 'the decision block must render with XvB off — it IS the enable/don\'t decision');
    const block = up.slice(from, up.indexOf('Reward figures are', from));
    assert.ok(block.length, 'block must end at the source footer');

    // Visible text only: tag-stripping also drops the title attributes the bands moved into.
    const visible = block.replace(/<[^>]*>/g, ' ');
    assert.doesNotMatch(visible, /…/, 'no visible figure may still be a low … high range');
    // The bands are preserved, just not at the cost of the card's width.
    assert.match(block, /title="[^"]*Range: [^"]*…[^"]*"/);

    // All four tiers, each with both named nets, and no panning table wrapper.
    for (const tier of ['Donor', 'Vip', 'Whale', 'Mega']) assert.ok(visible.includes(tier), tier);
    assert.equal(block.match(/Net \(XvB says\)/g).length, 4);
    assert.equal(block.match(/Net \(study\)/g).length, 4);
    assert.doesNotMatch(block, /table-scroll/);
    assert.doesNotMatch(block, /<table/);

    // Odds have no fallback while XvB is off, so they stay honestly empty — once per tier.
    assert.equal(block.match(/Odds \/ 30d —/g).length, 4);

    // Every visible XMR figure is a single number, and none of them is an 8-dp negative.
    const figures = visible.match(/-?\d+\.\d+ XMR/g) || [];
    assert.ok(figures.length >= 12, `expected a figure per net and input, got ${figures.length}`);
    assert.doesNotMatch(visible, /-\d+\.\d{8} XMR/);
});
