// Appliance OS update control: drive the host's staged A/B update flow from the dashboard.
//
// The container only ASKS. Every step is one typed intent through the control spool
// (/api/control/os-update -> the host runner's os-check/os-download/os-verify/os-install/
// os-reboot verbs); the host re-derives the release target over Tor, downloads to /data with
// resume, verifies the LOCAL bundle (signature, compatible, downgrade floor) before a slot is
// touched, and installs into the inactive slot while mining keeps running. Nothing here decides
// anything — this file only sequences the asks and renders the host's answers.
//
// The reboot is its own intent behind a typed confirmation: it is the one step that pauses
// mining, and nothing may reboot the machine implicitly. After it, the page polls until the
// dashboard answers again; the post-reboot verdict (updated / rolled back) arrives via the
// host-persisted state in state.os_update and renders as a banner.

import { verdictText } from "./osverdict.mjs";
import { Component, html } from "./preact.mjs";

const CONTROL_HEADERS = { "Content-Type": "application/json", "X-Pithead-Control": "1" };
const POLL_MS = 2000;
// A single download attempt is host-capped (~10 min); polls ride it out with margin.
const OS_POLL_MAX = 450;
// Resume attempts chained per Download/Retry click: 48 x ~10 min covers a very slow Tor night
// while a genuinely dead route still terminates.
const OS_RESUME_MAX = 48;

export const fmtMiB = (bytes) =>
  Number.isFinite(bytes) && bytes > 0 ? Math.round(bytes / 1048576) + " MiB" : "";

// POST one OS-update step; resolves to the intent id (the server always answers 202).
export async function osAction(action, version) {
  const body = version ? { action, version } : { action };
  const res = await fetch("/api/control/os-update", {
    method: "POST",
    headers: CONTROL_HEADERS,
    body: JSON.stringify(body),
  });
  if (!res.ok && res.status !== 202) throw new Error(`HTTP ${res.status}`);
  return (await res.json()).id;
}

// Poll one intent to its terminal result, surfacing in-flight progress ("downloading",
// "installing") through onProgress instead of skipping it — the difference from configview's
// pollResult, which has no progress to show. Rides out dropped connections and proxy 50x the
// same way (the host result file is the durable outcome).
export async function pollOsResult(id, onProgress, max = OS_POLL_MAX) {
  for (let i = 0; i < max; i++) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    let res;
    try {
      res = await fetch(`/api/control/result?id=${encodeURIComponent(id)}`);
    } catch {
      continue;
    }
    if (res.status === 202 || res.status === 502 || res.status === 503 || res.status === 504)
      continue;
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const out = await res.json();
    if (out.status === "downloading" || out.status === "installing") {
      if (onProgress) onProgress(out);
      continue;
    }
    return out;
  }
  throw new Error("Timed out waiting for the host runner — is the control channel running?");
}

// Download with resume: each intent is one bounded host-side attempt, and a "partial" result
// means "the window closed mid-transfer, the file is kept" — resubmit and the transfer resumes.
// `stopped` is the Cancel hook: it ends the CLIENT loop between attempts; the staged partial
// file stays on the host, so a later Download/Retry resumes instead of starting over.
export async function runOsDownload(
  version,
  onProgress,
  stopped = () => false,
  submit = osAction,
  poll = pollOsResult,
) {
  let out = null;
  for (let i = 0; i < OS_RESUME_MAX; i++) {
    const id = await submit("download", version);
    out = await poll(id, onProgress);
    if (out.status !== "partial") return out;
    if (onProgress) onProgress(out);
    if (stopped()) return { ...out, status: "cancelled" };
  }
  return out;
}

// The release-notes href arrives as host-relayed release data, not something this page authored.
// Pin it client-side: only the public GitHub release page ever renders as a link.
export const releaseNotesHref = (u) =>
  typeof u === "string" && u.startsWith("https://github.com/") ? u : null;

