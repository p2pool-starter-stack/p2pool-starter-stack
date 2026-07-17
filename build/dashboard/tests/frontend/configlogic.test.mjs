// Unit tests for the Configuration view's pure logic (#33):
// mining_dashboard/web/static/configlogic.mjs — flattening the masked config into form fields
// and folding edits back into the proposed config (secret sentinel semantics included).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  applyEdits,
  buildSections,
  classifyGroup,
  isSecretSentinel,
  jsonSyntaxError,
  LOGICAL_GROUPS,
  markEditable,
  nestSection,
  OTHER_GROUP,
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

test("buildSections: LOGICAL sections (#611), not one per top-level config key; _docs skipped, nesting flattened", () => {
  const sections = buildSections(CFG);
  // monero.wallet_address -> Wallets & payout; monero.mode/prune/node_password/remote.* -> Monero
  // node; p2pool.pool/stratum_password -> Mining; dashboard.auth.* -> Dashboard & access;
  // dashboard.workers is an array (skipped, #172) so it never pulls "Workers" into the list.
  assert.deepEqual(
    sections.map((s) => s.name),
    ["Wallets & payout", "Monero node", "Mining", "Dashboard & access"],
  );
  const moneroNode = sections.find((s) => s.name === "Monero node");
  const keys = moneroNode.fields.map((f) => f.key);
  assert.ok(keys.includes("monero.remote.rpc_port")); // nested objects walk down
  assert.ok(!keys.includes("_docs"));
});

test("buildSections: a config path split from its top-level key's other fields lands in a DIFFERENT logical section (#611)", () => {
  // dashboard.auth.username (Dashboard & access) and a hypothetical dashboard.energy.* leaf
  // (Energy) both live under the same top-level `dashboard` key but must not share a section —
  // that's the whole point of #611 over "one section per top-level key".
  const cfg = { ...CFG, dashboard: { ...CFG.dashboard, energy: { cost_per_kwh: 0.12 } } };
  const sections = buildSections(cfg);
  assert.ok(sections.some((s) => s.name === "Dashboard & access"));
  assert.ok(sections.some((s) => s.name === "Energy"));
  const energy = sections.find((s) => s.name === "Energy");
  assert.deepEqual(
    energy.fields.map((f) => f.key),
    ["dashboard.energy.cost_per_kwh"],
  );
});

test("classifyGroup: distinct monero.* leaves resolve to their own group, not a shared bare prefix", () => {
  assert.equal(classifyGroup("monero.data_dir"), "System / advanced");
  assert.equal(classifyGroup("monero.mode"), "Monero node");
});

// classifyGroup is first-match (no group's prefix is "more specific" than another's, by design —
// see the comment above LOGICAL_GROUPS). This test is what actually guarantees that design holds:
// no two groups may claim overlapping prefixes, so a real config path always resolves the same way
// regardless of LOGICAL_GROUPS' declaration order.
test("LOGICAL_GROUPS: no two groups claim overlapping prefixes", () => {
  const all = LOGICAL_GROUPS.flatMap((g) => g.prefixes.map((p) => ({ group: g.name, prefix: p })));
  const overlaps = [];
  for (const a of all) {
    for (const b of all) {
      if (a.group === b.group || a.prefix === b.prefix) continue;
      if (a.prefix === b.prefix || a.prefix.startsWith(`${b.prefix}.`)) {
        overlaps.push(`"${a.prefix}" (${a.group}) is inside "${b.prefix}" (${b.group})`);
      }
    }
  }
  assert.deepEqual(overlaps, []);
});

test("classifyGroup + buildSections: an unclaimed path renders in the catch-all Other group, not dropped", () => {
  assert.equal(classifyGroup("some_future_key.leaf"), OTHER_GROUP);
  const sections = buildSections({ ...CFG, some_future_key: { leaf: "x" } });
  const other = sections.find((s) => s.name === OTHER_GROUP);
  assert.ok(other, "an unclaimed field must still render, in the Other group");
  assert.deepEqual(
    other.fields.map((f) => f.key),
    ["some_future_key.leaf"],
  );
});

test("buildSections: nested underscore-prefixed docs keys (any depth) are skipped, not rendered as fields", () => {
  const cfg = { ...CFG, xmrig_proxy: { _docs: "legacy alias notes", enabled: true } };
  const keys = buildSections(cfg)
    .flatMap((s) => s.fields)
    .map((f) => f.key);
  assert.ok(!keys.includes("xmrig_proxy._docs"));
  assert.ok(keys.includes("xmrig_proxy.enabled"));
});

