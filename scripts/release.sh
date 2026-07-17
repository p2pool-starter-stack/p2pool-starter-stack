#!/usr/bin/env bash
#
# Pithead release pipeline (#44) — run from the private build/test server.
#
# Implements the documented stage -> smoke-test -> promote-by-digest flow (docs/releasing.md):
#
#   1. Preflight      clean tree, read VERSION, ensure the tag isn't already released, resolve pins
#   2. Test gate      `make test` (+ the #54 integration matrix, unless skipped) — blocking
#   3. Build          build the 5 first-party images with OCI labels + the release version baked in
#   4. Stage          push to a staging tag (:vX.Y.Z-rc.N) on GHCR and capture immutable digests
#   5. Smoke          pull the STAGED images back and verify they resolve to the right version
#   6. Promote        re-tag the smoke-tested digests to :vX.Y.Z + :latest (no rebuild) and push
#   6b. Sign          cosign-sign the promoted digests + the install bundle with the box's key (#376)
#   7. Publish        git tag, GitHub Release from CHANGELOG, attach the manifest + bundle + bundle sig
#
# Nothing user-facing is published until every gate is green. Promotion is by digest, so the released
# bundle is bit-for-bit what was smoke-tested. The script NEVER starts the live stack on this host and
# never prints a registry token.
#
# Usage:
#   scripts/release.sh [options]              (or: make release ARGS="...")
#
# Options:
#   --dry-run            Preflight + print the full plan (images, tags, manifest). No build/push/publish.
#   --rc N               Staging release-candidate number (default: 1) -> :vX.Y.Z-rc.N.
#   --skip-tests         Skip `make test` (NOT recommended; the gate is what makes a release trustworthy).
#   --skip-integration   Skip the #54 live integration matrix (still runs `make test`).
#   --skip-smoke         Skip the staged-image smoke verification.
#   --draft              Create the GitHub Release as a DRAFT (held for review; publish it by hand).
#   --resume-promote     Skip build/stage; promote the already-staged digests (retry after a smoke pass).
#   --allow-dirty        Don't require a clean git working tree (for local experimentation only).
#   -y, --yes            Don't prompt before the irreversible steps (push, tag, publish).
#   -h, --help           Show this help.
#
# Environment:
#   PITHEAD_REGISTRY        Registry namespace (default: ghcr.io/p2pool-starter-stack).
#   PITHEAD_IMAGE_PREFIX    Image-name prefix (default: pithead-) -> ghcr.io/.../pithead-dashboard.
#   GHCR_USER / GHCR_TOKEN  Registry login. Token falls back to GITHUB_TOKEN, then `gh auth token`.
#   RELEASE_INTEGRATION_ARGS  Extra args passed to `make test-integration ARGS=...` (the #54 gate).
#   RELEASE_SMOKE_CMD       Optional command run during the smoke stage for a fuller functional check.
#   COSIGN_KEY / COSIGN_PASSWORD  Release signing (#376): path to the cosign private key on this box
#                           and its passphrase. Promoted digests + the bundle get key signatures;
#                           the committed cosign.pub (repo root, shipped in the bundle) verifies them.
#
set -euo pipefail

# --- Configuration -------------------------------------------------------------------------------

REGISTRY="${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}"
IMAGE_PREFIX="${PITHEAD_IMAGE_PREFIX:-pithead-}"

# The 5 first-party images, by build-dir / image-name suffix (build context = "build/<suffix>",
# published image = "$REGISTRY/${IMAGE_PREFIX}<suffix>"). The compose service for "monero" is "monerod".
IMAGES=(tor monero p2pool xmrig-proxy dashboard)

# Target platform(s) for the published images. linux/amd64 ONLY: the bundled binaries are x86_64
# (monero/p2pool/xmrig-proxy ship `linux-x64`, and xmrig-proxy has NO arm64 build at all — so an arm64
# image can't be made to work), and self-hosted miners run x86_64. The point of buildx here is to FORCE
# amd64 even on an arm64 release host — a plain `docker build` on Apple Silicon labels the image arm64
# (the v1.0.0 bug), so it never ran on x86_64. The smoke stage fails the release if a pushed image
# doesn't carry every platform listed here. (Overridable via PITHEAD_PLATFORMS, but the components must
# actually ship binaries for any arch you add.)
PLATFORMS="${PITHEAD_PLATFORMS:-linux/amd64}"
BUILDX_BUILDER="${PITHEAD_BUILDX_BUILDER:-pithead-release}"

SOURCE_URL="https://github.com/p2pool-starter-stack/pithead"

# --- Small utilities -----------------------------------------------------------------------------

