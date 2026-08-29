# --- OS update over the control channel (appliance A/B slots, dashboard-driven) ---------------
# The dashboard container only ASKS; every verb below re-derives, re-verifies and executes on the
# HOST, and every one refuses outright on a non-appliance host (no RAUC, nothing to update).
# The flow is deliberately staged — check, download (resumable, to /data), verify the LOCAL file,
# install the verified local bundle, then an EXPLICIT reboot — so every network step is separated
# from every destructive step and a bundle is never stream-installed over Tor.

os_update_staging_dir() { printf '%s' "${PITHEAD_OS_UPDATE_DIR:-$PWD/data/os-update}"; }
os_update_inflight_file() { printf '%s/in-flight.json' "$(os_update_staging_dir)"; }
os_update_target_file() { printf '%s/target.json' "$(os_update_staging_dir)"; }

# The persistent OS-update state the dashboard renders (step across reloads and reboots, and the
# post-reboot verdict). Lives in the results/ leg of the control spool under a fixed non-uuid
# name, so it rides the existing read-only mount into the container — its presence is also how
# the dashboard knows it runs on an appliance at all. Atomic like control_write_result.
os_state_write() { # <control-dir> <json>
    mkdir -p "$1/results" 2>/dev/null || true
    printf '%s\n' "$2" >"$1/results/.os-update-state.tmp" &&
        mv "$1/results/.os-update-state.tmp" "$1/results/os-update-state.json"
}

# ponytail: test seam for the KVM battery — a root-owned `os-update-test-base` file beside the
# checkout redirects the release lookup and the bundle download to a local URL (and drops the
# Tor SOCKS, which cannot reach the bench). The ownership check stops a non-root plant from
# steering root's downloads; verification still runs for real against the slot keyring either
# way, so the seam can redirect WHERE the bytes come from but never what installs.
os_update_test_base() {
    local f="$PWD/os-update-test-base"
    { [ -f "$f" ] && [ -O "$f" ]; } || return 1
    tr -d ' \t\r\n' <"$f"
}

# The latest-release JSON, over the stack's own Tor SOCKS like every other stack egress.
#
# The real lookup is gh_release_fetch's, not a third copy of it. This one used `curl -fsS`, and
# `-f` collapses every non-2xx into one exit code — so a spent GitHub rate limit came out of
# os-check as "could not reach the release API over Tor" and sent the operator to a doctor run
# that correctly reports Tor healthy (#1081, which fixed the two DIY lookups and never saw this
# one). Only the bench seam keeps its own dial: it points at a local URL with no Tor in the path.
# Sets GH_RELEASE_JSON on success and GH_RELEASE_HINT on failure, like the shared fetch, so the
# caller must run it as a plain command — a command substitution is a subshell and would discard
# both. rc 2 = never reached the server at all, same convention as gh_release_fetch (#1050).
os_release_fetch() {
    local base
    if base=$(os_update_test_base); then
        GH_RELEASE_HINT=""
        GH_RELEASE_JSON=""
        if ! GH_RELEASE_JSON=$(curl -fsS --max-time 60 --max-filesize "$CURL_CAP_SMALL" \
            "$base/releases-latest.json" 2>/dev/null); then
            GH_RELEASE_HINT="could not reach the release API — nothing was changed."
            return 2
        fi
        return 0
    fi
    gh_release_fetch p2pool-starter-stack/pithead
}

# One shared refusal writer for the os-* verbs (they share one result/audit shape).
control_os_refuse() { # <cdir> <id> <actor> <action> <status rejected|failed> <reason>
    control_write_result "$1/results" "$2" "$(jq -n --arg s "$5" --arg e "$6" '{status:$s,error:$e,ts:(now|floor)}')"
    control_audit "$1/audit/control.log" "$2" "$3" "$4" "$5"
}

# The gate every os-* verb opens with: appliance only, and at most ONE os verb per drain — a
# download or install holds the single-threaded root runner for minutes, so a compromised
# container queueing a flood must not starve commit/restart intents (the worker-upgrade lesson).
control_os_gate() { # <cdir> <id> <actor> <action> — rc 0 = proceed (budget consumed)
    if ! is_appliance; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "OS updates apply only to a Pithead OS appliance — this install updates through release tarballs (the header upgrade button). Nothing was changed."
        return 1
    fi
    if [ "${CONTROL_OS_BUDGET:-0}" -le 0 ]; then
        control_os_refuse "$1" "$2" "$3" "$4" rejected "another OS-update step is already running in this cycle — retry in a moment."
        return 1
    fi
    CONTROL_OS_BUDGET=$((CONTROL_OS_BUDGET - 1))
    return 0
}

