# The Release / Validation Server

How a build is validated end-to-end before release, why that needs a dedicated server, what
GitHub Actions runs on every PR, and how to harden the server. Operational companion to
[Releasing](releasing.md) (the version/promote pipeline) and
[Integration Testing](integration-testing.md) (the harness it runs).

## Can GitHub Actions do the full end-to-end? (no)

GitHub-hosted runners can't do the real-chain tier. On a public repo the hosted Ubuntu runners
are free (4 vCPU / 16 GiB RAM), but they are ephemeral: a fresh VM per job, ~14 GiB of free
disk, and a 6-hour job ceiling. A pruned Monero chain measures ~258 GiB on our own bench
([#1446](https://github.com/p2pool-starter-stack/pithead/issues/1446)) and an unpruned one is
larger still [TODO: verify upstream — no full-chain measurement exists on this bench]; either
takes days to sync, and Tari adds ~50 GiB. There is nowhere to keep that synced state between runs, and no time
to sync it inside a job. So the real-daemon, real merge-mining tier (tier 4) is not possible on
hosted runners. That's the reason a dedicated, already-synced server exists
([#54](https://github.com/p2pool-starter-stack/pithead/issues/54)).

GitHub already runs almost everything else, free, on every PR. Tiers 1–3 of the
[testing strategy](testing-strategy.md) need no real chain and run on the hosted runners in
minutes:

- Tier 1, unit/component (dashboard pytest + coverage gate, frontend, the `pithead` shell
  suite, compose interpolation, and the #90 security/hardening invariants).
- Tier 2, contract (the real Monero/Tari clients vs. controllable fakes).
- Tier 3, the fake-daemon mini-stack (the real dashboard + docker-control proxy driven against
  fake daemons, with real Docker on the hosted runner). This proves the control plane
  end-to-end (sync hold/release, reject/readmit) on every PR.

So the split is clean:

| | Runs | Cost | Triggered |
|---|---|---|---|
| **Tiers 1–3** (logic, wiring, control plane, hardening) | GitHub-hosted runners | free (public repo) | every PR, the merge gate |
| **Tier 4** (real synced Monero+Tari, real merge-mining, prune/full DB, TLS/Tor, the config matrix, the staging smoke test) | the dedicated server | your hardware | pre-release / on-demand, the release gate |

The hosted runners catch most regressions before merge. The dedicated server proves what only
real chains can, and it is the blocking pre-release gate.

## Validating PRs on the dedicated server (possible, but security-loaded)

You can register the server as a GitHub Actions self-hosted runner so Actions dispatches the
tier-4 job to it (self-hosted minutes don't count against anything, also free). But there is a
sharp edge, and it's the single most important thing on this page:

> NOTE: GitHub explicitly recommends against self-hosted runners on public repositories. Any
> user can open a pull request, and a malicious PR can run arbitrary code on the runner. The
> server holds real wallet payout addresses, Tor onion private keys, and RPC credentials, so a
> compromised runner is a key-theft / persistent-backdoor event, not a flaky build.

The safe rule: the keyed server only ever runs code you trust. Concretely:

- Do not trigger tier-4 on `pull_request` (and never on a fork PR). "Require approval" only
  gates starting the run; once it starts, the PR's code still executes on the box.
- Trigger tier-4 only on trusted code: `workflow_dispatch`, on a ref a maintainer has reviewed.
  A `push`-to-`main` trigger is no longer an alternative — `main` only moves when a release
  fast-forwards it at publish time, after this gate should already have run. To E2E a specific
  fork PR, a maintainer reviews it first, then dispatches the workflow on that ref.
- Register the runner as ephemeral / just-in-time (one job, then auto-removed) in its own runner
  group, isolated from any private repos.
- Keep the runner least-privilege: a dedicated unprivileged user, the box runs nothing else
  sensitive, and ideally the runner reaches the stack only through `pithead`/`docker`, not the
  raw key files.

This is how the workflow ships.
[`.github/workflows/release-gate.yml`](../../.github/workflows/release-gate.yml) runs only on
`workflow_dispatch`, on a `[self-hosted, pithead-release]` runner, never automatically on a PR
and never on a push: no runner is registered, and a trigger that arrives before its runner is
how `main` ends up wearing a gate that never ran (#1048). Since releases fast-forward `main`
at publish time, a `push` trigger would also fire *after* the release it was meant to gate —
any future automation belongs on the ref being cut, not on `main`.

## Provisioning the server

Target an LTS Ubuntu (22.04 / 24.04). One-time:

1. Install Pithead and let it fully sync ([Getting Started](../getting-started.md)): full Monero +
   full Tari, all containers healthy, a worker (ideally two) mining. The synced
   `monero.data_dir` / `tari.data_dir` are the asset the harness reuses.
2. Keep the active chain on fast storage (SSD/NVMe). monerod is random-I/O heavy, so the chain
   it runs against must not sit on a spinning HDD; that alone makes every scenario crawl. A
   snapshot/reflink-capable filesystem (btrfs/zfs/xfs reflink) is a bonus: it lets the harness
   snapshot/restore a chain cheaply for the prune axis. It's optional. On plain ext4-on-SSD the
   matrix only edits `config.json` and reuses one chain, with `--safety-backup` isolating
   destructive runs. See the recipe below for the prune-axis details.
3. Disk headroom: enough for the chains plus a snapshot / second DB (budget ≥ ~150 GiB free
   beyond the live chains).
4. Tools: `jq`, `curl`, `docker` (compose v2), `sha256sum`, `git`, `tar`.

Check the box is fit at any time, non-destructively:

```bash
tests/integration/run.sh --host you@server --dir pithead --readiness
```

It asserts: chains synced (reusable), the prune axis is exercisable (the live chain FS is
snapshot-capable **or** a pre-built variant chain is supplied), disk headroom, `.env` is
owner-only, the dashboard is bound to localhost, and the backup/rollback net is usable.

### The lint/release toolchain

`make release`'s blocking test gate runs `make lint`, which shells out to `shellcheck`, `shfmt`,
`node`/`npx`, and `uv`/`uvx`. A reimaged box loses these, so the release preflight
([#426](https://github.com/p2pool-starter-stack/pithead/issues/426)) stops early and names the
missing tool rather than dying mid-gate. Restore them with the same pinned versions CI uses
([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) — apt's `shellcheck`/`shfmt` are older
and reformat differently, so a version skew would fail `make lint` on the box for diffs the merge
gate never saw. `shellcheck`'s pin lives in the `Makefile` as `SHELLCHECK_VERSION`, which is what
`ci.yml` installs and what `make lint-sh` refuses to run without; `make -s print-shellcheck-version`
prints it, so the version below is a copy and that command is the source:

```bash
# node 20 (brings npx) + the basics the harness also needs
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs jq curl git tar

# shellcheck 0.11.0 (= make -s print-shellcheck-version) + shfmt 3.13.1 (pinned, not apt's)
curl -fsSL https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz | tar -xJ -C /tmp
sudo install -m 0755 /tmp/shellcheck-v0.11.0/shellcheck /usr/local/bin/shellcheck
sudo curl -fsSL -o /usr/local/bin/shfmt https://github.com/mvdan/sh/releases/download/v3.13.1/shfmt_v3.13.1_linux_amd64
sudo chmod 0755 /usr/local/bin/shfmt

# uv 0.10.10 (pinned installer; brings uvx, and adds ~/.local/bin to PATH)
curl -LsSf https://astral.sh/uv/0.10.10/install.sh | sh
```

### The release signing key

The pipeline signs every promoted image digest and the install bundle with cosign
([#376](https://github.com/p2pool-starter-stack/pithead/issues/376), key-based — see
[Releasing › Signed releases](releasing.md#signed-releases) for what installs verify and how).
The private key lives only on this box, like the GHCR token; the public key is committed in the
repo as `cosign.pub`. The release preflight refuses to run without cosign, `COSIGN_KEY`,
`COSIGN_PASSWORD`, and `cosign.pub` all in place — signing is mandatory to publish because it is
mandatory to consume ([#960](https://github.com/p2pool-starter-stack/pithead/issues/960)), so a
missing piece aborts the cut rather than warning past it. `--dry-run` reaches the same decision and
skips only the signing, so a rehearsal on this box tells you whether the real cut would sign.

Preflight then proves the key end to end: it signs a probe blob and verifies it through the same
digest-pinned cosign container installs use. A `cosign.pub` that is no longer the public half of
`COSIGN_KEY` fails here rather than in the field
([#1084](https://github.com/p2pool-starter-stack/pithead/issues/1084)).

Install cosign (pinned — there is no Ubuntu apt package; the same snippet works on any host that
wants to verify). Take **v2.6.3**, not the newest: cosign v3 removed the `--tlog-upload` flag both
signing calls pass, and a drifted box would otherwise pass every other check and die at the signing
stage with the images already promoted. Preflight probes for the flag and aborts early if it is
gone.

```bash
curl -fsSL -o /tmp/cosign https://github.com/sigstore/cosign/releases/download/v2.6.3/cosign-linux-amd64
echo '7c78a7f2efc00088bd788a758db6e0928e79f3e0eb83eb5d3c499ed98da4c4f4  /tmp/cosign' | sha256sum -c
sudo install -m 0755 /tmp/cosign /usr/local/bin/cosign
```

Generate the key pair once, on this box:

```bash
cosign generate-key-pair      # prompts for a passphrase; writes cosign.key + cosign.pub
mkdir -p ~/.config/pithead-release
mv cosign.key ~/.config/pithead-release/cosign.key
chmod 600 ~/.config/pithead-release/cosign.key
```

Commit the `cosign.pub` it wrote at the repo root (it is the only half that ever enters the
repo), and point the release shell at the private half:

```bash
export COSIGN_KEY=~/.config/pithead-release/cosign.key
read -rs COSIGN_PASSWORD && export COSIGN_PASSWORD   # typed, not in shell history
```

Both are also defaults now: the preflight falls back to
`~/.config/pithead-release/cosign.key` when `COSIGN_KEY` is unset, and reads
`~/.config/pithead-release/cosign.passphrase` (a `chmod 600` file) when `COSIGN_PASSWORD` is
unset — so a cut on this box needs no signing exports at all. The passphrase file is optional:
delete it to be prompted per cut via the `read -rs` line above.

cosign reads `COSIGN_PASSWORD` from the environment to decrypt the key; neither the key nor the
passphrase ever appears on a command line, in the repo, in an image, or in the release log. Keep
an offline backup of `cosign.key` with the passphrase stored separately — losing it means
rotating the key. To rotate: generate a new pair the same way, commit the new `cosign.pub`, and
cut a transition release **signed with the old key** (leave `COSIGN_KEY` on the old key for that
one cut) — installs verify the bundle with the key they already hold and come out holding the new
one; switch `COSIGN_KEY` to the new key for the next release. If the old key is lost or
compromised, sign with the new key immediately: the transition release then fails the bundle
check on existing installs, so call it out in the release notes and have operators verify that
one by hand against the new committed key.

### The RAUC update-signing key

cosign signs the GHCR image digests and the install bundle. The **appliance** takes a second,
independent signature: every A/B update bundle (`os/rauc/mkbundle.sh` → `*.raucb`) is signed, and
RAUC on the device refuses any bundle that does not verify against the keyring baked into the
running slot (`os/rauc/system.conf` → `[keyring] path=/etc/rauc/keyring.pem`). This key is the
appliance fleet's update trust root: whoever holds it can push a bundle every fielded box will
install as authentic. Treat it exactly as you treat `cosign.key`.

The tooling refuses to invent one. `mkimage.sh` / `mkbundle.sh` auto-generate a throwaway
`CN=pithead-dev` key only for a build explicitly marked `--dev`; a release build (no `--dev`) exits
non-zero unless the key is named:

- `PITHEAD_RAUC_KEY` / `PITHEAD_RAUC_CERT` — the leaf that signs the bundle (private key + its
  cert/chain).
- `PITHEAD_RAUC_KEYRING` — the cert(s) baked into every slot as the device trust anchor. Defaults
  to `PITHEAD_RAUC_CERT`; for the root+leaf model below, set it to the **root** so a leaf can be
  rotated without re-imaging.

So a dev cert can never silently become a shipped keyring — the guard, not memory of this page, is
what enforces it.

**Trust model: root + leaf, only the root baked.** Use a two-cert chain, not one self-signed cert
doing both jobs. A single self-signed cert used as both trust anchor and signer is the shape the
bake-off found stricter verifiers reject (`CaUsedAsEndEntity`), and it couples the two rotations
that should be independent: the root that every device trusts is baked into the image and cannot
change without re-imaging, while the leaf that signs day-to-day should be cheap to replace. Bake
the **root** as the keyring; sign bundles with a **leaf** issued from it. RAUC verifies the bundle's
leaf against the baked root, so a leaf reissued from the same root is trusted by every fielded box
with no image change.

Generate the pair once, on this box (RSA-4096 mirrors the dev chain; the root is a CA, the leaf is
a `digitalSignature` end entity):

```bash
mkdir -p ~/.config/pithead-release && cd ~/.config/pithead-release

# Root — the device trust anchor. Baked into every slot; its private key is used ONLY to issue
# leaves, so keep it offline and out of the release shell's environment.
openssl req -x509 -newkey rsa:4096 -keyout rauc-root.key -out rauc-root.pem \
    -days 3650 -subj "/CN=pithead-update-root" \
    -addext "basicConstraints=critical,CA:TRUE"        # prompts for a passphrase

# Leaf — the day-to-day signer, issued from the root.
openssl req -newkey rsa:4096 -nodes -keyout rauc-signer.key -out rauc-signer.csr \
    -subj "/CN=pithead-update-signer"
openssl x509 -req -in rauc-signer.csr -CA rauc-root.pem -CAkey rauc-root.key \
    -CAcreateserial -out rauc-signer.pem -days 825 \
    -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n')

chmod 600 rauc-root.key rauc-signer.key
chmod 700 ~/.config/pithead-release
```

**Storage.** The root private key (`rauc-root.key`) is the crown jewel: keep it offline (an
encrypted volume or a hardware token), passphrase-protected, and off this box between rotations —
it is needed only to mint a new leaf, never to cut a routine release. The leaf key
(`rauc-signer.key`) lives on this box like `cosign.key`, `chmod 600`, owner-only, with an offline
backup. Only the certs (`rauc-root.pem`, the leaf `.pem`) are ever safe to hand out; neither
private key enters the repo, an image, or a log. Point the release shell at the release material:

```bash
export PITHEAD_RAUC_KEYRING=~/.config/pithead-release/rauc-root.pem     # baked as the device keyring
export PITHEAD_RAUC_CERT=~/.config/pithead-release/rauc-signer.pem      # leaf that signs the bundle
export PITHEAD_RAUC_KEY=~/.config/pithead-release/rauc-signer.key
```

`mkimage.sh` bakes the keyring cert into slot A; `mkbundle.sh` signs the bundle with the leaf. Both
refuse to run for a release with these unset — there is no silent fallback to a dev cert.

**Rotation.** The constraint that shapes the whole runbook: **RAUC trusts the keyring baked at
image build time, so a device only ever trusts what shipped in its running slot.** A new trust
anchor therefore has to reach devices *inside an OS update they already trust*, before any bundle
is signed under it — a keyring is not something a device can be told to add out of band.

- *Routine, or a leaf compromise (root intact).* Issue a fresh leaf from the same root (the second
  `openssl` pair above), and sign with it. Every fielded box already trusts the root, so nothing
  needs re-imaging. This is the case root+leaf exists for, and it should be the only one you ever
  hit in practice.
- *Root rotation (planned key change, or a suspected root compromise you can still sign around).*
  You cannot swap the anchor in one step. Build a **transition OS update** whose baked keyring
  contains **both** the old and new roots (concatenate the PEMs), and sign that bundle with a leaf
  under the **old** root so existing boxes accept it:

  ```bash
  cat rauc-root.pem rauc-root-new.pem > rauc-keyring-transition.pem
  PITHEAD_RAUC_KEYRING=~/.config/pithead-release/rauc-keyring-transition.pem \
    PITHEAD_RAUC_CERT=~/.config/pithead-release/rauc-signer.pem \
    PITHEAD_RAUC_KEY=~/.config/pithead-release/rauc-signer.key \
    ...build image + bundle...
  ```

  Ship it and wait for the fleet to take it. Only once a box is running that slot does its keyring
  trust the new root; from then on you may sign with a leaf under the new root. A later update can
  bake the new root alone and drop the old one. Sequencing is everything — sign under the new root
  before the fleet has taken the transition update and those boxes reject the bundle.
- *Root lost or compromised beyond signing (you can no longer produce a bundle the fleet trusts).*
  There is no remote recovery, the same dead end as a lost `cosign.key`: fielded devices trust only
  the baked root, so a bundle signed by anything else is refused. Recovery is a hands-on re-image
  of each box with a fresh keyring. Call it out in the release notes and, as with cosign, have
  operators verify the first post-incident image by hand against the new published root.

The dev/bench loop is unchanged — `os/rauc/mkimage.sh --dev` still auto-generates a throwaway into
the gitignored `os/rauc/certs/` and needs none of the above.

### Recipe: prune-axis coverage, and the storage that matters

Put the active chain on fast storage. The biggest factor is the disk, not the filesystem:
monerod does heavy random LMDB I/O, so a chain on a 7200 rpm HDD makes every scenario crawl.
Check what you have before placing chains:

```bash
lsblk -d -o NAME,ROTA,SIZE,MODEL   # ROTA=0 is SSD/NVMe, ROTA=1 is a spinning HDD
```

Keep the chain monerod runs against on an SSD/NVMe. A spare HDD is fine for cold backups and
`pithead backup` archives, but not for an active test chain.

A CoW filesystem (btrfs/zfs/xfs-reflink) is a bonus, not a requirement. On a CoW volume the
harness can snapshot/restore a chain cheaply for per-scenario isolation, but only if it's on
fast storage. A loopback btrfs on a spare HDD gives you CoW semantics at HDD speed, which is the
wrong trade for an active chain. If your root FS is ext4 on an SSD (the common case) you don't
need CoW at all: the matrix only edits `config.json` and reuses one chain, and `--safety-backup`
(a `pithead backup` + auto-rollback) isolates the destructive scenarios.

Covering both prune modes. The box mines one mode (its real config). The harness exercises that
mode against the live chain and skips the other unless you supply a chain for it
(`--full-data-dir` / `--pruned-data-dir`). You usually don't need to: the opposite mode is
covered by the fake mini-stack ([integration-testing](integration-testing.md)) plus the
compose/config tests, which need no real chain. Supply the opposite-mode chain only to exercise
it end-to-end, and build it on fast storage:

- Pruned chain next to a full one? [`build-pruned-chain.sh`](../../tests/integration/build-pruned-chain.sh)
  copies the LMDB consistently (brief monerod stop, then immediate restart) and prunes the copy,
  leaving the canonical chain untouched. Fetch `monero-blockchain-prune` at the same version as
  the running monerod and verify it against the hash the image pins (`build/monero/Dockerfile`
  → `MONERO_VERSION` / `MONERO_HASH`).
- Full chain? Pruning is irreversible, so a full chain means a fresh full sync
  (`MONERO_PRUNE=0`, ~1–3 days), rarely worth it just for test coverage.

The reference box is a pruned node on NVMe: it validates pruned mode live with `--safety-backup`,
and full mode comes from the fakes. `--readiness` reports exactly this:

```bash
tests/integration/run.sh --host you@server --dir pithead --readiness
```

> NOTE: a pruned chain's file stays large. An in-place prune does not shrink the LMDB file: it
> stays at the full-chain high-water mark, with the freed space sitting as internal free pages
> (Monero reuses them as the chain grows). **How much is actually reclaimable is a measurement,
> not an assumption** — `mdb_stat -ef` on an idle copy reports the freelist, and on this bench it
> is 10 pages out of 67,605,667, so there is nothing to reclaim (#1446). To reclaim it where there
> is, you must rewrite the DB with
> `monero-blockchain-prune` (see
> [`compact-chain.sh`](../../tests/integration/compact-chain.sh)). It's slow (it copies every block
> over hours), though it reads through a snapshot so monerod keeps mining.
>
> **The tool is copy-then-swap, so it does not leave the swap to you.** It renames
> `<data-dir>/lmdb` aside and moves the pruned DB into place — pointed at a live node's data dir
> that renames the live chain out from under a running monerod, silently until the next restart.
> To run it against a live chain, bind-mount the source so the kernel refuses the rename; the
> recipe and its guard are in `compact-chain.sh`'s header.
>
> `MDB_VERSION_MISMATCH` from a stock LMDB tool is the **lock-file** format, not a patched on-disk
> format: it appears while monerod holds the environment, and the same tool opens an idle copy of
> the same chain. Measured here on monerod 0.18.5.1, where both DBs read magic `0xbeefc0de`,
> version 1 (#1446) — one bench, one build, so treat the reading as ours rather than universal.
> It is not corruption — do not stop monerod over it. Often the best move is to leave the free pages alone.

## Bench allocation and the rig lock

The bench boxes are shared between this repo's tier-4 harness, RigForge's release gates, and
production mining. Two automations cycling the same rig's services corrupt each other's results
(a real 2026-07 incident: an operator "fixed" a service an e2e run had deliberately stopped),
so ownership is static and every run takes a kernel lock.

Static allocation — each box states its owner in `/etc/bench-role`, and each box's own
`~/README.md` carries its specifics (hostname, role, data roots):

| Box role | Owner | Use |
|---|---|---|
| RigForge bench rig | RigForge | `e2e-real` / tune gates. Pithead never touches its services. |
| Loaner rigs (two) | Pithead | Tier-4: `e2e.sh` repoints one at the test bench for a run, then reverts it. Verify `systemctl is-active xmrig` after any remote restart. |
| Fleet rigs | Production | Mining only. No test traffic. |
| Test bench | Pithead | Test bench + release box (the tier-4 target). |
| Production host | Production | Production stack; deploys only. |

The run lock — **RESERVE**. Both harnesses take a `flock` on `/var/lock/rig-e2e.lock` before
the first service-touching action and hold it on an inherited FD for the whole run, so the kernel releases
it the moment the run dies — `kill -9` included, no stale-lock cleanup. rigforge#183 defines the
mechanism; [#430](https://github.com/p2pool-starter-stack/pithead/issues/430) is this repo's
mirror; the shared path on every box is the protocol. Mutating runs hold it exclusive; read-only
runs (`run.sh --check` / `--readiness`) hold it shared, so concurrent readers coexist but still
exclude mutators. `tests/integration/run.sh` takes it on the target box (over SSH for `--host`);
`e2e.sh` also takes it on the loaner rig it borrows. A busy box makes the run exit 75
(`EX_TEMPFAIL`) naming the holder; set `RIG_LOCK_WAIT=1` to queue instead.
`/run/rig-e2e.holder` is a display-only sidecar naming the holder — the flock is authoritative,
and a stale sidecar is harmless.

**CHECK** — and **FREE**, which is not a step. Off-box actors (a human or an agent over SSH)
touch services on a shared box only after the same check. Nothing releases the lock afterwards: it
lives on an inherited descriptor, so the kernel drops it when the run ends, however it ends. A
holder that has to remember to free is a holder that eventually does not:

```bash
ssh <box> 'flock -n -x /var/lock/rig-e2e.lock true' || ssh <box> 'cat /run/rig-e2e.holder'
ssh <box> 'cat /etc/bench-role'   # the box's static owner
```

## Hardening checklist (the pitfalls)

Treat the box as production-sensitive. It holds keys and it's the thing that signs off releases.

- Secrets. `.env` (RPC creds), `config.json` (wallet addresses), and the Tor data dir (onion
  private keys) must be owner-only (`chmod 600 .env`; the `--readiness` check verifies this).
  Never print secrets in logs; the harness hashes them on the box and redacts artifacts. If the
  box also publishes releases, the GHCR token lives in the environment / a secret store, never in
  the repo — and so do the release signing keys: `cosign.key` + `COSIGN_PASSWORD`
  ([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)), and the RAUC update leaf
  key (`rauc-signer.key`) with the RAUC root key kept offline entirely — all owner-only on this
  box, only their certs/public halves ever committed or handed out (see the signing-key sections
  above).
- Network. Firewall to least exposure: inbound SSH (key-only, no root login, fail2ban) and the
  stratum port scoped to the LAN ([workers › firewall](../workers.md#firewall)); the dashboard
  stays on localhost behind Caddy and the monerod RPC on localhost (both asserted by
  `--readiness`). Nothing else should be reachable from the internet.
- Untrusted code. The runner only runs trusted code (see above). Prefer ephemeral/JIT runners;
  don't share the runner with private repos.
- Least privilege. A dedicated unprivileged user; the stack already runs least-privilege
  containers (`no-new-privileges`, `cap_drop`, read-only roots, scoped Docker socket proxies,
  regression-guarded in `tests/stack/test_compose.sh`).
- Reproducible, clean baseline. The matrix reuses the synced chains and never mutates the
  canonical copies (config-only changes, snapshot/restore for the prune axis), restores the
  original `config.json` at the end, and `--safety-backup` takes a `pithead backup` first and
  rolls the box back (down → restore → up) if anything fails.
- Build isolation and integrity. Build images in containers with pinned upstream versions and
  SHA256-verified binaries (the stack already does this); promote releases by digest so the
  published bundle is bit-for-bit what was validated ([Releasing](releasing.md)).

## How a release is validated end-to-end

1. Every PR → GitHub-hosted runners run tiers 1–3 (the merge gate). Cheap, free, fast.
2. Pre-release (or on-demand for a reviewed PR) → a maintainer dispatches the release-gate
   workflow on the dedicated server: `make test` (tiers 1–2 on the trusted box) plus the tier-4
   live matrix against the real synced nodes (`run.sh --safety-backup`), then per
   [Releasing](releasing.md) the staging smoke test: pull each staged image back from GHCR and
   verify its version label and target platforms — no stack is started; a functional run against
   the staged tag is opt-in via `RELEASE_SMOKE_CMD`.
3. Nothing is tagged or published until that's green, and promotion is by digest, so the version
   users get is the exact bundle the server validated.

## End-to-end coverage & gaps

What the live tier-4 gate exercises, and what it doesn't, so a release decision is made with eyes
open. (The reference box is a pruned Monero node on NVMe; its own snapshot and this table also
live at `~/pithead-testbench/` on the box, for operators and AI agents.)

Validated live (real synced chains): the config matrix (remote/local node, dashboard
secure/insecure, Tari required/optional, RPC LAN access, XvB on/off) applied + asserted; lifecycle
(restart, secret-preserving `apply`, backup→restore round-trip); node-down failover → recovery;
release readiness; pruned monerod (the real prod config). Covered without a real chain (tiers
1–3): client↔daemon contract tests, the fake-daemon mini-stack (incl. full-prune behavior),
compose hardening, config rendering, dashboard tests.

| Gap (not tested live) | Worth filling before release? |
|---|---|
| Full (unpruned) Monero live, which a pruned box can't exercise | Low. Stack paths don't differ by prune mode; fakes/config cover it. A multi-day full sync isn't justified. |
| Privacy / Tor egress: no clearnet-leak assertions in the live harness (#160) | High. Privacy is a core promise. Add egress checks (no clearnet to XvB stats, p2pool, Tari DNS). |
| Automated PR gate: the self-hosted runner is manual/opt-in | Medium-high, high-value. Wire the live harness as a required check on `workflow_dispatch`/push-to-`main` only (never fork PRs). |
| Upgrade / migration across image versions with chain continuity | Medium. Add a scenario: pull new images → `apply` → assert no re-sync + secrets intact. |
| XvB live routing end-to-end (the raffle optimization) | Medium. Core value-prop but unit/sim-tested today; a periodic live smoke test would help. |
| Multi-worker scale: the harness assumes ~2 workers | Medium. Add a load-gen worker + assert proxy routing/hashrate for perf confidence. |
| Real Tari merge-mined block acceptance | Low. Probabilistic; rely on template/connectivity checks. |
| Fault injection over SSH (currently local-mode only) | Low-Medium. Extend the SIGSTOP/remove cases to the `--host` path. |

Recommended before release: the privacy-egress checks and the automated PR gate; then the
upgrade scenario and an XvB live smoke test. The remainder are nice-to-have.
