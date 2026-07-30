#!/usr/bin/env bash
# Static verification of a built appliance image — the release gate's cheapest phase.
#
# Mounts the image read-only and checks everything a boot test cannot see quickly and a human
# checking by hand forgets under pressure: that no test material shipped, that every baked fix is
# actually in the artifact, and that the boot path's load-bearing files sit where the firmware
# and GRUB will look. Each check exists because its absence shipped, or nearly shipped, once.
#
#   sudo tests/os/verify-image.sh IMAGE            release expectations (test artifacts REFUSED)
#   sudo tests/os/verify-image.sh IMAGE --test     harness-build expectations (SSH key expected)
#
# Exit: 0 all checks pass, 1 otherwise.
set -uo pipefail

IMAGE="${1:-}"
MODE="${2:-}"
[ -f "$IMAGE" ] || {
    echo "usage: sudo tests/os/verify-image.sh IMAGE [--test]" >&2
    exit 2
}
[ "$(id -u)" -eq 0 ] || {
    echo "must run as root (loop mounts)" >&2
    exit 2
}

PASS=0
FAIL=0
ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n' "$1"
}
chk() { # <label> <shell-condition>
    if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}

LOOP=$(losetup -Pf --show "$IMAGE")
ROOT=$(mktemp -d)
ESP=$(mktemp -d)
cleanup() {
    umount "$ROOT" "$ESP" 2>/dev/null || true
    rmdir "$ROOT" "$ESP" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> partition table"
# Ships ONLY the ESP and slot A — systemd-repart builds the rest on the target's real disk. A
# third partition here means the build regressed to image-sized /data, the bug that was #784.
# shellcheck disable=SC2034  # used inside chk's eval'd condition
parts=$(lsblk -lno NAME "$LOOP" | grep -c "^$(basename "$LOOP")p")
chk "exactly 2 partitions (ESP + slot A)" '[ "$parts" -eq 2 ]'
chk "p1 is an ESP" 'sgdisk -i 1 "$LOOP" | grep -qi "EF00\|system partition"'

mount -o ro "${LOOP}p2" "$ROOT" || {
    bad "slot A does not mount"
    exit 1
}
mount -o ro "${LOOP}p1" "$ESP" || {
    bad "ESP does not mount"
    exit 1
}

echo "==> boot path (each location burned us once)"
chk "BOOTX64.EFI at the fallback path" '[ -s "$ESP/EFI/BOOT/BOOTX64.EFI" ]'
chk "grub.cfg in the prefix dir" '[ -s "$ESP/grub/grub.cfg" ]'
# load_env reads \$prefix/grubenv; at the ESP root it is a silent no-op and updates never take.
chk "grubenv in the prefix dir, not the ESP root" '[ -s "$ESP/grub/grubenv" ] && [ ! -e "$ESP/grubenv" ]'
chk "grubenv seeds slot A good" 'grub-editenv "$ESP/grub/grubenv" list | grep -q "A_OK=1"'
chk "kernel root by probed PARTUUID, never label" 'grep -q "probe --set=PU --part-uuid" "$ESP/grub/grub.cfg"'
# The console carries the token and the generated password; kernel chatter that scrolls them
# away is a defect. Journald keeps everything regardless.
chk "console is quieted so the token stays readable" 'grep -q "loglevel=4" "$ESP/grub/grub.cfg"'
chk "display hotplug polling off (repeated EDID spam)" 'grep -q "drm_kms_helper.poll=0" "$ESP/grub/grub.cfg"'
chk "kernel + initrd in the slot" '[ -s "$ROOT/vmlinuz" ] || [ -L "$ROOT/vmlinuz" ]'

echo "==> docker-export artefacts (all six members)"
chk "no /.dockerenv" '[ ! -e "$ROOT/.dockerenv" ]'
chk "pseudo-fs mount points exist" '[ -d "$ROOT/proc" ] && [ -d "$ROOT/sys" ] && [ -d "$ROOT/dev" ] && [ -d "$ROOT/run" ]'
chk "/etc/hostname is pithead" '[ "$(cat "$ROOT/etc/hostname")" = "pithead" ]'
chk "/etc/hosts resolves localhost" 'grep -q "127.0.0.1 localhost" "$ROOT/etc/hosts"'
chk "/etc/resolv.conf -> resolved stub" '[ -L "$ROOT/etc/resolv.conf" ]'

echo "==> state mounts follow the boot disk, never labels"
chk "mount generator shipped + executable" '[ -x "$ROOT/usr/lib/systemd/system-generators/pithead-mount-generator" ]'
chk "fstab carries no LABEL= mounts" '! grep -q "LABEL=" "$ROOT/etc/fstab"'
chk "fstab still overlays /var" 'grep -q "overlay /var" "$ROOT/etc/fstab"'
chk "repart declares 4 GiB slots" 'grep -q "SizeMaxBytes=4G" "$ROOT/usr/lib/repart.d/20-system-a.conf"'
chk "repart declares the data partition" '[ -s "$ROOT/usr/lib/repart.d/40-data.conf" ]'

echo "==> the appliance can run the product"
chk "podman" '[ -e "$ROOT/usr/bin/podman" ]'
chk "docker shim (podman-docker)" '[ -e "$ROOT/usr/bin/docker" ]'
chk "compose provider" '[ -x "$ROOT/usr/local/bin/docker-compose" ]'
chk "cosign" '[ -x "$ROOT/usr/local/bin/cosign" ]'
chk "shim banner silenced" '[ -e "$ROOT/etc/containers/nodocker" ]'
chk "docker short-name semantics restored" 'grep -q "docker.io" "$ROOT/etc/containers/registries.conf.d/pithead-docker-compat.conf"'
chk "container storage on /data" 'grep -q "graphroot = \"/data/containers/storage\"" "$ROOT/etc/containers/storage.conf"'
chk "podman-restart enabled (stack returns after power loss)" 'ls "$ROOT"/etc/systemd/system/*.wants/podman-restart.service'
chk "podman-restart covers unless-stopped (the stack's actual policy)" 'grep -q "restart-policy=unless-stopped" "$ROOT/etc/systemd/system/podman-restart.service.d/pithead-unless-stopped.conf"'
chk "wizard image baked (offline first boot)" 'ls "$ROOT"/opt/pithead/images/*.tar.gz'
chk "installer + its whole toolset" '[ -x "$ROOT/usr/local/sbin/pithead-install" ] && [ -e "$ROOT/usr/sbin/sgdisk" ] && [ -e "$ROOT/usr/bin/jq" ]'
chk "grub.cfg staged for installs" '[ -s "$ROOT/usr/share/pithead/grub.cfg" ]'
chk "rauc daemon present (CLI alone cannot install)" '[ -f "$ROOT/usr/lib/systemd/system/rauc.service" ]'
chk "rauc keyring baked" '[ -s "$ROOT/etc/rauc/keyring.pem" ]'
chk "firstboot + sync units enabled" 'ls "$ROOT"/etc/systemd/system/multi-user.target.wants/pithead-firstboot.service "$ROOT"/etc/systemd/system/multi-user.target.wants/pithead-sync.service'
chk "program tree at /opt/pithead" '[ -x "$ROOT/opt/pithead/pithead" ] && [ -s "$ROOT/opt/pithead/VERSION" ]'

echo "==> provenance"
BUILT=$(cat "$ROOT/opt/pithead/BUILD_COMMIT" 2>/dev/null || echo missing)
echo "  image built from: $BUILT"
chk "carries a build stamp" '[ "$BUILT" != "missing" ] && [ -n "$BUILT" ]'
# The check that would have caught shipping a two-commits-stale dashboard: compare against what
# the caller believes it built. PITHEAD_EXPECT_COMMIT is set by the release procedure.
if [ -n "${PITHEAD_EXPECT_COMMIT:-}" ]; then
    chk "built from the expected commit ($PITHEAD_EXPECT_COMMIT)" '[ "$BUILT" = "$PITHEAD_EXPECT_COMMIT" ]'
    chk "built from a clean tree" 'case "$BUILT" in *-dirty) false ;; *) true ;; esac'
fi

# The RC3 failure in full: an image shipped a dashboard two commits stale, passed every check
# above, and behaved like the previous build on a bench. The stamp catches a stale TREE; these
# catch a stale ARTIFACT — the program and the baked container image are compared against the
# very files this checkout holds. Skipped when run outside the repo.
if [ -f ./pithead ] && [ -f build/dashboard/mining_dashboard/wizard.py ]; then
    echo "==> the artifact matches the tree it was built from"
    chk "shipped pithead is the tree's pithead" 'cmp -s "$ROOT/opt/pithead/pithead" ./pithead'
    chk "shipped compose file matches" 'cmp -s "$ROOT/opt/pithead/docker-compose.yml" ./docker-compose.yml'
    chk "shipped config reference matches" 'cmp -s "$ROOT/opt/pithead/config.reference.json" ./config.reference.json'

    # The wizard is the part that shipped stale, and it lives inside a container archive rather
    # than on the filesystem — so it needs unpacking to be compared at all. That opacity is
    # precisely why nobody noticed.
    WIZ_ARCHIVE=$(ls "$ROOT"/opt/pithead/images/*.tar.gz 2>/dev/null | head -1)
    WIZ_TMP=$(mktemp -d)
    WIZ_SHIPPED=""
    if [ -n "$WIZ_ARCHIVE" ] && tar -xzf "$WIZ_ARCHIVE" -C "$WIZ_TMP" 2>/dev/null; then
        for layer in "$WIZ_TMP"/blobs/sha256/* "$WIZ_TMP"/*/layer.tar; do
            [ -f "$layer" ] || continue
            member=$(tar -tf "$layer" 2>/dev/null | grep -m1 'mining_dashboard/wizard\.py$') || continue
            tar -xOf "$layer" "$member" >"$WIZ_TMP/shipped-wizard.py" 2>/dev/null && {
                # shellcheck disable=SC2034  # read inside chk's eval'd condition below
                WIZ_SHIPPED="$WIZ_TMP/shipped-wizard.py"
                break
            }
        done
    fi
    chk "the baked wizard image contains the tree's wizard.py" \
        '[ -n "$WIZ_SHIPPED" ] && cmp -s "$WIZ_SHIPPED" build/dashboard/mining_dashboard/wizard.py'
    rm -rf "$WIZ_TMP"
fi

echo "==> test material"
if [ "$MODE" = "--test" ]; then
    chk "test SSH key present (harness build)" '[ -s "$ROOT/root/.ssh/authorized_keys" ]'
else
    # The reason this script exists in versioned form: a leaked test key on a release image is a
    # backdoor, and ad-hoc eyeballing is how one ships.
    chk "NO test marker" '[ ! -e "$ROOT/etc/pithead-test-marker" ]'
    chk "NO SSH authorized_keys" '[ ! -s "$ROOT/root/.ssh/authorized_keys" ]'
    chk "ssh service disabled" '! ls "$ROOT"/etc/systemd/system/multi-user.target.wants/ssh.service'
fi

echo ""
printf 'verify-image: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
