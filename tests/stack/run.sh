#!/usr/bin/env bash
#
# Dependency-free test suite for stack.sh (no bats required).
# Mixes unit tests (sourcing stack.sh and calling its functions) with black-box CLI tests
# (running a sandboxed copy of stack.sh with docker/sudo stubbed out). Run: tests/stack/run.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/stack.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

# Run a command with stack.sh sourced (functions available, no cd/main side effects),
# from a given working directory. Usage: run_sourced <dir> <cmd> [args...]
# shellcheck disable=SC1090  # STACK path is dynamic by design
run_sourced() {
    local dir="$1"; shift
    ( cd "$dir" || return; source "$STACK"; set +e; "$@" )
}

# A throwaway sandbox dir, cleaned on exit.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake docker that records calls and answers the few queries setup/apply make.
make_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose version"|"info") exit 0 ;;
  "exec tor test -f "*) exit 0 ;;
  "exec tor cat /var/lib/tor/monero/hostname") echo "mona.onion" ;;
  "exec tor cat /var/lib/tor/tari/hostname")   echo "taria.onion" ;;
  "exec tor cat /var/lib/tor/p2pool/hostname") echo "p2pa.onion" ;;
esac
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/sudo"
    chmod +x "$bin/docker" "$bin/sudo"
}

# ---------------------------------------------------------------------------
echo "== unit: resolve_default =="
assert_eq "auto -> default"        "$(run_sourced "$SANDBOX" resolve_default auto /def)"          "/def"
assert_eq "empty -> default"       "$(run_sourced "$SANDBOX" resolve_default '' /def)"            "/def"
assert_eq "DYNAMIC_DATA -> default" "$(run_sourced "$SANDBOX" resolve_default DYNAMIC_DATA /def)" "/def"
assert_eq "custom kept"            "$(run_sourced "$SANDBOX" resolve_default /my/dir /def)"        "/my/dir"

echo "== unit: assert_safe_dir =="
run_sourced "$SANDBOX" assert_safe_dir "/"       >/dev/null 2>&1; assert_rc "rejects /"        "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/home"   >/dev/null 2>&1; assert_rc "rejects /home"    "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir ""        >/dev/null 2>&1; assert_rc "rejects empty"    "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/srv/p2pool/data" >/dev/null 2>&1; assert_rc "allows real dir" "$?" "0"

echo "== unit: describe_change =="
assert_contains "prune is DEST"      "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 1 0)"        "DEST"
assert_contains "rpc lan is DEST"    "$(run_sourced "$SANDBOX" describe_change MONERO_RPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "wallet is DEST"     "$(run_sourced "$SANDBOX" describe_change MONERO_WALLET_ADDRESS a b)" "DEST"
assert_contains "xvb url is INFO"    "$(run_sourced "$SANDBOX" describe_change XVB_POOL_URL a b)"        "INFO"
assert_contains "data_dir is DEST"   "$(run_sourced "$SANDBOX" describe_change MONERO_DATA_DIR /a /b)"   "DEST"
assert_contains "tari mem is INFO"   "$(run_sourced "$SANDBOX" describe_change TARI_MEM_LIMIT 2048m 4g)" "INFO"

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' > "$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' > "$SANDBOX/new.env"
assert_eq "env_get_file reads value"      "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with ="     "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: node credential helpers =="
assert_eq "default username is admin" "$(run_sourced "$SANDBOX" default_node_username)" "admin"
PW="$(run_sourced "$SANDBOX" generate_node_password)"
assert_eq "generated password is 32 chars"   "${#PW}" "32"
assert_eq "generated password is alphanumeric" "$(printf '%s' "$PW" | tr -dc 'A-Za-z0-9')" "$PW"
PW2="$(run_sourced "$SANDBOX" generate_node_password)"
if [ "$PW" != "$PW2" ]; then ok "two generations differ"; else bad "two generations differ" "both were [$PW]"; fi
run_sourced "$SANDBOX" cred_needs_generating "" "PLACE";      assert_rc "empty needs generating"       "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "PLACE" "PLACE"; assert_rc "placeholder needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "real" "PLACE";  assert_rc "real value kept"              "$?" "1"

# ---------------------------------------------------------------------------
echo "== black-box: CLI dispatch =="
"$STACK" help >/dev/null 2>&1; assert_rc "help exits 0" "$?" "0"
assert_contains "help shows usage" "$("$STACK" help 2>&1)" "Usage:"
out="$("$STACK" frobnicate 2>&1)"; rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

echo "== black-box: guards =="
G="$SANDBOX/guard"; mkdir -p "$G/build/tari"; cp "$STACK" "$G/stack.sh"
cp "$ROOT/build/tari/config.toml.template" "$G/build/tari/" 2>/dev/null || true
make_stubs "$G/bin"
out="$(cd "$G" && PATH="$G/bin:$PATH" ./stack.sh apply 2>&1)"; rc=$?
assert_rc "apply without .env fails" "$rc" "1"
assert_contains "apply needs setup" "$out" "setup"

echo "== black-box: config validation =="
V="$SANDBOX/val"; mkdir -p "$V/build/tari"; cp "$STACK" "$V/stack.sh"; make_stubs "$V/bin"
cp "$ROOT/build/tari/config.toml.template" "$V/build/tari/"
mkdir -p "$V/data/monero" "$V/data/tari" "$V/data/p2pool" "$V/data/tor" "$V/data/dashboard" "$V/data/p2pool/stats"
seed_env() { cat > "$V/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
}
WALLET="49AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"banana"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"; rc=$?
assert_rc "invalid pool rejected" "$rc" "1"
assert_contains "invalid pool message" "$out" "p2pool.pool"

