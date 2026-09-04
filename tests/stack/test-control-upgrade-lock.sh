# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel upgrade lock contention (#1482 item 2): the dashboard's one-click `upgrade` verb
# falls back to an IN-PLACE extraction over the running install whenever the versioned fresh-dir
# layout does not apply. That extraction replaces the whole tree — this script included — BEFORE it
# re-invokes `pithead upgrade`, so the window the re-invoked child takes cannot cover the overwrite.
# Until #1482 item 2 it took no window at all: a one-click upgrade could rewrite the install
# directory while a `backup` or an `apply` held the lock.
#
# Three sections, and the first one is not decoration. A contended run reporting `rejected` is
# equally consistent with a fixture that never armed — this verb has six refusals of its own that
# all write `rejected` — so the positive control has to show the same fixture really does perform
# the in-place overwrite being looked for. The third section proves the window is held ACROSS the
# re-invocation and that the child does not deadlock on its parent's descriptor, which is the
# regression the subshell-plus-marker design would otherwise introduce silently.
# Sourced by tests/stack/run.sh.
#
# This lives beside test-control-upgrade.sh rather than inside it because that file is the tests
# lane's and already 795 lines; the same reason test-appliance-os-update-lock.sh sits beside its
# verbs file.
#
# Re-derivations: $SANDBOX, $STACK, make_stubs, write_fake_docker and the assert_* helpers come from
# lib.sh; every other name is assigned here. Every file in this suite is sourced into ONE shell, so
# nothing here reuses a name test-control-upgrade.sh defines — its $UPG/$UPGB/$UPGREQS/$UUPG and
# urun/upgrade_intent/reset_upgrade_state are deliberately untouched, and this file's are
# $CUL/$CULB/$CULREQS/$UCUL and culrun/cul_intent/cul_reset. Every write lands under $CUL, $CULB or
# $SANDBOX/control-upgrade-held.lock, and nothing outside this file reads what it creates.

: "${SANDBOX:?}"
: "${STACK:?}"

