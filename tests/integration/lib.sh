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
    IT_RESET='\033[0m'
    IT_GREEN='\033[1;32m'
    IT_YELLOW='\033[1;33m'
    IT_RED='\033[1;31m'
    IT_DIM='\033[2m'
else
    IT_RESET=''
    IT_GREEN=''
    IT_YELLOW=''
    IT_RED=''
    IT_DIM=''
fi

it_log() { echo -e "${IT_GREEN}[ITEST]${IT_RESET} $1"; }
it_warn() { echo -e "${IT_YELLOW}[ITEST]${IT_RESET} $1" >&2; }
it_err() { echo -e "${IT_RED}[ITEST]${IT_RESET} $1" >&2; }
it_step() { echo -e "${IT_DIM}  → $1${IT_RESET}"; }

# --- Secrets hygiene --------------------------------------------------------
# Redact before anything reaches a log or the terminal. Three shapes: KEY=value / --flag value by
# NAME, an opaque run >=90 chars by SHAPE, and JSON "key": "value" by the key's SUFFIX (#1587),
# matched CASE-INSENSITIVELY (#1590) — add new SPELLINGS, never case variants. THE LIST IS OPEN;
# a closed one opened #1582. Nesting is invisible line-wise: ntfy's bare "url" is secret, xvb's not.
redact() {
    sed -E \
        -e 's/(PROXY_AUTH_TOKEN|MONERO_NODE_PASSWORD|MONERO_NODE_USERNAME|.*_PASSWORD|.*_TOKEN|.*_SECRET)=.*/\1=<redacted>/; s/(--[a-z-]*(login|password|passwd|secret|token|key))([ =])[^[:space:]]+/\1\3<redacted>/g' \
        -e 's/("[A-Za-z0-9_]*(password|passwd|secret|token|login|username|key|wallet|wallet_address|ping_url|donor_id)"[[:space:]]*:[[:space:]]*")([^"\]|\\.)*/\1<redacted>/gI; s/[a-z2-7]{56}\.onion/<redacted>.onion/g; s/[A-Za-z0-9]{90,}/<redacted-address>/g'
}

# --- Assertions -------------------------------------------------------------
# Counters are global so the runner can total them across scenarios. The skip buckets and the
# three helpers that move them live next door; sourced here so anything that has lib.sh has them.
# Fail CLOSED: sourced as a bare name this resolves to "lib.sh/skip-accounting.sh", and a
# harness that merely warns would then miscount every skip in silence — the exact defect below.
# shellcheck source=tests/integration/skip-accounting.sh
source "${BASH_SOURCE[0]%/*}/skip-accounting.sh" ||
    {
        echo "lib.sh: skip-accounting.sh must sit beside it (source lib.sh by a path, not a bare name)" >&2
        exit 1
    }
IT_PASS=0
IT_FAIL=0
IT_FAILED_NAMES=""
it_pass() {
    IT_PASS=$((IT_PASS + 1))
    printf '    %b✓%b %s\n' "$IT_GREEN" "$IT_RESET" "$1"
}
it_fail() {
    IT_FAIL=$((IT_FAIL + 1))
    IT_FAILED_NAMES="${IT_FAILED_NAMES}\n    - ${IT_CURRENT_SCENARIO:-?}: $1"
    printf '    %b✗%b %s\n        %s\n' "$IT_RED" "$IT_RESET" "$1" "${2:-}"
}

assert_eq() { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1" "expected [$3], got [$2]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then it_pass "$1"; else it_fail "$1" "expected not [$3]"; fi; }
assert_rc() { if [ "$2" = "$3" ]; then it_pass "$1"; else it_fail "$1" "expected rc $3, got $2"; fi; }
assert_contains() { case "$2" in *"$3"*) it_pass "$1" ;; *) it_fail "$1" "[$2] missing [$3]" ;; esac }
# Numeric "greater than / >=" with a graceful non-number guard.
assert_num_ge() {
    if [ -n "$2" ] && [ "$2" -ge "$3" ] 2>/dev/null; then it_pass "$1"; else it_fail "$1" "expected >= $3, got [$2]"; fi
}
assert_num_gt() {
    if [ -n "$2" ] && [ "$2" -gt "$3" ] 2>/dev/null; then it_pass "$1"; else it_fail "$1" "expected > $3, got [$2]"; fi
}

