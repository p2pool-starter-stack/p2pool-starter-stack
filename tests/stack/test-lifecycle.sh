# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Lifecycle & data domain (#1105 Phase 1, develop-v2 lane): the stack's recovery paths, scoped
# restarts, and filesystem ownership discipline — `restart`'s whole-stack vs. tor-only vs.
# monerod-only scoping (#424/#972), the mkdir-before-chown ordering that keeps
# prepare_directories/reset_dashboard from EACCES-ing a non-default operator uid (#550),
# ensure_owner's conditional whole-tree recursive chown (#255), `up` staying "everything but the
# chain" under an appliance migration hold (#851) plus the Healthchecks.io ping-URL render (#79),
# `upgrade` re-rendering stale generated config while preserving secrets (#128), `apply` recovering
# from a failed `compose up` with a retry marker instead of a silent no-op (#125), `up` warning
# about relocated/missing data dirs instead of silently starting a fresh resync (#126), and
# `apply`'s no-change branch still converging the control-runner units so doctor's own prescribed
# fix ("run pithead apply") is never a no-op (#33).
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; the "config validation" black-box calls it once,
#   ahead of the migration-hold/upgrade/apply-recovery sections below that read them — that section lives
#   in tests/stack/test-config.sh, whose stanza run.sh sources before this file (a generic multi-field
#   validator, not a lifecycle concern). build_val_sandbox() is idempotent (a fixed $SANDBOX/val path,
#   mkdir -p, template copies), so calling it again here is a safe no-op re-affirm as currently sourced.
# - $DOCKER_LOG: the "apply preserves secrets + propagates" black-box sets it ($V/docker.log); it lives in
#   test-secrets.sh, sourced ahead of this file (a generic multi-key regression, not a lifecycle concern).
# - Everything else below (restart, the two ownership sections, upgrade re-render, apply-recovery,
#   up's relocated-dir warning, and the control-units convergence check) builds its own throwaway
#   dir under $SANDBOX (or runs a fully stubbed subshell against $SANDBOX directly) and needs no
#   re-derivation at all — none of it reads or writes the shared $C control sandbox, so none of it
#   carries the results-dir-pollution risk the rig-worker cut's token-mask pair hit.
build_val_sandbox
DOCKER_LOG="$V/docker.log"

echo "== unit: stack_restart — scoped tor restart (#424) =="
# `restart` bare restarts the whole stack; `restart tor` restarts ONLY tor (fresh guard
# selection when clearnet egress is stuck); anything else is rejected — other containers must
# go through apply/upgrade so a recreate applies current args (#273).
RSTBIN="$SANDBOX/rstbin"
make_stubs "$RSTBIN"
RSTLOG="$SANDBOX/restart-docker.log"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart 2>&1)"
assert_contains "bare restart restarts the whole stack" "$(cat "$RSTLOG")" "compose restart"
assert_not_contains "bare restart is not tor-scoped" "$(cat "$RSTLOG")" "compose restart tor"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart tor 2>&1)"
assert_contains "restart tor restarts only the tor container" "$(cat "$RSTLOG")" "compose restart tor"
assert_contains "restart tor warns that circuits drop" "$out" "circuits drop"
assert_contains "restart tor points at the doctor verify" "$out" "doctor"
: >"$RSTLOG"
# `restart monerod` (#972): the manual re-peer leg after a tor restart left the node out of sync.
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart monerod 2>&1)"
assert_contains "restart monerod restarts only the monerod container" "$(cat "$RSTLOG")" "compose restart monerod"
assert_contains "restart monerod says why (re-dial peers)" "$out" "re-dials"
: >"$RSTLOG"
out="$(DOCKER_LOG="$RSTLOG" PATH="$RSTBIN:$PATH" run_sourced "$SANDBOX" stack_restart p2pool 2>&1)"
rc=$?
assert_rc "restart rejects any service but tor/monerod" "$rc" "1"
assert_contains "restart rejection names the contract" "$out" "takes no argument, 'tor'"
assert_eq "rejected restart touches no container" "$(cat "$RSTLOG")" ""

echo "== regression: mkdir runs before chown -R of the same tree (#550) =="
# prepare_directories and reset_dashboard used to `sudo chown -R` a data dir tree and only THEN
# `mkdir -p` inside it (the p2pool stats subdir) — EACCES for any operator uid != APP_UID, since
# the tree no longer belongs to them. ensure_directories already got this right (mkdir first,
# ensure_owner/chown last); pin the other two to the same order. Shadow sudo/mkdir to log just the
# two ops that matter, in call order — same technique as fw_then_compose above.
mkdir_before_chown() { printf '%s\n' "$1" | grep -xE 'mkdir-stats|chown-p2pool' | tr '\n' ','; }

pd_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034  # read by the sourced prepare_directories, unseen here
    MONERO_DIR="$SANDBOX/pd-monero"
    # shellcheck disable=SC2034
    TARI_DIR="$SANDBOX/pd-tari"
    P2POOL_DIR="$SANDBOX/pd-p2pool"
    # shellcheck disable=SC2034  # read by the sourced prepare_directories, unseen here
    TOR_DATA_DIR="$SANDBOX/pd-tor"
    # shellcheck disable=SC2034  # read by the sourced prepare_directories, unseen here
    DASHBOARD_DIR="$SANDBOX/pd-dashboard"
    # shellcheck disable=SC2034
    CLEARNET_STATE_DIR="$SANDBOX/pd-clearnet"
    # shellcheck disable=SC2034
    PROXY_TLS_DIR="$SANDBOX/pd-proxy-tls" # #261: prepare_directories now creates it too
    log() { :; }
    prepare_control_dirs() { :; }
    mkdir() {
        [[ "$*" == *"$P2POOL_DIR/stats"* ]] && echo mkdir-stats
        return 0
    }
    sudo() {
        [[ "$*" == *"chown -R"*"$P2POOL_DIR"* ]] && echo chown-p2pool
        return 0
    }
    prepare_directories
)
assert_eq "prepare_directories: mkdir p2pool/stats precedes chown -R of P2POOL_DIR" \
    "$(mkdir_before_chown "$pd_order")" "mkdir-stats,chown-p2pool,"

rd2_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    env_get() { echo "/nonexistent/rd2-$1"; } # non-existent dirs -> the destructive rm is skipped
    assert_safe_dir() { :; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    mkdir() {
        [[ "$*" == *"/nonexistent/rd2-P2POOL_DATA_DIR/stats"* ]] && echo mkdir-stats
        return 0
    }
    sudo() {
        [[ "$*" == *"chown -R"*"/nonexistent/rd2-P2POOL_DATA_DIR"* ]] && echo chown-p2pool
        return 0
    }
    reset_dashboard -y
)
assert_eq "reset-dashboard: mkdir p2pool/stats precedes chown -R of p2pool_dir" \
    "$(mkdir_before_chown "$rd2_order")" "mkdir-stats,chown-p2pool,"

