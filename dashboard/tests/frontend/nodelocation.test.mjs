// Does the dashboard say whether each node runs here or somewhere else (#1040)?
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// The label mapping itself lives in statcards.test.mjs; these cover the WIRING — that each card
// and the diagram read the right node's flag — which only a render can prove. New file:
// components.test.mjs is at its file-budget ceiling.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { cardSlice, clone, renderApp } from './harness.mjs';

test('both node cards say whether the node is this machine\'s or somebody else\'s (#1040)', () => {
    // The wiring, not the mapping (statcards.test.mjs covers that): each card must read its OWN
    // node's flag out of sync.*, so a remote Tari can never be reported using Monero's answer.
    const s = clone();
    s.sync.monero.local = true;
    s.sync.tari.local = false;
    const tari = cardSlice(renderApp({ state: s }), 'card-tari');
    assert.match(tari, /<h5>Node<\/h5><p class="">Remote</);

    s.sync.tari.local = true;
    assert.match(cardSlice(renderApp({ state: s }), 'card-tari'), /<h5>Node<\/h5><p class="">Local</);

    // An older payload with no flag must not read as Local — see statcards.test.mjs for why.
    delete s.sync.tari.local;
    assert.match(cardSlice(renderApp({ state: s }), 'card-tari'), /<h5>Node<\/h5><p class="">—</);
});

test('the XMR Network card reads Monero\'s own location, not Tari\'s (#1040)', () => {
    const store = new Map([['dashboardCardNetwork', 'expanded']]);
    globalThis.localStorage = {
        getItem: (k) => (store.has(k) ? store.get(k) : null),
        setItem: (k, v) => store.set(k, String(v)),
    };
    try {
        const s = clone();
        s.sync.monero.local = false;
        s.sync.tari.local = true; // the wrong source would flip this assertion
        assert.match(cardSlice(renderApp({ state: s }), 'card-network'), /<h5>Node<\/h5><p class="">Remote</);
    } finally {
        delete globalThis.localStorage;
    }
});

test('the diagram captions the two relocatable nodes with their location (#1040)', () => {
    // The issue: the picture implied everything ran on this box. The caption rides as a SIBLING
    // of the node group because `.topo-node text` outranks `.topo-zone` — inside the group it
    // would render as a second full-size label, which is why this asserts the class, not just
    // the word.
    const s = clone();
    s.topology.nodes = s.topology.nodes.map((n) => (n.id === 'tari' ? { ...n, remote: true } : n));
    const html = renderApp({ state: s });
    assert.match(html, /class="topo-zone">remote</);
    assert.match(html, /class="topo-zone">local</);
    // Nodes that cannot move carry no location at all — no caption, no empty one.
    const captions = html.match(/class="topo-zone">(local|remote)</g) || [];
    assert.equal(captions.length, 2, 'only monerod and tari may carry a location');
});
