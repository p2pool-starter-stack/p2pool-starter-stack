# pithead-os rootfs (#77 phase 2) — the appliance operating system as a container build,
# exported to a tarball by os/build-image.sh (the Umbrel pattern) and turned into a bootable
# image or an update bundle by os/rauc/mkimage.sh / os/rauc/mkbundle.sh.
# Debian 13 + systemd + rootful Podman; pithead is the provisioning brain, Quadlet the runtime.
# Deliberately updater-agnostic: the updater sits on top and is selected by PITHEAD_UPDATER
# below, so swapping it does not touch this file (docs/dev/dual-distribution-plan.md
# § appliance architecture).
#
# This file is named Dockerfile, not Containerfile, so Dependabot's docker ecosystem tracks the
# base digest below (it only reads Dockerfile-named files — dependabot-core#6067); nothing else
# cares about the name, build-image.sh passes the path with -f.
# Pinned by digest (#135) so the debian:trixie-slim tag can't be silently re-pointed. The digest
# bump is how base-distro CVE fixes reach the appliance (#833): there is no apt on the running
# box — every Debian package here is frozen until the next bake.
FROM debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

ENV DEBIAN_FRONTEND=noninteractive

# The OS: init + kernel + bootloader userland for the generic-grub-efi target, the container
# engine, pithead's host dependencies, mDNS (pithead.local), and time sync (before Tor — the
# firstboot ordering rule). openssh-server ships installed but DISABLED: SSH is a wizard opt-in.
# The shell-out set is LOAD-BEARING and debian-slim ships none of it: netavark calls nft to
# program container networking, and pithead-install calls sgdisk (gdisk), partprobe (parted),
# jq, lsblk, mkfs and the grub tools ON THE APPLIANCE — a tool the build host happens to have is
# not a tool the image has. Each absence surfaces at runtime, so the set is audited against the
# built image rather than added one failure at a time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv systemd-timesyncd systemd-resolved dbus udev \
        linux-image-amd64 initramfs-tools zstd \
        grub-efi-amd64 shim-signed \
        podman podman-docker netavark aardvark-dns catatonit uidmap \
        jq openssl curl ca-certificates xxd iproute2 \
        fdisk gdisk parted e2fsprogs dosfstools \
        nftables iptables systemd-repart \
        avahi-daemon libnss-mdns \
        openssh-server sudo less nano htpdate
# NB: apt lists are kept on purpose — the Rugix core recipes run `apt-get install` in the build
# chroot (fdisk/parted etc.) and need resolvable metadata; deleting them fails the bake.

# The stack, at the image's exact release state: pithead + schemas + the build/ mount sources
# (config templates and entrypoints that services bind-mount). Build context = repo root.
# The commit this image was built from — the artifact's own answer to "did my change ship?".
COPY os/rootfs/BUILD_COMMIT /opt/pithead/BUILD_COMMIT
COPY pithead pithead-completion.bash VERSION docker-compose.yml \
     config.reference.json config.core-keys.json config.minimal.json /opt/pithead/