# Classify bench-verify-egress.sh output: ok | leak | inconclusive.
# "inconclusive" (neither the OK marker nor a leak line) means the verifier never produced a
# verdict — e.g. the script wasn't found under a release-bundle --dir. That MUST NOT read as a
# leak: a privacy check that can't run and a detected leak are different failures.
egress_verdict() {
    case "$1" in
    *"[verify-egress] OK"*) printf 'ok' ;;
    *LEAK* | *✗*) printf 'leak' ;;
    *) printf 'inconclusive' ;;
    esac
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
        true | false) jsonval="$value" ;;
        '' | *[!0-9-]*) jsonval="\"$value\"" ;; # has a non-digit -> string
        *) jsonval="$value" ;;                  # all digits (+ optional leading -) -> number
        esac
        program="${program} | .${path}=${jsonval}"
    done
    printf '%s' "$program"
}

# Render a scenario's config.json to stdout: start from the box's baseline config (real
# wallets / data dirs / host preserved) and apply the scenario overrides. Requires jq.
render_scenario_config() {
    local baseline_json="$1"
    shift
    local program
    program="$(overrides_to_jq "$@")"
    printf '%s' "$baseline_json" | jq "$program"
}

# Decide whether a scenario can run on this box, augmenting its overrides where needed (an alt
# data dir for the prune axis, a remote endpoint for remote mode). On success sets RESOLVED to
# the final override string and returns 0; on a missing prerequisite sets SKIP_REASON and
# returns 1 — no silent drops, and never a prune flip on the canonical synced DB (which would
# invalidate it). Reads the globals BASELINE_PRUNE / PRUNED_DATA_DIR / FULL_DATA_DIR /
# REMOTE_MONERO_HOST (+_RPC_PORT/_ZMQ_PORT) / REMOTE_TARI_HOST / IT_MONERO_VIEW_KEY / IT_TARI_VIEW_KEY /
# IT_TARI_SPEND_PUBLIC_KEY (all optional). Pure given those globals, so the self-test exercises it.
RESOLVED=""
SKIP_REASON=""
# shellcheck disable=SC2034  # RESOLVED/SKIP_REASON are output globals consumed by run.sh & selftest.sh
resolve_overrides() {
    local overrides="$1" prune mode tari_mode subnet out="$1"
    RESOLVED=""
    SKIP_REASON=""
    SKIP_CLASS="missing" # #1083: every prerequisite below names an input the caller could supply

    prune="$(printf '%s' "$overrides" | tr ' ' '\n' | sed -n 's/^monero\.prune=//p')"
    mode="$(printf '%s' "$overrides" | tr ' ' '\n' | sed -n 's/^monero\.mode=//p')"
    tari_mode="$(printf '%s' "$overrides" | tr ' ' '\n' | sed -n 's/^tari\.mode=//p')"
    subnet="$(printf '%s' "$overrides" | tr ' ' '\n' | sed -n 's/^network\.subnet=//p')"

    # A network.subnet move can't be hot-applied — Compose won't recreate the bridge's IPAM subnet
    # while containers are attached (#180/#201). It is exercised by run.sh's `--subnet` phase, which
    # does a full down -> up on the moved subnet. Skip it here so the hot-apply matrix never fails on
    # a move it structurally can't do (loud SKIP, never a silent drop).
    if [ -n "$subnet" ]; then
        SKIP_REASON="network.subnet move needs a full down/up — run the --subnet phase (not a hot apply)"
        SKIP_CLASS="covered" # the --subnet phase DOES exercise this; it is not an uncovered path (#1083)
        return 1
    fi

    # Prune axis: only flip away from the baseline DB if a matching synced dir is provided —
    # flipping prune on the canonical dir would invalidate it (a DEST change).
    if [ "$prune" = "true" ] && [ "${BASELINE_PRUNE:-}" = "0" ]; then
        [ -n "${PRUNED_DATA_DIR:-}" ] || {
            SKIP_REASON="needs --pruned-data-dir (box baseline is full)"
            return 1
        }
        out="$out monero.data_dir=$PRUNED_DATA_DIR"
    fi
    if [ "$prune" = "false" ] && [ "${BASELINE_PRUNE:-}" = "1" ]; then
        [ -n "${FULL_DATA_DIR:-}" ] || {
            SKIP_REASON="needs --full-data-dir (box baseline is pruned)"
            return 1
        }
        out="$out monero.data_dir=$FULL_DATA_DIR"
    fi

    # Remote mode needs an external endpoint; the host must be BARE, never host:port (#1491).
    if [ "$mode" = "remote" ]; then
        [ -n "${REMOTE_MONERO_HOST:-}" ] || {
            SKIP_REASON="needs --remote-monero-host"
            return 1
        }
        out="$out monero.remote.host=$REMOTE_MONERO_HOST"
        out="$out${REMOTE_MONERO_RPC_PORT:+ monero.remote.rpc_port=$REMOTE_MONERO_RPC_PORT}${REMOTE_MONERO_ZMQ_PORT:+ monero.remote.zmq_port=$REMOTE_MONERO_ZMQ_PORT}"
    fi

    # tari.mode remote (#103/#942) needs its own endpoint — same shape, its own global.
    if [ "$tari_mode" = "remote" ]; then
        [ -n "${REMOTE_TARI_HOST:-}" ] || {
            SKIP_REASON="needs --remote-tari-host"
            return 1
        }
        out="$out tari.remote.host=$REMOTE_TARI_HOST"
    fi

    # Payout confirmation (#381/#462, #942): monero.view_key / tari.view_key are real wallet-scanning
    # secrets for the box's OWN wallet — never hardcoded in the matrix. The scenario instead carries
    # the marker "payout_confirm=env" (not a real config path, always stripped below); an
    # operator-supplied IT_MONERO_VIEW_KEY gates the whole row, the same shape as remote mode needing
    # an endpoint. Tari's pair (IT_TARI_VIEW_KEY + IT_TARI_SPEND_PUBLIC_KEY) is an optional extra
    # folded in only when BOTH are set; it never gates the row on its own.
    if printf '%s' "$overrides" | tr ' ' '\n' | grep -qx 'payout_confirm=env'; then
        out="$(printf '%s' "$out" | tr ' ' '\n' | grep -vx 'payout_confirm=env' | tr '\n' ' ')"
        out="${out% }" # strip the trailing space left by removing the marker token
        out="${out# }" # ...and a leading one, when the marker was the only/first token
        [ -n "${IT_MONERO_VIEW_KEY:-}" ] || {
            SKIP_REASON="needs IT_MONERO_VIEW_KEY (env; a real Monero view key for the box's monero.wallet_address)"
            return 1
        }
        out="${out:+$out }monero.view_key=$IT_MONERO_VIEW_KEY"
        if [ -n "${IT_TARI_VIEW_KEY:-}" ] && [ -n "${IT_TARI_SPEND_PUBLIC_KEY:-}" ]; then
            out="$out tari.view_key=$IT_TARI_VIEW_KEY tari.spend_public_key=$IT_TARI_SPEND_PUBLIC_KEY"
        fi
    fi

    RESOLVED="$out"
    return 0
}

