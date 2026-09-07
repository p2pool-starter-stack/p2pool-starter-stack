# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Quadlet-render parity domain (#1105 Phase 1, appliance lane): the one section that pins
# render_quadlet_units against the os/quadlet fixtures committed from the #78 spike. It renders
# each of its three modes off that mode's fixture env file — the default remote-node set, the
# local-node set, and the payout-confirm set — and diffs every emitted unit against the
# checked-in file byte-for-byte. Two negative assertions pin what each mode must NOT emit: the
# remote render carries no node units, and the local render carries no wallet units. The fixtures ran live on the bench, so a
# diff here means the renderer drifted from something proven, not that a fixture went stale
# (#77 phase 1).
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Re-derivations. $ROOT and $SANDBOX come from lib.sh, where both are assigned at COLUMN 1 at top
# level, outside every function body — so neither is the ordering dependency the $WALLET case
# turned out to be. (Re-derive by grepping lib.sh for the assignment and reading the indent, not
# by line number: a citation into another file is the perishable part of any claim here.) Every other name is assigned here: $QOUT, $QLOCAL, $QPAY and the loop's
# own $f. The only provider functions called are run_sourced and assert_eq. Every write lands in
# the three $SANDBOX/quadlet-*-out trees, and a sweep of all of tests/stack/ finds those three
# paths named ONLY in this block — nothing else in the suite reads what this file creates, so it
# carries no ambient-fixture coupling in either direction.

: "${ROOT:?}" "${SANDBOX:?}"

echo "== unit: render-quadlet parity vs os/quadlet fixtures (#77 phase 1) =="
# The renderer must reproduce the spike-proven unit set byte-for-byte from the fixture env — the
# os/quadlet files ran live in the #78 spike, so any drift here needs a bench re-proof, not just
# an updated fixture.
QOUT="$SANDBOX/quadlet-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/fixture.env" "$QOUT" >/dev/null
for f in mining.network proxy.network tor.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet parity: $f" "$(diff -u "$ROOT/os/quadlet/$f" "$QOUT/$f" 2>&1 | head -c 300)" ""
done
assert_eq "remote render emits no node units" "$(find "$QOUT" -name 'monerod.container' -o -name 'tari.container' | wc -l | tr -d ' ')" "0"
# The two render targets share one dashboard, and a variable added to the compose service can be
# left off the quadlet unit with nothing red (#1896: the three DASHBOARD_ONION_* values the header
# reads reached compose in #1880 and the unit not at all). Pin the DASHBOARD_* cluster, the keys
# the two paths are meant to share, as compose ⊆ quadlet, read off the compose file itself (no
# docker) and the rendered unit. Not the whole set: compose also carries the DIY channel's
# notification and XVB surface the appliance does not, so equality would be red by design. The
# first row is the parse's own control: a broken awk yields an empty set and a vacuous pass.
compose_dash_keys=$(awk '/^  dashboard:/{f=1;next} f&&/^  [a-z]/{f=0} f' "$ROOT/docker-compose.yml" | sed -nE 's/^ +- ([A-Z_]+)=.*/\1/p' | grep '^DASHBOARD_' | sort -u)
quadlet_dash_keys=$(sed -n 's/^Environment=//p' "$QOUT/dashboard.container" | tr ' ' '\n' | sed -E 's/=.*//' | grep '^DASHBOARD_' | sort -u)
assert_eq "compose parse sees the dashboard service's own keys (control)" "$(printf '%s\n' "$compose_dash_keys" | grep -c '^DASHBOARD_CONTROL_ENABLED$')" "1"
assert_eq "every DASHBOARD_* key compose gives the dashboard is on the quadlet unit (#1896)" "$(comm -23 <(printf '%s\n' "$compose_dash_keys") <(printf '%s\n' "$quadlet_dash_keys") | tr '\n' ' ')" ""
# The local-node variant (bench-proven 2026-07-24): profiles on, 11 files, node units included.
QLOCAL="$SANDBOX/quadlet-local-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/local/fixture.env" "$QLOCAL" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    p2pool.container xmrig-proxy.container caddy.container docker-proxy.container \
    docker-control.container dashboard.container; do
    assert_eq "quadlet local parity: $f" "$(diff -u "$ROOT/os/quadlet/local/$f" "$QLOCAL/$f" 2>&1 | head -c 300)" ""
done
# The payout-confirm variant (bench-proven 2026-07-24): both wallet profiles, 13 files, the
# dashboard gains the payout env keys only in this set (the others stay byte-identical).
QPAY="$SANDBOX/quadlet-payout-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/payout/fixture.env" "$QPAY" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    wallet-rpc.container tari-wallet.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet payout parity: $f" "$(diff -u "$ROOT/os/quadlet/payout/$f" "$QPAY/$f" 2>&1 | head -c 300)" ""
done
assert_eq "local render emits no wallet units" "$(find "$QLOCAL" -name 'wallet-rpc.container' -o -name 'tari-wallet.container' | wc -l | tr -d ' ')" "0"
