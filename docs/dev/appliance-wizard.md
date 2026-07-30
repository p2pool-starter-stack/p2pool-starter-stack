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
| `installer` | `disks.tsv` exists (host booted from removable media with a target) | disk picker |
| `installing` | `install-target` or `installed` exists | progress, then the switch-off steps |
| `handoff` | `handoff.json` exists and `handoff-ack` does not | credentials card |
| `done` | `applied` or `handoff-ack` exists | provisioning notice |
| `setup` | none of the above | the config form |

Order matters: `handoff` is checked before `done`, because `applied` is written first and the
credentials must win while they are still unsaved.

**Why the server owns this.** Two defects came from the client deciding:

- A client-side stage flag was set with `setState` and read back on the next line. Preact
  batches, so the read saw the *old* value and the credentials card could never render — for
  two releases. Server-owned stage removes the variable that could be stale.
- A page refresh mid-provisioning was handed the setup form again, because the client had no
  way to know a config had already been accepted.

**Rule for changes:** any new step is a new spool file and a new `wizard_stage()` branch.
Never a client flag. `/api/wizard-state` carries the handoff payload inline for the same
reason — a separate fetch is a separate race.

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

After provisioning, every boot runs one unit — `pithead-boot` — whose three steps each answer
a hardware-validated failure:

1. **`pithead render`** — regenerate every *derived* file (`.env`, Caddyfile, service configs,
   host units) from `config.json` plus the program that is actually running. Derived files are
   never inspected or repaired, only rebuilt: an A/B update swaps the whole program, and a
   bench machine once served a days-old Caddyfile whose site list predated the code around it.
   On the read-only root, host units render into `/run/systemd/system` (`--runtime`
   enablement) and are recreated here each boot.
2. **`pithead up`** — compose owns the containers' lifecycle. Its predecessor,
   `podman-restart`, started the stack into its own oneshot cgroup, and systemd SIGKILLed the
   containers it had just spawned.
3. **Health-gated slot commit** — `rauc status mark-good` only once the dashboard answers
   through caddy on a *listed* vhost (`localhost`; bare `127.0.0.1` hits Caddy's empty default
   site and proves nothing). A slot that boots but cannot serve stays uncommitted on purpose:
   that is the state A/B fallback exists for. Unprovisioned machines never commit — GRUB's
   clear-and-retry keeps them booting, and a bad update before provisioning reverts.

**Rule for changes:** anything generated from `config.json` or the program is derived and must
be rebuilt by `render` — adding one anywhere else recreates the staleness bug. Genuine state
(`config.json`, wallets, chain data, Tor keys, generated secrets) is never regenerated; it
gets validation and a safe fallback instead.

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
| host logic | `tests/stack/run.sh` | cert minting + idempotence, remote-node preflight, pre-seed, install requests |
| the real thing | `tests/os/run.sh --phase provision` | token from the console → submit → handoff → ack → running stack → reboot through a corrupted Caddyfile → no failed units → slot self-commit |

The orchestration row is the one that was missing. pytest proved the endpoint published the
credentials; a render probe proved the card renders given them; nothing proved the app *asked*.
When adding a step, cover it at the layer that owns the promise **and** at the seam to the next
one.
