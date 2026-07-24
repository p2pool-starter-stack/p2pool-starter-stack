# Appliance image harness

Tier-4 tests for the `pithead-os` appliance image (#77 phase 2): the properties only real
firmware and a real A/B updater can prove. The compose/CLI stack is covered by the other
tiers ([`docs/dev/testing-strategy.md`](../../docs/dev/testing-strategy.md)); this harness
covers what the flashed image adds — EFI boot, the first-boot wizard window, and the
update → commit → rollback cycle that is the phase-2 exit criterion.

It needs a Linux host with KVM, libvirt, and qemu (the bench, not CI):

```bash
os/build-image.sh                              # produce os/bakery/build/pithead-os-amd64/system.img
tests/os/run.sh --image os/bakery/build/pithead-os-amd64/system.img
```

## Phases

- **boot** — flash the image to a scratch disk, boot it under OVMF, assert the kernel/systemd
  banner reaches the serial console, the first-boot wizard announces its URL + one-time token,
  and the token gate answers on `:80`.
- **update** — `bake bundle` a v2 update, install it with `rugix-ctrl update install`, and assert
  commit-on-healthy (the gate is `pithead doctor --json`); then install a deliberately broken
  bundle and assert automatic rollback to the previous slot. This is the plan's
  "apply a good update (commits), apply a deliberately broken one (falls back)" exit bar.

`--keep` leaves the VM and disks for inspection; `--phase boot|update|all` scopes the run.

## Status

The boot phase is wired and runs against a built image. The update phase builds the bundle;
driving `rugix-ctrl` install/commit/rollback inside the running guest is the open leg (the
guest exposes no SSH by default — the harness drives it over the serial console, or an
opt-in test-only SSH key baked by a build arg). Until that lands, the update phase fails
loudly rather than reporting a green it did not earn — a silent skip would read as coverage
that does not exist.
