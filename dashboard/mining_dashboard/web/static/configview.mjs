// Configuration view (#33): edit config.json from the dashboard, through the host-side control
// channel. Flow: GET /api/config (secrets masked) → form → POST /api/control/preview (the host
// runner dry-runs the candidate and returns the same change rows `pithead apply` prints) →
// confirm modal (destructive changes need a typed APPLY) → POST /api/control/commit → result.
// The view only ever ASKS — every request rides the X-Pithead-Control header (CSRF guard) and
// the host decides. When the channel is off the routes 404 and this view explains how to enable.
//
// ONE editing surface, the wizard's pattern (#785): the form sections on top and the candidate
// config beneath as a collapsed JSON pane — both live, both views of a single `candidate`
// object. Editing a field rewrites the candidate (typed by the field, via configsync's shared
// coerceForType) and the pane re-renders; editing the pane replaces it and the fields refill.
// Hidden paths (#1850) sit outside the candidate: neither surface shows or alters them.
//
// The form pins a `core` group — the wizard's own shortlist, `_core_keys` on the fetched config,
// sourced from config.core-keys.json so the two never drift apart — above LOGICAL sections
// (#611, buildSections) an operator recognizes, each a native <details> collapsed by default;
// noisy clusters nest one deeper (#612, nestSection). A field the control gate won't commit —
// `_editable_keys` (#613, markEditable) — renders disabled with no listener wired, so the FORM
// can never change it; the pane can (it always could, as the old JSON mode), and the
// closed-schema gate on the host remains the only validation authority. Secrets arrive masked as
// sentinels, render blank with a keep-hint, and an untouched or re-blanked secret keeps its
// sentinel — "blank means keep" survives the model change.

import { applyFailure } from "./applyfailure.mjs";
import { editableCandidate, restoreHidden } from "./confighidden.mjs";
import {
  buildSections,
  isSecretSentinel,
  jsonSyntaxError,
  markEditable,
  nestSection,
  parseConfigJson,
  regroupCore,
  SECRET_HINT,
} from "./configlogic.mjs";
import { coerceForType, pathGet, pathSet } from "./configsync.mjs";
import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
const POLL_MAX = 90; // 3 minutes — a commit recreates containers, which can take a while
// #1071: 45 minutes. The old 900s ceiling sat BELOW what the host runner is allowed to spend before
// the image pull even starts — 60s on the release API, 900s on the bundle over Tor, 120s on the
// signature — so a healthy upgrade on a slow circuit hit the ceiling with the slowest step still
// ahead of it and was reported as a failure. No constant can be provably enough (the pull is
// unbounded), which is why the message below no longer claims the upgrade failed.
const UPGRADE_POLL_MAX = 1350;

// Poll /api/control/result until a terminal result lands; shared by the Configuration view, the
// Upgrade button (#59), and the Backup card (#908). `skip` ignores an intermediate status under
// the same id (the still-present "previewed" result while a commit runs; "running" while an
// upgrade or backup runs). Commit/upgrade/backup all briefly recreate or stop+restart the stack
// — commit/upgrade take the dashboard container itself down, backup takes the whole compose
// project down and back up — so a fetch here can transiently fail: a dropped connection (proxy
// down too, for backup) or a 502/503/504 (proxy up, upstream mid-restart, #622). Ride both out
// and keep polling until the result file answers.
export async function pollResult(id, skip, max = POLL_MAX) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202) continue;
    // Both flows recreate the dashboard container itself; while it restarts, the reverse proxy
    // (caddy) stays up and answers 502/503/504 — the upstream is briefly gone, not failed. Ride
    // these out like a dropped connection (#59/#622); the durable control result is the real
    // outcome and `max` is the backstop. A real backend 500 (upstream up, erroring) still throws.
    if (res.status === 502 || res.status === 503 || res.status === 504) continue;
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const out = await res.json();
    if (out.status === skip) continue;
    return out;
  }
  // Stopping the wait is not the same as the work failing: the runner is a host unit that carries on
  // regardless of this page, and it records its own outcome. Saying "failed" here sent operators to
  // check a control channel that was healthy, and invited a re-click that only met the 10-minute
  // throttle. Say what is actually known instead.
  throw new Error(
    "Stopped waiting — this can take longer than expected on a slow connection. The host keeps going and finishes on its own; reload in a few minutes to see the result. If the version is unchanged after that, check that dashboard.control is enabled and the pithead-control unit is running.",
  );
}

