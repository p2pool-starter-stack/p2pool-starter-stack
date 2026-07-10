// Configuration editor (#33) — the browser end of the host-mutation channel.
//
// It never touches the host itself: Save POSTs the edited config to /api/control/preview, the panel
// shows the host runner's change preview (destructive rows flagged), and only an explicit Confirm
// POSTs /api/control/commit, which runs `pithead apply` on the host. The panel just asks and polls.
//
// The vendored Preact carries no hooks, so this is a class Component holding its own state.

import { Component, html } from "./preact.mjs";

// Custom header the server requires on every control POST (the CSRF guard). Paired with the
// self-only CSP, it means a cross-site page can't drive this with the operator's session.
const HDRS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };

// config.json leaves the server masks as {__secret__:true}; the form shows them as "leave blank to
// keep" and only sends back a real string when the operator types a new one.
function isSecret(v) {
  return v && typeof v === "object" && v.__secret__ === true;
}

export class ControlPanel extends Component {
  constructor(props) {
    super(props);
    // phase: loading | edit | error | confirm | committing | done
    this.state = { phase: "loading", config: null, error: "", preview: null, result: null };
  }

  componentDidMount() {
    fetch("/api/config", { headers: { "X-Requested-With": "fetch" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error("HTTP " + r.status))))
      .then((config) => this.setState({ phase: "edit", config }))
      .catch((e) =>
        this.setState({ phase: "error", error: "Could not load config: " + e.message }),
      );
  }

  // Set config[...path] = value immutably, then re-render.
  setLeaf(path, value) {
    const next = structuredClone(this.state.config);
    let node = next;
    for (let i = 0; i < path.length - 1; i++) node = node[path[i]];
    node[path[path.length - 1]] = value;
    this.setState({ config: next });
  }

  async preview() {
    this.setState({ phase: "loading", error: "" });
    try {
      const res = await fetch("/api/control/preview", {
        method: "POST",
        headers: HDRS,
        body: JSON.stringify({ config: this.state.config }),
      });
      const body = await res.json();
      const final = await this.settle(body);
      if (final.status === "rejected") {
        this.setState({ phase: "error", error: final.error || "Rejected by the host." });
      } else {
        this.setState({ phase: "confirm", preview: final });
      }
    } catch (e) {
      this.setState({ phase: "error", error: "Preview failed: " + e.message });
    }
  }

  async commit() {
    this.setState({ phase: "committing", error: "" });
    try {
      const res = await fetch("/api/control/commit", {
        method: "POST",
        headers: HDRS,
        body: JSON.stringify({ intent_id: this.state.preview.id }),
      });
      const final = await this.settle(await res.json());
      this.setState({ phase: "done", result: final });
    } catch (e) {
      this.setState({ phase: "error", error: "Commit failed: " + e.message });
    }
  }

  // A 202 {status:"pending", id} means the host is still working — poll the result by id.
  async settle(body) {
    let cur = body;
    for (let i = 0; i < 120 && cur.status === "pending"; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      const r = await fetch("/api/control/result?id=" + encodeURIComponent(cur.id));
      cur = await r.json();
    }
    return cur;
  }

  renderField(path, value) {
    const key = path[path.length - 1];
    const id = path.join(".");
    if (isSecret(value)) {
      return html`<label class="cfg-row" key=${id}>
        <span class="cfg-key">${key}</span>
        <input type="password" placeholder="set — leave blank to keep" class="cfg-input"
               onInput=${(e) => this.setLeaf(path, e.target.value === "" ? { __secret__: true } : e.target.value)} />
      </label>`;
    }
    if (typeof value === "boolean") {
      return html`<label class="cfg-row" key=${id}>
        <span class="cfg-key">${key}</span>
        <input type="checkbox" checked=${value} onChange=${(e) => this.setLeaf(path, e.target.checked)} />
      </label>`;
    }
    if (typeof value === "number") {
      return html`<label class="cfg-row" key=${id}>
        <span class="cfg-key">${key}</span>
        <input type="number" value=${value} class="cfg-input"
               onInput=${(e) => this.setLeaf(path, e.target.value === "" ? 0 : Number(e.target.value))} />
      </label>`;
    }
    if (typeof value === "string") {
      return html`<label class="cfg-row" key=${id}>
        <span class="cfg-key">${key}</span>
        <input type="text" value=${value} class="cfg-input"
               onInput=${(e) => this.setLeaf(path, e.target.value)} />
      </label>`;
    }
    if (value && typeof value === "object") {
      return html`<fieldset class="cfg-group" key=${id}>
        <legend>${key}</legend>
        ${Object.keys(value).map((k) => this.renderField([...path, k], value[k]))}
      </fieldset>`;
    }
    return null; // arrays/null: not edited by the form (rare in config.json)
  }

  render() {
    const { phase, config, error, preview, result } = this.state;
    const close = html`<button class="btn-toggle" onClick=${this.props.onClose}>✕ Close</button>`;
    return html`<div class="cfg-panel">
      <div class="cfg-header">
        <h2>Configuration</h2>
        ${close}
      </div>
      ${error ? html`<div class="cfg-error">${error}</div>` : null}
      ${
        phase === "loading"
          ? html`<div class="loading">Working…</div>`
          : phase === "edit"
            ? html`<${Fragmentish}>
                <form onSubmit=${(e) => {
                  e.preventDefault();
                  this.preview();
                }}>
                  ${
                    config
                      ? Object.keys(config)
                          .filter((k) => !k.startsWith("_"))
                          .map((k) => this.renderField([k], config[k]))
                      : null
                  }
                  <div class="cfg-actions"><button type="submit" class="btn-toggle active">Save…</button></div>
                </form>
              <//>`
            : phase === "confirm"
              ? html`<div class="cfg-confirm">
                  <p>Review the changes the host will apply:</p>
                  ${(preview.changes || []).length === 0 ? html`<p class="text-muted">No changes.</p>` : null}
                  <ul class="cfg-changes">
                    ${(preview.changes || []).map((c) => html`<li class=${c.flag === "DEST" ? "cfg-dest" : ""}>${c.flag === "DEST" ? "⚠ " : ""}${c.msg}</li>`)}
                  </ul>
                  ${preview.destructive ? html`<p class="cfg-warn">⚠ Some changes are disruptive (they can reset your PPLNS window, redirect payouts, or re-sync a chain).</p>` : null}
                  <div class="cfg-actions">
                    <button class="btn-toggle" onClick=${() => this.setState({ phase: "edit" })}>Back</button>
                    <button class="btn-toggle active" disabled=${(preview.changes || []).length === 0} onClick=${() => this.commit()}>Confirm &amp; apply</button>
                  </div>
                </div>`
              : phase === "committing"
                ? html`<div class="loading">Applying on the host…</div>`
                : phase === "done"
                  ? html`<div class="cfg-done">
                      <p class=${result.status === "applied" ? "status-ok" : "status-bad"}>
                        ${result.status === "applied" ? "✓ Applied on the host." : "✗ Apply failed."}
                      </p>
                      ${result.output ? html`<pre class="cfg-output">${result.output}</pre>` : null}
                      ${result.status !== "applied" && result.backup ? html`<p class="text-muted">Previous config saved as ${result.backup}.</p>` : null}
                      <div class="cfg-actions"><button class="btn-toggle" onClick=${this.props.onClose}>Done</button></div>
                    </div>`
                  : null
      }
    </div>`;
  }
}

// Tiny fragment stand-in so we don't need to thread Fragment through here.
function Fragmentish(props) {
  return props.children;
}
