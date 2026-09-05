// The Configuration view's hidden paths (#1850): keys the page never shows and never changes.
//
// Its own file rather than more of configlogic.test.mjs/configview.test.mjs, because it is one
// defect class spanning both — the hide set, the sections built from it, and the view's load →
// render → propose round trip — and because both of those files sit at or near a budget ceiling.
//
// The absence is the product here, so every assertion of "nothing renders" is paired with a
// control that fires: the same fixture with the key renamed to a NEAR MISS (`sshd`, which
// isHidden must not match) renders it, so a clean result means the hide set worked rather than
// the harness failing to render anything at all.
//
//     node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  editableCandidate,
  isHidden,
  restoreHidden,
} from "../../mining_dashboard/web/static/confighidden.mjs";
import {
  buildSections,
  classifyGroup,
  OTHER_GROUP,
} from "../../mining_dashboard/web/static/configlogic.mjs";
import { ConfigView } from "../../mining_dashboard/web/static/configview.mjs";
import { renderToString } from "./helpers/render.mjs";

// A live-shaped config: the hidden subtree, a sibling from the SAME logical section ssh used to
// share ("System / advanced"), a masked secret, and the underscore metadata the fetch carries.
// The key payload is deliberately not key-shaped: a real ed25519 public-key header trips the
// secret scanner, and the repo's other ssh fixtures use this same obviously-fake marker.
const SSH = { enabled: true, authorized_key: "ssh-ed25519 AAAATEST key@test" };
const CFG = {
  _core_keys: ["monero.wallet_address"],
  _editable_keys: ["monero.wallet_address"],
  monero: { wallet_address: "4AAAA", node_password: { __secret__: true } },
  network: { mtu: 1500 },
  ssh: SSH,
};
// The control fixture: identical but for the key name. `sshd` is a near miss the prefix rule must
// NOT claim — it starts with "ssh" as a string, but is neither `ssh` nor `ssh.` + something.
const NOT_HIDDEN_CFG = { ...CFG, ssh: undefined, sshd: SSH };
delete NOT_HIDDEN_CFG.ssh;

test("isHidden: the exact key and its subtree, and nothing that merely starts with the letters", () => {
  for (const k of ["ssh", "ssh.enabled", "ssh.authorized_key", "ssh.a.b"]) {
    assert.equal(isHidden(k), true, k);
  }
  for (const k of ["sshd", "sshd.enabled", "ssh_extra", "dashboard.ssh", "monero.mode"]) {
    assert.equal(isHidden(k), false, k);
  }
});

test("buildSections: a hidden path produces no form field; its section sibling still does", () => {
  const keys = buildSections(CFG).flatMap((s) => s.fields).map((f) => f.key);
  assert.deepEqual(keys.filter((k) => k.startsWith("ssh")), []);
  assert.ok(keys.includes("network.mtu"), "control: the sibling key in the same section renders");
  // The control fires: the same shape under a name the hide set does not claim DOES render.
  const control = buildSections(NOT_HIDDEN_CFG).flatMap((s) => s.fields).map((f) => f.key);
  assert.ok(control.includes("sshd.enabled"), "control: a near-miss key is still a field");
});

test("the hide set is the mechanism, not the missing LOGICAL_GROUPS entry (#1850)", () => {
  // ssh.* has no group, so classifyGroup sends it to the catch-all — which is exactly why the
  // group list alone could not hide it. Delete the hide set and this key comes back under "Other".
  assert.equal(classifyGroup("ssh.enabled"), OTHER_GROUP);
  const sections = buildSections(CFG).map((s) => s.name);
  assert.ok(!sections.includes(OTHER_GROUP), "no Other section is minted for the hidden key");
});

test("editableCandidate: drops hidden paths and top-level metadata, keeps everything else", () => {
  const out = editableCandidate(CFG);
  assert.equal(out.ssh, undefined);
  assert.equal(out._core_keys, undefined);
  assert.deepEqual(out.network, { mtu: 1500 });
  assert.deepEqual(out.monero.node_password, { __secret__: true }, "the secret sentinel survives");
  assert.ok("sshd" in editableCandidate(NOT_HIDDEN_CFG), "control: a near-miss key is kept");
});

test("editableCandidate: a deep copy — editing the candidate cannot rewrite the fetched config", () => {
  const cfg = JSON.parse(JSON.stringify(CFG));
  const candidate = editableCandidate(cfg);
  candidate.monero.wallet_address = "4BBBB";
  assert.equal(cfg.monero.wallet_address, "4AAAA");
});

test("restoreHidden: the server's hidden subtree comes back verbatim beside the operator's edits", () => {
  const edited = editableCandidate(CFG);
  edited.monero.wallet_address = "4BBBB";
  const out = restoreHidden(edited, CFG);
  assert.deepEqual(out.ssh, SSH, "ssh.* rides through untouched — a commit cannot silently drop it");
  assert.equal(out.monero.wallet_address, "4BBBB");
});

test("restoreHidden: a hidden key typed into the pane (or loaded from a file) is dropped, not honoured", () => {
  const typed = { ...editableCandidate(CFG), ssh: { enabled: true, authorized_key: "ssh-ed25519 AAAATEST-typed key@test" } };
  assert.deepEqual(restoreHidden(typed, CFG).ssh, SSH);
});

test("restoreHidden: a source with no hidden key does not invent one", () => {
  const source = { monero: { wallet_address: "4AAAA" } };
  assert.equal("ssh" in restoreHidden({ ssh: { enabled: true }, monero: {} }, source), false);
});

// --- The view's own round trip -----------------------------------------------------------

async function loadedView(cfg) {
  const inst = new ConfigView({});
  inst.setState = (patch) => Object.assign(inst.state, patch);
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ status: 200, ok: true, json: async () => cfg });
  try {
    await inst.load();
  } finally {
    globalThis.fetch = realFetch;
  }
  return inst;
}

test("load(): the hidden path is in neither the form nor the JSON pane, and renders nowhere", async () => {
  const inst = await loadedView(JSON.parse(JSON.stringify(CFG)));
  assert.equal(inst.state.candidate.ssh, undefined);
  assert.doesNotMatch(inst.state.editText, /ssh/);
  const out = renderToString(inst.render());
  assert.doesNotMatch(out, /ssh/, "no ssh row, no ssh in the pane");
  assert.doesNotMatch(out, /authorized_key/);
  assert.match(out, /mtu/, "control: the sibling field in the same section still renders");
});

test("load(): the control fires — the same config under a name the hide set does not claim renders", async () => {
  const inst = await loadedView(JSON.parse(JSON.stringify(NOT_HIDDEN_CFG)));
  const out = renderToString(inst.render());
  assert.match(out, /authorized_key/, "the view WOULD have shown these keys; the hide set is why it did not");
});

test("buildProposed(): what the pane never showed is committed exactly as the host sent it", async () => {
  const inst = await loadedView(JSON.parse(JSON.stringify(CFG)));
  inst.state.candidate.monero.wallet_address = "4BBBB";
  const { config } = inst.buildProposed();
  // The regression this guards: a proposed config missing ssh.* takes the reference default
  // (ssh.enabled: false), so an unrelated save from a machine with SSH on would turn it off.
  assert.deepEqual(config.ssh, SSH);
  assert.equal(config.monero.wallet_address, "4BBBB");
});
