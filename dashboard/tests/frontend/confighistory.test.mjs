// Unit tests for mining_dashboard/web/static/confighistory.mjs — the change-history vocabulary
// (STATUS_META, HistoryRow) split out of workerview.mjs, plus the config-provenance line (#1345).
//
// New file: workerview.test.mjs is at its file-budget ceiling. Rendering uses the dependency-free
// vnode walker (helpers/render.mjs) — no DOM, no npm deps. Run with: node --test dashboard/tests/frontend/
//
// The line under test is the one place a rig's own account of itself reaches the operator's screen,
// so the assertions are about what it may and may not CLAIM, not about markup:
//   - silence when the rig cannot answer (never the word "unknown");
//   - "restored" never phrased as someone having edited the rig;
//   - "unrecorded" never phrased as a change having happened.
import assert from "node:assert/strict";
import { test } from "node:test";

import { ConfigProvenance, HistoryRow, STATUS_META } from "../../mining_dashboard/web/static/confighistory.mjs";
import { configOriginNote } from "../../mining_dashboard/web/static/workerlogic.mjs";
import { renderToString } from "./helpers/render.mjs";

const META = {
  revision: "a1b2c3d4e5f60718",
  changed_at: "2026-08-20T11:22:33Z",
  source: "control",
  last_change_id: "0f1e2d3c4b5a6978",
};

// --- The line renders nothing when the rig said nothing -----------------------------------

for (const [label, origin] of [
  ["no RigForge at all", null],
  ["block absent", undefined],
  ["a verdict token we do not know", "compromised"],
]) {
  test(`ConfigProvenance is silent: ${label}`, () => {
    // Silence, not "unknown": a rig too old to serve the block has made no claim, and rendering
    // one would invent a suspicion the payload does not support.
    assert.equal(renderToString(ConfigProvenance({ origin, meta: null })), "");
  });
}

// --- Each verdict says the right thing, and only that ---------------------------------------

test("here reads as ours and stays calm", () => {
  const out = renderToString(ConfigProvenance({ origin: "here", meta: META }));
  assert.match(out, /Last changed from this dashboard/);
  assert.match(out, /text-muted/);
  assert.doesNotMatch(out, /status-warn/);
});

test("elsewhere is flagged and never claimed as ours", () => {
  const out = renderToString(ConfigProvenance({ origin: "elsewhere", meta: META }));
  assert.match(out, /Last changed from another dashboard/);
  assert.match(out, /status-warn/);
  // The distinction that matters: a control change with an id we never minted must NOT be
  // presented as ours. `here` and `elsewhere` differ only by that comparison server-side, so
  // the two lines must not be confusable on screen either.
  assert.doesNotMatch(out, /from this dashboard/);
  const note = configOriginNote("elsewhere", META);
  assert.match(note.title, /no record of/);
});

test("rig edits are flagged — noticing one is the whole point of the feature", () => {
  const out = renderToString(ConfigProvenance({ origin: "rig", meta: { ...META, source: "local" } }));
  assert.match(out, /Last changed on the rig itself/);
  assert.match(out, /status-warn/);
});

test("restored never accuses a rig that rolled itself back", () => {
  const note = configOriginNote("restored", { ...META, source: "restore" });
  assert.match(note.label, /restored from a saved config/i);
  // RigForge stamps `restore` for its OWN automatic rollback, so neither the label nor the
  // tooltip may say a person did it.
  assert.doesNotMatch(note.label + note.title, /\b(you|someone|operator|edited on the rig)\b/i);
  assert.match(note.title, /fails to hold/);
});

test("unrecorded claims no change happened and no change did not", () => {
  const note = configOriginNote("unrecorded", { revision: META.revision });
  assert.match(note.label, /No recorded config change/);
  // A never-changed rig and one edited underneath RigForge are indistinguishable from here, so
  // the tooltip must own that ambiguity rather than pick a side.
  assert.match(note.title, /never been changed/);
  assert.match(note.title, /outside RigForge/);
});

// --- The tooltip carries the evidence, not just the verdict ---------------------------------

test("the tooltip carries the revision, and does not repeat the visible timestamp", () => {
  const note = configOriginNote("here", META);
  assert.match(note.title, /a1b2c3d4e5f60718/);
  // changed_at is rendered inline by ConfigProvenance, so the tooltip must not say it again.
  assert.doesNotMatch(note.title, /2026-08-20T11:22:33Z/);
  assert.match(renderToString(ConfigProvenance({ origin: "here", meta: META })), /2026-08-20T11:22:33Z/);
});

test("a fresh rig's revision-only meta still yields a usable tooltip", () => {
  const note = configOriginNote("unrecorded", {
    revision: "beefbeefbeefbeef",
    changed_at: null,
    source: null,
    last_change_id: null,
  });
  assert.match(note.title, /beefbeefbeefbeef/);
});

// --- What moved out of workerview.mjs still behaves ------------------------------------------

test("STATUS_META still maps every outcome workerview renders", () => {
  for (const key of ["applied", "accepted", "pending", "rejected", "rolled_back", "failed", "error", "noop", "throttled"]) {
    assert.ok(STATUS_META[key].label, `${key} has a label`);
    assert.ok(STATUS_META[key].cls, `${key} has a variant`);
  }
});

test("HistoryRow lists a config diff by its keys and an upgrade by its version", () => {
  const cfg = renderToString(
    HistoryRow({ row: { status: "applied", changes: { DONATION: 5, max_temp_c: 70 }, applied_at: "x" } }),
  );
  assert.match(cfg, /DONATION, max_temp_c/);
  assert.match(cfg, /Applied/);
  const up = renderToString(
    HistoryRow({ row: { status: "noop", type: "upgrade", changes: { version: "1.10.0" } } }),
  );
  assert.match(up, /upgrade → 1\.10\.0/);
  assert.match(up, /Already up to date/);
});
