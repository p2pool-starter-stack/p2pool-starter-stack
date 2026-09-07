// Render probes for the wizard's views (mining_dashboard/web/static/wizard.mjs) — the UX
// promises that used to be asserted against server-rendered HTML, now asserted at the layer
// that actually renders them. Uses the repo's dependency-free vnode walker; no DOM.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  Done,
  Gate,
  Installing,
  InstallSection,
  RestoreSection,
  WizardApp,
} from "../../mining_dashboard/web/static/wizard.mjs";
import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { renderToString } from "./helpers/render.mjs";

const DISKS = [
  { name: "nvme0n1", size: "931.5G", model: "Samsung SSD 990", serial: "S6P1NF0T", state: "empty" },
  { name: "sda", size: "3.6T", model: "WDC WD40EFRX", serial: "WD-WCC7K3", state: "pithead-with-data" },
];

test("gate: says the token is case- and prefix-forgiving", () => {
  const out = renderToString(html`<${Gate} error="" onSubmit=${() => {}} />`);
  assert.match(out, /Case doesn't matter/);
  assert.match(out, /pit-/);
});

const sect = (props) =>
  renderToString(
    html`<${InstallSection} disks=${DISKS} chosen="" confirm="" wipe="keep"
      onPick=${() => {}} onConfirm=${() => {}} onWipe=${() => {}} ...${props} />`,
  );

test("picker: the consequence sits before the truncation point, per disk state", () => {
  const out = sect({});
  // A <select> truncates on the right; bench screenshots cut off exactly the erase/keep words.
  assert.ok(out.indexOf("nvme0n1 — ERASES everything on it") < out.indexOf("931.5G"));
  assert.ok(out.indexOf("sda — holds a previous install") < out.indexOf("3.6T"));
  // Model and serial show — a bare /dev/sda is not enough to choose safely.
  assert.match(out, /Samsung SSD 990/);
  assert.match(out, /S6P1NF0T/);
});

test("picker: an empty disk restates the erase in red, and offers NO wipe choice", () => {
  const destructive = sect({ chosen: "nvme0n1" });
  assert.match(destructive, /Installing to nvme0n1 — this ERASES everything on it/);
  assert.match(destructive, /c-bad/);
  assert.doesNotMatch(destructive, /Keep my data/);
});

test("picker: a previous install offers the three-way data choice as a dropdown", () => {
  const out = sect({ chosen: "sda" });
  assert.match(out, /Keep everything/);
  assert.match(out, /keep the blockchains/);
  assert.match(out, /Wipe everything/);
  // The expensive consequence is named where the choice is made, not discovered later.
  assert.match(out, /re-download from scratch/);
  // Not yet the red warning — that appears only once "all" is chosen.
  assert.doesNotMatch(out, /took days to download/);
});

test("picker: choosing 'wipe everything' surfaces the red consequence line", () => {
  const out = sect({ chosen: "sda", wipe: "all" });
  assert.match(out, /took days to download/);
  assert.match(out, /c-bad/);
});

test("installing: the completion is the shutdown, steps in un-swappable order", () => {
  const out = renderToString(html`<${Installing} status="Installed — the machine…" />`);
  assert.ok(out.indexOf("switch itself off") < out.indexOf("Remove the USB stick"));
  assert.ok(out.indexOf("Remove the USB stick") < out.indexOf("Switch it back on"));
});

test("done without a handoff yet: names the dark period and where the dashboard appears", () => {
  // Before the host publishes credentials (or on the fallback timeout), the page must already
  // say that going unresponsive IS the machine working — a bench session read the dark period
  // as a crash.
  const out = renderToString(html`<${Done} status="" handoff=${null} acked=${false} onAck=${() => {}} />`);
  assert.match(out, /stop responding/);
  assert.match(out, /pithead\.local/);
});

test("handoff card: credentials shown once, provisioning gated on the ack", () => {
  const handoff = {
    username: "admin",
    password: "fixture-password-render-test-only",
    dashboard: "https://pithead.local",
    stratum: "stratum+tcp://pithead.local:3333",
  };
  const card = renderToString(html`<${Done} status="" handoff=${handoff} onAck=${() => {}} />`);
  assert.match(card, /Save this before anything else/);
  assert.match(card, /fixture-password-render-test-only/);
  assert.match(card, /stratum\+tcp:\/\/pithead\.local:3333/);
  assert.match(card, /I saved these/);
  // Once the SERVER drops out of the handoff stage it stops sending the card, and the view
  // shows the dark-period notice instead — a dead tab must read as the machine working.
  const dark = renderToString(html`<${Done} status="" handoff=${null} onAck=${() => {}} />`);
  assert.match(dark, /stop responding/);
  assert.match(dark, /pithead\.local/);
});

// --- app orchestration --------------------------------------------------------------------
// THE gap these tests exist to close. Three bench-visible defects lived in the app's fetch
// orchestration, and nothing covered that layer: pytest proved the endpoints, the render probes
// above prove a view given its props, and between them sat "does the app ask for the right
// thing and render what comes back". The credentials card could never appear for two whole
// releases because submit() read a stage its own setState had not applied yet.

function stubSetState(inst) {
  inst.setState = (patch) => {
    const next = typeof patch === "function" ? patch(inst.state, inst.props) : patch;
    Object.assign(inst.state, next);
  };
}

// A server whose /api/wizard-state answers are scripted per call, so a stage TRANSITION can be
// asserted rather than a single snapshot.
function stubServer(states) {
  const real = globalThis.fetch;
  let i = 0;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/api/wizard-state")) {
      const s = states[Math.min(i++, states.length - 1)];
      return { ok: true, status: 200, json: async () => s };
    }
    if (String(url).includes("/status")) return { ok: true, text: async () => "Working…" };
    return { ok: true, status: 200, json: async () => ({}), text: async () => "" };
  };
  return () => {
    globalThis.fetch = real;
  };
}

