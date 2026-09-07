#!/usr/bin/env bash
# Tier-4 appliance harness (#77 phase 2): boot the pithead-os image in KVM and prove the
# properties only real firmware + a real A/B updater can show — EFI boot, the first-boot wizard
# window, and the update/commit/rollback cycle that is the phase-2 exit criterion. This is the
# os-image sibling of tests/integration/run.sh; it needs a Linux host with KVM + libvirt + the
# built image, so it runs on the bench, not in CI.
#
#   tests/os/run.sh --image PATH [--keep] [--phase boot|update|install|provision|rig|media|fault|reset|all]
#
# Phases:
#   boot    flash the image to a scratch disk, boot it, assert EFI boot + firstboot wizard up
#   update  build a v2 bundle; install, boot the spare, auto-rollback uncommitted, commit, and
#           roll back off a committed version. Also asserts /data grew to the disk (#784), then
#           drives the same A/B cycle through the DASHBOARD OS-update action end-to-end (leg 4):
#           provision, check/download (resume proven), floor + bad-signature refusals, install,
#           the explicit reboot intent, the boot-gated commit, and the persisted verdict.
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
#   media   physical-presence config channel (#786 sub-issue D): a removable stick applied at boot
#           shows its exact diff on the console, counts down, applies, and consumes itself; pulling
#           it mid-countdown cancels the change. A minimal stick (#965) changes only what it names;
#           dashboard login, appliance defaults and node credentials survive, old login still works.
#   fault   power cuts mid-write and mid-commit, plus a corrupt bundle. A brick is disqualifying.
#   reset   factory-reset's ESP marker (the real `pithead factory-reset`) wipes /data and returns a
#           FRESH machine to the wizard; a corrupt /data superblock drives wedged-/data recovery.
#   all     every phase above, in that order — media, fault and reset included since #1064
#
# A failed assertion is recorded and the run continues, so one bench boot collects the whole
# battery rather than stopping at the first fault; the run exits non-zero if any assertion failed.
# --keep leaves the VM + disks for inspection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=tests/os/hugepages-boot-verdict.sh
. "$SCRIPT_DIR/hugepages-boot-verdict.sh"
# shellcheck source=tests/os/failure-evidence.sh
. "$SCRIPT_DIR/failure-evidence.sh"
# shellcheck source=tests/os/kvm-preflight.sh
. "$SCRIPT_DIR/kvm-preflight.sh"
# shellcheck source=tests/os/journal-boot-verdict.sh
. "$SCRIPT_DIR/journal-boot-verdict.sh"
# shellcheck source=tests/os/restore-live-state-verdict.sh
. "$SCRIPT_DIR/restore-live-state-verdict.sh"
# shellcheck source=tests/os/reinstall-prefill-verdict.sh
. "$SCRIPT_DIR/reinstall-prefill-verdict.sh"
# shellcheck source=tests/os/provisioning-settled.sh
. "$SCRIPT_DIR/provisioning-settled.sh"
# shellcheck source=tests/os/data-floor-fallback-leg.sh
. "$SCRIPT_DIR/data-floor-fallback-leg.sh"
# shellcheck source=tests/os/aged-version.sh
. "$SCRIPT_DIR/aged-version.sh"
# shellcheck source=tests/os/provision-browser-submit.sh
. "$SCRIPT_DIR/provision-browser-submit.sh"
# shellcheck source=tests/os/reinstall-prefill-submit-leg.sh
. "$SCRIPT_DIR/reinstall-prefill-submit-leg.sh"
# shellcheck source=tests/os/setup-again-leg.sh
. "$SCRIPT_DIR/setup-again-leg.sh"

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
# Overwritten by every _ssh call with that call's stderr (empty on success). Not a log — just the
# LAST attempt's error text, so a caller that just gave up can classify why without another round
# trip. See _ssh_unreachable_reason.
SSH_ERR="/tmp/pithead-os-ssh.err"
# A fresh run must not inherit the last run's preserved console: the cleanup copy below is
# no-clobber (the at-assertion copy is the authoritative one), so clear the slate here.
rm -f "$SERIAL.failed"

# The wallet every phase submits. It must be checksum-VALID: p2pool refuses a well-formed but
# checksum-invalid address at startup with a SIGABRT and crash-loops (#829), which killed the
# provision phase's whole miner chain when the harness used `4` + 94×`A`. Host-side validation
# only checks the shape, so the crash is the first honest verdict. XMRig's public donation
# address: obviously not ours, plainly labelled, and any share it ever earned would be a donation.
HARNESS_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
# A real base58 Tari address: the wizard now decodes + checksum-validates it host-side, so a
# made-up placeholder is (correctly) rejected before the flow ever reaches the credentials
# handoff. Same throwaway address the stack suite uses.
HARNESS_TARI="126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"

