# Appliance image harness

Tier-4 tests for the `pithead-os` appliance image (#77 phase 2): the properties only real
firmware and a real A/B updater can prove. The compose/CLI stack is covered by the other
tiers ([`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md)); this harness
covers what the flashed image adds — EFI boot, the first-boot wizard window, install-to-disk,
the rig role, and the update → commit → rollback cycle that is the phase-2 exit criterion.

It needs a Linux host with KVM, libvirt and qemu, and root (the bench, not CI):

```bash
os/build-image.sh --ssh                       # rootfs tarball -> os/build/pithead-root.tar
os/rauc/mkimage.sh --dev                      # bootable image -> os/rauc/build/system.img
sudo tests/os/run.sh --image os/rauc/build/system.img
```

The harness builds its own update bundles from the same tarball (`os/rauc/mkbundle.sh --dev`),
signed with a throwaway development key. A release build names its key instead — see the custody
runbook in [`docs/dev/release-server.md`](../../docs/dev/release-server.md).

## Phases

- **boot** — flash the image to a scratch disk, boot it under OVMF, assert the kernel/systemd
  banner reaches the serial console, the first-boot wizard announces its URL + one-time token,
  and the token gate answers. Also asserts machine-id is stable across a plain reboot (#895) —
  the empty-baked image with no restore mechanism would regenerate a new one every boot.
- **update** — build a v2 bundle, `rauc install` it, boot the spare slot, and assert the whole
  A/B contract: an uncommitted slot auto-rolls-back, `rauc status mark-good` makes the update
  stick across a reboot, and `rauc status mark-bad booted` still rolls off a committed version.
  Also asserts `/data` grew to fill the disk, and that host identity (SSH host-key fingerprint,
  machine-id) survives the A/B swap (#894/#895) — both live on `/data`, untouched by the slot
  swap.
- **install** — boot the image as removable media beside a blank disk, run the disk installer,
  then boot the target and prove the copied system is COMPLETE — the `/var` overlay made an
  incomplete copy easy to produce and invisible to every other phase. Then the reinstall leg:
  `/data` must survive a second install over the same disk, and the three-way wipe choice
  (`keep`/`data`/`all`) is asserted on the raw partition.
- **provision** — submit a config through the wizard's real HTTP flow and require the STACK to
  come up: wizard accepted, setup ran, images pulled and verified, containers running, dashboard
  served, Tor-only egress actually enforced, built-in miner up. This is the phase that catches an
  appliance whose engine cannot run the product. Then the stack must return from a reboot with no
  hands on it, and the real commit gate — `pithead doctor --json` — must pass on that healthy
  stack yet refuse once a revenue service is down. The closing leg installs a `data_migration`
  bundle through `pithead os-update` and proves the migration hold: the chain services stay down
  until the slot commits, then start, with the pending marker consumed.
- **rig** — answer `RigForge` on the same page and prove the other machine this image installs:
  it mines from the baked binary with no compile and no clearnet, starts no containers at all,
  and takes an A/B update — install, boot, self-commit on the miner running, persistence —
  exactly like a coordinator. (Uncommitted fallback is the update phase's to prove: a
  provisioned rig commits the moment its miner is up, so the uncommitted window closes by
  design.) A rig serves no dashboard, so one that silently never mines is invisible to
  everything except this.
- **media** — the physical-presence configuration channel (#786 sub-issue D): provisions via the
  ESP pre-seed path, then attaches a second removable stick carrying a changed `config.json` and
  reboots. Asserts the exact diff appears on the console (the changed wallet address in full, a
  changed secret only named, never shown), the countdown applies the change, the changed setting
  takes effect, and the stick is consumed so it cannot re-apply. A second reboot proves pulling
  the stick mid-countdown cancels the change instead. Opt-in, like `fault`.
- **fault** — power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is
  disqualifying. Opt-in: `all` runs the five phases above, not this one.
- **reset** — the shell-less box's last resort, never before run against a real disk: a
  provisioned machine runs the real `pithead factory-reset -y`, which arms the `pithead-reset`
  marker on the ESP and reboots; assert it comes back to the wizard with the provisioned config
  and old container images gone, the seeded dirs back, and a FRESH host identity (SSH host-key
  fingerprint, machine-id) — the reset tier keeps nothing of the old owner's. A second leg
  corrupts the data partition's ext4 magic and asserts the wedged-`/data` recovery reformats it
  rather than bricking. Opt-in, destructive: not in `all`.

`--keep` leaves the VM and disks for inspection; `--phase boot|update|install|provision|rig|media|fault|reset|all`
scopes the run. A failed assertion is recorded and the run carries on, so one bench boot collects
the whole battery; the run exits non-zero if anything failed.

## Static verification

`tests/os/verify-image.sh` is the cheapest gate and runs without KVM — it mounts a built image
read-only and checks that no test material shipped, that every baked fix is in the artifact, and
that the boot path's files sit where the firmware and GRUB will look.

```bash
sudo tests/os/verify-image.sh os/rauc/build/system.img          # release: test artifacts REFUSED
sudo tests/os/verify-image.sh os/rauc/build/system.img --test   # harness build: SSH key expected
```

## The real appliance

`run.sh` and `verify-image.sh` above both work against a KVM guest or a built image — neither is
hardware. [`tests/os/hw-battery.sh`](hw-battery.sh) is the sibling harness for the physical
`pithead-os` appliance bench: it drives the real box over ssh, takes the bench reservation
(`tests/os/bench-lock.sh`) itself, and runs what only real hardware can prove — see
[`docs/dev/appliance-release.md`](../../docs/dev/appliance-release.md#manual-battery--required-before-every-appliance-release)
for what it covers and [`docs/dev/release-server.md`](../../docs/dev/release-server.md#appliance-bench-reservation)
for the reservation and the box contract.

```bash
tests/os/hw-battery.sh --host root@<appliance-address>
```
