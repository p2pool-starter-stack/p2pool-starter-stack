# Pithead OS — the appliance

A whole operating system that does one thing: run a Monero + Tari merge-mining stack
behind Tor. You write it to a USB stick, install it on a machine, and configure it from a
browser. There is no Linux to set up and no command line to learn.

If you already run Docker and would rather keep your own OS, use the
[getting-started guide](getting-started.md) instead — same stack, same dashboard, you
manage the host.

## What you need

- An x86-64 machine with UEFI you can dedicate to mining. It will be **erased**.
- 16 GB RAM or more, and an internal SSD or NVMe with room for the chain — Monero alone
  is over 250 GB and grows.
- A wired ethernet connection. Wi-Fi is not supported.
- A USB stick, **16 GB or larger** — the image writes 5 GB to the stick, whatever the size of the download.
- A second computer with a browser, on the same network.

The machine runs continuously. A slow disk or a USB-resident install will not keep up:
install to an internal drive.

**Set the machine to power on by itself after an outage.** This is a firmware setting, not
something the appliance can do for you, and the default on most machines is to stay off.
A mining box that sits dark until someone notices loses every hour of an outage plus every
hour until you walk past it. In BIOS/UEFI setup, look under Power or ACPI for
**Restore on AC Power Loss**, **AC Back Function**, **After Power Failure**, or
**State After G3**, and set it to power on — not "last state", which stays off if the
outage happened while the machine was already down.

## 1. Write the image to a USB stick

Download `pithead-os-vX.Y.Z.img` and verify the checksum. Then write it with
[balenaEtcher](https://etcher.balena.io/), or from a terminal:

```bash
sudo dd if=pithead-os-vX.Y.Z.img of=/dev/sdX bs=4M status=progress conv=fsync
```

`/dev/sdX` is the USB stick. Check it twice — `dd` will erase whatever you name.

## 2. Boot the machine from the stick

First, enter the machine's firmware setup (usually Del or F2 during startup) and check two
settings:

- **Disable Secure Boot.** The stick will not boot with it enabled — the machine either
  drops back to its old system or shows a security error, depending on the firmware.
- **Set the machine to power on after power loss** (the setting from "What you need") while
  you are in there.

Then plug in the stick and ethernet, and boot. Choose the USB device in the boot menu; on
most machines that is F12, F11, or Esc during startup.

The machine first says it is starting up, and then — **after a minute or two, sometimes
longer from a USB stick** — prints the address and a one-time token:

```
  Pithead setup wizard is ready. From a browser on this network, open:
      http://pithead.local
      http://192.168.1.42   (if the name above does not resolve)

  One-time token: pit-K7M2QX
```

Nothing is wrong during the wait. The machine is unpacking the setup page, and a login
prompt with no other output is what a working machine looks like at that moment. Wait for
the token line before trying the address — until it appears there is nothing listening.

You need the token, so this step wants a monitor attached at least once.

## 3. Install it to the internal disk

Open that address from your other computer and enter the token — case doesn't matter, and
the `pit-` prefix is optional. Because the machine is running from the USB stick, the
first screen asks which disk to install onto.

Each disk is listed with its model, size and serial number. The USB stick you booted from
is never offered. Nothing is preselected — you choose deliberately, because **installing
erases the disk**.

One exception, and it is the one that matters if you are reinstalling: a disk that already
holds a Pithead `data` partition is marked *"reinstall, keeps existing data"*. Installing
there replaces the system and **keeps your wallets, your settings and your synced chain**.
You do not download 250 GB again.

Type the disk's name to confirm and install. When the copy finishes, **the machine powers
itself off** — that is expected, not a crash. Remove the stick while it is off, then power
it back on. (Powering off before the stick comes out matters: while both disks are
present the machine cannot reliably tell them apart, so it never boots that way.)

## 4. Configure it

The machine boots from its own disk now and serves the same setup page. Enter the token
shown on its console.

**Paste your payout addresses — do not type them.** A Monero address is 95 characters and
a single wrong character pays a stranger. The page checks the address as you paste it and
tells you immediately if it is the wrong kind: p2pool cannot pay a subaddress (starting
`8`) or an integrated address, only your **primary** address, which starts with `4`.

Then a handful of choices, all of which have a sensible default:

| Question | Default | When to change it |
|---|---|---|
| Tari payout address | — | Required, like the Monero one: this stack always merge-mines both coins from the same work. |
| Monero node | run it here | Point at a node you already run. |
| Tari node | run it here | Same, over a network you trust. |
| P2Pool sidechain | mini | `main` only for very large hashrate. On `mini` a home rig gets paid far more often. |
| Mine with this machine's CPU | off | On if this box should mine as well as coordinate. |
| First sync | private over Tor | Faster over the open internet if days of syncing is too slow; it uses Tor afterwards either way. |
| Time zone | UTC | For dashboard timestamps. |

Press Apply. The machine provisions itself and prints the dashboard address and a
generated login on its console. That password is created on the machine and never travels
through the setup page.

Everything here stays editable from the dashboard afterwards, and there is much more you
can tune — see [configuration](configuration.md).

## Updates

The appliance keeps **two copies of the system**, and only one runs at a time. An update
is written to the copy that is idle, so the running system is never modified in place.
The machine installs an update, reboots into the new version, and checks that the stack
came up. If it did not — it fails to boot, or the stack does not start — **the machine
goes back to the previous version on its own**, with nobody present. That is the entire
point of keeping two copies.

**In this test build there is no update button yet.** Applying an OS image update from
the dashboard — and rolling back from it — is being built; until it ships, updates to a
test machine are applied by the release process, not by you. The dashboard's update
notice may still tell you a newer version exists; the one-click action it offers on
other installs refuses on the appliance on purpose, because it would apply the wrong
kind of update.

Your data is never part of an update. Wallets, settings and the chain live on a separate
partition that updates and rollbacks do not touch.

## If something goes wrong

**The machine will not boot from the stick.** Almost always Secure Boot — disable it in
firmware setup. Second most common: the stick was too small — the layout needs about 13 GB once the
machine builds its second system copy and data area, which is why the instructions say
16 GB; the failure shows up as an "emergency mode" console, not a clean message.

**The setup page will not load.** First: has the console printed the token line yet? Until
it does, nothing is listening and the address will refuse the connection — that is the
normal first-boot wait, not a fault. If the token is showing, check the ethernet cable and
try the IP the console prints as well as <http://pithead.local>; some networks filter the
`.local` name. Wi-Fi is not supported, so a wireless-only network will not work.

**"Wrong token."** The token changes each time the setup service restarts — read the
current one from the console. After five wrong attempts it mints a new one on purpose.

**The address was rejected.** You most likely pasted a subaddress (starts with `8`) or an
integrated address. Use your primary address, which starts with `4` and is 95 characters.

**It came back on the old version after an update.** That is the safety mechanism working:
the new version did not come up healthy, so the machine reverted. Nothing is lost. Check
the dashboard logs, and expect a fixed version.

**Power was cut during an update.** Turn it back on. The machine boots the version it was
already running — an interrupted update is discarded, not half-applied.

**The power came back but the machine did not.** That is the firmware setting above, not
a fault in the appliance. Set it to power on after an outage; otherwise every power cut
costs you mining time until someone presses the button.
