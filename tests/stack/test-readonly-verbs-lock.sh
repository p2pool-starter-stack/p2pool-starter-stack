# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
#
# The other half of the mutation window (#1734, carried out of #1482). Every mutating verb has a
# test proving it TAKES the window; nothing proved that a read-only verb takes nothing and never
# waits. docs/operations.md states that property to the operator, so it is a documented contract,
# and it holds today only because nobody has written `mutation_lock_acquire` into a read-only
# path. Nothing stops the next one: the acquire is one line and it reads as defensive. A stray
# one fails in the most expensive direction there is — `status`, `doctor` and `logs` are exactly
# what an operator reaches for WHILE a long mutating verb runs, so it turns the diagnostic into a
# wait during the incident it was meant to diagnose, and it would pass every other test here.
#
# Behavioural, not a grep for an absent call: `doctor` and `status` read .env and the compose
# state, so what is asserted is that they COMPLETE under contention, not that a particular line
# is missing from a particular function.

echo "== domain: read-only verbs complete while the mutation window is held (#1734) =="

ROV="$SANDBOX/readonly-lock"
ROVLK="$SANDBOX/readonly-lock-held.lock"
mkdir -p "$ROV/bin"
cp "$STACK" "$ROV/pithead"
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node,local_tari\nHOST_IP=box.lan\n' >"$ROV/.env"

# One docker stub for all three verbs. `info` fails so `doctor` reaches a critical FAIL and still
# runs to its summary — the completion is the claim, not the verdict; the three compose/inspect
# queries feed `status` from $FAKE_STATES; everything else exits 0, which is what `logs` needs.
cat >"$ROV/bin/docker" <<'EOF'
#!/usr/bin/env bash
sub="$*"
case "$sub" in
"info") exit 1 ;;
"compose config --services")
    for kv in $FAKE_STATES; do echo "${kv%%=*}"; done ;;
"compose ps -aq "*)
    svc="${sub##* }"
    for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$svc" ] && [ "${kv#*=}" != "missing" ] && echo "$svc"
    done ;;
"inspect "*)
    cid="${sub##* }"
    for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$cid" ] && echo "${kv#*=}" | tr ':' ' '
    done ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$ROV/bin/sudo"
chmod +x "$ROV/bin/docker" "$ROV/bin/sudo"

ROV_STATES="tor=running:healthy monerod=running:healthy p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"

# Sets ROV_OUT/ROV_RC rather than echoing them: a caller wrapping this in `$(...)` would run it in
# a subshell, and the rc — half of every assertion below — would never come back.
ROV_OUT=""
ROV_RC=""
rov_run() { # <lockfile|""> <verb> [args...] -> sets ROV_OUT, ROV_RC
    local lk="$1"
    shift
    # ONE invocation for both legs, and that is structural rather than tidy: the whole proof is
    # "same fixture, same command, only the lock differs". Two invocation lines could be edited
    # apart, and the contended leg would then be asserting against a different fixture.
    local -a rov_env=("FAKE_STATES=$ROV_STATES" "PATH=$ROV/bin:$PATH")
    if [ -n "$lk" ]; then
        rov_env+=("PITHEAD_LOCK_FILE=$lk" "PITHEAD_LOCK_TIMEOUT=1")
    fi
    ROV_OUT="$(cd "$ROV" && env "${rov_env[@]}" ./pithead "$@" 2>&1)"
    ROV_RC=$?
}

# Sets ROVHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks until that holder's stdout closes, i.e. for its whole lifetime.
ROVHOLDER=""
rov_hold() { # <lockfile> -> sets ROVHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    ROVHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the mutation window" "the lock is still free — every contended case below would prove nothing"
    fi
}

# Positive control, and it is the one that makes the rest mean anything: a verb that returns
# quickly because it failed for its own reasons reads identically to one that correctly never
# waited. So first prove each verb PRODUCES ITS OUTPUT here, uncontended, and assert on that same
# output under contention rather than on the exit alone.
rov_run "" status
assert_rc "uncontended: status exits 0" "$ROV_RC" "0"
assert_contains "uncontended: status really produced its summary" "$ROV_OUT" "All expected services are up"
rov_run "" doctor
assert_rc "uncontended: doctor exits 1 on the unreachable daemon" "$ROV_RC" "1"
assert_contains "uncontended: doctor really ran to its summary" "$ROV_OUT" "Diagnostics summary"
rov_run "" logs
assert_rc "uncontended: logs exits 0" "$ROV_RC" "0"
assert_contains "uncontended: logs really reached the follow" "$ROV_OUT" "Following logs"

rov_hold "$ROVLK"

# Negative control: the fixture can fire. Without this every contended PASS below is equally
# consistent with PITHEAD_LOCK_FILE never having pointed at the held lock at all — the verbs would
# complete for the wrong reason and the whole domain would go green over a lock nobody was holding.
# `down` takes the window as its first act, so nothing else can be what stopped it.
rov_run "$ROVLK" down
assert_contains "control: a MUTATING verb does see the held window" "$ROV_OUT" "Another pithead operation is in progress"
assert_contains "control: and it gives up rather than running" "$ROV_OUT" "Timed out after"
assert_rc "control: the mutating verb exits with the lock-timeout status" "$ROV_RC" "75"
assert_not_contains "control: the mutating verb stopped before doing anything" "$ROV_OUT" "Stopping stack"

# The claim. Same fixture, same held lock, same one-second timeout the control just timed out on.
rov_run "$ROVLK" status
assert_rc "contended: status still exits 0" "$ROV_RC" "0"
assert_contains "contended: status still produced its summary" "$ROV_OUT" "All expected services are up"
assert_not_contains "contended: status never announced a wait" "$ROV_OUT" "Another pithead operation is in progress"
assert_not_contains "contended: status never timed out" "$ROV_OUT" "Timed out after"

rov_run "$ROVLK" doctor
assert_rc "contended: doctor still exits on its own verdict" "$ROV_RC" "1"
assert_contains "contended: doctor still ran to its summary" "$ROV_OUT" "Diagnostics summary"
assert_not_contains "contended: doctor never announced a wait" "$ROV_OUT" "Another pithead operation is in progress"
assert_not_contains "contended: doctor never timed out" "$ROV_OUT" "Timed out after"

rov_run "$ROVLK" logs
assert_rc "contended: logs still exits 0" "$ROV_RC" "0"
assert_contains "contended: logs still reached the follow" "$ROV_OUT" "Following logs"
assert_not_contains "contended: logs never announced a wait" "$ROV_OUT" "Another pithead operation is in progress"
assert_not_contains "contended: logs never timed out" "$ROV_OUT" "Timed out after"

kill "$ROVHOLDER" 2>/dev/null

# The enumeration that cannot silently shrink. A hand-written list of read-only verbs goes stale
# the moment one is added, so the set to partition is READ FROM the shipped script —
# PITHEAD_COMMANDS, which test-cli.sh already holds equal to both the dispatch case labels and the
# completion list. Every verb it knows must fall in exactly one of the two sets below, so a verb
# added tomorrow lands in neither and reds this rather than passing unseen.
#
# ROV_UNCLAIMED is a floor, not a finding: it is what this domain makes NO claim about, not a set
# shown to mutate. Some of it is very likely read-only too; nothing here says so either way.
ROV_PROVEN="logs status doctor"
ROV_UNCLAIMED="setup apply render up down restart upgrade support-bundle reset-dashboard config-reset factory-reset backup restore uninstall firstboot-wizard load-images local-miner os-update control-run-pending onion-client-key rotate-dashboard-onion rotate-secrets render-quadlet version help"

rov_cmds="$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    printf '%s' "${PITHEAD_COMMANDS:-}"
)"
# The read is what every row below rests on, so it is asserted as a MEASUREMENT rather than as the
# absence of a sentinel. A size is the only shape here that cannot pass on an empty read: the
# `unsorted` row iterates $rov_cmds, so an empty read makes it PASS with nothing compared, and the
# phantom-appending control at the foot of this block adds its probe verb to the literal rather
# than to the read, so it reports non-empty either way. The `phantom` row does red on an empty
# read, but the headline claim resting on a sibling row catching the case by accident is not the
# same as the headline claim being checked.
rov_n_read="$(printf '%s' "$rov_cmds" | wc -w)"
rov_n_sets="$(printf '%s' "$ROV_PROVEN $ROV_UNCLAIMED" | wc -w)"
assert_eq "totality: the dispatch verb list was read from the script, and holds as many verbs as the two sets" "$rov_n_read" "$rov_n_sets"

