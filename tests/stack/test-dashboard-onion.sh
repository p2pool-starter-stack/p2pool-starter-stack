# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Dashboard-onion domain (#1105 Phase 1, develop-v2 lane): the dashboard-onion cluster stacked on
# test-dashboard.sh — generate_caddyfile's onion vhost render (the bridge-gateway HTTP site plus,
# once the .onion address is provisioned, its own self-signed HTTPS vhost, #343), the shared
# access-log render across ALL vhosts (LAN + onion HTTP + onion HTTPS, #349), the onion client-auth
# crypto (portable base32, the x25519 keypair, provision_onion_client_auth's authorized_clients
# descriptor and its 0700/0700/0600 mode discipline), ensure_onion_password's fail-closed
# auto-generated password (both directly and through stack_upgrade, which must run it BEFORE
# validation), the rotate-dashboard-onion command flow (resolving the host before render_env,
# preserving DEPLOYMENT_COMPLETED), the upgrade/apply/rotate capture flows that must re-render the
# Caddyfile in the SAME run rather than waiting on a later, possibly-no-op apply (#356/#546), and
# dashboard_onion_status's status/doctor resolver (the onion URL + reach-it hint, never the client
# private key, #343).
# Sourced by tests/stack/run.sh, conventionally after test-dashboard.sh — but not required (#1330):
# $auth_hb64 and $caddy_https used to be globals left behind there, so a reordered/inserted source
# line broke this file with a confusing empty-string mismatch. Both are re-derived locally below.
#
# Everything else below sources the real $STACK fresh per subshell against a throwaway dir under
# $SANDBOX (or a dedicated dir under it, e.g. the rotate-Caddyfile-seed fixtures), and touches
# neither $C nor its control-sandbox children ($REQS/$RESULTS/$STAGED/$AUDIT/$MASKED) — several of
# the black-box flows here explicitly stub provision_control_runner (and the rest of apply's/
# upgrade's heavy machinery) to a no-op precisely to keep this file's proof self-contained; the real
# control-channel/control-runner build lives in the "dashboard control channel" section, moved to
# test-control-core.sh by #1105 R12 and sourced well after.

echo "== unit: generate_caddyfile onion vhost (#343) =="
auth_hb64="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)" # re-derivation (#1330), see header
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
# shellcheck disable=SC1090  # STACK path is dynamic by design; re-derivation (#1330), see header
caddy_https="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
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
