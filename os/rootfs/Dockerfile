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
# ---------------------------------------------------------------------------------------------
# Builder: docker-compose and cosign, compiled here rather than downloaded as upstream binaries.
#
# Both projects publish release binaries built on whatever Go toolchain they happened to use, and
# that toolchain's stdlib CVEs become ours — baked into a read-only appliance image that cannot be
# patched in place. In August 2026 that was nine fixable HIGH findings the scan gated on, and no
# pin bump could clear them: cosign v3.1.3 (the newest release) ships built with go1.26.4, the same
# toolchain as v3.1.2, and docker-compose v5.4.0 (the pin then) shipped go1.26.5 — both below the
# go1.26.6 that carries the fixes. Verified by reading the build stamps out of the published
# binaries, not from release notes. Waiting for upstream to rebuild is not a schedule we control,
# so we compile them ourselves on a patched toolchain and the findings go away at the source.
#
# Provenance is not weakened by this, it moves: the old pin was a sha256 of a downloaded binary,
# this one is an exact upstream COMMIT (never a tag — a tag can be re-pointed, the same reason
# RIGFORGE_REF below pins a commit) plus Go module integrity from each project's own go.sum, EXCEPT
# where GO_RAISES below lifts a module — read that block for what a raise actually costs, which is
# wider than the modules it names. The build flags mirror each project's Makefile, so
# `docker-compose version` reports the release it was built from; `cosign version` reports it with a
# `+dirty` suffix, because raising a module edits go.mod and Go stamps that truthfully. It is also
# why the tree state below says dirty: this binary IS built from a modified tree, and a build that
# claimed otherwise would be lying about the provenance this paragraph exists to describe.
FROM golang:1.26.6-trixie@sha256:b75d466dd608587fd66cca705a307ba65b889827d06ad61d6a75f0482b51b7c7 AS gobuild

ARG COMPOSE_VERSION=v5.5.0
ARG COMPOSE_COMMIT=870908cc8f07f5e90acdf5d34dd1b96a4fe51d16
ARG COSIGN_VERSION=v3.1.3
ARG COSIGN_COMMIT=11926fa5bbbbde47e88fc006b625a17769b743b2
# Modules raised above what each project's own go.sum asks for, because upstream has not cut a
# release carrying the fix and the CVE gate is not optional (#1153). Same reasoning as the patched
# toolchain above, one level down: we compile from source, so the module graph is ours, and raising
# the module beats muting the scanner. Per-binary because the findings differ, and EXACT versions
# because `go get` will happily DOWNGRADE a module that is already newer.
#
#   golang.org/x/mod       v0.40.0   CVE-2026-56864 / CVE-2026-56865. Indirect in both: cosign
#                                    v3.1.3 pins v0.37.0; compose v5.4.0 and v5.5.0 both pin
#                                    v0.38.0; cosign's own main is still v0.38.0.
#   google.golang.org/grpc v1.82.1   GHSA-hrxh-6v49-42gf. cosign v3.1.3 pins v1.82.0 — v1.82.1 is
#                                    where cosign's own main has already moved.
#
# WHAT A RAISE ACTUALLY MOVES: `go get X@v Y@v` upgrades the whole closure minimum-version
# selection needs to satisfy X and Y, not just X and Y. Measured on these exact entries: compose
# moves 1 module, cosign moves 9 — x/mod pulls x/tools, which pulls x/net, x/sync and x/sys, and
# x/net pulls x/crypto, x/term and x/text. No formulation avoids that; it is what raising a module
# in a Go build means. So read a line here as "this module and whatever MVS needs to seat it", and
# when you add one, run the command and read Go's own upgrade list rather than assuming it is one.
#
# Every entry here is debt, not a feature: drop it the moment an upstream release makes it a no-op,
# and delete its .trivyignore mute in the SAME change — a mute left over a finding you have just
# fixed means the scan can no longer tell "fixed" from "hidden", which is how two obsolete mutes
# survived in that file until #1153. Verify by re-running the scan against the built binaries with
# NO ignore file, never by reading release notes: the first version of this change fixed x/mod and
# left two other HIGH findings standing.
ARG COMPOSE_GO_RAISES="golang.org/x/mod@v0.40.0 golang.org/x/crypto@v0.55.0 google.golang.org/grpc@v1.83.1"
ARG COSIGN_GO_RAISES="golang.org/x/mod@v0.40.0 google.golang.org/grpc@v1.83.1"
ENV CGO_ENABLED=0

