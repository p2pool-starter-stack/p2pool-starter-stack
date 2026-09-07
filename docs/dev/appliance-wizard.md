# The appliance's first-boot wizard

Two contracts that are easy to break from either side, and did break repeatedly during
hardware validation: **who decides which step the operator is on**, and **which certificate
the machine presents**. Both are written down here because the failures they produce look
like something else entirely — a crash, a hang, a dead page.

The setup flow itself is in [`appliance.md`](../appliance.md); building and releasing images
is in [`appliance-release.md`](appliance-release.md).

## Shape

| Piece | Where | Job |
|---|---|---|
| host loop | `pithead firstboot-wizard` | mints the token and certificate, runs the container, consumes the spool, provisions |
| server | `mining_dashboard/wizard.py` | token gate, `/api/wizard-state`, spool writes. **Renders no HTML** |
| client | `web/static/wizard.mjs` | preact/htm views on the dashboard's stack |
| shared logic | `web/static/configsync.mjs` | path access, typed coercion, address/pair guidance — also used by the dashboard's config tab |
| spool | `/data/pithead/data/firstboot` | the only channel between container and host |

The split is deliberate: the container **asks**, the host **decides**. Every privileged
action — validation, disk installs, provisioning — happens host-side, the same trust shape as
the [#33 control channel](../dashboard.md#configuration-view). A compromised container can
write the spool and nothing more.

## The stage machine

`wizard_stage()` in `wizard.py` derives the step from **spool files only**, and the client
renders what it is told. The client must never infer the stage.

| Stage | True when | View |
|---|---|---|
| `handoff` | `handoff.json` exists and `handoff-ack` does not | credentials card |
| `installing` | `installing` or `installed` exists | install progress, then the switch-off steps |
| `done` | `applied` or `handoff-ack` exists — but `installing` when the machine is the installation medium | provisioning notice |
| `installer` | `disks.tsv` exists (host booted from removable media with a target) | the COMBINED form: config + disk + reinstall choice |
| `setup` | none of the above | the config form |

Order matters twice. `handoff` outranks everything: `applied` is written first and the
credentials must win while they are still unsaved. And the ack means two different things —
on an installed machine it releases provisioning (`done`), on the installation medium it
releases the ERASE, so the same ack lands on `installing` and the switch-off steps.

The installation medium runs the whole flow on one page (config + disk + wipe mode in one
submission, gated server-side), publishes the credentials card BEFORE anything touches the
disk — the machine powers off after installing, so the page cannot deliver anything after —
and stages the accepted config onto the target's ESP. The first boot from disk provisions
headlessly through the pre-seed path; there is no second wizard. A missing ack installs
nothing: the erase waits for a human, and a timeout hands the form back intact.

On a reinstall the form opens with the previous machine's answers. When the inventory holds
exactly one disk that already carries an install, the host mounts its data partition
read-only, reads the previous `config.json`, strips every secret
(`strip_config_secrets` — the login, worker inventory, node credentials, view keys, alert
tokens, the ssh key) and publishes the remainder through the same `last-attempt.json` channel
the pre-seed path fills; an operator pre-seed outranks it. Derived fresh each boot and cleared
first — a fleet stick's spool survives between machines, and machine 2 must never open on
machine 1's answers. Pure convenience: any failure (no config, unreadable, ambiguous targets)
opens the form blank and blocks nothing. On keep, none of it matters — the survivor config
wins and no config crosses.

**Why the server owns this.** Two defects came from the client deciding:

- A client-side stage flag was set with `setState` and read back on the next line. Preact
  batches, so the read saw the *old* value and the credentials card could never render — for
  two releases. Server-owned stage removes the variable that could be stale.
- A page refresh mid-provisioning was handed the setup form again, because the client had no
  way to know a config had already been accepted.

**Rule for changes:** any new step is a new spool file and a new `wizard_stage()` branch.
Never a client flag. `/api/wizard-state` carries the handoff payload inline for the same
reason — a separate fetch is a separate race.

**And a spool file that judges a submission is cleared where submissions ARRIVE.** `error.txt`
and `node-probe.json` (#1889) each describe one config, not the machine, and the host only ever
writes them — every arm that hands the form back before `preflight_remote_nodes` runs would
otherwise leave the previous verdict standing. So the wizard voids both at each of its four
spool-writing entry points (`_spool_clear_host_verdict`) rather than removing them arm by arm,
which the next arm added would silently defeat. The probe report is the half that bites: it is
written on the PASS path too, so the survivor is the one that reads as "the nodes were reached".

## The role select — one stick, three machines

The page's FIRST disclosure, above the disk, is what the machine IS. One select, reading
exactly **Pithead** / **Pithead + RigForge** / **RigForge**, and everything downstream
reshapes to the answer the same way the disk choice already reshapes the form:

| Role | The form | What lands |
|---|---|---|
| Pithead | today's flow, byte for byte — the regression bar | `config.json` (the whole contract above) |
| Pithead + RigForge | the default. Pithead's form, opening with the mine-on-this-machine switch already on. The role IS `local_miner.enabled` — the select and the switch are two views of ONE value, so moving either moves the other, and choosing Pithead submits today's config unchanged | `config.json` with `local_miner.enabled: true`; the boot contract's step 5 starts the miner |
| RigForge | collapses to a pool address, a worker name and an optional stratum password. The pool field opens pre-filled when the host found a Pithead answering `pithead.local:3333` — dialed HOST-side and published to the spool as `rig-defaults.json`, the way the disk inventory travels, failing open to an empty field. The disk section gains **Run from this USB stick** as a first-class target: a rig holds almost no state, so the stick can BE the system — no erase, no commitment on machines whose disks belong to something else. The card shows the worker name and where it points; a rig has no dashboard and no login | `machine-role` + `rig.json` (below) |

Validation-before-erase, the keep semantics, the card-then-ack gate, self-power-off and the
headless first boot are identical in every role — one flow, three shapes. And keep means KEEP
whatever the role says: the survivor config wins, and no role change crosses.

The rig submission travels on its own spool channel (`rig-request.json`; the server never
writes a `config.json` candidate for it), and the host dials the pool BEFORE anything
irreversible — the same discipline `preflight_remote_nodes` gives remote nodes.

### The machine-role contract

What the boot path reads, written by the host at the moment a role is accepted:

| File (under `/data/pithead`) | Meaning |
|---|---|
| `machine-role` | `pithead`, `both` or `rig`. Absent means `pithead` — every machine provisioned before this contract. The coordinator values are derivable from `config.json` (both IS `local_miner.enabled`); the rig value is load-bearing, because a rig has no `config.json` at all. |
| `rig.json` | rig role only: `pool`, `worker`, and `stratum_password` when one was set. |

A rig install to a disk stages the accepted answers as `pithead-rig.json` on the ESP —
carried to the target by `pithead-install` beside the config and token pre-seeds — and the
installed machine's first boot lands them as the two files above, scrubbing the ESP copy the
way the config pre-seed is scrubbed. The stick keeps neither copy after a disk install: a
stick whose own `/data` carries the rig marker IS a rig (run-from-USB), and that marker
outranks installer mode on every later boot — except one chosen from the boot menu's **Set up
again** entry, which opens the wizard beside the role (below).

**Getting a machine back out of the rig role** is the boot menu's **Set up again** entry
(#1318) or the installer, never a setting: a rig serves no dashboard and answers on no port, so
there is nothing to log into and change. Boot the stick beside it and install with the wipe, and
it is a blank machine that can pick any role again. A *keep* reinstall deliberately leaves it a
rig — keep means keep whatever the role says.

### Set up again: the wizard beside a saved role

`os/rauc/grub.cfg`'s fourth entry boots the slot the default would have booted and appends
`pithead.setup=1` to that one boot's kernel cmdline. `pithead-setup-again.service`, the flag's
only reader, runs `pithead firstboot-wizard` on a provisioned machine with `PITHEAD_SETUP_AGAIN=1`
and `Before=pithead-boot.service`, so the role's normal boot waits behind the page. Under the
switch (`lib/pithead/12a-setup-again.sh`) three things change and nothing else: the "already a
rig" and "config.json present" short-circuits are skipped; `stage_wizard_spool` publishes
`saved-role.json` and points the pre-fill at the saved answers (`rig-defaults.json` gets the saved
pool + worker; `last-attempt.json` gets `config.json` through `strip_config_secrets`, unless a
failed retry's context is already there); and the inner loop honours `keep-role`. The page shows
its Keep it / Set up again screen exactly when `saved-role.json` exists (`saved_role` in
`/api/state`, `null` otherwise; a malformed file falls through to the normal form).

| Spool file | Written by | Meaning |
|---|---|---|
| `saved-role.json` | host | present only on a set-up-again boot: `{role, pool, worker}` for a rig, `{role}` for a coordinator, never a secret |
| `keep-role` | page | Keep it: the host ends the session with nothing on `/data` touched, the unit exits, pithead-boot runs the normal boot |

Set up again is the ordinary submit. A rig accepted with the same worker name keeps its
`access_token` (`firstboot_consume_rig` carries it over); any other change mints a new one on the
next render. `record_machine_role` removes `rig.json` when the accepted role is not `rig`, so a
role's data goes with the role. A coordinator's `config.json` is NOT removed by a change to `rig`:
it is operator data, and the factory reset is the erase.

## Restore-at-setup

A third spool channel, beside the config candidate and the rig request: an uploaded encrypted
backup (`pithead backup`'s own archive format) plus its passphrase, as an alternative to the
config form. `POST /submit-restore` writes `restore-archive` (binary) and `restore-passphrase`
(plain, read once) — on the installation medium the disk/wipe fields ride beside them through
the SAME `_gate_install_request` a typed submission takes.

`firstboot_consume_restore` (host-side) does the whole job in one call, staged through a COPY —
the same "validate before mutating real state" idiom `consume_preseed_config` already uses:

1. Magic-byte format check, then a full-stream integrity verify (decrypt + `tar -tzf`) —
   identical to `stack_restore`'s own pre-flight — BEFORE anything is extracted.
2. Extract to a `mktemp -d` staging tree, not to the real filesystem yet.
3. Validate the staged `config.json` through the same fresh-process `parse_and_validate_config`
   call `firstboot_consume_spool` uses.
4. Only on success: `cp -a` the whole staged tree onto `/` (config, `.env`, Caddyfile, the Tor
   data dir, the dashboard database — never the chains, which `stack_backup` excludes by
   default) and touch `applied` — the exact contract a typed submission leaves. The firstboot
   loop short-circuits straight into that acceptance path; `prepare_directories` (run by the
   `setup` it feeds) unconditionally re-chowns every data dir, so restore does not need to.

A rejected archive (bad passphrase, wrong format, failed integrity, unparseable config) writes
`error.txt` and returns 1 — nothing is extracted, nothing already on disk is touched, and the
page falls back to the form exactly like a rejected typed config. The passphrase file is deleted
at the top of the call, accepted or not; it never outlives the attempt.

Deliberately reuses `stack_backup`'s archive format (#786 sub-issue A) rather than inventing a
second one, and deliberately does NOT reuse `stack_restore` directly — that CLI command mutates
real state immediately (no staging) and is written for an operator who already has a shell,
which the wizard's pre-provisioning trust level does not assume.

## The certificate lifecycle

**One certificate for the machine's whole life**, at `appliance_tls_dir()`
(`/data/pithead/data/tls`), presented by the wizard *and* by Caddy afterwards.

```
first boot ──> appliance_mint_cert()      compares, doesn't date-guess: keeps a cert whose SANs
                    │                      still match, re-mints when they don't
        ┌───────────┴───────────┐
   wizard serves           generate_caddyfile() calls it on every render, then emits
   (copy in spool)         tls /pithead-tls/wizard.crt
```

Both the certificate's SAN list and Caddy's site list come from one shared builder,
`appliance_site_names()`: a name is either served and certified, or neither. `dashboard.host`
pinned collapses both to that one name; unpinned, both expand to every address the machine
answers on (mDNS name, LAN IPs, `localhost`).

Four properties, each earned:

1. **One cert, not two.** Caddy used to mint its own via `tls internal`, replacing the
   wizard's at the moment provisioning succeeded. A second, different self-signed certificate
   for one hostname is not a second warning — Safari refuses outright, Chrome throws
   `ERR_SSL_PROTOCOL_ERROR`. The setup page appeared to die exactly when it had worked.
2. **Minted wherever it is named, on every render.** `generate_caddyfile` calls
   `appliance_mint_cert` unconditionally now, not only when the pair is missing — the mint
   decides idempotency itself (property 3), so calling it every time is what lets a stale
   certificate get caught instead of surviving forever. It was previously created only by the
   wizard, so any machine that *skips* the wizard — a pre-seeded config, or a reinstall whose
   preserved `/data` already held `config.json` — got a Caddyfile pointing at a file that did
   not exist. Caddy then answered `:443` with no usable certificate, forever, and the console
   was silent because `pithead-firstboot.service`'s `ConditionPathExists=!…/config.json` had
   skipped the unit. Rebooting could not clear it; only reflashing or minting could.
3. **Re-minted only when the name list it covers actually changed.** The mint reads the SANs
   already on the certificate back with `openssl x509 -ext subjectAltName` — never guessed
   from a mint date — and set-compares them against `appliance_site_names()`'s current answer.
   Unchanged, the existing pair is kept: swapping a certificate that still names the machine
   correctly is indistinguishable from an attack, and the browser treats it that way. Changed —
   a DHCP lease moved, `dashboard.host` was just pinned — it re-mints and says so on the
   console, because an operator who pinned the old fingerprint needs to know it just moved.
4. **Checked, not just trusted.** `doctor`'s appliance lane reads the served certificate
   (`openssl x509 -ext subjectAltName -enddate`, no network) and FAILs if a name Caddy serves
   is missing from its SANs, or if it is within 30 days of expiry. With property 3 in place a
   coverage gap should not occur on a healthy render, so this is belt-and-braces there; expiry
   is the check nothing else derives. An unreadable certificate file WARNs instead — `doctor`
   is the second half of `pithead-boot`'s health gate, and a FAIL there reboots the box, so a
   read failure that doesn't prove the certificate is actually broken must not cause one.
5. **The remedy is real, and the gate does not punish the update for it (#1265).** `apply`
   reaches the mint even when `config.json` is unchanged: on an appliance the no-change branch
   re-renders the Caddyfile — the mint inside it is idempotent — and restarts Caddy only when
   the certificate or the Caddyfile moved, so the command `doctor` prints does what it names.
   `pithead-boot`'s gate keeps the coverage FAIL as its re-mint trigger; once its bounded
   re-mint cannot clear the gap (render mints nothing, or the budget is spent) the slot commits
   with the gap recorded as the verdict's `advisory` instead of rolling back a good update for
   a fact about the machine's addresses. Interactive `doctor` still FAILs on it.

The SHA-256 fingerprint is printed on the console beside the token so the browser warning can
actually be verified. A warning nobody can check is theatre.

**Rule for changes:** if a component serves TLS for this machine, it serves *that* pair. If
minting fails, fall back to `tls internal` and say so — a dashboard behind an unfamiliar
certificate beats no dashboard.

## The boot contract (provisioned machines)

After provisioning, every boot runs one unit — `pithead-boot`. **Provisioned has two shapes**,
and the unit's condition names both: a coordinator states it with `config.json` (every machine
provisioned before the role contract has only that), a rig with `machine-role` — it has no
`config.json` and never will. Both are *triggering* conditions — the `|` prefix — so either one
admits the unit while the `/data` mount check still has to hold. The mirror image guards the
wizard: `pithead-firstboot` is excluded by **either** file, or a rig would re-open a setup page
on every boot while the unit that owns its miner sat skipped beside it.

The marker and not `rig.json`, deliberately: a fleet stick holds a rig's answers *in flight*
while installing that rig onto a disk, and must stay an installer through it. Only an accepted
role writes the marker, and only onto the machine that IS that role.

The condition only decides *whether* the unit runs — existence is all a systemd condition can
test. Which leg runs is the marker's VALUE, read by the script.

### The rig leg

A rig is not a small coordinator. It runs no containers, so the image loader is skipped before
it costs anything; it has no `config.json` to render from and no stack to bring up. `pithead-boot`
forks first thing and does two steps:

1. **`pithead local-miner`**, which reads the marker and takes the rig branch: `rig.json` →
   RigForge's `config.json` (pool, worker name as `pools[].user`, stratum password when one was
   set, and *no* HugePages headroom — there is no stack here to leave room for) → the same
   appliance-mode setup the Both role runs, from the same tree on `/data`, against the same
   prebuilt XMRig the image baked. Nothing on this path clones or compiles; a Tor-only box could
   not. A native rebuild is the operator's option, cached on `/data`, never a requirement.
2. **The same health-gated slot commit**, on the miner running. The gate is deliberately
   *pool-independent*: a rig whose coordinator is late still starts, still retries, and still
   commits. Rolling a slot back cannot fix a switch nobody plugged in, and a gate that punished
   it would flap the A/B pair every boot the LAN was slow.

The leg also does the removable-root minimization the run-from-USB rig needs, because that
machine's root IS the stick it mines from. The image ships journald persistent with a 200 MB
cap, whose files land on that same medium; the rig leg flips it to volatile — logs in memory,
no rotating writes on the stick — and converges it on every boot, since `/etc` and `/run` are
both volatile here and no drop-in survives a reboot. Swap needs no code at all: the appliance
declares no swap partition and creates none, in any role. And `/data` needs no rig-sized repart
rule, because it is sized to the **medium** rather than to the role — a 16 GB stick leaves a rig
roughly 6 GiB after the ESP and both slots, which is plenty with no chains. It could not be
role-conditional in any case: `systemd-repart` runs at first boot, before the wizard has asked
what the machine is (`os/rootfs/repart.d/40-data.conf` carries the full reasoning).

### The coordinator leg

Five steps, each answering a hardware-validated failure:

1. **`pithead load-images`** — load the baked container-image archives when their content
   changed. The archives ship in the read-only slot, the engine's storage lives on `/data`,
   and every release tags its images identically — so without this step a keep-reinstall or
   A/B update boots the new OS and keeps serving the old containers (a keep-reinstall did
   exactly that on hardware: new slot, RC-old dashboard, every shipped fix absent). Keyed on
   the archive's digest, recorded beside the store it describes; a normal boot pays one
   sha256 per archive. The first-boot wizard runs the same loader before it serves, so both
   boot owners converge the same way.
2. **`pithead render`** — regenerate every *derived* file (`.env`, Caddyfile, service configs,
   host units) from `config.json` plus the program that is actually running. Derived files are
   never inspected or repaired, only rebuilt: an A/B update swaps the whole program, and a
   bench machine once served a days-old Caddyfile whose site list predated the code around it.
   On the read-only root, host units render into `/run/systemd/system` (`--runtime`
   enablement) and are recreated here each boot.
3. **`pithead up`** — compose owns the containers' lifecycle, and recreates containers when
   an image behind a constant tag changed identity. Its predecessor, `podman-restart`,
   started the stack into its own oneshot cgroup, and systemd SIGKILLed the containers it
   had just spawned.
4. **Health-gated slot commit** — `rauc status mark-good` only once the slot passes two gates.
   First the dashboard must answer through caddy on a *listed* vhost (`localhost`; bare
   `127.0.0.1` hits Caddy's empty default site and proves nothing) — the end of the
   derived-config → caddy → dashboard chain. Second `pithead doctor --json` must exit clean: it
   FAILs on a crashed revenue container (monerod/p2pool/tari), a dead Tor backbone, or a missing
   egress firewall, so a slot that serves a dashboard while mining is dead does not commit. "The
   dashboard answers" is a subset of "the stack is alive", and the second gate closes that gap.
   The gate is deliberately sync-tolerant: a node's healthcheck is a liveness probe that passes
   from early in a days-long initial sync, and the sync-held miners (p2pool/xmrig-proxy, stopped
   by the dashboard until the node catches up) never count as crashed — so a still-syncing box
   commits while a genuinely broken one does not. A slot that boots but is not healthy stays
   uncommitted on purpose: that is the state A/B fallback exists for. Unprovisioned machines never
   commit — GRUB's clear-and-retry keeps them booting, and a bad update before provisioning
   reverts.
5. **`pithead local-miner`** — converge the built-in RigForge worker to `local_miner.enabled`,
   deliberately LAST: the miner needs the stack's stratum listening, and it must never delay
   or block the slot commit — the stack serving is the product's health, the miner is a
   passenger (`|| true`). When enabled, this runs RigForge's setup in appliance mode from the
   tree `pithead-sync` keeps on `/data/rigforge`: its unit renders into `/run` with
   `--runtime` enablement (gone every boot, recreated here, like the control-runner units),
   and the cached XMRig build on `/data` makes the run a re-render rather than a recompile.
   The miner's config is derived by `render` (step 2's family): the stack's own stratum over
   loopback, the stratum password, and the stack's HugePages budget declared as
   `hugepages_reserve_extra_mb` — RigForge's grow-only sysctl then sizes the shared pool as
   the single writer, and pithead's own HugePages write never shrinks a grown pool back.

**Step 4 and forward-only data migrations.** On the first boot of a `data_migration`-flagged
update, `up` (step 3) deliberately withholds the chain services — monerod, tari and their
wallets, the holders of forward-only lmdb migrations — so the commit at step 4 is decided
before any migration touches `/data`, and a failed health check still falls back onto data
the old OS can read. The chain services start, and the migration runs, only after the slot
commits. `pithead os-update` separately refuses a *manual* rollback below the `/data`
migration floor — both halves are described in
[`appliance-release.md`](appliance-release.md#compatibility-metadata-and-the-data-migration-floor).

**Rule for changes:** anything generated from `config.json` or the program is derived and must
be rebuilt by `render` — adding one anywhere else recreates the staleness bug. The container
images are derived in the same sense: functions of the running slot, converged every boot by
`load-images`. Genuine state (`config.json`, wallets, chain data, Tor keys, generated secrets)
is never regenerated; it gets validation and a safe fallback instead.

The invariant, asserted by the provision phase: **corrupt any derived file, reboot, and the
machine must serve again.**

## Where each promise is tested

The layering is deliberate: three defects reached hardware because a layer that looked covered
had a gap between it and the next one.

| Layer | File | Covers |
|---|---|---|
| server contracts | `tests/web/test_wizard.py` | token gate, stage machine, spool writes, install guards, TLS selection |
| pure logic | `tests/frontend/configsync.test.mjs` | path access, typed coercion, address/pair guidance |
| view rendering | `tests/frontend/wizard.test.mjs` (probes) | each view given its props |
| **app orchestration** | `tests/frontend/wizard.test.mjs` (stubbed server) | **stage mapping, the handoff arriving through the poll, refresh-mid-provision, rejection round-trip, request bodies** |
| host logic | `tests/stack/run.sh` | cert minting + idempotence, remote-node preflight, pre-seed, install requests, the digest-keyed image loader, reinstall pre-fill (secret strip + fail-open), the local-miner legs (derived config, sync seeding, boot-leg wiring), the rig-role legs (pool discovery publisher, rig request consumption, the role marker, the rig boot leg's derived config + prebuilt-first + volatile journal + refusals, and both unit conditions), restore-at-setup (`firstboot_consume_restore`: accept against a genuine backup archive, wrong passphrase, missing passphrase, oversize, malformed archive, empty spool), the data-wipe note (`data_wipe_note` reads the ESP's dated log, `publish_data_wipe_note` carries it to the spool fresh every boot, `check_data_wipe_note` is the `doctor` line) |
| the artifact | `tests/os/verify-image.sh` | both role paths present in the shipped image: the boot script's fork, the unit conditions that admit each role, the baked prebuilt, no swap anywhere |
| the real thing | `tests/os/run.sh --phase provision` | token from the console → submit → handoff → ack → running stack → built-in miner up and its shares accepted → reboot through a corrupted Caddyfile → no failed units → slot self-commit → miner back |
| the other real thing | `tests/os/run.sh --phase rig` | the same page answered `RigForge` → rig card with no login → mining from the byte-identical baked binary → **no containers at all** → reboot owned by `pithead-boot`, wizard closed → slot self-commit on an unanswered pool → A/B install, uncommitted rollback, self-commit, persistence |
| the restore leg | `tests/os/run.sh --phase install` | a real encrypted backup taken off a live, fully-provisioned machine, pulled to the harness, uploaded through `/submit-restore` on a FRESH installer boot instead of the form — the wallet address and the Tor onion identity prove restored, not regenerated |

The orchestration row is the one that was missing. pytest proved the endpoint published the
credentials; a render probe proved the card renders given them; nothing proved the app *asked*.
When adding a step, cover it at the layer that owns the promise **and** at the seam to the next
one.
