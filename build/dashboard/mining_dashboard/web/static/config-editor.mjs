// Configuration editor (Issue #33). The form is generated from GET /api/config (the host's
// config.json laid over config.reference.json, secrets masked to {__secret__: true}); Save
// stages a typed intent for the host-side runner, which validates with pithead's own parser
// and answers with the same change preview the CLI shows. Nothing here mutates the host —
// the dashboard can only ask (see SECURITY.md).

import { Component, Fragment, html } from "./preact.mjs";

// A masked secret leaf as served by /api/config: means "set — leave blank to keep".
export const isSecretSentinel = (v) => v != null && typeof v === "object" && v.__secret__ === true;

// Keys rendered as password inputs even when unset (plain "" leaves — no sentinel to go by).
const looksSecret = (key) => /password|token/.test(key);

// Fixed option lists for enum-like keys (kept in lockstep with pithead's validation).
const FIELD_OPTIONS = {
  "p2pool.pool": ["main", "mini", "nano"],
  "monero.mode": ["local", "remote"],
  "workers.api_auth": ["none", "name", "token"],
};

// Inline warnings surfaced next to fields whose change is disruptive; the pool text mirrors
// pithead's describe_change wording so the form and the CLI never disagree.
const FIELD_WARNINGS = {
  "p2pool.pool":
    "Changing the pool re-syncs the sidechain and your PPLNS window resets (XvB shares reset too).",
  "monero.wallet_address": "Future mining rewards go to the new address.",
  "tari.wallet_address": "Future merge-mining rewards go to the new address.",
  "monero.prune":
    "Enabling prunes existing blocks; disabling needs a full re-sync of the Monero data dir.",
};

// Flatten a (masked) config object into leaf rows: { path: ["monero","prune"], key, value }.
// Sections come from grouping rows by path[0] — the config.reference.json top-level keys.
export function fieldRows(obj, prefix = []) {
  const rows = [];
  for (const key of Object.keys(obj)) {
    if (key === "_docs") continue;
    const value = obj[key];
    const path = [...prefix, key];
    if (value != null && typeof value === "object" && !isSecretSentinel(value)) {
      rows.push(...fieldRows(value, path));
    } else {
      rows.push({ path, key: path.join("."), value });
    }
  }
  return rows;
}

// One leaf input. Type follows the CURRENT value: boolean -> checkbox, number -> number input,
// sentinel/secret-named -> password ("leave blank to keep"), enum -> select, else text.
export function Field({ row, edited, onEdit }) {
  const { key, value } = row;
  const current = edited !== undefined ? edited : value;
  const warning = FIELD_WARNINGS[key];
  const options = FIELD_OPTIONS[key];
  let input;
  if (options) {
    input = html`<select
      value=${current}
      onChange=${(e) => onEdit(row, e.target.value)}
    >
      ${options.map((o) => html`<option value=${o} selected=${o === current}>${o}</option>`)}
    </select>`;
  } else if (typeof value === "boolean") {
    input = html`<input
      type="checkbox"
      checked=${current === true}
      onChange=${(e) => onEdit(row, e.target.checked)}
    />`;
  } else if (typeof value === "number") {
    input = html`<input
      type="number"
      value=${current}
      onInput=${(e) => onEdit(row, e.target.value === "" ? value : Number(e.target.value))}
    />`;
  } else if (isSecretSentinel(value)) {
    // A set secret: the browser never sees it. Blank -> keep (the sentinel goes back and the
    // host re-inserts the real value); typing -> replace.
    input = html`<input
      type="password"
      placeholder="set — leave blank to keep"
      value=${isSecretSentinel(current) ? "" : current}
      onInput=${(e) => onEdit(row, e.target.value === "" ? value : e.target.value)}
    />`;
  } else {
    input = html`<input
      type=${looksSecret(row.path[row.path.length - 1]) ? "password" : "text"}
      value=${current}
      onInput=${(e) => onEdit(row, e.target.value)}
    />`;
  }
  return html`<div class="config-row">
    <label title=${key}>${key}</label>
    ${input}
    ${warning ? html`<p class="config-warning">${warning}</p>` : null}
  </div>`;
}

// The whole form, grouped into a card per top-level config section. Pure — testable with the
// string-render probe.
export function ConfigForm({ cfg, edits, onEdit }) {
  const rows = fieldRows(cfg);
  const sections = [...new Set(rows.map((r) => r.path[0]))];
  return html`<div class="grid config-form">
    ${sections.map(
      (section) => html`<div class="card config-section">
        <h4>${section}</h4>
        ${rows
          .filter((r) => r.path[0] === section)
          .map(
            (r) => html`<${Field} row=${r} edited=${edits[r.key]} onEdit=${onEdit} key=${r.key} />`,
          )}
      </div>`,
    )}
  </div>`;
}

