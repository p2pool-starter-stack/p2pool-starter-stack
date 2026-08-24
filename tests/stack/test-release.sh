# shellcheck shell=bash
#
# Release domain (#1105 Phase 1): release.sh's side-effect-free logic (semver/image-name helpers,
# the ingredient manifest, bundle-contents/build-mounts checks), the GHCR read-after-push retry,
# the release-toolchain preflight, release-smoke's upgraded-install resolution, pull-vs-build mode
# detection, and the release bundle's macOS-xattr hygiene guard. Sourced by tests/stack/run.sh
# after lib.sh. (release.sh's signing/refusal/pinned-verifier/cosign-path tests move separately,
# to test-release-signing.sh. Left in run.sh, despite sharing a section marker with moved content:
# the #291 firewall-ordering assertions trailing cosign_container_path — tor/network, not release;
# the XvB tier-threshold drift guard trailing "release.sh pure logic" — dashboard, not release; the
# xmrig-proxy/tor-entrypoint tests trailing the bundle-hygiene section — unrelated domains; the
# doctor-side release-verification diagnostic and the control-channel upgrade's own bundle-
# signature check — doctor/control, by the same run-against-its-own-sandbox reasoning module 4
# used for apply --dry-run/symlink-invocation.)

echo "== unit: release.sh pure logic (#44) =="
# The release pipeline's side-effect-free helpers (no docker needed). Sourced from the repo root with
# the positional args cleared (`set --`) so release.sh's own arg-parser doesn't see the test's args;
# release.sh guards its main() behind a BASH_SOURCE check, so sourcing only defines the functions.
REL="$ROOT/scripts/release.sh"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "0.1.0"
)
assert_rc "is_semver accepts 0.1.0" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "1.2.3-rc.1"
)
assert_rc "is_semver accepts a prerelease" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "1.2"
)
assert_rc "is_semver rejects a partial" "$?" "1"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "v1.2.3"
)
assert_rc "is_semver rejects a leading v" "$?" "1"
# shellcheck disable=SC1090
assert_eq "image_for builds the GHCR image name" \
    "$(
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        image_for dashboard
    )" \
    "ghcr.io/p2pool-starter-stack/pithead-dashboard"
# --draft (#44): documented in --help, and --help stops at the comment header (a too-wide sed range
# used to leak the script body, e.g. `set -euo pipefail`, into the help output).
assert_contains "release --help documents --draft" "$(bash "$REL" --help 2>&1)" "--draft"
case "$(bash "$REL" --help 2>&1)" in
*"set -euo pipefail"*) bad "release --help stops at the comment header" "leaked the script body into --help" ;;
*) ok "release --help stops at the comment header" ;;
esac
# Bundle completeness: the pull-based bundle must ship every ./build/* path the compose MOUNTS at
# runtime. A pull install builds nothing and the images don't bake these in, so a missing one mounts an
# empty dir and breaks the container — the v1.0.0 bundle shipped without monerod's bitmonero.conf.template
# exactly this way. compose_build_mounts derives the list make_bundle copies.
# shellcheck disable=SC1090
BUILD_MOUNTS="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    compose_build_mounts docker-compose.yml
)"
assert_contains "bundle ships monerod's config template" "$BUILD_MOUNTS" "./build/monero/bitmonero.conf.template"
assert_contains "bundle ships the tari config dir" "$BUILD_MOUNTS" "./build/tari"
# The bundle must ship the BASIC config template (the documented quick-start config — `cp
# config.minimal.json config.json`) and unpack to a versionless `pithead/` dir for the stable
# /releases/latest/download/pithead.tar.gz URL. Build a real bundle and inspect it.
# shellcheck disable=SC1090,SC2034  # dynamic source; TAG/REGISTRY/DRY_RUN are consumed inside make_bundle
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SANDBOX/bundle"
    mkdir -p "$WORKDIR"
    TAG=v9.9.9
    REGISTRY=ghcr.io/test
    DRY_RUN=0
    # make_bundle now digest-pins the first-party images (#376), so it needs the promoted digests
    # promote would have captured -- a full repo@sha256 ref, as set_digest stores them.
    for _s in "${IMAGES[@]}"; do set_digest "$_s" "ghcr.io/test/pithead-$_s@sha256:feed${_s}dad"; done
    make_bundle "$WORKDIR/pithead.tar.gz" >/dev/null 2>&1
    cp "$WORKDIR/pithead/docker-compose.yml" "$SANDBOX/bundle-compose.yml" 2>/dev/null || true
    tar tzf "$WORKDIR/pithead.tar.gz" 2>/dev/null
) >"$SANDBOX/bundle.list" 2>/dev/null
grep -q '^pithead/config.minimal.json$' "$SANDBOX/bundle.list" && ok "bundle ships config.minimal.json (basic quick-start config)" || bad "bundle ships config.minimal.json" "absent from the bundle"
grep -q '^pithead/$' "$SANDBOX/bundle.list" && ok "bundle unpacks to versionless pithead/" || bad "bundle unpacks to pithead/" "top-level dir is not pithead/"
# Every first-party image line in the bundled compose must be digest-pinned (#376).
_bundle_unpinned=$(grep -E 'pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):' "$SANDBOX/bundle-compose.yml" 2>/dev/null | grep -cv '@sha256:')
[ "${_bundle_unpinned:-1}" -eq 0 ] && ok "bundle compose digest-pins all 5 first-party images (#376)" || bad "bundle digest-pins first-party images (#376)" "unpinned lines: ${_bundle_unpinned:-?}"
if grep -q 'pithead-dashboard:${STACK_VERSION:-dev}@sha256:feeddashboarddad' "$SANDBOX/bundle-compose.yml" 2>/dev/null; then
    ok "digest pin appends only the bare sha256, no double-repo (#376)"
