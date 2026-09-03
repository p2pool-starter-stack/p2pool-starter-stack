# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Release-signing domain (#1105 Phase 1): verify_release_images' fail-closed image-verification
# gate, cosign_container_path's host-to-container path mapping, and release.sh's signing/refusal/
# pinned-verifier-image checks (sign the promoted digests, refuse to publish unsigned, validate
# the pinned cosign verifier before publish). Sourced by tests/stack/run.sh after lib.sh. (The
# #291 firewall-ordering assertions trailing cosign_container_path are not here — tor/network, not
# signing, the documented map trap; they live in test-tor-network.sh. The control-channel upgrade's
# own bundle-signature check and its trailing control-disabled probe live in test-control-upgrade.sh
# in full: that section runs the control-run-pending verb against the $C control sandbox, the same
# run-against-its-own-sandbox reasoning module 4 used for apply --dry-run/symlink-invocation.)

echo "== black-box: verify_release_images fail-closed gate (#376) =="
# The verification decision itself, against a fake docker on a PINNED PATH ($VRI/bin:/usr/bin:/bin
# — coreutils stay, so the host can never decide the outcome). Since #1072 the verifier is a
# container, so the stub is `docker`, not `cosign`: it answers the availability probe, pretends the
# pinned image is already present, and logs the cosign argv that follows the image ref — which keeps
# every assertion below reading exactly as it did when cosign was a host binary. A release install
# is a dir without dashboard/Dockerfile.
VRI="$SANDBOX/verify376"
write_fake_docker "$VRI/bin"
write_unreachable_docker "$VRI/nodocker"

# A deterministic 64-hex digest per image, and a digest-pinned compose (#461) so verify has the same
# @sha256 bytes to check that a release install's compose would pull (#451). TOR_DG is what the tor
# assertions expect the tor image to be verified/failed against.
hex64() { printf "$1%.0s" $(seq 1 64); }
TOR_DG="sha256:$(hex64 1)"
write_pinned_compose() { # $1=dir  — one image: line per first-party suffix, each pinned by @sha256
    local d="$1" n=1 suffix
    : >"$d/docker-compose.yml"
    for suffix in tor monero p2pool xmrig-proxy dashboard; do
        printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-%s:${STACK_VERSION:-dev}@sha256:%s\n' \
            "$suffix" "$(hex64 "$n")" >>"$d/docker-compose.yml"
        n=$((n + 1))
    done
}
write_pinned_compose "$VRI"

# No cosign.pub (an install older than the first signed release): documented fallback — proceed,
# but say loudly that nothing was verified.
out="$(PATH="$VRI/bin:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "no pubkey -> pull proceeds (documented fallback)" "$?" "0"
assert_contains "no pubkey -> loud NOT-verified warning" "$out" "NOT be signature-verified"

# cosign.pub present but the verifier cannot run (docker daemon unreachable): FAIL CLOSED — an
# unavailable verifier must not silently disable verification.
printf 'fake release public key' >"$VRI/cosign.pub"
out="$(PATH="$VRI/nodocker:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "pubkey without a runnable verifier -> pull aborts" "$?" "1"
assert_contains "verifier-missing abort names docker, not a host cosign" "$out" "docker is not available"

# Valid signatures (fake cosign exits 0): all 5 images verified with the committed key, no Rekor
# (--private-infrastructure), against the EXACT @sha256 digest compose pins and pulls (#451 — bound
# to the same bytes, not the mutable tag).
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "valid signatures -> pull proceeds" "$?" "0"
assert_eq "all 5 first-party images verified" "$(grep -c '^\[cosign\] verify ' "$VRI/cosign.log")" "5"
assert_contains "verify binds to the pinned digest, not the tag (#451)" \
    "$(cat "$VRI/cosign.log")" "verify --key cosign.pub --private-infrastructure ghcr.io/test/pithead-tor@$TOR_DG"
assert_not_contains "verify never resolves the mutable tag (#451)" "$(cat "$VRI/cosign.log")" "pithead-tor:v9.9.9"

