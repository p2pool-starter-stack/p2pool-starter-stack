# sha256 of stdin as lowercase hex — portable across the sha256sum / shasum split.
sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

# bcrypt-hash a dashboard password with the PINNED Caddy image (read straight from docker-compose.yml
# so it tracks the digest), returned base64-encoded so the raw bcrypt '$' never lands in .env (#8).
# Returns non-zero if Docker / the image isn't available.
caddy_hash_password_b64() {
    local pw="$1" img hash
    img=$(grep -oE 'caddy:[0-9.]+@sha256:[a-f0-9]+' docker-compose.yml | head -1)
    [ -n "$img" ] || return 1
    # Fully qualified, because `docker run` here may be podman's shim: docker IMPLIES docker.io
    # for a short name, podman's native path refuses one outright — the compose pull worked (the
    # compat API keeps docker semantics) while this exact line killed appliance provisioning.
    img="docker.io/library/$img"
    hash=$(docker run --rm "$img" caddy hash-password --plaintext "$pw" 2>/dev/null) || return 1
    [ -n "$hash" ] || return 1
    printf '%s' "$hash" | openssl base64 -A
}

generate_caddyfile() {
    # Every vhost forwards the authenticated basic_auth username as X-Auth-User (#33) — the audit
    # `actor` for control-channel requests. header_up SETS the header, so a client-supplied
    # X-Auth-User can never spoof it; with auth off the placeholder renders empty.
    #
    # Optional basic_auth block (#8), rendered only when a dashboard password is configured. The
    # hash is decoded from its base64 .env form back to the raw bcrypt string Caddy expects; it
    # protects every route, so the dashboard prompts for login before anything is served.
    local auth=""
    if [ -n "${DASHBOARD_AUTH_HASH_B64:-}" ]; then
        local hash
        hash=$(printf '%s' "$DASHBOARD_AUTH_HASH_B64" | openssl base64 -d -A)
        auth=$(printf '    basic_auth {\n        %s %s\n    }' "$DASHBOARD_AUTH_USER" "$hash")
    fi
    # Access log (#349): every vhost writes a JSON line per request (timestamp, status, method,
    # URI, authenticated user) to one shared file under the host-mounted CADDY_LOG_DIR; the
    # dashboard tails it read-only, and repeated 401s there are the operator's "someone is
    # guessing the password" signal. Caddy redacts credential headers (Authorization, Cookie)
    # unless the log_credentials global option is set — it never is here — so no password material
    # lands in the log. Growth is bounded by Caddy's native rolling: 4 MiB per file, the current
    # file plus 2 rolled ones. mode 0644 lets the non-root dashboard read what root-run Caddy
    # writes (Caddy's default is 0600).
    local logblk='    log {
        output file /var/log/caddy/access.log {
            roll_size 4MiB
            roll_keep 2
            mode 0644
        }
        format json
    }'
    # Caddy LAN listen port (#740). An empty HOST_PORT — or a value that equals the scheme's own
    # default (443 for HTTPS, 80 for HTTP) — keeps the standard port and renders today's Caddyfile
    # verbatim. A custom port is appended to the site address so an existing reverse proxy on the
    # host can keep 80/443 (co-hosting, #181). In HTTPS mode a custom port also disables Caddy's
    # automatic :80 -> HTTPS redirect (a global option emitted once at the top of the file) so port
    # 80 is left free for that proxy; the fronting proxy owns any http->https bounce instead.
    local dport="${HOST_PORT:-}" port_suffix="" global_block="" own_plain_port=0
    if [ "$DASHBOARD_SECURE" == "true" ]; then
        [ "$dport" == "443" ] && dport=""
        if [ -n "$dport" ]; then
            port_suffix=":$dport"
            global_block='{
    auto_https disable_redirects
}

