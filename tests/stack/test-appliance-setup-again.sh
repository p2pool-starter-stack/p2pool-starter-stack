# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The boot menu's "Set up again" entry, host side (#1318): the switch pithead-setup-again.service
# sets, what the wizard publishes to the page under it, what "Keep it" does, and how a role's data
# follows a role change — the tier-1 half of what the KVM rig phase proves end to end (the entry
# boots, the page opens beside the role, the token survives a Keep and an unchanged Set-up-again).
# Sourced by tests/stack/run.sh. Every function under test resolves inside run_sourced's subshell,
# which sources $STACK for itself; $SASB and its captures are unset at the end. The tier-1 rows
# for rig_access_token itself are in test-appliance-rig-miner.sh (#1836) and are not repeated.

echo "== unit: publish_saved_role — the page is told what the machine is, secrets left out (#1318) =="
mk_tmpdir SASB
mkdir -p "$SASB/spool" "$SASB/bin"
printf 'rig\n' >"$SASB/machine-role"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","stratum_password":"pw-fixture","access_token":"kept-token-fixture-for-shed-3"}' >"$SASB/rig.json"
printf '{"worker":"probe-host","pool":"pithead.local:3333"}' >"$SASB/spool/rig-defaults.json"
run_sourced "$SASB" publish_saved_role "$SASB/spool" >/dev/null 2>&1
assert_rc "no switch -> rc 0 (a no-op on a first boot, never an error)" "$?" "0"
[ -e "$SASB/spool/saved-role.json" ] && bad "no switch -> nothing published (presence IS the signal)" "saved-role.json exists" ||
    ok "no switch -> nothing published (presence IS the signal)"
assert_eq "no switch -> the LAN probe's pre-fill is left alone" "$(jq -r '.worker' "$SASB/spool/rig-defaults.json")" "probe-host"
PITHEAD_SETUP_AGAIN=1 run_sourced "$SASB" publish_saved_role "$SASB/spool" >/dev/null 2>&1
assert_eq "rig: the saved role, pool and worker" "$(jq -c '[.role,.pool,.worker]' "$SASB/spool/saved-role.json")" '["rig","10.0.0.5:3333","shed-3"]'
assert_eq "rig: no secret crosses — exactly role, pool, worker" "$(jq -c 'keys' "$SASB/spool/saved-role.json")" '["pool","role","worker"]'
assert_eq "rig: the form's pre-fill is the SAVED pool + worker, not the probe's" "$(jq -c '[.pool,.worker]' "$SASB/spool/rig-defaults.json")" '["10.0.0.5:3333","shed-3"]'
assert_eq "no temp file beside either atomic target" "$(find "$SASB/spool" -name '.*.json.*' | wc -l | tr -d ' ')" "0"
rm -f "$SASB/machine-role" "$SASB/rig.json" "$SASB/spool/saved-role.json"
printf '{"monero":{"wallet":"4fixture"},"dashboard":{"auth":{"username":"admin","password":"hunter2"}}}' >"$SASB/config.json"
PITHEAD_SETUP_AGAIN=1 run_sourced "$SASB" publish_saved_role "$SASB/spool" >/dev/null 2>&1
assert_eq "coordinator: the role (an absent marker is pithead)" "$(jq -r '.role' "$SASB/spool/saved-role.json")" "pithead"
assert_eq "coordinator: the form pre-fills from config.json" "$(jq -r '.monero.wallet' "$SASB/spool/last-attempt.json")" "4fixture"
assert_eq "coordinator: ...with the login stripped (the reinstall rule)" "$(jq -r '.dashboard | has("auth")' "$SASB/spool/last-attempt.json")" "false"
printf '{"monero":{"wallet":"4retry"}}' >"$SASB/spool/last-attempt.json"
PITHEAD_SETUP_AGAIN=1 run_sourced "$SASB" publish_saved_role "$SASB/spool" >/dev/null 2>&1
assert_eq "an existing last-attempt.json (a failed retry's context) is never overwritten" "$(jq -r '.monero.wallet' "$SASB/spool/last-attempt.json")" "4retry"

