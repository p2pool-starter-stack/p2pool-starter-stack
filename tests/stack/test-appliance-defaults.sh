# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance defaults domain (#1105 Phase 1, appliance lane): two sections covering what a first
# boot writes into a config the operator did not finish. apply_appliance_defaults fills tor
# .auto_heal only where the key is ABSENT — an operator who wrote false meant it — and turns the
# dashboard control channel on only when a password is actually present, because the appliance has
# no shell and no ssh, so the channel is the only way to change a payout address, and an enabled
# channel with an empty password is the exact pair parse_and_validate_config refuses (#1066). The
# last case walks the documented "No login" first-boot sequence in the order the appliance runs it
# and asserts the forbidden pair is never produced.
# Sourced by tests/stack/run.sh.
#
# DISCLOSURE — the opening section is a provisioning preflight, and the file name does not say so.
# preflight_remote_nodes (dial every configured remote node before provisioning commits; name the
# host:port and point at the grpc_lan_access switch on failure) is thematically PROVISIONING and
# belongs beside test-control-provisioning.sh. It is here because contiguity outranks the label:
# the test-appliance-identity.sh source stanza sits BETWEEN that section and the provisioning
# block, and moving this section across it would make the provisioning cut non-contiguous — which
# would break the order-preserving-concat proof this whole split rests on. Ruled by the controller
# rather than assumed; a 14-line file of its own is below any sensible floor. Direct precedent:
# Phase 2's 21-doctor-stack-checks.sh carries three non-doctor helpers for the same reason.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Re-derivations. This file reads NO ambient name: every variable it reads it assigns itself —
# $PFSB and $ADSB (both mktemp -d, both removed and unset at the end of their section) and $out.
# Provider functions called: run_sourced, assert_rc, assert_eq, assert_contains. There is
# deliberately no `: "${NAME:?}"` guard line, because there is nothing to guard. $PFSB is also
# assigned in test-appliance-install.sh — its own mktemp -d, unset at the end of its own section.
# That is a name reused downstream, not a value shared with it, and that file assigns before it
# reads either way.

echo "== unit: preflight_remote_nodes dials before provisioning commits =="
mk_tmpdir PFSB
printf '{"monero":{"mode":"local"},"tari":{"mode":"local"}}' >"$PFSB/local.json"
run_sourced "$PFSB" preflight_remote_nodes "$PFSB/local.json" >/dev/null 2>&1
assert_rc "all-local config -> nothing to dial, rc 0" "$?" "0"
# 127.0.0.1:1 — reliably closed; the dial must fail fast and NAME the endpoint.
printf '{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"127.0.0.1","grpc_port":1}}}' >"$PFSB/bad.json"
out=$(run_sourced "$PFSB" preflight_remote_nodes "$PFSB/bad.json" 2>/dev/null)
assert_rc "unreachable remote Tari -> rc 1" "$?" "1"
assert_contains "failure names host and port" "$out" "127.0.0.1:1"
assert_contains "failure points at the LAN-access switch" "$out" "grpc_lan_access"

# The ZMQ half. A TCP connect proves reachability and NOTHING else, and on the ZMQ port that gap
# is load-bearing: docker's userland proxy binds a published host port and accepts the connection
# itself, so a containerised node whose publisher failed to bind answers the dial rc 0. The
# verdict is pure over the greeting the peer sent, so every failure class is a fixture here
# rather than a socket. The first is CAPTURED from a live monerod; the rest are the shapes a
# live node will not produce.
PFZ_LIVE=ff00000000000000017f03014e554c4c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
PFZ_HTTP=485454502f312e312034303020426164205265717565737400000000000000000000000000000000000000000000000000000000000000000000000000000000
PFZ_ZMTP2=ff00000000000000007f01004e554c4c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_LIVE"
assert_rc "a live monerod greeting is accepted" "$?" "0"
# THE case the dial cannot see: an accept() with no greeting is a published-but-dead port.
run_sourced "$PFSB" zmq_greeting_ok ""
assert_rc "an accept() that sends no greeting is refused" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "ff0000"
assert_rc "a truncated greeting is refused, not read past its end" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_HTTP"
assert_rc "a listener that is not ZMQ at all is refused" "$?" "1"
run_sourced "$PFSB" zmq_greeting_ok "$PFZ_ZMTP2"
assert_rc "a ZMTP 2 peer is refused — the READY exchange needs 3.x" "$?" "1"

