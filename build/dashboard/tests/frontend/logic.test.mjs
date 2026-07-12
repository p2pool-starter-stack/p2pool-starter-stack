// Unit tests for the dashboard's pure client logic (mining_dashboard/web/static/logic.mjs).
//
// Run with Node's built-in test runner — no dependencies, no package.json, no build step:
//     node --test build/dashboard/tests/frontend/
// (CI runs exactly this; Node is preinstalled on the runner.)
//
// Component *rendering* isn't unit-tested here (that needs a DOM/toolchain the repo avoids); it's
// covered by the browser smoke test. This file covers the logic with real regression risk.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
    sortWorkers, fmtTimestamp, WORKER_COLUMNS,
    THEMES, THEME_ORDER, normalizeTheme,
    clampZoomWindow, fmtWindowDuration,
    SERIES_KEYS, normalizeSeries,
    AVG_WINDOWS, DEFAULT_AVG_WINDOW, normalizeAvgWindow,
    heroKpis, raffleCls,
    parseHashrate, fmtHashrate, computeEarnings, computeXvbTier, xvbTierComparison, formatXmr, formatXtm, formatTimeToShare,
    computeEnergy, formatFiat, formatUnit,
    DAYS_PER_MONTH, DAYS_PER_YEAR,
    bandBorderWidth, uptimeCell,
    egressRoute, boxAnchor,
} from '../../mining_dashboard/web/static/logic.mjs';

const col = (key) => WORKER_COLUMNS.findIndex((c) => c.key === key);

test('sortWorkers: null index keeps the server-provided order', () => {
    const ws = [{ name: 'b' }, { name: 'a' }];
    assert.deepEqual(sortWorkers(ws, null, true), ws);
});

test('sortWorkers: numeric columns sort numerically, not lexically', () => {
    // The whole reason the server sends raw ip_sort/h* numbers: a string sort would order
    // 1000 before 9. This is the regression this suite exists to catch.
    const ws = [{ ip_sort: 9 }, { ip_sort: 1000 }, { ip_sort: 100 }];
    assert.deepEqual(
        sortWorkers(ws, col('ip_sort'), true).map((w) => w.ip_sort),
        [9, 100, 1000],
    );
});

test('sortWorkers: hashrate column also sorts numerically', () => {
    const ws = [{ h15: 5000 }, { h15: 250 }, { h15: 12000 }];
    assert.deepEqual(
        sortWorkers(ws, col('h15'), true).map((w) => w.h15),
        [250, 5000, 12000],
    );
});

test('sortWorkers: descending reverses the order', () => {
    const ws = [{ ip_sort: 1 }, { ip_sort: 2 }, { ip_sort: 3 }];
    assert.deepEqual(
        sortWorkers(ws, col('ip_sort'), false).map((w) => w.ip_sort),
        [3, 2, 1],
    );
});

test('sortWorkers: name column sorts as text', () => {
    const ws = [{ name: 'rig-10' }, { name: 'rig-2' }, { name: 'rig-1' }];
    assert.deepEqual(
        sortWorkers(ws, col('name'), true).map((w) => w.name),
        ['rig-1', 'rig-10', 'rig-2'],   // lexical (not natural) ordering, as implemented
    );
});

test('sortWorkers: does not mutate the input array', () => {
    const ws = [{ ip_sort: 3 }, { ip_sort: 1 }, { ip_sort: 2 }];
    const before = ws.map((w) => w.ip_sort);
    sortWorkers(ws, col('ip_sort'), true);
    assert.deepEqual(ws.map((w) => w.ip_sort), before);
});

test('WORKER_COLUMNS: keys match the worker fields the server sends', () => {
    assert.deepEqual(
        WORKER_COLUMNS.map((c) => c.key),
        ['name', 'ip_sort', 'uptime', 'h60', 'h15', 'accepted', 'rejected'],
    );
});

