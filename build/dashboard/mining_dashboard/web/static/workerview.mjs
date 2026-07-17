// Worker Inspect (#185): a per-worker panel to view a rig's live telemetry, edit the writable
// subset of its config, and browse the change history. Opened from the Workers Alive table.
//
// The write path only ever ASKS: it POSTs {worker, changes} to /api/control/worker-apply with the
// X-Pithead-Control CSRF header, and the HOST-side runner resolves the rig's address + token from
// config.json and dials the rig (the container never holds the token, #440). The editor is scoped to
// the writable allowlist the rig enforces; the rig re-validates and rolls back if the miner doesn't
// return to a live hashrate. Prefill comes from Pithead's own last-applied record — the rig's
// enriched feed doesn't expose the writable config values.
//
// Two edit modes (#518, ratified in #529): a table editor (one row per writable key, typed off its
// current value) and a raw JSON textarea — both fold to the same {changes} diff and go through the
// one apply() below. A "Load from file" button inside JSON mode reads a local file into the
// textarea (FileReader, no upload) for pushing the same profile to several rigs.

import { SECRET_HINT } from "./configlogic.mjs";
import { Component, createRef, html } from "./preact.mjs";
import {
  buildFields,
  buildTableChanges,
  jsonSyntaxError,
  parseJsonChanges,
} from "./workerlogic.mjs";

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

// One row of the hashrate-by-config table (#492): a config version + the measured hashrate
// (worker_history) aggregated over that version's active window, so an operator can compare
// versions empirically ("config #3 did X, config #4 did Y"). avg/min/max are `null` — rendered
// as "—" — for a version with no samples yet (e.g. the one just applied).
function HashrateByConfigRow({ row }) {
  return html`
    <tr>
        <td class="text-xs text-muted">${row.applied_at || ""}</td>
        <td class="font-mono text-xs">${row.change_id || "—"}</td>
        <td class="text-xs">${row.avg_h15 || "—"}</td>
        <td class="text-xs text-muted">${row.min_h15 || "—"}</td>
        <td class="text-xs text-muted">${row.max_h15 || "—"}</td>
        <td class="text-xs text-muted">${row.sample_count}</td>
    </tr>`;
}

// One table-editor row. `value` falls back to the field's prefilled value until the operator
// edits it (edits is keyed like ConfigView's own `edits` state). A secret row is a masked
// password input (#508) — never the raw sentinel JSON — so it can only be left alone or replaced.
function fieldValue(field, edits) {
  if (field.key in edits) return edits[field.key];
  return field.type === "boolean" ? String(field.value) : field.value;
}

function WorkerField({ field, edits, onEdit, busy }) {
  const value = fieldValue(field, edits);
  let input;
  if (field.type === "boolean") {
    input = html`<select disabled=${busy} value=${value} onChange=${(e) => onEdit(field.key, e.target.value)}>
        <option value="true">true</option><option value="false">false</option>
    </select>`;
  } else if (field.type === "secret") {
    input = html`<input type="password" disabled=${busy} value=${value} placeholder=${SECRET_HINT}
        onInput=${(e) => onEdit(field.key, e.target.value)} />`;
  } else if (field.type === "json") {
    input = html`<textarea class="worker-edit" spellcheck="false" rows="3" disabled=${busy} value=${value}
        onInput=${(e) => onEdit(field.key, e.target.value)}></textarea>`;
  } else {
    input = html`<input type=${field.type === "number" ? "number" : "text"} disabled=${busy} value=${value}
        onInput=${(e) => onEdit(field.key, e.target.value)} />`;
  }
  return html`<label class="config-field"><span class="config-field-name">${field.key}</span>${input}</label>`;
}

export class WorkerInspect extends Component {
  constructor(props) {
    super(props);
    // phase: loading | ready | error ; busy = an apply is in flight. mode picks which editor
    // drives apply(); tableEdits/editText/jsonError are that editor's own state.
    this.state = {
      phase: "loading",
      detail: null,
      error: null,
      mode: "table",
      tableEdits: {},
      editText: "",
      jsonError: null,
      busy: false,
      result: null,
    };
    this.dialogRef = createRef();
  }

  componentDidMount() {
    this.load();
    this.dialogRef.current?.showModal();
  }

