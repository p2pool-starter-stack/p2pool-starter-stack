# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Config domain (#1105 Phase 1, appliance lane): what decides whether a config.json is admissible
# and what it renders into — the multi-field validator that refuses a bad config before anything is
# written (wallet address forms and their checksums, the two worker shapes, energy, the /24 subnet
# rule), the closed-schema invariant keeping config.reference.json a superset of every path pithead
# reads plus the core-key shortlist that must stay inside it (#561/#502/#529), describe_change's
# per-key classification of an apply into INFO / CONFIRM / host-only DEST rows and its rule that no
# secret value ever reaches the preview (#719/#152/#121/#380), `pithead render` rebuilding the whole
# derived layer in place (#790), and the subnet-collision diagnosis a failed compose network is
# translated into (#180).
# Sourced by tests/stack/run.sh.
#
# Why the source line sits where it does: this file makes the suite's FIRST build_val_sandbox()
# call ($V, seed_env), so its stanza holds the ORIGINAL global position of the "config validation"
# block. Only read-only sections move; nothing here touches $C or the ambient .env/Caddyfile.
#
# Left behind, code-checked (not markers): the config_bool / env-helper probes (#294), unnamed for
# this module by the #1252 domain map; the editable-allowlist round-trip (#522, cut to
# test-control-editable-allowlist.sh by #1105 R14); and render-quadlet parity, an appliance test.

