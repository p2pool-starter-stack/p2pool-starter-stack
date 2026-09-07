// Tier-1 tests for the dashboard entry point (mining_dashboard/web/static/dashboard.js).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// dashboard.js owns the client's refresh loop and UI-state dispatch: the 30s poll with the
// Tor-hang abort (#382), the connected/disconnected flag, preference seeding from the URL and
// localStorage, and the handler wiring the App receives. initDashboard() names its browser seams
// (DOM, storage, fetch, history, timer, render) as injectable parameters, so these tests drive the
// real loop with fakes and observe it through the props handed to renderApp — no DOM, no npm deps.
// What the App *paints* from those props is components.test.mjs's job; the normalize* helpers'
// own semantics are logic.test.mjs's. Here we pin only what dashboard.js itself does.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
    FETCH_TIMEOUT_MS, initDashboard, loadSeries, REFRESH_MS, windowFromUrl,
} from '../../mining_dashboard/web/static/dashboard.js';
import { SERIES_KEYS } from '../../mining_dashboard/web/static/logic.mjs';

// --- fakes ------------------------------------------------------------------------------------

// Build an injectable environment. `responses` is a queue of response factories, one per expected
// fetch — a test that polls more than it queued fails loudly instead of hanging.
function makeEnv({ href = 'http://pithead.test/', stored = {}, responses = [] } = {}) {
    const fetches = []; // { url, opts } per fetch, in order
    const paints = []; // the full props object of every render, in order
    const urls = []; // history.replaceState rewrites, in order
    const doc = {
        title: '',
        documentElement: {
            attrs: {},
            setAttribute(name, value) { this.attrs[name] = value; },
        },
        getElementById: () => null,
    };
    let interval = null;
    const env = {
        doc,
        href,
        storage: {
            getItem: (k) => (k in stored ? stored[k] : null),
            setItem: (k, v) => { stored[k] = String(v); },
        },
        fetchFn: (url, opts) => {
            fetches.push({ url, opts });
            assert.ok(responses.length > 0, `unexpected fetch: ${url}`);
            return responses.shift()(url, opts);
        },
        replaceUrl: (u) => urls.push(u),
        schedule: (fn, ms) => { interval = { fn, ms }; },
        renderApp: (props) => paints.push(props),
    };
    return {
        env, fetches, paints, urls, doc, stored,
        interval: () => interval,
        last: () => paints[paints.length - 1],
    };
}

const ok = (body) => () => Promise.resolve({ ok: true, json: async () => body });
const httpError = (status) => () => Promise.resolve({ ok: false, status });
const aborted = () => () => Promise.reject(new DOMException('signal timed out', 'TimeoutError'));

// A poll that hangs like a dropped Tor circuit: never settles on its own; the test fires the
// abort the same way AbortSignal.timeout eventually would.
function hangingPoll() {
    let reject;
    const promise = new Promise((_, rej) => { reject = rej; });
    return {
        response: () => promise,
        abort: () => reject(new DOMException('signal timed out', 'TimeoutError')),
    };
}

// --- pure helpers -----------------------------------------------------------------------------

test('the poll timeout aborts before the next tick would fire (#382)', () => {
    // The whole point of the abort: a hung fetch must reject before the 30s interval ticks
    // again, or `inflight` latches and the page freezes on stale data with no banner.
    assert.ok(FETCH_TIMEOUT_MS > 0);
    assert.ok(FETCH_TIMEOUT_MS < REFRESH_MS);
});

test('windowFromUrl: accepts only a sane from/to pair', () => {
    const parse = (qs) => windowFromUrl(new URLSearchParams(qs));
    assert.deepEqual(parse('from=100&to=200'), { from: 100, to: 200 });
    assert.deepEqual(parse('from=100.5&to=200.25'), { from: 100.5, to: 200.25 });
    assert.equal(parse(''), null); // no zoom in the URL
    assert.equal(parse('from=100'), null); // half a window
    assert.equal(parse('to=100'), null);
    assert.equal(parse('from=200&to=100'), null); // inverted
    assert.equal(parse('from=100&to=100'), null); // empty span
    assert.equal(parse('from=0&to=100'), null); // epoch-0 start is garbage, not a window
    assert.equal(parse('from=abc&to=100'), null);
});

