#!/usr/bin/env bash
#
# Post-publish release smoke test (#459) — run ONCE, right after `make release` publishes vX.Y.Z.
#
# The tier-4 matrix tests a branch; it cannot test a PUBLISHED, SIGNED artifact that only exists
# after publish. Two things need that artifact for an honest check — the #376 cosign verification and
# the #59 one-click upgrade — so they are verified here, gated behind the publish, not in CI (before
# this existed they were hand-checked on the release checklist). Reuses scripts/release.sh for the
# image list / registry / naming, so there is one source of truth for what a release contains.
#
# Phase 1 (always): download the published pithead.tar.gz (+ .sig) and the 5 :vX.Y.Z images and
#   cosign-verify them FOR REAL against the committed cosign.pub — not the pre-merge fake cosign.
#     - a good signature passes;
#     - a byte-changed bundle is refused (this is what proves the verify is real);
#     - the bundle's own VERSION equals the tag (the #376 rollback guard — an older signed bundle
#       served at the vX.Y.Z URL is caught);
#     - every published image verifies, and an unrelated key is refused.
#   If the release is UNSIGNED (signing is opt-in, #376), that is reported plainly — never a false
#   pass. Runnable from any box with `gh` auth + network; needs no deployed stack.
#
# Phase 2 (--upgrade DIR): drive the REAL #59 host path against a previous-release install — enqueue
#   the exact upgrade intent the dashboard writes into its control spool, run the host control runner,
#   and assert the install upgrades cleanly to the published tag over the same download → verify →
#   rollback-guard → extract → `pithead upgrade` path. DESTRUCTIVE to that box's stack: run it on the
#   previous-release bench box (the stack must be up with dashboard.control enabled), never on the
#   release host.
#
# Usage:
#   scripts/release-smoke.sh [vX.Y.Z] [--upgrade DIR] [--keep] [-h]
#     (no version → the tag derived from the VERSION file)
#
# Environment:
#   PITHEAD_REGISTRY / PITHEAD_IMAGE_PREFIX   Override the image namespace (same as release.sh).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse release.sh's helpers (IMAGES, image_for, REGISTRY, is_semver, log/ok/warn/die/stage, colors)
# so the released image set is defined in exactly one place. Sourced inside a no-arg function so
# release.sh's top-level option parser sees an empty argv and does nothing but define functions.
# shellcheck source=scripts/release.sh
_load_release_helpers() { source "$SCRIPT_DIR/release.sh"; }
_load_release_helpers

# --- Args ----------------------------------------------------------------------------------------

VERSION_ARG=""
UPGRADE_DIR=""
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
    --upgrade)
        UPGRADE_DIR="${2:?--upgrade needs an install dir}"
        shift
        ;;
    --upgrade=*) UPGRADE_DIR="${1#*=}" ;;
    --keep) KEEP=1 ;;
    -h | --help)
        sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    v[0-9]* | [0-9]*) VERSION_ARG="$1" ;;
    *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not inside a git repository."
cd "$REPO_ROOT"
command -v gh >/dev/null 2>&1 || die "gh CLI is required to download the published release assets."

# Resolve the target version → tag. A bare or v-prefixed arg both work; default to the VERSION file.
STACK_VERSION="${VERSION_ARG:-$(tr -d ' \t\r\n' <VERSION)}"
STACK_VERSION="${STACK_VERSION#v}"
is_semver "$STACK_VERSION" || die "Version '$STACK_VERSION' is not SemVer (expected X.Y.Z)."
TAG="v$STACK_VERSION"

