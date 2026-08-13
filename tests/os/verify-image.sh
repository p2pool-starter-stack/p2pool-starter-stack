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

# Same race as mkimage.sh: losetup -P returns before the partition nodes exist. Wait once here
# so the checks below read the image, not the timing of udev on a busy box.
udevadm settle 2>/dev/null || true
for _ in {1..25}; do
    [ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] && break
    sleep 0.2
done
# Hard-fail like mkimage.sh does: a mount error two screens later names the wrong culprit.
[ -b "${LOOP}p1" ] && [ -b "${LOOP}p2" ] || {
    echo "partition nodes never appeared on $LOOP — udev timing or a broken image" >&2
    exit 1
}

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
# mDNS advertises IPv4 only — AAAA records stalled clients that cannot route to the box's v6.
chk "avahi is IPv4-only (no unreachable-AAAA stall)" 'grep -q "^use-ipv6=no" "$ROOT/etc/avahi/avahi-daemon.conf"'
# Boot recovery is compose-owned (#792): pithead-boot renders + ups + health-gates the slot
# commit. podman-restart started the stack into its own cgroup and SIGKILLed it on unit stop.
chk "pithead-boot unit enabled" 'test -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-boot.service"'
chk "pithead-boot script present and executable" 'test -x "$ROOT/usr/local/sbin/pithead-boot"'
chk "podman-restart retired (it killed the stack it started)" '[ ! -e "$ROOT/etc/systemd/system/multi-user.target.wants/podman-restart.service" ] && [ ! -e "$ROOT/etc/systemd/system/podman-restart.service.d" ]'
chk "kernel + initrd in the slot" '[ -s "$ROOT/vmlinuz" ] || [ -L "$ROOT/vmlinuz" ]'

echo "==> unattended auto-heal (soft hang the container/panic paths cannot catch)"
# systemd watchdog: a wedged kernel/init on a headless box is what /dev/watchdog exists for. We
# assert the CONFIG is baked, not that a hang reboots — no CI/KVM watchdog device to prove that.
chk "watchdog drop-in baked" '[ -s "$ROOT/etc/systemd/system.conf.d/pithead-watchdog.conf" ]'
chk "RuntimeWatchdogSec set" 'grep -q "^RuntimeWatchdogSec=" "$ROOT/etc/systemd/system.conf.d/pithead-watchdog.conf"'
chk "RebootWatchdogSec set (reboot itself is watched)" 'grep -q "^RebootWatchdogSec=" "$ROOT/etc/systemd/system.conf.d/pithead-watchdog.conf"'
# CPU governor: performance held every boot; a no-op where there is no cpufreq, so this asserts
# the unit is present and enabled, not the runtime governor value.
chk "cpu-governor unit present" '[ -s "$ROOT/etc/systemd/system/pithead-cpu-governor.service" ]'
chk "cpu-governor unit enabled" 'test -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-cpu-governor.service"'
chk "cpu-governor asks for performance" 'grep -q "frequency-set -g performance" "$ROOT/etc/systemd/system/pithead-cpu-governor.service"'

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
chk "wizard image baked (offline first boot)" 'ls "$ROOT"/opt/pithead/images/*.tar.gz'
chk "installer + its whole toolset" '[ -x "$ROOT/usr/local/sbin/pithead-install" ] && [ -e "$ROOT/usr/sbin/sgdisk" ] && [ -e "$ROOT/usr/bin/jq" ]'
chk "grub.cfg staged for installs" '[ -s "$ROOT/usr/share/pithead/grub.cfg" ]'
chk "rauc daemon present (CLI alone cannot install)" '[ -f "$ROOT/usr/lib/systemd/system/rauc.service" ]'
chk "rauc keyring baked" '[ -s "$ROOT/etc/rauc/keyring.pem" ]'
chk "firstboot + sync units enabled" 'ls "$ROOT"/etc/systemd/system/multi-user.target.wants/pithead-firstboot.service "$ROOT"/etc/systemd/system/multi-user.target.wants/pithead-sync.service'
chk "program tree at /opt/pithead" '[ -x "$ROOT/opt/pithead/pithead" ] && [ -s "$ROOT/opt/pithead/VERSION" ]'