echo "== unit: ensure_owner conditional recursive chown (#255) =="
# ensure_owner migrates a data tree to the container's uid ONLY when something in it is foreign-owned,
# and scans the WHOLE tree (not just the top dir) — an install upgraded from the root-container era has
# a user-owned dir but root-owned *contents*, and those are what the non-root container can't overwrite.
# MEMORY flags "must scan contents not just dir" as a past bug, so we guard both the decision and that
# the find scan is recursive (no -maxdepth). sudo is stubbed to record what it would chown.
EO="$SANDBOX/eo"
mkdir -p "$EO/bin" "$EO/tree/sub"
: >"$EO/tree/sub/file"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/sudo.log"\n' "$EO" >"$EO/bin/sudo"
chmod +x "$EO/bin/sudo"
myuid="$(id -u)"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" "$myuid" "$myuid" >/dev/null 2>&1
assert_rc "clean tree (already owned) stays sudo-free" "$?" "0"
assert_eq "clean tree triggers no chown" "$(grep -c chown "$EO/sudo.log")" "0"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" 424242 424242 >/dev/null 2>&1
assert_contains "foreign ownership triggers a recursive chown" "$(cat "$EO/sudo.log")" "chown -R 424242:424242 $EO/tree"
: >"$EO/sudo.log"
PATH="$EO/bin:$PATH" run_sourced "$EO" ensure_owner "$EO/nonexistent" "$myuid" "$myuid" >/dev/null 2>&1
assert_rc "missing dir is a no-op" "$?" "0"
assert_eq "missing dir triggers no chown" "$(grep -c chown "$EO/sudo.log")" "0"
# Regression guard for #255: the ownership scan must be whole-tree. Stub `find` to capture its args and
# assert ensure_owner never passes -maxdepth (which would re-introduce the top-dir-only bug).
mkdir -p "$EO/findbin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/find.log"\n' "$EO" >"$EO/findbin/find"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EO/findbin/sudo"
chmod +x "$EO/findbin/find" "$EO/findbin/sudo"
: >"$EO/find.log"
PATH="$EO/findbin:$PATH" run_sourced "$EO" ensure_owner "$EO/tree" "$myuid" "$myuid" >/dev/null 2>&1
assert_not_contains "the ownership scan is recursive (no -maxdepth)" "$(cat "$EO/find.log")" "-maxdepth"
assert_contains "the ownership scan keys off foreign uid" "$(cat "$EO/find.log")" "! -uid $myuid"

echo "== black-box: 'pithead up' under the migration hold starts everything but the chain (#851) =="
# PITHEAD_HOLD_CHAIN=1 is set by the appliance boot path on the first boot of a data_migration
# bundle: the chain services (the lmdb holders) must not start before the A/B slot commits. The
# compose service list comes from a dedicated stub because the shared one answers nothing for
# `compose config --services`, and stack_status's tests rely on exactly that.
HCB="$SANDBOX/hold-chain-bin"
mkdir -p "$HCB"
cat >"$HCB/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose config --services") printf 'tor\nmonerod\ntari\nwallet-rpc\ntari-wallet\np2pool\nxmrig-proxy\ncaddy\ndashboard\n' ;;
esac
exit 0
EOF
chmod +x "$HCB/docker"
HOLD_LOG=$(mktemp)
seed_env
out="$(cd "$V" && DOCKER_LOG="$HOLD_LOG" PATH="$HCB:$V/bin:$PATH" PITHEAD_HOLD_CHAIN=1 ./pithead up 2>&1)"
assert_rc "up succeeds under the hold" "$?" "0"
assert_contains "the hold is announced for the journal" "$out" "holding chain services"
up_line=$(grep "compose up" "$HOLD_LOG" | tail -1)
assert_contains "tor still starts under the hold" "$up_line" "tor"
assert_contains "p2pool still starts under the hold" "$up_line" "p2pool"
assert_contains "the dashboard still starts under the hold" "$up_line" "dashboard"
assert_not_contains "monerod is withheld" "$up_line" "monerod"
assert_not_contains "tari and tari-wallet are withheld" "$up_line" "tari"
assert_not_contains "wallet-rpc is withheld" "$up_line" "wallet-rpc"
# Without the env the same sandbox starts the whole stack — the hold is opt-in per boot.
HOLD_LOG2=$(mktemp)
(cd "$V" && DOCKER_LOG="$HOLD_LOG2" PATH="$HCB:$V/bin:$PATH" ./pithead up >/dev/null 2>&1)
up_line2=$(grep "compose up" "$HOLD_LOG2" | tail -1)
assert_not_contains "a plain up names no service subset" "$up_line2" "p2pool"
rm -f "$HOLD_LOG" "$HOLD_LOG2"

# Healthchecks.io (#79): absent => no ping URL (off).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks off by default (no ping URL)" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" ""

# A ping URL propagates verbatim to .env (the URL is the on switch; Tor is always used).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "healthchecks":{"ping_url":"https://hc-ping.com/abc"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks ping_url propagated" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" "https://hc-ping.com/abc"

echo "== black-box: upgrade re-renders generated config (#128) =="
# `upgrade` used to be just `up --build`, leaving the generated .env/Caddyfile/Tari config stale
# after a git pull. It must now re-render them while preserving secrets.
U="$SANDBOX/upgrade"
mkdir -p "$U/build/tari" "$U/dashboard" "$U/data/monero" "$U/data/tari" "$U/data/p2pool/stats" "$U/data/tor" "$U/data/dashboard"
: >"$U/dashboard/Dockerfile"
cp "$STACK" "$U/pithead"
make_stubs "$U/bin"
cp "$ROOT/build/tari/config.toml.template" "$U/build/tari/"
# Stale .env: secrets present, but STRATUM_BIND (a rendered var) is missing — the upgrade must fill it.
cat >"$U/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$U/config.json"
UL="$U/docker.log"
: >"$UL"
out="$(cd "$U" && DOCKER_LOG="$UL" PATH="$U/bin:$PATH" ./pithead upgrade 2>&1)"
rc=$?
assert_rc "upgrade exits 0" "$rc" "0"
assert_eq "upgrade re-renders a missing var (STRATUM_BIND)" "$(run_sourced "$U" env_get_file "$U/.env" STRATUM_BIND)" "0.0.0.0"
assert_eq "upgrade preserves the proxy token" "$(run_sourced "$U" env_get_file "$U/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
# render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and load_preserved_state
# doesn't carry it, so upgrade must re-assert it — else the flag flips to false and the NEXT
# require_deployed command (up/apply/upgrade) errors "run setup" on an already-deployed box.
assert_eq "upgrade preserves DEPLOYMENT_COMPLETED (require_deployed survives)" "$(run_sourced "$U" env_get_file "$U/.env" DEPLOYMENT_COMPLETED)" "true"
assert_contains "upgrade still rebuilds images (source mode)" "$(cat "$UL")" "compose up --pull never -d --build"
# Third-party images (caddy/tari/socket-proxies) are digest-pinned and can change between releases;
# a source-mode upgrade pulls the non-buildable ones first so a bumped digest is fetched (not "No
# such image" under --pull never). Best-effort, so it runs before the build.
assert_contains "upgrade pulls non-buildable images first (digest bumps)" "$(cat "$UL")" "compose pull --ignore-buildable"

