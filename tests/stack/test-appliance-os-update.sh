# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance os-update domain (#1105 Phase 1, appliance lane): the host side of an A/B OS update —
# the consent gate that decides whether an install may proceed at all, and the reporting layer that
# turns rauc's own output into something an operator can act on. Five sections. The variant gate
# covers SSH-posture flips in EITHER direction, because both are dangerous for opposite reasons: a
# release bundle onto a debug box removes the key that may be the only management channel, and a
# debug bundle onto a hardened release box bakes in a standing root authorized_keys (#854) — either
# flip, and any bundle whose stamp cannot be verified, must confirm, while a same-variant install
# must not. The rest is #1041's honesty work: os_bundle_meta degrading to empty instead of aborting
# its caller, os-update surfacing rauc's own diagnosis rather than a bare abort, and surfacing
# rauc install's real stderr rather than a generic failure — plus os_bundle_meta pinned against
# REAL `rauc info` output rather than a hand-written stand-in (#1093), so the parser is proven
# against the format it will actually meet.
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping. That is also why the two coupling rules
# cannot bite here: nothing moves relative to any consumer.
#
# Re-derivations: none. From outside the file the block reads $SANDBOX, $STACK and $ROOT, and the
# run_sourced, ok, bad, assert_eq, assert_rc, assert_contains and assert_not_contains helpers — all
# of them from lib.sh, which run.sh sources near its top. $STACK is only ever read: either sourced
# inside a subshell or copied into the sandbox. run_sourced itself is a subshell that cd's into the
# directory it is given and sources the stack there, so it cannot leak shell state back.
# Every other name is assigned here — $OUSB and $OUB and the fixture trees beneath them,
# $RAUC_LOG, the RAUC_INFO_*/RAUC_INSTALL_* stub knobs, $MARKER_FILE, $RIS/$RIJ/$FWR,
# $mig_manifest/$plain_manifest, $ombm_out/$ombm_rc, and the ourun, ourun_v,
# ourun_v_realfixture, ometa, omh and rmeta helpers. The block unsets them as it goes — each at
# the end of the section that used it, rather than all together at the close.
# As elsewhere in this suite a few generic scratch names ($out, $rc, $FN, $FW, $MK) are left set;
# they were before the move too, and the stanza runs at the block's former position, so grouping
# changes nothing about that.

echo "== unit: os-update variant gate — SSH posture flips in EITHER direction need consent =="
# The trap this guards, both ways: a debug image's SSH key is often the only management channel and
# a release bundle removes it BY DESIGN (losing a shell); a debug bundle onto a hardened release box
# bakes a standing root authorized_keys + sshd (GAINING a shell, #854). Either flip, and any bundle
# whose stamp can't be verified, must confirm; a same-variant install must not.
# Losing the shell (a KNOWN debug box installing something non-debug):
run_sourced "$SANDBOX" os_update_needs_confirmation debug release
assert_rc "debug system + release bundle -> confirmation required" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation debug unknown
assert_rc "debug system + unstamped bundle -> confirmation required" "$?" "0"
# Gaining a shell (a non-debug box installing a debug bundle) — the #854 direction:
run_sourced "$SANDBOX" os_update_needs_confirmation release debug
assert_rc "release system + debug bundle -> confirmation required (gains root SSH)" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown debug
assert_rc "unstamped system + debug bundle -> confirmation required (gains root SSH)" "$?" "0"
# Unverified bundle onto a non-debug box: the stamp could hide a debug build, so confirm.
run_sourced "$SANDBOX" os_update_needs_confirmation release unknown
assert_rc "release system + unstamped bundle -> confirmation required (posture unverifiable)" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown unknown
assert_rc "unstamped system + unstamped bundle -> confirmation required (posture unverifiable)" "$?" "0"
# Same-posture installs pass without ceremony:
run_sourced "$SANDBOX" os_update_needs_confirmation debug debug
assert_rc "debug -> debug passes without ceremony" "$?" "1"
run_sourced "$SANDBOX" os_update_needs_confirmation release release
assert_rc "release -> release passes (the fleet's normal update)" "$?" "1"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown release
assert_rc "unstamped system + release bundle passes — stays shell-less, no channel flips" "$?" "1"