# A signature that does not verify (fake cosign exits 1): FAIL CLOSED. This is the red test for the
# whole feature — bypass or soften the verification and it goes green-to-broken.
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "bad signature -> pull aborts (fail closed)" "$?" "1"
assert_contains "bad-signature abort names the pinned image" "$out" "Signature verification FAILED for ghcr.io/test/pithead-tor@$TOR_DG"

# cosign.pub present but the compose is NOT digest-pinned (a pre-#461 or tampered bundle): FAIL
# CLOSED (#451). Without a digest there's nothing to bind verification to the pulled bytes, so the
# verify-then-pull window can't be closed — refuse rather than fall back to verifying the tag.
UNPINNED="$SANDBOX/verify451-unpinned"
mkdir -p "$UNPINNED"
printf 'fake release public key' >"$UNPINNED/cosign.pub"
printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-tor:${STACK_VERSION:-dev}\n' >"$UNPINNED/docker-compose.yml"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" run_sourced "$UNPINNED" verify_release_images 2>&1)"
assert_rc "un-pinned compose + key -> pull aborts (#451)" "$?" "1"
assert_contains "un-pinned abort explains the missing digest bind" "$out" "not digest-pinned"
assert_eq "un-pinned -> cosign never asked to verify a tag" "$(cat "$VRI/cosign.log")" ""

# #557: run_sourced disables errexit (`set +e`, right after sourcing) for every test above, which
# happens to mask a real bug: the bare `sha="$(compose_pinned_digest ...)"` assignment aborts under
# pithead's own `set -Eeuo pipefail` BEFORE the crafted error() above ever runs, so a real invocation
# got a silent abort instead of the "not digest-pinned" diagnostic. Reproduce with errexit left ON —
# source directly and call the function, no run_sourced/`set +e`.
# shellcheck disable=SC1090  # dynamic source: the script under test
out557_vri="$(
    (
        cd "$UNPINNED" || exit 1
        PATH="$VRI/bin:/usr/bin:/bin"
        source "$STACK" 2>/dev/null
        verify_release_images
    ) 2>&1
)"
assert_rc "un-pinned + key, real errexit -> still aborts (#557)" "$?" "1"
assert_contains "un-pinned + key, real errexit -> crafted message still reaches the operator (#557)" \
    "$out557_vri" "not digest-pinned"

# Source checkout: locally built images are unsigned by design — skipped, silently and completely.
mkdir -p "$VRI/dashboard"
touch "$VRI/dashboard/Dockerfile"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 COSIGN_LOG="$VRI/cosign.log" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "source checkout -> verification skipped" "$?" "0"
assert_eq "source checkout -> cosign never invoked" "$(cat "$VRI/cosign.log")" ""
rm -rf "$VRI/build"

echo "== unit: cosign_container_path maps host paths into the verifier's mount (#1072) =="
# The verifier container sees the install dir at /w, so every file argument has to be renamed into
# that mount. The refusal case is the one that matters: both callers report a cosign failure as a
# SIGNATURE failure, so a path this function got wrong would read as a tampered download and burn a
# genuine release. It must fail rather than emit a path the mount does not cover.
CCP="$SANDBOX/ccp"
mkdir -p "$CCP/data/control/staged"
touch "$CCP/cosign.pub" "$CCP/data/control/staged/.abc.tar.gz"
assert_eq "file beside pithead -> /w/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/cosign.pub")" "/w/cosign.pub"
assert_eq "staged bundle -> /w/<relative dirs>/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
# The `current -> pithead-vX.Y.Z` layout: CONTROL_DIR in .env can name the same file through the
# symlink while the runner's cwd is the physical dir. Canonicalizing both sides is what makes these
# agree — a plain "${path#$PWD/}" prefix strip silently does not, and would fail closed on prod.
ln -sfn "$CCP" "$SANDBOX/ccp-current"
assert_eq "same file reached via the current symlink still resolves" \
    "$(run_sourced "$CCP" cosign_container_path "$SANDBOX/ccp-current/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