echo "== black-box: apply recovers from a failed 'compose up' (#125) =="
# A docker stub that fails `compose up -d --remove-orphans` only when FAIL_UP=1 (else succeeds).
A="$SANDBOX/applyfail"
mkdir -p "$A/build/tari" "$A/dashboard" "$A/bin" "$A/data/monero" "$A/data/tari" "$A/data/p2pool/stats" "$A/data/tor" "$A/data/dashboard"
: >"$A/dashboard/Dockerfile" # source-checkout marker → pithead builds (--pull never), #44
cp "$STACK" "$A/pithead"
cp "$ROOT/build/tari/config.toml.template" "$A/build/tari/"
cat >"$A/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose version"|"info") exit 0 ;;
  "exec tor cat /var/lib/tor/monero/hostname") echo "mona.onion"; exit 0 ;;
  "exec tor cat /var/lib/tor/tari/hostname")   echo "taria.onion"; exit 0 ;;
  "exec tor cat /var/lib/tor/p2pool/hostname") echo "p2pa.onion"; exit 0 ;;
  "compose up --pull never -d --remove-orphans") [ "${FAIL_UP:-0}" = "1" ] && exit 1 || exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$A/bin/sudo"
chmod +x "$A/bin/docker" "$A/bin/sudo"
cat >"$A/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$A/config.json"
# First apply: real config delta committed, but `compose up` FAILS -> marker left, rc 1, guidance.
out="$(cd "$A" && FAIL_UP=1 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "apply fails (rc 1) when compose up fails" "$rc" "1"
assert_contains "apply prints recovery guidance" "$out" "were NOT recreated"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi
assert_eq "apply leaves the incomplete marker" "$mk" "present"
# Second apply: config already committed (no delta), but the marker forces a retry, not a silent no-op.
out="$(cd "$A" && FAIL_UP=0 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "re-apply retries and succeeds (rc 0)" "$rc" "0"
assert_contains "re-apply re-attempts the recreate" "$out" "retrying"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi
assert_eq "marker cleared after a successful retry" "$mk" "absent"

echo "== black-box: up warns about missing (relocated) data dirs (#126) =="
RL="$SANDBOX/reloc"
mkdir -p "$RL/bin"
cp "$STACK" "$RL/pithead"
make_stubs "$RL/bin"
# Deployed, but .env names data dirs that don't exist — as if the install was moved/copied or a
# second checkout is being run. The stack would silently re-sync; `up` must warn first.
cat >"$RL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
MONERO_DATA_DIR=/no/such/data/monero
TARI_DATA_DIR=/no/such/data/tari
P2POOL_DATA_DIR=/no/such/data/p2pool
DASHBOARD_DATA_DIR=/no/such/data/dashboard
TOR_DATA_DIR=/no/such/data/tor
EOF
out="$(cd "$RL" && PATH="$RL/bin:$PATH" ./pithead up 2>&1)"
rc=$?
assert_rc "up still starts (rc 0)" "$rc" "0"
assert_contains "up warns about a fresh re-sync" "$out" "start a FRESH sync"
assert_contains "up names the missing monero dir" "$out" "MONERO_DATA_DIR → /no/such/data/monero"
# A healthy deployment (dirs present) must NOT warn.
mkdir -p "$RL/d/monero" "$RL/d/tari" "$RL/d/p2pool" "$RL/d/dashboard" "$RL/d/tor"
cat >"$RL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
MONERO_DATA_DIR=$RL/d/monero
TARI_DATA_DIR=$RL/d/tari
P2POOL_DATA_DIR=$RL/d/p2pool
DASHBOARD_DATA_DIR=$RL/d/dashboard
TOR_DATA_DIR=$RL/d/tor
EOF
out="$(cd "$RL" && PATH="$RL/bin:$PATH" ./pithead up 2>&1)"
case "$out" in *"FRESH sync"*) bad "no false warning when data dirs exist" "got: $out" ;; *) ok "no false warning when data dirs exist" ;; esac
# Gating: before the first deploy (no DEPLOYMENT_COMPLETED) the dirs are legitimately absent -> silent.
printf 'MONERO_DATA_DIR=/no/such/monero\n' >"$RL/.env"
assert_eq "missing_data_dirs silent before first deploy" "$(run_sourced "$RL" missing_data_dirs)" ""

echo "== unit: apply converges the control units even when nothing changed (#33) =="
# doctor's fix instruction is "run './pithead apply' from this directory". A box whose units point
# at a dead install has an UNCHANGED config by definition — the fault is in the unit files, not
# config.json — so apply's "nothing to apply" early return used to make the prescribed fix a no-op
# on the only box the check fires for.
# Mutation: remove provision_control_runner from apply's no-change branch -> this goes red.
apply_noop_steps() {
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { :; }
        load_preserved_state() { :; }
        onion_missing() { return 1; }
        is_deployed() { return 0; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        env_changed_keys() { :; } # nothing changed
        # shellcheck disable=SC2034  # read by apply()'s own `onion_missing "$P2POOL_ONION"` gate
        # (pithead:9344) in the sourced $STACK script, unseen here — onion_missing is stubbed
        # above, but bash evaluates the argument before calling it, so set -u still requires this
        # bound. The tor-network split (#1105) moved this file's only OTHER $P2POOL_ONION
        # reference (the onion-provisioning probes) into test-tor-network.sh, which unmasked this
        # one for shellcheck's single-file view.
        P2POOL_ONION="abc.onion" # provisioning marker; read under `set -u` before the stub
        log() { :; }
        provision_control_runner() { echo provision; }
        compose_up_checked() { echo compose; }
        apply
    ) | grep -xE 'provision|compose' | tr '\n' ','
}
: >"$SANDBOX/.env"
assert_eq "a no-change apply still converges the control units, and recreates nothing" \
    "$(apply_noop_steps)" "provision,"
unset apply_noop_steps

echo "== unit: the mutation lock serialises mutating windows (#1342) =="
# #1342: nothing in pithead excluded two mutating runs from each other, so a concurrent `backup`
# — which stops the stack — could delete a container out from under a still-running `setup`. The
# lock is scoped to mutating WINDOWS rather than whole verbs, because a wizard waiting on an
# operator (TimeoutStartSec=infinity) holding a whole-verb lock would block the boot unit forever.
# These cases prove the window refuses, names WHO holds it, gives it back, survives a
# re-invocation of pithead inside a hold, and counts nesting correctly.
LKDIR="$SANDBOX/lock"
mkdir -p "$LKDIR"
LKBIN="$SANDBOX/lockbin"
make_stubs "$LKBIN"
LKFILE="$LKDIR/explicit.lock"
LKLOG="$LKDIR/docker.log"

