// Render tests for the configuration editor (Issue #33) — the pure pieces only: the flattener,
// the field-typing rules, the section grouping, and the preview modal's DEST styling. The
// class component's fetch/poll flow is network-bound and lives at tier 3/4.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import {
  ConfigForm,
  Field,
  fieldRows,
  isSecretSentinel,
  PreviewModal,
} from "../../mining_dashboard/web/static/config-editor.mjs";
import { App } from "../../mining_dashboard/web/static/components.mjs";
import { render } from "./helpers/render.mjs";

const CFG = {
  monero: { mode: "local", prune: true, node_password: { __secret__: true } },
  p2pool: { pool: "mini", stratum_password: "" },
  dashboard: { auth: { username: "admin", password: { __secret__: true } } },
  proxy: { donate_level: 0 },
};

// --- fieldRows -------------------------------------------------------------------------

test("fieldRows flattens nested config into dotted leaf rows", () => {
  const rows = fieldRows(CFG);
  const keys = rows.map((r) => r.key);
  assert.ok(keys.includes("monero.prune"));
  assert.ok(keys.includes("dashboard.auth.username"));
  assert.equal(rows.find((r) => r.key === "p2pool.pool").value, "mini");
});

test("fieldRows treats the secret sentinel as a leaf, not a section", () => {
  const rows = fieldRows(CFG);
  const secret = rows.find((r) => r.key === "monero.node_password");
  assert.ok(isSecretSentinel(secret.value));
});

test("fieldRows skips the _docs banner key", () => {
  const rows = fieldRows({ _docs: "reference banner", monero: { prune: true } });
  assert.deepEqual(
    rows.map((r) => r.key),
    ["monero.prune"],
  );
});

// --- Field typing ----------------------------------------------------------------------

const field = (key, value, edited) =>
  render(Field, { row: { path: key.split("."), key, value }, edited, onEdit: () => {} });

test("a set secret renders as a password input with the leave-blank hint", () => {
  const html = field("dashboard.auth.password", { __secret__: true });
  assert.match(html, /type="password"/);
  assert.match(html, /set — leave blank to keep/);
});

test("booleans render as checkboxes, numbers as number inputs", () => {
  assert.match(field("monero.prune", true), /type="checkbox" checked/);
  assert.match(field("proxy.donate_level", 0), /type="number"/);
});

test("the pool field is a select carrying its PPLNS/XvB-reset warning", () => {
  const html = field("p2pool.pool", "mini");
  assert.match(html, /<select/);
  for (const pool of ["main", "mini", "nano"]) assert.match(html, new RegExp(pool));
  assert.match(html, /PPLNS window resets/);
});

test("an unset secret-named key still renders as a password input", () => {
  assert.match(field("p2pool.stratum_password", ""), /type="password"/);
});

// --- ConfigForm ------------------------------------------------------------------------

test("ConfigForm groups fields into one card per top-level section", () => {
  const html = render(ConfigForm, { cfg: CFG, edits: {}, onEdit: () => {} });
  for (const section of ["monero", "p2pool", "dashboard", "proxy"]) {
    assert.match(html, new RegExp(`<h4>${section}</h4>`));
  }
  assert.match(html, /config-section/);
});

// --- PreviewModal ----------------------------------------------------------------------

const PREVIEW = {
  id: "abc",
  status: "previewed",
  destructive: true,
  changes: [
    { flag: "INFO", key: "PROXY_DONATE_LEVEL", msg: "donate level 0 -> 1" },
    { flag: "DEST", key: "P2POOL_FLAGS", msg: "sidechain changes; PPLNS resets" },
  ],
};

test("PreviewModal styles DEST rows as warnings and flags the confirm button", () => {
  const html = render(PreviewModal, {
    result: PREVIEW,
    busy: false,
    onConfirm: () => {},
    onCancel: () => {},
  });
  assert.match(html, /change-dest/);
  assert.match(html, /change-info/);
  assert.match(html, /PPLNS resets/);
  assert.match(html, /Apply \(disruptive\)/); // destructive commit is labelled as such
});

test("PreviewModal with no changes offers no apply button", () => {
  const html = render(PreviewModal, {
    result: { ...PREVIEW, changes: [], destructive: false },
    busy: false,
    onConfirm: () => {},
    onCancel: () => {},
  });
  assert.match(html, /No configuration changes detected/);
  assert.doesNotMatch(html, /btn-confirm/);
});

// --- App wiring ------------------------------------------------------------------------

const BASE = JSON.parse(readFileSync(new URL("./fixtures/state.json", import.meta.url)));
const noop = () => {};
const HANDLERS = {
  onRange: noop,
  onSort: noop,
  onView: noop,
  onTheme: noop,
  onZoom: noop,
  onResetZoom: noop,
  onToggleSeries: noop,
  onAvgWindow: noop,
  onPage: noop,
};
const UI = {
  view: "simple",
  range: "all",
  window: null,
  series: {},
  avg: "10m",
  theme: "auto",
  sortIndex: null,
  sortAsc: true,
  page: "dashboard",
};

test("the Config button renders only when the control channel is enabled", () => {
  const on = render(App, { state: BASE, connected: true, ui: UI, controlEnabled: true, ...HANDLERS });
  const off = render(App, {
    state: BASE,
    connected: true,
    ui: UI,
    controlEnabled: false,
    ...HANDLERS,
  });
  assert.match(on, />Config</);
  assert.doesNotMatch(off, />Config</);
});

test("page=config swaps the dashboard body for the editor, keeping the header", () => {
  const html = render(App, {
    state: BASE,
    connected: true,
    ui: { ...UI, page: "config" },
    controlEnabled: true,
    ...HANDLERS,
  });
  assert.match(html, /Loading configuration/); // editor initial state (no fetch in the probe)
  assert.match(html, /brand-name/); // header stays
  assert.doesNotMatch(html, /dashboard-view/);
});
