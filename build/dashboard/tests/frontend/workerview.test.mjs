// Unit tests for Worker Inspect's editor UI (#518): mining_dashboard/web/static/workerview.mjs —
// the table editor, the JSON mode (inline parse errors + the file-fill button), and the masked
// sentinel round-trip shared with the Configuration view (#508/#440).
//
// Rendering uses the dependency-free vnode walker (helpers/render.mjs); apply()/onJsonInput/
// onFilePick are called directly against a WorkerInspect instance, the same pattern
// configview.test.mjs uses for ConfigView's poll()/save() — no DOM, no npm deps.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test build/dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { WorkerInspect } from "../../mining_dashboard/web/static/workerview.mjs";
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
};

// WorkerInspect is never mounted here (no DOM/jsdom — this repo's frontend tests deliberately run
// with neither, see helpers/render.mjs). Preact's setState() only takes effect through Preact's
// own render loop, which never runs for an unmounted instance, so it silently no-ops on `state`.
// Stub it to merge synchronously, the same net effect a real render would have, so the methods
// under test (onJsonInput, apply's busy/result bookkeeping) are observable.
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
  // editText is prefilled from last_applied at load() time — unmodified, it still carries the
  // literal sentinel shape (the same "unless replaced" contract the Configuration view uses).
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