# Every remote call is bounded. CORRECTION (this comment used to claim Debian socket-activates sshd —
# disproven): os/rootfs/Dockerfile only ever `systemctl enable`/`disable`s the plain ssh.service; no
# ssh.socket unit is ever enabled. What actually gates it is os/overlay/pithead-ssh-host-keys.conf, a drop-in
# that adds RequiresMountsFor=/data plus an ExecStartPre chain (generate the host key onto /data, then `sshd
# -t`) — so ssh.service cannot even begin starting until data.mount is active, and /data is freshly mkfs'd and
# grown by systemd-repart (os/rootfs/repart.d/40-data.conf) on every first boot. A guest whose sshd has not
# started yet therefore just refuses the connection (nothing is listening); it does not stall the handshake.
# The five-hour stall this bound exists for (2026-08-15: one boot-phase probe held for five hours against a
# guest that answered ssh normally the whole time, and the phase reported "SSH never came up" the instant that
# probe was killed) was an unbounded remote call outliving its own caller's deadline, not sshd's start order —
# bounding every call here is what fixed it, regardless of which cause produces the next stall. SSH_TIMEOUT is
# the per-call ceiling. The default is deliberately far larger than any legitimate call (the longest here is
# the 1800 s local-miner wait; a slot copy on slow storage is the other long one): this exists ONLY to stop an
# infinite hang, so it must never be the thing that ends real work — if a call is legitimately slower than
# this, raise it rather than let the ceiling arbitrate. ponytail: polling loops lower it to a few seconds — a
# stalled handshake must read as "not ready yet" so the loop re-evaluates its own deadline, which is the whole
# point of having one.
_ssh() {
    timeout "${SSH_TIMEOUT:-5400}" ssh -i "$KEY" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "root@$ip" "$@" 2>"$SSH_ERR"
}
_wait_ssh() { # $1 seconds — the definition of "not bricked"
    local deadline=$(($(date +%s) + $1)) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        _ssh true && return 0
        sleep 5
    done
    return 1
}
_boot_id() { _ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n' | grep .; } # rc 1 when unreadable
# A reboot is OBSERVED, never assumed (#1651): wait for a boot id DIFFERENT from $1. `sleep 10; _wait_ssh` reconnected
# to the still-running old boot whenever the shutdown outlasted the sleep (or the reboot command never landed) and
# read the OLD marker as the verdict. Reports how many probes the old boot answered, so a near-miss is visible.
_wait_new_boot() { # $1 = boot id before the reboot, $2 = seconds
    local deadline=$(($(date +%s) + $2)) SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" now='' stale=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        now=$(_boot_id)
        [ -n "$now" ] && [ "$now" != "$1" ] && break
        [ "$now" = "$1" ] && stale=$((stale + 1))
        sleep 5
    done
    [ "$stale" -eq 0 ] || info "the old boot $1 answered $stale probe(s) after the reboot command before going down"
    [ -n "$now" ] && [ "$now" != "$1" ] && return 0
    info "no new boot within $2 s — boot id ${now:-unreadable}, was $1"
    return 1
}
_reboot_wait() { # $1 = the command that reboots the guest, $2 = seconds to wait for the new boot
    local before
    before=$(_boot_id) || info "could not read the boot id before '$1' — a reconnect and a reboot would look alike"
    [ -n "$before" ] || return 1
    _ssh "$1" >/dev/null 2>&1 || true # the session dies with the reboot
    _wait_new_boot "$before" "$2"
}
# Classify why _wait_ssh gave up, using only signals that do NOT need a working SSH session — the
# guest either isn't running, isn't the one we're still probing, or is running and refusing the
# connection (sshd not up yet, or genuinely dead) vs. not answering the network at all. $1 is the
# ip that was being probed.
_ssh_unreachable_reason() {
    local probed_ip="$1" state cur_ip
    state=$(virsh domstate "$VM" 2>/dev/null || echo unknown)
    if [ "$state" != "running" ]; then
        printf 'guest VM is not running (libvirt state: %s) — it never had a chance to answer SSH' "$state"
        return
    fi
    cur_ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
    if [ -n "$cur_ip" ] && [ "$cur_ip" != "$probed_ip" ]; then
        printf 'guest now holds a DIFFERENT DHCP lease (%s, was probing %s) — it rebooted mid-boot and the probe was aimed at a dead lease, not a dead sshd' "$cur_ip" "$probed_ip"
        return
    fi
    if grep -qi refused "$SSH_ERR" 2>/dev/null; then
        printf 'guest answers on the network but refuses port 22 — sshd is still gated behind the /data mount + host-key generation (pithead-ssh-host-keys.conf), or failed to start; not a network problem'
        return
    fi
    # An auth rejection is the single most diagnostic answer here and it used to fall through to
    # the catch-all below, which reported a BENCH KEY MISMATCH as "guest never answered the
    # network — DHCP/routing/firewall problem". That is the opposite of what happened: sshd was up,
    # reachable, and said no. The misreport sent several sessions hunting product-side boot theories
    # (socket activation, RequiresMountsFor=/data) for a harness misconfiguration, so the classifier
    # names it explicitly and says which key it offered.
    if grep -qiE 'permission denied|no supported authentication|too many authentication' "$SSH_ERR" 2>/dev/null; then
        printf 'guest sshd is UP and REJECTED our key (%s) — this is authentication, not boot and not networking. The image bakes the pubkey passed to os/build-image.sh --ssh; if that is not the counterpart of the key this harness probes with, every phase that needs SSH fails like a dead guest' "$KEY"
        return
    fi
    printf 'guest never answered the network at all (last ssh error: %s) — DHCP/routing/firewall problem, not an sshd problem' "$(tr -s ' \n' ' ' <"$SSH_ERR" 2>/dev/null || echo none)"
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

# Poll until the guest has taken a DHCP lease. No guest agent in the appliance image (by
# design), so the lease is the source of truth. Sets the global `ip`. $1 seconds.
_wait_dhcp_ip() {
    local deadline=$(($(date +%s) + $1))
    ip=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        ip=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1 | head -1)
        [ -n "$ip" ] && return 0
        sleep 3
    done
    return 1
}

# Poll until the setup wizard's gate page answers on the global `ip`. The console announcement
# fires when the wizard CONTAINER starts, not when the Python server inside has bound its
# sockets, so the gate answers a little after the token prints — same retry shape everywhere
# this file waits on it. $1 seconds.
_wait_setup_page() {
    local deadline=$(($(date +%s) + $1))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        curl -fsSk -m 5 "https://$ip/" 2>/dev/null | grep -qi "Pithead setup" && return 0
        sleep 5
    done
    return 1
}

# Build a bootable image carrying $1 as its slot marker, for the selected updater.
_build_image() {
    [ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -q
    # What this harness believes it is building, so verify-image's stale-artifact guard runs here
    # too. It used to be unset in the only automated caller, which left the check that exists
    # BECAUSE an image shipped a two-commits-stale dashboard switched off in every battery run
    # (#1064). build-image.sh stamps the FULL sha, so that is the shape to hand over: a short one
    # never matched, and wiring the guard on with it would have failed every build the harness made.
    local expect
    expect="$(git rev-parse HEAD 2>/dev/null || true)"
    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$1" \
        os/build-image.sh >/tmp/os-fault-build.log 2>&1 || return 1
    os/rauc/mkimage.sh --dev >>/tmp/os-fault-build.log 2>&1 || return 1
    # Every image a phase boots gets the static verification first, in --test mode. The check
    # that matters most is the archive-vs-tree comparison: stale wizard images reached three
    # benches through caching bugs, and this layer catches the next one before a 25-minute
    # phase runs against it.
    PITHEAD_EXPECT_COMMIT="$expect" tests/os/verify-image.sh os/rauc/build/system.img --test >>/tmp/os-fault-build.log 2>&1 || {
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
    # timeout bounds every remote call (see _ssh) — without it each one dies 127 and the whole
    # run reads as a bricked guest, so it is a hard dependency, not a nicety.
    for c in virsh virt-install qemu-img timeout; do
        have "$c" || {
            echo "missing $c — install libvirt/qemu (see tests/os/README.md)" >&2
            exit 2
        }
    done
    [ -e /dev/kvm ] || {
        echo "/dev/kvm absent — this harness needs hardware virtualization" >&2
        exit 2
    }
    # --image is the boot phase's input; update and fault build their own v1/v2 images.
    if [ "$PHASE" = "boot" ] || [ "$PHASE" = "all" ]; then
        [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || {
            echo "--image PATH is required for the boot phase (build with os/build-image.sh)" >&2
            exit 2
        }
    fi
    require_probe_key_matches_image
}

# The harness probes the guest as root with $KEY; the image authorizes whatever pubkey was passed
# to `os/build-image.sh --ssh`. Nothing tied those together, and when they drifted apart — the
# driver built as an unprivileged user with that user's key while the harness ran under sudo with
# root's DIFFERENT key — the guest correctly refused every probe. That is indistinguishable from a
# dead guest once you are only watching a timeout, and it cost several sessions: three separate
# product-side theories were written up for what was a bench key mismatch, and the boot leg had in
# fact never once passed. Compare them here, before a multi-minute build and boot, and say so.
require_probe_key_matches_image() {
    [ -f "$KEY" ] || {
        echo "probe key $KEY not found — the harness authenticates to the guest with it" >&2
        exit 2
    }
    [ -n "$IMAGE" ] && [ -f "$IMAGE" ] || return 0
    local want
    # ssh-keygen -y derives the public half from the PRIVATE key, so this checks the actual keypair
    # rather than trusting a .pub file that may not be its counterpart — which is exactly how the
    # two drifted apart.
    want=$(ssh-keygen -y -f "$KEY" 2>/dev/null | awk '{print $1" "$2}')
    [ -n "$want" ] || return 0 # passphrase-protected or unreadable: not our call to judge here
    # Presence, not "the first key in the image": an image legitimately contains other keys (host
    # keys, fixtures), so comparing against whichever one appears first would refuse perfectly good
    # benches. If our pubkey is absent it cannot possibly authorize us, and that is the whole test.
    # A release image is shell-less and carries no authorized key at all, so only assert on debug
    # images — the only ones the harness can drive.
    grep -aq 'pithead-variant\|authorized_keys' "$IMAGE" 2>/dev/null || return 0
    grep -aqF "$want" "$IMAGE" 2>/dev/null || {
        echo "refusing to run: this image does not authorize the key the harness probes with." >&2
        echo "  harness key: $KEY" >&2
        echo "  its pubkey : $want" >&2
        echo "Every phase that needs SSH would fail like a dead guest — sshd answers and says no," >&2
        echo "which reads as a boot or network fault. Rebuild the image with" >&2
        echo "  os/build-image.sh --ssh $KEY.pub" >&2
        echo "or point \$KEY at the keypair the image was built with." >&2
        exit 2
    }
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
    if [ "$FAIL" -gt 0 ] && [ -s "$SERIAL" ] && [ ! -f "$SERIAL.failed" ]; then
        # No-clobber: an assertion that copied the console AT the failure got it before later
        # boots truncated $SERIAL — this end-of-phase copy would replace it with the wrong boot.
        cp "$SERIAL" "$SERIAL.failed" 2>/dev/null &&
            info "console from the failed run kept at $SERIAL.failed"
    fi
    if [ "$KEEP" -eq 1 ]; then
        info "left VM '$VM' and $DISK in place (--keep)"
        return
    fi
    vm_destroy
    rm -f "$DISK" "$SERIAL" "$SSH_ERR"
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
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
    _wait_dhcp_ip 60 || {
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
    _wait_setup_page 120 || {
        bad "wizard never served the token gate ($ip)"
        return
    }
    ok "wizard serves the token gate ($ip)"

    # SSH is a host service that starts after the wizard's HTTP gate answers, so the first _ssh here
    # must wait it out — a single-shot probe raced ssh.service and misread a healthy boot as dead.
    # 900, not the update phase's 240: this is the run's very FIRST cold boot — 6 GiB of
    # hugepages, systemd-repart growing /data, the wizard image unpacking, host-key generation —
    # and it starts while the image build's export I/O is still settling. 420 s passed idle but
    # clipped under full-battery load (proven both ways on the bench, 2026-08-15); the budget is
    # sized for the loaded case because a deadline that only holds on an idle host is a flake.
    # NOT raised again even though 900 s has since timed out too: it was proven sufficient on the
    # bench the same day on the same class of run, and a bigger arbitrary guess repeats the mistake
    # this file's history warns about (raising the ceiling instead of finding out why it was hit).
    # What changed instead is the failure message below: it names which of three things happened.
    _wait_ssh 900 || {
        bad "host SSH never came up after the wizard gate — cannot read hugepages/machine-id ($(_ssh_unreachable_reason "$ip"))"
        return
    }

    # Hugepages are load-bearing (the RandomX dataset must land in hugetlbfs, not the cgroup —
    # the Dockerfile's own words): the baked sysctl reserves 3072 2M pages, and a boot that
    # silently lost them starves the miner while everything else looks healthy. Since #977 this
    # also aims to pin the boot-time sizing unit's no-op branch — but HugePages_Total alone reads
    # identically whether the unit ran and correctly changed nothing, or never ran at all: the
    # baked sysctl reserves the same pool either way. Pairing the page count with the unit's own
    # record (systemd's is-active, true only once the RemainAfterExit=yes oneshot has actually
    # run) tells the two apart (#1212); hugepages_boot_verdict is fixture-tested at tier 1
    # (tests/stack/run.sh) so the discrimination itself is provable without a KVM boot. The
    # degrade tiers this unit computes are proven separately, also tier-1.
    local hp active verdict
    hp=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" 2>/dev/null) || hp=""
    active=$(_ssh "systemctl is-active pithead-hugepages.service" 2>/dev/null | tr -d '\r\n') || active=""
    if verdict=$(hugepages_boot_verdict "$hp" "$active"); then
        ok "$verdict"
    else
        bad "$verdict"
    fi

    # #895: machine-id must be assigned once and then STAY. #1659 and #1791 ride the same reboot:
    # journald keeping the transient id (a new journal dir per boot), and the /var overlay racing the
    # #1030 bind for /var/log/journal (a split boot list). Both verdicts are fixture-tested (tier 1).
    local id_before id_after jd_before jd_after jb
    id_before=$(_ssh cat /etc/machine-id)
    jd_before=$(_ssh 'ls /var/log/journal | wc -l' | tr -d '\r\n ')
    if [ -n "$id_before" ]; then
        if _reboot_wait reboot 240; then
            id_after=$(_ssh cat /etc/machine-id)
            [ -n "$id_after" ] && [ "$id_before" = "$id_after" ] && ok "machine-id stable across a reboot ($id_before)" ||
                bad "machine-id changed across a reboot (before: $id_before, after: ${id_after:-none})"
            jd_after=$(_ssh 'ls /var/log/journal | wc -l' | tr -d '\r\n ')
            jb=$(_ssh 'journalctl -b -q --no-pager -u pithead-machine-id 2>/dev/null | wc -l' | tr -d '\r\n ')
            printf '     · journal dirs %s -> %s; journalctl -b: %s kernel lines, %s from pithead-machine-id\n' "$jd_before" "$jd_after" "$(_ssh 'journalctl -b -k -q --no-pager 2>/dev/null | wc -l' | tr -d '\r\n ')" "$jb"
            verdict=$(journal_boot_verdict "$jd_before" "$jd_after" "$jb") && ok "$verdict" || bad "$verdict"
            verdict=$(journal_home_verdict "$(_ssh "$JOURNAL_HOME_PROBE" 2>/dev/null | tr -d '\r')") && ok "$verdict" || bad "$verdict"
        else
            bad "guest never returned after the machine-id reboot check"
        fi
    else
        bad "could not read machine-id before the reboot check (test SSH unreachable)"
    fi
}

# Boot a raw appliance disk under OVMF and return once it has a lease. Sets the global `ip`.
_vm_boot_disk() {
    vm_destroy
    cp "$1" "$DISK"
    qemu-img resize "$DISK" 40G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$DISK,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || return 1
    _wait_dhcp_ip 120
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
    # #894/#895 baseline, compared after the committed A/B swap below (leg 2) proves SURVIVAL,
    # not mere presence — /data (where both identities live) is untouched by a slot swap.
    local id_v1 hostkey_fp_v1
    id_v1=$(_ssh cat /etc/machine-id)
    hostkey_fp_v1=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
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
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after booting the spare slot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "spare slot booted with v2" || {
        bad "expected v2 in the spare slot, got '$marker'"
        return
    }
    _reboot_wait reboot 300 || { # uncommitted -> the bootloader must fall back on its own
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
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
        bad "guest never returned after the second install"
        return
    }
    _ssh "$(_commit_cmd)" || {
        bad "commit failed ($(_commit_cmd))"
        return
    }
    ok "committed the booted update"
    _reboot_wait reboot 300 || {
        bad "guest never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "COMMIT: a committed update persists across reboot" ||
        bad "expected v2 after commit, got '$marker'"
    # #894/#895: host identity must survive the A/B swap — it lives on /data, which an update
    # never touches, unlike the system slot an update replaces wholesale.
    local id_v2 hostkey_fp_v2
    id_v2=$(_ssh cat /etc/machine-id)
    hostkey_fp_v2=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    if [ -n "$id_v1" ] && [ "$id_v1" = "$id_v2" ]; then
        ok "machine-id survived the A/B swap ($id_v1)"
    else
        bad "machine-id changed across the A/B swap (v1: ${id_v1:-none}, v2: ${id_v2:-none})"
    fi
    if [ -n "$hostkey_fp_v1" ] && [ "$hostkey_fp_v1" = "$hostkey_fp_v2" ]; then
        ok "SSH host-key fingerprint survived the A/B swap ($hostkey_fp_v1)"
    else
        bad "SSH host-key fingerprint changed across the A/B swap (v1: ${hostkey_fp_v1:-none}, v2: ${hostkey_fp_v2:-none})"
    fi
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
    # Mark the serial BEFORE issuing the reboot that leg 4 provisions against: neither
    # config.json nor machine-role ever gets written by legs 1-3 (they only drive rauc), so
    # pithead-firstboot's ConditionPathExists stays satisfied and every one of the five reboots
    # above re-ran the wizard and minted its own token, none of them flushed by
    # _vm_boot_disk's one-time truncate (before leg 1). Taking the mark here — not on
    # entry to _wizard_provision_capture — is what makes it safe: anything already on the
    # serial before this point is a dead token from an earlier, now-destroyed wizard container,
    # and everything after belongs to the boot leg 4 actually runs against.
    local serial_mark
    serial_mark=$(wc -c <"$SERIAL" 2>/dev/null | tr -d ' ')
    _reboot_wait "$(_rollback_cmd)" 300 || {
        bad "guest never returned after an operator rollback"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "ROLLBACK: an operator can return to v1 after committing v2" ||
        bad "expected v1 after the operator rollback, got '$marker'"

    phase_update_dashboard "$bundle" "${serial_mark:-0}"
}

# Provision the wizard-gated stack over its real HTTP flow — the slim shape of what
# phase_provision drives with full assertions — and CAPTURE the generated dashboard login for
# API-driving legs. Sets DASH_USER/DASH_PASS. rc 1 on any failure; WIZ_FAIL_REASON names which of
# the six gates lost (the caller reports it — "no dashboard, no control channel" used to be the
# whole story, and every diagnostic run since has cost a battery pass to learn nothing more).
DASH_USER=""
DASH_PASS=""
WIZ_FAIL_REASON=""
_wizard_provision_capture() { # <serial-byte-offset-before-this-boot, default 0>
    local mark="${1:-0}" token="" tries=0 jar scode handoff="" tok_total
    WIZ_FAIL_REASON=""
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        # Only the tail past $mark: content from before this boot is a dead token from an
        # earlier, now-destroyed wizard container (see the leg-3 comment on serial_mark).
        token=$(tail -c "+$((mark + 1))" "$SERIAL" 2>/dev/null | tr -d '\r' | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    if [ -z "$token" ]; then
        WIZ_FAIL_REASON="gate: token — no pit-XXXXXX ever appeared on the serial console for this boot (waited ${tries}x3s)"
        return 1
    fi
    if ! _wait_setup_page 180; then
        WIZ_FAIL_REASON="gate: setup page — https://$ip/ never answered 'Pithead setup' within 180s (token: $token)"
        return 1
    fi
    jar=$(mktemp)
    if ! curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null; then
        # The number that confirms or kills the stale-token theory in one run: how many DISTINCT
        # tokens the whole serial (not just this boot's slice) is carrying right now.
        tok_total=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | sort -u | wc -l | tr -d ' ')
        WIZ_FAIL_REASON="gate: auth POST — https://$ip/auth rejected token $token ($tok_total distinct pit- token(s) on the serial so far)"
        rm -f "$jar"
        return 1
    fi
    if ! grep -q "wizard_session" "$jar"; then
        WIZ_FAIL_REASON="gate: session cookie — /auth returned 200 but set no wizard_session cookie (token: $token)"
        rm -f "$jar"
        return 1
    fi
    scode=$(curl -sSk -b "$jar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$scode" != "200" ]; then
        WIZ_FAIL_REASON="gate: submit — /submit returned $scode, want 200"
        rm -f "$jar"
        return 1
    fi
    tries=0
    while [ "$tries" -lt 24 ]; do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff" | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    if ! printf '%s' "$handoff" | grep -q '"password"'; then
        WIZ_FAIL_REASON="gate: handoff — /api/handoff never carried a password (waited ${tries}x5s)"
        rm -f "$jar"
        return 1
    fi
    DASH_USER=$(printf '%s' "$handoff" | jq -r '.username // "admin"')
    DASH_PASS=$(printf '%s' "$handoff" | jq -r '.password // ""')
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    [ -n "$DASH_PASS" ] || WIZ_FAIL_REASON="gate: handoff — password came back empty"
    [ -n "$DASH_PASS" ]
}

# POST one dashboard OS-update step and wait out its terminal result (progress statuses are
# in-flight, not terminal). Echoes the final result JSON; rc 1 on transport failure/deadline.
_os_step() { # <json-body> [<deadline-s>]
    local body="$1" deadline=$(($(date +%s) + ${2:-180})) rid out st
    rid=$(curl -sSk -u "$DASH_USER:$DASH_PASS" -H 'Content-Type: application/json' \
        -H 'X-Pithead-Control: 1' --data "$body" "https://$ip/api/control/os-update" 2>/dev/null |
        jq -r '.id // ""')
    [ -n "$rid" ] || return 1
    while [ "$(date +%s)" -lt "$deadline" ]; do
        out=$(curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/control/result?id=$rid" 2>/dev/null)
        st=$(printf '%s' "$out" | jq -r '.status // "pending"' 2>/dev/null) || st="pending"
        case "$st" in
        pending | running | downloading | installing | "") sleep 3 ;;
        *)
            printf '%s' "$out"
            return 0
            ;;
        esac
    done
    return 1
}

# Serve a directory over HTTP with byte-range support (curl -C - needs 206; python's stock
# SimpleHTTPRequestHandler answers 200-only, which would silently break the resume leg).
# Echoes the server PID; caller kills it.
# <dir> <port> [probe-file] -> prints the pid; rc 1 if the port never actually answered.
#
# The probe is the point (#1149). This used to background python with `>/dev/null 2>&1` and print
# `$!` unconditionally, so a FAILED BIND reported a running server: the error went to /dev/null and
# `$!` is a pid whether or not the process survived. A leaked server from an aborted run is the
# normal case on a bench — every failure path below kills `$srv_pid`, which is already dead when
# the bind failed, and `--keep` skips the kill entirely — and that corpse is serving a directory
# the previous run has since `rm -rf`'d, so every request 404s. The guest then got a 404 where it
# expected the release JSON, `curl -fsS` reported it the same as a dead circuit, and leg 4 blamed
# Tor for three sessions.
#
# The custom handler below 404s on a directory, so the probe names a real file — the one the
# caller has already written before starting the server.
_serve_update_dir() { # <dir> <port>
    python3 - "$1" "$2" <<'PYEOF' >/dev/null 2>&1 &
import http.server, os, re, sys
os.chdir(sys.argv[1])
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        path = self.translate_path(self.path)
        # Independent witness for the resume leg (#1051): the product's own `resumed_from`
        # field is the size of the partial file it staged BEFORE curl ever ran, so it holds
        # whether or not curl actually resumed — it cannot catch a resume that silently
        # restarted from zero. This log records what the server itself received on the wire,
        # which is the one place that can.
        with open(os.path.join(sys.argv[1], ".requests.log"), "a") as _lf:
            _lf.write(f"{os.path.basename(path)} {self.headers.get('Range') or 'none'}\n")
        if not os.path.isfile(path):
            self.send_error(404)
            return
        size = os.path.getsize(path)
        start = 0
        m = re.match(r"bytes=(\d+)-$", self.headers.get("Range") or "")
        if m:
            start = int(m.group(1))
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        else:
            self.send_response(200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(size - start))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except BrokenPipeError:
                    break
http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), H).serve_forever()
PYEOF
    local pid=$! i
    for i in $(seq 40); do
        if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$2/releases-latest.json" 2>/dev/null; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 0.25
    done
    # It never answered. Say WHO holds the port — a leftover from an earlier run is the usual
    # answer, and without this line the next person debugs the guest instead of the bench.
    # STDERR, not stdout: this function's stdout IS the pid, so the caller reads it through a
    # command substitution — an `info` here would be captured into the variable and never seen.
    # Same shape as the swallowed hint in #1081; the diagnostic has to step outside the capture.
    info "bench update server never answered on :$2 — port holder: $(ss -ltnp "sport = :$2" 2>/dev/null | tail -n +2 | tr -s ' ' | cut -c1-160)" >&2
    kill "$pid" 2>/dev/null
    return 1
}

# Leg 4 — the dashboard OS-update action end-to-end: the user-reachable path over the SAME A/B
# machinery legs 1-3 proved raw. Provisions the stack (the control channel and dashboard exist
# only on a provisioned machine), then drives check → download (with a proven RESUME) → verify
# (with the floor and bad-signature refusals) → install → the explicit reboot intent → the
# boot-gated commit → the persisted verdict the dashboard renders. The release lookup and the
# bundle download are pointed at a bench-local server through the root-owned test seam
# (os-update-test-base); RAUC signature verification still runs for real against the slot
# keyring, so the bad-signature refusal is genuine, not simulated.
_leg4_srv_stop() { # the bench release server and its dir, torn down at every leg-4 exit; reads the caller's locals
    kill "$srv_pid" 2>/dev/null
    rm -rf "$srv"
}
phase_update_dashboard() { # <good-bundle-path> <serial-byte-offset-before-this-boot>
    local good_bundle="$1" serial_mark="${2:-0}" marker before
    info "leg 4 — dashboard OS-update action end-to-end (provision, then check/download/verify/install/reboot)"
    if ! _wizard_provision_capture "$serial_mark"; then
        bad "leg 4: could not provision the stack through the wizard (${WIZ_FAIL_REASON:-no dashboard, no control channel})"
        return
    fi
    ok "leg 4: stack provisioned; dashboard login captured"
    # The stack must come up far enough that caddy answers and the control runner exists.
    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "leg 4: stack containers are running" ;;
    *)
        bad "leg 4: stack never came up — running: '${names:-none}'"
        return
        ;;
    esac
    local tries=0 code=000
    while [ "$tries" -lt 60 ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in 2?? | 3?? | 401 | 403) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    # The UI-presence contract: an appliance state carries os_update, so the header renders the
    # OS control instead of the tarball Upgrade button.
    if curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.step' >/dev/null 2>&1; then
        ok "leg 4: /api/state carries the appliance os_update state (the header control renders)"
    else
        bad "leg 4: /api/state has no os_update — the dashboard would never show the OS control"
        return
    fi

    # Bench-local release server: the good v2 bundle plus a corrupted twin, behind the seam.
    local tag srv host_addr port=8931 size srv_pid
    # The tag the bench release server publishes MUST match the bundle's own stamp, which is the
    # checkout's VERSION — the bundle is built from this tree.
    tag="v$(tr -d ' \t\r\n' <VERSION)"
    srv=$(mktemp -d)
    cp "$good_bundle" "$srv/pithead-os-$tag.raucb"
    size=$(wc -c <"$srv/pithead-os-$tag.raucb" | tr -d ' ')
    cp "$srv/pithead-os-$tag.raucb" "$srv/good.raucb"
    cp "$srv/good.raucb" "$srv/bad.raucb"
    # One clobbered byte mid-file: the signature no longer matches, nothing else changes.
    dd if=/dev/zero of="$srv/bad.raucb" bs=1 seek=$((size / 2)) count=64 conv=notrunc 2>/dev/null
    printf '{"tag_name":"%s","html_url":"http://bench.invalid/rel","assets":[{"name":"pithead-os-%s.raucb","size":%s}]}' \
        "$tag" "$tag" "$size" >"$srv/releases-latest.json"
    host_addr=$(ip -4 -o addr show virbr0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [ -n "$host_addr" ] || host_addr="192.168.122.1"
    if ! srv_pid=$(_serve_update_dir "$srv" "$port"); then
        bad "leg 4: the bench release server never answered on :$port — nothing was checked, and this is the harness, not the product (#1149)"
        rm -rf "$srv"
        return
    fi
    _ssh "printf 'http://$host_addr:$port' > /data/pithead/os-update-test-base" || {
        bad "leg 4: could not plant the update-server seam on the guest"
        _leg4_srv_stop
        return
    }

    # A real update arrives at a box running something OLDER, and the dashboard door refuses an
    # equal target on purpose: an equal-version reinstall is a forced-downtime and flash-wear loop
    # for a compromised container. Both images here are built from the one checkout, so without
    # this the guest is already running the version the bundle carries and leg 4 could never get
    # past its first download — it reported #976's path as broken while never offering it anything
    # to install. Age the RUNNING side, never the bundle's stamp (see tests/os/aged-version.sh).
    #
    # Safe here specifically: nothing renders .env or runs compose between this write and the
    # reboot — `pithead os-update` is a rauc install — and pithead-sync restores the slot's real
    # VERSION on the next boot, before pithead-boot reads it to judge the update. So the guest
    # claims the older version exactly for the length of the check/download/install window.
    # #1676: a failed precondition here used to cost SEVEN reds — every later step fails on the
    # same un-aged guest — so both failure shapes return after their one red.
    local aged
    if ! aged=$(aged_version "${tag#v}"); then
        bad "leg 4: cannot age the running version ${tag#v} — nothing sorts below it (tests/os/aged-version.sh)"
        _leg4_srv_stop
        return
    fi
    if ! _ssh "printf '%s\n' '$aged' > /data/pithead/VERSION"; then
        bad "leg 4: could not age the guest's running version to $aged"
        _leg4_srv_stop
        return
    fi

    local out st
    # Check: the host derives tag + size from the (redirected) release lookup.
    out=$(_os_step '{"action":"check"}' 120)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "checked" ] &&
        [ "$(printf '%s' "$out" | jq -r '.version')" = "$tag" ]; then
        ok "leg 4: check derived the published release ($tag, $(printf '%s' "$out" | jq -r '.size') bytes)"
    else
        bad "leg 4: check did not derive the release (got: $(printf '%s' "$out" | cut -c1-200))"
        _leg4_srv_stop
        return
    fi

    # Refusal 1 — the /data floor, via the dashboard door onto the SAME guard the CLI enforces. A
    # floor above this (newer) bundle is above the running version too: since #1393 that is the
    # failed-migration state, refused FIRST with its premise; the plain door is tier 1's (#1694).
    _ssh "printf '99.0.0\n' > /data/pithead/.os-data-floor"
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ]; then
        ok "leg 4: bundle downloaded to /data for the floor leg"
    else
        bad "leg 4: download for the floor leg did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    out=$(_os_step '{"action":"verify"}' 120)
    st=$(printf '%s' "$out" | jq -r '.status')
    if [ "$st" = "rejected" ] && printf '%s' "$out" | jq -r '.error' | grep -q "failed its gate.*the floor version or newer installs"; then
        ok "leg 4: FLOOR ABOVE THE RUNNING VERSION REFUSED — verify refuses with the failed-migration premise and the open route"
    else
        bad "leg 4: verify under a floor above the running version did not refuse with the true premise (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    if ! _ssh "test -f /data/pithead/data/os-update/pithead-os-$tag.raucb"; then
        ok "leg 4: the floor-refused bundle was deleted"
    else
        bad "leg 4: the floor-refused bundle is still staged"
    fi
    _ssh "rm -f /data/pithead/.os-data-floor"

    # Refusal 2 — a corrupted (mis-signed) bundle: RAUC's real signature check against the slot
    # keyring refuses it, the error says so, and the file is deleted. No override exists.
    cp "$srv/bad.raucb" "$srv/pithead-os-$tag.raucb"
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] ||
        bad "leg 4: download of the corrupted bundle did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
    out=$(_os_step '{"action":"verify"}' 120)
    st=$(printf '%s' "$out" | jq -r '.status')
    if [ "$st" = "rejected" ] && printf '%s' "$out" | jq -r '.error' | grep -q "signature"; then
        ok "leg 4: BAD SIGNATURE REFUSED — verify rejects the corrupted bundle with the honest error"
    else
        bad "leg 4: verify of the corrupted bundle did not refuse on signature (got: $(printf '%s' "$out" | cut -c1-200))"
    fi
    if ! _ssh "test -f /data/pithead/data/os-update/pithead-os-$tag.raucb"; then
        ok "leg 4: the mis-signed bundle was deleted"
    else
        bad "leg 4: the mis-signed bundle is still staged"
    fi

    # Resume: restore the good bundle, pre-stage a genuine prefix as the interrupted transfer,
    # and require the download to CONTINUE from it rather than start over.
    #
    # `resumed_from` alone is tautological (#1051): it is the size of the .partial file THIS
    # test staged, echoed back before curl ever runs, so it holds whether or not curl actually
    # resumed — a client that silently restarted from zero would still report it. The independent
    # witness is what the SERVER actually received on the wire (`.requests.log`, written by
    # `_serve_update_dir` above): a genuine resume sends `Range: bytes=4194304-`; a silent restart
    # sends no Range header (or one starting at 0). Truncate the log first so a stale request from
    # an earlier step in this leg can't be misread as this one's.
    : >"$srv/.requests.log"
    cp "$srv/good.raucb" "$srv/pithead-os-$tag.raucb"
    head -c 4194304 "$srv/good.raucb" |
        _ssh "mkdir -p /data/pithead/data/os-update && cat > /data/pithead/data/os-update/pithead-os-$tag.raucb.partial" || {
        bad "leg 4: could not pre-stage the interrupted download"
    }
    out=$(_os_step "{\"action\":\"download\",\"version\":\"$tag\"}" 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "downloaded" ] &&
        [ "$(printf '%s' "$out" | jq -r '.resumed_from // 0')" = "4194304" ] &&
        grep -q "^pithead-os-$tag.raucb bytes=4194304-\$" "$srv/.requests.log" 2>/dev/null; then
        ok "leg 4: RESUME PROVEN — the download continued from the interrupted 4 MiB, not from zero (server witnessed the Range request)"
    else
        bad "leg 4: the download did not resume from the staged prefix (got: $(printf '%s' "$out" | cut -c1-200); server saw: $(cat "$srv/.requests.log" 2>/dev/null | tr '\n' ';'))"
    fi

    # Verify + install: the good bundle passes for real, the install writes the spare slot while
    # the stack keeps running, and the in-flight flag arms the post-reboot verdict.
    out=$(_os_step '{"action":"verify"}' 180)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "verified" ]; then
        ok "leg 4: the good bundle verifies (signature + compatible + version)"
    else
        bad "leg 4: the good bundle failed verify (got: $(printf '%s' "$out" | cut -c1-200))"
        _leg4_srv_stop
        return
    fi
    out=$(_os_step '{"action":"install"}' 900)
    if [ "$(printf '%s' "$out" | jq -r '.status')" = "installed" ]; then
        ok "leg 4: install wrote the spare slot through the dashboard action"
    else
        bad "leg 4: install did not complete (got: $(printf '%s' "$out" | cut -c1-200))"
        # The runner deletes .install.log on a failed install and the result carries only a whitelisted last line
        # (#1651: one gate red said "[ERROR] rauc install failed", guest gone) — keep the guest's own account.
        SSH_TIMEOUT=120 _ssh "{ echo '== pithead-control.service (the root runner)'; journalctl -b -u pithead-control.service -o short-iso --no-pager -n 200; echo '== journal rauc/os-install lines'; journalctl -b -o short-iso --no-pager | grep -aiE 'rauc|os.install|os-update' | tail -300; echo '== rauc status'; rauc status; echo '== df'; df -h /data /tmp; echo '== free'; free -m; echo '== oom'; dmesg | grep -aiE 'oom|killed process'; } 2>&1" >"$SERIAL.leg4-install" || true
        [ -s "$SERIAL.leg4-install" ] && info "install diagnostics kept at $SERIAL.leg4-install" || info "install diagnostics capture came back EMPTY (guest unreachable, or the 120 s cap hit) — read $SERIAL.failed"
        _leg4_srv_stop
        return
    fi
    if [ "$(_ssh "jq -r '.to' /data/pithead/data/os-update/in-flight.json" 2>/dev/null)" = "${tag#v}" ]; then
        ok "leg 4: the in-flight flag names the target version"
    else
        bad "leg 4: no in-flight flag after the install — the post-reboot verdict is unarmed"
    fi
    if [ "$(_ssh "jq -r '.step' /data/pithead/data/control/results/os-update-state.json" 2>/dev/null)" = "reboot-pending" ]; then
        ok "leg 4: the persisted state says reboot-pending (survives reloads)"
    else
        bad "leg 4: the persisted state does not say reboot-pending"
    fi

    # The explicit reboot intent — nothing rebooted on its own up to here.
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v1" ] && ok "leg 4: nothing auto-rebooted — still on v1 until the operator says so" ||
        bad "leg 4: expected to still be on v1 before the reboot intent, got '$marker'"
    before=$(_boot_id) || info "could not read the boot id before the reboot intent — a reconnect and a reboot would look alike"
    [ -n "$before" ] && _os_step '{"action":"reboot"}' 30 >/dev/null 2>&1 || true # the machine goes away mid-poll; no id, no reboot
    [ -n "$before" ] && _wait_new_boot "$before" 420 || {
        bad "leg 4: guest never returned after the dashboard reboot intent"
        _leg4_srv_stop
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker)
    [ "$marker" = "v2" ] && ok "leg 4: the dashboard-driven update booted v2" ||
        bad "leg 4: expected v2 after the dashboard reboot, got '$marker'"
    # The verdict is written only when pithead-boot's health gate commits the slot — waiting for
    # it proves install + reboot + commit landed, and that the banner's data exists.
    local vdeadline=$(($(date +%s) + 900)) verdict=""
    while [ "$(date +%s)" -lt "$vdeadline" ]; do
        verdict=$(_ssh "jq -r '.verdict.outcome // \"\"' /data/pithead/data/control/results/os-update-state.json" 2>/dev/null)
        [ -n "$verdict" ] && break
        sleep 15
    done
    if [ "$verdict" = "updated" ]; then
        ok "leg 4: COMMIT + VERDICT — the slot committed and the verdict says updated"
    else
        bad "leg 4: no 'updated' verdict after the reboot (got '${verdict:-none}') — commit or verdict is broken"
    fi
    if curl -sSk -u "$DASH_USER:$DASH_PASS" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.verdict.outcome == "updated"' >/dev/null 2>&1; then
        ok "leg 4: the success banner's verdict reaches /api/state"
    else
        bad "leg 4: /api/state does not carry the updated verdict — the banner would never show"
    fi
    _leg4_srv_stop
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
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
    _wait_dhcp_ip 120
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
    _wait_setup_page 120 || {
        bad "installer wizard never served its gate page"
        return
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "installer wizard auth failed"
        rm -f "$jar"
        return
    }
    local body
    body="monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini&disk=vda&confirm=vda&wipe=keep"
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed to define the installed VM"
        return
    }
    _wait_dhcp_ip 120
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
    _wizard_up() { _wait_setup_page 180; } # shared by both legs — first boots load the wizard image first
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
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
    _wait_dhcp_ip 120
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
    # the stripped previous config as the page's pre-fill (pithead:2350,
    # prefill_from_previous_install). A wallet-address match on the page's own state API alone
    # cannot tell "the branch read the target disk and published it" from "the page shows that
    # value for some other reason" — #1038 found this leg green for four consecutive batteries
    # while never proving the branch itself had run. Pairing the outcome with the branch's OWN
    # record — the exact log line it prints ONLY on that path (StandardOutput=journal+console
    # per pithead-firstboot.service, so it lands on $SERIAL) — is what tells the two apart, the
    # same discrimination #1212 needed for hugepages; reinstall_prefill_verdict is fixture-tested
    # at tier 1 (tests/stack/run.sh) for exactly that reason. Runs BEFORE the wipe legs on
    # purpose — they destroy the config the pre-fill was read from.
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    if [ -n "$token" ] && _wizard_up; then
        jar=$(mktemp)
        local pf_state="" branch_logged=0 wallet_prefilled=0 password_leaked=0 pf_verdict
        curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
            pf_state=$(curl -fsSk -b "$jar" "https://$ip/api/wizard-state" 2>/dev/null)
        rm -f "$jar"
        grep -qF "Found the previous installation's settings on the target disk" "$SERIAL" &&
            branch_logged=1
        printf '%s' "$pf_state" | grep -q "\"wallet_address\": \"${HARNESS_WALLET:0:8}" &&
            wallet_prefilled=1
        # The provisioned config held a generated dashboard password; the merged state may
        # only ever show the reference's empty default for any "password" key.
        printf '%s' "$pf_state" | grep -Eq '"password": "[^"]' && password_leaked=1
        if pf_verdict=$(reinstall_prefill_verdict "$branch_logged" "$wallet_prefilled" "$password_leaked"); then
            ok "$pf_verdict"
        else
            bad "$pf_verdict"
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
    # Anchored: "verdict=OK,USER-DATA-SURVIVED" must NOT pass — the suffix flags are the failure.
    if printf '%s' "$wout" | grep -qx "verdict=OK"; then
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
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
    _wait_dhcp_ip 120
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
    _wait_setup_page 180 || {
        bad "the newer stick's wizard never served its gate page"
        return
    }
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
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$target_disk,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "virt-install failed for the reinstalled system"
        return
    }
    _wait_dhcp_ip 120
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

    # ---- restore-at-setup leg (#909, #786 sub-issue B) -----------------------------------
    # A genuine encrypted backup pulled off a live, fully-provisioned machine seeds a
    # totally fresh disk through the wizard's upload path instead of the config form — the
    # disaster-recovery loop #908 (export) opens and this closes. Real archive, real upload
    # over curl -F, real decrypt+extract on the guest, and the identity (wallet, Tor onion)
    # must survive — proof the "restored config drives provisioning as if pre-seeded" promise
    # actually holds, which nothing below tier 4 can prove.
    #
    # The keep-reinstalled machine above sits at the WIZARD — a reinstall always returns
    # there (keep preserves /data, not provisioned-ness), and `pithead backup` rightly
    # refuses without a provisioned stack (.env, onion keys). Provision it first, through
    # the same HTTP flow a human would drive.
    local rtoken rjar rtries
    rtoken=""
    rtries=0
    while [ -z "$rtoken" ] && [ "$rtries" -lt 40 ]; do
        rtoken=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$rtoken" ] || sleep 3
        rtries=$((rtries + 1))
    done
    if [ -z "$rtoken" ]; then
        bad "restore leg: no wizard token on the console after the keep-reinstall"
        rm -f "$target_disk"
        return
    fi
    rjar=$(mktemp)
    curl -fsSk -c "$rjar" -d "token=$rtoken" "https://$ip/auth" -o /dev/null 2>/dev/null
    scode=$(curl -sSk -b "$rjar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    if [ "$scode" != "200" ]; then
        bad "restore leg: wizard submit did not return 200 (got ${scode:-none})"
        rm -f "$rjar" "$target_disk"
        return
    fi
    # A keep-machine keeps its old login, so the credentials card (and the hold it creates)
    # may never appear — ack it if it does, move on if it does not.
    rtries=0
    while [ "$rtries" -lt 12 ]; do
        if curl -sSk -b "$rjar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"'; then
            curl -sSk -b "$rjar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
            break
        fi
        sleep 5
        rtries=$((rtries + 1))
    done
    rm -f "$rjar"
    local rdeadline rnames
    rdeadline=$(($(date +%s) + 1500))
    rnames=""
    while [ "$(date +%s)" -lt "$rdeadline" ]; do
        rnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$rnames" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$rnames" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "restore leg: keep-reinstalled machine provisioned — a live stack to back up ($rnames)"
        # Settle on the provisioning UNITS, not on `podman ps` (#1945): the wizard's `up` holds the
        # mutation lock through its tor-health wait for minutes after the stack looks live, and a
        # backup taken then waits it out or, when that `up` dies, archives the wreck. 900 s covers tor.
        if ! provisioning_settled 900; then
            bad "restore leg: provisioning never finished on the machine ($(provisioning_state))"
            backup_failure_evidence
            rm -f "$target_disk"
            return
        fi
        ok "restore leg: provisioning finished ($(provisioning_state))"
        ;;
    *)
        bad "restore leg: stack never came up after provisioning (running: '${rnames:-none}')"
        rm -f "$target_disk"
        return
        ;;
    esac
    local restore_archive="/tmp/pithead-os-restore-test.tar.gz.enc"
    local restore_pass="pithead-os-restore-test-passphrase" # fixture value, not real secret material
    rm -f "$restore_archive"
    backup_precapture # #1059: state of both collected files, plus a watcher for the run itself
    if _ssh "cd /data/pithead && PITHEAD_BACKUP_PASSPHRASE=$restore_pass ./pithead backup -y >/tmp/restore-backup.log 2>&1"; then
        ok "restore leg: took a real encrypted backup off the live machine"
        backup_watch_report # a vanish the backup happened to survive is still the #1059 event
    else
        bad "restore leg: could not take the source backup"
        # The reason lives on the guest — capture ALL of it, log AND tree, or this failure is
        # undiagnosable after the VM is recycled (it has been, twice: #1059).
        backup_failure_evidence
        rm -f "$target_disk"
        return
    fi
    local remote_archive
    remote_archive=$(_ssh "ls /data/pithead/backups/pithead-backup-*.tar.gz.enc" | tail -1)
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "root@$ip:$remote_archive" "$restore_archive" || {
        bad "restore leg: could not pull the backup archive off the guest"
        rm -f "$target_disk"
        return
    }
    local orig_onion
    orig_onion=$(_ssh "grep MONERO_ONION_ADDRESS /data/pithead/.env" | cut -d= -f2)
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy

    local restore_target="/srv/code/bench-vm/pithead-restore-target.img"
    rm -f "$restore_target"
    qemu-img create -f raw "$restore_target" 30G >/dev/null
    img=$(_build_image v1) || {
        bad "restore leg: image build failed"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    cp "$img" "$DISK"
    qemu-img resize "$DISK" 16G >/dev/null 2>&1 || true
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$restore_target,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "restore leg: virt-install failed for the fresh installer boot"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "restore leg: installer guest never answered SSH"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    _ssh "for i in \$(seq 36); do [ -s /data/pithead/data/firstboot/disks.tsv ] && exit 0; sleep 5; done; exit 1" || {
        bad "restore leg: installer never reached installer mode"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    token=""
    tries2=0
    while [ -z "$token" ] && [ "$tries2" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries2=$((tries2 + 1))
    done
    [ -n "$token" ] || {
        bad "restore leg: no one-time token on the installer console"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    _wait_setup_page 120 || {
        bad "restore leg: wizard never served its gate page"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "restore leg: auth failed"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    # The combined leg: ONE upload carries the archive, its passphrase, AND the disk choice —
    # the same _gate_install_request every other installer submission takes.
    scode=$(curl -sSk -b "$jar" \
        -F "archive=@$restore_archive" -F "passphrase=$restore_pass" \
        -F "disk=vda" -F "confirm=vda" -F "wipe=keep" \
        "https://$ip/submit-restore" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "restore leg: upload did not return 200 (got ${scode:-none})"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    ok "restore leg: uploaded the backup archive instead of the form"
    local rhandoff=""
    tries2=0
    while [ "$tries2" -lt 24 ]; do
        rhandoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$rhandoff" | grep -q '"password"' && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    [ "$tries2" -lt 24 ] || {
        bad "restore leg: no credentials card after the restore — the restored config never drove provisioning"
        rm -f "$jar" "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    ok "restore leg: the restored config drove provisioning to a credentials card"
    # Captured for the live-state check below (#1091) — the restored machine's OWN generated
    # login, not the source machine's, since a keep-reinstall would have kept the old one.
    DASH_USER=$(printf '%s' "$rhandoff" | jq -r '.username // "admin"')
    DASH_PASS=$(printf '%s' "$rhandoff" | jq -r '.password // ""')
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    tries2=0
    while [ "$tries2" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries2=$((tries2 + 1))
    done
    if [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ]; then
        ok "restore leg: installed and switched itself off"
    else
        bad "restore leg: never powered off after the ack"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    fi
    vm_destroy
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import --disk "path=$restore_target,format=raw,bus=virtio" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "restore leg: virt-install failed for the restored machine"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    _wait_dhcp_ip 120
    _wait_ssh 300 || {
        bad "restore leg: restored machine never answered SSH"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    }
    ok "restore leg: the restored machine boots from the fresh disk"
    # The carried restore lands during firstboot and .env only exists once render has run —
    # wait for provisioning, don't race it.
    if _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        ok "restore leg: the carried archive provisioned the machine — config.json is back"
    else
        bad "restore leg: no config.json ever appeared — the carried restore never landed"
        rm -f "$target_disk" "$restore_archive" "$restore_target"
        return
    fi
    if _ssh "grep -q \"$HARNESS_WALLET\" /data/pithead/config.json"; then
        ok "restore leg: restored machine carries the ORIGINAL wallet address, not a fresh one"
    else
        bad "restore leg: restored machine's config does not carry the original wallet"
    fi
    # THE assertion this leg exists for (#1091): config.json landing on disk proves the archive
    # was UNPACKED — it is a grep of a file the restore itself just wrote, so it is true even if
    # the stack never came back up on the restored config. So wait for the stack to actually come
    # up, then require a value sourced from the restored config to appear in LIVE state: the
    # --wallet argument the stack's own start path rendered into the p2pool container, read off
    # the container as created (#1662: p2pool's stratum stats, the earlier source, exist only once
    # a SYNCED monerod hands it a block template, which a restored guest never has in this window).
    # The verdict (restore_live_state_verdict) is fixture-tested at tier 1 (tests/stack/run.sh).
    local rsnames="" live_wallet="" verdict
    local rsdeadline
    rsdeadline=$(($(date +%s) + 900))
    while [ "$(date +%s)" -lt "$rsdeadline" ]; do
        rsnames=$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$rsnames" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$rsnames" in
    *dashboard*caddy* | *caddy*dashboard*)
        local lwdeadline
        lwdeadline=$(($(date +%s) + 180))
        while [ "$(date +%s)" -lt "$lwdeadline" ]; do
            live_wallet=$(_ssh "podman inspect p2pool --format '{{json .Config.Cmd}}'" 2>/dev/null | jq -r 'index("--wallet") as $i | if $i == null then "" else .[$i+1] // "" end')
            [ -n "$live_wallet" ] && [ "$live_wallet" != "Unknown" ] && [ "$live_wallet" != "null" ] && break
            sleep 10
        done
        ;;
    esac
    if verdict=$(restore_live_state_verdict "$rsnames" "$live_wallet" "$HARNESS_WALLET"); then
        ok "restore leg: $verdict"
    else
        bad "restore leg: $verdict"
        # A stack that never came up won't answer the identity check below either — stop here
        # rather than burn its 600s timeout on a machine already known to be broken.
        case "$rsnames" in
        *dashboard*caddy* | *caddy*dashboard*) ;;
        *)
            rm -f "$target_disk" "$restore_archive" "$restore_target"
            return
            ;;
        esac
    fi
    local new_onion="" tor_hostname=""
    local odeadline
    odeadline=$(($(date +%s) + 600))
    while [ "$(date +%s)" -lt "$odeadline" ]; do
        new_onion=$(_ssh "grep MONERO_ONION_ADDRESS /data/pithead/.env 2>/dev/null" | cut -d= -f2 | tr -d '\r')
        tor_hostname=$(_ssh "podman exec tor cat /var/lib/tor/monero/hostname 2>/dev/null" | tr -d '\r')
        [ -n "$new_onion" ] && [ -n "$tor_hostname" ] && break
        sleep 15
    done
    # .env is an archive member load_preserved_state replays verbatim when non-empty (pithead:6155-6166),
    # so new_onion == orig_onion proves only that the CONFIG FILE made the round trip — true even when
    # the Tor data dir (the onion PRIVATE KEYS) was dropped and Tor mints a fresh service underneath
    # (#1090). Only Tor's OWN hostname file, from the restored key material, proves the keys came back.
    if [ -n "$new_onion" ] && [ -n "$tor_hostname" ] && [ "$new_onion" = "$orig_onion" ] && [ "$tor_hostname" = "$orig_onion" ]; then
        ok "restore leg: restored machine kept the ORIGINAL Tor identity, not a regenerated one"
    else
        bad "restore leg: onion identity not restored (.env: $orig_onion -> ${new_onion:-none}, Tor's own hostname: ${tor_hostname:-none})"
    fi
    phase_install_prefill_submit_leg "$target_disk" # #1846, last: nothing after it needs the disk
    rm -f "$target_disk" "$restore_archive" "$restore_target"
}

phase_provision() {
    info "phase: provision (wizard HTTP submit -> setup -> stack containers up)"
    local img token jar scode

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
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return
    }

    jar=$(mktemp)
    # https, and PROVE the cookie landed: auth against :80 once hit the TLS redirect, whose 301
    # carries no cookie — curl -f called that success, the jar stayed empty, and the unauthenticated
    # submit's redirect ALSO read as success. Status codes and the jar are asserted, not inferred.
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
    # The browser's body (#1846): served config + HARNESS_WALLET (#829) + a dummy Tari address +
    # local_miner on (Both, #796; the local-miner leg asserts it) + auth_mode=auto — see the sibling.
    scode=$(provision_browser_submit "$ip" "$jar")
    [ "$scode" = "200" ] || {
        bad "config submit did not return 200 (got ${scode:-none} — a 30x means the session was not accepted)"
        rm -f "$jar"
        return
    }
    # The jar lives on: the handoff below is authenticated too (deleting it here once made the poll silently unauthenticated).
    ok "config submitted through the wizard"
    # The credentials handoff: the host publishes the generated login and HOLDS provisioning until
    # it is acknowledged (the page goes dark after). The login is kept for the OS-update check below.
    local handoff_body="" page_err=""
    tries=0
    while [ "$tries" -lt 24 ]; do
        handoff_body=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        if printf '%s' "$handoff_body" | grep -q '"password"'; then
            ok "generated credentials published to the page"
            break
        fi
        page_err=$(provision_page_error "$ip" "$jar")
        [ -z "$page_err" ] || break # the host refused: say what it said, not that it timed out
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] && [ -z "$page_err" ] || {
        bad "no credentials handoff appeared on the page${page_err:+ — the page says: $page_err}"
        rm -f "$jar"
        return
    }
    if printf '%s' "$handoff_body" | jq -r '.password // ""' | grep -qE '^[A-Za-z0-9]{32}$'; then
        ok "the card carries a generated 32-character password (auth_mode=auto, #1846)"
    else
        bad "the card's password is not a generated one: $(printf '%s' "$handoff_body" | jq -c '.password // null')"
    fi
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
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
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
        # `|| true`, never `|| echo 000`: on a connection failure curl ALREADY prints 000 (-w
        # always fires) and exits non-zero, so the echo appended a SECOND 000 — the retry case
        # below then matched neither, broke on the first iteration, and reported the impossible
        # "HTTP 000000". The loop existed to wait out exactly that state and never once waited.
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
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

    # ---- OS-update presence: the appliance state must carry os_update ------------------------
    # The header renders the OS update control (and suppresses the DIY tarball Upgrade button)
    # exactly when /api/state.os_update exists — seeded host-side for appliances only. Absent, an
    # operator has no reachable update path and the first update after GA means a reflash.
    local pv_user pv_pass
    pv_user=$(printf '%s' "$handoff_body" | jq -r '.username // "admin"' 2>/dev/null)
    pv_pass=$(printf '%s' "$handoff_body" | jq -r '.password // ""' 2>/dev/null)
    if [ -n "$pv_pass" ] && curl -sSk -u "$pv_user:$pv_pass" "https://$ip/api/state" 2>/dev/null |
        jq -e '.os_update.step' >/dev/null 2>&1; then
        ok "appliance state carries os_update — the dashboard OS-update control renders"
    else
        bad "no os_update in /api/state — the appliance has no reachable OS-update control"
    fi

    # ---- Tor-only egress backstop (#855): the fail-closed firewall must actually DROP -------
    # The whole product is Tor-first; the guarantee is that nothing CAN bypass Tor even if an app is
    # misconfigured, compromised, or dials a raw public IP. On the appliance the engine is podman+netavark,
    # and the old DOCKER-USER rules land in a chain no forwarded packet traverses — the firewall was fail-OPEN
    # while doctor and the boot log called it enforced. This leg dials clearnet FROM a mining-net container by
    # raw IP and asserts the drop. It is the check whose absence let a leaking appliance ship green: it FAILS
    # against the orphaned-chain code and PASSES once the nft table is installed. monerod sits on mining_net
    # (172.28.0.x) and syncs regardless of the mining hold, so it is the honest origin for the dial. monerod's
    # baked archive is the largest and loads last — dashboard+caddy answering (above) does not mean monerod
    # exists yet. A `podman exec` against a missing container fails exactly like a missing curl binary, which
    # used to blame the wrong thing (#887). Wait for it first.
    local monerod_deadline=$(($(date +%s) + 300)) monerod_present=0
    while [ "$(date +%s)" -lt "$monerod_deadline" ]; do
        case "$(_ssh "podman ps --format '{{.Names}}'" 2>/dev/null)" in
        *monerod*)
            monerod_present=1
            break
            ;;
        esac
        sleep 5
    done
    if [ "$monerod_present" -ne 1 ]; then
        bad "monerod container never came up — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
    elif _ssh "podman exec monerod sh -c 'command -v curl' >/dev/null 2>&1"; then
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
        bad "curl missing from the monerod image — cannot assert the Tor-only egress drop (the #855 backstop is unverified)"
    fi

    # ---- local-miner leg (#796): enable -> xmrig up -> wired to the machine's own stratum ---
    # The submit above asked to mine on the box itself, so the built-in RigForge worker must
    # come up without any hands: setup renders its config, runs its appliance-mode setup, and
    # the miner dials the machine's own stratum.
    #
    # The leg used to demand an accepted share, and that end of the chain cannot exist here: on a
    # fresh machine the product itself HOLDS p2pool and xmrig-proxy until the local chains sync
    # (#35 — the dashboard logs the hold and stops both), and a KVM guest syncing Monero over Tor
    # onto a 40 GiB scratch disk never clears that gate. No budget fixes a state the product
    # enforces on purpose. The share assertion lives where a synced node exists — the release e2e
    # on the bench. What the harness CAN prove, it now does, link by link: the miner runs, the hold
    # is the deliberate one (p2pool stopped CLEAN — a crash-looping p2pool, the #829 failure this
    # leg first caught, dies non-zero under the same gate), and the rendered worker config points
    # at this machine's own stratum.
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
    # #1724: the pool has a SECOND writer — xmrig runs as root and grows nr_hugepages through sysfs
    # before a large-page allocation, so the declared ceiling bounds the sizer alone. verify-image
    # pins the drop-in that SHIPPED; this reads what systemd LOADED, the pool, and the 1 GiB pool the
    # sizer never writes. Verdict + the ARMING caveat on it: tests/os/hugepages-boot-verdict.sh.
    if [ "$miner_up" -eq 1 ]; then
        local mhp mro m1g mv
        mhp=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" | tr -d '\r\n') || mhp=""
        mro=$(_ssh "systemctl show xmrig -p ReadOnlyPaths --value" | tr -d '\r\n') || mro=""
        m1g=$(_ssh "cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages" | tr -d '\r\n') || m1g=""
        if mv=$(hugepages_miner_verdict "$mhp" "$mro" "$m1g"); then ok "$mv"; else bad "$mv"; fi
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
    # pithead-boot owns recovery (#792): render the derived layer, compose up, health-gated slot commit.
    # Nothing may drive it here: no pithead command, no wizard. The failure mode this guards is a mining
    # appliance that sits dark after every power blip until a human logs in. The Caddyfile is corrupted FIRST
    # (#790): derived files are regenerated on every boot by construction, so a stale or broken one must not
    # survive — this is the defect that shipped new code against a days-old Caddyfile on hardware and killed
    # TLS.
    info "reboot leg — the stack must come back on its own (pithead-boot)"
    _ssh "echo '# corrupted by the harness — a regenerated boot must not serve this' > /data/pithead/Caddyfile" 2>/dev/null ||
        bad "could not corrupt the Caddyfile before the reboot"
    # And drop the baked-archive digest records: the wizard wrote them at first boot, so their
    # mere presence afterwards proves nothing. Gone, they must come back — that is
    # pithead-boot's own loader running on a provisioned machine (#798).
    _ssh "rm -f /data/pithead/data/.loaded-*.sha" 2>/dev/null ||
        bad "could not drop the digest records before the reboot"
    _reboot_wait reboot 300 || {
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
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
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
    # Hugepages sizing on supported RAM (#977): the sizing unit runs every boot before the
    # stack, and on this 16 GiB guest it must be a NO-OP — the full 3072-page (6 GiB) pool
    # intact and no degraded marker. A short pool here means the sizing shrank supported
    # hardware; a marker means it cried wolf. The degrade tiers themselves are tier-1 (stack
    # suite, meminfo fixtures) — a second low-RAM VM would re-prove arithmetic.
    local hp_prov
    hp_prov=$(_ssh "awk '/^HugePages_Total/{print \$2}' /proc/meminfo" 2>/dev/null) || hp_prov=""
    if [ -n "$hp_prov" ] && [ "$hp_prov" -ge 3072 ]; then
        ok "full hugepage pool intact on a provisioned boot ($hp_prov pages — sizing left supported RAM alone)"
    else
        bad "hugepage pool short on a provisioned boot (HugePages_Total: ${hp_prov:-unreadable}, want >= 3072) — the sizing unit degraded a supported machine"
    fi
    if _ssh "systemctl is-active --quiet pithead-hugepages.service"; then
        ok "hugepages sizing unit ran this boot"
    else
        bad "hugepages sizing unit did not run — a low-RAM machine would get the silent 6 GiB carve-out"
    fi
    if _ssh "test ! -f /run/pithead-hugepages-degraded"; then
        ok "no degraded-hugepages marker on a supported machine"
    else
        bad "degraded-hugepages marker present on the 16 GiB guest: $(_ssh 'cat /run/pithead-hugepages-degraded' 2>/dev/null | tr '\n' ' ' | cut -c1-160)"
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
    # The slot self-committed above off a HEALTHY stack. But "the dashboard answers" is a subset of "the stack
    # is alive": a slot whose monerod/p2pool crashed while caddy+dashboard keep serving is exactly the
    # healthy-looking-but-dead slot a curl-only gate committed. The real gate is `pithead doctor --json`
    # (os/overlay/pithead-boot); assert its DECISION both ways on this running stack. Reboot/fallback can't
    # show it here — RAUC's commit is sticky, so the already-committed slot won't re-arm — so we drive the
    # gate command the boot path runs and check its exit code. This is the assertion whose absence let the
    # curl-only gate ship green.
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

    # ---- migration hold (#851): a data_migration update starts the chain only POST-commit ----
    # The deadlock rule's automatic-fallback half: on the first boot of a flagged bundle, pithead-boot must
    # bring the stack up WITHOUT the chain services, commit on that reduced stack, and only then start monerod
    # — so a failed health check still falls back onto /data the old OS can read. The journal lines are the
    # race-free evidence (the hold and the release are both logged); the podman poll additionally proves
    # monerod never ran while the slot was uncommitted.
    info "migration leg — build a data_migration bundle, install via os-update, boot it"
    local mig_bundle
    mig_bundle=$(PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION="$(tr -d ' \n' <VERSION)" _build_bundle vmig) || {
        bad "migration bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    _stage_bundle "$mig_bundle" || {
        bad "staging the migration bundle failed"
        return
    }
    # os-update is the path that writes the pending marker (a bare rauc install does not) — and
    # this is also the first tier-4 exercise of os-update against a REAL bundle: it needs
    # unsquashfs on the appliance to read the manifest back, which CI's stubbed rauc never shows.
    local ou_out ou_rc
    ou_out=$(_ssh "cd /data/pithead && ./pithead os-update /data/update.bundle --yes 2>&1")
    ou_rc=$?
    if [ "$ou_rc" -ne 0 ]; then
        osupdate_failure_evidence "$ou_rc" "$ou_out" # both transport ends + the console, at the moment of death
        bad "pithead os-update failed on the guest — see the guest evidence above, and do not restate the cause without reading it"
        return
    fi
    marker=$(_ssh "cat /data/pithead/.os-migration-pending 2>/dev/null" | tr -d ' \r\n')
    if [ -n "$marker" ]; then
        ok "os-update left the migration-pending marker ($marker)"
    else
        bad "no migration-pending marker after installing a data_migration bundle"
        return
    fi
    _reboot_wait reboot 300 || {
        bad "guest never returned after booting the migration bundle"
        return
    }
    # Poll through the boot. The release line is logged at the commit boundary, BEFORE the
    # post-commit up — so any monerod observed running before that line is a chain service
    # beating the fallback decision, the exact ordering this rule exists to forbid.
    local chain_ran_early=0 released=0
    for _ in $(seq 120); do
        if _ssh "journalctl -u pithead-boot -b 2>/dev/null | grep -q 'chain services released'"; then
            released=1
            break
        fi
        if _ssh "podman ps --format '{{.Names}}' 2>/dev/null | grep -qx monerod"; then
            chain_ran_early=1
        fi
        sleep 5
    done
    if [ "$released" = 1 ]; then
        ok "the migrating slot committed and released the chain services"
    else
        bad "the migrating slot never reached the post-commit release — the hold deadlocked the gate it was built not to"
        return
    fi
    if [ "$chain_ran_early" = 0 ]; then
        ok "monerod never ran while the slot was uncommitted"
    else
        bad "monerod ran BEFORE the commit — the migration would beat the fallback decision"
    fi
    if _ssh "journalctl -u pithead-boot -b | grep -q 'holding chain services'"; then
        ok "boot journal shows the chain hold"
    else
        bad "no 'holding chain services' line in the boot journal — the hold path never ran"
    fi
    # After the release: monerod back up, marker consumed.
    local mig_node_up=0
    for _ in $(seq 60); do
        if _ssh "podman ps --format '{{.Names}}' 2>/dev/null | grep -qx monerod"; then
            mig_node_up=1
            break
        fi
        sleep 5
    done
    if [ "$mig_node_up" = 1 ]; then
        ok "monerod is running again post-commit (the migration window is over)"
    else
        bad "monerod never came back after the commit"
    fi
    if _ssh "test -f /data/pithead/.os-migration-pending"; then
        bad "the migration-pending marker survived the commit"
    else
        ok "the migration-pending marker was consumed"
    fi
    phase_provision_floor_fallback_leg "$mig_bundle"
}

# Build a small raw disk with one FAT partition carrying $2 as pithead-config.json at its root —
# the media the physical-presence channel reads. $1: output path.
_make_media_stick() {
    local path="$1" json="$2" loop mnt tries=0
    rm -f "$path"
    truncate -s 64M "$path"
    sgdisk -n1:0:0 -t1:0700 "$path" >/dev/null
    loop=$(losetup -Pf --show "$path")
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mkfs.vfat -n PITHEAD "${loop}p1" >/dev/null
    mnt=$(mktemp -d)
    mount "${loop}p1" "$mnt"
    printf '%s' "$json" >"$mnt/pithead-config.json"
    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$loop"
}

# Hot-attach $1 to the running guest as a REMOVABLE usb stick. attach-disk cannot express
# removable='on', and the media channel's discovery filter keys on lsblk RM=1 — exactly what a
# physical stick reports and what the install phase's virt-install disks already declare.
_attach_media_stick() {
    cat >"$DISK.stick.xml" <<EOF
<disk type='file' device='disk'>
  <driver name='qemu' type='raw'/>
  <source file='$1'/>
  <target dev='sdz' bus='usb' removable='on'/>
</disk>
EOF
    virsh attach-device "$VM" "$DISK.stick.xml" --config --live >/dev/null 2>&1
}
_detach_media_stick() {
    virsh detach-device "$VM" "$DISK.stick.xml" --config --live >/dev/null 2>&1
}

# Does $1 (a raw disk with one FAT partition) still carry pithead-config.json at its root? Used after a boot
# to prove the applied stick was consumed. Host-side, so the disk must already be detached from the guest.
_media_stick_has_config() {
    local path="$1" loop mnt tries=0 rc=1
    loop=$(losetup -Pf --show "$path")
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    mount -o ro "${loop}p1" "$mnt" 2>/dev/null && {
        [ -f "$mnt/pithead-config.json" ] && rc=0
        umount "$mnt"
    }
    rmdir "$mnt"
    losetup -d "$loop"
    return $rc
}

phase_media() {
    info "phase: media (physical-presence config channel — removable stick applied at boot)"
    # ponytail: provisions via the ESP pre-seed path (already proven by the install phase's
    # second leg) rather than re-driving the wizard's HTTP flow — this phase is about the SECOND
    # stick, read by a running appliance, not first-boot setup.
    local img loop mnt tries=0
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    loop=$(losetup -Pf --show "$img")
    while [ ! -e "${loop}p1" ] && [ "$tries" -lt 50 ]; do
        sleep 0.1
        tries=$((tries + 1))
    done
    mnt=$(mktemp -d)
    mount "${loop}p1" "$mnt"
    printf '{"monero":{"wallet_address":"%s"},"tari":{"wallet_address":"%s"},"p2pool":{"pool":"mini","stratum_password":"auto"}}' \
        "$HARNESS_WALLET" "$HARNESS_TARI" >"$mnt/pithead-config.json"
    umount "$mnt"
    rmdir "$mnt"
    losetup -d "$loop"

    _vm_boot_disk "$img" && _wait_ssh 300 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    if ! _ssh "for i in \$(seq 90); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the ESP pre-seed never reached the running system — nothing to change from here"
        return
    fi
    local deadline=$(($(date +%s) + 1500)) names=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in *dashboard*caddy* | *caddy*dashboard*) break ;; esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ok "provisioned via ESP pre-seed, stack up ($ip)" ;;
    *)
        bad "stack never came up within 25m — running: '${names:-none}'"
        return
        ;;
    esac

    # ---- apply leg: a real change, shown, counted down, applied, consumed --------------------
    # A MINIMAL stick on purpose — wallet + pool, nothing else. Settings it does not name must
    # keep their running values: the full-replace bug unset the generated dashboard password
    # (serving the dashboard to the LAN with no login), dropped the appliance defaults, and
    # regenerated the node credentials on every apply. Capture the pre-apply values now so the
    # post-apply asserts compare against what the machine actually had.
    local old_pw old_user old_npw
    old_pw=$(_ssh "jq -r '.dashboard.auth.password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    old_user=$(_ssh "jq -r '.dashboard.auth.username // \"admin\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    old_npw=$(_ssh "jq -r '.monero.node_password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ -n "$old_pw" ] && ok "a generated dashboard password exists before the media apply" ||
        bad "no generated dashboard password before the media apply — nothing to preserve"

    local stick1="${DISK%.img}-media-apply.img"
    # A DIFFERENT valid primary address than HARNESS_WALLET (an earlier copy-paste made them
    # identical, so the "changed wallet" leg changed nothing and the wallet assert could never
    # match). The Monero project's donation address: public, checksum-valid, safe as a fixture.
    local new_wallet="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"
    _make_media_stick "$stick1" \
        "{\"monero\":{\"wallet_address\":\"$new_wallet\"},\"p2pool\":{\"pool\":\"nano\"}}"
    _attach_media_stick "$stick1"
    : >"$SERIAL"
    _ssh reboot >/dev/null 2>&1 || true

    wait_serial "staged configuration differs from the running one" 180 &&
        ok "the exact diff is shown on the console before anything applies" ||
        bad "no diff banner appeared on the console"
    if tr -d '\r' <"$SERIAL" | grep -qE "$new_wallet"; then
        ok "the changed wallet address is shown in full — verifying it is the point"
    else
        bad "the changed wallet address never appeared on the console"
    fi
    wait_serial "Media configuration channel: applied" 120 &&
        ok "the countdown ran out and the change applied" ||
        bad "no applied confirmation ever appeared on the console"
    _wait_ssh 180 || {
        bad "guest never came back after the applied change"
        return
    }
    local pool_now
    pool_now=$(_ssh "jq -r '.p2pool.pool' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$pool_now" = "nano" ] && ok "the changed setting took effect (p2pool.pool: mini -> nano)" ||
        bad "the changed setting did not take effect (p2pool.pool is '${pool_now:-unknown}')"

    # ---- preservation asserts: everything the minimal stick did not name is still there ------
    local pw_now ctl_now heal_now npw_now
    pw_now=$(_ssh "jq -r '.dashboard.auth.password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    if [ -n "$old_pw" ] && [ "$pw_now" = "$old_pw" ]; then
        ok "the dashboard password the stick never named is unchanged — the old login still holds"
    else
        bad "the dashboard password was dropped or regenerated by a stick that never named it"
    fi
    ctl_now=$(_ssh "jq -r '.dashboard.control.enabled' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    heal_now=$(_ssh "jq -r '.tor.auto_heal' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$ctl_now" = "true" ] && [ "$heal_now" = "true" ] &&
        ok "the appliance defaults survive a minimal stick (control channel on, tor auto-heal on)" ||
        bad "appliance defaults dropped (control.enabled=$ctl_now tor.auto_heal=$heal_now)"
    npw_now=$(_ssh "jq -r '.monero.node_password // \"\"' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ -n "$npw_now" ] && [ "$npw_now" = "$old_npw" ] &&
        ok "the node credentials do not churn on a media apply" ||
        bad "monero node credentials were regenerated by a stick that never named them"

    # The end-to-end proof the issue asks for: after the minimal-stick apply, the served dashboard still
    # DEMANDS a login, and the pre-apply credentials still open it. Poll until caddy answers — the pool change
    # restarts the stack, so the front door lags the reboot. One readiness deadline covers BOTH probes: a
    # post-apply boot re-loads every baked image before compose up, and under bench load that runs past 10
    # minutes with caddy up (401) while the dashboard behind it still answers 502. The bench proved every
    # intermediate (000/000, 401/502, late-2xx) is the same slow settle — so poll each probe to its OWN
    # success within a shared 900 s window instead of judging a settling stack once.
    local http_deadline=$(($(date +%s) + 900)) code=000 authed=000
    while [ "$(date +%s)" -lt "$http_deadline" ]; do
        code=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 "https://$ip/" 2>/dev/null || true)
        case "$code" in 000 | 5??) sleep 10 ;; *) break ;; esac
    done
    if [ "$code" = "401" ]; then
        ok "the dashboard still demands a login after the minimal-stick apply (HTTP 401)"
    else
        bad "the dashboard answered HTTP $code without credentials after the minimal-stick apply"
    fi
    while [ "$(date +%s)" -lt "$http_deadline" ]; do
        authed=$(curl -ksS -o /dev/null -w '%{http_code}' -m 8 -u "$old_user:$old_pw" "https://$ip/" 2>/dev/null || true)
        case "$authed" in 000 | 5??) sleep 10 ;; *) break ;; esac
    done
    case "$authed" in
    2?? | 3??) ok "the pre-apply dashboard login still works (HTTP $authed)" ;;
    *) bad "the pre-apply dashboard login no longer works (HTTP $authed)" ;;
    esac

    _detach_media_stick
    sleep 2
    if _media_stick_has_config "$stick1"; then
        bad "the applied stick still carries pithead-config.json — it would re-apply next boot"
    else
        ok "the applied stick is consumed — it cannot re-apply on a later boot"
    fi
    rm -f "$stick1"

    # ---- abort leg: pulling the media mid-countdown cancels the change -----------------------
    local stick2="${DISK%.img}-media-abort.img"
    _make_media_stick "$stick2" \
        "{\"monero\":{\"wallet_address\":\"$HARNESS_WALLET\"},\"tari\":{\"wallet_address\":\"$HARNESS_TARI\"},\"p2pool\":{\"pool\":\"mini\",\"stratum_password\":\"auto\"}}"
    _attach_media_stick "$stick2"
    : >"$SERIAL"
    _ssh reboot >/dev/null 2>&1 || true
    wait_serial "staged configuration differs from the running one" 180 || bad "no diff banner on the abort leg"
    # Pull the medium mid-countdown — the deliberate physical act that cancels a pending change.
    _detach_media_stick || info "detach-device returned rc $? — the guest may still see the stick"
    # Full expected text (#1061): a bare "cancelled" would also match boot noise. On a miss, keep this
    # boot's console (no-clobber, as cleanup does) and quote the channel's last line, so the red carries it.
    wait_serial "Media configuration channel: cancelled" 90 &&
        ok "removing the media mid-countdown cancels the change, and says so on the console" || {
        [ -f "$SERIAL.failed" ] || [ ! -s "$SERIAL" ] || cp "$SERIAL" "$SERIAL.failed" 2>/dev/null
        bad "no cancellation confirmation on the console within 90 s of the pull — the channel's last line: '$(tr -d '\r' 2>/dev/null <"$SERIAL" | grep -o 'Media configuration channel: .*' | tail -1)'; console kept at $SERIAL.failed"
    }
    _wait_ssh 180 || {
        bad "guest never came back after the cancelled change"
        return
    }
    pool_now=$(_ssh "jq -r '.p2pool.pool' /data/pithead/config.json" 2>/dev/null | tr -d '\r')
    [ "$pool_now" = "nano" ] && ok "a cancelled change never took effect (p2pool.pool stayed nano)" ||
        bad "a cancelled change altered the running config anyway (p2pool.pool is '${pool_now:-unknown}')"
    rm -f "$stick2"
}

