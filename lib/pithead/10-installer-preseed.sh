# --- disk installer (appliance only) -------------------------------------------------------
# The appliance can boot from the installation medium itself. When it does, the wizard leads with
# a disk picker instead of the setup form: the operator installs first, reboots, and configures
# the installed machine. Config is never transplanted between machines.

# Overridable so the shell suite can point it at a fake — the real one partitions disks.
install_bin() { printf '%s' "${PITHEAD_INSTALL_BIN:-/usr/local/sbin/pithead-install}"; }

# --- pre-seeding from the installation medium ----------------------------------------------
# The ESP is FAT, so an operator can drop files on the stick from any laptop right after
# flashing — before the machine has ever booted. Two are honoured:
#
#   pithead-config.json   a complete configuration: first boot provisions with no browser
#   pithead-token.txt     a chosen one-time token, so a box with no display can be reached
#
# This is what makes a headless or fleet install possible at all: without it the token exists
# only on the console, so every machine needs a monitor walked to it once.
PRESEED_DIR="${PITHEAD_PRESEED_DIR:-/boot/efi}"

# A pre-seeded token, sanitised. Anything outside the token alphabet is dropped rather than
# interpreted — this string is operator input arriving from a filesystem anyone can write.
preseed_token() {
    local f="$PRESEED_DIR/pithead-token.txt" t
    [ -f "$f" ] || return 1
    t=$(tr -dc 'A-Za-z0-9-' <"$f" 2>/dev/null | head -c 32)
    [ "${#t}" -ge 4 ] || return 1
    printf '%s' "$t"
}

# The note pithead-data-reset leaves on the ESP when it reinitializes /data (#1062, #1121): an
# append-only log, one "<UTC timestamp> <reason>" line per wipe. Reads only the LAST line — the
# most recent event is the one an operator needs — and prints one JSON object on success:
# {when, reason, recovery}. "recovery" is false for a deliberate factory-reset (nothing to warn
# about, the operator asked for it) and true for the wedged-/data case, where the next move is
# restoring a backup rather than walking through setup as if this were a fresh machine. rc 1:
# absent, unreadable, or a line with no "<when> <reason>" shape to parse.
data_wipe_note() {
    local f="$PRESEED_DIR/pithead-data-wiped" line when reason
    [ -f "$f" ] || return 1
    line=$(tail -n 1 "$f" 2>/dev/null) || return 1
    case "$line" in *' '*) ;; *) return 1 ;; esac
    when="${line%% *}"
    reason="${line#* }"
    [ -n "$when" ] && [ -n "$reason" ] || return 1
    jq -cn --arg when "$when" --arg reason "$reason" \
        '{when: $when, reason: $reason, recovery: ($reason != "factory-reset requested")}'
}

# Carries the wipe note to the wizard's spool (#1121): the wizard runs in a container whose only
# mount is the spool (`-v "$spool":/wizard-spool`), so it cannot reach $PRESEED_DIR itself —
# unlike doctor, which runs on the host. Same shape as publish_rig_defaults: derive fresh, write
# atomically, always write SOMETHING (an empty object when there is no note) so a fleet stick's
# spool never hands machine 2 machine 1's note. Skipped on removable boot media, where
# PRESEED_DIR is the STICK's own ESP and would describe the stick, not this machine.
publish_data_wipe_note() { # <spool-dir>
    local tmp="$1/.data-wiped.json.$$" note
    if boot_is_removable; then
        note="{}"
    else
        note=$(data_wipe_note) || note="{}"
    fi
    printf '%s' "$note" >"$tmp" 2>/dev/null || : >"$tmp"
    chown 1000:1000 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$1/data-wiped.json"
}

# The restore pre-seed (#909): an installer boot that accepted a backup archive stages it —
# still encrypted, passphrase beside it — on the target's ESP, and the installed machine's
# first boot lands here to restore ITSELF: config, Tor onion keys, dashboard database, the
# whole identity the docs promise survives. Spent on use, accepted or not — the passphrase
# beside the archive makes the pair plaintext-equivalent and it must not outlive this boot.
# rc: 0 restored, 1 present but rejected, 2 none.
consume_preseed_restore() {
    local a="$PRESEED_DIR/pithead-restore.enc" pf="$PRESEED_DIR/pithead-restore-pass" pass errf
    [ -f "$a" ] || return 2
    { set +x; } 2>/dev/null # xtrace would print the passphrase below
    pass=$(cat "$pf" 2>/dev/null || true)
    errf=$(mktemp)
    if restore_apply "$a" "$pass" "$errf"; then
        pass=""
        log "Restored this machine from the carried backup archive."
        mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
        rm -f "$a" "$pf" 2>/dev/null ||
            warn "Could not remove the consumed restore archive from $PRESEED_DIR — it sits beside its passphrase; delete both."
        rm -f "$errf"
        return 0
    fi
    pass=""
    warn "The carried restore archive was rejected — falling back to the setup page."
    warn "  $(tail -c 200 "$errf" 2>/dev/null | tr -d '[:cntrl:]')"
    rm -f "$errf"
    mount -o remount,rw "$PRESEED_DIR" 2>/dev/null || true
    rm -f "$a" "$pf" 2>/dev/null || true
    return 1
}

