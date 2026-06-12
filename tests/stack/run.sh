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

ok()  { PASS=$((PASS + 1)); printf '  \033[1;32m✓\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[1;31m✗\033[0m %s\n      %s\n' "$1" "$2"; }

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$2] missing [$3]" ;; esac; }
assert_rc()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected rc $3, got $2"; fi; }

# Run a command with pithead sourced (functions available, no cd/main side effects),
# from a given working directory. Usage: run_sourced <dir> <cmd> [args...]
# shellcheck disable=SC1090  # STACK path is dynamic by design
run_sourced() {
    local dir="$1"; shift
    ( cd "$dir" || return; source "$STACK"; set +e; "$@" )
}

# A throwaway sandbox dir, cleaned on exit.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# A fake docker that records calls and answers the few queries setup/apply make.
make_stubs() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose version"|"info") exit 0 ;;
  "exec tor test -f "*) exit 0 ;;
  "exec tor cat /var/lib/tor/monero/hostname") echo "mona.onion" ;;
  "exec tor cat /var/lib/tor/tari/hostname")   echo "taria.onion" ;;
  "exec tor cat /var/lib/tor/p2pool/hostname") echo "p2pa.onion" ;;
  *hash-password*)
    # Fake `caddy hash-password` (#8): a per-password digest so enable/change paths differ, and it
    # never echoes the plaintext back (real bcrypt doesn't either) — keeps the leak checks honest.
    _pw="${*##*--plaintext }"
    _d="$(printf '%s' "$_pw" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-22)"
    printf '$2y$14$%s\n' "$_d" ;;
esac
exit 0
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/sudo"
    chmod +x "$bin/docker" "$bin/sudo"
}

# ---------------------------------------------------------------------------
echo "== unit: resolve_default =="
assert_eq "auto -> default"        "$(run_sourced "$SANDBOX" resolve_default auto /def)"          "/def"
assert_eq "empty -> default"       "$(run_sourced "$SANDBOX" resolve_default '' /def)"            "/def"
assert_eq "DYNAMIC_DATA -> default" "$(run_sourced "$SANDBOX" resolve_default DYNAMIC_DATA /def)" "/def"
assert_eq "custom kept"            "$(run_sourced "$SANDBOX" resolve_default /my/dir /def)"        "/my/dir"

echo "== unit: assert_safe_dir =="
run_sourced "$SANDBOX" assert_safe_dir "/"       >/dev/null 2>&1; assert_rc "rejects /"        "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/home"   >/dev/null 2>&1; assert_rc "rejects /home"    "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir ""        >/dev/null 2>&1; assert_rc "rejects empty"    "$?" "1"
run_sourced "$SANDBOX" assert_safe_dir "/srv/p2pool/data" >/dev/null 2>&1; assert_rc "allows real dir" "$?" "0"

echo "== unit: is_public_ip classifier (#113) =="
# Globally-routable -> rc 0 (public). Includes boundaries just OUTSIDE each excluded range.
for ip in 8.8.8.8 1.1.1.1 172.15.0.1 172.32.0.1 100.128.0.1 169.1.1.1 2606:4700:4700::1111 2001:db8::1; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1; assert_rc "public: $ip" "$?" "0"
done
# Private / loopback / link-local / CGNAT / ULA / multicast / unspecified / garbage -> rc 1.
for ip in 10.0.0.5 172.16.0.1 172.31.255.1 192.168.1.50 127.0.0.1 169.254.1.1 100.64.0.1 0.0.0.0 \
          ::1 fe80::1 fc00::1 fd12:3456::1 ff02::1 999.1.1.1 not-an-ip ""; do
    run_sourced "$SANDBOX" is_public_ip "$ip" >/dev/null 2>&1; assert_rc "non-public: ${ip:-<empty>}" "$?" "1"
done

echo "== unit: is_ipv4 =="
run_sourced "$SANDBOX" is_ipv4 "0.0.0.0"      >/dev/null 2>&1; assert_rc "accepts 0.0.0.0"     "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "127.0.0.1"    >/dev/null 2>&1; assert_rc "accepts 127.0.0.1"   "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "192.168.1.10" >/dev/null 2>&1; assert_rc "accepts LAN IP"      "$?" "0"
run_sourced "$SANDBOX" is_ipv4 "256.0.0.1"    >/dev/null 2>&1; assert_rc "rejects octet >255"  "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "1.2.3"        >/dev/null 2>&1; assert_rc "rejects 3 octets"    "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "192.168.1.0/24" >/dev/null 2>&1; assert_rc "rejects CIDR/subnet" "$?" "1"
run_sourced "$SANDBOX" is_ipv4 "example.com"  >/dev/null 2>&1; assert_rc "rejects hostname"    "$?" "1"
run_sourced "$SANDBOX" is_ipv4 ""             >/dev/null 2>&1; assert_rc "rejects empty"       "$?" "1"

echo "== unit: resolve_dashboard_host (dashboard.host 'auto' revert, 247c5a0) =="
# A configured dashboard.host is used verbatim.
# shellcheck disable=SC1090,SC2034  # $STACK path is dynamic; DASHBOARD_HOST is read by the sourced function
got="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; DASHBOARD_HOST='my.box.lan'; resolve_dashboard_host >/dev/null 2>&1; printf '%s' "$HOST_IP" )"
assert_eq "configured dashboard.host is used" "$got" "my.box.lan"
# 'auto' (no dashboard.host) on a non-interactive run must REVERT HOST_IP to the machine
# hostname, not keep a stale prior value — the regression fixed in 247c5a0.
# shellcheck disable=SC1090,SC2034
got="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; DASHBOARD_HOST=''; HOST_IP='STALE'; resolve_dashboard_host >/dev/null 2>&1; printf '%s' "$HOST_IP" )"
assert_eq "dashboard.host 'auto' reverts to hostname" "$got" "$(hostname)"
echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"; mkdir -p "$BOOT/bin"
cat > "$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled; assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket  run_sourced "$SANDBOX" docker_boot_enabled; assert_rc "docker.socket enabled -> 0"  "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none    run_sourced "$SANDBOX" docker_boot_enabled; assert_rc "neither enabled -> 1"        "$?" "1"

