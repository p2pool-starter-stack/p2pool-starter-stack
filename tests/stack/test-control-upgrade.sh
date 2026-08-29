# shellcheck shell=bash
#
# Control-upgrade domain (#1105 Phase 1, module 8): the one-click upgrade verb end to end —
# ordering safety (a failed upgrade never repoints the control-runner units, #1070), the shared
# GitHub release-fetch helper (a spent rate limit read honestly instead of blamed on Tor, #1081/
# #1139), the upgrade verb against a release install (#59), extraction to a fresh version dir
# (#629), and the bundle-signature verification module 6 left behind for this module (#376).
# Sourced by tests/stack/run.sh after lib.sh.
#
# Re-derivation: two spots below need the shared control sandbox $C, "control_config main,
# applied" (source-checkout upgrade refusal; the bundle-signature section's channel-disabled
# tail) — but $C is built by build_control_sandbox() in tests/stack/test-control-core.sh, which
# run.sh sources AFTER this file, so there is no ambient sandbox to reach back for at this point
# in the run. Re-derive a fresh, equivalent $C, mirroring the control-core domain's own "dashboard
# control channel (#33)" setup, and define $REQS/$RESULTS the same way (not lib.sh globals; only
# these two are read below).
#
# $WALLET, set explicitly: lib.sh's control_config() closure reads it without ever setting it — it used
# to arrive already set globally, from the config-validation section's far-earlier build_val_sandbox()
# call back when that section was inline in run.sh. Same trap as module 7's onion-report fix:
# $VALID_PRIMARY is what WALLET equals there, and it's always bound. Since FIXED in lib.sh (#1305): both
# sandbox builders default WALLET now, so a future control-sandbox domain file no longer has to set it.
# The line below is kept because it is correct and harmless, not because anything still requires it.
build_control_sandbox
# shellcheck disable=SC2034  # read by lib.sh's control_config() closure, unseen here
WALLET="$VALID_PRIMARY"
seed_control_env
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"

echo "== black-box: a failed upgrade never repoints the control-runner units (#1070) =="
# The units are host-global and bake an absolute path. On a one-click deploy stack_upgrade runs from
# the NEW version dir while `current ->` still names the old one, so provisioning them before the
# release is live points them at a dir that may never become the install. That is what bricked
# pithead-prod: the image gate aborted, `current` never moved, and the path unit was left watching a
# spool the running dashboard does not write to — silently killing the control channel, and with it
# the one-click upgrade that would have fixed it. Provisioning must therefore come last, after
# update_current_symlink. Both directions are asserted: the ordering on success, and — the one that
# actually bites — that an abort at the gate repoints nothing at all.
upg_step_order() { # <verify_release_images body> — the step markers stack_upgrade reaches, in order
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { :; }
        load_preserved_state() { :; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        provision_node_onions() { :; }
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        migrate_dashboard_data() { :; }
        is_source_checkout() { return 1; }
        log() { :; }
        eval "verify_release_images() { $1 }"
        compose_up_checked() { echo compose; }
        update_current_symlink() { echo symlink; }
        provision_control_runner() { echo provision; }
        stack_upgrade
    ) | grep -xE 'verify|compose|symlink|provision' | tr '\n' ','
}
assert_eq "successful upgrade provisions the units only after 'current ->' moves (#1070)" \
    "$(upg_step_order 'echo verify;')" "verify,compose,symlink,provision,"
# The red test for #1070: abort at the image gate, exactly as a host without a runnable verifier
# does. If provisioning ever migrates back above the pull, `provision` reappears here and this fails.
assert_eq "an upgrade that aborts at the gate repoints no units and moves no symlink (#1070)" \
    "$(upg_step_order 'echo verify; error "gate refused";')" "verify,"

echo "== unit: a spent GitHub rate limit is not a dead Tor circuit (#1081) =="
# The one-click upgrade was rejected on a healthy box with "could not reach the GitHub release API
# over Tor". Tor was fine and the dial succeeded; GitHub answered 403 because the unauthenticated
# limit is 60 requests an hour PER IP and a Tor exit is shared with everyone else using it, so the
# budget had been spent by strangers. `curl -f` collapses every non-2xx into one exit code, so the
# only thing the operator was told pointed at 'doctor' — which correctly reports Tor healthy.
#
# The remedy is a different one entirely: pick a new exit. The fetch is now ONE function both the
# pithead and the RigForge lookups go through, so neither can drift back.
#
# MUTATION PROOF: make the 403 branch fall through to the generic hint (or restore `curl -fsS`) and
# the rate-limit assertion goes red; the transport-failure assertion holds it honest in the other
# direction, so "always blame the rate limit" does not pass either.
GHR="$SANDBOX/gh-release"
mkdir -p "$GHR/bin"
cat >"$GHR/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Answers with $GH_STUB_CODE and $GH_STUB_BODY, in the shape `-w '\n%{http_code}'` produces.
[ "${GH_STUB_TRANSPORT_FAIL:-0}" = "1" ] && exit 7
[ "${GH_STUB_NOCODE:-0}" = "1" ] && { printf '%s' "${GH_STUB_BODY:-}"; exit 0; }
printf '%s\n%s' "${GH_STUB_BODY:-}" "${GH_STUB_CODE:-200}"
EOF
chmod +x "$GHR/bin/curl"
gh_fetch() { # <code> <body> [transport-fail] -> "<rc>|<stdout>|<hint>"
    (
        cd "$GHR" || exit 1
        # shellcheck disable=SC1090  # STACK path is dynamic by design
        source "$STACK" 2>/dev/null
        set +e
        export PATH="$GHR/bin:$PATH" GH_STUB_CODE="$1" GH_STUB_BODY="$2" GH_STUB_TRANSPORT_FAIL="${3:-0}"
        gh_release_fetch p2pool-starter-stack/pithead
        printf '%s|%s|%s' "$?" "$GH_RELEASE_JSON" "$GH_RELEASE_HINT"
    )
}
gh_ok=$(gh_fetch 200 '{"tag_name":"v1.2.3"}')
assert_eq "a 200 returns the release JSON" "${gh_ok%%|*}" "0"
assert_contains "and the JSON is what the caller gets" "$gh_ok" '"tag_name":"v1.2.3"'