C_RESET=$'\033[0m'
C_BLUE=$'\033[1;34m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_RED=$'\033[1;31m'

log() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
    printf '%s ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
    exit 1
}
stage() { printf '\n%s━━ %s %s\n' "$C_BLUE" "$*" "$C_RESET"; }

# In --dry-run, side-effecting commands are printed, not run. Read-only steps always run.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$DRY_RUN" -eq 1 ] && return 0
    local reply
    read -r -p "$1 (y/N): " reply || true
    [[ "$reply" =~ ^[Yy] ]]
}

image_for() { printf '%s/%s%s' "$REGISTRY" "$IMAGE_PREFIX" "$1"; }

# SemVer X.Y.Z with an optional -prerelease / .build suffix (e.g. 0.1.0, 1.2.3-rc.1). No leading 'v'.
is_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; }

# --- Argument parsing ----------------------------------------------------------------------------

DRY_RUN=0
RC=1
SKIP_TESTS=0
SKIP_INTEGRATION=0
SKIP_SMOKE=0
RESUME_PROMOTE=0
ALLOW_DIRTY=0
ASSUME_YES=0
DRAFT=0

while [ $# -gt 0 ]; do
    case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rc)
        RC="${2:?--rc needs a number}"
        shift
        ;;
    --rc=*) RC="${1#*=}" ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --skip-integration) SKIP_INTEGRATION=1 ;;
    --skip-smoke) SKIP_SMOKE=1 ;;
    --draft) DRAFT=1 ;;
    --resume-promote) RESUME_PROMOTE=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help)
        sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ "$RC" =~ ^[0-9]+$ ]] || die "--rc must be a number (got '$RC')."

# --- State (filled by the stages) ----------------------------------------------------------------

REPO_ROOT="" STACK_VERSION="" TAG="" STAGING_TAG="" GIT_COMMIT="" GIT_BRANCH="" BUILD_DATE=""
WORKDIR="" # scratch dir for digests, the manifest and the bundle (created in main, after preflight)

# Staged image digests are kept as files ($WORKDIR/digest.<suffix>), not an associative array, so this
# runs on the stock macOS bash 3.2 too and the digests survive across stages.
set_digest() { printf '%s' "$2" >"$WORKDIR/digest.$1"; }
get_digest() { cat "$WORKDIR/digest.$1" 2>/dev/null || true; }

# GHCR is read-after-push eventually-consistent: a tag it JUST accepted can fail to resolve for a few
# seconds (#429 — this killed stage-4 digest capture twice on the v1.3.1 cut). Retry a registry read up
# to $REGISTRY_READ_RETRIES times, with $REGISTRY_READ_BACKOFF-second backoff, requiring non-empty
# output. Emits the read's stdout; returns non-zero only after every attempt fails, so a genuinely-
# missing image still stops the release (the caller's `[ -n "$digest" ] || die` fires as before).
REGISTRY_READ_RETRIES="${PITHEAD_REGISTRY_READ_RETRIES:-5}"
REGISTRY_READ_BACKOFF="${PITHEAD_REGISTRY_READ_BACKOFF:-3}"

# The registry inspect, wrapped in a function so the tests can stub it (fail N times, then succeed).
buildx_inspect() { docker buildx imagetools inspect "$@"; }

retry_registry_read() {
    local attempt=1 out
    while :; do
        if out="$("$@" 2>/dev/null)" && [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        [ "$attempt" -ge "$REGISTRY_READ_RETRIES" ] && return 1
        warn "registry read failed (attempt $attempt/$REGISTRY_READ_RETRIES): $* — GHCR read-after-push lag? retrying in ${REGISTRY_READ_BACKOFF}s..."
        sleep "$REGISTRY_READ_BACKOFF"
        attempt=$((attempt + 1))
    done
}

# The manifest-LIST (index) digest of a pushed tag — the sha that spans every built platform, which
# promote re-tags by digest. NOTE: `imagetools inspect --format '{{.Manifest.Digest}}'` does NOT work
# for a buildx OCI index (it renders the whole descriptor block, not the digest), so parse the human
# `Digest:` line instead. Verified equal to `imagetools inspect --raw | shasum -a 256`.
manifest_digest() { retry_registry_read buildx_inspect "$1" | awk '/^Digest:/{print $2; exit}'; }

# Resolve a single upstream component pin on demand (the "ingredients" each release bundles).
pin() {
    case "$1" in
    p2pool) grep -oE '^ARG P2POOL_VERSION=.*' build/p2pool/Dockerfile | cut -d= -f2 ;;
    monero) grep -oE '^ARG MONERO_VERSION=.*' build/monero/Dockerfile | cut -d= -f2 ;;
    xmrig-proxy) grep -oE '^ARG XMRIG_PROXY_VERSION=.*' build/xmrig-proxy/Dockerfile | cut -d= -f2 ;;
    tor-base) grep -oE '^FROM [^ ]+' build/tor/Dockerfile | head -1 | awk '{print $2}' ;;
    tari) grep -oE 'quay.io/tarilabs/minotari_node:[^ ]+' docker-compose.yml | head -1 ;;
    caddy) grep -oE 'caddy:[0-9.]+@sha256:[a-f0-9]+' docker-compose.yml | head -1 ;;
    socket-proxy) grep -oE 'tecnativa/docker-socket-proxy:[^ ]+' docker-compose.yml | head -1 ;;
    esac
}