echo "== unit: is_valid_host (#130) =="
run_sourced "$SANDBOX" is_valid_host "box.lan"       >/dev/null 2>&1; assert_rc "accepts hostname"      "$?" "0"
run_sourced "$SANDBOX" is_valid_host "192.168.1.10"  >/dev/null 2>&1; assert_rc "accepts IPv4"          "$?" "0"
run_sourced "$SANDBOX" is_valid_host "fe80::1"       >/dev/null 2>&1; assert_rc "accepts IPv6"          "$?" "0"
run_sourced "$SANDBOX" is_valid_host "bad host"      >/dev/null 2>&1; assert_rc "rejects space"         "$?" "1"
run_sourced "$SANDBOX" is_valid_host 'evil{block}'   >/dev/null 2>&1; assert_rc "rejects braces"        "$?" "1"
run_sourced "$SANDBOX" is_valid_host "a/b"           >/dev/null 2>&1; assert_rc "rejects slash"         "$?" "1"
run_sourced "$SANDBOX" is_valid_host ""              >/dev/null 2>&1; assert_rc "rejects empty"         "$?" "1"

echo "== unit: describe_change =="
assert_contains "prune is DEST"      "$(run_sourced "$SANDBOX" describe_change MONERO_PRUNE 1 0)"        "DEST"
assert_contains "rpc lan is DEST"    "$(run_sourced "$SANDBOX" describe_change MONERO_RPC_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum open is DEST" "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 127.0.0.1 0.0.0.0)" "DEST"
assert_contains "stratum lan is INFO"  "$(run_sourced "$SANDBOX" describe_change STRATUM_BIND 0.0.0.0 127.0.0.1)" "INFO"
# Stratum access-password (#152): enabling/changing is DEST (rigs need the new pass), disabling is
# INFO — and the secret value must NEVER appear in the change preview.
assert_contains "stratum pw enable is DEST"  "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD '' s3cr3t)" "DEST"
assert_contains "stratum pw disable is INFO" "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD s3cr3t '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change PROXY_STRATUM_PASSWORD oldpw newpw)" in
    *oldpw*|*newpw*) bad "stratum pw change hides the secret" "value leaked into the change preview" ;;
    *DEST*)          ok  "stratum pw change hides the secret (DEST, no value shown)" ;;
    *)               bad "stratum pw change hides the secret" "expected DEST" ;;
esac
# Dev-fee donate-level (#173): a brief restart (INFO), shown as a percentage.
assert_contains "donate-level is INFO"      "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "INFO"
assert_contains "donate-level shows pct"    "$(run_sourced "$SANDBOX" describe_change PROXY_DONATE_LEVEL 0 1)" "0% → 1%"
assert_contains "wallet is DEST"     "$(run_sourced "$SANDBOX" describe_change MONERO_WALLET_ADDRESS a b)" "DEST"
assert_contains "xvb url is INFO"    "$(run_sourced "$SANDBOX" describe_change XVB_POOL_URL a b)"        "INFO"
assert_contains "data_dir is DEST"   "$(run_sourced "$SANDBOX" describe_change MONERO_DATA_DIR /a /b)"   "DEST"
assert_contains "tari mem is INFO"   "$(run_sourced "$SANDBOX" describe_change TARI_MEM_LIMIT 2048m 4g)" "INFO"
assert_contains "monero mem is INFO" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)"  "INFO"
assert_contains "monero mem recreate note" "$(run_sourced "$SANDBOX" describe_change MONERO_MEM_LIMIT 4g 6g)" "monerod container is recreated"

echo "== unit: dashboard auth (#8) =="
# Dashboard login (#8): enabling/changing is DEST (caddy is recreated), disabling is INFO. The bcrypt
# hash is a secret and must never surface in the change preview; the internal fingerprint stays silent.
assert_contains "dash login enable is DEST"  "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 '' aGFzaA==)" "DEST"
assert_contains "dash login disable is INFO" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 aGFzaA== '')" "INFO"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_HASH_B64 b2xkSA== bmV3SA==)" in
    *b2xkSA==*|*bmV3SA==*) bad "dash login change hides the hash" "hash value leaked into the change preview" ;;
    *DEST*)                ok  "dash login change hides the hash (DEST, no value shown)" ;;
    *)                     bad "dash login change hides the hash" "expected DEST" ;;
esac
assert_contains "dash login username change is shown" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_USER admin bob)" "admin → bob"
case "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_PW_FP aaa bbb)" in
    *PW_FP*|*updated*|*fingerprint*) bad "dash login fingerprint stays silent" "internal fingerprint surfaced in the preview" ;;
    INFO*)                           ok  "dash login fingerprint stays silent (no preview line)" ;;
    *)                               bad "dash login fingerprint stays silent" "unexpected message emitted" ;;
esac

# New-release check toggle (#224): enabling/disabling is INFO, and the message names GitHub + Tor.
assert_contains "update-check enable is INFO"   "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "INFO"
assert_contains "update-check enable mentions GitHub/Tor" "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES false true)" "GitHub"
assert_contains "update-check disable is INFO"  "$(run_sourced "$SANDBOX" describe_change DASHBOARD_CHECK_UPDATES true false)" "no longer contacts GitHub"

# generate_caddyfile renders a basic_auth block ONLY when a hash is configured, carrying the username
# and the *decoded* bcrypt string Caddy expects; with no hash the dashboard stays open (no basic_auth).
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_on="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$auth_hb64" \
        generate_caddyfile >/dev/null 2>&1; cat Caddyfile )"
assert_contains "caddy renders basic_auth when login set" "$caddy_on" "basic_auth"
assert_contains "caddy basic_auth carries the username"   "$caddy_on" "admin"
assert_contains "caddy basic_auth carries decoded hash"   "$caddy_on" '$2y$14$UNITTESTbcrypthashvalue'
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_off="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1; cat Caddyfile )"
case "$caddy_off" in
    *basic_auth*) bad "caddy stays open when no login set" "basic_auth rendered without a password" ;;
    *)            ok  "caddy stays open when no login set (no basic_auth)" ;;
esac

echo "== unit: generate_caddyfile scheme (#140) =="
# The HTTPS-vs-HTTP choice is security-relevant: secure -> https:// + `tls internal`; insecure ->
# plain http:// and no TLS directive. (Auth on/off is covered in the dashboard-auth block above.)
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_https="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1; cat Caddyfile )"
assert_contains "caddyfile secure uses https"  "$caddy_https" "https://box.lan"
assert_contains "caddyfile secure enables TLS" "$caddy_https" "tls internal"
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_http="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e
    DASHBOARD_SECURE=false HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1; cat Caddyfile )"
assert_contains "caddyfile insecure uses http" "$caddy_http" "http://box.lan"
case "$caddy_http" in
    *"tls internal"*) bad "caddyfile insecure has no TLS" "'tls internal' present on a plain-HTTP site" ;;
    *)                ok  "caddyfile insecure has no TLS" ;;
esac