echo "== black-box: a one-click upgrade blocked by another pithead operation changes nothing (#1482) =="
# A RELEASE install (no build/*/Dockerfile, so is_source_checkout is false) with the control channel
# on, in a plain `control-upgrade-lock/` directory — NOT a pithead-vX.Y.Z one, so is_versioned_
# install_dir is false and the verb takes the in-place fallback rather than the fresh-dir deploy.
CUL="$SANDBOX/control-upgrade-lock"
CULREQS="$CUL/data/control/requests"
CULRES="$CUL/data/control/results"
mkdir -p "$CULREQS" "$CULRES" "$CUL/data/control/staged" "$CUL/data/control/audit"
cp "$STACK" "$CUL/pithead"
make_stubs "$CUL/bin"
# The verifier is a PRECONDITION of a one-click upgrade since #1023, so the fixture needs a runnable
# docker even though this install carries no cosign.pub and therefore fetches no signature.
write_fake_docker "$CUL/bin"
printf '1.3.1' >"$CUL/VERSION"
printf '{}' >"$CUL/config.json" # the in-place path snapshots config.json before extracting (#637)
mkdir -p "$CUL/build/monero"
printf 'stale-monero-template-v1.3.1\n' >"$CUL/build/monero/bitmonero.conf.template"
cat >"$CUL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$CUL/data/control
NETWORK_PREFIX=10.9.0
EOF
cat >"$CUL/bin/curl" <<'EOF'
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
*releases/download/*) cp "${CURL_BUNDLE:?}" "$out" ;;
*) exit 22 ;;
esac
exit 0
EOF
chmod +x "$CUL/bin/curl"
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}' >"$CUL/api.json"

# The fake v9.9.9 bundle. Its `pithead` records that it was re-invoked and what it could see of the
# window it was invoked inside: a non-empty PITHEAD_LOCK_HELD, and whether the lock file is still
# taken. Both are what stop a re-invoked child blocking on its own parent's descriptor.
CULB="$SANDBOX/control-upgrade-lock-bundle"
mkdir -p "$CULB/pithead/build/monero"
cat >"$CULB/pithead/pithead" <<'EOF'
#!/usr/bin/env bash
{
    echo "new-pithead $*"
    echo "marker=${PITHEAD_LOCK_HELD:-UNSET}"
    if exec 8>>"${PITHEAD_LOCK_FILE:-$PWD/.pithead.lock}" && flock -n 8; then
        echo "window=FREE"
    else
        echo "window=HELD"
    fi
} >>"$PWD/upgrade-invocations.log"
exit 0
EOF
chmod +x "$CULB/pithead/pithead"
printf '9.9.9' >"$CULB/pithead/VERSION"
printf 'new-monero-template-v9.9.9\n' >"$CULB/pithead/build/monero/bitmonero.conf.template"
tar -czf "$CULB/bundle.tar.gz" -C "$CULB" pithead

culrun() { # [env pairs...] — drain the spool inside the release sandbox
    (cd "$CUL" && PATH="$CUL/bin:$PATH" CURL_API_RESPONSE="$CUL/api.json" \
        CURL_BUNDLE="$CULB/bundle.tar.gz" env "$@" ./pithead control-run-pending 2>&1)
}
cul_intent() { printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$1" >"$CULREQS/$1.json"; }
UCUL="77777777-7777-4777-8777-777777777777"
cul_st() { jq -r '.status' "$CULRES/$UCUL.json" 2>/dev/null; }
cul_err() { jq -r '.error' "$CULRES/$UCUL.json" 2>/dev/null; }
cul_reset() { # restore the pre-upgrade install between attempts
    cp "$STACK" "$CUL/pithead"
    printf '1.3.1' >"$CUL/VERSION"
    printf 'stale-monero-template-v1.3.1\n' >"$CUL/build/monero/bitmonero.conf.template"
    rm -f "$CUL/data/control/staged/.upgrade-stamp" "$CULRES/$UCUL.json" "$CUL/upgrade-invocations.log"
    rm -f "$CUL"/config.json.bak-upgrade-* "$CUL"/.env.bak-upgrade-*
}
# Sets CULHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks until that holder's stdout closes, i.e. for its whole lifetime.
CULHOLDER=""
cul_hold() { # <lockfile> -> sets CULHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    CULHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the lock window" "the lock is still free — the contended case would prove nothing"
    fi
}

# Positive control: the same fixture really does perform the in-place overwrite. Without it, every
# assertion below is equally consistent with a request that was refused at one of this verb's six
# other `rejected` doors and never reached the extraction at all.
cul_reset
cul_intent "$UCUL"
culrun >/dev/null
assert_eq "uncontended: the in-place upgrade reports upgraded" "$(cul_st)" "upgraded"
assert_contains "uncontended: the new release's pithead was re-invoked" "$(cat "$CUL/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
assert_eq "uncontended: the install dir really was overwritten" "$(cat "$CUL/VERSION")" "9.9.9"
assert_eq "uncontended: the new bundle's build/* landed" "$(cat "$CUL/build/monero/bitmonero.conf.template")" "new-monero-template-v9.9.9"
assert_eq "uncontended: a pre-upgrade snapshot was kept (#637)" \
    "$(find "$CUL" -maxdepth 1 -name 'config.json.bak-upgrade-*' | wc -l | tr -d ' ')" "1"
# The window is HELD across the re-invocation, and the child can tell: an inherited marker is what
# stops it opening a second descriptor on its parent's lock and blocking on it.
assert_not_contains "uncontended: the re-invoked child inherited the lock marker" "$(cat "$CUL/upgrade-invocations.log")" "marker=UNSET"
assert_contains "uncontended: and the window was still held while it ran" "$(cat "$CUL/upgrade-invocations.log")" "window=HELD"

# The claim: the same input, with the machine held by another pithead operation.
CULLK="$SANDBOX/control-upgrade-held.lock"
cul_hold "$CULLK"
cul_reset
cul_intent "$UCUL"
cul_out=$(culrun PITHEAD_LOCK_FILE="$CULLK" PITHEAD_LOCK_TIMEOUT=1)
assert_eq "contended: the upgrade is rejected, not failed" "$(cul_st)" "rejected"
assert_contains "contended: the reason says it was never started" "$(cul_err)" "never started"
assert_contains "contended: the reason says nothing was changed" "$(cul_err)" "nothing was changed"
assert_contains "contended: and it names the throttle the attempt still costs" "$(cul_err)" "ten-minute upgrade throttle"
assert_eq "contended: the new release's pithead was never re-invoked" "$(cat "$CUL/upgrade-invocations.log" 2>/dev/null)" ""
assert_eq "contended: the install dir was not overwritten" "$(cat "$CUL/VERSION")" "1.3.1"
assert_eq "contended: the new bundle's build/* did not land" "$(cat "$CUL/build/monero/bitmonero.conf.template")" "stale-monero-template-v1.3.1"
assert_eq "contended: no pre-upgrade snapshot was written either" \
    "$(find "$CUL" -maxdepth 1 -name 'config.json.bak-upgrade-*' | wc -l | tr -d ' ')" "0"
# The runner is long-lived and serves one request at a time: mutation_lock_acquire EXITS on timeout,
# so an unabsorbed exit kills it mid-request and leaves this result at the "running" it wrote before
# the download. Asserting only that a result FILE exists cannot fail for that reason — the "running"
# one is already on disk by then — so the assertion is that the runner got far enough to overwrite
# it with a verdict.
assert_not_contains "contended: the result is not left stranded at running" "$(cul_st)" "running"
assert_not_contains "contended: nothing tells the operator the upgrade ran and broke" "$cul_out" "failed to extract"
kill "$CULHOLDER" 2>/dev/null || true
