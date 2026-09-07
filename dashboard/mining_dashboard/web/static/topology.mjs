// Stack topology (#170, trust-boundary view). A data-driven SVG of the whole stack: every component
// is a node, every connection an edge coloured by the route the server derived from live config
// (service/egress.py · compute_topology). Tor = green; clearnet = red and lands on the `internet`
// node so a leak visibly BYPASSES the Tor hub; incoming = purple; LAN = blue; unverified = amber;
// local = grey. LAN and unverified exist because a node reached at a private address is not a leak
// and a node named by hostname cannot be judged without a DNS lookup we refuse to make (#1350). The P2P daemons get a double arrow
// (egress + onion ingress). The internal host-only mesh is hidden until expanded, so the default
// view stays focused on what crosses the trust boundary. Geometry is pure (boxAnchor, logic.mjs);
// this file is presentation only — it carries no routing logic of its own (the #61 principle).

import { boxAnchor, loadPref, savePref } from "./logic.mjs";
import { Component, Fragment, html } from "./preact.mjs";

// Fixed layout — the stack is a known, fixed set of components, so positions are hand-placed
// (left→right: incoming clients, the host bridge, the Tor hub, the internet) rather than solved.
export const CLIENT_ZONE_NAME = "Clients";
export const POS = {
  rigs: { x: 12, y: 64, w: 88, h: 32 },
  browser: { x: 12, y: 150, w: 88, h: 32 },
  "xmrig-proxy": { x: 132, y: 64, w: 104, h: 32 },
  caddy: { x: 132, y: 150, w: 104, h: 32 },
  dashboard: { x: 132, y: 226, w: 104, h: 32 },
  p2pool: { x: 262, y: 64, w: 92, h: 32 },
  monerod: { x: 262, y: 150, w: 92, h: 32 },
  tari: { x: 262, y: 226, w: 92, h: 32 },
  docker: { x: 262, y: 282, w: 92, h: 26 },
  tor: { x: 392, y: 96, w: 96, h: 40 },
  internet: { x: 392, y: 220, w: 96, h: 36 },
};

// Every route the server can put on an edge needs an entry in ALL THREE of these: a colour, a
// label, and a place in ROUTES (which generates the arrowhead markers). A route missing from
// ROUTE_COLOR silently borrows local's grey, and one missing from ROUTES points marker-end at an
// id that was never defined, so its arrowhead just vanishes — both look like a working diagram.
// The server half of this contract is NODE_ROUTES in service/topology_graph.py.
export const ROUTE_COLOR = {
  tor: "var(--ok)",
  clearnet: "var(--bad)",
  incoming: "var(--purple)",
  lan: "var(--accent)",
  unknown: "var(--warn)",
  local: "var(--text-muted)",
  inactive: "var(--text-muted)",
};
export const ROUTE_NAME = {
  tor: "Tor",
  clearnet: "Clearnet",
  incoming: "Incoming",
  // "Local" is this machine; "LAN" is a hop that leaves it but stays on your network. Before
  // #1350 the two were one state and this label said "Local/LAN" — it now has to tell them apart.
  lan: "LAN",
  unknown: "Unverified",
  local: "Local",
  inactive: "Inactive",
};
export const ROUTES = ["tor", "clearnet", "incoming", "lan", "unknown", "local", "inactive"];

const center = (n) => ({ x: n.x + n.w / 2, y: n.y + n.h / 2 });
const nodeCls = (zone) =>
  zone === "tor" ? "topo-node topo-hub" : zone === "host" ? "topo-node" : "topo-node topo-ext";

// SVG path for an edge. Most edges are a straight border-to-border segment; the three that would
// otherwise cross the daemon column are routed orthogonally through a clear lane (xmrig-proxy and
// dashboard reach the Tor hub over the top / under the bottom; p2pool→tari skips monerod between
// them). Lanes: y=42 (top), y=312 (bottom), x=372 (right gutter), x=254 (left gutter).
export function edgePath(e, a, b) {
  if (e.from === "xmrig-proxy" && (e.to === "tor" || e.to === "internet")) {
    return `M${a.x + a.w / 2},${a.y} V42 H372 V${b.y + b.h / 2} H${b.x}`;
  }
  if (e.from === "dashboard" && (e.to === "tor" || e.to === "internet")) {
    return `M${a.x + a.w / 2},${a.y + a.h} V312 H372 V${b.y + b.h / 2} H${b.x}`;
  }
  if (e.from === "p2pool" && e.to === "tari") {
    return `M${a.x},${a.y + a.h / 2} H254 V${b.y + b.h / 2} H${b.x}`;
  }
  const ac = center(a);
  const bc = center(b);
  const s = boxAnchor(a, bc.x, bc.y);
  const t = boxAnchor(b, ac.x, ac.y);
  return `M${s.x},${s.y} L${t.x},${t.y}`;
}

export class StackTopology extends Component {
  constructor(props) {
    super(props);
    // Mesh visibility is a persisted preference (#658), stored as "1"/"0".
    this.state = { internal: loadPref("dashboardTopoMesh", ["1", "0"], "0") === "1" };
  }

