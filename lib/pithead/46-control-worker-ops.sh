# Resolve a worker name to its dial target (host + control_port + token) from the HOST's OWN
# config.json — never the caller's intent (#122 SSRF). Shared by control_worker_apply and
# control_worker_upgrade, which had drifted this whole resolution+validation block out of sync
# line-for-line: the worker-name charset pin, the three WORKER_LIST_JQ lookups, and the
# host/port/token guards. On success sets RESOLVED_HOST/RESOLVED_CPORT/RESOLVED_TOKEN and returns
# 0. On failure sets RESOLVE_WORKER_ERR to the operator-facing rejection message (leaving the
# RESOLVED_* vars empty) and returns 1 — the caller writes its own rejected result/audit line with
# that message, since worker-apply and worker-upgrade audit under different action names.
resolve_worker_target() { # <worker-name> <verb-for-the-host-missing-message, e.g. "edit"/"upgrade">
    local worker="$1" verb="$2"
    RESOLVED_HOST="" RESOLVED_CPORT="" RESOLVED_TOKEN="" RESOLVE_WORKER_ERR=""
    # The worker name is a config.json lookup key AND (in name-auth) a bearer; pin its charset.
    # LC_ALL=C so [!-~] is the printable-ASCII BYTE range: under a UTF-8 locale GNU grep reads the
    # range by collation order and rejects ordinary names like "rig1" (caught by the release gate on a
    # UTF-8 box; CI runs under C and missed it). jq's test() above is codepoint-based and unaffected.
    if ! printf '%s' "$worker" | LC_ALL=C grep -qE '^[!-~]{1,128}$'; then
        RESOLVE_WORKER_ERR="malformed or missing 'worker' name in the request."
        return 1
    fi
    # Resolve the rig's ADDRESS + BEARER from the HOST's config.json — never the intent. A rig with no
    # host or no token cannot be a target (fail closed): the rig's control path is bearer-mandatory and
    # we only ever dial an operator-set host.
    local host cport token
    host=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .host // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    cport=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .control_port // 8082' "$CONFIG_FILE" 2>/dev/null | head -1)
    token=$(jq -r --arg n "$worker" "$WORKER_LIST_JQ"'worker_list[] | select(.name == $n) | .token // ""' "$CONFIG_FILE" 2>/dev/null | head -1)
    if [ -z "$host" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no configured host in workers.list[] (or the deprecated dashboard.workers[]) — set host + control_port + token to $verb it."
        return 1
    fi
    # host charset guard (#122): no port/path/userinfo can be smuggled into the URL below.
    if ! printf '%s' "$host" | grep -qE '^[A-Za-z0-9._-]{1,253}$'; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid host."
        return 1
    fi
    if ! is_valid_port "$cport"; then
        RESOLVE_WORKER_ERR="worker '$worker' has an invalid control_port."
        return 1
    fi
    if [ -z "$token" ]; then
        RESOLVE_WORKER_ERR="worker '$worker' has no token in workers.list[] (or the deprecated dashboard.workers[]) — the rig's control API is bearer-mandatory."
        return 1
    fi
    RESOLVED_HOST="$host" RESOLVED_CPORT="$cport" RESOLVED_TOKEN="$token"
    return 0
}

# Worker config apply (#185): POST an operator's writable-key change to a RigForge rig's control API
# and record the outcome for the dashboard's config history. The intent carries ONLY the worker NAME
# and the CHANGES — never a host, port, or token: the runner resolves the rig's real address + bearer
# from the HOST's own config.json (workers.list[] / the deprecated dashboard.workers[], #506), so a
# tampered intent can at most target another ALREADY-configured rig, never an arbitrary host (#122
# SSRF), and the rig's access token —
# masked out of the container (#440) — never leaves the host. Changes are re-validated against the
# same writable allowlist the rig enforces (defence in depth). Every result/audit line the container
# reads back carries the change_id + status only, never the token.
control_worker_apply() { # <claimed-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "started"
    _wa_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "rejected"
    }
    _wa_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-apply" "failed"
    }
    local worker changes
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-upgrade uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "edit"; then
        _wa_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    # Changes must be a non-empty object whose keys are ALL writable via the rig's control path (the
    # rig re-validates; this is the host-side gate — mirrors rigforge WRITABLE, #185/#236).
    changes=$(jq -c '.changes // {}' "$file")
    local badkeys
    badkeys=$(printf '%s' "$changes" | jq -r '
        (["pools","DONATION","autotune","watchdog","watchdog_interval_min","max_temp_c"]) as $ok
        | if (type) != "object" or (length) == 0 then "__empty__"
          else [keys[] | select(. as $k | $ok | index($k) | not)] | join(",") end' 2>/dev/null)
    if [ "$badkeys" = "__empty__" ]; then
        _wa_reject "'changes' must be a non-empty object of writable config keys."
        return 0
    fi
    if [ -n "$badkeys" ]; then
        _wa_reject "keys not writable via the control path: $badkeys"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    # Per-drain dial budget (hardening): worker-apply is the only control action that blocks the
    # single-threaded root runner on a network round-trip (a dial + a status poll, tens of seconds).
    # Cap how many actually dial per drain so a compromised container can't queue a flood of valid
    # worker-applies and starve legitimate commit/restart/upgrade intents. The counter lives in the
    # runner's shell (control_run_pending seeds it), so it persists across the drain loop. Over-budget
    # intents are rejected with a retry hint — the operator just re-applies; a real fleet edit is a
    # handful of rigs, never dozens at once.
    if [ "${CONTROL_WA_BUDGET:-0}" -le 0 ]; then
        _wa_reject "too many worker config changes in one cycle — retry in a moment."
        return 0
    fi
    CONTROL_WA_BUDGET=$((CONTROL_WA_BUDGET - 1))
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" '{status:"running",worker:$w,ts:(now|floor)}')"
    # POST the change to the rig's control API. Direct LAN dial (like the read path) — NOT Tor: the rig
    # is an operator-set host on the mining LAN, not clearnet. The token rides one header, never the
    # URL, the result, or the audit log.
    local url="http://$host:$cport/apply" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$changes" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wa_fail "could not reach worker '$worker' control API at $host:$cport — nothing was applied."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # The rig's error string is attacker-influenceable (a compromised rig or a LAN MITM); cap it
        # before it lands in a result the container reads and the dashboard renders.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wa_reject "worker '$worker' refused the change (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The rig stages → validates →
    # applies → liveness-checks → rolls back if the miner doesn't return live, seconds later. The 20s
    # deadline (plus the 15s dial above) stays under the dashboard's CONTROL_WAIT_S POST wait, so the
    # dashboard always catches a terminal-ish result and records it in the config history. Terminals
    # are applied / rejected / rolled_back / failed — failed is the rig unable to restore its own
    # rollback backup (present since the v1.11.2 fleet floor), a real fault the result must carry
    # with its reason, never a deadline-burned "accepted".
    local sbody scode status reason ckeys deadline=$((SECONDS + 20))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 2
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours (a concurrent change could be newer).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | rejected | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            ckeys=$(jq -c '.changed_keys // []' "$sbody")
            rm -f "$sbody"
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --argjson k "$ckeys" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,changed_keys:$k,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-apply" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status in time — the change is staged on the rig and will apply; the
    # container can keep polling the rig via the next read. Record accepted-but-pending, not a failure.
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" \
        '{status:"accepted",change_id:$c,worker:$w,note:"queued on the rig; outcome not yet observed",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-apply" "accepted"
}