# --- Expectation derivation (pure) ------------------------------------------
# Given a rendered config.json, list the services we expect to be running. The bundled monerod
# only runs in local mode (the local_node compose profile) and the bundled tari only runs in
# local mode (local_tari, #103) — each independently, since the two chains toggle mode on their
# own axis; in remote mode the matching bundled node must be ABSENT. wallet-rpc/tari-wallet
# (#381/#462) only run when their view key is set (payout_confirm/tari_payout_confirm). Everything
# else is always expected. Mirrors stack_status()'s profile gating.
EXPECTED_ALWAYS="caddy dashboard docker-control docker-proxy p2pool tor xmrig-proxy"

expected_services() {
    local config_json="$1" mmode tmode out
    mmode="$(printf '%s' "$config_json" | jq -r '.monero.mode // "local"')"
    tmode="$(printf '%s' "$config_json" | jq -r '.tari.mode // "local"')"
    out="$EXPECTED_ALWAYS"
    [ "$mmode" = "local" ] && out="monerod $out"
    [ "$tmode" = "local" ] && out="tari $out"
    [ -n "$(printf '%s' "$config_json" | jq -r '.monero.view_key // empty')" ] && out="wallet-rpc $out"
    [ -n "$(printf '%s' "$config_json" | jq -r '.tari.view_key // empty')" ] && out="tari-wallet $out"
    printf '%s\n' "$out" | tr ' ' '\n' | sort
}

# Services that must NOT exist for this config (remote mode -> no bundled node for that chain).
absent_services() {
    local config_json="$1" mmode tmode
    mmode="$(printf '%s' "$config_json" | jq -r '.monero.mode // "local"')"
    tmode="$(printf '%s' "$config_json" | jq -r '.tari.mode // "local"')"
    [ "$mmode" = "remote" ] && printf 'monerod\n'
    [ "$tmode" = "remote" ] && printf 'tari\n'
    return 0
}

# Membership against running_services()'s output: compose SERVICE NAMES, one per line. EXACT-LINE,
# never substring (#1478) — "tari" prefixes "tari-wallet" (#381/#462), so a loose match calls a DOWN
# tari up wherever payout-confirm runs. One place, so the three call sites cannot drift apart.
service_present() { printf '%s\n' "$2" | grep -Fqx -- "$1"; }

# Human-readable pool label as the dashboard reports it, from the config pool key.
pool_label() {
    case "$1" in
    main) printf 'Main' ;;
    mini) printf 'Mini' ;;
    nano) printf 'Nano' ;;
    *) printf '%s' "$1" ;;
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
        (cd "$IT_REMOTE_DIR" && bash -c "$snippet")
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

