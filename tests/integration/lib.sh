# shellcheck shell=bash
#
# Shared library for the Pithead integration test harness (tests/integration/).
#
# This file is *sourced*, never executed. It defines pure helpers (config rendering,
# expectation derivation, redaction) plus thin I/O wrappers (run a command on the target,
# poll for readiness) that the runner and the self-test build on. Keeping the pure logic
# here lets tests/integration/selftest.sh exercise it without a real server.
#
# Target model: every command runs *on the box* — either over SSH or, with --local, directly.
# Reads (dashboard JSON, pithead status) therefore behave identically in both modes, and we
# never depend on the runner being able to resolve the box's dashboard hostname.

# --- Output -----------------------------------------------------------------
# Colour only on a TTY with NO_COLOR unset (https://no-color.org), matching pithead.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    IT_RESET='\033[0m'; IT_GREEN='\033[1;32m'; IT_YELLOW='\033[1;33m'; IT_RED='\033[1;31m'; IT_DIM='\033[2m'
else
    IT_RESET=''; IT_GREEN=''; IT_YELLOW=''; IT_RED=''; IT_DIM=''
fi

it_log()  { echo -e "${IT_GREEN}[ITEST]${IT_RESET} $1"; }
it_warn() { echo -e "${IT_YELLOW}[ITEST]${IT_RESET} $1" >&2; }
it_err()  { echo -e "${IT_RED}[ITEST]${IT_RESET} $1" >&2; }
it_step() { echo -e "${IT_DIM}  → $1${IT_RESET}"; }

# --- Secrets hygiene --------------------------------------------------------
# The box holds real RPC creds, a proxy token, and onion addresses. Redact anything that
# looks secret before it reaches a log file or the terminal. Defence-in-depth: we also avoid
# printing these values in the first place. Patterns cover .env KEY=VALUE lines and .onion
# hostnames. Keep this conservative — over-redaction is safe, leaks are not.
redact() {
    sed -E \
        -e 's/(PROXY_AUTH_TOKEN|MONERO_NODE_PASSWORD|MONERO_NODE_USERNAME|.*_PASSWORD|.*_TOKEN|.*_SECRET)=.*/\1=<redacted>/' \
        -e 's/[a-z2-7]{56}\.onion/<redacted>.onion/g'
}

# --- Assertions -------------------------------------------------------------
# Counters are global so the runner can total them across scenarios.
IT_PASS=0
IT_FAIL=0
IT_FAILED_NAMES=""

it_pass() { IT_PASS=$((IT_PASS + 1)); printf '    %b✓%b %s\n' "$IT_GREEN" "$IT_RESET" "$1"; }
it_fail() {
    IT_FAIL=$((IT_FAIL + 1))
    IT_FAILED_NAMES="${IT_FAILED_NAMES}\n    - ${IT_CURRENT_SCENARIO:-?}: $1"
    printf '    %b✗%b %s\n        %s\n' "$IT_RED" "$IT_RESET" "$1" "${2:-}"
}

assert_eq()       { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1" "expected [$3], got [$2]"; fi; }
assert_ne()       { if [ "$2" != "$3" ]; then it_pass "$1"; else it_fail "$1" "expected not [$3]"; fi; }
assert_rc()       { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1" "expected rc $3, got $2"; fi; }
assert_contains() { case "$2" in *"$3"*) it_pass "$1" ;; *) it_fail "$1" "[$2] missing [$3]" ;; esac; }
# Numeric "greater than / >=" with a graceful non-number guard.
assert_num_ge()   {
    if [ -n "$2" ] && [ "$2" -ge "$3" ] 2>/dev/null; then it_pass "$1"; else it_fail "$1" "expected >= $3, got [$2]"; fi
}
assert_num_gt()   {
    if [ -n "$2" ] && [ "$2" -gt "$3" ] 2>/dev/null; then it_pass "$1"; else it_fail "$1" "expected > $3, got [$2]"; fi
}

# --- Config rendering (pure) ------------------------------------------------
# Map a space-separated list of `dotted.path=value` overrides into a jq program that applies
# them to a config.json. Values are typed: true/false -> boolean, integers -> number,
# everything else -> string. Pure and deterministic so selftest.sh can verify it.
overrides_to_jq() {
    local program="." pair path value jsonval
    for pair in "$@"; do
        [ -z "$pair" ] && continue
        path="${pair%%=*}"
        value="${pair#*=}"
        case "$value" in
            true|false)               jsonval="$value" ;;
            ''|*[!0-9-]*)             jsonval="\"$value\"" ;;   # has a non-digit -> string
            *)                        jsonval="$value" ;;       # all digits (+ optional leading -) -> number
        esac
        program="${program} | .${path}=${jsonval}"
    done
    printf '%s' "$program"
}

