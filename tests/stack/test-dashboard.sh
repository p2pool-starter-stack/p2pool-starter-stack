# shellcheck shell=bash
#
# Dashboard domain (#1105 Phase 1, develop-v2 lane): the dashboard's own login (Caddy basic_auth
# enable/disable/change previews plus the actual basic_auth block in the rendered Caddyfile, #8),
# generate_caddyfile's scheme/port/Host-header render (secure vs. plain HTTP; a custom HOST_PORT
# moving the vhost off 80/443; the :80 redirect's and :443's own catch-alls so an unmatched Host
# never falls through to Caddy's silent empty-200 default, #1123/#1132/#740), the v2 global-address
# guard that keeps a globally-routable address off both the site list AND the `bind` line — Caddy
# runs a single wildcard listener that matches on Host content alone, so filtering the site list is
# not sufficient — and dashboard_sync_progress's one-curl re-render of /api/state behind `pithead
# status` (#384).
#
# The dashboard-onion cluster (vhost render, client-auth crypto, rotate/upgrade/apply capture
# flows, status) is its own domain in test-dashboard-onion.sh, stacked on this file: it is sourced
# immediately after this one in run.sh and reads two globals this file sets ($auth_hb64, the bcrypt
# hash fixture from the dashboard-auth unit test; $caddy_https, the plain secure-mode Caddyfile
# render from the scheme unit test) — plain top-level assignments, so they survive the handoff
# between the two sourced files in the same shell. Do not reorder the two `source` lines in run.sh.
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; the "config validation" black-box calls
#   it once, but that section lives in test-config.sh, sourced AFTER this file — so nothing has
#   built $V by the time the dashboard-auth-lifecycle black-box below runs (docker-compose.yml
#   copy, .env/config.json writes via `seed_env`, $V/bin stubs), so this file needs its own copy.
#   build_val_sandbox() is idempotent (a fixed $SANDBOX/val path, mkdir -p, template copies), so
#   calling it again here is a safe no-op re-affirm, the same re-derivation test-lifecycle.sh uses.
# - Everything else below sources the real $STACK fresh per subshell against a throwaway dir under
#   $SANDBOX and needs no re-derivation: none of it reads or writes the shared $C control sandbox
#   ($REQS/$RESULTS/$STAGED/$AUDIT/$MASKED) — that is not built until the "dashboard control
#   channel" section in test-control-core.sh, sourced after this file and test-dashboard-onion.sh.
build_val_sandbox

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