# The local-bundle refusals shared by os-verify and os-install (install re-runs them so a result
# can never go stale between the two clicks). Echoes the refusal reason; empty = pass. Returns 0
# for a real verdict — the caller deletes a refused bundle, only bundles that verify may sit
# staged — and 3 when rauc itself could not run, where the caller KEEPS the bundle: deleting a
# multi-GB Tor download is a verdict too, and a tool that never ran has not earned one.
os_verify_bundle_reason() { # <bundle> <target-tag>
    local bundle="$1" tag="$2" rc=0
    # Signature first: `rauc info` verifies the bundle signature against the system keyring
    # before it prints anything, so an unsigned or mis-signed file fails here, before any
    # metadata is trusted. A nonzero exit is only a signature verdict when rauc actually ran
    # and judged the file — an exec failure or a crash (rc 126/127, or death by signal) gets
    # one retry and then its own honest reason instead of masquerading as a bad signature.
    rauc info "$bundle" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ge 126 ]; then
        rc=0
        rauc info "$bundle" >/dev/null 2>&1 || rc=$?
        if [ "$rc" -ge 126 ]; then
            printf '%s' "rauc could not run to judge the downloaded bundle — the file was kept; retry, and check the host journal if this repeats."
            return 3
        fi
    fi
    if [ "$rc" -ne 0 ]; then
        printf '%s' "the downloaded file failed signature verification against this machine's release keys — it was deleted; check for updates and download again."
        return 0
    fi
    # Compatible: refuse a definite mismatch early. `rauc install` re-enforces this
    # authoritatively either way, so an unparseable value falls through rather than refusing.
    local sys_compat bundle_compat
    sys_compat=$(sed -n 's/^compatible=//p' "${PITHEAD_RAUC_SYSTEM_CONF:-/etc/rauc/system.conf}" 2>/dev/null | head -1)
    bundle_compat=$(rauc info --output-format=shell "$bundle" 2>/dev/null |
        sed -n "s/^RAUC_MF_COMPATIBLE='\(.*\)'\$/\1/p" | head -1)
    if [ -n "$sys_compat" ] && [ -n "$bundle_compat" ] && [ "$sys_compat" != "$bundle_compat" ]; then
        printf '%s' "the bundle is built for '$bundle_compat' but this machine is '$sys_compat' — it cannot install here and was deleted."
        return 0
    fi
    # Variant: a bundle that would flip the machine's SSH/shell posture needs the CLI's explicit
    # consent flow, never a dashboard click — no override is surfaced here on purpose.
    local bundle_version
    if os_update_needs_confirmation "$(os_running_variant)" "$(os_bundle_variant "$bundle")"; then
        printf '%s' "this bundle would change the machine's shell/SSH build variant — that consent belongs at the machine, not on the dashboard. The bundle was deleted; nothing was changed."
        return 0
    fi
    # Version floor + downgrade: the same refusals `pithead os-update` enforces (shared code) —
    # a valid signature does not stop replaying an old vulnerable release.
    bundle_version=$(os_bundle_meta "$bundle" version)
    local reason
    reason=$(os_update_version_guard "$bundle_version" 0)
    if [ -n "$reason" ]; then
        printf '%s' "$reason"
        return 0
    fi
    # Equality passes the shared guard on purpose — the CLI keeps same-version installs for
    # manual slot repair at the machine — but on the dashboard door an equal bundle is only a
    # lever for looped reinstall-and-reboot downtime, so it refuses here.
    if os_semver_ok "$bundle_version" && [ "$bundle_version" = "$(os_running_version)" ]; then
        printf '%s' "already on v$bundle_version, nothing to update — the bundle was deleted."
        return 0
    fi
    # The bundle's own stamp must match the host-derived target — a mirror serving an OLDER
    # genuinely-signed bundle at the newest tag's URL would otherwise still pass the floor.
    if [ "v$bundle_version" != "$tag" ]; then
        printf '%s' "the downloaded bundle stamps itself '${bundle_version:-unstamped}' but the published release is $tag — refusing a version-mismatched file; it was deleted."
        return 0
    fi
    return 0
}

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

