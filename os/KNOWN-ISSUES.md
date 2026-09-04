# pithead-os build — known issues

## Status: RAUC appliance, installs to disk; the battery gates every cut

`tests/os/run.sh` has grown from the original five phases to eight — boot, update, install,
provision, media, rig, fault and reset — and "green" means the full battery passing on the
tip being cut, not a dated badge here: the 2026-08 waves each found real product bugs on a
tip whose previous run had passed. The last fully-green run of the original five phases was
2026-07-25 (boot 4/4, update 15/15, provision 21/21, install 33/33, fault 11/11, no brick in
any run). The per-phase assertion list is in
[the release doc's battery table](../docs/dev/appliance-release.md#the-automated-battery).
The image ships the ESP and slot A only (636 MB);
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
for `dashboard/Dockerfile` (dashboard moved out of `build/` in #1106; it is never copied into
the image). Copying the whole `build/` tree used to ship it there, which made the appliance
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

**Fixed — the derived layer is regenerated on every boot.** `pithead-sync` delivers the new
program; `pithead-boot` then runs `pithead render` before anything starts, so `.env`, the
Caddyfile, the service configs and the host units are rebuilt from `config.json` plus the
program that is actually running (#790). The same unit replaced `podman-restart`, which
SIGKILLed the containers it had just started (#792); it brings the stack up through
`pithead up` (compose owns the lifecycle) and commits the booted A/B slot only after the
dashboard answers through caddy (#793). On the read-only root, host units render into
`/run/systemd/system` and are re-created each boot by the same mechanism (#791).

**Fixed — every direct-flashed stick shared the image's identity material.** `/etc/machine-id`
and the SSH host keys were both baked at image build — generated by their packages' own
postinst (systemd, openssh-server) — so they were extractable from a published release and
identical across every machine flashed from it (#894/#895). The image now ships both empty:
no `ssh_host_*` files, and a 0-byte `/etc/machine-id` so systemd runs its own documented
first-boot semantics. Both identities are then generated once, at boot, into `/data` — the
same persistence root Tor's onion identity already lives on — and restored into the (volatile,
read-only-root) `/etc` on every later boot: `pithead-machine-id.service` runs early enough
that `systemd-networkd` (DHCP DUID) and the journal flush to `/var/log/journal` observe the
persisted id, and a `ssh.service` drop-in generates the host key into `/data/ssh` before sshd
starts. Host identity survives A/B updates and reboots by construction (it never lived on the
system slot to begin with); the reset tiers classify it like everything else on `/data` — a
keep-everything reinstall keeps it, a fresh-start or full wipe deletes it.

**Fixed — the boot health gate's other half was accepting Caddy's empty default vhost
(#1140).** The probe dialled `https://localhost/` and took any status but `000` as proof the
dashboard was serving, on the stated belief that localhost is always a listed site. It is one only
while `dashboard.host` is unset: `generate_caddyfile` adds it inside `is_appliance && [ -z
"$DASHBOARD_HOST" ]`. Pin the host — a documented, supported choice — and the probe reached the
default vhost, which answers 200 with no body, so "Caddy is running" passed as "the dashboard
serves" on the gate that decides whether an A/B update lives. Both halves are fixed together,
because tightening the check alone would have turned the false pass into a permanent failure on
exactly those machines: the probe now asks for the site the render itself chose, read as `HOST_IP`
from the `.env` of that same boot and dialled over loopback with `--resolve`, and it accepts only an
answer the default vhost cannot give — a body, or the `401` a locked dashboard sends. Not a `401`
check: an empty dashboard password is the documented default, and that machine answers `200`.

**Fixed — `doctor` looked for the control units in `/etc`, and the appliance puts them in
`/run` (#1151).** `provision_control_runner` knew the read-only root cannot take that write (#791);
`check_control_units` and `control_units_owner_dir` did not, and each kept its own `/etc` default.
On a provisioned box `doctor` therefore reported "no runner units are installed" about units that
were installed and running. That verdict is the `doctor` half of `pithead-boot`'s health gate, so
the gate never passed, the A/B slot was never committed, and the dashboard sat on "reboot pending"
after an update that had in fact succeeded. #1065 makes the first such boot reboot the box; the
counter is bounded and only a passing gate clears it, so from the second failure on the machine
deliberately stays up — a healthy, correctly updated appliance parked on an uncommitted slot with
no way to clear it but a power cycle. Legs 1-3 of the battery cannot see this: they never provision
the guest, so `pithead-boot` is condition-skipped and the gate never runs at all, and they commit
with the harness's own `rauc status mark-good`. Leg 4 is the only leg that provisions and then lets
the boot gate do the committing, and it found this the first time it ran to completion. The
directory is now one rule, `control_unit_dir`, read by the writer and both readers.

**Fixed — a provisioning failure now surfaces its own reason on the reopened wizard.**
Setup failures keep the config, copy it to `config.json.failed` and re-mint a token; the
reopened page used to make an operator dig the reason out of the console. It no longer
does: `pithead` writes the last `[ERROR]` line to `error.txt` and the failed config to
`last-attempt.json` before reopening, and `wizard.py`/`wizard.mjs` surface both — the
reason as the page's error text, the config as the retry prefill.

**Fixed — a failed setup no longer costs the machine its configuration (#1059).** It used
to move `config.json` aside, and delete it outright when that move failed. A non-zero
`setup` does not mean the submitted configuration is at fault: the capture that found this
was a concurrent `backup` stopping the stack under an in-flight `compose up`, on a config
that had already rendered `.env`, provisioned Tor and started containers. Moving it aside
existed to re-arm the setup wizard, and it could not — `pithead-firstboot.service` needs
both `config.json` and `machine-role` absent, and `record_machine_role` has already run by
then. So the machine keeps its configuration, takes an owner-only copy beside it, and
removes the original only where doing so genuinely re-arms the wizard: a `machine-role`
that never landed.

**Fixed — the hugepages reservation now fits the machine's RAM (#977).** The baked 6 GiB
sysctl imposed a silent ≥ 16 GiB floor the harness's 16 GiB VM could never notice.
`pithead-hugepages.service` now sizes the pool every boot before either boot owner:
full 3072 pages on a supported machine, 2560 below 15 GiB (the smallest pool holding
BOTH RandomX datasets — p2pool's ~2.3 GiB dataset falling out of hugetlbfs lands in its
1 GiB cgroup cap and OOM-loops, the load-bearing finding from the #78 spike), zero
below 7 GiB where the stack cannot run regardless. Degrades are announced on every
console, journaled, and repeated by `doctor` as a WARN — never a FAIL, so the A/B
commit gate still commits a degraded-but-serving slot. Running before the boot owners
is not what makes the decision hold: pithead's own later writers grow the pool too, so
the `/run` marker records the chosen page count and both of them honour it — setup's
kernel optimization caps its grow at the recorded pages, and the local-miner render
hands RigForge the recorded reservation, never the baked 6 GiB, as its headroom.

**Fixed — a boot-time race could reserve 11 GiB of HugePages on a 16 GiB machine (#1103).**
The miner's config declares the stack's reservation as headroom, and RigForge sizes the pool as
`current + required - available`. A co-resident holding pages at that instant is subtracted from
available while the same pages already sit inside required, so they are counted twice. Measured on
the bench: p2pool holds 1296 pages for about six seconds while it allocates its RandomX dataset,
the sync gate then stops it and it releases them. Whether the box over-reserves depends on whether
RigForge's setup lands inside that window — two consecutive boots of one image gave 5618 pages and
4322 pages, each persisting until the next reboot. The render now declares a pool ceiling of
9216 MB alongside the headroom, which bounds the pool whoever wins the race. Re-ordering the units
was rejected: it would make the common case correct and leave the failure intact under load.

The ceiling is declared only where it is honoured. RigForge ignores a config key it does not know,
warning rather than failing, so declaring the ceiling into a tree older than v1.16.0 would leave a
configuration that reads as bounded and behaves as it did before. The render reads the version of
the tree it is handing the file to and declares nothing when it cannot confirm the floor.

It is declared only on the full tier, too. The reduced tier still refuses co-location outright, and
the bench measured why that refusal should stay: lifting it by hand had RigForge ask for 6146 pages
(12.0 GiB) on a 7.76 GiB box, the kernel grew the pool from 2560 pages to 2916 — 356 new pages of
the 3586 it was asked to add — available memory fell to about 40 MB,
and RigForge exited zero reporting a completed deployment. Nothing on the box named the shortfall.
There is no ceiling value that helps on that tier — anything at or below 5120 MB is at or under the
pool the boot already sized, so nothing is written at all, and anything above it is drawn from the
roughly 700 MB the machine has spare.

The ceiling is a single-node value, and the render checks for that too. RigForge sizes the
fallback reservation as `1168 * nodes + threads + 50 + headroom`, where only the first term scales
with the machine's NUMA node count. On a two-node box the requirement is 5464 pages — above the
9216 MB ceiling — so declaring it there would cap a healthy machine short, and RigForge caps the
write and carries on rather than failing, which would make the shortfall silent. The render reads
the node count the same way RigForge does, preferring `lscpu`, then the kernel's own node entries,
then the socket count, and declares nothing when it reads more than one node. Node count is not
socket count in either direction: the bench guest reports four sockets and one node.

**Still open on #1103:** whether a co-located miner on a reduced-RAM box mines usefully or thrashes
is unanswered. Answering it needs synced chains rather than another KVM guest, because the sync gate
holds the stratum the miner dials.

**Fixed — the hugepage pool had a second writer, and the ceiling bounded only the first (#1724).**
The ceiling above is declared to RigForge, so it binds the sizer's write. The miner is a writer too:
the unit runs as root, and before every large-page allocation xmrig itself raises `nr_hugepages`
through sysfs whenever free pages fall short of what it wants — the per-node file first, then the
global one, never the sysctl. The #1103 bench watched the pool go from the baked 3072 pages to 4608
with the sizer out of the path, and every miner start also asks for a 1 GiB pool the sizer never
touches. The image now ships a systemd drop-in for the miner unit that makes both hugepage subtrees
read-only to it, so a refused write leaves the miner to fall back to the next page size, which it
already does when the kernel declines. The two subtrees are named on purpose: on the systemd this
image carries, the blanket kernel-tunable protection left `/sys` writable, and so did a read-only
path over `/sys` as a whole. The node and hugepage counters stay readable, because the miner reads
that tree to detect NUMA nodes.

**Fixed — a restored coordinator strands dark instead of provisioning itself (#1239).**
Live KVM guest evidence: `pithead-firstboot` lands a restored archive (`consume_preseed_restore`
or the wizard's spool channel) and calls `setup()`, but the archive's `.env` is the SOURCE
machine's own — it carries that machine's `DEPLOYMENT_COMPLETED=true`. `setup()`'s headless
`is_deployed` guard (#924) read that literally, could not tell "restored, never provisioned on
THIS hardware" from "already live", and fatally refused with no tty to ask: `podman ps -a` on
the live guest showed zero containers, ever. `restore_apply` — the one commit point both restore
doors share — now clears the carried marker right after landing the archive, before its caller's
`setup()` runs; every other restored value (onion keys, tokens, `HOST_IP`) still rides through
untouched, and a full `.env` re-render happens inside `setup()` anyway. The guard itself is
unchanged and still refuses a headless re-run on a genuinely live box (its own #924 test stays
green) — `stack_restore` (the admin `./pithead restore` command, for a box already deployed on
its own hardware) never calls `restore_apply` and keeps its completion marker exactly as before.
Separately evaluated and left alone on purpose: `pithead-boot.service`'s
`ConditionPathExists=|/data/pithead/config.json` is evaluated once, at the start of this same
boot, before `pithead-firstboot` writes `config.json` — so the boot-health-gate/RAUC-commit unit
never runs on the boot that provisions the machine, restored or fresh alike. This is not new
and not restore-specific: every first-time provisioning already reaches a running stack through
`setup()`'s own direct `stack_up` call, never through `pithead-boot`, so the A/B slot's own
health-gate commit has always landed on the *next* boot rather than the provisioning one. The
dashboard and the whole stack are live on the provisioning boot regardless — nothing is dark or
stranded waiting for that reboot — so bolting a same-boot restart of `pithead-boot.service` onto
just the restore path would fix nothing restore-specific and leave the identical timing on every
fresh setup. See [Recovering from a backup](../docs/appliance.md#recovering-from-a-backup) for
the operator-facing contract this restores.

## Open

- **Installing to a disk still needs a human (#979).** Pre-seeding (`pithead-token.txt` /
  `pithead-config.json` on the ESP) covers configuration headlessly and the installer carries
  both onto the target, so a fleet can be flashed and provisioned from one file. Choosing
  which disk to erase is deliberately NOT automated — an unattended installer that picks a
  disk itself will eventually pick the wrong one. A pre-seeded target would need to name the
  disk by serial, not by `/dev/` path, and that is unbuilt.
- **Part of the host-CLI surface is still unreachable on the appliance (#786).** The GA
  trio closed the sharpest losses: dashboard backup export (#908), restore at setup
  (#909), and the media config channel (#910) — which also carries the settings the
  dashboard never exposes, so "changing these later means reinstalling" no longer holds.
  What remains rides the post-GA fast-follows: out-of-band approval at the commit gate
  (#911), fleet descriptor editing (#912), and the CLI remainder on the dashboard (#913).
- **The dashboard OS-update action is built but not yet battery-proven (#976).** The
  user-reachable path exists: an OS-update control in the dashboard header drives
  check → resumable Tor download to `/data` → local verification (signature,
  `compatible`, downgrade/floor) → slot install → an explicit confirmed reboot, with
  the boot health gate committing and a persisted verdict banner after. Every verb is
  host-side through the control channel and refuses off the appliance; the DIY
  one-click upgrade still refuses on the appliance (a tarball upgrade would silently
  revert at the next boot). What remains before this line moves to Resolved: the
  battery's `phase_update` leg 4 (the dashboard-driven A/B cycle, resume, and the
  refusals) and the `provision` presence check must pass on the KVM bench.
- **The manual hardware battery has not been run.** Everything above is KVM. Secure Boot,
  real disks, headless discovery and a genuine power cut are exactly what a VM cannot
  show — M1-M10 in the release doc must pass on a physical box before an image ships.
- **Only the wizard image is baked in (#978).** The rest of the stack still pulls at
  provision time, so the plan's "first boot works offline" property is partial: the setup
  page works without a network, provisioning does not. Baking the full set roughly triples
  the image and inflates every update bundle — sized deliberately, not forgotten.
