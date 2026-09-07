# The remedy half of a control-channel refusal (#1888, the #1821 class): "edit config.json and run
# apply" is a real remedy on a DIY host and a DEAD END on a shell-less appliance (#786).
_control_host_remedy() {
    if is_appliance; then
        printf 'That setting is not changeable from the dashboard on an appliance; it is fixed when the machine is set up, so use "Set up again" if you need to change it.'
    else
        printf 'Edit config.json on the host and run `%s apply`.' "$0"
    fi
}

control_approval_gate() { # <staged-file> [confirm-token]
    local staged="$1" confirm="${2:-}" porcelain
    # Fail closed if we cannot re-derive the change set (the staged config was validated at
    # preview, so a dry-run failure here means something changed — refuse).
    if ! porcelain=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>/dev/null); then
        printf 'could not re-validate the staged change host-side — refusing to commit'
        return 1
    fi
    # Two config.json blocks never render to .env — the dashboard reads them straight off its
    # config.json mount (load_worker_endpoints + load_energy_config; these are the ONLY two), so the
    # env-diff allowlist below can't see either. Each config.json-only block must be handled here by
    # name or a commit could silently change it: the worker descriptors are REFUSED, dashboard.energy
    # is ALLOWED (#504). Every OTHER config path renders to .env and is gated by the allowlist, so a
    # change there is caught below — a NEW config.json-only block, though, MUST add its own line.
    #
    # The per-worker descriptors — workers.list[] (#506) — carry per-rig hosts and API tokens
    # (exactly the "free-form string that reaches a URL or credential" class the allowlist exists to
    # keep host-CLI-only). The deprecated dashboard.workers[] alias (#172) used to be refused here
    # outright; 2.0.0 removed it (#1832), so a staged config carrying it is now refused one step
    # later by the closed-schema check below, as an unknown key like any other typo.
    #
    # workers.list[] gets ONE narrow ADD-ONLY exception (the click-to-adopt flow): a commit may
    # APPEND a brand-new descriptor to the end of the array, but every entry already live must
    # reappear byte-for-byte, in the same order — so an adopt commit can add rig #4 without ever
    # being able to repoint rig #1's host or token. That asymmetry is deliberate: first adoption
    # gets a human confirming a freshly-observed address (the miner-advertised value is a PREFILL
    # only), but a REPOINT of an already-trusted descriptor is the #122-class escalation an adopt
    # confirmation was never designed to cover, so it stays a host edit like any other change here.
    # Checked as a prefix match: staged.workers.list, cut back to live's own length, must equal
    # live.workers.list exactly. An empty live list makes every staged entry "new" by definition
    # (first adoption); a shorter/reordered/edited staged list can never match and is refused.
    if ! jq -e --slurpfile live "$CONFIG_FILE" '
        ((($live[0].workers.list // []) | length) as $n
             | (.workers.list // [])[0:$n] == ($live[0].workers.list // []))
        ' "$staged" >/dev/null 2>&1; then
        printf 'this change alters an existing per-worker descriptor (workers.list[], a per-rig host/token) rather than only adding a new one, which is not committable from the dashboard. %s' "$(_control_host_remedy)"
        return 1
    fi
    # SSRF floor on what an add-only append may point at (see _control_host_is_internal): every
    # NEWLY appended entry's host — never an already-live one, already covered above — must clear
    # this host's own loopback/link-local/internal-bridge reach. Read the live length fresh (not
    # cached from the check above) so this stays correct however the prefix check above evolves.
    local live_n new_host
    live_n=$(jq -r --slurpfile live "$CONFIG_FILE" '($live[0].workers.list // []) | length' "$staged" 2>/dev/null) || live_n=0
    while IFS= read -r new_host; do
        [ -n "$new_host" ] || continue
        if _control_host_is_internal "$new_host"; then
            printf 'a new worker descriptor points at %s, which resolves inside this host'"'"'s own network — a rig'"'"'s control address must be a distinct machine on your LAN, not this host or one of its own containers.' "$new_host"
            return 1
        fi
    done < <(jq -r --argjson n "${live_n:-0}" '(.workers.list // [])[$n:] | .[] | select(has("host")) | .host' "$staged" 2>/dev/null)
    # Closed-schema guard (#33 hardening). A config.json key the stack doesn't recognize renders to
    # NO env var, so it emits zero porcelain rows and slips past the allowlist below — yet the
    # commit's `cp "$staged" "$CONFIG_FILE"` would still persist it. So refuse any staged path that
    # isn't in the canonical schema (config.reference.json). Numeric path components are dropped so a
    # populated known scalar array (notifications.webhooks, telegram.control.allowed_ids) collapses
    # onto its schema-listed key instead of false-rejecting, while a smuggled OBJECT inside such an
    # array still surfaces its unknown sub-key. Both worker-descriptor shapes are exempt: their
    # per-rig object elements aren't enumerated in the reference and the array is already fully
    # guarded above. Fail closed — an unreadable reference or a jq error refuses the commit.
    # INVARIANT: config.reference.json MUST stay a complete superset of every config path this script
    # reads (grep the config_bool/`jq ... "$CONFIG_FILE"` sites), or a legit config carrying a
    # read-but-unlisted path is false-rejected on every commit. 2.0.0 removed the two backward-compat
    # aliases that used to need listing for this reason (#1832), so the superset is now smaller rather
    # than larger. Guarded two ways in tests/stack/run.sh: the case asserting a staged 1.x alias is
    # REFUSED here rather than round-tripped, and (#561) an automated drift guard that walks this
    # script's own config_bool/`jq ... "$CONFIG_FILE"` read sites with a conservative fixed-shape
    # extractor and fails loud ("extend the extractor") on a shape it doesn't recognize, rather than
    # risking the false-alarms a naive grep-based path diff would hit on jq-internal and filename
    # dotted tokens.
    local unknown
    if ! unknown=$(jq -rn --slurpfile ref "$REFERENCE_CONFIG" --slurpfile cfg "$staged" '
        def norm: [.[] | strings] | join(".");
        ([$cfg[0] | paths | select(.[0:2] != ["workers", "list"]) | norm]
         - [$ref[0] | paths | norm])
        | unique | join(", ")' 2>/dev/null); then
        printf 'could not validate the staged config against the schema (%s) — refusing to commit' "$REFERENCE_CONFIG"
        return 1
    fi
    if [ -n "$unknown" ]; then
        printf 'this change adds config keys not in the schema (%s) — refusing to commit. %s' "$unknown" "$(_control_host_remedy)"
        return 1
    fi
    # Default-deny: refuse if any changed env key is NOT on the editable allowlist, whatever its
    # flag says. Refusal keys off a violation COUNT, not the matched text, so a blank or
    # malformed porcelain row (empty KEY column) still refuses instead of slipping past an
    # emptiness test.
    # The allowlist now spans BOTH the free-to-commit editable set and the confirm-gated set (#719):
    # a change to any other key still fails closed here. The CONFIRM set only gets PAST this pass —
    # it still has to clear the DEST perimeter and satisfy the typed-confirmation check below.
    local editable_re bad hit
    editable_re=$(printf '%s %s' "$CONTROL_DASHBOARD_EDITABLE_KEYS" "$CONTROL_DASHBOARD_CONFIRM_KEYS" | tr -s ' \n' '|')
    bad=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -cvxE "$editable_re" || true)
    if [ "${bad:-0}" -gt 0 ]; then
        hit=$(printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -m1 -vxE "$editable_re" || true)
        printf 'this change alters a security-sensitive setting (%s) that is not committable from the dashboard. %s' "${hit:-unparseable change row}" "$(_control_host_remedy)"
        return 1
    fi
    # Perimeter: any DEST row is refused outright — the confirm-gate never covers a destructive
    # host-only change. A data-dir MOVE is CONFIRM (below); a prune DISABLE or a TOR data-dir move
    # still emits DEST and is caught here even though its key is on the confirm allowlist.
    if printf '%s\n' "$porcelain" | grep -qE $'^DEST\t'; then
        printf 'this change is destructive and cannot be committed from the dashboard. %s' "$(_control_host_remedy)"
        return 1
    fi
    # Data-dir destination allowlist (#728). #719 made the four *_DATA_DIR moves confirm-gated, so a
    # dashboard operator who types APPLY can now RELOCATE a service's data dir. assert_safe_dir — the
    # host-shell guard — is a BLOCKLIST: it refuses the catastrophic roots (/, $HOME, bare mounts, …)
    # but passes any OTHER absolute path. At host-shell trust that is proportionate (a shell already
    # has filesystem-wide reach); at dashboard trust it would let a confirmed move target another
    # user's home or another service's data volume and have pithead mkdir/chown -R it and bind-mount
    # it into a recreated container — a destination trust-escalation. This gate runs ONLY for
    # dashboard commits (the host `apply` path never calls control_approval_gate), so it is exactly
    # where the tighter, control-only rule belongs: for a control-channel move, narrow the
    # DESTINATION from a blocklist to an ALLOWLIST — permit only a path under the stack's own data
    # root ($PWD/data, the install dir's data/) or a parent the stack ALREADY keeps data in (each
    # live *_DATA_DIR's parent — a root a host operator already opted into, which covers a co-located
    # shared data root, #455). Anything else is refused EVEN with the APPLY token: that move stays
    # host-CLI-only. Only EXPLICIT absolute paths are checked — "auto"/empty resolves to a stack
    # default that is under a data root by construction. assert_safe_dir still runs at apply time.
    local -a allowed_roots=("$PWD/data")
    local dvar cur
    for dvar in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR; do
        cur=$(env_get "$dvar")
        [ -n "$cur" ] && allowed_roots+=("$(dirname "$cur")")
    done
    local ddpath dest root ok_root
    for ddpath in monero.data_dir tari.data_dir p2pool.data_dir dashboard.data_dir; do
        dest=$(jq -r --arg p "$ddpath" 'getpath($p/".") // empty' "$staged" 2>/dev/null)
        # Skip only values resolve_default turns into an in-root stack default — its EXACT set,
        # not a DYNAMIC_* wildcard (which would also swallow a bogus DYNAMIC_FOO that resolve_default
        # passes through literally). A non-absolute/traversal dest never reaches here anyway:
        # assert_safe_dir (called in the dry-run re-derivation at the top of this gate) refuses
        # `..`/relative paths first — keep that ordering.
        case "$dest" in "" | auto | DYNAMIC_DATA | DYNAMIC_HOST | DYNAMIC_ID) continue ;; esac
        ok_root=0
        # Trailing slash on both sides so a root prefix can't false-match a sibling (/data vs
        # /database); an exact-root dest matches too (harmless — still the stack's own dir).
        for root in "${allowed_roots[@]}"; do
            case "$dest/" in "$root"/*) ok_root=1 && break ;; esac
        done
        if [ "$ok_root" -eq 0 ]; then
            printf 'this move sends %s to %s, which is outside the stack data root(s) — a dashboard-confirmed data-dir move must stay under the stack data directory (%s) or a parent it already uses. %s' "$ddpath" "$dest" "$PWD/data" "$(_control_host_remedy)"
            return 1
        fi
    done
    # Confirm-gate (#719): an in-scope CONFIRM row PROCEEDS only with the operator's typed
    # confirmation. The token is a fixed literal ("APPLY"), orthogonal to the value being set — it
    # is friction that forces the operator to acknowledge an expensive/disruptive op, NOT a security
    # control (the perimeter above is the boundary). control_commit records a confirmed change
    # distinctly in the audit log via the marker file touched here.
    if printf '%s\n' "$porcelain" | grep -qE $'^CONFIRM\t'; then
        if [ "$confirm" != "APPLY" ]; then
            hit=$(printf '%s\n' "$porcelain" | grep -m1 -E $'^CONFIRM\t' | cut -f3-)
            printf 'this change is disruptive (%s) — type APPLY in the dashboard to confirm.' "${hit:-disruptive change}"
            return 1
        fi
        touch "${staged}.confirmed" 2>/dev/null || true
    fi
    # Reachability probe (#1888) — the compensating control the confirm tier rests on for these keys
    # (42-): the typed token is friction, but a chain cannot be parked on a node that is not there.
    # Host-side, on the STAGED config, through the same preflight the wizard uses; nothing is
    # trusted from the container. Fires only when a node-endpoint key really changed (so an
    # unrelated commit is never blocked by a node that is down) and only after the typed
    # confirmation (so an unconfirmed attempt never pays the dial timeouts).
    local probe_err endpoint_re
    endpoint_re=$(printf '%s' "$CONTROL_NODE_ENDPOINT_KEYS" | tr -s ' \n' '|')
    if printf '%s' "$porcelain" | awk -F'\t' 'NF' | cut -f2 | grep -qxE "$endpoint_re"; then
        if ! probe_err=$(preflight_remote_nodes "$staged" 2>/dev/null); then
            printf 'this change points the stack at a node the host cannot use: %s' "$probe_err"
            return 1
        fi
    fi
    # Approved: echo the changed key NAMES so the commit's audit entry can record WHAT changed
    # (#349) without a third dry-run. Names only, never values. dashboard.energy (#504) is
    # config.json-only, so it never appears in the env porcelain — fold a synthetic DASHBOARD_ENERGY
    # name into the list when that block changed, else an energy-only commit would audit no key.
    # Reference defaults merged into both sides (#696), same as the preview leg: the editor
    # round-trips the reference-merged form, and materialized defaults are not a change.
    local keys
    keys=$(porcelain_keys "$porcelain")
    if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
        '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
         == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
        keys="${keys:+$keys }DASHBOARD_ENERGY"
    fi
    printf '%s' "$keys"
    return 0
}

control_write_result() { # <results-dir> <id> <json>
    printf '%s\n' "$3" >"$1/.$2.tmp" && mv "$1/.$2.tmp" "$1/$2.json"
}

# One JSON line per handled request. `keys` (optional 6th arg) is the space-separated list of
# changed env-key NAMES from the same dry-run porcelain the approval gate re-derives — names only,
# NEVER values: several allowlist-adjacent keys are secrets host-side, and the audit log is mounted
# into the (semi-trusted) dashboard container. Every free-form field is charset-stripped at write
# time (below) so none can forge a second JSON line — `action` in particular can arrive raw from a
# container-supplied intent on the unknown-action path, so it is NOT a fixed string.
control_audit() { # <audit-file> <id> <actor> <action> <status> [keys]
    # Size bound (#349, same posture as #123): once the log passes 512 KiB, keep the newest 2000
    # entries. Trim-before-append, so the file is complete JSONL at all times and the entry being
    # written is never the one trimmed.
    if [ -f "$1" ] && [ "$(wc -c <"$1" | tr -d ' ')" -gt 524288 ]; then
        tail -n 2000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
    # Sanitize the free-form fields at the write chokepoint so nothing can forge a second JSON line
    # into this tamper-evidence log: `action` may arrive straight from a container-supplied intent
    # on the unknown-action path (a newline + `{...}` would otherwise inject an entry), and `keys`
    # is defense-in-depth over its upstream guard. `id` is a validated uuid4, `status` is
    # code-set, and `actor` is regex-whitelisted upstream — but strip them here too, cheaply.
    printf '{"ts":"%s","id":"%s","actor":"%s","action":"%s","status":"%s","keys":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(printf '%s' "$2" | tr -cd 'A-Za-z0-9-')" \
        "$(printf '%s' "$3" | tr -cd 'A-Za-z0-9._@-')" \
        "$(printf '%s' "$4" | tr -cd 'a-z-')" \
        "$(printf '%s' "$5" | tr -cd 'a-z-')" \
        "$(printf '%s' "${6:-}" | tr -cd 'A-Z0-9_ ')" >>"$1"
}

# The unique changed env-key names in a dry-run porcelain, one space-separated line (for the
# audit `keys` field). Key NAMES only — the porcelain MSG column is dropped here.
porcelain_keys() {
    printf '%s' "$1" | awk -F'\t' 'NF' | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Preview: stage the candidate config host-side, dry-run it, report the describe_change rows.
control_preview() { # <request-file> <id> <actor> <control-dir>
    local file="$1" id="$2" actor="$3" cdir="$4"
    local staged="$cdir/staged/$id.json" errf="$cdir/staged/.$id.err" out result
    if [ "$(jq -r '.config | type' "$file")" != "object" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"config must be a JSON object",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
        return 0
    fi
    # The "blank secret keeps the live value" merge happens HERE, host-side (#440): the request
    # arrives with {"__secret__":true} sentinels for untouched secrets (the container never held
    # the real values — it prefills from the pre-masked copy), and each sentinel is swapped for
    # the live config.json value at staging. A sentinel for a secret that is not actually set
    # collapses to "" rather than leaking a dict into config.json. The staged copy therefore
    # carries merged secrets: it lives in host-only staged/ — never mounted — and is pinned
    # owner-only so a co-tenant on the host can't read secrets from it (#33 hardening). Created
    # under umask 077 so it is never even briefly world-readable (create-then-chmod race); the
    # chmod stays as belt-and-suspenders.
    # Per-worker token sentinels (#172) get the same swap, but out of the fixed-path walk: they
    # live in the variable-length descriptor array at workers.list[] (#506) — so restore each from
    # the LIVE token matched by worker name (first-declared wins on duplicate names, matching the
    # container's probe). A sentinel for a rig with no live token collapses to "" too.
    # dashboard.workers[] is restored too, and MUST be: 30's masker still masks that shape after
    # 2.0.0 removed the alias (#1832, see the note there), and mask and restore are one mechanism.
    # Keeping the mask without the restore would let a sentinel be committed as a literal token.
    # The LIVE lookup below therefore reads BOTH shapes, and that is the whole point: worker_list is
    # workers.list[] alone since #1832, so resolving legacy sentinels against it would find nothing
    # and blank every per-rig token to "" — a restore branch that cannot restore. workers.list[]
    # wins a name present in both (it is the canonical key, and both-populated-and-different is
    # already refused at apply); within one shape, first-declared still wins via the reverse.
    (umask 077 && jq --argjson paths "$CONTROL_SECRET_PATHS" --slurpfile live "$CONFIG_FILE" "$WORKER_LIST_JQ"'
        (reduce (($live[0] | worker_list) + (($live[0].dashboard // {}) | .workers // []) | reverse | .[]) as $w ({};
            if ($w | type) == "object" and ($w.name | type) == "string"
            then .[$w.name] = ($w.token // "") else . end)) as $livetok
        | reduce $paths[] as $p (.config;
            (try getpath($p) catch null) as $v
            | if ($v | type) == "object" and $v.__secret__ == true
              then setpath($p; (($live[0] | try getpath($p) catch null) // ""))
              else . end)
        | if (.workers | type) == "object" and (.workers.list | type) == "array"
          then .workers.list |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end
        | if (.dashboard | type) == "object" and (.dashboard.workers | type) == "array"
          then .dashboard.workers |= map(
              if (.token | type) == "object" and .token.__secret__ == true
              then .token = (if (.name | type) == "string" then ($livetok[.name] // "") else "" end)
              else . end)
          else . end' "$file" >"$staged")
    chmod 600 "$staged" 2>/dev/null || true
    if out=$(PITHEAD_CONFIG_FILE="$staged" "$0" apply --dry-run --porcelain 2>"$errf"); then
        result=$(printf '%s\n' "$out" | jq -R -s '
            [split("\n")[] | select(length > 0) | split("\t") | {flag: .[0], key: .[1], msg: (.[2:] | join("\t"))}]
            | {status: "previewed", changes: .,
               destructive: (map(.flag == "DEST" or .flag == "CONFIRM") | any), ts: (now | floor)}')
        # #504: dashboard.energy is config.json-only (never rendered to .env), so an energy-only
        # edit produces no porcelain row. Surface it as a normal committable INFO change so the UI
        # arms Apply and the commit lands it in config.json. The approval gate allowlists exactly
        # this config.json-only block; any OTHER config.json-only delta still refuses (see
        # control_approval_gate). INFO never flips destructive, so the existing verdict stands.
        # Compare with the reference defaults merged into BOTH sides (#696): the editor round-trips
        # the reference-merged form, so on a config.json that never set dashboard.energy the staged
        # copy carries the materialized defaults — an absent block and explicit defaults are the
        # same settings, not a change.
        if ! jq -e --slurpfile live "$CONFIG_FILE" --slurpfile ref "$REFERENCE_CONFIG" \
            '(($ref[0].dashboard.energy // {}) + ($live[0].dashboard.energy // {}))
             == (($ref[0].dashboard.energy // {}) + (.dashboard.energy // {}))' "$staged" >/dev/null 2>&1; then
            result=$(printf '%s' "$result" | jq '.changes += [{flag:"INFO",key:"dashboard.energy",msg:"Energy calculator settings (dashboard.energy) — electricity price / currency / XMR price updated."}]')
        fi
        control_write_result "$cdir/results" "$id" "$result"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "previewed" "$(porcelain_keys "$out")"
    else
        # Validation failed — reject with pithead's own error tail; nothing stays staged.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$errf")" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "preview" "rejected"
    fi
    rm -f "$errf"
}

# Hand the operator-facing stack files that the ROOT control-runner just wrote back to the stack
# owner (#33 v1.4). control_run_pending is root (User=root in pithead-control.service), so its
# `apply` renders `.env` under `umask 077` as root:root 0600 and rewrites the Caddyfile as root —
# but pithead runs a NON-ROOT operator model ($REAL_USER), and a normal operator-run apply leaves
# these files owned by the operator. Without this, the operator's next `status`/`apply` can't even
# read .env (Permission denied), which is what the tier-4 gate caught. The target owner is DERIVED
# from config.json's on-disk owner — an operator-owned file the dashboard container CANNOT write
# (its raw config.json mount was dropped in #440; control_commit's `cp` also preserves its inode/
# owner), so nothing from the request or spool can steer the chown. $USER/$SUDO_USER are NOT usable
# here — the runner is root, so they read as root. The control-dir (staged/results/audit) is
# deliberately host-owned and is NOT touched: that rw/ro split is the #33 trust boundary.
control_reown_operator_files() {
    local owner f
    # GNU stat first, BSD fallback (see the provision_onion_client_auth note). No owner → skip.
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    [ -n "$owner" ] || return 0
    # .bak-workers is the pre-2.0 name of the migration backup .bak-1x now writes (#1832) — both are
    # listed so a machine that migrated under 1.x still has its old copy reowned rather than stranded.
    for f in "$ENV_FILE" "Caddyfile" "${CONFIG_FILE}.bak-control" "${CONFIG_FILE}.bak-1x" "${CONFIG_FILE}.bak-workers"; do
        [ -e "$f" ] || continue
        # Fail safe: a chown that can't complete leaves the pre-existing bug, never corrupts state.
        chown "$owner" "$f" 2>/dev/null ||
            warn "Could not re-own $f to $owner after the control apply — the operator may need to chown it by hand."
    done
}

# Commit: apply the HOST-SIDE staged copy from the matching preview. A tampered second request
# can't swap the config — commit carries only the id; the config it applies is the one previewed.
control_commit() { # <id> <actor> <control-dir> [confirm-token]
    local id="$1" actor="$2" cdir="$3" confirm="${4:-}"
    local staged="$cdir/staged/$id.json" logf="$cdir/staged/.$id.log" rc=0
    if [ ! -f "$staged" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"no staged intent for this id — preview first",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    if [ -z "$(find "$staged" -mmin -10 2>/dev/null)" ]; then
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"rejected",error:"staged intent expired (older than 10 minutes) — preview again",ts:(now|floor)}')"
        rm -f "$staged"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    # On refusal the gate's stdout is the reason; on approval it is the changed key names, which
    # the audit entries below record — WHAT changed, by name only (#349).
    local gate_out keys=""
    if ! gate_out=$(control_approval_gate "$staged" "$confirm"); then
        [ -n "$gate_out" ] || gate_out="approval denied"
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$gate_out" '{status:"rejected",error:$e,ts:(now|floor)}')"
        rm -f "$staged" "${staged}.confirmed"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "commit" "rejected"
        return 0
    fi
    keys="$gate_out"
    # A confirm-gated destructive change (#719) is logged AS SUCH — the gate touches this marker
    # when a typed confirmation carried an in-scope CONFIRM row past the perimeter. The distinct
    # `commit-confirmed` action separates a dashboard-confirmed disruptive apply from an ordinary
    # (INFO-only) dashboard commit in the tamper-evidence log. Host-CLI applies never reach this log.
    local audit_action="commit"
    if [ -f "${staged}.confirmed" ]; then
        audit_action="commit-confirmed"
        rm -f "${staged}.confirmed"
    fi
    # Keep a pre-change backup; on failure it is named in the result and left in place. The
    # `apply -y` below re-renders the pre-masked prefill copy (#440), so the dashboard's editor
    # form reflects the committed config on the next load.
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak-control"
    cp "$staged" "$CONFIG_FILE"
    "$0" apply -y >"$logf" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        control_reown_operator_files # the root apply wrote .env/Caddyfile as root — give them back (#33)
        control_write_result "$cdir/results" "$id" "$(jq -n '{status:"applied",ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "applied" "$keys"
    else
        # apply's own .apply-incomplete marker handles the container-recreate retry; the config
        # backup lets the operator revert by hand if the new config itself is the problem.
        control_write_result "$cdir/results" "$id" "$(jq -n --arg e "$(tail -c 2000 "$logf")" --arg b "${CONFIG_FILE}.bak-control" '{status:"failed",error:$e,backup:$b,ts:(now|floor)}')"
        control_audit "$cdir/audit/control.log" "$id" "$actor" "$audit_action" "failed" "$keys"
    fi
    rm -f "$staged" "$logf" "${staged}.confirmed"
}
