# shellcheck shell=bash
#
# CLI domain (#1105 Phase 1): dispatch, subcommand chaining, completion, guards, the small input
# validators, host/deps detection, version, and the first-run epilogue. Sourced by
# tests/stack/run.sh after lib.sh. (The apply --dry-run and symlink-invocation sections stay
# with the control-channel cluster: they run against the $C sandbox and its applied state.)
echo "== unit: resolve_default =="
assert_eq "auto -> default" "$(run_sourced "$SANDBOX" resolve_default auto /def)" "/def"
assert_eq "empty -> default" "$(run_sourced "$SANDBOX" resolve_default '' /def)" "/def"
assert_eq "DYNAMIC_DATA -> default" "$(run_sourced "$SANDBOX" resolve_default DYNAMIC_DATA /def)" "/def"
assert_eq "custom kept" "$(run_sourced "$SANDBOX" resolve_default /my/dir /def)" "/my/dir"

echo "== unit: assert_safe_dir =="
run_sourced "$SANDBOX" assert_safe_dir "/" >/dev/null 2>&1
assert_rc "rejects /" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/home" >/dev/null 2>&1
assert_rc "rejects /home" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "" >/dev/null 2>&1
assert_rc "rejects empty" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/srv/p2pool/data" >/dev/null 2>&1
assert_rc "allows real dir" "$?" "0"
# Tightened guard (#91): bare mount/parent roots, non-absolute paths and '..' traversal are refused;
# a dedicated subfolder of a mount root is still fine.
run_sourced "$SANDBOX" assert_safe_dir "/srv" >/dev/null 2>&1
assert_rc "rejects bare /srv" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/mnt" >/dev/null 2>&1
assert_rc "rejects bare /mnt" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "relative/data" >/dev/null 2>&1
assert_rc "rejects relative path" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/srv/../etc/data" >/dev/null 2>&1
assert_rc "rejects .. traversal" "$?" "1"
# A ':' would forge an extra field in the compose bind-mount short syntax (SOURCE:TARGET:MODE).
run_sourced "$SANDBOX" assert_safe_dir "/srv/pithead/data:ro" >/dev/null 2>&1
assert_rc "rejects ':' (compose volume-mount injection)" "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/mnt/disk/monero" >/dev/null 2>&1
assert_rc "allows mount subfolder" "$?" "0"

echo "== unit: is_ipv4 =="
run_sourced "$SANDBOX" is_ipv4 "0.0.0.0" >/dev/null 2>&1
assert_rc "accepts 0.0.0.0" "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "127.0.0.1" >/dev/null 2>&1
assert_rc "accepts 127.0.0.1" "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "192.168.1.10" >/dev/null 2>&1
assert_rc "accepts LAN IP" "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "256.0.0.1" >/dev/null 2>&1
assert_rc "rejects octet >255" "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "1.2.3" >/dev/null 2>&1
assert_rc "rejects 3 octets" "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "192.168.1.0/24" >/dev/null 2>&1
assert_rc "rejects CIDR/subnet" "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "example.com" >/dev/null 2>&1
assert_rc "rejects hostname" "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "" >/dev/null 2>&1
assert_rc "rejects empty" "$?" "1"

echo "== unit: is_valid_port (#740 — dashboard.port / Caddyfile injection guard) =="
run_sourced "$SANDBOX" is_valid_port "8443" >/dev/null 2>&1
assert_rc "accepts 8443" "$?" "0"
run_sourced "$SANDBOX" is_valid_port "1" >/dev/null 2>&1
assert_rc "accepts 1 (low bound)" "$?" "0"
run_sourced "$SANDBOX" is_valid_port "65535" >/dev/null 2>&1
assert_rc "accepts 65535 (high bound)" "$?" "0"
run_sourced "$SANDBOX" is_valid_port "0" >/dev/null 2>&1
assert_rc "rejects 0" "$?" "1"
run_sourced "$SANDBOX" is_valid_port "65536" >/dev/null 2>&1
assert_rc "rejects 65536 (over range)" "$?" "1"
run_sourced "$SANDBOX" is_valid_port "80x" >/dev/null 2>&1
assert_rc "rejects non-numeric" "$?" "1"
run_sourced "$SANDBOX" is_valid_port "8080 {" >/dev/null 2>&1
assert_rc "rejects a Caddyfile-injection attempt" "$?" "1"
run_sourced "$SANDBOX" is_valid_port "" >/dev/null 2>&1
assert_rc "rejects empty" "$?" "1"
run_sourced "$SANDBOX" is_valid_port "0899" >/dev/null 2>&1
assert_rc "rejects a leading zero (no octal-parse error)" "$?" "1"

