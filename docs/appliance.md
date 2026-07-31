# Pithead OS — the appliance

A whole operating system that does one thing: run a Monero + Tari merge-mining stack
behind Tor. You write it to a USB stick, install it on a machine, and configure it from a
browser. There is no Linux to set up and no command line to learn.

If you already run Docker and would rather keep your own OS, use the
[getting-started guide](getting-started.md) instead — same stack, same dashboard, you
manage the host.

## What you need

- An x86-64 machine with UEFI you can dedicate to mining. It will be **erased**.
- 16 GB RAM or more, and an internal SSD or NVMe with room for the chains. Pruned Monero
  needs about 120 GB and a local Tari node about 170 GB, so **350 GB or more** runs both
  locally. On a smaller disk, run pruned Monero and point Tari at a node you already have —
  the setup page asks both questions.
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
      https://pithead.local
      https://192.168.1.42   (if the name above does not resolve)

  One-time token: pit-K7M2QX
  (case does not matter, and the pit- prefix is optional)

  Your browser will warn that the certificate is not trusted. That is expected:
  this machine signed its own. Check it matches before continuing --
  SHA-256: A1:B2:C3:...
```

**Your browser will warn you once, and that is expected.** The machine makes its own
certificate — the *same* one it keeps using for the dashboard afterwards, so you accept it a
single time and the warning does not return. The machine —
there is no authority that could vouch for a box on your network. The warning means "nobody
else vouched for this", not "something is wrong". Compare the fingerprint on the console with
the one your browser shows under the warning's details, then continue. The setup page is
encrypted either way, which matters because what you type into it includes node passwords and,
if you use the advanced view, anything else in the configuration.

Nothing is wrong during the wait. The machine is unpacking the setup page, and a login
prompt with no other output is what a working machine looks like at that moment. Wait for
the token line before trying the address — until it appears there is nothing listening.

You need the token, so this step wants a monitor attached at least once.

### Setting it up without a monitor

The steps above need a display once, to read the token. You can skip that by writing to the
USB stick **after flashing it** — the stick's small `PITHEAD` volume is readable on any
Windows, macOS or Linux machine, so plug it into your laptop and drop a file on it:

- **`pithead-token.txt`** — one line with a token you choose (letters, digits and dashes).
  The machine uses that instead of printing its own, so you can open the setup page without
  ever seeing its console.
- **`pithead-config.json`** — a complete configuration. First boot applies it and provisions
  itself; no setup page at all. Copy `config.json` from a machine you already set up, or see
  [configuration](configuration.md).

A rejected file never blocks you: the machine says so on its console and opens the normal
setup page instead.

Two cautions. A configuration file holds your payout addresses in plain text on a volume
anyone who picks up the stick can read — fine for a stick that stays in your hand, worth
thinking about otherwise. (The installed machine deletes its own copy the moment the
configuration is applied; the stick keeps yours for the next machine.) And installing to a
disk still needs someone to choose that disk: on the installation medium a pre-seeded file
opens the page with every answer already filled in, but the disk choice — the erase — is
always yours to confirm.

## 3. Install and configure it — one page

Open the address from your other computer, accept the certificate warning, and enter the
token — case doesn't matter, and the `pit-` prefix is optional. Because the machine is running
from the USB stick, one page asks for everything at once: which disk to install onto, and the
answers the miner needs. You fill it in, save the login it shows you, and the machine does the
rest — including erasing the disk only after everything else checked out.

### The disk

Each disk is listed with its model, size and serial number. The USB stick you booted from is
never offered. Nothing is preselected — you choose deliberately, because **installing erases
the disk**.

A disk that already holds a Pithead install is the exception, and the page asks what to do
with what is on it:

- **Keep everything** — settings, wallets, login and the synced chains all survive; only the
  system is replaced. The page collapses to just this choice, because there is nothing to
  ask: the machine comes back exactly as it was, same dashboard login included. The right
  choice for an upgrade-by-reinstall, and the default.
- **Fresh start, keep the blockchains** — settings, wallets, dashboard history and Tor
  identities are wiped; the synced Monero and Tari chains (days of downloading) survive. The
  node and first-sync questions are skipped — the chains on the disk answer them — and
  everything else is asked fresh. The right choice when handing the machine over, changing
  payout addresses, or starting clean without paying the sync again.
- **Wipe everything** — chains included. The new install re-downloads them from scratch, and
  the full set of questions is asked.

Type the disk's name to confirm.

### The questions

**Paste your payout addresses — do not type them.** A Monero address is 95 characters and a
single wrong character pays a stranger. The page checks the address as you paste it and tells
you immediately if it is the wrong kind: p2pool cannot pay a subaddress (starting `8`) or an
integrated address, only your **primary** address, which starts with `4`.

Then a handful of choices, all with sensible defaults:

| Question | Default | When to change it |
|---|---|---|
| Tari payout address | — | Required, like the Monero one: this stack always merge-mines both coins from the same work. |
| Monero chain | Pruned (~120 GB) | Only asked when this machine runs the node. Full is ~320 GB and mines identically. |
| P2Pool sidechain | mini | `nano` for a single low-power rig, `main` only for very large hashrate. Changeable later. |
| Healthchecks ping URL | — | Optional. Tells you when the machine goes *silent* — a power cut or crash, which it cannot report itself. |
| Telegram bot | — | Optional. Alerts and status commands; needs both the token and the chat id. |
| Monero node | run it here | Point at a node you already run. |
| Tari node | run it here | Same, over a network you trust. |
| Mine with this machine's CPU | off | On if this box should mine as well as coordinate. |
| First sync | private over Tor | Faster over the open internet if days of syncing is too slow; it uses Tor afterwards either way. |
| Time zone | UTC | For dashboard timestamps. |
| Dashboard login | generate one for me | Or choose your own password. "No login" is offered but leaves the dashboard — payout addresses, hashrate — open to anyone on your network; never combine it with the Tor onion. |

The dashboard login is also the machine's **console login**: sit at the machine, log in as
`root` with the dashboard password. It is set fresh at every boot and never stored on disk.
Two more switches live only in the **Advanced** view, deliberately out of the quick form:
`ssh.enabled` with `ssh.authorized_key` turns on key-only SSH (never passwords) for remote
debugging. Neither can be changed from the dashboard later — anyone who could flip them from a
browser session would own the machine, wallets and all.

**Already know exactly what you want?** Open **Advanced** at the bottom. It shows the complete
configuration — every key, with its default filled in — and it *is* what the machine will run:
answering a question above rewrites it, and editing it directly wins. Paste a whole
`config.json` in there if you have one.

### Press "Validate, then install"

The machine checks your answers first — including dialing any remote node you named, so a
wrong host fails here with the reason and your answers kept, not after the disk is gone. Only
when everything passes does it show you, on this page, the things you must save:

- the **dashboard login** (generated, or the one you chose)
- the **dashboard address** (`https://pithead.local`)
- where to **point your miners** (`stratum+tcp://pithead.local:3333`)

