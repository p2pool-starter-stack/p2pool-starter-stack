#!/usr/bin/env bash
# Everything that makes an unpacked rootfs into a bootable pithead slot.
#
# Sourced by BOTH mkimage.sh (initial slot A) and mkbundle.sh (the slot image inside an update
# bundle). It exists because those two started out as separate copies of the same steps and drifted:
# the bundle never wrote /etc/fstab, so slot B came up with a read-only root and no writable /var
# and could not boot. RAUC installed it perfectly and GRUB selected it correctly — the slot itself
# was simply unbootable. Anything a slot needs goes here, once, or the two paths drift again.
#
# Rugix needs no equivalent: its bakery builds the image and the bundle from one layer definition,
# so there is no second copy to keep in sync.

# Resolve the RAUC signing material into RAUC_CERT / RAUC_KEY, and decide whether auto-generating a
# throwaway is allowed. Both mkimage.sh and mkbundle.sh route through here so the rule is enforced
# once: the cert this returns becomes the device trust root (mkimage bakes it as the keyring) and
# the key signs update bundles (mkbundle). Getting it wrong ships a fleet whose update trust root
# is a throwaway dev key with no offline backup and no revocation — so the guard, not human memory
# of a runbook, is what separates a release key from whatever cert happens to sit on the build host.
#
#   $1 = 1 for an explicitly-marked dev/bench build (auto-generation allowed), 0 otherwise.
#
# A release build (the default, $1=0) MUST name the signing key explicitly: PITHEAD_RAUC_CERT +
# PITHEAD_RAUC_KEY. A dev build with no key named auto-generates a clearly-labelled CN=pithead-dev
# throwaway into os/rauc/certs/ (chmod 600 key, 700 dir). The two paths never cross — a release
# build refuses to run without an explicit key, so a dev cert can never silently become the fleet's
# update trust root. Custody of the real release key: docs/dev/release-server.md.
#
# Trust anchor vs. signer are separate axes. RAUC_KEYRING is the cert(s) baked into every slot as
# the device trust anchor; RAUC_CERT/RAUC_KEY are the leaf that signs the bundle. For a root+leaf
# release, set PITHEAD_RAUC_KEYRING to the root (or old+new roots concatenated during a rotation)
# and PITHEAD_RAUC_CERT to the leaf chain. It defaults to the signing cert, which is the single
# self-signed cert the dev model uses.
resolve_signing_material() { # $1 = dev(1/0); sets RAUC_CERT, RAUC_KEY, RAUC_KEYRING
    local dev="${1:-0}"
    local certdir="os/rauc/certs"

    if [ -n "${PITHEAD_RAUC_CERT:-}" ] || [ -n "${PITHEAD_RAUC_KEY:-}" ]; then
        # An explicit key was named: the release path. Both halves are required and readable.
        RAUC_CERT="${PITHEAD_RAUC_CERT:-}"
        RAUC_KEY="${PITHEAD_RAUC_KEY:-}"
        [ -s "$RAUC_CERT" ] && [ -s "$RAUC_KEY" ] || {
            echo "PITHEAD_RAUC_CERT and PITHEAD_RAUC_KEY must both point at readable files" >&2
            return 2
        }
    elif [ "$dev" != 1 ]; then
        # No explicit key and not a dev build: stop loudly, never auto-generate.
        echo "refusing to build without a signing key: set PITHEAD_RAUC_CERT + PITHEAD_RAUC_KEY to" \
            "the release key (custody: docs/dev/release-server.md), or pass --dev to auto-generate a" \
            "throwaway development key" >&2
        return 2
    else
        # Dev/bench build: auto-generate a labelled throwaway, reusing one already on the box.
        RAUC_CERT="$certdir/cert.pem"
        RAUC_KEY="$certdir/key.pem"
        mkdir -p "$certdir"
        chmod 700 "$certdir"
        if [ ! -s "$RAUC_CERT" ]; then
            echo "==> DEV BUILD: generating a throwaway CN=pithead-dev signing key (never a release trust root)"
            openssl req -x509 -newkey rsa:4096 -nodes -keyout "$RAUC_KEY" \
                -out "$RAUC_CERT" -days 3650 -subj "/CN=pithead-dev" 2>/dev/null
        fi
        chmod 600 "$RAUC_KEY"
    fi

    RAUC_KEYRING="${PITHEAD_RAUC_KEYRING:-$RAUC_CERT}"
    [ -s "$RAUC_KEYRING" ] || {
        echo "PITHEAD_RAUC_KEYRING must point at a readable cert file" >&2
        return 2
    }
    return 0
}

