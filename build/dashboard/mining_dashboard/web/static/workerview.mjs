// Worker Inspect (#185): a per-worker panel to view a rig's live telemetry, edit the writable
// subset of its config, and browse the change history. Opened from the Workers Alive table.
//
// The write path only ever ASKS: it POSTs {worker, changes} to /api/control/worker-apply with the
// X-Pithead-Control CSRF header, and the HOST-side runner resolves the rig's address + token from
// config.json and dials the rig (the container never holds the token, #440). The editor is scoped to
// the writable allowlist the rig enforces; the rig re-validates and rolls back if the miner doesn't
// return to a live hashrate. Prefill comes from Pithead's own last-applied record — the rig's
// enriched feed doesn't expose the writable config values.

import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 40; // ~80s — the host dials the rig then polls its /status

// Poll the shared control-result endpoint until a terminal outcome lands, skipping the interim
// "running". The apply can briefly out-run the dashboard, so tolerate a transient fetch failure.
async function pollWorkerResult(id) {
  for (let i = 0; i < POLL_MAX; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202) continue;
    if (!res.ok) return { status: "error", error: `HTTP ${res.status}` };
    const out = await res.json();
    if (out.status && out.status !== "running") return out;
  }
  return { status: "pending", note: "still applying — reopen to see the outcome" };
}

// A terminal status → a display variant + label. rolled_back and rejected/failed read as bad;
// applied is good; accepted/pending are in-flight.
const STATUS_META = {
  applied: { cls: "status-ok", label: "Applied" },
  accepted: { cls: "status-warn", label: "Queued on the rig" },
  pending: { cls: "status-warn", label: "Pending" },
  rejected: { cls: "status-bad", label: "Rejected" },
  rolled_back: { cls: "status-bad", label: "Rolled back" },
  failed: { cls: "status-bad", label: "Failed" },
  error: { cls: "status-bad", label: "Error" },
};

function StatusLine({ result }) {
  if (!result) return null;
  const meta = STATUS_META[result.status] || { cls: "text-muted", label: result.status };
  const detail = result.reason || result.error || result.note || "";
  return html`
    <p class=${"text-small mt-1 " + meta.cls}>
        ${meta.label}${result.change_id ? html` · <span class="font-mono text-xs">${result.change_id}</span>` : null}
        ${detail ? html`<span class="text-muted"> — ${detail}</span>` : null}
    </p>`;
}

// One history row: the change keys, the outcome, and when. `changes` IS the diff (we record only
// the deltas we authored), so listing its keys is the per-change diff.
function HistoryRow({ row }) {
  const meta = STATUS_META[row.status] || { cls: "text-muted", label: row.status };
  const keys = Object.keys(row.changes || {});
  return html`
    <tr>
        <td class="text-xs text-muted">${row.applied_at || ""}</td>
        <td class="font-mono text-xs">${keys.length ? keys.join(", ") : "—"}</td>
        <td><span class=${"text-small " + meta.cls}>${meta.label}</span></td>
        <td class="text-xs text-muted">${row.reason || ""}</td>
    </tr>`;
}

export class WorkerInspect extends Component {
  constructor(props) {
    super(props);
    // phase: loading | ready | error ; busy = an apply is in flight.
    this.state = {
      phase: "loading",
      detail: null,
      error: null,
      editText: "",
      busy: false,
      result: null,
    };
  }

  componentDidMount() {
    this.load();
  }

