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
MONERO_ZMQ_BIND=127.0.0.1
MONERO_NODE_HOST=172.28.0.26
MONERO_RPC_PORT=18081
MONERO_ZMQ_PORT=18083
TARI_GRPC_ADDRESS=172.28.0.27:18142
TARI_GRPC_BIND=127.0.0.1
COMPOSE_PROFILES=local_node,local_tari
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
# same key, deeper-indented) don't inflate the count — every service runs on a read-only root (#377).
expect_min "read-only roots (all 9 services, #377)" "^    read_only: true" 9
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
#
# The WHOLE reference, not the `tag@sha256:` prefix (#1137). In a `tag@digest` reference the digest
# is authoritative and the tag is decoration — that is the point of the pin, per the comment on
# these images in docker-compose.yml. A prefix match therefore passes on the half-done bump that
# matters: move the tag here and in the compose file, leave the digest, and the stack keeps pulling
# the old image while the file, this test, the release notes and the docs all announce the new
# version. Spelling the digest out makes the value a reviewable part of the diff at bump time.
# A COUNT, not a presence check (#1137's residual). This image runs TWICE — docker-proxy and
# docker-control — and expect_present is a grep -q, so it matches either line: bumping one proxy and
# leaving the other was green. The two would then run different socket-proxy builds, which is exactly
# the split the separate-proxy design exists to prevent.
expect_min "tecnativa socket-proxy pinned by digest (both proxies)" "tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459" 2
expect_present "caddy pinned by digest" "caddy:2.11.4@sha256:df7f1c2fb114453b951de51a98efc010db1655a92c2e86be6706714e2417a78d"
expect_present "tari node pinned by digest" "minotari_node:v5.3.1-mainnet@sha256:824fd6ec21d618805317d7eede374d6782906eeae17d2fc8aaad4df6205f94e0"

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
    '.services["docker-control"].environment | (.POST=="1" and .ALLOW_START=="1" and .ALLOW_STOP=="1" and ((.EXEC // "0") != "1") and ((.IMAGES // "0") != "1") and ((.ALLOW_PAUSE // "0") != "1") and ((.ALLOW_UNPAUSE // "0") != "1"))'
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
# Immutable root filesystems (#377): every service runs read_only with exactly its expected tmpfs
# scratch set, INCLUDING the mount options. An edit that grows a size cap or slips in `exec` —
# re-creating the executable staging area read_only exists to remove — must fail CI, not evolve
# silently. Each spec's entries are space-separated (the options carry commas). Removing read_only
# from any service, or changing any tmpfs entry, fails CI.
for spec in \
    "tor=/tmp:size=64m,mode=1777" \
    "monerod=/tmp:size=64m,mode=1777" \
    "tari=/tmp:size=64m,mode=1777" \
    "p2pool=/tmp:size=64m,mode=1777" \
    "xmrig-proxy=/home/ubuntu:size=64m,mode=1777 /tmp:size=64m,mode=1777" \
    "dashboard=/tmp:size=64m,mode=1777" \
    "docker-proxy=/run /tmp" \
    "docker-control=/run /tmp" \
    "caddy=/config /tmp"; do
    svc="${spec%%=*}" want="${spec#*=}"
    jq_assert "read_only rootfs + tmpfs [$want] on $svc (#377)" \
        ".services[\"$svc\"] | (.read_only == true) and (((.tmpfs // []) | sort) == (\"$want\" | split(\" \") | sort))"
done
# Belt-and-braces on the same risk: no tmpfs mount anywhere may carry the `exec` option token
# (Docker prepends noexec by default; only a literal `exec` in the options displaces it).
jq_assert "no tmpfs mount carries the exec option (#377)" \
    '[.services[] | (.tmpfs // [])[] | (split(":")[1] // "") | split(",")[] | select(. == "exec")] | length == 0'

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

# Control-channel spool mounts (#33): the rw/ro split IS the trust boundary. requests/ is the
# dashboard's ONLY writable leg; results/, audit/ and the pre-masked config prefill (#440) are
# read-only; staged/ is never mounted at all — so the container can ask, but cannot forge a
# result, rewrite the audit log, alter a staged intent, or read a raw secret.
jq_assert "dashboard control requests/ mounted read-write (#33)" \
    '.services.dashboard.volumes | any((.target == "/control/requests") and ((.read_only // false) == false))'
jq_assert "dashboard control results/ mounted read-only (#33)" \
    '.services.dashboard.volumes | any((.target == "/control/results") and (.read_only == true))'
