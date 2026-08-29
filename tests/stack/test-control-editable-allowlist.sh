# shellcheck shell=bash
#
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json (#522) — not just pass a describe_change unit
# check. Split out of run.sh by #1105 R14; the section's own contract is stated at its header below.
#
# WHY THE CONTROL FAMILY, AND NOT THE CONFIG FAMILY THE CUT MAP GUESSED. The map homed this row
# with the config family on the strength of its subject: it flips config keys and reads them back
# out of config.json. Its FIXTURE says otherwise, and the fixture is what a domain file actually
# has to reproduce. Every assertion here goes through gate_try() against the control channel's
# sandbox and its request/result spool, so this section's dependencies are the control channel's,
# and it is homed with them. The map's row left the target to be decided at cut time by fixture
# affinity; this is that decision, recorded rather than assumed.
#
# AMBIENT BY DESIGN — AND THE REASON IS NOT THAT ARMING WOULD BREAK IT. This file inherits $C,
# $CTRL_LOG and $WALLET from the build_control_sandbox() call a control-family domain file makes
# ahead of it, and re-derives only its own spool path from $C. Calling the builder here would most
# likely be harmless — it creates rather than clears and never touches the control spool — but it
# would add a call that does not exist today, and it would buy nothing, because gate_try() is a
# function defined in another domain file and no arm written here can supply it. The cut that
# changes nothing about what executes is the one whose proof is strongest, so that is the one
# taken; the ambient inheritance is disclosed here instead, which is the shipped
# test-control-add-only-ssrf.sh precedent. $VALID_TARI is a top-level lib.sh constant.
#
# POSITION-LOCKED IN run.sh's SOURCE ORDER, not merely position-preferring. gate_try() and $UUID5
# are defined by test-control-add-only-ssrf.sh and deliberately outlive its source; run.sh sources
# that file immediately ahead of this one. That is the other half of the dependency its own header
# already discloses from its side. The carry-over guard below fails by name rather than silently,
# but it cannot make this file sourceable standalone — a missing gate_try() is loud (command not
# found, then the status assertions fail by name) and that is the honest state of it.
#
# WHAT THE INHERITANCE COSTS, stated so the next cut near here need not re-derive it: the gate_try()
# calls below write result files into the shared control spool, and a control-family file run.sh
# sources AHEAD of this one asserts that spool's exact result count. That assertion runs before this
# section writes anything, so it is untouched while this file stays where run.sh sources it.
#
# CONCURRENCY PROVENANCE, carried across the move because it is exactly what a move loses: this is
# the fork-heavy section — a per-key round-trip, each one a real preview->commit through the spool —
# that the fleet's notes name as the contention point when two suite runs share a box. A concurrent
# pair that reddens like cross-talk should be looked for here first.

: "${C:?}" "${CTRL_LOG:?}" "${WALLET:?}" "${VALID_TARI:?}" "${UUID5:?}"
RESULTS="$C/data/control/results"

echo "== black-box: editable-allowlist commit round-trip, every key (#522) =="
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json — not just pass a describe_change unit check.
# Fresh baseline with each tunable at a known value so every row below is a genuine single-key
# env diff (pool flips P2POOL_FLAGS + P2POOL_PORT, both allowlisted).
jq -n --arg w "$WALLET" '{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",mem_limit:"4g",prep_blocks_threads:4},
    tari:{wallet_address:"'"$VALID_TARI"'",mem_limit:"3g"}, p2pool:{pool:"main"},
    xvb:{enabled:true,donation_level:"donor"}, telegram:{daily_summary_time:"08:00"},
    dashboard:{secure:true,host:"box.lan",tari_required:true,check_for_updates:true,timezone:"UTC",
               hashrate_drop_threshold:50,hashrate_drop_minutes:10,
               auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
roundtrip_key() { # <label> <jq-set> <jq-read> <expected>
    jq "$2" "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "$1 commit applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
    assert_eq "$1 landed in config.json" "$(jq -r "$3" "$C/config.json")" "$4"
}
roundtrip_key "XVB_ENABLED" '.xvb.enabled=false' '.xvb.enabled' "false"
roundtrip_key "XVB_DONATION_LEVEL" '.xvb.donation_level="whale"' '.xvb.donation_level' "whale"
roundtrip_key "TARI_REQUIRED" '.dashboard.tari_required=false' '.dashboard.tari_required' "false"
roundtrip_key "DASHBOARD_FAIL_CLOSED" '.dashboard.fail_closed=true' '.dashboard.fail_closed' "true"
roundtrip_key "DASHBOARD_CHECK_UPDATES" '.dashboard.check_for_updates=false' '.dashboard.check_for_updates' "false"
roundtrip_key "DASHBOARD_TZ" '.dashboard.timezone="Europe/Paris"' '.dashboard.timezone' "Europe/Paris"
roundtrip_key "MONERO_MEM_LIMIT" '.monero.mem_limit="5g"' '.monero.mem_limit' "5g"
roundtrip_key "TARI_MEM_LIMIT" '.tari.mem_limit="2g"' '.tari.mem_limit' "2g"
roundtrip_key "MONERO_PREP_THREADS" '.monero.prep_blocks_threads=8' '.monero.prep_blocks_threads' "8"
roundtrip_key "HASHRATE_DROP_THRESHOLD_PCT" '.dashboard.hashrate_drop_threshold=40' '.dashboard.hashrate_drop_threshold' "40"
roundtrip_key "HASHRATE_DROP_MINUTES" '.dashboard.hashrate_drop_minutes=15' '.dashboard.hashrate_drop_minutes' "15"
roundtrip_key "TELEGRAM_DAILY_SUMMARY_TIME" '.telegram.daily_summary_time="09:30"' '.telegram.daily_summary_time' "09:30"
roundtrip_key "P2POOL_FLAGS/P2POOL_PORT" '.p2pool.pool="mini"' '.p2pool.pool' "mini"
# The 25 allowlisted TELEGRAM_EVENT_* toggles (raffle_win added 2026-08: audit found it was the one
# event toggle missing from its siblings, all otherwise editable). wallet_changed + clearnet_exposed
# are deliberately NOT on the allowlist (tamper-evidence alarms; their refusal is asserted above),
# so they are excluded here. Each flips true->false as a single-key diff.
for ev in node_down node_recovered worker_offline worker_recovered worker_joined worker_left \
    sync_finished disk_space db_unhealthy db_reset xvb_no_share xvb_registration new_release \
    stack_online daily_summary hashrate_low hashrate_loss hugepages low_ram high_reject_rate \
    block_found payout_found payout_confirmed container_unhealthy raffle_win; do
    roundtrip_key "TELEGRAM_EVENT ${ev}" ".telegram.events.${ev}=false" ".telegram.events.${ev}" "false"
done
