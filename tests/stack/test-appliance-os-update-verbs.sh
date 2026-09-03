# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance os-update verbs domain (#1105 Phase 1, develop-v2 lane): the dashboard-driven A/B
# update path, exercised through the control channel the way an operator reaches it. Two black-box
# sections drive a release-shaped appliance sandbox — control channel on, PITHEAD_APPLIANCE forced,
# and the toolchain stubbed (rauc, curl, systemctl, df) — so the whole
# check → download → verify → install → reboot chain and every refusal along it run for real with
# no network, no RAUC and no root. Between them they cover the off-appliance and out-of-order
# refusals; os-check's derived target, its cache and how many times it dials; the free-space,
# same-version and unchecked-version doors on download; a mid-transfer timeout that keeps its bytes
# and resumes from them; verify rejecting a bad signature, a rauc that could not run, a wrong
# compatible string, a variant flip, a bundle below the /data floor and a mismatched tag — each
# refusal naming which of those it was; install's failed and installed results, the in-flight flag
# and the host-side log tail; the reboot order, its 24-hour staleness and the one-verb-per-drain
# budget; and a GitHub rate limit answered with a remedy the operator can actually reach (#1081).
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Re-derivations: none. From outside the file the block reads $SANDBOX and $STACK, and the
# make_stubs, ok, bad, assert_eq, assert_contains and assert_not_contains helpers — all of them from
# lib.sh, which run.sh sources near its top, long before this stanza. $STACK is only ever read, to
# copy the script into the sandbox. Every other name is assigned here: $OSC and the
# $OSREQS/$OSRES/$OSSTATE/$OSDIR tree beneath it, $UOS, $UOS2, $dials_before, and the osrun,
# os_intent, os_reset and os_restage helpers, which the closing lines unset. Two scratch names are
# left set — $out and $os_403 — as they were before the move; the stanza runs at the block's former
# position, so grouping changes nothing about that.
#
# Every write lands under $OSC ($SANDBOX/os-control), the stubs' RAUC_LOG, CURL_LOG and SYSCTL_LOG
# included, and the sandboxed pithead derives its own CONTROL_DIR from the directory osrun cd's
# into rather than from anything ambient. So nothing here touches $V, $C or the ambient $STACK, and
# nothing outside this file reads what it creates.

echo "== black-box: control os-update verbs (appliance A/B, dashboard-driven) =="
# A release-shaped appliance sandbox: control channel on, PITHEAD_APPLIANCE forced, and the whole
# toolchain stubbed (rauc/curl/systemctl/df) so every refusal and the full check → download →
# verify → install → reboot chain runs for real with no network, no RAUC, no root.
OSC="$SANDBOX/os-control"
OSREQS="$OSC/data/control/requests"
OSRES="$OSC/data/control/results"
OSSTATE="$OSRES/os-update-state.json"
OSDIR="$OSC/osdir"
mkdir -p "$OSREQS" "$OSC/data/control/staged" "$OSRES" "$OSC/data/control/audit" "$OSDIR"
cp "$STACK" "$OSC/pithead"
make_stubs "$OSC/bin"
printf '1.3.1' >"$OSC/VERSION"
printf '{}' >"$OSC/config.json"
cat >"$OSC/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$OSC/data/control
NETWORK_PREFIX=10.9.0
EOF
printf 'release\n' >"$OSC/variant-release"
printf 'compatible=pithead-os\n' >"$OSC/system.conf"
# The published release the stub API serves: tag + the .raucb asset with its size.
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-v9.9.9.raucb","size":1000}]}' >"$OSC/api.json"
# The 1000-byte bundle fixture the stub curl serves (deterministic bytes so resume can append).
yes x | head -c 1000 >"$OSC/fixture.raucb"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-good.txt"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='debug'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-debug.txt"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.8'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-mismatch.txt"
printf "RAUC_MF_COMPATIBLE='other-machine'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-othercompat.txt"
cat >"$OSC/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ "${RAUC_RUN_FAIL:-}" = "1" ] && exit 127 # rauc never ran (exec failure), no verdict
    [ "${RAUC_SIG_FAIL:-}" = "1" ] && exit 1
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    exit 0
    ;;
install)
    [ "${RAUC_INSTALL_FAIL:-}" = "1" ] && {
        echo "slot device /dev/hostdisk3 staging $PWD" # host detail that must stay out of the result
        echo "installing failed"
        exit 1
    }
    echo "installing bundle: 50%"
    echo "installing bundle: 100%"
    exit 0
    ;;
