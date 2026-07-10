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
  dashboard: { auth: { username: "admin", password: { __secret__: true } } },
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