# ONLY the build/ subtrees services bind-mount at runtime (config templates and wrapper
# entrypoints). Copying the whole tree ships build/dashboard/Dockerfile, which is exactly what
# is_source_checkout() looks for — the appliance would then think it is a dev checkout, tag its
# images :dev, set the pull policy to never, and SKIP cosign verification of the release images.
COPY build/monero/ /opt/pithead/build/monero/
COPY build/tari/ /opt/pithead/build/tari/
COPY build/tari-wallet/ /opt/pithead/build/tari-wallet/
RUN rm -f /opt/pithead/build/*/Dockerfile
RUN chmod +x /opt/pithead/pithead

# The engine bridge, and the reason the appliance can provision at all: pithead drives the stack
# with `docker compose`, podman-docker maps `docker` onto podman, and podman's compose command
# delegates to the FIRST provider it finds — this pinned docker-compose v2 binary, which then
# speaks the compat API on podman.socket. The appliance therefore runs the exact same compose
# lifecycle as the DIY channel: one config, one validator, one set of commands. Quadlet remains
# the tracked migration (docs/dev/dual-distribution-plan.md), not a second parallel path.
# /etc/containers/nodocker silences the shim's stderr banner, which would otherwise leak into
# every parsed command output.
ARG COMPOSE_VERSION=v5.3.1
ARG COMPOSE_SHA256=f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959
ARG COSIGN_VERSION=v3.1.2
ARG COSIGN_SHA256=f7622ed3cf22e55e1ae6377c080979ff77a22da9981c11df222a2e444991e7cf
RUN curl -fsSL -o /usr/local/bin/docker-compose \
        "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
    && echo "${COMPOSE_SHA256}  /usr/local/bin/docker-compose" | sha256sum -c - \
    && curl -fsSL -o /usr/local/bin/cosign \
        "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
    && echo "${COSIGN_SHA256}  /usr/local/bin/cosign" | sha256sum -c - \
    && chmod +x /usr/local/bin/docker-compose /usr/local/bin/cosign \
    && touch /etc/containers/nodocker

# The built-in miner (#796): a pinned RigForge tree plus everything it needs, baked at image
# build because nothing can be installed later — apt cannot run on the read-only root, and even
# a rw-remount install leaves its /etc state (alternatives, ld.so.cache) on the volatile overlay
# where the first reboot breaks the compiler. RIGFORGE_REF pins a commit on rigforge's develop
# (the first ref with appliance mode); move it to the next tagged rigforge release when one
# ships. pithead-sync copies the tree to /data/rigforge every boot; `pithead local-miner` runs
# its setup with RIGFORGE_APPLIANCE=1 when local_miner.enabled.
#
# The toolchain is RigForge's Debian dependency list, with one naming fix: trixie ships the
# cpupower CLI as linux-cpupower (linux-tools-common is Ubuntu's name and does not exist here).
# msr-tools gives doctor its rdmsr probe; gettext-base is envsubst, which renders the unit on
# every boot and is the ONLY tool a prebuilt tree strictly needs.
RUN apt-get install -y --no-install-recommends \
        git build-essential cmake libuv1-dev libssl-dev libhwloc-dev gettext-base python3 \
        linux-cpupower msr-tools
ARG RIGFORGE_REF=32be3a433b261110dde371f0ed5dab88acafd6f4
RUN curl -fsSL -o /tmp/rigforge.tar.gz \
        "https://github.com/p2pool-starter-stack/rigforge/archive/${RIGFORGE_REF}.tar.gz" \
    && mkdir -p /opt/rigforge \
    && tar -xzf /tmp/rigforge.tar.gz -C /opt/rigforge --strip-components=1 \
    && rm /tmp/rigforge.tar.gz \
    && chmod +x /opt/rigforge/rigforge.sh \
    && printf 'ref=%s version=%s\n' "$RIGFORGE_REF" "$(tr -d ' \t\r\n' </opt/rigforge/VERSION)" \
        >/opt/rigforge/RIGFORGE_REF
# Prebuild XMRig at RigForge's own pin, read from the baked tree so the two cannot drift. The
# appliance may be Tor-only, and RigForge's build step clones github over clearnet — so the
# clone happens HERE, on the build host, and pithead-sync seeds the result into the workspace
# where RigForge's "already built" check accepts it (binary + commit marker + sha record, the
# exact format rigforge.sh writes). The donate-level source patch is skipped on purpose: the
# default (1%) equals XMRig's own default, and the runtime config carries the value regardless.
RUN set -e \
    && XMRIG_VERSION=$(sed -n 's/^XMRIG_VERSION="${XMRIG_VERSION:-\(.*\)}"$/\1/p' /opt/rigforge/rigforge.sh) \
    && XMRIG_COMMIT=$(sed -n 's/^XMRIG_COMMIT="${XMRIG_COMMIT:-\(.*\)}"$/\1/p' /opt/rigforge/rigforge.sh) \
    && test -n "$XMRIG_VERSION" && test -n "$XMRIG_COMMIT" \
    && git clone --quiet --branch "$XMRIG_VERSION" --depth 1 https://github.com/xmrig/xmrig.git /tmp/xmrig \
    && test "$(git -C /tmp/xmrig rev-parse HEAD)" = "$XMRIG_COMMIT" \
    && cmake -S /tmp/xmrig -B /tmp/xmrig/build -DWITH_HWLOC=ON >/dev/null \
    && make -C /tmp/xmrig/build -j"$(nproc)" >/dev/null \
    && mkdir -p /opt/rigforge/prebuilt/xmrig/build \
    && install -m 755 /tmp/xmrig/build/xmrig /opt/rigforge/prebuilt/xmrig/build/xmrig \
    && printf '%s\n' "$XMRIG_COMMIT" >/opt/rigforge/prebuilt/xmrig/.rigforge-commit \
    && sha256sum /opt/rigforge/prebuilt/xmrig/build/xmrig | awk '{print $1}' \
        >/opt/rigforge/prebuilt/xmrig/.rigforge-sha256 \
    && rm -rf /tmp/xmrig

# Appliance identity: the engine pin doctor and the wizard read, hugepages (load-bearing for the
# memory caps — the RandomX dataset must land in hugetlbfs, not the cgroup), persistent journald
# (a headless box that loses its logs on reboot is undebuggable).
RUN printf 'PITHEAD_ENGINE=podman\n' >> /etc/environment \
    && printf 'vm.nr_hugepages=3072\n' > /etc/sysctl.d/99-pithead-hugepages.conf \
    && mkdir -p /etc/systemd/journald.conf.d \
    && printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/pithead.conf

# Hardware/systemd watchdog: catch a soft-hung kernel or wedged init on an unattended headless
# box — the case panic=60 (grub.cfg) and container restart policies cannot see, because nothing
# panicked and PID 1 is the thing that stopped pinging. systemd feeds /dev/watchdog every
# RuntimeWatchdogSec/2; miss the full interval and the platform watchdog hard-resets the machine.
# 20s is the balance point: long enough that a RandomX-loaded box under a GC or IO stall is not
# falsely reset, short enough that a real hang self-heals in well under a minute. RebootWatchdogSec
# arms the watchdog across a shutdown too, so a reboot that itself wedges still resets rather than
# hanging forever. No /dev/watchdog (a KVM guest or bench box with no virtual watchdog device) is a
# safe no-op — systemd logs the missing device and carries on; real appliance hardware exposes one
# (iTCO_wdt and friends auto-probe), which is where this earns its keep.
RUN mkdir -p /etc/systemd/system.conf.d \
    && printf '[Manager]\nRuntimeWatchdogSec=20s\nRebootWatchdogSec=2min\n' > /etc/systemd/system.conf.d/pithead-watchdog.conf

# Container storage lives on the DATA partition, never on the root overlay. Two reasons, both
# load-bearing: podman's overlay driver cannot stack on the appliance's overlayfs root ("'overlay' is not
# supported over overlayfs"), and images/containers must survive A/B updates and reboots — the
# root overlay is discarded. This is the plan's "/var/lib/containers on the labeled data
# partition" rule; the mount guard lives on the units that use it.
RUN mkdir -p /etc/containers && printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/data/containers/storage"\n' \
        > /etc/containers/storage.conf
# Docker's short-name semantics, explicitly: the stack was written against docker, where a bare
# image name implies docker.io. Podman's native path refuses short names without this — the
# compat API (compose) resolves them, `docker run` via the shim does not, and that split cost a
# provisioning run. Every first-party image is digest-pinned regardless; this only restores the
# implied registry for the few upstream refs.
RUN printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf.d/pithead-docker-compat.conf

# The wizard's image, staged by os/build-image.sh — loaded into podman storage on first boot
# (pithead firstboot-wizard), so the setup page comes up with no registry reachable.
COPY os/rootfs/images/ /opt/pithead/images/

# Networking: DHCP on any wired interface. The appliance ships no interactive network config —
# the operator plugs in ethernet and browses to the box, so an unconfigured NIC means an
# unreachable wizard and a bricked-looking appliance.
RUN printf '[Match]\nName=en*\nName=eth*\n\n[Network]\nDHCP=yes\nMulticastDNS=yes\n\n[DHCPv4]\nUseDomains=yes\n' \
        > /etc/systemd/network/10-wired.network

# First boot: time sync, then the wizard (only while unprovisioned). The unit's console output
# carries the URL + one-time token per the phase-3 design.
COPY os/overlay/pithead-firstboot.service /etc/systemd/system/pithead-firstboot.service
COPY os/overlay/pithead-sync.service /etc/systemd/system/pithead-sync.service
COPY os/overlay/pithead-sync /usr/local/sbin/pithead-sync
# State mounts are derived from the boot disk at every boot, never from labels — every pithead
# disk carries the same labels, and two present at once made LABEL= mount the wrong /data.
COPY os/overlay/pithead-mount-generator /usr/lib/systemd/system-generators/pithead-mount-generator
COPY os/overlay/pithead-boot.service /etc/systemd/system/pithead-boot.service
COPY os/overlay/pithead-boot /usr/local/sbin/pithead-boot
# The two-tier reset's deep tier and the wedged-/data recovery path: reformats /data before it
# mounts, either on a `pithead factory-reset` request (ESP marker) or when the partition is
# genuinely unmountable. Ordered before data.mount by its unit — the wipe cannot run once /data is
# in use — and fail-safe: a healthy, unmarked partition is never touched.
COPY os/overlay/pithead-data-reset.service /etc/systemd/system/pithead-data-reset.service
COPY os/overlay/pithead-data-reset /usr/local/sbin/pithead-data-reset
# CPU governor: hold the cores at performance every boot (mining appliance tuning). Oneshot, and
# a no-op on a box with no cpufreq — see the unit for the RigForge co-location note.
COPY os/overlay/pithead-cpu-governor.service /etc/systemd/system/pithead-cpu-governor.service
RUN chmod +x /usr/local/sbin/pithead-sync /usr/local/sbin/pithead-boot /usr/local/sbin/pithead-data-reset /usr/lib/systemd/system-generators/pithead-mount-generator
# The updater is chosen per image. RAUC is a Debian package, so it is installed here when
# selected; leaving PITHEAD_UPDATER empty builds the same rootfs with no updater at all.
ARG PITHEAD_UPDATER=""
# NB: `rauc` is the CLI ONLY. Debian splits the D-Bus daemon into `rauc-service`, which is not even
# a Recommends of `rauc` — so --no-install-recommends is not what drops it, the package simply has
# to be named. Install just `rauc` and you get a binary that cannot install anything, failing with
# "de.pengutronix.rauc was not provided by any .service files" rather than anything that names a
# missing daemon. Both packages are required.
RUN if [ "$PITHEAD_UPDATER" = "rauc" ]; then \
        apt-get install -y --no-install-recommends rauc rauc-service; \
    fi
# The disk installer and the boot config it writes to a target. No image payload ships with it —
# it copies the running slot, so the artifact does not carry a compressed copy of itself.
COPY os/installer/pithead-install /usr/local/sbin/pithead-install
COPY os/rauc/grub.cfg /usr/share/pithead/grub.cfg
RUN chmod +x /usr/local/sbin/pithead-install

# The appliance partition layout. systemd-repart creates slot B and /data on the target machine's
# real disk at first boot, so the shipped image carries only the ESP and slot A.
COPY os/rootfs/repart.d/ /usr/lib/repart.d/
# pithead-boot, NOT podman-restart, recovers the stack after a power cycle (#792): the stack is
# compose-managed, and podman-restart started the containers into its own oneshot cgroup — then
# systemd stopped the unit and SIGKILLed the conmon processes it had just spawned. The boot unit
# also re-renders derived config (#790) and health-gates the A/B slot commit (#793).
# mDNS over IPv4 only: advertising AAAA records made clients that cannot route to the box's
# IPv6 (a Wi-Fi laptop on a different segment than the box's ethernet) try v6 first and stall
# on ERR_ADDRESS_UNREACHABLE before falling back — pithead.local "took forever" on a healthy
# LAN. The console prints the v4 address; the name should resolve to the same thing.
RUN sed -i 's/^#\?use-ipv6=.*/use-ipv6=no/' /etc/avahi/avahi-daemon.conf
RUN systemctl enable podman.socket pithead-boot.service pithead-cpu-governor.service avahi-daemon \
        systemd-timesyncd systemd-resolved \
        systemd-networkd systemd-networkd-wait-online pithead-sync.service pithead-firstboot.service \
        pithead-data-reset.service \
    && systemctl disable ssh
