// The set-up-again screen (#1318): which role the page is willing to offer back, and what it
// does with each answer. Kept DOM-free — the two branches that matter are a boot state nobody
// can reach by hand, and the fall-through has to be provable without a browser.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  SavedRoleScreen,
  savedRoleOrSetup,
  savedRoleSummary,
} from "../../mining_dashboard/web/static/savedrole.mjs";
import { html } from "../../mining_dashboard/web/static/preact.mjs";
import { renderToString } from "./helpers/render.mjs";

// The shape wizard.py's _saved_role publishes for a rig.
const RIG = { role: "rig", pool: "pithead.lan:3333", worker: "rig-01" };

const labels = (s) => savedRoleSummary(s).rows.map((r) => r.label);

// --- savedRoleSummary -------------------------------------------------------------------------

test("savedRoleSummary: a rig names where it mines and what it is called", () => {
  const s = savedRoleSummary(RIG);
  assert.match(s.name, /rig/);
  assert.deepEqual(labels(RIG), ["Mines toward", "Worker name"]);
  assert.deepEqual(
    s.rows.map((r) => r.value),
    [RIG.pool, RIG.worker],
  );
});

test("savedRoleSummary: the two coordinators are named apart and carry no rows", () => {
  const pithead = savedRoleSummary({ role: "pithead" });
  const both = savedRoleSummary({ role: "both" });
  assert.deepEqual(pithead.rows, []);
  assert.deepEqual(both.rows, []);
  // A coordinator with its own miner is a different machine to the operator, so it must not
  // read back as the plain one.
  assert.notEqual(pithead.name, both.name);
});

test("savedRoleSummary: a role the page cannot name is not one it offers to keep", () => {
  // Falling through to the normal wizard is the safe answer: a screen that offers to keep
  // "your configuration" without saying what it is asks for a blind confirmation.
  for (const saved of [null, undefined, {}, { role: "" }, { role: "future-role" }, { pool: "p" }]) {
    assert.equal(savedRoleSummary(saved), null, JSON.stringify(saved));
  }
});

test("savedRoleSummary: an empty value drops its own row rather than blanking it", () => {
  assert.deepEqual(labels({ ...RIG, worker: "" }), ["Mines toward"]);
  assert.deepEqual(labels({ ...RIG, pool: "" }), ["Worker name"]);
  assert.deepEqual(labels({ role: "rig" }), []);
  // The sibling that keeps the three above narrow: the same reader, given both values, has to
  // produce the other answer.
  assert.deepEqual(labels(RIG), ["Mines toward", "Worker name"]);
});

// --- the dispatch -----------------------------------------------------------------------------

const fakeApp = (state) => {
  const app = {
    state,
    setState: (patch) => Object.assign(app.state, patch),
    renderSetup: () => {
      app.setupRendered = true;
      return html`<p>the setup form</p>`;
    },
    setupRendered: false,
  };
  return app;
};

test("savedRoleOrSetup: a normal boot goes straight to the setup form", () => {
  const app = fakeApp({ savedRole: null });
  savedRoleOrSetup(app);
  assert.equal(app.setupRendered, true);
});

test("savedRoleOrSetup: asking to set up again reaches the form past a saved role", () => {
  const app = fakeApp({ savedRole: RIG, setUpAgain: true });
  savedRoleOrSetup(app);
  assert.equal(app.setupRendered, true);
});

test("savedRoleOrSetup: asking to restore reaches the form past a saved role (#1923)", () => {
  // The same fall-through set-up-again uses. `renderSetup`'s own first line dispatches
  // `restoreMode` to `renderRestore` (`wizard.mjs`), which `wizard.test.mjs` covers at seven
  // sites — so this row proves THIS side of the seam (the screen lets go) and cites the other.
  const app = fakeApp({ savedRole: RIG, restoreMode: true });
  savedRoleOrSetup(app);
  assert.equal(app.setupRendered, true);
});

