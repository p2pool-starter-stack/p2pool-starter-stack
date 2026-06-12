# Launch assets

Marketing/launch screenshots of the Pithead dashboard (Issue #80). Each view ships in **dark** and
**light** themes (`*-light.png`), so docs can serve a theme-adaptive `<picture>`.

| View | Dark | Light | What |
|---|---|---|---|
| **Hero** | `hero.png` | `hero-light.png` | Header + hero KPI band (wide banner) |
| **Simple** | `simple.png` | `simple-light.png` | Operational view, Simple tab (default) |
| **Advanced** | `advanced.png` | `advanced-light.png` | Operational view, Advanced tab (power-user cards) |
| **Sync** | `sync.png` | `sync-light.png` | Sync Mode (nodes catching up, miner held) |

**These are illustrative mockups.** They are rendered from the **real dashboard UI** (the shipping
Preact components + `dashboard.css`) fed a **synthetic `/api/state`** payload, so they are
pixel-accurate to the product — but the numbers (a ~847 kH/s farm holding the Whale XvB tier, 14
workers, etc.) and the wallet/host values are **fabricated for presentation**. No real wallet, host,
or operator data appears in any of them (wallet fields are obvious `EXAMPLE` placeholders).

Rendered at retina 2× (`hero*` 2880×600; `sync*` 2880×1336; `simple*`/`advanced*` are full-page).
Used in the [README](../../README.md) (hero) and [docs/dashboard.md](../../docs/dashboard.md)
(Simple / Advanced / Sync).
