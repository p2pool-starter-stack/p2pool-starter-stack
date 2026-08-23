// Security panel (#349): render states of the access-log / audit-trail cards.
//
// The panel is a thin display layer — the server sanitizes every field before it ever reaches
// this component, and Preact renders text nodes, not markup. What IS client logic and tested
// here: the unavailable/empty/populated branches, the rotate nudge appearing only on
// rotate_hint, the 401 rows getting the warning class, and the audit card hiding entirely when
// the control channel is off (audit: null).
//
// Run with Node's built-in test runner:
//     node --test dashboard/tests/frontend/*.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  buildLogQuery,
  fmtEpoch,
  pageFor,
  SecurityPanel,
} from "../../mining_dashboard/web/static/securityview.mjs";
import { renderToString } from "./helpers/render.mjs";

// Render the panel with its state pre-set (the render probe runs no effects, so the fetches in
// componentDidMount never fire — state is injected directly, like the configview tests).
function renderPanel(state) {
  const panel = new SecurityPanel({});
  panel.state = {
    access: null, audit: null, error: null,
    accessFilters: { preset: "all", fromDate: "", toDate: "", q: "" },
    auditFilters: { preset: "all", fromDate: "", toDate: "", q: "" },
    accessPager: { page: 0, size: 20 },
    auditPager: { page: 0, size: 20 },
    ...state,
  };
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

// Pagination (#823 follow-up): the grouping dropdown became a rows-per-page control.

test("pageFor: slices, clamps past-the-end pages, and reports totals", () => {
  const entries = Array.from({ length: 23 }, (_, i) => ({ n: i }));
  const p0 = pageFor(entries, 0, 10);
  assert.deepEqual([p0.page, p0.pages, p0.total, p0.slice.length], [0, 3, 23, 10]);
  const last = pageFor(entries, 2, 10);
  assert.equal(last.slice.length, 3); // the short final page
  // A page past the end (result set shrank under a filter) clamps to the last real page.
  const clamped = pageFor(entries, 9, 10);
  assert.equal(clamped.page, 2);
  // Empty set: one empty page, never NaN/negative.
  const empty = pageFor([], 0, 10);
  assert.deepEqual([empty.page, empty.pages, empty.total], [0, 1, 0]);
  // Hostile size/page inputs fall back instead of dividing into NaN/Infinity.
  for (const badSize of [0, -5, NaN, undefined]) {
    const g = pageFor(entries, 0, badSize);
    assert.deepEqual([g.pages, g.slice.length], [2, 20], `size=${badSize} must fall back to 20`);
  }
  assert.equal(pageFor(entries, NaN, 10).page, 0);
  assert.equal(pageFor(entries, -999, 10).page, 0);
  // The clamp is the safety net behind every pager callback: a stale page (result set shrank,
  // size grew, a reset that never fired) lands on the last REAL page, never off the end.
  assert.equal(pageFor(entries, 5, 100).page, 0);
});

test("cards render the pager: count, rows-per-page select, prev/next with edge disabling", () => {
  const out = renderPanel({
    access: { available: true, entries: Array.from({ length: 23 }, (_, i) => ({
      ts: 1000 + i, status: 200, method: "GET", uri: `/p/${i}`, user: "u" })) },
    audit: [{ ts: "2026-07-20T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "XVB_ENABLED" }],
    accessPager: { page: 1, size: 10 },
  });
  assert.match(out, /23 entries · page 2 of 3/);
  assert.match(out, /aria-label="Access log: rows per page"/);
  assert.match(out, /‹ Prev/);
  assert.match(out, /Next ›/);
  // Edge disabling, actually asserted (vnode walker serializes boolean true as a bare
  // attribute and DROPS false), scoped per pager via its aria-label: the middle-page access
  // pager disables neither button, the single-page audit pager disables both.
  assert.doesNotMatch(out, /disabled aria-label="Access log: previous page"/);
  assert.doesNotMatch(out, /disabled aria-label="Access log: next page"/);
  assert.match(out, /disabled aria-label="Config changes: previous page"/);
  assert.match(out, /disabled aria-label="Config changes: next page"/);
  assert.match(out, /1 entry(?! · page)/); // audit count, no page suffix on one page
  // Page 2 of 3 shows rows 10-19.
  assert.match(out, /\/p\/10/);
  assert.doesNotMatch(out, /\/p\/9</);
  assert.doesNotMatch(out, /\/p\/20/);
  // ...and on the last page, Next is disabled while Prev stays live.
  const lastPage = renderPanel({
    access: { available: true, entries: Array.from({ length: 23 }, (_, i) => ({
      ts: 1000 + i, status: 200, method: "GET", uri: `/p/${i}`, user: "u" })) },
    audit: null,
    accessPager: { page: 2, size: 10 },
  });
  assert.match(lastPage, /disabled aria-label="Access log: next page"/);
  assert.doesNotMatch(lastPage, /disabled aria-label="Access log: previous page"/);
});

test("audit card renders flat rows only — grouping artifacts are gone", () => {
  const out = renderPanel({
    access: { available: true, entries: [] },
    audit: [
      { ts: "2026-07-20T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "A" },
      { ts: "2026-07-19T08:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "B" },
    ],
  });
  assert.doesNotMatch(out, /audit-group-header/);
  assert.doesNotMatch(out, /Group audit trail by/);
  assert.match(out, /XVB|A/);
});

// --- Log navigation (#823) -------------------------------------------------------------

test('buildLogQuery maps presets, date jumps and search onto the endpoint params', () => {
  const NOW = 1_760_000_000;
  // Preset -> a trailing from-window; All -> no params at all.
  assert.equal(buildLogQuery({ preset: '24h', fromDate: '', toDate: '', q: '' }, NOW),
    `?from=${NOW - 86_400}`);
  assert.equal(buildLogQuery({ preset: 'all', fromDate: '', toDate: '', q: '' }, NOW), '');
  // Explicit dates OVERRIDE the preset, and "to" covers that whole day (next-midnight bound).
  const from = Date.parse('2026-07-10') / 1000;
  const to = Date.parse('2026-07-11') / 1000 + 86_400;
  assert.equal(
    buildLogQuery({ preset: '24h', fromDate: '2026-07-10', toDate: '2026-07-11', q: '' }, NOW),
    `?from=${from}&to=${to}`);
  // Search rides along URL-encoded; blank search adds nothing.
  assert.equal(buildLogQuery({ preset: 'all', fromDate: '', toDate: '', q: 'api state' }, NOW),
    '?q=api+state');
  assert.equal(buildLogQuery({ preset: 'all', fromDate: '', toDate: '', q: '   ' }, NOW), '');
});

test('both cards render the shared filter controls with the active preset marked', () => {
  const html = renderPanel({
    access: access(),
    audit: [{ ts: "2026-07-10T12:00:00Z", actor: "admin", action: "commit", status: "applied", keys: "X" }],
    accessFilters: { preset: '24h', fromDate: '', toDate: '', q: '' },
    auditFilters: { preset: 'all', fromDate: '', toDate: '', q: '' },
  });
  assert.match(html, /aria-label="Access log filter"/);
  assert.match(html, /aria-label="Config-change filter"/);
  assert.match(html, /class="btn-range active"[^>]*>24 Hr</); // access card's active preset
  assert.match(html, /type="date"/);
  assert.match(html, /type="search"/);
});

test('filtered results page like everything else, with honest empty messages (#823)', () => {
  // 30 matches at 20/page: page 1 shows rows 0-19, the pager owns the rest — no silent cap.
  const many = access({ entries: Array.from({ length: 30 }, (_, i) => ({
    ts: 1000 + i, status: 200, method: 'GET', uri: `/p/${i}`, user: 'u' })) });
  const filtered = renderPanel({
    access: many,
    accessFilters: { preset: '7d', fromDate: '', toDate: '', q: '' },
  });
  assert.match(filtered, /30 entries · page 1 of 2/);
  assert.match(filtered, /\/p\/19/);
  assert.doesNotMatch(filtered, /\/p\/29/); // page 2's rows wait behind Next
  // No matches under a filter says so, instead of the no-changes-yet copy.
  const empty = renderPanel({
    access: access({ entries: [] }),
    accessFilters: { preset: 'all', fromDate: '', toDate: '', q: 'zzz' },
    audit: [],
    auditFilters: { preset: 'all', fromDate: '', toDate: '', q: 'zzz' },
  });
  assert.match(empty, /No entries match this filter/);
  assert.doesNotMatch(empty, /No config changes have gone through/);
});
