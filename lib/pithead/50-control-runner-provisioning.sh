# The directory the dashboard control units live in — ONE rule, shared by the writer and both
# readers. The appliance's root is read-only by design, so /etc/systemd/system cannot take the unit
# (#791); /run/systemd/system is a first-class unit path, writable, and cleared every boot, which is
# fine because these units are derived and the boot path re-renders them. A DIY host keeps /etc.
# This was two rules until #1151: `provision_control_runner` knew about /run and `doctor` did not,
# so on a PROVISIONED appliance doctor reported "no runner units are installed" about units that
# were installed and running. That is the half of the boot health gate that never passed, so the
# slot never committed — and after #1065 the box reboots a healthy, correctly-updated appliance.
control_unit_dir() {
    if [ -n "${PITHEAD_UNIT_DIR:-}" ]; then
        printf '%s' "$PITHEAD_UNIT_DIR"
    elif is_appliance; then
        printf '%s' /run/systemd/system
    else
        printf '%s' /etc/systemd/system
    fi
}

# Physical directory the installed control units name, or "" when there is no service unit or its
# ExecStart is unparseable. One checkout has two spellings — the `current` symlink and the versioned
# dir it points at (production units carry the versioned spelling) — so this resolves to a PHYSICAL
# path; comparing the literal string would call our own unit foreign. A stranded unit usually names
# a directory that no longer exists, so resolve the deepest existing ancestor and keep the rest
# verbatim: the caller still gets a comparable, printable path instead of an empty answer.
control_units_owner_dir() {
    local unit_dir owner_dir dir tail
    unit_dir=$(control_unit_dir)
    owner_dir=$(sed -n 's|^ExecStart=\(/.*\)/pithead control-run-pending$|\1|p' \
        "$unit_dir/pithead-control.service" 2>/dev/null | head -n 1)
    [ -n "$owner_dir" ] || return 0
    dir="$owner_dir" tail=""
    while [ -n "$dir" ] && [ "$dir" != "/" ] && [ ! -d "$dir" ]; do
        tail="/$(basename "$dir")$tail"
        dir=$(dirname "$dir")
    done
    printf '%s' "$(cd "$dir" 2>/dev/null && pwd -P)$tail"
}