echo "== unit: generate_caddyfile never publishes or binds a globally-routable address =="
# The appliance auto-publishes every address `hostname -I` reports, so on any network passing IPv6
# through, a GLOBAL unicast address was silently added — the control panel reachable from the open
# internet with nothing but the operator's router in the way. Filtering the SITE LIST is necessary
# and NOT sufficient: Caddy runs host-networked and opens ONE WILDCARD listener (`*:443`, observed
# on the bench), and it matches on Host content, never on which interface a connection arrived on
# — so a client reaching the box on the global address only has to send a Host header naming an
# address that IS listed. `bind` is the actual boundary. Addresses below are the real set from the
# physical appliance, written with reserved stand-ins: LAN v4, two podman bridge gateways, a
# globally-scoped v6 (2001:db8::/32, RFC 3849) and a ULA (fd00::/8).
_caddy_appliance() { # $1 = value for DASHBOARD_EXPOSE_PUBLIC_IP
    # shellcheck disable=SC1090  # STACK path is dynamic by design
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1 2001:db8::1 fd00::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        DASHBOARD_EXPOSE_PUBLIC_IP="$1" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
}
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_default="$(_caddy_appliance false)"
case "$caddy_default" in
*2001:db8:*) bad "the global v6 is not published as a site" "the global address appears in the Caddyfile" ;;
*) ok "the global v6 is not published as a site" ;;
esac
assert_contains "the LAN address is still published" "$caddy_default" "192.168.1.10"
assert_contains "the ULA is still published — private scope, not routable" "$caddy_default" "fd00::1"
assert_contains "a bind line closes the wildcard listener" "$caddy_default" "    bind "
assert_contains "bind keeps loopback for the host-networked dashboard" "$caddy_default" "127.0.0.1 ::1"
# The bind line is the boundary — it specifically must not carry the global address.
bindline=$(printf '%s' "$caddy_default" | grep '^    bind ')
case "$bindline" in
*2001:db8:*) bad "the bind line excludes the global v6" "global address present in: $bindline" ;;
*) ok "the bind line excludes the global v6" ;;
esac
# The bind directive must stand ALONE on its line. `$(...)` strips trailing newlines, so emitting
# one inside the helper silently glued the next directive on: `bind ... ::1    basic_auth {`,
# which Caddy will not parse — a config that would have taken the dashboard down. Caught on the
# bench, not here, so pin the shape: nothing may follow the last bound address.
case "$bindline" in
*"::1") ok "the bind directive stands alone on its line" ;;
*) bad "the bind directive stands alone on its line" "another directive was glued on: $bindline" ;;
esac
# Opt-in restores the old behaviour for a deployment that genuinely wants it.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_optin="$(_caddy_appliance true)"
assert_contains "the opt-in publishes the global v6 again" "$caddy_optin" "2001:db8::1"
case "$caddy_optin" in
*"    bind "*) bad "the opt-in leaves the listener open" "a bind line was still emitted" ;;
*) ok "the opt-in leaves the listener open" ;;
esac
# An operator who PINS dashboard.host is the most deliberately-configured box there is, and the
# first cut of this fix left exactly those boxes wide open: the bind was derived from the
# auto-expanded site list, so pinning the host produced a single-host site list and NO bind — the
# wildcard listener, and the whole exposure, back again. The bind is built from the BOX's
# addresses now, never from the site list, because they answer different questions: which Host
# values Caddy matches, versus which sockets it opens.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_pinned="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 2001:db8::1 fd00::1\n'; }
    # Pinned to a NAME (the documented appliance case, #1089), not an IP literal: an
    # IP-literal pin puts the box's own address INTO the site list too, so a bind built
    # from the site list and a bind built from the box's addresses render identically —
    # the mutation this test exists to catch (bind derived from $site_hosts instead of
    # `hostname -I`) stayed green against that fixture. A name-only pin gives the site
    # list no address literal at all, so the two derivations diverge.
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_HOST=pithead.local \
        DASHBOARD_AUTH_HASH_B64="" generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "a pinned dashboard.host still gets a bind" "$caddy_pinned" "    bind "
case "$(printf '%s' "$caddy_pinned" | grep '^    bind ')" in
*2001:db8:*) bad "a pinned host does not reopen the global v6" "global address is bound" ;;
*) ok "a pinned host does not reopen the global v6" ;;
esac
# The bind must come from the BOX's own addresses, never from the (name-only) site list —
# #1021-class regression. Assert the bind line names the box's actual LAN address; under
# the site-list-derived mutation it collapses to loopback-only and this goes red.
assert_contains "a pinned dashboard.host still binds the box's own LAN address" "$(printf '%s' "$caddy_pinned" | grep '^    bind ')" "192.168.1.10"

# Loopback is appended outside the address loop, so a box reporting no usable non-public address
# still binds something reachable rather than silently falling back to a wildcard.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_noaddr="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '2001:db8::1\n'; } # ONLY a public address
    DASHBOARD_SECURE=true HOST_IP=pithead.local DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "a box with only a public address still binds loopback" "$caddy_noaddr" "    bind 127.0.0.1 ::1"

# The onion vhost must bind exactly when the LAN vhost does. A site block with no bind asks for a
# WILDCARD listener, which reopens every address the bound blocks exclude — including the
# globally-routable one. (It does NOT crash Caddy: SO_REUSEPORT lets a wildcard and a specific
# listener share a port, measured against the pinned image. The hazard is the socket, not a
# startup failure.) dashboard.secure:false with the onion enabled is documented and exempted from
# the insecure-transport warning, so this combination is reachable today.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # site blocks/binds are under test, not cert minting
    hostname() { printf '192.168.1.10 2001:db8::1\n'; }
    DASHBOARD_SECURE=false HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "insecure+onion: both vhosts bind, never one wildcard and one specific" \
    "$(printf '%s' "$caddy_onion" | grep -c '^    bind ')" "2"

