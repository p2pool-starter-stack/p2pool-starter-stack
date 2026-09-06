# shellcheck shell=bash
# shellcheck disable=SC2154  # ip, token, jar and SERIAL are run.sh's — the guest address, the session, the console log
#
# The boot menu's "Set up again" entry, tier 4 (#1318). Sourced by tests/os/run.sh and run inside
# phase_rig on the guest the reboot leg just left: a provisioned rig, mining, slot A committed.
# Three legs, each a boot from that entry. Keep it: the page closes and the rig mines again with
# the SAME token. Set up again as the same rig: the card shows the SAME token, so the coordinator's
# adoption survives. And after the update leg has moved the rig to slot B, Set up again as a
# coordinator: the role and its data are replaced — and the entry followed the default to slot B.
#
# The entry is chosen the way the running system would choose it: `grub-editenv set next_entry=3`
# in the ESP's grubenv, which grub.cfg consumes for exactly one boot. Never keystrokes on the
# serial console. The page's "Keep it" is the fixes lane's screen; here it is what that screen
# writes — an empty keep-role in the spool — touched over SSH. That proves the HOST half (the
# marker ends the session with nothing changed) independent of the SPA, which is proven at tier 1.

SA_SPOOL=/data/pithead/data/firstboot

# Boot the "Set up again" entry once, and wait for the new boot. $1 = seconds. rc 1 = reported.
_setup_again_boot() {
    _ssh "mount -o remount,rw /boot/efi && grub-editenv /boot/efi/grub/grubenv set next_entry=3" || {
        bad "could not write next_entry into the ESP's grubenv"
        return 1
    }
    # Where the console log ends NOW: the session below reads only what this boot prints after
    # it. The log is continuous across in-guest reboots, so "the last token on the console" is
    # the previous session's until the new one appears — leg 3 once posted leg 2's token off
    # exactly that and the gate refused it.
    SA_SERIAL_OFFSET=$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)
    _reboot_wait reboot "$1" || {
        bad "the guest never returned from the reboot into the setup entry"
        return 1
    }
    # The unit is 'activating' for as long as the page is open; sshd answers before it starts.
    local n=0 st=""
    while [ "$n" -lt 24 ]; do
        st=$(_ssh 'systemctl is-active pithead-setup-again' 2>/dev/null | tr -d '\r\n')
        [ "$st" = activating ] && break
        sleep 5
        n=$((n + 1))
    done
    [ "$st" = activating ] && ok "pithead-setup-again holds the boot (activating) while the page is open" ||
        bad "pithead-setup-again is '${st:-unreadable}' 120 s into the boot — the flag was not honoured"
}

# The wizard session on a set-up-again boot: the token THIS boot minted (read past the offset
# _setup_again_boot took before the reboot, never the last session's), the page served, a session
# cookie in $jar. Sets token and jar in the caller; rc 1 = reported.
_setup_again_session() {
    local tries=0 from="${SA_SERIAL_OFFSET:-0}"
    # A harness-driven guest boot truncates the console log; then everything in it is this boot's.
    [ "$(stat -c %s "$SERIAL" 2>/dev/null || echo 0)" -ge "$from" ] || from=0
    token=""
    while [ "$tries" -lt 40 ]; do
        token=$(tail -c +"$((from + 1))" "$SERIAL" | tr -d '\r' | grep -oE 'pit-[A-Z0-9]{6}' | tail -1)
        [ -n "$token" ] && break
        sleep 3
        tries=$((tries + 1))
    done
    [ -n "$token" ] || {
        bad "no one-time token appeared on the console after the reboot into the setup entry"
        return 1
    }
    _wait_setup_page 120 || {
        bad "the setup page never served on the set-up-again boot"
        return 1
    }
    jar=$(mktemp)
    curl -fsSk -c "$jar" -d "token=$token" "https://$ip/auth" -o /dev/null 2>/dev/null && grep -q wizard_session "$jar" || {
        bad "the set-up-again token was not accepted (or no session cookie came back)"
        rm -f "$jar"
        return 1
    }
    ok "the setup page is up on the set-up-again boot, with a fresh token ($token)"
}