echo "== unit: describe_change =="
# Monero prune (#719): DISABLE (on → off) forces a full re-sync, host-only DEST; ENABLE (off → on)
# reclaims disk, an operator-intent op — now confirm-gated (CONFIRM), not a flat host-only refuse.
assert_contains "prune disable is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 1 0)" "DEST"
assert_contains "prune enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 0 1)" "CONFIRM"
assert_contains "rpc lan is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_RPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
# LAN exposure of the no-auth node feeds (#760): opening to 0.0.0.0 is DEST in that direction only.
assert_contains "zmq lan is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_ZMQ_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "zmq close is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_ZMQ_BIND 0.0.0.0 127.0.0.1)" "INFO"
assert_contains "tari grpc lan is DEST" "$(run_sourced "$SANDBOX" describe_change TARI_GRPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "tari grpc close is INFO" "$(run_sourced "$SANDBOX" describe_change TARI_GRPC_BIND 0.0.0.0 127.0.0.1)" "INFO"
assert_contains "stratum open is DEST" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum lan is INFO" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 0.0.0.0 127.0.0.1)" "INFO"
# Stratum port (#172/#719): changing it disconnects every rig until repointed — an operator-intent
# repoint, now confirm-gated (CONFIRM); the key's first appearance (an upgrade from a pre-#172 .env)
# is a no-op INFO row, never a scary repoint warning.
assert_contains "stratum port change is CONFIRM" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT 3333 4444)" "CONFIRM"
assert_contains "stratum port change says repoint" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT 3333 4444)" "repoint"
assert_contains "stratum port first render is INFO" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT '' 3333)" "INFO"
# Caddy LAN port (#740): a real change previews the port; the default->default no-op (the key is
# added empty on the first apply after an upgrade) stays silent so it isn't a scary row.
assert_contains "caddy port change previews the port" "$(run_sourced "$SANDBOX" describe_change HOST_PORT '' 8443)" "Caddy port"
hp_silent="$(run_sourced "$SANDBOX" describe_change HOST_PORT '' '')"
case "$hp_silent" in
*"Caddy port"*) bad "caddy port default->default stays silent" "empty-both HOST_PORT emitted a preview line" ;;
*) ok "caddy port default->default stays silent" ;;
esac
# Stratum access-password (#152): enabling/changing is DEST (rigs need the new pass), disabling is
# INFO — and the secret value must NEVER appear in the change preview.
assert_contains "stratum pw enable is DEST" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" "DEST"
assert_contains "stratum pw disable is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD s3cr3t '')" "INFO"
# Appliance (#1139): the DIY hint points at .env / './pithead status' to recover the password —
# neither exists without a shell, and the dashboard never round-trips a secret value either (#33),
# so there is no remedy to name. The appliance-lane message drops the instruction instead of
# inventing one.
#
# MUTATION PROOF: drop the is_appliance branch (always emit the DIY message) and the "names no CLI
# verb" assertion below goes red; force the appliance branch unconditionally and the unchanged-DIY
# assertion at line ~574's sibling below goes red — neither direction passes both.
stratum_pw_appliance="$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)"
assert_contains "appliance stratum pw enable is still DEST" "$stratum_pw_appliance" "DEST"
case "$stratum_pw_appliance" in
*"./pithead"* | *".env"*) bad "appliance stratum pw enable names no CLI verb or .env" "still says: $stratum_pw_appliance" ;;
*) ok "appliance stratum pw enable names no CLI verb or .env" ;;
esac
assert_contains "DIY stratum pw enable advice is unchanged" "$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" "find it in .env / './pithead status'"
case "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD oldpw newpw)" in
*oldpw* | *newpw*) bad "stratum pw change hides the secret" "value leaked into the change preview" ;;
*DEST*) ok "stratum pw change hides the secret (DEST, no value shown)" ;;
*) bad "stratum pw change hides the secret" "expected DEST" ;;
esac
# Tor guard self-heal toggle (#424): INFO either way, and the enable warns about circuits dropping.
assert_contains "tor auto-heal enable is INFO" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL false true)" "INFO"
assert_contains "tor auto-heal enable names the cost" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL false true)" "drops ALL Tor circuits"
assert_contains "tor auto-heal disable names the manual fix" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)" "restart tor"
# Appliance (#1139): 'doctor' and a scoped tor restart are both CLI-only, and no dashboard control
# restarts tor alone — the appliance-lane message states the fact instead of naming a remedy that
# does not exist on that lane.
# MUTATION PROOF: the same pair as the stratum-password block above, same mechanism — neither forced branch passes both assertions.
tor_heal_appliance="$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)"
assert_contains "appliance tor auto-heal disable is still INFO" "$tor_heal_appliance" "INFO"
case "$tor_heal_appliance" in
*"./pithead"*) bad "appliance tor auto-heal disable names no CLI verb" "still says: $tor_heal_appliance" ;;
*) ok "appliance tor auto-heal disable names no CLI verb" ;;
esac
assert_contains "DIY tor auto-heal disable advice is unchanged" "$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)" "'./pithead doctor', fix with './pithead restart tor'"
# Fail-closed miner hold (#490): INFO either way (like TARI_REQUIRED) — it's on the dashboard
# control-channel allowlist, so a DEST flag here would make control_approval_gate refuse every
# commit that touches it, defeating the allowlisting.
assert_contains "fail_closed enable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED false true)" "INFO"
assert_contains "fail_closed enable names the hold" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED false true)" "HOLDS p2pool and xmrig-proxy"
assert_contains "fail_closed disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED true false)" "INFO"
assert_contains "fail_closed disable names alert-only" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED true false)" "only alerts"
# Dev-fee donate-level (#173): a brief restart (INFO), shown as a percentage.
assert_contains "donate-level is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "INFO"
assert_contains "donate-level shows pct" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "0% → 1%"
# COMPOSE_PROFILES (#552): the payout-confirm profiles (#381/#462) share this key with local_node,
# so the node-switch text must key off the local_node token, not old/new emptiness.
case "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "" tari_payout_confirm)" in
*"LOCAL Monero node"*) bad "payout-confirm enable is not a node switch" "got node-switch text" ;;
*) ok "payout-confirm enable is not a node switch" ;;
esac
case "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "local_node,payout_confirm" local_node)" in
*"LOCAL Monero node"* | *"REMOTE Monero node"*) bad "payout-confirm disable (node stays local) is not a node switch" "got node-switch text" ;;
*) ok "payout-confirm disable (node stays local) is not a node switch" ;;
esac
assert_contains "empty to local_node is a LOCAL switch" "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "" local_node)" "LOCAL Monero node"
assert_contains "local_node to empty is a REMOTE switch" "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES local_node "")" "REMOTE Monero node"
assert_contains "wallet is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_WALLET_ADDRESS a b)" "DEST"
assert_contains "xvb url is INFO" "$(run_sourced "$SANDBOX" describe_change XVB_POOL_URL a b)" "INFO"
# Data-dir moves (#719): the four service dirs are confirm-gated (an expensive re-sync, not a
# breach); every OTHER data dir (e.g. TOR_DATA_DIR) stays host-only DEST.
assert_contains "monero data_dir is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_DATA_DIR /a /b)" "CONFIRM"
assert_contains "dashboard data_dir is CONFIRM" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_DATA_DIR /a /b)" "CONFIRM"
assert_contains "tor data_dir stays DEST" "$(run_sourced "$SANDBOX" describe_change TOR_DATA_DIR /a /b)" "DEST"
assert_contains "tari mem is INFO" "$(run_sourced "$SANDBOX" describe_change TARI_MEM_LIMIT 2048m 4g)" "INFO"
# Healthchecks.io (#79): the ping URL is the on/off switch AND a capability secret. Setting it says
# ENABLED, clearing it says DISABLED — and the value must NEVER be echoed into the apply preview.
assert_contains "hc enable is INFO" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)" "INFO"
assert_contains "hc set says ENABLED" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)" "ENABLED"
assert_contains "hc clear says DISABLED" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL https://hc-ping.com/SECRET "")" "DISABLED"
case "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL https://hc-ping.com/OLD https://hc-ping.com/NEW)" in
*SECRET* | *OLD* | *NEW*) bad "hc ping_url not printed" "leaked the ping URL into the preview" ;;
*) ok "hc ping_url not printed" ;;
esac
# Telegram (#121): toggles/events are a brief dashboard restart (INFO); the bot token is a secret,
# so its change line must NOT echo the old/new value.
assert_contains "telegram enable is INFO" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_ENABLED false true)" "INFO"
assert_contains "telegram event is INFO" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_EVENT_NODE_DOWN true false)" "INFO"
tg_tok_msg="$(run_sourced "$SANDBOX" describe_change TELEGRAM_BOT_TOKEN oldsecret newsecret)"
assert_contains "telegram token change noted" "$tg_tok_msg" "Telegram bot token updated"
# Webhook/ntfy sink changes (#380): URLs and the ntfy token are secrets — the preview names the
# change without printing any value.
hook_msg="$(run_sourced "$SANDBOX" describe_change NOTIFY_WEBHOOK_URLS "" "https://hook.example/x?key=HOOKSEC")"
assert_contains "webhook enable noted" "$hook_msg" "Webhook alert sink(s) ENABLED"
case "$hook_msg" in
*HOOKSEC*) bad "webhook url not leaked in preview" "leaked: $hook_msg" ;;
*) ok "webhook url not leaked in preview" ;;
esac
ntfy_msg="$(run_sourced "$SANDBOX" describe_change NTFY_URL "https://ntfy.sh/OLDTOPIC" "https://ntfy.sh/NEWTOPIC")"
assert_contains "ntfy url change noted" "$ntfy_msg" "ntfy topic URL updated"
case "$ntfy_msg" in
*OLDTOPIC* | *NEWTOPIC*) bad "ntfy topic url not leaked in preview" "leaked: $ntfy_msg" ;;
*) ok "ntfy topic url not leaked in preview" ;;
esac
ntfy_tok_msg="$(run_sourced "$SANDBOX" describe_change NTFY_TOKEN oldntfysec newntfysec)"
assert_contains "ntfy token change noted" "$ntfy_tok_msg" "ntfy access token updated"
case "$ntfy_tok_msg" in
*oldntfysec* | *newntfysec*) bad "ntfy token value not leaked in preview" "leaked: $ntfy_tok_msg" ;;
*) ok "ntfy token value not leaked in preview" ;;
esac
assert_contains "notify tor opt-out warns about IP exposure" \
    "$(run_sourced "$SANDBOX" describe_change NOTIFY_TOR true false)" "see this host's IP"
