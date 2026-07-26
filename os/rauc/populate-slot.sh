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

populate_slot() { # $1 = mounted rootfs
    local root="$1"

    # docker-export artefacts: systemd refuses to run as PID 1 with /.dockerenv present, and the
    # export omits the pseudo-filesystem mount points entirely.
    rm -f "$root/.dockerenv"
    mkdir -p "$root"/{dev,proc,sys,run,tmp,data,boot/efi}

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
    install -D -m 644 os/rauc/certs/cert.pem "$root/etc/rauc/keyring.pem"
}