# Pure: does a /metrics response body carry at least one pithead_ SAMPLE line (#379)? Samples
# start the line with the metric name; a "# HELP pithead_…" comment line must NOT count — a body
# of only comments means the route exists but the exporter produced no data.
metrics_has_pithead_sample() { printf '%s\n' "$1" | grep -q '^pithead_'; }

# Split a "<state> <health>" string (from service_state) into its two fields. Pure helpers so
# the self-test can verify the fault-injection predicates classify correctly.
svc_state_of() { printf '%s' "${1%% *}"; }
svc_health_of() { printf '%s' "${1##* }"; }

# Pull a jq path out of a JSON blob, printing nothing for an absent/null value. The `?`
# swallows "cannot index null" on a missing parent, and `values` drops nulls — but NOT
# boolean false (so `.monero.prune == false` reads as "false", not ""; `// empty` would
# wrongly swallow it because false is falsy in jq).
jq_get() { printf '%s' "$1" | jq -r "($2)? | values" 2>/dev/null; }

# Every dotted key path of a config JSON, one per line, sorted — the #880 bundle-vs-canonical
# drift signal. Full paths, not just top-level keys: the drift that bit on the bench dropped
# NESTED keys (monero.view_key, dashboard.energy) whose parents exist in both configs, so a
# top-level diff reads clean. Exposed as a constant so e2e.sh can run the same filter on the
# bench over SSH; config_key_paths is the local/selftest wrapper.
CONFIG_KEY_PATHS_JQ='[paths | map(tostring) | join(".")] | sort[]'
config_key_paths() { jq -r "$CONFIG_KEY_PATHS_JQ" "$1" 2>/dev/null; }

# One-line sync summary off /api/state for the #914 e2e pre-flight:
# "<monero-state> <current>/<target> <tari-state> <current>/<target>". A constant (not a
# function) because e2e.sh interpolates it into a remote jq call; the selftest pins it
# against the /api/state fixture so the field paths can't drift from the dashboard payload.
# shellcheck disable=SC2034  # consumed by e2e.sh + selftest.sh, which source this file
E2E_SYNC_SUMMARY_JQ='"\(.sync.monero.state) \(.sync.monero.current)/\(.sync.monero.target) \(.sync.tari.state) \(.sync.tari.current)/\(.sync.tari.target)"'

# Restore-proof marker compare (#971): does the value a live container was BAKED with (docker
# inspect .Config.Env) agree with the on-disk .env? Compares whole KEY=VALUE lines and prints a
# verdict word — never a value, so secrets stay out of logs. The incident this pins: an e2e run
# recreated the live containers with harness-rendered creds while the on-disk .env kept the real
# ones — internally consistent, healthy-looking, and every host-side RPC probe 401ed for a day.
#   match         — both carry the same KEY=VALUE line
#   mismatch      — both carry the var, values differ (the incident)
#   no-disk-value — the on-disk .env doesn't set the var (nothing to prove against)
#   not-baked     — the container env doesn't carry the var at all
env_bake_verdict() { # <var> <disk-env-lines> <container-env-lines>
    local disk baked
    disk="$(printf '%s\n' "$2" | grep -m1 "^$1=")"
    baked="$(printf '%s\n' "$3" | grep -m1 "^$1=")"
    if [ -z "$disk" ]; then
        printf 'no-disk-value'
    elif [ -z "$baked" ]; then
        printf 'not-baked'
    elif [ "$baked" = "$disk" ]; then
        printf 'match'
    else
        printf 'mismatch'
    fi
}

# Restore-proof control-channel verdict (#1085): classify `pithead doctor`'s control-channel section
# so "the check RAN and the units are on target" reads differently from "the check never ran".
# Classify the TEXT, never doctor's exit code — it is 1 on ANY failed check, so an unrelated failure
# would swamp this signal and a 0 would read as "units fine" on a pithead that never looked.
#   on-target — the units name the install doctor was run from
#   stranded  — the section is there and reports a fault: units naming another directory, no units
#               at all, or a spool nobody writes to
#   disabled  — the control channel is off for that install. NOT a pass on its own: `apply` leaves
#               the units alone when control is disabled, so a strand SURVIVES the restore in
#               exactly this state. The caller has to look for leftovers itself.
#   not-live  — doctor declined to grade: this directory is a superseded version dir and `current`
#               names another. An explicit "I did not evaluate", graded INFO by doctor and pointing
#               at where to look. Folding it into `stranded` hard-fails a run with a false claim.
#   no-check  — no section at all: no systemd, or a pithead predating the check (v1.19.2)
control_units_verdict() { # <doctor-output>
    case "$1" in
    *"Dashboard control channel:"*) ;;
    *)
        printf 'no-check'
        return
        ;;
    esac
    case "$1" in
    *"Control runner units target this install."*) printf 'on-target' ;;
    *"Disabled for this install"*) printf 'disabled' ;;
    *"This is not the live install"*) printf 'not-live' ;;
    *) printf 'stranded' ;;
    esac
}

