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
    parseHashrate, computeEarnings, formatXmr, formatTimeToShare,
    DAYS_PER_MONTH, DAYS_PER_YEAR,
    bandBorderWidth, uptimeCell,
    egressRoute,
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
    const ws = [{ h10: 5000 }, { h10: 250 }, { h10: 12000 }];
    assert.deepEqual(
        sortWorkers(ws, col('h10'), true).map((w) => w.h10),
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
        ['name', 'ip_sort', 'uptime', 'h10', 'h60', 'h15', 'accepted', 'rejected'],
    );
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
    assert.deepEqual(computeEarnings(0, ok), { day: null, month: null, year: null, timeToShareSec: null });
    assert.deepEqual(computeEarnings(null, ok), { day: null, month: null, year: null, timeToShareSec: null });
    // available:false (network stats missing) -> graceful "—" path even with a valid hashrate.
    assert.equal(computeEarnings(50_000, { available: false, coeff_day: 1e-7 }).day, null);
    assert.equal(computeEarnings(50_000, null).day, null);
});

test('computeEarnings: no time-to-share when share difficulty is unknown', () => {
    const est = computeEarnings(50_000, { available: true, coeff_day: 1e-7, pool_difficulty: 0 });
    assert.equal(est.timeToShareSec, null);
    assert.ok(est.day > 0);   // earnings still computed
});

test('formatXmr: precision scales with magnitude; "—" for null/invalid', () => {
    assert.equal(formatXmr(2.5), '2.5000 XMR');        // >= 1 -> 4 dp
    assert.equal(formatXmr(0.1234567), '0.123457 XMR'); // >= 0.001 -> 6 dp
    assert.equal(formatXmr(0.00000123), '0.00000123 XMR'); // tiny -> 8 dp, not rounded to 0
    assert.equal(formatXmr(0), '0 XMR');
    assert.equal(formatXmr(null), '—');
    assert.equal(formatXmr(Infinity), '—');
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
