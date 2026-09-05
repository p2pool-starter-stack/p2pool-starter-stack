# Non-fatal heads-up that the unauthenticated stratum port :3333 may face the public internet (#113):
# warn only when the host has a public IP AND stratum listens on all interfaces (the default bind).
# Home/NAT hosts (no public IP on an interface) and hosts that narrowed p2pool.stratum_bind stay
# quiet in setup. $1 = "setup" (emit via warn, only on exposure) or "doctor" (emit OK/WARN/skip).
check_stratum_exposure() {
    local mode="$1" bind pub msg port
    bind="${STRATUM_BIND:-}"
    if [ -z "$bind" ] && [ -f "${ENV_FILE:-.env}" ]; then bind="$(env_get STRATUM_BIND 2>/dev/null || true)"; fi
    [ -n "$bind" ] || bind="0.0.0.0"
    port=$(stratum_port_effective)

    if ! command -v ip >/dev/null 2>&1; then
        [ "$mode" = doctor ] && dr_info "Skipped public-IP exposure check (no 'ip' command; Linux-only)."
        return 0
    fi
    case "$bind" in
    0.0.0.0 | "") ;; # all interfaces — the exposed case
    *)
        [ "$mode" = doctor ] && dr_ok "Stratum :$port bound to $bind (not all interfaces) — not publicly exposed."
        return 0
        ;;
    esac

    pub="$(host_public_ips)"
    pub="${pub//$'\n'/, }"
    if [ -n "$pub" ]; then
        # setup's console warn NAMES the address, and keeps naming it: that is the operator's own
        # terminal on their own host, and the address is what makes the finding actionable there.
        # The DOCTOR verdict has a second audience since #1736 -- control_diag_doctor runs
        # `doctor --json` and ships every recorded message to the dashboard over the network -- so
        # the doctor arms carry the finding WITHOUT the value (#1772). The redactor on that path
        # does not close it: bundle_redact_log (07-support-bundle.sh) keys on argv position, the
        # onion shape and the Monero shape, and has no IP rule at all. tests/integration/lib.sh's
        # redact() does have one (#1609), but that twin guards CI artifact uploads, not the browser.
        msg="This host appears to have a public IP ($pub). The stratum port $port is unauthenticated by default and cleartext — firewall it to your LAN, set p2pool.stratum_bind to a LAN IP / 127.0.0.1, and/or require a p2pool.stratum_password. See $DOCS_URL/docs/workers.md#firewall."
        if [ "$mode" = doctor ]; then
            # The appliance arm names only what an appliance operator can actually reach. Blocking
            # the port at their own router is theirs. The two config remedies are not: neither
            # STRATUM_BIND nor STRATUM_PASSWORD is in CONTROL_DASHBOARD_EDITABLE_KEYS or
            # CONTROL_DASHBOARD_CONFIRM_KEYS (42-control-policy-and-host-checks.sh), where the
            # stratum password is named as deliberately host-only. So it states the diagnosis,
            # gives the one route that exists, and stops -- #1213's rule at #1772's site.
            dr_warn_surface "This host appears to have a public IP. The stratum port $port is unauthenticated by default and cleartext — firewall it to your LAN, set p2pool.stratum_bind to a LAN IP / 127.0.0.1, and/or require a p2pool.stratum_password. See $DOCS_URL/docs/workers.md#firewall." "This machine appears to have a public IP, and the stratum port $port is unauthenticated and cleartext by default — anything on the internet can reach it. Block that port at your router, so that only your own network can. Narrowing the listen address or requiring a stratum password is not editable from the dashboard: changing either needs console access to this machine."
        else
            warn "$msg"
        fi
    else
        [ "$mode" = doctor ] && dr_ok "No public IP on host interfaces — stratum :$port isn't directly internet-exposed."
    fi
    return 0
}

