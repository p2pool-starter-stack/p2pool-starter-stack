# shellcheck shell=bash
#
# Reset-verb lock wiring (#1482): factory-reset, config-reset and reset-dashboard each take the
# mutation lock, and take it in the one place that is correct. Sourced by tests/stack/run.sh.
#
# SCOPE, stated so this is not read as duplicating test-lifecycle.sh. That file proves the lock
# MECHANISM — the holder record, the announced wait, the refusal, the rc, the release — driven
# through `stack_down`. None of it says whether any OTHER verb is wired to that mechanism, and the
# three reset verbs were not: they mutated the machine holding nothing. So what is asserted here is
# WIRING and PLACEMENT, one verb at a time, and nothing about how the lock itself behaves. The rc
# assertions are the cheapest proof that a verb reaches mutation_lock_acquire at all, not a second
# opinion on the exit status.
#
# PLACEMENT is the half a plain "does it take the lock" test would miss, and it is pinned from both
# sides. Before the first mutation: on a held machine each verb must leave config.json, the ESP
# marker, the containers and the data directories exactly as it found them, because the refusal
# tells the operator nothing was changed and that has to be literally true. After the confirmation:
# a verb given the wrong confirmation word on a held machine must abort on the word, not sit in the
# lock wait — the hold must never span a human wait. Move the acquire past the first mutation and
# the first group fails; move it above the prompt and the second does.
#
# Every case runs against a POSITIVE CONTROL that the same fixture, uncontended, really does perform
# the mutation being looked for. Without that, "config.json is still here" is equally consistent with
# a fixture that never armed — and the two read identically.
#
# This lives beside test-appliance-reset.sh rather than inside it because tests/stack ceilings only
# go down, and the sibling-file shape is the one #1514 established for the os-install half of #1482.
#
# Re-derivations: $SANDBOX, $STACK, make_stubs, bad and the assert_* helpers come from lib.sh; every
# other name is assigned here, under an RSL/rsl_ prefix chosen because test-lifecycle.sh already
# owns $RL and both files are sourced into ONE shell. Unlike its sibling this file needs no $WALLET
# seed: config-reset only checks that config.json EXISTS before removing it, and the other two verbs
# never read it, so no case here writes a wallet address of any kind.

: "${SANDBOX:?}"
: "${STACK:?}"

