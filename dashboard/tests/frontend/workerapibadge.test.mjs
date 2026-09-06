// The Workers-table xmrig-API badge (#1857), rendered through App with a real build_state payload.
//
// The defect: one probe verdict (`api_ok === false`) was answering two different questions, so a
// freshly provisioned appliance rig — mining fine, simply not adopted yet — got the red "api ⚠"
// badge telling its operator to go and check workers.api_auth / api_port. These tests pin the two
// answers apart, and pin the tooltip to a control that actually exists in the state it is shown in.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { clone, renderApp } from "./harness.mjs";

const RED_BADGE = /class="badge badge-bad" title="The dashboard couldn't read this worker's xmrig/;
const NEUTRAL_SPAN = /<span class="badge badge-outline" title="([^"]*)">not adopted<\/span>/;
const NEUTRAL_BUTTON =
  /<button type="button" class="badge badge-outline" title="([^"]*)">not adopted<\/button>/;
const CANNOT_READ = "This rig mines through the proxy, but the dashboard could not read its stats";
// The second remedy is the whole point of design ruling 2: a rig with no `workers.list` entry may
// have a REAL api fault (the list defaults to []), so adoption must never be offered as the only fix.
const HAND_CONFIGURED = /A miner you configured yourself needs its xmrig API checked/;

// The fixture pins both workers to api_ok=null, so nothing here renders until a test asks for it.
function withWorker({ api_ok, adopted, control = false }) {
  const s = clone();
  Object.assign(s.workers[0], { api_ok, adopted });
  s.control_enabled = control;
  return renderApp({ state: s });
}

test("an ADOPTED rig whose feed failed keeps the red api ⚠ badge and its config advice", () => {
  // Unchanged behaviour, and the reason the split has to be a split rather than a replacement:
  // for this rig the original sentence is true and workers.api_auth really is where to look.
  const html = withWorker({ api_ok: false, adopted: true });
  assert.match(html, RED_BADGE);
  assert.match(html, /api ⚠/);
  assert.doesNotMatch(html, /not adopted/);
});

test("an UN-adopted rig gets the neutral badge instead of the red one (#1857)", () => {
  // Nothing is broken, so nothing may read as broken: no red variant, no "api ⚠", and the label
  // carries the state as text rather than leaving colour to do the work (WCAG 1.4.1).
  const html = withWorker({ api_ok: false, adopted: false });
  assert.doesNotMatch(html, RED_BADGE);
  assert.doesNotMatch(html, /api ⚠/);
  assert.match(html, /not adopted/);
});

test("with dashboard control ON the badge is a button pointing at the Adopt form", () => {
  // A button, like RigUpdateBadge: the tooltip carries the instruction, and a title on a <span> is
  // never reachable from the keyboard. The control is named as the UI names it — the form's own
  // button says "Adopt this rig" (workeradopt.mjs), and the way in is the worker's name.
  const html = withWorker({ api_ok: false, adopted: false, control: true });
  const m = html.match(NEUTRAL_BUTTON);
  assert.ok(m, "expected a keyboard-reachable button badge when control is on");
  assert.match(m[1], new RegExp(CANNOT_READ));
  assert.match(m[1], /needs adopting: open it from its name in this table and choose Adopt this rig\./);
  assert.match(m[1], HAND_CONFIGURED);
});

test("with dashboard control OFF the tooltip names the switch, not an impossible instruction", () => {
  // With control off the table renders no name button and Worker Inspect offers no Adopt form, so
  // "open the rig and adopt it" would send the operator after a control that is not on the page.
  const html = withWorker({ api_ok: false, adopted: false });
  const m = html.match(NEUTRAL_SPAN);
  assert.ok(m, "expected a plain span badge when control is off");
  assert.doesNotMatch(html, NEUTRAL_BUTTON);
  assert.match(m[1], new RegExp(CANNOT_READ));
  assert.match(m[1], /needs adopting, which needs dashboard\.control on and a dashboard password\./);
  assert.match(m[1], HAND_CONFIGURED);
  assert.doesNotMatch(m[1], /choose Adopt this rig/);
});

test("a readable feed, or a rig we never probed, badges nothing at all", () => {
  // api_ok true is a healthy rig; null is the SSRF-guarded "we did not look". Neither is a verdict
  // about adoption, and a rig the dashboard never probed must not be labelled from that silence.
  for (const api_ok of [true, null, undefined]) {
    for (const adopted of [true, false, null]) {
      const html = withWorker({ api_ok, adopted });
      assert.doesNotMatch(html, /not adopted/, `api_ok=${api_ok} adopted=${adopted}`);
      assert.doesNotMatch(html, /api ⚠/, `api_ok=${api_ok} adopted=${adopted}`);
    }
  }
});

test("the neutral variant the badge asks for is a real stylesheet rule, not an invented class", () => {
  // The design ruling is explicit that this badge adds NO class: it reuses `badge-outline`, the one
  // neutral variant the stylesheet has (the build-version and RigForge chips already use it). A
  // typo here renders an unstyled badge that no rendering assertion above could notice.
  const css = readFileSync(new URL("../../mining_dashboard/web/static/dashboard.css", import.meta.url), "utf8");
  assert.match(css, /^\.badge-outline \{$/m);
});
