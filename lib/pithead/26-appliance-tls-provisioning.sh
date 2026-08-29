# When the dashboard onion is enabled but no password is set, generate a strong one and save it to
# config.json (#343). Keeps the fail-closed onion usable without forcing the operator to invent a
# 16+ char secret; the plaintext lives in owner-only config.json, exactly like a hand-set password
# (login stays "admin"). Runs only on the config-writing paths (setup/apply), before parse validates
# — never on read-only commands, which must not mutate config.json.
ensure_onion_password() {
    [ -f "$CONFIG_FILE" ] || return 0
    [ "$(config_bool '.dashboard.onion.enabled' false)" == "true" ] || return 0
    [ -z "$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE")" ] || return 0
    local gen tmp
    gen=$(generate_node_password) # 32 alnum chars: clears the >=16 floor, no quotes, no weak pattern
    tmp=$(mktemp) || error "Could not create a temp file to save the generated dashboard password."
    jq --arg p "$gen" '.dashboard.auth.password = $p' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE" ||
        error "Could not save the generated dashboard password to $CONFIG_FILE."
    log "Dashboard onion is on but no password was set — generated one and saved it to config.json (login: admin; see dashboard.auth.password)."
}

# Put words in front of a human standing at the machine. /dev/console is only ONE of the
# consoles — whichever the cmdline named last — so a message sent there alone is invisible to an
# operator watching the other. Between power-on and the setup page there is a minute or more of
# image loading, and silence there reads as a broken machine.
_console() { # $1... lines
    local dev line
    # Every line reaches the journal too — a message that lives only on a physical console
    # cost a bench session an hour once (see firstboot's teed setup log for the same lesson).
    for line in "$@"; do
        # if, not '&&': an empty spacer line under set -e must not become the exit status.
        if [ -n "$line" ]; then log "$line"; fi
    done
    for dev in /dev/tty1 /dev/ttyS0; do
        [ -w "$dev" ] || continue
        printf '  %s\n' "$@" >"$dev" 2>/dev/null || true
    done
}

# A self-signed certificate for the setup page, valid for every address the operator might use.
# Echoes the SHA-256 fingerprint so the console can print it beside the token: a browser warning
# nobody can check is theatre, and this page now carries node passwords and bot tokens.
# Regenerated each run — addresses change with the DHCP lease, and the key is disposable.
# The machine's ONE certificate, minted once and kept on /data. The wizard serves it, and Caddy
# serves the same file afterwards — because a second, different self-signed cert for the same
# name is not a second warning, it is a hard refusal in Safari and a scary one everywhere else.
# A bench session hit exactly that: the setup page "died" at the moment provisioning succeeded.
appliance_tls_dir() { printf '%s' "${PITHEAD_TLS_DIR:-$PWD/data/tls}"; }

# The ONE list of names this appliance answers to — the shared builder behind BOTH Caddy's
# site_hosts (generate_caddyfile) and the certificate's SAN list (appliance_mint_cert), so a name
# is either served and certified or neither (#1132). Prints bare host/IP tokens, space-separated;
# each caller formats them for its own consumer (a literal Host for Caddy, a DNS:/IP: SAN entry
# for the certificate).
#
# The base name both appliance_site_names() and check_appliance_cert() start from: $HOST_IP —
# resolve_dashboard_host's own answer, which already carries its "dashboard.host wins, else this
# machine's name" rule — so an operator who pins dashboard.host gets that exact name from both
# consumers, never a certificate for the machine's OTHER names (the #1132 mismatch). Called before
# resolve_dashboard_host has run (the wizard's very first mint, before CONFIG_FILE exists) $HOST_IP
# is empty; fall back to its own "auto" default rather than duplicating that function's
# prompt/env logic here. Pulled out on its own because check_appliance_cert needs to tell this name
# apart from the auto-expanded ones below it — see that function's header for why.
appliance_base_name() {
    if [ -n "${HOST_IP:-}" ]; then
        printf '%s' "$HOST_IP"
    elif is_appliance; then
        printf '%s.local' "$(hostname)"
    else
        hostname
    fi
}

