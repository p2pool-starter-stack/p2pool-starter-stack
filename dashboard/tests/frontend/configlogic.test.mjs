// Unit tests for the Configuration view's pure logic (#33):
// mining_dashboard/web/static/configlogic.mjs — flattening the masked config into form fields
// and folding edits back into the proposed config (secret sentinel semantics included).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
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
  },
  workers: { list: [{ name: "rig1", host: "10.0.0.5", token: { __secret__: true } }] },
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
  // workers.list is an array (skipped, #172) so it never pulls "Workers" into the list.
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

// #1887: the four Tari node keys rendered under the group titled "Monero node", so an operator
// looking for where their Tari node is configured read the group titles, found no Tari, and
// concluded it could not be changed here. This sweeps the CLASS — every tari.* leaf the reference
// config declares, not just the four the issue named — so a Tari key added later cannot land back
// under Monero's title unnoticed.
test("classifyGroup: no tari.* key renders under the Monero node group (#1887)", () => {
  const reference = JSON.parse(
    readFileSync(new URL("../../../config.reference.json", import.meta.url)),
  );
  const tariKeys = buildSections(reference)
    .flatMap((s) => s.fields)
    .map((f) => f.key)
    .filter((k) => k.startsWith("tari."));
  // 11, counted from the reference, not from the four the issue named: a floor of 4 would still be
  // satisfied by a regression that stopped 7 of them rendering, and the class sweep below would
  // narrow to a spot check while staying green. Adding a tari.* key is meant to fail here.
  assert.equal(
    tariKeys.length,
    11,
    `the reference's tari.* leaf count changed (got ${tariKeys.length}) — update this floor and check the new key's group`,
  );
  assert.deepEqual(
    tariKeys.filter((k) => classifyGroup(k) === "Monero node"),
    [],
  );
  assert.equal(classifyGroup("tari.mode"), "Tari node");
  assert.equal(classifyGroup("tari.remote.host"), "Tari node");
  // Narrowness: a fix that swept every tari.* into the new group would fail these two.
  assert.equal(classifyGroup("tari.data_dir"), "System / advanced");
  assert.equal(classifyGroup("tari.wallet_address"), "Wallets & payout");
});

test("LOGICAL_GROUPS: the Tari node section renders directly under Monero's (#1887)", () => {
  const names = LOGICAL_GROUPS.map((g) => g.name);
  // A deleted "Tari node" gives LHS -1, which would need indexOf("Monero node") === -2 — impossible.
  // The other arm is not covered here: a deleted "Monero node" gives RHS 0, which passes if "Tari
  // node" happens to sit first. `classifyGroup("monero.mode") === "Monero node"` above is what
  // fails the moment the Monero group vanishes.
  assert.equal(names.indexOf("Tari node"), names.indexOf("Monero node") + 1);
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
  // A synthetic block: the two real nested docs keys (xmrig_proxy._docs, dashboard._workers_docs)
  // went with the deprecated aliases in 2.0.0 (#1832), and the rule outlived them.
  const cfg = { ...CFG, some_future_block: { _docs: "block notes", enabled: true } };
  const keys = buildSections(cfg)
    .flatMap((s) => s.fields)
    .map((f) => f.key);
  assert.ok(!keys.includes("some_future_block._docs"));
  assert.ok(keys.includes("some_future_block.enabled"));
});

// buildSections must claim EVERY leaf path in the real config.reference.json — a new config key
// added there without a matching LOGICAL_GROUPS entry must fail this test loudly (land in Other)
// rather than silently vanish from the editor (#611's own stated requirement). Reference values
// are all scalars/objects/empty-arrays, so feeding the reference straight into buildSections
// walks the exact same shape the live merged config does.
test("buildSections: every config.reference.json leaf path resolves to a REAL logical group, not Other", () => {
  const reference = JSON.parse(
    readFileSync(new URL("../../../config.reference.json", import.meta.url)),
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

test("array values are not form fields (#172)", () => {
  // workers.list is a list of per-rig descriptors — there is no form rendering for it, so
  // buildSections must skip it (a text field would mangle it into a string). Survival through
  // an edit is the candidate model's property now: untouched keys ride the candidate verbatim,
  // asserted in configview.test.mjs.
  const sections = buildSections(CFG);
  const keys = sections.flatMap((s) => s.fields.map((f) => f.key));
  assert.ok(!keys.some((k) => k.startsWith("workers.list")));
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

// --- Confirm-gated set (#719) -------------------------------------------------------------------

const fieldsByKey = (sections) =>
  Object.fromEntries(sections.flatMap((s) => s.fields).map((f) => [f.key, f]));

test("markEditable: a confirm-gated key is editable AND flagged confirm; host-only stays neither", () => {
  const byKey = fieldsByKey(markEditable(buildSections(CFG), [], ["monero.prune"]));
  assert.equal(byKey["monero.prune"].editable, true); // editable...
  assert.equal(byKey["monero.prune"].confirm, true); // ...but confirm-to-proceed
  assert.equal(byKey["monero.wallet_address"].editable, false); // host-only untouched
  assert.equal(byKey["monero.wallet_address"].confirm, false);
});

test("markEditable: editable wins over confirm — a key on both lists is freely editable, not gated", () => {
  const byKey = fieldsByKey(markEditable(buildSections(CFG), ["monero.prune"], ["monero.prune"]));
  assert.equal(byKey["monero.prune"].editable, true);
  assert.equal(byKey["monero.prune"].confirm, false); // no needless friction on a freely-editable key
});

// --- JSON mode's whole-config parse (#529) ----------------------------------------------------

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
