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

## The role select — one stick, three machines

The page's FIRST disclosure, above the disk, is what the machine IS. One select, reading
exactly **Pithead** / **Pithead + RigForge** / **RigForge**, and everything downstream
reshapes to the answer the same way the disk choice already reshapes the form:

| Role | The form | What lands |
|---|---|---|
| Pithead | today's flow, byte for byte — the default, and the regression bar | `config.json` (the whole contract above) |
| Pithead + RigForge | Pithead's form with the mine-on-this-machine switch preset to Yes. The role IS `local_miner.enabled` — the switch below stays live, and flipping it back submits today's config unchanged | `config.json` with `local_miner.enabled: true`; the boot contract's step 5 starts the miner |
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
outranks installer mode on every later boot.

**The rig boot leg belongs to the next phase.** Today a machine carrying `machine-role: rig`
states its role on the console and stops — nothing mines yet, and the message says exactly
that. The Both role is fully live end to end: the boot contract's step 5 already honours
`local_miner.enabled`.

## The certificate lifecycle

**One certificate for the machine's whole life**, at `appliance_tls_dir()`
(`/data/pithead/data/tls`), presented by the wizard *and* by Caddy afterwards.

```
first boot ──> appliance_mint_cert()      idempotent; reuses a cert that still covers the names
                    │
        ┌───────────┴───────────┐
   wizard serves           generate_caddyfile() emits
   (copy in spool)         tls /pithead-tls/wizard.crt
```

Three properties, each earned:

1. **One cert, not two.** Caddy used to mint its own via `tls internal`, replacing the
   wizard's at the moment provisioning succeeded. A second, different self-signed certificate
   for one hostname is not a second warning — Safari refuses outright, Chrome throws
   `ERR_SSL_PROTOCOL_ERROR`. The setup page appeared to die exactly when it had worked.
2. **Minted wherever it is named.** `generate_caddyfile` mints on demand if the pair is
   missing. It was previously created only by the wizard, so any machine that *skips* the
   wizard — a pre-seeded config, or a reinstall whose preserved `/data` already held
   `config.json` — got a Caddyfile pointing at a file that did not exist. Caddy then answered
   `:443` with no usable certificate, forever, and the console was silent because
   `pithead-firstboot.service`'s `ConditionPathExists=!…/config.json` had skipped the unit.
   Rebooting could not clear it; only reflashing or minting could.
3. **Never replaced once trusted.** The mint reuses an existing certificate whose SANs still
   cover the machine's names. Swapping a certificate an operator has accepted is
   indistinguishable from an attack — and the browser treats it that way.

The SHA-256 fingerprint is printed on the console beside the token so the browser warning can
actually be verified. A warning nobody can check is theatre.

**Rule for changes:** if a component serves TLS for this machine, it serves *that* pair. If
minting fails, fall back to `tls internal` and say so — a dashboard behind an unfamiliar
certificate beats no dashboard.

## The boot contract (provisioned machines)

After provisioning, every boot runs one unit — `pithead-boot` — whose five steps each answer
a hardware-validated failure:

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

**Known gap at step 4 — forward-only data migrations.** Today `up` (step 3) starts the whole
stack, monerod and tari included, *before* the commit at step 4. A release that runs a
forward-only lmdb migration would therefore migrate `/data` before the slot commits, so a
failed health check could leave the box unable to commit *or* fall back cleanly. The
migration-deadlock rule (`dual-distribution-plan.md` risk #6) closes this by withholding the
chain services until the slot commits on a `data_migration`-flagged update; that boot-path
change is scoped follow-up. Until it lands, `pithead os-update` already refuses a *manual*
rollback below the `/data` migration floor — see
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
| host logic | `tests/stack/run.sh` | cert minting + idempotence, remote-node preflight, pre-seed, install requests, the digest-keyed image loader, reinstall pre-fill (secret strip + fail-open), the local-miner legs (derived config, sync seeding, boot-leg wiring), the rig-role legs (pool discovery publisher, rig request consumption, the role marker + boot stub) |
| the real thing | `tests/os/run.sh --phase provision` | token from the console → submit → handoff → ack → running stack → built-in miner up and its shares accepted → reboot through a corrupted Caddyfile → no failed units → slot self-commit → miner back |

The orchestration row is the one that was missing. pytest proved the endpoint published the
credentials; a render probe proved the card renders given them; nothing proved the app *asked*.
When adding a step, cover it at the layer that owns the promise **and** at the seam to the next
one.
