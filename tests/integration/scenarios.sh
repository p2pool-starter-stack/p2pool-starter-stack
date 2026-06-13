# shellcheck shell=bash
#
# Declarative config matrix for the integration suite (issue #54).
#
# Each scenario is a NAME and a set of `dotted.path=value` overrides applied to the box's
# baseline config.json (see lib.sh:render_scenario_config). Keeping the matrix as data — not
# code — means adding a case is a one-line edit, and selftest.sh can prove that every value
# of every axis is exercised at least once (an acceptance criterion of #54).
#
# The full cross-product is large; we cover the realistic combinations and guarantee each
# axis value appears once. Axes (from the issue):
#   monero.mode .............. local | remote
#   monero.prune ............. true (pruned) | false (full)
#   monero.rpc_lan_access .... false (127.0.0.1) | true (LAN bind)
#   p2pool.pool .............. main | mini | nano
#   xvb.enabled .............. true | false
#   dashboard.secure ......... true (Caddy TLS) | false
#   dashboard.tari_required .. true (blocking) | false (non-blocking)
#   monero/tari.clearnet_initial_sync (#183) .. true (clearnet IBD) | false (Tor, the default)
#
# The clearnet_initial_sync `false` value is the default exercised by every other scenario (they
# never set the key); only the `true` value needs a dedicated case, so axis_coverage lists just
# the `true`s — run.sh asserts the rendered Tor-vs-clearnet config for both states on every run.
#
# Prerequisite-gated axes (skipped-with-a-loud-log, never silently, when the box can't host
# them — see run.sh):
#   * monero.prune=false (full) and =true (pruned) are different on-disk DBs. We only flip
#     prune when a matching synced data dir is available; otherwise the case is reported
#     SKIPPED so we never silently drop coverage or mutate the canonical chain.
#   * monero.mode=remote needs a reachable external node (REMOTE_MONERO_HOST); the natural
#     choice is the box's own synced monerod on its LAN address.

# Emit the matrix as `NAME<TAB>overrides…`, one scenario per line. Lines starting with the
# canonical-first scenario are ordered so the cheapest, most-common config runs first.
scenario_matrix() {
    cat <<'EOF'
local-pruned-main-secure-tari	monero.mode=local monero.prune=true monero.rpc_lan_access=false p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
local-full-main-secure-tari	monero.mode=local monero.prune=false p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
local-pruned-mini-secure-tari	monero.mode=local monero.prune=true p2pool.pool=mini xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
local-pruned-nano-insecure	monero.mode=local monero.prune=true p2pool.pool=nano xvb.enabled=true dashboard.secure=false dashboard.tari_required=true
local-pruned-main-rpclan	monero.mode=local monero.prune=true monero.rpc_lan_access=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
local-pruned-main-xvb-off	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=false dashboard.secure=true dashboard.tari_required=true
local-pruned-main-tari-optional	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=false
local-pruned-main-clearnet-sync	monero.mode=local monero.prune=true monero.clearnet_initial_sync=true tari.clearnet_initial_sync=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
remote-main-secure-tari	monero.mode=remote p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true
EOF
}

# The axis -> values map the matrix must cover. selftest.sh asserts every value below appears
# in at least one scenario's overrides (or is justified as prerequisite-gated).
axis_coverage() {
    cat <<'EOF'
monero.mode=local
monero.mode=remote
monero.prune=true
monero.prune=false
monero.rpc_lan_access=true
monero.rpc_lan_access=false
p2pool.pool=main
p2pool.pool=mini
p2pool.pool=nano
xvb.enabled=true
xvb.enabled=false
dashboard.secure=true
dashboard.secure=false
dashboard.tari_required=true
dashboard.tari_required=false
monero.clearnet_initial_sync=true
tari.clearnet_initial_sync=true
EOF
}

# Print the override string for a named scenario (empty if not found).
scenario_overrides() {
    local want="$1" name rest
    while IFS=$'\t' read -r name rest; do
        [ "$name" = "$want" ] && { printf '%s' "$rest"; return 0; }
    done < <(scenario_matrix)
    return 1
}

# Print just the scenario names, one per line.
scenario_names() {
    local name rest
    while IFS=$'\t' read -r name rest; do
        [ -n "$name" ] && printf '%s\n' "$name"
    done < <(scenario_matrix)
}