const HOST_ONLY_TITLE = "Host-only — edit config.json and run ./pithead apply";
// #719: an in-scope confirm-gated field IS editable, but committing it is disruptive — the review
// modal makes you type APPLY. The tooltip sets that expectation up front.
const CONFIRM_TITLE = "Editable — this change is disruptive; you'll type APPLY to confirm at Save";

// `full` (#529): the pinned Core card mixes fields from several sections, so its rows need the
// FULL dotted key ("monero.wallet_address") to stay unambiguous. A natural section keeps the
// shorter relative label ONLY while all its fields share one top-level key (its heading then says
// the rest); a logical section that mixes top-level keys (#611 — Wallets & payout spans monero.*
// AND tari.*) gets full keys too, or monero.view_key and tari.view_key would both render as a
// bare "view_key" (and System / advanced would show four identical "data_dir" rows).
//
// `field.editable` (#613): a field the control gate would refuse at commit renders disabled, its
// live value read-only, with a tooltip explaining why — and, critically, no onChange/onInput is
// wired at all when disabled, so a greyed field can never add itself to `edits` (defense in
// depth; the gate is still the real authority). Preact skips an event prop entirely when it's
// `undefined`, so passing `undefined` rather than a no-op is what actually removes the listener.
const Field = ({ field, value, onEdit, full }) => {
  const editable = field.editable !== false;
  const label = full ? field.key : field.path.slice(1).join(".") || field.path[0];
  const title = !editable ? HOST_ONLY_TITLE : field.confirm ? CONFIRM_TITLE : undefined;
  const change = editable ? (e) => onEdit(field, e.target.value) : undefined;
  let input;
  if (field.type === "boolean") {
    input = html`<select value=${String(value)} disabled=${!editable} onChange=${change}>
        <option value="true">true</option>
        <option value="false">false</option>
    </select>`;
  } else if (field.type === "select") {
    input = html`<select value=${value} disabled=${!editable} onChange=${change}>
        ${field.options.map((o) => html`<option value=${o}>${o}</option>`)}
    </select>`;
  } else if (field.type === "secret") {
    input = html`<input type="password" value=${value} placeholder=${SECRET_HINT}
        disabled=${!editable} onInput=${change} />`;
  } else {
    input = html`<input type=${field.type === "number" ? "number" : "text"} value=${value}
        disabled=${!editable} onInput=${change} />`;
  }
  return html`<label class="config-field" title=${title}>
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
                  ${changes.map((c) => {
                    // #719: CONFIRM rows (in-scope disruptive, confirm-gated) get the same warning
                    // treatment as DEST — both are "disruptive" and both arm the type-APPLY box.
                    const disruptive = c.flag === "DEST" || c.flag === "CONFIRM";
                    return html`<li class=${disruptive ? "config-preview-dest" : ""}>
                        ${disruptive ? "⚠ " : ""}${c.msg}</li>`;
                  })}
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
      editableKeys: [], // #613: config paths the control gate will actually commit
      confirmKeys: [], // #719: config paths the gate commits behind a type-to-confirm
      candidate: null, // the ONE config both the fields and the JSON pane edit (#785)
      pristine: "", // candidate's serialization at load — dirtiness is a comparison, not a flag
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
      const candidate = editableCandidate(cfg);
      const text = JSON.stringify(candidate, null, 2);
      this.setState({
        phase: "form",
        cfg,
        sections: buildSections(cfg),
        coreKeys: cfg._core_keys || [],
        editableKeys: cfg._editable_keys || [],
        confirmKeys: cfg._confirm_keys || [],
        candidate,
        pristine: text,
        editText: text,
        jsonError: null,
      });
    } catch (e) {
      this.setState({ phase: "error", error: String(e) });
    }
  }

  // Field -> candidate -> pane. The field's declared type drives coercion (shared
  // configsync.coerceForType), so a port stays a number and a toggle a boolean in the JSON.
  // A secret blanked out returns to what the server sent — the sentinel for a set secret —
  // because blank has always meant KEEP, and the model change must not quietly turn it into
  // "set to empty string".
  onFieldEdit(field, raw) {
    const { candidate, cfg } = this.state;
    const value =
      field.type === "secret" && raw === ""
        ? pathGet(cfg, field.key)
        : coerceForType(field.type, raw);
    pathSet(candidate, field.key, value);
    this.setState({ candidate, editText: JSON.stringify(candidate, null, 2), jsonError: null });
  }

  // Pane -> candidate -> fields. Hand-edited JSON wins; while it does not parse, the pane keeps
  // the broken text and the error, and the last good candidate stays what Save would send.
  onJsonInput(text) {
    const err = jsonSyntaxError(text);
    if (err) {
      this.setState({ editText: text, jsonError: err });
      return;
    }
    const staged = parseConfigJson(text);
    if (staged.error) {
      this.setState({ editText: text, jsonError: staged.error });
      return;
    }
    this.setState({ editText: text, jsonError: null, candidate: staged.config });
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

  // The candidate plus the hidden subtrees the fetched config carried (#1850) IS the proposed
  // config — the pane shows every key preview receives that this page may change, which is the
  // point of the pattern (#785). A pane mid-typo blocks Save via jsonError instead.
  buildProposed() {
    const { candidate, cfg, jsonError } = this.state;
    if (jsonError) return { error: jsonError };
    return { config: restoreHidden(candidate, cfg) };
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
      // #719: an in-scope disruptive change (preview.destructive) rides its typed confirmation to
      // the host gate, which requires it before a CONFIRM row proceeds. Friction, not a secret.
      const body = this.state.preview.destructive
        ? { id, confirm: this.state.confirmText }
        : { id };
      const res = await fetch("/api/control/commit", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify(body),
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

  // Form mode (#529): the core group (pinned, never collapsed) above the LOGICAL sections (#611),
  // each a native <details> — collapsed by default (no `open` attribute), which gets
  // keyboard/a11y toggling for free, the same "native platform feature over JS state" call
  // Worker Inspect's own <dialog> made (#518). Within a section, nestSection (#612) pulls a noisy
  // cluster (telegram.events, the notification sinks, healthchecks) into its own nested <details>,
  // one level deeper, also collapsed by default.
  renderForm(core, groups) {
    const { candidate } = this.state;
    const onEdit = (f, v) => this.onFieldEdit(f, v);
    // A set secret arrives as a sentinel and renders blank behind its keep-hint placeholder;
    // everything else shows the candidate's live value, so pane edits are visible immediately.
    const displayValue = (f) => {
      const v = pathGet(candidate, f.key);
      if (v === undefined || v === null || isSecretSentinel(v)) return f.value;
      return typeof v === "object" ? JSON.stringify(v) : String(v);
    };
    const field = (f, full) =>
      html`<${Field} field=${f} value=${displayValue(f)} full=${full} onEdit=${onEdit} />`;
    return html`<div class="grid">
        ${
          core.length
            ? html`<div class="card config-section config-section-core">
                <h3>Core</h3>
                ${core.map((f) => field(f, true))}
            </div>`
            : null
        }
        ${groups.map((s) => {
          const { fields, subgroups } = nestSection(s);
          // Computed on the flat fields AFTER nestSection, so a section that only mixes top-level
          // keys via its subgroups (Notifications: telegram + notifications + healthchecks, each
          // in its own labelled <details>) keeps short labels for the flat telegram.* remainder.
          const mixed = new Set(fields.map((f) => f.path[0])).size > 1;
          return html`<details class="card config-section">
              <summary>${s.name}</summary>
              ${fields.map((f) => field(f, mixed))}
              ${subgroups.map(
                (g) => html`<details class="config-subsection">
                    <summary>${g.label} (${g.fields.length})</summary>
                    ${g.fields.map((f) => field(f))}
                </details>`,
              )}
          </details>`;
        })}
    </div>`;
  }

  // The JSON pane (#785, the wizard's pattern): the whole candidate beneath the form, collapsed
  // by default, two-way live — never a separate mode. Load-from-file fills it (FileReader, no
  // upload); it shows byte-for-byte what Save previews, minus the hidden paths (#1850).
  renderJson(editText, jsonError, busy) {
    return html`<details class="card config-section">
        <summary><strong>Advanced</strong> — the configuration this page sends</summary>
        <p class="text-muted text-xs">Editing a field above updates it; editing here directly
        wins. Set secrets appear as <code>__secret__</code> markers and stay unchanged unless
        you replace them. Developer-only settings are not listed and are left exactly as they
        are. The host's gate remains the authority on what commits.</p>
        <textarea class="worker-edit" spellcheck="false" rows="20" disabled=${busy}
                  value=${editText} onInput=${(e) => this.onJsonInput(e.target.value)}></textarea>
        ${jsonError ? html`<p class="status-bad text-xs">${jsonError}</p>` : null}
        <div class="mt-1">
            <label class="text-muted text-xs">Load from file:
                <input type="file" accept="application/json,.json" disabled=${busy} onChange=${(e) => this.onFilePick(e)} />
            </label>
        </div>
    </details>`;
  }

  render() {
    const {
      phase,
      sections,
      coreKeys,
      editableKeys,
      confirmKeys,
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
              : applyFailure(result, this.props.appliance)
          }
          <button class="btn-toggle" onClick=${() => this.load()}>Back to the form</button>
      </div>`;
    }
    const busy = phase === "previewing" || phase === "committing";
    const dirty = editText !== this.state.pristine;
    const canSave = dirty && !jsonError;
    const { core, sections: groups } = regroupCore(
      markEditable(sections, editableKeys, confirmKeys),
      coreKeys,
    );
    return html`<div class="config-view">
        ${error ? html`<div class="card"><p class="status-bad">${error}</p></div>` : null}
        ${this.renderForm(core, groups)}
        ${this.renderJson(editText, jsonError, busy)}
        <div class="config-actions">
            <button class="btn-toggle active" disabled=${!canSave || busy} onClick=${() => this.save()}>
                ${phase === "previewing" ? "Previewing…" : "Save & preview changes"}
            </button>
            ${dirty ? html`<button class="btn-toggle" disabled=${busy} onClick=${() => this.load()}>Discard edits</button>` : null}
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
              ${
                result.rollback
                  ? html`<p class="text-muted">The previous release is kept at <code>${result.rollback}</code>
                    on the host — the rollback copy if this version misbehaves.</p>`
                  : null
              }
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
              ${
                result.backup
                  ? html`<p class="text-muted">Pre-upgrade copies of <code>config.json</code> and
                    <code>.env</code> are kept on the host: <code>${result.backup}</code>.</p>`
                  : null
              }
              <div class="config-modal-actions">
                  <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", confirmText: "" })}>Close</button>
              </div>
          </div>
      </div>`;
    }
    return html`<button class="badge badge-accent version-badge ml-2"
            title=${"Upgrade the stack to " + version + " from the dashboard"}
            onClick=${() => this.setState({ phase: "confirm", confirmText: "" })}>
            Upgrade to ${version}
        </button>${modal}`;
  }
}
