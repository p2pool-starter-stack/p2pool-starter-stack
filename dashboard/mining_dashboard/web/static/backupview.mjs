// Backup card (#908): trigger an encrypted stack backup from the dashboard, then a genuine
// one-time "download this now" reveal for the passphrase the host generated.
//
// The host NEVER accepts a passphrase from this container — it mints one, runs it through the
// existing `pithead backup` machinery encrypted-only, and hands the result back exactly once
// through the normal /api/control/result poll. There is no way to fetch it again: the host
// overwrites the passphrase with null on its own bounded timer, and this component keeps no
// copy once the operator navigates away (a reload starts a fresh idle card). Save-it-now is not
// a UI suggestion, it is the only chance — match that in the copy, not just the code.

import { pollResult } from "./configview.mjs";
import { Component, html } from "./preact.mjs";
import { fmtEpoch } from "./securityview.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const BACKUP_POLL_MAX = 90; // 3 minutes — backup stops and restarts the whole stack, dashboard included

// POST the backup intent, then poll past the runner's interim "running" to a terminal result.
// Exported for node --test — this network flow is the logic; BackupPanel only maps its outcome
// onto UI state.
export async function runBackup() {
  const res = await fetch("/api/control/backup", { method: "POST", headers: CONTROL_HEADERS });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  const { id } = await res.json();
  const result = await pollResult(id, "running", BACKUP_POLL_MAX);
  return { id, ...result };
}

// The downloadable kit as plain text — the archive name, when it was made, what it holds, and
// the passphrase itself, so an operator has one file to store somewhere other than this host.
export function buildKitText(result) {
  const lines = [
    "Pithead backup emergency kit",
    "",
    `Archive:     ${result.archive || ""}`,
    `Created:     ${fmtEpoch(result.ts)}`,
    `Passphrase:  ${result.passphrase || ""}`,
    "",
    "Contents:",
    ...(result.contents || []).map((c) => `  - ${c}`),
    "",
    "This passphrase is shown once and cannot be recovered — without it the archive cannot be",
    "decrypted. Keep this file somewhere other than the box it backs up.",
  ];
  return lines.join("\n");
}

function kitFilename(archive) {
  return (archive || "pithead-backup").replace(/\.tar\.gz(\.enc)?$/, "") + "-kit.txt";
}

export class BackupPanel extends Component {
  constructor(props) {
    super(props);
    // idle | confirm | creating | kit | failed
    this.state = { phase: "idle", id: null, result: null };
  }

  async run() {
    this.setState({ phase: "creating" });
    try {
      const out = await runBackup();
      this.setState({
        id: out.id,
        result: out,
        phase: out.status === "applied" ? "kit" : "failed",
      });
    } catch (e) {
      this.setState({ phase: "failed", result: { error: String(e) } });
    }
  }

  renderConfirm() {
    return html`<div class="config-modal-backdrop">
        <div class="card config-modal">
            <h3>Create a backup</h3>
            <p>The host stops the stack, archives config.json, .env, the Tor onion-service keys
            and the dashboard database into an encrypted file, then starts the stack again.
            Mining pauses for the duration — usually under a minute. Blockchains are excluded;
            they re-sync.</p>
            <p>The passphrase is generated on the host and shown once, right after this. There is
            no way to see it again — download the kit or write it down when it appears.</p>
            <div class="config-modal-actions">
                <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle" })}>Cancel</button>
                <button class="btn-toggle active" onClick=${() => this.run()}>Create backup</button>
            </div>
        </div>
    </div>`;
  }

  renderCreating() {
    return html`<div class="config-modal-backdrop">
        <div class="card config-modal">
            <h3>Creating a backup…</h3>
            <p class="text-muted">The stack is stopping, archiving, and starting again. This page
            may briefly disconnect — leave it open; it shows the passphrase when the archive is
            ready.</p>
        </div>
    </div>`;
  }

  renderKit(id, result) {
    const kitText = buildKitText(result);
    const kitHref = "data:text/plain;charset=utf-8," + encodeURIComponent(kitText);
    return html`<div class="card">
        <h3>Backup created</h3>
        <p class="status-warn">Save this passphrase now — it is shown once and cannot be
        recovered. Without it, the archive is useless.</p>
        <p class="config-error-tail kit-passphrase font-mono">${result.passphrase}</p>
        <p class="text-muted text-xs">Archive: <span class="font-mono">${result.archive}</span>${" "}
        — created ${fmtEpoch(result.ts)}</p>
        <p class="text-muted text-xs">Contains: ${(result.contents || []).join(", ")}.</p>
        <div class="config-actions">
            <a class="btn-toggle active" href=${kitHref} download=${kitFilename(result.archive)}>Download kit (.txt)</a>
            <a class="btn-toggle" href=${"/api/control/backup-download?id=" + encodeURIComponent(id)}>Download archive</a>
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", id: null, result: null })}>I've saved it — close</button>
        </div>
    </div>`;
  }

  renderFailed(result) {
    return html`<div class="card">
        <h3>Backup</h3>
        <p class="status-bad">${(result && result.error) || "The host runner reported a failure."}</p>
        <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", result: null })}>Close</button>
    </div>`;
  }

  render() {
    if (!this.props.enabled) {
      // The appliance has no shell, so the host-CLI remedy below is advice its operator cannot
      // act on (#1854) — but "wait for the channel" was the WRONG replacement. `enabled` is
      // DASHBOARD_CONTROL_ENABLED, a config constant with no liveness in it, and an appliance
      // reaches this branch only in the "No login" case: apply_appliance_defaults turns the
      // channel on when the key is null AND the dashboard password is non-empty, so an empty
      // password leaves it off DELIBERATELY and permanently. Nothing returns. Name the login.
      if (this.props.appliance) {
        return html`<div class="card">
            <h3>Backup</h3>
            <p>Backup is off because this machine was set up without a dashboard login. The
            control channel it exports through sits behind that login, so it stays off until
            this machine has one — set a password under Set up again in the boot menu.</p>
        </div>`;
      }
      return html`<div class="card">
          <h3>Backup</h3>
          <p>Backup export is off with the rest of the control channel. To enable it, set
          <code>dashboard.control.enabled: true</code> in <code>config.json</code> on the host
          and run <code>./pithead apply</code>. It requires a dashboard login.</p>
      </div>`;
    }
    const { phase, id, result } = this.state;
    if (phase === "kit" && result) return this.renderKit(id, result);
    if (phase === "failed") return this.renderFailed(result);
    let modal = null;
    if (phase === "confirm") modal = this.renderConfirm();
    else if (phase === "creating") modal = this.renderCreating();
    return html`<div class="card">
        <h3>Backup</h3>
        <p>Export an encrypted archive of config.json, .env, the Tor onion-service keys, and the
        dashboard database — the state a dead box takes with it. Blockchains are excluded; they
        re-sync.</p>
        <p class="text-muted text-xs">Keep both halves: the archive, and the kit that carries the
        passphrase opening it. Neither is any use without the other, and setting a machine up
        later asks for this same pair.</p>
        <button class="btn-toggle active" disabled=${phase !== "idle"}
                onClick=${() => this.setState({ phase: "confirm" })}>Back up now</button>
    </div>${modal}`;
  }
}
