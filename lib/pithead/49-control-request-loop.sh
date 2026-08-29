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