# Submit the rig form and wait for its card. $1 = worker; prints the card's token; rc 1 = reported.
_setup_again_rig_submit() {
    local scode card tries=0
    scode=$(curl -sSk -b "$jar" --data "role=rig&rig_pool=127.0.0.1:22&rig_worker=$1" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "rig submit on the set-up-again page returned ${scode:-none}, want 200"
        return 1
    }
    while [ "$tries" -lt 24 ]; do
        card=$(curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null)
        case "$card" in *'"worker"'*) break ;; esac
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] || {
        bad "no rig card appeared after Set up again"
        return 1
    }
    # Both fields on ONE line: this runs under $(...), so a variable set here dies with the
    # subshell — the first battery read an empty address off exactly that (#1318 rig-leg red).
    printf '%s' "$card" | jq -r '"\(.token // "") \(.address // "")"' 2>/dev/null
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || true
}

# Legs 1 and 2, on a committed, mining rig. $1 = the token the provisioning card showed,
# $2 = the provisioning session's one-time token. Leaves the rig mining as kvm-rig.
rig_setup_again_legs() {
    local tok0="$1" token="$2" jar="" cmd st n card_tok saved sa_card_address=""
    info "set-up-again leg 1 (#1318) — the menu entry opens the wizard beside the saved rig; Keep it"
    _setup_again_boot 300 || return
    cmd=$(_ssh cat /proc/cmdline 2>/dev/null | tr -d '\r')
    case "$cmd" in
    *pithead.setup=1*rauc.slot=A* | *rauc.slot=A*pithead.setup=1*) ok "GRUB booted the setup entry: the flag rides the slot the default would have booted (A)" ;;
    *) bad "the setup entry did not boot slot A with the flag — cmdline: $(printf '%s' "$cmd" | cut -c1-160)" ;;
    esac
    case "$(_ssh 'grub-editenv /boot/efi/grub/grubenv list' 2>/dev/null | tr -d '\r')" in
    *next_entry=3*) bad "next_entry is still set — the NEXT boot would open the page again" ;;
    *) ok "next_entry was consumed: the next boot takes the default entry again" ;;
    esac
    [ "$(_ssh 'systemctl is-active pithead-boot' 2>/dev/null | tr -d '\r\n')" = inactive ] &&
        ok "pithead-boot waits behind the page — the rig's normal boot is not taken" ||
        bad "pithead-boot ran beside the open page"
    _ssh "systemctl is-active --quiet pithead-firstboot" 2>/dev/null &&
        bad "pithead-firstboot ran on a provisioned rig — the flag must not reopen the first-boot unit" ||
        ok "the first-boot unit stays closed: the marker decides, the flag does not"
    _ssh "systemctl is-active --quiet xmrig" 2>/dev/null &&
        bad "the miner is running beside the open page — the normal boot was taken" ||
        ok "the miner is not started beside the page"
    _setup_again_session || return
    saved=$(_ssh "cat $SA_SPOOL/saved-role.json" 2>/dev/null | tr -d '\r')
    printf '%s' "$saved" | jq -e '.role == "rig" and .worker == "kvm-rig" and .pool == "127.0.0.1:22"' >/dev/null 2>&1 &&
        ok "the page is told the saved role: rig, kvm-rig -> 127.0.0.1:22" ||
        bad "saved-role.json is not the saved rig: ${saved:-empty}"
    [ "$(printf '%s' "$saved" | jq -c 'keys' 2>/dev/null)" = '["pool","role","worker"]' ] &&
        ok "saved-role.json carries no secret: exactly role, pool, worker" ||
        bad "saved-role.json carries more than role, pool, worker: $(printf '%s' "$saved" | jq -c 'keys' 2>/dev/null)"
    _ssh "jq -e '.pool == \"127.0.0.1:22\" and .worker == \"kvm-rig\"' $SA_SPOOL/rig-defaults.json >/dev/null" 2>/dev/null &&
        ok "the rig form pre-fills from the saved answers, not a fresh LAN probe" ||
        bad "rig-defaults.json does not carry the saved pool + worker"
    # Keep it — what the page's button writes, written here.
    _ssh "touch $SA_SPOOL/keep-role && chown 1000:1000 $SA_SPOOL/keep-role" >/dev/null 2>&1 || true
    rm -f "$jar"
    n=0
    while [ "$n" -lt 24 ]; do
        st=$(_ssh 'systemctl is-active pithead-setup-again' 2>/dev/null | tr -d '\r\n')
        [ "$st" = active ] && break
        sleep 5
        n=$((n + 1))
    done
    [ "$st" = active ] && ok "Keep it: the page closed and the unit ended clean (active, exited)" ||
        bad "the setup-again unit is '${st:-unreadable}' 120 s after keep-role was written"
    # The keep line is a JOURNAL line (journal+console on the unit), but this is a rig: minutes
    # into every boot pithead-boot flips journald volatile and reclaims the persistent journal
    # (#1817, 14-local-miner.sh), taking this boot's earlier entries with it — by the time the
    # miner is up, `journalctl -b -u pithead-setup-again` is empty. journald's own console
    # forward of the entry (`pithead[<pid>]: [pithead] ...`, distinct from _console's bare tty
    # write) is the durable witness that the line reached the journal.
    tr -d '\r' <"$SERIAL" | grep -qE 'pithead\[[0-9]+\]: \[pithead\] Setup closed: the saved settings are kept' &&
        ok "the host logged the keep, by name (the journal entry, via its console forward)" ||
        bad "no 'saved settings are kept' journal entry reached the console"
    _ssh "test ! -e $SA_SPOOL/keep-role" 2>/dev/null && ok "keep-role was consumed" ||
        bad "keep-role is still in the spool — a later session would close at once"
    _rig_mining_up 24 && ok "the rig mines again after Keep — pithead-boot ran the boot it would have" ||
        bad "the rig did not come back mining after Keep (unit: $(_ssh 'systemctl is-active xmrig' 2>/dev/null || echo unknown))"
    [ "$(_ssh 'jq -r .access_token /data/pithead/rig.json' 2>/dev/null | tr -d '\r\n')" = "$tok0" ] &&
        ok "the control token survived Keep" || bad "the token in rig.json changed on Keep"
    [ "$(_ssh 'cat /data/pithead/machine-role' 2>/dev/null | tr -d '\r\n')" = rig ] &&
        ok "the role marker is untouched by Keep" || bad "the role marker changed on Keep"

    info "set-up-again leg 2 — Set up again as the same rig keeps the token"
    _setup_again_boot 300 || return
    _setup_again_session || return
    card_tok=$(_setup_again_rig_submit kvm-rig) || {
        rm -f "$jar"
        return
    }
    rm -f "$jar"
    sa_card_address=${card_tok#* }
    card_tok=${card_tok%% *}
    [ -n "$card_tok" ] && [ "$card_tok" = "$tok0" ] &&
        ok "same role + worker: the card shows the SAME token — the coordinator's adoption survives" ||
        bad "the card's token changed on an unchanged rig ('${card_tok:0:8}' vs '${tok0:0:8}')"
    # #1836's card field the first battery never read (reviewer finding on the #1836 PR): the address
    # the adopt form needs must be THIS guest's, not empty and not another interface's.
    [ "$sa_card_address" = "$ip" ] && ok "the card's address is the guest's own ($ip) — the adopt form can reach it" ||
        bad "the card's address is '${sa_card_address:-empty}', the guest answers on $ip"
    _rig_mining_up 36 && ok "the rig mines after Set up again" || bad "the rig did not come up after Set up again"
    [ "$(_ssh 'jq -r .ACCESS_TOKEN /data/rigforge/config.json' 2>/dev/null | tr -d '\r\n')" = "$tok0" ] &&
        ok "the miner enforces the kept token" || bad "the miner's config carries a different token after Set up again"
    [ -z "$(_ssh 'ls /data/pithead/config.json 2>/dev/null')" ] &&
        ok "still no coordinator config on the rig" || bad "a config.json appeared on the rig after Set up again"
}

