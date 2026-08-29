# shellcheck shell=bash
#
# Appliance defaults domain (#1105 Phase 1, develop-v2 lane): two sections covering what a first
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
PFSB=$(mktemp -d)
printf '{"monero":{"mode":"local"},"tari":{"mode":"local"}}' >"$PFSB/local.json"
run_sourced "$PFSB" preflight_remote_nodes "$PFSB/local.json" >/dev/null 2>&1
assert_rc "all-local config -> nothing to dial, rc 0" "$?" "0"
# 127.0.0.1:1 — reliably closed; the dial must fail fast and NAME the endpoint.
printf '{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"127.0.0.1","grpc_port":1}}}' >"$PFSB/bad.json"
out=$(run_sourced "$PFSB" preflight_remote_nodes "$PFSB/bad.json" 2>/dev/null)
assert_rc "unreachable remote Tari -> rc 1" "$?" "1"
assert_contains "failure names host and port" "$out" "127.0.0.1:1"
assert_contains "failure points at the LAN-access switch" "$out" "grpc_lan_access"
rm -rf "$PFSB"
unset PFSB out

echo "== unit: appliance defaults (tor.auto_heal) =="
# Applied only where ABSENT: an operator who wrote false meant it.
ADSB=$(mktemp -d)
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
