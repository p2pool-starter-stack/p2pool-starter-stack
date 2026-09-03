// #1231: what the XvB decision table's "Odds / 30d" cell says when there is no odds figure yet.
//
// A bare "—" there was indistinguishable from a measured zero. The column is filled from XvB's
// public winners feed, and the sync that fills the round-stats cache is ENABLE_XVB-gated
// (build_xvb_calc), so there are exactly two empty states and the payload already separates
// them: XvB never enabled (nothing will ever arrive until it is), and XvB on but not yet synced.
// The cell names which one it is.
//
// A new file rather than more of xvbview.test.mjs: that file sits at its recorded file-budget
// ceiling (431), and this gate's ceilings only ever go down.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { XvbTierBlock } from '../../mining_dashboard/web/static/xvbview.mjs';
import { render } from './helpers/render.mjs';

// Two tiers is enough to show the placeholder is per-row; the decision table renders one block
// per tier regardless. `hr`/`coeffDay` are the what-if inputs — held fixed across every case
// here so the only variable is the odds data itself.
const HR = 200_000;
const COEFF_DAY = 1e-7;

function calc({ enabled = true, odds = null, players = null } = {}) {
    return {
        enabled,
        max_fraction: 0.85,
        estimates_available: false,
        estimates_stale: false,
        estimates_source: enabled ? 'none' : 'published',
        estimates_published_date: '2026-08-01',
        current_tier: 'None',
        target_tier: 'None',
        target_threshold: 10_000,
        sustainable: true,
        realization_pct: null,
        realization_wins: null,
        note: 'An XvB tier is raffle status, not an XMR payout.',
        mode_note: null,
        tiers: [
            {
                name: 'Vip (10.00 kH/s+)', threshold: 10_000, expected_reward_year: 0.81,
                realized_reward_year: null, assumed_reward_year_range: null,
                win_odds_day: odds, players_avg: players,
            },
            {
                name: 'Whale (100.00 kH/s+)', threshold: 100_000, expected_reward_year: 6.17,
                realized_reward_year: null, assumed_reward_year_range: null,
                win_odds_day: odds, players_avg: players,
            },
        ],
    };
}

const draw = (c) => render(XvbTierBlock, { calc: c, hr: HR, coeffDay: COEFF_DAY });

// --- the two empty states are named, and named differently ------------------------------

test('#1231: a box that has never enabled XvB says so in the Odds cell, not with a dash', () => {
    const out = draw(calc({ enabled: false }));
    // Positive assertion anchored to the label, so it cannot pass off some other cell's text:
    // the two tiers each render "Odds / 30d needs XvB enabled".
    assert.match(out, /Odds \/ 30d needs XvB enabled/);
    assert.equal(out.match(/Odds \/ 30d needs XvB enabled/g).length, 2);
    // The old rendering, and the other state's wording, are both absent.
    assert.doesNotMatch(out, /Odds \/ 30d —/);
    assert.doesNotMatch(out, /awaiting sync/);
});

test('#1231: an enabled box with nothing synced yet says it is waiting, not that XvB is off', () => {
    const out = draw(calc({ enabled: true }));
    assert.match(out, /Odds \/ 30d awaiting sync/);
    assert.equal(out.match(/Odds \/ 30d awaiting sync/g).length, 2);
    assert.doesNotMatch(out, /Odds \/ 30d —/);
    assert.doesNotMatch(out, /needs XvB enabled/);
});

test('#1231: the two states are distinguishable — the same fixture differing only in `enabled`', () => {
    // The discriminator is the payload field the server already sets, so this pins that the cell
    // reads `enabled` and nothing else: one flag flipped, two different answers.
    const off = draw(calc({ enabled: false }));
    const on = draw(calc({ enabled: true }));
    assert.notEqual(off, on);
    assert.match(off, /needs XvB enabled/);
    assert.match(on, /awaiting sync/);
});

// --- the tooltip carries the reason, and it is state-specific ---------------------------

test('#1231: the empty cell tooltip explains the state it is actually in', () => {
    const off = draw(calc({ enabled: false }));
    assert.match(off, /XvB is off, so its winners feed is never read/);
    assert.doesNotMatch(off, /No round statistics are cached right now/);

    const on = draw(calc({ enabled: true }));
    assert.match(on, /No round statistics are cached right now/);
    assert.doesNotMatch(on, /XvB is off, so its winners feed is never read/);
});

// --- no regression: a real figure still renders, and the placeholders stay away ---------

test('#1231: a measured figure still renders, with the original tooltip and no placeholder', () => {
    // 0.84/day x 30 = 25.2 -> toPrecision(2) = 25; players_avg 8.2 renders as-is.
    const out = draw(calc({ enabled: true, odds: 0.84, players: 8.2 }));
    assert.match(out, /Odds \/ 30d ≈ 25 wins · 8\.2 players/);
    assert.doesNotMatch(out, /needs XvB enabled/);
    assert.doesNotMatch(out, /awaiting sync/);
    // The measured cell keeps the descriptive tooltip, not either waiting-state one.
    assert.match(out, /How often this tier's rounds pay out/);
    assert.doesNotMatch(out, /No round statistics are cached right now/);
});

test('#1231: the placeholder assertions can fail — the same probe over measured data', () => {
    // A negative control for the two tests above: if `Odds / 30d needs XvB enabled` could match
    // whatever the table renders, it would match here too. It does not, so a match there is a
    // reading of the placeholder and not of the probe.
    const measured = draw(calc({ enabled: false, odds: 0.84, players: 8.2 }));
    assert.doesNotMatch(measured, /Odds \/ 30d needs XvB enabled/);
    assert.doesNotMatch(measured, /Odds \/ 30d awaiting sync/);
    assert.match(measured, /Odds \/ 30d ≈ 25 wins/);
});

// --- the boundary the render condition actually tests -----------------------------------

test('#1231: a zero or absent rate is a waiting state, not a rendered zero', () => {
    // The cell keys on `oddsPer30d` being truthy, and xvbDecisionRows only sets it for
    // win_odds_day > 0. A zero rate is XvB reporting no rounds of that type in the window —
    // not "you will win zero times" — so it belongs in the waiting state, and a qualifier count
    // arriving without a rate must not drag a bare number onto the row on its own.
    const zero = draw(calc({ enabled: true, odds: 0, players: 8.2 }));
    assert.match(zero, /Odds \/ 30d awaiting sync/);
    assert.doesNotMatch(zero, /Odds \/ 30d ≈/);

    const playersOnly = draw(calc({ enabled: false, odds: null, players: 31.4 }));
    assert.match(playersOnly, /Odds \/ 30d needs XvB enabled/);
    assert.doesNotMatch(playersOnly, /31\.4 players/);
});

// --- the block-level note and the per-row cell must not contradict each other ------------

test('#1231: the disabled note no longer claims the column stays empty', () => {
    const out = draw(calc({ enabled: false }));
    assert.match(out, /id="xvb-disabled-note"/);
    // The note used to say the odds column "stays empty"; the rows now say what they wait for,
    // so the note says that instead. A doc/prose claim the rendering contradicts is the defect
    // this assertion exists to catch.
    assert.match(out, /names what it\s+is waiting for instead of a figure/);
    assert.doesNotMatch(out, /odds column needs the live winners feed, so it stays empty/);
});
