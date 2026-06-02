#!/usr/bin/env bash
#
# Management script for the Monero + Tari merge-mining stack.
#
#   ./stack.sh setup            First-time setup (interactive config, Tor, optimize, start)
#   ./stack.sh apply            Re-read config.json and propagate changes to a running stack
#   ./stack.sh up | down | restart | upgrade
#   ./stack.sh logs [service] | status | reset-dashboard | help
#
# config.json is the single source of truth. Edit it, then run `./stack.sh apply`
# to regenerate .env / Caddyfile / Tari config and recreate only the changed containers
# WITHOUT re-provisioning Tor, re-prompting, touching GRUB, or rotating the proxy token.
#
set -Eeuo pipefail

# --- Logging Utilities ---
# Colour only when stdout is a terminal and NO_COLOR is unset (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[1;31m'
else
    C_RESET=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi
readonly C_RESET C_GREEN C_YELLOW C_RED

log() { echo -e "${C_GREEN}[STACK]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1" >&2; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; exit 1; }

on_err() {
    local ec=$?
    echo -e "${C_RED}[ERROR]${C_RESET} stack.sh aborted unexpectedly (exit $ec)." >&2
    echo "Re-run with 'bash -x $0 <command>' to see where, and check the output above." >&2
}

# Detect Operating System
OS_TYPE="$(uname -s)"; readonly OS_TYPE
readonly CONFIG_FILE="config.json"
readonly ENV_FILE=".env"
readonly REAL_USER="${SUDO_USER:-$USER}"

REBOOT_REQUIRED=false
SKIP_OPTIMIZE=0
SKIP_DEPS=0

# Detect whether we're being sourced (e.g. by the test suite). When sourced we only define
# functions/constants and skip all side effects (cd, traps, running main).
_STACK_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then _STACK_SOURCED=1; fi

if [ "$_STACK_SOURCED" = "0" ]; then
    # Always operate from the directory containing this script, so the stack can be managed from
    # anywhere (./stack.sh, an absolute path, cron, systemd, ...). All paths below are relative to it.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$SCRIPT_DIR" || error "Cannot enter the script directory: $SCRIPT_DIR"

    # Friendly message on unexpected failure; always clean up the apply staging file.
    trap on_err ERR
    trap 'rm -f "${ENV_FILE}.new" 2>/dev/null || true' EXIT
fi

# --- Lifecycle Helpers ---

stack_up() {
    log "Starting stack..."
    # Docker Compose automatically picks up COMPOSE_PROFILES from .env
    docker compose up -d
    log "Stack started successfully!"
    announce_dashboard_url
}

stack_down() {
    log "Stopping stack..."
    docker compose down
    log "Stack stopped."
}

stack_restart() {
    log "Restarting stack..."
    docker compose restart
    log "Stack restarted."
}

stack_upgrade() {
    log "Upgrading stack (rebuilding containers)..."
    docker compose up -d --build
    log "Stack upgraded."
}

# Show the compose table, then health-check every service we expect to be running and warn
# about anything that isn't. Returns non-zero if any service needs attention (handy for cron).
# Profile-aware (the bundled monerod only counts in local-node mode), and aware that a stopped
# p2pool/xmrig-proxy can be intentional: reject-workers (#31) stops xmrig-proxy when a node is
# down, and the sync hold (#35) stops both until the required chains finish their initial sync.
stack_status() {
    docker compose ps || true
    echo ""
    log "Service health check:"

    local expected profiles
    expected=$(docker compose config --services 2>/dev/null | sort || true)
    profiles=$(env_get COMPOSE_PROFILES)
    if [ -z "$expected" ]; then
        warn "Could not read the service list from compose — is Docker running?"
        return 1
    fi

    local problems=0 proxy_state="" p2pool_state="" node_down=0
    local s cid info state health
    while IFS= read -r s; do
        [ -z "$s" ] && continue
        # The bundled monerod only runs under the local_node profile; in remote mode it's
        # not expected, so don't flag it missing.
        if [ "$s" = "monerod" ] && [[ ",$profiles," != *",local_node,"* ]]; then
            continue
        fi

        cid=$(docker compose ps -aq "$s" 2>/dev/null | head -n1 || true)
        if [ -z "$cid" ]; then
            state="missing"; health="none"
        else
            info=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo "unknown none")
            state=${info%% *}; health=${info##* }
        fi

        # Track required-node health (monerod/tari) to interpret a stopped proxy below.
        if [ "$s" = "monerod" ] || [ "$s" = "tari" ]; then
            if [ "$state" != "running" ] || { [ "$health" != "healthy" ] && [ "$health" != "none" ]; }; then
                node_down=1
            fi
        fi

        # Defer the verdict for the miner containers until we know whether a node is down /
        # the sync hold is on: a stopped p2pool or xmrig-proxy is often intentional (#31/#35).
        if [ "$s" = "xmrig-proxy" ] && [ "$state" != "running" ]; then
            proxy_state="$state"
            continue
        fi
        if [ "$s" = "p2pool" ] && [ "$state" != "running" ]; then
            p2pool_state="$state"
            continue
        fi

        case "$state" in
            running)
                case "$health" in
                    healthy|none) printf '  %b✓%b %-13s running\n'  "$C_GREEN"  "$C_RESET" "$s" ;;
                    starting)     printf '  %b…%b %-13s starting (health check pending)\n' "$C_YELLOW" "$C_RESET" "$s" ;;
                    *)            printf '  %b⚠%b %-13s running but UNHEALTHY\n' "$C_YELLOW" "$C_RESET" "$s"; problems=$((problems + 1)) ;;
                esac ;;
            restarting)
                printf '  %b✗%b %-13s restarting (possible crash loop — check logs)\n' "$C_RED" "$C_RESET" "$s"; problems=$((problems + 1)) ;;
            *)
                printf '  %b✗%b %-13s %s\n' "$C_RED" "$C_RESET" "$s" "$state"; problems=$((problems + 1)) ;;
        esac
    done <<< "$expected"

    # A stopped p2pool/xmrig-proxy is normally intentional: the dashboard stops xmrig-proxy to
    # fail workers over a node-down (#31), and holds the miner until the required chains finish
    # syncing (#35). We can't tell those apart from a genuine fault here (a healthy node can
    # still be syncing), so report it as likely-intentional and point at the dashboard.
    local held name st why
    for held in "p2pool=$p2pool_state" "xmrig-proxy=$proxy_state"; do
        name=${held%%=*}; st=${held#*=}
        [ -z "$st" ] && continue
        if [ "$node_down" -eq 1 ]; then
            why="a node is down, so workers were rejected to fail over to backups"
        else
            why="held until the required chains finish syncing — check the dashboard"
        fi
        printf '  %b⚠%b %-13s %s — likely intentional: %s\n' "$C_YELLOW" "$C_RESET" "$name" "$st" "$why"
    done

    echo ""
    if [ "$problems" -eq 0 ]; then
        log "All expected services are up."
    else
        warn "$problems service(s) need attention (see above)."
        return 1
    fi
}

