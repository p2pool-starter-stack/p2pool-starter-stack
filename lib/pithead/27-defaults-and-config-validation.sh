# Defaults an APPLIANCE should carry that a DIY host should not. Applied only where a key is
# ABSENT — an operator who wrote "false" meant it.
#
# tor.auto_heal: opt-in on DIY because restarting Tor drops every circuit, and the stack should
# not reshape an operator's privacy boundary behind their back. On an appliance there is no back
# to go behind: it is headless and unattended, and the failure it heals is SILENT — mining keeps
# working while Healthchecks, Telegram and XvB all go dark at once. Production once sat that way
# for six hours. The heal is probe-driven, rate-limited and bounded, so the risk it guards
# against does not apply the way it does interactively.
apply_appliance_defaults() {
    [ -f "$CONFIG_FILE" ] || return 0
    local tmp
    tmp=$(mktemp) || return 1
    # dashboard.control.enabled: on DIY the operator has a shell, so the config editor is a
    # convenience and stays off. An appliance has NO other way in — no shell, ssh disabled — so
    # without this the machine is unconfigurable after first boot and the only route to a changed
    # payout address is a reflash. Production runs with it on. It sits behind the generated
    # login, which is why the password above is not optional.
    # ...but only behind a password. `strip_defaults` drops any wizard answer equal to the
    # reference default, and the reference has control.enabled false, so the key is absent from
    # EVERY submission — including "No login", which leaves the password empty. Injecting
    # unconditionally therefore built the exact pair parse_and_validate_config refuses, and the
    # machine dead-ended on first boot after the operator had been told provisioning started
    # (#1066). An unauthenticated config editor is what that rule exists to prevent, so the
    # honest resolution is to leave the channel off rather than to weaken the rule.
    if jq '
        if .tor.auto_heal == null then (.tor //= {}) | .tor.auto_heal = true else . end
        | if .dashboard.control.enabled == null and ((.dashboard.auth.password // "") != "")
          then (.dashboard //= {}) | (.dashboard.control //= {}) | .dashboard.control.enabled = true
          else . end' \
        "$CONFIG_FILE" >"$tmp" && mv "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# The one selection rule for every reader of the per-worker descriptors (#506): the descriptors
# live at workers.list[] and nowhere else. Until 2.0.0 an empty or absent workers.list fell back
# to the deprecated dashboard.workers[] (#172); that alias is gone (#1832) and a pre-2.0 config
# carrying it is MIGRATED before anything reads it, so no reader needs the fallback any more.
# A set-but-not-an-array workers.list still reaches validation under its own name.
readonly WORKER_LIST_JQ='def worker_list: ((.workers // {}) | .list // []);'

# Validate the per-worker endpoint descriptors (#506): a list of {name, host?, port?, token?}
# objects the dashboard uses to override the fleet worker-API defaults per rig. Nothing here
# renders to .env — the dashboard reads the list straight off its read-only config.json bind
# mount (tokens stay in the one owner-only file that already holds secrets) — so this validation
# exists to fail an apply LOUDLY on a typo instead of the dashboard silently dropping the entry
# at runtime. The `host` charset matters for #122: it must never be able to smuggle a port, path,
# or userinfo into the dashboard's probe URL.
# ORDER MATTERS (#1832): migrate_legacy_workers runs BEFORE this, so entries that arrived under
# the removed dashboard.workers[] alias are validated here under workers.list[] like any other.
# Validating first would pass an empty list and only then move unvalidated entries in.
validate_worker_endpoints() {
    local dw_err dw_dups
    dw_err=$(jq -r "$WORKER_LIST_JQ"'
        worker_list as $w
        | if ($w | type) != "array" then "workers.list must be an array of {name, host?, port?, token?} objects."
          else [ $w[] |
              if type != "object" then "workers.list entries must be objects (got a \(type))."
              elif (.name | type) != "string" or (.name | test("^[!-~]{1,128}$") | not)
                then "workers.list: every entry needs a \"name\" of 1-128 printable non-space characters (its stratum worker name)."
              elif has("host") and ((.host | type) != "string" or (.host | test("^[A-Za-z0-9._-]{1,253}$") | not))
                then "workers.list[\(.name)].host must be a hostname or IPv4 address (letters, digits, and . _ - only; no port or path)."
              elif has("port") and ((.port | type) != "number" or .port != (.port | floor) or .port < 1 or .port > 65535)
                then "workers.list[\(.name)].port must be an integer between 1 and 65535."
              elif has("control_port") and ((.control_port | type) != "number" or .control_port != (.control_port | floor) or .control_port < 1 or .control_port > 65535)
                then "workers.list[\(.name)].control_port must be an integer between 1 and 65535 (the rig writable control API port, #185)."
              elif has("token") and ((.token | type) != "string" or (.token | test("^[!-~]{1,128}$") | not))
                then "workers.list[\(.name)].token must be 1-128 printable non-space characters."
              elif has("watts") and ((.watts | type) != "number" or .watts <= 0 or .watts >= 1000000)
                then "workers.list[\(.name)].watts must be a positive number of watts (a manual power-draw estimate for the energy calculator, #260)."
              else empty end
          ] | first // empty end' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_err" ] || error "$dw_err"
    # Duplicate names are legal but only the FIRST declaration counts — surface that, once.
    dw_dups=$(jq -r "$WORKER_LIST_JQ"'[worker_list[] | .name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_dups" ] || warn "workers.list has duplicate names ($dw_dups) — the first-declared entry wins; a renamed rig needs its config entry updated."
}

# The 1.x -> 2.0 config migration (#1832), and the ONLY code left that understands the two
# deprecated key shapes 2.0.0 removed:
#   dashboard.workers[] -> workers.list[]  (relocated in #506; the fallback read is gone)
#   xmrig_proxy.{enabled,url,donor_id} -> xvb.*  (the block was renamed; the fallback read is gone)
# Migrate once, in place, then refuse: after this runs the old names are keys nothing reads, and
# the control channel's closed-schema check (43-control-approval-and-preview.sh) refuses them like
# any other typo. On a DIY host there is no such check, which is exactly why this migration is the
# safety story and not a convenience — without it a 1.x config would be accepted and its XvB and
# per-rig settings silently ignored.
# MUST RUN BEFORE validate_worker_endpoints (parse_and_validate_config calls it first): migrating
# afterwards would move entries in that validation had already skipped over.
# REFUSES rather than guesses when an old and a new name are BOTH set to DIFFERENT values —
# silently picking one leaves the other a stale, unnoticed copy of hosts and tokens. Set to the
# SAME value they are not a conflict, and the old name is simply dropped. An empty dashboard.workers
# array is a schema default, never an operator choice (#679) — the dashboard config editor merges
# config.reference.json UNDER the operator's config — so it can never trip the refusal.
# Write-back rules follow persist_node_credentials: never on a dry run (#556) — which also covers
# every control-channel preview, since preview dry-runs a staged copy — atomic temp+mv under
# umask 077, and best-effort. The pre-migration file is kept as ${CONFIG_FILE}.bak-1x. The
# pre-migration owner is restored after the mv so a root control-runner apply (#33) cannot strand
# config.json root-owned — the #480 bug class control_reown_operator_files exists for, handled here
# because this write happens mid-apply, before that reown runs.
readonly XVB_ALIAS_KEYS_JQ='["enabled", "url", "donor_id"]'
migrate_legacy_workers() {
    local conflict owner populated tmp="${CONFIG_FILE}.tmp"
    [ -f "$CONFIG_FILE" ] || return 0
    # The refusal is checked on EVERY run, dry or not: a config that sets an old and a new name to
    # different values must fail the apply it was handed to, not just the one that would rewrite it.
    conflict=$(jq -r --argjson ks "$XVB_ALIAS_KEYS_JQ" '
        [ (select(((.dashboard // {}) | .workers // []) != [] and ((.workers // {}) | .list // []) != []
                  and (.dashboard.workers != .workers.list))
           | "workers.list[] and dashboard.workers[]"),
          ($ks[] as $k | select(((.xmrig_proxy // {}) | has($k)) and ((.xvb // {}) | has($k))
                                and (.xmrig_proxy[$k] != .xvb[$k]))
           | "xvb.\($k) and xmrig_proxy.\($k)") ] | join("; ")' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$conflict" ]; then
        error "config.json sets both a removed 1.x key and its replacement to different values ($conflict). The 1.x names were removed in 2.0.0; keep the replacement, delete the old key, and re-run."
    fi
    [ "$PITHEAD_DRY_RUN" -eq 1 ] && return 0
    # Nothing to move is the common case — do not touch the file, and do not leave a backup.
    jq -e 'has("xmrig_proxy") or ((.dashboard // {}) | has("workers"))' "$CONFIG_FILE" >/dev/null 2>&1 || return 0
    # Is there 1.x DATA here, or only names to drop? An empty dashboard.workers[] and an
    # xmrig_proxy block xvb already mirrors lose nothing if the move fails. Populated ones are
    # lost SILENTLY once the fallback reads are gone: the validator sees an empty workers.list[]
    # and passes, render reads .xvb.* and falls back to defaults, and the apply REPORTS SUCCESS
    # while dropping the operator's XvB endpoint and per-rig hosts and tokens. So the two
    # best-effort branches below fail CLOSED whenever losing the move would lose settings, and
    # stay best-effort when it would not — a blanket error would break `backup` and
    # `release-verify`, which call parse_and_validate_config on paths that write nothing. The
    # same answer picks the success line: only a populated config had anything to migrate.
    populated=1
    jq -e --argjson ks "$XVB_ALIAS_KEYS_JQ" '. as $r
        | (((.dashboard // {}) | .workers // []) != [])
          or ([ $ks[] as $k | select((($r.xmrig_proxy // {}) | has($k))
                                     and ((($r.xvb // {}) | has($k)) | not)) ] | length > 0)' \
        "$CONFIG_FILE" >/dev/null 2>&1 || populated=0
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak-1x" 2>/dev/null; then
        if [ "$populated" -eq 1 ]; then
            error "Could not back up $CONFIG_FILE before migrating its 1.x config keys, and it carries 1.x settings 2.0.0 no longer reads. Refusing: applying now would report success while dropping your XvB settings and per-rig hosts and tokens. Free space or fix the permissions on the config directory, then re-run."
        fi
        warn "Could not back up $CONFIG_FILE before migrating the 1.x config keys — leaving them in place; they are no longer read."
        return 0
    fi
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    if (
        umask 077
        jq --argjson ks "$XVB_ALIAS_KEYS_JQ" '
            (if ((.dashboard // {}) | .workers // []) != []
             then .workers = ((.workers // {}) + {list: .dashboard.workers}) else . end)
            | (if (.dashboard | type) == "object" then .dashboard |= del(.workers) else . end)
            | reduce $ks[] as $k (.;
                if ((.xmrig_proxy // {}) | has($k)) and (((.xvb // {}) | has($k)) | not)
                then (.xvb //= {}) | .xvb[$k] = .xmrig_proxy[$k] else . end)
            | del(.xmrig_proxy)' "$CONFIG_FILE" >"$tmp" 2>/dev/null
    ); then
        mv "$tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        if [ -n "$owner" ]; then chown "$owner" "$CONFIG_FILE" 2>/dev/null || true; fi
        if [ "$populated" -eq 1 ]; then
            log "Migrated the 1.x config keys (dashboard.workers[] to workers.list[], xmrig_proxy.* to xvb.*) — the old copy is at ${CONFIG_FILE}.bak-1x."
        else
            log "Deleted the empty 1.x config keys — they carried nothing to move. The old copy is at ${CONFIG_FILE}.bak-1x."
        fi
    else
        rm -f "$tmp"
        if [ "$populated" -eq 1 ]; then
            error "Could not migrate the 1.x config keys in $CONFIG_FILE, and it carries 1.x settings 2.0.0 no longer reads. Refusing: applying now would report success while dropping your XvB settings and per-rig hosts and tokens. The pre-migration copy is at ${CONFIG_FILE}.bak-1x."
        fi
        warn "Could not migrate the 1.x config keys in $CONFIG_FILE — they are no longer read (backup left at ${CONFIG_FILE}.bak-1x)."
    fi
}

# Validate the dashboard.energy block for the energy/profit calculator (#260). Like the worker
# descriptors, this renders nothing to .env — the dashboard reads it off the read-only config.json
# bind mount — so validation exists only to fail an apply loudly on a typo. Prices are operator-set
# non-negative numbers and the currency a short label; price_feed (#520) opts into fetching both
# prices live from CoinGecko over Tor instead (the static numbers stay as the fallback).
validate_energy_config() {
    local en_err
    en_err=$(jq -r '
        (.dashboard.energy // {}) as $e
        | if ($e | type) != "object" then "dashboard.energy must be an object {cost_per_kwh, currency?, xmr_price?, tari_price?, price_feed?}."
          elif (($e | keys) - ["cost_per_kwh", "currency", "xmr_price", "tari_price", "price_feed"]) != []
            then "dashboard.energy has an unknown key (\(($e | keys) - ["cost_per_kwh", "currency", "xmr_price", "tari_price", "price_feed"] | join(", "))). Only cost_per_kwh, currency, xmr_price, tari_price and price_feed are allowed."
          elif ($e | has("cost_per_kwh")) and (($e.cost_per_kwh | type) != "number" or $e.cost_per_kwh < 0)
            then "dashboard.energy.cost_per_kwh must be a non-negative number (your electricity price per kWh; 0 or unset hides the profit math)."
          elif ($e | has("xmr_price")) and (($e.xmr_price | type) != "number" or $e.xmr_price < 0)
            then "dashboard.energy.xmr_price must be a non-negative number (the fiat price of 1 XMR in your currency; 0 or unset hides net profit)."
          elif ($e | has("tari_price")) and (($e.tari_price | type) != "number" or $e.tari_price < 0)
            then "dashboard.energy.tari_price must be a non-negative number (the fiat price of 1 XTM in your currency; 0 or unset excludes Tari from net profit)."
          elif ($e | has("currency")) and (($e.currency | type) != "string" or ($e.currency | test("^[!-~]{1,128}$") | not))
            then "dashboard.energy.currency must be a short currency label (e.g. USD, EUR)."
          elif ($e | has("price_feed")) and (($e.price_feed | type) != "boolean")
            then "dashboard.energy.price_feed must be true or false (fetch live XMR/XTM prices from CoinGecko over Tor; default false, no clearnet egress)."
          else empty end' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$en_err" ] || error "$en_err"
}
