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

# The one selection rule for every reader of the per-worker descriptors (#506): workers.list[]
# wins whenever it is set to anything but an empty array; an empty or absent workers.list falls
# back to the deprecated dashboard.workers[] (#172). An empty array is a schema default, not an
# operator choice — the dashboard config editor merges config.reference.json UNDER the operator's
# config, so a staged editor config always carries BOTH keys with at least one of them empty
# (#679); keying any decision on mere presence picks (or refuses) the wrong shape. A set-but-not-
# an-array workers.list still wins, so validation flags it under its own name.
readonly WORKER_LIST_JQ='def worker_list:
    ((.workers // {}) | .list // []) as $n
    | if ($n | type) == "array" and ($n | length) == 0
      then ((.dashboard // {}) | .workers // []) else $n end;'

# Validate the per-worker endpoint descriptors (#506): a list of {name, host?, port?, token?}
# objects the dashboard uses to override the fleet worker-API defaults per rig. workers.list[] is
# the current sub-key; dashboard.workers[] (#172) is read as a deprecated fallback (removed in
# v1.9, one-time warning below) — POPULATING both is refused outright, since silently picking one
# would leave the other a stale, unnoticed copy of hosts/tokens. Presence alone never refuses
# (#679, see WORKER_LIST_JQ above). Nothing here renders to .env — the
# dashboard reads the list straight off its read-only config.json bind mount (tokens stay in the
# one owner-only file that already holds secrets) — so this validation exists to fail an apply
# LOUDLY on a typo instead of the dashboard silently dropping the entry at runtime. The `host`
# charset matters for #122: it must never be able to smuggle a port, path, or userinfo into the
# dashboard's probe URL.
validate_worker_endpoints() {
    local new_n legacy_n dw_path dw_err dw_dups
    # Length, not presence (#679): 0 = absent or empty array (schema default — never an operator
    # signal), >0 = populated, -1 = set to something that isn't an array (validated below under
    # the right path label). A jq parse hiccup degrades to 0, same as the old has() going silent.
    new_n=$(jq -r '(.workers // {}) | (.list // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    legacy_n=$(jq -r '(.dashboard // {}) | (.workers // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [ "${new_n:-0}" != "0" ] && [ "${legacy_n:-0}" != "0" ]; then
        error "config.json sets both workers.list[] and dashboard.workers[] — pick one. dashboard.workers[] is a deprecated alias for workers.list[] (removed in v1.9); move its entries to workers.list[] and delete dashboard.workers."
    fi
    if [ "${legacy_n:-0}" != "0" ] && [ -z "${PITHEAD_WORKERS_LEGACY_WARNED:-}" ]; then
        warn "dashboard.workers[] is deprecated — move its entries to workers.list[] (removed in v1.9)."
        PITHEAD_WORKERS_LEGACY_WARNED=1
    fi
    dw_path="workers.list"
    if [ "${new_n:-0}" = "0" ] && [ "${legacy_n:-0}" != "0" ]; then dw_path="dashboard.workers"; fi
    dw_err=$(jq -r --arg path "$dw_path" "$WORKER_LIST_JQ"'
        worker_list as $w
        | if ($w | type) != "array" then "\($path) must be an array of {name, host?, port?, token?} objects."
          else [ $w[] |
              if type != "object" then "\($path) entries must be objects (got a \(type))."
              elif (.name | type) != "string" or (.name | test("^[!-~]{1,128}$") | not)
                then "\($path): every entry needs a \"name\" of 1-128 printable non-space characters (its stratum worker name)."
              elif has("host") and ((.host | type) != "string" or (.host | test("^[A-Za-z0-9._-]{1,253}$") | not))
                then "\($path)[\(.name)].host must be a hostname or IPv4 address (letters, digits, and . _ - only; no port or path)."
              elif has("port") and ((.port | type) != "number" or .port != (.port | floor) or .port < 1 or .port > 65535)
                then "\($path)[\(.name)].port must be an integer between 1 and 65535."
              elif has("control_port") and ((.control_port | type) != "number" or .control_port != (.control_port | floor) or .control_port < 1 or .control_port > 65535)
                then "\($path)[\(.name)].control_port must be an integer between 1 and 65535 (the rig writable control API port, #185)."
              elif has("token") and ((.token | type) != "string" or (.token | test("^[!-~]{1,128}$") | not))
                then "\($path)[\(.name)].token must be 1-128 printable non-space characters."
              elif has("watts") and ((.watts | type) != "number" or .watts <= 0 or .watts >= 1000000)
                then "\($path)[\(.name)].watts must be a positive number of watts (a manual power-draw estimate for the energy calculator, #260)."
              else empty end
          ] | first // empty end' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_err" ] || error "$dw_err"
    # Duplicate names are legal but only the FIRST declaration counts — surface that, once.
    dw_dups=$(jq -r "$WORKER_LIST_JQ"'[worker_list[] | .name] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$dw_dups" ] || warn "$dw_path has duplicate names ($dw_dups) — the first-declared entry wins; a renamed rig needs its config entry updated."
}

# Migrate a validated deprecated dashboard.workers[] (#172) to workers.list[] (#506) in place:
# move the entries, drop the old key, keep the pre-migration file as ${CONFIG_FILE}.bak-workers
# (the control channel's .bak-control naming). Runs AFTER validate_worker_endpoints, so only a
# config whose legacy entries already passed validation is ever rewritten. Write-back rules
# follow persist_node_credentials: never on a dry run (#556) — which also covers every
# control-channel preview, since preview dry-runs a staged copy — atomic temp+mv under umask 077,
# and best-effort: a failed write warns and the run continues reading the legacy key via
# worker_list. The pre-migration owner is restored after the mv so a root control-runner apply
# (#33) cannot strand config.json root-owned — the #480 bug class control_reown_operator_files
# exists for, handled here because this write happens mid-apply, before that reown runs.
migrate_legacy_workers() {
    local new_n legacy_n owner tmp="${CONFIG_FILE}.tmp"
    [ "$PITHEAD_DRY_RUN" -eq 1 ] && return 0
    new_n=$(jq -r '(.workers // {}) | (.list // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    legacy_n=$(jq -r '(.dashboard // {}) | (.workers // []) | if type == "array" then length else -1 end' "$CONFIG_FILE" 2>/dev/null || echo 0)
    { [ "${legacy_n:-0}" -gt 0 ] && [ "${new_n:-0}" = "0" ]; } || return 0
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak-workers" 2>/dev/null; then
        warn "Could not back up $CONFIG_FILE before migrating dashboard.workers[] — leaving the deprecated key in place."
        return 0
    fi
    owner=$(stat -c '%u:%g' "$CONFIG_FILE" 2>/dev/null || stat -f '%u:%g' "$CONFIG_FILE" 2>/dev/null) || owner=""
    if (
        umask 077
        jq '.workers = ((.workers // {}) + {list: .dashboard.workers}) | .dashboard |= del(.workers)' \
            "$CONFIG_FILE" >"$tmp" 2>/dev/null
    ); then
        mv "$tmp" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        if [ -n "$owner" ]; then chown "$owner" "$CONFIG_FILE" 2>/dev/null || true; fi
        log "Migrated dashboard.workers[] to workers.list[] — the old copy is at ${CONFIG_FILE}.bak-workers."
    else
        rm -f "$tmp"
        warn "Could not migrate dashboard.workers[] to workers.list[] — continuing on the deprecated key (backup left at ${CONFIG_FILE}.bak-workers)."
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
