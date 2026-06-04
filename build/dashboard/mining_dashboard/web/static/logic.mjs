// Pure, dependency-free client logic — no Preact, no DOM, no Chart.js. Kept separate so it can
// be unit-tested with Node's built-in runner (`node --test`; see tests/frontend/logic.test.mjs)
// without a browser or a JS toolchain. Presentation (components, the canvas) stays elsewhere and
// is covered by the browser smoke test.

// Worker table columns, each carrying the state key it sorts on. Hashrate/uptime/IP sort
// numerically (raw values the server includes alongside the formatted strings); name sorts as
// text. The order matches the rendered <th>s.
export const WORKER_COLUMNS = [
    { label: 'Worker', key: 'name' },
    { label: 'IP', key: 'ip_sort' },
    { label: 'Uptime', key: 'uptime' },
    { label: '10s', key: 'h10' },
    { label: '60s', key: 'h60' },
    { label: '15m', key: 'h15' },
];

// Return a new array of workers sorted by the given column index. ``idx == null`` keeps the
// server's order (online first, then name). Numeric columns compare numerically (so 1000 sorts
// after 9, not before it); everything else compares as a locale string. Never mutates input.
export function sortWorkers(workers, idx, asc) {
    if (idx === null || idx === undefined) return workers;
    const key = WORKER_COLUMNS[idx].key;
    const sorted = [...workers].sort((a, b) => {
        const va = a[key], vb = b[key];
        if (typeof va === 'number' && typeof vb === 'number') return va - vb;
        return String(va).localeCompare(String(vb));
    });
    return asc ? sorted : sorted.reverse();
}

// Format an epoch-ms x value for the chart tooltip title (Issue #65). Day + time so long ranges
// read clearly; browser locale (≈ the server's, for a localhost dashboard).
export function fmtTimestamp(ms) {
    return new Date(ms).toLocaleString([], {
        month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
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
export const SERIES_KEYS = ['p2pool', 'xvb', 'shares'];
export function normalizeSeries(obj) {
    const o = (obj && typeof obj === 'object') ? obj : {};
    const out = {};
    for (const k of SERIES_KEYS) out[k] = o[k] !== false;
    return out;
}

// Human-readable span for the "Zoomed: …" label — the two coarsest units from the first
// non-zero one (e.g. "3d 4h", "1h 20m", "45s"), trailing zero units dropped. Pure and
// locale-independent, unlike fmtTimestamp.
export function fmtWindowDuration(ms) {
    const totalSec = Math.max(0, Math.round(ms / 1000));
    if (totalSec === 0) return '0s';
    const units = [['d', 86400], ['h', 3600], ['m', 60], ['s', 1]];
    const counts = [];
    let rem = totalSec;
    for (const [label, size] of units) { counts.push([Math.floor(rem / size), label]); rem %= size; }
    const first = counts.findIndex(([n]) => n > 0);
    const parts = [];
    for (let i = first; i < counts.length && parts.length < 2; i++) {
        if (counts[i][0] > 0) parts.push(counts[i][0] + counts[i][1]);
        else if (parts.length > 0) break;   // stop at a trailing zero unit
    }
    return parts.join(' ');
}

// Theme switching (Issue #43). Three modes; "auto" follows the browser's prefers-color-scheme.
// The valid set, display order and labels live here (pure, no DOM) so they're unit-tested; the
// localStorage + <html data-theme> wiring is in dashboard.js and the segmented control (with its
// SVG icons) in components.mjs.
export const THEMES = ['auto', 'light', 'dark'];
export const THEME_LABELS = { auto: 'Auto', light: 'Light', dark: 'Dark' };
// Left→right order of the segmented control: light · auto · dark (brightness low→high with the
// system option in the middle).
export const THEME_ORDER = ['light', 'auto', 'dark'];

// Clamp any value (incl. a stale/garbage localStorage entry) to a valid theme; default "auto".
export function normalizeTheme(t) {
    return THEMES.includes(t) ? t : 'auto';
}

// Expected-earnings what-if (Issue #12). The server publishes the per-H/s daily XMR *rate*
// (earnings.coeff_day — authoritative, computed once in service/earnings.py) and the P2Pool
// share difficulty. Earnings are linear in hashrate, so the client only scales that one rate to
// the entered hashrate (and to month/year), and inverts the share difficulty for expected
// time-to-share — no formula is re-derived here. Kept pure so it's unit-tested (no DOM); the
// EarningsCard input wiring lives in components.mjs.
export const DAYS_PER_MONTH = 30;   // estimate convention (not 30.44); a year is 365 days
export const DAYS_PER_YEAR = 365;

// Parse a what-if hashrate string into H/s, accepting an optional k/M/G suffix so users can type
// "10.5k", "1.2 MH/s", or a bare "50000". Returns null for empty/unparseable input (the card then
// shows "—"). Mirrors helper/utils.parse_hashrate on the server side.
export function parseHashrate(str) {
    if (typeof str !== 'string') return null;
    const m = str.trim().match(/^([0-9]*\.?[0-9]+)\s*([kKmMgG])?/);
    if (!m) return null;
    const val = parseFloat(m[1]);
    if (!Number.isFinite(val) || val < 0) return null;
    const unit = (m[2] || '').toLowerCase();
    return val * (unit === 'g' ? 1e9 : unit === 'm' ? 1e6 : unit === 'k' ? 1e3 : 1);
}

// Scale the server's daily rate to expected XMR over day/month/year for `hashrateHs`, plus the
// expected seconds to find one P2Pool share (share difficulty / hashrate). Returns nulls when the
// estimate can't be computed (rate unavailable, or a non-positive hashrate) so the card shows "—".
export function computeEarnings(hashrateHs, earnings) {
    if (!earnings || !earnings.available || !(hashrateHs > 0)) {
        return { day: null, month: null, year: null, timeToShareSec: null };
    }
    const day = hashrateHs * earnings.coeff_day;
    const tts = earnings.pool_difficulty > 0 ? earnings.pool_difficulty / hashrateHs : null;
    return { day, month: day * DAYS_PER_MONTH, year: day * DAYS_PER_YEAR, timeToShareSec: tts };
}

// Format a client-computed XMR amount. More decimal places for small amounts (a day's earnings can
// be a tiny fraction) so the figure isn't rounded to "0.0000"; "—" for the null/invalid case.
export function formatXmr(xmr) {
    if (xmr === null || xmr === undefined || !Number.isFinite(xmr)) return '—';
    if (xmr === 0) return '0 XMR';
    const dp = xmr >= 1 ? 4 : xmr >= 0.001 ? 6 : 8;
    return xmr.toFixed(dp) + ' XMR';
}

// Format the expected time-to-share (seconds) for display; "—" when not computable. Reuses the
// two-coarsest-units duration formatter (e.g. "3d 4h", "1h 20m").
export function formatTimeToShare(sec) {
    if (sec === null || sec === undefined || !Number.isFinite(sec) || sec <= 0) return '—';
    return fmtWindowDuration(sec * 1000);
}