# Authoritative "is Monero caught up?" — query monerod's own get_info (creds stay on the box)
# and trust its `synchronized` flag / target_height 0, exactly like the sync gate. "Its own"
# follows the mode: in monero.mode=remote nothing listens on the box's loopback (the render
# emits no MONERO_RPC_URL; the in-stack relay is container-local), so the endpoint derives from
# config.json — found by #1083's first live remote run. Returns 0 when synced.
monero_caught_up() {
    rx 'u=$(grep -E "^MONERO_NODE_USERNAME=" .env 2>/dev/null | cut -d= -f2-);
        p=$(grep -E "^MONERO_NODE_PASSWORD=" .env 2>/dev/null | cut -d= -f2-);
        url=$(grep -E "^MONERO_RPC_URL=" .env 2>/dev/null | cut -d= -f2-); [ -n "$url" ] || url=$(jq -r "if (.monero.mode // \"local\") == \"remote\" and .monero.remote.host then \"http://\" + .monero.remote.host + \":\" + ((.monero.remote.rpc_port // 18081) | tostring) else \"http://127.0.0.1:18081\" end" config.json 2>/dev/null); [ -n "$url" ] || url="http://127.0.0.1:18081";
        if [ -n "$u" ]; then body=$(curl -fsS --max-time 8 --digest -u "$u:$p" "$url/get_info" 2>/dev/null);
        else body=$(curl -fsS --max-time 8 "$url/get_info" 2>/dev/null); fi;
        printf "%s" "$body" | jq -e "(.status==\"OK\") and ((.synchronized==true) or (.target_height==0))" >/dev/null 2>&1'
}

# --- Shared-bench rig lock (#430; canonical helper from rigforge#183) --------
# RigForge's release gates and this harness share bench hardware; a kernel flock on one
# world-known path coordinates them. The lock lives on an open FD, so it dies with its holder
# (kill -9 included — no stale-lock cleanup), shared (read-only) holders coexist but exclude
# exclusive (mutating) ones, and a busy box exits 75 (EX_TEMPFAIL) so wrappers can tell
# "retry later" from a real failure. The helper is copied VERBATIM from rigforge#183 — the
# same lock path on every box IS the protocol; do not fork the two copies. FD 9 is inherited
# by children, which is what keeps the lock held for the whole run — never close it.
# RIG_LOCK_FILE/RIG_LOCK_HOLDER are env-overridable so the tier-1 self-test can sandbox the
# paths (rigforge#183 note 6). run.sh NOW installs an EXIT trap — rig_key_atexit (rig-key-ledger.sh,
# #1379) — folding this rm -f into its body per note 3, since a later `trap … EXIT` replaces rather
# than stacks. That is its ONLY other copy; keep the pair in step. Opened READ-only (9<, #242/#252) so a
# root run can reserve a box whose lock file a prior non-root reserve created — fs.protected_regular
# blocks even root's write-open (9>) of a foreign-owned lock, silently dropping the flock (#249).
rig_lock() { # rig_lock <project> <suite> [shared]
    local mode=-x
    [ "${3:-}" = shared ] && mode=-s
    local lf="${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}"
    # Holder breadcrumb defaults BESIDE the lock, not under root-owned /run (a non-root box can't
    # write /run/rig-e2e.holder — the lock still holds, but the write errors with stderr noise). (#244)
    local hf="${RIG_LOCK_HOLDER:-$lf.holder}"
    # /run/lock is world-writable + sticky; refuse a symlinked lock/holder path so a planted symlink
    # can't redirect our root-side create/chmod/holder-write onto another file (defence for a
    # multi-tenant box; single-tenant rigs aren't exposed, but the guard is free).
    { [ -L "$lf" ] || [ -L "$hf" ]; } && {
        echo "rig_lock: lock/holder path is a symlink — refusing" >&2
        exit 1
    }
    # Open the lock READ-only (9<). A lock file first created by a NON-root flock (a manual reserve
    # after a reboot clears the /run/lock tmpfs) is owned by that user, and fs.protected_regular then
    # blocks even root's O_CREAT-*write* of it (a 9> open) with EACCES. A read-open is never guarded,
    # and flock -x/-s works fine on a read fd, so this sidesteps it without rm-ing a possibly-held
    # lock. Create it first if absent; keep it 0666 so a shared reader can still join. (#242)
    [ -e "$lf" ] || : >"$lf" 2>/dev/null || true
    chmod 666 "$lf" 2>/dev/null || true # best-effort world-writable; a read-open (9<) only needs o+r
    exec 9<"$lf"
    if ! flock -n $mode 9; then
        if [ "${RIG_LOCK_WAIT:-0}" = 1 ]; then
            echo "rig busy ($(cat "$hf" 2>/dev/null || echo unknown)) — waiting..." >&2
            flock $mode 9
        else
            echo "rig busy: $(cat "$hf" 2>/dev/null || echo unknown). Retry with RIG_LOCK_WAIT=1 to queue." >&2
            exit 75 # EX_TEMPFAIL — callers can tell "busy, retry later" from a real failure
        fi
    fi
    # DISPLAY-ONLY and strictly best-effort. The flock is already HELD on FD 9 above; a holder
    # marker we can't write (a root-owned RIG_LOCK_HOLDER + a non-root runner) must NEVER abort
    # under set -e and drop the lock — that would leave the box UNRESERVED, the exact bug (#249).
    # Plain write, then passwordless sudo, then swallow. Portable UTC stamp — the GNU-only
    # `date -Iseconds` errors on BSD/macOS. (#244)
    local _line
    _line="$(printf '%s %s pid=%s started=%s' "$1" "$2" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    { printf '%s\n' "$_line" >"$hf" || printf '%s\n' "$_line" | sudo -n tee "$hf" >/dev/null; } 2>/dev/null || true
    # The trap fires at EXIT when the $hf local is out of scope, so re-derive the path from the
    # durable env/default; best-effort removal, may need sudo for a root-written marker. (#244/#249)
    trap 'rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || sudo -n rm -f "${RIG_LOCK_HOLDER:-${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}.holder}" 2>/dev/null || true' EXIT
}