'
        else
            # Caddy's own HTTP->HTTPS redirect is a CATCH-ALL, and its target is the Host header the
            # request carried: :80 answered `Host: evil.example` with `308 -> https://evil.example`
            # (#1123, measured against the running bench appliance, not read off the config). Same
            # open redirector #1118 closed in the setup wizard, except this one is the state the
            # machine spends its life in, and it lands the operator on the dashboard login — the
            # screen where they type the dashboard password.
            #
            # So take :80 over rather than leaving it to auto_https. The site is built below, once
            # $site_hosts and the bind list exist: this is the port decision, that is the address
            # decision, and the bind list is what keeps the new block from reopening the addresses
            # #1021 closed.
            own_plain_port=1
            global_block='{
    auto_https disable_redirects
}

'
        fi
    else
        [ "$dport" == "80" ] && dport=""
        [ -n "$dport" ] && port_suffix=":$dport"
    fi

    # The site addresses — and the certificate's SAN list — now come from ONE shared builder
    # (appliance_site_names, #1132): a name Caddy serves and a name the certificate covers can no
    # longer drift apart the way they did when each kept its own copy of this expansion. DIY
    # serves the one host the operator reaches it by; the appliance expands to every address it
    # answers on unless dashboard.host is pinned, in which case it stays single on purpose — see
    # appliance_site_names for the full rule, the SLAAC-leak guard, and the bridge-gateway
    # exclusion (a stray site block on that address makes Caddy refuse the whole file).
    local site_hosts
    site_hosts=$(appliance_site_names)
    _site_addresses() { # $1 scheme — "https://a, https://b" from $site_hosts
        local h out=""
        for h in $site_hosts; do
            out="${out:+$out, }$1://$h$port_suffix"
        done
        printf '%s' "$out"
    }
    # Trimming the address list is necessary but is NOT a boundary on its own. Caddy runs with
    # network_mode: host and opens ONE WILDCARD listener (verified on the bench: `ss -lnt` shows
    # `*:443`, not per-address sockets), so a client that reaches the box on a global address still
    # completes the connection — it only has to send a Host header naming an address that IS in the
    # list, and Caddy matches on content, never on which interface the connection arrived over.
    # `bind` is what actually closes the socket: Caddy then listens on these addresses only, so the
    # global one is never accepted at all.
    #
    # LITERAL addresses only. A name would be resolved by Caddy at startup, and the appliance's
    # mDNS name resolves to every address it has — including the one being excluded, which would
    # re-open exactly what this closes. Loopback is always added: the host-networked dashboard and
    # Caddy's own admin healthcheck both arrive that way.
    # Built from the BOX's own addresses, never from $site_hosts. The two are different questions:
    # site_hosts is which Host values Caddy vhost-matches, this is which sockets it opens. Deriving
    # the bind from site_hosts tied it to the auto-expansion, so an operator who pinned
    # dashboard.host — a documented, supported choice — got a single-host site list and NO bind at
    # all, which is the wildcard listener and the whole exposure, back again for exactly the
    # operators who configured the box most deliberately.
    local bind_addrs="" _bh
    if is_appliance && [ "${DASHBOARD_EXPOSE_PUBLIC_IP:-false}" != "true" ]; then
        for _bh in $(hostname -I 2>/dev/null); do
            is_public_ip "$_bh" && continue
            case "$_bh" in
            *:*) ;;                # IPv6 literal
            *[!0-9.]*) continue ;; # not an address literal
            esac
            bind_addrs="${bind_addrs:+$bind_addrs }$_bh"
        done
        # Loopback unconditionally, appended OUTSIDE the loop so it survives a box that reports no
        # usable non-public address at render time: the host-networked dashboard and Caddy's own
        # admin healthcheck both arrive this way, and a bind that dropped them would be worse than
        # no bind at all.
        bind_addrs="${bind_addrs:+$bind_addrs }127.0.0.1 ::1"
    fi
    # NO trailing newline: consumed as $(_bind_line) on its own heredoc line, and command
    # substitution strips trailing newlines anyway — emitting one here produced
    # `bind ... ::1    basic_auth {` on a single line, which Caddy will not parse. Same convention
    # as $auth above. Empty when binding is off, which collapses to a blank line, like $auth.
    _bind_line() {
        [ -n "$bind_addrs" ] || return 0
        printf '    bind %s' "$bind_addrs"
    }
    # BOTH onion vhosts bind exactly when the LAN vhost does — the plain-HTTP one AND the HTTPS one
    # on the .onion name. A site block with NO bind asks Caddy for a WILDCARD listener, and that is
    # the whole reason this matters: an unbound block reopens every address the bound blocks were
    # written to exclude, including the globally-routable one #1021 exists to close. Verified
    # against the pinned caddy image: with `bind 127.0.0.1 ::1` on the LAN block and no bind on the
    # onion block, a request to an address OUTSIDE the bind list carrying the .onion name in Host/SNI
    # is served. For a Tor-first product that confirms the clearnet address behind the hidden
    # service and puts the login page back on the internet.
    #
    # Note what does NOT happen: a wildcard and a specific listener on one port do NOT collide.
    # Caddy sets SO_REUSEPORT, so `[::]:443` and `127.0.0.1:443` listen happily side by side —
    # measured, not assumed. The hazard is the reopened socket, never a startup crash.
    #
    # The HTTPS block is the one this originally missed: it renders only after provisioning lands a
    # real .onion address, so every render before that looked correct.
    _onion_bind_line() {
        [ -n "$bind_addrs" ] || return 0
        printf '    bind %s' "${NETWORK_PREFIX}.1"
    }

    # The :80 and :443 catch-alls that replace Caddy's own defaults for an unmatched Host. Built
    # here because both need everything that is only settled by now ($site_hosts, the bind list).
    #
    #  - the KNOWN hosts keep the address the operator typed, so browsing by mDNS name and browsing
    #    by IP each land on the name they used and match the certificate minted for it;
    #  - the trailing catch-alls answer everything else — including a forged Host or SNI — with
    #    THIS box's canonical address, never with what the request asked for. Unmatched, Caddy's
    #    own default is a reflecting redirect on :80 (closed by #1123) and an empty 200 on :443 —
    #    `content-length: 0`, no body, so a browser just shows a blank page (#1132's third bullet:
    #    the certificate/site-list mismatch this closes made that page's Host land HERE, not on the
    #    real vhost, and this was the only piece of the mismatch that stayed silent). Refusing
    #    outright would read as a dead machine, same reasoning as the :80 catch-all.
    #  - the :443 catch-all carries NO `tls` line of its own: it has no hostname in its address for
    #    Caddy to manage a certificate against, and needs none — proven with `caddy adapt` against
    #    the rendered file, a catch-all with no per-block TLS policy falls through to the file's
    #    default connection policy, which serves whatever certificate the named vhost below already
    #    loads (the appliance's minted file, or DIY's `tls internal`). A matching SNI never sees
    #    this block at all; an unmatched one completes the handshake against that same certificate
    #    (a name mismatch the browser will flag, honestly) and gets the redirect below instead of
    #    a silent 200.
    #  - and ALL of these carry the same bind list as the vhosts above. A site block with no bind
    #    asks Caddy for a WILDCARD listener, which would reopen every address the bound blocks were
    #    written to exclude — the globally-routable one included (#1021). That is the whole hazard
    #    here.
    #
    # A literal, NOT $(printf ...): command substitution strips the trailing newlines and the next
    # site block lands on the same line as this one's closing brace, which Caddy refuses.
    local redirect_block=""
    if [ "$own_plain_port" = 1 ]; then
        redirect_block="$(_site_addresses http) {
