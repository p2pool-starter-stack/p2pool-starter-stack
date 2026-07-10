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
EMPTY_TOKEN_ENV="$(mktemp)"
trap 'rm -f "$ENV_FILE" "$EMPTY_TOKEN_ENV"' EXIT

# A representative, fully-populated environment (mirrors what pithead renders).
cat >"$ENV_FILE" <<'EOF'
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
MONERO_MEM_LIMIT=3g
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
PROXY_STRATUM_PASSWORD=hunter2
PROXY_DONATE_LEVEL=1
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
    local n
    n=$(printf '%s\n' "$RENDERED" | grep -c -- "$2")
    if [ "$n" -ge "$3" ]; then echo "  ✓ $1 ($n)"; else
        echo "  ✗ $1: expected >= $3, got $n"
        fails=$((fails + 1))
    fi
}
expect_present() { # <label> <pattern>
    if printf '%s\n' "$RENDERED" | grep -q -- "$2"; then echo "  ✓ $1"; else
        echo "  ✗ $1: missing [$2]"
        fails=$((fails + 1))
    fi
}
expect_absent() { # <label> <pattern>
    if printf '%s\n' "$RENDERED" | grep -q -- "$2"; then
        echo "  ✗ $1: found [$2]"
        fails=$((fails + 1))
    else echo "  ✓ $1"; fi
}

# no-new-privileges on all 5 leaf services.
expect_min "no-new-privileges on leaf services" "no-new-privileges:true" 5
# cap_drop: [ALL] on all 5 leaf services — caddy, xmrig-proxy, the two socket proxies, AND the
# dashboard. The dashboard now runs non-root and owns its volume (#255), so it no longer needs
# CAP_DAC_OVERRIDE to write its history DB and joins the others; pin the count so dropping cap_drop
# from any leaf fails CI.
caps=$(printf '%s\n' "$RENDERED" | grep -c -- "- ALL")
if [ "$caps" -eq 5 ]; then echo "  ✓ cap_drop: [ALL] on all 5 leaves incl. dashboard ($caps)"; else
    echo "  ✗ cap_drop: [ALL]: expected 5 (incl. dashboard, #255), got $caps"
    fails=$((fails + 1))
fi
# Non-root containers (#255): the pulled tari image has no first-party Dockerfile USER, so its
# non-root uid is pinned via compose. Guard it so a silent drop back to root fails CI.
expect_min "tari runs non-root via compose user: (#255)" "user: 1000:1000" 1
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
expect_absent "no get_info (creds) in compose healthcheck" "get_info"

# Log rotation (#123): every service must carry the json-file size cap, including caddy and the two
# socket proxies that previously fell back to Docker's uncapped default. All 9 services (monerod is
# present under the local_node profile in this env) render one `max-size` line each.
expect_min "log rotation on every service" "max-size:" 9
# Image digest pinning (#135): the externally-pulled images must reference an immutable @sha256
# digest, not just a mutable tag, so a re-pushed tag can't silently change the running image.
expect_present "tecnativa socket-proxy pinned by digest" "tecnativa/docker-socket-proxy:v0.4.2@sha256:"
expect_present "caddy pinned by digest" "caddy:2.11.4@sha256:"
expect_present "tari node pinned by digest" "minotari_node:v5.3.1-mainnet@sha256:"

# Per-service precision checks via the JSON render (cleaner than grepping the flat YAML): the
# Docker socket proxies must stay least-privilege, and the Tari probe must self-match safely.
JSON="$(docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
jq_assert() { # <label> <filter>
    if printf '%s' "$JSON" | jq -e "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else
        echo "  ✗ $1: failed [$2]"
        fails=$((fails + 1))
    fi
}
# The read proxy must never gain write (POST) access; the control proxy is start/stop ONLY.
jq_assert "docker-proxy cannot POST (read-only API)" '(.services["docker-proxy"].environment.POST // "0") != "1"'
jq_assert "docker-control is start/stop only (no exec/image ops)" \
    '.services["docker-control"].environment | (.POST=="1" and .ALLOW_START=="1" and .ALLOW_STOP=="1" and ((.EXEC // "0") != "1") and ((.IMAGES // "0") != "1"))'