echo "== unit: host detection (#140) =="
# detect_os reads ID / VERSION_ID / PRETTY_NAME from an overridable os-release (drives the
# 'supported on Ubuntu 24.04' check); a missing file leaves the fields empty (caller warns).
osr="$SANDBOX/os-release"
printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04.1 LTS"\n' > "$osr"
# shellcheck disable=SC1090  # STACK path is dynamic by design
os_out="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; OS_RELEASE_FILE="$osr" detect_os; printf '%s|%s|%s' "$OS_ID" "$OS_VERSION" "$OS_PRETTY" )"
assert_eq "detect_os parses os-release" "$os_out" "ubuntu|24.04|Ubuntu 24.04.1 LTS"
# shellcheck disable=SC1090  # STACK path is dynamic by design
os_missing="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; OS_RELEASE_FILE="$SANDBOX/nope" detect_os; printf '%s' "$OS_ID" )"
assert_eq "detect_os tolerates a missing file" "$os_missing" ""

# detect_host_timezone: an explicit IANA-shaped TZ wins; garbage falls back to Etc/UTC.
# shellcheck disable=SC1090  # STACK path is dynamic by design
tz_good="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; TZ="America/Chicago" detect_host_timezone )"
assert_eq "detect_host_timezone honors a valid TZ" "$tz_good" "America/Chicago"
# shellcheck disable=SC1090  # STACK path is dynamic by design
tz_bad="$( cd "$SANDBOX" && source "$STACK" 2>/dev/null; set +e; TZ="not a zone!" detect_host_timezone )"
assert_eq "detect_host_timezone rejects garbage -> Etc/UTC" "$tz_bad" "Etc/UTC"

# deps_satisfied is true only when jq/openssl/docker are present AND `docker compose version` works
# (the v2-plugin gate). A docker whose `compose version` fails makes it false.
DEPS="$SANDBOX/deps"; make_stubs "$DEPS/bin"
# shellcheck disable=SC1090  # STACK path is dynamic by design
( cd "$SANDBOX" && PATH="$DEPS/bin:$PATH" && source "$STACK" 2>/dev/null; set +e; deps_satisfied ); assert_rc "deps_satisfied true with all deps" "$?" "0"
printf '#!/usr/bin/env bash\n[ "$*" = "compose version" ] && exit 1\nexit 0\n' > "$DEPS/bin/docker"; chmod +x "$DEPS/bin/docker"
# shellcheck disable=SC1090  # STACK path is dynamic by design
( cd "$SANDBOX" && PATH="$DEPS/bin:$PATH" && source "$STACK" 2>/dev/null; set +e; deps_satisfied ); assert_rc "deps_satisfied false without compose v2" "$?" "1"

echo "== unit: release.sh pure logic (#44) =="
# The release pipeline's side-effect-free helpers (no docker needed). Sourced from the repo root with
# the positional args cleared (`set --`) so release.sh's own arg-parser doesn't see the test's args;
# release.sh guards its main() behind a BASH_SOURCE check, so sourcing only defines the functions.
REL="$ROOT/scripts/release.sh"
# shellcheck disable=SC1090
( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; is_semver "0.1.0" );      assert_rc "is_semver accepts 0.1.0"        "$?" "0"
# shellcheck disable=SC1090
( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; is_semver "1.2.3-rc.1" ); assert_rc "is_semver accepts a prerelease" "$?" "0"
# shellcheck disable=SC1090
( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; is_semver "1.2" );        assert_rc "is_semver rejects a partial"    "$?" "1"
# shellcheck disable=SC1090
( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; is_semver "v1.2.3" );     assert_rc "is_semver rejects a leading v"  "$?" "1"
# shellcheck disable=SC1090
assert_eq "image_for builds the GHCR image name" \
    "$( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; image_for dashboard )" \
    "ghcr.io/p2pool-starter-stack/pithead-dashboard"
# The ingredients manifest's component pins must resolve to a real value present in each Dockerfile —
# a drift guard so a renamed ARG can't silently emit an empty pin in the release notes.
for svc in p2pool monero xmrig-proxy; do
    # shellcheck disable=SC1090
    pv="$( cd "$ROOT" || exit; set --; source "$REL" 2>/dev/null; set +eu; pin "$svc" )"
    if [ -n "$pv" ] && grep -q -- "$pv" "$ROOT/build/$svc/Dockerfile"; then
        ok "pin $svc resolves to a value in its Dockerfile"
    else
        bad "pin $svc resolves to a value in its Dockerfile" "got '$pv'"
    fi
done
# The top-level VERSION file is the single source of truth (#44); the dashboard's Python package
# metadata must stay in lockstep so a release can't ship two different "stack versions".
ver_file="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
ver_pyproject="$(grep -oE '^version = "[^"]+"' "$ROOT/build/dashboard/pyproject.toml" | head -1 | cut -d'"' -f2)"
assert_eq "pyproject.toml version matches VERSION (#44)" "$ver_pyproject" "$ver_file"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/build/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"; t_rest="${tier#*:}"; t_val="${t_rest%%:*}"; t_human="${t_rest#*:}"
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
SRCM="$SANDBOX/srcmode"; mkdir -p "$SRCM/build/dashboard"; : > "$SRCM/build/dashboard/Dockerfile"; printf '0.1.0\n' > "$SRCM/VERSION"
RELM="$SANDBOX/relmode"; mkdir -p "$RELM/build/tari"; printf '0.1.0\n' > "$RELM/VERSION"
# shellcheck disable=SC1090
( cd "$SRCM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; is_source_checkout ); assert_rc "is_source_checkout true with a Dockerfile" "$?" "0"
# shellcheck disable=SC1090
( cd "$RELM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; is_source_checkout ); assert_rc "is_source_checkout false without a Dockerfile" "$?" "1"
# shellcheck disable=SC1090
assert_eq "pull policy: source -> never"      "$( cd "$SRCM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; resolve_pull_policy )" "never"
# shellcheck disable=SC1090
assert_eq "pull policy: release -> missing"   "$( cd "$RELM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; resolve_pull_policy )" "missing"
# shellcheck disable=SC1090
assert_eq "pull policy: PITHEAD_PULL override" "$( cd "$SRCM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; PITHEAD_PULL=always resolve_pull_policy )" "always"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION dev in a source checkout"   "$( cd "$SRCM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; export_build_provenance; printf '%s' "$STACK_VERSION" )" "dev"
# shellcheck disable=SC1090
assert_eq "STACK_VERSION v0.1.0 in a release bundle" "$( cd "$RELM" || exit; set --; source "$STACK" 2>/dev/null; set +eu; export_build_provenance; printf '%s' "$STACK_VERSION" )" "v0.1.0"

