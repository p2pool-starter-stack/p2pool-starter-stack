// Unit tests for the click-to-adopt panel (#893): mining_dashboard/web/static/workeradopt.mjs
// (AdoptRigForm's own fetch sequencing) and its routing inside Worker Inspect (workerview.mjs) —
// the "explain the gated state" half of the feature: an unadopted rig shows the adopt form instead
// of a dead-end message, an off channel still shows the off message.
//
// Same no-DOM pattern as workerview.test.mjs: instantiate directly, stub setState, walk render()
// with the dependency-free vnode renderer.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { App } from "../../mining_dashboard/web/static/components.mjs";
import { AdoptRigForm } from "../../mining_dashboard/web/static/workeradopt.mjs";
import { WorkerInspect } from "../../mining_dashboard/web/static/workerview.mjs";
import { render, renderToString } from "./helpers/render.mjs";

const FIXTURE = JSON.parse(readFileSync(new URL("./fixtures/state.json", import.meta.url)));

function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

function adoptForm(props = {}) {
  const inst = new AdoptRigForm({ name: "rig1", ip: "10.0.0.9", onAdopted: () => {}, ...props });
  stubSetState(inst);
  return inst;
}

// Queue of fetch responses, consumed in order — the three legs adopt() drives: GET /api/config,
// POST /api/control/preview, POST /api/control/commit.
function withFetchSequence(responses, fn) {
  const realFetch = globalThis.fetch;
  const calls = [];
  let i = 0;
  globalThis.fetch = async (url, opts) => {
    calls.push({ url, body: opts?.body ? JSON.parse(opts.body) : null });
    const r = responses[i++] || { ok: true, json: async () => ({ status: "error" }) };
    return { ok: r.ok !== false, status: r.status || 200, json: async () => r.body };
  };
  return fn(calls).finally(() => {
    globalThis.fetch = realFetch;
  });
}

// --- Prefill -----------------------------------------------------------------------------------

test("AdoptRigForm: prefills host from the observed ip and the default control port", () => {
  const inst = adoptForm();
  assert.equal(inst.state.host, "10.0.0.9");
  assert.equal(inst.state.controlPort, "8082");
  assert.equal(inst.state.token, ""); // never prefilled — the operator must type it
  assert.match(renderToString(inst.render()), /value="10\.0\.0\.9"/);
});

test("AdoptRigForm: no observed ip yet still renders an empty, editable host field", () => {
  const inst = adoptForm({ ip: undefined });
  assert.equal(inst.state.host, "");
});

// --- Client-side validation gates the network entirely ------------------------------------------

test("AdoptRigForm: a malformed host is refused before any fetch happens", async () => {
  const inst = adoptForm();
  inst.state.host = "10.0.0.9:9999";
  await withFetchSequence([], async (calls) => {
    await inst.adopt();
    assert.equal(calls.length, 0);
  });
  assert.equal(inst.state.result.status, "error");
});

// --- The full preview -> commit round trip -----------------------------------------------------

test("AdoptRigForm: a well-formed submission previews then commits through the control path", async () => {
  const inst = adoptForm();
  inst.state.token = "tok-123";
  const liveConfig = { workers: { list: [] } };
  await withFetchSequence(
    [
      { body: liveConfig }, // GET /api/config
      { body: { id: "req-1", status: "previewed", destructive: false } }, // preview
      { body: { id: "req-1", status: "applied" } }, // commit
    ],
    async (calls) => {
      await inst.adopt();
      assert.equal(calls[0].url, "/api/config");
      assert.equal(calls[1].url, "/api/control/preview");
      assert.deepEqual(calls[1].body.config.workers.list, [
        { name: "rig1", host: "10.0.0.9", control_port: 8082, token: "tok-123" },
      ]);
      assert.equal(calls[2].url, "/api/control/commit");
      assert.equal(calls[2].body.id, "req-1");
    },
  );
  assert.equal(inst.state.result.status, "applied");
  assert.equal(inst.state.busy, false);
});

