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
UPDATER="rugix"
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
    --updater)
        UPDATER="$2"
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

KEY="$HOME/.ssh/pithead-os-test"
ip=""

_ssh() {
    ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 "root@$ip" "$@" 2>/dev/null
}
_wait_ssh() { # $1 seconds — the definition of "not bricked"
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh true && return 0
        sleep 5
    done
    return 1
}
_marker() { _ssh cat /etc/pithead-test-marker 2>/dev/null | tr -d "\r\n"; }

# Build a bootable image carrying $1 as its slot marker, for the selected updater.
_build_image() {
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -q
    if [ "$UPDATER" = "rauc" ]; then
        PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
            os/build-image.sh >/tmp/os-fault-build.log 2>&1 || return 1
        os/rauc/mkimage.sh >>/tmp/os-fault-build.log 2>&1 || return 1
        printf 'os/rauc/build/system.img'
    else
        PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
            os/build-image.sh >/tmp/os-fault-build.log 2>&1 || return 1
        printf 'os/bakery/build/pithead-os-amd64/system.img'
    fi
}

# Build an update bundle carrying $1 as its marker.
_build_bundle() {
    if [ "$UPDATER" = "rauc" ]; then
        PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
            os/build-image.sh >/tmp/os-fault-bundle.log 2>&1 || return 1
        os/rauc/mkbundle.sh >>/tmp/os-fault-bundle.log 2>&1 || return 1
        find os/rauc/build -name '*.raucb' | head -1
    else
        PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        PITHEAD_BAKE_ARTIFACT=bundle os/build-image.sh >/tmp/os-fault-bundle.log 2>&1 || return 1
        find os/bakery/build -name '*.rugixb' | head -1
    fi
}

