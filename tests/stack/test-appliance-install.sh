# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance install domain (#1105 Phase 1, develop-v2 lane): getting Pithead onto a machine, and
# what the next install reads back off the one before it. The installer gate retries a device
# probe that has not settled yet, so a reinstall boot does not fall through into setup mode; the
# installation medium's pre-seeded config and the ESP's wipe note are read as input rather than
# truth, and published to the wizard's spool; the appliance refuses the plain-tarball upgrade path
# a host install would take; consume_install_request validates a browser-supplied disk target on
# the host side; and the reinstall pre-fill strips every secret class before publishing the
# remainder, failing open when there is no previous install to read.
# Sourced by tests/stack/run.sh.
#
# Shape: one contiguous run plus one island. The source stanza sits at the contiguous run's exact
# former position, so all but the island execute exactly where they did. The island is the
# installer-gate section, which moves later in the order; it is safe to move because it is closed
# over itself — it builds its own mktemp tree, sources $STACK inside a subshell rather than
# relying on an ambient definition, and removes the tree and unsets its names before it ends, so
# nothing between its old position and its new one can observe that it ran.
#
# Left behind, deliberately, and this one is a coupling finding rather than a taste call: the
# host-installer cluster (install.sh's host gate, its fails-closed download verification, and the
# uninstall counterpart) is topically the strongest install content in the suite and is NOT
# takeable today. Those sections read $V, $WALLET and seed_env, none of which lib.sh defines at
# top level — they exist only as a side effect of build_val_sandbox() having been called, and the
# calls that satisfy them live in sibling domain files that run.sh happens to source earlier.
# The download-verification section additionally reads $REL, which leaks out of test-release.sh
# the same way, and it spans four other domains' source stanzas, so moving it would relocate
# where those domains load. Taking that cluster would either import a cross-file source-order
# dependency or require re-deriving the shared validation sandbox, and re-deriving it resets a
# tree that sections still in run.sh are using. It needs its own change, with that coupling
# addressed on purpose, not a move cut that inherits it quietly.
#
# Also left behind: load_baked_images, whose own comment names pithead-boot and the first-boot
# wizard as its owners; reinstall_prefill_verdict, which belongs with the boot-time verdict
# helpers it sits among rather than with the pre-fill it reports on; and the boot mechanics
# already promised to the appliance-boot cut.
#
# Re-derivations: none, and that is checkable rather than asserted — every name this file uses
# that it does not assign itself resolves in lib.sh. $SANDBOX, $STACK, $VALID_PRIMARY and
# $VALID_TARI are lib.sh top-level assignments, and run_sourced, ok, bad, assert_eq,
# assert_contains and assert_rc are lib.sh functions. Nothing here reads the shared validation or
# control sandboxes, writes the ambient .env or Caddyfile, or leaves state behind: each section
# builds its own mktemp tree and unsets its names as it ends. The PITHEAD_* names a section drives
# its subject with go two ways, and the assignment form decides which — one riding as a command
# prefix never enters this shell, while one exported standalone persists and is unset with the
# rest of that section's state. Read the form in front of you rather than the prefix of the name.

echo "== unit: the installer gate outlasts a slow device probe =="
# An empty FIRST inventory put a reinstall boot into setup mode (KVM keep leg): the gate runs
# ~18s into boot and races udev settling the target's partitions. It now retries before giving
# up — a probe that answers on the third try still opens the installer.
mk_tmpdir IGSB
cat >"$IGSB/fake-install" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--list" ] || exit 0
N=$(cat "${IG_COUNT:?}" 2>/dev/null || echo 0)
echo $((N + 1)) >"$IG_COUNT"
[ "$N" -ge 2 ] && printf 'vda\t30G\tFake\tSN\tpithead-with-data\n'
exit 0
FAKE
chmod +x "$IGSB/fake-install"
igout=$(
    cd "$IGSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    boot_is_removable() { return 0; }
    udevadm() { :; }
    sleep() { :; } # the retry cadence is not what is under test
    echo 0 >"$IGSB/count"
    PITHEAD_INSTALL_BIN="$IGSB/fake-install" IG_COUNT="$IGSB/count" installer_mode_available && echo GATE-OPEN
)
assert_contains "a third-try inventory still opens the installer" "$igout" "GATE-OPEN"
rm -rf "$IGSB"
unset IGSB igout