test('loadSeries: garbage or missing persisted JSON falls back to all-visible', () => {
    const allOn = Object.fromEntries(SERIES_KEYS.map((k) => [k, true]));
    assert.deepEqual(loadSeries(null), allOn);
    assert.deepEqual(loadSeries('{not json'), allOn);
    assert.deepEqual(loadSeries('"a string"'), allOn);
});

test('loadSeries: a persisted hidden series stays hidden', () => {
    const hidden = SERIES_KEYS[0];
    const out = loadSeries(JSON.stringify({ [hidden]: false }));
    assert.equal(out[hidden], false);
    for (const k of SERIES_KEYS.slice(1)) assert.equal(out[k], true);
});

// --- boot -------------------------------------------------------------------------------------

test('boot: paints the loading shell, then the first poll; refresh scheduled at 30s', async () => {
    const t = makeEnv({ responses: [ok({ page_title: 'Pithead — mining', workers: [] })] });
    const d = initDashboard(t.env);
    // The very first paint happens before any data arrives: state is still null.
    assert.equal(t.paints[0].state, null);
    assert.equal(t.paints[0].connected, true);
    await d.firstLoad;
    assert.equal(t.last().state.page_title, 'Pithead — mining');
    assert.equal(t.last().connected, true);
    assert.equal(t.doc.title, 'Pithead — mining'); // server-provided page title applied
    assert.equal(t.interval().ms, REFRESH_MS);
    assert.equal(t.interval().fn, d.tick); // the interval drives the same tick
});

test('poll request: default query, fetch marker header, and an abort signal (#382)', async () => {
    const t = makeEnv({ responses: [ok({})] });
    await initDashboard(t.env).firstLoad;
    const { url, opts } = t.fetches[0];
    assert.equal(url, '/api/state?range=all&avg=10m');
    assert.equal(opts.headers['X-Requested-With'], 'fetch');
    assert.ok(opts.signal instanceof AbortSignal); // the Tor-hang abort is actually wired
    assert.equal(t.doc.title, ''); // no page_title in the payload → title left alone
});

test('boot: ui state seeds from the URL and persisted preferences', async () => {
    const t = makeEnv({
        href: 'http://pithead.test/?range=24h',
        stored: {
            dashboardView: 'advanced',
            dashboardTheme: 'dark',
            dashboardAvgWindow: '1h',
            dashboardSort: '2:desc',
            dashboardCalcHint: 'dismissed',
        },
        responses: [ok({})],
    });
    const d = initDashboard(t.env);
    const ui = t.paints[0].ui;
    assert.equal(ui.range, '24h');
    assert.equal(ui.view, 'advanced');
    assert.equal(ui.theme, 'dark');
    assert.equal(ui.avg, '1h');
    assert.equal(ui.sortIndex, 2);
    assert.equal(ui.sortAsc, false);
    assert.equal(ui.hintDismissed, true);
    assert.equal(ui.inspectWorker, null);
    // The persisted theme is re-asserted on <html data-theme> before the first paint.
    assert.equal(t.doc.documentElement.attrs['data-theme'], 'dark');
    await d.firstLoad;
    assert.equal(t.fetches[0].url, '/api/state?range=24h&avg=1h');
});

test('boot: garbage persisted preferences are routed through their normalizers', async () => {
    // logic.test.mjs owns each normalizer's semantics; this pins that dashboard.js actually
    // feeds every storage key through the right one instead of trusting localStorage.
    const t = makeEnv({
        stored: {
            dashboardView: 'wat',
            dashboardTheme: 'blorp',
            dashboardAvgWindow: '7h',
            dashboardSort: '99:asc',
            dashboardSeries: '{broken',
        },
        responses: [ok({})],
    });
    initDashboard(t.env);
    const ui = t.paints[0].ui;
    assert.equal(ui.view, 'simple');
    assert.equal(ui.theme, 'auto');
    assert.equal(ui.avg, '10m');
    assert.equal(ui.sortIndex, null);
    assert.equal(ui.hintDismissed, false);
    for (const k of SERIES_KEYS) assert.equal(ui.series[k], true);
});

