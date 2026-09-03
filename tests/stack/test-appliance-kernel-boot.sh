# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance kernel and OS-image build domain (#1105 Phase 1, develop-v2 lane): the guards that
# stand between a build host and a slot the fleet would be wrong to trust. optimize_kernel's
# HugePages write is grow-only, because with a co-located miner the pool has a single writer that
# sizes it upward, and pithead writing its own absolute figure on top would shrink a grown pool to
# the in-use floor and starve whichever side restarts next; the degrade cap (#977) is proven with
# it. The os/rauc stale-tarball guard covers the failure where a present-but-stale
# os/build/pithead-root.tar is indistinguishable from a fresh one to a size test — a bench deploy
# once bundled a leftover tarball and every downstream check came up green with the old code still
# running — so verify_tarball_commit reads the tarball's own BUILD_COMMIT stamp and compares it to
# the working tree. mkbundle's compatibility-metadata validation refuses a malformed data-migration
# field, and a missing or non-semver migration floor, before the multi-minute image build rather
# than after it. Last, resolve_signing_material: a release build must name its signing key, and
# only an explicitly-marked --dev build may auto-generate a throwaway, so that a dev cert a build
# host happened to have lying around can never become the fleet's update trust root. All of it is
# proven at the shell-unit tier — sourced and called directly, no docker and no loop image build.
# Sourced by tests/stack/run.sh.
#
# THIS CUT REORDERED, by one section, and the reason is worth recording. In run.sh as it stood at
# the cut, this domain's sections were not contiguous: the source stanzas for the os-update and
# os-update-verbs domain files sat between the HugePages section and the RAUC/mkbundle/signing
# block. Those stanzas stayed where they were. Moving them would have nested two domain files
# inside this one, and a nested stanza reassigns the same _d0 that the outer stanza passes to
# domain_ran — which would have narrowed this file's zero-assertion guard (#1400) to cover only
# the part of the file running after the nesting, silently, with the suite still green and the
# moved text still byte-identical. So the cut took two ranges and left those stanzas out of both,
# and the source stanza was placed at the RAUC/mkbundle/signing block's former position, keeping
# the larger part of the domain exactly where it ran before. The HugePages section is the one that
# moved: it now runs after the os-update and os-update-verbs domains instead of before them.
#
# Why that is safe, argued rather than asserted, in both directions. Nothing can be inherited FROM
# the HugePages section by the domains it now follows: it builds its whole world inside a private
# mktemp sandbox, and unsets every variable and function it defined — the sandbox, the call log and
# the runner — as its own section ends, leaving nothing for them to read. And it inherits nothing
# FROM them: the only names it reads without assigning are $ROOT and $STACK, and the assertion
# helpers it calls — variables and functions alike coming from tests/stack/lib.sh, which is sourced
# before any domain file is, so neither of the two domains it now follows supplies any of them.
# It reaches optimize_kernel by sourcing
# $STACK inside a subshell rather than by relying on an earlier section having done so.
#
# Ambient contract. This file reads $ROOT and $STACK from lib.sh and calls lib.sh's assertion
# helpers. It reads no $WALLET and none of the control-sandbox globals, so it carries no self-arm
# stanza and no seed lines: the moved text is byte-identical to what it replaced, with nothing
# authored inside it. RAUC_CERT, RAUC_KEY and RAUC_KEYRING are read only through ${..:-} defaults
# and are outputs of the resolver under test, so they cannot trip set -u either. lib.sh alone is
# therefore the whole of this file's contract, and that is measured rather than asserted: sourcing
# lib.sh and then this file under set -u, with no run.sh in the picture, runs the domain to
# completion with no failures. Sourcing it WITHOUT lib.sh records no assertion at all: every helper
# is command-not-found from the first section onward, and the run ends non-zero.
# Note what it does NOT do — it does not halt at the first error. This file sets no -e, and the
# $ROOT reads that set -u does object to sit inside subshells, so the failure kills the subshell and
# the parent keeps going to the end. The negative half is what makes the positive half a test rather
# than a claim, and it discriminates on whether any assertion ran at all, not on where it stopped.
echo "== unit: optimize_kernel's HugePages write is grow-only =="
# With a co-located miner the pool is shared and RigForge (grow-only by design) sizes it as the
# single writer — pithead writing its absolute 3072 on top would shrink a grown pool to the
# in-use floor and starve whichever side restarts next.
mk_tmpdir OKSB
mkdir -p "$OKSB/bin"
printf '#!/usr/bin/env bash\necho "sudo:$*" >>"${OKLOG:?}"\n' >"$OKSB/bin/sudo"
# OS_TYPE is readonly once sourced, so the Linux arm is selected the way pcr791 does it: a
# stubbed uname on PATH before the source.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec /usr/bin/uname "$@"\n' >"$OKSB/bin/uname"
chmod +x "$OKSB/bin/sudo" "$OKSB/bin/uname"
export OKLOG="$OKSB/calls"
okrun() { # <pages currently in the pool> [degrade-marker file]
    printf '%s\n' "$1" >"$OKSB/nr"
    (
        cd "$OKSB" || exit
        PATH="$OKSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        PITHEAD_NR_HUGEPAGES_FILE="$OKSB/nr" PITHEAD_HUGEPAGES_MARKER="${2:-$OKSB/no-marker}" \
            optimize_kernel </dev/null
    )
}
: >"$OKLOG"
okrun 100 >/dev/null 2>&1
assert_contains "a small pool is grown to the stack's budget" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=3072"
: >"$OKLOG"
okrun 4000 >/dev/null 2>&1
assert_not_contains "a larger pool (the miner's merged budget) is never shrunk" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 3072 >/dev/null 2>&1
assert_not_contains "an exact pool is left alone" "$(cat "$OKLOG")" "vm.nr_hugepages"
# The degrade cap (#977): the boot-time sizing's marker records the chosen page count, and that
# record caps the grow. Without it the wizard-accept path (setup runs as root on the appliance)
# re-inflated the pool the sizing had just shrunk, while the marker and doctor kept saying
# "reduced". A pool at the recorded size is left alone; one below it grows only to the record.
printf 'reduced-reservation words for the operator\npages=2560\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 2560 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a marker-sized pool is never re-inflated to the full budget" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 100 "$OKSB/marker" >/dev/null 2>&1
assert_contains "a pool below the record grows to the record" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=2560"
assert_not_contains "the grow never passes the marker's cap" "$(cat "$OKLOG")" "3072"
printf 'released-reservation words\npages=0\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 0 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a released (0-page) decision writes nothing at all" "$(cat "$OKLOG")" "vm.nr_hugepages"
unset OKLOG
unset -f okrun
rm -rf "$OKSB"
unset OKSB