echo "== unit: pre-seeding from the installation medium =="
# The ESP is FAT and anyone can write it, so both readers treat its contents as input, not truth.
mk_tmpdir PSD
export PITHEAD_PRESEED_DIR="$PSD"

run_sourced "$SANDBOX" preseed_token >/dev/null 2>&1
assert_rc "no token file -> rc 1 (mint one instead)" "$?" "1"

printf 'pit-ABC123\n' >"$PSD/pithead-token.txt"
assert_eq "token read from the medium" "$(run_sourced "$SANDBOX" preseed_token)" "pit-ABC123"

printf 'pit-ABC123; rm -rf /\n' >"$PSD/pithead-token.txt"
assert_eq "token sanitised to its alphabet" "$(run_sourced "$SANDBOX" preseed_token)" "pit-ABC123rm-rf"

printf 'ab\n' >"$PSD/pithead-token.txt"
run_sourced "$SANDBOX" preseed_token >/dev/null 2>&1
assert_rc "implausibly short token refused" "$?" "1"
rm -f "$PSD/pithead-token.txt"

run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "no config file -> rc 2 (nothing pre-seeded)" "$?" "2"

printf '{"monero":{"wallet_address":"nope"},"tari":{"wallet_address":"t"}}' >"$PSD/pithead-config.json"
run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "invalid config -> rc 1, wizard still opens" "$?" "1"
[ -f "$PSD/out.json" ] && bad "rejected config NOT installed" "it was" || ok "rejected config NOT installed"

printf '{"monero":{"wallet_address":"%s"},"tari":{"wallet_address":"'"$VALID_TARI"'"},"p2pool":{"pool":"mini","stratum_password":"auto"}}' \
    "$VALID_PRIMARY" >"$PSD/pithead-config.json"
cp "$PSD/pithead-config.json" "$PSD/original.json"
run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "valid config -> rc 0" "$?" "0"
[ -s "$PSD/out.json" ] && ok "valid config installed" || bad "valid config installed" "missing"
# The medium must come back unchanged: validation fills in generated credentials, and writing
# those back would hand every machine in a fleet the first one's secrets.
if cmp -s "$PSD/pithead-config.json" "$PSD/original.json"; then
    ok "the medium is left byte-for-byte unchanged"
else
    bad "the medium is left byte-for-byte unchanged" "it was rewritten"
fi
unset PITHEAD_PRESEED_DIR PSD

echo "== unit: data_wipe_note / publish_data_wipe_note — the wipe note reader + spool carrier (#1121) =="
# pithead-data-reset's own record_wipe format ("<UTC when> <reason>\n", appended to the ESP's
# pithead-data-wiped) is the contract; this only reads it, never guesses it. "recovery"
# discriminates a deliberate factory-reset (the operator asked for it, nothing to warn about)
# from the wedged-/data case, where the wizard's next-move advice differs: restore a backup,
# don't set up as if this were a fresh machine.
mk_tmpdir DWN
mkdir -p "$DWN/esp" "$DWN/spool"
export PITHEAD_PRESEED_DIR="$DWN/esp"

run_sourced "$SANDBOX" data_wipe_note >/dev/null 2>&1
assert_rc "no note file -> rc 1" "$?" "1"

printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
note=$(run_sourced "$SANDBOX" data_wipe_note)
assert_eq "the wedged-partition wipe -> recovery true" "$(printf '%s' "$note" | jq -r '.recovery')" "true"
assert_eq "the last line's timestamp is carried through" "$(printf '%s' "$note" | jq -r '.when')" "2026-08-21T09:00:00Z"
assert_eq "the last line's reason is carried through" "$(printf '%s' "$note" | jq -r '.reason')" \
    "unrecoverable /data reinitialized — everything on it was lost"