gh_rl=$(gh_fetch 403 '{"message":"API rate limit exceeded for 203.0.113.9."}')
assert_eq "a spent rate limit is a failure" "${gh_rl%%|*}" "1"
assert_contains "and names the remedy that actually works" "$gh_rl" "restart tor"
case "$gh_rl" in
*"could not reach the GitHub release API"*) bad "a spent rate limit is not reported as unreachable" "the hint still blames the dial: $gh_rl" ;;
*) ok "a spent rate limit is not reported as unreachable" ;;
esac

gh_tf=$(gh_fetch 000 '' 1)
assert_eq "a transport failure is still a failure, now distinctly rc 2 (#1050)" "${gh_tf%%|*}" "2"
assert_contains "and still reads as a dial that did not land" "$gh_tf" "could not reach the GitHub release API"
case "$gh_tf" in
*"restart tor"*) bad "a dial failure is not blamed on the rate limit" "the hint sends them to restart tor: $gh_tf" ;;
*) ok "a dial failure is not blamed on the rate limit" ;;
esac

# No status line at all — `code` is then the WHOLE BODY, and it went into an operator-facing string
# ("answered HTTP {"message":"Not Found"}"): unreadable, and a way for a remote body to reach the
# dashboard verbatim. GH_STUB_NOCODE makes the stub answer the way that produced it.
gh_nocode=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s|%s' "$?" "$GH_RELEASE_HINT"
)
assert_eq "a response with no status line is a failure" "${gh_nocode%%|*}" "1"
case "$gh_nocode" in
*'{"message"'* | *'Not Found'*) bad "the body never reaches the operator" "the hint quotes the response body: $gh_nocode" ;;
*) ok "the body never reaches the operator" ;;
esac

gh_500=$(gh_fetch 500 'upstream is unwell')
assert_eq "a server error is a failure" "${gh_500%%|*}" "1"
assert_contains "and says which status came back" "$gh_500" "HTTP 500"

# Every lookup goes through the one function — a second copy is how the two messages drifted apart
# in the first place, and the RigForge one would have kept the old wrong hint. Three on this lane:
# the one-click upgrade, the RigForge worker upgrade, and the appliance's os-check, which carried
# its own `curl -fsS` (and so its own collapsed 403) until the sync that brought #1081 over.
assert_eq "every release lookup uses the shared fetch" \
    "$(grep -c 'gh_release_fetch p2pool-starter-stack/' "$STACK")" "3"
assert_eq "no release lookup dials the API directly any more" \
    "$(grep -c 'api.github.com/repos/.*/releases/latest' "$STACK")" "1"
# The hint has to reach the CALLER. `rel=$(gh_release_fetch ...)` reads naturally and is a subshell,
# so the hint would be set and discarded and every rejection would carry an empty message — the
# defect this whole change exists to remove, reintroduced by the refactor that removes it. Neither
# caller may wrap the fetch in a command substitution.
assert_eq "neither caller swallows the hint in a subshell" \
    "$(grep -cF '=$(gh_release_fetch' "$STACK")" "0"
# os_release_fetch wraps the shared fetch for the appliance and publishes the same two globals, so
# it inherits the same rule. It was `rel=$(os_release_fetch)` before — the exact swallowing form,
# which is why this one is asserted rather than trusted.
assert_eq "the appliance os-check does not swallow the hint either" \
    "$(grep -cF '=$(os_release_fetch' "$STACK")" "0"
# And the other half of the same mistake: folding the lookup into a function DELETED the caller's own
# `local prefix socks` derivation, while two later downloads in that same function still said
# "$socks". Under `set -u` the runner died at its first download — the upgrade result sat at
# "running" for ever with a single dial in the log and nothing extracted, and 60 assertions went red
# together. The fetch publishes the address it used; every dial on that path reads the same one.
assert_eq "every dial on the upgrade path uses the address the lookup derived" \
    "$(grep -cF -- '--socks5-hostname "$GH_SOCKS"' "$STACK")" "3"
# A whole-file count of `"$socks"` cannot tell a declared one from an undeclared one — the
# appliance's OS-bundle download legitimately derives its own, because its bench seam has to leave
# the address EMPTY, and a plain count reads that as the bug. So ask the question the defect
# actually poses: is every `"$socks"` dial inside a function that declares socks?
undeclared_socks="$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { fn = $1; declared = 0 }
    fn && /^ *local .*socks/ { declared = 1 }
    /--socks5-hostname "\$socks"/ && !declared { print FNR " in " fn }
' "$STACK")"
assert_eq "no dial refers to a socks variable its own function never declares" "$undeclared_socks" ""