**Copy the login somewhere safe, then press "I saved these — erase the disk and install."**
Nothing touches the disk until that press. The install takes a few minutes, and when it
finishes **the machine switches itself off.** That is the end of the install, not a crash.

Then the last three steps you will ever do at this machine:

1. Wait for it to go dark.
2. Remove the USB stick.
3. Switch it back on.

The machine boots from its own disk and **provisions itself with the configuration you just
confirmed** — no second setup page, no second token. Pulling and starting the stack takes
10–30 minutes on a home connection, its console narrates the progress, and when it finishes
the dashboard is at the address above, behind the login you saved. (The login is also in
`config.json` on the machine if you lose it.)

There is nothing to click before the power-off, on purpose: until it goes dark the machine is
running *from* the stick, so the stick cannot come out while it runs. (If you pull it out
early, the machine stops responding — hold the power button, leave the stick out, and switch
it on. An install that had already reported success is safe on the disk.)

Most of the configuration stays editable from the dashboard afterwards — see
[configuration](configuration.md) for everything you can tune. Be aware of one honest limit
in this release: the security-sensitive settings (payout addresses, view keys, the dashboard
password, per-rig worker entries) can be set **here, at install**, but not changed from the
dashboard later — that restriction is deliberate, so a compromised browser session can never
redirect your payouts. Until the approval flow that lifts it ships, changing those means
booting the stick again and reinstalling with **"Fresh start, keep the blockchains"** — you
enter the configuration again (paste your saved one into Advanced), and the synced chains
survive.

Keys still at their default are not written to disk, so this machine keeps picking up improved
defaults from future updates. The configuration it runs is identical either way.

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
try the IP the console prints as well as <https://pithead.local>; some networks filter the
`.local` name. Plain `http://` addresses redirect to `https://`, so either spelling works. Wi-Fi is not supported, so a wireless-only network will not work.

**You need a shell on the machine.** Log in at its console as `root` with the dashboard
password. For SSH, set `ssh.enabled` and `ssh.authorized_key` in the Advanced view at setup —
key-only, and only if you need it.

**"Wrong token."** The token changes each time the setup service restarts — read the
current one from the console. After five wrong attempts it mints a new one on purpose.

**The address was rejected.** You most likely pasted a subaddress (starts with `8`) or an
integrated address. Use your primary address, which starts with `4` and is 95 characters.

**It came back on the old version after an update.** That is the safety mechanism working:
the new version did not come up healthy, so the machine reverted. Nothing is lost. Check
the dashboard logs, and expect a fixed version.

**Nothing responds after I pulled the USB stick out.** The machine was running from it. Hold
the power button until it switches off, leave the stick out, and power it on: it boots the
installed system. An install that had already reported success is safe on the disk.

**Power was cut during an update.** Turn it back on. The machine boots the version it was
already running — an interrupted update is discarded, not half-applied.

**The power came back but the machine did not.** That is the firmware setting above, not
a fault in the appliance. Set it to power on after an outage; otherwise every power cut
costs you mining time until someone presses the button.
