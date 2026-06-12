# Launch assets

Marketing/launch screenshots of the Pithead dashboard (Issue #80).

| File | What |
|---|---|
| `hero.png` / `hero-light.png` | The header + hero KPI band (wide banner crop), dark / light theme |
| `dashboard.png` / `dashboard-light.png` | The full operational dashboard (Advanced view), dark / light theme |

**These are illustrative mockups.** They are rendered from the **real dashboard UI** (the shipping
Preact components + `dashboard.css`) fed a **synthetic `/api/state`** payload, so they are
pixel-accurate to the product — but the numbers (a ~847 kH/s farm holding the Whale XvB tier, 14
workers, etc.) and the wallet/host values are **fabricated for presentation**. No real wallet, host,
or operator data appears in any of them.

Rendered at retina 2× (`hero*` are 2880×600; `dashboard*` are 2880×5394).