printf '2026-08-20T08:00:00Z factory-reset requested\n2026-08-21T09:00:00Z factory-reset requested\n' >"$DWN/esp/pithead-data-wiped"
note=$(run_sourced "$SANDBOX" data_wipe_note)
assert_eq "a deliberate factory-reset -> recovery false" "$(printf '%s' "$note" | jq -r '.recovery')" "false"
assert_eq "append-only log: only the LAST line is read" "$(printf '%s' "$note" | jq -r '.when')" "2026-08-21T09:00:00Z"

printf 'garbage\n' >"$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" data_wipe_note >/dev/null 2>&1
assert_rc "a line with no '<when> <reason>' shape -> rc 1, never a made-up note" "$?" "1"

# publish_data_wipe_note carries the note to the wizard's spool — the wizard container's ONLY
# mount, so it cannot read PRESEED_DIR itself.
rm -f "$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "no note -> the spool gets an empty object, not a missing file" "$(cat "$DWN/spool/data-wiped.json")" "{}"
assert_eq "no temp file left beside the atomic target" \
    "$(find "$DWN/spool" -name '.data-wiped.json.*' | wc -l | tr -d ' ')" "0"

printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "a real note reaches the spool" "$(jq -r '.recovery' "$DWN/spool/data-wiped.json")" "true"

# The fleet-stick rule (same as publish_rig_defaults, #797 R3): a MISSING note must overwrite a
# PREVIOUS machine's note, never leave it standing — the spool survives on /data between
# machines. MUTATION PROOF: an early return in the publisher (`note=$(data_wipe_note) || return
# 0`) leaves the previous machine's note in place; this assertion catches it (see the table in
# the PR description for the actual red run).
rm -f "$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "a stale note from a previous machine does not survive an absent one" "$(cat "$DWN/spool/data-wiped.json")" "{}"

# Removable boot media: PRESEED_DIR is the STICK's own ESP there, describing the stick, never
# THIS machine — the publisher must not carry it across even when the stick's ESP holds a note.
printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    boot_is_removable() { return 0; }
    publish_data_wipe_note "$DWN/spool"
) >/dev/null 2>&1
assert_eq "booting from removable media never carries the STICK's own note across" \
    "$(cat "$DWN/spool/data-wiped.json")" "{}"

unset PITHEAD_PRESEED_DIR
rm -rf "$DWN"
unset DWN note

echo "== unit: is_appliance gates the tarball upgrade =="
# The appliance's program tree is resynced from the system slot every boot, so a DIY tarball
# upgrade would silently revert — both upgrade entrances must refuse when the host is one.
out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" stack_upgrade 2>&1)
assert_rc "appliance: stack_upgrade refuses" "$?" "1"
assert_contains "refusal explains the revert-at-reboot trap" "$out" "revert at the next reboot"
PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" is_appliance
assert_rc "override PITHEAD_APPLIANCE=1 -> appliance" "$?" "0"
PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" is_appliance
assert_rc "override PITHEAD_APPLIANCE=0 -> not appliance" "$?" "1"

echo "== unit: consume_install_request (disk installer host side) =="
# The request file is operator input arriving through a web form; the host must validate it
# against its own inventory and never trust a browser-supplied target. Driven against a fake
# pithead-install via PITHEAD_INSTALL_BIN — the real one partitions disks.
mk_tmpdir INSTSB
cat >"$INSTSB/fake-install" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
--list) printf 'vda\t40G\tFake Disk\tSN1\tempty\n' ;;
--target)
    # record target + wipe mode (args: --target /dev/X [--wipe M] --yes)
    echo "$2 ${4:-}" >>"${FAKE_LOG:?}"
    exit "${FAKE_RC:-0}"
    ;;
esac
FAKE
chmod +x "$INSTSB/fake-install"
export PITHEAD_INSTALL_BIN="$INSTSB/fake-install" FAKE_LOG="$INSTSB/calls" FAKE_RC=0