case "$tg_tok_msg" in
*oldsecret* | *newsecret*) bad "telegram token value not leaked in preview" "leaked: $tg_tok_msg" ;;
*) ok "telegram token value not leaked in preview" ;;
esac
assert_contains "monero mem is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "INFO"
assert_contains "monero mem recreate note" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "monerod container is recreated"
# Clearnet initial sync (#183/#719): ENABLING exposes the host IP during IBD — confirm-gated
# (CONFIRM), and the row must spell out the exposure. DISABLING keeps sync on Tor — a plain INFO
# change, no confirm friction.
assert_contains "monero clearnet enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "CONFIRM"
assert_contains "monero clearnet enable warns exposure" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "CLEARNET"
assert_contains "monero clearnet keeps tx on Tor" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "Tor"
assert_contains "monero clearnet disable is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC true false)" "INFO"
assert_contains "tari clearnet enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change TARI_CLEARNET_SYNC false true)" "CONFIRM"
assert_contains "tari clearnet enable warns exposure" "$(run_sourced "$SANDBOX" describe_change TARI_CLEARNET_SYNC false true)" "CLEARNET"
# 2026-08 security review: the outbound-peer count is confirm-gated (bounded 8-1024 but the
# biggest steady-state knob on the shared Tor daemon's CPU). The same review kept the payout
# restore points and proxy.donate_level host-only — a future-dated restore point silently defeats
# payout-confirmation tamper evidence, and donate traffic bypasses the Tor socks5.
assert_contains "monero outbound-peer change is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_OUT_PEERS 12 64)" "CONFIRM"
# 2026-09 operator ruling (#1888): the remote node endpoints joined that tier — they move TRUST, not
# disk — while the RPC LOGIN CREDENTIALS for the same node did NOT. That row is the control: it is what makes this set able to say NO.
node_ep="$(run_sourced "$SANDBOX" describe_change MONERO_NODE_HOST 10.0.0.9 10.0.0.11)"
assert_contains "monero node endpoint is CONFIRM (#1888)" "$node_ep" "CONFIRM"
assert_contains "monero node endpoint preview names old -> new" "$node_ep" "10.0.0.9 → 10.0.0.11"
assert_contains "tari node endpoint is CONFIRM (#1888)" "$(run_sourced "$SANDBOX" describe_change TARI_GRPC_ADDRESS a.lan:18142 b.lan:18142)" "CONFIRM"
assert_not_contains "a remote node's RPC password is NOT confirm-gated" "$(run_sourced "$SANDBOX" describe_change MONERO_NODE_PASSWORD old new)" "CONFIRM"

echo "== unit: explain_subnet_collision (#180) =="
ov="$(run_sourced "$SANDBOX" explain_subnet_collision "invalid pool request: Pool overlaps with other one on this address space" 2>&1)"
assert_contains "subnet overlap -> network.subnet hint" "$ov" "network"
assert_contains "subnet overlap -> suggests a free /24" "$ov" "/24"
assert_eq "non-overlap failure stays silent" "$(run_sourced "$SANDBOX" explain_subnet_collision "some other failure" 2>&1)" ""

echo "== black-box: config validation =="
build_val_sandbox
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"banana"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid pool rejected" "$rc" "1"
assert_contains "invalid pool message" "$out" "p2pool.pool"

# A non-IP stratum_bind must be rejected before it reaches the compose port mapping.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main","stratum_bind":"not-an-ip"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid stratum_bind rejected" "$rc" "1"
assert_contains "invalid stratum_bind message" "$out" "p2pool.stratum_bind"

# A dashboard.host with Caddyfile-breaking characters (space/braces) must be rejected before render.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"bad host{x}"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid dashboard.host rejected" "$rc" "1"
assert_contains "invalid dashboard.host message" "$out" "dashboard.host"

# proxy.donate_level must be an integer 0-99 (default 0); an out-of-range value is rejected (#173).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":150}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "out-of-range donate_level rejected" "$rc" "1"
assert_contains "donate_level message" "$out" "proxy.donate_level"
# Non-numeric donate_level is rejected (the "auto" sentinel was removed — the value is a plain integer).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":"auto"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "non-numeric donate_level rejected" "$rc" "1"

# A stratum_password with a shell/.env-unsafe character (a space) is rejected before render (#152).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main","stratum_password":"bad pass"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "unsafe stratum_password rejected" "$rc" "1"
assert_contains "stratum_password message" "$out" "p2pool.stratum_password"

# p2pool.stratum_port (#172) must be an integer 1-65535; junk and out-of-range values fail apply
# before they can render an unparseable compose port mapping.
for bad_port in '"abc"' 0 65536; do
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main","stratum_port":%s}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$bad_port" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "invalid stratum_port $bad_port rejected" "$rc" "1"
    assert_contains "stratum_port message ($bad_port)" "$out" "p2pool.stratum_port"
