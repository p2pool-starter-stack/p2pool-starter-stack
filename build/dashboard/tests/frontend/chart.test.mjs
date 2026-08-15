// Unit tests for the chart's pure helpers (mining_dashboard/web/static/chart.mjs).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
//
// Only the DOM-free logic is covered here (the Chart.js wiring + canvas gradients need a browser,
// by the repo's deliberate no-DOM-toolchain policy). withAlpha and padYAxis carry real regression
// risk — a colour-fill correctness rule and the near-flat-series y-padding maths.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { withAlpha, padYAxis, eventColors, donationSeries, workerMarkerStyle } from '../../mining_dashboard/web/static/chart.mjs';

test('withAlpha: appends an 8-bit alpha to a #rrggbb hex', () => {
    assert.equal(withAlpha('#58a6ff', '26'), '#58a6ff26');
    assert.equal(withAlpha('#000000', '0d'), '#0000000d');
});

test('withAlpha: non-#rrggbb values pass through opaque (a palette change cannot break fills)', () => {
    // CSS vars can resolve to rgb()/named/already-aa'd colours; those must pass through unchanged.
    for (const v of ['rgb(1,2,3)', 'red', '#abc', '#58a6ff26', '']) {
        assert.equal(withAlpha(v, '26'), v, v);
    }
});

test('padYAxis: pads the range and clamps the floor to zero', () => {
    const s = { min: 100, max: 200 };
    padYAxis(s);
    // pad = max(span*0.2, max*0.03) = max(20, 6) = 20
    assert.equal(s.min, 80);
    assert.equal(s.max, 220);
});

test('padYAxis: the floor is clamped to zero, never negative', () => {
    const s = { min: 10, max: 100 };
    padYAxis(s);
    // pad = max(span*0.2, max*0.03) = max(18, 3) = 18; 10 - 18 < 0 → clamps to 0.
    assert.equal(s.min, 0);
    assert.equal(s.max, 118);
});

test('padYAxis: the magnitude floor applies when the span is flat', () => {
    const s = { min: 1000, max: 1000 };
    padYAxis(s);
    // span is 0, so pad falls back to max*0.03 = 30
    assert.equal(s.min, 970);
    assert.equal(s.max, 1030);
});

test('padYAxis: no-op when the range is non-finite (all series hidden / no data)', () => {
    const s = { min: NaN, max: NaN };
    padYAxis(s);
    assert.ok(Number.isNaN(s.min) && Number.isNaN(s.max));
});

test('eventColors: maps recovery to ok, everything else to loss (#99)', () => {
    const c = { evtOk: '#3fb950', evtLoss: '#d29922' };
    const events = [
        { kind: 'hashrate_loss' },
        { kind: 'hashrate_recovered' },
        { kind: '' },
    ];
    assert.deepEqual(eventColors(events, c), [c.evtLoss, c.evtOk, c.evtLoss]);
});

test('eventColors: tolerates a missing events list', () => {
    assert.deepEqual(eventColors(undefined, { evtOk: 'g', evtLoss: 'r' }), []);
});

test('donationSeries: maps xvb_history donation_fraction (0..1) to a 0..100 percent line (#381)', () => {
    const hist = [
        { x: 1000, donation_fraction: 0.25 },
        { x: 2000, donation_fraction: 1 },
        { x: 3000 }, // missing fraction → 0, never NaN
    ];
    assert.deepEqual(donationSeries(hist), [
        { x: 1000, y: 25 },
        { x: 2000, y: 100 },
        { x: 3000, y: 0 },
    ]);
});

test('donationSeries: tolerates a missing history (XvB off / no samples yet)', () => {
    assert.deepEqual(donationSeries(undefined), []);
    assert.deepEqual(donationSeries([]), []);
});

test('workerMarkerStyle: upgrade markers are triangles, config-apply markers are diamonds (#1015)', () => {
    const c = { accent: '#58a6ff', ticks: '#8b949e' };
    const markers = [
        { kind: 'apply', quiet: false },
        { kind: 'upgrade', quiet: false },
    ];
    const style = workerMarkerStyle(markers, c);
    assert.deepEqual(style.pointStyle, ['rectRot', 'triangle']);
});

test('workerMarkerStyle: a quiet outcome (nothing changed) renders muted, not accent', () => {
    const c = { accent: '#58a6ff', ticks: '#8b949e' };
    const markers = [
        { kind: 'apply', quiet: false },
        { kind: 'apply', quiet: true },
    ];
    const style = workerMarkerStyle(markers, c);
    assert.deepEqual(style.color, [c.accent, c.ticks]);
});

test('workerMarkerStyle: tolerates a missing marker list', () => {
    const c = { accent: '#58a6ff', ticks: '#8b949e' };
    assert.deepEqual(workerMarkerStyle(undefined, c), { pointStyle: [], color: [] });
});