$(_bind_line)
    redir https://{host}{uri} 308
}

http:// {
$(_bind_line)
    redir https://$HOST_IP{uri} 308
}

https:// {
$(_bind_line)
    redir https://$HOST_IP{uri} 308
}

"
    fi

    : >"Caddyfile"
    [ -n "$global_block" ] && printf '%s' "$global_block" >>"Caddyfile"
    [ -n "$redirect_block" ] && printf '%s' "$redirect_block" >>"Caddyfile"
    # The appliance hands its ONE certificate to Caddy — the same file the setup page served, so
    # the operator's trust decision survives the handoff. Without this the wizard's cert is
    # replaced by Caddy's own at the exact moment provisioning succeeds, and the browser that
    # trusted the first one refuses the second: the setup page appears to die on success.
    local tls_line="    tls internal" tlsd
    if is_appliance; then
        # MINT IT HERE, every render — never gated on "missing". The certificate was previously
        # created only by the setup wizard, so any machine that skips the wizard (a pre-seeded
        # config, or a reinstall whose preserved /data already held config.json) reached this point
        # with the Caddyfile naming a file that did not exist; Caddy then answered :443 without a
        # usable certificate and the dashboard failed the TLS handshake outright
        # (ERR_SSL_PROTOCOL_ERROR), which covered the missing-file case. But site_hosts above is
        # rebuilt fresh on every render while a file-exists gate would leave an EXISTING certificate
        # untouched forever — so the moment the machine's addresses changed (a DHCP lease, a pinned
        # host), Caddy would serve names the certificate never heard of (#1132). Calling
        # unconditionally hands that decision to appliance_mint_cert itself, which is idempotent
        # by comparison, not by "already have a file": it re-mints only when the name list it was
        # minted for no longer matches, and reuses the operator's already-trusted certificate
        # otherwise.
        tlsd=$(appliance_tls_dir)
        appliance_mint_cert >/dev/null 2>&1 || true
        if [ -s "$tlsd/wizard.crt" ] && [ -s "$tlsd/wizard.key" ]; then
            tls_line="    tls /pithead-tls/wizard.crt /pithead-tls/wizard.key"
        else
            warn "Could not provide a certificate for the dashboard — falling back to Caddy's own."
        fi
    fi
    if [ "$DASHBOARD_SECURE" == "true" ]; then
        log "Generating Caddyfile for automatic HTTPS ($site_hosts$port_suffix)$([ -n "$auth" ] && echo ' with login')..."
        cat <<EOF >>"Caddyfile"
