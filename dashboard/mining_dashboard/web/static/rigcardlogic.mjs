// The rig handoff card's contents, kept DOM-free so node --test covers the two states nobody can
// produce by hand (issue #1836). The host publishes the card as
// {role, worker, stratum, token, address} — lib/pithead/12-firstboot-wizard.sh's rig handoff — and
// two of those five are legitimately empty at the moment the page renders it:
//
//   token   — rig_access_token could not mint or keep one. The card is written BEFORE the miner is
//             configured, so the wizard shows this state first. What happens next DIVERGES, which
//             is why the note promises neither half: run from the stick, render_rig_miner_config
//             returns 1 and rigforge_setup_run never runs, so the machine does not even mine; on
//             the installer path the target mints its own token and mines, but nothing prints that
//             token after provisioning, so its console cannot tell the operator what to paste.
//   address — hostname -I answered nothing, because the box has no IPv4 lease yet.
//
// A label with a blank beside it is the one thing this card must never show, so an empty value
// drops its own row and the note says what is missing instead. Worker and pool stay unconditional:
// they were on the card before the token existed, and their emptiness is the host's own business.

import { DEFAULT_CONTROL_PORT } from "./workeradoptlogic.mjs";

/**
 * The card's rows, in the order they render. The view owns the markup; this owns only which rows
 * exist, which is what makes the address and token branches testable without a DOM.
 */
export function rigCardFields(handoff) {
  const fields = [
    { label: "Worker name", value: handoff.worker },
    { label: "Mines toward", value: handoff.stratum },
  ];
  if (handoff.address) {
    fields.push({ label: "This machine's address", value: handoff.address });
  }
  if (handoff.token) {
    fields.push({ label: "Control token", value: handoff.token });
  }
  return fields;
}

/**
 * The note under the rows. Before the token existed this said "no login — nothing to save"; there
 * is now exactly one thing to save, and this page is the only place it is ever shown.
 */
export function rigCardNote(handoff) {
  if (!handoff.token) {
    return (
      "This machine could not create its control token. There is nothing to copy here, and no " +
      "Pithead can adopt this rig until it has one — set this machine up again."
    );
  }
  const adopt = handoff.address
    ? "takes this rig's address, control port " + DEFAULT_CONTROL_PORT + " and the token."
    : "takes this rig's address, control port " +
      DEFAULT_CONTROL_PORT +
      " and the token — this machine has no address on the network yet, so read it from its " +
      "console once it is up.";
  return (
    "The token is not a login — a rig has none. It is shown once and never again: this machine " +
    "serves no page after this, so copy it now. Your Pithead's Workers → Adopt form " +
    adopt +
    " Until you adopt it the rig still mines and appears by this name in the Workers view, though " +
    "its row is badged not adopted."
  );
}
