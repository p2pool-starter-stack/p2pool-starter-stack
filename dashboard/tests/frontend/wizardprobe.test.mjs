// The remote-node probe report as an operator reads it (#1889). The host refuses to provision when
// a configured node does not answer; this module is what turns that refusal into which endpoint and
// why. Kept DOM-free — every branch here is a boot state nobody can reach by hand.
//
// The fixtures are the producer's shape, taken from node_probe_one in 10-installer-preseed.sh: the
// row keys, the seven reasons, and the host's own `detail` sentence for each.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  NodeProbeReport,
  probeSummary,
} from "../../mining_dashboard/web/static/nodeprobe.mjs";
import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { WizardApp } from "../../mining_dashboard/web/static/wizard.mjs";
import { renderToString } from "./helpers/render.mjs";

const RPC = {
  target: "monero",
  host: "192.168.1.10",
  port: 18081,
  ok: true,
  checked: "rpc",
  reason: "ok",
  detail: "reached 192.168.1.10:18081 and verified it with a live rpc check",
  elapsed_ms: 12,
};
const ZMQ = { ...RPC, port: 18083, checked: "zmq" };
const TARI = {
  ...RPC,
  target: "tari",
  port: 18142,
  checked: "connect",
  detail: "192.168.1.10:18142 accepted a TCP connection; the protocol behind it was NOT checked",
};

// The generic reach sentence the host writes for any failure it cannot name more precisely — the
// one that sends the operator to their host, their port and their LAN switch.
const REACH = "cannot reach the remote Monero node at 192.168.1.10:18081 — check the host, the port, and that the node allows LAN access";

const failed = (reason, over = {}) => ({ ...RPC, ok: false, reason, detail: REACH, ...over });
const report = (probes, over = {}) => ({
  ok: probes.every((p) => p.ok === true),
  configured: probes.length,
  probed: probes.length,
  ...over,
  probes,
});

const rowsOf = (probes, over) => probeSummary(report(probes, over)).rows;
const one = (probe) => rowsOf([probe])[0];
const card = (rep, children) =>
  renderToString(html`<${NodeProbeReport} report=${rep}>${children}<//>`);

// --- the absent report is not a failed one ----------------------------------------------------

test("probeSummary: no usable verdict is nothing to render, not a failure", () => {
  // Same discipline wizard.py reads the file with, repeated here because this module is also the
  // one a second producer will feed. `null` is the ordinary state of a machine older than the
  // report, and of one whose report could not be parsed.
  for (const r of [null, undefined, {}, { probes: [] }]) {
    assert.equal(probeSummary(r), null, JSON.stringify(r));
  }
  // A verdict that is not a real boolean, on a report that DOES carry rows — the rows matter,
  // because otherwise the empty-configuration door below answers for this one and the check here
  // is never exercised. `ok: "false"` is the shape that bites: it is TRUTHY, so reading presence
  // as `!= null` would put "every check passed" over a refusal.
  for (const ok of ["true", "false", 1, 0, null, undefined]) {
    const r = { ok, configured: 2, probed: 2, probes: [RPC, ZMQ] };
    assert.equal(probeSummary(r), null, JSON.stringify(ok));
  }
  // The control that proves those fixtures arm at all: the same report with a real boolean is
  // rendered, so the six above are not passing because nothing reaches the check.
  assert.notEqual(probeSummary({ ok: false, configured: 2, probed: 2, probes: [RPC, ZMQ] }), null);
});

test("probeSummary: a machine that runs its own nodes says nothing at all", () => {
  // 0 of 0 is a PASS on the host and a non-subject on the page: a card about node checks on a
  // machine with no remote node is a puzzle, not reassurance.
  assert.equal(probeSummary({ ok: true, configured: 0, probed: 0, probes: [] }), null);
  assert.equal(card({ ok: true, configured: 0, probed: 0, probes: [] }), "");
  // The sibling that keeps that narrow: one configured endpoint IS a subject.
  assert.notEqual(probeSummary(report([RPC])), null);
});

// --- which endpoint ---------------------------------------------------------------------------

test("rows: the three real endpoints are named apart, and carry the address probed", () => {
  const names = rowsOf([RPC, ZMQ, TARI]).map((r) => r.name);
  assert.equal(new Set(names).size, 3, names.join(" | "));
  assert.match(names[0], /Monero/);
  assert.match(names[1], /Monero/);
  assert.match(names[2], /Tari/);
  assert.deepEqual(
    rowsOf([RPC, ZMQ, TARI]).map((r) => r.where),
    ["192.168.1.10:18081", "192.168.1.10:18083", "192.168.1.10:18142"],
  );
});

test("rows: an endpoint this page has no name for still renders, identified by its address", () => {
  // The probe's vocabulary is expected to grow. A row it cannot name reads vague; it must not read
  // as some other endpoint, and it must not vanish.
  const r = one({ ...RPC, target: "future-chain", checked: "future-check" });
  assert.doesNotMatch(r.name, /Monero|Tari/);
  assert.equal(r.where, "192.168.1.10:18081");
});