mk_tmpdir OUSB
mkdir -p "$OUSB/bin"
# A fake rauc: logs every call, answers `info` with a canned shell-format body —
# the format the real os_bundle_meta parses (RAUC 1.11's JSON output omits [meta.*]). Two escape
# hatches for #1041's error-surfacing tests: RAUC_INFO_RC/RAUC_INFO_ERR fail `info` (a signature
# verdict) with a chosen message on stderr, RAUC_INSTALL_RC/RAUC_INSTALL_ERR do the same for
# `install`. Both default to a clean 0/no-output — every test above this one never sets them.
#
# RAUC_INFO_OUT_JSON (#1093): most callers below never set this, so `info` behaves exactly as
# before — cat RAUC_INFO_OUT regardless of the `--output-format` the caller actually passed,
# which is precisely the gap #1093 named: a caller that regressed to --output-format=json would
# still get the hand-written shell-format fixture back, so the drift could never turn any
# assertion red. The migration-floor real-fixture block below sets RAUC_INFO_OUT_JSON so `info`
# answers format-honestly: shell gets RAUC_INFO_OUT, json gets RAUC_INFO_OUT_JSON — two REAL
# `rauc info` captures of the same bundle (tests/stack/fixtures/rauc-info/), not two hand-written
# stand-ins that already agree with the parser by construction.
cat >"$OUSB/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    fmt=shell
    for _a in "$@"; do case "$_a" in --output-format=*) fmt="${_a#--output-format=}" ;; esac; done
    if [ -n "${RAUC_INFO_OUT_JSON:-}" ] && [ "$fmt" = json ]; then
        [ -s "$RAUC_INFO_OUT_JSON" ] && cat "$RAUC_INFO_OUT_JSON"
    else
        [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    fi
    [ -n "${RAUC_INFO_ERR:-}" ] && echo "$RAUC_INFO_ERR" >&2
    exit "${RAUC_INFO_RC:-0}"
    ;;
install)
    [ -n "${RAUC_INSTALL_ERR:-}" ] && echo "$RAUC_INSTALL_ERR" >&2
    exit "${RAUC_INSTALL_RC:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$OUSB/bin/rauc"
touch "$OUSB/bundle.raucb"
export RAUC_LOG="$OUSB/calls"

printf 'debug\n' >"$OUSB/variant-debug"
printf 'release\n' >"$OUSB/variant-release"
printf 'mystery\n' >"$OUSB/variant-garbage"
assert_eq "running variant read from the stamp file" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/variant-debug run_sourced "$SANDBOX" os_running_variant)" "debug"
assert_eq "a garbage stamp degrades to unknown, never to a variant" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/variant-garbage run_sourced "$SANDBOX" os_running_variant)" "unknown"
assert_eq "a missing stamp file is unknown (pre-stamp images)" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/nope run_sourced "$SANDBOX" os_running_variant)" "unknown"

ourun() { # <variant-file> <info-json-file or empty> [os-update args...] — stdin closed (no tty)
    local vf="$1" ij="$2"
    shift 2
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        RAUC_INFO_OUT="$ij" PITHEAD_VARIANT_FILE="$vf" \
            PITHEAD_MIGRATION_MARKER_FILE="$OUSB/marker-scratch" os_update "$@" </dev/null
    )
}
printf "RAUC_META_PITHEAD_VARIANT='release'\n" >"$OUSB/info-release.txt"
printf "RAUC_META_PITHEAD_VARIANT='debug'\n" >"$OUSB/info-debug.txt"
assert_eq "bundle variant parsed from rauc info shell output" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$OUSB/info-release.txt" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "release"
assert_eq "bundle variant parse reads the debug stamp" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$OUSB/info-debug.txt" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "debug"
assert_eq "an unstamped bundle is unknown" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "unknown"

