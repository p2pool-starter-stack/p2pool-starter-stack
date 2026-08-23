#!/usr/bin/env bash
#
# Tier-1 proof for #1103: a reduced-RAM appliance must not co-locate the built-in RigForge
# miner with a headroom declaration that double-counts the stack's own HugePages reservation.
#
# tests/stack/run.sh already proves render_local_miner_config's DERIVATION (pool URL, secret,
# the full/released headroom values) — this file is a sibling, not a duplicate: it proves the
# NEW #1103 gate that sits in front of that derivation, so it lives on its own rather than
# growing a file mid-split (#1105 Phase 1). See tests/os/hugepages-boot-verdict.sh /
# os/overlay/pithead-hugepages for where the marker this gate reads comes from — a real KVM
# boot on reduced -m proves the marker itself; this proves what pithead does once it exists.
#
# The math this exists to stop (from the issue): RigForge's grow-only pool write is
# required = 1168*numa + 128 + threads + 10 + (extra_mb+1)/2, and avail excludes pages the
# stack already holds. On the REDUCED tier (2560 pages, sized for the stack's own two RandomX
# datasets with no co-resident miner in the budget) any nonzero extra_mb the render declares is
# added to required while the same pages are subtracted from avail — a real machine's numbers
# put that at ~12 GiB requested on an 8 GiB box. No declared value bounds it, so the fix refuses
# co-location on exactly that tier: the RELEASED tier (0 pages) already declares zero headroom
# and has nothing to double-count, and the FULL tier is the measured, supported case — neither
# changes.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"

echo "== unit: local_miner_hugepages_blocked — exactly the reduced tier is blocked =="
HG="$SANDBOX/hg"
mkdir -p "$HG"
assert_eq "no marker (healthy/DIY) -> not blocked" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/no-marker" run_sourced "$HG" local_miner_hugepages_blocked && echo yes || echo no)" "no"
printf 'reduced\npages=2560\n' >"$HG/reduced-marker"
assert_eq "reduced tier (2560 pages) -> blocked" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/reduced-marker" run_sourced "$HG" local_miner_hugepages_blocked && echo yes || echo no)" "yes"
printf 'released\npages=0\n' >"$HG/released-marker"
assert_eq "released tier (0 pages) -> NOT blocked (nothing left to double-count)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/released-marker" run_sourced "$HG" local_miner_hugepages_blocked && echo yes || echo no)" "no"
printf 'full\npages=3072\n' >"$HG/full-marker"
assert_eq "marker present but at the full budget -> NOT blocked" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/full-marker" run_sourced "$HG" local_miner_hugepages_blocked && echo yes || echo no)" "no"

echo "== unit: render_local_miner_config refuses the reduced tier (#1103) =="
LMH="$SANDBOX/lmh"
mkdir -p "$LMH/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$LMH/config.json"
printf 'STRATUM_PORT=3333\n' >"$LMH/.env"
export PITHEAD_RIGFORGE_DIR="$LMH/rigforge"
printf 'reduced\npages=2560\n' >"$LMH/reduced-marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMH/reduced-marker" run_sourced "$LMH" render_local_miner_config >/dev/null 2>&1
[ -f "$LMH/rigforge/config.json" ] && bad "reduced tier -> no derived config (was blocked)" "file exists" ||
    ok "reduced tier -> no derived config (was blocked)"
# The full tier is untouched: this is the regression a sloppy fix would introduce (blocking
# everything, or shrinking the healthy-box declaration).
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMH/no-marker" run_sourced "$LMH" render_local_miner_config >/dev/null 2>&1
assert_eq "full tier -> headroom is UNCHANGED at 6144 MB (no regression on a normal box)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMH/rigforge/config.json")" "6144"
rm -f "$LMH/rigforge/config.json"
# The released tier is untouched too: it already declares zero headroom, so there is nothing
# for this gate to refuse.
printf 'released\npages=0\n' >"$LMH/released-marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMH/released-marker" run_sourced "$LMH" render_local_miner_config >/dev/null 2>&1
assert_eq "released tier -> still renders, zero headroom (unchanged)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMH/rigforge/config.json")" "0"
unset PITHEAD_RIGFORGE_DIR