# Take the rig lock ON a remote box and hold it for the lifetime of THIS process. The remote
# bash receives the verbatim helper over ssh stdin, acquires, answers RIG_LOCK_OK, then blocks
# reading the still-open pipe; local FD 8 keeps that pipe open, so the remote shell — and with
# it the kernel lock — dies the moment this process does, kill -9 included: the same crash
# semantics as holding FD 9 locally, one hop out. Busy propagates as the helper's exit 75; an
# ssh failure propagates as ssh's own exit code. Uses fixed local FD 8 (bash 3.2 has no
# dynamic fds), so: one remote lock per process — enough for run.sh (the target box) and
# e2e.sh (the borrowed loaner rig; its bench lock is taken by the run.sh it launches there).
RIG_LOCK_SSH_PID=""
rig_lock_remote() { # rig_lock_remote <project> <suite> <shared|""> <dest> [ssh opts...]
    local project="$1" suite="$2" shmode="$3" dest="$4"
    shift 4
    local d
    d="$(mktemp -d)" && mkfifo "$d/in" "$d/out" || {
        it_err "rig_lock_remote: cannot create fifos under ${TMPDIR:-/tmp}"
        exit 1
    }
    ssh "$@" "$dest" "RIG_LOCK_WAIT=$(quote_arg "${RIG_LOCK_WAIT:-0}") RIG_LOCK_FILE=$(quote_arg "${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}") RIG_LOCK_HOLDER=$(quote_arg "${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}") bash -s" <"$d/in" >"$d/out" &
    RIG_LOCK_SSH_PID=$!
    exec 8>"$d/in"
    {
        declare -f rig_lock
        printf 'rig_lock %s %s %s && echo RIG_LOCK_OK\n' "$(quote_arg "$project")" "$(quote_arg "$suite")" "$(quote_arg "$shmode")"
    } >&8
    local ack=""
    IFS= read -r ack <"$d/out" || true
    rm -rf "$d" # the open FDs outlive the fifo names
    if [ "$ack" != "RIG_LOCK_OK" ]; then
        # No ack: the remote helper exited 75 (its busy message already reached our stderr
        # via ssh) or ssh itself failed — either way the run must not touch the box.
        local rc
        wait "$RIG_LOCK_SSH_PID" 2>/dev/null
        rc=$?
        [ "$rc" -eq 0 ] && rc=1 # EOF without the ack is never success
        it_err "could not take the rig lock on $dest (exit $rc)"
        exit "$rc"
    fi
}

# --- Readiness waiters ------------------------------------------------------
# Poll a predicate until it succeeds or the timeout elapses. The interval is a *poll* cadence
# against a real readiness signal — not a fixed "sleep and hope" (issue #54). Returns 0 on
# success, 1 on timeout.
now_s() { date +%s; }

wait_for() { # wait_for <timeout_s> <interval_s> <desc> <predicate-cmd...>
    local timeout="$1" interval="$2" desc="$3"
    shift 3
    local deadline=$(($(now_s) + timeout))
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
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.sync.monero.state')" = "done" ]
}