run_sourced "$CCP" cosign_container_path "$SANDBOX/outside.txt" >/dev/null 2>&1
assert_rc "a path outside the install dir is refused, not guessed at" "$?" "1"
run_sourced "$CCP" cosign_container_path "/etc/hosts" >/dev/null 2>&1
assert_rc "an absolute path elsewhere on the box is refused" "$?" "1"

echo "== unit: release.sh signs the promoted digests (#376) =="
# sign_images must sign the recorded manifest-LIST digest (repo@sha256:… — never the mutable tag,
# never a per-arch child) with the box's key and no Rekor upload; the password never reaches argv.
# A fake cosign records exactly what it was asked to sign.
# $REL is re-derived here (not inherited from test-release.sh's "release.sh pure logic" section):
# this file sources earlier in run.sh than that one now, and the three signing sections below are
# the only ones in this domain that read release.sh's own functions rather than pithead's.
REL="$ROOT/scripts/release.sh"
SIGN="$SANDBOX/sign376"
mkdir -p "$SIGN/bin"
cat >"$SIGN/bin/cosign" <<'EOF'
#!/usr/bin/env bash
echo "[cosign] $*" >>"${COSIGN_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$SIGN/bin/cosign"
# shellcheck disable=SC1090,SC2030,SC2031,SC2034  # dynamic source; the globals are consumed inside sign_images
sign_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SIGN"
    DRY_RUN=0
    COSIGN_ENABLED=1
    COSIGN_KEY="/release-box/cosign.key"
    export COSIGN_LOG="$SIGN/cosign.log"
    PATH="$SIGN/bin:$PATH"
    for s in "${IMAGES[@]}"; do set_digest "$s" "ghcr.io/test/pithead-$s@sha256:feed$s"; done
    sign_images 2>&1
)"
assert_contains "sign stage announces itself" "$sign_out" "Sign the promoted digests"
assert_eq "all 5 promoted digests signed" "$(grep -c '^\[cosign\] sign ' "$SIGN/cosign.log")" "5"
assert_contains "signs the digest with the box key, no Rekor upload" "$(cat "$SIGN/cosign.log")" \
    "sign --key /release-box/cosign.key --tlog-upload=false --yes ghcr.io/test/pithead-dashboard@sha256:feeddashboard"
assert_not_contains "never signs a mutable tag" "$(cat "$SIGN/cosign.log")" ":v"
# Opt-in (#376): with signing OFF, sign_images is a no-op -- no cosign calls, and it says why.
: >"$SIGN/cosign-off.log"
# shellcheck disable=SC1090,SC2030,SC2031,SC2034  # dynamic source; the globals are consumed inside sign_images
sign_off_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SIGN"
    DRY_RUN=0
    COSIGN_ENABLED=0
    export COSIGN_LOG="$SIGN/cosign-off.log"
    PATH="$SIGN/bin:$PATH"
    for s in "${IMAGES[@]}"; do set_digest "$s" "ghcr.io/test/pithead-$s@sha256:feed$s"; done
    sign_images 2>&1
)"
assert_eq "signing off means no cosign invocations" "$(grep -c '^\[cosign\]' "$SIGN/cosign-off.log")" "0"
assert_contains "signing off announces the skip" "$sign_off_out" "skipping image signatures"
# The bundle gets a detached signature the #59 runner can fetch (pithead.tar.gz.sig), and the
# committed public key ships INSIDE the bundle so a release install has its verifier beside pithead.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    DRY_RUN=0
    COSIGN_KEY="/release-box/cosign.key"
    export COSIGN_LOG="$SIGN/cosign.log"
    PATH="$SIGN/bin:$PATH"
    sign_bundle "$SIGN/pithead.tar.gz" "$SIGN/pithead.tar.gz.sig" >/dev/null 2>&1
)
assert_contains "bundle signed as a detached blob signature" "$(cat "$SIGN/cosign.log")" \
    "sign-blob --key /release-box/cosign.key --tlog-upload=false --yes --output-signature $SIGN/pithead.tar.gz.sig"
assert_contains "the bundle ships cosign.pub (the install-side verifier)" "$(cat "$REL")" "config.reference.json config.core-keys.json cosign.pub"