# "auto" (dashboard.host unset) expands to every address the appliance actually answers on — a
# headless box reached by mDNS name, by IP, or from the console must have all three certified. An
# explicit pin stays a single name on purpose: the site list collapsing was never the #1132 bug,
# only the certificate not following suit was.
#
# Deliberately engine-free: this runs from BOTH generate_caddyfile (render, always BEFORE `up`
# creates either compose bridge this boot) and, via check_appliance_cert, from doctor (always
# AFTER `up`, inside pithead-boot's health-gate retry loop). A call here that talked to
# docker/podman would make this function's answer depend on whether the engine happened to be
# reachable at the exact moment it ran — and #1065 reboots the box on a doctor FAIL, so an engine
# hiccup must never change what this reports. mining_net's gateway is excludable without asking
# anything live (${NETWORK_PREFIX}.1, fixed by config) so it stays here; proxy_net's is NOT
# (docker-compose.yml: "Docker auto-assigns the subnet", #345) and asking the engine for it is
# check_appliance_cert's job alone — the ONE caller for whom a stale or unreachable answer would
# otherwise manufacture a FAIL, and so the only one equipped to turn "can't tell" into a WARN
# instead of a guess. See that function's header for the full reasoning.
appliance_site_names() {
    local base
    base=$(appliance_base_name)
    local names="$base"
    if is_appliance && [ -z "${DASHBOARD_HOST:-}" ]; then
        local extra
        for extra in $(hostname -I 2>/dev/null) localhost; do
            case " $names " in *" $extra "*) continue ;; esac
            # `hostname -I` lists EVERY address on every interface, so on any network whose router
            # passes IPv6 through, a SLAAC/DHCPv6 global unicast address lands here exactly like a
            # LAN one — and this list is rebuilt every render. That published the control panel on
            # a globally-routable address, with nothing but the operator's router between it and
            # the internet; the product must not depend on that. The documented way to reach the
            # dashboard off-LAN is the onion service, never a routable address, so nothing
            # supported regresses. Opt back in with dashboard.expose_public_ip if a deployment
            # really does want it.
            if [ "${DASHBOARD_EXPOSE_PUBLIC_IP:-false}" != "true" ] && is_public_ip "$extra"; then
                continue
            fi
            # mining_net's gateway belongs to the ONION vhost, which serves on exactly that
            # address, and never to the LAN list — two site blocks naming the same scheme://address
            # make Caddy refuse the whole file with "ambiguous site definition" (see
            # generate_caddyfile). Excluding it here keeps the certificate honest too: it was never
            # reachable at the bridge gateway by anything except the tor container. proxy_net's
            # gateway is the SAME kind of plumbing address but has no fixed literal to exclude it
            # by — see this function's header for why that exclusion lives in check_appliance_cert
            # instead of here.
            if [ -n "${NETWORK_PREFIX:-}" ] && [ "$extra" = "${NETWORK_PREFIX}.1" ]; then
                continue
            fi
            names="$names $extra"
        done
    fi
    printf '%s' "$names"
}

# appliance_site_names(), formatted as a certificate SAN string ("DNS:a,DNS:b,IP:c,..."). Same
# character-class rule the bind_addrs loop below uses: a colon is an IPv6 literal, any other
# non-digit/non-dot character makes it a name, otherwise it's a dotted-quad IPv4 literal. Always
# succeeds (appliance_site_names never fails) — safe to use in a bare assignment under `set -e`.
appliance_cert_alt_string() {
    local h out=""
    for h in $(appliance_site_names); do
        case "$h" in
        *:*) out="${out:+$out,}IP:$h" ;;
        *[!0-9.]*) out="${out:+$out,}DNS:$h" ;;
        *) out="${out:+$out,}IP:$h" ;;
        esac
    done
    printf '%s' "$out"
}

# The SAN list a certificate FILE actually carries, in the same "DNS:a,IP:b" form
# appliance_cert_alt_string builds — so appliance_mint_cert and doctor can compare what a
# certificate covers against what it should, instead of guessing from a mint date (#1132). Empty
# on any read failure (missing file, corrupt cert, no SAN extension at all) — callers treat that
# as "does not match". Deliberately always exits 0 (`|| true`): a corrupt certificate is data for
# the caller to act on, not a reason for `pithead` itself to abort under `set -e`.
cert_san_string() { # <cert-file>
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null |
        tr -d '[:space:]' | sed -e 's/^X509v3SubjectAlternativeName://' -e 's/IPAddress:/IP:/g' || true
}