echo "== unit: semver_newer (#59 — the upgrade downgrade guard) =="
# The comparison gates the upgrade button: a lexical bug would let 1.9.0 look "newer" than 1.10.0
# and could be leveraged to force an older, vulnerable release.
run_sourced "$SANDBOX" semver_newer "v1.10.0" "v1.9.0" >/dev/null 2>&1
assert_rc "1.10.0 is newer than 1.9.0 (no lexical bug)" "$?" "0"
run_sourced "$SANDBOX" semver_newer "v1.9.0" "v1.10.0" >/dev/null 2>&1
assert_rc "1.9.0 is NOT newer than 1.10.0" "$?" "1"
run_sourced "$SANDBOX" semver_newer "v1.3.1" "v1.3.1" >/dev/null 2>&1
assert_rc "equal versions are not newer" "$?" "1"
run_sourced "$SANDBOX" semver_newer "v2.0.0" "v1.99.99" >/dev/null 2>&1
assert_rc "major bump beats a high minor/patch" "$?" "0"

echo "== unit: resolve_dashboard_host (dashboard.host 'auto' revert, 247c5a0) =="
# A configured dashboard.host is used verbatim.
# shellcheck disable=SC1090,SC2034  # $STACK path is dynamic; DASHBOARD_HOST is read by the sourced function
got="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_HOST='my.box.lan'
    resolve_dashboard_host >/dev/null 2>&1
    printf '%s' "$HOST_IP"
)"
assert_eq "configured dashboard.host is used" "$got" "my.box.lan"
# 'auto' (no dashboard.host) on a non-interactive run must REVERT HOST_IP to the machine
# hostname, not keep a stale prior value — the regression fixed in 247c5a0.
# shellcheck disable=SC1090,SC2034
got="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_HOST=''
    HOST_IP='STALE'
    resolve_dashboard_host >/dev/null 2>&1
    printf '%s' "$HOST_IP"
)"
assert_eq "dashboard.host 'auto' reverts to hostname" "$got" "$(hostname)"

echo "== unit: is_valid_host (#130) =="
run_sourced "$SANDBOX" is_valid_host "box.lan" >/dev/null 2>&1
assert_rc "accepts hostname" "$?" "0"
run_sourced "$SANDBOX" is_valid_host "192.168.1.10" >/dev/null 2>&1
assert_rc "accepts IPv4" "$?" "0"
run_sourced "$SANDBOX" is_valid_host "fe80::1" >/dev/null 2>&1
assert_rc "accepts IPv6" "$?" "0"
run_sourced "$SANDBOX" is_valid_host "bad host" >/dev/null 2>&1
assert_rc "rejects space" "$?" "1"
run_sourced "$SANDBOX" is_valid_host 'evil{block}' >/dev/null 2>&1
assert_rc "rejects braces" "$?" "1"
run_sourced "$SANDBOX" is_valid_host "a/b" >/dev/null 2>&1
assert_rc "rejects slash" "$?" "1"
run_sourced "$SANDBOX" is_valid_host "" >/dev/null 2>&1
assert_rc "rejects empty" "$?" "1"
# #558: length-bound at 253 (a DNS name's max length), mirroring the worker-host charset check
# (resolve_worker_target / validate_worker_endpoints) rather than leaving this one check unbounded.
run_sourced "$SANDBOX" is_valid_host "$(printf 'a%.0s' $(seq 1 253))" >/dev/null 2>&1
assert_rc "accepts 253 chars (the DNS name bound)" "$?" "0"
run_sourced "$SANDBOX" is_valid_host "$(printf 'a%.0s' $(seq 1 254))" >/dev/null 2>&1
assert_rc "rejects 254 chars, past the bound (#558)" "$?" "1"

