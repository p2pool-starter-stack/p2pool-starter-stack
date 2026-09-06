// The wizard's two opt-in mining questions (mining_dashboard/web/static/wizardmining.mjs):
// merge-mine Tari or not (#1855), join the XvB raffle or not (#1848).
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// Two tiers here on purpose. `tariAnswer` is pure and carries the migration rule, so it is proved
// alone. Everything else is proved through WizardApp's REAL setup form rather than through the
// components in isolation: the defect this replaces was a binding defect — a select that showed
// one answer while the config held another — and a component rendered with hand-made props cannot
// see it. The form's own select is found by its LABEL and its handler is fired, so the assertion
// covers the path an operator's click actually takes.
import assert from "node:assert/strict";
import { test } from "node:test";

import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { WizardApp } from "../../mining_dashboard/web/static/wizard.mjs";
import { TariSection, XvbField, tariAnswer } from "../../mining_dashboard/web/static/wizardmining.mjs";
import { renderToString } from "./helpers/render.mjs";

// --- tariAnswer: the migration rule -----------------------------------------------------------

test("tariAnswer shows back the mode that is stored, off included (#1855)", () => {
  assert.equal(tariAnswer("off"), "off");
  assert.equal(tariAnswer("local"), "local");
  assert.equal(tariAnswer("remote"), "remote");
});

test("tariAnswer reads a config that never mentioned Tari as merge-mining, not as declined", () => {
  // THE MIGRATION TRAP. `tari.mode` did not exist before 2.0, and the host still reads a missing
  // key as `local` (lib/pithead/28-parse-and-validate-config.sh). If this said "off", an upgraded
  // 1.x machine would open the wizard, be told it had declined merge-mining, and write that
  // decline back on submit — turning off a payout the operator never asked to stop.
  for (const missing of [undefined, null, "", {}, 0, false]) {
    assert.equal(tariAnswer(missing), "local", `${JSON.stringify(missing)} must not read as off`);
  }
  // "off" is the exact literal the host accepts; a near-miss is not a decline. It stays a yes on
  // screen and the host rejects it on submit, which fails loudly instead of quietly obeying a
  // typo. The sibling that keeps the row above narrow: the same reader still says off for "off".
  for (const near of ["Off", "OFF", " off", "off ", "no", "false", "disabled"]) {
    assert.equal(tariAnswer(near), "local", `${JSON.stringify(near)} is not the literal off`);
  }
  assert.equal(tariAnswer("off"), "off");
});

// --- the form ---------------------------------------------------------------------------------

// The reference config the server merges under every answer, trimmed to the keys these tests
// read. `tari.mode` is "local" here because that is what config.reference.json says and must keep
// saying — the reference is the host's default for an EXISTING config, not the wizard's answer
// for a new machine. Those two being different is the whole point of #1855.
const REF = {
  monero: { wallet_address: "", prune: true, mode: "local" },
  tari: { mode: "local", wallet_address: "", remote: { host: "", grpc_port: 18142 } },
  p2pool: { pool: "mini" },
  xvb: { enabled: true },
};

const clone = (o) => JSON.parse(JSON.stringify(o));

// A WizardApp sitting on the setup form with `cfg`, with setState applied synchronously so a
// fired handler is visible to the next assertion.
function form(cfg) {
  const inst = new WizardApp({});
  inst.setState = (patch) => {
    Object.assign(inst.state, typeof patch === "function" ? patch(inst.state, inst.props) : patch);
  };
  Object.assign(inst.state, {
    stage: "setup",
    cfg,
    reference: REF,
    jsonText: JSON.stringify(cfg, null, 2),
  });
  return inst;
}

// The vnode walker renderToString does, stopping to collect element vnodes instead of stringifying
// them — the only way to reach a handler, which renderToString drops by design.
function walk(vnode, out = []) {
  if (vnode == null || typeof vnode !== "object") return out;
  if (Array.isArray(vnode)) {
    for (const child of vnode) walk(child, out);
    return out;
  }
  const { type, props = {} } = vnode;
  if (type == null) return out;
  if (typeof type === "function") {
    if (type.prototype && typeof type.prototype.render === "function") {
      const inst = new type(props);
      inst.props = props;
      if (inst.state == null) inst.state = {};
      return walk(inst.render(inst.props, inst.state, inst.context), out);
    }
    return walk(type(props), out);
  }
  out.push(vnode);
  return walk(props.children, out);
}

// The <select> inside the Field whose label reads `label`. Binding the lookup to the label rather
// than to document order is what makes each assertion below a claim about the question an
// operator reads, and keeps it from silently following the wrong control after a reorder.
const controlFor = (kind) => (tree, label) => {
  for (const node of walk(tree)) {
    if (node.type !== "label" || !renderToString(node).includes(label)) continue;
    const found = walk(node).find((n) => n.type === kind);
    if (found) return found;
  }
  return null;
};
const selectFor = controlFor("select");
const inputFor = controlFor("input");