control_process_request() { # <claimed-file> <control-dir>
    local file="$1" cdir="$2" id action actor size
    # Refuse a symlinked / non-regular claimed file (graft #437): a symlink dropped in requests/
    # could point the root runner at any host file. Skip + audit, never follow it.
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        warn "Control request is a symlink or not a regular file — refused."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-nonregular"
        return 0
    fi
    # Bound the root-runner DoS (#33 hardening): reject an oversized intent BEFORE jq parses it. A
    # real config.json is a few KB; 64 KB is generous headroom for the full schema plus edits.
    size=$(wc -c <"$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 65536 ]; then
        warn "Control request exceeds 64 KB ($size bytes) — refused before parsing."
        control_audit "$cdir/audit/control.log" "" "" "invalid" "refused-oversize"
        return 0
    fi
    if ! jq -e . "$file" >/dev/null 2>&1; then
        warn "Control request is not valid JSON — discarded."
        return 0
    fi
    id=$(jq -r '.id // ""' "$file")
    # Strict canonical uuid4 (version nibble 4, variant nibble 8/9/a/b) — the id becomes a result/
    # staged FILENAME, so pin it hard (defense-in-depth, from #438). submit() mints str(uuid4()).
    if ! printf '%s' "$id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        warn "Control request has a malformed id — discarded (no result can be addressed)."
        return 0
    fi
    if [ "$(jq -r '[keys[] | select(. != "id" and . != "action" and . != "config" and . != "actor" and . != "version" and . != "worker" and . != "changes" and . != "confirm")] | length' "$file")" != "0" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unexpected keys in request",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "" "invalid" "rejected"
        return 0
    fi
    actor=$(jq -r '.actor // ""' "$file")
    # The actor rides into the audit log; it originates from Caddy's X-Auth-User but the container
    # writes the file, so re-validate it against the basic_auth username charset.
    printf '%s' "$actor" | grep -qE '^[A-Za-z0-9._@-]{0,64}$' || actor="untrusted"
    action=$(jq -r '.action // ""' "$file")
    case "$action" in
    preview) control_preview "$file" "$id" "$actor" "$cdir" ;;
    commit) control_commit "$id" "$actor" "$cdir" "$(jq -r '.confirm // ""' "$file")" ;;
    upgrade) control_upgrade "$file" "$id" "$actor" "$cdir" ;;
    worker-apply) control_worker_apply "$file" "$id" "$actor" "$cdir" ;;
    worker-upgrade) control_worker_upgrade "$file" "$id" "$actor" "$cdir" ;;
    restart | apply) control_lifecycle "$action" "$id" "$actor" "$cdir" ;;
    backup) control_backup "$id" "$actor" "$cdir" ;;
    # Appliance OS update, one verb per step so every network move stays separate from every
    # destructive one; each refuses outright off the appliance.
    os-check) control_os_check "$file" "$id" "$actor" "$cdir" ;;
    os-download) control_os_download "$file" "$id" "$actor" "$cdir" ;;
    os-verify) control_os_verify "$file" "$id" "$actor" "$cdir" ;;
    os-install) control_os_install "$file" "$id" "$actor" "$cdir" ;;
    os-reboot) control_os_reboot "$file" "$id" "$actor" "$cdir" ;;
    *)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"unknown action",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "${action:-none}" "rejected"
        ;;
    esac
}

