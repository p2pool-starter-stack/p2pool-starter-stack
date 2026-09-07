// What the full-screen sync takeover TELLS the operator (#1886 gap 3, the copy half).
//
// A sibling file rather than rows in an existing one: there was no syncview test at all, and the
// nearest candidates are at or near their recorded ceilings in docs/dev/file-budget.tsv.
//
// These assert PROSE, which is the weakest kind of test there is, so each row below is written to
// fail for the reason it names rather than for any reason at all: every needle names the SUBJECT
// of the sentence (a bare /recovery/ or /apply/ would match a chain card, a future banner, or the
// word "applies" in unrelated copy), and the fixture deliberately carries a near-miss sibling —
// a Tari card whose own text contains "syncing" and a Monero card carrying a mode string — so a
// needle that has quietly widened to match the whole page is visible here rather than in review.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { SyncView } from "../../mining_dashboard/web/static/syncview.mjs";
import { renderToString } from "./helpers/render.mjs";

// A machine mid-sync, with the near-miss sibling text described above: the cards carry their own
// words so a needle can be shown to be scoped to the header rather than to the page.
const SYNCING = {
  monero: {
    percent: 41,
    state: "syncing",
    current: "1,200,000",
    target: "2,900,000",
    remaining: "1,700,000",
    mode: "Pruned",
    db_size: "58 GB",
  },
  tari: {
    percent: 8,
    state: "syncing",
    current: "40,000",
    target: "500,000",
    remaining: "460,000",
  },
};

const headerOf = (out) => {
  const m = out.match(/<div class="header-placeholder">([\s\S]*?)<\/div>/);
  assert.ok(m, "the sync screen has no header-placeholder block to read");
  return m[1];
};

test("the sync screen still leads with the headline the docs quote (#1886)", () => {
  // docs/dashboard.md quotes this sentence verbatim. Added copy must not silently retire it, or
  // the doc goes false in a file this change never touches.
  assert.match(headerOf(renderToString(SyncView({ sync: SYNCING }))), /System is currently synchronizing with the network\./);
});

test("the sync screen says workers wait for a STABLE window, not one good check (#1886 gap 3)", () => {
  // The mechanism: readmission gates on NodeHealthMonitor.healthy — reachable continuously for
  // NODE_RECOVERY_AFTER_SEC — which service/node_health.py documents as deliberately distinct
  // from "not down". Without this the operator sees a synced chain and an idle miner and has no
  // way to tell that from a fault. Both halves are asserted: that a window is named, and that
  // the "not on the first success" half is there, because the first half alone reads as a
  // promise that mining starts on the next poll.
  const header = headerOf(renderToString(SyncView({ sync: SYNCING })));
  assert.match(header, /workers are readmitted once the node has stayed reachable/);
  assert.match(header, /rather than on the first check that succeeds/);
  // The scope clause is load-bearing, not throat-clearing: `_apply_worker_rejection` has exactly
  // one call site and it sits under `if self.miner_released:`, a one-way latch that is False until
  // the sync gate first releases. A machine reaching this screen for the first time has no
  // rejected workers to readmit, so an unscoped sentence promises a wait that cannot happen on the
  // very path the screen is most often on. Asserted here so a future trim of the clause reddens.
  assert.match(header, /If the node went unreachable and is catching up again/);
});

test("the sync screen says a Tari-required change lands on apply, not live (#1886 gap 3)", () => {
  // TARI_REQUIRED is read at import (config/config.py), so it reaches the dashboard only when
  // apply recreates the container. This is the half the operator actually hit: they flipped the
  // setting and watched a screen that could not have known about it yet.
  const header = headerOf(renderToString(SyncView({ sync: SYNCING })));
  assert.match(header, /Whether Tari is required is read when\s+the dashboard starts/);
  assert.match(header, /takes effect once you apply the change/);
});

test("the screen promises it clears itself, so waiting is not mistaken for hanging (#1886)", () => {
  assert.match(headerOf(renderToString(SyncView({ sync: SYNCING }))), /clears itself once the required chains are ready/);
});

test("the added copy is in the HEADER, not smeared across the chain cards (#1886 narrowness)", () => {
  // The control for every row above: they read the header block only, so this pins that the
  // block is a real subset of the page. If the added text ever moves into a card, the rows above
  // keep passing while the screen changes shape — this is what notices.
  const out = renderToString(SyncView({ sync: SYNCING }));
  const header = headerOf(out);
  assert.ok(header.length < out.length, "header block is the whole page — the rows above prove nothing about placement");
  // The cards' own words are present on the page and absent from the header: that is what makes
  // "scoped to the header" a measurement rather than an assumption.
  assert.match(out, /Monero Sync/);
  assert.doesNotMatch(header, /Monero Sync/);
  assert.doesNotMatch(header, /blocks left/);
});