done

# A 1.x dashboard.workers[] config is migrated to workers.list[] BEFORE validation (#1832), so its
# malformed descriptors are still refused loudly — under the key the operator must now edit.
dw_case() { # <workers-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
dw_case '{"name":"rig1"}' "non-array 1.x dashboard.workers" "must be an array"
dw_case '[{"host":"10.0.0.5"}]' "1.x worker entry without a name" "name"
dw_case '[{"name":"rig1","host":"attacker:8080"}]' "1.x worker host smuggling a port" "workers.list[rig1].host"
dw_case '[{"name":"rig1","watts":0}]' "non-positive 1.x worker watts (#260)" "workers.list[rig1].watts"

# Duplicate names are legal (first-declared wins) but warned about, and a valid 1.x
# dashboard.workers[] list applies — migrated once, with the duplicate warning naming the new key.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"rig1","port":1111},{"name":"rig1","port":2222},{"name":"rig2","host":"worker-lan.local","token":"tok_abc123"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "valid dashboard.workers applies" "$rc" "0"
assert_contains "duplicate worker names are warned" "$out" "first-declared"
assert_contains "a 1.x dashboard.workers[] list is migrated on apply (#1832)" "$out" "Migrated the 1.x config keys"
# Nothing from the list reaches .env: the dashboard reads it from its config.json mount, and the
# per-worker token must not leak into a second secrets file.
if grep -q 'tok_abc123' "$V/.env"; then bad "worker token stays out of .env" "token landed in .env"; else ok "worker token stays out of .env"; fi

# workers.list[] is the only worker key 2.0.0 reads (#506/#1832), so this is the authoritative
# per-field enumeration; the block above keeps only enough 1.x cases to prove the migrate-then-
# validate order. The path label is built from the entry name in validate_worker_endpoints.
wl_case() { # <workers-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
wl_case '{"name":"rig1"}' "non-array workers.list" "must be an array"
wl_case '[{"host":"10.0.0.5"}]' "workers.list entry without a name" "name"
wl_case '[{"name":"rig1","host":"10.0.0.5/path"}]' "workers.list host with URL structure" "workers.list[rig1].host"
wl_case '[{"name":"rig1","host":"attacker:8080"}]' "workers.list host smuggling a port" "workers.list[rig1].host"
wl_case '[{"name":"rig1","port":65536}]' "out-of-range workers.list port" "workers.list[rig1].port"
wl_case '[{"name":"rig1","port":"8080"}]' "string workers.list port" "workers.list[rig1].port"
wl_case '[{"name":"rig1","token":"has space"}]' "unsafe workers.list token" "workers.list[rig1].token"
wl_case '[{"name":"rig1","watts":0}]' "non-positive workers.list watts (#260)" "workers.list[rig1].watts"
wl_case '[{"name":"rig1","watts":"142"}]' "string workers.list watts (#260)" "workers.list[rig1].watts"

# A valid workers.list[] applies cleanly, leaves the 1.x migration inert, and — like the 1.x shape
# — never leaks a per-worker token into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":[{"name":"rig1","host":"worker-lan.local","token":"tok_xyz789"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid workers.list applies" "$?" "0"
assert_not_contains "a canonical workers.list[] config triggers no 1.x migration" "$out" "Migrated the 1.x config keys"
if grep -q 'tok_xyz789' "$V/.env"; then bad "workers.list token stays out of .env" "token landed in .env"; else ok "workers.list token stays out of .env"; fi

# Setting BOTH workers.list[] and the removed dashboard.workers[] to DIFFERENT values is a hard
# error (#506/#1832) — migrating over the new key, or silently picking one, would leave the other a
# stale unnoticed copy of hosts and tokens. Equal values are no conflict: the old name is dropped.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig"}]}, "workers":{"list":[{"name":"new-rig"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "both workers.list and dashboard.workers set is rejected" "$rc" "1"
assert_contains "both-set refusal names both keys" "$out" "different values (workers.list[] and dashboard.workers[])"

# The refusal keys on CONTENT, not presence (#679): a part-edited 1.x config can carry an empty
# dashboard.workers[] beside the populated new key, and an empty array is never an operator choice.
# (config.reference.json no longer ships either 1.x name, so the editor's reference merge can not
# produce this shape any more — a hand-edited file still can.) The migration drops the empty key.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[]}, "workers":{"list":[{"name":"new-rig","host":"worker-lan.local"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "workers.list beside an empty dashboard.workers applies (#679)" "$?" "0"
assert_not_contains "an empty 1.x key does not trip the both-set refusal" "$out" "different values (workers.list[] and dashboard.workers[])"
assert_eq "the empty 1.x key is dropped, workers.list[] untouched" "$(jq -r '[(.dashboard|has("workers")),(.workers.list[0].name)]|map(tostring)|join(",")' "$V/config.json")" "false,new-rig"

# Mirror: a populated 1.x list beside an empty workers.list[] is no conflict either — the migration
# moves the entries in over the empty list, and they are then validated at their new path.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"10.0.0.5"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "populated dashboard.workers beside an empty workers.list applies (#679)" "$?" "0"
assert_contains "a populated 1.x list beside an empty workers.list[] is migrated" "$out" "Migrated the 1.x config keys"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "an empty workers.list must not shadow legacy entries from validation (#679)" "$?" "1"
assert_contains "the migrated entry is flagged under its new path label" "$out" "workers.list[legacy-rig].host"

# The editor contract itself (#679): the shipped config.reference.json deep-merged UNDER a valid
# operator config — exactly the document read_config serves and the editor POSTs back — must
# survive the same dry-run the control channel's preview leg runs. Fails on any future schema
# default that trips validation, whatever the key.
seed_env
cp "$ROOT/config.reference.json" "$V/reference.json"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":[{"name":"new-rig","host":"worker-lan.local"}]} }\n' "$WALLET" >"$V/operator.json"
jq -s '(.[0] | del(._docs)) * .[1]' "$V/reference.json" "$V/operator.json" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "reference-merged editor round-trip survives the preview dry-run (#679)" "$?" "0"

# Migration (#679/#1832): a 1.x dashboard.workers[] is moved to workers.list[] in place on apply —
# old key deleted, sibling workers.* keys and per-worker tokens preserved, pre-migration copy kept
# beside the file as .bak-1x. Dry runs never write (#556).
rm -f "$V/config.json.bak-1x"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"worker-lan.local","token":"tok_mig456"}]}, "workers":{"api_port":9090} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "dry run on a legacy config succeeds" "$?" "0"
if [ -f "$V/config.json.bak-1x" ]; then bad "dry run never migrates (#556)" "backup appeared"; else ok "dry run never migrates (#556)"; fi
assert_eq "dry run leaves dashboard.workers in place" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "true"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "legacy config applies and migrates" "$?" "0"
assert_contains "migration is announced" "$out" "Migrated the 1.x config keys"
assert_eq "entries moved to workers.list (token intact)" "$(jq -r '.workers.list[0].token' "$V/config.json")" "tok_mig456"
assert_eq "sibling workers.* keys survive the move" "$(jq -r '.workers.api_port' "$V/config.json")" "9090"
assert_eq "dashboard.workers is gone after migration" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "false"
assert_eq "pre-migration copy still holds the legacy key" "$(jq -r '.dashboard.workers[0].name' "$V/config.json.bak-1x")" "legacy-rig"
case "$(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" in
600) ok "migrated config.json stays owner-only" ;;
*) bad "migrated config.json stays owner-only" "mode $(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" ;;
esac
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "second apply after migration succeeds" "$?" "0"
assert_not_contains "migration runs once — nothing to move on the next apply" "$out" "Migrated the 1.x config keys"
assert_eq "the second apply preserves the migrated entries" "$(jq -r '.workers.list[0].token' "$V/config.json")" "tok_mig456"