# The invariant, checked by counting rather than by naming the blocks: EVERY site block in the
# rendered file carries a bind, or none does. A hardcoded count only proves the blocks that
# happened to render, and that is exactly how the HTTPS onion vhost shipped unbound — it renders
# only once DASHBOARD_ONION holds a provisioned address, so every test that left it empty saw a
# correct file. `_site_count` counts site openers (a line starting at column 0 and ending in `{`);
# the global options block opens with a bare `{`, which the leading-character class excludes.
_site_count() { printf '%s' "$1" | grep -cE '^[^[:space:]{].*\{[[:space:]]*$'; }
_bind_count() { printf '%s' "$1" | grep -c '^    bind '; }
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_tls_dir() { printf '%s' "$SANDBOX/notls"; }
    appliance_mint_cert() { return 1; }
    hostname() { printf '192.168.1.10 2001:db8::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcdefghij234567.onion \
        DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
# Six blocks since #1123 took :80 over and #1132 took :443's own empty-200 default: the two LAN
# vhosts (the known-host :80 redirect and the HTTPS one), the :80 catch-all, the :443 catch-all,
# and the two onion vhosts. The number is worth pinning rather than deriving — it is what caught
# the redirect blocks arriving without anyone re-counting.
assert_eq "secure+onion+provisioned: the HTTPS onion vhost renders (6 site blocks)" \
    "$(_site_count "$caddy_onion_https")" "6"
assert_eq "secure+onion+provisioned: every site block binds — no unbound wildcard on :443" \
    "$(_bind_count "$caddy_onion_https")" "$(_site_count "$caddy_onion_https")"

# Counting binds proves every block HAS one; it says nothing about the VALUE, and a widened bind
# is the same exposure as a missing one. `bind 0.0.0.0 ::` on the onion blocks satisfies the count
# assertion above exactly, and reopens every address #1021 closed. So pin what the onion vhosts
# bind: the container-bridge gateway the Tor daemon dials them on, and nothing else. Both onion
# blocks (plain HTTP and the HTTPS one on the .onion name) render from _onion_bind_line, so the
# expected count is 2 — widening either one takes this to 0.
assert_eq "secure+onion+provisioned: the onion vhosts bind the bridge gateway, not a wildcard" \
    "$(printf '%s' "$caddy_onion_https" | grep -c '^    bind 172\.28\.0\.1$')" "2"
# The same invariant on the binding-off side: a DIY host renders the same three blocks and binds
# none of them, so there is still no mixed wildcard/specific pair.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_https_diy="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 1; }
    hostname() { printf '192.168.1.10\n'; }
    DASHBOARD_SECURE=true HOST_IP=box.lan NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcdefghij234567.onion \
        DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "DIY secure+onion+provisioned: no site block binds" \
    "$(_bind_count "$caddy_onion_https_diy")" "0"

# No two site blocks may name the same scheme://address. Caddy rejects the WHOLE file with
# "ambiguous site definition" and, under Restart=always, crash-loops — dashboard and onion down
# together. This is reachable because `hostname -I` reports the container-bridge gateway (it is a
# real host address), so it landed in the auto-expanded LAN list AND in the onion block, which
# serves on exactly that address. With dashboard.secure:false the two schemes match and the file
# is unadaptable. Counting binds cannot see this, which is why it is a separate structural check:
# these two assertions together are the cheap tier-1 stand-in for the real `caddy adapt` gate
# tracked in #1037.
_dupe_sites() {
    printf '%s' "$1" | grep -E '^[^[:space:]{].*\{[[:space:]]*$' |
        sed 's/[[:space:]]*{[[:space:]]*$//' | tr ',' '\n' | tr -d ' ' | grep -v '^$' |
        sort | uniq -d
}
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_insecure_onion_gw="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # site blocks/dupes are under test, not cert minting
    # The physical appliance set: LAN address plus BOTH podman bridge gateways, as documented above.
    hostname() { printf '192.168.1.10 10.89.0.1 172.28.0.1\n'; }
    DASHBOARD_SECURE=false HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "insecure+onion on a real appliance: no duplicate site definition" \
    "$(_dupe_sites "$caddy_insecure_onion_gw")" ""
# The gateway belongs to the onion vhost alone — it must not appear in the LAN block at all.
case "$(printf '%s' "$caddy_insecure_onion_gw" | head -1)" in
*172.28.0.1*) bad "the bridge gateway stays out of the LAN site list" "gateway present in: $(printf '%s' "$caddy_insecure_onion_gw" | head -1)" ;;
*) ok "the bridge gateway stays out of the LAN site list" ;;
esac
# And with binding off, NEITHER may bind — the mirror of the case above.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_onion_off="$(
    # shellcheck disable=SC1090
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 1; } # DIY: no binding at all
    hostname() { printf '192.168.1.10\n'; }
    DASHBOARD_SECURE=false HOST_IP=box.lan NETWORK_PREFIX=172.28.0 \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_AUTH_USER=admin \
        DASHBOARD_AUTH_HASH_B64="$(printf 'x' | openssl base64 -A)" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_eq "DIY insecure+onion: neither vhost binds — no wildcard/specific clash" \
    "$(printf '%s' "$caddy_onion_off" | grep -c '^    bind ')" "0"
