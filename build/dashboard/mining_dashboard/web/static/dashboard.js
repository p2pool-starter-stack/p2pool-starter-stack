// Dashboard entry point (ES module, loaded from <head>).
//
// Owns the small amount of client state and the refresh loop, then renders the Preact <App>.
// Data comes from GET /api/state (the server builds it; see views.build_state); the client
// holds only *UI* state that must survive data refreshes — selected range, table sort, and
// the simple/advanced view — plus the latest data snapshot and connection status.
import { render, html } from './preact.mjs';
import { App } from './components.mjs';

const root = document.getElementById('app');
const REFRESH_MS = 30000;

const ui = {
    range: new URL(location.href).searchParams.get('range') || 'all',
    sortIndex: null,
    sortAsc: true,
    view: localStorage.getItem('dashboardView') === 'advanced' ? 'advanced' : 'simple',
};

let state = null;        // latest /api/state payload, or null before the first response
let connected = true;    // false after a failed fetch (we keep showing the last snapshot)
let inflight = false;    // guard against overlapping fetches if one is slow

function rerender() {
    render(
        html`<${App} state=${state} connected=${connected} ui=${ui}
                     onRange=${setRange} onSort=${onSort} onView=${setView} />`,
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

rerender();                      // paint the loading shell immediately
tick();                          // first data load
setInterval(tick, REFRESH_MS);   // then live updates