echo "== unit: explain_subnet_collision (#180) =="
ov="$(run_sourced "$SANDBOX" explain_subnet_collision "invalid pool request: Pool overlaps with other one on this address space" 2>&1)"
assert_contains "subnet overlap -> network.subnet hint"  "$ov" "network"
assert_contains "subnet overlap -> suggests a free /24"  "$ov" "/24"
assert_eq "non-overlap failure stays silent" "$(run_sourced "$SANDBOX" explain_subnet_collision "some other failure" 2>&1)" ""

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' > "$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' > "$SANDBOX/new.env"
assert_eq "env_get_file reads value"      "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with ="     "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in build/dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"; mkdir -p "$PROV"; printf '  9.9.9 \n' > "$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"; mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

echo "== unit: node credential helpers =="
assert_eq "default username is admin" "$(run_sourced "$SANDBOX" default_node_username)" "admin"
PW="$(run_sourced "$SANDBOX" generate_node_password)"
assert_eq "generated password is 32 chars"   "${#PW}" "32"
assert_eq "generated password is alphanumeric" "$(printf '%s' "$PW" | tr -dc 'A-Za-z0-9')" "$PW"
PW2="$(run_sourced "$SANDBOX" generate_node_password)"
if [ "$PW" != "$PW2" ]; then ok "two generations differ"; else bad "two generations differ" "both were [$PW]"; fi
run_sourced "$SANDBOX" cred_needs_generating "" "PLACE";      assert_rc "empty needs generating"       "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "PLACE" "PLACE"; assert_rc "placeholder needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "real" "PLACE";  assert_rc "real value kept"              "$?" "1"

echo "== unit: randomx_boot_params (#176) =="
# The kernel boot params pithead writes into GRUB_CMDLINE_LINUX_DEFAULT for RandomX. Guards the
# regression where the THP-disable param was PLURAL (transparent_hugepages=never) — an unrecognized
# param the kernel silently ignores, so THP was never actually disabled. The valid param is singular.
bp="$(run_sourced "$SANDBOX" randomx_boot_params)"
assert_contains "reserves 2M huge page size" "$bp" "hugepagesz=2M"
assert_contains "reserves 3072 huge pages"   "$bp" "hugepages=3072"
assert_contains "disables THP (singular param)" "$bp" "transparent_hugepage=never"
case "$bp" in
    *transparent_hugepages=*) bad "THP param must be singular, not the kernel-ignored plural" "got [$bp]" ;;
    *) ok "THP param is singular (no plural transparent_hugepages= typo)" ;;
esac

echo "== unit: grub heal + boot-param insert (#176) =="
# A passthrough sudo so the helpers' `sudo cp` / `sudo sed -i` actually edit a sandbox grub file
# (the global stub sudo is a no-op). The helpers select GNU vs BSD sed via OS_TYPE, so this exercises
# the real transformation on both Linux CI and a macOS dev box.
GR="$SANDBOX/grub"; mkdir -p "$GR/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$GR/bin/sudo"
chmod +x "$GR/bin/sudo"
run_grub() { PATH="$GR/bin:$PATH" run_sourced "$SANDBOX" "$@"; }

# heal: rewrites an existing plural typo to the singular param, then is an idempotent no-op.
g="$GR/healed"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never quiet"\n' > "$g"
run_grub heal_grub_thp_typo "$g"; assert_rc "heal: rewrites plural typo (rc 0)" "$?" "0"
assert_contains "heal: file now uses singular param" "$(cat "$g")" "transparent_hugepage=never"
case "$(cat "$g")" in *transparent_hugepages=*) bad "heal: plural typo removed" "$(cat "$g")" ;; *) ok "heal: plural typo removed" ;; esac
run_grub heal_grub_thp_typo "$g"; assert_rc "heal: idempotent no-op when already singular (rc 1)" "$?" "1"

# insert: appends the params to the active line, preserving what's already there.
g="$GR/fresh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' > "$g"
run_grub append_grub_boot_params "$g"; assert_rc "insert: edits the active line (rc 0)" "$?" "0"
out="$(cat "$g")"
assert_contains "insert: keeps existing params"      "$out" "quiet splash"
assert_contains "insert: adds hugepages reservation" "$out" "hugepages=3072"
assert_contains "insert: adds singular THP param"    "$out" "transparent_hugepage=never"

# insert: a commented-out line is not the active form -> rc 1, file untouched (no silent reboot).
g="$GR/commented"
printf '# GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_TIMEOUT=5\n' > "$g"
before="$(cat "$g")"
run_grub append_grub_boot_params "$g"; assert_rc "insert: no active line -> rc 1" "$?" "1"
assert_eq "insert: leaves file unchanged when no active line" "$(cat "$g")" "$before"

echo "== unit: disk_component_gib =="
assert_eq "monero pruned -> 120" "$(run_sourced "$SANDBOX" disk_component_gib monero 1)" "120"
assert_eq "monero full -> 320"   "$(run_sourced "$SANDBOX" disk_component_gib monero 0)" "320"
assert_eq "tari -> 170"          "$(run_sourced "$SANDBOX" disk_component_gib tari)"     "170"
assert_eq "tor -> 1"             "$(run_sourced "$SANDBOX" disk_component_gib tor)"      "1"

echo "== unit: check_disk_grouped (mocked df) =="
# A df stub on PATH so check_disk_grouped sees a scripted filesystem layout. DF_MAP maps each path
# df is queried for to a mount point ("path=mount" space-separated): the data dirs (disk_fs_mount
# resolves the mount from these) AND the mount points themselves (check_disk_grouped reads free
# space via the mount, not the possibly-missing dir — #179). DF_AVAIL_KB / DF_AVAIL_H give the
# (single) free figure every mount reports. Real temp dirs make disk_fs_mount resolve without walking up.
DISK="$SANDBOX/disk"; mkdir -p "$DISK/bin"
cat > "$DISK/bin/df" <<'EOF'
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
DM="$DISK/data"; mkdir -p "$DM/monero" "$DM/tari" "$DM/p2pool" "$DM/dashboard" "$DM/tor"
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
    *xmrvsbeast.com:18080*|*nodes.hashvault.pro*) bad "monerod: priority-node hostnames dropped (#161)" "still present" ;;
    *) ok "monerod: priority-node hostnames dropped (#161)" ;;
esac
case "$(grep -E '^enforce-dns-checkpointing' "$MONC" || true)" in
    "") ok "monerod: enforce-dns-checkpointing removed (#161)" ;;
    *)  bad "monerod: enforce-dns-checkpointing removed (#161)" "still present" ;;
