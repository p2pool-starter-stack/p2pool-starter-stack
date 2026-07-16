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

// --- One-click upgrade (#59) ----------------------------------------------------------
//
// runUpgrade is the whole client-side flow: POST the version the operator saw, then poll the
// result file to the terminal outcome — skipping the runner's intermediate "running" status and
// riding out the window where the upgrade recreates the dashboard container itself. The typed
// UPGRADE confirm is UX only; the host runner re-derives the real target (tier-2 spool tests).

import {
  PreviewModal,
  runUpgrade,
  UpgradeControl,
} from "../../mining_dashboard/web/static/configview.mjs";
import { renderToString } from "./helpers/render.mjs";

const UPDATE = { available: true, latest: "v9.9.9", url: "https://example.invalid/rel" };

test("runUpgrade posts the seen version, skips 'running', rides out the restart, returns the outcome", async () => {
  let posted = null;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/upgrade") {
      posted = { body: JSON.parse(opts.body), headers: opts.headers };
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    polls++;
    if (polls === 1) return okResult({ status: "running", version: "v9.9.9" });
    if (polls === 2) throw new TypeError("Failed to fetch"); // dashboard recreated mid-upgrade
    return okResult({ status: "upgraded", version: "v9.9.9" });
  };
  const out = await withFastPoll(fetchStub, () => runUpgrade("v9.9.9"));
  assert.equal(out.status, "upgraded");
  assert.deepEqual(posted.body, { version: "v9.9.9" }); // the proposal — nothing else crosses
  assert.equal(posted.headers["X-Pithead-Control"], "1"); // CSRF guard rides every mutation
});

test("runUpgrade surfaces a host-side rejection as the outcome, not a throw", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/upgrade"
      ? { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) }
      : okResult({ status: "rejected", error: "already up to date" });
  const out = await withFastPoll(fetchStub, () => runUpgrade("v9.9.9"));
  assert.equal(out.status, "rejected");
  assert.match(out.error, /up to date/);
});

test("UpgradeControl renders nothing without a newer release or with the channel off", () => {
  const inst = (props) => {
    const c = new UpgradeControl(props);
    c.props = props;
    return renderToString(c.render());
  };
  assert.equal(inst({ update: null, enabled: true }), "");
  assert.equal(inst({ update: { available: false }, enabled: true }), "");
  assert.equal(inst({ update: UPDATE, enabled: false }), "");
  assert.match(inst({ update: UPDATE, enabled: true }), /Upgrade to v9\.9\.9/);
});

test("the confirm modal arms only on a typed UPGRADE", () => {
  const props = { update: UPDATE, enabled: true };
  const inst = new UpgradeControl(props);
  inst.props = props;
  inst.state.phase = "confirm";
  assert.match(renderToString(inst.render()), /disabled/); // unarmed until typed
  inst.state.confirmText = "UPGRADE";
  assert.doesNotMatch(renderToString(inst.render()), /disabled/);
});

// --- Preview modal (#504) --------------------------------------------------------------
//
// dashboard.energy is config.json-only, so the host runner previews an energy edit as a normal
// INFO change row (not the old, non-committable HOST note). The modal must render it as a pending
// change and arm Confirm — a non-destructive change needs no typed APPLY.
test("an INFO change (e.g. dashboard.energy) renders committable and arms Confirm", () => {
  const preview = {
    changes: [{ flag: "INFO", key: "dashboard.energy", msg: "Energy calculator settings updated." }],
    destructive: false,
  };
  const out = renderToString(PreviewModal({ preview, confirmText: "", busy: false }));
  assert.match(out, /Energy calculator settings updated\./); // the change is shown
  assert.doesNotMatch(out, /No configuration changes detected/);
  // Confirm is armed: the only disabled control is absent for a non-destructive, non-empty change.
  assert.doesNotMatch(out, /disabled/);
});

test("an empty preview leaves Confirm disabled", () => {
  const out = renderToString(
    PreviewModal({ preview: { changes: [], destructive: false }, confirmText: "", busy: false }),
  );
  assert.match(out, /No configuration changes detected/);
  assert.match(out, /disabled/); // nothing to commit
});
