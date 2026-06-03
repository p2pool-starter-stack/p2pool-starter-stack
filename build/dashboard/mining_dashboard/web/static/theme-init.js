// Apply the saved theme (Issue #43) before the first paint, so an explicit light/dark choice
// doesn't flash the opposite palette while the deferred ES modules load.
//
// This is intentionally a *classic*, render-blocking <script src> in <head> (not a module —
// modules are deferred and would run after the shell has already painted). It's same-origin,
// so it loads under the CSP's `script-src 'self'` without needing 'unsafe-inline'.
//
// It only sets the attribute the CSS reacts to; dashboard.js owns the live toggle and keeps
// localStorage in sync. An unset/unknown value is left alone — the CSS default is "auto"
// (follow prefers-color-scheme), so nothing to do.
(function () {
    try {
        var t = localStorage.getItem('dashboardTheme');
        if (t === 'light' || t === 'dark' || t === 'auto') {
            document.documentElement.setAttribute('data-theme', t);
        }
    } catch (e) {
        /* localStorage blocked (e.g. privacy mode) — fall back to the CSS default (auto). */
    }
})();
