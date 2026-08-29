# shellcheck shell=bash
#
# rotate-secrets lock wiring (#1482): the rotate-secrets verb takes the mutation lock, and takes it
# in the one place that is correct. Sourced by tests/stack/run.sh.
#
# SCOPE, stated so this is not read as duplicating its two neighbours. test-lifecycle.sh proves the
# lock MECHANISM — the holder record, the announced wait, the refusal, the rc, the release — driven
# through `stack_down`, and says nothing about which verbs are wired to it. test-secrets.sh proves
# what rotate-secrets DOES — the three credentials it regenerates, what it skips, the safety copies,
# the failure path — and says nothing about mutual exclusion. What is asserted here is WIRING and
# PLACEMENT for this one verb, and nothing about how the lock itself behaves. The rc assertions are
# the cheapest proof that the verb reaches mutation_lock_acquire at all, not a second opinion on the
# exit status.
#
# PLACEMENT is the half a plain "does it take the lock" test would miss, and it is pinned from both
# sides. Before the first mutation: on a held machine the verb must leave config.json's stored RPC
# password, the rendered .env, and the containers exactly as it found them, and must write no
# pre-rotation safety copies — because the refusal tells the operator nothing was changed and that
# has to be literally true. Note that the safety copies, not the credential rewrite, are this verb's
# first write to disk, so they are the assertion that actually pins the acquire's lower bound. After
# the confirmation: a declined rotate on a held machine must come back on the ANSWER, not sit in the
# lock wait — the hold must never span a human wait. Move the acquire past the safety copies and the
# first group fails; move it above the prompt and the second does.
#
# Every contended case runs against a POSITIVE CONTROL that the same fixture, uncontended, really
# does perform the mutation being looked for. Without that, "the token is unchanged" is equally
# consistent with a fixture that never armed — and the two read identically.
#
# This lives beside test-secrets.sh rather than inside it because tests/stack ceilings only go down
# and that file sits at its own (401), and the sibling-file shape is the one #1514/#1528 established
# for the other halves of #1482.
#
# Re-derivations: $SANDBOX, $STACK, $ROOT, $VALID_PRIMARY, $VALID_TARI, make_stubs, run_sourced, bad
# and the assert_* helpers come from lib.sh. Every other name is assigned here, under an RS/rs_
# prefix, because this file and its neighbours are sourced into ONE shell — $V (build_val_sandbox's
# shared sandbox) is deliberately NOT reused: the contended cases assert on the ABSENCE of
# config.json.bak-* files, which would otherwise depend on another domain file's cleanup.
#
# The seeding `apply` below always runs against the FREE lock file, never the held one: `apply` takes
# the window itself, so seeding through a held lock would block rather than set the fixture up.

: "${SANDBOX:?}"
: "${STACK:?}"
: "${ROOT:?}"

RS="$SANDBOX/rotate-lock"
mkdir -p "$RS/build/tari" "$RS/dashboard" "$RS/data/monero" "$RS/data/tari" "$RS/data/p2pool/stats" "$RS/data/tor" "$RS/data/dashboard"
: >"$RS/dashboard/Dockerfile"
cp "$STACK" "$RS/pithead"
make_stubs "$RS/bin"
cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"

RSFREE="$SANDBOX/rotate-lock-free.lock" # never held: the seeding applies and the positive controls run through it
RSHELD="$SANDBOX/rotate-lock-held.lock" # held by rs_hold for the contended cases
RSDOCKER="$RS/docker.log"

rs_seed() { # a deployed local-mode box with stratum auth on "auto": re-armed before EVERY run
    cat >"$RS/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"seedrpcpass"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' \
        "$VALID_PRIMARY" "$VALID_TARI" >"$RS/config.json"
    (cd "$RS" && DOCKER_LOG=/dev/null PATH="$RS/bin:$PATH" PITHEAD_LOCK_FILE="$RSFREE" ./pithead apply -y) >/dev/null 2>&1
    rm -f "$RS"/config.json.bak-* "$RS"/.env.bak-* "$RS/.env.apply-incomplete"
    : >"$RSDOCKER"
}

rs_run() { # <lock file> <extra env pairs...> -- <verb args...>
    local lk="$1" env_pairs=()
    shift
    while [ "$1" != "--" ]; do
        env_pairs+=("$1")
        shift
    done
    shift
    (cd "$RS" && PATH="$RS/bin:$PATH" DOCKER_LOG="$RSDOCKER" \
        PITHEAD_LOCK_FILE="$lk" env "${env_pairs[@]}" ./pithead "$@" 2>&1)
}

rs_baks() { # how many pre-rotation safety copies are on disk
    find "$RS" -maxdepth 1 -name 'config.json.bak-*' -o -maxdepth 1 -name '.env.bak-*' | wc -l | tr -d ' '
}

