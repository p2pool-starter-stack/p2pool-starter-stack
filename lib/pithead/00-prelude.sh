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

# --- Mutation lock (#1342) ---
#
# pithead had no mutual exclusion of any kind, so the writers on a box — the firstboot wizard
# loop, the host-side runner draining the dashboard's spooled intents, and an operator verb from a
# shell or a harness — could interleave with one another. The observed harm: a concurrent `backup`
# runs stack_down inside a still-running `setup`, setup fails for a reason that has nothing to do
# with the configuration, and the wizard treats that as a bad configuration (#1059).
#
# The lock goes around mutating WINDOWS, never around a whole verb. `backup` prompts for a
# passphrase and then for permission to stop the stack, `restore` asks before overwriting, and
# firstboot-wizard waits on a web form under TimeoutStartSec=infinity
# (os/overlay/pithead-firstboot.service:35). A verb-scoped lock would sit inside those waits and
# convert a race into a hang — the harder failure to read out of a journal, because a hang has no
# message.
#
# Re-entrancy needs TWO mechanisms, because pithead DOES re-invoke itself for mutating verbs
# (run_chain, control_lifecycle, control_backup):
#   - within one process (backup -> down -> up): a depth counter.
#   - across a re-invocation: an EXPORTED marker. The child inherits the descriptor across exec,
#     so the lock is already held on its behalf — but without the marker it runs its own `exec 9>`,
#     which opens a SECOND open file description on the same file and blocks on its own parent.
#     Both halves were confirmed against the tools rather than reasoned: a child's `flock -n` on
#     the inherited fd succeeds, and on a freshly opened one it blocks.
#
# fd 9 is a literal on purpose. Descriptors bash allocates itself (`exec {fd}>`) and any fd >= 10
# are close-on-exec, so a child would not inherit the hold; fds 0-9 named explicitly are not.
# Nothing else in this script uses fd 9. The lock lives on the descriptor, so the kernel releases
# it if the holder dies — which matters here because error() is an exit and several of these paths
# reach it.
_PITHEAD_LOCK_DEPTH=0
_PITHEAD_LOCK_OWNED=0
_PITHEAD_LOCK_PATH=""
_PITHEAD_LOCK_WARNED=0
# Long enough that a routine `compose down` (seconds) never turns a backup into a refusal, short
# enough that a wedged holder is reported instead of waited on forever.
PITHEAD_LOCK_TIMEOUT="${PITHEAD_LOCK_TIMEOUT:-300}"
# A timeout exits with THIS, not error()'s 1, because one caller has to tell the two apart:
# os/overlay/pithead-boot reboots on its first failed boot so the bootloader falls back to the
# other A/B slot, and declares "the fault is not the slot" on its second. A boot that merely
# collided with the firstboot wizard's `setup` would spend that fallback on a slot that is fine
# and then misdiagnose itself. 75 is sysexits.h's EX_TEMPFAIL — retry, nothing is wrong here.
PITHEAD_EX_LOCK_TIMEOUT=75

