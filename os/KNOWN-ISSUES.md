# pithead-os build — known issues

## Status: RAUC appliance, installs to disk, all batteries green (2026-07-25)

`tests/os/run.sh` passes boot 3/3, update 11/11 and fault 11/11 on the RAUC appliance,
with no brick in any run. The image ships the ESP and slot A only (636 MB);
systemd-repart builds slot B and /data on the target's own disk, and `/data` measured
24 GiB of a 40 GiB disk while the system slot stayed at 8.

The Rugix candidate is removed from this branch and preserved on
`reference/rugix-candidate`. The decision and its evidence are in the plan's bake-off
section; build, release and the manual hardware battery are in
[`docs/dev/appliance-release.md`](../docs/dev/appliance-release.md).

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

**First boot repartitions, so the boot medium must fit the whole layout** — 256M ESP +
2×4 GiB slots + data's 4 GiB minimum ≈ **12.5 GiB**. systemd-repart is transactional:
below that, NOTHING is created, `/data` never exists, and the machine drops to an
emergency shell with the root account locked — no clean message. A real 16 GB stick
(14.9 GiB) is the smallest supported medium, and the install phase tests exactly that
size. This ceiling is why the slots are 4 GiB: at 8 GiB the layout needed ~20.5 GiB and
the documented 16 GB stick failed to boot.

**The appliance needs images containing unreleased code.** The wizard module is new on
this branch, so no published image has it — a pulled image starts and exits with
`No module named mining_dashboard.wizard`. `build-image.sh` builds the dashboard image
from the working tree by default; `PITHEAD_WIZARD_FROM_REGISTRY=1` switches to the
released image once a release carries the wizard.

**`apt install rauc` gives you a CLI that cannot install anything.** Debian splits the
D-Bus daemon into a separate `rauc-service` package which is not even a *Recommends* of
`rauc` — so `--no-install-recommends` is not what drops it; the package has to be named.
Every `rauc install` then fails with `de.pengutronix.rauc was not provided by any
.service files`, which names a D-Bus address and never the missing daemon. This survived
four full battery runs because boot and the mid-write power cuts don't touch the daemon —
only the install path does. When a component fails on a D-Bus name, check the package
split before the code.

**A hand-written GRUB slot selector broke fallback, and the bug was invisible to review.**
RAUC's reference `grub.cfg` reserves menu index 0 for a rescue entry, so `default=0`
carries the meaning "no slot was selectable". Renumbering the slots to 0/1 made "chose
slot A" and "found nothing" the same value, and the try-flag reset then only fired when A
was already bad. Boot tests passed 3/3 throughout — only power-cutting a VM mid-update
exposed it. If the boot logic is ours, the fault battery is the only thing that checks it.

**`load_env` reads `$prefix/grubenv`, and a misplaced env block fails silently.** Our
BOOTX64.EFI is built with `-p /grub`, so GRUB looks for `ESP:/grub/grubenv`; the image
seeded `ESP:/grubenv` and RAUC was configured to write there too. Both wrote the file
correctly, GRUB never read it, `ORDER` kept its built-in value with both slots marked
not-OK, and every boot landed on the same slot. Nothing logs an error at any layer — the
symptom is an update that installs cleanly and never takes effect.

**A slot cannot be found by filesystem label.** One RAUC bundle carries one filesystem
image and installs into whichever slot is spare, so its fs label cannot encode the slot;
after an install, `search --label system-b` fails with `no such device`. The GPT
partition label survives (the updater writes the partition, not the table), so
`root=/dev/disk/by-partlabel/` still works for the kernel. Slots are addressed
positionally in `grub.cfg`, with the disk derived from where GRUB found its config
rather than hardcoded to `hd0` — a mining box often has several drives.

**Two hand-maintained copies of "populate a slot" drifted the moment the root went
read-only.** `mkimage.sh` gained the fstab that mounts `/data` and overlays `/var`;
`mkbundle.sh` did not, so slot B came up with a read-only root, no writable `/var`, and
could not boot — while RAUC and GRUB both did their jobs correctly. Both paths now call
`populate_slot()` from `os/rauc/populate-slot.sh`.

