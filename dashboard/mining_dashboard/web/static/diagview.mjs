// Service Diagnostics card (#913 doctor detail, #943 log tail).
//
// WHY IT EXISTS: an appliance operator has no shell. Before this, they could see THAT a service
// was unhealthy and never WHY — the only recourse was the support bundle or a physical console.
// Both actions here are read-only asks: the host runs `doctor --json` or tails one container's
// log, redacts it, and reports. Nothing on this card mutates the stack, which is why neither
// action goes through the typed-confirm modal the committing verbs use.
//
// THE CONTAINER LIST BELOW IS A CONVENIENCE, NOT THE AUTHORITY. The host's own allowlist is
// PITHEAD_DIAG_CONTAINERS in lib/pithead/46a-control-diagnostics.sh, and it is deliberately
// narrower than the compose set — `wallet-rpc` and `tari-wallet` are refused, because the
// redactor is keyed to the launch-line leak class and the wallet daemons are the two whose
// ordinary output most easily carries key material outside it. If this list ever drifts from the
// host's, the host refuses and the panel shows that refusal verbatim rather than reinterpreting
// it. Publishing the list from the host so the two CANNOT drift is filed as a follow-up.

import { pollResult } from "./configview.mjs";
import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const DIAG_POLL_MAX = 40; // ~80s — doctor dials the node RPCs; a log tail answers far sooner.

export const DIAG_CONTAINERS = [
  "tor",
  "monerod",
  "tari",
  "p2pool",
  "xmrig-proxy",
  "dashboard",
  "docker-proxy",
  "docker-control",
  "caddy",
];

// POST an intent, then poll to a terminal result. Exported for node --test: this is the flow;
// the component only maps its outcome onto UI state.
export async function runDiag(path, body) {
  const res = await fetch(`/api/control/${path}`, {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify(body || {}),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const { id } = await res.json();
  return await pollResult(id, "running", DIAG_POLL_MAX);
}

// doctor --json emits {version, exit, summary:{ok,warn,fail}, checks:[{status, message}]} —
// doctor_json in lib/pithead/06-doctor.sh, which splits each report line on a TAB into exactly
// those two fields. There is no per-check name: the message IS the check, so this renders two
// columns, not three. Failures sort first, because a passing check is not why anyone opened this
// card. A document of another shape yields no rows rather than throwing — an operator with no
// shell has nowhere else to look, so the card must still render and say so.
export function doctorRows(doc) {
  const checks = doc && doc.checks;
  if (!Array.isArray(checks)) return [];
  const rank = (c) => (c.status === "fail" ? 0 : c.status === "warn" ? 1 : 2);
  return checks
    .filter((c) => c && typeof c === "object")
    .map((c) => ({
      status: String(c.status ?? "").toLowerCase(),
      message: String(c.message ?? ""),
    }))
    .sort((a, b) => rank(a) - rank(b));
}

// The one-line headline doctor already computed, so the card does not recount what the host
// counted. Returns null when the document carries no summary.
export function doctorSummary(doc) {
  const s = doc && doc.summary;
  if (!s || typeof s !== "object") return null;
  const n = (v) => (Number.isFinite(v) ? v : 0);
  return `${n(s.fail)} failing, ${n(s.warn)} warning, ${n(s.ok)} ok`;
}

const STATUS_CLS = { fail: "status-bad", warn: "status-warn", ok: "status-ok" };

export class DiagnosticsPanel extends Component {
  constructor(props) {
    super(props);
    // idle | running | done | failed
    this.state = { phase: "idle", mode: null, result: null, container: DIAG_CONTAINERS[0] };
  }

  async run(mode) {
    this.setState({ phase: "running", mode, result: null });
    try {
      const out =
        mode === "doctor"
          ? await runDiag("diag-doctor", {})
          : await runDiag("diag-logs", { container: this.state.container, lines: 200 });
      this.setState({ phase: out.status === "applied" ? "done" : "failed", result: out });
    } catch (e) {
      this.setState({ phase: "failed", result: { error: String(e) } });
    }
  }

  renderDoctor(result) {
    const rows = doctorRows(result.doctor);
    if (!rows.length) {
      return html`<p class="text-muted">The host returned a report with no checks in it.</p>`;
    }
    const summary = doctorSummary(result.doctor);
    return html`${summary ? html`<p class="text-muted text-xs">${summary}</p>` : null}
    <div class="table-scroll"><table class="est-table">
        <tbody>
            ${rows.map(
              (r) => html`<tr>
                  <td class=${STATUS_CLS[r.status] || "text-muted"}>${r.status || "—"}</td>
                  <td>${r.message}</td>
              </tr>`,
            )}
        </tbody>
    </table></div>`;
  }

  renderLogs(result) {
    // `note` is the host's own words for "nothing came back" — show it rather than an empty box,
    // which reads as a broken panel.
    if (!result.lines) {
      return html`<p class="text-muted">${result.note || "No log output."}</p>`;
    }
    return html`<pre class="config-error-tail font-mono text-xs">${result.lines}</pre>`;
  }

  renderResult() {
    const { mode, result } = this.state;
    if (!result) return null;
    return html`<div>
        <p class="text-muted text-xs">${
          mode === "doctor"
            ? "Host health report."
            : `Last 200 lines from ${result.container}, redacted on the host.`
        }</p>
        ${mode === "doctor" ? this.renderDoctor(result) : this.renderLogs(result)}
    </div>`;
  }

  render() {
    if (!this.props.enabled) {
      return html`<div class="card">
          <h3>Service diagnostics</h3>
          <p>Diagnostics are off with the rest of the control channel. To enable them, set
          <code>dashboard.control.enabled: true</code> in <code>config.json</code> on the host
          and run <code>./pithead apply</code>. It requires a dashboard login.</p>
      </div>`;
    }
    const { phase, result } = this.state;
    const busy = phase === "running";
    return html`<div class="card">
        <h3>Service diagnostics</h3>
        <p>Run the host's own health check, or read a recent, redacted slice of one service's
        log. Both only read — nothing here changes the stack.</p>
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${busy}
                    onClick=${() => this.run("doctor")}>Run health check</button>
            <select class="btn-toggle" disabled=${busy} value=${this.state.container}
                    onChange=${(e) => this.setState({ container: e.target.value })}>
                ${DIAG_CONTAINERS.map((c) => html`<option value=${c}>${c}</option>`)}
            </select>
            <button class="btn-toggle" disabled=${busy}
                    onClick=${() => this.run("logs")}>Show recent log</button>
        </div>
        ${busy ? html`<p class="text-muted">Asking the host…</p>` : null}
        ${
          phase === "failed"
            ? html`<p class="status-bad">${(result && (result.error || result.note)) || "The host runner reported a failure."}</p>`
            : null
        }
        ${phase === "done" ? this.renderResult() : null}
    </div>`;
  }
}