test('WORKER_COLUMNS: hashrate windows are labelled by what the data is (#387)', () => {
    // h60 holds the 1m rate and h15 the 10m rate (legacy key names; see data_service). The labels
    // must say 1m / 10m so the table matches the chart toggle and Telegram's "(10m avg)".
    const labels = Object.fromEntries(WORKER_COLUMNS.map((c) => [c.key, c.label]));
    assert.equal(labels.h60, '1m');
    assert.equal(labels.h15, '10m');
    assert.equal(labels.h10, undefined); // dropped — via the proxy it duplicated the 1m rate
});

test('sortWorkers: rejected column sorts numerically (find problem rigs)', () => {
    // Per-worker share counts are raw numbers so the operator can sort the worst rejecters up.
    const ws = [{ rejected: 12 }, { rejected: 0 }, { rejected: 3 }];
    assert.deepEqual(
        sortWorkers(ws, col('rejected'), false).map((w) => w.rejected),
        [12, 3, 0],
    );
});

test('fmtTimestamp: returns a non-empty string for an epoch-ms value', () => {
    // Exact text is locale/timezone dependent (CI varies), so assert shape, not content.
    const out = fmtTimestamp(0);
    assert.equal(typeof out, 'string');
    assert.ok(out.length > 0);
});

test('normalizeTheme: passes valid modes through, defaults the rest to auto', () => {
    for (const t of THEMES) assert.equal(normalizeTheme(t), t);
    assert.equal(normalizeTheme(null), 'auto');       // nothing saved yet
    assert.equal(normalizeTheme('sepia'), 'auto');    // garbage in localStorage
});

test('THEME_ORDER: the control renders every theme exactly once', () => {
    // The segmented control maps over THEME_ORDER, so it must cover the same set as THEMES with
    // no dupes/strays — otherwise a mode would be unreachable or rendered twice.
    assert.deepEqual([...THEME_ORDER].sort(), [...THEMES].sort());
});

test('normalizeAvgWindow: passes valid windows through, defaults the rest to 10m (#168)', () => {
    for (const w of AVG_WINDOWS) assert.equal(normalizeAvgWindow(w), w);
    assert.equal(normalizeAvgWindow(null), '10m');     // nothing saved yet
    assert.equal(normalizeAvgWindow('7d'), '10m');     // garbage in localStorage
    assert.equal(normalizeAvgWindow(undefined), '10m');
    assert.equal(DEFAULT_AVG_WINDOW, '10m');           // the default is today's headline series
});

test('AVG_WINDOWS: the client window set matches the server contract (#168)', () => {
    // The buttons (chart.mjs WINDOWS) and the server (config.HASHRATE_WINDOWS) must agree on the
    // same five keys in the same order, or a button would request a window the server canonicalizes
    // away (silently snapping back to 10m).
    assert.deepEqual(AVG_WINDOWS, ['1m', '10m', '1h', '12h', '24h']);
});

// --- Issue #47: zoom window helpers --------------------------------------------------

test('clampZoomWindow: orders endpoints and enforces a minimum span', () => {
    // Reversed drag is normalized low->high.
    assert.deepEqual(clampZoomWindow(2000, 1000, 100), { from: 1000, to: 2000 });
    // A too-narrow window is widened around its centre to minSpanMs.
    assert.deepEqual(clampZoomWindow(1000, 1010, 100), { from: 955, to: 1055 });
    // A comfortably wide window is left as-is.
    assert.deepEqual(clampZoomWindow(0, 5000, 1000), { from: 0, to: 5000 });
});

test('clampZoomWindow: rejects unusable input', () => {
    assert.equal(clampZoomWindow(NaN, 1000, 100), null);
    assert.equal(clampZoomWindow(1000, 1000, 100), null);   // zero-width selection
    assert.equal(clampZoomWindow(Infinity, 1, 100), null);
});