rov_unsorted=""
for c in $rov_cmds; do
    case " $ROV_PROVEN $ROV_UNCLAIMED " in *" $c "*) ;; *) rov_unsorted="$rov_unsorted $c" ;; esac
done
assert_eq "totality: every dispatch verb is either proven here or explicitly out of scope" "${rov_unsorted# }" ""

rov_phantom=""
for c in $ROV_PROVEN $ROV_UNCLAIMED; do
    case " $rov_cmds " in *" $c "*) ;; *) rov_phantom="$rov_phantom $c" ;; esac
done
assert_eq "totality: neither set names a verb the dispatch does not have" "${rov_phantom# }" ""

rov_both=""
for c in $ROV_PROVEN; do
    case " $ROV_UNCLAIMED " in *" $c "*) rov_both="$rov_both $c" ;; esac
done
assert_eq "totality: a verb is never both proven and out of scope" "${rov_both# }" ""

# The empty results above are only evidence once the comparison behind them has been shown able to
# say something else. Same loop, same sets, one verb the dispatch does not have. Its limit, stated
# because it is the weak point: the probe verb is a literal, so this control fires even on an
# empty read — it shows the comparison can speak, never that the read contributed to it. The
# control for THAT case is the second one below.
rov_probe=""
for c in $rov_cmds pithead-verb-that-does-not-exist; do
    case " $ROV_PROVEN $ROV_UNCLAIMED " in *" $c "*) ;; *) rov_probe="$rov_probe $c" ;; esac
done
assert_eq "control: the totality check does report a verb that is in neither set" "${rov_probe# }" "pithead-verb-that-does-not-exist"

# The control the one above cannot be: the size comparison, run over an empty read. This is the
# case the headline totality row is weakest on, so the row is only evidence once the comparison
# has been shown to come apart there.
rov_n_empty="$(printf '%s' "" | wc -w)"
if [ "$rov_n_empty" = "$rov_n_sets" ]; then rov_empty_verdict="SAME"; else rov_empty_verdict="DIFFERS"; fi
assert_eq "control: on an empty read the totality size comparison comes apart, so that row can fail" "$rov_empty_verdict" "DIFFERS"