# Take the window in a background process and sit in it. `exec sleep` so the holder is ONE
# process: a forked sleep would inherit fd 9 and keep the lock alive past the kill below.
lock_hold_bg() { # -> sets LKHOLDER
    # Clear the record BEFORE starting, so `lock_await_record` below can only be satisfied by the
    # holder this call starts. Without it a record left by an earlier holder — a stale one is a
    # fixture in this file, and abnormal exits leave them in the field — satisfies the poll
    # instantly, the caller proceeds believing the window is held, and every case that needs
    # contention silently reports on an uncontended run instead.
    : >"$LKFILE"
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE"
        # shellcheck disable=SC1090
        source "$STACK"
        mutation_lock_acquire backup
        exec sleep 60
    ) >/dev/null 2>&1 &
    LKHOLDER=$!
}
# Poll for the holder record rather than sleeping a guessed interval — a sleep long enough to be
# reliable is long enough to slow the suite, and a short one is a flake waiting to happen.
lock_await_record() {
    local i=0
    while [ "$i" -lt 200 ]; do
        [ -s "$LKFILE" ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
# An external probe run as a CHILD opens its own descriptor, so it conflicts with a hold taken in
# any process — including this one. That is what makes it usable as a same-process probe.
lock_state() { if flock -n "$LKFILE" true 2>/dev/null; then echo free; else echo held; fi; }

lock_hold_bg
assert_rc "the holder records itself so a waiter can name it" "$(lock_await_record && echo 0 || echo 1)" "0"

: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "a mutating verb refuses rather than interleaving with a held window" "$rc" "75"
# `verb=backup` is the discriminator for opening the lock file with `9>>` and not `9>`: `9>`
# truncates at OPEN time, before the flock, which would wipe the record this waiter just read.
assert_contains "the refusal names the verb holding the window" "$out" "verb=backup"
# Only that the wait is ANNOUNCED — this message is printed before the blocking flock, so it
# cannot show that any waiting happened. The release-during-wait case below proves that part.
assert_contains "the waiter announces the wait before blocking" "$out" "waiting up to 1s"
assert_contains "the refusal states that nothing was changed" "$out" "nothing was changed"
assert_eq "a refused window touches no container" "$(cat "$LKLOG")" ""

# The lock lives on the descriptor, so the kernel releases it when the holder dies — no stale
# lock file to clean up by hand, which is why `error()` (an exit) is safe inside a window.
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "the kernel gives the window back when the holder dies" "$rc" "0"
assert_contains "the freed window actually runs the mutation it was holding back" "$(cat "$LKLOG")" "compose down"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "a window that completed is available to the next verb" "$rc" "0"
assert_eq "release clears the record, so nothing can name a holder that has gone" "$(cat "$LKFILE")" ""

# Arm the STALE-RECORD fixture the three cases below need, and note why they need it: with the
# lock file empty, `verb=backup` exists nowhere on disk and "never reported under the previous
# holder's name" is true of an empty string — an assertion that cannot fail for any change to
# pithead. So leave the record a real holder leaves when it is killed inside its window: the
# kernel drops the flock with the descriptor, and nothing clears the line. That is what an
# operator's Ctrl-C, and `error()` inside a window, both leave behind.
#
# The pair that discriminates is this stanza against the LIVE-holder case above: there the same
# record must be named in full (`verb=backup`), here the same bytes must not be, because the pid
# they name has gone. Suppressing every name would fail the first; echoing the file back would
# fail the second.
lock_hold_bg
lock_await_record || bad "the killed holder for the stale-record cases records itself" "no record"
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
assert_contains "a holder killed inside its window leaves its record on disk" "$(cat "$LKFILE")" "verb=backup"
assert_eq "while the kernel has already given the window itself back" "$(lock_state)" "free"

# A holder that is not pithead (an operator's own flock, a future caller) writes no record, and
# the record it finds on disk is the dead one armed above. The waiter must say so rather than
# print a stale name it happens to find.
# `flock -n FILE sleep 60 &` would NOT do: flock forks, so killing $! orphans a sleep that still
# holds the inherited descriptor for the full 60s and blocks every case after this one. Open the
# descriptor here and `exec` the sleep onto it instead, so the holder is one killable process.
(
    exec 9>>"$LKFILE"
    flock -n 9 || exit 1
    exec sleep 60
) &
LKEXT=$!
lock_held() { [ "$(lock_state)" = "held" ]; } # #1495: see wait_while_alive in lib.sh
wait_while_alive "$LKEXT" lock_held
# A poll that gives up must say so. If this one exhausts, the external holder never took the
# window: the two rc/message cases below would be reporting on an uncontended run, and the third
# passes for the worst reason available — nothing was reported under ANY name, so "never under
# the previous holder's name" is true of an empty string.
if [ "$(lock_state)" != "held" ]; then
    bad "the unrecorded holder takes the window" "the lock is free, so the three cases below prove nothing"
fi
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "an unrecorded holder still blocks the window" "$rc" "75"
assert_contains "an unrecorded holder is reported as unrecorded" "$out" "holder unrecorded"
assert_not_contains "and is never reported under the previous holder's name" "$out" "verb=backup"
kill "$LKEXT" 2>/dev/null
wait "$LKEXT" 2>/dev/null

# A blocked waiter must actually WAIT and then proceed — not print that it is waiting and refuse.
# Driven by releasing the lock underneath a waiter that is already blocked, rather than by timing:
# start the waiter, poll until it has announced the wait, then kill the holder and read its result.
# The pair is what discriminates. "Announced the wait" alone would also be true of a build that
# refuses on contact; rc=0 alone would also be true of a lock that was never taken.
: >"$LKLOG"
LKWOUT="$LKDIR/waiter.out"
: >"$LKWOUT"
lock_hold_bg
lock_await_record || bad "the holder for the release-during-wait case records itself" "no record"
(
    PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=30 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down >"$LKWOUT" 2>&1
    echo "rc=$?" >>"$LKWOUT"
) &
LKWAITER=$!
i=0
while [ "$i" -lt 200 ]; do
    grep -q "waiting up to" "$LKWOUT" 2>/dev/null && break
    sleep 0.05
    i=$((i + 1))
done
# Same shape. If the waiter never announced, the kill below frees the window before anything was
# blocked on it, and the three cases become a report on a verb that never contended at all.
if ! grep -q "waiting up to" "$LKWOUT" 2>/dev/null; then
    bad "the waiter reaches the held window before the holder is killed" "no announcement, so the three cases below prove nothing"
fi
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
wait "$LKWAITER" 2>/dev/null
assert_contains "a contending verb blocks rather than refusing on contact" "$(cat "$LKWOUT")" "waiting up to"
assert_contains "and proceeds once the holder leaves, instead of timing out" "$(cat "$LKWOUT")" "rc=0"
assert_contains "the mutation it was waiting to make then actually runs" "$(cat "$LKLOG")" "compose down"

# The re-invocation pair, and it is the load-bearing case. pithead re-invokes ITSELF for mutating
# verbs (run_chain, control_lifecycle's `"$self" restart`, control_backup's `"$self" backup -y`),
# so a lock that only knew about descriptors would deadlock a parent against its own child. fd 9
# is inherited across exec, but a child that opens its OWN descriptor on the same file blocks —
# which is why the marker is EXPORTED rather than merely set. Stripping the marker is therefore
# the mutation that proves the marker is what carries the hold across the re-invocation.
lock_reinvoke_probe() { # <1=keep the inherited marker|0=strip it> -> "<child rc>|<docker>|<parent>"
    local keep="$1" clog="$LKDIR/child.log"
    : >"$clog"
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1
        export PATH="$LKBIN:$PATH" DOCKER_LOG="$clog"
        # shellcheck disable=SC1090
        source "$STACK"
        # pithead:14 is `set -Eeuo pipefail`, and sourcing it turns errexit on HERE — which would
        # kill this subshell at the deliberately-failing child below. run_sourced does the same.
        set +e
        mutation_lock_acquire backup
        local crc st=free called=untouched
        # Take the child's exit status from the child itself, not from an `echo "$?"` inside it:
        # the refusal path is error(), which exits, so any trailing echo never runs and would
        # report an empty status for the very case this asserts.
        case "$keep" in
        1) bash -c 'source "$1"; stack_down' _ "$STACK" >/dev/null 2>&1 ;;
        0) env -u PITHEAD_LOCK_HELD bash -c 'source "$1"; stack_down' _ "$STACK" >/dev/null 2>&1 ;;
        # Two sequential windows in one re-invoked child. This is what the not-owner guard in
        # mutation_lock_release is for: without it the FIRST release closes the inherited
        # descriptor and drops the marker, so the child's SECOND window opens a descriptor of its
        # own and deadlocks against the parent that invoked it.
        2) bash -c 'source "$1"; set +e
               mutation_lock_acquire down && mutation_lock_release
               mutation_lock_acquire down && mutation_lock_release' _ "$STACK" >/dev/null 2>&1 ;;
        esac
        crc=$?
        flock -n "$LKFILE" true 2>/dev/null || st=held
        [ -s "$clog" ] && called=called
        # An inherited hold belongs to the ancestor, so the child's release must leave the record
        # alone. Clearing it would leave the parent holding a window that the next waiter can only
        # describe as "unrecorded" — the lock still correct, the diagnosis silently lost.
        local rec recstate=other
        rec=$(head -n 1 "$LKFILE" 2>/dev/null)
        case "$rec" in
        *verb=backup*) recstate=intact ;;
        "") recstate=cleared ;;
        esac
        printf '%s|%s|%s|%s\n' "$crc" "$called" "$st" "$recstate"
    ) 2>/dev/null
}
assert_eq "a re-invoked pithead inside a held window proceeds on the inherited marker" \
    "$(lock_reinvoke_probe 1)" "0|called|held|intact"
