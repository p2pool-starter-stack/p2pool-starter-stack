// Unit tests for the Configuration view's pure logic (#33):
// mining_dashboard/web/static/configlogic.mjs — flattening the masked config into form fields
// and folding edits back into the proposed config (secret sentinel semantics included).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  applyEdits,
  buildSections,
  isSecretSentinel,
  jsonSyntaxError,
  parseConfigJson,
  regroupCore,
} from "../../mining_dashboard/web/static/configlogic.mjs";

const CFG = {
  _docs: "reference blurb — never a form field",
  monero: {
    mode: "local",
    wallet_address: "4AAAA",
    prune: true,
    node_password: { __secret__: true },
    remote: { host: "node.example", rpc_port: 18081 },
  },
  p2pool: { pool: "mini", stratum_password: "" },
  dashboard: {
    auth: { username: "admin", password: { __secret__: true } },
    workers: [{ name: "rig1", host: "10.0.0.5", token: { __secret__: true } }],
  },
};

test("isSecretSentinel: only the exact sentinel shape", () => {
  assert.equal(isSecretSentinel({ __secret__: true }), true);
  for (const v of [null, "x", 1, ["__secret__"], { __secret__: false }, {}]) {
    assert.equal(isSecretSentinel(v), false, JSON.stringify(v));
  }
});

test("buildSections: one section per top-level object, _docs skipped, nesting flattened", () => {
  const sections = buildSections(CFG);
  assert.deepEqual(
    sections.map((s) => s.name),
    ["monero", "p2pool", "dashboard"],
  );
  const monero = sections[0];
  const keys = monero.fields.map((f) => f.key);
  assert.ok(keys.includes("monero.remote.rpc_port")); // nested objects walk down
  assert.ok(!keys.includes("_docs"));
});

test("buildSections: field types follow the JSON value", () => {
  const fields = Object.fromEntries(
    buildSections(CFG)
      .flatMap((s) => s.fields)
      .map((f) => [f.key, f]),
  );
  assert.equal(fields["monero.prune"].type, "boolean");
  assert.equal(fields["monero.remote.rpc_port"].type, "number");
  assert.equal(fields["monero.wallet_address"].type, "text");
  assert.equal(fields["p2pool.pool"].type, "select"); // fixed choices
  assert.deepEqual(fields["p2pool.pool"].options, ["main", "mini", "nano"]);
  assert.equal(fields["dashboard.auth.password"].type, "secret"); // sentinel → secret input
  assert.equal(fields["dashboard.auth.password"].value, "");
  // An UNSET secret arrives as "" and renders as a plain text field (nothing to keep).
  assert.equal(fields["p2pool.stratum_password"].type, "text");
});

test("buildSections: high-consequence fields carry their inline warning", () => {
  const fields = Object.fromEntries(
    buildSections(CFG)
      .flatMap((s) => s.fields)
      .map((f) => [f.key, f]),
  );
  assert.match(fields["p2pool.pool"].warning, /PPLNS window resets/);
  assert.match(fields["monero.wallet_address"].warning, /payout address/);
  assert.equal(fields["monero.prune"].warning, undefined);
});

test("applyEdits: edits land at their path with type coercion; the rest is untouched", () => {
  const sections = buildSections(CFG);
  const proposed = applyEdits(CFG, sections, {
    "p2pool.pool": "main",
    "monero.prune": "false",
    "monero.remote.rpc_port": "18089",
  });
  assert.equal(proposed.p2pool.pool, "main");
  assert.equal(proposed.monero.prune, false); // string → boolean
  assert.equal(proposed.monero.remote.rpc_port, 18089); // string → number
  assert.equal(proposed.monero.wallet_address, "4AAAA");
  assert.equal(CFG.p2pool.pool, "mini"); // the source config is never mutated
});

test("array values are not form fields and survive an edit round-trip verbatim (#172)", () => {
  // dashboard.workers is a list of per-rig descriptors — there is no form rendering for it, so
  // buildSections must skip it (a text field would mangle it into a string) and applyEdits must
  // carry it through untouched.
  const sections = buildSections(CFG);
  const keys = sections.flatMap((s) => s.fields.map((f) => f.key));
  assert.ok(!keys.some((k) => k.startsWith("dashboard.workers")));
  const proposed = applyEdits(CFG, sections, { "p2pool.pool": "main" });
  assert.deepEqual(proposed.dashboard.workers, CFG.dashboard.workers);
});