echo "== unit: wizard_keep_requested — Keep it ends the session with nothing touched (#1318) =="
run_sourced "$SASB" wizard_keep_requested "$SASB/spool" >/dev/null 2>&1
assert_rc "no switch, no marker -> rc 1" "$?" "1"
: >"$SASB/spool/keep-role"
run_sourced "$SASB" wizard_keep_requested "$SASB/spool" >/dev/null 2>&1
assert_rc "a marker with no switch -> rc 1 (a stale marker cannot close a first boot)" "$?" "1"
[ -e "$SASB/spool/keep-role" ] && ok "...and the marker is left alone" || bad "...and the marker is left alone" "consumed"
PITHEAD_SETUP_AGAIN=1 run_sourced "$SASB" wizard_keep_requested "$SASB/spool" >/dev/null 2>&1
assert_rc "switch + marker -> rc 0: the caller returns" "$?" "0"
[ -e "$SASB/spool/keep-role" ] && bad "the marker is consumed" "still present" || ok "the marker is consumed"
PITHEAD_SETUP_AGAIN=1 run_sourced "$SASB" wizard_keep_requested "$SASB/spool" >/dev/null 2>&1
assert_rc "consumed -> rc 1 again (one keep per marker)" "$?" "1"
assert_eq "config.json is untouched by a keep" "$(jq -r '.monero.wallet' "$SASB/config.json")" "4fixture"

echo "== unit: a role's data follows the role — record_machine_role and the kept token (#1318) =="
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"kept-token-fixture-for-shed-3"}' >"$SASB/rig.json"
run_sourced "$SASB" record_machine_role rig >/dev/null 2>&1
[ -f "$SASB/rig.json" ] && ok "accepting rig keeps rig.json" || bad "accepting rig keeps rig.json" "removed"
run_sourced "$SASB" record_machine_role both >/dev/null 2>&1
[ -f "$SASB/rig.json" ] && bad "accepting a coordinator role removes rig.json (and the token in it)" "still present" ||
    ok "accepting a coordinator role removes rig.json (and the token in it)"
assert_eq "...and the marker still lands" "$(cat "$SASB/machine-role")" "both"
# firstboot_consume_rig: the token survives when role AND worker are unchanged; any other worker
# carries nothing, and rig_access_token mints anew on the next render. timeout is a PATH stub so
# the pool dial answers deterministically (the rig-miner domain's fixture).
printf '#!/bin/bash\nexit 0\n' >"$SASB/bin/timeout"
chmod +x "$SASB/bin/timeout"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3","access_token":"kept-token-fixture-for-shed-3"}' >"$SASB/rig.json"
printf '{"pool":"10.0.0.9:3333","worker":"shed-3"}' >"$SASB/spool/rig-request.json"
PATH="$SASB/bin:$PATH" run_sourced "$SASB" firstboot_consume_rig "$SASB/spool" >/dev/null 2>&1
assert_rc "same worker, new pool -> accepted" "$?" "0"
assert_eq "same worker: the token is KEPT (the coordinator adopted this worker with it)" "$(jq -r '.access_token' "$SASB/rig.json")" "kept-token-fixture-for-shed-3"
assert_eq "...and the new pool landed" "$(jq -r '.pool' "$SASB/rig.json")" "10.0.0.9:3333"
printf '{"pool":"10.0.0.9:3333","worker":"shed-4"}' >"$SASB/spool/rig-request.json"
PATH="$SASB/bin:$PATH" run_sourced "$SASB" firstboot_consume_rig "$SASB/spool" >/dev/null 2>&1
assert_eq "a changed worker: no token carried — the next render mints a fresh one" "$(jq -r 'has("access_token")' "$SASB/rig.json")" "false"
rm -f "$SASB/rig.json"
printf '{"pool":"10.0.0.9:3333","worker":"shed-4"}' >"$SASB/spool/rig-request.json"
PATH="$SASB/bin:$PATH" run_sourced "$SASB" firstboot_consume_rig "$SASB/spool" >/dev/null 2>&1
assert_eq "no previous rig.json (a first boot): no token key, exactly as before #1318" "$(jq -r 'has("access_token")' "$SASB/rig.json")" "false"
rm -rf "$SASB"
unset SASB

