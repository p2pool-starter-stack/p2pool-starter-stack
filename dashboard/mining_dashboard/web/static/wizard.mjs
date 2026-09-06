// First-boot wizard app. Same stack as the dashboard: preact + htm from the one vendored
// binding, pure logic imported from shared modules, state fetched from the server, views as
// functions of that state. The server (mining_dashboard/wizard.py) stays the trust boundary:
// it validates, writes the spool, and the host consumes — this module only asks.
//
// Views: token gate → (installer? disk picker : setup form) → done/installing, polling /status.
// The setup form is the pattern #785 converges the dashboard's Configuration view on: the
// simple questions on top, the WHOLE effective config underneath, both live — editing a field
// rewrites the JSON, editing the JSON refills the fields, and the JSON is what gets submitted.

import { jsonSyntaxError } from "./configlogic.mjs";
import {
  classifyMoneroAddress,
  coerceForPath,
  pathGet,
  pathSet,
  telegramPairReady,
} from "./configsync.mjs";
import { Component, html, render } from "./preact.mjs";
import { rigCardFields, rigCardNote } from "./rigcardlogic.mjs";
import { savedRoleOrSetup } from "./savedrole.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

// The simple questions, each bound to its config path. Conditional blocks name the field that
// gates them; option lists carry the same guidance the docs give. This is deliberately a
// CURATED list — the JSON pane underneath is where everything else lives.
const FIELDS = {
  moneroWallet: { path: "monero.wallet_address" },
  tariWallet: { path: "tari.wallet_address" },
  moneroMode: { path: "monero.mode" },
  prune: { path: "monero.prune" },
  moneroRemoteHost: { path: "monero.remote.host" },
  moneroRemoteRpc: { path: "monero.remote.rpc_port" },
  moneroRemoteZmq: { path: "monero.remote.zmq_port" },
  moneroUser: { path: "monero.node_username" },
  moneroPass: { path: "monero.node_password" },
  tariMode: { path: "tari.mode" },
  tariRemoteHost: { path: "tari.remote.host" },
  tariRemoteGrpc: { path: "tari.remote.grpc_port" },
  pool: { path: "p2pool.pool" },
  localMiner: { path: "local_miner.enabled" },
  clearnetSync: { path: "monero.clearnet_initial_sync" },
  healthchecks: { path: "healthchecks.ping_url" },
  telegramToken: { path: "telegram.bot_token" },
  telegramChat: { path: "telegram.chat_id" },
  timezone: { path: "dashboard.timezone" },
  dashPassword: { path: "dashboard.auth.password" },
};

// Restore-at-setup (#909, #786 sub-issue B): mirrors the pithead script's and wizard.py's own
// cap — a Pithead backup holds only config, keys and the dashboard database, never the
// blockchains. Three languages, one number kept in step by hand (no shared source across them).
const RESTORE_MAX_BYTES = 64 * 1024 * 1024;

const TIMEZONES = [
  "auto",
  "UTC",
  "America/New_York",
  "America/Chicago",
  "America/Denver",
  "America/Los_Angeles",
  "America/Sao_Paulo",
  "Europe/London",
  "Europe/Berlin",
  "Europe/Warsaw",
  "Africa/Johannesburg",
  "Asia/Dubai",
  "Asia/Kolkata",
  "Asia/Singapore",
  "Asia/Tokyo",
  "Australia/Sydney",
];

export const Gate = ({ error, onSubmit }) => html`<div class="card">
    <p>Enter the one-time token shown on this machine's console or terminal.</p>
    <${Err}>${error}<//>
    <form onSubmit=${onSubmit}>
        <${Field} label="Token">
            <input name="token" autofocus autocomplete="off" autocapitalize="off"
                spellcheck=${false} placeholder="pit-XXXXXX" />
        <//>
        <${Note}>Case doesn't matter, and the ${" "}<code>pit-</code>${" "}prefix is optional.<//>
        <button type="submit" class="btn-toggle active">Continue</button>
    </form>
</div>`;