# The console login mirrors the dashboard login (operator decision 2026-07-31): one secret per
# machine. Anyone at the physical console with the dashboard password may log in as root —
# consistent with the LAN/physical trust model (the console already shows the setup token, and
# SSH stays key-only regardless: PasswordAuthentication never turns on). Re-asserted on every
# render, so a changed dashboard password propagates and an empty one locks the console again.
provision_console_login() {
    is_appliance || return 0
    command -v chpasswd >/dev/null 2>&1 || return 0
    # /etc/shadow sits on the read-only root, so the password lives in a /run-backed overlay on
    # /etc — DERIVED (#790) in the strictest sense: rewritten from config.json on every boot,
    # persisted nowhere, gone the moment the machine powers off. (A bind-mounted shadow FILE
    # does not survive chpasswd, which replaces the file by rename.)
    if ! findmnt -no FSTYPE /etc 2>/dev/null | grep -q overlay; then
        sudo mkdir -p /run/pithead-etc/upper /run/pithead-etc/work
        sudo mount -t overlay overlay \
            -o lowerdir=/etc,upperdir=/run/pithead-etc/upper,workdir=/run/pithead-etc/work /etc ||
            {
                warn "Could not prepare the console login (no /etc overlay)."
                return 0
            }
    fi
    local pass
    pass=$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$pass" ]; then
        sudo passwd -l root >/dev/null 2>&1 || true
        return 0
    fi
    printf 'root:%s\n' "$pass" | sudo chpasswd 2>/dev/null &&
        log "Console login set: root, with the dashboard password." ||
        warn "Could not set the console login."
}

# SSH per config (ssh.enabled + ssh.authorized_key) — the appliance's opt-in debug and
# recovery path (#786). Key-only, never passwords. Everything it writes is DERIVED (#790) and
# lives on tmpfs: the key under /run/pithead-ssh, sshd's override under /run/systemd/system —
# rebuilt every boot by render, gone on the first boot after the flag turns off, and no key
# material ever rests on disk outside config.json itself. Appliance-only: a DIY host owns its
# own sshd. Deliberately in the HOST-ONLY config class (never dashboard-editable): a dashboard
# session that could enable SSH and choose the key would own the machine.
provision_ssh_access() {
    is_appliance || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit_d="${PITHEAD_UNIT_DIR:-/run/systemd/system}/ssh.service.d"
    local key_d="${PITHEAD_SSH_RUN_DIR:-/run/pithead-ssh}" en key
    en=$(jq -r '.ssh.enabled // false' "$CONFIG_FILE" 2>/dev/null)
    key=$(jq -r '.ssh.authorized_key // ""' "$CONFIG_FILE" 2>/dev/null)
    if [ "$en" != "true" ] || [ -z "$key" ]; then
        if [ -e "$unit_d/pithead.conf" ] || [ -d "$key_d" ]; then
            log "SSH is OFF (ssh.enabled) — removing the runtime access."
            rm -rf "$unit_d" "$key_d"
            sudo systemctl daemon-reload
            sudo systemctl stop ssh >/dev/null 2>&1 || true
        fi
        return 0
    fi
    mkdir -p "$unit_d" "$key_d"
    chmod 755 "$key_d" # sshd's StrictModes walks the path — group/world-writable would refuse
    printf '%s\n' "$key" >"$key_d/authorized_keys"
    chmod 644 "$key_d/authorized_keys"
    cat >"$unit_d/pithead.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/sshd -D -o AuthorizedKeysFile=$key_d/authorized_keys -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password
EOF
    sudo systemctl daemon-reload
    sudo systemctl start ssh >/dev/null 2>&1 ||
        warn "Could not start sshd — ssh.enabled is set but SSH is not running."
    log "SSH is ON (key-only): root@$(hostname).local"
}

