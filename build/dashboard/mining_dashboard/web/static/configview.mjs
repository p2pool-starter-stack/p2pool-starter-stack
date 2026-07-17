// Configuration view (#33): edit config.json from the dashboard, through the host-side control
// channel. Flow: GET /api/config (secrets masked) → form → POST /api/control/preview (the host
// runner dry-runs the candidate and returns the same change rows `pithead apply` prints) →
// confirm modal (destructive changes need a typed APPLY) → POST /api/control/commit → result.
// The view only ever ASKS — every request rides the X-Pithead-Control header (CSRF guard) and
// the host decides. When the channel is off the routes 404 and this view explains how to enable.
//
// Two edit modes (#529, RATIFIED Wave-0 decision — mirrors #518's Worker Inspect shape exactly):
// **Form** (the default) pins a `core` group — the wizard's own shortlist, `_core_keys` on the
// fetched config, sourced from config.core-keys.json so the two never drift apart — above the
// config's natural sections, each a native <details> collapsed by default. **JSON** is the same
// fetched config as one editable textarea, with a Load-from-file fill button (FileReader, no
// upload). Both modes build the SAME `proposed` config object and POST it to the SAME
// /api/control/preview → confirm → /api/control/commit pipeline — the closed-schema gate on the
// host is the only validation authority; neither mode adds a server-side path the other lacks.

import {
  applyEdits,
  buildSections,
  jsonSyntaxError,
  parseConfigJson,
  regroupCore,
  SECRET_HINT,
} from "./configlogic.mjs";
import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 90; // 3 minutes — a commit recreates containers, which can take a while
const UPGRADE_POLL_MAX = 450; // 15 minutes — an upgrade pulls a whole release of images first

// Poll /api/control/result until a terminal result lands; shared by the Configuration view and
// the Upgrade button (#59). `skip` ignores an intermediate status under the same id (the
// still-present "previewed" result while a commit runs; "running" while an upgrade runs). Both
// flows recreate the dashboard container itself, so a fetch here can transiently fail (connection
// refused mid-restart) — ride it out and keep polling until the result file answers.
async function pollResult(id, skip, max = POLL_MAX) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
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