# Predicate: the sync gate has released the miner — at least one worker is online on the proxy.
# (proxy_workers is the reliable signal; stratum.conns can read 0 on a healthy, mining box.)
_pred_miner_running() {
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    local w
    w="$(jq_get "$st" '.proxy_workers')"
    [ -n "$w" ] && [ "$w" -ge 1 ] 2>/dev/null
}

# Predicate: Tari has caught up — its .sync.tari.state reaches "done" once it has a reliable target,
# so the dashboard field is authoritative here (Monero's panel now reaches "done" for a synced node
# too). After
# a restart Tari needs a moment to re-establish peers and close its offline gap, so we poll this
# rather than asserting cold (issue #54: a real readiness signal, not "sleep and hope").
_pred_tari_synced() {
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.sync.tari.state')" = "done" ]
}

# Predicate: p2pool has joined the expected sidechain and the dashboard can classify it. The pool
# type is inferred from connected peers' ports (detect_pool_type: 37889 Main / 37888 Mini / 37890
# Nano), so right after a sidechain switch it reads "Unknown" until enough peers on the NEW chain
# connect — poll until it matches the expected label rather than asserting cold (issue #54).
_pred_pool_ready() { # _pred_pool_ready <expected-label>
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.pool.type')" = "$1" ]
}

# Predicate: hashes are flowing end-to-end (miner → proxy → p2pool stratum). stratum.total_hashes is
# a per-session counter that RESETS to 0 on a p2pool restart, then climbs once the proxy's upstream
# reconnects and the first share lands — so right after an apply (especially a pool switch, where
# p2pool re-syncs its sidechain before serving) it reads 0. It's monotonic within a session, so
# polling until >0 is robust where the instantaneous stratum.conns is not (issue #54).
_pred_hashes_flowing() {
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    local h
    h="$(jq_get "$st" '.stratum.total_hashes')"
    [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null
}

# Predicate: the dashboard's persistence flag (#131) reads exactly <expected> ("true"/"false").
# Parameterized because the db-readonly fault (#202) waits on both edges. db_healthy is a one-way
# latch per process — storage_service only sets it True in __init__ — so the fault choreography in
# run.sh restarts the dashboard around each wait instead of polling for a self-heal that can't
# happen. jq_get preserves boolean false (it doesn't fall through `// empty`), so "false" here
# means the flag really reads false, not that the key is missing.
_pred_db_healthy_is() { # _pred_db_healthy_is <true|false>
    local st
    st="$(api_state)"
    [ -n "$st" ] || return 1
    [ "$(jq_get "$st" '.db_healthy')" = "$1" ]
}

# Predicate: the dashboard's share-health series (#116) has at least one row — proof the poll
# loop is actually CAPTURING per-poll share deltas on a mining box, not just serving the key.
# The series fills as polls land, so right after a dashboard recreate it is legitimately empty —
# poll, don't read cold (issue #54).
_pred_share_stats_nonempty() {
    local st n
    st="$(api_state)"
    [ -n "$st" ] || return 1
    n="$(jq_get "$st" '.share_stats | length')"
    [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null
}

# Predicate: the proxy's stratum counters show hashes accumulating — proof a rig is actually
# submitting work, not merely listed. A REAL borrowed rig fails over to its secondary pool when
# the bench stratum bounces between scenarios and returns on xmrig's own retry clock (~60-90s),
# so a single early sample legitimately reads 0 on a rig that is mining a minute later (#831).
_pred_stratum_hashes() {
    local st h
    st="$(api_state)"
    [ -n "$st" ] || return 1
    h="$(jq_get "$st" '.stratum.total_hashes')"
    [ -n "$h" ] && [ "$h" -gt 0 ] 2>/dev/null
}

wait_status_ok() { wait_for "${1:-180}" 5 "pithead status OK" _pred_status_ok; }
wait_stratum_hashes() { wait_for "${1:-180}" 10 "stratum hashes accumulating" _pred_stratum_hashes; }
wait_monero_synced() { wait_for "${1:-300}" 10 "Monero sync complete" _pred_monero_synced; }
wait_miner_running() { wait_for "${1:-180}" 5 "miner released" _pred_miner_running; }
wait_tari_synced() { wait_for "${1:-300}" 10 "Tari sync complete" _pred_tari_synced; }
wait_pool_ready() { wait_for "${1:-180}" 5 "pool type determinate (${2})" _pred_pool_ready "$2"; }

# Ground truth for the sidechain axis (#746): the rendered P2POOL_FLAGS in the box's .env carry
# --mini / --nano (main carries neither). The dashboard classifies the sidechain by counting
# connected peers' ports, so right after a pool SWITCH p2pool runs the NEW flags while the
# classifier can still report the OLD sidechain until enough new-chain peers connect over Tor —
# determinate, wrong, and transient. The flags tell a real render bug apart from that lag.
pool_flags_correct() { # <expected-pool-label: Main|Mini|Nano>
    local flags
    flags="$(rx "grep -E '^P2POOL_FLAGS=' .env 2>/dev/null | head -n1 | cut -d= -f2-")"
    case "$1" in
    Mini) [[ "$flags" == *"--mini"* ]] ;;
    Nano) [[ "$flags" == *"--nano"* ]] ;;
    *) [[ "$flags" != *"--mini"* && "$flags" != *"--nano"* ]] ;;
    esac
}