const REF = { monero: { wallet_address: "", prune: true }, p2pool: { pool: "mini" } };
const stateFor = (stage, extra = {}) => ({
  stage,
  mode: stage === "installer" ? "installer" : "setup",
  config: REF,
  reference: REF,
  error: null,
  disks: [],
  handoff: null,
  ...extra,
});

async function appOn(states) {
  const inst = new WizardApp({});
  stubSetState(inst);
  // poll() re-arms itself on a timer; left live it keeps node alive forever and couples every
  // assertion to a background loop. The loop's own behaviour is asserted by driving loadState
  // directly, which is all poll() does.
  inst.poll = () => {};
  const restore = stubServer(states);
  await inst.loadState();
  return { inst, restore };
}

test("loadState maps every server stage onto the view it should render", async () => {
  for (const [serverStage, viewStage] of [
    ["setup", "setup"],
    ["installer", "setup"], // the combined form: same view, installer flag set
    ["installing", "installing"],
    ["handoff", "done"],
    ["done", "done"],
  ]) {
    const { inst, restore } = await appOn([stateFor(serverStage)]);
    assert.equal(inst.state.stage, viewStage, `${serverStage} -> ${viewStage}`);
    assert.equal(inst.state.installer, serverStage === "installer", `${serverStage} installer flag`);
    restore();
  }
});

test("an unknown server stage falls back to setup rather than a blank screen", async () => {
  const { inst, restore } = await appOn([stateFor("something-new")]);
  assert.equal(inst.state.stage, "setup");
  restore();
});

test("the handoff arrives through the SAME poll and reaches the view", async () => {
  // The exact bug: the card must appear without a second, separately-raced fetch.
  const handoff = { username: "admin", password: "p".repeat(32), dashboard: "https://x", stratum: "s" };
  const { inst, restore } = await appOn([
    stateFor("done"), // provisioning started, nothing published yet
    stateFor("handoff", { handoff }), // then credentials appear
  ]);
  assert.equal(inst.state.handoff, null);
  await inst.loadState();
  assert.equal(inst.state.stage, "done");
  assert.equal(inst.state.handoff.password.length, 32);
  // And the view actually renders the card from that state — the end of the chain.
  assert.match(renderToString(inst.render()), /Save this before anything else/);
  restore();
});

test("a refresh mid-provision does not walk back into an editable form", async () => {
  const { inst, restore } = await appOn([stateFor("done")]);
  const out = renderToString(inst.render());
  assert.doesNotMatch(out, /Monero payout address/);
  assert.match(out, /stop responding/);
  restore();
});

test("a host rejection returns to the form with the reason and the submitted answers", async () => {
  const attempted = { monero: { wallet_address: "4TYPO" }, p2pool: { pool: "mini" } };
  const { inst, restore } = await appOn([
    stateFor("setup", { config: attempted, error: "bad wallet" }),
  ]);
  assert.equal(inst.state.stage, "setup");
  assert.equal(inst.state.error, "bad wallet");
  const out = renderToString(inst.render());
  assert.match(out, /bad wallet/);
  assert.match(out, /4TYPO/); // no retyping a 95-character address
  restore();
});