esac
exit 0
EOF
# Stub curl: serves the canned API JSON, and for the bundle URL either appends the fixture's
# remainder onto -o's target (a genuine resume when the partial exists) or, told CURL_RC=28,
# writes CURL_PARTIAL_BYTES and exits like --max-time closing the window mid-transfer.
cat >"$OSC/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
# os-check reads the body AND the status now that it goes through the shared release fetch
# (#1081), so the stub has to answer in the shape `-w '\n%{http_code}'` produces. GH_STUB_CODE
# lets a test drive a non-2xx through the real control path; unset means the ordinary 200.
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n%s' "${GH_STUB_CODE:-200}"
    ;;
*releases/download/*)
    if [ "${CURL_RC:-0}" = "28" ]; then
        head -c "${CURL_PARTIAL_BYTES:-300}" "${CURL_BUNDLE:?}" >"$out"
        exit 28
    fi
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    tail -c "+$((have + 1))" "${CURL_BUNDLE:?}" >>"$out"
    ;;
*) exit 22 ;;
esac
exit 0
EOF
cat >"$OSC/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${SYSCTL_LOG:?}"
exit 0
EOF
# Stub df: the headroom gate reads column 4 (Available, KiB) of the second line.
cat >"$OSC/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 1000000 0 ${DF_AVAIL_KB:-999999999} 0% /data"
EOF
chmod +x "$OSC/bin/rauc" "$OSC/bin/curl" "$OSC/bin/systemctl" "$OSC/bin/df"
osrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$OSC" && PATH="$OSC/bin:$PATH" RAUC_LOG="$OSC/rauc.log" CURL_LOG="$OSC/curl.log" \
        SYSCTL_LOG="$OSC/sysctl.log" CURL_API_RESPONSE="$OSC/api.json" CURL_BUNDLE="$OSC/fixture.raucb" \
        RAUC_INFO_OUT="$OSC/info-good.txt" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$OSDIR" \
        PITHEAD_VARIANT_FILE="$OSC/variant-release" PITHEAD_DATA_FLOOR_FILE="$OSC/floor" \
        PITHEAD_RAUC_SYSTEM_CONF="$OSC/system.conf" PITHEAD_OS_DL_ATTEMPT=60 \
        PITHEAD_MIGRATION_MARKER_FILE="$OSC/marker-scratch" \
        env "$@" ./pithead control-run-pending 2>&1)
}
os_intent() { # <id> <action> [version]
    if [ "$#" -ge 3 ]; then
        printf '{"id":"%s","action":"%s","actor":"admin","version":"%s"}\n' "$1" "$2" "$3" >"$OSREQS/$1.json"
    else
        printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$1" "$2" >"$OSREQS/$1.json"
    fi
}
UOS="77777777-7777-4777-8777-777777777777"
os_reset() { rm -f "$OSRES/$UOS.json"; }
: >"$OSC/rauc.log"
: >"$OSC/curl.log"
: >"$OSC/sysctl.log"

# Off the appliance every verb refuses outright — there is no RAUC and nothing to update.
os_intent "$UOS" os-check
osrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "os-check off the appliance is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the appliance" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "appliance"
os_reset
os_intent "$UOS" os-reboot
osrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "os-reboot off the appliance is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
os_reset

# Download before any check: there is no host-derived target to hold the proposal against.
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "os-download without a prior check is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says to check first" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "check for updates"
os_reset

# os-check derives tag + asset size on the host and reports newer honestly.
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "os-check reports checked" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "os-check carries the host-derived version" "$(jq -r '.version' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
assert_eq "os-check carries the bundle size" "$(jq -r '.size' "$OSRES/$UOS.json" 2>/dev/null)" "1000"
assert_eq "os-check reports newer against the running 1.3.1" "$(jq -r '.newer' "$OSRES/$UOS.json" 2>/dev/null)" "true"
assert_eq "os-check caches the derived target" "$(jq -r '.tag' "$OSDIR/target.json" 2>/dev/null)" "v9.9.9"
os_reset
# A second check answers from the fresh cache — no second dial (anti-beacon).
dials_before=$(grep -c 'api.github.com' "$OSC/curl.log" || true)
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "a fresh cache answers the second check" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "the second check dials nothing" "$(grep -c 'api.github.com' "$OSC/curl.log" || true)" "$dials_before"
os_reset

# The container cannot steer the download target: a proposal that isn't the checked tag refuses.
os_intent "$UOS" os-download "v1.0.0"
osrun >/dev/null
assert_eq "a non-checked download version is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the checked release" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
os_reset

# Equality is still an honest CHECK — up to date reports normally; only fetch and install refuse.
# pithead re-reads the VERSION file at startup (env cannot override it through the black-box
# door), so the sandbox's running version is swapped to the target and back.
printf '9.9.9' >"$OSC/VERSION"
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "a same-version check still reports checked" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "a same-version check reports not newer" "$(jq -r '.newer' "$OSRES/$UOS.json" 2>/dev/null)" "false"
os_reset

# The dashboard door refuses a same-version fetch outright, before a byte moves — a compromised
# container must not loop gigabytes over Tor into reinstalls and forced reboots. (The CLI keeps
# equality for manual slot repair, proven in the os-update unit block above.)
dials_before=$(grep -c 'releases/download' "$OSC/curl.log" || true)
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "a same-version download is rejected on the dashboard door" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says already on it" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "already on v9.9.9"
assert_eq "no bytes moved for the refused same-version fetch" "$(grep -c 'releases/download' "$OSC/curl.log" || true)" "$dials_before"
printf '1.3.1' >"$OSC/VERSION"
os_reset

# No disk headroom: refused before a byte moves.
os_intent "$UOS" os-download "v9.9.9"
osrun DF_AVAIL_KB=1000 >/dev/null
assert_eq "a full /data refuses the download" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names free space" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "free space"
assert_eq "no bundle bytes landed" "$(find "$OSDIR" -name '*.raucb*' | wc -l | tr -d ' ')" "0"
os_reset

# The attempt window closes mid-transfer: partial result, partial file KEPT for the resume.
os_intent "$UOS" os-download "v9.9.9"
osrun CURL_RC=28 CURL_PARTIAL_BYTES=300 >/dev/null
assert_eq "a mid-transfer timeout reports partial" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "partial"
assert_eq "partial reports the bytes so far" "$(jq -r '.bytes' "$OSRES/$UOS.json" 2>/dev/null)" "300"
assert_eq "the partial file is kept for the resume" "$(wc -c <"$OSDIR/pithead-os-v9.9.9.raucb.partial" | tr -d ' ')" "300"
os_reset

# The retry RESUMES: curl is asked to continue (-C -) and the result names where it picked up.
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "the resumed download completes" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "downloaded"
assert_eq "the resume started from the kept bytes" "$(jq -r '.resumed_from' "$OSRES/$UOS.json" 2>/dev/null)" "300"
assert_contains "curl was asked to continue the transfer" "$(cat "$OSC/curl.log")" "-C -"
assert_eq "the staged bundle is complete" "$(wc -c <"$OSDIR/pithead-os-v9.9.9.raucb" | tr -d ' ')" "1000"
assert_eq "the state file records the staged download" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "downloaded"
os_reset
# A repeated download of a staged bundle is an idempotent no-op, not a re-download.
dials_before=$(grep -c 'releases/download' "$OSC/curl.log" || true)
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "an already-staged bundle answers downloaded" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "downloaded"
assert_eq "no second transfer for a staged bundle" "$(grep -c 'releases/download' "$OSC/curl.log" || true)" "$dials_before"
os_reset

# os-verify: signature first — a mis-signed file is refused AND deleted, no override.
os_intent "$UOS" os-verify
osrun RAUC_SIG_FAIL=1 >/dev/null
assert_eq "a mis-signed bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names signature verification" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "signature"
assert_eq "the mis-signed bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# Verify with nothing staged: refused with the honest next step.
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "verify with no staged bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says to download first" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "download it first"
os_reset

os_restage() { cp "$OSC/fixture.raucb" "$OSDIR/pithead-os-v9.9.9.raucb"; }

# rauc failing to RUN is not a signature verdict: one retry, a distinct honest reason, and the
# download is KEPT for the retry — deleting a multi-GB Tor fetch is a verdict a broken tool
# has not earned.
os_restage
: >"$OSC/rauc.log"
os_intent "$UOS" os-verify
osrun RAUC_RUN_FAIL=1 >/dev/null
assert_eq "a rauc that cannot run rejects the verify" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the reason says rauc could not run, not signature" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "could not run"
assert_not_contains "the reason does not claim a signature verdict" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "signature"
assert_eq "the bundle is kept when rauc never judged it" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "present"
assert_eq "the failed rauc run was retried once" "$(grep -c 'info' "$OSC/rauc.log" || true)" "2"
os_reset

# Wrong compatible: built for another machine class, refused and deleted.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-othercompat.txt" >/dev/null
assert_eq "a wrong-compatible bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names both machine classes" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "other-machine"
assert_eq "the wrong-compatible bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# A variant flip (release box, debug bundle) never installs from the dashboard — CLI consent only.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-debug.txt" >/dev/null
assert_eq "a variant-flipping bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the variant consent" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "variant"
os_reset

# The /data floor refuses through the dashboard door exactly as at the CLI — a valid signature is
# not permission to replay below the floor (shared guard; VERSION swap as at the equality rows).
os_restage
printf '10.0.0\n' >"$OSC/floor" && printf '10.0.0' >"$OSC/VERSION"
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a bundle below the /data floor is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the floor refusal warns about the chain data" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "strand the chain data"
rm -f "$OSC/floor" && printf '1.3.1' >"$OSC/VERSION"
os_reset

# A stamp that isn't the published tag is a possible replay — refused.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-mismatch.txt" >/dev/null
assert_eq "a tag-mismatched stamp is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the mismatch" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "9.9.8"
os_reset

# A same-version bundle refuses at verify too — download refuses it first, but verify holds the
# line for a bundle already staged when the versions converged, and the bundle is deleted.
# Same VERSION-file swap as the check/download equality tests above.
os_restage
printf '9.9.9' >"$OSC/VERSION"
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a same-version bundle is rejected at verify" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the verify refusal says already on it" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "already on v9.9.9"
assert_eq "the same-version bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
printf '1.3.1' >"$OSC/VERSION"
os_reset

# The happy verify: signed, compatible, newer, stamped as published.
os_restage
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a good bundle verifies" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "verified"
assert_eq "verify reports the version" "$(jq -r '.version' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
assert_eq "the state file records verified" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "verified"
os_reset

# Reboot with no installed update waiting: refused — the dashboard is not a reboot lever.
rm -f "$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "os-reboot with nothing installed is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_eq "no reboot was ordered" "$(grep -c reboot "$OSC/sysctl.log" || true)" "0"
os_reset

# A failing install reports failed and the running system is untouched (no in-flight flag).
# The result carries only the whitelist-extracted final error line — the raw log tail (staging
# paths, slot devices) stays host-side, in the journal.
os_intent "$UOS" os-install
out=$(osrun RAUC_INSTALL_FAIL=1)
assert_eq "a failing install reports failed" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "failed"
assert_contains "the failure says the system is untouched" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "untouched"
assert_contains "the result carries rauc's final error line" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "installing failed"
assert_not_contains "the raw log tail stays out of the result" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "hostdisk3"
assert_contains "the full log tail lands host-side for the journal" "$out" "hostdisk3"
assert_eq "no in-flight flag after a failed install" "$([ -f "$OSDIR/in-flight.json" ] && echo present || echo absent)" "absent"
os_reset

# The happy install: the SAME os_update path the CLI takes writes the spare slot, the in-flight
# flag arms the post-reboot verdict, and the staged bundle is cleaned up.
os_intent "$UOS" os-install
osrun >/dev/null
assert_eq "the install reports installed" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "installed"
assert_contains "rauc install ran with the staged bundle" "$(cat "$OSC/rauc.log")" "install $OSDIR/pithead-os-v9.9.9.raucb"
assert_eq "the in-flight flag names the target" "$(jq -r '.to' "$OSDIR/in-flight.json" 2>/dev/null)" "9.9.9"
assert_eq "the in-flight flag names the origin" "$(jq -r '.from' "$OSDIR/in-flight.json" 2>/dev/null)" "1.3.1"
assert_eq "the state file records reboot-pending" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "reboot-pending"
assert_eq "the staged bundle was cleaned up" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# Now the reboot goes through — the install result is FRESH: result lands BEFORE the order,
# then systemctl reboot.
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "os-reboot with a fresh install reports rebooting" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$OSC/sysctl.log")" "reboot"
os_reset

# The install result authorizes a reboot for 24 hours, then goes stale: refused with the re-arm
# path, and no reboot is ordered. An in-flight flag with no readable timestamp refuses too —
# unreadable is not proof of freshness.
jq -n '{from:"1.3.1",to:"9.9.9",ts:((now|floor) - 90000)}' >"$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "a stale install no longer authorizes a reboot" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the stale refusal names the re-arm path" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "re-arms the reboot"
assert_eq "no second reboot was ordered" "$(grep -c reboot "$OSC/sysctl.log" || true)" "1"
os_reset
jq -n '{from:"1.3.1",to:"9.9.9"}' >"$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "an in-flight flag without a timestamp refuses the reboot" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
os_reset

# One os-* verb per drain: a second one in the same cycle rejects with a retry hint.
UOS2="88888888-8888-4888-8888-888888888888"
rm -f "$OSDIR/in-flight.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short" # a fresh dial, not the check throttle
os_intent "$UOS" os-check
sleep 1 # distinct mtimes so the drain order is deterministic (oldest first)
os_intent "$UOS2" os-check
osrun >/dev/null
assert_eq "the first os verb in a drain runs" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "the second os verb in the same drain is rejected" "$(jq -r '.status' "$OSRES/$UOS2.json" 2>/dev/null)" "rejected"
assert_contains "the budget refusal says retry" "$(jq -r '.error' "$OSRES/$UOS2.json" 2>/dev/null)" "retry"
rm -f "$OSRES/$UOS.json" "$OSRES/$UOS2.json"

# The battery's test seam only redirects for a ROOT-owned file: written by anyone else it is
# ignored and the flow stays on the GitHub-over-Tor path. Running unprivileged here, our own
# file IS owner-matched — assert the redirect engages, which is the seam's whole contract.
printf 'http://bench.invalid/updates' >"$OSC/os-update-test-base"
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short"
os_intent "$UOS" os-check
osrun >/dev/null
assert_contains "the test seam redirects the release lookup" "$(cat "$OSC/curl.log")" "bench.invalid/updates/releases-latest.json"
rm -f "$OSC/os-update-test-base" "$OSRES/$UOS.json" "$OSDIR/.check-stamp-short" # the stub's exit-22 catch-all makes this bench dial rc 2 too (#1050 review) — clear it or it leaks into the next test

# #1081 reached only the two DIY lookups. The appliance's os-check kept its own `curl -fsS`, and
# `-f` collapses every non-2xx into one exit code — so a spent GitHub budget came out of the
# dashboard as "could not reach the release API over Tor", pointing at a doctor run that reports
# Tor healthy, on a box with no shell to run it from. It goes through the shared fetch now.
echo "== black-box: a rate-limited os-check names the remedy that works (#1081) =="
printf '%s' '{"message":"API rate limit exceeded for this IP.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}' >"$OSC/api-403.json"
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short" # starts clean regardless of what leaked above
os_reset
os_intent "$UOS" os-check
osrun CURL_API_RESPONSE="$OSC/api-403.json" GH_STUB_CODE=403 >/dev/null
os_403=$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)
assert_eq "a rate-limited os-check is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "and names the remedy that actually works" "$os_403" "restart tor"
# The defect itself, as the operator read it: the old refusal blamed the transport and sent them to
# a doctor run that reports Tor healthy. Both halves of that sentence are barred. (The replacement
# does say the word "doctor" — "nothing is wrong with this box, and 'doctor' will say so" — so this
# matches the two OLD phrasings, not the word.)
case "$os_403" in
*"could not reach the release API"* | *"Check './pithead doctor' and retry"*)
    bad "a rate limit is not reported as a dead Tor circuit" "the refusal still says: $os_403"
    ;;
*) ok "a rate limit is not reported as a dead Tor circuit" ;;
esac
# The 10-minute throttle stays HELD on a rate-limit refusal: that request did reach GitHub, so
# releasing it restores exactly the unthrottled beacon the throttle exists to stop (#1081's fix 2,
# deliberately not taken).
assert_eq "the throttle is still held after a rate-limit refusal" \
    "$([ -f "$OSDIR/.check-stamp" ] && echo held || echo released)" "held"
os_reset
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short"

unset -f osrun os_intent os_reset os_restage
rm -rf "$OSC"
unset OSC OSREQS OSRES OSSTATE OSDIR UOS UOS2 dials_before