echo "==> the built-in miner (local_miner on the appliance)"
# The whole point of baking: nothing here can be installed after the image ships. A missing
# piece surfaces as a miner that silently never starts — on a machine with no shell.
chk "rigforge tree baked" '[ -x "$ROOT/opt/rigforge/rigforge.sh" ]'
chk "rigforge ref recorded" 'grep -q "^ref=" "$ROOT/opt/rigforge/RIGFORGE_REF"'
chk "prebuilt xmrig baked (Tor-only box cannot clone)" '[ -x "$ROOT/opt/rigforge/prebuilt/xmrig/build/xmrig" ]'
chk "prebuilt commit marker matches rigforge's pin" '[ "$(cat "$ROOT/opt/rigforge/prebuilt/xmrig/.rigforge-commit")" = "$(sed -n "s/^XMRIG_COMMIT=\"\${XMRIG_COMMIT:-\(.*\)}\"$/\1/p" "$ROOT/opt/rigforge/rigforge.sh")" ]'
chk "prebuilt sha record present (integrity check input)" '[ -s "$ROOT/opt/rigforge/prebuilt/xmrig/.rigforge-sha256" ]'
chk "miner toolchain baked (compiler chain)" '[ -e "$ROOT/usr/bin/gcc" ] && [ -e "$ROOT/usr/bin/cmake" ] && [ -e "$ROOT/usr/bin/make" ] && [ -e "$ROOT/usr/bin/git" ]'
chk "miner runtime tools baked (envsubst/cpupower/rdmsr)" '[ -e "$ROOT/usr/bin/envsubst" ] && [ -e "$ROOT/usr/bin/cpupower" ] && [ -e "$ROOT/usr/sbin/rdmsr" ]'

echo "==> both role paths (a rig boots differently, updates identically)"
# One image installs two machines, and which one a box becomes is decided by a marker on /data
# that no static check can see. What CAN be checked here is that the shipped artifact carries
# both legs — because the failure mode is silent on the machine that has no dashboard to say so:
# a rig whose boot unit never fires just sits there, dark, mining nothing.
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
RIGB="$ROOT/usr/local/sbin/pithead-boot"
# The guard, not just the mention: `<machine-role` where there is none is a redirection failure
# the shell reports itself, so an unguarded read prints an error into every COORDINATOR boot.
chk "pithead-boot forks on the role marker, existence-tested before it is read" 'grep -q "^if \[ -f machine-role \]" "$RIGB"'
chk "the rig leg runs the miner instead of the stack" 'grep -qE "local-miner" "$RIGB"'
# The rig leg must reach the SAME commit the coordinator's does, or every A/B update to a rig
# rolls back at the next boot — the whole one-image, one-update-pipeline promise.
chk "the rig leg commits its A/B slot too (two mark-good sites)" '[ "$(grep -c "mark-good" "$RIGB")" -ge 2 ]'
chk "the rig leg starts nothing container-shaped" '! sed -n "/machine-role/,/^fi$/p" "$RIGB" | grep -qE "pithead (up|load-images|render)"'
# Unit conditions are the actual fork: without the triggering condition a rig never runs the
# boot unit at all, and without the firstboot exclusion it runs the WIZARD on every boot.
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
BOOTU="$ROOT/etc/systemd/system/pithead-boot.service"
# shellcheck disable=SC2034  # read inside chk's eval'd conditions
FBU="$ROOT/etc/systemd/system/pithead-firstboot.service"
chk "boot unit triggers on a coordinator's config.json" 'grep -q "^ConditionPathExists=|/data/pithead/config.json" "$BOOTU"'
chk "boot unit triggers on an accepted role marker (a rig has no config.json)" 'grep -q "^ConditionPathExists=|/data/pithead/machine-role" "$BOOTU"'
chk "firstboot is closed by config.json" 'grep -q "^ConditionPathExists=!/data/pithead/config.json" "$FBU"'
chk "firstboot is closed by the role marker (no wizard on a provisioned rig)" 'grep -q "^ConditionPathExists=!/data/pithead/machine-role" "$FBU"'
# Prebuilt-first for the rig role: the baked binary is asserted above, and the seeding that puts
# it in the rig's workspace is pithead-sync's, shared with the Both role.
chk "sync seeds the prebuilt into the miner workspace" 'grep -q "prebuilt/xmrig" "$ROOT/usr/local/sbin/pithead-sync"'
# Removable-root tolerance: a rig can run FROM the stick, and the image's journald is persistent.
chk "the rig leg makes the journal volatile" 'grep -q "Storage=volatile" "$ROOT/opt/pithead/pithead"'
chk "no swap in any role (no partition declared, none mounted)" '! grep -rqi "swap" "$ROOT"/usr/lib/repart.d/ && ! grep -qi "swap" "$ROOT/etc/fstab"'

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

