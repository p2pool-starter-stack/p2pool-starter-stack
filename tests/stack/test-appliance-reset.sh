# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance reset domain (#1105 Phase 1, develop-v2 lane): the two-tier reset, and the boot-time
# wipe that carries out its heavier half. config-reset clears the operator's configuration and the
# rendered files that came from it while leaving the chain data alone, because re-running setup must
# not cost a resync; factory-reset does not wipe anything itself but arms a marker the next boot
# acts on, and refuses outright anywhere that is not an appliance. pithead-data-reset is that next
# boot: it decides reformat-versus-skip fail-safe, so a wedged /data can be recovered without a
# healthy one ever being destroyed by a misread, it leaves evidence behind that the wipe really
# happened rather than reporting success from a no-op (#1062), and it resolves the partition to
# operate on by PARTLABEL on the disk actually booted from, never by a bare label that a second
# disk could answer for (#926). Sourced by tests/stack/run.sh.
#
# $WALLET IS SEEDED BELOW — do not delete it as redundant. The config-reset section writes a
# config.json and reads $WALLET to do it, but nothing in this file calls either sandbox builder.
# lib.sh sets WALLET only inside build_val_sandbox and build_control_sandbox, as a defaulted
# assignment, which retires the coupling for anything that CALLS a builder and does nothing at all
# for anything that does not. This file calls neither, so without the seed it cannot be sourced on
# its own under set -u. The seed defaults, so an ambient value still wins, and it falls back to
# lib.sh's checksum-valid dummy — never a real address.
#
# Three names look like the same hazard on a first pass and are not. $VALID_PRIMARY — the fallback
# in the seed line above — and $VALID_TARI, which sits on the same printf as $WALLET, are both
# assigned by lib.sh at top level, so they are genuinely ambient and need no seed of their own; the
# way to tell them from $WALLET is where lib.sh assigns the name, not how it reads at the call site.
# $REPAIR_LOG reads as unassigned to a scan anchored at line-start, because it is the second name on
# an export line inside this file — every read of it here is defaulted in any case.
#
# Otherwise: $ROOT, $SANDBOX and $STACK come from the harness as they do for every domain file,
# along with lib.sh's assert_eq, assert_rc, assert_contains and assert_not_contains. The three
# functions the reset decision itself is made of — boot_disk_part, data_reset_decision and
# record_wipe — come from os/overlay/pithead-data-reset, which the sections source for themselves
# before each call rather than inheriting it from anywhere. Every other name is assigned here.

WALLET="${WALLET:-$VALID_PRIMARY}"

echo "== black-box: config-reset clears config, keeps the chains (appliance two-tier reset) =="
# A throwaway deployment: config.json + rendered files + data dirs. docker is a noop; the reboot is
# a stub that just records that it fired, so we assert the reboot without rebooting the runner.
CR="$SANDBOX/config-reset"
mkdir -p "$CR/bin" "$CR/data/monero" "$CR/data/tor"
cp "$STACK" "$CR/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/sudo"
chmod +x "$CR/bin/docker" "$CR/bin/sudo"
seed_cr() {
    printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$CR/config.json"
    printf 'DEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n' >"$CR/.env"
    : >"$CR/Caddyfile"
    : >"$CR/data/monero/blockchain" # stand-in for the synced chain
    : >"$CR/data/tor/hostname"      # stand-in for the onion key material
}
# Wrong confirmation word: aborts, changes nothing.
seed_cr
out=$(cd "$CR" && printf 'nope\n' | PITHEAD_APPLIANCE=0 PATH="$CR/bin:$PATH" ./pithead config-reset 2>&1) || true
assert_contains "config-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted config-reset keeps config.json" "$([ -f "$CR/config.json" ] && echo yes)" "yes"
# -y off the appliance: config + rendered files go, data dirs stay, no reboot — just the hint.
seed_cr
rebooted="$CR/.rebooted"
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=0 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_rc "config-reset succeeds" "$?" "0"
assert_eq "config-reset removes config.json" "$([ -f "$CR/config.json" ] || echo gone)" "gone"
assert_eq "config-reset removes .env" "$([ -f "$CR/.env" ] || echo gone)" "gone"
assert_eq "config-reset removes Caddyfile" "$([ -f "$CR/Caddyfile" ] || echo gone)" "gone"
assert_eq "config-reset KEEPS the monero chain" "$([ -f "$CR/data/monero/blockchain" ] && echo kept)" "kept"
assert_eq "config-reset KEEPS the Tor onion key" "$([ -f "$CR/data/tor/hostname" ] && echo kept)" "kept"
assert_eq "config-reset off the appliance does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"
assert_contains "config-reset hints how to reconfigure" "$out" "firstboot-wizard"
# On the appliance: same wipe, but it reboots into first-boot setup.
seed_cr
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_eq "config-reset on the appliance reboots into firstboot" "$([ -f "$rebooted" ] && echo yes)" "yes"
# Already unprovisioned: nothing to reset.
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1) || true
assert_contains "config-reset refuses when config.json is absent" "$out" "already unprovisioned"
out=$(cd "$CR" && PATH="$CR/bin:$PATH" ./pithead config-reset --bogus 2>&1) || true
assert_contains "config-reset rejects unknown options" "$out" "Unknown option"

