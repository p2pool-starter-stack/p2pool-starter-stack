// Configuration view (#33): edit config.json from the dashboard, through the host-side control
// channel. Flow: GET /api/config (secrets masked) → form → POST /api/control/preview (the host
// runner dry-runs the candidate and returns the same change rows `pithead apply` prints) →
// confirm modal (destructive changes need a typed APPLY) → POST /api/control/commit → result.
// The view only ever ASKS — every request rides the X-Pithead-Control header (CSRF guard) and
// the host decides. When the channel is off the routes 404 and this view explains how to enable.

import { applyEdits, buildSections, SECRET_HINT } from "./configlogic.mjs";
import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 90; // 3 minutes — a commit recreates containers, which can take a while

const Field = ({ field, edits, onEdit }) => {
  const value = field.key in edits ? edits[field.key] : field.value;
  const label = field.path.slice(1).join(".") || field.path[0];
  let input;
  if (field.type === "boolean") {
    input = html`<select value=${String(value)} onChange=${(e) => onEdit(field.key, e.target.value)}>
        <option value="true">true</option>
        <option value="false">false</option>
    </select>`;
  } else if (field.type === "select") {
    input = html`<select value=${value} onChange=${(e) => onEdit(field.key, e.target.value)}>
        ${field.options.map((o) => html`<option value=${o}>${o}</option>`)}
    </select>`;
  } else if (field.type === "secret") {
    input = html`<input type="password" value=${value} placeholder=${SECRET_HINT}
        onInput=${(e) => onEdit(field.key, e.target.value)} />`;
  } else {
    input = html`<input type=${field.type === "number" ? "number" : "text"} value=${value}
        onInput=${(e) => onEdit(field.key, e.target.value)} />`;
  }
  return html`<label class="config-field">
      <span class="config-field-name">${label}</span>
      ${input}
      ${field.warning ? html`<span class="config-field-warning">⚠ ${field.warning}</span>` : null}
  </label>`;
};

const PreviewModal = ({ preview, confirmText, onConfirmText, onConfirm, onCancel, busy }) => {
  const changes = preview.changes || [];
  const armed = !preview.destructive || confirmText === "APPLY";
  return html`<div class="config-modal-backdrop">
      <div class="card config-modal">
          <h3>Review changes</h3>
          ${
            changes.length === 0
              ? html`<p class="text-muted">No configuration changes detected.</p>`
              : html`<ul class="config-preview-list">
                  ${changes.map(
                    (c) => html`<li class=${c.flag === "DEST" ? "config-preview-dest" : ""}>
                        ${c.flag === "DEST" ? "⚠ " : ""}${c.msg}</li>`,
                  )}
              </ul>`
          }
          ${
            preview.destructive
              ? html`<label class="config-confirm-type">Some changes above are disruptive.
                  Type <code>APPLY</code> to confirm:
                  <input type="text" value=${confirmText} onInput=${(e) => onConfirmText(e.target.value)} /></label>`
              : null
          }
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${onCancel} disabled=${busy}>Cancel</button>
              <button class="btn-toggle active" onClick=${onConfirm}
                      disabled=${busy || changes.length === 0 || !armed}>
                  ${busy ? "Applying…" : "Confirm & apply"}
              </button>
          </div>
      </div>
  </div>`;
};

export class ConfigView extends Component {
  constructor(props) {
    super(props);
    this.state = {
      phase: "loading", // loading | disabled | form | previewing | confirm | committing | done | error
      cfg: null,
      sections: [],
      edits: {},
      preview: null,
      confirmText: "",
      result: null,
      error: null,
    };
  }

  componentDidMount() {
    this.load();
  }

