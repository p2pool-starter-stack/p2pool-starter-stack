// Pure, dependency-free client logic — no Preact, no DOM, no Chart.js. Kept separate so it can
// be unit-tested with Node's built-in runner (`node --test`; see tests/frontend/logic.test.mjs)
// without a browser or a JS toolchain. Presentation (components, the canvas) stays elsewhere and
// is covered by the browser smoke test.

// Worker table columns, each carrying the state key it sorts on. Hashrate/uptime/IP and the
// accepted/rejected share counts sort numerically (raw values the server includes alongside the
// formatted strings); name sorts as text. The order matches the rendered <th>s.
export const WORKER_COLUMNS = [
  { label: "Worker", key: "name" },
  { label: "IP", key: "ip_sort" },
  { label: "Uptime", key: "uptime" },
  { label: "10s", key: "h10" },
  { label: "60s", key: "h60" },
  { label: "15m", key: "h15" },
  { label: "Accepted", key: "accepted" },
  { label: "Rejected", key: "rejected" },
];

// Return a new array of workers sorted by the given column index. ``idx == null`` keeps the
// server's order (online first, then name). Numeric columns compare numerically (so 1000 sorts
// after 9, not before it); everything else compares as a locale string. Never mutates input.
export function sortWorkers(workers, idx, asc) {
  if (idx === null || idx === undefined) return workers;
  const key = WORKER_COLUMNS[idx].key;
  const sorted = [...workers].sort((a, b) => {
    const va = a[key],
      vb = b[key];
    if (typeof va === "number" && typeof vb === "number") return va - vb;
    return String(va).localeCompare(String(vb));
  });
  return asc ? sorted : sorted.reverse();
}

// Hero KPI band (Issue #81). The headline numbers surfaced as a prominent top strip: each entry
// is { label, value, cls } where `value` is an already-formatted display string from build_state
// and `cls` is the text-colour class applied to it ('' = default text colour). Pure selection +
// labelling is kept here so the wiring (which state field feeds which KPI, and the mode/shares
// colouring) is unit-tested; <HeroBand> in components.mjs only renders the returned list.
// Tri-state colour for the Raffle Eligible indicator (#158): muted '' when XvB is off (N/A — no
// raffle to be eligible for), green when fully eligible (donor tier on credited 1h+24h AND a PPLNS
// share), red otherwise. Kept here (not inline) so both the Hero KPI and the Simple card share it.
export function raffleCls(raffle) {
  if (!raffle || !raffle.applies) return "";
  return raffle.eligible ? "status-ok" : "status-bad";
}

export function heroKpis(state) {
  const hr = state.hashrate,
    sw = state.shares_window,
    p = state.pool,
    raffle = state.raffle_eligible || {};
  return [
    { label: "Total Hashrate", value: hr.total, cls: "text-accent" },
    { label: "Shares in Window", value: sw.count, cls: sw.ok ? "status-ok" : "status-bad" },
    // Raffle Eligible (#158): Yes only when you'd WIN and COLLECT — in a donor tier AND holding a
    // PPLNS share. Muted "N/A" when XvB is off; red "No" when donating but a gate is unmet.
    { label: "Raffle Eligible", value: raffle.label, cls: raffleCls(raffle) },
    { label: "Blocks Found", value: p.blocks, cls: "" },
    { label: "XvB Tier", value: hr.tier, cls: "" },
    { label: "Mining Mode", value: hr.mode_name, cls: "c-" + hr.mode_variant },
  ];
}