// Post-reboot verdict banner, rendered by App beside the disconnected banner. Dismiss hides it
// for this browser session (keyed on the verdict's timestamp); the host clears the verdict
// itself when the next update check moves on.
export const OsVerdictBanner = ({ os }) => {
  const v = os && os.verdict;
  const text = verdictText(v);
  if (!text) return null;
  const key = "os-verdict-dismissed-" + (v.ts || "");
  let dismissed = false;
  try {
    dismissed = sessionStorage.getItem(key) === "1";
  } catch {
    /* storage unavailable: the banner just stays */
  }
  if (dismissed) return null;
  return html`<div class=${"disconnected-banner" + (v.outcome === "updated" ? " status-ok" : "")}>
      ${text}
      <button class="btn-toggle ml-2" onClick=${(e) => {
        try {
          sessionStorage.setItem(key, "1");
        } catch {
          /* fall through — hide for this render at least */
        }
        e.target.closest("div").style.display = "none";
      }}>Dismiss</button>
  </div>`;
};

// Header control. Renders only when the host says this is an appliance (state.os_update
// present) and the control channel is on. One button opens a modal that hosts the whole flow;
// the button reads loud only when an update is actually available.
export class OsUpdateControl extends Component {
  constructor(props) {
    super(props);
    // phase: closed | idle | checking | downloading | verifying | verified | installing |
    //        reboot-pending | confirm-reboot | rebooting | error
    this.state = {
      phase: "closed",
      check: null,
      progress: null,
      result: null,
      error: "",
      confirmText: "",
    };
    this.cancelled = false;
  }

  // What the host remembers across reloads/reboots: reopen the modal mid-flow honestly.
  stepPhase() {
    const step = (this.props.os && this.props.os.step) || "idle";
    if (step === "downloaded") return "verified-pending"; // downloaded but not yet verified
    if (step === "verified") return "verified";
    if (step === "reboot-pending") return "reboot-pending";
    if (step === "downloading") return "resume-pending";
    return "idle";
  }

  // The version this flow is working toward: a live check result, the host's persisted step,
  // or the passive update badge — in that order of freshness.
  targetVersion() {
    if (this.state.check && this.state.check.version) return this.state.check.version;
    const step = this.props.os || {};
    if (step.version) return step.version.startsWith("v") ? step.version : "v" + step.version;
    return (this.props.update && this.props.update.latest) || null;
  }

  fail(e) {
    this.setState({ phase: "error", error: String((e && e.message) || e) });
  }

  async check() {
    this.setState({ phase: "checking", error: "" });
    try {
      const id = await osAction("check");
      const out = await pollOsResult(id);
      if (out.status !== "checked") {
        this.fail(out.error || "The host could not check for updates.");
        return;
      }
      this.setState({ phase: "idle", check: out });
      return out;
    } catch (e) {
      this.fail(e);
    }
  }

  async download() {
    // The host only downloads a target IT resolved: target.json is written in exactly one place,
    // control_os_check. The idle pane offers Download off the passive update badge alone, so on a
    // fresh appliance the first click posted a version the host had never checked, was refused,
    // and the error pane's Retry re-posted the identical call — the first thing the feature ever
    // does, failing forever. Resolve the target here when this flow has not checked yet; check()
    // reports its own failure and returns nothing, which is the whole error path.
    let checked = this.state.check;
    if (!checked) {
      checked = await this.check();
      if (!checked) return;
    }
    // A stale passive badge can offer Download for a release the host then reports as not newer.
    // Posting it anyway earns "an equal version is nothing to update" and puts the error pane's
    // Retry back into the same loop this guard exists to break. Fall back to idle instead, where
    // the pane now renders off the fresh check and offers no Download at all.
    if (checked.newer === false) {
      this.setState({ phase: "idle", check: checked });
      return;
    }
    const version = checked.version || this.targetVersion();
    if (!version) return;
    this.cancelled = false;
    this.setState({ phase: "downloading", progress: null, error: "" });
    try {
      const out = await runOsDownload(
        version,
        (p) => this.setState({ progress: p }),
        () => this.cancelled,
      );
      if (out.status === "cancelled") {
        this.setState({ phase: "idle", progress: out });
        return;
      }
      if (out.status !== "downloaded") {
        this.fail(out.error || "The download did not complete — Retry resumes it.");
        return;
      }
      await this.verify();
    } catch (e) {
      this.fail(e);
    }
  }