# Doctor check (#33): do the installed control units point at THIS install?
# The dashboard writes control requests into its own install's spool and a systemd path unit
# watches that spool. The unit names an absolute path and is box-global, so it can end up naming a
# different directory than the dashboard writes to — and when it does, nothing anywhere reports it:
# requests pile up unread, and the config editor and one-click upgrade simply never complete. A
# failed upgrade was enough to cause it in the field (#1070 fixed the ordering that did it; this
# finds a box already stranded, which that fix by definition cannot reach — the channel it would
# arrive through is the broken one).
check_control_units() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    echo ""
    echo "Dashboard control channel:"
    local unit_dir owner here spool
    unit_dir=$(control_unit_dir)
    if [ "$(normalize_bool "$(env_get DASHBOARD_CONTROL_ENABLED)")" != "true" ]; then
        dr_info "Disabled for this install — the dashboard cannot apply config changes or upgrade."
        return 0
    fi
    owner=$(control_units_owner_dir)
    here=$(pwd -P)
    spool=$(env_get CONTROL_DIR)
    # A versioned dir that `current` no longer names is a superseded rollback copy, not a
    # stranded install: the units SHOULD name the live dir, and the dashboard writes there, not
    # here. Verdicts about the control channel belong to the live install, so say what this dir
    # is and stop. Same pattern update_current_symlink uses to recognise the layout (#455).
    local _name _parent _live
    _name=$(basename "$here")
    _parent=$(dirname "$here")
    if [[ "$_name" =~ ^pithead-v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -L "$_parent/current" ]; then
        _live=$(cd "$_parent/current" 2>/dev/null && pwd -P)
        if [ -n "$_live" ] && [ "$_live" != "$here" ]; then
            dr_info "This is not the live install — '$_parent/current' points at $_live. Run doctor there to check its control channel." # appliance-unreachable: the DIY versioned layout only -- the guard above needs basename pithead-vX.Y.Z AND a sibling `current` symlink, and the appliance's /opt/pithead install creates neither
            return 0
        fi
    fi
    if [ -z "$owner" ]; then
        dr_fail_surface "The control channel is enabled but no runner units are installed — the dashboard's config changes and one-click upgrades will never run, with no error shown. Fix: run './pithead apply' from this directory." "The control channel is enabled but no runner units are installed — config changes and one-click upgrades made here will never run, with no error shown. The installed system provides these units, so this system copy is faulty."
    elif [ "$owner" != "$here" ]; then
        dr_fail_surface "The control runner units point at $owner, but this install is $here — the dashboard writes its requests here and nothing reads them, so config changes and one-click upgrades silently never run. Fix: run './pithead apply' from this directory." "The control runner units point at $owner, but this install is $here — requests are written here and nothing reads them, so config changes and one-click upgrades silently never run. The installed system sets this up, so this system copy is faulty."
    elif [ -n "$spool" ] &&
        ! grep -qsF "PathExistsGlob=$spool/requests/*.json" "$unit_dir/pithead-control.path"; then
        dr_fail_surface "The control runner watches a different spool than this install writes to ($spool) — requests are never picked up, with no error shown. Fix: run './pithead apply' from this directory." "The control runner watches a different spool than this install writes to ($spool) — requests are never picked up, with no error shown. The installed system sets this up, so this system copy is faulty."
    else
        dr_ok "Control runner units target this install."
    fi
}

# Doctor check (#1121): the wipe note pithead-data-reset leaves on the ESP when it reinitializes
# /data (#1062) — a support conversation on a box with a shell gets the fact without knowing
# where to look. Appliance-only: PRESEED_DIR only carries this note on that channel; absent is
# silent, matching every other doctor check that has nothing to report.
check_data_wipe_note() {
    is_appliance || return 0
    local note
    note=$(data_wipe_note) || return 0
    local when reason
    when=$(printf '%s' "$note" | jq -r '.when')
    reason=$(printf '%s' "$note" | jq -r '.reason')
    echo ""
    echo "Data reset:"
    if printf '%s' "$note" | jq -e '.recovery' >/dev/null 2>&1; then
        dr_warn "/data was reinitialized on $when ($reason) — if this was not a deliberate factory reset, restore from backup rather than reprovisioning from scratch."
    else
        dr_info "/data was reformatted on $when ($reason)."
    fi
}

# Doctor-only: a SINGLE compose bridge's gateway, read live from the engine — one network per
# call, never a combined multi-name `network inspect a b`. A combined call's behavior when only
# ONE of several names resolves is not a documented, stable shape across engines/versions, so
# asking one name at a time keeps each call's outcome about exactly that network, and keeps
# check_appliance_cert's WARN-vs-FAIL decision below simple: "did this ONE network answer with a
# gateway", never "did some of a compound answer parse". Prints nothing on ANY failure — the
# network genuinely does not exist yet, the engine is unreachable, the daemon restarted mid-boot, a
# socket permission slip — deliberately making no attempt to tell those apart by exit code (docker
# and podman do not reliably agree on one for "no such network" vs. everything else). Callers key
# off whether this printed anything, never off its exit code.
appliance_bridge_gateway() { # <network-name> -> the network's gateway on stdout, or nothing at all
    "$(container_engine)" network inspect "$1" 2>/dev/null |
        jq -r '(.[0].subnets[]?.gateway // empty), (.[0].IPAM.Config[]?.Gateway // empty)' 2>/dev/null |
        awk 'NF{print; exit}'
}

