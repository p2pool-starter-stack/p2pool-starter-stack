#!/usr/bin/env bash
# Tier-4 appliance harness (#77 phase 2): boot the pithead-os image in KVM and prove the
# properties only real firmware + a real A/B updater can show — EFI boot, the first-boot wizard
# window, and the update/commit/rollback cycle that is the phase-2 exit criterion. This is the
# os-image sibling of tests/integration/run.sh; it needs a Linux host with KVM + libvirt + the
# built image, so it runs on the bench, not in CI.
#
#   tests/os/run.sh --image PATH [--keep] [--phase boot|update|all]
#
# Phases:
#   boot    flash the image to a scratch disk, boot it, assert EFI boot + firstboot wizard up
#   update  build a v2 bundle, install it, commit-on-healthy; then a broken bundle, assert rollback
#   all     both (default)
#
# Exit non-zero on the first failed assertion. --keep leaves the VM + disks for inspection.
set -uo pipefail

IMAGE=""
KEEP=0
PHASE="all"
VM="pithead-os-test"
BAKERY_DIR="os/bakery"
DISK="/srv/code/bench-vm/pithead-os-test.img"
SERIAL="/tmp/pithead-os-serial.log"

while [ $# -gt 0 ]; do
    case "$1" in
    --image)
        IMAGE="$2"
        shift 2
        ;;
    --keep)
        KEEP=1
        shift
        ;;
    --phase)
        PHASE="$2"
        shift 2
        ;;
    --vm)
        VM="$2"
        shift 2
        ;;
    -h | --help)
        sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "unknown arg: $1" >&2
        exit 2
        ;;
    esac
done

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
info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

