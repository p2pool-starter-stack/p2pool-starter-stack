// Unit tests for the stack-topology diagram geometry (mining_dashboard/web/static/topology.mjs).
//
// Run with Node's built-in test runner — no dependencies, no package.json, no build step:
//     node --test dashboard/tests/frontend/
// (CI runs exactly this; Node is preinstalled on the runner.)
//
// The SVG *component* isn't rendered here (that needs a DOM toolchain the repo avoids); these
// cover the pure geometry + the node-placement contract that decides whether every server-derived
// config actually "shows correctly" in the diagram. The server half of the data is exercised in
// tests/service/test_egress.py.
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
    POS, ROUTE_COLOR, ROUTE_NAME, edgePath,
} from '../../mining_dashboard/web/static/topology.mjs';

// Canonical node ids — MUST equal service/egress.py TOPOLOGY_NODES ids. The backend half of this
// contract is tests/service/test_egress.py::test_topology_nodes_match_the_canonical_set. If the
// two drift, the server can emit an edge whose endpoint POS can't place and it vanishes from the
// SVG silently (StackTopology._edge returns null when POS[id] is missing).
const NODE_IDS = [
    'rigs', 'browser', 'xmrig-proxy', 'caddy', 'dashboard',
    'p2pool', 'monerod', 'tari', 'docker', 'tor', 'internet',
];

test('POS places every canonical node and nothing extra', () => {
    assert.deepEqual(new Set(Object.keys(POS)), new Set(NODE_IDS));
});

test('every POS box has finite, positive geometry', () => {
    for (const [id, b] of Object.entries(POS)) {
        for (const k of ['x', 'y', 'w', 'h']) {
            assert.ok(Number.isFinite(b[k]), `${id}.${k} is not finite`);
        }
        assert.ok(b.w > 0 && b.h > 0, `${id} has non-positive size`);
    }
});

test('edgePath: any edge between two nodes yields a valid, finite SVG path', () => {
    // Every config produces a subset of these node-to-node edges; none may render as malformed
    // geometry (a stray NaN/undefined makes the whole <path> disappear in the browser).
    for (const from of NODE_IDS) {
        for (const to of NODE_IDS) {
            if (from === to) continue;
            const d = edgePath({ from, to }, POS[from], POS[to]);
            assert.ok(d.startsWith('M'), `${from}->${to}: "${d}" must start with a moveto`);
            assert.ok(!/NaN|undefined/.test(d), `${from}->${to}: "${d}" has NaN/undefined`);
        }
    }
});

test('edgePath: column-crossing edges route orthogonally through a clear lane', () => {
    // The three edges that would otherwise cut across the daemon column are routed through a
    // dedicated lane; they must NOT fall through to the straight diagonal default.
    assert.match(edgePath({ from: 'xmrig-proxy', to: 'tor' }, POS['xmrig-proxy'], POS.tor), /V42/);
    assert.match(edgePath({ from: 'dashboard', to: 'tor' }, POS.dashboard, POS.tor), /V312/);
    assert.match(edgePath({ from: 'p2pool', to: 'tari' }, POS.p2pool, POS.tari), /H254/);
    // A clearnet leak lands on `internet` instead of `tor` but must take the SAME lane.
    assert.match(
        edgePath({ from: 'dashboard', to: 'internet' }, POS.dashboard, POS.internet),
        /V312/,
    );
});

test('route palette + names cover every route the server can emit', () => {
    // egress.py emits exactly these four route tokens; the diagram must colour & label them all.
    for (const r of ['tor', 'clearnet', 'local', 'inactive']) {
        assert.ok(ROUTE_COLOR[r], `no colour for route "${r}"`);
        assert.ok(ROUTE_NAME[r], `no label for route "${r}"`);
    }
});
