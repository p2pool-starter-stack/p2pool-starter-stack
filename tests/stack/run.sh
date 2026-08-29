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

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-upgrade.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-upgrade.sh" && domain_ran test-control-upgrade.sh "$_d0" "$?" || domain_ran test-control-upgrade.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-release-signing.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release-signing.sh" && domain_ran test-release-signing.sh "$_d0" "$?" || domain_ran test-release-signing.sh "$_d0" "$?"

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

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-dashboard.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard.sh" && domain_ran test-dashboard.sh "$_d0" "$?" || domain_ran test-dashboard.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-dashboard-onion.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard-onion.sh" && domain_ran test-dashboard-onion.sh "$_d0" "$?" || domain_ran test-dashboard-onion.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release.sh" && domain_ran test-release.sh "$_d0" "$?" || domain_ran test-release.sh "$_d0" "$?"

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

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-cli.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-cli.sh" && domain_ran test-cli.sh "$_d0" "$?" || domain_ran test-cli.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-config.sh" && domain_ran test-config.sh "$_d0" "$?" || domain_ran test-config.sh "$_d0" "$?"

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
# shellcheck source=tests/stack/test-control-add-only-ssrf.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-add-only-ssrf.sh" && domain_ran test-control-add-only-ssrf.sh "$_d0" "$?" || domain_ran test-control-add-only-ssrf.sh "$_d0" "$?"

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
# shellcheck source=tests/stack/test-control-deploy.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-deploy.sh" && domain_ran test-control-deploy.sh "$_d0" "$?" || domain_ran test-control-deploy.sh "$_d0" "$?"

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

# shellcheck source=tests/stack/test-wizard-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-wizard-setup.sh" && domain_ran test-wizard-setup.sh "$_d0" "$?" || domain_ran test-wizard-setup.sh "$_d0" "$?"

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

# shellcheck source=tests/stack/test-appliance-identity.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity.sh" && domain_ran test-appliance-identity.sh "$_d0" "$?" || domain_ran test-appliance-identity.sh "$_d0" "$?"

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

# shellcheck source=tests/stack/test-appliance-kernel-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-kernel-boot.sh" && domain_ran test-appliance-kernel-boot.sh "$_d0" "$?" || domain_ran test-appliance-kernel-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-reset.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-reset.sh" && domain_ran test-appliance-reset.sh "$_d0" "$?" || domain_ran test-appliance-reset.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-identity-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity-boot.sh" && domain_ran test-appliance-identity-boot.sh "$_d0" "$?" || domain_ran test-appliance-identity-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-media.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-media.sh" && domain_ran test-appliance-media.sh "$_d0" "$?" || domain_ran test-appliance-media.sh "$_d0" "$?"

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