# rc: 0 a valid pre-seeded config was installed, 1 one was present but rejected, 2 none.
# Validated through a COPY: parse_and_validate_config fills in generated fields as it goes, and
# writing those back would mutate the operator's stick — and on a fleet, every machine would
# inherit the first one's generated credentials.
consume_preseed_config() { # <dest-config-path>
    local f="$PRESEED_DIR/pithead-config.json" dest="$1" tmp err
    [ -f "$f" ] || return 2
    tmp=$(mktemp) || return 1
    cp "$f" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if err=$(PITHEAD_CONFIG_FILE="$tmp" bash -c "source '${BASH_SOURCE[0]}' && parse_and_validate_config" 2>&1); then
        mv "$tmp" "$dest"
        log "Using the pre-seeded configuration from $f."
        return 0
    fi
    rm -f "$tmp"
    warn "The pre-seeded $f was rejected — falling back to the setup page."
    warn "  $(printf '%s' "$err" | tail -n 1 | tr -d '[:cntrl:]' | tail -c 200)"
    return 1
}

# Is this host a Pithead OS appliance? Decides which UPGRADE path is legal: the appliance's
# program tree is delivered by OS images and resynced from the system slot at every boot, so a
# DIY tarball upgrade would "succeed" and then silently revert at the next reboot. Probes two
# files only the appliance image bakes; PITHEAD_APPLIANCE=0/1 overrides for tests.
is_appliance() {
    case "${PITHEAD_APPLIANCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
    esac
    [ -f /etc/rauc/system.conf ] && [ -x /usr/local/sbin/pithead-install ]
}

# Did this system boot from removable media (a USB stick)?
boot_is_removable() {
    local root_src boot_dev
    root_src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
    boot_dev=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    [ -n "$boot_dev" ] || return 1
    [ "$(cat "/sys/block/$boot_dev/removable" 2>/dev/null)" = "1" ]
}

# Booted from removable media AND some other disk is available to install onto. Both halves
# matter: a box running from its internal disk must never offer to reinstall itself, and an
# installer with nowhere to install is just a broken setup page.
installer_mode_available() {
    [ -x "$(install_bin)" ] || return 1
    boot_is_removable || return 1
    # The gate runs ~18s into boot and RACES udev's settling of a multi-partition internal
    # disk: an empty first probe put a reinstall boot into SETUP mode while the same --list
    # answered fine seconds later over SSH (KVM keep leg, deterministic after an unrelated
    # boot-timing shift). Settle, then give the inventory a few honest tries — a stick with
    # genuinely no target pays ~10 extra seconds once, against a wizard that otherwise opens
    # in the wrong mode with no way back short of a power cycle.
    udevadm settle --timeout=10 2>/dev/null || true
    local tries=0
    while [ "$tries" -lt 5 ]; do
        [ -n "$("$(install_bin)" --list 2>/dev/null)" ] && return 0
        sleep 2
        tries=$((tries + 1))
    done
    return 1
}

# The HOST enumerates disks; the container only renders what it is given. A browser must never be
# able to name a target the host did not offer — that is the same boundary the #33 control
# channel draws, and here the action erases a disk.
publish_disk_inventory() { # <spool-dir>
    # Atomic: the wizard reads this file between our writes, and a truncate-then-write would
    # hand it an empty inventory mid-write — rendering a disk picker with no disks.
    local tmp="$1/.disks.tsv.$$"
    "$(install_bin)" --list >"$tmp" 2>/dev/null || : >"$tmp"
    chown 1000:1000 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$1/disks.tsv"
}

