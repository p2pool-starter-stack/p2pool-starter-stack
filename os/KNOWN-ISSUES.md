# pithead-os build — known issues

## Status: the appliance boots and serves its setup wizard (2026-07-25)

`tests/os/run.sh --phase boot` passes 3/3: boots to userspace on generic x86 EFI,
opens the first-boot wizard with a one-time token on the console, and serves the token
gate on `:80`. The A/B update battery is the remaining proof.

## Resolved, with the lessons worth keeping

**The debugging rule that cost eleven silent rebuilds.** `/dev/console` is whichever
`console=` came **last** on the kernel cmdline, and `loglevel=3` keeps the kernel
banner off it entirely. Kernel messages reaching a serial capture prove nothing about
whether userspace output does — the updater was printing its exact error to tty1 the
whole time. Check which console you are actually reading before concluding a component
is silent.

**debian-slim ships none of the tools our Rust components shell out to.** rugix-ctrl
calls `sfdisk`/`mkfs.ext4` as init; netavark calls `nft`. Each absence surfaces only as
a bare `os error 2` at runtime. After fixing these one at a time across three build
cycles, the whole shell-out set is now audited against the built image instead:
`nft iptables hostname ip mkfs.ext4 sfdisk tar gzip systemctl podman awk sed`.

**Container storage cannot live on the root overlay.** Rugix mounts `/` as an overlay,
and podman's overlay driver refuses to stack on it (`'overlay' is not supported over
overlayfs`). Storage belongs on the data partition for a second reason too: the root
overlay is discarded across reboots and A/B updates, so images stored there would
vanish on every update. `ConditionPathIsMountPoint=/data` guards it.

**The appliance must not look like a source checkout.** `is_source_checkout()` probes
for `build/dashboard/Dockerfile`, so copying the whole `build/` tree made the appliance
tag images `:dev`, set the pull policy to `never`, and — the serious one — skip cosign
verification of release images entirely. Only the three subtrees services bind-mount
are shipped now.

**First boot repartitions, so the disk must fit the whole layout** — 256M EFI +
2×512M boot + 2×8 GiB system + data ≈ **18 GiB minimum**. Below it, bootstrapping
aborts and the box panics rather than degrading. This is the appliance's real
minimum-disk spec.

**The appliance needs images containing unreleased code.** The wizard module is new on
this branch, so no published image has it — a pulled image starts and exits with
`No module named mining_dashboard.wizard`. `build-image.sh` builds the dashboard image
from the working tree by default; `PITHEAD_WIZARD_FROM_REGISTRY=1` switches to the
released image once a release carries the wizard.

## Open

- **Only the wizard image is baked in.** The rest of the stack still pulls at provision
  time, so the plan's "first boot works offline" property is partial: the setup page
  works without a network, provisioning does not. Baking the full set roughly triples
  the image and inflates every update bundle — sized deliberately, not forgotten.
- **Hugepages are reserved unconditionally** (6 GiB), so the appliance needs ≥ 16 GiB
  RAM to leave room for the stack. The harness sizes its VM accordingly; a real
  appliance should either check or scale the reservation.