jq_assert "dashboard control audit/ mounted read-only (#33)" \
    '.services.dashboard.volumes | any((.target == "/control/audit") and (.read_only == true))'
jq_assert "dashboard pre-masked config prefill mounted read-only (#440)" \
    '.services.dashboard.volumes | any((.target == "/control/masked") and (.read_only == true))'
jq_assert "raw config.json never enters the dashboard container (#440)" \
    '.services.dashboard.volumes | any(.source | tostring | endswith("/config.json")) | not'
jq_assert "dashboard config.reference.json prefill mounted read-only (#33)" \
    '.services.dashboard.volumes | any((.target == "/host-config/config.reference.json") and (.read_only == true))'
jq_assert "dashboard config.core-keys.json shortlist mounted read-only (#529)" \
    '.services.dashboard.volumes | any((.target == "/host-config/config.core-keys.json") and (.read_only == true))'
jq_assert "control staged/ dir never enters the container (#33)" \
    '.services.dashboard.volumes | any(.target | contains("staged")) | not'
jq_assert "control channel defaults off in the dashboard env (#33)" \
    '.services.dashboard.environment["DASHBOARD_CONTROL_ENABLED"] == "false"'

# depends_on startup ordering (#565): "wait until healthy" vs "wait until started" is a startup-
# correctness guarantee, not decoration. Render with the optional payout-confirmation profiles too
# (payout_confirm/tari_payout_confirm, #381/#462) so the profile-gated wallet-rpc/tari-wallet edges
# are covered, not just the always-on services. Edges enumerated from the compose file itself (5
# depends_on stanzas total): xmrig-proxy -> p2pool is the one deliberate exception that only waits
# for service_started, since p2pool's own healthcheck already proves what xmrig-proxy needs.
# p2pool itself has NO depends_on (#103/#565): both monerod and tari are profile-gated and can be
# off in remote mode, so p2pool retries its own RPC/gRPC dials instead of waiting on either.
DEPS_ENV="$(mktemp)"
sed 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=local_node,local_tari,payout_confirm,tari_payout_confirm/' "$ENV_FILE" >"$DEPS_ENV"
JSON="$(docker compose --env-file "$DEPS_ENV" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
rm -f "$DEPS_ENV"
for edge in "monerod=tor" "tari=tor" "wallet-rpc=monerod" "tari-wallet=tari"; do
    svc="${edge%%=*}" dep="${edge#*=}"
    jq_assert "$svc waits for $dep to be service_healthy (#565)" \
        ".services[\"$svc\"].depends_on[\"$dep\"].condition == \"service_healthy\""
done
jq_assert "xmrig-proxy waits for p2pool service_started only, not health-gated (#565)" \
    '.services["xmrig-proxy"].depends_on["p2pool"].condition == "service_started"'
# Peer-loss coupling (#972): a tor restart/recreate kills monerod's SOCKS peers and monerod does
# NOT re-dial on its own (bench: 0 in / 0 out peers for ~6h, healthcheck green). restart: true
# makes every compose operation that restarts/recreates tor restart monerod right after — and it
# is deliberately the ONLY such coupling: p2pool re-peers on its own.
jq_assert "monerod restarts whenever compose restarts/recreates tor (#972)" \
    '.services["monerod"].depends_on["tor"].restart == true'
jq_assert "the tor restart coupling stays monerod-only (#972)" \
    '[.services[] | (.depends_on // {}) | to_entries[] | select(.value.restart == true)] | length == 1'
jq_assert "p2pool has no depends_on — both monerod and tari can be profiled off (#103/#565)" \
    '(.services["p2pool"].depends_on // {}) == {}'
# Count guard: a NEW depends_on edge (health-gated or not) added anywhere in the file must show up
# in the enumeration above too, or this trips before it ships unasserted.
jq_assert "exactly 4 service_healthy depends_on edges total (#565)" \
    '[.services[] | (.depends_on // {}) | to_entries[] | select(.value.condition == "service_healthy")] | length == 4'
jq_assert "exactly 5 depends_on edges total (#565)" \
    '[.services[] | (.depends_on // {}) | to_entries[]] | length == 5'
# The wallet probe must fit ps's 15-char CMD column — procps truncates CMD there, so the full
# binary name never matches and the container would report unhealthy forever while the wallet
# runs fine (#777). Asserted here because tari-wallet only renders under tari_payout_confirm.
jq_assert "tari-wallet healthcheck pattern survives ps CMD truncation (#777)" \
    '(.services["tari-wallet"].healthcheck.test | tostring) | contains("[m]inotari_consol") and (contains("[m]inotari_console_wallet") | not)'