test("in-progress edits are not clobbered by a later poll of the server's copy", async () => {
  // The form polls while open; the operator's half-typed address must survive it.
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({
    target: {
      value: JSON.stringify({ monero: { wallet_address: "4MINE" }, p2pool: { pool: "nano" } }),
    },
  });
  await inst.loadState();
  assert.equal(inst.state.cfg.monero.wallet_address, "4MINE");
  assert.equal(inst.state.cfg.p2pool.pool, "nano");
  restore();
});

test("submit carries the auth-mode choice beside the config", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setState({ authMode: "none" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("done"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentBody, /auth_mode=none/);
  assert.match(sentBody, /config=/);
  restore();
});

test("on the installation medium, ONE submit carries config, disk, confirmation and wipe", async () => {
  const { inst, restore } = await appOn([stateFor("installer")]);
  inst.setState({ chosen: "sda", confirm: "sda", wipe: "data" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("handoff"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentBody, /config=/);
  assert.match(sentBody, /disk=sda/);
  assert.match(sentBody, /confirm=sda/);
  assert.match(sentBody, /wipe=data/);
  restore();
});

test("the erase is blocked client-side until the disk name is retyped exactly", async () => {
  const { inst, restore } = await appOn([stateFor("installer")]);
  inst.setState({ chosen: "sda", confirm: "sd" });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /exactly/);
  restore();
});

// --- the form matches the install selection --------------------------------------------------

async function appWithPick(chosen, wipe) {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [
        { name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" },
        { name: "sdb", size: "1T", model: "M", serial: "S", state: "empty" },
      ],
    }),
  ]);
  inst.setState({ chosen, wipe });
  const out = renderToString(inst.render());
  restore();
  return out;
}

test("keep everything: the whole config half disappears — the survivor config wins", async () => {
  const out = await appWithPick("sda", "keep");
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Dashboard login/);
  assert.doesNotMatch(out, /Advanced/);
  assert.match(out, /keeps everything/);
  assert.match(out, /Reinstall the system — keep everything/);
});

test("keep the blockchains still asks the node questions — kept chains only answer for LOCAL nodes", async () => {
  // A machine with local Monero + REMOTE Tari keeps only the Monero chain; hiding the node
  // sections forced Tari local and re-downloaded the very chain remote mode avoids (bench).
  const out = await appWithPick("sda", "data");
  assert.match(out, /Where does Monero data come from/);
  assert.match(out, /Merge-mine Tari\?/);
  assert.match(out, /First sync/);
  assert.match(out, /Payout address/);
  assert.match(out, /Dashboard login/);
});

test("wipe everything (or an empty disk): the full form asks everything", async () => {
  const all = await appWithPick("sda", "all");
  assert.match(all, /Where does Monero data come from/);
  assert.match(all, /First sync/);
  const empty = await appWithPick("sdb", "keep");
  assert.match(empty, /Payout address/);
});

test("chain size, healthchecks and time zone sit under Advanced, not the first-run form", async () => {
  // Audit-confirmed slim first-run (Home Assistant model): these three are the only appliance
  // questions beyond the DIY CLI's own core shortlist, so they move to day-2, not day-1.
  const all = await appWithPick("sda", "all");
  const advancedAt = all.indexOf("Advanced");
  assert.ok(advancedAt > -1, "Advanced pane should render");
  for (const label of ["Chain size", "Healthchecks.io ping URL", "Time zone"]) {
    const at = all.indexOf(label);
    assert.ok(at > -1, `${label} should still render (day-2 need is real)`);
    assert.ok(at > advancedAt, `${label} should render inside the Advanced pane, not the main form`);
  }
  // The primary form's own headings stay above Advanced, unmoved.
  for (const label of ["Payout address", "Dashboard login", "Alerts"]) {
    assert.ok(all.indexOf(label) < advancedAt, `${label} should stay in the primary form`);
  }
});