# The command end to end, with the daemon stubbed. Non-interactive stdin means the prompt reads
# EOF -> cancelled: precisely the automation case where a silent install would strand the box.
: >"$RAUC_LOG"
out=$(ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" bundle.raucb 2>&1)
rc=$?
assert_rc "debug box + release bundle, no --yes -> refused" "$rc" "1"
assert_contains "the refusal names the SSH loss" "$out" "removes SSH"
assert_not_contains "rauc install was NOT reached" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" bundle.raucb --yes >/dev/null 2>&1
assert_rc "--yes acknowledges the warning and proceeds" "$?" "0"
assert_contains "rauc install ran with the bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# The #854 direction: a hardened release box taking a debug bundle GAINS a root SSH backdoor. Non-
# interactive stdin reads EOF -> refused, and rauc install must never be reached — the silent
# install is exactly the backdoor this guards.
: >"$RAUC_LOG"
out=$(ourun "$OUSB/variant-release" "$OUSB/info-debug.txt" bundle.raucb 2>&1)
rc=$?
assert_rc "release box + debug bundle, no --yes -> refused" "$rc" "1"
assert_contains "the refusal names the root SSH it would gain" "$out" "root SSH"
assert_not_contains "rauc install was NOT reached on the gain-a-shell refusal" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun "$OUSB/variant-release" "$OUSB/info-debug.txt" bundle.raucb --yes >/dev/null 2>&1
assert_rc "--yes acknowledges the backdoor warning and proceeds" "$?" "0"
assert_contains "rauc install ran with the debug bundle after --yes" "$(cat "$RAUC_LOG")" "install bundle.raucb"
: >"$RAUC_LOG"
ourun "$OUSB/variant-release" "$OUSB/info-release.txt" bundle.raucb >/dev/null 2>&1
assert_rc "release -> release installs with no prompt" "$?" "0"
assert_contains "rauc install ran unprompted" "$(cat "$RAUC_LOG")" "install bundle.raucb"
out=$(ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" 2>&1)
assert_rc "a missing bundle path is an error, not an install" "$?" "1"

echo "== unit: os_bundle_meta degrades to empty instead of aborting the caller (#1041) =="
# run_sourced (used everywhere above) disables errexit right after sourcing, which would hide
# the exact bug #1041 traces to: under `set -o pipefail`, `rauc info | sed | head` returns rauc's
# own nonzero exit even though sed/head both succeed, and a bare `var=$(os_bundle_meta ...)`
# assignment then trips `set -e` — silently, since the diagnostic went to `2>/dev/null`. This
# check keeps errexit ON (the real pithead script's own posture) so a regression here reproduces
# the actual failure: the subshell would abort before ever reaching the second echo.
: >"$RAUC_LOG"
ombm_out=$(
    cd "$OUSB" || exit 1
    PATH="$OUSB/bin:$PATH"
    export RAUC_INFO_RC=1 RAUC_INFO_OUT="" RAUC_INFO_ERR="signature verification failed: self-signed certificate"
    # shellcheck disable=SC1090
    source "$STACK"
    echo "before"
    v=$(os_bundle_meta bundle.raucb version)
    echo "after:[$v]"
)
ombm_rc=$?
assert_rc "a failing rauc info does not abort the caller under errexit+pipefail" "$ombm_rc" "0"
assert_contains "execution continues past the failed call" "$ombm_out" "after:[]"

echo "== integration: os-update surfaces rauc's own diagnosis instead of a bare abort (#1041) =="
# The bug as filed: a signature failure inside a command substitution (os_bundle_meta, above)
# tripped the ERR trap with nothing to show for it — three bare "aborted unexpectedly" lines and
# no clue rauc had already diagnosed it precisely on its own stderr. Runs the REAL script as a
# subprocess (not sourced) so the ERR trap this bug lives in is actually armed.
mk_tmpdir OUB
mkdir -p "$OUB/bin"
cp "$STACK" "$OUB/pithead"
chmod +x "$OUB/pithead"
cp "$OUSB/bin/rauc" "$OUB/bin/rauc"
chmod +x "$OUB/bin/rauc"
touch "$OUB/bundle.raucb"
: >"$OUB/calls"
out=$(cd "$OUB" && PATH="$OUB/bin:$PATH" RAUC_LOG="$OUB/calls" \
    RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error: self-signed certificate" \
    ./pithead os-update bundle.raucb --yes 2>&1)
rc=$?
assert_rc "a bad-signature bundle refuses the update" "$rc" "1"
assert_contains "rauc's own diagnosis reaches the operator" "$out" "self-signed certificate"
assert_not_contains "the generic contentless abort does not ALSO fire" "$out" "aborted unexpectedly"
assert_not_contains "rauc install is never reached on a bad signature" "$(cat "$OUB/calls")" "install"
rm -rf "$OUB"

echo "== unit: os-update surfaces rauc install's own stderr, not just a bare failure (#1041) =="
: >"$RAUC_LOG"
out=$(
    cd "$OUSB" || exit 1
    PATH="$OUSB/bin:$PATH"
    export RAUC_INFO_OUT="$OUSB/info-release.txt" PITHEAD_VARIANT_FILE="$OUSB/variant-release"
    export PITHEAD_MIGRATION_MARKER_FILE="$OUSB/marker-scratch"
    export RAUC_INSTALL_RC=1 RAUC_INSTALL_ERR="LastError: mounting slot failed: no such device"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    os_update bundle.raucb --yes </dev/null 2>&1
)
rc=$?
assert_rc "an install-time rauc failure is refused, not silently ignored" "$rc" "1"
assert_contains "rauc's install-time diagnosis reaches the operator" "$out" "mounting slot failed"
unset RAUC_INFO_RC RAUC_INFO_ERR RAUC_INSTALL_RC RAUC_INSTALL_ERR

# --- os-update version floor + data-migration guards (#856 downgrade, #851 migration deadlock) ---
# A correctly-signed bundle is not automatically a safe one: an OLDER image re-opens fixed holes,
# and an image below the /data migration floor cannot read the chain data a newer release migrated.
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-1170.txt"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.10.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-1100.txt"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='true'\nRAUC_META_PITHEAD_MINIMUM_OS_VERSION='1.17.0'\n" >"$OUSB/info-mig.txt"

# os_bundle_meta: the manifest fields read back out of `rauc info` JSON.
ometa() { cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$1" run_sourced "$OUSB" os_bundle_meta bundle.raucb "$2"; }
# render_bundle_manifest: the WRITE side of the manifest (the read side is os_bundle_meta below).
# RAUC refuses a key with an empty value, so an ordinary non-migrating build must omit the floor
# entirely — emitting `minimum_os_version=` unconditionally broke every plain bundle build, and
# the stubbed rauc in these tests never saw it. Assert the rendered text directly.
plain_manifest="$(cd "$ROOT" && . os/rauc/populate-slot.sh && render_bundle_manifest 1.17.0 release false "")"
assert_not_contains "plain build omits the migration floor entirely (no empty-valued key)" \
    "$plain_manifest" "minimum_os_version"
assert_contains "plain build still carries the version" "$plain_manifest" "version=1.17.0"
assert_contains "plain build still carries the variant" "$plain_manifest" "variant=release"
assert_contains "plain build declares no migration" "$plain_manifest" "data_migration=false"
mig_manifest="$(cd "$ROOT" && . os/rauc/populate-slot.sh && render_bundle_manifest 1.18.0 release true 1.18.0)"
assert_contains "a migrating build names its floor" "$mig_manifest" "minimum_os_version=1.18.0"
# No key may ever render with an empty value — that is the exact shape rauc rejects.
if grep -qE '^[a-z_]+=$' <(printf '%s\n' "$plain_manifest" "$mig_manifest"); then
    bad "no manifest key renders with an empty value" "found one"
else
    ok "no manifest key renders with an empty value"
fi

assert_eq "os_bundle_meta reads version" "$(ometa "$OUSB/info-mig.txt" version)" "1.17.0"
assert_eq "os_bundle_meta reads data_migration" "$(ometa "$OUSB/info-mig.txt" data_migration)" "true"
assert_eq "os_bundle_meta reads minimum_os_version" "$(ometa "$OUSB/info-mig.txt" minimum_os_version)" "1.17.0"
assert_eq "an absent meta key is empty, not an error" "$(ometa "$OUSB/info-mig.txt" db_schema)" ""
unset -f ometa

# ourun_v: os_update with a set running version + a data-floor file, variant pinned to release
# (the SSH gate is covered above; here we isolate the version/floor guards).
ourun_v() { # <running-version> <floor-file> <info-json> [os-update args...]
    local rv="$1" ff="$2" ij="$3"
    shift 3
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_VERSION="$rv" PITHEAD_DATA_FLOOR_FILE="$ff" \
            PITHEAD_MIGRATION_MARKER_FILE="${MARKER_FILE:-$OUSB/marker-scratch}" \
            RAUC_INFO_OUT="$ij" PITHEAD_VARIANT_FILE="$OUSB/variant-release" os_update "$@" </dev/null
    )
}

# #856: an older bundle is refused, and rauc install is never reached.
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "" "$OUSB/info-1100.txt" bundle.raucb 2>&1)
assert_rc "a bundle older than running is refused" "$?" "1"
assert_contains "the refusal names the downgrade" "$out" "possible downgrade"
assert_not_contains "rauc install was NOT reached on a refused downgrade" "$(cat "$RAUC_LOG")" "install"
# ...unless --allow-downgrade is passed on purpose.
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-1100.txt" bundle.raucb --allow-downgrade >/dev/null 2>&1
assert_rc "--allow-downgrade installs the older bundle" "$?" "0"
assert_contains "rauc install ran under --allow-downgrade" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# A newer bundle installs with no ceremony.
: >"$RAUC_LOG"
ourun_v "1.10.0" "" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a newer bundle installs" "$?" "0"
assert_contains "rauc install ran for the newer bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# The CLI door keeps same-version installs — manual slot repair at the machine is its job.
# The dashboard door refuses equality (covered in the control os-* block below).
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a same-version bundle installs at the CLI (slot repair)" "$?" "0"
assert_contains "rauc install ran for the same-version bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"

# #851: below the /data migration floor is refused OUTRIGHT — --allow-downgrade does not override it.
printf '2.0.0\n' >"$OUSB/floor-2"
: >"$RAUC_LOG"
out=$(ourun_v "2.1.0" "$OUSB/floor-2" "$OUSB/info-1170.txt" bundle.raucb --allow-downgrade 2>&1)
assert_rc "a bundle below the /data floor is refused even with --allow-downgrade" "$?" "1"
assert_contains "the floor refusal warns about the chain data" "$out" "strand the chain data"
assert_not_contains "rauc install was NOT reached below the floor" "$(cat "$RAUC_LOG")" "install"
# A bundle at or above the floor installs.
printf '1.17.0\n' >"$OUSB/floor-at"
: >"$RAUC_LOG"
ourun_v "1.17.0" "$OUSB/floor-at" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a bundle at the /data floor installs" "$?" "0"

# #851: installing a data_migration bundle RECORDS the floor; a plain bundle does not.
FW="$OUSB/floor-written"
rm -f "$FW"
: >"$RAUC_LOG"
ourun_v "1.17.0" "$FW" "$OUSB/info-mig.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a data_migration bundle installs" "$?" "0"
assert_eq "installing a data_migration bundle records the /data floor" "$(tr -d ' \n' <"$FW" 2>/dev/null)" "1.17.0"
FN="$OUSB/floor-none"
rm -f "$FN"
ourun_v "1.10.0" "$FN" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a non-migration bundle records no floor" "$([ -f "$FN" ] && echo present || echo absent)" "absent"

echo "== unit: os_bundle_meta pinned against REAL rauc info output, not a hand-written stand-in (#1093) =="
# Every info-*.txt fixture above is hand-typed RAUC_META_PITHEAD_KEY='value' text, invented to
# already match the sed pattern it feeds — it can never catch a real parse drift. #1093: RAUC
# 1.11's --output-format=json OMITS [meta.*] entirely (the drift os_bundle_meta's comment already
# names), and the fake rauc's `info` case never looked at --output-format at all, so a caller that
# regressed to json would still get the shell-format fixture back — invisible to every assertion
# above. tests/stack/fixtures/rauc-info/*.txt are genuine `rauc info` captures off a bundle built
# from the real render_bundle_manifest (see capture.sh for the recipe and refresh instructions),
# and the fake rauc now answers format-honestly (RAUC_INFO_OUT for shell, RAUC_INFO_OUT_JSON for
# json) — so this block proves the parse against real tool output, both shapes.
RIS="$ROOT/tests/stack/fixtures/rauc-info/rauc-info-migration.shell.txt"
RIJ="$ROOT/tests/stack/fixtures/rauc-info/rauc-info-migration.json.txt"
if [ -s "$RIS" ] && [ -s "$RIJ" ]; then
    ok "real rauc-info fixtures present ($RIS, $RIJ)"
else
    bad "real rauc-info fixtures present" "missing $RIS or $RIJ"
fi

rmeta() { # <key> — both real fixtures loaded together, so the format os_bundle_meta's own argv
    # actually requests decides which one the fake rauc serves. A caller that regressed from
    # --output-format=shell to json would silently start reading the json capture here instead —
    # empty meta, not the pinned value — which is exactly the drift this block exists to catch.
    cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$RIS" RAUC_INFO_OUT_JSON="$RIJ" \
        run_sourced "$OUSB" os_bundle_meta bundle.raucb "$1"
}
assert_eq "real bundle: os_bundle_meta reads variant off genuine shell output" \
    "$(rmeta variant)" "release"
assert_eq "real bundle: os_bundle_meta reads data_migration off genuine shell output" \
    "$(rmeta data_migration)" "true"
assert_eq "real bundle: os_bundle_meta reads minimum_os_version off genuine shell output" \
    "$(rmeta minimum_os_version)" "1.18.0"
# The drift itself, in isolation: pointed at ONLY the real json capture (RAUC 1.11's own shape —
# [meta.*] entirely absent), the parse must degrade to empty — fail-closed "unstamped", never a
# wrong-but-plausible value — regardless of which format asked for it.
assert_eq "the real json capture alone has no meta section to read" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$RIJ" RAUC_INFO_OUT_JSON="" \
        run_sourced "$OUSB" os_bundle_meta bundle.raucb minimum_os_version)" ""
unset -f rmeta

# os_raise_data_floor, driven end to end by the REAL fixture through os_update: a migrating bundle
# whose meta the genuine shell-format capture carries must record the floor at the value the real
# bundle actually declares (1.18.0), not a hand-typed stand-in.
ourun_v_realfixture() { # <running-version> <floor-file> <shell-fixture> <json-fixture> [os-update args...]
    local rv="$1" ff="$2" ijs="$3" ijj="$4"
    shift 4
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_VERSION="$rv" PITHEAD_DATA_FLOOR_FILE="$ff" \
            PITHEAD_MIGRATION_MARKER_FILE="${MARKER_FILE:-$OUSB/marker-scratch}" \
            RAUC_INFO_OUT="$ijs" RAUC_INFO_OUT_JSON="$ijj" \
            PITHEAD_VARIANT_FILE="$OUSB/variant-release" os_update "$@" </dev/null
    )
}
FWR="$OUSB/floor-written-real"
rm -f "$FWR"
: >"$RAUC_LOG"
ourun_v_realfixture "1.10.0" "$FWR" "$RIS" "$RIJ" bundle.raucb >/dev/null 2>&1
assert_rc "the real migrating bundle installs" "$?" "0"
assert_eq "the real bundle's own declared floor is recorded, not a stand-in value" \
    "$(tr -d ' \n' <"$FWR" 2>/dev/null)" "1.18.0"
unset -f ourun_v_realfixture
unset RIS RIJ FWR

# #851 marker lifecycle: a migrating install leaves the pending marker (stamped with the bundle's
# version) for the next boot's chain hold; a non-migrating install clears a stale one — it
# supersedes a migrating install that never booted.
MK="$OUSB/marker-mig"
rm -f "$MK"
MARKER_FILE="$MK" ourun_v "1.10.0" "$OUSB/floor-scratch" "$OUSB/info-mig.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a data_migration install writes the pending marker with the bundle version" "$(tr -d ' \n' <"$MK" 2>/dev/null)" "1.17.0"
MARKER_FILE="$MK" ourun_v "1.10.0" "$OUSB/floor-scratch" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a non-migrating install clears a stale pending marker" "$([ -f "$MK" ] && echo present || echo absent)" "absent"

# The hold query the boot path and doctor share: active only when the marker matches the RUNNING
# version — a mismatched marker is a fallback boot onto untouched data and must not hold anything.
omh() { # <marker-content-or-ABSENT> <running-version>
    local mf="$OUSB/marker-q"
    rm -f "$mf"
    [ "$1" != "ABSENT" ] && printf '%s\n' "$1" >"$mf"
    (
        cd "$OUSB" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_MIGRATION_MARKER_FILE="$mf" PITHEAD_VERSION="$2" os_migration_hold_active
    )
}
omh "1.17.0" "1.17.0"
assert_rc "hold active: marker matches the running version" "$?" "0"
omh "1.17.0" "1.16.0"
assert_rc "no hold: marker for another version (fallback boot)" "$?" "1"
omh "ABSENT" "1.17.0"
assert_rc "no hold: no marker" "$?" "1"
omh "" "1.17.0"
assert_rc "no hold: empty marker is not a version match" "$?" "1"
unset -f omh

# Fail-closed: a version the comparator can't parse is NOT proof of safety. Releases DO use -prep
# tags, so a pre-release bundle must not silently bypass the downgrade guard by parsing as "0".
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0-prep'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-prep.txt"
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "" "$OUSB/info-prep.txt" bundle.raucb 2>&1)
assert_rc "a pre-release (-prep) bundle is refused fail-closed" "$?" "1"
assert_contains "the refusal names it a possible downgrade" "$out" "possible downgrade"
assert_not_contains "rauc install was NOT reached for the pre-release bundle" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-prep.txt" bundle.raucb --allow-downgrade >/dev/null 2>&1
assert_rc "--allow-downgrade installs the pre-release bundle on purpose" "$?" "0"
assert_contains "rauc install ran for the pre-release under --allow-downgrade" "$(cat "$RAUC_LOG")" "install bundle.raucb"

# Fail-closed: a corrupt floor file is NOT permission to downgrade past a migration.
printf 'not-a-version\n' >"$OUSB/floor-corrupt"
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "$OUSB/floor-corrupt" "$OUSB/info-1170.txt" bundle.raucb --allow-downgrade 2>&1)
assert_rc "a corrupt /data floor is refused fail-closed, even with --allow-downgrade" "$?" "1"
assert_contains "the corrupt-floor refusal says the floor is unreadable" "$out" "floor is unreadable"
assert_not_contains "rauc install was NOT reached with a corrupt floor" "$(cat "$RAUC_LOG")" "install"
unset -f ourun_v

unset RAUC_LOG
unset -f ourun
rm -rf "$OUSB"
unset OUSB