test("Restore from a backup asks for the restore branch and clears a stale error (#1923)", () => {
  // The error being cleared is not decoration: a failed Keep leaves its reason on screen, and
  // carrying it onto the restore form would blame the upload for the previous action's failure.
  const app = fakeApp({ savedRole: RIG, keepError: "could not keep this configuration" });
  savedRoleOrSetup(app).props.onRestore();
  assert.equal(app.state.restoreMode, true);
  assert.equal(app.state.error, "");
  // The restore form's Back clears `restoreMode` and lands on THIS screen again — the first
  // choice here with a way back — so a failed Keep left in `keepError` would be waiting for the
  // operator on their return, reporting an action they have since abandoned.
  assert.equal(app.state.keepError, "");
  // The control: the OTHER exit does not set the restore flag, so this row is about the door it
  // names rather than about any button on the screen.
  const other = fakeApp({ savedRole: RIG });
  savedRoleOrSetup(other).props.onSetUpAgain();
  assert.equal(other.state.restoreMode, undefined);
  assert.equal(other.state.setUpAgain, true);
});

test("savedRoleOrSetup: an unnameable role falls through rather than failing", () => {
  const app = fakeApp({ savedRole: { role: "future-role" } });
  savedRoleOrSetup(app);
  assert.equal(app.setupRendered, true);
});

test("savedRoleOrSetup: a named role opens the screen instead of the form", () => {
  const app = fakeApp({ savedRole: RIG });
  const view = savedRoleOrSetup(app);
  assert.equal(app.setupRendered, false);
  assert.match(renderToString(view), /already set up/);
});

// --- rendered ---------------------------------------------------------------------------------

const screen = (props) =>
  renderToString(html`<${SavedRoleScreen} summary=${savedRoleSummary(RIG)} ...${props} />`);

test("rendered: the screen says what the machine is and offers all three answers", () => {
  const card = screen({});
  assert.match(card, /already set up/);
  assert.match(card, /rig/);
  assert.match(card, new RegExp(RIG.pool.replace(".", "\\.")));
  assert.match(card, new RegExp(RIG.worker));
  assert.match(card, /Keep it/);
  assert.match(card, /Set up again/);
  // #1923: the operator most likely to boot this screen is the one holding a backup, and it was
  // the one screen in the product that did not mention restoring from one.
  assert.match(card, /Restore from a backup/);
});

test("rendered: the restore choice names what it REPLACES, not just that it exists (#1923)", () => {
  // A door labelled only "Restore from a backup" asks for a blind choice on the one path where
  // the machine has something to lose: this boot already has an identity, and restoring
  // overwrites it. The fresh-boot path has nothing to destroy and says less, deliberately.
  const card = screen({});
  assert.match(card, /replaces\s+this machine's configuration and secrets/);
  assert.match(card, /onion address/);
  // Narrowness: the same note must still distinguish the OTHER destructive-sounding choice,
  // which does not replace secrets — a needle that has widened to "any scary sentence" fails here.
  assert.match(card, /Its login and other secrets are never filled\s+in/);
});

test("rendered: after keeping, the page closes rather than offering the choice again", () => {
  const card = screen({ kept: true });
  assert.match(card, /Nothing was changed/);
  assert.doesNotMatch(card, /Keep it/);
  assert.doesNotMatch(card, /Set up again/);
  // The third choice has to leave with the other two: a restore door still open on a screen that
  // has already committed to keeping would act on a decision the operator has finished making.
  assert.doesNotMatch(card, /Restore from a backup/);
});

test("rendered: a failed keep says so on the screen the operator is still looking at", () => {
  assert.match(screen({ error: "could not keep this configuration" }), /could not keep/);
});

// --- the Keep button's one call ---------------------------------------------------------------

test("Keep it posts once and closes the page", async () => {
  const calls = [];
  const app = fakeApp({ savedRole: RIG });
  globalThis.fetch = async (url, opts) => {
    calls.push([url, opts.method]);
    return { ok: true };
  };
  await savedRoleOrSetup(app).props.onKeep();
  assert.deepEqual(calls, [["/keep-role", "POST"]]);
  assert.equal(app.state.keptRole, true);
});

test("Keep it that the host refuses leaves the choice on screen with a reason", async () => {
  const app = fakeApp({ savedRole: RIG });
  globalThis.fetch = async () => ({ ok: false });
  await savedRoleOrSetup(app).props.onKeep();
  assert.equal(app.state.keptRole, undefined);
  assert.match(app.state.keepError, /could not keep/);
});