test("keep everything submits NO config — only the disk request", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  inst.setState({ chosen: "sda", confirm: "sda", wipe: "keep" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("installing"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.doesNotMatch(sentBody, /config=/);
  assert.match(sentBody, /disk=sda/);
  assert.match(sentBody, /wipe=keep/);
  restore();
});

test("submit validates IN PLACE: no view swap, the button narrates, the server moves the page", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({ target: { value: JSON.stringify({ monero: { wallet_address: "4A" } }) } });
  const real = globalThis.fetch;
  globalThis.fetch = async (url) => {
    if (String(url).includes("/submit")) return { ok: true, status: 200, json: async () => ({}) };
    return { ok: true, status: 200, json: async () => stateFor("setup"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  // Still the form — no optimistic page change (the scroll-jump bug) — with the wait narrated.
  assert.equal(inst.state.stage, "setup");
  assert.equal(inst.state.submitting, true);
  assert.match(renderToString(inst.render()), /Validating…/);
  // The server rejects: the wait ends and the reason shows on the same page.
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    json: async () => stateFor("setup", { error: "bad wallet" }),
    text: async () => "",
  });
  await inst.loadState();
  globalThis.fetch = real;
  assert.equal(inst.state.submitting, false);
  assert.match(renderToString(inst.render()), /bad wallet/);
  restore();
});

test("the mine-on-this-box choice is a labeled select naming RigForge, default Yes", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const out = renderToString(inst.render());
  assert.match(out, /Mine on this machine too\?/);
  assert.match(out, /No — this box only coordinates/);
  assert.match(out, /RigForge/);
  restore();
});

test("saying yes promises the built-in miner, never a manual install", async () => {
  // The appliance honours the choice itself now: an operator who answers Yes must not be
  // told to install anything — that instruction pointed at a rig that could never exist
  // on a machine with no shell.
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.editJson({ target: { value: JSON.stringify({ local_miner: { enabled: true } }) } });
  const out = renderToString(inst.render());
  assert.match(out, /Nothing to install/);
  assert.doesNotMatch(out, /install RigForge/i);
  restore();
});

// --- the role select (#797 R3): one page, three shapes ---------------------------------------

test("the role select is the FIRST disclosure, above the disk, reading exactly three names", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  const out = renderToString(inst.render());
  assert.ok(out.indexOf("What is this machine?") < out.indexOf("Install onto"));
  assert.match(out, /Pithead \+ RigForge/);
  assert.match(out, /"rig">RigForge</);
  assert.match(out, /"pithead">Pithead</);
  restore();
});

test("role Pithead + RigForge presets the local-miner switch and keeps the full form", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "both" } });
  assert.equal(inst.state.cfg.local_miner.enabled, true);
  const out = renderToString(inst.render());
  assert.match(out, /Payout address/); // still Pithead's form — no new UI beyond the select
  assert.match(out, /Nothing to install/); // the preset shows as the live switch's Yes note
  // Back to plain Pithead: the documented default returns — today's config, byte for byte.
  inst.setRole({ target: { value: "pithead" } });
  assert.equal(inst.state.cfg.local_miner.enabled, false);
  restore();
});

test("role RigForge collapses the form to pool, worker, password — none of the coordinator", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  const out = renderToString(inst.render());
  assert.match(out, /Pool address/);
  assert.match(out, /Worker name/);
  assert.match(out, /Stratum password/);
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Dashboard login/);
  assert.doesNotMatch(out, /Advanced/);
  assert.doesNotMatch(out, /First sync/);
  restore();
});

test("the rig fields open on the host's discovery, and say when nothing answered", async () => {
  const found = await appOn([
    stateFor("setup", { rig_defaults: { pool: "pithead.local:3333", worker: "hp-tower" } }),
  ]);
  found.inst.setRole({ target: { value: "rig" } });
  assert.equal(found.inst.state.rigPool, "pithead.local:3333");
  assert.equal(found.inst.state.rigWorker, "hp-tower");
  assert.match(renderToString(found.inst.render()), /already filled in/);
  found.restore();
  const none = await appOn([stateFor("setup")]);
  none.inst.setRole({ target: { value: "rig" } });
  assert.match(renderToString(none.inst.render()), /No Pithead answered/);
  none.restore();
});

test("run-from-this-stick appears beside the disks for the rig role ONLY", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  assert.doesNotMatch(renderToString(inst.render()), /Run from this USB stick/);
  inst.setRole({ target: { value: "rig" } });
  const out = renderToString(inst.render());
  assert.match(out, /Run from this USB stick — nothing is erased/);
  // Picking it discloses the rig form with no retype gate — nothing is erased.
  inst.setState({ chosen: "usb" });
  const after = renderToString(inst.render());
  assert.match(after, /Pool address/);
  assert.doesNotMatch(after, /Type the disk name to confirm/);
  assert.match(after, /Validate, then save to this stick/);
  restore();
});

