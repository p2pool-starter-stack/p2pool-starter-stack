# pithead-os build — known issues

## BLOCKER: first-boot kernel panic — `rugix-ctrl` exits as initramfs init (2026-07-24)

**Status:** the image builds and boots through EFI → GRUB → kernel → initrd, then panics.
Everything up to userspace works; the initramfs → system handoff does not.

**Symptom** (serial console, reproducible every boot):

```
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path
[   32.x] Kernel panic - not syncing: Attempted to kill init! exitcode=0x00000000
[   32.x] CPU: N UID: 0 PID: 285 Comm: rugix-ctrl ... Debian 6.12.96
```

`rugix-ctrl` runs as PID 1 in the initramfs (its A/B boot flow), produces **no output**,
waits ~32 s (the register dump shows `clock_nanosleep` interrupted — a retry/timeout, not
a crash), then exits, which panics the kernel. First boot, so this is the bootstrapping
leg (repartition-from-image-layout → reboot).

**Ruled out** (each tried, panic unchanged):

- Image tag / pseudo-fs dirs / root-layer wiring / apt-in-chroot / cache staleness — all
  fixed; the build itself is clean and reproducible now.
- Secure Boot (disabled for the test VM — unsigned GRUB; SB is out of scope for v1).
- `/.dockerenv` removal (systemd container-detection) — removed via `pithead-prepare`.
- Baked image layout with `root = "config"/"boot"/"system"` markers — added, matching
  umbrelOS's amd64 layout.
- Exact recipe parity with umbrelOS `setup-rugix` (bootstrapping.toml + state-data.toml +
  system.toml; no manual `update-initramfs`).

**Leading hypothesis:** the difference is the rootfs itself — a `debian:trixie-slim`
docker export vs. umbrelOS's purpose-built base (their `umbrelos-prepare` /
`umbrelos-cleanup` recipes do more than we mirror). `rugix-ctrl` in the initramfs likely
cannot find/mount the system partition and times out. Silence + 32 s + first-boot points
at the bootstrapping device lookup.

**Next step (needs a focused session, not more blind rebuilds):** drop into the
initramfs — boot with `rd.break` or a shell, or bake a debug initrd — and observe what
`rugix-ctrl` actually sees: is the system partition present, does its UUID match the image
layout, what does `rugix-ctrl` log at a higher verbosity. Compare a booting umbrelOS
amd64 image's initramfs contents against ours. The fix is almost certainly a rootfs
preparation step umbrelOS does that we don't, or a Rugix boot-flow parameter for a
from-scratch Debian base.

**What is DONE and unaffected:** the entire `os/` build tooling (reproducible), the
`tests/os/` harness (boot + full A/B update/rollback, ready to run the moment boot
succeeds), and all of phases 0–3 on `develop-v2`. This is the single remaining item to
make phase 2's appliance boot.