echo "== unit: release.sh refuses to publish unsigned (#960/#1108) =="
# The producer used to treat signing as opt-in while the consumer treats it as mandatory: once
# cosign.pub is committed it ships in every bundle, and every one-click upgrade REFUSES a release
# with no pithead.tar.gz.sig. So a cut on a box with no key does not make a degraded release, it
# makes one the whole fleet rejects — and GitHub release assets are immutable, so the signature can
# never be added afterwards. That is how v1.18.0 shipped unsigned and had to be withdrawn (#960).
# resolve_signing must therefore ABORT the cut. MUTATION PROOF: change its final die() to warn() and
# "an unconfigured signing box aborts the cut" goes red (verified — see the PR).
SGN="$SANDBOX/signing960"
mkdir -p "$SGN/bin" "$SGN/v3" "$SGN/nopub"
# A cosign that advertises --tlog-upload, the flag both signing calls pass.
printf '#!/usr/bin/env bash\necho "      --tlog-upload   upload to the transparency log"\nexit 0\n' >"$SGN/bin/cosign"
# cosign v3 removed that flag: the box passes every other check and then dies at stage 6b, with the
# images already promoted (#960 — the release box had drifted to v3.1.2 exactly this way).
printf '#!/usr/bin/env bash\necho "      --yes   skip confirmation"\nexit 0\n' >"$SGN/v3/cosign"
chmod +x "$SGN/bin/cosign" "$SGN/v3/cosign"
: >"$SGN/cosign.key"

# One resolve_signing decision, rendered as "rc=N <message> enabled=N". The env arrives as a string
# because release.sh's option parser needs an empty argv (`set --`), which eats positional args; and
# COSIGN_ENABLED — the variable that actually drives whether anything gets signed — is reported from
# an EXIT trap, because die() exits this subshell before a trailing read of it could run.
signing_decide() { # <cwd> <env-assignments>
    _out="$(
        cd "$1" || exit
        _envs="$2"
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        eval "$_envs"
        trap 'printf " enabled=%s" "${COSIGN_ENABLED:-unset}"' EXIT
        resolve_signing 2>&1
    )"
    printf 'rc=%s %s' "$?" "$_out"
}
SGN_OK="PATH=$SGN/bin:\$PATH; COSIGN_KEY=$SGN/cosign.key; COSIGN_PASSWORD=x; UNSIGNED=0; DRY_RUN=0"

