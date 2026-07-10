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

# A throwaway sandbox dir, cleaned on exit.
SANDBOX="$(mktemp -d)"
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
run_sourced "$SANDBOX" assert_safe_dir "/mnt/disk/monero" >/dev/null 2>&1
assert_rc "allows mount subfolder" "$?" "0"

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
name=$(printf '%s' "$*" | sed -n 's/.*name=\^\([a-z-]*\)\$.*/\1/p')
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
# Running + nothing on :3333 -> FAIL.
out="$(RUNNING_CONTAINERS="xmrig-proxy" SS_OUT='LISTEN 0 4096 127.0.0.1:8000 0.0.0.0:*' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_stratum_listening 2>&1)"
assert_contains "stratum listen: nothing on :3333 -> FAIL" "$out" "NOTHING is listening"

# Dashboard probe: container running + app answers -> OK; running + no answer -> WARN (not FAIL).
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=0 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: answers -> OK" "$out" "answers on 127.0.0.1:8000"
out="$(RUNNING_CONTAINERS="dashboard" CURL_RC=22 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: no answer -> WARN" "$out" "WARN"
out="$(RUNNING_CONTAINERS="" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_dashboard_answers 2>&1)"
assert_contains "dashboard probe: container down -> info" "$out" "isn't running"

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

echo "== unit: describe_change =="
assert_contains "prune is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 1 0)" "DEST"
assert_contains "rpc lan is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_RPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum open is DEST" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum lan is INFO" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 0.0.0.0 127.0.0.1)" "INFO"
# Stratum access-password (#152): enabling/changing is DEST (rigs need the new pass), disabling is
# INFO — and the secret value must NEVER appear in the change preview.
assert_contains "stratum pw enable is DEST" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" "DEST"
assert_contains "stratum pw disable is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD s3cr3t '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD oldpw newpw)" in
*oldpw* | *newpw*) bad "stratum pw change hides the secret" "value leaked into the change preview" ;;
*DEST*) ok "stratum pw change hides the secret (DEST, no value shown)" ;;
*) bad "stratum pw change hides the secret" "expected DEST" ;;
esac
# Dev-fee donate-level (#173): a brief restart (INFO), shown as a percentage.
assert_contains "donate-level is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "INFO"
assert_contains "donate-level shows pct" "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "0% → 1%"
assert_contains "wallet is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_WALLET_ADDRESS a b)" "DEST"
assert_contains "xvb url is INFO" "$(run_sourced "$SANDBOX" describe_change XVB_POOL_URL a b)" "INFO"
assert_contains "data_dir is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_DATA_DIR /a /b)" "DEST"
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
case "$tg_tok_msg" in
*oldsecret* | *newsecret*) bad "telegram token value not leaked in preview" "leaked: $tg_tok_msg" ;;
*) ok "telegram token value not leaked in preview" ;;
esac
assert_contains "monero mem is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "INFO"
assert_contains "monero mem recreate note" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "monerod container is recreated"
# Clearnet initial sync (#183): enabling OR disabling is DEST (the daemon is recreated), and enabling
# must spell out the exposure so the apply confirmation is unambiguous.
assert_contains "monero clearnet enable is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "DEST"
assert_contains "monero clearnet enable warns exposure" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "CLEARNET"
assert_contains "monero clearnet keeps tx on Tor" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC false true)" "Tor"
assert_contains "monero clearnet disable is DEST" "$(run_sourced "$SANDBOX" describe_change MONERO_CLEARNET_SYNC true false)" "DEST"
assert_contains "tari clearnet enable is DEST" "$(run_sourced "$SANDBOX" describe_change TARI_CLEARNET_SYNC false true)" "DEST"
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