$(_site_addresses https) {
$tls_line
$(_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
    else
        log "Generating Caddyfile for HTTP ($site_hosts$port_suffix)$([ -n "$auth" ] && echo ' with login')..."
        cat <<EOF >>"Caddyfile"
$(_site_addresses http) {
$(_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
    fi

    # Onion vhost (#343): a second site reachable ONLY from the tor container, via the bridge gateway
    # (NETWORK_PREFIX.1 — the /24's first host, where host-networked Caddy binds and bridge containers
    # route out). It is never on the LAN. Plain HTTP: Tor provides the transport encryption inside the
    # tunnel, so no `tls internal` here. It MUST carry the same auth block — refuse to publish an
    # unauthenticated control panel (config validation already fails closed; this is belt-and-suspenders).
    if [ "${DASHBOARD_ONION_ENABLED:-false}" == "true" ]; then
        if [ -z "$auth" ]; then
            error "Refusing to render the dashboard onion vhost without a login: dashboard.onion.enabled is on but no auth hash is set."
        fi
        log "Adding onion vhost for the dashboard (${NETWORK_PREFIX}.1, login required)..."
        cat <<EOF >>"Caddyfile"

http://${NETWORK_PREFIX}.1 {
$(_onion_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
        # Also serve HTTPS on the .onion name so Tor Browser's default http->https upgrade lands on a
        # working :443 instead of a refused connection (#343). The cert is self-signed (Caddy's internal
        # CA) for the .onion — a .onion can't get a browser-trusted cert without a manual CA process, and
        # Tor already encrypts the tunnel, so the browser shows a one-time "accept the risk" prompt. SNI
        # (the .onion name) routes this apart from the LAN vhost, both on host-networked :443. Rendered
        # only once the address is provisioned; a fresh enable serves HTTP immediately, and apply,
        # upgrade, and rotate-dashboard-onion regenerate this Caddyfile (and restart caddy) the moment
        # the capture step lands the real address, so HTTPS appears in that same run (#546).
        if [ -n "${DASHBOARD_ONION:-}" ] && [ "${DASHBOARD_ONION:-}" != "placeholder" ]; then
            log "Adding HTTPS onion vhost (self-signed cert for the .onion)..."
            cat <<EOF >>"Caddyfile"

https://${DASHBOARD_ONION} {
    tls internal
$(_onion_bind_line)
$auth
$logblk
    reverse_proxy 127.0.0.1:8000 {
        header_up X-Auth-User {http.auth.user.id}
    }
}
EOF
        fi
    fi
}
