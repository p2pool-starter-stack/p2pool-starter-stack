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
#   network.subnet (#180/#201) .. default 172.28.0.0/24 | a moved /24 (e.g. 10.84.0.0/24)
#   tari.mode ................ local | remote (#103)
#   p2pool.stratum_tls ........ false | true (#261)
#   network.tor_egress_firewall .. true (default) | false (#270)
#   payout confirmation ...... unset (default) | monero.view_key (+ optional tari pair, #381/#462)
#
# The clearnet_initial_sync `false` value is the default exercised by every other scenario (they
# never set the key); only the `true` value needs a dedicated case, so axis_coverage lists just
# the `true`s — run.sh asserts the rendered Tor-vs-clearnet config for both states on every run.
# tari.mode/stratum_tls/tor_egress_firewall follow the same rule: only the non-default value gets
# a dedicated case.
#
# Prerequisite-gated axes (skipped-with-a-loud-log, never silently, when the box can't host
# them — see run.sh):
#   * monero.prune=false (full) and =true (pruned) are different on-disk DBs. We only flip
#     prune when a matching synced data dir is available; otherwise the case is reported
#     SKIPPED so we never silently drop coverage or mutate the canonical chain.
#   * monero.mode=remote needs a reachable external node (REMOTE_MONERO_HOST); the natural
#     choice is the box's own synced monerod on its LAN address.
#   * tari.mode=remote (#103) needs its own reachable external node (REMOTE_TARI_HOST) — the
#     same shape as monero's, an already-synced Tari node.
#   * network.subnet is a set-at-install knob: moving it changes the docker bridge's IPAM subnet,
#     which Compose cannot recreate while containers are attached — a hot `apply` fails. So the
#     matrix line documents the axis for coverage, resolve_overrides SKIPS it in the hot-apply
#     loop (with a loud reason), and run.sh's `--subnet` phase runs it for real via a full
#     down -> up on the moved subnet (chains are bind-mounted by path, so they are never touched).
#   * Payout confirmation (#381/#462) needs a REAL Monero view key for the box's own wallet
#     (IT_MONERO_VIEW_KEY) — never hardcoded here. The row carries the marker
#     "payout_confirm=env"; resolve_overrides swaps it for the real monero.view_key override (and
#     folds in tari.view_key/spend_public_key too when IT_TARI_VIEW_KEY + IT_TARI_SPEND_PUBLIC_KEY
#     are BOTH set), or SKIPs the row when the env var is absent.

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
local-pruned-main-subnet	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true network.subnet=10.84.0.0/24
remote-tari-main-secure	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true tari.mode=remote
local-pruned-main-stratum-tls	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true p2pool.stratum_tls=true
local-pruned-main-firewall-off	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true network.tor_egress_firewall=false
local-pruned-main-payout-confirm	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=true dashboard.tari_required=true payout_confirm=env
local-pruned-main-insecure	monero.mode=local monero.prune=true p2pool.pool=main xvb.enabled=true dashboard.secure=false dashboard.tari_required=true
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
network.subnet=10.84.0.0/24
tari.mode=remote
p2pool.stratum_tls=true
network.tor_egress_firewall=false
payout_confirm=env
EOF
}

# Print the override string for a named scenario (empty if not found).
scenario_overrides() {
    local want="$1" name rest
    while IFS=$'\t' read -r name rest; do
        [ "$name" = "$want" ] && {
            printf '%s' "$rest"
            return 0
        }
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

# Pure membership test on a comma-separated Compose profiles list (#1301) — the runtime
# counterpart of this file's monero.mode/tari.mode axes: render_env (pithead's env writer) turns
# the local/remote choice above into COMPOSE_PROFILES by APPENDING tokens (local_node, then
# local_tari/payout_confirm/tari_payout_confirm as those features turn on), so a standard local
# box's COMPOSE_PROFILES reads "local_node,local_tari,payout_confirm", never the bare token
# alone. A strict string-equality comparison against one literal token therefore only ever
# matches when that token is the ONLY active profile — not a configuration run.sh's six
# local-mode gates were ever meant to require, so they silently read every standard local box as
# remote mode. Mirrors pithead's own membership idiom (remove_deactivated_profile_containers in
# the `pithead` CLI). Sourced (via this file) by run.sh; selftest-compose-profiles.sh proves the
# mutation this guards against: reverting to a literal `[ "$1" = "$2" ]` comparison must go red.
has_compose_profile() { # <profiles-csv> <token>
    case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
    esac
}