else
    bad "digest pin format (#376)" "expected tag@sha256:digest on the dashboard image line"
fi
_bm_missing=""
for _m in $BUILD_MOUNTS; do [ -e "$ROOT/$_m" ] || _bm_missing="$_bm_missing $_m"; done
assert_eq "every compose ./build runtime mount exists in the tree" "${_bm_missing:-none}" "none"
case "$BUILD_MOUNTS" in
*Dockerfile*) bad "bundle build-mounts exclude Dockerfiles" "a Dockerfile would flip the bundle pull->build mode" ;;
*) ok "bundle build-mounts exclude Dockerfiles" ;;
esac
# Target-arch guard: the release MUST build linux/amd64 (the bundled binaries are x86_64; xmrig-proxy
# has no arm64 build, so the stack can't be arm64). A plain host-arch `docker build` on an arm64 dev box
# shipped arm64-labelled images that don't run on x86_64 — the v1.0.0 defect. Assert the pipeline builds
# via buildx (which forces the target arch even on an arm64 host), defaults to amd64, and that smoke
# rejects a wrong-arch push.
REL_SRC="$(cat "$REL")"
assert_contains "release builds with buildx (forces the target arch)" "$REL_SRC" "docker buildx build"
PLAT_DEF="$(grep -E '^PLATFORMS=' "$REL" | head -1)"
case "$PLAT_DEF" in
*linux/amd64*) ok "release targets linux/amd64 (the x86_64 binaries' platform)" ;;
*) bad "release targets linux/amd64" "PLATFORMS default: $PLAT_DEF" ;;
esac
assert_contains "smoke stage verifies the pushed image's target platform" "$REL_SRC" "missing target platform"
# write_manifest's "- **Version:**" line starts with a dash; without `printf --` it died with
# "printf: - : invalid option" and broke the whole publish stage. Render it and assert it survives.
man_out="$SANDBOX/manifest.md"
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside write_manifest
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    TAG="v9.9.9"
    STACK_VERSION="9.9.9"
    GIT_COMMIT="abc1234"
    BUILD_DATE="now"
    WORKDIR="$SANDBOX"
    write_manifest "$man_out"
) 2>/dev/null
assert_contains "manifest renders the leading-dash Version line (printf --)" "$(cat "$man_out" 2>/dev/null)" "- **Version:** 9.9.9"
# #1138's actual deliverable is that the ingredient list names BOTH Tari images. The drift guard
# below tests pin(), which is a different function — deleting either printf leaves it green while
# the notes regress to naming one of the two. Assert the rendered manifest, which is the artefact an
# operator reads. A twin-sync conflict on release.sh is a realistic way to lose one of these lines.
assert_contains "manifest names the tari NODE pin (#1138)" "$(cat "$man_out" 2>/dev/null)" \
    "- tari node: \`quay.io/tarilabs/minotari_node:"
assert_contains "manifest names the tari CONSOLE WALLET pin (#1138)" "$(cat "$man_out" 2>/dev/null)" \
    "- tari console wallet: \`quay.io/tarilabs/minotari_console_wallet:"
# The ingredients manifest's component pins must resolve to a real value present in each Dockerfile —
# a drift guard so a renamed ARG can't silently emit an empty pin in the release notes.
for svc in p2pool monero xmrig-proxy; do
    # shellcheck disable=SC1090
    pv="$(
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        pin "$svc"
    )"
    if [ -n "$pv" ] && grep -q -- "$pv" "$ROOT/build/$svc/Dockerfile"; then
        ok "pin $svc resolves to a value in its Dockerfile"
    else
        bad "pin $svc resolves to a value in its Dockerfile" "got '$pv'"
    fi