# Sets RSHOLDER rather than echoing it: `$(...)` around a function that backgrounds a long-lived
# holder blocks the substitution for that holder's whole lifetime. `exec sleep` rather than a plain
# one so the holder is a single killable process owning the descriptor.
RSHOLDER=""
rs_hold() { # <lock file> -> sets RSHOLDER
    local lk="$1" i=0
    : >"$lk"
    (
        exec 9>>"$lk"
        flock -w 20 9 || exit 1
        exec sleep 120
    ) >/dev/null 2>&1 &
    RSHOLDER=$!
    while [ "$i" -lt 200 ]; do
        flock -n "$lk" true 2>/dev/null || break
        sleep 0.05
        i=$((i + 1))
    done
    if flock -n "$lk" true 2>/dev/null; then
        bad "the holder takes the lock window" "the lock is still free — every contended case below would prove nothing"
    fi
}

echo "== black-box: the fixture arms — uncontended, rotate-secrets performs its mutations (#1482) =="
# Read every assertion here as the control for its contended twin further down. Each one names a
# change that must NOT happen once the machine is held.
rs_seed
rs_out=$(rs_run "$RSFREE" -- rotate-secrets -y)
rs_rc=$?
assert_rc "uncontended rotate-secrets succeeds" "$rs_rc" "0"
assert_eq "uncontended rotate-secrets really rewrites the RPC password in config.json" \
    "$([ "$(jq -r '.monero.node_password' "$RS/config.json")" != "seedrpcpass" ] && echo changed)" "changed"
assert_eq "uncontended rotate-secrets really rewrites the proxy token in .env" \
    "$([ "$(run_sourced "$RS" env_get_file "$RS/.env" PROXY_AUTH_TOKEN)" != "ORIGINALTOKEN" ] && echo changed)" "changed"
assert_eq "uncontended rotate-secrets really writes both pre-rotation safety copies" "$(rs_baks)" "2"
assert_contains "uncontended rotate-secrets really recreates the containers" "$(cat "$RSDOCKER")" "compose up"

echo "== black-box: a held machine refuses rotate-secrets and changes nothing (#1482) =="
rs_hold "$RSHELD"

rs_seed
rs_out=$(rs_run "$RSHELD" PITHEAD_LOCK_TIMEOUT=1 -- rotate-secrets -y)
rs_rc=$?
assert_rc "contended rotate-secrets refuses rather than interleaving with the held window" "$rs_rc" "75"
assert_contains "contended rotate-secrets tells the operator which verb to re-run" "$rs_out" "rotate-secrets' once it has finished"
assert_eq "contended rotate-secrets KEEPS the stored RPC password" "$(jq -r '.monero.node_password' "$RS/config.json")" "seedrpcpass"
assert_eq "contended rotate-secrets KEEPS the rendered proxy token" "$(run_sourced "$RS" env_get_file "$RS/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
# The safety copies are this verb's FIRST write to disk, so their absence is what pins the acquire
# above them rather than merely above the credential rewrite.
assert_eq "contended rotate-secrets writes no pre-rotation safety copy" "$(rs_baks)" "0"
assert_eq "contended rotate-secrets recreates no container" "$(grep -c 'compose up' "$RSDOCKER" || true)" "0"
assert_eq "contended rotate-secrets leaves no retry marker" "$([ -f "$RS/.env.apply-incomplete" ] || echo none)" "none"

echo "== black-box: the rotate window opens AFTER the confirmation, so no hold spans a human wait (#1482) =="
# The other side of the placement. The verb is declined while the machine is held: it must come back
# on the ANSWER, having never entered the lock wait. If the acquire were moved above the prompt this
# would time out instead — and an operator answering "no" would have been made to wait for a window
# the verb was about to decline to use.
rs_seed
rs_out=$(printf 'n\n' | rs_run "$RSHELD" PITHEAD_LOCK_TIMEOUT=1 -- rotate-secrets)
assert_contains "rotate-secrets declined on a held machine reports the decline" "$rs_out" "Rotation cancelled"
assert_not_contains "rotate-secrets never waited for the window it was not going to use" "$rs_out" "Timed out"
# Not implied by the two rows above: they say the decline was REACHED, this says the decline path
# reached it without having written anything. It is the row M5 kills — the safety copies moved above
# the confirmation — which is the one edit that would make the acquire's placement wrong without
# moving the acquire at all.
assert_eq "rotate-secrets declined on a held machine writes no safety copy either" "$(rs_baks)" "0"

kill "$RSHOLDER" 2>/dev/null || true
wait "$RSHOLDER" 2>/dev/null || true