echo "== black-box: factory-reset arms the boot-time wipe, appliance-only (two-tier reset) =="
FR="$SANDBOX/factory-reset"
mkdir -p "$FR/bin" "$FR/esp"
cp "$STACK" "$FR/pithead"
marker="$FR/esp/pithead-reset"
rebooted="$FR/.rebooted"
# Off the appliance: refuse, arm nothing, point at uninstall.
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=0 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset off the appliance refuses" "$out" "only runs on the appliance"
assert_eq "refused factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# Wrong confirmation word on the appliance: aborts, arms nothing.
out=$(cd "$FR" && printf 'nope\n' | PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset 2>&1) || true
assert_contains "factory-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# -y on the appliance: BATTERY — the marker is written AND the reboot fires (both, or the wipe
# either never runs or never reaches the boot that runs it).
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1)
assert_rc "factory-reset succeeds" "$?" "0"
assert_eq "factory-reset arms the ESP marker AND reboots" \
    "$([ -f "$marker" ] && [ -f "$rebooted" ] && echo armed-and-rebooting)" "armed-and-rebooting"
# ESP not writable: refuse loudly, reboot nothing (a box that quietly did nothing is the trap).
rm -f "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/no-such-esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset refuses when the ESP marker cannot be written" "$out" "Could not arm"
assert_eq "unarmable factory-reset does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"

