// Unit tests for Worker Inspect's editor UI (#518): mining_dashboard/web/static/workerview.mjs — the
// table editor, the JSON mode (inline parse errors + the file-fill button), and the masked sentinel
// round-trip shared with the Configuration view (#508/#440). Rendering uses the dependency-free vnode
// walker (helpers/render.mjs); apply()/onJsonInput/onFilePick are called directly against a
// WorkerInspect instance — no DOM, no npm deps. Run with: node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { StatsTable, WorkerInspect } from "../../mining_dashboard/web/static/workerview.mjs";
import {
  contrastRatio,
  DARK_BLOCK,
  DASHBOARD_CSS,
  LIGHT_BLOCK,
  themeToken,
} from "./helpers/contrast.mjs";
import { renderToString } from "./helpers/render.mjs";

const SENTINEL = { __secret__: true };
const DETAIL = {
  name: "rig1",
  found: true,
  editable: true,
  control_enabled: true,
  status: "mining",
  hashrate: "1.2 kH/s",
  rigforge: null,
  writable_keys: ["DONATION", "max_temp_c", "token"],
  last_applied: { DONATION: 5, max_temp_c: 70, token: SENTINEL },
  history: [],
  hashrate_history: { hashrate: [], markers: [] },
};

// WorkerInspect is never mounted here (no DOM/jsdom), so Preact's setState() silently no-ops on
// `state` — its render loop never runs. Stub it to merge synchronously so the methods under test
// (onJsonInput, apply's bookkeeping) are observable.
function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

function readyInstance(detail = DETAIL) {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  inst.state = {
    ...inst.state,
    phase: "ready",
    detail,
    editText: JSON.stringify(detail.last_applied, null, 2),
  };
  return inst;
}

// --- Table mode ------------------------------------------------------------------------------

test("table mode renders one row per writable key", () => {
  const out = renderToString(readyInstance().render());
  assert.match(out, /config-field-name">DONATION/);
  assert.match(out, /config-field-name">max_temp_c/);
  assert.match(out, /config-field-name">token/);
});

test("table mode: editing a row and applying builds the changes object (only the diff)", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = { DONATION: "6" };
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = { url, body: JSON.parse(opts.body) };
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(posted.url, "/api/control/worker-apply");
  assert.deepEqual(posted.body, { worker: "rig1", changes: { DONATION: 6 } });
});

// --- JSON mode ---------------------------------------------------------------------------------

test("JSON mode: a parse error surfaces inline, not just on Apply", () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  inst.onJsonInput("{not json");
  assert.match(inst.state.jsonError, /Not valid JSON/);
  assert.match(renderToString(inst.render()), /Not valid JSON/);
});

test("JSON mode: valid JSON builds the same shape of changes object as table mode", async () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  inst.onJsonInput(JSON.stringify({ DONATION: 6 }));
  assert.equal(inst.state.jsonError, null);
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = JSON.parse(opts.body);
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.deepEqual(posted.changes, { DONATION: 6 }); // same shape the table-mode test posted
});

// --- Masked-token sentinel round-trip (#508/#440) -------------------------------------------

test("table mode: a masked value renders as a secret field, never raw sentinel JSON", () => {
  const out = renderToString(readyInstance().render());
  assert.doesNotMatch(out, /__secret__/); // never printed as raw JSON the operator could mangle
  assert.match(out, /type="password"/);
});

test("table mode: leaving the secret row blank keeps the token untouched", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = { DONATION: "6" }; // token row untouched
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    posted = JSON.parse(opts.body);
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.ok(!("token" in posted.changes)); // untouched — never resent, masked or otherwise
});

test("JSON mode: an untouched sentinel round-trips verbatim through the textarea", () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  // editText is prefilled from last_applied at load() time — unmodified, it still carries the literal sentinel shape (the same "unless replaced" contract the Configuration view uses).
  assert.match(inst.state.editText, /__secret__/);
  const parsed = JSON.parse(inst.state.editText);
  assert.deepEqual(parsed.token, SENTINEL);
});

// --- File-fill button (#518, ~5 lines) ---------------------------------------------------------

test("the fill button reads a picked file into the JSON textarea via FileReader", async () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  const content = JSON.stringify({ DONATION: 9 });
  let capturedOnLoad;
  class FakeFileReader {
    set onload(fn) {
      capturedOnLoad = fn;
    }
    readAsText() {
      this.result = content;
      capturedOnLoad();
    }
  }
  const realFileReader = globalThis.FileReader;
  globalThis.FileReader = FakeFileReader;
  try {
    inst.onFilePick({ target: { files: [{ name: "profile.json" }] } });
  } finally {
    globalThis.FileReader = realFileReader;
  }
  assert.equal(inst.state.editText, content);
  assert.equal(inst.state.jsonError, null);
});