# Blobless clone then detach to the commit: the tag is only a convenience for the version string.
#
# The `describe --exact-match` line is what makes the pin a PAIR rather than two values that happen
# to sit next to each other. `${COMPOSE_VERSION}` is only an ldflag, `${COMPOSE_COMMIT}` is what is
# actually built, so bumping the version alone rebuilds the OLD code and stamps the NEW version on
# it — and every downstream check agrees it worked: the build succeeds, `docker-compose version`
# prints the new number, and scripts/pin-watch.sh reads the VERSION ARG and reports the component
# current for ever. Nothing else in the tree reads `${COMPOSE_COMMIT}` at all. The clone is blobless
# but not shallow, so the tag objects are present and this costs nothing.
RUN git clone --filter=blob:none --no-checkout https://github.com/docker/compose /src/compose \
    && git -C /src/compose checkout --detach "${COMPOSE_COMMIT}" \
    && { [ "$(git -C /src/compose describe --tags --exact-match "${COMPOSE_COMMIT}")" = "${COMPOSE_VERSION}" ] \
        || { echo "COMPOSE_COMMIT ${COMPOSE_COMMIT} is not tag ${COMPOSE_VERSION} — a compose bump is TWO ARGs; resolve the pair with: gh api repos/docker/compose/commits/${COMPOSE_VERSION} --jq .sha" >&2; exit 1; }; } \
    && go -C /src/compose get ${COMPOSE_GO_RAISES} \
    && go build -C /src/compose -trimpath -tags e2e \
        -ldflags "-w -X github.com/docker/compose/v5/internal.Version=${COMPOSE_VERSION}" \
        -o /out/docker-compose ./cmd

RUN git clone --filter=blob:none --no-checkout https://github.com/sigstore/cosign /src/cosign \
    && git -C /src/cosign checkout --detach "${COSIGN_COMMIT}" \
    && { [ "$(git -C /src/cosign describe --tags --exact-match "${COSIGN_COMMIT}")" = "${COSIGN_VERSION}" ] \
        || { echo "COSIGN_COMMIT ${COSIGN_COMMIT} is not tag ${COSIGN_VERSION} — a cosign bump is TWO ARGs; resolve the pair with: gh api repos/sigstore/cosign/commits/${COSIGN_VERSION} --jq .sha" >&2; exit 1; }; } \
    && go -C /src/cosign get ${COSIGN_GO_RAISES} \
    && go build -C /src/cosign -trimpath \
        -ldflags "-buildid= -X sigs.k8s.io/release-utils/version.gitVersion=${COSIGN_VERSION} \
            -X sigs.k8s.io/release-utils/version.gitCommit=${COSIGN_COMMIT} \
            -X sigs.k8s.io/release-utils/version.gitTreeState=dirty" \
        -o /out/cosign ./cmd/cosign

# Fail the build here rather than shipping a binary that cannot run: a wrong build path produces a
# file that exists and does nothing useful, which every later stage would happily copy.
#
# The version has to be ASSERTED, not merely printed. `go build -ldflags "-X pkg.Var=value"` for a
# symbol that no longer exists is silently ignored by the linker — no warning, no non-zero exit — so
# if upstream renames the variable or the module path gains a /v6, the binary builds, reports its
# built-in default (`dev`), and passes a bare `version` call. Measured on a mimic module built with
# these exact flags: renaming the symbol changed the output to `dev` and left the exit code 0. That
# string is a provenance guarantee this file makes further up, so a run that prints it is not the
# same as a run that checks it. Printed first so the build log still shows the real output.
RUN /out/docker-compose version && /out/cosign version \
    && /out/docker-compose version | grep -qF "${COMPOSE_VERSION}" \
    && /out/cosign version | grep -qF "${COSIGN_VERSION}"