# systemd-repart.service is static — it is pulled in by sysinit.target, and `systemctl enable` on a
# static unit is an error that would fail the build. Assert it is present instead.
RUN test -f /usr/lib/systemd/system/systemd-repart.service

# TEST-ONLY hooks (tests/os/run.sh --phase update): both default EMPTY and change nothing in a
# release build. A pubkey enables root-key SSH so the harness can drive `rauc` in the guest;
# the marker distinguishes v1/v2 slots across the A/B cycle.
#
# The SSH bake is also what DEFINES the build variant, so it is stamped here (#819): a baked key
# means a debug image, no key means the shell-less release. /etc/pithead-variant travels with the
# rootfs into the image, every installed slot and the update bundle's [meta.pithead] section —
# `pithead os-update` compares the running stamp against the bundle's, because a debug box that
# silently takes a release bundle loses the SSH channel performing the install.
ARG PITHEAD_TEST_SSH_PUBKEY=""
ARG PITHEAD_TEST_MARKER=""
RUN if [ -n "$PITHEAD_TEST_SSH_PUBKEY" ]; then \
        mkdir -p /root/.ssh && chmod 700 /root/.ssh \
        && printf '%s\n' "$PITHEAD_TEST_SSH_PUBKEY" > /root/.ssh/authorized_keys \
        && chmod 600 /root/.ssh/authorized_keys \
        && systemctl enable ssh \
        && printf 'debug\n' > /etc/pithead-variant; \
    else \
        printf 'release\n' > /etc/pithead-variant; \
    fi \
    && if [ -n "$PITHEAD_TEST_MARKER" ]; then \
        printf '%s\n' "$PITHEAD_TEST_MARKER" > /etc/pithead-test-marker; \
    fi
