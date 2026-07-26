#!/usr/bin/env bash
# Tier-4 appliance harness (#77 phase 2): boot the pithead-os image in KVM and prove the
# properties only real firmware + a real A/B updater can show — EFI boot, the first-boot wizard
# window, and the update/commit/rollback cycle that is the phase-2 exit criterion. This is the
# os-image sibling of tests/integration/run.sh; it needs a Linux host with KVM + libvirt + the
# built image, so it runs on the bench, not in CI.
#
#   tests/os/run.sh --image PATH [--keep] [--phase boot|update|install|provision|fault|all]
#
# Phases:
#   boot    flash the image to a scratch disk, boot it, assert EFI boot + firstboot wizard up
#   update  build a v2 bundle; install, boot the spare, auto-rollback uncommitted, commit, and
#           roll back off a committed version. Also asserts /data grew to the disk (#784).
#   install boot the image as removable media beside a blank disk, run the disk installer, then
#           boot from the target and prove the copied system is COMPLETE (the /var overlay made
#           an incomplete copy easy to produce and invisible to every other phase). Then the
#           reinstall leg: /data must survive a second install over the same disk.
#   provision submit a config through the wizard's real HTTP flow and require the STACK to come
#           up — wizard accepted, setup ran, images pulled and verified, containers running,
#           dashboard served. This is the phase that catches an appliance whose engine cannot
#           actually run the product (it happened: pithead speaks docker, the image had only
#           podman, and every other phase was green).
#   fault   power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is disqualifying.
#   all     all four (default)
#
# Exit non-zero on the first failed assertion. --keep leaves the VM + disks for inspection.
set -uo pipefail

IMAGE=""
KEEP=0
PHASE="all"

VM="pithead-os-test"
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
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-build.log 2>&1 || return 1
    os/rauc/mkimage.sh >>/tmp/os-fault-build.log 2>&1 || return 1
    printf 'os/rauc/build/system.img'
}

# Build an update bundle carrying $1 as its marker.
_build_bundle() {
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-bundle.log 2>&1 || return 1
    os/rauc/mkbundle.sh >>/tmp/os-fault-bundle.log 2>&1 || return 1
    find os/rauc/build -name '*.raucb' | head -1
}