# --- Stage 1: preflight --------------------------------------------------------------------------

# The CLI tools the blocking test gate (`make test` → `make lint`) shells out to: shellcheck + shfmt
# (lint-sh), node/npx (lint-js/md/toml), uv/uvx (lint-py/lint-yaml). A reimaged release box loses these
# (#426 — the v1.3.0 cut died ~1 min in with a bare `shellcheck: not found`). docker/jq are checked
# elsewhere. Verify them here so a missing tool fails preflight with an actionable message, before any
# build, instead of mid-gate.
LINT_TOOLCHAIN=(shellcheck shfmt node npx uv uvx)

check_release_toolchain() {
    local tool missing=()
    for tool in "${LINT_TOOLCHAIN[@]}"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "Missing lint/test tool(s): ${missing[*]} — the release box needs the lint toolchain before the test gate can run. Provision it (apt + the pinned uv installer): see docs/release-server.md § Provisioning the server. (Or --skip-tests to bypass the gate — NOT recommended.)"
    fi
    ok "Lint/test toolchain present (${LINT_TOOLCHAIN[*]})."
}

preflight() {
    stage "1/7  Preflight"

    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
    cd "$REPO_ROOT"
    [ -f VERSION ] && [ -f docker-compose.yml ] || die "VERSION / docker-compose.yml not found at the repo root."
    command -v docker >/dev/null 2>&1 || die "docker is required."
    docker buildx version >/dev/null 2>&1 || die "docker buildx is required (for digest-level promotion)."
    # Only the test gate needs the lint toolchain — skip the check on the paths that don't run it.
    if [ "$DRY_RUN" -eq 0 ] && [ "$SKIP_TESTS" -eq 0 ] && [ "$RESUME_PROMOTE" -eq 0 ]; then
        check_release_toolchain
    fi
    # Release signing (#376) is OPT-IN and pure defense-in-depth. The tag-substitution vector it
    # exists for — the first-party images pull by mutable `:vX.Y.Z` tag, so a re-pointed tag / leaked
    # registry token could serve a malicious root-running image — is ALREADY closed by digest-pinning
    # those images in the bundle (make_bundle). cosign additionally signs the promoted digests + the
    # bundle for operators who want to verify. So a normal cut needs NOTHING off-repo: signing turns
    # on only when a key is configured on this box AND cosign.pub is committed; otherwise we warn and
    # skip it rather than block the release.
    COSIGN_ENABLED=0
    if [ "$DRY_RUN" -eq 0 ]; then
        if command -v cosign >/dev/null 2>&1 && [ -n "${COSIGN_KEY:-}" ] && [ -f "${COSIGN_KEY:-/nonexistent}" ] && [ -f cosign.pub ]; then
            COSIGN_ENABLED=1
            ok "Release signing ON (cosign key + committed cosign.pub present)."
        else
            warn "Release signing OFF — shipping digest-pinned images + bundle without cosign signatures (#376 is opt-in). Installs are protected by the pinned digests; to also sign, see docs/release-server.md § The release signing key."
        fi
    fi

    STACK_VERSION="$(tr -d ' \t\r\n' <VERSION)"
    is_semver "$STACK_VERSION" || die "VERSION ('$STACK_VERSION') is not SemVer (expected X.Y.Z)."
    TAG="v$STACK_VERSION"
    STAGING_TAG="${TAG}-rc.${RC}"
    GIT_COMMIT="$(git rev-parse HEAD)"
    GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$ALLOW_DIRTY" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
        die "Working tree is dirty. Commit/stash first, or pass --allow-dirty."
    fi
    [ "$GIT_BRANCH" = "main" ] || warn "Releasing from '$GIT_BRANCH', not main."

    if git rev-parse "refs/tags/$TAG" >/dev/null 2>&1; then
        die "Git tag $TAG already exists — bump VERSION before cutting a new release."
    fi
    # Best-effort: warn if the promoted tag already exists in the registry (needs auth; non-fatal).
    if docker buildx imagetools inspect "$(image_for dashboard):$TAG" >/dev/null 2>&1; then
        warn "$(image_for dashboard):$TAG already exists in the registry — promotion would overwrite it."
    fi

    log "Version:   $STACK_VERSION  (tag $TAG, staging $STAGING_TAG)"
    log "Commit:    $GIT_COMMIT ($GIT_BRANCH)"
    log "Registry:  $REGISTRY  prefix '$IMAGE_PREFIX'"
    log "Pins:      p2pool $(pin p2pool) · monerod $(pin monero) · xmrig-proxy $(pin xmrig-proxy)"
    ok "Preflight passed."
}