  render({ topology }, { internal }) {
    if (!topology) return null;
    const nodes = topology.nodes.filter((n) => internal || !n.internal);
    const edges = topology.edges.filter((e) => internal || e.kind !== "internal");
    const byId = {};
    for (const n of topology.nodes) byId[n.id] = n;

    return html`
      <div class="topology">
        <div class="topo-controls">
          <span class="topo-legend"><i class="topo-sw" style="background:var(--ok)"></i>Tor</span>
          <span class="topo-legend"><i class="topo-sw" style="background:var(--bad)"></i>Clearnet</span>
          <span class="topo-legend" title="Connection into this stack; source network not classified"><i
            class="topo-sw" style="background:var(--purple)"></i>Incoming</span>
          <span class="topo-legend" title="Leaves this machine but stays on your own network"><i
            class="topo-sw" style="background:var(--accent)"></i>LAN</span>
          <span class="topo-legend" title="Configured as a name, so where it goes cannot be checked without a DNS lookup"><i
            class="topo-sw" style="background:var(--warn)"></i>Unverified</span>
          <span class="topo-legend"><i class="topo-sw" style="background:var(--text-muted)"></i>Local</span>
          <button class="topo-toggle" aria-pressed=${internal}
            title="Container-to-container links inside the stack"
            onClick=${() => {
              savePref("dashboardTopoMesh", internal ? "0" : "1");
              this.setState({ internal: !internal });
            }}>
            ${internal ? "Hide internal mesh" : "Show internal mesh"}
          </button>
        </div>
        <svg viewBox="0 0 500 322" class="topo-svg" role="img"
             aria-label="Stack network topology: each component and its connections, coloured green for Tor, red for clearnet, purple for incoming, blue for your own LAN, and amber where the route could not be verified.">
          <defs>
            ${ROUTES.map(
              (r) => html`
                <marker id=${"topo-a-" + r} markerWidth="7" markerHeight="7" refX="6" refY="3" orient="auto">
                  <path d="M0,0 L6,3 L0,6 Z" fill=${ROUTE_COLOR[r]} />
                </marker>
                <marker id=${"topo-s-" + r} markerWidth="7" markerHeight="7" refX="1" refY="3" orient="auto">
                  <path d="M6,0 L0,3 L6,6 Z" fill=${ROUTE_COLOR[r]} />
                </marker>`,
            )}
          </defs>
          <text x="56" y="20" class="topo-zone">${CLIENT_ZONE_NAME}</text>
          <text x="243" y="20" class="topo-zone">host — mining_net bridge</text>
          <text x="440" y="20" class="topo-zone">Tor → internet</text>
          ${edges.map((e) => this._edge(e, byId)).filter(Boolean)}
          ${nodes.map((n) => {
            const p = POS[n.id];
            if (!p) return null;
            // #1040: monerod and tari are the only nodes an operator can run elsewhere, so only
            // they carry `remote` and only they get a location caption. It rides as a SIBLING of
            // the node group, not a child: `.topo-node text` outranks `.topo-zone`, so a caption
            // inside the group would silently render as a second full-size label.
            const loc = n.remote === true ? "remote" : n.remote === false ? "local" : null;
            const cx = p.x + p.w / 2;
            return html`
              <${Fragment}>
                <g class=${nodeCls(n.zone)}>
                  <rect x=${p.x} y=${p.y} width=${p.w} height=${p.h} rx="6" />
                  <text x=${cx} y=${loc ? p.y + 14 : p.y + p.h / 2 + 4} text-anchor="middle">${n.label}</text>
                </g>
                ${loc && html`<text x=${cx} y=${p.y + 26} class="topo-zone">${loc}</text>`}
              <//>`;
          })}
        </svg>
      </div>`;
  }

  _edge(e, byId) {
    const a = POS[e.from];
    const b = POS[e.to];
    if (!a || !b) return null;
    const key = e.leak ? "clearnet" : e.route;
    const color = ROUTE_COLOR[key] || ROUTE_COLOR.local;
    const dash = e.kind === "internal" ? "3 3" : e.blocked_by_firewall ? "2 3" : null;
    // Marching ants (dashboard.css .topo-edge-ants) mark active Tor, clearnet, incoming, LAN and
    // unverified links against the static grey local/inactive edges. Skipped whenever a dash
    // pattern is already spoken for (internal mesh,
    // firewall-blocked) so it can't collide.
    const ants = !dash && key !== "local" && key !== "inactive";
    const note = e.leak ? " — LEAK" : e.blocked_by_firewall ? " — firewall-blocked" : "";
    const from = byId[e.from]?.label || e.from;
    const to = byId[e.to]?.label || e.to;
    const tip = `${from} → ${to}: ${e.label} · ${ROUTE_NAME[key] || key}${note}`;
    return html`
      <path d=${edgePath(e, a, b)} fill="none" class=${ants ? "topo-edge-ants" : null}
            stroke=${color} stroke-width=${e.kind === "internal" ? 1 : 1.8}
            stroke-dasharray=${dash} opacity=${e.route === "inactive" ? 0.4 : 1}
            marker-end=${"url(#topo-a-" + key + ")"}
            marker-start=${e.kind === "p2p" ? "url(#topo-s-" + key + ")" : null}>
        <title>${tip}</title>
      </path>`;
  }
}