mkdir -p "$INSTSB/spool"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "empty spool -> rc 2 (nothing requested)" "$?" "2"

printf 'vda\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "offered target -> rc 0" "$?" "0"
assert_eq "installer invoked with /dev/vda and the wipe mode" "$(cat "$INSTSB/calls")" "/dev/vda keep"
[ -f "$INSTSB/spool/installed" ] && ok "installed marker written" || bad "installed marker written" "missing"
[ -f "$INSTSB/spool/install-request" ] && bad "request consumed" "still present" || ok "request consumed"

# The wipe mode is validated HERE too: a crafted mode falls back to keep, never reaches a shell.
rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'vda\tdata' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_eq "wipe mode passes through" "$(cat "$INSTSB/calls")" "/dev/vda data"
rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'vda\t; rm -rf /' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_eq "hostile wipe mode normalized to keep" "$(cat "$INSTSB/calls")" "/dev/vda keep"

rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'sdz\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "unlisted target -> rc 1, refused" "$?" "1"
assert_contains "refusal names the target" "$(cat "$INSTSB/spool/error.txt")" "sdz"
[ -f "$INSTSB/calls" ] && bad "installer NOT invoked for unlisted target" "was invoked" || ok "installer NOT invoked for unlisted target"

# A browser-supplied name is sanitized before it can reach a shell: path characters vanish and
# the remainder no longer matches the inventory.
rm -f "$INSTSB/spool/error.txt"
printf '../../vda; rm -rf /\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "hostile target string -> rc 1, refused" "$?" "1"
[ -f "$INSTSB/calls" ] && bad "installer NOT invoked for hostile string" "was invoked" || ok "installer NOT invoked for hostile string"

# Installer failure surfaces into the spool for the page, and no success marker appears.
rm -f "$INSTSB/spool/error.txt"
printf 'vda\tkeep' >"$INSTSB/spool/install-request"
FAKE_RC=1 run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "installer failure -> rc 1" "$?" "1"
[ -f "$INSTSB/spool/error.txt" ] && ok "failure surfaced to the page" || bad "failure surfaced to the page" "no error.txt"
[ -f "$INSTSB/spool/installed" ] && bad "no success marker on failure" "present" || ok "no success marker on failure"

unset PITHEAD_INSTALL_BIN FAKE_LOG FAKE_RC INSTSB

