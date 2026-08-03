#!/usr/bin/env bash
# Tier-4 appliance harness (#77 phase 2): boot the pithead-os image in KVM and prove the
# properties only real firmware + a real A/B updater can show — EFI boot, the first-boot wizard
# window, and the update/commit/rollback cycle that is the phase-2 exit criterion. This is the
# os-image sibling of tests/integration/run.sh; it needs a Linux host with KVM + libvirt + the
# built image, so it runs on the bench, not in CI.
#
#   tests/os/run.sh --image PATH [--keep] [--phase boot|update|install|provision|rig|fault|all]
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
#   rig     answer "RigForge" on the same page and prove the OTHER machine this image installs:
#           mines from the baked binary with no compile and no stack at all, and takes an A/B
#           update — install, uncommitted rollback, self-commit — exactly like a coordinator.
#   fault   power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is disqualifying.
#   all     all five (default)
#
# A failed assertion is recorded and the run continues, so one bench boot collects the whole
# battery rather than stopping at the first fault; the run exits non-zero if any assertion failed.
# --keep leaves the VM + disks for inspection.
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

# The wallet every phase submits. It must be checksum-VALID: p2pool refuses a well-formed but
# checksum-invalid address at startup with a SIGABRT and crash-loops (#829), which killed the
# provision phase's whole miner chain when the harness used `4` + 94×`A`. Host-side validation
# only checks the shape, so the crash is the first honest verdict. XMRig's public donation
# address: obviously not ours, plainly labelled, and any share it ever earned would be a donation.
HARNESS_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"

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

# The marker baked INTO the dashboard image and served by whatever container actually answers
# (/static/os-test-marker.txt, stamped by os/build-image.sh on harness builds). Distinct from
# /etc/pithead-test-marker, which only names the OS slot: the image tag is identical across
# builds, so this is the one signal that separates "new OS, new containers" from the #798
# failure — new OS, stale containers, every other check green. $1 expected, $2 seconds.
_dash_marker_served() {
    local want="$1" deadline=$(($(date +%s) + ${2:-300})) got=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got=$(curl -fsSk -m 5 "https://$ip/static/os-test-marker.txt" 2>/dev/null)
        [ "$got" = "$want" ] && return 0
        sleep 5
    done
    printf '%s' "${got:-nothing}"
    return 1
}

# Build a bootable image carrying $1 as its slot marker, for the selected updater.
_build_image() {
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -q
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-build.log 2>&1 || return 1
    os/rauc/mkimage.sh --dev >>/tmp/os-fault-build.log 2>&1 || return 1
    # Every image a phase boots gets the static verification first, in --test mode. The check
    # that matters most is the archive-vs-tree comparison: stale wizard images reached three
    # benches through caching bugs, and this layer catches the next one before a 25-minute
    # phase runs against it.
    tests/os/verify-image.sh os/rauc/build/system.img --test >>/tmp/os-fault-build.log 2>&1 || {
        echo "verify-image failed on the freshly built image (see /tmp/os-fault-build.log)" >&2
        return 1
    }
    printf 'os/rauc/build/system.img'
}

