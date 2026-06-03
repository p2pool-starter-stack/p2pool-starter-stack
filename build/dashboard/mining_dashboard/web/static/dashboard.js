// Dashboard entry point (ES module, loaded from <head>).
//
// Owns the small amount of client state and the refresh loop, then renders the Preact <App>.
// Data comes from GET /api/state (the server builds it; see views.build_state); the client
// holds only *UI* state that must survive data refreshes — selected range, table sort, and
// the simple/advanced view — plus the latest data snapshot and connection status.
import { render, html } from './preact.mjs';
import { App } from './components.mjs';
import { normalizeTheme } from './logic.mjs';

const root = document.getElementById('app');
const REFRESH_MS = 30000;

const ui = {
    range: new URL(location.href).searchParams.get('range') || 'all',
    sortIndex: null,
    sortAsc: true,
    view: localStorage.getItem('dashboardView') === 'advanced' ? 'advanced' : 'simple',
    // Theme is persisted in localStorage so it survives reloads and stack restarts (Issue #43).
    // theme-init.js already applied it to <html> before first paint; we mirror it into the UI
    // state and re-apply on toggle.
    theme: normalizeTheme(localStorage.getItem('dashboardTheme')),
};

// Reflect the current theme onto <html data-theme>; the CSS palette (and the chart, which reads
// the resolved CSS variables) follow from there.
function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
}

let state = null;        // latest /api/state payload, or null before the first response
let connected = true;    // false after a failed fetch (we keep showing the last snapshot)
let inflight = false;    // guard against overlapping fetches if one is slow

function rerender() {
    render(
        html`<${App} state=${state} connected=${connected} ui=${ui}
                     onRange=${setRange} onSort=${onSort} onView=${setView} onTheme=${setTheme} />`,
        root,
    );
}

async function tick() {
    if (inflight) return;
    inflight = true;
    try {
        const res = await fetch('/api/state?range=' + encodeURIComponent(ui.range),
                                { headers: { 'X-Requested-With': 'fetch' } });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        state = await res.json();
        connected = true;
        if (state.page_title) document.title = state.page_title;
    } catch (e) {
        connected = false;
        console.warn('dashboard refresh failed', e);
    } finally {
        inflight = false;
        rerender();
    }
}

function setRange(r) {
    ui.range = r;
    history.replaceState(null, '', r === 'all' ? location.pathname : ('?range=' + r));
    tick();   // re-fetch immediately; the chart/series depend on the range
}

function onSort(idx) {
    ui.sortAsc = (ui.sortIndex === idx) ? !ui.sortAsc : true;
    ui.sortIndex = idx;
    rerender();   // client-side sort only, no fetch
}

function setView(mode) {
    ui.view = mode;
    localStorage.setItem('dashboardView', mode);
    rerender();
}

function setTheme(theme) {
    ui.theme = theme;
    localStorage.setItem('dashboardTheme', theme);
    applyTheme(theme);   // updates <html data-theme>; the chart recolours on the next render
    rerender();
}

applyTheme(ui.theme);            // re-assert the (normalized) theme before the first paint
rerender();                      // paint the loading shell immediately
tick();                          // first data load
setInterval(tick, REFRESH_MS);   // then live updates