echo "== unit: strip_config_secrets — no secret class survives the reinstall pre-fill =="
# The strip runs before a previous install's config may be SHOWN on the setup page. Every
# secret carries the same marker value, so one grep proves the whole list at once; the
# non-secret answers (the point of the pre-fill) must all survive.
mk_tmpdir SCS
cat >"$SCS/prev.json" <<'PREV'
{
  "monero": {"wallet_address": "4KEEP-WALLET", "mode": "remote",
             "remote": {"host": "node.lan", "rpc_port": 18081, "zmq_port": 18083},
             "node_username": "LEAK-user", "node_password": "LEAK-nodepw", "view_key": "LEAK-mvk"},
  "tari": {"wallet_address": "KEEP-TARI", "mode": "remote",
           "remote": {"host": "tari.lan", "grpc_port": 18142},
           "view_key": "LEAK-tvk", "spend_public_key": "LEAK-tspk"},
  "p2pool": {"pool": "main", "stratum_password": "LEAK-stratum"},
  "dashboard": {"timezone": "Europe/Berlin",
                "auth": {"username": "LEAK-dashuser", "password": "LEAK-dashpw"},
                "control": {"enabled": true},
                "onion": {"enabled": true, "client_auth": true},
                "workers": [{"name": "w0", "host": "h", "token": "LEAK-oldworker"}]},
  "workers": {"api_auth": true, "api_token": "LEAK-apitoken",
              "list": [{"name": "rig1", "host": "rig1.lan", "token": "LEAK-workertoken"}]},
  "telegram": {"enabled": true, "bot_token": "LEAK-bot", "chat_id": "LEAK-chat"},
  "healthchecks": {"ping_url": "https://hc.example/LEAK-ping"},
  "notifications": {"ntfy": {"url": "https://ntfy.example/LEAK-url", "token": "LEAK-ntfy"}},
  "ssh": {"enabled": true, "authorized_key": "ssh-ed25519 LEAK-sshkey"},
  "xvb": {"enabled": true, "standby": {"source": "LEAK-standby"}}
}
PREV
stripped=$(run_sourced "$SANDBOX" strip_config_secrets "$SCS/prev.json")
assert_rc "a real config strips cleanly (rc 0)" "$?" "0"
assert_eq "no secret of ANY class survives" "$(printf '%s' "$stripped" | grep -c 'LEAK-')" "0"
assert_eq "wallet address survives" "$(printf '%s' "$stripped" | jq -r '.monero.wallet_address')" "4KEEP-WALLET"
assert_eq "remote node mode survives" "$(printf '%s' "$stripped" | jq -r '.tari.mode')" "remote"
assert_eq "remote node host survives" "$(printf '%s' "$stripped" | jq -r '.tari.remote.host')" "tari.lan"
assert_eq "pool tier survives" "$(printf '%s' "$stripped" | jq -r '.p2pool.pool')" "main"
assert_eq "timezone survives" "$(printf '%s' "$stripped" | jq -r '.dashboard.timezone')" "Europe/Berlin"
# Secret-free is not the same as SUBMITTABLE (#1846). parse_and_validate_config fails closed on
# dashboard.control.enabled (:455) and dashboard.onion.enabled (:432) whenever the password is
# empty — and this strip is what empties it. Leaving either switch on published a pre-fill the
# page offers back and the first validation then refuses, which is how "Generate a strong
# password for me" became unusable on a reinstall: the HOST generates one only AFTER validation.
assert_eq "control.enabled goes with the login it needs" "$(printf '%s' "$stripped" | jq -r '.dashboard.control.enabled // "absent"')" "absent"
assert_eq "onion.enabled goes with the login it needs" "$(printf '%s' "$stripped" | jq -r '.dashboard.onion.enabled // "absent"')" "absent"
# The sibling that keeps the two above narrow: a dashboard answer that depends on NO credential is
# still carried over, so this is not "strip the whole dashboard block and call it safe".
assert_eq "client_auth, which needs no login, survives" "$(printf '%s' "$stripped" | jq -r '.dashboard.onion.client_auth')" "true"
# Not-a-config shapes are refused, not partially stripped: rc != 0 means "no pre-fill".
printf 'not json at all' >"$SCS/garbage.json"
if run_sourced "$SANDBOX" strip_config_secrets "$SCS/garbage.json" >/dev/null 2>&1; then
    bad "garbage file -> refused" "rc 0"
else
    ok "garbage file -> refused"
fi
printf '[1,2,3]' >"$SCS/array.json"
if run_sourced "$SANDBOX" strip_config_secrets "$SCS/array.json" >/dev/null 2>&1; then
    bad "non-object JSON -> refused" "rc 0"
else
    ok "non-object JSON -> refused"
fi
rm -rf "$SCS"
unset SCS stripped

