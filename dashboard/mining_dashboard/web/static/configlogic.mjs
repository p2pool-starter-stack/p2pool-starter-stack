// Pure logic for the Configuration view (#33), kept DOM-free so node --test covers it.
//
// GET /api/config returns the live config.json with every set secret masked to the
// {__secret__: true} sentinel, plus _core_keys — the wizard's core-key shortlist
// (config.core-keys.json, #502/#529), the SAME shared artifact, not a hand-maintained duplicate —
// and _editable_keys (#613), the config paths the control gate will actually commit (see
// markEditable below). buildSections groups the flattened config into LOGICAL sections (#611) —
// display groups an operator recognizes (Wallets & payout, Monero node, …), not "one section per
// top-level config.json key" — so a 14-key grab-bag like `dashboard.*` splits across the sections
// it actually belongs to. regroupCore (#529) then pulls the core-key fields out of THOSE sections
// into one pinned group on top, mirroring the RATIFIED Wave-0 decision. applyEdits folds the
// user's edits back into a proposed config for POST /api/control/preview — it takes the flat field
// list regardless of which display section it renders in, so config.json itself, the staged
// preview, and the gate are all untouched by this display-only regroup. A secret left blank keeps
// its sentinel — the server swaps it for the live value ("unchanged").

import { isHidden } from "./confighidden.mjs";

export const SECRET_HINT = "set — leave blank to keep";

export function isSecretSentinel(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v) && v.__secret__ === true;
}

// Fixed-choice fields; everything else renders from its JSON type.
const FIELD_OPTIONS = {
  "monero.mode": ["local", "remote"],
  "tari.mode": ["local", "remote"],
  "p2pool.pool": ["main", "mini", "nano"],
  "workers.api_auth": ["none", "name", "token"],
  "xvb.donation_level": ["auto", "donor", "vip", "whale", "mega"],
};

// Inline warnings for high-consequence fields, shown before any preview round-trip. The pool
// text carries describe_change's P2POOL_FLAGS warning; the wallet texts its DEST messages.
const FIELD_WARNINGS = {
  "p2pool.pool":
    "P2Pool sidechain changing — p2pool re-syncs the new sidechain and your PPLNS window resets (XvB shares reset too).",
  "monero.wallet_address":
    "Monero payout address is changing — future mining rewards go to the new address.",
  "tari.wallet_address":
    "Tari payout address is changing — future merge-mining rewards go to the new address.",
};

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function walk(node, path, out) {
  for (const [key, value] of Object.entries(node)) {
    // Underscore-prefixed keys are metadata/docs, not config, at ANY depth. The two nested ones
    // this guarded (xmrig_proxy._docs, dashboard._workers_docs) went with the deprecated aliases in
    // 2.0.0 (#1832); the rule stays because the top-level _docs and any future nested one need it,
    // and without it they'd render as stray text
    // fields and, worse, fall into the catch-all "Other" logical group (#611) since no group
    // claims a docs blob.
    if (key.startsWith("_")) continue;
    const p = [...path, key];
    const dotted = p.join(".");
    if (isPlainObject(value) && !isSecretSentinel(value)) {
      walk(value, p, out);
      continue;
    }
    // Array values (workers.list, #506) have no form rendering: skip them so they can't be
    // mangled into a string by a text field. applyEdits clones the whole config and only folds
    // TOUCHED fields back, so a skipped array survives the round trip verbatim.
    if (Array.isArray(value)) continue;
    const field = { path: p, key: dotted, warning: FIELD_WARNINGS[dotted] };
    if (isSecretSentinel(value)) Object.assign(field, { type: "secret", value: "" });
    else if (typeof value === "boolean") Object.assign(field, { type: "boolean", value });
    else if (typeof value === "number") Object.assign(field, { type: "number", value });
    else if (FIELD_OPTIONS[dotted])
      Object.assign(field, {
        type: "select",
        value: String(value ?? ""),
        options: FIELD_OPTIONS[dotted],
      });
    else Object.assign(field, { type: "text", value: String(value ?? "") });
    out.push(field);
  }
}

