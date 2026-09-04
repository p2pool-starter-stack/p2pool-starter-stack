# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
#
# #1443, the wiring half. test-lifecycle.sh's lock_reinvoke_probe cases prove the MECHANISM — a
# marker mutation_lock_acquire exports survives a real process boundary. They do not prove the
# WIRING at the three places that actually build a re-invoked child: run_chain's
# `bash "$self" "$c"`, control_lifecycle's `"$self" restart` / `"$self" apply -y`, and
# control_backup's `"$self" backup -y`.
#
# lock_reinvoke_probe's own child is sourced and hand-called (`bash -c 'source "$1"; stack_down'`),
# never through main()'s dispatch — and because it is sourced, the _STACK_SOURCED guard means
# PITHEAD_SELF is never assigned in it at all. Each site's pre-existing coverage elsewhere points
# PITHEAD_SELF at a stub that only records its argv, so the re-invoked pithead never runs and the
# lock code inside it never executes — a child that dropped the marker would look identical.
#
# Drive all three for real instead: PITHEAD_SELF points at a COPY of $STACK — a real, executable
# pithead, not a stub — so each site's own re-invocation runs the genuine child through main()'s
# dispatch. The control is the one those mechanism cases use: strip the marker and the SAME real
# re-invocation must block on its own ancestor instead of proceeding.

echo "== domain: the re-invoked-child marker is wired at all three re-invocation sites (#1443) =="

RWDIR="$SANDBOX/reinvoke-wiring"
mkdir -p "$RWDIR"
cp "$STACK" "$RWDIR/pithead"
cp "$ROOT/docker-compose.yml" "$RWDIR/docker-compose.yml"
RWBIN="$RWDIR/bin"
make_stubs "$RWBIN"
cat >"$RWDIR/.env" <<'EOF'
DEPLOYMENT_COMPLETED=true
EOF
# A config valid enough to clear parse_and_validate_config, so `backup -y` reaches
# mutation_lock_acquire instead of refusing on unrelated grounds before ever getting there.
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
  "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"},
  "dashboard":{"secure":true,"host":"box.lan",
               "auth":{"username":"admin","password":"a control passphrase"},
               "control":{"enabled":true}} }\n' "$VALID_PRIMARY" "$VALID_TARI" >"$RWDIR/config.json"
RWDOCKER="$RWDIR/docker.log"

reinvoke_wiring_probe() { # <site: chain|restart|backup> <1=keep marker|0=strip> -> "<applied?>|<blocked-on-the-lock?>"
    local site="$1" keep="$2" reqid="req"
    local cdir="$RWDIR/ctrl-$site-$keep"
    mkdir -p "$cdir/staged" "$cdir/results" "$cdir/audit"
    (
        cd "$RWDIR" || exit 9
        export PITHEAD_LOCK_FILE="$RWDIR/$site-$keep.lock" PITHEAD_LOCK_TIMEOUT=1
        export PATH="$RWBIN:$PATH" DOCKER_LOG="$RWDOCKER" PITHEAD_SELF="$RWDIR/pithead"
        # shellcheck disable=SC1090
        source "$STACK"
        # The stack script sets `set -Eeuo pipefail` at its top; sourcing it turns errexit on HERE too.
        # Same note as on lock_reinvoke_probe in test-lifecycle.sh.
        set +e
        mutation_lock_acquire ancestor
        [ "$keep" = 1 ] || unset PITHEAD_LOCK_HELD
        : >"$RWDOCKER"
        local applied=no blocked=no err=""
        case "$site" in
        chain)
            # run_chain's own fail-fast path is `exit "$rc"`, not `return` — run it in its own
            # subshell so that exit only ends the chain step, not this whole probe.
            (run_chain down) >/dev/null 2>&1
            [ "$?" -eq 0 ] && applied=yes
            # run_chain's own step never reports a rc other than the child's, so the lock's
            # refusal is read off the one place it actually lands: no `compose down` ever ran.
            [ -s "$RWDOCKER" ] || blocked=yes
            ;;
        restart)
            control_lifecycle restart "$reqid" tester "$cdir" >/dev/null 2>&1
            [ "$(jq -r .status "$cdir/results/$reqid.json" 2>/dev/null)" = "applied" ] && applied=yes
            [ -s "$RWDOCKER" ] || blocked=yes
            ;;
        backup)
            # Unlike restart, stack_backup calls docker (a `compose ps` running-check) BEFORE it
            # ever reaches mutation_lock_acquire, so an empty docker log would not discriminate
            # here — that call happens whether the marker is kept or stripped. What is unique to
            # the strip case is the timeout message mutation_lock_acquire itself prints into the
            # child's captured log, which control_backup carries into the result's error field.
            control_backup "$reqid" tester "$cdir" >/dev/null 2>&1
            [ "$(jq -r .status "$cdir/results/$reqid.json" 2>/dev/null)" = "applied" ] && applied=yes
            err="$(jq -r '.error // ""' "$cdir/results/$reqid.json" 2>/dev/null)"
            case "$err" in *"Timed out after"*"waiting for another pithead operation"*) blocked=yes ;; esac
            ;;
        esac
        printf '%s|%s\n' "$applied" "$blocked"
    ) 2>/dev/null
}
assert_eq "run_chain's real (unstubbed) re-invocation proceeds on the inherited marker" \
    "$(reinvoke_wiring_probe chain 1)" "yes|no"
assert_eq "and without it the SAME real chain step blocks on its own ancestor instead" \
    "$(reinvoke_wiring_probe chain 0)" "no|yes"
assert_eq "control_lifecycle's real (unstubbed) restart proceeds on the inherited marker" \
    "$(reinvoke_wiring_probe restart 1)" "yes|no"
assert_eq "and without it the SAME real restart blocks on its own ancestor instead" \
    "$(reinvoke_wiring_probe restart 0)" "no|yes"
assert_eq "control_backup's real (unstubbed) 'backup -y' proceeds on the inherited marker" \
    "$(reinvoke_wiring_probe backup 1)" "yes|no"
assert_eq "and without it the SAME real backup blocks on its own ancestor instead" \
    "$(reinvoke_wiring_probe backup 0)" "no|yes"