# Both proxies mount the Docker socket read-only.
jq_assert "docker socket mounted read-only in both proxies" \
    '[.services["docker-proxy"], .services["docker-control"]] | all((.volumes // []) | any((.source == "/var/run/docker.sock") and (.read_only == true)))'
# Socket-proxy isolation (#345): neither proxy is on the mining bridge, and each is published ONLY to
# the host loopback — so no mining container (monerod/tari/p2pool/xmrig-proxy) can reach the Docker
# API to read secrets (inspect) or start/stop containers.
jq_assert "docker-proxy is off mining_net (proxy_net only)" \
    '(.services["docker-proxy"].networks | keys) == ["proxy_net"]'
jq_assert "docker-control is off mining_net (proxy_net only)" \
    '(.services["docker-control"].networks | keys) == ["proxy_net"]'
jq_assert "both socket proxies publish only to the host loopback" \
    '[.services["docker-proxy"], .services["docker-control"]] | all((.ports | length > 0) and (.ports | all(.host_ip == "127.0.0.1")))'
# No mining service may sit on proxy_net (keep the isolation one-directional).
jq_assert "mining services are not on proxy_net" \
    '[.services["monerod"], .services["tari"], .services["p2pool"], .services["xmrig-proxy"]] | all((.networks // {} | keys) | any(. == "proxy_net") | not)'
# The Tari probe uses the [m] bracket so grep can't match its own argv (a false-healthy bug).
jq_assert "tari healthcheck uses the [m]inotari self-match guard" \
    '(.services.tari.healthcheck.test | tostring) | contains("[m]inotari")'
# The Compose project name is pinned to "pithead" (not derived from the checkout directory).
jq_assert "compose project name is pinned to pithead" '.name == "pithead"'
# Memory ceilings (#132): every service carries a mem_limit so a leak/runaway OOM-restarts the
# offender in its own cgroup instead of the host OOM-killer reaching monerod (the revenue service).
jq_assert "memory ceiling (mem_limit) on every service (#132)" '[.services[] | select(.mem_limit != null)] | length >= 9'

# Config-editor spool mounts (#33): the rw/ro split IS the trust boundary. The dashboard may
# write ONLY requests/; results/, audit/ and the two config views are read-only, and staged/
# (the host-side copy a commit applies) is not mounted at all — so the container can ask, but
# can never forge a result, alter a staged intent, or rewrite the audit log.
jq_assert "control requests/ is the dashboard's only writable spool mount (#33)" \
    '.services.dashboard.volumes | any((.target == "/control/requests") and (.read_only != true))'
jq_assert "control results/, audit/ and config views are read-only (#33)" \
    '.services.dashboard.volumes | map(select(.target == "/control/results" or .target == "/control/audit" or .target == "/host-config/config.json" or .target == "/host-config/config.reference.json")) | (length == 4) and all(.read_only == true)'
jq_assert "control staged/ is never mounted in the dashboard (#33)" \
    '.services.dashboard.volumes | all(.target != "/control/staged")'
jq_assert "control channel defaults off in the dashboard env (#33)" \
    '.services.dashboard.environment["DASHBOARD_CONTROL_ENABLED"] == "false"'

# Fail closed on the xmrig-proxy control-API token (#153). The HTTP API is writable
# (--http-no-restricted, required for XvB pool-switching) and reachable on the bridge + host, so it
# must ALWAYS be authenticated. The command requires a non-empty token; an empty/stale .env value
# must make the stack refuse to start rather than expose an unauthenticated API.
jq_assert "xmrig-proxy API carries a non-empty access token (#153)" \
    '.services["xmrig-proxy"].command as $c | ($c | index("--http-access-token")) as $i | ($i != null) and (($c[($i + 1)] // "") | length > 0)'
grep -v '^PROXY_AUTH_TOKEN=' "$ENV_FILE" >"$EMPTY_TOKEN_ENV"
echo 'PROXY_AUTH_TOKEN=' >>"$EMPTY_TOKEN_ENV"
if docker compose --env-file "$EMPTY_TOKEN_ENV" -f "$ROOT/docker-compose.yml" config -q >/dev/null 2>&1; then
    echo "  ✗ empty PROXY_AUTH_TOKEN still rendered (would start an UNAUTHENTICATED API)"
    fails=$((fails + 1))
else
    echo "  ✓ empty PROXY_AUTH_TOKEN makes the stack refuse to start (#153)"
fi