# BEHAVIOUR CHANGE (#1832): an INVALID 1.x list is now migrated FIRST and refused after. The order
# is required — a config whose only descriptors live under the old key would otherwise validate an
# empty workers.list[] and pass. The rewrite is lossless, with .bak-1x holding the pre-migration copy.
rm -f "$V/config.json.bak-1x"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "invalid legacy config still fails apply" "$?" "1"
assert_eq "the refused config was migrated first — the 1.x key is gone" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "false"
assert_eq "the refused config's entries survive at the new path" "$(jq -r '.workers.list[0].host' "$V/config.json")" "attacker:8080"
if [ -f "$V/config.json.bak-1x" ]; then ok "a refused config keeps its pre-migration copy"; else bad "a refused config keeps its pre-migration copy" "no .bak-1x"; fi

# A migration that CANNOT run must fail closed when it would lose settings (#1832): with the
# fallback reads gone, past a failed move the apply reads an empty workers.list[] and default
# .xvb.* and REPORTS SUCCESS, dropping per-rig hosts, tokens and the XvB endpoint. The same answer
# picks the success line. An unwritable backup TARGET blocks only the cp; a directory would not.
mig_1x() { # <dashboard.workers-json> — seed a 1.x-only config and apply it; output lands in $out
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
}
rm -f "$V/config.json.bak-1x" && mig_1x '[]'
assert_rc "an empty 1.x key applies — it carries nothing to lose" "$?" "0"
assert_not_contains "and the success line claims no move that never happened" "$out" "Migrated the 1.x config keys"
: >"$V/config.json.bak-1x" && chmod 444 "$V/config.json.bak-1x" && mig_1x '[{"name":"legacy-rig","host":"worker-lan.local","token":"tok_lost99"}]'
assert_rc "a 1.x config whose migration cannot back up is REFUSED, not applied" "$?" "1"
assert_contains "the refusal says settings would be dropped" "$out" "dropping your XvB settings"
assert_eq "the refused config is left exactly as the operator wrote it" "$(jq -r '.dashboard.workers[0].token' "$V/config.json")" "tok_lost99"
mig_1x '[]'
assert_rc "an EMPTY 1.x key whose backup fails still applies (nothing to lose)" "$?" "0"
chmod 644 "$V/config.json.bak-1x" && rm -f "$V/config.json.bak-1x"