announce_dashboard_url() {
    local display_host
    display_host=$(env_get HOST_IP)
    [ -z "$display_host" ] && display_host="$(hostname)"
    if [ "$(env_get DASHBOARD_SECURE)" == "true" ]; then
        log "Dashboard available at: https://$display_host"
    else
        log "Dashboard available at: http://$display_host"
    fi
}

reset_dashboard() {
    echo -e "${C_RED}[WARNING] This is a DESTRUCTIVE action.${C_RESET}"
    echo "It will stop the dashboard/p2pool containers and WIPE their data directories."
    read -r -p "Are you sure you want to continue? (y/N): " CONFIRM || true
    if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
        log "Reset cancelled."
        return
    fi

    log "Resetting dashboard and p2pool..."
    parse_and_validate_config

    log "Stopping dashboard and p2pool containers..."
    docker compose rm -s -f -v dashboard p2pool

    log "Removing data directories..."
    [ -d "$DASHBOARD_DIR" ] && sudo rm -rf "$DASHBOARD_DIR"
    [ -d "$P2POOL_DIR" ] && sudo rm -rf "$P2POOL_DIR"

    log "Recreating data directories..."
    mkdir -p "$DASHBOARD_DIR" "$P2POOL_DIR"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$P2POOL_DIR"
    mkdir -p "$P2POOL_DIR/stats"
    sudo chmod -R 755 "$P2POOL_DIR/stats"

    log "Bringing services back up..."
    docker compose up -d dashboard p2pool
}

show_help() {
    cat <<EOF
Usage: $0 <command> [options]

Manage the P2Pool / Monero + Tari merge-mining stack.

Setup & configuration:
  setup [--skip-optimize] [--skip-deps]
                            First-time setup: dependency check, interactive config, Tor
                            provisioning, kernel optimization, and start.
                              --skip-optimize  skip the kernel/GRUB HugePages tuning.
                              --skip-deps      skip dependency detection/install (for
                                               unsupported or custom setups).
  apply [-y|--yes]          Re-read config.json and propagate changes: previews what will
                            change, warns before anything disruptive, then recreates only
                            the containers that need it. Use this after you edit config.json.
                              -y, --yes        apply without the confirmation prompt.

Lifecycle:
  up                        Start the stack.
  down                      Stop the stack.
  restart                   Restart the stack.
  upgrade                   Rebuild and restart the stack (after a 'git pull').

Inspection:
  logs [service]            Follow logs for all containers, or a single service.
  status                    Show container status + health-check every expected service
                            (warns about anything down; non-zero exit if so).

Maintenance:
  reset-dashboard           DESTRUCTIVE: wipe and recreate dashboard/p2pool data.

  help, -h, --help          Show this message.

Workflow: edit config.json, then run '$0 apply'.
EOF
}

# --- Small Utilities ---

# Read a single KEY=value from an env file (value may contain '=').
# Tolerant of a missing key / missing file under `set -e` + `pipefail`.
env_get_file() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 0
    line=$(grep -E "^$key=" "$file" 2>/dev/null) || true
    line=${line%%$'\n'*}        # first matching line
    printf '%s' "${line#*=}"    # value after the first '='
}

env_get() { env_get_file "$ENV_FILE" "$1"; }

# Keys whose value differs between two env files (added, removed, or changed), one per line.
env_changed_keys() {
    comm -3 <(sort "$1") <(sort "$2") 2>/dev/null \
        | sed -E 's/^[[:space:]]+//; s/=.*$//' \
        | sort -u
}

is_deployed() {
    [ -f "$ENV_FILE" ] && grep -q "^DEPLOYMENT_COMPLETED=true" "$ENV_FILE"
}

require_env() {
    [ -f "$ENV_FILE" ] || error "No $ENV_FILE found. Run '$0 setup' first."
}

require_deployed() {
    is_deployed || error "The stack isn't fully set up yet. Run '$0 setup' first."
}

# Refuse data directories that would be catastrophic to chown -R / rm -rf.
assert_safe_dir() {
    case "$1" in
        ""|/|//|/.|/root|/home|/etc|/usr|/var|/bin|/sbin|/lib|/lib64|/boot|/dev|/proc|/sys)
            error "Refusing to use '$1' as a data directory. Choose a dedicated folder in $CONFIG_FILE." ;;
    esac
}

