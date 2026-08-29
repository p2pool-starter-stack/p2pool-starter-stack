# shellcheck shell=bash
#
# Secrets domain (#1105 Phase 1, develop-v2 lane): apply's secret propagation and redaction, the
# payout-wallet typed confirm, secret-file permissions, and rotate-secrets end to end — apply
# propagating telegram/webhook/ntfy secrets into .env while never printing them in the change
# preview (alongside the rest of apply's field-propagation regression, which this section also
# carries), the payout-wallet change's typed-confirm gate on both chains (a bare 'y' no longer
# passes; the address's first 8 characters must be typed back; -y still bypasses it for automation,
# #375), secret-bearing files being owner-only from the moment they are created rather than chmod'd
# after the fact (#368), and rotate-secrets regenerating the local Monero RPC password, the "auto"
# stratum password, and PROXY_AUTH_TOKEN — recreating containers via compose up (never restart),
# skipping what it must (remote-mode RPC, a literal stratum password), a declined prompt changing
# nothing, and a failed recreate leaving the retry marker plus recoverable owner-only safety copies
# of the old values (#378).
# Sourced by tests/stack/run.sh, stacked on test-backup.sh.
#
# This file merges TWO clusters that sat apart in run.sh, on either side of the backup domain's
# black-box round-trip cluster (test-backup.sh): the apply/payout-wallet/secret-file cluster used to
# run first, and the rotate-secrets cluster used to run roughly 350 lines later, after the whole
# backup round-trip + reset-dashboard block. With that block now extracted to test-backup.sh, the two
# clusters below are adjacent again in the same relative order they always ran in — nothing here
# reads or writes backup's fixtures ($BK/$FB/$R/$RD557), so pulling its cluster out from between them
# changes nothing this file depends on.
#
# Left behind, code-checked (not markers): the "xmrig-proxy entrypoint" pair (unset/set stratum
# access-password, then the TLS cert-flag pair, #152/#261) sits immediately after "rotate-secrets
# failure path" in run.sh, under the same run of secrets-domain markers. It is rig/worker content —
# it drives build/xmrig-proxy/entrypoint.sh's stratum-password and TLS-keypair flag rendering, not
# secret storage/rotation/confirms — and the test-rig-worker.sh cut's own header already declined it
# as "not this domain" and left it in run.sh pending this cut's decision. Code-checked again here: it
# does not belong to secrets either. Line count corroborates the split — this file lands at 353 lines
# of moved content against the #1252 map's ~359-line estimate for test-secrets.sh; folding the
# xmrig-proxy pair in as well would land at 393, well past it. It stays in run.sh, still unclaimed by
# either domain (most likely a future rig/worker-domain follow-up, since that is what its code does).
#
# Re-derivations:
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; the "config validation" black-box calls it
#   once, ahead of the sections below that read them — that section lives in test-config.sh, sourced
#   ahead of this file (a generic multi-field validator, not a secrets concern). build_val_sandbox() is
#   idempotent (a fixed $SANDBOX/val path, mkdir -p, template copies), so calling it again here is a safe
#   no-op re-affirm, the same re-derivation test-monero-tari.sh/test-rig-worker.sh/test-lifecycle.sh use.
# - $DOCKER_LOG: this file's own first section ("apply preserves secrets + propagates") is DOCKER_LOG's
#   original definition site ($V/docker.log) — every other domain file that reads it re-derives its
#   own copy instead of reaching back here, per each of their own header notes. Set again explicitly
#   below anyway, matching their defensive convention, so this file stays correct even if a future
#   reorder ever moved it ahead of the section that used to set it.
build_val_sandbox
DOCKER_LOG="$V/docker.log"