// Logical section groups (#611): a display-layer map from a section name an operator recognizes
// to the config-path PREFIXES it pulls fields from — config.json itself is unchanged, this only
// changes which <details> a field renders under. A field matches a prefix if its dotted key
// equals the prefix or starts with `prefix + "."`. Every prefix below names a SPECIFIC leaf or
// object, never a bare top-level key another group also reaches into (e.g. no group lists a bare
// "dashboard", even though six different groups claim different dashboard.* leaves) — so prefixes
// never overlap across groups and first-match is unambiguous; classifyGroup's own test asserts
// that invariant directly. Any leaf no group claims renders in the catch-all "Other" group below
// (never silently dropped) — buildSections' own test suite asserts every config.reference.json
// path resolves to a REAL group, so a new key can't slip into "Other" unnoticed either. The one
// exception is a HIDDEN path (confighidden.mjs, #1850), dropped below before any of this runs —
// `ssh.*` has no group entry BECAUSE it can never render, not the other way round.
export const OTHER_GROUP = "Other";
export const LOGICAL_GROUPS = [
  {
    name: "Wallets & payout",
    prefixes: [
      "monero.wallet_address",
      "monero.view_key",
      "monero.payout_scan_height",
      "tari.wallet_address",
      "tari.view_key",
      "tari.spend_public_key",
      "tari.payout_scan_birthday",
    ],
  },
  {
    name: "Monero node",
    prefixes: [
      "monero.mode",
      "monero.node_username",
      "monero.node_password",
      "monero.prune",
      "monero.remote",
      "monero.rpc_lan_access",
      "monero.zmq_lan_access",
      "monero.clearnet_initial_sync",
    ],
  },
  {
    // The Tari node's own section (#1887), directly under Monero's. These four lived in "Monero
    // node" on the reasoning that two chains share one node section; an operator looking for where
    // their Tari node is configured read the group titles, found no Tari, and concluded it could
    // not be changed here. Its resource knobs (tari.mem_limit, tari.data_dir) stay in "System /
    // advanced" beside monero's — the split follows what a field IS, not which chain it names.
    name: "Tari node",
    prefixes: ["tari.mode", "tari.remote", "tari.grpc_lan_access", "tari.clearnet_initial_sync"],
  },
  {
    name: "Mining",
    prefixes: [
      "p2pool.pool",
      "p2pool.stratum_bind",
      "p2pool.stratum_port",
      "p2pool.stratum_password",
      "p2pool.stratum_tls",
      "p2pool.clearnet",
      "proxy",
      "xvb",
      "local_miner",
      "dashboard.tari_required",
      "dashboard.fail_closed",
    ],
  },
  { name: "Workers", prefixes: ["workers"] },
  {
    name: "Dashboard & access",
    prefixes: [
      "dashboard.secure",
      "dashboard.host",
      "dashboard.expose_public_ip",
      "dashboard.port",
      "dashboard.timezone",
      "dashboard.auth",
      "dashboard.onion",
      "dashboard.control",
    ],
  },
  { name: "Notifications", prefixes: ["telegram", "notifications", "healthchecks"] },
  { name: "Energy", prefixes: ["dashboard.energy"] },
  {
    name: "Alerts & thresholds",
    prefixes: ["dashboard.hashrate_drop_threshold", "dashboard.hashrate_drop_minutes"],
  },
  {
    name: "System / advanced",
    prefixes: [
      "monero.mem_limit",
      "monero.data_dir",
      "monero.prep_blocks_threads",
      "monero.out_peers",
      "tari.mem_limit",
      "tari.data_dir",
      "p2pool.data_dir",
      "tor",
      "dashboard.data_dir",
      "dashboard.check_for_updates",
      "network",
    ],
  },
];

export function classifyGroup(key) {
  for (const g of LOGICAL_GROUPS) {
    for (const p of g.prefixes) {
      if (key === p || key.startsWith(`${p}.`)) return g.name;
    }
  }
  return OTHER_GROUP;
}

// Flatten the masked config into LOGICAL sections (#611): every leaf field, whatever top-level
// config.json key it lives under, bucketed by classifyGroup above. Section order follows
// LOGICAL_GROUPS, with "Other" last so an unclaimed key is visible, not hidden at the top.
// Non-object top-level keys (e.g. a _docs string) are left out of the form but survive untouched
// in the proposed config; underscore-prefixed keys (_core_keys, _editable_keys, #529/#613) are
// metadata, not config, and are skipped the same way _docs always was.
export function buildSections(cfg) {
  const fields = [];
  for (const [name, value] of Object.entries(cfg || {})) {
    if (name.startsWith("_") || !isPlainObject(value)) continue;
    walk(value, [name], fields);
  }
  const byGroup = new Map();
  for (const g of LOGICAL_GROUPS) byGroup.set(g.name, []);
  byGroup.set(OTHER_GROUP, []);
  for (const f of fields) if (!isHidden(f.key)) byGroup.get(classifyGroup(f.key)).push(f);
  const sections = [];
  for (const [name, groupFields] of byGroup)
    if (groupFields.length) sections.push({ name, fields: groupFields });
  return sections;
}

function _setPath(cfg, path, value) {
  let node = cfg;
  for (const key of path.slice(0, -1)) node = node[key];
  node[path.at(-1)] = value;
}

