// Security panel (#349): render states of the access-log / audit-trail cards.
//
// The panel is a thin display layer — the server sanitizes every field before it ever reaches
// this component, and Preact renders text nodes, not markup. What IS client logic and tested
// here: the unavailable/empty/populated branches, the rotate nudge appearing only on
// rotate_hint, the 401 rows getting the warning class, and the audit card hiding entirely when
// the control channel is off (audit: null).
//
// Run with Node's built-in test runner:
//     node --test build/dashboard/tests/frontend/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  bucketKey,
  fmtEpoch,
  groupAuditEntries,
  SecurityPanel,
} from "../../mining_dashboard/web/static/securityview.mjs";
import { renderToString } from "./helpers/render.mjs";

// Render the panel with its state pre-set (the render probe runs no effects, so the fetches in
// componentDidMount never fire — state is injected directly, like the configview tests).
function renderPanel(state) {
  const panel = new SecurityPanel({});
  panel.state = { access: null, audit: null, auditGroup: "flat", error: null, ...state };
  return renderToString(panel.render());
}

const access = (over = {}) => ({
  available: true,
  entries: [],
  failures_24h: 0,
  last_failure_ts: null,
  rotate_hint: false,
  ...over,
});

test("fmtEpoch: epoch seconds render, garbage renders blank", () => {
  assert.equal(fmtEpoch(0), "");
  assert.equal(fmtEpoch(Number.NaN), "");
  assert.ok(fmtEpoch(1752148800).length > 0);
});

test("unavailable access log explains itself; no table", () => {
  const out = renderPanel({ access: { available: false, entries: [] } });
  assert.match(out, /No access log yet/);
  assert.doesNotMatch(out, /<table/);
});

test("clean history: zero failures, no rotate nudge", () => {
  const out = renderPanel({
    access: access({ entries: [{ ts: 100, status: 200, method: "GET", uri: "/", user: "admin" }] }),
  });
  assert.match(out, /0 failed logins in the last 24 h/);
  assert.doesNotMatch(out, /Repeated failed logins/);
  assert.match(out, /status-ok/);
});

test("401 burst: rotate nudge names the password and onion rotation commands", () => {
  const out = renderPanel({
    access: access({
      failures_24h: 7,
      rotate_hint: true,
      entries: [{ ts: 100, status: 401, method: "GET", uri: "/", user: "" }],
    }),
  });
  assert.match(out, /7 failed logins/);
  assert.match(out, /Repeated failed logins/);
  assert.match(out, /rotate-dashboard-onion/);
  assert.match(out, /dashboard.auth.password/);
  // The 401 row is styled as a warning.
  assert.match(out, /<td class="status-bad">401<\/td>/);
});

test("audit: null (control channel off) renders no config-changes card", () => {
  const out = renderPanel({ access: access() });
  assert.doesNotMatch(out, /Recent config changes/);
});

test("audit entries render actor, outcome, and the changed key names", () => {
  const out = renderPanel({
    access: access(),
    audit: [
      {
        ts: "2026-07-10T12:00:00Z",
        actor: "admin",
        action: "commit",
        status: "applied",
        keys: "XVB_ENABLED P2POOL_PORT",
      },
    ],
  });
  assert.match(out, /Recent config changes/);
  assert.match(out, /XVB_ENABLED P2POOL_PORT/);
  assert.match(out, /<td class="status-ok">applied<\/td>/);
});

test("audit: empty list says so instead of an empty table", () => {
  const out = renderPanel({ access: access(), audit: [] });
  assert.match(out, /No config changes have gone through the dashboard yet/);
});

test("fetch error surfaces as a message, not a blank panel", () => {
  const out = renderPanel({ error: "TypeError: fetch failed" });
  assert.match(out, /fetch failed/);
});

// #530: hour/day/month grouping for the audit trail.

test("bucketKey: hour/day/month slice the shared ts format; unknown granularity ignored by the caller", () => {
  const ts = "2026-07-20T14:35:00Z";
  assert.equal(bucketKey(ts, "hour"), "2026-07-20T14");
  assert.equal(bucketKey(ts, "day"), "2026-07-20");
  assert.equal(bucketKey(ts, "month"), "2026-07");
  assert.equal(bucketKey(42, "day"), ""); // non-string ts never throws
});

test("groupAuditEntries: flat/unknown granularity returns one ungrouped run", () => {
  const entries = [{ ts: "2026-07-20T00:00:00Z" }, { ts: "2026-07-19T00:00:00Z" }];
  assert.deepEqual(groupAuditEntries(entries, "flat"), [{ bucket: null, entries }]);
  assert.deepEqual(groupAuditEntries(entries, undefined), [{ bucket: null, entries }]);
});

test("groupAuditEntries: contiguous same-day entries collapse into one bucket", () => {
  const entries = [
    { ts: "2026-07-20T14:00:00Z", actor: "a" },
    { ts: "2026-07-20T09:00:00Z", actor: "b" },
    { ts: "2026-07-19T23:00:00Z", actor: "c" },
  ];
  const groups = groupAuditEntries(entries, "day");
  assert.equal(groups.length, 2);
  assert.equal(groups[0].bucket, "2026-07-20");
  assert.equal(groups[0].entries.length, 2);
  assert.equal(groups[1].bucket, "2026-07-19");
  assert.equal(groups[1].entries.length, 1);
});

test("groupAuditEntries: month grouping spans multiple days in one bucket", () => {
  const entries = [
    { ts: "2026-07-20T00:00:00Z" },
    { ts: "2026-07-01T00:00:00Z" },
    { ts: "2026-06-30T00:00:00Z" },
  ];
  const groups = groupAuditEntries(entries, "month");
  assert.deepEqual(
    groups.map((g) => [g.bucket, g.entries.length]),
    [
      ["2026-07", 2],
      ["2026-06", 1],
    ],
  );
});

test("audit card: default flat grouping shows no group-header row (unchanged row output)", () => {
  const out = renderPanel({
    access: { available: true, entries: [] },
    audit: [{ ts: "2026-07-20T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "XVB_ENABLED" }],
  });
  assert.doesNotMatch(out, /audit-group-header/);
  assert.match(out, /XVB_ENABLED/);
});

test("audit card: grouping select appears once there are entries, with the current group selected", () => {
  const out = renderPanel({
    access: { available: true, entries: [] },
    audit: [{ ts: "2026-07-20T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "XVB_ENABLED" }],
    auditGroup: "day",
  });
  assert.match(out, /<select/);
  assert.match(out, /Group by day/);
  // Accessibility parity (#530 review): a bare <select> with no associated <label> has no
  // accessible name for a screen reader — every other select/group control in this codebase
  // carries one (role=group aria-label, or a <label for>, see xvb-tier-select).
  assert.match(out, /aria-label="Group audit trail by"/);
});

test("audit card: day grouping renders one header row per distinct day, spanning the table", () => {
  const out = renderPanel({
    access: { available: true, entries: [] },
    auditGroup: "day",
    audit: [
      { ts: "2026-07-20T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "A" },
      { ts: "2026-07-19T08:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "B" },
    ],
  });
  assert.match(out, /class="audit-group-header"/);
  assert.match(out, /colspan="5"/);
  assert.match(out, /2026-07-20 \(1\)/);
  assert.match(out, /2026-07-19 \(1\)/);
});

test("audit card: empty list shows no grouping select (nothing to group)", () => {
  const out = renderPanel({ access: { available: true, entries: [] }, audit: [] });
  assert.doesNotMatch(out, /<select/);
});