# `control-run-pending`: drain the request spool, oldest first. Each request is CLAIMED (moved out
# of requests/) before a byte of it is parsed, so the container can never mutate or replay a
# request the runner is working on. Fired by the pithead-control systemd path unit.
control_run_pending() {
    [ "$(env_get DASHBOARD_CONTROL_ENABLED)" == "true" ] ||
        error "The dashboard control channel is not enabled (dashboard.control.enabled)."
    local cdir
    cdir=$(env_get CONTROL_DIR)
    [ -n "$cdir" ] || cdir="$PWD/data/control"
    mkdir -p "$cdir/staged" "$cdir/results" "$cdir/audit"
    # Freshen the pre-masked prefill copy (#440) before draining: hand-edits to config.json since
    # the last apply show up in the editor form. A commit re-renders it again via its `apply -y`.
    render_masked_config "$cdir"
    # Time-bounded DoS sweep (#33 hardening): drop staged/ copies and stray requests/ files older
    # than an hour that no commit ever claimed, so a burst that is never committed cannot pile up
    # (staged intents already expire per-commit at 10 min; this bounds accumulation regardless).
    find "$cdir/staged" "$cdir/requests" -maxdepth 1 -type f -mmin +60 -delete 2>/dev/null || true
    # Orphaned claims (#548): a claimed request whose handler died before the loop's own `rm -f
    # "$claim"` below (an errexit gap, e.g.) leaves a `.claim.<pid>` file sitting directly in
    # $cdir forever. Same age cutoff — a claim in flight never lives past a single drain.
    find "$cdir" -maxdepth 1 -type f -name '.claim.*' -mmin +60 -delete 2>/dev/null || true
    # Stale backup-kit passphrases: control_backup's one-time kit self-redacts after a blocking
    # TTL, but a runner killed mid-sleep (a reboot racing the window) would leave a wallet-grade
    # passphrase in results/ in plaintext on /data indefinitely. This backstop — a fresh runner
    # after that reboot runs it — nulls the passphrase in any kit older than the TTL that still
    # carries one. Belt to the TTL's braces; the passphrase is only ever meant for the live window.
    control_redact_stale_kits "$cdir/results"
    local names name req claim n=0
    # Per-run cap (#33 hardening): a single trigger drains at most this many intents, so a flood in
    # the spool can't hold the root runner for an unbounded stretch — the leftovers wait for the
    # next path-unit fire.
    local max=50
    # Per-drain worker-apply DIAL budget (#185 hardening): worker-apply is the only action that blocks
    # the runner on a network round-trip, so cap how many dial per drain (the rest reject with a retry
    # hint). control_worker_apply reads + decrements this in the same shell.
    CONTROL_WA_BUDGET=5
    # Worker-upgrade budget (#597): an upgrade blocks the runner on a rig build (minutes), so
    # exactly one runs per drain; the rest reject with a retry hint.
    CONTROL_WU_BUDGET=1
    # OS-update budget: a bundle download attempt or a slot install holds the runner for minutes
    # too, so exactly one os-* verb runs per drain; the rest reject with a retry hint.
    CONTROL_OS_BUDGET=1
    names=$(cd "$cdir/requests" 2>/dev/null && ls -1tr -- *.json 2>/dev/null) || true
    if [ -z "$names" ]; then
        log "No pending control requests."
        return 0
    fi
    while IFS= read -r name; do
        if [ "$n" -ge "$max" ]; then
            warn "Reached the $max-request per-run cap — remaining intents wait for the next run."
            break
        fi
        req="$cdir/requests/$name"
        [ -f "$req" ] || continue
        claim="$cdir/.claim.$$"
        mv "$req" "$claim" 2>/dev/null || continue
        control_process_request "$claim" "$cdir"
        rm -f "$claim"
        n=$((n + 1))
    done <<<"$names"
    log "Processed $n control request(s)."
}

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

# --- Main Execution ---

# #493: a subcommand's -h/--help must print usage and exit 0 BEFORE any side effect, and a
# subcommand that takes no options must reject an unrecognized flag instead of silently ignoring it
# and running anyway. `pithead upgrade --help` used to run a full upgrade (image pull + container
# recreation) — on the v1.4.0 deploy that recreation collided with the real upgrade and corrupted
# the dashboard DB (#489). A --help must never mutate the host.
_help_requested() { # "$@" — return 0 if any argument is -h/--help
    local a
    for a in "$@"; do
        case "$a" in
        -h | --help) return 0 ;;
        esac
    done
    return 1
}
_reject_options() { # <verb> "$@" — this verb takes no options; error on any leftover argument
    local verb="$1"
    shift
    [ "$#" -eq 0 ] || error "Unknown option for $verb: '$1'. This command takes no options. Run '$0 $verb -h' or '$0 help'."
}