# Render a scenario's config.json to stdout: start from the box's baseline config (real
# wallets / data dirs / host preserved) and apply the scenario overrides. Requires jq.
render_scenario_config() {
    local baseline_json="$1"; shift
    local program; program="$(overrides_to_jq "$@")"
    printf '%s' "$baseline_json" | jq "$program"
}

# Decide whether a scenario can run on this box, augmenting its overrides where needed (an alt
# data dir for the prune axis, a remote endpoint for remote mode). On success sets RESOLVED to
# the final override string and returns 0; on a missing prerequisite sets SKIP_REASON and
# returns 1 — no silent drops, and never a prune flip on the canonical synced DB (which would
# invalidate it). Reads the globals BASELINE_PRUNE / PRUNED_DATA_DIR / FULL_DATA_DIR /
# REMOTE_MONERO_HOST (all optional). Pure given those globals, so the self-test exercises it.
RESOLVED=""
SKIP_REASON=""
# shellcheck disable=SC2034  # RESOLVED/SKIP_REASON are output globals consumed by run.sh & selftest.sh
resolve_overrides() {
    local overrides="$1" prune mode out="$1"
    RESOLVED=""; SKIP_REASON=""

    prune="$(printf '%s' "$overrides" | tr ' ' '\n' | sed -n 's/^monero\.prune=//p')"
    mode="$(printf '%s' "$overrides"  | tr ' ' '\n' | sed -n 's/^monero\.mode=//p')"

    # Prune axis: only flip away from the baseline DB if a matching synced dir is provided —
    # flipping prune on the canonical dir would invalidate it (a DEST change).
    if [ "$prune" = "true" ] && [ "${BASELINE_PRUNE:-}" = "0" ]; then
        [ -n "${PRUNED_DATA_DIR:-}" ] || { SKIP_REASON="needs --pruned-data-dir (box baseline is full)"; return 1; }
        out="$out monero.data_dir=$PRUNED_DATA_DIR"
    fi
    if [ "$prune" = "false" ] && [ "${BASELINE_PRUNE:-}" = "1" ]; then
        [ -n "${FULL_DATA_DIR:-}" ] || { SKIP_REASON="needs --full-data-dir (box baseline is pruned)"; return 1; }
        out="$out monero.data_dir=$FULL_DATA_DIR"
    fi

    # Remote mode needs an external endpoint to point at.
    if [ "$mode" = "remote" ]; then
        [ -n "${REMOTE_MONERO_HOST:-}" ] || { SKIP_REASON="needs --remote-monero-host"; return 1; }
        out="$out monero.remote.host=$REMOTE_MONERO_HOST"
    fi

    RESOLVED="$out"
    return 0
}

# --- Expectation derivation (pure) ------------------------------------------
# Given a rendered config.json, list the services we expect to be running. The bundled
# monerod only runs in local mode (the local_node compose profile); in remote mode it must
# be ABSENT. Everything else is always expected. Mirrors stack_status()'s profile gating.
EXPECTED_ALWAYS="caddy dashboard docker-control docker-proxy p2pool tari tor xmrig-proxy"

expected_services() {
    local config_json="$1" mode
    mode="$(printf '%s' "$config_json" | jq -r '.monero.mode // "local"')"
    if [ "$mode" = "local" ]; then
        printf '%s\n' "monerod $EXPECTED_ALWAYS" | tr ' ' '\n' | sort
    else
        printf '%s\n' "$EXPECTED_ALWAYS" | tr ' ' '\n' | sort
    fi
}

# Services that must NOT exist for this config (remote mode -> no local monerod).
absent_services() {
    local config_json="$1" mode
    mode="$(printf '%s' "$config_json" | jq -r '.monero.mode // "local"')"
    [ "$mode" = "remote" ] && printf 'monerod\n'
}

# Human-readable pool label as the dashboard reports it, from the config pool key.
pool_label() {
    case "$1" in
        main) printf 'Main' ;;
        mini) printf 'Mini' ;;
        nano) printf 'Nano' ;;
        *)    printf '%s' "$1" ;;
    esac
}

# --- Target I/O (SSH or local) ----------------------------------------------
# Globals set by the runner: IT_MODE (ssh|local), IT_SSH_DEST, IT_SSH_OPTS (array),
# IT_REMOTE_DIR, IT_PITHEAD (the pithead invocation, e.g. "./pithead" or "sudo ./pithead").