# Wiring, both directions, with no socket: stub `timeout` so every dial answers rc 0 and the
# greeting read returns whatever the case supplies. An empty return is exactly the
# published-but-dead shape — reachable, and nothing behind it.
printf '{"monero":{"mode":"remote","remote":{"host":"127.0.0.1","rpc_port":18081,"zmq_port":18083}},"tari":{"mode":"local"}}' >"$PFSB/zmq.json"
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() { return 0; }
    # #1889 added an RPC protocol leg to the same config. Stub it PASSING so this case still
    # measures the ZMTP greeting alone — otherwise it would go green off the new leg's failure
    # and stop testing the thing it names.
    monero_rpc_speaks() { return 0; }
    preflight_remote_nodes "$PFSB/zmq.json" 2>/dev/null
)
assert_rc "reachable but no ZMTP greeting -> rc 1" "$?" "1"
assert_contains "the refusal says nothing there speaks ZMQ" "$out" "speaks ZMQ"
assert_contains "the refusal names the ZMQ port" "$out" "18083"
# The same run with a live greeting must PASS, or the case above would go green against a
# preflight that refuses everything.
out=$(
    cd "$PFSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    timeout() {
        case "$*" in *"od -An"*) printf '%s' "$PFZ_LIVE" ;; esac
        return 0
    }
    monero_rpc_speaks() { return 0; }
    preflight_remote_nodes "$PFSB/zmq.json" 2>/dev/null
)
assert_rc "reachable AND greeting -> rc 0" "$?" "0"
rm -rf "$PFSB"
unset PFSB out PFZ_LIVE PFZ_HTTP PFZ_ZMTP2

echo "== unit: the node probe reports WHAT it checked, not only that a port answered =="
# #1889. The dial proves a port ANSWERED. Until now the Monero RPC port got nothing further, so a
# wrong service on 18081 passed the whole preflight while the ZMQ port beside it was genuinely
# protocol-checked. These cases pin the reason mapping and the report contract.
mk_tmpdir NPB
# monero_rpc_speaks' verdict is reached through `timeout`, so every failure class is a stub here
# rather than a socket — the same technique the ZMQ cases above use, and for the same reason.
np_reason() { # <stub-rc> [body]; prints the reason the RPC leg lands on
    (
        cd "$NPB" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        eval "timeout() { ${2:+printf '%s' '$2'; }return $1; }"
        monero_rpc_speaks 10.0.0.1 18081
        printf '%s' "$NODE_PROBE_REASON"
    )
}
assert_eq "a well-formed get_info is the only pass" "$(np_reason 0 '{"status":"OK"}')" "ok"
assert_eq "a listener that answers but is not monerod reads as protocol, not unreachable" \
    "$(np_reason 0 '<html>nope</html>')" "protocol"
# Valid JSON that is not an OK status. This is the case `.status == "OK"` exists for, and it is
# the one a wrong-service fixture CANNOT reach: non-JSON fails jq's parse whatever the filter
# says, so a mutation replacing the status test with `true` survived a suite that only ever fed
# it HTML. A real monerod answers exactly this shape while it is busy or erroring.
assert_eq "JSON that is not an OK status is refused, not accepted as well-formed" \
    "$(np_reason 0 '{"status":"BUSY"}')" "protocol"
assert_eq "a refused connection reads as refused" "$(np_reason 7)" "refused"
assert_eq "an RPC that demands credentials reads as auth, never as success" "$(np_reason 22)" "auth"
assert_eq "a node that never answers reads as timeout" "$(np_reason 28)" "timeout"
# A reason the mapping does not know must still be NAMED. The page that will switch on this enum
# is #1888 — nothing reads it yet — and its default arm has to be unreachable, so an unmapped code
# becomes `unknown` rather than a silently-wrong neighbour.
assert_eq "an unmapped failure is named unknown, not guessed" "$(np_reason 99)" "unknown"

# THE DETAIL OVERRIDES ARE WHAT THIS ISSUE SHIPS, and np_reason above cannot reach them: it calls
# monero_rpc_speaks directly, so it never enters node_probe_one and never sees the sentence the
# operator is actually shown. Deleting the whole override block survived that suite. Here only
# `timeout` is stubbed — the real reason mapping, the real override block and the real row
# builder all run, so a row is judged by what an operator would read off it.
NPZ_LIVE=ff00000000000000017f03014e554c4c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
NPZ_HTTP=485454502f312e312034303020426164205265717565737400000000000000000000000000000000000000000000000000000000000000000000000000000000
np_row() { # <checked> <stub-rc> [stdout]; prints the row node_probe_one emits
    (
        cd "$NPB" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        eval "timeout() { ${3:+printf '%s' '$3'; }return $2; }"
        node_probe_one monero 10.0.0.1 18083 "$1" "cannot reach it — check the host, the port, and that the node allows LAN access"
    )
}
row=$(np_row rpc 0 '<html>nope</html>')
assert_eq "a wrong service on the RPC port reaches the row as protocol" \
    "$(printf '%s' "$row" | jq -r .reason)" "protocol"