unset -f _caddy_appliance
unset -f _site_count _bind_count
unset -f _dupe_sites
unset caddy_default caddy_optin bindline caddy_pinned caddy_noaddr caddy_onion caddy_onion_off caddy_onion_https caddy_onion_https_diy caddy_insecure_onion_gw

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
# header, so the provisioned appliance answered `Host: evil.example` on :80 with
# `308 -> https://evil.example` — measured against the real hardware. That is #1118's open
# redirector again, in the state the machine spends its life in, landing on the screen where the
# operator types the dashboard password. The render now owns :80 itself.
#
# Two blocks, not one: the KNOWN hosts keep the address the operator typed (browsing by mDNS name
# and by IP each stay on the name they used, which is also the name the certificate covers), and a
# trailing catch-all answers everything else with THIS box's canonical address.
#
# MUTATION PROOF: point the catch-all at {host}, and the two "not from the request" assertions go
# red; drop $(_bind_line) from either block and the bind assertion goes red; drop the
# disable_redirects and the takeover assertion goes red.
# shellcheck disable=SC1090  # STACK path is dynamic by design
caddy_redir="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    is_appliance() { return 0; }
    appliance_mint_cert() { return 1; } # the :80 redirect shape is under test, not cert minting
    hostname() { printf '192.168.1.10 172.28.0.1 fd00::1\n'; }
    DASHBOARD_SECURE=true HOST_IP=pithead.local NETWORK_PREFIX=172.28.0 DASHBOARD_AUTH_HASH_B64="" \
        generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
assert_contains "the default secure render takes :80 over from auto_https" "$caddy_redir" "auto_https disable_redirects"
assert_contains "the known hosts get their own :80 site" "$caddy_redir" "http://pithead.local, http://192.168.1.10"
assert_contains "and keep the address the operator actually used" "$caddy_redir" "redir https://{host}{uri} 308"
assert_contains "everything else lands on this box, by name" "$caddy_redir" "redir https://pithead.local{uri} 308"
# The defect itself: the CATCH-ALL — the block a forged Host reaches — must never build its target
# from the request. The known-host block may, because it only matches names this box answers to.
caddy_catchall="$(printf '%s\n' "$caddy_redir" | sed -n '/^http:\/\/ {/,/^}/p')"
assert_contains "the catch-all exists" "$caddy_catchall" "redir https://"
case "$caddy_catchall" in
*"{host}"* | *"{http.request.host}"*) bad "the catch-all target never comes from the request" "it interpolates the request host: $caddy_catchall" ;;
*) ok "the catch-all target never comes from the request" ;;
esac
# #1021: a site block with NO bind asks Caddy for a WILDCARD listener, which reopens every address
# the bound blocks exclude — the globally-routable one included. All new catch-alls are site blocks.
# Four site blocks in this render — the two new :80 ones, the new :443 one (#1132), and the HTTPS
# LAN vhost — so four binds.
assert_eq "every site block carries the bind, including both :80 catch-alls and the :443 one" \
    "$(printf '%s\n' "$caddy_redir" | grep -c 'bind 192.168.1.10 172.28.0.1 fd00::1 127.0.0.1 ::1')" "4"