esac
assert_contains "monerod: DNS checkpoints disabled (#161)" "$(cat "$MONC")" "disable-dns-checkpoints=1"
assert_contains "monerod: update check disabled (#161)"    "$(cat "$MONC")" "check-updates=disabled"
# tari (#162): no DNS seeds; peer_seeds onion-only; the inert check_for_updates gRPC method dropped.
assert_contains "tari: DNS seeds disabled (#162)" "$(cat "$TARC")" "dns_seeds = []"
case "$(grep -E '::/ip4/|::/ip6/' "$TARC" || true)" in
    "") ok "tari: peer_seeds are onion-only (#162)" ;;
    *)  bad "tari: peer_seeds are onion-only (#162)" "clearnet /ip4//ip6/ peer seeds present" ;;
esac
case "$(grep -E 'check_for_updates' "$TARC" || true)" in
    "") ok "tari: check_for_updates dropped from gRPC allow-list (#162)" ;;
    *)  bad "tari: check_for_updates dropped from gRPC allow-list (#162)" "still present" ;;
esac
# The Pulse (checkpoints.tari.com TXT, ~120s) is the last clearnet DNS path: the tari container's
# resolver is pointed at a dead local address so the lookup fails without a packet leaving the host
# (Tari tolerates it — returns "passed"). The container already overrode Docker's 127.0.0.11, so no
# service-discovery dependency is broken. Assert no clearnet resolvers remain on the tari service.
TARI_SVC="$(awk '/^  tari:/{f=1;print;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml")"
case "$TARI_SVC" in
    *1.1.1.1*|*8.8.8.8*) bad "tari: clearnet DNS resolvers removed from compose (#162)" "1.1.1.1/8.8.8.8 present" ;;
    *)                   ok "tari: clearnet DNS resolvers removed from compose (#162)" ;;
esac
assert_contains "tari: resolver pointed at dead local sinkhole (#162)" "$TARI_SVC" "127.0.0.1"

# ---------------------------------------------------------------------------
echo "== black-box: CLI dispatch =="
"$STACK" help >/dev/null 2>&1; assert_rc "help exits 0" "$?" "0"
assert_contains "help shows usage" "$("$STACK" help 2>&1)" "Usage:"
out="$("$STACK" frobnicate 2>&1)"; rc=$?
assert_rc "unknown command fails" "$rc" "1"
assert_contains "unknown command message" "$out" "Unknown command"

echo "== black-box: guards =="
G="$SANDBOX/guard"; mkdir -p "$G/build/tari"; cp "$STACK" "$G/pithead"
cp "$ROOT/build/tari/config.toml.template" "$G/build/tari/" 2>/dev/null || true
make_stubs "$G/bin"
out="$(cd "$G" && PATH="$G/bin:$PATH" ./pithead apply 2>&1)"; rc=$?
assert_rc "apply without .env fails" "$rc" "1"
assert_contains "apply needs setup" "$out" "setup"

echo "== black-box: config validation =="
V="$SANDBOX/val"; mkdir -p "$V/build/tari" "$V/build/dashboard"; : > "$V/build/dashboard/Dockerfile"; cp "$STACK" "$V/pithead"; make_stubs "$V/bin"
cp "$ROOT/build/tari/config.toml.template" "$V/build/tari/"
mkdir -p "$V/data/monero" "$V/data/tari" "$V/data/p2pool" "$V/data/tor" "$V/data/dashboard" "$V/data/p2pool/stats"
seed_env() { cat > "$V/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
}
WALLET="49AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"banana"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "invalid pool rejected" "$rc" "1"
assert_contains "invalid pool message" "$out" "p2pool.pool"

# A non-IP stratum_bind must be rejected before it reaches the compose port mapping.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main","stratum_bind":"not-an-ip"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "invalid stratum_bind rejected" "$rc" "1"
assert_contains "invalid stratum_bind message" "$out" "p2pool.stratum_bind"

# A dashboard.host with Caddyfile-breaking characters (space/braces) must be rejected before render.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"bad host{x}"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "invalid dashboard.host rejected" "$rc" "1"
assert_contains "invalid dashboard.host message" "$out" "dashboard.host"

# proxy.donate_level must be an integer 0-99 (default 0); an out-of-range value is rejected (#173).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":150}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "out-of-range donate_level rejected" "$rc" "1"
assert_contains "donate_level message" "$out" "proxy.donate_level"
# Non-numeric donate_level is rejected (the "auto" sentinel was removed — the value is a plain integer).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":"auto"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "non-numeric donate_level rejected" "$rc" "1"

# A stratum_password with a shell/.env-unsafe character (a space) is rejected before render (#152).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main","stratum_password":"bad pass"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "unsafe stratum_password rejected" "$rc" "1"
assert_contains "stratum_password message" "$out" "p2pool.stratum_password"

# Dashboard login (#8): a username with a Caddyfile-unsafe character (a space) is rejected before any
# hashing; the password is validated for length/charset too. Both fail fast on apply.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"bad user","password":"longenough1"}} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "invalid dashboard.auth.username rejected" "$rc" "1"
assert_contains "dashboard.auth.username message" "$out" "dashboard.auth.username"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"short"}} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "too-short dashboard.auth.password rejected" "$rc" "1"
assert_contains "dashboard.auth.password message" "$out" "dashboard.auth.password"

echo "== black-box: dashboard auth lifecycle (#8) =="
# The hashing reads the pinned Caddy image out of docker-compose.yml and shells out to the stubbed
# `caddy hash-password`, so the whole enable → reuse → change → disable path runs offline.
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
AUTH_LOG="$V/auth-docker.log"

# (1) ENABLE: a password turns on basic_auth — hash + fingerprint persisted, plaintext never stored.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":0}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" > "$V/config.json"
: > "$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "auth enable applies cleanly" "$rc" "0"
assert_eq "auth username persisted" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_USER)" "admin"
hash1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)"
fp1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)"
[ -n "$hash1" ] && ok "auth hash persisted (base64)" || bad "auth hash persisted (base64)" "empty"
[ -n "$fp1" ]   && ok "auth fingerprint persisted"   || bad "auth fingerprint persisted"   "empty"
assert_contains "auth hashed via the pinned caddy image" "$(cat "$AUTH_LOG")" "hash-password"
assert_contains "Caddyfile gains basic_auth"             "$(cat "$V/Caddyfile")" "basic_auth"
case "$(cat "$V/.env" "$V/Caddyfile")" in
    *hunter2hunter2*) bad "auth plaintext never persisted" "password leaked into .env/Caddyfile" ;;
    *)                ok  "auth plaintext never persisted" ;;
esac

# (2) REUSE: re-applying (here nudging an unrelated knob) keeps the SAME hash and does NOT re-hash —
# bcrypt is salted, so a stable fingerprint is what keeps the Caddyfile from churning every apply.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" > "$V/config.json"
: > "$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "unchanged password keeps the same hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" "$hash1"
case "$(cat "$AUTH_LOG")" in
    *hash-password*) bad "unchanged password is not re-hashed" "caddy hash-password was called again" ;;
    *)               ok  "unchanged password is not re-hashed (stable hash)" ;;