sg="$(signing_decide "$ROOT" "$SGN_OK")"
assert_contains "a complete signing env turns signing ON" "$sg" "rc=0"
assert_contains "signing ON is what the later stages actually read" "$sg" "enabled=1"
assert_contains "signing ON says what will be signed" "$sg" "Release signing ON"
# The defect itself: cosign.pub committed + no key must stop the cut, and say why it cannot be fixed later.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}")"
assert_contains "an unconfigured signing box aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the missing piece" "$sg" "COSIGN_KEY is unset"
assert_contains "the abort says the fleet would refuse the release" "$sg" "every one-click upgrade refuses"
assert_contains "the abort says assets are immutable, so this cannot be fixed after publish" "$sg" "immutable"
assert_contains "the abort offers the deliberate escape hatch" "$sg" "--unsigned"
# --unsigned is the loud, explicit way to publish one anyway.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}; UNSIGNED=1")"
assert_contains "--unsigned publishes anyway" "$sg" "rc=0"
assert_contains "--unsigned leaves signing genuinely off" "$sg" "enabled=0"
assert_contains "--unsigned warns the fleet will refuse this release" "$sg" "REFUSES a release that has none"
# No committed public key means nothing in the field fails closed — warn and proceed, as before.
sg="$(signing_decide "$SGN/nopub" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}")"
assert_contains "no committed cosign.pub still publishes unsigned" "$sg" "rc=0"
assert_contains "no committed cosign.pub leaves signing off" "$sg" "enabled=0"
assert_contains "no committed cosign.pub says installs will not verify" "$sg" "proceed unverified"
# COSIGN_PASSWORD was never checked before: cosign would prompt for it at stage 6b, after promotion.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_PASSWORD=x/unset COSIGN_PASSWORD}")"
assert_contains "an unset COSIGN_PASSWORD aborts the cut" "$sg" "rc=1"
assert_contains "the abort names COSIGN_PASSWORD" "$sg" "COSIGN_PASSWORD is unset"
# Set-but-empty is a legitimate key with no passphrase — an -n test would wrongly block that box.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_PASSWORD=x/COSIGN_PASSWORD=}")"
assert_contains "an empty passphrase is a valid key, not a missing one" "$sg" "rc=0"
assert_contains "an empty passphrase still signs" "$sg" "enabled=1"
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/COSIGN_KEY=$SGN\/absent.key}")"
assert_contains "a COSIGN_KEY naming no file aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the path it could not find" "$sg" "$SGN/absent.key"
# The version drift that killed a cut: the flags are probed, not the version number.
sg="$(signing_decide "$ROOT" "${SGN_OK/PATH=$SGN\/bin/PATH=$SGN\/v3}")"
assert_contains "a cosign without --tlog-upload aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the flag that would fail at stage 6b" "$sg" "--tlog-upload"
# The rehearsal is the point: the decision used to sit inside `if [ "$DRY_RUN" -eq 0 ]`, so a dry run
# printed "signing OFF" whatever the box was configured to do — the one check that exists to protect
# a cut could only ever report the failure state (#1108). MUTATION PROOF: put resolve_signing's body
# back inside that guard and both of the next two go red.
sg="$(signing_decide "$ROOT" "${SGN_OK/DRY_RUN=0/DRY_RUN=1}")"
assert_contains "a dry run rehearses the real decision, not a fixed OFF (#1108)" "$sg" "rc=0"
assert_contains "a dry run reports signing will be ON, not OFF (#1108)" "$sg" "enabled=1"
sg="$(signing_decide "$ROOT" "${SGN_OK/DRY_RUN=0/DRY_RUN=1}; unset COSIGN_KEY")"
assert_contains "a dry run on an unconfigured box fails the rehearsal (#1108)" "$sg" "rc=1"

echo "== unit: release.sh takes the release box's key defaults (#77 phase 1, #1115) =="
# The release box keeps the key and its passphrase at fixed paths under $HOME, so a cut there needs
# no exports — that convenience is what the appliance lane runs on, and losing it in the twin sync
# would have made every v2 cut demand exports nobody has been typing (#1115). apply_signing_defaults
# runs BEFORE signing_env_gaps, so what the gate validates is what the cut will actually use, and it
# only fills in what is unset. MUTATION PROOF: drop the COSIGN_KEY default and "an unset COSIGN_KEY
# falls back" + "the gap names the release box path" go red; drop the passphrase-file read and "the
# passphrase file satisfies COSIGN_PASSWORD" goes red; change `-z ${COSIGN_PASSWORD+x}` to `-z
# ${COSIGN_PASSWORD:-}` and "an empty passphrase is not overwritten" goes red.
DEF="$SANDBOX/signdefaults"
mkdir -p "$DEF/keydir" "$DEF/nokeydir"
: >"$DEF/keydir/cosign.key"
printf 'correct horse\n' >"$DEF/keydir/cosign.passphrase"

signing_defaults() { # <env-assignments> -> "key=<COSIGN_KEY> pass=<value|unset> gaps=<...>"
    (
        _envs="$1" # saved first: release.sh's option parser needs an empty argv, and `set --` eats it
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        eval "$_envs"
        apply_signing_defaults
        printf 'key=%s pass=%s gaps=%s' "${COSIGN_KEY:-}" "${COSIGN_PASSWORD-unset}" "$(signing_env_gaps | tr '\n' ';')"
    )
}