# Build an update bundle carrying $1 as its marker.
_build_bundle() {
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-bundle.log 2>&1 || return 1
    os/rauc/mkbundle.sh --dev >>/tmp/os-fault-bundle.log 2>&1 || return 1
    find os/rauc/build -name '*.raucb' | head -1
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
    [ -n "$ip" ] || {
        bad "wizard not reachable — the VM never took a DHCP lease"
        return
    }
    # The console announcement fires when the wizard CONTAINER starts (`podman run -d` returns),
    # not when the Python server inside has bound its sockets — so the gate answers a little
    # after the token prints. Measured: zero on an idle host (two clean single-phase runs
    # answered the first probe), but 2 of 3 full-battery runs on the same image flaked here —
    # the gap only opens when the host is loaded, which is exactly when batteries run. A human
    # operator never sees it because reading the token and typing the URL takes longer. Same
    # retry shape as every other wizard probe in this file.
    tries=0
    while ! curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries=$((tries + 1))
        [ "$tries" -lt 24 ] || {
            bad "wizard never served the token gate ($ip)"
            return
        }
    done
    ok "wizard serves the token gate ($ip, ready after ~$((tries * 5))s)"
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
    # Baseline for the stale-container check below: the v1 image must serve its own marker
    # BEFORE any update, or a later "v2 never served" says nothing about staleness.
    local dm
    if dm=$(_dash_marker_served v1 300); then
        ok "the served page comes from the v1 dashboard image"
    else
        bad "the v1 dashboard image never served its marker (got: $dm)"
        return
    fi

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
    # THE stale-container assertion: the OS slot saying v2 is not enough — an A/B update that
    # ships a new dashboard must end with the NEW image answering, without any wizard
    # involvement. The tag never changes and podman's store survives on /data, so only the
    # boot-path loader can make this true.
    if dm=$(_dash_marker_served v2 360); then
        ok "UPDATE REFRESHED THE CONTAINERS: the served page comes from the v2 dashboard image"
    else
        bad "the OS updated to v2 but the served page still comes from the old dashboard image (got: $dm)"
    fi

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
    # Poll: firstboot loads the wizard image from its tarball BEFORE publishing the inventory,
    # which takes about a minute on a first boot. Checking the moment SSH answers is a race the
    # standalone runs happened to win and the full gate lost.
    if _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1"; then
        ok "firstboot entered installer mode (inventory published to the spool)"
    else
        bad "firstboot did not publish a disk inventory — installer mode never engaged"
    fi

    # ---- the combined web flow, exactly as an operator drives it -------------------------
    # ONE page: config + disk + typed confirmation in one submission; the host validates
    # everything, publishes the credentials, and only the ack releases the erase. The machine
    # then installs, stages the accepted config for the target, and powers itself off.
    local token="" jar scode
    local tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token on the installer console"
        return
    }
    ok "one-time token read from the installer console ($token)"
    # The token prints before the container finishes coming up — wait for the gate to SERVE
    # before authing, exactly as the provision phase does (and as a human's browser would).
    tries2=0
    while ! curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries2=$((tries2 + 1))
        [ "$tries2" -lt 24 ] || {
            bad "installer wizard never served its gate page"
            return
        }
    done
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "installer wizard auth failed"
        rm -f "$jar"
        return
    }
    local body
    body="monero_wallet=$HARNESS_WALLET&tari_wallet=harness-dummy-tari-address&pool=mini&disk=vda&confirm=vda&wipe=keep"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "combined submit (config + disk) did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    ok "ONE submission carried config + disk + confirmation"
    tries2=0
    while [ "$tries2" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    [ "$tries2" -lt 24 ] || {
        bad "credentials never published on the installer page — the erase would be releasable blind"
        rm -f "$jar"
        return
    }
    ok "credentials published BEFORE anything touched the disk"
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    # The ack releases the erase; the machine installs and powers ITSELF off.
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "machine installed and switched itself off"
    else
        bad "machine never powered off after the ack"
        return
    fi
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
            curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup" && return 0
            sleep 5
            wtries=$((wtries + 1))
        done
        return 1
    }
    # The staged config makes the first boot HEADLESS: the machine provisions itself and no
    # second wizard ever serves. The full stack-up is the provision phase's job; here we prove
    # the config arrived and provisioning began.
    if _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        ok "staged config crossed to the installed system (headless provisioning began)"
    else
        bad "the config confirmed on the installer page never reached the installed system"
    fi
    if _ssh "journalctl -u pithead-firstboot -b --no-pager 2>/dev/null | grep -q pre-seeded"; then
        ok "installed system took the pre-seed path — no second wizard, no second token"
    else
        bad "installed system did not take the pre-seed path"
    fi
    # And no plaintext copy lingers: the staged file carried the dashboard password across, and
    # once consumed it must not sit on the installed machine's unencrypted ESP forever.
    if _ssh "test -f /boot/efi/pithead-config.json"; then
        bad "the consumed pre-seed (with credentials) is still on the installed system's ESP"
    else
        ok "consumed pre-seed removed from the installed system's ESP"
    fi

    # ---- reinstall leg: the path that must NOT lose data --------------------------------
    # A disk that already carries a pithead layout is reinstalled in place: the system slot is
    # replaced, /data — the wallets and the synced chain — survives. This is the promise that
    # costs a user days of re-syncing if it breaks, so it gets its own leg: plant a sentinel in
    # /data, reinstall over the disk, and require the sentinel afterwards.
    info "reinstall leg — a second install over the same disk must preserve /data"
    _ssh "echo chain-data-survives > /data/pithead/reinstall-sentinel &&
          mkdir -p /data/pithead/data/monero /data/pithead/data/tari &&
          echo synced-chain > /data/pithead/data/monero/chain-sentinel &&
          echo synced-chain > /data/pithead/data/tari/chain-sentinel" || {
        bad "could not plant the reinstall sentinels"
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
    # ---- reinstall pre-fill: the previous machine's answers, never its secrets ----------
    # The host mounted the target's data partition read-only at wizard start and published
    # the stripped previous config as the page's pre-fill. Two assertions, both through the
    # page's own state API: the first leg's wallet came back, and no password crossed. Runs
    # BEFORE the wipe legs on purpose — they destroy the config the pre-fill was read from.
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    if [ -n "$token" ] && _wizard_up; then
        jar=$(mktemp)
        local pf_state=""
        curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
            pf_state=$(curl -fsSk -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null)
        rm -f "$jar"
        if printf '%s' "$pf_state" | grep -q "\"wallet_address\": \"${HARNESS_WALLET:0:8}"; then
            ok "pre-fill carries the previous install's wallet"
        else
            bad "the previous install's answers did not pre-fill the reinstall page"
        fi
        # The provisioned config held a generated dashboard password; the merged state may
        # only ever show the reference's empty default for any "password" key.
        if printf '%s' "$pf_state" | grep -Eq '"password": "[^"]'; then
            bad "a password crossed into the reinstall page's state"
        else
            ok "no password reaches the reinstall page"
        fi
    else
        bad "no wizard session for the pre-fill check (token: ${token:-none})"
    fi
    # ---- wipe legs: the three-way reinstall data choice, asserted on the raw partition ----
    # Mounted from the installer VM (the target's data partition is vda4) rather than booting
    # between legs — the assertion is about what is ON the disk, and this keeps three slot
    # copies instead of three full boot cycles.
    info "wipe=data — user data goes, the synced chains stay"
    out=$(_ssh "pithead-install --target /dev/vda --wipe data --yes 2>&1")
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q "preserving the synced chains"; then
        ok "wipe=data took the selective path"
    else
        bad "wipe=data failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140)"
        return
    fi
    # The mountpoint comes from mktemp: the appliance root is READ-ONLY, so a path like /mnt/t
    # cannot be created — mkdir's refusal was eaten by _ssh's stderr drop and read as a wipe bug.
    local wout
    wout=$(_ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" 2>&1 || { echo MOUNT-FAILED; exit 9; }
                 s=OK
                 test -s \"\$T/pithead/data/monero/chain-sentinel\" || s=NO-MONERO-CHAIN
                 test -s \"\$T/pithead/data/tari/chain-sentinel\" || s=\$s,NO-TARI-CHAIN
                 test -e \"\$T/pithead/reinstall-sentinel\" && s=\$s,USER-DATA-SURVIVED
                 umount \"\$T\" 2>&1 || s=\$s,UMOUNT-FAILED
                 echo \"verdict=\$s\"" 2>&1)
    if printf '%s' "$wout" | grep -q "verdict=OK"; then
        ok "wipe=data KEPT both chains and dropped the user data"
    else
        bad "wipe=data got the split wrong: $(printf '%s' "$wout" | tr '\n' ' ' | cut -c1-300)"
        return
    fi
    info "wipe=all — the data partition is reformatted"
    _ssh "umount -A /dev/vda4 2>/dev/null || true"
    out=$(_ssh "pithead-install --target /dev/vda --wipe all --yes 2>&1")
    if [ $? -eq 0 ] && printf '%s' "$out" | grep -q "everything, chains included"; then
        ok "wipe=all took the reformat path"
    else
        bad "wipe=all failed: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-140) [mounts: $(_ssh "findmnt -no SOURCE,TARGET | grep vda" | tr '\n' ' ')]"
        return
    fi
    if _ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" && [ -z \"\$(ls \"\$T\" | grep -v lost+found)\" ]; rc=\$?; umount \"\$T\"; exit \$rc"; then
        ok "wipe=all left an empty data partition"
    else
        bad "wipe=all left residue on the data partition"
        return
    fi
    # Re-plant the keep-leg sentinel on the now-empty partition, then prove the DEFAULT path.
    _ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" && mkdir -p \"\$T/pithead\" &&
          echo chain-data-survives > \"\$T/pithead/reinstall-sentinel\" && umount \"\$T\"" || {
        bad "could not re-plant the sentinel for the keep leg"
        return
    }
    _ssh "umount -A /dev/vda4 2>/dev/null || true"
    # A keep-reinstall must refresh the CONTAINERS too (#798). Model the machine that hit this
    # live: /data already carries a dashboard image under the release tag, with its digest
    # recorded beside the store — then reinstall from a NEWER stick. Only the digest-keyed
    # boot loader makes the image change; a tag-exists check keeps the old containers forever.
    info "keep leg prep — plant this build's dashboard image + digest record (a machine that ran it)"
    local old_dash_id=""
    # The plant must leave a store a REAL machine could have written. `podman --root` also
    # creates a libpod database (db.sql + libpod/) that records the mount path as the graph
    # root — and podman refuses a store whose recorded paths differ from its own, so the
    # reinstalled machine's every podman command died with "database configuration mismatch"
    # (invisible: _ssh drops stderr). A machine that ran the product wrote its db against
    # /data/containers/storage; dropping the plant's db models that machine — the first real
    # boot recreates it against the right paths, images intact.
    old_dash_id=$(_ssh "T=\$(mktemp -d) && mount /dev/vda4 \"\$T\" &&
          mkdir -p \"\$T/pithead/data\" \"\$T/containers/storage\" &&
          podman --root \"\$T/containers/storage\" load -qi /opt/pithead/images/dashboard.tar.gz >/dev/null &&
          sha256sum /opt/pithead/images/dashboard.tar.gz | cut -d' ' -f1 | tr -d '\n' >\"\$T/pithead/data/.loaded-dashboard.tar.gz.sha\" &&
          podman --root \"\$T/containers/storage\" images --format '{{.Repository}} {{.ID}}' | awk '/pithead-dashboard/{print \$2; exit}' &&
          rm -rf \"\$T/containers/storage/db.sql\" \"\$T/containers/storage/libpod\" &&
          umount \"\$T\"")
    [ -n "$old_dash_id" ] || {
        bad "could not plant the old dashboard image for the keep leg"
        return
    }
    ok "planted the old dashboard image ($old_dash_id) and its digest record on the target's /data"
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    info "building the NEWER stick (marker v2 — its dashboard archive differs)"
    img=$(_build_image v2) || {
        bad "v2 stick build failed (/tmp/os-fault-build.log)"
        return
    }
    cp "$img" "$DISK"
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    : >"$SERIAL"
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the newer-stick keep-reinstall boot"
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
        bad "newer stick never answered SSH for the keep leg"
        return
    }
    ok "newer stick boots as removable media"
    _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1" || {
        bad "the newer stick never published a disk inventory"
        return
    }
    # The keep path goes through the PAGE, exactly as an operator would: a bare submit with the
    # disk and wipe=keep — no config, because the survivor config wins. No credentials card may
    # appear (the machine keeps its old login; a regenerated one here was a real bench bug).
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "no token for the keep-reinstall leg"
        return
    }
    # Fresh boot: the token prints before the wizard container finishes coming up.
    tries2=0
    while ! curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries2=$((tries2 + 1))
        [ "$tries2" -lt 36 ] || {
            bad "the newer stick's wizard never served its gate page"
            return
        }
    done
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "keep-reinstall auth failed"
        rm -f "$jar"
        return
    }
    scode=$(curl -sSk -b "$jar" --data "disk=vda&confirm=vda&wipe=keep" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "keep-reinstall submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    sleep 3
    hcode=$(curl -sSk -b "$jar" -o /dev/null -w '%{http_code}' -m 5 "https://$ip/api/handoff" 2>/dev/null)
    if [ "$hcode" = "404" ]; then
        ok "keep-reinstall shows NO credentials card — the machine keeps its old login"
    else
        bad "a handoff appeared on a keep reinstall (HTTP $hcode) — its password would be a lie"
    fi
    rm -f "$jar"
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "keep-reinstall installed and switched itself off"
    else
        bad "keep-reinstall never powered off"
        return
    fi
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
    # The keep-leg staleness assertions (#798): the dashboard image ID must have CHANGED — the
    # boot-path loader keyed on the newer stick's archive digest, over a /data that already
    # held the old image under the same tag — and the page actually served must come from the
    # new image, not merely "some wizard answers".
    local new_dash_id dm
    new_dash_id=$(_ssh "podman images --format '{{.Repository}} {{.ID}}'" | awk '/pithead-dashboard/{print $2; exit}')
    if [ -n "$new_dash_id" ] && [ "$new_dash_id" != "$old_dash_id" ]; then
        ok "KEEP-REINSTALL REFRESHED THE DASHBOARD IMAGE ($old_dash_id -> $new_dash_id)"
    else
        bad "keep-reinstall left the old dashboard image in place (id: ${new_dash_id:-none}, was $old_dash_id)"
    fi
    if dm=$(_dash_marker_served v2 300); then
        ok "the served page comes from the NEWER stick's dashboard image"
    else
        bad "the reinstalled machine still serves the old dashboard image (got: $dm)"
    fi
    rm -f "$target_disk"
}

