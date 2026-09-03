// Pool credential round-trip through Worker Inspect's editor (#1548), split out of
// workerview.test.mjs (same file-budget reason #1543 split test_worker_config_credentials.py).
//
// A pool's `pass` is masked server-side (xmrig_client.mask_pool_credentials), not deleted, so it
// travels through the prefill as a NESTED sentinel — buildFields' own sentinel check
// (workerlogic.test.mjs, #508) only ever sees a WHOLE writable value, so a credential nested
// inside `pools` is invisible to it. Before this fix, an Apply that never opened the credential
// still resent it (JSON mode always resends the whole textarea; table mode does if `pools` is
// touched for any other reason) — wiping the rig's password. Same no-DOM pattern as
// workerview.test.mjs: instantiate directly, stub setState, no rendering needed here.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { WorkerInspect } from "../../mining_dashboard/web/static/workerview.mjs";

const SENTINEL = { __secret__: true };
const DETAIL = {
  name: "rig1",
  found: true,
  editable: true,
  control_enabled: true,
  status: "mining",
  writable_keys: ["DONATION", "pools"],
  last_applied: {
    DONATION: 5,
    pools: [{ url: "pool.example:3333", user: "wallet.rig1", pass: SENTINEL }],
  },
  history: [],
  hashrate_history: { hashrate: [], markers: [] },
};

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

test("JSON mode: applying an untouched textarea sends nothing at all, not the resent pools credential", async () => {
  const inst = readyInstance();
  inst.state.mode = "json";
  let posted = false;
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => {
    posted = true;
    return { json: async () => ({ status: "applied" }) };
  };
  try {
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(posted, false); // nothing changed -> nothing sent at all
  assert.match(inst.state.result.error, /No changes to apply/);
});

test("JSON mode: editing an unrelated key does not resend the untouched pools credential", async () => {
  // The issue's exact reproduction: open Inspect, switch to JSON mode, change one unrelated key.
  const inst = readyInstance();
  inst.state.mode = "json";
  inst.onJsonInput(JSON.stringify({ ...DETAIL.last_applied, DONATION: 6 }));
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
  assert.deepEqual(posted.changes, { DONATION: 6 });
  assert.ok(!("pools" in posted.changes)); // untouched — the whole point of the fix
});

test("table mode: editing the pools row without a real password strips the sentinel, not the pool", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = {
    pools: JSON.stringify([
      { url: "pool.example:3333", user: "wallet.rig1", pass: SENTINEL, keepalive: true },
    ]),
  };
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
  assert.deepEqual(posted.changes.pools, [
    { url: "pool.example:3333", user: "wallet.rig1", keepalive: true },
  ]);
  assert.doesNotMatch(JSON.stringify(posted), /__secret__/); // never the literal marker
});

test("JSON mode prefill also prefers the rig's own config over last_applied (#1235)", async () => {
  // load() builds editText from the SAME writableSnapshot() the table renders from, not
  // last_applied alone — the two modes must agree on the starting point they diff against.
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  const withRig = { ...DETAIL, rig_config: { DONATION: 9 } };
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, json: async () => withRig });
  try {
    await inst.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  const prefilled = JSON.parse(inst.state.editText);
  assert.equal(prefilled.DONATION, 9); // the rig's value, not last_applied's 5
});
