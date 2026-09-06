// The dashboard's Tor way in, rendered under the header's hostname/IP line (#1853).
//
// The server decides whether there IS one: state.dashboard_onion is {url, client_auth} only when
// the onion is both enabled and provisioned (mining_dashboard/web/header.py). This file renders
// what it is handed and infers nothing — no onion means no block at all, not an empty row, which
// on the appliance is the difference between "Tor is off" and "Tor is broken".
//
// The URL is never elided. A v3 onion address is 56 characters of base32 with no redundancy, so a
// tidy-looking truncation produces a string that does not open — and the whole product here is
// that someone can copy it to a phone, which is the only way in on a machine with no shell.
//
// Reuses .brand-host (the host line's own size, spacing and overflow-wrap: anywhere) and the
// generic .btn-range control rather than introducing header-only CSS.

import { Component, html } from "./preact.mjs";

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
  }

  async copy() {
    const ok = await copyText(this.props.onion.url, globalThis.navigator?.clipboard);
    this.setState({ copied: ok });
  }

  render({ onion }, { copied }) {
    if (!onion) return null;
    return html`
      <div class="brand-host text-muted">
        <span class="font-mono">${onion.url}</span>
        <button type="button" class="btn-range btn-reset" onClick=${() => this.copy()}>
          ${copied ? "Copied" : "Copy"}
        </button>
        ${
          // Client authorisation on means the URL alone does not open — Tor Browser answers with
          // a generic failure that reads as "the onion is down". Saying so here is the whole
          // point; the key itself is host-side and never reaches this container.
          onion.client_auth
            ? html`<div>
                Client authorisation is on — this address only opens for a browser holding your
                client key. Get the key with
                <span class="font-mono">pithead onion-client-key</span> on the machine.
              </div>`
            : null
        }
      </div>
    `;
  }
}