done
# The same drift guard for the pins read out of docker-compose.yml and build/tor, which had none
# (#1138). pin() emits the EMPTY string when its grep stops matching — a renamed image, a moved tag
# format — and the release notes then print "- caddy: " with nothing after it. The ingredient list's
# whole job, silently not done, on the exact surface an operator uses to check what they installed.
#
# Each row also names the identifier the pin MUST contain, and that half is the one that matters.
# "is $pv present in the file it came from" is a TAUTOLOGY for every arm here — pin() extracts a
# substring of that same file, so any non-empty answer is present by construction, and the check
# would only ever have caught the empty case. It would NOT have caught the mistake this issue is
# about: an arm that greps a SIBLING's image (a copy-paste slip when adding tari-wallet next to
# tari, or a later edit "de-duplicating" two near-identical regexes) resolves fine, matches the
# file, and reports ok while the release notes name the same image twice.
# grep -F throughout: these values carry '/' and '.', and a regex match would accept a value that is
# merely similar to one in the file.
for row in \
    "tari|docker-compose.yml|quay.io/tarilabs/minotari_node:" \
    "tari-wallet|docker-compose.yml|quay.io/tarilabs/minotari_console_wallet:" \
    "caddy|docker-compose.yml|caddy:" \
    "socket-proxy|docker-compose.yml|tecnativa/docker-socket-proxy:" \
    "tor-base|build/tor/Dockerfile|:"; do
    comp="${row%%|*}"
    rest="${row#*|}"
    pin_rel="${rest%%|*}"
    pin_want="${rest#*|}"
    pin_src="$ROOT/$pin_rel"
    # shellcheck disable=SC1090
    pv="$(
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        pin "$comp"
    )"
    pin_ok=0
    if [ -n "$pv" ] && grep -qF -- "$pv" "$pin_src"; then
        case "$pv" in *"$pin_want"*) pin_ok=1 ;; esac
    fi
    if [ "$pin_ok" = 1 ]; then
        ok "pin $comp resolves to its own image in $pin_rel"
    else
        bad "pin $comp resolves to its own image in $pin_rel" "got '$pv', expected to contain '$pin_want'"
    fi
done
# The top-level VERSION file is the single source of truth (#44); the dashboard's Python package
# metadata must stay in lockstep so a release can't ship two different "stack versions".
ver_file="$(tr -d ' \t\r\n' <"$ROOT/VERSION")"
ver_pyproject="$(grep -oE '^version = "[^"]+"' "$ROOT/dashboard/pyproject.toml" | head -1 | cut -d'"' -f2)"
assert_eq "pyproject.toml version matches VERSION (#44)" "$ver_pyproject" "$ver_file"

echo "== unit: release.sh registry read retries GHCR read-after-push lag (#429) =="
# manifest_digest reads a tag GHCR just accepted, which can 404 for a few seconds (read-after-push
# lag) — this killed stage-4 digest capture twice on v1.3.1. retry_registry_read must retry until the
# read resolves. Stub buildx_inspect to fail the first two calls (empty + rc 1) then succeed; a counter
# file survives the retries. Backoff forced to 0 keeps the test instant.
RETRY_CNT="$SANDBOX/inspect.count"
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
retry_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    printf 0 >"$RETRY_CNT"
    buildx_inspect() {
        local n
        n=$(($(cat "$RETRY_CNT") + 1))
        printf '%s' "$n" >"$RETRY_CNT"
        [ "$n" -lt 3 ] && return 1                  # attempts 1 and 2 fail (tag not yet readable)
        printf 'Name: x\nDigest: sha256:deadbeef\n' # attempt 3 resolves
    }
    printf 'DIGEST=%s ATTEMPTS=%s\n' "$(manifest_digest some:tag)" "$(cat "$RETRY_CNT")"
)"
assert_contains "manifest_digest resolves after transient GHCR failures" "$retry_out" "DIGEST=sha256:deadbeef"
assert_contains "retried until the read succeeded (3 attempts)" "$retry_out" "ATTEMPTS=3"
# Genuinely-missing image: after the retries exhaust, manifest_digest stays empty so the caller's
# `[ -n "$digest" ] || die` still stops the release (a missing image must not silently pass).
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
exhaust_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    REGISTRY_READ_RETRIES=3
    buildx_inspect() { return 1; } # GHCR never makes it readable
    digest="$(manifest_digest gone:tag)"
    [ -n "$digest" ] || echo "DIED-EMPTY"
)"
assert_contains "exhausted retries -> empty digest (caller dies)" "$exhaust_out" "DIED-EMPTY"
# The smoke stage's raw manifest read has the same read-after-push exposure — wire it through the retry.
assert_contains "smoke stage reads the manifest via retry_registry_read (#429)" \
    "$(cat "$REL")" "retry_registry_read buildx_inspect \"\$repo:\$STAGING_TAG\" --raw"