RSL="$SANDBOX/reset-lock"
RSLBIN="$RSL/bin"
mkdir -p "$RSLBIN" "$RSL/esp" "$RSL/envdir/dashboard" "$RSL/envdir/p2pool"
cp "$STACK" "$RSL/pithead"
make_stubs "$RSLBIN"
# lib.sh's sudo stub is a silent `exit 0`, which is what keeps the wipe from running for real — but
# it also means the deletion leaves no trace to assert on. Log it instead: the sudo line is the
# observation point for "did this verb delete a data directory", in both directions.
cat >"$RSLBIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >>"${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$RSLBIN/sudo"

RSLFREE="$SANDBOX/reset-lock-free.lock" # never held: the positive controls run through it
RSLHELD="$SANDBOX/reset-lock-held.lock" # held by rsl_hold for the contended cases
RSLDOCKER="$RSL/docker.log"
RSLSUDO="$RSL/sudo.log"
RSLMARKER="$RSL/esp/pithead-reset"
RSLREBOOTED="$RSL/.rebooted"

rsl_seed() { # a provisioned box with clean logs: re-armed before EVERY run, contended or not
    printf '{}\n' >"$RSL/config.json"
    cat >"$RSL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$RSL/envdir/dashboard
P2POOL_DATA_DIR=$RSL/envdir/p2pool
EOF
    : >"$RSL/Caddyfile"
    mkdir -p "$RSL/envdir/dashboard" "$RSL/envdir/p2pool"
    rm -f "$RSLMARKER" "$RSLREBOOTED"
    : >"$RSLDOCKER"
    : >"$RSLSUDO"
}

rsl_run() { # <lock file> <extra env pairs...> -- <verb args...>
    local lk="$1" env_pairs=()
    shift
    while [ "$1" != "--" ]; do
        env_pairs+=("$1")
        shift
    done
    shift
    (cd "$RSL" && PATH="$RSLBIN:$PATH" DOCKER_LOG="$RSLDOCKER" SUDO_LOG="$RSLSUDO" \
        PITHEAD_LOCK_FILE="$lk" PITHEAD_PRESEED_DIR="$RSL/esp" \
        PITHEAD_REBOOT_CMD="touch $RSLREBOOTED" \
        env "${env_pairs[@]}" ./pithead "$@" 2>&1)
}

# Sets RSLHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks the substitution for that holder's whole lifetime. `exec sleep` rather than a plain
# one so the holder is a single killable process owning the descriptor.
RSLHOLDER=""
rsl_hold() { # <lock file> -> sets RSLHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    RSLHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the lock window" "the lock is still free — every contended case below would prove nothing"
    fi
}

echo "== black-box: the fixture arms — uncontended, each reset verb performs its mutation (#1482) =="
# Read every assertion here as the control for its contended twin further down. Each one names the
# mutation that must NOT happen once the machine is held.
rsl_seed
rsl_out=$(rsl_run "$RSLFREE" PITHEAD_APPLIANCE=0 -- reset-dashboard -y)
rsl_rc=$?
assert_rc "uncontended reset-dashboard succeeds" "$rsl_rc" "0"
assert_contains "uncontended reset-dashboard really removes the containers" "$(cat "$RSLDOCKER")" "compose rm -s -f -v dashboard p2pool"
assert_contains "uncontended reset-dashboard really deletes the .env data directory" "$(cat "$RSLSUDO")" "rm -rf $RSL/envdir/dashboard"

rsl_seed
rsl_out=$(rsl_run "$RSLFREE" PITHEAD_APPLIANCE=1 -- factory-reset -y)
rsl_rc=$?
assert_rc "uncontended factory-reset succeeds" "$rsl_rc" "0"
assert_eq "uncontended factory-reset really arms the ESP marker AND reboots" \
    "$([ -f "$RSLMARKER" ] && [ -f "$RSLREBOOTED" ] && echo armed-and-rebooting)" "armed-and-rebooting"

rsl_seed
rsl_out=$(rsl_run "$RSLFREE" PITHEAD_APPLIANCE=0 -- config-reset -y)
rsl_rc=$?
assert_rc "uncontended config-reset succeeds" "$rsl_rc" "0"
assert_eq "uncontended config-reset really removes config.json" "$([ -f "$RSL/config.json" ] || echo gone)" "gone"
assert_contains "uncontended config-reset really stops the stack" "$(cat "$RSLDOCKER")" "compose down"

echo "== black-box: a held machine refuses all three reset verbs and changes nothing (#1482) =="
rsl_hold "$RSLHELD"

rsl_seed
rsl_out=$(rsl_run "$RSLHELD" PITHEAD_APPLIANCE=0 PITHEAD_LOCK_TIMEOUT=1 -- reset-dashboard -y)
rsl_rc=$?
assert_rc "contended reset-dashboard refuses rather than interleaving with the held window" "$rsl_rc" "75"
assert_contains "contended reset-dashboard tells the operator which verb to re-run" "$rsl_out" "reset-dashboard' once it has finished"
assert_eq "contended reset-dashboard removes no container" "$(grep -c 'compose rm' "$RSLDOCKER" || true)" "0"
assert_eq "contended reset-dashboard deletes no data directory" "$(grep -c 'rm -rf' "$RSLSUDO" || true)" "0"

rsl_seed
rsl_out=$(rsl_run "$RSLHELD" PITHEAD_APPLIANCE=1 PITHEAD_LOCK_TIMEOUT=1 -- factory-reset -y)
rsl_rc=$?
assert_rc "contended factory-reset refuses rather than interleaving with the held window" "$rsl_rc" "75"
assert_contains "contended factory-reset tells the operator which verb to re-run" "$rsl_out" "factory-reset' once it has finished"
assert_eq "contended factory-reset arms no ESP marker" "$([ -f "$RSLMARKER" ] || echo none)" "none"
assert_eq "contended factory-reset does not reboot the box" "$([ -f "$RSLREBOOTED" ] || echo no)" "no"

rsl_seed
rsl_out=$(rsl_run "$RSLHELD" PITHEAD_APPLIANCE=0 PITHEAD_LOCK_TIMEOUT=1 -- config-reset -y)
rsl_rc=$?
assert_rc "contended config-reset refuses rather than interleaving with the held window" "$rsl_rc" "75"
assert_contains "contended config-reset tells the operator which verb to re-run" "$rsl_out" "config-reset' once it has finished"
assert_eq "contended config-reset KEEPS config.json" "$([ -f "$RSL/config.json" ] && echo kept)" "kept"
assert_eq "contended config-reset KEEPS the rendered .env" "$([ -f "$RSL/.env" ] && echo kept)" "kept"
assert_eq "contended config-reset KEEPS the rendered Caddyfile" "$([ -f "$RSL/Caddyfile" ] && echo kept)" "kept"
assert_eq "contended config-reset never stops the stack" "$(grep -c 'compose down' "$RSLDOCKER" || true)" "0"

echo "== black-box: the reset window opens AFTER the confirmation, so no hold spans a human wait (#1482) =="
# The other side of the placement. Each verb is given the wrong confirmation word while the machine
# is held: it must come back on the WORD, having never entered the lock wait. If the acquire were
# moved above the prompt these three would time out instead — and an operator answering "no" would
# have been made to wait for a window the verb was about to decline to use.
rsl_seed
rsl_out=$(printf 'n\n' | rsl_run "$RSLHELD" PITHEAD_APPLIANCE=0 PITHEAD_LOCK_TIMEOUT=1 -- reset-dashboard)
assert_contains "reset-dashboard declined on a held machine reports the decline" "$rsl_out" "Reset cancelled"
assert_not_contains "reset-dashboard never waited for the window it was not going to use" "$rsl_out" "Timed out"

rsl_seed
rsl_out=$(printf 'nope\n' | rsl_run "$RSLHELD" PITHEAD_APPLIANCE=1 PITHEAD_LOCK_TIMEOUT=1 -- factory-reset)
assert_contains "factory-reset declined on a held machine reports the decline" "$rsl_out" "Aborted"
assert_not_contains "factory-reset never waited for the window it was not going to use" "$rsl_out" "Timed out"

rsl_seed
rsl_out=$(printf 'nope\n' | rsl_run "$RSLHELD" PITHEAD_APPLIANCE=0 PITHEAD_LOCK_TIMEOUT=1 -- config-reset)
assert_contains "config-reset declined on a held machine reports the decline" "$rsl_out" "Aborted"
assert_not_contains "config-reset never waited for the window it was not going to use" "$rsl_out" "Timed out"

kill "$RSLHOLDER" 2>/dev/null || true
wait "$RSLHOLDER" 2>/dev/null || true