# dashboard.energy (#260): malformed price/currency fails apply loudly, like the worker descriptors.
en_case() { # <energy-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","energy":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
en_case '"nope"' "non-object dashboard.energy" "dashboard.energy must be an object"
en_case '{"cost_per_kwh":-1}' "negative cost_per_kwh" "dashboard.energy.cost_per_kwh"
en_case '{"xmr_price":"lots"}' "non-number xmr_price" "dashboard.energy.xmr_price"
en_case '{"tari_price":-2}' "negative tari_price (#520)" "dashboard.energy.tari_price"
en_case '{"currency":"US Dollars"}' "unsafe currency label" "dashboard.energy.currency"
# price_feed (#520): boolean only — a truthy string must not silently opt into network egress.
en_case '{"price_feed":"yes"}' "non-boolean price_feed (#520)" "dashboard.energy.price_feed"
# Closed schema (#33 hardening): the validator rejects any key outside {cost_per_kwh, currency,
# xmr_price, tari_price, price_feed} — defense in depth beneath the control gate's own
# unknown-path refusal.
en_case '{"cost_per_kwh":0.1,"__evil":{"x":1}}' "unknown dashboard.energy subkey" "dashboard.energy has an unknown key"

# A valid energy block (prices + feed opt-in + per-worker watts) applies; like workers[], nothing
# reaches .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","energy":{"cost_per_kwh":0.18,"xmr_price":150,"tari_price":2.5,"currency":"EUR","price_feed":true},"workers":[{"name":"rig1","watts":142}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid dashboard.energy applies" "$?" "0"

# Dashboard login (#8): a username with a Caddyfile-unsafe character (a space) is rejected before any
# hashing; the password is validated for length/charset too. Both fail fast on apply.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"bad user","password":"longenough1"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid dashboard.auth.username rejected" "$rc" "1"
assert_contains "dashboard.auth.username message" "$out" "dashboard.auth.username"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"short"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "too-short dashboard.auth.password rejected" "$rc" "1"
assert_contains "dashboard.auth.password message" "$out" "dashboard.auth.password"

# Dashboard onion (#343): a weak (LAN-acceptable but <16-char) password is rejected once the onion is on. This case
# passes the length regex and so reaches the bcrypt step, which reads docker-compose.yml for the
# pinned Caddy image — make sure it's present here (it's copied for later tests further down too).
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"shortish12"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "onion with a <16-char password rejected" "$rc" "1"
assert_contains "onion strong-password message" "$out" "at least 16 characters"
# Weak-password denylist: even at 16+ chars, a single repeated character or a well-known pattern is
# rejected once the onion is on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"aaaaaaaaaaaaaaaa"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "onion repeated-character password rejected" "$?" "1"
assert_contains "repeated-character message" "$out" "single repeated character"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"changemechangeme"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "onion well-known-weak password rejected" "$?" "1"
assert_contains "well-known-weak message" "$out" "well-known weak pattern"

# onion-client-key (#343): prints the client descriptor line when client-auth is on; errors when off.
# The line the operator pastes is "<addr-without-.onion>:descriptor:x25519:<privkey>".
cat >"$V/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_ONION_ENABLED=true
DASHBOARD_ONION_CLIENT_AUTH=true
DASHBOARD_ONION_ADDRESS=abcd234.onion
DASHBOARD_ONION_CLIENT_PRIVKEY=UNITTESTPRIVKEYBASE32
EOF
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead onion-client-key 2>&1)"
assert_rc "onion-client-key succeeds when client-auth on" "$?" "0"
assert_contains "onion-client-key prints the descriptor line (system Tor)" "$out" "abcd234:descriptor:x25519:UNITTESTPRIVKEYBASE32"
assert_contains "onion-client-key offers the Tor Browser path" "$out" "Tor Browser"
cat >"$V/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_ONION_ENABLED=true
DASHBOARD_ONION_CLIENT_AUTH=false
DASHBOARD_ONION_ADDRESS=abcd234.onion
EOF
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead onion-client-key 2>&1)"
assert_rc "onion-client-key errors when client-auth off" "$?" "1"
assert_contains "onion-client-key off message" "$out" "password-only"

# Wallet-type hard-fail (#250): p2pool pays via coinbase, which CANNOT reach a subaddress or an
# integrated address — a wrong type MINES but is NEVER paid, silently. monero_address_type is
# unit-tested in isolation; these prove parse_and_validate_config actually ABORTS apply on each,
# so the guardrail against losing every reward is wired, not just present.
SUBADDR="$VALID_SUBADDR"    # checksum-valid subaddress (the Monero project donation address)
INTADDR="$VALID_INTEGRATED" # checksum-valid integrated address (derived fixture, see the unit block)
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$SUBADDR" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "subaddress payout rejected (would never be paid)" "$rc" "1"
assert_contains "subaddress message names the type" "$out" "SUBADDRESS"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$INTADDR" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "integrated payout rejected (would never be paid)" "$rc" "1"
assert_contains "integrated message names the type" "$out" "INTEGRATED"
# Checksum hard-fail: a well-shaped primary with mistyped characters must abort apply with the
# retype message — accepted, it crash-loops p2pool on a stack that looks healthy from outside.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"4%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$(printf 'A%.0s' $(seq 94))" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "checksum-invalid payout rejected (would crash p2pool)" "$rc" "1"
assert_contains "checksum message says to re-copy the address" "$out" "checksum"
# The Tari sibling: a mistyped Tari address means merge-mine rewards silently lost, and a
# testnet address pasted from the wrong wallet is the same class of quiet loss.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "${VALID_TARI:0:90}B" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "checksum-invalid tari payout rejected" "$rc" "1"
assert_contains "tari checksum message says to re-copy" "$out" "checksum"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "testnet tari payout rejected" "$rc" "1"
assert_contains "tari network message names mainnet" "$out" "MAINNET"

# tari.wallet_address left at the placeholder -> rejected by the shared template-placeholder guard
# (else mining earns Tari that goes nowhere, the #250 failure mode). No exact-format gate
# (base58/emoji both valid), but the placeholder and any whitespace are unambiguous.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"your_tari_wallet_address"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "placeholder tari.wallet_address rejected" "$?" "1"
assert_contains "placeholder message names the template placeholders" "$out" "template placeholders"
# A stray space in the Tari address (not a control char, so the central guard misses it) -> rejected.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"12ab cd34"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "whitespace in tari.wallet_address rejected" "$?" "1"
assert_contains "whitespace message names the field" "$out" "tari.wallet_address"