test("applyEdits: a blank secret keeps the sentinel; a typed one replaces it", () => {
  const sections = buildSections(CFG);
  const kept = applyEdits(CFG, sections, { "dashboard.auth.password": "" });
  assert.deepEqual(kept.dashboard.auth.password, { __secret__: true });
  const changed = applyEdits(CFG, sections, { "dashboard.auth.password": "new pass phrase" });
  assert.equal(changed.dashboard.auth.password, "new pass phrase");
});

test("applyEdits: garbage in a number field passes through for the host validator to reject", () => {
  const sections = buildSections(CFG);
  const proposed = applyEdits(CFG, sections, { "monero.remote.rpc_port": "lots" });
  assert.equal(proposed.monero.remote.rpc_port, "lots");
});

// --- Core-vs-sections regroup (#529, RATIFIED Wave-0) ---------------------------------------

const CORE_KEYS = ["monero.wallet_address", "p2pool.pool", "dashboard.auth.username"];

test("regroupCore: lifts core-key fields into one pinned group, out of their sections", () => {
  const { core, sections } = regroupCore(buildSections(CFG), CORE_KEYS);
  assert.deepEqual(
    core.map((f) => f.key).sort(),
    CORE_KEYS.slice().sort(),
  );
  // The lifted fields no longer appear in their natural section...
  const monero = sections.find((s) => s.name === "monero");
  assert.ok(!monero.fields.some((f) => f.key === "monero.wallet_address"));
  // ...but every OTHER field in that section is untouched.
  assert.ok(monero.fields.some((f) => f.key === "monero.prune"));
  const dashboard = sections.find((s) => s.name === "dashboard");
  assert.ok(!dashboard.fields.some((f) => f.key === "dashboard.auth.username"));
  assert.ok(dashboard.fields.some((f) => f.key === "dashboard.auth.password"));
});

test("regroupCore: a section left with no remaining fields is dropped, not shown empty", () => {
  // Every leaf of p2pool is core: the section itself should disappear from the regrouped list.
  const { sections } = regroupCore(buildSections(CFG), ["p2pool.pool", "p2pool.stratum_password"]);
  assert.ok(!sections.some((s) => s.name === "p2pool"));
});

test("regroupCore: no core keys (missing/empty config.core-keys.json) leaves every field in its section", () => {
  const original = buildSections(CFG);
  const { core, sections } = regroupCore(original, []);
  assert.deepEqual(core, []);
  assert.deepEqual(
    sections.map((s) => s.fields.length),
    original.map((s) => s.fields.length),
  );
});

test("regroupCore: workers.list isn't a field to begin with (array, #172) — it never appears, core or not", () => {
  const withWorkers = {
    ...CFG,
    workers: { list: [{ name: "rig1" }], api_auth: "none" },
  };
  const { core, sections } = regroupCore(buildSections(withWorkers), [
    ...CORE_KEYS,
    "workers.list",
  ]);
  assert.ok(!core.some((f) => f.key === "workers.list"));
  assert.ok(!sections.some((s) => s.fields.some((f) => f.key === "workers.list")));
});

// --- JSON mode's whole-config parse (#529) ----------------------------------------------------

test("parseConfigJson: valid JSON builds the same staged config shape applyEdits does", () => {
  const sections = buildSections(CFG);
  const viaForm = applyEdits(CFG, sections, { "p2pool.pool": "main" });
  const viaJson = parseConfigJson(JSON.stringify(viaForm));
  assert.deepEqual(viaJson, { config: viaForm });
});

test("parseConfigJson: a masked secret round-trips verbatim through the textarea (#508/#440)", () => {
  const out = parseConfigJson(JSON.stringify(CFG));
  assert.deepEqual(out.config.dashboard.auth.password, { __secret__: true });
});

test("parseConfigJson: malformed JSON surfaces a parse error", () => {
  assert.match(parseConfigJson("{not json").error, /Not valid JSON/);
});

test("parseConfigJson: a non-object (array, primitive) is rejected", () => {
  assert.match(parseConfigJson("[1, 2]").error, /JSON object/);
  assert.match(parseConfigJson("42").error, /JSON object/);
});

test("jsonSyntaxError: live check used for inline feedback while typing", () => {
  assert.equal(jsonSyntaxError(""), null); // still typing — not an error yet
  assert.equal(jsonSyntaxError('{"a": 1}'), null);
  assert.match(jsonSyntaxError("{not json"), /Not valid JSON/);
});