assert_contains "and the operator is told the port is OPEN and the service behind it is wrong" \
    "$(printf '%s' "$row" | jq -r .detail)" "does not speak monerod's RPC"
assert_not_contains "not that the node is unreachable, which would send them to a fine network" \
    "$(printf '%s' "$row" | jq -r .detail)" "cannot reach"
row=$(np_row rpc 22)
assert_eq "an RPC demanding credentials reaches the row as auth" \
    "$(printf '%s' "$row" | jq -r .reason)" "auth"
assert_contains "and the sentence says WHY Pithead will not accept it" \
    "$(printf '%s' "$row" | jq -r .detail)" "nowhere to store remote-node credentials"
# The OUTER timeout returns 124; curl's own is 28, and only 28 was ever fed. `| 124` was text a
# deletion would have survived.
assert_eq "the outer bound firing (124) is a timeout, not an unmapped failure" \
    "$(printf '%s' "$(np_row rpc 124)" | jq -r .reason)" "timeout"
# A missing curl exits 127. It used to land in `unknown` — "we do not know why the node is
# unreachable" said about a probe that never ran. The enum names it now; the SENTENCE is still
# the generic reach wording, which is a known gap, not a fixed one.
assert_eq "a missing curl is named, not folded into unknown" \
    "$(printf '%s' "$(np_row rpc 127)" | jq -r .reason)" "missing-tool"

# ⛔ REGRESSION GUARD. The ZMQ leg forced `protocol` for EVERY failure, so a refused port was
# reported with a sentence asserting it had answered — the dishonesty this issue exists to remove,
# written backwards. zmq_endpoint_greets returns 1 for a refused dial and a bad greeting alike, so
# the two classes must be shown to produce DIFFERENT answers, in the enum and in the sentence.
row=$(np_row zmq 1)
assert_eq "a REFUSED ZMQ port reads as refused, not as a protocol failure" \
    "$(printf '%s' "$row" | jq -r .reason)" "refused"
assert_contains "and the operator is sent to the network path, which is where the fault is" \
    "$(printf '%s' "$row" | jq -r .detail)" "cannot reach"
assert_not_contains "and is NOT told the port answered, because it did not" \
    "$(printf '%s' "$row" | jq -r .detail)" "speaks ZMQ"
assert_eq "a ZMQ port that never answers in time reads as timeout" \
    "$(printf '%s' "$(np_row zmq 124)" | jq -r .reason)" "timeout"
row=$(np_row zmq 0 "$NPZ_HTTP")
assert_eq "a ZMQ port answering the wrong protocol still reads as protocol" \
    "$(printf '%s' "$row" | jq -r .reason)" "protocol"
assert_contains "and THAT is the row that says the port answered but nothing speaks ZMQ" \
    "$(printf '%s' "$row" | jq -r .detail)" "speaks ZMQ"
# The positive control: the same fixture must be able to produce a PASS, or every assertion above
# is equally consistent with a probe that refuses everything.
row=$(np_row zmq 0 "$NPZ_LIVE")
assert_eq "a live ZMTP peer passes, and the pass says which check was made" \
    "$(printf '%s' "$row" | jq -r '[.ok,.reason,.checked] | @csv')" 'true,"ok","zmq"'
unset row NPZ_LIVE NPZ_HTTP

np_report() { # <config-json>; prints the report with both network legs stubbed PASSING
    printf '%s' "$1" >"$NPB/c.json"
    (
        cd "$NPB" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        monero_rpc_speaks() { return 0; }
        zmq_endpoint_greets() { return 0; }
        timeout() { return 0; }
        node_probe_report "$NPB/c.json"
    )
}
out=$(np_report '{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"10.0.0.1","grpc_port":18142}}}')
assert_eq "a Tari pass says the protocol was NOT checked" \
    "$(printf '%s' "$out" | jq -r '.probes[0].checked')" "connect"