safe_sed() {
    local pattern="$1"
    local file="$2"
    if [ "$OS_TYPE" == "Darwin" ]; then
        sed -i '' "$pattern" "$file"
    else
        sed -i "$pattern" "$file"
    fi
}

# Resolve a config value, treating "auto"/empty (and the legacy DYNAMIC_* sentinels) as
# "use the stack default". $1 = configured value, $2 = default.
resolve_default() {
    case "$1" in
        ""|auto|DYNAMIC_DATA|DYNAMIC_HOST|DYNAMIC_ID) printf '%s' "$2" ;;
        *) printf '%s' "$1" ;;
    esac
}

# --- Setup Steps ---

# Read the os-release file into OS_ID / OS_VERSION / OS_PRETTY (subshell-sourced to avoid clobber).
# OS_RELEASE_FILE is overridable for testing; defaults to the standard location.
# shellcheck disable=SC1090  # os-release path is dynamic by design
detect_os() {
    local osr="${OS_RELEASE_FILE:-/etc/os-release}"
    OS_ID=""; OS_VERSION=""; OS_PRETTY="$OS_TYPE"
    if [ -r "$osr" ]; then
        OS_ID=$(. "$osr" 2>/dev/null; printf '%s' "${ID:-}")
        OS_VERSION=$(. "$osr" 2>/dev/null; printf '%s' "${VERSION_ID:-}")
        OS_PRETTY=$(. "$osr" 2>/dev/null; printf '%s' "${PRETTY_NAME:-$OS_TYPE}")
    fi
}

# True when the four runtime dependencies are all present.
deps_satisfied() {
    command -v jq >/dev/null 2>&1 \
        && command -v openssl >/dev/null 2>&1 \
        && command -v docker >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1
}

check_prerequisites() {
    if [ "$SKIP_DEPS" == "1" ]; then
        warn "Skipping dependency checks (--skip-deps). Ensure docker, docker compose (v2), jq and openssl are installed."
        return 0
    fi

    log "Checking dependencies..."
    detect_os
    if [ "$OS_ID" != "ubuntu" ] || [ "$OS_VERSION" != "24.04" ]; then
        warn "Officially supported on Ubuntu Server 24.04 (detected: ${OS_PRETTY:-$OS_TYPE})."
        warn "The stack may still work; install dependencies manually if needed, or re-run with --skip-deps to bypass these checks."
    fi

    # Detect missing dependencies and the apt packages that provide them.
    local missing_cmds=() missing_pkgs=()
    command -v jq      >/dev/null 2>&1 || { missing_cmds+=("jq");      missing_pkgs+=("jq"); }
    command -v openssl >/dev/null 2>&1 || { missing_cmds+=("openssl"); missing_pkgs+=("openssl"); }
    if ! command -v docker >/dev/null 2>&1; then
        missing_cmds+=("docker"); missing_pkgs+=("docker.io" "docker-compose-v2")
    elif ! docker compose version >/dev/null 2>&1; then
        missing_cmds+=("docker compose (v2 plugin)"); missing_pkgs+=("docker-compose-v2")
    fi

    if [ "${#missing_cmds[@]}" -gt 0 ]; then
        warn "Missing dependencies: ${missing_cmds[*]}"
        local apt_cmd="sudo apt-get install -y ${missing_pkgs[*]}"
        if [ "$OS_ID" == "ubuntu" ] && command -v apt-get >/dev/null 2>&1; then
            read -r -p "Install them now with apt? (Y/n): " ANS || true
            if [[ "$ANS" =~ ^[Nn] ]]; then
                error "Dependencies not installed. Install them and re-run setup:\n  $apt_cmd"
            fi
            log "Installing missing packages..."
            sudo apt-get update
            sudo apt-get install -y "${missing_pkgs[@]}"
            deps_satisfied || error "Dependencies still missing after install. Please install manually:\n  $apt_cmd"
        else
            error "Cannot auto-install on this OS. Please install: ${missing_cmds[*]}\n  On Ubuntu:  $apt_cmd\n  Or re-run with --skip-deps if your setup already provides these another way."
        fi
    fi

    # Docker present but daemon not reachable is a separate (non-package) problem.
    docker info >/dev/null 2>&1 || error "Docker daemon is not reachable. Start it (e.g. 'sudo systemctl start docker') and ensure your user can use Docker (add yourself to the 'docker' group, then re-log in)."

    # Verify AVX2 instruction set support (performance only)
    if [ "$OS_TYPE" == "Darwin" ]; then
        if ! sysctl -a 2>/dev/null | grep "machdep.cpu" | grep -q "AVX2"; then
            warn "AVX2 not detected. Mining performance will be poor."
        fi
    else
        if ! grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
            warn "AVX2 not detected. Mining performance will be poor."
        fi
    fi
    log "All dependencies satisfied."
}