assert_eq "without the marker that same child blocks on its own parent and changes nothing" \
    "$(lock_reinvoke_probe 0)" "75|untouched|held|intact"
assert_eq "a re-invoked child can open a second window without deadlocking on its parent" \
    "$(lock_reinvoke_probe 2)" "0|untouched|held|intact"

# Nesting: an inner window (backup -> down) must not hand the lock back when IT finishes, only
# when the outermost one does. This is what the depth counter is for; without it the first
# release inside a backup would free the stack mid-archive.
lock_nest_probe() { # <releases> -> free|held
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e # sourcing pithead turns errexit on here (pithead:14)
        mutation_lock_acquire backup
        mutation_lock_acquire down
        local i=0
        while [ "$i" -lt "$1" ]; do
            mutation_lock_release
            i=$((i + 1))
        done
        if flock -n "$LKFILE" true 2>/dev/null; then echo free; else echo held; fi
    ) 2>/dev/null
}
assert_eq "an inner window closing does not release the outer one" "$(lock_nest_probe 1)" "held"
assert_eq "the outermost release is the one that gives the lock back" "$(lock_nest_probe 2)" "free"

# A bad argument must be rejected AT ONCE, not after waiting out someone else's window. Validating
# inside the hold made `restart typo` sit for PITHEAD_LOCK_TIMEOUT seconds only to report a typo.
lock_hold_bg
assert_rc "the holder for the restart cases records itself" "$(lock_await_record && echo 0 || echo 1)" "0"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_restart bogus 2>&1)"
rc=$?
assert_rc "a bad restart argument is still rejected while the lock is held" "$rc" "1"
assert_contains "the rejection names the contract" "$out" "takes no argument, 'tor'"
assert_not_contains "a bad argument never waits out another operation's window" "$out" "waiting up to"
assert_eq "and it touches no container" "$(cat "$LKLOG")" ""
# Control for the assertion above: without this, "no waiting message" would also be true of a lock
# that was never held, and the case would pass for a reason unrelated to the guard.
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_restart 2>&1)"
assert_contains "while a VALID restart against the same held window does wait" "$out" "waiting up to"
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null

# The shipped default: no PITHEAD_LOCK_FILE, so the lock is .pithead.lock in the stack directory
# (pithead cd's to its own directory when executed, so that path is stable across invocations).
rm -f "$LKDIR/.pithead.lock"
DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down >/dev/null 2>&1
assert_eq "the lock defaults to .pithead.lock in the stack directory" \
    "$([ -f "$LKDIR/.pithead.lock" ] && echo present || echo absent)" "present"

# An unopenable lock file degrades OPEN, exactly like a missing flock and for the same reason: a
# deploy root only root can write, or a read-only mount, is an environment fault, and refusing
# every mutating verb on such a box is a worse regression than the race. The path here has a
# REGULAR FILE as its parent, so the open fails with ENOTDIR for any uid — a chmod-based fixture
# would silently stop being a fixture under a root-run suite and the case would pass vacuously.
printf 'not a directory\n' >"$LKDIR/notadir"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKDIR/notadir/nope.lock" DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "an unopenable lock file degrades instead of refusing every mutating verb" "$rc" "0"
assert_contains "and says out loud that it is no longer serialising anything" "$out" "cannot serialise itself"
assert_contains "the mutation it could not serialise still runs" "$(cat "$LKLOG")" "compose down"

# The lock is keyed on the DEPLOY ROOT, not on the directory pithead was run from. One stack is
# several sibling pithead-vX.Y.Z dirs (`current ->`, the rollback copy, and the fresh dir the
# dashboard's one-click upgrade creates and runs `./pithead upgrade` inside), all driving the same
# Compose project against the same data. Keyed on the directory, that upgrade and a concurrent
# `backup` took different lock files and could not see each other — uncontended by construction,
# which is #1059 wearing a green tick.
LKROOT="$SANDBOX/deploy"
mkdir -p "$LKROOT/pithead-v1.0.0" "$LKROOT/pithead-v2.0.0" "$LKROOT/plain-a" "$LKROOT/plain-b"
# Hold a window in one dir; drive a mutating verb from its sibling. `env -u PITHEAD_LOCK_HELD`
# because the concurrent actor is a SEPARATE process tree — inheriting the marker would make the
# child skip the lock entirely and the case would pass without ever contending.
lock_sibling_probe() { # <holder dir> <other dir> -> "<rc>|<mutated?>"
    local clog="$LKROOT/sib.log"
    : >"$clog"
    (
        cd "$1" || exit 9
        # shellcheck disable=SC1090
        source "$STACK"
        set +e # sourcing pithead turns errexit on here (pithead:14)
        mutation_lock_acquire backup
        PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$clog" PATH="$LKBIN:$PATH" \
            env -u PITHEAD_LOCK_HELD bash -c 'cd "$2" || exit 9; source "$1"; set +e; stack_down' _ "$STACK" "$2" >/dev/null 2>&1
        local rc=$? mutated=untouched
        grep -q 'compose down' "$clog" 2>/dev/null && mutated=mutated
        printf '%s|%s\n' "$rc" "$mutated"
    ) 2>/dev/null
}
assert_eq "a window held in one version dir blocks its sibling, which is where the one-click upgrade runs" \
    "$(lock_sibling_probe "$LKROOT/pithead-v1.0.0" "$LKROOT/pithead-v2.0.0")" "75|untouched"
