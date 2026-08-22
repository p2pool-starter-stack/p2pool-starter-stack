# shellcheck shell=bash
#
# Shared test harness for tests/stack/run.sh (#1105 Phase 1, first extraction).
#
# The assertion/reporting primitives, the pass/fail counters, and the common fixtures every
# test group in run.sh builds on. This file is *sourced*, never executed on its own — it has
# no shebang and is not marked executable, matching tests/integration/lib.sh's convention.
#
# Mechanical move only: this is the SAME code that used to sit at the top of run.sh, moved
# here verbatim so run.sh can source it. No behaviour changed.

# shellcheck disable=SC2034  # sourced library: fixture constants are consumed by run.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/pithead"
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  \033[1;32m✓\033[0m %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"
}

assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac }
assert_rc() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

# Run a command with pithead sourced (functions available, no cd/main side effects),
# from a given working directory. Usage: run_sourced <dir> <cmd> [args...]
# shellcheck disable=SC1090  # STACK path is dynamic by design
run_sourced() {
    local dir="$1"
    shift
    (
        cd "$dir" || return
        source "$STACK"
        set +e
        "$@"
    )
}

# A throwaway sandbox dir, cleaned on exit. Physical path (#695): pithead canonicalizes its
# own directory with pwd -P, so a sandbox spelled through a symlink (macOS /var -> /private/var)
# would render .env paths that no longer string-match the $SANDBOX-based assertions.
SANDBOX="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake docker that records calls and answers the few queries setup/apply make.
make_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose version"|"info") exit 0 ;;
  "exec tor test -f "*) exit 0 ;;
  "exec tor cat /var/lib/tor/monero/hostname") echo "mona.onion" ;;
  "exec tor cat /var/lib/tor/tari/hostname")   echo "taria.onion" ;;
  "exec tor cat /var/lib/tor/p2pool/hostname") echo "p2pa.onion" ;;
  "exec p2pool cat /proc/1/cmdline") printf '%s' "${P2POOL_PROC1:-}" ;;  # #273: tests set the running p2pool argv
  *hash-password*)
    # Fake `caddy hash-password` (#8): a per-password digest so enable/change paths differ, and it
    # never echoes the plaintext back (real bcrypt doesn't either) — keeps the leak checks honest.
    _pw="${*##*--plaintext }"
    _d="$(printf '%s' "$_pw" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-22)"
    printf '$2y$14$%s\n' "$_d" ;;
esac
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/sudo"
    chmod +x "$bin/docker" "$bin/sudo"
}

# --- shared test fixtures hoisted from run.sh (#1105 Phase 1, module 1b), verbatim ---------
# Two gates in one verdict. Shape (network-byte prefix + length): primary 4…/95 (the only payable
# kind), integrated 4…/106, subaddress 8…/95. Then base58-check: block-wise decode + the 4-byte
# legacy-Keccak checksum — a well-shaped address with one mistyped character crashes p2pool at
# startup, so "checksum" is its own verdict with its own operator message.
#
# Checksum-VALID fixtures are well-known PUBLIC addresses (never ours): XMRig's donation address
# (primary) and the Monero project's donation address (subaddress). The integrated fixture is the
# XMRig donation keys re-tagged with a zero payment id and a recomputed checksum — no public
# project publishes a stable integrated donation address. The checksum-INVALID primary is the KVM
# harness wallet that slipped the shape-only gate and crash-looped a provisioned appliance.
VALID_PRIMARY="48edfHu7V9Z84YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBGUicoD"
VALID_SUBADDR="888tNkZrPN6JsEgekjMnABU4TBzc2Dt29EPAvkRxbANsAnjyPbb3iQ1YBRk1UXcdRsiKc9dhwMVgN5S9cQUiyoogDavup3H"
VALID_INTEGRATED="4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijGDpDGTWtLM516v46mB"

# The Tari sibling of the gate above. Both Tari forms (base58 and emoji) carry a 1-byte DammSum
# checksum; the decode and check order mirror tari's own from_bytes. The checksum-VALID fixture
# is the dual mainnet address hardcoded in tari's OWN test suite (test_serialize_deserialize_
# dual_address: one-sided, known view/spend keys) — reference-blessed, never ours. The emoji
# fixture is that same address's byte-for-byte emoji form; the single-address fixture reuses the
# reference spend key with a recomputed checksum (no project publishes a single-form address).
# The invalid emoji strings are ALSO tari's own test vectors (invalid_emoji / invalid_checksum).
VALID_TARI="126J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5BJ"
VALID_TARI_EMOJI="🐢📟🍼🌈🍓🚓➕🎸🍆🍷🎣🍗📿😂🥊⏰🍯👾🤔👒🍾👀🍼🌊🎷📟😈🚨👙🍈🌈🛵🤢🍔🔋👙🚽🤑🎽🎓🎓🐀🐜🐴🥄🚿📷💰👶👍🎉🍄🎢🔌🐋🚰🚑💅👢🦂🐬🐋🍗🍸🎹🏀🍄"
VALID_TARI_SINGLE="1224yPceFvbksLKQ8JE6APDzVY2D6P3SpXwB5LLC3BH4F7oF"

