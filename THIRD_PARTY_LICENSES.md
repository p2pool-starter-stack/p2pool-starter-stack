# Third-Party Licenses

Pithead's own code is [MIT](./LICENSE). The images it builds and the files it
vendors also **redistribute** third-party components, which keep their own licenses:

## Bundled binaries (in the published `pithead-*` images)

Version-pinned, sha256-verified, **unmodified** upstream binaries (pin + hash in each
`build/<name>/Dockerfile`):

| Binary | Version | License | Source |
|--------|---------|---------|--------|
| monerod | v0.18.5.0 | BSD-3-Clause | <https://github.com/monero-project/monero> |
| p2pool | v4.16 | **GPL-3.0-or-later** | <https://github.com/SChernykh/p2pool/releases/tag/v4.16> |
| xmrig-proxy | 6.26.0 | **GPL-3.0-or-later** | <https://github.com/xmrig/xmrig-proxy/releases/tag/v6.26.0> |
| tor | distro | BSD-3-Clause | <https://gitlab.torproject.org/tpo/core/tor> |

`p2pool` and `xmrig-proxy` are GPL-3.0, shipped **unmodified** as **separate
containers** (mere aggregation — no linking into Pithead's code). The GPLv3 text is at
<https://www.gnu.org/licenses/gpl-3.0.txt>; the **corresponding source** is the exact
upstream release linked above (matching the pinned version + sha256 in the Dockerfile).

## Vendored / generated (in `pithead-dashboard`)

- Frontend JS under `build/dashboard/mining_dashboard/web/static/`: **preact** 10.24.3 (MIT),
  **htm** 3.1.1 (Apache-2.0), **chart.js** 4.4.6 (MIT), **chartjs-plugin-zoom** 2.2.0 (MIT),
  **hammerjs** 2.0.8 (MIT) — see that dir's `vendor/README.md`.
- Tari gRPC `.proto` files + generated stubs under
  `build/dashboard/mining_dashboard/client/tari/`: **BSD-3-Clause**, © The Tari Project.

Base images (`ubuntu`/`alpine`/`python-slim`) and the dashboard's Python dependencies
(`build/dashboard/pyproject.toml`) carry their own, permissive licenses.