ensure_config_exists() {
    [ -f "$CONFIG_FILE" ] && return 0

    if [ ! -t 0 ]; then
        error "$CONFIG_FILE not found and no interactive terminal is available.\n  Create it first (copy config.json.template to config.json and edit it), then re-run."
    fi

    log "$CONFIG_FILE not found. Starting interactive setup..."
    echo "Please provide the following details to generate a minimal configuration:"

    read -r -p "Enter Monero Wallet Address: " IN_MONERO_WALLET || true
    read -r -p "Enter Tari Wallet Address: " IN_TARI_WALLET || true

    if [ -z "$IN_MONERO_WALLET" ] || [ -z "$IN_TARI_WALLET" ]; then
        error "Wallet addresses are required. Aborting."
    fi

    echo ""
    echo "--- Node Configuration ---"
    read -r -p "Use LOCAL Monero node? (Y/n): " USE_LOCAL || true

    if [[ ! "$USE_LOCAL" =~ ^[Nn] ]]; then
        echo "Local node selected."
        # The local node's RPC credentials are internal to the stack (only p2pool, monerod and
        # the dashboard use them), so we generate them rather than asking you to invent some.
        # They're stored in config.json / .env if you ever need them (e.g. to attach a wallet).
        local IN_MONERO_USER="monero"
        local IN_MONERO_PASS
        IN_MONERO_PASS=$(openssl rand -hex 16)
        log "Generated internal Monero node RPC credentials (saved in $CONFIG_FILE)."
        cat <<EOF > "$CONFIG_FILE"
{
    "monero": {
        "mode": "local",
        "wallet_address": "$IN_MONERO_WALLET",
        "node_username": "$IN_MONERO_USER",
        "node_password": "$IN_MONERO_PASS"
    },
    "tari": {
        "wallet_address": "$IN_TARI_WALLET"
    },
    "p2pool": {
        "pool": "main"
    },
    "dashboard": {
        "secure": true
    }
}
EOF
    else
        echo "Remote node selected."
        read -r -p "Enter Remote Node Host (IP or Domain): " REMOTE_HOST || true
        read -r -p "Enter Remote RPC Port [18081]: " REMOTE_RPC || true
        read -r -p "Enter Remote ZMQ Port [18083]: " REMOTE_ZMQ || true
        REMOTE_RPC=${REMOTE_RPC:-18081}
        REMOTE_ZMQ=${REMOTE_ZMQ:-18083}

        local IN_MONERO_USER="" IN_MONERO_PASS=""
        read -r -p "Does the remote node require authentication? (y/N): " REMOTE_AUTH || true
        if [[ "$REMOTE_AUTH" =~ ^[Yy] ]]; then
            read -r -p "Enter Remote Node Username: " IN_MONERO_USER || true
            read -r -s -p "Enter Remote Node Password: " IN_MONERO_PASS || true
            echo ""
        fi
        cat <<EOF > "$CONFIG_FILE"
{
    "monero": {
        "mode": "remote",
        "wallet_address": "$IN_MONERO_WALLET",
        "node_username": "$IN_MONERO_USER",
        "node_password": "$IN_MONERO_PASS",
        "remote": {
            "host": "$REMOTE_HOST",
            "rpc_port": $REMOTE_RPC,
            "zmq_port": $REMOTE_ZMQ
        }
    },
    "tari": {
        "wallet_address": "$IN_TARI_WALLET"
    },
    "p2pool": {
        "pool": "main"
    },
    "dashboard": {
        "secure": true
    }
}
EOF
    fi
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    log "$CONFIG_FILE created successfully."
}

parse_and_validate_config() {
    log "Parsing configuration..."
    if ! jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE is not valid JSON."
    fi

    # Required fields
    MONERO_WALLET=$(jq -r '.monero.wallet_address // empty' "$CONFIG_FILE")
    TARI_WALLET=$(jq -r '.tari.wallet_address // empty' "$CONFIG_FILE")
    if [ -z "$MONERO_WALLET" ] || [ -z "$TARI_WALLET" ]; then
        error "Missing required wallet addresses in $CONFIG_FILE."
    fi
    # Catch the most common fat-finger: a truncated/placeholder Monero address. Standard
    # mainnet addresses are 95 chars; don't hard-fail (testnet/integrated differ), just warn.
    if [ "$MONERO_WALLET" == "your_monero_wallet_address" ] || [ "$TARI_WALLET" == "your_tari_wallet_address" ]; then
        error "Wallet addresses in $CONFIG_FILE are still the template placeholders. Set your real addresses."
    fi
    if [ "${#MONERO_WALLET}" -lt 90 ]; then
        warn "Monero wallet address looks short (${#MONERO_WALLET} chars) — double-check it's complete."
    fi

    MONERO_MODE=$(jq -r '.monero.mode // "local"' "$CONFIG_FILE")
    case "$MONERO_MODE" in
        local|remote) ;;
        *) error "monero.mode must be \"local\" or \"remote\" (got \"$MONERO_MODE\")." ;;
    esac
    if [ "$MONERO_MODE" == "remote" ]; then
        local remote_host
        remote_host=$(jq -r '.monero.remote.host // empty' "$CONFIG_FILE")
        [ -n "$remote_host" ] || error "monero.mode is \"remote\" but monero.remote.host is not set in $CONFIG_FILE."
    fi

    POOL_TYPE=$(jq -r '.p2pool.pool // "main"' "$CONFIG_FILE")
    case "$POOL_TYPE" in
        main|mini|nano) ;;
        *) error "p2pool.pool must be \"main\", \"mini\", or \"nano\" (got \"$POOL_TYPE\")." ;;
    esac

    MONERO_USER=$(jq -r '.monero.node_username // empty' "$CONFIG_FILE")
    MONERO_PASS=$(jq -r '.monero.node_password // empty' "$CONFIG_FILE")

    # Resolve data directories ("auto"/empty/legacy DYNAMIC_DATA → the stack default under ./data)
    MONERO_DIR=$(resolve_default "$(jq -r '.monero.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/monero")
    TARI_DIR=$(resolve_default "$(jq -r '.tari.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/tari")
    P2POOL_DIR=$(resolve_default "$(jq -r '.p2pool.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/p2pool")
    TOR_DATA_DIR=$(resolve_default "$(jq -r '.tor.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/tor")
    DASHBOARD_DIR=$(resolve_default "$(jq -r '.dashboard.data_dir // empty' "$CONFIG_FILE")" "$PWD/data/dashboard")

    # Guard every data dir against catastrophic chown -R / rm -rf targets before we touch them.
    local d
    for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"; do
        assert_safe_dir "$d"
    done

    # "auto"/empty/DYNAMIC_HOST here means "decide later" (preserved value, prompt, or hostname)
    DASHBOARD_HOST=$(resolve_default "$(jq -r '.dashboard.host // empty' "$CONFIG_FILE")" "")
    # Ensure a strict true/false string is returned, defaulting to true
    DASHBOARD_SECURE=$(jq -r 'if .dashboard.secure != null then .dashboard.secure | tostring else "true" end' "$CONFIG_FILE")
}