# Dev signing material, shared by both candidates so the comparison stays updater-only.
CERT_DIR="os/certs-test"
# A ROOT + LEAF chain, not a single self-signed cert. Rugix enforces proper X.509 semantics and
# rejects a CA certificate used as the end entity ("CaUsedAsEndEntity"); RAUC accepts the same
# certificate as both root and signer. The stricter reading is the right one, and it is also what
# production wants: the root that devices trust should not be the key that signs day to day.
_gen_certs() {
    [ -s "$CERT_DIR/cert.pem" ] && return 0
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:4096 -nodes -keyout "$CERT_DIR/ca.key" \
        -out "$CERT_DIR/ca.pem" -days 3650 -subj "/CN=pithead-os-test-ca" \
        -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null || return 1
    openssl req -newkey rsa:4096 -nodes -keyout "$CERT_DIR/key.pem" \
        -out "$CERT_DIR/leaf.csr" -subj "/CN=pithead-os-test-signer" 2>/dev/null || return 1
    openssl x509 -req -in "$CERT_DIR/leaf.csr" -CA "$CERT_DIR/ca.pem" -CAkey "$CERT_DIR/ca.key" \
        -CAcreateserial -out "$CERT_DIR/cert.pem" -days 3650 \
        -extfile <(printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n') \
        2>/dev/null || return 1
}

# Bundles are signed with the dev chain and RAUC verifies them against the keyring baked into the
# slot, so nothing but the bundle itself needs staging.
_stage_bundle() { # $1 bundle path
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$1" "root@$ip:/data/update.bundle"
}

# Per-updater command vocabulary — the ONLY updater-specific part of the battery.
#
# NOTE RAUC refuses unsigned bundles, which is correct — the battery signs with the development
# chain generated below and verification runs for real. Production signs with the release key; see
# the signing section of the plan.
_install_cmd() {
    printf 'rauc install %s' "$1"
}
_commit_cmd() {
    printf 'rauc status mark-good'
}
# Booting the newly written slot. RAUC arms the GRUB try-counter during install, so a plain
# reboot already lands on it.
_boot_spare_cmd() {
    printf 'reboot'
}
# The normal update path an operator would take: install and end up running the new version.
_install_and_boot_cmd() {
    printf 'rauc install %s && systemctl reboot' "$1"
}
# Operator-initiated rollback: the "put it back" button, distinct from automatic fallback.
_rollback_cmd() {
    printf 'rauc status mark-bad booted && reboot'
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

# A stray VM on the same libvirt network can take the DHCP lease the harness then reads back,
# so the battery silently drives someone else's guest. This happened with a hand-started
# diagnostic VM and produced passing legs that proved nothing. Refuse to run rather than report.
require_clean_bench() {
    local strays
    strays=$(virsh list --name 2>/dev/null | grep -E '^pithead-' | grep -v "^${VM}$" || true)
    [ -z "$strays" ] || {
        echo "refusing to run: other pithead VMs are on the bench and can steal the lease:" >&2
        echo "$strays" >&2
        echo "destroy them first (virsh destroy <name>; virsh undefine <name> --nvram)" >&2
        exit 2
    }
}

vm_destroy() {
    virsh destroy "$VM" >/dev/null 2>&1 || true
    virsh undefine "$VM" --nvram >/dev/null 2>&1 || true
}

cleanup() {
    # Preserve the console on failure. It is deleted with everything else on a green run, which
    # meant the one artefact that explains a boot failure was destroyed by the failure itself.
    if [ "$FAIL" -gt 0 ] && [ -s "$SERIAL" ]; then
        cp "$SERIAL" "$SERIAL.failed" 2>/dev/null &&
            info "console from the failed run kept at $SERIAL.failed"
    fi
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
    # Grow the scratch disk before first boot: the image ships only the ESP and slot A, and
    # systemd-repart creates slot B and /data on whatever disk it finds. A 40 GiB disk leaves
    # /data around 24 GiB, which the update phase asserts.
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
    # Grow the scratch disk before first boot: the image ships only the ESP and slot A, and
    # systemd-repart creates slot B and /data on whatever disk it finds. A 40 GiB disk leaves
    # /data around 24 GiB, which the update phase asserts.
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
    # NO local _ssh/_wait_ssh redefinitions here. Function definitions are global but locals are
    # not: a redefinition capturing a local outlives the phase, and the NEXT phase in an
    # --phase all run then calls it with the variable gone — an unbound-variable crash that no
    # standalone phase run can ever reproduce. The top-level helpers already do this job.
    local ip="" marker bundle

    info "building v1 test image (test SSH key + marker v1)"
    local img
    img=$(_build_image v1) || {
        bad "v1 test image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 ||
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

    # #784: /data must fit the MACHINE, not the image. The image ships ~9 GiB with no data
    # partition at all; systemd-repart creates it on the target disk at first boot. The harness
    # grows the scratch disk to 40 GiB, so a correct grow leaves /data well above 15 GiB — an
    # image-sized or unresized /data would land near zero and is the bug this asserts against.
    local data_gib
    data_gib=$(_ssh "df -BG --output=size /data 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$data_gib" ] && [ "$data_gib" -ge 15 ]; then
        ok "/data grew to fill the disk (${data_gib} GiB of a 40 GiB disk)"
    else
        bad "/data did not grow to fill the disk (got '${data_gib:-none}' GiB, want >= 15)"
    fi
    # The slots must NOT have grown — an A/B pair has to stay interchangeable.
    local slot_gib
    slot_gib=$(_ssh "df -BG --output=size / 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$slot_gib" ] && [ "$slot_gib" -le 5 ]; then
        ok "system slot stayed fixed at ${slot_gib} GiB"
    else
        bad "system slot grew to '${slot_gib:-none}' GiB — slots must stay interchangeable"
    fi

    info "building v2 update bundle (marker v2)"
    bundle=$(_build_bundle v2) || {
        bad "v2 bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    [ -n "$bundle" ] || {
        bad "no update bundle produced"
        return
    }
    ok "built v2 bundle: $(basename "$bundle")"

    # Install failures MUST be surfaced. Both candidates failed silently for several rounds
    # because the install was fired with `|| true` and only the marker was checked afterwards —
    # the harness reported "update did not take" when the real story was "install never ran".
    _install_or_fail() { # $1 human label
        local out
        out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1")
        local rc=$?
        [ -n "$out" ] && printf '     install output (%s): %s\n' "$1" "$(printf '%s' "$out" | tail -5)"
        return $rc
    }

    info "leg 1 — install v2, boot spare, reboot WITHOUT commit -> must fall back to v1"
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the guest failed"
        return
    }
    _install_or_fail "leg 1" || {
        bad "the v2 install command failed on the guest"
        return
    }
    ok "v2 installed into the spare slot"
    _ssh "$(_boot_spare_cmd)" || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after booting the spare slot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "spare slot booted with v2" || {
        bad "expected v2 in the spare slot, got '$marker'"
        return
    }
    _ssh reboot || true # uncommitted -> the bootloader must fall back on its own
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the no-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an uncommitted update reverts to v1 on reboot" || {
        bad "expected v1 after the uncommitted reboot, got '$marker'"
        return
    }

    info "leg 2 — install v2 again, COMMIT, reboot -> must stay v2"
    _install_or_fail "leg 2" || {
        bad "the second v2 install failed on the guest"
        return
    }
    _ssh "$(_boot_spare_cmd)" || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after the second install"
        return
    }
    _ssh "$(_commit_cmd)" || {
        bad "commit failed ($(_commit_cmd))"
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

    info "leg 3 — operator-initiated rollback off a committed update"
    _ssh "$(_rollback_cmd)" || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned after an operator rollback"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an operator can return to v1 after committing v2" ||
        bad "expected v1 after the operator rollback, got '$marker'"
}

phase_install() {
    info "phase: disk install (USB-style boot -> pithead-install -> boot from the target)"
    local img target_disk="/srv/code/bench-vm/pithead-target.img" out marker

    info "building the installer image (test SSH key + marker v1)"
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }

    vm_destroy
    rm -f "$target_disk"
    cp "$img" "$DISK"
    # 16G, the smallest real stick the docs allow: ESP + two 4 GiB slots + data's 4 GiB minimum
    # must fit or repart creates nothing and the guest lands in an emergency shell — which is
    # exactly what this sizing proves cannot happen on supported media.
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    # The target: blank, larger than the source medium, so the grow assertions distinguish the
    # two disks beyond doubt.
    qemu-img create -f raw "$target_disk" 30G >/dev/null
    : >"$SERIAL"
    # The image rides a USB bus with removable=on — that is what makes the guest a faithful
    # analog of a user's stick: the host-side gate (installer_mode_available) keys on
    # /sys/block/*/removable, which virtio never sets.
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the installer VM"
        return
    }
    ip=""
    local tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 40 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    _wait_ssh 240 || {
        bad "installer guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots as removable media ($ip)"

    out=$(_ssh "pithead-install --list")
    if printf '%s' "$out" | cut -f1 | grep -qx "vda"; then
        ok "inventory offers the internal disk (vda)"
    else
        bad "inventory does not offer vda — got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
        return
    fi
    # The boot medium must never be a target. It shows up as sdX on the USB bus.
    if printf '%s' "$out" | cut -f1 | grep -qE '^sd'; then
        bad "inventory offers the boot medium itself"
        return
    fi
    ok "inventory excludes the disk the system booted from"
    # The host wizard loop must be in installer mode — the same gate a real stick hits.
    if _ssh "test -s /data/pithead/data/firstboot/disks.tsv"; then
        ok "firstboot entered installer mode (inventory published to the spool)"
    else
        bad "firstboot did not publish a disk inventory — installer mode never engaged"
    fi

    out=$(_ssh "pithead-install --target /dev/vda --yes 2>&1")
    if [ $? -eq 0 ]; then
        ok "install to /dev/vda completed"
    else
        bad "install failed: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
        return
    fi

    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    # Boot from the TARGET alone — the stick is gone, exactly as the instructions tell the user.
    : >"$SERIAL"
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the installed VM"
        return
    }
    ip=""
    tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 40 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    _wait_ssh 300 || {
        bad "installed system never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "installed system boots from the internal disk"

    # findmnt reports the by-partlabel symlink the cmdline named; resolve to the parent disk
    # before comparing, or the assertion fails on a correctly installed system.
    local rootdev
    rootdev=$(_ssh "lsblk -no PKNAME \$(findmnt -no SOURCE /)" | head -1)
    if [ "$rootdev" = "vda" ]; then
        ok "root is on the target disk, not a leftover medium"
    else
        bad "root is on '${rootdev:-unknown}' — expected the target disk (vda)"
    fi
    # THE assertion this phase exists for: the copy must include the slot's real /var, which the
    # overlay mount hides from a naive copy of /. An installed machine without a dpkg database
    # is subtly broken in ways no boot banner reveals.
    if _ssh "test -s /var/lib/dpkg/status"; then
        ok "copied system is complete (/var/lib/dpkg survived the overlay)"
    else
        bad "/var/lib/dpkg/status missing — the copy lost the slot's /var"
    fi
    if _ssh "test -s /etc/machine-id"; then
        ok "machine-id regenerated on the installed system"
    else
        bad "machine-id empty — identity was not regenerated"
    fi
    local data_gib
    data_gib=$(_ssh "df -BG --output=size /data 2>/dev/null | tail -1 | tr -dc '0-9'")
    if [ -n "$data_gib" ] && [ "$data_gib" -ge 15 ]; then
        ok "repart built /data on the target's own disk (${data_gib} GiB of 30)"
    else
        bad "/data on the target is '${data_gib:-none}' GiB — repart did not size it to the disk"
    fi
    _wizard_up() { # shared by both legs — first boots must load the wizard image first
        local wtries=0
        while [ "$wtries" -lt 36 ]; do
            curl -fsS -m 5 "http://$ip/" 2>/dev/null | grep -qi "Pithead setup" && return 0
            sleep 5
            wtries=$((wtries + 1))
        done
        return 1
    }
    if _wizard_up; then
        ok "setup wizard serves on the installed system"
    else
        bad "no setup wizard on :80 of the installed system within 180s"
    fi

    # ---- reinstall leg: the path that must NOT lose data --------------------------------
    # A disk that already carries a pithead layout is reinstalled in place: the system slot is
    # replaced, /data — the wallets and the synced chain — survives. This is the promise that
    # costs a user days of re-syncing if it breaks, so it gets its own leg: plant a sentinel in
    # /data, reinstall over the disk, and require the sentinel afterwards.
    info "reinstall leg — a second install over the same disk must preserve /data"
    _ssh "echo chain-data-survives > /data/pithead/reinstall-sentinel" || {
        bad "could not plant the reinstall sentinel"
        return
    }
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    : >"$SERIAL"
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the reinstall boot"
        return
    }
    ip=""
    tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 40 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    _wait_ssh 240 || {
        bad "installer guest never answered SSH for the reinstall leg"
        return
    }
    if _ssh "pithead-install --list" | grep -q "pithead-with-data"; then
        ok "inventory recognises the installed disk (pithead-with-data)"
    else
        bad "inventory does not flag the installed disk as carrying data"
    fi
    out=$(_ssh "pithead-install --target /dev/vda --yes 2>&1")
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q "preserving its data partition"; then
        ok "reinstall took the preserve path"
    else
        bad "reinstall did not preserve: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140)"
        return
    fi
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    : >"$SERIAL"
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the reinstalled system"
        return
    }
    ip=""
    tries=0
    while [ -z "$ip" ] && [ "$tries" -lt 40 ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] || sleep 3
        tries=$((tries + 1))
    done
    _wait_ssh 300 || {
        bad "reinstalled system never answered SSH"
        return
    }
    ok "reinstalled system boots"
    if [ "$(_ssh cat /data/pithead/reinstall-sentinel)" = "chain-data-survives" ]; then
        ok "REINSTALL PRESERVED /data — the sentinel survived"
    else
        bad "REINSTALL LOST /data — the sentinel is gone (this is the chain-eating bug)"
    fi
    if _ssh "test -s /var/lib/dpkg/status"; then
        ok "reinstalled system copy is complete"
    else
        bad "/var/lib/dpkg/status missing after reinstall"
    fi
    if _wizard_up; then
        ok "wizard serves after the reinstall"
    else
        bad "no wizard on :80 after the reinstall"
    fi
    rm -f "$target_disk"
}