# --- Stage 2: test gate ---------------------------------------------------------------------------

test_gate() {
    stage "2/7  Test gate (blocking)"
    if [ "$SKIP_TESTS" -eq 1 ]; then
        warn "Skipping 'make test' (--skip-tests). A skipped gate means an unvalidated release."
    else
        log "Running 'make test' (lint + dashboard pytest + shell suite + compose)..."
        run make test
        ok "make test passed."
    fi
    if [ "$SKIP_INTEGRATION" -eq 1 ]; then
        warn "Skipping the #54 integration matrix (--skip-integration) — the live-node gate did NOT run."
    else
        log "Running the #54 integration matrix against the real nodes..."
        # shellcheck disable=SC2086  # RELEASE_INTEGRATION_ARGS is an intentional word-split arg list
        run make test-integration ARGS="${RELEASE_INTEGRATION_ARGS:-}"
        ok "Integration matrix passed."
    fi
}

# --- Stage 3: build --------------------------------------------------------------------------------

# Multi-arch build+push needs a builder with the "docker-container" driver — the default "docker" driver
# can only build for the host platform (and can't --push a manifest list). Create a dedicated one if it's
# absent; --bootstrap also wires up QEMU so the non-native arch (e.g. amd64 on an Apple-Silicon host) can
# be cross-built. Idempotent.
ensure_buildx_builder() {
    [ "$DRY_RUN" -eq 1 ] && return 0
    if ! docker buildx inspect "$BUILDX_BUILDER" >/dev/null 2>&1; then
        log "Creating cross-build buildx builder '$BUILDX_BUILDER' (docker-container driver + QEMU)..."
        run docker buildx create --name "$BUILDX_BUILDER" --driver docker-container --bootstrap >/dev/null
    fi
}

build_images() {
    stage "3/7  Build + push images ($PLATFORMS, staging $STAGING_TAG)"
    # buildx builds the target platform(s) and --push uploads the result in one step — a buildx --push
    # image isn't loaded into the local docker store, so there is no separate local-build + push. Auth
    # and the builder must therefore be ready here, not in stage 4.
    ghcr_login
    ensure_buildx_builder
    local suffix context repo
    for suffix in "${IMAGES[@]}"; do
        context="build/$suffix"
        repo="$(image_for "$suffix")"
        log "Building $repo:$STAGING_TAG  ($PLATFORMS, from $context)"
        local args=(
            docker buildx build "$context"
            --builder "$BUILDX_BUILDER"
            --platform "$PLATFORMS"
            --push
            -t "$repo:$STAGING_TAG"
            --label "org.opencontainers.image.title=Pithead ($suffix)"
            --label "org.opencontainers.image.version=$STACK_VERSION"
            --label "org.opencontainers.image.revision=$GIT_COMMIT"
            --label "org.opencontainers.image.source=$SOURCE_URL"
            --label "org.opencontainers.image.created=$BUILD_DATE"
        )
        # The dashboard bakes the version badge from build args; a release build flags PITHEAD_RELEASE=1
        # so the badge shows the clean vX.Y.Z instead of "dev · branch @ hash" (#58).
        if [ "$suffix" = "dashboard" ]; then
            args+=(
                --build-arg "PITHEAD_VERSION=$STACK_VERSION"
                --build-arg "PITHEAD_RELEASE=1"
                --build-arg "PITHEAD_GIT_COMMIT=$GIT_COMMIT"
                --build-arg "PITHEAD_GIT_BRANCH=$GIT_BRANCH"
            )
        fi
        run "${args[@]}"
    done
    ok "Built + pushed all 5 images for $PLATFORMS."
}

# --- Stage 4: stage (push to the RC tag, capture digests) -----------------------------------------

stage_push() {
    stage "4/7  Capture pushed manifest digests"
    # build_images already pushed each image (buildx --push). Record the manifest-LIST digest (the index
    # sha that spans every built platform) — promote re-tags it by digest, so :vX.Y.Z and :latest point
    # at the exact bytes the smoke stage validates.
    local suffix repo digest
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        if [ "$DRY_RUN" -eq 1 ]; then
            set_digest "$suffix" "$repo@sha256:<dry-run>"
            log "  digest: $repo@sha256:<dry-run>"
            continue
        fi
        # #557: plain `digest="$(...)"` aborts under errexit once retries are exhausted, BEFORE this
        # die() fires — `if !` suspends errexit for the assignment so the message is reachable.
        if ! digest="$(manifest_digest "$repo:$STAGING_TAG")" || [ -z "$digest" ]; then
            die "Could not read the pushed manifest digest for $repo:$STAGING_TAG."
        fi
        set_digest "$suffix" "$repo@$digest"
        log "  digest: $repo@$digest"
    done
    ok "Captured $STAGING_TAG digests for all 5 images."
}

