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

# Directory-independent: this script assumes cwd == repo root for the relative paths later on
# (./pithead, dashboard/...), so resolve the shared helper from the script's own location
# instead of adding a cd that would change those.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=os/rauc/loop-wait.sh
. "$SCRIPT_DIR/../../os/rauc/loop-wait.sh"

# #1414: the baked ref must EQUAL the pin, not merely exist. `grep -q "^ref="` passed for any
# value — including one two rigforge releases stale, which is the state this gate shipped in.
# Two values from two places, the shape the prebuilt-commit check below already uses. The
# Dockerfile is READ, never written, and resolved from SCRIPT_DIR rather than cwd; an unreadable
# one SKIPS, and exit refuses a skip (#1064), so this cannot go quiet the way its predecessor did.
DOCKERFILE="$SCRIPT_DIR/../../os/rootfs/Dockerfile"
rigforge_ref_matches() { # <image-root> <dockerfile> — 0 iff the recorded ref IS the pinned one
    local rec pin
    rec=$(sed -n 's/^ref=\([^ ]*\).*/\1/p' "$1/opt/rigforge/RIGFORGE_REF" 2>/dev/null)
    pin=$(sed -n 's/^ARG RIGFORGE_REF=\([^ ]*\).*/\1/p' "$2" 2>/dev/null)
    [ -n "$rec" ] && [ "$rec" = "$pin" ]
}
# Sourcing defines the helper and runs nothing, so the self-test drives the REAL comparison.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0; fi

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

