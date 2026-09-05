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

Every guest boot is preceded by a host pre-flight (`tests/os/kvm-preflight.sh`): under 20 GiB of
`MemAvailable` the battery refuses to boot the 16 GiB guest rather than risk hanging the host that
runs it (`PITHEAD_KVM_MIN_AVAIL_MB` sets the bar; the reading is printed at every boot either way).

The harness builds its own update bundles from the same tarball (`os/rauc/mkbundle.sh --dev`),
signed with a throwaway development key. A release build names its key instead — see the custody
runbook in [`docs/dev/release-server.md`](../../docs/dev/release-server.md).

## Phases

- **boot** — flash the image to a scratch disk, boot it under OVMF, assert the kernel/systemd
  banner reaches the serial console, the first-boot wizard announces its URL + one-time token,
  and the token gate answers. Also asserts machine-id is stable across a plain reboot (#895) —
  the empty-baked image with no restore mechanism would regenerate a new one every boot — and,
  across that same reboot, that journald follows the restored id (#1659) and writes the one
  persistent journal home, the `/data/pithead/journal` bind, with the boot list intact (#1791:
  the `/var` overlay used to race the bind for `/var/log/journal`, and a boot that lost was
  missing from `journalctl --list-boots`).
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
  until the slot commits, then start, with the pending marker consumed. After it, the floor-fallback
  leg (`data-floor-fallback-leg.sh`, #1393) installs a migrating bundle stamped with a version no
  release carries, so its slot cannot bring the stack up and falls back uncommitted: the previous
  slot's boot must put the `/data` floor back from the record the raise left, and the same fall-back
  with the record deleted must leave the floor alone and make `os-update` refuse with the
  failed-update premise.
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

## Soak probe

`tests/os/soak-probe.sh HOST LOGDIR [--start]` is the 7-day unattended soak's daily reader
(#1652): one non-interactive, read-only SSH session whose remote command is fixed in the script,
one line per day appended to `LOGDIR/soak.log`, scored against the pass condition ruled on the
issue (one boot, restart counts and start times flat, every container running and — except
`xmrig-proxy`, #1098 — healthy, exactly the probe's own login since the previous read). Each
read records the journal cursor it reached in `LOGDIR/ssh.cursor`, and the next read counts logins
from there, so nothing falls between two days and nothing is counted twice; a count of 0 fails
naming the instrument, since the probe's own login must be there. `--start` writes the day-0
baseline — its own line reads `window=25h` and carries a rule-4 FAIL from the setup logins, so day
0 is the baseline, not a soak day. Only `--start` writes `day0.env`; a cron read never does, so a
restart in the window's first hours can never be absorbed into the baseline it is scored against.
Every line carries `read=N`, its `soak.log` line number, because the first cron read lands under
24 h after `--start` and shares `day=0` with the baseline line; each run's raw readings are kept as
`LOGDIR/readN.env`. `--self-test` proves the verdict over canned readings, then drives the script
three times through a stubbed `ssh` to prove the baseline survives a cron read, without a box. Run
it from a cron line on the build host, never from a resident session.