// buildSections must claim EVERY leaf path in the real config.reference.json — a new config key
// added there without a matching LOGICAL_GROUPS entry must fail this test loudly (land in Other)
// rather than silently vanish from the editor (#611's own stated requirement). Reference values
// are all scalars/objects/empty-arrays, so feeding the reference straight into buildSections
// walks the exact same shape the live merged config does.
test("buildSections: every config.reference.json leaf path resolves to a REAL logical group, not Other", () => {
  const reference = JSON.parse(
    readFileSync(new URL("../../../../config.reference.json", import.meta.url)),
  );
  const fields = buildSections(reference).flatMap((s) => s.fields);
  assert.ok(fields.length > 50, "sanity: the reference should produce many fields");
  const unclaimed = fields.filter((f) => classifyGroup(f.key) === OTHER_GROUP).map((f) => f.key);
  assert.deepEqual(unclaimed, [], "these config.reference.json paths need a LOGICAL_GROUPS entry");
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

test("regroupCore: lifts core-key fields into one pinned group, out of their (logical) sections", () => {
  const { core, sections } = regroupCore(buildSections(CFG), CORE_KEYS);
  assert.deepEqual(
    core.map((f) => f.key).sort(),
    CORE_KEYS.slice().sort(),
  );
  // monero.wallet_address was the ONLY field "Wallets & payout" had for this fixture — lifting it
  // empties the section, so it disappears entirely (same "no empty section" rule #529 already had).
  assert.ok(!sections.some((s) => s.name === "Wallets & payout"));
  // monero.prune stays behind in Monero node, untouched...
  const moneroNode = sections.find((s) => s.name === "Monero node");
  assert.ok(moneroNode.fields.some((f) => f.key === "monero.prune"));
  // ...dashboard.auth.username is lifted out of Dashboard & access, dashboard.auth.password stays.
  const dashboardAccess = sections.find((s) => s.name === "Dashboard & access");
  assert.ok(!dashboardAccess.fields.some((f) => f.key === "dashboard.auth.username"));
  assert.ok(dashboardAccess.fields.some((f) => f.key === "dashboard.auth.password"));
});

test("regroupCore: a section left with no remaining fields is dropped, not shown empty", () => {
  // Every leaf CFG.p2pool has (both Mining fields) is core: the section should disappear.
  const { sections } = regroupCore(buildSections(CFG), ["p2pool.pool", "p2pool.stratum_password"]);
  assert.ok(!sections.some((s) => s.name === "Mining"));
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

// --- Nested sub-groups within a logical section (#612) ----------------------------------------

const NOTIFY_CFG = {
  telegram: {
    enabled: true,
    bot_token: { __secret__: true },
    daily_summary_time: "08:00",
    events: { node_down: true, wallet_changed: true },
  },
  notifications: { ntfy: { url: "https://ntfy.sh/x" }, tor: true },
  healthchecks: { ping_url: { __secret__: true } },
};

test("nestSection: telegram.events / notifications.* / healthchecks.* pull out into subgroups, rest stays flat", () => {
  const notifications = buildSections(NOTIFY_CFG).find((s) => s.name === "Notifications");
  const { fields, subgroups } = nestSection(notifications);
  // The connection keys stay flat in the section...
  assert.deepEqual(
    fields.map((f) => f.key).sort(),
    ["telegram.bot_token", "telegram.daily_summary_time", "telegram.enabled"],
  );
  // ...the 26-toggle wall and the sinks each get their own nested group.
  const byLabel = Object.fromEntries(subgroups.map((g) => [g.label, g.fields.map((f) => f.key)]));
  assert.deepEqual(byLabel["Telegram events"].sort(), ["telegram.events.node_down", "telegram.events.wallet_changed"]);
  assert.deepEqual(byLabel["ntfy / webhook"].sort(), ["notifications.ntfy.url", "notifications.tor"]);
  assert.deepEqual(byLabel.Healthchecks, ["healthchecks.ping_url"]);
});

test("nestSection: a section with no SUBGROUPS entry (e.g. Monero node) is returned unchanged, empty subgroups", () => {
  const moneroNode = buildSections(CFG).find((s) => s.name === "Monero node");
  const out = nestSection(moneroNode);
  assert.deepEqual(out.fields, moneroNode.fields);
  assert.deepEqual(out.subgroups, []);
});

test("nestSection: an empty subgroup (no matching fields) is omitted, not rendered blank", () => {
  const notifications = buildSections({ telegram: { enabled: true } }).find((s) => s.name === "Notifications");
  const { subgroups } = nestSection(notifications);
  assert.deepEqual(subgroups, []); // no events, no notifications.*, no healthchecks in this fixture
});

// --- Editable-set membership / grey-out (#613) --------------------------------------------------

test("markEditable: only fields whose dotted key is in the editable set are marked editable", () => {
  const [marked] = markEditable(buildSections(CFG), ["monero.wallet_address"]);
  const byKey = Object.fromEntries(marked.fields.map((f) => [f.key, f.editable]));
  assert.equal(byKey["monero.wallet_address"], true);
});

test("markEditable: a missing/empty editable set fails CLOSED — every field non-editable", () => {
  for (const bad of [undefined, [], null]) {
    const sections = markEditable(buildSections(CFG), bad);
    for (const s of sections) for (const f of s.fields) assert.equal(f.editable, false, f.key);
  }
});

test("markEditable: host-only fields (e.g. dashboard.auth.password, a security/secret field) stay non-editable", () => {
  const editableKeys = ["monero.wallet_address", "p2pool.pool"]; // dashboard.auth.* deliberately absent
  const [, , , dashboardAccess] = markEditable(buildSections(CFG), editableKeys);
  const password = dashboardAccess.fields.find((f) => f.key === "dashboard.auth.password");
  assert.equal(password.editable, false);
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