sd="$(signing_defaults "RELEASE_KEY_DIR=$DEF/keydir; unset COSIGN_KEY; unset COSIGN_PASSWORD")"
assert_contains "an unset COSIGN_KEY falls back to the release box's key" "$sd" "key=$DEF/keydir/cosign.key"
assert_contains "the passphrase file satisfies COSIGN_PASSWORD" "$sd" "pass=correct horse"
# Assert on the two variables only: whether cosign itself is on PATH is the test host's business,
# not this function's, and asserting the whole gap list would make this pass or fail by box.
assert_not_contains "the key default leaves no COSIGN_KEY gap" "$sd" "COSIGN_KEY"
assert_not_contains "the passphrase file leaves no COSIGN_PASSWORD gap" "$sd" "COSIGN_PASSWORD"
# An explicit environment always wins — including an explicitly wrong one, which must still abort.
sd="$(signing_defaults "RELEASE_KEY_DIR=$DEF/keydir; COSIGN_KEY=$DEF/elsewhere.key; COSIGN_PASSWORD=typed")"
assert_contains "an explicit COSIGN_KEY beats the default" "$sd" "key=$DEF/elsewhere.key"
assert_contains "an explicit COSIGN_PASSWORD beats the passphrase file" "$sd" "pass=typed"
assert_contains "an explicit key naming no file still aborts the cut" "$sd" "COSIGN_KEY names no file"
# Set-but-empty is a key with no passphrase (see signing_env_gaps) — reading the file over it would
# hand cosign the wrong secret for a key that needs none.
sd="$(signing_defaults "RELEASE_KEY_DIR=$DEF/keydir; unset COSIGN_KEY; COSIGN_PASSWORD=")"
assert_contains "an empty passphrase is not overwritten by the file" "$sd" "pass= "
# Nothing configured anywhere: the gap must name the path the cut looked in, not just "unset".
sd="$(signing_defaults "RELEASE_KEY_DIR=$DEF/nokeydir; unset COSIGN_KEY; unset COSIGN_PASSWORD")"
assert_contains "the gap names the release box path it expected" "$sd" "COSIGN_KEY names no file ($DEF/nokeydir/cosign.key)"
assert_contains "no passphrase file leaves COSIGN_PASSWORD a gap" "$sd" "COSIGN_PASSWORD is unset"
# The appliance's install.sh verifies its download against this manifest line and nothing else until
# cosign exists on the box, so publish() must still emit it (#77 phase 1). The format itself is
# proven against install.sh's parser in the installer test below. MUTATION PROOF: delete the call
# from publish() and this goes red.
assert_contains "publish appends the bundle sha256 to the ingredients manifest" "$(cat "$REL")" \
    'append_bundle_sha256 "$manifest" "$bundle"'

echo "== unit: release.sh validates the pinned verifier image before publish (#1084) =="
# Since #1072 every install verifies its images and its upgrade bundle by running ONE digest-pinned
# cosign container, so that image is the trust root for the whole fleet — and nothing checked it.
# The stack tests around it run against a fake docker (they pass whether the digest is real, typo'd
# or deleted), the tier-4 e2e skips verification on a source checkout, and release-smoke runs after
# the publish, when the assets are immutable. So preflight proves the pin end to end instead.
VER="$SANDBOX/verifier1084"
mkdir -p "$VER/bin" "$VER/box"
printf 'fake release public key\n' >"$VER/box/cosign.pub"
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:d1ge57"  # v2.6.3\n' >"$VER/box/pithead"
# Enough cosign for preflight: it advertises --tlog-upload, and sign-blob writes the blob's sha256 as
# the "signature" so the fake verifier below can genuinely check it rather than return a canned rc.
cat >"$VER/bin/cosign" <<'FAKECOSIGN'
#!/usr/bin/env bash
case "${2:-}" in --help)
    echo "      --tlog-upload   upload to the transparency log"
    exit 0
    ;;
esac
[ "${SIGN_RC:-0}" -eq 0 ] || exit "${SIGN_RC}"
out="" blob=""
while [ $# -gt 0 ]; do
    case "$1" in
    --output-signature)
        out="$2"
        shift
        ;;
    -*) ;;
    *) blob="$1" ;;
    esac
    shift
