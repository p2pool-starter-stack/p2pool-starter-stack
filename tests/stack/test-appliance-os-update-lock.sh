# shellcheck shell=bash
#
# OS-update lock contention (#1482): the appliance's `os-install` verb takes the mutation lock, so
# an install that arrives while another pithead operation holds the machine must come back as
# `rejected` — never as a `failed` install. The distinction is the whole point: "failed" tells an
# operator the install ran and broke, when in fact `rauc install` was never reached and the staged
# bundle is still there to retry. Two sections: a positive control that the fixture arms and an
# uncontended install really does succeed, then the contended case itself.
# Sourced by tests/stack/run.sh.
#
# This lives beside test-appliance-os-update-verbs.sh rather than inside it because that file sits
# at its recorded budget ceiling with zero headroom, and ceilings only go down.
#
# Re-derivations: $SANDBOX, $STACK and the assert_* helpers come from lib.sh; every other name is
# assigned here. Both files are sourced into ONE shell by run.sh, so nothing here reuses a name the
# verbs file defines — its $OSC/$OSDIR/$OSRES/$UOS and osrun/os_intent/os_reset are deliberately
# untouched, and this file's are $OSL/$OSLDIR/$OSLRES/$ULOCK and oslrun/osl_intent. Every write
# lands under $OSL ($SANDBOX/os-lock): nothing touches $V, $C or the ambient $STACK sandbox, and
# nothing outside this file reads what it creates.

: "${SANDBOX:?}"
: "${STACK:?}"

echo "== black-box: an os-install blocked by another pithead operation is rejected, not failed (#1482) =="
# A release-shaped appliance sandbox with the toolchain stubbed, so the whole check -> download ->
# verify -> install chain runs for real with no network, no RAUC and no root.
OSL="$SANDBOX/os-lock"
OSLREQS="$OSL/data/control/requests"
OSLRES="$OSL/data/control/results"
OSLSTATE="$OSLRES/os-update-state.json"
OSLDIR="$OSL/osdir"
mkdir -p "$OSLREQS" "$OSLRES" "$OSL/data/control/staged" "$OSL/data/control/audit" "$OSLDIR"
cp "$STACK" "$OSL/pithead"
make_stubs "$OSL/bin"
printf '1.3.1' >"$OSL/VERSION"
printf '{}' >"$OSL/config.json"
cat >"$OSL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$OSL/data/control
NETWORK_PREFIX=10.9.0
EOF
printf 'release\n' >"$OSL/variant-release"
printf 'compatible=pithead-os\n' >"$OSL/system.conf"
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-v9.9.9.raucb","size":1000}]}' >"$OSL/api.json"
yes x | head -c 1000 >"$OSL/fixture.raucb"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSL/info-good.txt"
cat >"$OSL/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    exit 0
    ;;
install)
    echo "installing bundle: 100%"
    exit 0
    ;;
esac
exit 0
EOF
cat >"$OSL/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n200'
    ;;