test('fmtWindowDuration: two coarsest units, trailing zeros dropped', () => {
    assert.equal(fmtWindowDuration(0), '0s');
    assert.equal(fmtWindowDuration(45_000), '45s');
    assert.equal(fmtWindowDuration(90_000), '1m 30s');
    assert.equal(fmtWindowDuration(3_600_000), '1h');          // exactly 1h -> no "0m"
    assert.equal(fmtWindowDuration(4_800_000), '1h 20m');
    assert.equal(fmtWindowDuration(3 * 86_400_000), '3d');     // exactly 3d -> no "0h"
});

test('normalizeSeries: defaults every series to visible, only explicit false hides', () => {
    assert.deepEqual(normalizeSeries(null), { p2pool: true, xvb: true, shares: true });
    assert.deepEqual(normalizeSeries({}), { p2pool: true, xvb: true, shares: true });
    assert.deepEqual(normalizeSeries({ xvb: false }), { p2pool: true, xvb: false, shares: true });
    // Garbage / stray keys are ignored; output is always the full key set.
    assert.deepEqual(Object.keys(normalizeSeries({ junk: 1 })).sort(), [...SERIES_KEYS].sort());
    assert.deepEqual(normalizeSeries('nope'), { p2pool: true, xvb: true, shares: true });
});

// --- Issue #12: expected-earnings what-if --------------------------------------------

test('parseHashrate: accepts bare numbers and k/M/G suffixes', () => {
    assert.equal(parseHashrate('50000'), 50000);
    assert.equal(parseHashrate('10.5k'), 10500);
    assert.equal(parseHashrate('1.2M'), 1_200_000);
    assert.equal(parseHashrate('2.5g'), 2_500_000_000);
    // Round-trips the server's formatted measured-hashrate string (e.g. the input default).
    assert.equal(parseHashrate('10.50 kH/s'), 10500);
    assert.equal(parseHashrate('1.20 MH/s'), 1_200_000);
});

test('parseHashrate: rejects empty / unparseable input', () => {
    assert.equal(parseHashrate(''), null);
    assert.equal(parseHashrate('   '), null);
    assert.equal(parseHashrate('abc'), null);
    assert.equal(parseHashrate(null), null);
    assert.equal(parseHashrate(undefined), null);
});

test('fmtHashrate: mirrors the server format_hashrate unit boundaries (#387)', () => {
    // Same cases as tests/helper/test_utils.py TestFormatHashrate — the two must stay in lockstep.
    assert.equal(fmtHashrate(1_500_000_000), '1.50 GH/s');
    assert.equal(fmtHashrate(2_500_000), '2.50 MH/s');
    assert.equal(fmtHashrate(1_500), '1.50 kH/s');
    assert.equal(fmtHashrate(500), '500.00 H/s');
    assert.equal(fmtHashrate(0), '0.00 H/s');
    assert.equal(fmtHashrate('invalid'), '0 H/s');
});

test('computeEarnings: scales the daily rate to day/month/year + time-to-share', () => {
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 250_000_000 };
    const est = computeEarnings(50_000, earnings);
    assert.equal(est.day, 50_000 * 1e-7);
    assert.equal(est.month, est.day * DAYS_PER_MONTH);
    assert.equal(est.year, est.day * DAYS_PER_YEAR);
    // Expected seconds to a P2Pool share = share difficulty / hashrate.
    assert.equal(est.timeToShareSec, 250_000_000 / 50_000);
});

test('computeEarnings: returns nulls when unavailable or hashrate is non-positive', () => {
    const ok = { available: true, coeff_day: 1e-7, pool_difficulty: 1 };
    const allNull = { day: null, month: null, year: null, timeToShareSec: null,
                      tariDay: null, tariMonth: null, tariYear: null,
                      tariTimeToBlockSec: null, tariRewardPerBlock: null };
    assert.deepEqual(computeEarnings(0, ok), allNull);
    assert.deepEqual(computeEarnings(null, ok), allNull);
    // available:false (network stats missing) -> graceful "—" path even with a valid hashrate.
    assert.equal(computeEarnings(50_000, { available: false, coeff_day: 1e-7 }).day, null);
    assert.equal(computeEarnings(50_000, null).day, null);
});

