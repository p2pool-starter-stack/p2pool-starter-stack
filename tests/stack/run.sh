#!/usr/bin/env bash
#
# Dependency-free test suite for pithead (no bats required).
# Mixes unit tests (sourcing pithead and calling its functions) with black-box CLI tests
# (running a sandboxed copy of pithead with docker/sudo stubbed out). Run: tests/stack/run.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-harness-tooling.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-harness-tooling.sh" && domain_ran test-harness-tooling.sh "$_d0" "$?" || domain_ran test-harness-tooling.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-doctor.sh" && domain_ran test-doctor.sh "$_d0" "$?" || domain_ran test-doctor.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-upgrade.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-upgrade.sh" && domain_ran test-control-upgrade.sh "$_d0" "$?" || domain_ran test-control-upgrade.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-release-signing.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release-signing.sh" && domain_ran test-release-signing.sh "$_d0" "$?" || domain_ran test-release-signing.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-dashboard.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard.sh" && domain_ran test-dashboard.sh "$_d0" "$?" || domain_ran test-dashboard.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-dashboard-onion.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard-onion.sh" && domain_ran test-dashboard-onion.sh "$_d0" "$?" || domain_ran test-dashboard-onion.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release.sh" && domain_ran test-release.sh "$_d0" "$?" || domain_ran test-release.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-unit-helpers.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-unit-helpers.sh" && domain_ran test-unit-helpers.sh "$_d0" "$?" || domain_ran test-unit-helpers.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-cli.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-cli.sh" && domain_ran test-cli.sh "$_d0" "$?" || domain_ran test-cli.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-config.sh" && domain_ran test-config.sh "$_d0" "$?" || domain_ran test-config.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-render-quadlet.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-render-quadlet.sh" && domain_ran test-render-quadlet.sh "$_d0" "$?" || domain_ran test-render-quadlet.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor-appliance.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-doctor-appliance.sh" && domain_ran test-doctor-appliance.sh "$_d0" "$?" || domain_ran test-doctor-appliance.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-setup.sh" && domain_ran test-appliance-setup.sh "$_d0" "$?" || domain_ran test-appliance-setup.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-backup.sh" && domain_ran test-backup.sh "$_d0" "$?" || domain_ran test-backup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-install-verify.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-install-verify.sh" && domain_ran test-install-verify.sh "$_d0" "$?" || domain_ran test-install-verify.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-secrets.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-secrets.sh" && domain_ran test-secrets.sh "$_d0" "$?" || domain_ran test-secrets.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-rig-worker.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rig-worker.sh" && domain_ran test-rig-worker.sh "$_d0" "$?" || domain_ran test-rig-worker.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-monero-tari.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-monero-tari.sh" && domain_ran test-monero-tari.sh "$_d0" "$?" || domain_ran test-monero-tari.sh "$_d0" "$?"

# xmrig-proxy wrapper entrypoint: optional stratum access-password (#152). The flag moved out of the
# compose command (a `${VAR:+--flag}` list element rendered a stray '' positional arg when the password
# was unset — xmrig-proxy warns `unsupported non-option argument ''`) into this wrapper, which appends
# it only when PROXY_STRATUM_PASSWORD is set. Exercise the real script with a stub xmrig-proxy on PATH
# that echoes its argv, so the set/unset branch is actually run.
XP_ENTRY="$ROOT/build/xmrig-proxy/entrypoint.sh"
xp_argv() { # <password value> -> the argv the wrapper would exec
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD="$1" sh "$XP_ENTRY" --http-no-restricted --donate-level=0
    rm -rf "$d"
}
assert_eq "xmrig-proxy entrypoint: unset password appends no flag (#152)" \
    "$(xp_argv '')" "[--http-no-restricted][--donate-level=0]"
assert_eq "xmrig-proxy entrypoint: set password appends --access-password (#152)" \
    "$(xp_argv 's3cret')" "[--http-no-restricted][--donate-level=0][--access-password=s3cret]"
# #261: the TLS cert flags append only when the toggle is on AND both keypair files exist at the
# mount (PROXY_TLS_MOUNT overrides the fixed /tls so the suite can use a temp dir).
xp_tls_argv() { # <PROXY_STRATUM_TLS value> <tls dir>
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD='' PROXY_STRATUM_TLS="$1" PROXY_TLS_MOUNT="$2" sh "$XP_ENTRY" -b 0.0.0.0:3333
    rm -rf "$d"
}
XPTLS="$(mktemp -d)"
printf 'cert' >"$XPTLS/cert.pem"
printf 'key' >"$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on + keypair appends the cert flags (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333][--tls-cert=$XPTLS/cert.pem][--tls-cert-key=$XPTLS/key.pem]"
assert_eq "xmrig-proxy entrypoint: TLS off appends nothing (#261)" \
    "$(xp_tls_argv false "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -f "$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on but keypair incomplete appends nothing (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -rf "$XPTLS"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-tor-network.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-network.sh" && domain_ran test-tor-network.sh "$_d0" "$?" || domain_ran test-tor-network.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-core.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-core.sh" && domain_ran test-control-core.sh "$_d0" "$?" || domain_ran test-control-core.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-secrets-masking.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-secrets-masking.sh" && domain_ran test-secrets-masking.sh "$_d0" "$?" || domain_ran test-secrets-masking.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-confirm-approval.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-confirm-approval.sh" && domain_ran test-confirm-approval.sh "$_d0" "$?" || domain_ran test-confirm-approval.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-data-management.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-data-management.sh" && domain_ran test-data-management.sh "$_d0" "$?" || domain_ran test-data-management.sh "$_d0" "$?"

