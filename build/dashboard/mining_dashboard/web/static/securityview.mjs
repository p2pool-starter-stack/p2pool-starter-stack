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

// Pagination (#823 follow-up): the grouping dropdown became a page-size control — with range
// presets, date jumps and search doing the time navigation, bucketed grouping answered a
// strictly weaker question. Paging is CLIENT-side over the (server-filtered, bounded) result
// set; pageFor clamps so a shrinking result set never strands the view on a page past the end.
export const PAGE_SIZES = [5, 10, 20, 50, 100];

export function pageFor(entries, page, size) {
  const total = entries.length;
  const pages = Math.max(1, Math.ceil(total / size));
  const p = Math.min(Math.max(0, page), pages - 1);
  return { slice: entries.slice(p * size, (p + 1) * size), page: p, pages, total };
}

const Pager = ({ label, total, page, pages, size, onPage, onSize }) => html`<div class="log-pager">
    <span class="text-muted text-xs">${total} entr${total === 1 ? "y" : "ies"}${pages > 1 ? html` · page ${page + 1} of ${pages}` : ""}</span>
    <select aria-label=${label + ": rows per page"} value=${String(size)}
            onChange=${(e) => onSize(Number(e.target.value))}>
        ${PAGE_SIZES.map((n) => html`<option value=${String(n)}>${n} rows</option>`)}
    </select>
    <button type="button" class="btn-range" disabled=${page <= 0} aria-label=${label + ": previous page"}
            onClick=${() => onPage(page - 1)}>‹ Prev</button>
    <button type="button" class="btn-range" disabled=${page >= pages - 1} aria-label=${label + ": next page"}
            onClick=${() => onPage(page + 1)}>Next ›</button>
</div>`;

// Epoch seconds -> local "YYYY-MM-DD HH:MM:SS"-style string; blank for a missing/zero ts.
export function fmtEpoch(ts) {
  if (!Number.isFinite(ts) || ts <= 0) return "";
  return new Date(ts * 1000).toLocaleString();
}

const AccessCard = ({ access, filters, onFilters, pager, onPager }) => {
  if (!access) return null;
  if (!access.available) {
    return html`<div class="card">
        <h3>Access log</h3>
        <p class="text-muted">No access log yet — Caddy writes it from the first request after
        an <code>apply</code>/<code>upgrade</code> on this version.</p>
    </div>`;
  }
  const failures = access.failures_24h || 0;
  const pg = pageFor(access.entries || [], pager.page, pager.size);
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
        pg.total === 0
          ? html`<p class="text-muted">${
              isFiltering(filters) ? "No entries match this filter." : "No requests logged yet."
            }</p>`
          : html`<div>
          <${Pager} label="Access log" total=${pg.total} page=${pg.page} pages=${pg.pages}
                    size=${pager.size} onPage=${(page) => onPager({ ...pager, page })}
                    onSize=${(size) => onPager({ size, page: 0 })} />
          <div class="table-scroll">
          <table>
              <thead><tr><th>Time</th><th>Status</th><th>Method</th><th>Path</th><th>User</th></tr></thead>
              <tbody>
                  ${pg.slice.map(
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

const AuditCard = ({ audit, filters, onFilters, pager, onPager }) => {
  // null = control channel off (the /api/audit route 404s) — no card at all.
  if (!audit) return null;
  const pg = pageFor(audit, pager.page, pager.size);
  return html`<div class="card">
      <h3>Recent config changes</h3>
      <${LogControls} label="Config-change filter" filters=${filters} onChange=${onFilters} />
      ${
        pg.total === 0
          ? html`<p class="text-muted">${
              isFiltering(filters)
                ? "No entries match this filter."
                : "No config changes have gone through the dashboard yet."
            }</p>`
          : html`<div>
              <${Pager} label="Config changes" total=${pg.total} page=${pg.page} pages=${pg.pages}
                        size=${pager.size} onPage=${(page) => onPager({ ...pager, page })}
                        onSize=${(size) => onPager({ size, page: 0 })} />
              <div class="table-scroll">
              <table>
                  <thead><tr><th>Time (UTC)</th><th>User</th><th>Action</th><th>Outcome</th><th>Settings</th></tr></thead>
                  <tbody>
                      ${pg.slice.map(AuditRow)}
                  </tbody>
              </table>
              </div>
          </div>`
      }
  </div>`;
};

export class SecurityPanel extends Component {
  constructor(props) {
    super(props);
    // Each card carries its own #823 filter state — following the access log and pinning down
    // one config change are different investigations — plus its own pager (page resets to 0
    // whenever the filter changes; a new question starts at its first page).
    this.state = {
      access: null,
      audit: null,
      accessFilters: { ...EMPTY_FILTERS },
      auditFilters: { ...EMPTY_FILTERS },
      accessPager: { page: 0, size: 20 },
      auditPager: { page: 0, size: 20 },
      error: null,
    };
    // Search keystrokes debounce (300 ms) so each letter doesn't hit the endpoint; preset and
    // date changes apply immediately — they are single deliberate clicks.
    this.setAccessFilters = (f) => this.applyFilters("access", "accessFilters", f);
    this.setAuditFilters = (f) => this.applyFilters("audit", "auditFilters", f);
    this.setAccessPager = (pager) => this.setState({ accessPager: pager });
    this.setAuditPager = (pager) => this.setState({ auditPager: pager });
  }

  applyFilters(which, key, filters) {
    const prev = this.state[key];
    const pagerKey = which === "access" ? "accessPager" : "auditPager";
    this.setState({ [key]: filters, [pagerKey]: { ...this.state[pagerKey], page: 0 } });
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
    const { access, audit, accessFilters, auditFilters, accessPager, auditPager, error } =
      this.state;
    if (error) return html`<div class="card"><p class="status-bad">${error}</p></div>`;
    return html`<div class="grid">
        <${AccessCard} access=${access} filters=${accessFilters} onFilters=${this.setAccessFilters}
                       pager=${accessPager} onPager=${this.setAccessPager} />
        <${AuditCard} audit=${audit} filters=${auditFilters} onFilters=${this.setAuditFilters}
                      pager=${auditPager} onPager=${this.setAuditPager} />
    </div>`;
  }
}
