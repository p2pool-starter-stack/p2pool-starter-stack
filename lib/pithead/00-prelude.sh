#!/usr/bin/env bash
#
# Management script for the Monero + Tari merge-mining stack.
#
#   ./pithead setup            First-time setup (interactive config, Tor, optimize, start)
#   ./pithead apply            Re-read config.json and propagate changes to a running stack
#   ./pithead up | down | restart | upgrade
#   ./pithead logs [service] | status | reset-dashboard | help
#
# config.json is the single source of truth. Edit it, then run `./pithead apply`
# to regenerate .env / Caddyfile / Tari config and recreate only the changed containers
# WITHOUT re-provisioning Tor, re-prompting, touching GRUB, or rotating the proxy token.
#
set -Eeuo pipefail

# --- Logging Utilities ---
# Colour only when stdout is a terminal and NO_COLOR is unset (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'
    C_GREEN='\033[1;32m'
    C_YELLOW='\033[1;33m'
    C_RED='\033[1;31m'
else
    C_RESET=''
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
fi
readonly C_RESET C_GREEN C_YELLOW C_RED

log() { echo -e "${C_GREEN}[pithead]${C_RESET} $1"; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1" >&2; }
error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2
    exit 1
}

on_err() {
    local ec=$?
    echo -e "${C_RED}[ERROR]${C_RESET} pithead aborted unexpectedly (exit $ec)." >&2
    echo "Re-run with 'bash -x $0 <command>' to see where, and check the output above." >&2
}

# Detect Operating System
OS_TYPE="$(uname -s)"
readonly OS_TYPE
# PITHEAD_CONFIG_FILE points a single invocation at an alternate candidate config — the control
# runner (#33) uses it to preview a staged config with `apply --dry-run` without touching the
# live config.json. Everything else (the .env, generated files) still belongs to this checkout.
readonly CONFIG_FILE="${PITHEAD_CONFIG_FILE:-config.json}"
readonly ENV_FILE=".env"
# Canonical closed schema: every known config.json leaf path, shipped beside this script (bundle +
# checkout root). The #33 control gate uses it to refuse a staged config carrying any path the
# schema doesn't know — the "unrecognized key renders to no env var, so no porcelain row" smuggling
# gap. Relative like CONFIG_FILE/ENV_FILE (the script cd's to its own dir at startup).
readonly REFERENCE_CONFIG="config.reference.json"
# The core config-key shortlist (#502/#529): dotted paths only the operator can supply, shared
# between the first-run wizard below and the dashboard's core form section (once #529's regroup
# lands there). A tier-1 test asserts every path here exists in REFERENCE_CONFIG.
readonly CORE_KEYS_CONFIG="config.core-keys.json"
# Marker (beside .env) that records the one-time "what happens next" epilogue has been shown (#384),
# so the onboarding note appears on the first `up` after a fresh setup, not on every later restart.
readonly FIRST_RUN_MARKER=".pithead-first-run-done"
# ${USER:-$(id -un)}: USER is a login-session convention, not a guarantee — systemd services and
# containers may run without it, and set -u turns the reference into a fatal error at source time.
readonly REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
# Where operator messages send a reader for the long version (#1024). A release bundle carries the
# CLI, the compose file, the config files and cosign.pub — deliberately no docs/, so a message that
# names a repo path resolves to nothing on the installs that make up most of the fleet. Point at the
# published copy instead: `main` is the released-only branch, so it is the documentation for the
# version an operator is actually running. Bare paths are still fine in COMMENTS, which only ever
# get read inside a checkout that has them.
readonly DOCS_URL="https://github.com/p2pool-starter-stack/pithead/blob/main"

# Non-root uid:gid the BUILT images run their main process as (#255). pithead owns the data dirs,
# so it chowns each service's bind-mount to this id to match the in-image USER. Tor is the
# exception — it keeps its own alpine 'tor' user (100:101). Was $REAL_USER when every container
# ran as root; existing installs are migrated in place by ensure_owner on the next apply/upgrade.
readonly APP_UID=1000
readonly APP_GID=1000

# Upper bound on a wizard-time restore upload (#909): a Pithead backup holds only config,
# keys and the dashboard database, never the blockchains — 64 MiB is generous headroom over
# that. Mirrored in wizard.py's own cap (client + server, per the spool contract); the two
# can't share a literal across languages, so keep the VALUE in step by hand.
readonly RESTORE_MAX_BYTES=67108864

REBOOT_REQUIRED=false
SKIP_OPTIMIZE=0
SKIP_DEPS=0
# Set by apply_dry_run before it calls parse_and_validate_config (#556). A dry run must only
# read — persist_node_credentials checks this to skip its config.json write-back while still
# generating in-memory creds so the preview/diff is realistic.
PITHEAD_DRY_RUN=0

# Detect whether we're being sourced (e.g. by the test suite). When sourced we only define
# functions/constants and skip all side effects (cd, traps, running main).
_STACK_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then _STACK_SOURCED=1; fi

if [ "$_STACK_SOURCED" = "0" ]; then
    # Always operate from the directory containing this script, so the stack can be managed from
    # anywhere (./pithead, an absolute path, cron, systemd, ...). All paths below are relative to it.
    # -P (#695): resolve symlinks so every $PWD-derived .env value (CLEARNET_STATE_DIR, CONTROL_DIR,
    # ...) renders the same physical path however pithead is invoked — an interactive apply through
    # the `current ->` deploy symlink and the systemd control runner on the real dir used to render
    # different strings for the same directory, so an unedited preview showed a path "change".
    SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    cd "$SCRIPT_DIR" || error "Cannot enter the script directory: $SCRIPT_DIR"
    # Absolute path to this script — run_chain (#94) re-invokes it once per chained step.
    PITHEAD_SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    readonly PITHEAD_SELF

    # Friendly message on unexpected failure; always clean up the apply staging file.
    trap on_err ERR
    trap 'rm -f "${ENV_FILE}.new" "${ENV_FILE}.dryrun" 2>/dev/null || true' EXIT
fi