// `full` (#529): the pinned Core card mixes fields from several sections, so its rows need the
// FULL dotted key ("monero.wallet_address") to stay unambiguous; a natural section already says
// which section it is via its own heading, so its rows keep the shorter relative label.
const Field = ({ field, edits, onEdit, full }) => {
  const value = field.key in edits ? edits[field.key] : field.value;
  const label = full ? field.key : field.path.slice(1).join(".") || field.path[0];
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

export const PreviewModal = ({
  preview,
  confirmText,
  onConfirmText,
  onConfirm,
  onCancel,
  busy,
}) => {
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
      coreKeys: [],
      edits: {},
      mode: "form", // form | json (#529)
      editText: "",
      jsonError: null,
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
      this.setState({
        phase: "form",
        cfg,
        sections: buildSections(cfg),
        coreKeys: cfg._core_keys || [],
        edits: {},
        editText: JSON.stringify(cfg, null, 2),
        jsonError: null,
      });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // JSON mode (#529, mirrors WorkerInspect.onJsonInput): live parse-error feedback while typing,
  // not only on Save.
  onJsonInput(text) {
    this.setState({ editText: text, jsonError: jsonSyntaxError(text) });
  }

  // Fill the JSON textarea from a local file (#529, mirrors WorkerInspect.onFilePick, #518) — a
  // FileReader read, never an upload; the operator still reviews and clicks Save like any other
  // JSON-mode edit.
  onFilePick(e) {
    const file = e.target.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => this.onJsonInput(String(reader.result));
    reader.readAsText(file);
  }

  // Poll the result endpoint until a terminal result lands (shared pollResult above; kept as a
  // method because the view's flows and tests drive it through the instance).
  poll(id, skip) {
    return pollResult(id, skip);
  }

  // Build the SAME staged `proposed` config object regardless of mode (#529) — the form folds
  // edits back via applyEdits; JSON mode's textarea already IS the candidate config, so it only
  // needs parsing. Either result feeds the identical preview/commit pipeline below.
  buildProposed() {
    const { cfg, sections, edits, mode, editText } = this.state;
    if (mode === "json") return parseConfigJson(editText);
    return { config: applyEdits(cfg, sections, edits) };
  }

  async save() {
    const staged = this.buildProposed();
    if (staged.error) {
      this.setState({ error: staged.error });
      return;
    }
    this.setState({ phase: "previewing", error: null });
    try {
      const proposed = staged.config;
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

  // Form mode (#529): the core group (pinned, never collapsed) above the config's natural
  // sections, each a native <details> — collapsed by default (no `open` attribute), which gets
  // keyboard/a11y toggling for free, the same "native platform feature over JS state" call
  // Worker Inspect's own <dialog> made (#518).
  renderForm(core, groups, edits) {
    const onEdit = (k, v) => this.setState({ edits: { ...edits, [k]: v } });
    const field = (f, full) =>
      html`<${Field} field=${f} edits=${edits} full=${full} onEdit=${onEdit} />`;
    return html`<div class="grid">
        ${
          core.length
            ? html`<div class="card config-section config-section-core">
                <h3>Core</h3>
                ${core.map((f) => field(f, true))}
            </div>`
            : null
        }
        ${groups.map(
          (s) => html`<details class="card config-section">
              <summary>${s.name}</summary>
              ${s.fields.map((f) => field(f))}
          </details>`,
        )}
    </div>`;
  }

  // JSON mode (#529): the whole candidate config as one textarea, mirroring Worker Inspect's JSON
  // mode (#518) — inline parse-error feedback, and a Load-from-file fill button.
  renderJson(editText, jsonError, busy) {
    return html`<div class="card config-section">
        <textarea class="worker-edit" spellcheck="false" rows="20" disabled=${busy}
                  value=${editText} onInput=${(e) => this.onJsonInput(e.target.value)}></textarea>
        ${jsonError ? html`<p class="status-bad text-xs">${jsonError}</p>` : null}
        <div class="mt-1">
            <label class="text-muted text-xs">Load from file:
                <input type="file" accept="application/json,.json" disabled=${busy} onChange=${(e) => this.onFilePick(e)} />
            </label>
        </div>
    </div>`;
  }

  render() {
    const {
      phase,
      sections,
      coreKeys,
      edits,
      mode,
      editText,
      jsonError,
      preview,
      confirmText,
      result,
      error,
    } = this.state;
    if (phase === "loading")
      return html`<div class="card"><p class="text-muted">Loading configuration…</p></div>`;
    if (phase === "disabled") {
      return html`<div class="card">
          <h3>Configuration</h3>
          <p>Configuration editing is off (the default). To enable it, set <code>dashboard.control.enabled: true</code>
          in <code>config.json</code> on the host and
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
    const canSave = mode === "json" ? !jsonError : dirty;
    const { core, sections: groups } = regroupCore(sections, coreKeys);
    return html`<div class="config-view">
        ${error ? html`<div class="card"><p class="status-bad">${error}</p></div>` : null}
        <div class="toggle-group mb-1">
            <button class=${"btn-toggle" + (mode === "form" ? " active" : "")} onClick=${() => this.setState({ mode: "form" })}>Form</button>
            <button class=${"btn-toggle" + (mode === "json" ? " active" : "")} onClick=${() => this.setState({ mode: "json" })}>JSON</button>
        </div>
        ${mode === "form" ? this.renderForm(core, groups, edits) : this.renderJson(editText, jsonError, busy)}
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${!canSave || busy} onClick=${() => this.save()}>
                ${phase === "previewing" ? "Previewing…" : "Save & preview changes"}
            </button>
            ${mode === "form" && dirty ? html`<button class="btn-toggle" disabled=${busy} onClick=${() => this.setState({ edits: {}, error: null })}>Discard edits</button>` : null}
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

// --- One-click upgrade (#59) ---------------------------------------------------------

// POST the upgrade intent, then wait out the whole run. Exported for node --test — this network
// flow is the logic; UpgradeControl only maps its outcome onto UI state. The server answers 202
// straight away (the upgrade recreates the dashboard container itself), so the real outcome
// arrives via pollResult, skipping the intermediate "running" result and riding out the restart.
export async function runUpgrade(version) {
  const res = await fetch("/api/control/upgrade", {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify({ version }),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const out = await res.json();
  return pollResult(out.id, "running", UPGRADE_POLL_MAX);
}

// Header control for #59, rendered next to the new-release badge only when the server reports
// BOTH a newer release and an enabled control channel. The typed UPGRADE confirm is UX, not a
// security control — the host runner re-derives the target from the GitHub release API and
// refuses anything that isn't the latest published release.
export class UpgradeControl extends Component {
  constructor(props) {
    super(props);
    // idle | confirm | upgrading | done | failed
    this.state = { phase: "idle", confirmText: "", result: null };
  }

  async run() {
    this.setState({ phase: "upgrading" });
    try {
      const out = await runUpgrade(this.props.update.latest);
      this.setState({ phase: out.status === "upgraded" ? "done" : "failed", result: out });
    } catch (e) {
      this.setState({ phase: "failed", result: { error: String(e) } });
    }
  }

  render() {
    const { update, enabled } = this.props;
    if (!enabled || !update || !update.available) return null;
    const { phase, confirmText, result } = this.state;
    const version = update.latest;
    let modal = null;
    if (phase === "confirm") {
      modal = html`<div class="config-modal-backdrop">
          <div class="card config-modal">
              <h3>Upgrade to ${version}</h3>
              <p>The host pulls the ${version} release and recreates every container — including
              this dashboard, which goes away for a moment, and the miners' stratum connection,
              which reconnects. Your config, wallet, and chain data are kept.</p>
              <label class="config-confirm-type">Type <code>UPGRADE</code> to confirm:
                  <input type="text" value=${confirmText}
                      onInput=${(e) => this.setState({ confirmText: e.target.value })} /></label>
              <div class="config-modal-actions">
                  <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", confirmText: "" })}>Cancel</button>
                  <button class="btn-toggle active" disabled=${confirmText !== "UPGRADE"}
                      onClick=${() => this.run()}>Upgrade</button>
              </div>
          </div>
      </div>`;
    } else if (phase === "upgrading") {
      modal = html`<div class="config-modal-backdrop">
          <div class="card config-modal">
              <h3>Upgrading to ${version}…</h3>
              <p class="text-muted">The host is pulling images and recreating containers. This page
              will briefly disconnect while the dashboard restarts — leave it open; it reports the
              outcome when the new version is up.</p>
          </div>
      </div>`;
    } else if (phase === "done") {
      modal = html`<div class="config-modal-backdrop">
          <div class="card config-modal">
              <h3>Upgraded to ${result.version || version}</h3>
              <p class="status-ok">The stack is running the new release.</p>
              <div class="config-modal-actions">
                  <button class="btn-toggle active" onClick=${() => window.location.reload()}>Reload the dashboard</button>
              </div>
          </div>
      </div>`;
    } else if (phase === "failed") {
      modal = html`<div class="config-modal-backdrop">
          <div class="card config-modal">
              <h3>Upgrade did not complete</h3>
              <p class="status-bad">${result.error || "The host runner reported a failure."}</p>
              <div class="config-modal-actions">
                  <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", confirmText: "" })}>Close</button>
              </div>
          </div>
      </div>`;
    }
    return html`<button class="badge badge-accent version-badge upgrade-btn ml-2"
            title=${"Upgrade the stack to " + version + " from the dashboard"}
            onClick=${() => this.setState({ phase: "confirm", confirmText: "" })}>
            Upgrade to ${version}
        </button>${modal}`;
  }
}