# Load secrets and one-time-provisioned values from an existing .env so that re-rendering
# (apply, or a re-run setup) never rotates the proxy token or loses the Tor onion addresses.
# Generates a fresh proxy token only when none exists yet.
load_preserved_state() {
    PROXY_AUTH_TOKEN=$(env_get PROXY_AUTH_TOKEN)
    MONERO_ONION=$(env_get MONERO_ONION_ADDRESS)
    TARI_ONION=$(env_get TARI_ONION_ADDRESS)
    P2POOL_ONION=$(env_get P2POOL_ONION_ADDRESS)
    PRESERVED_HOST_IP=$(env_get HOST_IP)

    [ -n "$PROXY_AUTH_TOKEN" ] || PROXY_AUTH_TOKEN=$(openssl rand -hex 12)
    [ -n "$MONERO_ONION" ] || MONERO_ONION="placeholder"
    [ -n "$TARI_ONION" ] || TARI_ONION="placeholder"
    [ -n "$P2POOL_ONION" ] || P2POOL_ONION="placeholder"
    return 0
}

prepare_directories() {
    log "Initializing data directories..."
    mkdir -p "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"

    # Enforce permissions
    sudo chown -R 100:101 "$TOR_DATA_DIR"
    sudo chown -R "$REAL_USER":"$REAL_USER" "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR"
    mkdir -p "$P2POOL_DIR/stats"
    sudo chmod -R 755 "$P2POOL_DIR/stats"
}

# Lightweight directory check for `apply`: create any missing data dir and chown only the
# ones we just created, so a routine apply does not require sudo on every run.
ensure_directories() {
    local d created=()
    for d in "$MONERO_DIR" "$TARI_DIR" "$P2POOL_DIR" "$TOR_DATA_DIR" "$DASHBOARD_DIR"; do
        if [ ! -d "$d" ]; then
            mkdir -p "$d"
            created+=("$d")
        fi
    done
    mkdir -p "$P2POOL_DIR/stats"
    if [ "${#created[@]}" -gt 0 ]; then
        log "Created new data directories; applying ownership..."
        for d in "${created[@]}"; do
            if [ "$d" == "$TOR_DATA_DIR" ]; then
                sudo chown -R 100:101 "$d"
            else
                sudo chown -R "$REAL_USER":"$REAL_USER" "$d"
            fi
        done
        sudo chmod -R 755 "$P2POOL_DIR/stats"
    fi
}

# Decide the hostname the dashboard is reached at: config wins, then the preserved .env value,
# then (only during interactive setup) a prompt, otherwise the machine hostname.
resolve_dashboard_host() {
    local allow_prompt="${1:-}"
    if [ -n "${DASHBOARD_HOST:-}" ]; then
        HOST_IP="$DASHBOARD_HOST"
        log "Using dashboard hostname '$HOST_IP' from $CONFIG_FILE."
    elif [ -n "${PRESERVED_HOST_IP:-}" ]; then
        HOST_IP="$PRESERVED_HOST_IP"
    elif [ "$allow_prompt" == "interactive" ]; then
        local default_host
        default_host=$(hostname)
        echo "The stack needs to know what hostname you will use to access the dashboard in your browser."
        read -r -p "Enter Hostname [$default_host]: " input_host || true
        HOST_IP="${input_host:-$default_host}"
    else
        HOST_IP=$(hostname)
    fi
}

provision_tor() {
    log "Initializing Tor service to generate Onion addresses..."
    docker compose up -d tor
    # Poll for the three hidden-service hostname files instead of a fixed sleep — Tor can take
    # more or less than 15s to publish them, especially on first run.
    log "Waiting for Tor hidden services to be generated..."
    local elapsed=0 timeout=60
    until docker exec tor test -f /var/lib/tor/monero/hostname \
        && docker exec tor test -f /var/lib/tor/tari/hostname \
        && docker exec tor test -f /var/lib/tor/p2pool/hostname; do
        if [ "$elapsed" -ge "$timeout" ]; then
            error "Timed out after ${timeout}s waiting for Tor hidden-service hostnames."
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    MONERO_ONION=$(docker exec tor cat /var/lib/tor/monero/hostname)
    TARI_ONION=$(docker exec tor cat /var/lib/tor/tari/hostname)
    P2POOL_ONION=$(docker exec tor cat /var/lib/tor/p2pool/hostname)
}