assert_contains "and says so in words, not only in a field" "$out" "NOT checked"
# THE ROLL-UP, both directions. `all()` over an empty array is TRUE, so a consumer deriving the
# gate from the probe list alone reads a run that probed NOTHING as a pass. But "nothing probed"
# is also the correct state of an all-local machine. Only `configured` separates them.
out=$(np_report '{"monero":{"mode":"local"},"tari":{"mode":"local"}}')
assert_eq "0 probed of 0 configured is a PASS — an all-local machine has nothing to reach" \
    "$(printf '%s' "$out" | jq -c '[.ok,.configured,.probed]')" "[true,0,0]"
# Fault injection: the config asks for three endpoints and the probe emits no rows. This is the
# shape the empty-array roll-up would have called a pass.
out=$(
    printf '{"monero":{"mode":"remote","remote":{"host":"10.0.0.1"}},"tari":{"mode":"remote","remote":{"host":"10.0.0.1"}}}' >"$NPB/c.json"
    cd "$NPB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    node_probe_one() { return 0; }
    node_probe_report "$NPB/c.json"
)
assert_eq "0 probed of 3 configured is a FAILURE, not a vacuous pass" \
    "$(printf '%s' "$out" | jq -c '[.ok,.configured,.probed]')" "[false,3,0]"
# Both Monero legs, both failing, with DIFFERENT reasons: the enum has to survive into the report
# rather than only into the variable, and no assertion read `.probes[].reason` out of a report at
# all. This is also the only case that produces two real rows for one chain.
out=$(
    printf '{"monero":{"mode":"remote","remote":{"host":"10.0.0.1","rpc_port":18081,"zmq_port":18083}},"tari":{"mode":"local"}}' >"$NPB/r.json"
    cd "$NPB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    monero_rpc_speaks() {
        NODE_PROBE_REASON="auth"
        return 1
    }
    zmq_endpoint_greets() {
        NODE_PROBE_REASON="refused"
        return 1
    }
    node_probe_report "$NPB/r.json"
)
assert_eq "each leg's reason reaches the report, and the two do not collapse into one" \
    "$(printf '%s' "$out" | jq -c '[.probes[].reason]')" '["auth","refused"]'
assert_eq "a chain with two failing legs counts both and is not ok" \
    "$(printf '%s' "$out" | jq -c '[.ok,.configured,.probed]')" "[false,2,2]"
rm -rf "$NPB"
unset NPB out

echo "== unit: appliance defaults (tor.auto_heal) =="
# Applied only where ABSENT: an operator who wrote false meant it.
mk_tmpdir ADSB
printf '{"monero":{"wallet_address":"x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "absent auto_heal -> enabled" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "true"
printf '{"tor":{"auto_heal":false}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "explicit false is respected" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "false"
printf '{"tor":{"data_dir":"/x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "other tor keys survive" "$(jq -r '.tor.data_dir' "$ADSB/config.json")" "/x"

# dashboard.control.enabled had NO coverage, which is how #1066 shipped. The appliance turns the
# control channel on because it has no other way in — but only behind a login, because an
# unauthenticated config editor can change the payout wallet and run `apply`, which is exactly
# what parse_and_validate_config refuses. The wizard's strip_defaults drops any answer equal to
# the reference default, and the reference has control.enabled false, so the key is absent from
# EVERY submission: injecting unconditionally built the forbidden pair on the "No login" answer
# and dead-ended first boot after the operator was told provisioning had started.
printf '{"dashboard":{"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a password present -> the control channel is turned on" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
printf '{"dashboard":{"auth":{"password":""}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "no password -> the control channel is NOT turned on (#1066)" "$(jq -r '.dashboard.control.enabled // "absent"' "$ADSB/config.json")" "absent"
printf '{"dashboard":{"control":{"enabled":false},"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "an explicit control.enabled false is respected" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "false"
# The whole first-boot sequence for the documented "No login" answer, in the order the appliance
# runs it. The invariant is the one the validator enforces: this machine must never hand itself a
# config carrying an enabled control channel and no password.
mkdir -p "$ADSB/spool"
printf 'none' >"$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "\"No login\" leaves the password empty, as asked" "$(jq -r '.dashboard.auth.password // ""' "$ADSB/config.json")" ""
assert_eq "\"No login\" never produces the pair the validator refuses (#1066)" \
    "$(jq -r 'if (.dashboard.control.enabled == true) and ((.dashboard.auth.password // "") == "") then "forbidden-pair" else "ok" end' "$ADSB/config.json")" "ok"
# ...and the same sequence WITH a login still ends up configurable, which is the whole reason the
# appliance turns the channel on: no shell, no ssh, no other way to change a payout address.
rm -f "$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a generated login leaves the machine configurable" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
rm -rf "$ADSB"
unset ADSB
