#!/usr/bin/env bash
#
# Security / hardening regression guard for docker-compose.yml.
#
# These assert the invariants from the pre-launch hardening sweep (#90) and the
# creds-in-`docker inspect` fix, so a future edit can't silently undo them:
#   - monerod RPC credentials never appear in a healthcheck command (they were readable via
#     `docker inspect` before; the healthcheck now reads them from the container env via a script).
#   - the leaf containers run with no-new-privileges, and the right ones drop ALL capabilities
#     (the dashboard deliberately does NOT — it writes its SQLite history as root into a
#     host-user-owned volume; see #90 / the cap_drop revert).
#   - the Docker socket proxies stay least-privilege: the read proxy can't POST, the control
#     proxy is scoped to start/stop only, both mount the socket read-only and run read-only.
#   - the revenue-critical p2pool container has a liveness healthcheck (#90).
#
# We render the canonical config (`docker compose config`) so the checks see the resolved,
# interpolated values — exactly what `docker inspect` would show on a real host. Needs the
# docker compose CLI (no daemon); skips cleanly without it, like test_compose.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "${2:-}"; }

if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP: docker compose not available"
    exit 0
fi

# A representative, fully-populated env. The RPC password is a loud sentinel so the
# "no creds in a healthcheck" check is unambiguous.
ENV_FILE="$(mktemp)"
trap 'rm -f "$ENV_FILE"' EXIT
cat > "$ENV_FILE" <<'EOF'
MONERO_DATA_DIR=/srv/data/monero
TARI_DATA_DIR=/srv/data/tari
P2POOL_DATA_DIR=/srv/data/p2pool
DASHBOARD_DATA_DIR=/srv/data/dashboard
TOR_DATA_DIR=/srv/data/tor
MONERO_NODE_USERNAME=admin
MONERO_NODE_PASSWORD=RPC_HEALTHCHECK_SECRET_SENTINEL
MONERO_WALLET_ADDRESS=49Wallet
TARI_WALLET_ADDRESS=TWallet
MONERO_ONION_ADDRESS=a.onion
TARI_ONION_ADDRESS=b.onion
TARI_MEM_LIMIT=2048m
P2POOL_ONION_ADDRESS=c.onion
P2POOL_FLAGS=
P2POOL_PORT=37889
P2POOL_STRATUM_BIND=0.0.0.0
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
DASHBOARD_TZ=Etc/UTC
HOST_IP=box.lan
PITHEAD_VERSION=0.0.0
EOF

CONFIG="$(docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
if [ -z "$CONFIG" ]; then
    bad "render docker compose config" "config --format json produced no output"
    echo ""; echo "security: $PASS passed, $FAIL failed"; exit 1
fi

# sec_check <label> <jq filter returning true/false>
sec_check() {
    if printf '%s' "$CONFIG" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1" "failed: $2"; fi
}

echo "== secrets are not exposed via docker inspect =="
# No healthcheck command anywhere may contain the RPC password (#90 leak fix).
sec_check "no RPC creds in any healthcheck command" \
    '([.services[].healthcheck.test? // []] | flatten | map(select(contains("RPC_HEALTHCHECK_SECRET_SENTINEL"))) | length) == 0'
# monerod's healthcheck reads creds from a script, not an inline curl with -u/--digest.
sec_check "monerod healthcheck uses the external script" \
    '.services.monerod.healthcheck.test | any(. == "/usr/local/bin/monerod-healthcheck.sh")'

echo "== least privilege: no-new-privileges on the hardened leaf services =="
for svc in caddy xmrig-proxy dashboard docker-proxy docker-control; do
    sec_check "no-new-privileges: $svc" \
        '(.services["'"$svc"'"].security_opt // []) | any(. == "no-new-privileges:true")'
done

echo "== least privilege: capabilities dropped (dashboard is the documented exception) =="
for svc in caddy xmrig-proxy docker-proxy docker-control; do
    sec_check "cap_drop ALL: $svc" '(.services["'"$svc"'"].cap_drop // []) | any(. == "ALL")'
done
sec_check "dashboard does NOT cap_drop ALL (writes its DB as root)" \
    '((.services.dashboard.cap_drop // []) | any(. == "ALL")) | not'
sec_check "caddy keeps only NET_BIND_SERVICE" \
    '(.services.caddy.cap_add // []) | any(. == "NET_BIND_SERVICE")'

echo "== Docker socket proxies stay scoped =="
# The read proxy must never gain write access.
sec_check "docker-proxy cannot POST (read-only API)" \
    '(.services["docker-proxy"].environment.POST // "0") != "1"'
# The control proxy is start/stop only — no exec/images/create.
sec_check "docker-control allows start+stop" \
    '(.services["docker-control"].environment | (.POST=="1" and .ALLOW_START=="1" and .ALLOW_STOP=="1"))'
sec_check "docker-control does NOT allow exec" \
    '((.services["docker-control"].environment.EXEC // "0") != "1")'
sec_check "docker-control does NOT allow image ops" \
    '((.services["docker-control"].environment.IMAGES // "0") != "1")'
# Both mount the socket read-only and run on a read-only root filesystem.
for svc in docker-proxy docker-control; do
    sec_check "$svc mounts the docker socket read-only" \
        '(.services["'"$svc"'"].volumes // []) | any((.source == "/var/run/docker.sock") and (.read_only == true))'
    sec_check "$svc runs read-only root fs" '.services["'"$svc"'"].read_only == true'
done

echo "== healthchecks that earlier bugs depended on =="
# #90: p2pool (the revenue service) gained a liveness probe so a stall is visible.
sec_check "p2pool has a liveness healthcheck" '.services.p2pool.healthcheck.test != null'
# The Tari probe uses the [m] bracket so `grep` doesn't match its own argv (a false-healthy bug).
sec_check "tari healthcheck uses the [m]inotari self-match guard" \
    '(.services.tari.healthcheck.test | tostring) | contains("[m]inotari")'

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "security: $PASS passed, $FAIL failed"
else
    echo "security: $PASS passed, $FAIL failed"
    exit 1
fi