echo "== black-box: apply preserves secrets + propagates =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
DOCKER_LOG="$V/docker.log"
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "pool flag propagated" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--mini"
# Default routes outbound sidechain P2P through Tor (#165): the rendered P2POOL_FLAGS carries the
# pool flag AND the Tor SOCKS flags (no p2pool.clearnet set in this config).
assert_contains "outbound P2P via Tor by default (#165)" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_eq "stratum_bind default" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_BIND)" "0.0.0.0"
# stratum_port (#172) defaults to 3333, so an unconfigured stack keeps today's behaviour, and the
# internal proxy→p2pool leg (P2POOL_URL) stays :3333 whatever the operator-facing port says.
assert_eq "stratum_port default" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_PORT)" "3333"
assert_eq "P2POOL_URL keeps the internal :3333" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_URL)" "172.28.0.28:3333"
assert_eq "token preserved" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
assert_eq "onion preserved" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_ONION_ADDRESS)" "p2pa.onion"
assert_eq "tari_required default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"
assert_eq "fail_closed default off (#490)" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_FAIL_CLOSED)" "false"
# The new-release check (#224) defaults ON when absent from config — it's Tor-routed, so it leaks
# nothing, and an operator who wants zero GitHub contact sets check_for_updates:false to opt out.
assert_eq "check_for_updates default on" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "true"
# Both new xmrig-proxy knobs default to OFF/no-fee when absent from config (#152/#173).
assert_eq "stratum auth off by default" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" ""
assert_eq "donate-level 0 by default (no fee)" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "0"
# Build provenance is exported for the build args, not persisted to .env (Issue #58) — so a git pull
# never shows up as a config change. Assert it stays out of the rendered .env.
assert_eq "provenance not written to .env" "$(run_sourced "$V" env_get_file "$V/.env" PITHEAD_VERSION)" ""
assert_contains "compose up called (build mode)" "$(cat "$DOCKER_LOG")" "compose up --pull never -d --remove-orphans"

# Regression (Issue #58): a second apply with nothing changed must report no changes and exit 0
# cleanly — never tripping the ERR trap. (Provenance keys briefly leaked into this diff; when they
# were the only delta the filter emptied the pipeline and `set -o pipefail` aborted apply.)
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "no-op apply exits 0" "$rc" "0"
assert_contains "no-op apply reports no changes" "$out" "No configuration changes detected"
case "$out" in
*"aborted unexpectedly"*) bad "no-op apply does not trip the error trap" "got: $out" ;;
*) ok "no-op apply does not trip the error trap" ;;
esac
# tari.mem_limit absent => "auto" is a safety ceiling: host RAM minus a >=2 GB reserve, floored at
# 2048m. Assert it ends in 'm', is >= the 2048m floor, and never exceeds physical RAM.
mem="$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)"
host_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
case "$mem" in
*m)
    n="${mem%m}"
    if [ "$n" -ge 2048 ] && { [ "$host_ram_mb" -le 0 ] || [ "$n" -le "$host_ram_mb" ]; }; then
        ok "tari mem auto is a sane ceiling ($mem, host ${host_ram_mb}m)"
    else bad "tari mem auto sane ceiling" "got [$mem] on ${host_ram_mb}m host"; fi
    ;;
*) bad "tari mem auto has m suffix" "got [$mem]" ;;
esac

# A custom p2pool.stratum_port (#172) propagates to STRATUM_PORT; the internal proxy→p2pool leg
# (P2POOL_URL) is deliberately untouched — only the operator-facing published port moves.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_port":4444}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_PORT)" "4444"
assert_eq "custom stratum_port leaves P2POOL_URL internal" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_URL)" "172.28.0.28:3333"

# Non-blocking Tari (dashboard.tari_required:false) propagates as TARI_REQUIRED=false.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","tari_required":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari_required propagated false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

# Opt-in fail-closed (dashboard.fail_closed:true) propagates as DASHBOARD_FAIL_CLOSED=true (#490).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","fail_closed":true} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "fail_closed propagated true" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_FAIL_CLOSED)" "true"

# Opting out (dashboard.check_for_updates:false) propagates as DASHBOARD_CHECK_UPDATES=false (#224) —
# only an explicit false disables it (anything else, incl. absent, stays the default-on true).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","check_for_updates":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "check_for_updates opt-out propagated false" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "false"

# Telegram defaults (#121): no telegram block => disabled, per-event toggles default on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram disabled by default" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_ENABLED)" "false"
assert_eq "telegram event defaults on" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_NODE_DOWN)" "true"