echo "== unit: pithead-data-reset decides reformat-vs-skip fail-safe (wedged-/data recovery) =="
# Source the boot script (functions only — its main is guarded) and drive data_reset_decision with
# stubbed repair tools, in a subshell so its set -u / defs never leak into the suite.
#
# The stubs model each tool's REAL contract, because the old ones could not fail (#1086): `fsck` was
# `exit 0` and the mount stub succeeded on its second call whatever had run in between, so "fsck
# repairs the mount -> skip" was true of the stub and said nothing about the product. Here a
# partition carries a damage level, each tool repairs only the damage it can, and mount succeeds only
# once something actually repaired it — so the assertions below are about the escalation, not the
# harness. REPAIRABLE_BY names the tool that fixes this partition: preen, e2fsck, backup, or none.
DR="$SANDBOX/data-reset"
mkdir -p "$DR/bin"
cat >"$DR/bin/mount" <<'EOF'
#!/usr/bin/env bash
# Mounts when the partition was never damaged, or once the repair log says the right tool ran.
[ "${REPAIRABLE_BY:-none}" = "healthy" ] && exit 0
grep -qx "repaired" "${REPAIR_STATE:-/dev/null}" 2>/dev/null && exit 0
exit 1
EOF
# fsck -p: preen repairs ONLY what needs no operator decision and refuses the rest by definition —
# rc 8 with a "try an alternate superblock" hint is exactly what it does to the damage this issue is
# about (#1062). It must never be able to repair a partition the real one could not.
cat >"$DR/bin/fsck" <<'EOF'
#!/usr/bin/env bash
echo "fsck $*" >>"${REPAIR_LOG:-/dev/null}"
[ "${REPAIRABLE_BY:-none}" = "preen" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; }
exit 8
EOF
# e2fsck -y: repairs what preen refused. With -b it rebuilds the primary superblock from a backup —
# the only thing that saves a partition whose superblock is gone.
cat >"$DR/bin/e2fsck" <<'EOF'
#!/usr/bin/env bash
echo "e2fsck $*" >>"${REPAIR_LOG:-/dev/null}"
case " $* " in
*" -b "*) [ "${REPAIRABLE_BY:-none}" = "backup" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
*) [ "${REPAIRABLE_BY:-none}" = "e2fsck" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
esac
exit 8
EOF
# mke2fs -n computes the layout and writes nothing; this is the shape its backup list prints in.
cat >"$DR/bin/mke2fs" <<'EOF'
#!/usr/bin/env bash
echo "mke2fs $*" >>"${REPAIR_LOG:-/dev/null}"
printf 'Creating filesystem with 131072 4k blocks\nSuperblock backups stored on blocks:\n\t32768, 98304, 163840\n'
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$DR/bin/umount"
chmod +x "$DR/bin/mount" "$DR/bin/umount" "$DR/bin/fsck" "$DR/bin/e2fsck" "$DR/bin/mke2fs"
decide() { # $1 marker-file, $2 which tool can repair this partition (healthy|preen|e2fsck|backup|none)
    (
        export PATH="$DR/bin:$PATH"
        export REPAIRABLE_BY="$2" # exported: the stubs run as child processes
        export REPAIR_STATE="$DR/state" REPAIR_LOG="$DR/log"
        : >"$REPAIR_STATE"
        : >"$REPAIR_LOG"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        data_reset_decision "/dev/fake-data" "$1"
    )
}
touch "$DR/marker-present"
assert_eq "marker present -> reformat-requested (even if /data would mount)" "$(decide "$DR/marker-present" healthy)" "reformat-requested"
assert_eq "no marker + /data mounts clean -> skip (fail-safe: never touch a healthy partition)" "$(decide "$DR/no-marker" healthy)" "skip"
assert_eq "no marker + preen repairs the mount -> skip (a dirty filesystem is not a lost one)" "$(decide "$DR/no-marker" preen)" "skip"
# The defect (#1062): `fsck -p` refuses precisely the damage a full e2fsck recovers, so stopping
# there sent a salvageable partition — wallets, onion keys, both chains — to mkfs.ext4 -F.
assert_eq "no marker + only a full e2fsck can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" e2fsck)" "skip"
# The textbook case the issue reproduced: a corrupt primary superblock, recoverable only from a
# backup, which `fsck -p` reports by printing the very command that would have saved it.
assert_eq "no marker + only a backup superblock can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" backup)" "skip"
assert_eq "no marker + no repair mounts it -> reformat-wedged (the box would be bricked otherwise)" "$(decide "$DR/no-marker" none)" "reformat-wedged"
# Escalation order: least destructive first, and every rung tried before the partition is erased.
decide "$DR/no-marker" none >/dev/null
dr_log="$(cat "$DR/log")"
assert_contains "preen runs first" "$dr_log" "fsck -p -t ext4 /dev/fake-data"
assert_contains "then a full e2fsck" "$dr_log" "e2fsck -y /dev/fake-data"
assert_contains "then the backup superblocks mke2fs -n reports" "$dr_log" "e2fsck -y -b 32768 /dev/fake-data"
assert_contains "the backup offsets are computed, never hardcoded" "$dr_log" "mke2fs -n /dev/fake-data"
assert_eq "the backup retry is bounded, so a destroyed filesystem cannot grind forever" "$(grep -c 'e2fsck -y -b' "$DR/log")" "2"
# A partition the FIRST tool fixes must not be handed to the later, heavier ones.
decide "$DR/no-marker" preen >/dev/null
assert_not_contains "a preen-repaired partition never reaches e2fsck" "$(cat "$DR/log")" "e2fsck"