# Install (or remove) the systemd trigger for the runner (#33): a path unit that fires
# `pithead control-run-pending` whenever a request file lands in the spool. Root, because `apply`
# needs iptables/chown; the service is a FIXED ExecStart with no parameter from the container, so
# a compromised dashboard cannot steer it into anything but the two known verbs. No-op on hosts
# without systemd (macOS/dev checkouts run the runner by hand).
provision_control_runner() {
    [ "$OS_TYPE" == "Linux" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local unit_dir
    unit_dir=$(control_unit_dir)
    # Enablement must be --runtime wherever the units are runtime units: on the appliance's
    # read-only root, systemd cannot write the /etc symlink a persistent enable needs.
    local -a enable_args=(enable --now)
    case "$unit_dir" in /run/*) enable_args=(enable --runtime --now) ;; esac
    if [ "${DASHBOARD_CONTROL_ENABLED:-false}" != "true" ]; then
        if [ -e "$unit_dir/pithead-control.path" ] || [ -e "$unit_dir/pithead-control.service" ]; then
            # The unit names are box-global but a box can hold several checkouts (release bench:
            # live stack + e2e harness + bundle-smoke tmp dirs). Only remove units whose ExecStart
            # points at THIS checkout — deleting a sibling's runner strands its dashboard control
            # requests unprocessed (the editor hangs at "Previewing…" until that stack's next
            # apply/upgrade reinstalls the units).
            # Ownership compares PHYSICAL paths: one checkout has two spellings — the `current`
            # symlink and the versioned dir it points at (production units carry the versioned
            # spelling). A literal $PWD compare would call our own unit foreign and never remove
            # it. If the unit's dir is gone, resolve the deepest existing ancestor and keep the
            # rest verbatim; an unparseable ExecStart is foreign (fail safe, leave it alone).
            if [ -e "$unit_dir/pithead-control.service" ]; then
                local owner_dir
                owner_dir=$(control_units_owner_dir)
                if [ -z "$owner_dir" ] || [ "$owner_dir" != "$(pwd -P)" ]; then
                    log "Leaving the dashboard control runner units alone — they belong to another checkout."
                    return 0
                fi
            fi
            log "Removing the dashboard control runner units..."
            sudo systemctl disable --now pithead-control.path >/dev/null 2>&1 || true
            sudo rm -f "$unit_dir/pithead-control.path" "$unit_dir/pithead-control.service"
            sudo systemctl daemon-reload
        fi
        return 0
    fi
    # Already installed for this checkout — keep the routine apply sudo-free. (-F: both paths
    # are literals — versioned dirs carry dots (pithead-v1.9.3), and the glob star must not
    # read as a regex repeat.)
    if grep -qsF "PathExistsGlob=$CONTROL_DIR/requests/*.json" "$unit_dir/pithead-control.path" &&
        grep -qsF "ExecStart=$PWD/pithead control-run-pending" "$unit_dir/pithead-control.service"; then
        return 0
    fi
    # The grep above is an idempotence skip, not an ownership check. The removal branch got its
    # ownership guard when a disable-apply deleted the live stack's units; the install branch had
    # none, so any sibling checkout's apply/up (e2e harness, bundle-smoke tmp dir, disposable
    # install) silently repointed the box-global units at itself — the exact mechanism behind the
    # production control-channel stranding. A unit naming a DIFFERENT install that still exists on
    # disk is someone's live runner: refuse. A unit whose directory is gone is adoptable (the
    # failed-upgrade repair), our own unit converges (the post-restore proof depends on it), and an
    # unparseable ExecStart is left alone, fail-safe, like the removal branch. Deliberate takeover
    # has two spellings: the upgrade callsite passes the `steal` argument (after a successful
    # upgrade the units MUST repoint here — the old versioned dir still exists as the rollback, so
    # without the escape every one-click upgrade would refuse and strand the control channel), and
    # PITHEAD_STEAL_CONTROL_UNITS=1 is the operator's escape (manual migration, repair).
    if [ -e "$unit_dir/pithead-control.service" ] && [ "${1:-}" != "steal" ] &&
        [ "${PITHEAD_STEAL_CONTROL_UNITS:-0}" != "1" ]; then
        local install_owner
        install_owner=$(control_units_owner_dir)
        if [ -z "$install_owner" ]; then
            warn "Not installing the dashboard control runner: $unit_dir/pithead-control.service exists but its ExecStart is not one this tool wrote. Inspect it, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to overwrite it; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
        if [ "$install_owner" != "$(pwd -P)" ] && [ -d "$install_owner" ]; then
            warn "Not installing the dashboard control runner: the box-global units belong to the install at $install_owner. Run this from that checkout, or re-run with PITHEAD_STEAL_CONTROL_UNITS=1 to take the units over; until a runner watches this install, dashboard config changes are not applied."
            return 0
        fi
    fi
    log "Installing the dashboard control runner (systemd path unit)..."
    sudo tee "$unit_dir/pithead-control.service" >/dev/null <<EOF
[Unit]
Description=pithead dashboard control runner (#33)

[Service]
Type=oneshot
User=root
WorkingDirectory=$PWD
ExecStart=$PWD/pithead control-run-pending
EOF
    sudo tee "$unit_dir/pithead-control.path" >/dev/null <<EOF
[Unit]
Description=Watch the pithead control spool for dashboard requests (#33)

[Path]
PathExistsGlob=$CONTROL_DIR/requests/*.json

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl "${enable_args[@]}" pithead-control.path >/dev/null 2>&1 ||
        warn "Could not enable pithead-control.path — dashboard config changes will not be applied until it is enabled."
}