echo "== unit: first-run epilogue shows once after up (#384) =="
# The "what happens next" onboarding note: prints on the first up in a fresh deploy dir, drops a
# marker beside .env, and stays silent on every later restart.
FR="$(mktemp -d)"
out="$(run_sourced "$FR" print_first_run_epilogue 2>&1)"
assert_contains "first-run: epilogue explains the sync-then-mine hold" "$out" "held until Monero and Tari finish their first sync"
assert_eq "first-run: silent on the second up (marker respected)" \
    "$(run_sourced "$FR" print_first_run_epilogue 2>&1)" ""
rm -rf "$FR"

echo "== unit: host detection (#140) =="
# detect_os reads ID / VERSION_ID / PRETTY_NAME from an overridable os-release (drives the
# 'supported on Ubuntu 24.04' check); a missing file leaves the fields empty (caller warns).
osr="$SANDBOX/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n' >"$osr"
# shellcheck disable=SC1090  # STACK path is dynamic by design
os_out="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    OS_RELEASE_FILE="$osr" detect_os
    printf '%s|%s|%s' "$OS_ID" "$OS_VERSION" "$OS_PRETTY"
)"
assert_eq "detect_os parses os-release" "$os_out" "ubuntu|24.04|Ubuntu 24.04.1 LTS"
# shellcheck disable=SC1090  # STACK path is dynamic by design
os_missing="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    OS_RELEASE_FILE="$SANDBOX/nope" detect_os
    printf '%s' "$OS_ID"
)"
assert_eq "detect_os tolerates a missing file" "$os_missing" ""

# detect_host_timezone: an explicit IANA-shaped TZ wins; garbage falls back to Etc/UTC.
# shellcheck disable=SC1090  # STACK path is dynamic by design
tz_good="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    TZ="America/Chicago" detect_host_timezone
)"
assert_eq "detect_host_timezone honors a valid TZ" "$tz_good" "America/Chicago"
# shellcheck disable=SC1090  # STACK path is dynamic by design
tz_bad="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    TZ="not a zone!" detect_host_timezone
)"
assert_eq "detect_host_timezone rejects garbage -> Etc/UTC" "$tz_bad" "Etc/UTC"

# deps_satisfied is true only when jq/openssl/docker are present AND `docker compose version` works
# (the v2-plugin gate). A docker whose `compose version` fails makes it false.
DEPS="$SANDBOX/deps"
make_stubs "$DEPS/bin"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && PATH="$DEPS/bin:$PATH" && source "$STACK" 2>/dev/null
    set +e
    deps_satisfied
)
assert_rc "deps_satisfied true with all deps" "$?" "0"
printf '#!/usr/bin/env bash\n[ "$*" = "compose version" ] && exit 1\nexit 0\n' >"$DEPS/bin/docker"
chmod +x "$DEPS/bin/docker"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && PATH="$DEPS/bin:$PATH" && source "$STACK" 2>/dev/null
    set +e
    deps_satisfied
)
assert_rc "deps_satisfied false without compose v2" "$?" "1"

echo "== black-box: CLI dispatch =="
"$STACK" help >/dev/null 2>&1
assert_rc "help exits 0" "$?" "0"
assert_contains "help shows usage" "$("$STACK" help 2>&1)" "Usage:"
out="$("$STACK" frobnicate 2>&1)"
rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