# Run a shell snippet on the target, in the stack directory. The snippet is our own trusted
# code; we never interpolate untrusted data into it. Returns the remote command's exit code.
rx() {
    local snippet="$1"
    if [ "$IT_MODE" = "local" ]; then
        ( cd "$IT_REMOTE_DIR" && bash -c "$snippet" )
    else
        local remote
        remote="cd $(quote_arg "$IT_REMOTE_DIR") && { $snippet; }"
        # -n: never read OUR stdin. rx runs inside `while read … done < <(scenario_matrix)` loops;
        # an ssh that inherits stdin drains the loop's remaining input, silently running only the
        # first scenario. rx never needs stdin (push_config has its own piped ssh), so -n is safe.
        ssh -n "${IT_SSH_OPTS[@]}" "$IT_SSH_DEST" "$remote"
    fi
}

# Quote a single argument for safe expansion inside the remote shell string.
quote_arg() { printf '%q' "$1"; }

# Run pithead with a subcommand on the target, e.g. `pithead status` or `pithead apply -y`.
pithead() { rx "$IT_PITHEAD $*"; }

# Fetch the dashboard state JSON from the box (dashboard binds 127.0.0.1:8000 on the host
# network). Empty output on failure so callers can detect unreachable.
api_state() { rx "curl -fsS --max-time 10 http://127.0.0.1:8000/api/state" 2>/dev/null; }

# Split a "<state> <health>" string (from service_state) into its two fields. Pure helpers so
# the self-test can verify the fault-injection predicates classify correctly.
svc_state_of()  { printf '%s' "${1%% *}"; }
svc_health_of() { printf '%s' "${1##* }"; }

# Pull a jq path out of a JSON blob, printing nothing for an absent/null value. The `?`
# swallows "cannot index null" on a missing parent, and `values` drops nulls — but NOT
# boolean false (so `.monero.prune == false` reads as "false", not ""; `// empty` would
# wrongly swallow it because false is falsy in jq).
jq_get() { printf '%s' "$1" | jq -r "($2)? | values" 2>/dev/null; }

# Authoritative "is Monero caught up?" — query monerod's own get_info on the box (creds stay
# on the box) and trust its `synchronized` flag / target_height 0, exactly like the sync gate.
# This is the readiness GATE (the source of truth, and it avoids waiting on a dashboard poll cycle).
# The dashboard's `.sync.monero.state` now also reaches "done" for a synced node — run.sh asserts
# that display separately. Returns 0 when synced.
monero_caught_up() {
    rx 'u=$(grep -E "^MONERO_NODE_USERNAME=" .env 2>/dev/null | cut -d= -f2-);
        p=$(grep -E "^MONERO_NODE_PASSWORD=" .env 2>/dev/null | cut -d= -f2-);
        url=$(grep -E "^MONERO_RPC_URL=" .env 2>/dev/null | cut -d= -f2-); [ -n "$url" ] || url="http://127.0.0.1:18081";
        if [ -n "$u" ]; then body=$(curl -fsS --max-time 8 --digest -u "$u:$p" "$url/get_info" 2>/dev/null);
        else body=$(curl -fsS --max-time 8 "$url/get_info" 2>/dev/null); fi;
        printf "%s" "$body" | jq -e "(.status==\"OK\") and ((.synchronized==true) or (.target_height==0))" >/dev/null 2>&1'
}

# --- Readiness waiters ------------------------------------------------------
# Poll a predicate until it succeeds or the timeout elapses. The interval is a *poll* cadence
# against a real readiness signal — not a fixed "sleep and hope" (issue #54). Returns 0 on
# success, 1 on timeout.
now_s() { date +%s; }

wait_for() {  # wait_for <timeout_s> <interval_s> <desc> <predicate-cmd...>
    local timeout="$1" interval="$2" desc="$3"; shift 3
    local deadline=$(( $(now_s) + timeout ))
    it_step "waiting for ${desc} (timeout ${timeout}s)…"
    while :; do
        if "$@"; then return 0; fi
        if [ "$(now_s)" -ge "$deadline" ]; then
            it_warn "timed out after ${timeout}s waiting for ${desc}"
            return 1
        fi
        sleep "$interval"
    done
}

# Predicate: pithead status exits 0 (all expected services healthy / intentional-stops aside).
_pred_status_ok() { pithead status >/dev/null 2>&1; }

# Predicate: monerod itself reports caught up (authoritative; see monero_caught_up).
_pred_monero_synced() { monero_caught_up; }