_rig_mining_up() { # <tries>, 10 s apart — 0 once the xmrig unit is active with its process up
    local n=0
    while [ "$n" -lt "$1" ]; do
        _ssh "systemctl is-active --quiet xmrig && pgrep -x xmrig >/dev/null" && return 0
        sleep 10
        n=$((n + 1))
    done
    return 1
}

phase_rig() {
    info "phase: rig (the OTHER machine this image installs — mines instead of coordinating)"
    # One image, two machines. Every other phase proves the coordinator; this one proves that
    # answering "RigForge" produces a box with no stack at all, mining the baked binary without
    # compiling or reaching the network, that takes an A/B update exactly like a coordinator. A
    # rig has no dashboard to complain through, so one that never starts is invisible otherwise.
    local img token jar body scode marker card card_tok rtok pcode ptries=0

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
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return
    }
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

    # The pool: the guest's OWN sshd — a KVM guest has no Pithead on its LAN, and the host-side gate only
    # dials a TCP listener before committing. It deliberately does NOT prove an accepted share (the same
    # limit the coordinator's local-miner leg documents). XMRig dials it, gets no stratum and retries
    # forever, which is the point: the miner must come up and STAY up on a pool that does not answer.
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
        card=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        case "$card" in *'"worker"'*) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no rig card appeared on the page"
        rm -f "$jar"
        return
    }
    case "$card" in
    *'"password"'*) bad "the rig card published a dashboard password — a rig serves no dashboard" ;;
    *) ok "the rig card is worker + pool, with no login (a rig has none)" ;;
    esac
    card_tok=$(printf '%s' "$card" | jq -r '.token // ""' 2>/dev/null)
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || true
    rm -f "$jar"

    # ---- the machine that came out: a rig, not a small coordinator ------------------------
    if _rig_mining_up 36; then
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
    # #1836: the rig's token guards every API, the sister feed the coordinator probes exists, and the
    # writable control path is pinned to the pool host — 127.0.0.1 here, so the guest probes itself over
    # loopback and this host, an unpinned source, is dropped (loopback answering proves the port is alive).
    rtok=$(_ssh "jq -r '.ACCESS_TOKEN // \"\"' /data/rigforge/config.json" | tr -d '\r')
    [[ "$rtok" =~ ^[0-9a-f]{32}$ ]] && ok "the miner's config carries a minted 32-hex control token" || bad "no control token in the rig's config (got '${rtok:0:8}')"
    [ -n "$card_tok" ] && [ "$card_tok" = "$rtok" ] && ok "the rig card showed the SAME token the miner enforces" || bad "the card's token ('${card_tok:0:8}') is not the miner's ('${rtok:0:8}')"
    _ssh "jq -e '.api == \"enabled\" and .control == \"enabled\" and .api_allow_from == \"127.0.0.1\" and (has(\"control_upgrade\") | not)' /data/rigforge/config.json >/dev/null" &&
        ok "sister API + control enabled, pinned to the pool host; control_upgrade untouched" ||
        bad "the rig's API keys are not what #1836 renders: $(_ssh "jq -c 'del(.pools, .ACCESS_TOKEN)' /data/rigforge/config.json" | cut -c1-120)"
    _rig_http() { _ssh "curl -s -m 5 -o /dev/null -w '%{http_code}' $*" 2>/dev/null | tr -d '\r'; }
    while [ "$ptries" -lt 12 ] && [ "$(_rig_http -H "'Authorization: Bearer $rtok'" http://127.0.0.1:8081/1/summary)" != "200" ]; do
        sleep 5
        ptries=$((ptries + 1))
    done
    [ "$ptries" -lt 12 ] && ok "the sister feed answers 200 with the token" || bad "the sister feed never answered 200 with the token"
    pcode=$(_rig_http http://127.0.0.1:8081/1/summary)
    [ "$pcode" = "401" ] && ok "the sister feed refuses without the token (401)" || bad "the sister feed answered '${pcode}' without a token"
    pcode=$(_rig_http http://127.0.0.1:8080/1/summary)
    case "$pcode" in 401 | 403) ok "XMRig's own API is closed without the token ($pcode)" ;; *) bad "XMRig's API on 8080 answered '${pcode}' with no token — still open on the LAN" ;; esac
    pcode=$(_rig_http http://127.0.0.1:8082/)
    [ -n "$pcode" ] && [ "$pcode" != "000" ] && ok "the control port listens (loopback answers $pcode)" || bad "the control port does not answer even on loopback ('${pcode}')"
    pcode=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$ip:8082/" 2>/dev/null)
    [ "${pcode:-000}" = "000" ] && ok "the control port is unreachable from an unpinned source (this host)" || bad "the control port answered '$pcode' from an unpinned source"
    # THE assertion of this phase: no stack. Not a stopped stack, not a held one — none started.
    local names
    names=$(_ssh "podman ps -a --format '{{.Names}}'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -z "${names// /}" ]; then
        ok "no compose stack was started — no containers exist at all on a rig"
    else
        bad "a rig started containers: '$names'"
    fi
    # Prebuilt-first, proven by identity: a recompile gives a DIFFERENT binary; a clone has no path to github.
    if _ssh "cmp -s /data/rigforge/data/worker/xmrig/build/xmrig /opt/rigforge/prebuilt/xmrig/build/xmrig"; then
        ok "the rig mines the BAKED binary byte for byte — no compile, no clone, no clearnet"
    else
        bad "the running miner is not the baked prebuilt — something compiled or fetched on first boot"
    fi
    # Removable-root tolerance: an in-memory journal, so a stick root takes no rotating writes (the role's setting, not the medium's).
    [ "$(_ssh 'systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -c "^Storage=volatile"')" != "0" ] &&
        ok "journald is volatile on a rig (a rig's root may be the stick it mines from)" ||
        bad "journald is still persistent on a rig — a USB root would take rotating writes"

    # ---- reboot: pithead-boot owns a rig now, and commits its slot -------------------------
    info "reboot leg — the rig must come back mining, and commit its own slot"
    _reboot_wait reboot 300 || {
        bad "the rig never returned from the reboot"
        return
    }
    _rig_mining_up 24 &&
        ok "the rig returned mining with no hands on it (its unit lives in /run and died with the reboot)" ||
        bad "the rig did not return after the reboot — its runtime unit was never re-rendered"
    # WHICH unit owns the boot is the whole R4 fork: the wizard's window is closed, pithead-boot runs.
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
    # The commit gate, rig-shaped: a rig that cannot commit rolls back every update; the pool answers nothing, and must not matter.
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
    rig_setup_again_legs "$card_tok" "$token" # #1318: Keep it, then Set up again as the same rig (tests/os/setup-again-leg.sh)

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
    _reboot_wait "$(_boot_spare_cmd)" 300 || {
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
    _rig_mining_up 24 && ok "the rig mines again on the updated slot" ||
        bad "the rig stopped mining after the A/B update"
    # No harness mark-good: the boot that just brought the miner up must have COMMITTED — a rig commits on the
    # miner running, the same event this leg just waited for. That coupling is also why an "uncommitted
    # revert" is not observable here: on a provisioned rig the commit window closes the moment the miner is up
    # (seconds), which is the property itself, not a gap. The generic uncommitted-fallback machinery — same
    # grub.cfg, same RAUC — is proven by the update phase on an unprovisioned box, where no boot path
    # self-commits. This leg's first run asserted the revert anyway and refuted ITSELF: the rig had already
    # committed, the reboot stayed v2, and a follow-up install then targeted the wrong slot.
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
    _reboot_wait reboot 300 || {
        bad "the rig never returned after the post-commit reboot"
        return
    }
    marker=$(_ssh cat /etc/pithead-test-marker | tr -d '\r\n')
    [ "$marker" = "v2" ] && ok "COMMIT: the update persists on the rig across reboot" ||
        bad "expected v2 on the rig after commit, got '$marker'"
    rig_setup_again_coordinator_leg "$token" # #1318: Set up again as a coordinator, from the updated slot
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
    local corrupt_rc=0
    out=$(_ssh "$(_install_cmd /data/update.bundle) 2>&1") || corrupt_rc=$?
    if printf '%s' "$out" | grep -qi "panic"; then
        bad "C: the updater PANICKED on a corrupt bundle instead of refusing it"
        info "  $(printf '%s' "$out" | grep -i panic | head -1 | cut -c1-150)"
    elif [ "$corrupt_rc" -eq 0 ]; then
        # The old check only asserted the absence of "panic" — an install that quietly ACCEPTED
        # the tampered bundle read as a pass. The refusal itself is the assertion.
        bad "C: a corrupted/tampered bundle was ACCEPTED (installer exited 0)"
    else
        ok "C: a corrupt bundle is refused without crashing (exit $corrupt_rc)"
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
    local before
    before=$(_boot_id) || bad "could not read the boot id before the install — a reconnect and a reboot would look alike"
    [ -n "$before" ] || return
    out=$(_ssh "$(_install_and_boot_cmd /data/update.bundle) 2>&1" || true)
    [ -n "$out" ] && info "install output: $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-160)"
    _wait_new_boot "$before" 300 || {
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

    # Operator-initiated rollback: a release can be bad without failing its health check, so the operator must
    # be able to put the previous version back on demand — not only wait for an automatic fallback.
    info "operator-initiated rollback"
    marker=$(_marker)
    if _reboot_wait "$(_rollback_cmd)" 300; then
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

# The last-resort path — never yet run against a real disk. Two legs, opt-in (destructive, and
# the recovery leg re-partitions/re-mounts a disk out from under a running guest).
#
#   leg 1  a PROVISIONED machine runs `pithead factory-reset -y` — the real command, not a
#          reimplementation of it — which arms the `pithead-reset` marker on the ESP
#          ($PRESEED_DIR/pithead-reset, default /boot/efi) and reboots. pithead-data-reset picks
#          the marker up before /data mounts, reformats it, and consumes the marker. Assert the
#          machine comes back to the wizard without bricking, the provisioned config and old
#          container images are gone, and — the reset-tier rule — host identity (SSH host-key
#          fingerprint, machine-id) is FRESH, not carried over: a handed-over box must not keep
#          the old owner's identity (os/overlay/pithead-data-reset). The reseed directive itself
#          (systemd-repart's MakeDirectories= for the overlay/var upperdirs and /pithead) is
#          proven statically against the built image in tests/os/verify-image.sh (#1092) — a
#          post-boot dir check here cannot observe a dropped entry honestly (see the comment at
#          the assertion site below).
#   leg 2  the OTHER trigger: a data partition that will not mount even after fsck. Corrupt the
#          ext4 magic on partition 4 (the fixed data slot) from the HOST, on the powered-off
#          disk, then boot and assert the box self-heals into the wizard instead of bricking.
phase_reset() {
    info "phase: reset (factory-reset ESP marker + wedged-/data recovery — opt-in, destructive)"
    local img token tries jar scode names deadline

    info "leg 1 — factory-reset must wipe /data and return a FRESH machine to the wizard"
    img=$(_build_image v1) || {
        bad "image build failed (/tmp/os-fault-build.log)"
        return
    }
    _vm_boot_disk "$img" && _wait_ssh 240 || {
        bad "guest never answered SSH (ip: ${ip:-none})"
        return
    }
    ok "image boots ($ip)"

    token="" tries=0
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token ever appeared on the console"
        return
    }
    _wait_setup_page 120 || {
        bad "wizard gate never served"
        return
    }

    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "token was not accepted"
        rm -f "$jar"
        return
    }
    scode=$(curl -sSk -b "$jar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" \
        "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "config submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    tries=0
    while [ "$tries" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no credentials handoff appeared on the page"
        rm -f "$jar"
        return
    }
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null
    rm -f "$jar"
    ok "config submitted and provisioning released"

    if ! _ssh "for i in \$(seq 120); do [ -f /data/pithead/config.json ] && exit 0; sleep 2; done; exit 1"; then
        bad "the submitted config never became /data/pithead/config.json"
        return
    fi
    ok "provisioned: config installed by the host"

    names="" deadline=$(($(date +%s) + 1500))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        names=$(SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh "podman ps --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ')
        case "$names" in
        *dashboard*caddy* | *caddy*dashboard*) break ;;
        esac
        sleep 15
    done
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*)
        ok "stack containers are running ahead of the reset ($names)"
        ;;
    *)
        bad "stack never came up before the reset — running: '${names:-none}'"
        return
        ;;
    esac

    # Baseline, captured on the machine ABOUT to be wiped.
    local id_before fp_before images_before
    id_before=$(_ssh cat /etc/machine-id)
    fp_before=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    images_before=$(_ssh "podman images --format '{{.Repository}}'" 2>/dev/null | tr '\n' ' ')
    if [ -n "$id_before" ] && [ -n "$fp_before" ] && printf '%s' "$images_before" | grep -q dashboard; then
        ok "pre-reset baseline: machine-id $id_before, host-key $fp_before, images present ($images_before)"
    else
        bad "could not capture a full pre-reset baseline (id: ${id_before:-none}, fp: ${fp_before:-none}, images: ${images_before:-none})"
        return
    fi

    # The real command an operator runs — not a reimplementation of it (factory_reset() in
    # `pithead`). It arms the ESP marker and reboots; the ssh connection drops with the reboot.
    if _reboot_wait "cd /data/pithead && ./pithead factory-reset -y" 300; then
        ok "guest returned after the factory-reset reboot"
    else
        bad "guest never returned after factory-reset — BRICKED"
        return
    fi

    if _wait_setup_page 120; then
        ok "machine comes back UNPROVISIONED — the wizard token gate serves again"
    else
        bad "no wizard gate after factory-reset — the machine did not return to first-boot"
    fi
    if _ssh "test -f /data/pithead/config.json"; then
        bad "the provisioned config.json survived factory-reset"
    else
        ok "the provisioned config is gone"
    fi
    # #1092: a post-boot `test -d` here is true by construction, not a check of the reseed. The overlay/var +
    # var-work upperdirs cannot be observed missing at this point — with no `nofail` on that fstab line
    # (os/rauc/populate-slot.sh), a missing upperdir fails local-fs.target on this read-only root and the box
    # never answers SSH, so the leg would already have bailed above at "guest never returned after
    # factory-reset — BRICKED". And /data/pithead is recreated by pithead-sync's own `mkdir -p` on every boot
    # (os/overlay/pithead-sync) whether or not repart seeded it, so its presence here proves the sync script
    # ran, not that the seed worked. The seeding mechanism itself — systemd-repart's MakeDirectories= for all
    # three dirs — is asserted statically against the built image in tests/os/verify-image.sh, the one place
    # that can actually observe a dropped entry. What THIS leg proves is the pair above: the reformat+reboot
    # cycle didn't brick, and it landed back at an unprovisioned wizard. The dashboard image is BAKED into the
    # OS image (the wizard archive) and legitimately reloaded onto the fresh store by the post-reset wizard
    # boot — its presence proves nothing. The wipe probe is an image that only ever arrives by PULL at
    # provision time: monerod.
    local images_after
    images_after=$(_ssh "podman images --format '{{.Repository}}'" 2>/dev/null | tr '\n' ' ')
    if printf '%s' "$images_after" | grep -q monero; then
        bad "the OLD container store survived factory-reset (still has: $images_after)"
    else
        ok "container store was recreated — no pulled stack images survive the wipe (podman images: ${images_after:-none})"
    fi

    # The reset-tier rule (os/overlay/pithead-data-reset): /data/ssh and /data/pithead/machine-id
    # are deliberately NOT reseeded, so both regenerate — a handed-over box keeps nothing OF THE
    # OWNER'S. A bare inequality already caught one real bug (a dbus-baked machine-id shared by
    # every image, fixed in the rootfs Dockerfile) but cannot pass HERE even when the product is
    # right: with that bake gone, systemd's next first-boot source inside a VM is the DMI product
    # UUID (machine-id(5) — VM-only; real hardware falls through to random), and this leg reboots
    # ONE VM, so the "fresh" id is deterministically the same. The honest assert: the regenerated
    # id is the PLATFORM's (DMI-derived — machine identity, like a serial number) or it changed
    # (the real-hardware shape). Only an id that is neither proves owner state carried over.
    local id_after fp_after dmi_id
    id_after=$(_ssh cat /etc/machine-id)
    fp_after=$(_ssh ssh-keygen -lf /data/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $2}')
    dmi_id=$(_ssh "cat /sys/class/dmi/id/product_uuid 2>/dev/null" | tr -d '-' | tr 'A-F' 'a-f')
    if [ -n "$id_after" ] && { [ "$id_after" != "$id_before" ] || [ "$id_after" = "$dmi_id" ]; }; then
        ok "machine-id regenerated from the platform after factory-reset ($id_after${dmi_id:+, matches DMI})"
    else
        bad "machine-id survived factory-reset (before: $id_before, after: ${id_after:-none}, dmi: ${dmi_id:-none}) — the old owner's identity carried over"
    fi
    if [ -n "$fp_after" ] && [ "$fp_after" != "$fp_before" ]; then
        ok "SSH host-key fingerprint is FRESH after factory-reset ($fp_before -> $fp_after)"
    else
        bad "SSH host-key fingerprint survived factory-reset (before: $fp_before, after: ${fp_after:-none})"
    fi

    # ---- leg 2: a wedged /data must be REPAIRED, not erased --------------------------------
    info "leg 2 — a corrupt data-partition superblock must be repaired, with /data still there afterwards"
    # A sentinel standing in for what /data actually holds: the wallets, the Tor onion private keys,
    # the dashboard database and both synced chains. Until #1062 this leg asked only whether the box
    # came back to the wizard, which a full reformat satisfies — so a green battery certified the
    # data loss (#1087). The question is not "did it boot", it is "is the irreplaceable thing still
    # there". A reformat cannot pass this.
    _ssh "mkdir -p /data/pithead && printf 'IRREPLACEABLE-KEY-MATERIAL\n' > /data/pithead/.battery-sentinel && sync" || {
        bad "could not plant the /data survival sentinel"
        return
    }
    # Leg 1's factory reset was a REAL wipe and correctly recorded one, so the note already exists
    # here. What leg 2 must not do is add to it: the count is the question, not the presence.
    local wipes_before
    wipes_before=$(_ssh "wc -l < /boot/efi/pithead-data-wiped 2>/dev/null" | tr -cd '0-9')
    [ -n "$wipes_before" ] || wipes_before=0
    _ssh "systemctl poweroff" 2>/dev/null || true
    tries=0
    while [ "$tries" -lt 60 ]; do
        [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$(virsh domstate "$VM" 2>/dev/null)" = "shut off" ] || {
        bad "guest never powered off cleanly before corrupting the data partition"
        return
    }

    # Corrupt the ext4 magic (2 bytes at offset 1080 — the 1024-byte superblock plus s_magic at
    # 0x38) on partition 4, the fixed data slot pithead-data-reset itself derives by number. Done
    # from the HOST against the powered-off disk, via a loop device with partition scanning:
    # dd'ing a MOUNTED filesystem's superblock risks the live kernel writing the correct bytes
    # straight back before the corruption is ever read at the next mount.
    local loopdev
    loopdev=$(losetup -f) || {
        bad "no free loop device to corrupt the data partition"
        return
    }
    if losetup -P "$loopdev" "$DISK"; then
        have udevadm && udevadm settle 2>/dev/null
        sleep 1
        if [ -b "${loopdev}p4" ] &&
            dd if=/dev/zero of="${loopdev}p4" bs=1 seek=1080 count=2 conv=notrunc >/dev/null 2>&1; then
            ok "corrupted the ext4 magic on the data partition (${loopdev}p4)"
        else
            bad "could not corrupt ${loopdev}p4 (partition node missing or dd failed)"
            losetup -d "$loopdev" 2>/dev/null || true
            return
        fi
    else
        bad "losetup -P failed to attach $DISK"
        return
    fi
    losetup -d "$loopdev" 2>/dev/null || true

    virsh start "$VM" >/dev/null 2>&1 || {
        bad "guest would not start after the corruption"
        return
    }
    if _wait_ssh 300; then
        ok "guest survived a wedged /data — no brick"
    else
        bad "BRICKED — no boot after a corrupt data-partition superblock (disqualifying)"
        return
    fi
    if _wait_setup_page 120; then
        ok "the box came back usable after the corrupt superblock"
    else
        bad "no wizard gate after the wedged-/data recovery — the box did not come back usable"
    fi
    # The assertion that a reformat cannot satisfy: `fsck -p` refuses a corrupt primary superblock,
    # so before #1062 this partition was handed to mkfs.ext4 -F and the sentinel died with it.
    if [ "$(_ssh "cat /data/pithead/.battery-sentinel 2>/dev/null" | tr -d '\r')" = "IRREPLACEABLE-KEY-MATERIAL" ]; then
        ok "/data SURVIVED the corrupt superblock — it was repaired, not erased (#1062)"
    else
        bad "DATA LOSS — /data was reinitialized rather than repaired; a real box loses its wallets and onion keys here (#1062)"
    fi
    # And the wipe log must not have grown: a repair is not a wipe, and evidence that cries wolf
    # is worse than none — the operator would restore from backup over a machine that kept its data.
    local wipes_after
    wipes_after=$(_ssh "wc -l < /boot/efi/pithead-data-wiped 2>/dev/null" | tr -cd '0-9')
    [ -n "$wipes_after" ] || wipes_after=0
    if [ "$wipes_after" = "$wipes_before" ]; then
        ok "the ESP wipe log did not grow ($wipes_before line(s), from leg 1's real factory reset) — a repair is not recorded as a wipe"
    else
        bad "a repaired /data recorded a wipe on the ESP ($wipes_before -> $wipes_after) — the evidence would cry wolf"
    fi
    # Leg 1's own wipe SHOULD be in there: the recording path is real, not dead code.
    if [ "$wipes_before" -gt 0 ] 2>/dev/null; then
        ok "leg 1's factory reset was recorded on the ESP ($wipes_before line(s))"
    else
        bad "leg 1 reformatted /data and left no record on the ESP — a wiped machine is indistinguishable from a fresh one (#1062)"
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
media) phase_media ;;
fault) phase_fault ;;
reset) phase_reset ;;
all)
    # ALL of them. This arm once ran five of eight while the release checklist told a maintainer
    # that step 1 covered everything — the mid-write and mid-commit power cuts, the corrupt-bundle
    # refusal, the factory reset, the wedged-/data recovery and the media channel omitted (#1064).
    phase_boot
    phase_update
    phase_install
    phase_provision
    phase_rig
    phase_media
    phase_fault
    phase_reset
    ;;
*)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

printf '\nos harness: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
