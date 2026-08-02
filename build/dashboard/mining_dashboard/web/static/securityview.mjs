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

// --- Log navigation (#823) -------------------------------------------------------------
//
// Both cards share one control row: the chart's preset idiom (24 Hr / 1 Wk / 1 Mo / All) for
// "following" a live log, two native date inputs for jumping to a specific time, and a search
// box. Filtering is SERVER-side (?from&to&q on /api/access and /api/audit) so a match outside
// the glance tail is still found; the server owns sanitation, this file only builds the query.

export const LOG_PRESETS = [
  { id: "24h", label: "24 Hr", secs: 86_400 },
  { id: "7d", label: "1 Wk", secs: 7 * 86_400 },
  { id: "30d", label: "1 Mo", secs: 30 * 86_400 },
  { id: "all", label: "All", secs: null },
];

// UI filter state -> the endpoint query string. Preset and explicit dates are mutually
// exclusive (the controls clear one when the other is picked); an explicit "to" date means
// "through that whole day", so it maps to the NEXT midnight as the half-open upper bound.
// Date inputs parse as UTC midnight (the audit trail is displayed in UTC) — close enough for
// day-granularity jumps either way, and stable across viewer timezones.
export function buildLogQuery({ preset = "all", fromDate = "", toDate = "", q = "" } = {}, now) {
  const p = new URLSearchParams();
  const nowSec = now !== undefined ? now : Date.now() / 1000;
  const chosen = LOG_PRESETS.find((x) => x.id === preset);
  if (fromDate || toDate) {
    const from = Date.parse(fromDate) / 1000;
    const to = Date.parse(toDate) / 1000;
    if (Number.isFinite(from)) p.set("from", String(from));
    if (Number.isFinite(to)) p.set("to", String(to + 86_400));
  } else if (chosen && chosen.secs !== null) {
    p.set("from", String(nowSec - chosen.secs));
  }
  const qq = q.trim();
  if (qq) p.set("q", qq);
  const s = p.toString();
  return s ? `?${s}` : "";
}

const LogControls = ({ label, filters, onChange }) => {
  const set = (patch) => onChange({ ...filters, ...patch });
  return html`<div class="chart-controls log-controls" role="group" aria-label=${label}>
      ${LOG_PRESETS.map(
        (p) => html`<button type="button"
            class=${"btn-range" + (filters.preset === p.id && !filters.fromDate && !filters.toDate ? " active" : "")}
            aria-pressed=${filters.preset === p.id && !filters.fromDate && !filters.toDate}
            title=${"Show the last " + p.label}
            onClick=${() => set({ preset: p.id, fromDate: "", toDate: "" })}>${p.label}</button>`,
      )}
      <input type="date" aria-label=${label + ": from date"} value=${filters.fromDate}
             onChange=${(e) => set({ fromDate: e.target.value })} />
      <span class="text-muted">–</span>
      <input type="date" aria-label=${label + ": to date"} value=${filters.toDate}
             onChange=${(e) => set({ toDate: e.target.value })} />
      <input type="search" class="log-search" placeholder="Search…" aria-label=${label + ": search"}
             value=${filters.q} onInput=${(e) => set({ q: e.target.value })} />
  </div>`;
};

const EMPTY_FILTERS = { preset: "all", fromDate: "", toDate: "", q: "" };
const isFiltering = (f) => f.preset !== "all" || !!f.fromDate || !!f.toDate || !!f.q.trim();

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