// The runner's change preview: pithead's own describe_change lines, DEST rows styled as
// warnings — the exact preview a CLI apply would print.
export function PreviewModal({ result, busy, onConfirm, onCancel }) {
  const changes = result.changes || [];
  return html`<div class="modal-overlay">
    <div class="card modal">
      <h4>Review changes</h4>
      ${
        changes.length === 0
          ? html`<p>No configuration changes detected.</p>`
          : html`<ul class="change-list">
            ${changes.map(
              (c) => html`<li class=${c.flag === "DEST" ? "change-dest" : "change-info"}>
                ${c.flag === "DEST" ? "⚠ " : "• "}${c.msg}
              </li>`,
            )}
          </ul>`
      }
      <div class="modal-actions">
        <button class="btn-toggle" onClick=${onCancel} disabled=${busy}>Cancel</button>
        ${
          changes.length > 0
            ? html`<button
              class=${"btn-toggle btn-confirm" + (result.destructive ? " btn-danger" : "")}
              onClick=${onConfirm}
              disabled=${busy}
            >
              ${busy ? "Applying…" : result.destructive ? "Apply (disruptive)" : "Apply"}
            </button>`
            : null
        }
      </div>
    </div>
  </div>`;
}

const CONTROL_HEADERS = {
  "Content-Type": "application/json",
  // Custom header = CORS preflight cross-site (never granted) = CSRF guard; see server.py.
  "X-Pithead-Control": "1",
};

async function postControl(path, body) {
  const res = await fetch(path, {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify(body),
  });
  const data = await res.json();
  if (!res.ok && res.status !== 202) throw new Error(data.error || "HTTP " + res.status);
  return data;
}

// Poll a request's result. Commits can recreate the dashboard container itself, so fetch
// failures during the poll are expected — keep polling until the result file answers.
async function pollResult(id, { tries = 90, delayMs = 2000 } = {}) {
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch("/api/control/result?id=" + encodeURIComponent(id));
      if (res.ok) return await res.json();
    } catch {
      // dashboard restarting mid-apply — retry
    }
    await new Promise((r) => setTimeout(r, delayMs));
  }
  throw new Error("Timed out waiting for the runner's result.");
}

// Set a value at a nested path of a plain-object tree, cloning along the way.
function withPath(obj, path, value) {
  if (path.length === 0) return value;
  const [head, ...rest] = path;
  return { ...obj, [head]: withPath(obj[head] ?? {}, rest, value) };
}

export class ConfigEditor extends Component {
  constructor(props) {
    super(props);
    // phase: loading -> edit -> previewing -> preview(modal) -> committing -> done/error
    this.state = { phase: "loading", cfg: null, edits: {}, preview: null, error: null };
  }

  componentDidMount() {
    fetch("/api/config")
      .then((res) => {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then((cfg) => this.setState({ phase: "edit", cfg }))
      .catch((e) => this.setState({ phase: "error", error: String(e) }));
  }

  onEdit = (row, value) => {
    this.setState({ edits: { ...this.state.edits, [row.key]: value } });
  };

  proposed() {
    let cfg = this.state.cfg;
    const rows = fieldRows(cfg);
    for (const row of rows) {
      const edited = this.state.edits[row.key];
      if (edited !== undefined) cfg = withPath(cfg, row.path, edited);
    }
    return cfg;
  }

  requestPreview = async () => {
    this.setState({ phase: "previewing", error: null });
    try {
      let result = await postControl("/api/control/preview", this.proposed());
      if (result.status === "pending") result = await pollResult(result.id);
      if (result.status !== "previewed") {
        throw new Error(result.error || "The runner rejected the preview.");
      }
      this.setState({ phase: "preview", preview: result });
    } catch (e) {
      this.setState({ phase: "edit", error: String(e.message || e) });
    }
  };

  confirmCommit = async () => {
    this.setState({ phase: "committing" });
    try {
      let result = await postControl("/api/control/commit", {
        intent_id: this.state.preview.id,
      });
      if (result.status === "pending") result = await pollResult(result.id);
      if (result.status !== "applied") {
        throw new Error(result.error || "The apply failed on the host.");
      }
      this.setState({ phase: "done", preview: null, edits: {} });
    } catch (e) {
      this.setState({ phase: "edit", preview: null, error: String(e.message || e) });
    }
  };

  render() {
    const { phase, cfg, edits, preview, error } = this.state;
    const dirty = Object.keys(edits).length > 0;
    return html`<${Fragment}>
      <div class="view-controls config-controls">
        <div class="toggle-group">
          <button class="btn-toggle" onClick=${() => this.props.onBack()}>← Dashboard</button>
        </div>
        <div class="toggle-group">
          <button
            class="btn-toggle btn-confirm"
            disabled=${phase !== "edit" || !dirty}
            onClick=${this.requestPreview}
          >
            ${phase === "previewing" ? "Validating…" : "Review changes"}
          </button>
        </div>
      </div>
      ${error ? html`<div class="disconnected-banner">${error}</div>` : null}
      ${phase === "done" ? html`<div class="config-applied">Configuration applied.</div>` : null}
      ${phase === "loading" ? html`<div class="loading">Loading configuration…</div>` : null}
      ${
        phase === "error"
          ? html`<div class="disconnected-banner">Cannot load the configuration${error ? " — " + error : ""}.</div>`
          : null
      }
      ${cfg ? html`<${ConfigForm} cfg=${cfg} edits=${edits} onEdit=${this.onEdit} />` : null}
      ${
        phase === "preview" || phase === "committing"
          ? html`<${PreviewModal}
            result=${preview}
            busy=${phase === "committing"}
            onConfirm=${this.confirmCommit}
            onCancel=${() => this.setState({ phase: "edit", preview: null })}
          />`
          : null
      }
    <//>`;
  }
}