test('computeEarnings: Tari figures scale with the same what-if input (#117)', () => {
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 1,
                       tari_available: true, tari_coeff_day: 2e-3 };
    const est = computeEarnings(50_000, earnings);
    assert.equal(est.tariDay, 50_000 * 2e-3);
    assert.equal(est.tariMonth, est.tariDay * DAYS_PER_MONTH);
    assert.equal(est.tariYear, est.tariDay * DAYS_PER_YEAR);
    // Doubling the hashrate doubles the XTM figures — one input drives both estimates.
    assert.equal(computeEarnings(100_000, earnings).tariDay, 2 * est.tariDay);
});

test('computeEarnings: solo Tari time-to-block = difficulty / hashrate, reward passed through', () => {
    // tari_difficulty carries seconds-to-block-per-H/s (== difficulty, guarded server-side).
    // Prod field numbers: diff ~1.677e12, fleet ~269 kH/s -> ~6.23e6 s (~72 days).
    const earnings = { available: true, coeff_day: 1e-7, pool_difficulty: 1,
                       tari_available: true, tari_coeff_day: 2e-3,
                       tari_difficulty: 1.677e12, tari_reward: 10_709 };
    const est = computeEarnings(269_000, earnings);
    assert.equal(est.tariTimeToBlockSec, 1.677e12 / 269_000);
    assert.ok(est.tariTimeToBlockSec / 86_400 > 70 && est.tariTimeToBlockSec / 86_400 < 74);
    assert.equal(est.tariRewardPerBlock, 10_709);
    // More hashrate finds the block sooner (inverse), so time-to-block halves when hashrate doubles.
    assert.equal(computeEarnings(538_000, earnings).tariTimeToBlockSec, est.tariTimeToBlockSec / 2);
    // The duration formatter renders the ~72-day span as days, not a huge hour count.
    assert.match(formatTimeToShare(est.tariTimeToBlockSec), /^\d+d/);
});

test('computeEarnings: Tari figures are null when merge-mining is unavailable (#117)', () => {
    const est = computeEarnings(50_000, {
        available: true, coeff_day: 1e-7, pool_difficulty: 1,
        tari_available: false, tari_coeff_day: 0, tari_difficulty: 0, tari_reward: 0,
    });
    assert.equal(est.tariDay, null);
    assert.equal(est.tariMonth, null);
    assert.equal(est.tariYear, null);
    assert.equal(est.tariTimeToBlockSec, null);
    assert.equal(est.tariRewardPerBlock, null);
    assert.ok(est.day > 0);   // the XMR estimate is unaffected
});

test('computeEarnings: no time-to-share when share difficulty is unknown', () => {
    const est = computeEarnings(50_000, { available: true, coeff_day: 1e-7, pool_difficulty: 0 });
    assert.equal(est.timeToShareSec, null);
    assert.ok(est.day > 0);   // earnings still computed
});

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

test('computeXvbTier: null when disabled, calc missing, empty tiers, or bad hashrate', () => {
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, enabled: false }), null);
    assert.equal(computeXvbTier(15_000, null), null);
    assert.equal(computeXvbTier(15_000, { ...XVB_CALC, tiers: [] }), null);
    assert.equal(computeXvbTier(0, XVB_CALC), null);
    assert.equal(computeXvbTier(null, XVB_CALC), null);
});

// --- xvbTierComparison (#118) — per-tier expected vs cost vs net -------------------------

test('xvbTierComparison: expected − cost = net when the estimate is present', () => {
    const tier = { name: 'Whale', threshold: 100_000, expected_reward_year: 6.17 };
    const c = xvbTierComparison(tier, 1e-7); // cost = 100000 × 1e-7 × 365 = 3.65
    assert.equal(c.expected, 6.17);
    assert.ok(Math.abs(c.cost - 3.65) < 1e-9);
    assert.ok(Math.abs(c.net - 2.52) < 1e-9);
});