# The control that makes the case above mean something: two dirs that are NOT a versioned deploy
# keep their own locks, so the block is the deploy root talking and not merely "two directories".
assert_eq "two unrelated stacks still lock independently" \
    "$(lock_sibling_probe "$LKROOT/plain-a" "$LKROOT/plain-b")" "0|mutated"
rm -f "$LKROOT/.pithead.lock" "$LKROOT/pithead-v1.0.0/.pithead.lock"
DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKROOT/pithead-v1.0.0" stack_down >/dev/null 2>&1
assert_eq "a versioned install keys its lock on the deploy root its siblings share" \
    "$([ -f "$LKROOT/.pithead.lock" ] && echo present || echo absent)" "present"
assert_eq "and leaves no second, uncontendable lock inside the version dir" \
    "$([ -f "$LKROOT/pithead-v1.0.0/.pithead.lock" ] && echo present || echo absent)" "absent"

# WIRING, verb by verb. Everything above proves the lock PRIMITIVE; these prove each verb is
# actually attached to it. Every runtime case above drives stack_down, so six of the eight locked
# verbs could stop acquiring — or stop releasing — with nothing going red.
LKW="$SANDBOX/lockwiring"
mkdir -p "$LKW/bin"
make_stubs "$LKW/bin"
cat >"$LKW/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
# restore's chown to the container uid cannot work unprivileged; everything else runs as the
# test user, so the verb reaches its own window instead of aborting before it.
[ "$1" = "chown" ] && exit 0
exec "$@"
SUDOEOF
chmod +x "$LKW/bin/sudo"
# A provisioned install, rebuildable — every verb driven below WRITES to it, and a used fixture
# stops being a fixture. The hand-written .env is deliberately not what a render produces, so
# `apply` sees a change and takes its committing branch rather than returning early — but that
# holds only on a directory no verb has run in yet. The free half of each pair below re-renders
# this .env, so by the time `apply` is probed on the shared fixture there is nothing left to
# change. That is why the committing branch is driven on its own fixture, here and in
# lock_wiring_balance.
lock_wiring_fixture() { # <dir>
    mkdir -p "$1/data/tor" "$1/data/dashboard"
    cat >"$1/.env" <<'ENVEOF'
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=LKWTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
ENVEOF
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VALID_TARI" >"$1/config.json"
    printf 'CADDY-ORIG\n' >"$1/Caddyfile"
    printf 'ONIONKEY-ORIG\n' >"$1/data/tor/hs_ed25519_secret_key"
    printf 'DBDATA-ORIG\n' >"$1/data/dashboard/dashboard.db"
}
lock_wiring_fixture "$LKW"
tar -czf "$LKW/wiring-archive.tar.gz" -C "$LKW" config.json
LKWHELD="$LKW/held.lock"
LKWFREE="$LKW/free.lock"
# Which directory a pair runs in. `setup` needs an UNPROVISIONED one: the fixture above carries a
# rendered .env, and setup refuses a non-interactive re-run before it reaches its window — so
# driven there it would report "did not wait" for a reason that has nothing to do with the lock.
LKWDIR="$LKW"
LKWFRESH="$LKW/fresh"
LKWAPPLY="$LKW/applying"
LKWBAL="$LKW/balance"
LKWSETUP="$LKW/setupprompt"
mkdir -p "$LKWFRESH"

lock_wiring_probe() { # <lock file> <fn> [args...] -> "<timedout|ran>+<mutated|untouched>"
    local lk="$1" log="$LKW/wiring-docker.log" out t=ran m=untouched
    shift
    : >"$log"
    out=$(cd "$LKWDIR" && PITHEAD_LOCK_FILE="$lk" PITHEAD_LOCK_TIMEOUT=1 PITHEAD_APPLIANCE=0 \
        DOCKER_LOG="$log" PATH="$LKW/bin:$PATH" \
        env -u PITHEAD_LOCK_HELD bash -c 'source "$1"; set +e; shift; "$@"' _ "$STACK" "$@" 2>&1)
    case "$out" in *"waiting up to"*) t=timedout ;; esac
    # Only the MUTATING compose calls: `backup` runs `compose ps` to decide whether the stack is
    # up before it takes the window, and a read-only query is not a mutation.
    grep -Eq 'compose (up|down|stop|create|restart)' "$log" 2>/dev/null && m=mutated
    printf '%s+%s' "$t" "$m"
}
# The pair, per verb, in one assertion: refuses against a held window and touches nothing, and
# gets PAST the lock when nothing holds it. The second half is the control — without it
# "timed out" would also be true of a verb that cannot run in this fixture at all.
lock_wiring_pair() { # <fn> [args...] -> "<held>|<free timed out?>"
    local held free
    held=$(lock_wiring_probe "$LKWHELD" "$@")
    rm -f "$LKWFREE"
    free=$(lock_wiring_probe "$LKWFREE" "$@")
    rm -f "$LKWFREE"
    printf '%s|%s' "$held" "${free%%+*}"
}
# One holder for all six pairs below. `flock -w`, not `flock -n`: the readiness poll under it
# takes the lock itself to test for it, and a non-blocking holder that loses that race exits —
# leaving every case below to pass against a lock nobody held. Bounded, so a genuinely stuck
# fixture is reported by the guard below instead of hanging the suite.
: >"$LKWHELD"
(
    exec 9>>"$LKWHELD"
    flock -w 20 9 || exit 1
    exec sleep 120
) &
LKWHOLDER=$!
i=0
while [ "$i" -lt 200 ]; do
    flock -n "$LKWHELD" true 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
done
# The wiring cases are only evidence while this holds — say so rather than reporting six passes
# earned by an absent holder.
if flock -n "$LKWHELD" true 2>/dev/null; then
    bad "the holder for the verb-wiring cases takes the window" "the lock is free, so the six cases below prove nothing"
fi
assert_eq "up waits on a held window and changes nothing" "$(lock_wiring_pair stack_up)" "timedout+untouched|ran"
assert_eq "upgrade waits on a held window and changes nothing" "$(lock_wiring_pair stack_upgrade)" "timedout+untouched|ran"
LKWDIR="$LKWFRESH"
assert_eq "setup waits on a held window and changes nothing" "$(lock_wiring_pair setup)" "timedout+untouched|ran"
LKWDIR="$LKW"
assert_eq "restore waits on a held window and changes nothing" \
    "$(lock_wiring_pair stack_restore -y "$LKW/wiring-archive.tar.gz")" "timedout+untouched|ran"
assert_eq "backup waits on a held window and changes nothing" \
    "$(lock_wiring_pair stack_backup -y --no-encrypt)" "timedout+untouched|ran"