esac

# (3) CHANGE: a new password re-hashes (fingerprint changes) and recreates the caddy container.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"freshpass99"}} }\n' "$WALLET" > "$V/config.json"
: > "$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "changed password re-hashes"     "$(cat "$AUTH_LOG")" "hash-password"
assert_eq "changed password updates fingerprint" "$([ "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)" != "$fp1" ] && echo changed)" "changed"
assert_contains "auth change recreates caddy"     "$(cat "$AUTH_LOG")" "restart caddy"

# (4) DISABLE: clearing the password drops basic_auth — hash cleared, dashboard reachable again.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "auth disable clears the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" ""
case "$(cat "$V/Caddyfile")" in
    *basic_auth*) bad "auth disable drops basic_auth" "basic_auth still present in the Caddyfile" ;;
    *)            ok  "auth disable drops basic_auth" ;;
esac

echo "== black-box: apply preserves secrets + propagates =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
DOCKER_LOG="$V/docker.log"; : > "$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "pool flag propagated"  "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_FLAGS)"  "--mini"
assert_eq "stratum_bind default"  "$(run_sourced "$V" env_get_file "$V/.env" STRATUM_BIND)" "0.0.0.0"
assert_eq "token preserved"       "$(run_sourced "$V" env_get_file "$V/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
assert_eq "onion preserved"       "$(run_sourced "$V" env_get_file "$V/.env" P2POOL_ONION_ADDRESS)" "p2pa.onion"
assert_eq "tari_required default"  "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"
# The new-release check (#224) defaults ON when absent from config — it's Tor-routed, so it leaks
# nothing, and an operator who wants zero GitHub contact sets check_for_updates:false to opt out.
assert_eq "check_for_updates default on" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "true"
# Both new xmrig-proxy knobs default to OFF/no-fee when absent from config (#152/#173).
assert_eq "stratum auth off by default"        "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" ""
assert_eq "donate-level 0 by default (no fee)"  "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "0"
# Build provenance is exported for the build args, not persisted to .env (Issue #58) — so a git pull
# never shows up as a config change. Assert it stays out of the rendered .env.
assert_eq "provenance not written to .env" "$(run_sourced "$V" env_get_file "$V/.env" PITHEAD_VERSION)" ""
assert_contains "compose up called (build mode)" "$(cat "$DOCKER_LOG")" "compose up --pull never -d --remove-orphans"

# Regression (Issue #58): a second apply with nothing changed must report no changes and exit 0
# cleanly — never tripping the ERR trap. (Provenance keys briefly leaked into this diff; when they
# were the only delta the filter emptied the pipeline and `set -o pipefail` aborted apply.)
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
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
    *m) n="${mem%m}"
        if [ "$n" -ge 2048 ] && { [ "$host_ram_mb" -le 0 ] || [ "$n" -le "$host_ram_mb" ]; }
        then ok "tari mem auto is a sane ceiling ($mem, host ${host_ram_mb}m)"
        else bad "tari mem auto sane ceiling" "got [$mem] on ${host_ram_mb}m host"; fi ;;
    *) bad "tari mem auto has m suffix" "got [$mem]" ;;
esac

# Non-blocking Tari (dashboard.tari_required:false) propagates as TARI_REQUIRED=false.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","tari_required":false} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari_required propagated false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

# Opting out (dashboard.check_for_updates:false) propagates as DASHBOARD_CHECK_UPDATES=false (#224) —
# only an explicit false disables it (anything else, incl. absent, stays the default-on true).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan","check_for_updates":false} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "check_for_updates opt-out propagated false" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_CHECK_UPDATES)" "false"

# An explicit tari.mem_limit is passed through verbatim (overriding the "auto" host-RAM scaling).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T","mem_limit":"3072m"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari mem_limit explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" "3072m"

echo "== black-box: xmrig-proxy knobs (#152 stratum auth, #173 donate-level) =="
# stratum_password "auto" generates + persists a stable secret and surfaces it for rigs; an explicit
# proxy.donate_level propagates verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "proxy":{"donate_level":1}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
sp1="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
case "$sp1" in ?*) ok "stratum_password auto generated a secret" ;; *) bad "stratum_password auto generated a secret" "got empty" ;; esac
assert_eq "donate-level explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "1"
assert_contains "stratum auth surfaced for rigs" "$(run_sourced "$V" announce_stratum_auth 2>&1)" "Stratum authentication is ON"
# Re-apply: an "auto" password must be STABLE (reused, not rotated) — like the proxy token.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_password auto stable across apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "$sp1"

echo "== black-box: local node creds auto-generated + persisted (#50) =="
# A local node with BLANK creds: apply must generate them, write them into .env AND back into
# config.json, and keep them stable on a second apply (don't regenerate every run).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"","node_password":""}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "auto-gen is logged" "$out" "Auto-generated missing local"
env_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
assert_eq "blank username -> admin in .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" "admin"
assert_eq "generated password is 32 chars"  "${#env_pass}" "32"
assert_eq "username persisted to config.json" "$(jq -r '.monero.node_username' "$V/config.json")" "admin"
assert_eq "password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"
# Second apply must not rotate the now-populated creds.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "password stable across apply" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"

# A REMOTE node with blank creds means "no auth" — leave it empty, don't invent credentials.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote username left blank" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" ""
assert_eq "remote creds not persisted" "$(jq -r '.monero.node_username' "$V/config.json")" ""

echo "== black-box: upgrade re-renders generated config (#128) =="
# `upgrade` used to be just `up --build`, leaving the generated .env/Caddyfile/Tari config stale
# after a git pull. It must now re-render them while preserving secrets.
U="$SANDBOX/upgrade"; mkdir -p "$U/build/tari" "$U/build/dashboard" "$U/data/monero" "$U/data/tari" "$U/data/p2pool/stats" "$U/data/tor" "$U/data/dashboard"; : > "$U/build/dashboard/Dockerfile"
cp "$STACK" "$U/pithead"; make_stubs "$U/bin"; cp "$ROOT/build/tari/config.toml.template" "$U/build/tari/"
# Stale .env: secrets present, but STRATUM_BIND (a rendered var) is missing — the upgrade must fill it.
cat > "$U/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$U/config.json"
UL="$U/docker.log"; : > "$UL"
out="$(cd "$U" && DOCKER_LOG="$UL" PATH="$U/bin:$PATH" ./pithead upgrade 2>&1)"; rc=$?
assert_rc "upgrade exits 0" "$rc" "0"
assert_eq "upgrade re-renders a missing var (STRATUM_BIND)" "$(run_sourced "$U" env_get_file "$U/.env" STRATUM_BIND)" "0.0.0.0"
assert_eq "upgrade preserves the proxy token"               "$(run_sourced "$U" env_get_file "$U/.env" PROXY_AUTH_TOKEN)" "ORIGINALTOKEN"
# render_env writes DEPLOYMENT_COMPLETED=${DEPLOYMENT_COMPLETED:-false} and load_preserved_state
# doesn't carry it, so upgrade must re-assert it — else the flag flips to false and the NEXT
# require_deployed command (up/apply/upgrade) errors "run setup" on an already-deployed box.
assert_eq "upgrade preserves DEPLOYMENT_COMPLETED (require_deployed survives)" "$(run_sourced "$U" env_get_file "$U/.env" DEPLOYMENT_COMPLETED)" "true"
assert_contains "upgrade still rebuilds images (source mode)" "$(cat "$UL")" "compose up --pull never -d --build"