# Mint (or keep) the machine's ONE certificate in appliance_tls_dir. Idempotent: an existing
# certificate that still covers the machine's names is reused, because the operator has already
# trusted it and replacing it is indistinguishable from an attack. Re-mints ONLY when the name
# list it was minted for no longer matches (#1132) — compared, not date-guessed: the minted SAN
# list is derived from the certificate itself with openssl (cert_san_string) and set-compared
# against appliance_site_names' current answer, sorted on both sides so a re-ordered (but
# unchanged) `hostname -I` never trips a needless re-mint. An operator who has pinned this
# fingerprint loses that trust on every unnecessary replacement, so the comparison stays as
# conservative as it can — and a real re-mint says so on the console, since the operator's browser
# will need to trust the new certificate.
appliance_mint_cert() { # -> prints the SHA-256 fingerprint
    local d alt need_mint=1 names primary
    d=$(appliance_tls_dir)
    mkdir -p "$d"
    alt=$(appliance_cert_alt_string)
    if [ -s "$d/wizard.crt" ] && [ -s "$d/wizard.key" ] &&
        [ "$(cert_san_string "$d/wizard.crt" | tr ',' '\n' | sort | tr '\n' ',')" = \
            "$(printf '%s' "$alt" | tr ',' '\n' | sort | tr '\n' ',')" ]; then
        need_mint=0
    fi
    if [ "$need_mint" = 1 ]; then
        [ -s "$d/wizard.crt" ] &&
            log "Re-minting the dashboard certificate — the machine now answers to a different set of names than the one it was minted for. Your browser will need to trust the new certificate."
        names=$(appliance_site_names)
        primary="${names%% *}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$d/wizard.key" -out "$d/wizard.crt" \
            -subj "/CN=$primary" -addext "subjectAltName=$alt" \
            -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1 || return 1
    fi
    openssl x509 -in "$d/wizard.crt" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//'
}

wizard_mint_cert() { # <spool-dir>  -> prints the fingerprint
    local d spool="$1" fp
    d=$(appliance_tls_dir)
    fp=$(appliance_mint_cert) || return 1
    # The container reads its copy from the spool; the canonical pair stays on /data.
    cp "$d/wizard.crt" "$spool/wizard.crt" 2>/dev/null || return 1
    cp "$d/wizard.key" "$spool/wizard.key" 2>/dev/null || return 1
    chown 1000:1000 "$spool/wizard.key" "$spool/wizard.crt" 2>/dev/null || true
    chmod 640 "$spool/wizard.key" 2>/dev/null || true
    printf '%s' "$fp"
}

# An appliance gets a dashboard login whether or not the onion is on.
#
# ensure_onion_password only fires for the onion, so a LAN appliance shipped an UNAUTHENTICATED
# dashboard — and the setup page told the operator a login had been generated. On DIY that is a
# defensible default: the operator ran the CLI wizard, was asked, and pressed Enter to skip. A
# headless appliance was never asked, so the safe answer is the one it gets. The credential is
# generated on the machine and printed to its console; it never crosses the setup page.
ensure_appliance_dashboard_password() { # [spool-dir]
    [ -f "$CONFIG_FILE" ] || return 0
    [ -z "$(jq -r '.dashboard.auth.password // ""' "$CONFIG_FILE")" ] || return 0
    # The operator's explicit "no login" is honoured — an empty password is also what "not
    # chosen" looks like, so the choice cannot live in the config and rides beside it.
    if [ -n "${1:-}" ] && [ "$(cat "$1/auth-mode" 2>/dev/null)" = "none" ]; then
        warn "Dashboard login disabled at the operator's request — anyone on this network can open it."
        return 0
    fi
    local gen tmp user
    gen=$(generate_node_password) # 32 alnum: clears the >=16 floor, no quotes, no weak pattern
    user=$(jq -r '.dashboard.auth.username // "admin"' "$CONFIG_FILE")
    tmp=$(mktemp) || return 1
    if jq --arg p "$gen" '.dashboard.auth.password = $p' "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"; then
        _console "" "Dashboard login for this machine:" "    user: $user" "    password: $gen" \
            "Write this down — it is also in config.json on the machine."
        return 0
    fi
    rm -f "$tmp"
    warn "Could not save a generated dashboard password; the dashboard will have no login."
    return 1
}