# The approval gate (#33) — default-deny on security-sensitive changes — together with
# workers.list[]'s add-only exception (#893) and the #122 SSRF floor on a newly appended entry's
# host. The whole domain lives in the file and arms its own control sandbox (#1105 R13); this
# stanza sits at the position the section has always run from.
# shellcheck source=tests/stack/test-control-add-only-ssrf.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-add-only-ssrf.sh" && domain_ran test-control-add-only-ssrf.sh "$_d0" "$?" || domain_ran test-control-add-only-ssrf.sh "$_d0" "$?"

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

# shellcheck source=tests/stack/test-worker-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-worker-config.sh" && domain_ran test-worker-config.sh "$_d0" "$?" || domain_ran test-worker-config.sh "$_d0" "$?"

echo "== black-box: notification secrets masked in the prefill copy (#848) =="
# The ntfy topic URL + token are bearer credentials, and each notifications.webhooks[] entry IS a
# bearer URL (query strings carry tokens). All must be sentineled in the world-readable masked copy
# — one LEAK- marker across every set secret proves the whole set at once; a blank webhook entry and
# the non-secret notifications.tor flag must survive so the editor can still render the form.
jq '.notifications = {
    webhooks: ["https://hooks.example/LEAK-hookA", "", "https://hooks.example/LEAK-hookB"],
    ntfy: {url: "https://ntfy.example/LEAK-ntfyurl", token: "LEAK-ntfytoken"},
    tor: true}' "$C/config.json" >"$C/config.json.tmp" && mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
assert_eq "ntfy url masked to the sentinel" "$(jq -c '.notifications.ntfy.url' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "ntfy token masked to the sentinel" "$(jq -c '.notifications.ntfy.token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "first webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[0]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "third webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[2]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "a blank webhook entry stays blank in the masked copy" "$(jq -r '.notifications.webhooks[1]' "$MASKED" 2>/dev/null)" ""
assert_eq "the non-secret notifications.tor flag survives" "$(jq -r '.notifications.tor' "$MASKED" 2>/dev/null)" "true"
case "$(cat "$MASKED")" in
*LEAK-*) bad "masked copy holds no notification secret" "a notification secret leaked into $MASKED" ;;
*) ok "masked copy holds no notification secret" ;;
esac

# shellcheck source=tests/stack/test-spool-audit.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-spool-audit.sh" && domain_ran test-spool-audit.sh "$_d0" "$?" || domain_ran test-spool-audit.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-deploy.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-deploy.sh" && domain_ran test-control-deploy.sh "$_d0" "$?" || domain_ran test-control-deploy.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-telegram.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-telegram.sh" && domain_ran test-control-telegram.sh "$_d0" "$?" || domain_ran test-control-telegram.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-backup.sh" && domain_ran test-control-backup.sh "$_d0" "$?" || domain_ran test-control-backup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-wizard-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-wizard-setup.sh" && domain_ran test-wizard-setup.sh "$_d0" "$?" || domain_ran test-wizard-setup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-provisioning.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-provisioning.sh" && domain_ran test-control-provisioning.sh "$_d0" "$?" || domain_ran test-control-provisioning.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-identity.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity.sh" && domain_ran test-appliance-identity.sh "$_d0" "$?" || domain_ran test-appliance-identity.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-defaults.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-defaults.sh" && domain_ran test-appliance-defaults.sh "$_d0" "$?" || domain_ran test-appliance-defaults.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-install.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-install.sh" && domain_ran test-appliance-install.sh "$_d0" "$?" || domain_ran test-appliance-install.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-rig-miner.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-rig-miner.sh" && domain_ran test-appliance-rig-miner.sh "$_d0" "$?" || domain_ran test-appliance-rig-miner.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-boot.sh" && domain_ran test-appliance-boot.sh "$_d0" "$?" || domain_ran test-appliance-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update.sh" && domain_ran test-appliance-os-update.sh "$_d0" "$?" || domain_ran test-appliance-os-update.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update-verbs.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update-verbs.sh" && domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?" || domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update-lock.sh" && domain_ran test-appliance-os-update-lock.sh "$_d0" "$?" || domain_ran test-appliance-os-update-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-kernel-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-kernel-boot.sh" && domain_ran test-appliance-kernel-boot.sh "$_d0" "$?" || domain_ran test-appliance-kernel-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-reset.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-reset.sh" && domain_ran test-appliance-reset.sh "$_d0" "$?" || domain_ran test-appliance-reset.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-identity-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity-boot.sh" && domain_ran test-appliance-identity-boot.sh "$_d0" "$?" || domain_ran test-appliance-identity-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-media.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-media.sh" && domain_ran test-appliance-media.sh "$_d0" "$?" || domain_ran test-appliance-media.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-rauc-loop-wait.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rauc-loop-wait.sh" && domain_ran test-rauc-loop-wait.sh "$_d0" "$?" || domain_ran test-rauc-loop-wait.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-lifecycle.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-lifecycle.sh" && domain_ran test-lifecycle.sh "$_d0" "$?" || domain_ran test-lifecycle.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
