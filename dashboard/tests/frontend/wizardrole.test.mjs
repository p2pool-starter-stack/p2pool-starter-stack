// The setup wizard's role select (mining_dashboard/web/static/wizard.mjs): what an unconfigured
// machine opens on (#1830), and the single fact it shares with the built-in-miner switch
// (#1831). A sibling of wizard.test.mjs rather than more rows inside it: that file sits at its
// recorded ceiling in docs/dev/file-budget.tsv, and ceilings only go down.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import { WizardApp } from "../../mining_dashboard/web/static/wizard.mjs";
import { renderToString } from "./helpers/render.mjs";

// The published reference as a real machine has it: config.reference.json carries
// local_miner.enabled and documents it OFF (#593), which is what the CLI wizard keeps.
const REF = {
  monero: { wallet_address: "", prune: true },
  p2pool: { pool: "mini" },
  local_miner: { enabled: false },
};
const cfgFor = (enabled) => ({
  monero: { wallet_address: "", prune: true },
  p2pool: { pool: "mini" },
  local_miner: { enabled },
});

// A mounted wizard sitting on a given config. The server round trip is deliberately not driven
// here — loadState's own behaviour is asserted in wizard.test.mjs, and what the SERVER publishes
// for an unconfigured machine is pinned at its own tier in tests/web/test_wizard_role.py.
function appOn(cfg) {
  const inst = new WizardApp({});
  inst.setState = (patch) =>
    Object.assign(inst.state, typeof patch === "function" ? patch(inst.state) : patch);
  Object.assign(inst.state, {
    stage: "setup",
    cfg,
    reference: REF,
    jsonText: JSON.stringify(cfg, null, 2),
  });
  return inst;
}

test("a machine whose config has the miner on opens on Pithead + RigForge (#1830)", () => {
  const out = renderToString(appOn(cfgFor(true)).render());
  assert.match(out, /<select value="both"/); // the select
  assert.match(out, /Nothing to install/); // the switch's own Yes note — the same fact
});

test("a machine whose config keeps the miner off opens on Pithead (#1830 control)", () => {
  // The control that shows the row above can say something else. It is also the real case: a
  // pre-seed, a reinstall pre-fill and a rejected submission all arrive with their own config
  // and win whole over the page's default (tests/web/test_wizard_role.py pins that half).
  const out = renderToString(appOn(cfgFor(false)).render());
  assert.match(out, /<select value="pithead"/);
  assert.doesNotMatch(out, /Nothing to install/);
});

test("the (default) marker names the option an unconfigured machine opens on (#1830)", () => {
  // wizard.py:246 publishes local_miner.enabled true for a machine with no previous config, so
  // the marker belongs on Yes. Nothing else on this page pins any marker's POSITION: the row in
  // wizard.test.mjs asserts option text that survives moving the marker back, so a straight
  // revert of the fix ships green (measured by the non-author reviewer at this head).
  const out = renderToString(appOn(cfgFor(true)).render());
  assert.match(out, /Yes — this machine also mines[^<]*, default\)/);
  // The load-bearing half: matching on Yes alone still passes if the marker is re-added to No.
  assert.doesNotMatch(out, /coordinates the miners \(default\)/);
});

test("the miner switch moves the role select, and so does the JSON pane (#1831)", () => {
  const inst = appOn(cfgFor(false));
  // The switch is the plain field edit the rendered <select> is bound to (FIELDS.localMiner).
  inst.edit("local_miner.enabled")({ target: { value: "true" } });
  assert.match(renderToString(inst.render()), /<select value="both"/);
  inst.edit("local_miner.enabled")({ target: { value: "false" } });
  assert.match(renderToString(inst.render()), /<select value="pithead"/);
  // Hand-edited JSON wins the same way, because it is the same one fact.
  inst.editJson({ target: { value: JSON.stringify(cfgFor(true)) } });
  assert.match(renderToString(inst.render()), /<select value="both"/);
});

test("picking rig IS stored, and outranks whatever the config's miner switch says (#1831)", () => {
  // A rig carries no config at all, so it is the one answer that cannot be read out of one.
  const inst = appOn(cfgFor(true));
  inst.setRole({ target: { value: "rig" } });
  assert.equal(inst.state.role, "rig");
  assert.match(renderToString(inst.render()), /<select value="rig"/);
  assert.equal(inst.state.cfg.local_miner.enabled, true); // untouched: a rig never edits config
  // Back to a coordinator: nothing is stored, and the config answers again.
  inst.setRole({ target: { value: "pithead" } });
  assert.equal(inst.state.role, "");
  assert.equal(inst.state.cfg.local_miner.enabled, false);
  assert.match(renderToString(inst.render()), /<select value="pithead"/);
});