echo "==> host identity never ships baked (#894/#895)"
# Both variants — a debug image is not exempt: its baked authorized_keys is USER auth, and the
# host identity underneath it must be exactly as per-machine as a release image's.
chk "no SSH host keys baked (extractable + shared across every machine otherwise)" \
    '! ls "$ROOT"/etc/ssh/ssh_host_* >/dev/null 2>&1'
chk "machine-id ships empty (systemd's own read-only-root first-boot semantics)" \
    '[ ! -s "$ROOT/etc/machine-id" ]'
chk "SSH host-key generator baked and executable" '[ -x "$ROOT/usr/local/sbin/pithead-ssh-host-keys" ]'
chk "ssh.service host-key drop-in orders after /data" \
    'grep -q "RequiresMountsFor=/data" "$ROOT/etc/systemd/system/ssh.service.d/pithead-host-keys.conf"'
chk "sshd points at the /data host key" \
    'grep -q "^HostKey /data/ssh/ssh_host_ed25519_key" "$ROOT/etc/ssh/sshd_config.d/pithead-host-keys.conf"'
chk "machine-id restore script baked and executable" '[ -x "$ROOT/usr/local/sbin/pithead-machine-id" ]'
chk "machine-id restore unit enabled" \
    'test -L "$ROOT/etc/systemd/system/sysinit.target.wants/pithead-machine-id.service"'
chk "machine-id restore orders before networkd (DHCP DUID) and the journal flush" \
    'grep -q "systemd-networkd.service" "$ROOT/etc/systemd/system/pithead-machine-id.service" &&
     grep -q "systemd-journal-flush.service" "$ROOT/etc/systemd/system/pithead-machine-id.service"'

echo "==> test material"
# The variant stamp must MATCH the material, not just exist: a debug image stamped "release"
# defeats the os-update guard that keeps a debug box from silently dropping its own SSH.
if [ "$MODE" = "--test" ]; then
    chk "test SSH key present (harness build)" '[ -s "$ROOT/root/.ssh/authorized_keys" ]'
    chk "variant stamp says debug" '[ "$(cat "$ROOT/etc/pithead-variant")" = "debug" ]'
else
    # The reason this script exists in versioned form: a leaked test key on a release image is a
    # backdoor, and ad-hoc eyeballing is how one ships.
    chk "NO test marker" '[ ! -e "$ROOT/etc/pithead-test-marker" ]'
    chk "NO SSH authorized_keys" '[ ! -s "$ROOT/root/.ssh/authorized_keys" ]'
    chk "ssh service disabled" '! ls "$ROOT"/etc/systemd/system/multi-user.target.wants/ssh.service'
    chk "variant stamp says release" '[ "$(cat "$ROOT/etc/pithead-variant")" = "release" ]'
    # The keyring is the fleet's update trust root. A dev build auto-generates a CN=pithead-dev
    # cert; if that baked as the release keyring, every device would trust a throwaway,
    # unencrypted key with no offline backup — a backdoor of the same class as a leaked SSH key,
    # so it is a hard fail here (the build guard should stop it upstream, this catches a slip at
    # the artifact). A legitimately self-signed release root is fine — only the known dev CN is
    # refused, so this never false-positives on a real single-cert keyring.
    chk "keyring is NOT the dev signing cert (CN=pithead-dev)" \
        '! openssl x509 -in "$ROOT/etc/rauc/keyring.pem" -noout -subject 2>/dev/null | grep -q "pithead-dev"'
fi

echo ""
printf 'verify-image: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