test('xvbTierComparison: null expected (stale) keeps cost, nulls net — never fabricates a reward', () => {
    const tier = { name: 'Whale', threshold: 100_000, expected_reward_year: null };
    const c = xvbTierComparison(tier, 1e-7);
    assert.equal(c.expected, null);
    assert.ok(Math.abs(c.cost - 3.65) < 1e-9);
    assert.equal(c.net, null);
});

test('xvbTierComparison: no coeff_day (network stats down) → cost and net null', () => {
    const tier = { name: 'Whale', threshold: 100_000, expected_reward_year: 6.17 };
    const c = xvbTierComparison(tier, 0);
    assert.equal(c.cost, null);
    assert.equal(c.net, null);
    assert.equal(c.expected, 6.17);
});

test('formatXmr: precision scales with magnitude; "—" for null/invalid', () => {
    assert.equal(formatXmr(2.5), '2.5000 XMR');        // >= 1 -> 4 dp
    assert.equal(formatXmr(0.1234567), '0.123457 XMR'); // >= 0.001 -> 6 dp
    assert.equal(formatXmr(0.00000123), '0.00000123 XMR'); // tiny -> 8 dp, not rounded to 0
    assert.equal(formatXmr(0), '0 XMR');
    assert.equal(formatXmr(null), '—');
    assert.equal(formatXmr(Infinity), '—');
});

test('formatXtm: same adaptive precision with the XTM unit; "—" for null (#117)', () => {
    assert.equal(formatXtm(2.5), '2.5000 XTM');
    assert.equal(formatXtm(0), '0 XTM');
    assert.equal(formatXtm(null), '—');   // the Tari-unavailable "—" state
});

test('formatTimeToShare: formats seconds, "—" for null / non-positive', () => {
    assert.equal(formatTimeToShare(5400), '1h 30m');
    assert.equal(formatTimeToShare(90), '1m 30s');
    assert.equal(formatTimeToShare(null), '—');
    assert.equal(formatTimeToShare(0), '—');
    assert.equal(formatTimeToShare(Infinity), '—');
});

// --- Issue #81: hero KPI band selector ------------------------------------------------

// Minimal /api/state shape carrying just the fields the band reads; `over` deep-overrides a
// section so each test changes only what it asserts on.
const _heroState = (over = {}) => ({
    hashrate: { total: '10.50 kH/s', tier: 'Donor (1.00 kH/s+)', mode_name: 'P2POOL',
                mode_variant: 'ok', ...over.hashrate },
    shares_window: { count: 5, ok: true, ...over.shares_window },
    raffle_eligible: { applies: true, eligible: true, label: 'Yes', ...over.raffle_eligible },
    pool: { blocks: 42, ...over.pool },
});
const _byLabel = (state) => Object.fromEntries(heroKpis(state).map((k) => [k.label, k]));

test('heroKpis: surfaces the six headline numbers under stable labels, in order', () => {
    assert.deepEqual(
        heroKpis(_heroState()).map((k) => k.label),
        ['Total Hashrate', 'Shares in Window', 'Raffle Eligible', 'Blocks Found', 'XvB Tier', 'Mining Mode'],
    );
});

test('heroKpis: wires each KPI to its build_state field', () => {
    const k = _byLabel(_heroState());
    assert.equal(k['Total Hashrate'].value, '10.50 kH/s');   // hashrate.total
    assert.equal(k['Shares in Window'].value, 5);            // shares_window.count
    assert.equal(k['Raffle Eligible'].value, 'Yes');         // raffle_eligible.label
    assert.equal(k['Blocks Found'].value, 42);               // pool.blocks
    assert.equal(k['XvB Tier'].value, 'Donor (1.00 kH/s+)'); // hashrate.tier
    assert.equal(k['Mining Mode'].value, 'P2POOL');          // hashrate.mode_name
});

