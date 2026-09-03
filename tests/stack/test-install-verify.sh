# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# install.sh verification domain (#1105 Phase 1, develop-v2 lane): everything the installer does
# before it will put a bundle on a box. The host gate that hard-fails on a platform the stack
# cannot run on, before any download at all (#77 phase 1), and the download-verification path that
# fails CLOSED — a bad sha, a bad signature, a missing key, an occupied target or a corrupt archive
# each refuse the install rather than degrade to trusting HTTPS alone (#868, #1115).
#
# The two sections are one domain and are kept in one file deliberately: the gate decides whether
# an install may start and the verification decides whether it may finish, and a regression that
# moved a check from one to the other would otherwise straddle two files.
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $REL is SEEDED here, and that is the substantive change in this file. It is read to source
#   release.sh for append_bundle_sha256(), which builds the sha manifest the verified-install case
#   needs. Nothing in this domain assigns it: in run.sh it arrived ambiently, because the release
#   and release-signing domains happen to be sourced earlier and each set it for their own reasons.
#   That is an ordering accident, not a dependency this domain declares — sourcing in place
#   preserves it, so the suite is green either way and byte-identity, header order and pass totals
#   are all blind to it by construction. Seeded with the same value its assigners already use,
#   so the sourced-in-place behaviour is unchanged and the file no longer depends on a neighbour
#   having run.
# - $ROOT and $SANDBOX are lib.sh top-level globals, as are the assertion helpers this domain calls
#   (assert_eq, assert_rc, assert_contains, and ok/bad beneath them). $PATH is the environment's.
# - append_bundle_sha256() is release.sh's, reached only through the $REL source above, inside a
#   subshell so it never leaks into this file's own shell.
# - irun() is defined and unset within the moved block; it does not escape this file.
# - This domain never touches $V, seed_env(), $C or the results dir, and writes no ambient .env or
#   Caddyfile, so it needs no sandbox self-arm and carries neither coupling rule.
REL="$ROOT/scripts/release.sh"

echo "== unit: install.sh host gate (#77 phase 1) =="
# The installer hard-fails on the platforms the stack cannot run on, before any download.
IBIN="$SANDBOX/install-stub-bin"
mkdir -p "$IBIN"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo aarch64 ;; esac\n' >"$IBIN/uname"
chmod +x "$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-amd64" "$out" "x86_64-only"
printf '#!/bin/bash\ncase "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; esac\n' >"$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-Linux" "$out" "runs on Linux"

echo "== unit: install.sh download verification fails CLOSED (#868) =="
# The two security-critical branches of the public curl installer: the bundle sha256 against the
# release manifest, and the cosign signature against the repo-pinned key. This is the path a new
# operator runs BEFORE any of the bundle's own defenses exist — a tampered bundle that gets
# extracted has already won — so a mismatch must install NOTHING. The stubs model each remote
# artifact as a file served by basename; absent file = curl -f failure, exactly the shape the
# script distinguishes (absent degrades politely, present-but-wrong is fatal).
ISB=$(mktemp -d)
mkdir -p "$ISB/bin" "$ISB/srv" "$ISB/work"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' >"$ISB/bin/uname"
cat >"$ISB/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o)
        out="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *) shift ;;
    esac
done
src="$CURL_SRV/$(basename "$url")"
[ -f "$src" ] || exit 22
[ -n "$out" ] && cp "$src" "$out"
exit 0
EOF
# macOS has no sha256sum; shasum -a 256 prints the identical "hash  file" shape.
printf '#!/bin/bash\nif command -v /usr/bin/sha256sum >/dev/null; then exec /usr/bin/sha256sum "$@"; fi\nexec shasum -a 256 "$@"\n' >"$ISB/bin/sha256sum"
printf '#!/bin/bash\nexit "${COSIGN_RC:-0}"\n' >"$ISB/bin/cosign"
chmod +x "$ISB/bin/"*
# A canned release bundle whose pithead stub proves the handoff (install.sh exec's it).
mkdir -p "$ISB/bundle-src/pithead-x"
printf '#!/bin/bash\necho "SETUP-REACHED $*"\n' >"$ISB/bundle-src/pithead-x/pithead"
chmod +x "$ISB/bundle-src/pithead-x/pithead"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/bundle-src" pithead-x
# One invocation per scenario; PATH keeps the stubs first, cosign joins only where a test wants it.
irun() { # <dest-subdir> [env overrides via preceding assignments]
    (
        cd "$ISB/work" || exit
        CURL_SRV="$ISB/srv" PITHEAD_VERSION=v9.9.9 PITHEAD_ALLOW_ANY_DISTRO=1 \
            PITHEAD_DIR="$ISB/work/$1" PATH="$ISB/bin:$PATH" bash "$ROOT/install.sh" 2>&1
    )
}