const TARI_Q = "Merge-mine Tari?";
const XVB_Q = "Join the XMRvsBeast raffle?";

const setupOn = (tariMode) => {
  const cfg = clone(REF);
  cfg.tari.mode = tariMode;
  const inst = form(cfg);
  return { inst, tree: inst.renderSetup() };
};

test("the wizard asks whether to merge-mine at all, with No as the first answer (#1855)", () => {
  const { tree } = setupOn("off");
  const select = selectFor(tree, TARI_Q);
  assert.ok(select, "the form asks the merge-mining question");
  const options = walk(select)
    .filter((n) => n.type === "option")
    .map((n) => n.props.value);
  assert.deepEqual(options, ["off", "local", "remote"]);
  // A select truncates on the right and the first option is what an operator who reads nothing
  // gets. Both have to say No.
  assert.match(renderToString(select), /No — mine Monero only/);
});

test("a machine that declined merge-mining reads back as declined, not as local (#1855)", () => {
  // The defect this replaces: the select was `remoteTari ? "remote" : "local"`, which had no way
  // to say off. A config holding "off" rendered as "Run the bundled node on this machine", so the
  // wizard misreported the machine to its own operator, and one touch of that control wrote a yes.
  assert.equal(selectFor(setupOn("off").tree, TARI_Q).props.value, "off");
  assert.equal(selectFor(setupOn("local").tree, TARI_Q).props.value, "local");
  assert.equal(selectFor(setupOn("remote").tree, TARI_Q).props.value, "remote");
});

test("answering the merge-mining question writes tari.mode and nothing else (#1855)", () => {
  for (const answer of ["off", "local", "remote"]) {
    const { inst, tree } = setupOn("local");
    selectFor(tree, TARI_Q).props.onChange({ target: { value: answer } });
    assert.equal(inst.state.cfg.tari.mode, answer, `answering ${answer}`);
    // The JSON pane underneath is what gets submitted, so a field edit that does not reach it
    // is an answer the machine never sees.
    assert.equal(JSON.parse(inst.state.jsonText).tari.mode, answer, `${answer} reaches the JSON`);
  }
});

test("declining Tari asks for no Tari payout address, and no node (#1855)", () => {
  const out = renderToString(setupOn("off").tree);
  assert.doesNotMatch(out, /Tari payout address/);
  assert.doesNotMatch(out, /gRPC port/);
  // The Monero half of the form is untouched by the decline — the machine still mines Monero.
  assert.match(out, /Monero payout address/);
  assert.match(out, /Where does Monero data come from\?/);
});

test("the retired prose does not survive the decline it contradicts (#1855)", () => {
  // "this stack always does both, so it needs both addresses" was true until this issue and is
  // now false at every setting, so it must be gone from the form rather than merely hidden when
  // Tari is off. Prose that explains a behaviour is where the stale claim lives, and it never
  // goes red on its own.
  for (const mode of ["off", "local", "remote"]) {
    const out = renderToString(setupOn(mode).tree);
    assert.doesNotMatch(out, /always does both/, mode);
    assert.doesNotMatch(out, /Where does Tari data come from\?/, mode);
  }
});

test("saying yes asks for the payout address, and only a remote node asks where it is (#1855)", () => {
  const yes = setupOn("local");
  const local = renderToString(yes.tree);
  assert.match(local, /Tari payout address/);
  assert.doesNotMatch(local, /gRPC port/);
  assert.doesNotMatch(local, /Node host/);
  // Named at its own input, not swept for in the page text: /required/ would also match the
  // Monero address's, so the loose form is a check that cannot fail while that field exists.
  assert.equal(inputFor(yes.tree, "Tari payout address").props.required, true);
  assert.equal(inputFor(yes.tree, "Monero payout address").props.required, true);

  const remote = renderToString(setupOn("remote").tree);
  assert.match(remote, /Tari payout address/);
  assert.match(remote, /Node host/);
  assert.match(remote, /gRPC port/);
  assert.match(remote, /not encrypted/);
});

test("the disk cost of saying yes is stated before the answer, not after it (#1855)", () => {
  // The operator's complaint was meeting Tari on a machine that never asked for it. A decline
  // that is cheap to make has to state what it costs to accept, so the figure sits on the
  // question itself and shows at every answer, off included.
  for (const mode of ["off", "local", "remote"]) {
    assert.match(renderToString(setupOn(mode).tree), /about 170 GB/, mode);
  }
});