**A stray VM on the bench invalidates results without failing anything.** A
hand-started diagnostic guest kept the DHCP lease the harness reads back, so the battery
drove the wrong machine and reported passing legs. `tests/os/run.sh` now refuses to start
when another `pithead-*` domain is defined.

**A copy of / is not a copy of the slot.** The disk installer ran `tar --one-file-system`
from `/` and shipped an empty `/var` — the overlay mount is a different filesystem, so the
slot's real `/var` (dpkg database, `/var/lib`) was invisible to the walk. A bind mount of
`/` exposes the slot filesystem underneath every runtime mount and is the only correct
source for a self-copy. Nothing failed at boot; the damage was a machine with no package
database, found only because `--phase install` asserts `/var/lib/dpkg/status` exists.

**lsblk column output cannot be parsed with `read`.** A model with spaces shifts fields
right; an empty model (all virtio, some NVMe) shifts them left. Both failure modes made
real disks silently vanish from the installer's inventory. `lsblk -J` through `jq` or
nothing.

**docker export lies about /etc/hosts, /etc/resolv.conf AND /etc/hostname.** Docker
overlays all three as per-container bind mounts: writes to them during the build never
leave the build, and the export carries empty stubs. The OS could not resolve even
`localhost` (glibc's fallback sent DNS to `[::1]:53` — first visible as image pulls
failing), and it called itself `localhost`, so avahi published `localhost.local` and
caddy rendered a site nobody could reach. Fourth, fifth and sixth members of the
docker-export-artefact family after `/.dockerenv` and the pseudo-dirs; populate_slot
writes all of them, because docker cannot.

**Every battery was green while the appliance could not run the product.** pithead drives
the stack with `docker compose`; the image shipped only podman — no shim, no compose
provider, no cosign. The wizard accepted a config and `setup` died at "docker: command
not found", after boot, update, install and fault all passed: none of them provision.
The engine bridge (podman-docker + pinned docker-compose v2 as podman's provider +
pinned cosign) keeps ONE lifecycle across both channels, and the `provision` phase now
submits a config through the wizard's real HTTP flow and requires running containers —
the test that fails when the product cannot actually start.

**A build can ship code you never wrote into it.** A release image once carried a dashboard
two commits stale: the release clone's origin was an intermediate clone, not the real remote,
so `git pull` succeeded and fetched nothing new. The image looked right, passed every static
check, and behaved like the previous build — the operator flashed it and hit an
already-fixed bug. Images are stamped with their build commit now
(`/opt/pithead/BUILD_COMMIT`) and `verify-image.sh` compares it against
`PITHEAD_EXPECT_COMMIT`. Never diagnose an image by the label on it.

**The appliance runs FROM the installation medium, so the stick cannot come out while it
runs.** An install ends by powering the machine OFF, never rebooting: removing the stick from
a running system takes its root, `/data` and the wizard's spool with it, and the machine
wedges — the browser's request and the host's poll both write to a filesystem that no longer
exists, so the button appears to do nothing. A restart with the stick still in just boots the
stick again. Off → stick out → on is the only sequence the hardware allows, and it costs
nothing: the operator is already at the machine to pull the stick. A bench session hit this twice —
once after the flow was changed to "remove the stick, then press Reboot", and again after the
wording was corrected but the button remained. The button is gone: the install powers the
machine off unprompted, so by the time anyone reaches it to pull the stick, it is already
dark and there is no order left to get wrong.

**podman is two different engines about short image names.** The compat API (what compose
speaks) keeps docker's semantics and resolves `caddy:2.x@sha256:…` via docker.io; the native
path (`docker run` through the shim) refuses the same string outright unless
`unqualified-search-registries` is configured. So the stack pulled and ran — and then died the
first time a helper did a bare `docker run` with the same image reference the compose file uses.
The image reference is now fully qualified at the call site AND the appliance restores docker's
implied docker.io, because the stack was written against docker semantics and the next bare
`docker run` is otherwise a time bomb.