# sha256 verified against the manifest: match proceeds to the handoff, mismatch installs NOTHING.
# The manifest line is written by release.sh's OWN producer, not a hand-copied format: this grep is
# the only integrity check a fresh install has before cosign exists on the box, and the two sides
# drifting apart would leave every appliance install silently trusting HTTPS alone (#77 phase 1,
# #1115). MUTATION PROOF: drop the backticks from append_bundle_sha256's format and "sha256 match is
# announced" goes red — install.sh finds no sha, degrades to HTTPS trust and installs anyway, which
# is the actual damage: a silent downgrade, not a visible failure.
: >"$ISB/srv/ingredients-v9.9.9.md" # it appends; write_manifest has run by then in a real cut
# shellcheck disable=SC1090
(set -- && PATH="$ISB/bin:$PATH" && source "$REL" 2>/dev/null && set +eu &&
    append_bundle_sha256 "$ISB/srv/ingredients-v9.9.9.md" "$ISB/srv/pithead.tar.gz")
out=$(irun ok-sha)
assert_rc "verified install runs to the setup handoff" "$?" "0"
assert_contains "sha256 match is announced" "$out" "sha256 verified"
assert_contains "the extracted pithead was exec'd" "$out" "SETUP-REACHED"
printf 'bundle sha256: `%s`\n' "$(printf 'a%.0s' $(seq 64))" >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun bad-sha) && rc=0 || rc=$?
assert_rc "sha256 mismatch refuses to install" "$rc" "1"
assert_contains "the mismatch names both digests' verdict" "$out" "sha256 mismatch"
assert_eq "nothing was installed on a sha256 mismatch" "$([ -e "$ISB/work/bad-sha" ] && echo present || echo absent)" "absent"
# A manifest with no sha line (pre-v1.15) and a missing manifest both degrade politely.
printf 'no digest here\n' >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-sha-line)
assert_contains "manifest without a sha degrades to HTTPS trust" "$out" "carries no bundle sha256"
rm -f "$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-manifest)
assert_contains "missing manifest degrades to HTTPS trust" "$out" "No release manifest"

# cosign: a present-but-bad signature is FATAL; an absent one is a note; a signature whose
# pinned key cannot be fetched is fatal too (the cross-channel check cannot be half-done).
touch "$ISB/srv/pithead.tar.gz.sig" "$ISB/srv/cosign.pub"
out=$(irun sig-ok)
assert_rc "good signature installs" "$?" "0"
assert_contains "signature verification is announced" "$out" "signature verified"
out=$(COSIGN_RC=1 irun sig-bad) && rc=0 || rc=$?
assert_rc "bad signature refuses to install" "$rc" "1"
assert_contains "the failure names the signature" "$out" "signature verification FAILED"
assert_eq "nothing was installed on a bad signature" "$([ -e "$ISB/work/sig-bad" ] && echo present || echo absent)" "absent"
rm -f "$ISB/srv/cosign.pub"
out=$(irun sig-nokey) && rc=0 || rc=$?
assert_rc "signature without a fetchable pinned key refuses" "$rc" "1"
assert_contains "the failure names the pinned key" "$out" "pinned key could not be fetched"
rm -f "$ISB/srv/pithead.tar.gz.sig"
out=$(irun sig-absent)
assert_contains "absent signature is noted, not fatal" "$out" "No bundle signature"

# The remaining guards on the same path: an occupied target refuses before downloading, and a
# bundle with no pithead executable refuses after extraction.
mkdir -p "$ISB/work/taken"
out=$(irun taken) && rc=0 || rc=$?
assert_rc "an existing target dir refuses" "$rc" "1"
assert_contains "the refusal names the dir" "$out" "already exists"
mkdir -p "$ISB/empty/pithead-x" && touch "$ISB/empty/pithead-x/README"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/empty" pithead-x
out=$(irun corrupt) && rc=0 || rc=$?
assert_rc "a bundle without a pithead executable refuses" "$rc" "1"
assert_contains "the refusal suspects corruption" "$out" "no pithead executable"
rm -rf "$ISB"
unset -f irun