# apply takes the window in THREE places and the shared fixture reaches exactly one of them:
# five free-runs have re-rendered its .env by now, so apply finds nothing to change and returns
# on the no-change branch. Drive all three, each on the fixture it needs. Until this split,
# DELETING either of the other two acquires outright left this whole file green.
assert_eq "apply waits on a held window when it has nothing to change" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
lock_wiring_fixture "$LKWAPPLY"
LKWDIR="$LKWAPPLY"
assert_eq "apply waits on a held window before it commits a change" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
# The third window is the retry branch — a previous apply committed the config and then failed to
# recreate. That state is what this fixture is in now (the free run above re-rendered its .env),
# so arming the marker is the whole setup. Nothing else in this file reaches that acquire:
# deleting it leaves every other case green, which is how it stayed unguarded until now.
: >"$LKWAPPLY/.env.apply-incomplete"
assert_eq "apply waits on a held window while it retries a failed recreate" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
LKWDIR="$LKW"
kill "$LKWHOLDER" 2>/dev/null
wait "$LKWHOLDER" 2>/dev/null

# The other half of the wiring: a verb that finishes must hand the lock back exactly once. A
# missing release leaves the window open for the rest of the process, and a DOUBLE acquire leaves
# the depth counter at 1 with nothing left to decrement it — the failure the `apply` retry-branch
# guard exists to prevent. Neither is visible from outside the process, because the kernel drops
# the hold when it exits; both are visible from inside it.
lock_wiring_balance() { # <fn> [args...] -> "depth=<n> state=<free|held>"
    # On a FRESH fixture every time, and that is load-bearing rather than tidiness: a completed
    # `apply` re-renders .env, so a second apply against the same dir finds nothing to change and
    # returns before the retry-branch guard this case exists to protect. Re-using the dir left
    # that guard unfalsifiable — the case passed either way, which reads exactly like coverage.
    rm -rf "$LKWBAL"
    lock_wiring_fixture "$LKWBAL"
    rm -f "$LKWFREE"
    (cd "$LKWBAL" && PITHEAD_LOCK_FILE="$LKWFREE" PITHEAD_APPLIANCE=0 DOCKER_LOG=/dev/null \
        PATH="$LKW/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e; shift; "$@" >/dev/null 2>&1
                 st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
                 printf "depth=%s state=%s" "$_PITHEAD_LOCK_DEPTH" "$st"' _ "$STACK" "$@") 2>/dev/null
}
assert_eq "up gives its window back when it finishes" "$(lock_wiring_balance stack_up)" "depth=0 state=free"
assert_eq "upgrade gives its window back when it finishes" "$(lock_wiring_balance stack_upgrade)" "depth=0 state=free"
assert_eq "backup gives its window back when it finishes" \
    "$(lock_wiring_balance stack_backup -y --no-encrypt)" "depth=0 state=free"
assert_eq "restore gives its window back when it finishes" \
    "$(lock_wiring_balance stack_restore -y "$LKW/wiring-archive.tar.gz")" "depth=0 state=free"
assert_eq "apply takes its window once and gives it back, however it reached the recreate" \
    "$(lock_wiring_balance apply -y)" "depth=0 state=free"
# restart is the sixth verb with a window and the only one the block above did not name. Nothing
# else in this file reaches its release either: the four restart cases at the top of the file
# assert what it restarted, not what it did with the lock, so deleting stack_restart's
# `mutation_lock_release` left every case in this file green.
assert_eq "restart gives its window back when it finishes" \
    "$(lock_wiring_balance stack_restart)" "depth=0 state=free"

# SETUP'S RELEASE — its own probe, because a balance case cannot reach it.
#
# setup's release is not at the end of the verb. It sits BEFORE the interactive "start now?",
# and setup's own comment says why: everything below it is a message or a human wait, and the
# firstboot wizard runs `(setup)` in a subshell, so a hold spanning the prompt would park the
# window on an absent operator while pithead-boot's `up` timed out against it. The property is
# therefore an ORDERING — released BEFORE the wait — which an end-state balance cannot see.
#
# Nor can a balance case be driven here at all: setup refuses a non-interactive re-run against a
# provisioned dir before it ever reaches its window (which is why the pair case above needs the
# fresh dir), and against a fresh one it would run the entire wizard. So the probe stubs the
# provisioning body — every step between the acquire and the release — and leaves the LOCK
# WIRING real, which is the only thing under test. prompt_start_stack becomes the probe itself,
# reporting whether the window was free at the instant setup reached the human wait.
#
# REACHING the probe is the anti-vacuity control: if the stubs ever stop letting setup through,
# nothing prints and the assertion fails on an empty string instead of passing on a run that
# never got there. The end-state half is read too, so a release that moved rather than vanished
# still shows up.
lock_wiring_setup_prompt() { # -> "at-prompt=<free|held> depth=<n> state=<free|held>"
    rm -rf "$LKWSETUP"
    mkdir -p "$LKWSETUP"
    rm -f "$LKWFREE"
    (cd "$LKWSETUP" && PITHEAD_LOCK_FILE="$LKWFREE" PITHEAD_APPLIANCE=0 DOCKER_LOG=/dev/null \
        PATH="$LKW/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e
            for f in check_prerequisites ensure_config_exists ensure_onion_password \
                parse_and_validate_config preflight_resources check_stratum_exposure \
                load_preserved_state resolve_dashboard_host prepare_directories render_env \
                provision_tor inject_service_configs optimize_kernel generate_caddyfile \
                provision_control_runner render_local_miner_config update_current_symlink \
                provision_local_miner; do eval "$f() { :; }"; done
            prompt_start_stack() {
                st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
                printf "at-prompt=%s " "$st" >&3
            }
            setup >/dev/null 2>&1
            st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
            printf "depth=%s state=%s" "$_PITHEAD_LOCK_DEPTH" "$st" >&3' _ "$STACK" 3>&1) 2>/dev/null
}
assert_eq "setup hands its window back BEFORE the interactive start prompt" \
    "$(lock_wiring_setup_prompt)" "at-prompt=free depth=0 state=free"

# THE RUNNING-STACK BACKUP BRANCH — unreachable by every case above, and that is the point.
#
# stack_backup takes the window in TWO places, chosen on `docker compose ps --status running -q`.
# make_stubs' docker (tests/stack/lib.sh) has NO case arm for that query and falls through to
# `exit 0` with empty stdout, so `running` is always empty and BOTH backup cases above take the
# stack-already-stopped branch. Deleting the running branch's acquire outright left this whole
# file green — the same shape as apply's two unreached windows, and it hides more: without it the
# archive is taken in a THIRD window rather than one, with `tar` running UNLOCKED between
# stack_down's release and stack_up's re-acquire. A concurrent setup or apply can then bring
# containers up mid-archive, which is a torn backup — #970's retry failure mode arriving for a
# reason the retry cannot fix.
#
# A balance case CANNOT see this: with or without that acquire the verb ends depth=0 and free. The
# property that discriminates is WHEN the window is held, so the probe asks the only question that
# separates them — was it held at the moment the archive was taken?
LKWRUN="$LKW/runningstack"
LKWRUNLK="$LKW/running.lock"
lock_backup_running_probe() { # -> "<which branch>|<window while the archive is taken>"
    local log="$LKWRUN/docker.log" branch=stopped
    rm -rf "$LKWRUN"
    lock_wiring_fixture "$LKWRUN"
    mkdir -p "$LKWRUN/bin"
    : >"$log"
    rm -f "$LKWRUNLK" "$LKWRUN/window"
    # A docker that reports a RUNNING stack — the one answer the shared stub cannot give.
    cat >"$LKWRUN/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose ps --status running -q") echo "c0ffeec0ffee" ;;
esac
exit 0
DOCKEREOF
    # A sudo that runs nothing and records whether the mutation window is held at the instant the
    # archive is taken. `flock -n` from this child opens its OWN descriptor, so the parent's fd 9
    # hold denies it — the same mechanism the balance cases use to read the lock's state.
    cat >"$LKWRUN/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
case "$1" in
tar)
    if flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null; then
        printf 'free' >"$WINDOW_OUT"
    else
        printf 'held' >"$WINDOW_OUT"
    fi
    ;;
esac
exit 0
SUDOEOF
    chmod +x "$LKWRUN/bin/docker" "$LKWRUN/bin/sudo"
    (cd "$LKWRUN" && PITHEAD_LOCK_FILE="$LKWRUNLK" PITHEAD_APPLIANCE=0 DOCKER_LOG="$log" \
        WINDOW_OUT="$LKWRUN/window" PATH="$LKWRUN/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e; shift; "$@"' _ "$STACK" \
        stack_backup -y --no-encrypt) >/dev/null 2>&1
    # Which branch actually ran, read from the stack having been STOPPED for the backup. Without
    # this half the row is vacuous in exactly the way it exists to fix: if the stub ever stops
    # answering the query, the stopped branch takes its own window, the archive is still taken
    # under it, and a "held" verdict would read as coverage of a branch that never ran.
    grep -Eq 'compose .*\bdown\b' "$log" 2>/dev/null && branch=running
    printf '%s|%s' "$branch" "$(cat "$LKWRUN/window" 2>/dev/null || printf 'never-archived')"
}
assert_eq "a backup that stops a running stack holds one window across the archive" \
    "$(lock_backup_running_probe)" "running|held"
unset -f lock_backup_running_probe

unset -f lock_hold_bg lock_await_record lock_state lock_held lock_reinvoke_probe lock_nest_probe
unset -f lock_sibling_probe lock_wiring_fixture lock_wiring_probe lock_wiring_pair lock_wiring_balance

echo "== unit: the appliance boot leg tells lock contention from a bad slot (#1342) =="
# pithead-boot's fail_boot reboots on the first failed boot so the bootloader falls back to the
# other A/B slot, and on the second declares that the fault is not the slot. There is no systemd
# ordering between pithead-firstboot and pithead-boot, so `./pithead up` here can collide with the
# wizard's `setup` window — and a collision routed through fail_boot spends the one fallback the
# box has on a slot that is fine, then misdiagnoses itself. Sourcing the boot script defines its
# functions and runs none of it (its BASH_SOURCE guard), so this drives the real routing.
BOOTC="$SANDBOX/bootcontend"
mkdir -p "$BOOTC"
boot_up_probe() { # <exit status from `pithead up`> -> "<counter>|<rebooted?>|<which message>"
    local out verdict=other
    rm -f "$BOOTC/.boot-gate-failures" "$BOOTC/rebooted"
    # Both branches report on STDERR, so the redirect belongs to the subshell and INSIDE the
    # capture: `$(...) 2>&1` sends it to the caller's stderr instead and leaves $out empty.
    out=$( (
        cd "$BOOTC" || exit 9
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot"
        # shellcheck disable=SC2034  # both are read by the sourced boot script, not by this shell
        BOOT_FAIL_COUNT="$BOOTC/.boot-gate-failures"
        # shellcheck disable=SC2034
        PITHEAD_REBOOT_CMD="touch $BOOTC/rebooted"
        boot_up_failed "$1"
    ) 2>&1)
    # Each branch is read on the one sentence ONLY it writes, and the other's absence is asserted
    # by the verdict being a single value: both messages mention the A/B fallback, so keying on
    # that shared phrase would let either branch stand in for the other.
    case "$out" in *"contention, NOT a bad slot"*) verdict=contended ;; esac
    case "$out" in *"slot left uncommitted so"*) verdict="$verdict+slotfailure" ;; esac
    printf '%s|%s|%s' \
        "$(cat "$BOOTC/.boot-gate-failures" 2>/dev/null || echo none)" \
        "$([ -f "$BOOTC/rebooted" ] && echo rebooted || echo no-reboot)" "$verdict"
}
assert_eq "a lock timeout spends no A/B fallback, is not counted, and says it is contention" \
    "$(boot_up_probe 75)" "none|no-reboot|contended"
