// The shared render harness for the frontend render tests. components.mjs exports only the App
// root by design, so every card is driven THROUGH App with a real build_state() payload
// (fixtures/state.json, regenerate with fixtures/_gen_state.py) — the components are therefore
// exercised against the true server contract. Rendering uses a dependency-free vnode walker
// (helpers/render.mjs): no DOM, no npm deps.
//
// Split out of components.test.mjs so a second render test file can use it without duplicating a
// fixture and a handler table, and because that file is at its file-budget ceiling.
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
    onDismissHint: noop, onInspect: noop, onCloseInspect: noop,
};

function renderApp({ state = BASE, connected = true, ui = UI } = {}) {
    return render(App, { state, connected, ui, ...HANDLERS });
}

export { BASE, clone, renderApp, UI };

// One card's slice of the rendered HTML, so an assertion cannot accidentally match a sibling card.
function cardSlice(html, id) {
    const marker = `id="${id}"`;
    const start = html.indexOf(marker);
    assert.notEqual(start, -1, `missing ${id}`);
    const next = html.indexOf('id="card-', start + marker.length);
    return next === -1 ? html.slice(start) : html.slice(start, next);
}

export { cardSlice };