# The strip a previous install's config passes through before any of it may be SHOWN (#794):
# every leaf CONTROL_SECRET_PATHS names, plus the whole objects whose value IS access — the
# dashboard login, the worker inventory (its per-entry tokens live in a variable-length array
# the fixed paths cannot reach), alert credentials, the ssh key. Wallet addresses, node modes
# and hosts, the pool tier stay: those are the answers the operator came back for, and none of
# them is a secret. Errs toward stripping more — a lost convenience beats a leaked credential.
# rc non-zero when the file is not a usable config object; callers treat that as "no pre-fill".
strip_config_secrets() { # <config-file> -> stripped JSON on stdout
    jq -e --argjson paths "$CONTROL_SECRET_PATHS" '
        delpaths($paths)
        | del(.dashboard.auth, .dashboard.workers, .workers, .telegram,
              .healthchecks, .notifications, .ssh, .tari.spend_public_key)' "$1" 2>/dev/null
}

# Reinstall pre-fill (#794). When the offered targets include exactly one disk that already
# carries an install, mount its data partition READ-ONLY, read the previous config, strip the
# secrets and publish the remainder as the page's starting point — the same last-attempt.json
# channel the pre-seed path fills. The operator sees the answers the machine already knew and
# changes what they came to change; a bench box once had its remote-Tari setting silently
# defaulted back to a local chain by this gap. Host-side only (the container never mounts
# anything) and pure convenience: every failure path returns 1 and the page simply opens
# blank — nothing here may block an install. rc 0 = a pre-fill was published.
prefill_from_previous_install() { # <spool-dir>
    local spool="$1" disk part mnt cfg tmp rc=1
    disk=$(awk -F'\t' '$5 == "pithead-with-data" {print $1}' "$spool/disks.tsv" 2>/dev/null)
    # Two candidates would make the pre-fill a guess about WHICH machine's answers; offer none.
    [ -n "$disk" ] && [ "$(printf '%s\n' "$disk" | wc -l)" -eq 1 ] || return 1
    part=$(lsblk -lnpo NAME,PARTLABEL "/dev/$disk" 2>/dev/null | awk '$2 == "data" {print $1; exit}')
    [ -n "$part" ] || return 1
    mnt=$(mktemp -d) || return 1
    # -t ext4 pinned: the appliance only ever formats data partitions as ext4, and an
    # auto-probed type would let an arbitrary disk pick which filesystem parser the kernel
    # runs against its content.
    if mount -t ext4 -o ro,nosuid,nodev,noexec "$part" "$mnt" 2>/dev/null; then
        cfg="$mnt/pithead/config.json"
        tmp="$spool/.last-attempt.json.$$"
        # The -L guards close a symlink escape: a crafted disk could point pithead/ or
        # config.json at a file on the RUNNING host, and jq follows symlinks — the read-only
        # mount keeps both components stable under the checks. The size cap bounds what an
        # arbitrary disk can make this boot path chew on; jq's parse (and the object shape
        # it needs) rejects everything else.
        if [ ! -L "$mnt/pithead" ] && [ ! -L "$cfg" ] &&
            [ -f "$cfg" ] && [ "$(wc -c <"$cfg" 2>/dev/null || echo 0)" -le 1048576 ] &&
            [ -s "$cfg" ] && strip_config_secrets "$cfg" >"$tmp"; then
            chown 1000:1000 "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$spool/last-attempt.json" && rc=0
        fi
        rm -f "$tmp"
        umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
    fi
    rmdir "$mnt" 2>/dev/null || true
    return "$rc"
}

# Dial every remote node the candidate names, BEFORE the wizard closes and provisioning churns.
# A wrong host or a firewalled port otherwise surfaces minutes later as a failed setup — a bench
# session read exactly that as a crash. TCP connect only (bash /dev/tcp): proves reachability,
# not protocol health, which the stack's own healthchecks own. rc 0 = all reachable or none
# remote; rc 1 = a named failure on stdout.
# A TCP connect proves reachability and NOTHING ELSE, and on the ZMQ port that gap is
# load-bearing rather than pedantic: docker's userland proxy binds a published host port and
# accepts the connection ITSELF, so a containerised node whose publisher failed to bind answers
# the dial rc 0 — and a remote node is a natural thing to run in a container. Measured: a dial
# cannot separate that from a live node. One ZMTP greeting can, because an accept() cannot
# produce one; a real publisher sends 64 bytes beginning ff … 7f as soon as it accepts.
# Refusing here rather than warning is deliberate. A named setup error is recoverable in a
# minute; the failure it replaces is p2pool starving for block notifications while every check
# in the stack reports green, which nothing downstream can see.
# The connect is bounded by wrapping the whole exchange in `timeout` — `timeout` cannot wrap a
# bare redirection, so an unwrapped `exec` would inherit only the kernel's SYN-retry deadline
# against a host that stops answering between the dial above and this call.
# The release-gate harness carries the full probe. This is the greeting half alone because the
# shipped CLI cannot depend on the test harness: the duplication is forced by that boundary, not
# chosen, so if ZMTP's greeting shape moves, both copies move with it.
# PURE, over the hex the peer sent, so every failure class is reachable from a fixture with no
# socket: empty (the published-but-dead port), truncated, not-ZMTP, and ZMTP 2.
# Length first — every slice below is read with `16#`, and `16#` on an empty string is a fatal
# arithmetic error rather than a false verdict.
zmq_greeting_ok() { # <hex>; rc 0 only for a well-formed ZMTP >=3 greeting
    local g="${1,,}"
    [ "${#g}" -ge 24 ] && [ "${g:0:2}" = "ff" ] && [ "${g:18:2}" = "7f" ] && [ "$((16#${g:20:2}))" -ge 3 ]
}