# The console wallet's digest pin had NO assertion anywhere (#1137). It cannot have one where the
# other three live: $RENDERED is built with COMPOSE_PROFILES=local_node,local_tari and tari-wallet
# is profiles: ["tari_payout_confirm"], so an expect_present there would pass and fail identically —
# it is not in that render at all. Here it is, for the same reason the healthcheck assertion above
# is. Whole reference, not the `tag@sha256:` prefix, for the reason given at the other three.
jq_assert "tari console wallet pinned by digest (#1137)" \
    '.services["tari-wallet"].image == "quay.io/tarilabs/minotari_console_wallet:v5.3.1-mainnet@sha256:31b3cd7b2b390da33c279fd1a5cd457eb254aeea17a5a230ff4c7bfea79a47eb"'
# The two Tari images are one component, bumped together, so a tag that moves on one and not the
# other is a silent split-brain — the node speaking one protocol version and the wallet another.
# Nothing compared them, and `scripts/release.sh pin tari` reads the NODE only (#1138), so a wallet
# left behind is invisible in the release notes as well.
jq_assert "both Tari images carry the same tag (#1137)" \
    '[.services["tari"].image, .services["tari-wallet"].image] | map(split("@")[0] | split(":")[-1]) | unique | length == 1'
# Compose healthchecks close the #904 gap. `pithead status` and the dashboard's container-health
# alert (#337) read these states, and a service without a check reports Up even when dead inside —
# so with every profile active (this render), no service may lack one, and each of the five late
# arrivals probes real readiness with tooling its own image ships.
jq_assert "every service carries a healthcheck (#904)" \
    '[.services[] | select(.healthcheck == null)] | length == 0'
jq_assert "xmrig-proxy healthcheck probes the control API via script (#904)" \
    '.services["xmrig-proxy"].healthcheck.test == ["CMD", "/usr/local/bin/xmrig-proxy-healthcheck.sh"]'
jq_assert "dashboard healthcheck probes /api/state via script (#904)" \
    '.services.dashboard.healthcheck.test == ["CMD", "/app/healthcheck.sh"]'
jq_assert "caddy healthcheck probes the admin endpoint with wget (#904)" \
    '(.services.caddy.healthcheck.test | tostring) | contains("wget") and contains("2019/config/")'
jq_assert "both socket proxies healthcheck /_ping through HAProxy (#904)" \
    '[.services["docker-proxy"], .services["docker-control"]] | all((.healthcheck.test | tostring) | contains("wget") and contains("2375/_ping"))'
# The standing #90 bar, applied to the new probes: no secret rides in a rendered healthcheck
# command. The env file above sets PROXY_AUTH_TOKEN=token, so any interpolation of the API token
# into a probe would surface as the literal "token" here.
jq_assert "no healthcheck command carries the proxy auth token (#90/#904)" \
    '[.services[] | (.healthcheck.test | tostring)] | all(contains("token") | not)'
# Profile-map drift guard (#822, same pattern as the depends_on count guard above): compose never
# removes a profile-deactivated service's container (#795), so remove_deactivated_profile_containers
# in the pithead script is the only thing that does — and it hardcodes the service↔profile map.
# Enumerate every profile-gated service from the compose file itself (--profile '*' activates them
# all, whatever their names) and diff against the map parsed out of the script's function body: a
# new profile-gated service, a renamed profile, or a stale map entry fails here until both agree.
COMPOSE_PROFILE_MAP="$(docker compose --env-file "$ENV_FILE" --profile '*' -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null |
    jq -r '.services | to_entries[] | select(.value.profiles) | .value.profiles[] as $p | "\(.key)=\($p)"' | sort)"
SCRIPT_PROFILE_MAP="$(sed -n '/^remove_deactivated_profile_containers()/,/^}/p' "$ROOT/pithead" |
    sed -n 's/.*\*,\([a-z_]*\),\* ]] || gone+=(\([a-z-]*\)).*/\2=\1/p' | sort)"
if [ -n "$COMPOSE_PROFILE_MAP" ] && [ "$COMPOSE_PROFILE_MAP" = "$SCRIPT_PROFILE_MAP" ]; then
    echo "  ✓ removal map covers exactly the profile-gated services (#795/#822)"
