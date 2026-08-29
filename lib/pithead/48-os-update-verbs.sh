# os-check: re-derive the latest release + its .raucb asset on the HOST, over Tor. The container
# proposes nothing here; the cached derivation is what os-download later holds the container's
# proposal against. Claim-before-dial throttle (one lookup per 10 minutes), the anti-beacon
# lesson from the one-click upgrade; a fresh cache answers without dialing at all.
control_os_check() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-check" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "started"
    local osdir tagf stampf shortstampf tag size notes rel
    osdir=$(os_update_staging_dir)
    mkdir -p "$osdir"
    tagf=$(os_update_target_file)
    stampf="$osdir/.check-stamp"
    shortstampf="$osdir/.check-stamp-short"
    if [ -z "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "an update check ran less than 10 minutes ago — retry in a few minutes."
            return 0
        fi
        if [ -n "$(find "$shortstampf" -mmin -1 2>/dev/null)" ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the last check could not confirm it reached the network — retry in about a minute."
            return 0
        fi
        # The throttle stamp is claimed AFTER the dial, and its window depends on whether the
        # dial confirmed it reached the release API (#1050, revised after review). rc 2 from
        # os_release_fetch does NOT mean "no real attempt": through Tor a circuit-build
        # timeout, an exit-relay refusal, or a mid-handshake TLS failure comes back as the
        # exact same curl nonzero as a purely local "no route" — and those DID put a real dial
        # on the wire. So rc 2 still claims a stamp, just a SHORT one (60s, "$shortstampf")
        # instead of the full 10 minutes: this bounds how often a dashboard-authenticated actor
        # can force another real Tor dial while the transport is degraded, without making an
        # operator who fixes a genuinely-down Tor daemon wait a full 10 minutes to find out. A
        # fetch that DID definitively reach GitHub — success, or a definitive refusal like the
        # rate limit below — still claims the full stamp exactly as before; that dial happened
        # and #1081 relies on it staying throttled (releasing it there would restore the
        # unthrottled beacon that guard exists to stop). Every other nonzero rc reached the
        # server.
        local fetch_rc=0
        os_release_fetch || fetch_rc=$?
        if [ "$fetch_rc" -ne 0 ]; then
            if [ "$fetch_rc" -eq 2 ]; then
                touch "$shortstampf"
            else
                touch "$stampf"
            fi
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "$GH_RELEASE_HINT"
            return 0
        fi
        touch "$stampf"
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the release API returned no usable release tag — nothing was changed."
            return 0
        fi
        size=$(printf '%s' "$rel" | jq -r --arg n "pithead-os-$tag.raucb" \
            '[.assets[]? | select(.name == $n)][0].size // 0' 2>/dev/null)
        notes=$(printf '%s' "$rel" | jq -r '.html_url // ""' 2>/dev/null | head -c 300)
        if ! printf '%s' "$size" | grep -qE '^[0-9]+$' || [ "$size" -le 0 ]; then
            control_os_refuse "$cdir" "$id" "$actor" "os-check" rejected "the latest release ($tag) publishes no appliance OS bundle — nothing to download."
            return 0
        fi
        jq -n --arg t "$tag" --argjson s "$size" --arg n "$notes" \
            '{tag:$t,size:$s,notes:$n,ts:(now|floor)}' >"$tagf.tmp" && mv "$tagf.tmp" "$tagf"
    fi
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    notes=$(jq -r '.notes // ""' "$tagf" 2>/dev/null) || notes=""
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        rm -f "$tagf"
        control_os_refuse "$cdir" "$id" "$actor" "os-check" failed "the cached update target is unreadable — it was cleared; check again in a few minutes."
        return 0
    fi
    local newer=false running
    running=$(os_running_version)
    if os_semver_ok "$running" && os_semver_ok "$tag" && semver_newer "$tag" "v$running"; then
        newer=true
    fi
    # A manual check moves the operator on — drop any leftover verdict banner with it.
    if [ -f "$cdir/results/os-update-state.json" ] &&
        [ "$(jq -r '.step // "idle"' "$cdir/results/os-update-state.json" 2>/dev/null)" = "idle" ]; then
        os_state_write "$cdir" '{"step":"idle"}'
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson s "$size" --arg n "$notes" --argjson nw "$newer" \
        '{status:"checked",version:$v,size:$s,notes:$n,newer:$nw,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-check" "checked"
}

# os-download: fetch the .raucb for the HOST-derived target to /data, resumable (`curl -C -`).
# Each intent is one bounded attempt — the dashboard resubmits on a "partial" result and the
# transfer resumes, so a Tor-slow gigabyte arrives across attempts while the runner is never
# held longer than the attempt cap. Mining is untouched throughout; nothing installs from here.
control_os_download() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-download" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "started"
    local osdir tagf tag size proposed final part
    osdir=$(os_update_staging_dir)
    tagf=$(os_update_target_file)
    tag=$(jq -r '.tag // ""' "$tagf" 2>/dev/null) || tag=""
    size=$(jq -r '.size // 0' "$tagf" 2>/dev/null) || size=0
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "no update target is known — check for updates first."
        return 0
    fi
    proposed=$(jq -r '.version // ""' "$file")
    if [ "$proposed" != "$tag" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "requested version ${proposed:-none} is not the checked release ($tag) — check for updates first, then retry."
        return 0
    fi
    # An equal version is nothing to update — refused before a byte moves, or a compromised
    # container could loop a same-version download (gigabytes over Tor) into install and reboot
    # for forced downtime and flash wear. Same-version slot repair stays with `pithead
    # os-update` at the machine, which allows equality on purpose.
    if [ "$tag" = "v$(os_running_version)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "already on $tag, nothing to update."
        return 0
    fi
    mkdir -p "$osdir"
    final="$osdir/pithead-os-$tag.raucb"
    part="$final.partial"
    # One update at a time: a partial or staged bundle for any OTHER version is superseded.
    find "$osdir" -maxdepth 1 -name 'pithead-os-*.raucb*' \
        ! -name "pithead-os-$tag.raucb" ! -name "pithead-os-$tag.raucb.partial" -delete 2>/dev/null || true
    local have=0
    [ -f "$part" ] && have=$(wc -c <"$part" | tr -d ' ')
    if [ -f "$final" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$(wc -c <"$final" | tr -d ' ')" \
            '{status:"downloaded",version:$v,bytes:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    # Disk headroom for the REMAINDER plus a 1 GiB margin, refused up front — a download that
    # fills /data would starve the chain databases mid-write, which is far worse than waiting,
    # and the LMDB chain stores degrade well before the disk actually fills. The margin has to
    # absorb the .partial in flight plus results growth for the whole transfer.
    local avail_kb need
    avail_kb=$(df -Pk "$osdir" 2>/dev/null | awk 'NR==2{print $4}') || avail_kb=0
    need=$(((size - have) / 1024 + 1048576))
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-download" rejected "not enough free space on /data for the update bundle (need about $((need / 1024)) MiB free, have $((${avail_kb:-0} / 1024)) MiB) — free space and retry."
        return 0
    fi
    local url socks="" base prefix
    if base=$(os_update_test_base); then
        url="$base/pithead-os-$tag.raucb"
    else
        prefix=$(env_get NETWORK_PREFIX 2>/dev/null) || true
        [ -n "$prefix" ] || prefix="172.28.0"
        socks="${prefix}.25:9050"
        url="https://github.com/p2pool-starter-stack/pithead/releases/download/$tag/pithead-os-$tag.raucb"
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$have" --argjson t "$size" \
        '{status:"downloading",version:$v,bytes:$b,total:$t,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloading",version:$v}')"
    # Bounded attempt in the background; the loop surfaces live progress into the result the
    # dashboard is polling. curl -C - resumes from whatever the partial file already holds.
    # (Two invocations, not a conditional argument array — macOS's bash 3.2 rejects an empty
    # array expansion under set -u, and the tier-1 suite runs this function there.)
    local attempt="${PITHEAD_OS_DL_ATTEMPT:-600}" pid rc=0 bytes
    if [ -n "$socks" ]; then
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            --socks5-hostname "$socks" -o "$part" "$url" >/dev/null 2>&1 &
    else
        curl -fSL -C - --max-time "$attempt" --max-filesize "$CURL_CAP_OS_BUNDLE" \
            -o "$part" "$url" >/dev/null 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        bytes=0
        [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"downloading",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
    done
    # Not `if ! wait`: inside that branch $? is the negation's status (always 0), which silently
    # ate every curl exit code the first time the tier-1 suite ran this.
    wait "$pid" && rc=0 || rc=$?
    bytes=0
    [ -f "$part" ] && bytes=$(wc -c <"$part" | tr -d ' ')
    if [ "$rc" -eq 0 ] && [ "$bytes" -eq "$size" ]; then
        mv "$part" "$final"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson r "$have" \
            '{status:"downloaded",version:$v,bytes:$b,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "downloaded"
        os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"downloaded",version:$v}')"
        return 0
    fi
    if [ "$rc" -eq 0 ]; then
        # The server sent a complete-but-wrong-sized body — not resumable, not trustworthy.
        rm -f "$part"
        control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download completed at $bytes bytes but the release publishes $size — the file was discarded; retry, and check for updates again if this repeats."
        return 0
    fi
    # rc 28 is curl's --max-time: the attempt window closed mid-transfer. The partial file is
    # kept either way — the next attempt resumes from it.
    if [ "$rc" -eq 28 ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson b "$bytes" --argjson t "$size" --argjson r "$have" \
            '{status:"partial",version:$v,bytes:$b,total:$t,resumed_from:$r,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "os-download" "partial"
        return 0
    fi
    control_os_refuse "$cdir" "$id" "$actor" "os-download" failed "the download failed over Tor at $bytes of $size bytes — nothing was installed; Retry resumes from where it stopped."
}

# os-verify: judge the fully-downloaded LOCAL file before anything touches a slot — signature,
# compatible, variant posture, version floor and downgrade, and the stamp-vs-tag match. A refused
# bundle is deleted; there is no override. Read-only otherwise: verifying changes nothing.
control_os_verify() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-verify" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "no fully downloaded update bundle is staged — download it first."
        return 0
    fi
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # rc 3 = rauc never ran, so no verdict was reached: the download stays staged for the
        # retry instead of being deleted on a broken tool.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-verify" rejected "$reason"
        return 0
    fi
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg va "$(os_bundle_variant "$bundle")" \
        '{status:"verified",version:$v,variant:$va,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-verify" "verified"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"verified",version:$v}')"
}

# os-install: write the verified local bundle into the inactive slot via the SAME `os_update`
# path the CLI takes (guards, floor raise, migration marker — one code path, two doors). Mining
# keeps running: RAUC writes the slot the machine is not using. On success the in-flight flag is
# persisted so the boot after the operator's explicit reboot can render an honest verdict.
control_os_install() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-install" || return 0
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "started"
    local osdir tag bundle reason keep=0
    osdir=$(os_update_staging_dir)
    tag=$(jq -r '.tag // ""' "$(os_update_target_file)" 2>/dev/null) || tag=""
    bundle="$osdir/pithead-os-$tag.raucb"
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || [ ! -f "$bundle" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "no fully downloaded update bundle is staged — download and verify it first."
        return 0
    fi
    # Re-run the whole verify gate: a result can go stale between the verify click and this one,
    # and the install must never trust a judgment it did not just make itself.
    reason=$(os_verify_bundle_reason "$bundle" "$tag") || keep=1
    if [ -n "$reason" ]; then
        # Same keep rule as os-verify: only a real verdict deletes the staged download.
        if [ "$keep" -eq 0 ]; then
            rm -f "$bundle"
            os_state_write "$cdir" '{"step":"idle"}'
        fi
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "$reason"
        return 0
    fi
    local running logf pid rc=0 pct
    running=$(os_running_version)
    logf="$osdir/.install.log"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" '{status:"installing",version:$v,percent:0,ts:(now|floor)}')"
    os_state_write "$cdir" "$(jq -n --arg v "$tag" '{step:"installing",version:$v}')"
    # os_update -y in a subshell: error() exits the subshell, never this runner, and the -y only
    # waives a variant confirmation the gate above has already refused to reach. RAUC's progress
    # lines land in the log; the loop surfaces the latest percentage to the polling dashboard.
    (os_update "$bundle" -y </dev/null) >"$logf" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        pct=$(grep -oE '[0-9]+%' "$logf" 2>/dev/null | tail -1 | tr -d '%') || pct=""
        control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --argjson p "${pct:-0}" \
            '{status:"installing",version:$v,percent:$p,ts:(now|floor)}')"
    done
    # Same wait shape as the download's: `if ! wait` would eat the subshell's exit code.
    wait "$pid" && rc=0 || rc=$?
    # Contention, not a failed install: os_update timed out waiting for another pithead operation
    # and exited before it reached rauc, so no slot was written. Falling through to the generic
    # branch below would report a FAILED install whose message asserts the running system is
    # untouched — true, and misleading, because nothing was attempted at all. Same shape and the
    # same reasoning as the firstboot wizard's contention branch (wizard_setup_failed). "rejected"
    # rather than "failed" matches this runner's own vocabulary for a request that never ran.
    if [ "$rc" -eq "$PITHEAD_EX_LOCK_TIMEOUT" ]; then
        warn "OS install could not start: another pithead operation still held the machine."
        control_os_refuse "$cdir" "$id" "$actor" "os-install" rejected "another pithead operation was already running, so the install was not started — nothing was changed. Try again once it has finished."
        rm -f "$logf"
        os_state_write "$cdir" '{"step":"idle"}'
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        # The raw install log is a host detail (staging paths, slot devices) and stays host-side:
        # the full tail goes to the journal, and the container-visible result carries only the
        # final error line whitelist-extracted from the log — rauc's own last word, or nothing.
        local detail
        detail=$(grep -aE '^LastError: |^\[ERROR\] |[Ff]ailed' "$logf" 2>/dev/null |
            grep -av 'pithead aborted unexpectedly' |
            tail -1 | tr -d '[:cntrl:]' | head -c 300) || detail=""
        warn "OS install failed (rc=$rc); log tail: $(tail -c 500 "$logf" 2>/dev/null | tr -d '[:cntrl:]')"
        control_os_refuse "$cdir" "$id" "$actor" "os-install" failed "the install did not complete — the running system is untouched and mining continues.${detail:+ $detail} The full install log is in the host journal."
        rm -f "$logf"
        # #1050: a terminal-failure transition. Without this the persisted step stayed
        # "installing" forever — nothing ever moved it off that value on a failed install — so
        # the dashboard kept showing an install in progress that had already ended and would
        # never finish or fail again. idle matches the state a fresh appliance starts in: Check
        # and Download are offered again on the next open.
        os_state_write "$cdir" '{"step":"idle"}'
        return 0
    fi
    local bundle_version
    bundle_version="${tag#v}"
    jq -n --arg f "$running" --arg t "$bundle_version" '{from:$f,to:$t,ts:(now|floor)}' \
        >"$(os_update_inflight_file)"
    # The staged bundle did its job — free the space before the reboot the operator will order.
    rm -f "$bundle" "$(os_update_target_file)" "$logf"
    control_write_result "$cdir/results" "$id" "$(jq -n --arg v "$tag" --arg f "$running" \
        '{status:"installed",version:$v,from:$f,ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-install" "installed"
    os_state_write "$cdir" "$(jq -n --arg v "$bundle_version" --arg f "$running" \
        '{step:"reboot-pending",version:$v,from:$f}')"
}