echo "== unit: chain validation (#94) =="
# A chain must be judged as a whole BEFORE anything runs. validate_chain error-exits (rc 1) on the
# first broken rule; run_sourced's subshell captures that without killing the suite.
run_sourced "$SANDBOX" validate_chain apply upgrade >/dev/null 2>&1
assert_rc "accepts 'apply upgrade'" "$?" "0"
run_sourced "$SANDBOX" validate_chain apply upgrade status >/dev/null 2>&1
assert_rc "accepts 'apply upgrade status'" "$?" "0"
run_sourced "$SANDBOX" validate_chain upgrade down >/dev/null 2>&1
assert_rc "accepts 'upgrade down' (down last)" "$?" "0"
out="$(run_sourced "$SANDBOX" validate_chain logs status 2>&1)"
assert_rc "rejects non-chainable command (logs)" "$?" "1"
assert_contains "non-chainable message names the command" "$out" "logs"
out="$(run_sourced "$SANDBOX" validate_chain apply apply 2>&1)"
assert_rc "rejects duplicate command" "$?" "1"
assert_contains "duplicate message" "$out" "twice"
out="$(run_sourced "$SANDBOX" validate_chain up down 2>&1)"
assert_rc "rejects 'up down' (contradictory run-state)" "$?" "1"
assert_contains "contradiction message" "$out" "contradict"
run_sourced "$SANDBOX" validate_chain down up >/dev/null 2>&1
assert_rc "rejects 'down up'" "$?" "1"
run_sourced "$SANDBOX" validate_chain up restart >/dev/null 2>&1
assert_rc "rejects 'up restart'" "$?" "1"
out="$(run_sourced "$SANDBOX" validate_chain down upgrade 2>&1)"
assert_rc "rejects 'down upgrade' (down not last)" "$?" "1"
assert_contains "down-not-last message" "$out" "last"

echo "== unit: subcommand flag guard (#493) =="
# `-h/--help` on a subcommand must print help and exit 0 BEFORE any side effect, and a no-option verb
# must reject an unrecognized flag instead of silently ignoring it and running the command anyway
# (`pithead upgrade --help` used to run a full upgrade — the trigger for the #489 DB corruption). Run
# from a NON-deployed sandbox: if the guard failed to short-circuit, `upgrade`/`status` would fall
# through to require_deployed/stack_upgrade — so exit 0 + help text here proves the guard fired first.
CLIG="$SANDBOX/cli-guard"
mkdir -p "$CLIG"
cp "$STACK" "$CLIG/pithead"
out="$(cd "$CLIG" && ./pithead upgrade --help 2>&1)"
assert_rc "upgrade --help exits 0 (no side effect)" "$?" "0"
assert_contains "upgrade --help prints usage" "$out" "Commands"
(cd "$CLIG" && ./pithead upgrade -h >/dev/null 2>&1)
assert_rc "upgrade -h exits 0" "$?" "0"
out="$(cd "$CLIG" && ./pithead upgrade --bogus 2>&1)"
assert_rc "upgrade --bogus errors" "$?" "1"
assert_contains "unknown-flag message names the flag" "$out" "--bogus"
out="$(cd "$CLIG" && ./pithead status --json 2>&1)"
assert_rc "status --json (unknown flag) errors" "$?" "1"
assert_contains "status unknown-flag names the verb" "$out" "status"
# A mutating verb that parses its own args still gets the help short-circuit before it runs.
(cd "$CLIG" && ./pithead apply --help >/dev/null 2>&1)
assert_rc "apply --help exits 0 (no apply)" "$?" "0"
# `logs` is the deliberate passthrough — --help forwards to docker, not the pithead guard (no exit 0
# from our guard). It can't run a real docker here, so just assert the guard didn't hijack it: the
# bare `pithead --help` / `help` still print pithead help and exit 0.
(cd "$CLIG" && ./pithead --help >/dev/null 2>&1)
assert_rc "bare --help still exits 0" "$?" "0"
(cd "$CLIG" && ./pithead help >/dev/null 2>&1)
assert_rc "help command still exits 0" "$?" "0"