test("rows: a host the config left blank drops the address rather than rendering a bare port", () => {
  assert.equal(one({ ...RPC, host: "" }).where, "");
  assert.equal(one({ ...RPC, host: null }).where, "");
});

// --- what a pass proved -----------------------------------------------------------------------

test("rows: a bare TCP connect renders QUALIFIED, never as a verified node", () => {
  // Any socket that accepts satisfies a connect — an ssh forward, a stray container, the right
  // port on the wrong host — and there is no Tari client here to ask further.
  const r = one(TARI);
  assert.equal(r.ok, true);
  assert.match(r.sentence, /not checked/);
  assert.doesNotMatch(r.sentence, /verified|protocol itself/);
  // The sibling that keeps it narrow: a live protocol check says so, and says it differently.
  assert.match(one(RPC).sentence, /live check of the protocol/);
  assert.notEqual(one(RPC).sentence, r.sentence);
});

test("rows: only a strict true is a pass", () => {
  // The report is JSON from a shell script. A string "false" reading as a pass would show a green
  // row for an endpoint the host refused to provision against.
  for (const ok of ["false", "true", 1, 0, null, undefined]) {
    assert.equal(one({ ...RPC, ok }).ok, false, JSON.stringify(ok));
  }
  assert.equal(one(RPC).ok, true);
});

// --- why it failed ----------------------------------------------------------------------------

test("reasons: each of the six failure reasons gets its own sentence", () => {
  const reasons = ["protocol", "timeout", "refused", "auth", "missing-tool", "unknown"];
  const said = reasons.map((r) => one(failed(r)).sentence);
  assert.equal(new Set(said).size, reasons.length, said.join(" | "));
});

test("reasons: refused reads as NOT REACHED, never as reached and declined", () => {
  // One unresolvable host makes the ZMQ leg say `refused` and the RPC leg say `unknown` — neither
  // may claim the node answered, and neither may blame the operator's network.
  const s = one(failed("refused")).sentence;
  assert.match(s, /Not reached/);
  assert.doesNotMatch(s, /answered|declined|refused the connection|your network/i);
  // The sibling: `protocol` is the reason that DOES get to say the port is open, because it is
  // the one where something replied.
  assert.match(one(failed("protocol")).sentence, /port is open/);
});

test("reasons: auth is a dead end, not a reachability failure", () => {
  // The node ANSWERED and wanted a login, and a remote-node config has nowhere to put one. Copy
  // that lumps this in with `refused` sends the operator to re-check a working firewall.
  const s = one(failed("auth")).sentence;
  assert.match(s, /answered/);
  assert.match(s, /login/);
  assert.doesNotMatch(s, /Not reached/);
});

test("reasons: an unrecognised reason did not COMPLETE, and is never reported as NOT REACHED", () => {
  // The probe grows a name-resolution reason next. Inventing a reachability claim for a value this
  // page has never seen is the defect that fix exists to end, so the default must not make one.
  for (const reason of ["dns", "", null, undefined, "ok"]) {
    const s = one(failed(reason)).sentence;
    assert.equal(s, "The check did not complete.", JSON.stringify(reason));
  }
  // The sibling that proves the assertion above is not vacuous: a reason it DOES know reads
  // differently, so "did not complete" is not simply what every row says.
  assert.notEqual(one(failed("refused")).sentence, "The check did not complete.");
});

test("reasons: missing-tool blames THIS machine, and drops the host's sentence that blames yours", () => {
  // curl rc 127 is our binary missing. The host keeps its generic reach text on that row, which
  // names the operator's host, port and LAN switch — every one of them innocent.
  const r = one(failed("missing-tool"));
  assert.match(r.sentence, /fault is here/);
  assert.doesNotMatch(r.sentence, /Not reached/);
  assert.equal(r.detail, "");
  // The sibling that keeps the suppression to the one reason that needs it: the SAME host sentence
  // on a `refused` row is shown, because there it is true.
  assert.equal(one(failed("refused")).detail, REACH);
});

test("rows: a detail the host did not write is dropped rather than rendered as text", () => {
  assert.equal(one(failed("refused", { detail: null })).detail, "");
  assert.equal(one(failed("refused", { detail: 7 })).detail, "");
});

// --- the endpoints that produced no row at all ------------------------------------------------

test("skipped: an endpoint that emitted no row is counted from the array, not from `probed`", () => {
  // `probed` is the producer's own count; the array is what is on screen. In a well-formed report
  // they agree, and in a malformed one only one of them is the truth.
  assert.equal(probeSummary(report([RPC], { configured: 3, probed: 3 })).skipped, 2);
  assert.equal(probeSummary(report([RPC, ZMQ])).skipped, 0);
  assert.equal(probeSummary(report([RPC], { configured: 0 })).skipped, 0);
});

test("skipped: the gap is named on screen, and stays silent when there is none", () => {
  assert.match(card(report([RPC], { configured: 3, ok: false })), /2 of the 3 checks/);
  assert.doesNotMatch(card(report([RPC, ZMQ])), /checks this configuration asks for/);
});