# Doctor check (#1141): does the certificate Caddy is ACTUALLY serving still cover the machine's
# name list, and is it still current? Appliance-only — DIY serves Caddy's own "tls internal" CA,
# out of scope here. With #1132's shared appliance_site_names() behind both the mint and the
# Caddyfile, a fresh render can no longer produce the two-different-rules mismatch by construction
# — this check is belt-and-braces for that half (a re-mint that silently failed, a hand-installed
# certificate, a stale one from before #1132) and the primary signal for expiry, which nothing
# else here re-derives on its own.
#
# Conservative on purpose: doctor is the second half of pithead-boot's health gate, and after
# #1065 a FAIL here reboots the box. An unreadable or truncated certificate file is a TOOLING
# problem, not proof the certificate itself is broken (a mid-write snapshot, a filesystem hiccup),
# so it WARNs; a FAIL is reserved for a certificate openssl actually parsed and found a concrete
# problem with — a host it does not cover, or a real expiry date.
#
# Coverage is split into two questions with two different honesty rules, because they need
# different evidence:
#
# The BASE name (appliance_base_name — a pinned dashboard.host, or this box's own hostname/.local)
# needs no live state to derive. An uncovered base name is always a real, actionable problem, so
# it can always FAIL.
#
# The rest is appliance_site_names' auto-expansion (only runs when dashboard.host is unset), and
# its membership can include one of pithead's OWN compose-bridge gateways. mining_net's is already
# excluded by appliance_site_names itself (a known config literal, ${NETWORK_PREFIX}.1); proxy_net's
# is NOT — #345: Docker/podman auto-assigns its subnet, so there is no literal to exclude it by, and
# telling it apart from a genuinely uncovered name needs asking the engine, live, right now (see
# appliance_bridge_gateway). pithead-boot mints the certificate at render, BEFORE `up` creates
# either bridge this boot; this check runs from doctor, inside pithead-boot's health-gate retry
# loop, AFTER `up` — so by the time this runs, both bridges normally exist and their gateways are
# in `hostname -I` whether or not the engine is reachable to explain them: bridge INTERFACES outlive
# an engine hiccup. Reading "the engine didn't answer" as "nothing to exclude" would manufacture
# exactly the FAIL this check exists to prevent — worse than the original bug, because it would
# come back intermittently, on a healthy box, disguised as a passing check. So: engine reachable
# for BOTH bridges -> filter the confirmed gateways out and FAIL on whatever is genuinely still
# missing, same as any other name. Engine did not answer for either one -> dr_warn once and skip
# the FAIL for every auto-expanded name this run — only the base name, which needs no engine at
# all, can still fail this boot.
check_appliance_cert() {
    is_appliance || return 0
    echo ""
    echo "Certificate:"
    local crt
    crt="$(appliance_tls_dir)/wizard.crt"
    if [ ! -s "$crt" ]; then
        dr_info_surface "No dashboard certificate at $crt yet — run './pithead apply' to mint one." "No dashboard certificate yet — this machine mints one whenever it renders its web configuration."
        return 0
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        dr_warn "Could not check the dashboard certificate — openssl not found."
        return 0
    fi

    # Rebuild the SAME name list generate_caddyfile/appliance_mint_cert build (#1132), so this
    # asks the shared builder's own question rather than a second copy of the expansion rule.
    # doctor() never renders, so the inputs appliance_site_names reads as globals are populated
    # locally here — HOST_IP/NETWORK_PREFIX/DASHBOARD_EXPOSE_PUBLIC_IP from the already-rendered
    # .env, DASHBOARD_HOST from config.json exactly like parse_and_validate_config does — never
    # re-derived by prompting or guessing.
    local HOST_IP NETWORK_PREFIX DASHBOARD_EXPOSE_PUBLIC_IP DASHBOARD_HOST
    HOST_IP=$(env_get HOST_IP)
    NETWORK_PREFIX=$(env_get NETWORK_PREFIX)
    DASHBOARD_EXPOSE_PUBLIC_IP=$(env_get DASHBOARD_EXPOSE_PUBLIC_IP)
    DASHBOARD_HOST=$(resolve_default "$(jq -r '.dashboard.host // empty' "$CONFIG_FILE" 2>/dev/null)" "")

    # -enddate is the readability gate for BOTH checks below: an unreadable/truncated/corrupt cert
    # prints nothing and exits non-zero, and that must WARN, never FAIL (see function header).
    local enddate
    enddate=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | sed 's/^notAfter=//') || true
    if [ -z "$enddate" ]; then
        dr_warn "Could not read the dashboard certificate ($crt may be unreadable or truncated)."
        return 0
    fi

    local san h
    san=$(cert_san_string "$crt")

    # Base and "localhost" are always checked outright — neither depends on live host-network
    # state, so an engine hiccup never excuses either one. "localhost" is unconditional the moment
    # the auto-expansion runs at all (appliance_site_names appends it beside every real address),
    # so it has to be pulled out here explicitly — left inside $extras below, it would make
    # "anything auto-expanded" true on EVERY appliance doctor run and WARN on every engine hiccup
    # even when nothing bridge-related is actually in play.
    local base missing=""
    base=$(appliance_base_name)
    case ",$san," in
    *",DNS:$base,"* | *",IP:$base,"*) ;;
    *) missing="$base" ;;
    esac

    # Everything else appliance_site_names() adds beyond the base — always empty when
    # dashboard.host is pinned (appliance_site_names' own auto-expansion guard), so a pin never
    # even reaches the engine-dependent leniency below: there is nothing here it would need to
    # excuse. This is the only category that can contain a compose-bridge gateway.
    local tok extras=""
    for tok in $(appliance_site_names); do
        [ "$tok" = "$base" ] && continue
        if [ "$tok" = "localhost" ]; then
            case ",$san," in
            *",DNS:localhost,"* | *",IP:localhost,"*) ;;
            *) missing="${missing:+$missing }localhost" ;;
            esac
            continue
        fi
        extras="${extras:+$extras }$tok"
    done

    if [ -n "$extras" ]; then
        local net gw bridge_gws="" engine_ok=1
        # mining_net is probed too even though appliance_site_names already excludes its gateway
        # (so it can never appear in $extras to filter) — it exists from the first `up` of every
        # boot, so if the engine cannot even confirm THAT, the engine itself is the problem, not
        # "proxy_net isn't up yet", and the WARN path below is the honest answer either way.
        for net in mining_net proxy_net; do
            gw=$(appliance_bridge_gateway "$net")
            if [ -n "$gw" ]; then
                bridge_gws="${bridge_gws:+$bridge_gws }$gw"
            else
                engine_ok=0
            fi
        done
        if [ "$engine_ok" != 1 ]; then
            dr_warn "Could not derive the bridge-gateway exclusions for the dashboard certificate check — the container engine did not answer for mining_net/proxy_net. Coverage was not checked against this box's auto-expanded addresses this run."
        else
            bridge_gws=" $bridge_gws "
            for h in $extras; do
                case "$bridge_gws" in *" $h "*) continue ;; esac
                case ",$san," in
                *",DNS:$h,"* | *",IP:$h,"*) ;;
                *) missing="${missing:+$missing }$h" ;;
                esac
            done
        fi
    fi

    if [ -n "$missing" ]; then
        dr_fail_surface "The dashboard certificate does not cover: $missing — Caddy serves those names without a certificate for them. Run './pithead apply' to re-mint." "The dashboard certificate does not cover: $missing — those names are served without a certificate for them. This machine re-mints the certificate whenever it renders its web configuration, so saving any change from the dashboard renews it."
    else
        dr_ok "The dashboard certificate covers every name Caddy serves."
    fi

    # 30 days: generous next to the appliance's own 10-year mint — this exists to catch a
    # hand-installed short-lived certificate, not the appliance's own, which will not near this
    # window inside the life of a shipped box.
    if openssl x509 -in "$crt" -noout -checkend 2592000 >/dev/null 2>&1; then
        dr_ok "The dashboard certificate does not expire within 30 days ($enddate)."
    elif openssl x509 -in "$crt" -noout -checkend 0 >/dev/null 2>&1; then
        dr_fail_surface "The dashboard certificate expires within 30 days ($enddate). Run './pithead apply' to re-mint." "The dashboard certificate expires within 30 days ($enddate). This machine only re-mints it when the set of names it answers to changes, so it will not renew on its own; replacing it needs console access."
    else
        dr_fail_surface "The dashboard certificate has EXPIRED ($enddate) — browsers will refuse it. Run './pithead apply' to re-mint." "The dashboard certificate has EXPIRED ($enddate) — browsers will refuse it. This machine only re-mints it when the set of names it answers to changes, so it will not renew on its own; replacing it needs console access."
    fi
}
