// The screen a set-up-again boot opens on (#1318), kept out of wizard.mjs because that file is
// at its budget ceiling and because the decision this makes is worth testing without a DOM.
//
// A boot with `pithead.setup=1` publishes `saved-role.json`, and the host's having named a role
// is the whole signal: the operator is offered the machine as it stands, and only reaches the
// setup form by asking for it. Keeping is the default because it changes nothing — the page
// writes one empty spool file and the host carries on booting with the configuration it has.

import { html } from "./preact.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

// What each role is, in the operator's terms rather than the config's. A role NOT in this map
// is one the page cannot name, and a screen offering to keep "your saved configuration" without
// saying what it is asks the operator to confirm something they cannot see — so an unknown role
// falls through to the normal wizard instead.
const ROLES = {
  rig: "a rig — it mines toward a Pithead, which manages it from there",
  pithead: "a Pithead — it runs the node, the pool and this dashboard",
  both: "a Pithead with its own miner",
};

/**
 * What the screen says about the saved role, or null when there is nothing nameable to keep —
 * no file, a file the server could not use, or a role this page has no words for. Rows follow
 * the handoff card's rule: a value the host left empty drops its own row rather than rendering
 * a blank beside a label.
 */
export function savedRoleSummary(saved) {
  const name = ROLES[saved?.role];
  if (!name) return null;
  const rows = [];
  if (saved.pool) rows.push({ label: "Mines toward", value: saved.pool });
  if (saved.worker) rows.push({ label: "Worker name", value: saved.worker });
  return { name, rows };
}

export const SavedRoleScreen = ({ summary, kept, error, onKeep, onSetUpAgain }) => html`<div
    class="card">
    ${
      kept
        ? html`<h3>Keeping this machine as it is</h3>
            <p>Nothing was changed. This page is done — the machine carries on starting up.</p>`
        : html`<h3>This machine is already set up</h3>
            <p>It is ${summary.name}.</p>
            ${summary.rows.map(
              (r) =>
                html`<${Field} label=${r.label}><code class="wizard-mono">${r.value}</code><//>`,
            )}
            <${Err}>${error}<//>
            <button type="button" class="btn-toggle active" onClick=${onKeep}>Keep it</button>
            <button type="button" class="wizard-link" onClick=${onSetUpAgain}>Set up again</button>
            <${Note}>Setting it up again asks the same questions as a first boot, with this
            machine's answers already filled in. Its login and other secrets are never filled
            in — you choose those again.<//>`
    }
</div>`;

/**
 * The wizard's setup branch: this screen when the host named a role and the operator has not
 * asked to start over, otherwise the ordinary form. Owns the Keep button's one call, so the
 * app itself gains nothing but this dispatch.
 */
export function savedRoleOrSetup(app) {
  const summary = app.state.setUpAgain ? null : savedRoleSummary(app.state.savedRole);
  if (!summary) return app.renderSetup();
  const keep = async () => {
    const ok = (await fetch("/keep-role", { method: "POST" })).ok;
    app.setState(ok ? { keptRole: true } : { keepError: "could not keep this configuration" });
  };
  return html`<${SavedRoleScreen} summary=${summary} kept=${app.state.keptRole}
    error=${app.state.keepError} onKeep=${keep}
    onSetUpAgain=${() => app.setState({ setUpAgain: true })} />`;
}
