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

## Development loop

Everything runs from the repo root on a Linux box with docker, KVM and libvirt. The
bench is `gouda`; a laptop cannot run this (`/dev/kvm` is required).

```bash
os/build-image.sh && sudo os/rauc/mkimage.sh
```

Then the tiered battery, lowest tier first — the same rule as
[`testing-strategy.md`](testing-strategy.md):

```bash
sudo tests/os/run.sh --phase boot --image os/rauc/build/system.img
```

`--phase update` and `--phase fault` build their own v1/v2 images and need no `--image`.
`--phase all` runs everything. Expect roughly 25 minutes per phase, most of it image
builds.

Two harness rules worth knowing before you lose an afternoon to them:

- It **refuses to run** when another `pithead-*` domain is defined on the bench. A stray
  VM takes the DHCP lease the harness reads back, and the battery then drives the wrong
  machine and reports passes that mean nothing.
- On failure it keeps the guest console at `/tmp/pithead-os-serial.log.failed`. Read it
  first. `/dev/console` is whichever `console=` came **last** on the kernel cmdline, so
  check which one you are reading before concluding a component is silent.

## The automated battery

`tests/os/run.sh` is a **release gate**, not a spike artifact. It found every defect in
the updater bake-off, three of which had already survived multiple passing runs, and it
is the only thing standing between the hand-written boot path and a fleet.

| Phase | Asserts | Count |
|---|---|---|
| `boot` | EFI boot to userspace; first-boot wizard announces itself with a console token; wizard serves the token gate on `:80` | 3 |
| `update` | `/data` grew to the disk and slots did not (#784); bundle installs into the spare; spare boots; **an uncommitted update reverts on reboot**; a committed update persists; **after the commit, the page served comes from the NEW dashboard image** (marker baked into the image and read back over HTTP — the tag never changes, so "containers run" proves nothing about staleness, #798); an operator can roll back off a committed version | 13 |
| `provision` | a config submitted through the wizard's real HTTP flow (token read from the console, exactly as a human would) provisions the stack: validation, cosign-verified image pulls, containers running under podman, dashboard served through caddy. Then a **reboot with no hands on it** — the stack must return unaided through `pithead-boot` (load baked images, render the derived layer, compose up, health-gated slot commit), the failure mode being a miner that sits dark after every power blip. The Caddyfile is corrupted and the archive digest records dropped before the reboot on purpose: derived things are regenerated every boot, and a stale one killed TLS on hardware. Catches an appliance whose engine cannot run the product — which happened, invisibly to every other phase | 10 |
| `install` | the image boots as **removable** media (usb bus — the gate keys on it); the inventory offers the internal disk and never the boot medium; the real installer runs; the machine then boots from the target alone with a **complete** copy (`/var/lib/dpkg` — the overlay made an incomplete copy easy and invisible), a fresh machine-id, `/data` sized to the target, and the wizard serving. Then the **reinstall leg**: a sentinel planted in `/data`, a second install over the same disk, and the sentinel required afterwards — the chain-preserving promise, tested. The keep leg reinstalls from a **newer stick** over a `/data` that already holds the old dashboard image and its digest record: the image ID must change and the page served must come from the newer image (#798) | 21 |
| `fault` | three power cuts mid-write; a deliberately corrupted bundle is refused without crashing and without bricking; a power cut inside the commit window; operator rollback after all of it; the box is still updatable afterwards | 11 |

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

**M6 — configure by paste.** Complete the wizard using copy/paste for both addresses.
Confirm a pasted **subaddress** (`8…`) is rejected with an explanation before submitting.
Expected: the stack provisions and the dashboard comes up.

**M7 — real update.** Build a `v+1` bundle, copy it to the machine, and install it with
`rauc install` (the test image carries SSH for exactly this). Expected: installs, reboots
into the new version, and an uncommitted update reverts on the next reboot. The
dashboard-driven OS update is tracked pre-GA work — until it exists, this is the honest
mechanism, and it is the same one the KVM update phase exercises.

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

1. `develop` is green: `make lint && make test`, and `tests/os/run.sh --phase all` on the
   bench.
2. Bump `VERSION`. The tag is `v<VERSION>` and every artifact derives from it —
   `STACK_VERSION` is the single place the registry tag comes from.
3. Build the image and bundle. **Sign the bundle with the release key**, never the
   development chain `mkimage.sh` generates. Key custody is in
   [`release-server.md`](release-server.md).
   Then verify the artifact, pinning the commit you meant to build:

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
4. Run the manual battery (M1–M10) on real hardware. Record results.
5. Publish image + bundle + checksums; the bundle's signature is what devices verify.
6. Back-merge `main` → `develop`, per the DIY release rule.

## Shipping a bad release

Covered in full by the bad-release runbook in
[`dual-distribution-plan.md`](dual-distribution-plan.md). The short version, because it is
the thing you will want at 3am:

- **It does not boot** — the machine reverts itself. An uncommitted update never survives
  a reboot; this is the case the A/B design exists for and it needs no operator.
- **It boots but fails its health check** — `pithead` does not commit, and the next reboot
  reverts. Publish a fixed version; the fleet takes it on the next update.
- **It boots, passes its checks, and is still wrong** — this one is on us, not the
  updater. Publish `v+1` with the fix. Operators who already committed roll back with
  `rauc status mark-bad booted && reboot`, which the dashboard exposes as a button.

What bounds the damage in every case: `/data` is never touched by an update. Wallets,
config and the synced chain survive a rollback, a bad release, and a factory reset of the
system slots.