# #557: the test above disables errexit (`set +eu`, right after sourcing) to observe the bare helper
# in isolation, which happens to mask a real bug in stage_push itself: the bare
# `digest="$(manifest_digest ...)"` assignment aborts under release.sh's own `set -euo pipefail`
# BEFORE the crafted die() ever runs, so a real release run got a silent abort instead of a diagnosed
# digest-read failure. Reproduce with errexit left ON, driving the REAL stage_push (not the bare
# helper) so the actual call site is exercised.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside stage_push
stage_push_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        DRY_RUN=0
        IMAGES=(tor)
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        WORKDIR="$SANDBOX/stagepush557"
        mkdir -p "$WORKDIR"
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        stage_push
    ) 2>&1
)"
assert_rc "stage_push, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "stage_push, real errexit: crafted die() reaches the operator (#557)" \
    "$stage_push_out" "Could not read the pushed manifest digest"

# #557: main()'s --resume-promote branch has the exact same shape (a second, separately-written
# instance of the bug — found in review, not part of the original 3 sites). Drive the real `main`
# (preflight/ghcr_login stubbed no-op) with RESUME_PROMOTE=1 and errexit left ON.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside main
resume_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        preflight() { :; }
        ghcr_login() { :; }
        promote() { :; }
        sign_images() { :; }
        publish() { :; }
        DRY_RUN=0
        RESUME_PROMOTE=1
        IMAGES=(tor)
        TAG="v9.9.9"
        STAGING_TAG="v9.9.9-rc.1"
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        main
    ) 2>&1
)"
assert_rc "--resume-promote, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "--resume-promote, real errexit: crafted die() reaches the operator (#557)" \
    "$resume_out" "Cannot resolve a staged digest"

echo "== unit: release.sh preflight checks the lint toolchain (#426) =="
# A reimaged release box loses shellcheck/shfmt/node/uv — the v1.3.0 cut died ~1 min in mid-gate with a
# bare `shellcheck: not found`. check_release_toolchain must fail fast BEFORE building, naming the tool
# and the provisioning doc. Point PATH at a sandbox of stub tools so the host's real PATH doesn't decide.
RTB="$SANDBOX/release-tools"
mkdir -p "$RTB"
for t in shellcheck shfmt node npx uv uvx; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$RTB/$t"
    chmod +x "$RTB/$t"
done
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain >/dev/null 2>&1
)
assert_rc "full toolchain present -> preflight passes" "$?" "0"
rm -f "$RTB/shfmt" # simulate a reimaged box missing one tool
# shellcheck disable=SC1090
tc_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain 2>&1
)"
tc_rc=$?
assert_rc "missing tool -> preflight fails fast (rc 1)" "$tc_rc" "1"
assert_contains "the missing tool is named" "$tc_out" "shfmt"
assert_contains "error points at the provisioning doc" "$tc_out" "release-server.md"

echo "== unit: release-smoke resolves the upgraded install at ASSERT time (#1068) =="
# The #59 upgrade never rewrites the old install in place — it extracts a fresh pithead-v<new> and
# repoints `current`, which is what makes rollback possible. So asserting on the directory the run
# was POINTED at could only pass if the upgrade had overwritten the previous install: a correct
# upgrade reported as a failure, on the documented final gate of a release. MUTATION PROOF: return
# the given path unresolved and both "lands on" assertions go red.
SMK="$SANDBOX/smoke1068"
SMOKE_SH="$ROOT/scripts/release-smoke.sh"
mkdir -p "$SMK/pithead-v1.18.1" "$SMK/pithead-v1.19.0"
printf '1.18.1\n' >"$SMK/pithead-v1.18.1/VERSION"
printf '1.19.0\n' >"$SMK/pithead-v1.19.0/VERSION"
ln -sfn "$SMK/pithead-v1.19.0" "$SMK/current"
smoke_resolve() { # <dir-as-given>
    (
        _arg="$1"          # saved before `set --`, which release-smoke's own arg parser needs empty
        cd "$ROOT" || exit # its top level insists on a git repo, like the real invocation
        set --
        # Sourced through a variable, never a literal path: shellcheck follows a literal that names
        # another file in the same invocation, and release-smoke pulls in release.sh, whose
        # `local tool missing=()` then collides with this file's own scalar `missing` (SC2178).
        # shellcheck disable=SC1090
        source "$SMOKE_SH" 2>/dev/null
        set +eu
        upgraded_install_dir "$_arg"
    )
}
# Handed the previous VERSIONED dir — the shape that produced the false red. It is unchanged by
# design, so the answer has to come from the `current` beside it.
assert_eq "a versioned dir resolves to where the upgrade actually landed" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/pithead-v1.18.1")/VERSION")" "1.19.0"
# Handed the SYMLINK — resolved now, after the upgrade moved it. This is why the v1.19.2 cut did
# not hit the false red, and it must keep working.
assert_eq "the current symlink resolves to the new install" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/current")/VERSION")" "1.19.0"
# Nothing moved: a box that is already on the target must resolve to itself, not wander off.
ln -sfn "$SMK/pithead-v1.18.1" "$SMK/current"
assert_eq "with current pointing at it, the same dir resolves to itself" \
    "$(smoke_resolve "$SMK/pithead-v1.18.1")" "$SMK/pithead-v1.18.1"