ghcr_login() {
    local registry_host="${REGISTRY%%/*}" user token
    user="${GHCR_USER:-}"
    token="${GHCR_TOKEN:-${GITHUB_TOKEN:-}}"
    [ -n "$token" ] || token="$(gh auth token 2>/dev/null || true)"
    [ -n "$user" ] || user="$(gh api user --jq .login 2>/dev/null || true)"
    if [ -z "$token" ]; then
        warn "No registry token (GHCR_TOKEN / GITHUB_TOKEN / gh auth) — assuming docker is already logged in to $registry_host."
        return 0
    fi
    # IMPORTANT: never route the token through run()/any echo. Pipe it straight to docker via stdin.
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s docker login %s -u %s --password-stdin  (token not shown)\n' \
            "$C_YELLOW" "$C_RESET" "$registry_host" "${user:-<token-user>}"
        return 0
    fi
    log "Logging in to $registry_host as ${user:-<token-user>} (token not shown)..."
    printf '%s' "$token" | docker login "$registry_host" -u "${user:-x}" --password-stdin >/dev/null ||
        die "docker login to $registry_host failed."
    ok "Registry login OK."
}

# --- Stage 5: smoke test (validate the PUSHED artifacts) ------------------------------------------

smoke_test() {
    stage "5/7  Staging smoke test"
    if [ "$SKIP_SMOKE" -eq 1 ]; then
        warn "Skipping smoke test (--skip-smoke) — the pushed artifacts were NOT re-validated from the registry."
        return 0
    fi
    # Pull each STAGED image back from the registry (not the local build) and confirm it resolves and
    # carries the right version label. This validates the bytes that were actually pushed. It does NOT
    # start a stack — that would collide with this host's live deployment; use RELEASE_SMOKE_CMD or the
    # #54 harness against the staged tag for a full functional run.
    local suffix repo got
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        log "Verifying $repo:$STAGING_TAG from the registry..."
        # Pull the TARGET platform explicitly: a plain `docker pull` resolves the build HOST's arch, so
        # on an arm64 release host an amd64-only image fails with "no matching manifest for linux/arm64".
        # Docker can still pull (not run) a non-native arch image, which is all the label check needs.
        run docker pull --quiet --platform "${PLATFORMS%%,*}" "$repo:$STAGING_TAG"
        if [ "$DRY_RUN" -eq 0 ]; then
            got="$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}' "$repo:$STAGING_TAG" 2>/dev/null || true)"
            [ "$got" = "$STACK_VERSION" ] ||
                die "Smoke: $repo:$STAGING_TAG reports version '$got', expected '$STACK_VERSION'."
            # The pushed manifest MUST carry every target platform — a wrong-arch image here means the
            # build host's arch leaked through (the v1.0.0 bug: an arm64 host produced an arm64-labelled
            # image that doesn't run on x86_64). Read the raw manifest list and require each $PLATFORMS.
            # The read retries GHCR's read-after-push lag (#429) so a slow-to-resolve tag doesn't fail smoke.
            local arches raw
            raw="$(retry_registry_read buildx_inspect "$repo:$STAGING_TAG" --raw)" ||
                die "Smoke: could not read the pushed manifest for $repo:$STAGING_TAG from the registry (after $REGISTRY_READ_RETRIES tries)."
            arches="$(printf '%s' "$raw" |
                python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(sorted({m.get("platform",{}).get("os","")+"/"+m["platform"]["architecture"] for m in d.get("manifests",[]) if m.get("platform",{}).get("architecture") not in (None,"unknown")})))' 2>/dev/null || true)"
            local p
            for p in ${PLATFORMS//,/ }; do
                case " $arches " in *" $p "*) ;; *) die "Smoke: $repo:$STAGING_TAG is missing target platform $p (got: ${arches:-none}). A wrong-arch build leaked through (the v1.0.0 arm64-only bug)." ;; esac
            done
            log "  $repo:$STAGING_TAG OK ($arches)"
        fi
    done
    if [ -n "${RELEASE_SMOKE_CMD:-}" ]; then
        log "Running RELEASE_SMOKE_CMD..."
        run bash -c "$RELEASE_SMOKE_CMD"
    fi
    ok "Staged images pull cleanly and report version $STACK_VERSION."
}

# --- Stage 6: promote by digest -------------------------------------------------------------------

