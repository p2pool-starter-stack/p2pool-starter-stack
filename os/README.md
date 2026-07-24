# Appliance runtime units

The hand-written Quadlet unit set that ran the full stack under rootful Podman in
the #78 runtime spike (2026-07-24): seven `.container` units and two `.network` units,
brought up on a Debian 13 VM with both nodes remote. Preserved in `quadlet/` as the
reference output the phase-1 `pithead render-quadlet` renderer must reproduce.

Secrets, wallets, and the onion address are replaced with `rendered-*` /
`your_*_wallet_address` placeholders; everything else is exactly what ran, including
the fixes the spike forced (`TimeoutStartSec=infinity`, tmpfs `mode=` instead of
`uid=`/`gid=`, the 1g p2pool cap that holds once hugepages are reserved).

These files are fixtures, not deployable configuration. Nothing consumes them yet, and
the appliance never hand-edits units — `pithead` renders them from `config.json`. The
translation rules the spike established, with evidence, live in
[`docs/dev/dual-distribution-plan.md`](../docs/dev/dual-distribution-plan.md)
(Runtime architecture) and on issue #78.