# The bundle manifest, rendered from the compatibility inputs so it can be tested without a
# multi-minute image build. RAUC refuses a key with an empty value ("Missing value for key
# 'minimum_os_version'"), so the migration floor is emitted ONLY when the release declares one —
# emitting it unconditionally broke every ordinary, non-migrating build.
render_bundle_manifest() { # $1 os_version, $2 variant, $3 data_migration, $4 minimum_os_version
    printf '[update]\ncompatible=pithead-amd64\nversion=%s\n\n' "$1"
    printf '[meta.pithead]\nvariant=%s\nversion=%s\ndata_migration=%s\n' "$2" "$1" "$3"
    [ -n "$4" ] && printf 'minimum_os_version=%s\n' "$4"
    printf '\n[image.rootfs]\nfilename=rootfs.ext4\n'
}

# Refuse a present-but-stale rootfs tarball. A bench deploy once bundled the PREVIOUS session's
# leftover os/build/pithead-root.tar — mkbundle's only guard was `[ -s ]`, existence, not freshness
# — and RAUC installed it, the appliance booted it, every service came up green, and only a manual
# /opt/pithead/BUILD_COMMIT check on the box caught that the fix under test was never on it. The
# tarball already carries that same stamp (written by build-image.sh from the tree it built), so
# compare it against the working tree instead of trusting that a stale artifact looks fine.
#
#   $1 = tarball path
#
# Both mkimage.sh and mkbundle.sh consume the SAME tarball, so the check lives here once rather
# than drifting between two copies. Fail-closed like the version/variant/signing guards above:
# mismatch (or a dirty-tree stamp the tree has since moved past) refuses by default, naming both
# commits, with PITHEAD_STALE_TARBALL_OK=1 as the explicit escape for a deliberate stale rebuild.
verify_tarball_commit() {
    local tarball="$1" stamped head
    stamped=$(tar -xOf "$tarball" opt/pithead/BUILD_COMMIT 2>/dev/null) || stamped=""
    [ -n "$stamped" ] || stamped="(no BUILD_COMMIT stamp in the tarball)"

    if ! head=$(_working_tree_commit); then
        if [ "${PITHEAD_STALE_TARBALL_OK:-0}" = 1 ]; then
            echo "==> PITHEAD_STALE_TARBALL_OK=1: proceeding with $tarball (stamped $stamped) though the working tree's commit cannot be read" >&2
            return 0
        fi
        echo "refusing $tarball: cannot read the working tree's commit to check the tarball's" \
            "freshness against it (git failed — under sudo, root may refuse another user's" \
            "checkout). Run from the checkout's owner, or set PITHEAD_STALE_TARBALL_OK=1 to" \
            "skip the freshness check" >&2
        return 2
    fi

    if [ "$stamped" = "$head" ]; then
        return 0
    fi
    if [ "${PITHEAD_STALE_TARBALL_OK:-0}" = 1 ]; then
        echo "==> PITHEAD_STALE_TARBALL_OK=1: proceeding with $tarball (stamped $stamped) while the working tree is at $head" >&2
        return 0
    fi
    echo "refusing to use a stale rootfs tarball: $tarball was built from commit $stamped but the" \
        "working tree is now at $head — rerun os/build-image.sh, or set PITHEAD_STALE_TARBALL_OK=1" \
        "to use it anyway" >&2
    return 2
}