test('heroKpis: shares colour reflects the ok flag', () => {
    assert.equal(_byLabel(_heroState({ shares_window: { count: 3, ok: true } }))['Shares in Window'].cls, 'status-ok');
    assert.equal(_byLabel(_heroState({ shares_window: { count: 0, ok: false } }))['Shares in Window'].cls, 'status-bad');
});

test('heroKpis: Raffle Eligible colour reflects win eligibility (#158)', () => {
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: true, eligible: true, label: 'Yes' } }))['Raffle Eligible'].cls, 'status-ok');
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: true, eligible: false, label: 'No' } }))['Raffle Eligible'].cls, 'status-bad');
    // XvB off => N/A => muted (not red).
    assert.equal(_byLabel(_heroState({ raffle_eligible: { applies: false, label: 'N/A (XvB off)' } }))['Raffle Eligible'].cls, '');
});

test('raffleCls: muted when XvB off (N/A), green when eligible, red otherwise (#158)', () => {
    assert.equal(raffleCls({ applies: false, eligible: false }), '');   // N/A — XvB off
    assert.equal(raffleCls({ applies: true, eligible: true }), 'status-ok');
    assert.equal(raffleCls({ applies: true, eligible: false }), 'status-bad');
    assert.equal(raffleCls(undefined), '');                              // defensive: no state yet
});

test('heroKpis: mode colour follows the server mode_variant token', () => {
    // Same c-<token> mapping the Overview card uses, so the band's mode matches the rest of the UI.
    assert.equal(_byLabel(_heroState({ hashrate: { mode_variant: 'purple' } }))['Mining Mode'].cls, 'c-purple');
    assert.equal(_byLabel(_heroState({ hashrate: { mode_variant: 'accent' } }))['Mining Mode'].cls, 'c-accent');
});

test('heroKpis: total is accent-coloured; blocks and tier carry no colour class', () => {
    const k = _byLabel(_heroState());
    assert.equal(k['Total Hashrate'].cls, 'text-accent');
    assert.equal(k['Blocks Found'].cls, '');
    assert.equal(k['XvB Tier'].cls, '');
});

// #184: a flat-zero band must not paint its top border-line over the other series' edge.
test('bandBorderWidth: zero-height segments get no border, real ones keep full width', () => {
    // XvB off all window: every XvB sample is 0 → no purple line anywhere.
    const xvb = [{ x: 1, y: 0 }, { x: 2, y: 0 }, { x: 3, y: 0 }];
    assert.equal(bandBorderWidth(xvb, { p0DataIndex: 0, p1DataIndex: 1 }, 3.5), 0);
    assert.equal(bandBorderWidth(xvb, { p0DataIndex: 1, p1DataIndex: 2 }, 3.5), 0);
    // A series with real hashrate keeps its border on non-zero segments...
    const p2p = [{ x: 1, y: 0 }, { x: 2, y: 50 }, { x: 3, y: 80 }];
    assert.equal(bandBorderWidth(p2p, { p0DataIndex: 1, p1DataIndex: 2 }, 3.5), 3.5);
    // ...and drops it only where the band is genuinely flat-zero (one endpoint zero is enough to keep
    // the rising edge visible).
    assert.equal(bandBorderWidth(p2p, { p0DataIndex: 0, p1DataIndex: 1 }, 3.5), 3.5);
});

// #169: the Uptime cell must read DOWN for an offline worker, not a climbing duration.
test('uptimeCell: online shows uptime, offline shows DOWN', () => {
    assert.equal(uptimeCell({ status: 'online', uptime_str: '3h 20m' }), '3h 20m');
    assert.equal(uptimeCell({ status: 'offline', uptime_str: '99h 9m' }), 'DOWN');
});

