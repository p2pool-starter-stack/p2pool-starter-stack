// Unit tests for the shared stat-card primitives (mining_dashboard/web/static/statcards.mjs).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// Only the pure pieces live here; the components themselves are exercised through the rendered
// app in components.test.mjs, which is the lowest tier that proves they are actually wired up.
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
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

// --- No module may keep a private copy of a shared primitive (#1361) ------------------------
//
// xvbview.mjs carried a `const StatCard` byte-identical to the export above, justified in-file by
// a `workerview.mjs` InfoCard precedent that did not apply. Nothing caught it and nothing here
// could have: identical copies render identically, so no assertion over rendered output can tell
// them apart — which is why this law is enforced over the SOURCE. It proves the text (no sibling
// module re-declares one of these names) and NOT the behaviour (it cannot tell you a caller
// actually uses the import it holds). The names are read out of statcards.mjs itself, so a
// primitive added there is covered without editing this test.
const STATIC_DIR = new URL("../../mining_dashboard/web/static/", import.meta.url);
// `export` is part of the pattern: a sibling that re-declares AND exports a shared primitive is
// the same defect, and a bare `^(?:const|...)` alternation would step straight over it.
const DECL = "(?:export\\s+)?(?:const|let|var|function|class)";

test("no module keeps a private copy of a shared stat-card primitive (#1361)", () => {
  const shared = readFileSync(new URL("statcards.mjs", STATIC_DIR), "utf8");
  const EXPORTED = /^export\s+(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/gm;
  const names = [...shared.matchAll(EXPORTED)].map((m) => m[1]);
  // Anti-false-pass: a reformat that stopped the pattern matching would leave the sweep below
  // vacuously clean, which reads exactly like compliance. Add a name here when you export one.
  assert.deepEqual(names.sort(), ["MoreStats", "StatCard", "TariStatus", "nodeLocation"].sort());

  const offenders = [];
  for (const file of readdirSync(STATIC_DIR).filter((f) => f.endsWith(".mjs") && f !== "statcards.mjs")) {
    const body = readFileSync(new URL(file, STATIC_DIR), "utf8");
    for (const name of names) {
      if (new RegExp(`^${DECL}\\s+${name}\\b`, "m").test(body)) {
        offenders.push(`${file} declares its own ${name}`);
      }
    }
  }
  assert.deepEqual(offenders, [], `import these from statcards.mjs instead of re-declaring them`);
});