phase_provision() {
    info "phase: provision (wizard HTTP submit -> setup -> stack containers up)"
    local img token jar body

    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots ($ip)"

    # The wizard's one-time token, exactly where a human gets it: the console.
    local tries=0
    token=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        return
    }
    ok "one-time token read from the console ($token)"
    tries=0
    while ! curl -fsS -m 5 "http://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries=$((tries + 1))
        [ "$tries" -lt 24 ] || {
            bad "wizard gate never served on :80"
            return
        }
    done

    jar=$(mktemp)
    curl -fsS -c "$jar" -d "token=$token" "http://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    # Minimal honest config: a well-formed (dummy) primary Monero address, Monero-only mining.
    # Everything else keeps its default — which is itself part of what this proves.
    # Both addresses are required — Monero's has a format gate (95 chars, leading 4), Tari's is
    # deliberately format-free host-side, so a labelled dummy passes and stays obviously fake.
    body="monero_wallet=4$(printf 'A%.0s' $(seq 1 94))&tari_wallet=harness-dummy-tari-address&pool=mini"
    curl -fsS -b "$jar" --data "$body" "http://$ip/submit" -o /dev/null 2>/dev/null || {
        bad "config submit failed"
        rm -f "$jar"
        return
    }
    rm -f "$jar"
    ok "config submitted through the wizard"

    # The host validates, installs config.json, and runs setup — which pulls the release images
    # (cosign-verified) and starts the stack. Pulls are the slow part; be generous.
    if ! _ssh "for i in \$(seq 120); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the submitted config never became /data/pithead/config.json (validation output: $(_ssh "cat /data/pithead/data/firstboot/error.txt 2>/dev/null" | cut -c1-120))"
        return
    fi
    ok "config validated and installed by the host"

    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack containers are running (podman: $names)"
        ;;
    *)
        bad "stack never came up within 25m — running: '${names:-none}'"
        info "  setup journal tail: $(_ssh "journalctl -u pithead-firstboot -n 5 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
        return
        ;;
    esac
    # Caddy fronts the dashboard once the wizard's window closes; self-signed on :443 by default.
    # Status-based on purpose: the landing response may be a redirect to the login page or an
    # auth challenge, both empty-bodied — any well-formed HTTP answer proves caddy is proxying.
    # The window covers the dashboard's healthcheck start period, not just its process start.
    tries=0
    local code=000 served=0
    while [ "$tries" -lt 60 ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || echo 000)
        case "$code" in
        2?? | 3?? | 401 | 403)
            ok "dashboard is served through caddy (HTTP $code)"
            served=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    if [ "$served" -ne 1 ]; then
        bad "no HTTP answer behind caddy on :443 within 5m (last: $code)"
        return
    fi

    # ---- reboot leg: the provisioned stack must return UNAIDED ---------------------------
    # Docker's daemon restores restart-policy containers implicitly; podman only does it with
    # podman-restart.service — which was missing once, and the failure mode is exactly a mining
    # appliance that sits dark after every power blip until a human logs in. Nothing may drive
    # the recovery here: no pithead command, no wizard. Reboot, wait, demand the stack.
    info "reboot leg — the stack must come back on its own (podman-restart)"
    _ssh reboot 2>/dev/null || true
    sleep 10
    _wait_ssh 300 || {
        bad "guest never returned from the reboot"
        return
    }
    local deadline2=$(($(date +%s) + 420)) names2=""
    while [ "$(date +%s)" -lt "$deadline2" ]; do
        names2=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names2" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 10
    done
    case "$names2" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack returned after reboot with no hands on it (podman: $names2)"
        ;;
    *)
        bad "stack did NOT return after a reboot — running: '${names2:-none}'"
        return
        ;;
    esac
    tries=0
    while [ "$tries" -lt 36 ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || echo 000)
        case "$code" in
        2?? | 3?? | 401 | 403)
            ok "dashboard answers again after the reboot (HTTP $code)"
            return
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    bad "dashboard never answered after the reboot (last: $code)"
}