*releases/download/*)
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    tail -c "+$((have + 1))" "${CURL_BUNDLE:?}" >>"$out"
    ;;
*) exit 22 ;;
esac
exit 0
EOF
cat >"$OSL/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$OSL/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 1000000 0 999999999 0% /data"
EOF
chmod +x "$OSL/bin/rauc" "$OSL/bin/curl" "$OSL/bin/systemctl" "$OSL/bin/df"

oslrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$OSL" && PATH="$OSL/bin:$PATH" RAUC_LOG="$OSL/rauc.log" \
        CURL_API_RESPONSE="$OSL/api.json" CURL_BUNDLE="$OSL/fixture.raucb" \
        RAUC_INFO_OUT="$OSL/info-good.txt" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$OSLDIR" \
        PITHEAD_VARIANT_FILE="$OSL/variant-release" PITHEAD_DATA_FLOOR_FILE="$OSL/floor" \
        PITHEAD_RAUC_SYSTEM_CONF="$OSL/system.conf" PITHEAD_OS_DL_ATTEMPT=60 \
        PITHEAD_MIGRATION_MARKER_FILE="$OSL/marker-scratch" \
        env "$@" ./pithead control-run-pending 2>&1)
}
osl_intent() { printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$1" "$2" >"$OSLREQS/$1.json"; }
ULOCK="88888888-8888-4888-8888-888888888888"
osl_st() { jq -r '.status' "$OSLRES/$ULOCK.json" 2>/dev/null; }
osl_err() { jq -r '.error' "$OSLRES/$ULOCK.json" 2>/dev/null; }
: >"$OSL/rauc.log"

# The install door reads the CHECKED target ($OSLDIR/target.json), so a bare restage is not enough:
# with no check the door refuses "no fully downloaded update bundle is staged" and BOTH sections
# below would go green off that refusal instead of off the path under test. os-check is throttled to
# once per ten minutes and a successful install consumes target.json, so check once and restore the
# snapshot per section.
OSLARM="11111111-1111-4111-8111-111111111111"
osl_intent "$OSLARM" os-check
oslrun >/dev/null
assert_eq "the fixture arms: os-check records a checked target" "$(jq -r '.status' "$OSLRES/$OSLARM.json" 2>/dev/null)" "checked"
cp -f "$OSLDIR/target.json" "$OSL/target-pristine.json"

osl_arm() { # restore a checked target and a staged bundle. Deliberately does NOT pre-set the state
    # file: writing "idle" here would make the "returns to idle" assertion below unfailable.
    cp -f "$OSL/target-pristine.json" "$OSLDIR/target.json"
    cp "$OSL/fixture.raucb" "$OSLDIR/pithead-os-v9.9.9.raucb"
    rm -f "$OSLDIR/in-flight.json" "$OSLRES/$ULOCK.json"
    : >"$OSL/rauc.log"
}
# Sets OSLHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks until that holder's stdout closes, i.e. for its whole lifetime.
OSLHOLDER=""
osl_hold() { # <lockfile> -> sets OSLHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    OSLHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the lock window" "the lock is still free — the contended case would prove nothing"
    fi
}

# Positive control: the fixture really does drive a working install. Without this, a contended run
# reporting "rejected" is equally consistent with a fixture that never armed — the staging door
# refuses with a "rejected" of its own, and the two read identically.
osl_arm
osl_intent "$ULOCK" os-install
oslrun >/dev/null
assert_eq "uncontended: the install reports installed" "$(osl_st)" "installed"
assert_contains "uncontended: rauc install actually ran" "$(cat "$OSL/rauc.log")" "install $OSLDIR/pithead-os-v9.9.9.raucb"
assert_eq "uncontended: the state file records reboot-pending" "$(jq -r '.step' "$OSLSTATE" 2>/dev/null)" "reboot-pending"

# The claim: the same input, with the machine held by another operation.
OSLLK="$SANDBOX/os-lock-held.lock"
osl_hold "$OSLLK"
osl_arm
osl_intent "$ULOCK" os-install
osl_out=$(oslrun PITHEAD_LOCK_FILE="$OSLLK" PITHEAD_LOCK_TIMEOUT=1)
assert_eq "contended: the install is rejected, not failed" "$(osl_st)" "rejected"
assert_contains "contended: the reason says the install was not started" "$(osl_err)" "was not started"
assert_contains "contended: the reason says nothing was changed" "$(osl_err)" "nothing was changed"
assert_not_contains "contended: it does not claim the install did not complete" "$(osl_err)" "did not complete"
assert_eq "contended: rauc install never ran" "$(grep -c 'rauc\] install' "$OSL/rauc.log" || true)" "0"
assert_eq "contended: no in-flight flag is left behind" "$([ -f "$OSLDIR/in-flight.json" ] && echo present || echo absent)" "absent"
assert_eq "contended: the state file returns to idle" "$(jq -r '.step' "$OSLSTATE" 2>/dev/null)" "idle"
assert_contains "contended: the host-side log names the contention" "$osl_out" "still held the machine"
assert_eq "contended: the staged bundle is kept for the retry" "$([ -f "$OSLDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "present"
kill "$OSLHOLDER" 2>/dev/null || true