# ---------------------------------------------------------------------------------------------
# Pinned by digest (#135) so the debian:trixie-slim tag can't be silently re-pointed. The digest
# bump is how base-distro CVE fixes reach the appliance (#833): there is no apt on the running
# box — every Debian package here is frozen until the next bake.
FROM debian:trixie-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

ENV DEBIAN_FRONTEND=noninteractive

# The OS: init + kernel + bootloader userland for the generic-grub-efi target, the container
# engine, pithead's host dependencies, mDNS (pithead.local), and time sync (before Tor — the
# firstboot ordering rule). openssh-server ships installed but DISABLED: SSH is a wizard opt-in.
# The shell-out set is LOAD-BEARING and debian-slim ships none of it: netavark calls nft to
# program container networking, and pithead-install calls sgdisk (gdisk), partprobe (parted),
# jq, lsblk, mkfs and the grub tools ON THE APPLIANCE — a tool the build host happens to have is
# not a tool the image has. Each absence surfaces at runtime, so the set is audited against the
# built image rather than added one failure at a time. squashfs-tools is in that set too:
# `rauc info` extracts a bundle's manifest with unsquashfs, and without it `pithead os-update`
# cannot read any bundle's compatibility metadata — every guard it carries was dead on the
# appliance (found live on the bench, not by CI, whose stack tests stub rauc).
# Cache-busts ONLY this layer (#929): a warm builder cache reuses the apt index for weeks, and
# when the mirror rotates a package between builds the stale index 404s. build-image.sh's
# --fresh-index flag passes a fresh value here; any other build-arg on a later layer would still
# hit cache as normal — an ARG only invalidates the RUN steps from its declaration onward.
ARG APT_INDEX_STAMP=0
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv systemd-timesyncd systemd-resolved dbus udev \
        linux-image-amd64 initramfs-tools zstd \
        grub-efi-amd64 shim-signed \
        podman podman-docker netavark aardvark-dns catatonit uidmap \
        jq openssl curl ca-certificates xxd iproute2 \
        fdisk gdisk parted e2fsprogs dosfstools \
        nftables iptables systemd-repart \
        avahi-daemon libnss-mdns \
        squashfs-tools \
        openssh-server sudo less nano htpdate
# NB: the apt lists survive THIS layer on purpose — the later `apt-get install` steps below
# (the RigForge toolchain, the updater) run without their own `apt-get update` and resolve
# against these lists. They are deleted after the LAST apt step: nothing at runtime uses apt
# (no apt on the running box), and the rootfs ships as a flat tarball, so a late deletion
# genuinely leaves every slot and update bundle smaller.

# The stack, at the image's exact release state: pithead + schemas + the build/ mount sources
# (config templates and entrypoints that services bind-mount). Build context = repo root.
# The commit this image was built from — the artifact's own answer to "did my change ship?".
COPY os/rootfs/BUILD_COMMIT /opt/pithead/BUILD_COMMIT
COPY pithead pithead-completion.bash VERSION docker-compose.yml \
     config.reference.json config.core-keys.json config.minimal.json /opt/pithead/
# ONLY the build/ subtrees services bind-mount at runtime (config templates and wrapper
# entrypoints). dashboard/Dockerfile isn't among them (moved out of build/, #1106; see
# KNOWN-ISSUES.md) — is_source_checkout() keys off its presence here, so shipping one by accident
# would make the appliance think it's a dev checkout, tag :dev, never pull, and SKIP cosign.
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
# Built in the gobuild stage above, on a Go toolchain we choose, rather than downloaded. See the
# rationale there — upstream release binaries carry their builder's stdlib CVEs into an image that
# cannot be patched in place.
COPY --from=gobuild /out/docker-compose /out/cosign /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-compose /usr/local/bin/cosign \
    && touch /etc/containers/nodocker