  async load() {
    this.setState({ phase: "loading", error: null });
    try {
      const res = await fetch(`/api/worker?name=${encodeURIComponent(this.props.name)}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const detail = await res.json();
      // Prefill the editor with the last-applied writable config, or an empty object to start from.
      const editText = JSON.stringify(detail.last_applied || {}, null, 2);
      this.setState({ phase: "ready", detail, editText });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  async apply() {
    const { detail, editText } = this.state;
    let changes;
    try {
      changes = JSON.parse(editText);
    } catch {
      this.setState({ result: { status: "error", error: "Not valid JSON." } });
      return;
    }
    if (
      !changes ||
      typeof changes !== "object" ||
      Array.isArray(changes) ||
      !Object.keys(changes).length
    ) {
      this.setState({
        result: { status: "error", error: "Enter a non-empty JSON object of writable keys." },
      });
      return;
    }
    // Client-side allowlist check (the server, host runner, and rig all re-check — this is UX).
    const allowed = new Set(detail.writable_keys || []);
    const bad = Object.keys(changes).filter((k) => !allowed.has(k));
    if (bad.length) {
      this.setState({ result: { status: "error", error: `Not writable: ${bad.join(", ")}` } });
      return;
    }
    this.setState({ busy: true, result: { status: "running" } });
    try {
      const res = await fetch("/api/control/worker-apply", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ worker: this.props.name, changes }),
      });
      let out = await res.json();
      if (out.status === "pending") out = await pollWorkerResult(out.id);
      this.setState({ busy: false, result: out });
      this.load(); // refresh telemetry + history with the new row
    } catch (e) {
      this.setState({ busy: false, result: { status: "error", error: String(e) } });
    }
  }

  render() {
    const { phase, detail, error, editText, busy, result } = this.state;
    const { name, onClose } = this.props;
    return html`
        <div class="worker-inspect-overlay" onClick=${(e) => e.target === e.currentTarget && onClose()}>
            <div class="worker-inspect card" role="dialog" aria-label=${"Worker " + name}>
                <div class="flex items-center justify-between">
                    <h3>Worker · ${name}</h3>
                    <button class="btn-toggle" onClick=${onClose} aria-label="Close">✕</button>
                </div>
                ${phase === "loading" ? html`<p class="text-muted">Loading…</p>` : null}
                ${phase === "error" ? html`<p class="status-bad">Couldn't load this worker: ${error}</p>` : null}
                ${phase === "ready" ? this.renderBody(detail, editText, busy, result) : null}
            </div>
        </div>`;
  }

  renderBody(detail, editText, busy, result) {
    const canEdit = detail.control_enabled && detail.editable;
    return html`
        <div class="worker-inspect-body">
            <div class="stat-grid">
                <${InfoCard} label="Status" value=${detail.status || "—"} />
                <${InfoCard} label="Hashrate (1m)" value=${detail.hashrate || "—"} />
                <${InfoCard} label="RigForge" value=${detail.rigforge ? detail.rigforge.version || "yes" : "—"} />
            </div>
            ${detail.rigforge ? html`<${Chips} chips=${detail.rigforge.chips} />` : null}

            <h4 class="mt-2">Edit config</h4>
            ${
              canEdit
                ? html`
            <p class="text-muted text-xs">Writable keys: <span class="font-mono">${(detail.writable_keys || []).join(", ")}</span>.
               Prefilled with the last config applied from the dashboard — the rig's live feed doesn't expose these values.
               The rig validates and rolls back if the miner doesn't come back live.</p>
            <textarea class="worker-edit" spellcheck="false" rows="10" disabled=${busy}
                      value=${editText} onInput=${(e) => this.setState({ editText: e.target.value })}></textarea>
            <div class="mt-1">
                <button class="btn-toggle" disabled=${busy} onClick=${() => this.apply()}>${busy ? "Applying…" : "Apply to rig"}</button>
            </div>
            <${StatusLine} result=${result} />`
                : html`<p class="text-muted text-small">${
                    detail.control_enabled
                      ? "This worker has no host/control_port/token in dashboard.workers[] — set them to edit its config from here."
                      : "Config editing is off. Enable dashboard.control (which needs a dashboard password) to edit a rig's config."
                  }</p>`
            }

            <h4 class="mt-2">History</h4>
            ${
              (detail.history || []).length
                ? html`
            <div class="table-scroll">
                <table class="worker-history">
                    <thead><tr><th>When</th><th>Changed</th><th>Outcome</th><th>Reason</th></tr></thead>
                    <tbody>${detail.history.map((row) => html`<${HistoryRow} row=${row} />`)}</tbody>
                </table>
            </div>`
                : html`<p class="text-muted text-small">No changes applied from the dashboard yet.</p>`
            }
        </div>`;
  }
}

const InfoCard = ({ label, value }) => html`
    <div class="stat-card"><h5>${label}</h5><p>${value}</p></div>`;

const Chips = ({ chips }) =>
  chips && chips.length
    ? html`<div class="badge-row mt-1">${chips.map(
        (c) =>
          html`<span class=${"badge badge-" + c.variant} title=${c.title || ""}>${c.text}</span>`,
      )}</div>`
    : null;