echo "== unit: chain execution — order, fail-fast, exit code (#94) =="
# run_chain re-invokes pithead per step via PITHEAD_SELF; a stub records the order and can be told
# to fail a given step, so order/fail-fast/propagation are proven without a stack.
CH="$SANDBOX/chain"
mkdir -p "$CH"
cat >"$CH/fake-pithead" <<'EOF'
#!/usr/bin/env bash
echo "ran $1" >>"$CHAIN_LOG"
[ "$1" = "${CHAIN_FAIL_ON:-}" ] && exit 42
exit 0
EOF
chmod +x "$CH/fake-pithead"
: >"$CH/order.log"
(
    cd "$CH" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    export CHAIN_LOG="$CH/order.log"
    PITHEAD_SELF="$CH/fake-pithead" run_chain apply upgrade status
) >/dev/null 2>&1
assert_rc "valid chain exits 0" "$?" "0"
assert_eq "steps run left-to-right" "$(tr '\n' ',' <"$CH/order.log")" "ran apply,ran upgrade,ran status,"
: >"$CH/order.log"
out="$(
    cd "$CH" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    export CHAIN_LOG="$CH/order.log" CHAIN_FAIL_ON=upgrade
    PITHEAD_SELF="$CH/fake-pithead" run_chain apply upgrade status 2>&1
)"
assert_rc "failing step's exit code propagates (42)" "$?" "42"
assert_eq "fail-fast: later steps never run" "$(tr '\n' ',' <"$CH/order.log")" "ran apply,ran upgrade,"
assert_contains "report names the failed step" "$out" "step 2/3"
assert_contains "report says what already ran" "$out" "Already ran: apply"
assert_contains "report says what did not run" "$out" "Did not run: status"

echo "== black-box: chain wiring — reject runs NOTHING, failure stops the chain (#94) =="
CBX="$SANDBOX/chainbb"
mkdir -p "$CBX"
cp "$STACK" "$CBX/pithead"
make_stubs "$CBX/bin"
out="$(cd "$CBX" && DOCKER_LOG="$CBX/docker.log" PATH="$CBX/bin:$PATH" ./pithead up down 2>&1)"
rc=$?
assert_rc "'up down' rejected" "$rc" "1"
assert_contains "'up down' rejection explains itself" "$out" "contradict"
assert_eq "rejected chain has NO side effects (no docker calls)" "$(cat "$CBX/docker.log" 2>/dev/null)" ""
# A valid chain whose first step fails (status without .env) stops there and reports the remainder.
out="$(cd "$CBX" && PATH="$CBX/bin:$PATH" ./pithead status doctor 2>&1)"
rc=$?
assert_rc "mid-chain failure propagates non-zero" "$rc" "1"
assert_contains "chain reached step 1" "$out" "step 1/2"
assert_contains "chain reports the unrun remainder" "$out" "Did not run: doctor"
# Single-command invocations with arguments are NOT chains: 'logs monerod' hits the normal
# .env guard, not a chain error.
out="$(cd "$CBX" && PATH="$CBX/bin:$PATH" ./pithead logs monerod 2>&1)"
assert_rc "'logs <service>' stays single-command" "$?" "1"
assert_contains "'logs <service>' hits the usual guard" "$out" "setup"
assert_not_contains "'logs <service>' is not judged as a chain" "$out" "chain"

echo "== completion: sources cleanly + no drift from the dispatch (#94) =="
COMP="$ROOT/pithead-completion.bash"
bash -c "source '$COMP'" >/dev/null 2>&1
assert_rc "completion script sources cleanly in bash" "$?" "0"
# Drift-guard: the completion's static list, pithead's PITHEAD_COMMANDS, and the labels of main's
# dispatch case must all be the SAME set — adding/removing a subcommand in one place fails here.
stack_cmds="$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    printf '%s' "${PITHEAD_COMMANDS:-}"
)"
comp_cmds="$(
    # shellcheck disable=SC1090
    source "$COMP" 2>/dev/null
    printf '%s' "${_pithead_commands:-}"
)"
dispatch_cmds="$(sed -n '/case "\$cmd" in/,/^    esac$/p' "$STACK" |
    sed -n -e 's/^    \([a-z][a-z-]*\)).*/\1/p' -e 's/^    \([a-z][a-z-]*\) |.*/\1/p' | tr '\n' ' ')"
