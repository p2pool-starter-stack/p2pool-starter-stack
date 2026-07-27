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
export const InstallView = ({ disks, error, chosen, confirm, onPick, onConfirm, onSubmit }) => {
  const picked = disks.find((d) => d.name === chosen);
  const verdictText = (d) =>
    d.state === "pithead-with-data"
      ? "KEEPS existing data (reinstall)"
      : d.state === "pithead"
        ? "ERASES it (Pithead layout, no data partition)"
        : "ERASES everything on it";
  return html`<div class="card">
    <p>This machine is running from the installation medium. Choose the disk to install onto —
    everything on it is erased unless it already holds a Pithead data partition.</p>
    <${Err}>${error}<//>
    <form onSubmit=${onSubmit}>
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
          html`<p class=${picked.state === "pithead-with-data" ? "text-muted" : "c-bad"}>
            Installing to ${picked.name} — this ${verdictText(picked)}.
        </p>`
        }
        <${Field} label="Type the disk name to confirm">
            <input value=${confirm} onInput=${onConfirm} autocomplete="off" autocapitalize="off"
                spellcheck=${false} placeholder=${chosen || "choose a disk above first"} />
        <//>
        <button type="submit">Erase and install</button>
    </form>
    <${Note}>Disks already holding a Pithead ${" "}<code>data</code>${" "}partition are
    reinstalled in place and keep their synced chain. Everything else is erased.<//>
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
            <${Note}>The setup page returns from the installed system, with a new token.<//>`
        : html`<p class="text-muted">${status || "Working…"}</p>`
    }
</div>`;

export const Done = ({ status }) => html`<div class="card">
    <p><strong>Configuration received.</strong> This machine is validating and provisioning
    itself — watch its console for the dashboard address, the generated login, and where to
    point your miners. This page closes when provisioning completes.</p>
    <p class="text-muted">${status || "Waiting…"}</p>
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
    jsonText: "",
    jsonError: "",
    status: "",
  };

  async loadState() {
    const res = await fetch("/api/wizard-state");
    if (!res.ok) return false;
    const s = await res.json();
    this.setState({
      stage: s.mode === "installer" ? "install" : "setup",
      cfg: s.config,
      reference: s.reference,
      disks: s.disks,
      error: s.error || "",
      jsonText: JSON.stringify(s.config, null, 2),
    });
    return true;
  }

  async componentDidMount() {
    await this.loadState(); // an existing session cookie skips the gate
  }

  poll(stage) {
    this.setState({ stage });
    const tick = async () => {
      try {
        const status = await (await fetch("/status")).text();
        this.setState({ status });
        if (status.startsWith("Rejected")) {
          // Validation failed host-side: reopen the form with the attempt and the reason.
          await this.loadState();
          return;
        }
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
    const res = await fetch("/submit", {
      method: "POST",
      body: new URLSearchParams({ config: JSON.stringify(this.state.cfg) }),
    });
    if (res.ok) this.poll("done");
    else this.setState({ error: "Submit failed — check the configuration and retry." });
  };

  install = async (e) => {
    e.preventDefault();
    const res = await fetch("/install", {
      method: "POST",
      body: new URLSearchParams({ disk: this.state.chosen, confirm: this.state.confirm }),
    });
    if (res.ok) this.poll("installing");
    else
      this.setState({ error: `Type ${this.state.chosen || "the disk name"} exactly to confirm.` });
  };

  renderSetup() {
    const { cfg, error, jsonText, jsonError } = this.state;
    const v = (name) => pathGet(cfg, FIELDS[name].path);
    const on = (name) => this.edit(FIELDS[name].path);
    const addr = classifyMoneroAddress(v("moneroWallet"));
    const tg = telegramPairReady(v("telegramToken"), v("telegramChat"));
    const remoteMonero = v("moneroMode") === "remote";
    const remoteTari = v("tariMode") === "remote";
    return html`<div class="card">
        <p>Only the answers that cannot be guessed for you. Everything else keeps its documented
        default and stays editable from the dashboard.</p>
        <${Err}>${error}<//>
        <form onSubmit=${this.submit}>
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

            <button type="submit" disabled=${!!jsonError}>Apply</button>
            <${Note}>This machine validates and provisions itself. The dashboard login is
            generated on the machine and shown on its console — it never travels over this
            page.<//>
        </form>
    </div>`;
  }

  render() {
    const { stage, error, disks, chosen, confirm, status } = this.state;
    let view;
    if (stage === "gate") view = html`<${Gate} error=${error} onSubmit=${this.auth} />`;
    else if (stage === "install")
      view = html`<${InstallView} disks=${disks} error=${error} chosen=${chosen} confirm=${confirm}
        onPick=${(e) => this.setState({ chosen: e.target.value })}
        onConfirm=${(e) => this.setState({ confirm: e.target.value })}
        onSubmit=${this.install} />`;
    else if (stage === "installing") view = html`<${Installing} status=${status} />`;
    else if (stage === "done") view = html`<${Done} status=${status} />`;
    else view = this.renderSetup();
    return html`<h1>Pithead setup</h1>${view}`;
  }
}

// Mount only in a browser: node --test imports this module to render-probe the views, and a
// bare `document` reference at import time would make the whole file untestable.
if (typeof document !== "undefined") {
  render(html`<${WizardApp} />`, document.getElementById("app"));
}
