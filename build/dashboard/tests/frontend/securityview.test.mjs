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

import { fmtEpoch, SecurityPanel } from "../../mining_dashboard/web/static/securityview.mjs";
import { renderToString } from "./helpers/render.mjs";

// Render the panel with its state pre-set (the render probe runs no effects, so the fetches in
// componentDidMount never fire — state is injected directly, like the configview tests).
function renderPanel(state) {
  const panel = new SecurityPanel({});
  panel.state = { access: null, audit: null, error: null, ...state };
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