# Leg 3, at the end of the phase: the rig runs the updated slot B, committed. Set up again as a
# coordinator replaces the role and its data. ($1, the last session's token, is no longer what
# the session keys on — see _setup_again_boot — but run.sh still hands it over.)
rig_setup_again_coordinator_leg() {
    local token="$1" jar="" cmd scode tries=0 n=0 role
    info "set-up-again leg 3 — Set up again as a coordinator replaces the role (from slot B)"
    # The COMMIT leg's reboot left GRUB's try-count on B raised (B_TRY=1) until pithead-boot
    # re-commits it on the miner running. The setup entry follows what the DEFAULT would boot,
    # and an uncommitted B is not it — the first battery rebooted inside that window and the
    # entry correctly took A. Wait for the rig's own re-commit; that it happens is the property.
    while [ "$n" -lt 24 ]; do
        case "$(_ssh 'grub-editenv /boot/efi/grub/grubenv list' 2>/dev/null | tr -d '\r' | tr '\n' ' ')" in
        *"B_OK=1 "*"B_TRY=0"* | *"B_TRY=0"*"B_OK=1"*) break ;;
        esac
        sleep 5
        n=$((n + 1))
    done
    [ "$n" -lt 24 ] && ok "the updated slot re-committed itself on the next boot (B_OK=1 B_TRY=0), no hands" ||
        bad "slot B did not re-commit within 120 s of the COMMIT reboot — the setup entry would follow the fallback"
    n=0
    _setup_again_boot 300 || return
    cmd=$(_ssh cat /proc/cmdline 2>/dev/null | tr -d '\r')
    case "$cmd" in
    *pithead.setup=1*rauc.slot=B* | *rauc.slot=B*pithead.setup=1*) ok "after the update the setup entry followed the default to slot B" ;;
    *) bad "the setup entry did not follow the default to slot B — cmdline: $(printf '%s' "$cmd" | cut -c1-160)" ;;
    esac
    _setup_again_session || return
    scode=$(curl -sSk -b "$jar" --data "monero_wallet=$HARNESS_WALLET&tari_wallet=$HARNESS_TARI&pool=mini" "https://$ip/submit" -o /dev/null -w '%{http_code}' 2>/dev/null)
    [ "$scode" = "200" ] || {
        bad "coordinator submit on the set-up-again page returned ${scode:-none}, want 200"
        rm -f "$jar"
        return
    }
    while [ "$tries" -lt 24 ]; do
        curl -sSk -b "$jar" -m 5 "https://$ip/api/handoff" 2>/dev/null | grep -q '"password"' && break
        sleep 5
        tries=$((tries + 1))
    done
    [ "$tries" -lt 24 ] && ok "a coordinator's credentials card appeared on the set-up-again page" ||
        bad "no coordinator card appeared — the config was not accepted (error: $(_ssh "cat $SA_SPOOL/error.txt" 2>/dev/null | cut -c1-160))"
    curl -sSk -b "$jar" -X POST "https://$ip/handoff-ack" -o /dev/null 2>/dev/null || true
    rm -f "$jar"
    while [ "$n" -lt 18 ]; do
        role=$(_ssh 'cat /data/pithead/machine-role' 2>/dev/null | tr -d '\r\n')
        [ "$role" = pithead ] && break
        sleep 5
        n=$((n + 1))
    done
    [ "$role" = pithead ] && ok "the role marker was replaced: rig -> pithead" || bad "the role marker still says '${role:-nothing}' 90 s after the ack"
    _ssh "test -s /data/pithead/config.json" 2>/dev/null && ok "the coordinator's config.json was written" || bad "no config.json after accepting the coordinator role"
    _ssh "test ! -e /data/pithead/rig.json" 2>/dev/null && ok "rig.json (and the token in it) went with the rig role" || bad "rig.json survived a role change to coordinator"
}