zmq_endpoint_greets() { # <host> <port>; rc 0 only for a ZMTP >=3 peer
    local g
    g=$(timeout 5 bash -c '
        exec 3<>/dev/tcp/"$0"/"$1" 2>/dev/null || exit 1
        { printf "\xff\x00\x00\x00\x00\x00\x00\x00\x00\x7f\x03\x01NULL"; head -c 48 /dev/zero; } >&3
        head -c 64 <&3 | od -An -v -tx1 | tr -d " \n"' "$1" "$2" 2>/dev/null) || g=""
    zmq_greeting_ok "$g"
}

preflight_remote_nodes() { # <config-file>
    local cfg="$1" host port zmq
    if [ "$(jq -r '.monero.mode // "local"' "$cfg")" = "remote" ]; then
        host=$(jq -r '.monero.remote.host // ""' "$cfg")
        zmq=$(jq -r '.monero.remote.zmq_port // 18083' "$cfg")
        for port in $(jq -r '.monero.remote.rpc_port // 18081' "$cfg") "$zmq"; do
            if ! timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
                printf 'cannot reach the remote Monero node at %s:%s — check the host, the port, and that the node allows LAN access (monero.rpc_lan_access / zmq_lan_access on a Pithead host)' "$host" "$port"
                return 1
            fi
        done
        if ! zmq_endpoint_greets "$host" "$zmq"; then
            printf 'the remote Monero node at %s answers on ZMQ port %s but nothing there speaks ZMQ — a published container port with no publisher behind it answers a reachability check exactly like a live node does. Check that monerod is running with ZMQ enabled, and that zmq_lan_access is on if it is a Pithead host' "$host" "$zmq"
            return 1
        fi
    fi
    if [ "$(jq -r '.tari.mode // "local"' "$cfg")" = "remote" ]; then
        host=$(jq -r '.tari.remote.host // ""' "$cfg")
        port=$(jq -r '.tari.remote.grpc_port // 18142' "$cfg")
        if ! timeout 5 bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
            printf 'cannot reach the remote Tari node at %s:%s — check the host, the port, and that the node allows LAN access (tari.grpc_lan_access on a Pithead host)' "$host" "$port"
            return 1
        fi
    fi
    return 0
}

# rc: 0 installed, 1 failed, 2 nothing requested. The request is "disk<TAB>wipe" written by
# the wizard's combined submit; both fields are re-validated HERE because they arrive through
# a web form — the disk against the inventory this host published, the wipe mode against the
# fixed set. The container asks, the host decides.
consume_install_request() { # <spool-dir>
    local spool="$1" req="$1/install-request" target wipe err
    [ -f "$req" ] || return 2
    target=$(cut -f1 <"$req" | tr -dc 'a-zA-Z0-9_-')
    wipe=$(cut -f2 <"$req" | tr -dc 'a-z')
    rm -f "$req"
    case "$wipe" in keep | data | all) ;; *) wipe="keep" ;; esac
    if ! "$(install_bin)" --list 2>/dev/null | cut -f1 | grep -qx "$target"; then
        printf 'not an offered target: %s' "$target" >"$spool/error.txt"
        return 1
    fi
    log "Installing to /dev/$target (data: $wipe) ..."
    if err=$("$(install_bin)" --target "/dev/$target" --wipe "$wipe" --yes 2>&1); then
        touch "$spool/installed"
        log "Installed to /dev/$target."
        return 0
    fi
    printf '%s' "$err" | tail -n 2 | tr -d '[:cntrl:]' | tail -c 240 >"$spool/error.txt"
    warn "Install to /dev/$target failed."
    return 1
}