# Remote mode with no host (#*): renders an empty MONERO_NODE_HOST -> p2pool/dashboard dial nothing,
# mining can't start. Must abort at validation, not silently proceed.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "remote mode without a host rejected" "$rc" "1"
assert_contains "remote-host message" "$out" "monero.remote.host"

# monero.remote.host with a comma is rejected by is_valid_host (#103): monero's remote host renders
# into the p2pool `--host` arg the same way tari's does, and the comma vector slips past the central
# control-char guard, so the field-specific guard must catch it here too.
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"1.2.3.4,fork"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero.remote.host with a comma rejected" "$?" "1"
assert_contains "monero comma-host message names the field" "$out" "monero.remote.host"

# A malformed network.subnet (#180): anything but an X.Y.Z.0/24 block renders a broken NETWORK_PREFIX
# into every service IP and the #270 firewall rules — reject before it can.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "network":{"subnet":"172.28.0.0/16"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "non-/24 network.subnet rejected" "$rc" "1"
assert_contains "network.subnet message" "$out" "network.subnet"

# ---------------------------------------------------------------------------
echo "== unit: config.reference.json stays a complete superset of every path pithead reads (#561) =="
# The closed-schema control gate (#537, pithead ~L4706) relies on this invariant: every config.json
# path pithead reads must exist in config.reference.json, or a legitimate config carrying that path
# is false-rejected on every control-channel commit (a control-plane DoS). Until now the only guard
# was the single legacy-xmrig_proxy round-trip case above. This walks pithead's own read sites,
# mirroring the #515 cross-file drift guard's shape (dashboard/tests/service/test_control_service.py,
# test_writable_key_allowlist_has_no_intra_repo_drift): a conservative, fixed-shape extractor over
# the literal read sites that FAILS LOUD on a shape it doesn't recognize (rather than silently
# skipping it), so a new read shape can't slip through unchecked.

# Deliberate exceptions: paths this extractor finds that are NOT required to have a reference
# entry. Empty today — every path pithead reads already has one (this test itself verifies that).
# Keep the mechanism here for the day a genuinely internal/env-only read needs one; each entry
# needs a why-comment.
# macOS ships bash 3.2 (no associative arrays / mapfile — matches the rest of this file), so
# extracted paths accumulate as a newline-separated string, deduped with `sort -u` at the end.
declare -a DRIFT_EXCEPTIONS=()

DRIFT_FOUND="" # newline-separated normalized dotted paths (no leading dot), deduped at the end
DRIFT_BAD=0

drift_add_path() { # <.dotted.path> (leading dot optional)
    local p="${1#.}"
    [ -n "$p" ] && DRIFT_FOUND="$DRIFT_FOUND
$p"
}