// The proposed config: the fetched (masked) config with the edits applied. Booleans/numbers are
// coerced back from input strings (garbage in a number field is passed through for the host-side
// validator to reject with its real message); a blank secret keeps its sentinel.
// The core-vs-sections regroup (#529, RATIFIED Wave-0): lift every field whose dotted key is in
// the core shortlist out of its natural section into one pinned `core` group; the same sections
// keep every OTHER field (never emptied outright — the shortlist is a handful of keys against ~94
// leaves). workers.list isn't a leaf (buildSections already skips arrays, #172), so it never
// produces a field to lift — it stays core-in-spirit only, exactly like the wizard treats it.
// coreKeys missing/empty degrades to no core group; every field still renders in its section.
export function regroupCore(sections, coreKeys) {
  const coreSet = new Set(coreKeys || []);
  const core = sections.flatMap((s) => s.fields).filter((f) => coreSet.has(f.key));
  const rest = sections
    .map((s) => ({ name: s.name, fields: s.fields.filter((f) => !coreSet.has(f.key)) }))
    .filter((s) => s.fields.length);
  return { core, sections: rest };
}

// Nested sub-groups within a logical section (#612): a noisy cluster of fields — telegram.events'
// 26 toggles, the notification sinks, healthchecks — collapses into its own one-level-deep
// <details>, collapsed by default, instead of dominating the section's flat field list. Keyed by
// the OWNING SECTION's name so only sections listed here get sub-grouping; everything else's
// fields stay flat, unchanged from before. A field matches a subgroup the same way classifyGroup
// matches a logical group (exact key or `prefix + "."`); fields claimed by a subgroup are removed
// from the section's own `fields` so they render exactly once.
const SUBGROUPS = {
  Notifications: [
    { label: "Telegram events", prefix: "telegram.events" },
    { label: "ntfy / webhook", prefix: "notifications" },
    { label: "Healthchecks", prefix: "healthchecks" },
  ],
};

export function nestSection(section) {
  const defs = SUBGROUPS[section.name];
  if (!defs) return { name: section.name, fields: section.fields, subgroups: [] };
  const claimed = new Set();
  const subgroups = defs
    .map((d) => {
      const fields = section.fields.filter(
        (f) => f.key === d.prefix || f.key.startsWith(`${d.prefix}.`),
      );
      for (const f of fields) claimed.add(f.key);
      return { label: d.label, fields };
    })
    .filter((g) => g.fields.length);
  return {
    name: section.name,
    fields: section.fields.filter((f) => !claimed.has(f.key)),
    subgroups,
  };
}

// Editable-set membership (#613): the control gate only ever commits a fixed allowlist of config
// paths (pithead's CONTROL_DASHBOARD_EDITABLE_KEYS, plus the dashboard.energy special-case, #504)
// — everything else is refused at commit no matter what the form sends. Rather than let an
// operator edit a host-only field and find out at Save, mark it non-editable up front so the view
// can grey it out and never wire an onChange for it (belt-and-suspenders: the gate still refuses
// regardless). `editableKeys` is `_editable_keys` on the fetched config (#613), the same
// underscore-metadata convention `_core_keys` uses, computed server-side from the SAME allowlist
// the gate enforces (control_service.EDITABLE_ENV_KEY_PATHS, drift-guarded against pithead's
// CONTROL_DASHBOARD_EDITABLE_KEYS). A missing/empty set fails CLOSED — nothing is marked
// editable — rather than defaulting to "everything editable" and silently reintroducing the
// edit-then-reject problem this feature exists to remove.
//
// `confirmKeys` is `_confirm_keys` (#719): the operationally-disruptive paths the gate WILL commit,
// but only behind a type-to-confirm. They render editable (not greyed) and carry `confirm: true` so
// the field can show a "confirm to proceed" affordance instead of the "host-only" one. A key on
// both lists is treated as freely editable (editable wins); the gate is still the authority.
export function markEditable(sections, editableKeys, confirmKeys) {
  const editable = new Set(editableKeys || []);
  const confirm = new Set(confirmKeys || []);
  return sections.map((s) => ({
    name: s.name,
    fields: s.fields.map((f) => {
      const isConfirm = !editable.has(f.key) && confirm.has(f.key);
      return { ...f, editable: editable.has(f.key) || isConfirm, confirm: isConfirm };
    }),
  }));
}

// JSON mode's own path (#529): the textarea holds the WHOLE candidate config (not a diff, unlike
// Worker Inspect's writable-key changes, #518) — parse it into the same shape applyEdits produces,
// so either mode can POST straight to /api/control/preview. Returns { config } or { error }.
export function parseConfigJson(text) {
  let cfg;
  try {
    cfg = JSON.parse(text);
  } catch {
    return { error: "Not valid JSON." };
  }
  if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
    return { error: "Enter a JSON object." };
  }
  return { config: cfg };
}

// Live syntax check for the JSON textarea, surfaced inline as the operator types (not only on
// Save). Blank is not an error yet — the operator hasn't finished typing. Shared with
// workerlogic.mjs's JSON mode (re-exported from there) so both editors give the same feedback.
export function jsonSyntaxError(text) {
  if (!text.trim()) return null;
  try {
    JSON.parse(text);
    return null;
  } catch {
    return "Not valid JSON.";
  }
}
