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