# Split a jq `//`-alternative chain into its parts and record each leading-dot part as a read
# path. A part that isn't a path must be one of the literal default shapes this codebase uses
# (empty/true/false/[]/{}, a quoted string, or a number) — anything else fails the whole test
# loudly, naming the culprit, so a new default shape gets a deliberate look instead of a silent
# pass-through.
drift_classify_chain() { # <chain> <line-label>
    local chain="$1" line="$2" part
    while [ -n "$chain" ]; do
        if [[ "$chain" == *" // "* ]]; then
            part="${chain%% // *}"
            chain="${chain#* // }"
        else
            part="$chain"
            chain=""
        fi
        if [[ "$part" == .* ]]; then
            if [[ "$part" =~ ^\.[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
                drift_add_path "$part"
            else
                bad "config-read extractor (#561)" "unrecognized path shape '$part' in $line — extend the extractor"
                DRIFT_BAD=1
            fi
        elif [ "$part" = "empty" ] || [ "$part" = "true" ] || [ "$part" = "false" ] || [ "$part" = "[]" ] || [ "$part" = "{}" ]; then
            : # known default literal, not a path
        elif [[ "$part" =~ ^\"[^\"]*\"$ ]] || [[ "$part" =~ ^-?[0-9]+$ ]]; then
            : # quoted-string or numeric default
        else
            bad "config-read extractor (#561)" "unrecognized default shape '$part' in $line — extend the extractor"
            DRIFT_BAD=1
        fi
    done
}

# config_bool '<path>' <default> call sites (pithead's null-aware boolean reader) — the path arg
# is always a plain single-quoted leading-dot literal.
while IFS= read -r p; do
    drift_add_path "$p"
done < <(grep -oE "config_bool '\.[A-Za-z0-9_.]+'" "$STACK" | sed -E "s/^config_bool '(.*)'\$/\1/")

# Single-line jq reads against $CONFIG_FILE. Filtered down to genuine simple `config_get`-style
# reads: this excludes multi-line validator blocks (an unterminated quote leaves an odd '-count on
# its opening/closing line), writes (`= $var`), and the closed-schema gate's own whole-block
# --slurpfile comparisons (those compare already-covered blocks wholesale, not a new leaf path).
while IFS=: read -r lineno text; do
    [[ "$text" == *'--slurpfile'* ]] && continue
    [[ "$text" == *' = $'* ]] && continue
    [[ "$text" == *'jq'* ]] || continue
    qcount=$(grep -o "'" <<<"$text" | wc -l)
    [ "$qcount" -eq 2 ] || continue
    filter="${text#*\'}"
    filter="${filter%\'*}"
    # In scope only if the filter is itself a path read: a bare path, a parenthesized
    # `(path // default)` prefix, or an `if path <op> ...` boolean read. Anything else (`.`,
    # `any(..|strings;...)`, an array-literal walk like `[(.path // [])[] | .name] | group_by(.)`)
    # is a structural check or a nested-element walk, not a new top-level path — out of scope.
    if [[ "$filter" == .* ]]; then
        drift_classify_chain "$filter" "pithead:$lineno"
    elif [[ "$filter" == \(* ]]; then
        # Only the parenthesized `(path // default)` prefix is attributed; whatever follows the
        # closing paren (e.g. `[] | select(.name == $n) | .host // ""`) is relative to an
        # iterated element, not a new root path — deliberately not walked further.
        inner="${filter#\(}"
        inner="${inner%%\)*}"
        drift_classify_chain "$inner" "pithead:$lineno"
    elif [[ "$filter" == "if "* ]]; then
        while IFS= read -r tok; do
            [ -n "$tok" ] && drift_add_path "$tok"
        done < <(grep -oE '\.[A-Za-z_][A-Za-z0-9_.]*(\[[^]]*\])?[[:space:]]+(!=|==)' <<<"$filter" |
            sed -E 's/(\[[^]]*\])?[[:space:]]+(!=|==)$//')
    fi
done < <(grep -n '"\$CONFIG_FILE"' "$STACK")

REF_PATHS="$(jq -r '[paths | map(select(type=="string")) | join(".")] | unique[]' "$ROOT/config.reference.json")"
DRIFT_FOUND="$(sort -u <<<"$DRIFT_FOUND")"

checked=0
missing=0
for p in $DRIFT_FOUND; do
    checked=$((checked + 1))
    grep -qxF "$p" <<<"$REF_PATHS" && continue
    allowed=0
    for a in "${DRIFT_EXCEPTIONS[@]:-}"; do
        [ "$a" = "$p" ] && allowed=1 && break
    done
    [ "$allowed" -eq 1 ] && continue
    bad "config path pithead reads has a config.reference.json entry" "'$p' is missing from config.reference.json"
    missing=$((missing + 1))
done
if [ "$checked" -eq 0 ]; then
    bad "the extractor found at least one config-read path" "found zero — extend the extractor"
elif [ "$missing" -eq 0 ] && [ "$DRIFT_BAD" -eq 0 ]; then
    ok "every extracted config-read path ($checked total) exists in config.reference.json"
fi
unset DRIFT_FOUND REF_PATHS DRIFT_BAD

echo "== unit: config.core-keys.json — valid JSON, stays inside config.reference.json (#502/#529) =="
# The core-key shortlist (#529's binding Wave-0 decision) is the ONE shared artifact between the
# wizard (here) and the dashboard form (later, #529's regroup). Every path it lists must resolve
# somewhere in config.reference.json, or the wizard could start asking about a key the closed
# schema (#537/#561) would then refuse — a config the wizard itself just generated getting
# rejected on the very first apply.
CORE_KEYS="$(jq -r '.[]' "$ROOT/config.core-keys.json" 2>/dev/null)"
if [ -z "$CORE_KEYS" ]; then
    bad "config.core-keys.json parses to a non-empty array" "got nothing — check the file exists and is valid JSON"
else
    ok "config.core-keys.json parses to a non-empty array"
fi
REF_PATHS_CORE="$(jq -r '[paths | map(select(type=="string")) | join(".")] | unique[]' "$ROOT/config.reference.json")"
core_checked=0
core_missing=0
for p in $CORE_KEYS; do
    core_checked=$((core_checked + 1))
    grep -qxF "$p" <<<"$REF_PATHS_CORE" || {
        bad "core key has a config.reference.json entry" "'$p' is missing from config.reference.json"
        core_missing=$((core_missing + 1))
    }
done
if [ "$core_checked" -gt 0 ] && [ "$core_missing" -eq 0 ]; then
    ok "every config.core-keys.json path ($core_checked total) exists in config.reference.json"
fi
unset REF_PATHS_CORE CORE_KEYS core_checked core_missing

echo "== unit: pithead render rebuilds the whole derived layer in place (#790) =="
# The defect this guards: pithead-sync delivers a NEW program on every A/B update, but .env and
# the Caddyfile kept whatever the LAST build rendered. A bench machine served a days-old
# Caddyfile whose site list didn't include pithead.local — new code, stale derived config, dead
# TLS. render is the chokepoint: derived files are regenerated from config.json + this program,
# never inspected or patched, and no container is touched.
RSUT="$SANDBOX/render-sut"
mkdir -p "$RSUT/bin"
cp "$STACK" "$RSUT/pithead" && chmod +x "$RSUT/pithead"
cp -R "$(dirname "$STACK")/build" "$RSUT/build" # service-config templates render injects from
make_stubs "$RSUT/bin"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false} }\n' "$WALLET" >"$RSUT/config.json"
(cd "$RSUT" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$RSUT/bin:$PATH" ./pithead setup --skip-deps --skip-optimize >/dev/null 2>&1)
echo "# stale — written by an older build" >"$RSUT/Caddyfile"
render_out=$(cd "$RSUT" && DOCKER_LOG=/dev/null PATH="$RSUT/bin:$PATH" ./pithead render 2>&1)
assert_rc "render exits 0 on a provisioned tree" "$?" "0"
grep -q "reverse_proxy" "$RSUT/Caddyfile" &&
    ok "a stale Caddyfile is rebuilt from config + program" ||
    bad "a stale Caddyfile is rebuilt from config + program" "$(head -2 "$RSUT/Caddyfile")"
case "$render_out" in
*"Updating containers"*) bad "render never touches containers" "$render_out" ;;
*) ok "render never touches containers" ;;
esac
unset RSUT render_out
