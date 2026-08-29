# shellcheck shell=bash
#
# Appliance identity and boot-provisioning domain (#1105 Phase 1, develop-v2 lane): the overlay
# units that give a freshly imaged machine an identity of its own, and the boot-time work whose
# success a later boot has to be able to prove. pithead-machine-id restores THROUGH
# /etc/machine-id rather than unmounting it first, because on a read-only-root A/B slot the
# unmount exposes the lower image and the write then fails, leaving an empty id and a machine
# that comes back as a stranger. pithead-hugepages sizes the RandomX pool against the machine's
# own RAM and degrades on a small box instead of refusing to boot (#977), with the overlay's pool
# figure, the CLI's PITHEAD_HUGEPAGES and the rootfs's baked sysctl line all held to one value,
# because drift between them re-opens the silent floor that cap was written to close. Then the
# boot verdicts, each of which exists because a simpler check could not tell two different
# histories apart: hugepages_boot_verdict separates a boot where the unit ran and had nothing to
# do from one where it never ran at all (#1212); restore_live_state_verdict demands proof that the
# restored machine is RUNNING what was restored, since config.json sitting on disk is not that
# proof (#1091); reinstall_prefill_verdict refuses to read a matching wallet as evidence of which
# code path produced it (#1038). The rest covers the identity a machine mints for itself and the
# disks it has to find: pithead-ssh-host-keys generates a per-machine host key on /data and only
# once (#894/#980), and pithead-mount-generator follows the BOOTED disk rather than a label, so a
# second disk carrying the same label cannot capture /data or the ESP (#926/#980). os/build-image.sh's
# flag parsing and its 404 remedy hint are proven here too, without a build. All of it is at the
# shell-unit tier: the scripts under test are sourced and called directly inside subshells, with
# no docker and no image build. Sourced by tests/stack/run.sh.
#
# THIS CUT REORDERED, and the reason is worth recording. In run.sh as it stood at the cut, this
# domain's sections were not contiguous: the source stanza for the appliance-media domain file sat
# between the reinstall-prefill verdict and the build-image section. That stanza stayed where it
# was. Moving it would have nested a domain file inside this one, and a nested stanza reassigns
# the same _d0 that the outer stanza passes to domain_ran — which would have narrowed this file's
# zero-assertion guard (#1400) to cover only the part running after the nesting, silently, with
# the suite still green and the moved text still byte-identical. So the cut took two ranges and
# left that stanza out of both, and the source stanza was placed at the machine-id section's
# former position, which keeps the larger part of the domain exactly where it ran before. The
# build-image, ssh-host-keys and mount-generator sections are the ones that moved: they now run
# before the appliance-media domain instead of after it.
#
# Why that is safe, argued rather than asserted, and in both directions. Those three sections
# inherit nothing FROM appliance-media. The only variables they read without assigning are $ROOT
# and $SANDBOX, and the only functions they call without defining are lib.sh's assertion helpers
# and apt_fetch_failure_hint: the variables and the helpers come from tests/stack/lib.sh, which is
# sourced before any domain file is, and apt_fetch_failure_hint comes from os/build-image.sh,
# which the section sources for itself inside the very subshell that calls it. So the domain they
# used to follow supplies none of them. FRESH_INDEX looks like a further such name and is not: it
# is set by os/build-image.sh and read back through a ${..:-} default inside that same subshell.
# And appliance-media inherits nothing FROM them, in either of the two ways it could. It reads no
# variable they assign — the only names it reads without assigning are $ROOT, $SANDBOX,
# $VALID_PRIMARY and $VALID_TARI, all of them lib.sh's, and none of the three relocated sections
# assigns any of the four. And it calls no function they now leave behind: those sections define
# build_image_test, run_hint, shk_run and mg_run at this file's level, and appliance-media calls
# none of those names. Their filesystem footprints are disjoint as well — the relocated sections
# work inside their own $SANDBOX subdirectories and one probe path that deliberately does not
# exist, while appliance-media works inside its own.
#
# Ambient contract. This file reads $ROOT and $SANDBOX from lib.sh and calls lib.sh's run_sourced
# along with its assertion helpers — assert_eq, assert_rc, assert_contains, assert_not_contains,
# ok and bad. It reads no $WALLET and none of the control-sandbox globals, so it carries no
# self-arm stanza and no seed lines: the moved text is byte-identical to what it replaced, with
# nothing authored inside it. Everything else it needs it sources for itself inside a subshell —
# os/overlay/pithead-hugepages for its pool figure, its sizing helper and its own entry point,
# tests/os/hugepages-boot-verdict.sh, tests/os/restore-live-state-verdict.sh and
# tests/os/reinstall-prefill-verdict.sh for the three verdict functions, and os/build-image.sh for
# its argument handling and remedy hint — so none of those reaches this file as ambient state.
# lib.sh alone is therefore the whole of this file's contract, and that is measured rather than
# asserted: sourcing lib.sh and then this file under set -u, with no run.sh in the picture, runs
# the domain to completion with no failures. Sourcing it WITHOUT lib.sh records no assertion at
# all — it stops inside the first section, at the first read of $SANDBOX, and the whole shell
# exits there rather than carrying on, because that read sits at the file's top level and not
# inside a subshell. The run ends non-zero. Read the message and the stop position, not the exit
# code: on this bash an unbound variable under set -u and a missing command both exit 127, so the
# code on its own cannot tell the two apart.

