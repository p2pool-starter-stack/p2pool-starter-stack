// The .onion URL under the header's hostname/IP line (#1853).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// New file rather than more of components.test.mjs, which is at its file-budget ceiling. The
// render cases go through the App root on the real build_state fixture, like every other card, so
// they exercise the true server contract; copyText is a pure function and is tested directly,
// because the render probe deliberately never invokes handlers.
import assert from 'node:assert/strict';
import { mock, test } from 'node:test';

import { clone, renderApp } from './harness.mjs';
import { CLEAR_MS, OnionUrl, copyText } from '../../mining_dashboard/web/static/onionurl.mjs';

// A run of one letter, not a realistic v3 address: nothing here depends on the characters, and a
// high-entropy literal is what puts a secret scanner on a test file that holds no secret.
const ADDR = 'a'.repeat(56) + '.onion';
const URL = `http://${ADDR}`;

const withOnion = (onion) => {
    const s = clone();
    s.dashboard_onion = onion;
    return renderApp({ state: s });
};

test('the onion URL renders under the host line, whole (#1853)', () => {
    const html = withOnion({ url: URL, client_auth: false });
    // Whole, not elided: 56 characters of base32 carry no redundancy, so a truncated address is
    // one that does not open — and copying it to a phone is the entire product here.
    assert.match(html, new RegExp(`<span class="font-mono">${URL}</span>`));
    // It belongs to the header's address block, not to some card lower down the page. Anchor on
    // a marker that must exist: indexOf(-1) would slice the whole page and pass vacuously.
    assert.ok(html.includes('hero-band'), 'the hero band anchor is gone — re-anchor this slice');
    const header = html.slice(0, html.indexOf('hero-band'));
    assert.ok(header.includes(URL), 'the onion URL is not in the header block');
});

test('no onion means no block at all — not an empty row (#1853)', () => {
    // An empty row reads as "Tor is broken" rather than "Tor is off".
    assert.doesNotMatch(withOnion(null), /\.onion/);
    assert.doesNotMatch(withOnion(undefined), /\.onion/);
    // The control: the same fixture, one field filled, does render it — so the assertions above
    // mean the field was read, not that the harness rendered an empty page.
    assert.match(withOnion({ url: URL, client_auth: false }), /\.onion/);
});

test('client authorisation is explained beside the URL when it is on (#1853)', () => {
    // The URL alone does not open under client auth, and Tor Browser's failure for a missing key
    // is indistinguishable from the service being down.
    const on = withOnion({ url: URL, client_auth: true });
    assert.match(on, /Client authorisation is on/);
    assert.match(on, /onion-client-key/);
    // The WORDS, not the markup. htm strips a whitespace run containing a newline from each end of
    // a static text chunk, so a line break before the <span> renders "to,pithead onion-client-key"
    // — a defect both assertions above stay green on, because each matches one side of the join.
    // This drops the tags and puts NOTHING in their place, which is the load-bearing half: the
    // sibling in xvbview.test.mjs substitutes a space, and a space would re-join "to,<span>pithead"
    // into readable text and pass over the very defect this asserts against. Not a sanitiser — the
    // result is read by assert.match and never reaches a DOM.
    const words = on.split(/<[^>]*>/).join('');
    assert.match(words, /On a machine you can log in to, pithead onion-client-key prints it\./);
    // And is absent when it is off — the same render path, one boolean apart.
    assert.doesNotMatch(withOnion({ url: URL, client_auth: false }), /Client authorisation/);
});

test('the block never carries client-auth key material (#1853)', () => {
    // The container is not given the keys, so this pins the shape rather than the plumbing: a
    // payload that grew a key field would put it on the page, and nothing else would notice.
    const html = withOnion({
        url: URL,
        client_auth: true,
        client_privkey: 'PRIVKEY-SENTINEL',
        client_pubkey: 'PUBKEY-SENTINEL',
    });
    assert.doesNotMatch(html, /SENTINEL/);
});

test('the copy control keeps its name, and the confirmation has its own region (#1853)', () => {
    const html = withOnion({ url: URL, client_auth: false });
    // The button's accessible name IS its text, so the confirmation cannot live in the label: one
    // copy would leave the control named "Copied", a state rather than the action it performs.
    assert.match(
        html,
        /<button type="button" class="btn-range btn-reset">\s*Copy address\s*<\/button>/,
    );
    // The region is rendered EMPTY rather than conditionally: a live region inserted with its
    // message already inside it presents no content change, and announces nothing.
    assert.match(html, /<span role="status"><\/span>/);
});

// The render probe never invokes handlers, so the copy state machine is driven directly. setState
// is replaced rather than stubbed away, so each call's payload is observable in order.
const driveCopy = (clipboard) => {
    const component = new OnionUrl({ onion: { url: URL, client_auth: false } });
    const seen = [];
    component.setState = (patch) => {
        Object.assign(component.state, patch);
        seen.push(patch.copied);
    };
    const priorNavigator = globalThis.navigator;
    Object.defineProperty(globalThis, 'navigator', { value: { clipboard }, configurable: true });
    const restore = () =>
        Object.defineProperty(globalThis, 'navigator', {
            value: priorNavigator,
            configurable: true,
        });
    return { component, seen, restore };
};

test('the confirmation clears itself, so a second copy announces too (#1853)', async (t) => {
    mock.timers.enable({ apis: ['setTimeout'] });
    const { component, seen, restore } = driveCopy({ writeText: async () => {} });
    t.after(() => {
        mock.timers.reset();
        restore();
    });

    await component.copy();
    assert.deepEqual(seen, [true], 'a successful copy raises the confirmation');
    // Left standing, the region's content never changes again and every copy after the first is
    // silent to a screen reader. Coming down is what makes the next one an announcement.
    mock.timers.tick(CLEAR_MS);
    assert.deepEqual(seen, [true, false], 'the confirmation is still up after CLEAR_MS elapsed');
    assert.equal(component.state.copied, false);
});

test('a failed copy takes a standing confirmation down with it (#1853)', async (t) => {
    mock.timers.enable({ apis: ['setTimeout'] });
    const clipboard = { writeText: async () => {} };
    const { component, seen, restore } = driveCopy(clipboard);
    t.after(() => {
        mock.timers.reset();
        restore();
    });

    await component.copy();
    // The clipboard goes away under the operator — a page that lost its secure context, a denied
    // permission. The previous "Copied" must not read as this attempt's answer.
    clipboard.writeText = async () => {
        throw new Error('denied');
    };
    await component.copy();
    assert.deepEqual(seen, [true, false]);
    // And no timer from the failed attempt is left to fire.
    mock.timers.tick(CLEAR_MS);
    assert.deepEqual(seen, [true, false]);
});

test('copyText answers whether the clipboard actually took the text (#1853)', async () => {
    const taken = [];
    assert.equal(await copyText(URL, { writeText: async (t) => taken.push(t) }), true);
    assert.deepEqual(taken, [URL]);
});

test('copyText degrades instead of throwing where there is no clipboard (#1853)', async () => {
    // Not a secure context, or the test renderer: the button has to fall back to "select it by
    // hand", and the label must not claim a copy that never happened.
    assert.equal(await copyText(URL, undefined), false);
    assert.equal(await copyText(URL, {}), false);
    assert.equal(await copyText(URL, { writeText: 'not a function' }), false);
});

test('copyText answers false when the clipboard rejects (#1853)', async () => {
    const rejects = { writeText: async () => { throw new Error('denied'); } };
    assert.equal(await copyText(URL, rejects), false);
});
