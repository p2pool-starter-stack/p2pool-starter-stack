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
        ['name', 'ip_sort', 'uptime', 'h10', 'h60', 'h15'],
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
