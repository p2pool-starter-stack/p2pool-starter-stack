// The failed-apply wording an appliance operator reads (#1769).
//
// The defect: the host puts `tail -c 2000` of the raw `apply` log into the control result's
// `error` field, server.py returns that dict to the browser unfiltered, and the Configuration
// card rendered the tail bare beneath a sentence naming a host filesystem path. An appliance has
// no shell, so both the path and the log's imperatives are dead ends. #1213 settled the rule for
// doctor's messages; this is the same rule on a surface #1213's dr_* sweep is structurally blind
// to, because the text never passes through dr_*.
//
// Its own file rather than more of configview.test.mjs: that file is at its recorded budget
// ceiling with no headroom, and this is a distinct defect class. It reuses the sibling render
// probe (helpers/render.mjs) rather than duplicating one.
//
// WHAT THIS FILE DOES NOT COVER, so nobody reads it as more than it is:
//   - The App -> ConfigView prop hop (`appliance=${!!state.os_update}`, components.mjs:1044) is
//     verified by reading, not by a test: ConfigView's first paint through App is always its
//     loading card, so this render probe cannot reach the failed state that way. The test below
//     that pins the undefined-prop degradation is what stands in for it.
//   - Escaping. The probe does not escape, so an assertion about it would pass or fail for a
//     reason unrelated to what it names (the same call osverdict.test.mjs makes).
//   - That no CLI verb reaches an appliance at all. That is FALSE by design and asserted false
//     below: the log tail is kept verbatim on both branches, because it is real diagnostic detail
//     and #1769 is a wording problem, not a redaction one.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { applyFailure } from "../../mining_dashboard/web/static/applyfailure.mjs";
import { ConfigView } from "../../mining_dashboard/web/static/configview.mjs";
import { DiagnosticsPanel } from "../../mining_dashboard/web/static/diagview.mjs";
import { renderToString } from "./helpers/render.mjs";

// A faithful failed-commit result: `backup` as 43-control-approval-and-preview.sh writes it, and
// an `error` tail carrying the two host-CLI imperatives #1769 names, verbatim from
// 40-apply-and-render.sh:131 and :289 with `$0` expanded as the operator would see it.
const BACKUP = "/opt/pithead/config.json.bak-control";
const TAIL = [
  "==> Rendering .env",
  "ERROR: Stack is not fully provisioned. Run './pithead setup' first.",
  "WARN: Fix the cause shown above, then re-run './pithead apply' (it will retry the recreate).",
].join("\n");
const RESULT = { status: "failed", error: TAIL, backup: BACKUP };

const host = () => renderToString(applyFailure(RESULT, false));
const appliance = () => renderToString(applyFailure(RESULT, true));

// --- the host branch, which is also the control for the appliance branch's absence -------------

// This test is load-bearing twice over. It pins that a shelled operator still gets the path they
// can act on, and it is the FIRING CONTROL for the assertion below: the same needle, through the
// same instrument, found here and absent there. Without it, "the path is absent on an appliance"
// could be satisfied by a render that produced nothing at all.
test("a host operator is still told where the previous config was kept", () => {
  const out = host();
  assert.match(out, /Apply failed\./);
  assert.match(out, /previous config is kept at/);
  assert.ok(out.includes(BACKUP), "the host branch must name the backup path");
  assert.ok(out.includes("on the host"));
});

test("an appliance operator is never pointed at a host path they cannot reach", () => {
  const out = appliance();
  // Non-empty and saying the right thing FIRST, so the absence below cannot be an empty render.
  assert.ok(out.length > 0);
  assert.match(out, /Apply failed\./);
  assert.match(out, /previous configuration is kept on this machine/);
  // The needle the control above proved this instrument can find.
  assert.ok(!out.includes(BACKUP), "the appliance branch must not name a host path");
  assert.doesNotMatch(out, /config\.json\.bak-control/);
  assert.doesNotMatch(out, /on the host/);
});

// --- the constraint #1769 states explicitly: wording, not redaction ----------------------------

test("the apply log survives verbatim on both branches", () => {
  // Suppressing the tail would trade one bad outcome for another — it is the only diagnostic
  // detail either operator gets. Asserted on BOTH branches so a later "fix" that scrubs the log
  // reddens here rather than passing as an improvement.
  for (const out of [host(), appliance()]) {
    assert.ok(out.includes("Stack is not fully provisioned"));
    assert.ok(out.includes("./pithead setup"));
    assert.ok(out.includes("./pithead apply"));
  }
});

test("the appliance branch frames the log instead of leaving it to read as instructions", () => {
  const out = appliance();
  assert.match(out, /this machine's own log from the failed\s+apply/);
  assert.match(out, /cannot\s+be run from here/);
  // It names only surfaces this page actually has: the form above and the Service diagnostics
  // card rendered beside it in the same card-stack. #1213's rule is that it invents no remedy.
  assert.match(out, /Correct the change in the form above and save again/);
  assert.match(out, /Service diagnostics/);
});

// Finding B of this change's over-engineering pass: the caption names another component's card by
// its heading, and cross-file prose goes stale with nothing red. Pin the two together so renaming
// that card fails here instead of leaving the appliance pointed at a surface that no longer exists.
test("the surface the caption names is the heading Service diagnostics actually renders", () => {
  const panel = renderToString(new DiagnosticsPanel({ enabled: false }).render());
  assert.match(panel, /<h3>Service diagnostics<\/h3>/);
  assert.ok(renderToString(applyFailure(RESULT, true)).includes("Service diagnostics"));
});

// --- the prop is load-bearing, and its absence is silent ---------------------------------------

test("a dropped appliance prop degrades to the host wording, not to a blank card", () => {
  // The failure mode of the App -> ConfigView hop this file cannot otherwise reach: if the prop
  // is ever removed, `this.props.appliance` is undefined and #1769 returns with nothing red. Pin
  // it so the next reader knows the prop carries the whole fix.
  const out = renderToString(applyFailure(RESULT, undefined));
  assert.ok(out.includes(BACKUP));
  assert.equal(out, host());
});

// --- the wiring inside ConfigView --------------------------------------------------------------

// Proves the failed arm of ConfigView's `done` state actually consults this.props.appliance,
// which the module-level tests above cannot see.
function doneCard(props) {
  const view = new ConfigView(props);
  view.state = { ...view.state, phase: "done", result: RESULT };
  return renderToString(view.render());
}

test("ConfigView's failed result routes through the appliance-aware wording", () => {
  const onAppliance = doneCard({ appliance: true });
  assert.match(onAppliance, /previous configuration is kept on this machine/);
  assert.ok(!onAppliance.includes(BACKUP));
  const onHost = doneCard({ appliance: false });
  assert.ok(onHost.includes(BACKUP));
  // Both still offer the way back to the form, so neither branch lost the card's own control.
  assert.match(onAppliance, /Back to the form/);
  assert.match(onHost, /Back to the form/);
});

test("an applied result is untouched by #1769 on either branch", () => {
  for (const props of [{ appliance: true }, { appliance: false }]) {
    const view = new ConfigView(props);
    view.state = { ...view.state, phase: "done", result: { status: "applied" } };
    const out = renderToString(view.render());
    assert.match(out, /Changes applied/);
    assert.doesNotMatch(out, /Apply failed/);
  }
});