# Single writer for the env file. Derives every value from the parsed config plus the preserved
# secrets/onions/host, so it is safe to call repeatedly (bootstrap, finalize, or apply).
# $1 = target file (defaults to $ENV_FILE); apply renders to a temp file first to diff it.
render_env() {
    local target="${1:-$ENV_FILE}"
    log "Rendering environment configuration ($target)..."

    # Mode → host / ports / compose profile
    local mono_host rpc_port zmq_port profiles
    if [ "$MONERO_MODE" == "local" ]; then
        mono_host="172.28.0.26"
        rpc_port="18081"
        zmq_port="18083"
        profiles="local_node"
    else
        mono_host=$(jq -r '.monero.remote.host // empty' "$CONFIG_FILE")
        rpc_port=$(jq -r '.monero.remote.rpc_port // 18081' "$CONFIG_FILE")
        zmq_port=$(jq -r '.monero.remote.zmq_port // 18083' "$CONFIG_FILE")
        profiles="" # Empty profile disables local monerod
    fi

    # Pruning. Use the `!= null` form, not `//`: jq's `//` treats a literal `false` as absent,
    # which would silently ignore "prune": false and leave pruning on.
    local prune_bool prune
    prune_bool=$(jq -r 'if .monero.prune != null then .monero.prune else true end' "$CONFIG_FILE")
    if [ "$prune_bool" == "true" ]; then prune=1; else prune=0; fi

    # Block-verification threads — hardware-dependent, so derive from THIS host's core count
    # rather than hardcoding (more cores = faster initial-sync verification). Reserve 2 cores
    # and cap at 8 (diminishing returns past that). Override with monero.prep_blocks_threads.
    local prep_threads cores
    prep_threads=$(jq -r '.monero.prep_blocks_threads // "auto"' "$CONFIG_FILE")
    if ! [[ "$prep_threads" =~ ^[0-9]+$ ]]; then
        cores=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
        prep_threads=$(( cores - 2 ))
        [ "$prep_threads" -lt 4 ] && prep_threads=4
        [ "$prep_threads" -gt 8 ] && prep_threads=8
    fi

    # monerod RPC LAN exposure. Default localhost-only: p2pool reaches monerod over the internal
    # Docker network regardless, so the published port is only for external wallets.
    local rpc_bind rpc_lan
    rpc_lan=$(jq -r '.monero.rpc_lan_access // false' "$CONFIG_FILE")
    if [ "$rpc_lan" == "true" ]; then rpc_bind="0.0.0.0"; else rpc_bind="127.0.0.1"; fi

    # P2Pool pool type → flags + p2p port
    local pool_type p2pool_flags p2pool_port
    pool_type=$(jq -r '.p2pool.pool // "main"' "$CONFIG_FILE")
    p2pool_flags=""
    p2pool_port="37889"
    if [ "$pool_type" == "mini" ]; then
        p2pool_flags="--mini"; p2pool_port="37888"
    elif [ "$pool_type" == "nano" ]; then
        p2pool_flags="--nano"; p2pool_port="37890"
    fi

    # XvB config (accepts legacy xmrig_proxy.* keys)
    local xvb_enabled xvb_url xvb_donor xvb_donation_level
    xvb_enabled=$(jq -r 'if .xvb.enabled != null then .xvb.enabled elif .xmrig_proxy.enabled != null then .xmrig_proxy.enabled else "true" end' "$CONFIG_FILE")
    xvb_url=$(jq -r '.xvb.url // .xmrig_proxy.url // empty' "$CONFIG_FILE")
    [ -z "$xvb_url" ] && xvb_url="na.xmrvsbeast.com:4247"
    xvb_donor=$(jq -r '.xvb.donor_id // .xmrig_proxy.donor_id // empty' "$CONFIG_FILE")
    case "$xvb_donor" in
        ""|auto|DYNAMIC_ID) xvb_donor=$(echo "$MONERO_WALLET" | cut -c 1-8) ;;
    esac
    # Donation tier target: auto (default) / donor|vip|whale|mega
    xvb_donation_level=$(jq -r '.xvb.donation_level // empty' "$CONFIG_FILE")
    [ -z "$xvb_donation_level" ] && xvb_donation_level="auto"

    # How much Tari blocks the stack (#31/#35/#51). monerod is required and not configurable
    # (a monerod outage always rejects workers; the miner always waits for monerod's sync).
    # tari_required (default true): a Tari outage rejects workers, the miner waits for Tari's
    # sync, and a Tari-only sync drives full Sync Mode. false = non-blocking Tari.
    local tari_required
    tari_required=$(jq -r 'if .dashboard.tari_required != null then .dashboard.tari_required | tostring else "true" end' "$CONFIG_FILE")

    log "Monero block-prep threads: $prep_threads | pool: $pool_type | mode: $MONERO_MODE"

    cat <<EOF > "$target"
MONERO_DATA_DIR=$MONERO_DIR
TARI_DATA_DIR=$TARI_DIR
P2POOL_DATA_DIR=$P2POOL_DIR
DASHBOARD_DATA_DIR=$DASHBOARD_DIR
TOR_DATA_DIR=$TOR_DATA_DIR
MONERO_NODE_USERNAME=$MONERO_USER
MONERO_NODE_PASSWORD=$MONERO_PASS
MONERO_WALLET_ADDRESS=$MONERO_WALLET
TARI_WALLET_ADDRESS=$TARI_WALLET
MONERO_ONION_ADDRESS=$MONERO_ONION
TARI_ONION_ADDRESS=$TARI_ONION
P2POOL_ONION_ADDRESS=$P2POOL_ONION
P2POOL_FLAGS=$p2pool_flags
P2POOL_PORT=$p2pool_port
XVB_POOL_URL=$xvb_url
XVB_DONOR_ID=$xvb_donor
XVB_ENABLED=$xvb_enabled
XVB_DONATION_LEVEL=$xvb_donation_level
TARI_REQUIRED=$tari_required
P2POOL_URL=172.28.0.28:3333
PROXY_API_PORT=3344
PROXY_AUTH_TOKEN=$PROXY_AUTH_TOKEN
MONERO_PRUNE=$prune
MONERO_PREP_THREADS=$prep_threads
MONERO_RPC_BIND=$rpc_bind
MONERO_NODE_HOST=$mono_host
MONERO_RPC_PORT=$rpc_port
MONERO_ZMQ_PORT=$zmq_port
COMPOSE_PROFILES=$profiles
DASHBOARD_SECURE=$DASHBOARD_SECURE
HOST_IP=$HOST_IP
DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false}
EOF
    # Contains the node RPC password; keep it owner-only.
    chmod 600 "$target" 2>/dev/null || true
}