test('boot: a shareable zoom URL (?from=&to=) wins over the preset range', async () => {
    const t = makeEnv({ href: 'http://pithead.test/?from=1000&to=2000', responses: [ok({})] });
    await initDashboard(t.env).firstLoad;
    assert.equal(t.fetches[0].url, '/api/state?from=1000&to=2000&avg=10m');
});

// --- the refresh loop -------------------------------------------------------------------------

test('poll failure: disconnected banner state, last snapshot kept, recovery on next tick', async () => {
    const t = makeEnv({ responses: [ok({ page_title: 'live' }), aborted(), ok({ page_title: 'back' })] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    const snapshot = t.last().state;
    await d.tick(); // this poll dies (Tor circuit dropped, request aborted)
    assert.equal(t.last().connected, false);
    assert.equal(t.last().state, snapshot); // stale data stays on screen, flagged by the banner
    await d.tick(); // the next 30s tick reaches the server again
    assert.equal(t.last().connected, true);
    assert.equal(t.last().state.page_title, 'back');
});

test('poll failure: a non-2xx response counts as disconnected', async () => {
    const t = makeEnv({ responses: [httpError(502)] });
    await initDashboard(t.env).firstLoad;
    assert.equal(t.last().connected, false);
    assert.equal(t.last().state, null); // still the loading shell — no made-up data
});

test('a hung poll cannot stack fetches; the abort unblocks the loop (#382)', async () => {
    const hang = hangingPoll();
    const t = makeEnv({ responses: [hang.response, ok({ page_title: 'recovered' })] });
    const d = initDashboard(t.env);
    // The 30s interval fires while the first poll is still hanging: the inflight guard drops
    // the tick instead of stacking a second fetch.
    await t.interval().fn();
    assert.equal(t.fetches.length, 1);
    // The abort rejects the hung fetch — without it, `inflight` would stay latched and every
    // later tick would no-op forever: frozen page, no banner (the original #382).
    hang.abort();
    await d.firstLoad;
    assert.equal(t.last().connected, false);
    await d.tick();
    assert.equal(t.last().state.page_title, 'recovered');
    assert.equal(t.last().connected, true);
});

// --- handlers, as handed to the App -----------------------------------------------------------

test('onRange: exits any zoom, rewrites the URL, and refetches the new range', async () => {
    const t = makeEnv({
        href: 'http://pithead.test/?from=1000&to=2000',
        responses: [ok({}), ok({}), ok({})],
    });
    const d = initDashboard(t.env);
    await d.firstLoad;
    assert.ok(t.last().ui.window); // zoomed via the URL
    await t.last().onRange('1h');
    assert.equal(t.last().ui.range, '1h');
    assert.equal(t.last().ui.window, null); // picking a preset exits the zoom
    assert.deepEqual(t.urls, ['?range=1h']);
    assert.equal(t.fetches[1].url, '/api/state?range=1h&avg=10m');
    await t.last().onRange('all');
    assert.deepEqual(t.urls, ['?range=1h', '/']); // "all" restores the bare path
});

test('onZoom/onResetZoom: pin and release the manual window, with shareable URLs', async () => {
    const t = makeEnv({ responses: [ok({}), ok({}), ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    await t.last().onZoom(1000.4, 2000.6);
    assert.deepEqual(t.last().ui.window, { from: 1000.4, to: 2000.6 }); // exact, for the fetch
    assert.deepEqual(t.urls, ['?from=1000&to=2001']); // rounded, for the shareable URL
    assert.equal(t.fetches[1].url, '/api/state?from=1000.4&to=2000.6&avg=10m');
    await t.last().onResetZoom();
    assert.equal(t.last().ui.window, null);
    assert.deepEqual(t.urls, ['?from=1000&to=2001', '/']); // back on range "all" → bare path
    assert.equal(t.fetches[2].url, '/api/state?range=all&avg=10m');
});

test('onSort: first click ascends, same column flips, new column restarts ascending', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    const polls = t.fetches.length;
    t.last().onSort(3);
    assert.equal(t.last().ui.sortIndex, 3);
    assert.equal(t.last().ui.sortAsc, true);
    t.last().onSort(3);
    assert.equal(t.last().ui.sortAsc, false); // same column toggles direction
    t.last().onSort(1);
    assert.equal(t.last().ui.sortIndex, 1);
    assert.equal(t.last().ui.sortAsc, true); // a new column restarts ascending
    assert.equal(t.fetches.length, polls); // client-side sort only — no refetch
});

test('onView: persists the view; visiting Advanced retires the calculators hint (#425)', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    assert.equal(t.last().ui.hintDismissed, false);
    t.last().onView('advanced');
    assert.equal(t.last().ui.view, 'advanced');
    assert.equal(t.stored.dashboardView, 'advanced');
    assert.equal(t.last().ui.hintDismissed, true); // the hint's discoverability job is done
    assert.equal(t.stored.dashboardCalcHint, 'dismissed');
});

test('onView: switching to a non-Advanced view leaves the hint alone', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    t.last().onView('config');
    assert.equal(t.last().ui.view, 'config');
    assert.equal(t.last().ui.hintDismissed, false);
    assert.equal('dashboardCalcHint' in t.stored, false);
});

test('onDismissHint: dismisses the hint without leaving Simple view', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    t.last().onDismissHint();
    assert.equal(t.last().ui.hintDismissed, true);
    assert.equal(t.stored.dashboardCalcHint, 'dismissed');
    assert.equal(t.last().ui.view, 'simple');
});

test('onTheme: persists and re-applies the theme to <html data-theme>', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    t.last().onTheme('dark');
    assert.equal(t.last().ui.theme, 'dark');
    assert.equal(t.stored.dashboardTheme, 'dark');
    assert.equal(t.doc.documentElement.attrs['data-theme'], 'dark');
});