# Predicate: the dashboard's monero sync PANEL has settled to "done" — distinct from
# _pred_monero_synced, which reads monerod's RPC directly. After a scenario's apply recreates the
# dashboard, the panel starts at "loading" and only flips to "done" once the first monerod poll lands,
# so we poll it rather than reading cold. A single-shot read raced that first poll and spuriously
# failed one scenario during the v1.0.0 release gate; a genuinely stuck panel (the #180 regression)
# never settles, so a bounded wait still catches it.
_pred_monero_panel_done() {
    local st; st="$(api_state)"; [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.sync.monero.state')" = "done" ]
}

# Predicate: the sync gate has released the miner — at least one worker is online on the proxy.
# (proxy_workers is the reliable signal; stratum.conns can read 0 on a healthy, mining box.)
_pred_miner_running() {
    local st; st="$(api_state)"; [ -n "$st" ] || return 1
    local w; w="$(jq_get "$st" '.proxy_workers')"
    [ -n "$w" ] && [ "$w" -ge 1 ] 2>/dev/null
}

# Predicate: Tari has caught up — its .sync.tari.state reaches "done" once it has a reliable target,
# so the dashboard field is authoritative here (Monero's panel now reaches "done" for a synced node
# too). After
# a restart Tari needs a moment to re-establish peers and close its offline gap, so we poll this
# rather than asserting cold (issue #54: a real readiness signal, not "sleep and hope").
_pred_tari_synced() {
    local st; st="$(api_state)"; [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.sync.tari.state')" = "done" ]
}

# Predicate: p2pool has joined the expected sidechain and the dashboard can classify it. The pool
# type is inferred from connected peers' ports (detect_pool_type: 37889 Main / 37888 Mini / 37890
# Nano), so right after a sidechain switch it reads "Unknown" until enough peers on the NEW chain
# connect — poll until it matches the expected label rather than asserting cold (issue #54).
_pred_pool_ready() {  # _pred_pool_ready <expected-label>
    local st; st="$(api_state)"; [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.pool.type')" = "$1" ]
}

# Predicate: hashes are flowing end-to-end (miner → proxy → p2pool stratum). stratum.total_hashes is
# a per-session counter that RESETS to 0 on a p2pool restart, then climbs once the proxy's upstream
# reconnects and the first share lands — so right after an apply (especially a pool switch, where
# p2pool re-syncs its sidechain before serving) it reads 0. It's monotonic within a session, so
# polling until >0 is robust where the instantaneous stratum.conns is not (issue #54).
_pred_hashes_flowing() {
    local st; st="$(api_state)"; [ -n "$st" ] || return 1
    local h; h="$(jq_get "$st" '.stratum.total_hashes')"
    [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null
}

wait_status_ok()     { wait_for "${1:-180}" 5 "pithead status OK"     _pred_status_ok; }
wait_monero_synced() { wait_for "${1:-300}" 10 "Monero sync complete" _pred_monero_synced; }
wait_miner_running() { wait_for "${1:-180}" 5 "miner released"        _pred_miner_running; }
wait_tari_synced()   { wait_for "${1:-300}" 10 "Tari sync complete"   _pred_tari_synced; }
wait_pool_ready()    { wait_for "${1:-180}" 5 "pool type determinate (${2})" _pred_pool_ready "$2"; }
wait_hashes_flowing() { wait_for "${1:-300}" 5 "stratum hashes flowing" _pred_hashes_flowing; }

# --- Artifact capture -------------------------------------------------------
# On a scenario failure, collect everything needed to debug it — redacted. Writes into
# <outdir>/<scenario>/. Best-effort: never let capture failures mask the test result.
capture_artifacts() {
    local scenario="$1" outdir="$2"
    local dir="${outdir}/${scenario}"
    mkdir -p "$dir"
    it_step "capturing artifacts to ${dir}"
    rx "docker compose ps"                 2>&1 | redact > "${dir}/compose-ps.txt"      || true
    rx "$IT_PITHEAD status"                2>&1 | redact > "${dir}/status.txt"          || true
    rx "$IT_PITHEAD doctor"                2>&1 | redact > "${dir}/doctor.txt"          || true
    rx "cat config.json"                   2>&1 | redact > "${dir}/config.json"         || true
    rx "cat .env"                          2>&1 | redact > "${dir}/env.redacted.txt"    || true
    api_state                                   | redact > "${dir}/api-state.json"      || true
    # Last 200 lines of each service's logs, redacted.
    rx "docker compose logs --tail=200 --no-color" 2>&1 | redact > "${dir}/logs.txt"   || true
}