echo "== black-box: apply recovers from a failed 'compose up' (#125) =="
# A docker stub that fails `compose up -d --remove-orphans` only when FAIL_UP=1 (else succeeds).
A="$SANDBOX/applyfail"; mkdir -p "$A/build/tari" "$A/build/dashboard" "$A/bin" "$A/data/monero" "$A/data/tari" "$A/data/p2pool/stats" "$A/data/tor" "$A/data/dashboard"
: > "$A/build/dashboard/Dockerfile"   # source-checkout marker → pithead builds (--pull never), #44
cp "$STACK" "$A/pithead"; cp "$ROOT/build/tari/config.toml.template" "$A/build/tari/"
cat > "$A/bin/docker" <<'EOF'
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$A/bin/sudo"; chmod +x "$A/bin/docker" "$A/bin/sudo"
cat > "$A/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" > "$A/config.json"
# First apply: real config delta committed, but `compose up` FAILS -> marker left, rc 1, guidance.
out="$(cd "$A" && FAIL_UP=1 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "apply fails (rc 1) when compose up fails" "$rc" "1"
assert_contains "apply prints recovery guidance"     "$out" "were NOT recreated"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi; assert_eq "apply leaves the incomplete marker" "$mk" "present"
# Second apply: config already committed (no delta), but the marker forces a retry, not a silent no-op.
out="$(cd "$A" && FAIL_UP=0 PATH="$A/bin:$PATH" ./pithead apply -y 2>&1)"; rc=$?
assert_rc "re-apply retries and succeeds (rc 0)"          "$rc" "0"
assert_contains "re-apply re-attempts the recreate"      "$out" "retrying"
if [ -f "$A/.env.apply-incomplete" ]; then mk=present; else mk=absent; fi; assert_eq "marker cleared after a successful retry" "$mk" "absent"

echo "== black-box: up warns about missing (relocated) data dirs (#126) =="
RL="$SANDBOX/reloc"; mkdir -p "$RL/bin"; cp "$STACK" "$RL/pithead"; make_stubs "$RL/bin"
# Deployed, but .env names data dirs that don't exist — as if the install was moved/copied or a
# second checkout is being run. The stack would silently re-sync; `up` must warn first.
cat > "$RL/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
MONERO_DATA_DIR=/no/such/data/monero
TARI_DATA_DIR=/no/such/data/tari
P2POOL_DATA_DIR=/no/such/data/p2pool
DASHBOARD_DATA_DIR=/no/such/data/dashboard
TOR_DATA_DIR=/no/such/data/tor
EOF
out="$(cd "$RL" && PATH="$RL/bin:$PATH" ./pithead up 2>&1)"; rc=$?
assert_rc "up still starts (rc 0)"               "$rc" "0"
assert_contains "up warns about a fresh re-sync" "$out" "start a FRESH sync"
assert_contains "up names the missing monero dir" "$out" "MONERO_DATA_DIR → /no/such/data/monero"
# A healthy deployment (dirs present) must NOT warn.
mkdir -p "$RL/d/monero" "$RL/d/tari" "$RL/d/p2pool" "$RL/d/dashboard" "$RL/d/tor"
cat > "$RL/.env" <<EOF
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
printf 'MONERO_DATA_DIR=/no/such/monero\n' > "$RL/.env"
assert_eq "missing_data_dirs silent before first deploy" "$(run_sourced "$RL" missing_data_dirs)" ""

echo "== black-box: status health check =="
# A docker stub driven by FAKE_STATES ("svc=state:health ..."; state "missing" = no container)
# so we can script each service's state and assert how `status` reports it.
make_status_stub() {
    local bin="$1"; mkdir -p "$bin"
    cat > "$bin/docker" <<'EOF'
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
ST="$SANDBOX/status"; mkdir -p "$ST/bin"; cp "$STACK" "$ST/pithead"
make_status_stub "$ST/bin"
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' > "$ST/.env"
ALL_UP="tor=running:healthy monerod=running:healthy p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"

# All services up -> success, friendly summary.
out="$(cd "$ST" && FAKE_STATES="$ALL_UP" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"; rc=$?
assert_rc "status: all up exits 0" "$rc" "0"
assert_contains "status: all-up summary" "$out" "All expected services are up"

# A node down + proxy stopped -> node flagged, proxy treated as intentional failover.
NODE_DOWN="${ALL_UP/monerod=running:healthy/monerod=exited:none}"; NODE_DOWN="${NODE_DOWN/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$NODE_DOWN" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"; rc=$?
assert_rc "status: node down exits 1" "$rc" "1"
assert_contains "status: proxy stop is intentional" "$out" "likely intentional"

# A stopped p2pool/xmrig-proxy with healthy nodes is intentional — the nodes pass their
# healthchecks while still syncing and the dashboard holds the miner until they're synced
# (#35), so status reports it as likely-intentional (exit 0), not a fault.
PROXY_ONLY="${ALL_UP/xmrig-proxy=running:none/xmrig-proxy=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$PROXY_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"; rc=$?
assert_rc "status: proxy stop under sync hold exits 0" "$rc" "0"
assert_contains "status: proxy stop notes sync hold" "$out" "finish syncing"

P2POOL_ONLY="${ALL_UP/p2pool=running:none/p2pool=exited:none}"
out="$(cd "$ST" && FAKE_STATES="$P2POOL_ONLY" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"; rc=$?
assert_rc "status: p2pool stop under sync hold exits 0" "$rc" "0"
assert_contains "status: p2pool stop notes sync hold" "$out" "finish syncing"

# Remote-node mode: the bundled monerod is not expected even if absent.
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=\nHOST_IP=box.lan\n' > "$ST/.env"
REMOTE="tor=running:healthy monerod=missing p2pool=running:none tari=running:healthy xmrig-proxy=running:none dashboard=running:none docker-proxy=running:none docker-control=running:none caddy=running:none"
out="$(cd "$ST" && FAKE_STATES="$REMOTE" PATH="$ST/bin:$PATH" ./pithead status 2>&1)"; rc=$?
assert_rc "status: remote mode ignores monerod" "$rc" "0"

echo "== black-box: doctor exit code (#127) =="
# doctor must EXIT NON-ZERO when a critical check fails, so it's usable as a cron/CI health gate
# (it previously always returned 0). Drive one failure via an unreachable Docker daemon; jq/openssl
# stay real on PATH so only the daemon check fails.
DOC="$SANDBOX/doctor"; mkdir -p "$DOC/bin"; cp "$STACK" "$DOC/pithead"
cat > "$DOC/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "info") exit 1 ;;   # daemon unreachable -> doctor records a critical FAIL
  *)      exit 0 ;;   # `--version`, `compose version`, etc. succeed
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$DOC/bin/sudo"
chmod +x "$DOC/bin/docker" "$DOC/bin/sudo"
out="$(cd "$DOC" && PATH="$DOC/bin:$PATH" ./pithead doctor 2>&1)"; rc=$?
assert_contains "doctor runs to the summary"          "$out" "Diagnostics summary"
assert_contains "doctor flags the unreachable daemon" "$out" "Docker daemon is not reachable"
assert_rc       "doctor exits 1 on a critical FAIL"   "$rc" "1"

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
BK="$(cd "$SANDBOX" && pwd -P)/backup"; mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
cp "$STACK" "$BK/pithead"; cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
cat > "$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;;   # empty output -> stack treated as not running
esac
exit 0
EOF
cat > "$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run backup/restore's privileged commands as the test user, except chown (can't set 100:101
# unprivileged) which is accepted as a no-op so restore doesn't abort.
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/docker" "$BK/bin/sudo"
cat > "$BK/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=BKTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"T"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" > "$BK/config.json"
printf 'CADDY-ORIG\n'    > "$BK/Caddyfile"
printf 'ONIONKEY-ORIG\n' > "$BK/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n'    > "$BK/data/dashboard/dashboard.db"