# xmrig-proxy config knobs (#152 stratum access-password, #173 dev-fee donate-level). donate-level is
# a plain command item. The access-password flag is instead applied by the wrapper entrypoint from the
# PROXY_STRATUM_PASSWORD env var — NOT a command item — because a compose command LIST can't drop an
# empty element: a `${VAR:+--flag}` item rendered a stray '' positional arg when the password was unset
# (xmrig-proxy warns `unsupported non-option argument ''`). So assert the env var is plumbed with the
# value, and the command carries NO --access-password and NO empty element. The entrypoint's set/unset
# append logic is covered by tests/stack/run.sh.
jq_assert "xmrig-proxy stratum password plumbed via env (#152)" \
    '.services["xmrig-proxy"].environment["PROXY_STRATUM_PASSWORD"] == "hunter2"'
jq_assert "xmrig-proxy command has no empty arg or --access-password item (#152)" \
    '.services["xmrig-proxy"].command | (any(. == "") | not) and (any(startswith("--access-password")) | not)'
jq_assert "xmrig-proxy dev-fee donate-level rendered (#173)" \
    '.services["xmrig-proxy"].command | any(. == "--donate-level=1")'
# Default-off path: an EMPTY PROXY_STRATUM_PASSWORD and a MISSING PROXY_DONATE_LEVEL (a stale .env from
# before these keys) must leave the env var empty (the entrypoint then appends no flag, so any rig may
# still mine) and fall back to --donate-level=0 (no dev fee).
OFF_ENV="$(mktemp)"
grep -vE '^PROXY_STRATUM_PASSWORD=|^PROXY_DONATE_LEVEL=' "$ENV_FILE" >"$OFF_ENV"
echo 'PROXY_STRATUM_PASSWORD=' >>"$OFF_ENV"
OFF_JSON="$(docker compose --env-file "$OFF_ENV" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
rm -f "$OFF_ENV"
if printf '%s' "$OFF_JSON" | jq -e '.services["xmrig-proxy"] | (.environment["PROXY_STRATUM_PASSWORD"] == "") and (.command | any(. == "--donate-level=0"))' >/dev/null 2>&1; then
    echo "  ✓ default-off: empty stratum password + --donate-level=0 (#152/#173)"
else
    echo "  ✗ default-off must leave PROXY_STRATUM_PASSWORD empty and render --donate-level=0"
    fails=$((fails + 1))
fi

# Configurable bridge subnet (#180): a custom network.subnet must rebase every static IP, the bridge
# CIDR, and the dashboard's derived bridge endpoints — the host address-space-collision install fix.
CUSTOM_ENV="$(mktemp)"
{
    cat "$ENV_FILE"
    printf 'NETWORK_SUBNET=10.84.0.0/24\nNETWORK_PREFIX=10.84.0\n'
} >"$CUSTOM_ENV"
CUSTOM="$(docker compose --env-file "$CUSTOM_ENV" -f "$ROOT/docker-compose.yml" config 2>/dev/null)"
rm -f "$CUSTOM_ENV"
sub_check() { # <label> <pattern> <min-count>
    local n
    n=$(printf '%s\n' "$CUSTOM" | grep -c -- "$2")
    if [ "$n" -ge "$3" ]; then echo "  ✓ $1 ($n)"; else
        echo "  ✗ $1: expected >= $3, got $n"
        fails=$((fails + 1))
    fi
}
sub_check "custom subnet rebases the bridge network (#180)" "subnet: 10.84.0.0/24" 1
# Five static mining-bridge IPs (tor .25, monerod .26, tari .27, p2pool .28, dashboard-reach .29);
# the two socket proxies moved off mining_net to loopback-published proxy_net (#345), so no longer 7.
sub_check "custom subnet rebases all static service IPs (#180)" "ipv4_address: 10.84.0." 5
sub_check "custom subnet rebases the dashboard SSRF CIDR (#180)" "MINING_NET_CIDR: 10.84.0.0/24" 1
sub_check "custom subnet rebases the dashboard Tor SOCKS endpoint (#180)" "TOR_SOCKS_PROXY: socks5h://10.84.0.25:9050" 1

if [ "$fails" -ne 0 ]; then
    echo "  ✗ $fails hardening check(s) failed"
    exit 1
fi
echo "  ✓ hardening directives present"