assert_eq "any other failed up still reads as a bad slot and falls back" \
    "$(boot_up_probe 1)" "1|rebooted|other+slotfailure"
unset -f boot_up_probe

# THE WIZARD'S HALF OF THE SAME ROUTING — the leg #1342 left unrouted, recreating #1059's shape.
#
# The block above proves the BOOT leg tells contention from a bad slot. `setup` runs inside a
# mutating window too and can lose the same race, but every non-zero (setup) was routed as a
# provisioning failure: the operator is told their configuration is wrong and asked to correct it,
# on a first boot where there is no shell to contradict it. Worse, that path calls
# wizard_keep_failed_config, which REMOVES config.json when the machine-role marker never landed —
# and record_machine_role is best-effort (`printf ... || true`).
#
# THE FIXTURE IS CHOSEN TO MAKE THE REMOVAL REACHABLE: config.json present, machine-role ABSENT.
# With the marker present nothing is removed on either branch, both rows would read "kept", and
# this pair could not fail for any change to the routing.
WIZC="$SANDBOX/wizcontend"
wizard_fail_probe() { # <exit status of setup> -> "<config>|<copy>|<verdict>|<rc>"
    local out rc=0 verdict=other
    rm -rf "$WIZC"
    mkdir -p "$WIZC"
    printf '{"monero":{}}\n' >"$WIZC/config.json"
    out=$(run_sourced "$WIZC" wizard_setup_failed "$1" 2>&1) || rc=$?
    # Keyed on a sentence ONLY one branch writes, for the reason the boot probe above gives: both
    # branches mention reopening the setup window, so that shared phrase would let either stand in
    # for the other.
    case "$out" in *"contention, NOT a problem with the configuration"*) verdict=contended ;; esac
    case "$out" in *"so it can be corrected"*) verdict="$verdict+badconfig" ;; esac
    printf '%s|%s|%s|%s' \
        "$([ -f "$WIZC/config.json" ] && echo kept || echo DELETED)" \
        "$([ -f "$WIZC/config.json.failed" ] && echo copied || echo no-copy)" \
        "$verdict" "$rc"
}
# rc is the prefill signal: 0 means a config.json.failed copy was kept and the reopened page fills
# from it, 1 means the live config.json is what the operator gets back.
assert_eq "a lock-timeout setup keeps the operator's configuration and names it as contention" \
    "$(wizard_fail_probe 75)" "kept|no-copy|contended|1"
assert_eq "any other failed setup still copies the config aside and asks for a correction" \
    "$(wizard_fail_probe 1)" "DELETED|copied|other+badconfig|0"
unset -f wizard_fail_probe
