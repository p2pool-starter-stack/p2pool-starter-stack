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

import { WorkerChartCard } from "./chart.mjs";
import { ConfigProvenance, HistoryRow, STATUS_META } from "./confighistory.mjs";
import { SECRET_HINT } from "./configlogic.mjs";
import { loadPref, savePref } from "./logic.mjs";
import { Component, createRef, html } from "./preact.mjs";
import { AdoptRigForm } from "./workeradopt.mjs";
import {
  buildChartMarkers,
  buildFields,
  buildTableChanges,
  fieldNote,
  jsonSyntaxError,
  parseJsonChanges,
} from "./workerlogic.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 40; // ~80s — the host dials the rig then polls its /status
// ~5 min — covers spool latency + the host runner's own 90s rig-poll cap (#597). A rebuild that
// outlives the cap lands as "accepted"; the badge clears on its own once the rig reports the
// new version, so polling longer here buys nothing.
const UPGRADE_POLL_MAX = 150;

// Poll the shared control-result endpoint until a terminal outcome lands, skipping the interim
// "running". The apply can briefly out-run the dashboard, so tolerate a transient fetch failure.
async function pollWorkerResult(id, max = POLL_MAX) {
  for (let i = 0; i < max; i++) {
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
  const note = fieldNote(field.source);
  return html`<label class="config-field"><span class="config-field-name">${field.key}${note && html` <span class="text-muted text-xs">${note}</span>`}</span>${input}</label>`;
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
      mode: loadPref("dashboardWorkerMode", ["table", "json"], "table"), // persisted (#658)
      tableEdits: {},
      editText: "",
      jsonError: null,
      busy: false,
      result: null,
      // One-click rig upgrade (#597): a two-step arm → confirm, its own in-flight flag (a build
      // can run minutes) and its own result line, independent of the config editor's.
      upgArmed: false,
      upgBusy: false,
      upgResult: null,
      // Per-worker hashrate chart (#1013): its own range preference (persisted, like the editor
      // mode above) and its own loading flag — a range switch refetches ONLY the chart data
      // (loadChart), never the full load(), so it can't wipe an in-progress config edit.
      chartRange: loadPref("dashboardWorkerChartRange", ["24h", "1w", "all"], "24h"),
      chartLoading: false,
    };
    this.dialogRef = createRef();
  }

  componentDidMount() {
    this.load();
    this.dialogRef.current?.showModal();
  }

  setMode(mode) {
    savePref("dashboardWorkerMode", mode);
    this.setState({ mode });
  }

  async load() {
    this.setState({ phase: "loading", error: null });
    try {
      const res = await fetch(
        `/api/worker?name=${encodeURIComponent(this.props.name)}&range=${this.state.chartRange}`,
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const detail = await res.json();
      // Prefill the editor with the last-applied writable config, or an empty object to start from.
      const editText = JSON.stringify(detail.last_applied || {}, null, 2);
      this.setState({ phase: "ready", detail, editText, tableEdits: {}, jsonError: null });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // Hashrate chart range change (#1013): re-fetch /api/worker at the new range and replace ONLY
  // detail.hashrate_history — unlike load(), this must never reset tableEdits/editText/phase, or
  // clicking a range button mid-edit would silently drop the operator's in-progress changes.
  async loadChart(range) {
    this.setState({ chartLoading: true });
    try {
      const res = await fetch(
        `/api/worker?name=${encodeURIComponent(this.props.name)}&range=${range}`,
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const detail = await res.json();
      this.setState((s) => ({
        chartLoading: false,
        detail: { ...s.detail, hashrate_history: detail.hashrate_history },
      }));
    } catch {
      this.setState({ chartLoading: false });
    }
  }

  setChartRange(range) {
    savePref("dashboardWorkerChartRange", range);
    this.setState({ chartRange: range });
    return this.loadChart(range);
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
      const fields = buildFields(detail.writable_keys, detail.last_applied, detail.rig_config);
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

  // One-click rig upgrade (#597). POSTs {worker, version} only — the version is the badge's
  // latest, a proposal the HOST re-derives and the rig bounds; this client never picks a target.
  // 202 means spooled: poll with the long budget (the rig may rebuild its miner, ~10 min).
  async upgrade() {
    const version = this.state.detail.rigforge_update.latest;
    this.setState({ upgArmed: false, upgBusy: true, upgResult: { status: "running" } });
    try {
      const res = await fetch("/api/control/worker-upgrade", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ worker: this.props.name, version }),
      });
      let out = await res.json();
      if (res.status === 202 && out.id) out = await pollWorkerResult(out.id, UPGRADE_POLL_MAX);
      this.setState({ upgBusy: false, upgResult: out });
      this.load(); // an applied upgrade clears the badge once the rig reports the new version
    } catch (e) {
      this.setState({ upgBusy: false, upgResult: { status: "error", error: String(e) } });
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
    const {
      mode,
      tableEdits,
      editText,
      jsonError,
      busy,
      result,
      upgArmed,
      upgBusy,
      upgResult,
      chartRange,
      chartLoading,
    } = this.state;
    const canEdit = detail.control_enabled && detail.editable;
    return html`
        <div class="worker-inspect-body">
            <div class="stat-grid">
                <${InfoCard} label="Status" value=${detail.status || "—"} />
                <${InfoCard} label="Hashrate (1m)" value=${detail.hashrate || "—"} />
                <${InfoCard} label="RigForge" value=${detail.rigforge ? detail.rigforge.version || "yes" : "—"} />
            </div>
            ${
              // This rig runs an older RigForge (#596) — the badge links to the release notes;
              // with the control channel on and an operator-set host, the one-click upgrade
              // button (#597) appears beside it: arm → confirm → POST → poll (a rig rebuild can
              // take ~10 min; the rig rolls back on a build that doesn't come back live).
              detail.rigforge_update &&
              detail.rigforge_update.available &&
              detail.rigforge_update.url
                ? html`<p class="mt-1"><a class="badge badge-accent" href=${detail.rigforge_update.url}
                        target="_blank" rel="noopener noreferrer"
                        title=${"A newer RigForge release is available: " + detail.rigforge_update.latest}
                     >New RigForge release ${detail.rigforge_update.latest} available ↗</a>${
                       canEdit && !upgBusy
                         ? upgArmed
                           ? html` <button class="btn-toggle" disabled=${busy}
                                 title=${"Ask the rig to upgrade itself to " + detail.rigforge_update.latest + " now"}
                                 onClick=${() => this.upgrade()}>Confirm upgrade</button>
                               <button class="btn-toggle" onClick=${() => this.setState({ upgArmed: false })}>Cancel</button>`
                           : html` <button class="btn-toggle" disabled=${busy}
                                 title="Upgrade this rig's RigForge to the latest release (its miner may rebuild, ~10 min)"
                                 onClick=${() => this.setState({ upgArmed: true, upgResult: null })}>Upgrade rig…</button>`
                         : null
}${
                       upgBusy
                         ? html` <span class="text-muted text-small">upgrading — a rebuild can take minutes…</span>`
                         : null
}</p>`
                : null
            }
            <${StatusLine} result=${upgResult} />
            ${detail.rigforge ? html`<${StatsTable} stats=${detail.rigforge.stats} />` : null}

            <h4 class="mt-2">Hashrate${chartLoading ? html` <span class="text-muted text-small">refreshing…</span>` : null}</h4>
            <${WorkerChartCard}
                chart=${{
                  hashrate: detail.hashrate_history?.hashrate || [],
                  markers: buildChartMarkers(detail.hashrate_history?.markers),
                }}
                range=${chartRange}
                onRange=${(r) => this.setChartRange(r)} />

            <h4 class="mt-2">Edit config</h4>
            ${
              canEdit
                ? html`
            <p class="text-muted text-xs">Writable keys: <span class="font-mono">${(detail.writable_keys || []).join(", ")}</span>. Prefilled with what the rig is running now, read from its own feed. A box falls back to the last config applied from here, or says so when the value cannot be read at all — a rig that is offline, or one running a RigForge older than the release that started publishing them. The rig validates and rolls back if the miner doesn't come back live.</p>
            <div class="toggle-group mb-1" role="group" aria-label="Worker config mode">
                <button class=${"btn-toggle" + (mode === "table" ? " active" : "")} aria-pressed=${mode === "table"}
                    title="View the config as a table" onClick=${() => this.setMode("table")}>Table</button>
                <button class=${"btn-toggle" + (mode === "json" ? " active" : "")} aria-pressed=${mode === "json"}
                    title="View the raw config JSON" onClick=${() => this.setMode("json")}>JSON</button>
            </div>
            ${
              mode === "table"
                ? html`<div>
                    ${buildFields(detail.writable_keys, detail.last_applied, detail.rig_config).map(
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
                : detail.control_enabled
                  ? html`<${AdoptRigForm} name=${this.props.name} ip=${detail.ip} onAdopted=${() => this.load()} />`
                  : html`<p class="text-muted text-small">Config editing is off. Enable dashboard.control (which needs a dashboard password) to edit a rig's config.</p>`
            }

            <h4 class="mt-2">History</h4>
            <${ConfigProvenance} origin=${detail.config_origin} meta=${detail.rig_config_meta} drift=${detail.config_drift} />
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
// variant (bad governor, throttling, thermal hold) also colours its value; every value — including
// the plain `outline` metrics with no entry below — gets the base `.stat-value` colour/weight
// (#1232: an uncoloured value used to fall back to the dialog's ambient text and read as disabled).
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
                    <td class=${("stat-value " + (STAT_VALUE_CLS[s.variant] || "")).trim()}>${s.value}</td>
                </tr>`,
            )}</tbody>
        </table>
    </div>`
    : null;