echo "== unit: provision_local_miner stops/refuses the miner on the reduced tier (#1103) =="
LMP="$SANDBOX/lmp"
mkdir -p "$LMP/bin" "$LMP/rigforge"
cat >"$LMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"${SYSTEMCTL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$LMP/bin/systemctl"
cat >"$LMP/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge.sh $*" >>"${RIGFORGE_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$LMP/rigforge/rigforge.sh"
printf '{"local_miner":{"enabled":true}}' >"$LMP/config.json"
printf 'reduced\npages=2560\n' >"$LMP/reduced-marker"
export PITHEAD_RIGFORGE_DIR="$LMP/rigforge" SYSTEMCTL_LOG="$LMP/systemctl.log" RIGFORGE_LOG="$LMP/rigforge.log"
lmp_out=$(PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMP/reduced-marker" PATH="$LMP/bin:$PATH" \
    run_sourced "$LMP" provision_local_miner 2>&1)
assert_rc "blocked -> rc 0 (refusing is not a failure)" "$?" "0"
assert_contains "blocked -> the operator is told why" "$lmp_out" "reduced HugePages reservation"
assert_contains "blocked -> any running miner is stopped" "$(cat "$LMP/systemctl.log" 2>/dev/null)" "stop xmrig.service"
assert_not_contains "blocked -> RigForge's own setup never runs" "$(cat "$LMP/rigforge.log" 2>/dev/null)" "setup"
[ -f "$LMP/rigforge/config.json" ] && bad "blocked -> no derived config left behind" "file exists" ||
    ok "blocked -> no derived config left behind"
unset PITHEAD_RIGFORGE_DIR SYSTEMCTL_LOG RIGFORGE_LOG

echo "== unit: announce_local_miner (appliance) states the refusal instead of claiming the worker runs =="
LMA="$SANDBOX/lma"
mkdir -p "$LMA"
printf '{"local_miner":{"enabled":true}}' >"$LMA/config.json"
printf 'reduced\npages=2560\n' >"$LMA/reduced-marker"
lma_out=$(PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMA/reduced-marker" run_sourced "$LMA" announce_local_miner 2>&1)
assert_contains "blocked -> announcement names the reduced reservation" "$lma_out" "reduced HugePages reservation"
assert_not_contains "blocked -> announcement does not claim the worker is on" "$lma_out" "is ON: this machine"

echo "== unit: doctor's check_local_miner_hugepages_blocked (#1103) =="
DLB="$SANDBOX/dlb"
mkdir -p "$DLB"
printf 'reduced\npages=2560\n' >"$DLB/reduced-marker"
printf '{"local_miner":{"enabled":true}}' >"$DLB/config.json"
out=$(PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$DLB/reduced-marker" \
    run_sourced "$DLB" check_local_miner_hugepages_blocked 2>&1)
assert_contains "enabled + blocked -> WARNs" "$out" "reduced HugePages reservation"
printf '{"local_miner":{"enabled":false}}' >"$DLB/config.json"
assert_eq "disabled -> silent even on the reduced tier" \
    "$(PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$DLB/reduced-marker" run_sourced "$DLB" check_local_miner_hugepages_blocked 2>&1)" ""
printf '{"local_miner":{"enabled":true}}' >"$DLB/config.json"
assert_eq "enabled + full tier -> silent (nothing to warn about)" \
    "$(PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$DLB/no-marker" run_sourced "$DLB" check_local_miner_hugepages_blocked 2>&1)" ""
assert_eq "off the appliance -> silent regardless" \
    "$(PITHEAD_APPLIANCE=0 PITHEAD_HUGEPAGES_MARKER="$DLB/reduced-marker" run_sourced "$DLB" check_local_miner_hugepages_blocked 2>&1)" ""

echo ""
printf 'appliance-hugepages tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
