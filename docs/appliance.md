# Pithead OS — the appliance

A whole operating system that does one thing: run a Monero + Tari merge-mining stack
behind Tor. You write it to a USB stick, install it on a machine, and configure it from a
browser. There is no Linux to set up and no command line to learn.

If you already run Docker and would rather keep your own OS, use the
[getting-started guide](getting-started.md) instead — same stack, same dashboard, you
manage the host.

## What you need

- An x86-64 machine with UEFI you can dedicate to mining. It will be **erased**.
- 16 GB RAM or more — that is the supported floor, not a suggestion: the appliance reserves
  6 GB of it for mining at every boot. With less RAM it still boots, but it prints a warning
  on the machine's screen and shrinks that reservation — mining runs slower and everything
  else runs squeezed, at every boot until the machine has 16 GB.
- An internal SSD or NVMe with room for the chains. The stack budgets
  about 120 GB for pruned Monero and about 200 GB for a local Tari node (measured chains:
  roughly 100 GB and 150 GB in August 2026, and growing — the budget is the growth room), so
  **400 GB or more** runs both locally: the appliance keeps a 256 MB boot partition and two 4 GB
  system copies before your data starts, so a 350 GB disk leaves the chains short of their budget.
  On a smaller disk, run pruned Monero and point Tari at a node you already have — the setup page
  asks both questions, and that drops the requirement to about 140 GB. See
  [Hardware › Running a node elsewhere](hardware.md#running-a-node-elsewhere) for the totals in
  every combination.
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
certificate — the *same* one it keeps using for the dashboard afterwards, so you accept it once
and the warning does not return, unless the set of names the machine answers to actually
changes later (its network address moves, or you pin a custom hostname) — then it mints a new
certificate for the new names and you accept the warning again, once. The machine —
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

### What is this machine?

Before the disk, the page asks what the machine is going to be. This is the first question
because it decides everything else the page asks — and, for one of the three answers, whether
the machine gets a dashboard at all.

| Choice | What it produces |
|---|---|
| **Pithead** | A coordinator: p2pool, xmrig-proxy, Tor and the dashboard, plus the Monero and Tari nodes for whichever of the two you keep on this machine (the setup page asks). Does not mine itself unless you turn on the built-in miner. |
| **Pithead + RigForge** (default) | The same coordinator, plus a built-in miner on this machine's own CPU, pointed at its own pool. It is the same switch as "Mine on this machine too?" below, pre-answered — most people who put one machine on this image want it to mine as well as coordinate. Pick **Pithead** for a box that should only coordinate. |
| **RigForge** | A rig: just the miner, pointed at a Pithead you already have running. No coordinator, no containers, no chains, no dashboard. |

Picking **RigForge** collapses the rest of the page to three questions — the pool address
(`host:port`), a worker name, and an optional stratum password — because a rig holds no payout
addresses, runs no node, and serves nothing to log into. If a Pithead already answers on the
network at `pithead.local:3333`, its address is filled in for you; otherwise enter it by hand
from that machine's own "Point miners at" line. Confirming shows a summary card with the worker
name, where it mines, this machine's address and a **control token** — **not a login**, because
a rig has none. The token is shown once — a rig serves no page after this — so copy it now. If you lose
it, the boot menu's **Set up again** with the same worker name shows the same token again
(see [The boot menu](#the-boot-menu)). It is what lets that Pithead adopt the rig: in its dashboard, under Workers, the adopt
form takes this rig's address, control port `8082` and the token. Until you do that, the rig
still mines and still appears under Workers once it connects, but its row reads as an API error,
because the token guards every API on the rig — the miner's own included, so nothing else on the
network can read or change it. From then on its own console is the only place to look at it, the
same way you would watch any other machine on the network. A rig pointed at a pool with no
IPv4 address (an onion address, say) keeps the token and the read-only feed but runs with
control off, since RigForge refuses a writable path it cannot pin to one source.
Where the machine cannot fill a line in, the card leaves that line out rather than
showing a blank beside its label: with no IPv4 address yet it tells you to read the
address off the console once the machine is up, and on the rare failure to mint a token
it says the rig cannot be adopted until it has one, and to set the machine up again.

**Pithead + RigForge** asks every coordinator question below, unchanged, and adds the built-in
miner on top. The two mining workloads on that one box do not compete for HugePages: the
appliance reserves a RandomX pool sized to its RAM at boot (6 GiB on the supported 16 GB
machine), and the built-in miner is told to leave the coordinator's share alone
(`hugepages_reserve_extra_mb` in its own config) rather than the two halves independently
growing into each other's reservation. The miner is not allowed to resize that pool itself,
either: its service is fenced off the kernel files that would let it, so the reservation the
appliance sized at boot is the one the machine keeps.

Switching back to plain **Pithead** after trying one of the others resets the local-miner switch
to its documented default (off) and, on the installation medium, clears a disk choice of "run
from the USB stick" — that option only exists for a rig.

### The disk

Each disk is listed with its model, size and serial number. The USB stick you booted from is
never offered. Nothing is preselected — you choose deliberately, because **installing erases
the disk**.

A rig has one more choice: **run from this USB stick**. Nothing is written to any disk, so none
of the erase questions below apply — the machine mines from the stick and stops when you unplug
it. The page says the rig's settings are saved and that it appears in your Pithead's Workers
view once it connects. It never shows the install progress, because nothing is being installed.
Choosing a disk on a later attempt — including through **Restore from a backup** — puts the
install progress back, so a machine that really is being installed always says so.

A disk that already holds a Pithead install is the exception, and the page asks what to do
with what is on it:

- **Keep everything** — settings, wallets, login and the synced chains all survive; only the
  system is replaced. The page collapses to just this choice, because there is nothing to
  ask: the machine comes back exactly as it was, same dashboard login included. The right
  choice for an upgrade-by-reinstall, and the default.
- **Fresh start, keep the blockchains** — settings, wallets, dashboard history and Tor
  identities are wiped; the synced Monero and Tari chains (days of downloading) survive.
  Every question is asked fresh — including the node ones: a kept chain only answers for a
  node that ran locally, so say again where each node lives. The right choice when handing
  the machine over, changing payout addresses, or starting clean without paying the sync
  again.
- **Wipe everything** — chains included. The new install re-downloads them from scratch, and
  the full set of questions is asked.

On either fresh start, the page opens with the previous install's answers already filled in —
wallet addresses, node locations, pool tier — read from the disk you are about to wipe, so you
only change what you came to change. Its secrets never make the trip: the dashboard login,
node passwords, view keys, worker tokens and alert credentials are left out, and anything the
machine generates for itself is generated anew. The two switches that need that login come
back at their defaults for the same reason: config editing from the dashboard, which the
machine turns on again for you once a password exists, and publishing the dashboard as a Tor
onion, which you tick again if you want it. If the old configuration cannot be read, the page
opens blank.

Type the disk's name to confirm.

### The questions

Everything below applies to the **Pithead** and **Pithead + RigForge** roles. A **RigForge**
rig skips all of it — see [What is this machine?](#what-is-this-machine) above for its three
questions.

**Paste your payout addresses — do not type them.** A Monero address is 95 characters and a
single wrong character pays a stranger. The page checks the address as you paste it and tells
you immediately if it is the wrong kind: p2pool cannot pay a subaddress (starting `8`) or an
integrated address, only your **primary** address, which starts with `4`.

Then a handful of choices, all with sensible defaults:

| Question | Default | When to change it |
|---|---|---|
| Tari payout address | — | Required, like the Monero one: this stack always merge-mines both coins from the same work. |
| P2Pool sidechain | mini | `nano` for a single low-power rig, `main` only for very large hashrate. Changeable later. |
| Telegram bot | — | Optional. Alerts and status commands; needs both the token and the chat id. |
| Monero node | run it here | Point at a node you already run. It has to be on your own network — a private address (10.x, 172.16–31.x, 192.168.x) or one reached over a VPN — because the machine only lets the mining containers dial private ranges; everything else goes through Tor. |
| Tari node | run it here | Same, over a network you trust, and the same private-address requirement. Pointing Tari elsewhere is the single biggest saving on a small disk: it takes about 200 GB out of the budget. |
| Mine on this machine too? | on | Off if this box should only coordinate — it is the same answer as the **Pithead** role above. Nothing to install: the image carries its own [RigForge](https://github.com/p2pool-starter-stack/rigforge) miner, pointed at this machine's own pool. It starts by itself once the stack is up, comes back on every boot, and appears in the dashboard's Workers view. The box is tuned for hashrate either way — the CPU governor and the HugePages reservation are set on every boot whether or not this switch is on. |
| First sync | private over Tor | Faster over the open internet if days of syncing is too slow; it uses Tor afterwards either way. |
| Dashboard login | generate one for me | Or choose your own password. "No login" is offered but leaves the dashboard — payout addresses, hashrate — open to anyone on your network; never combine it with the Tor onion. It also leaves the machine **unconfigurable from the dashboard** — editing settings can change the payout address, so that stays behind a login — and on a machine with no shell that is permanent: changing it means a factory reset and setting up again. |

That is the whole first-run form — fewer questions than the DIY install, on purpose: anything
with a default that is right for almost every home rig lives one level down, in **Advanced**,
not on the quick form. Today that means the Monero chain size (a ~120 GB budget pruned vs.
~320 GB full — only asked at all when this machine runs the node), the Healthchecks ping URL, and
the time zone (detected from the machine unless set). They are still there to change, just not asked outright.

The dashboard login is also the machine's **console login**: sit at the machine, log in as
`root` with the dashboard password. It is set fresh at every boot and never stored on disk.
Two more switches live only in the **Advanced** view, deliberately out of the quick form:
`ssh.enabled` with `ssh.authorized_key` turns on key-only SSH (never passwords) for remote
debugging. Neither can be changed from the dashboard later, and its Configuration view does not
list them at all — anyone who could flip them from a browser session would own the machine,
wallets and all.

**Already know exactly what you want?** Open **Advanced** at the bottom. It shows the complete
configuration — every key, with its default filled in — and it *is* what the machine will run:
answering a question above (or one of the Advanced fields) rewrites it, and editing it directly
wins. Paste a whole `config.json` in there if you have one.

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
redirect your payouts. Changing them later does not mean reinstalling: write the new settings to a
FAT stick as `pithead-config.json`, insert it and reboot — see
[Changing settings with a USB stick](#changing-settings-with-a-usb-stick). Being able to insert
media and power-cycle the machine is authority over it already, so that channel may set anything,
including what no remote channel is allowed to touch.

Keys still at their default are not written to disk, so this machine keeps picking up improved
defaults from future updates. The configuration it runs is identical either way.

## What the machine does on its own

Two things the appliance sets for itself, that a machine you installed the stack on yourself
would not:

- **It resets itself if it hangs.** The image arms the hardware watchdog built into the
  motherboard: systemd pets it every 10 seconds, and if the kernel stops answering for 20
  seconds the board cuts power and the machine reboots. An appliance in a cupboard has nobody
  to press the button, so a hang that would otherwise cost you days of downtime costs a reboot.
  A shutdown that stalls is bounded the same way, at two minutes.
- **It holds the CPU at full clock.** The governor is set to `performance` at every boot, so the
  node, the wallet and any built-in miner are never scheduled onto a CPU that has clocked itself
  down. This applies whether or not you mine on the machine — a dedicated appliance has no other
  workload to save power for. On hardware with no frequency scaling the step is skipped.

## Updates

The appliance keeps **two copies of the system**, and only one runs at a time. An update
is written to the copy that is idle, so the running system is never modified in place.
The machine installs an update, reboots into the new version, and checks that the stack
came up. If it did not — it fails to boot, or the stack does not start — **the machine
goes back to the previous version on its own**, with nobody present: it restarts itself
once, and that restart lands on the copy that was working. That is the entire point of
keeping two copies.

It restarts itself **once**, not repeatedly. If the previous version fails the same way,
the fault is not in the system copy — something on the data partition is wrong — and the
machine stays powered on with its reason in the logs rather than looping. In that state
the dashboard is down; see [If something goes wrong](#if-something-goes-wrong).

One case does not count as a failed start at all: the stack was already being changed by
something else — the first-run install finishing, or a command you started — and this boot
waited for it and ran out of time. Going back to the previous version would meet the same
wait, so the machine does not spend its one restart on it. It stays powered on, says in the
logs that it was waiting rather than failing, and keeps the return to the previous version
available. Start it again once the other operation has finished.

Updates are applied from the dashboard: an **OS updates** control in the header checks
for a new release, downloads its signed image to the data partition (over Tor, resumable
— mining keeps running), verifies the file on the machine before anything is written to
the idle copy, installs it, and then waits for you: **nothing reboots on its own**. The
reboot is a separately confirmed step, the only one that pauses mining — typically under
five minutes — and after it the machine runs its normal health checks before keeping the
new version. A banner reports the outcome, including an automatic return to the previous
version if the new one failed — and, when those health checks were what held it back,
which check it was, so a return is never mistaken for a bad release. One thing the machine
repairs on its own during that wait: a network address that arrived after the certificate
was made gets a fresh certificate minted there and then, instead of failing the checks
and returning to the previous version. If the certificate still does not match after that,
the machine keeps the new version and notes the gap in its boot log and with the update's
recorded outcome: the mismatch is about this machine's addresses, not the update, and
running `pithead apply` on the machine mints the certificate — that command now does so
even when the configuration is unchanged. The machine refuses images that are unsigned, built for
different hardware, or older than what it runs; there is no override. If another operation is changing the stack when you start an
install, the install is not started at all: nothing is written to the idle copy and the
dashboard says so rather than reporting a failed install. Start it again once that
operation has finished. See
[Dashboard › Updating the appliance OS](dashboard.md#updating-the-appliance-os) for the
step-by-step. The one-click tarball upgrade other installs offer refuses on the
appliance on purpose — it would apply the wrong kind of update.

Your data is never part of an update. Wallets, settings and the chain live on a separate
partition that updates and rollbacks do not touch.

Security fixes travel the same road. There is no package manager on the machine and
nothing for you to patch by hand: every piece of the operating system — Debian itself,
the container engine, the mining programs — is fixed at the moment the image is built,
and a security fix reaches your machine as the next image, with the same
install-then-fall-back protection as any other update. The practical consequence:
**taking updates when they are offered is the security maintenance.** A machine left on
an old image keeps running fine, but it keeps the old image's known holes too. The base
system is Debian 13, which receives security support upstream into 2030.

## The boot menu

Every start shows a short menu for five seconds, then boots by itself. You never need to
touch it: the machine keeps two copies of the system and boots the last one that worked,
so an update that fails to come up is undone on the next start without you.

- **Pithead OS - slot A** and **slot B** are those two copies. The one selected when the
  menu appears is the one the machine chose; the other holds the previous version after an
  update. Pick it only if support asks you to.
- **Pithead OS - slot A (fallback)** is what boots when neither copy is marked good: the
  same system as slot A, offered so a machine with nobody at it boots something rather
  than waiting at a prompt.
- **Set up again** opens the setup page, keeping everything the machine already has. Use it
  when a machine's answers need changing and there is no other way in. A RigForge rig has no
  dashboard and no login, so this entry is its only way back to the setup page from the
  machine itself.

### Set up again

Choose it with a keyboard on the machine during the countdown. The machine starts the
setup page instead of its normal work, prints the address and one-time token on the
console as it did on the first boot, and the page opens by naming what the machine is: a
rig mining at a pool as a worker, or a Pithead coordinator. Two choices:

- **Keep it** closes the page and starts the machine exactly as it was. Nothing changes,
  and the same holds for a page you never touch or a machine switched off part way: the
  saved settings are replaced only when you accept new ones.
- **Set up again** opens the form filled in with the saved answers and the secrets left
  out: a stratum password, and for a coordinator the dashboard login and node credentials,
  are typed again. Accept the form and the machine provisions itself with the new answers.

A rig kept as a rig with the same worker name keeps its control token: the Pithead that
adopted it goes on reaching it, and the card shows that same token again, so this is also
the way to see a token you did not copy the first time. A different worker name, or a
change of role, makes a new one. A rig that becomes a coordinator, or the other way round,
is provisioned as the new role; whatever the old role kept on the data partition stays
there until a [factory reset](#starting-over-the-two-resets).

### Getting a rig back to setup from another computer

A run-from-USB rig with no monitor or keyboard cannot reach the menu. Plug the stick into
another computer instead:

- Delete `pithead/machine-role` and `pithead/rig.json` from the stick's partition labelled
  `data`. It is ext4, so a Linux machine can open it; macOS and Windows cannot without extra
  software. The setup page runs on the next boot and the installed systems are kept.
- Or create an empty file named `pithead-reset` at the top of the stick's first partition,
  the small FAT one that any computer can open. The next boot erases the data area and
  starts from a blank setup page: a factory reset.
- Or write the image to the stick again ([step 1](#1-write-the-image-to-a-usb-stick)).

## Backing up your data

The machine holds state a resync cannot rebuild: your wallet settings, the Tor onion
keys that give it its address, and the dashboard's history. There is no filesystem to
copy from a shell-less box, so the dashboard's **Backup** view exports it
for you as one encrypted file.

Click **Back up now** and the machine stops the stack, archives `config.json`, `.env`,
the Tor onion-service keys and the dashboard database into a single file, and starts the
stack again — mining pauses for the archive's duration. The blockchains are left out; they
resync from the network on their own.

The archive is encrypted, and the machine picks the passphrase for you: a long, random
one, shown exactly once, right after the archive is ready. There is no way to see it
again — the page shows it inside a downloadable kit (the passphrase, the archive's name,
and what it contains), and warns you before it moves on. Save the kit and download the
archive together, and keep them somewhere other than this machine. Without the
passphrase, the archive cannot be opened.

Putting a backup to use is the [Recovering from a backup](#recovering-from-a-backup)
section below: a fresh install accepts the archive and its passphrase in place of the
setup form.

## Starting over: the two resets

There are two ways to reset the machine, and the difference between them is days of your
time. Both run from a shell — log in at the console as `root` with the dashboard password
(the appliance has no uninstall; these resets are its equivalents).

**Config reset** clears your settings and reopens the setup wizard, and keeps everything
else. The synced chain, your wallet, the Tor onion keys and your dashboard history all
stay on the machine, so the wizard opens on a box that is still fully synced — you re-enter
your answers and it is running again in minutes, at the same onion address. Reach for this
when you want to change a setting the wizard owns, or hand the machine to someone else
without a resync.

```
pithead config-reset
```

**Factory reset** erases the whole data area — chain, wallet, Tor keys, settings, all of
it — and reboots to a blank setup wizard, exactly as the machine shipped. The resync that
follows takes days, so use config reset first unless you truly want nothing kept.

```
pithead factory-reset
```

Both ask you to type the reset name before they do anything. The machine reboots itself
into setup when the reset is done.

A machine that comes back to the setup wizard **without** being asked to is a different
event: the data area would not mount, and the machine repaired it or, failing that,
reinitialized it to get itself back. Repair is tried first and goes as far as rebuilding
the filesystem's superblock from a backup copy — a data area is only ever erased when
nothing could mount it. When that does happen the setup page itself says so, dated, and
`pithead doctor` reports the same fact for a support conversation on a machine with a
shell. If you have a backup, restore it instead of setting up as a fresh machine — a
factory reset you asked for never shows this notice.

## Recovering from a backup

Fresh flash, restore, done — if the machine is gone (dead disk, stolen, dropped), a backup
taken beforehand provisions a replacement in one page, with nothing retyped.

**Take a backup before you need it.** The dashboard's **Backup** view is
the machine's own way to do that ([Backing up your data](#backing-up-your-data) above): the
archive it downloads and the passphrase from its kit are exactly what restore asks for. The
console works too — log in as `root` with the dashboard password and run:

```
pithead backup
```

This writes the same kind of encrypted archive under `backups/`, with a passphrase you type
(or set `PITHEAD_BACKUP_PASSPHRASE` for an unattended run). Either way the archive holds
config, wallets, the Tor identity, and the dashboard's history — never the blockchain, which
re-syncs — and restore opens it with whichever passphrase sealed it: the kit's, or yours.
Copy the archive off the machine and keep the passphrase somewhere else — the archive is
useless without it, and the machine you are backing up is exactly the thing you might lose
next.

**Restore it at setup.** Write a fresh image, boot the machine, and on the setup page choose
"Restoring an existing Pithead? Upload its backup instead." above the form. Upload the archive
and its passphrase; the machine decrypts, validates, and provisions itself from what it
restores — the same wallets, the same Tor onion address, the same dashboard login and history,
on hardware that has never seen them. Provisioning runs to completion and the stack comes up on
that same boot: the restored configuration is new to this hardware, not a re-run of a finished
setup, so it is treated as first-time provisioning even though the identity underneath it is not.
This works on the installation medium's combined page too, alongside the disk choice.

A wrong passphrase or a damaged archive is rejected with the reason, and the page falls back to
the normal form — restore never blocks setup. Restore only runs at first setup, on a machine
that has no configuration yet; it does not restore over a running install.

## Changing settings with a USB stick

Insert a stick carrying a `pithead-config.json` and reboot: the machine validates it, shows
the exact change on the console, and applies it after a countdown — no password, no browser,
no keyboard required. This is the same file format the setup wizard reads (see [setting it up
without a monitor](#setting-it-up-without-a-monitor)), and it can change **any** setting,
including the ones the dashboard never exposes: the SSH toggle, the dashboard login password,
and the Telegram alert channel's own identity. That is deliberate. Whoever can insert media
and power the machine off and on already has full authority over it — a shell at the console
proves the same thing today — so this channel makes that authority usable instead of assuming
you have a monitor and a working password. It is the recovery path when the dashboard password
is lost.

Prepare the stick with a normal FAT32 partition and a `pithead-config.json` at its root — copy
`config.json` from a machine you already set up, or write just the settings you want to change
(see [configuration](configuration.md)). Settings the file does not name keep their current
values: `{"p2pool": {"pool": "nano"}}` changes the pool tier and nothing else — the dashboard
login, the generated node credentials, and every other setting stay as they are. To clear a
setting instead of keeping it, name it with a value of `null`. At boot:

- If the staged file changes nothing — every setting it names already holds that value — the
  console says so and the boot carries on without stopping.
- If it differs, the console prints every changed setting: the old value, the new value, and
  for a password, token or RPC credential, that it changed — never what it changed to. Wallet
  addresses print in full; confirming the payout address is the point of the display.
- The console then counts down 60 seconds. Pulling the stick during the countdown cancels the
  change, and the console says so — nothing is applied. On a machine with a keyboard attached,
  `a` applies immediately and `n` cancels; a headless machine needs neither key — letting the
  countdown run out applies the change. If the confirmation never reaches the physical console
  (a serial line can lose a message to a login prompt claiming it at the wrong moment), the same
  line is always in the journal: `journalctl -u pithead-boot` on that machine.
- Once applied, the file is deleted from the stick, the same way the installer clears its own
  pre-seed, so the same change cannot reapply on a later boot. Reinsert a fresh export to make
  another change.

An applied change is a real config commit: it goes through the same path as any other, so a
payout-wallet swap or a clearnet-exposure change still fires the matching Telegram alert.

NOTE: this channel only reads at boot. Inserting the stick into a running machine does nothing
until you reboot it.

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
key-only, and only if you need it. The dashboard does not offer them after that; a configuration
stick is the way in later.

**"Wrong token."** The token changes each time the setup service restarts — read the
current one from the console. After five wrong attempts it mints a new one on purpose.

**The address was rejected.** For Monero you most likely pasted a subaddress (starts with
`8`) or an integrated address. Use your primary address, which starts with `4` and is 95
characters. If the message says the checksum failed — for either the Monero or the Tari
address — at least one character is wrong: re-copy it from your wallet rather than fixing
it by eye. A Tari address rejected as the wrong network came from a testnet wallet; the
stack mines mainnet.

**"Wrong passphrase or corrupt archive."** Confirm you copied the whole `.tar.gz.enc` file (a
partial copy fails the same way) and typed the passphrase exactly as it was set when you ran
`pithead backup`. Nothing is written until this check passes — retry from the same page.

**It came back on the old version after an update.** That is the safety mechanism working:
the new version did not come up healthy, so the machine restarted itself and went back.
Nothing is lost. Check the dashboard logs, and expect a fixed version.

**It restarted once and the dashboard is still down.** Then both copies failed the same
check, which points at the data partition rather than at the update — most often a disk
that has gone bad. The machine deliberately stops restarting at that point so it stays
still long enough to be looked at. Attach a screen and keyboard: the console prints the
reason on every boot.

**Nothing responds after I pulled the USB stick out.** The machine was running from it. Hold
the power button until it switches off, leave the stick out, and power it on: it boots the
installed system. An install that had already reported success is safe on the disk.

**Power was cut during an update.** Turn it back on. The machine boots the version it was
already running — an interrupted update is discarded, not half-applied.

**The power came back but the machine did not.** That is the firmware setting above, not
a fault in the appliance. Set it to power on after an outage; otherwise every power cut
costs you mining time until someone presses the button.