# Shared pool-type verdict (#454/#687/#746), used by assert_scenario and assert_pool_switched:
# determinate match → pass; Unknown/empty → peer-timing WARN (nano/Tor is slow to populate);
# determinate-but-wrong with CORRECT P2POOL_FLAGS → classifier-lag WARN (#746, the post-switch
# stale read); wrong type AND wrong flags → a real config/render bug → FAIL. The mismatch path
# now checks the actual flags, so this is a stronger check than the old hard-fail, not a looser one.
assert_pool_type() { # <label> <got> <want>
    if [ "$2" = "$3" ]; then
        it_pass "$1 ($2)"
    elif [ "$2" = "Unknown" ] || [ -z "$2" ]; then
        it_warn "$1 — pool still Unknown for [$3]; peers not classified in time (nano/Tor is slow to populate), not a misclassification (#454)"
    elif pool_flags_correct "$3"; then
        it_warn "$1 — classifier still reads [$2] for [$3] but P2POOL_FLAGS carry the right sidechain; pre-switch peers not re-classified in time (#746), not a render bug"
    else
        it_fail "$1" "got [$2], want [$3] and P2POOL_FLAGS disagree — wrong sidechain rendered"
    fi
}

# Assert a pool switch settled, WITHOUT flaking red on peer luck (#687/#746). The 420s window is
# Tor-realistic; the wait polls, so a fast bench that classifies in seconds pays nothing.
assert_pool_switched() { # <label> <expected-pool-label>
    wait_pool_ready 420 "$2" || true
    assert_pool_type "$1" "$(jq_get "$(api_state)" '.pool.type')" "$2"
}

# Tari sync verdict for tari_required scenarios (#746). Every per-scenario restart sends Tari back
# through "discovering the target height" ('loading' = no target yet), and over Tor that
# re-discovery can outlast wait_tari_synced's window — an in-progress state, not a sync failure.
# But lag tolerance must not mask a Tari that NEVER syncs, so it is earned: "done" passes and
# records the proof (TARI_SEEN_DONE); loading/syncing AFTER that proof warns; anything else — or an
# in-progress state on the first look — fails the gate.
assert_tari_synced_required() { # <state>
    if [ "$1" = "done" ]; then
        TARI_SEEN_DONE=1
        it_pass "tari synced (required)"
    elif [ "${TARI_SEEN_DONE:-0}" = "1" ] && { [ "$1" = "loading" ] || [ "$1" = "syncing" ]; }; then
        it_warn "tari sync reads [$1] after the restart — Tari proved synced earlier this run; post-restart target re-discovery lag over Tor (#746), not a sync failure"
    else
        it_fail "tari synced (required)" "expected [done], got [$1]"
    fi
}
wait_hashes_flowing() { wait_for "${1:-300}" 5 "stratum hashes flowing" _pred_hashes_flowing; }

# --- Artifact capture -------------------------------------------------------
# On a scenario failure, collect everything needed to debug it — redacted. Writes into
# <outdir>/<scenario>/. Best-effort: never let capture failures mask the test result.
capture_artifacts() {
    local scenario="$1" outdir="$2"
    local dir="${outdir}/${scenario}"
    mkdir -p "$dir"
    it_step "capturing artifacts to ${dir}"
    rx "docker compose ps" 2>&1 | redact >"${dir}/compose-ps.txt" || true
    rx "$IT_PITHEAD status" 2>&1 | redact >"${dir}/status.txt" || true
    rx "$IT_PITHEAD doctor" 2>&1 | redact >"${dir}/doctor.txt" || true
    rx "cat config.json" 2>&1 | redact >"${dir}/config.json" || true
    rx "cat .env" 2>&1 | redact >"${dir}/env.redacted.txt" || true
    api_state | redact >"${dir}/api-state.json" || true
    # Last 200 lines of each service's logs, redacted.
    rx "docker compose logs --tail=200 --no-color" 2>&1 | redact >"${dir}/logs.txt" || true
}