WORK="$(mktemp -d)"
cleanup() { [ "$KEEP" -eq 1 ] && log "Kept work dir: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

SIG_PUBLISHED=0
SIGNED=0

# --- Phase 1: download + real cosign verify ------------------------------------------------------

fetch_published_bundle() {
    stage "Fetch the published $TAG bundle"
    local assets
    assets="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null)" ||
        die "No published GitHub Release $TAG — publish it first (make release)."
    grep -qx 'pithead.tar.gz' <<<"$assets" || die "Release $TAG has no pithead.tar.gz asset."
    gh release download "$TAG" --pattern 'pithead.tar.gz' --dir "$WORK" --clobber
    if grep -qx 'pithead.tar.gz.sig' <<<"$assets"; then
        gh release download "$TAG" --pattern 'pithead.tar.gz.sig' --dir "$WORK" --clobber
        SIG_PUBLISHED=1
    fi
    ok "Downloaded pithead.tar.gz$([ "$SIG_PUBLISHED" -eq 1 ] && echo ' + .sig')."
}

verify_release() {
    stage "cosign verify — published $TAG bundle + images"
    local bundle="$WORK/pithead.tar.gz" sig="$WORK/pithead.tar.gz.sig"
    local pub="$REPO_ROOT/cosign.pub"

    # Signed-vs-unsigned, reported honestly. The trust anchor is the COMMITTED cosign.pub (the key the
    # running install already trusts), never the bundle's own copy — a key that arrives inside the
    # artifact it vouches for proves nothing.
    if [ ! -f "$pub" ] && [ "$SIG_PUBLISHED" -eq 0 ]; then
        warn "UNSIGNED release: no committed cosign.pub and no pithead.tar.gz.sig asset. Release signing is opt-in (#376) — releases up to v1.3.x, and any cut with signing off, ship unsigned. Nothing to cosign-verify; bundle integrity rests on the digest-pinned compose + TLS to GitHub. (Not a failure.)"
        return 0
    fi
    # A half state is a misconfiguration, not a pass — surface it.
    [ -f "$pub" ] ||
        die "pithead.tar.gz.sig is published but no cosign.pub is committed — cannot anchor trust. Commit the release cosign.pub (docs/dev/releasing.md § Signed releases)."
    [ "$SIG_PUBLISHED" -eq 1 ] ||
        die "cosign.pub is committed but release $TAG published no pithead.tar.gz.sig — it was cut with signing off, so no install can verify the bundle (#376). Re-cut with COSIGN_KEY set."
    command -v cosign >/dev/null 2>&1 ||
        die "cosign is not installed — cannot verify a signed release. Install it: docs/dev/release-server.md § The release signing key."
    SIGNED=1

    # 1. A good signature passes.
    cosign verify-blob --key "$pub" --signature "$sig" --insecure-ignore-tlog=true "$bundle" >/dev/null 2>&1 ||
        die "Bundle signature FAILED against the committed cosign.pub — the published pithead.tar.gz is not what this key signed."
    ok "Bundle signature verifies against the committed cosign.pub."

    # 2. A changed bundle is refused. This is the assertion that proves the verification is REAL
    #    (pre-merge tests only ever saw a fake cosign that always passes).
    local tampered="$WORK/pithead.tampered.tar.gz"
    cp "$bundle" "$tampered"
    printf 'x' >>"$tampered" # any content change → a different hash → the signature must not match
    if cosign verify-blob --key "$pub" --signature "$sig" --insecure-ignore-tlog=true "$tampered" >/dev/null 2>&1; then
        die "A changed bundle STILL verified — cosign verification is not real. Refusing to declare $TAG safe."
    fi
    ok "A changed bundle is refused (verification is real, not a no-op)."

    # 3. Rollback guard (#376): the bundle's own top-level VERSION must equal the tag, so an older
    #    genuinely-signed bundle served at the $TAG URL is caught. Read without extracting — the same
    #    check control_upgrade makes before it unpacks a byte.
    local bv
    # #548: plain assignment — under errexit a tar failure here would kill the smoke test with a
    # bare trap instead of the die() message below. Guard it like every other check in this script.
    if ! bv="$(tar -xzOf "$bundle" pithead/VERSION 2>/dev/null | tr -d '[:space:]')"; then
        die "Published $TAG bundle is missing pithead/VERSION — cannot verify against the tag (corrupt or not a pithead bundle)."
    fi
    [ "v$bv" = "$TAG" ] ||
        die "Published $TAG bundle contains VERSION '$bv' — a version mismatch (possible rollback). control_upgrade refuses this (#376)."
    ok "Bundle VERSION matches the tag ($TAG) — no rollback substitution."

    # 4. Every published image verifies against the committed key (the exact command the docs give and
    #    that pithead runs before a release pull).
    local suffix repo
    for suffix in "${IMAGES[@]}"; do
        repo="$(image_for "$suffix")"
        cosign verify --key "$pub" --private-infrastructure "$repo:$TAG" >/dev/null 2>&1 ||
            die "Image signature FAILED for $repo:$TAG against the committed cosign.pub."
        ok "  $repo:$TAG verifies."
    done

    # 5. Negative: an unrelated key is refused. Registry bytes can't be byte-flipped in place, so prove
    #    `cosign verify` actually refuses by pointing it at a throwaway key. Best-effort — a box without
    #    key-gen still got the real positives above.
    local ekpfx="$WORK/ephemeral"
    if (cd "$WORK" && COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix ephemeral >/dev/null 2>&1); then
        if cosign verify --key "$ekpfx.pub" --private-infrastructure "$(image_for dashboard):$TAG" >/dev/null 2>&1; then
            die "The dashboard image verified against an UNRELATED key — image verification is not real."
        fi
        ok "An unrelated key is refused (image verify is real, not a no-op)."
    else
        warn "Could not generate an ephemeral key for the wrong-key negative — skipping (the real positives above still ran)."
    fi
}

# verify_release() above proves cosign itself works, but it re-implements the cosign calls rather
# than exercising pithead's OWN verify_release_images() — the function `up`/`upgrade` actually run
# on every install (#376/#459). This extracts the published bundle (a real, non-source-checkout
# install dir — verify_release_images's `is_source_checkout` early-return only fires inside a git
# checkout) and calls that exact function directly, positive AND negative:
#   - positive (needs a signed release): the real function, against the real pinned digests + the
#     committed cosign.pub, in the real bundle dir, must pass.
#   - negative (security-critical, runs regardless of signing): a digest tampered in a COPY of the
#     bundle's docker-compose.yml can't verify against any real signature — the function must abort
#     fail-closed before anything would be pulled. This is the assertion that proves the real
#     host-path function refuses a mismatched digest, not just that a hand-rolled cosign call does.
verify_release_images_direct() {
    stage "verify_release_images() direct exercise (#376/#459) — the real host-path function"
    local bundle_dir="$WORK/pithead"
    tar -xzf "$WORK/pithead.tar.gz" -C "$WORK" ||
        die "Could not extract the published bundle to exercise verify_release_images()."
    [ -x "$bundle_dir/pithead" ] || die "Extracted bundle has no executable pithead at $bundle_dir."

    if [ "$SIGNED" -eq 1 ]; then
        local out
        if out="$(cd "$bundle_dir" && PITHEAD_REGISTRY="$REGISTRY" bash -c 'source ./pithead; verify_release_images' 2>&1)"; then
            ok "verify_release_images() passes for real, in the actual bundle dir (not a reimplementation)."
        else
            die "verify_release_images() FAILED against the real published bundle: $out"
        fi
    else
        warn "Release is unsigned — skipping the positive verify_release_images() exercise (needs a signed release; the negative/tamper case below still runs)."
    fi

    # Negative: corrupt ONE image's pinned digest in a COPY of the bundle and re-run the real
    # function. Needs a cosign.pub to reach the real cosign dial (the bundle's own, or the one
    # committed to this checkout) — without one, verify_release_images's documented fallback is to
    # WARN and proceed (#376 opt-in), which is a different, already-covered behaviour, not this gate.
    local pub_src=""
    [ -f "$bundle_dir/cosign.pub" ] && pub_src="$bundle_dir/cosign.pub"
    [ -z "$pub_src" ] && [ -f "$REPO_ROOT/cosign.pub" ] && pub_src="$REPO_ROOT/cosign.pub"
    if [ -z "$pub_src" ] || ! command -v cosign >/dev/null 2>&1; then
        warn "No cosign.pub available (bundle or committed) or cosign not installed — skipping the tamper-refuses negative case."
        return 0
    fi

    local tdir="$WORK/pithead-tampered"
    rm -rf "$tdir"
    cp -a "$bundle_dir" "$tdir"
    cp "$pub_src" "$tdir/cosign.pub"
    local orig_sha bad_sha
    orig_sha="$(grep -oE 'pithead-tor:[^[:space:]]*@sha256:[0-9a-f]+' "$tdir/docker-compose.yml" | grep -oE 'sha256:[0-9a-f]+' | head -1)"
    [ -n "$orig_sha" ] ||
        die "Could not find a digest-pinned pithead-tor image in the bundle's docker-compose.yml to tamper — the bundle isn't digest-pinned (#461 regression)."
    # A fixed all-zero 64-hex-char digest: the right SHAPE (a sha256 never legitimately hashes to
    # it) so verify_release_images sees a well-formed-but-mismatched digest, not a parse error.
    bad_sha="sha256:$(printf '%064d' 0)"
    sed -E "s#(pithead-tor:[^[:space:]]*@)$orig_sha#\\1$bad_sha#" "$tdir/docker-compose.yml" >"$tdir/docker-compose.yml.tmp" &&
        mv "$tdir/docker-compose.yml.tmp" "$tdir/docker-compose.yml"
    grep -qF "$bad_sha" "$tdir/docker-compose.yml" ||
        die "Failed to tamper the bundle's docker-compose.yml digest — the negative case didn't set up."

    local out2 rc2=0
    out2="$(cd "$tdir" && PITHEAD_REGISTRY="$REGISTRY" bash -c 'source ./pithead; verify_release_images' 2>&1)" || rc2=$?
    if [ "$rc2" -eq 0 ]; then
        die "verify_release_images() PASSED against a TAMPERED digest — fail-closed verification is not real (#376/#459). Output: $out2"
    fi
    ok "verify_release_images() REFUSES a tampered/mismatched digest (fail-closed, #376/#459): $(printf '%s' "$out2" | tail -1)"
}

# --- Phase 2: real #59 upgrade against the published bundle ---------------------------------------

smoke_upgrade() {
    stage "Real #59 upgrade → $TAG (install: $UPGRADE_DIR)"
    local dir="$UPGRADE_DIR"
    [ -x "$dir/pithead" ] || die "--upgrade dir '$dir' has no executable pithead — point it at a previous-release install."
    [ -f "$dir/VERSION" ] || die "$dir has no VERSION file — not a pithead install."
    local cur
    cur="$(tr -d '[:space:]' <"$dir/VERSION")"
    [ "v$cur" != "$TAG" ] || die "Install at $dir is already $TAG — the upgrade smoke needs it on the PREVIOUS release."
    local spool="$dir/data/control"
    [ -d "$spool/requests" ] ||
        die "No control spool at $spool/requests — the #59 path rides the #33 control channel. Enable dashboard.control on $dir and bring the stack up first."

    warn "About to run the REAL host upgrade on $dir — it recreates that box's stack. Ctrl-C now to abort."
    confirm_upgrade

    # Enqueue the exact intent the dashboard POSTs (#59), then let the host runner do the real work:
    # re-derive the latest tag over Tor, download the bundle, cosign-verify it, rollback-guard it,
    # extract, and run `pithead upgrade`. Nothing here reimplements that path.
    local id
    id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')" || id=""
    [ -n "$id" ] || id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
    [ -n "$id" ] || die "Could not generate a request id (need uuidgen or /proc/sys/kernel/random/uuid)."
    jq -n --arg id "$id" --arg v "$TAG" --arg a "release-smoke" \
        '{id:$id, action:"upgrade", actor:$a, version:$v}' >"$spool/requests/$id.json"
    ok "Enqueued upgrade intent $id ($TAG) into the control spool."

    # Drive the runner exactly as the systemd path unit does (docs/dev/releasing.md documents the manual
    # `control-run-pending` drain).
    (cd "$dir" && ./pithead control-run-pending) || die "control-run-pending failed — see the output above."

    # Poll the result spool for this id (an upgrade pulls a whole release of images first).
    local result="$spool/results/$id.json" status="" waited=0
    while [ "$waited" -lt 900 ]; do
        if [ -f "$result" ]; then
            status="$(jq -r '.status // ""' "$result" 2>/dev/null || true)"
            [ -n "$status" ] && [ "$status" != "running" ] && break
        fi
        sleep 5
        waited=$((waited + 5))
    done
    [ "$status" = "upgraded" ] ||
        die "Upgrade did not report success (status='${status:-none}' after ${waited}s): $(cat "$result" 2>/dev/null || echo '<no result file>')"

    local new
    new="$(tr -d '[:space:]' <"$dir/VERSION")"
    [ "v$new" = "$TAG" ] || die "Runner reported 'upgraded' but $dir/VERSION is '$new', not $TAG."
    ok "Install at $dir upgraded cleanly $cur → $new via the real #59 control path."
}

# Interactive gate before the destructive phase-2 upgrade (auto-yes when not a TTY, so a runbook
# harness can drive it).
confirm_upgrade() {
    [ -t 0 ] || return 0
    local reply
    read -r -p "Proceed with the real upgrade on $UPGRADE_DIR? (y/N): " reply || true
    [[ "$reply" =~ ^[Yy] ]] || die "Upgrade smoke cancelled — nothing was changed."
}

# --- Main ----------------------------------------------------------------------------------------

log "Post-publish release smoke test (#459) — $TAG"
fetch_published_bundle
verify_release
verify_release_images_direct
if [ -n "$UPGRADE_DIR" ]; then
    smoke_upgrade
else
    log "Skipping the #59 upgrade smoke (no --upgrade DIR). Run it on the previous-release bench box."
fi

printf '\n'
if [ "$SIGNED" -eq 1 ]; then
    ok "Smoke passed: $TAG is signed and verifies for real$([ -n "$UPGRADE_DIR" ] && echo ', and upgrades cleanly')."
else
    ok "Smoke passed: $TAG downloaded and checked; release is UNSIGNED (opt-in signing off)$([ -n "$UPGRADE_DIR" ] && echo '; upgrade path exercised')."
fi
