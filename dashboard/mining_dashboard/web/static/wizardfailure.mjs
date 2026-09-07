// Failed-install recovery. The server owns the stage and retained values; this view only renders
// that state and asks the authenticated server to reopen the settings form.
import { html } from "./preact.mjs";
import { Err, Note } from "./wizardparts.mjs";

export function restoredState(server, current) {
  return {
    stage:
      {
        installer: "setup",
        failed: "failed",
        installing: "installing",
        handoff: "done",
        done: "done",
      }[server.stage] || "setup",
    installer: server.stage === "installer",
    ...restoredAttempt(server, current),
  };
}

export const ConfigChanges = ({ changes }) =>
  changes?.length
    ? html`<${Note}>Adjusted for Pithead 2.0: ${changes.join("; ")}. Review the settings below.<//>`
    : null;

export const InstallFailed = ({ error, changes, onBack }) => html`<div class="card">
    <h3>Installation failed</h3>
    <${Err}>${error || "The install stopped. Check the machine console for detail."}<//>
    <${ConfigChanges} changes=${changes} />
    <p>Nothing else will be installed until you return to the settings and submit again.</p>
    <button type="button" class="btn-toggle active" onClick=${onBack}>Back to the settings</button>
</div>`;

export const failedView = (app) =>
  html`<${InstallFailed} error=${app.state.error} changes=${app.state.configChanges} onBack=${() => backToSettings(app)} />`;

export function restoredAttempt(server, current) {
  const fresh = current.stage !== "setup" || !current.cfg || !Object.keys(current.cfg).length;
  const attempt = server.install_attempt || {};
  const restored = {
    configChanges: Array.isArray(server.config_changes) ? server.config_changes : [],
  };
  const failed = server.stage === "failed";
  if (failed) restored.confirm = "";
  if (!fresh && !failed) return restored;
  if (typeof attempt.disk === "string") restored.chosen = attempt.disk;
  if (["keep", "data", "all"].includes(attempt.wipe)) restored.wipe = attempt.wipe;
  if (["auto", "set", "none"].includes(server.auth_mode)) restored.authMode = server.auth_mode;
  return restored;
}

export async function backToSettings(app) {
  const res = await fetch("/retry", { method: "POST" });
  if (res.ok) {
    if (await app.loadState()) return true;
    app.setState({ error: "Settings reopened. Reload this page to continue." });
    return false;
  }
  let error = "Could not reopen the settings. Reload the page and try again.";
  try {
    error = (await res.json()).error || error;
  } catch {
    // A non-JSON proxy error has no safe detail to render; keep the actionable fallback.
  }
  app.setState({ error });
  return false;
}