test("a rig submit carries the role and answers — never a config", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  inst.setRole({ target: { value: "rig" } });
  inst.setState({ chosen: "usb", rigPool: "10.0.0.5:3333", rigWorker: "shed-3" });
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit")) {
      sentBody = String(opts.body);
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("handoff"), text: async () => "" };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentBody, /role=rig/);
  assert.match(sentBody, /rig_pool=10.0.0.5%3A3333/);
  assert.match(sentBody, /disk=usb/);
  assert.doesNotMatch(sentBody, /config=/);
  restore();
});

test("an empty pool address is stopped client-side with a named reason", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submit({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /pool address/);
  restore();
});

test("the rig card with no token and no address is worker and pool only — no login", () => {
  const handoff = { role: "rig", worker: "shed-3", stratum: "stratum+tcp://pithead.local:3333" };
  const card = renderToString(
    html`<${Done} status="" handoff=${handoff} installer=${true} stick=${false} onAck=${() => {}} />`,
  );
  assert.match(card, /shed-3/);
  assert.match(card, /stratum\+tcp:\/\/pithead\.local:3333/);
  assert.match(card, /erase the disk and install/); // the ack still releases the erase
  assert.doesNotMatch(card, /Dashboard password/);
  assert.doesNotMatch(card, /Save this before anything else/);
  const stick = renderToString(
    html`<${Done} status="" handoff=${handoff} installer=${true} stick=${true} onAck=${() => {}} />`,
  );
  assert.doesNotMatch(stick, /erase the disk/); // run-from-stick erases nothing
});

test("after the ack, the rig's done view sends the operator to the coordinator, not a link here", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setRole({ target: { value: "rig" } });
  Object.assign(inst.state, { stage: "done", handoff: null });
  const out = renderToString(inst.render());
  assert.match(out, /miner is starting/);
  assert.match(out, /Workers view/); // a rig has no dashboard of its own to point at
  assert.doesNotMatch(out, /nothing mines yet/); // the boot leg is real now
  assert.doesNotMatch(out, /pulling and starting the stack/);
  restore();
});

test("keep on a preserved disk still collapses everything — the rig role included", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  inst.setRole({ target: { value: "rig" } });
  inst.setState({ chosen: "sda", wipe: "keep" });
  const out = renderToString(inst.render());
  assert.doesNotMatch(out, /Pool address/);
  assert.match(out, /keeps everything/);
  restore();
});

test("before a disk is chosen, the page asks ONLY that", async () => {
  const { inst, restore } = await appOn([
    stateFor("installer", {
      disks: [{ name: "sda", size: "1T", model: "M", serial: "S", state: "pithead-with-data" }],
    }),
  ]);
  const out = renderToString(inst.render());
  assert.match(out, /Choose the disk to install onto/);
  assert.match(out, /Target disk/);
  assert.doesNotMatch(out, /Payout address/);
  assert.doesNotMatch(out, /Type the disk name to confirm/);
  assert.doesNotMatch(out, /<button type="submit"/);
  // Picking the disk reveals the rest.
  inst.setState({ chosen: "sda", wipe: "all" });
  const after = renderToString(inst.render());
  assert.match(after, /Payout address/);
  assert.match(after, /Type the disk name to confirm/);
  restore();
});

// --- restore-at-setup (#909, #786 sub-issue B): the config form's alternative -----------------
// Upload an encrypted backup + its passphrase instead of typing a config. Validation is entirely
// host-side (same "container asks, host decides" split); the client wires the two answers up and
// enforces the size cap it can check without a round trip.

test("restore section: names what a restore does and asks for the archive + passphrase", () => {
  const out = renderToString(
    html`<${RestoreSection} file=${null} passphrase="" onFile=${() => {}} onPassphrase=${() => {}} />`,
  );
  assert.match(out, /Restore from a backup/);
  assert.match(out, /emergency-kit passphrase/);
  assert.match(out, /type="file"/);
  assert.match(out, /type="password"/);
});

test("the setup form offers a toggle into restore mode, and back again", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const before = renderToString(inst.render());
  assert.match(before, /Restoring an existing Pithead/);
  assert.doesNotMatch(before, /Restore from a backup/);
  inst.setState({ restoreMode: true });
  const during = renderToString(inst.render());
  assert.match(during, /Restore from a backup/);
  assert.doesNotMatch(during, /Payout address/); // the normal form is gone, not just hidden
  assert.match(during, /Back to the setup form/);
  restore();
});