# Per-updater command vocabulary — the ONLY updater-specific part of the battery.
#
# NOTE both updaters refuse unverified bundles by default, which is correct and is why the test
# bundles carry an explicit bypass: this battery measures crash-safety, not the signing chain.
# Production signs bundles with the release key — see the signing section of the plan. RAUC has
# no bypass at all (it will not install an unsigned bundle), so its bundles are signed with the
# development keypair mkimage.sh generates.
_install_cmd() {
    case "$UPDATER" in
    rauc) printf 'rauc install %s' "$1" ;;
    *) printf 'rugix-ctrl update install --insecure-skip-bundle-verification --reboot no %s' "$1" ;;
    esac
}
_commit_cmd() {
    case "$UPDATER" in
    rauc) printf 'rauc status mark-good' ;;
    *) printf 'rugix-ctrl system commit' ;;
    esac
}
# Booting the newly written slot. rugix installs with --reboot no, so the spare must be selected
# explicitly — a plain reboot returns to the running slot. RAUC arms the GRUB try-counter during
# install, so a plain reboot already lands on the new slot.
_boot_spare_cmd() {
    case "$UPDATER" in
    rauc) printf 'reboot' ;;
    *) printf 'rugix-ctrl system reboot --spare' ;;
    esac
}
# The normal update path an operator would take: install and end up running the new version.
_install_and_boot_cmd() {
    case "$UPDATER" in
    rauc) printf 'rauc install %s && systemctl reboot' "$1" ;;
    *) printf 'rugix-ctrl update install --insecure-skip-bundle-verification %s' "$1" ;;
    esac
}
# Operator-initiated rollback: the "put it back" button, distinct from automatic fallback.
_rollback_cmd() {
    case "$UPDATER" in
    rauc) printf 'rauc status mark-bad booted && reboot' ;;
    *) printf 'rugix-ctrl system reboot --spare' ;;
    esac
}

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
    # --image is the boot phase's input; the update phase builds its own v1/v2 images.
    # --image is the boot phase's input; update and fault build their own v1/v2 images.
    if [ "$PHASE" = "boot" ] || [ "$PHASE" = "all" ]; then
        [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || {
            echo "--image PATH is required for the boot phase (build with os/build-image.sh)" >&2
            exit 2
        }
    fi
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
    # 16 GiB guest: the appliance reserves 6 GiB of hugepages at boot (RandomX), so a smaller VM
    # leaves too little for the stack — and the plan sizes appliance RAM to the compose caps anyway.
    # Grow the scratch disk before first boot: rugix-ctrl's bootstrapping expands the baked image
    # into the full A/B layout (256M EFI + 2x512M boot + 2x8GiB system + data ~= 18 GiB minimum).
    # On the raw 1.8G image it fails with "insufficient space, cannot add partition 5" and exits,
    # panicking the kernel — which is what a real flash to an undersized disk would also do.
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    # UEFI (OVMF), serial to a file we tail, import the raw appliance disk as-is.
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
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
    # 16 GiB guest: the appliance reserves 6 GiB of hugepages at boot (RandomX), so a smaller VM
    # leaves too little for the stack — and the plan sizes appliance RAM to the compose caps anyway.
    # Grow the scratch disk before first boot: rugix-ctrl's bootstrapping expands the baked image
    # into the full A/B layout (256M EFI + 2x512M boot + 2x8GiB system + data ~= 18 GiB minimum).
    # On the raw 1.8G image it fails with "insufficient space, cannot add partition 5" and exits,
    # panicking the kernel — which is what a real flash to an undersized disk would also do.
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
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

phase_fault() {
    info "phase: fault injection ($UPDATER) — a brick is disqualifying, not deducted"
    local img bundle marker i out

    info "building v1 image (marker v1)"
    img=$(_build_image v1) || {
        bad "v1 image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 300 || {
        bad "v1 guest never answered SSH"
        return
    }
    ok "v1 boots and answers SSH ($ip)"

    info "building v2 bundle (marker v2)"
    bundle=$(_build_bundle v2) || {
        bad "v2 bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    [ -n "$bundle" ] && [ -f "$bundle" ] || {
        bad "no update bundle produced"
        return
    }
    ok "v2 bundle built: $(basename "$bundle")"
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$bundle" "root@$ip:/data/update.bundle" || {
        bad "bundle copy to the guest failed"
        return
    }

    # Fault A: cut power WHILE the updater is writing the spare slot. The invariant is not that
    # the update survives — it is that the box still boots something.
    for i in 1 2 3; do
        info "fault A$i — destroy mid-write"
        _ssh "nohup sh -c '$(_install_cmd /data/update.bundle)' >/tmp/inst.log 2>&1 &" || true
        sleep 12
        virsh destroy "$VM" >/dev/null 2>&1 || true
        sleep 3
        virsh start "$VM" >/dev/null 2>&1 || true
        if _wait_ssh 300; then
            marker=$(_marker)
            ok "A$i: survived a mid-write power cut — booted slot marker '$marker'"
        else
            bad "A$i: BRICKED — no boot after a mid-write power cut (disqualifying)"
            return
        fi
    done

    # Fault B: cut power during the commit itself, the smallest and most dangerous window.
    info "installing v2 fully, then destroying mid-commit"
    out=$(_ssh "$(_install_and_boot_cmd /data/update.bundle) 2>&1" || true)
    [ -n "$out" ] && info "install output: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after installing v2"
        return
    }
    marker=$(_marker)
    if [ "$marker" = "v2" ]; then
        ok "installed update is running (marker v2)"
    else
        bad "expected v2 after installing and booting the spare, got '$marker'"
        return
    fi
    _ssh "nohup sh -c '$(_commit_cmd)' >/tmp/commit.log 2>&1 &" || true
    sleep 1
    virsh destroy "$VM" >/dev/null 2>&1 || true
    sleep 3
    virsh start "$VM" >/dev/null 2>&1 || true
    if _wait_ssh 300; then
        ok "B: survived a mid-commit power cut — booted slot marker '$(_marker)'"
    else
        bad "B: BRICKED — no boot after a mid-commit power cut (disqualifying)"
        return
    fi

    # Operator-initiated rollback: a release can be bad without failing its health check, so the
    # operator must be able to put the previous version back on demand — not only wait for an
    # automatic fallback.
    info "operator-initiated rollback"
    marker=$(_marker)
    _ssh "$(_rollback_cmd)" >/dev/null 2>&1 || true
    sleep 10
    if _wait_ssh 300; then
        local after
        after=$(_marker)
        if [ -n "$after" ] && [ "$after" != "$marker" ]; then
            ok "operator rollback works on demand ($marker -> $after)"
        else
            bad "operator rollback did not change the running slot (still '$after')"
        fi
    else
        bad "guest did not return after an operator-initiated rollback"
        return
    fi

    # The box must still be updatable afterwards, not merely alive.
    local out
    if out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1"); then
        ok "still updatable after fault injection"
    else
        bad "no longer accepts an update after fault injection: $(printf '%s' "$out" | tail -1 | cut -c1-90)"
    fi
}

require_host
case "$PHASE" in
boot) phase_boot ;;
update) phase_update ;;
fault) phase_fault ;;
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
