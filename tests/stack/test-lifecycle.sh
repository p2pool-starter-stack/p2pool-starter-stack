# shellcheck shell=bash
#
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
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; run.sh's "config validation" black-box
#   calls it once, far earlier than the migration-hold/upgrade/apply-recovery sections below that
#   read them — that section stays in run.sh (a generic multi-field validator, not a lifecycle
#   concern). build_val_sandbox() is idempotent (a fixed $SANDBOX/val path, mkdir -p, template
#   copies), so calling it again here is a safe no-op re-affirm as currently sourced.
# - $DOCKER_LOG: the "apply preserves secrets + propagates" black-box sets it ($V/docker.log) and
#   stays in run.sh (a generic multi-key regression, not a lifecycle concern).
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
