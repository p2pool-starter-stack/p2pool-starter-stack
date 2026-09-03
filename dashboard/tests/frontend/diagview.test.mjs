// Service Diagnostics card (#913 doctor detail, #943 log tail): the POST + poll flow, the
// doctor-document mapping, and the render states.
//
// The mapping tests are the load-bearing ones. doctor --json's shape is fixed by doctor_json in
// lib/pithead/06-doctor.sh — {version, exit, summary:{ok,warn,fail}, checks:[{status, message}]},
// where each check is a report line split on a TAB, so a check has a status and a message and NO
// name. These tests pin that shape, so a card written against a guessed one fails here instead of
// rendering a column of placeholders to an operator with no other way to look.
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  DIAG_CONTAINERS,
  DiagnosticsPanel,
  doctorRows,
  doctorSummary,
  runDiag,
} from "../../mining_dashboard/web/static/diagview.mjs";
import { renderToString } from "./helpers/render.mjs";

const ID = "22222222-2222-4222-8222-222222222222";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

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

// --- the real doctor --json shape -------------------------------------------------------------

const DOCTOR_DOC = {
  version: "1.19.3",
  exit: 2,
  summary: { ok: 3, warn: 1, fail: 2 },
  checks: [
    { status: "ok", message: "docker compose is installed" },
    { status: "fail", message: "monerod is not answering on 18081" },
    { status: "warn", message: "tari is 400 blocks behind" },
    { status: "ok", message: "tor control port responds" },
    { status: "fail", message: "p2pool exited 3 minutes ago" },
    { status: "ok", message: "config.json parses" },
  ],
};

test("doctorRows keeps status+message and carries no invented per-check name", () => {
  const rows = doctorRows(DOCTOR_DOC);
  assert.equal(rows.length, 6);
  for (const r of rows) {
    assert.deepEqual(Object.keys(r).sort(), ["message", "status"]);
    assert.ok(r.message.length > 0);
  }
});

test("doctorRows sorts fail, then warn, then ok", () => {
  const got = doctorRows(DOCTOR_DOC).map((r) => r.status);
  assert.deepEqual(got, ["fail", "fail", "warn", "ok", "ok", "ok"]);
});

test("doctorRows preserves the message text verbatim", () => {
  const rows = doctorRows(DOCTOR_DOC);
  assert.deepEqual(
    rows.filter((r) => r.status === "fail").map((r) => r.message).sort(),
    ["monerod is not answering on 18081", "p2pool exited 3 minutes ago"],
  );
});

test("doctorRows yields no rows for a document of another shape, and never throws", () => {
  for (const doc of [null, undefined, {}, { checks: null }, { checks: "nope" }, { results: [] }]) {
    assert.deepEqual(doctorRows(doc), [], JSON.stringify(doc));
  }
});

test("doctorRows tolerates a malformed check without dropping the good ones", () => {
  const rows = doctorRows({ checks: [null, "x", { status: "fail" }, { message: "m" }] });
  assert.deepEqual(rows, [
    { status: "fail", message: "" },
    { status: "", message: "m" },
  ]);
});

test("doctorSummary reports the host's own counts, and null when there are none", () => {
  assert.equal(doctorSummary(DOCTOR_DOC), "2 failing, 1 warning, 3 ok");
  assert.equal(doctorSummary({}), null);
  assert.equal(doctorSummary(null), null);
  assert.equal(doctorSummary({ summary: {} }), "0 failing, 0 warning, 0 ok");
});

// --- the submit + poll flow ---------------------------------------------------------------

test("runDiag posts the intent, skips 'running', and returns the terminal result", async () => {
  let posted = null;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/diag-logs") {
      posted = { headers: opts.headers, body: JSON.parse(opts.body) };
      return { status: 202, ok: false, json: async () => ({ id: ID }) };
    }
    assert.match(url, new RegExp(`/api/control/result\\?id=${ID}`));
    return posted.seen
      ? okResult({ status: "applied", container: "tor", lines: "a\nb" })
      : ((posted.seen = true), okResult({ status: "running" }));
  };
  const out = await withFastPoll(fetchStub, () => runDiag("diag-logs", { container: "tor" }));
  assert.equal(out.status, "applied");
  assert.equal(out.lines, "a\nb");
  assert.equal(posted.headers["X-Pithead-Control"], "1");
  assert.deepEqual(posted.body, { container: "tor" });
});

test("runDiag throws on a non-202 error status rather than polling a request it never made", async () => {
  const fetchStub = async () => ({ status: 403, ok: false, json: async () => ({}) });
  await assert.rejects(
    () => withFastPoll(fetchStub, () => runDiag("diag-doctor", {})),
    /HTTP 403/,
  );
});

// --- render states --------------------------------------------------------------------------

// Same shape backupview.test.mjs uses: the constructor sets state, but `props` has to be assigned
// because renderToString walks a vnode, not a mounted component.
function inst(props, state) {
  const c = new DiagnosticsPanel(props);
  c.props = props;
  if (state) c.state = { ...c.state, ...state };
  return c;
}

test("the card explains how to turn the control channel on when it is off", () => {
  const out = renderToString(inst({ enabled: false }).render());
  assert.match(out, /dashboard\.control\.enabled/);
  assert.doesNotMatch(out, /Run health check/);
});

test("the idle card offers both actions and every container the host allowlists", () => {
  const out = renderToString(inst({ enabled: true }).render());
  assert.match(out, /Run health check/);
  assert.match(out, /Show recent log/);
  for (const c of DIAG_CONTAINERS) assert.match(out, new RegExp(`<option value="${c}"`));
});

test("the picker offers neither wallet daemon — the host refuses both", () => {
  // Not cosmetic: bundle_redact_log is keyed to the launch-line leak class, and the wallet
  // daemons are the two whose ordinary output most easily carries key material outside it.
  assert.ok(!DIAG_CONTAINERS.includes("wallet-rpc"));
  assert.ok(!DIAG_CONTAINERS.includes("tari-wallet"));
});

test("a rendered log tail shows the host's note rather than an empty box", () => {
  const out = renderToString(
    inst(
      { enabled: true },
      {
        phase: "done",
        mode: "logs",
        result: { status: "applied", container: "tor", lines: "", note: "No log output — not running." },
      },
    ).render(),
  );
  assert.match(out, /No log output/);
});

test("a failed run surfaces the host's own reason, not a generic one", () => {
  const out = renderToString(
    inst(
      { enabled: true },
      {
        phase: "failed",
        mode: "logs",
        result: { status: "rejected", error: "not a container this dashboard may read logs for." },
      },
    ).render(),
  );
  assert.match(out, /not a container this dashboard may read logs for/);
});