// Format an epoch-ms x value for the chart tooltip title (Issue #65). Day + time so long ranges
// read clearly; browser locale (≈ the server's, for a localhost dashboard).
export function fmtTimestamp(ms) {
  return new Date(ms).toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// Manual chart zoom (Issue #47). Pure window math, kept here (no DOM/Chart) so it's unit-tested;
// the chartjs-plugin-zoom gestures and the /api/state refetch wiring live in chart.mjs /
// dashboard.js.

// Normalize a dragged/zoomed pixel→time window to an ordered {from, to} (epoch ms) with at
// least `minSpanMs`. Returns null for unusable input (NaN, or a zero-width selection) so a
// degenerate gesture is treated as "no zoom". A too-narrow but valid window is widened around
// its centre to `minSpanMs` (so you can't request a sub-sample window).
export function clampZoomWindow(aMs, bMs, minSpanMs = 60000) {
  if (!Number.isFinite(aMs) || !Number.isFinite(bMs) || aMs === bMs) return null;
  let from = Math.min(aMs, bMs);
  let to = Math.max(aMs, bMs);
  if (to - from < minSpanMs) {
    const mid = (from + to) / 2;
    from = mid - minSpanMs / 2;
    to = mid + minSpanMs / 2;
  }
  return { from, to };
}

// Chart series the user can show/hide, and a normalizer for the persisted state (Issue #47).
// Kept pure so the default-visible logic is unit-tested; dashboard.js persists it in localStorage
// and chart.mjs applies it. Anything not explicitly false defaults to visible.
export const SERIES_KEYS = ["p2pool", "xvb", "shares"];
export function normalizeSeries(obj) {
  const o = obj && typeof obj === "object" ? obj : {};
  const out = {};
  for (const k of SERIES_KEYS) out[k] = o[k] !== false;
  return out;
}

// Human-readable span for the "Zoomed: …" label — the two coarsest units from the first
// non-zero one (e.g. "3d 4h", "1h 20m", "45s"), trailing zero units dropped. Pure and
// locale-independent, unlike fmtTimestamp.
export function fmtWindowDuration(ms) {
  const totalSec = Math.max(0, Math.round(ms / 1000));
  if (totalSec === 0) return "0s";
  const units = [
    ["d", 86400],
    ["h", 3600],
    ["m", 60],
    ["s", 1],
  ];
  const counts = [];
  let rem = totalSec;
  for (const [label, size] of units) {
    counts.push([Math.floor(rem / size), label]);
    rem %= size;
  }
  const first = counts.findIndex(([n]) => n > 0);
  const parts = [];
  for (let i = first; i < counts.length && parts.length < 2; i++) {
    if (counts[i][0] > 0) parts.push(counts[i][0] + counts[i][1]);
    else if (parts.length > 0) break; // stop at a trailing zero unit
  }
  return parts.join(" ");
}

// Theme switching (Issue #43). Three modes; "auto" follows the browser's prefers-color-scheme.
// The valid set, display order and labels live here (pure, no DOM) so they're unit-tested; the
// localStorage + <html data-theme> wiring is in dashboard.js and the segmented control (with its
// SVG icons) in components.mjs.
export const THEMES = ["auto", "light", "dark"];
export const THEME_LABELS = { auto: "Auto", light: "Light", dark: "Dark" };
// Left→right order of the segmented control: light · auto · dark (brightness low→high with the
// system option in the middle).
export const THEME_ORDER = ["light", "auto", "dark"];

// Clamp any value (incl. a stale/garbage localStorage entry) to a valid theme; default "auto".
export function normalizeTheme(t) {
  return THEMES.includes(t) ? t : "auto";
}

// Hashrate-averaging windows for the chart toggle (#168). The valid set + default live here (pure,
// no DOM) so they're unit-tested; the localStorage wiring is in dashboard.js and the segmented
// control (spelled-out labels) in chart.mjs. Keys match the server's `avg` param and
// config.HASHRATE_WINDOWS.
export const AVG_WINDOWS = ["1m", "10m", "1h", "12h", "24h"];
export const DEFAULT_AVG_WINDOW = "10m";

// Clamp any value (incl. a stale/garbage localStorage entry) to a valid window; default 10m — the
// original headline series, so a bad or missing preference reproduces today's chart exactly.
export function normalizeAvgWindow(w) {
  return AVG_WINDOWS.includes(w) ? w : DEFAULT_AVG_WINDOW;
}

// Expected-earnings what-if (Issue #12). The server publishes the per-H/s daily XMR *rate*
// (earnings.coeff_day — authoritative, computed once in service/earnings.py) and the P2Pool
// share difficulty. Earnings are linear in hashrate, so the client only scales that one rate to
// the entered hashrate (and to month/year), and inverts the share difficulty for expected
// time-to-share — no formula is re-derived here. Kept pure so it's unit-tested (no DOM); the
// EarningsCard input wiring lives in components.mjs.
export const DAYS_PER_MONTH = 30; // estimate convention (not 30.44); a year is 365 days
export const DAYS_PER_YEAR = 365;

// Parse a what-if hashrate string into H/s, accepting an optional k/M/G suffix so users can type
// "10.5k", "1.2 MH/s", or a bare "50000". Returns null for empty/unparseable input (the card then
// shows "—"). Mirrors helper/utils.parse_hashrate on the server side.
export function parseHashrate(str) {
  if (typeof str !== "string") return null;
  const m = str.trim().match(/^([0-9]*\.?[0-9]+)\s*([kKmMgG])?/);
  if (!m) return null;
  const val = parseFloat(m[1]);
  if (!Number.isFinite(val) || val < 0) return null;
  const unit = (m[2] || "").toLowerCase();
  return val * (unit === "g" ? 1e9 : unit === "m" ? 1e6 : unit === "k" ? 1e3 : 1);
}

// Scale the server's daily rate to expected XMR over day/month/year for `hashrateHs`, plus the
// expected seconds to find one P2Pool share (share difficulty / hashrate). Returns nulls when the
// estimate can't be computed (rate unavailable, or a non-positive hashrate) so the card shows "—".
export function computeEarnings(hashrateHs, earnings) {
  if (!earnings || !earnings.available || !(hashrateHs > 0)) {
    return {
      day: null,
      month: null,
      year: null,
      timeToShareSec: null,
      tariDay: null,
      tariMonth: null,
      tariYear: null,
    };
  }
  const day = hashrateHs * earnings.coeff_day;
  const tts = earnings.pool_difficulty > 0 ? earnings.pool_difficulty / hashrateHs : null;
  // Tari (#117): merge-mining works the aux chain with the SAME hashrate, so the one what-if
  // input scales the server's XTM rate identically. Nulls (rendered "—") while merge-mining is
  // inactive or the Tari figures aren't collected yet — the XMR estimate is unaffected.
  const tariDay = earnings.tari_available ? hashrateHs * earnings.tari_coeff_day : null;
  return {
    day,
    month: day * DAYS_PER_MONTH,
    year: day * DAYS_PER_YEAR,
    timeToShareSec: tts,
    tariDay,
    tariMonth: tariDay === null ? null : tariDay * DAYS_PER_MONTH,
    tariYear: tariDay === null ? null : tariDay * DAYS_PER_YEAR,
  };
}

// Format a client-computed coin amount. More decimal places for small amounts (a day's earnings can
// be a tiny fraction) so the figure isn't rounded to "0.0000"; "—" for the null/invalid case.
function formatCoin(value, unit) {
  if (value === null || value === undefined || !Number.isFinite(value)) return "—";
  if (value === 0) return "0 " + unit;
  const dp = value >= 1 ? 4 : value >= 0.001 ? 6 : 8;
  return value.toFixed(dp) + " " + unit;
}

export function formatXmr(xmr) {
  return formatCoin(xmr, "XMR");
}

// Merge-mined Tari (#117); the collector already delivers the reward in XTM (not µT).
export function formatXtm(xtm) {
  return formatCoin(xtm, "XTM");
}

// Format the expected time-to-share (seconds) for display; "—" when not computable. Reuses the
// two-coarsest-units duration formatter (e.g. "3d 4h", "1h 20m").
export function formatTimeToShare(sec) {
  if (sec === null || sec === undefined || !Number.isFinite(sec) || sec <= 0) return "—";
  return fmtWindowDuration(sec * 1000);
}

// Egress posture (#170): map a connection's route token to a display glyph + label + CSS token for
// the Component Health panel. The server (service/egress.py) derives the route from live config; the
// client only maps it to presentation, no logic of its own (the #61 principle).
export const EGRESS_ROUTES = {
  tor: { icon: "🧅", label: "Tor", cls: "ok" },
  clearnet: { icon: "🌐", label: "Clearnet", cls: "bad" },
  local: { icon: "🏠", label: "Local/LAN", cls: "muted" },
  inactive: { icon: "⚪", label: "Inactive", cls: "muted" },
};

export function egressRoute(route) {
  return EGRESS_ROUTES[route] || { icon: "❔", label: route || "unknown", cls: "muted" };
}

// Topology edge routing (#170): the point on a node box's border heading toward a target point, so
// a connector starts/ends flush on the box edge (not its centre). Pure geometry — `node` is
// {x, y, w, h}; (tx, ty) the target centre. Used by the StackTopology SVG and unit-tested directly.
export function boxAnchor(node, tx, ty) {
  const cx = node.x + node.w / 2;
  const cy = node.y + node.h / 2;
  const dx = tx - cx;
  const dy = ty - cy;
  if (dx === 0 && dy === 0) return { x: cx, y: cy };
  // Scale the direction vector until it hits the nearest border (half-width / half-height).
  const sx = dx !== 0 ? node.w / 2 / Math.abs(dx) : Infinity;
  const sy = dy !== 0 ? node.h / 2 / Math.abs(dy) : Infinity;
  const s = Math.min(sx, sy);
  return { x: cx + dx * s, y: cy + dy * s };
}

// Width of a stacked hashrate band's top border-line for one chart segment. Returns 0 when the band
// has zero height across the segment (both endpoints y === 0), so a flat-zero series doesn't paint
// its colored border-line over the other series' edge — the "blue-purple at 100% P2Pool" artifact,
// and the symmetric stray-blue-line in XvB-only mode (#184). `series` is the [{x, y}] data; `ctx` is
// the Chart.js line-segment context (p0DataIndex / p1DataIndex). Partial-zero spans are handled
// per-segment, so a window that's only briefly all-one-pool still hides just the zero stretch.
export function bandBorderWidth(series, ctx, fullWidth) {
  const y0 = series[ctx.p0DataIndex]?.y;
  const y1 = series[ctx.p1DataIndex]?.y;
  return y0 === 0 && y1 === 0 ? 0 : fullWidth;
}

// What to show in a worker's "Uptime" cell. For an online worker it's the real uptime; for an
// offline one it's "DOWN" — never the raw duration, which for a disconnected worker kept climbing
// and read like uptime when it was really downtime (#169). The raw numeric `uptime` is left on the
// row for client-side column sorting; only the displayed string changes.
export function uptimeCell(worker) {
  return worker.status === "online" ? worker.uptime_str : "DOWN";
}