promote() {
    stage "6/7  Promote by digest -> $TAG + latest"
    confirm "Promote the smoke-tested digests to $TAG and :latest (publishes user-facing tags)?" ||
        die "Promotion cancelled — nothing user-facing was published."
    ghcr_login
    local suffix repo digest
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        digest="$(get_digest "$suffix")"
        [ -n "$digest" ] || die "No staged digest for $suffix — run without --resume-promote, or stage first."
        log "Promoting $digest -> :$TAG, :latest"
        # imagetools re-tags at the manifest level (server-side, no pull/rebuild), so the released tag
        # is the exact digest that was smoke-tested.
        run docker buildx imagetools create --tag "$repo:$TAG" --tag "$repo:latest" "$digest"
    done
    ok "Promoted all 5 images to $TAG + latest."
}

# --- Stage 6b: sign the promoted digests (#376) ----------------------------------------------------

# A cosign key signature on each promoted image so `pithead upgrade` can refuse a re-pointed tag or
# a tampered registry. Sign the manifest-LIST digest promote just re-tagged — NEVER a per-arch child
# digest (that makes `cosign verify <tag>` fail) and never the tag (a tag is mutable; the signature
# must pin the bytes that were smoke-tested). No Rekor upload (--tlog-upload=false): the key is
# private infrastructure, installs verify with the committed cosign.pub via
# `cosign verify --key cosign.pub --private-infrastructure`. COSIGN_PASSWORD is read by cosign from
# the environment — it never touches argv, run(), or the log.
sign_images() {
    if [ "${COSIGN_ENABLED:-0}" -ne 1 ]; then
        log "Release signing off — skipping image signatures (the bundle is digest-pinned; #376 opt-in)."
        return 0
    fi
    stage "6b/7 Sign the promoted digests (cosign, #376)"
    local suffix digest
    for suffix in "${IMAGES[@]}"; do
        digest="$(get_digest "$suffix")"
        [ -n "$digest" ] || die "No staged digest for $suffix — nothing to sign."
        log "Signing $digest"
        run cosign sign --key "${COSIGN_KEY:-}" --tlog-upload=false --yes "$digest"
    done
    ok "Signed all 5 promoted digests (verify with the committed cosign.pub)."
}

# Detached signature for the install bundle (#376): the #59 dashboard upgrade downloads
# pithead.tar.gz (not images) and verifies it against the cosign.pub already on the host BEFORE
# extracting, so the tarball needs its own signature published next to it on the GitHub Release.
sign_bundle() { # <bundle> <sig-out>
    log "Signing the install bundle -> $(basename "$2")"
    run cosign sign-blob --key "${COSIGN_KEY:-}" --tlog-upload=false --yes --output-signature "$2" "$1"
}

# --- Stage 7: publish (git tag, GitHub Release, manifest, bundle) ---------------------------------

publish() {
    stage "7/7  Publish GitHub Release $TAG"
    local manifest="$WORKDIR/ingredients-$TAG.md"
    write_manifest "$manifest"
    local bundle="$WORKDIR/pithead.tar.gz" # versionless name → stable /releases/latest/download/ URL
    make_bundle "$bundle"
    local bundle_sig="" # pithead.tar.gz.sig — only when signing is on (#376 opt-in)
    if [ "${COSIGN_ENABLED:-0}" -eq 1 ]; then
        bundle_sig="$bundle.sig" # the #59 upgrade runner fetches it by name
        sign_bundle "$bundle" "$bundle_sig"
    fi

    confirm "Create git tag $TAG, push it, and publish the GitHub Release?" ||
        {
            warn "Publish cancelled. Images are promoted; re-run --resume-promote to finish, or publish by hand."
            return 0
        }

    run git tag -a "$TAG" -m "Pithead $TAG"
    run git push origin "$TAG"

    local notes="$WORKDIR/notes.md"
    changelog_notes >"$notes"
    cat "$manifest" >>"$notes"

    if command -v gh >/dev/null 2>&1; then
        # --draft holds the GitHub Release for review (not visible/announced until published by hand).
        # The images are already promoted, so the draft's install bundle works the moment it's published.
        local gh_args=(release create "$TAG" --title "Pithead $TAG" --notes-file "$notes")
        [ "$DRAFT" -eq 1 ] && gh_args+=(--draft)
        gh_args+=("$bundle")
        [ -n "$bundle_sig" ] && gh_args+=("$bundle_sig") # the .sig only exists when signing is on
        gh_args+=("$manifest")
        run gh "${gh_args[@]}"
        ok "GitHub Release $TAG $([ "$DRAFT" -eq 1 ] && echo 'created as a DRAFT (publish it from the Releases page when ready)' || echo published)."
    else
        warn "gh CLI not found — tag pushed, but create the release by hand. Notes: $notes  Assets: $bundle $bundle_sig $manifest"
    fi
}