# Order-of-two-ops extractor for the firewall-before-compose regressions (#291).
fw_then_compose() { printf '%s\n' "$1" | grep -xE 'firewall|compose' | tr '\n' ','; }

write_fake_docker() { # <bin-dir> — the containerized verifier's stand-in (#1072)
    mkdir -p "$1"
    cat >"$1/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info | pull) exit 0 ;;
image) exit 0 ;; # `image inspect` -> pinned verifier already local, nothing pulled
run)
    shift
    # Drop the run flags up to and including the pinned verifier image; what remains is the cosign
    # argv the caller actually asked for.
    while [ "$#" -gt 0 ]; do
        case "$1" in
        *sigstore/cosign*)
            shift
            break
            ;;
        *) shift ;;
        esac
    done
    echo "[cosign] $*" >>"${COSIGN_LOG:-/dev/null}"
    exit "${COSIGN_RC:-0}"
    ;;
esac
exit 0
EOF
    chmod +x "$1/docker"
}
write_unreachable_docker() { # <bin-dir> — docker present, daemon down: the "cannot verify" branch.
    # Probing the daemon rather than unsetting PATH keeps this deterministic on hosts that ship
    # /usr/bin/docker, which the pinned PATHs below deliberately still expose.
    mkdir -p "$1"
    printf '#!/usr/bin/env bash\n[ "$1" = "info" ] && exit 1\nexit 0\n' >"$1/docker"
    chmod +x "$1/docker"
}

# config.json, proving the mode at creation, not just the end state.
# GNU form first: `stat -c` errors cleanly on BSD/macOS, so the `||` fallback fires there. The
# reverse order is wrong — on Linux `stat -f` is a VALID flag (filesystem status) that succeeds
# with the wrong output, so the fallback never runs and CI (Linux) reads garbage.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
file_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }

# The config-validation/black-box sandbox: builds $V, defines seed_env and the reference
# $WALLET. Body is the verbatim block run.sh built inline (indentation left untouched so the
# seed_env heredoc keeps its column-0 terminator).
build_val_sandbox() {
    V="$SANDBOX/val"
    mkdir -p "$V/build/tari" "$V/build/dashboard"
    : >"$V/build/dashboard/Dockerfile"
    cp "$STACK" "$V/pithead"
    make_stubs "$V/bin"
    cp "$ROOT/build/tari/config.toml.template" "$V/build/tari/"
    mkdir -p "$V/data/monero" "$V/data/tari" "$V/data/p2pool" "$V/data/tor" "$V/data/dashboard" "$V/data/p2pool/stats"
    seed_env() {
        cat >"$V/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
    }
    WALLET="$VALID_PRIMARY" # checksum-valid mainnet primary (the XMRig donation address) — #250 gates the type, #829 the checksum
}

# The control-channel sandbox: builds $C, defines CTRL_LOG, seed_control_env, control_config.
build_control_sandbox() {
    C="$SANDBOX/control"
    mkdir -p "$C/build/tari" "$C/build/dashboard" \
        "$C/data/monero" "$C/data/tari" "$C/data/p2pool/stats" "$C/data/tor" "$C/data/dashboard"
    : >"$C/build/dashboard/Dockerfile"
    cp "$STACK" "$C/pithead"
    # The control gate reads config.reference.json (the closed schema) from beside the script; it ships
    # in the bundle + checkout root, so mirror it into the sandbox.
    cp "$ROOT/config.reference.json" "$C/config.reference.json"
    make_stubs "$C/bin"
    cp "$ROOT/build/tari/config.toml.template" "$C/build/tari/"
    # The password hash step reads the pinned Caddy image out of docker-compose.yml (#8).
    cp "$ROOT/docker-compose.yml" "$C/docker-compose.yml"
    CTRL_LOG="$C/docker.log"
    seed_control_env() {
        cat >"$C/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
    }
    control_config() { # <pool> [extra dashboard keys...] -> writes $C/config.json
        printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
              "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"%s"},
              "dashboard":{"secure":true,"host":"box.lan",
                           "auth":{"username":"admin","password":"a control passphrase"},
                           "control":{"enabled":true}} }\n' "$WALLET" "$1" >"$C/config.json"
    }
}

run_pending() { (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending 2>&1); }

# A small helper so tests can drive the whole Q&A -> write in one sourced call, sharing the globals
# wizard_ask_core/wizard_ask_shape set with wizard_write_config (each function's locals don't
# survive a return, so they must run in the same invocation).
run_wizard() {
    wizard_ask_core
    wizard_ask_shape
    wizard_write_config
}