# 1) Backup creates a timestamped archive.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"; rc=$?
assert_rc "backup exits 0" "$rc" "0"
archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$archive" ] && [ -f "$archive" ]; } && ok "backup archive created" || bad "backup archive created" "no archive under backups/"

# 2) Archive layout: the irreplaceable bits are in it; blockchains are NOT (no --with-chains).
listing="$(tar -tzf "$archive" 2>/dev/null)"
assert_contains "archive has config.json"      "$listing" "config.json"
assert_contains "archive has .env"             "$listing" ".env"
assert_contains "archive has Caddyfile"        "$listing" "Caddyfile"
assert_contains "archive has the tor onion key" "$listing" "hs_ed25519_secret_key"
assert_contains "archive has the dashboard db" "$listing" "dashboard.db"
case "$listing" in
    *data/monero*|*data/p2pool/*|*data/tari*) bad "archive excludes blockchains by default" "chain data present without --with-chains" ;;
    *)                                        ok  "archive excludes blockchains by default" ;;
esac
# Safety tripwire: every archived path is under the sandbox, so restore's `tar -C /` can't escape it.
sandbox_rel="${BK#/}"
escaped="$(printf '%s\n' "$listing" | grep -v '^$' | grep -v "^$sandbox_rel" || true)"
assert_eq "archive paths stay inside the sandbox" "$escaped" ""

# 3) Round-trip: corrupt/delete the live files, restore, assert the originals come back in place.
printf 'CORRUPTED\n' > "$BK/Caddyfile"
printf 'CORRUPTED\n' > "$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"; rc=$?
assert_rc "restore exits 0" "$rc" "0"
assert_eq "restore brings back the Caddyfile"     "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "restore brings back the dashboard db"  "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "restore brings back the onion key"     "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4) Low-space pre-check (#127): a df reporting almost no free space makes backup prompt; answering
# "no" cancels and writes nothing, while --yes proceeds with a warning. The check runs BEFORE the
# stack is touched, so a cancel leaves everything as it was.
cat > "$BK/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/fake 100 99 1 99% /'
EOF
chmod +x "$BK/bin/df"
rm -f "$BK"/backups/pithead-backup-*.tar.gz
out="$(cd "$BK" && printf 'n\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"; rc=$?
assert_rc       "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first"         "$out" "Low free space"

echo "== black-box: reset-dashboard targets .env dirs, not config.json (#139) =="
# reset-dashboard must wipe the LIVE deployment's data dirs (from .env), not a path the user may
# have edited into config.json without applying. docker = noop; sudo only LOGS (never executes the
# rm), so we can assert what it would have targeted without deleting anything.
R="$SANDBOX/reset"; mkdir -p "$R/bin" "$R/envdir/dashboard" "$R/envdir/p2pool"; cp "$STACK" "$R/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/bin/docker"
cat > "$R/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >> "${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$R/bin/docker" "$R/bin/sudo"
cat > "$R/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$R/envdir/dashboard
P2POOL_DATA_DIR=$R/envdir/p2pool
EOF
# config.json points the data dirs somewhere ELSE (a path the running stack never used).
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"T"}, "p2pool":{"data_dir":"%s/CONFIGONLY/p2pool"}, "dashboard":{"data_dir":"%s/CONFIGONLY/dashboard"} }\n' "$WALLET" "$R" "$R" > "$R/config.json"
SUDO_LOG="$R/sudo.log"; : > "$SUDO_LOG"
out="$(cd "$R" && SUDO_LOG="$SUDO_LOG" PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"; rc=$?
assert_rc "reset-dashboard succeeds" "$rc" "0"
sudo_calls="$(cat "$SUDO_LOG")"
assert_contains "reset rm targets the .env dashboard dir" "$sudo_calls" "rm -rf $R/envdir/dashboard"
case "$sudo_calls" in *CONFIGONLY*) bad "reset must ignore the config-only data_dir" "$sudo_calls" ;; *) ok "reset ignores the config-only data_dir" ;; esac

echo "== black-box: reset-dashboard refuses to guess without .env dirs (#139) =="
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' > "$R/.env"
out="$(cd "$R" && SUDO_LOG=/dev/null PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"; rc=$?
assert_rc "reset refuses with no data dirs in .env" "$rc" "1"
assert_contains "reset refuse message" "$out" "refusing to guess"

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[1;31m%d failed\033[0m\n' "$FAIL"; exit 1; fi
printf '0 failed\n'