  async load() {
    try {
      const res = await fetch("/api/config");
      if (res.status === 404) {
        this.setState({ phase: "disabled" });
        return;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const cfg = await res.json();
      this.setState({ phase: "form", cfg, sections: buildSections(cfg), edits: {} });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // Poll the result endpoint until a terminal result lands. `skip` ignores the still-present
  // preview result while waiting for the commit outcome under the same id.
  async poll(id, skip) {
    for (let i = 0; i < POLL_MAX; i++) {
      await new Promise((r) => setTimeout(r, POLL_MS));
      const res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
      if (res.status === 202) continue;
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const out = await res.json();
      if (out.status === skip) continue;
      return out;
    }
    throw new Error(
      "Timed out waiting for the host runner — is dashboard.control enabled and the pithead-control unit running?",
    );
  }

  async save() {
    this.setState({ phase: "previewing", error: null });
    try {
      const proposed = applyEdits(this.state.cfg, this.state.sections, this.state.edits);
      const res = await fetch("/api/control/preview", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ config: proposed }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let out = await res.json();
      if (out.status === "pending") out = { id: out.id, ...(await this.poll(out.id)) };
      if (out.status === "rejected") {
        this.setState({
          phase: "form",
          error: out.error || "The host runner rejected the config.",
        });
        return;
      }
      this.setState({ phase: "confirm", preview: out, confirmText: "" });
    } catch (e) {
      this.setState({ phase: "form", error: String(e) });
    }
  }

  async commit() {
    const id = this.state.preview.id;
    this.setState({ phase: "committing" });
    try {
      const res = await fetch("/api/control/commit", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ id }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let out = await res.json();
      if (out.status === "pending" || out.status === "previewed")
        out = await this.poll(id, "previewed");
      this.setState({ phase: "done", result: out });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  render() {
    const { phase, sections, edits, preview, confirmText, result, error } = this.state;
    if (phase === "loading")
      return html`<div class="card"><p class="text-muted">Loading configuration…</p></div>`;
    if (phase === "disabled") {
      return html`<div class="card">
          <h3>Configuration</h3>
          <p>Configuration editing is off (the default). To enable it, set
          <code>dashboard.control.enabled: true</code> in <code>config.json</code> on the host and
          run <code>./pithead apply</code>. It requires a dashboard login.</p>
      </div>`;
    }
    if (phase === "error") {
      return html`<div class="card">
          <h3>Configuration</h3>
          <p class="status-bad">${error}</p>
          <button class="btn-toggle" onClick=${() => this.load()}>Reload</button>
      </div>`;
    }
    if (phase === "done") {
      const ok = result.status === "applied";
      return html`<div class="card">
          <h3>Configuration</h3>
          ${
            ok
              ? html`<p class="status-ok">Changes applied — only the affected containers were recreated.</p>`
              : html`<p class="status-bad">Apply failed. The previous config is kept at
                  <code>${result.backup || "config.json.bak-control"}</code> on the host.</p>
                  ${result.error ? html`<pre class="config-error-tail">${result.error}</pre>` : null}`
          }
          <button class="btn-toggle" onClick=${() => this.load()}>Back to the form</button>
      </div>`;
    }
    const busy = phase === "previewing" || phase === "committing";
    const dirty = Object.keys(edits).length > 0;
    return html`<div class="config-view">
        ${error ? html`<div class="card"><p class="status-bad">${error}</p></div>` : null}
        <div class="grid">
            ${sections.map(
              (s) => html`<div class="card config-section">
                  <h3>${s.name}</h3>
                  ${s.fields.map((f) => html`<${Field} field=${f} edits=${edits} onEdit=${(k, v) => this.setState({ edits: { ...edits, [k]: v } })} />`)}
              </div>`,
            )}
        </div>
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${!dirty || busy} onClick=${() => this.save()}>
                ${phase === "previewing" ? "Previewing…" : "Save & preview changes"}
            </button>
            ${dirty ? html`<button class="btn-toggle" disabled=${busy} onClick=${() => this.setState({ edits: {}, error: null })}>Discard edits</button>` : null}
        </div>
        ${
          phase === "confirm" || phase === "committing"
            ? html`<${PreviewModal} preview=${preview} confirmText=${confirmText}
                  onConfirmText=${(t) => this.setState({ confirmText: t })}
                  onConfirm=${() => this.commit()}
                  onCancel=${() => this.setState({ phase: "form", preview: null })}
                  busy=${phase === "committing"} />`
            : null
        }
    </div>`;
  }
}