test("restore mode on the installer asks for the disk before revealing the upload fields", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  inst.setState({ restoreMode: true });
  const before = renderToString(inst.render());
  assert.match(before, /Target disk/);
  assert.doesNotMatch(before, /Restore from a backup/);
  inst.setState({ chosen: "nvme0n1" });
  const after = renderToString(inst.render());
  assert.match(after, /Restore from a backup/);
  restore();
});

test("submitRestore refuses with no file chosen, client-side, before any fetch", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  inst.setState({ restoreMode: true });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /Choose a backup archive/);
  restore();
});

test("submitRestore refuses an oversize file client-side, naming the cap", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const huge = new File([new Uint8Array(10)], "backup.tar.gz.enc");
  Object.defineProperty(huge, "size", { value: 64 * 1024 * 1024 + 1 });
  inst.setState({ restoreMode: true, restoreFile: huge });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.equal(fetched, false);
  assert.match(inst.state.error, /too large/);
  restore();
});

test("submitRestore posts multipart with the archive and passphrase, then waits like a normal submit", async () => {
  const { inst, restore } = await appOn([stateFor("setup")]);
  const file = new File([new Uint8Array(4)], "backup.tar.gz.enc");
  inst.setState({ restoreMode: true, restoreFile: file, restorePassphrase: "fixture-pw" });
  let sentUrl = null;
  let sentBody = null;
  const real = globalThis.fetch;
  globalThis.fetch = async (url, opts) => {
    if (String(url).includes("/submit-restore")) {
      sentUrl = String(url);
      sentBody = opts.body;
      return { ok: true, status: 200, json: async () => ({}) };
    }
    return { ok: true, status: 200, json: async () => stateFor("done"), text: async () => "" };
  };
  await inst.submitRestore({ preventDefault() {} });
  globalThis.fetch = real;
  assert.match(sentUrl, /\/submit-restore$/);
  assert.ok(sentBody instanceof FormData);
  assert.equal(sentBody.get("archive"), file);
  assert.equal(sentBody.get("passphrase"), "fixture-pw");
  assert.equal(inst.state.submitting, true);
  restore();
});

test("submitRestore on the installer requires a disk and the exact retype, like a normal install", async () => {
  const { inst, restore } = await appOn([stateFor("installer", { disks: DISKS })]);
  const file = new File([new Uint8Array(4)], "backup.tar.gz.enc");
  inst.setState({ restoreMode: true, restoreFile: file });
  let fetched = false;
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    fetched = true;
    return { ok: true, status: 200, json: async () => ({}) };
  };
  await inst.submitRestore({ preventDefault() {} });
  assert.equal(fetched, false);
  assert.match(inst.state.error, /Choose the disk/);
  inst.setState({ chosen: "sda", confirm: "wrong" });
  await inst.submitRestore({ preventDefault() {} });
  assert.equal(fetched, false);
  assert.match(inst.state.error, /exactly/);
  globalThis.fetch = real;
  restore();
});

test("a rejected restore returns to restore mode with the reason, not the typed-config form", async () => {
  const { inst, restore } = await appOn([
    stateFor("setup", { error: "wrong passphrase or corrupt archive" }),
  ]);
  inst.setState({ restoreMode: true });
  const out = renderToString(inst.render());
  assert.match(out, /wrong passphrase or corrupt archive/);
  assert.match(out, /Restore from a backup/);
  restore();
});

// --- the token gate: the lockout must read as actionable, not as a dead page -----------------

test("auth: a 429 (lockout) shows the console-token message, not the generic wrong-token one", async () => {
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: false,
    status: 429,
    json: async () => ({ error: "server-side lockout text" }),
  });
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.match(inst.state.error, /too many attempts/i);
  assert.match(inst.state.error, /console/i);
});

test("auth: a genuinely dropped connection reads the same as the 429 it raced", async () => {
  // The exact bug: the lockout's exit used to race the response, so the fetch this app makes
  // rejects instead of resolving 429. Uncaught, that was a silent unhandled rejection — the
  // operator just saw the page do nothing.
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new TypeError("Failed to fetch");
  };
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.match(inst.state.error, /too many attempts/i);
  assert.match(inst.state.error, /console/i);
});

test("auth: an ordinary wrong token still gets the plain message, not the lockout one", async () => {
  const inst = new WizardApp({});
  stubSetState(inst);
  const real = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: false, status: 403, json: async () => ({}) });
  await inst.auth({ preventDefault() {}, target: undefined });
  globalThis.fetch = real;
  assert.equal(inst.state.error, "Wrong token.");
});
