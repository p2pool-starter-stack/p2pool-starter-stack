// Click-to-adopt (#893): the form shown in Worker Inspect for a rig that isn't yet a write
// target. Prefilled with the worker's OBSERVED IP (proxy-reported — a #122 miner-advertised value,
// so it's a PREFILL only; the operator confirms or edits it before anything is sent), a default
// control port, and a token the operator must type. Submitting rides the SAME control-channel
// config path (GET /api/config -> POST preview -> POST commit) the Configuration view uses for any
// other edit — no new write endpoint. The host's own add-only gate (pithead's control_approval_gate)
// is what actually authorizes appending a brand-new workers.list[] descriptor; this only builds and
// sends the proposal.
//
// One caveat carried over from every other config.json-only write (dashboard.energy is the
// existing example): a commit that changes nothing in .env doesn't recreate any container, so the
// dashboard's own cached worker list picks up the new rig only once the dashboard itself restarts
// — the panel says so rather than claiming the rig is editable the instant the request returns.

import { pollResult } from "./configview.mjs";
import { Component, html } from "./preact.mjs";
import {
  buildAdoptedConfig,
  DEFAULT_CONTROL_PORT,
  validateAdoptFields,
} from "./workeradoptlogic.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };

export class AdoptRigForm extends Component {
  constructor(props) {
    super(props);
    this.state = {
      host: props.ip || "",
      controlPort: DEFAULT_CONTROL_PORT,
      token: "",
      busy: false,
      result: null,
    };
  }

  async adopt() {
    const { host, controlPort, token } = this.state;
    const validation = validateAdoptFields(host, controlPort, token);
    if (validation) {
      this.setState({ result: { status: "error", error: validation } });
      return;
    }
    this.setState({ busy: true, result: null });
    try {
      const cfgRes = await fetch("/api/config");
      if (!cfgRes.ok) throw new Error(`HTTP ${cfgRes.status}`);
      const proposed = buildAdoptedConfig(
        await cfgRes.json(),
        this.props.name,
        host,
        controlPort,
        token,
      );
      let res = await fetch("/api/control/preview", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ config: proposed }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let out = await res.json();
      if (out.status === "pending") out = { id: out.id, ...(await pollResult(out.id)) };
      if (out.status === "rejected") {
        this.setState({ busy: false, result: out });
        return;
      }
      if (out.destructive) {
        // An add-only descriptor never produces a DEST/CONFIRM row; a destructive verdict here
        // means the proposal carried more than the new descriptor — refuse rather than committing
        // something no one reviewed.
        this.setState({
          busy: false,
          result: { status: "error", error: "Unexpected change — nothing was applied." },
        });
        return;
      }
      res = await fetch("/api/control/commit", {
        method: "POST",
        headers: CONTROL_HEADERS,
        body: JSON.stringify({ id: out.id }),
      });
      if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
      let committed = await res.json();
      if (committed.status === "pending" || committed.status === "previewed") {
        committed = await pollResult(out.id, "previewed");
      }
      this.setState({ busy: false, result: committed });
      if (committed.status === "applied" && this.props.onAdopted) this.props.onAdopted();
    } catch (e) {
      this.setState({ busy: false, result: { status: "error", error: String(e) } });
    }
  }

  render() {
    const { host, controlPort, token, busy, result } = this.state;
    return html`
      <div class="adopt-rig">
        <p class="text-muted text-xs">
          Set up remote control for this rig: confirm its control address (prefilled from what the
          proxy observed — verify it before sending), then add its control token. This writes
          workers.list[] through the same control channel the Configuration view uses.
        </p>
        <label class="config-field">
          <span class="config-field-name">host</span>
          <input type="text" disabled=${busy} value=${host} placeholder="e.g. 192.168.1.10"
              onInput=${(e) => this.setState({ host: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">control_port</span>
          <input type="number" disabled=${busy} value=${controlPort}
              onInput=${(e) => this.setState({ controlPort: e.target.value })} />
        </label>
        <label class="config-field">
          <span class="config-field-name">token</span>
          <input type="password" disabled=${busy} value=${token} placeholder="the rig's control token"
              onInput=${(e) => this.setState({ token: e.target.value })} />
        </label>
        <div class="mt-1">
          <button class="btn-toggle" disabled=${busy} onClick=${() => this.adopt()}>${
            busy ? "Adopting…" : "Adopt this rig"
          }</button>
        </div>
        ${result ? html`<${AdoptStatus} result=${result} />` : null}
      </div>`;
  }
}

function AdoptStatus({ result }) {
  if (result.status === "applied") {
    return html`<p class="text-small mt-1 status-ok">
      Saved to config.json. The dashboard reads its worker list once at startup, so this editor may
      not appear until it restarts — the next config apply, upgrade, or a manual restart picks it up.
    </p>`;
  }
  return html`<p class="text-small mt-1 status-bad">${result.error || result.status}</p>`;
}
