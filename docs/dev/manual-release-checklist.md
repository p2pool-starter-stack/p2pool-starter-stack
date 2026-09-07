# The manual release checklist

Everything a release needs that no harness can do for you, and the traps that have actually
bitten. The automated gates are described in [releasing.md](releasing.md) (DIY channel) and
[appliance-release.md](appliance-release.md) (appliance channel); this page is the human half,
and it exists because a checklist nobody wrote down is a checklist nobody runs.

Each item says **why it cannot be automated**. That matters: anything on this list that becomes
automatable should move off it, and anything that keeps biting should get a harness leg.

---

## Before the cut

### Confirm what the harness cannot see

The KVM battery boots a VM on a virtual NIC with a private address, one virtual disk, and no
firmware. It is structurally blind to the following, all of which have produced real defects:

| Check | Why a VM cannot show it |
|---|---|
| No world-addressable address is served | The guest only ever has a private LAN address. A real box gets an ISP-assigned globally-routable IPv6, and the dashboard was found bound to it. |
| Secure Boot, firmware power-on behaviour, real disk topology | No firmware, one virtual disk. |
| Thermals, CPU governor, the hardware watchdog actually resetting a wedged board | A VM has no watchdog device and no heat. |
| First-boot on real media — wall-clock, and what a power cut leaves behind | Writing container storage to a USB stick is nothing like a virtual disk, and the operator experience lives in that gap. An interrupted write to a stick left a store that was present, digest-matched and unrunnable, and it bricked install-from-stick on every later boot (#1029). A virtual disk does not produce that damage; the repair for it is covered at tier 1, the cause is not. |

### Reserve the hardware

Bench resources are shared with other sessions and with RigForge's own gates. Reserve before
touching anything, free when done — see the reservation protocol in
[release-server.md](release-server.md). The loaner rigs carry their own contract at `~/README.md`
on each box: back up the config, repoint, and **restore + restart when the job frees it**.

That protocol covers the **rigs**. It does not cover the appliance under test, which
[#1022](https://github.com/p2pool-starter-stack/pithead/issues/1022) records as having no lock, no
holder marker and no contract file of its own — so nothing stops two sessions working on it at
once, and the battery below reflashes and factory-resets the box. A collision costs whoever else
is holding it both their run and the chain on that disk. Until #1022 lands a mechanism, reserving
the appliance is an agreement between sessions and nothing enforces it: say in your handoff that
you are holding it, and say when you let go.

The appliance cannot copy the rig protocol, and #1022 names the reason: a lock stored *on*
the appliance is destroyed by the very tests that take it. Its reservation has to live on a
coordinator that the reflash does not touch.

### Know which image you are holding

A **debug** image (sshd on, keys baked) is bench equipment. A **release** image is shell-less
with no keys. `verify-image.sh` without `--test` refuses a debug build, and that refusal is the
last thing standing between a development convenience and a published one. Never publish a debug
image; never hand one to a user.

---

## The manual hardware battery (M1–M10)

Defined in [appliance-release.md](appliance-release.md). Run it on a physical box and record the
results in the release issue. Today every item is driven by hand; a harness that automates the
parts a script can reach, and demands typed attestation for the rest, is tracked as #1022 and is
not yet merged. Until it is, this whole battery is a human procedure.

Needs hands, every time:

- **M1 — flash and boot** from a real stick with Secure Boot in its real state.
- **M4 — the wrong-disk guard**, which needs a second physical disk holding unrelated data.
- **M8 — power cut during the update's write phase.** Pull the plug at the wall.
- **M10 — power cut during normal mining.** Same, while the stack is live.

The power-cut items are the ones that justify the whole appliance design (A/B slots, the
health-gated commit, the migration hold). They have never been proven on real hardware.

### Install-path cases worth walking deliberately

- A **fresh** disk.
- A disk that **already holds an installation** — choose *keep* and confirm the chain survives
  (this is M5, and it is where the corrupt-container-store blocker was found: a partially written
  image store left every `podman run` failing, so the wizard never served).
- Reaching the wizard **by mDNS name** and **by IP**, since the appliance serves both.
- Configuring **by paste** for both addresses (M6, which now needs a yes to merge-mining first —
  a new machine is asked for the Monero address only): a wallet address typed by hand is a support
  ticket waiting to happen.

---

## Cutting

1. **Signing must be ON.** Confirm the preflight says so *before* answering the confirmation
   prompt. A release once shipped unsigned because the environment was absent and the script
   only warned; the fix made it refuse, and the check still belongs on this list.
2. **Two-channel versions publish as a draft.** Published release assets are immutable — a
   version was burned exactly this way. Cut with `--draft`, attach both channels' artifacts,
   publish once. Note the git tag is spent at the cut even under `--draft`, so do not start the
   DIY stage until the appliance tree is believed final.
3. **Never pass `--yes` to `os-update` across a variant flip.** Installing a release bundle onto
   a debug box removes the SSH channel driving the install. The prompt exists for exactly that;
   overriding it costs the box's management channel until someone reflashes or rolls back.
4. Record the **hardware battery results** and the **live e2e** evidence in the release issue.

## After publishing

- Post-publish smoke against the published tag, including the upgrade path from the previous
  release on a box that actually runs it.
- Confirm `main` fast-forwarded to the tag — `release.sh` does this at publish. If the push was
  refused, run the command it printed by hand.
- Sync `develop` → the integration branch, so the next cut does not diverge.
- Record the per-rig performance baselines you actually re-tagged (see
  [RELEASING.md in RigForge](https://github.com/p2pool-starter-stack/rigforge/blob/main/RELEASING.md)),
  and reset the rigs' checkouts afterwards — a dirty checkout aborts the next tag deploy.

---

## Watch the operator experience, not just the asserts

A green battery says the machine works. It does not say the product is pleasant. During any
manual run, notice and file:

- Any step that goes silent for more than a minute or two without saying what it is doing or
  roughly how long it will take. A first boot that loads container images from a USB stick is
  the current worst case, and it reads as a hang.
- Any failure that leaves the console showing a stale progress message. A failed first-boot
  service once looked identical to a slow one, forever, which turned a three-minute failure into
  an hour of waiting; that one is fixed, and the shape of it is worth watching for elsewhere.
- Any message that promises a duration the machine cannot keep ("this takes a minute or two").
- Anything you had to know rather than read.

These are release-quality defects for a product whose whole promise is that a non-expert can run
it. File them with what you saw on screen; a photograph of the console is a perfectly good bug
report and has already produced two.