// Disk picker: the consequence sits right after the disk name (a <select> truncates on the
// right — bench screenshots cut off exactly the erase/keep words), and is restated in full
// below the control, red when destructive. The server re-validates the choice against the
// inventory the HOST published; a browser can never name a disk the host did not offer.
export const InstallSection = ({
  disks,
  chosen,
  confirm,
  wipe,
  allowStick,
  onPick,
  onConfirm,
  onWipe,
}) => {
  const picked = disks.find((d) => d.name === chosen);
  const verdictText = (d) =>
    d.state === "pithead-with-data"
      ? "holds a previous install"
      : d.state === "pithead"
        ? "ERASES it (Pithead layout, no data partition)"
        : "ERASES everything on it";
  return html`<div>
    <h3>Install onto</h3>
    <${Field} label="Target disk">
        <select value=${chosen} onChange=${onPick}>
            <option value="" disabled selected=${!chosen}>Choose a disk…</option>
            ${
              // A rig holds almost no state, so for that role the stick itself is a
              // first-class place to live — no erase, no commitment on machines whose
              // disks belong to something else.
              allowStick &&
              html`<option value="usb">Run from this USB stick — nothing is erased</option>`
            }
            ${disks.map(
              (d) =>
                html`<option value=${d.name}>
                    ${d.name} — ${verdictText(d)} — ${d.size} ${d.model} (SN ${d.serial})
                </option>`,
            )}
        </select>
    <//>
    ${
      chosen === "usb" &&
      html`<${Note}>The stick stays in the machine and is the system: the rig's settings ride
        on it, no disk is touched, and pulling it out just stops the miner.<//>`
    }
    ${
      picked &&
      picked.state === "pithead-with-data" &&
      html`<${Field} label="It holds a previous install — what happens to its data?">
        <select value=${wipe} onChange=${onWipe}>
            <option value="keep">Keep everything — settings, wallets and the synced chains (default)</option>
            <option value="data">Fresh start, keep the blockchains — settings and wallets are wiped</option>
            <option value="all">Wipe everything — the chains re-download from scratch</option>
        </select>
    <//>`
    }
    ${
      picked &&
      picked.state === "pithead-with-data" &&
      wipe === "all" &&
      html`<p class="c-bad">Everything on ${picked.name} is erased — including synced chains
        that took days to download.</p>`
    }
    ${
      picked &&
      picked.state !== "pithead-with-data" &&
      html`<p class="c-bad">Installing to ${picked.name} — this ${verdictText(picked)}.</p>`
    }
    ${
      picked &&
      html`<${Field} label="Type the disk name to confirm">
        <input value=${confirm} onInput=${onConfirm} autocomplete="off" autocapitalize="off"
            spellcheck=${false} placeholder=${chosen} />
    <//>`
    }
</div>`;
};

// Restore-at-setup (#909): the config form's alternative — an uploaded encrypted backup +
// its emergency-kit passphrase. Validation is host-side (the same "container asks, host
// decides" split as everything else here); this just carries the two answers up.
export const RestoreSection = ({ file, passphrase, onFile, onPassphrase }) => html`<div>
    <h3>Restore from a backup</h3>
    <${Note}>Upload the encrypted backup archive and its emergency-kit passphrase — shown once,
    when the backup was made. This restores settings, wallets, keys and the dashboard's history;
    the machine then provisions itself from what it restores, exactly as if you had filled in
    the form.<//>
    <${Field} label="Backup archive">
        <input type="file" accept=".enc,.tar.gz" onChange=${onFile} />
    <//>
    ${file && html`<p class="text-muted">${file.name} (${Math.round(file.size / 1024)} KB)</p>`}
    <${Field} label="Passphrase">
        <input type="password" value=${passphrase} onInput=${onPassphrase}
            autocomplete="off" placeholder="the emergency-kit passphrase" />
    <//>
</div>`;

export const Installing = ({ status }) => html`<div class="card">
    <p><strong>Installing.</strong> Takes a few minutes. Do not power it off.</p>
    ${
      status.startsWith("Installed")
        ? html`<h3>Installed</h3>
            <ol>
                <li>Wait for the machine to switch itself off.</li>
                <li>Remove the USB stick.</li>
                <li>Switch it back on.</li>
            </ol>
            <${Note}>Nothing more to configure: the machine provisions itself from the
            configuration you confirmed, then serves the dashboard behind the login you
            saved.<//>`
        : html`<p class="text-muted">${status || "Working…"}</p>`
    }
</div>`;

export const Done = ({ status, handoff, installer, stick, rig, onAck }) => html`<div class="card">
    ${
      handoff && handoff.role === "rig"
        ? html`<h3>Check this rig</h3>
            <p>This is what the machine will be.</p>
            ${rigCardFields(handoff).map((f) => html`<${Field} label=${f.label}><code class="wizard-mono">${f.value}</code><//>`)}
            <${Note}>${rigCardNote(handoff)}<//>
            <button type="button" class="btn-toggle active" onClick=${onAck}>
                ${installer && !stick ? "Looks right — erase the disk and install" : "Looks right — save it"}</button>`
        : handoff
          ? html`<h3>Save this before anything else</h3>
            <p>This is shown once, here.</p>
            <${Field} label="Dashboard user"><code class="wizard-mono">${handoff.username}</code><//>
            <${Field} label="Dashboard password"><code class="wizard-mono">${handoff.password}</code><//>
            <${Field} label="Dashboard address"><code class="wizard-mono">${handoff.dashboard}</code><//>
            <${Field} label="Point miners at"><code class="wizard-mono">${handoff.stratum}</code><//>
            <button type="button" class="btn-toggle active" onClick=${onAck}>
                ${installer ? "I saved these — erase the disk and install" : "I saved these — start provisioning"}</button>
            <${Note}>${
              installer
                ? html`Nothing is written to the disk until you press this. The machine installs,
                  switches itself off, and provisions with this exact configuration when you
                  power it back on — these credentials are the ones it will serve.`
                : html`Provisioning waits for this confirmation (up to 10 minutes), because the
                  page goes dark while the machine builds itself.`
            }<//>`
          : rig
            ? html`<p><strong>Saved.</strong> The miner is starting on this machine now. It has no
            dashboard of its own, so this page is the last one it shows — the rig appears in your
            Pithead's Workers view once it connects, and its console narrates until then.</p>
            <p class="text-muted">${status || ""}</p>`
            : html`<p><strong>Provisioning.</strong> The machine is pulling and starting the stack —
            10 to 30 minutes on a home connection. <strong>This page will stop responding</strong>
            while it happens; that is the machine working, not failing. Its console narrates, and
            when it finishes the dashboard is at
            ${" "}<code class="wizard-mono">${handoff ? handoff.dashboard : "https://pithead.local"}</code>${" "}
            behind the login you just saved.</p>
            <p class="text-muted">${status || "Waiting…"}</p>`
    }