echo "== unit: pithead-data-reset leaves evidence that /data was wiped (#1062) =="
# A reformatted box and a factory-fresh one both boot into the wizard, so without this the operator
# reads a wipe as "it reset itself" and never learns the disk may have been salvageable. The ESP is
# the only writable thing a /data reformat leaves standing.
DRW="$SANDBOX/data-reset-wipe"
mkdir -p "$DRW/esp"
(
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    record_wipe "$DRW/esp" "unrecoverable /data reinitialized — everything on it was lost"
    record_wipe "" "an ESP that would not mount must never block the recovery"
)
assert_eq "the wipe is recorded on the ESP" "$([ -f "$DRW/esp/pithead-data-wiped" ] && echo present || echo absent)" "present"
assert_contains "the record says what was lost" "$(cat "$DRW/esp/pithead-data-wiped")" "everything on it was lost"
assert_contains "the record is timestamped" "$(cat "$DRW/esp/pithead-data-wiped")" "$(date -u +%Y-)"
assert_eq "one wipe, one line" "$(wc -l <"$DRW/esp/pithead-data-wiped" | tr -d ' ')" "1"

echo "== unit: pithead-data-reset boot_disk_part resolves by PARTLABEL on the boot disk (#926) =="
# Stubbed findmnt + lsblk (the same PATH-stub shape pithead's own prefill_from_previous_install
# test uses for lsblk). findmnt always answers the fake root partition; lsblk branches on its
# first flag: -no PKNAME returns the parent disk name, -lnpo NAME,PARTLABEL lists that disk's
# partitions with their labels — never a bare/unscoped label lookup.
DRP="$SANDBOX/data-reset-partition"
mkdir -p "$DRP/bin"
printf '#!/usr/bin/env bash\necho "/dev/vda2"\n' >"$DRP/bin/findmnt"
# The stub's labels are DERIVED from the real build inputs, not hand-typed: mkimage's sgdisk line
# names the ESP, repart.d names the data partition. If either file ever changes its casing or
# name, this test fails instead of green-lighting a lookup that no longer matches reality.
DRP_ESP_LABEL=$(grep -oE '\-c 1:[a-zA-Z]+' "$ROOT/os/rauc/mkimage.sh" | cut -d: -f2)
DRP_DATA_LABEL=$(grep -oE '^Label=.*' "$ROOT/os/rootfs/repart.d/40-data.conf" | cut -d= -f2)
assert_eq "the ESP label mkimage bakes is the one data-reset looks up" "$DRP_ESP_LABEL" "esp"
assert_eq "the data label repart declares is the one data-reset looks up" "$DRP_DATA_LABEL" "data"
cat >"$DRP/bin/lsblk" <<EOF
#!/usr/bin/env bash
case "\$1" in
-no) echo "vda" ;;
-lnpo) printf '/dev/vda1 ${DRP_ESP_LABEL}\n/dev/vda4 ${DRP_DATA_LABEL}\n' ;;
esac
EOF
chmod +x "$DRP/bin/findmnt" "$DRP/bin/lsblk"
resolve() { # $1: partlabel
    (
        export PATH="$DRP/bin:$PATH"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        boot_disk_part "$1"
    )
}
assert_eq "boot_disk_part data -> the data partition on the boot disk" "$(resolve data)" "/dev/vda4"
assert_eq "boot_disk_part esp -> the ESP on the boot disk" "$(resolve esp)" "/dev/vda1"
assert_eq "boot_disk_part on a label the boot disk doesn't carry -> empty (first boot, pre-repart)" \
    "$(resolve nosuchlabel)" ""

# A container/unexpected root (mountinfo source isn't /dev/*) must fail closed, not guess.
printf '#!/usr/bin/env bash\necho "overlay"\n' >"$DRP/bin/findmnt"
out=$(
    export PATH="$DRP/bin:$PATH"
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    boot_disk_part data
)
rc=$?
assert_rc "boot_disk_part on a non-/dev root -> rc 1" "$rc" "1"
assert_eq "boot_disk_part on a non-/dev root -> prints nothing" "$out" ""