# --- os/rauc stale-tarball guard (verify_tarball_commit in populate-slot.sh). A present-but-stale
# os/build/pithead-root.tar looks identical to a fresh one to `[ -s ]` — a bench deploy once
# bundled a leftover tarball from a previous session and every downstream check came up green with
# the old code running. The guard extracts the tarball's own opt/pithead/BUILD_COMMIT stamp and
# compares it to the working tree, proven here with a fabricated fixture tarball (no image build).
echo "== unit: os/rauc stale-tarball guard =="
mk_tmpdir VTC_TMP
# The same commit+dirty-suffix computation verify_tarball_commit does, so the "match" fixture is
# honest about the state of THIS working tree (it may itself be dirty mid-change).
VTC_HEAD_SHA=$(cd "$ROOT" && git rev-parse HEAD)
VTC_HEAD="$VTC_HEAD_SHA"
(cd "$ROOT" && git diff --quiet) || VTC_HEAD="${VTC_HEAD_SHA}-dirty"

# Build a fixture tarball with the single member the guard reads: opt/pithead/BUILD_COMMIT.
# $2=NONE fabricates a tarball with the directory but no stamp file (an old/broken build).
mk_vtc_fixture() { # $1=out-path $2=stamp-content|NONE
    local d
    mk_tmpdir d
    mkdir -p "$d/opt/pithead"
    [ "$2" = NONE ] || printf '%s\n' "$2" >"$d/opt/pithead/BUILD_COMMIT"
    tar -cf "$1" -C "$d" opt
    rm -rf "$d"
}
vtc() { # $1=tarball -> prints "rc=<n>"; stderr goes to $VTC_TMP/err
    (
        cd "$ROOT" || exit
        # shellcheck disable=SC1090
        . os/rauc/populate-slot.sh
        set +e
        verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}

mk_vtc_fixture "$VTC_TMP/fresh.tar" "$VTC_HEAD"
assert_eq "a tarball stamped with the current HEAD is accepted" "$(vtc "$VTC_TMP/fresh.tar")" "rc=0"

mk_vtc_fixture "$VTC_TMP/stale.tar" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
out=$(vtc "$VTC_TMP/stale.tar")
assert_eq "a tarball stamped with a foreign commit is refused" "$out" "rc=2"
err="$(cat "$VTC_TMP/err")"
assert_contains "the refusal names the tarball's stamped commit" "$err" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
assert_contains "the refusal names the working tree's commit" "$err" "$VTC_HEAD_SHA"
assert_contains "the refusal points at the override env var" "$err" "PITHEAD_STALE_TARBALL_OK"

out=$(PITHEAD_STALE_TARBALL_OK=1 vtc "$VTC_TMP/stale.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides a stale-commit refusal" "$out" "rc=0"

mk_vtc_fixture "$VTC_TMP/nostamp.tar" NONE
out=$(vtc "$VTC_TMP/nostamp.tar")
assert_eq "a tarball with no BUILD_COMMIT stamp is refused" "$out" "rc=2"
assert_contains "the refusal says no stamp was found" "$(cat "$VTC_TMP/err")" "no BUILD_COMMIT stamp"

# A checkout git cannot read (sudo on another user's tree, once the SUDO_USER fallback also
# fails) must refuse rather than silently skip the freshness check — fail closed, with the
# same explicit escape. Run from a non-repo dir with the fallback neutralized to simulate it.
vtc_norepo() { # $1=tarball -> prints "rc=<n>"; stderr to $VTC_TMP/err
    (
        cd "$VTC_TMP" || exit
        # shellcheck disable=SC1091
        . "$ROOT/os/rauc/populate-slot.sh"
        set +e
        SUDO_USER="" GIT_DIR="$VTC_TMP/no-such-repo" verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}
out=$(vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "an unreadable working tree refuses (fail closed, never skip)" "$out" "rc=2"
assert_contains "the refusal explains git could not be read" "$(cat "$VTC_TMP/err")" "cannot read the working tree's commit"
out=$(PITHEAD_STALE_TARBALL_OK=1 vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides the unreadable-tree refusal" "$out" "rc=0"

rm -rf "$VTC_TMP"
unset -f mk_vtc_fixture vtc vtc_norepo
unset VTC_TMP VTC_HEAD_SHA VTC_HEAD

# --- mkbundle metadata validation (fails fast, before the multi-minute image build) ---
echo "== unit: mkbundle compatibility-metadata validation =="
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=maybe bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "PITHEAD_DATA_MIGRATION must be true/false" "$?" "2"
assert_contains "the message names the field" "$out" "PITHEAD_DATA_MIGRATION"
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=true bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "data_migration=true without a floor is refused" "$?" "2"
assert_contains "the message asks for the migration floor" "$out" "PITHEAD_MIN_OS_VERSION"
out=$(cd "$ROOT" && PITHEAD_MIN_OS_VERSION=1.2 bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "a non-semver floor is refused" "$?" "2"
assert_contains "the message names the floor field" "$out" "PITHEAD_MIN_OS_VERSION"

# ---------------------------------------------------------------------------
# os/rauc signing-material guard (resolve_signing_material in populate-slot.sh). A release build
# must name the signing key; only an explicitly-marked --dev build auto-generates a throwaway. The
# refuse logic is proven here at the shell-unit tier — sourced and called directly, no docker/loop
# image build. The guard is the safety fix: a dev cert must never become the fleet's update trust
# root because a build host happened to have one lying around.
RSM="$ROOT/os/rauc/populate-slot.sh"
mk_tmpdir RSMTMP
# Run the resolver in an isolated cwd (it writes os/rauc/certs/ relative to $PWD). $1=dev(0/1),
# $2=where to send stderr. Prints: rc=<n> cert=<..> key=<..> keyring=<..>
rsm() {
    local dev="$1" errto="$2" d
    mk_tmpdir d
    (
        cd "$d" || exit
        # shellcheck disable=SC1090
        . "$RSM"
        set +e
        resolve_signing_material "$dev" 2>"$errto"
        printf ' rc=%s cert=%s key=%s keyring=%s\n' "$?" "${RAUC_CERT:-}" "${RAUC_KEY:-}" "${RAUC_KEYRING:-}"
    )
    rm -rf "$d"
}
rsm_field() { echo "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

# Release build (dev=0), no key named -> refuses, non-zero, names the env vars and --dev.
res=$(
    unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "release build with no signing key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"
assert_contains "refusal names the release key env vars" "$(cat "$RSMTMP/err")" "PITHEAD_RAUC_CERT"
assert_contains "refusal points at --dev for a throwaway key" "$(cat "$RSMTMP/err")" "--dev"

# Explicit key (dev=0) -> accepted; keyring defaults to the signing cert. Content is irrelevant to
# the guard (it checks readability, not validity), so dummy files exercise the branch openssl-free.
printf 'cert\n' >"$RSMTMP/rel-cert.pem"
printf 'key\n' >"$RSMTMP/rel-key.pem"
res=$(
    PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem"
    export PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY
    unset PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "explicit release key is accepted (rc 0)" "$(rsm_field "$res" rc)" "0"
assert_eq "the named cert is used for signing" "$(rsm_field "$res" cert)" "$RSMTMP/rel-cert.pem"
assert_eq "keyring defaults to the signing cert" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-cert.pem"

# Explicit keyring overrides the baked trust anchor (root+leaf: root baked, leaf signs).
printf 'root\n' >"$RSMTMP/rel-root.pem"
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem" PITHEAD_RAUC_KEYRING="$RSMTMP/rel-root.pem"
    rsm 0 "$RSMTMP/err"
)
assert_eq "PITHEAD_RAUC_KEYRING is what gets baked" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-root.pem"

# A cert with no matching key is rejected — both halves are required.
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem"
    unset PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "cert without key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"

# Dev build (dev=1) still auto-generates a throwaway — the local/bench loop is preserved.
if command -v openssl >/dev/null 2>&1; then
    res=$(
        unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
        rsm 1 "$RSMTMP/err"
    )
    assert_eq "dev build auto-generates and succeeds (rc 0)" "$(rsm_field "$res" rc)" "0"
    assert_contains "dev key lands in os/rauc/certs" "$(rsm_field "$res" key)" "os/rauc/certs/key.pem"
else
    ok "dev auto-gen skipped (no openssl on this host)"
fi
rm -rf "$RSMTMP"
unset RSM RSMTMP
unset -f rsm rsm_field
