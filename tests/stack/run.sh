#!/usr/bin/env bash
#
# Dependency-free test suite for pithead (no bats required).
# Mixes unit tests (sourcing pithead and calling its functions) with black-box CLI tests
# (running a sandboxed copy of pithead with docker/sudo stubbed out). Run: tests/stack/run.sh
#
set -uo pipefail

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

# ---------------------------------------------------------------------------
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

echo "== unit: lint-operator-strings self-test (#755) =="
# The operator-strings guard's frontend scanner is non-trivial awk (comment-stripping + CSS-hex-colour
# skip); a silent break would make it stop catching leaks. Its --self-test drives fixtures through the
# real scanners and fails if a planted #NNN is missed or a hex colour/comment is wrongly flagged.
bash "$ROOT/scripts/lint-operator-strings.sh" --self-test >/dev/null 2>&1
assert_rc "operator-strings guard self-test passes" "$?" "0"

echo "== unit: patch-coverage overlap self-test (#1000) =="
# diff-cover exits 0 on "No lines with coverage information" — a vacuous pass. The wrapper's
# overlap check is what turns that into a loud not-applicable pass or a real failure; its
# --self-test drives fixtures through both branches plus the file-present quiet pass.
bash "$ROOT/scripts/patch-coverage.sh" --self-test >/dev/null 2>&1
assert_rc "patch-coverage wrapper self-test passes" "$?" "0"

echo "== unit: is_public_ip classifier (#113) =="
# Globally-routable -> rc 0 (public). Includes boundaries just OUTSIDE each excluded range.
for ip in 8.8.8.8 1.1.1.1 172.15.0.1 172.32.0.1 100.128.0.1 169.1.1.1 2606:4700:4700::1111 2001:db8::1; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1
    assert_rc "public: $ip" "$?" "0"
done
# Private / loopback / link-local / CGNAT / ULA / multicast / unspecified / garbage -> rc 1.
for ip in 10.0.0.5 172.16.0.1 172.31.255.1 192.168.1.50 127.0.0.1 169.254.1.1 100.64.0.1 0.0.0.0 \
    ::1 fe80::1 fc00::1 fd12:3456::1 ff02::1 999.1.1.1 not-an-ip ""; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1
    assert_rc "non-public: ${ip:-<empty>}" "$?" "1"
done

echo "== unit: check_stratum_exposure warning (#113/#206) =="
# The classifier above is unit-tested; this exercises the WARNING COMPOSITION that uses it —
# the bind × public-IP × mode matrix that #206 wanted live-validated. We shadow `ip` with a stub
# emitting canned `ip -o addr show` lines, so the host's real interfaces never decide the outcome.
# STRATUM_BIND is read straight from the env when set, so no .env is needed.
IPBIN="$SANDBOX/ipbin"
mkdir -p "$IPBIN"
make_ip_stub() { # $1 = body for `ip -o addr show`
    {
        printf '#!/usr/bin/env bash\n'
        printf 'cat <<'\''ADDRS'\''\n%s\nADDRS\n' "$1"
    } >"$IPBIN/ip"
    chmod +x "$IPBIN/ip"
}
PUBLIC_IFACE='2: eth0    inet 8.8.8.8/24 scope global eth0'
PRIVATE_IFACE='1: lo    inet 127.0.0.1/8 scope host lo
2: eth0    inet 192.168.1.5/24 scope global eth0'

# Exposed: a public IP on an interface AND stratum on the default all-interfaces bind -> warn.
make_ip_stub "$PUBLIC_IFACE"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_contains "setup warns: public IP + 0.0.0.0 bind" "$out" "public IP"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor WARNs: public IP + 0.0.0.0 bind" "$out" "WARN"

# No public IP on any interface -> quiet in setup; an explicit OK in doctor.
make_ip_stub "$PRIVATE_IFACE"
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_eq "setup is quiet: no public IP" "$out" ""
out="$(STRATUM_BIND=0.0.0.0 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor OK: no public IP" "$out" "No public IP"

# Narrowed bind short-circuits BEFORE the IP check (public stub present): quiet setup / OK doctor.
make_ip_stub "$PUBLIC_IFACE"
out="$(STRATUM_BIND=192.168.1.5 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure setup 2>&1)"
assert_eq "setup is quiet: bind narrowed to a LAN IP" "$out" ""
out="$(STRATUM_BIND=192.168.1.5 PATH="$IPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure doctor 2>&1)"
assert_contains "doctor OK: bind narrowed to a LAN IP" "$out" "not all interfaces"

echo "== unit: doctor runtime checks — egress firewall / stratum listening / dashboard probe (#383) =="
# Each check degrades to an info skip on every can't-check path and only judges what it confirmed.
# Stub the whole toolchain: docker answers the running-container filter from RUNNING_CONTAINERS,
# sudo denies via SUDO_DENY or execs through to the iptables stub (tag presence via IPT_TAGGED),
# ss prints SS_OUT, curl exits CURL_RC.
DRBIN="$SANDBOX/drbin"
mkdir -p "$DRBIN"
cat >"$DRBIN/docker" <<'EOF'
#!/usr/bin/env bash
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z0-9-]*\)\$.*/\1/p')
case " ${RUNNING_CONTAINERS:-} " in *" $name "*) echo cid123 ;; esac
exit 0
EOF
cat >"$DRBIN/sudo" <<'EOF'
#!/usr/bin/env bash
[ "${SUDO_DENY:-0}" = "1" ] && exit 1
[ "$1" = "-n" ] && shift
exec "$@"
EOF
cat >"$DRBIN/iptables" <<'EOF'
#!/usr/bin/env bash
if [ "${IPT_TAGGED:-0}" = "1" ]; then
    echo '-A DOCKER-USER -m comment --comment "pithead-tor-egress" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
else
    echo '-P DOCKER-USER ACCEPT'
fi
EOF
cat >"$DRBIN/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${SS_OUT:-}"
EOF
cat >"$DRBIN/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
EOF
chmod +x "$DRBIN"/*

# container_is_running: filter answered vs not.
RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" container_is_running tor
assert_rc "container_is_running: running container" "$?" "0"
RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" container_is_running tor
assert_rc "container_is_running: stopped container" "$?" "1"

# Egress firewall: opted out -> info skip (reads the toggle from .env).
echo "TOR_EGRESS_FIREWALL=false" >"$SANDBOX/.env"
out="$(RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: opted out -> info" "$out" "opted out"
rm -f "$SANDBOX/.env"
# Stack down (tor not running) -> info skip: rules are legitimately absent after 'down'.
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: stack down -> info" "$out" "isn't running"
# The tor-down-while-mining verdict lives in the dedicated check_tor_running (#563), so the egress
# checks just info-skip when tor is down — they don't double-FAIL the same root cause.
out="$(RUNNING_CONTAINERS="p2pool" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: tor down -> info skip (dedicated check owns the verdict)" "$out" "isn't running"
# check_tor_running: the loud, dedicated privacy-outage verdict.
out="$(RUNNING_CONTAINERS="tor" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: tor up -> OK" "$out" "privacy backbone is up"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: whole stack down -> info" "$out" "stack is down"
out="$(RUNNING_CONTAINERS="p2pool" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_running 2>&1)"
assert_contains "tor-running check: tor down + mining up -> FAIL" "$out" "Tor container is DOWN"
# Running + tagged rules present -> OK.
out="$(RUNNING_CONTAINERS="tor" IPT_TAGGED=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: rules installed -> OK" "$out" "installed"
# Running + rules ABSENT -> FAIL (the post-reboot gap this check exists for).
out="$(RUNNING_CONTAINERS="tor" IPT_TAGGED=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: rules missing -> FAIL" "$out" "MISSING"
# sudo -n denied -> info skip with the manual command, never a prompt or a false FAIL.
out="$(RUNNING_CONTAINERS="tor" SUDO_DENY=1 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_egress_firewall_installed 2>&1)"
assert_contains "egress check: no passwordless sudo -> info" "$out" "passwordless sudo"

# Stratum listening: proxy not running -> info (a sync hold must not FAIL).
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: proxy down -> info" "$out" "isn't running"
# Running + a :3333 listener -> OK.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 0.0.0.0:3333 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: listening -> OK" "$out" "workers can connect"
# An IPv6-only listener ([::]:3333, what ss reports on a dual-stack box) must also read OK —
# pins the ':3333 ' match against the bracketed v6 local-address format.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 [::]:3333 [::]:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: IPv6 listener -> OK" "$out" "workers can connect"
# Running + nothing on :3333 -> FAIL.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 127.0.0.1:8000 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: nothing on :3333 -> FAIL" "$out" "NOTHING is listening"
# A custom p2pool.stratum_port (#172) moves the check: a :3333 listener no longer satisfies it,
# the configured port does.
out="$(RUNNING_CONTAINERS="xmrig-proxy" STRATUM_PORT=4444 SS_OUT='LISTEN 0 4096 0.0.0.0:3333 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: custom port not listening -> FAIL" "$out" "NOTHING is listening on :4444"
out="$(RUNNING_CONTAINERS="xmrig-proxy" STRATUM_PORT=4444 SS_OUT='LISTEN 0 4096 0.0.0.0:4444 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: custom port listening -> OK" "$out" "Stratum :4444 is listening"

# Dashboard probe: container running + app answers -> OK; running + no answer -> WARN (not FAIL).
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: answers -> OK" "$out" "answers on 127.0.0.1:8000"
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=22 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: no answer -> WARN" "$out" "WARN"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: container down -> info" "$out" "isn't running"

# Tor clearnet-egress probe (#424): a bootstrapped Tor on a failing guard breaks clearnet exits
# (Healthchecks/Telegram/XvB) while mining keeps working — the probe WARNs (never FAILs: Tor
# weather is transient) and points at a tor restart. Skips when tor is down or curl is absent.
out="$(RUNNING_CONTAINERS="tor" CURL_RC=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: exit works -> OK" "$out" "clearnet egress works"
out="$(RUNNING_CONTAINERS="tor" CURL_RC=28 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: exit times out -> WARN" "$out" "WARN"
assert_contains "tor egress probe: WARN names the fix" "$out" "restart tor"
out="$(
    RUNNING_CONTAINERS="tor" CURL_RC=28 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1
    echo "rc=$?"
)"
assert_contains "tor egress probe: WARN never fails doctor (rc 0)" "$out" "rc=0"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tor_clearnet_egress 2>&1)"
assert_contains "tor egress probe: tor down -> info skip" "$out" "isn't running"

echo "== unit: doctor answers 'can this box take an upgrade' (#1108) =="
# Each branch mirrors a refusal the one-click upgrade runner makes, so a green line here means the
# runner's preconditions hold. The last branch is the one that did not exist: the verifier is a
# digest-pinned image fetched on demand, and if THAT fetch fails the upgrade reports a *signature*
# failure — an operator reads tampering where the truth is an image the host could not pull (#1084).
DVER="$SANDBOX/doctor-verify"
mkdir -p "$DVER/bin" "$DVER/src/build/dashboard"
: >"$DVER/src/build/dashboard/Dockerfile"
printf '1.19.1\n' >"$DVER/VERSION"
printf '1.19.1\n' >"$DVER/src/VERSION"
# A docker whose daemon is up; IMAGE_CACHED decides whether the pinned verifier is already here.
cat >"$DVER/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
case "$1 $2" in
"info ") exit "${DOCKER_DEAD:-0}" ;;
"image inspect") exit $((1 - ${IMAGE_CACHED:-0})) ;;
esac
exit 0
FAKEDOCKER
chmod +x "$DVER/bin/docker"

# A source checkout cannot take a one-click upgrade at all — the runner refuses it outright.
out="$(PATH="$DVER/bin:$PATH" run_sourced "$DVER/src" check_release_verification 2>&1)"
assert_contains "doctor: a source checkout says one-click does not apply" "$out" "one-click upgrade does not apply"
assert_contains "doctor: a source checkout names the upgrade it CAN take" "$out" "./pithead upgrade"
# A release install predating the first signed release has no key, so nothing is verified.
out="$(PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: no cosign.pub warns that pulls are unverified" "$out" "WARN"
assert_contains "doctor: no cosign.pub says what is missing" "$out" "No cosign.pub next to pithead"
printf 'fake release public key\n' >"$DVER/cosign.pub"
out="$(DOCKER_DEAD=1 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: a dead docker daemon warns rather than claiming verification works" "$out" "WARN"
assert_contains "doctor: the dead-daemon line names the fix" "$out" "Start the Docker daemon"
# The verifier image is present: the box can take an upgrade today.
out="$(IMAGE_CACHED=1 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: a cached verifier image reports OK" "$out" "OK"
assert_contains "doctor: the OK line says nothing needs installing" "$out" "nothing to install"
# The verifier image is NOT here yet. MUTATION PROOF: collapse this branch into the OK above and
# "an absent verifier image is not reported as OK" goes red.
out="$(IMAGE_CACHED=0 PATH="$DVER/bin:$PATH" run_sourced "$DVER" check_release_verification 2>&1)"
assert_contains "doctor: an absent verifier image is not reported as OK" "$out" "WARN"
assert_contains "doctor: the absent-verifier line pre-empts the misleading signature failure" "$out" "even though nothing was tampered with"
assert_contains "doctor: the absent-verifier line names the pre-fetch command" "$out" "docker pull ghcr.io/sigstore/cosign/cosign@sha256:"

echo "== unit: doctor Monero sync check — peer-loss strand (#972) =="
# A monerod stranded by a tor restart keeps a green healthcheck while get_info reports
# synchronized:false — the check trusts the RAW flag (a stranded node can report a stale
# target_height of 0, so height math lies) and WARNs, never FAILs (initial sync reads the same).
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":true,"target_height":0}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: synchronized -> OK" "$out" "reports synchronized"
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":false,"target_height":0,"height":3000000}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: stranded (raw flag false, stale target 0) -> WARN" "$out" "NOT synchronized"
assert_contains "monerod sync: WARN names the fix" "$out" "restart monerod"
out="$(
    RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":false,"target_height":10}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1
    echo "rc=$?"
)"
assert_contains "monerod sync: WARN never fails doctor (rc 0)" "$out" "rc=0"
# RPC not answering (container mid-start) -> info skip; no monerod container (remote mode /
# stack down) -> silent skip, no verdict either way.
out="$(RUNNING_CONTAINERS="monerod" CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod sync: RPC silent -> info skip" "$out" "did not answer"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_eq "monerod sync: no container -> silent skip" "$out" ""

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
echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"
mkdir -p "$BOOT/bin"
cat >"$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.socket enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "neither enabled -> 1" "$?" "1"

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
# (control_worker_apply / validate_worker_endpoints) rather than leaving this one check unbounded.
run_sourced "$SANDBOX" is_valid_host "$(printf 'a%.0s' $(seq 1 253))" >/dev/null 2>&1
assert_rc "accepts 253 chars (the DNS name bound)" "$?" "0"
run_sourced "$SANDBOX" is_valid_host "$(printf 'a%.0s' $(seq 1 254))" >/dev/null 2>&1
assert_rc "rejects 254 chars, past the bound (#558)" "$?" "1"

echo "== unit: describe_change =="
# Monero prune (#719): DISABLE (on → off) forces a full re-sync, host-only DEST; ENABLE (off → on)
# reclaims disk, an operator-intent op — now confirm-gated (CONFIRM), not a flat host-only refuse.
assert_contains "prune disable is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 1 0)" "DEST"
assert_contains "prune enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 0 1)" "CONFIRM"
assert_contains "rpc lan is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_RPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
# LAN exposure of the no-auth node feeds (#760): opening to 0.0.0.0 is DEST in that direction only.
assert_contains "zmq lan is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_ZMQ_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "zmq close is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_ZMQ_BIND 0.0.0.0 127.0.0.1)" "INFO"
assert_contains "tari grpc lan is DEST" "$(run_sourced "$SANDBOX" describe_change TARI_GRPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "tari grpc close is INFO" "$(run_sourced "$SANDBOX" describe_change TARI_GRPC_BIND 0.0.0.0 127.0.0.1)" "INFO"
assert_contains "stratum open is DEST" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum lan is INFO" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 0.0.0.0 127.0.0.1)" "INFO"
# Stratum port (#172/#719): changing it disconnects every rig until repointed — an operator-intent
# repoint, now confirm-gated (CONFIRM); the key's first appearance (an upgrade from a pre-#172 .env)
# is a no-op INFO row, never a scary repoint warning.
assert_contains "stratum port change is CONFIRM" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT 3333 4444)" "CONFIRM"
assert_contains "stratum port change says repoint" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT 3333 4444)" "repoint"
assert_contains "stratum port first render is INFO" "$(run_sourced "$SANDBOX" describe_change STRATUM_PORT '' 3333)" "INFO"
# Caddy LAN port (#740): a real change previews the port; the default->default no-op (the key is
# added empty on the first apply after an upgrade) stays silent so it isn't a scary row.
assert_contains "caddy port change previews the port" "$(run_sourced "$SANDBOX" describe_change HOST_PORT '' 8443)" "Caddy port"
hp_silent="$(run_sourced "$SANDBOX" describe_change HOST_PORT '' '')"
case "$hp_silent" in
*"Caddy port"*) bad "caddy port default->default stays silent" "empty-both HOST_PORT emitted a preview line" ;;
*) ok "caddy port default->default stays silent" ;;
esac
# Stratum access-password (#152): enabling/changing is DEST (rigs need the new pass), disabling is
# INFO — and the secret value must NEVER appear in the change preview.
assert_contains "stratum pw enable is DEST" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" "DEST"
assert_contains "stratum pw disable is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD s3cr3t '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD oldpw newpw)" in
*oldpw* | *newpw*) bad "stratum pw change hides the secret" "value leaked into the change preview" ;;
*DEST*) ok "stratum pw change hides the secret (DEST, no value shown)" ;;
*) bad "stratum pw change hides the secret" "expected DEST" ;;
esac
# Tor guard self-heal toggle (#424): INFO either way, and the enable warns about circuits dropping.
assert_contains "tor auto-heal enable is INFO" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL false true)" "INFO"
assert_contains "tor auto-heal enable names the cost" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL false true)" "drops ALL Tor circuits"
assert_contains "tor auto-heal disable names the manual fix" "$(run_sourced "$SANDBOX" describe_change TOR_AUTO_HEAL true false)" "restart tor"
# Fail-closed miner hold (#490): INFO either way (like TARI_REQUIRED) — it's on the dashboard
# control-channel allowlist, so a DEST flag here would make control_approval_gate refuse every
# commit that touches it, defeating the allowlisting.
assert_contains "fail_closed enable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED false true)" "INFO"
assert_contains "fail_closed enable names the hold" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED false true)" "HOLDS p2pool and xmrig-proxy"
assert_contains "fail_closed disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED true false)" "INFO"
assert_contains "fail_closed disable names alert-only" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_FAIL_CLOSED true false)" "only alerts"
# Dev-fee donate-level (#173): a brief restart (INFO), shown as a percentage.
assert_contains "donate-level is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "INFO"
assert_contains "donate-level shows pct" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "0% → 1%"
# COMPOSE_PROFILES (#552): the payout-confirm profiles (#381/#462) share this key with local_node,
# so the node-switch text must key off the local_node token, not old/new emptiness.
case "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "" tari_payout_confirm)" in
*"LOCAL Monero node"*) bad "payout-confirm enable is not a node switch" "got node-switch text" ;;
*) ok "payout-confirm enable is not a node switch" ;;
esac
case "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "local_node,payout_confirm" local_node)" in
*"LOCAL Monero node"* | *"REMOTE Monero node"*) bad "payout-confirm disable (node stays local) is not a node switch" "got node-switch text" ;;
*) ok "payout-confirm disable (node stays local) is not a node switch" ;;
esac
assert_contains "empty to local_node is a LOCAL switch" "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES "" local_node)" "LOCAL Monero node"
assert_contains "local_node to empty is a REMOTE switch" "$(run_sourced "$SANDBOX" describe_change COMPOSE_PROFILES local_node "")" "REMOTE Monero node"
assert_contains "wallet is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_WALLET_ADDRESS a b)" "DEST"
assert_contains "xvb url is INFO" "$(run_sourced "$SANDBOX" describe_change XVB_POOL_URL a b)" "INFO"
# Data-dir moves (#719): the four service dirs are confirm-gated (an expensive re-sync, not a
# breach); every OTHER data dir (e.g. TOR_DATA_DIR) stays host-only DEST.
assert_contains "monero data_dir is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_DATA_DIR /a /b)" "CONFIRM"
assert_contains "dashboard data_dir is CONFIRM" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_DATA_DIR /a /b)" "CONFIRM"
assert_contains "tor data_dir stays DEST" "$(run_sourced "$SANDBOX" describe_change TOR_DATA_DIR /a /b)" "DEST"
assert_contains "tari mem is INFO" "$(run_sourced "$SANDBOX" describe_change TARI_MEM_LIMIT 2048m 4g)" "INFO"
# Healthchecks.io (#79): the ping URL is the on/off switch AND a capability secret. Setting it says
# ENABLED, clearing it says DISABLED — and the value must NEVER be echoed into the apply preview.
assert_contains "hc enable is INFO" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)" "INFO"
assert_contains "hc set says ENABLED" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)" "ENABLED"
assert_contains "hc clear says DISABLED" "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL https://hc-ping.com/SECRET "")" "DISABLED"
case "$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL "" https://hc-ping.com/SECRET)$(run_sourced "$SANDBOX" describe_change HEALTHCHECKS_PING_URL https://hc-ping.com/OLD https://hc-ping.com/NEW)" in
*SECRET* | *OLD* | *NEW*) bad "hc ping_url not printed" "leaked the ping URL into the preview" ;;
*) ok "hc ping_url not printed" ;;
esac
# Telegram (#121): toggles/events are a brief dashboard restart (INFO); the bot token is a secret,
# so its change line must NOT echo the old/new value.
assert_contains "telegram enable is INFO" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_ENABLED false true)" "INFO"
assert_contains "telegram event is INFO" "$(run_sourced "$SANDBOX" describe_change TELEGRAM_EVENT_NODE_DOWN true false)" "INFO"
tg_tok_msg="$(run_sourced "$SANDBOX" describe_change TELEGRAM_BOT_TOKEN oldsecret newsecret)"
assert_contains "telegram token change noted" "$tg_tok_msg" "Telegram bot token updated"
# Webhook/ntfy sink changes (#380): URLs and the ntfy token are secrets — the preview names the
# change without printing any value.
hook_msg="$(run_sourced "$SANDBOX" describe_change NOTIFY_WEBHOOK_URLS "" "https://hook.example/x?key=HOOKSEC")"
assert_contains "webhook enable noted" "$hook_msg" "Webhook alert sink(s) ENABLED"
case "$hook_msg" in
*HOOKSEC*) bad "webhook url not leaked in preview" "leaked: $hook_msg" ;;
*) ok "webhook url not leaked in preview" ;;
esac
ntfy_msg="$(run_sourced "$SANDBOX" describe_change NTFY_URL "https://ntfy.sh/OLDTOPIC" "https://ntfy.sh/NEWTOPIC")"
assert_contains "ntfy url change noted" "$ntfy_msg" "ntfy topic URL updated"
case "$ntfy_msg" in
*OLDTOPIC* | *NEWTOPIC*) bad "ntfy topic url not leaked in preview" "leaked: $ntfy_msg" ;;
*) ok "ntfy topic url not leaked in preview" ;;
esac
ntfy_tok_msg="$(run_sourced "$SANDBOX" describe_change NTFY_TOKEN oldntfysec newntfysec)"
assert_contains "ntfy token change noted" "$ntfy_tok_msg" "ntfy access token updated"
case "$ntfy_tok_msg" in
*oldntfysec* | *newntfysec*) bad "ntfy token value not leaked in preview" "leaked: $ntfy_tok_msg" ;;
*) ok "ntfy token value not leaked in preview" ;;
esac
assert_contains "notify tor opt-out warns about IP exposure" \
    "$(run_sourced "$SANDBOX" describe_change NOTIFY_TOR true false)" "see this host's IP"
case "$tg_tok_msg" in
*oldsecret* | *newsecret*) bad "telegram token value not leaked in preview" "leaked: $tg_tok_msg" ;;
*) ok "telegram token value not leaked in preview" ;;
esac
assert_contains "monero mem is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "INFO"
assert_contains "monero mem recreate note" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "monerod container is recreated"
# Clearnet initial sync (#183/#719): ENABLING exposes the host IP during IBD — confirm-gated
# (CONFIRM), and the row must spell out the exposure. DISABLING keeps sync on Tor — a plain INFO
# change, no confirm friction.
assert_contains "monero clearnet enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "CONFIRM"
assert_contains "monero clearnet enable warns exposure" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "CLEARNET"
assert_contains "monero clearnet keeps tx on Tor" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "Tor"
assert_contains "monero clearnet disable is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC true false)" "INFO"
assert_contains "tari clearnet enable is CONFIRM" "$(run_sourced "$SANDBOX" describe_change TARI_CLEARNET_SYNC false true)" "CONFIRM"
assert_contains "tari clearnet enable warns exposure" "$(run_sourced "$SANDBOX" describe_change TARI_CLEARNET_SYNC false true)" "CLEARNET"

echo "== unit: p2pool_outbound_flags — Tor-by-default for outbound P2P (#165) =="
# Default (clearnet absent/false) routes outbound sidechain dials through the bundled Tor SOCKS proxy.
assert_eq "default → Tor SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags false 172.28.0)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_eq "empty arg → Tor (default off)" "$(run_sourced "$SANDBOX" p2pool_outbound_flags '' 172.28.0)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
# clearnet opt-out → no SOCKS flags (p2pool dials peers directly, IP exposed).
assert_eq "clearnet=true → no SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags true 172.28.0)" ""
assert_eq "clearnet=yes (any truthy) → no SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags yes 172.28.0)" ""
# Honours a custom bridge subnet (#180) — the Tor container is always .25 of the configured /24.
assert_contains "custom NETWORK_PREFIX points at its Tor (.25)" "$(run_sourced "$SANDBOX" p2pool_outbound_flags false 172.30.5)" "172.30.5.25:9050"

echo "== p2pool entrypoint word-splits P2POOL_FLAGS into separate args (#165) =="
# Compose passes P2POOL_FLAGS as ONE env var (a `- ${VAR}` command item is a single arg, unsplit);
# the entrypoint must word-split it so a multi-flag value reaches p2pool as distinct args. A stub
# p2pool on PATH captures what it's exec'd with.
PE="$SANDBOX/p2pool-ep/bin"
mkdir -p "$PE"
cat >"$PE/p2pool" <<'STUB'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
STUB
chmod +x "$PE/p2pool"
ep_out=$(PATH="$PE:$PATH" P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" bash "$ROOT/build/p2pool/entrypoint.sh" --stratum 0.0.0.0:3333 2>&1)
assert_contains "--socks5 is its own arg" "$ep_out" "ARG=[--socks5]"
assert_contains "socks address is its own arg" "$ep_out" "ARG=[172.28.0.25:9050]"
assert_contains "proxy-type value split out" "$ep_out" "ARG=[tor]"
assert_contains "2 fixed + 5 flag tokens = ARGC 7" "$ep_out" "ARGC=7"
ep_empty=$(PATH="$PE:$PATH" P2POOL_FLAGS="" bash "$ROOT/build/p2pool/entrypoint.sh" --stratum 0.0.0.0:3333 2>&1)
assert_contains "empty P2POOL_FLAGS → no stray empty arg (ARGC=2)" "$ep_empty" "ARGC=2"

echo "== p2pool entrypoint moves the Tari merge-mine gRPC onto loopback under Tor (#278 follow-up) =="
# With --socks5 on, p2pool would dial --merge-mine tari://<private-ip> THROUGH Tor (rejected as an
# RFC1918 address → TRANSIENT_FAILURE). The entrypoint must socat-bridge that node to 127.0.0.1 and
# rewrite the URL host to the loopback IP literal. Stub socat so the test never binds a real port.
SE="$SANDBOX/socat-ep/bin"
mkdir -p "$SE"
cat >"$SE/socat" <<STUB
#!/usr/bin/env bash
printf 'SOCAT=[%s]\n' "\$*" >> "$SANDBOX/socat.log"
STUB
chmod +x "$SE/socat"
: >"$SANDBOX/socat.log"
mm_out=$(PATH="$PE:$SE:$PATH" P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" \
    bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --merge-mine tari://172.28.0.27:18142 WALLET --stratum 0.0.0.0:3333 2>&1)
assert_contains "merge-mine URL rewritten to loopback IP literal" "$mm_out" "ARG=[tari://127.0.0.1:18142]"
assert_not_contains "original private merge-mine IP no longer dialled by p2pool" "$mm_out" "ARG=[tari://172.28.0.27:18142]"
assert_contains "merge-mine wallet arg preserved" "$mm_out" "ARG=[WALLET]"
assert_contains "socat bridges loopback:18142 -> the real Tari node" "$(cat "$SANDBOX/socat.log")" "TCP-LISTEN:18142,bind=127.0.0.1,fork,reuseaddr TCP:172.28.0.27:18142"
# No SOCKS proxy → no rewrite, no bridge (clearnet mode dials the node directly, the gRPC stays put).
: >"$SANDBOX/socat.log"
mm_clear=$(PATH="$PE:$SE:$PATH" P2POOL_FLAGS="--mini" \
    bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine tari://172.28.0.27:18142 WALLET --stratum 0.0.0.0:3333 2>&1)
assert_contains "no --socks5 → merge-mine URL untouched" "$mm_clear" "ARG=[tari://172.28.0.27:18142]"
assert_eq "no --socks5 → no Tari bridge spawned" "$(cat "$SANDBOX/socat.log")" ""

echo "== unit: tor_egress_rules — fail-closed Tor-only egress ruleset (#270) =="
TER=$(run_sourced "$SANDBOX" tor_egress_rules 172.28.0.0/24 172.28.0.25)
assert_contains "ESTABLISHED/RELATED accepted (published-port replies, ongoing flows)" "$TER" "conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
assert_contains "only Tor (.25) may egress to the internet" "$TER" "-s 172.28.0.25 -j ACCEPT"
assert_contains "inter-container + 172.16/12 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 172.16.0.0/12 -j ACCEPT"
assert_contains "10/8 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 10.0.0.0/8 -j ACCEPT"
assert_contains "192.168/16 LAN allowed" "$TER" "-s 172.28.0.0/24 -d 192.168.0.0/16 -j ACCEPT"
assert_eq "the clearnet DROP is the FINAL rule (fail-closed)" "$(printf '%s\n' "$TER" | tail -1)" "-s 172.28.0.0/24 -j DROP"
assert_contains "honours a custom subnet/prefix (#180)" "$(run_sourced "$SANDBOX" tor_egress_rules 172.30.5.0/24 172.30.5.25)" "-s 172.30.5.0/24 -j DROP"

echo "== black-box: apply/remove_tor_egress_firewall via stubbed iptables (#270) =="
FW="$SANDBOX/fw"
mkdir -p "$FW/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FW/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$FW" >"$FW/bin/iptables"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FW/bin/iptables-save" # no pre-existing rules
chmod +x "$FW/bin/sudo" "$FW/bin/iptables" "$FW/bin/iptables-save"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FW/.env"
: >"$FW/ipt.log"
PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
iptlog="$(cat "$FW/ipt.log" 2>/dev/null)"
assert_contains "installs the fail-closed clearnet DROP, tagged" "$iptlog" "-I DOCKER-USER 7 -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "exempts the Tor container" "$iptlog" "-m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
# Pre-creates DOCKER-USER so the BEFORE-compose install at `up` can't miss on a first-ever start where
# Docker hasn't created the chain yet — closes the startup window that grandfathered leaks (#276).
assert_contains "pre-creates the DOCKER-USER chain (idempotently)" "$iptlog" "-N DOCKER-USER"
# opt-out: TOR_EGRESS_FIREWALL=false installs nothing
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=false\n' >"$FW/.env"
: >"$FW/ipt.log"
PATH="$FW/bin:$PATH" run_sourced "$FW" apply_tor_egress_firewall >/dev/null 2>&1
assert_eq "opt-out (network.tor_egress_firewall=false) installs no DROP" "$(grep -c 'DROP' "$FW/ipt.log" 2>/dev/null)" "0"
# install-failure rollback (#270): if an `iptables -I` insert fails partway, apply must NOT leave a
# half-open firewall it believes is fail-closed — it warns and rolls back via remove_tor_egress_firewall.
# Stub: -N/-D succeed but every -I insert fails (rc 1). remove runs once up-front (idempotent clear)
# and again on rollback, so iptables-save fires TWICE — that second call is the proof the rollback ran.
FF="$SANDBOX/fwfail"
mkdir -p "$FF/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$FF/bin/sudo"
cat >"$FF/bin/iptables" <<'IPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$IPT_LOG"
case "$1" in -I) exit 1 ;; esac # every insert fails midway
exit 0
IPT
printf '#!/usr/bin/env bash\nprintf "save\\n" >>"$IPT_LOG"\nexit 0\n' >"$FF/bin/iptables-save"
chmod +x "$FF/bin/sudo" "$FF/bin/iptables" "$FF/bin/iptables-save"
printf 'NETWORK_SUBNET=172.28.0.0/24\nNETWORK_PREFIX=172.28.0\nTOR_EGRESS_FIREWALL=true\n' >"$FF/.env"
: >"$FF/ipt.log"
fwfail_out="$(PATH="$FF/bin:$PATH" IPT_LOG="$FF/ipt.log" run_sourced "$FF" apply_tor_egress_firewall 2>&1)"
fwfail_rc=$?
assert_rc "insert failure degrades gracefully (stack still runs, rc 0)" "$fwfail_rc" "0"
assert_contains "insert failure warns clearnet is NOT fail-closed" "$fwfail_out" "NOT fail-closed"
assert_eq "insert failure rolls back the partial firewall (remove reruns -> save x2)" "$(grep -c '^save$' "$FF/ipt.log")" "2"
# remove: `down` (and every re-apply) strips ONLY our tagged rules — this removal is the precondition
# for the #291 down->upgrade/apply window, so prove it deletes the tags and spares foreign DOCKER-USER
# rules. iptables-save replays two tagged rules + one foreign rule; remove must -D the tagged pair only.
RM="$SANDBOX/rm"
mkdir -p "$RM/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$RM/bin/sudo"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/ipt.log"\n' "$RM" >"$RM/bin/iptables"
cat >"$RM/bin/iptables-save" <<'SAVE'
#!/usr/bin/env bash
cat <<'RULES'
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP
-A DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT
-A DOCKER-USER -j RETURN
RULES
SAVE
chmod +x "$RM/bin/sudo" "$RM/bin/iptables" "$RM/bin/iptables-save"
: >"$RM/ipt.log"
PATH="$RM/bin:$PATH" run_sourced "$RM" remove_tor_egress_firewall >/dev/null 2>&1
rmlog="$(cat "$RM/ipt.log" 2>/dev/null)"
assert_contains "down removes the tagged clearnet DROP" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.0/24 -j DROP"
assert_contains "down removes the tagged Tor-exempt ACCEPT" "$rmlog" "-D DOCKER-USER -m comment --comment pithead-tor-egress -s 172.28.0.25 -j ACCEPT"
assert_not_contains "down leaves foreign DOCKER-USER rules untouched" "$rmlog" "RETURN"

echo "== regression: every command installs the Tor-egress firewall BEFORE compose (#291) =="
# The firewall must go in BEFORE any clearnet-capable container starts, on EVERY path that brings one
# up (#276 closed the window for stack_up; #291 + this change close it for upgrade/apply/reset). If a
# container starts first, the leading ESTABLISHED rule grandfathers its clearnet dial past the DROP.
# Each case neutralises the command's preamble and records the order of the two load-bearing ops; the
# firewall sentinel MUST precede the compose sentinel. fw_then_compose() extracts just those two from
# whatever else the function prints (warnings, banners) so the assert is exact.
fw_then_compose() { printf '%s\n' "$1" | grep -xE 'firewall|compose' | tr '\n' ','; }

# up: the reference path #276 fixed — pin it too so a future reorder of stack_up is caught here.
up_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    stack_up
)
assert_eq "up applies the firewall before 'compose up' (#276)" "$(fw_then_compose "$up_order")" "firewall,compose,"

upg_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$upg_order")" "firewall,compose,"

# #355: `upgrade` must run ensure_onion_password BEFORE parse_and_validate_config, so enabling the
# dashboard onion (#343) with no password auto-generates one (login: admin) instead of failing the
# "onion needs a 16+ char password" validation. setup/apply already do; upgrade didn't (prod hit it).
# This exercises the command-flow ORDER — the wiring the unit test of ensure_onion_password can't see.
upg_onion_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { echo onionpw; }
    parse_and_validate_config() { echo validate; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    stack_upgrade
)
assert_eq "upgrade runs ensure_onion_password before config validation (#355)" \
    "$(printf '%s\n' "$upg_onion_order" | grep -xE 'onionpw|validate' | tr '\n' ',')" "onionpw,validate,"

# #376: on a release install, `upgrade` must verify the image signatures BEFORE anything is pulled
# or recreated. If a refactor drops or reorders the verify_release_images call, "verify" goes
# missing or lands after "compose" and this fails — the wiring half of the fail-closed guarantee
# (the decision itself is black-boxed below).
upg_sig_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade verifies release-image signatures before 'compose up' (#376)" \
    "$(printf '%s\n' "$upg_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

# #452: the FIRST-install `up` must also verify before it pulls — the same wiring guarantee as
# upgrade. A fresh release install's first `up` is where the 5 images are first fetched; if verify
# goes missing or lands after "compose", this fails.
up_sig_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    warn_missing_data_dirs() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    print_clearnet_banner() { :; }
    announce_dashboard_url() { :; }
    print_first_run_epilogue() { :; }
    log() { :; }
    verify_release_images() { echo verify; }
    compose_up_checked() { echo compose; }
    stack_up
)
assert_eq "first-install up verifies release-image signatures before 'compose up' (#452)" \
    "$(printf '%s\n' "$up_sig_order" | grep -xE 'verify|compose' | tr '\n' ',')" "verify,compose,"

echo "== black-box: a failed upgrade never repoints the control-runner units (#1070) =="
# The units are host-global and bake an absolute path. On a one-click deploy stack_upgrade runs from
# the NEW version dir while `current ->` still names the old one, so provisioning them before the
# release is live points them at a dir that may never become the install. That is what bricked
# pithead-prod: the image gate aborted, `current` never moved, and the path unit was left watching a
# spool the running dashboard does not write to — silently killing the control channel, and with it
# the one-click upgrade that would have fixed it. Provisioning must therefore come last, after
# update_current_symlink. Both directions are asserted: the ordering on success, and — the one that
# actually bites — that an abort at the gate repoints nothing at all.
upg_step_order() { # <verify_release_images body> — the step markers stack_upgrade reaches, in order
    (
        cd "$SANDBOX" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        parse_and_validate_config() { :; }
        load_preserved_state() { :; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        render_env() { [ -n "${1:-}" ] && : >"$1"; }
        provision_node_onions() { :; }
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        migrate_dashboard_data() { :; }
        is_source_checkout() { return 1; }
        log() { :; }
        eval "verify_release_images() { $1 }"
        compose_up_checked() { echo compose; }
        update_current_symlink() { echo symlink; }
        provision_control_runner() { echo provision; }
        stack_upgrade
    ) | grep -xE 'verify|compose|symlink|provision' | tr '\n' ','
}
assert_eq "successful upgrade provisions the units only after 'current ->' moves (#1070)" \
    "$(upg_step_order 'echo verify;')" "verify,compose,symlink,provision,"
# The red test for #1070: abort at the image gate, exactly as a host without a runnable verifier
# does. If provisioning ever migrates back above the pull, `provision` reappears here and this fails.
assert_eq "an upgrade that aborts at the gate repoints no units and moves no symlink (#1070)" \
    "$(upg_step_order 'echo verify; error "gate refused";')" "verify,"

echo "== black-box: verify_release_images fail-closed gate (#376) =="
# The verification decision itself, against a fake docker on a PINNED PATH ($VRI/bin:/usr/bin:/bin
# — coreutils stay, so the host can never decide the outcome). Since #1072 the verifier is a
# container, so the stub is `docker`, not `cosign`: it answers the availability probe, pretends the
# pinned image is already present, and logs the cosign argv that follows the image ref — which keeps
# every assertion below reading exactly as it did when cosign was a host binary. A release install
# is a dir without build/dashboard/Dockerfile.
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
VRI="$SANDBOX/verify376"
write_fake_docker "$VRI/bin"
write_unreachable_docker "$VRI/nodocker"

# A deterministic 64-hex digest per image, and a digest-pinned compose (#461) so verify has the same
# @sha256 bytes to check that a release install's compose would pull (#451). TOR_DG is what the tor
# assertions expect the tor image to be verified/failed against.
hex64() { printf "$1%.0s" $(seq 1 64); }
TOR_DG="sha256:$(hex64 1)"
write_pinned_compose() { # $1=dir  — one image: line per first-party suffix, each pinned by @sha256
    local d="$1" n=1 suffix
    : >"$d/docker-compose.yml"
    for suffix in tor monero p2pool xmrig-proxy dashboard; do
        printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-%s:${STACK_VERSION:-dev}@sha256:%s\n' \
            "$suffix" "$(hex64 "$n")" >>"$d/docker-compose.yml"
        n=$((n + 1))
    done
}
write_pinned_compose "$VRI"

# No cosign.pub (an install older than the first signed release): documented fallback — proceed,
# but say loudly that nothing was verified.
out="$(PATH="$VRI/bin:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "no pubkey -> pull proceeds (documented fallback)" "$?" "0"
assert_contains "no pubkey -> loud NOT-verified warning" "$out" "NOT be signature-verified"

# cosign.pub present but the verifier cannot run (docker daemon unreachable): FAIL CLOSED — an
# unavailable verifier must not silently disable verification.
printf 'fake release public key' >"$VRI/cosign.pub"
out="$(PATH="$VRI/nodocker:/usr/bin:/bin" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "pubkey without a runnable verifier -> pull aborts" "$?" "1"
assert_contains "verifier-missing abort names docker, not a host cosign" "$out" "docker is not available"

# Valid signatures (fake cosign exits 0): all 5 images verified with the committed key, no Rekor
# (--private-infrastructure), against the EXACT @sha256 digest compose pins and pulls (#451 — bound
# to the same bytes, not the mutable tag).
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "valid signatures -> pull proceeds" "$?" "0"
assert_eq "all 5 first-party images verified" "$(grep -c '^\[cosign\] verify ' "$VRI/cosign.log")" "5"
assert_contains "verify binds to the pinned digest, not the tag (#451)" \
    "$(cat "$VRI/cosign.log")" "verify --key cosign.pub --private-infrastructure ghcr.io/test/pithead-tor@$TOR_DG"
assert_not_contains "verify never resolves the mutable tag (#451)" "$(cat "$VRI/cosign.log")" "pithead-tor:v9.9.9"

# A signature that does not verify (fake cosign exits 1): FAIL CLOSED. This is the red test for the
# whole feature — bypass or soften the verification and it goes green-to-broken.
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 \
    PITHEAD_REGISTRY="ghcr.io/test" STACK_VERSION="v9.9.9" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "bad signature -> pull aborts (fail closed)" "$?" "1"
assert_contains "bad-signature abort names the pinned image" "$out" "Signature verification FAILED for ghcr.io/test/pithead-tor@$TOR_DG"

# cosign.pub present but the compose is NOT digest-pinned (a pre-#461 or tampered bundle): FAIL
# CLOSED (#451). Without a digest there's nothing to bind verification to the pulled bytes, so the
# verify-then-pull window can't be closed — refuse rather than fall back to verifying the tag.
UNPINNED="$SANDBOX/verify451-unpinned"
mkdir -p "$UNPINNED"
printf 'fake release public key' >"$UNPINNED/cosign.pub"
printf '    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-tor:${STACK_VERSION:-dev}\n' >"$UNPINNED/docker-compose.yml"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_LOG="$VRI/cosign.log" run_sourced "$UNPINNED" verify_release_images 2>&1)"
assert_rc "un-pinned compose + key -> pull aborts (#451)" "$?" "1"
assert_contains "un-pinned abort explains the missing digest bind" "$out" "not digest-pinned"
assert_eq "un-pinned -> cosign never asked to verify a tag" "$(cat "$VRI/cosign.log")" ""

# #557: run_sourced disables errexit (`set +e`, right after sourcing) for every test above, which
# happens to mask a real bug: the bare `sha="$(compose_pinned_digest ...)"` assignment aborts under
# pithead's own `set -Eeuo pipefail` BEFORE the crafted error() above ever runs, so a real invocation
# got a silent abort instead of the "not digest-pinned" diagnostic. Reproduce with errexit left ON —
# source directly and call the function, no run_sourced/`set +e`.
# shellcheck disable=SC1090  # dynamic source: the script under test
out557_vri="$(
    (
        cd "$UNPINNED" || exit 1
        PATH="$VRI/bin:/usr/bin:/bin"
        source "$STACK" 2>/dev/null
        verify_release_images
    ) 2>&1
)"
assert_rc "un-pinned + key, real errexit -> still aborts (#557)" "$?" "1"
assert_contains "un-pinned + key, real errexit -> crafted message still reaches the operator (#557)" \
    "$out557_vri" "not digest-pinned"

# Source checkout: locally built images are unsigned by design — skipped, silently and completely.
mkdir -p "$VRI/build/dashboard"
touch "$VRI/build/dashboard/Dockerfile"
: >"$VRI/cosign.log"
out="$(PATH="$VRI/bin:/usr/bin:/bin" COSIGN_RC=1 COSIGN_LOG="$VRI/cosign.log" run_sourced "$VRI" verify_release_images 2>&1)"
assert_rc "source checkout -> verification skipped" "$?" "0"
assert_eq "source checkout -> cosign never invoked" "$(cat "$VRI/cosign.log")" ""
rm -rf "$VRI/build"

echo "== unit: cosign_container_path maps host paths into the verifier's mount (#1072) =="
# The verifier container sees the install dir at /w, so every file argument has to be renamed into
# that mount. The refusal case is the one that matters: both callers report a cosign failure as a
# SIGNATURE failure, so a path this function got wrong would read as a tampered download and burn a
# genuine release. It must fail rather than emit a path the mount does not cover.
CCP="$SANDBOX/ccp"
mkdir -p "$CCP/data/control/staged"
touch "$CCP/cosign.pub" "$CCP/data/control/staged/.abc.tar.gz"
assert_eq "file beside pithead -> /w/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/cosign.pub")" "/w/cosign.pub"
assert_eq "staged bundle -> /w/<relative dirs>/<name>" \
    "$(run_sourced "$CCP" cosign_container_path "$CCP/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
# The `current -> pithead-vX.Y.Z` layout: CONTROL_DIR in .env can name the same file through the
# symlink while the runner's cwd is the physical dir. Canonicalizing both sides is what makes these
# agree — a plain "${path#$PWD/}" prefix strip silently does not, and would fail closed on prod.
ln -sfn "$CCP" "$SANDBOX/ccp-current"
assert_eq "same file reached via the current symlink still resolves" \
    "$(run_sourced "$CCP" cosign_container_path "$SANDBOX/ccp-current/data/control/staged/.abc.tar.gz")" \
    "/w/data/control/staged/.abc.tar.gz"
run_sourced "$CCP" cosign_container_path "$SANDBOX/outside.txt" >/dev/null 2>&1
assert_rc "a path outside the install dir is refused, not guessed at" "$?" "1"
run_sourced "$CCP" cosign_container_path "/etc/hosts" >/dev/null 2>&1
assert_rc "an absolute path elsewhere on the box is refused" "$?" "1"

# apply had the same after-compose ordering bug as #272's stack_upgrade — fixed alongside #291. Take
# the no-change-but-incomplete-marker retry path so apply recreates containers without the interactive
# diff (env_changed_keys returns nothing; a pre-seeded .apply-incomplete marker forces the retry).
apply_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034  # read by the sourced apply()'s "not provisioned" guard, unseen here
    P2POOL_ONION=onion
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    is_deployed() { return 0; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    env_changed_keys() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { echo firewall; }
    compose_up_checked() { echo compose; }
    : >".env.apply-incomplete" # force the retry path
    apply
)
assert_eq "apply applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$apply_order")" "firewall,compose,"

# reset-dashboard recreates p2pool (clearnet-capable); on a `down` stack it must install the firewall
# first or p2pool comes up with no firewall at all. -y skips the destructive confirm; the docker stub
# emits the compose sentinel only for the `compose up` it ends on.
rd_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    env_get() { echo "/nonexistent/reset-$1"; } # non-existent dirs -> rm skipped
    assert_safe_dir() { :; }
    mkdir() { :; }
    sudo() { :; }
    log() { :; }
    docker() {
        [ "$1 $2" = "compose up" ] && echo compose
        return 0
    }
    apply_tor_egress_firewall() { echo firewall; }
    reset_dashboard -y
)
assert_eq "reset-dashboard applies the firewall before 'compose up' (#291)" "$(fw_then_compose "$rd_order")" "firewall,compose,"

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
    TOR_DATA_DIR="$SANDBOX/pd-tor"
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

echo "== unit: config_bool honours an explicit false (jq // false-coercion guard, #294) =="
# Regression for #294: `.x // true` returns true even when x is explicitly false (jq treats false as
# empty), which silently broke the #270 firewall opt-out (config false → .env stayed true) and
# xvb.tor=false. config_bool null-checks instead. CONFIG_FILE is the relative "config.json", so a
# fixture in the cwd is what the sourced helper reads.
CB="$SANDBOX/cb"
mkdir -p "$CB"
printf '{"network":{"tor_egress_firewall":false},"xvb":{"tor":false}}' >"$CB/config.json"
assert_eq "explicit false honoured (firewall)" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "false"
assert_eq "explicit false honoured (xvb.tor)" "$(run_sourced "$CB" config_bool '.xvb.tor' true)" "false"
printf '{"network":{"tor_egress_firewall":true}}' >"$CB/config.json"
assert_eq "explicit true honoured" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
printf '{}' >"$CB/config.json"
assert_eq "absent -> default true" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
assert_eq "absent -> default false" "$(run_sourced "$CB" config_bool '.xvb.tor' false)" "false"

echo "== unit: monero_prune_flag maps prune bool -> 1/0, honouring explicit false (#294) =="
# render_env + preflight both size disk off this flag; an explicit prune:false must yield 0, not the
# pruned default of 1. Missing config falls back to pruned (1).
printf '{"monero":{"prune":false}}' >"$CB/config.json"
assert_eq "explicit false -> 0" "$(run_sourced "$CB" monero_prune_flag)" "0"
printf '{"monero":{"prune":true}}' >"$CB/config.json"
assert_eq "explicit true -> 1" "$(run_sourced "$CB" monero_prune_flag)" "1"
printf '{}' >"$CB/config.json"
assert_eq "absent -> 1 (pruned default)" "$(run_sourced "$CB" monero_prune_flag)" "1"
rm -f "$CB/config.json"
assert_eq "missing config -> 1 (pruned default)" "$(run_sourced "$CB" monero_prune_flag)" "1"

echo "== unit: clearnet initial sync helpers (#183) =="
# normalize_bool: 1/true/yes/on (any case) => true; everything else (incl. empty) => false, matching
# the dashboard's MONERO_PRUNE truthiness so a config bool reads the same on both sides.
for v in true 1 YES On TRUE; do
    assert_eq "normalize_bool '$v' => true" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "true"
done
for v in false 0 no off "" garbage; do
    assert_eq "normalize_bool '${v:-<empty>}' => false" "$(run_sourced "$SANDBOX" normalize_bool "$v")" "false"
done
# Monero render transform (#183): exercise the REAL container entrypoint function. Sourced with
# PITHEAD_TEST_SOURCE=1 it defines the helpers and stops before envsubst/exec. The transform must
# strip the Tor P2P proxy + lower out-peers, while KEEPING tx-proxy on Tor.
MONT="$SANDBOX/mon-clearnet.conf"
cp "$ROOT/build/monero/bitmonero.conf.template" "$MONT"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/entrypoint.sh"
    apply_clearnet_initial_sync "$MONT"
)
case "$(grep -E '^proxy=' "$MONT" || true)" in
"") ok "monero clearnet: P2P proxy= line stripped (#183)" ;;
*) bad "monero clearnet: P2P proxy= line stripped (#183)" "still present" ;;
esac
assert_contains "monero clearnet: tx-proxy stays on Tor (#183)" "$(cat "$MONT")" "tx-proxy=tor"
# P2Pool v4.16 clearnet recommendation: out-peers 32 + the recommended priority nodes (added only in
# the clearnet window; the Tor template has neither — the #161 check below guards that).
assert_contains "monero clearnet: out-peers=32 (p2pool v4.16 rec)" "$(cat "$MONT")" "out-peers=32"
assert_contains "monero clearnet: xmrvsbeast priority node (v4.16)" "$(cat "$MONT")" "add-priority-node=p2pmd.xmrvsbeast.com:18080"
assert_contains "monero clearnet: hashvault priority node (v4.16)" "$(cat "$MONT")" "add-priority-node=nodes.hashvault.pro:18080"
# The committed template (the Tor-only default) keeps the proxy line + the Tor-tuned out-peers.
assert_contains "monero default: Tor P2P proxy present (#183)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'proxy=${NETWORK_PREFIX}.25:9050'
# #595: the template's out-peers is now config-driven (monero.out_peers, default 48 in the render).
assert_contains "monero default: out-peers config-driven for Tor (#183/#595)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" 'out-peers=${MONERO_OUT_PEERS}'
# Compose wires both flags into container env: monerod reads MONERO_CLEARNET_SYNC in its entrypoint;
# TARI_CLEARNET_SYNC is inert in the container but its presence makes a flag change recreate tari so
# it re-reads the host-rendered config.toml (a bind-mount content change alone won't recreate it).
assert_contains "compose passes MONERO_CLEARNET_SYNC to monerod (#183)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_CLEARNET_SYNC=${MONERO_CLEARNET_SYNC'
assert_contains "compose passes TARI_CLEARNET_SYNC to tari (#183)" "$(cat "$ROOT/docker-compose.yml")" 'TARI_CLEARNET_SYNC=${TARI_CLEARNET_SYNC'
# #595: the render chain for the out-peers knob is only complete if compose forwards it.
assert_contains "compose passes MONERO_OUT_PEERS to monerod (#595)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_OUT_PEERS=${MONERO_OUT_PEERS'

# --- Auto-transition (#234): the entrypoints gate clearnet on flag AND the absence of the
# dashboard-written marker, so a node returns to Tor on its own once synced. ---
# Monero entrypoint marker gate.
mono_active() { (
    export PITHEAD_TEST_SOURCE=1 MONERO_CLEARNET_SYNC="$1" CLEARNET_MARKER="$2"
    source "$ROOT/build/monero/entrypoint.sh"
    clearnet_sync_active
); }
if mono_active true "$SANDBOX/absent-marker"; then ok "monero clearnet ACTIVE when flag on + no marker (#234)"; else bad "monero clearnet active gate (#234)" "expected active"; fi
: >"$SANDBOX/mono.marker"
if mono_active true "$SANDBOX/mono.marker"; then bad "monero clearnet inactive once marker present (#234)" "still active"; else ok "monero clearnet INACTIVE once marker present → Tor (#234)"; fi
if mono_active false "$SANDBOX/absent-marker"; then bad "monero clearnet off when flag off (#234)" "active with flag off"; else ok "monero clearnet OFF when flag off (#234)"; fi

# Tari entrypoint renders a runtime config from the canonical Tor config; transform only when active.
TARISRC="$SANDBOX/tari-src.toml"
cp "$ROOT/build/tari/config.toml.template" "$TARISRC"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/absent-marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt.toml"
)
assert_contains "tari entrypoint clearnet: TCP transport (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'type = "tcp"'
assert_contains "tari entrypoint clearnet: DNS seed enabled (#234)" "$(cat "$SANDBOX/tari-rt.toml")" 'dns_seeds = ["seeds.tari.com"]'
: >"$SANDBOX/tari.marker"
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1 TARI_CLEARNET_SYNC=true CLEARNET_MARKER="$SANDBOX/tari.marker"
    source "$ROOT/build/tari/entrypoint.sh"
    render_tari_runtime_config "$TARISRC" "$SANDBOX/tari-rt2.toml"
)
assert_contains "tari entrypoint marker→Tor: transport tor (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" 'type = "tor"'
assert_contains "tari entrypoint marker→Tor: DNS seeds empty (#234)" "$(cat "$SANDBOX/tari-rt2.toml")" "dns_seeds = []"
assert_contains "tari entrypoint never mutates the canonical config (#234)" "$(cat "$TARISRC")" 'type = "tor"'
# Compose wires the shared marker dir into all three: dashboard rw, monerod + tari ro, + the tari
# wrapper entrypoint that chains to the upstream start_tari_app.sh.
assert_contains "compose mounts clearnet-state into monerod (#234)" "$(cat "$ROOT/docker-compose.yml")" ':/clearnet-state:ro'
assert_contains "compose wires the tari wrapper entrypoint (#234)" "$(cat "$ROOT/docker-compose.yml")" '/var/tari/config/entrypoint.sh'

# --- Wallet entrypoint (#381/#714): the view-only create-from-keys JSON must OMIT the spend key.
# monero-wallet-rpc v0.18 parses an empty-string "spendkey":"" as a secret key and aborts wallet
# creation ("failed to parse spend key secret key"), so the field's ABSENCE — not "" — is what
# lets the payout wallet build. This exercises the REAL entrypoint's write_gen_json.
echo "== unit: wallet-entrypoint view-only gen.json omits spendkey (#714) =="
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    export GEN_JSON="$SANDBOX/wallet-gen.json" WALLET_FILE="$SANDBOX/payout-wallet"
    export MONERO_WALLET_ADDRESS="48exampleAddr" MONERO_VIEW_KEY="deadbeefdeadbeef"
    write_gen_json 3000000
)
WGEN="$(cat "$SANDBOX/wallet-gen.json")"
if printf '%s' "$WGEN" | jq -e . >/dev/null 2>&1; then ok "wallet gen.json is valid JSON (#714)"; else bad "wallet gen.json is valid JSON (#714)" "jq rejected: $WGEN"; fi
assert_eq "wallet gen.json carries the address (#381)" "$(printf '%s' "$WGEN" | jq -r .address)" "48exampleAddr"
assert_eq "wallet gen.json carries the view key (#381)" "$(printf '%s' "$WGEN" | jq -r .viewkey)" "deadbeefdeadbeef"
assert_eq "wallet gen.json scan_from_height verbatim (#381)" "$(printf '%s' "$WGEN" | jq -r .scan_from_height)" "3000000"
# THE REGRESSION GUARD: a revert to "spendkey":"" crashes monero-wallet-rpc (#714). Field must be absent.
assert_eq "wallet gen.json OMITS spendkey — monero rejects an empty one (#714)" "$(printf '%s' "$WGEN" | jq 'has("spendkey")')" "false"
# Restore height: "auto"/empty means genesis (0) so the wallet scans the FULL payout history; an
# explicit height is used verbatim to skip the long scan.
rsh() { (
    export PITHEAD_TEST_SOURCE=1 PAYOUT_SCAN_HEIGHT="$1"
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    resolve_scan_height
); }
assert_eq "scan height: auto -> genesis 0 (full payout history)" "$(rsh auto)" "0"
assert_eq "scan height: empty -> genesis 0" "$(rsh '')" "0"
assert_eq "scan height: explicit block kept verbatim" "$(rsh 2500000)" "2500000"

# Wallet healthcheck (#718): during the multi-hour genesis scan monero-wallet-rpc refuses the RPC,
# so the check must tolerate an unreachable RPC WHILE the initial-scan marker is present, and turn
# strict once the RPC first answers. Stub `curl` on PATH to be the RPC up/down control.
HCBIN="$SANDBOX/hc-bin"
HCDIR="$SANDBOX/hc-wallet"
mkdir -p "$HCBIN" "$HCDIR"
mk_curl() {
    printf '#!/bin/sh\nexit %s\n' "$1" >"$HCBIN/curl"
    chmod +x "$HCBIN/curl"
}
run_hc() { (
    PATH="$HCBIN:$PATH" WALLET_DIR="$HCDIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
    echo $?
); }
# RPC down + marker present (mid initial scan) -> healthy (the whole point of #718).
mk_curl 7
: >"$HCDIR/.payout-scanning"
assert_eq "healthcheck: RPC down but scanning -> healthy (#718)" "$(run_hc)" "0"
# RPC up -> healthy AND the marker is retired (scan caught up; strict from now on).
mk_curl 0
assert_eq "healthcheck: RPC up -> healthy (#718)" "$(run_hc)" "0"
if [ -f "$HCDIR/.payout-scanning" ]; then bad "healthcheck: RPC up clears the scan marker (#718)" "marker still present"; else ok "healthcheck: RPC up clears the scan marker (#718)"; fi
# RPC down + NO marker (scan already finished once) -> unhealthy: a real fault, not scan tolerance.
mk_curl 7
assert_eq "healthcheck: RPC down after scan done -> unhealthy (#718)" "$(run_hc)" "1"
# The entrypoint arms the marker on wallet creation so the grace applies from first boot.
assert_contains "wallet-entrypoint touches the scan marker on create (#718)" "$(cat "$ROOT/build/monero/wallet-entrypoint.sh")" 'touch "$SCAN_MARKER"'

echo "== unit: clock_sync_status (mining is time-sensitive) =="
# doctor's NTP check classifies timedatectl's NTPSynchronized: yes→synced, no→unsynced, else unknown.
CLKBIN="$SANDBOX/clk-bin"
mkdir -p "$CLKBIN"
mk_timedatectl() {
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\n' "$1" >"$CLKBIN/timedatectl"
    chmod +x "$CLKBIN/timedatectl"
}
mk_timedatectl "yes"
assert_eq "clock_sync_status: NTP yes => synced" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "synced"
mk_timedatectl "no"
assert_eq "clock_sync_status: NTP no => unsynced" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "unsynced"
mk_timedatectl ""
assert_eq "clock_sync_status: blank => unknown" "$(PATH="$CLKBIN:$PATH" run_sourced "$SANDBOX" clock_sync_status)" "unknown"

echo "== unit: monero_address_type — p2pool needs a PRIMARY address (#250) =="
# Classify by network-byte prefix + length: primary 4…/95 (the only payable kind), integrated 4…/106,
# subaddress 8…/95. setup/apply hard-fail anything but primary so nobody mines to an unpayable address.
_a94="$(printf 'a%.0s' $(seq 94))"
_a93="$(printf 'a%.0s' $(seq 93))"
_a105="$(printf 'a%.0s' $(seq 105))"
assert_eq "monero_address_type: 4…/95  => primary" "$(run_sourced "$SANDBOX" monero_address_type "4$_a94")" "primary"
assert_eq "monero_address_type: 8…/95  => subaddress" "$(run_sourced "$SANDBOX" monero_address_type "8$_a94")" "subaddress"
assert_eq "monero_address_type: 4…/106 => integrated" "$(run_sourced "$SANDBOX" monero_address_type "4$_a105")" "integrated"
assert_eq "monero_address_type: 4…/94  => invalid" "$(run_sourced "$SANDBOX" monero_address_type "4$_a93")" "invalid"
assert_eq "monero_address_type: other  => invalid" "$(run_sourced "$SANDBOX" monero_address_type "1abc")" "invalid"

echo "== unit: dashboard auth (#8) =="
# Dashboard login (#8): enabling/changing is DEST (caddy is recreated), disabling is INFO. The bcrypt
# hash is a secret and must never surface in the change preview; the internal fingerprint stays silent.
assert_contains "dash login enable is DEST" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 '' aGFzaA==)" "DEST"
assert_contains "dash login disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 aGFzaA== '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 b2xkSA== bmV3SA==)" in
*b2xkSA==* | *bmV3SA==*) bad "dash login change hides the hash" "hash value leaked into the change preview" ;;
*DEST*) ok "dash login change hides the hash (DEST, no value shown)" ;;
*) bad "dash login change hides the hash" "expected DEST" ;;
esac
assert_contains "dash login username change is shown" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_USER admin bob)" "admin → bob"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_PW_FP aaa bbb)" in
*PW_FP* | *updated* | *fingerprint*) bad "dash login fingerprint stays silent" "internal fingerprint surfaced in the preview" ;;
INFO*) ok "dash login fingerprint stays silent (no preview line)" ;;
*) bad "dash login fingerprint stays silent" "unexpected message emitted" ;;
esac

# Dashboard onion (#343): enabling is DEST (tor+caddy recreated); the client PRIVATE key must never
# surface in the change preview, even though a fresh key co-changes with the toggle.
assert_contains "onion enable is DEST" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_ONION_ENABLED false true)" "DEST"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_ONION_CLIENT_PRIVKEY OLDPRIVKEYVALUE NEWPRIVKEYVALUE)" in
*OLDPRIVKEYVALUE* | *NEWPRIVKEYVALUE*) bad "onion client privkey hidden in preview" "the client private key leaked into the change preview" ;;
*) ok "onion client privkey hidden in preview (no value shown)" ;;
esac

# New-release check toggle (#224): enabling/disabling is INFO, and the message names GitHub + Tor.
assert_contains "update-check enable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "INFO"
assert_contains "update-check enable mentions GitHub/Tor" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "GitHub"
assert_contains "update-check disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES true false)" "no longer contacts GitHub"

# generate_caddyfile renders a basic_auth block ONLY when a hash is configured, carrying the username
# and the *decoded* bcrypt string Caddy expects; with no hash the dashboard stays open (no basic_auth).
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_on="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddy renders basic_auth when login set" "$caddy_on" "basic_auth"
assert_contains "caddy basic_auth carries the username" "$caddy_on" "admin"
assert_contains "caddy basic_auth carries decoded hash" "$caddy_on" '$2y$14$UNITTESTbcrypthashvalue'
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_off="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
case "$caddy_off" in
*basic_auth*) bad "caddy stays open when no login set" "basic_auth rendered without a password" ;;
*) ok "caddy stays open when no login set (no basic_auth)" ;;
esac

echo "== unit: generate_caddyfile scheme (#140) =="
# The HTTPS-vs-HTTP choice is security-relevant: secure -> https:// + `tls internal`; insecure ->
# plain http:// and no TLS directive. (Auth on/off is covered in the dashboard-auth block above.)
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddyfile secure uses https" "$caddy_https" "https://box.lan"
assert_contains "caddyfile secure enables TLS" "$caddy_https" "tls internal"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_http="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=false HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "caddyfile insecure uses http" "$caddy_http" "http://box.lan"
case "$caddy_http" in
*"tls internal"*) bad "caddyfile insecure has no TLS" "'tls internal' present on a plain-HTTP site" ;;
*) ok "caddyfile insecure has no TLS" ;;
esac

echo "== unit: generate_caddyfile custom port (#740) =="
# A custom HOST_PORT moves the LAN vhost off the scheme default so a co-hosted reverse proxy keeps
# 80/443. In HTTPS mode it also emits the global `auto_https disable_redirects` so nothing holds :80.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=8443 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "custom https port binds the site" "$caddy_port_https" "https://box.lan:8443 {"
assert_contains "custom https port disables the :80 redirect" "$caddy_port_https" "auto_https disable_redirects"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_http="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=false HOST_IP=box.lan HOST_PORT=8080 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "custom http port binds the site" "$caddy_port_http" "http://box.lan:8080 {"
case "$caddy_port_http" in
*"disable_redirects"*) bad "plain-HTTP custom port has no redirect global" "'disable_redirects' present on a plain-HTTP site" ;;
*) ok "plain-HTTP custom port has no redirect global" ;;
esac
# A port that equals the scheme default (443 secure / unset) renders the same site address as an
# unset one — no port suffix. It still takes :80 over from auto_https (see #1123 below), which is
# what separates it from the custom-port case: there, :80 is deliberately left to a fronting proxy.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_default="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=443 DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "explicit default port keeps the bare site address" "$caddy_port_default" "https://box.lan {"
case "$caddy_port_default" in
*":443"*) bad "default port emits no explicit suffix" "':443' suffix present at the scheme default" ;;
*) ok "default port renders the bare site address" ;;
esac

echo "== unit: the :80 redirect cannot be steered by the Host header (#1123) =="
# Caddy's built-in HTTP->HTTPS redirect is a CATCH-ALL whose target is the request's own Host
# header, so a provisioned box answered `Host: evil.example` on :80 with `308 -> https://evil.example`
# — measured on a running machine. That is #1118's open redirector again, in the state the machine
# spends its life in, and it lands on the screen where the operator types the dashboard password.
# The render now disables the built-in redirects and serves :80 itself with a FIXED target.
# MUTATION PROOF: render `redir https://{host}{uri}` instead of the literal host, or drop the
# `auto_https disable_redirects`, and the two assertions below go red.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_redir="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "the default secure render takes :80 over from auto_https" "$caddy_redir" "auto_https disable_redirects"
assert_contains "it serves :80 itself" "$caddy_redir" "http:// {"
assert_contains "and redirects to the box, by name, not to whatever was asked for" "$caddy_redir" \
    "redir https://box.lan{uri} 308"
# The whole defect in one assertion: no redirect target may be built from the request. Caddy spells
# the request's host `{host}` (and `{http.request.host}`), so neither may appear in a redir line.
caddy_redir_lines="$(printf '%s\n' "$caddy_redir" | grep -a "redir" || true)"
case "$caddy_redir_lines" in
*"{host}"* | *"{http.request.host}"*) bad "no redirect target comes from the request" "a redir line interpolates the request host: $caddy_redir_lines" ;;
*) ok "no redirect target comes from the request" ;;
esac
# A custom port means a fronting proxy owns :80 (#740). Taking it over there would break exactly the
# co-hosting the option exists for, so the catch-all is the default path's alone.
case "$caddy_port_https" in
*"http:// {"*) bad "a custom port leaves :80 to the fronting proxy" "the render claimed :80 anyway" ;;
*) ok "a custom port leaves :80 to the fronting proxy" ;;
esac
# Plain-HTTP mode has no redirect to steer: :80 IS the dashboard there.
case "$caddy_http" in
*"redir"*) bad "plain-HTTP mode renders no redirect at all" "a redir line appeared on a plain-HTTP site" ;;
*) ok "plain-HTTP mode renders no redirect at all" ;;
esac
# Onion + custom LAN port together (#740 × #343): the LAN vhost moves to the custom port and the
# `disable_redirects` global is emitted, but the onion vhost MUST stay on the bridge gateway's bare
# :80 — Tor's HiddenServicePort maps 80 -> NETWORK_PREFIX.1:80, so a custom LAN port must not leak
# onto it. Also confirms the global-options block is still valid Caddyfile with onion vhosts appended.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_port_onion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan HOST_PORT=8443 DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion+custom-port: LAN vhost moves to the custom port" "$caddy_port_onion" "https://box.lan:8443 {"
assert_contains "onion+custom-port: redirect global still emitted" "$caddy_port_onion" "auto_https disable_redirects"
assert_contains "onion+custom-port: onion vhost stays on the bridge's bare :80" "$caddy_port_onion" "http://172.28.0.1 {"
case "$caddy_port_onion" in
*"172.28.0.1:8443"* | *"172.28.0.1:80 "*) bad "onion vhost keeps its bare bridge port" "custom LAN port leaked onto the onion vhost" ;;
*) ok "onion vhost keeps its bare bridge port (no custom-port leak)" ;;
esac

echo "== unit: generate_caddyfile onion vhost (#343) =="
# With the dashboard onion enabled, generate_caddyfile appends a SECOND site bound to the bridge
# gateway (NETWORK_PREFIX.1) — reachable only from the tor container, never the LAN — serving plain
# HTTP (Tor is the transport) and carrying the SAME basic_auth block as the LAN site.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion vhost bound to the bridge gateway" "$caddy_onion" "http://172.28.0.1 {"
assert_contains "onion vhost carries basic_auth" "$caddy_onion" "basic_auth"
# The onion site (everything after the gateway address) must not get a TLS directive.
onion_site="${caddy_onion#*172.28.0.1}"
case "$onion_site" in
*"tls internal"*) bad "onion vhost is plain HTTP" "'tls internal' present on the onion site" ;;
*) ok "onion vhost is plain HTTP (no tls internal)" ;;
esac
# Fail-closed belt: onion enabled but NO auth hash -> generate_caddyfile must refuse (rc 1).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" \
        DASHBOARD_ONION_ENABLED=true NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
)
assert_rc "onion without a login refuses to render" "$?" "1"
# Onion OFF -> no gateway vhost appears at all.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_noonion="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=false NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_not_contains "no onion vhost when disabled" "$caddy_noonion" "172.28.0.1"
# Once the .onion address is provisioned, ALSO render an HTTPS onion vhost (self-signed cert for the
# .onion name) so Tor Browser's default http->https upgrade lands on a working :443 (#343). Both the
# http (:80, bridge IP) and https (:443, .onion name) onion sites must be present.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcd234onionname.onion NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost still present with the address set (#343)" "$caddy_onion_https" "http://172.28.0.1 {"
assert_contains "onion HTTPS vhost on the .onion name (#343)" "$caddy_onion_https" "https://abcd234onionname.onion {"
https_site="${caddy_onion_https#*https://abcd234onionname.onion}"
case "$https_site" in
*"tls internal"*) ok "onion HTTPS vhost uses a self-signed cert (tls internal)" ;;
*) bad "onion HTTPS vhost uses tls internal" "no 'tls internal' on the https onion site" ;;
esac
assert_contains "onion HTTPS vhost carries the same basic_auth (#343)" "$https_site" "basic_auth"
# Not yet provisioned (placeholder address) -> HTTP onion vhost only, no HTTPS one (a later apply adds it).
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_ph="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=placeholder NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "onion HTTP vhost renders even before the address is captured (#343)" "$caddy_onion_ph" "http://172.28.0.1 {"
assert_not_contains "no HTTPS onion vhost until the .onion address is provisioned (#343)" "$caddy_onion_ph" "https://placeholder"

echo "== unit: generate_caddyfile access log (#349) =="
# Every vhost logs each request as one JSON line to a shared file. Growth is bounded by Caddy's
# native rolling (4 MiB per file, current + 2 rolled); mode 0644 lets the non-root dashboard
# read what root-run Caddy writes (Caddy's own default is 0600, unreadable across the mount).
assert_contains "access log block rendered" "$caddy_https" "output file /var/log/caddy/access.log"
assert_contains "access log is JSON" "$caddy_https" "format json"
assert_contains "access log growth is bounded (roll_size)" "$caddy_https" "roll_size 4MiB"
assert_contains "rolled files are capped (roll_keep)" "$caddy_https" "roll_keep 2"
assert_contains "access log stays dashboard-readable (mode 0644)" "$caddy_https" "mode 0644"
log_count="$(printf '%s' "$caddy_onion_https" | grep -c 'output file /var/log/caddy/access.log')"
assert_eq "every vhost (LAN + onion HTTP + onion HTTPS) writes the shared log" "$log_count" "3"

echo "== unit: onion client-auth crypto (#343) =="
# Portable base32 (RFC 4648 vectors) — no external `base32` binary (absent on macOS).
assert_eq "b32encode_hex('f') = MY" "$(run_sourced "$SANDBOX" b32encode_hex 66)" "MY"
assert_eq "b32encode_hex('foobar') = MZXW6YTBOI" "$(run_sourced "$SANDBOX" b32encode_hex 666f6f626172)" "MZXW6YTBOI"
# x25519 client-auth keypair: two distinct 52-char base32 keys.
kp="$(run_sourced "$SANDBOX" generate_onion_client_keypair)"
set -- $kp
assert_eq "client pubkey is 52-char base32" "${#1}" "52"
assert_eq "client privkey is 52-char base32" "${#2}" "52"
if [ "$1" != "$2" ]; then ok "client pub != priv"; else bad "client pub != priv" "identical keys generated"; fi
case "$1$2" in *[!A-Z2-7]*) bad "client keys use the base32 alphabet" "non-base32 char present" ;; *) ok "client keys use the base32 alphabet" ;; esac

# provision_onion_client_auth writes the authorized_clients descriptor into the hidden-service dir.
ac_root="$SANDBOX/tor-ac"
rm -rf "$ac_root"
mkdir -p "$ac_root"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    ensure_owner() { :; } # skip the sudo chown in the unit sandbox
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=true \
        DASHBOARD_ONION_CLIENT_PUBKEY=placeholder TOR_DATA_DIR="$ac_root" \
        APP_UID=$(id -u) APP_GID=$(id -g) provision_onion_client_auth >/dev/null 2>&1
)
ac_file="$ac_root/dashboard/authorized_clients/dashboard.auth"
if [ -f "$ac_file" ]; then ok "authorized_clients/dashboard.auth is written"; else bad "authorized_clients/dashboard.auth is written" "file missing"; fi
assert_contains "authorized_clients carries a v3 descriptor" "$(cat "$ac_file" 2>/dev/null)" "descriptor:x25519:"
# Tor refuses a HiddenServiceDir that is group/other-accessible, so the modes provision_onion_client_auth
# sets (pithead ~L3096-3099) are load-bearing, not a hardening nicety — a wrong mode is a silent onion
# provisioning failure. GNU stat first (CI/Linux), BSD/macOS `-f %Lp` fallback (the repo's known gotcha:
# `stat -f` is a VALID-but-wrong flag on Linux, so it must never run first).
ac_dir_mode="$(stat -c '%a' "$ac_root/dashboard" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard" 2>/dev/null)"
ac_subdir_mode="$(stat -c '%a' "$ac_root/dashboard/authorized_clients" 2>/dev/null || stat -f '%Lp' "$ac_root/dashboard/authorized_clients" 2>/dev/null)"
ac_key_mode="$(stat -c '%a' "$ac_file" 2>/dev/null || stat -f '%Lp' "$ac_file" 2>/dev/null)"
assert_eq "hidden-service dir is 0700" "$ac_dir_mode" "700"
assert_eq "authorized_clients dir is 0700" "$ac_subdir_mode" "700"
assert_eq "authorized_clients key file is 0600" "$ac_key_mode" "600"
# With client-auth OFF, an existing authorized_clients dir is cleared (onion falls back to password-only).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION_CLIENT_AUTH=false TOR_DATA_DIR="$ac_root" \
        provision_onion_client_auth >/dev/null 2>&1
)
if [ -d "$ac_root/dashboard/authorized_clients" ]; then bad "client-auth off clears authorized_clients" "dir still present"; else ok "client-auth off clears authorized_clients"; fi

echo "== unit: ensure_onion_password auto-generates (#343) =="
# Onion on + no password -> generate a strong one into config.json (login stays admin), so the
# fail-closed onion is usable without the operator inventing a 16+ char secret. CONFIG_FILE is
# readonly (config.json in the cwd), so drive it via a dedicated dir rather than an override.
autopw_dir="$SANDBOX/onion-autopw"
mkdir -p "$autopw_dir"
autopw_cfg="$autopw_dir/config.json"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$autopw_cfg"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
genpw="$(jq -r '.dashboard.auth.password // ""' "$autopw_cfg")"
if [ "${#genpw}" -ge 16 ]; then ok "ensure_onion_password writes a >=16-char password"; else bad "ensure_onion_password writes a >=16-char password" "length ${#genpw}"; fi
# Idempotent: a second run leaves an already-set password alone (no churn).
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password leaves an existing password alone" "$(jq -r '.dashboard.auth.password' "$autopw_cfg")" "$genpw"
# No-op when the onion is off — never touches config.json.
printf '{"dashboard":{}}' >"$autopw_cfg"
# shellcheck disable=SC1090  # STACK path is dynamic by design
(cd "$autopw_dir" && source "$STACK" 2>/dev/null && ensure_onion_password >/dev/null 2>&1)
assert_eq "ensure_onion_password no-op when onion off" "$(jq -r '.dashboard.auth.password // "none"' "$autopw_cfg")" "none"

# Regression: stack_upgrade must run ensure_onion_password BEFORE parse_and_validate_config (as
# setup/apply do), so enabling the onion with no password on a deployed stack auto-generates one
# instead of erroring at the validation gate. Drive the REAL ensure_onion_password through
# stack_upgrade with everything downstream stubbed; onion-on + no password must end with a >=16-char pw.
upg_autopw_dir="$SANDBOX/upgrade-onion-autopw"
mkdir -p "$upg_autopw_dir"
printf '{"dashboard":{"onion":{"enabled":true}}}' >"$upg_autopw_dir/config.json"
(
    cd "$upg_autopw_dir" || exit
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    # NB: mv is left REAL — ensure_onion_password uses it to commit the generated password. The only
    # other mv here (.env.new swap) is a harmless no-op on the stubbed-away .env.new.
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    is_source_checkout() { return 1; }
    docker() { :; }
    log() { :; }
    stack_upgrade >/dev/null 2>&1
)
upg_genpw="$(jq -r '.dashboard.auth.password // ""' "$upg_autopw_dir/config.json")"
if [ "${#upg_genpw}" -ge 16 ]; then ok "upgrade auto-generates the onion password (not an error)"; else bad "upgrade auto-generates the onion password (not an error)" "length ${#upg_genpw}"; fi

echo "== black-box: rotate-dashboard-onion command flow (#356) =="
# The rotate command reprovisions the onion then persists via render_env. It must (a) resolve the host
# so HOST_IP is set for render_env — rotate skipped that and crashed on the unbound var under set -u —
# and (b) preserve DEPLOYMENT_COMPLETED, which render_env would otherwise reset to false, breaking the
# next apply/upgrade. Drive the real command with stubs; render_env reports the two values it would write.
rot_out=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$SANDBOX/rot-tor"
    mkdir -p "$TOR_DATA_DIR/dashboard"
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { [ "$1" = "DEPLOYMENT_COMPLETED" ] && echo true || echo "x.onion"; }
    resolve_dashboard_host() { HOST_IP="host.set"; }
    provision_tor() { :; }
    render_env() { echo "HOST_IP=${HOST_IP-UNSET} DC=${DEPLOYMENT_COMPLETED-UNSET}"; }
    onion_client_key() { :; }
    rotate_dashboard_onion -y
)
assert_contains "rotate resolves the host before render_env — no unbound HOST_IP (#356)" "$rot_out" "HOST_IP=host.set"
assert_contains "rotate preserves DEPLOYMENT_COMPLETED across render_env (#356)" "$rot_out" "DC=true"

echo "== black-box: upgrade captures a just-enabled dashboard onion address (#356) =="
# Enabling the onion via `upgrade` must read the freshly-generated .onion back into .env; apply's
# capture only runs when the config changed, so an upgrade-based enable left the address uncaptured.
upg_capture() { # <onion_enabled> <current_onion> -> "captured" when provision runs, "caddyfile-rendered" per generate_caddyfile call
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { echo caddyfile-rendered; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    provision_dashboard_onion() {
        DASHBOARD_ONION="upgcap5678.onion"
        echo captured
    }
    export DASHBOARD_ONION_ENABLED="$1"
    export DASHBOARD_ONION="$2"
    stack_upgrade
}
assert_contains "upgrade captures the onion address when enabled + uncaptured (#356)" "$(upg_capture true '')" "captured"
assert_not_contains "upgrade skips capture when the onion is disabled (#356)" "$(upg_capture false '')" "captured"

# #546: the upgrade-path capture must ALSO regenerate the Caddyfile — the render preamble ran while
# the address was still the placeholder, so a capture without a re-render leaves the HTTPS onion
# vhost missing forever (the next apply no-ops on an unchanged config). Count generate_caddyfile
# calls: once from the preamble, a second time only when the capture leg runs.
upg_regen_on=$(upg_capture true '' | grep -c "caddyfile-rendered")
case "$upg_regen_on" in
2) ok "upgrade capture regenerates the Caddyfile (#546)" ;;
*) bad "upgrade capture regenerates the Caddyfile (#546)" "generate_caddyfile ran $upg_regen_on time(s), want 2 (preamble + capture)" ;;
esac
upg_regen_off=$(upg_capture false '' | grep -c "caddyfile-rendered")
case "$upg_regen_off" in
1) ok "upgrade without onion renders the Caddyfile once (#546)" ;;
*) bad "upgrade without onion renders the Caddyfile once (#546)" "generate_caddyfile ran $upg_regen_off time(s), want 1" ;;
esac

echo "== black-box: apply captures + renders the HTTPS onion vhost in the SAME run (#546) =="
# Before the fix, apply's post-up capture block (provision_dashboard_onion && render_env) never
# re-ran generate_caddyfile, so the https://<onion> vhost (#360) only appeared on some LATER,
# unrelated apply — a re-apply that changed nothing hit the "No configuration changes detected"
# early return before ever reaching generate_caddyfile. Drive the real apply() with the heavy
# machinery stubbed away but generate_caddyfile left REAL, so the Caddyfile is the actual proof.
AOC="$SANDBOX/apply-onion-capture"
mkdir -p "$AOC"
printf 'DEPLOYMENT_COMPLETED=true\n' >"$AOC/.env"
caddy_apply_capture=$(
    cd "$AOC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    env_changed_keys() { echo DASHBOARD_ONION_ENABLED; }
    inject_service_configs() { :; }
    provision_onion_client_auth() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { :; }
    compose_up_checked() { :; }
    announce_dashboard_url() { :; }
    log() { :; }
    warn() { :; }
    docker() { :; }
    # The shadowed capture: the address is unknown until the recreated tor container publishes it
    # post-up, exactly like the real provision_dashboard_onion.
    provision_dashboard_onion() { DASHBOARD_ONION="captured1234abcd.onion"; }
    P2POOL_ONION=p2pa.onion HOST_IP=box.lan DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 DASHBOARD_ONION_ENABLED=true \
        DASHBOARD_ONION=placeholder apply -y >/dev/null 2>&1
    cat Caddyfile
)
assert_contains "apply: HTTPS onion vhost appears in the SAME apply run (#546)" "$caddy_apply_capture" "https://captured1234abcd.onion {"
assert_contains "apply: HTTP onion vhost (bridge gateway) still present" "$caddy_apply_capture" "http://172.28.0.1 {"

echo "== black-box: rotate-dashboard-onion regenerates the Caddyfile (#546) =="
# Before the fix, rotate restarted caddy WITHOUT regenerating the Caddyfile, so caddy kept serving
# the retired onion's HTTPS vhost and the new address had none. Seed a Caddyfile as if a PRIOR
# generate_caddyfile ran for the old address, then rotate with a shadowed provision_tor that
# returns a new one — the fix must leave exactly the new address's vhost behind.
ROC="$SANDBOX/rotate-onion-capture"
mkdir -p "$ROC/rot-tor/dashboard"
cat >"$ROC/Caddyfile" <<'EOF'
https://box.lan {
    tls internal
}

http://172.28.0.1 {
}

https://oldaddr1234.onion {
    tls internal
}
EOF
caddy_rotate_capture=$(
    cd "$ROC" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    warn() { :; }
    log() { :; }
    docker() { :; }
    sudo() { :; }
    env_get() { :; }
    render_env() { :; }
    resolve_dashboard_host() { HOST_IP=box.lan; }
    # The shadowed provision the issue asks for: a fresh address on rotate.
    provision_tor() { DASHBOARD_ONION="newaddr5678.onion"; }
    onion_client_key() { :; }
    export DASHBOARD_ONION_ENABLED=true
    export DASHBOARD_ONION_CLIENT_AUTH=false
    TOR_DATA_DIR="$ROC/rot-tor" DASHBOARD_SECURE=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$auth_hb64" NETWORK_PREFIX=172.28.0 rotate_dashboard_onion -y >/dev/null 2>&1
    cat Caddyfile
)
assert_not_contains "rotate drops the retired onion's HTTPS vhost (#546)" "$caddy_rotate_capture" "oldaddr1234.onion"
assert_contains "rotate adds the new onion's HTTPS vhost in the same run (#546)" "$caddy_rotate_capture" "https://newaddr5678.onion {"

echo "== unit: dashboard_onion_status surfaces the onion URL for status/doctor (#343) =="
# The shared resolver behind both `pithead status` and `pithead doctor`: it returns the onion URL +
# reach-it hint ONLY when the onion is enabled AND provisioned, and NEVER the client private key.
onion_env_dir() { # <enabled> <address> <client_auth> -> a dir whose .env carries those keys
    local d
    d="$(mktemp -d)"
    {
        echo "DASHBOARD_ONION_ENABLED=$1"
        echo "DASHBOARD_ONION_ADDRESS=$2"
        echo "DASHBOARD_ONION_CLIENT_AUTH=$3"
    } >"$d/.env"
    echo "$d"
}
od_on="$(onion_env_dir true abcd.onion true)"
# Enabled + provisioned + client-auth: URL plus the pointer to onion-client-key (assert the stable
# prefix — the trailing "'<path> onion-client-key'" varies with $0).
assert_contains "status onion: URL + client-key pointer when client-auth on" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "http://abcd.onion (client-auth ON + login; get your client key with"
# And it must NOT leak a client private key.
assert_not_contains "status onion: never prints a client key" \
    "$(run_sourced "$od_on" dashboard_onion_status)" "descriptor:x25519:"
od_noauth="$(onion_env_dir true abcd.onion false)"
assert_eq "status onion: login-required line when client-auth off" \
    "$(run_sourced "$od_noauth" dashboard_onion_status)" "http://abcd.onion (login required)"
od_unprov="$(onion_env_dir true placeholder true)"
assert_eq "status onion: nothing while unprovisioned (placeholder)" \
    "$(run_sourced "$od_unprov" dashboard_onion_status)" ""
od_off="$(onion_env_dir false abcd.onion true)"
assert_eq "status onion: nothing when the onion is disabled" \
    "$(run_sourced "$od_off" dashboard_onion_status)" ""
rm -rf "$od_on" "$od_noauth" "$od_unprov" "$od_off"

echo "== unit: dashboard_sync_progress re-renders per-chain sync from /api/state (#384) =="
# The one-curl re-render behind `pithead status`: read the dashboard's own /api/state (host-local,
# no auth) and print per-chain progress, skipping synced chains and degrading quietly when the app
# isn't up. Stub curl to serve a canned body — real jq parses it, matching the dashboard's shape.
SP="$(mktemp -d)"
mkdir -p "$SP/bin"
cat >"$SP/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${CURL_BODY:-}" ] && printf '%s' "$CURL_BODY"
exit "${CURL_RC:-0}"
EOF
chmod +x "$SP/bin/curl"
# Monero mid-sync + Tari still discovering its target height: both surface, monero with numbers.
sp_body='{"sync":{"monero":{"state":"syncing","percent":87,"current":2451000,"target":2810000,"remaining":359000},"tari":{"state":"loading","percent":0,"current":0,"target":0,"remaining":0}}}'
out="$(CURL_BODY="$sp_body" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "sync progress: monero syncing shows percent + blocks-to-go" "$out" "87% (2451000 / 2810000 blocks, 359000 to go)"
assert_contains "sync progress: no-target chain reads as discovering" "$out" "discovering the target height"
assert_contains "sync progress: header names the #35 hold" "$out" "held until it completes"
# Both synced: nothing to say (steady-state status stays quiet), non-zero return.
sp_done='{"sync":{"monero":{"state":"done","percent":100,"current":10,"target":10,"remaining":0},"tari":{"state":"done","percent":100,"current":5,"target":5,"remaining":0}}}'
assert_eq "sync progress: both synced -> silent" \
    "$(CURL_BODY="$sp_done" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)" ""
# Only monero still syncing: the synced tari is omitted (not listed as done).
sp_partial='{"sync":{"monero":{"state":"syncing","percent":42,"current":100,"target":238,"remaining":138},"tari":{"state":"done","percent":100,"current":5,"target":5,"remaining":0}}}'
out="$(CURL_BODY="$sp_partial" PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)"
assert_contains "sync progress: partial -> monero listed" "$out" "monero"
assert_not_contains "sync progress: partial -> synced tari omitted" "$out" "tari"
# Dashboard app not answering yet (curl fails): quiet, non-zero — graceful during startup.
assert_eq "sync progress: dashboard down -> silent" \
    "$(CURL_RC=22 PATH="$SP/bin:$PATH" run_sourced "$SANDBOX" dashboard_sync_progress 2>&1)" ""
rm -rf "$SP"

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

echo "== unit: release.sh pure logic (#44) =="
# The release pipeline's side-effect-free helpers (no docker needed). Sourced from the repo root with
# the positional args cleared (`set --`) so release.sh's own arg-parser doesn't see the test's args;
# release.sh guards its main() behind a BASH_SOURCE check, so sourcing only defines the functions.
REL="$ROOT/scripts/release.sh"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "0.1.0"
)
assert_rc "is_semver accepts 0.1.0" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "1.2.3-rc.1"
)
assert_rc "is_semver accepts a prerelease" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "1.2"
)
assert_rc "is_semver rejects a partial" "$?" "1"
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    is_semver "v1.2.3"
)
assert_rc "is_semver rejects a leading v" "$?" "1"
# shellcheck disable=SC1090
assert_eq "image_for builds the GHCR image name" \
    "$(
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        image_for dashboard
    )" \
    "ghcr.io/p2pool-starter-stack/pithead-dashboard"
# --draft (#44): documented in --help, and --help stops at the comment header (a too-wide sed range
# used to leak the script body, e.g. `set -euo pipefail`, into the help output).
assert_contains "release --help documents --draft" "$(bash "$REL" --help 2>&1)" "--draft"
case "$(bash "$REL" --help 2>&1)" in
*"set -euo pipefail"*) bad "release --help stops at the comment header" "leaked the script body into --help" ;;
*) ok "release --help stops at the comment header" ;;
esac
# Bundle completeness: the pull-based bundle must ship every ./build/* path the compose MOUNTS at
# runtime. A pull install builds nothing and the images don't bake these in, so a missing one mounts an
# empty dir and breaks the container — the v1.0.0 bundle shipped without monerod's bitmonero.conf.template
# exactly this way. compose_build_mounts derives the list make_bundle copies.
# shellcheck disable=SC1090
BUILD_MOUNTS="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    compose_build_mounts docker-compose.yml
)"
assert_contains "bundle ships monerod's config template" "$BUILD_MOUNTS" "./build/monero/bitmonero.conf.template"
assert_contains "bundle ships the tari config dir" "$BUILD_MOUNTS" "./build/tari"
# The bundle must ship the BASIC config template (the documented quick-start config — `cp
# config.minimal.json config.json`) and unpack to a versionless `pithead/` dir for the stable
# /releases/latest/download/pithead.tar.gz URL. Build a real bundle and inspect it.
# shellcheck disable=SC1090,SC2034  # dynamic source; TAG/REGISTRY/DRY_RUN are consumed inside make_bundle
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SANDBOX/bundle"
    mkdir -p "$WORKDIR"
    TAG=v9.9.9
    REGISTRY=ghcr.io/test
    DRY_RUN=0
    # make_bundle now digest-pins the first-party images (#376), so it needs the promoted digests
    # promote would have captured -- a full repo@sha256 ref, as set_digest stores them.
    for _s in "${IMAGES[@]}"; do set_digest "$_s" "ghcr.io/test/pithead-$_s@sha256:feed${_s}dad"; done
    make_bundle "$WORKDIR/pithead.tar.gz" >/dev/null 2>&1
    cp "$WORKDIR/pithead/docker-compose.yml" "$SANDBOX/bundle-compose.yml" 2>/dev/null || true
    tar tzf "$WORKDIR/pithead.tar.gz" 2>/dev/null
) >"$SANDBOX/bundle.list" 2>/dev/null
grep -q '^pithead/config.minimal.json$' "$SANDBOX/bundle.list" && ok "bundle ships config.minimal.json (basic quick-start config)" || bad "bundle ships config.minimal.json" "absent from the bundle"
grep -q '^pithead/$' "$SANDBOX/bundle.list" && ok "bundle unpacks to versionless pithead/" || bad "bundle unpacks to pithead/" "top-level dir is not pithead/"
# Every first-party image line in the bundled compose must be digest-pinned (#376).
_bundle_unpinned=$(grep -E 'pithead-(tor|monero|p2pool|xmrig-proxy|dashboard):' "$SANDBOX/bundle-compose.yml" 2>/dev/null | grep -cv '@sha256:')
[ "${_bundle_unpinned:-1}" -eq 0 ] && ok "bundle compose digest-pins all 5 first-party images (#376)" || bad "bundle digest-pins first-party images (#376)" "unpinned lines: ${_bundle_unpinned:-?}"
if grep -q 'pithead-dashboard:${STACK_VERSION:-dev}@sha256:feeddashboarddad' "$SANDBOX/bundle-compose.yml" 2>/dev/null; then
    ok "digest pin appends only the bare sha256, no double-repo (#376)"
else
    bad "digest pin format (#376)" "expected tag@sha256:digest on the dashboard image line"
fi
_bm_missing=""
for _m in $BUILD_MOUNTS; do [ -e "$ROOT/$_m" ] || _bm_missing="$_bm_missing $_m"; done
assert_eq "every compose ./build runtime mount exists in the tree" "${_bm_missing:-none}" "none"
case "$BUILD_MOUNTS" in
*Dockerfile*) bad "bundle build-mounts exclude Dockerfiles" "a Dockerfile would flip the bundle pull->build mode" ;;
*) ok "bundle build-mounts exclude Dockerfiles" ;;
esac
# Target-arch guard: the release MUST build linux/amd64 (the bundled binaries are x86_64; xmrig-proxy
# has no arm64 build, so the stack can't be arm64). A plain host-arch `docker build` on an arm64 dev box
# shipped arm64-labelled images that don't run on x86_64 — the v1.0.0 defect. Assert the pipeline builds
# via buildx (which forces the target arch even on an arm64 host), defaults to amd64, and that smoke
# rejects a wrong-arch push.
REL_SRC="$(cat "$REL")"
assert_contains "release builds with buildx (forces the target arch)" "$REL_SRC" "docker buildx build"
PLAT_DEF="$(grep -E '^PLATFORMS=' "$REL" | head -1)"
case "$PLAT_DEF" in
*linux/amd64*) ok "release targets linux/amd64 (the x86_64 binaries' platform)" ;;
*) bad "release targets linux/amd64" "PLATFORMS default: $PLAT_DEF" ;;
esac
assert_contains "smoke stage verifies the pushed image's target platform" "$REL_SRC" "missing target platform"
# write_manifest's "- **Version:**" line starts with a dash; without `printf --` it died with
# "printf: - : invalid option" and broke the whole publish stage. Render it and assert it survives.
man_out="$SANDBOX/manifest.md"
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside write_manifest
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    TAG="v9.9.9"
    STACK_VERSION="9.9.9"
    GIT_COMMIT="abc1234"
    BUILD_DATE="now"
    WORKDIR="$SANDBOX"
    write_manifest "$man_out"
) 2>/dev/null
assert_contains "manifest renders the leading-dash Version line (printf --)" "$(cat "$man_out" 2>/dev/null)" "- **Version:** 9.9.9"
# The ingredients manifest's component pins must resolve to a real value present in each Dockerfile —
# a drift guard so a renamed ARG can't silently emit an empty pin in the release notes.
for svc in p2pool monero xmrig-proxy; do
    # shellcheck disable=SC1090
    pv="$(
        cd "$ROOT" || exit
        set --
        source "$REL" 2>/dev/null
        set +eu
        pin "$svc"
    )"
    if [ -n "$pv" ] && grep -q -- "$pv" "$ROOT/build/$svc/Dockerfile"; then
        ok "pin $svc resolves to a value in its Dockerfile"
    else
        bad "pin $svc resolves to a value in its Dockerfile" "got '$pv'"
    fi
done
# The top-level VERSION file is the single source of truth (#44); the dashboard's Python package
# metadata must stay in lockstep so a release can't ship two different "stack versions".
ver_file="$(tr -d ' \t\r\n' <"$ROOT/VERSION")"
ver_pyproject="$(grep -oE '^version = "[^"]+"' "$ROOT/build/dashboard/pyproject.toml" | head -1 | cut -d'"' -f2)"
assert_eq "pyproject.toml version matches VERSION (#44)" "$ver_pyproject" "$ver_file"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/build/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"
    t_rest="${tier#*:}"
    t_val="${t_rest%%:*}"
    t_human="${t_rest#*:}"
    if grep -qE ": ${t_val}[ ,]" "$tier_cfg" && grep -qF "$t_human" "$tier_doc"; then
        ok "XvB $t_name tier: config.py $t_val matches docs '$t_human'"
    else
        bad "XvB $t_name tier docs match TIER_DEFAULTS" "config $t_val / doc '$t_human' out of sync"
    fi
done

echo "== unit: release.sh registry read retries GHCR read-after-push lag (#429) =="
# manifest_digest reads a tag GHCR just accepted, which can 404 for a few seconds (read-after-push
# lag) — this killed stage-4 digest capture twice on v1.3.1. retry_registry_read must retry until the
# read resolves. Stub buildx_inspect to fail the first two calls (empty + rc 1) then succeed; a counter
# file survives the retries. Backoff forced to 0 keeps the test instant.
RETRY_CNT="$SANDBOX/inspect.count"
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
retry_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    printf 0 >"$RETRY_CNT"
    buildx_inspect() {
        local n
        n=$(($(cat "$RETRY_CNT") + 1))
        printf '%s' "$n" >"$RETRY_CNT"
        [ "$n" -lt 3 ] && return 1                  # attempts 1 and 2 fail (tag not yet readable)
        printf 'Name: x\nDigest: sha256:deadbeef\n' # attempt 3 resolves
    }
    printf 'DIGEST=%s ATTEMPTS=%s\n' "$(manifest_digest some:tag)" "$(cat "$RETRY_CNT")"
)"
assert_contains "manifest_digest resolves after transient GHCR failures" "$retry_out" "DIGEST=sha256:deadbeef"
assert_contains "retried until the read succeeded (3 attempts)" "$retry_out" "ATTEMPTS=3"
# Genuinely-missing image: after the retries exhaust, manifest_digest stays empty so the caller's
# `[ -n "$digest" ] || die` still stops the release (a missing image must not silently pass).
# shellcheck disable=SC1090,SC2034  # dynamic source; REGISTRY_READ_* are read by the sourced retry helper
exhaust_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    REGISTRY_READ_BACKOFF=0
    REGISTRY_READ_RETRIES=3
    buildx_inspect() { return 1; } # GHCR never makes it readable
    digest="$(manifest_digest gone:tag)"
    [ -n "$digest" ] || echo "DIED-EMPTY"
)"
assert_contains "exhausted retries -> empty digest (caller dies)" "$exhaust_out" "DIED-EMPTY"
# The smoke stage's raw manifest read has the same read-after-push exposure — wire it through the retry.
assert_contains "smoke stage reads the manifest via retry_registry_read (#429)" \
    "$(cat "$REL")" "retry_registry_read buildx_inspect \"\$repo:\$STAGING_TAG\" --raw"

# #557: the test above disables errexit (`set +eu`, right after sourcing) to observe the bare helper
# in isolation, which happens to mask a real bug in stage_push itself: the bare
# `digest="$(manifest_digest ...)"` assignment aborts under release.sh's own `set -euo pipefail`
# BEFORE the crafted die() ever runs, so a real release run got a silent abort instead of a diagnosed
# digest-read failure. Reproduce with errexit left ON, driving the REAL stage_push (not the bare
# helper) so the actual call site is exercised.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside stage_push
stage_push_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        DRY_RUN=0
        IMAGES=(tor)
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        WORKDIR="$SANDBOX/stagepush557"
        mkdir -p "$WORKDIR"
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        stage_push
    ) 2>&1
)"
assert_rc "stage_push, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "stage_push, real errexit: crafted die() reaches the operator (#557)" \
    "$stage_push_out" "Could not read the pushed manifest digest"

# #557: main()'s --resume-promote branch has the exact same shape (a second, separately-written
# instance of the bug — found in review, not part of the original 3 sites). Drive the real `main`
# (preflight/ghcr_login stubbed no-op) with RESUME_PROMOTE=1 and errexit left ON.
# shellcheck disable=SC1090,SC2034  # dynamic source; the globals are consumed inside main
resume_out="$(
    (
        cd "$ROOT" || exit 1
        set --
        source "$REL" 2>/dev/null
        preflight() { :; }
        ghcr_login() { :; }
        promote() { :; }
        sign_images() { :; }
        publish() { :; }
        DRY_RUN=0
        RESUME_PROMOTE=1
        IMAGES=(tor)
        TAG="v9.9.9"
        STAGING_TAG="v9.9.9-rc.1"
        REGISTRY="ghcr.io/test"
        REGISTRY_READ_RETRIES=1
        REGISTRY_READ_BACKOFF=0
        buildx_inspect() { return 1; } # every registry read fails -> retries exhaust
        main
    ) 2>&1
)"
assert_rc "--resume-promote, real errexit: retries-exhausted digest read still aborts (#557)" "$?" "1"
assert_contains "--resume-promote, real errexit: crafted die() reaches the operator (#557)" \
    "$resume_out" "Cannot resolve a staged digest"

echo "== unit: release.sh preflight checks the lint toolchain (#426) =="
# A reimaged release box loses shellcheck/shfmt/node/uv — the v1.3.0 cut died ~1 min in mid-gate with a
# bare `shellcheck: not found`. check_release_toolchain must fail fast BEFORE building, naming the tool
# and the provisioning doc. Point PATH at a sandbox of stub tools so the host's real PATH doesn't decide.
RTB="$SANDBOX/release-tools"
mkdir -p "$RTB"
for t in shellcheck shfmt node npx uv uvx; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$RTB/$t"
    chmod +x "$RTB/$t"
done
# shellcheck disable=SC1090
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain >/dev/null 2>&1
)
assert_rc "full toolchain present -> preflight passes" "$?" "0"
rm -f "$RTB/shfmt" # simulate a reimaged box missing one tool
# shellcheck disable=SC1090
tc_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    PATH="$RTB" check_release_toolchain 2>&1
)"
tc_rc=$?
assert_rc "missing tool -> preflight fails fast (rc 1)" "$tc_rc" "1"
assert_contains "the missing tool is named" "$tc_out" "shfmt"
assert_contains "error points at the provisioning doc" "$tc_out" "release-server.md"

echo "== unit: release-smoke resolves the upgraded install at ASSERT time (#1068) =="
# The #59 upgrade never rewrites the old install in place — it extracts a fresh pithead-v<new> and
# repoints `current`, which is what makes rollback possible. So asserting on the directory the run
# was POINTED at could only pass if the upgrade had overwritten the previous install: a correct
# upgrade reported as a failure, on the documented final gate of a release. MUTATION PROOF: return
# the given path unresolved and both "lands on" assertions go red.
SMK="$SANDBOX/smoke1068"
SMOKE_SH="$ROOT/scripts/release-smoke.sh"
mkdir -p "$SMK/pithead-v1.18.1" "$SMK/pithead-v1.19.0"
printf '1.18.1\n' >"$SMK/pithead-v1.18.1/VERSION"
printf '1.19.0\n' >"$SMK/pithead-v1.19.0/VERSION"
ln -sfn "$SMK/pithead-v1.19.0" "$SMK/current"
smoke_resolve() { # <dir-as-given>
    (
        _arg="$1"          # saved before `set --`, which release-smoke's own arg parser needs empty
        cd "$ROOT" || exit # its top level insists on a git repo, like the real invocation
        set --
        # Sourced through a variable, never a literal path: shellcheck follows a literal that names
        # another file in the same invocation, and release-smoke pulls in release.sh, whose
        # `local tool missing=()` then collides with this file's own scalar `missing` (SC2178).
        # shellcheck disable=SC1090
        source "$SMOKE_SH" 2>/dev/null
        set +eu
        upgraded_install_dir "$_arg"
    )
}
# Handed the previous VERSIONED dir — the shape that produced the false red. It is unchanged by
# design, so the answer has to come from the `current` beside it.
assert_eq "a versioned dir resolves to where the upgrade actually landed" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/pithead-v1.18.1")/VERSION")" "1.19.0"
# Handed the SYMLINK — resolved now, after the upgrade moved it. This is why the v1.19.2 cut did
# not hit the false red, and it must keep working.
assert_eq "the current symlink resolves to the new install" \
    "$(tr -d '[:space:]' <"$(smoke_resolve "$SMK/current")/VERSION")" "1.19.0"
# Nothing moved: a box that is already on the target must resolve to itself, not wander off.
ln -sfn "$SMK/pithead-v1.18.1" "$SMK/current"
assert_eq "with current pointing at it, the same dir resolves to itself" \
    "$(smoke_resolve "$SMK/pithead-v1.18.1")" "$SMK/pithead-v1.18.1"
# NOTE, measured rather than assumed: replacing the `readlink -f` with the raw argument leaves all
# three assertions above GREEN. The sibling lookup is what fixes the false red; the readlink only
# normalises the path that lands in the pass and failure messages. Recorded here so the next reader
# does not mistake it for a covered behaviour.
rm -rf "$SMK"
unset SMK SMOKE_SH

echo "== unit: release.sh signs the promoted digests (#376) =="
# sign_images must sign the recorded manifest-LIST digest (repo@sha256:… — never the mutable tag,
# never a per-arch child) with the box's key and no Rekor upload; the password never reaches argv.
# A fake cosign records exactly what it was asked to sign.
SIGN="$SANDBOX/sign376"
mkdir -p "$SIGN/bin"
cat >"$SIGN/bin/cosign" <<'EOF'
#!/usr/bin/env bash
echo "[cosign] $*" >>"${COSIGN_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$SIGN/bin/cosign"
# shellcheck disable=SC1090,SC2030,SC2031,SC2034  # dynamic source; the globals are consumed inside sign_images
sign_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SIGN"
    DRY_RUN=0
    COSIGN_ENABLED=1
    COSIGN_KEY="/release-box/cosign.key"
    export COSIGN_LOG="$SIGN/cosign.log"
    PATH="$SIGN/bin:$PATH"
    for s in "${IMAGES[@]}"; do set_digest "$s" "ghcr.io/test/pithead-$s@sha256:feed$s"; done
    sign_images 2>&1
)"
assert_contains "sign stage announces itself" "$sign_out" "Sign the promoted digests"
assert_eq "all 5 promoted digests signed" "$(grep -c '^\[cosign\] sign ' "$SIGN/cosign.log")" "5"
assert_contains "signs the digest with the box key, no Rekor upload" "$(cat "$SIGN/cosign.log")" \
    "sign --key /release-box/cosign.key --tlog-upload=false --yes ghcr.io/test/pithead-dashboard@sha256:feeddashboard"
assert_not_contains "never signs a mutable tag" "$(cat "$SIGN/cosign.log")" ":v"
# Opt-in (#376): with signing OFF, sign_images is a no-op -- no cosign calls, and it says why.
: >"$SIGN/cosign-off.log"
# shellcheck disable=SC1090,SC2030,SC2031,SC2034  # dynamic source; the globals are consumed inside sign_images
sign_off_out="$(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    WORKDIR="$SIGN"
    DRY_RUN=0
    COSIGN_ENABLED=0
    export COSIGN_LOG="$SIGN/cosign-off.log"
    PATH="$SIGN/bin:$PATH"
    for s in "${IMAGES[@]}"; do set_digest "$s" "ghcr.io/test/pithead-$s@sha256:feed$s"; done
    sign_images 2>&1
)"
assert_eq "signing off means no cosign invocations" "$(grep -c '^\[cosign\]' "$SIGN/cosign-off.log")" "0"
assert_contains "signing off announces the skip" "$sign_off_out" "skipping image signatures"
# The bundle gets a detached signature the #59 runner can fetch (pithead.tar.gz.sig), and the
# committed public key ships INSIDE the bundle so a release install has its verifier beside pithead.
# shellcheck disable=SC1090,SC2030,SC2031,SC2034
(
    cd "$ROOT" || exit
    set --
    source "$REL" 2>/dev/null
    set +eu
    DRY_RUN=0
    COSIGN_KEY="/release-box/cosign.key"
    export COSIGN_LOG="$SIGN/cosign.log"
    PATH="$SIGN/bin:$PATH"
    sign_bundle "$SIGN/pithead.tar.gz" "$SIGN/pithead.tar.gz.sig" >/dev/null 2>&1
)
assert_contains "bundle signed as a detached blob signature" "$(cat "$SIGN/cosign.log")" \
    "sign-blob --key /release-box/cosign.key --tlog-upload=false --yes --output-signature $SIGN/pithead.tar.gz.sig"
assert_contains "the bundle ships cosign.pub (the install-side verifier)" "$(cat "$REL")" "config.reference.json config.core-keys.json cosign.pub"

echo "== unit: release.sh refuses to publish unsigned (#960/#1108) =="
# The producer used to treat signing as opt-in while the consumer treats it as mandatory: once
# cosign.pub is committed it ships in every bundle, and every one-click upgrade REFUSES a release
# with no pithead.tar.gz.sig. So a cut on a box with no key does not make a degraded release, it
# makes one the whole fleet rejects — and GitHub release assets are immutable, so the signature can
# never be added afterwards. That is how v1.18.0 shipped unsigned and had to be withdrawn (#960).
# resolve_signing must therefore ABORT the cut. MUTATION PROOF: change its final die() to warn() and
# "an unconfigured signing box aborts the cut" goes red (verified — see the PR).
SGN="$SANDBOX/signing960"
mkdir -p "$SGN/bin" "$SGN/v3" "$SGN/nopub"
# A cosign that advertises --tlog-upload, the flag both signing calls pass.
printf '#!/usr/bin/env bash\necho "      --tlog-upload   upload to the transparency log"\nexit 0\n' >"$SGN/bin/cosign"
# cosign v3 removed that flag: the box passes every other check and then dies at stage 6b, with the
# images already promoted (#960 — the release box had drifted to v3.1.2 exactly this way).
printf '#!/usr/bin/env bash\necho "      --yes   skip confirmation"\nexit 0\n' >"$SGN/v3/cosign"
chmod +x "$SGN/bin/cosign" "$SGN/v3/cosign"
: >"$SGN/cosign.key"

# One resolve_signing decision, rendered as "rc=N <message> enabled=N". The env arrives as a string
# because release.sh's option parser needs an empty argv (`set --`), which eats positional args; and
# COSIGN_ENABLED — the variable that actually drives whether anything gets signed — is reported from
# an EXIT trap, because die() exits this subshell before a trailing read of it could run.
signing_decide() { # <cwd> <env-assignments>
    _out="$(
        cd "$1" || exit
        _envs="$2"
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        eval "$_envs"
        trap 'printf " enabled=%s" "${COSIGN_ENABLED:-unset}"' EXIT
        resolve_signing 2>&1
    )"
    printf 'rc=%s %s' "$?" "$_out"
}
SGN_OK="PATH=$SGN/bin:\$PATH; COSIGN_KEY=$SGN/cosign.key; COSIGN_PASSWORD=x; UNSIGNED=0; DRY_RUN=0"

sg="$(signing_decide "$ROOT" "$SGN_OK")"
assert_contains "a complete signing env turns signing ON" "$sg" "rc=0"
assert_contains "signing ON is what the later stages actually read" "$sg" "enabled=1"
assert_contains "signing ON says what will be signed" "$sg" "Release signing ON"
# The defect itself: cosign.pub committed + no key must stop the cut, and say why it cannot be fixed later.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}")"
assert_contains "an unconfigured signing box aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the missing piece" "$sg" "COSIGN_KEY is unset"
assert_contains "the abort says the fleet would refuse the release" "$sg" "every one-click upgrade refuses"
assert_contains "the abort says assets are immutable, so this cannot be fixed after publish" "$sg" "immutable"
assert_contains "the abort offers the deliberate escape hatch" "$sg" "--unsigned"
# --unsigned is the loud, explicit way to publish one anyway.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}; UNSIGNED=1")"
assert_contains "--unsigned publishes anyway" "$sg" "rc=0"
assert_contains "--unsigned leaves signing genuinely off" "$sg" "enabled=0"
assert_contains "--unsigned warns the fleet will refuse this release" "$sg" "REFUSES a release that has none"
# No committed public key means nothing in the field fails closed — warn and proceed, as before.
sg="$(signing_decide "$SGN/nopub" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/unset COSIGN_KEY}")"
assert_contains "no committed cosign.pub still publishes unsigned" "$sg" "rc=0"
assert_contains "no committed cosign.pub leaves signing off" "$sg" "enabled=0"
assert_contains "no committed cosign.pub says installs will not verify" "$sg" "proceed unverified"
# COSIGN_PASSWORD was never checked before: cosign would prompt for it at stage 6b, after promotion.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_PASSWORD=x/unset COSIGN_PASSWORD}")"
assert_contains "an unset COSIGN_PASSWORD aborts the cut" "$sg" "rc=1"
assert_contains "the abort names COSIGN_PASSWORD" "$sg" "COSIGN_PASSWORD is unset"
# Set-but-empty is a legitimate key with no passphrase — an -n test would wrongly block that box.
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_PASSWORD=x/COSIGN_PASSWORD=}")"
assert_contains "an empty passphrase is a valid key, not a missing one" "$sg" "rc=0"
assert_contains "an empty passphrase still signs" "$sg" "enabled=1"
sg="$(signing_decide "$ROOT" "${SGN_OK/COSIGN_KEY=$SGN\/cosign.key/COSIGN_KEY=$SGN\/absent.key}")"
assert_contains "a COSIGN_KEY naming no file aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the path it could not find" "$sg" "$SGN/absent.key"
# The version drift that killed a cut: the flags are probed, not the version number.
sg="$(signing_decide "$ROOT" "${SGN_OK/PATH=$SGN\/bin/PATH=$SGN\/v3}")"
assert_contains "a cosign without --tlog-upload aborts the cut" "$sg" "rc=1"
assert_contains "the abort names the flag that would fail at stage 6b" "$sg" "--tlog-upload"
# The rehearsal is the point: the decision used to sit inside `if [ "$DRY_RUN" -eq 0 ]`, so a dry run
# printed "signing OFF" whatever the box was configured to do — the one check that exists to protect
# a cut could only ever report the failure state (#1108). MUTATION PROOF: put resolve_signing's body
# back inside that guard and both of the next two go red.
sg="$(signing_decide "$ROOT" "${SGN_OK/DRY_RUN=0/DRY_RUN=1}")"
assert_contains "a dry run rehearses the real decision, not a fixed OFF (#1108)" "$sg" "rc=0"
assert_contains "a dry run reports signing will be ON, not OFF (#1108)" "$sg" "enabled=1"
sg="$(signing_decide "$ROOT" "${SGN_OK/DRY_RUN=0/DRY_RUN=1}; unset COSIGN_KEY")"
assert_contains "a dry run on an unconfigured box fails the rehearsal (#1108)" "$sg" "rc=1"

echo "== unit: release.sh validates the pinned verifier image before publish (#1084) =="
# Since #1072 every install verifies its images and its upgrade bundle by running ONE digest-pinned
# cosign container, so that image is the trust root for the whole fleet — and nothing checked it.
# The stack tests around it run against a fake docker (they pass whether the digest is real, typo'd
# or deleted), the tier-4 e2e skips verification on a source checkout, and release-smoke runs after
# the publish, when the assets are immutable. So preflight proves the pin end to end instead.
VER="$SANDBOX/verifier1084"
mkdir -p "$VER/bin" "$VER/box"
printf 'fake release public key\n' >"$VER/box/cosign.pub"
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:d1ge57"  # v2.6.3\n' >"$VER/box/pithead"
# Enough cosign for preflight: it advertises --tlog-upload, and sign-blob writes the blob's sha256 as
# the "signature" so the fake verifier below can genuinely check it rather than return a canned rc.
cat >"$VER/bin/cosign" <<'FAKECOSIGN'
#!/usr/bin/env bash
case "${2:-}" in --help)
    echo "      --tlog-upload   upload to the transparency log"
    exit 0
    ;;
esac
[ "${SIGN_RC:-0}" -eq 0 ] || exit "${SIGN_RC}"
out="" blob=""
while [ $# -gt 0 ]; do
    case "$1" in
    --output-signature)
        out="$2"
        shift
        ;;
    -*) ;;
    *) blob="$1" ;;
    esac
    shift
done
[ -n "$out" ] && [ -n "$blob" ] || exit 1
openssl dgst -sha256 "$blob" | awk '{print $NF}' >"$out"
FAKECOSIGN
# A stand-in for the pinned container. `version` answers the liveness probe; verify-blob does the
# real thing in miniature against the read-only mount, so the tampered-blob leg fails for the right
# reason. VERIFIER_DEAD / VERIFIER_ALWAYS drive the failure modes a bad pin would produce.
cat >"$VER/bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
mount=""
for a in "$@"; do case "$a" in *:/w:ro) mount="${a%%:/w:ro}" ;; esac done
case " $* " in *" version "*)
    exit "${VERIFIER_DEAD:-0}"
    ;;
esac
case "${VERIFIER_ALWAYS:-}" in
accept) exit 0 ;;
refuse) exit 1 ;;
esac
[ -n "$mount" ] || exit 1
[ "$(openssl dgst -sha256 "$mount/blob" | awk '{print $NF}')" = "$(cat "$mount/blob.sig")" ]
FAKEDOCKER
chmod +x "$VER/bin/cosign" "$VER/bin/docker"

verifier_check() { # <cwd> <env-assignments>
    (
        cd "$1" || exit
        _envs="$2"
        set --
        # shellcheck disable=SC1090
        source "$REL" 2>/dev/null
        set +eu
        eval "$_envs"
        _out="$(check_verifier_image 2>&1)"
        printf 'rc=%s %s' "$?" "$_out"
    )
}
VER_OK="PATH=$VER/bin:\$PATH; COSIGN_ENABLED=1; COSIGN_KEY=$VER/box/cosign.key; DRY_RUN=0"
: >"$VER/box/cosign.key"

# The real tree's pin is what ships, so read it the way preflight will and check its shape.
# shellcheck disable=SC1090
assert_contains "the pin is read out of pithead" \
    "$(cd "$ROOT" && set -- && source "$REL" 2>/dev/null && cosign_image_pin)" "ghcr.io/sigstore/cosign/cosign@sha256:"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a working verifier passes preflight" "$vc" "rc=0"
assert_contains "the pass says the round trip actually ran" "$vc" "refuses a tampered blob"
# A verifier that says yes to everything is the failure a tag (rather than a digest) would let a
# hostile registry serve — it must never read as a pass. MUTATION PROOF: delete the tampered-blob
# leg from check_verifier_image and this goes red.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_ALWAYS=accept")"
assert_contains "a verifier that accepts a tampered blob aborts the cut" "$vc" "rc=1"
assert_contains "the abort says it is not verifying anything" "$vc" "ACCEPTED a tampered blob"
# The mundane realistic failure: a CVE bump, one wrong character, every other test still green.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_DEAD=1")"
assert_contains "an unpullable pin aborts the cut" "$vc" "rc=1"
assert_contains "the abort says installs would fail at the first up" "$vc" "will not run"
# A verifier that refuses a signature this box just made means the committed cosign.pub is no longer
# the public half of COSIGN_KEY — every install would refuse every artifact of the release.
vc="$(verifier_check "$VER/box" "$VER_OK; export VERIFIER_ALWAYS=refuse")"
assert_contains "a key/cosign.pub mismatch aborts the cut" "$vc" "rc=1"
assert_contains "the abort names the mismatch as a cause" "$vc" "public half"
vc="$(verifier_check "$VER/box" "$VER_OK; export SIGN_RC=1")"
assert_contains "a key that cannot sign aborts the cut before stage 6b" "$vc" "rc=1"
# A tag would let a hostile registry serve a cosign that exits 0 on everything.
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v2.6.3"\n' >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a verifier pinned by tag rather than digest aborts the cut" "$vc" "rc=1"
assert_contains "the abort explains what a tag would allow" "$vc" "exits 0 on everything"
: >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "$VER_OK")"
assert_contains "a pin that cannot be read at all aborts the cut" "$vc" "rc=1"
# With signing off there is no signature to prove the verifier against — say so, do not imply a pass.
printf 'readonly COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign@sha256:d1ge57"\n' >"$VER/box/pithead"
vc="$(verifier_check "$VER/box" "${VER_OK/COSIGN_ENABLED=1/COSIGN_ENABLED=0}")"
assert_contains "signing off still proves the pin pulls and runs" "$vc" "rc=0"
assert_contains "signing off says the round trip was skipped" "$vc" "round trip was skipped"

echo "== unit: pull-vs-build mode (#44) =="
# is_source_checkout / resolve_pull_policy / STACK_VERSION key off whether the image build CONTEXTS
# (Dockerfiles) are present: a source checkout builds locally (:dev, --pull never); a release bundle
# (only build/tari/ + VERSION) pulls (:vX.Y.Z, --pull missing). Two scratch dirs stand in for each.
SRCM="$SANDBOX/srcmode"
mkdir -p "$SRCM/build/dashboard"
: >"$SRCM/build/dashboard/Dockerfile"
printf '0.1.0\n' >"$SRCM/VERSION"
RELM="$SANDBOX/relmode"
mkdir -p "$RELM/build/tari"
printf '0.1.0\n' >"$RELM/VERSION"
# shellcheck disable=SC1090
(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout true with a Dockerfile" "$?" "0"
# shellcheck disable=SC1090
(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    is_source_checkout
)
assert_rc "is_source_checkout false without a Dockerfile" "$?" "1"
# shellcheck disable=SC1090
assert_eq "pull policy: source -> never" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "never"
# shellcheck disable=SC1090
assert_eq "pull policy: release -> missing" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    resolve_pull_policy
)" "missing"
# shellcheck disable=SC1090
assert_eq "pull policy: PITHEAD_PULL override" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    PITHEAD_PULL=always resolve_pull_policy
)" "always"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION dev in a source checkout" "$(
    cd "$SRCM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "dev"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION v0.1.0 in a release bundle" "$(
    cd "$RELM" || exit
    set --
    source "$STACK" 2>/dev/null
    set +eu
    export_build_provenance
    printf '%s' "$STACK_VERSION"
)" "v0.1.0"

echo "== unit: explain_subnet_collision (#180) =="
ov="$(run_sourced "$SANDBOX" explain_subnet_collision "invalid pool request: Pool overlaps with other one on this address space" 2>&1)"
assert_contains "subnet overlap -> network.subnet hint" "$ov" "network"
assert_contains "subnet overlap -> suggests a free /24" "$ov" "/24"
assert_eq "non-overlap failure stays silent" "$(run_sourced "$SANDBOX" explain_subnet_collision "some other failure" 2>&1)" ""

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/new.env"
assert_eq "env_get_file reads value" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with =" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in build/dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"
mkdir -p "$PROV"
printf '  9.9.9 \n' >"$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"
mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

echo "== unit: node credential helpers =="
assert_eq "default username is admin" "$(run_sourced "$SANDBOX" default_node_username)" "admin"
PW="$(run_sourced "$SANDBOX" generate_node_password)"
assert_eq "generated password is 32 chars" "${#PW}" "32"
assert_eq "generated password is alphanumeric" "$(printf '%s' "$PW" | tr -dc 'A-Za-z0-9')" "$PW"
PW2="$(run_sourced "$SANDBOX" generate_node_password)"
if [ "$PW" != "$PW2" ]; then ok "two generations differ"; else bad "two generations differ" "both were [$PW]"; fi
run_sourced "$SANDBOX" cred_needs_generating "" "PLACE"
assert_rc "empty needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "PLACE" "PLACE"
assert_rc "placeholder needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "real" "PLACE"
assert_rc "real value kept" "$?" "1"

echo "== unit: randomx_boot_params (#176) =="
# The kernel boot params pithead writes into GRUB_CMDLINE_LINUX_DEFAULT for RandomX. Guards the
# regression where the THP-disable param was PLURAL (transparent_hugepages=never) — an unrecognized
# param the kernel silently ignores, so THP was never actually disabled. The valid param is singular.
bp="$(run_sourced "$SANDBOX" randomx_boot_params)"
assert_contains "reserves 2M huge page size" "$bp" "hugepagesz=2M"
assert_contains "reserves 3072 huge pages" "$bp" "hugepages=3072"
assert_contains "disables THP (singular param)" "$bp" "transparent_hugepage=never"
case "$bp" in
*transparent_hugepages=*) bad "THP param must be singular, not the kernel-ignored plural" "got [$bp]" ;;
*) ok "THP param is singular (no plural transparent_hugepages= typo)" ;;
esac

echo "== unit: grub heal + boot-param insert (#176) =="
# A passthrough sudo so the helpers' `sudo cp` / `sudo sed -i` actually edit a sandbox grub file
# (the global stub sudo is a no-op). The helpers select GNU vs BSD sed via OS_TYPE, so this exercises
# the real transformation on both Linux CI and a macOS dev box.
GR="$SANDBOX/grub"
mkdir -p "$GR/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$GR/bin/sudo"
chmod +x "$GR/bin/sudo"
run_grub() { PATH="$GR/bin:$PATH" run_sourced "$SANDBOX" "$@"; }

# heal: rewrites an existing plural typo to the singular param, then is an idempotent no-op.
g="$GR/healed"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never quiet"\n' >"$g"
run_grub heal_grub_thp_typo "$g"
assert_rc "heal: rewrites plural typo (rc 0)" "$?" "0"
assert_contains "heal: file now uses singular param" "$(cat "$g")" "transparent_hugepage=never"
case "$(cat "$g")" in *transparent_hugepages=*) bad "heal: plural typo removed" "$(cat "$g")" ;; *) ok "heal: plural typo removed" ;; esac
run_grub heal_grub_thp_typo "$g"
assert_rc "heal: idempotent no-op when already singular (rc 1)" "$?" "1"

# insert: appends the params to the active line, preserving what's already there.
g="$GR/fresh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$g"
run_grub append_grub_boot_params "$g"
assert_rc "insert: edits the active line (rc 0)" "$?" "0"
out="$(cat "$g")"
assert_contains "insert: keeps existing params" "$out" "quiet splash"
assert_contains "insert: adds hugepages reservation" "$out" "hugepages=3072"
assert_contains "insert: adds singular THP param" "$out" "transparent_hugepage=never"

# insert: a commented-out line is not the active form -> rc 1, file untouched (no silent reboot).
g="$GR/commented"
printf '# GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_TIMEOUT=5\n' >"$g"
before="$(cat "$g")"
run_grub append_grub_boot_params "$g"
assert_rc "insert: no active line -> rc 1" "$?" "1"
assert_eq "insert: leaves file unchanged when no active line" "$(cat "$g")" "$before"

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

echo "== unit: disk_component_gib =="
assert_eq "monero pruned -> 120" "$(run_sourced "$SANDBOX" disk_component_gib monero 1)" "120"
assert_eq "monero full -> 320" "$(run_sourced "$SANDBOX" disk_component_gib monero 0)" "320"
assert_eq "tari -> 200" "$(run_sourced "$SANDBOX" disk_component_gib tari)" "200"
assert_eq "tor -> 1" "$(run_sourced "$SANDBOX" disk_component_gib tor)" "1"

echo "== unit: check_disk_grouped (mocked df) =="
# A df stub on PATH so check_disk_grouped sees a scripted filesystem layout. DF_MAP maps each path
# df is queried for to a mount point ("path=mount" space-separated): the data dirs (disk_fs_mount
# resolves the mount from these) AND the mount points themselves (check_disk_grouped reads free
# space via the mount, not the possibly-missing dir — #179). DF_AVAIL_KB / DF_AVAIL_H give the
# (single) free figure every mount reports. Real temp dirs make disk_fs_mount resolve without walking up.
DISK="$SANDBOX/disk"
mkdir -p "$DISK/bin"
cat >"$DISK/bin/df" <<'EOF'
#!/usr/bin/env bash
human=0; path=""
for a in "$@"; do case "$a" in -Ph) human=1 ;; -*) : ;; *) path="$a" ;; esac; done
mount=""
for kv in $DF_MAP; do [ "${kv%%=*}" = "$path" ] && mount="${kv#*=}"; done
[ -n "$mount" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
if [ "$human" = 1 ]; then echo "src 9 9 ${DF_AVAIL_H} 1% $mount"; else echo "src 9 9 ${DF_AVAIL_KB} 1% $mount"; fi
EOF
chmod +x "$DISK/bin/df"
DM="$DISK/data"
mkdir -p "$DM/monero" "$DM/tari" "$DM/p2pool" "$DM/dashboard" "$DM/tor"
md="$DM/monero" td="$DM/tari" pd="$DM/p2pool" dd="$DM/dashboard" rd="$DM/tor"

# All five dirs on ONE filesystem with plenty of space -> a SINGLE grouped OK line naming every
# component, with the combined pruned requirement (120+200+5+2+1 = 328 GB).
one_map="$md=/data $td=/data $pd=/data $dd=/data $rd=/data /data=/data"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "single line names all components" "$out" "(monero, tari, p2pool, dashboard, tor)"
assert_contains "single line shows combined ~328 GB" "$out" "needs ~328 GB"
assert_contains "ample space -> OK" "$out" "OK"

# Same single filesystem but too small (100 GiB < 328 GiB) -> ONE WARN line.
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=104857600 DF_AVAIL_H=100G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one small fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "small fs warns below need" "$out" "below the ~328 GB"

# Two filesystems: monero+tari on /big, the rest on /small -> ONE line per filesystem.
two_map="$md=/big $td=/big $pd=/small $dd=/small $rd=/small /big=/big /small=/small"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$two_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "two fs -> two lines" "$(printf '%s\n' "$out" | grep -c 'Data on')" "2"
assert_contains "/big groups monero+tari (~320 GB)" "$out" "/big (monero, tari): 600G free — needs ~320 GB"
assert_contains "/small groups the small three (~8 GB)" "$out" "/small (p2pool, dashboard, tor): 600G free — needs ~8 GB"

# Remote node modes (#103): doctor/preflight blank the remote component's dir (its chain lives on
# the OTHER host), and an empty dir arg must drop that component from the budget entirely — here
# tari remote drops the ~200 GB Tari share, leaving monero+the small three (120+5+2+1 = 128 GB).
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "" "$pd" "$dd" "$rd" 2>&1)"
assert_contains "remote tari drops tari from the budget" "$out" "(monero, p2pool, dashboard, tor)"
assert_contains "remote tari budget excludes the 200 GB" "$out" "needs ~128 GB"

# Preflight mode is WARN-only and silent when there's enough room.
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped preflight 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "preflight silent when ample" "$out" ""
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=104857600 DF_AVAIL_H=100G \
    run_sourced "$SANDBOX" check_disk_grouped preflight 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_contains "preflight warns once when low" "$out" "Low disk on /data (hosts monero, tari, p2pool, dashboard, tor)"

# Regression #179: on first run the data dirs don't exist yet; check_disk_grouped must resolve to the
# nearest existing ancestor's mount and read free space THERE, not df the missing dir (which fails the
# pipe and trips pithead's `set -Eeuo pipefail`). Run under strict mode — NOT run_sourced, which does
# `set +e` and would mask the crash — so a re-introduced df-on-missing-dir would actually abort here.
fresh_map="$DM=/data /data=/data"
PATH="$DISK/bin:$PATH" DF_MAP="$fresh_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    bash -c 'source "$1" 2>/dev/null; check_disk_grouped preflight 1 "$2/fresh/monero" "$2/fresh/tari" "$2/fresh/p2pool" "$2/fresh/dashboard" "$2/fresh/tor"' \
    _ "$STACK" "$DM" >/dev/null 2>&1
assert_rc "check_disk_grouped survives not-yet-created data dirs under set -e (#179)" "$?" "0"

echo "== node configs: no clearnet DNS egress (#161 monerod, #162 tari) =="
MONC="$ROOT/build/monero/bitmonero.conf.template"
TARC="$ROOT/build/tari/config.toml.template"
# monerod (#161): hostname priority-nodes dropped; DNS checkpoints + update check off.
case "$(cat "$MONC")" in
*xmrvsbeast.com:18080* | *nodes.hashvault.pro*) bad "monerod: priority-node hostnames dropped (#161)" "still present" ;;
*) ok "monerod: priority-node hostnames dropped (#161)" ;;
esac
case "$(grep -E '^enforce-dns-checkpointing' "$MONC" || true)" in
"") ok "monerod: enforce-dns-checkpointing removed (#161)" ;;
*) bad "monerod: enforce-dns-checkpointing removed (#161)" "still present" ;;
esac
assert_contains "monerod: DNS checkpoints disabled (#161)" "$(cat "$MONC")" "disable-dns-checkpoints=1"
assert_contains "monerod: update check disabled (#161)" "$(cat "$MONC")" "check-updates=disabled"
# tari (#162): no DNS seeds; peer_seeds onion-only; the inert check_for_updates gRPC method dropped.
assert_contains "tari: DNS seeds disabled (#162)" "$(cat "$TARC")" "dns_seeds = []"
# #271: minotari defaults proxy_bypass_for_outbound_tcp=true → it direct-dials peers advertising a bare
# /ip4 (clearnet) address, bypassing Tor. false routes every dial through the SOCKS proxy (reach those
# peers via Tor exits) — so Tari is functional AND never touches clearnet directly.
assert_contains "tari: outbound TCP dials routed via Tor SOCKS, not direct (#271)" "$(cat "$TARC")" "proxy_bypass_for_outbound_tcp = false"
case "$(grep -E '::/ip4/|::/ip6/' "$TARC" || true)" in
"") ok "tari: peer_seeds are onion-only (#162)" ;;
*) bad "tari: peer_seeds are onion-only (#162)" "clearnet /ip4//ip6/ peer seeds present" ;;
esac
case "$(grep -E 'check_for_updates' "$TARC" || true)" in
"") ok "tari: check_for_updates dropped from gRPC allow-list (#162)" ;;
*) bad "tari: check_for_updates dropped from gRPC allow-list (#162)" "still present" ;;
esac
# The Pulse (checkpoints.tari.com TXT, ~120s) is the last clearnet DNS path: the tari container's
# resolver is pointed at a dead local address so the lookup fails without a packet leaving the host
# (Tari tolerates it — returns "passed"). The container already overrode Docker's 127.0.0.11, so no
# service-discovery dependency is broken. Assert no clearnet resolvers remain on the tari service.
TARI_SVC="$(awk '/^  tari:/{f=1;print;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")"
case "$TARI_SVC" in
*1.1.1.1* | *8.8.8.8*) bad "tari: clearnet DNS resolvers removed from compose (#162)" "1.1.1.1/8.8.8.8 present" ;;
*) ok "tari: clearnet DNS resolvers removed from compose (#162)" ;;
esac
assert_contains "tari: resolver pointed at dead local sinkhole (#162)" "$TARI_SVC" "127.0.0.1"

# ---------------------------------------------------------------------------
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

echo "== black-box: config validation =="
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
WALLET="4$(printf 'A%.0s' $(seq 94))" # 95-char mainnet primary (starts with 4); #250 now hard-validates this
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"banana"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid pool rejected" "$rc" "1"
assert_contains "invalid pool message" "$out" "p2pool.pool"

# A non-IP stratum_bind must be rejected before it reaches the compose port mapping.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main","stratum_bind":"not-an-ip"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid stratum_bind rejected" "$rc" "1"
assert_contains "invalid stratum_bind message" "$out" "p2pool.stratum_bind"

# A dashboard.host with Caddyfile-breaking characters (space/braces) must be rejected before render.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"bad host{x}"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid dashboard.host rejected" "$rc" "1"
assert_contains "invalid dashboard.host message" "$out" "dashboard.host"

# proxy.donate_level must be an integer 0-99 (default 0); an out-of-range value is rejected (#173).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":150}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "out-of-range donate_level rejected" "$rc" "1"
assert_contains "donate_level message" "$out" "proxy.donate_level"
# Non-numeric donate_level is rejected (the "auto" sentinel was removed — the value is a plain integer).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":"auto"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "non-numeric donate_level rejected" "$rc" "1"

# A stratum_password with a shell/.env-unsafe character (a space) is rejected before render (#152).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main","stratum_password":"bad pass"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "unsafe stratum_password rejected" "$rc" "1"
assert_contains "stratum_password message" "$out" "p2pool.stratum_password"

# p2pool.stratum_port (#172) must be an integer 1-65535; junk and out-of-range values fail apply
# before they can render an unparseable compose port mapping.
for bad_port in '"abc"' 0 65536; do
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main","stratum_port":%s}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$bad_port" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "invalid stratum_port $bad_port rejected" "$rc" "1"
    assert_contains "stratum_port message ($bad_port)" "$out" "p2pool.stratum_port"
done

# dashboard.workers (#172): malformed per-worker descriptors fail apply loudly — a typo must not
# be silently dropped at dashboard runtime. host charset is the #122 guard (no port/path/userinfo).
dw_case() { # <workers-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
dw_case '{"name":"rig1"}' "non-array dashboard.workers" "must be an array"
dw_case '[{"host":"10.0.0.5"}]' "worker entry without a name" "name"
dw_case '[{"name":"rig1","host":"10.0.0.5/path"}]' "worker host with URL structure" "dashboard.workers[rig1].host"
dw_case '[{"name":"rig1","host":"attacker:8080"}]' "worker host smuggling a port" "dashboard.workers[rig1].host"
dw_case '[{"name":"rig1","port":65536}]' "out-of-range worker port" "dashboard.workers[rig1].port"
dw_case '[{"name":"rig1","port":"8080"}]' "string worker port" "dashboard.workers[rig1].port"
dw_case '[{"name":"rig1","token":"has space"}]' "unsafe worker token" "dashboard.workers[rig1].token"
dw_case '[{"name":"rig1","watts":0}]' "non-positive worker watts (#260)" "dashboard.workers[rig1].watts"
dw_case '[{"name":"rig1","watts":"142"}]' "string worker watts (#260)" "dashboard.workers[rig1].watts"

# Duplicate names are legal (first-declared wins) but warned about, and a valid dashboard.workers[]
# list applies. Also proves the legacy fallback still validates + warns once (#506).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"rig1","port":1111},{"name":"rig1","port":2222},{"name":"rig2","host":"worker-lan.local","token":"tok_abc123"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "valid dashboard.workers applies" "$rc" "0"
assert_contains "duplicate worker names are warned" "$out" "first-declared"
assert_contains "legacy dashboard.workers is warned as deprecated (#506)" "$out" "dashboard.workers[] is deprecated"
# Nothing from the list reaches .env: the dashboard reads it from its config.json mount, and the
# per-worker token must not leak into a second secrets file.
if grep -q 'tok_abc123' "$V/.env"; then bad "worker token stays out of .env" "token landed in .env"; else ok "worker token stays out of .env"; fi

# workers.list[] (#506): the current sub-key validates with the same rules, at the new path — every
# per-field error message above named its path via dashboard.workers[]; each case repeats here
# named via workers.list[], proving the dynamic path label in validate_worker_endpoints tracks
# whichever key is actually in use, not a hardcoded string.
wl_case() { # <workers-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
wl_case '{"name":"rig1"}' "non-array workers.list" "must be an array"
wl_case '[{"host":"10.0.0.5"}]' "workers.list entry without a name" "name"
wl_case '[{"name":"rig1","host":"10.0.0.5/path"}]' "workers.list host with URL structure" "workers.list[rig1].host"
wl_case '[{"name":"rig1","host":"attacker:8080"}]' "workers.list host smuggling a port" "workers.list[rig1].host"
wl_case '[{"name":"rig1","port":65536}]' "out-of-range workers.list port" "workers.list[rig1].port"
wl_case '[{"name":"rig1","token":"has space"}]' "unsafe workers.list token" "workers.list[rig1].token"
wl_case '[{"name":"rig1","watts":0}]' "non-positive workers.list watts (#260)" "workers.list[rig1].watts"

# A valid workers.list[] applies cleanly, warns no deprecation, and — like the legacy shape — never
# leaks a per-worker token into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":[{"name":"rig1","host":"worker-lan.local","token":"tok_xyz789"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid workers.list applies" "$?" "0"
assert_not_contains "workers.list applying raises no deprecation warning" "$out" "deprecated"
if grep -q 'tok_xyz789' "$V/.env"; then bad "workers.list token stays out of .env" "token landed in .env"; else ok "workers.list token stays out of .env"; fi

# Setting BOTH workers.list[] and dashboard.workers[] is a hard error (#506) — a silent pick would
# leave the other a stale, unnoticed copy of hosts/tokens. REVERT-PROOF: the exact case a partial
# revert of the dual-read change would silently start allowing again.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig"}]}, "workers":{"list":[{"name":"new-rig"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "both workers.list and dashboard.workers set is rejected" "$rc" "1"
assert_contains "both-set refusal names both keys" "$out" "sets both workers.list[] and dashboard.workers[]"

# The refusal keys on CONTENT, not presence (#679): the dashboard config editor merges
# config.reference.json (which ships BOTH keys as empty-array schema defaults) under the
# operator's config before serving the form, and round-trips the merged doc on save — so an
# empty array beside the populated key must neither refuse nor warn.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[]}, "workers":{"list":[{"name":"new-rig","host":"worker-lan.local"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "workers.list beside an empty dashboard.workers applies (#679)" "$?" "0"
assert_not_contains "empty legacy default does not trip the both-set refusal" "$out" "sets both workers.list[] and dashboard.workers[]"
assert_not_contains "empty legacy default raises no deprecation warning" "$out" "deprecated"

# Mirror: a populated legacy list beside an empty workers.list (the same reference-merge shape,
# for an operator still on the deprecated key) selects — and still validates — the legacy entries.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"10.0.0.5"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "populated dashboard.workers beside an empty workers.list applies (#679)" "$?" "0"
assert_contains "legacy shape beside the empty default still warns as deprecated" "$out" "dashboard.workers[] is deprecated"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]}, "workers":{"list":[]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "an empty workers.list must not shadow legacy entries from validation (#679)" "$?" "1"
assert_contains "shadowed legacy entry is flagged under its own path label" "$out" "dashboard.workers[legacy-rig].host"

# The editor contract itself (#679): the shipped config.reference.json deep-merged UNDER a valid
# operator config — exactly the document read_config serves and the editor POSTs back — must
# survive the same dry-run the control channel's preview leg runs. Fails on any future schema
# default that trips validation, whatever the key.
seed_env
cp "$ROOT/config.reference.json" "$V/reference.json"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"}, "workers":{"list":[{"name":"new-rig","host":"worker-lan.local"}]} }\n' "$WALLET" >"$V/operator.json"
jq -s '(.[0] | del(._docs)) * .[1]' "$V/reference.json" "$V/operator.json" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "reference-merged editor round-trip survives the preview dry-run (#679)" "$?" "0"

# Migration (#679): a validated legacy dashboard.workers[] is moved to workers.list[] in place on
# apply — old key deleted, sibling workers.* keys and per-worker tokens preserved, pre-migration
# copy kept beside the file (the .bak-control naming). Dry runs never write.
rm -f "$V/config.json.bak-workers"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"worker-lan.local","token":"tok_mig456"}]}, "workers":{"api_port":9090} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "dry run on a legacy config succeeds" "$?" "0"
if [ -f "$V/config.json.bak-workers" ]; then bad "dry run never migrates (#556)" "backup appeared"; else ok "dry run never migrates (#556)"; fi
assert_eq "dry run leaves dashboard.workers in place" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "true"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "legacy config applies and migrates" "$?" "0"
assert_contains "migration is announced with the backup path" "$out" "Migrated dashboard.workers[] to workers.list[]"
assert_eq "entries moved to workers.list (token intact)" "$(jq -r '.workers.list[0].token' "$V/config.json")" "tok_mig456"
assert_eq "sibling workers.* keys survive the move" "$(jq -r '.workers.api_port' "$V/config.json")" "9090"
assert_eq "dashboard.workers is gone after migration" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "false"
assert_eq "pre-migration copy still holds the legacy key" "$(jq -r '.dashboard.workers[0].name' "$V/config.json.bak-workers")" "legacy-rig"
case "$(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" in
600) ok "migrated config.json stays owner-only" ;;
*) bad "migrated config.json stays owner-only" "mode $(stat -c '%a' "$V/config.json" 2>/dev/null || stat -f '%Lp' "$V/config.json" 2>/dev/null)" ;;
esac
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "second apply after migration succeeds" "$?" "0"
assert_not_contains "migration runs once — nothing to move on the next apply" "$out" "Migrated dashboard.workers[]"
assert_not_contains "no deprecation warning after migration" "$out" "deprecated"

# An INVALID legacy list fails validation before the migration hook — config and backup untouched.
rm -f "$V/config.json.bak-workers"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","workers":[{"name":"legacy-rig","host":"attacker:8080"}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "invalid legacy config still fails apply" "$?" "1"
assert_eq "failed validation leaves the legacy key untouched" "$(jq -r '.dashboard | has("workers")' "$V/config.json")" "true"
if [ -f "$V/config.json.bak-workers" ]; then bad "no backup written for a refused config" "backup appeared"; else ok "no backup written for a refused config"; fi

# dashboard.energy (#260): malformed price/currency fails apply loudly, like the worker descriptors.
en_case() { # <energy-json> <label> <expected-msg-fragment>
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","energy":%s} }\n' "$WALLET" "$1" >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    rc=$?
    assert_rc "$2 rejected" "$rc" "1"
    assert_contains "$2 message" "$out" "$3"
}
en_case '"nope"' "non-object dashboard.energy" "dashboard.energy must be an object"
en_case '{"cost_per_kwh":-1}' "negative cost_per_kwh" "dashboard.energy.cost_per_kwh"
en_case '{"xmr_price":"lots"}' "non-number xmr_price" "dashboard.energy.xmr_price"
en_case '{"tari_price":-2}' "negative tari_price (#520)" "dashboard.energy.tari_price"
en_case '{"currency":"US Dollars"}' "unsafe currency label" "dashboard.energy.currency"
# price_feed (#520): boolean only — a truthy string must not silently opt into network egress.
en_case '{"price_feed":"yes"}' "non-boolean price_feed (#520)" "dashboard.energy.price_feed"
# Closed schema (#33 hardening): the validator rejects any key outside {cost_per_kwh, currency,
# xmr_price, tari_price, price_feed} — defense in depth beneath the control gate's own
# unknown-path refusal.
en_case '{"cost_per_kwh":0.1,"__evil":{"x":1}}' "unknown dashboard.energy subkey" "dashboard.energy has an unknown key"

# A valid energy block (prices + feed opt-in + per-worker watts) applies; like workers[], nothing
# reaches .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","energy":{"cost_per_kwh":0.18,"xmr_price":150,"tari_price":2.5,"currency":"EUR","price_feed":true},"workers":[{"name":"rig1","watts":142}]} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid dashboard.energy applies" "$?" "0"

# Dashboard login (#8): a username with a Caddyfile-unsafe character (a space) is rejected before any
# hashing; the password is validated for length/charset too. Both fail fast on apply.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"bad user","password":"longenough1"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "invalid dashboard.auth.username rejected" "$rc" "1"
assert_contains "dashboard.auth.username message" "$out" "dashboard.auth.username"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"short"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "too-short dashboard.auth.password rejected" "$rc" "1"
assert_contains "dashboard.auth.password message" "$out" "dashboard.auth.password"

# Dashboard onion (#343): a weak (LAN-acceptable but <16-char) password is rejected once the onion is on. This case
# passes the length regex and so reaches the bcrypt step, which reads docker-compose.yml for the
# pinned Caddy image — make sure it's present here (it's copied for later tests further down too).
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"shortish12"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "onion with a <16-char password rejected" "$rc" "1"
assert_contains "onion strong-password message" "$out" "at least 16 characters"
# Weak-password denylist: even at 16+ chars, a single repeated character or a well-known pattern is
# rejected once the onion is on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"aaaaaaaaaaaaaaaa"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "onion repeated-character password rejected" "$?" "1"
assert_contains "repeated-character message" "$out" "single repeated character"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","onion":{"enabled":true},"auth":{"username":"admin","password":"changemechangeme"}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "onion well-known-weak password rejected" "$?" "1"
assert_contains "well-known-weak message" "$out" "well-known weak pattern"

# onion-client-key (#343): prints the client descriptor line when client-auth is on; errors when off.
# The line the operator pastes is "<addr-without-.onion>:descriptor:x25519:<privkey>".
cat >"$V/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_ONION_ENABLED=true
DASHBOARD_ONION_CLIENT_AUTH=true
DASHBOARD_ONION_ADDRESS=abcd234.onion
DASHBOARD_ONION_CLIENT_PRIVKEY=UNITTESTPRIVKEYBASE32
EOF
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead onion-client-key 2>&1)"
assert_rc "onion-client-key succeeds when client-auth on" "$?" "0"
assert_contains "onion-client-key prints the descriptor line (system Tor)" "$out" "abcd234:descriptor:x25519:UNITTESTPRIVKEYBASE32"
assert_contains "onion-client-key offers the Tor Browser path" "$out" "Tor Browser"
cat >"$V/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_ONION_ENABLED=true
DASHBOARD_ONION_CLIENT_AUTH=false
DASHBOARD_ONION_ADDRESS=abcd234.onion
EOF
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead onion-client-key 2>&1)"
assert_rc "onion-client-key errors when client-auth off" "$?" "1"
assert_contains "onion-client-key off message" "$out" "password-only"

# Wallet-type hard-fail (#250): p2pool pays via coinbase, which CANNOT reach a subaddress or an
# integrated address — a wrong type MINES but is NEVER paid, silently. monero_address_type is
# unit-tested in isolation; these prove parse_and_validate_config actually ABORTS apply on each,
# so the guardrail against losing every reward is wired, not just present.
SUBADDR="8$(printf 'A%.0s' $(seq 94))"  # 95-char, starts with 8 -> subaddress
INTADDR="4$(printf 'A%.0s' $(seq 105))" # 106-char, starts with 4 -> integrated
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$SUBADDR" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "subaddress payout rejected (would never be paid)" "$rc" "1"
assert_contains "subaddress message names the type" "$out" "SUBADDRESS"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$INTADDR" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "integrated payout rejected (would never be paid)" "$rc" "1"
assert_contains "integrated message names the type" "$out" "INTEGRATED"

# tari.wallet_address left at the placeholder -> rejected by the shared template-placeholder guard
# (else mining earns Tari that goes nowhere, the #250 failure mode). No exact-format gate
# (base58/emoji both valid), but the placeholder and any whitespace are unambiguous.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"your_tari_wallet_address"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "placeholder tari.wallet_address rejected" "$?" "1"
assert_contains "placeholder message names the template placeholders" "$out" "template placeholders"
# A stray space in the Tari address (not a control char, so the central guard misses it) -> rejected.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"12ab cd34"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "whitespace in tari.wallet_address rejected" "$?" "1"
assert_contains "whitespace message names the field" "$out" "tari.wallet_address"

# Remote mode with no host (#*): renders an empty MONERO_NODE_HOST -> p2pool/dashboard dial nothing,
# mining can't start. Must abort at validation, not silently proceed.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "remote mode without a host rejected" "$rc" "1"
assert_contains "remote-host message" "$out" "monero.remote.host"

# monero.remote.host with a comma is rejected by is_valid_host (#103): monero's remote host renders
# into the p2pool `--host` arg the same way tari's does, and the comma vector slips past the central
# control-char guard, so the field-specific guard must catch it here too.
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"1.2.3.4,fork"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero.remote.host with a comma rejected" "$?" "1"
assert_contains "monero comma-host message names the field" "$out" "monero.remote.host"

# A malformed network.subnet (#180): anything but an X.Y.Z.0/24 block renders a broken NETWORK_PREFIX
# into every service IP and the #270 firewall rules — reject before it can.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "network":{"subnet":"172.28.0.0/16"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "non-/24 network.subnet rejected" "$rc" "1"
assert_contains "network.subnet message" "$out" "network.subnet"

echo "== black-box: dashboard auth lifecycle (#8) =="
# The hashing reads the pinned Caddy image out of docker-compose.yml and shells out to the stubbed
# `caddy hash-password`, so the whole enable → reuse → change → disable path runs offline.
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
AUTH_LOG="$V/auth-docker.log"

# (1) ENABLE: a password turns on basic_auth — hash + fingerprint persisted, plaintext never stored.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":0}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "auth enable applies cleanly" "$rc" "0"
assert_eq "auth username persisted" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_USER)" "admin"
hash1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)"
fp1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)"
[ -n "$hash1" ] && ok "auth hash persisted (base64)" || bad "auth hash persisted (base64)" "empty"
[ -n "$fp1" ] && ok "auth fingerprint persisted" || bad "auth fingerprint persisted" "empty"
assert_contains "auth hashed via the pinned caddy image" "$(cat "$AUTH_LOG")" "hash-password"
assert_contains "Caddyfile gains basic_auth" "$(cat "$V/Caddyfile")" "basic_auth"
case "$(cat "$V/.env" "$V/Caddyfile")" in
*hunter2hunter2*) bad "auth plaintext never persisted" "password leaked into .env/Caddyfile" ;;
*) ok "auth plaintext never persisted" ;;
esac

# (2) REUSE: re-applying (here nudging an unrelated knob) keeps the SAME hash and does NOT re-hash —
# bcrypt is salted, so a stable fingerprint is what keeps the Caddyfile from churning every apply.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "unchanged password keeps the same hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" "$hash1"
case "$(cat "$AUTH_LOG")" in
*hash-password*) bad "unchanged password is not re-hashed" "caddy hash-password was called again" ;;
*) ok "unchanged password is not re-hashed (stable hash)" ;;
esac

# (3) CHANGE: a new password re-hashes (fingerprint changes) and recreates the caddy container.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"freshpass99"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "changed password re-hashes" "$(cat "$AUTH_LOG")" "hash-password"
assert_eq "changed password updates fingerprint" "$([ "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)" != "$fp1" ] && echo changed)" "changed"
assert_contains "auth change recreates caddy" "$(cat "$AUTH_LOG")" "restart caddy"

# (4) DISABLE: clearing the password drops basic_auth — hash cleared, dashboard reachable again.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "auth disable clears the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" ""
case "$(cat "$V/Caddyfile")" in
*basic_auth*) bad "auth disable drops basic_auth" "basic_auth still present in the Caddyfile" ;;
*) ok "auth disable drops basic_auth" ;;
esac

echo "== black-box: payout confirmation view key (#381) =="
# The private view key gates the view-only wallet-rpc service. Empty (default) -> feature off, no
# profile, no container. Set on a LOCAL node -> the payout_confirm profile is added, the key +
# generated wallet-rpc creds render into .env, and PAYOUT_CONFIRM_ENABLED flips true. The key is a
# secret: it must never be echoed to stdout by apply (BOTSECRET pattern), only land in the 600 .env.
VIEWKEY="$(printf 'a%.0s' $(seq 64))" # 64 hex chars — a well-formed private view key
# (1) OFF by default: no view key -> feature disabled, wallet-rpc profile absent.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "payout confirm off by default" "$(run_sourced "$V" env_get_file "$V/.env" PAYOUT_CONFIRM_ENABLED)" "false"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*payout_confirm*) bad "no wallet-rpc profile when view key unset" "payout_confirm leaked into COMPOSE_PROFILES" ;;
*) ok "no wallet-rpc profile when view key unset" ;;
esac
# (2) ON (local node): view key set -> profile added, key + creds rendered, flag true.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","view_key":"%s"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VIEWKEY" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a view key succeeds" "$?" "0"
assert_eq "payout confirm enabled renders true" "$(run_sourced "$V" env_get_file "$V/.env" PAYOUT_CONFIRM_ENABLED)" "true"
assert_eq "view key rendered into .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_VIEW_KEY)" "$VIEWKEY"
assert_contains "wallet-rpc profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "payout_confirm"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)" ] && ok "wallet-rpc password generated" || bad "wallet-rpc password generated" "empty"
# The view key must NEVER be echoed to stdout by apply — only land in the owner-only .env (#90).
case "$out" in
*"$VIEWKEY"*) bad "view key never printed by apply" "the view key leaked into apply stdout" ;;
*) ok "view key never printed by apply" ;;
esac
# The wallet-rpc password stays off the .env command line too — it's in .env but never on stdout.
case "$out" in
*"$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)"*) bad "wallet-rpc password not printed" "leaked into apply stdout" ;;
*) ok "wallet-rpc password not printed" ;;
esac
# The wallet-rpc password is preserved across a re-apply (like PROXY_AUTH_TOKEN), so both containers
# keep matching creds and the wallet-rpc isn't needlessly recreated.
pw1="$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "wallet-rpc password preserved across apply" "$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)" "$pw1"
# (3) REMOTE node + view key -> refused loudly (Phase 1 is local-only; scanning a third-party node
# changes the trust story).
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p","view_key":"%s"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VIEWKEY" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "view key on a remote node rejected" "$?" "1"
assert_contains "remote view-key message names the mode" "$out" "monero.view_key"
# (4) A malformed view key (not 64 hex) is rejected before it reaches the wallet.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","view_key":"not-a-view-key"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed view key rejected" "$?" "1"
assert_contains "malformed view-key message" "$out" "64-character hex"

echo "== black-box: Tari payout confirmation view key (#462) =="
# The Tari sibling of #381: tari.view_key + tari.spend_public_key gate the view-only tari-wallet.
# Empty (default) -> feature off, no profile. Set on a LOCAL Tari node -> the tari_payout_confirm
# profile is added, the keys render into .env, the secret file is written 600, and the view key is
# never echoed to stdout. Obvious dummy keys (all-a / all-b) so gitleaks can't mistake them.
TVIEW="$(printf 'a%.0s' $(seq 64))"  # 64 hex — a well-formed Tari private view key
TSPEND="$(printf 'b%.0s' $(seq 64))" # 64 hex — a well-formed Tari public spend key
# (1) OFF by default: no tari view key -> feature disabled, tari_payout_confirm profile absent.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari payout confirm off by default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_PAYOUT_CONFIRM_ENABLED)" "false"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*tari_payout_confirm*) bad "no tari-wallet profile when view key unset" "tari_payout_confirm leaked into COMPOSE_PROFILES" ;;
*) ok "no tari-wallet profile when view key unset" ;;
esac
# (2) ON (local node): tari view key + spend key set -> profile added, keys rendered, flag true.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a tari view key succeeds" "$?" "0"
assert_eq "tari payout confirm enabled renders true" "$(run_sourced "$V" env_get_file "$V/.env" TARI_PAYOUT_CONFIRM_ENABLED)" "true"
assert_eq "tari view key rendered into .env" "$(run_sourced "$V" env_get_file "$V/.env" TARI_VIEW_KEY)" "$TVIEW"
assert_contains "tari-wallet profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "tari_payout_confirm"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)" ] && ok "tari wallet password generated" || bad "tari wallet password generated" "empty"
# The secret file is written owner-only (600) and contains the view key; it is NOT world-readable.
secret_file="$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_SECRET_FILE)"
[ -f "$secret_file" ] && ok "tari wallet secret file written" || bad "tari wallet secret file written" "missing $secret_file"
perms="$(stat -c '%a' "$secret_file" 2>/dev/null || stat -f '%Lp' "$secret_file" 2>/dev/null)"
assert_eq "tari wallet secret file is owner-only (600)" "$perms" "600"
assert_contains "secret file carries the view key for the container" "$(cat "$secret_file")" "$TVIEW"
# The view key must NEVER be echoed to stdout by apply — only land in the owner-only .env / secret file.
case "$out" in
*"$TVIEW"*) bad "tari view key never printed by apply" "the tari view key leaked into apply stdout" ;;
*) ok "tari view key never printed by apply" ;;
esac
# The tari wallet password is preserved across a re-apply so the existing wallet DB can be reopened.
tpw1="$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari wallet password preserved across apply" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)" "$tpw1"
# (3) A view key WITHOUT the spend key -> refused (a view-only wallet needs both).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari view key without spend key rejected" "$?" "1"
assert_contains "missing-spend-key message" "$out" "tari.spend_public_key"
# (4) A malformed tari view key (not 64 hex) is rejected before it reaches the wallet.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"nope","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed tari view key rejected" "$?" "1"
assert_contains "malformed tari view-key message" "$out" "64-character hex"
# (5) A spend key PRESENT but malformed (not 64 hex) is rejected — the require-both check keys off
# the same 64-hex shape as the view key, so a garbage spend key fails just like a missing one (#523).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s","spend_public_key":"deadbeef"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed tari spend key rejected" "$?" "1"
assert_contains "malformed spend-key message names spend_public_key" "$out" "tari.spend_public_key"

echo "== black-box: tari.payout_scan_birthday validation (#523) =="
# The restore-point birthday is validated only on the view-key path (it feeds the tari-wallet). It
# is "auto" or a u16 days-since-epoch (0–65535) — a block height or an out-of-range value is a
# common mistake that must fail at apply, not silently mis-restore the wallet. Keys are valid so
# only the birthday is under test.
# (1) A non-integer birthday (a block height, say) is refused.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"height-3200000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-integer birthday rejected" "$?" "1"
assert_contains "non-integer birthday message names the field" "$out" "tari.payout_scan_birthday"
# (2) An in-range-looking but too-large birthday (> 65535, e.g. a block height) is refused.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"99999"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "out-of-range birthday rejected" "$?" "1"
assert_contains "out-of-range birthday message names the u16 ceiling" "$out" "65535"
# (3) A valid u16 birthday applies and reflects verbatim into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"1000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid birthday accepted" "$?" "0"
assert_eq "valid birthday reflected into .env" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_BIRTHDAY)" "1000"

echo "== black-box: tari.mode remote (#103) =="
# The Tari sibling of monero.mode remote: mirrors the Monero pattern above (host:port render,
# missing-host error, mode/view-key gating), so a third-party or fleet-shared Tari base node works
# the same way an operator already expects from Monero.

# (1) local (default): TARI_GRPC_ADDRESS renders the bundled node's fixed bridge IP, and local_tari
# is added to COMPOSE_PROFILES so compose actually starts it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "local tari mode applies cleanly" "$?" "0"
assert_eq "local tari renders the bundled node's gRPC address" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "172.28.0.27:18142"
assert_contains "local_tari profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "local_tari"

# (2) remote: TARI_GRPC_ADDRESS renders host:port from tari.remote, and local_tari is OMITTED from
# COMPOSE_PROFILES so the bundled node stays off. Port defaults to 18142 when unset.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "remote tari mode applies cleanly" "$?" "0"
assert_eq "remote tari renders host:port with the default gRPC port" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "tari.example.com:18142"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*local_tari*) bad "no local_tari profile in remote tari mode" "local_tari leaked into COMPOSE_PROFILES" ;;
*) ok "no local_tari profile in remote tari mode" ;;
esac
# A remote node still renders SOME TARI_MEM_LIMIT placeholder (compose interpolation must resolve
# even though the profiled-off tari service never uses it) rather than an empty value.
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" ] && ok "remote tari still renders a TARI_MEM_LIMIT placeholder" || bad "remote tari still renders a TARI_MEM_LIMIT placeholder" "empty"

# (3) remote with a custom grpc_port reflects verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com","grpc_port":28142}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote tari custom grpc_port reflected" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "tari.example.com:28142"

# (4) remote mode with no host: renders an empty TARI_GRPC_ADDRESS -> p2pool/dashboard dial nothing,
# merge-mining can't start. Must abort at validation, not silently proceed.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "remote tari mode without a host rejected" "$rc" "1"
assert_contains "tari remote-host message" "$out" "tari.remote.host"

# (5) remote Tari node + tari.view_key -> refused loudly (Phase 1 is local-only for the same reason
# as Monero's #381 gate: scanning through a third-party node changes the trust story).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com"},"view_key":"%s","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari view key on a remote node rejected" "$?" "1"
assert_contains "remote tari view-key message names the field" "$out" "tari.view_key"

# (6a) tari.remote.host carrying a newline is rejected. Defence-in-depth: the central control-char
# guard catches it first (a newline in ANY value would forge a second .env line), before the
# per-field is_valid_host check below even runs — so assert rejection + no forged line, not a
# field-specific message.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"1.2.3.4\\nEVIL=pwned"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari.remote.host with a newline rejected" "$?" "1"
case "$(cat "$V/.env" 2>/dev/null)" in
*EVIL=pwned*) bad "no forged .env line from a crafted host" "EVIL=pwned leaked into .env" ;;
*) ok "no forged .env line from a crafted host" ;;
esac

# (6b) A comma in tari.remote.host is rejected by is_valid_host — a comma is NOT a control char, so
# it slips past the central guard above, but it would inject socat address options in the p2pool
# entrypoint's bridge command (TCP:$_mmhost:$_mmport). This is the field-specific guard's own case.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"1.2.3.4,fork,reuseaddr"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari.remote.host with a comma rejected" "$?" "1"
assert_contains "comma-host message names the field" "$out" "tari.remote.host"

# (6c) A non-numeric tari.remote.grpc_port is rejected.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com","grpc_port":"18142; rm -rf"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-numeric tari.remote.grpc_port rejected" "$?" "1"
assert_contains "bad grpc_port message names the field" "$out" "tari.remote.grpc_port"

# (7) An invalid tari.mode value is rejected before it ever reaches render_env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"bogus"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "invalid tari.mode rejected" "$?" "1"
assert_contains "invalid tari.mode message" "$out" "tari.mode must be"

echo "== black-box: profile deactivation removes the old container (#795) =="
# `compose up --remove-orphans` does not remove a profile-deactivated service's container — the
# service is still in the compose file, so compose does not count it as an orphan — and a tari
# local→remote switch left the old node running (offline, re-syncing) against a remote-mode
# config. Apply must issue an explicit `compose rm -sf` for every profile-gated service whose
# profile is off, BEFORE the recreate up. Asserted through the docker-stub call log.
# (1) Baseline, both nodes local: the reconcile list is exactly the (off) payout-confirm wallets —
# neither node container is touched.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
SWLOG="$V/docker-switch.log"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "baseline local-nodes apply exits 0" "$?" "0"
assert_contains "local nodes: only the off payout wallets reconcile" "$(cat "$SWLOG")" "compose rm -sf wallet-rpc tari-wallet"
# (2) tari local→remote (the #795 reproduction): the tari container joins the removal list. No
# re-seed — the committed local-mode .env from (1) makes this a real transition.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari local-to-remote switch applies cleanly" "$?" "0"
assert_contains "switch removes the deactivated tari container" "$(cat "$SWLOG")" "compose rm -sf tari wallet-rpc tari-wallet"
# The removal must precede the recreate up — the point is the old node never runs beside the
# remote-mode p2pool, not that it eventually disappears.
assert_contains "tari removal happens before the recreate up" "$(sed '/compose up --pull never -d --remove-orphans/q' "$SWLOG")" "compose rm -sf tari wallet-rpc tari-wallet"
# (3) monerod rides the same guard on a monero local→remote switch.
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero local-to-remote switch applies cleanly" "$?" "0"
assert_contains "switch removes the deactivated monerod container" "$(cat "$SWLOG")" "compose rm -sf monerod wallet-rpc tari-wallet"
# (4) Reverse switch, tari remote→local (#822): the freshly-reactivated profile's service must be
# left alone by the reconcile — only the still-off profiles (monerod stays remote, both payout
# wallets off) reconcile — and the recreate up must run with local_tari back in the committed
# profile list, which is what brings the tari container up again. First commit a tari-remote .env
# so the switch back is a real transition.
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari remote baseline applies cleanly" "$?" "0"
assert_not_contains "tari remote baseline commits a profile list without local_tari" "$(grep '^COMPOSE_PROFILES=' "$V/.env")" "local_tari"
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mode":"local"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari remote-to-local switch applies cleanly" "$?" "0"
# The reconcile list is exactly the still-deactivated profiles — no tari between monerod and
# wallet-rpc (the list renders in fixed map order), so the reactivated service's container is
# never touched by the removal.
assert_contains "reverse switch reconciles only the still-off profiles" "$(cat "$SWLOG")" "compose rm -sf monerod wallet-rpc tari-wallet"
assert_not_contains "reverse switch leaves the reactivated tari alone" "$(cat "$SWLOG")" "rm -sf tari "
# And the recreate up runs AFTER that reconcile with local_tari committed back into the profile
# list — that up is what (re)creates the tari container.
assert_contains "recreate up follows the reconcile" "$(sed -n '/compose rm -sf monerod wallet-rpc tari-wallet/,$p' "$SWLOG")" "compose up --pull never -d --remove-orphans"
assert_contains "reactivated profile is live for the recreate up" "$(grep '^COMPOSE_PROFILES=' "$V/.env")" "local_tari"

echo "== black-box: monero.rpc_lan_access + prep_blocks_threads reflect into .env (#523) =="
# The rendered .env must match the config input. rpc_lan_access gates the monerod RPC bind: default
# (unset) keeps it localhost-only; true opens it to the LAN. prep_blocks_threads overrides the
# host-core-derived block-verification thread count verbatim when it is an integer.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "rpc_lan_access default binds monerod RPC to localhost" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_BIND)" "127.0.0.1"
# The #760 siblings default localhost-only the same way: ZMQ and the Tari gRPC publish.
assert_eq "zmq_lan_access default binds monerod ZMQ to localhost" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_BIND)" "127.0.0.1"
assert_eq "grpc_lan_access default binds tari gRPC to localhost" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_BIND)" "127.0.0.1"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","rpc_lan_access":true,"zmq_lan_access":true,"prep_blocks_threads":6}, "tari":{"wallet_address":"T","grpc_lan_access":true}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "rpc_lan_access true binds monerod RPC to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_BIND)" "0.0.0.0"
assert_eq "zmq_lan_access true binds monerod ZMQ to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_BIND)" "0.0.0.0"
assert_eq "grpc_lan_access true binds tari gRPC to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_BIND)" "0.0.0.0"
assert_eq "prep_blocks_threads override reflected verbatim" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_PREP_THREADS)" "6"

echo "== black-box: monero.out_peers renders to .env, bounds enforced (#595) =="
# Default 48 when unset (the Tor-IBD bandwidth default); an explicit value lands verbatim in
# MONERO_OUT_PEERS (each outbound peer ≈ one Tor circuit — the steady-state Tor CPU lever);
# out-of-range or non-integer values are refused before anything is written.
assert_eq "out_peers default renders 48" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_OUT_PEERS)" "48"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":32}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "out_peers 32 reflected verbatim" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_OUT_PEERS)" "32"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":"lots"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-integer out_peers refused" "$?" "1"
assert_contains "out_peers refusal names the bounds" "$out" "between 8 and 1024"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":4}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "below-minimum out_peers refused" "$?" "1"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":2000}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "above-maximum out_peers refused" "$?" "1"
assert_contains "above-maximum refusal names the bounds" "$out" "between 8 and 1024"

echo "== black-box: tor.auto_heal renders to .env (#424) =="
# The dashboard's healer reads TOR_AUTO_HEAL from .env. Key absent -> off (the stack never
# restarts its privacy boundary unbidden); explicit true -> on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal defaults to off" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "false"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "tor":{"auto_heal":true}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tor.auto_heal opt-in renders true" "$(run_sourced "$V" env_get_file "$V/.env" TOR_AUTO_HEAL)" "true"

echo "== black-box: apply preserves secrets + propagates =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
DOCKER_LOG="$V/docker.log"
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "pool flag propagated" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--mini"
# Default routes outbound sidechain P2P through Tor (#165): the rendered P2POOL_FLAGS carries the
# pool flag AND the Tor SOCKS flags (no p2pool.clearnet set in this config).
assert_contains "outbound P2P via Tor by default (#165)" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_eq "stratum_bind default" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_BIND)" "0.0.0.0"
# stratum_port (#172) defaults to 3333, so an unconfigured stack keeps today's behaviour, and the
# internal proxy→p2pool leg (P2POOL_URL) stays :3333 whatever the operator-facing port says.
assert_eq "stratum_port default" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_PORT)" "3333"
assert_eq "P2POOL_URL keeps the internal :3333" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_URL)" "172.28.0.28:3333"
assert_eq "token preserved" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
assert_eq "onion preserved" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_ONION_ADDRESS)" "p2pa.onion"
assert_eq "tari_required default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"
assert_eq "fail_closed default off (#490)" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_FAIL_CLOSED)" "false"
# The new-release check (#224) defaults ON when absent from config — it's Tor-routed, so it leaks
# nothing, and an operator who wants zero GitHub contact sets check_for_updates:false to opt out.
assert_eq "check_for_updates default on" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "true"
# Both new xmrig-proxy knobs default to OFF/no-fee when absent from config (#152/#173).
assert_eq "stratum auth off by default" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" ""
assert_eq "donate-level 0 by default (no fee)" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "0"
# Build provenance is exported for the build args, not persisted to .env (Issue #58) — so a git pull
# never shows up as a config change. Assert it stays out of the rendered .env.
assert_eq "provenance not written to .env" "$(run_sourced "$V" env_get_file "$V/.env" PITHEAD_VERSION)" ""
assert_contains "compose up called (build mode)" "$(cat "$DOCKER_LOG")" "compose up --pull never -d --remove-orphans"

# Regression (Issue #58): a second apply with nothing changed must report no changes and exit 0
# cleanly — never tripping the ERR trap. (Provenance keys briefly leaked into this diff; when they
# were the only delta the filter emptied the pipeline and `set -o pipefail` aborted apply.)
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "no-op apply exits 0" "$rc" "0"
assert_contains "no-op apply reports no changes" "$out" "No configuration changes detected"
case "$out" in
*"aborted unexpectedly"*) bad "no-op apply does not trip the error trap" "got: $out" ;;
*) ok "no-op apply does not trip the error trap" ;;
esac
# tari.mem_limit absent => "auto" is a safety ceiling: host RAM minus a >=2 GB reserve, floored at
# 2048m. Assert it ends in 'm', is >= the 2048m floor, and never exceeds physical RAM.
mem="$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)"
host_ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
case "$mem" in
*m)
    n="${mem%m}"
    if [ "$n" -ge 2048 ] && { [ "$host_ram_mb" -le 0 ] || [ "$n" -le "$host_ram_mb" ]; }; then
        ok "tari mem auto is a sane ceiling ($mem, host ${host_ram_mb}m)"
    else bad "tari mem auto sane ceiling" "got [$mem] on ${host_ram_mb}m host"; fi
    ;;
*) bad "tari mem auto has m suffix" "got [$mem]" ;;
esac

# A custom p2pool.stratum_port (#172) propagates to STRATUM_PORT; the internal proxy→p2pool leg
# (P2POOL_URL) is deliberately untouched — only the operator-facing published port moves.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_port":4444}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_PORT)" "4444"
assert_eq "custom stratum_port leaves P2POOL_URL internal" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_URL)" "172.28.0.28:3333"

# Non-blocking Tari (dashboard.tari_required:false) propagates as TARI_REQUIRED=false.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","tari_required":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari_required propagated false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

# Opt-in fail-closed (dashboard.fail_closed:true) propagates as DASHBOARD_FAIL_CLOSED=true (#490).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","fail_closed":true} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "fail_closed propagated true" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_FAIL_CLOSED)" "true"

# Opting out (dashboard.check_for_updates:false) propagates as DASHBOARD_CHECK_UPDATES=false (#224) —
# only an explicit false disables it (anything else, incl. absent, stays the default-on true).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","check_for_updates":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "check_for_updates opt-out propagated false" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "false"

# Telegram defaults (#121): no telegram block => disabled, per-event toggles default on.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram disabled by default" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_ENABLED)" "false"
assert_eq "telegram event defaults on" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_NODE_DOWN)" "true"

# Telegram enabled: token/chat_id + per-event toggles propagate from config.json into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","events":{"worker_offline":false}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram enabled propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_ENABLED)" "true"
assert_eq "telegram token propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_BOT_TOKEN)" "BOTSECRET"
assert_eq "telegram chat_id propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_CHAT_ID)" "-100123"
assert_eq "telegram per-event override off" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_WORKER_OFFLINE)" "false"
assert_eq "telegram unset event stays on" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_EVENT_NODE_DOWN)" "true"
# The bot token is a secret: the apply preview must not print it.
case "$out" in
*BOTSECRET*) bad "telegram token not printed by apply" "leaked in: $out" ;;
*) ok "telegram token not printed by apply" ;;
esac

# Interactive command interface (#45): off by default, opt-in via telegram.commands.enabled.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram commands off by default" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_COMMANDS_ENABLED)" "false"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","commands":{"enabled":true}} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "telegram commands opt-in propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_COMMANDS_ENABLED)" "true"

# Daily-summary time (#121): defaults to 08:00; an explicit telegram.daily_summary_time propagates.
assert_eq "daily summary time defaults to 08:00" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_DAILY_SUMMARY_TIME)" "08:00"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "telegram":{"enabled":true,"bot_token":"BOTSECRET","chat_id":"-100123","daily_summary_time":"21:30"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "daily summary time propagated" "$(run_sourced "$V" env_get_file "$V/.env" TELEGRAM_DAILY_SUMMARY_TIME)" "21:30"

# Webhook + ntfy alert sinks (#380): no notifications block => everything off, Tor default on.
assert_eq "webhook urls default empty" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_WEBHOOK_URLS)" ""
assert_eq "ntfy url default empty" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_URL)" ""
assert_eq "ntfy token default empty" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_TOKEN)" ""
assert_eq "notify tor defaults on" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_TOR)" "true"
# Configured block propagates: the webhook list joins to one space-separated value, ntfy url/token
# land verbatim, tor:false carries through — and apply never prints the URL/token secrets.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "notifications":{"webhooks":["https://hook.example/a","https://hook2.example/b?key=HOOKSECRET"],"ntfy":{"url":"https://ntfy.sh/PITTOPIC","token":"NTFYSECRET"},"tor":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "webhook urls join space-separated" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_WEBHOOK_URLS)" "https://hook.example/a https://hook2.example/b?key=HOOKSECRET"
assert_eq "ntfy url propagated" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_URL)" "https://ntfy.sh/PITTOPIC"
assert_eq "ntfy token propagated" "$(run_sourced "$V" env_get_file "$V/.env" NTFY_TOKEN)" "NTFYSECRET"
assert_eq "notify tor opt-out propagated" "$(run_sourced "$V" env_get_file "$V/.env" NOTIFY_TOR)" "false"
case "$out" in
*HOOKSECRET* | *NTFYSECRET* | *PITTOPIC*) bad "webhook/ntfy secrets not printed by apply" "leaked in: $out" ;;
*) ok "webhook/ntfy secrets not printed by apply" ;;
esac

# Hashrate-loss detector knobs (#99): default 50% over 10 min; explicit dashboard overrides propagate.
assert_eq "hashrate drop threshold default 50" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_THRESHOLD_PCT)" "50"
assert_eq "hashrate drop minutes default 10" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_MINUTES)" "10"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","hashrate_drop_threshold":40,"hashrate_drop_minutes":5} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "hashrate drop threshold override propagated" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_THRESHOLD_PCT)" "40"
assert_eq "hashrate drop minutes override propagated" "$(run_sourced "$V" env_get_file "$V/.env" HASHRATE_DROP_MINUTES)" "5"

# Event-set consistency (#121/#45): every telegram.events.* key in config.reference.json must be
# rendered by pithead into .env AND declared in docker-compose.yml — so adding an alert event in one
# surface but forgetting another fails here. (The Python side — AlertService.EVT_* vs config.py's
# TELEGRAM_EVENTS — is guarded by a dashboard unit test.) The .env above has all events at their
# default (no events overrides in that config), so each should render "true".
compose_text="$(cat "$ROOT/docker-compose.yml")"
while IFS= read -r ev; do
    up=$(printf '%s' "$ev" | tr '[:lower:]' '[:upper:]')
    assert_eq "telegram event '$ev' rendered to .env" \
        "$(run_sourced "$V" env_get_file "$V/.env" "TELEGRAM_EVENT_$up")" "true"
    assert_contains "telegram event '$ev' declared in docker-compose.yml" \
        "$compose_text" "TELEGRAM_EVENT_$up="
done < <(jq -r '.telegram.events | keys[]' "$ROOT/config.reference.json")

# #502/#529: p2pool.pool defaults to "mini" (the global default — config.reference.json, the two
# `.p2pool.pool // "mini"` code fallbacks, and the wizard Enter-through all agree). A config that
# OMITS p2pool.pool must render the mini sidechain flag, not the old "main". Standalone config so
# it doesn't disturb the propagate block above.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$V/docker.log" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "omitted p2pool.pool defaults to the mini sidechain flag (#502)" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)" "--mini"

echo "== black-box: payout-wallet change needs a typed confirm (#375) =="
# Swapping the payout wallet is the highest-value tamper: apply must demand the first 8 chars of
# the new address typed back (a pasted 'y' can't wave it through), while -y keeps automation alive.
WALLET2="4$(printf 'B%.0s' $(seq 94))" # a second valid mainnet primary; first 8 chars = 4BBBBBBB
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)" # baseline .env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET2" >"$V/config.json"
# (1) A bare 'y' — the old destructive confirm — must NOT pass; .env stays untouched.
out="$(cd "$V" && printf 'y\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
rc=$?
assert_rc "wallet change with 'y' aborts cleanly" "$rc" "0"
assert_contains "wallet prompt shows the new address's first 8 chars" "$out" "(4BBBBBBB)"
assert_contains "wallet change cancelled" "$out" "Apply cancelled"
assert_eq "wallet unchanged in .env after abort" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"
# The preview/prompt never echoes the full new address (only its first 8 chars).
assert_not_contains "full new address not echoed by apply" "$out" "$WALLET2"
# (2) Typing the first 8 chars confirms and applies.
out="$(cd "$V" && printf '4BBBBBBB\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "typed confirm applies" "$?" "0"
assert_eq "wallet updated in .env after typed confirm" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET2"
# (3) -y still bypasses the prompt for automation.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1 </dev/null)"
assert_rc "apply -y skips the typed confirm" "$?" "0"
assert_eq "wallet updated with -y" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"

# A TARI-only wallet change demands the same typed confirm (the suite above only drove Monero).
TARI2="TARITARITARI2" # first 8 chars = TARITARI
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" "$TARI2" >"$V/config.json"
out="$(cd "$V" && printf 'y\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "tari wallet change with 'y' aborts cleanly" "$?" "0"
assert_contains "tari wallet prompt shows the new address's first 8 chars" "$out" "(TARITARI)"
assert_eq "tari wallet unchanged in .env after abort" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "T"
out="$(cd "$V" && printf 'TARITARI\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "tari typed confirm applies" "$?" "0"
assert_eq "tari wallet updated in .env after typed confirm" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI2"

# BOTH wallets changing in one apply needs TWO typed confirms — one prefix must never wave both
# through (env_changed_keys sorts, so Monero prompts first, then Tari).
TARI3="TARIXTARIX3" # first 8 chars = TARIXTAR
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET2" "$TARI3" >"$V/config.json"
out="$(cd "$V" && printf '4BBBBBBB\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "both-wallet change with one prefix aborts cleanly" "$?" "0"
assert_contains "both-wallet change prompts for the Monero prefix" "$out" "(4BBBBBBB)"
assert_contains "both-wallet change prompts for the Tari prefix too" "$out" "(TARIXTAR)"
assert_contains "both-wallet change with one prefix is cancelled" "$out" "Apply cancelled"
assert_eq "monero wallet unchanged after one-prefix abort" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET"
assert_eq "tari wallet unchanged after one-prefix abort" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI2"
out="$(cd "$V" && printf '4BBBBBBB\nTARIXTAR\n' | DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply 2>&1)"
assert_rc "both typed confirms apply" "$?" "0"
assert_eq "monero wallet updated after both confirms" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_WALLET_ADDRESS)" "$WALLET2"
assert_eq "tari wallet updated after both confirms" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" "$TARI3"

# An explicit tari.mem_limit is passed through verbatim (overriding the "auto" host-RAM scaling).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mem_limit":"3072m"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari mem_limit explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" "3072m"

# Healthchecks.io (#79): absent => no ping URL (off).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks off by default (no ping URL)" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" ""

# A ping URL propagates verbatim to .env (the URL is the on switch; Tor is always used).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"}, "healthchecks":{"ping_url":"https://hc-ping.com/abc"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "healthchecks ping_url propagated" "$(run_sourced "$V" env_get_file "$V/.env" HEALTHCHECKS_PING_URL)" "https://hc-ping.com/abc"

echo "== unit+black-box: secret files are owner-only from creation (#368) =="
# The subshell umask must make the secret-bearing files 600 from the FIRST byte — a chmod after
# the write leaves a world-readable window on a shared host, and a silently failed chmod used to
# leave them 644 forever. The mv shim captures the credential temp file's mode BEFORE it lands on
# config.json, proving the mode at creation, not just the end state.
# GNU form first: `stat -c` errors cleanly on BSD/macOS, so the `||` fallback fires there. The
# reverse order is wrong — on Linux `stat -f` is a VALID flag (filesystem status) that succeeds
# with the wrong output, so the fallback never runs and CI (Linux) reads garbage.
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
file_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }
PB="$SANDBOX/perm368"
mkdir -p "$PB/bin"
printf '{ "monero": {} }\n' >"$PB/config.json"
cat >"$PB/bin/mv" <<'EOF'
#!/usr/bin/env bash
stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null # GNU form first (see file_mode note)
exec /usr/bin/mv "$@" # absolute path — a bare `mv` re-resolves to this stub and loops forever
EOF
chmod +x "$PB/bin/mv"
out="$( (umask 022 && PATH="$PB/bin:$PATH" run_sourced "$PB" persist_node_credentials user secret))"
assert_eq "credential temp file is 600 at creation (umask 022)" "$out" "600"
assert_eq "config.json is 600 after credential persist" "$(file_mode "$PB/config.json")" "600"
# Black-box: a full apply under the default umask must leave .env owner-only.
out="$( (cd "$V" && umask 022 && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1))"
assert_eq ".env is owner-only after apply (umask 022)" "$(file_mode "$V/.env")" "600"

echo "== black-box: xmrig-proxy knobs (#152 stratum auth, #173 donate-level) =="
# stratum_password "auto" generates + persists a stable secret and surfaces it for rigs; an explicit
# proxy.donate_level propagates verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "proxy":{"donate_level":1}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
sp1="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
case "$sp1" in ?*) ok "stratum_password auto generated a secret" ;; *) bad "stratum_password auto generated a secret" "got empty" ;; esac
assert_eq "donate-level explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "1"
assert_contains "stratum auth surfaced for rigs" "$(run_sourced "$V" announce_stratum_auth 2>&1)" "Stratum authentication is ON"

echo "== unit: announce_local_miner hands off the stratum URL + secret only when opted in (#593) =="
# The local-miner opt-in surfaces the two values a co-located RigForge install needs (pool URL +
# stratum secret) and NOTHING else — off by default, loopback when the bind allows it, the bound
# LAN address when it doesn't (the #593 stratum_bind edge case), and RigForge-owns-tuning stated.
LM="$SANDBOX/lm"
mkdir -p "$LM"
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
# Opt-out (default): prints nothing at all.
printf '{"local_miner":{"enabled":false}}' >"$LM/config.json"
assert_eq "opt-out prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Absent block also prints nothing (default false).
printf '{}' >"$LM/config.json"
assert_eq "absent local_miner prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Opt-in, 0.0.0.0 bind: loopback URL + the secret + the RigForge-owns-tuning note.
printf '{"local_miner":{"enabled":true}}' >"$LM/config.json"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "opt-in surfaces loopback pool URL" "$lm_out" "127.0.0.1:3333"
assert_contains "opt-in surfaces the stratum secret" "$lm_out" "s3cr3t"
assert_contains "opt-in states RigForge owns host tuning" "$lm_out" "RigForge"
# Custom port + specific LAN bind: target the bound address, not hardcoded loopback (#593 edge case).
printf 'STRATUM_BIND=192.168.1.9\nSTRATUM_PORT=4444\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "LAN bind targets the bound address:port" "$lm_out" "192.168.1.9:4444"
# No stratum password set: say so rather than printing a blank pass.
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=\n' >"$LM/.env"
assert_contains "no-password case is stated explicitly" "$(run_sourced "$LM" announce_local_miner 2>&1)" "none set"

# Re-apply: an "auto" password must be STABLE (reused, not rotated) — like the proxy token.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_password auto stable across apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "$sp1"

echo "== black-box: stratum-over-TLS render + cert lifecycle (#261) =="
# Default: off, no cert generated. The dir var still renders (compose always mounts it :ro).
assert_eq "stratum TLS off by default" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "false"
[ ! -f "$V/data/proxy-tls/cert.pem" ] && ok "no cert generated while TLS is off" ||
    bad "no cert generated while TLS is off" "cert.pem exists"
# Knob on: real openssl generates the keypair once; key owner-only; fingerprint announced and
# STABLE across a second apply (the fingerprint is what every rig pins — regenerating it on each
# apply would break every TLS rig).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum TLS renders true" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "true"
[ -f "$V/data/proxy-tls/cert.pem" ] && [ -f "$V/data/proxy-tls/key.pem" ] &&
    ok "TLS keypair generated on first apply" || bad "TLS keypair generated on first apply" "missing files"
assert_eq "TLS key is owner-only" "$(file_mode "$V/data/proxy-tls/key.pem")" "600"
assert_contains "fingerprint announced for rig pinning" "$out" "Stratum TLS is ON"
fp1="$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "cert (and its pinned fingerprint) stable across apply" \
    "$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)" "$fp1"
# announce_stratum_tls prints the pin in xmrig's format: 64 lowercase hex chars, no colons.
announced="$(run_sourced "$V" announce_stratum_tls 2>&1 | grep -oE '[0-9a-f]{64}' | head -1)"
assert_eq "announced fingerprint is the cert's own, xmrig format" \
    "$announced" "$(printf '%s' "$fp1" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
# compose forwards the toggle and mounts the keypair dir read-only.
assert_contains "compose passes PROXY_STRATUM_TLS to the proxy (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_STRATUM_TLS=${PROXY_STRATUM_TLS'
assert_contains "compose mounts the TLS keypair dir :ro (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_TLS_DIR:-./data/proxy-tls}:/tls:ro'

echo "== black-box: clearnet initial sync render (#183) =="
# Default (no flags): both daemons stay Tor-only — .env flags are false and the rendered Tari config
# keeps the Tor transport, empty DNS seeds, and an onion public address.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "false"
assert_eq "tari clearnet off by default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari default: Tor transport" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "tari default: DNS seeds empty" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari default: advertises onion" "$(cat "$V/build/tari/config.toml")" "/onion3/"

# Monero clearnet ON (Tari left off): only the Monero flag flips; Tari stays Tor. The apply preview
# must spell out the clearnet exposure (a CONFIRM change — disruptive, warned ⚠ on the host CLI).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":true}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"
assert_eq "tari clearnet still false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "false"
assert_contains "tari stays Tor when only monero is clearnet" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "apply preview warns clearnet exposure" "$out" "CLEARNET"

# Tari clearnet ON: pithead always renders the CANONICAL Tor config — the clearnet transform is
# applied per-start INSIDE the container (marker-gated, #234), so the host-rendered config.toml
# stays Tor even with the flag on. That's what lets the node return to Tor on its own after sync
# without pithead re-rendering clearnet over it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","clearnet_initial_sync":true}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari clearnet flag propagated true" "$(run_sourced "$V" env_get_file "$V/.env" TARI_CLEARNET_SYNC)" "true"
assert_contains "tari host-render stays Tor even with flag on (#234)" "$(cat "$V/build/tari/config.toml")" 'type = "tor"'
assert_contains "tari host-render keeps DNS seeds empty (#234)" "$(cat "$V/build/tari/config.toml")" "dns_seeds = []"
assert_contains "tari host-render still advertises the onion (#234)" "$(cat "$V/build/tari/config.toml")" "/onion3/"

# Truthy parse consistency (#183): a JSON string "yes" reads as enabled, like normalize_bool/MONERO_PRUNE.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","clearnet_initial_sync":"yes"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "monero clearnet truthy 'yes' => true" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_CLEARNET_SYNC)" "true"

# doctor flags the active clearnet sync (read-only). Re-render Tor-only first so later sections see a
# clean default, then assert doctor's WARN/OK both ways.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "doctor: OK when Tor-only (#183)" "$(cd "$V" && PATH="$V/bin:$PATH" ./pithead doctor 2>&1)" "Tor-only"

# p2pool compose↔image coupling fail-safe (#273): clearnet is off, so apply renders P2POOL_FLAGS with
# the #165 --socks5. doctor reads the RUNNING p2pool argv (/proc/1/cmdline, stubbed via P2POOL_PROC1)
# and must FAIL loudly if --socks5 is absent (a stale pre-#165 image silently dropping the env flags),
# and pass when it IS present. The config above (p2pool.pool=mini, clearnet default off) is reused.
dr273() { cd "$V" && P2POOL_PROC1="$1" PATH="$V/bin:$PATH" ./pithead doctor 2>&1; }
assert_contains "doctor FAILs when p2pool isn't on Tor — stale image (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --rpc-port 18081 --mini')" "STALE p2pool image"
assert_contains "doctor OK when p2pool IS routed over Tor (#273)" \
    "$(dr273 'p2pool --host 172.28.0.26 --mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor')" "routes outbound sidechain P2P via Tor"

echo "== black-box: local node creds auto-generated + persisted (#50) =="
# A local node with BLANK creds: apply must generate them, write them into .env AND back into
# config.json, and keep them stable on a second apply (don't regenerate every run).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"","node_password":""}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "auto-gen is logged" "$out" "Auto-generated missing local"
env_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
assert_eq "blank username -> admin in .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" "admin"
assert_eq "generated password is 32 chars" "${#env_pass}" "32"
assert_eq "username persisted to config.json" "$(jq -r '.monero.node_username' "$V/config.json")" "admin"
assert_eq "password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"
# Second apply must not rotate the now-populated creds.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "password stable across apply" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"

# A REMOTE node with blank creds means "no auth" — leave it empty, don't invent credentials.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote username left blank" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" ""
assert_eq "remote creds not persisted" "$(jq -r '.monero.node_username' "$V/config.json")" ""

# Custom remote rpc_port/zmq_port propagate to .env (the dashboard + p2pool read these to reach the
# node); both default to 18081/18083 but an operator can point at a node on non-standard ports.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com","rpc_port":28081,"zmq_port":28083}}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote rpc_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_PORT)" "28081"
assert_eq "remote zmq_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_PORT)" "28083"
# And the defaults apply when omitted (local node).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "zmq_port defaults to 18083" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_PORT)" "18083"

# `logs` forwards its service argument to `docker compose logs -f` (read-only follow).
seed_env
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead logs monerod 2>&1)"
assert_contains "logs follows (-f) the named service" "$(cat "$DOCKER_LOG")" "compose logs -f monerod"

echo "== black-box: upgrade re-renders generated config (#128) =="
# `upgrade` used to be just `up --build`, leaving the generated .env/Caddyfile/Tari config stale
# after a git pull. It must now re-render them while preserving secrets.
U="$SANDBOX/upgrade"
mkdir -p "$U/build/tari" "$U/build/dashboard" "$U/data/monero" "$U/data/tari" "$U/data/p2pool/stats" "$U/data/tor" "$U/data/dashboard"
: >"$U/build/dashboard/Dockerfile"
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
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$U/config.json"
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
mkdir -p "$A/build/tari" "$A/build/dashboard" "$A/bin" "$A/data/monero" "$A/data/tari" "$A/data/p2pool/stats" "$A/data/tor" "$A/data/dashboard"
: >"$A/build/dashboard/Dockerfile" # source-checkout marker → pithead builds (--pull never), #44
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
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$A/config.json"
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

echo "== black-box: status health check =="
# A docker stub driven by FAKE_STATES ("svc=state:health ..."; state "missing" = no container)
# so we can script each service's state and assert how `status` reports it.
make_status_stub() {
    local bin="$1"
    mkdir -p "$bin"
    cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
sub="$*"
case "$sub" in
  "compose config --services")
      for kv in $FAKE_STATES; do echo "${kv%%=*}"; done ;;
  "compose ps -aq "*)
      svc="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$svc" ] && [ "${kv#*=}" != "missing" ] && echo "$svc"
      done ;;
  "inspect "*)
      cid="${sub##* }"
      for kv in $FAKE_STATES; do
        [ "${kv%%=*}" = "$cid" ] && echo "${kv#*=}" | tr ':' ' '
      done ;;
esac
exit 0
EOF
    chmod +x "$bin/docker"
}
ST="$SANDBOX/status"
mkdir -p "$ST/bin"
cp "$STACK" "$ST/pithead"
make_status_stub "$ST/bin"
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node,local_tari\nHOST_IP=box.lan\n' >"$ST/.env"
ALL_UP="tor=running:healthy monerod=running:healthy p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"

# All services up -> success, friendly summary.
out="$(cd "$ST" && FAKE_STATES="$ALL_UP" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: all up exits 0" "$rc" "0"
assert_contains "status: all-up summary" "$out" "All expected services are up"

# A node down + proxy stopped -> node flagged, proxy treated as intentional failover.
NODE_DOWN="${ALL_UP/monerod=running:healthy/monerod=exited:none}"
NODE_DOWN="${NODE_DOWN/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$NODE_DOWN" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: node down exits 1" "$rc" "1"
assert_contains "status: proxy stop is intentional" "$out" "likely intentional"

# A stopped p2pool/xmrig-proxy with healthy nodes is intentional — the nodes pass their
# healthchecks while still syncing and the dashboard holds the miner until they're synced
# (#35), so status reports it as likely-intentional (exit 0), not a fault.
PROXY_ONLY="${ALL_UP/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$PROXY_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: proxy stop under sync hold exits 0" "$rc" "0"
assert_contains "status: proxy stop notes sync hold" "$out" "finish syncing"

P2POOL_ONLY="${ALL_UP/p2pool=running:none/p2pool=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$P2POOL_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: p2pool stop under sync hold exits 0" "$rc" "0"
assert_contains "status: p2pool stop notes sync hold" "$out" "finish syncing"

# Remote-node mode: the bundled monerod is not expected even if absent.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=\nHOST_IP=box.lan\n' >"$ST/.env"
REMOTE="tor=running:healthy monerod=missing p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: remote mode ignores monerod" "$rc" "0"

# Remote Tari mode (#103): the bundled tari container is not expected even if absent, mirroring
# monerod above — COMPOSE_PROFILES carries local_node (Monero local) but no local_tari.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$ST/.env"
REMOTE_TARI="tor=running:healthy monerod=running:healthy p2pool=running:none tari=missing xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE_TARI" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"
rc=$?
assert_rc "status: remote tari mode ignores tari" "$rc" "0"

echo "== black-box: doctor exit code (#127) =="
# doctor must EXIT NON-ZERO when a critical check fails, so it's usable as a cron/CI health gate
# (it previously always returned 0). Drive one failure via an unreachable Docker daemon; jq/openssl
# stay real on PATH so only the daemon check fails.
DOC="$SANDBOX/doctor"
mkdir -p "$DOC/bin"
cp "$STACK" "$DOC/pithead"
cat >"$DOC/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "info") exit 1 ;;   # daemon unreachable -> doctor records a critical FAIL
  *)      exit 0 ;;   # `--version`, `compose version`, etc. succeed
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$DOC/bin/sudo"
chmod +x "$DOC/bin/docker" "$DOC/bin/sudo"
printf '9.9.9\n' >"$DOC/VERSION" # #386: doctor's header must carry the stack version
out="$(cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1)"
rc=$?
assert_contains "doctor runs to the summary" "$out" "Diagnostics summary"
assert_contains "doctor flags the unreachable daemon" "$out" "Docker daemon is not reachable"
assert_rc "doctor exits 1 on a critical FAIL" "$rc" "1"
assert_contains "doctor header carries the version (#386)" "$out" "Version: pithead v9.9.9"

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

echo "== black-box: backup -> restore round-trip (#140) =="
# backup/restore touch irreplaceable state (onion keys, the dashboard DB) and have fiddly logic
# (leading-'/' strip, the disk pre-check, stop->backup->start). They shell out only to tar/du/df/
# docker/sudo, so a full round-trip is stubbable: the docker stub reports the stack NOT running, and
# a smart sudo runs tar/du/df for real (so the archive is genuinely created/extracted) but no-ops
# chown (we can't chown to 100:101 unprivileged). The archive stores paths relative to '/', and every
# path is under the sandbox, so `restore`'s `tar -C /` can only write back inside it (asserted below).
# Use the sandbox's PHYSICAL path (pwd -P): `restore` extracts at '/', and on macOS the /var ->
# /private/var symlink would otherwise make BSD tar refuse to "extract through symlink" (Linux /tmp
# isn't symlinked, so this is a no-op there).
BK="$(cd "$SANDBOX" && pwd -P)/backup"
mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
cp "$STACK" "$BK/pithead"
cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;;   # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run backup/restore's privileged commands as the test user, except chown (can't set 100:101
# unprivileged) which is accepted as a no-op so restore doesn't abort.
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/docker" "$BK/bin/sudo"
cat >"$BK/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=BKTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$BK/config.json"
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$BK/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$BK/data/dashboard/dashboard.db"

# 1) Backup creates a timestamped archive. --no-encrypt keeps this #140 round-trip on the plaintext
# path (encryption is exercised in the #374 block below); an unattended run without a passphrase
# now refuses rather than downgrading, so the flag is required here.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup exits 0" "$rc" "0"
archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$archive" ] && [ -f "$archive" ]; } && ok "backup archive created" || bad "backup archive created" "no archive under backups/"

# 2) Archive layout: the irreplaceable bits are in it; blockchains are NOT (no --with-chains).
listing="$(tar -tzf "$archive" 2>/dev/null)"
assert_contains "archive has config.json" "$listing" "config.json"
assert_contains "archive has .env" "$listing" ".env"
assert_contains "archive has Caddyfile" "$listing" "Caddyfile"
assert_contains "archive has the tor onion key" "$listing" "hs_ed25519_secret_key"
assert_contains "archive has the dashboard db" "$listing" "dashboard.db"
case "$listing" in
*data/monero* | *data/p2pool/* | *data/tari*) bad "archive excludes blockchains by default" "chain data present without --with-chains" ;;
*) ok "archive excludes blockchains by default" ;;
esac
# Safety tripwire: every archived path is under the sandbox, so restore's `tar -C /` can't escape it.
sandbox_rel="${BK#/}"
escaped="$(printf '%s\n' "$listing" | grep -v '^$' | grep -v "^$sandbox_rel" || true)"
assert_eq "archive paths stay inside the sandbox" "$escaped" ""

# 3) Round-trip: corrupt/delete the live files, restore, assert the originals come back in place.
printf 'CORRUPTED\n' >"$BK/Caddyfile"
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
rc=$?
assert_rc "restore exits 0" "$rc" "0"
assert_eq "restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4) Low-space pre-check (#127): a df reporting almost no free space makes backup prompt; answering
# "no" cancels and writes nothing, while --yes proceeds with a warning. The check runs BEFORE the
# stack is touched, so a cancel leaves everything as it was.
cat >"$BK/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/fake 100 99 1 99% /'
EOF
chmod +x "$BK/bin/df"
rm -f "$BK"/backups/pithead-backup-*.tar.gz
# stdin answers two prompts since #374: empty passphrase (-> plaintext fallback), then 'n'.
out="$(cd "$BK" && printf '\nn\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first" "$out" "Low free space"

echo "== black-box: encrypted backup -> restore (#374) =="
# The archive holds the stack's full secret material (onion keys, .env, dashboard DB), so backup
# encrypts by default (openssl aes-256-cbc + pbkdf2). Covered here: the unattended-without-
# passphrase REFUSAL (an automated run must never silently downgrade to plaintext), the explicit
# --no-encrypt opt-out, env-var and prompt encrypt round-trips, wrong-passphrase rejection BEFORE
# anything is touched, a tamper/truncation refusal before extraction, legacy/garbage archives, and
# that a failed encrypted backup leaves no file behind (the tar|openssl stream means no plaintext
# temp ever).
rm -f "$BK/bin/df" "$BK"/backups/pithead-backup-*

# 1a) --yes with no passphrase REFUSES (no silent plaintext downgrade for cron); writes nothing.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "unattended backup without passphrase exits non-zero" || bad "unattended backup without passphrase exits non-zero" "rc=0"
assert_contains "refusal names the missing passphrase" "$out" "PITHEAD_BACKUP_PASSPHRASE"
assert_eq "refused unattended backup writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
# 1b) --no-encrypt is the explicit plaintext opt-out (loud warning, exits 0, writes a plain archive).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "explicit --no-encrypt backup exits 0" "$rc" "0"
plain_optout="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_optout" ] && [ -f "$plain_optout" ]; } && ok "--no-encrypt writes a plaintext archive" || bad "--no-encrypt writes a plaintext archive" "no plain archive"
rm -f "$BK"/backups/pithead-backup-*

# 2) Env-var passphrase: a .enc archive with the openssl Salted__ header, no plaintext twin.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$enc_archive" ] && [ -f "$enc_archive" ]; } && ok "encrypted archive created (.enc)" || bad "encrypted archive created (.enc)" "no .enc under backups/"
assert_eq "archive starts with Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
plain_left="$(ls "$BK"/backups/*.tar.gz 2>/dev/null | head -1)"
assert_eq "no plaintext archive alongside the .enc" "$plain_left" ""
assert_contains "backup says to store the passphrase elsewhere" "$out" "passphrase"

# 3) Wrong passphrase: restore fails loudly before tar runs — live files untouched.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=wrong ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "wrong passphrase exits non-zero" || bad "wrong passphrase exits non-zero" "rc=0"
assert_contains "wrong passphrase names the cause" "$out" "rong passphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"

# 4) Right passphrase, via the prompt this time: full round-trip (archive was taken while the
# files held their -ORIG values, so restore must bring those back over the corrupted ones).
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && printf 'hunter2\n' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
assert_rc "encrypted restore exits 0" "$rc" "0"
assert_eq "encrypted restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "encrypted restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "encrypted restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4b) Tampered/truncated ciphertext (CBC has no MAC): a flip past the first block passes the
# cheap magic pre-flight but must be caught by the full-stream verify BEFORE tar writes anything,
# so the live files survive. Truncating the archive tail simulates corruption/tampering.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
head -c $(($(wc -c <"$enc_archive") - 32)) "$enc_archive" >"$BK/backups/truncated.tar.gz.enc"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead restore -y "$BK/backups/truncated.tar.gz.enc" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "tampered archive exits non-zero" || bad "tampered archive exits non-zero" "rc=0"
assert_contains "tampered archive names integrity failure" "$out" "integrity"
assert_eq "tampered archive leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated.tar.gz.enc"
# Leave the fixtures as this block found them (the round-trip above restored -ORIG) so the
# later plaintext-backup test captures -ORIG, not this test's probe value.
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"

# 5) Interactive prompt path: passphrase typed twice encrypts; a mismatch aborts with no archive.
out="$(cd "$BK" && printf 'pw\npw\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
assert_rc "prompted encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
assert_eq "prompted backup writes Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
rm -f "$BK"/backups/pithead-backup-*
out="$(cd "$BK" && printf 'pw\nother\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "passphrase mismatch exits non-zero" || bad "passphrase mismatch exits non-zero" "rc=0"
assert_contains "passphrase mismatch says so" "$out" "do not match"
assert_eq "passphrase mismatch writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""

# 6) --no-encrypt forces plaintext even with the env var set, and that legacy-format archive
# still restores through the gzip path (magic-byte detection, no flag).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "--no-encrypt backup exits 0" "$rc" "0"
plain_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_archive" ] && gzip -t "$plain_archive" 2>/dev/null; } && ok "--no-encrypt writes plain gzip" || bad "--no-encrypt writes plain gzip" "missing or not gzip"
printf 'CORRUPTED\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$plain_archive" 2>&1)"
rc=$?
assert_rc "plaintext archive still restores" "$rc" "0"
assert_eq "plaintext restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
rm -f "$BK"/backups/pithead-backup-*

# 6b) Truncated plaintext archive (#549): mirrors the encrypted-branch tamper/truncation check
# (4b above) on the gzip path — a truncated archive must be rejected by a full-stream `tar -tzf`
# verify BEFORE extraction, with nothing written, instead of half-overwriting config.json/.env.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
plain_trunc_src="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
config_before="$(cat "$BK/config.json")"
env_before="$(cat "$BK/.env")"
head -c "$(($(wc -c <"$plain_trunc_src") / 2))" "$plain_trunc_src" >"$BK/backups/truncated-plain.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/truncated-plain.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "truncated plaintext archive exits non-zero" || bad "truncated plaintext archive exits non-zero" "rc=0"
assert_contains "truncated plaintext archive names integrity failure" "$out" "integrity"
assert_eq "truncated plaintext archive leaves config.json untouched" "$(cat "$BK/config.json")" "$config_before"
assert_eq "truncated plaintext archive leaves .env untouched" "$(cat "$BK/.env")" "$env_before"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated-plain.tar.gz"

# 7) A failed encrypted backup (openssl dies mid-stream) removes the partial archive.
cat >"$BK/bin/openssl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BK/bin/openssl"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=x ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed encrypted backup exits non-zero" || bad "failed encrypted backup exits non-zero" "rc=0"
assert_eq "failed encrypted backup leaves nothing behind" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
rm -f "$BK/bin/openssl"

# 8) An archive that is neither encrypted nor gzip is refused before the overwrite prompt.
printf 'garbage-not-an-archive' >"$BK/backups/bogus.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/bogus.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "garbage archive is refused" || bad "garbage archive is refused" "rc=0"
assert_contains "garbage archive names the problem" "$out" "Not a pithead backup archive"
rm -f "$BK"/backups/bogus.tar.gz

# 9) Restore of an encrypted archive with no passphrase available (piped empty stdin) fails clean.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
out="$(cd "$BK" && printf '' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "encrypted restore w/o passphrase exits non-zero" || bad "encrypted restore w/o passphrase exits non-zero" "rc=0"
assert_contains "encrypted restore w/o passphrase explains" "$out" "PITHEAD_BACKUP_PASSPHRASE"
rm -f "$BK"/backups/pithead-backup-*

echo "== black-box: failed plaintext backup restarts a running stack, removes the partial archive (#551) =="
# Companion to the #549 test above: a failed tar must not strand the stack stopped, nor leave a
# partial (root-owned) archive that looks like a valid backup. Shadow tar to fail unconditionally
# and simulate a RUNNING stack (was_running=1), so the failure path must call stack_up for real —
# proven here by "compose up" showing up in the docker log, not by stubbing stack_up away.
FB="$SANDBOX/failbackup"
mkdir -p "$FB/build/tari" "$FB/data/tor" "$FB/data/dashboard" "$FB/bin"
cp "$STACK" "$FB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$FB/build/tari/"
cat >"$FB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose ps --status running -q") echo cid123 ;; # non-empty -> stack treated as RUNNING
esac
exit 0
EOF
cat >"$FB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
cat >"$FB/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FB/bin/docker" "$FB/bin/sudo" "$FB/bin/tar"
cat >"$FB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=FBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FB/config.json"

out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed plaintext backup (running stack) exits non-zero" || bad "failed plaintext backup (running stack) exits non-zero" "rc=0"
assert_contains "failed plaintext backup names the cause" "$out" "partial archive was removed"
assert_eq "failed plaintext backup leaves no archive behind" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
assert_contains "failed plaintext backup restarts the stack" "$(cat "$FB/docker.log" 2>/dev/null)" "compose up"

echo "== black-box: reset-dashboard targets .env dirs, not config.json (#139) =="
# reset-dashboard must wipe the LIVE deployment's data dirs (from .env), not a path the user may
# have edited into config.json without applying. docker = noop; sudo only LOGS (never executes the
# rm), so we can assert what it would have targeted without deleting anything.
R="$SANDBOX/reset"
mkdir -p "$R/bin" "$R/envdir/dashboard" "$R/envdir/p2pool"
cp "$STACK" "$R/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/bin/docker"
cat >"$R/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >> "${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$R/bin/docker" "$R/bin/sudo"
cat >"$R/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$R/envdir/dashboard
P2POOL_DATA_DIR=$R/envdir/p2pool
EOF
# config.json points the data dirs somewhere ELSE (a path the running stack never used).
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"T"}, "p2pool":{"data_dir":"%s/CONFIGONLY/p2pool"}, "dashboard":{"data_dir":"%s/CONFIGONLY/dashboard"} }\n' "$WALLET" "$R" "$R" >"$R/config.json"
SUDO_LOG="$R/sudo.log"
: >"$SUDO_LOG"
out="$(cd "$R" && SUDO_LOG="$SUDO_LOG" PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard succeeds" "$rc" "0"
sudo_calls="$(cat "$SUDO_LOG")"
assert_contains "reset rm targets the .env dashboard dir" "$sudo_calls" "rm -rf $R/envdir/dashboard"
case "$sudo_calls" in *CONFIGONLY*) bad "reset must ignore the config-only data_dir" "$sudo_calls" ;; *) ok "reset ignores the config-only data_dir" ;; esac

echo "== black-box: reset-dashboard refuses to guess without .env dirs (#139) =="
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$R/.env"
out="$(cd "$R" && SUDO_LOG=/dev/null PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset refuses with no data dirs in .env" "$rc" "1"
assert_contains "reset refuse message" "$out" "refusing to guess"

echo "== black-box: reset-dashboard's final compose_up_checked is if!-guarded, not bare (#557/#180) =="
# Before #557: the last compose_up_checked call in reset_dashboard was bare (every OTHER call site
# wraps it in `if !`, per the contract at compose_up_checked's own definition). A bare call let a real
# compose failure trip errexit INSIDE compose_up_checked's own `docker compose up | tee` pipeline,
# before the #180 subnet-collision explanation printed. Real `./pithead` (not sourced) arms
# `trap on_err ERR` exactly like production, so this reproduces the actual operator experience.
RD557="$SANDBOX/reset557"
mkdir -p "$RD557/bin" "$RD557/envdir/dashboard" "$RD557/envdir/p2pool"
cp "$STACK" "$RD557/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RD557/bin/sudo"
cat >"$RD557/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose up"*)
    echo "Error response from daemon: Pool overlaps with other one on this address space" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$RD557/bin/docker" "$RD557/bin/sudo"
cat >"$RD557/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
NETWORK_SUBNET=172.28.0.0/24
DASHBOARD_DATA_DIR=$RD557/envdir/dashboard
P2POOL_DATA_DIR=$RD557/envdir/p2pool
EOF
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"T"} }\n' "$WALLET" >"$RD557/config.json"
out="$(cd "$RD557" && PATH="$RD557/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard: compose failure still exits 1 (fail-closed unchanged)" "$rc" "1"
assert_contains "reset-dashboard: #180 subnet-collision explanation reaches the operator (#557)" \
    "$out" "Docker refused the stack's bridge subnet"
assert_contains "reset-dashboard: crafted failure message names the retry command" "$out" "did NOT come back up"

echo "== black-box: rotate-secrets regenerates the internal credentials (#378) =="
# One command rotates the local Monero RPC password, the "auto" stratum password, and
# PROXY_AUTH_TOKEN — the three values apply/load_preserved_state otherwise preserve forever.
# Baseline: an applied local-mode config with stratum auth on "auto".
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"oldrpcpass"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rot_sp_old="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
rm -f "$V"/config.json.bak-* "$V"/.env.bak-*
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
rc=$?
assert_rc "rotate-secrets exits 0" "$rc" "0"
rot_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
rot_sp="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
rot_token="$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)"
assert_eq "RPC password rotated (32 chars)" "${#rot_pass}" "32"
assert_eq "RPC password changed" "$([ "$rot_pass" != "oldrpcpass" ] && echo changed)" "changed"
assert_eq "new RPC password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$rot_pass"
assert_eq "stratum password changed" "$([ -n "$rot_sp" ] && [ "$rot_sp" != "$rot_sp_old" ] && echo changed)" "changed"
assert_eq "proxy token changed" "$([ -n "$rot_token" ] && [ "$rot_token" != "ORIGINALTOKEN" ] && echo changed)" "changed"
assert_eq "DEPLOYMENT_COMPLETED survives the rotate (#356)" "$(run_sourced "$V" env_get_file "$V/.env" DEPLOYMENT_COMPLETED)" "true"
# Consumers: the containers are RECREATED via compose up (env/args re-read), never `compose restart`
# (which would reuse p2pool's old --rpc-login args).
assert_contains "rotate recreates via compose up" "$(cat "$DOCKER_LOG")" "compose up"
assert_not_contains "rotate never uses compose restart" "$(cat "$DOCKER_LOG")" "compose restart"
# Secrets stay out of the command output — except the stratum password, deliberately surfaced via
# announce_stratum_auth so the operator can update each rig's 'pass'.
case "$out" in
*"$rot_pass"* | *"$rot_token"*) bad "rotate never prints the RPC password / proxy token" "leaked in: $out" ;;
*) ok "rotate never prints the RPC password / proxy token" ;;
esac
assert_contains "rotate surfaces the new stratum password for rigs" "$out" "Stratum authentication is ON"
assert_contains "rotate warns that rigs are rejected until updated" "$out" "rejected"
# Recoverability: the pre-rotation copies hold the OLD values, owner-only.
rot_cfg_bak="$(ls "$V"/config.json.bak-* 2>/dev/null | head -1)"
rot_env_bak="$(ls "$V"/.env.bak-* 2>/dev/null | head -1)"
assert_eq "config.json safety copy holds the old RPC password" "$(jq -r '.monero.node_password' "${rot_cfg_bak:-/dev/null}" 2>/dev/null)" "oldrpcpass"
assert_contains ".env safety copy holds the old proxy token" "$(cat "${rot_env_bak:-/dev/null}" 2>/dev/null)" "ORIGINALTOKEN"
rot_bak_mode="$(stat -c '%a' "$rot_env_bak" 2>/dev/null || stat -f '%Lp' "$rot_env_bak" 2>/dev/null)"
assert_eq "safety copies are owner-only (600)" "$rot_bak_mode" "600"
# Persistence: a follow-up apply reports no changes — the preservation logic now carries the NEW
# values instead of resurrecting the old ones. (This is exactly the assertion that fails if
# rotate silently no-ops: the preserved values would never have changed.)
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "apply after rotate reports no changes" "$out" "No configuration changes detected"
assert_eq "rotated token survives the next apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "$rot_token"

echo "== black-box: rotate-secrets skips what it must (#378) =="
# Remote mode: the RPC credential belongs to the remote node — config.json stays untouched.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"ru","node_password":"remotepass","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
assert_rc "rotate-secrets (remote) exits 0" "$?" "0"
assert_eq "remote RPC password untouched" "$(jq -r '.monero.node_password' "$V/config.json")" "remotepass"
assert_contains "remote skip is explained" "$out" "remote"
assert_eq "proxy token still rotates in remote mode" "$([ "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" != "ORIGINALTOKEN" ] && echo changed)" "changed"

# Literal stratum password: lives in config.json, so rotate leaves it and points there instead.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_password":"my.literal-pass"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
assert_eq "literal stratum password untouched" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "my.literal-pass"
assert_contains "literal skip points at config.json" "$out" "config.json"

# Declined prompt (no -y): nothing changes.
rot_token_now="$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" sh -c 'echo n | ./pithead rotate-secrets' 2>&1)"
assert_rc "declined rotate exits 0" "$?" "0"
assert_contains "declined rotate says cancelled" "$out" "cancelled"
assert_eq "declined rotate changes nothing" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "$rot_token_now"

echo "== black-box: rotate-secrets failure path keeps the old values recoverable (#378) =="
# A failed recreate must exit non-zero, leave the retry marker (#125) so `apply` re-attempts the
# recreate, and point at the safety copies that still hold the old secrets.
FDOCK="$SANDBOX/faildocker"
mkdir -p "$FDOCK"
cat >"$FDOCK/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose version"|"info") exit 0 ;;
  compose\ up*) echo "boom: no space left on device"; exit 1 ;;
esac
exit 0
EOF
chmod +x "$FDOCK/docker"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"failoldpass"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rm -f "$V"/config.json.bak-* "$V"/.env.bak-* "$V/.env.apply-incomplete"
out="$(cd "$V" && PATH="$FDOCK:$V/bin:$PATH" ./pithead rotate-secrets -y 2>&1)"
rc=$?
assert_rc "failed recreate exits non-zero" "$rc" "1"
assert_contains "failure names the retry path" "$out" "apply"
[ -f "$V/.env.apply-incomplete" ] && ok "failure leaves the retry marker (#125)" || bad "failure leaves the retry marker (#125)" "marker missing"
assert_eq "safety copy still holds the pre-rotation RPC password" "$(jq -r '.monero.node_password' "$(ls "$V"/config.json.bak-* | head -1)")" "failoldpass"
assert_contains "safety copy still holds the pre-rotation token" "$(cat "$(ls "$V"/.env.bak-* | head -1)")" "ORIGINALTOKEN"
rm -f "$V/.env.apply-incomplete" "$V"/config.json.bak-* "$V"/.env.bak-*

echo "== release: install bundle is free of macOS xattr pax headers (#252) =="
# Static guard: make_bundle must keep `--no-xattrs` AND the post-bundle xattr assertion, so the
# fix can't be silently reverted in a future edit.
REL="$ROOT/scripts/release.sh"
assert_contains "release.sh tars the bundle with --no-xattrs" \
    "$(grep -E '^[[:space:]]*tar .*--no-xattrs' "$REL" || true)" "--no-xattrs"
assert_contains "release.sh guards the bundle against xattr pax headers" \
    "$(cat "$REL")" "LIBARCHIVE.xattr"
# Functional: this platform's tar must actually honour --no-xattrs (the guard's whole premise).
# Tar a file that carries an xattr where we can set one (macOS: xattr -w / Linux: setfattr; a
# no-op elsewhere), and assert no LIBARCHIVE.xattr/SCHILY.xattr pax header survives — the exact
# check release.sh runs. Reproduces #252 on macOS; a clean no-op on GNU tar.
RELTMP="$(mktemp -d)"
mkdir -p "$RELTMP/pithead"
echo hi >"$RELTMP/pithead/f"
xattr -w com.test val "$RELTMP/pithead/f" 2>/dev/null ||
    setfattr -n user.test -v val "$RELTMP/pithead/f" 2>/dev/null || true
tar --no-xattrs -czf "$RELTMP/b.tar.gz" -C "$RELTMP" pithead 2>/dev/null
if gzip -dc "$RELTMP/b.tar.gz" 2>/dev/null | grep -qa -e 'LIBARCHIVE.xattr' -e 'SCHILY.xattr'; then
    bad "tar --no-xattrs yields an xattr-free bundle" "xattr pax headers present despite --no-xattrs"
else
    ok "tar --no-xattrs yields an xattr-free bundle"
fi
rm -rf "$RELTMP"

# xmrig-proxy wrapper entrypoint: optional stratum access-password (#152). The flag moved out of the
# compose command (a `${VAR:+--flag}` list element rendered a stray '' positional arg when the password
# was unset — xmrig-proxy warns `unsupported non-option argument ''`) into this wrapper, which appends
# it only when PROXY_STRATUM_PASSWORD is set. Exercise the real script with a stub xmrig-proxy on PATH
# that echoes its argv, so the set/unset branch is actually run.
XP_ENTRY="$ROOT/build/xmrig-proxy/entrypoint.sh"
xp_argv() { # <password value> -> the argv the wrapper would exec
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD="$1" sh "$XP_ENTRY" --http-no-restricted --donate-level=0
    rm -rf "$d"
}
assert_eq "xmrig-proxy entrypoint: unset password appends no flag (#152)" \
    "$(xp_argv '')" "[--http-no-restricted][--donate-level=0]"
assert_eq "xmrig-proxy entrypoint: set password appends --access-password (#152)" \
    "$(xp_argv 's3cret')" "[--http-no-restricted][--donate-level=0][--access-password=s3cret]"
# #261: the TLS cert flags append only when the toggle is on AND both keypair files exist at the
# mount (PROXY_TLS_MOUNT overrides the fixed /tls so the suite can use a temp dir).
xp_tls_argv() { # <PROXY_STRATUM_TLS value> <tls dir>
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD='' PROXY_STRATUM_TLS="$1" PROXY_TLS_MOUNT="$2" sh "$XP_ENTRY" -b 0.0.0.0:3333
    rm -rf "$d"
}
XPTLS="$(mktemp -d)"
printf 'cert' >"$XPTLS/cert.pem"
printf 'key' >"$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on + keypair appends the cert flags (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333][--tls-cert=$XPTLS/cert.pem][--tls-cert-key=$XPTLS/key.pem]"
assert_eq "xmrig-proxy entrypoint: TLS off appends nothing (#261)" \
    "$(xp_tls_argv false "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -f "$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on but keypair incomplete appends nothing (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -rf "$XPTLS"

# tor wrapper entrypoint: opt-in dashboard hidden service (#343). The HiddenService block is appended
# to the rendered torrc ONLY when DASHBOARD_ONION_ENABLED=true, targeting the bridge gateway
# (NETWORK_PREFIX.1) where Caddy binds the auth-gated onion vhost. pithead's caddy/client-auth side is
# covered above; this exercises the real container entrypoint's branch + the .1 substitution with a
# stub `tor` on PATH and the repo torrc.template (via the TORRC_TEMPLATE seam).
TOR_ENTRY="$ROOT/build/tor/entrypoint.sh"
tor_torrc() { # <DASHBOARD_ONION_ENABLED> [COMPOSE_PROFILES] -> the torrc the entrypoint would hand to `tor -f`
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\ncat /tmp/torrc\n' >"$d/tor" # stub tor: ignore -f, just print the rendered file
    chmod +x "$d/tor"
    PATH="$d:$PATH" DASHBOARD_ONION_ENABLED="$1" COMPOSE_PROFILES="${2-local_node,local_tari}" NETWORK_PREFIX=10.9.0 \
        TORRC_TEMPLATE="$ROOT/build/tor/torrc.template" sh "$TOR_ENTRY"
    rm -rf "$d"
}
tor_onion_on="$(tor_torrc true)"
assert_contains "tor entrypoint: dashboard HiddenService appended when enabled (#343)" \
    "$tor_onion_on" "HiddenServiceDir /var/lib/tor/dashboard/"
assert_contains "tor entrypoint: onion vhost targets the bridge gateway .1 (#343)" \
    "$tor_onion_on" "HiddenServicePort 80 10.9.0.1:80"
assert_contains "tor entrypoint: onion also exposes :443 for the Tor-Browser https upgrade (#343)" \
    "$tor_onion_on" "HiddenServicePort 443 10.9.0.1:443"
assert_not_contains "tor entrypoint: no dashboard onion when disabled (default off) (#343)" \
    "$(tor_torrc false)" "Dashboard Hidden Service"

# Node inbound onions (#103): each is published only while its node is local, so a remote node
# leaves no onion pointing at a container that never starts. The gate is the compose profile list,
# passed through from the rendered .env — same tokens that decide whether the node runs at all.
tor_both_local="$(tor_torrc false local_node,local_tari)"
assert_contains "tor entrypoint: Monero HS present when local_node is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/monero/"
assert_contains "tor entrypoint: Monero HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18080 10.9.0.26:18084"
assert_contains "tor entrypoint: Tari HS present when local_tari is active (#103)" \
    "$tor_both_local" "HiddenServiceDir /var/lib/tor/tari/"
assert_contains "tor entrypoint: Tari HS targets the node on the moved prefix (#103/#180)" \
    "$tor_both_local" "HiddenServicePort 18189 10.9.0.27:18189"
tor_remote_tari="$(tor_torrc false local_node)"
assert_contains "tor entrypoint: Monero HS still present with only local_node (#103)" \
    "$tor_remote_tari" "HiddenServiceDir /var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS when local_tari is omitted (remote tari, #103)" \
    "$tor_remote_tari" "/var/lib/tor/tari/"
tor_both_remote="$(tor_torrc false "")"
assert_not_contains "tor entrypoint: no Monero HS with no profiles (remote monero, #103)" \
    "$tor_both_remote" "/var/lib/tor/monero/"
assert_not_contains "tor entrypoint: no Tari HS with no profiles (remote tari, #103)" \
    "$tor_both_remote" "/var/lib/tor/tari/"
assert_contains "tor entrypoint: P2Pool HS is unconditional — p2pool always runs (#103)" \
    "$tor_both_remote" "HiddenServiceDir /var/lib/tor/p2pool/"
unset tor_both_local tor_remote_tari tor_both_remote

echo "== unit: onion provisioning follows node mode (#103) =="
# pithead's half of the same gate: a hidden service that is never published has no hostname to wait
# for, so provision_tor must not block on a remote node's onion (a 60s timeout, then a fatal error),
# and the address stays a placeholder. wait_for_onion is stubbed — the polling itself is the docker
# layer, and it runs in a command substitution, so the probe records asks in a file.
ONP="$SANDBOX/onion-prov"
mkdir -p "$ONP"
prov_probe() { # <MONERO_MODE> <TARI_MODE> -> "<onions asked for>|<MONERO_ONION>|<TARI_ONION>|<P2POOL_ONION>"
    (
        cd "$ONP" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        : >asked
        log() { :; }
        docker() { :; }
        resolve_pull_policy() { echo missing; }
        provision_onion_client_auth() { :; }
        provision_dashboard_onion() { :; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        MONERO_MODE="$1"
        TARI_MODE="$2"
        MONERO_ONION=placeholder
        TARI_ONION=placeholder
        P2POOL_ONION=placeholder
        provision_tor
        printf '%s|%s|%s|%s' "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$P2POOL_ONION"
    )
}
assert_eq "provision_tor waits for both node onions when both nodes are local (#103)" \
    "$(prov_probe local local)" "p2pool,monero,tari,|monero.onion|tari.onion|p2pool.onion"
assert_eq "provision_tor skips a remote node's onion and leaves it a placeholder (#103)" \
    "$(prov_probe remote remote)" "p2pool,|placeholder|placeholder|p2pool.onion"
assert_eq "provision_tor waits for the local node only in a mixed setup (#103)" \
    "$(prov_probe local remote)" "p2pool,monero,|monero.onion|placeholder|p2pool.onion"

# provision_node_onions: the remote → local switch. A stack first set up in remote mode has no
# address for that node, so apply/upgrade recreate tor against the committed profiles, capture the
# freshly minted hostname, and re-render .env BEFORE the node container starts against it. It must
# cost nothing (no docker, no render) once every local node's address is in hand.
node_onion_probe() { # <MONERO_MODE> <MONERO_ONION> <TARI_MODE> <TARI_ONION> -> "<docker calls>|<asked>|<MONERO_ONION>|<TARI_ONION>|<renders>"
    (
        cd "$ONP" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        : >asked
        : >dockerlog
        : >renders
        log() { :; }
        docker() { printf '%s ' "$*" >>dockerlog; }
        render_env() { printf 'x' >>renders; }
        wait_for_onion() {
            printf '%s,' "$1" >>asked
            echo "$1.onion"
        }
        # shellcheck disable=SC2034  # read by the sourced provision_node_onions, unseen here
        MONERO_MODE="$1"
        MONERO_ONION="$2"
        # shellcheck disable=SC2034  # read by the sourced provision_node_onions, unseen here
        TARI_MODE="$3"
        TARI_ONION="$4"
        provision_node_onions
        printf '%s|%s|%s|%s|%s' "$(cat dockerlog)" "$(cat asked)" "$MONERO_ONION" "$TARI_ONION" "$(cat renders)"
    )
}
assert_eq "provision_node_onions is a free no-op once every local node has its onion (#103)" \
    "$(node_onion_probe local mona.onion local taria.onion)" "||mona.onion|taria.onion|"
assert_eq "provision_node_onions ignores a remote node with no onion (#103)" \
    "$(node_onion_probe remote placeholder remote placeholder)" "||placeholder|placeholder|"
assert_eq "provision_node_onions mints + captures the onion of a node that just went local (#103)" \
    "$(node_onion_probe local placeholder remote placeholder)" "compose up -d tor |monero,|monero.onion|placeholder|x"
assert_eq "provision_node_onions treats an empty address as missing, and re-renders once (#103)" \
    "$(node_onion_probe local '' local '')" "compose up -d tor |monero,tari,|monero.onion|tari.onion|x"
unset ONP prov_probe node_onion_probe

echo "== black-box: doctor's onion report follows node mode (#103) =="
# A node running elsewhere has no hidden service to provision, so its placeholder address is the
# correct state — doctor must not send the operator back to `setup` over it. A LOCAL node with no
# address is still a real problem and must keep warning.
DOC="$SANDBOX/doctor-onion"
mkdir -p "$DOC/build/tari" "$DOC/build/dashboard"
: >"$DOC/build/dashboard/Dockerfile"
cp "$STACK" "$DOC/pithead"
cp "$ROOT/build/tari/config.toml.template" "$DOC/build/tari/"
make_stubs "$DOC/bin"
printf '{"monero":{"mode":"remote","wallet_address":"%s","remote":{"host":"10.0.0.8"}},"tari":{"mode":"remote","wallet_address":"T","remote":{"host":"10.0.0.9"}}}\n' "$WALLET" >"$DOC/config.json"
doctor_onions() { # <COMPOSE_PROFILES> -> doctor's "Tor onion addresses" section
    {
        printf 'MONERO_ONION_ADDRESS=placeholder\nTARI_ONION_ADDRESS=placeholder\nP2POOL_ONION_ADDRESS=p2pa.onion\n'
        printf 'TARI_GRPC_ADDRESS=10.0.0.9:18142\nDEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n'
        printf 'COMPOSE_PROFILES=%s\n' "$1"
    } >"$DOC/.env"
    (cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1 | sed -n '/Tor onion addresses/,/^$/p')
}
doc_remote="$(doctor_onions "")"
assert_contains "doctor: a remote Monero node's missing onion is expected, not a warning (#103)" \
    "$doc_remote" "MONERO_ONION_ADDRESS not needed"
assert_contains "doctor: a remote Tari node's missing onion is expected, not a warning (#103)" \
    "$doc_remote" "TARI_ONION_ADDRESS not needed"
assert_contains "doctor: P2Pool's onion is still reported either way (#103)" \
    "$doc_remote" "P2POOL_ONION_ADDRESS set"
doc_local="$(doctor_onions "local_node,local_tari")"
assert_contains "doctor: a LOCAL Monero node with no onion still warns (#103)" \
    "$doc_local" "MONERO_ONION_ADDRESS is not provisioned"
assert_contains "doctor: a LOCAL Tari node with no onion still warns (#103)" \
    "$doc_local" "TARI_ONION_ADDRESS is not provisioned"
unset DOC doc_remote doc_local doctor_onions

# ---------------------------------------------------------------------------
echo "== black-box: dashboard control channel (#33) =="
# A deployed sandbox with the control channel on: config carries a dashboard password (required)
# and dashboard.control.enabled, docker/sudo stubbed. The runner is exercised end-to-end against
# real spool files; `apply` inside it runs this same sandboxed pithead.
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
              "tari":{"wallet_address":"T"}, "p2pool":{"pool":"%s"},
              "dashboard":{"secure":true,"host":"box.lan",
                           "auth":{"username":"admin","password":"a control passphrase"},
                           "control":{"enabled":true}} }\n' "$WALLET" "$1" >"$C/config.json"
}

# Fail-closed: enabling the control channel without a dashboard password must not validate.
seed_control_env
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan","control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "control.enabled without a password is rejected" "$rc" "1"
assert_contains "control-without-password message names the flag" "$out" "dashboard.control.enabled"

# Baseline: control enabled + password, pool main → a rendered .env with the control keys.
seed_control_env
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "baseline apply with control enabled succeeds" "$?" "0"
assert_contains "control toggle rendered to .env" "$(cat "$C/.env")" "DASHBOARD_CONTROL_ENABLED=true"
assert_contains "control spool dir rendered to .env" "$(cat "$C/.env")" "CONTROL_DIR=$C/data/control"
[ -d "$C/data/control/requests" ] && [ -d "$C/data/control/staged" ] &&
    [ -d "$C/data/control/results" ] && [ -d "$C/data/control/audit" ] &&
    ok "control spool dirs created" || bad "control spool dirs created" "missing under $C/data/control"
assert_contains "caddy access-log dir rendered to .env (#349)" "$(cat "$C/.env")" "CADDY_LOG_DIR=$C/data/caddy-logs"
[ -d "$C/data/caddy-logs" ] && ok "caddy access-log dir created (#349)" || bad "caddy access-log dir created (#349)" "missing"

echo "== black-box: apply --dry-run [--porcelain] (#33) =="
control_config mini # candidate change: pool main -> mini
cp "$C/.env" "$C/env.before"
: >"$CTRL_LOG"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run --porcelain exits 0" "$?" "0"
assert_contains "porcelain emits FLAG<TAB>KEY<TAB>MSG rows" "$out" "$(printf 'INFO\tP2POOL_FLAGS\t')"
assert_contains "porcelain row carries the describe_change message" "$out" "P2Pool sidechain changing"
if cmp -s "$C/.env" "$C/env.before"; then ok "dry-run leaves .env untouched"; else bad "dry-run leaves .env untouched" ".env changed"; fi
case "$(grep 'compose up' "$CTRL_LOG" 2>/dev/null || true)" in
"") ok "dry-run touches no container" ;;
*) bad "dry-run touches no container" "docker compose up was called" ;;
esac
[ ! -f "$C/.env.dryrun" ] && ok "dry-run staging file removed" || bad "dry-run staging file removed" ".env.dryrun left behind"
# Human (non-porcelain) preview prints the bullet form of the same row.
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>/dev/null)"
assert_contains "human dry-run prints the preview bullet" "$out" "• P2Pool sidechain changing"
# --porcelain without --dry-run is refused (it would silently look like a real apply).
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --porcelain 2>&1)"
assert_rc "--porcelain without --dry-run is rejected" "$?" "1"

# PITHEAD_CONFIG_FILE points ONE invocation at a candidate config; config.json is not consulted.
control_config main # config.json back to the applied state (no changes)
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"T"}, "p2pool":{"pool":"nano"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/alt.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" PITHEAD_CONFIG_FILE="$C/alt.json" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_contains "PITHEAD_CONFIG_FILE override is honoured" "$out" "37890" # nano's p2p port
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_eq "without the override, config.json shows no changes" "$out" ""

echo "== black-box: symlink-invoked stack renders physical paths (#695) =="
# A stack managed through a deploy symlink (`current -> pithead-vX.Y.Z`) must render the same
# .env as one managed from the physical dir: SCRIPT_DIR resolves with pwd -P, so an unedited
# preview through the symlink shows zero changes and an apply never rewrites the $PWD-derived
# paths (CLEARNET_STATE_DIR & co.) to the symlink spelling.
ln -sfn "$C" "$SANDBOX/current-link"
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run through the symlink exits 0" "$?" "0"
assert_eq "unedited preview through the symlink shows zero changes (#695)" "$out" ""
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply through the symlink succeeds" "$?" "0"
assert_contains "clearnet state dir keeps the physical path" "$(cat "$C/.env")" "CLEARNET_STATE_DIR=$C/data/clearnet-state"
assert_not_contains "the symlink spelling never reaches .env" "$(cat "$C/.env")" "current-link"
rm -f "$SANDBOX/current-link"

echo "== black-box: apply --dry-run is read-only re: node credential generation (#556) =="
# Direct CLI leg: a fresh/hand-edited local-node config with placeholder/empty creds must not have
# config.json rewritten by a --dry-run preview — the read-only contract #556 reported broken
# (persist_node_credentials was writing the freshly-generated creds back to disk).
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"","node_password":""},
          "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
cp "$C/config.json" "$C/config.json.556before"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>&1)"
assert_rc "dry-run with placeholder node creds still validates" "$?" "0"
if cmp -s "$C/config.json" "$C/config.json.556before"; then
    ok "dry-run leaves config.json byte-identical with placeholder node creds (#556)"
else
    bad "dry-run leaves config.json byte-identical with placeholder node creds (#556)" "config.json was rewritten"
fi
assert_contains "dry-run still previews the credential it would generate (in-memory only)" "$out" "Monero node RPC credential"
rm -f "$C/config.json.556before"

# Control-channel leg: the same blank-creds config staged through the control path must not have
# its ON-DISK STAGED COPY rewritten by the dry-run re-validation either (#556) — the same write,
# one level removed, that used to leave a generated secret sitting in data/control/staged/ and
# could dirty the diff a later commit gate re-derives from that file.
UUID0="00000000-0000-4000-8000-000000000000"
REQS0="$C/data/control/requests"
STAGED0="$C/data/control/staged"
RESULTS0="$C/data/control/results"
jq -n --arg w "$WALLET" --arg id "$UUID0" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"",node_password:""},
    tari:{wallet_address:"T"}, p2pool:{pool:"main"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS0/$UUID0.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "blank-creds preview status" "$(jq -r '.status' "$RESULTS0/$UUID0.json" 2>/dev/null)" "previewed"
assert_eq "staged copy keeps the blank node_username — not persisted (#556)" "$(jq -r '.monero.node_username' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
assert_eq "staged copy keeps the blank node_password — not persisted (#556)" "$(jq -r '.monero.node_password' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
# Clean up: the result/staged counters the tests below assume start from a clean spool.
rm -f "$RESULTS0/$UUID0.json" "$STAGED0/$UUID0.json"
control_config main # restore config.json to the state control-run-pending below expects

echo "== black-box: control-run-pending (#33) =="
UUID1="11111111-1111-4111-8111-111111111111"
UUID2="22222222-2222-4222-8222-222222222222"
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"
STAGED="$C/data/control/staged"
AUDIT="$C/data/control/audit/control.log"
run_pending() { (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending 2>&1); }

# Preview: a valid typed intent (pool main -> mini) → previewed result + a host-side staged copy.
jq -n --arg w "$WALLET" --arg id "$UUID1" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID1.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a valid preview" "$?" "0"
[ ! -f "$REQS/$UUID1.json" ] && ok "request claimed out of requests/" || bad "request claimed out of requests/" "still present"
assert_eq "preview result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "previewed"
assert_contains "preview result carries the change row" "$(jq -r '.changes[].msg' "$RESULTS/$UUID1.json" 2>/dev/null)" "P2Pool sidechain changing"
assert_eq "pool switch alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID1.json" 2>/dev/null)" "false"
[ -f "$STAGED/$UUID1.json" ] && ok "candidate staged host-side" || bad "candidate staged host-side" "missing"
# The staged copy carries merged secrets — it must land owner-only (#33 re-review).
assert_eq "staged candidate is mode 600" "$(file_mode "$STAGED/$UUID1.json")" "600"
assert_contains "preview audited" "$(cat "$AUDIT" 2>/dev/null)" "\"action\":\"preview\",\"status\":\"previewed\""

# Malformed id: it would become a filename, so the request is discarded with no result at all.
printf '{"id":"../../etc/passwd","action":"preview","actor":"x","config":{}}\n' >"$REQS/evil.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a malformed id" "$?" "0"
assert_contains "malformed id is called out" "$out" "malformed id"
assert_eq "no result file for a malformed id" "$(ls "$RESULTS" | wc -l | tr -d ' ')" "1"

# Well-formed but non-v4 id (version nibble 1): the loose old regex accepted any hex uuid shape;
# the tightened gate (#438) pins version 4 + RFC variant, so this must be discarded too.
printf '{"id":"11111111-1111-1111-1111-111111111111","action":"preview","actor":"x","config":{}}\n' >"$REQS/nonv4.json"
out="$(run_pending)"
assert_contains "non-v4 uuid id is discarded" "$out" "malformed id"
[ ! -f "$RESULTS/11111111-1111-1111-1111-111111111111.json" ] &&
    ok "no result file for a non-v4 id" || bad "no result file for a non-v4 id" "result written"

# Unknown action / extra keys / invalid candidate config → rejected results, nothing staged.
printf '{"id":"%s","action":"exec","actor":"x"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "unknown action is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
# A malicious action string on the unknown-action path cannot forge a second line into the
# tamper-evidence audit log: the field is charset-stripped at the write chokepoint. Feed an action
# carrying a newline + a fake JSON entry, then assert every audit line is still valid JSON and no
# forged status leaked in (#349 review).
audit_before=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
# jq decodes the \n and quotes into REAL characters in the action value, so the host-side
# jq -r '.action' hands control_audit a string with an embedded newline + fake JSON object —
# the exact shape that would append a forged line without the charset strip.
jq -nc --arg id "$UUID2" '{id:$id,actor:"x",action:"evil\n{\"ts\":\"0\",\"forged\":\"yes\"}"}' >"$REQS/$UUID2.json"
run_pending >/dev/null
audit_after=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
assert_eq "forged-action intent adds exactly one audit line" "$((audit_after - audit_before))" "1"
while IFS= read -r line; do printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad "every audit line is valid JSON" "unparseable: $line"; done <"$AUDIT"
ok "every audit line is valid JSON after a forged-action intent"
assert_not_contains "no forged audit entry leaked in" "$(cat "$AUDIT")" '"forged":"yes"'
printf '{"id":"%s","action":"preview","actor":"x","config":{},"cmd":"rm -rf /"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "extra request keys are rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "unexpected keys"
jq -n --arg w "$WALLET" --arg id "$UUID2" '{id:$id, action:"preview", actor:"x", config:{
    monero:{mode:"local",wallet_address:$w}, tari:{wallet_address:"T"}, p2pool:{pool:"banana"},
    dashboard:{auth:{password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "invalid candidate config is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
assert_contains "rejection carries pithead's validation error" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "p2pool.pool"
[ ! -f "$STAGED/$UUID2.json" ] && ok "rejected candidate is not left staged" || bad "rejected candidate is not left staged" "staged file present"

# Commit without a staged intent → rejected (preview first).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "commit without a staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "preview first"

# Commit of the previewed intent: backup written, apply -y ran, audit line, result applied.
: >"$CTRL_LOG"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID1" >"$REQS/$UUID1.json"
run_pending >/dev/null
assert_eq "commit result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "applied"
assert_eq "committed config landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"
[ -f "$C/config.json.bak-control" ] &&
    assert_eq "pre-change backup kept" "$(jq -r '.p2pool.pool' "$C/config.json.bak-control")" "main" ||
    bad "pre-change backup kept" "config.json.bak-control missing"
assert_contains "commit ran the real apply (containers recreated)" "$(cat "$CTRL_LOG")" "compose up"
assert_contains "commit audited with the actor" "$(cat "$AUDIT")" "\"actor\":\"admin\",\"action\":\"commit\",\"status\":\"applied\""
[ ! -f "$STAGED/$UUID1.json" ] && ok "staged intent consumed on commit" || bad "staged intent consumed on commit" "still staged"

# Operator keeps ownership of the stack files the root runner's apply wrote (#33 v1.4): control_run_pending
# is root, so its apply would render .env root:root 0600 — unreadable to the non-root operator. The
# re-own derives the owner from config.json (operator-owned, container can't write it) so a commit
# matches a normal apply. Assert every operator-facing file is owned by config.json's owner, so a
# non-root operator can still read .env / re-render on the next apply.
cfg_uid="$(file_uid "$C/config.json")"
for reowned in ".env" "Caddyfile" "config.json.bak-control"; do
    [ -e "$C/$reowned" ] &&
        assert_eq "$reowned owned by the config.json owner after a control commit" "$(file_uid "$C/$reowned")" "$cfg_uid" ||
        bad "$reowned present after a control commit" "missing"
done

echo "== black-box: audit log records names, never values (#349) =="
# WHAT changed rides in the audit entry as env-key NAMES (main -> mini touches the p2pool keys);
# no config or secret VALUE may ever land in the log — it is mounted into the dashboard container.
assert_contains "commit audit records the changed key names" "$(cat "$AUDIT")" '"keys":"P2POOL'
assert_contains "preview audit records the changed key names" "$(grep '"status":"previewed"' "$AUDIT" | tail -n 1)" '"keys":"P2POOL'
case "$(cat "$AUDIT")" in
*"a control passphrase"* | *"$WALLET"* | *mini*) bad "audit log holds no config or secret values" "a value leaked into audit/control.log" ;;
*) ok "audit log holds no config or secret values" ;;
esac

# Expired staged intent (older than the 10-min commit window) → rejected as expired and cleared.
# Age it ~15 min: past the 10-min expiry the commit enforces, but INSIDE the 60-min stale sweep so
# the sweep leaves it for control_commit to judge (a 2020 date would be swept first, #33 hardening).
jq -n --arg id "$UUID2" '{}' >"$STAGED/$UUID2.json"
touch -t "$(date -d '15 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-15M +%Y%m%d%H%M)" "$STAGED/$UUID2.json"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "expired staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "expired"
[ ! -f "$STAGED/$UUID2.json" ] && ok "expired staged intent cleared" || bad "expired staged intent cleared" "still staged"

echo "== black-box: pre-masked prefill copy + host-side secret merge (#440) =="
# The dashboard container never mounts the raw config.json: apply/run-pending render a PRE-MASKED
# copy into the spool's masked/ leg, and the "blank secret keeps the live value" sentinel swap
# happens host-side at staging. Current state: pool mini committed above, node_password "p",
# dashboard password "a control passphrase".
MASKED="$C/data/control/masked/config.json"
[ -f "$MASKED" ] && ok "masked prefill copy rendered by apply" || bad "masked prefill copy rendered by apply" "$MASKED missing"
assert_eq "masked copy is world-readable for the container (644)" "$(file_mode "$MASKED")" "644"
assert_eq "set secret masked to the sentinel" "$(jq -c '.monero.node_password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "dashboard password masked to the sentinel" "$(jq -c '.dashboard.auth.password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "non-secret keys survive the masking" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "mini"
case "$(cat "$MASKED")" in
*"a control passphrase"* | *'"p"'*) bad "masked copy holds no secret values" "a secret leaked into $MASKED" ;;
*) ok "masked copy holds no secret values" ;;
esac

# Staleness: a hand-edit to config.json (new BOTSECRET token) is re-masked by the next runner
# pass — run-pending freshens the copy even with an empty request spool.
jq '.telegram = {"bot_token":"BOTSECRET","chat_id":"-100123"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_pending >/dev/null
assert_eq "run-pending re-renders the masked copy" "$(jq -c '.telegram.bot_token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
case "$(cat "$MASKED")" in
*BOTSECRET*) bad "hand-edited secret never reaches the masked copy" "BOTSECRET leaked into $MASKED" ;;
*) ok "hand-edited secret never reaches the masked copy" ;;
esac

# Sync .env with the hand-edited config so the sentinel commit below only changes allowlisted
# P2POOL keys (TELEGRAM_BOT_TOKEN is deliberately NOT dashboard-committable).
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

# Host-side sentinel swap: a proposal carrying {"__secret__":true} for untouched secrets (what the
# dashboard now submits) stages with the LIVE values merged back in, and a sentinel for an UNSET
# secret collapses to "" instead of leaking a dict into config.json.
UUID5="55555555-5555-4555-8555-555555555555"
jq -n --arg w "$WALLET" --arg id "$UUID5" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:{"__secret__":true}},
    tari:{wallet_address:"T"}, p2pool:{pool:"main"}, workers:{api_token:{"__secret__":true}},
    telegram:{bot_token:{"__secret__":true},chat_id:"-100123"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:{"__secret__":true}},control:{enabled:true}}}}' >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel-carrying preview validates" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_eq "sentinel swapped for the live node password at staging" "$(jq -r '.monero.node_password' "$STAGED/$UUID5.json" 2>/dev/null)" "p"
assert_eq "sentinel swapped for the live dashboard password" "$(jq -r '.dashboard.auth.password' "$STAGED/$UUID5.json" 2>/dev/null)" "a control passphrase"
assert_eq "sentinel swapped for the live telegram token" "$(jq -r '.telegram.bot_token' "$STAGED/$UUID5.json" 2>/dev/null)" "BOTSECRET"
assert_eq "sentinel for an unset secret collapses to empty" "$(jq -r '.workers.api_token' "$STAGED/$UUID5.json" 2>/dev/null)" ""
# The container-visible legs of this round trip stay secret-free (the request carried sentinels,
# the merged copy lives only in host-only staged/).
case "$(cat "$RESULTS/$UUID5.json")$(cat "$AUDIT")" in
*BOTSECRET* | *"a control passphrase"*) bad "results/audit stay secret-free on a sentinel preview" "a live secret leaked" ;;
*) ok "results/audit stay secret-free on a sentinel preview" ;;
esac

# Commit the sentinel intent: the committed config.json carries the LIVE secrets ("blank keeps"),
# and the masked prefill copy is re-rendered to match the new state.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live node password" "$(jq -r '.monero.node_password' "$C/config.json")" "p"
assert_eq "committed config keeps the live telegram token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "BOTSECRET"
assert_eq "committed config never carries a sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
assert_eq "masked copy re-rendered after the commit" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "main"
case "$(cat "$MASKED")" in
*BOTSECRET* | *"a control passphrase"*) bad "re-rendered masked copy still holds no secrets" "a secret leaked into $MASKED" ;;
*) ok "re-rendered masked copy still holds no secrets" ;;
esac

echo "== black-box: .env line-injection guard (#33 hardening, per field) =="
# A newline in any config string that renders into .env unquoted would inject a SECOND KEY=value
# line — e.g. PITHEAD_REGISTRY=evil.tld — which the root apply then trusts for every image: pull
# (RCE). parse_and_validate_config (the chokepoint both preview dry-run and real commit run) must
# reject a control character in EVERY string leaf. Build a full valid config, then poison one field.
inject_reject() { # <label> <jq-setter expr using $v>
    jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"T"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}
         | '"$2" >"$C/config.json"
    out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
    rc=$?
    assert_rc "$1 with a newline is rejected by parse_and_validate_config" "$rc" "1"
    assert_contains "$1 rejection names the control-char guard" "$out" "control character"
}
inject_reject "node_password" '.monero.node_password=$v'
inject_reject "node_username" '.monero.node_username=$v'
inject_reject "bot_token" '(.telegram={bot_token:$v})'
inject_reject "api_token" '(.workers={api_token:$v})'
inject_reject "ping_url" '(.healthchecks={ping_url:$v})'
inject_reject "chat_id" '(.telegram={chat_id:$v})'
# Positive: legitimate tokens (no control chars) still validate.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"T"}, p2pool:{pool:"main"},
      telegram:{bot_token:"123456:legit-ABC_def"}, workers:{api_token:"tok_legit123"},
      healthchecks:{ping_url:"https://hc-ping.com/abc-123"},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "legitimate secrets still validate" "$?" "0"
# No second line reaches .env: a poisoned config rejected at `apply -y` never renders the attacker key.
jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"T"}, p2pool:{pool:"main"}, telegram:{bot_token:$v},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
if grep -q 'PITHEAD_REGISTRY' "$C/.env"; then bad "no injected line in .env" "PITHEAD_REGISTRY landed in .env"; else ok "rejected config injects no second .env line"; fi

echo "== black-box: control channel on a published onion requires client-auth (#33 hardening) =="
# A root-capable, funds-redirecting mutation channel must not sit behind only a brute-forceable
# password on an anonymously-reachable onion. control+onion+client_auth=false → refused.
onion_control_config() { # <onion-enabled> <client-auth> -> writes config.json
    jq -n --arg w "$WALLET" --argjson onion "$1" --argjson ca "$2" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"T"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a strong control passphrase"},
                     onion:{enabled:$onion,client_auth:$ca}, control:{enabled:true}}}' >"$C/config.json"
}
onion_control_config true false
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion without client_auth is refused" "$?" "1"
assert_contains "refusal names client_auth" "$out" "client_auth"
onion_control_config true true
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion WITH client_auth validates" "$?" "0"
assert_not_contains "allowed combo raises no client_auth error" "$out" "client_auth"
# control without an onion (LAN) stays allowed — client-auth only gates the published onion.
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control without an onion is allowed" "$?" "0"

echo "== black-box: telegram.control fails closed on each leg (#521) =="
# telegram.control (the #338 remote /restart /apply surface) is a remotely-reachable host-control
# channel, so it refuses to enable unless the whole chain is present: dashboard.control on (the #33
# spool it rides), telegram.commands on (the bot that answers it), and at least one allow-listed
# operator id (or every command is refused and the feature is inert). Each leg must fail closed.
tg_control_config() { # <dashboard.control.enabled> <telegram.commands.enabled> <allowed_ids-json>
    jq -n --arg w "$WALLET" --argjson ctl "$1" --argjson cmds "$2" --argjson ids "$3" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"T"}, p2pool:{pool:"main"},
          telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111",
                    commands:{enabled:$cmds}, control:{enabled:true,allowed_ids:$ids}},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
                     control:{enabled:$ctl}}}' >"$C/config.json"
}
# Leg 1: dashboard.control off — the spool the commands ride does not exist.
tg_control_config false true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without dashboard.control is refused" "$?" "1"
assert_contains "refusal names dashboard.control.enabled" "$out" "dashboard.control.enabled is false"
# Leg 2: telegram.commands off — no bot is polling for the commands.
tg_control_config true false '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without telegram.commands is refused" "$?" "1"
assert_contains "refusal names telegram.commands.enabled" "$out" "telegram.commands.enabled is false"
# Leg 3: allowed_ids empty — no operator could ever confirm, the feature is inert.
tg_control_config true true '[]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control with an empty allowed_ids is refused" "$?" "1"
assert_contains "refusal names allowed_ids" "$out" "telegram.control.allowed_ids is empty"
# All three legs present — validates.
tg_control_config true true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "fully-configured telegram.control validates" "$?" "0"
assert_not_contains "fully-configured control raises no telegram.control error" "$out" "telegram.control.enabled is true but"
# Restore the section baseline (control on, no telegram) for the tests that follow.
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

echo "== black-box: confirm-gate — an in-scope disruptive change needs a typed APPLY (#719) =="
UUID3="33333333-3333-4333-8333-333333333333"
# Clean baseline: pool mini, clearnet off, applied.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# Candidate turns on Monero clearnet initial sync — describe_change flags this CONFIRM (#719): an
# in-scope disruptive change (host IP exposed during IBD), confirm-gated rather than host-only DEST.
preview_clearnet() {
    jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",clearnet_initial_sync:true},
        tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
    run_pending >/dev/null
}
preview_clearnet
assert_eq "confirm-gated candidate previews destructive:true" "$(jq -r '.destructive' "$RESULTS/$UUID3.json" 2>/dev/null)" "true"
assert_contains "confirm-gated preview carries a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID3.json" 2>/dev/null)" "CONFIRM"
# Commit WITHOUT the typed confirmation is refused — and points at the confirm step, NOT a flat
# host-only #338 refusal. The in-scope change is NOT hard-refused; it just needs the acknowledgement.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit without a token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "refusal asks for the typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "type APPLY"
assert_eq "unconfirmed commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# A WRONG token is refused too — only the exact literal proceeds.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"apply"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with the wrong token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_eq "wrong-token commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# Commit WITH the exact typed APPLY proceeds and lands the change.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "confirmed change landed in config.json" "$(jq -r '.monero.clearnet_initial_sync' "$C/config.json")" "true"
# The audit log records it AS a dashboard-confirmed destructive change (#719): the distinct
# commit-confirmed action, carrying the changed key NAME (never a value).
assert_contains "confirmed commit audits as commit-confirmed with the key name" \
    "$(grep '"action":"commit-confirmed","status":"applied"' "$AUDIT" | tail -n 1)" "MONERO_CLEARNET_SYNC"

echo "== black-box: the typed APPLY does NOT unlock the perimeter — DEST stays host-only (#719) =="
# Type-to-confirm is UX friction, not a security control: it must never carry a PERIMETER change.
# (a) A perimeter key that never touches an allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND,
# DEST) is refused even WITH the token, on the security-sensitive gate.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "perimeter RPC-LAN change is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "perimeter refusal is the security-sensitive gate, not the confirm step" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "security-sensitive"
assert_eq "perimeter change did not touch config.json" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
# (b) A confirm-KEY in its HEAVY direction (monero.prune DISABLE → full re-sync) still emits DEST
# and is refused even WITH the token — the confirm allowlist is not a blanket unlock for the key.
jq -n --arg w "$WALLET" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:true},
    tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "prune DISABLE is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
# #713 removed the stale #338 reference from the destructive refusal; it now names the host path.
assert_contains "prune-disable refusal names the host apply path, not stale #338 (#713)" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "Edit config.json on the host"
assert_eq "prune stays enabled after the refusal" "$(jq -r '.monero.prune' "$C/config.json")" "true"
[ ! -f "$STAGED/$UUID3.json" ] && ok "refused destructive intent cleared from staged" || bad "refused destructive intent cleared from staged" "still staged"

echo "== black-box: a dashboard-confirmed data-dir move is allowlisted to the stack data root (#728) =="
# #719 made the four *_DATA_DIR moves confirm-gated. assert_safe_dir is a BLOCKLIST, so a
# confirmed move could target any non-blocklisted absolute path (another user's home, another
# service's volume). control_approval_gate now narrows the DESTINATION to an allowlist for
# control-channel moves: only under the stack data root ($C/data) or a parent it already uses.
# The host `apply` path keeps the blocklist — a shell operator is already trusted.
UUID7="77777777-7777-4777-8777-777777777777"
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
EVIL_DIR="$SANDBOX/other-service-vol/monero" # absolute, NOT blocklisted, NOT under $C/data
preview_move() {                             # <monero.data_dir>
    jq -n --arg w "$WALLET" --arg id "$UUID7" --arg dd "$1" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
        tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID7.json"
    run_pending >/dev/null
}
# (1) A move UNDER the stack data root, confirmed with APPLY, is allowed and lands.
preview_move "$C/data/monero-v2"
assert_contains "in-root data-dir move previews a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID7.json" 2>/dev/null)" "CONFIRM"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "in-root data-dir move with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "applied"
assert_eq "in-root move landed in .env" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$C/data/monero-v2"
# (2) A move to an arbitrary non-blocklisted, non-allowed path is refused EVEN with APPLY.
preview_move "$EVIL_DIR"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "out-of-root data-dir move is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
assert_contains "refusal names the data-root allowlist" "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "outside the stack data root"
# The refusal left config.json untouched — it still carries the previously-committed in-root value
# (test 1), never the refused out-of-root path.
assert_eq "refused move did not touch config.json" "$(jq -r '.monero.data_dir // empty' "$C/config.json")" "$C/data/monero-v2"
[ ! -f "$STAGED/$UUID7.json" ] && ok "refused out-of-root move cleared from staged" || bad "refused out-of-root move cleared from staged" "still staged"
# (3) The SAME path from the HOST shell still applies — the tighter rule is control-only.
jq -n --arg w "$WALLET" --arg dd "$EVIL_DIR" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
    tari:{wallet_address:"T"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_rc "host-shell apply to the same out-of-root path succeeds" "$?" "0"
assert_eq "host-shell apply rendered the out-of-root path (blocklist, not allowlist)" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$EVIL_DIR"

echo "== black-box: a NON-destructive commit still proceeds with no token (#33) =="
# Restore a clean baseline (prune off, clearnet off) then a pool switch mini -> nano is INFO, not
# DEST/CONFIRM — it commits with no confirmation at all.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"T"}, p2pool:{pool:"nano"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "non-destructive commit still applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "non-destructive change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "nano"

echo "== black-box: approval gate default-denies security-control changes (#33 re-review) =="
# describe_change flags only the ENABLE/CHANGE direction of security controls as DEST — disabling
# dashboard auth, downgrading onion client-auth, clearing the stratum password or repointing the
# Telegram bot are all INFO rows. The gate must refuse those on the explicit sensitive-key set,
# independent of the DEST flag; a non-security change must still pass.
UUID5="55555555-5555-4555-8555-555555555555"
# Baseline: nano pool + stratum password + telegram bot + control, applied from the host CLI.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"T"}, p2pool:{pool:"nano",stratum_password:"s3cretpw"},
    telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
               control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
gate_try() { # <candidate-json-file> [confirm-token] — preview then commit via the spool; result lands in $RESULTS/$UUID5.json
    # An optional second arg carries a typed confirmation ("APPLY") on the commit, so a PERIMETER case
    # can prove the change stays refused EVEN WITH a valid token present. Omitted → token-less commit.
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
    if [ -n "${2:-}" ]; then
        printf '{"id":"%s","action":"commit","actor":"admin","confirm":"%s"}\n' "$UUID5" "$2" >"$REQS/$UUID5.json"
    else
        printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
    fi
    run_pending >/dev/null
}

# Disable the dashboard login (auth.password:"" needs control:false to pass validation): the
# preview flags destructive:false — proof the DEST path alone would wave it through — and the
# commit must still be refused, config untouched.
jq '.dashboard.auth={username:"admin"} | .dashboard.control={enabled:false}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "auth-disable previews destructive:false (DEST alone would allow it)" \
    "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "dashboard-login disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "auth-disable refusal names the sensitive-key gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the dashboard password" "$(jq -r '.dashboard.auth.password' "$C/config.json")" "a control passphrase"
assert_eq "config.json keeps control enabled" "$(jq -r '.dashboard.control.enabled' "$C/config.json")" "true"

# Clear the stratum access password (disable direction is an INFO row) — refused.
jq 'del(.p2pool.stratum_password)' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "stratum-password disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the stratum password" "$(jq -r '.p2pool.stratum_password' "$C/config.json")" "s3cretpw"

# Repoint the Telegram bot (token change is an INFO row; the bot is the future #338 approval
# channel, so an attacker must not swap it) — refused.
jq '.telegram.bot_token="654321:evil-XYZ_abc"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "telegram bot_token repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the original bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Downgrade the onion to password-only (client_auth:false is an INFO row in every direction).
# Baseline first: onion on + client_auth on (the only combo valid with control on), applied.
jq '.dashboard.onion={enabled:true,client_auth:true}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_contains "onion baseline applied (client_auth on)" "$(cat "$C/.env")" "DASHBOARD_ONION_CLIENT_AUTH=true"
jq '.dashboard.onion.client_auth=false | .dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "onion client-auth downgrade commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps onion client-auth on" "$(jq -r '.dashboard.onion.client_auth' "$C/config.json")" "true"

# TRUE default-deny (#33 re-review round 2): the gate is an ALLOWLIST of editable keys, not a
# blocklist of sensitive ones, so a key nobody thought to enumerate still refuses. Each candidate
# below was committable under the blocklist gate — these assertions are the teeth.
# p2pool clearnet flip: dials sidechain peers over clearnet, deanonymizing the host IP, no
# auto-revert.
jq '.p2pool.clearnet=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "p2pool clearnet flip commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps p2pool on Tor" "$(jq -r '.p2pool.clearnet // false' "$C/config.json")" "false"
# XvB stats over clearnet: correlates the host IP with the payout wallet.
jq '.xvb.tor=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb tor-disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps xvb on Tor" "$(jq -r '.xvb.tor // true' "$C/config.json")" "true"
# Healthchecks ping-URL repoint: exfiltrates liveness / silences the dead-man's switch.
jq '.healthchecks={ping_url:"https://attacker.example/ping"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "healthchecks ping-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps healthchecks unset" "$(jq -r '.healthchecks.ping_url // "unset"' "$C/config.json")" "unset"
# The #719 perimeter, named explicitly: disabling the Tor egress firewall would let containers dial
# clearnet — it is NOT in the confirm-gated set and stays host-only. Commit WITH a valid APPLY token
# to prove the typed confirmation does not unlock the perimeter — the refusal fires before the token
# is ever examined, so it stays refused just as it does token-less (#719).
jq '.network={tor_egress_firewall:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "tor-egress-firewall disable commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tor-egress refusal is a host-only gate (the APPLY token did not unlock it)" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the tor egress firewall unset (defaults on)" "$(jq -r '.network.tor_egress_firewall // "unset"' "$C/config.json")" "unset"
# Setting a Monero view key (the #381 payout-confirm secret) reveals every incoming amount — a
# secret, host-only, never confirm-gated. Commit WITH a valid APPLY token: the perimeter gate must
# still refuse it, proving the typed confirmation is UX friction, not a security bypass (#719).
jq '.monero.view_key="deadbeef"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "monero view-key set commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json gains no view key" "$(jq -r '.monero.view_key // "unset"' "$C/config.json")" "unset"
# XvB pool-URL repoint: redirects donated hashrate to an attacker's pool.
jq '.xvb.url="attacker.example:4247"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb pool-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the default xvb url" "$(jq -r '.xvb.url // "unset"' "$C/config.json")" "unset"
# The tamper-evidence alert toggles stay host-only even though sibling event toggles are
# editable: silencing WALLET_CHANGED would blind the future #338 approval channel.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "wallet-changed alert silencing is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
# An allowlisted operational toggle on the same baseline still commits.
jq '.telegram.events={node_down:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "allowlisted alert toggle still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "alert toggle landed in config.json" "$(jq -r '.telegram.events.node_down' "$C/config.json")" "false"
# dashboard.workers (#172) never renders to .env, so the env-diff allowlist can't see it — yet it
# carries per-rig hosts and API tokens (a committed attacker host would point token-bearing probes
# at it). The gate must refuse it via its explicit config-level check.
jq '.dashboard.workers=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "dashboard.workers change commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "workers refusal names dashboard.workers" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "dashboard.workers"
assert_eq "config.json keeps no worker descriptors" "$(jq -r '.dashboard.workers // "unset"' "$C/config.json")" "unset"
# Same refusal on the CURRENT workers.list[] shape (#506) — the gate must catch either key.
jq '.workers.list=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list change commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "workers.list refusal names the per-worker descriptors" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "workers.list"
assert_eq "config.json keeps no workers.list descriptors" "$(jq -r '.workers.list // "unset"' "$C/config.json")" "unset"

# dashboard.energy (#504) is the ONE config.json-only block a commit MAY change: it never renders
# to .env, so the host previews it as a normal INFO row (not the old non-committable HOST note) and
# the commit lands it in config.json. Preview first to assert the committable row + non-destructive.
jq '.dashboard.energy={cost_per_kwh:0.18,currency:"EUR",xmr_price:142.5}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy preview status" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_contains "energy preview carries a committable change row" "$(jq -r '.changes[] | select(.key=="dashboard.energy") | .flag' "$RESULTS/$UUID5.json" 2>/dev/null)" "INFO"
assert_eq "energy edit alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy edit commits" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "energy cost landed in config.json" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
assert_eq "energy currency landed in config.json" "$(jq -r '.dashboard.energy.currency' "$C/config.json")" "EUR"
assert_contains "energy commit audits the synthetic key name (#504)" "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"

# Unedited editor round-trip (#696): the form serves the reference-merged config and posts the
# merged document back, so a save with NO edits must preview as zero changes. The live energy
# block above is partial — the merge materializes the remaining reference defaults (tari_price,
# price_feed) into the staged copy, and defaults against an absent value are the same settings,
# not an "Energy calculator settings updated" row.
UUIDE="55555555-5555-4555-8555-555555555555"
jq -s --arg id "$UUIDE" '{id:$id, action:"preview", actor:"admin",
    config:((.[0] | del(._docs)) * .[1])}' "$ROOT/config.reference.json" "$C/config.json" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip previews" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "previewed"
assert_eq "unedited merged round-trip shows zero changes (#696)" "$(jq -r '.changes | length' "$RESULTS/$UUIDE.json" 2>/dev/null)" "0"
# Audit leg of the same contract: committing that unedited round-trip must not record a phantom
# DASHBOARD_ENERGY key — the gate's audit comparison merges the reference defaults too (#696).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUIDE" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip commits" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "applied"
assert_not_contains "unedited commit audits no phantom DASHBOARD_ENERGY key (#696)" \
    "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"
rm -f "$RESULTS/$UUIDE.json" "$STAGED/$UUIDE.json"

# NEGATIVE — the #504 security teeth: an energy edit BUNDLED with a change that is NOT on the env
# allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND) must be REFUSED. The energy exemption must
# not become a carrier for other config: the gate re-derives the env change set host-side and the
# allowlist catches the monero key even though the energy block is legitimately editable.
jq '.dashboard.energy={cost_per_kwh:0.25} | .monero.rpc_lan_access=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit bundled with a non-allowlisted key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "bundled refusal names the security-sensitive gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps monero LAN access off after the refusal" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
assert_eq "config.json keeps the previously-committed energy cost after the refusal" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"

# NEGATIVE — closed-schema smuggling (#33 hardening). An unrecognized config.json key renders to NO
# env var, so it emits ZERO porcelain rows: invisible to the env-diff allowlist, yet the commit's
# `cp` would persist it. The schema guard must refuse it. (a) A LEGIT energy edit bundled with a
# smuggled top-level key is refused whole, and the key never lands. (b) A config identical to live
# except for one extra key still refuses — an empty change set must not read as "clean".
jq '.dashboard.energy={cost_per_kwh:0.30} | .attacker_smuggled={payload:"pwned"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit smuggling an unknown top-level key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "smuggle refusal names the schema and the offending key" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema (attacker_smuggled"
assert_eq "config.json never gains the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
assert_eq "config.json keeps the pre-smuggle energy cost" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
# Only an unknown key added — every rendered value byte-identical to live, so the porcelain is empty.
jq '.attacker_smuggled={payload:"x"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "an otherwise-identical config with one extra key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "empty-porcelain smuggle still names the schema guard" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema"
assert_eq "config.json still free of the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
# A nested unknown key under a KNOWN block (dashboard.energy) is caught by the same guard.
jq '.dashboard.energy={cost_per_kwh:0.18,__evil:{x:1}}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a nested unknown key under a known block is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"

# NO FALSE-REJECT on legacy configs: config.reference.json must be a COMPLETE superset of every path
# pithead READS, or the closed-schema guard refuses a legit config on EVERY commit. A config.json
# predating the xvb rename still carries a legacy xmrig_proxy.* block (read as an alias at pithead
# ~L3245). Seed it into the live baseline, then prove a normal on-allowlist commit
# (xvb.donation_level -> XVB_DONATION_LEVEL) still passes the gate and the legacy block round-trips.
jq '.xmrig_proxy={enabled:true,url:"na.xmrvsbeast.com:4247",donor_id:"auto"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.xvb.donation_level="whale"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a commit on a config carrying a legacy xmrig_proxy block still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the allowlisted xvb tier landed in config.json" "$(jq -r '.xvb.donation_level' "$C/config.json")" "whale"
assert_eq "the legacy xmrig_proxy block round-trips untouched" "$(jq -r '.xmrig_proxy.url' "$C/config.json")" "na.xmrvsbeast.com:4247"

# Forged-flag bypass: the container tampers its visible copy of the preview result to
# destructive:false AND sends a commit request carrying its own destructive:false field. The
# extra request key is rejected outright; a clean follow-up commit is still refused because the
# gate re-derives the change set host-side from the STAGED config — it never reads either flag.
jq '.telegram.bot_token="999999:forged-token"' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
printf '{"status":"previewed","changes":[],"destructive":false,"ts":0}\n' >"$RESULTS/$UUID5.json"
printf '{"id":"%s","action":"commit","actor":"admin","destructive":false}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "commit request smuggling a destructive flag is rejected" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "unexpected keys"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "commit after result-file tampering is still refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tampered-flag refusal comes from the host-side re-derivation" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the untampered bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Sensitive keys PRESENT but UNCHANGED must not trip the gate: a plain pool-tier change on the
# same baseline (auth + onion + stratum password + telegram all set) still applies.
jq '.p2pool.pool="mini"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "non-security change on a security-laden config still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "pool tier change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"

echo "== black-box: editable-allowlist commit round-trip, every key (#522) =="
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json — not just pass a describe_change unit check.
# Fresh baseline with each tunable at a known value so every row below is a genuine single-key
# env diff (pool flips P2POOL_FLAGS + P2POOL_PORT, both allowlisted).
jq -n --arg w "$WALLET" '{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",mem_limit:"4g",prep_blocks_threads:4},
    tari:{wallet_address:"T",mem_limit:"3g"}, p2pool:{pool:"main"},
    xvb:{enabled:true,donation_level:"donor"}, telegram:{daily_summary_time:"08:00"},
    dashboard:{secure:true,host:"box.lan",tari_required:true,check_for_updates:true,timezone:"UTC",
               hashrate_drop_threshold:50,hashrate_drop_minutes:10,
               auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
roundtrip_key() { # <label> <jq-set> <jq-read> <expected>
    jq "$2" "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "$1 commit applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
    assert_eq "$1 landed in config.json" "$(jq -r "$3" "$C/config.json")" "$4"
}
roundtrip_key "XVB_ENABLED" '.xvb.enabled=false' '.xvb.enabled' "false"
roundtrip_key "XVB_DONATION_LEVEL" '.xvb.donation_level="whale"' '.xvb.donation_level' "whale"
roundtrip_key "TARI_REQUIRED" '.dashboard.tari_required=false' '.dashboard.tari_required' "false"
roundtrip_key "DASHBOARD_FAIL_CLOSED" '.dashboard.fail_closed=true' '.dashboard.fail_closed' "true"
roundtrip_key "DASHBOARD_CHECK_UPDATES" '.dashboard.check_for_updates=false' '.dashboard.check_for_updates' "false"
roundtrip_key "DASHBOARD_TZ" '.dashboard.timezone="Europe/Paris"' '.dashboard.timezone' "Europe/Paris"
roundtrip_key "MONERO_MEM_LIMIT" '.monero.mem_limit="5g"' '.monero.mem_limit' "5g"
roundtrip_key "TARI_MEM_LIMIT" '.tari.mem_limit="2g"' '.tari.mem_limit' "2g"
roundtrip_key "MONERO_PREP_THREADS" '.monero.prep_blocks_threads=8' '.monero.prep_blocks_threads' "8"
roundtrip_key "HASHRATE_DROP_THRESHOLD_PCT" '.dashboard.hashrate_drop_threshold=40' '.dashboard.hashrate_drop_threshold' "40"
roundtrip_key "HASHRATE_DROP_MINUTES" '.dashboard.hashrate_drop_minutes=15' '.dashboard.hashrate_drop_minutes' "15"
roundtrip_key "TELEGRAM_DAILY_SUMMARY_TIME" '.telegram.daily_summary_time="09:30"' '.telegram.daily_summary_time' "09:30"
roundtrip_key "P2POOL_FLAGS/P2POOL_PORT" '.p2pool.pool="mini"' '.p2pool.pool' "mini"
# The 24 allowlisted TELEGRAM_EVENT_* toggles. wallet_changed + clearnet_exposed are deliberately
# NOT on the allowlist (tamper-evidence alarms; their refusal is asserted above), so they are
# excluded here. Each flips true->false as a single-key diff.
for ev in node_down node_recovered worker_offline worker_recovered worker_joined worker_left \
    sync_finished disk_space db_unhealthy db_reset xvb_no_share xvb_registration new_release \
    stack_online daily_summary hashrate_low hashrate_loss hugepages low_ram high_reject_rate \
    block_found payout_found payout_confirmed container_unhealthy; do
    roundtrip_key "TELEGRAM_EVENT ${ev}" ".telegram.events.${ev}=false" ".telegram.events.${ev}" "false"
done

echo "== black-box: per-worker token mask + host-side restore, legacy dashboard.workers (#172/#679) =="
# dashboard.workers[].token is a per-rig credential living in a VARIABLE-LENGTH array — out of the
# fixed CONTROL_SECRET_PATHS walk. The masked prefill copy must sentinel each set token (extends
# the #440 property per-rig), and the staging swap must restore each sentinel from the LIVE token
# matched by worker NAME. Per-worker descriptors are never dashboard-EDITABLE (the commit gate
# refuses any dashboard.workers change, asserted above) — so this restore is exactly what lets an
# operator's OTHER edits round-trip: the workers come back as sentinels and must resolve to the
# live values unchanged, or every dashboard commit on a stack with configured workers would fail.
# Since #679 `apply` MIGRATES the legacy shape, so a live config carries dashboard.workers only
# between a hand-edit and the next apply — exactly the state the preview leg (a dry run, never
# migrates) still serves. Hand-edit to legacy and render the masked copy directly, no apply.
jq '.dashboard.workers=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}] | del(.workers.list)' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears,
#    and a token-less worker stays token-less.
assert_eq "per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less worker stays token-less in the masked copy" "$(jq -r '.dashboard.workers[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no per-worker token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no per-worker token" ;;
esac
# 2) staging swap: a proposal that prefills the workers from the masked copy (sentinel tokens) and
#    changes only an allowlisted key stages with each token restored from live BY NAME.
UUID6="66666666-6666-4666-8666-666666666666"
jq --arg id "$UUID6" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="main")}' "$MASKED" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "previewed"
assert_eq "per-worker sentinel restored to the live token by name" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second per-worker sentinel restored by name" "$(jq -r '.dashboard.workers[2].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig3secret"
assert_eq "token-less worker stays token-less at staging" "$(jq -r '.dashboard.workers[1] | has("token")' "$STAGED/$UUID6.json" 2>/dev/null)" "false"
case "$(cat "$RESULTS/$UUID6.json")$(cat "$AUDIT")" in
*tok_rig1secret* | *tok_rig3secret*) bad "results/audit stay free of the restored per-worker token" "a per-worker token leaked" ;;
*) ok "results/audit stay free of the restored per-worker token" ;;
esac
# 3) commit: workers restored to live == live, so the gate passes on the pool-only change; the
#    commit's `apply -y` then MIGRATES (#679) — the committed config keeps the live per-worker
#    tokens under workers.list[], the legacy key is gone, and the pre-migration copy sits beside.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID6" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live per-worker token (migrated to workers.list, #679)" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "commit migrated the legacy key away (#679)" "$(jq -r '.dashboard | has("workers")' "$C/config.json")" "false"
assert_eq "pre-migration copy kept through the control commit (#679)" "$(jq -r '.dashboard.workers[0].token' "$C/config.json.bak-workers" 2>/dev/null)" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
# 4) duplicate names resolve first-declared-wins (staging only — a duplicate can't round-trip a
#    commit, since the second entry's token would flip and trip the gate). Same hand-edited
#    legacy state as above: masked copy rendered directly, no apply, so no migration yet.
jq 'del(.workers.list) | .dashboard.workers=[{name:"rig1",host:"10.0.0.5",token:"tok_first"},{name:"rig1",token:"tok_second"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
UUID7="77777777-7777-4777-8777-777777777777"
jq --arg id "$UUID7" '{id:$id, action:"preview", actor:"admin", config: .}' "$MASKED" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "duplicate-name sentinel restores the first-declared token" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"
assert_eq "duplicate-name second entry also resolves to first-declared" "$(jq -r '.dashboard.workers[1].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"

echo "== black-box: per-worker token mask + host-side restore, workers.list[] shape (#506) =="
# Same mask/restore/commit round-trip as above, but on the CURRENT workers.list[] shape — proves
# render_masked_config and the control_preview sentinel swap key off whichever shape the live
# config actually uses, not a hardcoded dashboard.workers path. Clear the legacy key first so the
# live config carries only the new shape (both-set is refused at apply, asserted earlier).
jq 'del(.dashboard.workers) | .workers.list=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears.
assert_eq "workers.list token masked to the sentinel" "$(jq -c '.workers.list[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second workers.list token masked to the sentinel" "$(jq -c '.workers.list[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less workers.list worker stays token-less in the masked copy" "$(jq -r '.workers.list[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no workers.list token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no workers.list token" ;;
esac
# 2) staging swap: a proposal that prefills from the masked copy stages with each token restored
#    from live BY NAME.
UUID8="88888888-8888-4888-8888-888888888888"
jq --arg id "$UUID8" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="nano")}' "$MASKED" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "previewed"
assert_eq "workers.list sentinel restored to the live token by name" "$(jq -r '.workers.list[0].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second workers.list sentinel restored by name" "$(jq -r '.workers.list[2].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig3secret"
# 3) commit: workers.list restored to live == live, so the gate passes on the pool-only change, and
#    the committed config KEEPS the live per-worker tokens.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID8" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live workers.list token" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"

echo "== black-box: audit log growth is bounded (#349) =="
# Seed the log past the 512 KiB cap, then let the runner audit one more event: the writer trims
# to the newest 2000 lines BEFORE appending, so the file shrinks instead of growing forever and
# the fresh entry is always the last line.
for _ in $(seq 1 6000); do
    printf '{"ts":"old","id":"","actor":"filler","action":"preview","status":"previewed","keys":""}\n'
done >>"$AUDIT"
[ "$(wc -c <"$AUDIT" | tr -d ' ')" -gt 524288 ] || bad "audit log seeded past the cap" "seed too small"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json" # no staged intent -> rejected, still audited
run_pending >/dev/null
audit_size="$(wc -c <"$AUDIT" | tr -d ' ')"
if [ "$audit_size" -lt 300000 ]; then
    ok "audit log trimmed back under the cap ($audit_size bytes)"
else
    bad "audit log trimmed back under the cap" "$audit_size bytes"
fi
assert_eq "trim keeps the newest entries (fresh entry is the last line)" "$(tail -n 1 "$AUDIT" | jq -r '.action')" "commit"
# Pin the line count too, not just the byte size: control_audit trims to `tail -n 2000` BEFORE
# appending the triggering entry, so the file must land at <= 2001 lines (2000 kept + the new one) —
# the "newest ~2000 lines" behavior the byte-size check above doesn't directly prove.
audit_lines="$(wc -l <"$AUDIT" | tr -d ' ')"
if [ "$audit_lines" -le 2001 ]; then
    ok "audit log trim caps the line count near the newest 2000 entries ($audit_lines lines)"
else
    bad "audit log trim caps the line count near the newest 2000 entries" "$audit_lines lines"
fi

echo "== black-box: spool intake cap + symlink refusal + stale sweep (#33 hardening) =="
UUID4="44444444-4444-4444-8444-444444444444"
# Oversized intent: refused BEFORE jq parses it (bounded root-runner DoS), no result addressed.
: >"$AUDIT"
{
    printf '{"id":"%s","action":"preview","pad":"' "$UUID4"
    head -c 70000 /dev/zero | tr '\0' a
    printf '"}\n'
} >"$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "oversized intent refused before parsing" "$(cat "$AUDIT" 2>/dev/null)" "refused-oversize"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "oversized intent gets no result file" || bad "oversized intent gets no result file" "result written"
[ ! -f "$REQS/$UUID4.json" ] && ok "oversized intent claimed out of requests/" || bad "oversized intent claimed out of requests/" "still present"
# Symlinked request: a symlink dropped in requests/ could point the root runner at any host file —
# refused, never followed (graft #437).
: >"$AUDIT"
ln -s "$C/config.json" "$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "symlinked request refused" "$(cat "$AUDIT" 2>/dev/null)" "refused-nonregular"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "symlinked request gets no result" || bad "symlinked request gets no result" "result written"
rm -f "$REQS/$UUID4.json"
# Stale sweep: staged/ + requests/ files older than an hour are removed at run start.
jq -n '{}' >"$STAGED/stale.json"
touch -t 202001010000 "$STAGED/stale.json"
printf '{}' >"$REQS/stale-req.json"
touch -t 202001010000 "$REQS/stale-req.json"
run_pending >/dev/null
[ ! -f "$STAGED/stale.json" ] && ok "aged staged file swept" || bad "aged staged file swept" "still present"
[ ! -f "$REQS/stale-req.json" ] && ok "aged request file swept" || bad "aged request file swept" "still present"
# Orphaned claim sweep (#548): a `.claim.<pid>` left behind by a runner that died mid-dispatch
# (the errexit gap this issue closes) is swept the same way as stale staged/request files.
touch -t 202001010000 "$C/data/control/.claim.12345"
run_pending >/dev/null
[ ! -f "$C/data/control/.claim.12345" ] && ok "stale orphaned claim swept" || bad "stale orphaned claim swept" "still present"
# Per-run intake cap: 60 pending intents → one run claims exactly 50 and LEAVES the remainder in
# requests/ for the next path-unit fire (deterministic overflow — nothing is dropped). Invalid
# JSON bodies keep each of the 60 on the cheap discard path; they still count against the cap.
for i in $(seq 1 60); do printf 'notjson' >"$REQS/cap-$i.json"; done
out="$(run_pending)"
assert_contains "per-run cap announced after 50 intents" "$out" "per-run cap"
assert_contains "exactly 50 intents processed in one run" "$out" "Processed 50 control request(s)"
assert_eq "overflow intents left for the next run" "$(ls "$REQS" | wc -l | tr -d ' ')" "10"
out="$(run_pending)"
assert_contains "next run drains the remainder" "$out" "Processed 10 control request(s)"
assert_eq "spool empty after the second run" "$(ls "$REQS" | wc -l | tr -d ' ')" "0"

echo "== black-box: control upgrade verb (#59) =="
# A RELEASE install (no build/*/Dockerfile → is_source_checkout false) with the control channel
# on. The runner's upgrade verb runs against a stub curl (GitHub release API + bundle download)
# and a fake release bundle whose pithead records what it was asked to do — no network, no docker.
UPG="$SANDBOX/upgrade59"
UPGREQS="$UPG/data/control/requests"
UPGRESULTS="$UPG/data/control/results"
UPGAUDIT="$UPG/data/control/audit/control.log"
mkdir -p "$UPGREQS" "$UPG/data/control/staged" "$UPGRESULTS" "$UPG/data/control/audit"
cp "$STACK" "$UPG/pithead"
make_stubs "$UPG/bin"
# The #544 abort ("Cannot unlink: Directory not empty") is GNU-tar behaviour — macOS's bsdtar -U
# tolerates non-empty dirs and would mask the regression. CI (Linux) and real installs run GNU
# tar; on a Mac with gnu-tar installed, route this block's tar there too so the bug reproduces.
command -v gtar >/dev/null 2>&1 && ln -sf "$(command -v gtar)" "$UPG/bin/tar"
# Every release bundle ships cosign.pub, so the runner requires the verifier before it downloads
# anything (#1023) — the fixture carries a runnable one so the paths that are supposed to proceed do
# not depend on the host. Since #1072 that means a fake docker, not a fake cosign. It stays inert
# here: this install has no cosign.pub, so no signature is ever fetched and nothing invokes it.
write_fake_docker "$UPG/bin"
printf '1.3.1' >"$UPG/VERSION"
printf '{}' >"$UPG/config.json" # #637: the in-place path snapshots config.json before extracting
# #544/#555: a real release install carries non-empty build/* config-template mounts (see the
# bundle's build/* below) — pre-seed them here with STALE content from "the previous version",
# including a file the new bundle does NOT ship, so the extraction below runs over the exact shape
# that made v1.6.0's single -U tar pass abort ("Cannot unlink: Directory not empty").
mkdir -p "$UPG/build/monero" "$UPG/build/tari" "$UPG/build/tari-wallet"
printf 'stale-monero-template-v1.3.1\n' >"$UPG/build/monero/bitmonero.conf.template"
printf 'stale-tari-template-v1.3.1\n' >"$UPG/build/tari/config.toml.template"
printf 'stale-tari-wallet-entry-v1.3.1\n' >"$UPG/build/tari-wallet/entrypoint.sh"
printf 'leftover-from-a-removed-mount\n' >"$UPG/build/monero/leftover.conf" # absent from the new bundle
# The stub curl serves the canned API response for the release-API URL and copies the fake bundle
# for the download URL; every call is logged so the tests can assert what was (not) dialled.
cat >"$UPG/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "[curl] $*" >>"${CURL_LOG:-/dev/null}"
[ "${CURL_FAIL:-}" = "1" ] && exit 22
url="${*: -1}"
out=""
prev=""
for a in "$@"; do
    [ "$prev" = "-o" ] && out="$a"
    prev="$a"
done
case "$url" in
*api.github.com*) cat "${CURL_API_RESPONSE:?}" ;;
*releases/download/*.sig) cp "${CURL_SIG:?}" "$out" ;;
*releases/download/*) cp "${CURL_BUNDLE:?}" "$out" ;;
*) exit 22 ;;
esac
EOF
chmod +x "$UPG/bin/curl"
# The fake v9.9.9 release bundle: a pithead that logs its invocation (and can be told to fail).
UPGB="$SANDBOX/upgrade59-bundle"
mkdir -p "$UPGB/pithead/build/monero" "$UPGB/pithead/build/tari" "$UPGB/pithead/build/tari-wallet"
cat >"$UPGB/pithead/pithead" <<'EOF'
#!/usr/bin/env bash
echo "new-pithead $*" >>upgrade-invocations.log
[ "${NEW_PITHEAD_FAIL:-}" = "1" ] && exit 1
exit 0
EOF
chmod +x "$UPGB/pithead/pithead"
printf '9.9.9' >"$UPGB/pithead/VERSION"
# build/* members mirror the real bundle layout (scripts/release.sh's compose_build_mounts): every
# release install carries these non-empty config-template mounts, which is exactly what #544/#555
# tests below — a bundle with only the "pithead" script can't reproduce that bug.
printf 'new-monero-template-v9.9.9\n' >"$UPGB/pithead/build/monero/bitmonero.conf.template"
printf 'new-tari-template-v9.9.9\n' >"$UPGB/pithead/build/tari/config.toml.template"
printf 'new-tari-wallet-entry-v9.9.9\n' >"$UPGB/pithead/build/tari-wallet/entrypoint.sh"
tar -czf "$UPGB/bundle.tar.gz" -C "$UPGB" pithead
printf '{"tag_name":"v9.9.9","html_url":"https://example.invalid/rel"}' >"$UPGB/api.json"
seed_upgrade_env() { # <control-enabled true|false>
    cat >"$UPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=$1
CONTROL_DIR=$UPG/data/control
NETWORK_PREFIX=10.9.0
EOF
}
urun() {
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        ./pithead control-run-pending 2>&1)
}
upgrade_intent() { # <id> [version] — drop an upgrade request into the spool
    if [ "$#" -ge 2 ]; then
        printf '{"id":"%s","action":"upgrade","actor":"admin","version":"%s"}\n' "$1" "$2" >"$UPGREQS/$1.json"
    else
        printf '{"id":"%s","action":"upgrade","actor":"admin"}\n' "$1" >"$UPGREQS/$1.json"
    fi
}
UUPG="66666666-6666-4666-8666-666666666666"
reset_upgrade_state() { # restore between attempts: fresh runner copy, running version, no throttle
    cp "$STACK" "$UPG/pithead"
    printf '1.3.1' >"$UPG/VERSION"
    rm -f "$UPG/data/control/staged/.upgrade-stamp" "$UPGRESULTS/$UUPG.json" "$UPG/upgrade-invocations.log"
    rm -f "$UPG"/config.json.bak-upgrade-* "$UPG"/.env.bak-upgrade-* # #637 snapshots
    : >"$UPG/curl.log"
}

# Source checkout ($C): the upgrade verb is refused outright — its update path is `git pull`.
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$REQS/$UUPG.json"
run_pending >/dev/null
assert_eq "upgrade on a source checkout is rejected" "$(jq -r '.status' "$RESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "source-checkout refusal points at git pull" "$(jq -r '.error' "$RESULTS/$UUPG.json" 2>/dev/null)" "git pull"
rm -f "$RESULTS/$UUPG.json"

# Channel off: the runner refuses to process ANYTHING — the intent stays unclaimed, no result.
seed_upgrade_env false
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "upgrade runner refuses when the channel is off" "$?" "1"
assert_contains "channel-off refusal names the flag" "$out" "not enabled"
[ -f "$UPGREQS/$UUPG.json" ] && ok "channel-off intent left unclaimed" || bad "channel-off intent left unclaimed" "claimed"
[ ! -f "$UPGRESULTS/$UUPG.json" ] && ok "channel-off intent gets no result" || bad "channel-off intent gets no result" "result written"
rm -f "$UPGREQS/$UUPG.json"
seed_upgrade_env true

# #1023: no cosign on the host -> refused before a single dial, whether or not this install already
# holds a key. This fixture has NO cosign.pub (it models an install cut before signing engaged),
# which is exactly the shape that used to sail past the old `[ -f cosign.pub ] &&` guard, download
# the bundle, extract it over the install, and only then abort inside the new CLI's image gate.
# Same pinned PATH as its key-holding twin below, so a host cosign can't decide the test.
reset_upgrade_state
ln -sf "$(command -v jq)" "$UPG/bin/jq" # PATH is pinned below, which may not carry jq
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
rm -f "$UPG/bin/jq"
assert_eq "upgrade without a runnable verifier is rejected on a key-less install" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing refusal names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal dials nothing" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
assert_eq "verifier-missing refusal extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "verifier-missing refusal claims no throttle" "$(ls "$UPG/data/control/staged/.upgrade-stamp" 2>/dev/null)" ""

# Malformed / missing version: refused BEFORE any network dial (curl must never run).
reset_upgrade_state
upgrade_intent "$UUPG" 'v9.9.9;curl evil.tld'
urun >/dev/null
assert_eq "shell-metacharacter version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "malformed-version rejection names the field" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "version"
assert_eq "no network dial for a malformed version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""
reset_upgrade_state
upgrade_intent "$UUPG"
urun >/dev/null
assert_eq "missing version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_eq "no network dial for a missing version" "$(cat "$UPG/curl.log" 2>/dev/null)" ""

# A smuggled target field (the image-swap vector): the closed key set refuses the whole request.
reset_upgrade_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9","target":"evil.tld/img:tag"}\n' "$UUPG" >"$UPGREQS/$UUPG.json"
urun >/dev/null
assert_contains "upgrade intent smuggling a target is rejected" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "unexpected keys"

# Forged/stale version: the container proposes v1.9.9 but the host-derived latest is v9.9.9 —
# refused, nothing downloaded, nothing extracted. The container cannot choose the target.
reset_upgrade_state
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_eq "container-proposed non-latest version is rejected" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "forged-version rejection names the real latest" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "forged version downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
assert_eq "forged version leaves the install untouched" "$(cat "$UPG/VERSION")" "1.3.1"
# ...and it still CLAIMED the throttle (stamp taken before the network dial), so a compromised
# container can't flood well-formed-but-stale intents to grind the GitHub API / beacon over Tor:
# a second attempt straight after — without reset — is throttled (#59 review, egress-beacon guard).
upgrade_intent "$UUPG" "v1.9.9"
urun >/dev/null
assert_contains "a non-latest attempt still claims the throttle" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"

# Already up to date: latest equals the running version — refused, no download.
reset_upgrade_state
printf '{"tag_name":"v1.3.1","html_url":"https://example.invalid/rel"}' >"$UPGB/api-same.json"
upgrade_intent "$UUPG" "v1.3.1"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-same.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "same-version upgrade is rejected as up to date" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "already up to date"

# Release API unreachable / unusable: refused, nothing changed (fail closed, silent stack).
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "unreachable release API rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "could not reach"
reset_upgrade_state
printf '{"tag_name":"main","html_url":"https://example.invalid/rel"}' >"$UPGB/api-bad.json"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api-bad.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_contains "non-semver API tag rejects the upgrade" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no usable release tag"

# Bundle download failure AFTER the checks pass: the attempt fails, the stack keeps running.
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/missing.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed bundle download reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "download failure says the stack keeps running" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "keeps running"
assert_eq "download failure extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

# `pithead upgrade` itself fails after extraction: status failed, error points at the host CLI.
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" NEW_PITHEAD_FAIL=1 CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "failed upgrade run reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "failed upgrade points at the host CLI" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "./pithead upgrade"
assert_contains "failed upgrade audited" "$(cat "$UPGAUDIT" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"failed\""
# #637: the failure result names the pre-upgrade config/.env copies, and they exist on disk.
upg_bak="$(jq -r '.backup // ""' "$UPGRESULTS/$UUPG.json" 2>/dev/null)"
assert_contains "failed in-place upgrade names the pre-upgrade copies (#637)" "$upg_bak" ".bak-upgrade-"
upg_bak_cfg="${upg_bak%% *}"
[ -n "$upg_bak_cfg" ] && [ -f "$upg_bak_cfg" ] && ok "the named config.json copy exists (#637)" ||
    bad "the named config.json copy exists (#637)" "missing: $upg_bak_cfg"

# Happy path: proposed == host-derived latest and newer than running → bundle extracted, the NEW
# pithead's `upgrade` ran, both dials went through the stack's Tor SOCKS, everything audited.
reset_upgrade_state
: >"$UPGAUDIT"
upgrade_intent "$UUPG" "v9.9.9"
out="$(urun)"
assert_rc "runner exits 0 on a valid upgrade" "$?" "0"
assert_eq "upgrade result status" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "upgrade result carries the host-derived version" "$(jq -r '.version' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "v9.9.9"
assert_eq "bundle extracted over the install" "$(cat "$UPG/VERSION")" "9.9.9"
assert_contains "the NEW pithead ran the upgrade" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
assert_eq "both GitHub dials went over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050' "$UPG/curl.log")" "2"
# #376 fallback: this install has no cosign.pub, so no signature is fetched — today's behaviour.
assert_eq "no cosign.pub -> no signature dial (documented fallback)" "$(grep -c '\.sig' "$UPG/curl.log" || true)" "0"
assert_contains "upgrade start audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"started\""
assert_contains "upgrade completion audited" "$(cat "$UPGAUDIT")" "\"action\":\"upgrade\",\"status\":\"upgraded\""
# #544/#555: the extraction above ran over the non-empty build/* dirs pre-seeded near the top of
# this block — this is the regression test for the withdrawn v1.6.0 bug. Pin b12082c's documented
# semantics: pass 1 MERGES directories with plain tar (never purges), so new build/* content lands
# and a stale file the new bundle doesn't carry survives untouched.
assert_eq "build/* new content lands (monero template)" "$(cat "$UPG/build/monero/bitmonero.conf.template" 2>/dev/null)" "new-monero-template-v9.9.9"
assert_eq "build/* new content lands (tari template)" "$(cat "$UPG/build/tari/config.toml.template" 2>/dev/null)" "new-tari-template-v9.9.9"
assert_eq "build/* new content lands (tari-wallet entrypoint)" "$(cat "$UPG/build/tari-wallet/entrypoint.sh" 2>/dev/null)" "new-tari-wallet-entry-v9.9.9"
assert_eq "a stale build/* file absent from the new bundle survives the merge" "$(cat "$UPG/build/monero/leftover.conf" 2>/dev/null)" "leftover-from-a-removed-mount"
# No partial/temp extraction residue after a successful run: the staged bundle + tar log are gone.
if [ ! -e "$UPG/data/control/staged/.$UUPG.tar.gz" ] && [ ! -e "$UPG/data/control/staged/.$UUPG.log" ]; then
    ok "no staged bundle/log residue after a successful upgrade"
else
    bad "no staged bundle/log residue after a successful upgrade" "leftover staging file present"
fi
# #637: before the extraction overwrote the install, the runner kept timestamped copies of the
# operator's config and the rendered .env — the in-place layout's only restore point.
upg_bak_env="$(ls "$UPG"/.env.bak-upgrade-* 2>/dev/null | head -1)"
[ -n "$upg_bak_env" ] && ok "in-place upgrade keeps a pre-upgrade .env copy (#637)" ||
    bad "in-place upgrade keeps a pre-upgrade .env copy (#637)" "no .env.bak-upgrade-* in $UPG"
assert_contains "the .env copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
upg_bak_cfg2="$(ls "$UPG"/config.json.bak-upgrade-* 2>/dev/null | head -1)"
assert_eq "the config.json copy holds the pre-upgrade content (#637)" "$(cat "$upg_bak_cfg2" 2>/dev/null)" "{}"

# #637 fail-closed: no snapshot, no upgrade. With config.json unreadable the runner must refuse
# BEFORE a byte of the bundle lands — the whole point of the restore point is that it exists
# before the mutation does.
reset_upgrade_state
mv "$UPG/config.json" "$UPG/config.json.hidden"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "failed snapshot fails the upgrade (#637)" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "snapshot refusal names the missing restore point (#637)" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "restore point"
assert_eq "failed snapshot extracts nothing (#637)" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(ls "$UPG"/.bak-upgrade.* 2>/dev/null)" ] && ok "failed snapshot leaves no mktemp residue (#637)" ||
    bad "failed snapshot leaves no mktemp residue (#637)" "leftover temp file"
mv "$UPG/config.json.hidden" "$UPG/config.json"

# #637 hardening: the snapshot destination name is predictable, so a co-tenant can plant a
# symlink there and hope root writes through it (the #629 attack class) — the runner must
# replace the planted entry, never follow it. And old snapshots hold yesterday's secrets, so
# only the newest three pairs survive. Freeze `date` so the destination name is known.
reset_upgrade_state
cat >"$UPG/bin/date" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "+%Y%m%d-%H%M%S" ]; then echo "20990101-000000"; else exec /bin/date "$@"; fi
EOF
chmod +x "$UPG/bin/date"
printf 'victim-untouched' >"$UPG/victim"
ln -s "$UPG/victim" "$UPG/config.json.bak-upgrade-20990101-000000"
for bakstamp in 20200101-000000 20200102-000000 20200103-000000; do
    printf 'stale' >"$UPG/.env.bak-upgrade-$bakstamp"
    printf 'stale' >"$UPG/config.json.bak-upgrade-$bakstamp"
done
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_eq "planted symlink at the snapshot name is not written through (#637)" "$(cat "$UPG/victim")" "victim-untouched"
if [ ! -L "$UPG/config.json.bak-upgrade-20990101-000000" ] && [ -f "$UPG/config.json.bak-upgrade-20990101-000000" ]; then
    ok "the snapshot replaced the planted entry with a regular file (#637)"
else
    bad "the snapshot replaced the planted entry with a regular file (#637)" "still a symlink or missing"
fi
assert_eq "snapshots pruned to the newest three .env copies (#637)" "$(ls -1 "$UPG"/.env.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
assert_eq "snapshots pruned to the newest three config.json copies (#637)" "$(ls -1 "$UPG"/config.json.bak-upgrade-* 2>/dev/null | wc -l | tr -d ' ')" "3"
[ ! -e "$UPG/.env.bak-upgrade-20200101-000000" ] && ok "the oldest .env snapshot was pruned (#637)" ||
    bad "the oldest .env snapshot was pruned (#637)" "still present"
rm -f "$UPG/bin/date" "$UPG/victim"
reset_upgrade_state

# #376 rollback guard: an attacker who controls the release response serves an OLDER (genuine)
# bundle at the v9.9.9 URL — its VERSION (1.0.0) does not match the host-derived tag, so the
# runner refuses BEFORE extraction. A cosign signature binds bytes, not a version, so without
# this check a validly-signed old bundle would silently downgrade the stack.
reset_upgrade_state
mkdir -p "$UPGB/rollback/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/rollback/pithead/pithead"
printf '1.0.0' >"$UPGB/rollback/pithead/VERSION"
tar -czf "$UPGB/rollback.tar.gz" -C "$UPGB/rollback" pithead
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/rollback.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "version-mismatched (rollback) bundle is refused" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "rollback refusal names the mismatch" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rollback"
assert_eq "rollback bundle extracts nothing (VERSION untouched)" "$(cat "$UPG/VERSION")" "1.3.1"
assert_eq "rollback bundle never ran a new pithead" "$(cat "$UPG/upgrade-invocations.log" 2>/dev/null || echo none)" "none"

# #548: a bundle that gzips fine but carries no pithead/VERSION at all (corrupt download, or a
# hostile non-pithead archive) must fail cleanly — not kill the runner via errexit and leave the
# result stuck at "running" with an orphaned claim and the rest of the queue abandoned.
reset_upgrade_state
mkdir -p "$UPGB/noversion/pithead"
cp "$UPGB/pithead/pithead" "$UPGB/noversion/pithead/pithead"
tar -czf "$UPGB/noversion.tar.gz" -C "$UPGB/noversion" pithead
UUPG2="77777777-7777-4777-8777-777777777777"
upgrade_intent "$UUPG" "v9.9.9"
# The drain orders requests by mtime (ls -1tr); a same-second tie breaks differently between GNU
# (CI) and BSD (macOS) ls, flipping which intent runs first — and the second one is throttled.
# One second between the writes makes "UUPG first" deterministic everywhere.
sleep 1
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG2" >"$UPGREQS/$UUPG2.json"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" \
    CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/noversion.tar.gz" \
    ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "bundle missing pithead/VERSION reports failed (not stuck running)" \
    "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-VERSION failure names the cause" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "missing pithead/VERSION"
assert_eq "missing-VERSION bundle extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ -z "$(find "$UPG/data/control" -maxdepth 1 -name '.claim.*' 2>/dev/null)" ] &&
    ok "missing-VERSION failure releases its claim" || bad "missing-VERSION failure releases its claim" "claim file left behind"
[ -f "$UPGRESULTS/$UUPG2.json" ] &&
    ok "the rest of the queue is not abandoned (second intent still processed)" ||
    bad "the rest of the queue is not abandoned (second intent still processed)" "no result written for the second intent"
rm -f "$UPGRESULTS/$UUPG2.json" "$UPGREQS/$UUPG2.json"

# Throttle: a second attempt straight after is refused for 10 minutes (egress-beacon guard).
# The happy path replaced $U/pithead with the fake bundle's script — restore the real runner
# (keeping the throttle stamp the successful attempt left behind).
cp "$STACK" "$UPG/pithead"
upgrade_intent "$UUPG" "v9.9.9"
urun >/dev/null
assert_contains "immediate second upgrade attempt is throttled" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "less than 10 minutes"
reset_upgrade_state

echo "== black-box: control upgrade extracts to a fresh version dir (#629) =="
# A VERSIONED release install (deploy629/pithead-v1.3.1) whose data dirs all resolve OUTSIDE the
# install dir — the documented bundle-deploy layout. The runner must extract v9.9.9 into a fresh
# sibling pithead-v9.9.9/, seed config.json/.env and the install-local state dirs, run the NEW
# dir's pithead upgrade from the new dir, write the result into BOTH spools, and leave this dir
# intact as the rollback copy. Reuses the upgrade59 stubs ($UPG/bin) and fake bundle ($UPGB).
VROOT="$SANDBOX/deploy629"
VUPG="$VROOT/pithead-v1.3.1"
VNEW="$VROOT/pithead-v9.9.9"
mkdir -p "$VUPG/data/control/requests" "$VUPG/data/control/staged" "$VUPG/data/control/results" \
    "$VUPG/data/control/audit" "$VUPG/data/clearnet-state" "$VROOT/data/monero"
cp "$STACK" "$VUPG/pithead"
printf '1.3.1' >"$VUPG/VERSION"
printf '{}' >"$VUPG/config.json"
printf 'clearnet-marker' >"$VUPG/data/clearnet-state/monero.synced"
seed_v629_env() { # data dirs OUTSIDE the install dir → fresh-dir mode
    cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VROOT/data/monero
TARI_DATA_DIR=$VROOT/data/tari
P2POOL_DATA_DIR=$VROOT/data/p2pool
TOR_DATA_DIR=$VROOT/data/tor
DASHBOARD_DATA_DIR=$VROOT/data/dashboard
EOF
}
seed_v629_env
vrun() { # <extra env VAR=val...>
    (cd "$VUPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$VUPG/curl.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" \
        env "$@" ./pithead control-run-pending 2>&1)
}
reset_v629_state() {
    cp "$STACK" "$VUPG/pithead"
    printf '1.3.1' >"$VUPG/VERSION"
    rm -f "$VUPG/data/control/staged/.upgrade-stamp" "$VUPG/data/control/results/$UUPG.json"
    rm -f "$VUPG"/config.json.bak-upgrade-* "$VUPG"/.env.bak-upgrade-* # #637 snapshots
    rm -rf "$VNEW"
}

# Happy path: fresh sibling dir, seeded state, new pithead ran FROM the new dir, both spools
# carry the result, and the running install — the rollback copy — is byte-for-byte untouched.
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun >/dev/null
assert_eq "fresh-dir upgrade result status (old spool)" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "fresh-dir upgrade result status (new spool)" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "new version dir holds the new release" "$(cat "$VNEW/VERSION" 2>/dev/null)" "9.9.9"
assert_eq "old version dir still holds the old release (rollback preserved)" "$(cat "$VUPG/VERSION")" "1.3.1"
cmp -s "$VUPG/pithead" "$STACK" && ok "old dir's pithead untouched by the extraction" ||
    bad "old dir's pithead untouched by the extraction" "the running script was overwritten"
assert_contains "the NEW pithead ran the upgrade from the NEW dir" "$(cat "$VNEW/upgrade-invocations.log" 2>/dev/null)" "new-pithead upgrade"
[ -f "$VNEW/config.json" ] && ok "config.json seeded into the new dir" || bad "config.json seeded into the new dir" "missing"
assert_contains "rendered .env seeded into the new dir" "$(cat "$VNEW/.env" 2>/dev/null)" "DEPLOYMENT_COMPLETED=true"
assert_eq "clearnet sync markers carried over" "$(cat "$VNEW/data/clearnet-state/monero.synced" 2>/dev/null)" "clearnet-marker"
assert_contains "fresh-dir upgrade audited in the old spool" "$(cat "$VUPG/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
assert_contains "fresh-dir upgrade audited in the new spool" "$(cat "$VNEW/data/control/audit/control.log" 2>/dev/null)" "\"action\":\"upgrade\",\"status\":\"upgraded\""
# #637: the result names the old dir as the restore point (pwd -P tail, macOS /private prefix).
assert_contains "fresh-dir result names the old dir as the rollback copy (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"
[ -z "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" ||
    bad "fresh-dir path takes no file snapshots — the old dir IS the restore point (#637)" "found .bak-upgrade-* in $VUPG"

# The new release's upgrade fails: both spools say failed, the error points at the NEW dir for
# the host-side finish, and the old install keeps running — still intact for rollback.
reset_v629_state
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
vrun NEW_PITHEAD_FAIL=1 >/dev/null
assert_eq "failed fresh-dir upgrade reports failed" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
# The runner derives its paths from `pwd -P`, so on macOS the /var/folders sandbox reports as
# /private/var/... — assert on the path's tail, not the unresolved $VNEW.
assert_contains "failed fresh-dir upgrade points at the new dir" "$(jq -r '.error' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v9.9.9 && ./pithead upgrade"
assert_eq "failed fresh-dir upgrade leaves the old install intact" "$(cat "$VUPG/VERSION")" "1.3.1"
assert_eq "failed fresh-dir upgrade wrote the result to the new spool too" "$(jq -r '.status' "$VNEW/data/control/results/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "failed fresh-dir result still names the rollback dir (#637)" \
    "$(jq -r '.rollback // ""' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "/deploy629/pithead-v1.3.1"

# Data inside the install dir (the pre-#455 default): a dir swap would strand it — the runner
# must fall back to the in-place path: no sibling dir, the new release lands in THIS dir.
reset_v629_state
mkdir -p "$VUPG/data/monero" # must exist: the guard canonicalizes via cd/pwd -P
cat >"$VUPG/.env" <<EOF
DEPLOYMENT_COMPLETED=true
DASHBOARD_CONTROL_ENABLED=true
CONTROL_DIR=$VUPG/data/control
NETWORK_PREFIX=10.9.0
MONERO_DATA_DIR=$VUPG/data/monero
EOF
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_eq "data-inside-install falls back to in-place upgrade" "$(cat "$VUPG/VERSION")" "9.9.9"
[ ! -e "$VNEW" ] && ok "data-inside-install creates no sibling version dir" ||
    bad "data-inside-install creates no sibling version dir" "$VNEW exists"
assert_contains "in-place fallback names the stranded data dir" "$out" "MONERO_DATA_DIR resolves inside the install dir"
assert_eq "in-place fallback still upgrades" "$(jq -r '.status' "$VUPG/data/control/results/$UUPG.json" 2>/dev/null)" "upgraded"
[ -n "$(ls "$VUPG"/.env.bak-upgrade-* 2>/dev/null)" ] &&
    ok "in-place fallback keeps the pre-upgrade config/.env copies (#637)" ||
    bad "in-place fallback keeps the pre-upgrade config/.env copies (#637)" "no .bak-upgrade-* in $VUPG"
seed_v629_env

# A pre-existing entry at the target path — a leftover failed attempt, or a co-tenant's planted
# dir/symlink (the mkdir-without--p TOCTOU guard): root must never extract into it. The runner
# refuses the fresh-dir path and upgrades in place instead.
reset_v629_state
mkdir -p "$VNEW"
printf 'not-ours' >"$VNEW/marker"
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "pre-existing target dir falls back to in-place" "$out" "already exists"
assert_eq "pre-existing target dir is never written into" "$(
    cat "$VNEW/marker" 2>/dev/null
    ls "$VNEW" | wc -l | tr -d ' '
)" "not-ours1"
assert_eq "pre-existing target still upgrades in place" "$(cat "$VUPG/VERSION")" "9.9.9"
reset_v629_state
mkdir -p "$VROOT/plant"      # the attacker-controlled tree behind the symlink
ln -s "$VROOT/plant" "$VNEW" # a planted symlink must fail the atomic mkdir, not be followed
printf '{"id":"%s","action":"upgrade","actor":"admin","version":"v9.9.9"}\n' "$UUPG" >"$VUPG/data/control/requests/$UUPG.json"
out="$(vrun)"
assert_contains "planted symlink at the target falls back to in-place" "$out" "already exists"
[ -z "$(ls -A "$VROOT/plant" 2>/dev/null)" ] && ok "planted symlink is not followed (nothing extracted through it)" ||
    bad "planted symlink is not followed (nothing extracted through it)" "files appeared behind the symlink"
rm -f "$VNEW"
seed_v629_env

echo "== black-box: control upgrade verifies the bundle signature (#376) =="
# Give the install a trust anchor (cosign.pub next to pithead — what a signed release bundle
# ships) plus a runnable verifier; the runner must fetch pithead.tar.gz.sig over the same Tor SOCKS
# and verify the download against the EXISTING key before a byte of it is extracted.
write_fake_docker "$UPG/bin"
printf 'fake release public key' >"$UPG/cosign.pub"
printf 'fake signature' >"$UPGB/bundle.sig"
usign() { # <extra env VAR=val...> — one signed-mode runner invocation
    (cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" COSIGN_LOG="$UPG/cosign.log" \
        CURL_API_RESPONSE="$UPGB/api.json" CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" \
        env "$@" ./pithead control-run-pending 2>&1)
}

# Valid signature: the upgrade goes through, and the verification demonstrably happened.
: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign >/dev/null
assert_eq "signed bundle with a valid signature upgrades" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "upgraded"
assert_eq "signature fetched over Tor SOCKS" "$(grep -c -- '--socks5-hostname 10.9.0.25:9050.*pithead\.tar\.gz\.sig' "$UPG/curl.log")" "1"
assert_contains "bundle verified against the existing key, no Rekor" \
    "$(cat "$UPG/cosign.log")" "verify-blob --key cosign.pub --signature"
# Bad signature: FAIL CLOSED — nothing extracted, the install untouched. The red test for the
# control path: bypass the verify-blob call and this goes green-to-broken.
reset_upgrade_state
: >"$UPG/cosign.log"
upgrade_intent "$UUPG" "v9.9.9"
usign COSIGN_RC=1 >/dev/null
assert_eq "bad bundle signature reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "bad-signature failure says verification FAILED" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "verification FAILED"
assert_eq "bad signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"
[ ! -f "$UPG/upgrade-invocations.log" ] && ok "bad signature never runs the new pithead" || bad "bad signature never runs the new pithead" "it ran"

# Missing signature asset: a signed install refuses a release that carries no .sig (fail closed —
# a stripped signature must not downgrade verification to nothing).
reset_upgrade_state
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/bin:$PATH" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/missing.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "missing signature asset reports failed" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "failed"
assert_contains "missing-signature failure names the asset" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "no bundle signature"
assert_eq "missing signature extracts nothing" "$(cat "$UPG/VERSION")" "1.3.1"

# The other half of the same precondition (#1023): an install that already HOLDS the key is
# refused for the same reason a key-less one is — no runnable verifier, no upgrade — BEFORE the
# download. PATH is pinned to the daemon-down stub + /usr/bin:/bin so a working host docker can't
# leak in; jq rides along as a symlink since the pinned PATH may not carry it.
reset_upgrade_state
write_unreachable_docker "$UPG/nodocker"
ln -sf "$(command -v jq)" "$UPG/nodocker/jq"
upgrade_intent "$UUPG" "v9.9.9"
(cd "$UPG" && PATH="$UPG/nodocker:/usr/bin:/bin" CURL_LOG="$UPG/curl.log" CURL_API_RESPONSE="$UPGB/api.json" \
    CURL_BUNDLE="$UPGB/bundle.tar.gz" CURL_SIG="$UPGB/bundle.sig" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "pubkey without a runnable verifier rejects the upgrade" "$(jq -r '.status' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "rejected"
assert_contains "verifier-missing rejection names docker" "$(jq -r '.error' "$UPGRESULTS/$UUPG.json" 2>/dev/null)" "docker is not available"
assert_eq "verifier-missing refusal downloads no bundle" "$(grep -c 'releases/download' "$UPG/curl.log" || true)" "0"
rm -f "$UPG/cosign.pub" "$UPG/nodocker/jq"
reset_upgrade_state

# The runner refuses to run at all when the channel is off (fail-closed).
control_config main
"$C/bin/docker" >/dev/null 2>&1 || true
sed -i.bak 's/"control":{"enabled":true}/"control":{"enabled":false}/' "$C/config.json" 2>/dev/null || true
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
out="$(run_pending)"
assert_rc "runner refuses when the channel is disabled" "$?" "1"
assert_contains "runner disabled message" "$out" "not enabled"

# ---------------------------------------------------------------------------
echo "== unit: update_current_symlink (#455) =="
# A non-versioned install dir (source checkout, plain `pithead/` extract) gets NO symlink —
# `current` only makes sense beside pithead-vX.Y.Z version dirs.
mkdir -p "$SANDBOX/plainroot/pithead"
run_sourced "$SANDBOX/plainroot/pithead" update_current_symlink >/dev/null 2>&1
if [ -e "$SANDBOX/plainroot/current" ]; then
    bad "no current symlink for a non-versioned dir" "created $SANDBOX/plainroot/current"
else
    ok "no current symlink for a non-versioned dir"
fi

# A versioned dir gets `../current -> <dirname>` (relative target, so the tree can move).
mkdir -p "$SANDBOX/deployroot/pithead-v9.9.9" "$SANDBOX/deployroot/pithead-v9.9.10"
run_sourced "$SANDBOX/deployroot/pithead-v9.9.9" update_current_symlink >/dev/null 2>&1
assert_eq "current -> pithead-v9.9.9 after first run" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.9"
# Re-pointing: a later version dir takes over the same symlink (ln -sfn, no stale nesting).
run_sourced "$SANDBOX/deployroot/pithead-v9.9.10" update_current_symlink >/dev/null 2>&1
assert_eq "current re-pointed to pithead-v9.9.10" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.10"
# Idempotent re-run keeps it.
run_sourced "$SANDBOX/deployroot/pithead-v9.9.10" update_current_symlink >/dev/null 2>&1
assert_eq "current unchanged on re-run" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.10"

# `current` existing as a REAL directory is never clobbered (ln -sfn would nest a link inside it).
mkdir -p "$SANDBOX/dirroot/pithead-v1.2.3" "$SANDBOX/dirroot/current"
out="$(run_sourced "$SANDBOX/dirroot/pithead-v1.2.3" update_current_symlink 2>&1)"
rc=$?
assert_rc "real-dir current: still rc 0 (never fails the upgrade)" "$rc" "0"
assert_contains "real-dir current: warns" "$out" "not a symlink"
if [ -d "$SANDBOX/dirroot/current" ] && [ ! -L "$SANDBOX/dirroot/current" ]; then
    ok "real-dir current left untouched"
else
    bad "real-dir current left untouched" "was replaced"
fi

echo "== unit: migrate_dashboard_data (#455) =="
# Direct unit calls with the parse-time globals set by hand; docker stubbed (no daemon in tests).
mig455() { # <workdir> <DASHBOARD_DIR> <is_default>
    (
        cd "$1" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        docker() { :; }
        # shellcheck disable=SC2034  # read by the sourced migrate_dashboard_data
        DASHBOARD_DIR="$2"
        # shellcheck disable=SC2034
        DASHBOARD_DIR_IS_DEFAULT="$3"
        migrate_dashboard_data
    )
}
M="$SANDBOX/mig"
mkdir -p "$M/data/dashboard" "$M/shared"
printf 'olddb' >"$M/data/dashboard/mining_data.db"
# move-if-default: the old in-install-dir data moves to the shared-root default, DB intact.
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "move-if-default succeeds" "$?" "0"
assert_eq "DB moved intact" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb"
if [ -e "$M/data/dashboard" ]; then bad "old default gone after move" "still exists"; else ok "old default gone after move"; fi
# idempotent: nothing at the old default any more -> silent no-op.
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "re-run is a no-op" "$?" "0"
assert_eq "DB survives the re-run" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb"
# warn-if-custom: an operator-pinned dashboard.data_dir is never migrated — warn and leave both.
mkdir -p "$M/data/dashboard"
printf 'olddb2' >"$M/data/dashboard/mining_data.db"
out="$(mig455 "$M" "$M/pinned" 0 2>&1)"
assert_rc "custom path: rc 0" "$?" "0"
assert_contains "custom path: warns about the leftover" "$out" "$M/data/dashboard"
assert_eq "custom path: old data untouched" "$(cat "$M/data/dashboard/mining_data.db")" "olddb2"
if [ -e "$M/pinned/mining_data.db" ]; then bad "custom path: nothing moved" "moved anyway"; else ok "custom path: nothing moved"; fi
# conflict: data at BOTH locations -> hard stop, nothing touched (never guess which DB is live).
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "both-populated: refuses" "$?" "1"
assert_eq "both-populated: old DB untouched" "$(cat "$M/data/dashboard/mining_data.db")" "olddb2"
assert_eq "both-populated: new DB untouched" "$(cat "$M/shared/dashboard/mining_data.db")" "olddb"
# empty pre-created target (an earlier ensure_directories mkdir) is not a conflict — the move runs.
rm -f "$M/shared/dashboard/mining_data.db"
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "empty pre-created target: move succeeds" "$?" "0"
assert_eq "empty pre-created target: DB moved" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb2"

# Wiring: stack_upgrade migrates BEFORE the containers are recreated and points `current` at the
# install only AFTER a successful 'compose up' — a failed upgrade must not move the pointer.
upg455_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 0; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { echo migrate; }
    update_current_symlink() { echo symlink; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade: migrate -> compose -> symlink (#455)" \
    "$(printf '%s\n' "$upg455_order" | grep -xE 'migrate|compose|symlink' | tr '\n' ',')" "migrate,compose,symlink,"
upg455_fail=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 0; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { :; }
    update_current_symlink() { echo symlink; }
    compose_up_checked() { return 1; }
    stack_upgrade
)
assert_not_contains "failed upgrade does NOT move the current pointer (#455)" "$upg455_fail" "symlink"

echo "== black-box: deploy-box layout (#455) =="
# A sandboxed source-checkout install whose chain data dirs share one root — the live deploy-box
# layout. Proves the default resolution, the apply-time migration, and the upgrade-time
# symlink end to end through the real CLI (docker/sudo stubbed).
L="$SANDBOX/boxroot/pithead-v9.9.9"
mkdir -p "$L/build/tari" "$L/build/dashboard"
: >"$L/build/dashboard/Dockerfile"
cp "$STACK" "$L/pithead"
make_stubs "$L/bin"
cp "$ROOT/build/tari/config.toml.template" "$L/build/tari/"
SHARED="$SANDBOX/boxroot/data"
seed_L() {
    cat >"$L/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
}
cfg_L() { # <dashboard-extra-json>  e.g. ',"data_dir":"/pinned"'
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"T","data_dir":"%s/tari"}, "p2pool":{"pool":"main","data_dir":"%s/p2pool"}, "tor":{"data_dir":"%s/tor"}, "dashboard":{"secure":true,"host":"box.lan"%s} }\n' \
        "$WALLET" "$SHARED" "$SHARED" "$SHARED" "$SHARED" "$1" >"$L/config.json"
}
# Old layout on disk: the dashboard DB inside the version dir's ./data (the pre-#455 default).
seed_L
cfg_L ""
mkdir -p "$L/data/dashboard"
printf 'proddb' >"$L/data/dashboard/mining_data.db"
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a shared data root succeeds" "$?" "0"
assert_eq "DASHBOARD_DATA_DIR joins the shared data root" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$SHARED/dashboard"
assert_eq "apply moved the dashboard DB to the shared root" \
    "$(cat "$SHARED/dashboard/mining_data.db" 2>/dev/null)" "proddb"
if [ -e "$L/data/dashboard" ]; then bad "apply: old in-version-dir data gone" "still exists"; else ok "apply: old in-version-dir data gone"; fi
# Re-apply: no config change, nothing to migrate — clean no-op.
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "re-apply is a no-op" "$?" "0"
assert_eq "re-apply leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Upgrade from the versioned dir: maintains `current ->` beside it and stays idempotent.
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead upgrade 2>&1)"
assert_rc "upgrade succeeds" "$?" "0"
assert_eq "upgrade maintains current -> pithead-v9.9.9" "$(readlink "$SANDBOX/boxroot/current")" "pithead-v9.9.9"
assert_eq "upgrade leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Scattered custom dirs (no single parent): the classic in-install ./data default stands.
seed_L
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
    "$WALLET" "$SHARED" >"$L/config.json"
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with scattered data dirs succeeds" "$?" "0"
assert_eq "no shared root -> dashboard default stays ./data/dashboard" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$L/data/dashboard"

echo "== control channel: Telegram lifecycle verbs (#338) =="
# The #33 runner dispatches the two bounded Telegram control verbs to FIXED pithead commands and
# audits them; an unknown verb is rejected and no host command runs. PITHEAD_SELF points the runner
# at a stub that only records the literal verb it was handed, so nothing real is applied/restarted.
CC="$SANDBOX/ctrl338"
mkdir -p "$CC/staged" "$CC/results" "$CC/audit"
cat >"$CC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SELF_LOG"
exit 0
EOF
chmod +x "$CC/self"
export SELF_LOG="$CC/self.log"
export PITHEAD_SELF="$CC/self"
uid_r="11111111-1111-4111-8111-111111111111"
uid_a="22222222-2222-4222-8222-222222222222"
uid_x="33333333-3333-4333-8333-333333333333"

: >"$SELF_LOG"
printf '{"id":"%s","action":"restart","actor":"tg-7"}\n' "$uid_r" >"$CC/req_r.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_r.json" "$CC" >/dev/null 2>&1
assert_eq "restart intent runs the fixed 'restart' verb" "$(cat "$SELF_LOG")" "restart"
assert_eq "restart result is applied" "$(jq -r .status "$CC/results/$uid_r.json")" "applied"
assert_contains "restart is audited with the actor + action" \
    "$(cat "$CC/audit/control.log")" '"actor":"tg-7","action":"restart","status":"applied"'

: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tg-7"}\n' "$uid_a" >"$CC/req_a.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "apply intent runs the fixed 'apply -y' verb (config re-apply, no edit)" "$(cat "$SELF_LOG")" "apply -y"
assert_eq "apply result is applied" "$(jq -r .status "$CC/results/$uid_a.json")" "applied"

: >"$SELF_LOG"
printf '{"id":"%s","action":"frobnicate","actor":"tg-7"}\n' "$uid_x" >"$CC/req_x.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_x.json" "$CC" >/dev/null 2>&1
assert_eq "unknown verb rejected (bounded action set)" "$(jq -r .error "$CC/results/$uid_x.json")" "unknown action"
assert_eq "unknown verb never runs a host command" "$(cat "$SELF_LOG")" ""
unset PITHEAD_SELF SELF_LOG

# ---------------------------------------------------------------------------
echo "== control channel: worker config apply fails closed (#185) =="
# control_worker_apply resolves the rig's host/token from the HOST's config.json (never the intent)
# and refuses — before dialing any rig — a bad worker name, a non-writable key, an empty change, or a
# worker missing a host or token. These are the fail-closed guards a compromised container hits.
WA="$SANDBOX/ctrl185"
mkdir -p "$WA/staged" "$WA/results" "$WA/audit"
# config.json: rig1 fully addressable (host+token), rig2 has a host but no token (bearer-mandatory).
cat >"$WA/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wa_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WA/req.json"
    PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WA/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
u1="aaaaaaaa-1111-4111-8111-111111111111"
u2="bbbbbbbb-2222-4222-8222-222222222222"
u3="cccccccc-3333-4333-8333-333333333333"
u4="dddddddd-4444-4444-8444-444444444444"
u5="eeeeeeee-5555-4555-8555-555555555555"
wa_case "$u1" "{\"id\":\"$u1\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"\",\"changes\":{\"DONATION\":2}}" "empty worker name rejected" "worker"
wa_case "$u2" "{\"id\":\"$u2\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{\"ACCESS_TOKEN\":\"x\"}}" "non-writable key rejected" "not writable"
wa_case "$u3" "{\"id\":\"$u3\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{}}" "empty changes rejected" "non-empty"
wa_case "$u4" "{\"id\":\"$u4\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"ghost\",\"changes\":{\"DONATION\":2}}" "unknown/hostless worker rejected" "no configured host"
wa_case "$u5" "{\"id\":\"$u5\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig2\",\"changes\":{\"DONATION\":2}}" "worker without a token rejected (bearer-mandatory)" "no token"
# The intent's own host/port/token are IGNORED — resolution is from config.json only (#122). A tampered
# intent naming rig2 (no token) with an injected token still fails closed.
u6="ffffffff-6666-4666-8666-666666666666"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig2","changes":{"DONATION":2}}\n' "$u6" >"$WA/req.json"
PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_eq "worker-apply reject is audited by name only" \
    "$(jq -r '.status' "$WA/results/$u6.json")" "rejected"
assert_contains "worker-apply audit records the action, no token" \
    "$(cat "$WA/audit/control.log")" '"action":"worker-apply","status":"rejected"'
if grep -q 'tok-rig1' "$WA/audit/control.log" "$WA"/results/*.json 2>/dev/null; then
    bad "worker-apply never leaks a token to results/audit" "token found"
else
    ok "worker-apply never leaks a token to results/audit"
fi
# Per-drain dial budget (#185 hardening): with the budget exhausted, a fully-valid apply (rig1 has a
# host + token) is refused BEFORE any rig dial, so a flood can't starve the root runner.
u7="99999999-7777-4777-8777-777777777777"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u7" >"$WA/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_contains "worker-apply over the dial budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WA/results/$u7.json")" "too many worker config changes"

# workers.list[] (#506): control_worker_apply resolves the rig's host/token the same way from the
# CURRENT shape. Reuses the budget=0 technique above — a "too many worker config changes" rejection
# (instead of "no configured host"/"no token") proves resolution succeeded BEFORE the pre-dial
# budget gate, without needing to stub the actual network dial.
WA2="$SANDBOX/ctrl506"
mkdir -p "$WA2/staged" "$WA2/results" "$WA2/audit"
cat >"$WA2/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
u8="88888888-9999-4999-8999-888888888888"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u8" >"$WA2/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA2/config.json" run_sourced "$SANDBOX" control_process_request "$WA2/req.json" "$WA2" >/dev/null 2>&1
assert_contains "workers.list worker-apply resolves the rig (budget rejection proves pre-dial success)" \
    "$(jq -r '.error // ""' "$WA2/results/$u8.json")" "too many worker config changes"

echo "== control channel: worker config apply ACCEPT path succeeds + is audited (#185) =="
# Mirrors the reject-path setup above, but with a stub curl standing in for the rig's control API so a
# fully-valid worker-apply actually dials, gets accepted (202 + change_id), and polls the rig's
# /status to a terminal "applied" — proving the success leg of #185, not just the fail-closed guards
# exercised above it.
WA3="$SANDBOX/ctrl185-accept"
mkdir -p "$WA3/staged" "$WA3/results" "$WA3/audit" "$WA3/bin"
cat >"$WA3/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
# A minimal curl stand-in: no real network dial. Reads its own args for `-o <file>` and the trailing
# URL (curl always puts flags/headers/data before the bare URL, so the last plain token IS the URL);
# serves a canned 202 body for POST .../apply and a terminal "applied" 200 body for GET .../status —
# mirroring what a real RigForge rig's control API returns (rigforge#236's status shape).
cat >"$WA3/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-1"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-1","status":"applied","changed_keys":["pools"]}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA3/bin/curl"
u9="12121212-1212-4212-8212-121212121212"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u9" >"$WA3/req.json"
PATH="$WA3/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA3/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA3/req.json" "$WA3" >/dev/null 2>&1
assert_eq "worker-apply accept path reaches a terminal 'applied' status" \
    "$(jq -r '.status' "$WA3/results/$u9.json" 2>/dev/null)" "applied"
assert_eq "worker-apply accept path records the rig's change_id" \
    "$(jq -r '.change_id' "$WA3/results/$u9.json" 2>/dev/null)" "chg-1"
assert_eq "worker-apply accept path records the rig's changed_keys" \
    "$(jq -rc '.changed_keys' "$WA3/results/$u9.json" 2>/dev/null)" '["pools"]'
assert_contains "worker-apply accept is audited as applied" \
    "$(cat "$WA3/audit/control.log")" '"action":"worker-apply","status":"applied"'
# The rig can also end an apply terminal "failed" — it could not restore its own rollback backup
# (present since the v1.11.2 fleet floor). The poll must land it as failed-with-reason, never burn
# the 20s deadline into a vague "accepted".
WA4="$SANDBOX/ctrl185-failed"
mkdir -p "$WA4/staged" "$WA4/results" "$WA4/audit" "$WA4/bin"
cp "$WA3/config.json" "$WA4/config.json"
cat >"$WA4/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-2"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-2","status":"failed","reason":"rollback backup unreadable: /var/lib/rigforge/backup"}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA4/bin/curl"
u10="fafafafa-fafa-4afa-8afa-fafafafafafa"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u10" >"$WA4/req.json"
PATH="$WA4/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA4/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA4/req.json" "$WA4" >/dev/null 2>&1
assert_eq "a failed apply reaches terminal 'failed', not the poll-deadline 'accepted'" \
    "$(jq -r '.status' "$WA4/results/$u10.json" 2>/dev/null)" "failed"
assert_contains "the failed apply carries the rig's reason" \
    "$(jq -r '.reason' "$WA4/results/$u10.json" 2>/dev/null)" "rollback backup unreadable"
assert_contains "the failed apply is audited as failed" \
    "$(cat "$WA4/audit/control.log")" '"action":"worker-apply","status":"failed"'

# ---------------------------------------------------------------------------
echo "== control channel: worker upgrade fails closed (#597) =="
# control_worker_upgrade fuses the worker-apply template (rig resolved from the HOST config, never
# the intent) with the stack-upgrade template (host-side target re-derivation, throttled). These are
# the pre-dial fail-closed guards.
WU="$SANDBOX/ctrl597"
mkdir -p "$WU/staged" "$WU/results" "$WU/audit"
cat >"$WU/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wu_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WU/req.json"
    PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WU/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
w1="aaaaaaaa-1111-4111-9111-111111111111"
w2="bbbbbbbb-2222-4222-9222-222222222222"
w3="cccccccc-3333-4333-9333-333333333333"
w4="dddddddd-4444-4444-9444-444444444444"
w5="eeeeeeee-5555-4555-9555-555555555555"
wu_case "$w1" "{\"id\":\"$w1\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"\",\"version\":\"v1.11.2\"}" "upgrade: empty worker name rejected" "worker"
wu_case "$w2" "{\"id\":\"$w2\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig1\",\"version\":\"1.11.2\"}" "upgrade: bare (non-tag) version rejected" "version"
wu_case "$w3" "{\"id\":\"$w3\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"ghost\",\"version\":\"v1.11.2\"}" "upgrade: unknown/hostless worker rejected" "no configured host"
wu_case "$w4" "{\"id\":\"$w4\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig2\",\"version\":\"v1.11.2\"}" "upgrade: worker without a token rejected (bearer-mandatory)" "no token"
# Per-drain budget: exactly one upgrade dials per drain; over-budget rejects BEFORE the tag lookup
# (a "already in this cycle" rejection also proves rig resolution succeeded pre-dial).
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w5" >"$WU/req.json"
CONTROL_WU_BUDGET=0 PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
assert_contains "upgrade over the per-drain budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WU/results/$w5.json")" "already in this cycle"
if grep -q 'tok-rig1' "$WU/audit/control.log" "$WU"/results/*.json 2>/dev/null; then
    bad "worker-upgrade never leaks a token to results/audit" "token found"
else
    ok "worker-upgrade never leaks a token to results/audit"
fi
# Anti-beacon throttle (#597, control_upgrade's lesson): a fresh lookup stamp with no cached tag
# means a recent derive attempt failed — refuse WITHOUT another GitHub/Tor dial. The curl stub
# records every invocation; it must stay unused.
WUT="$SANDBOX/ctrl597-throttle"
mkdir -p "$WUT/staged" "$WUT/results" "$WUT/audit" "$WUT/bin"
cp "$WU/config.json" "$WUT/config.json"
cat >"$WUT/bin/curl" <<EOF
#!/usr/bin/env bash
echo "dialed \$*" >>"$WUT/dials.log"
exit 7
EOF
chmod +x "$WUT/bin/curl"
touch "$WUT/staged/.rigforge-latest-stamp"
w6="ffffffff-6666-4666-9666-666666666666"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w6" >"$WUT/req.json"
PATH="$WUT/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$WUT/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WUT/req.json" "$WUT" >/dev/null 2>&1
assert_contains "upgrade inside the 10-min lookup window (no cached tag) is rejected" \
    "$(jq -r '.error // ""' "$WUT/results/$w6.json")" "retry in a few minutes"
assert_eq "the throttled upgrade made NO network dial" "$(cat "$WUT/dials.log" 2>/dev/null)" ""

echo "== control channel: worker upgrade drives the rig to each terminal (#597) =="
# A stub curl stands in for the rig's control API (and would catch any unexpected GitHub dial: the
# tag is pre-cached, so the only allowed URLs are the rig's /upgrade and /status). One sandbox per
# scenario; the stub's /status behaviour is parameterized via WU_STATUS_BODY, and the stale-terminal
# case serves a PREVIOUS change's terminal first to prove change_id matching.
wu_accept_case() { # <uuid> <status-body-json> <label> <expected-status>
    local dir="$SANDBOX/ctrl597-$1"
    mkdir -p "$dir/staged" "$dir/results" "$dir/audit" "$dir/bin"
    cp "$WU/config.json" "$dir/config.json"
    printf '%s' "v9.9.9" >"$dir/staged/.rigforge-latest-tag"
    cat >"$dir/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$dir/dials.log"
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status) printf '%s' '$2' >"\$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/curl"
    printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$1" >"$dir/req.json"
    PATH="$dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$dir/config.json" \
        run_sourced "$SANDBOX" control_process_request "$dir/req.json" "$dir" >/dev/null 2>&1
    assert_eq "$3" "$(jq -r '.status' "$dir/results/$1.json" 2>/dev/null)" "$4"
    WU_LAST_DIR="$dir"
}
w7="12121212-1212-4212-9212-121212121212"
wu_accept_case "$w7" '{"change_id":"chg-9","status":"applied"}' \
    "upgrade accept path reaches a terminal 'applied'" "applied"
assert_eq "applied result records the rig's change_id" \
    "$(jq -r '.change_id' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "chg-9"
assert_eq "applied result records the host-derived version" \
    "$(jq -r '.version' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "v9.9.9"
# #690: every runner dial (the rig POST + each /status poll) carries a response-size cap so a
# hostile rig can't stream an unbounded body into disk/memory. Proves the flag is wired, not curl's
# own enforcement (that needs a real curl against an oversized server — an e2e concern).
assert_contains "worker-upgrade rig dials carry a --max-filesize cap (#690)" \
    "$(cat "$WU_LAST_DIR/dials.log" 2>/dev/null)" "--max-filesize"
assert_contains "upgrade applied is audited" \
    "$(cat "$WU_LAST_DIR/audit/control.log")" '"action":"worker-upgrade","status":"applied"'
w8="23232323-2323-4232-9232-232323232323"
wu_accept_case "$w8" '{"change_id":"chg-9","status":"rolled_back","reason":"miner did not return live"}' \
    "upgrade rollback surfaces as rolled_back" "rolled_back"
assert_eq "rolled_back result carries the rig's reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w8.json" 2>/dev/null)" "miner did not return live"
w9="34343434-3434-4234-9234-343434343434"
wu_accept_case "$w9" '{"change_id":"chg-9","status":"failed","reason":"throttled: retry after the window"}' \
    "legacy rig (pre-v1.12.0) throttle refusal (failed+text) still maps to retry-later" "throttled"
# First-class terminals since rigforge#320 (v1.12.0): noop (already on the target) and throttled
# land their real status on the first poll — neither burns the poll cap into a vague "accepted".
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
wu_accept_case "$w17" '{"change_id":"chg-9","status":"noop","reason":"already on v9.9.9 — nothing to upgrade"}' \
    "a rig already on the target lands first-class 'noop', not the poll-cap fallback" "noop"
assert_contains "the noop result carries the rig's already-on-target reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w17.json" 2>/dev/null)" "already on v9.9.9"
w18="cdcdcdcd-cdcd-42cd-92cd-cdcdcdcdcdcd"
wu_accept_case "$w18" '{"change_id":"chg-9","status":"throttled","reason":"throttled — too soon since the last upgrade attempt"}' \
    "a first-class 'throttled' terminal lands as retry-later on the first poll" "throttled"
# A genuine failure that merely MENTIONS the throttle must stay a fault (rigforge#321's
# fail-closed refusal): only the legacy leading-"throttled" free text remaps to retry-later.
w19="dededede-dede-42de-92de-dededededede"
wu_accept_case "$w19" '{"change_id":"chg-9","status":"failed","reason":"throttle state unavailable under /var/lib/rigforge — refused (fail-closed)"}' \
    "a broken-rig failure mentioning the throttle stays 'failed', never calmed" "failed"
# An unreachable rig fails cleanly (nothing changed, rig keeps its version).
unreach_dir="$SANDBOX/ctrl597-unreach"
mkdir -p "$unreach_dir/staged" "$unreach_dir/results" "$unreach_dir/audit" "$unreach_dir/bin"
cp "$WU/config.json" "$unreach_dir/config.json"
printf '%s' "v9.9.9" >"$unreach_dir/staged/.rigforge-latest-tag"
printf '#!/usr/bin/env bash\nexit 7\n' >"$unreach_dir/bin/curl"
chmod +x "$unreach_dir/bin/curl"
w12="67676767-6767-4267-9267-676767676767"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w12" >"$unreach_dir/req.json"
PATH="$unreach_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$unreach_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$unreach_dir/req.json" "$unreach_dir" >/dev/null 2>&1
assert_contains "an unreachable rig fails cleanly (nothing changed)" \
    "$(jq -r '.status + "|" + (.error // "")' "$unreach_dir/results/$w12.json")" "failed|could not reach worker"

# A non-latest proposal is refused against the CACHED tag — before any rig dial.
wa_dir="$SANDBOX/ctrl597-notlatest"
mkdir -p "$wa_dir/staged" "$wa_dir/results" "$wa_dir/audit"
cp "$WU/config.json" "$wa_dir/config.json"
printf '%s' "v9.9.9" >"$wa_dir/staged/.rigforge-latest-tag"
w10="45454545-4545-4245-9245-454545454545"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.0.0"}\n' "$w10" >"$wa_dir/req.json"
CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$wa_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$wa_dir/req.json" "$wa_dir" >/dev/null 2>&1
assert_contains "a non-latest proposal is refused against the host-derived tag" \
    "$(jq -r '.error // ""' "$wa_dir/results/$w10.json")" "not the latest published RigForge release"
# Stale-terminal guard: the rig's /status first shows a PREVIOUS change's applied (no in-progress
# state, rigforge#320) — it must be ignored until OUR change_id appears.
stale_dir="$SANDBOX/ctrl597-stale"
mkdir -p "$stale_dir/staged" "$stale_dir/results" "$stale_dir/audit" "$stale_dir/bin"
cp "$WU/config.json" "$stale_dir/config.json"
printf '%s' "v9.9.9" >"$stale_dir/staged/.rigforge-latest-tag"
cat >"$stale_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status)
    if [ -f "$stale_dir/.polled" ]; then
        printf '{"change_id":"chg-9","status":"applied"}' >"\$out"
    else
        touch "$stale_dir/.polled"
        printf '{"change_id":"chg-OLD","status":"applied"}' >"\$out"
    fi
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$stale_dir/bin/curl"
w11="56565656-5656-4256-9256-565656565656"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w11" >"$stale_dir/req.json"
PATH="$stale_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$stale_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$stale_dir/req.json" "$stale_dir" >/dev/null 2>&1
assert_eq "a stale terminal for a PREVIOUS change_id is ignored; ours lands" \
    "$(jq -r '.status + "|" + .change_id' "$stale_dir/results/$w11.json" 2>/dev/null)" "applied|chg-9"
# Poll-cap timeout (the sec-review headline fix): the cap bounds a hostile/hung rig's hold on the
# single-threaded root drain, and hitting it must land "accepted" (queued on the rig; the #596
# badge clears on its own), never a failure. CONTROL_WU_POLL_CAP shrinks the 90s cap so this
# proves the fallback in seconds — the rig accepts (202) but its /status only ever shows a
# PREVIOUS change's terminal, so no terminal for OUR change_id arrives inside the cap.
to_dir="$SANDBOX/ctrl597-timeout"
mkdir -p "$to_dir/staged" "$to_dir/results" "$to_dir/audit" "$to_dir/bin"
cp "$WU/config.json" "$to_dir/config.json"
printf '%s' "v9.9.9" >"$to_dir/staged/.rigforge-latest-tag"
cat >"$to_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-OLD","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$to_dir/bin/curl"
w13="78787878-7878-4278-9278-787878787878"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w13" >"$to_dir/req.json"
PATH="$to_dir/bin:$PATH" CONTROL_WU_BUDGET=1 CONTROL_WU_POLL_CAP=1 PITHEAD_CONFIG_FILE="$to_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$to_dir/req.json" "$to_dir" >/dev/null 2>&1
assert_eq "hitting the poll cap lands 'accepted' (queued on the rig), not a failure" \
    "$(jq -r '.status + "|" + .change_id' "$to_dir/results/$w13.json" 2>/dev/null)" "accepted|chg-9"
assert_contains "the timed-out result says the upgrade is still running" \
    "$(jq -r '.note // ""' "$to_dir/results/$w13.json" 2>/dev/null)" "still running on the rig"
assert_contains "the poll-cap timeout is audited as accepted" \
    "$(cat "$to_dir/audit/control.log")" '"action":"worker-upgrade","status":"accepted"'

echo "== control channel: worker upgrade derives the target tag from GitHub (#597) =="
# Every accept case above pre-caches .rigforge-latest-tag; these prove the derive itself. The
# GitHub call captures curl's STDOUT (no -o), so the stub answers the release API on stdout and
# keeps the -o/-w shape for the rig's /upgrade + /status.
gh_dir="$SANDBOX/ctrl597-derive"
mkdir -p "$gh_dir/staged" "$gh_dir/results" "$gh_dir/audit" "$gh_dir/bin"
cp "$WU/config.json" "$gh_dir/config.json"
cat >"$gh_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/releases/latest) printf '{"tag_name":"v9.9.9"}' ;;
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-9","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$gh_dir/bin/curl"
w14="89898989-8989-4289-9289-898989898989"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w14" >"$gh_dir/req.json"
PATH="$gh_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$gh_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$gh_dir/req.json" "$gh_dir" >/dev/null 2>&1
assert_eq "a fresh derive parses tag_name and drives the upgrade to applied" \
    "$(jq -r '.status + "|" + .version' "$gh_dir/results/$w14.json" 2>/dev/null)" "applied|v9.9.9"
assert_eq "the derived tag is cached for the next intent" \
    "$(cat "$gh_dir/staged/.rigforge-latest-tag" 2>/dev/null)" "v9.9.9"
# GitHub unreachable over Tor: refused fail-closed, nothing dialed toward the rig.
ghfail_dir="$SANDBOX/ctrl597-ghdown"
mkdir -p "$ghfail_dir/staged" "$ghfail_dir/results" "$ghfail_dir/audit" "$ghfail_dir/bin"
cp "$WU/config.json" "$ghfail_dir/config.json"
printf '#!/usr/bin/env bash\nexit 7\n' >"$ghfail_dir/bin/curl"
chmod +x "$ghfail_dir/bin/curl"
w15="9a9a9a9a-9a9a-429a-929a-9a9a9a9a9a9a"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w15" >"$ghfail_dir/req.json"
PATH="$ghfail_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghfail_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghfail_dir/req.json" "$ghfail_dir" >/dev/null 2>&1
assert_contains "an unreachable GitHub release API refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghfail_dir/results/$w15.json")" \
    "rejected|could not reach the GitHub release API over Tor"
# GitHub reachable but the response carries no usable tag: refused fail-closed.
ghjunk_dir="$SANDBOX/ctrl597-ghjunk"
mkdir -p "$ghjunk_dir/staged" "$ghjunk_dir/results" "$ghjunk_dir/audit" "$ghjunk_dir/bin"
cp "$WU/config.json" "$ghjunk_dir/config.json"
cat >"$ghjunk_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"message":"Not Found"}'
exit 0
EOF
chmod +x "$ghjunk_dir/bin/curl"
w16="abababab-abab-42ab-92ab-abababababab"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w16" >"$ghjunk_dir/req.json"
PATH="$ghjunk_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghjunk_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghjunk_dir/req.json" "$ghjunk_dir" >/dev/null 2>&1
assert_contains "a release API response with no usable tag refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghjunk_dir/results/$w16.json")" \
    "rejected|the GitHub release API returned no usable RigForge release tag"

# Rig refusal (non-202) — this branch is also where an old rig (< v1.11.2: no /upgrade endpoint,
# or its own version gate) surfaces its refusal. The rig's error text is attacker-influenceable
# (a compromised rig / LAN MITM), so it must be capped at 500 chars before it lands in a result.
refuse_dir="$SANDBOX/ctrl597-refuse"
mkdir -p "$refuse_dir/staged" "$refuse_dir/results" "$refuse_dir/audit" "$refuse_dir/bin"
cp "$WU/config.json" "$refuse_dir/config.json"
printf '%s' "v9.9.9" >"$refuse_dir/staged/.rigforge-latest-tag"
# 500 filler chars then a marker: the cap keeps the filler and must drop the marker.
wu_long_err="$(printf 'A%.0s' $(seq 1 500))OVERFLOW-TAIL"
cat >"$refuse_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"error":"$wu_long_err"}' >"\$out"; printf '403' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$refuse_dir/bin/curl"
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w17" >"$refuse_dir/req.json"
PATH="$refuse_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$refuse_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$refuse_dir/req.json" "$refuse_dir" >/dev/null 2>&1
assert_contains "a rig non-202 (incl. an old-rig < v1.11.2 refusal) is surfaced as rejected" \
    "$(jq -r '.status + "|" + (.error // "")' "$refuse_dir/results/$w17.json")" \
    "rejected|worker 'rig1' refused the upgrade (HTTP 403): AAAA"
assert_not_contains "the rig's error text is truncated at 500 chars" \
    "$(jq -r '.error // ""' "$refuse_dir/results/$w17.json")" "OVERFLOW-TAIL"

# ---------------------------------------------------------------------------
echo "== unit: config.reference.json stays a complete superset of every path pithead reads (#561) =="
# The closed-schema control gate (#537, pithead ~L4706) relies on this invariant: every config.json
# path pithead reads must exist in config.reference.json, or a legitimate config carrying that path
# is false-rejected on every control-channel commit (a control-plane DoS). Until now the only guard
# was the single legacy-xmrig_proxy round-trip case above. This walks pithead's own read sites,
# mirroring the #515 cross-file drift guard's shape (build/dashboard/tests/service/test_control_service.py,
# test_writable_key_allowlist_has_no_intra_repo_drift): a conservative, fixed-shape extractor over
# the literal read sites that FAILS LOUD on a shape it doesn't recognize (rather than silently
# skipping it), so a new read shape can't slip through unchecked.

# Deliberate exceptions: paths this extractor finds that are NOT required to have a reference
# entry. Empty today — every path pithead reads already has one (this test itself verifies that).
# Keep the mechanism here for the day a genuinely internal/env-only read needs one; each entry
# needs a why-comment.
# macOS ships bash 3.2 (no associative arrays / mapfile — matches the rest of this file), so
# extracted paths accumulate as a newline-separated string, deduped with `sort -u` at the end.
declare -a DRIFT_EXCEPTIONS=()

DRIFT_FOUND="" # newline-separated normalized dotted paths (no leading dot), deduped at the end
DRIFT_BAD=0

drift_add_path() { # <.dotted.path> (leading dot optional)
    local p="${1#.}"
    [ -n "$p" ] && DRIFT_FOUND="$DRIFT_FOUND
$p"
}

# Split a jq `//`-alternative chain into its parts and record each leading-dot part as a read
# path. A part that isn't a path must be one of the literal default shapes this codebase uses
# (empty/true/false/[]/{}, a quoted string, or a number) — anything else fails the whole test
# loudly, naming the culprit, so a new default shape gets a deliberate look instead of a silent
# pass-through.
drift_classify_chain() { # <chain> <line-label>
    local chain="$1" line="$2" part
    while [ -n "$chain" ]; do
        if [[ "$chain" == *" // "* ]]; then
            part="${chain%% // *}"
            chain="${chain#* // }"
        else
            part="$chain"
            chain=""
        fi
        if [[ "$part" == .* ]]; then
            if [[ "$part" =~ ^\.[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
                drift_add_path "$part"
            else
                bad "config-read extractor (#561)" "unrecognized path shape '$part' in $line — extend the extractor"
                DRIFT_BAD=1
            fi
        elif [ "$part" = "empty" ] || [ "$part" = "true" ] || [ "$part" = "false" ] || [ "$part" = "[]" ] || [ "$part" = "{}" ]; then
            : # known default literal, not a path
        elif [[ "$part" =~ ^\"[^\"]*\"$ ]] || [[ "$part" =~ ^-?[0-9]+$ ]]; then
            : # quoted-string or numeric default
        else
            bad "config-read extractor (#561)" "unrecognized default shape '$part' in $line — extend the extractor"
            DRIFT_BAD=1
        fi
    done
}

# config_bool '<path>' <default> call sites (pithead's null-aware boolean reader) — the path arg
# is always a plain single-quoted leading-dot literal.
while IFS= read -r p; do
    drift_add_path "$p"
done < <(grep -oE "config_bool '\.[A-Za-z0-9_.]+'" "$STACK" | sed -E "s/^config_bool '(.*)'\$/\1/")

# Single-line jq reads against $CONFIG_FILE. Filtered down to genuine simple `config_get`-style
# reads: this excludes multi-line validator blocks (an unterminated quote leaves an odd '-count on
# its opening/closing line), writes (`= $var`), and the closed-schema gate's own whole-block
# --slurpfile comparisons (those compare already-covered blocks wholesale, not a new leaf path).
while IFS=: read -r lineno text; do
    [[ "$text" == *'--slurpfile'* ]] && continue
    [[ "$text" == *' = $'* ]] && continue
    [[ "$text" == *'jq'* ]] || continue
    qcount=$(grep -o "'" <<<"$text" | wc -l)
    [ "$qcount" -eq 2 ] || continue
    filter="${text#*\'}"
    filter="${filter%\'*}"
    # In scope only if the filter is itself a path read: a bare path, a parenthesized
    # `(path // default)` prefix, or an `if path <op> ...` boolean read. Anything else (`.`,
    # `any(..|strings;...)`, an array-literal walk like `[(.path // [])[] | .name] | group_by(.)`)
    # is a structural check or a nested-element walk, not a new top-level path — out of scope.
    if [[ "$filter" == .* ]]; then
        drift_classify_chain "$filter" "pithead:$lineno"
    elif [[ "$filter" == \(* ]]; then
        # Only the parenthesized `(path // default)` prefix is attributed; whatever follows the
        # closing paren (e.g. `[] | select(.name == $n) | .host // ""`) is relative to an
        # iterated element, not a new root path — deliberately not walked further.
        inner="${filter#\(}"
        inner="${inner%%\)*}"
        drift_classify_chain "$inner" "pithead:$lineno"
    elif [[ "$filter" == "if "* ]]; then
        while IFS= read -r tok; do
            [ -n "$tok" ] && drift_add_path "$tok"
        done < <(grep -oE '\.[A-Za-z_][A-Za-z0-9_.]*(\[[^]]*\])?[[:space:]]+(!=|==)' <<<"$filter" |
            sed -E 's/(\[[^]]*\])?[[:space:]]+(!=|==)$//')
    fi
done < <(grep -n '"\$CONFIG_FILE"' "$STACK")

REF_PATHS="$(jq -r '[paths | map(select(type=="string")) | join(".")] | unique[]' "$ROOT/config.reference.json")"
DRIFT_FOUND="$(sort -u <<<"$DRIFT_FOUND")"

checked=0
missing=0
for p in $DRIFT_FOUND; do
    checked=$((checked + 1))
    grep -qxF "$p" <<<"$REF_PATHS" && continue
    allowed=0
    for a in "${DRIFT_EXCEPTIONS[@]:-}"; do
        [ "$a" = "$p" ] && allowed=1 && break
    done
    [ "$allowed" -eq 1 ] && continue
    bad "config path pithead reads has a config.reference.json entry" "'$p' is missing from config.reference.json"
    missing=$((missing + 1))
done
if [ "$checked" -eq 0 ]; then
    bad "the extractor found at least one config-read path" "found zero — extend the extractor"
elif [ "$missing" -eq 0 ] && [ "$DRIFT_BAD" -eq 0 ]; then
    ok "every extracted config-read path ($checked total) exists in config.reference.json"
fi
unset DRIFT_FOUND REF_PATHS DRIFT_BAD

echo "== unit: config.core-keys.json — valid JSON, stays inside config.reference.json (#502/#529) =="
# The core-key shortlist (#529's binding Wave-0 decision) is the ONE shared artifact between the
# wizard (here) and the dashboard form (later, #529's regroup). Every path it lists must resolve
# somewhere in config.reference.json, or the wizard could start asking about a key the closed
# schema (#537/#561) would then refuse — a config the wizard itself just generated getting
# rejected on the very first apply.
CORE_KEYS="$(jq -r '.[]' "$ROOT/config.core-keys.json" 2>/dev/null)"
if [ -z "$CORE_KEYS" ]; then
    bad "config.core-keys.json parses to a non-empty array" "got nothing — check the file exists and is valid JSON"
else
    ok "config.core-keys.json parses to a non-empty array"
fi
REF_PATHS_CORE="$(jq -r '[paths | map(select(type=="string")) | join(".")] | unique[]' "$ROOT/config.reference.json")"
core_checked=0
core_missing=0
for p in $CORE_KEYS; do
    core_checked=$((core_checked + 1))
    grep -qxF "$p" <<<"$REF_PATHS_CORE" || {
        bad "core key has a config.reference.json entry" "'$p' is missing from config.reference.json"
        core_missing=$((core_missing + 1))
    }
done
if [ "$core_checked" -gt 0 ] && [ "$core_missing" -eq 0 ]; then
    ok "every config.core-keys.json path ($core_checked total) exists in config.reference.json"
fi
unset REF_PATHS_CORE CORE_KEYS core_checked core_missing

echo "== unit: wizard prompt count is pinned (#502 — a silently-added prompt fails this loud) =="
# Structural, not behavioral: every Enter-through default answer looks the same ("blank"), so a
# NEW prompt slipped into either function wouldn't visibly break a happy-path run — it would just
# eat one more blank line unnoticed. Pinning the count is what actually catches wizard scope creep.
core_reads=$(awk '/^wizard_ask_core\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
shape_reads=$(awk '/^wizard_ask_shape\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
assert_eq "wizard_ask_core has exactly 12 read prompts (wallets, node config, pool tier, dashboard login)" "$core_reads" "12"
assert_eq "wizard_ask_shape has exactly 6 read prompts (clearnet-sync, remote-access, alerts cluster, local-miner opt-in)" "$shape_reads" "6"

# A small helper so tests can drive the whole Q&A -> write in one sourced call, sharing the globals
# wizard_ask_core/wizard_ask_shape set with wizard_write_config (each function's locals don't
# survive a return, so they must run in the same invocation).
run_wizard() {
    wizard_ask_core
    wizard_ask_shape
    wizard_write_config
}

echo "== unit: wizard — Enter-through defaults skip everything but the core answers (#502) =="
# Local node, every optional prompt left blank. Proves two things at once: the core answers land
# (wallets, mode, pool tier), and nothing else does — dashboard.hashrate_drop_threshold,
# network.subnet, xvb.*, telegram.*, dashboard.onion, dashboard.auth all keep their
# config.reference.json default because the wizard never wrote them at all.
W1="$SANDBOX/wizard-defaults"
mkdir -p "$W1"
printf '%s\n%s\n\n\n\n\n\n\n\n\n' "$WALLET" "TARIWALLETDEFAULT" | run_sourced "$W1" run_wizard >/dev/null 2>&1
if [ -f "$W1/config.json" ]; then
    ok "wizard (defaults path) writes config.json"
else
    bad "wizard (defaults path) writes config.json" "no file at $W1/config.json"
fi
w1_cfg="$(cat "$W1/config.json" 2>/dev/null)"
assert_eq "defaults path: monero.wallet_address" "$(jq -r '.monero.wallet_address' <<<"$w1_cfg")" "$WALLET"
assert_eq "defaults path: tari.wallet_address" "$(jq -r '.tari.wallet_address' <<<"$w1_cfg")" "TARIWALLETDEFAULT"
assert_eq "defaults path: monero.mode local (Enter-through)" "$(jq -r '.monero.mode' <<<"$w1_cfg")" "local"
assert_eq "defaults path: p2pool.pool Enter-through is mini (the global default)" "$(jq -r '.p2pool.pool' <<<"$w1_cfg")" "mini"
assert_eq "defaults path: local node RPC creds auto-generated (non-empty)" \
    "$([ -n "$(jq -r '.monero.node_username' <<<"$w1_cfg")" ] && [ -n "$(jq -r '.monero.node_password' <<<"$w1_cfg")" ] && echo yes)" "yes"
# The revert-proof core: config.json carries ONLY the four top-level blocks the defaults path
# writes. If a future prompt silently starts writing e.g. dashboard.hashrate_drop_threshold or
# network.subnet, this fails — a defaulted key growing a prompt shows up here even though its own
# (blank) answer looks identical to every other blank answer.
assert_eq "defaults path: top-level keys are exactly monero/tari/p2pool/dashboard, nothing else" \
    "$(jq -rc '[keys[]] | sort' <<<"$w1_cfg")" '["dashboard","monero","p2pool","tari"]'
assert_eq "defaults path: dashboard has only 'secure' — no auth/onion written" \
    "$(jq -rc '.dashboard | keys' <<<"$w1_cfg")" '["secure"]'
assert_eq "defaults path: no telegram block written" "$(jq -r 'has("telegram")' <<<"$w1_cfg")" "false"
assert_eq "defaults path: no clearnet_initial_sync written (stays the reference default)" \
    "$(jq -r '.monero | has("clearnet_initial_sync")' <<<"$w1_cfg")" "false"
assert_eq "defaults path: no local_miner block written (opt-in off, #593)" \
    "$(jq -r 'has("local_miner")' <<<"$w1_cfg")" "false"

# Opt-in to the local miner (#593): answering 'y' to the final shape prompt writes
# local_miner.enabled=true; every other answer left blank so only that key appears.
WLM="$SANDBOX/wizard-local-miner"
mkdir -p "$WLM"
printf '%s\n%s\n\n\n\n\n\n\n\ny\n' "$WALLET" "TARIWALLETLM" | run_sourced "$WLM" run_wizard >/dev/null 2>&1
wlm_cfg="$(cat "$WLM/config.json" 2>/dev/null)"
assert_eq "opt-in path: local_miner.enabled written true (#593)" "$(jq -r '.local_miner.enabled' <<<"$wlm_cfg")" "true"
unset wlm_cfg

echo "== unit: wizard — remote node branch is unchanged by the ask/write split (#502) =="
# The remote-node prompts (host/RPC/ZMQ/auth) were only moved into wizard_ask_core, not touched —
# this catches the refactor breaking the variable handoff to wizard_write_config.
W3="$SANDBOX/wizard-remote"
mkdir -p "$W3"
printf '%s\n%s\nn\nnode.example.com\n\n\ny\nremoteuser\nremotepass\n\n\n\n\n\n\n' \
    "$WALLET" "TARIWALLETREMOTE" | run_sourced "$W3" run_wizard >/dev/null 2>&1
w3_cfg="$(cat "$W3/config.json" 2>/dev/null)"
assert_eq "remote path: monero.mode remote" "$(jq -r '.monero.mode' <<<"$w3_cfg")" "remote"
assert_eq "remote path: remote host set" "$(jq -r '.monero.remote.host' <<<"$w3_cfg")" "node.example.com"
assert_eq "remote path: RPC/ZMQ ports default 18081/18083" \
    "$(jq -rc '[.monero.remote.rpc_port, .monero.remote.zmq_port]' <<<"$w3_cfg")" "[18081,18083]"
assert_eq "remote path: auth creds carried through" \
    "$(jq -rc '[.monero.node_username, .monero.node_password]' <<<"$w3_cfg")" '["remoteuser","remotepass"]'
unset w3_cfg

echo "== unit: wizard — remote node WITHOUT auth + an explicit nano pool tier (#502) =="
# Two case arms neither W1 (defaults -> mini) nor W2/W3 (main / auth'd remote) reach: REMOTE_AUTH
# answered "n" (the un-auth'd remote branch skips both credential prompts, leaving them "") and
# the pool-tier case's "nano" arm. Same run_wizard helper, non-default answers on both axes.
W4="$SANDBOX/wizard-remote-noauth-nano"
mkdir -p "$W4"
printf '%s\n%s\nn\nremote2.example.com\n\n\nn\nnano\n\n\n\n\n\n' \
    "$WALLET" "TARIWALLETNOAUTH" | run_sourced "$W4" run_wizard >/dev/null 2>&1
w4_cfg="$(cat "$W4/config.json" 2>/dev/null)"
assert_eq "remote-noauth path: monero.mode remote" "$(jq -r '.monero.mode' <<<"$w4_cfg")" "remote"
assert_eq "remote-noauth path: remote host set" "$(jq -r '.monero.remote.host' <<<"$w4_cfg")" "remote2.example.com"
assert_eq "remote-noauth path: declining auth leaves creds empty, not auto-generated" \
    "$(jq -rc '[.monero.node_username, .monero.node_password]' <<<"$w4_cfg")" '["",""]'
assert_eq "remote-noauth path: pool tier nano" "$(jq -r '.p2pool.pool' <<<"$w4_cfg")" "nano"
unset w4_cfg

echo "== unit: wizard — shape-question and dashboard-login answers flow into config.json (#502) =="
# The inverse of the defaults test: every optional prompt answered, proving the new logic (pool
# tier mapping, the dashboard-login cluster, and each Stage-2 cluster) actually wires through.
W2="$SANDBOX/wizard-full"
mkdir -p "$W2"
printf '%s\n%s\n\nmain\nopuser\nsuperSecret1\ny\ny\ny\nmybottoken123\n987654321\n' \
    "$WALLET" "TARIWALLETFULL" | run_sourced "$W2" run_wizard >/dev/null 2>&1
w2_cfg="$(cat "$W2/config.json" 2>/dev/null)"
assert_eq "full path: monero.mode local (Enter-through)" "$(jq -r '.monero.mode' <<<"$w2_cfg")" "local"
assert_eq "full path: p2pool.pool honors an explicit main" "$(jq -r '.p2pool.pool' <<<"$w2_cfg")" "main"
assert_eq "full path: stratum auth defaults on for new installs (#208)" "$(jq -r '.p2pool.stratum_password' <<<"$w2_cfg")" "auto"
# The other new-install path — `cp config.minimal.json config.json` (the bundle quick-start,
# which bypasses the wizard) — must carry the same default, or only wizard users get auth.
assert_eq "config.minimal.json ships stratum auth on (#208)" "$(jq -r '.p2pool.stratum_password' "$ROOT/config.minimal.json")" "auto"
assert_eq "full path: dashboard.auth.username set" "$(jq -r '.dashboard.auth.username' <<<"$w2_cfg")" "opuser"
assert_eq "full path: dashboard.auth.password set" "$(jq -r '.dashboard.auth.password' <<<"$w2_cfg")" "superSecret1"
assert_eq "full path: clearnet-sync cluster sets BOTH chains together" \
    "$(jq -rc '[.monero.clearnet_initial_sync, .tari.clearnet_initial_sync]' <<<"$w2_cfg")" '[true,true]'
assert_eq "full path: remote-access sets dashboard.onion.enabled" "$(jq -r '.dashboard.onion.enabled' <<<"$w2_cfg")" "true"
assert_eq "full path: telegram cluster sets enabled+token+chat_id together" \
    "$(jq -rc '[.telegram.enabled, .telegram.bot_token, .telegram.chat_id]' <<<"$w2_cfg")" '[true,"mybottoken123","987654321"]'

echo "== unit: wizard_print_pointer — closing pointer names what it deliberately didn't ask (#502) =="
pointer_out="$(run_sourced "$SANDBOX" wizard_print_pointer 2>&1)"
assert_contains "pointer mentions monero.view_key (on-chain payout confirmation)" "$pointer_out" "monero.view_key"
assert_contains "pointer mentions dashboard.energy.cost_per_kwh (#504)" "$pointer_out" "dashboard.energy.cost_per_kwh"
assert_contains "pointer mentions workers.list (per-worker overrides, #506)" "$pointer_out" "workers.list"
assert_contains "pointer points at docs/configuration.md" "$pointer_out" "docs/configuration.md"
assert_contains "pointer mentions the dashboard's config editor" "$pointer_out" "dashboard's config editor"

echo "== black-box: 'pithead setup' completes end-to-end from a wizard-produced config (#502) =="
# Everything above drives the wizard sub-functions directly (sourced). Nothing drives the actual
# command an operator runs — this is the gap. ensure_config_exists refuses a piped, non-interactive
# run OUTRIGHT when config.json is missing ([ ! -t 0 ] -> error, pithead ~L2118) — that gate is
# deliberate (don't silently generate a config from a script with no human reading the prompts), and
# it's exactly why the wizard functions were split out for testing (the comment above
# ensure_config_exists says so) rather than something to fake a tty around here. So: produce
# config.json the same piped-stdin way the wizard tests above do (proving the Q&A -> config path,
# same as W1), THEN hand it to the real `setup` command, which skips straight past that gate
# ([-f "$CONFIG_FILE"] short-circuit) and drives its own two remaining prompts (dashboard hostname,
# "start now?") from stdin like any other `read -r -p`. Same docker/sudo-stubbed sandbox as the apply
# black-box tests above; --skip-deps/--skip-optimize keep it host-safe (no apt/GRUB/sysctl edits);
# declining "start now?" stops short of actually bringing containers up.
SU="$SANDBOX/setup-e2e"
mkdir -p "$SU/build/tari" "$SU/build/dashboard"
: >"$SU/build/dashboard/Dockerfile"
cp "$STACK" "$SU/pithead"
cp "$ROOT/build/tari/config.toml.template" "$SU/build/tari/"
make_stubs "$SU/bin"
printf '%s\n%s\n\n\n\n\n\n\n\n\n' "$WALLET" "TARISETUPWALLET" | run_sourced "$SU" run_wizard >/dev/null 2>&1
if [ -f "$SU/config.json" ]; then ok "setup e2e: wizard stage produces config.json"; else bad "setup e2e: wizard stage produces config.json" "no file at $SU/config.json"; fi
su_out="$(cd "$SU" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SU/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
su_rc=$?
assert_rc "'pithead setup' exits 0 given an existing config.json" "$su_rc" "0"
assert_contains "'pithead setup' reports completion" "$su_out" "Deployment preparation complete"
assert_eq "'pithead setup' writes a completed .env" \
    "$(run_sourced "$SU" env_get_file "$SU/.env" DEPLOYMENT_COMPLETED)" "true"
unset SU su_out su_rc

echo "== black-box: 'pithead setup' with stratum_tls in a hand-written config generates the keypair (#261) =="
# The setup path reaches compose through prepare_directories, never ensure_directories — a
# hand-written config.json with stratum_tls:true at FIRST setup must still get its cert + the
# fingerprint announcement (verifier catch: only the apply path was covered).
SUT="$SANDBOX/setup-tls"
mkdir -p "$SUT/build/tari" "$SUT/build/dashboard"
: >"$SUT/build/dashboard/Dockerfile"
cp "$STACK" "$SUT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$SUT/build/tari/"
make_stubs "$SUT/bin"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false} }\n' "$WALLET" >"$SUT/config.json"
sut_out="$(cd "$SUT" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SUT/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
assert_rc "setup with stratum_tls exits 0" "$?" "0"
[ -f "$SUT/data/proxy-tls/cert.pem" ] && [ -f "$SUT/data/proxy-tls/key.pem" ] &&
    ok "setup generates the TLS keypair (#261)" || bad "setup generates the TLS keypair (#261)" "missing under $SUT/data/proxy-tls"
assert_contains "setup announces the fingerprint for rig pinning" "$sut_out" "Stratum TLS is ON"
unset SUT sut_out

unset run_wizard w1_cfg w2_cfg pointer_out core_reads shape_reads

echo "== unit: provision_control_runner only removes units this checkout owns (#33) =="
# The pithead-control.{path,service} names are box-global, but a release bench holds several
# checkouts at once (live stack + e2e harness + bundle-smoke tmp dirs). A checkout with control
# disabled used to remove whatever units were installed — including the LIVE stack's runner,
# stranding its dashboard control requests (config editor stuck at "Previewing…"). The removal
# branch keys on the service unit's ExecStart: foreign owner → leave alone; own units → remove;
# a dangling path unit with no service file → still reaped.
PCR="$SANDBOX/pcr"
mkdir -p "$PCR/units" "$PCR/bin"
# uname stub: the OS gate reads `uname -s` at source time; report Linux so the branch runs on dev
# Macs too. systemctl stub satisfies the command -v gate.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR/bin/systemctl"
chmod +x "$PCR/bin/uname" "$PCR/bin/systemctl"

pcr_run() { # <owner-dir|-> <run-dir> — seed units owned by owner-dir ('-' = no service file), run the removal branch from run-dir, echo sudo calls
    rm -f "$PCR/units/pithead-control.service" "$PCR/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCR/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=/x/requests/*.json\n' >"$PCR/units/pithead-control.path"
    (
        cd "$2" || exit
        PATH="$PCR/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        sudo() { echo "sudo:$*"; } # record instead of executing; the disable call's output is redirected in-function
        PITHEAD_UNIT_DIR="$PCR/units" DASHBOARD_CONTROL_ENABLED=false provision_control_runner
    )
}

assert_eq "foreign owner -> units left alone (no sudo rm)" "$(pcr_run /srv/code/other-checkout "$PCR")" ""
assert_contains "own units -> removed" "$(pcr_run "$PCR" "$PCR")" \
    "sudo:rm -f $PCR/units/pithead-control.path $PCR/units/pithead-control.service"
assert_contains "dangling path unit (no service file) -> still reaped" "$(pcr_run - "$PCR")" "sudo:rm -f"
# Versioned install dirs carry dots (pithead-v1.9.3). Ownership must compare the ExecStart path
# as an exact string, never a regex: with the dots read as "any char", a sibling whose path
# differs only at those positions would falsely match as our own — and get removed.
mkdir -p "$PCR/v1.9.3" "$PCR/v1x9y3"
assert_eq "foreign owner differing only at regex-dot positions -> left alone" \
    "$(pcr_run "$PCR/v1x9y3" "$PCR/v1.9.3")" ""
# One checkout, two spellings: production units carry the versioned dir in ExecStart, and an
# operator's disable apply runs through the `current` symlink. Ownership compares physical
# paths, so the unit is recognized as our own and removed — a literal $PWD compare would call
# it foreign and the disable would never converge.
mkdir -p "$PCR/versions/pithead-v1.9.3"
ln -s "$PCR/versions/pithead-v1.9.3" "$PCR/current"
assert_contains "own unit under its versioned spelling, run via the current symlink -> removed" \
    "$(pcr_run "$PCR/versions/pithead-v1.9.3" "$PCR/current")" "sudo:rm -f"
unset PCR pcr_run

echo "== unit: doctor sees control units that do not point at this install (#33) =="
# The failure this guards is silent by construction: the dashboard writes control requests into
# its own install's spool, a box-global systemd unit watches some absolute path, and when the two
# disagree nothing reports it — the config editor and one-click upgrade just never complete.
# Seen in the field on a production box: a failed upgrade repointed the units at the half-installed
# tree, and two operator upgrade requests sat unread for a day with no error on either side.
#
# Mutation proof (each assertion below fails if the guard regresses):
#   - drop the `[ "$owner" != "$here" ]` arm      -> "units point elsewhere" goes green->red
#   - flip that `!=` to `=`                        -> mismatch AND aligned assertions both flip
#   - drop the spool comparison arm                -> "watches a different spool" goes red
#   - drop the `-z "$owner"` arm                   -> "no units installed" loses its message
#   - drop the enabled gate's `return 0`           -> "disabled" assertion sees a FAIL
CCU="$SANDBOX/ccu"
mkdir -p "$CCU/units" "$CCU/bin" "$CCU/install" "$CCU/other"
# uname/systemctl stubs: the check gates on Linux + systemctl, so dev Macs run the branch too.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$CCU/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CCU/bin/systemctl"
chmod +x "$CCU/bin/uname" "$CCU/bin/systemctl"

ccu_run() { # <owner-dir|-> <spool-in-path-unit|-> <enabled> <run-dir> [control-dir-in-env] -> output
    rm -f "$CCU/units/pithead-control.service" "$CCU/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$CCU/units/pithead-control.service"
    [ "$2" != "-" ] && printf '[Path]\nPathExistsGlob=%s/requests/*.json\n' "$2" >"$CCU/units/pithead-control.path"
    printf 'DASHBOARD_CONTROL_ENABLED=%s\nCONTROL_DIR=%s\n' "$3" "${5:-$4/data/control}" >"$4/.env"
    (
        cd "$4" || exit
        PATH="$CCU/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        PITHEAD_UNIT_DIR="$CCU/units" check_control_units 2>&1
    )
}

# The production shape: units name a tree that is not this install. Must FAIL, and must name both
# paths — an operator who cannot see which directory is wrong cannot fix it.
out="$(ccu_run "$CCU/other" "$CCU/install/data/control" true "$CCU/install")"
assert_contains "units point elsewhere -> FAIL" "$out" "FAIL"
assert_contains "units point elsewhere -> names the unit's directory" "$out" "$CCU/other"
assert_contains "units point elsewhere -> names this install" "$out" "$CCU/install"

# Aligned: same install, same spool. Must be OK and must NOT fail.
out="$(ccu_run "$CCU/install" "$CCU/install/data/control" true "$CCU/install")"
assert_not_contains "aligned units -> no FAIL" "$out" "FAIL"
assert_contains "aligned units -> OK" "$out" "target this install"

# Control enabled but the units were never installed at all. Assert the DISTINCT message, not just
# that something failed: with no units the owner is empty, so the mismatch arm below would fail on
# its own and an assertion for bare "FAIL" would stay green with this arm deleted — and the operator
# would get "point at , but this install is ..." instead of being told the units are simply missing.
out="$(ccu_run - - true "$CCU/install")"
assert_contains "no units installed -> FAIL naming the real cause" "$out" "no runner units are installed"

# Service unit right, path unit watching someone else's spool: requests are still never read.
out="$(ccu_run "$CCU/install" "$CCU/other/data/control" true "$CCU/install")"
assert_contains "path unit watches a different spool -> FAIL" "$out" "FAIL"

# Control disabled: the units are irrelevant, so a mismatch must NOT be reported as a fault.
out="$(ccu_run "$CCU/other" "$CCU/other/data/control" false "$CCU/install")"
assert_not_contains "control disabled -> no FAIL" "$out" "FAIL"

# The two spellings of one checkout (versioned dir vs the `current` symlink) are the SAME install.
# A literal string compare would call this a mismatch and cry wolf on every production box.
mkdir -p "$CCU/versions/pithead-v1.9.3"
ln -sfn "$CCU/versions/pithead-v1.9.3" "$CCU/current"
# .env and the path unit both carry the versioned spelling, as one render always writes them;
# only the invocation goes through the symlink. The owner compare must resolve both to one install.
out="$(ccu_run "$CCU/versions/pithead-v1.9.3" "$CCU/versions/pithead-v1.9.3/data/control" true \
    "$CCU/current" "$CCU/versions/pithead-v1.9.3/data/control")"
assert_not_contains "versioned dir vs current symlink -> same install, no FAIL" "$out" "FAIL"

# A stranded unit usually names a directory that no longer exists; the check must still resolve a
# printable path and report the mismatch rather than going quiet on an empty answer.
out="$(ccu_run "$CCU/deleted-tree" "$CCU/install/data/control" true "$CCU/install")"
assert_contains "unit names a deleted directory -> still FAILs" "$out" "FAIL"
assert_contains "unit names a deleted directory -> still names it" "$out" "$CCU/deleted-tree"

# The documented layout keeps the PREVIOUS version dir for rollback, and the one-click upgrade runs
# in the browser, so the operator's shell is routinely still sitting in it. The units correctly name
# the live dir there. Calling that box broken would be a cry-wolf FAIL on a healthy install — and
# worse, the printed fix ('apply' from here) would repoint the units at the rollback dir and break
# the live install for real. A superseded version dir must report INFO and no verdict.
# Mutation: delete the `current`-symlink guard in check_control_units -> this goes red (FAIL returns).
mkdir -p "$CCU/deploy/pithead-v1.19.0" "$CCU/deploy/pithead-v1.19.1/data/control"
ln -sfn pithead-v1.19.1 "$CCU/deploy/current"
out="$(ccu_run "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control" true \
    "$CCU/deploy/pithead-v1.19.0" "$CCU/deploy/pithead-v1.19.1/data/control")"
assert_not_contains "superseded rollback dir -> no FAIL (units belong to the live install)" "$out" "FAIL"
assert_contains "superseded rollback dir -> says which dir is live" "$out" "$CCU/deploy/pithead-v1.19.1"
# ...and the live dir itself still gets a real verdict, so the guard cannot silence everything.
out="$(ccu_run "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control" true \
    "$CCU/deploy/pithead-v1.19.1" "$CCU/deploy/pithead-v1.19.1/data/control")"
assert_contains "the live install still gets a verdict" "$out" "target this install"
unset CCU ccu_run out

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
        P2POOL_ONION="abc.onion"  # provisioning marker; read under `set -u` before the stub
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

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
