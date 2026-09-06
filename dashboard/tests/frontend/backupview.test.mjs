// Backup card (#908): the one-click backup POST + poll flow, and the render states of the card
// (disabled / idle / confirm / creating / kit / failed). The kit reveal is the one genuinely new
// bit of client logic — everything else (the poll resilience itself) is pollResult's, already
// covered by configview.test.mjs; these tests only check BackupPanel drives it correctly.
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  BackupPanel,
  buildKitText,
  runBackup,
} from "../../mining_dashboard/web/static/backupview.mjs";
import { renderToString } from "./helpers/render.mjs";

const ID = "11111111-1111-4111-8111-111111111111";
const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

// Same technique configview.test.mjs uses: fire setTimeout synchronously so pollResult's 2s
// cadence doesn't slow the test.
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

test("runBackup posts with no body, skips 'running', and returns the id + terminal result", async () => {
  let posted = null;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/backup") {
      posted = opts;
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    polls++;
    if (polls === 1) return okResult({ status: "running" });
    return okResult({
      status: "applied",
      passphrase: "abc123",
      archive: "pithead-backup-20260813-000000.tar.gz.enc",
      contents: ["config.json"],
      ts: 1_000,
    });
  };
  const out = await withFastPoll(fetchStub, () => runBackup());
  assert.equal(out.id, ID);
  assert.equal(out.status, "applied");
  assert.equal(out.passphrase, "abc123");
  assert.equal(posted.headers["X-Pithead-Control"], "1"); // CSRF guard rides every mutation
  assert.equal(posted.body, undefined); // no operator input travels with this verb
});

test("runBackup surfaces a host-side rejection as the outcome, not a throw", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/backup"
      ? { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) }
      : okResult({ status: "rejected", error: "a backup was started less than 10 minutes ago" });
  const out = await withFastPoll(fetchStub, () => runBackup());
  assert.equal(out.status, "rejected");
  assert.match(out.error, /10 minutes/);
});

test("buildKitText carries the passphrase, archive, and contents — the whole one-time kit", () => {
  const text = buildKitText({
    archive: "pithead-backup-20260813-000000.tar.gz.enc",
    ts: 1_000,
    passphrase: "S3cr3tPass",
    contents: ["config.json", "the dashboard database"],
  });
  assert.match(text, /S3cr3tPass/);
  assert.match(text, /pithead-backup-20260813-000000\.tar\.gz\.enc/);
  assert.match(text, /- config\.json/);
  assert.match(text, /- the dashboard database/);
  assert.match(text, /shown once and cannot be recovered/);
});

function inst(props) {
  const c = new BackupPanel(props);
  c.props = props;
  return c;
}

test("BackupPanel renders the disabled explainer when the control channel is off", () => {
  const out = renderToString(inst({ enabled: false }).render());
  assert.match(out, /off with the rest of the control channel/);
  assert.doesNotMatch(out, /Back up now/);
});

test("BackupPanel idle phase offers the Back up now button", () => {
  const out = renderToString(inst({ enabled: true }).render());
  assert.match(out, /Back up now/);
});

test("BackupPanel confirm phase shows the disruption notice with Cancel/Create", () => {
  const c = inst({ enabled: true });
  c.state.phase = "confirm";
  const out = renderToString(c.render());
  assert.match(out, /stops the stack/);
  assert.match(out, /Create backup/);
  assert.match(out, /Cancel/);
});

test("BackupPanel kit phase reveals the passphrase exactly once, with download links", () => {
  const c = inst({ enabled: true });
  c.state = {
    phase: "kit",
    id: ID,
    result: {
      status: "applied",
      passphrase: "hunter2-strong-pass",
      archive: "pithead-backup-20260813-000000.tar.gz.enc",
      contents: ["config.json", "the dashboard database"],
      ts: 1_000,
    },
  };
  const out = renderToString(c.render());
  assert.match(out, /hunter2-strong-pass/);
  assert.match(out, /shown once and cannot be\s+recovered/);
  assert.match(out, /pithead-backup-20260813-000000\.tar\.gz\.enc/);
  assert.match(out, new RegExp(`/api/control/backup-download\\?id=${ID}`));
  assert.match(out, /Download kit/);
  assert.match(out, /I.ve saved it/);
});

test("BackupPanel failed phase surfaces the host's error", () => {
  const c = inst({ enabled: true });
  c.state = { phase: "failed", id: null, result: { status: "failed", error: "boom" } };
  assert.match(renderToString(c.render()), /boom/);
});

// #1854: the appliance has no shell, so the host-CLI remedy in the explainer above is advice its
// operator cannot act on. The card has to say something true for a box you cannot log into —
// and "wait for the channel" was not true. `enabled` carries no liveness, and the only way an
// appliance reaches this branch is the "No login" setup, where the off state is permanent.
test("BackupPanel on the appliance names the login, not a channel that is coming back (#1854)", () => {
  const out = renderToString(inst({ enabled: false, appliance: true }).render());
  assert.match(out, /set up without a dashboard login/);
  // The defect this replaced: telling an operator to wait for something that never arrives.
  assert.doesNotMatch(out, /not answering|returns with the channel/);
  assert.doesNotMatch(out, /pithead apply/);
  assert.doesNotMatch(out, /config\.json/);
});

test("BackupPanel off a non-appliance host keeps the remedy — the appliance branch is narrow (#1854)", () => {
  const out = renderToString(inst({ enabled: false, appliance: false }).render());
  assert.match(out, /pithead apply/);
});

test("BackupPanel names both halves the operator has to keep — archive and kit (#1854)", () => {
  const out = renderToString(inst({ enabled: true }).render());
  assert.match(out, /Keep both halves/);
  assert.match(out, /passphrase/);
});