main() {
    # Chained subcommands (#94): when every argument is a bare subcommand name, run them
    # left-to-right as a chain. Any other token (a flag, a service name, an archive path) keeps
    # the invocation on the single-command path below, unchanged.
    if [ "$#" -ge 2 ]; then
        local _tok _chain=1
        for _tok in "$@"; do
            if ! is_pithead_command "$_tok"; then
                _chain=0
                break
            fi
        done
        if [ "$_chain" -eq 1 ]; then
            run_chain "$@"
            return 0
        fi
    fi

    local cmd="${1:-}"
    if [ -n "$cmd" ]; then shift; fi

    # #493: -h/--help on any subcommand prints help and exits 0 before ANY side effect. `logs` is the
    # one deliberate passthrough (its args go to `docker compose logs`), so it opts out and forwards
    # -h/--help downstream. The bare `pithead -h/--help/help` is its own command in the case below.
    case "$cmd" in
    "" | help | -h | --help | logs) ;;
    *) if _help_requested "$@"; then
        show_help
        exit 0
    fi ;;
    esac

    # Make the stack version + build provenance available to any `docker compose [up] build` this
    # invocation runs, so the dashboard image bakes in its version badge (Issue #58).
    export_build_provenance

    case "$cmd" in
    "")
        # No command: first-time users get setup, deployed users get help.
        if is_deployed; then show_help; else setup; fi
        ;;
    setup)
        for arg in "$@"; do
            case "$arg" in
            --skip-optimize) SKIP_OPTIMIZE=1 ;;
            --skip-deps) SKIP_DEPS=1 ;;
            *) error "Unknown option for setup: $arg. Run '$0 help'." ;;
            esac
        done
        setup
        ;;
    apply) apply "$@" ;;
    render)
        _reject_options render "$@"
        render_derived
        ;;
    up)
        _reject_options up "$@"
        require_deployed
        stack_up
        ;;
    down)
        _reject_options down "$@"
        require_env
        stack_down
        ;;
    restart)
        require_deployed
        stack_restart "$@"
        ;;
    upgrade)
        _reject_options upgrade "$@"
        require_deployed
        stack_upgrade
        ;;
    logs)
        require_env
        log "Following logs (Ctrl+C to exit)..."
        docker compose logs -f "$@"
        ;;
    status)
        _reject_options status "$@"
        require_env
        stack_status || exit 1
        ;;
    doctor)
        case "${1:-}" in
        "") doctor || exit 1 ;;
        --json)
            [ "$#" -eq 1 ] || error "doctor --json takes no further options. Run '$0 help'."
            doctor_json || exit 1
            ;;
        *) error "Unknown option for doctor: '$1'. Run '$0 help'." ;;
        esac
        ;;
    support-bundle) stack_support_bundle "$@" ;;
    reset-dashboard)
        require_deployed
        reset_dashboard "$@"
        ;;
    config-reset) config_reset "$@" ;;
    factory-reset) factory_reset "$@" ;;
    backup) stack_backup "$@" ;;
    restore) stack_restore "$@" ;;
    uninstall) stack_uninstall "$@" ;;
    firstboot-wizard) firstboot_wizard "$@" ;;
    load-images)
        _reject_options load-images "$@"
        load_baked_images
        ;;
    local-miner)
        _reject_options local-miner "$@"
        # A rig has no .env and never will — there is no stack on it to render one.
        [ "$(machine_role)" = "rig" ] || require_env
        provision_local_miner
        ;;
    os-update) os_update "$@" ;;
    control-run-pending)
        _reject_options control-run-pending "$@"
        require_deployed
        control_run_pending
        ;;
    onion-client-key)
        _reject_options onion-client-key "$@"
        onion_client_key
        ;;
    rotate-dashboard-onion) rotate_dashboard_onion "$@" ;;
    rotate-secrets) rotate_secrets "$@" ;;
    render-quadlet)
        rq_env=".env" rq_out="./quadlet"
        while [ $# -gt 0 ]; do
            case "$1" in
            --env)
                [ -n "${2:-}" ] || error "render-quadlet: --env needs a file argument."
                rq_env="$2"
                shift 2
                ;;
            --out)
                [ -n "${2:-}" ] || error "render-quadlet: --out needs a directory argument."
                rq_out="$2"
                shift 2
                ;;
            *) error "Unknown option for render-quadlet: $1. Run '$0 help'." ;;
            esac
        done
        render_quadlet_units "$rq_env" "$rq_out"
        ;;
    version | -V | --version) show_version ;;
    help | -h | --help) show_help ;;
    *) error "Unknown command: $cmd. Run '$0 help'." ;;
    esac
}

if [ "$_STACK_SOURCED" = "0" ]; then
    main "$@"
fi