# Telegram enabled: token/chat_id + per-event toggles propagate from config.json into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","events":{"worker_offline":false}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram enabled propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_ENABLED)" "true"
assert_eq "telegram token propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_BOT_TOKEN)" "BOTSECRET"
assert_eq "telegram chat_id propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_CHAT_ID)" "-100123"
assert_eq "telegram per-event override off" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_WORKER_OFFLINE)" "false"
assert_eq "telegram unset event stays on" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_NODE_DOWN)" "true"
# The bot token is a secret: the apply preview must not print it.
case "$out" in
*BOTSECRET*) bad "telegram token not printed by apply" "leaked in: $out" ;;
*) ok "telegram token not printed by apply" ;;
esac

# Interactive command interface (#45): off by default, opt-in via telegram.commands.enabled.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram commands off by default" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_COMMANDS_ENABLED)" "false"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","commands":{"enabled":true}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram commands opt-in propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_COMMANDS_ENABLED)" "true"

# Daily-summary time (#121): defaults to 08:00; an explicit telegram.daily_summary_time propagates.
assert_eq "daily summary time defaults to 08:00" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_DAILY_SUMMARY_TIME)" "08:00"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","daily_summary_time":"21:30"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "daily summary time propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_DAILY_SUMMARY_TIME)" "21:30"

# Webhook + ntfy alert sinks (#380): no notifications block => everything off, Tor default on.
assert_eq "webhook urls default empty" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_WEBHOOK_URLS)" ""
assert_eq "ntfy url default empty" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_URL)" ""
assert_eq "ntfy token default empty" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_TOKEN)" ""
assert_eq "notify tor defaults on" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_TOR)" "true"
# Configured block propagates: the webhook list joins to one space-separated value, ntfy url/token
# land verbatim, tor:false carries through — and apply never prints the URL/token secrets.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "notifications":{"webhooks":["https://hook.example/a","https://hook2.example/b?key=HOOKSECRET"],"ntfy":{"url":"https://ntfy.sh/PITTOPIC","token":"NTFYSECRET"},"tor":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "webhook urls join space-separated" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_WEBHOOK_URLS)" "https://hook.example/a https://hook2.example/b?key=HOOKSECRET"
assert_eq "ntfy url propagated" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_URL)" "https://ntfy.sh/PITTOPIC"
assert_eq "ntfy token propagated" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_TOKEN)" "NTFYSECRET"
assert_eq "notify tor opt-out propagated" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_TOR)" "false"
case "$out" in
*HOOKSECRET* | *NTFYSECRET* | *PITTOPIC*) bad "webhook/ntfy secrets not printed by apply" "leaked in: $out" ;;
*) ok "webhook/ntfy secrets not printed by apply" ;;
esac

# Hashrate-loss detector knobs (#99): default 50% over 10 min; explicit dashboard overrides propagate.
assert_eq "hashrate drop threshold default 50" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_THRESHOLD_PCT)" "50"
assert_eq "hashrate drop minutes default 10" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_MINUTES)" "10"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","hashrate_drop_threshold":40,"hashrate_drop_minutes":5} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "hashrate drop threshold override propagated" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_THRESHOLD_PCT)" "40"
assert_eq "hashrate drop minutes override propagated" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_MINUTES)" "5"

# Event-set consistency (#121/#45): every telegram.events.* key in config.reference.json must be
# rendered by pithead into .env AND declared in docker-compose.yml — so adding an alert event in one
# surface but forgetting another fails here. (The Python side — AlertService.EVT_* vs config.py's
# TELEGRAM_EVENTS — is guarded by a dashboard unit test.) The .env above has all events at their
# default (no events overrides in that config), so each should render "true".
compose_text="$(cat "$ROOT/docker-compose.yml")"
while IFS= read -r ev; do
    up=$(printf '%s' "$ev" | tr '[:lower:]' '[:upper:]')
    assert_eq "telegram event '$ev' rendered to .env" \
        "$(run_sourced "$V" env_get_file "$V/.env" "TELEGRAM_EVENT_$up")" "true"
    assert_contains "telegram event '$ev' declared in docker-compose.yml" \
        "$compose_text" "TELEGRAM_EVENT_$up="
