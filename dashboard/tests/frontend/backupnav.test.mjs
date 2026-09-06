// Can an operator find the backup without reading the config editor first (#1854)?
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// The card's own render states live in backupview.test.mjs; these cover the WIRING — that Backup
// is its own view rather than a card under the editor, that choosing it puts the card on screen
// instead of the dashboard grid, and that the appliance flag reaches the card. Only a render
// through App can prove any of that. New file: components.test.mjs is at its file-budget ceiling.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { clone, renderApp, UI } from './harness.mjs';

// The base fixture has the control channel off, so the card's disabled explainer is the cheapest
// proof that BackupPanel rendered at all — it does not depend on the backup flow being reachable.
// The leading word is load-bearing: the Diagnostics card beside it says the same sentence about
// itself, and a needle without "Backup export" matches that one instead.
const CARD = /Backup export is off with the rest of the control channel/;

test('the view controls offer Backup as an entry of its own (#1854)', () => {
    assert.match(renderApp(), /class="btn-toggle[^"]*"[^>]*>Backup</);
});

test('choosing Backup shows the card and stands the dashboard grid down (#1854)', () => {
    const backup = renderApp({ ui: { ...UI, view: 'backup' } });
    assert.match(backup, /class="btn-toggle active"[^>]*>Backup</);
    assert.match(backup, CARD);
    assert.doesNotMatch(backup, /class="grid"/);
    // The control: the grid is what every other view shows, so its absence above is the Backup
    // view's doing and not a fixture that renders no grid anywhere.
    assert.match(renderApp({ ui: { ...UI, view: 'simple' } }), /class="grid"/);
});

test('Backup has left the Configuration stack — it moved, it did not multiply (#1854)', () => {
    const config = renderApp({ ui: { ...UI, view: 'config' } });
    assert.doesNotMatch(config, CARD);
    assert.doesNotMatch(config, /class="btn-toggle active"[^>]*>Backup</);
});

test('the appliance flag reaches the card, so it never prints a host-CLI remedy (#1854)', () => {
    const state = clone();
    state.os_update = { status: 'idle' }; // what makes App call this machine an appliance
    const out = renderApp({ state, ui: { ...UI, view: 'backup' } });
    assert.match(out, /set up without a dashboard login/);
    assert.doesNotMatch(out, /not answering|returns with the channel/);
    assert.doesNotMatch(out, /pithead apply/);
});
