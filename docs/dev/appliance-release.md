# Releasing Pithead OS

How the appliance is built, tested, released, and rolled back. The DIY channel keeps its
own process in [`releasing.md`](releasing.md) — this document covers only
`pithead-os`, and the two share a version number and a release manifest.

The wizard's own contracts — the stage machine and the certificate lifecycle — are in
[`appliance-wizard.md`](appliance-wizard.md); read that before changing anything it touches.

The updater is RAUC. The evidence for that choice, and the five defects the decision
cost, are in [`dual-distribution-plan.md`](dual-distribution-plan.md). The rejected
Rugix candidate is preserved on the `reference/rugix-candidate` branch.

## What gets built

| Artifact | Built by | Contents |
|---|---|---|
| `os/build/pithead-root.tar` | `os/build-image.sh` | the OS as a container build, exported |
| `pithead-os-vX.Y.Z.img` | `os/rauc/mkimage.sh` | bootable image: ESP + slot A only |
| `pithead-os-vX.Y.Z.raucb` | `os/rauc/mkbundle.sh` | signed A/B update bundle |

The image carries **only the ESP and slot A**. Slot B and `/data` are created by
`systemd-repart` on first boot, sized to the machine's real disk — so a 5 GB image (636 MB of it
real data) becomes a full A/B appliance on whatever hardware it lands on, and `/data` fits a 250+ GB
chain instead of the image. The layout is declared once in `os/rootfs/repart.d/`.

The image also carries no installer payload. `pithead-install` rebuilds the layout on the
target and copies the running slot, so the artifact never contains a compressed copy of
itself.

### Host tuning baked in

An unattended headless box has to heal itself, and two of the guards live below the container
layer where `restart:` policies and `panic=60` cannot reach:

- **systemd watchdog.** `/etc/systemd/system.conf.d/pithead-watchdog.conf` sets
  `RuntimeWatchdogSec=20s`, so systemd feeds `/dev/watchdog` and the platform watchdog
  hard-resets the machine if PID 1 stops pinging — the soft-hang case, where nothing panicked and
  no container died but the box is wedged. `RebootWatchdogSec=2min` keeps the watchdog armed
  through shutdown, so a reboot that itself hangs still resets. 20 s is chosen to survive a
  RandomX-loaded stall without a false reset while still self-healing in under a minute. On
  hardware with no watchdog device — a KVM guest, most bench boxes — the setting is a safe no-op;
  real appliance boards expose one and this is where it earns its keep.
- **CPU governor.** `pithead-cpu-governor.service` sets the `performance` governor every boot, so
  the node, wallet, and any built-in miner run at full clock. A co-located RigForge miner sets the
  same `performance` value from its own service; the two agree, and this only establishes the
  baseline earlier and covers the miner-disabled box. It is a no-op where there is no cpufreq to
  steer.

Both are asserted by `tests/os/verify-image.sh` — the config is checked into the built rootfs, not
the runtime effect (CI has no real watchdog device to trip).

## Build variants and the variant stamp

Every build is one of two variants, decided by whether the rootfs bakes an SSH key
(`PITHEAD_TEST_SSH_PUBKEY` at build time):

- **release** — shell-less. No key, sshd disabled, the dashboard is the only management
  surface. The only variant that ships.
- **debug** — the bench build: a root SSH key baked, sshd enabled. Never publish one;
  `verify-image` without `--test` refuses it.

The variant is stamped into the artifacts so tooling can tell them apart after the build:

| Where | What |
|---|---|
| `/etc/pithead-variant` | in the rootfs — the running system and every installed slot carry it |
| `[meta.pithead] variant=` | in the update bundle's manifest — `rauc info` shows it before anything is installed |

`verify-image` asserts the stamp matches the mode it runs in: `--test` expects `debug`,
no flag expects `release`.