else
    echo "  ✗ compose profiles and remove_deactivated_profile_containers disagree (#795/#822):"
    echo "    compose file: $(printf '%s' "$COMPOSE_PROFILE_MAP" | tr '\n' ' ')"
    echo "    pithead map:  $(printf '%s' "$SCRIPT_PROFILE_MAP" | tr '\n' ' ')"
    fails=$((fails + 1))
fi
# Restore $JSON to the default-profile render for every check below this point.
JSON="$(docker compose --env-file "$ENV_FILE" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"

# Tari profile gating (#103, mirrors monerod's local_node above): local_tari present/absent from
# COMPOSE_PROFILES must add/omit the tari service itself, and compose must resolve cleanly either
# way — a depends_on edge onto a profiled-off service would otherwise fail `compose config`/`up`
# outright, not just at startup.
jq_assert "tari service present when local_tari is active (#103)" \
    '.services | has("tari")'
REMOTE_TARI_ENV="$(mktemp)"
sed 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=local_node/' "$ENV_FILE" >"$REMOTE_TARI_ENV"
if docker compose --env-file "$REMOTE_TARI_ENV" -f "$ROOT/docker-compose.yml" config -q; then
    echo "  ✓ compose config resolves with local_tari OMITTED (remote tari, #103)"
else
    echo "  ✗ compose config failed to resolve with local_tari omitted (remote tari, #103)"
    fails=$((fails + 1))
fi
REMOTE_TARI_JSON="$(docker compose --env-file "$REMOTE_TARI_ENV" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
rm -f "$REMOTE_TARI_ENV"
if printf '%s' "$REMOTE_TARI_JSON" | jq -e '.services | has("tari") | not' >/dev/null 2>&1; then
    echo "  ✓ tari service absent when local_tari is omitted (remote tari, #103)"
else
    echo "  ✗ tari service still present with local_tari omitted (remote tari, #103)"
    fails=$((fails + 1))
fi
# The same profile list must reach the tor container, which gates each node's inbound hidden service
# on it (#103) — without this wiring tor would keep publishing an onion for a node that never starts.
if printf '%s' "$REMOTE_TARI_JSON" | jq -e '.services.tor.environment.COMPOSE_PROFILES == "local_node"' >/dev/null 2>&1; then
    echo "  ✓ tor receives the active profile list, so its onion gate matches the running nodes (#103)"
else
    echo "  ✗ tor did not receive the active profile list (#103)"
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

# Configurable stratum port (#172). Default env (no STRATUM_PORT — a pre-#172 .env) must keep
# publishing/binding :3333; a custom port must move the publish, the container port, the -b bind
# AND the dashboard hint — while the internal proxy→p2pool leg stays :3333 (P2POOL_URL, and
# p2pool's own --stratum 0.0.0.0:3333).
jq_assert "default stratum publish stays :3333 (#172)" \
    '.services["xmrig-proxy"].ports | any((.published == "3333") and (.target == 3333))'
jq_assert "default -b bind stays 0.0.0.0:3333 (#172)" \
    '.services["xmrig-proxy"].command | any(. == "0.0.0.0:3333")'
PORT_ENV="$(mktemp)"
{
    cat "$ENV_FILE"
    printf 'STRATUM_PORT=4444\n'
} >"$PORT_ENV"
PORT_JSON="$(docker compose --env-file "$PORT_ENV" -f "$ROOT/docker-compose.yml" config --format json 2>/dev/null)"
rm -f "$PORT_ENV"
port_assert() { # <label> <filter>
    if printf '%s' "$PORT_JSON" | jq -e "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else
        echo "  ✗ $1: failed [$2]"
        fails=$((fails + 1))
    fi
}
port_assert "custom stratum port moves the publish and container port (#172)" \
    '.services["xmrig-proxy"].ports | any((.published == "4444") and (.target == 4444))'
port_assert "custom stratum port moves the -b bind (#172)" \
    '.services["xmrig-proxy"].command | any(. == "0.0.0.0:4444")'
port_assert "custom stratum port reaches the dashboard hint env (#172)" \
    '.services.dashboard.environment["STRATUM_PORT"] == "4444"'
port_assert "internal p2pool stratum stays :3333 under a custom port (#172)" \
    '.services["p2pool"].command | any(. == "0.0.0.0:3333")'
port_assert "proxy upstream (P2POOL_URL) stays the internal :3333 (#172)" \
    '.services["xmrig-proxy"].command | any(. == "172.28.0.28:3333")'

if [ "$fails" -ne 0 ]; then
    echo "  ✗ $fails hardening check(s) failed"
    exit 1
fi
echo "  ✓ hardening directives present"