test("the chain-size advice stops citing a Tari node on a machine that has none (#1855)", () => {
  // Advanced's "pruned Monero plus a remote Tari node is the combination that fits" is disk
  // arithmetic for a machine that runs Tari. With Tari off it is advice about software this
  // machine will not install. It is right for BOTH yes answers — that is what makes the gate a
  // gate on the decline and not on the remote branch.
  assert.doesNotMatch(renderToString(setupOn("off").tree), /combination that fits/);
  assert.match(renderToString(setupOn("local").tree), /combination that fits/);
  assert.match(renderToString(setupOn("remote").tree), /combination that fits/);
});

// --- the raffle (#1848) -----------------------------------------------------------------------

test("the wizard offers the raffle as a first-boot switch (#1848)", () => {
  const { tree } = setupOn("off");
  const select = selectFor(tree, XVB_Q);
  assert.ok(select, "the form asks the raffle question");
  assert.deepEqual(
    walk(select)
      .filter((n) => n.type === "option")
      .map((n) => n.props.value),
    ["true", "false"],
  );
  // The docs' own sentence, so the wizard cannot drift from them or invent a figure.
  assert.match(renderToString(tree), /earns nothing extra/);
});

test("the raffle switch defaults to the reference's answer, not to off (#1848)", () => {
  // xvb.enabled is true in config.reference.json: the raffle is opt-OUT, and a switch that
  // rendered No would show every new machine a state it is not in.
  assert.equal(selectFor(setupOn("off").tree, XVB_Q).props.value, "true");
  const off = clone(REF);
  off.tari.mode = "off";
  off.xvb.enabled = false;
  assert.equal(selectFor(form(off).renderSetup(), XVB_Q).props.value, "false");
  // A config with no xvb key at all still shows the reference's answer rather than blanking.
  const bare = clone(REF);
  bare.tari.mode = "off";
  delete bare.xvb;
  assert.equal(selectFor(form(bare).renderSetup(), XVB_Q).props.value, "true");
});

test("leaving the raffle writes a BOOLEAN false to xvb.enabled (#1848)", () => {
  const { inst, tree } = setupOn("off");
  selectFor(tree, XVB_Q).props.onChange({ target: { value: "false" } });
  // The string "false" is truthy everywhere downstream — in the host's config parse and in the
  // dashboard — so a binding that skipped coercion would read as the raffle still being on.
  assert.equal(inst.state.cfg.xvb.enabled, false);
  assert.notEqual(inst.state.cfg.xvb.enabled, "false");
  assert.equal(JSON.parse(inst.state.jsonText).xvb.enabled, false);
});

// --- the components on their own ---------------------------------------------------------------

test("the Tari note does not send the operator to a view that cannot change tari.mode", () => {
  // The defect this guards: the note promised "turn it on later from the dashboard's
  // Configuration view", and tari.mode is NOT editable there. control_service.py's
  // EDITABLE_ENV_KEY_PATHS carries only dashboard.tari_required, tari.mem_limit, tari.data_dir
  // and tari.clearnet_initial_sync, and the host's own allowlist has no TARI_MODE either — so
  // the field renders greyed and the operator is hunting for a control that is not there.
  //
  // Scoped to TariSection ON PURPOSE. The XvbField sibling says "Changeable later" and that is
  // TRUE (XVB_ENABLED -> xvb.enabled), so a needle swept over the whole form would match the
  // honest row and this guard would be pinning the wrong subject.
  const v = (name) => ({ tariWallet: "", tariRemoteHost: "", xvb: true })[name];
  const on = () => () => {};
  // Source wrapping puts newlines inside the sentences, so match on collapsed whitespace.
  const out = renderToString(html`<${TariSection} answer="off" v=${v} on=${on} />`).replace(
    /\s+/g,
    " ",
  );
  // The needle forbids the PROMISE, not the phrase: the honest copy names the Configuration
  // view too, to say it does NOT carry this switch. A bare /Configuration view/ needle reddens
  // on the fix as readily as on the defect.
  assert.doesNotMatch(out, /(turn|change) it on later from the dashboard/i);
  assert.doesNotMatch(out, /later from the dashboard's Configuration view/i);
  assert.match(out, /Configuration view does not carry this switch/);
  assert.match(out, /setting this machine up again from the boot menu/);
});

test("TariSection and XvbField render from props alone, with no app around them", () => {
  // The form tests above are the ones that matter; this is the narrow guard that neither export
  // reaches back into WizardApp, so a second view can render either one from props alone.
  const v = (name) => ({ tariWallet: "", tariRemoteHost: "", xvb: true })[name];
  const on = () => () => {};
  assert.match(
    renderToString(html`<${TariSection} answer="off" v=${v} on=${on} />`),
    /Merge-mine Tari\?/,
  );
  assert.match(renderToString(html`<${XvbField} v=${v} on=${on} />`), /XMRvsBeast/);
});