phase_provision() {
    info "phase: provision (wizard HTTP submit -> setup -> stack containers up)"
    local img token jar body scode

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
    while ! curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries=$((tries + 1))
        [ "$tries" -lt 24 ] || {
            bad "wizard gate never served on :80"
            return
        }
    done

    jar=$(mktemp)
    # https, and PROVE the cookie landed: auth against :80 once hit the new TLS redirect, whose
    # 301 carries no cookie — curl -f called that success, the jar stayed empty, and the
    # unauthenticated submit's redirect then ALSO read as success. Two phantom green checks in a
    # row while nothing was written. Status codes and the jar are asserted now, not inferred.
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    grep -q "wizard_session" "$jar" || {
        bad "auth returned no session cookie — the submit below would be silently unauthenticated"
        rm -f "$jar"
        return
    }
    # Minimal honest config: a checksum-valid primary Monero address (see HARNESS_WALLET — the
    # old dummy crash-looped p2pool, #829). Tari's gate is deliberately format-free host-side
    # and p2pool tolerates a bad merge-mine address, so a labelled dummy stays obviously fake.
    # Everything else keeps its default — which is itself part of what this proves.
    # local_miner=true: the Both role (#796) — the same submit must also light the built-in
    # RigForge worker, asserted in the local-miner leg below.
    body="monero_wallet=$HARNESS_WALLET&tari_wallet=harness-dummy-tari-address&pool=mini&local_miner=true"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "config submit did not return 200 (got ${scode:-none} — a 30x means the session was not accepted)"
        rm -f "$jar"
        return
    }
    # The jar lives on: the handoff below is authenticated too, and a real operator's session
    # does not end at submit. (Deleting it here made the handoff poll silently unauthenticated,
    # which read as "the appliance never published credentials" — it had.)
    ok "config submitted through the wizard"
    # The credentials handoff: the host publishes the generated login and HOLDS provisioning
    # until it is acknowledged — the page goes dark afterwards, so the card must come first.
    tries=0
    while [ "$tries" -lt 24 ]; do
        if curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"'; then
            ok "generated credentials published to the page"
            break
        fi
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no credentials handoff appeared on the page"
        rm -f "$jar"
        return
    }
    scode=$(curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "handoff acknowledgement did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    ok "handoff acknowledged — provisioning released"
    rm -f "$jar"
    if curl -sS -o /dev/null -w '%{http_code}' -m 5 "http://$ip/" 2>/dev/null | grep -q '^30'; then
        ok "plain :80 redirects to TLS rather than refusing"
    else
        bad "plain :80 does not redirect — an operator typing a bare address sees a dead port"
    fi

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

    # ---- Tor-only egress backstop (#855): the fail-closed firewall must actually DROP -------
    # The whole product is Tor-first; the guarantee is that nothing CAN bypass Tor even if an app
    # is misconfigured, compromised, or dials a raw public IP. On the appliance the engine is
    # podman+netavark, and the old DOCKER-USER rules land in a chain no forwarded packet traverses
    # — the firewall was fail-OPEN while doctor and the boot log called it enforced. This leg dials
    # clearnet FROM a mining-net container by raw IP and asserts the drop. It is the check whose
    # absence let a leaking appliance ship green: it FAILS against the orphaned-chain code and
    # PASSES once the nft table is installed. monerod sits on mining_net (172.28.0.x) and syncs
    # regardless of the mining hold, so it is the honest origin for the dial.
    if _ssh "podman exec monerod sh -c 'command -v curl' >/dev/null 2>&1"; then
        # NEGATIVE — a direct clearnet dial by IP must be DROPPED (curl times out, non-zero).
        if _ssh "podman exec monerod curl -s -o /dev/null -m 8 http://1.1.1.1/" 2>/dev/null; then
            bad "clearnet egress is FAIL-OPEN — monerod reached 1.1.1.1 directly, bypassing Tor (the firewall is not enforced)"
        else
            ok "direct clearnet dial from a mining container is dropped — Tor-only egress is enforced"
        fi
        # POSITIVE — the SAME container still reaches clearnet THROUGH Tor's SOCKS, proving the
        # drop spares Tor and intra-subnet traffic (real mining keeps working). Tor's default
        # SOCKS is 172.28.0.25:9050 on the appliance's mining_net.
        if _ssh "podman exec monerod curl -s -o /dev/null -m 30 --socks5-hostname 172.28.0.25:9050 http://1.1.1.1/" 2>/dev/null; then
            ok "egress through Tor's SOCKS still works — the drop did not break real mining"
        else
            bad "the mining container can no longer reach clearnet even through Tor — the firewall is too tight"
        fi
        # IPv6 backstop (#858): mining_net is IPv4-only by design, so monerod has no global v6 and
        # this leg self-skips on the stock appliance. If mining_net ever gains a v6 subnet, the
        # container CAN originate v6 clearnet — assert that dial is DROPPED too (the fail-open the
        # v4-only rules left behind). Guarded on the container actually holding a global v6 address.
        if _ssh "podman exec monerod sh -c 'ip -6 addr show scope global 2>/dev/null | grep -q inet6'" 2>/dev/null; then
            if _ssh "podman exec monerod curl -s -o /dev/null -m 8 -g 'http://[2606:4700:4700::1111]/'" 2>/dev/null; then
                bad "IPv6 clearnet egress is FAIL-OPEN — monerod reached a v6 address directly, bypassing Tor"
            else
                ok "direct IPv6 clearnet dial from a mining container is dropped — the v6 backstop holds"
            fi
        else
            ok "mining_net is IPv4-only (no global v6 in the container) — v6 clearnet dial not possible, backstop not exercised"
        fi
    else
        bad "monerod lacks curl — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
    fi

    # ---- local-miner leg (#796): enable -> xmrig up -> wired to the machine's own stratum ---
    # The submit above asked to mine on the box itself, so the built-in RigForge worker must
    # come up without any hands: setup renders its config, runs its appliance-mode setup, and
    # the miner dials the machine's own stratum.
    #
    # The leg used to demand an accepted share, and that end of the chain cannot exist here:
    # on a fresh machine the product itself HOLDS p2pool and xmrig-proxy until the local
    # chains sync (#35 — the dashboard logs the hold and stops both), and a KVM guest
    # syncing Monero over Tor onto a 40 GiB scratch disk never clears that gate. No budget
    # fixes a state the product enforces on purpose. The share assertion lives where a synced
    # node exists — the release e2e on the bench, which accepted in under two minutes the day
    # this leg was rewritten. What the harness CAN prove, it now does, link by link: the
    # miner runs, the hold is the deliberate one (p2pool stopped CLEAN — a crash-looping
    # p2pool, the #829 failure this leg first caught, dies non-zero under the same gate), and
    # the rendered worker config points at this machine's own stratum.
    local mtries=0 miner_up=0
    while [ "$mtries" -lt 36 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_up=1
            break
        fi
        sleep 10
        mtries=$((mtries + 1))
    done
    if [ "$miner_up" -eq 1 ]; then
        ok "built-in miner is up (xmrig unit active, process running)"
    else
        bad "the built-in miner never came up (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
        info "  local-miner journal tail: $(_ssh "journalctl -u pithead-firstboot -n 5 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"
    fi
    # The deliberate pre-sync state: the dashboard's sync gate (#35) holds mining until the
    # chains catch up, and says so. Its absence would mean mining died some OTHER way.
    local gtries=0 gate_seen=0
    while [ "$gtries" -lt 30 ]; do
        if _ssh "podman logs dashboard 2>&1 | grep -q 'holding p2pool, xmrig-proxy until synced'"; then
            gate_seen=1
            break
        fi
        sleep 10
        gtries=$((gtries + 1))
    done
    if [ "$gate_seen" -eq 1 ]; then
        ok "fresh chains hold mining behind the sync gate — the deliberate pre-sync state (#35)"
    else
        bad "no sync-gate hold in the dashboard log — mining is down for some other reason"
    fi
    # Held, not crashed: the gate stops a healthy p2pool cleanly (exit 0). A p2pool that
    # cannot run — the checksum-invalid wallet of #829 was exactly this — dies by signal and
    # shows a non-zero exit under the very same hold line.
    local pstate
    pstate=$(_ssh "podman inspect p2pool --format '{{.State.Running}} {{.State.ExitCode}}'" | tr -d '\r')
    case "$pstate" in
    "true 0" | "false 0")
        ok "p2pool stopped clean under the gate, not by a crash ($pstate)"
        ;;
    *)
        bad "p2pool did not survive its own start — crashed rather than held (state: ${pstate:-unreadable})"
        info "  p2pool log tail: $(_ssh "podman logs --tail 3 p2pool 2>&1" | tr '\n' ' ' | cut -c1-200)"
        ;;
    esac
    # The wiring itself (#796): the worker's rendered config dials THIS machine's stratum.
    if _ssh "jq -e '.pools[0].url == \"127.0.0.1:3333\"' /data/rigforge/config.json >/dev/null"; then
        ok "built-in miner is wired to the machine's own stratum (127.0.0.1:3333)"
    else
        bad "the built-in miner's config does not dial the machine's own stratum (pools: $(_ssh "jq -c '.pools' /data/rigforge/config.json 2>/dev/null" | cut -c1-100))"
    fi

    # ---- reboot leg: the provisioned stack must return UNAIDED ---------------------------
    # pithead-boot owns recovery (#792): render the derived layer, compose up, health-gated slot
    # commit. Nothing may drive it here: no pithead command, no wizard. The failure mode this
    # guards is a mining appliance that sits dark after every power blip until a human logs in.
    # The Caddyfile is corrupted FIRST (#790): derived files are regenerated on every boot by
    # construction, so a stale or broken one must not survive — this is the defect that shipped
    # new code against a days-old Caddyfile on hardware and killed TLS.
    info "reboot leg — the stack must come back on its own (pithead-boot)"
    _ssh "echo '# corrupted by the harness — a regenerated boot must not serve this' > /data/pithead/Caddyfile" 2>/dev/null ||
        bad "could not corrupt the Caddyfile before the reboot"
    # And drop the baked-archive digest records: the wizard wrote them at first boot, so their
    # mere presence afterwards proves nothing. Gone, they must come back — that is
    # pithead-boot's own loader running on a provisioned machine (#798).
    _ssh "rm -f /data/pithead/data/.loaded-*.sha" 2>/dev/null ||
        bad "could not drop the digest records before the reboot"
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
    local answered=0
    while [ "$tries" -lt 36 ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || echo 000)
        case "$code" in
        2?? | 3?? | 401 | 403)
            ok "dashboard answers again after the reboot (HTTP $code) — through a REGENERATED Caddyfile"
            answered=1
            break
            ;;
        esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$answered" -eq 1 ] || {
        bad "dashboard never answered after the reboot (last: $code)"
        return
    }
    # No unit may be quietly broken (#792 sat visible in --failed for two RCs, unasserted).
    local failed_units
    # Transient healthcheck ephemera excluded: podman drives container healthchecks through
    # hash-named systemd-run units, and one dies harmlessly whenever compose recreates its
    # container mid-check. Every REAL unit (pithead-boot, tor, podman…) stays load-bearing.
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    if [ -z "${failed_units//[; ]/}" ]; then
        ok "no failed systemd units after the reboot"
    else
        bad "failed units after the reboot: $failed_units"
    fi
    # The records dropped before the reboot must be BACK: on a provisioned machine only
    # pithead-boot can have rewritten them, so this is the boot path running the baked-image
    # loader — the mechanism a keep-reinstall or A/B update depends on (#798).
    if _ssh "test -s /data/pithead/data/.loaded-dashboard.tar.gz.sha"; then
        ok "pithead-boot ran the baked-image loader (digest record rewritten)"
    else
        bad "the digest record never came back — pithead-boot did not run the loader"
    fi
    # The booted slot must commit ITSELF once healthy (#793) — no harness mark-good here. On a
    # real appliance nothing ever ran mark-good, so RAUC called both slots bad and every boot
    # took GRUB's degraded fallback path. A_OK=1 + A_TRY=0 is the committed state.
    local genv tries3=0
    while [ "$tries3" -lt 18 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in
        *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;;
        esac
        sleep 10
        tries3=$((tries3 + 1))
    done
    case "$genv" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "booted slot committed itself after the health gate (A_OK=1 A_TRY=0)"
        ;;
    *)
        bad "slot never self-committed — grubenv: ${genv:-unreadable}"
        ;;
    esac
    # The miner must return too (#796): its unit lives in /run and died with the reboot, so
    # only pithead-boot's local-miner leg — which runs after the slot commit above — can have
    # brought it back. The cached build makes this a re-render, not a recompile.
    local mtries2=0 miner_back=0
    while [ "$mtries2" -lt 24 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_back=1
            break
        fi
        sleep 10
        mtries2=$((mtries2 + 1))
    done
    if [ "$miner_back" -eq 1 ]; then
        ok "built-in miner returned after the reboot (boot path re-ran its setup)"
    else
        bad "the miner did not return after the reboot — its runtime unit was never re-rendered"
    fi

    # ---- commit-gate honesty (#852): the gate must REFUSE a mining-dead slot ----------------
    # The slot self-committed above off a HEALTHY stack. But "the dashboard answers" is a subset
    # of "the stack is alive": a slot whose monerod/p2pool crashed while caddy+dashboard keep
    # serving is exactly the healthy-looking-but-dead slot a curl-only gate committed. The real
    # gate is `pithead doctor --json` (os/overlay/pithead-boot); assert its DECISION both ways on
    # this running stack. Reboot/fallback can't show it here — RAUC's commit is sticky, so the
    # already-committed slot won't re-arm — so we drive the gate command the boot path runs and
    # check its exit code. This is the assertion whose absence let the curl-only gate ship green.
    _gate() { _ssh "cd /data/pithead && PITHEAD_ENGINE=podman ./pithead doctor --json >/dev/null 2>&1"; }
    # Healthy, mid initial sync with mining held (#35): the gate must COMMIT. A gate that rejected
    # this would never commit a fresh box — the over-tightening the sync-tolerant rule guards.
    if _gate; then
        ok "commit gate PASSES on the healthy stack (dashboard serving, node up, mining held for sync)"
    else
        bad "commit gate rejected a healthy still-syncing stack — a fresh box would never commit (over-tightened)"
    fi
    # Crash a revenue service: stop monerod. It stays down (restart:unless-stopped won't revive a
    # manual stop), so podman reports it exited — a chain node down. The gate must now REFUSE, so
    # pithead-boot would leave the slot uncommitted and A/B fallback would revert. A curl-only gate
    # PASSES here (the dashboard still answers) — that is the regression this leg catches.
    _ssh "podman stop -t 5 monerod >/dev/null 2>&1" || true
    if _gate; then
        bad "commit gate PASSED with monerod stopped — a mining-dead slot would self-commit (the curl-only gap)"
    else
        ok "commit gate REFUSES a slot whose monerod is down — left uncommitted, A/B fallback stays armed"
    fi
    _ssh "podman start monerod >/dev/null 2>&1" || true
    unset -f _gate
}