# The built-in miner (#796): a pinned RigForge tree plus everything it needs, baked at image
# build because nothing can be installed later — apt cannot run on the read-only root, and even
# a rw-remount install leaves its /etc state (alternatives, ld.so.cache) on the volatile overlay
# where the first reboot breaks the compiler. RIGFORGE_REF pins rigforge's v1.16.0 release
# (by commit, not tag name, so a moved tag cannot change the bake); bump it release by release.
# v1.16.0 is the floor for the HugePages pool ceiling: hugepages_pool_ceiling_mb (rigforge#398,
# filed from #1103) is absent from v1.15.1's tree entirely, and declaring it into one fails OPEN —
# parse_config never reads the key, so the rendered config would look capped and behave as today.
# When bumping: re-check that the span's control /status vocabulary is still covered by the closed
# allowlists both poll loops in the root pithead script match on (rigforge#344 added pending and
# age_seconds). A status neither arm names must stay non-terminal — it must never read as applied.
# pithead-sync copies the tree to /data/rigforge every boot; `pithead local-miner` runs
# its setup with RIGFORGE_APPLIANCE=1 when local_miner.enabled.
#
# The toolchain is RigForge's Debian dependency list, with one naming fix: trixie ships the
# cpupower CLI as linux-cpupower (linux-tools-common is Ubuntu's name and does not exist here).
# msr-tools gives doctor its rdmsr probe; gettext-base is envsubst, which renders the unit on
# every boot and is the ONLY tool a prebuilt tree strictly needs.
RUN apt-get install -y --no-install-recommends \
        git build-essential cmake libuv1-dev libssl-dev libhwloc-dev gettext-base python3 \
        linux-cpupower msr-tools