# WHERE the lock lives, and it is deliberately not the install directory.
#
# `$PWD/.pithead.lock` keys the lock on the directory pithead was run from — but the documented
# bundle layout (docs/operations.md, "A recommended layout") gives ONE stack SEVERAL of those:
# `current -> pithead-v1.5.0` sits beside `pithead-v1.4.0`, and the dashboard's one-click upgrade
# creates a third sibling and runs `./pithead upgrade` INSIDE it (control_upgrade). Every one of
# them drives the same Compose project (`pithead`, pinned in docker-compose.yml) against the same
# data dirs, so a directory-keyed lock leaves that upgrade and a concurrent `backup` mutually
# invisible — a lock that cannot be contended is #1059 again, wearing a green tick.
#
# So key it on the DEPLOY ROOT: the one thing every version dir of a stack shares. A plain
# `pithead/` checkout has no siblings, keeps the directory-local path, and is unaffected.
# PITHEAD_LOCK_FILE still overrides both, which is what the suite drives.
is_versioned_install_dir() { # <dir> — the `pithead-vX.Y.Z` shape control_upgrade's #629 deploy creates
    [[ "$(basename "$1")" =~ ^pithead-v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
mutation_lock_path() {
    if [ -n "${PITHEAD_LOCK_FILE:-}" ]; then
        printf '%s' "$PITHEAD_LOCK_FILE"
    elif is_versioned_install_dir "$PWD"; then
        printf '%s' "$(dirname "$PWD")/.pithead.lock"
    else
        printf '%s' "$PWD/.pithead.lock"
    fi
}

# Describe the holder of a window we could not take — and never name one we cannot show is still
# there.
#
# The record is written by whoever takes the lock and cleared by its release, but only an ORDERLY
# release clears it. A verb that is Ctrl-C'd, or that hits `error()` inside its window, leaves its
# line on disk: the kernel drops the flock with the descriptor, so the lock goes free while the
# record does not. A later waiter reading that line would be told to wait for a pid that exited —
# the exact misdiagnosis this message exists to prevent. The gap is narrow but ordinary: the next
# acquire truncates the record only AFTER it has taken the lock, so a third invocation that loses
# `flock -n` in between reads the dead line, and a holder that is not pithead at all (an
# operator's own `flock .pithead.lock`) never writes one and so never clears the dead line either.
#
# So the record is trusted only while the pid it names is alive. `/proc` is asked first because it
# answers regardless of who owns the process: `kill -0` returns non-zero on EPERM, and a root
# `pithead` holding the window against an unprivileged waiter is an ordinary case here, not an
# exotic one. `kill -0` is the fallback where /proc is not mounted. Anything that does not parse
# as our own `pid=<n>` record is reported as unrecorded rather than echoed back, because a line we
# cannot check is a line we cannot stand behind.
#
# What this does NOT cover, stated rather than implied: pid REUSE. A recycled pid reads as live
# and we would name the wrong holder — the same wrong name the code has without this check, in a
# far rarer case, and it costs a misleading message rather than a wrong action. The wait itself is
# correct either way, because it is the flock that decides it, never the record.
mutation_lock_holder() { # <lock file> — a holder description safe to show an operator
    local line pid
    line=$(head -n 1 "$1" 2>/dev/null | tr -d '[:cntrl:]' | head -c 120)
    pid="${line#pid=}"
    pid="${pid%% *}"
    if [ -n "$line" ] && [[ "$pid" =~ ^[0-9]+$ ]] &&
        { [ -d "/proc/$pid" ] || kill -0 "$pid" 2>/dev/null; }; then
        printf '%s' "$line"
        return 0
    fi
    printf '%s' "holder unrecorded"
}

mutation_lock_acquire() { # <verb label>
    local label="${1:-pithead}"

    # Already inside a window this process holds (backup -> down/up): count and return.
    if [ "$_PITHEAD_LOCK_DEPTH" -gt 0 ]; then
        _PITHEAD_LOCK_DEPTH=$((_PITHEAD_LOCK_DEPTH + 1))
        return 0
    fi

    # Held by an ancestor pithead that re-invoked us — we inherited its descriptor, so the lock is
    # already held on our behalf. Opening our own here is the deadlock described above.
    if [ -n "${PITHEAD_LOCK_HELD:-}" ]; then
        _PITHEAD_LOCK_DEPTH=1
        return 0
    fi

    if ! command -v flock >/dev/null 2>&1; then
        # Refusing to run `up` on a box without util-linux would be a worse regression than the
        # race this closes, so degrade — but loudly and once, never silently.
        if [ "$_PITHEAD_LOCK_WARNED" -eq 0 ]; then
            warn "flock is not installed, so pithead cannot serialise itself — another pithead running now can interleave with this one."
            _PITHEAD_LOCK_WARNED=1
        fi
        return 0
    fi

    _PITHEAD_LOCK_PATH="$(mutation_lock_path)"
    # Append, never truncate: `9>` empties the file at OPEN time — before the flock is taken — so
    # it would wipe the holder record the waiter below is about to read.
    #
    # Fail OPEN here, matching the missing-flock branch above and for the same reason: a lock file
    # this user cannot open is an environment fault (a deploy root only root can write, a
    # read-only mount), and refusing every mutating verb on such a box is a worse regression than
    # the race this closes. The two environmental failures are now handled the same direction on
    # purpose — the asymmetry that used to sit here was not deliberate.
    if ! exec 9>>"$_PITHEAD_LOCK_PATH"; then
        if [ "$_PITHEAD_LOCK_WARNED" -eq 0 ]; then
            warn "Cannot open the pithead lock file ($_PITHEAD_LOCK_PATH), so pithead cannot serialise itself — another pithead running now can interleave with this one."
            _PITHEAD_LOCK_WARNED=1
        fi
        _PITHEAD_LOCK_PATH=""
        return 0
    fi
    if ! flock -n 9; then
        local holder
        holder="$(mutation_lock_holder "$_PITHEAD_LOCK_PATH")"
        warn "Another pithead operation is in progress ($holder) — waiting up to ${PITHEAD_LOCK_TIMEOUT}s for it to finish."
        if ! flock -w "$PITHEAD_LOCK_TIMEOUT" 9; then
            exec 9>&-
            # error()'s message, error()'s exit — except the status, for the reason at
            # PITHEAD_EX_LOCK_TIMEOUT above. Anything reading only the message is unaffected.
            echo -e "${C_RED}[ERROR]${C_RESET} Timed out after ${PITHEAD_LOCK_TIMEOUT}s waiting for another pithead operation ($holder) — nothing was changed. Re-run '$0 $label' once it has finished." >&2
            exit "$PITHEAD_EX_LOCK_TIMEOUT"
        fi
    fi
    _PITHEAD_LOCK_OWNED=1
    _PITHEAD_LOCK_DEPTH=1
    # Exported, not merely set: the marker has to survive into a re-invoked child.
    export PITHEAD_LOCK_HELD="$$"
    # Record the holder now that we are one. A truncating write through a second descriptor is
    # safe while we hold the lock, and it is what lets the next waiter name who it is waiting for.
    #
    # `$BASHPID`, not `$$`, and the difference is load-bearing rather than pedantic: the pid we
    # write is the one a waiter checks for life, so it has to be the process that actually holds
    # fd 9. In a subshell `$$` is the PARENT's pid — the firstboot wizard runs `setup` inside
    # `(setup)` precisely so that the subshell's exit closes fd 9 and releases the window, and a
    # record naming the parent would stay "alive" after the process holding the lock had gone.
    # The `PITHEAD_LOCK_HELD` marker above is a different question — it marks the invocation whose
    # descriptor a child inherits — and correctly stays `$$`.
    printf 'pid=%s verb=%s since=%s\n' "$BASHPID" "$label" \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)" >"$_PITHEAD_LOCK_PATH" 2>/dev/null || true
    return 0
}

mutation_lock_release() {
    [ "$_PITHEAD_LOCK_DEPTH" -gt 0 ] || return 0
    _PITHEAD_LOCK_DEPTH=$((_PITHEAD_LOCK_DEPTH - 1))
    [ "$_PITHEAD_LOCK_DEPTH" -eq 0 ] || return 0
    # An inherited hold belongs to the ancestor: never close its descriptor and never clear its
    # record. Only the process that took the lock gives it back.
    [ "$_PITHEAD_LOCK_OWNED" -eq 1 ] || return 0
    # Clear the record while we still hold the lock, so a stale line can never name a holder that
    # has already gone.
    : >"$_PITHEAD_LOCK_PATH" 2>/dev/null || true
    _PITHEAD_LOCK_OWNED=0
    unset PITHEAD_LOCK_HELD
    exec 9>&-
    return 0
}