inject_service_configs() {
    log "Injecting service configurations..."
    cp build/tari/config.toml.template build/tari/config.toml
    local tari_onion_short
    tari_onion_short=$(echo "$TARI_ONION" | cut -d'.' -f1)
    safe_sed "s/<your_tari_onion_address_no_extension>/$tari_onion_short/g" build/tari/config.toml
}

generate_caddyfile() {
    if [ "$DASHBOARD_SECURE" == "true" ]; then
        log "Generating Caddyfile for automatic HTTPS ($HOST_IP)..."
        cat <<EOF > "Caddyfile"
https://$HOST_IP {
    tls internal
    reverse_proxy 127.0.0.1:8000
}
EOF
    else
        log "Generating Caddyfile for HTTP ($HOST_IP)..."
        cat <<EOF > "Caddyfile"
http://$HOST_IP {
    reverse_proxy 127.0.0.1:8000
}
EOF
    fi
}

optimize_kernel() {
    if [ "$SKIP_OPTIMIZE" == "1" ]; then
        log "Skipping kernel/HugePages optimization (--skip-optimize)."
        return 0
    fi
    log "Applying RandomX optimizations (HugePages)..."
    if [ "$OS_TYPE" == "Linux" ]; then
        sudo sysctl -w vm.nr_hugepages=3072

        if [ -f "/etc/default/grub" ]; then
            if ! grep -q "hugepages=" /etc/default/grub; then
                warn "Persistent HugePages requires editing /etc/default/grub and a reboot."
                read -r -p "Modify GRUB for persistent HugePages now? (y/N): " GRUB_OK || true
                if [[ ! "$GRUB_OK" =~ ^[Yy] ]]; then
                    log "Skipped GRUB edit. HugePages set for this boot only (vm.nr_hugepages=3072)."
                    return 0
                fi
                log "Updating GRUB configuration for persistent HugePages..."
                sudo cp /etc/default/grub /etc/default/grub.bak
                sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never /' /etc/default/grub
                if command -v update-grub >/dev/null; then
                    sudo update-grub
                    REBOOT_REQUIRED=true
                else
                    warn "'update-grub' not found. Please manually update your bootloader."
                fi
            else
                log "HugePages already configured in GRUB."
            fi
        fi
    else
        log "Skipping Host HugePages configuration (Not supported on $OS_TYPE)."
    fi
}

prompt_start_stack() {
    read -r -p "Start the P2Pool Starter Stack now? (Y/n): " START_NOW || true
    if [[ ! "$START_NOW" =~ ^[Nn] ]]; then
        stack_up
    else
        echo "You can start the stack later with: $0 up"
    fi
}

# --- Top-level Commands ---

setup() {
    if is_deployed; then
        warn "A previous deployment was detected."
        read -r -p "Re-run setup (re-provisions Tor and may modify GRUB)? (y/N): " RERUN || true
        if [[ ! "$RERUN" =~ ^[Yy] ]]; then
            log "Setup skipped. Edit config.json and run '$0 apply' to propagate config changes,"
            log "or '$0 up' to start the stack."
            exit 0
        fi
    fi

    check_prerequisites
    ensure_config_exists
    parse_and_validate_config
    load_preserved_state
    resolve_dashboard_host "interactive"
    prepare_directories
    render_env            # bootstrap .env so Tor (and compose var substitution) have what they need
    provision_tor         # populates the real onion addresses
    DEPLOYMENT_COMPLETED=true
    render_env            # finalize with real onions + completion flag
    inject_service_configs
    optimize_kernel
    generate_caddyfile

    log "Deployment preparation complete!"
    if [ "$REBOOT_REQUIRED" = true ]; then
        echo -e "\n${C_YELLOW}[!] ATTENTION: System optimization requires a reboot.${C_RESET}"
        echo "Please run: 'sudo reboot' now."
        echo "After reboot, start the stack with: '$0 up'"
    else
        prompt_start_stack
    fi
}

