// Security panel (#349): recent dashboard accesses (Caddy's access log, read-only) and the
// config-change audit trail (the #33 host-side audit log, read-only, plus the #530 out-of-band
// host-edit/rig-edit detections and their persisted history). Both APIs serve server-sanitized
// fields — the backend whitelists every character before it leaves the host logs — and everything
// here renders through Preact text nodes, never markup, so a hostile log line stays inert even if
// the server-side filter regressed.
//
// The operator story: over Tor there is no source IP, so the attack signal is the RATE of 401s.
// A burst of failed logins shows a rotate nudge — change the password, or mint a fresh onion
// with `./pithead rotate-dashboard-onion`.

import { Component, html } from "./preact.mjs";

const ACCESS_LIMIT_SHOWN = 20;

// Audit entries share one ts format across every source (control.log's own writer and the #530
// watchers both emit "YYYY-MM-DDTHH:MM:SSZ", see data_service._iso_now), so a bucket key is a
// plain string slice — no date parsing, no timezone math.
export function bucketKey(ts, granularity) {
  if (typeof ts !== "string") return "";
  if (granularity === "hour") return ts.slice(0, 13);
  if (granularity === "month") return ts.slice(0, 7);
  return ts.slice(0, 10); // "day"
}

// Group already newest-first ``entries`` into contiguous {bucket, entries} runs for
// ``granularity`` ("hour"|"day"|"month"), or one ungrouped run for "flat"/anything else — the
// drill: pick "month" to scan a year at a glance, "hour" to pin down one incident.
export function groupAuditEntries(entries, granularity) {
  if (granularity !== "hour" && granularity !== "day" && granularity !== "month") {
    return [{ bucket: null, entries }];
  }
  const groups = [];
  let current = null;
  for (const e of entries) {
    const key = bucketKey(e.ts, granularity);
    if (!current || current.bucket !== key) {
      current = { bucket: key, entries: [] };
      groups.push(current);
    }
    current.entries.push(e);
  }
  return groups;
}

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

// Outcome values a "detected" (never applied/rejected) out-of-band row never has, so it keeps its
// own neutral styling instead of picking up the "applied" green.
const AuditRow = (e) => html`<tr>
    <td>${e.ts}</td>
    <td>${e.actor}</td>
    <td>${e.action}</td>
    <td class=${e.status === "applied" ? "status-ok" : ""}>${e.status}</td>
    <td class="font-mono">${e.keys}</td>
</tr>`;

const AuditCard = ({ audit, group, onGroupChange }) => {
  // null = control channel off (the /api/audit route 404s) — no card at all.
  if (!audit) return null;
  return html`<div class="card">
      <div class="card-header-row">
          <h3>Recent config changes</h3>
          ${
            audit.length > 0
              ? html`<select value=${group} onChange=${(e) => onGroupChange(e.target.value)}>
                  <option value="flat">All (newest first)</option>
                  <option value="hour">Group by hour</option>
                  <option value="day">Group by day</option>
                  <option value="month">Group by month</option>
              </select>`
              : null
          }
      </div>
      ${
        audit.length === 0
          ? html`<p class="text-muted">No config changes have gone through the dashboard yet.</p>`
          : html`<div class="table-scroll">
              <table>
                  <thead><tr><th>Time (UTC)</th><th>User</th><th>Action</th><th>Outcome</th><th>Settings</th></tr></thead>
                  <tbody>
                      ${groupAuditEntries(audit, group).flatMap((g) => [
                        g.bucket !== null
                          ? html`<tr class="audit-group-header">
                              <td colspan="5">${g.bucket} (${g.entries.length})</td>
                          </tr>`
                          : null,
                        ...g.entries.map(AuditRow),
                      ])}
                  </tbody>
              </table>
          </div>`
      }
  </div>`;
};

export class SecurityPanel extends Component {
  constructor(props) {
    super(props);
    // auditGroup: "flat" (today's plain newest-first list) is the default so existing behavior
    // doesn't change until the operator opts into grouping (#530).
    this.state = { access: null, audit: null, auditGroup: "flat", error: null };
    this.setAuditGroup = (group) => this.setState({ auditGroup: group });
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
    const { access, audit, auditGroup, error } = this.state;
    if (error) return html`<div class="card"><p class="status-bad">${error}</p></div>`;
    return html`<div class="grid">
        <${AccessCard} access=${access} />
        <${AuditCard} audit=${audit} group=${auditGroup} onGroupChange=${this.setAuditGroup} />
    </div>`;
  }
}
