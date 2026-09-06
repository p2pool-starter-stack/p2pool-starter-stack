// The dashboard's Tor way in, rendered under the header's hostname/IP line (#1853).
//
// The server decides whether there IS one: state.dashboard_onion is {url, client_auth} only when
// the onion is both enabled and provisioned (mining_dashboard/web/header.py). This file renders
// what it is handed and infers nothing — no onion means no block at all, not an empty row, which
// is the difference between "Tor is off" and "Tor is broken".
//
// WHERE THIS RENDERS TODAY: the Compose stack, which passes DASHBOARD_ONION_ENABLED, _ADDRESS and
// _CLIENT_AUTH into the dashboard container (docker-compose.yml). The appliance runs podman
// quadlets, and its dashboard unit is written with none of the three
// (lib/pithead/36-quadlet-units.sh), so there the server sends no onion and this block is absent.
// That gap is #1896 — until it lands, no prose here promises an appliance operator this surface.
//
// The URL is never elided. A v3 onion address is 56 characters of base32 with no redundancy, so a
// tidy-looking truncation produces a string that does not open — and the whole product here is
// that someone can copy it to a phone instead of reading it off a terminal.
//
// Reuses .brand-host (the host line's own size, spacing and overflow-wrap: anywhere), .text-muted,
// and the generic .btn-range control paired with .btn-reset, which is what supplies the 8px before
// the button (dashboard.css) — no header-only CSS is introduced.

import { Component, html } from "./preact.mjs";

// How long the copy confirmation stays up. It has to come down: the confirmation lives in a live
// region, and a live region announces a CHANGE to its content. A control that reads "Copied" from
// the first copy onwards announces once per page load and is silent for every copy after it.
export const CLEAR_MS = 4000;

// Copy `text`, answering true only if the clipboard actually took it. The clipboard is passed in
// rather than reached for: it is absent in the test renderer, and undefined on any page not
// served in a secure context — where the button has to degrade to "select it by hand" instead of
// throwing. A false answer leaves the label alone, so the operator is never told it copied when
// nothing reached the clipboard.
export async function copyText(text, clipboard) {
  try {
    if (!clipboard || typeof clipboard.writeText !== "function") return false;
    await clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export class OnionUrl extends Component {
  constructor(props) {
    super(props);
    this.state = { copied: false };
    this.clearTimer = null;
  }

  componentWillUnmount() {
    clearTimeout(this.clearTimer);
  }

  async copy() {
    const ok = await copyText(this.props.onion.url, globalThis.navigator?.clipboard);
    // A copy that failed takes the standing confirmation down with it rather than leaving the
    // previous one to read as this one's answer.
    clearTimeout(this.clearTimer);
    this.setState({ copied: ok });
    if (ok) this.clearTimer = setTimeout(() => this.setState({ copied: false }), CLEAR_MS);
  }

  render({ onion }, { copied }) {
    if (!onion) return null;
    // The button's accessible name IS its text, so the confirmation cannot live in the label: one
    // copy would rename the control "Copied" — a state, not the action a returning reader needs.
    // It goes in a sibling status region instead, which is rendered EMPTY rather than conditionally,
    // because a live region inserted with its message already in it has no change to announce.
    return html`
      <div class="brand-host text-muted">
        <span class="font-mono">${onion.url}</span>
        <button type="button" class="btn-range btn-reset" onClick=${() => this.copy()}>
          Copy address
        </button>
        ${" "}
        <span role="status">${copied ? "Copied" : ""}</span>
        ${
          // Client authorisation on means the URL alone does not open — Tor Browser answers with
          // a generic failure that reads as "the onion is down". Saying so here is the whole
          // point; the key itself is host-side and never reaches this container.
          //
          // The ${" "} before the <span> is load-bearing and the repo has 13 other sites of it:
          // htm strips a whitespace run CONTAINING A NEWLINE from both ends of every static text
          // chunk, so a line break before a tag deletes the space and the words run together. A
          // field is pushed as its own child and never goes through that regex.
          onion.client_auth
            ? html`<div>
                Client authorisation is on — this address only opens for a browser holding your
                client key. On a machine you can log in to,${" "}
                <span class="font-mono">pithead onion-client-key</span> prints it.
              </div>`
            : null
        }
      </div>
    `;
  }
}
