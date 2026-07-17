// Unit tests for Worker Inspect's writable-config editor logic (#518):
// mining_dashboard/web/static/workerlogic.mjs — flattening the writable allowlist + last-applied
// config into table rows, and folding table/JSON edits back into the `changes` diff.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildFields,
  buildTableChanges,
  jsonSyntaxError,
  parseJsonChanges,
} from "../../mining_dashboard/web/static/workerlogic.mjs";

const KEYS = ["DONATION", "max_temp_c", "watchdog", "pools", "token"];
const APPLIED = {
  DONATION: 5,
  max_temp_c: 70,
  watchdog: true,
  pools: [{ url: "pool.example:3333" }],
  token: { __secret__: true },
};

// --- buildFields --------------------------------------------------------------------------

test("buildFields: one row per writable key, typed off the last-applied value", () => {
  const fields = Object.fromEntries(buildFields(KEYS, APPLIED).map((f) => [f.key, f]));
  assert.equal(fields.DONATION.type, "number");
  assert.equal(fields.DONATION.value, 5);
  assert.equal(fields.max_temp_c.type, "number");
  assert.equal(fields.watchdog.type, "boolean");
  assert.equal(fields.watchdog.value, true);
  assert.equal(fields.pools.type, "json");
  assert.match(fields.pools.value, /pool\.example:3333/);
});

test("buildFields: a never-applied key gets an empty JSON row, not a crash", () => {
  const fields = Object.fromEntries(buildFields(KEYS, {}).map((f) => [f.key, f]));
  assert.equal(fields.DONATION.type, "json");
  assert.equal(fields.DONATION.value, "");
});

test("buildFields: a masked token sentinel renders as a secret row, never raw JSON (#508)", () => {
  const fields = Object.fromEntries(buildFields(KEYS, APPLIED).map((f) => [f.key, f]));
  assert.equal(fields.token.type, "secret");
  assert.equal(fields.token.value, ""); // blank prefill — the sentinel itself never reaches the row
});

// --- buildTableChanges ---------------------------------------------------------------------

test("buildTableChanges: only touched rows enter the diff", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, { DONATION: "6" });
  assert.deepEqual(changes, { DONATION: 6 });
});

test("buildTableChanges: a row typed back to its original value drops out of the diff", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, { DONATION: "5", max_temp_c: "75" });
  assert.deepEqual(changes, { max_temp_c: 75 });
});

test("buildTableChanges: boolean and JSON sub-rows coerce back to real types", () => {
  const fields = buildFields(KEYS, APPLIED);
  const changes = buildTableChanges(fields, {
    watchdog: "false",
    pools: '[{"url":"pool2.example:3333"}]',
  });
  assert.deepEqual(changes, { watchdog: false, pools: [{ url: "pool2.example:3333" }] });
});

test("buildTableChanges: an unparsable JSON sub-row throws for the caller to surface", () => {
  const fields = buildFields(KEYS, APPLIED);
  assert.throws(() => buildTableChanges(fields, { pools: "{not json" }));
});

test("buildTableChanges: a blank secret row leaves the masked token alone; a typed one replaces it (#508)", () => {
  const fields = buildFields(KEYS, APPLIED);
  assert.deepEqual(buildTableChanges(fields, { token: "" }), {});
  assert.deepEqual(buildTableChanges(fields, { token: "new-token-value" }), {
    token: "new-token-value",
  });
});

// --- parseJsonChanges / jsonSyntaxError -----------------------------------------------------

test("parseJsonChanges: valid JSON builds the same shape of changes object as the table", () => {
  const out = parseJsonChanges('{"DONATION": 6}', KEYS);
  assert.deepEqual(out, { changes: { DONATION: 6 } });
});

test("parseJsonChanges: a masked token round-trips verbatim unless the operator replaces it (#508)", () => {
  const text = JSON.stringify({ token: { __secret__: true } });
  const out = parseJsonChanges(text, KEYS);
  assert.deepEqual(out.changes, { token: { __secret__: true } }); // untouched — passes through as-is
});

test("parseJsonChanges: malformed JSON surfaces a parse error", () => {
  assert.match(parseJsonChanges("{not json", KEYS).error, /Not valid JSON/);
});

test("parseJsonChanges: empty object and non-writable keys are rejected", () => {
  assert.match(parseJsonChanges("{}", KEYS).error, /non-empty/);
  assert.match(parseJsonChanges('{"nope": 1}', KEYS).error, /Not writable: nope/);
});

test("jsonSyntaxError: live check used for inline feedback while typing", () => {
  assert.equal(jsonSyntaxError(""), null); // still typing — not an error yet
  assert.equal(jsonSyntaxError("  "), null);
  assert.equal(jsonSyntaxError('{"a": 1}'), null);
  assert.match(jsonSyntaxError("{not json"), /Not valid JSON/);
});