# A check that did not run is not a check that passed (#1064). Both of the strongest blocks below
# are conditional, and their skips were silent — so the summary printed "0 failed" for a verifier
# that had declined to compare the artifact against the tree at all, which is exactly the failure
# the RC3 stale-dashboard incident produced.
SKIP=0
skip() { # <label> <why>
    SKIP=$((SKIP + 1))
    printf '  \033[1;33m-\033[0m %s (SKIPPED: %s)\n' "$1" "$2"
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

# Same race as mkimage.sh (see loop-wait.sh). Hard-fail like it does: a mount error two screens
# later names the wrong culprit.
wait_loop_partitions "$LOOP" || {
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
# The console carries the token and the password; chatter that scrolls them away is a defect.
chk "console is quieted so the token stays readable" 'grep -q "loglevel=4" "$ESP/grub/grub.cfg"'
chk "display hotplug polling off (repeated EDID spam)" 'grep -q "drm_kms_helper.poll=0" "$ESP/grub/grub.cfg"'
# shellcheck source=tests/os/verify-image-boot-menu.sh
. "$SCRIPT_DIR/verify-image-boot-menu.sh"
# mDNS advertises IPv4 only — AAAA records stalled clients that cannot route to the box's v6.
chk "avahi is IPv4-only (no unreachable-AAAA stall)" 'grep -q "^use-ipv6=no" "$ROOT/etc/avahi/avahi-daemon.conf"'
# Boot recovery is compose-owned (#792): pithead-boot renders + ups + health-gates the slot commit.
chk "pithead-boot unit enabled" 'test -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-boot.service"'
chk "pithead-boot script present and executable" 'test -x "$ROOT/usr/local/sbin/pithead-boot"'
# Physical-presence config channel (#786 sub-issue D): pithead-boot's one stage before render,
# no unit of its own.
chk "pithead-media-config script present and executable" 'test -x "$ROOT/usr/local/sbin/pithead-media-config"'
chk "pithead-boot calls the media-config channel before render" \
    'grep -q "pithead-media-config" "$ROOT/usr/local/sbin/pithead-boot"'
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
# The factory-reset / wedged-/data recovery path: every other boot-path unit is pinned here, and
# this one is the last resort an operator has on a shell-less box — a build that drops it ships a
# machine that cannot recover itself.
chk "data-reset unit shipped" '[ -s "$ROOT/etc/systemd/system/pithead-data-reset.service" ]'
chk "data-reset unit enabled (local-fs transaction)" 'test -L "$ROOT/etc/systemd/system/local-fs.target.wants/pithead-data-reset.service"'
chk "data-reset script present and executable" 'test -x "$ROOT/usr/local/sbin/pithead-data-reset"'
chk "data-reset ordered before /data mounts (a mounted partition cannot be reformatted)" \
    'grep -q "^Before=data.mount local-fs.target" "$ROOT/etc/systemd/system/pithead-data-reset.service"'
# Hugepages: the sysctl the Dockerfile calls load-bearing for the memory caps.
chk "hugepage reservation baked (RandomX dataset must land in hugetlbfs)" 'grep -q "vm.nr_hugepages=3072" "$ROOT/etc/sysctl.d/99-pithead-hugepages.conf"'
# The low-RAM sizing that corrects that sysctl at boot: without it a small machine gets the
# silent 6 GiB carve-out back.
chk "hugepages sizing unit enabled (low-RAM boots degrade loudly, not silently)" 'test -L "$ROOT/etc/systemd/system/multi-user.target.wants/pithead-hugepages.service"'
chk "hugepages sizing script present and executable" 'test -x "$ROOT/usr/local/sbin/pithead-hugepages"'
# The pool's second writer (#1724): the miner unit must not be able to grow nr_hugepages through either sysfs subtree xmrig writes. The live unit's readback is the battery's; this pins the ship.
chk "miner unit drop-in fences BOTH hugepage sysfs subtrees (#1724)" 'grep -qxF "ReadOnlyPaths=/sys/devices/system/node /sys/kernel/mm/hugepages" "$ROOT/etc/systemd/system/xmrig.service.d/pithead-hugepages.conf"'

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
# The seeding mechanism itself (#1092): systemd-repart's MakeDirectories= only runs the moment it
# FORMATS the partition, so this is the one place that can actually observe a dropped seed — a
# post-boot check on a running system cannot, because pithead-sync's own `mkdir -p /data/pithead`
# recreates that directory every boot regardless of what repart seeded, and a missing overlay
# upperdir fails local-fs.target on this read-only root, bricking the boot before any check runs.
chk "repart seeds /overlay/var on first format" \
    'grep -qxF "MakeDirectories=/overlay/var" "$ROOT/usr/lib/repart.d/40-data.conf"'
chk "repart seeds /overlay/var-work on first format" \
    'grep -qxF "MakeDirectories=/overlay/var-work" "$ROOT/usr/lib/repart.d/40-data.conf"'
chk "repart seeds /pithead on first format" \
    'grep -qxF "MakeDirectories=/pithead" "$ROOT/usr/lib/repart.d/40-data.conf"'

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
if [ -r "$DOCKERFILE" ]; then
    chk "rigforge ref recorded AND equal to the pin" 'rigforge_ref_matches "$ROOT" "$DOCKERFILE"'
else
    skip "rigforge ref recorded AND equal to the pin" "os/rootfs/Dockerfile not readable"
fi
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
    # Prefix, not equality: the stamp is the full sha with an optional "-dirty" suffix, while the
    # commit anyone types is the short one every log line prints. Equality failed both callers.
    # Dirtiness is the next check's job, not this one's.
    chk "built from the expected commit ($PITHEAD_EXPECT_COMMIT)" 'case "$BUILT" in "$PITHEAD_EXPECT_COMMIT"*) true ;; *) false ;; esac'
    chk "built from a clean tree" 'case "$BUILT" in *-dirty) false ;; *) true ;; esac'
else
    skip "built from the expected commit" "PITHEAD_EXPECT_COMMIT is unset"
    skip "built from a clean tree" "PITHEAD_EXPECT_COMMIT is unset"
fi

# The RC3 failure in full: an image shipped a dashboard two commits stale, passed every check
# above, and behaved like the previous build on a bench. The stamp catches a stale TREE; these
# catch a stale ARTIFACT — the program and the baked container image are compared against the
# very files this checkout holds. Skipped when run outside the repo.
if [ -f ./pithead ] && [ -f dashboard/mining_dashboard/wizard.py ]; then
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
    # #1935: this check reddened once in a battery, re-passed on the same image, and the log could not
    # say which step produced no file — so each step names itself, and a mismatch prints cmp's verdict.
    WIZ_WHY="no *.tar.gz under opt/pithead/images"
    if [ -n "$WIZ_ARCHIVE" ]; then
        if tar -xzf "$WIZ_ARCHIVE" -C "$WIZ_TMP" 2>"$WIZ_TMP/untar.err"; then
            WIZ_WHY="no layer lists mining_dashboard/wizard.py"
            for layer in "$WIZ_TMP"/blobs/sha256/* "$WIZ_TMP"/*/layer.tar; do
                [ -f "$layer" ] || continue
                # sed, not grep -m1: an early exit would SIGPIPE tar and, under pipefail, skip the layer.
                member=$(tar -tf "$layer" 2>/dev/null | grep 'mining_dashboard/wizard\.py$' | sed -n '1p')
                [ -n "$member" ] || continue
                if tar -xOf "$layer" "$member" >"$WIZ_TMP/shipped-wizard.py" 2>"$WIZ_TMP/extract.err"; then
                    # shellcheck disable=SC2034  # read inside chk's eval'd condition below
                    WIZ_SHIPPED="$WIZ_TMP/shipped-wizard.py"
                    break
                fi
                WIZ_WHY="tar -xOf $member from $(basename "$layer" | cut -c1-12) failed: $(head -c 120 "$WIZ_TMP/extract.err" | tr -c '[:print:]' '?')"
            done
        else
            WIZ_WHY="tar -xzf $(basename "$WIZ_ARCHIVE") failed: $(head -c 120 "$WIZ_TMP/untar.err" | tr -c '[:print:]' '?')"
        fi
    fi
    chk "the baked wizard image contains the tree's wizard.py" \
        '[ -n "$WIZ_SHIPPED" ] && cmp -s "$WIZ_SHIPPED" dashboard/mining_dashboard/wizard.py'
    if [ -z "$WIZ_SHIPPED" ]; then
        echo "     · wizard.py was not extracted: $WIZ_WHY"
    elif ! cmp -s "$WIZ_SHIPPED" dashboard/mining_dashboard/wizard.py; then
        echo "     · shipped wizard.py differs from the tree's: $(cmp "$WIZ_SHIPPED" dashboard/mining_dashboard/wizard.py 2>&1 | head -1)"
    fi
    rm -rf "$WIZ_TMP"
else
    skip "the artifact matches the tree it was built from" "not run from the repo root"
fi

echo "==> host identity never ships baked (#894/#895)"
# Both variants — a debug image is not exempt: its baked authorized_keys is USER auth, and the
# host identity underneath it must be exactly as per-machine as a release image's.
chk "no SSH host keys baked (extractable + shared across every machine otherwise)" \
    '! ls "$ROOT"/etc/ssh/ssh_host_* >/dev/null 2>&1'
chk "machine-id ships empty (systemd's own read-only-root first-boot semantics)" '[ ! -s "$ROOT/etc/machine-id" ]'
# systemd's first-boot logic PREFERS /var/lib/dbus/machine-id when it exists — dbus's postinst
# bakes one at build, and a baked copy gives every machine flashed from this release the SAME
# identity. The symlink makes dbus follow the per-machine /etc/machine-id instead.
chk "dbus machine-id is a symlink (no per-release baked identity)" '[ -L "$ROOT/var/lib/dbus/machine-id" ]'
chk "SSH host-key generator baked and executable" '[ -x "$ROOT/usr/local/sbin/pithead-ssh-host-keys" ]'
chk "ssh.service host-key drop-in orders after /data" \
    'grep -q "RequiresMountsFor=/data" "$ROOT/etc/systemd/system/ssh.service.d/pithead-host-keys.conf"'
# Debian's own unit runs `sshd -t` as ExecStartPre, and drop-in entries APPEND — without the
# reset, the config test runs before the generator, finds no key on a first boot, and
# ssh.service can never start (KVM-battery find). The reset line + generator-first order is
# load-bearing, so pin all three lines and their order.
chk "host-key generator runs BEFORE the distro's sshd -t (reset + reorder)" \
    '[ "$(grep "^ExecStartPre" "$ROOT/etc/systemd/system/ssh.service.d/pithead-host-keys.conf" | head -1)" = "ExecStartPre=" ] &&
     grep -qxF "ExecStartPre=/usr/local/sbin/pithead-ssh-host-keys" "$ROOT/etc/systemd/system/ssh.service.d/pithead-host-keys.conf" &&
     grep -qxF "ExecStartPre=/usr/sbin/sshd -t" "$ROOT/etc/systemd/system/ssh.service.d/pithead-host-keys.conf"'
chk "sshd points at the /data host key" \
    'grep -q "^HostKey /data/ssh/ssh_host_ed25519_key" "$ROOT/etc/ssh/sshd_config.d/pithead-host-keys.conf"'
chk "machine-id restore script baked and executable" '[ -x "$ROOT/usr/local/sbin/pithead-machine-id" ]'
chk "machine-id restore unit enabled" \
    'test -L "$ROOT/etc/systemd/system/sysinit.target.wants/pithead-machine-id.service"'
chk "machine-id restore orders before networkd (DHCP DUID) and the journal flush" \
    'grep -q "systemd-networkd.service" "$ROOT/etc/systemd/system/pithead-machine-id.service" &&
     grep -q "systemd-journal-flush.service" "$ROOT/etc/systemd/system/pithead-machine-id.service"'
chk "machine-id restore re-points journald at the restored id (#1659)" \
    'grep -q "systemctl restart systemd-journald.service" "$ROOT/usr/local/sbin/pithead-machine-id"'
# First-boot interrupt record (#1030) and one journal home (#1791): Storage=persistent
# (journald.conf.d/pithead.conf) lands on this bind, which must exist, be enabled, and be ordered
# after the /var overlay it used to race for /var/log/journal and before the flush it feeds.
chk "persistent-journald config baked" \
    'grep -q "^Storage=persistent" "$ROOT/etc/systemd/journald.conf.d/pithead.conf"'
chk "the /data-backed journal mountpoint is baked (must pre-exist: a bind mount cannot mkdir a read-only root)" \
    '[ -d "$ROOT/var/log/journal" ]'
chk "journal-persist script baked and executable" '[ -x "$ROOT/usr/local/sbin/pithead-journal-persist" ]'
# #1030 review: the baked script must actually chown the persisted directory to
# root:systemd-journal, not just claim to in a comment — the parent chain under /data is
# root:root, and setgid alone only propagates the DIRECTORY's own group, so a promoted journal
# without this line ends up group root and unreadable by non-root systemd-journal members.
chk "journal-persist chowns the persisted directory to root:systemd-journal" \
    'grep -q "chown root:systemd-journal" "$ROOT/usr/local/sbin/pithead-journal-persist"'
chk "journal-persist unit enabled" \
    'test -L "$ROOT/etc/systemd/system/sysinit.target.wants/pithead-journal-persist.service"'
chk "journal-persist orders after the /var overlay (#1791) and before the journal flush it exists to feed" \
    'grep -q "^After=var.mount" "$ROOT/etc/systemd/system/pithead-journal-persist.service" && grep -q "^Before=.*systemd-journal-flush.service" "$ROOT/etc/systemd/system/pithead-journal-persist.service"'
# An empty machine-id makes systemd run FIRST-BOOT semantics on every power cycle (the volatile
# /etc upper resets it), and first boot applies preset-all — with no preset files, systemd's
# fallback is enable-everything, which would resurrect the deliberately-disabled ssh.service on
# a release image. The disable-* preset neutralizes that pass; systemd-firstboot is masked so it
# cannot re-run (and prompt on console) each boot. Guard both or the machine-id fix reopens ssh.
chk "blanket disable preset baked (first-boot preset-all must be a no-op)" \
    'grep -qx "disable \*" "$ROOT/etc/systemd/system-preset/00-pithead.preset"'
chk "systemd-firstboot masked (every boot is a first boot with an empty machine-id)" \
    '[ "$(readlink "$ROOT/etc/systemd/system/systemd-firstboot.service")" = "/dev/null" ]'

# The sibling carries the refusals that stop a debug image shipping as a release; this script runs
# without -e, so a missing sibling must refuse here rather than source nothing and report clean.
[ -r "$SCRIPT_DIR/verify-image-variant.sh" ] || {
    echo "verify-image: $SCRIPT_DIR/verify-image-variant.sh is missing — refusing to report" >&2
    exit 2
}
# shellcheck source=tests/os/verify-image-variant.sh
. "$SCRIPT_DIR/verify-image-variant.sh"

echo ""
printf 'verify-image: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m' "$FAIL"
    [ "$SKIP" -gt 0 ] && printf ', \033[1;33m%d skipped\033[0m' "$SKIP"
    printf '\n'
    exit 1
fi
printf '0 failed'
[ "$SKIP" -gt 0 ] && printf ', \033[1;33m%d skipped\033[0m' "$SKIP"
printf '\n'
# Release mode is the one run whose job is to catch a stale artifact. Skipping the checks that do
# that and exiting 0 is how an image with a two-commits-stale dashboard passed everything (#1064).
# --test builds come from the harness, which pins the commit itself, so a skip there is a defect
# in the harness rather than the operator's invocation — refuse in both.
if [ "$SKIP" -gt 0 ]; then
    printf '\033[1;31m[FAIL]\033[0m %d check(s) were SKIPPED, so this is not a verified image. Run from the repo root with PITHEAD_EXPECT_COMMIT set to the commit you believe you built.\n' "$SKIP" >&2
    exit 1
fi
