#!/usr/bin/env bash
#
# Lightweight integration check: validate that docker-compose.yml parses and all
# ${VAR} interpolations resolve against a representative .env. This is client-side
# (`docker compose config` does not need the daemon), so it runs anywhere docker is installed.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP: docker compose not available"
    exit 0
fi

ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT

# A representative, fully-populated environment (mirrors what pithead renders).
cat > "$ENV_FILE" <<'EOF'
MONERO_DATA_DIR=/srv/data/monero
TARI_DATA_DIR=/srv/data/tari
P2POOL_DATA_DIR=/srv/data/p2pool
DASHBOARD_DATA_DIR=/srv/data/dashboard
TOR_DATA_DIR=/srv/data/tor
MONERO_NODE_USERNAME=monero
MONERO_NODE_PASSWORD=secret
MONERO_WALLET_ADDRESS=49Wallet
TARI_WALLET_ADDRESS=TWallet
MONERO_ONION_ADDRESS=a.onion
TARI_ONION_ADDRESS=b.onion
TARI_MEM_LIMIT=2048m
P2POOL_ONION_ADDRESS=c.onion
P2POOL_FLAGS=
P2POOL_PORT=37889
STRATUM_BIND=0.0.0.0
XVB_POOL_URL=na.xmrvsbeast.com:4247
XVB_DONOR_ID=49Wallet
XVB_ENABLED=true
P2POOL_URL=172.28.0.28:3333
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=token
MONERO_PRUNE=1
MONERO_PREP_THREADS=4
MONERO_RPC_BIND=127.0.0.1
MONERO_NODE_HOST=172.28.0.26
MONERO_RPC_PORT=18081
MONERO_ZMQ_PORT=18083
COMPOSE_PROFILES=local_node
DASHBOARD_SECURE=true
HOST_IP=box.lan
EOF

echo "Validating docker-compose.yml ..."
if docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config -q; then
    echo "  ✓ compose config is valid"
else
    echo "  ✗ compose config failed validation"
    exit 1
fi

# --- Hardening assertions (#90) ----------------------------------------------
# Render the resolved config once and assert the defense-in-depth directives survived. These are
# structural checks on the rendered YAML (counts/substrings), so an accidental removal of a
# cap_drop / read_only / the credential-free healthcheck fails CI rather than silently regressing.
echo "Checking hardening directives (#90) ..."
RENDERED="$(docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config)"
fails=0
expect_min() { # <label> <pattern> <min-count>
    local n; n=$(printf '%s\n' "$RENDERED" | grep -c -- "$2")
    if [ "$n" -ge "$3" ]; then echo "  ✓ $1 ($n)"; else echo "  ✗ $1: expected >= $3, got $n"; fails=$((fails + 1)); fi
}
expect_present() { # <label> <pattern>
    if printf '%s\n' "$RENDERED" | grep -q -- "$2"; then echo "  ✓ $1"; else echo "  ✗ $1: missing [$2]"; fails=$((fails + 1)); fi
}
expect_absent() { # <label> <pattern>
    if printf '%s\n' "$RENDERED" | grep -q -- "$2"; then echo "  ✗ $1: found [$2]"; fails=$((fails + 1)); else echo "  ✓ $1"; fi
}

# no-new-privileges on all 5 leaf services.
expect_min "no-new-privileges on leaf services" "no-new-privileges:true" 5
# cap_drop: [ALL] on exactly 4 of them — caddy, xmrig-proxy, and the two socket proxies. The
# dashboard is intentionally exempt (it writes its history DB as root into a user-owned volume,
# which needs CAP_DAC_OVERRIDE); pin the count so re-adding cap_drop there fails CI.
caps=$(printf '%s\n' "$RENDERED" | grep -c -- "- ALL")
if [ "$caps" -eq 4 ]; then echo "  ✓ cap_drop: [ALL] on 4 leaves, dashboard exempt ($caps)"; else echo "  ✗ cap_drop: [ALL]: expected 4 (dashboard exempt), got $caps"; fails=$((fails + 1)); fi
# Anchor to the 4-space service-level indent so read-only :ro *bind mounts* (rendered with the
# same key, deeper-indented) don't inflate the count — we want exactly the 3 read-only roots.
expect_min "read-only roots (caddy + 2 socket proxies)" "^    read_only: true" 3
# Caddy keeps NET_BIND_SERVICE so it can still bind :80/:443 after the drop.
expect_present "caddy retains NET_BIND_SERVICE" "NET_BIND_SERVICE"
# Stratum port is configurable, defaulting to all interfaces.
expect_present "stratum host port published" '"3333"'
# Healthchecks moved to scripts; RPC creds no longer appear in the compose healthcheck command.
expect_present "monerod healthcheck via script" "monerod-healthcheck.sh"
expect_present "p2pool healthcheck via script" "p2pool-healthcheck.sh"
expect_absent  "no get_info (creds) in compose healthcheck" "get_info"

# Per-service precision checks via the JSON render (cleaner than grepping the flat YAML): the
# Docker socket proxies must stay least-privilege, and the Tari probe must self-match safely.
JSON="$(docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
jq_assert() { # <label> <filter>
    if printf '%s' "$JSON" | jq -e "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1: failed [$2]"; fails=$((fails + 1)); fi
}
# The read proxy must never gain write (POST) access; the control proxy is start/stop ONLY.
jq_assert "docker-proxy cannot POST (read-only API)" '(.services["docker-proxy"].environment.POST // "0") != "1"'
jq_assert "docker-control is start/stop only (no exec/image ops)" \
    '.services["docker-control"].environment | (.POST=="1" and .ALLOW_START=="1" and .ALLOW_STOP=="1" and ((.EXEC // "0") != "1") and ((.IMAGES // "0") != "1"))'
# Both proxies mount the Docker socket read-only.
jq_assert "docker socket mounted read-only in both proxies" \
    '[.services["docker-proxy"], .services["docker-control"]] | all((.volumes // []) | any((.source == "/var/run/docker.sock") and (.read_only == true)))'
# The Tari probe uses the [m] bracket so grep can't match its own argv (a false-healthy bug).
jq_assert "tari healthcheck uses the [m]inotari self-match guard" \
    '(.services.tari.healthcheck.test | tostring) | contains("[m]inotari")'
# The Compose project name is pinned to "pithead" (not derived from the checkout directory).
jq_assert "compose project name is pinned to pithead" '.name == "pithead"'

if [ "$fails" -ne 0 ]; then
    echo "  ✗ $fails hardening check(s) failed"
    exit 1
fi
echo "  ✓ hardening directives present"