</div>`;

export class WizardApp extends Component {
  state = {
    stage: "gate", // gate | setup | install | installing | done
    error: "",
    cfg: {},
    reference: {},
    disks: [],
    chosen: "",
    confirm: "",
    wipe: "keep",
    submitting: false,
    jsonText: "",
    jsonError: "",
    authMode: "auto", // auto | set | none — travels beside the config (see wizard.py submit)
    // What this machine IS, asked above the disk. ONLY "rig" is stored — it is the one answer
    // that carries no config; the two coordinators are read back out of one (see renderSetup).
    role: "",
    rigPool: "",
    rigWorker: "",
    rigPassword: "",
    rigDefaults: {},
    // The data-wipe note (#1121): set when /data was reinitialized before this boot. Only
    // `recovery: true` ever renders — a deliberate factory-reset is not a surprise to the
    // operator who asked for it.
    dataWiped: {},
    // Restore-at-setup (#909): an alternative to the whole form above, toggled independently
    // of role/install-target — an uploaded backup replaces the config the operator would
    // otherwise type in.
    restoreMode: false,
    restoreFile: null,
    restorePassphrase: "",
    status: "",
    handoff: null,
  };

  // The SERVER decides which step this machine is on (wizard_stage, from the spool). The client
  // never infers it: a refresh mid-provision used to walk back into an editable form, and a
  // client-side stage flag raced its own setState so the credentials card could never appear.
  async loadState() {
    const res = await fetch("/api/wizard-state");
    if (!res.ok) return false;
    const s = await res.json();
    const next = {
      // The installation medium gets the SAME setup form with an install section folded in —
      // one page, one submission (config + disk + wipe), one credentials card, then the erase.
      stage:
        { installer: "setup", installing: "installing", handoff: "done", done: "done" }[s.stage] ||
        "setup",
      installer: s.stage === "installer",
      reference: s.reference,
      disks: s.disks,
      error: s.error || "",
      rigDefaults: s.rig_defaults || {},
      dataWiped: s.data_wiped || {},
      handoff: s.handoff || null,
      savedRole: s.saved_role || null,
    };
    // The host's discovery pre-fills the rig fields, but only while they are untouched — the
    // form polls, and a half-typed pool address must survive it (same rule as cfg below).
    if (!this.state.rigPool && !this.state.rigWorker) {
      next.rigPool = (s.rig_defaults || {}).pool || "";
      next.rigWorker = (s.rig_defaults || {}).worker || "";
    }
    // The wait is over once the server either moved on or rejected: both end "Validating…".
    if (this.state.submitting && (next.stage !== "setup" || next.error)) next.submitting = false;
    // Do not clobber in-progress editing with the server's copy once the form is up.
    if (this.state.stage !== "setup" || !this.state.cfg || !Object.keys(this.state.cfg).length) {
      next.cfg = s.config;
      next.jsonText = JSON.stringify(s.config, null, 2);
    }
    this.setState(next);
    return true;
  }

  async componentDidMount() {
    await this.loadState(); // an existing session cookie skips the gate
  }

  // One loop after submit: refresh the SERVER's stage (which carries the handoff when it is
  // published) and the human-readable status line. No client-side stage guessing.
  poll() {
    const tick = async () => {
      try {
        this.setState({ status: await (await fetch("/status")).text() });
        await this.loadState();
      } catch {
        /* the machine reboots or powers off under this poll by design */
      }
      setTimeout(tick, 2000);
    };
    tick();
  }

  // A dropped connection reads identically to the lockout to the operator: the machine
  // exits right after refusing the last attempt, so a network failure gets the same
  // actionable message as the 429 it raced.
  static LOCKOUT_MESSAGE =
    "Too many attempts — the machine printed a fresh token on its console; enter that one.";

  auth = async (e) => {
    e.preventDefault();
    try {
      const res = await fetch("/auth", {
        method: "POST",
        body: new URLSearchParams(new FormData(e.target)),
      });
      if (res.ok && (await this.loadState())) return;
      if (res.status === 429) {
        this.setState({ error: WizardApp.LOCKOUT_MESSAGE });
        return;
      }
      this.setState({ error: "Wrong token." });
    } catch {
      this.setState({ error: WizardApp.LOCKOUT_MESSAGE });
    }
  };

  // Field edit → config → JSON pane. The JSON is the single source of what gets submitted.
  edit = (path) => (e) => {
    const raw = e.target.type === "checkbox" ? String(e.target.checked) : e.target.value;
    const cfg = this.state.cfg;
    pathSet(cfg, path, coerceForPath(this.state.reference, path, raw));
    this.setState({ cfg, jsonText: JSON.stringify(cfg, null, 2) });
  };

  // The role reshapes the page the way the disk choice does. "Both" IS the existing
  // local_miner switch: picking it turns that switch on, plain Pithead turns it off, and the
  // switch below stays live either way. Neither is stored; a rig never touches the config.
  setRole = (e) => {
    const role = e.target.value;
    const cfg = this.state.cfg;
    const next = { role: role === "rig" ? "rig" : "", cfg };
    if (role !== "rig") {
      pathSet(cfg, "local_miner.enabled", role === "both");
      // "usb" only exists for rigs — a coordinator switching back must re-pick a real disk.
      if (this.state.chosen === "usb") {
        next.chosen = "";
        next.confirm = "";
      }
    }
    next.jsonText = JSON.stringify(cfg, null, 2);
    this.setState(next);
  };

  // JSON pane edit → config → fields. Hand-edited JSON wins; shape errors show as typed.
  editJson = (e) => {
    const text = e.target.value;
    const err = jsonSyntaxError(text);
    if (err) {
      this.setState({ jsonText: text, jsonError: err });
      return;
    }
    this.setState({ jsonText: text, jsonError: "", cfg: JSON.parse(text) });
  };

  submit = async (e) => {
    e.preventDefault();
    const rig = this.state.role === "rig";
    const keepEverything =
      this.state.installer &&
      (this.state.disks.find((d) => d.name === this.state.chosen) || {}).state ===
        "pithead-with-data" &&
      this.state.wipe === "keep";
    // keep means KEEP in every role: no config, no role — the survivor wins.
    const body = keepEverything
      ? {} // the preserved config wins — sending one would only mislead
      : rig
        ? {
            role: "rig",
            rig_pool: this.state.rigPool.trim(),
            rig_worker: this.state.rigWorker.trim(),
            rig_password: this.state.rigPassword,
          }
        : {
            config: JSON.stringify(this.state.cfg),
            auth_mode: this.state.authMode,
          };
    if (rig && !keepEverything && !body.rig_pool) {
      this.setState({ error: "Enter the pool address (host:port)." });
      return;
    }
    // One page, one submission: on the installation medium the disk choice rides beside the
    // config, and the server gates both before anything is written. "usb" (rig role only) is
    // not a disk: nothing is erased, so the retyped-name gate does not apply.
    if (this.state.installer) {
      if (!this.state.chosen) {
        this.setState({
          error: rig
            ? "Choose a disk — or run from this USB stick."
            : "Choose the disk to install onto.",
        });
        return;
      }
      if (this.state.chosen === "usb") {
        body.disk = "usb";
      } else {
        if (this.state.confirm !== this.state.chosen) {
          this.setState({ error: `Type ${this.state.chosen} exactly to confirm the erase.` });
          return;
        }
        body.disk = this.state.chosen;
        body.confirm = this.state.confirm;
        body.wipe = this.state.wipe;
      }
    }
    const res = await fetch("/submit", { method: "POST", body: new URLSearchParams(body) });
    if (!res.ok) {
      let msg = "Submit failed — check the configuration and retry.";
      try {
        msg = (await res.json()).error || msg;
      } catch {}
      this.setState({ error: msg });
      return;
    }
    // No optimistic view swap: flipping the stage locally re-rendered a different page and
    // threw the scroll to the top while nothing had happened yet. The button reads
    // "Validating…" in place, and the page changes when the SERVER's stage does.
    this.setState({ submitting: true, error: "" });
    this.poll();
  };

  // The restore-at-setup alternative (#909): an uploaded archive + passphrase instead of the
  // typed config. Multipart, not URLSearchParams — the archive is a file, not a form field.
  // Validation is entirely host-side; the client only enforces the size cap it can check
  // without a round trip.
  submitRestore = async (e) => {
    e.preventDefault();
    if (!this.state.restoreFile) {
      this.setState({ error: "Choose a backup archive to upload." });
      return;
    }
    if (this.state.restoreFile.size > RESTORE_MAX_BYTES) {
      this.setState({
        error: `Archive is too large (max ${RESTORE_MAX_BYTES / (1024 * 1024)} MB) — a Pithead backup holds only config, keys and the dashboard database, never the blockchains.`,
      });
      return;
    }
    const body = new FormData();
    body.append("archive", this.state.restoreFile);
    body.append("passphrase", this.state.restorePassphrase);
    if (this.state.installer) {
      if (!this.state.chosen) {
        this.setState({ error: "Choose the disk to install onto." });
        return;
      }
      if (this.state.confirm !== this.state.chosen) {
        this.setState({ error: `Type ${this.state.chosen} exactly to confirm the erase.` });
        return;
      }
      body.append("disk", this.state.chosen);
      body.append("confirm", this.state.confirm);
      body.append("wipe", this.state.wipe);
    }
    const res = await fetch("/submit-restore", { method: "POST", body });
    if (!res.ok) {
      let msg = "Restore failed — check the archive and passphrase, and retry.";
      try {
        msg = (await res.json()).error || msg;
      } catch {}
      this.setState({ error: msg });
      return;
    }
    // Same in-place wait as a typed submission: no optimistic page swap, the server's stage
    // moves the page when it actually does.
    this.setState({ submitting: true, error: "" });
    this.poll();
  };

  ack = async () => {
    await fetch("/handoff-ack", { method: "POST" });
    await this.loadState(); // the server drops out of the handoff stage; the view follows
  };

  // The rig role's whole form: where the pool is, what to call the machine, an optional
  // stratum password. No payout addresses (the Pithead holds those), no nodes, no dashboard
  // login — a rig has none of them.
  renderRigFields() {
    const { rigPool, rigWorker, rigPassword, rigDefaults } = this.state;
    return html`<h3>Where it mines</h3>
        <${Field} label="Pool address (host:port)">
            <input class="wizard-mono" value=${rigPool}
                onInput=${(e) => this.setState({ rigPool: e.target.value })}
                autocomplete="off" autocapitalize="off" spellcheck=${false}
                placeholder="pithead.local:3333" required />
        <//>
        <${Note}>${
          rigDefaults.pool
            ? html`A Pithead answered at ${" "}<code>${rigDefaults.pool}</code>${" "}on this
              network — already filled in.`
            : html`No Pithead answered on this network — enter the coordinator's address by
              hand. Its own setup card names it, as ${" "}
              <code>stratum+tcp://…</code>${" "}under "Point miners at".`
        }<//>
        <${Field} label="Worker name">
            <input value=${rigWorker} onInput=${(e) => this.setState({ rigWorker: e.target.value })}
                autocomplete="off" autocapitalize="off" spellcheck=${false} />
        <//>
        <${Field} label="Stratum password (leave blank unless the Pithead set one)">
            <input type="password" value=${rigPassword}
                onInput=${(e) => this.setState({ rigPassword: e.target.value })}
                autocomplete="new-password" />
        <//>
        <${Note}>That is everything a rig needs. It has no dashboard and no login of its own —
        it appears by this name in the Pithead's Workers view.<//>`;
  }

  // Restore-at-setup (#909): its own small card, reached by the toggle at the top of the
  // normal form and left by the "back" link here — independent of role/disk state, which
  // this branch handles on its own (the install target still needs picking on the medium).
  renderRestore() {
    const { error, installer, disks, chosen, confirm, wipe, restorePassphrase, submitting } =
      this.state;
    const diskPicked = !installer || Boolean(chosen);
    return html`<div class="card">
        <p>Upload an encrypted Pithead backup instead of filling in the form below. The machine
        decrypts, validates and provisions itself from what it restores.</p>
        <${Err}>${error}<//>
        <form onSubmit=${this.submitRestore}>
            ${
              installer &&
              html`<${InstallSection} disks=${disks} chosen=${chosen} confirm=${confirm}
                wipe=${wipe} allowStick=${false}
                onPick=${(e) => this.setState({ chosen: e.target.value, wipe: "keep" })}
                onConfirm=${(e) => this.setState({ confirm: e.target.value })}
                onWipe=${(e) => this.setState({ wipe: e.target.value })} />`
            }
            ${
              diskPicked &&
              html`<${RestoreSection} file=${this.state.restoreFile} passphrase=${restorePassphrase}
                onFile=${(e) => this.setState({ restoreFile: e.target.files[0] || null })}
                onPassphrase=${(e) => this.setState({ restorePassphrase: e.target.value })} />
            <button type="submit" class="btn-toggle active" disabled=${submitting}>
                ${submitting ? "Validating…" : "Restore and provision"}</button>`
            }
        </form>
        <button type="button" class="wizard-link"
            onClick=${() => this.setState({ restoreMode: false, error: "" })}>
            Back to the setup form</button>
    </div>`;
  }

  renderSetup() {
    if (this.state.restoreMode) return this.renderRestore();
    const { cfg, error, jsonText, jsonError } = this.state;
    const v = (name) => pathGet(cfg, FIELDS[name].path);
    const on = (name) => this.edit(FIELDS[name].path);
    const addr = classifyMoneroAddress(v("moneroWallet"));
    const tg = telegramPairReady(v("telegramToken"), v("telegramChat"));
    const remoteMonero = v("moneroMode") === "remote";
    const remoteTari = v("tariMode") === "remote";
    const { installer, disks, chosen, confirm, wipe, dataWiped } = this.state;
    // The select is stored for a rig and read out of the config for the two coordinators.
    const role = this.state.role || (v("localMiner") ? "both" : "pithead");
    const rig = role === "rig";
    // Keep-everything reinstall: the machine's settings, wallets, login and chains all survive,
    // so there is nothing to ask — the config half of the page would collect answers the
    // machine will ignore (its preserved config wins). Only the disk half renders.
    const pickedState = (disks.find((d) => d.name === chosen) || {}).state;
    // Progressive disclosure: the DISK decides what gets asked (keep = nothing, keep-chains =
    // a trimmed form, fresh = everything), so until one is chosen the page asks only that.
    // The rig role's "usb" target counts as picked: running from the stick is a full answer.
    const diskPicked = !installer || Boolean(pickedState) || chosen === "usb";
    const keepEverything = installer && pickedState === "pithead-with-data" && wipe === "keep";
    return html`<div class="card">
        <p>${
          installer && !diskPicked
            ? rig
              ? html`Choose where this rig runs — one of the disks, or straight from this USB
                stick. The rest of the page appears once you pick.`
              : html`Choose the disk to install onto — what happens next depends on what is
              already on it, so the rest of the page appears once you pick.`
            : keepEverything
              ? html`This disk keeps everything — settings, wallets, dashboard login and the
              synced chains. Only the system is replaced, so there is nothing to configure:
              the machine comes back exactly as it was, on a fresh install.`
              : rig
                ? html`A rig needs almost nothing: where the pool is, and what to call this
                machine. It mines toward a Pithead and appears in that machine's dashboard.`
                : installer
                  ? html`Choose the disk to install onto and answer the questions below — the
                machine validates everything, shows you the login to save, and only then erases
                the disk. After it switches itself off, remove the stick and power it on: it
                provisions itself with exactly this configuration.`
                  : html`Only the answers that cannot be guessed for you. Everything else keeps
                its documented default and stays editable from the dashboard.`
        }</p>
        ${
          dataWiped.recovery &&
          html`<p class="c-bad">This machine's data area could not be read and was reinitialized
          on ${dataWiped.when} — the wallets, node identity and synced chains that were on it are
          gone. If you have a backup, restore it below instead of setting up as a fresh machine.</p>`
        }
        <p><button type="button" class="wizard-link"
            onClick=${() => this.setState({ restoreMode: true, error: "" })}>
            Restoring an existing Pithead? Upload its backup instead.</button></p>
        <${Err}>${error}<//>
        <form onSubmit=${this.submit}>
            <${Field} label="What is this machine?">
                <select value=${role} onChange=${this.setRole}>
                    <option value="pithead">Pithead</option>
                    <option value="both">Pithead + RigForge</option>
                    <option value="rig">RigForge</option>
                </select>
            <//>
            <${Note}>A Pithead coordinates the mine — nodes, pool and dashboard. A RigForge rig
            only mines, pointed at a Pithead. The middle choice is a Pithead that also mines
            with its own CPU.<//>
            ${
              installer &&
              html`<${InstallSection} disks=${disks} chosen=${chosen} confirm=${confirm}
                wipe=${wipe} allowStick=${rig}
                onPick=${(e) => this.setState({ chosen: e.target.value, wipe: "keep" })}
                onConfirm=${(e) => this.setState({ confirm: e.target.value })}
                onWipe=${(e) => this.setState({ wipe: e.target.value })} />`
            }
            ${diskPicked && !keepEverything && rig && this.renderRigFields()}
            ${
              diskPicked &&
              !keepEverything &&
              !rig &&
              html`<h3>Payout addresses</h3>
            <${Note}>Paste these — they are far too long to type, and a typo pays a stranger.<//>
            <${Field} label="Monero payout address">
                <input class="wizard-mono" value=${v("moneroWallet") || ""} onInput=${on("moneroWallet")}
                    autocomplete="off" autocapitalize="off" spellcheck=${false}
                    placeholder="4… (95 characters)" required />
            <//>
            <p class=${addr.kind === "ok" || addr.kind === "empty" || addr.kind === "partial" ? "text-muted" : "c-bad"}>
                ${addr.message}
            </p>
            <${Field} label="Tari payout address">
                <input class="wizard-mono" value=${v("tariWallet") || ""} onInput=${on("tariWallet")}
                    autocomplete="off" autocapitalize="off" spellcheck=${false} required />
            <//>
            <${Note}>Merge-mining earns Tari from the same work that mines Monero — this stack
            always does both, so it needs both addresses.<//>

            <h3>Monero node</h3>
            <${Field} label="Where does Monero data come from?">
                <select value=${remoteMonero ? "remote" : "local"} onChange=${on("moneroMode")}>
                    <option value="local">Run the bundled node on this machine (default)</option>
                    <option value="remote">Use a Monero node I already run</option>
                </select>
            <//>
            ${
              remoteMonero
                ? html`<div class="wizard-when">
                    <${Field} label="Node host">
                        <input value=${v("moneroRemoteHost") || ""} onInput=${on("moneroRemoteHost")}
                            placeholder="192.168.1.10 or my-node.local" autocomplete="off" spellcheck=${false} />
                    <//>
                    <${Field} label="RPC port">
                        <input value=${v("moneroRemoteRpc") ?? 18081} onInput=${on("moneroRemoteRpc")}
                            inputmode="numeric" pattern="[0-9]+" />
                    <//>
                    <${Field} label="ZMQ port">
                        <input value=${v("moneroRemoteZmq") ?? 18083} onInput=${on("moneroRemoteZmq")}
                            inputmode="numeric" pattern="[0-9]+" />
                    <//>
                    <${Field} label="Node username (blank if none)">
                        <input value=${v("moneroUser") || ""} onInput=${on("moneroUser")} autocomplete="off" />
                    <//>
                    <${Field} label="Node password">
                        <input type="password" value=${v("moneroPass") || ""} onInput=${on("moneroPass")}
                            autocomplete="new-password" />
                    <//>
                </div>`
                : null
            }

            <h3>Tari node</h3>
            <${Field} label="Where does Tari data come from?">
                <select value=${remoteTari ? "remote" : "local"} onChange=${on("tariMode")}>
                    <option value="local">Run the bundled node on this machine (default)</option>
                    <option value="remote">Use a Tari node I already run</option>
                </select>
            <//>
            ${
              remoteTari &&
              html`<div class="wizard-when">
                <${Field} label="Node host">
                    <input value=${v("tariRemoteHost") || ""} onInput=${on("tariRemoteHost")}
                        placeholder="192.168.1.10 or my-node.local" autocomplete="off" spellcheck=${false} />
                <//>
                <${Field} label="gRPC port">
                    <input value=${v("tariRemoteGrpc") ?? 18142} onInput=${on("tariRemoteGrpc")}
                        inputmode="numeric" pattern="[0-9]+" />
                <//>
                <${Note}>An IP or a hostname both work. Only over a network you trust — this
                connection is not encrypted.<//>
            </div>`
            }

            
            <h3>Mining</h3>
            <${Field} label="P2Pool sidechain">
                <select value=${v("pool") || "mini"} onChange=${on("pool")}>
                    <option value="mini">mini — right for almost every home rig (default)</option>
                    <option value="nano">nano — a single low-power rig</option>
                    <option value="main">main — only for very large hashrate</option>
                </select>
            <//>
            <${Note}>The sidechains are sized by hashrate so miners find shares at a similar
            cadence. Too large a tier means waiting days between shares; it costs nothing to
            change later.<//>
            <${Field} label="Mine on this machine too?">
                <select value=${String(v("localMiner") ?? false)} onChange=${on("localMiner")}>
                    <option value="false">No — this box only coordinates the miners</option>
                    <option value="true">Yes — this machine also mines with its own CPU (built-in RigForge, default)</option>
                </select>
            <//>
            ${
              v("localMiner") === true &&
              html`<${Note}>Nothing to install: the machine carries its own RigForge miner,
                pointed at its own pool. It starts by itself once the stack is up and appears
                in the dashboard's Workers view. Mining tunes the whole box for hashrate —
                CPU governor, memory reservations — which is exactly what a dedicated
                appliance is for.<//>`
            }

            <h3>First sync</h3>
            <${Field} label="Downloading the chain the first time">
                <select value=${String(v("clearnetSync") ?? false)} onChange=${on("clearnetSync")}>
                    <option value="false">Private, over Tor — takes days</option>
                    <option value="true">Faster, over the open internet, then Tor afterwards — takes hours</option>
                </select>
            <//>

            
            <h3>Dashboard login</h3>
            <${Field} label="How should the dashboard be protected?">
                <select value=${this.state.authMode} onChange=${(e) => this.setState({ authMode: e.target.value })}>
                    <option value="auto">Generate a strong password for me (recommended)</option>
                    <option value="set">Let me choose the password</option>
                    <option value="none">No login at all</option>
                </select>
            <//>
            ${
              this.state.authMode === "set"
                ? html`<div class="wizard-when">
                    <${Field} label="Password (8+ characters)">
                        <input type="password" value=${v("dashPassword") || ""}
                            onInput=${on("dashPassword")} autocomplete="new-password" minlength="8" />
                    <//>
                <//>`
                : this.state.authMode === "none"
                  ? html`<p class="c-bad">Anyone on this network will be able to open the
                    dashboard — it shows your payout addresses and hashrate. Only choose this on a
                    network you fully control, and never with the Tor onion enabled.</p>`
                  : html`<${Note}>A 32-character password is generated on the machine and shown
                    to you on the next screen.<//>`
            }

            <h3>Alerts <span class="text-muted">(optional — skip if you are not sure)</span></h3>
            <${Field} label="Telegram bot token">
                <input value=${v("telegramToken") || ""} onInput=${on("telegramToken")}
                    autocomplete="off" spellcheck=${false} placeholder="123456:ABC-DEF…" />
            <//>
            <${Field} label="Telegram chat ID">
                <input value=${v("telegramChat") || ""} onInput=${on("telegramChat")}
                    autocomplete="off" spellcheck=${false} placeholder="987654321" />
            <//>
            ${tg.partial && html`<p class="c-bad">Telegram needs both fields, or leave both blank.</p>`}

            <details>
                <summary><strong>Advanced</strong> — the exact configuration, every key and default</summary>
                <${Note}>Everything here already has a sane default — the machine runs fine
                untouched. Change these only if you know you need to.<//>
                ${
                  !remoteMonero &&
                  html`<${Field} label="Chain size">
                    <select value=${String(v("prune") ?? true)} onChange=${on("prune")}>
                        <option value="true">Pruned — about 120 GB (default, mines exactly the same)</option>
                        <option value="false">Full — about 320 GB (only if you need the whole chain)</option>
                    </select>
                <//>
                <${Note}>A local Tari node adds about 170 GB on top. Under roughly 350 GB of
                disk, pruned Monero plus a ${" "}<em>remote</em>${" "}Tari node is the
                combination that fits.<//>`
                }
                <${Field} label="Healthchecks.io ping URL">
                    <input value=${v("healthchecks") || ""} onInput=${on("healthchecks")}
                        autocomplete="off" spellcheck=${false} placeholder="https://hc-ping.com/your-uuid" />
                <//>
                <${Note}>Tells you when this machine goes ${" "}<em>silent</em>${" "}— a power cut
                or a crash, which the machine itself cannot report.<//>
                <${Field} label="Time zone">
                    <input value=${v("timezone") || "auto"} onInput=${on("timezone")} list="wizard-tzs"
                        autocomplete="off" />
                <//>
                <datalist id="wizard-tzs">${TIMEZONES.map((t) => html`<option value=${t} />`)}</datalist>
                <${Note}><code>auto</code>${" "}uses this machine's own setting — for dashboard
                timestamps and the daily summary.<//>

                <${Note}>This is what the machine will run. Editing a field above updates it;
                editing it here directly wins. Keys still at their documented default are not
                written to disk, so this machine keeps receiving improved defaults from future
                updates — the effective configuration is identical either way.<//>
                <textarea class="wizard-json wizard-mono" value=${jsonText} onInput=${this.editJson}
                    spellcheck=${false}></textarea>
                <${Err}>${jsonError}<//>
            </details>`
            }

            ${
              diskPicked &&
              html`<button type="submit" class="btn-toggle active" disabled=${(!rig && !!jsonError) || this.state.submitting}>
                ${
                  this.state.submitting
                    ? "Validating…"
                    : keepEverything
                      ? "Reinstall the system — keep everything"
                      : installer
                        ? chosen === "usb"
                          ? "Validate, then save to this stick"
                          : "Validate, then install"
                        : "Apply"
                }</button>`
            }
        </form>
    </div>`;
  }

  render() {
    const { stage, error, status } = this.state;
    let view;
    if (stage === "gate") view = html`<${Gate} error=${error} onSubmit=${this.auth} />`;
    else if (stage === "installing") view = html`<${Installing} status=${status} />`;
    else if (stage === "done")
      view = html`<${Done} status=${status} handoff=${this.state.handoff}
        installer=${this.state.installer} stick=${this.state.chosen === "usb"}
        rig=${this.state.role === "rig"} onAck=${this.ack} />`;
    else view = savedRoleOrSetup(this);
    return html`<h1>Pithead setup</h1>${view}`;
  }
}

// Mount only in a browser (node --test imports this module; a bare `document` would break that).
// Clear #app: the shell ships the heading and "Loading…" inside it, and preact APPENDS (#1868).
if (typeof document !== "undefined") {
  document.getElementById("app").replaceChildren();
  render(html`<${WizardApp} />`, document.getElementById("app"));
}