The stamp exists because the debug→release transition is one-way and used to be silent: a
debug box that installs a release bundle drops SSH by design — the channel that drove the
install — and recovery needs a console. This happened live on the bench and ended in a
stick reinstall. `pithead os-update BUNDLE` is the install path that reads both stamps and
warns before making that transition, requiring a y/N confirmation (or `--yes`). A bare
`rauc install` bypasses the guard; use it only when you have already decided the SSH loss
is acceptable.

## Compatibility metadata and the data-migration floor

The bundle manifest's `[meta.pithead]` section carries the compatibility contract the
update path reads back before it installs:

| Field | Meaning |
|---|---|
| `version` | the OS version this bundle carries (from `VERSION`) |
| `data_migration` | `true` if this release runs a forward-only `/data` (lmdb) migration |
| `minimum_os_version` | the lowest OS version that can still read `/data` once it has migrated |

Two guards consume them, because a correctly-signed bundle is not automatically a safe one:

- **No signed downgrade.** `os-update` installs without confirmation only a clean `X.Y.Z`
  release whose `version` is at or newer than the running OS. It fails **closed**: an older
  bundle, a pre-release/`-prep` version, garbage, or an absent stamp is not proof of safety
  (an older image re-introduces the holes the newer one fixed, carrying our own valid
  signature), so any of them is refused unless `--allow-downgrade` is passed on purpose.
  The check is skipped only when the box cannot read its *own* version — a source checkout,
  never a provisioned appliance. (Deliberate A/B rollback is unaffected — `rauc status
  mark-bad booted` boots the spare slot already present; it does not re-install an old bundle.)