# Describe a changed env key for the apply preview. Prints "FLAG\tmessage" where FLAG is
# DEST (disruptive — apply should confirm) or INFO. Always returns 0 (safe in $()).
describe_change() {
    local key="$1" old="$2" new="$3" flag="INFO" msg
    case "$key" in
        MONERO_PRUNE)
            flag=DEST; msg="Monero pruning ($old → $new) — enabling prunes existing blocks; disabling needs a full re-sync (pruned data can't be restored). Wipe the Monero data dir to fully re-sync." ;;
        COMPOSE_PROFILES)
            flag=DEST
            if [ -z "$new" ]; then
                msg="Switching to a REMOTE Monero node — the local monerod container will be STOPPED and removed (its on-disk data is kept)."
            else
                msg="Switching to a LOCAL Monero node — monerod will start and SYNC the blockchain (large download / disk use)."
            fi ;;
        MONERO_WALLET_ADDRESS)
            flag=DEST; msg="Monero payout address is changing — future mining rewards go to the new address." ;;
        TARI_WALLET_ADDRESS)
            flag=DEST; msg="Tari payout address is changing — future merge-mining rewards go to the new address." ;;
        MONERO_RPC_BIND)
            if [ "$new" == "0.0.0.0" ]; then
                flag=DEST; msg="Monero RPC will be EXPOSED on your LAN ($old → $new) — make sure this is intended."
            else
                msg="Monero RPC bind address: $old → $new."
            fi ;;
        *_DATA_DIR)
            flag=DEST; msg="$key: $old → $new — the service will use the new (empty) directory and re-sync; old data is left in place." ;;
        P2POOL_FLAGS|P2POOL_PORT)
            msg="P2Pool sidechain changing ($key: '$old' → '$new') — p2pool re-syncs the new sidechain and your PPLNS window resets." ;;
        MONERO_NODE_HOST|MONERO_RPC_PORT|MONERO_ZMQ_PORT)
            msg="Monero node endpoint ($key): $old → $new." ;;
        MONERO_NODE_USERNAME|MONERO_NODE_PASSWORD)
            msg="Monero node RPC credential updated ($key)." ;;
        XVB_ENABLED|XVB_POOL_URL|XVB_DONOR_ID|XVB_DONATION_LEVEL)
            msg="XMRvsBeast setting ($key): $old → $new." ;;
        TARI_REQUIRED)
            if [ "$new" == "true" ]; then
                msg="Tari → required — a Tari outage rejects workers, the miner waits for Tari's sync, and a Tari-only sync takes over the dashboard."
            else
                msg="Tari → non-blocking — keep mining Monero through a Tari outage, start as soon as Monero is synced, and keep the operational dashboard while Tari syncs."
            fi ;;
        DASHBOARD_SECURE)
            msg="Dashboard scheme → $([ "$new" == "true" ] && echo HTTPS || echo HTTP) (secure=$new)." ;;
        HOST_IP)
            msg="Dashboard hostname: $old → $new." ;;
        MONERO_PREP_THREADS)
            msg="Monero block-prep threads: $old → $new." ;;
        *)
            msg="$key: $old → $new." ;;
    esac
    printf '%s\t%s' "$flag" "$msg"
}

apply() {
    local assume_yes=0 arg
    for arg in "$@"; do
        case "$arg" in
            -y|--yes) assume_yes=1 ;;
            *) error "Unknown option for apply: $arg. Run '$0 help'." ;;
        esac
    done

    require_env
    parse_and_validate_config
    load_preserved_state
    if [ "$MONERO_ONION" == "placeholder" ] || ! is_deployed; then
        error "Stack is not fully provisioned. Run '$0 setup' first."
    fi

    ensure_directories
    resolve_dashboard_host       # non-interactive
    DEPLOYMENT_COMPLETED=true

    # Render the new config to a staging file and diff it against the live .env, so we can
    # preview the changes and confirm anything disruptive before touching running containers.
    local newenv="${ENV_FILE}.new"
    render_env "$newenv"

    local changed=() key
    while IFS= read -r key; do
        [ -n "$key" ] && changed+=("$key")
    done < <(env_changed_keys "$ENV_FILE" "$newenv")

    if [ "${#changed[@]}" -eq 0 ]; then
        rm -f "$newenv"
        log "No configuration changes detected. Nothing to apply."
        return 0
    fi

    local destructive=0 caddy_changed=0 line flag msg old new
    echo ""
    log "The following changes will be applied:"
    for key in "${changed[@]}"; do
        old=$(env_get_file "$ENV_FILE" "$key")
        new=$(env_get_file "$newenv" "$key")
        case "$key" in HOST_IP|DASHBOARD_SECURE) caddy_changed=1 ;; esac
        line=$(describe_change "$key" "$old" "$new")
        flag=${line%%$'\t'*}
        msg=${line#*$'\t'}
        if [ "$flag" == "DEST" ]; then
            echo -e "  ${C_YELLOW}⚠ ${msg}${C_RESET}"
            destructive=1
        else
            echo "  • ${msg}"
        fi
    done
    echo ""

    if [ "$destructive" -eq 1 ] && [ "$assume_yes" -eq 0 ]; then
        warn "Some of the changes above (⚠) are disruptive."
        read -r -p "Proceed with applying these changes? (y/N): " CONFIRM || true
        if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
            rm -f "$newenv"
            log "Apply cancelled. No changes were made."
            return 0
        fi
    fi

    mv "$newenv" "$ENV_FILE"
    inject_service_configs
    generate_caddyfile

    log "Updating containers..."
    # Compose recreates only the services whose resolved config changed; --remove-orphans
    # drops monerod when a local→remote switch deactivates the local_node profile.
    docker compose up -d --remove-orphans
    # Caddy mounts the Caddyfile read-only, so a content change alone won't recreate it.
    if [ "$caddy_changed" -eq 1 ]; then
        docker compose restart caddy
    fi
    log "Configuration applied."
    announce_dashboard_url
}

# --- Main Execution ---

main() {
    local cmd="${1:-}"
    if [ -n "$cmd" ]; then shift; fi

    case "$cmd" in
        "")
            # No command: first-time users get setup, deployed users get help.
            if is_deployed; then show_help; else setup; fi
            ;;
        setup)
            for arg in "$@"; do
                case "$arg" in
                    --skip-optimize) SKIP_OPTIMIZE=1 ;;
                    --skip-deps)     SKIP_DEPS=1 ;;
                    *) error "Unknown option for setup: $arg. Run '$0 help'." ;;
                esac
            done
            setup
            ;;
        apply)            apply "$@" ;;
        up)               require_deployed; stack_up ;;
        down)             require_env; stack_down ;;
        restart)          require_deployed; stack_restart ;;
        upgrade)          require_deployed; stack_upgrade ;;
        logs)             require_env; log "Following logs (Ctrl+C to exit)..."; docker compose logs -f "$@" ;;
        status)           require_env; stack_status || exit 1 ;;
        reset-dashboard)  require_deployed; reset_dashboard ;;
        help|-h|--help)   show_help ;;
        *)                error "Unknown command: $cmd. Run '$0 help'." ;;
    esac
}

if [ "$_STACK_SOURCED" = "0" ]; then
    main "$@"
fi
