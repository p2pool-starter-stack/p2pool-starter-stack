# Launch assets

Marketing/launch visuals for the Pithead dashboard (Issue #80). Static views ship in dark and light
themes (`*-light.png`), so docs can serve a theme-adaptive `<picture>`.

| Asset | Files | What |
|---|---|---|
| **Hero** | `hero.png` / `hero-light.png` | Header + hero KPI band (wide banner) |
| **Simple** | `simple.png` / `simple-light.png` | Operational view, Simple tab (default) |
| **Advanced** | `advanced.png` / `advanced-light.png` | Operational view, Advanced tab (power-user cards) |
| **Sync** | `sync.png` / `sync-light.png` | Sync Mode (nodes catching up, miner held) |
| **Demo GIF** | `demo.gif` | ~12s scroll-tour of the Advanced dashboard (600×338) |
| **Social preview** | `social-preview.png` | 1280×640 card for GitHub's repo social preview (Settings → Social preview) |

These are illustrative mockups. Static views are rendered from the real dashboard UI (the shipping
Preact components + `dashboard.css`) fed a synthetic `/api/state` payload, so they are pixel-accurate
to the product. The numbers (a ~847 kH/s farm holding the Whale XvB tier, 14 workers, etc.) and the
wallet/host values are fabricated for presentation. No real wallet, host, or operator data appears
in any of them (wallet fields are obvious `EXAMPLE` placeholders).

Static views rendered at retina 2× (`hero*` 2880×600; `sync*` 2880×1336; `simple*`/`advanced*`
full-page). Used in the [README](../../README.md) (hero + demo GIF) and
[docs/dashboard.md](../../docs/dashboard.md) (Simple / Advanced / Sync).

> NOTE: `social-preview.png` is not wired up automatically. GitHub's repo social-preview image can
> only be set from the web UI: repo → Settings → General → Social preview → Edit → upload
> `social-preview.png`.
