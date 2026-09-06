# shellcheck shell=bash
# shellcheck disable=SC2154  # ip is run.sh's: the guest address _wait_dhcp_ip assigns, a global there
#
# The reinstall pre-fill submit leg (#1846). Sourced by tests/os/run.sh and run LAST in
# phase_install, when nothing after it needs the target disk. The operator's path that refused:
# the installer booted over a disk that already holds a Pithead install, so the host publishes
# the previous machine's answers as the page's pre-fill (#794, prefill_from_previous_install), and
# the browser then submits that pre-fill whole beside "Generate a strong password for me"
# (auth_mode=auto) and a wipe mode. The host validates the candidate BEFORE it generates a
# password and before it touches the disk, so a pre-fill that carries a switch needing a login
# (dashboard.control.enabled) with the login stripped is refused on the operator's own answers.
# The fresh-disk provision leg cannot see this: its candidate carries no dashboard block at all.
#
# NON-DESTRUCTIVE BY CONSTRUCTION. The card is published before the erase and the erase is
# released only by the acknowledgement, which this leg never sends; the host then hands the form
# back ("Credentials were never confirmed — nothing was installed"). A refusal installs nothing
# either. The disk is the same after the leg as before it, whichever way the row goes.
#
# $1 = a disk holding a provisioned install (the reinstall leg's target); $DISK still holds the
# installer image the restore leg booted from; ip/SERIAL/VM/HARNESS_WALLET from run.sh.
phase_install_prefill_submit_leg() { # <target-disk>
    local target_disk="$1" token="" tries=0 jar scode handoff="" page_err=""
    info "pre-fill submit leg (#1846) — the previous machine's answers, submitted as a browser does"
    _ssh "systemctl poweroff" 2>/dev/null || true
    sleep 8
    vm_destroy
    : >"$SERIAL"
    kvm_preflight || exit 1 # #1059: never boot a 16 GiB guest the host cannot back
    virt-install --name "$VM" --memory 16384 --vcpus 4 --cpu host-passthrough \
        --osinfo debian12 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --import \
        --disk "path=$DISK,format=raw,bus=usb,removable=on,boot.order=1" \
        --disk "path=$target_disk,format=raw,bus=virtio,boot.order=2" \
        --network network=default,model=virtio --graphics none \
        --serial "file,path=$SERIAL" --noautoconsole >/dev/null 2>&1 || {
        bad "pre-fill submit leg: virt-install failed for the installer boot"
        return
    }
    _wait_dhcp_ip 120
    _wait_ssh 240 || {
        bad "pre-fill submit leg: installer guest never answered SSH"
        return
    }
    while [ -z "$token" ] && [ "$tries" -lt 40 ]; do
        token=$(tr -d '\r' <"$SERIAL" | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] || sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] && _wait_setup_page 180 || {
        bad "pre-fill submit leg: the installer wizard never served its gate"
        return
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null &&
        grep -q "wizard_session" "$jar" || {
        bad "pre-fill submit leg: wizard auth failed"
        rm -f "$jar"
        return
    }
    # Fixture-works control: the page must be OFFERING the previous install's answers, or the
    # candidate below is a blank form and the row cannot reach the #1846 path. The pre-fill is
    # read off the disk before the page is served, so the first read carrying a wallet is the
    # verdict; a red names the wallet it saw, or what the reads saw when none carried one (#1936).
    wizard_state_poll "$ip" "$jar" '.config.monero.wallet_address // empty' || true
    case "$WIZ_STATE" in
    "${HARNESS_WALLET:0:8}"*) ok "pre-fill submit leg: the page offers the previous install's answers (pre-fill armed)" ;;
    *)
        bad "pre-fill submit leg: pre-fill NOT armed, the leg cannot reach the #1846 path (served wallet: ${WIZ_STATE:-none; $WIZ_STATE_WHY})"
        rm -f "$jar"
        return
        ;;
    esac
    # What the browser sends on this page: the served pre-fill whole, auth_mode=auto, the disk
    # retyped, and a wipe mode other than keep (keep never carries a config across).
    scode=$(provision_browser_submit "$ip" "$jar" "disk=vda" "confirm=vda" "wipe=data")
    [ "$scode" = "200" ] || {
        bad "pre-fill submit leg: submit did not return 200 (got ${scode:-none})"
        rm -f "$jar"
        return
    }
    tries=0
    while [ "$tries" -lt 24 ]; do
        handoff=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        printf '%s' "$handoff" | grep -q '"password"' && break
        page_err=$(provision_page_error "$ip" "$jar")
        [ -z "$page_err" ] || break
        sleep 5
        tries=$((tries + 1))
    done
    rm -f "$jar" # never acknowledged: the ack is what releases the erase
    if printf '%s' "$handoff" | jq -r '.password // ""' 2>/dev/null | grep -qE '^[A-Za-z0-9]{32}$'; then
        ok "pre-fill submit leg: the previous answers validated and the card carries a generated password (#1846)"
    else
        bad "pre-fill submit leg: no generated password for the pre-filled answers${page_err:+ — the page says: $page_err}${page_err:-" (no card, no error, ${tries}x5s)"}"
    fi
}