echo "== unit: firstboot_wizard under the switch — the role short-circuits are skipped (#1318) =="
# Reaching the page path is observed at export_build_provenance, the first DIRECT call past both
# short-circuits (a stub inside a $(...) would only exit its own subshell); the stub exits 7. The
# no-switch runs are the sibling controls: the same fixture takes the rig leg (rc 0, the miner's
# setup logged) or runs setup (stubbed, rc 5) exactly as before #1318.
mk_tmpdir SAWB
mk_tmpdir SAESP
mkdir -p "$SAWB/rigforge"
printf '#!/usr/bin/env bash\necho "rigforge:$1" >>"${RF_LOG:?}"\n' >"$SAWB/rigforge/rigforge.sh"
chmod +x "$SAWB/rigforge/rigforge.sh"
export PITHEAD_PRESEED_DIR="$SAESP" PITHEAD_RIGFORGE_DIR="$SAWB/rigforge" RF_LOG="$SAWB/calls"
SAW_STUBS='container_engine() { echo podman; }; export_build_provenance() { echo page-path-reached; exit 7; }; setup() { echo setup-ran; exit 5; }; firstboot_wizard'
printf 'rig\n' >"$SAWB/machine-role"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$SAWB/rig.json"
: >"$RF_LOG"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$SAWB" eval "$SAW_STUBS" 2>&1)
assert_rc "no switch: a marked rig takes the rig leg and returns" "$?" "0"
assert_contains "...the miner's setup ran, the page path was never reached" "$(cat "$RF_LOG")" "rigforge:setup"
assert_not_contains "...(control: the stub CAN be reached, and was not)" "$out" "page-path-reached"
: >"$RF_LOG"
out=$(PITHEAD_SETUP_AGAIN=1 PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$SAWB" eval "$SAW_STUBS" 2>&1)
assert_rc "switch: the rig short-circuit is skipped and the page path is reached" "$?" "7"
assert_contains "...by name" "$out" "page-path-reached"
assert_not_contains "...and the rig leg did not run beside it" "$(cat "$RF_LOG")" "rigforge:setup"
assert_eq "...the marker is untouched" "$(cat "$SAWB/machine-role")" "rig"
assert_eq "...rig.json is untouched" "$(jq -r '.worker' "$SAWB/rig.json")" "shed-3"
rm -f "$SAWB/machine-role" "$SAWB/rig.json"
printf '{"monero":{"wallet":"4fixture"}}' >"$SAWB/config.json"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$SAWB" eval "$SAW_STUBS" 2>&1)
assert_rc "no switch: a present config.json short-circuits into setup" "$?" "5"
out=$(PITHEAD_SETUP_AGAIN=1 PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$SAWB" eval "$SAW_STUBS" 2>&1)
assert_rc "switch: config.json does not short-circuit — the page path is reached" "$?" "7"
assert_not_contains "...and setup did not run" "$out" "setup-ran"
unset PITHEAD_PRESEED_DIR PITHEAD_RIGFORGE_DIR RF_LOG SAW_STUBS
rm -rf "$SAWB" "$SAESP"
echo "== unit: write_handoff_card — the credentials card is owner-only from its first byte (#1842) =="
# The card carries the login or the rig's control token. Both controls remove what a lazy fix would
# lean on: the caller's umask is permissive and chmod is a no-op, so only the helper's own umask can
# produce 600; and a 644 card from an earlier attempt must be REPLACED, since a redirect keeps its mode.
mk_tmpdir HCSB
mkdir -p "$HCSB/spool"
printf '{"role":"rig","token":"tok-1"}' | run_sourced "$HCSB" eval 'umask 022; chmod() { :; }; write_handoff_card "$HCSB/spool"'
assert_rc "writing the card -> rc 0" "$?" "0"
assert_eq "the card is 600 under a permissive umask with chmod a no-op" "$(stat -c '%a' "$HCSB/spool/handoff.json")" "600"
assert_eq "the card is the JSON handed in" "$(jq -r '.token' "$HCSB/spool/handoff.json")" "tok-1"
assert_eq "no temp file beside the card" "$(find "$HCSB/spool" -name '.handoff*' | wc -l | tr -d ' ')" "0"
chmod 644 "$HCSB/spool/handoff.json"
printf '{"username":"admin","password":"p"}' | run_sourced "$HCSB" eval 'umask 022; chmod() { :; }; write_handoff_card "$HCSB/spool"'
assert_eq "a 644 card left by an earlier attempt is replaced, not truncated in place" "$(stat -c '%a' "$HCSB/spool/handoff.json")" "600"
assert_eq "...and carries the new card" "$(jq -r '.username' "$HCSB/spool/handoff.json")" "admin"
# The two wizard writers (rig card, coordinator card) go through the helper: no direct redirect
# into handoff.json survives in the slices, and exactly two call sites do. A text guard, said so.
assert_eq "no wizard slice redirects into handoff.json directly (text guard)" "$(grep -c '>"\$spool/handoff.json"' "$ROOT"/lib/pithead/*.sh | awk -F: '{n+=$2} END{print n+0}')" "0"
assert_eq "...and both card writers call write_handoff_card (the guard's positive control)" "$(grep -c '| write_handoff_card "\$spool"' "$ROOT/lib/pithead/12-firstboot-wizard.sh")" "2"
rm -rf "$HCSB"
unset HCSB

unset SAWB SAESP out