echo "== black-box: apply preserves secrets + propagates =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
DOCKER_LOG="$V/docker.log"; : > "$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_eq "pool flag propagated"  "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)"  "--mini"
assert_eq "token preserved"       "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
assert_eq "onion preserved"       "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_ONION_ADDRESS)" "p2pa.onion"
assert_eq "tari_required default"  "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"
assert_contains "compose up called" "$(cat "$DOCKER_LOG")" "compose up -d --remove-orphans"
# tari.mem_limit absent => "auto" is a safety ceiling: host RAM minus a >=2 GB reserve, floored at
# 2048m. Assert it ends in 'm', is >= the 2048m floor, and never exceeds physical RAM.
mem="$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)"
host_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
case "$mem" in
    *m) n="${mem%m}"
        if [ "$n" -ge 2048 ] && { [ "$host_ram_mb" -le 0 ] || [ "$n" -le "$host_ram_mb" ]; }
        then ok "tari mem auto is a sane ceiling ($mem, host ${host_ram_mb}m)"
        else bad "tari mem auto sane ceiling" "got [$mem] on ${host_ram_mb}m host"; fi ;;
    *) bad "tari mem auto has m suffix" "got [$mem]" ;;
esac

# Non-blocking Tari (dashboard.tari_required:false) propagates as TARI_REQUIRED=false.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","tari_required":false} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_eq "tari_required propagated false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

# An explicit tari.mem_limit is passed through verbatim (overriding the "auto" host-RAM scaling).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mem_limit":"3072m"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_eq "tari mem_limit explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" "3072m"

echo "== black-box: local node creds auto-generated + persisted (#50) =="
# A local node with BLANK creds: apply must generate them, write them into .env AND back into
# config.json, and keep them stable on a second apply (don't regenerate every run).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"","node_password":""}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_contains "auto-gen is logged" "$out" "Auto-generated missing local"
env_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
assert_eq "blank username -> admin in .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" "admin"
assert_eq "generated password is 32 chars"  "${#env_pass}" "32"
assert_eq "username persisted to config.json" "$(jq -r '.monero.node_username' "$V/config.json")" "admin"
assert_eq "password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"
# Second apply must not rotate the now-populated creds.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_eq "password stable across apply" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"

# A REMOTE node with blank creds means "no auth" — leave it empty, don't invent credentials.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./stack.sh apply -y 2>&1)"
assert_eq "remote username left blank" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" ""
assert_eq "remote creds not persisted" "$(jq -r '.monero.node_username' "$V/config.json")" ""

echo "== black-box: status health check =="
# A docker stub driven by FAKE_STATES ("svc=state:health ..."; state "missing" = no container)
# so we can script each service's state and assert how `status` reports it.
make_status_stub() {
    local bin="$1"; mkdir -p "$bin"
    cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
sub="$*"
case "$sub" in
  "compose config --services")
      for kv in $FAKE_STATES; do echo "${kv%%=*}"; done ;;
  "compose ps -aq "*)
      svc="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$svc" ] && [ "${kv#*=}" != "missing" ] && echo "$svc"
      done ;;
  "inspect "*)
      cid="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$cid" ] && echo "${kv#*=}" | tr ':' ' '
      done ;;
esac
exit 0
EOF
    chmod +x "$bin/docker"
}
ST="$SANDBOX/status"; mkdir -p "$ST/bin"; cp "$STACK" "$ST/stack.sh"
make_status_stub "$ST/bin"
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' > "$ST/.env"
ALL_UP="tor=running:healthy monerod=running:healthy p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"

# All services up -> success, friendly summary.
out="$(cd "$ST" && FAKE_STATES="$ALL_UP" PATH="$ST/bin:$PATH" ./stack.sh status 2>&1)"; rc=$?
assert_rc "status: all up exits 0" "$rc" "0"
assert_contains "status: all-up summary" "$out" "All expected services are up"

# A node down + proxy stopped -> node flagged, proxy treated as intentional failover.
NODE_DOWN="${ALL_UP/monerod=running:healthy/monerod=exited:none}"; NODE_DOWN="${NODE_DOWN/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$NODE_DOWN" PATH="$ST/bin:$PATH" ./stack.sh status 2>&1)"; rc=$?
assert_rc "status: node down exits 1" "$rc" "1"
assert_contains "status: proxy stop is intentional" "$out" "likely intentional"

# A stopped p2pool/xmrig-proxy with healthy nodes is intentional — the nodes pass their
# healthchecks while still syncing and the dashboard holds the miner until they're synced
# (#35), so status reports it as likely-intentional (exit 0), not a fault.
PROXY_ONLY="${ALL_UP/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$PROXY_ONLY" PATH="$ST/bin:$PATH" ./stack.sh status 2>&1)"; rc=$?
assert_rc "status: proxy stop under sync hold exits 0" "$rc" "0"
assert_contains "status: proxy stop notes sync hold" "$out" "finish syncing"

P2POOL_ONLY="${ALL_UP/p2pool=running:none/p2pool=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$P2POOL_ONLY" PATH="$ST/bin:$PATH" ./stack.sh status 2>&1)"; rc=$?
assert_rc "status: p2pool stop under sync hold exits 0" "$rc" "0"
assert_contains "status: p2pool stop notes sync hold" "$out" "finish syncing"

# Remote-node mode: the bundled monerod is not expected even if absent.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=\nHOST_IP=box.lan\n' > "$ST/.env"
REMOTE="tor=running:healthy monerod=missing p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE" PATH="$ST/bin:$PATH" ./stack.sh status 2>&1)"; rc=$?
assert_rc "status: remote mode ignores monerod" "$rc" "0"

# ---------------------------------------------------------------------------
echo ""
printf 'stack.sh tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[1;31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