test("AdoptRigForm: a rejected preview surfaces the host's reason and never commits", async () => {
  const inst = adoptForm();
  inst.state.token = "tok-123";
  await withFetchSequence(
    [
      { body: {} },
      { body: { id: "req-1", status: "rejected", error: "alters an existing per-worker descriptor" } },
    ],
    async (calls) => {
      await inst.adopt();
      assert.equal(calls.length, 2); // never reached commit
    },
  );
  assert.equal(inst.state.result.status, "rejected");
  assert.match(inst.state.result.error, /existing per-worker descriptor/);
});

test("AdoptRigForm: an unexpected destructive preview is refused, not blindly committed", async () => {
  // A pure add should never come back destructive; if it somehow does, adopt() must refuse rather
  // than auto-confirming a change no one reviewed.
  const inst = adoptForm();
  inst.state.token = "tok-123";
  await withFetchSequence(
    [{ body: {} }, { body: { id: "req-1", status: "previewed", destructive: true } }],
    async (calls) => {
      await inst.adopt();
      assert.equal(calls.length, 2); // never reached commit
    },
  );
  assert.equal(inst.state.result.status, "error");
});

test("AdoptRigForm: calls onAdopted only once the commit actually applied", async () => {
  const inst = adoptForm();
  inst.state.token = "tok-123";
  let notified = 0;
  inst.props.onAdopted = () => notified++;
  await withFetchSequence(
    [
      { body: {} },
      { body: { id: "req-1", status: "previewed", destructive: false } },
      { body: { id: "req-1", status: "failed", error: "apply failed" } },
    ],
    async () => inst.adopt(),
  );
  assert.equal(notified, 0); // a failed commit must not claim success
});

// --- Routed from Worker Inspect (#893 item 2: explain the gated state) ------------------------

const BASE_DETAIL = {
  name: "rig1",
  found: true,
  status: "online",
  hashrate: "1.0 kH/s",
  rigforge: null,
  writable_keys: ["DONATION"],
  last_applied: {},
  history: [],
  hashrate_history: { hashrate: [], markers: [] },
};

function inspectInstance(detail) {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  inst.state = { ...inst.state, phase: "ready", detail, editText: "{}" };
  return inst;
}

test("Worker Inspect: an unadopted rig with the control channel on shows the adopt form", () => {
  const out = renderToString(
    inspectInstance({ ...BASE_DETAIL, editable: false, control_enabled: true, ip: "10.0.0.9" }).render(),
  );
  assert.match(out, /Adopt this rig/);
  assert.doesNotMatch(out, /Config editing is off/);
});

test("Worker Inspect: the control channel off shows the off message, not the adopt form", () => {
  const out = renderToString(
    inspectInstance({ ...BASE_DETAIL, editable: false, control_enabled: false }).render(),
  );
  assert.match(out, /Config editing is off/);
  assert.doesNotMatch(out, /Adopt this rig/);
});

test("Worker Inspect: an already-adopted (editable) rig shows the editor, not the adopt form", () => {
  const out = renderToString(
    inspectInstance({ ...BASE_DETAIL, editable: true, control_enabled: true }).render(),
  );
  assert.match(out, /Apply to rig/);
  assert.doesNotMatch(out, /Adopt this rig/);
});

// --- The table badge routes into the dialog instead of straight to GitHub (#893 item 3) --------

const UI = {
  view: "advanced",
  range: "all",
  window: null,
  series: {},
  avg: "10m",
  theme: "auto",
  sortIndex: null,
  sortAsc: true,
};
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
  onDismissHint: noop,
  onCloseInspect: noop,
};

function withRigUpdate(onInspect, controlEnabled) {
  const state = structuredClone(FIXTURE);
  state.control_enabled = controlEnabled;
  state.workers[0].rigforge_update = { available: true, latest: "v1.11.2", url: "https://h/v1.11.2" };
  return render(App, { state, connected: true, ui: UI, onInspect, ...HANDLERS });
}

test("table badge: with Worker Inspect available, it's a button (opens the dialog), not a link", () => {
  const out = withRigUpdate(noop, true);
  assert.match(out, /<button[^>]*>rf v1\.11\.2 available/);
  assert.doesNotMatch(out, /<a[^>]*>rf v1\.11\.2 available/);
});

test("table badge: with the control channel off, it falls back to the old release-notes link", () => {
  const out = withRigUpdate(noop, false);
  assert.match(out, /<a[^>]*href="https:\/\/h\/v1\.11\.2"[^>]*>rf v1\.11\.2 available/);
});
