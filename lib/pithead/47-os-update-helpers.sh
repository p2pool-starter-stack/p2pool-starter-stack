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