done < <(jq -r '.telegram.events | keys[]' "$ROOT/config.reference.json")

# #502/#529: p2pool.pool defaults to "mini" (the global default — config.reference.json, the two
# `.p2pool.pool // "mini"` code fallbacks, and the wizard Enter-through all agree). A config that
# OMITS p2pool.pool must render the mini sidechain flag, not the old "main". Standalone config so
# it doesn't disturb the propagate block above.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$V/docker.log" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "omitted p2pool.pool defaults to the mini sidechain flag (#502)" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--mini"

echo "== black-box: payout-wallet change needs a typed confirm (#375) =="
# Swapping the payout wallet is the highest-value tamper: apply must demand the first 8 chars of
# the new address typed back (a pasted 'y' can't wave it through), while -y keeps automation alive.
WALLET2="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A" # a second checksum-valid primary (the Monero project's legacy donation address); first 8 chars = 44AFFq5k
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)" # baseline .env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET2" >"$V/config.json"
# (1) A bare 'y' — the old destructive confirm — must NOT pass; .env stays untouched.
out="$(cd "$V" && printf 'y\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
rc=$?
assert_rc "wallet change with 'y' aborts cleanly" "$rc" "0"
assert_contains "wallet prompt shows the new address's first 8 chars" "$out" "(44AFFq5k)"
assert_contains "wallet change cancelled" "$out" "Apply cancelled"
assert_eq "wallet unchanged in .env after abort" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"
# The preview/prompt never echoes the full new address (only its first 8 chars).
assert_not_contains "full new address not echoed by apply" "$out" "$WALLET2"
# (2) Typing the first 8 chars confirms and applies.
out="$(cd "$V" && printf '44AFFq5k\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "typed confirm applies" "$?" "0"
assert_eq "wallet updated in .env after typed confirm" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET2"
# (3) -y still bypasses the prompt for automation.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1 </dev/null)"
assert_rc "apply -y skips the typed confirm" "$?" "0"
assert_eq "wallet updated with -y" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"

# A TARI-only wallet change demands the same typed confirm (the suite above only drove Monero).
TARI2="12KQktz75n4MDh12q8CSV2evxAHrPFAMo29tZqsgKhyHXqP17Tz9jkVhE3T7bB5qAcHQu2kFoXi78EgwfzDhYZ748JT" # checksum-valid (reference keys swapped); first 8 chars = 12KQktz7
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" "$TARI2" >"$V/config.json"
out="$(cd "$V" && printf 'y\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "tari wallet change with 'y' aborts cleanly" "$?" "0"
assert_contains "tari wallet prompt shows the new address's first 8 chars" "$out" "(12KQktz7)"
assert_eq "tari wallet unchanged in .env after abort" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$VALID_TARI"
out="$(cd "$V" && printf '12KQktz7\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "tari typed confirm applies" "$?" "0"
assert_eq "tari wallet updated in .env after typed confirm" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI2"

# BOTH wallets changing in one apply needs TWO typed confirms — one prefix must never wave both
# through (env_changed_keys sorts, so Monero prompts first, then Tari).
TARI3="16beoiD8FT6Ty7q9fyGVk7BmstB3rrtAb7FLFUnJ66deCkAUNsh3suMDQ1CTnhkNKfAjMF2UHJQDVjYJ57wmdMPpwqJfi2i3" # checksum-valid (payment-id form); first 8 chars = 16beoiD8
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET2" "$TARI3" >"$V/config.json"
out="$(cd "$V" && printf '44AFFq5k\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "both-wallet change with one prefix aborts cleanly" "$?" "0"
assert_contains "both-wallet change prompts for the Monero prefix" "$out" "(44AFFq5k)"
assert_contains "both-wallet change prompts for the Tari prefix too" "$out" "(16beoiD8)"
assert_contains "both-wallet change with one prefix is cancelled" "$out" "Apply cancelled"
assert_eq "monero wallet unchanged after one-prefix abort" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"
assert_eq "tari wallet unchanged after one-prefix abort" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI2"
out="$(cd "$V" && printf '44AFFq5k\n16beoiD8\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "both typed confirms apply" "$?" "0"
assert_eq "monero wallet updated after both confirms" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET2"
assert_eq "tari wallet updated after both confirms" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI3"