echo "== unit: pithead-machine-id — restore writes THROUGH /etc/machine-id, never unmounts it =="
# The regression this pins: an earlier version unmounted /etc/machine-id before writing, which on
# a read-only-root A/B slot exposed the lower image and the write failed — leaving an empty id and
# a dead DHCP lease. The write must land in the (writable) target as-is. ETC + ID_FILE are
# overridable so this runs without touching the real /etc.
MID="$SANDBOX/machine-id"
mkdir -p "$MID"
# 1) Restore: /data holds an id, /etc has a different (systemd-transient) one -> /etc takes /data's.
printf 'fa85bfc69f0b451d95bbacf897e431ce\n' >"$MID/data-id"
printf 'ffffffffffffffffffffffffffffffff\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "restore overwrites /etc/machine-id with the persisted id" "$(cat "$MID/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"
assert_eq "restore leaves the persisted id unchanged" "$(cat "$MID/data-id")" "fa85bfc69f0b451d95bbacf897e431ce"
# 2) Adopt: /data has none yet -> adopt this boot's /etc id and persist it read-only.
rm -f "$MID/data-id"
printf 'abc0000000000000000000000000def0\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "adopt persists this boot's id to /data" "$(cat "$MID/data-id" 2>/dev/null)" "abc0000000000000000000000000def0"
# 3) Nothing to adopt: /etc empty AND /data empty -> refuse loudly, persist nothing. A newline
# persisted here would satisfy [ -s ] forever and every later boot would restore garbage.
rm -f "$MID/data-id"
: >"$MID/etc-id"
if (
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1; then
    bad "empty-adopt: script must refuse when there is no id anywhere"
else
    ok "empty-adopt: refused (non-zero exit)"
fi
assert_eq "empty-adopt persists nothing" "$(cat "$MID/data-id" 2>/dev/null || echo absent)" "absent"

echo "== unit: pithead-hugepages — the RandomX reservation fits the machine's RAM (#977) =="
# The appliance bakes a 6 GiB hugepages reservation sized for the supported 16 GB machine; the
# boot-time sizing shrinks it LOUDLY on smaller RAM. The tier function is pure over a
# meminfo-shaped file, so every branch is provable here; the only thing left for the battery is
# that on the 16 GiB harness VM the sizing is a no-op (full pool intact, no marker).
HG="$SANDBOX/hugepages"
mkdir -p "$HG"
printf 'MemTotal:       16250000 kB\nMemFree:        16000000 kB\n' >"$HG/meminfo-16g"
printf 'MemTotal:       8050000 kB\n' >"$HG/meminfo-8g"
printf 'MemTotal:       4000000 kB\n' >"$HG/meminfo-4g"
printf 'MemTotal:       15728640 kB\n' >"$HG/meminfo-at-floor"
printf 'MemTotal:       15728639 kB\n' >"$HG/meminfo-under-floor"
printf 'MemTotal:       banana kB\n' >"$HG/meminfo-garbage"
printf 'MemFree:        123 kB\n' >"$HG/meminfo-no-total"

hg_want() {
    (
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-hugepages"
        hugepages_want "$1"
    )
}
assert_eq "16 GiB machine keeps the full 3072-page pool" "$(hg_want "$HG/meminfo-16g")" "3072"
assert_eq "exactly the 15 GiB floor keeps the full pool (a real 16 GB box clears it)" "$(hg_want "$HG/meminfo-at-floor")" "3072"
assert_eq "just under the floor reduces to 2560 pages (both RandomX datasets still fit)" "$(hg_want "$HG/meminfo-under-floor")" "2560"
assert_eq "8 GiB machine reduces to 2560 pages" "$(hg_want "$HG/meminfo-8g")" "2560"
assert_eq "4 GiB machine releases the reservation (0 pages)" "$(hg_want "$HG/meminfo-4g")" "0"
assert_eq "garbage MemTotal keeps the full baked pool (degrade only on evidence)" "$(hg_want "$HG/meminfo-garbage")" "3072"
assert_eq "missing MemTotal keeps the full baked pool" "$(hg_want "$HG/meminfo-no-total")" "3072"

# ONE definition, three copies: the overlay script's full value must match the CLI's
# PITHEAD_HUGEPAGES and the rootfs's baked sysctl line — drift here re-opens the silent floor.
cli_pages=$(run_sourced "$SANDBOX" eval 'echo "$PITHEAD_HUGEPAGES"')
overlay_pages=$(
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    echo "$FULL_PAGES"
)
assert_eq "overlay full pool matches the CLI's PITHEAD_HUGEPAGES" "$overlay_pages" "$cli_pages"
if grep -q "vm.nr_hugepages=$cli_pages" "$ROOT/os/rootfs/Dockerfile"; then
    ok "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)"
else
    bad "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)" \
        "no vm.nr_hugepages=$cli_pages line in os/rootfs/Dockerfile"
fi

# main, degraded tier: shrinks the pool file, leaves the plain-words marker doctor reads.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-8g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "low-RAM boot shrinks the pool to the reduced target" "$(cat "$HG/nr_hugepages")" "2560"
assert_contains "low-RAM boot announces the degrade on the console/journal" "$out" "below the supported 16 GB"
assert_contains "degraded marker names the supported floor in plain words" "$(cat "$HG/marker" 2>/dev/null)" "16 GB"
assert_eq "marker records the chosen page count — the authority later writers honour" \
    "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "2560"
assert_not_contains "degrade message carries no issue numbers (operator text)" "$out" "#9"

# main, too-small tier: releases the pool entirely and says the stack will not run.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-4g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "far-below-floor boot releases the reservation" "$(cat "$HG/nr_hugepages")" "0"
assert_contains "far-below-floor boot says the stack will not run reliably" "$out" "will not run reliably"
assert_eq "released marker records zero pages" "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "0"

# main, supported tier: a strict no-op — pool untouched, no marker, nothing said.
printf '3072\n' >"$HG/nr_hugepages"
rm -f "$HG/marker"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-16g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "supported machine leaves the baked pool alone" "$(cat "$HG/nr_hugepages")" "3072"
assert_eq "supported machine writes no degraded marker" "$(cat "$HG/marker" 2>/dev/null || echo absent)" "absent"
assert_eq "supported machine says nothing" "$out" ""

# doctor reads the marker as a WARN — never FAIL, so the A/B commit gate (which takes doctor's
# exit code) still commits a degraded-but-serving box. The words on line one are for the human;
# the pages= record under them is for the writers, and doctor must not leak it.
printf 'This machine has 7.7 GiB of RAM - below the supported 16 GB. Reduced reservation.\npages=2560\n' >"$HG/marker"
out=$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" check_hugepages_degraded 2>&1)
assert_contains "doctor surfaces the degraded-hugepages message as a WARN" "$out" "WARN"
assert_contains "doctor repeats the boot-time message verbatim" "$out" "below the supported 16 GB"
assert_not_contains "doctor never FAILs on the degrade (commit gate must still pass)" "$out" "FAIL"
assert_not_contains "doctor repeats the words, not the machine record" "$out" "pages=2560"
rc=$(
    PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" check_hugepages_degraded >/dev/null 2>&1
    echo $?
)
assert_rc "no marker, no verdict (rc 0, silent off the appliance)" "$rc" "0"

# The decision reader (hugepages_decision_pages) can only ever LOWER the budget: a corrupt
# record at or above the full pool reads as the full pool, and no marker means the full budget
# — so DIY hosts and healthy appliances keep the exact pre-#977 behavior.
printf 'words\npages=9999\n' >"$HG/marker"
assert_eq "a record above the budget is capped at the budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"
assert_eq "no marker reads as the full budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"

echo "== unit: hugepages_boot_verdict — a bare boot can tell ran-and-no-op from never-ran (#1212) =="
# tests/os/run.sh's phase_boot cannot be driven from here (it needs a real KVM guest), but the
# verdict it now checks is pure text-matching over two already-observed strings
# (HugePages_Total, `systemctl is-active` output) — #1212 pulled it into
# tests/os/hugepages-boot-verdict.sh for exactly this reason: the discrimination the issue asked
# for is provable with fixtures, without a bench boot. The case that matters is the first pair
# below: the SAME HugePages_Total (3072 — the baked sysctl reserves it whether the unit ran or
# not) must verdict differently once the unit's own record disagrees.
# Mutation run: drop the is-active check and fall back to judging HugePages_Total alone -> the
# "never ran" assertion flips from fail to pass, silently reintroducing #1212.
hbv() { # <hugepages-total> <is-active-output> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/hugepages-boot-verdict.sh"
        hugepages_boot_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "ran + full pool: passes" \
    "$(hbv 3072 active)" "0 hugepages sizing unit ran this boot and left the full pool intact (3072 pages)"
assert_eq "never ran + the SAME full pool: fails — the #1212 case a pool-only check missed" \
    "$(hbv 3072 inactive)" "1 hugepages sizing unit did not run this boot (is-active: inactive) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the pool is short: fails" \
    "$(hbv 2560 active)" "1 hugepages sizing unit ran but the pool is short (HugePages_Total: 2560, want >= 3072)"
assert_eq "never ran + unreadable is-active: fails, names it unreadable" \
    "$(hbv "" "")" "1 hugepages sizing unit did not run this boot (is-active: unreadable) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the page count is garbage: fails cleanly, no arithmetic error" \
    "$(hbv banana active)" "1 hugepage pool unreadable at boot (HugePages_Total: banana, want >= 3072)"
unset -f hbv

echo "== unit: restore_live_state_verdict — a restore leaves proof it is RUNNING, not just unpacked (#1091) =="
# tests/os/run.sh's phase_install restore leg cannot be driven from here (it needs a real KVM
# guest, a genuine encrypted backup, and the wizard's HTTP upload path), but the verdict it now
# checks is pure text-matching over two already-observed strings (`podman ps` names, /api/state's
# live stratum wallet) — #1091 pulled it into tests/os/restore-live-state-verdict.sh for exactly
# that reason. The case that matters is the second pair below: `config.json` on disk (proven by a
# separate assertion in the battery) says nothing about whether the stack is actually RUNNING
# it — the verdict must fail that case even though the file landed.
# Mutation run: drop the live-wallet comparison and fall back to judging `podman ps` alone -> the
# "stack up but wallet never came back" and "stack up but wrong wallet" cases both flip from fail
# to pass, silently reintroducing #1091.
# The same fixture wallet tests/os/run.sh's battery uses (HARNESS_WALLET) — any well-formed
# address works here since the verdict only ever string-compares two values, never parses one.
RLV_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
rlv() { # <podman-ps-names> <live-wallet> <want-wallet> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/restore-live-state-verdict.sh"
        restore_live_state_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "stack up + live wallet matches: passes" \
    "$(rlv "dashboard caddy monerod" "$RLV_WALLET" "$RLV_WALLET")" \
    "0 the restored machine's LIVE state (p2pool's own running config) carries the restored wallet — not just the unpacked archive file"
assert_eq "stack never came up: fails — the #1091 case a file-only check missed" \
    "$(rlv "" "" "$RLV_WALLET")" \
    "1 the stack never came up on the restored machine (podman ps: 'none') — config.json on disk is not proof the machine is RUNNING what was restored (#1091)"
assert_eq "stack up but live wallet never came back: fails, names it unreadable" \
    "$(rlv "dashboard caddy" "" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'none')"
assert_eq "stack up but live wallet is a fresh/different address: fails — config.json alone would have missed this too" \
    "$(rlv "dashboard caddy" "44SomeFreshUnrelatedAddress" "$RLV_WALLET")" \
    "1 the stack is up but live state's wallet is '44SomeFreshUnrelatedAddress', not the restored '$RLV_WALLET' — the restore landed a file but the running stack does not reflect it (#1091)"
assert_eq "stack up but /api/state answered literal Unknown/null: still fails, not treated as a match" \
    "$(rlv "caddy dashboard" "Unknown" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'Unknown')"
unset -f rlv
unset RLV_WALLET

echo "== unit: reinstall_prefill_verdict — a wallet match alone cannot prove which path produced it (#1038) =="
# tests/os/run.sh's reinstall pre-fill check cannot be driven from here (it needs a real KVM
# guest reinstalled over an existing install), but the verdict it now checks is pure
# text-matching over three already-observed signals (the branch's own console log line, the
# wallet match, the password-leak check) — #1038 pulled it into
# tests/os/reinstall-prefill-verdict.sh for exactly that reason: the discrimination the issue
# asked for is provable with fixtures, without a bench boot. The case that matters is the first
# pair below: a wallet match with NO console record of the branch having run (the exact shape
# #1038 found passing for four consecutive batteries) must verdict as a failure.
# Mutation run: drop the branch_logged check and judge by the wallet match alone -> the
# "branch never logged" case flips from fail to pass, silently reintroducing #1038.
rpv() { # <branch-logged> <wallet-prefilled> <password-leaked> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/reinstall-prefill-verdict.sh"
        reinstall_prefill_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "branch ran, wallet matched, no password: passes" \
    "$(rpv 1 1 0)" "0 reinstall pre-fill ran this boot and published the previous install's non-secret answers (secrets left out)"
assert_eq "wallet matched but the branch never logged: fails — the #1038 case a wallet-only check missed" \
    "$(rpv 0 1 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "branch ran but the wallet never reached the page: fails" \
    "$(rpv 1 0 0)" "1 the pre-fill branch ran but the previous install's wallet never reached the page"
assert_eq "branch ran, wallet matched, but a password leaked: fails" \
    "$(rpv 1 1 1)" "1 a password crossed into the reinstall page's pre-filled state"
assert_eq "neither the branch nor the wallet: fails on the branch record first" \
    "$(rpv 0 0 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "empty inputs (unset shell vars): treated as not-logged, fails cleanly" \
    "$(rpv "" "" "")" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
unset -f rpv

echo "== unit: os/build-image.sh — --fresh-index flag parsing + the 404 remedy hint (#929) =="
# PITHEAD_BUILD_IMAGE_TEST makes the script return right after arg parsing (before docker), so
# these run its real argument handling and apt_fetch_failure_hint without a build.
build_image_test() {
    (
        export PITHEAD_BUILD_IMAGE_TEST=1
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh" "$@"
        [ "${FRESH_INDEX:-0}" = "1" ] && echo "FRESH_INDEX=1"
        declare -f apt_fetch_failure_hint >/dev/null && echo "HINT_FN_DEFINED"
    )
}
assert_contains "--fresh-index sets FRESH_INDEX" "$(build_image_test --fresh-index)" "FRESH_INDEX=1"
assert_not_contains "bare invocation leaves FRESH_INDEX unset" "$(build_image_test)" "FRESH_INDEX=1"
assert_contains "apt_fetch_failure_hint is defined after sourcing" "$(build_image_test)" "HINT_FN_DEFINED"

unknown_flag_out="$("$ROOT/os/build-image.sh" --bogus 2>&1 || true)"
assert_contains "unknown argument is rejected" "$unknown_flag_out" "unknown argument: --bogus"
assert_contains "unknown-argument error names --fresh-index" "$unknown_flag_out" "--fresh-index"

# --fresh-index composes with --ssh: parsed left-to-right, then --ssh's own missing-key check
# exits before docker, proving --fresh-index didn't swallow the next argument.
missing_key_out="$("$ROOT/os/build-image.sh" --fresh-index --ssh "$SANDBOX/no-such-key.pub" 2>&1 || true)"
assert_contains "--fresh-index then --ssh with a missing key still hits --ssh's own error" "$missing_key_out" "--ssh: no public key found"

# Exercise the hint function directly by sourcing the same way and calling it.
run_hint() {
    (
        local log="$1"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # `source file` with no args keeps the caller's $@ — clear it so build-image.sh's
        # own arg loop doesn't try to parse the log tail as a CLI flag.
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh"
        apt_fetch_failure_hint "$log" 2>&1
    )
}
assert_contains "404 signature triggers the --fresh-index remedy" "$(run_hint 'E: Failed to fetch ... 404  Not Found')" "--fresh-index"
assert_contains "'Unable to fetch' signature triggers the remedy" "$(run_hint 'E: Unable to fetch some archives, maybe run apt-get update')" "--fresh-index"
assert_eq "an unrelated failure prints no hint" "$(run_hint 'E: some other build error')" ""

echo "== unit: pithead-ssh-host-keys — per-machine host key on /data, generated once (#894/#980) =="
# Real ssh-keygen against a sandboxed key dir (PITHEAD_SSH_HOST_KEYS_DIR — the same env-seam
# shape pithead-machine-id carries). chown is PATH-stubbed: the suite is not root, and ownership
# on the box is systemd's root context, not logic this tier can prove. stdin is /dev/null on
# every run — the systemd condition the wedge-recovery case below depends on.
SHK="$SANDBOX/ssh-host-keys"
mkdir -p "$SHK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHK/bin/chown"
chmod +x "$SHK/bin/chown"
shk_key="$SHK/data-ssh/ssh_host_ed25519_key"
shk_run() {
    (
        export PATH="$SHK/bin:$PATH" PITHEAD_SSH_HOST_KEYS_DIR="$SHK/data-ssh"
        sh "$ROOT/os/overlay/pithead-ssh-host-keys" </dev/null 2>&1
    )
}
out=$(shk_run)
assert_rc "first run on an empty /data generates the key" "$?" "0"
assert_contains "generation is announced (a silent identity change is the bug class)" "$out" "generated a new host key"
shk_fp1=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp1" ] && ok "the generated key is a loadable ed25519 key ($shk_fp1)" ||
    bad "the generated key is a loadable ed25519 key" "ssh-keygen -lf failed on $shk_key"
assert_eq "key dir is owner-only (700)" "$(stat -c '%a' "$SHK/data-ssh" 2>/dev/null || stat -f '%Lp' "$SHK/data-ssh")" "700"
assert_eq "private key is owner-only (600)" "$(stat -c '%a' "$shk_key" 2>/dev/null || stat -f '%Lp' "$shk_key")" "600"
assert_eq "public key is world-readable (644)" "$(stat -c '%a' "$shk_key.pub" 2>/dev/null || stat -f '%Lp' "$shk_key.pub")" "644"
# Idempotence IS the identity contract (#894): a second start must find the key and change
# NOTHING — a regeneration here is exactly the host-key churn an A/B update must never cause.
out=$(shk_run)
assert_rc "second run exits 0" "$?" "0"
assert_not_contains "second run regenerates nothing" "$out" "generated"
assert_eq "second run leaves the key byte-identical" "$(ssh-keygen -lf "$shk_key" | awk '{print $2}')" "$shk_fp1"
# Wedge recovery: an interrupted prior run leaves an empty key file (+ stale .pub). ssh-keygen
# prompts before overwriting an existing path, and with stdin on /dev/null that prompt reads EOF
# and refuses — the script must clear the partial file first or sshd wedges forever.
: >"$shk_key"
out=$(shk_run)
assert_rc "a stale empty key file is regenerated, not wedged on the overwrite prompt" "$?" "0"
shk_fp2=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp2" ] && ok "recovery produced a loadable key again" ||
    bad "recovery produced a loadable key again" "ssh-keygen -lf failed on $shk_key"

echo "== unit: pithead-mount-generator — /data + ESP follow the BOOTED disk, never a label (#926/#980) =="
# The generator against staged mountinfo files (PITHEAD_MOUNTINFO seam; GENDIR is already an
# argument). The staged lines keep the real shape — surrounding mounts, optional fields before
# the "-" separator — so the awk root-line/source extraction runs against what a kernel writes.
MG="$SANDBOX/mount-generator"
mkdir -p "$MG"
mg_run() { # $1 mountinfo file, $2 gendir
    (
        export PITHEAD_MOUNTINFO="$1"
        sh "$ROOT/os/overlay/pithead-mount-generator" "$2"
    )
}
cat >"$MG/mi-sda" <<'EOF'
24 30 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:5 - proc proc rw
29 1 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw,stripe=32
32 29 8:4 / /data rw,noatime shared:2 - ext4 /dev/sda4 rw
EOF
mg_run "$MG/mi-sda" "$MG/gen-sda"
assert_rc "generator succeeds on a /dev/sda2 root" "$?" "0"
mg_data=$(cat "$MG/gen-sda/data.mount" 2>/dev/null)
mg_esp=$(cat "$MG/gen-sda/boot-efi.mount" 2>/dev/null)
assert_contains "data.mount is partition 4 OF THE BOOT DISK" "$mg_data" "What=/dev/sda4"
assert_contains "data.mount mounts /data" "$mg_data" "Where=/data"
assert_contains "data.mount is ext4" "$mg_data" "Type=ext4"
assert_not_contains "data.mount never mounts by label" "$mg_data" "LABEL"
assert_contains "boot-efi.mount is partition 1 of the boot disk" "$mg_esp" "What=/dev/sda1"
assert_contains "boot-efi.mount mounts /boot/efi" "$mg_esp" "Where=/boot/efi"
assert_contains "the ESP mount is root-only (RAUC boot state lives there)" "$mg_esp" "Options=umask=0077"
assert_contains "the data mount orders before local-fs.target" "$mg_data" "Before=local-fs.target"
for u in data.mount boot-efi.mount; do
    if [ "$(readlink "$MG/gen-sda/local-fs.target.requires/$u")" = "../$u" ]; then
        ok "$u is required by local-fs.target (the boot waits for it)"
    else
        bad "$u is required by local-fs.target" "missing or wrong symlink"
    fi
done
# nvme/mmc naming: the partition number strips AND the 'p' separator comes back on the
# partition paths (nvme0n1p2 -> disk nvme0n1 -> partitions nvme0n1p4 / nvme0n1p1).
printf '29 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw\n' >"$MG/mi-nvme"
mg_run "$MG/mi-nvme" "$MG/gen-nvme"
assert_contains "an nvme root keeps the p separator: data" "$(cat "$MG/gen-nvme/data.mount")" "What=/dev/nvme0n1p4"
assert_contains "an nvme root keeps the p separator: ESP" "$(cat "$MG/gen-nvme/boot-efi.mount")" "What=/dev/nvme0n1p1"
# A root line with NO optional fields (the "-" comes right after the options) still parses —
# and vda-style names get no separator (vda2 -> vda4).
printf '29 1 254:2 / / rw,relatime - ext4 /dev/vda2 rw\n' >"$MG/mi-vda"
mg_run "$MG/mi-vda" "$MG/gen-vda"
assert_contains "a no-optional-fields root line parses (vda2 -> vda4)" "$(cat "$MG/gen-vda/data.mount")" "What=/dev/vda4"
# A container/unexpected root (source is not /dev/*) generates NOTHING rather than guessing.
printf '29 1 0:35 / / rw,relatime - overlay overlay rw\n' >"$MG/mi-ovl"
mg_run "$MG/mi-ovl" "$MG/gen-ovl"
assert_rc "a non-/dev root exits 0 (a generator must not fail the boot)" "$?" "0"
assert_eq "a non-/dev root generates no units" "$([ -e "$MG/gen-ovl" ] || echo none)" "none"