const AccessCard = ({ access, filters, onFilters }) => {
  if (!access) return null;
  if (!access.available) {
    return html`<div class="card">
        <h3>Access log</h3>
        <p class="text-muted">No access log yet — Caddy writes it from the first request after
        an <code>apply</code>/<code>upgrade</code> on this version.</p>
    </div>`;
  }
  const failures = access.failures_24h || 0;
  // A filtered view shows every match the server returned (its read is already bounded); only
  // the unfiltered glance keeps the short tail so the card stays a glance.
  const shown = isFiltering(filters)
    ? access.entries || []
    : (access.entries || []).slice(0, ACCESS_LIMIT_SHOWN);
  return html`<div class="card">
      <h3>Access log</h3>
      <${LogControls} label="Access log filter" filters=${filters} onChange=${onFilters} />
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
      ${
        shown.length === 0 && isFiltering(filters)
          ? html`<p class="text-muted">No entries match this filter.</p>`
          : html`<div class="table-scroll">
          <table>
              <thead><tr><th>Time</th><th>Status</th><th>Method</th><th>Path</th><th>User</th></tr></thead>
              <tbody>
                  ${shown.map(
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
      </div>`
      }
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

const AuditCard = ({ audit, group, onGroupChange, filters, onFilters }) => {
  // null = control channel off (the /api/audit route 404s) — no card at all.
  if (!audit) return null;
  return html`<div class="card">
      <div class="card-header-row">
          <h3>Recent config changes</h3>
          ${
            audit.length > 0 || isFiltering(filters)
              ? html`<select aria-label="Group audit trail by" value=${group} onChange=${(e) => onGroupChange(e.target.value)}>
                  <option value="flat">All (newest first)</option>
                  <option value="hour">Group by hour</option>
                  <option value="day">Group by day</option>
                  <option value="month">Group by month</option>
              </select>`
              : null
          }
      </div>
      <${LogControls} label="Config-change filter" filters=${filters} onChange=${onFilters} />
      ${
        audit.length === 0
          ? html`<p class="text-muted">${
              isFiltering(filters)
                ? "No entries match this filter."
                : "No config changes have gone through the dashboard yet."
            }</p>`
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
    // doesn't change until the operator opts into grouping (#530). Each card carries its own
    // #823 filter state — following the access log and pinning down one config change are
    // different investigations.
    this.state = {
      access: null,
      audit: null,
      auditGroup: "flat",
      accessFilters: { ...EMPTY_FILTERS },
      auditFilters: { ...EMPTY_FILTERS },
      error: null,
    };
    this.setAuditGroup = (group) => this.setState({ auditGroup: group });
    // Search keystrokes debounce (300 ms) so each letter doesn't hit the endpoint; preset and
    // date changes apply immediately — they are single deliberate clicks.
    this.setAccessFilters = (f) => this.applyFilters("access", "accessFilters", f);
    this.setAuditFilters = (f) => this.applyFilters("audit", "auditFilters", f);
  }

  applyFilters(which, key, filters) {
    const prev = this.state[key];
    this.setState({ [key]: filters });
    clearTimeout(this._debounce?.[which]);
    const run = () => this.refetch(which, filters);
    if (filters.q !== prev.q) {
      this._debounce = { ...this._debounce, [which]: setTimeout(run, 300) };
    } else {
      run();
    }
  }

  async refetch(which, filters) {
    // Sequence guard: two quick filter changes can land responses out of order — only the
    // NEWEST request for a surface may write state, or a slow stale response would overwrite
    // the fresher view the operator is already looking at.
    if (!this._seq) this._seq = {};
    this._seq[which] = (this._seq[which] || 0) + 1;
    const seq = this._seq;
    const mine = seq[which];
    try {
      const qs = buildLogQuery(filters);
      if (which === "access") {
        const res = await fetch("/api/access" + qs);
        if (res.ok && seq[which] === mine) this.setState({ access: await res.json() });
      } else {
        const res = await fetch("/api/audit" + qs);
        if (res.ok && seq[which] === mine)
          this.setState({ audit: (await res.json()).entries || [] });
      }
    } catch (e) {
      if (seq[which] === mine) this.setState({ error: String(e) });
    }
  }

  componentWillUnmount() {
    // A pending search debounce firing after unmount would setState on a dead component.
    for (const t of Object.values(this._debounce || {})) clearTimeout(t);
    this._debounce = {};
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
    const { access, audit, auditGroup, accessFilters, auditFilters, error } = this.state;
    if (error) return html`<div class="card"><p class="status-bad">${error}</p></div>`;
    return html`<div class="grid">
        <${AccessCard} access=${access} filters=${accessFilters} onFilters=${this.setAccessFilters} />
        <${AuditCard} audit=${audit} group=${auditGroup} onGroupChange=${this.setAuditGroup}
                      filters=${auditFilters} onFilters=${this.setAuditFilters} />
    </div>`;
  }
}