# A custom port means a fronting proxy owns :80 (#740). Claiming it there breaks the co-hosting the
# option exists for.
case "$caddy_port_https" in
*"http:// {"*) bad "a custom port leaves :80 to the fronting proxy" "the render claimed :80 anyway" ;;
*) ok "a custom port leaves :80 to the fronting proxy" ;;
esac
# Plain-HTTP mode has no redirect to steer: :80 IS the dashboard there.
case "$caddy_http" in
*"redir"*) bad "plain-HTTP mode renders no redirect at all" "a redir line appeared on a plain-HTTP site" ;;
*) ok "plain-HTTP mode renders no redirect at all" ;;
esac

echo "== unit: the :443 catch-all replaces Caddy's empty-200 default for an unmatched Host (#1132) =="
# Caddy's OWN default for a TLS connection whose Host/SNI matches no site block is a silent
# `200`, `content-length: 0`, no body — measured, and the reason #1132's certificate/site-list
# mismatch stayed quiet: the browser just showed a blank page. #1123 gave :80 a real answer;
# this is the same trailing catch-all for :443, reusing $caddy_redir (same secure, no-custom-port,
# no-onion render as the :80 test above — own_plain_port gates both catch-alls identically).
#
# MUTATION PROOF: point the catch-all at {host} (or {http.request.host}), and the "never comes
# from the request" assertion goes red; drop $(_bind_line) from it, and the bind-count assertion
# above (already re-derived to 4) goes red; give it a `tls` line of its own, and the
# no-tls-directive assertion below goes red.
caddy_https_catchall="$(printf '%s\n' "$caddy_redir" | sed -n '/^https:\/\/ {/,/^}/p')"
assert_contains "the :443 catch-all exists" "$caddy_https_catchall" "redir https://"
case "$caddy_https_catchall" in
*"{host}"* | *"{http.request.host}"*) bad "the :443 catch-all target never comes from the request" "it interpolates the request host: $caddy_https_catchall" ;;
*) ok "the :443 catch-all target never comes from the request" ;;
esac
# No `tls` directive of its own: proven against real Caddy (`caddy adapt`) that a hostless catch-all
# falls through to the file's default TLS connection policy — the SAME certificate the named vhost
# below already loads — so a matching SNI never reaches this block, and an unmatched one completes
# the handshake against that certificate (an honest name-mismatch warning) instead of an empty 200.
# An explicit `tls` line here would ask Caddy to manage a SEPARATE certificate for a site address
# with no hostname to manage one against.
case "$caddy_https_catchall" in
*"    tls "*) bad "the :443 catch-all carries no tls directive of its own" "a tls line appeared: $caddy_https_catchall" ;;
*) ok "the :443 catch-all carries no tls directive of its own" ;;
esac
# A custom port means a fronting proxy owns :443 too (#740), the same reasoning as :80 above.
case "$caddy_port_https" in
*"https:// {"*) bad "a custom port leaves :443 to the fronting proxy" "the render claimed the bare :443 catch-all anyway" ;;
*) ok "a custom port leaves :443 to the fronting proxy" ;;
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

echo "== black-box: dashboard auth lifecycle (#8) =="
# The hashing reads the pinned Caddy image out of docker-compose.yml and shells out to the stubbed
# `caddy hash-password`, so the whole enable → reuse → change → disable path runs offline.
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
AUTH_LOG="$V/auth-docker.log"

# (1) ENABLE: a password turns on basic_auth — hash + fingerprint persisted, plaintext never stored.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":0}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
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
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "unchanged password keeps the same hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" "$hash1"
case "$(cat "$AUTH_LOG")" in
*hash-password*) bad "unchanged password is not re-hashed" "caddy hash-password was called again" ;;
*) ok "unchanged password is not re-hashed (stable hash)" ;;
esac

# (3) CHANGE: a new password re-hashes (fingerprint changes) and recreates the caddy container.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"freshpass99"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "changed password re-hashes" "$(cat "$AUTH_LOG")" "hash-password"
assert_eq "changed password updates fingerprint" "$([ "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)" != "$fp1" ] && echo changed)" "changed"
assert_contains "auth change recreates caddy" "$(cat "$AUTH_LOG")" "restart caddy"

# (4) DISABLE: clearing the password drops basic_auth — hash cleared, dashboard reachable again.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "auth disable clears the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" ""
case "$(cat "$V/Caddyfile")" in
*basic_auth*) bad "auth disable drops basic_auth" "basic_auth still present in the Caddyfile" ;;
*) ok "auth disable drops basic_auth" ;;
esac
