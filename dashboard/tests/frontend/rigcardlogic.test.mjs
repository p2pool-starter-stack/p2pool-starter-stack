// Unit tests for the rig handoff card's contents (issue #1836):
// mining_dashboard/web/static/rigcardlogic.mjs — which rows the card shows, and the note that
// replaced "no login — nothing to save" now that there is a token to save.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// Mutation-kill notes: the two "missing" cases are the point of the module. Dropping either guard
// in rigCardFields puts a labelled row with a blank value on the card, which the row-count and
// label assertions catch; dropping either branch in rigCardNote leaves the operator being told to
// paste something that does not exist, which the phrase assertions catch in both directions — each
// case asserts what its note MUST say and what it must NOT.
import assert from "node:assert/strict";
import { test } from "node:test";

import { html } from "../../mining_dashboard/web/static/preact.mjs";
import {
  rigCardFields,
  rigCardNote,
} from "../../mining_dashboard/web/static/rigcardlogic.mjs";
import { Done } from "../../mining_dashboard/web/static/wizard.mjs";
import { renderToString } from "./helpers/render.mjs";

// The shape lib/pithead/12-firstboot-wizard.sh publishes for role=rig. The token keeps the real
// 32-hex shape but is all zeros on purpose: gitleaks scans every pushed ref and reads its config
// from the checked-out one, so a plausible literal here reds the secret scan on every OTHER branch
// until an allowlist entry for it has merged. Nothing on the card depends on the characters.
const FULL = {
  role: "rig",
  worker: "rig-01",
  stratum: "stratum+tcp://pithead.example:3333",
  token: "00000000000000000000000000000000",
  address: "10.0.0.9",
};
const labels = (h) => rigCardFields(h).map((f) => f.label);

// --- rigCardFields --------------------------------------------------------------------------

test("rigCardFields: a complete handoff shows all four rows, worker and pool first", () => {
  assert.deepEqual(labels(FULL), [
    "Worker name",
    "Mines toward",
    "This machine's address",
    "Control token",
  ]);
  assert.deepEqual(
    rigCardFields(FULL).map((f) => f.value),
    [FULL.worker, FULL.stratum, FULL.address, FULL.token],
  );
});

test("rigCardFields: no IPv4 lease yet drops the address row rather than blanking it", () => {
  const fields = rigCardFields({ ...FULL, address: "" });
  assert.deepEqual(labels({ ...FULL, address: "" }), [
    "Worker name",
    "Mines toward",
    "Control token",
  ]);
  assert.ok(fields.every((f) => f.value !== ""));
});

test("rigCardFields: an unminted token drops the token row rather than blanking it", () => {
  const fields = rigCardFields({ ...FULL, token: "" });
  assert.deepEqual(labels({ ...FULL, token: "" }), [
    "Worker name",
    "Mines toward",
    "This machine's address",
  ]);
  assert.ok(fields.every((f) => f.value !== ""));
});

test("rigCardFields: both missing leaves only the two rows the card always had", () => {
  assert.deepEqual(labels({ ...FULL, token: "", address: "" }), ["Worker name", "Mines toward"]);
});

test("rigCardFields: worker and pool are unconditional — an empty one still gets its row", () => {
  // Deliberate asymmetry: these two predate the token and the host decides what they hold, so the
  // card does not start hiding them. Only the rows this change added are conditional.
  assert.deepEqual(labels({ ...FULL, worker: "", stratum: "" }), [
    "Worker name",
    "Mines toward",
    "This machine's address",
    "Control token",
  ]);
});

// --- rigCardNote ----------------------------------------------------------------------------

test("rigCardNote: with a token and an address, it points at the adopt form and the port", () => {
  const note = rigCardNote(FULL);
  assert.match(note, /Workers → Adopt/);
  assert.match(note, /control port 8082/);
  assert.match(note, /shown once and never again/);
  assert.doesNotMatch(note, /no address on the network yet/);
});

test("rigCardNote: with no address, it says to read the address off the console", () => {
  const note = rigCardNote({ ...FULL, address: "" });
  assert.match(note, /no address on the network yet/);
  assert.match(note, /console once it is up/);
  // Still the adopt instruction — the token is real, only the address is not known yet.
  assert.match(note, /Workers → Adopt/);
  assert.match(note, /control port 8082/);
});

test("rigCardNote: with no token, it never tells the operator to paste one", () => {
  const note = rigCardNote({ ...FULL, token: "" });
  assert.match(note, /could not create its control token/);
  assert.match(note, /no Pithead can adopt this rig/);
  assert.doesNotMatch(note, /Adopt form/);
  assert.doesNotMatch(note, /control port/);
  assert.doesNotMatch(note, /shown once/);
  // Both halves of the pre-review wording were false, on OPPOSITE paths: run from the stick the
  // machine does not mine at all, and on the installer path nothing ever prints the token. The
  // note must promise neither, so these two pin the retracted claims rather than the new ones.
  assert.doesNotMatch(note, /still mines/);
  assert.doesNotMatch(note, /console says why/);
});

test("rigCardNote: the pre-token wording is gone from every case", () => {
  // The old note said a rig has "nothing to save". It now has exactly one thing to save, so that
  // sentence must not survive in any branch.
  for (const h of [FULL, { ...FULL, address: "" }, { ...FULL, token: "" }]) {
    assert.doesNotMatch(rigCardNote(h), /nothing to save/);
  }
});

// --- the card as the wizard actually renders it -----------------------------------------------
//
// The rows above are decided here but WIRED in wizard.mjs's Done view, so the logic assertions
// alone cannot tell a correct field list from one the view drops on the floor. These two rows
// close that gap. They live in this file rather than beside the other Done probes because
// wizard.test.mjs sits at its file-budget ceiling with no headroom.

test("rendered: a complete handoff puts the address and the token on the card", () => {
  const card = renderToString(
    html`<${Done} status="" handoff=${FULL} installer=${false} stick=${false} onAck=${() => {}} />`,
  );
  assert.match(card, /This machine's address/);
  assert.match(card, /10\.0\.0\.9/);
  assert.match(card, /Control token/);
  assert.match(card, new RegExp(FULL.token));
  assert.match(card, /Workers → Adopt/);
  assert.doesNotMatch(card, /nothing to save/);
});

test("rendered: an unminted token puts no empty 'Control token' row on the card", () => {
  const card = renderToString(
    html`<${Done} status="" handoff=${{ ...FULL, token: "" }} installer=${false} stick=${false}
      onAck=${() => {}} />`,
  );
  assert.doesNotMatch(card, /Control token/);
  assert.doesNotMatch(card, /Workers → Adopt/);
  assert.match(card, /could not create its control token/);
  assert.match(card, /This machine's address/); // the address it DOES have still shows
});