// #170: egressRoute maps a server route token to a display glyph + label + CSS colour token.
test('egressRoute: known routes map to icon/label/class; unknown falls back to muted', () => {
    assert.deepEqual(egressRoute('tor'), { icon: '🧅', label: 'Tor', cls: 'ok' });
    assert.equal(egressRoute('clearnet').cls, 'bad');
    assert.equal(egressRoute('local').cls, 'muted');
    assert.equal(egressRoute('inactive').cls, 'muted');
    const unknown = egressRoute('weird');
    assert.equal(unknown.cls, 'muted');
    assert.equal(unknown.label, 'weird');
});

// #170: boxAnchor returns the point on a node box's border heading toward a target — for topology
// connectors that start/end flush on the box edge.
test('boxAnchor: lands on the border facing the target, not the centre', () => {
    const node = { x: 100, y: 100, w: 40, h: 20 }; // centre (120, 110)
    // Target straight to the right → exits the right edge (x = 140) at the centre height.
    assert.deepEqual(boxAnchor(node, 300, 110), { x: 140, y: 110 });
    // Target straight up → exits the top edge (y = 100) at the centre width.
    assert.deepEqual(boxAnchor(node, 120, 0), { x: 120, y: 100 });
    // Degenerate (target == centre) → the centre itself, no NaN.
    assert.deepEqual(boxAnchor(node, 120, 110), { x: 120, y: 110 });
});


// --- Energy & profit calculator (#260) --------------------------------------------------

test('computeEnergy: kWh from measured watts, naive extrapolation', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0, xmr_price: 0 },
        { day: 0 },
    );
    assert.equal(en.kwhDay, 24);                      // 1000 W = 1 kW * 24h
    assert.equal(en.kwhMonth, 24 * DAYS_PER_MONTH);
    assert.equal(en.kwhYear, 24 * DAYS_PER_YEAR);
    assert.equal(en.costDay, null);                   // no price -> no cost
    assert.equal(en.netDay, null);
});

test('computeEnergy: cost appears once cost_per_kwh is set', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 0 },
        { day: 0.01 },
    );
    assert.equal(en.costDay, 24 * 0.2);               // 24 kWh * 0.2
    assert.equal(en.netDay, null);                    // no xmr_price -> no net
});

test('computeEnergy: net = gross(XMR*price) - cost when both prices set', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 0.2, xmr_price: 150 },
        { day: 0.1 },                                  // 0.1 XMR/day
    );
    // gross = 0.1 * 150 = 15; cost = 24 * 0.2 = 4.8; net = 10.2
    assert.ok(Math.abs(en.netDay - 10.2) < 1e-9);
    assert.ok(Math.abs(en.netYear - 10.2 * DAYS_PER_YEAR) < 1e-6);
});

test('computeEnergy: negative net survives (power costs more than it earns)', () => {
    const en = computeEnergy(
        { available: true, total_watts: 1000, cost_per_kwh: 1, xmr_price: 1 },
        { day: 0.001 },
    );
    assert.ok(en.netDay < 0);
});

test('computeEnergy: unavailable / zero watts returns all nulls', () => {
    for (const bad of [null, { available: false }, { available: true, total_watts: 0 }]) {
        const en = computeEnergy(bad, { day: 1 });
        assert.equal(en.kwhDay, null);
        assert.equal(en.netDay, null);
    }
});

test('formatFiat: currency label, two decimals, keeps the sign', () => {
    assert.equal(formatFiat(12.5, 'USD'), 'USD 12.50');
    assert.equal(formatFiat(-3, 'EUR'), '-EUR 3.00');
    assert.equal(formatFiat(null, 'USD'), '—');
});

test('formatUnit: value + unit, "—" for null', () => {
    assert.equal(formatUnit(142.0, 'W'), '142.0 W');
    assert.equal(formatUnit(20, 'H/s·W', 2), '20.00 H/s·W');
    assert.equal(formatUnit(null, 'kWh'), '—');
});