  async verify() {
    this.setState({ phase: "verifying", error: "" });
    try {
      const id = await osAction("verify");
      const out = await pollOsResult(id);
      if (out.status !== "verified") {
        this.fail(out.error || "The bundle failed verification.");
        return;
      }
      this.setState({ phase: "verified", result: out });
    } catch (e) {
      this.fail(e);
    }
  }

  async install() {
    this.setState({ phase: "installing", progress: null, error: "" });
    try {
      const id = await osAction("install");
      const out = await pollOsResult(id, (p) => this.setState({ progress: p }));
      if (out.status !== "installed") {
        this.fail(out.error || "The install did not complete — the running system is untouched.");
        return;
      }
      this.setState({ phase: "reboot-pending", result: out });
    } catch (e) {
      this.fail(e);
    }
  }

  async reboot() {
    this.setState({ phase: "rebooting", error: "" });
    try {
      const id = await osAction("reboot");
      const out = await pollOsResult(id, null, 30).catch(() => null); // rejected -> never rebooted
      if (out?.status === "rejected") return this.fail(out.error || "The reboot was refused.");
    } catch {
      /* the reboot may cut the answer off — the reconnect poll below is the real signal */
    }
    this.reconnect();
  }

  // The static "reconnecting" behaviour: poll until the dashboard answers again, then reload —
  // the fresh state carries the post-reboot verdict banner.
  async reconnect(max = 300) {
    for (let i = 0; i < max; i++) {
      await new Promise((r) => setTimeout(r, POLL_MS));
      try {
        const res = await fetch("/api/state?range=1h");
        if (res.ok) {
          window.location.reload();
          return;
        }
      } catch {
        /* still rebooting */
      }
    }
  }