# The working tree's commit, with build-image.sh's exact -dirty suffix. These scripts normally run
# under sudo, and root's git refuses to read another user's checkout ("dubious ownership") — and
# `git -c safe.directory=` is documented as ignored from the command line — so on failure ask
# again as the invoking user. Without this the guard would refuse EVERY sudo build on a
# user-owned checkout, which is exactly the flow the stale-tarball incident happened on.
_working_tree_commit() {
    local h
    if h=$(git rev-parse HEAD 2>/dev/null); then
        git diff --quiet 2>/dev/null || h="${h}-dirty"
        printf '%s\n' "$h"
        return 0
    fi
    if [ -n "${SUDO_USER:-}" ]; then
        if h=$(sudo -u "$SUDO_USER" git rev-parse HEAD 2>/dev/null); then
            sudo -u "$SUDO_USER" git diff --quiet 2>/dev/null || h="${h}-dirty"
            printf '%s\n' "$h"
            return 0
        fi
    fi
    return 1
}

populate_slot() { # $1 = mounted rootfs
    local root="$1"

    # docker-export artefacts: systemd refuses to run as PID 1 with /.dockerenv present, the
    # export omits the pseudo-filesystem mount points entirely, and /etc/hosts + /etc/resolv.conf
    # are BIND MOUNTS inside docker — unwritable during the build and exported as empty stubs.
    # Without real ones the OS cannot resolve even localhost, and glibc's fallback sends DNS to
    # [::1]:53; the first symptom is image pulls failing while everything else looks healthy.
    rm -f "$root/.dockerenv"
    mkdir -p "$root"/{dev,proc,sys,run,tmp,data,boot/efi}
    {
        echo '127.0.0.1 localhost'
        echo '127.0.1.1 pithead'
        echo '::1 localhost ip6-localhost ip6-loopback'
    } >"$root/etc/hosts"
    ln -sf ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
    # /etc/hostname is the FOURTH bind-mount artefact: docker overlays it per container, so the
    # rootfs Dockerfile's write never left the build. The machine then calls itself "localhost",
    # avahi publishes localhost.local, and caddy renders a site nobody can reach.
    echo 'pithead' >"$root/etc/hostname"

    # Writable state, declared explicitly because the root is READ-ONLY. That is the point of the
    # appliance: the stack cannot be mutated at runtime, only replaced wholesale by an update.
    #   /data — operator state (config, wallets, chains, container storage), survives updates
    #   /var  — machine state (logs, runtime), an OVERLAY so the new slot's /var shows through
    #           after an update while local machine state persists. A bind mount would pin the old
    #           slot's /var forever; the overlay keeps the stack fresh and the state local.
    # RAUC has no persist/state model, so this is ours to own. Rugix declares it in two lines of
    # [[persist]] and keeps an /etc overlay on the data partition besides.
    # /data and /boot/efi are NOT here: pithead-mount-generator derives them from the disk the
    # system actually booted from, because every pithead disk carries the same labels by design
    # and LABEL= picks whichever udev saw last when two are present. Only the /var overlay is
    # static — it names paths, not devices, so it cannot pick a wrong disk.
    cat >>"$root/etc/fstab" <<'FSTAB'
overlay /var overlay lowerdir=/var,upperdir=/data/overlay/var,workdir=/data/overlay/var-work,x-systemd.requires-mounts-for=/data 0 0
FSTAB

    install -D -m 644 os/rauc/system.conf "$root/etc/rauc/system.conf"
    # The keyring is the device's update trust anchor. resolve_signing_material must have run first
    # (both callers do) so this bakes the resolved keyring — the root for a root+leaf release, or
    # the single dev cert — not a hardcoded path.
    install -D -m 644 "$RAUC_KEYRING" "$root/etc/rauc/keyring.pem"
}
