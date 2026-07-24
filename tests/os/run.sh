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
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    # UEFI (OVMF), serial to a file we tail, import the raw appliance disk as-is.
    virt-install --name "$VM" --memory 4096 --vcpus 4 --cpu host-passthrough \
        --boot uefi --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 ||
        {
            bad "virt-install failed to define the VM"
            return
        }
    if wait_serial "Linux version|systemd\[1\]" 120; then
        ok "image boots (kernel + systemd on the serial console)"
    else
        bad "no kernel/systemd banner on serial within 120s — EFI boot likely failed"
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

phase_update() {
    info "phase: update (A/B commit + rollback)"
    have "$BAKERY_DIR/run-bakery" || {
        bad "no run-bakery in $BAKERY_DIR — run os/build-image.sh once first"
        return
    }
    # A good update: same recipe, a marker file so we can prove the new slot booted.
    # (bake bundle emits an installable .rugixb; the commit gate is pithead doctor --json.)
    info "building v2 update bundle"
    (cd "$BAKERY_DIR" && ./run-bakery bake bundle pithead-os-amd64 >/dev/null 2>&1) ||
        {
            bad "bake bundle failed"
            return
        }
    local bundle
    bundle=$(find "$BAKERY_DIR/build" -name '*.rugixb' | head -1)
    [ -n "$bundle" ] || {
        bad "no .rugixb bundle produced"
        return
    }
    ok "built update bundle: $(basename "$bundle")"

    # The install/commit/rollback legs run guest-side over the serial console or ssh-if-enabled;
    # this harness copies the bundle in and drives rugix-ctrl. Kept as explicit asserts so a
    # regression in the commit gate or the rollback path fails loudly.
    info "NOTE: install/commit/rollback execution binds to the booted guest — see tests/os/README.md"
    bad "update leg not yet wired to the running guest (bundle build proven; guest drive pending)"
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