test("the fill button is a no-op when the file picker is dismissed with no file", () => {
  const inst = readyInstance();
  const before = inst.state.editText;
  inst.onFilePick({ target: { files: [] } });
  assert.equal(inst.state.editText, before);
});

// --- Change history (#1014) -------------------------------------------------------------------

test("a config-apply history row lists its changed keys", () => {
  const detail = {
    ...DETAIL,
    history: [
      {
        applied_at: "2026-07-16 12:00",
        status: "applied",
        type: "apply",
        changes: { DONATION: 3 },
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /DONATION/);
  assert.doesNotMatch(out, /upgrade →/);
});

test("a rig-upgrade history row shows the version it moved to, not the literal key 'version'", () => {
  const detail = {
    ...DETAIL,
    history: [
      {
        applied_at: "2026-07-16 12:00",
        status: "applied",
        type: "upgrade",
        changes: { version: "v1.12.0" },
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /upgrade → v1\.12\.0/);
  assert.doesNotMatch(out, />version</); // never the raw changed-key name for an upgrade row
});

// --- Hashrate by config (#492) ----------------------------------------------------------------

test("renders one row per config version with its aggregated hashrate", () => {
  const detail = {
    ...DETAIL,
    hashrate_by_config: [
      {
        change_id: "cid2",
        applied_at: "2026-07-16 12:00",
        avg_h15: "4.00 kH/s",
        min_h15: "4.00 kH/s",
        max_h15: "4.00 kH/s",
        sample_count: 0,
        reason: null,
      },
      {
        change_id: "cid1",
        applied_at: "2026-07-16 10:00",
        avg_h15: "1.50 kH/s",
        min_h15: "1.00 kH/s",
        max_h15: "2.00 kH/s",
        sample_count: 2,
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /cid2/);
  assert.match(out, /cid1/);
  assert.match(out, /1\.50 kH\/s/);
});

test("a version with no samples yet shows a dash, not a crash", () => {
  const detail = {
    ...DETAIL,
    hashrate_by_config: [
      {
        change_id: "cid1",
        applied_at: "2026-07-16 10:00",
        avg_h15: null,
        min_h15: null,
        max_h15: null,
        sample_count: 0,
        reason: null,
      },
    ],
  };
  const out = renderToString(readyInstance(detail).render());
  assert.match(out, /cid1/);
  assert.match(out, />—</);
});

test("no applied config versions yet falls back to an explanatory message", () => {
  const out = renderToString(readyInstance({ ...DETAIL, hashrate_by_config: [] }).render());
  assert.match(out, /No applied config changes to correlate hashrate against yet/);
});

// --- Hashrate chart (#1013/#1015) -------------------------------------------------------------

test("a rig with no hashrate history yet renders an honest empty state, not a broken chart", () => {
  const out = renderToString(readyInstance(DETAIL).render());
  assert.match(out, /No hashrate history for this rig yet/);
  // The range control still renders (the operator can still try a wider range).
  assert.match(out, /24 Hr/);
  assert.match(out, />All</);
});

test("a rig with samples renders the range control and the chart canvas, not the empty state", () => {
  const detail = {
    ...DETAIL,
    hashrate_history: { hashrate: [{ x: 1000, y: 500 }], markers: [] },
  };
  const out = renderToString(readyInstance(detail).render());
  assert.doesNotMatch(out, /No hashrate history for this rig yet/);
  assert.match(out, /<canvas/);
  assert.match(out, /24 Hr/);
  assert.match(out, /1 Wk/);
});

test("only the current chart range button is marked active", () => {
  const detail = { ...DETAIL, hashrate_history: { hashrate: [{ x: 1, y: 1 }], markers: [] } };
  const inst = readyInstance(detail);
  inst.state.chartRange = "1w";
  const out = renderToString(inst.render());
  assert.match(out, /class="btn-range active"[^>]*>1 Wk/);
});

test("clicking a range button refetches only the chart data, leaving an in-progress edit alone", async () => {
  const detail = { ...DETAIL, hashrate_history: { hashrate: [{ x: 1, y: 1 }], markers: [] } };
  const inst = readyInstance(detail);
  inst.state.tableEdits = { DONATION: "9" }; // an in-progress, unsaved edit
  let requested = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requested = url;
    return {
      ok: true,
      json: async () => ({ hashrate_history: { hashrate: [{ x: 2, y: 2 }], markers: [] } }),
    };
  };
  try {
    await inst.setChartRange("1w");
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.match(requested, /\/api\/worker\?name=rig1&range=1w/);
  assert.equal(inst.state.chartRange, "1w");
  assert.equal(inst.state.chartLoading, false);
  assert.deepEqual(inst.state.detail.hashrate_history.hashrate, [{ x: 2, y: 2 }]);
  // Nothing else in detail, and no unrelated state, was touched by the chart-only refresh.
  assert.deepEqual(inst.state.tableEdits, { DONATION: "9" });
  assert.equal(inst.state.phase, "ready");
});

test("load() requests the current chart range from /api/worker", async () => {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  let requested = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url) => {
    requested = url;
    return { ok: true, json: async () => DETAIL };
  };
  try {
    await inst.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.match(requested, /range=24h/); // the default chart-range preference
  assert.equal(inst.state.phase, "ready");
});

test("a detail payload missing hashrate_history entirely still renders (defensive, no crash)", () => {
  const withoutChart = { ...DETAIL };
  delete withoutChart.hashrate_history;
  const out = renderToString(readyInstance(withoutChart).render());
  assert.match(out, /No hashrate history for this rig yet/);
});

// --- One-click rig upgrade (#597) -------------------------------------------------------------

const UPG_DETAIL = {
  ...DETAIL,
  rigforge: { version: "1.11.1", stats: [] },
  rigforge_update: { available: true, latest: "v1.11.2", url: "https://h/v1.11.2" },
};

test("upgrade button gates on rigforge_update + an editable, control-enabled worker (#597)", () => {
  assert.match(renderToString(readyInstance(UPG_DETAIL).render()), /Upgrade rig…/);
  // Notify-only without an operator-set host or with control off — badge yes, button no.
  const noEdit = renderToString(readyInstance({ ...UPG_DETAIL, editable: false }).render());
  assert.match(noEdit, /New RigForge release/);
  assert.doesNotMatch(noEdit, /Upgrade rig…/);
  const noCtl = renderToString(readyInstance({ ...UPG_DETAIL, control_enabled: false }).render());
  assert.doesNotMatch(noCtl, /Upgrade rig…/);
  // No update derived -> no badge, no button.
  const current = renderToString(readyInstance({ ...UPG_DETAIL, rigforge_update: null }).render());
  assert.doesNotMatch(current, /Upgrade rig…|New RigForge release/);
});

test("arming swaps the button for confirm/cancel; cancel disarms (#597)", () => {
  const inst = readyInstance(UPG_DETAIL);
  inst.state.upgArmed = true;
  const armed = renderToString(inst.render());
  assert.match(armed, /Confirm upgrade/);
  assert.match(armed, /Cancel/);
  assert.doesNotMatch(armed, /Upgrade rig…/);
});

test("upgrade() POSTs {worker, version} and renders the terminal result (#597)", async () => {
  const inst = readyInstance(UPG_DETAIL);
  let posted = null;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (posted === null && url === "/api/control/worker-upgrade") {
      posted = { url, body: JSON.parse(opts.body) };
      return { status: 200, json: async () => ({ status: "noop", note: "already on v1.11.2" }) };
    }
    return { ok: true, status: 200, json: async () => UPG_DETAIL }; // the load() refresh
  };
  try {
    await inst.upgrade();
    await new Promise((r) => setImmediate(r)); // flush the fire-and-forget load() refresh
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(posted.url, "/api/control/worker-upgrade");
  assert.deepEqual(posted.body, { worker: "rig1", version: "v1.11.2" });
  assert.equal(inst.state.upgBusy, false);
  assert.match(renderToString(inst.render()), /Already up to date/);
});

test("terminal statuses render their calm/red variants (#597)", () => {
  const inst = readyInstance(UPG_DETAIL);
  inst.state.upgResult = { status: "throttled", reason: "throttled: retry after the window" };
  assert.match(renderToString(inst.render()), /Throttled by the rig — retry later/);
  inst.state.upgResult = { status: "rolled_back", reason: "miner did not return live" };
  assert.match(renderToString(inst.render()), /Rolled back/);
});

// --- RigForge new-release callout (#596) ----------------------------------------------------

test("Inspect surfaces the RigForge new-release callout only when the server derived one (#596)", () => {
  const behind = {
    ...DETAIL,
    rigforge: { version: "1.11.1", stats: [] },
    rigforge_update: { available: true, latest: "v1.11.2", url: "https://h/v1.11.2" },
  };
  const out = renderToString(readyInstance(behind).render());
  assert.match(out, /New RigForge release v1\.11\.2 available/);
  assert.match(out, /href="https:\/\/h\/v1\.11\.2"/);

  // Current rig / plain xmrig: the server sends null -> no callout, no error.
  const current = { ...DETAIL, rigforge_update: null };
  assert.doesNotMatch(renderToString(readyInstance(current).render()), /New RigForge release/);
});

// --- StatsTable value contrast (#1232) ------------------------------------------------------
// A plain metric renders with variant "outline" — STAT_VALUE_CLS has no entry for it, so before the
// fix the value <td> got an empty class (no colour/weight, reading as disabled text in dark mode).
// The fix puts every value in `.stat-value`, with status-ok/warn/bad layered on top for a flagged
// metric; these two tests catch a regression to either the markup or the CSS rule itself.

test("StatsTable: a plain outline value still gets the stat-value class, not an empty one (#1232)", () => {
  const out = renderToString(StatsTable({ stats: [{ label: "Governor", value: "performance", variant: "outline" }] }));
  const valueCell = out.match(/<td class="([^"]*)">performance<\/td>/);
  assert.ok(valueCell, `expected a value <td> for the outline stat, got: ${out}`);
  assert.match(valueCell[1], /\bstat-value\b/);
  // The old code emitted `STAT_VALUE_CLS[s.variant] || ""`, which for "outline" (or any variant with no colour entry) rendered class="" — an empty class is exactly the regression.
  assert.notEqual(valueCell[1].trim(), "");
});

test("StatsTable: a warn-variant value keeps its status colour alongside stat-value (#1232)", () => {
  const out = renderToString(StatsTable({ stats: [{ label: "Temp / max", value: "78°C / 90°C", variant: "warn" }] }));
  const valueCell = out.match(/<td class="([^"]*)">78°C \/ 90°C<\/td>/);
  assert.ok(valueCell, `expected a value <td> for the warn stat, got: ${out}`);
  assert.match(valueCell[1], /\bstat-value\b/);
  assert.match(valueCell[1], /\bstatus-warn\b/);
});

test("dashboard.css: .stat-value declares an explicit --text colour, not an empty/inherited one (#1232)", () => {
  const rule = DASHBOARD_CSS.match(/\.stat-value\s*\{([^}]*)\}/);
  assert.ok(rule, "expected a .stat-value rule in dashboard.css");
  assert.match(rule[1], /color:\s*var\(--text\)/);
  assert.match(rule[1], /font-weight:\s*6\d\d/); // 600-ish, matching the top stat-card values
});

test("dashboard.css: .stat-value's --text on --card meets WCAG AA (>= 4.5:1) in dark AND light (#1232)", () => {
  // Dark is the base palette; light is the explicit override block — pull each theme's pair independently.
  const darkText = themeToken(DASHBOARD_CSS, DARK_BLOCK, "--text");
  const darkCard = themeToken(DASHBOARD_CSS, DARK_BLOCK, "--card");
  const lightText = themeToken(DASHBOARD_CSS, LIGHT_BLOCK, "--text");
  const lightCard = themeToken(DASHBOARD_CSS, LIGHT_BLOCK, "--card");

  const darkRatio = contrastRatio(darkText, darkCard);
  const lightRatio = contrastRatio(lightText, lightCard);
  assert.ok(darkRatio >= 4.5, `dark .stat-value contrast ${darkRatio.toFixed(2)}:1 is below AA (4.5:1)`);
  assert.ok(lightRatio >= 4.5, `light .stat-value contrast ${lightRatio.toFixed(2)}:1 is below AA (4.5:1)`);
});

// --- Prefill provenance (#1235) ----------------------------------------------------------------

test("table mode prefills from the rig's own config and labels every other case (#1235)", () => {
  // Label text is proven at the logic tier (fieldNote, workerlogic.test.mjs); this proves the render.
  const withRig = { ...DETAIL, rig_config: { DONATION: 9, max_temp_c: 85 } };
  const out = renderToString(readyInstance(withRig).render());
  assert.match(out, /value="9"/); // the rig's DONATION
  assert.match(out, /value="85"/); // the rig's max_temp_c
  assert.doesNotMatch(out, /value="5"/); // not the last-applied DONATION
  assert.doesNotMatch(out, /value="70"/); // nor its max_temp_c
  const noRig = { ...DETAIL, last_applied: { DONATION: 5 }, rig_config: null };
  const fell = renderToString(readyInstance(noRig).render());
  assert.match(fell, /last applied from here/);
  assert.equal((fell.match(/could not read from the rig/g) || []).length, 2); // max_temp_c, token
  assert.doesNotMatch(out, /the rig's live feed doesn't expose these values/); // stale claim, #1235
  assert.match(out, /Prefilled with what the rig is running now/);
});
