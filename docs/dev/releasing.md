# Releasing

How Pithead is versioned and released
([#44](https://github.com/p2pool-starter-stack/pithead/issues/44)). The pipeline is
implemented as [`scripts/release.sh`](../../scripts/release.sh). Run it from the build/test
server with `make release` (preview a run with `make release ARGS="--dry-run"`).

## One product, one version

Pithead is versioned and released as a single product, not as individual components.

The components are upstream projects pinned and integrated, not authored here: `p2pool`
(`ARG P2POOL_VERSION`), `xmrig-proxy` (`ARG XMRIG_PROXY_VERSION`), `monerod`
(`ARG MONERO_VERSION`), and `tari` (`quay.io/tarilabs/minotari_node:v5.3.1-mainnet`,
pinned by digest in `docker-compose.yml`). The first-party code is the dashboard plus the
orchestration (`pithead`, `docker-compose.yml`, configs). The integration matrix validates the
composed set. A release is one artifact with one version, one changelog, one upgrade path, and
one "new version available" signal.

Trade-off: swapping a single component to a version not tested together is unsupported. You can
override an ARG or image tag locally, but that combination is not a supported release.

## Single source of truth

The product version lives in a top-level [`VERSION`](../../VERSION) file: plain text, one line,
[SemVer](https://semver.org/spec/v2.0.0.html). Nothing else hardcodes the version:

- `pithead` reads it for tagging and upgrade.
- The dashboard bakes it in for display ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- Released images carry it in the `org.opencontainers.image.version` OCI label.
- The dashboard's `pyproject.toml` is kept in lockstep (packaging metadata only); a shell test fails
  if it drifts from `VERSION`.

> NOTE: `VERSION` holds the last released version. Set it to the version you want to publish; the
> `pyproject.toml` metadata must match, enforced by the drift-guard test.

## Component pins = an ingredients manifest

Every component stays pinned (build ARGs and image tags). The pins are the ingredients lockfile
of each product release, not independent releases:

- The dashboard surfaces them as "what's inside vX.Y.Z" (component info is already shown).
- Bumping any component, including a security patch such as a `monerod` CVE, is a normal stack
  release: bump the pin → cut a stack patch → re-run the integration gate → ship. The bundle
  ships re-tested.

Noticing that a bump is available is a separate job from making one, and nothing did it until
`scripts/pin-watch.sh`. It runs weekly from `.github/workflows/pin-watch.yml`, compares each pin
against the component's latest upstream release, and keeps one tracking issue up to date. It
reports and never bumps: a Tari or `monerod` minor can carry a one-time data migration, which is
work to schedule rather than a pull request to merge. Dependabot covers the base images it can see
and is set to ignore minor and major bumps on the component pins for the same reason.

A lookup that could not be made is reported as unchecked, never as current, and the run fails. The
report carries the date of the last fully successful check, so a watcher that has stopped looks
different from one with nothing to say.

## Published images: GHCR, single-tag model

Images are published to GitHub Container Registry (`ghcr.io/p2pool-starter-stack/*`). Public
images pull without a Docker Hub-style rate limit.

The stack is multi-container. Every built image (`pithead-dashboard`, `pithead-p2pool`,
`pithead-xmrig-proxy`, `pithead-monero`, `pithead-tor`) is published, all tagged with the single
stack version, and compose references one `${STACK_VERSION}`. `docker compose pull` fetches the
set with one knob, replacing the "git pull + rebuild" upgrade path. The version is the bundle,
not the layers.

## Release process

Releases are cut on a private build/test server that runs the full Monero and full Tari nodes
(the integration-test environment from
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)). A single entry point,
`make release` (or `pithead release`), runs the pipeline. Nothing is promoted or published until
every gate is green.

> How to provision and harden that server, why end-to-end validation can't run on GitHub-hosted
> runners (and what does run free on every PR), and the safe self-hosted-runner setup are covered
> in [Release / Validation Server](release-server.md).

### Branch mechanics

Releases are cut from `develop`. Land the release-prep commit (`VERSION`, `pyproject.toml`, the
`CHANGELOG.md` entry) as a normal PR, run the pipeline with that commit checked out, and publish:
the tag lands on it, and `release.sh` then moves `main` to the tagged commit with a fast-forward
push. `main` keeps its meaning — the last released commit — and stays an ancestor of `develop` by
construction, so there is no back-merge and no post-release repair step ([#1076]; releases through
v1.19.3 instead merged `develop` into `main` and back, and the back-merge was missed on v1.19.0).
Commits that land on `develop` after the prep commit sit ahead of `main`, the normal state
between releases — cut with the prep commit checked out, not whatever `develop` has moved on to.
`release.sh` warns (it does not abort) when the working tree is on any branch other than
`develop`.

The fast-forward push cannot ride a PR: GitHub merges a PR by merge commit, squash, or rebase,
each of which mints a new commit, and the point is that `main` gains no object the tag does not
already name. The Main Branch ruleset requires PRs from everyone except organization admins, so
`release.sh` relies on the same admin bypass the release's protected tag push already uses. If
the push is refused, the script says so and prints the command to run by hand; the release
itself is unaffected — `main` merely lags until an admin runs it.

Release-note prose that once lived in the `main` merge commit's body belongs in the GitHub
Release notes, where operators actually read it. The branch model itself is in
[CONTRIBUTING.md](../../CONTRIBUTING.md#development-workflow).

[#1076]: https://github.com/p2pool-starter-stack/pithead/issues/1076

### Pipeline: stage → smoke-test → promote

1. Preflight: clean working tree; read the product version from the top-level `VERSION` file;
   confirm `vX.Y.Z` isn't already released; resolve the component pins into the ingredients
   manifest.
2. Test gate (blocking): run the existing tests (`make test`: lint + dashboard pytest ≥ 80% +
   the `pithead` shell suite + compose validation) and the
   [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration matrix against
   the real nodes. Abort the release on any failure. See [Pre-release gate](#pre-release-gate-54).
3. Build: build the first-party images with the pinned upstream versions baked in and OCI labels
   stamped (`org.opencontainers.image.version` = the `VERSION` value, source revision, etc.). The
   dashboard already reads `PITHEAD_VERSION` / git build-args for its header badge
   ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)); a release build must pass
   `PITHEAD_RELEASE=1` (and `PITHEAD_VERSION` from `VERSION`) so the badge shows the clean
   `vX.Y.Z` rather than the `dev · branch @ hash` it shows for working-tree builds.
4. Push to staging: push to a staging tag on GHCR (e.g. `:vX.Y.Z-rc.N`) and capture the
   immutable digests. Nothing user-facing points here yet.
5. Staging smoke test (gate): pull each staged image back from GHCR and verify it resolves,
   reports the release version in its OCI label, and carries every target platform (the v1.0.0
   wrong-arch guard). This validates the bytes actually pushed, not the local build — but it does
   not start a stack, which would collide with the release host's live deployment. A fuller
   functional run is opt-in: set `RELEASE_SMOKE_CMD` to a command to run during this stage, or
   point the [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) harness at the
   staged tag. Abort on failure.
6. Promote by digest: re-tag the exact digests just smoke-tested to `:vX.Y.Z` and `:latest`,
   then push. Promotion is by digest (no rebuild), so the released bundle is bit-for-bit what was
   validated. Same version on every image.
7. Sign ([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)): cosign-sign each
   promoted manifest-list digest and the install bundle with the key on the release server. See
   [Signed releases](#signed-releases).
8. Publish GitHub Release: create the git tag `vX.Y.Z`, fast-forward `main` to the tagged commit
   (see [Branch mechanics](#branch-mechanics)), write the release notes from the `CHANGELOG.md`
   entry, and attach release assets: a pinned `docker-compose.yml` / config bundle referencing
   `${STACK_VERSION}=vX.Y.Z`, its detached signature (`pithead.tar.gz.sig`), plus the ingredients
   manifest (exact component versions + promoted image digests).
9. Post-publish smoke ([#459](https://github.com/p2pool-starter-stack/pithead/issues/459)): run
   `make release-smoke` once against the just-published tag. It downloads the published bundle +
   images and verifies them for real, and — on the previous-release bench box — drives the real #59
   upgrade. See [Post-publish smoke test](#post-publish-smoke-test-459). This is the only step gated
   *behind* the publish, because it checks the published artifact, not a branch.

### Pre-release gate (#54)

The [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration test matrix is a
required, blocking pre-release gate. A release must not be promoted or published unless that
matrix is green against the real Monero + Tari nodes. This is what makes every published version
a single, validated bundle.

Two runs of the matrix are required, and the automated one is the smaller of the two:

1. `release.sh` stage 2 runs the non-destructive `--readiness` assessment against the live
   stack. Export the harness arguments on the release box before `make release`:

   ```bash
   export RELEASE_INTEGRATION_ARGS="--local --dir <live-stack-dir> --readiness"
   ```

   `--local` / `--dir` point the harness at the box's live stack install, not the checkout — the
   same invocation the closing `--check` sweep below uses. Left unset, the cut aborts at stage 2
   with `run.sh`'s usage error. The assessment proves the box is fit to cut from — it does not
   mine, restart anything, or touch a rig.
2. Before cutting, run the targeted end-to-end matrix on the release candidate with a borrowed
   loaner rig. `release.sh` never runs this leg — run it yourself, before `make release`:

   ```bash
   BENCH_HOST=<bench> MINER_HOST=<loaner-rig> tests/integration/e2e.sh <ref> --mode targeted
   ```

   This deploys the candidate to the bench's dedicated e2e checkout, repoints the rig at it
   (under the [rig lock](release-server.md#bench-allocation-and-the-rig-lock), with automatic
   restore of both), and proves what `--readiness` cannot: a real miner mining through the
   stack, the lifecycle phase (restart, apply secret-preservation, node-down failover), and
   fail-closed auth. If the release's diff touches the worker or control-descriptor path, add
   the `--rigforge-control` legs (needs a rig with its control API enabled). The readiness
   gate alone does not satisfy this requirement; abort the release on any failure.

After deploying the published release to the bench, run the non-destructive live sweep as the
closing check: `tests/integration/run.sh --local --dir <stack-dir> --check`. On a bench with no
miners connected, add `--no-mining-asserts`
([#905](https://github.com/p2pool-starter-stack/pithead/issues/905)): the two mining
assertions skip with a logged notice, and the sweep must then pass with zero failures — any
failure is a regression. Without the flag, `workers online` and `stratum total hashes` fail on
every miner-less bench and have to be eyeballed as "expected", which is exactly the
tolerated-known-failure habit the flag exists to end.

### Which gates are automated, and which are not

Every gate below runs at cut time or is run by hand. **Nothing gates an update of `main`**, and no
workflow claims to ([#1048](https://github.com/p2pool-starter-stack/pithead/issues/1048)):
`release-gate.yml` is dispatch-only, because a self-hosted runner on a key-holding box is not
registered. It previously carried a `push: [main]` trigger behind a repo variable nobody set, so
every merge recorded a *skipped* run — and a skipped job is green, which made `main` display a
passing live-node gate that had never once executed.

| Gate | When | Run by | Blocking |
| --- | --- | --- | --- |
| `make test` (tiers 1–3) + `make lint` | every PR | CI | yes |
| `make test` again, on the release box | `release.sh` stage 2 | the cut | yes |
| #54 live matrix, `--readiness` | `release.sh` stage 2 | the cut | yes |
| Targeted e2e with a borrowed rig | before `make release` | you | yes — by policy, not by code |
| Release signing environment + pinned verifier | `release.sh` stage 1 | the cut | yes |
| Staged-image smoke (pull back, check version) | `release.sh` stage 5 | the cut | yes |
| `release-smoke` (real cosign, real #59 upgrade) | after publish | you | no — the assets already exist |
| `release-gate.yml` tier-4 live matrix | on demand | you, via *Run workflow* | no |
| Live `--check` sweep on the bench | after deploy | you | no |

The two human-run rows are policy, not automation: the release is not finished until they are green.
To move `release-gate.yml` into the automated column, register the runner first — see
[Release / Validation Server](release-server.md) and the note at the top of the workflow.

## Signed releases

Every promoted image digest and the install bundle carry a cosign key signature
([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)). The private key lives only
on the release server (`COSIGN_KEY` / `COSIGN_PASSWORD`, provisioned once — see
[Release / Validation Server › The release signing key](release-server.md#the-release-signing-key));
the public key is committed at the repo root as `cosign.pub` and ships inside
every release bundle, next to `pithead`. Signing is key-based, not Sigstore keyless: releases are
cut from a private box with no CI OIDC identity, and `--tlog-upload=false` keeps release activity
out of the public transparency log — which is why verification passes `--private-infrastructure`
(images) / `--insecure-ignore-tlog` (the bundle blob). Signatures pin the promoted manifest-list
digests — the exact bytes the smoke stage validated — never a mutable tag.

Signing is **mandatory to publish, because it is mandatory to consume**
([#960](https://github.com/p2pool-starter-stack/pithead/issues/960),
[#1108](https://github.com/p2pool-starter-stack/pithead/issues/1108)). Once `cosign.pub` is
committed it ships in every bundle, so every install from that release on refuses a release with no
`pithead.tar.gz.sig`. A cut made on a box with no key therefore does not produce a degraded release
— it produces one every one-click upgrade in the field rejects, and GitHub release assets are
immutable, so the signature can never be attached afterwards. That is how v1.18.0 shipped unsigned
and had to be withdrawn and re-cut. Preflight now aborts the cut instead, naming what is missing;
`--unsigned` is the explicit, loud way to publish one anyway. The check runs on `--dry-run` too and
only the signing itself is skipped, so a rehearsal reports the decision the real cut will make —
it used to sit inside the dry-run guard and could only ever print "signing OFF".

Preflight also proves the pinned verifier before anything is built
([#1084](https://github.com/p2pool-starter-stack/pithead/issues/1084)): it pulls `COSIGN_IMAGE`,
signs a probe blob with this box's key, verifies it through the container, and requires a tampered
blob to be refused. That round trip catches a digest that no longer pulls, an image that is not the
cosign it claims to be, and a committed `cosign.pub` that is no longer the public half of
`COSIGN_KEY` — each of which would otherwise surface as *signature verification failed* on every
install, which reads as tampering rather than as our own pin having moved.

`pithead` verifies before it changes anything:

- `pithead upgrade` on a release install with `cosign.pub` present verifies all five first-party
  images (`cosign verify --key cosign.pub --private-infrastructure`) and aborts on the first
  failure. Nothing is pulled or restarted.
- The dashboard upgrade ([#59](https://github.com/p2pool-starter-stack/pithead/issues/59))
  additionally fetches `pithead.tar.gz.sig` and verifies the downloaded bundle against the key
  **already on disk** before extracting a byte. The new bundle's own `cosign.pub` is never the
  trust anchor for its own verification, so a malicious bundle cannot vouch for itself; a key
  rotation reaches installs through a bundle signed with the previous key.
- Verification fails closed. With `cosign.pub` present, a bad signature, a stripped
  `pithead.tar.gz.sig`, or an image the bundle does not pin by digest each abort the upgrade with a
  message naming the fix. Only an install with no `cosign.pub` at all — older than the first signed
  release — proceeds unverified, with a warning saying exactly that; `pithead doctor` reports the
  state.
- The verifier is a container, not a host binary
  ([#1072](https://github.com/p2pool-starter-stack/pithead/issues/1072)): `cosign_run` invokes a
  digest-pinned `cosign` image with the install dir mounted read-only. Operators install nothing,
  and cosign never appears in the prerequisites. Requiring it on the host made signing a hidden
  dependency that no prerequisite listed and no dependency check installed — a fresh bundle install
  dead-ended at first `up`, and every install cut before signing engaged hit the same wall on its
  first signed upgrade, after the download and the extract. The release box is the exception: it
  signs, so it keeps a real pinned cosign (see [release-server.md](release-server.md)).
- Source checkouts skip verification: locally built images are unsigned by design.

What the signature does and does not prove: it proves the artifact was produced by the holder of
the release key, so a re-pointed GHCR tag, a tampered registry, or a swapped GitHub release asset
fails verification. It cannot protect against a compromise of the release server itself, which
holds the key and cuts the releases.

### Verifying a release

`pithead upgrade` runs the checks automatically, with no cosign install on the host — it calls a
digest-pinned cosign image. To verify by hand instead, use a cosign of your own (pinned install:
[release-server.md](release-server.md#the-release-signing-key)) against the committed `cosign.pub`:

```bash
# An image (repeat per image, or pin the digest from the ingredients manifest):
cosign verify --key cosign.pub --private-infrastructure \
    ghcr.io/p2pool-starter-stack/pithead-dashboard:vX.Y.Z

# The install bundle:
curl -fsSLO https://github.com/p2pool-starter-stack/pithead/releases/download/vX.Y.Z/pithead.tar.gz.sig
cosign verify-blob --key cosign.pub --signature pithead.tar.gz.sig --insecure-ignore-tlog=true pithead.tar.gz
```

Releases before **v1.18.1** are unsigned — that is the first cut whose bundle shipped a
`pithead.tar.gz.sig`, because it is the first tag containing the committed `cosign.pub`;
verification gates every release from it on.
If an upgrade sent you here saying cosign is not installed, read the next section — that box needs
the host binary once, not a manual verify.

### Upgrading an install older than v1.19.1

The verifier became a container in **v1.19.1**
([#1072](https://github.com/p2pool-starter-stack/pithead/issues/1072)). Before that it was a host
binary, and an upgrade is driven by the code the box is **already running** — so an install still on
v1.18.1 or v1.19.0 checks `command -v cosign` on its next one-click upgrade and refuses when the
binary is absent:

- **v1.19.0** refuses unconditionally: *"cosign is not installed on the host…"*
- **v1.18.1** refuses when `cosign.pub` is present: *"cosign.pub is present but cosign is not
  installed on the host…"*

cosign has no apt package, so this is not something an operator can resolve from the message alone —
and containerising the verifier does not help the boxes that have not taken the upgrade yet. This bit
a production install on 2026-08-15.

The escape path, once per box:

1. Install the pinned cosign **v2.6.3** binary on the host — the snippet in
   [Release / Validation Server › The release signing key](release-server.md#the-release-signing-key).
   v2.6.3 is the version this project pins and tests. A current cosign **v3 also works for this
   verify** — proven with v3.1.3 against real bundles: it accepts the flags these releases pass
   (`--signature` with a deprecation warning, `--insecure-ignore-tlog=true` unchanged) and still
   refuses a tampered bundle. The v3 breakage that motivated the original "not the newest" warning
   is in the release box's *signing* flags (`--tlog-upload`), not the operator's verify — so a box
   that already has a v3 binary needs nothing done.
2. Retry the upgrade from the dashboard. It now passes the old guard, verifies the bundle, and lands
   on a release whose verifier is the container.
3. From the next upgrade on the host binary is unused and can be removed.

`pithead doctor` on v1.19.1 and later answers this before an upgrade rather than during one: it
reports whether the pinned verifier image is present, and names the pre-fetch command if it is not.
On the older versions `doctor` cannot report it, which is why it is written here.

> **Proven on the bench, 2026-08-21.** Driven end to end on disposable installs actually running
> each tag. With no cosign on `PATH`, v1.19.0 rejected with its exact message above before any
> network dial; v1.18.1 dialled the release API first (over the stack's own Tor) and then rejected
> with its own message — a Tor failure on that leg reads as *"could not reach the GitHub release
> API"* instead, so retry rather than reinstalling anything. With cosign v2.6.3 back on `PATH`,
> both installs completed the one-click upgrade onto v1.19.3, and each upgraded install then ran a
> full `down`/`up` cycle with **no host cosign visible** — all five images verified by the pinned
> container. Two behaviours worth knowing before reading them as new walls: the request must name
> the *current latest* tag (the runner re-derives it host-side and refuses anything else), and a
> ten-minute throttle stamp is claimed by some attempts that end rejected — a retry inside that
> window reports *"attempted less than 10 minutes ago"* until the stamp ages out.

## Post-publish smoke test (#459)

Two features can't be tested before merge, because both need a *published* release to exist: the
[#376](https://github.com/p2pool-starter-stack/pithead/issues/376) cosign verification and the
[#59](https://github.com/p2pool-starter-stack/pithead/issues/59) one-click upgrade. The tier-4 matrix
tests a branch, not a published artifact, so the pre-merge tests only ever see a fake cosign. Right
after `make release` publishes, run [`scripts/release-smoke.sh`](../../scripts/release-smoke.sh) once to
verify the real thing:

```bash
make release-smoke                                     # verify the just-published version
make release-smoke ARGS="--upgrade /srv/code/previous" # + drive the real #59 upgrade
```

It runs two phases:

- **Real cosign verify.** Downloads the published `pithead.tar.gz` (+ `.sig`) and the five
  `:vX.Y.Z` images and verifies them against the committed `cosign.pub`. A good signature must pass;
  a byte-changed bundle must be refused (this is what proves the check is real, not the pre-merge
  fake); the bundle's own `VERSION` must equal the tag (the #376 rollback guard); and an unrelated
  key must be refused. If the release is **unsigned** — every release before v1.18.1 predates the
  committed key, and a deliberate `--unsigned` cut ships without a signature (an unconfigured box
  aborts the cut instead; see
  [Release / Validation Server › The release signing key](release-server.md#the-release-signing-key))
  — that is reported plainly and the phase is skipped. It never reports a signed pass for an
  unsigned release. This phase needs only
  `gh` auth and network; run it anywhere.
- **Real #59 upgrade** (`--upgrade DIR`). On a box still running the *previous* release, it enqueues
  the exact upgrade intent the dashboard writes into the #33 control spool, runs the host control
  runner, and asserts the install upgrades cleanly to the published tag over the real download →
  verify → rollback-guard → extract → `pithead upgrade` path. This is destructive to that box's
  stack: run it on the previous-release bench box (stack up, `dashboard.control` enabled), never on
  the release host. The one leg it doesn't drive is the browser → dashboard hop (the dashboard
  container writing the intent), which is unit-covered (#33/#59) and confirmed by clicking the
  button once by hand.

## Conventions

- Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`vMAJOR.MINOR.PATCH`),
  single source of truth in the top-level `VERSION` file. `pithead` reads it for tagging/upgrade;
  the dashboard reads it for display
  ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- Changelog: hand-curated [`CHANGELOG.md`](../../CHANGELOG.md) following
  [Keep a Changelog](https://keepachangelog.com) + SemVer, with GitHub's auto-generated PR list
  as a supplement in the release body. (Chosen over Conventional-Commits / release-please
  automation because the commit style here is human, issue-referencing summaries; curated notes
  read better for users, and automation can come later if a commit convention is adopted.)
- Patches: security and component bumps ship as normal patch releases, re-validated through the
  same gate.
- Host ports: a release that adds a host-published `ports:` entry to `docker-compose.yml` must
  call it out as **upgrade-blocking** in the release notes — a host where something else already
  binds that port fails `pithead upgrade` at compose up, after images are pulled and config is
  re-rendered.

### Withdrawing a bad release

A published `vX.Y.Z` tag is immutable: an active tag ruleset blocks deleting or re-pointing any
`v*` tag, so a released version number can never be re-cut — the v1.6.0 withdrawal burned that
number for good. When a published release turns out broken:

1. Supersede it: bump `VERSION` and cut the next patch through the full gate. Promotion re-points
   `:latest` at the good digests.
2. Edit the bad GitHub Release's notes to a "Superseded by the next patch — do not use" warning,
   and say so in `CHANGELOG.md` (the 1.0.0 tombstone and the 1.6.1 "Supersedes 1.6.0" header are
   the precedents).
3. Operators already on the bad version roll back per
   [Operations › The deploy-box layout](../operations.md#the-deploy-box-layout).

## Install & upgrade

- Install: download the release's compose bundle (or `git checkout vX.Y.Z`) → `./pithead setup`.
  Images are pulled from GHCR; no local build.
- Upgrade: the dashboard shows "vX.Y.Z available"
  ([#59](https://github.com/p2pool-starter-stack/pithead/issues/59)) → run `./pithead upgrade` →
  it pulls the new single-tagged images and recreates only what changed.
- Every published version is one immutable, #54-validated bundle; release notes list what's
  inside and what changed.

## Status

What exists today:

- ✅ Top-level `VERSION` file (single source of truth).
- ✅ `CHANGELOG.md` (Keep a Changelog + SemVer, with an `Unreleased` section).
- ✅ This document.
- ✅ The [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration test
  suite: the live config-matrix gate against real nodes (`tests/integration/`, `make
  test-integration`). See [Integration Testing](integration-testing.md).
- ✅ The dashboard version badge ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)):
  `VERSION` + git build-args baked into the dashboard image (env + OCI labels); shows `vX.Y.Z` on
  releases and `dev · branch @ hash` otherwise.
- ✅ The release pipeline, [`scripts/release.sh`](../../scripts/release.sh) (`make release`).
  Implements the full preflight → test gate (`make test` + the #54 matrix, blocking) → build (OCI
  labels + `PITHEAD_RELEASE=1`) → stage to `:vX.Y.Z-rc.N` → smoke-verify the pushed images →
  promote-by-digest to `:vX.Y.Z` + `:latest` → publish the GitHub Release. It generates the
  ingredients manifest (promoted digests + upstream pins) and a pinned install bundle as release
  assets, never starts the live stack on the build host, and never prints the registry token.
  Preview any run with `make release ARGS="--dry-run"`.

- ✅ Signed releases ([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)): the
  pipeline cosign-signs the promoted digests + the bundle, `pithead upgrade` and the dashboard
  upgrade verify against the committed `cosign.pub` and fail closed. See
  [Signed releases](#signed-releases).
- ✅ Pull-based install: `${STACK_VERSION}` wired through `docker-compose.yml`. Each first-party
  service now carries an `image: ${PITHEAD_REGISTRY:-…}/pithead-<svc>:${STACK_VERSION:-dev}` ref
  alongside its `build:`. pithead picks build-vs-pull automatically: a source checkout (the image
  Dockerfiles are present) builds locally and tags `:dev` with `--pull never`; a release install
  (the bundle ships no Dockerfiles, just `pithead` + `VERSION` + compose + the config templates + the
  `./build` runtime mounts) resolves `STACK_VERSION` to `vX.Y.Z` and pulls the published images
  (`--pull missing`; `upgrade` forces a re-pull). Override with `PITHEAD_REGISTRY` / `PITHEAD_PULL`. So
  a release is now `cp config.minimal.json config.json && ./pithead setup`, no local build.

**Remaining:**

- ⬜ The dashboard "new version available" update warning
  ([#59](https://github.com/p2pool-starter-stack/pithead/issues/59)), which builds on the
  version badge. Tracked separately.

> NOTE: before the first real release, choose the first published version. Set `VERSION` (the
> `pyproject.toml` metadata follows it, enforced by the drift-guard test) and confirm the GHCR image
> namespace (`scripts/release.sh` defaults to `ghcr.io/p2pool-starter-stack/pithead-*`; override with
> `PITHEAD_REGISTRY` / `PITHEAD_IMAGE_PREFIX`).