# An explicit tari.mem_limit is passed through verbatim (overriding the "auto" host-RAM scaling).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mem_limit":"3072m"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari mem_limit explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" "3072m"

echo "== unit+black-box: secret files are owner-only from creation (#368) =="
# The subshell umask must make the secret-bearing files 600 from the FIRST byte — a chmod after
# the write leaves a world-readable window on a shared host, and a silently failed chmod used to
# leave them 644 forever. The mv shim captures the credential temp file's mode BEFORE it lands on
PB="$SANDBOX/perm368"
mkdir -p "$PB/bin"
printf '{ "monero": {} }\n' >"$PB/config.json"
cat >"$PB/bin/mv" <<'EOF'
#!/usr/bin/env bash
stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null # GNU form first (see file_mode note)
exec /usr/bin/mv "$@" # absolute path — a bare `mv` re-resolves to this stub and loops forever
EOF
chmod +x "$PB/bin/mv"
out="$( (umask 022 && PATH="$PB/bin:$PATH" run_sourced "$PB" persist_node_credentials user secret))"
assert_eq "credential temp file is 600 at creation (umask 022)" "$out" "600"
assert_eq "config.json is 600 after credential persist" "$(file_mode "$PB/config.json")" "600"
# Black-box: a full apply under the default umask must leave .env owner-only.
out="$( (cd "$V" && umask 022 && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1))"
assert_eq ".env is owner-only after apply (umask 022)" "$(file_mode "$V/.env")" "600"

echo "== black-box: rotate-secrets regenerates the internal credentials (#378) =="
# One command rotates the local Monero RPC password, the "auto" stratum password, and
# PROXY_AUTH_TOKEN — the three values apply/load_preserved_state otherwise preserve forever.
# Baseline: an applied local-mode config with stratum auth on "auto".
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"oldrpcpass"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rot_sp_old="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
rm -f "$V"/config.json.bak-* "$V"/.env.bak-*
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
rc=$?
assert_rc "rotate-secrets exits 0" "$rc" "0"
rot_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
rot_sp="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
rot_token="$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)"
assert_eq "RPC password rotated (32 chars)" "${#rot_pass}" "32"
assert_eq "RPC password changed" "$([ "$rot_pass" != "oldrpcpass" ] && echo changed)" "changed"
assert_eq "new RPC password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$rot_pass"
assert_eq "stratum password changed" "$([ -n "$rot_sp" ] && [ "$rot_sp" != "$rot_sp_old" ] && echo changed)" "changed"
assert_eq "proxy token changed" "$([ -n "$rot_token" ] && [ "$rot_token" != "ORIGINALTOKEN" ] && echo changed)" "changed"
assert_eq "DEPLOYMENT_COMPLETED survives the rotate (#356)" "$(run_sourced "$V" env_get_file "$V/.env" DEPLOYMENT_COMPLETED)" "true"
# Consumers: the containers are RECREATED via compose up (env/args re-read), never `compose restart`
# (which would reuse p2pool's old --rpc-login args).
assert_contains "rotate recreates via compose up" "$(cat "$DOCKER_LOG")" "compose up"
assert_not_contains "rotate never uses compose restart" "$(cat "$DOCKER_LOG")" "compose restart"
# Secrets stay out of the command output — except the stratum password, deliberately surfaced via
# announce_stratum_auth so the operator can update each rig's 'pass'.
case "$out" in
*"$rot_pass"* | *"$rot_token"*) bad "rotate never prints the RPC password / proxy token" "leaked in: $out" ;;
*) ok "rotate never prints the RPC password / proxy token" ;;
esac
assert_contains "rotate surfaces the new stratum password for rigs" "$out" "Stratum authentication is ON"
assert_contains "rotate warns that rigs are rejected until updated" "$out" "rejected"
# Recoverability: the pre-rotation copies hold the OLD values, owner-only.
rot_cfg_bak="$(ls "$V"/config.json.bak-* 2>/dev/null | head -1)"
rot_env_bak="$(ls "$V"/.env.bak-* 2>/dev/null | head -1)"
assert_eq "config.json safety copy holds the old RPC password" "$(jq -r '.monero.node_password' "${rot_cfg_bak:-/dev/null}" 2>/dev/null)" "oldrpcpass"
assert_contains ".env safety copy holds the old proxy token" "$(cat "${rot_env_bak:-/dev/null}" 2>/dev/null)" "ORIGINALTOKEN"
rot_bak_mode="$(stat -c '%a' "$rot_env_bak" 2>/dev/null || stat -f '%Lp' "$rot_env_bak" 2>/dev/null)"
assert_eq "safety copies are owner-only (600)" "$rot_bak_mode" "600"
# Persistence: a follow-up apply reports no changes — the preservation logic now carries the NEW
# values instead of resurrecting the old ones. (This is exactly the assertion that fails if
# rotate silently no-ops: the preserved values would never have changed.)
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "apply after rotate reports no changes" "$out" "No configuration changes detected"
assert_eq "rotated token survives the next apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "$rot_token"