ARG RIGFORGE_REF=4ce29b3daf063fd1b45e050649e93aa9592618e1
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
# The sed anchors match rigforge.sh's exact NAME="${NAME:-value}" quoting; a cosmetic upstream
# reformat extracts nothing, so the guard names the cause instead of failing mute mid-chain.
RUN set -e \
    && XMRIG_VERSION=$(sed -n 's/^XMRIG_VERSION="${XMRIG_VERSION:-\(.*\)}"$/\1/p' /opt/rigforge/rigforge.sh) \
    && XMRIG_COMMIT=$(sed -n 's/^XMRIG_COMMIT="${XMRIG_COMMIT:-\(.*\)}"$/\1/p' /opt/rigforge/rigforge.sh) \
    && { test -n "$XMRIG_VERSION" && test -n "$XMRIG_COMMIT" || { \
            echo "could not extract the XMRig pin from rigforge.sh — its XMRIG_VERSION/XMRIG_COMMIT quoting no longer matches the sed anchors above; update them to the new format" >&2; \
            exit 1; }; } \
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
    && printf '[Journal]\nStorage=persistent\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/pithead.conf \
    && mkdir -p /var/log/journal # bind-mount target for pithead-journal-persist.service (#1030)

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
# Physical-presence configuration channel (#786 sub-issue D): pithead-boot's one stage before
# render. No unit of its own — it runs inline, inside the boot unit above.
COPY os/overlay/pithead-media-config /usr/local/sbin/pithead-media-config
# Hugepages sizing (#977): the sysctl.d reservation above is sized for the supported 16 GB
# machine; this unit corrects it every boot on smaller RAM — loudly — before either boot owner
# starts a container. Its own unit, not a pithead-boot stage, because the reservation lands on
# EVERY boot including the unprovisioned first one, where pithead-boot never runs.
COPY os/overlay/pithead-hugepages.service /etc/systemd/system/pithead-hugepages.service
COPY os/overlay/pithead-hugepages /usr/local/sbin/pithead-hugepages
# The two-tier reset's deep tier and the wedged-/data recovery path: reformats /data before it
# mounts, on a `pithead factory-reset` request (ESP marker) or a genuinely unmountable partition.
# Ordered before data.mount by its unit; fail-safe — a healthy, unmarked partition is never touched.
COPY os/overlay/pithead-data-reset.service /etc/systemd/system/pithead-data-reset.service
COPY os/overlay/pithead-data-reset /usr/local/sbin/pithead-data-reset
# CPU governor: hold cores at performance every boot; a no-op with no cpufreq (co-location note on the unit).
COPY os/overlay/pithead-cpu-governor.service /etc/systemd/system/pithead-cpu-governor.service
# Host identity (#894/#895): neither SSH host keys nor machine-id may ship CONCRETE — both were
# baked by their packages' own postinst (openssh-server, systemd, dbus), extractable from a
# published release and identical across every machine flashed from one. dbus's copy counts
# fully too: its first-boot logic PREFERS /var/lib/dbus/machine-id when present, resurrecting
# the shared identity even with /etc emptied (the KVM reset leg caught exactly that — every
# "fresh" boot minting the same id). The symlink below fixes dbus; the boot-time mechanism that
# generates (once) and persists both on /data, the single persistence root, fixes the rest.
COPY os/overlay/pithead-ssh-host-keys.conf /etc/systemd/system/ssh.service.d/pithead-host-keys.conf
COPY os/overlay/pithead-ssh-host-keys /usr/local/sbin/pithead-ssh-host-keys
COPY os/overlay/pithead-machine-id.service /etc/systemd/system/pithead-machine-id.service
COPY os/overlay/pithead-machine-id /usr/local/sbin/pithead-machine-id
COPY os/overlay/pithead-journal-persist.service /etc/systemd/system/pithead-journal-persist.service
COPY os/overlay/pithead-journal-persist /usr/local/sbin/pithead-journal-persist
RUN mkdir -p /etc/ssh/sshd_config.d \
    && printf 'HostKey /data/ssh/ssh_host_ed25519_key\n' > /etc/ssh/sshd_config.d/pithead-host-keys.conf \
    && rm -f /etc/ssh/ssh_host_* \
    && : > /etc/machine-id \
    && ln -sf /etc/machine-id /var/lib/dbus/machine-id
# An empty machine-id makes systemd treat EVERY boot as a first boot (the volatile /etc upper
# resets it each power cycle), and on first boot PID 1 applies preset-all in enable-only mode.
# Debian ships no preset files, and systemd's no-preset fallback is "enable" — which would
# quietly re-enable every installable unit, ssh.service included, on a RELEASE image. The
# blanket disable-* preset turns that pass into a no-op; the enable symlinks written at build
# below live in the image's /etc and presets never touch existing state. systemd-firstboot
# would likewise re-run per boot and can prompt on the console for anything it finds unset —
# masked: this image bakes its own locale/timezone, and the console password is pithead's.
RUN mkdir -p /etc/systemd/system-preset \
    && printf 'disable *\n' > /etc/systemd/system-preset/00-pithead.preset \
    && systemctl mask systemd-firstboot.service
RUN chmod +x /usr/local/sbin/pithead-sync /usr/local/sbin/pithead-boot /usr/local/sbin/pithead-media-config /usr/local/sbin/pithead-hugepages /usr/local/sbin/pithead-data-reset /usr/local/sbin/pithead-ssh-host-keys /usr/local/sbin/pithead-machine-id /usr/local/sbin/pithead-journal-persist /usr/lib/systemd/system-generators/pithead-mount-generator
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
# The last apt step is above — from here the lists are dead weight in every slot and bundle.
RUN rm -rf /var/lib/apt/lists/*
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
        pithead-data-reset.service pithead-machine-id.service pithead-hugepages.service \
        pithead-journal-persist.service \
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
