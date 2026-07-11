# Releasing

How Pithead is versioned and released
([#44](https://github.com/p2pool-starter-stack/pithead/issues/44)). The pipeline is
implemented as [`scripts/release.sh`](../scripts/release.sh). Run it from the build/test
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

The product version lives in a top-level [`VERSION`](../VERSION) file: plain text, one line,
[SemVer](https://semver.org/spec/v2.0.0.html). Nothing else hardcodes the version:

- `pithead` reads it for tagging and upgrade.
- The dashboard bakes it in for display ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- Released images carry it in the `org.opencontainers.image.version` OCI label.
- The dashboard's `pyproject.toml` is kept in lockstep (packaging metadata only); a shell test fails
  if it drifts from `VERSION`.

> NOTE: `VERSION` is `1.0.3`. Set it to the version you want to publish; the `pyproject.toml`
> metadata must match, enforced by the drift-guard test.

## Component pins = an ingredients manifest

Every component stays pinned (build ARGs and image tags). The pins are the ingredients lockfile
of each product release, not independent releases:

- The dashboard surfaces them as "what's inside vX.Y.Z" (component info is already shown).
- Bumping any component, including a security patch such as a `monerod` CVE, is a normal stack
  release: bump the pin → cut a stack patch → re-run the integration gate → ship. The bundle
  ships re-tested.

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
5. Staging smoke test (gate): on a clean host, pull the staged images from GHCR and run the real
   user path (`setup` → up → `status`, minimal mine check). This proves the actually-pushed
   artifacts work, not just the local build. Abort on failure.
6. Promote by digest: re-tag the exact digests just smoke-tested to `:vX.Y.Z` and `:latest`,
   then push. Promotion is by digest (no rebuild), so the released bundle is bit-for-bit what was
   validated. Same version on every image.
7. Sign ([#376](https://github.com/p2pool-starter-stack/pithead/issues/376)): cosign-sign each
   promoted manifest-list digest and the install bundle with the key on the release server. See
   [Signed releases](#signed-releases).
8. Publish GitHub Release: create the git tag `vX.Y.Z`, write the `CHANGELOG.md` entry / release
   notes, and attach release assets: a pinned `docker-compose.yml` / config bundle referencing
   `${STACK_VERSION}=vX.Y.Z`, its detached signature (`pithead.tar.gz.sig`), plus the ingredients
   manifest (exact component versions + promoted image digests).

### Pre-release gate (#54)

The [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration test matrix is a
required, blocking pre-release gate. A release must not be promoted or published unless that
matrix is green against the real Monero + Tari nodes. This is what makes every published version
a single, validated bundle.

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
  `pithead.tar.gz.sig`, or a missing `cosign` binary each abort the upgrade with a message naming
  the fix. Only an install with no `cosign.pub` at all — older than the first signed release —
  proceeds unverified, with a warning saying exactly that; `pithead doctor` reports the state.
- Source checkouts skip verification: locally built images are unsigned by design.

What the signature does and does not prove: it proves the artifact was produced by the holder of
the release key, so a re-pointed GHCR tag, a tampered registry, or a swapped GitHub release asset
fails verification. It cannot protect against a compromise of the release server itself, which
holds the key and cuts the releases.

### Verifying a release

`pithead upgrade` runs the checks automatically once `cosign` is installed
(pinned install: [release-server.md](release-server.md#the-release-signing-key) — the same
snippet works on any host). To verify by hand against the committed
`cosign.pub`:

```bash
# An image (repeat per image, or pin the digest from the ingredients manifest):
cosign verify --key cosign.pub --private-infrastructure \
    ghcr.io/p2pool-starter-stack/pithead-dashboard:vX.Y.Z

# The install bundle:
curl -fsSLO https://github.com/p2pool-starter-stack/pithead/releases/download/vX.Y.Z/pithead.tar.gz.sig
cosign verify-blob --key cosign.pub --signature pithead.tar.gz.sig --insecure-ignore-tlog=true pithead.tar.gz
```

Releases up to v1.3.x are unsigned; verification gates every release from the first signed one.

## Conventions

- Versioning: [Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`vMAJOR.MINOR.PATCH`),
  single source of truth in the top-level `VERSION` file. `pithead` reads it for tagging/upgrade;
  the dashboard reads it for display
  ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- Changelog: hand-curated [`CHANGELOG.md`](../CHANGELOG.md) following
  [Keep a Changelog](https://keepachangelog.com) + SemVer, with GitHub's auto-generated PR list
  as a supplement in the release body. (Chosen over Conventional-Commits / release-please
  automation because the commit style here is human, issue-referencing summaries; curated notes
  read better for users, and automation can come later if a commit convention is adopted.)
- Patches: security and component bumps ship as normal patch releases, re-validated through the
  same gate.

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
- ✅ The release pipeline, [`scripts/release.sh`](../scripts/release.sh) (`make release`).
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