**Generated config is never re-rendered, so new code reads config it did not write.** The
most consequential defect found on hardware, and it was invisible to every KVM phase because
each one provisions fresh. `pithead-sync` copies the PROGRAM tree from the slot on every boot,
but `.env`, `Caddyfile` and the rendered service configs are state on `/data` — they keep
whatever the last successful `setup` produced. A bench machine ran the newest `pithead` against
a `Caddyfile` generated days earlier by an older build: its site list said `https://pithead`
(no `.local`) and `tls internal`, so `pithead.local` matched no site and TLS died —
diagnosed twice as a certificate bug it was not. Two ordinary paths reach this state: a
reinstall over preserved `/data`, and **any A/B OS update**, which is the appliance's whole
point. VERSION cannot be the trigger (RCs share one); the build stamp at
`/opt/pithead/BUILD_COMMIT` can. The fix is to record the program identity that produced the
current render and re-render when it changes — see #787.

## Open

- **A provisioning failure reopens the wizard, but the failed config needs surfacing.**
  Setup failures move the config aside as `config.json.failed` and re-mint a token; the
  console explains, but the fresh wizard page does not yet show WHY the last attempt
  failed. Plumbing the failure reason into the reopened form is UX work worth doing
  before GA.
- **Installing to a disk still needs a human.** Pre-seeding (`pithead-token.txt` /
  `pithead-config.json` on the ESP) covers configuration headlessly and the installer carries
  both onto the target, so a fleet can be flashed and provisioned from one file. Choosing
  which disk to erase is deliberately NOT automated — an unattended installer that picks a
  disk itself will eventually pick the wrong one. A pre-seeded target would need to name the
  disk by serial, not by `/dev/` path, and that is unbuilt.
- **Everything host-CLI-only is impossible on the appliance (#786).** The control gate's
  host-only class — wallets, view keys, auth, onion, workers.list, backup/restore — assumes
  a host terminal that the appliance does not have. Right by design, unreachable by
  accident: the wizard covers setup, but changing these later means reinstalling. #338's
  out-of-band approval (or a physical-presence channel via the stick) is the lift;
  dashboard backup export is the sharpest single loss.
- **No user-facing OS update path exists yet.** RAUC and rollback are proven at the OS
  layer, but nothing a user can reach applies an update: the dashboard action for
  install/commit/rollback of OS bundles is the pre-GA blocker, and the DIY one-click
  upgrade deliberately refuses on the appliance (a tarball upgrade would silently revert
  at the next boot).
- **The manual hardware battery has not been run.** Everything above is KVM. Secure Boot,
  real disks, headless discovery and a genuine power cut are exactly what a VM cannot
  show — M1-M10 in the release doc must pass on a physical box before an image ships.
- **Only the wizard image is baked in.** The rest of the stack still pulls at provision
  time, so the plan's "first boot works offline" property is partial: the setup page
  works without a network, provisioning does not. Baking the full set roughly triples
  the image and inflates every update bundle — sized deliberately, not forgotten.
- **The stick and an installed disk carry identical partition labels.** The DANGEROUS half
  is fixed: the kernel root is the PARTUUID of the partition GRUB actually chose (`probe
  --part-uuid` at boot), so the machine can no longer boot one disk's kernel against the
  other disk's system. What remains is `/data` and the ESP, mounted by LABEL from a static
  fstab — with both disks present, which `data` wins is udev's choice. The installer powers
  the machine off after installing (remove the stick while it is off) and the docs say
  never to boot with both; the residual exposure is a confusing but non-destructive mount,
  not a wrong system.
- **Every direct-flashed stick shares the image's identity material.** `/etc/machine-id`
  and the SSH host keys are baked at image build, so two sticks flashed from one release
  are identical until something regenerates them. The installer resets machine-id for
  installed systems; direct-flash boots and host-key regeneration need a first-boot
  answer before fleet shipping.
- **Hugepages are reserved unconditionally** (6 GiB), so the appliance needs ≥ 16 GiB
  RAM to leave room for the stack. The harness sizes its VM accordingly; a real
  appliance should either check or scale the reservation.