echo "== black-box: rotate-secrets skips what it must (#378) =="
# Remote mode: the RPC credential belongs to the remote node — config.json stays untouched.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"ru","node_password":"remotepass","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
assert_rc "rotate-secrets (remote) exits 0" "$?" "0"
assert_eq "remote RPC password untouched" "$(jq -r '.monero.node_password' "$V/config.json")" "remotepass"
assert_contains "remote skip is explained" "$out" "remote"
assert_eq "proxy token still rotates in remote mode" "$([ "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" != "ORIGINALTOKEN" ] && echo changed)" "changed"

# Literal stratum password: lives in config.json, so rotate leaves it and points there instead.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"my.literal-pass"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
assert_eq "literal stratum password untouched" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "my.literal-pass"
assert_contains "literal skip points at config.json" "$out" "config.json"

# Declined prompt (no -y): nothing changes.
rot_token_now="$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" sh -c 'echo n | ./pithead rotate-secrets' 2>&1)"
assert_rc "declined rotate exits 0" "$?" "0"
assert_contains "declined rotate says cancelled" "$out" "cancelled"
assert_eq "declined rotate changes nothing" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "$rot_token_now"

echo "== black-box: rotate-secrets failure path keeps the old values recoverable (#378) =="
# A failed recreate must exit non-zero, leave the retry marker (#125) so `apply` re-attempts the
# recreate, and point at the safety copies that still hold the old secrets.
FDOCK="$SANDBOX/faildocker"
mkdir -p "$FDOCK"
cat >"$FDOCK/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose version"|"info") exit 0 ;;
  compose\ up*) echo "boom: no space left on device"; exit 1 ;;
esac
exit 0
EOF
chmod +x "$FDOCK/docker"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"failoldpass"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rm -f "$V"/config.json.bak-* "$V"/.env.bak-* "$V/.env.apply-incomplete"
out="$(cd "$V" && PATH="$FDOCK:$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
rc=$?
assert_rc "failed recreate exits non-zero" "$rc" "1"
assert_contains "failure names the retry path" "$out" "apply"
[ -f "$V/.env.apply-incomplete" ] && ok "failure leaves the retry marker (#125)" || bad "failure leaves the retry marker (#125)" "marker missing"
assert_eq "safety copy still holds the pre-rotation RPC password" "$(jq -r '.monero.node_password' "$(ls "$V"/config.json.bak-* | head -1)")" "failoldpass"
assert_contains "safety copy still holds the pre-rotation token" "$(cat "$(ls "$V"/.env.bak-* | head -1)")" "ORIGINALTOKEN"
rm -f "$V/.env.apply-incomplete" "$V"/config.json.bak-* "$V"/.env.bak-*