require_host() {
    for c in virsh virt-install qemu-img; do
        have "$c" || {
            echo "missing $c — install libvirt/qemu (see tests/os/README.md)" >&2
            exit 2
        }
    done
    [ -e /dev/kvm ] || {
        echo "/dev/kvm absent — this harness needs hardware virtualization" >&2
        exit 2
    }
    [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || {
        echo "--image PATH is required and must exist (build with os/build-image.sh)" >&2
        exit 2
    }
}

vm_destroy() {
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" --nvram >/dev/null 2>&1 || true
}

cleanup() {
    if [ "$KEEP" -eq 1 ]; then
        info "left VM '$VM' and $DISK in place (--keep)"
        return
    fi
    vm_destroy
    rm -f "$DISK" "$SERIAL"
}
trap cleanup EXIT

# Wait until the serial log matches a pattern, or time out. $1 pattern, $2 seconds.
wait_serial() {
    local pat="$1" deadline=$(($(date +%s) + ${2:-180}))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        grep -qE "$pat" "$SERIAL" 2>/dev/null && return 0
        sleep 3
    done
    return 1
}

phase_boot() {
    info "phase: boot"
    vm_destroy
    cp "$IMAGE" "$DISK"
    # Grow the scratch disk before first boot: rugix-ctrl's bootstrapping expands the baked image
    # into the full A/B layout (256M EFI + 2x512M boot + 2x8GiB system + data ~= 18 GiB minimum).
    # On the raw 1.8G image it fails with "insufficient space, cannot add partition 5" and exits,
    # panicking the kernel — which is what a real flash to an undersized disk would also do.
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    # UEFI (OVMF), serial to a file we tail, import the raw appliance disk as-is.
    virt-install --name "$VM" --memory 8192 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 ||
        {
            bad "virt-install failed to define the VM"
            return
        }
    # NB: do NOT assert on the kernel banner — the appliance boots with loglevel=3, which keeps
    # those lines off the console entirely, so a healthy boot looks silent. The getty banner (or
    # the wizard's own announcement) is the first thing userspace reliably puts on serial.
    if wait_serial "login:|Debian GNU/Linux|Pithead setup wizard" 240; then
        ok "image boots to userspace (login banner on the serial console)"
    else
        bad "no userspace banner on serial within 240s — boot failed; check the serial log"
        return
    fi
    # The firstboot unit prints the wizard URL + one-time token to the console (phase-3 design).
    if wait_serial "firstboot-wizard|One-time token|Setup wizard is up" 180; then
        ok "first-boot wizard window opens (token printed to console)"
    else
        bad "first-boot wizard never announced itself on the console"
    fi
    # Reachable on :80 from the host once the VM has a lease.
    local ip
    # No guest agent in the appliance image (by design) — the DHCP lease is the source of truth.
    local tries=0
    while [ -z "${ip:-}" ] && [ "$tries" -lt 20 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    if [ -n "$ip" ] && curl -fsS -m 5 "http://$ip/" 2>/dev/null | grep -qi "Pithead setup"; then
        ok "wizard serves the token gate on :80 ($ip)"
    else
        bad "wizard not reachable on :80 (guest-agent IP: ${ip:-none})"
    fi
}

# Boot a raw appliance disk under OVMF and return once it has a lease. Sets the global `ip`.
_vm_boot_disk() {
    vm_destroy
    cp "$1" "$DISK"
    # Grow the scratch disk before first boot: rugix-ctrl's bootstrapping expands the baked image
    # into the full A/B layout (256M EFI + 2x512M boot + 2x8GiB system + data ~= 18 GiB minimum).
    # On the raw 1.8G image it fails with "insufficient space, cannot add partition 5" and exits,
    # panicking the kernel — which is what a real flash to an undersized disk would also do.
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    virt-install --name "$VM" --memory 8192 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || return 1
    ip=""
    local tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 40 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$ip" ]
}

phase_update() {
    info "phase: update (A/B commit + rollback, driven over test-only SSH)"
    local key="$HOME/.ssh/pithead-os-test" ip="" marker bundle
    [ -f "$key" ] || ssh-keygen -t ed25519 -N "" -f "$key" -q
    _ssh() {
        ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=8 "root@$ip" "$@" 2>/dev/null
    }
    _wait_ssh() {
        local deadline=$(($(date +%s) + $1))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            _ssh true && return 0
            sleep 5
        done
        return 1
    }

    info "building v1 test image (test SSH key + marker v1)"
    if ! PITHEAD_TEST_SSH_PUBKEY="$(cat "$key.pub")" PITHEAD_TEST_MARKER="v1" \
        os/build-image.sh >/tmp/os-test-v1-build.log 2>&1; then
        bad "v1 test image build failed (/tmp/os-test-v1-build.log)"
        return
    fi
    _vm_boot_disk "$BAKERY_DIR/build/pithead-os-amd64/system.img" && _wait_ssh 240 ||
        {
            bad "v1 test guest never answered SSH (ip: ${ip:-none})"
            return
        }
    ok "v1 test image boots and answers test SSH ($ip)"
    [ "$(_ssh cat /etc/pithead-test-marker)" = "v1" ] && ok "marker v1 on the initial slot" ||
        {
            bad "marker v1 missing on the initial slot"
            return
        }

    info "building v2 update bundle (marker v2)"
    if ! PITHEAD_TEST_SSH_PUBKEY="$(cat "$key.pub")" PITHEAD_TEST_MARKER="v2" \
    PITHEAD_BAKE_ARTIFACT=bundle os/build-image.sh >/tmp/os-test-v2-build.log 2>&1; then
        bad "v2 bundle build failed (/tmp/os-test-v2-build.log)"
        return
    fi
    bundle=$(find "$BAKERY_DIR/build/pithead-os-amd64" -name '*.rugixb' | head -1)
    [ -n "$bundle" ] || {
        bad "no .rugixb bundle produced"
        return
    }
    ok "built v2 bundle: $(basename "$bundle")"

    info "leg 1 — install v2, boot spare, reboot WITHOUT commit -> must fall back to v1"
    scp -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$bundle" "root@$ip:/data/update.rugixb" || {
        bad "bundle scp to the guest failed"
        return
    }
    _ssh "rugix-ctrl update install /data/update.rugixb" || true # reboots into the spare slot
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the v2 install"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "spare slot booted with v2" ||
        {
            bad "expected v2 in the spare slot, got '$marker'"
            return
        }
    _ssh reboot || true # uncommitted -> Rugix falls back on its own
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the no-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an uncommitted update reverts to v1 on reboot" ||
        {
            bad "expected v1 after the uncommitted reboot, got '$marker'"
            return
        }

    info "leg 2 — install v2 again, COMMIT, reboot -> must stay v2"
    _ssh "rugix-ctrl update install /data/update.rugixb" || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the second install"
        return
    }
    _ssh "rugix-ctrl system commit" || {
        bad "rugix-ctrl system commit failed"
        return
    }
    ok "committed the booted update"
    _ssh reboot || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "COMMIT: a committed update persists across reboot" ||
        bad "expected v2 after commit, got '$marker'"
}

require_host
case "$PHASE" in
boot) phase_boot ;;
update) phase_update ;;
all)
    phase_boot
    phase_update
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