# apply had the same after-compose ordering bug as #272's stack_upgrade — fixed alongside #291. Take
# the no-change-but-incomplete-marker retry path so apply recreates containers without the interactive
# diff (env_changed_keys returns nothing; a pre-seeded .apply-incomplete marker forces the retry).
apply_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    # shellcheck disable=SC2034  # read by the sourced apply()'s "not provisioned" guard, unseen here
    MONERO_ONION=onion
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
assert_contains "monero default: out-peers 48 for Tor (#183)" "$(cat "$ROOT/build/monero/bitmonero.conf.template")" "out-peers=48"
# Compose wires both flags into container env: monerod reads MONERO_CLEARNET_SYNC in its entrypoint;
# TARI_CLEARNET_SYNC is inert in the container but its presence makes a flag change recreate tari so
# it re-reads the host-rendered config.toml (a bind-mount content change alone won't recreate it).
assert_contains "compose passes MONERO_CLEARNET_SYNC to monerod (#183)" "$(cat "$ROOT/docker-compose.yml")" 'MONERO_CLEARNET_SYNC=${MONERO_CLEARNET_SYNC'
assert_contains "compose passes TARI_CLEARNET_SYNC to tari (#183)" "$(cat "$ROOT/docker-compose.yml")" 'TARI_CLEARNET_SYNC=${TARI_CLEARNET_SYNC'

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
upg_capture() { # <onion_enabled> <current_onion> -> prints "captured" if provision_dashboard_onion ran
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
    migrate_compose_project() { :; }
    is_source_checkout() { return 1; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    compose_up_checked() { :; }
    provision_dashboard_onion() { echo captured; }
    export DASHBOARD_ONION_ENABLED="$1"
    export DASHBOARD_ONION="$2"
    stack_upgrade
}
assert_contains "upgrade captures the onion address when enabled + uncaptured (#356)" "$(upg_capture true '')" "captured"
assert_not_contains "upgrade skips capture when the onion is disabled (#356)" "$(upg_capture false '')" "captured"

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
    make_bundle "$WORKDIR/pithead.tar.gz" >/dev/null 2>&1
    tar tzf "$WORKDIR/pithead.tar.gz" 2>/dev/null
) >"$SANDBOX/bundle.list" 2>/dev/null
grep -q '^pithead/config.minimal.json$' "$SANDBOX/bundle.list" && ok "bundle ships config.minimal.json (basic quick-start config)" || bad "bundle ships config.minimal.json" "absent from the bundle"
grep -q '^pithead/$' "$SANDBOX/bundle.list" && ok "bundle unpacks to versionless pithead/" || bad "bundle unpacks to pithead/" "top-level dir is not pithead/"
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
assert_eq "tari -> 170" "$(run_sourced "$SANDBOX" disk_component_gib tari)" "170"
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
# component, with the combined pruned requirement (120+170+5+2+1 = 298 GB).
one_map="$md=/data $td=/data $pd=/data $dd=/data $rd=/data /data=/data"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "single line names all components" "$out" "(monero, tari, p2pool, dashboard, tor)"
assert_contains "single line shows combined ~298 GB" "$out" "needs ~298 GB"
assert_contains "ample space -> OK" "$out" "OK"

# Same single filesystem but too small (100 GiB < 298 GiB) -> ONE WARN line.
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$one_map" DF_AVAIL_KB=104857600 DF_AVAIL_H=100G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "one small fs -> single line" "$(printf '%s\n' "$out" | grep -c 'Data on')" "1"
assert_contains "small fs warns below need" "$out" "below the ~298 GB"

# Two filesystems: monero+tari on /big, the rest on /small -> ONE line per filesystem.
two_map="$md=/big $td=/big $pd=/small $dd=/small $rd=/small /big=/big /small=/small"
out="$(PATH="$DISK/bin:$PATH" DF_MAP="$two_map" DF_AVAIL_KB=629145600 DF_AVAIL_H=600G \
    run_sourced "$SANDBOX" check_disk_grouped doctor 1 "$md" "$td" "$pd" "$dd" "$rd" 2>&1)"
assert_eq "two fs -> two lines" "$(printf '%s\n' "$out" | grep -c 'Data on')" "2"
assert_contains "/big groups monero+tari (~290 GB)" "$out" "/big (monero, tari): 600G free — needs ~290 GB"
assert_contains "/small groups the small three (~8 GB)" "$out" "/small (p2pool, dashboard, tor): 600G free — needs ~8 GB"

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

# Remote mode with no host (#*): renders an empty MONERO_NODE_HOST -> p2pool/dashboard dial nothing,
# mining can't start. Must abort at validation, not silently proceed.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "remote mode without a host rejected" "$rc" "1"
assert_contains "remote-host message" "$out" "monero.remote.host"

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
assert_eq "token preserved" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
assert_eq "onion preserved" "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_ONION_ADDRESS)" "p2pa.onion"
assert_eq "tari_required default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"
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

# Non-blocking Tari (dashboard.tari_required:false) propagates as TARI_REQUIRED=false.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","tari_required":false} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari_required propagated false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

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
# Re-apply: an "auto" password must be STABLE (reused, not rotated) — like the proxy token.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_password auto stable across apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "$sp1"

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
# must spell out the clearnet exposure (it's a DEST change).
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
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$ST/.env"
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
out="$(cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1)"
rc=$?
assert_contains "doctor runs to the summary" "$out" "Diagnostics summary"
assert_contains "doctor flags the unreachable daemon" "$out" "Docker daemon is not reachable"
assert_rc "doctor exits 1 on a critical FAIL" "$rc" "1"

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

# 1) Backup creates a timestamped archive.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
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
out="$(cd "$BK" && printf 'n\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
rc=$?
assert_rc "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first" "$out" "Low free space"

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

# tor wrapper entrypoint: opt-in dashboard hidden service (#343). The HiddenService block is appended
# to the rendered torrc ONLY when DASHBOARD_ONION_ENABLED=true, targeting the bridge gateway
# (NETWORK_PREFIX.1) where Caddy binds the auth-gated onion vhost. pithead's caddy/client-auth side is
# covered above; this exercises the real container entrypoint's branch + the .1 substitution with a
# stub `tor` on PATH and the repo torrc.template (via the TORRC_TEMPLATE seam).
TOR_ENTRY="$ROOT/build/tor/entrypoint.sh"
tor_torrc() { # <DASHBOARD_ONION_ENABLED> -> the torrc the entrypoint would hand to `tor -f`
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\ncat /tmp/torrc\n' >"$d/tor" # stub tor: ignore -f, just print the rendered file
    chmod +x "$d/tor"
    PATH="$d:$PATH" DASHBOARD_ONION_ENABLED="$1" NETWORK_PREFIX=10.9.0 \
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

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
