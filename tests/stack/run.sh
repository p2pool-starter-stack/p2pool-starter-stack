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
# shellcheck source=tests/stack/test-harness-tooling.sh
source "$HERE/test-harness-tooling.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor.sh
source "$HERE/test-doctor.sh"

echo "== unit: stack_restart — scoped tor restart (#424) =="
# `restart` bare restarts the whole stack; `restart tor` restarts ONLY tor (fresh guard
# selection when clearnet egress is stuck); anything else is rejected — other containers must
# go through apply/upgrade so a recreate applies current args (#273).
RSTBIN="$SANDBOX/rstbin"
make_stubs "$RSTBIN"
RSTLOG="$SANDBOX/restart-docker.log"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart 2>&1)"
assert_contains "bare restart restarts the whole stack" "$(cat "$RSTLOG")" "compose restart"
assert_not_contains "bare restart is not tor-scoped" "$(cat "$RSTLOG")" "compose restart tor"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart tor 2>&1)"
assert_contains "restart tor restarts only the tor container" "$(cat "$RSTLOG")" "compose restart tor"
assert_contains "restart tor warns that circuits drop" "$out" "circuits drop"
assert_contains "restart tor points at the doctor verify" "$out" "doctor"
: >"$RSTLOG"
# `restart monerod` (#972): the manual re-peer leg after a tor restart left the node out of sync.
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart monerod 2>&1)"
assert_contains "restart monerod restarts only the monerod container" "$(cat "$RSTLOG")" "compose restart monerod"
assert_contains "restart monerod says why (re-dial peers)" "$out" "re-dials"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart p2pool 2>&1)"
rc=$?
assert_rc "restart rejects any service but tor/monerod" "$rc" "1"
assert_contains "restart rejection names the contract" "$out" "takes no argument, 'tor'"
assert_eq "rejected restart touches no container" "$(cat "$RSTLOG")" ""

echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"
mkdir -p "$BOOT/bin"
cat >"$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.socket enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "neither enabled -> 1" "$?" "1"

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
assert_contains "DIY stratum pw enable advice is unchanged" \
    "$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" \
    "find it in .env / './pithead status'"
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
#
# MUTATION PROOF: drop the is_appliance branch (always emit the DIY message) and the "names no CLI
# verb" assertion below goes red; force the appliance branch unconditionally and the unchanged-DIY
# assertion right above (checked again explicitly below) goes red — neither direction passes both.
tor_heal_appliance="$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)"
assert_contains "appliance tor auto-heal disable is still INFO" "$tor_heal_appliance" "INFO"
case "$tor_heal_appliance" in
*"./pithead"*) bad "appliance tor auto-heal disable names no CLI verb" "still says: $tor_heal_appliance" ;;
*) ok "appliance tor auto-heal disable names no CLI verb" ;;
esac
assert_contains "DIY tor auto-heal disable advice is unchanged" \
    "$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)" \
    "'./pithead doctor', fix with './pithead restart tor'"
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

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-upgrade.sh
source "$HERE/test-control-upgrade.sh"

# shellcheck source=tests/stack/test-release-signing.sh
source "$HERE/test-release-signing.sh"

echo "== regression: mkdir runs before chown -R of the same tree (#550) =="
# prepare_directories and reset_dashboard used to `sudo chown -R` a data dir tree and only THEN
# `mkdir -p` inside it (the p2pool stats subdir) — EACCES for any operator uid != APP_UID, since
# the tree no longer belongs to them. ensure_directories already got this right (mkdir first,
# ensure_owner/chown last); pin the other two to the same order. Shadow sudo/mkdir to log just the
# two ops that matter, in call order — same technique as fw_then_compose above.
mkdir_before_chown() { printf '%s\n' "$1" | grep -xE 'mkdir-stats|chown-p2pool' | tr '\n' ','; }

pd_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034  # read by the sourced prepare_directories, unseen here
    MONERO_DIR="$SANDBOX/pd-monero"
    # shellcheck disable=SC2034
    TARI_DIR="$SANDBOX/pd-tari"
    P2POOL_DIR="$SANDBOX/pd-p2pool"
    TOR_DATA_DIR="$SANDBOX/pd-tor"
    DASHBOARD_DIR="$SANDBOX/pd-dashboard"
    # shellcheck disable=SC2034
    CLEARNET_STATE_DIR="$SANDBOX/pd-clearnet"
    # shellcheck disable=SC2034
    PROXY_TLS_DIR="$SANDBOX/pd-proxy-tls" # #261: prepare_directories now creates it too
    log() { :; }
    prepare_control_dirs() { :; }
    mkdir() {
        [[ "$*" == *"$P2POOL_DIR/stats"* ]] && echo mkdir-stats
        return 0
    }
    sudo() {
        [[ "$*" == *"chown -R"*"$P2POOL_DIR"* ]] && echo chown-p2pool
        return 0
    }
    prepare_directories
)
assert_eq "prepare_directories: mkdir p2pool/stats precedes chown -R of P2POOL_DIR" \
    "$(mkdir_before_chown "$pd_order")" "mkdir-stats,chown-p2pool,"

rd2_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    env_get() { echo "/nonexistent/rd2-$1"; } # non-existent dirs -> the destructive rm is skipped
    assert_safe_dir() { :; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    mkdir() {
        [[ "$*" == *"/nonexistent/rd2-P2POOL_DATA_DIR/stats"* ]] && echo mkdir-stats
        return 0
    }
    sudo() {
        [[ "$*" == *"chown -R"*"/nonexistent/rd2-P2POOL_DATA_DIR"* ]] && echo chown-p2pool
        return 0
    }
    reset_dashboard -y
)
assert_eq "reset-dashboard: mkdir p2pool/stats precedes chown -R of p2pool_dir" \
    "$(mkdir_before_chown "$rd2_order")" "mkdir-stats,chown-p2pool,"

echo "== unit: config_bool honours an explicit false (jq // false-coercion guard, #294) =="
# Regression for #294: `.x // true` returns true even when x is explicitly false (jq treats false as
# empty), which silently broke the #270 firewall opt-out (config false → .env stayed true) and
# xvb.tor=false. config_bool null-checks instead. CONFIG_FILE is the relative "config.json", so a
# fixture in the cwd is what the sourced helper reads.
CB="$SANDBOX/cb"
mkdir -p "$CB"
printf '{"network":{"tor_egress_firewall":false},"xvb":{"tor":false}}' >"$CB/config.json"
assert_eq "explicit false honoured (firewall)" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "false"
assert_eq "explicit false honoured (xvb.tor)" "$(run_sourced "$CB" config_bool '.xvb.tor' true)" "false"
printf '{"network":{"tor_egress_firewall":true}}' >"$CB/config.json"
assert_eq "explicit true honoured" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
printf '{}' >"$CB/config.json"
assert_eq "absent -> default true" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
assert_eq "absent -> default false" "$(run_sourced "$CB" config_bool '.xvb.tor' false)" "false"

echo "== unit: dashboard auth (#8) =="
# Dashboard login (#8): enabling/changing is DEST (caddy is recreated), disabling is INFO. The bcrypt
# hash is a secret and must never surface in the change preview; the internal fingerprint stays silent.
assert_contains "dash login enable is DEST" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 '' aGFzaA==)" "DEST"
assert_contains "dash login disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 aGFzaA== '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 b2xkSA== bmV3SA==)" in
*b2xkSA==* | *bmV3SA==*) bad "dash login change hides the hash" "hash value leaked into the change preview" ;;
*DEST*) ok "dash login change hides the hash (DEST, no value shown)" ;;
*) bad "dash login change hides the hash" "expected DEST" ;;
esac
assert_contains "dash login username change is shown" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_USER admin bob)" "admin → bob"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_PW_FP aaa bbb)" in
*PW_FP* | *updated* | *fingerprint*) bad "dash login fingerprint stays silent" "internal fingerprint surfaced in the preview" ;;
INFO*) ok "dash login fingerprint stays silent (no preview line)" ;;
*) bad "dash login fingerprint stays silent" "unexpected message emitted" ;;
esac

# Dashboard onion (#343): enabling is DEST (tor+caddy recreated); the client PRIVATE key must never
# surface in the change preview, even though a fresh key co-changes with the toggle.
assert_contains "onion enable is DEST" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_ONION_ENABLED false true)" "DEST"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_ONION_CLIENT_PRIVKEY OLDPRIVKEYVALUE NEWPRIVKEYVALUE)" in
*OLDPRIVKEYVALUE* | *NEWPRIVKEYVALUE*) bad "onion client privkey hidden in preview" "the client private key leaked into the change preview" ;;
*) ok "onion client privkey hidden in preview (no value shown)" ;;
esac

# New-release check toggle (#224): enabling/disabling is INFO, and the message names GitHub + Tor.
assert_contains "update-check enable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "INFO"
assert_contains "update-check enable mentions GitHub/Tor" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "GitHub"
assert_contains "update-check disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES true false)" "no longer contacts GitHub"

# generate_caddyfile renders a basic_auth block ONLY when a hash is configured, carrying the username
# and the *decoded* bcrypt string Caddy expects; with no hash the dashboard stays open (no basic_auth).
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_on="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddy renders basic_auth when login set" "$caddy_on" "basic_auth"
assert_contains "caddy basic_auth carries the username" "$caddy_on" "admin"
assert_contains "caddy basic_auth carries decoded hash" "$caddy_on" '$2y$14$UNITTESTbcrypthashvalue'
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_off="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
case "$caddy_off" in
*basic_auth*) bad "caddy stays open when no login set" "basic_auth rendered without a password" ;;
*) ok "caddy stays open when no login set (no basic_auth)" ;;
esac

echo "== unit: generate_caddyfile scheme (#140) =="
# The HTTPS-vs-HTTP choice is security-relevant: secure -> https:// + `tls internal`; insecure ->
# plain http:// and no TLS directive. (Auth on/off is covered in the dashboard-auth block above.)
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddyfile secure uses https" "$caddy_https" "https://box.lan"
assert_contains "caddyfile secure enables TLS" "$caddy_https" "tls internal"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_http="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=false HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddyfile insecure uses http" "$caddy_http" "http://box.lan"
case "$caddy_http" in
*"tls internal"*) bad "caddyfile insecure has no TLS" "'tls internal' present on a plain-HTTP site" ;;
*) ok "caddyfile insecure has no TLS" ;;
esac

echo "== unit: generate_caddyfile never publishes or binds a globally-routable address =="
# The appliance auto-publishes every address `hostname -I` reports, so on any network passing IPv6
# through, a GLOBAL unicast address was silently added — the control panel reachable from the open
# internet with nothing but the operator's router in the way. Filtering the SITE LIST is necessary
# and NOT sufficient: Caddy runs host-networked and opens ONE WILDCARD listener (`*:443`, observed
# on the bench), and it matches on Host content, never on which interface a connection arrived on
# — so a client reaching the box on the global address only has to send a Host header naming an
# address that IS listed. `bind` is the actual boundary. Addresses below are the real set from the
# physical appliance, written with reserved stand-ins: LAN v4, two podman bridge gateways, a
# globally-scoped v6 (2001:db8::/32, RFC 3849) and a ULA (fd00::/8).
_caddy_appliance() { # $1 = value for DASHBOARD_EXPOSE_PUBLIC_IP
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1 2001:db8::1 fd00::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        DASHBOARD_EXPOSE_PUBLIC_IP="$1" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
}
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_default="$(_caddy_appliance false)"
case "$caddy_default" in
*2001:db8:*) bad "the global v6 is not published as a site" "the global address appears in the Caddyfile" ;;
*) ok "the global v6 is not published as a site" ;;
esac
assert_contains "the LAN address is still published" "$caddy_default" "192.168.1.10"
assert_contains "the ULA is still published — private scope, not routable" "$caddy_default" "fd00::1"
assert_contains "a bind line closes the wildcard listener" "$caddy_default" "    bind "
assert_contains "bind keeps loopback for the host-networked dashboard" "$caddy_default" "127.0.0.1 ::1"
# The bind line is the boundary — it specifically must not carry the global address.
bindline=$(printf '%s' "$caddy_default" | grep '^    bind ')
case "$bindline" in
*2001:db8:*) bad "the bind line excludes the global v6" "global address present in: $bindline" ;;
*) ok "the bind line excludes the global v6" ;;
esac
# The bind directive must stand ALONE on its line. `$(...)` strips trailing newlines, so emitting
# one inside the helper silently glued the next directive on: `bind ... ::1    basic_auth {`,
# which Caddy will not parse — a config that would have taken the dashboard down. Caught on the
# bench, not here, so pin the shape: nothing may follow the last bound address.
case "$bindline" in
*"::1") ok "the bind directive stands alone on its line" ;;
*) bad "the bind directive stands alone on its line" "another directive was glued on: $bindline" ;;
esac
# Opt-in restores the old behaviour for a deployment that genuinely wants it.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_optin="$(_caddy_appliance true)"
assert_contains "the opt-in publishes the global v6 again" "$caddy_optin" "2001:db8::1"
case "$caddy_optin" in
*"    bind "*) bad "the opt-in leaves the listener open" "a bind line was still emitted" ;;
*) ok "the opt-in leaves the listener open" ;;
esac
# An operator who PINS dashboard.host is the most deliberately-configured box there is, and the
# first cut of this fix left exactly those boxes wide open: the bind was derived from the
# auto-expanded site list, so pinning the host produced a single-host site list and NO bind — the
# wildcard listener, and the whole exposure, back again. The bind is built from the BOX's
# addresses now, never from the site list, because they answer different questions: which Host
# values Caddy matches, versus which sockets it opens.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_pinned="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 2001:db8::1 fd00::1\n'; }
    # Pinned to a NAME (the documented appliance case, #1089), not an IP literal: an
    # IP-literal pin puts the box's own address INTO the site list too, so a bind built
    # from the site list and a bind built from the box's addresses render identically —
    # the mutation this test exists to catch (bind derived from $site_hosts instead of
    # `hostname -I`) stayed green against that fixture. A name-only pin gives the site
    # list no address literal at all, so the two derivations diverge.
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_HOST=pithead.local \
        DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "a pinned dashboard.host still gets a bind" "$caddy_pinned" "    bind "
case "$(printf '%s' "$caddy_pinned" | grep '^    bind ')" in
*2001:db8:*) bad "a pinned host does not reopen the global v6" "global address is bound" ;;
*) ok "a pinned host does not reopen the global v6" ;;
esac
# The bind must come from the BOX's own addresses, never from the (name-only) site list —
# #1021-class regression. Assert the bind line names the box's actual LAN address; under
# the site-list-derived mutation it collapses to loopback-only and this goes red.
assert_contains "a pinned dashboard.host still binds the box's own LAN address" "$(printf '%s' "$caddy_pinned" | grep '^    bind ')" "192.168.1.10"

# Loopback is appended outside the address loop, so a box reporting no usable non-public address
# still binds something reachable rather than silently falling back to a wildcard.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_noaddr="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '2001:db8::1\n'; } # ONLY a public address
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "a box with only a public address still binds loopback" "$caddy_noaddr" "    bind 127.0.0.1 ::1"

# The onion vhost must bind exactly when the LAN vhost does. A site block with no bind asks for a
# WILDCARD listener, which reopens every address the bound blocks exclude — including the
# globally-routable one. (It does NOT crash Caddy: SO_REUSEPORT lets a wildcard and a specific
# listener share a port, measured against the pinned image. The hazard is the socket, not a
# startup failure.) dashboard.secure:false with the onion enabled is documented and exempted from
# the insecure-transport warning, so this combination is reachable today.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # site blocks/binds are under test, not cert minting
    hostname() { printf '192.168.1.10 2001:db8::1\n'; }
    DASHBOARD_SECURE=false HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "insecure+onion: both vhosts bind, never one wildcard and one specific" \
    "$(printf '%s' "$caddy_onion" | grep -c '^    bind ')" "2"

# The invariant, checked by counting rather than by naming the blocks: EVERY site block in the
# rendered file carries a bind, or none does. A hardcoded count only proves the blocks that
# happened to render, and that is exactly how the HTTPS onion vhost shipped unbound — it renders
# only once DASHBOARD_ONION holds a provisioned address, so every test that left it empty saw a
# correct file. `_site_count` counts site openers (a line starting at column 0 and ending in `{`);
# the global options block opens with a bare `{`, which the leading-character class excludes.
_site_count() { printf '%s' "$1" | grep -cE '^[^[:space:]{].*\{[[:space:]]*$'; }
_bind_count() { printf '%s' "$1" | grep -c '^    bind '; }
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 2001:db8::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcdefghij234567.onion \
        DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
# Six blocks since #1123 took :80 over and #1132 took :443's own empty-200 default: the two LAN
# vhosts (the known-host :80 redirect and the HTTPS one), the :80 catch-all, the :443 catch-all,
# and the two onion vhosts. The number is worth pinning rather than deriving — it is what caught
# the redirect blocks arriving without anyone re-counting.
assert_eq "secure+onion+provisioned: the HTTPS onion vhost renders (6 site blocks)" \
    "$(_site_count "$caddy_onion_https")" "6"
assert_eq "secure+onion+provisioned: every site block binds — no unbound wildcard on :443" \
    "$(_bind_count "$caddy_onion_https")" "$(_site_count "$caddy_onion_https")"

# Counting binds proves every block HAS one; it says nothing about the VALUE, and a widened bind
# is the same exposure as a missing one. `bind 0.0.0.0 ::` on the onion blocks satisfies the count
# assertion above exactly, and reopens every address #1021 closed. So pin what the onion vhosts
# bind: the container-bridge gateway the Tor daemon dials them on, and nothing else. Both onion
# blocks (plain HTTP and the HTTPS one on the .onion name) render from _onion_bind_line, so the
# expected count is 2 — widening either one takes this to 0.
assert_eq "secure+onion+provisioned: the onion vhosts bind the bridge gateway, not a wildcard" \
    "$(printf '%s' "$caddy_onion_https" | grep -c '^    bind 172\.28\.0\.1$')" "2"
# The same invariant on the binding-off side: a DIY host renders the same three blocks and binds
# none of them, so there is still no mixed wildcard/specific pair.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https_diy="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 1; }
    hostname() { printf '192.168.1.10\n'; }
    DASHBOARD_SECURE=true HOST_IP=box.lan NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcdefghij234567.onion \
        DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "DIY secure+onion+provisioned: no site block binds" \
    "$(_bind_count "$caddy_onion_https_diy")" "0"

# No two site blocks may name the same scheme://address. Caddy rejects the WHOLE file with
# "ambiguous site definition" and, under Restart=always, crash-loops — dashboard and onion down
# together. This is reachable because `hostname -I` reports the container-bridge gateway (it is a
# real host address), so it landed in the auto-expanded LAN list AND in the onion block, which
# serves on exactly that address. With dashboard.secure:false the two schemes match and the file
# is unadaptable. Counting binds cannot see this, which is why it is a separate structural check:
# these two assertions together are the cheap tier-1 stand-in for the real `caddy adapt` gate
# tracked in #1037.
_dupe_sites() {
    printf '%s' "$1" | grep -E '^[^[:space:]{].*\{[[:space:]]*$' |
        sed 's/[[:space:]]*{[[:space:]]*$//' | tr ',' '\n' | tr -d ' ' | grep -v '^$' |
        sort | uniq -d
}
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_insecure_onion_gw="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # site blocks/dupes are under test, not cert minting
    # The physical appliance set: LAN address plus BOTH podman bridge gateways, as documented above.
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1\n'; }
    DASHBOARD_SECURE=false HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "insecure+onion on a real appliance: no duplicate site definition" \
    "$(_dupe_sites "$caddy_insecure_onion_gw")" ""
# The gateway belongs to the onion vhost alone — it must not appear in the LAN block at all.
case "$(printf '%s' "$caddy_insecure_onion_gw" | head -1)" in
*172.28.0.1*) bad "the bridge gateway stays out of the LAN site list" "gateway present in: $(printf '%s' "$caddy_insecure_onion_gw" | head -1)" ;;
*) ok "the bridge gateway stays out of the LAN site list" ;;
esac
# And with binding off, NEITHER may bind — the mirror of the case above.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_off="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 1; } # DIY: no binding at all
    hostname() { printf '192.168.1.10\n'; }
    DASHBOARD_SECURE=false HOST_IP=box.lan NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "DIY insecure+onion: neither vhost binds — no wildcard/specific clash" \
    "$(printf '%s' "$caddy_onion_off" | grep -c '^    bind ')" "0"
unset -f _caddy_appliance
unset -f _site_count _bind_count
unset -f _dupe_sites
unset caddy_default caddy_optin bindline caddy_pinned caddy_noaddr caddy_onion caddy_onion_off caddy_onion_https caddy_onion_https_diy caddy_insecure_onion_gw

echo "== unit: generate_caddyfile custom port (#740) =="
# A custom HOST_PORT moves the LAN vhost off the scheme default so a co-hosted reverse proxy keeps
# 80/443. In HTTPS mode it also emits the global `auto_https disable_redirects` so nothing holds :80.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=8443 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "custom https port binds the site" "$caddy_port_https" "https://box.lan:8443 {"
assert_contains "custom https port disables the :80 redirect" "$caddy_port_https" "auto_https disable_redirects"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_http="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=false HOST_IP=box.lan HOST_PORT=8080 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "custom http port binds the site" "$caddy_port_http" "http://box.lan:8080 {"
case "$caddy_port_http" in
*"disable_redirects"*) bad "plain-HTTP custom port has no redirect global" "'disable_redirects' present on a plain-HTTP site" ;;
*) ok "plain-HTTP custom port has no redirect global" ;;
esac
# A port that equals the scheme default (443 secure / unset) renders the same site address as an
# unset one — no port suffix. It still takes :80 over from auto_https (see #1123 below), which is
# what separates it from the custom-port case: there, :80 is deliberately left to a fronting proxy.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_default="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=443 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "explicit default port keeps the bare site address" "$caddy_port_default" "https://box.lan {"
case "$caddy_port_default" in
*":443"*) bad "default port emits no explicit suffix" "':443' suffix present at the scheme default" ;;
*) ok "default port renders the bare site address" ;;
esac

echo "== unit: the :80 redirect cannot be steered by the Host header (#1123) =="
# Caddy's built-in HTTP->HTTPS redirect is a CATCH-ALL whose target is the request's own Host
# header, so the provisioned appliance answered `Host: evil.example` on :80 with
# `308 -> https://evil.example` — measured against the real hardware. That is #1118's open
# redirector again, in the state the machine spends its life in, landing on the screen where the
# operator types the dashboard password. The render now owns :80 itself.
#
# Two blocks, not one: the KNOWN hosts keep the address the operator typed (browsing by mDNS name
# and by IP each stay on the name they used, which is also the name the certificate covers), and a
# trailing catch-all answers everything else with THIS box's canonical address.
#
# MUTATION PROOF: point the catch-all at {host}, and the two "not from the request" assertions go
# red; drop $(_bind_line) from either block and the bind assertion goes red; drop the
# disable_redirects and the takeover assertion goes red.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_redir="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # the :80 redirect shape is under test, not cert minting
    hostname() { printf '192.168.1.10 172.28.0.1 fd00::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "the default secure render takes :80 over from auto_https" "$caddy_redir" "auto_https disable_redirects"
assert_contains "the known hosts get their own :80 site" "$caddy_redir" "http://pithead.local, http://192.168.1.10"
assert_contains "and keep the address the operator actually used" "$caddy_redir" "redir https://{host}{uri} 308"
assert_contains "everything else lands on this box, by name" "$caddy_redir" "redir https://pithead.local{uri} 308"
# The defect itself: the CATCH-ALL — the block a forged Host reaches — must never build its target
# from the request. The known-host block may, because it only matches names this box answers to.
caddy_catchall="$(printf '%s\n' "$caddy_redir" | sed -n '/^http:\/\/ {/,/^}/p')"
assert_contains "the catch-all exists" "$caddy_catchall" "redir https://"
case "$caddy_catchall" in
*"{host}"* | *"{http.request.host}"*) bad "the catch-all target never comes from the request" "it interpolates the request host: $caddy_catchall" ;;
*) ok "the catch-all target never comes from the request" ;;
esac
# #1021: a site block with NO bind asks Caddy for a WILDCARD listener, which reopens every address
# the bound blocks exclude — the globally-routable one included. All new catch-alls are site blocks.
# Four site blocks in this render — the two new :80 ones, the new :443 one (#1132), and the HTTPS
# LAN vhost — so four binds.
assert_eq "every site block carries the bind, including both :80 catch-alls and the :443 one" \
    "$(printf '%s\n' "$caddy_redir" | grep -c 'bind 192.168.1.10 172.28.0.1 fd00::1 127.0.0.1 ::1')" "4"
# A custom port means a fronting proxy owns :80 (#740). Claiming it there breaks the co-hosting the
# option exists for.
case "$caddy_port_https" in
*"http:// {"*) bad "a custom port leaves :80 to the fronting proxy" "the render claimed :80 anyway" ;;
*) ok "a custom port leaves :80 to the fronting proxy" ;;
esac
# Plain-HTTP mode has no redirect to steer: :80 IS the dashboard there.
case "$caddy_http" in
*"redir"*) bad "plain-HTTP mode renders no redirect at all" "a redir line appeared on a plain-HTTP site" ;;
*) ok "plain-HTTP mode renders no redirect at all" ;;
esac

echo "== unit: the :443 catch-all replaces Caddy's empty-200 default for an unmatched Host (#1132) =="
# Caddy's OWN default for a TLS connection whose Host/SNI matches no site block is a silent
# `200`, `content-length: 0`, no body — measured, and the reason #1132's certificate/site-list
# mismatch stayed quiet: the browser just showed a blank page. #1123 gave :80 a real answer;
# this is the same trailing catch-all for :443, reusing $caddy_redir (same secure, no-custom-port,
# no-onion render as the :80 test above — own_plain_port gates both catch-alls identically).
#
# MUTATION PROOF: point the catch-all at {host} (or {http.request.host}), and the "never comes
# from the request" assertion goes red; drop $(_bind_line) from it, and the bind-count assertion
# above (already re-derived to 4) goes red; give it a `tls` line of its own, and the
# no-tls-directive assertion below goes red.
caddy_https_catchall="$(printf '%s\n' "$caddy_redir" | sed -n '/^https:\/\/ {/,/^}/p')"
assert_contains "the :443 catch-all exists" "$caddy_https_catchall" "redir https://"
case "$caddy_https_catchall" in
*"{host}"* | *"{http.request.host}"*) bad "the :443 catch-all target never comes from the request" "it interpolates the request host: $caddy_https_catchall" ;;
*) ok "the :443 catch-all target never comes from the request" ;;
esac
# No `tls` directive of its own: proven against real Caddy (`caddy adapt`) that a hostless catch-all
# falls through to the file's default TLS connection policy — the SAME certificate the named vhost
# below already loads — so a matching SNI never reaches this block, and an unmatched one completes
# the handshake against that certificate (an honest name-mismatch warning) instead of an empty 200.
# An explicit `tls` line here would ask Caddy to manage a SEPARATE certificate for a site address
# with no hostname to manage one against.
case "$caddy_https_catchall" in
*"    tls "*) bad "the :443 catch-all carries no tls directive of its own" "a tls line appeared: $caddy_https_catchall" ;;
*) ok "the :443 catch-all carries no tls directive of its own" ;;
esac
# A custom port means a fronting proxy owns :443 too (#740), the same reasoning as :80 above.
case "$caddy_port_https" in
*"https:// {"*) bad "a custom port leaves :443 to the fronting proxy" "the render claimed the bare :443 catch-all anyway" ;;
*) ok "a custom port leaves :443 to the fronting proxy" ;;
esac

# Onion + custom LAN port together (#740 × #343): the LAN vhost moves to the custom port and the
# `disable_redirects` global is emitted, but the onion vhost MUST stay on the bridge gateway's bare
# :80 — Tor's HiddenServicePort maps 80 -> NETWORK_PREFIX.1:80, so a custom LAN port must not leak
# onto it. Also confirms the global-options block is still valid Caddyfile with onion vhosts appended.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_onion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=8443 DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion+custom-port: LAN vhost moves to the custom port" "$caddy_port_onion" "https://box.lan:8443 {"
assert_contains "onion+custom-port: redirect global still emitted" "$caddy_port_onion" "auto_https disable_redirects"
assert_contains "onion+custom-port: onion vhost stays on the bridge's bare :80" "$caddy_port_onion" "http://172.28.0.1 {"
case "$caddy_port_onion" in
*"172.28.0.1:8443"* | *"172.28.0.1:80 "*) bad "onion vhost keeps its bare bridge port" "custom LAN port leaked onto the onion vhost" ;;
*) ok "onion vhost keeps its bare bridge port (no custom-port leak)" ;;
esac

echo "== unit: generate_caddyfile onion vhost (#343) =="
# With the dashboard onion enabled, generate_caddyfile appends a SECOND site bound to the bridge
# gateway (NETWORK_PREFIX.1) — reachable only from the tor container, never the LAN — serving plain
# HTTP (Tor is the transport) and carrying the SAME basic_auth block as the LAN site.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion vhost bound to the bridge gateway" "$caddy_onion" "http://172.28.0.1 {"
assert_contains "onion vhost carries basic_auth" "$caddy_onion" "basic_auth"
# The onion site (everything after the gateway address) must not get a TLS directive.
onion_site="${caddy_onion#*172.28.0.1}"
case "$onion_site" in
*"tls internal"*) bad "onion vhost is plain HTTP" "'tls internal' present on the onion site" ;;
*) ok "onion vhost is plain HTTP (no tls internal)" ;;
esac
# Fail-closed belt: onion enabled but NO auth hash -> generate_caddyfile must refuse (rc 1).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
)
assert_rc "onion without a login refuses to render" "$?" "1"
# Onion OFF -> no gateway vhost appears at all.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_noonion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=false NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_not_contains "no onion vhost when disabled" "$caddy_noonion" "172.28.0.1"
# Once the .onion address is provisioned, ALSO render an HTTPS onion vhost (self-signed cert for the
# .onion name) so Tor Browser's default http->https upgrade lands on a working :443 (#343). Both the
# http (:80, bridge IP) and https (:443, .onion name) onion sites must be present.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcd234onionname.onion NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost still present with the address set (#343)" "$caddy_onion_https" "http://172.28.0.1 {"
assert_contains "onion HTTPS vhost on the .onion name (#343)" "$caddy_onion_https" "https://abcd234onionname.onion {"
https_site="${caddy_onion_https#*https://abcd234onionname.onion}"
case "$https_site" in
*"tls internal"*) ok "onion HTTPS vhost uses a self-signed cert (tls internal)" ;;
*) bad "onion HTTPS vhost uses tls internal" "no 'tls internal' on the https onion site" ;;
esac
assert_contains "onion HTTPS vhost carries the same basic_auth (#343)" "$https_site" "basic_auth"
# Not yet provisioned (placeholder address) -> HTTP onion vhost only, no HTTPS one (a later apply adds it).
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_ph="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=placeholder NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost renders even before the address is captured (#343)" "$caddy_onion_ph" "http://172.28.0.1 {"
assert_not_contains "no HTTPS onion vhost until the .onion address is provisioned (#343)" "$caddy_onion_ph" "https://placeholder"

echo "== unit: generate_caddyfile access log (#349) =="
# Every vhost logs each request as one JSON line to a shared file. Growth is bounded by Caddy's
# native rolling (4 MiB per file, current + 2 rolled); mode 0644 lets the non-root dashboard
# read what root-run Caddy writes (Caddy's own default is 0600, unreadable across the mount).
assert_contains "access log block rendered" "$caddy_https" "output file /var/log/caddy/access.log"
assert_contains "access log is JSON" "$caddy_https" "format json"
assert_contains "access log growth is bounded (roll_size)" "$caddy_https" "roll_size 4MiB"
assert_contains "rolled files are capped (roll_keep)" "$caddy_https" "roll_keep 2"
assert_contains "access log stays dashboard-readable (mode 0644)" "$caddy_https" "mode 0644"
log_count="$(printf '%s' "$caddy_onion_https" | grep -c 'output file /var/log/caddy/access.log')"
assert_eq "every vhost (LAN + onion HTTP + onion HTTPS) writes the shared log" "$log_count" "3"

echo "== unit: onion client-auth crypto (#343) =="
# Portable base32 (RFC 4648 vectors) — no external `base32` binary (absent on macOS).
assert_eq "b32encode_hex('f') = MY" "$(run_sourced "$SANDBOX" b32encode_hex 66)" "MY"
assert_eq "b32encode_hex('foobar') = MZXW6YTBOI" "$(run_sourced "$SANDBOX" b32encode_hex 666f6f626172)" "MZXW6YTBOI"
# x25519 client-auth keypair: two distinct 52-char base32 keys.
kp="$(run_sourced "$SANDBOX" generate_onion_client_keypair)"
set -- $kp
assert_eq "client pubkey is 52-char base32" "${#1}" "52"
assert_eq "client privkey is 52-char base32" "${#2}" "52"
if [ "$1" != "$2" ]; then ok "client pub != priv"; else bad "client pub != priv" "identical keys generated"; fi
case "$1$2" in *[!A-Z2-7]*) bad "client keys use the base32 alphabet" "non-base32 char present" ;; *) ok "client keys use the base32 alphabet" ;; esac

# provision_onion_client_auth writes the authorized_clients descriptor into the hidden-service dir.
ac_root="$SANDBOX/tor-ac"
rm -rf "$ac_root"
mkdir -p "$ac_root"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    ensure_owner() { :; } # skip the sudo chown in the unit sandbox
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=true \
        DASHBOARD_ONION_CLIENT_PUBKEY=placeholder TOR_DATA_DIR="$ac_root" \
        APP_UID=$(id -u) APP_GID=$(id -g) provision_onion_client_auth >/dev/null 2>&1
)
ac_file="$ac_root/dashboard/authorized_clients/dashboard.auth"
if [ -f "$ac_file" ]; then ok "authorized_clients/dashboard.auth is written"; else bad "authorized_clients/dashboard.auth is written" "file missing"; fi
assert_contains "authorized_clients carries a v3 descriptor" "$(cat "$ac_file" 2>/dev/null)" "descriptor:x25519:"
# Tor refuses a HiddenServiceDir that is group/other-accessible, so the modes provision_onion_client_auth
# sets (pithead ~L3096-3099) are load-bearing, not a hardening nicety — a wrong mode is a silent onion
# provisioning failure. GNU stat first (CI/Linux), BSD/macOS `-f %Lp` fallback (the repo's known gotcha:
# `stat -f` is a VALID-but-wrong flag on Linux, so it must never run first).
ac_dir_mode="$(stat -c '%a' "$ac_root/dashboard" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard" 2>/dev/null)"
ac_subdir_mode="$(stat -c '%a' "$ac_root/dashboard/authorized_clients" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard/authorized_clients" 2>/dev/null)"
ac_key_mode="$(stat -c '%a' "$ac_file" 2>/dev/null || stat -f '%Lp' "$ac_file" 2>/dev/null)"
assert_eq "hidden-service dir is 0700" "$ac_dir_mode" "700"
assert_eq "authorized_clients dir is 0700" "$ac_subdir_mode" "700"
assert_eq "authorized_clients key file is 0600" "$ac_key_mode" "600"
# With client-auth OFF, an existing authorized_clients dir is cleared (onion falls back to password-only).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=false TOR_DATA_DIR="$ac_root" \
        provision_onion_client_auth >/dev/null 2>&1
)
if [ -d "$ac_root/dashboard/authorized_clients" ]; then bad "client-auth off clears authorized_clients" "dir still present"; else ok "client-auth off clears authorized_clients"; fi

echo "== unit: ensure_onion_password auto-generates (#343) =="
# Onion on + no password -> generate a strong one into config.json (login stays admin), so the
# fail-closed onion is usable without the operator inventing a 16+ char secret. CONFIG_FILE is
# readonly (config.json in the cwd), so drive it via a dedicated dir rather than an override.
autopw_dir="$SANDBOX/onion-autopw"
mkdir -p "$autopw_dir"
autopw_cfg="$autopw_dir/config.json"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$autopw_cfg"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
genpw="$(jq -r '.dashboard.auth.password // ""' "$autopw_cfg")"
if [ "${#genpw}" -ge 16 ]; then ok "ensure_onion_password writes a >=16-char password"; else bad "ensure_onion_password writes a >=16-char password" "length ${#genpw}"; fi
# Idempotent: a second run leaves an already-set password alone (no churn).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password leaves an existing password alone" "$(jq -r '.dashboard.auth.password' "$autopw_cfg")" "$genpw"
# No-op when the onion is off — never touches config.json.
printf '{"dashboard":{}}' >"$autopw_cfg"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password no-op when onion off" "$(jq -r '.dashboard.auth.password // "none"' "$autopw_cfg")" "none"

# Regression: stack_upgrade must run ensure_onion_password BEFORE parse_and_validate_config (as
# setup/apply do), so enabling the onion with no password on a deployed stack auto-generates one
# instead of erroring at the validation gate. Drive the REAL ensure_onion_password through
# stack_upgrade with everything downstream stubbed; onion-on + no password must end with a >=16-char pw.
upg_autopw_dir="$SANDBOX/upgrade-onion-autopw"
mkdir -p "$upg_autopw_dir"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$upg_autopw_dir/config.json"
(
    cd "$upg_autopw_dir" || exit
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    # NB: mv is left REAL — ensure_onion_password uses it to commit the generated password. The only
    # other mv here (.env.new swap) is a harmless no-op on the stubbed-away .env.new.
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    is_source_checkout() { return 1; }
    docker() { :; }
    log() { :; }
    stack_upgrade >/dev/null 2>&1
)
upg_genpw="$(jq -r '.dashboard.auth.password // ""' "$upg_autopw_dir/config.json")"
if [ "${#upg_genpw}" -ge 16 ]; then ok "upgrade auto-generates the onion password (not an error)"; else bad "upgrade auto-generates the onion password (not an error)" "length ${#upg_genpw}"; fi

echo "== black-box: rotate-dashboard-onion command flow (#356) =="
# The rotate command reprovisions the onion then persists via render_env. It must (a) resolve the host
# so HOST_IP is set for render_env — rotate skipped that and crashed on the unbound var under set -u —
# and (b) preserve DEPLOYMENT_COMPLETED, which render_env would otherwise reset to false, breaking the
# next apply/upgrade. Drive the real command with stubs; render_env reports the two values it would write.
rot_out=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$SANDBOX/rot-tor"
    mkdir -p "$TOR_DATA_DIR/dashboard"
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { [ "$1" = "DEPLOYMENT_COMPLETED" ] && echo true || echo "x.onion"; }
    resolve_dashboard_host() { HOST_IP="host.set"; }
    provision_tor() { :; }
    render_env() { echo "HOST_IP=${HOST_IP-UNSET} DC=${DEPLOYMENT_COMPLETED-UNSET}"; }
    onion_client_key() { :; }
    rotate_dashboard_onion -y
)
assert_contains "rotate resolves the host before render_env — no unbound HOST_IP (#356)" "$rot_out" "HOST_IP=host.set"
assert_contains "rotate preserves DEPLOYMENT_COMPLETED across render_env (#356)" "$rot_out" "DC=true"

echo "== black-box: upgrade captures a just-enabled dashboard onion address (#356) =="
# Enabling the onion via `upgrade` must read the freshly-generated .onion back into .env; apply's
# capture only runs when the config changed, so an upgrade-based enable left the address uncaptured.
upg_capture() { # <onion_enabled> <current_onion> -> "captured" when provision runs, "caddyfile-rendered" per generate_caddyfile call
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { echo caddyfile-rendered; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    provision_dashboard_onion() {
        DASHBOARD_ONION="upgcap5678.onion"
        echo captured
    }
    export DASHBOARD_ONION_ENABLED="$1"
    export DASHBOARD_ONION="$2"
    stack_upgrade
}
assert_contains "upgrade captures the onion address when enabled + uncaptured (#356)" "$(upg_capture true '')" "captured"
assert_not_contains "upgrade skips capture when the onion is disabled (#356)" "$(upg_capture false '')" "captured"

# #546: the upgrade-path capture must ALSO regenerate the Caddyfile — the render preamble ran while
# the address was still the placeholder, so a capture without a re-render leaves the HTTPS onion
# vhost missing forever (the next apply no-ops on an unchanged config). Count generate_caddyfile
# calls: once from the preamble, a second time only when the capture leg runs.
upg_regen_on=$(upg_capture true '' | grep -c "caddyfile-rendered")
case "$upg_regen_on" in
2) ok "upgrade capture regenerates the Caddyfile (#546)" ;;
*) bad "upgrade capture regenerates the Caddyfile (#546)" "generate_caddyfile ran $upg_regen_on time(s), want 2 (preamble + capture)" ;;
esac
upg_regen_off=$(upg_capture false '' | grep -c "caddyfile-rendered")
case "$upg_regen_off" in
1) ok "upgrade without onion renders the Caddyfile once (#546)" ;;
*) bad "upgrade without onion renders the Caddyfile once (#546)" "generate_caddyfile ran $upg_regen_off time(s), want 1" ;;
esac

echo "== black-box: apply captures + renders the HTTPS onion vhost in the SAME run (#546) =="
# Before the fix, apply's post-up capture block (provision_dashboard_onion && render_env) never
# re-ran generate_caddyfile, so the https://<onion> vhost (#360) only appeared on some LATER,
# unrelated apply — a re-apply that changed nothing hit the "No configuration changes detected"
# early return before ever reaching generate_caddyfile. Drive the real apply() with the heavy
# machinery stubbed away but generate_caddyfile left REAL, so the Caddyfile is the actual proof.
AOC="$SANDBOX/apply-onion-capture"
mkdir -p "$AOC"
printf 'DEPLOYMENT_COMPLETED=true\n' >"$AOC/.env"
caddy_apply_capture=$(
    cd "$AOC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    env_changed_keys() { echo DASHBOARD_ONION_ENABLED; }
    inject_service_configs() { :; }
    provision_onion_client_auth() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { :; }
    compose_up_checked() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    # The shadowed capture: the address is unknown until the recreated tor container publishes it
    # post-up, exactly like the real provision_dashboard_onion.
    provision_dashboard_onion() { DASHBOARD_ONION="captured1234abcd.onion"; }
    P2POOL_ONION=p2pa.onion HOST_IP=box.lan DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 DASHBOARD_ONION_ENABLED=true \
        DASHBOARD_ONION=placeholder apply -y >/dev/null 2>&1
    cat Caddyfile
)
assert_contains "apply: HTTPS onion vhost appears in the SAME apply run (#546)" "$caddy_apply_capture" "https://captured1234abcd.onion {"
assert_contains "apply: HTTP onion vhost (bridge gateway) still present" "$caddy_apply_capture" "http://172.28.0.1 {"

echo "== black-box: rotate-dashboard-onion regenerates the Caddyfile (#546) =="
# Before the fix, rotate restarted caddy WITHOUT regenerating the Caddyfile, so caddy kept serving
# the retired onion's HTTPS vhost and the new address had none. Seed a Caddyfile as if a PRIOR
# generate_caddyfile ran for the old address, then rotate with a shadowed provision_tor that
# returns a new one — the fix must leave exactly the new address's vhost behind.
ROC="$SANDBOX/rotate-onion-capture"
mkdir -p "$ROC/rot-tor/dashboard"
cat >"$ROC/Caddyfile" <<'EOF'
https://box.lan {
    tls internal
}

http://172.28.0.1 {
}

https://oldaddr1234.onion {
    tls internal
}
EOF
caddy_rotate_capture=$(
    cd "$ROC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { :; }
    render_env() { :; }
    resolve_dashboard_host() { HOST_IP=box.lan; }
    # The shadowed provision the issue asks for: a fresh address on rotate.
    provision_tor() { DASHBOARD_ONION="newaddr5678.onion"; }
    onion_client_key() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$ROC/rot-tor" DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 rotate_dashboard_onion -y >/dev/null 2>&1
    cat Caddyfile
)
assert_not_contains "rotate drops the retired onion's HTTPS vhost (#546)" "$caddy_rotate_capture" "oldaddr1234.onion"
assert_contains "rotate adds the new onion's HTTPS vhost in the same run (#546)" "$caddy_rotate_capture" "https://newaddr5678.onion {"

echo "== unit: dashboard_onion_status surfaces the onion URL for status/doctor (#343) =="
# The shared resolver behind both `pithead status` and `pithead doctor`: it returns the onion URL +
# reach-it hint ONLY when the onion is enabled AND provisioned, and NEVER the client private key.
onion_env_dir() { # <enabled> <address> <client_auth> -> a dir whose .env carries those keys
    local d
    d="$(mktemp -d)"
    {
        echo "DASHBOARD_ONION_ENABLED=$1"
        echo "DASHBOARD_ONION_ADDRESS=$2"
        echo "DASHBOARD_ONION_CLIENT_AUTH=$3"
    } >"$d/.env"
    echo "$d"
}
od_on="$(onion_env_dir true abcd.onion true)"
# Enabled + provisioned + client-auth: URL plus the pointer to onion-client-key (assert the stable
# prefix — the trailing "'<path> onion-client-key'" varies with $0).
assert_contains "status onion: URL + client-key pointer when client-auth on" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "http://abcd.onion (client-auth ON + login; get your client key with"
# And it must NOT leak a client private key.
assert_not_contains "status onion: never prints a client key" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "descriptor:x25519:"
od_noauth="$(onion_env_dir true abcd.onion false)"
assert_eq "status onion: login-required line when client-auth off" \
    "$(run_sourced "$od_noauth" dashboard_onion_status)" "http://abcd.onion (login required)"
od_unprov="$(onion_env_dir true placeholder true)"
assert_eq "status onion: nothing while unprovisioned (placeholder)" \
    "$(run_sourced "$od_unprov" dashboard_onion_status)" ""
od_off="$(onion_env_dir false abcd.onion true)"
assert_eq "status onion: nothing when the onion is disabled" \
    "$(run_sourced "$od_off" dashboard_onion_status)" ""
rm -rf "$od_on" "$od_noauth" "$od_unprov" "$od_off"

echo "== unit: dashboard_sync_progress re-renders per-chain sync from /api/state (#384) =="
# The one-curl re-render behind `pithead status`: read the dashboard's own /api/state (host-local,
# no auth) and print per-chain progress, skipping synced chains and degrading quietly when the app
# isn't up. Stub curl to serve a canned body — real jq parses it, matching the dashboard's shape.
SP="$(mktemp -d)"
mkdir -p "$SP/bin"
cat >"$SP/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
EOF
chmod +x "$SP/bin/curl"
# Monero mid-sync + Tari still discovering its target height: both surface, monero with numbers.
sp_body='{"sync":{"monero":{"state":"syncing","percent":87,"current":2451000,"target":2810000,"remaining":359000},"tari":{"state":"loading","percent":0,"current":0,"target":0,"remaining":0}}}'
out="$(CURL_BODY="$sp_body" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "sync progress: monero syncing shows percent + blocks-to-go" "$out" "87% (2451000 / 2810000 blocks, 359000 to go)"
assert_contains "sync progress: no-target chain reads as discovering" "$out" "discovering the target height"
assert_contains "sync progress: header names the #35 hold" "$out" "held until it completes"
# Both synced: nothing to say (steady-state status stays quiet), non-zero return.
sp_done='{"sync":{"monero":{"state":"done","percent":100,"current":10,"target":10,"remaining":0},"tari":{"state":"done","percent":100,"current":5,"target":5,"remaining":0}}}'
assert_eq "sync progress: both synced -> silent" \
    "$(CURL_BODY="$sp_done" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)" ""
# Only monero still syncing: the synced tari is omitted (not listed as done).
sp_partial='{"sync":{"monero":{"state":"syncing","percent":42,"current":100,"target":238,"remaining":138},"tari":{"state":"done","percent":100,"current":5,"target":5,"remaining":0}}}'
out="$(CURL_BODY="$sp_partial" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "sync progress: partial -> monero listed" "$out" "monero"
assert_not_contains "sync progress: partial -> synced tari omitted" "$out" "tari"
# Dashboard app not answering yet (curl fails): quiet, non-zero — graceful during startup.
assert_eq "sync progress: dashboard down -> silent" \
    "$(CURL_RC=22 PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)" ""
rm -rf "$SP"

# shellcheck source=tests/stack/test-release.sh
source "$HERE/test-release.sh"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"
    t_rest="${tier#*:}"
    t_val="${t_rest%%:*}"
    t_human="${t_rest#*:}"
    if grep -qE ": ${t_val}[ ,]" "$tier_cfg" && grep -qF "$t_human" "$tier_doc"; then
        ok "XvB $t_name tier: config.py $t_val matches docs '$t_human'"
    else
        bad "XvB $t_name tier docs match TIER_DEFAULTS" "config $t_val / doc '$t_human' out of sync"
    fi
done

echo "== unit: explain_subnet_collision (#180) =="
ov="$(run_sourced "$SANDBOX" explain_subnet_collision "invalid pool request: Pool overlaps with other one on this address space" 2>&1)"
assert_contains "subnet overlap -> network.subnet hint" "$ov" "network"
assert_contains "subnet overlap -> suggests a free /24" "$ov" "/24"
assert_eq "non-overlap failure stays silent" "$(run_sourced "$SANDBOX" explain_subnet_collision "some other failure" 2>&1)" ""

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/new.env"
assert_eq "env_get_file reads value" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with =" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"
mkdir -p "$PROV"
printf '  9.9.9 \n' >"$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"
mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

echo "== unit: ensure_owner conditional recursive chown (#255) =="
# ensure_owner migrates a data tree to the container's uid ONLY when something in it is foreign-owned,
# and scans the WHOLE tree (not just the top dir) — an install upgraded from the root-container era has
# a user-owned dir but root-owned *contents*, and those are what the non-root container can't overwrite.
# MEMORY flags "must scan contents not just dir" as a past bug, so we guard both the decision and that
# the find scan is recursive (no -maxdepth). sudo is stubbed to record what it would chown.
EO="$SANDBOX/eo"
mkdir -p "$EO/bin" "$EO/tree/sub"
: >"$EO/tree/sub/file"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/sudo.log"\n' "$EO" >"$EO/bin/sudo"
chmod +x "$EO/bin/sudo"
myuid="$(id -u)"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" "$myuid" "$myuid" >/dev/null 2>&1
assert_rc "clean tree (already owned) stays sudo-free" "$?" "0"
assert_eq "clean tree triggers no chown" "$(grep -c chown "$EO/sudo.log")" "0"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" 424242 424242 >/dev/null 2>&1
assert_contains "foreign ownership triggers a recursive chown" "$(cat "$EO/sudo.log")" "chown -R 424242:424242 $EO/tree"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/nonexistent" "$myuid" "$myuid" >/dev/null 2>&1
assert_rc "missing dir is a no-op" "$?" "0"
assert_eq "missing dir triggers no chown" "$(grep -c chown "$EO/sudo.log")" "0"
# Regression guard for #255: the ownership scan must be whole-tree. Stub `find` to capture its args and
# assert ensure_owner never passes -maxdepth (which would re-introduce the top-dir-only bug).
mkdir -p "$EO/findbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/find.log"\n' "$EO" >"$EO/findbin/find"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EO/findbin/sudo"
chmod +x "$EO/findbin/find" "$EO/findbin/sudo"
: >"$EO/find.log"
PATH="$EO/findbin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" "$myuid" "$myuid" >/dev/null 2>&1
assert_not_contains "the ownership scan is recursive (no -maxdepth)" "$(cat "$EO/find.log")" "-maxdepth"
assert_contains "the ownership scan keys off foreign uid" "$(cat "$EO/find.log")" "! -uid $myuid"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-cli.sh
source "$HERE/test-cli.sh"

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

# dashboard.workers (#172): malformed per-worker descriptors fail apply loudly — a typo must not
# be silently dropped at dashboard runtime. host charset is the #122 guard (no port/path/userinfo).
dw_case() { # <workers-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
dw_case '{"name":"rig1"}' "non-array dashboard.workers" "must be an array"
dw_case '[{"host":"10.0.0.5"}]' "worker entry without a name" "name"
dw_case '[{"name":"rig1","host":"10.0.0.5/path"}]' "worker host with URL structure" "dashboard.workers[rig1].host"
dw_case '[{"name":"rig1","host":"attacker:8080"}]' "worker host smuggling a port" "dashboard.workers[rig1].host"
dw_case '[{"name":"rig1","port":65536}]' "out-of-range worker port" "dashboard.workers[rig1].port"
dw_case '[{"name":"rig1","port":"8080"}]' "string worker port" "dashboard.workers[rig1].port"
dw_case '[{"name":"rig1","token":"has space"}]' "unsafe worker token" "dashboard.workers[rig1].token"
dw_case '[{"name":"rig1","watts":0}]' "non-positive worker watts (#260)" "dashboard.workers[rig1].watts"
dw_case '[{"name":"rig1","watts":"142"}]' "string worker watts (#260)" "dashboard.workers[rig1].watts"

# Duplicate names are legal (first-declared wins) but warned about, and a valid dashboard.workers[]
# list applies. Also proves the legacy fallback still validates + warns once (#506).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"rig1","port":1111},{"name":"rig1","port":2222},{"name":"rig2","host":"worker-lan.local","token":"tok_abc123"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "valid dashboard.workers applies" "$rc" "0"
assert_contains "duplicate worker names are warned" "$out" "first-declared"
assert_contains "legacy dashboard.workers is warned as deprecated (#506)" "$out" "dashboard.workers[] is deprecated"
# Nothing from the list reaches .env: the dashboard reads it from its config.json mount, and the
# per-worker token must not leak into a second secrets file.
if grep -q 'tok_abc123' "$V/.env"; then bad "worker token stays out of .env" "token landed in .env"; else ok "worker token stays out of .env"; fi

# workers.list[] (#506): the current sub-key validates with the same rules, at the new path — every
# per-field error message above named its path via dashboard.workers[]; each case repeats here
# named via workers.list[], proving the dynamic path label in validate_worker_endpoints tracks
# whichever key is actually in use, not a hardcoded string.
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
wl_case '[{"name":"rig1","token":"has space"}]' "unsafe workers.list token" "workers.list[rig1].token"
wl_case '[{"name":"rig1","watts":0}]' "non-positive workers.list watts (#260)" "workers.list[rig1].watts"

# A valid workers.list[] applies cleanly, warns no deprecation, and — like the legacy shape — never
# leaks a per-worker token into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":[{"name":"rig1","host":"worker-lan.local","token":"tok_xyz789"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid workers.list applies" "$?" "0"
assert_not_contains "workers.list applying raises no deprecation warning" "$out" "deprecated"
if grep -q 'tok_xyz789' "$V/.env"; then bad "workers.list token stays out of .env" "token landed in .env"; else ok "workers.list token stays out of .env"; fi

# Setting BOTH workers.list[] and dashboard.workers[] is a hard error (#506) — a silent pick would
# leave the other a stale, unnoticed copy of hosts/tokens. REVERT-PROOF: the exact case a partial
# revert of the dual-read change would silently start allowing again.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig"}]}, "workers":{"list":[{"name":"new-rig"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "both workers.list and dashboard.workers set is rejected" "$rc" "1"
assert_contains "both-set refusal names both keys" "$out" "sets both workers.list[] and dashboard.workers[]"

# The refusal keys on CONTENT, not presence (#679): the dashboard config editor merges
# config.reference.json (which ships BOTH keys as empty-array schema defaults) under the
# operator's config before serving the form, and round-trips the merged doc on save — so an
# empty array beside the populated key must neither refuse nor warn.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[]}, "workers":{"list":[{"name":"new-rig","host":"worker-lan.local"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "workers.list beside an empty dashboard.workers applies (#679)" "$?" "0"
assert_not_contains "empty legacy default does not trip the both-set refusal" "$out" "sets both workers.list[] and dashboard.workers[]"
assert_not_contains "empty legacy default raises no deprecation warning" "$out" "deprecated"

# Mirror: a populated legacy list beside an empty workers.list (the same reference-merge shape,
# for an operator still on the deprecated key) selects — and still validates — the legacy entries.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"10.0.0.5"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "populated dashboard.workers beside an empty workers.list applies (#679)" "$?" "0"
assert_contains "legacy shape beside the empty default still warns as deprecated" "$out" "dashboard.workers[] is deprecated"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "an empty workers.list must not shadow legacy entries from validation (#679)" "$?" "1"
assert_contains "shadowed legacy entry is flagged under its own path label" "$out" "dashboard.workers[legacy-rig].host"

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

# Migration (#679): a validated legacy dashboard.workers[] is moved to workers.list[] in place on
# apply — old key deleted, sibling workers.* keys and per-worker tokens preserved, pre-migration
# copy kept beside the file (the .bak-control naming). Dry runs never write.
rm -f "$V/config.json.bak-workers"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"worker-lan.local","token":"tok_mig456"}]}, "workers":{"api_port":9090} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "dry run on a legacy config succeeds" "$?" "0"
if [ -f "$V/config.json.bak-workers" ]; then bad "dry run never migrates (#556)" "backup appeared"; else ok "dry run never migrates (#556)"; fi
assert_eq "dry run leaves dashboard.workers in place" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "true"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "legacy config applies and migrates" "$?" "0"
assert_contains "migration is announced with the backup path" "$out" "Migrated dashboard.workers[] to workers.list[]"
assert_eq "entries moved to workers.list (token intact)" "$(jq -r '.workers.list[0].token' "$V/config.json")" "tok_mig456"
assert_eq "sibling workers.* keys survive the move" "$(jq -r '.workers.api_port' "$V/config.json")" "9090"
assert_eq "dashboard.workers is gone after migration" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "false"
assert_eq "pre-migration copy still holds the legacy key" "$(jq -r '.dashboard.workers[0].name' "$V/config.json.bak-workers")" "legacy-rig"
case "$(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" in
600) ok "migrated config.json stays owner-only" ;;
*) bad "migrated config.json stays owner-only" "mode $(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" ;;
esac
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "second apply after migration succeeds" "$?" "0"
assert_not_contains "migration runs once — nothing to move on the next apply" "$out" "Migrated dashboard.workers[]"
assert_not_contains "no deprecation warning after migration" "$out" "deprecated"

# An INVALID legacy list fails validation before the migration hook — config and backup untouched.
rm -f "$V/config.json.bak-workers"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "invalid legacy config still fails apply" "$?" "1"
assert_eq "failed validation leaves the legacy key untouched" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "true"
if [ -f "$V/config.json.bak-workers" ]; then bad "no backup written for a refused config" "backup appeared"; else ok "no backup written for a refused config"; fi

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

echo "== black-box: dashboard auth lifecycle (#8) =="
# The hashing reads the pinned Caddy image out of docker-compose.yml and shells out to the stubbed
# `caddy hash-password`, so the whole enable → reuse → change → disable path runs offline.
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
AUTH_LOG="$V/auth-docker.log"

# (1) ENABLE: a password turns on basic_auth — hash + fingerprint persisted, plaintext never stored.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":0}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "auth enable applies cleanly" "$rc" "0"
assert_eq "auth username persisted" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_USER)" "admin"
hash1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)"
fp1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)"
[ -n "$hash1" ] && ok "auth hash persisted (base64)" || bad "auth hash persisted (base64)" "empty"
[ -n "$fp1" ] && ok "auth fingerprint persisted" || bad "auth fingerprint persisted" "empty"
assert_contains "auth hashed via the pinned caddy image" "$(cat "$AUTH_LOG")" "hash-password"
assert_contains "Caddyfile gains basic_auth" "$(cat "$V/Caddyfile")" "basic_auth"
case "$(cat "$V/.env" "$V/Caddyfile")" in
*hunter2hunter2*) bad "auth plaintext never persisted" "password leaked into .env/Caddyfile" ;;
*) ok "auth plaintext never persisted" ;;
esac

# (2) REUSE: re-applying (here nudging an unrelated knob) keeps the SAME hash and does NOT re-hash —
# bcrypt is salted, so a stable fingerprint is what keeps the Caddyfile from churning every apply.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "unchanged password keeps the same hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" "$hash1"
case "$(cat "$AUTH_LOG")" in
*hash-password*) bad "unchanged password is not re-hashed" "caddy hash-password was called again" ;;
*) ok "unchanged password is not re-hashed (stable hash)" ;;
esac

# (3) CHANGE: a new password re-hashes (fingerprint changes) and recreates the caddy container.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"freshpass99"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "changed password re-hashes" "$(cat "$AUTH_LOG")" "hash-password"
assert_eq "changed password updates fingerprint" "$([ "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)" != "$fp1" ] && echo changed)" "changed"
assert_contains "auth change recreates caddy" "$(cat "$AUTH_LOG")" "restart caddy"

# (4) DISABLE: clearing the password drops basic_auth — hash cleared, dashboard reachable again.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "auth disable clears the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" ""
case "$(cat "$V/Caddyfile")" in
*basic_auth*) bad "auth disable drops basic_auth" "basic_auth still present in the Caddyfile" ;;
*) ok "auth disable drops basic_auth" ;;
esac

echo "== unit: render-quadlet parity vs os/quadlet fixtures (#77 phase 1) =="
# The renderer must reproduce the spike-proven unit set byte-for-byte from the fixture env — the
# os/quadlet files ran live in the #78 spike, so any drift here needs a bench re-proof, not just
# an updated fixture.
QOUT="$SANDBOX/quadlet-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/fixture.env" "$QOUT" >/dev/null
for f in mining.network proxy.network tor.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet parity: $f" "$(diff -u "$ROOT/os/quadlet/$f" "$QOUT/$f" 2>&1 | head -c 300)" ""
done
assert_eq "remote render emits no node units" "$(find "$QOUT" -name 'monerod.container' -o -name 'tari.container' | wc -l | tr -d ' ')" "0"
# The local-node variant (bench-proven 2026-07-24): profiles on, 11 files, node units included.
QLOCAL="$SANDBOX/quadlet-local-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/local/fixture.env" "$QLOCAL" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    p2pool.container xmrig-proxy.container caddy.container docker-proxy.container \
    docker-control.container dashboard.container; do
    assert_eq "quadlet local parity: $f" "$(diff -u "$ROOT/os/quadlet/local/$f" "$QLOCAL/$f" 2>&1 | head -c 300)" ""
done
# The payout-confirm variant (bench-proven 2026-07-24): both wallet profiles, 13 files, the
# dashboard gains the payout env keys only in this set (the others stay byte-identical).
QPAY="$SANDBOX/quadlet-payout-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/payout/fixture.env" "$QPAY" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    wallet-rpc.container tari-wallet.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet payout parity: $f" "$(diff -u "$ROOT/os/quadlet/payout/$f" "$QPAY/$f" 2>&1 | head -c 300)" ""
done
assert_eq "local render emits no wallet units" "$(find "$QLOCAL" -name 'wallet-rpc.container' -o -name 'tari-wallet.container' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor-appliance.sh
source "$HERE/test-doctor-appliance.sh"

echo "== unit: firstboot wizard token + spool consume (#77 phase 3) =="
# Token: pit- prefix + 6 chars from the unambiguous alphabet (never 0, O, 1, I, or l).
tok=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "token shape" "$(printf '%s' "$tok" | grep -cE '^pit-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$')" "1"
tok2=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "tokens vary" "$([ "$tok" = "$tok2" ] && echo same || echo differ)" "differ"
# Consume: a valid submission installs config.json + marks applied; an invalid one surfaces the
# error into the spool for the form and installs nothing; an empty spool is rc 2.
WSPOOL="$V/data/firstboot-test"
mkdir -p "$WSPOOL"
rm -f "$V/config.json"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"} }\n' "$WALLET" >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" && echo rc0)
assert_contains "valid submission accepted" "$out" "rc0"
assert_eq "valid submission installs config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
assert_eq "applied marker set" "$([ -f "$WSPOOL/applied" ] && echo yes)" "yes"
rm -f "$WSPOOL/applied"
printf '{ "monero": {"wallet_address":"8-not-a-primary"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"} }\n' >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "invalid submission rejected" "$out" "rc1"
assert_eq "rejection surfaces spool error" "$([ -s "$WSPOOL/error.txt" ] && echo yes)" "yes"
assert_eq "rejection leaves no candidate" "$([ -f "$WSPOOL/config.json" ] || echo gone)" "gone"
out=$(run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$WSPOOL"
# Restore the sandbox config for later sections.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
# A missing env file is a hard error, not an empty render.
out=$(run_sourced "$SANDBOX" render_quadlet_units "$SANDBOX/no-such.env" "$SANDBOX/quadlet-none" 2>&1)
assert_contains "render-quadlet missing env errors" "$out" "env file not found"

echo "== unit: firstboot_consume_restore — restore-at-setup (#909, #786 sub-issue B) =="
# A genuine encrypted backup (the same `pithead backup` #908 rides), fed through the wizard's
# restore-consume exactly as the host loop would: decrypt, verify BEFORE anything is touched,
# validate the embedded config through a copy, and land it as a normal accepted config.json —
# the SAME contract firstboot_consume_spool gives a typed submission. Physical path (#695): see
# the backup/restore black-box block above for why `pwd -P` matters here too.
RS="$(cd "$SANDBOX" && pwd -P)/restore-consume"
mkdir -p "$RS/build/tari" "$RS/data/tor" "$RS/data/dashboard" "$RS/bin"
cp "$STACK" "$RS/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"
cat >"$RS/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;; # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$RS/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$RS/bin/docker" "$RS/bin/sudo"
cat >"$RS/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RSTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$RS/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore fixture: backup exits 0" "$rc" "0"
rarchive="$(ls "$RS"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rarchive" ] && [ -f "$rarchive" ]; } && ok "restore fixture: encrypted archive created" || bad "restore fixture: encrypted archive created" "no .enc archive"

RSPOOL="$RS/data/firstboot-test"
mkdir -p "$RSPOOL"
rm -f "$RS/config.json"

# 1) Accept: the right passphrase decrypts, verifies, validates and lands config.json — settings,
# the Tor identity and the dashboard database all come back, and neither the archive nor the
# passphrase survive the attempt.
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" && echo rc0)
assert_contains "valid restore accepted" "$out" "rc0"
assert_eq "valid restore installs config.json" "$([ -f "$RS/config.json" ] && echo yes)" "yes"
assert_contains "valid restore carries the original wallet" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_eq "valid restore brings back the Caddyfile" "$(cat "$RS/Caddyfile" 2>/dev/null)" "CADDY-ORIG"
assert_eq "valid restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-ORIG"
assert_eq "applied marker set" "$([ -f "$RSPOOL/applied" ] && echo yes)" "yes"
assert_eq "the archive is consumed" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
rm -f "$RSPOOL/applied" "$RS/config.json" # clean slate for the rejection cases below

# 1b) Installer door (installer=1): the config surfaces for the credentials card, but the
# machine itself is NOT restored — decrypted keys must never rest on the stick — and the
# accepted archive + passphrase park in the carry dir for the ESP staging the install branch
# performs (the target's first boot does the real restore).
printf 'STICK-CADDY\n' >"$RS/Caddyfile"
printf 'STICK-DB\n' >"$RS/data/dashboard/dashboard.db"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
RCARRY="$RS/carry"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" 1 && echo rc0)
assert_contains "installer restore accepted" "$out" "rc0"
assert_contains "installer restore surfaces the config for the card" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_eq "installer restore does NOT restore onto the stick (Caddyfile untouched)" "$(cat "$RS/Caddyfile")" "STICK-CADDY"
assert_eq "installer restore does NOT restore onto the stick (db untouched)" "$(cat "$RS/data/dashboard/dashboard.db")" "STICK-DB"
assert_eq "accepted archive parked for the ESP carry" "$([ -f "$RCARRY/archive" ] && echo yes)" "yes"
assert_eq "passphrase parked beside it" "$(cat "$RCARRY/pass" 2>/dev/null)" "hunter2"
assert_eq "installer restore consumes the spool archive" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
rm -rf "$RCARRY"
rm -f "$RSPOOL/applied" "$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" # fixtures back to their case-1 state for the cases below
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"

# 2) Bad passphrase: rejected before anything is touched.
printf 'CORRUPTED\n' >"$RS/Caddyfile"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'not-the-passphrase' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "wrong passphrase rejected" "$out" "rc1"
assert_contains "wrong passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "assphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$RS/Caddyfile")" "CORRUPTED"
assert_eq "the archive is consumed even on rejection" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained even on rejection" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RSPOOL/error.txt"

# 3) Encrypted archive, no passphrase supplied at all.
cp "$rarchive" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "missing passphrase rejected" "$out" "rc1"
assert_contains "missing passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "passphrase"
rm -f "$RSPOOL/error.txt"

# 4) Oversize: refused on SIZE alone, before any decrypt/extract — content is irrelevant.
truncate -s 67108865 "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "oversize archive rejected" "$out" "rc1"
assert_contains "oversize archive names the cap" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "too large"
rm -f "$RSPOOL/error.txt"

# 5) Malformed: neither the encrypted magic nor gzip's — falls back exactly like a rejected
# config, never blocking setup.
printf 'garbage-not-an-archive' >"$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "malformed archive rejected" "$out" "rc1"
assert_contains "malformed archive names the problem" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "not a Pithead backup archive"
assert_eq "malformed archive leaves config.json untouched" "$([ -f "$RS/config.json" ] || echo gone)" "gone"
rm -f "$RSPOOL/error.txt"

# 6) Path-traversal / symlink defense: a well-formed gzip archive (passes the magic + integrity
# checks) whose members escape the restore set must be refused BEFORE anything is staged to "/".
# A Pithead backup is only regular files under known prefixes, so a symlink or a ".." member is an
# attack. Built with real tar so the guard faces the exact bytes it would on a box.
MAL="$RS/mal"
mkdir -p "$MAL/pithead"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"     # live file the escape would try to clobber via symlink
ln -s /etc/shadow "$MAL/pithead/Caddyfile" # symlink escape
(cd "$MAL" && tar -czf "$RSPOOL/restore-archive" pithead) 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "a symlink member is refused" "$out" "rc1"
assert_contains "the symlink refusal names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "unsafe paths or links"
assert_eq "a symlink archive touches nothing" "$(cat "$RS/Caddyfile")" "CADDY-ORIG"
rm -f "$RSPOOL/error.txt" "$RSPOOL/restore-passphrase"
# Absolute-path member (stored with a leading slash via -P): would land at /… on cp -a.
printf 'EVIL\n' >"$MAL/evil"
(cd "$MAL" && tar -Pczf "$RSPOOL/restore-archive" "$MAL/evil") 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "an absolute-path member is refused" "$out" "rc1"
rm -f "$RSPOOL/error.txt"

# 7) Nothing to consume.
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$RS"

echo "== black-box: uninstall keeps the operator's files (#77 phase 1) =="
# Without confirmation: aborts, changes nothing.
touch "$V/Caddyfile"
out=$(cd "$V" && printf 'no\n' | PATH="$V/bin:$PATH" ./pithead uninstall 2>&1) || true
assert_contains "uninstall aborts without the confirm word" "$out" "Aborted"
assert_eq "aborted uninstall keeps .env" "$([ -f "$V/.env" ] && echo yes)" "yes"
# With -y: rendered files go, the operator's files stay.
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1)
assert_contains "uninstall names the kept files" "$out" "config.json"
assert_eq "uninstall removes .env" "$([ -f "$V/.env" ] || echo gone)" "gone"
assert_eq "uninstall removes Caddyfile" "$([ -f "$V/Caddyfile" ] || echo gone)" "gone"
assert_eq "uninstall keeps config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall --bogus 2>&1) || true
assert_contains "uninstall rejects unknown options" "$out" "Unknown option"
# Re-render the sandbox .env for the sections below — uninstall just deleted it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"

echo "== unit: stack_backup — one bounded retry on a tar race (#970) =="
# Even with the stack stopped, tar can lose a race against a teardown's last flush — exit 1
# under pipefail failed the whole backup once on the KVM bench. The fixture sudo fails the
# FIRST tar with tar's real race error, then passes through: one retry must land the archive.
RB="$(cd "$SANDBOX" && pwd -P)/backup-retry"
mkdir -p "$RB/build/tari" "$RB/data/tor" "$RB/data/dashboard" "$RB/bin"
cp "$STACK" "$RB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RB/build/tari/"
cat >"$RB/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$RB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
if [ "$1" = "tar" ] && [ ! -f "${RETRY_MARK:?}" ]; then
    : >"$RETRY_MARK"
    echo "tar: fixture-member: file changed as we read it" >&2
    exit 1
fi
exec "$@"
EOF
chmod +x "$RB/bin/docker" "$RB/bin/sudo"
cat >"$RB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RB/config.json"
out="$(cd "$RB" && PATH="$RB/bin:$PATH" RETRY_MARK="$RB/first-tar-failed" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "backup survives one tar race via the retry" "$rc" "0"
assert_contains "the first failure is loud, not silent" "$out" "retrying once"
assert_eq "the retry actually ran (fixture consumed)" "$([ -f "$RB/first-tar-failed" ] && echo yes)" "yes"
rbarchive="$(ls "$RB"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rbarchive" ] && [ -s "$rbarchive" ]; } && ok "retry produced a real archive" || bad "retry produced a real archive" "no .enc archive"

echo "== unit: backup_require_items — refuses a missing/dangling required item before anything is touched (#1244) =="
# The KVM battery caught tar failing to stat config.json AFTER the stack had already been
# stopped for the backup (#1059) — a real archive attempt was thrown away and the box paid for
# a stop/start cycle it didn't need. These two functions are pulled out of stack_backup and
# sourced directly (the same pattern gate_ready/os_update_rollback_verdict use) so the refusal
# and the diagnostic dump are provable without driving tar, sudo, or the whole backup flow.
BRI="$SANDBOX/backup-require-items"
mkdir -p "$BRI"
: >"$BRI/present.txt"
ln -s "$BRI/nowhere" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/missing.txt" 2>&1)
rc=$?
assert_rc "a genuinely missing item refuses (nonzero)" "$rc" "1"
assert_contains "the refusal names the exact resolved path" "$out" "$BRI/missing.txt"
assert_contains "the refusal says what to do next" "$out" "pithead setup"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/dangling.txt" 2>&1)
rc=$?
assert_rc "a dangling symlink refuses the same way a missing file does" "$rc" "1"
assert_contains "the dangling-symlink refusal also names the path" "$out" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" 2>&1)
rc=$?
assert_rc "every item present passes silently" "$rc" "0"
assert_eq "nothing is printed when every required item is present" "$out" ""

echo "== unit: backup_diagnose_items — a tar failure names its cwd and each item's real state (#1244) =="
# The diagnostic half of the same fix: when tar fails anyway (both #970 retry attempts spent),
# the failure names the -C directory it ran against and what each resolved item actually was —
# so the NEXT occurrence of #1059's run-conditional vanish doesn't need another bench boot
# before anyone can look.
out=$(run_sourced "$BRI" backup_diagnose_items "/" "$BRI/present.txt" "$BRI/missing.txt" "$BRI/dangling.txt" 2>&1)
assert_contains "names the -C directory tar ran against" "$out" 'tar ran with -C "/"'
assert_contains "a present item is reported present with its own listing" "$out" "present: "
assert_contains "the present item's line names its own path" "$out" "$BRI/present.txt"
assert_contains "a missing item is called out by name" "$out" "MISSING: $BRI/missing.txt"
assert_contains "a dangling symlink is distinguished from a plain miss" "$out" "DANGLING SYMLINK: $BRI/dangling.txt"
unset BRI out rc

echo "== unit: stack_backup — an absolute CONFIG_FILE override is archived at its real path, not a doubled one (#1244) =="
# PITHEAD_CONFIG_FILE (the control gate's staged-config preview seam) can be an ABSOLUTE path.
# Before this fix, stack_backup unconditionally prefixed $PWD onto it ("$PWD/$CONFIG_FILE"),
# which for an absolute override built a doubled, nonexistent path like
# "$PWD//tmp/staged.json" — tar would fail to stat THAT, the same shape #1059 hunted, just from
# a cause the live capture ruled out rather than the one that actually happened.
CJ="$SANDBOX/backup-cfg-override"
mkdir -p "$CJ/build/tari" "$CJ/data/tor" "$CJ/data/dashboard" "$CJ/bin"
cp "$STACK" "$CJ/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CJ/build/tari/"
cat >"$CJ/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$CJ/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$CJ/bin/docker" "$CJ/bin/sudo"
cat >"$CJ/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=CJTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
# The override candidate lives OUTSIDE $CJ entirely — a doubled "$CJ/<absolute candidate>" path
# could never coincidentally resolve to something real, so a pass here can only mean the join
# is absolute-safe, not a lucky path collision.
CJALT="$SANDBOX/backup-cfg-override-elsewhere"
mkdir -p "$CJALT"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$CJALT/candidate.json"
out=$(cd "$CJ" && PATH="$CJ/bin:$PATH" PITHEAD_CONFIG_FILE="$CJALT/candidate.json" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)
rc=$?
assert_rc "backup succeeds against an absolute CONFIG_FILE override" "$rc" "0"
cjarchive="$(ls "$CJ"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$cjarchive" ] && [ -s "$cjarchive" ]; } && ok "override archive was written" || bad "override archive was written" "no .enc archive"
# The archive's member list is the ground truth for what tar was actually told to stat: the
# override's OWN absolute path (leading / stripped, same as every other item), never a doubled
# artifact of the old $PWD-prefix bug.
cjlist=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:hunter2 -in "$cjarchive" 2>/dev/null | tar -tzf - 2>/dev/null)
assert_contains "the archive carries the override's real, un-doubled path" "$cjlist" "${CJALT#/}/candidate.json"
assert_not_contains "the archive never carries a \$PWD-doubled override path" "$cjlist" "${CJ#/}${CJALT}"
unset CJ CJALT out rc cjarchive cjlist

echo "== unit: install.sh host gate (#77 phase 1) =="
# The installer hard-fails on the platforms the stack cannot run on, before any download.
IBIN="$SANDBOX/install-stub-bin"
mkdir -p "$IBIN"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo aarch64 ;; esac\n' >"$IBIN/uname"
chmod +x "$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-amd64" "$out" "x86_64-only"
printf '#!/bin/bash\ncase "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; esac\n' >"$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-Linux" "$out" "runs on Linux"

echo "== unit: install.sh download verification fails CLOSED (#868) =="
# The two security-critical branches of the public curl installer: the bundle sha256 against the
# release manifest, and the cosign signature against the repo-pinned key. This is the path a new
# operator runs BEFORE any of the bundle's own defenses exist — a tampered bundle that gets
# extracted has already won — so a mismatch must install NOTHING. The stubs model each remote
# artifact as a file served by basename; absent file = curl -f failure, exactly the shape the
# script distinguishes (absent degrades politely, present-but-wrong is fatal).
ISB=$(mktemp -d)
mkdir -p "$ISB/bin" "$ISB/srv" "$ISB/work"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' >"$ISB/bin/uname"
cat >"$ISB/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o)
        out="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *) shift ;;
    esac
done
src="$CURL_SRV/$(basename "$url")"
[ -f "$src" ] || exit 22
[ -n "$out" ] && cp "$src" "$out"
exit 0
EOF
# macOS has no sha256sum; shasum -a 256 prints the identical "hash  file" shape.
printf '#!/bin/bash\nif command -v /usr/bin/sha256sum >/dev/null; then exec /usr/bin/sha256sum "$@"; fi\nexec shasum -a 256 "$@"\n' >"$ISB/bin/sha256sum"
printf '#!/bin/bash\nexit "${COSIGN_RC:-0}"\n' >"$ISB/bin/cosign"
chmod +x "$ISB/bin/"*
# A canned release bundle whose pithead stub proves the handoff (install.sh exec's it).
mkdir -p "$ISB/bundle-src/pithead-x"
printf '#!/bin/bash\necho "SETUP-REACHED $*"\n' >"$ISB/bundle-src/pithead-x/pithead"
chmod +x "$ISB/bundle-src/pithead-x/pithead"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/bundle-src" pithead-x
# One invocation per scenario; PATH keeps the stubs first, cosign joins only where a test wants it.
irun() { # <dest-subdir> [env overrides via preceding assignments]
    (
        cd "$ISB/work" || exit
        CURL_SRV="$ISB/srv" PITHEAD_VERSION=v9.9.9 PITHEAD_ALLOW_ANY_DISTRO=1 \
            PITHEAD_DIR="$ISB/work/$1" PATH="$ISB/bin:$PATH" bash "$ROOT/install.sh" 2>&1
    )
}

# sha256 verified against the manifest: match proceeds to the handoff, mismatch installs NOTHING.
# The manifest line is written by release.sh's OWN producer, not a hand-copied format: this grep is
# the only integrity check a fresh install has before cosign exists on the box, and the two sides
# drifting apart would leave every appliance install silently trusting HTTPS alone (#77 phase 1,
# #1115). MUTATION PROOF: drop the backticks from append_bundle_sha256's format and "sha256 match is
# announced" goes red — install.sh finds no sha, degrades to HTTPS trust and installs anyway, which
# is the actual damage: a silent downgrade, not a visible failure.
: >"$ISB/srv/ingredients-v9.9.9.md" # it appends; write_manifest has run by then in a real cut
# shellcheck disable=SC1090
(set -- && PATH="$ISB/bin:$PATH" && source "$REL" 2>/dev/null && set +eu &&
    append_bundle_sha256 "$ISB/srv/ingredients-v9.9.9.md" "$ISB/srv/pithead.tar.gz")
out=$(irun ok-sha)
assert_rc "verified install runs to the setup handoff" "$?" "0"
assert_contains "sha256 match is announced" "$out" "sha256 verified"
assert_contains "the extracted pithead was exec'd" "$out" "SETUP-REACHED"
printf 'bundle sha256: `%s`\n' "$(printf 'a%.0s' $(seq 64))" >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun bad-sha) && rc=0 || rc=$?
assert_rc "sha256 mismatch refuses to install" "$rc" "1"
assert_contains "the mismatch names both digests' verdict" "$out" "sha256 mismatch"
assert_eq "nothing was installed on a sha256 mismatch" "$([ -e "$ISB/work/bad-sha" ] && echo present || echo absent)" "absent"
# A manifest with no sha line (pre-v1.15) and a missing manifest both degrade politely.
printf 'no digest here\n' >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-sha-line)
assert_contains "manifest without a sha degrades to HTTPS trust" "$out" "carries no bundle sha256"
rm -f "$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-manifest)
assert_contains "missing manifest degrades to HTTPS trust" "$out" "No release manifest"

# cosign: a present-but-bad signature is FATAL; an absent one is a note; a signature whose
# pinned key cannot be fetched is fatal too (the cross-channel check cannot be half-done).
touch "$ISB/srv/pithead.tar.gz.sig" "$ISB/srv/cosign.pub"
out=$(irun sig-ok)
assert_rc "good signature installs" "$?" "0"
assert_contains "signature verification is announced" "$out" "signature verified"
out=$(COSIGN_RC=1 irun sig-bad) && rc=0 || rc=$?
assert_rc "bad signature refuses to install" "$rc" "1"
assert_contains "the failure names the signature" "$out" "signature verification FAILED"
assert_eq "nothing was installed on a bad signature" "$([ -e "$ISB/work/sig-bad" ] && echo present || echo absent)" "absent"
rm -f "$ISB/srv/cosign.pub"
out=$(irun sig-nokey) && rc=0 || rc=$?
assert_rc "signature without a fetchable pinned key refuses" "$rc" "1"
assert_contains "the failure names the pinned key" "$out" "pinned key could not be fetched"
rm -f "$ISB/srv/pithead.tar.gz.sig"
out=$(irun sig-absent)
assert_contains "absent signature is noted, not fatal" "$out" "No bundle signature"

# The remaining guards on the same path: an occupied target refuses before downloading, and a
# bundle with no pithead executable refuses after extraction.
mkdir -p "$ISB/work/taken"
out=$(irun taken) && rc=0 || rc=$?
assert_rc "an existing target dir refuses" "$rc" "1"
assert_contains "the refusal names the dir" "$out" "already exists"
mkdir -p "$ISB/empty/pithead-x" && touch "$ISB/empty/pithead-x/README"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/empty" pithead-x
out=$(irun corrupt) && rc=0 || rc=$?
assert_rc "a bundle without a pithead executable refuses" "$rc" "1"
assert_contains "the refusal suspects corruption" "$out" "no pithead executable"
rm -rf "$ISB"
unset -f irun

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

echo "== black-box: 'pithead up' under the migration hold starts everything but the chain (#851) =="
# PITHEAD_HOLD_CHAIN=1 is set by the appliance boot path on the first boot of a data_migration
# bundle: the chain services (the lmdb holders) must not start before the A/B slot commits. The
# compose service list comes from a dedicated stub because the shared one answers nothing for
# `compose config --services`, and stack_status's tests rely on exactly that.
HCB="$SANDBOX/hold-chain-bin"
mkdir -p "$HCB"
cat >"$HCB/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose config --services") printf 'tor\nmonerod\ntari\nwallet-rpc\ntari-wallet\np2pool\nxmrig-proxy\ncaddy\ndashboard\n' ;;
esac
exit 0
EOF
chmod +x "$HCB/docker"
HOLD_LOG=$(mktemp)
seed_env
out="$(cd "$V" && DOCKER_LOG="$HOLD_LOG" PATH="$HCB:$V/bin:$PATH" PITHEAD_HOLD_CHAIN=1 ./pithead up 2>&1)"
assert_rc "up succeeds under the hold" "$?" "0"
assert_contains "the hold is announced for the journal" "$out" "holding chain services"
up_line=$(grep "compose up" "$HOLD_LOG" | tail -1)
assert_contains "tor still starts under the hold" "$up_line" "tor"
assert_contains "p2pool still starts under the hold" "$up_line" "p2pool"
assert_contains "the dashboard still starts under the hold" "$up_line" "dashboard"
assert_not_contains "monerod is withheld" "$up_line" "monerod"
assert_not_contains "tari and tari-wallet are withheld" "$up_line" "tari"
assert_not_contains "wallet-rpc is withheld" "$up_line" "wallet-rpc"
# Without the env the same sandbox starts the whole stack — the hold is opt-in per boot.
HOLD_LOG2=$(mktemp)
(cd "$V" && DOCKER_LOG="$HOLD_LOG2" PATH="$HCB:$V/bin:$PATH" ./pithead up >/dev/null 2>&1)
up_line2=$(grep "compose up" "$HOLD_LOG2" | tail -1)
assert_not_contains "a plain up names no service subset" "$up_line2" "p2pool"
rm -f "$HOLD_LOG" "$HOLD_LOG2"

# Healthchecks.io (#79): absent => no ping URL (off).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks off by default (no ping URL)" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" ""

# A ping URL propagates verbatim to .env (the URL is the on switch; Tor is always used).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "healthchecks":{"ping_url":"https://hc-ping.com/abc"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks ping_url propagated" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" "https://hc-ping.com/abc"

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

echo "== black-box: xmrig-proxy knobs (#152 stratum auth, #173 donate-level) =="
# stratum_password "auto" generates + persists a stable secret and surfaces it for rigs; an explicit
# proxy.donate_level propagates verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "proxy":{"donate_level":1}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
sp1="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
case "$sp1" in ?*) ok "stratum_password auto generated a secret" ;; *) bad "stratum_password auto generated a secret" "got empty" ;; esac
assert_eq "donate-level explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "1"
assert_contains "stratum auth surfaced for rigs" "$(run_sourced "$V" announce_stratum_auth 2>&1)" "Stratum authentication is ON"

echo "== unit: announce_local_miner hands off the stratum URL + secret only when opted in (#593) =="
# The local-miner opt-in surfaces the two values a co-located RigForge install needs (pool URL +
# stratum secret) and NOTHING else — off by default, loopback when the bind allows it, the bound
# LAN address when it doesn't (the #593 stratum_bind edge case), and RigForge-owns-tuning stated.
LM="$SANDBOX/lm"
mkdir -p "$LM"
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
# Opt-out (default): prints nothing at all.
printf '{"local_miner":{"enabled":false}}' >"$LM/config.json"
assert_eq "opt-out prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Absent block also prints nothing (default false).
printf '{}' >"$LM/config.json"
assert_eq "absent local_miner prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Opt-in, 0.0.0.0 bind: loopback URL + the secret + the RigForge-owns-tuning note.
printf '{"local_miner":{"enabled":true}}' >"$LM/config.json"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "opt-in surfaces loopback pool URL" "$lm_out" "127.0.0.1:3333"
assert_contains "opt-in surfaces the stratum secret" "$lm_out" "s3cr3t"
assert_contains "opt-in states RigForge owns host tuning" "$lm_out" "RigForge"
# Custom port + specific LAN bind: target the bound address, not hardcoded loopback (#593 edge case).
printf 'STRATUM_BIND=192.168.1.9\nSTRATUM_PORT=4444\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "LAN bind targets the bound address:port" "$lm_out" "192.168.1.9:4444"
# No stratum password set: say so rather than printing a blank pass.
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=\n' >"$LM/.env"
assert_contains "no-password case is stated explicitly" "$(run_sourced "$LM" announce_local_miner 2>&1)" "none set"
# On the appliance the miner is BUILT IN: the announcement must promise the machine handles it,
# never instruct an install on a box with no shell — the exact gap that was filed as a defect.
lm_out="$(PITHEAD_APPLIANCE=1 run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "appliance: announces the built-in worker" "$lm_out" "built-in RigForge worker"
assert_not_contains "appliance: no install-it-yourself instruction" "$lm_out" "point a RigForge install"

# Re-apply: an "auto" password must be STABLE (reused, not rotated) — like the proxy token.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_password auto stable across apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "$sp1"

echo "== black-box: stratum-over-TLS render + cert lifecycle (#261) =="
# Default: off, no cert generated. The dir var still renders (compose always mounts it :ro).
assert_eq "stratum TLS off by default" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "false"
[ ! -f "$V/data/proxy-tls/cert.pem" ] && ok "no cert generated while TLS is off" ||
    bad "no cert generated while TLS is off" "cert.pem exists"
# Knob on: real openssl generates the keypair once; key owner-only; fingerprint announced and
# STABLE across a second apply (the fingerprint is what every rig pins — regenerating it on each
# apply would break every TLS rig).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum TLS renders true" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "true"
[ -f "$V/data/proxy-tls/cert.pem" ] && [ -f "$V/data/proxy-tls/key.pem" ] &&
    ok "TLS keypair generated on first apply" || bad "TLS keypair generated on first apply" "missing files"
assert_eq "TLS key is owner-only" "$(file_mode "$V/data/proxy-tls/key.pem")" "600"
assert_contains "fingerprint announced for rig pinning" "$out" "Stratum TLS is ON"
fp1="$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "cert (and its pinned fingerprint) stable across apply" \
    "$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)" "$fp1"
# announce_stratum_tls prints the pin in xmrig's format: 64 lowercase hex chars, no colons.
announced="$(run_sourced "$V" announce_stratum_tls 2>&1 | grep -oE '[0-9a-f]{64}' | head -1)"
assert_eq "announced fingerprint is the cert's own, xmrig format" \
    "$announced" "$(printf '%s' "$fp1" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
# compose forwards the toggle and mounts the keypair dir read-only.
assert_contains "compose passes PROXY_STRATUM_TLS to the proxy (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_STRATUM_TLS=${PROXY_STRATUM_TLS'
assert_contains "compose mounts the TLS keypair dir :ro (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_TLS_DIR:-./data/proxy-tls}:/tls:ro'

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-monero-tari.sh
source "$HERE/test-monero-tari.sh"

echo "== black-box: upgrade re-renders generated config (#128) =="
# `upgrade` used to be just `up --build`, leaving the generated .env/Caddyfile/Tari config stale
# after a git pull. It must now re-render them while preserving secrets.
U="$SANDBOX/upgrade"
mkdir -p "$U/build/tari" "$U/dashboard" "$U/data/monero" "$U/data/tari" "$U/data/p2pool/stats" "$U/data/tor" "$U/data/dashboard"
: >"$U/dashboard/Dockerfile"
cp "$STACK" "$U/pithead"
make_stubs "$U/bin"
cp "$ROOT/build/tari/config.toml.template" "$U/build/tari/"
# Stale .env: secrets present, but STRATUM_BIND (a rendered var) is missing — the upgrade must fill it.
cat >"$U/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$U/config.json"
UL="$U/docker.log"
: >"$UL"
out="$(cd "$U" && DOCKER_LOG="$UL" PATH="$U/bin:$PATH" ./pithead upgrade 2>&1)"
rc=$?
assert_rc "upgrade exits 0" "$rc" "0"
assert_eq "upgrade re-renders a missing var (STRATUM_BIND)" "$(run_sourced "$U" env_get_file "$U/.env" STRATUM_BIND)" "0.0.0.0"
assert_eq "upgrade preserves the proxy token" "$(run_sourced "$U" env_get_file "$U/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
# render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and load_preserved_state
# doesn't carry it, so upgrade must re-assert it — else the flag flips to false and the NEXT
# require_deployed command (up/apply/upgrade) errors "run setup" on an already-deployed box.
assert_eq "upgrade preserves DEPLOYMENT_COMPLETED (require_deployed survives)" "$(run_sourced "$U" env_get_file "$U/.env" DEPLOYMENT_COMPLETED)" "true"
assert_contains "upgrade still rebuilds images (source mode)" "$(cat "$UL")" "compose up --pull never -d --build"
# Third-party images (caddy/tari/socket-proxies) are digest-pinned and can change between releases;
# a source-mode upgrade pulls the non-buildable ones first so a bumped digest is fetched (not "No
# such image" under --pull never). Best-effort, so it runs before the build.
assert_contains "upgrade pulls non-buildable images first (digest bumps)" "$(cat "$UL")" "compose pull --ignore-buildable"

echo "== black-box: apply recovers from a failed 'compose up' (#125) =="
# A docker stub that fails `compose up -d --remove-orphans` only when FAIL_UP=1 (else succeeds).
A="$SANDBOX/applyfail"
mkdir -p "$A/build/tari" "$A/dashboard" "$A/bin" "$A/data/monero" "$A/data/tari" "$A/data/p2pool/stats" "$A/data/tor" "$A/data/dashboard"
: >"$A/dashboard/Dockerfile" # source-checkout marker → pithead builds (--pull never), #44
cp "$STACK" "$A/pithead"
cp "$ROOT/build/tari/config.toml.template" "$A/build/tari/"
cat >"$A/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose version"|"info") exit 0 ;;
  "exec tor cat /var/lib/tor/monero/hostname") echo "mona.onion"; exit 0 ;;
  "exec tor cat /var/lib/tor/tari/hostname")   echo "taria.onion"; exit 0 ;;
  "exec tor cat /var/lib/tor/p2pool/hostname") echo "p2pa.onion"; exit 0 ;;
  "compose up --pull never -d --remove-orphans") [ "${FAIL_UP:-0}" = "1" ] && exit 1 || exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$A/bin/sudo"
chmod +x "$A/bin/docker" "$A/bin/sudo"
cat >"$A/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$A/config.json"
# First apply: real config delta committed, but `compose up` FAILS -> marker left, rc 1, guidance.
out="$(cd "$A" && FAIL_UP=1 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "apply fails (rc 1) when compose up fails" "$rc" "1"
assert_contains "apply prints recovery guidance" "$out" "were NOT recreated"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi
assert_eq "apply leaves the incomplete marker" "$mk" "present"
# Second apply: config already committed (no delta), but the marker forces a retry, not a silent no-op.
out="$(cd "$A" && FAIL_UP=0 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "re-apply retries and succeeds (rc 0)" "$rc" "0"
assert_contains "re-apply re-attempts the recreate" "$out" "retrying"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi
assert_eq "marker cleared after a successful retry" "$mk" "absent"

echo "== black-box: up warns about missing (relocated) data dirs (#126) =="
RL="$SANDBOX/reloc"
mkdir -p "$RL/bin"
cp "$STACK" "$RL/pithead"
make_stubs "$RL/bin"
# Deployed, but .env names data dirs that don't exist — as if the install was moved/copied or a
# second checkout is being run. The stack would silently re-sync; `up` must warn first.
cat >"$RL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
MONERO_DATA_DIR=/no/such/data/monero
TARI_DATA_DIR=/no/such/data/tari
P2POOL_DATA_DIR=/no/such/data/p2pool
DASHBOARD_DATA_DIR=/no/such/data/dashboard
TOR_DATA_DIR=/no/such/data/tor
EOF
out="$(cd "$RL" && PATH="$RL/bin:$PATH" ./pithead up 2>&1)"
rc=$?
assert_rc "up still starts (rc 0)" "$rc" "0"
assert_contains "up warns about a fresh re-sync" "$out" "start a FRESH sync"
assert_contains "up names the missing monero dir" "$out" "MONERO_DATA_DIR → /no/such/data/monero"
# A healthy deployment (dirs present) must NOT warn.
mkdir -p "$RL/d/monero" "$RL/d/tari" "$RL/d/p2pool" "$RL/d/dashboard" "$RL/d/tor"
cat >"$RL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
MONERO_DATA_DIR=$RL/d/monero
TARI_DATA_DIR=$RL/d/tari
P2POOL_DATA_DIR=$RL/d/p2pool
DASHBOARD_DATA_DIR=$RL/d/dashboard
TOR_DATA_DIR=$RL/d/tor
EOF
out="$(cd "$RL" && PATH="$RL/bin:$PATH" ./pithead up 2>&1)"
case "$out" in *"FRESH sync"*) bad "no false warning when data dirs exist" "got: $out" ;; *) ok "no false warning when data dirs exist" ;; esac
# Gating: before the first deploy (no DEPLOYMENT_COMPLETED) the dirs are legitimately absent -> silent.
printf 'MONERO_DATA_DIR=/no/such/monero\n' >"$RL/.env"
assert_eq "missing_data_dirs silent before first deploy" "$(run_sourced "$RL" missing_data_dirs)" ""

echo "== black-box: backup -> restore round-trip (#140) =="
# backup/restore touch irreplaceable state (onion keys, the dashboard DB) and have fiddly logic
# (leading-'/' strip, the disk pre-check, stop->backup->start). They shell out only to tar/du/df/
# docker/sudo, so a full round-trip is stubbable: the docker stub reports the stack NOT running, and
# a smart sudo runs tar/du/df for real (so the archive is genuinely created/extracted) but no-ops
# chown (we can't chown to 100:101 unprivileged). The archive stores paths relative to '/', and every
# path is under the sandbox, so `restore`'s `tar -C /` can only write back inside it (asserted below).
# Use the sandbox's PHYSICAL path (pwd -P): `restore` extracts at '/', and on macOS the /var ->
# /private/var symlink would otherwise make BSD tar refuse to "extract through symlink" (Linux /tmp
# isn't symlinked, so this is a no-op there).
BK="$(cd "$SANDBOX" && pwd -P)/backup"
mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
cp "$STACK" "$BK/pithead"
cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;;   # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run backup/restore's privileged commands as the test user, except chown (can't set 100:101
# unprivileged) which is accepted as a no-op so restore doesn't abort.
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/docker" "$BK/bin/sudo"
cat >"$BK/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=BKTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$BK/config.json"
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$BK/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$BK/data/dashboard/dashboard.db"

# 1) Backup creates a timestamped archive. --no-encrypt keeps this #140 round-trip on the plaintext
# path (encryption is exercised in the #374 block below); an unattended run without a passphrase
# now refuses rather than downgrading, so the flag is required here.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup exits 0" "$rc" "0"
archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$archive" ] && [ -f "$archive" ]; } && ok "backup archive created" || bad "backup archive created" "no archive under backups/"

# 2) Archive layout: the irreplaceable bits are in it; blockchains are NOT (no --with-chains).
listing="$(tar -tzf "$archive" 2>/dev/null)"
assert_contains "archive has config.json" "$listing" "config.json"
assert_contains "archive has .env" "$listing" ".env"
assert_contains "archive has Caddyfile" "$listing" "Caddyfile"
assert_contains "archive has the tor onion key" "$listing" "hs_ed25519_secret_key"
assert_contains "archive has the dashboard db" "$listing" "dashboard.db"
case "$listing" in
*data/monero* | *data/p2pool/* | *data/tari*) bad "archive excludes blockchains by default" "chain data present without --with-chains" ;;
*) ok "archive excludes blockchains by default" ;;
esac
# Safety tripwire: every archived path is under the sandbox, so restore's `tar -C /` can't escape it.
sandbox_rel="${BK#/}"
escaped="$(printf '%s\n' "$listing" | grep -v '^$' | grep -v "^$sandbox_rel" || true)"
assert_eq "archive paths stay inside the sandbox" "$escaped" ""

# 3) Round-trip: corrupt/delete the live files, restore, assert the originals come back in place.
printf 'CORRUPTED\n' >"$BK/Caddyfile"
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
rc=$?
assert_rc "restore exits 0" "$rc" "0"
assert_eq "restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4) Low-space pre-check (#127): a df reporting almost no free space makes backup prompt; answering
# "no" cancels and writes nothing, while --yes proceeds with a warning. The check runs BEFORE the
# stack is touched, so a cancel leaves everything as it was.
cat >"$BK/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/fake 100 99 1 99% /'
EOF
chmod +x "$BK/bin/df"
rm -f "$BK"/backups/pithead-backup-*.tar.gz
# stdin answers two prompts since #374: empty passphrase (-> plaintext fallback), then 'n'.
out="$(cd "$BK" && printf '\nn\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first" "$out" "Low free space"

echo "== black-box: encrypted backup -> restore (#374) =="
# The archive holds the stack's full secret material (onion keys, .env, dashboard DB), so backup
# encrypts by default (openssl aes-256-cbc + pbkdf2). Covered here: the unattended-without-
# passphrase REFUSAL (an automated run must never silently downgrade to plaintext), the explicit
# --no-encrypt opt-out, env-var and prompt encrypt round-trips, wrong-passphrase rejection BEFORE
# anything is touched, a tamper/truncation refusal before extraction, legacy/garbage archives, and
# that a failed encrypted backup leaves no file behind (the tar|openssl stream means no plaintext
# temp ever).
rm -f "$BK/bin/df" "$BK"/backups/pithead-backup-*

# 1a) --yes with no passphrase REFUSES (no silent plaintext downgrade for cron); writes nothing.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "unattended backup without passphrase exits non-zero" || bad "unattended backup without passphrase exits non-zero" "rc=0"
assert_contains "refusal names the missing passphrase" "$out" "PITHEAD_BACKUP_PASSPHRASE"
assert_eq "refused unattended backup writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
# 1b) --no-encrypt is the explicit plaintext opt-out (loud warning, exits 0, writes a plain archive).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "explicit --no-encrypt backup exits 0" "$rc" "0"
plain_optout="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_optout" ] && [ -f "$plain_optout" ]; } && ok "--no-encrypt writes a plaintext archive" || bad "--no-encrypt writes a plaintext archive" "no plain archive"
rm -f "$BK"/backups/pithead-backup-*

# 2) Env-var passphrase: a .enc archive with the openssl Salted__ header, no plaintext twin.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$enc_archive" ] && [ -f "$enc_archive" ]; } && ok "encrypted archive created (.enc)" || bad "encrypted archive created (.enc)" "no .enc under backups/"
assert_eq "archive starts with Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
plain_left="$(ls "$BK"/backups/*.tar.gz 2>/dev/null | head -1)"
assert_eq "no plaintext archive alongside the .enc" "$plain_left" ""
assert_contains "backup says to store the passphrase elsewhere" "$out" "passphrase"

# 3) Wrong passphrase: restore fails loudly before tar runs — live files untouched.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=wrong ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "wrong passphrase exits non-zero" || bad "wrong passphrase exits non-zero" "rc=0"
assert_contains "wrong passphrase names the cause" "$out" "rong passphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"

# 4) Right passphrase, via the prompt this time: full round-trip (archive was taken while the
# files held their -ORIG values, so restore must bring those back over the corrupted ones).
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && printf 'hunter2\n' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
assert_rc "encrypted restore exits 0" "$rc" "0"
assert_eq "encrypted restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "encrypted restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "encrypted restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4b) Tampered/truncated ciphertext (CBC has no MAC): a flip past the first block passes the
# cheap magic pre-flight but must be caught by the full-stream verify BEFORE tar writes anything,
# so the live files survive. Truncating the archive tail simulates corruption/tampering.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
head -c $(($(wc -c <"$enc_archive") - 32)) "$enc_archive" >"$BK/backups/truncated.tar.gz.enc"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead restore -y "$BK/backups/truncated.tar.gz.enc" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "tampered archive exits non-zero" || bad "tampered archive exits non-zero" "rc=0"
assert_contains "tampered archive names integrity failure" "$out" "integrity"
assert_eq "tampered archive leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated.tar.gz.enc"
# Leave the fixtures as this block found them (the round-trip above restored -ORIG) so the
# later plaintext-backup test captures -ORIG, not this test's probe value.
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"

# 5) Interactive prompt path: passphrase typed twice encrypts; a mismatch aborts with no archive.
out="$(cd "$BK" && printf 'pw\npw\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
assert_rc "prompted encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
assert_eq "prompted backup writes Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
rm -f "$BK"/backups/pithead-backup-*
out="$(cd "$BK" && printf 'pw\nother\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "passphrase mismatch exits non-zero" || bad "passphrase mismatch exits non-zero" "rc=0"
assert_contains "passphrase mismatch says so" "$out" "do not match"
assert_eq "passphrase mismatch writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""

# 6) --no-encrypt forces plaintext even with the env var set, and that legacy-format archive
# still restores through the gzip path (magic-byte detection, no flag).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "--no-encrypt backup exits 0" "$rc" "0"
plain_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_archive" ] && gzip -t "$plain_archive" 2>/dev/null; } && ok "--no-encrypt writes plain gzip" || bad "--no-encrypt writes plain gzip" "missing or not gzip"
printf 'CORRUPTED\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$plain_archive" 2>&1)"
rc=$?
assert_rc "plaintext archive still restores" "$rc" "0"
assert_eq "plaintext restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
rm -f "$BK"/backups/pithead-backup-*

# 6b) Truncated plaintext archive (#549): mirrors the encrypted-branch tamper/truncation check
# (4b above) on the gzip path — a truncated archive must be rejected by a full-stream `tar -tzf`
# verify BEFORE extraction, with nothing written, instead of half-overwriting config.json/.env.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
plain_trunc_src="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
config_before="$(cat "$BK/config.json")"
env_before="$(cat "$BK/.env")"
head -c "$(($(wc -c <"$plain_trunc_src") / 2))" "$plain_trunc_src" >"$BK/backups/truncated-plain.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/truncated-plain.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "truncated plaintext archive exits non-zero" || bad "truncated plaintext archive exits non-zero" "rc=0"
assert_contains "truncated plaintext archive names integrity failure" "$out" "integrity"
assert_eq "truncated plaintext archive leaves config.json untouched" "$(cat "$BK/config.json")" "$config_before"
assert_eq "truncated plaintext archive leaves .env untouched" "$(cat "$BK/.env")" "$env_before"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated-plain.tar.gz"

# 7) A failed encrypted backup (openssl dies mid-stream) removes the partial archive.
cat >"$BK/bin/openssl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BK/bin/openssl"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=x ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed encrypted backup exits non-zero" || bad "failed encrypted backup exits non-zero" "rc=0"
assert_eq "failed encrypted backup leaves nothing behind" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
rm -f "$BK/bin/openssl"

# 8) An archive that is neither encrypted nor gzip is refused before the overwrite prompt.
printf 'garbage-not-an-archive' >"$BK/backups/bogus.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/bogus.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "garbage archive is refused" || bad "garbage archive is refused" "rc=0"
assert_contains "garbage archive names the problem" "$out" "Not a pithead backup archive"
rm -f "$BK"/backups/bogus.tar.gz

# 9) Restore of an encrypted archive with no passphrase available (piped empty stdin) fails clean.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
out="$(cd "$BK" && printf '' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "encrypted restore w/o passphrase exits non-zero" || bad "encrypted restore w/o passphrase exits non-zero" "rc=0"
assert_contains "encrypted restore w/o passphrase explains" "$out" "PITHEAD_BACKUP_PASSPHRASE"
rm -f "$BK"/backups/pithead-backup-*

echo "== black-box: failed plaintext backup restarts a running stack, removes the partial archive (#551) =="
# Companion to the #549 test above: a failed tar must not strand the stack stopped, nor leave a
# partial (root-owned) archive that looks like a valid backup. Shadow tar to fail unconditionally
# and simulate a RUNNING stack (was_running=1), so the failure path must call stack_up for real —
# proven here by "compose up" showing up in the docker log, not by stubbing stack_up away.
FB="$SANDBOX/failbackup"
mkdir -p "$FB/build/tari" "$FB/data/tor" "$FB/data/dashboard" "$FB/bin"
cp "$STACK" "$FB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$FB/build/tari/"
cat >"$FB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose ps --status running -q") echo cid123 ;; # non-empty -> stack treated as RUNNING
esac
exit 0
EOF
cat >"$FB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
cat >"$FB/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FB/bin/docker" "$FB/bin/sudo" "$FB/bin/tar"
cat >"$FB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=FBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FB/config.json"

out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed plaintext backup (running stack) exits non-zero" || bad "failed plaintext backup (running stack) exits non-zero" "rc=0"
assert_contains "failed plaintext backup names the cause" "$out" "partial archive was removed"
assert_eq "failed plaintext backup leaves no archive behind" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
assert_contains "failed plaintext backup restarts the stack" "$(cat "$FB/docker.log" 2>/dev/null)" "compose up"

echo "== black-box: reset-dashboard targets .env dirs, not config.json (#139) =="
# reset-dashboard must wipe the LIVE deployment's data dirs (from .env), not a path the user may
# have edited into config.json without applying. docker = noop; sudo only LOGS (never executes the
# rm), so we can assert what it would have targeted without deleting anything.
R="$SANDBOX/reset"
mkdir -p "$R/bin" "$R/envdir/dashboard" "$R/envdir/p2pool"
cp "$STACK" "$R/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/bin/docker"
cat >"$R/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >> "${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$R/bin/docker" "$R/bin/sudo"
cat >"$R/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$R/envdir/dashboard
P2POOL_DATA_DIR=$R/envdir/p2pool
EOF
# config.json points the data dirs somewhere ELSE (a path the running stack never used).
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"data_dir":"%s/CONFIGONLY/p2pool"}, "dashboard":{"data_dir":"%s/CONFIGONLY/dashboard"} }\n' "$WALLET" "$R" "$R" >"$R/config.json"
SUDO_LOG="$R/sudo.log"
: >"$SUDO_LOG"
out="$(cd "$R" && SUDO_LOG="$SUDO_LOG" PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard succeeds" "$rc" "0"
sudo_calls="$(cat "$SUDO_LOG")"
assert_contains "reset rm targets the .env dashboard dir" "$sudo_calls" "rm -rf $R/envdir/dashboard"
case "$sudo_calls" in *CONFIGONLY*) bad "reset must ignore the config-only data_dir" "$sudo_calls" ;; *) ok "reset ignores the config-only data_dir" ;; esac

echo "== black-box: reset-dashboard refuses to guess without .env dirs (#139) =="
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$R/.env"
out="$(cd "$R" && SUDO_LOG=/dev/null PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset refuses with no data dirs in .env" "$rc" "1"
assert_contains "reset refuse message" "$out" "refusing to guess"

echo "== black-box: reset-dashboard's final compose_up_checked is if!-guarded, not bare (#557/#180) =="
# Before #557: the last compose_up_checked call in reset_dashboard was bare (every OTHER call site
# wraps it in `if !`, per the contract at compose_up_checked's own definition). A bare call let a real
# compose failure trip errexit INSIDE compose_up_checked's own `docker compose up | tee` pipeline,
# before the #180 subnet-collision explanation printed. Real `./pithead` (not sourced) arms
# `trap on_err ERR` exactly like production, so this reproduces the actual operator experience.
RD557="$SANDBOX/reset557"
mkdir -p "$RD557/bin" "$RD557/envdir/dashboard" "$RD557/envdir/p2pool"
cp "$STACK" "$RD557/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RD557/bin/sudo"
cat >"$RD557/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose up"*)
    echo "Error response from daemon: Pool overlaps with other one on this address space" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$RD557/bin/docker" "$RD557/bin/sudo"
cat >"$RD557/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
NETWORK_SUBNET=172.28.0.0/24
DASHBOARD_DATA_DIR=$RD557/envdir/dashboard
P2POOL_DATA_DIR=$RD557/envdir/p2pool
EOF
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$RD557/config.json"
out="$(cd "$RD557" && PATH="$RD557/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard: compose failure still exits 1 (fail-closed unchanged)" "$rc" "1"
assert_contains "reset-dashboard: #180 subnet-collision explanation reaches the operator (#557)" \
    "$out" "Docker refused the stack's bridge subnet"
assert_contains "reset-dashboard: crafted failure message names the retry command" "$out" "did NOT come back up"

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
# shellcheck source=tests/stack/test-tor-network.sh
source "$HERE/test-tor-network.sh"

# ---------------------------------------------------------------------------
echo "== black-box: dashboard control channel (#33) =="
# A deployed sandbox with the control channel on: config carries a dashboard password (required)
# and dashboard.control.enabled, docker/sudo stubbed. The runner is exercised end-to-end against
# real spool files; `apply` inside it runs this same sandboxed pithead.
build_control_sandbox

# Fail-closed: enabling the control channel without a dashboard password must not validate.
seed_control_env
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan","control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "control.enabled without a password is rejected" "$rc" "1"
assert_contains "control-without-password message names the flag" "$out" "dashboard.control.enabled"

# Baseline: control enabled + password, pool main → a rendered .env with the control keys.
seed_control_env
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "baseline apply with control enabled succeeds" "$?" "0"
assert_contains "control toggle rendered to .env" "$(cat "$C/.env")" "DASHBOARD_CONTROL_ENABLED=true"
assert_contains "control spool dir rendered to .env" "$(cat "$C/.env")" "CONTROL_DIR=$C/data/control"
[ -d "$C/data/control/requests" ] && [ -d "$C/data/control/staged" ] &&
    [ -d "$C/data/control/results" ] && [ -d "$C/data/control/audit" ] &&
    ok "control spool dirs created" || bad "control spool dirs created" "missing under $C/data/control"
assert_contains "caddy access-log dir rendered to .env (#349)" "$(cat "$C/.env")" "CADDY_LOG_DIR=$C/data/caddy-logs"
[ -d "$C/data/caddy-logs" ] && ok "caddy access-log dir created (#349)" || bad "caddy access-log dir created (#349)" "missing"

echo "== black-box: apply --dry-run [--porcelain] (#33) =="
control_config mini # candidate change: pool main -> mini
cp "$C/.env" "$C/env.before"
: >"$CTRL_LOG"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run --porcelain exits 0" "$?" "0"
assert_contains "porcelain emits FLAG<TAB>KEY<TAB>MSG rows" "$out" "$(printf 'INFO\tP2POOL_FLAGS\t')"
assert_contains "porcelain row carries the describe_change message" "$out" "P2Pool sidechain changing"
if cmp -s "$C/.env" "$C/env.before"; then ok "dry-run leaves .env untouched"; else bad "dry-run leaves .env untouched" ".env changed"; fi
case "$(grep 'compose up' "$CTRL_LOG" 2>/dev/null || true)" in
"") ok "dry-run touches no container" ;;
*) bad "dry-run touches no container" "docker compose up was called" ;;
esac
[ ! -f "$C/.env.dryrun" ] && ok "dry-run staging file removed" || bad "dry-run staging file removed" ".env.dryrun left behind"
# Human (non-porcelain) preview prints the bullet form of the same row.
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>/dev/null)"
assert_contains "human dry-run prints the preview bullet" "$out" "• P2Pool sidechain changing"
# --porcelain without --dry-run is refused (it would silently look like a real apply).
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --porcelain 2>&1)"
assert_rc "--porcelain without --dry-run is rejected" "$?" "1"

# PITHEAD_CONFIG_FILE points ONE invocation at a candidate config; config.json is not consulted.
control_config main # config.json back to the applied state (no changes)
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"nano"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/alt.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" PITHEAD_CONFIG_FILE="$C/alt.json" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_contains "PITHEAD_CONFIG_FILE override is honoured" "$out" "37890" # nano's p2p port
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_eq "without the override, config.json shows no changes" "$out" ""

echo "== black-box: symlink-invoked stack renders physical paths (#695) =="
# A stack managed through a deploy symlink (`current -> pithead-vX.Y.Z`) must render the same
# .env as one managed from the physical dir: SCRIPT_DIR resolves with pwd -P, so an unedited
# preview through the symlink shows zero changes and an apply never rewrites the $PWD-derived
# paths (CLEARNET_STATE_DIR & co.) to the symlink spelling.
ln -sfn "$C" "$SANDBOX/current-link"
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run through the symlink exits 0" "$?" "0"
assert_eq "unedited preview through the symlink shows zero changes (#695)" "$out" ""
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply through the symlink succeeds" "$?" "0"
assert_contains "clearnet state dir keeps the physical path" "$(cat "$C/.env")" "CLEARNET_STATE_DIR=$C/data/clearnet-state"
assert_not_contains "the symlink spelling never reaches .env" "$(cat "$C/.env")" "current-link"
rm -f "$SANDBOX/current-link"

echo "== black-box: apply --dry-run is read-only re: node credential generation (#556) =="
# Direct CLI leg: a fresh/hand-edited local-node config with placeholder/empty creds must not have
# config.json rewritten by a --dry-run preview — the read-only contract #556 reported broken
# (persist_node_credentials was writing the freshly-generated creds back to disk).
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"","node_password":""},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
cp "$C/config.json" "$C/config.json.556before"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>&1)"
assert_rc "dry-run with placeholder node creds still validates" "$?" "0"
if cmp -s "$C/config.json" "$C/config.json.556before"; then
    ok "dry-run leaves config.json byte-identical with placeholder node creds (#556)"
else
    bad "dry-run leaves config.json byte-identical with placeholder node creds (#556)" "config.json was rewritten"
fi
assert_contains "dry-run still previews the credential it would generate (in-memory only)" "$out" "Monero node RPC credential"
rm -f "$C/config.json.556before"

# Control-channel leg: the same blank-creds config staged through the control path must not have
# its ON-DISK STAGED COPY rewritten by the dry-run re-validation either (#556) — the same write,
# one level removed, that used to leave a generated secret sitting in data/control/staged/ and
# could dirty the diff a later commit gate re-derives from that file.
UUID0="00000000-0000-4000-8000-000000000000"
REQS0="$C/data/control/requests"
STAGED0="$C/data/control/staged"
RESULTS0="$C/data/control/results"
jq -n --arg w "$WALLET" --arg id "$UUID0" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"",node_password:""},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS0/$UUID0.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "blank-creds preview status" "$(jq -r '.status' "$RESULTS0/$UUID0.json" 2>/dev/null)" "previewed"
assert_eq "staged copy keeps the blank node_username — not persisted (#556)" "$(jq -r '.monero.node_username' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
assert_eq "staged copy keeps the blank node_password — not persisted (#556)" "$(jq -r '.monero.node_password' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
# Clean up: the result/staged counters the tests below assume start from a clean spool.
rm -f "$RESULTS0/$UUID0.json" "$STAGED0/$UUID0.json"
control_config main # restore config.json to the state control-run-pending below expects

echo "== black-box: control-run-pending (#33) =="
UUID1="11111111-1111-4111-8111-111111111111"
UUID2="22222222-2222-4222-8222-222222222222"
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"
STAGED="$C/data/control/staged"
AUDIT="$C/data/control/audit/control.log"

# Preview: a valid typed intent (pool main -> mini) → previewed result + a host-side staged copy.
jq -n --arg w "$WALLET" --arg id "$UUID1" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID1.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a valid preview" "$?" "0"
[ ! -f "$REQS/$UUID1.json" ] && ok "request claimed out of requests/" || bad "request claimed out of requests/" "still present"
assert_eq "preview result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "previewed"
assert_contains "preview result carries the change row" "$(jq -r '.changes[].msg' "$RESULTS/$UUID1.json" 2>/dev/null)" "P2Pool sidechain changing"
assert_eq "pool switch alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID1.json" 2>/dev/null)" "false"
[ -f "$STAGED/$UUID1.json" ] && ok "candidate staged host-side" || bad "candidate staged host-side" "missing"
# The staged copy carries merged secrets — it must land owner-only (#33 re-review).
assert_eq "staged candidate is mode 600" "$(file_mode "$STAGED/$UUID1.json")" "600"
assert_contains "preview audited" "$(cat "$AUDIT" 2>/dev/null)" "\"action\":\"preview\",\"status\":\"previewed\""

# Malformed id: it would become a filename, so the request is discarded with no result at all.
printf '{"id":"../../etc/passwd","action":"preview","actor":"x","config":{}}\n' >"$REQS/evil.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a malformed id" "$?" "0"
assert_contains "malformed id is called out" "$out" "malformed id"
assert_eq "no result file for a malformed id" "$(ls "$RESULTS" | wc -l | tr -d ' ')" "1"

# Well-formed but non-v4 id (version nibble 1): the loose old regex accepted any hex uuid shape;
# the tightened gate (#438) pins version 4 + RFC variant, so this must be discarded too.
printf '{"id":"11111111-1111-1111-1111-111111111111","action":"preview","actor":"x","config":{}}\n' >"$REQS/nonv4.json"
out="$(run_pending)"
assert_contains "non-v4 uuid id is discarded" "$out" "malformed id"
[ ! -f "$RESULTS/11111111-1111-1111-1111-111111111111.json" ] &&
    ok "no result file for a non-v4 id" || bad "no result file for a non-v4 id" "result written"

# Unknown action / extra keys / invalid candidate config → rejected results, nothing staged.
printf '{"id":"%s","action":"exec","actor":"x"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "unknown action is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
# A malicious action string on the unknown-action path cannot forge a second line into the
# tamper-evidence audit log: the field is charset-stripped at the write chokepoint. Feed an action
# carrying a newline + a fake JSON entry, then assert every audit line is still valid JSON and no
# forged status leaked in (#349 review).
audit_before=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
# jq decodes the \n and quotes into REAL characters in the action value, so the host-side
# jq -r '.action' hands control_audit a string with an embedded newline + fake JSON object —
# the exact shape that would append a forged line without the charset strip.
jq -nc --arg id "$UUID2" '{id:$id,actor:"x",action:"evil\n{\"ts\":\"0\",\"forged\":\"yes\"}"}' >"$REQS/$UUID2.json"
run_pending >/dev/null
audit_after=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
assert_eq "forged-action intent adds exactly one audit line" "$((audit_after - audit_before))" "1"
while IFS= read -r line; do printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad "every audit line is valid JSON" "unparseable: $line"; done <"$AUDIT"
ok "every audit line is valid JSON after a forged-action intent"
assert_not_contains "no forged audit entry leaked in" "$(cat "$AUDIT")" '"forged":"yes"'
printf '{"id":"%s","action":"preview","actor":"x","config":{},"cmd":"rm -rf /"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "extra request keys are rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "unexpected keys"
jq -n --arg w "$WALLET" --arg id "$UUID2" '{id:$id, action:"preview", actor:"x", config:{
    monero:{mode:"local",wallet_address:$w}, tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"banana"},
    dashboard:{auth:{password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "invalid candidate config is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
assert_contains "rejection carries pithead's validation error" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "p2pool.pool"
[ ! -f "$STAGED/$UUID2.json" ] && ok "rejected candidate is not left staged" || bad "rejected candidate is not left staged" "staged file present"

# Commit without a staged intent → rejected (preview first).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "commit without a staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "preview first"

# Commit of the previewed intent: backup written, apply -y ran, audit line, result applied.
: >"$CTRL_LOG"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID1" >"$REQS/$UUID1.json"
run_pending >/dev/null
assert_eq "commit result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "applied"
assert_eq "committed config landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"
[ -f "$C/config.json.bak-control" ] &&
    assert_eq "pre-change backup kept" "$(jq -r '.p2pool.pool' "$C/config.json.bak-control")" "main" ||
    bad "pre-change backup kept" "config.json.bak-control missing"
assert_contains "commit ran the real apply (containers recreated)" "$(cat "$CTRL_LOG")" "compose up"
assert_contains "commit audited with the actor" "$(cat "$AUDIT")" "\"actor\":\"admin\",\"action\":\"commit\",\"status\":\"applied\""
[ ! -f "$STAGED/$UUID1.json" ] && ok "staged intent consumed on commit" || bad "staged intent consumed on commit" "still staged"

# Operator keeps ownership of the stack files the root runner's apply wrote (#33 v1.4): control_run_pending
# is root, so its apply would render .env root:root 0600 — unreadable to the non-root operator. The
# re-own derives the owner from config.json (operator-owned, container can't write it) so a commit
# matches a normal apply. Assert every operator-facing file is owned by config.json's owner, so a
# non-root operator can still read .env / re-render on the next apply.
cfg_uid="$(file_uid "$C/config.json")"
for reowned in ".env" "Caddyfile" "config.json.bak-control"; do
    [ -e "$C/$reowned" ] &&
        assert_eq "$reowned owned by the config.json owner after a control commit" "$(file_uid "$C/$reowned")" "$cfg_uid" ||
        bad "$reowned present after a control commit" "missing"
done

echo "== black-box: audit log records names, never values (#349) =="
# WHAT changed rides in the audit entry as env-key NAMES (main -> mini touches the p2pool keys);
# no config or secret VALUE may ever land in the log — it is mounted into the dashboard container.
assert_contains "commit audit records the changed key names" "$(cat "$AUDIT")" '"keys":"P2POOL'
assert_contains "preview audit records the changed key names" "$(grep '"status":"previewed"' "$AUDIT" | tail -n 1)" '"keys":"P2POOL'
case "$(cat "$AUDIT")" in
*"a control passphrase"* | *"$WALLET"* | *mini*) bad "audit log holds no config or secret values" "a value leaked into audit/control.log" ;;
*) ok "audit log holds no config or secret values" ;;
esac

# Expired staged intent (older than the 10-min commit window) → rejected as expired and cleared.
# Age it ~15 min: past the 10-min expiry the commit enforces, but INSIDE the 60-min stale sweep so
# the sweep leaves it for control_commit to judge (a 2020 date would be swept first, #33 hardening).
jq -n --arg id "$UUID2" '{}' >"$STAGED/$UUID2.json"
touch -t "$(date -d '15 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-15M +%Y%m%d%H%M)" "$STAGED/$UUID2.json"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "expired staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "expired"
[ ! -f "$STAGED/$UUID2.json" ] && ok "expired staged intent cleared" || bad "expired staged intent cleared" "still staged"

echo "== black-box: pre-masked prefill copy + host-side secret merge (#440) =="
# The dashboard container never mounts the raw config.json: apply/run-pending render a PRE-MASKED
# copy into the spool's masked/ leg, and the "blank secret keeps the live value" sentinel swap
# happens host-side at staging. Current state: pool mini committed above, node_password "p",
# dashboard password "a control passphrase".
MASKED="$C/data/control/masked/config.json"
[ -f "$MASKED" ] && ok "masked prefill copy rendered by apply" || bad "masked prefill copy rendered by apply" "$MASKED missing"
assert_eq "masked copy is world-readable for the container (644)" "$(file_mode "$MASKED")" "644"
assert_eq "set secret masked to the sentinel" "$(jq -c '.monero.node_password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "dashboard password masked to the sentinel" "$(jq -c '.dashboard.auth.password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "non-secret keys survive the masking" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "mini"
case "$(cat "$MASKED")" in
*"a control passphrase"* | *'"p"'*) bad "masked copy holds no secret values" "a secret leaked into $MASKED" ;;
*) ok "masked copy holds no secret values" ;;
esac

# Staleness: a hand-edit to config.json (new BOTSECRET token) is re-masked by the next runner
# pass — run-pending freshens the copy even with an empty request spool.
jq '.telegram = {"bot_token":"BOTSECRET","chat_id":"-100123"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_pending >/dev/null
assert_eq "run-pending re-renders the masked copy" "$(jq -c '.telegram.bot_token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
case "$(cat "$MASKED")" in
*BOTSECRET*) bad "hand-edited secret never reaches the masked copy" "BOTSECRET leaked into $MASKED" ;;
*) ok "hand-edited secret never reaches the masked copy" ;;
esac

# Sync .env with the hand-edited config so the sentinel commit below only changes allowlisted
# P2POOL keys (TELEGRAM_BOT_TOKEN is deliberately NOT dashboard-committable).
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

# Host-side sentinel swap: a proposal carrying {"__secret__":true} for untouched secrets (what the
# dashboard now submits) stages with the LIVE values merged back in, and a sentinel for an UNSET
# secret collapses to "" instead of leaking a dict into config.json.
UUID5="55555555-5555-4555-8555-555555555555"
jq -n --arg w "$WALLET" --arg id "$UUID5" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:{"__secret__":true}},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, workers:{api_token:{"__secret__":true}},
    telegram:{bot_token:{"__secret__":true},chat_id:"-100123"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:{"__secret__":true}},control:{enabled:true}}}}' >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel-carrying preview validates" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_eq "sentinel swapped for the live node password at staging" "$(jq -r '.monero.node_password' "$STAGED/$UUID5.json" 2>/dev/null)" "p"
assert_eq "sentinel swapped for the live dashboard password" "$(jq -r '.dashboard.auth.password' "$STAGED/$UUID5.json" 2>/dev/null)" "a control passphrase"
assert_eq "sentinel swapped for the live telegram token" "$(jq -r '.telegram.bot_token' "$STAGED/$UUID5.json" 2>/dev/null)" "BOTSECRET"
assert_eq "sentinel for an unset secret collapses to empty" "$(jq -r '.workers.api_token' "$STAGED/$UUID5.json" 2>/dev/null)" ""
# The container-visible legs of this round trip stay secret-free (the request carried sentinels,
# the merged copy lives only in host-only staged/).
case "$(cat "$RESULTS/$UUID5.json")$(cat "$AUDIT")" in
*BOTSECRET* | *"a control passphrase"*) bad "results/audit stay secret-free on a sentinel preview" "a live secret leaked" ;;
*) ok "results/audit stay secret-free on a sentinel preview" ;;
esac

# Commit the sentinel intent: the committed config.json carries the LIVE secrets ("blank keeps"),
# and the masked prefill copy is re-rendered to match the new state.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live node password" "$(jq -r '.monero.node_password' "$C/config.json")" "p"
assert_eq "committed config keeps the live telegram token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "BOTSECRET"
assert_eq "committed config never carries a sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
assert_eq "masked copy re-rendered after the commit" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "main"
case "$(cat "$MASKED")" in
*BOTSECRET* | *"a control passphrase"*) bad "re-rendered masked copy still holds no secrets" "a secret leaked into $MASKED" ;;
*) ok "re-rendered masked copy still holds no secrets" ;;
esac

echo "== black-box: .env line-injection guard (#33 hardening, per field) =="
# A newline in any config string that renders into .env unquoted would inject a SECOND KEY=value
# line — e.g. PITHEAD_REGISTRY=evil.tld — which the root apply then trusts for every image: pull
# (RCE). parse_and_validate_config (the chokepoint both preview dry-run and real commit run) must
# reject a control character in EVERY string leaf. Build a full valid config, then poison one field.
inject_reject() { # <label> <jq-setter expr using $v>
    jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}
         | '"$2" >"$C/config.json"
    out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
    rc=$?
    assert_rc "$1 with a newline is rejected by parse_and_validate_config" "$rc" "1"
    assert_contains "$1 rejection names the control-char guard" "$out" "control character"
}
inject_reject "node_password" '.monero.node_password=$v'
inject_reject "node_username" '.monero.node_username=$v'
inject_reject "bot_token" '(.telegram={bot_token:$v})'
inject_reject "api_token" '(.workers={api_token:$v})'
inject_reject "ping_url" '(.healthchecks={ping_url:$v})'
inject_reject "chat_id" '(.telegram={chat_id:$v})'
# Positive: legitimate tokens (no control chars) still validate.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
      telegram:{bot_token:"123456:legit-ABC_def"}, workers:{api_token:"tok_legit123"},
      healthchecks:{ping_url:"https://hc-ping.com/abc-123"},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "legitimate secrets still validate" "$?" "0"
# No second line reaches .env: a poisoned config rejected at `apply -y` never renders the attacker key.
jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, telegram:{bot_token:$v},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
if grep -q 'PITHEAD_REGISTRY' "$C/.env"; then bad "no injected line in .env" "PITHEAD_REGISTRY landed in .env"; else ok "rejected config injects no second .env line"; fi

echo "== black-box: control channel on a published onion requires client-auth (#33 hardening) =="
# A root-capable, funds-redirecting mutation channel must not sit behind only a brute-forceable
# password on an anonymously-reachable onion. control+onion+client_auth=false → refused.
onion_control_config() { # <onion-enabled> <client-auth> -> writes config.json
    jq -n --arg w "$WALLET" --argjson onion "$1" --argjson ca "$2" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a strong control passphrase"},
                     onion:{enabled:$onion,client_auth:$ca}, control:{enabled:true}}}' >"$C/config.json"
}
onion_control_config true false
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion without client_auth is refused" "$?" "1"
assert_contains "refusal names client_auth" "$out" "client_auth"
onion_control_config true true
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion WITH client_auth validates" "$?" "0"
assert_not_contains "allowed combo raises no client_auth error" "$out" "client_auth"
# control without an onion (LAN) stays allowed — client-auth only gates the published onion.
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control without an onion is allowed" "$?" "0"

echo "== black-box: telegram.control fails closed on each leg (#521) =="
# telegram.control (the #338 remote /restart /apply surface) is a remotely-reachable host-control
# channel, so it refuses to enable unless the whole chain is present: dashboard.control on (the #33
# spool it rides), telegram.commands on (the bot that answers it), and at least one allow-listed
# operator id (or every command is refused and the feature is inert). Each leg must fail closed.
tg_control_config() { # <dashboard.control.enabled> <telegram.commands.enabled> <allowed_ids-json>
    jq -n --arg w "$WALLET" --argjson ctl "$1" --argjson cmds "$2" --argjson ids "$3" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111",
                    commands:{enabled:$cmds}, control:{enabled:true,allowed_ids:$ids}},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
                     control:{enabled:$ctl}}}' >"$C/config.json"
}
# Leg 1: dashboard.control off — the spool the commands ride does not exist.
tg_control_config false true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without dashboard.control is refused" "$?" "1"
assert_contains "refusal names dashboard.control.enabled" "$out" "dashboard.control.enabled is false"
# Leg 2: telegram.commands off — no bot is polling for the commands.
tg_control_config true false '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without telegram.commands is refused" "$?" "1"
assert_contains "refusal names telegram.commands.enabled" "$out" "telegram.commands.enabled is false"
# Leg 3: allowed_ids empty — no operator could ever confirm, the feature is inert.
tg_control_config true true '[]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control with an empty allowed_ids is refused" "$?" "1"
assert_contains "refusal names allowed_ids" "$out" "telegram.control.allowed_ids is empty"
# All three legs present — validates.
tg_control_config true true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "fully-configured telegram.control validates" "$?" "0"
assert_not_contains "fully-configured control raises no telegram.control error" "$out" "telegram.control.enabled is true but"
# Restore the section baseline (control on, no telegram) for the tests that follow.
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

echo "== black-box: confirm-gate — an in-scope disruptive change needs a typed APPLY (#719) =="
UUID3="33333333-3333-4333-8333-333333333333"
# Clean baseline: pool mini, clearnet off, applied.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# Candidate turns on Monero clearnet initial sync — describe_change flags this CONFIRM (#719): an
# in-scope disruptive change (host IP exposed during IBD), confirm-gated rather than host-only DEST.
preview_clearnet() {
    jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",clearnet_initial_sync:true},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
    run_pending >/dev/null
}
preview_clearnet
assert_eq "confirm-gated candidate previews destructive:true" "$(jq -r '.destructive' "$RESULTS/$UUID3.json" 2>/dev/null)" "true"
assert_contains "confirm-gated preview carries a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID3.json" 2>/dev/null)" "CONFIRM"
# Commit WITHOUT the typed confirmation is refused — and points at the confirm step, NOT a flat
# host-only #338 refusal. The in-scope change is NOT hard-refused; it just needs the acknowledgement.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit without a token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "refusal asks for the typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "type APPLY"
assert_eq "unconfirmed commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# A WRONG token is refused too — only the exact literal proceeds.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"apply"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with the wrong token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_eq "wrong-token commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# Commit WITH the exact typed APPLY proceeds and lands the change.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "confirmed change landed in config.json" "$(jq -r '.monero.clearnet_initial_sync' "$C/config.json")" "true"
# The audit log records it AS a dashboard-confirmed destructive change (#719): the distinct
# commit-confirmed action, carrying the changed key NAME (never a value).
assert_contains "confirmed commit audits as commit-confirmed with the key name" \
    "$(grep '"action":"commit-confirmed","status":"applied"' "$AUDIT" | tail -n 1)" "MONERO_CLEARNET_SYNC"

echo "== black-box: the typed APPLY does NOT unlock the perimeter — DEST stays host-only (#719) =="
# Type-to-confirm is UX friction, not a security control: it must never carry a PERIMETER change.
# (a) A perimeter key that never touches an allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND,
# DEST) is refused even WITH the token, on the security-sensitive gate.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "perimeter RPC-LAN change is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "perimeter refusal is the security-sensitive gate, not the confirm step" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "security-sensitive"
assert_eq "perimeter change did not touch config.json" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
# (b) A confirm-KEY in its HEAVY direction (monero.prune DISABLE → full re-sync) still emits DEST
# and is refused even WITH the token — the confirm allowlist is not a blanket unlock for the key.
jq -n --arg w "$WALLET" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "prune DISABLE is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
# #713 removed the stale #338 reference from the destructive refusal; it now names the host path.
assert_contains "prune-disable refusal names the host apply path, not stale #338 (#713)" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "Edit config.json on the host"
assert_eq "prune stays enabled after the refusal" "$(jq -r '.monero.prune' "$C/config.json")" "true"
[ ! -f "$STAGED/$UUID3.json" ] && ok "refused destructive intent cleared from staged" || bad "refused destructive intent cleared from staged" "still staged"

echo "== black-box: a dashboard-confirmed data-dir move is allowlisted to the stack data root (#728) =="
# #719 made the four *_DATA_DIR moves confirm-gated. assert_safe_dir is a BLOCKLIST, so a
# confirmed move could target any non-blocklisted absolute path (another user's home, another
# service's volume). control_approval_gate now narrows the DESTINATION to an allowlist for
# control-channel moves: only under the stack data root ($C/data) or a parent it already uses.
# The host `apply` path keeps the blocklist — a shell operator is already trusted.
UUID7="77777777-7777-4777-8777-777777777777"
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
EVIL_DIR="$SANDBOX/other-service-vol/monero" # absolute, NOT blocklisted, NOT under $C/data
preview_move() {                             # <monero.data_dir>
    jq -n --arg w "$WALLET" --arg id "$UUID7" --arg dd "$1" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID7.json"
    run_pending >/dev/null
}
# (1) A move UNDER the stack data root, confirmed with APPLY, is allowed and lands.
preview_move "$C/data/monero-v2"
assert_contains "in-root data-dir move previews a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID7.json" 2>/dev/null)" "CONFIRM"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "in-root data-dir move with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "applied"
assert_eq "in-root move landed in .env" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$C/data/monero-v2"
# (2) A move to an arbitrary non-blocklisted, non-allowed path is refused EVEN with APPLY.
preview_move "$EVIL_DIR"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "out-of-root data-dir move is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
assert_contains "refusal names the data-root allowlist" "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "outside the stack data root"
# The refusal left config.json untouched — it still carries the previously-committed in-root value
# (test 1), never the refused out-of-root path.
assert_eq "refused move did not touch config.json" "$(jq -r '.monero.data_dir // empty' "$C/config.json")" "$C/data/monero-v2"
[ ! -f "$STAGED/$UUID7.json" ] && ok "refused out-of-root move cleared from staged" || bad "refused out-of-root move cleared from staged" "still staged"
# (3) The SAME path from the HOST shell still applies — the tighter rule is control-only.
jq -n --arg w "$WALLET" --arg dd "$EVIL_DIR" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_rc "host-shell apply to the same out-of-root path succeeds" "$?" "0"
assert_eq "host-shell apply rendered the out-of-root path (blocklist, not allowlist)" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$EVIL_DIR"

echo "== black-box: a NON-destructive commit still proceeds with no token (#33) =="
# Restore a clean baseline (prune off, clearnet off) then a pool switch mini -> nano is INFO, not
# DEST/CONFIRM — it commits with no confirmation at all.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "non-destructive commit still applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "non-destructive change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "nano"

echo "== black-box: approval gate default-denies security-control changes (#33 re-review) =="
# describe_change flags only the ENABLE/CHANGE direction of security controls as DEST — disabling
# dashboard auth, downgrading onion client-auth, clearing the stratum password or repointing the
# Telegram bot are all INFO rows. The gate must refuse those on the explicit sensitive-key set,
# independent of the DEST flag; a non-security change must still pass.
UUID5="55555555-5555-4555-8555-555555555555"
# Baseline: nano pool + stratum password + telegram bot + control, applied from the host CLI.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano",stratum_password:"s3cretpw"},
    telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
               control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
gate_try() { # <candidate-json-file> [confirm-token] — preview then commit via the spool; result lands in $RESULTS/$UUID5.json
    # An optional second arg carries a typed confirmation ("APPLY") on the commit, so a PERIMETER case
    # can prove the change stays refused EVEN WITH a valid token present. Omitted → token-less commit.
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
    if [ -n "${2:-}" ]; then
        printf '{"id":"%s","action":"commit","actor":"admin","confirm":"%s"}\n' "$UUID5" "$2" >"$REQS/$UUID5.json"
    else
        printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
    fi
    run_pending >/dev/null
}

# Disable the dashboard login (auth.password:"" needs control:false to pass validation): the
# preview flags destructive:false — proof the DEST path alone would wave it through — and the
# commit must still be refused, config untouched.
jq '.dashboard.auth={username:"admin"} | .dashboard.control={enabled:false}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "auth-disable previews destructive:false (DEST alone would allow it)" \
    "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "dashboard-login disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "auth-disable refusal names the sensitive-key gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the dashboard password" "$(jq -r '.dashboard.auth.password' "$C/config.json")" "a control passphrase"
assert_eq "config.json keeps control enabled" "$(jq -r '.dashboard.control.enabled' "$C/config.json")" "true"

# Clear the stratum access password (disable direction is an INFO row) — refused.
jq 'del(.p2pool.stratum_password)' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "stratum-password disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the stratum password" "$(jq -r '.p2pool.stratum_password' "$C/config.json")" "s3cretpw"

# Repoint the Telegram bot (token change is an INFO row; the bot is the future #338 approval
# channel, so an attacker must not swap it) — refused.
jq '.telegram.bot_token="654321:evil-XYZ_abc"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "telegram bot_token repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the original bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Downgrade the onion to password-only (client_auth:false is an INFO row in every direction).
# Baseline first: onion on + client_auth on (the only combo valid with control on), applied.
jq '.dashboard.onion={enabled:true,client_auth:true}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_contains "onion baseline applied (client_auth on)" "$(cat "$C/.env")" "DASHBOARD_ONION_CLIENT_AUTH=true"
jq '.dashboard.onion.client_auth=false | .dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "onion client-auth downgrade commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps onion client-auth on" "$(jq -r '.dashboard.onion.client_auth' "$C/config.json")" "true"

# TRUE default-deny (#33 re-review round 2): the gate is an ALLOWLIST of editable keys, not a
# blocklist of sensitive ones, so a key nobody thought to enumerate still refuses. Each candidate
# below was committable under the blocklist gate — these assertions are the teeth.
# p2pool clearnet flip: dials sidechain peers over clearnet, deanonymizing the host IP, no
# auto-revert.
jq '.p2pool.clearnet=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "p2pool clearnet flip commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps p2pool on Tor" "$(jq -r '.p2pool.clearnet // false' "$C/config.json")" "false"
# XvB stats over clearnet: correlates the host IP with the payout wallet.
jq '.xvb.tor=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb tor-disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps xvb on Tor" "$(jq -r '.xvb.tor // true' "$C/config.json")" "true"
# Healthchecks ping-URL repoint: exfiltrates liveness / silences the dead-man's switch.
jq '.healthchecks={ping_url:"https://attacker.example/ping"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "healthchecks ping-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps healthchecks unset" "$(jq -r '.healthchecks.ping_url // "unset"' "$C/config.json")" "unset"
# The #719 perimeter, named explicitly: disabling the Tor egress firewall would let containers dial
# clearnet — it is NOT in the confirm-gated set and stays host-only. Commit WITH a valid APPLY token
# to prove the typed confirmation does not unlock the perimeter — the refusal fires before the token
# is ever examined, so it stays refused just as it does token-less (#719).
jq '.network={tor_egress_firewall:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "tor-egress-firewall disable commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tor-egress refusal is a host-only gate (the APPLY token did not unlock it)" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the tor egress firewall unset (defaults on)" "$(jq -r '.network.tor_egress_firewall // "unset"' "$C/config.json")" "unset"
# Setting a Monero view key (the #381 payout-confirm secret) reveals every incoming amount — a
# secret, host-only, never confirm-gated. Commit WITH a valid APPLY token: the perimeter gate must
# still refuse it, proving the typed confirmation is UX friction, not a security bypass (#719).
jq '.monero.view_key="deadbeef"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "monero view-key set commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json gains no view key" "$(jq -r '.monero.view_key // "unset"' "$C/config.json")" "unset"
# XvB pool-URL repoint: redirects donated hashrate to an attacker's pool.
jq '.xvb.url="attacker.example:4247"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb pool-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the default xvb url" "$(jq -r '.xvb.url // "unset"' "$C/config.json")" "unset"
# The tamper-evidence alert toggles stay host-only even though sibling event toggles are
# editable: silencing WALLET_CHANGED would blind the future #338 approval channel.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "wallet-changed alert silencing is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
# An allowlisted operational toggle on the same baseline still commits.
jq '.telegram.events={node_down:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "allowlisted alert toggle still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "alert toggle landed in config.json" "$(jq -r '.telegram.events.node_down' "$C/config.json")" "false"
# dashboard.workers (#172) never renders to .env, so the env-diff allowlist can't see it — yet it
# carries per-rig hosts and API tokens (a committed attacker host would point token-bearing probes
# at it). The gate must refuse it via its explicit config-level check.
jq '.dashboard.workers=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "dashboard.workers change commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "workers refusal names dashboard.workers" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "dashboard.workers"
assert_eq "config.json keeps no worker descriptors" "$(jq -r '.dashboard.workers // "unset"' "$C/config.json")" "unset"
# workers.list[]'s add-only exception (#893's click-to-adopt) + the #122 SSRF floor on a newly
# appended entry's host — split into its own file purely for the file-budget ratchet; it shares
# this section's $C/$UUID5/gate_try exactly like test-control-deploy.sh shares its own section's.
# shellcheck source=tests/stack/test-control-add-only-ssrf.sh
source "$HERE/test-control-add-only-ssrf.sh"

# dashboard.energy (#504) is the ONE config.json-only block a commit MAY change: it never renders
# to .env, so the host previews it as a normal INFO row (not the old non-committable HOST note) and
# the commit lands it in config.json. Preview first to assert the committable row + non-destructive.
jq '.dashboard.energy={cost_per_kwh:0.18,currency:"EUR",xmr_price:142.5}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy preview status" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_contains "energy preview carries a committable change row" "$(jq -r '.changes[] | select(.key=="dashboard.energy") | .flag' "$RESULTS/$UUID5.json" 2>/dev/null)" "INFO"
assert_eq "energy edit alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy edit commits" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "energy cost landed in config.json" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
assert_eq "energy currency landed in config.json" "$(jq -r '.dashboard.energy.currency' "$C/config.json")" "EUR"
assert_contains "energy commit audits the synthetic key name (#504)" "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"

# Unedited editor round-trip (#696): the form serves the reference-merged config and posts the
# merged document back, so a save with NO edits must preview as zero changes. The live energy
# block above is partial — the merge materializes the remaining reference defaults (tari_price,
# price_feed) into the staged copy, and defaults against an absent value are the same settings,
# not an "Energy calculator settings updated" row.
UUIDE="55555555-5555-4555-8555-555555555555"
jq -s --arg id "$UUIDE" '{id:$id, action:"preview", actor:"admin",
    config:((.[0] | del(._docs)) * .[1])}' "$ROOT/config.reference.json" "$C/config.json" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip previews" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "previewed"
assert_eq "unedited merged round-trip shows zero changes (#696)" "$(jq -r '.changes | length' "$RESULTS/$UUIDE.json" 2>/dev/null)" "0"
# Audit leg of the same contract: committing that unedited round-trip must not record a phantom
# DASHBOARD_ENERGY key — the gate's audit comparison merges the reference defaults too (#696).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUIDE" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip commits" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "applied"
assert_not_contains "unedited commit audits no phantom DASHBOARD_ENERGY key (#696)" \
    "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"
rm -f "$RESULTS/$UUIDE.json" "$STAGED/$UUIDE.json"

# NEGATIVE — the #504 security teeth: an energy edit BUNDLED with a change that is NOT on the env
# allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND) must be REFUSED. The energy exemption must
# not become a carrier for other config: the gate re-derives the env change set host-side and the
# allowlist catches the monero key even though the energy block is legitimately editable.
jq '.dashboard.energy={cost_per_kwh:0.25} | .monero.rpc_lan_access=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit bundled with a non-allowlisted key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "bundled refusal names the security-sensitive gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps monero LAN access off after the refusal" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
assert_eq "config.json keeps the previously-committed energy cost after the refusal" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"

# NEGATIVE — closed-schema smuggling (#33 hardening). An unrecognized config.json key renders to NO
# env var, so it emits ZERO porcelain rows: invisible to the env-diff allowlist, yet the commit's
# `cp` would persist it. The schema guard must refuse it. (a) A LEGIT energy edit bundled with a
# smuggled top-level key is refused whole, and the key never lands. (b) A config identical to live
# except for one extra key still refuses — an empty change set must not read as "clean".
jq '.dashboard.energy={cost_per_kwh:0.30} | .attacker_smuggled={payload:"pwned"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit smuggling an unknown top-level key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "smuggle refusal names the schema and the offending key" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema (attacker_smuggled"
assert_eq "config.json never gains the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
assert_eq "config.json keeps the pre-smuggle energy cost" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
# Only an unknown key added — every rendered value byte-identical to live, so the porcelain is empty.
jq '.attacker_smuggled={payload:"x"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "an otherwise-identical config with one extra key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "empty-porcelain smuggle still names the schema guard" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema"
assert_eq "config.json still free of the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
# A nested unknown key under a KNOWN block (dashboard.energy) is caught by the same guard.
jq '.dashboard.energy={cost_per_kwh:0.18,__evil:{x:1}}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a nested unknown key under a known block is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"

# NO FALSE-REJECT on legacy configs: config.reference.json must be a COMPLETE superset of every path
# pithead READS, or the closed-schema guard refuses a legit config on EVERY commit. A config.json
# predating the xvb rename still carries a legacy xmrig_proxy.* block (read as an alias at pithead
# ~L3245). Seed it into the live baseline, then prove a normal on-allowlist commit
# (xvb.donation_level -> XVB_DONATION_LEVEL) still passes the gate and the legacy block round-trips.
jq '.xmrig_proxy={enabled:true,url:"na.xmrvsbeast.com:4247",donor_id:"auto"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.xvb.donation_level="whale"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a commit on a config carrying a legacy xmrig_proxy block still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the allowlisted xvb tier landed in config.json" "$(jq -r '.xvb.donation_level' "$C/config.json")" "whale"
assert_eq "the legacy xmrig_proxy block round-trips untouched" "$(jq -r '.xmrig_proxy.url' "$C/config.json")" "na.xmrvsbeast.com:4247"

# Forged-flag bypass: the container tampers its visible copy of the preview result to
# destructive:false AND sends a commit request carrying its own destructive:false field. The
# extra request key is rejected outright; a clean follow-up commit is still refused because the
# gate re-derives the change set host-side from the STAGED config — it never reads either flag.
jq '.telegram.bot_token="999999:forged-token"' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
printf '{"status":"previewed","changes":[],"destructive":false,"ts":0}\n' >"$RESULTS/$UUID5.json"
printf '{"id":"%s","action":"commit","actor":"admin","destructive":false}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "commit request smuggling a destructive flag is rejected" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "unexpected keys"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "commit after result-file tampering is still refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tampered-flag refusal comes from the host-side re-derivation" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the untampered bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Sensitive keys PRESENT but UNCHANGED must not trip the gate: a plain pool-tier change on the
# same baseline (auth + onion + stratum password + telegram all set) still applies.
jq '.p2pool.pool="mini"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "non-security change on a security-laden config still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "pool tier change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"

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

echo "== black-box: per-worker token mask + host-side restore, legacy dashboard.workers (#172/#679) =="
# dashboard.workers[].token is a per-rig credential living in a VARIABLE-LENGTH array — out of the
# fixed CONTROL_SECRET_PATHS walk. The masked prefill copy must sentinel each set token (extends
# the #440 property per-rig), and the staging swap must restore each sentinel from the LIVE token
# matched by worker NAME. Per-worker descriptors are never dashboard-EDITABLE (the commit gate
# refuses any dashboard.workers change, asserted above) — so this restore is exactly what lets an
# operator's OTHER edits round-trip: the workers come back as sentinels and must resolve to the
# live values unchanged, or every dashboard commit on a stack with configured workers would fail.
# Since #679 `apply` MIGRATES the legacy shape, so a live config carries dashboard.workers only
# between a hand-edit and the next apply — exactly the state the preview leg (a dry run, never
# migrates) still serves. Hand-edit to legacy and render the masked copy directly, no apply.
jq '.dashboard.workers=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}] | del(.workers.list)' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears,
#    and a token-less worker stays token-less.
assert_eq "per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less worker stays token-less in the masked copy" "$(jq -r '.dashboard.workers[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no per-worker token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no per-worker token" ;;
esac
# 2) staging swap: a proposal that prefills the workers from the masked copy (sentinel tokens) and
#    changes only an allowlisted key stages with each token restored from live BY NAME.
UUID6="66666666-6666-4666-8666-666666666666"
jq --arg id "$UUID6" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="main")}' "$MASKED" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "previewed"
assert_eq "per-worker sentinel restored to the live token by name" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second per-worker sentinel restored by name" "$(jq -r '.dashboard.workers[2].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig3secret"
assert_eq "token-less worker stays token-less at staging" "$(jq -r '.dashboard.workers[1] | has("token")' "$STAGED/$UUID6.json" 2>/dev/null)" "false"
case "$(cat "$RESULTS/$UUID6.json")$(cat "$AUDIT")" in
*tok_rig1secret* | *tok_rig3secret*) bad "results/audit stay free of the restored per-worker token" "a per-worker token leaked" ;;
*) ok "results/audit stay free of the restored per-worker token" ;;
esac
# 3) commit: workers restored to live == live, so the gate passes on the pool-only change; the
#    commit's `apply -y` then MIGRATES (#679) — the committed config keeps the live per-worker
#    tokens under workers.list[], the legacy key is gone, and the pre-migration copy sits beside.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID6" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live per-worker token (migrated to workers.list, #679)" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "commit migrated the legacy key away (#679)" "$(jq -r '.dashboard | has("workers")' "$C/config.json")" "false"
assert_eq "pre-migration copy kept through the control commit (#679)" "$(jq -r '.dashboard.workers[0].token' "$C/config.json.bak-workers" 2>/dev/null)" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
# 4) duplicate names resolve first-declared-wins (staging only — a duplicate can't round-trip a
#    commit, since the second entry's token would flip and trip the gate). Same hand-edited
#    legacy state as above: masked copy rendered directly, no apply, so no migration yet.
jq 'del(.workers.list) | .dashboard.workers=[{name:"rig1",host:"10.0.0.5",token:"tok_first"},{name:"rig1",token:"tok_second"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
UUID7="77777777-7777-4777-8777-777777777777"
jq --arg id "$UUID7" '{id:$id, action:"preview", actor:"admin", config: .}' "$MASKED" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "duplicate-name sentinel restores the first-declared token" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"
assert_eq "duplicate-name second entry also resolves to first-declared" "$(jq -r '.dashboard.workers[1].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"

echo "== black-box: per-worker token mask + host-side restore, workers.list[] shape (#506) =="
# Same mask/restore/commit round-trip as above, but on the CURRENT workers.list[] shape — proves
# render_masked_config and the control_preview sentinel swap key off whichever shape the live
# config actually uses, not a hardcoded dashboard.workers path. Clear the legacy key first so the
# live config carries only the new shape (both-set is refused at apply, asserted earlier).
jq 'del(.dashboard.workers) | .workers.list=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears.
assert_eq "workers.list token masked to the sentinel" "$(jq -c '.workers.list[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second workers.list token masked to the sentinel" "$(jq -c '.workers.list[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less workers.list worker stays token-less in the masked copy" "$(jq -r '.workers.list[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no workers.list token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no workers.list token" ;;
esac
# 2) staging swap: a proposal that prefills from the masked copy stages with each token restored
#    from live BY NAME.
UUID8="88888888-8888-4888-8888-888888888888"
jq --arg id "$UUID8" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="nano")}' "$MASKED" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "previewed"
assert_eq "workers.list sentinel restored to the live token by name" "$(jq -r '.workers.list[0].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second workers.list sentinel restored by name" "$(jq -r '.workers.list[2].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig3secret"
# 3) commit: workers.list restored to live == live, so the gate passes on the pool-only change, and
#    the committed config KEEPS the live per-worker tokens.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID8" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live workers.list token" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"

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

echo "== black-box: audit log growth is bounded (#349) =="
# Seed the log past the 512 KiB cap, then let the runner audit one more event: the writer trims
# to the newest 2000 lines BEFORE appending, so the file shrinks instead of growing forever and
# the fresh entry is always the last line.
for _ in $(seq 1 6000); do
    printf '{"ts":"old","id":"","actor":"filler","action":"preview","status":"previewed","keys":""}\n'
done >>"$AUDIT"
[ "$(wc -c <"$AUDIT" | tr -d ' ')" -gt 524288 ] || bad "audit log seeded past the cap" "seed too small"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json" # no staged intent -> rejected, still audited
run_pending >/dev/null
audit_size="$(wc -c <"$AUDIT" | tr -d ' ')"
if [ "$audit_size" -lt 300000 ]; then
    ok "audit log trimmed back under the cap ($audit_size bytes)"
else
    bad "audit log trimmed back under the cap" "$audit_size bytes"
fi
assert_eq "trim keeps the newest entries (fresh entry is the last line)" "$(tail -n 1 "$AUDIT" | jq -r '.action')" "commit"
# Pin the line count too, not just the byte size: control_audit trims to `tail -n 2000` BEFORE
# appending the triggering entry, so the file must land at <= 2001 lines (2000 kept + the new one) —
# the "newest ~2000 lines" behavior the byte-size check above doesn't directly prove.
audit_lines="$(wc -l <"$AUDIT" | tr -d ' ')"
if [ "$audit_lines" -le 2001 ]; then
    ok "audit log trim caps the line count near the newest 2000 entries ($audit_lines lines)"
else
    bad "audit log trim caps the line count near the newest 2000 entries" "$audit_lines lines"
fi

echo "== black-box: spool intake cap + symlink refusal + stale sweep (#33 hardening) =="
UUID4="44444444-4444-4444-8444-444444444444"
# Oversized intent: refused BEFORE jq parses it (bounded root-runner DoS), no result addressed.
: >"$AUDIT"
{
    printf '{"id":"%s","action":"preview","pad":"' "$UUID4"
    head -c 70000 /dev/zero | tr '\0' a
    printf '"}\n'
} >"$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "oversized intent refused before parsing" "$(cat "$AUDIT" 2>/dev/null)" "refused-oversize"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "oversized intent gets no result file" || bad "oversized intent gets no result file" "result written"
[ ! -f "$REQS/$UUID4.json" ] && ok "oversized intent claimed out of requests/" || bad "oversized intent claimed out of requests/" "still present"
# Symlinked request: a symlink dropped in requests/ could point the root runner at any host file —
# refused, never followed (graft #437).
: >"$AUDIT"
ln -s "$C/config.json" "$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "symlinked request refused" "$(cat "$AUDIT" 2>/dev/null)" "refused-nonregular"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "symlinked request gets no result" || bad "symlinked request gets no result" "result written"
rm -f "$REQS/$UUID4.json"
# Stale sweep: staged/ + requests/ files older than an hour are removed at run start.
jq -n '{}' >"$STAGED/stale.json"
touch -t 202001010000 "$STAGED/stale.json"
printf '{}' >"$REQS/stale-req.json"
touch -t 202001010000 "$REQS/stale-req.json"
run_pending >/dev/null
[ ! -f "$STAGED/stale.json" ] && ok "aged staged file swept" || bad "aged staged file swept" "still present"
[ ! -f "$REQS/stale-req.json" ] && ok "aged request file swept" || bad "aged request file swept" "still present"
# Orphaned claim sweep (#548): a `.claim.<pid>` left behind by a runner that died mid-dispatch
# (the errexit gap this issue closes) is swept the same way as stale staged/request files.
touch -t 202001010000 "$C/data/control/.claim.12345"
run_pending >/dev/null
[ ! -f "$C/data/control/.claim.12345" ] && ok "stale orphaned claim swept" || bad "stale orphaned claim swept" "still present"
# Per-run intake cap: 60 pending intents → one run claims exactly 50 and LEAVES the remainder in
# requests/ for the next path-unit fire (deterministic overflow — nothing is dropped). Invalid
# JSON bodies keep each of the 60 on the cheap discard path; they still count against the cap.
for i in $(seq 1 60); do printf 'notjson' >"$REQS/cap-$i.json"; done
out="$(run_pending)"
assert_contains "per-run cap announced after 50 intents" "$out" "per-run cap"
assert_contains "exactly 50 intents processed in one run" "$out" "Processed 50 control request(s)"
assert_eq "overflow intents left for the next run" "$(ls "$REQS" | wc -l | tr -d ' ')" "10"
out="$(run_pending)"
assert_contains "next run drains the remainder" "$out" "Processed 10 control request(s)"
assert_eq "spool empty after the second run" "$(ls "$REQS" | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-deploy.sh
source "$HERE/test-control-deploy.sh"

echo "== control channel: Telegram lifecycle verbs (#338) =="
# The #33 runner dispatches the two bounded Telegram control verbs to FIXED pithead commands and
# audits them; an unknown verb is rejected and no host command runs. PITHEAD_SELF points the runner
# at a stub that only records the literal verb it was handed, so nothing real is applied/restarted.
CC="$SANDBOX/ctrl338"
mkdir -p "$CC/staged" "$CC/results" "$CC/audit"
cat >"$CC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SELF_LOG"
exit 0
EOF
chmod +x "$CC/self"
export SELF_LOG="$CC/self.log"
export PITHEAD_SELF="$CC/self"
uid_r="11111111-1111-4111-8111-111111111111"
uid_a="22222222-2222-4222-8222-222222222222"
uid_x="33333333-3333-4333-8333-333333333333"

: >"$SELF_LOG"
printf '{"id":"%s","action":"restart","actor":"tg-7"}\n' "$uid_r" >"$CC/req_r.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_r.json" "$CC" >/dev/null 2>&1
assert_eq "restart intent runs the fixed 'restart' verb" "$(cat "$SELF_LOG")" "restart"
assert_eq "restart result is applied" "$(jq -r .status "$CC/results/$uid_r.json")" "applied"
assert_contains "restart is audited with the actor + action" \
    "$(cat "$CC/audit/control.log")" '"actor":"tg-7","action":"restart","status":"applied"'

: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tg-7"}\n' "$uid_a" >"$CC/req_a.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "apply intent runs the fixed 'apply -y' verb (config re-apply, no edit)" "$(cat "$SELF_LOG")" "apply -y"
assert_eq "apply result is applied" "$(jq -r .status "$CC/results/$uid_a.json")" "applied"

: >"$SELF_LOG"
printf '{"id":"%s","action":"frobnicate","actor":"tg-7"}\n' "$uid_x" >"$CC/req_x.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_x.json" "$CC" >/dev/null 2>&1
assert_eq "unknown verb rejected (bounded action set)" "$(jq -r .error "$CC/results/$uid_x.json")" "unknown action"
assert_eq "unknown verb never runs a host command" "$(cat "$SELF_LOG")" ""
unset PITHEAD_SELF SELF_LOG

# ---------------------------------------------------------------------------
echo "== control channel: worker config apply fails closed (#185) =="
# control_worker_apply resolves the rig's host/token from the HOST's config.json (never the intent)
# and refuses — before dialing any rig — a bad worker name, a non-writable key, an empty change, or a
# worker missing a host or token. These are the fail-closed guards a compromised container hits.
WA="$SANDBOX/ctrl185"
mkdir -p "$WA/staged" "$WA/results" "$WA/audit"
# config.json: rig1 fully addressable (host+token), rig2 has a host but no token (bearer-mandatory).
cat >"$WA/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wa_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WA/req.json"
    PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WA/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
u1="aaaaaaaa-1111-4111-8111-111111111111"
u2="bbbbbbbb-2222-4222-8222-222222222222"
u3="cccccccc-3333-4333-8333-333333333333"
u4="dddddddd-4444-4444-8444-444444444444"
u5="eeeeeeee-5555-4555-8555-555555555555"
wa_case "$u1" "{\"id\":\"$u1\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"\",\"changes\":{\"DONATION\":2}}" "empty worker name rejected" "worker"
wa_case "$u2" "{\"id\":\"$u2\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{\"ACCESS_TOKEN\":\"x\"}}" "non-writable key rejected" "not writable"
wa_case "$u3" "{\"id\":\"$u3\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{}}" "empty changes rejected" "non-empty"
wa_case "$u4" "{\"id\":\"$u4\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"ghost\",\"changes\":{\"DONATION\":2}}" "unknown/hostless worker rejected" "no configured host"
wa_case "$u5" "{\"id\":\"$u5\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig2\",\"changes\":{\"DONATION\":2}}" "worker without a token rejected (bearer-mandatory)" "no token"
# The intent's own host/port/token are IGNORED — resolution is from config.json only (#122). A tampered
# intent naming rig2 (no token) with an injected token still fails closed.
u6="ffffffff-6666-4666-8666-666666666666"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig2","changes":{"DONATION":2}}\n' "$u6" >"$WA/req.json"
PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_eq "worker-apply reject is audited by name only" \
    "$(jq -r '.status' "$WA/results/$u6.json")" "rejected"
assert_contains "worker-apply audit records the action, no token" \
    "$(cat "$WA/audit/control.log")" '"action":"worker-apply","status":"rejected"'
if grep -q 'tok-rig1' "$WA/audit/control.log" "$WA"/results/*.json 2>/dev/null; then
    bad "worker-apply never leaks a token to results/audit" "token found"
else
    ok "worker-apply never leaks a token to results/audit"
fi
# Per-drain dial budget (#185 hardening): with the budget exhausted, a fully-valid apply (rig1 has a
# host + token) is refused BEFORE any rig dial, so a flood can't starve the root runner.
u7="99999999-7777-4777-8777-777777777777"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u7" >"$WA/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_contains "worker-apply over the dial budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WA/results/$u7.json")" "too many worker config changes"

# workers.list[] (#506): control_worker_apply resolves the rig's host/token the same way from the
# CURRENT shape. Reuses the budget=0 technique above — a "too many worker config changes" rejection
# (instead of "no configured host"/"no token") proves resolution succeeded BEFORE the pre-dial
# budget gate, without needing to stub the actual network dial.
WA2="$SANDBOX/ctrl506"
mkdir -p "$WA2/staged" "$WA2/results" "$WA2/audit"
cat >"$WA2/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
u8="88888888-9999-4999-8999-888888888888"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u8" >"$WA2/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA2/config.json" run_sourced "$SANDBOX" control_process_request "$WA2/req.json" "$WA2" >/dev/null 2>&1
assert_contains "workers.list worker-apply resolves the rig (budget rejection proves pre-dial success)" \
    "$(jq -r '.error // ""' "$WA2/results/$u8.json")" "too many worker config changes"

echo "== control channel: worker config apply ACCEPT path succeeds + is audited (#185) =="
# Mirrors the reject-path setup above, but with a stub curl standing in for the rig's control API so a
# fully-valid worker-apply actually dials, gets accepted (202 + change_id), and polls the rig's
# /status to a terminal "applied" — proving the success leg of #185, not just the fail-closed guards
# exercised above it.
WA3="$SANDBOX/ctrl185-accept"
mkdir -p "$WA3/staged" "$WA3/results" "$WA3/audit" "$WA3/bin"
cat >"$WA3/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
# A minimal curl stand-in: no real network dial. Reads its own args for `-o <file>` and the trailing
# URL (curl always puts flags/headers/data before the bare URL, so the last plain token IS the URL);
# serves a canned 202 body for POST .../apply and a terminal "applied" 200 body for GET .../status —
# mirroring what a real RigForge rig's control API returns (rigforge#236's status shape).
cat >"$WA3/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-1"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-1","status":"applied","changed_keys":["pools"]}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA3/bin/curl"
u9="12121212-1212-4212-8212-121212121212"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u9" >"$WA3/req.json"
PATH="$WA3/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA3/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA3/req.json" "$WA3" >/dev/null 2>&1
assert_eq "worker-apply accept path reaches a terminal 'applied' status" \
    "$(jq -r '.status' "$WA3/results/$u9.json" 2>/dev/null)" "applied"
assert_eq "worker-apply accept path records the rig's change_id" \
    "$(jq -r '.change_id' "$WA3/results/$u9.json" 2>/dev/null)" "chg-1"
assert_eq "worker-apply accept path records the rig's changed_keys" \
    "$(jq -rc '.changed_keys' "$WA3/results/$u9.json" 2>/dev/null)" '["pools"]'
assert_contains "worker-apply accept is audited as applied" \
    "$(cat "$WA3/audit/control.log")" '"action":"worker-apply","status":"applied"'
# The rig can also end an apply terminal "failed" — it could not restore its own rollback backup
# (present since the v1.11.2 fleet floor). The poll must land it as failed-with-reason, never burn
# the 20s deadline into a vague "accepted".
WA4="$SANDBOX/ctrl185-failed"
mkdir -p "$WA4/staged" "$WA4/results" "$WA4/audit" "$WA4/bin"
cp "$WA3/config.json" "$WA4/config.json"
cat >"$WA4/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-2"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-2","status":"failed","reason":"rollback backup unreadable: /var/lib/rigforge/backup"}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA4/bin/curl"
u10="fafafafa-fafa-4afa-8afa-fafafafafafa"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u10" >"$WA4/req.json"
PATH="$WA4/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA4/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA4/req.json" "$WA4" >/dev/null 2>&1
assert_eq "a failed apply reaches terminal 'failed', not the poll-deadline 'accepted'" \
    "$(jq -r '.status' "$WA4/results/$u10.json" 2>/dev/null)" "failed"
assert_contains "the failed apply carries the rig's reason" \
    "$(jq -r '.reason' "$WA4/results/$u10.json" 2>/dev/null)" "rollback backup unreadable"
assert_contains "the failed apply is audited as failed" \
    "$(cat "$WA4/audit/control.log")" '"action":"worker-apply","status":"failed"'

# ---------------------------------------------------------------------------
echo "== control channel: worker upgrade fails closed (#597) =="
# control_worker_upgrade fuses the worker-apply template (rig resolved from the HOST config, never
# the intent) with the stack-upgrade template (host-side target re-derivation, throttled). These are
# the pre-dial fail-closed guards.
WU="$SANDBOX/ctrl597"
mkdir -p "$WU/staged" "$WU/results" "$WU/audit"
cat >"$WU/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wu_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WU/req.json"
    PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WU/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
w1="aaaaaaaa-1111-4111-9111-111111111111"
w2="bbbbbbbb-2222-4222-9222-222222222222"
w3="cccccccc-3333-4333-9333-333333333333"
w4="dddddddd-4444-4444-9444-444444444444"
w5="eeeeeeee-5555-4555-9555-555555555555"
wu_case "$w1" "{\"id\":\"$w1\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"\",\"version\":\"v1.11.2\"}" "upgrade: empty worker name rejected" "worker"
wu_case "$w2" "{\"id\":\"$w2\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig1\",\"version\":\"1.11.2\"}" "upgrade: bare (non-tag) version rejected" "version"
wu_case "$w3" "{\"id\":\"$w3\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"ghost\",\"version\":\"v1.11.2\"}" "upgrade: unknown/hostless worker rejected" "no configured host"
wu_case "$w4" "{\"id\":\"$w4\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig2\",\"version\":\"v1.11.2\"}" "upgrade: worker without a token rejected (bearer-mandatory)" "no token"
# Per-drain budget: exactly one upgrade dials per drain; over-budget rejects BEFORE the tag lookup
# (a "already in this cycle" rejection also proves rig resolution succeeded pre-dial).
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w5" >"$WU/req.json"
CONTROL_WU_BUDGET=0 PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
assert_contains "upgrade over the per-drain budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WU/results/$w5.json")" "already in this cycle"
if grep -q 'tok-rig1' "$WU/audit/control.log" "$WU"/results/*.json 2>/dev/null; then
    bad "worker-upgrade never leaks a token to results/audit" "token found"
else
    ok "worker-upgrade never leaks a token to results/audit"
fi
# Anti-beacon throttle (#597, control_upgrade's lesson): a fresh lookup stamp with no cached tag
# means a recent derive attempt failed — refuse WITHOUT another GitHub/Tor dial. The curl stub
# records every invocation; it must stay unused.
WUT="$SANDBOX/ctrl597-throttle"
mkdir -p "$WUT/staged" "$WUT/results" "$WUT/audit" "$WUT/bin"
cp "$WU/config.json" "$WUT/config.json"
cat >"$WUT/bin/curl" <<EOF
#!/usr/bin/env bash
echo "dialed \$*" >>"$WUT/dials.log"
exit 7
EOF
chmod +x "$WUT/bin/curl"
touch "$WUT/staged/.rigforge-latest-stamp"
w6="ffffffff-6666-4666-9666-666666666666"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w6" >"$WUT/req.json"
PATH="$WUT/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$WUT/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WUT/req.json" "$WUT" >/dev/null 2>&1
assert_contains "upgrade inside the 10-min lookup window (no cached tag) is rejected" \
    "$(jq -r '.error // ""' "$WUT/results/$w6.json")" "retry in a few minutes"
assert_eq "the throttled upgrade made NO network dial" "$(cat "$WUT/dials.log" 2>/dev/null)" ""

echo "== control channel: worker upgrade drives the rig to each terminal (#597) =="
# A stub curl stands in for the rig's control API (and would catch any unexpected GitHub dial: the
# tag is pre-cached, so the only allowed URLs are the rig's /upgrade and /status). One sandbox per
# scenario; the stub's /status behaviour is parameterized via WU_STATUS_BODY, and the stale-terminal
# case serves a PREVIOUS change's terminal first to prove change_id matching.
wu_accept_case() { # <uuid> <status-body-json> <label> <expected-status>
    local dir="$SANDBOX/ctrl597-$1"
    mkdir -p "$dir/staged" "$dir/results" "$dir/audit" "$dir/bin"
    cp "$WU/config.json" "$dir/config.json"
    printf '%s' "v9.9.9" >"$dir/staged/.rigforge-latest-tag"
    cat >"$dir/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$dir/dials.log"
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status) printf '%s' '$2' >"\$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/curl"
    printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$1" >"$dir/req.json"
    PATH="$dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$dir/config.json" \
        run_sourced "$SANDBOX" control_process_request "$dir/req.json" "$dir" >/dev/null 2>&1
    assert_eq "$3" "$(jq -r '.status' "$dir/results/$1.json" 2>/dev/null)" "$4"
    WU_LAST_DIR="$dir"
}
w7="12121212-1212-4212-9212-121212121212"
wu_accept_case "$w7" '{"change_id":"chg-9","status":"applied"}' \
    "upgrade accept path reaches a terminal 'applied'" "applied"
assert_eq "applied result records the rig's change_id" \
    "$(jq -r '.change_id' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "chg-9"
assert_eq "applied result records the host-derived version" \
    "$(jq -r '.version' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "v9.9.9"
# #690: every runner dial (the rig POST + each /status poll) carries a response-size cap so a
# hostile rig can't stream an unbounded body into disk/memory. Proves the flag is wired, not curl's
# own enforcement (that needs a real curl against an oversized server — an e2e concern).
assert_contains "worker-upgrade rig dials carry a --max-filesize cap (#690)" \
    "$(cat "$WU_LAST_DIR/dials.log" 2>/dev/null)" "--max-filesize"
assert_contains "upgrade applied is audited" \
    "$(cat "$WU_LAST_DIR/audit/control.log")" '"action":"worker-upgrade","status":"applied"'
w8="23232323-2323-4232-9232-232323232323"
wu_accept_case "$w8" '{"change_id":"chg-9","status":"rolled_back","reason":"miner did not return live"}' \
    "upgrade rollback surfaces as rolled_back" "rolled_back"
assert_eq "rolled_back result carries the rig's reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w8.json" 2>/dev/null)" "miner did not return live"
w9="34343434-3434-4234-9234-343434343434"
wu_accept_case "$w9" '{"change_id":"chg-9","status":"failed","reason":"throttled: retry after the window"}' \
    "legacy rig (pre-v1.12.0) throttle refusal (failed+text) still maps to retry-later" "throttled"
# First-class terminals since rigforge#320 (v1.12.0): noop (already on the target) and throttled
# land their real status on the first poll — neither burns the poll cap into a vague "accepted".
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
wu_accept_case "$w17" '{"change_id":"chg-9","status":"noop","reason":"already on v9.9.9 — nothing to upgrade"}' \
    "a rig already on the target lands first-class 'noop', not the poll-cap fallback" "noop"
assert_contains "the noop result carries the rig's already-on-target reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w17.json" 2>/dev/null)" "already on v9.9.9"
w18="cdcdcdcd-cdcd-42cd-92cd-cdcdcdcdcdcd"
wu_accept_case "$w18" '{"change_id":"chg-9","status":"throttled","reason":"throttled — too soon since the last upgrade attempt"}' \
    "a first-class 'throttled' terminal lands as retry-later on the first poll" "throttled"
# A genuine failure that merely MENTIONS the throttle must stay a fault (rigforge#321's
# fail-closed refusal): only the legacy leading-"throttled" free text remaps to retry-later.
w19="dededede-dede-42de-92de-dededededede"
wu_accept_case "$w19" '{"change_id":"chg-9","status":"failed","reason":"throttle state unavailable under /var/lib/rigforge — refused (fail-closed)"}' \
    "a broken-rig failure mentioning the throttle stays 'failed', never calmed" "failed"
# An unreachable rig fails cleanly (nothing changed, rig keeps its version).
unreach_dir="$SANDBOX/ctrl597-unreach"
mkdir -p "$unreach_dir/staged" "$unreach_dir/results" "$unreach_dir/audit" "$unreach_dir/bin"
cp "$WU/config.json" "$unreach_dir/config.json"
printf '%s' "v9.9.9" >"$unreach_dir/staged/.rigforge-latest-tag"
printf '#!/usr/bin/env bash\nexit 7\n' >"$unreach_dir/bin/curl"
chmod +x "$unreach_dir/bin/curl"
w12="67676767-6767-4267-9267-676767676767"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w12" >"$unreach_dir/req.json"
PATH="$unreach_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$unreach_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$unreach_dir/req.json" "$unreach_dir" >/dev/null 2>&1
assert_contains "an unreachable rig fails cleanly (nothing changed)" \
    "$(jq -r '.status + "|" + (.error // "")' "$unreach_dir/results/$w12.json")" "failed|could not reach worker"

# A non-latest proposal is refused against the CACHED tag — before any rig dial.
wa_dir="$SANDBOX/ctrl597-notlatest"
mkdir -p "$wa_dir/staged" "$wa_dir/results" "$wa_dir/audit"
cp "$WU/config.json" "$wa_dir/config.json"
printf '%s' "v9.9.9" >"$wa_dir/staged/.rigforge-latest-tag"
w10="45454545-4545-4245-9245-454545454545"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.0.0"}\n' "$w10" >"$wa_dir/req.json"
CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$wa_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$wa_dir/req.json" "$wa_dir" >/dev/null 2>&1
assert_contains "a non-latest proposal is refused against the host-derived tag" \
    "$(jq -r '.error // ""' "$wa_dir/results/$w10.json")" "not the latest published RigForge release"
# Stale-terminal guard: the rig's /status first shows a PREVIOUS change's applied (no in-progress
# state, rigforge#320) — it must be ignored until OUR change_id appears.
stale_dir="$SANDBOX/ctrl597-stale"
mkdir -p "$stale_dir/staged" "$stale_dir/results" "$stale_dir/audit" "$stale_dir/bin"
cp "$WU/config.json" "$stale_dir/config.json"
printf '%s' "v9.9.9" >"$stale_dir/staged/.rigforge-latest-tag"
cat >"$stale_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status)
    if [ -f "$stale_dir/.polled" ]; then
        printf '{"change_id":"chg-9","status":"applied"}' >"\$out"
    else
        touch "$stale_dir/.polled"
        printf '{"change_id":"chg-OLD","status":"applied"}' >"\$out"
    fi
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$stale_dir/bin/curl"
w11="56565656-5656-4256-9256-565656565656"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w11" >"$stale_dir/req.json"
PATH="$stale_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$stale_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$stale_dir/req.json" "$stale_dir" >/dev/null 2>&1
assert_eq "a stale terminal for a PREVIOUS change_id is ignored; ours lands" \
    "$(jq -r '.status + "|" + .change_id' "$stale_dir/results/$w11.json" 2>/dev/null)" "applied|chg-9"
# Poll-cap timeout (the sec-review headline fix): the cap bounds a hostile/hung rig's hold on the
# single-threaded root drain, and hitting it must land "accepted" (queued on the rig; the #596
# badge clears on its own), never a failure. CONTROL_WU_POLL_CAP shrinks the 90s cap so this
# proves the fallback in seconds — the rig accepts (202) but its /status only ever shows a
# PREVIOUS change's terminal, so no terminal for OUR change_id arrives inside the cap.
to_dir="$SANDBOX/ctrl597-timeout"
mkdir -p "$to_dir/staged" "$to_dir/results" "$to_dir/audit" "$to_dir/bin"
cp "$WU/config.json" "$to_dir/config.json"
printf '%s' "v9.9.9" >"$to_dir/staged/.rigforge-latest-tag"
cat >"$to_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-OLD","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$to_dir/bin/curl"
w13="78787878-7878-4278-9278-787878787878"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w13" >"$to_dir/req.json"
PATH="$to_dir/bin:$PATH" CONTROL_WU_BUDGET=1 CONTROL_WU_POLL_CAP=1 PITHEAD_CONFIG_FILE="$to_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$to_dir/req.json" "$to_dir" >/dev/null 2>&1
assert_eq "hitting the poll cap lands 'accepted' (queued on the rig), not a failure" \
    "$(jq -r '.status + "|" + .change_id' "$to_dir/results/$w13.json" 2>/dev/null)" "accepted|chg-9"
assert_contains "the timed-out result says the upgrade is still running" \
    "$(jq -r '.note // ""' "$to_dir/results/$w13.json" 2>/dev/null)" "still running on the rig"
assert_contains "the poll-cap timeout is audited as accepted" \
    "$(cat "$to_dir/audit/control.log")" '"action":"worker-upgrade","status":"accepted"'

echo "== control channel: worker upgrade derives the target tag from GitHub (#597) =="
# Every accept case above pre-caches .rigforge-latest-tag; these prove the derive itself. The
# GitHub call captures curl's STDOUT (no -o), so the stub answers the release API on stdout and
# keeps the -o/-w shape for the rig's /upgrade + /status.
gh_dir="$SANDBOX/ctrl597-derive"
mkdir -p "$gh_dir/staged" "$gh_dir/results" "$gh_dir/audit" "$gh_dir/bin"
cp "$WU/config.json" "$gh_dir/config.json"
cat >"$gh_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/releases/latest) printf '{"tag_name":"v9.9.9"}\n200' ;;
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-9","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$gh_dir/bin/curl"
w14="89898989-8989-4289-9289-898989898989"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w14" >"$gh_dir/req.json"
PATH="$gh_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$gh_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$gh_dir/req.json" "$gh_dir" >/dev/null 2>&1
assert_eq "a fresh derive parses tag_name and drives the upgrade to applied" \
    "$(jq -r '.status + "|" + .version' "$gh_dir/results/$w14.json" 2>/dev/null)" "applied|v9.9.9"
assert_eq "the derived tag is cached for the next intent" \
    "$(cat "$gh_dir/staged/.rigforge-latest-tag" 2>/dev/null)" "v9.9.9"
# GitHub unreachable over Tor: refused fail-closed, nothing dialed toward the rig.
ghfail_dir="$SANDBOX/ctrl597-ghdown"
mkdir -p "$ghfail_dir/staged" "$ghfail_dir/results" "$ghfail_dir/audit" "$ghfail_dir/bin"
cp "$WU/config.json" "$ghfail_dir/config.json"
printf '#!/usr/bin/env bash\nexit 7\n' >"$ghfail_dir/bin/curl"
chmod +x "$ghfail_dir/bin/curl"
w15="9a9a9a9a-9a9a-429a-929a-9a9a9a9a9a9a"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w15" >"$ghfail_dir/req.json"
PATH="$ghfail_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghfail_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghfail_dir/req.json" "$ghfail_dir" >/dev/null 2>&1
assert_contains "an unreachable GitHub release API refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghfail_dir/results/$w15.json")" \
    "rejected|could not reach the GitHub release API over Tor"
# GitHub reachable but the response carries no usable tag: refused fail-closed.
ghjunk_dir="$SANDBOX/ctrl597-ghjunk"
mkdir -p "$ghjunk_dir/staged" "$ghjunk_dir/results" "$ghjunk_dir/audit" "$ghjunk_dir/bin"
cp "$WU/config.json" "$ghjunk_dir/config.json"
cat >"$ghjunk_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"message":"Not Found"}\n200'
exit 0
EOF
chmod +x "$ghjunk_dir/bin/curl"
w16="abababab-abab-42ab-92ab-abababababab"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w16" >"$ghjunk_dir/req.json"
PATH="$ghjunk_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghjunk_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghjunk_dir/req.json" "$ghjunk_dir" >/dev/null 2>&1
assert_contains "a release API response with no usable tag refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghjunk_dir/results/$w16.json")" \
    "rejected|the GitHub release API returned no usable RigForge release tag"

# Rig refusal (non-202) — this branch is also where an old rig (< v1.11.2: no /upgrade endpoint,
# or its own version gate) surfaces its refusal. The rig's error text is attacker-influenceable
# (a compromised rig / LAN MITM), so it must be capped at 500 chars before it lands in a result.
refuse_dir="$SANDBOX/ctrl597-refuse"
mkdir -p "$refuse_dir/staged" "$refuse_dir/results" "$refuse_dir/audit" "$refuse_dir/bin"
cp "$WU/config.json" "$refuse_dir/config.json"
printf '%s' "v9.9.9" >"$refuse_dir/staged/.rigforge-latest-tag"
# 500 filler chars then a marker: the cap keeps the filler and must drop the marker.
wu_long_err="$(printf 'A%.0s' $(seq 1 500))OVERFLOW-TAIL"
cat >"$refuse_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"error":"$wu_long_err"}' >"\$out"; printf '403' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$refuse_dir/bin/curl"
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w17" >"$refuse_dir/req.json"
PATH="$refuse_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$refuse_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$refuse_dir/req.json" "$refuse_dir" >/dev/null 2>&1
assert_contains "a rig non-202 (incl. an old-rig < v1.11.2 refusal) is surfaced as rejected" \
    "$(jq -r '.status + "|" + (.error // "")' "$refuse_dir/results/$w17.json")" \
    "rejected|worker 'rig1' refused the upgrade (HTTP 403): AAAA"
assert_not_contains "the rig's error text is truncated at 500 chars" \
    "$(jq -r '.error // ""' "$refuse_dir/results/$w17.json")" "OVERFLOW-TAIL"

# ---------------------------------------------------------------------------
echo "== control channel: backup verb (#908) =="
# control_backup generates its OWN passphrase (never accepted from the container), runs the
# real backup as a CHILD "$self backup -y" (stack_backup's own error() exits its process, which
# must not take the drain loop's other pending requests with it), and hands back a one-time kit
# through results/. A stub self reproduces stack_backup's own "Backup written to: <path>" log
# line so this stays a fast, docker-free test of the GLUE — the archive mechanics themselves are
# already covered by the backup/restore round-trip tests above (#140/#374).
BKC="$SANDBOX/ctrl908"
mkdir -p "$BKC/staged" "$BKC/results" "$BKC/audit"
cat >"$BKC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SELF_LOG:-/dev/null}"
printf '%s\n' "${PITHEAD_BACKUP_PASSPHRASE:-<empty>}" >>"${PASS_LOG:-/dev/null}"
if [ "${BACKUP_FAIL:-0}" = "1" ]; then
    echo "boom: disk full" >&2
    exit 1
fi
mkdir -p "$(dirname "$FAKE_ARCHIVE")"
printf 'FAKE-ENCRYPTED-BYTES' >"$FAKE_ARCHIVE"
echo "[pithead] Backup written to: $FAKE_ARCHIVE"
exit 0
EOF
chmod +x "$BKC/self"
export PITHEAD_SELF="$BKC/self"
export SELF_LOG="$BKC/self.log"
export PASS_LOG="$BKC/pass.log"
export CONTROL_BACKUP_KIT_TTL_S=0 # redact immediately — this block only checks the applied shape

bid1="a0a0a0a0-0000-4000-8000-000000000001"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000000.tar.gz.enc"
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid1" >"$BKC/req1.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req1.json" "$BKC" >/dev/null 2>&1
assert_eq "backup runs the fixed 'backup -y' verb (never --no-encrypt)" "$(cat "$SELF_LOG")" "backup -y"
assert_eq "backup result is applied" "$(jq -r .status "$BKC/results/$bid1.json")" "applied"
pass1="$(cat "$PASS_LOG")"
{ [ -n "$pass1" ] && [ "$pass1" != "<empty>" ]; } &&
    ok "the child gets a non-empty passphrase (via env, never argv)" ||
    bad "the child gets a non-empty passphrase (via env, never argv)" "got: $pass1"
assert_eq "the passphrase never rides argv (the child's own argv log shows only 'backup -y')" \
    "$(cat "$SELF_LOG")" "backup -y"
assert_eq "the kit names the archive by basename" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"
assert_contains "the kit lists what the archive holds" \
    "$(jq -r '.contents | join(",")' "$BKC/results/$bid1.json")" "config.json"
[ -f "$BKC/results/$bid1.tar.gz.enc" ] &&
    ok "the archive lands under results/ (the container's existing ro mount — no new bind mount)" ||
    bad "the archive lands under results/ (the container's existing ro mount — no new bind mount)" "missing"
assert_eq "the archive's content is preserved by the move into results/" \
    "$(cat "$BKC/results/$bid1.tar.gz.enc")" "FAKE-ENCRYPTED-BYTES"
assert_contains "backup is audited applied" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"applied"'
# TTL=0 above means the redaction ran synchronously before control_process_request returned.
assert_eq "the passphrase is gone once the TTL elapses (redacted in place, whether read or not)" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid1.json")" "null"
assert_contains "the redaction note explains the passphrase is gone" \
    "$(jq -r .note "$BKC/results/$bid1.json")" "no longer available"
assert_eq "the archive name survives the redaction (ciphertext stays downloadable)" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"

echo "== control channel: backup verb — the kit is visible before its TTL, gone after (#908) =="
# A wider TTL, checked mid-flight: the passphrase is readable for a real window (long enough for
# an ordinary dashboard poll), then null either way — "consumed or not, it's gone".
rm -f "$BKC/staged/.backup-stamp" # bid1 above already claimed the 10-minute throttle
bid2="a0a0a0a0-0000-4000-8000-000000000002"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000001.tar.gz.enc"
export CONTROL_BACKUP_KIT_TTL_S=3
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid2" >"$BKC/req2.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req2.json" "$BKC" >/dev/null 2>&1 &
bg_pid=$!
sleep 0.5 # well inside the 3s TTL — the stubbed child + write are effectively instant
mid_pass="$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)"
{ [ -n "$mid_pass" ] && [ "$mid_pass" != "null" ]; } &&
    ok "the passphrase IS present while inside the TTL window" ||
    bad "the passphrase IS present while inside the TTL window" "got: $mid_pass"
assert_eq "the kit's passphrase is exactly what the child received (same secret both ends)" \
    "$mid_pass" "$(cat "$PASS_LOG")"
wait "$bg_pid"
assert_eq "the passphrase is null once the TTL elapses" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)" "null"
[ -f "$BKC/results/$bid2.tar.gz.enc" ] &&
    ok "the archive file itself is untouched by the redaction" ||
    bad "the archive file itself is untouched by the redaction" "missing"
unset bg_pid mid_pass

echo "== control channel: backup verb — failure and throttle (#908) =="
rm -f "$BKC/staged/.backup-stamp" # bid2 above already claimed the 10-minute throttle
bid3="a0a0a0a0-0000-4000-8000-000000000003"
export CONTROL_BACKUP_KIT_TTL_S=0
export BACKUP_FAIL=1
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid3" >"$BKC/req3.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req3.json" "$BKC" >/dev/null 2>&1
assert_eq "a failed child backup is reported failed, not applied" \
    "$(jq -r .status "$BKC/results/$bid3.json")" "failed"
assert_contains "the failure carries the child's own error tail" \
    "$(jq -r .error "$BKC/results/$bid3.json")" "boom: disk full"
assert_eq "a failed backup's result never carries a passphrase field" \
    "$(jq -r 'has("passphrase")' "$BKC/results/$bid3.json")" "false"
assert_contains "the failed attempt is audited" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"failed"'
unset BACKUP_FAIL

# Throttle (mirrors #59's upgrade throttle): bid1 above already claimed the 10-minute window —
# a fourth attempt right after is refused before the passphrase is even generated.
bid4="a0a0a0a0-0000-4000-8000-000000000004"
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid4" >"$BKC/req4.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req4.json" "$BKC" >/dev/null 2>&1
assert_contains "an immediate second backup attempt is throttled" \
    "$(jq -r .error "$BKC/results/$bid4.json")" "less than 10 minutes"
assert_eq "a throttled attempt never runs the child" "$(cat "$SELF_LOG")" ""

# The request schema itself cannot carry a passphrase — control_process_request's fixed key
# allowlist (id/action/config/actor/version/worker/changes/confirm) rejects any other field
# before the action even dispatches, so the container has no field to smuggle one through.
bid5="a0a0a0a0-0000-4000-8000-000000000005"
printf '{"id":"%s","action":"backup","actor":"admin","passphrase":"leaked"}\n' "$bid5" >"$BKC/req5.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req5.json" "$BKC" >/dev/null 2>&1
assert_contains "a request carrying a passphrase field is refused outright (unexpected keys)" \
    "$(jq -r .error "$BKC/results/$bid5.json")" "unexpected keys"

# Backstop: a kit whose runner was KILLED mid-TTL keeps a plaintext passphrase on /data. The next
# drain's control_redact_stale_kits must null it once past the TTL, while leaving a still-in-window
# kit and a non-kit result alone.
export CONTROL_BACKUP_KIT_TTL_S=20 # cutoff = max(2x, 120) = 120s
old_ts=$(($(date +%s) - 3600))     # an hour stale
now_ts=$(date +%s)                 # fresh
jq -n --argjson t "$old_ts" '{status:"applied",passphrase:"STRANDED-SECRET",archive:"a.enc",ts:$t}' >"$BKC/results/stale.json"
jq -n --argjson t "$now_ts" '{status:"applied",passphrase:"LIVE-SECRET",archive:"b.enc",ts:$t}' >"$BKC/results/fresh.json"
jq -n --argjson t "$old_ts" '{status:"applied",change_id:"c",ts:$t}' >"$BKC/results/other.json" # not a kit
run_sourced "$SANDBOX" control_redact_stale_kits "$BKC/results" >/dev/null 2>&1
assert_eq "a stranded kit passphrase (runner died mid-TTL) is redacted on the next drain" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/stale.json")" "null"
assert_eq "a kit still inside its window keeps its passphrase" \
    "$(jq -r '.passphrase' "$BKC/results/fresh.json")" "LIVE-SECRET"
assert_eq "a non-kit result is left untouched" \
    "$(jq -r '.change_id' "$BKC/results/other.json")" "c"
unset PITHEAD_SELF SELF_LOG PASS_LOG FAKE_ARCHIVE CONTROL_BACKUP_KIT_TTL_S bid1 bid2 bid3 bid4 bid5 pass1 old_ts now_ts

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

# shellcheck source=tests/stack/test-wizard-setup.sh
source "$HERE/test-wizard-setup.sh"

echo "== unit: provision_control_runner only removes units this checkout owns (#33) =="
# The pithead-control.{path,service} names are box-global, but a release bench holds several
# checkouts at once (live stack + e2e harness + bundle-smoke tmp dirs). A checkout with control
# disabled used to remove whatever units were installed — including the LIVE stack's runner,
# stranding its dashboard control requests (config editor stuck at "Previewing…"). The removal
# branch keys on the service unit's ExecStart: foreign owner → leave alone; own units → remove;
# a dangling path unit with no service file → still reaped.
PCR="$SANDBOX/pcr"
mkdir -p "$PCR/units" "$PCR/bin"
# uname stub: the OS gate reads `uname -s` at source time; report Linux so the branch runs on dev
# Macs too. systemctl stub satisfies the command -v gate.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR/bin/systemctl"
chmod +x "$PCR/bin/uname" "$PCR/bin/systemctl"

pcr_run() { # <owner-dir|-> <run-dir> — seed units owned by owner-dir ('-' = no service file), run the removal branch from run-dir, echo sudo calls
    rm -f "$PCR/units/pithead-control.service" "$PCR/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCR/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=/x/requests/*.json\n' >"$PCR/units/pithead-control.path"
    (
        cd "$2" || exit
        PATH="$PCR/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        sudo() { echo "sudo:$*"; } # record instead of executing; the disable call's output is redirected in-function
        PITHEAD_UNIT_DIR="$PCR/units" DASHBOARD_CONTROL_ENABLED=false provision_control_runner
    )
}

assert_eq "foreign owner -> units left alone (no sudo rm)" "$(pcr_run /srv/code/other-checkout "$PCR")" ""
assert_contains "own units -> removed" "$(pcr_run "$PCR" "$PCR")" \
    "sudo:rm -f $PCR/units/pithead-control.path $PCR/units/pithead-control.service"
assert_contains "dangling path unit (no service file) -> still reaped" "$(pcr_run - "$PCR")" "sudo:rm -f"
# Versioned install dirs carry dots (pithead-v1.9.3). Ownership must compare the ExecStart path
# as an exact string, never a regex: with the dots read as "any char", a sibling whose path
# differs only at those positions would falsely match as our own — and get removed.
mkdir -p "$PCR/v1.9.3" "$PCR/v1x9y3"
assert_eq "foreign owner differing only at regex-dot positions -> left alone" \
    "$(pcr_run "$PCR/v1x9y3" "$PCR/v1.9.3")" ""
# One checkout, two spellings: production units carry the versioned dir in ExecStart, and an
# operator's disable apply runs through the `current` symlink. Ownership compares physical
# paths, so the unit is recognized as our own and removed — a literal $PWD compare would call
# it foreign and the disable would never converge.
mkdir -p "$PCR/versions/pithead-v1.9.3"
ln -s "$PCR/versions/pithead-v1.9.3" "$PCR/current"
assert_contains "own unit under its versioned spelling, run via the current symlink -> removed" \
    "$(pcr_run "$PCR/versions/pithead-v1.9.3" "$PCR/current")" "sudo:rm -f"
unset PCR pcr_run

echo "== unit: provision_control_runner refuses to overwrite a foreign install's units (#1190) =="
# The removal branch above got its ownership check when a disable-apply deleted the live stack's
# units; the INSTALL branch had none — any sibling checkout's apply/up with control enabled
# overwrote the box-global units and silently repointed dashboard control at itself (the
# production-stranding mechanism, this time via install instead of a failed upgrade). The guard:
# foreign owner that still exists on disk → refuse and name it; owner directory gone → adopt
# (that is how a new version takes over from a removed one); own unit → converge; unparseable
# ExecStart → leave alone, fail safe; PITHEAD_STEAL_CONTROL_UNITS=1 → deliberate takeover.
#
# Mutation proof (each ran red against its assertion with the guard intact elsewhere):
#   - drop the `[ -d "$install_owner" ]` conjunct  -> "owner directory gone -> adopted" goes red
#   - flip the `!=` ownership compare to `=`       -> "foreign existing owner -> refused" goes red
#   - drop the PITHEAD_STEAL_CONTROL_UNITS conjunct -> "steal escape -> overwritten" goes red
#   - drop the `steal` argument conjunct           -> "upgrade repoint (steal arg)" goes red
PCI="$SANDBOX/pci"
mkdir -p "$PCI/units" "$PCI/bin" "$PCI/mine" "$PCI/other"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCI/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCI/bin/systemctl"
chmod +x "$PCI/bin/uname" "$PCI/bin/systemctl"

pci_run() { # <owner-dir|-|garbage> <run-dir> [steal-env] [fn-arg] — seed a service unit, run the INSTALL branch, echo warns + recorded sudo calls
    rm -f "$PCI/units/pithead-control.service" "$PCI/units/pithead-control.path" "$PCI/calls"
    case "$1" in
    -) ;; # no pre-existing units
    garbage) printf '[Service]\nExecStart=/usr/bin/env not-ours\n' >"$PCI/units/pithead-control.service" ;;
    *) printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCI/units/pithead-control.service" ;;
    esac
    (
        cd "$2" || exit
        PATH="$PCI/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        # Record instead of executing — into a side file, because the install branch redirects
        # `sudo tee`'s stdout to /dev/null, so an echoing stub would be invisible there.
        sudo() { echo "sudo:$*" >>"$PCI/calls"; }
        PITHEAD_UNIT_DIR="$PCI/units" DASHBOARD_CONTROL_ENABLED=true \
            CONTROL_DIR="$2/data/control" PITHEAD_STEAL_CONTROL_UNITS="${3:-0}" \
            provision_control_runner ${4:+"$4"} 2>&1
        cat "$PCI/calls" 2>/dev/null
    )
}

out="$(pci_run "$PCI/other" "$PCI/mine")"
assert_contains "install: foreign existing owner -> refused, names the owner" "$out" "belong to the install at $PCI/other"
assert_not_contains "install: foreign existing owner -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: foreign existing owner + steal escape -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 1)" "sudo:tee $PCI/units/pithead-control.service"
# The upgrade callsite's spelling: after a successful upgrade the OLD versioned dir still exists
# (it is the rollback), so the converge MUST take the units over — via the `steal` argument, not
# the operator env var. Without it every one-click upgrade would refuse and strand the channel.
assert_contains "install: foreign existing owner + upgrade repoint (steal arg) -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 0 steal)" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: foreign owner whose directory is gone -> adopted" \
    "$(pci_run "$PCI/long-gone" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
out="$(pci_run garbage "$PCI/mine")"
assert_contains "install: unparseable ExecStart -> left alone, says so" "$out" "not one this tool wrote"
assert_not_contains "install: unparseable ExecStart -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: own drifted unit -> converged (rewritten in place)" \
    "$(pci_run "$PCI/mine" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: no units at all -> fresh install unaffected by the guard" \
    "$(pci_run - "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
unset PCI pci_run out

echo "== unit: the installer gate outlasts a slow device probe =="
# An empty FIRST inventory put a reinstall boot into setup mode (KVM keep leg): the gate runs
# ~18s into boot and races udev settling the target's partitions. It now retries before giving
# up — a probe that answers on the third try still opens the installer.
IGSB=$(mktemp -d)
cat >"$IGSB/fake-install" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = "--list" ] || exit 0
N=$(cat "${IG_COUNT:?}" 2>/dev/null || echo 0)
echo $((N + 1)) >"$IG_COUNT"
[ "$N" -ge 2 ] && printf 'vda\t30G\tFake\tSN\tpithead-with-data\n'
exit 0
FAKE
chmod +x "$IGSB/fake-install"
igout=$(
    cd "$IGSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    boot_is_removable() { return 0; }
    udevadm() { :; }
    sleep() { :; } # the retry cadence is not what is under test
    echo 0 >"$IGSB/count"
    PITHEAD_INSTALL_BIN="$IGSB/fake-install" IG_COUNT="$IGSB/count" installer_mode_available && echo GATE-OPEN
)
assert_contains "a third-try inventory still opens the installer" "$igout" "GATE-OPEN"
rm -rf "$IGSB"
unset IGSB igout

echo "== unit: headless setup resolves the appliance's browsable name, never the bare hostname =="
# 'interactive' with no terminal is an EOF that silently picked $(hostname) — the appliance's
# dashboard then served a name no LAN client resolves (a bench machine showed a BLANK page:
# pithead.local hit Caddy's empty default vhost). No tty -> the non-interactive rules decide.
RDH=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    PITHEAD_APPLIANCE=1 DASHBOARD_HOST="" resolve_dashboard_host interactive </dev/null
    printf '%s' "$HOST_IP"
)
assert_eq "no tty + appliance -> <hostname>.local" "$RDH" "$(hostname).local"
unset RDH

echo "== unit: ssh access is derived — key-only, /run-resident, absent when disabled (#786) =="
SSHSB="$SANDBOX/sshsb"
mkdir -p "$SSHSB/bin" "$SSHSB/units" "$SSHSB/run"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SSHSB/bin/systemctl"
chmod +x "$SSHSB/bin/systemctl"
ssh_run() { # <config-json>
    printf '%s' "$1" >"$SSHSB/config.json"
    (
        cd "$SSHSB" || exit
        PATH="$SSHSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        sudo() { "$@"; }
        PITHEAD_APPLIANCE=1 PITHEAD_UNIT_DIR="$SSHSB/units" PITHEAD_SSH_RUN_DIR="$SSHSB/run/ssh" \
            CONFIG_FILE="$SSHSB/config.json" provision_ssh_access
    )
}
ssh_run '{"ssh":{"enabled":true,"authorized_key":"ssh-ed25519 AAAATEST key@test"}}'
grep -q "ssh-ed25519 AAAATEST" "$SSHSB/run/ssh/authorized_keys" 2>/dev/null &&
    ok "enabled -> the key lands in the runtime dir" || bad "enabled -> the key lands in the runtime dir" "missing"
grep -q "PasswordAuthentication=no" "$SSHSB/units/ssh.service.d/pithead.conf" 2>/dev/null &&
    ok "password auth is forced OFF in the unit override" || bad "password auth is forced OFF in the unit override" "missing"
ssh_run '{"ssh":{"enabled":false}}'
[ ! -e "$SSHSB/run/ssh" ] && [ ! -e "$SSHSB/units/ssh.service.d" ] &&
    ok "disabled -> key and override are REMOVED" || bad "disabled -> key and override are REMOVED" "residue"
unset SSHSB ssh_run

echo "== unit: ssh.enabled without a public key is refused at validation =="
VSB="$SANDBOX/vsb"
mkdir -p "$VSB"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "ssh":{"enabled":true} }' "$WALLET" >"$VSB/config.json"
vout=$(
    cd "$VSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    CONFIG_FILE="$VSB/config.json" parse_and_validate_config 2>&1
)
assert_contains "refusal names the missing key" "$vout" "ssh.authorized_key"
unset VSB vout

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

echo "== unit: on the appliance, control-runner units render into /run — root is read-only (#791) =="
# /etc/systemd/system cannot take a write on the appliance (RO root by design): apply died at
# 'tee: Read-only file system' on hardware, killing the ONLY post-setup management path. /run is
# a first-class unit dir, writable, and cleared every boot — fine, because these units are
# derived and the boot path re-renders them every boot. Enablement must be --runtime for the
# same reason (no symlinks under /etc either).
PCR791="$SANDBOX/pcr791"
mkdir -p "$PCR791/bin"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR791/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR791/bin/systemctl"
chmod +x "$PCR791/bin/uname" "$PCR791/bin/systemctl"
pcr791_run() { # <PITHEAD_APPLIANCE value> — run the install branch, echo recorded sudo calls
    (
        cd "$PCR791" || exit
        PATH="$PCR791/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        # a file, not a stream: the function /dev/null's both stdout AND stderr on some calls
        sudo() { echo "sudo:$*" >>"$PCR791/calls"; }
        PITHEAD_APPLIANCE="$1" CONTROL_DIR="$PCR791/control" DASHBOARD_CONTROL_ENABLED=true provision_control_runner
    )
}
: >"$PCR791/calls"
pcr791_run 1 >/dev/null 2>&1
appl_out=$(cat "$PCR791/calls")
assert_contains "appliance -> units written under /run/systemd/system" "$appl_out" "sudo:tee /run/systemd/system/pithead-control.service"
assert_contains "appliance -> enablement is --runtime" "$appl_out" "systemctl enable --runtime --now"
: >"$PCR791/calls"
PITHEAD_UNIT_DIR="$PCR791/units" pcr791_run 0 >/dev/null 2>&1
diy_out=$(cat "$PCR791/calls")
case "$diy_out" in
*"--runtime"*) bad "DIY keeps persistent /etc enablement (no --runtime)" "$diy_out" ;;
*) ok "DIY keeps persistent /etc enablement (no --runtime)" ;;
esac
unset PCR791 pcr791_run appl_out diy_out

echo "== unit: the dashboard certificate exists whenever the Caddyfile names it =="
# A machine that SKIPS the wizard (pre-seeded config, or a reinstall whose preserved /data
# already held config.json) still gets a certificate: the Caddyfile named a file only the wizard
# used to create, so Caddy answered :443 with no usable cert and the dashboard failed the TLS
# handshake outright — a bench machine looked hung while serving a broken listener.
TLSSB=$(mktemp -d)
export PITHEAD_TLS_DIR="$TLSSB/tls"
fp1=$(run_sourced "$SANDBOX" appliance_mint_cert 2>/dev/null)
[ -s "$TLSSB/tls/wizard.crt" ] && ok "mints a certificate on demand" || bad "mints a certificate on demand" "no crt"
[ -s "$TLSSB/tls/wizard.key" ] && ok "mints the matching key" || bad "mints the matching key" "no key"
assert_contains "prints a SHA-256 fingerprint" "$fp1" ":"
# Idempotent: the operator has already trusted this one, so a second call must NOT replace it.
fp2=$(run_sourced "$SANDBOX" appliance_mint_cert 2>/dev/null)
assert_eq "an existing certificate is reused, never replaced" "$fp2" "$fp1"
unset PITHEAD_TLS_DIR
rm -rf "$TLSSB"
unset TLSSB fp1 fp2

echo "== unit: the certificate SAN list and Caddy's site list agree, for a given identity (#1132) =="
# Three named disagreements this closes, all one root cause (two independent copies of the same
# expansion): (1) the cert always used `hostname` while site_hosts used dashboard.host when
# pinned; (2) pinning dashboard.host collapsed the site list to one host while the cert kept every
# address; (3) ".local" was unconditional in the cert, conditional in the site list. One shared
# builder (appliance_site_names) now feeds both consumers, so a given identity cannot produce two
# different name lists any more.
# MUTATION PROOF: hardcode site_hosts back to "$HOST_IP" in generate_caddyfile, or the old
# unconditional alt= string back into appliance_mint_cert, and every scenario below goes red.
NL=$(mktemp -d)
export PITHEAD_TLS_DIR="$NL/tls"
nl_render() { # sets $NL/Caddyfile and mints $NL/tls/wizard.crt for the given identity; prints the
    # canonical name list both consumers should agree on.
    (
        cd "$NL" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$NL_IPS"; else printf '%s' "$NL_HOSTNAME"; fi; }
        # Real (persistent) assignments, not command-prefix ones — appliance_site_names below
        # must see the SAME HOST_IP/DASHBOARD_HOST generate_caddyfile just rendered with, and a
        # prefix assignment scopes to one command only.
        # shellcheck disable=SC2034  # read by the sourced generate_caddyfile, unseen here
        DASHBOARD_SECURE=true
        # shellcheck disable=SC2034
        DASHBOARD_AUTH_HASH_B64=""
        # shellcheck disable=SC2034  # read by generate_caddyfile AND appliance_site_names, unseen here
        HOST_IP="$NL_HOST_IP"
        # shellcheck disable=SC2034
        DASHBOARD_HOST="${NL_DASHBOARD_HOST:-}"
        generate_caddyfile >/dev/null 2>&1
        appliance_site_names
    )
}
nl_assert_agreement() { # <scenario-label> — every name appliance_site_names() prints must be BOTH
    # served (in the Caddyfile) and certified (in the minted cert's SAN list).
    local names n cf cert bad_name=""
    names=$(nl_render)
    cf=$(cat "$NL/Caddyfile" 2>/dev/null)
    cert=$(openssl x509 -in "$NL/tls/wizard.crt" -noout -ext subjectAltName 2>/dev/null)
    for n in $names; do
        case "$cf" in
        *"https://$n,"* | *"https://$n "*) ;;
        *) bad_name="$n (not served)" ;;
        esac
        case ",$cert," in
        *"DNS:$n"* | *"IP:$n"* | *"IP Address:$n"*) ;;
        *) bad_name="${bad_name:+$bad_name, }$n (not certified)" ;;
        esac
    done
    if [ -n "$bad_name" ]; then
        bad "$1: every name is both served and certified" "$bad_name"
    else
        ok "$1: every name is both served and certified"
    fi
}

# Disagreement #3: auto identity, HOST_IP already the .local form (resolve_dashboard_host's own
# answer for an appliance on "auto") — both consumers must agree the .local name is IN.
NL_HOSTNAME="rig1" NL_IPS="192.168.1.20" NL_HOST_IP="rig1.local" NL_DASHBOARD_HOST=""
nl_assert_agreement "auto identity"

# Disagreements #1 and #2: dashboard.host pinned to a name that is NOT this machine's hostname.
NL_HOSTNAME="rig1" NL_IPS="192.168.1.20" NL_HOST_IP="panel.example" NL_DASHBOARD_HOST="panel.example"
nl_assert_agreement "pinned dashboard.host"
# And the negative proof that makes #1/#2 concrete: the OLD cert always carried the machine's
# other names (hostname, .local, its IPs) regardless of the pin — assert neither consumer does
# that any more, not just that the pinned name is present in both.
pcf=$(cat "$NL/Caddyfile")
pcert=$(openssl x509 -in "$NL/tls/wizard.crt" -noout -ext subjectAltName 2>/dev/null)
case "$pcf$pcert" in
*rig1*) bad "pinned dashboard.host: neither consumer names the machine's OTHER identity" "still present: $pcf | $pcert" ;;
*) ok "pinned dashboard.host: neither consumer names the machine's OTHER identity" ;;
esac

unset -f nl_render nl_assert_agreement
rm -rf "$NL"
unset PITHEAD_TLS_DIR NL NL_HOSTNAME NL_IPS NL_HOST_IP NL_DASHBOARD_HOST pcf pcert

echo "== unit: appliance_site_names stays engine-free — proxy_net's gateway is NOT excluded there (#reboot-leg-fix) =="
# #1204 already excluded mining_net's gateway here (a known config literal, \${NETWORK_PREFIX}.1).
# proxy_net's is NOT excluded here on purpose, even though it needs the SAME kind of exclusion —
# see appliance_site_names' own header. This function runs from BOTH the mint (render, always
# BEFORE \`up\` creates either bridge) and, via check_appliance_cert, doctor (always AFTER \`up\`,
# inside the boot health-gate's retry loop) — an engine call here would make its answer depend on
# whether docker/podman happened to be reachable at the exact moment it ran, and #1065 reboots the
# box on a doctor FAIL. The live exclusion belongs ONLY to check_appliance_cert, the one caller who
# can turn "engine didn't answer" into a WARN instead of a guess (next block).
AST="$SANDBOX/appliance-site-test"
mkdir -p "$AST/bin"
ast_names() {
    (
        cd "$AST" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '192.168.1.50 172.28.0.1 172.19.0.1'; else printf 'coordinator'; fi; }
        # shellcheck disable=SC2034
        HOST_IP=""
        # shellcheck disable=SC2034
        NETWORK_PREFIX="172.28.0"
        # shellcheck disable=SC2034
        DASHBOARD_EXPOSE_PUBLIC_IP="false"
        # shellcheck disable=SC2034
        DASHBOARD_HOST=""
        appliance_site_names
    )
}
ast_out="$(ast_names)"
assert_not_contains "mining_net's gateway (the known literal) stays excluded here" "$ast_out" "172.28.0.1"
assert_contains "proxy_net's gateway is NOT excluded here — that exclusion moved to doctor" "$ast_out" "172.19.0.1"
assert_contains "the real LAN address is still there" "$ast_out" "192.168.1.50"
unset -f ast_names
rm -rf "$AST"
unset AST ast_out

echo "== unit: check_appliance_cert excludes proxy_net's gateway live, engine reachable (#reboot-leg-fix) =="
# pithead-boot's real sequence: render (which mints the certificate, appliance_mint_cert) runs
# BEFORE \`up\` — neither compose bridge exists yet, so the minted certificate never covers either
# gateway. doctor's health-gate loop calls check_appliance_cert() AFTER \`up\`, when a live
# hostname -I reports both gateways. Before this fix only mining_net's (config-known prefix) was
# excluded from that later, live re-derivation; proxy_net's auto-assigned gateway (#345) was a name
# doctor then considered SERVED that the pre-\`up\`-minted certificate never covered — dr_fail on a
# perfectly healthy, still-syncing box. That FAIL is exactly the "commit gate rejected a healthy
# still-syncing stack (over-tightened)" battery assertion this fixes, and independently, exactly
# what stranded the OS-update 'updated' verdict behind a boot health gate that never passed (#1051
# — a second investigation on this same #1204 regression, folded in here; see also #1210/#1218
# below).
#
# MUTATION PROOF: delete the proxy_net leg from check_appliance_cert's engine loop and "does not
# FAIL" below goes red.
CAB="$SANDBOX/certboot"
mkdir -p "$CAB/tls" "$CAB/bin"
cat >"$CAB/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = network ] && [ "$2" = inspect ] || exit 1
case "$3" in
mining_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.28.0.0/24","Gateway":"172.28.0.1"}]}}]' ;;
proxy_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.19.0.0/16","Gateway":"172.19.0.1"}]}}]' ;;
*) exit 1 ;;
esac
EOF
chmod +x "$CAB/bin/docker"
printf '{"dashboard":{"host":"auto"}}' >"$CAB/config.json"
cab_run() { # <hostname -I answer> <mint|doctor>
    (
        cd "$CAB" || exit 1
        PATH="$CAB/bin:$PATH"
        export PITHEAD_ENGINE=docker
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$CAB/tls"; }
        env_get() {
            case "$1" in
            HOST_IP) printf 'rig1.local' ;;
            *) printf '' ;;
            esac
        }
        HOST_IP="rig1.local"
        CAB_IPS="$1"
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$CAB_IPS"; else printf 'rig1'; fi; }
        if [ "$2" = mint ]; then appliance_mint_cert >/dev/null; else check_appliance_cert 2>&1; fi
    )
}
# The pre-\`up\` render/mint — only the LAN address, neither bridge exists yet.
cab_run "192.168.1.20" mint >/dev/null
# doctor, after \`up\` — both bridges now show up in hostname -I, and the engine can vouch for both.
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "doctor after \`up\` still says the cert covers every name" "$out" "covers every name"
assert_not_contains "doctor after \`up\` does not FAIL a healthy, pre-\`up\`-minted cert" "$out" "FAIL"
assert_not_contains "the engine answered, so no WARN is owed either" "$out" "WARN"

# A GENUINE mismatch must still FAIL — this fix must not neuter #1141's own coverage check. An
# address that is neither the base, localhost, nor a confirmed bridge gateway is a real gap.
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1 10.55.55.55" doctor)
assert_contains "a genuinely uncovered LAN address still FAILs (#1141 not neutered)" "$out" "FAIL"
assert_contains "the FAIL names the real gap" "$out" "10.55.55.55"

echo "== unit: check_appliance_cert WARNs (never FAILs) when the engine can't be asked — the security-review blocker =="
# Demonstrated live by the reviewer with a stubbed daemon-unreachable docker: bridge INTERFACES
# outlive an engine blip, so hostname -I keeps reporting both gateways whether or not the engine is
# there to explain them. Reading "the engine didn't answer" as "nothing to exclude" would FAIL a
# perfectly healthy box on a transient engine hiccup — worse than the pre-fix bug, because #1065
# then reboots it, and the failure now looks intermittent instead of the deterministic, explicable
# bug #1204 shipped. #1204's own philosophy for the analogous unreadable-certificate-file case: a
# TOOLING problem WARNs, a certificate found with a real problem FAILs.
#
# MUTATION PROOF: replace the "if \$engine_ok != 1" branch with "if false" (verified by hand — the
# real repro this test encodes) and this reproduces the exact regression: FAIL on a healthy box
# during an engine hiccup.
cat >"$CAB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
exit 1
EOF
chmod +x "$CAB/bin/docker"
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "engine unreachable post-\`up\` -> WARN, naming the tooling gap" "$out" "WARN"
assert_not_contains "engine unreachable post-\`up\` -> never FAILs a healthy box" "$out" "FAIL"

# The base name is NOT excused by an unreachable engine — it needs no live state to derive, so an
# uncovered base name is always a real, actionable problem.
printf 'not a certificate' >"$CAB/tls/wizard.crt"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$CAB/tls/wizard.key" \
    -out "$CAB/tls/wizard.crt" -subj "/CN=other" -addext "subjectAltName=DNS:somethingelse" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "an uncovered BASE name still FAILs even with the engine unreachable" "$out" "FAIL"
assert_contains "the FAIL names the base" "$out" "rig1.local"

# Nothing extra to explain (dashboard.host pinned collapses the auto-expansion to just the base,
# per appliance_site_names' own "an explicit pin stays a single name on purpose" rule) -> an
# unreachable engine is never even consulted, so no spurious WARN either. check_appliance_cert
# re-derives DASHBOARD_HOST from $CONFIG_FILE itself (never trusts a caller-set variable — see its
# own comment), so the pin has to be staged there, not just passed as a local override.
printf '{"dashboard":{"host":"rig1.local"}}' >"$CAB/config.json"
cab_run_pinned() {
    (
        cd "$CAB" || exit 1
        PATH="$CAB/bin:$PATH"
        export PITHEAD_ENGINE=docker
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$CAB/tls"; }
        env_get() {
            case "$1" in
            HOST_IP) printf 'rig1.local' ;;
            *) printf '' ;;
            esac
        }
        HOST_IP="rig1.local"
        hostname() { if [ "${1:-}" = "-I" ]; then printf '192.168.1.20 172.28.0.1 172.19.0.1'; else printf 'rig1'; fi; }
        check_appliance_cert 2>&1
    )
}
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$CAB/tls/wizard.key" \
    -out "$CAB/tls/wizard.crt" -subj "/CN=rig1.local" -addext "subjectAltName=DNS:rig1.local" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
out=$(cab_run_pinned)
assert_not_contains "a pinned dashboard.host is verified — no engine dependency to bypass into a WARN" "$out" "WARN"
assert_not_contains "a pinned dashboard.host that IS covered -> no FAIL" "$out" "FAIL"
unset -f cab_run cab_run_pinned
rm -rf "$CAB"
unset CAB out

echo "== unit: the certificate re-mints when the served name list changes, not otherwise (#1132) =="
# Compare, don't date-guess: the minted SAN list is derived from the certificate itself (openssl)
# and set-compared against the machine's current name list. An operator who has pinned this
# fingerprint loses that trust on every unnecessary replacement, so a re-mint must be conservative.
# MUTATION PROOF: drop the comparison (always re-mint) -> "an unchanged list does not re-mint"
# goes red. Drop the re-mint branch (never re-mint) -> "a changed list re-mints" goes red.
RM=$(mktemp -d)
export PITHEAD_TLS_DIR="$RM/tls"
RM_IPS="192.168.1.20"
rm_run() {
    (
        cd "$RM" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$RM_IPS"; else printf 'rig1'; fi; }
        appliance_mint_cert
    )
}
rm_fp1=$(rm_run 2>/dev/null)
assert_contains "mints a certificate" "$rm_fp1" ":"
rm_fp2=$(rm_run 2>/dev/null)
assert_eq "an unchanged name list does not re-mint" "$rm_fp2" "$rm_fp1"
RM_IPS="10.0.0.99" # the DHCP lease moved
rm_out=$(rm_run 2>&1)
assert_contains "a changed name list logs a re-mint" "$rm_out" "Re-minting the dashboard certificate"
rm_fp3=$(rm_run 2>/dev/null)
case "$rm_fp3" in
"$rm_fp1") bad "a changed name list re-mints" "fingerprint unchanged after the lease moved: $rm_fp3" ;;
*) ok "a changed name list re-mints" ;;
esac
rm_fp4=$(rm_run 2>/dev/null)
assert_eq "the new certificate is then stable across repeat renders" "$rm_fp4" "$rm_fp3"
unset -f rm_run
rm -rf "$RM"
unset PITHEAD_TLS_DIR RM RM_IPS rm_fp1 rm_fp2 rm_fp3 rm_fp4 rm_out

echo "== unit: stage_wizard_spool re-arms a wiped spool, so a retry keeps its TLS (#1063) =="
# The accept path removes the whole spool before provisioning. Staging used to run ONCE before the
# loop, so a provisioning failure re-entered it with the certificate, the reference schema and the
# rig pre-fill gone — and wizard.py gates TLS on the cert FILE existing, so the retry served the
# setup page (payout address, dashboard password, node secrets) in CLEARTEXT while the console
# still advertised HTTPS and a fingerprint. MUTATION PROOF: stage once before the loop again and
# "a wiped spool is fully re-armed" + "the retry can still serve TLS" go red.
SWS=$(mktemp -d)
export PITHEAD_TLS_DIR="$SWS/tls"
sws_fp=$(run_sourced "$ROOT" stage_wizard_spool "$SWS/spool" 2>/dev/null)
assert_contains "staging prints the certificate fingerprint the console advertises" "$sws_fp" ":"
# data-wiped.json is checked for EXISTENCE only here (present/absent) — its content is always
# "{}" off the appliance (PITHEAD_PRESEED_DIR unset), so that assertion belongs with the
# data_wipe_note/publish_data_wipe_note tests below, not this staging-plumbing check.
for f in wizard.crt wizard.key config.reference.json rig-defaults.json data-wiped.json; do
    assert_eq "staged: $f" "$([ -s "$SWS/spool/$f" ] && echo present || echo absent)" "present"
done
# The accept path's teardown, exactly as it happens, then the retry the outer loop drives.
rm -rf "$SWS/spool"
sws_fp2=$(run_sourced "$ROOT" stage_wizard_spool "$SWS/spool" 2>/dev/null)
sws_missing=""
for f in wizard.crt wizard.key config.reference.json rig-defaults.json data-wiped.json; do
    [ -s "$SWS/spool/$f" ] || sws_missing="$sws_missing $f"
done
assert_eq "a wiped spool is fully re-armed" "${sws_missing:-none}" "none"
assert_eq "the retry can still serve TLS — the cert the container is pointed at exists" \
    "$([ -s "$SWS/spool/wizard.crt" ] && [ -s "$SWS/spool/wizard.key" ] && echo yes || echo no)" "yes"
# One machine, one certificate: the operator already trusted this fingerprint, and a retry that
# minted a fresh one would make the console's printed fingerprint a lie in the other direction.
assert_eq "the fingerprint survives the retry" "$sws_fp2" "$sws_fp"
# And the loop must actually call it per session — staging that only a caller could reach is the
# bug this fixes. MUTATION PROOF: delete the call from the loop and this goes red.
assert_contains "the wizard loop re-stages every session" "$(cat "$STACK")" 'cert_fp=$(stage_wizard_spool "$spool")'
unset PITHEAD_TLS_DIR
rm -rf "$SWS"
unset SWS sws_fp sws_fp2 sws_missing

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

echo "== unit: load_baked_images — the archive digest, not the tag, decides a load (#798) =="
# Every build tags its images identically and the engine's storage lives on /data, which
# survives reinstalls and A/B updates — so "does the tag exist" pins a machine to the first
# image it ever loaded. Both boot owners (pithead-boot and the first-boot wizard) run this ONE
# loader; the digest record beside the store is what makes a keep-reinstall or A/B update
# converge on the shipped containers.
WSB=$(mktemp -d)
mkdir -p "$WSB/images" "$WSB/bin"
printf 'v1-archive' >"$WSB/images/dashboard.tar.gz"
cat >"$WSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
  image) [ -e "${PODMAN_IMAGE_PRESENT:-/nonexistent}" ] ;;   # `image exists <ref>`
  load) exit "${PODMAN_LOAD_RC:-0}" ;;
esac
EOF
chmod +x "$WSB/bin/podman"
export PODMAN_LOG="$WSB/podman.log" PITHEAD_IMAGES_DIR="$WSB/images"
lbl() { PITHEAD_ENGINE=podman PATH="$WSB/bin:$PATH" run_sourced "$WSB" load_baked_images "$@"; }
WREC="$WSB/data/.loaded-dashboard.tar.gz.sha"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && ok "first boot loads the archive" ||
    bad "first boot loads the archive" "no load call"
assert_eq "the digest is recorded beside the store" \
    "$(cat "$WREC" 2>/dev/null)" "$(sha_of "$WSB/images/dashboard.tar.gz")"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && bad "an unchanged archive is not reloaded" "loaded again" ||
    ok "an unchanged archive is not reloaded"
printf 'v2-archive-different' >"$WSB/images/dashboard.tar.gz"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a changed archive reloads — the keep-reinstall and A/B update path" ||
    bad "a changed archive reloads" "no load call"
# The wizard names the image it needs: a matching record must not count when the image is gone
# (the record can outlive the storage it describes).
: >"$PODMAN_LOG"
lbl ghcr.io/x/pithead-dashboard:v0 >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a missing required image forces a load despite a matching record" ||
    bad "a missing required image forces a load" "no load call"
# A failed load leaves the old record: the next boot must retry, not skip.
WV2SHA=$(cat "$WREC")
printf 'v3-archive' >"$WSB/images/dashboard.tar.gz"
export PODMAN_LOAD_RC=1
lbl >/dev/null 2>&1
unset PODMAN_LOAD_RC
assert_eq "a failed load records nothing — the next boot retries" "$(cat "$WREC")" "$WV2SHA"
unset PODMAN_LOG PITHEAD_IMAGES_DIR
unset -f lbl sha_of
rm -rf "$WSB"
unset WSB WREC WV2SHA

echo "== unit: load_baked_images — a store damaged by an interrupted write is rebuilt =="
# An unclean reset mid-load (power cut, or the watchdog firing while slow media is written) leaves
# ZERO-LENGTH `lower` files; containers/storage then readlinks the graph root itself and EVERY
# container start fails. The digest record still matches AND the image still exists, so the two
# guards above both pass and the reload was skipped — which is what made the damage permanent and
# left an appliance unable to install from its own stick. A base layer carries no `lower` file at
# all, so a zero-length one is damage, never a legitimate state.
RSB=$(mktemp -d)
mkdir -p "$RSB/images" "$RSB/bin" "$RSB/data"
printf 'archive' >"$RSB/images/dashboard.tar.gz"
cat >"$RSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 0 ;; # the image ALWAYS exists — that is the point of this test
load) exit 0 ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$RSB/bin/podman"
export PODMAN_LOG="$RSB/podman.log" PITHEAD_IMAGES_DIR="$RSB/images" FAKE_GRAPHROOT="$RSB/store"
rbl() { PITHEAD_ENGINE=podman PATH="$RSB/bin:$PATH" run_sourced "$RSB" load_baked_images; }
# A healthy store: the base layer has NO `lower`, the layer above carries a real chain.
mk_store() {
    rm -rf "$RSB/store"
    mkdir -p "$RSB/store/overlay/base/diff" "$RSB/store/overlay/top/diff"
    printf 'l/BASE' >"$RSB/store/overlay/top/lower"
}
mk_store
printf '%s' "$(sha256sum "$RSB/images/dashboard.tar.gz" | cut -d' ' -f1)" >"$RSB/data/.loaded-dashboard.tar.gz.sha"
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay/top" ] &&
    ok "a healthy store is left alone — no needless re-pull" ||
    bad "a healthy store is left alone" "the store was rebuilt"
grep -q "load -i" "$PODMAN_LOG" &&
    bad "a healthy store still honours the digest record" "reloaded anyway" ||
    ok "a healthy store still honours the digest record"

mk_store
: >"$RSB/store/overlay/base/lower" # zero-length: the corruption itself
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay" ] &&
    bad "a damaged store is torn down" "the store survived" ||
    ok "a damaged store is torn down"
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a damaged store reloads the archive despite a matching record" ||
    bad "a damaged store reloads the archive" "no load call"
unset PODMAN_LOG PITHEAD_IMAGES_DIR FAKE_GRAPHROOT
unset -f rbl mk_store
rm -rf "$RSB"
unset RSB

echo "== unit: load_baked_images — a slow load narrates itself, a fast one stays quiet =="
# `podman load` prints nothing a console sees and runs for MINUTES on USB media (3m47s measured
# on the bench) behind a line promising "a minute or two" — so a working box looked hung, twice.
# A rising elapsed count is what tells slow apart from stuck. The load stays in the FOREGROUND
# and the heartbeat is the background job: polling a backgrounded load with `kill -0` would make
# a fast load pay a full sleep, because a finished-but-unwaited child still answers.
HSB=$(mktemp -d)
mkdir -p "$HSB/images" "$HSB/bin" "$HSB/data"
printf 'archive' >"$HSB/images/dashboard.tar.gz"
cat >"$HSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 1 ;;
load) sleep "${FAKE_LOAD_SECS:-0}" ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$HSB/bin/podman"
export PITHEAD_IMAGES_DIR="$HSB/images" FAKE_GRAPHROOT="" PITHEAD_LOAD_HEARTBEAT_SECS=1
hbl() { PITHEAD_ENGINE=podman PATH="$HSB/bin:$PATH" run_sourced "$HSB" load_baked_images 2>&1; }

export FAKE_LOAD_SECS=3
hout=$(hbl)
assert_contains "a slow load reports it is still working" "$hout" "still loading"
assert_contains "the heartbeat carries elapsed seconds" "$hout" "elapsed"

rm -f "$HSB/data/.loaded-dashboard.tar.gz.sha"
export FAKE_LOAD_SECS=0
hstart=$(date +%s)
hout=$(hbl)
hlen=$(($(date +%s) - hstart))
printf '%s' "$hout" | grep -q "still loading" &&
    bad "a fast load stays quiet" "heartbeat fired anyway" ||
    ok "a fast load stays quiet — no heartbeat for work already done"
[ "$hlen" -lt 3 ] &&
    ok "a fast load does not wait on the heartbeat interval (${hlen}s)" ||
    bad "a fast load returns promptly" "took ${hlen}s"
unset PITHEAD_IMAGES_DIR FAKE_GRAPHROOT PITHEAD_LOAD_HEARTBEAT_SECS FAKE_LOAD_SECS
unset -f hbl
rm -rf "$HSB"
unset HSB hout hstart hlen

echo "== unit: pre-seeding from the installation medium =="
# The ESP is FAT and anyone can write it, so both readers treat its contents as input, not truth.
PSD=$(mktemp -d)
export PITHEAD_PRESEED_DIR="$PSD"

run_sourced "$SANDBOX" preseed_token >/dev/null 2>&1
assert_rc "no token file -> rc 1 (mint one instead)" "$?" "1"

printf 'pit-ABC123\n' >"$PSD/pithead-token.txt"
assert_eq "token read from the medium" "$(run_sourced "$SANDBOX" preseed_token)" "pit-ABC123"

printf 'pit-ABC123; rm -rf /\n' >"$PSD/pithead-token.txt"
assert_eq "token sanitised to its alphabet" "$(run_sourced "$SANDBOX" preseed_token)" "pit-ABC123rm-rf"

printf 'ab\n' >"$PSD/pithead-token.txt"
run_sourced "$SANDBOX" preseed_token >/dev/null 2>&1
assert_rc "implausibly short token refused" "$?" "1"
rm -f "$PSD/pithead-token.txt"

run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "no config file -> rc 2 (nothing pre-seeded)" "$?" "2"

printf '{"monero":{"wallet_address":"nope"},"tari":{"wallet_address":"t"}}' >"$PSD/pithead-config.json"
run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "invalid config -> rc 1, wizard still opens" "$?" "1"
[ -f "$PSD/out.json" ] && bad "rejected config NOT installed" "it was" || ok "rejected config NOT installed"

printf '{"monero":{"wallet_address":"%s"},"tari":{"wallet_address":"'"$VALID_TARI"'"},"p2pool":{"pool":"mini","stratum_password":"auto"}}' \
    "$VALID_PRIMARY" >"$PSD/pithead-config.json"
cp "$PSD/pithead-config.json" "$PSD/original.json"
run_sourced "$SANDBOX" consume_preseed_config "$PSD/out.json" >/dev/null 2>&1
assert_rc "valid config -> rc 0" "$?" "0"
[ -s "$PSD/out.json" ] && ok "valid config installed" || bad "valid config installed" "missing"
# The medium must come back unchanged: validation fills in generated credentials, and writing
# those back would hand every machine in a fleet the first one's secrets.
if cmp -s "$PSD/pithead-config.json" "$PSD/original.json"; then
    ok "the medium is left byte-for-byte unchanged"
else
    bad "the medium is left byte-for-byte unchanged" "it was rewritten"
fi
unset PITHEAD_PRESEED_DIR PSD

echo "== unit: data_wipe_note / publish_data_wipe_note — the wipe note reader + spool carrier (#1121) =="
# pithead-data-reset's own record_wipe format ("<UTC when> <reason>\n", appended to the ESP's
# pithead-data-wiped) is the contract; this only reads it, never guesses it. "recovery"
# discriminates a deliberate factory-reset (the operator asked for it, nothing to warn about)
# from the wedged-/data case, where the wizard's next-move advice differs: restore a backup,
# don't set up as if this were a fresh machine.
DWN=$(mktemp -d)
mkdir -p "$DWN/esp" "$DWN/spool"
export PITHEAD_PRESEED_DIR="$DWN/esp"

run_sourced "$SANDBOX" data_wipe_note >/dev/null 2>&1
assert_rc "no note file -> rc 1" "$?" "1"

printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
note=$(run_sourced "$SANDBOX" data_wipe_note)
assert_eq "the wedged-partition wipe -> recovery true" "$(printf '%s' "$note" | jq -r '.recovery')" "true"
assert_eq "the last line's timestamp is carried through" "$(printf '%s' "$note" | jq -r '.when')" "2026-08-21T09:00:00Z"
assert_eq "the last line's reason is carried through" "$(printf '%s' "$note" | jq -r '.reason')" \
    "unrecoverable /data reinitialized — everything on it was lost"

printf '2026-08-20T08:00:00Z factory-reset requested\n2026-08-21T09:00:00Z factory-reset requested\n' >"$DWN/esp/pithead-data-wiped"
note=$(run_sourced "$SANDBOX" data_wipe_note)
assert_eq "a deliberate factory-reset -> recovery false" "$(printf '%s' "$note" | jq -r '.recovery')" "false"
assert_eq "append-only log: only the LAST line is read" "$(printf '%s' "$note" | jq -r '.when')" "2026-08-21T09:00:00Z"

printf 'garbage\n' >"$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" data_wipe_note >/dev/null 2>&1
assert_rc "a line with no '<when> <reason>' shape -> rc 1, never a made-up note" "$?" "1"

# publish_data_wipe_note carries the note to the wizard's spool — the wizard container's ONLY
# mount, so it cannot read PRESEED_DIR itself.
rm -f "$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "no note -> the spool gets an empty object, not a missing file" "$(cat "$DWN/spool/data-wiped.json")" "{}"
assert_eq "no temp file left beside the atomic target" \
    "$(find "$DWN/spool" -name '.data-wiped.json.*' | wc -l | tr -d ' ')" "0"

printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "a real note reaches the spool" "$(jq -r '.recovery' "$DWN/spool/data-wiped.json")" "true"

# The fleet-stick rule (same as publish_rig_defaults, #797 R3): a MISSING note must overwrite a
# PREVIOUS machine's note, never leave it standing — the spool survives on /data between
# machines. MUTATION PROOF: an early return in the publisher (`note=$(data_wipe_note) || return
# 0`) leaves the previous machine's note in place; this assertion catches it (see the table in
# the PR description for the actual red run).
rm -f "$DWN/esp/pithead-data-wiped"
run_sourced "$SANDBOX" publish_data_wipe_note "$DWN/spool" >/dev/null 2>&1
assert_eq "a stale note from a previous machine does not survive an absent one" "$(cat "$DWN/spool/data-wiped.json")" "{}"

# Removable boot media: PRESEED_DIR is the STICK's own ESP there, describing the stick, never
# THIS machine — the publisher must not carry it across even when the stick's ESP holds a note.
printf '2026-08-21T09:00:00Z unrecoverable /data reinitialized — everything on it was lost\n' >"$DWN/esp/pithead-data-wiped"
(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    boot_is_removable() { return 0; }
    publish_data_wipe_note "$DWN/spool"
) >/dev/null 2>&1
assert_eq "booting from removable media never carries the STICK's own note across" \
    "$(cat "$DWN/spool/data-wiped.json")" "{}"

unset PITHEAD_PRESEED_DIR
rm -rf "$DWN"
unset DWN note

echo "== unit: is_appliance gates the tarball upgrade =="
# The appliance's program tree is resynced from the system slot every boot, so a DIY tarball
# upgrade would silently revert — both upgrade entrances must refuse when the host is one.
out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" stack_upgrade 2>&1)
assert_rc "appliance: stack_upgrade refuses" "$?" "1"
assert_contains "refusal explains the revert-at-reboot trap" "$out" "revert at the next reboot"
PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" is_appliance
assert_rc "override PITHEAD_APPLIANCE=1 -> appliance" "$?" "0"
PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" is_appliance
assert_rc "override PITHEAD_APPLIANCE=0 -> not appliance" "$?" "1"

echo "== unit: consume_install_request (disk installer host side) =="
# The request file is operator input arriving through a web form; the host must validate it
# against its own inventory and never trust a browser-supplied target. Driven against a fake
# pithead-install via PITHEAD_INSTALL_BIN — the real one partitions disks.
INSTSB=$(mktemp -d)
cat >"$INSTSB/fake-install" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
--list) printf 'vda\t40G\tFake Disk\tSN1\tempty\n' ;;
--target)
    # record target + wipe mode (args: --target /dev/X [--wipe M] --yes)
    echo "$2 ${4:-}" >>"${FAKE_LOG:?}"
    exit "${FAKE_RC:-0}"
    ;;
esac
FAKE
chmod +x "$INSTSB/fake-install"
export PITHEAD_INSTALL_BIN="$INSTSB/fake-install" FAKE_LOG="$INSTSB/calls" FAKE_RC=0

mkdir -p "$INSTSB/spool"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "empty spool -> rc 2 (nothing requested)" "$?" "2"

printf 'vda\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "offered target -> rc 0" "$?" "0"
assert_eq "installer invoked with /dev/vda and the wipe mode" "$(cat "$INSTSB/calls")" "/dev/vda keep"
[ -f "$INSTSB/spool/installed" ] && ok "installed marker written" || bad "installed marker written" "missing"
[ -f "$INSTSB/spool/install-request" ] && bad "request consumed" "still present" || ok "request consumed"

# The wipe mode is validated HERE too: a crafted mode falls back to keep, never reaches a shell.
rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'vda\tdata' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_eq "wipe mode passes through" "$(cat "$INSTSB/calls")" "/dev/vda data"
rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'vda\t; rm -rf /' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_eq "hostile wipe mode normalized to keep" "$(cat "$INSTSB/calls")" "/dev/vda keep"

rm -f "$INSTSB/spool/installed" "$INSTSB/calls"
printf 'sdz\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "unlisted target -> rc 1, refused" "$?" "1"
assert_contains "refusal names the target" "$(cat "$INSTSB/spool/error.txt")" "sdz"
[ -f "$INSTSB/calls" ] && bad "installer NOT invoked for unlisted target" "was invoked" || ok "installer NOT invoked for unlisted target"

# A browser-supplied name is sanitized before it can reach a shell: path characters vanish and
# the remainder no longer matches the inventory.
rm -f "$INSTSB/spool/error.txt"
printf '../../vda; rm -rf /\tkeep' >"$INSTSB/spool/install-request"
run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "hostile target string -> rc 1, refused" "$?" "1"
[ -f "$INSTSB/calls" ] && bad "installer NOT invoked for hostile string" "was invoked" || ok "installer NOT invoked for hostile string"

# Installer failure surfaces into the spool for the page, and no success marker appears.
rm -f "$INSTSB/spool/error.txt"
printf 'vda\tkeep' >"$INSTSB/spool/install-request"
FAKE_RC=1 run_sourced "$SANDBOX" consume_install_request "$INSTSB/spool" >/dev/null 2>&1
assert_rc "installer failure -> rc 1" "$?" "1"
[ -f "$INSTSB/spool/error.txt" ] && ok "failure surfaced to the page" || bad "failure surfaced to the page" "no error.txt"
[ -f "$INSTSB/spool/installed" ] && bad "no success marker on failure" "present" || ok "no success marker on failure"

unset PITHEAD_INSTALL_BIN FAKE_LOG FAKE_RC INSTSB

echo "== unit: strip_config_secrets — no secret class survives the reinstall pre-fill =="
# The strip runs before a previous install's config may be SHOWN on the setup page. Every
# secret carries the same marker value, so one grep proves the whole list at once; the
# non-secret answers (the point of the pre-fill) must all survive.
SCS=$(mktemp -d)
cat >"$SCS/prev.json" <<'PREV'
{
  "monero": {"wallet_address": "4KEEP-WALLET", "mode": "remote",
             "remote": {"host": "node.lan", "rpc_port": 18081, "zmq_port": 18083},
             "node_username": "LEAK-user", "node_password": "LEAK-nodepw", "view_key": "LEAK-mvk"},
  "tari": {"wallet_address": "KEEP-TARI", "mode": "remote",
           "remote": {"host": "tari.lan", "grpc_port": 18142},
           "view_key": "LEAK-tvk", "spend_public_key": "LEAK-tspk"},
  "p2pool": {"pool": "main", "stratum_password": "LEAK-stratum"},
  "dashboard": {"timezone": "Europe/Berlin",
                "auth": {"username": "LEAK-dashuser", "password": "LEAK-dashpw"},
                "workers": [{"name": "w0", "host": "h", "token": "LEAK-oldworker"}]},
  "workers": {"api_auth": true, "api_token": "LEAK-apitoken",
              "list": [{"name": "rig1", "host": "rig1.lan", "token": "LEAK-workertoken"}]},
  "telegram": {"enabled": true, "bot_token": "LEAK-bot", "chat_id": "LEAK-chat"},
  "healthchecks": {"ping_url": "https://hc.example/LEAK-ping"},
  "notifications": {"ntfy": {"url": "https://ntfy.example/LEAK-url", "token": "LEAK-ntfy"}},
  "ssh": {"enabled": true, "authorized_key": "ssh-ed25519 LEAK-sshkey"},
  "xvb": {"enabled": true, "standby": {"source": "LEAK-standby"}}
}
PREV
stripped=$(run_sourced "$SANDBOX" strip_config_secrets "$SCS/prev.json")
assert_rc "a real config strips cleanly (rc 0)" "$?" "0"
assert_eq "no secret of ANY class survives" "$(printf '%s' "$stripped" | grep -c 'LEAK-')" "0"
assert_eq "wallet address survives" "$(printf '%s' "$stripped" | jq -r '.monero.wallet_address')" "4KEEP-WALLET"
assert_eq "remote node mode survives" "$(printf '%s' "$stripped" | jq -r '.tari.mode')" "remote"
assert_eq "remote node host survives" "$(printf '%s' "$stripped" | jq -r '.tari.remote.host')" "tari.lan"
assert_eq "pool tier survives" "$(printf '%s' "$stripped" | jq -r '.p2pool.pool')" "main"
assert_eq "timezone survives" "$(printf '%s' "$stripped" | jq -r '.dashboard.timezone')" "Europe/Berlin"
# Not-a-config shapes are refused, not partially stripped: rc != 0 means "no pre-fill".
printf 'not json at all' >"$SCS/garbage.json"
if run_sourced "$SANDBOX" strip_config_secrets "$SCS/garbage.json" >/dev/null 2>&1; then
    bad "garbage file -> refused" "rc 0"
else
    ok "garbage file -> refused"
fi
printf '[1,2,3]' >"$SCS/array.json"
if run_sourced "$SANDBOX" strip_config_secrets "$SCS/array.json" >/dev/null 2>&1; then
    bad "non-object JSON -> refused" "rc 0"
else
    ok "non-object JSON -> refused"
fi
rm -rf "$SCS"
unset SCS stripped

echo "== unit: prefill_from_previous_install — fail open, publish only the stripped remainder =="
# The orchestration around the strip: exactly one disk with an install, a read-only mount, and
# every failure degrading to "no pre-fill" — never to a blocked install. mount/umount/lsblk are
# PATH stubs; the fake mount copies a fixture tree under the mountpoint.
PFSB=$(mktemp -d)
mkdir -p "$PFSB/bin" "$PFSB/spool" "$PFSB/prev/pithead"
printf '#!/bin/bash\necho "/dev/fake2 data"\n' >"$PFSB/bin/lsblk"
cat >"$PFSB/bin/mount" <<'MNT'
#!/bin/bash
[ "${PF_MOUNT_RC:-0}" -eq 0 ] || exit "$PF_MOUNT_RC"
# The mountpoint is the last argument; -P keeps fixture symlinks AS symlinks.
cp -RP "${PF_TREE:?}/." "${!#}/"
MNT
printf '#!/bin/bash\nexit 0\n' >"$PFSB/bin/umount"
chmod +x "$PFSB/bin/lsblk" "$PFSB/bin/mount" "$PFSB/bin/umount"
export PF_TREE="$PFSB/prev"
printf 'sda\t4T\tPrev Disk\tSN9\tpithead-with-data\n' >"$PFSB/spool/disks.tsv"
printf '{"monero":{"wallet_address":"4PREV"},"dashboard":{"auth":{"username":"op","password":"LEAK-pw"}}}' \
    >"$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "previous install found -> pre-fill published (rc 0)" "$?" "0"
assert_eq "pre-fill keeps the wallet" "$(jq -r '.monero.wallet_address' "$PFSB/spool/last-attempt.json")" "4PREV"
assert_eq "pre-fill carries NO login" "$(grep -c 'LEAK-' "$PFSB/spool/last-attempt.json")" "0"
assert_eq "no temp file left beside the atomic target" "$(find "$PFSB/spool" -name '.last-attempt*' | wc -l | tr -d ' ')" "0"

# Broken previous config -> no pre-fill, no error surfaced to the page.
rm -f "$PFSB/spool/last-attempt.json"
printf '{broken' >"$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "broken previous config -> rc 1" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "broken config publishes nothing" "file exists" || ok "broken config publishes nothing"
[ -f "$PFSB/spool/error.txt" ] && bad "broken config surfaces no page error" "error.txt written" || ok "broken config surfaces no page error"

# Absent previous config -> no pre-fill.
rm -f "$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "no previous config -> rc 1" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "no config publishes nothing" "file exists" || ok "no config publishes nothing"

# A mount failure (corrupt filesystem, busy partition) fails open too.
printf '{"monero":{"wallet_address":"4PREV"}}' >"$PFSB/prev/pithead/config.json"
PF_MOUNT_RC=32 PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "mount failure -> rc 1, nothing blocked" "$?" "1"

# Symlink escape: a crafted disk pointing config.json — or the pithead dir itself — at a file
# on the RUNNING host must publish nothing, even when the target parses as a valid config.
printf '{"monero":{"wallet_address":"4HOST-FILE"}}' >"$PFSB/outside.json"
rm -f "$PFSB/prev/pithead/config.json"
ln -s "$PFSB/outside.json" "$PFSB/prev/pithead/config.json"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "symlinked config.json -> rc 1, refused" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "symlinked config publishes nothing" "file exists" || ok "symlinked config publishes nothing"
mkdir -p "$PFSB/outside-dir"
printf '{"monero":{"wallet_address":"4HOST-FILE"}}' >"$PFSB/outside-dir/config.json"
rm -rf "$PFSB/prev/pithead"
ln -s "$PFSB/outside-dir" "$PFSB/prev/pithead"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "symlinked pithead dir -> rc 1, refused" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "symlinked dir publishes nothing" "file exists" || ok "symlinked dir publishes nothing"
rm -rf "$PFSB/prev/pithead"
mkdir -p "$PFSB/prev/pithead"

# Two disks carrying installs: WHICH machine's answers is a guess — publish none.
printf 'sda\t4T\tPrev A\tSN9\tpithead-with-data\nsdb\t4T\tPrev B\tSN8\tpithead-with-data\n' >"$PFSB/spool/disks.tsv"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "two candidate disks -> rc 1, no guessing" "$?" "1"
[ -f "$PFSB/spool/last-attempt.json" ] && bad "ambiguous target publishes nothing" "file exists" || ok "ambiguous target publishes nothing"

# No disk with data at all (the everyday fresh-install stick) -> rc 1, quietly.
printf 'vda\t40G\tBlank\tSN1\tempty\n' >"$PFSB/spool/disks.tsv"
PATH="$PFSB/bin:$PATH" run_sourced "$SANDBOX" prefill_from_previous_install "$PFSB/spool" >/dev/null 2>&1
assert_rc "no install on any disk -> rc 1" "$?" "1"
rm -rf "$PFSB"
unset PFSB PF_TREE

echo "== unit: publish_rig_defaults — host-side pool discovery, fail open (#797 R3) =="
# The rig role's pre-fill: the HOST dials for a Pithead and publishes the finding to the spool
# like the disk inventory. The dial is 'timeout N bash -c </dev/tcp/...' — timeout is a PATH
# stub here (like mount in the pre-fill tests), so the probe answers deterministically.
RDSB=$(mktemp -d)
mkdir -p "$RDSB/bin" "$RDSB/spool"
printf '#!/bin/bash\nexit 0\n' >"$RDSB/bin/timeout"
chmod +x "$RDSB/bin/timeout"
PITHEAD_RIG_PROBE="coordinator.lan:3333" PATH="$RDSB/bin:$PATH" \
    run_sourced "$SANDBOX" publish_rig_defaults "$RDSB/spool" >/dev/null 2>&1
assert_eq "a Pithead answering -> pool published" "$(jq -r '.pool' "$RDSB/spool/rig-defaults.json")" "coordinator.lan:3333"
assert_eq "the worker default is this machine's own name" "$(jq -r '.worker' "$RDSB/spool/rig-defaults.json")" "$(hostname)"
printf '#!/bin/bash\nexit 1\n' >"$RDSB/bin/timeout"
PITHEAD_RIG_PROBE="coordinator.lan:3333" PATH="$RDSB/bin:$PATH" \
    run_sourced "$SANDBOX" publish_rig_defaults "$RDSB/spool" >/dev/null 2>&1
assert_eq "no answer -> NO pool key, the field opens empty" "$(jq -r 'has("pool")' "$RDSB/spool/rig-defaults.json")" "false"
assert_eq "no temp file beside the atomic target" "$(find "$RDSB/spool" -name '.rig-defaults*' | wc -l | tr -d ' ')" "0"
rm -rf "$RDSB"
unset RDSB

echo "== unit: firstboot_consume_rig — the pool is dialed BEFORE anything irreversible (#797 R3) =="
RCSB=$(mktemp -d)
mkdir -p "$RCSB/bin" "$RCSB/spool"
printf '#!/bin/bash\nexit 0\n' >"$RCSB/bin/timeout"
chmod +x "$RCSB/bin/timeout"

run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "no request -> rc 2 (nothing submitted)" "$?" "2"

printf '{"pool":"not-an-address"}' >"$RCSB/spool/rig-request.json"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "shapeless pool -> rc 1, rejected" "$?" "1"
assert_contains "the rejection names the format" "$(cat "$RCSB/spool/error.txt")" "host:port"
[ -f "$RCSB/rig.json" ] && bad "a rejected request lands nothing" "rig.json exists" || ok "a rejected request lands nothing"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3","stratum_password":"pw-fixture"}' >"$RCSB/spool/rig-request.json"
printf '#!/bin/bash\nexit 1\n' >"$RCSB/bin/timeout"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "unreachable pool -> rc 1 (validate before erase)" "$?" "1"
assert_contains "the failure names the endpoint" "$(cat "$RCSB/spool/error.txt")" "10.0.0.5:3333"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3","stratum_password":"pw-fixture"}' >"$RCSB/spool/rig-request.json"
printf '#!/bin/bash\nexit 0\n' >"$RCSB/bin/timeout"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "reachable pool -> rc 0, accepted" "$?" "0"
assert_eq "the accepted answers land host-side" "$(jq -r '.worker' "$RCSB/rig.json")" "shed-3"
assert_eq "the password rides along" "$(jq -r '.stratum_password' "$RCSB/rig.json")" "pw-fixture"
[ -f "$RCSB/spool/rig-request.json" ] && bad "the request is consumed" "still present" || ok "the request is consumed"

printf '{"pool":"10.0.0.5:3333"}' >"$RCSB/spool/rig-request.json"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_eq "no worker named -> this machine's own name" "$(jq -r '.worker' "$RCSB/rig.json")" "$(hostname)"
assert_eq "no password -> the key is omitted, not written empty" "$(jq -r 'has("stratum_password")' "$RCSB/rig.json")" "false"
rm -rf "$RCSB"
unset RCSB

echo "== unit: the machine-role marker, written and read back (#797 R3/R4) =="
MRSB=$(mktemp -d)
printf '{"local_miner":{"enabled":true}}' >"$MRSB/config.json"
assert_eq "local_miner on -> both (the role IS the switch)" "$(run_sourced "$MRSB" machine_role_from_config "$MRSB/config.json")" "both"
printf '{}' >"$MRSB/config.json"
assert_eq "no local_miner -> pithead" "$(run_sourced "$MRSB" machine_role_from_config "$MRSB/config.json")" "pithead"
rm -f "$MRSB/config.json"
assert_eq "no marker at all -> pithead (every pre-contract machine)" "$(run_sourced "$MRSB" machine_role)" "pithead"
run_sourced "$MRSB" record_machine_role rig >/dev/null 2>&1
assert_eq "the marker lands where the boot path reads it" "$(cat "$MRSB/machine-role")" "rig"
assert_eq "the boot path reads back what was written" "$(run_sourced "$MRSB" machine_role)" "rig"
printf 'nonsense\n' >"$MRSB/machine-role"
assert_eq "an unreadable marker degrades to pithead, never to rig" "$(run_sourced "$MRSB" machine_role)" "pithead"
rm -rf "$MRSB"
unset MRSB

echo "== unit: the rig boot leg — a role=rig machine mines instead of coordinating (#797 R4) =="
# A rig has no config.json, no .env, no containers and no dashboard: rig.json IS its whole
# contract. Driven against a fake rigforge.sh, like the Both role's leg — the real one compiles
# miners and tunes kernels. What this owns: the derived config (pool + worker + password), the
# invocation contract, and the refusals.
RIGL=$(mktemp -d)
mkdir -p "$RIGL/rigforge" "$RIGL/bin" "$RIGL/run" "$RIGL/journal"
cat >"$RIGL/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset} cwd=$PWD" >>"${RF_LOG:?}"
exit "${RF_RC:-0}"
EOF
chmod +x "$RIGL/rigforge/rigforge.sh"
printf '#!/usr/bin/env bash\necho "systemctl:$*" >>"${RF_LOG:?}"\n' >"$RIGL/bin/systemctl"
chmod +x "$RIGL/bin/systemctl"
# The prebuilt XMRig the image bakes and pithead-sync seeds: present means no compile, which is
# the whole no-clearnet-on-first-boot promise. Its absence is what narrates a build.
mkdir -p "$RIGL/rigforge/data/worker/xmrig/build"
: >"$RIGL/rigforge/data/worker/xmrig/build/xmrig"
chmod +x "$RIGL/rigforge/data/worker/xmrig/build/xmrig"
export RF_LOG="$RIGL/calls" PITHEAD_RIGFORGE_DIR="$RIGL/rigforge"
export PITHEAD_JOURNALD_DROPIN_DIR="$RIGL/run" PITHEAD_JOURNAL_DIR="$RIGL/journal"
run_rig() { PITHEAD_APPLIANCE=1 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" "$@"; }

printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RIGL/rig.json"
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "role=rig without the marker -> still the coordinator leg" "$?" "0"
# rig.json alone means nothing: the MARKER is what the boot path forks on. Unmarked, this is a
# coordinator with local_miner off, and the coordinator leg's job there is to stop the miner.
assert_not_contains "no marker means no rig leg ran" "$(cat "$RF_LOG")" "rigforge:"
assert_contains "unmarked -> the coordinator leg, which stops a miner it does not own" "$(cat "$RF_LOG")" "systemctl:stop xmrig.service"
run_sourced "$RIGL" record_machine_role rig >/dev/null 2>&1
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "marked rig -> rc 0" "$?" "0"
assert_contains "the marked machine runs rigforge setup in appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_contains "it runs from the synced tree on /data" "$(cat "$RF_LOG")" "cwd=$RIGL/rigforge"
assert_contains "the console names the worker and its pool" "$rigl_out" "shed-3 -> 10.0.0.5:3333"
# The derived config: rig.json's three values and nothing else. No hugepages headroom — there is
# no stack on this machine to leave room for.
assert_eq "the pool is the address the operator gave" "$(jq -r '.pools[0].url' "$RIGL/rigforge/config.json")" "10.0.0.5:3333"
assert_eq "the worker name labels the rig at the pool" "$(jq -r '.pools[0].user' "$RIGL/rigforge/config.json")" "shed-3"
assert_eq "no stratum password -> no pass key at all" "$(jq -r '.pools[0] | has("pass")' "$RIGL/rigforge/config.json")" "false"
assert_eq "no stack here -> no hugepages headroom declared" "$(jq -r 'has("hugepages_reserve_extra_mb")' "$RIGL/rigforge/config.json")" "false"
# Prebuilt-first: the seeded binary means the first boot renders, it never compiles or clones.
assert_not_contains "a seeded prebuilt narrates no build" "$rigl_out" "building it once"
# Removable-root tolerance: the journal goes to memory, because the root may be the stick the
# miner runs from — and journald has to be restarted for the setting to take.
assert_contains "journald is flipped to volatile" "$(cat "$RIGL/run/zz-rig-volatile.conf")" "Storage=volatile"
[ -d "$RIGL/journal" ] && bad "the persistent journal directory is reclaimed" "still there" ||
    ok "the persistent journal directory is reclaimed"
assert_contains "journald is restarted so the setting takes" "$(cat "$RF_LOG")" "systemctl:restart systemd-journald"
# A stratum password lands as the pool pass, and the config is re-derived every boot. Idempotent
# on the second boot: nothing left to reclaim, so journald is not restarted again.
printf '{"pool":"pithead.local:3333","worker":"shed-4","stratum_password":"s3cret"}' >"$RIGL/rig.json"
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "re-run (the leg fires every boot) -> rc 0" "$?" "0"
assert_eq "the config is re-derived, not repaired" "$(jq -r '.pools[0].url' "$RIGL/rigforge/config.json")" "pithead.local:3333"
assert_eq "the stratum password lands as the pool pass" "$(jq -r '.pools[0].pass' "$RIGL/rigforge/config.json")" "s3cret"
assert_not_contains "already volatile -> journald is not restarted again" "$(cat "$RF_LOG")" "restart systemd-journald"
# No prebuilt (a wiped workspace): the operator gets told why the console is silent for minutes.
rm -rf "$RIGL/rigforge/data/worker/xmrig"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_contains "a missing prebuilt narrates the one-time build" "$rigl_out" "building it once"
# A failing setup is a failing boot leg: the caller leaves the slot uncommitted on it.
rigl_out=$(PITHEAD_APPLIANCE=1 RF_RC=1 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" provision_local_miner 2>&1)
assert_rc "failed setup -> rc 1" "$?" "1"
assert_contains "failed setup is named on the console" "$rigl_out" "did not start"
# A marker with no settings beside it: refuse, and say how to get the machine back.
rm -f "$RIGL/rig.json"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "marked rig with no settings -> rc 1" "$?" "1"
assert_contains "the refusal names the way back (install again from the stick)" "$rigl_out" "install it again from the stick"
# DIY host: a no-op, marker or not — RigForge there is the operator's own install.
: >"$RF_LOG"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RIGL/rig.json"
PITHEAD_APPLIANCE=0 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" provision_local_miner >/dev/null 2>&1
assert_eq "DIY host -> touches nothing" "$(cat "$RF_LOG")" ""
unset RF_LOG PITHEAD_RIGFORGE_DIR PITHEAD_JOURNALD_DROPIN_DIR PITHEAD_JOURNAL_DIR
unset -f run_rig
rm -rf "$RIGL"
unset RIGL rigl_out

echo "== unit: a rig's first boot mines — wizard side and staged-install side (#797 R4) =="
# Both boots that ACCEPT a role end mining on that same boot: no second wizard, no reboot to
# wait for. Every LATER boot skips this unit entirely (its condition now excludes rig.json) and
# goes through pithead-boot instead.
RPSB=$(mktemp -d)
RPESP=$(mktemp -d)
mkdir -p "$RPSB/rigforge"
cat >"$RPSB/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset}" >>"${RF_LOG:?}"
EOF
chmod +x "$RPSB/rigforge/rigforge.sh"
export PITHEAD_PRESEED_DIR="$RPESP" PITHEAD_RIGFORGE_DIR="$RPSB/rigforge" RF_LOG="$RPSB/calls"
: >"$RF_LOG"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RPESP/pithead-rig.json"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$RPSB" firstboot_wizard 2>&1)
assert_rc "staged rig settings -> consumed, rc 0" "$?" "0"
assert_eq "the answers land beside the program" "$(jq -r '.worker' "$RPSB/rig.json")" "shed-3"
assert_eq "the role marker is written" "$(cat "$RPSB/machine-role")" "rig"
assert_contains "the console states the role and the worker" "$out" "RigForge rig"
assert_contains "the staged install mines on that first boot" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_not_contains "no wizard container is started" "$out" "Setup wizard is up"
# Spent, like the config pre-seed: settings (possibly a password) must not sit on the ESP.
[ -f "$RPESP/pithead-rig.json" ] && bad "the consumed settings leave the ESP" "still there" || ok "the consumed settings leave the ESP"
# An already-marked machine reaching this unit by hand takes the same leg, and asks nothing.
: >"$RF_LOG"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$RPSB" firstboot_wizard 2>&1)
assert_rc "already-marked rig -> rc 0, no coordinator questions" "$?" "0"
assert_contains "the marked machine takes the rig leg too" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_not_contains "the R3 stub message is gone" "$out" "nothing mines yet"
unset PITHEAD_PRESEED_DIR PITHEAD_RIGFORGE_DIR RF_LOG
rm -rf "$RPSB" "$RPESP"
unset RPSB RPESP out

echo "== unit: render_local_miner_config — the built-in miner's config is DERIVED (#796) =="
# On the appliance, RigForge's config.json is a pure function of pithead's config.json + .env,
# rebuilt on every render like the Caddyfile: the stack's own stratum over loopback, the stratum
# password when one is set, and the stack's HugePages budget declared as headroom — the hand-off
# that makes RigForge the pool's single (grow-only) writer.
LMR=$(mktemp -d)
mkdir -p "$LMR/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$LMR/config.json"
printf 'STRATUM_PORT=3333\n' >"$LMR/.env"
export PITHEAD_RIGFORGE_DIR="$LMR/rigforge"
PITHEAD_APPLIANCE=0 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "DIY host -> nothing written" "file exists" ||
    ok "DIY host -> nothing written"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/no-marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "pool url is the stack's own stratum over loopback" \
    "$(jq -r '.pools[0].url' "$LMR/rigforge/config.json")" "127.0.0.1:3333"
assert_eq "no stratum password -> no pass key at all" \
    "$(jq -r '.pools[0] | has("pass")' "$LMR/rigforge/config.json")" "false"
assert_eq "no degrade marker -> the full budget is declared as headroom (3072 pages -> 6144 MB)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMR/rigforge/config.json")" "6144"
# #1103 superseded this: it used to assert the recorded reservation as headroom (2560 pages ->
# 5120 MB), the double-count #1103 removes — co-location is now refused outright on this
# REDUCED tier (no config); the rest of the gate is proven in test_appliance_hugepages.sh.
printf 'reduced-reservation words\npages=2560\n' >"$LMR/marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "reduced tier -> co-location refused, no config rendered (#1103)" "file exists" ||
    ok "reduced tier -> co-location refused, no config rendered (#1103)"
printf 'released-reservation words\npages=0\n' >"$LMR/marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "released reservation -> zero headroom (RigForge sizes for the miner alone)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMR/rigforge/config.json")" "0"
printf 'STRATUM_PORT=13333\nPROXY_STRATUM_PASSWORD=s3cret\n' >"$LMR/.env"
PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "custom stratum port lands in the pool url" \
    "$(jq -r '.pools[0].url' "$LMR/rigforge/config.json")" "127.0.0.1:13333"
assert_eq "stratum password lands as the pool pass" \
    "$(jq -r '.pools[0].pass' "$LMR/rigforge/config.json")" "s3cret"
# Derived means derived: switched off, the config goes away with the toggle.
printf '{"local_miner":{"enabled":false}}' >"$LMR/config.json"
PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "disabled -> the derived config is removed" "still there" ||
    ok "disabled -> the derived config is removed"
# Enabled on an image that never baked the tree: warn and carry on — render must not fail.
printf '{"local_miner":{"enabled":true}}' >"$LMR/config.json"
rm -rf "$LMR/rigforge"
lmr_out=$(PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config 2>&1)
assert_rc "missing tree -> rc 0 (render survives)" "$?" "0"
assert_contains "missing tree is named" "$lmr_out" "no RigForge tree"
unset PITHEAD_RIGFORGE_DIR
rm -rf "$LMR"
unset LMR lmr_out

echo "== unit: provision_local_miner — the boot leg converges the miner (#796) =="
# Driven against a fake rigforge.sh: the real one compiles miners and tunes kernels. What this
# owns: the invocation contract (appliance flag set, run from the tree on /data, config rendered
# first) and both convergence directions (enabled -> setup, disabled -> stop).
LMP=$(mktemp -d)
mkdir -p "$LMP/rigforge" "$LMP/bin"
cat >"$LMP/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset} cwd=$PWD" >>"${RF_LOG:?}"
exit "${RF_RC:-0}"
EOF
chmod +x "$LMP/rigforge/rigforge.sh"
printf '#!/usr/bin/env bash\necho "systemctl:$*" >>"${RF_LOG:?}"\n' >"$LMP/bin/systemctl"
chmod +x "$LMP/bin/systemctl"
export RF_LOG="$LMP/calls" PITHEAD_RIGFORGE_DIR="$LMP/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$LMP/config.json"
printf 'STRATUM_PORT=3333\n' >"$LMP/.env"
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "enabled -> rc 0" "$?" "0"
assert_contains "runs rigforge setup in appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_contains "runs it from the synced tree" "$(cat "$RF_LOG")" "cwd=$LMP/rigforge"
[ -s "$LMP/rigforge/config.json" ] && ok "a missing miner config is rendered before setup" ||
    bad "a missing miner config is rendered before setup" "not written"
# Idempotent re-run (the boot leg fires EVERY boot): same config, run again — same outcome,
# setup invoked again (rigforge's own appliance mode is the idempotency owner), no error.
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "enabled re-run (second boot) -> rc 0" "$?" "0"
assert_contains "re-run invokes setup again, appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
# Disabled: stop the service, never run setup — a dashboard toggle must not wait for a reboot.
printf '{"local_miner":{"enabled":false}}' >"$LMP/config.json"
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "disabled -> rc 0" "$?" "0"
assert_contains "disabled -> the miner service is stopped" "$(cat "$RF_LOG")" "systemctl:stop xmrig.service"
assert_not_contains "disabled -> rigforge never runs" "$(cat "$RF_LOG")" "rigforge:"
# DIY host: a no-op in both directions — RigForge there is the operator's own install.
printf '{"local_miner":{"enabled":true}}' >"$LMP/config.json"
: >"$RF_LOG"
PITHEAD_APPLIANCE=0 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "DIY host -> rc 0" "$?" "0"
assert_eq "DIY host -> touches nothing" "$(cat "$RF_LOG")" ""
# A failing setup is contained: warned, rc 1, and the caller treats the stack as unaffected.
: >"$RF_LOG"
lmp_out=$(PITHEAD_APPLIANCE=1 RF_RC=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner 2>&1)
assert_rc "failed setup -> rc 1" "$?" "1"
assert_contains "failed setup names the containment" "$lmp_out" "stack itself is unaffected"
# An image that never baked the tree: enabled is a promise the image cannot keep — warn, rc 1.
rm -rf "$LMP/rigforge"
lmp_out=$(PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner 2>&1)
assert_rc "missing tree -> rc 1" "$?" "1"
assert_contains "missing tree is named" "$lmp_out" "no RigForge tree"
unset RF_LOG PITHEAD_RIGFORGE_DIR
rm -rf "$LMP"
unset LMP lmp_out

echo "== unit: pithead-boot wiring — the miner leg rides AFTER the slot commit =="
# Ordering is the contract: the stack serving is the product's health and gates the A/B commit;
# the miner is a passenger that needs the stratum listening and must never delay the commit.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
mg_line=$(grep -n "mark-good" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
lm_line=$(grep -n "pithead local-miner" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$mg_line" ] && [ -n "$lm_line" ] && [ "$lm_line" -gt "$mg_line" ]; then
    ok "pithead-boot runs 'pithead local-miner' after the health-gated commit"
else
    bad "pithead-boot runs 'pithead local-miner' after the health-gated commit" \
        "mark-good@${mg_line:-none} local-miner@${lm_line:-none}"
fi
# A hung miner setup must not wedge the boot unit either — TimeoutStartSec=infinity on
# pithead-boot means || true alone cannot save it; the leg needs its own bounded clock.
grep -qE "timeout [0-9]+ \./pithead local-miner" "$BOOTSCRIPT" &&
    ok "the miner leg runs under its own timeout (boot unit has no clock of its own)" ||
    bad "the miner leg runs under its own timeout (boot unit has no clock of its own)" \
        "no 'timeout N ./pithead local-miner' in pithead-boot"

# The rig fork (#797 R4): a rig has no stack, so the role branch must come BEFORE the loader and
# must never reach render/up. It still commits its own slot — one image, one update pipeline.
rig_line=$(grep -n '^if .*machine-role' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
li_line=$(grep -n 'pithead load-images' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$rig_line" ] && [ -n "$li_line" ] && [ "$rig_line" -lt "$li_line" ]; then
    ok "the role fork precedes the container-image loader (a rig loads none)"
else
    bad "the role fork precedes the container-image loader (a rig loads none)" \
        "role@${rig_line:-none} load-images@${li_line:-none}"
fi
# A coordinator has no marker, and reading a file that is not there is a REDIRECTION failure the
# shell reports itself — `2>/dev/null` on the inner command cannot reach it. Harmless to control
# flow, but it would print "No such file or directory" into the journal of every coordinator
# boot. Existence has to be tested before the read.
sed -n "${rig_line:-1}p" "$BOOTSCRIPT" | grep -q '\[ -f machine-role \]' &&
    ok "the marker is tested for existence before it is read (no error on every coordinator boot)" ||
    bad "the marker is tested for existence before it is read (no error on every coordinator boot)" \
        "$(sed -n "${rig_line:-1}p" "$BOOTSCRIPT")"
rig_branch=$(sed -n "${rig_line:-1},/^fi\$/p" "$BOOTSCRIPT")
printf '%s' "$rig_branch" | grep -qE '\./pithead (up|render|load-images)' &&
    bad "the rig branch starts nothing container-shaped" "it calls the stack's own commands" ||
    ok "the rig branch starts nothing container-shaped"
printf '%s' "$rig_branch" | grep -q 'mark-good' &&
    ok "a rig commits its A/B slot exactly like a coordinator" ||
    bad "a rig commits its A/B slot exactly like a coordinator" "no mark-good in the rig branch"
# The units are the other half of the fork: without the triggering condition a rig never runs
# the boot unit, and without the firstboot exclusion it re-runs the WIZARD every boot.
BOOTUNIT="$ROOT/os/overlay/pithead-boot.service"
FBUNIT="$ROOT/os/overlay/pithead-firstboot.service"
grep -q '^ConditionPathExists=|/data/pithead/machine-role' "$BOOTUNIT" &&
    grep -q '^ConditionPathExists=|/data/pithead/config.json' "$BOOTUNIT" &&
    ok "the boot unit triggers on either shape of provisioned (config.json or the role marker)" ||
    bad "the boot unit triggers on either shape of provisioned (config.json or the role marker)" \
        "$(grep -c '^ConditionPathExists=|' "$BOOTUNIT") triggering conditions"
grep -q '^ConditionPathExists=!/data/pithead/machine-role' "$FBUNIT" &&
    ok "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" ||
    bad "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" "missing"
# The marker, not rig.json: a fleet stick writes a rig's ANSWERS in flight while installing one
# onto a disk, and must stay an installer through it — only an ACCEPTED role writes the marker.
grep -h '^ConditionPathExists=' "$BOOTUNIT" "$FBUNIT" | grep -q 'rig\.json' &&
    bad "neither unit keys on the in-flight rig.json (a stick would stop being an installer)" "it does" ||
    ok "neither unit keys on the in-flight rig.json (a stick stays an installer)"
unset BOOTSCRIPT BOOTUNIT FBUNIT mg_line lm_line rig_line li_line rig_branch

echo "== unit: the A/B commit gate consumes doctor --json, not just the curl (#852) =="
# The gate that used to be a bare curl to https://localhost/ committed any slot whose dashboard
# answered — even one whose mining services had crashed. The fix pairs the curl with doctor's
# exit code. Assert the wiring: both signals gate the same mark-good, curl first (cheap).
# BOTH signals must gate mark-good (#852): a slot whose dashboard answers but whose mining
# containers have crashed must NOT commit. This was a grep of the boot script until #1140, and the
# doctor half of that grep matched the file's own HEADER COMMENT — it stayed green with the doctor
# call deleted from the commit condition outright. The pairing now lives in gate_ready and is
# driven here with a stubbed `pithead`, so deleting either half goes red.
# Mutation run: drop the doctor call from gate_ready -> "a crashed stack does not commit" goes red;
# drop the gate_answer_is_dashboard call -> "the default vhost does not commit" goes red.
GR="$SANDBOX/gate-ready"
mkdir -p "$GR"
gr_run() { # <doctor-exit> <code> <size> -> ready|held
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"$GR/pithead"
    chmod +x "$GR/pithead"
    (
        cd "$GR" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$GR/doctor.json"
        gate_ready "$2" "$3" && echo ready || echo held
    )
}
assert_eq "dashboard serving AND doctor clean -> commit" "$(gr_run 0 200 4096)" "ready"
# #852 itself: the mining-dead-but-serving slot a curl-only gate used to mark-good.
assert_eq "a crashed stack does not commit, however well the dashboard answers" "$(gr_run 1 200 4096)" "held"
# #1140 itself: Caddy's empty default vhost must not open the door to the doctor run either.
assert_eq "the default vhost does not commit, even with doctor clean" "$(gr_run 0 200 0)" "held"
assert_eq "nothing answering does not commit" "$(gr_run 0 000 0)" "held"
assert_eq "a locked dashboard (401) with doctor clean -> commit" "$(gr_run 0 401 0)" "ready"
unset -f gr_run
unset GR

echo "== unit: the boot health probe asks the dashboard's own site, and can tell it apart (#1140) =="
# The probe used to dial https://localhost/ and accept any status but 000, on the stated belief
# that localhost is always a listed site. generate_caddyfile only adds localhost while
# dashboard.host is UNSET — pin the host and the probe reached Caddy's EMPTY DEFAULT VHOST, which
# answers 200 with no body. On the gate that decides whether an A/B update lives, and that #1065
# reboots on, "Caddy is running" was passing as "the dashboard serves".
# Two halves, both driven here: ask the right site, and recognise the right answer.
GU="$SANDBOX/gateurl"
mkdir -p "$GU"
gu_run() { # <env-body> -> "scheme|host|port"
    printf '%s\n' "$1" >"$GU/.env"
    (
        cd "$GU" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_url
    )
}
# THE #1140 CASE: a pinned dashboard.host. The site list holds that name and NOT localhost, so the
# probe has to carry it or it is talking to the default vhost.
assert_eq "a pinned host is what the probe asks for" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true')" "https|panel.example|443"
# Unpinned: HOST_IP is whatever resolve_dashboard_host chose, and it is still the first site.
assert_eq "an unpinned host still comes from the render, not a literal" \
    "$(gu_run 'HOST_IP=pithead.local
DASHBOARD_SECURE=true')" "https|pithead.local|443"
assert_eq "dashboard.secure:false -> the site is http, so the probe is too" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=false')" "http|panel.example|80"
assert_eq "a custom host port is honoured" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true
HOST_PORT=8443')" "https|panel.example|8443"
# Fail SAFE, not closed: an unreadable .env must not make this gate a permanent RED, because after
# #1065 a gate that never passes reboots a healthy box. Falling back to localhost is the old
# behaviour, and gate_answer_is_dashboard below still refuses to call the default vhost a success.
assert_eq "an .env with no HOST_IP falls back rather than dialling nothing" \
    "$(gu_run 'DASHBOARD_SECURE=true')" "https|localhost|443"
unset -f gu_run
unset GU

gad() { # <code> <size> -> accept|reject
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_answer_is_dashboard "$1" "$2" && echo accept || echo reject
    )
}
# The whole point: Caddy's empty default vhost answers 200 with a zero-length body. That is the
# answer #1140 was accepting as a healthy dashboard.
assert_eq "200 with an empty body is the default vhost -> REJECT" "$(gad 200 0)" "reject"
assert_eq "200 with a real page is the dashboard -> accept" "$(gad 200 4096)" "accept"
# Auth on: the login's 401 has no body of its own, so size alone would reject a healthy locked box.
assert_eq "401 (a healthy, locked dashboard) -> accept" "$(gad 401 0)" "accept"
# Auth OFF is supported — an empty dashboard password is the documented default — so the box that
# answers 200 with a page must pass. That is why this is not a 401 check.
assert_eq "no connection at all -> reject" "$(gad 000 0)" "reject"
assert_eq "an empty code -> reject" "$(gad '' 0)" "reject"
assert_eq "a 502 from a dead upstream -> reject" "$(gad 502 0)" "reject"
assert_eq "a redirect carrying a body -> accept" "$(gad 308 120)" "accept"
unset -f gad

# dashboard.host is validated as "a hostname or IP address" and explicitly allows colons, so HOST_IP
# can be an IPv6 literal. curl will not take one in --resolve — it rejects the WHOLE option with
# "Couldn't parse CURLOPT_RESOLVE entry" — and an unbracketed literal in the URL reads the port as
# part of the address. Either way the request fails, the gate never passes, and #1065 reboots a
# healthy box: a false RED on this gate is as bad as the false GREEN this issue is about. Measured
# against curl 8.7 before writing these.
# Mutation run: drop the *:* arm of gate_target_url -> the bracketing assertion goes red; make
# gate_resolve_spec answer for every host -> the two literal assertions go red.
# NOT run_sourced: that sources `pithead`, and these live in the boot overlay. (An assert_eq
# expecting "" would pass vacuously against a function that was never defined, so the non-empty
# assertions below are what prove the source landed.)
boot_fn() { # <function> <args...>
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        "$@"
    )
}
gtu() { boot_fn gate_target_url "$@"; }
grs() { boot_fn gate_resolve_spec "$@"; }
assert_eq "a name goes in the URL as-is" "$(gtu https panel.example 443)" "https://panel.example:443/"
assert_eq "an IPv6 literal is bracketed, or the port joins the address" \
    "$(gtu https 2001:db8::1 443)" "https://[2001:db8::1]:443/"
assert_eq "an IPv4 literal needs no brackets" "$(gtu http 192.0.2.5 80)" "http://192.0.2.5:80/"
# --resolve is for names only. It is what keeps a name's dial on loopback without the box having to
# resolve its own mDNS name; a literal is already an address and needs no lookup.
assert_eq "a name gets a --resolve spec pointing at loopback" \
    "$(grs panel.example 443)" "panel.example:443:127.0.0.1"
assert_eq "an IPv6 literal gets NO --resolve (curl cannot parse one)" "$(grs 2001:db8::1 443)" ""
assert_eq "an IPv4 literal gets no --resolve either" "$(grs 192.0.2.5 80)" ""
unset -f gtu grs boot_fn

echo "== unit: os_update_rollback_verdict — the rolled_back verdict, provable without a KVM boot (#1051) =="
# A dashboard-driven install leaves data/os-update/in-flight.json naming the version the machine
# was headed to. If THIS boot's VERSION disagrees, the bootloader already fell back — the update
# failed its health gate, and the verdict belongs in the state file now. Before #1051 this was
# inline code that only ran when pithead-boot was EXECUTED, never sourced, so no tier could ever
# drive it with a fixture — genuinely untested, at every tier, despite being promised in two
# operator-facing docs. It is pure file logic (an in-flight flag, a VERSION file, one jq call), so
# nothing here needs real firmware or a real A/B updater to prove; #1051 pulled it into a function
# for exactly that reason.
# Mutation run: flip the != to = in os_update_rollback_verdict's version check -> both assertions
# below invert (a real fallback stays silent, a real landing wrongly claims rollback).
ORV="$SANDBOX/os-rollback-verdict"
orv_run() { # <running-version> [inflight-to] -> "<outcome> <in-flight-consumed>"
    rm -rf "$ORV"
    mkdir -p "$ORV/data/os-update" "$ORV/data/control/results"
    printf '%s\n' "$1" >"$ORV/VERSION"
    # "consumed" has to mean the flag EXISTED and the function REMOVED it — checking only
    # post-call existence conflates that with "there was never a flag to remove", so the
    # no-flag case wrongly read back as consumed. had_flag pins the before state.
    local had_flag=no
    if [ -n "${2:-}" ]; then
        printf '{"from":"1.0.0","to":"%s"}\n' "$2" >"$ORV/data/os-update/in-flight.json"
        had_flag=yes
    fi
    (
        cd "$ORV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_rollback_verdict >/dev/null
    )
    local outcome consumed=no
    outcome=$(jq -r '.verdict.outcome // "none"' "$ORV/data/control/results/os-update-state.json" 2>/dev/null)
    [ "$had_flag" = yes ] && [ ! -f "$ORV/data/os-update/in-flight.json" ] && consumed=yes
    printf '%s %s' "${outcome:-none}" "$consumed"
}
assert_eq "a fallback boot (running the OLD version) writes rolled_back and consumes the flag" \
    "$(orv_run 1.2.3 1.2.4)" "rolled_back yes"
assert_eq "a landed boot (running matches the target) writes nothing here — the commit gate's success half owns it" \
    "$(orv_run 1.2.4 1.2.4)" "none no"
assert_eq "no in-flight flag at all is a no-op" "$(orv_run 1.2.3)" "none no"
unset -f orv_run
unset ORV

echo "== unit: revenue_container_verdict — commit-gate honesty, syncing vs crashed (#852) =="
# The pure classifier behind check_revenue_containers, so the commit gate's central judgement is
# tested without a running stack. Two rules it must hold:
#   1. a crashed/unhealthy CHAIN node (monerod/tari/wallets) is a fault — the slot must not commit;
#   2. a DOWN sync-gated miner (p2pool/xmrig-proxy) is the deliberate #35 hold, not a fault — so a
#      days-long initial sync still commits. Only a running-but-unhealthy miner is a fault.
rcv() { run_sourced "$SANDBOX" revenue_container_verdict "$@"; }
# Chain nodes: healthy commits, everything short of running-and-healthy holds.
assert_eq "monerod up+healthy -> ok" "$(rcv monerod running 'Up 5 minutes (healthy)')" "ok"
assert_contains "monerod exited -> fail" "$(rcv monerod exited 'Exited (0) 1 minute ago')" "fail:monerod"
assert_contains "monerod running+unhealthy -> fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)')" "fail:monerod"
assert_contains "monerod still starting -> fail (loop retries, never commits early)" "$(rcv monerod running 'Up 8 seconds (starting)')" "fail:monerod"
assert_eq "tari up+healthy -> ok" "$(rcv tari running 'Up 3 minutes (healthy)')" "ok"
assert_contains "wallet-rpc down -> fail (chain-side must be up)" "$(rcv wallet-rpc created 'Created')" "fail:wallet-rpc"
# Sync-gated miners: down is the #35 hold (ok); only running-but-unhealthy is a fault.
assert_eq "p2pool exited (sync hold) -> ok" "$(rcv p2pool exited 'Exited (0) 4 minutes ago')" "ok"
assert_eq "p2pool created (never started, held) -> ok" "$(rcv p2pool created 'Created')" "ok"
assert_eq "p2pool up+healthy -> ok" "$(rcv p2pool running 'Up 6 minutes (healthy)')" "ok"
assert_contains "p2pool running+unhealthy -> fail" "$(rcv p2pool running 'Up 30 seconds (unhealthy)')" "fail:p2pool"
assert_eq "xmrig-proxy down (sync hold) -> ok" "$(rcv xmrig-proxy exited 'Exited (0) 4 minutes ago')" "ok"
# Non-revenue containers are out of scope — the rest of doctor covers them.
assert_eq "caddy (not revenue) -> ok" "$(rcv caddy running 'Up 5 minutes')" "ok"
assert_eq "dashboard (not revenue) -> ok" "$(rcv dashboard running 'Up 5 minutes (healthy)')" "ok"
# The migration hold (#851): with chain_hold=1 a chain node is judged by the miners' rule — the
# boot path is deliberately withholding it, so down is expected and the commit must not deadlock
# on the very hold it gates. A RUNNING-but-unhealthy chain node is still a fault.
assert_eq "monerod down under the migration hold -> ok" "$(rcv monerod exited 'Exited (0) 1 minute ago' 1)" "ok"
assert_eq "tari never created under the migration hold -> ok" "$(rcv tari created 'Created' 1)" "ok"
assert_eq "wallet-rpc down under the migration hold -> ok" "$(rcv wallet-rpc exited 'Exited (0) 2 minutes ago' 1)" "ok"
assert_contains "monerod running+unhealthy under the hold -> still fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)' 1)" "fail:monerod"
assert_eq "monerod up+healthy under the hold -> ok (an early manual start is not a fault)" "$(rcv monerod running 'Up 5 minutes (healthy)' 1)" "ok"
assert_contains "the hold changes nothing for a miner" "$(rcv p2pool running 'Up 30 seconds (unhealthy)' 1)" "fail:p2pool"
unset -f rcv

echo "== unit: pithead-sync's rigforge leg — program replaced, state preserved, prebuilt seeded =="
# The baked tree is program; config.json (pithead-rendered) and the data/ workspace (the XMRig
# build cache) are state. The prebuilt binary seeds the workspace so the appliance never needs
# RigForge's clone path — github over clearnet, unreachable from a Tor-only box.
SYNCSCRIPT="$ROOT/os/overlay/pithead-sync"
SSB=$(mktemp -d)
mkdir -p "$SSB/opt-pithead" "$SSB/opt-rigforge/util" "$SSB/opt-rigforge/prebuilt/xmrig/build"
for f in pithead pithead-completion.bash VERSION docker-compose.yml \
    config.reference.json config.core-keys.json config.minimal.json cosign.pub; do
    printf 'pithead-program' >"$SSB/opt-pithead/$f"
done
printf 'program-v2' >"$SSB/opt-rigforge/rigforge.sh"
chmod +x "$SSB/opt-rigforge/rigforge.sh"
printf 'helper' >"$SSB/opt-rigforge/util/proposed-grub.sh"
printf 'bin-v2' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'commit-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'sha-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-sha256"
run_sync() {
    PITHEAD_SYNC_SRC="$SSB/opt-pithead" PITHEAD_SYNC_DST="$SSB/data/pithead" \
        PITHEAD_SYNC_RIGFORGE_SRC="$SSB/opt-rigforge" PITHEAD_SYNC_RIGFORGE_DST="$SSB/data/rigforge" \
        bash "$SYNCSCRIPT"
}
run_sync >/dev/null 2>&1
assert_rc "sync runs clean" "$?" "0"
[ -x "$SSB/data/rigforge/rigforge.sh" ] && ok "rigforge program delivered beside pithead's" ||
    bad "rigforge program delivered beside pithead's" "missing"
assert_eq "prebuilt seeded into the workspace where 'already built' finds it" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig" 2>/dev/null)" "bin-v2"
assert_eq "the commit marker rides with the seed" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/.rigforge-commit" 2>/dev/null)" "commit-B"
[ -e "$SSB/data/rigforge/prebuilt" ] && bad "prebuilt/ is a seed, never a synced tree" "synced" ||
    ok "prebuilt/ is a seed, never a synced tree"
# State survives a re-run: the rendered config and a native rebuild of the SAME pin stay put.
printf '{"pools":[{"url":"127.0.0.1:3333"}]}' >"$SSB/data/rigforge/config.json"
printf 'native-rebuild' >"$SSB/data/rigforge/data/worker/xmrig/build/xmrig"
run_sync >/dev/null 2>&1
assert_eq "config.json (state) survives the resync" \
    "$(cat "$SSB/data/rigforge/config.json")" '{"pools":[{"url":"127.0.0.1:3333"}]}'
assert_eq "a same-pin native rebuild is left alone" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "native-rebuild"
# A new pin arrives with a new image AND its new prebuilt: the cached build is replaced, so the
# on-box clone path never needs to run.
printf 'commit-C\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'bin-v3' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'program-v3' >"$SSB/opt-rigforge/rigforge.sh"
run_sync >/dev/null 2>&1
assert_eq "a new pin replaces the cached build with the new prebuilt" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "bin-v3"
assert_eq "program files are replaced wholesale" "$(cat "$SSB/data/rigforge/rigforge.sh")" "program-v3"
# An image without the bake (downgrade, older layout): the leg skips cleanly.
rm -rf "$SSB/opt-rigforge"
run_sync >/dev/null 2>&1
assert_rc "no baked tree -> the leg is skipped, sync still clean" "$?" "0"
unset -f run_sync
rm -rf "$SSB"
unset SSB SYNCSCRIPT

echo "== unit: optimize_kernel's HugePages write is grow-only =="
# With a co-located miner the pool is shared and RigForge (grow-only by design) sizes it as the
# single writer — pithead writing its absolute 3072 on top would shrink a grown pool to the
# in-use floor and starve whichever side restarts next.
OKSB=$(mktemp -d)
mkdir -p "$OKSB/bin"
printf '#!/usr/bin/env bash\necho "sudo:$*" >>"${OKLOG:?}"\n' >"$OKSB/bin/sudo"
# OS_TYPE is readonly once sourced, so the Linux arm is selected the way pcr791 does it: a
# stubbed uname on PATH before the source.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec /usr/bin/uname "$@"\n' >"$OKSB/bin/uname"
chmod +x "$OKSB/bin/sudo" "$OKSB/bin/uname"
export OKLOG="$OKSB/calls"
okrun() { # <pages currently in the pool> [degrade-marker file]
    printf '%s\n' "$1" >"$OKSB/nr"
    (
        cd "$OKSB" || exit
        PATH="$OKSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        PITHEAD_NR_HUGEPAGES_FILE="$OKSB/nr" PITHEAD_HUGEPAGES_MARKER="${2:-$OKSB/no-marker}" \
            optimize_kernel </dev/null
    )
}
: >"$OKLOG"
okrun 100 >/dev/null 2>&1
assert_contains "a small pool is grown to the stack's budget" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=3072"
: >"$OKLOG"
okrun 4000 >/dev/null 2>&1
assert_not_contains "a larger pool (the miner's merged budget) is never shrunk" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 3072 >/dev/null 2>&1
assert_not_contains "an exact pool is left alone" "$(cat "$OKLOG")" "vm.nr_hugepages"
# The degrade cap (#977): the boot-time sizing's marker records the chosen page count, and that
# record caps the grow. Without it the wizard-accept path (setup runs as root on the appliance)
# re-inflated the pool the sizing had just shrunk, while the marker and doctor kept saying
# "reduced". A pool at the recorded size is left alone; one below it grows only to the record.
printf 'reduced-reservation words for the operator\npages=2560\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 2560 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a marker-sized pool is never re-inflated to the full budget" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 100 "$OKSB/marker" >/dev/null 2>&1
assert_contains "a pool below the record grows to the record" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=2560"
assert_not_contains "the grow never passes the marker's cap" "$(cat "$OKLOG")" "3072"
printf 'released-reservation words\npages=0\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 0 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a released (0-page) decision writes nothing at all" "$(cat "$OKLOG")" "vm.nr_hugepages"
unset OKLOG
unset -f okrun
rm -rf "$OKSB"
unset OKSB

echo "== unit: os-update variant gate — SSH posture flips in EITHER direction need consent =="
# The trap this guards, both ways: a debug image's SSH key is often the only management channel and
# a release bundle removes it BY DESIGN (losing a shell); a debug bundle onto a hardened release box
# bakes a standing root authorized_keys + sshd (GAINING a shell, #854). Either flip, and any bundle
# whose stamp can't be verified, must confirm; a same-variant install must not.
# Losing the shell (a KNOWN debug box installing something non-debug):
run_sourced "$SANDBOX" os_update_needs_confirmation debug release
assert_rc "debug system + release bundle -> confirmation required" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation debug unknown
assert_rc "debug system + unstamped bundle -> confirmation required" "$?" "0"
# Gaining a shell (a non-debug box installing a debug bundle) — the #854 direction:
run_sourced "$SANDBOX" os_update_needs_confirmation release debug
assert_rc "release system + debug bundle -> confirmation required (gains root SSH)" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown debug
assert_rc "unstamped system + debug bundle -> confirmation required (gains root SSH)" "$?" "0"
# Unverified bundle onto a non-debug box: the stamp could hide a debug build, so confirm.
run_sourced "$SANDBOX" os_update_needs_confirmation release unknown
assert_rc "release system + unstamped bundle -> confirmation required (posture unverifiable)" "$?" "0"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown unknown
assert_rc "unstamped system + unstamped bundle -> confirmation required (posture unverifiable)" "$?" "0"
# Same-posture installs pass without ceremony:
run_sourced "$SANDBOX" os_update_needs_confirmation debug debug
assert_rc "debug -> debug passes without ceremony" "$?" "1"
run_sourced "$SANDBOX" os_update_needs_confirmation release release
assert_rc "release -> release passes (the fleet's normal update)" "$?" "1"
run_sourced "$SANDBOX" os_update_needs_confirmation unknown release
assert_rc "unstamped system + release bundle passes — stays shell-less, no channel flips" "$?" "1"

OUSB=$(mktemp -d)
mkdir -p "$OUSB/bin"
# A fake rauc: logs every call, answers `info` with a canned shell-format body —
# the format the real os_bundle_meta parses (RAUC 1.11's JSON output omits [meta.*]). Two escape
# hatches for #1041's error-surfacing tests: RAUC_INFO_RC/RAUC_INFO_ERR fail `info` (a signature
# verdict) with a chosen message on stderr, RAUC_INSTALL_RC/RAUC_INSTALL_ERR do the same for
# `install`. Both default to a clean 0/no-output — every test above this one never sets them.
#
# RAUC_INFO_OUT_JSON (#1093): most callers below never set this, so `info` behaves exactly as
# before — cat RAUC_INFO_OUT regardless of the `--output-format` the caller actually passed,
# which is precisely the gap #1093 named: a caller that regressed to --output-format=json would
# still get the hand-written shell-format fixture back, so the drift could never turn any
# assertion red. The migration-floor real-fixture block below sets RAUC_INFO_OUT_JSON so `info`
# answers format-honestly: shell gets RAUC_INFO_OUT, json gets RAUC_INFO_OUT_JSON — two REAL
# `rauc info` captures of the same bundle (tests/stack/fixtures/rauc-info/), not two hand-written
# stand-ins that already agree with the parser by construction.
cat >"$OUSB/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    fmt=shell
    for _a in "$@"; do case "$_a" in --output-format=*) fmt="${_a#--output-format=}" ;; esac; done
    if [ -n "${RAUC_INFO_OUT_JSON:-}" ] && [ "$fmt" = json ]; then
        [ -s "$RAUC_INFO_OUT_JSON" ] && cat "$RAUC_INFO_OUT_JSON"
    else
        [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    fi
    [ -n "${RAUC_INFO_ERR:-}" ] && echo "$RAUC_INFO_ERR" >&2
    exit "${RAUC_INFO_RC:-0}"
    ;;
install)
    [ -n "${RAUC_INSTALL_ERR:-}" ] && echo "$RAUC_INSTALL_ERR" >&2
    exit "${RAUC_INSTALL_RC:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$OUSB/bin/rauc"
touch "$OUSB/bundle.raucb"
export RAUC_LOG="$OUSB/calls"

printf 'debug\n' >"$OUSB/variant-debug"
printf 'release\n' >"$OUSB/variant-release"
printf 'mystery\n' >"$OUSB/variant-garbage"
assert_eq "running variant read from the stamp file" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/variant-debug run_sourced "$SANDBOX" os_running_variant)" "debug"
assert_eq "a garbage stamp degrades to unknown, never to a variant" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/variant-garbage run_sourced "$SANDBOX" os_running_variant)" "unknown"
assert_eq "a missing stamp file is unknown (pre-stamp images)" \
    "$(PITHEAD_VARIANT_FILE=$OUSB/nope run_sourced "$SANDBOX" os_running_variant)" "unknown"

ourun() { # <variant-file> <info-json-file or empty> [os-update args...] — stdin closed (no tty)
    local vf="$1" ij="$2"
    shift 2
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        RAUC_INFO_OUT="$ij" PITHEAD_VARIANT_FILE="$vf" \
            PITHEAD_MIGRATION_MARKER_FILE="$OUSB/marker-scratch" os_update "$@" </dev/null
    )
}
printf "RAUC_META_PITHEAD_VARIANT='release'\n" >"$OUSB/info-release.txt"
printf "RAUC_META_PITHEAD_VARIANT='debug'\n" >"$OUSB/info-debug.txt"
assert_eq "bundle variant parsed from rauc info shell output" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$OUSB/info-release.txt" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "release"
assert_eq "bundle variant parse reads the debug stamp" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$OUSB/info-debug.txt" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "debug"
assert_eq "an unstamped bundle is unknown" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="" run_sourced "$OUSB" os_bundle_variant bundle.raucb)" "unknown"

# The command end to end, with the daemon stubbed. Non-interactive stdin means the prompt reads
# EOF -> cancelled: precisely the automation case where a silent install would strand the box.
: >"$RAUC_LOG"
out=$(ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" bundle.raucb 2>&1)
rc=$?
assert_rc "debug box + release bundle, no --yes -> refused" "$rc" "1"
assert_contains "the refusal names the SSH loss" "$out" "removes SSH"
assert_not_contains "rauc install was NOT reached" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" bundle.raucb --yes >/dev/null 2>&1
assert_rc "--yes acknowledges the warning and proceeds" "$?" "0"
assert_contains "rauc install ran with the bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# The #854 direction: a hardened release box taking a debug bundle GAINS a root SSH backdoor. Non-
# interactive stdin reads EOF -> refused, and rauc install must never be reached — the silent
# install is exactly the backdoor this guards.
: >"$RAUC_LOG"
out=$(ourun "$OUSB/variant-release" "$OUSB/info-debug.txt" bundle.raucb 2>&1)
rc=$?
assert_rc "release box + debug bundle, no --yes -> refused" "$rc" "1"
assert_contains "the refusal names the root SSH it would gain" "$out" "root SSH"
assert_not_contains "rauc install was NOT reached on the gain-a-shell refusal" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun "$OUSB/variant-release" "$OUSB/info-debug.txt" bundle.raucb --yes >/dev/null 2>&1
assert_rc "--yes acknowledges the backdoor warning and proceeds" "$?" "0"
assert_contains "rauc install ran with the debug bundle after --yes" "$(cat "$RAUC_LOG")" "install bundle.raucb"
: >"$RAUC_LOG"
ourun "$OUSB/variant-release" "$OUSB/info-release.txt" bundle.raucb >/dev/null 2>&1
assert_rc "release -> release installs with no prompt" "$?" "0"
assert_contains "rauc install ran unprompted" "$(cat "$RAUC_LOG")" "install bundle.raucb"
out=$(ourun "$OUSB/variant-debug" "$OUSB/info-release.txt" 2>&1)
assert_rc "a missing bundle path is an error, not an install" "$?" "1"

echo "== unit: os_bundle_meta degrades to empty instead of aborting the caller (#1041) =="
# run_sourced (used everywhere above) disables errexit right after sourcing, which would hide
# the exact bug #1041 traces to: under `set -o pipefail`, `rauc info | sed | head` returns rauc's
# own nonzero exit even though sed/head both succeed, and a bare `var=$(os_bundle_meta ...)`
# assignment then trips `set -e` — silently, since the diagnostic went to `2>/dev/null`. This
# check keeps errexit ON (the real pithead script's own posture) so a regression here reproduces
# the actual failure: the subshell would abort before ever reaching the second echo.
: >"$RAUC_LOG"
ombm_out=$(
    cd "$OUSB" || exit 1
    PATH="$OUSB/bin:$PATH"
    export RAUC_INFO_RC=1 RAUC_INFO_OUT="" RAUC_INFO_ERR="signature verification failed: self-signed certificate"
    # shellcheck disable=SC1090
    source "$STACK"
    echo "before"
    v=$(os_bundle_meta bundle.raucb version)
    echo "after:[$v]"
)
ombm_rc=$?
assert_rc "a failing rauc info does not abort the caller under errexit+pipefail" "$ombm_rc" "0"
assert_contains "execution continues past the failed call" "$ombm_out" "after:[]"

echo "== integration: os-update surfaces rauc's own diagnosis instead of a bare abort (#1041) =="
# The bug as filed: a signature failure inside a command substitution (os_bundle_meta, above)
# tripped the ERR trap with nothing to show for it — three bare "aborted unexpectedly" lines and
# no clue rauc had already diagnosed it precisely on its own stderr. Runs the REAL script as a
# subprocess (not sourced) so the ERR trap this bug lives in is actually armed.
OUB=$(mktemp -d)
mkdir -p "$OUB/bin"
cp "$STACK" "$OUB/pithead"
chmod +x "$OUB/pithead"
cp "$OUSB/bin/rauc" "$OUB/bin/rauc"
chmod +x "$OUB/bin/rauc"
touch "$OUB/bundle.raucb"
: >"$OUB/calls"
out=$(cd "$OUB" && PATH="$OUB/bin:$PATH" RAUC_LOG="$OUB/calls" \
    RAUC_INFO_RC=1 RAUC_INFO_ERR="signature verification failed: Verify error: self-signed certificate" \
    ./pithead os-update bundle.raucb --yes 2>&1)
rc=$?
assert_rc "a bad-signature bundle refuses the update" "$rc" "1"
assert_contains "rauc's own diagnosis reaches the operator" "$out" "self-signed certificate"
assert_not_contains "the generic contentless abort does not ALSO fire" "$out" "aborted unexpectedly"
assert_not_contains "rauc install is never reached on a bad signature" "$(cat "$OUB/calls")" "install"
rm -rf "$OUB"

echo "== unit: os-update surfaces rauc install's own stderr, not just a bare failure (#1041) =="
: >"$RAUC_LOG"
out=$(
    cd "$OUSB" || exit 1
    PATH="$OUSB/bin:$PATH"
    export RAUC_INFO_OUT="$OUSB/info-release.txt" PITHEAD_VARIANT_FILE="$OUSB/variant-release"
    export PITHEAD_MIGRATION_MARKER_FILE="$OUSB/marker-scratch"
    export RAUC_INSTALL_RC=1 RAUC_INSTALL_ERR="LastError: mounting slot failed: no such device"
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    os_update bundle.raucb --yes </dev/null 2>&1
)
rc=$?
assert_rc "an install-time rauc failure is refused, not silently ignored" "$rc" "1"
assert_contains "rauc's install-time diagnosis reaches the operator" "$out" "mounting slot failed"
unset RAUC_INFO_RC RAUC_INFO_ERR RAUC_INSTALL_RC RAUC_INSTALL_ERR

# --- os-update version floor + data-migration guards (#856 downgrade, #851 migration deadlock) ---
# A correctly-signed bundle is not automatically a safe one: an OLDER image re-opens fixed holes,
# and an image below the /data migration floor cannot read the chain data a newer release migrated.
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-1170.txt"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.10.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-1100.txt"
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0'\nRAUC_META_PITHEAD_DATA_MIGRATION='true'\nRAUC_META_PITHEAD_MINIMUM_OS_VERSION='1.17.0'\n" >"$OUSB/info-mig.txt"

# os_bundle_meta: the manifest fields read back out of `rauc info` JSON.
ometa() { cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$1" run_sourced "$OUSB" os_bundle_meta bundle.raucb "$2"; }
# render_bundle_manifest: the WRITE side of the manifest (the read side is os_bundle_meta below).
# RAUC refuses a key with an empty value, so an ordinary non-migrating build must omit the floor
# entirely — emitting `minimum_os_version=` unconditionally broke every plain bundle build, and
# the stubbed rauc in these tests never saw it. Assert the rendered text directly.
plain_manifest="$(cd "$ROOT" && . os/rauc/populate-slot.sh && render_bundle_manifest 1.17.0 release false "")"
assert_not_contains "plain build omits the migration floor entirely (no empty-valued key)" \
    "$plain_manifest" "minimum_os_version"
assert_contains "plain build still carries the version" "$plain_manifest" "version=1.17.0"
assert_contains "plain build still carries the variant" "$plain_manifest" "variant=release"
assert_contains "plain build declares no migration" "$plain_manifest" "data_migration=false"
mig_manifest="$(cd "$ROOT" && . os/rauc/populate-slot.sh && render_bundle_manifest 1.18.0 release true 1.18.0)"
assert_contains "a migrating build names its floor" "$mig_manifest" "minimum_os_version=1.18.0"
# No key may ever render with an empty value — that is the exact shape rauc rejects.
if printf '%s\n' "$plain_manifest" "$mig_manifest" | grep -qE '^[a-z_]+=$'; then
    bad "no manifest key renders with an empty value" "found one"
else
    ok "no manifest key renders with an empty value"
fi

assert_eq "os_bundle_meta reads version" "$(ometa "$OUSB/info-mig.txt" version)" "1.17.0"
assert_eq "os_bundle_meta reads data_migration" "$(ometa "$OUSB/info-mig.txt" data_migration)" "true"
assert_eq "os_bundle_meta reads minimum_os_version" "$(ometa "$OUSB/info-mig.txt" minimum_os_version)" "1.17.0"
assert_eq "an absent meta key is empty, not an error" "$(ometa "$OUSB/info-mig.txt" db_schema)" ""
unset -f ometa

# ourun_v: os_update with a set running version + a data-floor file, variant pinned to release
# (the SSH gate is covered above; here we isolate the version/floor guards).
ourun_v() { # <running-version> <floor-file> <info-json> [os-update args...]
    local rv="$1" ff="$2" ij="$3"
    shift 3
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_VERSION="$rv" PITHEAD_DATA_FLOOR_FILE="$ff" \
            PITHEAD_MIGRATION_MARKER_FILE="${MARKER_FILE:-$OUSB/marker-scratch}" \
            RAUC_INFO_OUT="$ij" PITHEAD_VARIANT_FILE="$OUSB/variant-release" os_update "$@" </dev/null
    )
}

# #856: an older bundle is refused, and rauc install is never reached.
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "" "$OUSB/info-1100.txt" bundle.raucb 2>&1)
assert_rc "a bundle older than running is refused" "$?" "1"
assert_contains "the refusal names the downgrade" "$out" "possible downgrade"
assert_not_contains "rauc install was NOT reached on a refused downgrade" "$(cat "$RAUC_LOG")" "install"
# ...unless --allow-downgrade is passed on purpose.
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-1100.txt" bundle.raucb --allow-downgrade >/dev/null 2>&1
assert_rc "--allow-downgrade installs the older bundle" "$?" "0"
assert_contains "rauc install ran under --allow-downgrade" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# A newer bundle installs with no ceremony.
: >"$RAUC_LOG"
ourun_v "1.10.0" "" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a newer bundle installs" "$?" "0"
assert_contains "rauc install ran for the newer bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"
# The CLI door keeps same-version installs — manual slot repair at the machine is its job.
# The dashboard door refuses equality (covered in the control os-* block below).
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a same-version bundle installs at the CLI (slot repair)" "$?" "0"
assert_contains "rauc install ran for the same-version bundle" "$(cat "$RAUC_LOG")" "install bundle.raucb"

# #851: below the /data migration floor is refused OUTRIGHT — --allow-downgrade does not override it.
printf '2.0.0\n' >"$OUSB/floor-2"
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "$OUSB/floor-2" "$OUSB/info-1170.txt" bundle.raucb --allow-downgrade 2>&1)
assert_rc "a bundle below the /data floor is refused even with --allow-downgrade" "$?" "1"
assert_contains "the floor refusal warns about the chain data" "$out" "strand the chain data"
assert_not_contains "rauc install was NOT reached below the floor" "$(cat "$RAUC_LOG")" "install"
# A bundle at or above the floor installs.
printf '1.17.0\n' >"$OUSB/floor-at"
: >"$RAUC_LOG"
ourun_v "1.17.0" "$OUSB/floor-at" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a bundle at the /data floor installs" "$?" "0"

# #851: installing a data_migration bundle RECORDS the floor; a plain bundle does not.
FW="$OUSB/floor-written"
rm -f "$FW"
: >"$RAUC_LOG"
ourun_v "1.17.0" "$FW" "$OUSB/info-mig.txt" bundle.raucb >/dev/null 2>&1
assert_rc "a data_migration bundle installs" "$?" "0"
assert_eq "installing a data_migration bundle records the /data floor" "$(tr -d ' \n' <"$FW" 2>/dev/null)" "1.17.0"
FN="$OUSB/floor-none"
rm -f "$FN"
ourun_v "1.10.0" "$FN" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a non-migration bundle records no floor" "$([ -f "$FN" ] && echo present || echo absent)" "absent"

echo "== unit: os_bundle_meta pinned against REAL rauc info output, not a hand-written stand-in (#1093) =="
# Every info-*.txt fixture above is hand-typed RAUC_META_PITHEAD_KEY='value' text, invented to
# already match the sed pattern it feeds — it can never catch a real parse drift. #1093: RAUC
# 1.11's --output-format=json OMITS [meta.*] entirely (the drift os_bundle_meta's comment already
# names), and the fake rauc's `info` case never looked at --output-format at all, so a caller that
# regressed to json would still get the shell-format fixture back — invisible to every assertion
# above. tests/stack/fixtures/rauc-info/*.txt are genuine `rauc info` captures off a bundle built
# from the real render_bundle_manifest (see capture.sh for the recipe and refresh instructions),
# and the fake rauc now answers format-honestly (RAUC_INFO_OUT for shell, RAUC_INFO_OUT_JSON for
# json) — so this block proves the parse against real tool output, both shapes.
RIS="$ROOT/tests/stack/fixtures/rauc-info/rauc-info-migration.shell.txt"
RIJ="$ROOT/tests/stack/fixtures/rauc-info/rauc-info-migration.json.txt"
if [ -s "$RIS" ] && [ -s "$RIJ" ]; then
    ok "real rauc-info fixtures present ($RIS, $RIJ)"
else
    bad "real rauc-info fixtures present" "missing $RIS or $RIJ"
fi

rmeta() { # <key> — both real fixtures loaded together, so the format os_bundle_meta's own argv
    # actually requests decides which one the fake rauc serves. A caller that regressed from
    # --output-format=shell to json would silently start reading the json capture here instead —
    # empty meta, not the pinned value — which is exactly the drift this block exists to catch.
    cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$RIS" RAUC_INFO_OUT_JSON="$RIJ" \
        run_sourced "$OUSB" os_bundle_meta bundle.raucb "$1"
}
assert_eq "real bundle: os_bundle_meta reads variant off genuine shell output" \
    "$(rmeta variant)" "release"
assert_eq "real bundle: os_bundle_meta reads data_migration off genuine shell output" \
    "$(rmeta data_migration)" "true"
assert_eq "real bundle: os_bundle_meta reads minimum_os_version off genuine shell output" \
    "$(rmeta minimum_os_version)" "1.18.0"
# The drift itself, in isolation: pointed at ONLY the real json capture (RAUC 1.11's own shape —
# [meta.*] entirely absent), the parse must degrade to empty — fail-closed "unstamped", never a
# wrong-but-plausible value — regardless of which format asked for it.
assert_eq "the real json capture alone has no meta section to read" \
    "$(cd "$OUSB" && PATH="$OUSB/bin:$PATH" RAUC_INFO_OUT="$RIJ" RAUC_INFO_OUT_JSON="" \
        run_sourced "$OUSB" os_bundle_meta bundle.raucb minimum_os_version)" ""
unset -f rmeta

# os_raise_data_floor, driven end to end by the REAL fixture through os_update: a migrating bundle
# whose meta the genuine shell-format capture carries must record the floor at the value the real
# bundle actually declares (1.18.0), not a hand-typed stand-in.
ourun_v_realfixture() { # <running-version> <floor-file> <shell-fixture> <json-fixture> [os-update args...]
    local rv="$1" ff="$2" ijs="$3" ijj="$4"
    shift 4
    (
        cd "$OUSB" || exit
        PATH="$OUSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_VERSION="$rv" PITHEAD_DATA_FLOOR_FILE="$ff" \
            PITHEAD_MIGRATION_MARKER_FILE="${MARKER_FILE:-$OUSB/marker-scratch}" \
            RAUC_INFO_OUT="$ijs" RAUC_INFO_OUT_JSON="$ijj" \
            PITHEAD_VARIANT_FILE="$OUSB/variant-release" os_update "$@" </dev/null
    )
}
FWR="$OUSB/floor-written-real"
rm -f "$FWR"
: >"$RAUC_LOG"
ourun_v_realfixture "1.10.0" "$FWR" "$RIS" "$RIJ" bundle.raucb >/dev/null 2>&1
assert_rc "the real migrating bundle installs" "$?" "0"
assert_eq "the real bundle's own declared floor is recorded, not a stand-in value" \
    "$(tr -d ' \n' <"$FWR" 2>/dev/null)" "1.18.0"
unset -f ourun_v_realfixture
unset RIS RIJ FWR

# #851 marker lifecycle: a migrating install leaves the pending marker (stamped with the bundle's
# version) for the next boot's chain hold; a non-migrating install clears a stale one — it
# supersedes a migrating install that never booted.
MK="$OUSB/marker-mig"
rm -f "$MK"
MARKER_FILE="$MK" ourun_v "1.10.0" "$OUSB/floor-scratch" "$OUSB/info-mig.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a data_migration install writes the pending marker with the bundle version" "$(tr -d ' \n' <"$MK" 2>/dev/null)" "1.17.0"
MARKER_FILE="$MK" ourun_v "1.10.0" "$OUSB/floor-scratch" "$OUSB/info-1170.txt" bundle.raucb >/dev/null 2>&1
assert_eq "a non-migrating install clears a stale pending marker" "$([ -f "$MK" ] && echo present || echo absent)" "absent"

# The hold query the boot path and doctor share: active only when the marker matches the RUNNING
# version — a mismatched marker is a fallback boot onto untouched data and must not hold anything.
omh() { # <marker-content-or-ABSENT> <running-version>
    local mf="$OUSB/marker-q"
    rm -f "$mf"
    [ "$1" != "ABSENT" ] && printf '%s\n' "$1" >"$mf"
    (
        cd "$OUSB" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_MIGRATION_MARKER_FILE="$mf" PITHEAD_VERSION="$2" os_migration_hold_active
    )
}
omh "1.17.0" "1.17.0"
assert_rc "hold active: marker matches the running version" "$?" "0"
omh "1.17.0" "1.16.0"
assert_rc "no hold: marker for another version (fallback boot)" "$?" "1"
omh "ABSENT" "1.17.0"
assert_rc "no hold: no marker" "$?" "1"
omh "" "1.17.0"
assert_rc "no hold: empty marker is not a version match" "$?" "1"
unset -f omh

# Fail-closed: a version the comparator can't parse is NOT proof of safety. Releases DO use -prep
# tags, so a pre-release bundle must not silently bypass the downgrade guard by parsing as "0".
printf "RAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='1.17.0-prep'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OUSB/info-prep.txt"
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "" "$OUSB/info-prep.txt" bundle.raucb 2>&1)
assert_rc "a pre-release (-prep) bundle is refused fail-closed" "$?" "1"
assert_contains "the refusal names it a possible downgrade" "$out" "possible downgrade"
assert_not_contains "rauc install was NOT reached for the pre-release bundle" "$(cat "$RAUC_LOG")" "install"
: >"$RAUC_LOG"
ourun_v "1.17.0" "" "$OUSB/info-prep.txt" bundle.raucb --allow-downgrade >/dev/null 2>&1
assert_rc "--allow-downgrade installs the pre-release bundle on purpose" "$?" "0"
assert_contains "rauc install ran for the pre-release under --allow-downgrade" "$(cat "$RAUC_LOG")" "install bundle.raucb"

# Fail-closed: a corrupt floor file is NOT permission to downgrade past a migration.
printf 'not-a-version\n' >"$OUSB/floor-corrupt"
: >"$RAUC_LOG"
out=$(ourun_v "1.17.0" "$OUSB/floor-corrupt" "$OUSB/info-1170.txt" bundle.raucb --allow-downgrade 2>&1)
assert_rc "a corrupt /data floor is refused fail-closed, even with --allow-downgrade" "$?" "1"
assert_contains "the corrupt-floor refusal says the floor is unreadable" "$out" "floor is unreadable"
assert_not_contains "rauc install was NOT reached with a corrupt floor" "$(cat "$RAUC_LOG")" "install"
unset -f ourun_v

unset RAUC_LOG
unset -f ourun
rm -rf "$OUSB"
unset OUSB

echo "== black-box: control os-update verbs (appliance A/B, dashboard-driven) =="
# A release-shaped appliance sandbox: control channel on, PITHEAD_APPLIANCE forced, and the whole
# toolchain stubbed (rauc/curl/systemctl/df) so every refusal and the full check → download →
# verify → install → reboot chain runs for real with no network, no RAUC, no root.
OSC="$SANDBOX/os-control"
OSREQS="$OSC/data/control/requests"
OSRES="$OSC/data/control/results"
OSSTATE="$OSRES/os-update-state.json"
OSDIR="$OSC/osdir"
mkdir -p "$OSREQS" "$OSC/data/control/staged" "$OSRES" "$OSC/data/control/audit" "$OSDIR"
cp "$STACK" "$OSC/pithead"
make_stubs "$OSC/bin"
printf '1.3.1' >"$OSC/VERSION"
printf '{}' >"$OSC/config.json"
cat >"$OSC/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$OSC/data/control
NETWORK_PREFIX=10.9.0
EOF
printf 'release\n' >"$OSC/variant-release"
printf 'compatible=pithead-os\n' >"$OSC/system.conf"
# The published release the stub API serves: tag + the .raucb asset with its size.
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel","assets":[{"name":"pithead-os-v9.9.9.raucb","size":1000}]}' >"$OSC/api.json"
# The 1000-byte bundle fixture the stub curl serves (deterministic bytes so resume can append).
yes x | head -c 1000 >"$OSC/fixture.raucb"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-good.txt"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='debug'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-debug.txt"
printf "RAUC_MF_COMPATIBLE='pithead-os'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.8'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-mismatch.txt"
printf "RAUC_MF_COMPATIBLE='other-machine'\nRAUC_META_PITHEAD_VARIANT='release'\nRAUC_META_PITHEAD_VERSION='9.9.9'\nRAUC_META_PITHEAD_DATA_MIGRATION='false'\n" >"$OSC/info-othercompat.txt"
cat >"$OSC/bin/rauc" <<'EOF'
#!/usr/bin/env bash
echo "[rauc] $*" >>"${RAUC_LOG:?}"
case "$1" in
info)
    [ "${RAUC_RUN_FAIL:-}" = "1" ] && exit 127 # rauc never ran (exec failure), no verdict
    [ "${RAUC_SIG_FAIL:-}" = "1" ] && exit 1
    [ -s "${RAUC_INFO_OUT:-}" ] && cat "$RAUC_INFO_OUT"
    exit 0
    ;;
install)
    [ "${RAUC_INSTALL_FAIL:-}" = "1" ] && {
        echo "slot device /dev/hostdisk3 staging $PWD" # host detail that must stay out of the result
        echo "installing failed"
        exit 1
    }
    echo "installing bundle: 50%"
    echo "installing bundle: 100%"
    exit 0
    ;;
esac
exit 0
EOF
# Stub curl: serves the canned API JSON, and for the bundle URL either appends the fixture's
# remainder onto -o's target (a genuine resume when the partial exists) or, told CURL_RC=28,
# writes CURL_PARTIAL_BYTES and exits like --max-time closing the window mid-transfer.
cat >"$OSC/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
# os-check reads the body AND the status now that it goes through the shared release fetch
# (#1081), so the stub has to answer in the shape `-w '\n%{http_code}'` produces. GH_STUB_CODE
# lets a test drive a non-2xx through the real control path; unset means the ordinary 200.
*api.github.com*)
    cat "${CURL_API_RESPONSE:?}"
    printf '\n%s' "${GH_STUB_CODE:-200}"
    ;;
*releases/download/*)
    if [ "${CURL_RC:-0}" = "28" ]; then
        head -c "${CURL_PARTIAL_BYTES:-300}" "${CURL_BUNDLE:?}" >"$out"
        exit 28
    fi
    have=0
    [ -f "$out" ] && have=$(wc -c <"$out" | tr -d ' ')
    tail -c "+$((have + 1))" "${CURL_BUNDLE:?}" >>"$out"
    ;;
*) exit 22 ;;
esac
exit 0
EOF
cat >"$OSC/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${SYSCTL_LOG:?}"
exit 0
EOF
# Stub df: the headroom gate reads column 4 (Available, KiB) of the second line.
cat >"$OSC/bin/df" <<'EOF'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "fake 1000000 0 ${DF_AVAIL_KB:-999999999} 0% /data"
EOF
chmod +x "$OSC/bin/rauc" "$OSC/bin/curl" "$OSC/bin/systemctl" "$OSC/bin/df"
osrun() { # [env pairs...] — drain the spool inside the appliance sandbox
    (cd "$OSC" && PATH="$OSC/bin:$PATH" RAUC_LOG="$OSC/rauc.log" CURL_LOG="$OSC/curl.log" \
        SYSCTL_LOG="$OSC/sysctl.log" CURL_API_RESPONSE="$OSC/api.json" CURL_BUNDLE="$OSC/fixture.raucb" \
        RAUC_INFO_OUT="$OSC/info-good.txt" PITHEAD_APPLIANCE=1 PITHEAD_OS_UPDATE_DIR="$OSDIR" \
        PITHEAD_VARIANT_FILE="$OSC/variant-release" PITHEAD_DATA_FLOOR_FILE="$OSC/floor" \
        PITHEAD_RAUC_SYSTEM_CONF="$OSC/system.conf" PITHEAD_OS_DL_ATTEMPT=60 \
        PITHEAD_MIGRATION_MARKER_FILE="$OSC/marker-scratch" \
        env "$@" ./pithead control-run-pending 2>&1)
}
os_intent() { # <id> <action> [version]
    if [ "$#" -ge 3 ]; then
        printf '{"id":"%s","action":"%s","actor":"admin","version":"%s"}\n' "$1" "$2" "$3" >"$OSREQS/$1.json"
    else
        printf '{"id":"%s","action":"%s","actor":"admin"}\n' "$1" "$2" >"$OSREQS/$1.json"
    fi
}
UOS="77777777-7777-4777-8777-777777777777"
os_reset() { rm -f "$OSRES/$UOS.json"; }
: >"$OSC/rauc.log"
: >"$OSC/curl.log"
: >"$OSC/sysctl.log"

# Off the appliance every verb refuses outright — there is no RAUC and nothing to update.
os_intent "$UOS" os-check
osrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "os-check off the appliance is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the appliance" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "appliance"
os_reset
os_intent "$UOS" os-reboot
osrun PITHEAD_APPLIANCE=0 >/dev/null
assert_eq "os-reboot off the appliance is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
os_reset

# Download before any check: there is no host-derived target to hold the proposal against.
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "os-download without a prior check is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says to check first" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "check for updates"
os_reset

# os-check derives tag + asset size on the host and reports newer honestly.
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "os-check reports checked" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "os-check carries the host-derived version" "$(jq -r '.version' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
assert_eq "os-check carries the bundle size" "$(jq -r '.size' "$OSRES/$UOS.json" 2>/dev/null)" "1000"
assert_eq "os-check reports newer against the running 1.3.1" "$(jq -r '.newer' "$OSRES/$UOS.json" 2>/dev/null)" "true"
assert_eq "os-check caches the derived target" "$(jq -r '.tag' "$OSDIR/target.json" 2>/dev/null)" "v9.9.9"
os_reset
# A second check answers from the fresh cache — no second dial (anti-beacon).
dials_before=$(grep -c 'api.github.com' "$OSC/curl.log" || true)
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "a fresh cache answers the second check" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "the second check dials nothing" "$(grep -c 'api.github.com' "$OSC/curl.log" || true)" "$dials_before"
os_reset

# The container cannot steer the download target: a proposal that isn't the checked tag refuses.
os_intent "$UOS" os-download "v1.0.0"
osrun >/dev/null
assert_eq "a non-checked download version is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the checked release" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
os_reset

# Equality is still an honest CHECK — up to date reports normally; only fetch and install refuse.
# pithead re-reads the VERSION file at startup (env cannot override it through the black-box
# door), so the sandbox's running version is swapped to the target and back.
printf '9.9.9' >"$OSC/VERSION"
os_intent "$UOS" os-check
osrun >/dev/null
assert_eq "a same-version check still reports checked" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "a same-version check reports not newer" "$(jq -r '.newer' "$OSRES/$UOS.json" 2>/dev/null)" "false"
os_reset

# The dashboard door refuses a same-version fetch outright, before a byte moves — a compromised
# container must not loop gigabytes over Tor into reinstalls and forced reboots. (The CLI keeps
# equality for manual slot repair, proven in the os-update unit block above.)
dials_before=$(grep -c 'releases/download' "$OSC/curl.log" || true)
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "a same-version download is rejected on the dashboard door" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says already on it" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "already on v9.9.9"
assert_eq "no bytes moved for the refused same-version fetch" "$(grep -c 'releases/download' "$OSC/curl.log" || true)" "$dials_before"
printf '1.3.1' >"$OSC/VERSION"
os_reset

# No disk headroom: refused before a byte moves.
os_intent "$UOS" os-download "v9.9.9"
osrun DF_AVAIL_KB=1000 >/dev/null
assert_eq "a full /data refuses the download" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names free space" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "free space"
assert_eq "no bundle bytes landed" "$(find "$OSDIR" -name '*.raucb*' | wc -l | tr -d ' ')" "0"
os_reset

# The attempt window closes mid-transfer: partial result, partial file KEPT for the resume.
os_intent "$UOS" os-download "v9.9.9"
osrun CURL_RC=28 CURL_PARTIAL_BYTES=300 >/dev/null
assert_eq "a mid-transfer timeout reports partial" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "partial"
assert_eq "partial reports the bytes so far" "$(jq -r '.bytes' "$OSRES/$UOS.json" 2>/dev/null)" "300"
assert_eq "the partial file is kept for the resume" "$(wc -c <"$OSDIR/pithead-os-v9.9.9.raucb.partial" | tr -d ' ')" "300"
os_reset

# The retry RESUMES: curl is asked to continue (-C -) and the result names where it picked up.
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "the resumed download completes" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "downloaded"
assert_eq "the resume started from the kept bytes" "$(jq -r '.resumed_from' "$OSRES/$UOS.json" 2>/dev/null)" "300"
assert_contains "curl was asked to continue the transfer" "$(cat "$OSC/curl.log")" "-C -"
assert_eq "the staged bundle is complete" "$(wc -c <"$OSDIR/pithead-os-v9.9.9.raucb" | tr -d ' ')" "1000"
assert_eq "the state file records the staged download" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "downloaded"
os_reset
# A repeated download of a staged bundle is an idempotent no-op, not a re-download.
dials_before=$(grep -c 'releases/download' "$OSC/curl.log" || true)
os_intent "$UOS" os-download "v9.9.9"
osrun >/dev/null
assert_eq "an already-staged bundle answers downloaded" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "downloaded"
assert_eq "no second transfer for a staged bundle" "$(grep -c 'releases/download' "$OSC/curl.log" || true)" "$dials_before"
os_reset

# os-verify: signature first — a mis-signed file is refused AND deleted, no override.
os_intent "$UOS" os-verify
osrun RAUC_SIG_FAIL=1 >/dev/null
assert_eq "a mis-signed bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names signature verification" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "signature"
assert_eq "the mis-signed bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# Verify with nothing staged: refused with the honest next step.
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "verify with no staged bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal says to download first" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "download it first"
os_reset

os_restage() { cp "$OSC/fixture.raucb" "$OSDIR/pithead-os-v9.9.9.raucb"; }

# rauc failing to RUN is not a signature verdict: one retry, a distinct honest reason, and the
# download is KEPT for the retry — deleting a multi-GB Tor fetch is a verdict a broken tool
# has not earned.
os_restage
: >"$OSC/rauc.log"
os_intent "$UOS" os-verify
osrun RAUC_RUN_FAIL=1 >/dev/null
assert_eq "a rauc that cannot run rejects the verify" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the reason says rauc could not run, not signature" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "could not run"
assert_not_contains "the reason does not claim a signature verdict" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "signature"
assert_eq "the bundle is kept when rauc never judged it" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "present"
assert_eq "the failed rauc run was retried once" "$(grep -c 'info' "$OSC/rauc.log" || true)" "2"
os_reset

# Wrong compatible: built for another machine class, refused and deleted.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-othercompat.txt" >/dev/null
assert_eq "a wrong-compatible bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names both machine classes" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "other-machine"
assert_eq "the wrong-compatible bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# A variant flip (release box, debug bundle) never installs from the dashboard — CLI consent only.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-debug.txt" >/dev/null
assert_eq "a variant-flipping bundle is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the variant consent" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "variant"
os_reset

# The /data migration floor refuses through the dashboard door exactly as it does at the CLI —
# a valid signature is not permission to replay below the floor (shared os_update_version_guard).
os_restage
printf '99.0.0\n' >"$OSC/floor"
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a bundle below the /data floor is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the floor refusal warns about the chain data" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "strand the chain data"
rm -f "$OSC/floor"
os_reset

# A stamp that isn't the published tag is a possible replay — refused.
os_restage
os_intent "$UOS" os-verify
osrun RAUC_INFO_OUT="$OSC/info-mismatch.txt" >/dev/null
assert_eq "a tag-mismatched stamp is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names the mismatch" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "9.9.8"
os_reset

# A same-version bundle refuses at verify too — download refuses it first, but verify holds the
# line for a bundle already staged when the versions converged, and the bundle is deleted.
# Same VERSION-file swap as the check/download equality tests above.
os_restage
printf '9.9.9' >"$OSC/VERSION"
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a same-version bundle is rejected at verify" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the verify refusal says already on it" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "already on v9.9.9"
assert_eq "the same-version bundle was deleted" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
printf '1.3.1' >"$OSC/VERSION"
os_reset

# The happy verify: signed, compatible, newer, stamped as published.
os_restage
os_intent "$UOS" os-verify
osrun >/dev/null
assert_eq "a good bundle verifies" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "verified"
assert_eq "verify reports the version" "$(jq -r '.version' "$OSRES/$UOS.json" 2>/dev/null)" "v9.9.9"
assert_eq "the state file records verified" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "verified"
os_reset

# Reboot with no installed update waiting: refused — the dashboard is not a reboot lever.
rm -f "$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "os-reboot with nothing installed is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_eq "no reboot was ordered" "$(grep -c reboot "$OSC/sysctl.log" || true)" "0"
os_reset

# A failing install reports failed and the running system is untouched (no in-flight flag).
# The result carries only the whitelist-extracted final error line — the raw log tail (staging
# paths, slot devices) stays host-side, in the journal.
os_intent "$UOS" os-install
out=$(osrun RAUC_INSTALL_FAIL=1)
assert_eq "a failing install reports failed" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "failed"
assert_contains "the failure says the system is untouched" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "untouched"
assert_contains "the result carries rauc's final error line" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "installing failed"
assert_not_contains "the raw log tail stays out of the result" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "hostdisk3"
assert_contains "the full log tail lands host-side for the journal" "$out" "hostdisk3"
assert_eq "no in-flight flag after a failed install" "$([ -f "$OSDIR/in-flight.json" ] && echo present || echo absent)" "absent"
os_reset

# The happy install: the SAME os_update path the CLI takes writes the spare slot, the in-flight
# flag arms the post-reboot verdict, and the staged bundle is cleaned up.
os_intent "$UOS" os-install
osrun >/dev/null
assert_eq "the install reports installed" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "installed"
assert_contains "rauc install ran with the staged bundle" "$(cat "$OSC/rauc.log")" "install $OSDIR/pithead-os-v9.9.9.raucb"
assert_eq "the in-flight flag names the target" "$(jq -r '.to' "$OSDIR/in-flight.json" 2>/dev/null)" "9.9.9"
assert_eq "the in-flight flag names the origin" "$(jq -r '.from' "$OSDIR/in-flight.json" 2>/dev/null)" "1.3.1"
assert_eq "the state file records reboot-pending" "$(jq -r '.step' "$OSSTATE" 2>/dev/null)" "reboot-pending"
assert_eq "the staged bundle was cleaned up" "$([ -f "$OSDIR/pithead-os-v9.9.9.raucb" ] && echo present || echo absent)" "absent"
os_reset

# Now the reboot goes through — the install result is FRESH: result lands BEFORE the order,
# then systemctl reboot.
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "os-reboot with a fresh install reports rebooting" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rebooting"
assert_contains "systemctl reboot was ordered" "$(cat "$OSC/sysctl.log")" "reboot"
os_reset

# The install result authorizes a reboot for 24 hours, then goes stale: refused with the re-arm
# path, and no reboot is ordered. An in-flight flag with no readable timestamp refuses too —
# unreadable is not proof of freshness.
jq -n '{from:"1.3.1",to:"9.9.9",ts:((now|floor) - 90000)}' >"$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "a stale install no longer authorizes a reboot" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "the stale refusal names the re-arm path" "$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)" "re-arms the reboot"
assert_eq "no second reboot was ordered" "$(grep -c reboot "$OSC/sysctl.log" || true)" "1"
os_reset
jq -n '{from:"1.3.1",to:"9.9.9"}' >"$OSDIR/in-flight.json"
os_intent "$UOS" os-reboot
osrun >/dev/null
assert_eq "an in-flight flag without a timestamp refuses the reboot" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
os_reset

# One os-* verb per drain: a second one in the same cycle rejects with a retry hint.
UOS2="88888888-8888-4888-8888-888888888888"
rm -f "$OSDIR/in-flight.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short" # a fresh dial, not the check throttle
os_intent "$UOS" os-check
sleep 1 # distinct mtimes so the drain order is deterministic (oldest first)
os_intent "$UOS2" os-check
osrun >/dev/null
assert_eq "the first os verb in a drain runs" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "checked"
assert_eq "the second os verb in the same drain is rejected" "$(jq -r '.status' "$OSRES/$UOS2.json" 2>/dev/null)" "rejected"
assert_contains "the budget refusal says retry" "$(jq -r '.error' "$OSRES/$UOS2.json" 2>/dev/null)" "retry"
rm -f "$OSRES/$UOS.json" "$OSRES/$UOS2.json"

# The battery's test seam only redirects for a ROOT-owned file: written by anyone else it is
# ignored and the flow stays on the GitHub-over-Tor path. Running unprivileged here, our own
# file IS owner-matched — assert the redirect engages, which is the seam's whole contract.
printf 'http://bench.invalid/updates' >"$OSC/os-update-test-base"
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short"
os_intent "$UOS" os-check
osrun >/dev/null
assert_contains "the test seam redirects the release lookup" "$(cat "$OSC/curl.log")" "bench.invalid/updates/releases-latest.json"
rm -f "$OSC/os-update-test-base" "$OSRES/$UOS.json" "$OSDIR/.check-stamp-short" # the stub's exit-22 catch-all makes this bench dial rc 2 too (#1050 review) — clear it or it leaks into the next test

# #1081 reached only the two DIY lookups. The appliance's os-check kept its own `curl -fsS`, and
# `-f` collapses every non-2xx into one exit code — so a spent GitHub budget came out of the
# dashboard as "could not reach the release API over Tor", pointing at a doctor run that reports
# Tor healthy, on a box with no shell to run it from. It goes through the shared fetch now.
echo "== black-box: a rate-limited os-check names the remedy that works (#1081) =="
printf '%s' '{"message":"API rate limit exceeded for this IP.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api"}' >"$OSC/api-403.json"
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short" # starts clean regardless of what leaked above
os_reset
os_intent "$UOS" os-check
osrun CURL_API_RESPONSE="$OSC/api-403.json" GH_STUB_CODE=403 >/dev/null
os_403=$(jq -r '.error' "$OSRES/$UOS.json" 2>/dev/null)
assert_eq "a rate-limited os-check is rejected" "$(jq -r '.status' "$OSRES/$UOS.json" 2>/dev/null)" "rejected"
assert_contains "and names the remedy that actually works" "$os_403" "restart tor"
# The defect itself, as the operator read it: the old refusal blamed the transport and sent them to
# a doctor run that reports Tor healthy. Both halves of that sentence are barred. (The replacement
# does say the word "doctor" — "nothing is wrong with this box, and 'doctor' will say so" — so this
# matches the two OLD phrasings, not the word.)
case "$os_403" in
*"could not reach the release API"* | *"Check './pithead doctor' and retry"*)
    bad "a rate limit is not reported as a dead Tor circuit" "the refusal still says: $os_403"
    ;;
*) ok "a rate limit is not reported as a dead Tor circuit" ;;
esac
# The 10-minute throttle stays HELD on a rate-limit refusal: that request did reach GitHub, so
# releasing it restores exactly the unthrottled beacon the throttle exists to stop (#1081's fix 2,
# deliberately not taken).
assert_eq "the throttle is still held after a rate-limit refusal" \
    "$([ -f "$OSDIR/.check-stamp" ] && echo held || echo released)" "held"
os_reset
rm -f "$OSDIR/target.json" "$OSDIR/.check-stamp" "$OSDIR/.check-stamp-short"

unset -f osrun os_intent os_reset os_restage
rm -rf "$OSC"
unset OSC OSREQS OSRES OSSTATE OSDIR UOS UOS2 dials_before

# --- os/rauc stale-tarball guard (verify_tarball_commit in populate-slot.sh). A present-but-stale
# os/build/pithead-root.tar looks identical to a fresh one to `[ -s ]` — a bench deploy once
# bundled a leftover tarball from a previous session and every downstream check came up green with
# the old code running. The guard extracts the tarball's own opt/pithead/BUILD_COMMIT stamp and
# compares it to the working tree, proven here with a fabricated fixture tarball (no image build).
echo "== unit: os/rauc stale-tarball guard =="
VTC_TMP=$(mktemp -d)
# The same commit+dirty-suffix computation verify_tarball_commit does, so the "match" fixture is
# honest about the state of THIS working tree (it may itself be dirty mid-change).
VTC_HEAD_SHA=$(cd "$ROOT" && git rev-parse HEAD)
VTC_HEAD="$VTC_HEAD_SHA"
(cd "$ROOT" && git diff --quiet) || VTC_HEAD="${VTC_HEAD_SHA}-dirty"

# Build a fixture tarball with the single member the guard reads: opt/pithead/BUILD_COMMIT.
# $2=NONE fabricates a tarball with the directory but no stamp file (an old/broken build).
mk_vtc_fixture() { # $1=out-path $2=stamp-content|NONE
    local d
    d=$(mktemp -d)
    mkdir -p "$d/opt/pithead"
    [ "$2" = NONE ] || printf '%s\n' "$2" >"$d/opt/pithead/BUILD_COMMIT"
    tar -cf "$1" -C "$d" opt
    rm -rf "$d"
}
vtc() { # $1=tarball -> prints "rc=<n>"; stderr goes to $VTC_TMP/err
    (
        cd "$ROOT" || exit
        # shellcheck disable=SC1090
        . os/rauc/populate-slot.sh
        set +e
        verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}

mk_vtc_fixture "$VTC_TMP/fresh.tar" "$VTC_HEAD"
assert_eq "a tarball stamped with the current HEAD is accepted" "$(vtc "$VTC_TMP/fresh.tar")" "rc=0"

mk_vtc_fixture "$VTC_TMP/stale.tar" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
out=$(vtc "$VTC_TMP/stale.tar")
assert_eq "a tarball stamped with a foreign commit is refused" "$out" "rc=2"
err="$(cat "$VTC_TMP/err")"
assert_contains "the refusal names the tarball's stamped commit" "$err" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
assert_contains "the refusal names the working tree's commit" "$err" "$VTC_HEAD_SHA"
assert_contains "the refusal points at the override env var" "$err" "PITHEAD_STALE_TARBALL_OK"

out=$(PITHEAD_STALE_TARBALL_OK=1 vtc "$VTC_TMP/stale.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides a stale-commit refusal" "$out" "rc=0"

mk_vtc_fixture "$VTC_TMP/nostamp.tar" NONE
out=$(vtc "$VTC_TMP/nostamp.tar")
assert_eq "a tarball with no BUILD_COMMIT stamp is refused" "$out" "rc=2"
assert_contains "the refusal says no stamp was found" "$(cat "$VTC_TMP/err")" "no BUILD_COMMIT stamp"

# A checkout git cannot read (sudo on another user's tree, once the SUDO_USER fallback also
# fails) must refuse rather than silently skip the freshness check — fail closed, with the
# same explicit escape. Run from a non-repo dir with the fallback neutralized to simulate it.
vtc_norepo() { # $1=tarball -> prints "rc=<n>"; stderr to $VTC_TMP/err
    (
        cd "$VTC_TMP" || exit
        # shellcheck disable=SC1091
        . "$ROOT/os/rauc/populate-slot.sh"
        set +e
        SUDO_USER="" GIT_DIR="$VTC_TMP/no-such-repo" verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}
out=$(vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "an unreadable working tree refuses (fail closed, never skip)" "$out" "rc=2"
assert_contains "the refusal explains git could not be read" "$(cat "$VTC_TMP/err")" "cannot read the working tree's commit"
out=$(PITHEAD_STALE_TARBALL_OK=1 vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides the unreadable-tree refusal" "$out" "rc=0"

rm -rf "$VTC_TMP"
unset -f mk_vtc_fixture vtc vtc_norepo
unset VTC_TMP VTC_HEAD_SHA VTC_HEAD

# --- mkbundle metadata validation (fails fast, before the multi-minute image build) ---
echo "== unit: mkbundle compatibility-metadata validation =="
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=maybe bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "PITHEAD_DATA_MIGRATION must be true/false" "$?" "2"
assert_contains "the message names the field" "$out" "PITHEAD_DATA_MIGRATION"
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=true bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "data_migration=true without a floor is refused" "$?" "2"
assert_contains "the message asks for the migration floor" "$out" "PITHEAD_MIN_OS_VERSION"
out=$(cd "$ROOT" && PITHEAD_MIN_OS_VERSION=1.2 bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "a non-semver floor is refused" "$?" "2"
assert_contains "the message names the floor field" "$out" "PITHEAD_MIN_OS_VERSION"

# ---------------------------------------------------------------------------
# os/rauc signing-material guard (resolve_signing_material in populate-slot.sh). A release build
# must name the signing key; only an explicitly-marked --dev build auto-generates a throwaway. The
# refuse logic is proven here at the shell-unit tier — sourced and called directly, no docker/loop
# image build. The guard is the safety fix: a dev cert must never become the fleet's update trust
# root because a build host happened to have one lying around.
RSM="$ROOT/os/rauc/populate-slot.sh"
RSMTMP=$(mktemp -d)
# Run the resolver in an isolated cwd (it writes os/rauc/certs/ relative to $PWD). $1=dev(0/1),
# $2=where to send stderr. Prints: rc=<n> cert=<..> key=<..> keyring=<..>
rsm() {
    local dev="$1" errto="$2" d
    d=$(mktemp -d)
    (
        cd "$d" || exit
        # shellcheck disable=SC1090
        . "$RSM"
        set +e
        resolve_signing_material "$dev" 2>"$errto"
        printf ' rc=%s cert=%s key=%s keyring=%s\n' "$?" "${RAUC_CERT:-}" "${RAUC_KEY:-}" "${RAUC_KEYRING:-}"
    )
    rm -rf "$d"
}
rsm_field() { echo "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

# Release build (dev=0), no key named -> refuses, non-zero, names the env vars and --dev.
res=$(
    unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "release build with no signing key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"
assert_contains "refusal names the release key env vars" "$(cat "$RSMTMP/err")" "PITHEAD_RAUC_CERT"
assert_contains "refusal points at --dev for a throwaway key" "$(cat "$RSMTMP/err")" "--dev"

# Explicit key (dev=0) -> accepted; keyring defaults to the signing cert. Content is irrelevant to
# the guard (it checks readability, not validity), so dummy files exercise the branch openssl-free.
printf 'cert\n' >"$RSMTMP/rel-cert.pem"
printf 'key\n' >"$RSMTMP/rel-key.pem"
res=$(
    PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem"
    export PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY
    unset PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "explicit release key is accepted (rc 0)" "$(rsm_field "$res" rc)" "0"
assert_eq "the named cert is used for signing" "$(rsm_field "$res" cert)" "$RSMTMP/rel-cert.pem"
assert_eq "keyring defaults to the signing cert" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-cert.pem"

# Explicit keyring overrides the baked trust anchor (root+leaf: root baked, leaf signs).
printf 'root\n' >"$RSMTMP/rel-root.pem"
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem" PITHEAD_RAUC_KEYRING="$RSMTMP/rel-root.pem"
    rsm 0 "$RSMTMP/err"
)
assert_eq "PITHEAD_RAUC_KEYRING is what gets baked" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-root.pem"

# A cert with no matching key is rejected — both halves are required.
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem"
    unset PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "cert without key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"

# Dev build (dev=1) still auto-generates a throwaway — the local/bench loop is preserved.
if command -v openssl >/dev/null 2>&1; then
    res=$(
        unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
        rsm 1 "$RSMTMP/err"
    )
    assert_eq "dev build auto-generates and succeeds (rc 0)" "$(rsm_field "$res" rc)" "0"
    assert_contains "dev key lands in os/rauc/certs" "$(rsm_field "$res" key)" "os/rauc/certs/key.pem"
else
    ok "dev auto-gen skipped (no openssl on this host)"
fi
rm -rf "$RSMTMP"
unset RSM RSMTMP
unset -f rsm rsm_field

echo "== black-box: config-reset clears config, keeps the chains (appliance two-tier reset) =="
# A throwaway deployment: config.json + rendered files + data dirs. docker is a noop; the reboot is
# a stub that just records that it fired, so we assert the reboot without rebooting the runner.
CR="$SANDBOX/config-reset"
mkdir -p "$CR/bin" "$CR/data/monero" "$CR/data/tor"
cp "$STACK" "$CR/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/sudo"
chmod +x "$CR/bin/docker" "$CR/bin/sudo"
seed_cr() {
    printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$CR/config.json"
    printf 'DEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n' >"$CR/.env"
    : >"$CR/Caddyfile"
    : >"$CR/data/monero/blockchain" # stand-in for the synced chain
    : >"$CR/data/tor/hostname"      # stand-in for the onion key material
}
# Wrong confirmation word: aborts, changes nothing.
seed_cr
out=$(cd "$CR" && printf 'nope\n' | PITHEAD_APPLIANCE=0 PATH="$CR/bin:$PATH" ./pithead config-reset 2>&1) || true
assert_contains "config-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted config-reset keeps config.json" "$([ -f "$CR/config.json" ] && echo yes)" "yes"
# -y off the appliance: config + rendered files go, data dirs stay, no reboot — just the hint.
seed_cr
rebooted="$CR/.rebooted"
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=0 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_rc "config-reset succeeds" "$?" "0"
assert_eq "config-reset removes config.json" "$([ -f "$CR/config.json" ] || echo gone)" "gone"
assert_eq "config-reset removes .env" "$([ -f "$CR/.env" ] || echo gone)" "gone"
assert_eq "config-reset removes Caddyfile" "$([ -f "$CR/Caddyfile" ] || echo gone)" "gone"
assert_eq "config-reset KEEPS the monero chain" "$([ -f "$CR/data/monero/blockchain" ] && echo kept)" "kept"
assert_eq "config-reset KEEPS the Tor onion key" "$([ -f "$CR/data/tor/hostname" ] && echo kept)" "kept"
assert_eq "config-reset off the appliance does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"
assert_contains "config-reset hints how to reconfigure" "$out" "firstboot-wizard"
# On the appliance: same wipe, but it reboots into first-boot setup.
seed_cr
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_eq "config-reset on the appliance reboots into firstboot" "$([ -f "$rebooted" ] && echo yes)" "yes"
# Already unprovisioned: nothing to reset.
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1) || true
assert_contains "config-reset refuses when config.json is absent" "$out" "already unprovisioned"
out=$(cd "$CR" && PATH="$CR/bin:$PATH" ./pithead config-reset --bogus 2>&1) || true
assert_contains "config-reset rejects unknown options" "$out" "Unknown option"

echo "== black-box: factory-reset arms the boot-time wipe, appliance-only (two-tier reset) =="
FR="$SANDBOX/factory-reset"
mkdir -p "$FR/bin" "$FR/esp"
cp "$STACK" "$FR/pithead"
marker="$FR/esp/pithead-reset"
rebooted="$FR/.rebooted"
# Off the appliance: refuse, arm nothing, point at uninstall.
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=0 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset off the appliance refuses" "$out" "only runs on the appliance"
assert_eq "refused factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# Wrong confirmation word on the appliance: aborts, arms nothing.
out=$(cd "$FR" && printf 'nope\n' | PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset 2>&1) || true
assert_contains "factory-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# -y on the appliance: BATTERY — the marker is written AND the reboot fires (both, or the wipe
# either never runs or never reaches the boot that runs it).
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1)
assert_rc "factory-reset succeeds" "$?" "0"
assert_eq "factory-reset arms the ESP marker AND reboots" \
    "$([ -f "$marker" ] && [ -f "$rebooted" ] && echo armed-and-rebooting)" "armed-and-rebooting"
# ESP not writable: refuse loudly, reboot nothing (a box that quietly did nothing is the trap).
rm -f "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/no-such-esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset refuses when the ESP marker cannot be written" "$out" "Could not arm"
assert_eq "unarmable factory-reset does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"

echo "== unit: a boot that fails its health gate reboots itself, once (#1065) =="
# The A/B design's headline promise is that a bad update reverts itself, and for the likeliest bad
# update — one that boots cleanly with a dead stack — it did not: pithead-boot left the slot
# uncommitted and exited, and the fallback is a GRUB decision GRUB does not get to make until
# something reboots. So the box sat on the broken slot with the stack down until a human pulled the
# power, while two operator docs promised otherwise.
#
# Bounded is the load-bearing half. A fault on /data survives the fallback, so both slots fail the
# same way; a machine that reboot-loops can never be looked at. And if the counter cannot be
# written the machine must NOT reboot — an unbounded loop is the one outcome worse than a stranded
# box, so the failure to persist has to fail SAFE, not open.
#
# MUTATION PROOF: drop the `[ "$n" -ge 2 ]` bound and the second-failure assertion goes red; make
# the unwritable-counter branch reboot anyway and the fail-safe assertion goes red; drop the
# rm in boot_gate_passed and the cleared-on-success assertion goes red.
BG="$SANDBOX/boot-gate"
mkdir -p "$BG"
# shellcheck disable=SC1090  # overlay path is dynamic by design
bg_run() { # <cwd> — one fail_boot in a sandbox, printing "<reboots> <counter> <stderr>"
    (
        cd "$1" 2>/dev/null || exit 1
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
    )
}
rm -f "$BG"/rebooted.*
bg_out1=$(bg_run "$BG")
bg_rebooted1=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the first failed health gate reboots the machine" "$bg_rebooted1" "1"
assert_eq "and records the attempt on /data" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "1"
assert_contains "saying why, on the console" "$bg_out1" "falls back to the previous slot"

rm -f "$BG"/rebooted.*
bg_out2=$(bg_run "$BG")
bg_rebooted2=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the fallback slot failing the same way does NOT reboot again" "$bg_rebooted2" "0"
assert_eq "the attempt is still counted" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "2"
assert_contains "and the console says the fault is not the slot" "$bg_out2" "the fault is not the slot"

# A healthy boot clears the counter, or one transient failure months ago would spend the machine's
# single rollback attempt on the update that actually needs it.
(
    cd "$BG" || exit 1
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    boot_gate_passed
)
assert_eq "a boot that commits clears the counter" "$([ -f "$BG/.boot-gate-failures" ] && echo present || echo gone)" "gone"

# Unwritable counter: the cwd is deleted out from under it, which makes the relative write fail for
# root too — a chmod would not, and this suite runs as both.
BGX="$SANDBOX/boot-gate-unwritable"
mkdir -p "$BGX"
rm -f "$BG"/rebooted.*
bg_out3=$(
    cd "$BGX" && rmdir "$BGX"
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
)
assert_eq "a counter it cannot write means it does NOT reboot" "$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_contains "and it says a reboot it cannot count is a reboot loop" "$bg_out3" "a reboot it cannot count is a reboot loop"
rm -f "$BG"/rebooted.*

# Every exit that leaves the slot uncommitted goes through the helper — a bare `exit 1` on any of
# them is the original defect back on that path alone. The rig leg's two and the coordinator's
# render, up and health gate are all of them.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
bg_bare=$(grep -cE '^[[:space:]]*(\./pithead (render|up)|timeout 1800 \./pithead local-miner).*\|\| exit 1' "$BOOTSCRIPT" || true)
assert_eq "no boot-failure path exits without arming the fallback" "$bg_bare" "0"
echo "== unit: the appliance battery's release gate does not lie about what it ran (#1064) =="
# Harness wiring, asserted here because the harness itself only runs on the KVM bench. Both halves
# are the same defect: a gate that reports success without having run. `--phase all` executed five
# of eight phases while the release checklist said it ran everything, so every cut skipped the
# power cuts, the corrupt-bundle refusal, the factory reset, the wedged-/data recovery and the
# media channel; and verify-image's stale-artifact comparison was switched off in the ONE caller
# that is not a human typing a command. MUTATION PROOF: drop a phase from the `all` arm, or drop
# the PITHEAD_EXPECT_COMMIT prefix, and the matching assertion goes red.
OSH="$(cat "$ROOT/tests/os/run.sh")"
osh_all="$(printf '%s' "$OSH" | sed -n '/^all)/,/^    ;;/p')"
for ph in boot update install provision rig media fault reset; do
    assert_contains "--phase all runs phase_$ph" "$osh_all" "phase_$ph"
done
assert_contains "the battery's own build pins the commit verify-image checks against" "$OSH" \
    'PITHEAD_EXPECT_COMMIT="$expect" tests/os/verify-image.sh'
VIS="$(cat "$ROOT/tests/os/verify-image.sh")"
# Wiring the guard on is only half of it: the two ends have to speak the same shape. build-image.sh
# stamps `git rev-parse HEAD` — the FULL sha — and the harness first handed over `--short`, so the
# equality check failed EVERY harness build. A guard that refuses everything is the same lie as one
# that refuses nothing, pointed the other way. Bench-proven on the KVM image; asserted here because
# verify-image needs a loop device and root, which tier-1 has neither of.
assert_contains "the harness hands over the full sha build-image.sh stamps" "$OSH" \
    'expect="$(git rev-parse HEAD 2>/dev/null || true)"'
assert_not_contains "the harness does not hand over a short sha the stamp never equals" "$OSH" \
    'rev-parse --short HEAD'
assert_contains "the expected-commit check matches on a prefix, so a short sha still verifies" "$VIS" \
    'case "$BUILT" in "$PITHEAD_EXPECT_COMMIT"*)'
assert_contains "a skipped check is counted, not silent" "$VIS" "SKIP=\$((SKIP + 1))"
assert_contains "skipped checks refuse to report a verified image" "$VIS" "were SKIPPED, so this is not a verified image"
unset OSH osh_all VIS

echo "== unit: pithead-data-reset decides reformat-vs-skip fail-safe (wedged-/data recovery) =="
# Source the boot script (functions only — its main is guarded) and drive data_reset_decision with
# stubbed repair tools, in a subshell so its set -u / defs never leak into the suite.
#
# The stubs model each tool's REAL contract, because the old ones could not fail (#1086): `fsck` was
# `exit 0` and the mount stub succeeded on its second call whatever had run in between, so "fsck
# repairs the mount -> skip" was true of the stub and said nothing about the product. Here a
# partition carries a damage level, each tool repairs only the damage it can, and mount succeeds only
# once something actually repaired it — so the assertions below are about the escalation, not the
# harness. REPAIRABLE_BY names the tool that fixes this partition: preen, e2fsck, backup, or none.
DR="$SANDBOX/data-reset"
mkdir -p "$DR/bin"
cat >"$DR/bin/mount" <<'EOF'
#!/usr/bin/env bash
# Mounts when the partition was never damaged, or once the repair log says the right tool ran.
[ "${REPAIRABLE_BY:-none}" = "healthy" ] && exit 0
grep -qx "repaired" "${REPAIR_STATE:-/dev/null}" 2>/dev/null && exit 0
exit 1
EOF
# fsck -p: preen repairs ONLY what needs no operator decision and refuses the rest by definition —
# rc 8 with a "try an alternate superblock" hint is exactly what it does to the damage this issue is
# about (#1062). It must never be able to repair a partition the real one could not.
cat >"$DR/bin/fsck" <<'EOF'
#!/usr/bin/env bash
echo "fsck $*" >>"${REPAIR_LOG:-/dev/null}"
[ "${REPAIRABLE_BY:-none}" = "preen" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; }
exit 8
EOF
# e2fsck -y: repairs what preen refused. With -b it rebuilds the primary superblock from a backup —
# the only thing that saves a partition whose superblock is gone.
cat >"$DR/bin/e2fsck" <<'EOF'
#!/usr/bin/env bash
echo "e2fsck $*" >>"${REPAIR_LOG:-/dev/null}"
case " $* " in
*" -b "*) [ "${REPAIRABLE_BY:-none}" = "backup" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
*) [ "${REPAIRABLE_BY:-none}" = "e2fsck" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
esac
exit 8
EOF
# mke2fs -n computes the layout and writes nothing; this is the shape its backup list prints in.
cat >"$DR/bin/mke2fs" <<'EOF'
#!/usr/bin/env bash
echo "mke2fs $*" >>"${REPAIR_LOG:-/dev/null}"
printf 'Creating filesystem with 131072 4k blocks\nSuperblock backups stored on blocks:\n\t32768, 98304, 163840\n'
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$DR/bin/umount"
chmod +x "$DR/bin/mount" "$DR/bin/umount" "$DR/bin/fsck" "$DR/bin/e2fsck" "$DR/bin/mke2fs"
decide() { # $1 marker-file, $2 which tool can repair this partition (healthy|preen|e2fsck|backup|none)
    (
        export PATH="$DR/bin:$PATH"
        export REPAIRABLE_BY="$2" # exported: the stubs run as child processes
        export REPAIR_STATE="$DR/state" REPAIR_LOG="$DR/log"
        : >"$REPAIR_STATE"
        : >"$REPAIR_LOG"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        data_reset_decision "/dev/fake-data" "$1"
    )
}
touch "$DR/marker-present"
assert_eq "marker present -> reformat-requested (even if /data would mount)" "$(decide "$DR/marker-present" healthy)" "reformat-requested"
assert_eq "no marker + /data mounts clean -> skip (fail-safe: never touch a healthy partition)" "$(decide "$DR/no-marker" healthy)" "skip"
assert_eq "no marker + preen repairs the mount -> skip (a dirty filesystem is not a lost one)" "$(decide "$DR/no-marker" preen)" "skip"
# The defect (#1062): `fsck -p` refuses precisely the damage a full e2fsck recovers, so stopping
# there sent a salvageable partition — wallets, onion keys, both chains — to mkfs.ext4 -F.
assert_eq "no marker + only a full e2fsck can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" e2fsck)" "skip"
# The textbook case the issue reproduced: a corrupt primary superblock, recoverable only from a
# backup, which `fsck -p` reports by printing the very command that would have saved it.
assert_eq "no marker + only a backup superblock can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" backup)" "skip"
assert_eq "no marker + no repair mounts it -> reformat-wedged (the box would be bricked otherwise)" "$(decide "$DR/no-marker" none)" "reformat-wedged"
# Escalation order: least destructive first, and every rung tried before the partition is erased.
decide "$DR/no-marker" none >/dev/null
dr_log="$(cat "$DR/log")"
assert_contains "preen runs first" "$dr_log" "fsck -p -t ext4 /dev/fake-data"
assert_contains "then a full e2fsck" "$dr_log" "e2fsck -y /dev/fake-data"
assert_contains "then the backup superblocks mke2fs -n reports" "$dr_log" "e2fsck -y -b 32768 /dev/fake-data"
assert_contains "the backup offsets are computed, never hardcoded" "$dr_log" "mke2fs -n /dev/fake-data"
assert_eq "the backup retry is bounded, so a destroyed filesystem cannot grind forever" "$(grep -c 'e2fsck -y -b' "$DR/log")" "2"
# A partition the FIRST tool fixes must not be handed to the later, heavier ones.
decide "$DR/no-marker" preen >/dev/null
assert_not_contains "a preen-repaired partition never reaches e2fsck" "$(cat "$DR/log")" "e2fsck"

echo "== unit: pithead-data-reset leaves evidence that /data was wiped (#1062) =="
# A reformatted box and a factory-fresh one both boot into the wizard, so without this the operator
# reads a wipe as "it reset itself" and never learns the disk may have been salvageable. The ESP is
# the only writable thing a /data reformat leaves standing.
DRW="$SANDBOX/data-reset-wipe"
mkdir -p "$DRW/esp"
(
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    record_wipe "$DRW/esp" "unrecoverable /data reinitialized — everything on it was lost"
    record_wipe "" "an ESP that would not mount must never block the recovery"
)
assert_eq "the wipe is recorded on the ESP" "$([ -f "$DRW/esp/pithead-data-wiped" ] && echo present || echo absent)" "present"
assert_contains "the record says what was lost" "$(cat "$DRW/esp/pithead-data-wiped")" "everything on it was lost"
assert_contains "the record is timestamped" "$(cat "$DRW/esp/pithead-data-wiped")" "$(date -u +%Y-)"
assert_eq "one wipe, one line" "$(wc -l <"$DRW/esp/pithead-data-wiped" | tr -d ' ')" "1"

echo "== unit: pithead-data-reset boot_disk_part resolves by PARTLABEL on the boot disk (#926) =="
# Stubbed findmnt + lsblk (the same PATH-stub shape pithead's own prefill_from_previous_install
# test uses for lsblk). findmnt always answers the fake root partition; lsblk branches on its
# first flag: -no PKNAME returns the parent disk name, -lnpo NAME,PARTLABEL lists that disk's
# partitions with their labels — never a bare/unscoped label lookup.
DRP="$SANDBOX/data-reset-partition"
mkdir -p "$DRP/bin"
printf '#!/usr/bin/env bash\necho "/dev/vda2"\n' >"$DRP/bin/findmnt"
# The stub's labels are DERIVED from the real build inputs, not hand-typed: mkimage's sgdisk line
# names the ESP, repart.d names the data partition. If either file ever changes its casing or
# name, this test fails instead of green-lighting a lookup that no longer matches reality.
DRP_ESP_LABEL=$(grep -oE '\-c 1:[a-zA-Z]+' "$ROOT/os/rauc/mkimage.sh" | cut -d: -f2)
DRP_DATA_LABEL=$(grep -oE '^Label=.*' "$ROOT/os/rootfs/repart.d/40-data.conf" | cut -d= -f2)
assert_eq "the ESP label mkimage bakes is the one data-reset looks up" "$DRP_ESP_LABEL" "esp"
assert_eq "the data label repart declares is the one data-reset looks up" "$DRP_DATA_LABEL" "data"
cat >"$DRP/bin/lsblk" <<EOF
#!/usr/bin/env bash
case "\$1" in
-no) echo "vda" ;;
-lnpo) printf '/dev/vda1 ${DRP_ESP_LABEL}\n/dev/vda4 ${DRP_DATA_LABEL}\n' ;;
esac
EOF
chmod +x "$DRP/bin/findmnt" "$DRP/bin/lsblk"
resolve() { # $1: partlabel
    (
        export PATH="$DRP/bin:$PATH"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        boot_disk_part "$1"
    )
}
assert_eq "boot_disk_part data -> the data partition on the boot disk" "$(resolve data)" "/dev/vda4"
assert_eq "boot_disk_part esp -> the ESP on the boot disk" "$(resolve esp)" "/dev/vda1"
assert_eq "boot_disk_part on a label the boot disk doesn't carry -> empty (first boot, pre-repart)" \
    "$(resolve nosuchlabel)" ""

# A container/unexpected root (mountinfo source isn't /dev/*) must fail closed, not guess.
printf '#!/usr/bin/env bash\necho "overlay"\n' >"$DRP/bin/findmnt"
out=$(
    export PATH="$DRP/bin:$PATH"
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    boot_disk_part data
)
rc=$?
assert_rc "boot_disk_part on a non-/dev root -> rc 1" "$rc" "1"
assert_eq "boot_disk_part on a non-/dev root -> prints nothing" "$out" ""

echo "== unit: pithead-machine-id — restore writes THROUGH /etc/machine-id, never unmounts it =="
# The regression this pins: an earlier version unmounted /etc/machine-id before writing, which on
# a read-only-root A/B slot exposed the lower image and the write failed — leaving an empty id and
# a dead DHCP lease. The write must land in the (writable) target as-is. ETC + ID_FILE are
# overridable so this runs without touching the real /etc.
MID="$SANDBOX/machine-id"
mkdir -p "$MID"
# 1) Restore: /data holds an id, /etc has a different (systemd-transient) one -> /etc takes /data's.
printf 'fa85bfc69f0b451d95bbacf897e431ce\n' >"$MID/data-id"
printf 'ffffffffffffffffffffffffffffffff\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "restore overwrites /etc/machine-id with the persisted id" "$(cat "$MID/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"
assert_eq "restore leaves the persisted id unchanged" "$(cat "$MID/data-id")" "fa85bfc69f0b451d95bbacf897e431ce"
# 2) Adopt: /data has none yet -> adopt this boot's /etc id and persist it read-only.
rm -f "$MID/data-id"
printf 'abc0000000000000000000000000def0\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "adopt persists this boot's id to /data" "$(cat "$MID/data-id" 2>/dev/null)" "abc0000000000000000000000000def0"
# 3) Nothing to adopt: /etc empty AND /data empty -> refuse loudly, persist nothing. A newline
# persisted here would satisfy [ -s ] forever and every later boot would restore garbage.
rm -f "$MID/data-id"
: >"$MID/etc-id"
if (
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1; then
    bad "empty-adopt: script must refuse when there is no id anywhere"
else
    ok "empty-adopt: refused (non-zero exit)"
fi
assert_eq "empty-adopt persists nothing" "$(cat "$MID/data-id" 2>/dev/null || echo absent)" "absent"

echo "== unit: pithead-hugepages — the RandomX reservation fits the machine's RAM (#977) =="
# The appliance bakes a 6 GiB hugepages reservation sized for the supported 16 GB machine; the
# boot-time sizing shrinks it LOUDLY on smaller RAM. The tier function is pure over a
# meminfo-shaped file, so every branch is provable here; the only thing left for the battery is
# that on the 16 GiB harness VM the sizing is a no-op (full pool intact, no marker).
HG="$SANDBOX/hugepages"
mkdir -p "$HG"
printf 'MemTotal:       16250000 kB\nMemFree:        16000000 kB\n' >"$HG/meminfo-16g"
printf 'MemTotal:       8050000 kB\n' >"$HG/meminfo-8g"
printf 'MemTotal:       4000000 kB\n' >"$HG/meminfo-4g"
printf 'MemTotal:       15728640 kB\n' >"$HG/meminfo-at-floor"
printf 'MemTotal:       15728639 kB\n' >"$HG/meminfo-under-floor"
printf 'MemTotal:       banana kB\n' >"$HG/meminfo-garbage"
printf 'MemFree:        123 kB\n' >"$HG/meminfo-no-total"

hg_want() {
    (
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-hugepages"
        hugepages_want "$1"
    )
}
assert_eq "16 GiB machine keeps the full 3072-page pool" "$(hg_want "$HG/meminfo-16g")" "3072"
assert_eq "exactly the 15 GiB floor keeps the full pool (a real 16 GB box clears it)" "$(hg_want "$HG/meminfo-at-floor")" "3072"
assert_eq "just under the floor reduces to 2560 pages (both RandomX datasets still fit)" "$(hg_want "$HG/meminfo-under-floor")" "2560"
assert_eq "8 GiB machine reduces to 2560 pages" "$(hg_want "$HG/meminfo-8g")" "2560"
assert_eq "4 GiB machine releases the reservation (0 pages)" "$(hg_want "$HG/meminfo-4g")" "0"
assert_eq "garbage MemTotal keeps the full baked pool (degrade only on evidence)" "$(hg_want "$HG/meminfo-garbage")" "3072"
assert_eq "missing MemTotal keeps the full baked pool" "$(hg_want "$HG/meminfo-no-total")" "3072"

# ONE definition, three copies: the overlay script's full value must match the CLI's
# PITHEAD_HUGEPAGES and the rootfs's baked sysctl line — drift here re-opens the silent floor.
cli_pages=$(run_sourced "$SANDBOX" eval 'echo "$PITHEAD_HUGEPAGES"')
overlay_pages=$(
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    echo "$FULL_PAGES"
)
assert_eq "overlay full pool matches the CLI's PITHEAD_HUGEPAGES" "$overlay_pages" "$cli_pages"
if grep -q "vm.nr_hugepages=$cli_pages" "$ROOT/os/rootfs/Dockerfile"; then
    ok "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)"
else
    bad "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)" \
        "no vm.nr_hugepages=$cli_pages line in os/rootfs/Dockerfile"
fi

# main, degraded tier: shrinks the pool file, leaves the plain-words marker doctor reads.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-8g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "low-RAM boot shrinks the pool to the reduced target" "$(cat "$HG/nr_hugepages")" "2560"
assert_contains "low-RAM boot announces the degrade on the console/journal" "$out" "below the supported 16 GB"
assert_contains "degraded marker names the supported floor in plain words" "$(cat "$HG/marker" 2>/dev/null)" "16 GB"
assert_eq "marker records the chosen page count — the authority later writers honour" \
    "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "2560"
assert_not_contains "degrade message carries no issue numbers (operator text)" "$out" "#9"

# main, too-small tier: releases the pool entirely and says the stack will not run.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-4g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "far-below-floor boot releases the reservation" "$(cat "$HG/nr_hugepages")" "0"
assert_contains "far-below-floor boot says the stack will not run reliably" "$out" "will not run reliably"
assert_eq "released marker records zero pages" "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "0"

# main, supported tier: a strict no-op — pool untouched, no marker, nothing said.
printf '3072\n' >"$HG/nr_hugepages"
rm -f "$HG/marker"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-16g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "supported machine leaves the baked pool alone" "$(cat "$HG/nr_hugepages")" "3072"
assert_eq "supported machine writes no degraded marker" "$(cat "$HG/marker" 2>/dev/null || echo absent)" "absent"
assert_eq "supported machine says nothing" "$out" ""

# doctor reads the marker as a WARN — never FAIL, so the A/B commit gate (which takes doctor's
# exit code) still commits a degraded-but-serving box. The words on line one are for the human;
# the pages= record under them is for the writers, and doctor must not leak it.
printf 'This machine has 7.7 GiB of RAM - below the supported 16 GB. Reduced reservation.\npages=2560\n' >"$HG/marker"
out=$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" check_hugepages_degraded 2>&1)
assert_contains "doctor surfaces the degraded-hugepages message as a WARN" "$out" "WARN"
assert_contains "doctor repeats the boot-time message verbatim" "$out" "below the supported 16 GB"
assert_not_contains "doctor never FAILs on the degrade (commit gate must still pass)" "$out" "FAIL"
assert_not_contains "doctor repeats the words, not the machine record" "$out" "pages=2560"
rc=$(
    PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" check_hugepages_degraded >/dev/null 2>&1
    echo $?
)
assert_rc "no marker, no verdict (rc 0, silent off the appliance)" "$rc" "0"

# The decision reader (hugepages_decision_pages) can only ever LOWER the budget: a corrupt
# record at or above the full pool reads as the full pool, and no marker means the full budget
# — so DIY hosts and healthy appliances keep the exact pre-#977 behavior.
printf 'words\npages=9999\n' >"$HG/marker"
assert_eq "a record above the budget is capped at the budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"
assert_eq "no marker reads as the full budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"

echo "== unit: hugepages_boot_verdict — a bare boot can tell ran-and-no-op from never-ran (#1212) =="
# tests/os/run.sh's phase_boot cannot be driven from here (it needs a real KVM guest), but the
# verdict it now checks is pure text-matching over two already-observed strings
# (HugePages_Total, `systemctl is-active` output) — #1212 pulled it into
# tests/os/hugepages-boot-verdict.sh for exactly this reason: the discrimination the issue asked
# for is provable with fixtures, without a bench boot. The case that matters is the first pair
# below: the SAME HugePages_Total (3072 — the baked sysctl reserves it whether the unit ran or
# not) must verdict differently once the unit's own record disagrees.
# Mutation run: drop the is-active check and fall back to judging HugePages_Total alone -> the
# "never ran" assertion flips from fail to pass, silently reintroducing #1212.
hbv() { # <hugepages-total> <is-active-output> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/hugepages-boot-verdict.sh"
        hugepages_boot_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "ran + full pool: passes" \
    "$(hbv 3072 active)" "0 hugepages sizing unit ran this boot and left the full pool intact (3072 pages)"
assert_eq "never ran + the SAME full pool: fails — the #1212 case a pool-only check missed" \
    "$(hbv 3072 inactive)" "1 hugepages sizing unit did not run this boot (is-active: inactive) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the pool is short: fails" \
    "$(hbv 2560 active)" "1 hugepages sizing unit ran but the pool is short (HugePages_Total: 2560, want >= 3072)"
assert_eq "never ran + unreadable is-active: fails, names it unreadable" \
    "$(hbv "" "")" "1 hugepages sizing unit did not run this boot (is-active: unreadable) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the page count is garbage: fails cleanly, no arithmetic error" \
    "$(hbv banana active)" "1 hugepage pool unreadable at boot (HugePages_Total: banana, want >= 3072)"
unset -f hbv

echo "== unit: restore_live_state_verdict — a restore leaves proof it is RUNNING, not just unpacked (#1091) =="
# tests/os/run.sh's phase_install restore leg cannot be driven from here (it needs a real KVM
# guest, a genuine encrypted backup, and the wizard's HTTP upload path), but the verdict it now
# checks is pure text-matching over two already-observed strings (`podman ps` names, /api/state's
# live stratum wallet) — #1091 pulled it into tests/os/restore-live-state-verdict.sh for exactly
# that reason. The case that matters is the second pair below: `config.json` on disk (proven by a
# separate assertion in the battery) says nothing about whether the stack is actually RUNNING
# it — the verdict must fail that case even though the file landed.
# Mutation run: drop the live-wallet comparison and fall back to judging `podman ps` alone -> the
# "stack up but wallet never came back" and "stack up but wrong wallet" cases both flip from fail
# to pass, silently reintroducing #1091.
# The same fixture wallet tests/os/run.sh's battery uses (HARNESS_WALLET) — any well-formed
# address works here since the verdict only ever string-compares two values, never parses one.
RLV_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
rlv() { # <podman-ps-names> <live-wallet> <want-wallet> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/restore-live-state-verdict.sh"
        restore_live_state_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "stack up + live wallet matches: passes" \
    "$(rlv "dashboard caddy monerod" "$RLV_WALLET" "$RLV_WALLET")" \
    "0 the restored machine's LIVE state (p2pool's own running config) carries the restored wallet — not just the unpacked archive file"
assert_eq "stack never came up: fails — the #1091 case a file-only check missed" \
    "$(rlv "" "" "$RLV_WALLET")" \
    "1 the stack never came up on the restored machine (podman ps: 'none') — config.json on disk is not proof the machine is RUNNING what was restored (#1091)"
assert_eq "stack up but live wallet never came back: fails, names it unreadable" \
    "$(rlv "dashboard caddy" "" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'none')"
assert_eq "stack up but live wallet is a fresh/different address: fails — config.json alone would have missed this too" \
    "$(rlv "dashboard caddy" "44SomeFreshUnrelatedAddress" "$RLV_WALLET")" \
    "1 the stack is up but live state's wallet is '44SomeFreshUnrelatedAddress', not the restored '$RLV_WALLET' — the restore landed a file but the running stack does not reflect it (#1091)"
assert_eq "stack up but /api/state answered literal Unknown/null: still fails, not treated as a match" \
    "$(rlv "caddy dashboard" "Unknown" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'Unknown')"
unset -f rlv
unset RLV_WALLET

echo "== unit: reinstall_prefill_verdict — a wallet match alone cannot prove which path produced it (#1038) =="
# tests/os/run.sh's reinstall pre-fill check cannot be driven from here (it needs a real KVM
# guest reinstalled over an existing install), but the verdict it now checks is pure
# text-matching over three already-observed signals (the branch's own console log line, the
# wallet match, the password-leak check) — #1038 pulled it into
# tests/os/reinstall-prefill-verdict.sh for exactly that reason: the discrimination the issue
# asked for is provable with fixtures, without a bench boot. The case that matters is the first
# pair below: a wallet match with NO console record of the branch having run (the exact shape
# #1038 found passing for four consecutive batteries) must verdict as a failure.
# Mutation run: drop the branch_logged check and judge by the wallet match alone -> the
# "branch never logged" case flips from fail to pass, silently reintroducing #1038.
rpv() { # <branch-logged> <wallet-prefilled> <password-leaked> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/reinstall-prefill-verdict.sh"
        reinstall_prefill_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "branch ran, wallet matched, no password: passes" \
    "$(rpv 1 1 0)" "0 reinstall pre-fill ran this boot and published the previous install's non-secret answers (secrets left out)"
assert_eq "wallet matched but the branch never logged: fails — the #1038 case a wallet-only check missed" \
    "$(rpv 0 1 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "branch ran but the wallet never reached the page: fails" \
    "$(rpv 1 0 0)" "1 the pre-fill branch ran but the previous install's wallet never reached the page"
assert_eq "branch ran, wallet matched, but a password leaked: fails" \
    "$(rpv 1 1 1)" "1 a password crossed into the reinstall page's pre-filled state"
assert_eq "neither the branch nor the wallet: fails on the branch record first" \
    "$(rpv 0 0 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "empty inputs (unset shell vars): treated as not-logged, fails cleanly" \
    "$(rpv "" "" "")" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
unset -f rpv

echo "== unit: pithead-media-config — physical-presence media channel (#786 sub-issue D) =="
# Source the boot leg (functions only — its main is guarded) and drive its pieces with stubbed
# lsblk/mount/umount and a real (sandboxed) copy of pithead for validation — the same two-layer
# style pithead-data-reset's block above uses: fake the hardware, keep the decision logic real.
MC="$SANDBOX/media-config"
mkdir -p "$MC/bin"
cp "$ROOT/pithead" "$ROOT/config.reference.json" "$ROOT/config.core-keys.json" "$MC/"

# lsblk stub: prints whatever TSV the test staged, so _removable_fat_partitions' own awk filter
# runs for real against controlled input.
cat >"$MC/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
cat "${LSBLK_OUT:?}"
EOF
# mount stub: simulates `mount -o <ro|rw> <device> <mountpoint>` by copying $MOUNT_SRC's contents
# into the mountpoint (refusing any device but the one under test) and logging the mountpoint so
# a test can inspect what ended up there after an in-script `rm` — real bind semantics are a KVM
# concern; the decision logic (which device, which flag, what gets removed) is not.
cat >"$MC/bin/mount" <<'EOF'
#!/usr/bin/env bash
# Flag-agnostic: the channel mounts with pinned-type/hardening options (-t vfat -o ro,nosuid,...),
# so device and mountpoint are simply the last two arguments.
argv=("$@")
n=${#argv[@]}
dev="${argv[n - 2]}" mnt="${argv[n - 1]}"
[ "$dev" = "${MOUNT_DEVICE:-/dev/fake1}" ] || exit 1
mkdir -p "$mnt"
cp -a "${MOUNT_SRC:-/dev/null}"/. "$mnt"/ 2>/dev/null
[ -n "${MOUNT_LOG:-}" ] && printf '%s\n' "$mnt" >>"$MOUNT_LOG"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$MC/bin/umount"
chmod +x "$MC/bin/lsblk" "$MC/bin/mount" "$MC/bin/umount"

# A merged config that carries dashboard.auth.password sends media_validate_config's fresh bash
# into parse_and_validate_config's caddy hash branch, which greps docker-compose.yml at CWD for
# the pinned image and shells out to `docker run`. Give this section the #8 auth tests' hash-
# answering docker stub plus a caddy-pinned one-line compose fixture, and run those legs from
# $MC — the hash lands on the stub, never on a real (network-reaching) docker or the repo's
# compose file.
make_stubs "$MC/bin"
printf 'image: caddy:0.0.0@sha256:0000000000000000000000000000000000000000000000000000000000000000\n' >"$MC/docker-compose.yml"

printf 'sda\tdisk\t0\t\nsda1\tpart\t0\text4\nsdb\tdisk\t1\t\nsdb1\tpart\t1\tvfat\n' >"$MC/lsblk-out"

echo "== unit: _removable_fat_partitions =="
out=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    source "$ROOT/os/overlay/pithead-media-config"
    _removable_fat_partitions
)
assert_eq "removable FAT partitions filtered from lsblk (skips internal disk + a non-FAT removable)" "$out" "/dev/sdb1"

echo "== unit: media_find_config =="
STICK="$MC/stick"
mkdir -p "$STICK"
printf '{"staged":true}' >"$STICK/pithead-config.json"
result=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK"
    source "$ROOT/os/overlay/pithead-media-config"
    media_find_config
)
assert_eq "media_find_config names the carrying partition" "${result%%$'\t'*}" "/dev/sdb1"
found_copy="${result#*$'\t'}"
if [ -s "$found_copy" ] && cmp -s "$found_copy" "$STICK/pithead-config.json"; then
    ok "media_find_config copies the staged file out unmodified"
else
    bad "media_find_config copies the staged file out unmodified" "missing or altered: $found_copy"
fi
rm -f "$found_copy"

rc=$(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$MC/empty-stick"
    mkdir -p "$MOUNT_SRC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_find_config >/dev/null 2>&1
    echo $?
)
assert_eq "media_find_config returns 1 when no candidate carries the file" "$rc" "1"

echo "== unit: media_merge_config (settings the stick does not name keep their running values) =="
cat >"$MC/running-full.json" <<EOF
{"monero":{"wallet_address":"$VALID_PRIMARY","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"},"dashboard":{"auth":{"password":"the-firstboot-password"},"control":{"enabled":true}},"tor":{"auto_heal":true}}
EOF
printf '{"p2pool":{"pool":"nano"}}' >"$MC/minimal-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/minimal-stick.json"
)
assert_eq "the named setting changes" "$(jq -r '.p2pool.pool' "$merged")" "nano"
# THE assertion that separates a deep merge from a shallow one. Every other check below reads a
# key in a top-level object the stick never names, and `.[0] + .[1]` preserves those too — so the
# suite stayed byte-identical under the one-character mutation that reverts the merge and re-opens
# #965. stratum_password is the sibling of the key the stick DOES name: a shallow merge replaces
# the whole p2pool object and takes the secret with it.
assert_eq "a secret beside the named key survives — the merge is deep, not a shallow replace" \
    "$(jq -r '.p2pool.stratum_password' "$merged")" "auto"
assert_eq "the unnamed dashboard password is preserved, not dropped" \
    "$(jq -r '.dashboard.auth.password' "$merged")" "the-firstboot-password"
assert_eq "the unnamed appliance defaults are preserved (control.enabled)" \
    "$(jq -r '.dashboard.control.enabled' "$merged")" "true"
assert_eq "the unnamed appliance defaults are preserved (tor.auto_heal)" \
    "$(jq -r '.tor.auto_heal' "$merged")" "true"
assert_eq "unnamed node credentials carry forward — validation has nothing left to regenerate" \
    "$(jq -r '.monero.node_password' "$merged")" "a-generated-password-1"
rm -f "$merged"

printf '{"tor":{"auto_heal":null}}' >"$MC/null-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/null-stick.json"
)
assert_eq "naming a setting null clears it — the documented unset spelling" \
    "$(jq -r '.tor.auto_heal == null' "$merged")" "true"
rm -f "$merged"

printf 'not json at all' >"$MC/broken-stick.json"
merged=$(
    source "$ROOT/os/overlay/pithead-media-config"
    media_merge_config "$MC/running-full.json" "$MC/broken-stick.json"
)
if cmp -s "$MC/broken-stick.json" "$merged"; then
    ok "an unmergeable stick file passes through as-is, so validation reports ITS error"
else
    bad "an unmergeable stick file passes through as-is" "merge altered or dropped it"
fi
rm -f "$merged"

echo "== unit: media_validate_config (reuses the pre-seed validation engine) =="
cat >"$MC/good.json" <<EOF
{"monero":{"wallet_address":"$VALID_PRIMARY","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"}}
EOF
cat >"$MC/bad.json" <<'EOF'
{"monero":{"wallet_address":"nope"},"tari":{"wallet_address":"t"}}
EOF
validated=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    media_validate_config "$MC/good.json"
)
if [ -s "$validated" ]; then
    ok "a valid candidate validates and yields a scratch file"
else
    bad "a valid candidate validates and yields a scratch file" "no output"
fi
if cmp -s "$MC/good.json" "$validated"; then
    ok "a candidate that already carries its node credentials validates byte-identical"
else
    bad "a candidate that already carries its node credentials validates byte-identical" "$(diff "$MC/good.json" "$validated" 2>&1 | head -3)"
fi
rm -f "$validated"

rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    media_validate_config "$MC/bad.json" >/dev/null 2>&1
    echo $?
)
assert_eq "an invalid candidate is rejected, not installed" "$rc" "1"

echo "== unit: media_config_diff / media_config_identical (masked, wallet shown in full) =="
cat >"$MC/changed.json" <<EOF
{"monero":{"wallet_address":"44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg","node_username":"admin","node_password":"a-generated-password-1"},"tari":{"wallet_address":"$VALID_TARI"},"p2pool":{"pool":"mini","stratum_password":"auto"},"dashboard":{"auth":{"password":"a-new-dashboard-password"}}}
EOF
diffout=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON=$(_secret_paths_json) # the real fetch, against the sandboxed pithead copy
    media_config_diff "$MC/good.json" "$MC/changed.json"
)
assert_contains "the payout wallet change shows old -> new in full (that IS the point)" "$diffout" "$VALID_PRIMARY -> 44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
assert_contains "a changed secret (dashboard password) names the path" "$diffout" "dashboard.auth.password"
assert_not_contains "a changed secret never shows the new value" "$diffout" "a-new-dashboard-password"

rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON=$(_secret_paths_json)
    media_config_identical "$MC/good.json" "$MC/good.json"
    echo $?
)
assert_eq "identical configs -> media_config_identical true" "$rc" "0"
rc=$(
    export PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    # shellcheck disable=SC2034 # read by the sourced media_config_* functions, not directly here
    SECRET_PATHS_JSON=$(_secret_paths_json)
    media_config_identical "$MC/good.json" "$MC/changed.json"
    echo $?
)
assert_eq "a real change -> media_config_identical false" "$rc" "1"

# Masking fails CLOSED: with no secret-path list there is no diff and no "identical" verdict —
# an earlier draft fell back to an empty list, which printed raw secret values to the console.
rc=$(
    export PITHEAD_MEDIA_BIN="$MC/does-not-exist"
    source "$ROOT/os/overlay/pithead-media-config"
    _secret_paths_json >/dev/null 2>&1
    echo $?
)
assert_eq "an unreadable host program -> _secret_paths_json refuses (rc 1, never '[]')" "$rc" "1"
out=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON="" media_config_diff "$MC/good.json" "$MC/changed.json"
    echo "rc=$?"
)
assert_eq "no secret list -> no diff output, distinct rc" "$out" "rc=2"
rc=$(
    source "$ROOT/os/overlay/pithead-media-config"
    SECRET_PATHS_JSON="" media_config_identical "$MC/good.json" "$MC/good.json"
    echo $?
)
assert_eq "no secret list -> identical is NOT assumed (fail closed)" "$rc" "1"

echo "== unit: media_confirm_gate (abort/apply state machine, no real 60s wait) =="
gate() { # $1 device-present override rc, $2 key sequence (space-separated, 'timeout' = no key)
    # shellcheck disable=SC2206  # deliberate word-splitting: $2 is a space-separated key sequence
    local present_rc="$1" keys=($2) i=0
    (
        source "$ROOT/os/overlay/pithead-media-config"
        media_device_present() { return "$present_rc"; }
        media_read_key() {
            local k="${keys[$i]:-timeout}"
            i=$((i + 1))
            [ "$k" = "timeout" ] && return 1
            printf '%s' "$k"
        }
        media_confirm_gate /dev/fake 3
    )
}
assert_eq "countdown exhausted with no keypress -> apply" "$(gate 0 'timeout timeout timeout')" "apply"
assert_eq "media removed mid-countdown -> abort" "$(gate 1 '')" "abort"
assert_eq "'a' keypress -> apply immediately, before the countdown ends" "$(gate 0 a)" "apply"
assert_eq "'n' keypress -> abort immediately" "$(gate 0 n)" "abort"
assert_eq "an unrecognized key is ignored, not treated as abort" "$(gate 0 'x x apply')" "apply"

echo "== unit: media_consume (deletes the staged file on the medium, never renames it) =="
STICK2="$MC/stick2"
mkdir -p "$STICK2"
printf '{"staged":true}' >"$STICK2/pithead-config.json"
: >"$MC/mount.log"
(
    export PATH="$MC/bin:$PATH"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK2" MOUNT_LOG="$MC/mount.log"
    source "$ROOT/os/overlay/pithead-media-config"
    media_consume "/dev/sdb1"
)
mounted_at=$(tail -1 "$MC/mount.log")
if [ -n "$mounted_at" ] && [ ! -f "$mounted_at/pithead-config.json" ]; then
    ok "the consumed configuration is removed from the medium (installer's own hygiene, not a renamed copy)"
else
    bad "the consumed configuration is removed from the medium" "still present at ${mounted_at:-<no mount>}"
fi

echo "== unit: pithead-media-config main() — identical short-circuit vs. a real apply =="
RUN_CFG="$MC/running.json"
cp "$MC/good.json" "$RUN_CFG"
STICK3="$MC/stick-identical"
mkdir -p "$STICK3"
cp "$MC/good.json" "$STICK3/pithead-config.json"
: >"$MC/mount.log"
(
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK3" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() {
        echo "media_confirm_gate must not be called for an identical config" >&2
        echo apply
    }
    main
) >"$MC/identical.out" 2>&1
if cmp -s "$MC/good.json" "$RUN_CFG"; then
    ok "an identical staged config never touches the running config.json"
else
    bad "an identical staged config never touches the running config.json" "it was rewritten"
fi
assert_not_contains "an identical config never reaches the confirm gate (no ceremony)" "$(cat "$MC/identical.out")" "must not be called"
assert_contains "an identical config says so on the console" "$(cat "$MC/identical.out")" "would change nothing"
[ -f "$STICK3/pithead-config.json" ] && ok "an identical config is not consumed — nothing was applied" ||
    bad "an identical config is not consumed" "the stick's file was removed anyway"

STICK4="$MC/stick-apply"
mkdir -p "$STICK4"
cp "$MC/changed.json" "$STICK4/pithead-config.json"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — the hash branch needs $MC's compose fixture + docker stub
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK4" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo apply; }
    main
) >"$MC/apply.out" 2>&1
# jq-level equality, not cmp: the merge stage reformats, and changed.json names every key
# good.json has, so the merged result must equal changed.json setting-for-setting.
if [ "$(jq -S . "$MC/changed.json")" = "$(jq -S . "$RUN_CFG")" ]; then
    ok "a confirmed change is written to the running config.json — the changed setting took effect"
else
    bad "a confirmed change is written to the running config.json" "$(diff <(jq -S . "$MC/changed.json") <(jq -S . "$RUN_CFG") 2>&1 | head -3)"
fi
mounted_at=$(tail -1 "$MC/mount.log")
[ -n "$mounted_at" ] && [ ! -f "$mounted_at/pithead-config.json" ] &&
    ok "the applied stick is consumed so it cannot re-apply next boot" ||
    bad "the applied stick is consumed" "still present"
assert_contains "the applied change is announced on the console" "$(cat "$MC/apply.out")" "applied"

STICK5="$MC/stick-abort"
mkdir -p "$STICK5"
cp "$MC/changed.json" "$STICK5/pithead-config.json"
cp "$MC/good.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK5" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo abort; }
    main
) >"$MC/abort.out" 2>&1
if cmp -s "$MC/good.json" "$RUN_CFG"; then
    ok "a cancelled change never touches the running config.json"
else
    bad "a cancelled change never touches the running config.json" "it was rewritten"
fi
[ -f "$STICK5/pithead-config.json" ] && ok "a cancelled change is not consumed — the stick still carries it" ||
    bad "a cancelled change is not consumed" "the stick's file was removed anyway"
# #1061: the running config staying untouched is not proof the operator was ever told — a
# cancelled change looks identical to a silent one from that assertion alone. This is the one
# that would have caught the console promising a confirmation that never appeared.
assert_contains "the cancelled change is announced on the console" "$(cat "$MC/abort.out")" \
    "Media configuration channel: cancelled — no changes applied."

# main() must FAIL CLOSED end to end when the secret-path list can't be read: with a broken host
# program, no diff (which could leak raw secret values) is ever shown and no config is applied.
STICK6="$MC/stick-nosecrets"
mkdir -p "$STICK6"
cp "$MC/changed.json" "$STICK6/pithead-config.json"
cp "$MC/good.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # changed.json carries dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK6" MOUNT_LOG="$MC/mount.log"
    # Validation still works (real pithead), but the secret-path fetch reads a DIFFERENT, broken
    # binary — the one place masking could silently turn off.
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    _secret_paths_json() { return 1; }             # simulate an unreadable/broken host program
    media_config_diff() { echo "DIFF-WAS-SHOWN"; } # would leak values if ever reached
    media_confirm_gate() { echo apply; }
    main
) >"$MC/nosecrets.out" 2>&1
assert_eq "no secret list -> the running config is never rewritten" "$(cmp -s "$MC/good.json" "$RUN_CFG" && echo same)" "same"
assert_not_contains "no secret list -> no diff is ever displayed" "$(cat "$MC/nosecrets.out")" "DIFF-WAS-SHOWN"
assert_contains "no secret list -> the stage refuses out loud" "$(cat "$MC/nosecrets.out")" "cannot read the secret-path list"

# The issue-965 shape end to end: a stick naming ONLY the pool tier must change the pool tier
# and NOTHING else — the generated dashboard login, the appliance defaults and the node
# credentials all survive, and none of them appear in the console diff as a change.
STICK7="$MC/stick-minimal"
mkdir -p "$STICK7"
cp "$MC/minimal-stick.json" "$STICK7/pithead-config.json"
cp "$MC/running-full.json" "$RUN_CFG"
: >"$MC/mount.log"
(
    cd "$MC" || exit 1 # the merged config carries the running dashboard.auth.password — see the stub note above
    export PATH="$MC/bin:$PATH" LSBLK_OUT="$MC/lsblk-out"
    export MOUNT_DEVICE="/dev/sdb1" MOUNT_SRC="$STICK7" MOUNT_LOG="$MC/mount.log"
    export PITHEAD_MEDIA_BIN="$MC/pithead" PITHEAD_MEDIA_CONFIG="$RUN_CFG" PITHEAD_MEDIA_DIR="$MC"
    source "$ROOT/os/overlay/pithead-media-config"
    media_confirm_gate() { echo apply; }
    main
) >"$MC/minimal.out" 2>&1
assert_eq "minimal stick: the named setting applies (p2pool.pool)" "$(jq -r '.p2pool.pool' "$RUN_CFG")" "nano"
assert_eq "minimal stick: the dashboard password it never named is kept, not dropped or regenerated" \
    "$(jq -r '.dashboard.auth.password' "$RUN_CFG")" "the-firstboot-password"
assert_eq "minimal stick: dashboard.control.enabled survives" "$(jq -r '.dashboard.control.enabled' "$RUN_CFG")" "true"
assert_eq "minimal stick: tor.auto_heal survives" "$(jq -r '.tor.auto_heal' "$RUN_CFG")" "true"
assert_eq "minimal stick: node credentials do not churn" "$(jq -r '.monero.node_password' "$RUN_CFG")" "a-generated-password-1"
assert_contains "minimal stick: the diff names the one real change" "$(cat "$MC/minimal.out")" "p2pool.pool: mini -> nano"
assert_not_contains "minimal stick: nothing unnamed shows up as changed" "$(cat "$MC/minimal.out")" "dashboard.auth.password"
assert_contains "minimal stick: the console states the keep-what-you-do-not-name rule" \
    "$(cat "$MC/minimal.out")" "Settings the file does not name keep their current values."

echo "== unit: os/build-image.sh — --fresh-index flag parsing + the 404 remedy hint (#929) =="
# PITHEAD_BUILD_IMAGE_TEST makes the script return right after arg parsing (before docker), so
# these run its real argument handling and apt_fetch_failure_hint without a build.
build_image_test() {
    (
        export PITHEAD_BUILD_IMAGE_TEST=1
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh" "$@"
        [ "${FRESH_INDEX:-0}" = "1" ] && echo "FRESH_INDEX=1"
        declare -f apt_fetch_failure_hint >/dev/null && echo "HINT_FN_DEFINED"
    )
}
assert_contains "--fresh-index sets FRESH_INDEX" "$(build_image_test --fresh-index)" "FRESH_INDEX=1"
assert_not_contains "bare invocation leaves FRESH_INDEX unset" "$(build_image_test)" "FRESH_INDEX=1"
assert_contains "apt_fetch_failure_hint is defined after sourcing" "$(build_image_test)" "HINT_FN_DEFINED"

unknown_flag_out="$("$ROOT/os/build-image.sh" --bogus 2>&1 || true)"
assert_contains "unknown argument is rejected" "$unknown_flag_out" "unknown argument: --bogus"
assert_contains "unknown-argument error names --fresh-index" "$unknown_flag_out" "--fresh-index"

# --fresh-index composes with --ssh: parsed left-to-right, then --ssh's own missing-key check
# exits before docker, proving --fresh-index didn't swallow the next argument.
missing_key_out="$("$ROOT/os/build-image.sh" --fresh-index --ssh "$SANDBOX/no-such-key.pub" 2>&1 || true)"
assert_contains "--fresh-index then --ssh with a missing key still hits --ssh's own error" "$missing_key_out" "--ssh: no public key found"

# Exercise the hint function directly by sourcing the same way and calling it.
run_hint() {
    (
        local log="$1"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # `source file` with no args keeps the caller's $@ — clear it so build-image.sh's
        # own arg loop doesn't try to parse the log tail as a CLI flag.
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh"
        apt_fetch_failure_hint "$log" 2>&1
    )
}
assert_contains "404 signature triggers the --fresh-index remedy" "$(run_hint 'E: Failed to fetch ... 404  Not Found')" "--fresh-index"
assert_contains "'Unable to fetch' signature triggers the remedy" "$(run_hint 'E: Unable to fetch some archives, maybe run apt-get update')" "--fresh-index"
assert_eq "an unrelated failure prints no hint" "$(run_hint 'E: some other build error')" ""

echo "== unit: pithead-ssh-host-keys — per-machine host key on /data, generated once (#894/#980) =="
# Real ssh-keygen against a sandboxed key dir (PITHEAD_SSH_HOST_KEYS_DIR — the same env-seam
# shape pithead-machine-id carries). chown is PATH-stubbed: the suite is not root, and ownership
# on the box is systemd's root context, not logic this tier can prove. stdin is /dev/null on
# every run — the systemd condition the wedge-recovery case below depends on.
SHK="$SANDBOX/ssh-host-keys"
mkdir -p "$SHK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHK/bin/chown"
chmod +x "$SHK/bin/chown"
shk_key="$SHK/data-ssh/ssh_host_ed25519_key"
shk_run() {
    (
        export PATH="$SHK/bin:$PATH" PITHEAD_SSH_HOST_KEYS_DIR="$SHK/data-ssh"
        sh "$ROOT/os/overlay/pithead-ssh-host-keys" </dev/null 2>&1
    )
}
out=$(shk_run)
assert_rc "first run on an empty /data generates the key" "$?" "0"
assert_contains "generation is announced (a silent identity change is the bug class)" "$out" "generated a new host key"
shk_fp1=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp1" ] && ok "the generated key is a loadable ed25519 key ($shk_fp1)" ||
    bad "the generated key is a loadable ed25519 key" "ssh-keygen -lf failed on $shk_key"
assert_eq "key dir is owner-only (700)" "$(stat -c '%a' "$SHK/data-ssh" 2>/dev/null || stat -f '%Lp' "$SHK/data-ssh")" "700"
assert_eq "private key is owner-only (600)" "$(stat -c '%a' "$shk_key" 2>/dev/null || stat -f '%Lp' "$shk_key")" "600"
assert_eq "public key is world-readable (644)" "$(stat -c '%a' "$shk_key.pub" 2>/dev/null || stat -f '%Lp' "$shk_key.pub")" "644"
# Idempotence IS the identity contract (#894): a second start must find the key and change
# NOTHING — a regeneration here is exactly the host-key churn an A/B update must never cause.
out=$(shk_run)
assert_rc "second run exits 0" "$?" "0"
assert_not_contains "second run regenerates nothing" "$out" "generated"
assert_eq "second run leaves the key byte-identical" "$(ssh-keygen -lf "$shk_key" | awk '{print $2}')" "$shk_fp1"
# Wedge recovery: an interrupted prior run leaves an empty key file (+ stale .pub). ssh-keygen
# prompts before overwriting an existing path, and with stdin on /dev/null that prompt reads EOF
# and refuses — the script must clear the partial file first or sshd wedges forever.
: >"$shk_key"
out=$(shk_run)
assert_rc "a stale empty key file is regenerated, not wedged on the overwrite prompt" "$?" "0"
shk_fp2=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp2" ] && ok "recovery produced a loadable key again" ||
    bad "recovery produced a loadable key again" "ssh-keygen -lf failed on $shk_key"

echo "== unit: pithead-mount-generator — /data + ESP follow the BOOTED disk, never a label (#926/#980) =="
# The generator against staged mountinfo files (PITHEAD_MOUNTINFO seam; GENDIR is already an
# argument). The staged lines keep the real shape — surrounding mounts, optional fields before
# the "-" separator — so the awk root-line/source extraction runs against what a kernel writes.
MG="$SANDBOX/mount-generator"
mkdir -p "$MG"
mg_run() { # $1 mountinfo file, $2 gendir
    (
        export PITHEAD_MOUNTINFO="$1"
        sh "$ROOT/os/overlay/pithead-mount-generator" "$2"
    )
}
cat >"$MG/mi-sda" <<'EOF'
24 30 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:5 - proc proc rw
29 1 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw,stripe=32
32 29 8:4 / /data rw,noatime shared:2 - ext4 /dev/sda4 rw
EOF
mg_run "$MG/mi-sda" "$MG/gen-sda"
assert_rc "generator succeeds on a /dev/sda2 root" "$?" "0"
mg_data=$(cat "$MG/gen-sda/data.mount" 2>/dev/null)
mg_esp=$(cat "$MG/gen-sda/boot-efi.mount" 2>/dev/null)
assert_contains "data.mount is partition 4 OF THE BOOT DISK" "$mg_data" "What=/dev/sda4"
assert_contains "data.mount mounts /data" "$mg_data" "Where=/data"
assert_contains "data.mount is ext4" "$mg_data" "Type=ext4"
assert_not_contains "data.mount never mounts by label" "$mg_data" "LABEL"
assert_contains "boot-efi.mount is partition 1 of the boot disk" "$mg_esp" "What=/dev/sda1"
assert_contains "boot-efi.mount mounts /boot/efi" "$mg_esp" "Where=/boot/efi"
assert_contains "the ESP mount is root-only (RAUC boot state lives there)" "$mg_esp" "Options=umask=0077"
assert_contains "the data mount orders before local-fs.target" "$mg_data" "Before=local-fs.target"
for u in data.mount boot-efi.mount; do
    if [ "$(readlink "$MG/gen-sda/local-fs.target.requires/$u")" = "../$u" ]; then
        ok "$u is required by local-fs.target (the boot waits for it)"
    else
        bad "$u is required by local-fs.target" "missing or wrong symlink"
    fi
done
# nvme/mmc naming: the partition number strips AND the 'p' separator comes back on the
# partition paths (nvme0n1p2 -> disk nvme0n1 -> partitions nvme0n1p4 / nvme0n1p1).
printf '29 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw\n' >"$MG/mi-nvme"
mg_run "$MG/mi-nvme" "$MG/gen-nvme"
assert_contains "an nvme root keeps the p separator: data" "$(cat "$MG/gen-nvme/data.mount")" "What=/dev/nvme0n1p4"
assert_contains "an nvme root keeps the p separator: ESP" "$(cat "$MG/gen-nvme/boot-efi.mount")" "What=/dev/nvme0n1p1"
# A root line with NO optional fields (the "-" comes right after the options) still parses —
# and vda-style names get no separator (vda2 -> vda4).
printf '29 1 254:2 / / rw,relatime - ext4 /dev/vda2 rw\n' >"$MG/mi-vda"
mg_run "$MG/mi-vda" "$MG/gen-vda"
assert_contains "a no-optional-fields root line parses (vda2 -> vda4)" "$(cat "$MG/gen-vda/data.mount")" "What=/dev/vda4"
# A container/unexpected root (source is not /dev/*) generates NOTHING rather than guessing.
printf '29 1 0:35 / / rw,relatime - overlay overlay rw\n' >"$MG/mi-ovl"
mg_run "$MG/mi-ovl" "$MG/gen-ovl"
assert_rc "a non-/dev root exits 0 (a generator must not fail the boot)" "$?" "0"
assert_eq "a non-/dev root generates no units" "$([ -e "$MG/gen-ovl" ] || echo none)" "none"

echo "== unit: os/rauc/loop-wait.sh — the partition wait demands block devices and polls its budget =="
# The negative half of the contract — all a non-root tier can prove: absent nodes and
# regular-file impostors both exhaust the poll and return 1. sleep/udevadm are function-stubbed
# so the 25-poll budget runs instantly. The positive half (real nodes appearing) runs for real
# on every image build — mkimage.sh and verify-image.sh both call this.
LW="$SANDBOX/loop-wait"
mkdir -p "$LW"
lw_run() { # $1 device path
    (
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/rauc/loop-wait.sh"
        udevadm() { :; }
        sleep() { echo x >>"$LW/sleeps"; }
        wait_loop_partitions "$1"
    )
}
: >"$LW/sleeps"
lw_run "$LW/loop0"
assert_rc "nodes that never appear -> rc 1" "$?" "1"
assert_eq "the wait polls its full 25-try budget, not a single-shot check" "$(wc -l <"$LW/sleeps" | tr -d ' ')" "25"
touch "$LW/loop0p1" "$LW/loop0p2"
lw_run "$LW/loop0"
assert_rc "regular files at p1/p2 do not satisfy the wait — block devices required" "$?" "1"

echo "== unit: apply converges the control units even when nothing changed (#33) =="
# doctor's fix instruction is "run './pithead apply' from this directory". A box whose units point
# at a dead install has an UNCHANGED config by definition — the fault is in the unit files, not
# config.json — so apply's "nothing to apply" early return used to make the prescribed fix a no-op
# on the only box the check fires for.
# Mutation: remove provision_control_runner from apply's no-change branch -> this goes red.
apply_noop_steps() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { :; }
        load_preserved_state() { :; }
        onion_missing() { return 1; }
        is_deployed() { return 0; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        env_changed_keys() { :; } # nothing changed
        # shellcheck disable=SC2034  # read by apply()'s own `onion_missing "$P2POOL_ONION"` gate
        # (pithead:9344) in the sourced $STACK script, unseen here — onion_missing is stubbed
        # above, but bash evaluates the argument before calling it, so set -u still requires this
        # bound. The tor-network split (#1105) moved this file's only OTHER $P2POOL_ONION
        # reference (the onion-provisioning probes) into test-tor-network.sh, which unmasked this
        # one for shellcheck's single-file view.
        P2POOL_ONION="abc.onion" # provisioning marker; read under `set -u` before the stub
        log() { :; }
        provision_control_runner() { echo provision; }
        compose_up_checked() { echo compose; }
        apply
    ) | grep -xE 'provision|compose' | tr '\n' ','
}
: >"$SANDBOX/.env"
assert_eq "a no-change apply still converges the control units, and recreates nothing" \
    "$(apply_noop_steps)" "provision,"
unset apply_noop_steps

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