# Ingredients manifest — exactly what's inside this release: the promoted image digests + upstream pins.
write_manifest() {
    local out="$1" suffix repo dg
    {
        printf '## Ingredients — Pithead %s\n\n' "$TAG"
        printf -- '- **Version:** %s\n- **Commit:** `%s`\n- **Built:** %s\n\n' "$STACK_VERSION" "$GIT_COMMIT" "$BUILD_DATE"
        printf '### Published images (`%s`, tags `%s` + `latest`)\n\n' "$REGISTRY" "$TAG"
        for suffix in "${IMAGES[@]}"; do
            repo="$(image_for "$suffix")"
            dg="$(get_digest "$suffix")"
            printf -- '- `%s`\n  - digest: `%s`\n' "$repo:$TAG" "${dg:-<not staged>}"
        done
        printf '\n### Upstream component pins\n\n'
        printf -- '- p2pool: `%s`\n' "$(pin p2pool)"
        printf -- '- monerod: `%s`\n' "$(pin monero)"
        printf -- '- xmrig-proxy: `%s`\n' "$(pin xmrig-proxy)"
        printf -- '- tor base: `%s`\n' "$(pin tor-base)"
        printf -- '- tari: `%s`\n' "$(pin tari)"
        printf -- '- caddy: `%s`\n' "$(pin caddy)"
        printf -- '- docker-socket-proxy: `%s`\n' "$(pin socket-proxy)"
    } >"$out"
    log "Wrote ingredients manifest: $out"
}

# The host paths under ./build/ that docker-compose.yml MOUNTS at runtime (volumes:), as opposed to
# build: contexts. A pull-based bundle builds nothing and the images do NOT bake these in — monerod, for
# instance, reads /home/ubuntu/bitmonero.conf.template purely from this host mount — so every one MUST ship in
# the bundle, or the container mounts an empty dir and fails to start (the v1.0.0 bundle missed monerod's
# template this way). Matches the volume short-syntax source (between "- " and the first ":"); ignores
# build:/context: lines so no Dockerfile lands in the bundle (which would flip is_source_checkout to true
# and make pithead build instead of pull). Sourced + unit-tested.
compose_build_mounts() {
    grep -oE '^[[:space:]]*-[[:space:]]+\./build/[^:[:space:]]+:' "${1:-docker-compose.yml}" |
        sed -E 's/^[[:space:]]*-[[:space:]]+//; s/:$//' | sort -u
}