dispatch_cmds="${dispatch_cmds% }"
assert_eq "completion list == pithead's command list" "$comp_cmds" "$stack_cmds"
assert_eq "dispatch case labels == pithead's command list" "$dispatch_cmds" "$stack_cmds"
# Every chainable command must be a real command.
chain_ok=1
for c in $(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK" 2>/dev/null
    printf '%s' "${PITHEAD_CHAINABLE:-}"
); do
    case " $stack_cmds " in *" $c "*) ;; *) chain_ok=0 ;; esac
done
assert_eq "chainable commands are a subset of the command list" "$chain_ok" "1"

echo "== completion: suggestions (#94) =="
out="$(bash -c "source '$COMP'; COMP_WORDS=('./pithead' 'up'); COMP_CWORD=1; _pithead; printf '%s\n' \"\${COMPREPLY[@]}\"" 2>/dev/null | tr '\n' ' ')"
assert_eq "'up<tab>' offers up + upgrade" "$out" "up upgrade "
out="$(bash -c "source '$COMP'; COMP_WORDS=('$ROOT/pithead' 'logs' ''); COMP_CWORD=2; _pithead; printf '%s\n' \"\${COMPREPLY[@]}\"" 2>/dev/null | tr '\n' ' ')"
assert_eq "'logs <tab>' offers the compose service names" "$out" "tor monerod wallet-rpc tari tari-wallet p2pool xmrig-proxy dashboard docker-proxy docker-control caddy "
# Bare-name invocation via $PATH from an unrelated cwd must resolve the same way (#566) — a
# symlink in a fake bin dir stands in for a real `$PATH` install.
BAREBIN="$SANDBOX/completion-barebin"
mkdir -p "$BAREBIN"
ln -sf "$ROOT/pithead" "$BAREBIN/pithead"
out="$(cd "$SANDBOX" && PATH="$BAREBIN:$PATH" bash -c "source '$COMP'; COMP_WORDS=('pithead' 'logs' ''); COMP_CWORD=2; _pithead; printf '%s\n' \"\${COMPREPLY[@]}\"" 2>/dev/null | tr '\n' ' ')"
assert_eq "'logs <tab>' resolves via \$PATH bare name from an unrelated cwd" "$out" "tor monerod wallet-rpc tari tari-wallet p2pool xmrig-proxy dashboard docker-proxy docker-control caddy "

echo "== black-box: guards =="
G="$SANDBOX/guard"
mkdir -p "$G/build/tari"
cp "$STACK" "$G/pithead"
cp "$ROOT/build/tari/config.toml.template" "$G/build/tari/" 2>/dev/null || true
make_stubs "$G/bin"
out="$(cd "$G" && PATH="$G/bin:$PATH" ./pithead apply 2>&1)"
rc=$?
assert_rc "apply without .env fails" "$rc" "1"
assert_contains "apply needs setup" "$out" "setup"

echo "== black-box: version subcommand (#386) =="
# The version identity must print offline and exit 0 before any setup, on both a release bundle
# (VERSION present, no Dockerfile) and a source checkout (Dockerfile marker), and read the value
# export_build_provenance computed — no VERSION file falls back to `unknown`, still exit 0.
VER="$SANDBOX/version"
mkdir -p "$VER"
cp "$STACK" "$VER/pithead"
printf '9.9.9\n' >"$VER/VERSION"
out="$(cd "$VER" && ./pithead version)"
rc=$?
assert_rc "version: exits 0" "$rc" "0"
assert_contains "version: prints the VERSION contents" "$out" "v9.9.9"
assert_contains "version: -V alias" "$(cd "$VER" && ./pithead -V)" "v9.9.9"
assert_contains "version: --version alias" "$(cd "$VER" && ./pithead --version)" "v9.9.9"
mkdir -p "$VER/build/dashboard"
: >"$VER/build/dashboard/Dockerfile"
assert_contains "version: source checkout reads dev" "$(cd "$VER" && ./pithead version)" "pithead dev"
rm -rf "$VER/build"
rm -f "$VER/VERSION"
out="$(cd "$VER" && ./pithead version)"
rc=$?
assert_rc "version: no VERSION still exits 0" "$rc" "0"
assert_contains "version: no VERSION -> unknown" "$out" "unknown"