  async load() {
    this.setState({ phase: "loading", error: null });
    try {
      const res = await fetch(`/api/worker?name=${encodeURIComponent(this.props.name)}`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const detail = await res.json();
      // Prefill the editor with the last-applied writable config, or an empty object to start from.
      const editText = JSON.stringify(detail.last_applied || {}, null, 2);
      this.setState({ phase: "ready", detail, editText, tableEdits: {}, jsonError: null });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  onJsonInput(text) {
    this.setState({ editText: text, jsonError: jsonSyntaxError(text) });
  }

  // Fill the JSON textarea from a local file (#518) — a FileReader read, never an upload; the
  // operator still reviews and clicks Apply like any other JSON-mode edit.
  onFilePick(e) {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => this.onJsonInput(String(reader.result));
    reader.readAsText(file);
  }

  async apply() {
    const { detail, mode, editText, tableEdits } = this.state;
    let changes;
    if (mode === "json") {
      const out = parseJsonChanges(editText, detail.writable_keys);
      if (out.error) {
        this.setState({ result: { status: "error", error: out.error } });
        return;
      }
      changes = out.changes;
    } else {
      const fields = buildFields(detail.writable_keys, detail.last_applied);
      try {
        changes = buildTableChanges(fields, tableEdits);
      } catch {
        this.setState({
          result: { status: "error", error: "One of the edited rows isn't valid JSON." },
        });
        return;
      }
      if (!Object.keys(changes).length) {
        this.setState({ result: { status: "error", error: "No changes to apply." } });
        return;
      }
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
    const { phase, detail, error } = this.state;
    const { name, onClose } = this.props;
    const close = () => this.dialogRef.current?.close();
    return html`
        <dialog class="worker-inspect card" ref=${this.dialogRef} aria-label=${"Worker " + name}
                onClose=${onClose} onClick=${(e) => e.target === this.dialogRef.current && close()}>
            <div class="flex items-center justify-between">
                <h3>Worker · ${name}</h3>
                <button class="btn-toggle" onClick=${close} aria-label="Close">✕</button>
            </div>
            ${phase === "loading" ? html`<p class="text-muted">Loading…</p>` : null}
            ${phase === "error" ? html`<p class="status-bad">Couldn't load this worker: ${error}</p>` : null}
            ${phase === "ready" ? this.renderBody(detail) : null}
        </dialog>`;
  }

  renderBody(detail) {
    const { mode, tableEdits, editText, jsonError, busy, result } = this.state;
    const canEdit = detail.control_enabled && detail.editable;
    return html`
        <div class="worker-inspect-body">
            <div class="stat-grid">
                <${InfoCard} label="Status" value=${detail.status || "—"} />
                <${InfoCard} label="Hashrate (1m)" value=${detail.hashrate || "—"} />
                <${InfoCard} label="RigForge" value=${detail.rigforge ? detail.rigforge.version || "yes" : "—"} />
            </div>
            ${detail.rigforge ? html`<${StatsTable} stats=${detail.rigforge.stats} />` : null}

            <h4 class="mt-2">Edit config</h4>
            ${
              canEdit
                ? html`
            <p class="text-muted text-xs">Writable keys: <span class="font-mono">${(detail.writable_keys || []).join(", ")}</span>.
               Prefilled with the last config applied from the dashboard — the rig's live feed doesn't expose these values.
               The rig validates and rolls back if the miner doesn't come back live.</p>
            <div class="toggle-group mb-1">
                <button class=${"btn-toggle" + (mode === "table" ? " active" : "")} onClick=${() => this.setState({ mode: "table" })}>Table</button>
                <button class=${"btn-toggle" + (mode === "json" ? " active" : "")} onClick=${() => this.setState({ mode: "json" })}>JSON</button>
            </div>
            ${
              mode === "table"
                ? html`<div>
                    ${buildFields(detail.writable_keys, detail.last_applied).map(
                      (f) => html`<${WorkerField} field=${f} edits=${tableEdits} busy=${busy}
                          onEdit=${(k, v) => this.setState({ tableEdits: { ...tableEdits, [k]: v } })} />`,
                    )}
                  </div>`
                : html`
            <textarea class="worker-edit" spellcheck="false" rows="10" disabled=${busy}
                      value=${editText} onInput=${(e) => this.onJsonInput(e.target.value)}></textarea>
            ${jsonError ? html`<p class="status-bad text-xs">${jsonError}</p>` : null}
            <div class="mt-1">
                <label class="text-muted text-xs">Load from file:
                    <input type="file" accept="application/json,.json" disabled=${busy} onChange=${(e) => this.onFilePick(e)} />
                </label>
            </div>`
            }
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

            <h4 class="mt-2">Hashrate by config version</h4>
            ${
              (detail.hashrate_by_config || []).length
                ? html`
            <div class="table-scroll">
                <table class="worker-history">
                    <thead><tr><th>Applied</th><th>Version</th><th>Avg h15</th><th>Min</th><th>Max</th><th>Samples</th></tr></thead>
                    <tbody>${detail.hashrate_by_config.map((row) => html`<${HashrateByConfigRow} row=${row} />`)}</tbody>
                </table>
            </div>`
                : html`<p class="text-muted text-small">No applied config changes to correlate hashrate against yet.</p>`
            }
        </div>`;
  }
}

const InfoCard = ({ label, value }) => html`
    <div class="stat-card"><h5>${label}</h5><p>${value}</p></div>`;

// The compact Workers-Alive list renders the enriched feed as a horizontal badge row; here in the
// single-rig detail view the same server-built metrics read better as a label → value table (#507).
// `stats` is the {label, value, variant, title} split of the very chips the list uses. A warn/bad
// variant (bad governor, throttling, thermal hold) colours its value; `outline` metrics stay plain.
const STAT_VALUE_CLS = { ok: "status-ok", warn: "status-warn", bad: "status-bad" };
export const StatsTable = ({ stats }) =>
  stats && stats.length
    ? html`
    <div class="table-scroll mt-1">
        <table class="worker-history">
            <tbody>${stats.map(
              (s) => html`
                <tr>
                    <td class="text-muted" title=${s.title || ""}>${s.label}</td>
                    <td class=${STAT_VALUE_CLS[s.variant] || ""}>${s.value}</td>
                </tr>`,
            )}</tbody>
        </table>
    </div>`
    : null;