# A pinned, pull-based install bundle: the runtime files needed to `./pithead setup` WITHOUT building.
# Deliberately ships NO image Dockerfiles — so pithead detects release mode (is_source_checkout=false),
# resolves STACK_VERSION from the bundled VERSION, and pulls the published `:vX.Y.Z` images. Every
# ./build/* path the compose mounts at runtime (compose_build_mounts) IS shipped, so the pulled
# containers find the config templates they render at setup.
make_bundle() {
    # Unpacks to a versionless "pithead/" dir so the documented quick start can `cd pithead` and so a
    # later bundle re-download upgrades it in place. Ships BOTH config templates: config.minimal.json
    # (basic — just the two wallet addresses, the documented quick-start config) and the advanced
    # example. The bundle README + the repo quick start both point at the basic one (matching setup's
    # own "copy config.minimal.json" guidance); the advanced example is "for more options".
    local out="$1" d="$WORKDIR/pithead"
    mkdir -p "$d"
    # cosign.pub rides in the bundle (#376) so a release install (no git checkout) has the verifier
    # next to pithead; preflight guarantees it exists on a real run.
    cp pithead pithead-completion.bash VERSION docker-compose.yml config.minimal.json config.reference.json cosign.pub "$d/" 2>/dev/null || true
    local m
    while IFS= read -r m; do
        [ -e "$m" ] || {
            warn "bundle: compose mounts '$m' but it is missing from the tree — skipping"
            continue
        }
        mkdir -p "$d/$(dirname "$m")"
        cp -R "$m" "$d/$(dirname "$m")/"
    done < <(compose_build_mounts docker-compose.yml)
    printf 'Pithead %s — pinned install bundle (images pulled from %s, no local build).\n\nQuick start:\n  1. cp config.minimal.json config.json   # then set your Monero + Tari payout addresses\n     (more options: config.reference.json)\n  2. ./pithead setup\n\nThere are no build contexts here, so pithead pulls the published %s images instead of building.\n' \
        "$TAG" "$REGISTRY" "$TAG" >"$d/README.txt"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '   %s[dry-run]%s would tar -> %s\n' "$C_YELLOW" "$C_RESET" "$out"
        return 0
    fi
    # Digest-pin the first-party images in the BUNDLED compose (#376). The released images pull by
    # mutable `:vX.Y.Z` tag, so a re-pointed tag / leaked registry token could substitute a
    # root-running image under the same tag. Pinning each to the immutable @sha256 digest promote just
    # published makes the pull content-addressed — this is what actually closes that vector (cosign
    # signing, when on, is the additional layer). The tag stays for readability; the digest wins.
    local suffix digest sha
    for suffix in "${IMAGES[@]}"; do
        digest="$(get_digest "$suffix")"
        [ -n "$digest" ] ||
            die "make_bundle: no promoted digest for $suffix — refusing to ship an un-pinned bundle (#376)."
        # get_digest stores a FULL ref ($repo@sha256:…); we append only the @sha256 part to the
        # existing image line (which already has the repo + tag), so pin by the bare digest.
        sha="${digest##*@}"
        case "$sha" in
        sha256:*) ;;
        *) die "make_bundle: digest for $suffix is not a sha256 ref ('$digest') — cannot pin (#376)." ;;
        esac
        sed -i.bak "s|\(pithead-${suffix}:\${STACK_VERSION:-dev}\)|\1@${sha}|" "$d/docker-compose.yml"
    done
    rm -f "$d/docker-compose.yml.bak"
    # Post-condition: NEVER ship a partially-pinned bundle. Every first-party image line must now
    # carry an @sha256 digest.
    local unpinned
    unpinned="$(grep -E "pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):" "$d/docker-compose.yml" | grep -v "@sha256:" || true)"
    [ -z "$unpinned" ] ||
        die "make_bundle: first-party image(s) left un-pinned in the bundle compose (#376):"$'\n'"$unpinned"
    # --no-xattrs: we cut releases on macOS, where tar is bsdtar and stores each file's extended
    # attributes (incl. macOS's com.apple.provenance) as LIBARCHIVE.xattr.* pax headers. GNU tar on
    # a user's Linux box doesn't know that keyword and warns once per file on extract (#252). Stripping
    # xattrs makes the bundle clean; the flag is a portable no-op on GNU tar (xattrs aren't stored by
    # default), so release.sh stays correct if a release is ever cut on Linux.
    tar --no-xattrs -czf "$out" -C "$WORKDIR" "pithead"
    # Guard the fix (#252): the bundle must carry no extended-attribute pax headers
    # (LIBARCHIVE.xattr.* from bsdtar / SCHILY.xattr.* from GNU tar) — those make GNU tar warn once
    # per file on a Linux extract. pax headers store the keyword as plain text in the tar stream, so
    # grepping the decompressed bytes detects them regardless of which tar built the archive.
    if gzip -dc "$out" 2>/dev/null | grep -qa -e 'LIBARCHIVE.xattr' -e 'SCHILY.xattr'; then
        die "Bundle $out carries xattr pax headers (#252) — GNU tar will warn on extract. Does this tar honor --no-xattrs?"
    fi
    log "Wrote install bundle: $out"
}

# Release notes = the top (newest) section of CHANGELOG.md — the curated, user-facing summary.
changelog_notes() {
    if [ ! -f CHANGELOG.md ]; then
        printf 'Pithead %s\n' "$TAG"
        return
    fi
    # Print from the first "## [" heading up to (but not including) the next one.
    awk '/^## \[/{ if (seen) exit; seen=1 } seen' CHANGELOG.md
}

# --- Main -----------------------------------------------------------------------------------------

main() {
    log "Pithead release pipeline (#44)$([ "$DRY_RUN" -eq 1 ] && echo '  [DRY RUN]')"
    preflight
    WORKDIR="$(mktemp -d)" # holds the captured digests, the ingredients manifest and the bundle
    if [ "$RESUME_PROMOTE" -eq 1 ]; then
        warn "--resume-promote: skipping build/stage. Re-staging to recover digests..."
        ghcr_login
        local suffix repo digest
        for suffix in "${IMAGES[@]}"; do
            repo="$(image_for "$suffix")"
            digest="$(manifest_digest "$repo:$STAGING_TAG")"
            [ -n "$digest" ] || die "Cannot resolve a staged digest for $repo:$STAGING_TAG — stage first."
            set_digest "$suffix" "$repo@$digest"
        done
    else
        test_gate
        build_images
        stage_push
        smoke_test
    fi
    promote
    sign_images # #376 — signs the digests promote re-tagged; --resume-promote reaches this too
    publish

    printf '\n'
    ok "Release $TAG complete."
    [ "$DRY_RUN" -eq 1 ] && warn "(dry run — nothing was actually built, pushed, tagged, or published.)"
    [ -n "$WORKDIR" ] && log "Artifacts left in: $WORKDIR"
}

# Run the pipeline only when executed directly; allow sourcing for unit tests (functions only).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