phase_rig() {
    info "phase: rig (the OTHER machine this image installs — mines instead of coordinating)"
    # One image, two machines. Every other phase proves the coordinator; this one proves that
    # answering "RigForge" on the same page produces a box with no stack at all, that it mines
    # from the baked binary without compiling or reaching the network, and — the part that makes
    # it a fleet member rather than a toy — that it takes an A/B update exactly like a
    # coordinator does. A rig has no dashboard to complain through, so a rig that silently never
    # starts is invisible to everything except an assertion like this one.
    local img token jar body scode marker

    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots ($ip)"

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
    tries=0
    while ! curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup"; do
        sleep 5
        tries=$((tries + 1))
        [ "$tries" -lt 24 ] || {
            bad "wizard gate never served"
            return
        }
    done
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    grep -q "wizard_session" "$jar" || {
        bad "auth returned no session cookie — the submit below would be unauthenticated"
        rm -f "$jar"
        return
    }

    # The pool: the guest's OWN sshd. The host-side gate dials the address before it commits
    # anything, and a KVM guest has no Pithead on its LAN to dial — so this stands in for one.
    # It is a real TCP listener and nothing more, which is exactly what the gate checks; what it
    # deliberately does NOT prove is an accepted share, the same limit the coordinator's
    # local-miner leg documents. XMRig will dial it, get no stratum and retry forever, and that
    # is the point: the miner must come up and STAY up on a pool that does not answer, or a rig
    # whose coordinator is late would fail its own boot and roll its slot back.
    body="role=rig&rig_pool=127.0.0.1:22&rig_worker=kvm-rig"
    scode=$(curl -sSk -b "$jar" --data "$body" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "rig submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    ok "rig role submitted through the wizard"
    tries=0
    while [ "$tries" -lt 24 ]; do
        if curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"worker"'; then
            break
        fi
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no rig card appeared on the page"
        rm -f "$jar"
        return
    }
    # A rig's card carries the worker and where it points — and NO login, because a rig has none.
    if curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"'; then
        bad "the rig card published a dashboard password — a rig serves no dashboard"
    else
        ok "the rig card is worker + pool, with no login (a rig has none)"
    fi
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || true
    rm -f "$jar"

    # ---- the machine that came out: a rig, not a small coordinator ------------------------
    local mtries=0 miner_up=0
    while [ "$mtries" -lt 36 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_up=1
            break
        fi
        sleep 10
        mtries=$((mtries + 1))
    done
    if [ "$miner_up" -eq 1 ]; then
        ok "the rig mines (xmrig unit active, process running) with no reboot in between"
    else
        bad "the rig never started mining (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
        info "  firstboot journal tail: $(_ssh "journalctl -u pithead-firstboot -n 8 --no-pager -o cat" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
    fi
    [ "$(_ssh 'cat /data/pithead/machine-role' | tr -d '\r\n')" = "rig" ] &&
        ok "the role marker says rig" || bad "the role marker is not rig"
    [ -z "$(_ssh 'ls /data/pithead/config.json 2>/dev/null')" ] &&
        ok "no coordinator config was ever written (a rig has none)" ||
        bad "a config.json appeared on a rig — the coordinator contract leaked into the rig role"
    if _ssh "jq -e '.pools[0].url == \"127.0.0.1:22\" and .pools[0].user == \"kvm-rig\"' /data/rigforge/config.json >/dev/null"; then
        ok "the miner's config is derived from rig.json (pool + worker name)"
    else
        bad "the rig's miner config does not match its answers ($(_ssh "jq -c '.pools' /data/rigforge/config.json 2>/dev/null" | cut -c1-100))"
    fi
    # THE assertion of this phase: no stack. Not a stopped stack, not a held one — none started.
    local names
    names=$(_ssh "podman ps -a --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "${names// /}" ]; then
        ok "no compose stack was started — no containers exist at all on a rig"
    else
        bad "a rig started containers: '$names'"
    fi
    # Prebuilt-first, proven by identity: a native recompile produces a DIFFERENT binary, and a
    # clone could not have happened at all (this guest has no path to github).
    if _ssh "cmp -s /data/rigforge/data/worker/xmrig/build/xmrig /opt/rigforge/prebuilt/xmrig/build/xmrig"; then
        ok "the rig mines the BAKED binary byte for byte — no compile, no clone, no clearnet"
    else
        bad "the running miner is not the baked prebuilt — something compiled or fetched on first boot"
    fi
    # Removable-root tolerance: the journal is in memory, so a stick root takes no rotating
    # writes. (This guest's root is virtual, but the setting is the role's, not the medium's.)
    [ "$(_ssh 'systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -c "^Storage=volatile"')" != "0" ] &&
        ok "journald is volatile on a rig (a rig's root may be the stick it mines from)" ||
        bad "journald is still persistent on a rig — a USB root would take rotating writes"

    # ---- reboot: pithead-boot owns a rig now, and commits its slot -------------------------
    info "reboot leg — the rig must come back mining, and commit its own slot"
    _ssh reboot 2>/dev/null || true
    sleep 10
    _wait_ssh 300 || {
        bad "the rig never returned from the reboot"
        return
    }
    local mtries2=0 miner_back=0
    while [ "$mtries2" -lt 24 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_back=1
            break
        fi
        sleep 10
        mtries2=$((mtries2 + 1))
    done
    [ "$miner_back" -eq 1 ] &&
        ok "the rig returned mining with no hands on it (its unit lives in /run and died with the reboot)" ||
        bad "the rig did not return after the reboot — its runtime unit was never re-rendered"
    # WHICH unit owns the boot is the whole R4 fork: the wizard's window is closed by rig.json,
    # and pithead-boot — skipped on a rig before this phase existed — is what runs.
    [ "$(_ssh 'systemctl is-active pithead-boot' | tr -d '\r\n')" = "active" ] &&
        ok "pithead-boot owns a provisioned rig's boot" ||
        bad "pithead-boot did not run on the rig (its condition still excludes a machine with no config.json)"
    _ssh "systemctl is-active --quiet pithead-firstboot" &&
        bad "the first-boot wizard ran again on a provisioned rig" ||
        ok "the wizard window is closed on a provisioned rig (no setup page on every boot)"
    local failed_units
    failed_units=$(_ssh "systemctl --failed --no-legend --no-pager --plain" 2>/dev/null |
        awk '$1 !~ /^[0-9a-f]{64}-[0-9a-f]+\.service$/' | tr -s ' ' | tr '\n' ';')
    [ -z "${failed_units//[; ]/}" ] && ok "no failed systemd units on the rig after the reboot" ||
        bad "failed units on the rig after the reboot: $failed_units"
    # The commit gate, rig-shaped: a rig that could not commit would roll back every A/B update
    # it ever received. Note the pool here answers nothing — the commit must not depend on it.
    local genv tries3=0
    while [ "$tries3" -lt 18 ]; do
        genv=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv" in *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*) break ;; esac
        sleep 10
        tries3=$((tries3 + 1))
    done
    case "$genv" in
    *A_OK=1*A_TRY=0* | *A_TRY=0*A_OK=1*)
        ok "the rig committed its own slot on the miner running (A_OK=1 A_TRY=0), pool unanswered"
        ;;
    *) bad "the rig never self-committed — grubenv: ${genv:-unreadable}" ;;
    esac

    # ---- A/B update: identical pipeline, identical outcome --------------------------------
    info "update leg — a rig takes a bundle exactly like a coordinator"
    local bundle
    bundle=$(_build_bundle v2) || {
        bad "v2 bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    _stage_bundle "$bundle" || {
        bad "staging the bundle on the rig failed"
        return
    }
    _ssh "$(_install_cmd /data/update.bundle)" || {
        bad "the v2 install failed on the rig"
        return
    }
    ok "v2 installed into the rig's spare slot"
    _ssh "$(_boot_spare_cmd)" || true
    sleep 10
    _wait_ssh 300 || {
        bad "the rig never returned after booting the spare slot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v2" ] && ok "the rig's spare slot booted with v2" || {
        bad "expected v2 in the rig's spare slot, got '$marker'"
        return
    }
    # The state that must survive a whole-slot replacement: the role and its answers live on
    # /data, so the new slot has to come up as the SAME rig.
    [ "$(_ssh 'cat /data/pithead/machine-role' | tr -d '\r\n')" = "rig" ] &&
        ok "the role survived the slot swap (it lives on /data, not in the image)" ||
        bad "the updated slot lost the rig role"
    local mtries3=0 miner_v2=0
    while [ "$mtries3" -lt 24 ]; do
        if _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null"; then
            miner_v2=1
            break
        fi
        sleep 10
        mtries3=$((mtries3 + 1))
    done
    [ "$miner_v2" -eq 1 ] && ok "the rig mines again on the updated slot" ||
        bad "the rig stopped mining after the A/B update"
    # An uncommitted update must revert here for the same reason it does on a coordinator.
    _ssh reboot || true
    sleep 10
    _wait_ssh 300 || {
        bad "the rig never returned after the no-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v1" ] && ok "ROLLBACK: an uncommitted update reverts on a rig too" ||
        bad "expected v1 after the rig's uncommitted reboot, got '$marker'"
    _ssh "$(_install_cmd /data/update.bundle)" || {
        bad "the second v2 install failed on the rig"
        return
    }
    _ssh "$(_boot_spare_cmd)" || true
    sleep 10
    _wait_ssh 300 || {
        bad "the rig never returned after the second install"
        return
    }
    # No harness mark-good: the rig's own boot path must commit, the same way it did on v1.
    local genv2 tries4=0
    while [ "$tries4" -lt 24 ]; do
        genv2=$(_ssh "grub-editenv /boot/efi/grub/grubenv list" 2>/dev/null | tr '\n' ' ')
        case "$genv2" in *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*) break ;; esac
        sleep 10
        tries4=$((tries4 + 1))
    done
    case "$genv2" in
    *B_OK=1*B_TRY=0* | *B_TRY=0*B_OK=1*)
        ok "the rig self-committed the UPDATED slot (B_OK=1 B_TRY=0) — no harness hands"
        ;;
    *) bad "the rig never self-committed the updated slot — grubenv: ${genv2:-unreadable}" ;;
    esac
    _ssh reboot || true
    sleep 10
    _wait_ssh 300 || {
        bad "the rig never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v2" ] && ok "COMMIT: the update persists on the rig across reboot" ||
        bad "expected v2 on the rig after commit, got '$marker'"
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
rig) phase_rig ;;
fault) phase_fault ;;
all)
    phase_boot
    phase_update
    phase_install
    phase_provision
    phase_rig
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
