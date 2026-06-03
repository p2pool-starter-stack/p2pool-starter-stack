# Vendored frontend libraries

These are committed (not fetched at build/runtime) so the dashboard has no Node/npm build
step and serves entirely from `/static` under a strict Content-Security-Policy
(`script-src 'self'`, no `'unsafe-inline'`/`'unsafe-eval'`). Both are standalone ES modules
with no bare imports and no `eval`/`new Function`, so they load and run under that CSP.

| File                | Package  | Version | Source                                               |
|---------------------|----------|---------|------------------------------------------------------|
| `preact.module.js`  | preact   | 10.24.3 | https://unpkg.com/preact@10.24.3/dist/preact.module.js |
| `htm.module.js`     | htm      | 3.1.1   | https://unpkg.com/htm@3.1.1/dist/htm.module.js         |
| `chart.umd.min.js`  | chart.js | (vendored previously) | https://www.chartjs.org/                 |

## Updating

Download the new version from the same URL pattern, drop it in here, and re-run the dashboard
browser smoke test. Keep the table above in sync. Do not minify/transform — the point is that
what ships is exactly the published file.
