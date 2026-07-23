// Mine cart train — the pure data adapter (cartsFromState) and tooltip text. The canvas
// renderer is browser-only (verified visually); the bucketing that decides what each cart
// shows is the logic worth pinning.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
    cartsFromState, cartTitle,
} from '../../mining_dashboard/web/static/minecart.mjs';

// Minimal chart payload: n points at 60s spacing (x in ms, like the server sends).
const T0 = 1_700_000_000_000;
function mkChart(n, { shares = [], raffle = [] } = {}) {
    const p2pool = [];
    for (let i = 0; i < n; i++) p2pool.push({ x: T0 + i * 60_000, y: 1000 });
    return { t0: T0, chart: { p2pool, shares, raffle } };
}

test('cartsFromState: spans the loaded window with `count` equal carts', () => {
    const { chart } = mkChart(120); // 119 minutes of history
    const carts = cartsFromState(chart, [], 12);
    assert.equal(carts.length, 12);
    // Contiguous, equal buckets covering first->last point.
    for (let i = 1; i < carts.length; i++) assert.equal(carts[i].t0, carts[i - 1].t1);
    assert.ok(Math.abs((carts[0].t1 - carts[0].t0) - (119 * 60) / 12) < 1e-9);
    // Only the newest cart is still loading under the chute.
    assert.deepEqual(carts.map((c) => c.loading), [...Array(11).fill(false), true]);
});

test('cartsFromState: null gap markers are skipped, empty payload yields no carts', () => {
    const { chart } = mkChart(10);
    chart.p2pool[4] = { x: chart.p2pool[4].x, y: null }; // outage break marker
    const carts = cartsFromState(chart, [], 5);
    assert.equal(carts.length, 5); // survives, no NaN
    for (const c of carts) assert.ok(Number.isFinite(c.t0) && Number.isFinite(c.t1));
    assert.deepEqual(cartsFromState({ p2pool: [] }, []), []);
    assert.deepEqual(cartsFromState(null, []), []);
    // All-gap history (every sample an outage marker) -> no window, no carts.
    const gaps = mkChart(4).chart;
    for (const p of gaps.p2pool) p.y = null;
    assert.deepEqual(cartsFromState(gaps, []), []);
});

test('cartsFromState: each event series lands its count in the right cart', () => {
    const { chart } = mkChart(120, {
        shares: [{ x: T0 + 10 * 60_000, c: 2 }, { x: T0 + 70 * 60_000, c: 1 }],
        raffle: [{ x: T0 + 70 * 60_000, label: 'win' }],
    });
    const blocks = [{ x: T0 + 110 * 60_000, height: 1 }];
    const carts = cartsFromState(chart, blocks, 12);
    assert.equal(carts[1].shares, 2);   // minute 10 -> bucket 1
    assert.equal(carts[7].shares, 1);   // minute 70 held a share AND a raffle win —
    assert.equal(carts[7].wins, 1);     // both counted, coins coexist in one cart
    assert.equal(carts[11].blocks, 1);  // minute 110 -> newest bucket
    assert.equal(carts[0].shares + carts[0].blocks + carts[0].wins, 0); // quiet cart stays quiet
});

test('cartsFromState: confirmed Tari payouts count in their cart, alongside other events', () => {
    const { chart } = mkChart(120, { shares: [{ x: T0 + 30 * 60_000, c: 1 }] });
    const payouts = { tari: [{ x: T0 + 30 * 60_000, amount: 4552e6 }, { x: T0 + 90 * 60_000, amount: 1 }] };
    const blocks = [{ x: T0 + 90 * 60_000, height: 7 }];
    const carts = cartsFromState(chart, blocks, 12, payouts);
    assert.equal(carts[3].tari, 1);    // minute 30: payout and share share a cart
    assert.equal(carts[3].shares, 1);
    assert.equal(carts[9].tari, 1);    // minute 90: payout and block share a cart
    assert.equal(carts[9].blocks, 1);
    // No payouts key at all (older server) -> same as before, no crash.
    assert.equal(cartsFromState(chart, blocks, 12).length, 12);
});

test('cartsFromState: an event on the exact last timestamp lands in the newest cart', () => {
    const { t0, chart } = mkChart(60);
    const lastX = t0 + 59 * 60_000;
    const carts = cartsFromState(chart, [{ x: lastX, height: 9 }], 6);
    assert.equal(carts[5].blocks, 1); // inclusive right edge on the loading cart
});

test('cartsFromState: single-point history yields carts without NaN (fresh dashboard start)', () => {
    // One poll of data: the window collapses to a point, so bucketSec floors at 60/count.
    // An event at that instant lands in cart 0; every cart stays well-formed.
    const { chart } = mkChart(1);
    const carts = cartsFromState(chart, [{ x: T0, height: 1 }], 12);
    assert.equal(carts.length, 12);
    for (const c of carts) assert.ok(Number.isFinite(c.t0) && Number.isFinite(c.t1));
    assert.equal(carts[0].blocks, 1);
});

test('cartTitle: says what the cart hauled, plurals and all', () => {
    const s = cartTitle({ t0: 0, t1: 600, shares: 2, blocks: 1, wins: 0, tari: 0, loading: true });
    assert.match(s, /1 block FOUND/);
    assert.match(s, /2 shares/);
    assert.match(s, /\(loading\)/);
    const rich = cartTitle({ t0: 0, t1: 600, shares: 1, blocks: 2, wins: 2, tari: 2, loading: false });
    assert.match(rich, /2 blocks FOUND/);
    assert.match(rich, /2 Tari payouts/);
    assert.match(rich, /2 XvB raffle wins/);
    assert.match(rich, /1 share(?!s)/);
    const one = cartTitle({ t0: 0, t1: 600, shares: 0, blocks: 0, wins: 1, tari: 1, loading: false });
    assert.match(one, /1 Tari payout(?!s)/);
    assert.match(one, /1 XvB raffle win(?!s)/);
    const quiet = cartTitle({ t0: 0, t1: 600, shares: 0, blocks: 0, wins: 0, tari: 0, loading: false });
    assert.match(quiet, /hauling/);
});
