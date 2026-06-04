# Releasing

How Pithead is versioned and released. This page documents the **agreed process**
([#44](https://github.com/p2pool-starter-stack/pithead/issues/44)). The publishing
automation it describes — the `make release` / `pithead release` pipeline and the GHCR
workflow — is **not yet implemented**; see [Status](#status) below. The
version source of truth (`VERSION`) and the changelog exist today.

## One product, one version

Pithead is versioned and released as a **single product**, not as individual components.

The components are upstream projects we *pin and integrate*, not author — `p2pool`
(`ARG P2POOL_VERSION`), `xmrig-proxy`, `monerod`, and `tari`
(`quay.io/tarilabs/minotari_node:vX-mainnet`). The only first-party code is the dashboard
plus the orchestration (`pithead`, `docker-compose.yml`, configs). The unit of value — and
the thing the integration matrix validates — is the *composed, tested-together set*. So a
release is **one artifact with one version, one changelog, one upgrade path, and one
"new version available" signal**.

The one accepted trade-off: we don't support hot-swapping a single component to a version
we haven't tested together. Power users can still override an ARG or image tag locally, but
that combination isn't a *supported* release.

## Single source of truth

The product version lives in a top-level **[`VERSION`](../VERSION)** file — plain text,
one line, [SemVer](https://semver.org/spec/v2.0.0.html). Nothing else hardcodes the version:

- `pithead` reads it for tagging and upgrade.
- The dashboard bakes it in for display ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- Released images carry it in the `org.opencontainers.image.version` OCI label.

> **Note for the first real release.** `VERSION` is currently `0.1.0`, while
> `build/dashboard/pyproject.toml` reads `0.2.0`. Reconciling the two and choosing the
> first published version is a maintainer decision to make before the first `make release`.

## Component pins = an ingredients manifest

We keep pinning every component (build ARGs and image tags), but treat the pins as the
*ingredients lockfile* of each product release — not as independent releases:

- Surface them in the dashboard as "what's inside vX.Y.Z" (we already show component info).
- Bumping any component — including a security patch, e.g. a `monerod` CVE — is just a
  normal stack release: bump the pin → cut a stack patch → re-run the integration gate →
  ship. No loss of patch agility; we always ship a *re-tested bundle*.

## Published images — GHCR, single-tag model

Images are published to **GitHub Container Registry** (`ghcr.io/p2pool-starter-stack/*`),
which is free for public images: unlimited free pulls and no Docker Hub-style rate limits.

"One product" doesn't mean one image — the stack is inherently multi-container. We publish
**every image we build** (`dashboard`, `p2pool`, `xmrig-proxy`, `monero`, `tor`), **all
tagged with the single stack version**, and compose references one `${STACK_VERSION}`.
Users `docker compose pull` a coherent set with one knob — removing the old
"git pull + rebuild" upgrade path. The version is the *bundle*, not the layers.

## Release process

Releases are cut on a **private build/test server** that runs the full Monero and full Tari
nodes (the integration-test environment from
[#54](https://github.com/p2pool-starter-stack/pithead/issues/54)). A single entry
point — `make release` (or `pithead release`) — runs the whole pipeline. **Nothing is
promoted or published until every gate is green.**

### Pipeline: stage → smoke-test → promote

1. **Preflight** — clean working tree; read the product version from the top-level
   `VERSION` file; confirm `vX.Y.Z` isn't already released; resolve the component pins into
   the ingredients manifest.
2. **Test gate (blocking)** — run the existing tests (`make test`: lint + dashboard pytest
   ≥ 80% + the `pithead` shell suite + compose validation) **and** the
   [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration matrix
   against the real nodes. **Abort the release on any failure** — see
   [Pre-release gate](#pre-release-gate-54).
3. **Build** — build the first-party images with the pinned upstream versions baked in and
   OCI labels stamped (`org.opencontainers.image.version` = the `VERSION` value, source
   revision, etc.).
4. **Push to staging** — push to a **staging tag** on GHCR (e.g. `:vX.Y.Z-rc.N`) and
   capture the immutable digests. Nothing user-facing points here yet.
5. **Staging smoke test (gate)** — on a *clean host*, pull the **staged images from GHCR**
   and run the real user path (`setup` → up → `status`, minimal mine check). This proves the
   actually-pushed artifacts work — not just the local build. **Abort on failure.**
6. **Promote by digest** — re-tag the **exact digests** just smoke-tested to `:vX.Y.Z`
   **and** `:latest`, then push. Promotion is by digest (no rebuild), so the released bundle
   is bit-for-bit what was validated. Same version on every image.
7. **Publish GitHub Release** — create the git tag `vX.Y.Z`, write the `CHANGELOG.md`
   entry / release notes, and attach release assets: a pinned `docker-compose.yml` / config
   bundle referencing `${STACK_VERSION}=vX.Y.Z`, plus the **ingredients manifest** (exact
   component versions + promoted image digests).

### Pre-release gate (#54)

The [#54](https://github.com/p2pool-starter-stack/pithead/issues/54) integration test
matrix is a **required, blocking pre-release gate**. A release must not be promoted or
published unless that matrix is green against the real Monero + Tari nodes. This is what
makes every published version a single, validated bundle.

## Conventions

- **Versioning** — [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
  (`vMAJOR.MINOR.PATCH`), single source of truth in the top-level `VERSION` file. `pithead`
  reads it for tagging/upgrade; the dashboard reads it for display
  ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58)).
- **Changelog** — hand-curated [`CHANGELOG.md`](../CHANGELOG.md) following
  [Keep a Changelog](https://keepachangelog.com) + SemVer, with GitHub's auto-generated PR
  list as a supplement in the release body. (Chosen over Conventional-Commits /
  release-please automation because our commit style is human, issue-referencing summaries —
  curated notes read better for users; we can automate later if we adopt a commit
  convention.)
- **Patches** — security and component bumps ship as normal patch releases, re-validated
  through the same gate.

## Install & upgrade UX

The goal is professional and one-command:

- **Install** — download the release's compose bundle (or `git checkout vX.Y.Z`) →
  `./pithead setup`. Images are *pulled* from GHCR — no local build, no compile wait.
- **Upgrade** — the dashboard shows "vX.Y.Z available"
  ([#59](https://github.com/p2pool-starter-stack/pithead/issues/59)) → the user runs
  `./pithead upgrade` → it pulls the new single-tagged images and recreates only what
  changed.
- **Trust** — every published version is one immutable, #54-validated bundle; release notes
  list exactly what's inside and what changed.

## Status

This page is the **scaffold** for [#44](https://github.com/p2pool-starter-stack/pithead/issues/44).
What exists today:

- ✅ Top-level `VERSION` file (single source of truth).
- ✅ `CHANGELOG.md` (Keep a Changelog + SemVer, with an `Unreleased` section).
- ✅ This document.

**TODO — not yet implemented:**

- ⬜ The `make release` / `pithead release` pipeline (preflight → test gate → build →
  stage → smoke-test → promote-by-digest → publish).
- ⬜ The GHCR single-tag publishing workflow and CI integration.
- ⬜ Wiring `${STACK_VERSION}` through `docker-compose.yml` and the OCI image labels.
- ⬜ The ingredients-manifest generation and release-asset attachment.
- ⬜ The dashboard version badge ([#58](https://github.com/p2pool-starter-stack/pithead/issues/58))
  and update warning ([#59](https://github.com/p2pool-starter-stack/pithead/issues/59)),
  tracked separately.