# os-reboot: the ONLY verb that interrupts mining, in its own allowlisted intent so rebooting the
# machine never rides implicitly on any other action. Refused unless an installed update is
# actually waiting — the dashboard must never be a general reboot lever.
control_os_reboot() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    control_os_gate "$cdir" "$id" "$actor" "os-reboot" || return 0
    if [ ! -f "$(os_update_inflight_file)" ]; then
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "no installed update is waiting for a reboot — nothing to finish."
        return 0
    fi
    # The install result authorizes the reboot for 24 hours, then goes stale. The gate proves
    # "an installed update is waiting", never "the operator asked just now" — within the window
    # a spool writer can still time the reboot, so the TTL bounds how long that lever stays
    # armed rather than pretending it does not exist. An unreadable timestamp is not proof of
    # freshness and refuses too; a fresh verify and install re-arms it.
    local armed_ts
    armed_ts=$(jq -r '.ts // 0' "$(os_update_inflight_file)" 2>/dev/null) || armed_ts=0
    printf '%s' "$armed_ts" | grep -qE '^[0-9]+$' || armed_ts=0
    if [ "$armed_ts" -le 0 ] || [ $(($(date +%s) - armed_ts)) -gt 86400 ]; then
        # #1050: the re-arm transition the comment above always promised but never performed.
        # The flag alone used to survive this refusal, so the persisted step stayed
        # "reboot-pending" forever — the dashboard kept offering only "Reboot now", which kept
        # refusing, with no button that ever led back to Check/Download. Clearing the expired
        # flag and the step together is what actually re-arms it: the next open finds an
        # ordinary idle appliance, exactly as the message already claimed.
        rm -f "$(os_update_inflight_file)"
        os_state_write "$cdir" '{"step":"idle"}'
        control_os_refuse "$cdir" "$id" "$actor" "os-reboot" rejected "the installed update has been waiting more than a day and has expired — check for updates again; a fresh verify and install re-arms the reboot."
        return 0
    fi
    # The result must land BEFORE the reboot order or the page never learns the reboot is real.
    control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rebooting",ts:(now|floor)}')"
    control_audit "$cdir/audit/control.log" "$id" "$actor" "os-reboot" "rebooting"
    systemctl reboot 2>/dev/null || true
}