done
[ -n "$out" ] && [ -n "$blob" ] || exit 1
openssl dgst -sha256 "$blob" | awk '{print $NF}' >"$out"
FAKECOSIGN
# A stand-in for the pinned container. `version` answers the liveness probe; verify-blob does the
# real thing in miniature against the read-only mount, so the tampered-blob leg fails for the right
# reason. VERIFIER_DEAD / VERIFIER_ALWAYS drive the failure modes a bad pin would produce.
cat >"$VER/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
mount=""
for a in "$@"; do case "$a" in *:/w:ro) mount="${a%%:/w:ro}" ;; esac done
case " $* " in *" version "*)
    exit "${VERIFIER_DEAD:-0}"
    ;;
esac
case "${VERIFIER_ALWAYS:-}" in
accept) exit 0 ;;
refuse) exit 1 ;;
esac
[ -n "$mount" ] || exit 1
[ "$(openssl dgst -sha256 "$mount/blob" | awk '{print $NF}')" = "$(cat "$mount/blob.sig")" ]
FAKEDOCKER
chmod +x "$VER/bin/cosign" "$VER/bin/docker"

verifier_check() { # <cwd> <env-assignments>
    (
        cd "$1" || exit
        _envs="$2"
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        eval "$_envs"
        _out="$(check_verifier_image 2>&1)"
        printf 'rc=%s %s' "$?" "$_out"
    )
}
VER_OK="PATH=$VER/bin:\$PATH; COSIGN_ENABLED=1; COSIGN_KEY=$VER/box/cosign.key; DRY_RUN=0"
: >"$VER/box/cosign.key"

# The real tree's pin is what ships, so read it the way preflight will and check its shape.
# shellcheck disable=SC1090
assert_contains "the pin is read out of pithead" \
    "$(cd "$ROOT" && set -- && source "$REL" 2>/dev/null && cosign_image_pin)" "ghcr.io/sigstore/cosign/cosign@sha256:"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a working verifier passes preflight" "$vc" "rc=0"
assert_contains "the pass says the round trip actually ran" "$vc" "refuses a tampered blob"
# A verifier that says yes to everything is the failure a tag (rather than a digest) would let a
# hostile registry serve — it must never read as a pass. MUTATION PROOF: delete the tampered-blob
# leg from check_verifier_image and this goes red.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_ALWAYS=accept")"
assert_contains "a verifier that accepts a tampered blob aborts the cut" "$vc" "rc=1"
assert_contains "the abort says it is not verifying anything" "$vc" "ACCEPTED a tampered blob"
# The mundane realistic failure: a CVE bump, one wrong character, every other test still green.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_DEAD=1")"
assert_contains "an unpullable pin aborts the cut" "$vc" "rc=1"
assert_contains "the abort says installs would fail at the first up" "$vc" "will not run"
# A verifier that refuses a signature this box just made means the committed cosign.pub is no longer
# the public half of COSIGN_KEY — every install would refuse every artifact of the release.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_ALWAYS=refuse")"
assert_contains "a key/cosign.pub mismatch aborts the cut" "$vc" "rc=1"
assert_contains "the abort names the mismatch as a cause" "$vc" "public half"
vc="$(verifier_check "$VER/box" "$VER_OK; export SIGN_RC=1")"
assert_contains "a key that cannot sign aborts the cut before stage 6b" "$vc" "rc=1"
# A tag would let a hostile registry serve a cosign that exits 0 on everything.
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v2.6.3"\n' >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a verifier pinned by tag rather than digest aborts the cut" "$vc" "rc=1"
assert_contains "the abort explains what a tag would allow" "$vc" "exits 0 on everything"
: >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a pin that cannot be read at all aborts the cut" "$vc" "rc=1"
# With signing off there is no signature to prove the verifier against — say so, do not imply a pass.
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:d1ge57"\n' >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "${VER_OK/COSIGN_ENABLED=1/COSIGN_ENABLED=0}")"
assert_contains "signing off still proves the pin pulls and runs" "$vc" "rc=0"
assert_contains "signing off says the round trip was skipped" "$vc" "round trip was skipped"
