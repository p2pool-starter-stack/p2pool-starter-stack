// The shared stat-card primitives every dashboard card is built from: one stat cell, the
// progressive-disclosure wrapper that splits a busy card into headline + detail, and the Tari
// merge-mine status line. Split out of components.mjs (#1040) because that file sits at its
// file-budget ceiling and these three are the pieces with no dependency back on it — the import
// runs one way, leaf to hub, like chart.mjs and topology.mjs already do.

import { loadPref, savePref } from "./logic.mjs";
import { Component, html } from "./preact.mjs";

export const StatCard = ({ label, value, cls, span, title }) => html`
    <div class=${"stat-card" + (span ? " col-span-2" : "")} title=${title || ""}>
        <h5>${label}</h5>
        <p class=${cls || ""}>${value}</p>
    </div>`;

// Progressive disclosure for a busy stat-grid card ("show more" pattern). A card splits its
// StatCards into `headline` (always visible — the figures an operator actually glances at) and
// `detail` (behind the toggle, collapsed by default); both share one `stat-grid` so the layout is
// identical to the old flat list once expanded. Expansion is persisted per card via
// loadPref/savePref — the same helpers dashboardEarningsTab already uses — keyed on `prefKey` so
// each card remembers its own state independently across a reload. The toggle is a real <button>
// with aria-expanded (not <details>/<summary>): that keeps the expanded/collapsed state explicit
// for assistive tech and gives the label control ("Show all (N)") the native disclosure triangle
// doesn't.
const EXPAND_STATES = ["expanded", "collapsed"];
export class MoreStats extends Component {
  constructor(props) {
    super(props);
    this.state = { expanded: loadPref(props.prefKey, EXPAND_STATES, "collapsed") === "expanded" };
    this.toggle = () => {
      const expanded = !this.state.expanded;
      savePref(this.props.prefKey, expanded ? "expanded" : "collapsed");
      this.setState({ expanded });
    };
  }

  render() {
    const { headline, detail, count } = this.props;
    const { expanded } = this.state;
    return html`
        <div class="stat-grid">
            ${headline}
            ${expanded ? detail : null}
        </div>
        <button type="button" class="more-stats-toggle" aria-expanded=${expanded ? "true" : "false"}
                onClick=${this.toggle}>
            ${expanded ? "Show less ▴" : `Show all (${count}) ▾`}
        </button>`;
  }
}

// Tari merge-mine status. The ✔ means the gRPC channel is actually up, so it's gated on `connected`
// (channel_state READY) — NOT on `active` (a chain is merely configured). When configured but the
// channel is down (e.g. TRANSIENT_FAILURE) we show the raw state in a warn style and no ✔, so a dead
// channel can never read as "TRANSIENT_FAILURE ✔".
export const TariStatus = ({ tari }) => html`
    <p class=${tari.connected ? "status-ok" : tari.active ? "status-warn" : ""}>
        ${tari.status}${tari.connected ? html` <span class="check-inline">✔</span>` : null}
    </p>`;

// Local vs remote for the two nodes an operator can run somewhere else (#1040). A remote node's
// health is not theirs to fix, which is the whole reason a card has to say which it is. An absent
// flag is a payload from before this shipped, NOT a location, so it reads as unknown rather than
// quietly claiming "Local" — the one answer that would send someone to the wrong machine.
export const nodeLocation = (local) =>
  local === true ? "Local" : local === false ? "Remote" : "—";