test("skipped: a gap contradicts the headline, whatever the verdict says", () => {
  // `ok: true` beside a gap is unreachable from the shipped producer — its `ok` already implies
  // `probed == configured` — but it is exactly the malformed report `skipped` exists to survive,
  // and the two lines are computed independently. A green "every check passed" above a red "2 of
  // the 3 produced no result" is one card telling the operator both things at once.
  const out = card(report([RPC], { ok: true, configured: 3 }));
  assert.doesNotMatch(out, /Every node check this configuration asks for passed/);
  assert.match(out, /2 of the 3 checks/);
  // The consequence still keys on the verdict, not on the gap: this host published `ok: true` and
  // DID proceed, so claiming setup had stopped would be the opposite lie.
  assert.doesNotMatch(card(report([RPC], { ok: true, configured: 3 }), "Setup does not continue."), /Setup does not continue/);
  // The two controls that keep this narrow: a clean pass still says so, and the gap is what moved
  // the headline — not the mere presence of the paragraph.
  assert.match(card(report([RPC, ZMQ])), /Every node check this configuration asks for passed/);
});

// --- rendered -----------------------------------------------------------------------------------

test("rendered: a failure names the endpoint, the address, the reason and the host's detail", () => {
  const out = card(report([failed("timeout"), ZMQ]));
  assert.match(out, /could not be verified/);
  assert.match(out, /Monero node, RPC port/);
  assert.match(out, /192\.168\.1\.10:18081/);
  assert.match(out, /Nothing answered within the time/);
  assert.match(out, new RegExp(REACH.slice(0, 40).replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
  // The passing sibling endpoint is still shown: "the node is not the problem" is worth as much as
  // naming the one that is.
  assert.match(out, /Monero node, ZMQ port/);
});

test("rendered: a pass does not claim more than the checks proved", () => {
  const out = card(report([RPC, TARI]));
  assert.match(out, /Every node check this configuration asks for passed/);
  // The headline defers to the rows rather than saying every node "answered" — a connect did not.
  assert.match(out, /any socket that accepts satisfies this/);
});

test("rendered: the consequence is the surface's sentence, and only a failure has one", () => {
  const words = "Setup does not continue while a check is failing.";
  assert.match(card(report([failed("refused")]), words), /Setup does not continue/);
  assert.doesNotMatch(card(report([RPC]), words), /Setup does not continue/);
});

test("rendered: the report offers no control — it gates nothing", () => {
  // The gate is the host's: preflight_remote_nodes refuses to provision and hands the form back.
  // A client-side disable would take away the only way out of a failed probe, which is to correct
  // the address and submit again.
  const out = card(report([failed("refused")]), "Setup does not continue.");
  assert.doesNotMatch(out, /<button|<input|<form|disabled/);
});

// --- the seam ------------------------------------------------------------------------------------
// A correct component over a wrong served value is the shape that survived the last fix on this
// page: every component test passed the value in explicitly and saw nothing. So this drives the
// real app against a real /api/wizard-state body and reads what the setup screen actually paints.

async function setupScreen(nodeProbe) {
  const inst = new WizardApp({});
  inst.setState = (patch) => Object.assign(inst.state, patch);
  inst.poll = () => {};
  const real = globalThis.fetch;
  const cfg = { monero: { wallet_address: "", prune: true }, p2pool: { pool: "mini" } };
  globalThis.fetch = async (url) =>
    String(url).includes("/api/wizard-state")
      ? {
          ok: true,
          status: 200,
          json: async () => ({
            stage: "setup",
            config: cfg,
            reference: cfg,
            error: "cannot reach the remote Monero node",
            disks: [],
            handoff: null,
            saved_role: null,
            node_probe: nodeProbe,
          }),
        }
      : { ok: true, status: 200, json: async () => ({}), text: async () => "" };
  await inst.loadState();
  globalThis.fetch = real;
  return renderToString(inst.renderSetup());
}

test("seam: the setup screen paints what /api/wizard-state actually serves as node_probe", async () => {
  const out = await setupScreen(report([failed("protocol"), ZMQ]));
  assert.match(out, /could not be verified/);
  assert.match(out, /Monero node, RPC port/);
  assert.match(out, /port is open/);
  // The consequence sentence belongs to this surface, and this is the only place it is written.
  assert.match(out, /Setup does not continue/);
  // The host's one-line error still stands above it — the report explains that line, never
  // replaces it.
  assert.match(out, /cannot reach the remote Monero node/);
});

test("seam: a machine that was never probed gets the ordinary form, with nothing extra on it", async () => {
  // `null` is what wizard.py serves for an all-local machine and for any host older than the
  // report, and it is the common case — the form must not grow a card for it.
  const out = await setupScreen(null);
  assert.doesNotMatch(out, /could not be verified|node check this configuration/);
  assert.match(out, /What is this machine\?/);
});

test("seam: the submit button stays live under a failed probe", async () => {
  // The gate is the host's. The operator's only way out is to correct the address and submit
  // again, so a failing report must not take the button away.
  const out = await setupScreen(report([failed("refused")]));
  assert.match(out, /<button type="submit">/);
});