phase_fault() {
    info "phase: fault injection — a brick is disqualifying, not deducted"
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
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the guest failed"
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

    # Fault C: hand the updater a CORRUPTED bundle. Three power cuts just landed on this guest,
    # so a damaged download is exactly what a real box would be holding. The bar is a clean
    # refusal — refusing to install is correct, crashing is not, and bricking is disqualifying.
    info "fault C — install a deliberately corrupted bundle"
    _ssh "dd if=/dev/urandom of=/data/update.bundle bs=1M seek=8 count=2 conv=notrunc" >/dev/null 2>&1 || true
    out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1" || true)
    if printf '%s' "$out" | grep -qi "panic"; then
        bad "C: the updater PANICKED on a corrupt bundle instead of refusing it"
        info "  $(printf '%s' "$out" | grep -i panic | head -1 | cut -c1-150)"
    else
        ok "C: a corrupt bundle is refused without crashing"
    fi
    if _wait_ssh 300; then
        ok "C: still boots after being handed a corrupt bundle (marker '$(_marker)')"
    else
        bad "C: BRICKED by a corrupt bundle (disqualifying)"
        return
    fi

    # Fault B: cut power during the commit itself, the smallest and most dangerous window.
    # Re-stage first: the bundle on /data has just survived three power cuts and been corrupted
    # on purpose, and this leg is measuring the commit window, not bundle integrity.
    info "installing v2 fully, then destroying mid-commit"
    _stage_bundle "$bundle" || {
        bad "re-staging the bundle before the commit test failed"
        return
    }
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

    # The box must still be updatable afterwards, not merely alive. Commit first: an operator who
    # has just rolled back to a known-good version would mark it good before updating again, and
    # Rugix correctly refuses to install onto a system that has not yet verified its own boot
    # ("system needs to be committed before installing an update"). Skipping the commit tested an
    # operator nobody is, and scored a safety feature as a failure.
    local out
    _ssh "$(_commit_cmd)" >/dev/null 2>&1 || true
    if out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1"); then
        ok "still updatable after fault injection"
    else
        bad "no longer accepts an update after fault injection"
        printf '%s\n' "$out" | tail -12 | sed 's/^/       /'
    fi
}

require_host
require_clean_bench
case "$PHASE" in
boot) phase_boot ;;
update) phase_update ;;
install) phase_install ;;
provision) phase_provision ;;
fault) phase_fault ;;
all)
    phase_boot
    phase_update
    phase_install
    phase_provision
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