  renderBody() {
    const { phase, check, progress, error, confirmText } = this.state;
    const version = this.targetVersion();
    const running = (this.props.version && this.props.version.text) || "";
    const passive = this.props.update;
    if (phase === "error")
      return html`<p class="status-bad">${error}</p>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "idle", error: "" })}>Close</button>
              ${version ? html`<button class="btn-toggle active" onClick=${() => this.download()}>Retry</button>` : null}
          </div>`;
    if (phase === "checking")
      return html`<p class="text-muted">Asking the release server over Tor…</p>`;
    if (phase === "downloading") {
      const b = progress || {};
      const pct = b.total ? Math.floor(((b.bytes || 0) * 100) / b.total) : 0;
      return html`<p>Downloading ${version} — ${fmtMiB(b.bytes || 0) || "0 MiB"} of ${fmtMiB(b.total)} (${pct}%).</p>
          <p class="text-muted">Over Tor — this can be slow. Mining continues; the download survives
          restarts and resumes where it stopped.</p>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => {
                this.cancelled = true;
              }}>Cancel</button>
          </div>`;
    }
    if (phase === "verifying")
      return html`<p class="text-muted">Verifying the downloaded bundle on the machine — signature,
          compatibility, and version…</p>`;
    if (phase === "verified")
      return html`<p class="status-ok">Bundle ${version} verified — signed for this machine.</p>
          <p>Installing writes the spare system slot. Mining keeps running; nothing changes until
          you reboot.</p>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed" })}>Later</button>
              <button class="btn-toggle active" onClick=${() => this.install()}>Install</button>
          </div>`;
    if (phase === "installing") {
      const pct = (progress && progress.percent) || 0;
      return html`<p>Installing ${version} into the spare slot — ${pct}%.</p>
          <p class="text-muted">Mining keeps running throughout.</p>`;
    }
    if (phase === "reboot-pending" || phase === "confirm-reboot")
      return html`<p class="status-ok">${version || "The update"} is installed in the spare slot.</p>
          <p>Reboot to finish. Mining pauses while the machine restarts — typically under five
          minutes — and if the new version fails its health checks the machine returns to the
          current one on its own.</p>
          <label class="config-confirm-type">Type <code>REBOOT</code> to confirm:
              <input type="text" value=${confirmText}
                  onInput=${(e) => this.setState({ confirmText: e.target.value })} /></label>
          <div class="config-modal-actions">
              <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed", confirmText: "" })}>Later</button>
              <button class="btn-toggle active" disabled=${confirmText !== "REBOOT"}
                  onClick=${() => this.reboot()}>Reboot now</button>
          </div>`;
    if (phase === "rebooting")
      return html`<p>Rebooting — this page reconnects when the dashboard returns.</p>
          <p class="text-muted">Leave it open. The result appears as a banner after the restart.</p>`;
    // idle: current version, what the host knows, and the next honest step.
    const stepPhase = this.stepPhase();
    const size = (check && check.size) || (passive && passive.raucb_size);
    const newer = check ? check.newer : !!(passive && passive.available);
    const notes =
      releaseNotesHref(check && check.notes) || releaseNotesHref(passive && passive.url);
    return html`<p>Running ${running || "this release"}.</p>
        ${
          newer && version
            ? html`<p>Update ${version} is available${size ? ` (${fmtMiB(size)} download)` : ""}.
                ${
                  notes
                    ? html` <a href=${notes} target="_blank" rel="noopener noreferrer">Release notes ↗</a>`
                    : null
                }</p>`
            : html`<p class="text-muted">No newer release is known. Check to ask the release
                server now.</p>`
        }
        <div class="config-modal-actions">
            <button class="btn-toggle" onClick=${() => this.setState({ phase: "closed" })}>Close</button>
            <button class="btn-toggle" onClick=${() => this.check()}>Check now</button>
            ${
              stepPhase === "verified"
                ? html`<button class="btn-toggle active" onClick=${() => this.setState({ phase: "verified" })}>Install staged update</button>`
                : stepPhase === "verified-pending"
                  ? html`<button class="btn-toggle active" onClick=${() => this.verify()}>Verify staged download</button>`
                  : stepPhase === "reboot-pending"
                    ? html`<button class="btn-toggle active" onClick=${() => this.setState({ phase: "reboot-pending" })}>Reboot to finish</button>`
                    : newer && version
                      ? html`<button class="btn-toggle active" onClick=${() => this.download()}>
                          ${stepPhase === "resume-pending" ? "Resume download" : "Download"}</button>`
                      : null
            }
        </div>`;
  }

  render() {
    const { os, enabled } = this.props;
    if (!os || !enabled) return null;
    const { phase } = this.state;
    const passive = this.props.update;
    const attention =
      (passive && passive.available) || (os.step && os.step !== "idle")
        ? " badge-accent"
        : " badge-outline";
    const label =
      os.step === "reboot-pending"
        ? "OS update: reboot to finish"
        : passive && passive.available
          ? `OS update ${passive.latest}`
          : "OS updates";
    const open = phase !== "closed";
    return html`<button class=${"badge version-badge ml-2" + attention}
            title="Check for and apply signed OS image updates"
            onClick=${() => this.setState({ phase: open ? "closed" : this.stepPhase() === "reboot-pending" ? "reboot-pending" : "idle" })}>
            ${label}
        </button>${
          open
            ? html`<div class="config-modal-backdrop">
                <div class="card config-modal">
                    <h3>System update</h3>
                    ${this.renderBody()}
                </div>
            </div>`
            : null
        }`;
  }
}
