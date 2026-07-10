// Unit test for the Configuration view's result-poll loop (#33 hardening, graft #437).
//
// A commit recreates the dashboard container itself, so a fetch mid-poll can transiently fail
// (connection refused while the container restarts). poll() must ride that out — keep polling
// until the result file answers — instead of dropping to an error state. The retry is pure
// control flow, tested here against a stubbed global fetch with setTimeout fired immediately; the
// full network round-trip (real recreate) is exercised at tier 3/4.
//
// Run with Node's built-in test runner (CI runs exactly this — the *.test.mjs glob; pointing
// node --test at the bare directory fails, it tries to run non-test helpers too):
//     node --test build/dashboard/tests/frontend/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { ConfigView } from "../../mining_dashboard/web/static/configview.mjs";

const ID = "11111111-1111-4111-8111-111111111111";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

// Drive poll() with setTimeout fired synchronously so the 2s cadence doesn't slow the test,
// restoring the globals afterwards.
async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

test("poll rides out a transient fetch failure (container recreate) then returns the result", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    if (calls === 1) throw new TypeError("Failed to fetch"); // dashboard restarting mid-apply
    return okResult({ status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID));
  assert.equal(out.status, "applied");
  assert.equal(calls, 2); // it retried after the throw instead of surfacing an error
});

test("poll skips the still-present preview result until the commit outcome lands", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    return okResult(calls < 2 ? { status: "previewed" } : { status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID, "previewed"));
  assert.equal(out.status, "applied");
});