echo "== unit: appliance-lane release-fetch hints name no shell the box does not have (#1139) =="
# The transport-failure and unparseable-response hints told the operator to run './pithead doctor'
# — reachable from the dashboard's os-check (and the RigForge worker-upgrade) on an appliance,
# which has no shell to run it from. gh_release_fetch now keys the retry hint off is_appliance, a
# fact about the machine rather than the caller, so every caller gets it right for free.
#
# MUTATION PROOF: hardcode retry_hint to the DIY string (drop the is_appliance branch) and both
# "names no CLI verb" assertions below go red; hardcode it to the appliance string instead and the
# DIY-lane assertions (both here and in the block above) go red — neither direction can pass alone.
gh_tf_appliance=$(PITHEAD_APPLIANCE=1 gh_fetch 000 '' 1)
assert_eq "appliance transport failure is still a failure, now distinctly rc 2 (#1050)" "${gh_tf_appliance%%|*}" "2"
assert_contains "and still reads as a dial that did not land" "$gh_tf_appliance" "could not reach the GitHub release API"
assert_contains "and points at the dashboard instead of a shell" "$gh_tf_appliance" "Retry from the dashboard"
case "$gh_tf_appliance" in
*"./pithead"*) bad "appliance transport-failure hint names no CLI verb" "still says: $gh_tf_appliance" ;;
*) ok "appliance transport-failure hint names no CLI verb" ;;
esac

gh_nocode_appliance=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1 PITHEAD_APPLIANCE=1
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s|%s' "$?" "$GH_RELEASE_HINT"
)
assert_eq "appliance unparseable response is still a failure" "${gh_nocode_appliance%%|*}" "1"
assert_contains "and reads as an unreadable shape" "$gh_nocode_appliance" "answered in a shape this cannot read"
assert_contains "and points at the dashboard instead of a shell" "$gh_nocode_appliance" "Retry from the dashboard"
case "$gh_nocode_appliance" in
*"./pithead"*) bad "appliance unparseable-response hint names no CLI verb" "still says: $gh_nocode_appliance" ;;
*) ok "appliance unparseable-response hint names no CLI verb" ;;
esac

# DIY-lane advice is untouched: 'doctor' is exactly right when the operator has a shell to run it
# from — same fetch, same call, only the machine fact differs.
gh_tf_diy=$(PITHEAD_APPLIANCE=0 gh_fetch 000 '' 1)
assert_contains "DIY transport-failure advice is unchanged" "$gh_tf_diy" "Check './pithead doctor' and retry."
gh_nocode_diy=$(
    cd "$GHR" || exit 1
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    source "$STACK" 2>/dev/null
    set +e
    export PATH="$GHR/bin:$PATH" GH_STUB_BODY='{"message":"Not Found"}' GH_STUB_NOCODE=1 PITHEAD_APPLIANCE=0
    gh_release_fetch p2pool-starter-stack/pithead
    printf '%s' "$GH_RELEASE_HINT"
)
assert_contains "DIY unparseable-response advice is unchanged" "$gh_nocode_diy" "Check './pithead doctor' and retry."

echo "== black-box: control upgrade verb (#59) =="
# A RELEASE install (no build/*/Dockerfile → is_source_checkout false) with the control channel
# on. The runner's upgrade verb runs against a stub curl (GitHub release API + bundle download)
# and a fake release bundle whose pithead records what it was asked to do — no network, no docker.
UPG="$SANDBOX/upgrade59"
UPGREQS="$UPG/data/control/requests"
UPGRESULTS="$UPG/data/control/results"
UPGAUDIT="$UPG/data/control/audit/control.log"
mkdir -p "$UPGREQS" "$UPG/data/control/staged" "$UPGRESULTS" "$UPG/data/control/audit"
cp "$STACK" "$UPG/pithead"
make_stubs "$UPG/bin"
# The #544 abort ("Cannot unlink: Directory not empty") is GNU-tar behaviour — macOS's bsdtar -U
# tolerates non-empty dirs and would mask the regression. CI (Linux) and real installs run GNU
# tar; on a Mac with gnu-tar installed, route this block's tar there too so the bug reproduces.
command -v gtar >/dev/null 2>&1 && ln -sf "$(command -v gtar)" "$UPG/bin/tar"
# Every release bundle ships cosign.pub, so the runner requires the verifier before it downloads
# anything (#1023) — the fixture carries a runnable one so the paths that are supposed to proceed do
# not depend on the host. Since #1072 that means a fake docker, not a fake cosign. It stays inert
# here: this install has no cosign.pub, so no signature is ever fetched and nothing invokes it.
write_fake_docker "$UPG/bin"
printf '1.3.1' >"$UPG/VERSION"
printf '{}' >"$UPG/config.json" # #637: the in-place path snapshots config.json before extracting
# #544/#555: a real release install carries non-empty build/* config-template mounts (see the
# bundle's build/* below) — pre-seed them here with STALE content from "the previous version",
# including a file the new bundle does NOT ship, so the extraction below runs over the exact shape
# that made v1.6.0's single -U tar pass abort ("Cannot unlink: Directory not empty").
mkdir -p "$UPG/build/monero" "$UPG/build/tari" "$UPG/build/tari-wallet"
printf 'stale-monero-template-v1.3.1\n' >"$UPG/build/monero/bitmonero.conf.template"
printf 'stale-tari-template-v1.3.1\n' >"$UPG/build/tari/config.toml.template"
printf 'stale-tari-wallet-entry-v1.3.1\n' >"$UPG/build/tari-wallet/entrypoint.sh"
printf 'leftover-from-a-removed-mount\n' >"$UPG/build/monero/leftover.conf" # absent from the new bundle
# The stub curl serves the canned API response for the release-API URL and copies the fake bundle
# for the download URL; every call is logged so the tests can assert what was (not) dialled.
cat >"$UPG/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
[ "${CURL_FAIL:-}" = "1" ] && exit 22
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
# The release lookup reads the body AND the status now (#1081), so the stub has to answer in the
# shape `-w '\n%{http_code}'` produces. GH_STUB_CODE lets a test drive a non-2xx through the real
# control path; unset means the ordinary 200.
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n%s' "${GH_STUB_CODE:-200}"
    ;;
