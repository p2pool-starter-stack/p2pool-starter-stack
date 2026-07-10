// Security panel (#349): recent dashboard accesses (Caddy's access log, read-only) and the
// config-change audit trail (the #33 host-side audit log, read-only). Both APIs serve
// server-sanitized fields — the backend whitelists every character before it leaves the host
// logs — and everything here renders through Preact text nodes, never markup, so a hostile log
// line stays inert even if the server-side filter regressed.
//
// The operator story: over Tor there is no source IP, so the attack signal is the RATE of 401s.
// A burst of failed logins shows a rotate nudge — change the password, or mint a fresh onion
// with `./pithead rotate-dashboard-onion`.

import { Component, html } from "./preact.mjs";

const ACCESS_LIMIT_SHOWN = 20;

// Epoch seconds -> local "YYYY-MM-DD HH:MM:SS"-style string; blank for a missing/zero ts.
export function fmtEpoch(ts) {
  if (!Number.isFinite(ts) || ts <= 0) return "";
  return new Date(ts * 1000).toLocaleString();
}

const AccessCard = ({ access }) => {
  if (!access) return null;
  if (!access.available) {
    return html`<div class="card">
        <h3>Access log</h3>
        <p class="text-muted">No access log yet — Caddy writes it from the first request after
        an <code>apply</code>/<code>upgrade</code> on this version.</p>
    </div>`;
  }
  const failures = access.failures_24h || 0;
  return html`<div class="card">
      <h3>Access log</h3>
      <p class=${failures > 0 ? "status-warn" : "status-ok"}>
          ${failures} failed login${failures === 1 ? "" : "s"} in the last 24 h${
            access.last_failure_ts ? html` — last at ${fmtEpoch(access.last_failure_ts)}` : ""
          }
      </p>
      ${
        access.rotate_hint
          ? html`<p class="status-bad">Repeated failed logins — someone who can reach the
              dashboard is guessing the password. Rotate it (set a new
              <code>dashboard.auth.password</code> and run <code>./pithead apply</code>) and, if
              the onion address may have leaked, run
              <code>./pithead rotate-dashboard-onion</code>.</p>`
          : null
      }
      <div class="table-scroll">
          <table>
              <thead><tr><th>Time</th><th>Status</th><th>Method</th><th>Path</th><th>User</th></tr></thead>
              <tbody>
                  ${(access.entries || []).slice(0, ACCESS_LIMIT_SHOWN).map(
                    (e) => html`<tr>
                        <td>${fmtEpoch(e.ts)}</td>
                        <td class=${e.status === 401 ? "status-bad" : ""}>${e.status || "?"}</td>
                        <td>${e.method}</td>
                        <td class="font-mono">${e.uri}</td>
                        <td>${e.user}</td>
                    </tr>`,
                  )}
              </tbody>
          </table>
      </div>
  </div>`;
};

const AuditCard = ({ audit }) => {
  // null = control channel off (the /api/audit route 404s) — no card at all.
  if (!audit) return null;
  return html`<div class="card">
      <h3>Recent config changes</h3>
      ${
        audit.length === 0
          ? html`<p class="text-muted">No config changes have gone through the dashboard yet.</p>`
          : html`<div class="table-scroll">
              <table>
                  <thead><tr><th>Time (UTC)</th><th>User</th><th>Action</th><th>Outcome</th><th>Settings</th></tr></thead>
                  <tbody>
                      ${audit.map(
                        (e) => html`<tr>
                            <td>${e.ts}</td>
                            <td>${e.actor}</td>
                            <td>${e.action}</td>
                            <td class=${e.status === "applied" ? "status-ok" : ""}>${e.status}</td>
                            <td class="font-mono">${e.keys}</td>
                        </tr>`,
                      )}
                  </tbody>
              </table>
          </div>`
      }
  </div>`;
};

export class SecurityPanel extends Component {
  constructor(props) {
    super(props);
    this.state = { access: null, audit: null, error: null };
  }

  async componentDidMount() {
    try {
      const res = await fetch("/api/access");
      if (res.ok) this.setState({ access: await res.json() });
      // /api/audit exists only when the control channel is on; a 404 just hides the card.
      const auditRes = await fetch("/api/audit");
      if (auditRes.ok) this.setState({ audit: (await auditRes.json()).entries || [] });
    } catch (e) {
      this.setState({ error: String(e) });
    }
  }

  render() {
    const { access, audit, error } = this.state;
    if (error) return html`<div class="card"><p class="status-bad">${error}</p></div>`;
    return html`<div class="grid">
        <${AccessCard} access=${access} />
        <${AuditCard} audit=${audit} />
    </div>`;
  }
}