test('onToggleSeries: flips one series, persists the set, and never refetches', async () => {
    const key = SERIES_KEYS[0];
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    const polls = t.fetches.length;
    t.last().onToggleSeries(key);
    assert.equal(t.last().ui.series[key], false);
    assert.equal(JSON.parse(t.stored.dashboardSeries)[key], false); // survives reload
    t.last().onToggleSeries(key);
    assert.equal(t.last().ui.series[key], true);
    assert.equal(t.fetches.length, polls); // visibility only — no round-trip
});

test('onAvgWindow: clamps, persists, and refetches — the series lives on the server (#168)', async () => {
    const t = makeEnv({ responses: [ok({}), ok({}), ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    await t.last().onAvgWindow('1h');
    assert.equal(t.last().ui.avg, '1h');
    assert.equal(t.stored.dashboardAvgWindow, '1h');
    assert.equal(t.fetches[1].url, '/api/state?range=all&avg=1h');
    await t.last().onAvgWindow('bogus'); // garbage clamps to the default window
    assert.equal(t.last().ui.avg, '10m');
    assert.equal(t.fetches[2].url, '/api/state?range=all&avg=10m');
});

test('onInspect/onCloseInspect: transient worker-panel state — no fetch, nothing persisted', async () => {
    const t = makeEnv({ responses: [ok({})] });
    const d = initDashboard(t.env);
    await d.firstLoad;
    const polls = t.fetches.length;
    t.last().onInspect('miner-1');
    assert.equal(t.last().ui.inspectWorker, 'miner-1');
    t.last().onCloseInspect();
    assert.equal(t.last().ui.inspectWorker, null);
    assert.equal(t.fetches.length, polls);
    assert.deepEqual(Object.keys(t.stored), []); // transient: nothing written to storage
});

test('a persisted Backup view is restored, not quietly dropped to Simple (#1854)', async () => {
    const t = makeEnv({ stored: { dashboardView: 'backup' }, responses: [ok({})] });
    initDashboard(t.env);
    assert.equal(t.paints[0].ui.view, 'backup');
    // The control: the whitelist really does reject a view it does not know.
    const u = makeEnv({ stored: { dashboardView: 'nonsense' }, responses: [ok({})] });
    initDashboard(u.env);
    assert.equal(u.paints[0].ui.view, 'simple');
});
