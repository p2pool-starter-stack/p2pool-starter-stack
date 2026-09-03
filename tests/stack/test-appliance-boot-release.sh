# shellcheck shell=bash
#
# The post-commit release of the held chain services retries, keeps its order, and alerts (#1684).
# A data_migration update boots with the chain services held; once the slot commits, pithead-boot
# releases them with `./pithead up`. On the bench that `up` landed while p2pool — started by the
# held `up` — was mid-stop, compose aborted the WHOLE start on podman's "container state improper",
# and the swallowed failure left every held service down under a dashboard reading `updated`;
# nothing retried short of a reboot a committed appliance has no reason to take. The release is now
# `release_held_chain_services`, above pithead-boot's sourcing boundary and driven here with a
# stubbed `pithead` that fails a scripted number of times: the `up` is retried a bounded number of
# times, the markers go BEFORE the first try, the release line (the tier-4 battery's commit
# boundary) prints BEFORE the first `up`, and the last failure is one named FAULT line on stderr,
# never a failed boot. The call site is below the boundary and asserted by the script's text.
# Sourced by tests/stack/run.sh.

echo "== unit: release_held_chain_services — the post-commit up is retried, ordered, and alerted (#1684) =="
RL="$SANDBOX/boot-release"
rm -rf "$RL"
mkdir -p "$RL"
# The stub fails its first N calls and succeeds after. Every call appends to the order file, which
# also takes the function's stdout, so the file reads as the sequence of events.
rl_stub() { # <fails-before-success>
    cat >"$RL/pithead" <<EOF
#!/usr/bin/env bash
echo "up:\$*" >>"$RL/order"
n=\$(cat "$RL/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$RL/calls"
[ "\$n" -gt $1 ]
EOF
    chmod +x "$RL/pithead"
}
rl_run() { # <fails-before-success> <tries> -> "rc=N"; stdout lands in order, stderr in err
    rl_stub "$1"
    rm -f "$RL/calls" "$RL/order" "$RL/err"
    touch "$RL/.os-migration-pending" "$RL/.os-data-floor.prev"
    (
        cd "$RL" || exit 1
        export PITHEAD_RELEASE_UP_TRIES="$2" PITHEAD_RELEASE_UP_PAUSE=0
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        release_held_chain_services >>"$RL/order" 2>"$RL/err"
        echo "rc=$?"
    )
}

# Positive control first: a first-try success is one up, no retry line, no fault, markers gone.
rl_out=$(rl_run 0 5)
assert_eq "an up that succeeds first time releases with rc 0" "$rl_out" "rc=0"
assert_eq "and calls up exactly once" "$(cat "$RL/calls")" "1"
assert_not_contains "no retry is announced when none happened" "$(cat "$RL/order")" "retrying"
assert_eq "no fault is alerted" "$(wc -c <"$RL/err" | tr -d ' ')" "0"
assert_eq "the migration marker is consumed by the release" \
    "$([ -f "$RL/.os-migration-pending" ] && echo present || echo gone)" "gone"
assert_eq "and the floor record with it (the commit-side removal, #1393)" \
    "$([ -f "$RL/.os-data-floor.prev" ] && echo present || echo gone)" "gone"
# The order the tier-4 battery keys on: the release line marks the commit boundary in the journal
# and must land BEFORE the first up, whose start can take minutes.
assert_eq "the release line prints BEFORE the first up" "$(head -n1 "$RL/order")" \
    "pithead-boot: slot committed — chain services released, the data migration runs now"
assert_eq "and the up follows it" "$(sed -n '2p' "$RL/order")" "up:up"

# #1684 itself: two transitional failures, then the stack comes up. Mutation run: drop the loop
# (one bare up) -> the rc row goes red; drop the announcement -> the count row goes red.
rl_out=$(rl_run 2 5)
assert_eq "an up that fails twice on a transitional container still releases (rc 0)" "$rl_out" "rc=0"
assert_eq "it took exactly three ups — the two failures and the success" "$(cat "$RL/calls")" "3"
assert_eq "each failure short of the last try is announced" "$(grep -c 'retrying in' "$RL/order")" "2"
assert_contains "and the announcement counts the try" "$(cat "$RL/order")" "(try 2 of 5)"
assert_eq "no fault is alerted for a release that succeeded" "$(wc -c <"$RL/err" | tr -d ' ')" "0"

# Bounded: every try fails. The markers still went first (the next boot takes the normal path),
# the fault is alerted ONCE on stderr naming the recovery, and the function returns 1 — the caller's
# `|| true` is what keeps the boot from failing, asserted by text below.
rl_out=$(rl_run 99 3)
assert_eq "a stack that never comes up returns 1 after the last try" "$rl_out" "rc=1"
assert_eq "and it tried exactly PITHEAD_RELEASE_UP_TRIES times" "$(cat "$RL/calls")" "3"
assert_eq "the last failure is not followed by a retry announcement" "$(grep -c 'retrying in' "$RL/order")" "2"
assert_eq "the fault is alerted exactly once" "$(grep -c 'FAULT' "$RL/err")" "1"
assert_contains "the alert says the migration has NOT run" "$(cat "$RL/err")" "the data migration has NOT run"
assert_contains "and names the recovery" "$(cat "$RL/err")" "run './pithead up' from /data/pithead"
assert_eq "the marker was still consumed — re-holding would gate on a commit that already happened" \
    "$([ -f "$RL/.os-migration-pending" ] && echo present || echo gone)" "gone"

# The shipped defaults: five tries ten seconds apart. The bench's transition lasted under a second;
# forty seconds of patience is nothing against a boot unit that runs with TimeoutStartSec=infinity.
rl_defaults=$(
    cd "$RL" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    echo "$RELEASE_UP_TRIES/$RELEASE_UP_PAUSE"
)
assert_eq "the shipped defaults are five tries, ten seconds apart" "$rl_defaults" "5/10"

# The call site sits below the sourcing boundary, so its wiring is asserted by the script's text:
# the hold-chain commit block calls the function and tolerates its failure, and no bare, un-retried
# `./pithead up || true` — the original defect — is back on the release path.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
assert_eq "the hold-chain commit block calls release_held_chain_services and tolerates its failure" \
    "$(grep -cE '^\s*\[ "\$hold_chain" = 1 \] && \{ release_held_chain_services \|\| true; \}' "$BOOTSCRIPT" || true)" "1"
assert_eq "no bare, un-retried up remains on the release path" \
    "$(grep -cE '^\s*\./pithead up \|\| true' "$BOOTSCRIPT" || true)" "0"
unset -f rl_stub rl_run
unset RL rl_out rl_defaults BOOTSCRIPT