control_worker_upgrade() { # <claimed-file> <id> <actor> <control-dir>
    # One-click RigForge upgrade for a single rig (#597) — fuses the two existing templates:
    # resolve_worker_target's rig resolution/guards (address + bearer from the HOST config, never
    # the intent, shared with control_worker_apply) and control_upgrade's throttled host-side
    # target re-derivation over Tor (the container proposes a version; GitHub decides the real
    # target; a mismatch is refused).
    # The rig bounds whatever tag we send with its own monotonic + ancestry guards and rolls back
    # a build that doesn't come back live — rollback coverage is rig-side (rigforge#322).
    local file="$1" id="$2" actor="$3" cdir="$4"
    local results="$cdir/results" auditf="$cdir/audit/control.log"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "started"
    _wu_reject() { # <reason> — refused before dialing the rig; nothing changed
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"rejected",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "rejected"
    }
    _wu_fail() { # <reason> — the dial started and did not complete
        control_write_result "$results" "$id" "$(jq -n --arg e "$1" '{status:"failed",error:$e,ts:(now|floor)}')"
        control_audit "$auditf" "$id" "$actor" "worker-upgrade" "failed"
    }
    local worker proposed
    worker=$(jq -r '.worker // ""' "$file")
    # Resolve the rig's dial target FIRST (worker-name charset + host/port/token) — the same
    # fail-closed gate worker-apply uses, so the two verbs can't drift out of sync on it.
    if ! resolve_worker_target "$worker" "upgrade"; then
        _wu_reject "$RESOLVE_WORKER_ERR"
        return 0
    fi
    local host="$RESOLVED_HOST" cport="$RESOLVED_CPORT" token="$RESOLVED_TOKEN"
    proposed=$(jq -r '.version // ""' "$file")
    if ! printf '%s' "$proposed" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        _wu_reject "malformed or missing 'version' in the upgrade request."
        return 0
    fi
    # Per-drain budget: an upgrade blocks the single-threaded root runner on the rig's build
    # (minutes, vs seconds for worker-apply), so exactly ONE dials per drain. v1 is per-worker
    # only — no "upgrade all" — and a real fleet upgrade is one rig at a time by design.
    if [ "${CONTROL_WU_BUDGET:-0}" -le 0 ]; then
        _wu_reject "another worker upgrade is already in this cycle — retry in a moment."
        return 0
    fi
    CONTROL_WU_BUDGET=$((CONTROL_WU_BUDGET - 1))
    # Host-side re-derivation of the target from the RigForge release API over Tor — load-bearing:
    # the rig deliberately computes no "latest" itself (ADR 0002 D4), it bounds the tag we send.
    # The derived tag is cached for 10 minutes and the dial itself is stamp-throttled to one per
    # 10 minutes (claimed BEFORE the dial, control_upgrade's anti-beacon lesson): a compromised
    # container flooding well-formed intents costs at most one GitHub/Tor egress per window,
    # while a legitimate rig-after-rig fleet upgrade reuses the cached tag.
    local tagf="$cdir/staged/.rigforge-latest-tag" stampf="$cdir/staged/.rigforge-latest-stamp" tag=""
    if [ -n "$(find "$tagf" -mmin -10 2>/dev/null)" ]; then
        tag=$(cat "$tagf" 2>/dev/null)
    fi
    if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
        if [ -n "$(find "$stampf" -mmin -10 2>/dev/null)" ]; then
            _wu_reject "a RigForge release lookup was attempted less than 10 minutes ago and no usable tag is cached — retry in a few minutes."
            return 0
        fi
        touch "$stampf"
        local rel
        if ! gh_release_fetch p2pool-starter-stack/rigforge; then
            _wu_reject "$GH_RELEASE_HINT"
            return 0
        fi
        rel=$GH_RELEASE_JSON
        tag=$(printf '%s' "$rel" | jq -r '.tag_name // ""' 2>/dev/null)
        if ! printf '%s' "$tag" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
            _wu_reject "the GitHub release API returned no usable RigForge release tag — nothing was changed."
            return 0
        fi
        printf '%s' "$tag" >"$tagf"
    fi
    if [ "$proposed" != "$tag" ]; then
        _wu_reject "requested version $proposed is not the latest published RigForge release ($tag) — reload the dashboard and retry."
        return 0
    fi
    control_write_result "$results" "$id" "$(jq -n --arg w "$worker" --arg v "$tag" '{status:"running",worker:$w,version:$v,ts:(now|floor)}')"
    # POST the upgrade to the rig's control API — direct LAN dial like worker-apply, NOT Tor. The
    # body carries the HOST-derived tag only; the token rides one header, never the URL or result.
    local url="http://$host:$cport/upgrade" bodyf="$cdir/staged/.$id.body" code
    if ! code=$(curl -sS -o "$bodyf" -w '%{http_code}' --max-time 15 --max-filesize "$CURL_CAP_SMALL" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
        --data "$(jq -n --arg v "$tag" '{version:$v}')" "$url" 2>/dev/null); then
        rm -f "$bodyf"
        _wu_fail "could not reach worker '$worker' control API at $host:$cport — nothing was changed."
        return 0
    fi
    if [ "$code" != "202" ]; then
        local rig_err
        # Rig-supplied text is attacker-influenceable (a compromised rig / LAN MITM); cap it.
        rig_err=$(jq -r '.error // ""' "$bodyf" 2>/dev/null | head -c 500)
        rm -f "$bodyf"
        _wu_reject "worker '$worker' refused the upgrade (HTTP $code): ${rig_err:-no detail}."
        return 0
    fi
    local change_id
    change_id=$(jq -r '.change_id // ""' "$bodyf" 2>/dev/null | head -c 64)
    rm -f "$bodyf"
    # Poll the rig's /status for THIS change_id's terminal outcome. The cap is a deliberate
    # trade: a no-rebuild upgrade (the common case — git checkout + restart) reaches terminal in
    # well under 90s, while a pin-change rebuild (~10 min) times out to "accepted" below and the
    # badge (#596) clears on its own when the rig reports the new version. Polling the full build
    # would hand a hostile/hung rig 12 minutes of the single-threaded root drain per intent
    # (sec-review finding) — 90s keeps the stall bound in worker-apply's envelope. Since
    # rigforge#320 (v1.12.0) the rig writes an in-progress "started" plus first-class noop
    # (already on the target) and throttled (its own 6h anti-beacon window) terminals; "started",
    # like a non-matching change_id, just means keep polling. Terminals are applied / noop /
    # throttled / rolled_back / failed. The cap is overridable (CONTROL_WU_POLL_CAP) so the stack
    # tests can prove the timeout→accepted fallback in seconds.
    local sbody scode status reason deadline=$((SECONDS + ${CONTROL_WU_POLL_CAP:-90}))
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 5
        sbody="$cdir/staged/.$id.status"
        if ! scode=$(curl -sS -o "$sbody" -w '%{http_code}' --max-time 10 --max-filesize "$CURL_CAP_SMALL" \
            -H "Authorization: Bearer $token" "http://$host:$cport/status" 2>/dev/null); then
            rm -f "$sbody"
            continue
        fi
        [ "$scode" = "200" ] || {
            rm -f "$sbody"
            continue
        }
        # Only trust a status whose change_id matches ours — the rig may still be showing a
        # PREVIOUS change's terminal state (no in-progress status, rigforge#320).
        if [ "$(jq -r '.change_id // ""' "$sbody" 2>/dev/null)" != "$change_id" ]; then
            rm -f "$sbody"
            continue
        fi
        status=$(jq -r '.status // ""' "$sbody")
        case "$status" in
        applied | noop | throttled | rolled_back | failed)
            # reason is rig-supplied (attacker-influenceable); cap it before it is stored/rendered.
            reason=$(jq -r '.reason // ""' "$sbody" | head -c 500)
            rm -f "$sbody"
            # Legacy remap: a pre-rigforge#320 rig (≤ v1.11.2, the supported floor) collapses its
            # 6h anti-beacon throttle into failed+"throttled — ..." free text, and retry-later
            # must render calm, not red. Anchored to that leading word on purpose: a modern rig's
            # genuine failed can mention the throttle too ("throttle state unavailable",
            # rigforge#321's fail-closed refusal) and must STAY a fault. Drop the remap once the
            # fleet floor reaches rigforge v1.12.0 (first-class throttled) — the v2 appliance
            # bakes v1.15.0, so post-v2 fleets are already past it.
            if [ "$status" = "failed" ] && printf '%s' "$reason" | grep -qiE '^throttled'; then
                status="throttled"
            fi
            control_write_result "$results" "$id" "$(jq -n --arg s "$status" --arg c "$change_id" --arg w "$worker" --arg v "$tag" --arg r "$reason" \
                '{status:$s,change_id:$c,worker:$w,version:$v,reason:(if $r=="" then null else $r end),ts:(now|floor)}')"
            control_audit "$auditf" "$id" "$actor" "worker-upgrade" "$status"
            return 0
            ;;
        esac
        rm -f "$sbody"
    done
    # Accepted but no terminal status inside the cap — the upgrade is running on the rig. Record
    # accepted, not failure: the badge (#596) clears on its own when the rig's next summary poll
    # reports the new version ('applied' echoes no version, rigforge#320 — the summary is the
    # confirmation of record either way).
    control_write_result "$results" "$id" "$(jq -n --arg c "$change_id" --arg w "$worker" --arg v "$tag" \
        '{status:"accepted",change_id:$c,worker:$w,version:$v,note:"upgrade still running on the rig — check the rig if the badge has not cleared in a while",ts:(now|floor)}')"
    control_audit "$auditf" "$id" "$actor" "worker-upgrade" "accepted"
}