# NOTE, measured rather than assumed: replacing the `readlink -f` with the raw argument leaves all
# three assertions above GREEN. The sibling lookup is what fixes the false red; the readlink only
# normalises the path that lands in the pass and failure messages. Recorded here so the next reader
# does not mistake it for a covered behaviour.
rm -rf "$SMK"
unset SMK SMOKE_SH

echo "== unit: pull-vs-build mode (#44) =="
# is_source_checkout / resolve_pull_policy / STACK_VERSION key off whether the image build CONTEXTS
# (Dockerfiles) are present: a source checkout builds locally (:dev, --pull never); a release bundle
# (only build/tari/ + VERSION) pulls (:vX.Y.Z, --pull missing). Two scratch dirs stand in for each.
SRCM="$SANDBOX/srcmode"
mkdir -p "$SRCM/dashboard"
: >"$SRCM/dashboard/Dockerfile"
printf '0.1.0\n' >"$SRCM/VERSION"
RELM="$SANDBOX/relmode"
mkdir -p "$RELM/build/tari"
printf '0.1.0\n' >"$RELM/VERSION"
# shellcheck disable=SC1090
(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout true with a Dockerfile" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout false without a Dockerfile" "$?" "1"
# shellcheck disable=SC1090
assert_eq "pull policy: source -> never" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "never"
# shellcheck disable=SC1090
assert_eq "pull policy: release -> missing" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "missing"
# shellcheck disable=SC1090
assert_eq "pull policy: PITHEAD_PULL override" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    PITHEAD_PULL=always resolve_pull_policy
)" "always"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION dev in a source checkout" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "dev"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION v0.1.0 in a release bundle" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "v0.1.0"

echo "== release: install bundle is free of macOS xattr pax headers (#252) =="
# Static guard: make_bundle must keep `--no-xattrs` AND the post-bundle xattr assertion, so the
# fix can't be silently reverted in a future edit.
REL="$ROOT/scripts/release.sh"
assert_contains "release.sh tars the bundle with --no-xattrs" \
    "$(grep -E '^[[:space:]]*tar .*--no-xattrs' "$REL" || true)" "--no-xattrs"
assert_contains "release.sh guards the bundle against xattr pax headers" \
    "$(cat "$REL")" "LIBARCHIVE.xattr"
# Functional: this platform's tar must actually honour --no-xattrs (the guard's whole premise).
# Tar a file that carries an xattr where we can set one (macOS: xattr -w / Linux: setfattr; a
# no-op elsewhere), and assert no LIBARCHIVE.xattr/SCHILY.xattr pax header survives — the exact
# check release.sh runs. Reproduces #252 on macOS; a clean no-op on GNU tar.
RELTMP="$(mktemp -d)"
mkdir -p "$RELTMP/pithead"
echo hi >"$RELTMP/pithead/f"
xattr -w com.test val "$RELTMP/pithead/f" 2>/dev/null ||
    setfattr -n user.test -v val "$RELTMP/pithead/f" 2>/dev/null || true
tar --no-xattrs -czf "$RELTMP/b.tar.gz" -C "$RELTMP" pithead 2>/dev/null
if grep -qa -e 'LIBARCHIVE.xattr' -e 'SCHILY.xattr' <(gzip -dc "$RELTMP/b.tar.gz" 2>/dev/null); then
    bad "tar --no-xattrs yields an xattr-free bundle" "xattr pax headers present despite --no-xattrs"
else
    ok "tar --no-xattrs yields an xattr-free bundle"
fi
rm -rf "$RELTMP"