*releases/download/*.sig) cp "${CURL_SIG:?}" "$out" ;;
*releases/download/*) cp "${CURL_BUNDLE:?}" "$out" ;;
*) exit 22 ;;
esac
EOF
chmod +x "$UPG/bin/curl"
# The fake v9.9.9 release bundle: a pithead that logs its invocation (and can be told to fail).
UPGB="$SANDBOX/upgrade59-bundle"
mkdir -p "$UPGB/pithead/build/monero" "$UPGB/pithead/build/tari" "$UPGB/pithead/build/tari-wallet"
cat >"$UPGB/pithead/pithead" <<'EOF'
#!/usr/bin/env bash
echo "new-pithead $*" >>upgrade-invocations.log
[ "${NEW_PITHEAD_FAIL:-}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$UPGB/pithead/pithead"
printf '9.9.9' >"$UPGB/pithead/VERSION"
# build/* members mirror the real bundle layout (scripts/release.sh's compose_build_mounts): every
# release install carries these non-empty config-template mounts, which is exactly what #544/#555
# tests below — a bundle with only the "pithead" script can't reproduce that bug.
printf 'new-monero-template-v9.9.9\n' >"$UPGB/pithead/build/monero/bitmonero.conf.template"
printf 'new-tari-template-v9.9.9\n' >"$UPGB/pithead/build/tari/config.toml.template"
printf 'new-tari-wallet-entry-v9.9.9\n' >"$UPGB/pithead/build/tari-wallet/entrypoint.sh"
tar -czf "$UPGB/bundle.tar.gz" -C "$UPGB" pithead
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}' >"$UPGB/api.json"
seed_upgrade_env() { # <control-enabled true|false>
    cat >"$UPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=$1
CONTROL_DIR=$UPG/data/control
NETWORK_PREFIX=10.9.0
EOF
}
urun() {
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        ./pithead control-run-pending 2>&1)
}
upgrade_intent() { # <id> [version] — drop an upgrade request into the spool
    if [ "$#" -ge 2 ]; then
        printf '{"id":"%s","action":"upgrade","actor":"admin","version":"%s"}\n' "$1" "$2" >"$UPGREQS/$1.json"
    else
        printf '{"id":"%s","action":"upgrade","actor":"admin"}\n' "$1" >"$UPGREQS/$1.json"
    fi
}
UUPG="66666666-6666-4666-8666-666666666666"
reset_upgrade_state() { # restore between attempts: fresh runner copy, running version, no throttle
    cp "$STACK" "$UPG/pithead"
    printf '1.3.1' >"$UPG/VERSION"
    rm -f "$UPG/data/control/staged/.upgrade-stamp" "$UPGRESULTS/$UUPG.json" "$UPG/upgrade-invocations.log"
    rm -f "$UPG"/config.json.bak-upgrade-* "$UPG"/.env.bak-upgrade-* # #637 snapshots
    : >"$UPG/curl.log"
}

# Source checkout ($C): the upgrade verb is refused outright — its update path is `git pull`.
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$REQS/$UUPG.json"
run_pending >/dev/null
assert_eq "upgrade on a source checkout is rejected" "$(jq -r '.status' "$RESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "source-checkout refusal points at git pull" "$(jq -r '.error' "$RESULTS/$UUPG.json" 2>/dev/null)" "git pull"
rm -f "$RESULTS/$UUPG.json"

# Channel off: the runner refuses to process ANYTHING — the intent stays unclaimed, no result.
seed_upgrade_env false
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "upgrade runner refuses when the channel is off" "$?" "1"
assert_contains "channel-off refusal names the flag" "$out" "not enabled"
[ -f "$UPGREQS/$UUPG.json" ] && ok "channel-off intent left unclaimed" || bad "channel-off intent left unclaimed" "claimed"
[ ! -f "$UPGRESULTS/$UUPG.json" ] && ok "channel-off intent gets no result" || bad "channel-off intent gets no result" "result written"
rm -f "$UPGREQS/$UUPG.json"
seed_upgrade_env true

# #1023: no cosign on the host -> refused before a single dial, whether or not this install already
# holds a key. This fixture has NO cosign.pub (it models an install cut before signing engaged),
# which is exactly the shape that used to sail past the old `[ -f cosign.pub ] &&` guard, download
# the bundle, extract it over the install, and only then abort inside the new CLI's image gate.
# Same pinned PATH as its key-holding twin below, so a host cosign can't decide the test.
reset_upgrade_state
ln -sf "$(command -v jq)" "$UPG/bin/jq" # PATH is pinned below, which may not carry jq
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
rm -f "$UPG/bin/jq"
assert_eq "upgrade without a runnable verifier is rejected on a key-less install" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing refusal names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal dials nothing" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
assert_eq "verifier-missing refusal extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "verifier-missing refusal claims no throttle" "$(ls "$UPG/data/control/staged/.upgrade-stamp" 2>/dev/null)" ""

# Malformed / missing version: refused BEFORE any network dial (curl must never run).
reset_upgrade_state
upgrade_intent "$UUPG" 'v9.9.9;curl evil.tld'
urun >/dev/null
assert_eq "shell-metacharacter version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "malformed-version rejection names the field" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "version"
assert_eq "no network dial for a malformed version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
reset_upgrade_state
upgrade_intent "$UUPG"
urun >/dev/null
assert_eq "missing version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_eq "no network dial for a missing version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""

# A smuggled target field (the image-swap vector): the closed key set refuses the whole request.
reset_upgrade_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9","target":"evil.tld/img:tag"}\n' "$UUPG" >"$UPGREQS/$UUPG.json"
urun >/dev/null
assert_contains "upgrade intent smuggling a target is rejected" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "unexpected keys"

# Forged/stale version: the container proposes v1.9.9 but the host-derived latest is v9.9.9 —
# refused, nothing downloaded, nothing extracted. The container cannot choose the target.
reset_upgrade_state
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_eq "container-proposed non-latest version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "forged-version rejection names the real latest" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "forged version downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
assert_eq "forged version leaves the install untouched" "$(cat "$UPG/VERSION")" "1.3.1"
# ...and it still CLAIMED the throttle (stamp taken before the network dial), so a compromised
# container can't flood well-formed-but-stale intents to grind the GitHub API / beacon over Tor:
# a second attempt straight after — without reset — is throttled (#59 review, egress-beacon guard).
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_contains "a non-latest attempt still claims the throttle" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"

# Already up to date: latest equals the running version — refused, no download.
reset_upgrade_state
printf '{"tag_name":"v1.3.1","html_url":"https://example.invalid/rel"}' >"$UPGB/api-same.json"
upgrade_intent "$UUPG" "v1.3.1"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-same.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "same-version upgrade is rejected as up to date" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "already up to date"

# Release API unreachable / unusable: refused, nothing changed (fail closed, silent stack).
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "unreachable release API rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "could not reach"
reset_upgrade_state
printf '{"tag_name":"main","html_url":"https://example.invalid/rel"}' >"$UPGB/api-bad.json"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-bad.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "non-semver API tag rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no usable release tag"

# Bundle download failure AFTER the checks pass: the attempt fails, the stack keeps running.
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/missing.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed bundle download reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "download failure says the stack keeps running" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "keeps running"
assert_eq "download failure extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

# `pithead upgrade` itself fails after extraction: status failed, error points at the host CLI.
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" NEW_PITHEAD_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed upgrade run reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "failed upgrade points at the host CLI" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "./pithead upgrade"
assert_contains "failed upgrade audited" "$(cat "$UPGAUDIT" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"failed\""
# #637: the failure result names the pre-upgrade config/.env copies, and they exist on disk.
upg_bak="$(jq -r '.backup // ""' "$UPGRESULTS/$UUPG.json" 2>/dev/null)"
assert_contains "failed in-place upgrade names the pre-upgrade copies (#637)" "$upg_bak" ".bak-upgrade-"
upg_bak_cfg="${upg_bak%% *}"
[ -n "$upg_bak_cfg" ] && [ -f "$upg_bak_cfg" ] && ok "the named config.json copy exists (#637)" ||
    bad "the named config.json copy exists (#637)" "missing: $upg_bak_cfg"

# Happy path: proposed == host-derived latest and newer than running → bundle extracted, the NEW
# pithead's `upgrade` ran, both dials went through the stack's Tor SOCKS, everything audited.
reset_upgrade_state
: >"$UPGAUDIT"
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "runner exits 0 on a valid upgrade" "$?" "0"
assert_eq "upgrade result status" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "upgrade result carries the host-derived version" "$(jq -r '.version' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "bundle extracted over the install" "$(cat "$UPG/VERSION")" "9.9.9"
assert_contains "the NEW pithead ran the upgrade" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
assert_eq "both GitHub dials went over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050' "$UPG/curl.log")" "2"
# #376 fallback: this install has no cosign.pub, so no signature is fetched — today's behaviour.
assert_eq "no cosign.pub -> no signature dial (documented fallback)" "$(grep -c '\.sig' "$UPG/curl.log" || true)" "0"
assert_contains "upgrade start audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"started\""
assert_contains "upgrade completion audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"upgraded\""
# #544/#555: the extraction above ran over the non-empty build/* dirs pre-seeded near the top of
# this block — this is the regression test for the withdrawn v1.6.0 bug. Pin b12082c's documented
# semantics: pass 1 MERGES directories with plain tar (never purges), so new build/* content lands
# and a stale file the new bundle doesn't carry survives untouched.
assert_eq "build/* new content lands (monero template)" "$(cat "$UPG/build/monero/bitmonero.conf.template" 2>/dev/null)" "new-monero-template-v9.9.9"
assert_eq "build/* new content lands (tari template)" "$(cat "$UPG/build/tari/config.toml.template" 2>/dev/null)" "new-tari-template-v9.9.9"
assert_eq "build/* new content lands (tari-wallet entrypoint)" "$(cat "$UPG/build/tari-wallet/entrypoint.sh" 2>/dev/null)" "new-tari-wallet-entry-v9.9.9"
assert_eq "a stale build/* file absent from the new bundle survives the merge" "$(cat "$UPG/build/monero/leftover.conf" 2>/dev/null)" "leftover-from-a-removed-mount"
# No partial/temp extraction residue after a successful run: the staged bundle + tar log are gone.
if [ ! -e "$UPG/data/control/staged/.$UUPG.tar.gz" ] && [ ! -e "$UPG/data/control/staged/.$UUPG.log" ]; then
    ok "no staged bundle/log residue after a successful upgrade"
else
    bad "no staged bundle/log residue after a successful upgrade" "leftover staging file present"
fi
# #637: before the extraction overwrote the install, the runner kept timestamped copies of the
# operator's config and the rendered .env — the in-place layout's only restore point.
upg_bak_env="$(ls "$UPG"/.env.bak-upgrade-* 2>/dev/null | head -1)"
[ -n "$upg_bak_env" ] && ok "in-place upgrade keeps a pre-upgrade .env copy (#637)" ||
    bad "in-place upgrade keeps a pre-upgrade .env copy (#637)" "no .env.bak-upgrade-* in $UPG"
assert_contains "the .env copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
upg_bak_cfg2="$(ls "$UPG"/config.json.bak-upgrade-* 2>/dev/null | head -1)"
assert_eq "the config.json copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_cfg2" 2>/dev/null)" "{}"

# #637 fail-closed: no snapshot, no upgrade. With config.json unreadable the runner must refuse
# BEFORE a byte of the bundle lands — the whole point of the restore point is that it exists
# before the mutation does.
reset_upgrade_state
mv "$UPG/config.json" "$UPG/config.json.hidden"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "failed snapshot fails the upgrade (#637)" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "snapshot refusal names the missing restore point (#637)" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "restore point"
assert_eq "failed snapshot extracts nothing (#637)" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(ls "$UPG"/.bak-upgrade.* 2>/dev/null)" ] && ok "failed snapshot leaves no mktemp residue (#637)" ||
    bad "failed snapshot leaves no mktemp residue (#637)" "leftover temp file"
mv "$UPG/config.json.hidden" "$UPG/config.json"

# #637 hardening: the snapshot destination name is predictable, so a co-tenant can plant a
# symlink there and hope root writes through it (the #629 attack class) — the runner must
# replace the planted entry, never follow it. And old snapshots hold yesterday's secrets, so
# only the newest three pairs survive. Freeze `date` so the destination name is known.
reset_upgrade_state
cat >"$UPG/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "+%Y%m%d-%H%M%S" ]; then echo "20990101-000000"; else exec /bin/date "$@"; fi
EOF
chmod +x "$UPG/bin/date"
printf 'victim-untouched' >"$UPG/victim"
ln -s "$UPG/victim" "$UPG/config.json.bak-upgrade-20990101-000000"
for bakstamp in 20200101-000000 20200102-000000 20200103-000000; do
    printf 'stale' >"$UPG/.env.bak-upgrade-$bakstamp"
    printf 'stale' >"$UPG/config.json.bak-upgrade-$bakstamp"
done
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "planted symlink at the snapshot name is not written through (#637)" "$(cat "$UPG/victim")" "victim-untouched"
if [ ! -L "$UPG/config.json.bak-upgrade-20990101-000000" ] && [ -f "$UPG/config.json.bak-upgrade-20990101-000000" ]; then
    ok "the snapshot replaced the planted entry with a regular file (#637)"
else
    bad "the snapshot replaced the planted entry with a regular file (#637)" "still a symlink or missing"
fi
assert_eq "snapshots pruned to the newest three .env copies (#637)" "$(ls -1 "$UPG"/.env.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
assert_eq "snapshots pruned to the newest three config.json copies (#637)" "$(ls -1 "$UPG"/config.json.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
[ ! -e "$UPG/.env.bak-upgrade-20200101-000000" ] && ok "the oldest .env snapshot was pruned (#637)" ||
    bad "the oldest .env snapshot was pruned (#637)" "still present"
rm -f "$UPG/bin/date" "$UPG/victim"
reset_upgrade_state

# #376 rollback guard: an attacker who controls the release response serves an OLDER (genuine)
# bundle at the v9.9.9 URL — its VERSION (1.0.0) does not match the host-derived tag, so the
# runner refuses BEFORE extraction. A cosign signature binds bytes, not a version, so without
# this check a validly-signed old bundle would silently downgrade the stack.
reset_upgrade_state
mkdir -p "$UPGB/rollback/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/rollback/pithead/pithead"
printf '1.0.0' >"$UPGB/rollback/pithead/VERSION"
tar -czf "$UPGB/rollback.tar.gz" -C "$UPGB/rollback" pithead
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/rollback.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "version-mismatched (rollback) bundle is refused" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "rollback refusal names the mismatch" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rollback"
assert_eq "rollback bundle extracts nothing (VERSION untouched)" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "rollback bundle never ran a new pithead" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null || echo none)" "none"

# #548: a bundle that gzips fine but carries no pithead/VERSION at all (corrupt download, or a
# hostile non-pithead archive) must fail cleanly — not kill the runner via errexit and leave the
# result stuck at "running" with an orphaned claim and the rest of the queue abandoned.
reset_upgrade_state
mkdir -p "$UPGB/noversion/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/noversion/pithead/pithead"
tar -czf "$UPGB/noversion.tar.gz" -C "$UPGB/noversion" pithead
UUPG2="77777777-7777-4777-8777-777777777777"
upgrade_intent "$UUPG" "v9.9.9"
# The drain orders requests by mtime (ls -1tr); a same-second tie breaks differently between GNU
# (CI) and BSD (macOS) ls, flipping which intent runs first — and the second one is throttled.
# One second between the writes makes "UUPG first" deterministic everywhere.
sleep 1
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG2" >"$UPGREQS/$UUPG2.json"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/noversion.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "bundle missing pithead/VERSION reports failed (not stuck running)" \
    "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-VERSION failure names the cause" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "missing pithead/VERSION"
assert_eq "missing-VERSION bundle extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(find "$UPG/data/control" -maxdepth 1 -name '.claim.*' 2>/dev/null)" ] &&
    ok "missing-VERSION failure releases its claim" || bad "missing-VERSION failure releases its claim" "claim file left behind"
[ -f "$UPGRESULTS/$UUPG2.json" ] &&
    ok "the rest of the queue is not abandoned (second intent still processed)" ||
    bad "the rest of the queue is not abandoned (second intent still processed)" "no result written for the second intent"
rm -f "$UPGRESULTS/$UUPG2.json" "$UPGREQS/$UUPG2.json"

# Throttle: a second attempt straight after is refused for 10 minutes (egress-beacon guard).
# The happy path replaced $U/pithead with the fake bundle's script — restore the real runner
# (keeping the throttle stamp the successful attempt left behind).
cp "$STACK" "$UPG/pithead"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_contains "immediate second upgrade attempt is throttled" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"
reset_upgrade_state

echo "== black-box: control upgrade extracts to a fresh version dir (#629) =="
# A VERSIONED release install (deploy629/pithead-v1.3.1) whose data dirs all resolve OUTSIDE the
# install dir — the documented bundle-deploy layout. The runner must extract v9.9.9 into a fresh
# sibling pithead-v9.9.9/, seed config.json/.env and the install-local state dirs, run the NEW
# dir's pithead upgrade from the new dir, write the result into BOTH spools, and leave this dir
# intact as the rollback copy. Reuses the upgrade59 stubs ($UPG/bin) and fake bundle ($UPGB).
VROOT="$SANDBOX/deploy629"
VUPG="$VROOT/pithead-v1.3.1"
VNEW="$VROOT/pithead-v9.9.9"
mkdir -p "$VUPG/data/control/requests" "$VUPG/data/control/staged" "$VUPG/data/control/results" \
    "$VUPG/data/control/audit" "$VUPG/data/clearnet-state" "$VROOT/data/monero"
cp "$STACK" "$VUPG/pithead"
printf '1.3.1' >"$VUPG/VERSION"
printf '{}' >"$VUPG/config.json"
printf 'clearnet-marker' >"$VUPG/data/clearnet-state/monero.synced"
seed_v629_env() { # data dirs OUTSIDE the install dir → fresh-dir mode
    cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VROOT/data/monero
TARI_DATA_DIR=$VROOT/data/tari
P2POOL_DATA_DIR=$VROOT/data/p2pool
TOR_DATA_DIR=$VROOT/data/tor
DASHBOARD_DATA_DIR=$VROOT/data/dashboard
EOF
}
seed_v629_env
vrun() { # <extra env VAR=val...>
    (cd "$VUPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$VUPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        env "$@" ./pithead control-run-pending 2>&1)
}
reset_v629_state() {
    cp "$STACK" "$VUPG/pithead"
    printf '1.3.1' >"$VUPG/VERSION"
    rm -f "$VUPG/data/control/staged/.upgrade-stamp" "$VUPG/data/control/results/$UUPG.json"
    rm -f "$VUPG"/config.json.bak-upgrade-* "$VUPG"/.env.bak-upgrade-* # #637 snapshots
    rm -rf "$VNEW"
}

# Happy path: fresh sibling dir, seeded state, new pithead ran FROM the new dir, both spools
# carry the result, and the running install — the rollback copy — is byte-for-byte untouched.
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun >/dev/null
assert_eq "fresh-dir upgrade result status (old spool)" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "fresh-dir upgrade result status (new spool)" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "new version dir holds the new release" "$(cat "$VNEW/VERSION" 2>/dev/null)" "9.9.9"
assert_eq "old version dir still holds the old release (rollback preserved)" "$(cat "$VUPG/VERSION")" "1.3.1"
cmp -s "$VUPG/pithead" "$STACK" && ok "old dir's pithead untouched by the extraction" ||
    bad "old dir's pithead untouched by the extraction" "the running script was overwritten"
assert_contains "the NEW pithead ran the upgrade from the NEW dir" "$(cat "$VNEW/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
[ -f "$VNEW/config.json" ] && ok "config.json seeded into the new dir" || bad "config.json seeded into the new dir" "missing"
assert_contains "rendered .env seeded into the new dir" "$(cat "$VNEW/.env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
assert_eq "clearnet sync markers carried over" "$(cat "$VNEW/data/clearnet-state/monero.synced" 2>/dev/null)" "clearnet-marker"
assert_contains "fresh-dir upgrade audited in the old spool" "$(cat "$VUPG/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
assert_contains "fresh-dir upgrade audited in the new spool" "$(cat "$VNEW/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
# #637: the result names the old dir as the restore point (pwd -P tail, macOS /private prefix).
assert_contains "fresh-dir result names the old dir as the rollback copy (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"
[ -z "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" ||
    bad "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" "found .bak-upgrade-* in $VUPG"

# The new release's upgrade fails: both spools say failed, the error points at the NEW dir for
# the host-side finish, and the old install keeps running — still intact for rollback.
reset_v629_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun NEW_PITHEAD_FAIL=1 >/dev/null
assert_eq "failed fresh-dir upgrade reports failed" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
# The runner derives its paths from `pwd -P`, so on macOS the /var/folders sandbox reports as
# /private/var/... — assert on the path's tail, not the unresolved $VNEW.
assert_contains "failed fresh-dir upgrade points at the new dir" "$(jq -r '.error' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v9.9.9 && ./pithead upgrade"
assert_eq "failed fresh-dir upgrade leaves the old install intact" "$(cat "$VUPG/VERSION")" "1.3.1"
assert_eq "failed fresh-dir upgrade wrote the result to the new spool too" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "failed fresh-dir result still names the rollback dir (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"

# Data inside the install dir (the pre-#455 default): a dir swap would strand it — the runner
# must fall back to the in-place path: no sibling dir, the new release lands in THIS dir.
reset_v629_state
mkdir -p "$VUPG/data/monero" # must exist: the guard canonicalizes via cd/pwd -P
cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VUPG/data/monero
EOF
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_eq "data-inside-install falls back to in-place upgrade" "$(cat "$VUPG/VERSION")" "9.9.9"
[ ! -e "$VNEW" ] && ok "data-inside-install creates no sibling version dir" ||
    bad "data-inside-install creates no sibling version dir" "$VNEW exists"
assert_contains "in-place fallback names the stranded data dir" "$out" "MONERO_DATA_DIR resolves inside the install dir"
assert_eq "in-place fallback still upgrades" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
[ -n "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "in-place fallback keeps the pre-upgrade config/.env copies (#637)" ||
    bad "in-place fallback keeps the pre-upgrade config/.env copies (#637)" "no .bak-upgrade-* in $VUPG"
seed_v629_env

# A pre-existing entry at the target path — a leftover failed attempt, or a co-tenant's planted
# dir/symlink (the mkdir-without--p TOCTOU guard): root must never extract into it. The runner
# refuses the fresh-dir path and upgrades in place instead.
reset_v629_state
mkdir -p "$VNEW"
printf 'not-ours' >"$VNEW/marker"
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "pre-existing target dir falls back to in-place" "$out" "already exists"
assert_eq "pre-existing target dir is never written into" "$(
    cat "$VNEW/marker" 2>/dev/null
    ls "$VNEW" | wc -l | tr -d ' '
)" "not-ours1"
assert_eq "pre-existing target still upgrades in place" "$(cat "$VUPG/VERSION")" "9.9.9"
reset_v629_state
mkdir -p "$VROOT/plant"      # the attacker-controlled tree behind the symlink
ln -s "$VROOT/plant" "$VNEW" # a planted symlink must fail the atomic mkdir, not be followed
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "planted symlink at the target falls back to in-place" "$out" "already exists"
[ -z "$(ls -A "$VROOT/plant" 2>/dev/null)" ] && ok "planted symlink is not followed (nothing extracted through it)" ||
    bad "planted symlink is not followed (nothing extracted through it)" "files appeared behind the symlink"
rm -f "$VNEW"
seed_v629_env

echo "== black-box: control upgrade verifies the bundle signature (#376) =="
# Give the install a trust anchor (cosign.pub next to pithead — what a signed release bundle
# ships) plus a runnable verifier; the runner must fetch pithead.tar.gz.sig over the same Tor SOCKS
# and verify the download against the EXISTING key before a byte of it is extracted.
write_fake_docker "$UPG/bin"
printf 'fake release public key' >"$UPG/cosign.pub"
printf 'fake signature' >"$UPGB/bundle.sig"
usign() { # <extra env VAR=val...> — one signed-mode runner invocation
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" COSIGN_LOG="$UPG/cosign.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" \
        env "$@" ./pithead control-run-pending 2>&1)
}

# Valid signature: the upgrade goes through, and the verification demonstrably happened.
: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign >/dev/null
assert_eq "signed bundle with a valid signature upgrades" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "signature fetched over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050.*pithead\.tar\.gz\.sig' "$UPG/curl.log")" "1"
assert_contains "bundle verified against the existing key, no Rekor" \
    "$(cat "$UPG/cosign.log")" "verify-blob --key cosign.pub --signature"
# Bad signature: FAIL CLOSED — nothing extracted, the install untouched. The red test for the
# control path: bypass the verify-blob call and this goes green-to-broken.
reset_upgrade_state
: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign COSIGN_RC=1 >/dev/null
assert_eq "bad bundle signature reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "bad-signature failure says verification FAILED" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "verification FAILED"
assert_eq "bad signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ ! -f "$UPG/upgrade-invocations.log" ] && ok "bad signature never runs the new pithead" || bad "bad signature never runs the new pithead" "it ran"

# Missing signature asset: a signed install refuses a release that carries no .sig (fail closed —
# a stripped signature must not downgrade verification to nothing).
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/missing.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "missing signature asset reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-signature failure names the asset" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no bundle signature"
assert_eq "missing signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

# The other half of the same precondition (#1023): an install that already HOLDS the key is
# refused for the same reason a key-less one is — no runnable verifier, no upgrade — BEFORE the
# download. PATH is pinned to the daemon-down stub + /usr/bin:/bin so a working host docker can't
# leak in; jq rides along as a symlink since the pinned PATH may not carry it.
reset_upgrade_state
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "pubkey without a runnable verifier rejects the upgrade" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing rejection names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
rm -f "$UPG/cosign.pub" "$UPG/nodocker/jq"
reset_upgrade_state

# The runner refuses to run at all when the channel is off (fail-closed).
control_config main
"$C/bin/docker" >/dev/null 2>&1 || true
sed -i.bak 's/"control":{"enabled":true}/"control":{"enabled":false}/' "$C/config.json" 2>/dev/null || true
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
out="$(run_pending)"
assert_rc "runner refuses when the channel is disabled" "$?" "1"
assert_contains "runner disabled message" "$out" "not enabled"
