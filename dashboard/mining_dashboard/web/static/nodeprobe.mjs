// The host's remote-node probe report, rendered (#1889). ONE module, because the same report
// reaches an operator on two surfaces — the wizard's setup screen, and the Configuration view's
// preview once the control channel carries a probe of its own — and six failure reasons worded
// two ways is exactly how two surfaces come to disagree about what a failure means.
//
// IT GATES NOTHING. `preflight_remote_nodes` refuses to provision and hands the form back
// (12-firstboot-wizard.sh), which is the same side wizard.py already puts "which step this machine
// is on" on. A client-side disable here would be worse than a courtesy: the only way out of a
// failed probe is to correct the host or the port and submit again, and a disabled button takes
// that away. The CONSEQUENCE sentence is the surface's own, passed in — setup halting and an apply
// being refused are different things — so it arrives as this component's children, while the
// vocabulary below is shared so it cannot drift between the two.

import { html } from "./preact.mjs";

// What each row is, in the operator's terms. A target/check pair this map has no name for still
// renders: the host and port beside it are what identify an endpoint, so an unnamed row reads
// vague rather than wrong.
const ENDPOINTS = {
  "monero:rpc": "Monero node, RPC port",
  "monero:zmq": "Monero node, ZMQ port",
  "tari:connect": "Tari node, gRPC port",
};

// Why a check did not pass. Two of these are not reachability failures at all, and copy that
// lumps them in with the rest sends the operator to check something that is working:
//   - `auth` is a node that ANSWERED and wanted a login. It is a dead end, not a retry — there is
//     nowhere in a remote-node config to put credentials.
//   - `missing-tool` is curl missing on THIS machine. Nothing about the operator's node is known.
// An unlisted reason falls to "did not complete" and never to "not reached": inventing a
// reachability claim for a value this page does not recognise is the defect #1913 names, and the
// probe's vocabulary is expected to grow a name-resolution reason.
const REASONS = {
  protocol: "The port is open, and what is listening there is not the node this expects.",
  timeout: "Nothing answered within the time the check allows.",
  refused: "Not reached — no connection was made to that address.",
  auth: "The node answered, and asked for a login this machine has nowhere to keep.",
  "missing-tool": "This machine could not run the check — the fault is here, not with your node.",
  unknown: "The check did not complete.",
};
const UNRECOGNISED = REASONS.unknown;

// What a pass PROVED, which is not the same claim on every endpoint. A bare TCP connect is
// satisfied by any socket that accepts — an ssh forward, a stray container, the right port on the
// wrong host — and the shipped CLI has no Tari client to ask further, so that pass is always
// reported qualified rather than as a verified node.
const PASSED = {
  connect:
    "The port accepted a connection. What is listening behind it was not checked — any socket that accepts satisfies this.",
};
const PASSED_DEFAULT = "Reached, and it answered a live check of the protocol itself.";

/**
 * What the surfaces render, or null when there is nothing to say: no report, a report whose
 * verdict did not arrive as a real boolean, or a configuration that asked for no remote node at
 * all. An ABSENT report is not a failed one — a machine running its own nodes probes nothing.
 */
export function probeSummary(report) {
  if (!report || typeof report.ok !== "boolean") return null;
  const probes = Array.isArray(report.probes) ? report.probes : [];
  // `configured` is what the config ASKED for; `probes` is what arrived. The gap between them is a
  // skipped endpoint, measured against the array rather than the report's own `probed` count: in a
  // well-formed report the two are the same number, and in a malformed one the array is the thing
  // actually on screen.
  const configured = Number.isInteger(report.configured) ? report.configured : probes.length;
  // Nothing asked and nothing checked is the healthy all-local machine, not a subject. A card
  // about node checks on a machine that has no remote node is a puzzle, so it says nothing.
  if (!configured && !probes.length) return null;
  return {
    ok: report.ok,
    configured,
    skipped: Math.max(0, configured - probes.length),
    rows: probes.map(summariseRow),
  };
}

function summariseRow(p) {
  // Strictly `true`, the same discipline wizard.py reads the top-level verdict with: a string
  // "false" arriving here must not read as a pass on the one screen that would show it.
  const ok = p.ok === true;
  const host = typeof p.host === "string" ? p.host : "";
  return {
    name: ENDPOINTS[`${p.target}:${p.checked}`] || "A node this machine was told to use",
    where: host ? `${host}:${p.port}` : "",
    ok,
    verdict: ok ? "Reached" : "Not verified",
    sentence: ok ? PASSED[p.checked] || PASSED_DEFAULT : REASONS[p.reason] || UNRECOGNISED,
    // The host writes a sentence per row, and for one reason it is actively misleading: a
    // `missing-tool` failure keeps the generic reach text, which names the operator's host, port
    // and LAN switch — none of which has anything to do with a missing curl on this machine.
    // Every other reason either gets a precise sentence from the host or a generic one still true.
    detail: p.reason === "missing-tool" || typeof p.detail !== "string" ? "" : p.detail,
  };
}

export const NodeProbeReport = ({ report, children }) => {
  const s = probeSummary(report);
  if (!s) return null;
  // The headline has to agree with the skipped paragraph below it. `ok` alone would put a green
  // "every check passed" over a red "2 of the 3 produced no result" — unreachable from the shipped
  // producer, whose `ok` already implies `probed == configured`, but this is precisely the
  // malformed report `skipped` exists to survive, and an endpoint that produced no row was not
  // verified. The CONSEQUENCE below deliberately stays on `s.ok`: a host that published `ok: true`
  // DID proceed, so telling the operator setup had stopped would be the opposite lie.
  const passed = s.ok && s.skipped === 0;
  return html`<div class="card">
    <h3 class=${passed ? "c-ok" : "c-bad"}>
      ${
        passed
          ? "Every node check this configuration asks for passed."
          : "A node this machine was told to use could not be verified."
      }
    </h3>
    ${!s.ok && children && html`<p>${children}</p>`}
    <ul class="config-preview-list">
      ${s.rows.map(
        (r) => html`<li>
          <strong>${r.name}</strong>${
            r.where ? html` <code class="wizard-mono">${r.where}</code>` : null
          } — <span class=${r.ok ? "c-ok" : "c-bad"}>${r.verdict}</span>. ${r.sentence}
          ${r.detail ? html`<p class="text-muted">${r.detail}</p>` : null}
        </li>`,
      )}
    </ul>
    ${
      s.skipped > 0 &&
      html`<p class="c-bad">${s.skipped} of the ${s.configured} checks this configuration asks for
      produced no result at all, so nothing here covers them.</p>`
    }
  </div>`;
};
