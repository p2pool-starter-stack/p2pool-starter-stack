// Unit tests for the shared stat-card primitives (mining_dashboard/web/static/statcards.mjs).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// Only the pure pieces live here; the components themselves are exercised through the rendered
// app in components.test.mjs, which is the lowest tier that proves they are actually wired up.
import assert from "node:assert/strict";
import { test } from "node:test";

import { nodeLocation } from "../../mining_dashboard/web/static/statcards.mjs";

test("nodeLocation names each node local or remote (#1040)", () => {
  assert.equal(nodeLocation(true), "Local");
  assert.equal(nodeLocation(false), "Remote");
});

test("nodeLocation never guesses Local when the payload does not say (#1040)", () => {
  // A dashboard serving a payload from before this shipped has no `local` key. "Local" is the one
  // answer that would send an operator to the wrong machine to fix a node that is not theirs, so
  // an absent or unusable flag must read as unknown rather than as the common case.
  for (const missing of [undefined, null, "", 0, "true", 1]) {
    assert.equal(nodeLocation(missing), "—", `${JSON.stringify(missing)} must not read as a location`);
  }
});