echo "== unit: prefill_from_previous_install — fail open, publish only the stripped remainder =="
# The orchestration around the strip: exactly one disk with an install, a read-only mount, and
# every failure degrading to "no pre-fill" — never to a blocked install. mount/umount/lsblk are
# PATH stubs; the fake mount copies a fixture tree under the mountpoint.
mk_tmpdir PFSB
mkdir -p "$PFSB/bin" "$PFSB/spool" "$PFSB/prev/pithead"
printf '#!/bin/bash\necho "/dev/fake2 data"\n' >"$PFSB/bin/lsblk"
cat >"$PFSB/bin/mount" <<'MNT'
#!/bin/bash
[ "${PF_MOUNT_RC:-0}" -eq 0 ] || exit "$PF_MOUNT_RC"
# The mountpoint is the last argument; -P keeps fixture symlinks AS symlinks.
cp -RP "${PF_TREE:?}/." "${!#}/"
MNT
printf '#!/bin/bash\nexit 0\n' >"$PFSB/bin/umount"
chmod +x "$PFSB/bin/lsblk" "$PFSB/bin/mount" "$PFSB/bin/umount"
export PF_TREE="$PFSB/prev"
printf 'sda\t4T\tPrev Disk\tSN9\tpithead-with-data\n' >"$PFSB/spool/disks.tsv"
printf '{"monero":{"wallet_address":"4PREV"},"dashboard":{"auth":{"username":"op","password":"LEAK-pw"}}}' \
    >"$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "previous install found -> pre-fill published (rc 0)" "$?" "0"
assert_eq "pre-fill keeps the wallet" "$(jq -r '.monero.wallet_address' "$PFSB/spool/last-attempt.json")" "4PREV"
assert_eq "pre-fill carries NO login" "$(grep -c 'LEAK-' "$PFSB/spool/last-attempt.json")" "0"
assert_eq "no temp file left beside the atomic target" "$(find "$PFSB/spool" -name '.last-attempt*' | wc -l | tr -d ' ')" "0"

# Broken previous config -> no pre-fill, no error surfaced to the page.
rm -f "$PFSB/spool/last-attempt.json"
printf '{broken' >"$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "broken previous config -> rc 1" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "broken config publishes nothing" "file exists" || ok "broken config publishes nothing"
[ -f "$PFSB/spool/error.txt" ] && bad "broken config surfaces no page error" "error.txt written" || ok "broken config surfaces no page error"

# Absent previous config -> no pre-fill.
rm -f "$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "no previous config -> rc 1" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "no config publishes nothing" "file exists" || ok "no config publishes nothing"

# A mount failure (corrupt filesystem, busy partition) fails open too.
printf '{"monero":{"wallet_address":"4PREV"}}' >"$PFSB/prev/pithead/config.json"
PF_MOUNT_RC=32 PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "mount failure -> rc 1, nothing blocked" "$?" "1"

# Symlink escape: a crafted disk pointing config.json — or the pithead dir itself — at a file
# on the RUNNING host must publish nothing, even when the target parses as a valid config.
printf '{"monero":{"wallet_address":"4HOST-FILE"}}' >"$PFSB/outside.json"
rm -f "$PFSB/prev/pithead/config.json"
ln -s "$PFSB/outside.json" "$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "symlinked config.json -> rc 1, refused" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "symlinked config publishes nothing" "file exists" || ok "symlinked config publishes nothing"
mkdir -p "$PFSB/outside-dir"
printf '{"monero":{"wallet_address":"4HOST-FILE"}}' >"$PFSB/outside-dir/config.json"
rm -rf "$PFSB/prev/pithead"
ln -s "$PFSB/outside-dir" "$PFSB/prev/pithead"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "symlinked pithead dir -> rc 1, refused" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "symlinked dir publishes nothing" "file exists" || ok "symlinked dir publishes nothing"
rm -rf "$PFSB/prev/pithead"
mkdir -p "$PFSB/prev/pithead"

# Two disks carrying installs: WHICH machine's answers is a guess — publish none.
printf 'sda\t4T\tPrev A\tSN9\tpithead-with-data\nsdb\t4T\tPrev B\tSN8\tpithead-with-data\n' >"$PFSB/spool/disks.tsv"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "two candidate disks -> rc 1, no guessing" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "ambiguous target publishes nothing" "file exists" || ok "ambiguous target publishes nothing"

# No disk with data at all (the everyday fresh-install stick) -> rc 1, quietly.
printf 'vda\t40G\tBlank\tSN1\tempty\n' >"$PFSB/spool/disks.tsv"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "no install on any disk -> rc 1" "$?" "1"
rm -rf "$PFSB"
unset PFSB PF_TREE
