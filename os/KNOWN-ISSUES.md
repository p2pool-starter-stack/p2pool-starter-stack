# pithead-os build — known issues

## RESOLVED: first-boot kernel panic (2026-07-24)

The image now boots to multi-user on generic x86 EFI. Kept because the debugging
method is the reusable part.

**What it looked like:** `Kernel panic - not syncing: Attempted to kill init`, with
`Comm: rugix-ctrl`, ~32 s after the initrd handed off — and *no* diagnostic output,
through eleven rebuilds.

**Why it stayed invisible:** the cmdline was `console=ttyS0 console=tty1`, and the
**last** `console=` becomes `/dev/console`. Every byte rugix-ctrl printed went to tty1
while the serial capture saw only kernel messages (the kernel writes to *all*
consoles). Swapping the order made it talk on the first try. `loglevel=3` compounds
this: kernel lines below KERN_ERR never reach the console either, which is also why
the harness's "kernel banner" assertion sees nothing on a *healthy* boot.

**What it was actually saying, once visible:**

1. `insufficient space, cannot add partition 5` — the harness booted the raw 1.8 GB
   image, but bootstrapping expands to the full A/B layout (~18 GiB minimum). Our
   regression: the `qemu-img resize 40G` had been removed. Restored, with the reason
   recorded next to it.
2. `mkfs.ext4 …: No such file or directory` — `debian-slim` ships no `e2fsprogs` or
   `dosfstools`, and rugix-ctrl shells out to them as init. Both are now load-bearing
   rootfs packages.

**Method worth reusing:** when init dies silently, check which console `/dev/console`
actually is before assuming there is nothing to read. Kernel-message presence proves
nothing about userspace output.

## Open: rootfs completeness

Found by the first successful boot — neither is an updater or Bakery issue:

- **No network configuration.** The rootfs installs no network manager and ships no
  `systemd-networkd` `.network` unit, so the appliance boots with no DHCP lease. The
  wizard is unreachable until this lands.
- **Stack images are not baked in.** `pithead firstboot-wizard` runs the dashboard
  image under Podman; with no images present and no network, it cannot start. The
  appliance must carry the release's images (the plan's "first boot works offline"
  property).

## Open: harness boot assertion

`tests/os/run.sh` waits for `Linux version|systemd\[1\]` on serial, which `loglevel=3`
suppresses — so a healthy boot reports failure. Assert on the wizard's console
announcement (now broadcast to every console device) or on the getty banner instead.
