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

const Note = ({ children }) => html`<p class="text-muted wizard-note">${children}</p>`;
const Err = ({ children }) => (children ? html`<p class="c-bad">${children}</p>` : null);

const Field = ({ label, children }) => html`<label class="config-field">
    <span class="config-field-name">${label}</span>${children}
</label>`;

export const Gate = ({ error, onSubmit }) => html`<div class="card">
    <p>Enter the one-time token shown on this machine's console or terminal.</p>
    <${Err}>${error}<//>
    <form onSubmit=${onSubmit}>
        <${Field} label="Token">
            <input name="token" autofocus autocomplete="off" autocapitalize="off"
                spellcheck=${false} placeholder="pit-XXXXXX" />
        <//>
        <${Note}>Case doesn't matter, and the ${" "}<code>pit-</code>${" "}prefix is optional.<//>
        <button type="submit">Continue</button>
    </form>
</div>`;

// Disk picker: the consequence sits right after the disk name (a <select> truncates on the
// right — bench screenshots cut off exactly the erase/keep words), and is restated in full
// below the control, red when destructive. The server re-validates the choice against the
// inventory the HOST published; a browser can never name a disk the host did not offer.
export const InstallSection = ({ disks, chosen, confirm, wipe, onPick, onConfirm, onWipe }) => {
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
            ${disks.map(
              (d) =>
                html`<option value=${d.name}>
                    ${d.name} — ${verdictText(d)} — ${d.size} ${d.model} (SN ${d.serial})
                </option>`,
            )}
        </select>
    <//>
    ${
      picked &&
      picked.state === "pithead-with-data" &&
      html`<${Field} label="This disk holds a previous install">
        <label class="choice"><input type="radio" name="wipe" value="keep"
            checked=${wipe === "keep"} onChange=${onWipe} />
            Keep my data — settings, wallets and the synced chains all survive</label>
        <label class="choice"><input type="radio" name="wipe" value="data"
            checked=${wipe === "data"} onChange=${onWipe} />
            Fresh start, keep the blockchains — settings and wallets are wiped, the synced
            chains (days of downloading) survive</label>
        <label class="choice"><input type="radio" name="wipe" value="all"
            checked=${wipe === "all"} onChange=${onWipe} />
            <span class="c-bad">Wipe everything</span> — including the synced chains; the new
            install re-downloads them from scratch</label>
    <//>`
    }
    ${
      picked &&
      picked.state !== "pithead-with-data" &&
      html`<p class="c-bad">Installing to ${picked.name} — this ${verdictText(picked)}.</p>`
    }
    <${Field} label="Type the disk name to confirm">
        <input value=${confirm} onInput=${onConfirm} autocomplete="off" autocapitalize="off"
            spellcheck=${false} placeholder=${chosen || "choose a disk above first"} />
    <//>
</div>`;
};

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

export const Done = ({ status, handoff, installer, onAck }) => html`<div class="card">
    ${
      handoff
        ? html`<h3>Save this before anything else</h3>
            <p>This is shown once, here.</p>
            <${Field} label="Dashboard user"><code class="wizard-mono">${handoff.username}</code><//>
            <${Field} label="Dashboard password"><code class="wizard-mono">${handoff.password}</code><//>
            <${Field} label="Dashboard address"><code class="wizard-mono">${handoff.dashboard}</code><//>
            <${Field} label="Point miners at"><code class="wizard-mono">${handoff.stratum}</code><//>
            <button type="button" onClick=${onAck}>
                ${installer ? "I saved these — erase the disk and install" : "I saved these — start provisioning"}</button>
            <${Note}>${
              installer
                ? html`Nothing is written to the disk until you press this. The machine installs,
                  switches itself off, and provisions with this exact configuration when you
                  power it back on — these credentials are the ones it will serve.`
                : html`Provisioning waits for this confirmation (up to 10 minutes), because the
                  page goes dark while the machine builds itself.`
            }<//>`
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
    jsonText: "",
    jsonError: "",
    authMode: "auto", // auto | set | none — travels beside the config (see wizard.py submit)
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
      handoff: s.handoff || null,
    };
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

  auth = async (e) => {
    e.preventDefault();
    const res = await fetch("/auth", {
      method: "POST",
      body: new URLSearchParams(new FormData(e.target)),
    });
    if (res.ok && (await this.loadState())) return;
    this.setState({ error: "Wrong token." });
  };

  // Field edit → config → JSON pane. The JSON is the single source of what gets submitted.
  edit = (path) => (e) => {
    const raw = e.target.type === "checkbox" ? String(e.target.checked) : e.target.value;
    const cfg = this.state.cfg;
    pathSet(cfg, path, coerceForPath(this.state.reference, path, raw));
    this.setState({ cfg, jsonText: JSON.stringify(cfg, null, 2) });
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
    const body = {
      config: JSON.stringify(this.state.cfg),
      auth_mode: this.state.authMode,
    };
    // One page, one submission: on the installation medium the disk choice rides beside the
    // config, and the server gates both before anything is written.
    if (this.state.installer) {
      if (!this.state.chosen) {
        this.setState({ error: "Choose the disk to install onto." });
        return;
      }
      if (this.state.confirm !== this.state.chosen) {
        this.setState({ error: `Type ${this.state.chosen} exactly to confirm the erase.` });
        return;
      }
      body.disk = this.state.chosen;
      body.confirm = this.state.confirm;
      body.wipe = this.state.wipe;
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
    this.setState({ stage: "done", status: "Validating…" });
    this.poll();
  };

  ack = async () => {
    await fetch("/handoff-ack", { method: "POST" });
    await this.loadState(); // the server drops out of the handoff stage; the view follows
  };

  renderSetup() {
    const { cfg, error, jsonText, jsonError } = this.state;
    const v = (name) => pathGet(cfg, FIELDS[name].path);
    const on = (name) => this.edit(FIELDS[name].path);
    const addr = classifyMoneroAddress(v("moneroWallet"));
    const tg = telegramPairReady(v("telegramToken"), v("telegramChat"));
    const remoteMonero = v("moneroMode") === "remote";
    const remoteTari = v("tariMode") === "remote";
    const { installer, disks, chosen, confirm, wipe } = this.state;
    return html`<div class="card">
        <p>${
          installer
            ? html`Choose the disk to install onto and answer the questions below — the machine
              validates everything, shows you the login to save, and only then erases the disk.
              After it switches itself off, remove the stick and power it on: it provisions
              itself with exactly this configuration.`
            : html`Only the answers that cannot be guessed for you. Everything else keeps its
              documented default and stays editable from the dashboard.`
        }</p>
        <${Err}>${error}<//>
        <form onSubmit=${this.submit}>
            ${
              installer &&
              html`<${InstallSection} disks=${disks} chosen=${chosen} confirm=${confirm}
                wipe=${wipe}
                onPick=${(e) => this.setState({ chosen: e.target.value, wipe: "keep" })}
                onConfirm=${(e) => this.setState({ confirm: e.target.value })}
                onWipe=${(e) => this.setState({ wipe: e.target.value })} />`
            }
            <h3>Payout addresses</h3>
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
                : html`<div class="wizard-when">
                    <${Field} label="Chain size">
                        <select value=${String(v("prune") ?? true)} onChange=${on("prune")}>
                            <option value="true">Pruned — about 120 GB (default, mines exactly the same)</option>
                            <option value="false">Full — about 320 GB (only if you need the whole chain)</option>
                        </select>
                    <//>
                    <${Note}>A local Tari node adds about 170 GB on top. Under roughly 350 GB of
                    disk, pruned Monero plus a ${" "}<em>remote</em>${" "}Tari node is the
                    combination that fits.<//>
                </div>`
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
            <label class="config-field">
                <span class="config-field-name">Also mine with this machine's own CPU</span>
                <input type="checkbox" checked=${!!v("localMiner")} onChange=${on("localMiner")} />
            </label>

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

            <h3>Alerts <span class="text-muted">(optional — skip both if you are not sure)</span></h3>
            <${Field} label="Healthchecks.io ping URL">
                <input value=${v("healthchecks") || ""} onInput=${on("healthchecks")}
                    autocomplete="off" spellcheck=${false} placeholder="https://hc-ping.com/your-uuid" />
            <//>
            <${Note}>Tells you when this machine goes ${" "}<em>silent</em>${" "}— a power cut
            or a crash, which the machine itself cannot report.<//>
            <${Field} label="Telegram bot token">
                <input value=${v("telegramToken") || ""} onInput=${on("telegramToken")}
                    autocomplete="off" spellcheck=${false} placeholder="123456:ABC-DEF…" />
            <//>
            <${Field} label="Telegram chat ID">
                <input value=${v("telegramChat") || ""} onInput=${on("telegramChat")}
                    autocomplete="off" spellcheck=${false} placeholder="987654321" />
            <//>
            ${tg.partial && html`<p class="c-bad">Telegram needs both fields, or leave both blank.</p>`}

            <${Field} label="Time zone">
                <input value=${v("timezone") || "auto"} onInput=${on("timezone")} list="wizard-tzs"
                    autocomplete="off" />
            <//>
            <datalist id="wizard-tzs">${TIMEZONES.map((t) => html`<option value=${t} />`)}</datalist>
            <${Note}><code>auto</code>${" "}uses this machine's own setting — for dashboard
            timestamps and the daily summary.<//>

            <details>
                <summary><strong>Advanced</strong> — the exact configuration, every key and default</summary>
                <${Note}>This is what the machine will run. Editing a field above updates it;
                editing it here directly wins. Keys still at their documented default are not
                written to disk, so this machine keeps receiving improved defaults from future
                updates — the effective configuration is identical either way.<//>
                <textarea class="wizard-json wizard-mono" value=${jsonText} onInput=${this.editJson}
                    spellcheck=${false}></textarea>
                <${Err}>${jsonError}<//>
            </details>

            <button type="submit" disabled=${!!jsonError}>
                ${installer ? "Validate, then install" : "Apply"}</button>
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
        installer=${this.state.installer} onAck=${this.ack} />`;
    else view = this.renderSetup();
    return html`<h1>Pithead setup</h1>${view}`;
  }
}

// Mount only in a browser: node --test imports this module to render-probe the views, and a
// bare `document` reference at import time would make the whole file untestable.
if (typeof document !== "undefined") {
  render(html`<${WizardApp} />`, document.getElementById("app"));
}