- **No rollback below the migration floor.** When a `data_migration` bundle installs,
  `os-update` records its `minimum_os_version` as a floor on `/data` (`.os-data-floor`). Once
  a floor file exists it is authoritative and fails **closed**: an OS below it, a bundle whose
  version can't be parsed, *or a corrupt floor file itself* is refused **outright** —
  `--allow-downgrade` does not override any of these, because the migrated chain data is
  unreadable there and the failure is silent data loss, not a policy preference. The escape is
  a factory reset (loses the chain) or restoring a backup taken on a version at or above the
  floor.
  The floor is raised at install time, before the migration runs, and the migration itself
  waits for the slot to commit (#851) — so a migrating bundle that fails its boot gate falls
  back with the data untouched and the floor already raised. `os-update` therefore records the
  floor it replaced (or `none`) in `.os-data-floor.prev` before raising, and the fallback boot
  puts the floor back from that record and removes it; a box with no record keeps its floor,
  since a floor is never lowered without one. Until the old slot carries that boot logic, the
  guard tells the truth about the state instead: a floor above the running version means the
  migration never ran (or the slot was installed outside `pithead`), the floor version or newer
  installs, and nothing needs resetting or restoring for it (#1393).

**The data-migration contract for release authors:** a release that ships a forward-only
schema bump MUST declare it, or a later rollback silently strands the migrated chain data.
Build the bundle with both fields set:

```bash
PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION=X.Y.Z os/rauc/mkbundle.sh ...
```

`X.Y.Z` is the lowest OS version whose monerod/tari can still read `/data` after the
migration — normally this release's own version. `mkbundle.sh` refuses to build a
migrating bundle without it.

**The migration hold — how a flagged update boots.** Installing a `data_migration` bundle
also leaves a marker on `/data` (`.os-migration-pending`, stamped with the bundle's
version). On the next boot, `pithead-boot` sees a marker matching its own version and
brings the stack up **without** the chain services (monerod, tari, and their wallets — the
holders of forward-only lmdb migrations): the A/B commit decision is made on everything
else first. `doctor` reads the same marker and judges the deliberately-held chain
containers by the sync-hold rule, so the commit gate gates on what is running instead of
deadlocking on the hold. Only after `mark-good` does the boot path remove the marker and
run a plain `up` — the chain services start, and the migration runs on a slot a fallback
can no longer leave. That `up` is retried, five times ten seconds apart by default: compose
aborts the whole start when one container is mid-transition at that instant, and a
passenger container's restart must delay the chain start by seconds, never veto it until
the next reboot. If every try fails the boot still finishes — the slot is committed and
nothing can undo that — and the journal carries one `FAULT` line saying the chain services
did not start and the migration has not run, with the recovery: `./pithead up` from
`/data/pithead`. If health fails instead, the slot stays uncommitted, the machine
falls back, and the old OS boots normally — its data was never touched (the old boot path
ignores a marker for a version it isn't). A non-migrating install clears any stale marker.
The `db_schema` field the plan also lists stays out until something reads it — an
unread manifest field is a claim, not a contract.

## Development loop

Everything runs from the repo root on a Linux box with docker, KVM and libvirt. The
bench is the KVM-capable build box; a laptop cannot run this (`/dev/kvm` is required).

```bash
os/build-image.sh --ssh && sudo os/rauc/mkimage.sh --dev
```

`--dev` auto-generates a throwaway `CN=pithead-dev` signing key for the bench. A release build
omits it and must name the real key instead (`PITHEAD_RAUC_CERT` + `PITHEAD_RAUC_KEY`) — see
[Cutting a release](#cutting-a-release) and the key custody runbook in
[`release-server.md`](release-server.md#the-rauc-update-signing-key). The guard is what stops a
throwaway dev cert from becoming the fleet's update trust root.

Two build variants, chosen by one flag:

- **Release** (the artifact that ships): no flag. Shell-less — sshd stays disabled and no key
  is baked; `tests/os/verify-image.sh` refuses test material in this variant.
- **Debug/bench** (`--ssh [PUBKEY_FILE]`): bakes the given public key (default: the builder's
  own `~/.ssh/id_ed25519.pub`) as root's authorized key and enables sshd, for benches driven
  over SSH. Verify with `tests/os/verify-image.sh IMAGE --test`. A bench that takes an A/B
  update to a *release* bundle loses SSH — deliberate, and worth remembering before pressing
  install.

The updater defaults to RAUC; an image built without it cannot take another update, and the
only way to get one now is to set `PITHEAD_UPDATER` to something else on purpose.

### Updating a bench over SSH, and the signing trap that stops you

A bench appliance can be moved to a new build entirely over SSH — copy the bundle to it and run
`pithead os-update BUNDLE`, then reboot. No USB, no console, and `/data` is never touched, so a
synced chain survives. This is proven on the physical bench: a full A/B update installed and the
machine came back on the new slot with its chain intact.

The trap is signing. **`--dev` generates the throwaway chain once per checkout and reuses it after
that** (`os/rauc/certs/`, gitignored — `resolve_signing_material` in `populate-slot.sh` only
generates when nothing is there yet). So a `--dev` bundle installs on any machine whose keyring
came from the *same checkout*, but a different checkout — a second clone, a fresh CI workspace, a
`certs/` directory you deleted — starts with no cert and generates its own, different chain on
its first `--dev` run. Point a bundle at a machine whose keyring came from a different checkout
and RAUC refuses with `signature verification failed: Verify error: self-signed certificate`. To
update a bench you built from another checkout, name that checkout's chain instead of generating
a new one:

```sh
PITHEAD_RAUC_CERT=<build>/os/rauc/certs/cert.pem \
PITHEAD_RAUC_KEY=<build>/os/rauc/certs/key.pem \
  os/rauc/mkbundle.sh          # no --dev: naming the key IS the signal
```

Confirm before copying anything, by comparing fingerprints — the target's trusted chain is at
`/etc/rauc/keyring.pem`:

```sh
openssl x509 -in /etc/rauc/keyring.pem -noout -fingerprint -sha256
```

Check the variant first as well: an update from a debug build to a release bundle removes the SSH
channel you are driving it over, and `--yes` skips the guard that would have asked.

The rootfs Dockerfile deliberately keeps its `apt-get update` layer cached across later install
steps (layer economy); on a warm builder cache that layer can outlive a mirror rotating a
package, and the install then 404s on a package the stale index still thinks exists. Rerun with
`os/build-image.sh --fresh-index` to bust only that layer — `build-image.sh` prints this same
remedy when it recognizes the 404 signature in a failed build's output. (#929; snapshot.debian.org
pinning is a deliberate non-goal here, tracked as a follow-up for full build reproducibility.)

Then the tiered battery, lowest tier first — the same rule as
[`testing-strategy.md`](testing-strategy.md):

```bash
sudo tests/os/run.sh --phase boot --image os/rauc/build/system.img
```

`--phase update` and `--phase fault` build their own v1/v2 images and need no `--image`.
`--phase all` runs all eight — boot, update, install, provision, rig, media, fault and reset.
Expect roughly 25 minutes per phase, most of it image builds, so budget an evening rather
than a coffee break. It ran five of the eight until #1064, which meant a cut that followed
this page ran none of the destructive phases: the power cuts, the corrupt-bundle refusal, the
factory reset, the wedged-`/data` recovery and the whole media channel. Record the dated
per-phase pass count in the release issue for the tip actually being cut — an old green
standing in for a new one is the same defect wearing a different hat.

Two harness rules worth knowing before you lose an afternoon to them:

- It **refuses to run** when another `pithead-*` domain is defined on the bench. A stray
  VM takes the DHCP lease the harness reads back, and the battery then drives the wrong
  machine and reports passes that mean nothing.
- On failure it keeps the guest console at `/tmp/pithead-os-serial.log.failed`. Read it
  first. `/dev/console` is whichever `console=` came **last** on the kernel cmdline, so
  check which one you are reading before concluding a component is silent.
- A failed dashboard-driven install (update phase, leg 4) also keeps the guest's own
  account at `/tmp/pithead-os-serial.log.leg4-install`: the root runner's own journal
  (`pithead-control.service`, where its "OS install failed" warning and log tail land),
  the boot journal's rauc and OS-install lines, `rauc status`, disk and memory, and any
  OOM kill. It reads the current boot only: if the install took the guest down, the
  serial log above spans the reboot. The runner deletes its install log on failure and
  the dashboard result carries at most rauc's last error line, or nothing, so this file
  is the only place the cause survives.

## The automated battery

`tests/os/run.sh` is a **release gate**, not a spike artifact. It found every defect in
the updater bake-off, three of which had already survived multiple passing runs, and it
is the only thing standing between the hand-written boot path and a fleet.

| Phase | Asserts | Count |
|---|---|---|
| `boot` | EFI boot to userspace; first-boot wizard announces itself with a console token; wizard serves the token gate on `:80`; machine-id is STABLE across a plain reboot (#895 — an empty-baked id with no restore mechanism regenerates on every boot, worse than the bug it fixes) | 4 |
| `update` | `/data` grew to the disk and slots did not (#784); bundle installs into the spare; spare boots; **an uncommitted update reverts on reboot**; a committed update persists; **after the commit, the page served comes from the NEW dashboard image** (marker baked into the image and read back over HTTP — the tag never changes, so "containers run" proves nothing about staleness, #798); an operator can roll back off a committed version; **host identity (SSH host-key fingerprint, machine-id) survives the A/B swap** (#894/#895 — both live on `/data`, untouched by a slot swap). Then leg 4, **the dashboard OS-update action end-to-end** (#976): the machine is provisioned through the wizard's real HTTP flow, the release lookup is pointed at a bench-local server through the root-owned test seam, and the flow runs check → download (a pre-staged partial must RESUME, not restart) → verify — with the `/data`-floor and **bad-signature refusals proven against RAUC's real keyring**, refused bundles deleted — → install (in-flight flag armed, state says reboot-pending, nothing auto-reboots) → the explicit reboot intent → the new slot boots, the health gate commits, and the persisted **"updated" verdict reaches `/api/state`** | 15 + leg 4 |
| `provision` | a config submitted through the wizard's real HTTP flow (token read from the console, exactly as a human would) provisions the stack: validation, cosign-verified image pulls, containers running under podman, dashboard served through caddy. The submitted config also enables the on-box miner, so the **built-in RigForge worker** must come up on its own, wired to the machine's own stratum, with mining held behind the sync gate *cleanly* — a fresh guest cannot sync a chain, so the gate's hold is the correct state, and a p2pool that crashes instead of being held (a checksum-invalid wallet does exactly that, #829) fails the leg. The accepted-share end of the chain needs a synced node, so it lives in the bench release e2e, not here. Then a **reboot with no hands on it** — the stack must return unaided through `pithead-boot` (load baked images, render the derived layer, compose up, health-gated slot commit, then the local-miner leg), the failure mode being a miner that sits dark after every power blip. The Caddyfile is corrupted and the archive digest records dropped before the reboot on purpose: derived things are regenerated every boot, and a stale one killed TLS on hardware. Finally the **commit gate's honesty** (#852): the real gate is `pithead doctor --json`, so it must PASS on the healthy still-syncing stack yet REFUSE once a revenue service is crashed (monerod stopped) — the mining-dead-but-serving slot a curl-only gate used to commit. Catches an appliance whose engine cannot run the product — which happened, invisibly to every other phase. The provisioned boot also pins the **hugepages sizing no-op** (#977): the full 3072-page pool intact, the sizing unit active, and no degraded marker on the 16 GiB guest — the degrade tiers themselves are tier-1 | 24 |
| `install` | the image boots as **removable** media (usb bus — the gate keys on it); the inventory offers the internal disk and never the boot medium; the real installer runs; the machine then boots from the target alone with a **complete** copy (`/var/lib/dpkg` — the overlay made an incomplete copy easy and invisible), a fresh machine-id, `/data` sized to the target, and the wizard serving. Then the **reinstall leg**: a sentinel planted in `/data`, a second install over the same disk, and the sentinel required afterwards — the chain-preserving promise, tested. The keep leg reinstalls from a **newer stick** over a `/data` that already holds the old dashboard image and its digest record: the image ID must change and the page served must come from the newer image (#798) | 33 |
| `fault` | three power cuts mid-write; a deliberately corrupted bundle is refused without crashing and without bricking; a power cut inside the commit window; operator rollback after all of it; the box is still updatable afterwards | 11 |
| `reset` | leg 1, the real `pithead factory-reset` off a provisioned machine: it comes back unprovisioned at the wizard, the config is gone, the container store holds no pulled stack images, machine-id and the SSH host key are **fresh** (a handed-over box must not keep the old owner's identity), and the wipe is recorded on the ESP — a wiped machine must be tellable from a brand-new one (#1062). Leg 2, the wedged-`/data` recovery: the ext4 magic corrupted on the real data partition, the box comes back usable with **`/data` repaired, not erased** — a sentinel planted before the corruption must survive (#1087) — and the ESP wipe log must not grow, because a repair recorded as a wipe would cry wolf | 17 |

A **brick is disqualifying, not deducted** — any run that leaves a machine unable to boot
fails the release regardless of the rest.

## Manual battery — required before every appliance release

The automated battery runs in KVM. KVM is not hardware, and the failures it cannot see
are exactly the ones that strand a user: real firmware, real disks, real NICs. Run this
on a physical box before publishing an image. Record the results in the release issue.

Hardware: one x86-64 machine with UEFI, ≥ 16 GiB RAM, an internal SSD/NVMe, wired
ethernet, and a USB stick. A second disk makes M4 and M5 meaningful.

**M1 — flash and boot.** Write the image to the USB stick. Boot the target from it with
Secure Boot **enabled**, then again **disabled**. Expected: reaches userspace both times,
or fails with a legible message on Secure Boot rather than a blank screen. *KVM cannot
see this: the harness disables Secure Boot because our GRUB is unsigned.*

**M2 — discovery.** Read the token from the console, then find the box from another machine
at `http://pithead.local` and at the IP it printed. Expected: both load the token gate, and
the machine stays reachable by name after the monitor is unplugged.

Note what this case does **not** prove: the install is not headless today, because the token
exists only on the console. A monitor (or serial line) is required at least once. Pre-seeding
the token or a whole config from the stick's FAT partition is the fix, and it is not built —
see KNOWN-ISSUES.

KVM analog: `--phase install` automates the mechanics of M3 and M5 (inventory, guards,
copy completeness, target boot, and reinstall preserving `/data`). The manual cases remain
about what KVM cannot fake — real firmware's boot order, a real USB controller, and a real
internal disk.

**M3 — install to disk.** From the browser, choose the internal disk. Confirm that the
USB stick itself is **not offered**, that no disk is preselected, and that model, size and
serial are shown. Type the disk name, install, reboot, remove the stick. Expected: the
machine boots from its internal disk and serves the setup page again.

**M4 — the wrong-disk guard.** With a second disk present holding unrelated data, confirm
it is listed as "will be erased" and that installing to the *other* disk leaves it
untouched.

**M5 — reinstall preserves the chain.** Re-run the installer against a disk that already
holds a Pithead `data` partition. Expected: listed as "reinstall, keeps existing data",
and `/data` survives with its contents. *This is the one that costs a user days of
re-syncing if it is wrong.*

**M6 — configure by paste.** Answer **yes** to merge-mining so the Tari address is asked at
all, then complete the wizard using copy/paste for both addresses.
Confirm a pasted **subaddress** (`8…`) is rejected with an explanation before submitting.
Expected: the stack provisions and the dashboard comes up.

**M7 — real update.** Build a `v+1` bundle, copy it to the machine, and install it with
`pithead os-update BUNDLE` (the test image carries SSH for exactly this; the command wraps
`rauc install` and compares the variant stamps first — a debug box taking a release bundle
must warn before removing its own SSH). Expected: installs, reboots into the new version,
and an uncommitted update reverts on the next reboot, which `pithead-boot` now triggers itself
after a failed health gate (#1065). The dashboard-driven OS update rides
the same mechanism from the header's OS-update control
([Dashboard › Updating the appliance OS](../dashboard.md#updating-the-appliance-os)); the
KVM update phase's leg 4 drives it end-to-end, so this manual step stays about what KVM
cannot show — real firmware and a real disk under the slot write.

**M8 — pull the plug.** During the update's write phase, physically cut power. Repeat
three times. Expected: the machine boots the old version every time. *A brick here blocks
the release.*

**M9 — bad release rollback.** Ship a deliberately broken bundle (a failing health check).
Expected: the machine reverts to the previous version without a human present. Then
perform an operator-initiated rollback from a good version and confirm it returns.

**M10 — power-loss during normal mining.** Cut power at the wall with the stack running
and synced, then restore it and **do not touch the machine**. Expected: it powers on by
itself, the chain is intact, and mining resumes.

The "by itself" half is the part that gets skipped, and it is the half that matters for an
unattended miner. It depends on a firmware setting — Restore on AC Power Loss, or whatever
the board calls it — that defaults to staying off on most hardware. Confirm the setting is
part of the setup instructions and that the machine really does return unaided; a box that
needs a human to press a button after every outage is not an appliance. This was found the
obvious way: a mains outage took the build bench down overnight and it was still dark in
the morning.

## Cutting a release

The branch mechanics are the DIY doc's ([releasing.md](releasing.md#branch-mechanics)): the cut
runs from the release-prep commit on `develop`, and `main` fast-forwards to the tag only when
`release.sh` publishes it. The steps here run from that same prep commit; both channels share
one version and one GitHub Release.

1. The release commit is green: `make lint && make test`, and `tests/os/run.sh --phase all`
   on the bench. `make lint-sh` refuses to run on any shellcheck but the pinned one and names the
   version it found alongside the one it wants; `make -s print-shellcheck-version` prints the pin.
   A distro build reports different findings over the same files, so a skew reds the cut for
   nothing — install the pin from [`release-server.md`](release-server.md#the-lintrelease-toolchain).
2. Bump `VERSION`. The tag is `v<VERSION>` and every artifact derives from it —
   `STACK_VERSION` is the single place the registry tag comes from.
3. Build the image and bundle with the **release key**, never the throwaway `--dev` chain. Point
   both `mkimage.sh` and `mkbundle.sh` at it and omit `--dev` — a release build refuses to run
   without an explicit key, so there is no silent-dev-cert path:

   ```bash
   export PITHEAD_RAUC_CERT=~/.config/pithead-release/rauc-signer.pem
   export PITHEAD_RAUC_KEY=~/.config/pithead-release/rauc-signer.key
   os/build-image.sh && sudo -E os/rauc/mkimage.sh && sudo -E os/rauc/mkbundle.sh
   ```

   Key generation, storage, the trust model and the rotation runbook are in
   [`release-server.md`](release-server.md#the-rauc-update-signing-key), mirroring the cosign
   section beside it. Then verify the artifact, pinning the commit you meant to build:

   ```bash
   PITHEAD_EXPECT_COMMIT=$(git rev-parse HEAD) sudo tests/os/verify-image.sh <image>
   ```

   Run it **from the repo checkout you built**, because it compares the artifact against these
   files: the shipped `pithead`, compose file and config reference must be byte-identical to the
   tree, and the baked container archive is unpacked to confirm it carries this tree's
   `wizard.py`.

   All of that exists because a release build once shipped a dashboard two commits stale — the
   release clone was pulling from an intermediate clone rather than origin, so `git pull`
   succeeded and fetched nothing. The image passed every check that existed, behaved like the
   previous build, and reached a bench. The commit stamp catches a stale *tree*; the comparisons
   catch a stale *artifact*, including inside the container image, which is where it hid. It mounts the artifact
   and checks everything a green boot cannot prove: no test SSH key or marker shipped, the
   grubenv sits where `load_env` reads it, the kernel root is a probed PARTUUID, all six
   docker-export artefacts are fixed, the engine bridge and cosign are aboard, and
   pithead-boot is enabled (and podman-restart is NOT — it started the stack into its own
   oneshot cgroup and systemd SIGKILLed the containers it had just spawned). Every check exists because its absence shipped, or nearly
   shipped, once.
4. Run the manual battery (M1–M10) on real hardware. Record results. The human half of a
   release — every check no harness can make, and the traps that have actually bitten — is
   collected in [the manual release checklist](manual-release-checklist.md); walk it alongside
   this list.
5. Attach image + bundle + checksums to the version's GitHub Release **while it is still a
   draft** (the DIY cut opens it with `release.sh --draft`), then publish once everything is
   attached. Published release assets are immutable — v1.18.0 burned its tag this way — so
   the release publishes exactly once, with both channels' artifacts aboard. The bundle's
   signature is what devices verify.
6. `main` fast-forwards to the tag automatically when `release.sh` publishes; if the push was
   refused, run the command it prints (see
   [After publishing](manual-release-checklist.md#after-publishing)).

## Shipping a bad release

Covered in full by the bad-release runbook in
[`dual-distribution-plan.md`](dual-distribution-plan.md). The short version, because it is
the thing you will want at 3am:

- **It does not boot** — the machine reverts itself. An uncommitted update never survives
  a reboot; this is the case the A/B design exists for and it needs no operator.
- **It boots but fails its health check** — `pithead-boot` does not commit and reboots the
  machine itself, so the fallback happens with nobody present (#1065). Exactly once: if the
  slot it falls back to fails the same way the fault is on `/data`, not in the slot, and the
  machine stays up with the reason in the journal instead of looping. Publish a fixed
  version; the fleet takes it on the next update.
- **It boots, passes its checks, and is still wrong** — this one is on us, not the
  updater. Publish `v+1` with the fix. An operator who already committed rolls back from
  a root shell with `rauc status mark-bad booted && reboot`; the dashboard has no button.

What bounds the damage in every case: `/data` is never touched by an update. Wallets,
config and the synced chain survive a rollback, a bad release, and a factory reset of the
system slots.
