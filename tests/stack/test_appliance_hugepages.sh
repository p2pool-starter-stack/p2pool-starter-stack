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
# The math this exists to stop. RigForge's grow-only write is target = current + required - avail,
# and avail excludes pages the stack already holds. On the REDUCED tier (2560 pages, sized for the
# stack's own two RandomX datasets with no co-resident miner in the budget) any nonzero extra_mb the
# render declares is added to required while the same pages are subtracted from avail — counted
# twice. No declared value bounds it, so the fix refuses co-location on exactly that tier: the
# RELEASED tier (0 pages) already declares zero headroom and has nothing to double-count, and the
# FULL tier is the measured, supported case — neither changes.
#
# CORRECTED (#1103 step 2): the formula this header used to quote —
# `1168*numa + 128 + threads + 10 + (extra_mb+1)/2` — is not one of rigforge's, it MERGES two of
# them. util/proposed-grub.sh at the pinned commit has a 1G-page branch
# (`128 + THREADS + 10 + EXTRA`) and a pure-2MB FALLBACK (`1168*NUMA + THREADS + 50 + EXTRA`), and
# the appliance always takes the FALLBACK because it reserves no 1G pages. The correct figure is
# 1168 + 6 + 50 + 3072 = 4296 pages on the supported X5690; it reproduces both measured landings
# exactly (the 16 GiB guest reads THREADS 32 rather than 6 and lands on 4322 — a KVM artifact).
#
# AND THE ~12 GiB ESTIMATE IS NO LONGER AN ESTIMATE: leg B measured the reduced tier with the
# refusal lifted by hand. RigForge requested 6146 pages (12.0 GiB) on a 7.76 GiB box, the kernel
# granted 2916, MemAvailable fell to ~40 MB, and RigForge exited 0 "Deployment Complete" — a 6.3 GiB
# shortfall that nothing on the box reports. Evidence: ~/appliance-suite-logs/1103/RESULTS.md.
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
# The appliance always has a version-stamped tree here (pithead-sync copies the baked one every
# boot). Without this the full-tier case below would quietly exercise the no-version path instead.
printf '1.16.0\n' >"$LMH/rigforge/VERSION"
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
assert_eq "full tier -> AND the #1103 pool ceiling is declared alongside it" \
    "$(jq -r '.hugepages_pool_ceiling_mb' "$LMH/rigforge/config.json")" "9216"
rm -f "$LMH/rigforge/config.json"
# The released tier is untouched too: it already declares zero headroom, so there is nothing
# for this gate to refuse.
printf 'released\npages=0\n' >"$LMH/released-marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMH/released-marker" run_sourced "$LMH" render_local_miner_config >/dev/null 2>&1
assert_eq "released tier -> still renders, zero headroom (unchanged)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMH/rigforge/config.json")" "0"
# ABSENT, not present-and-zero: `has` is the assertion that discriminates the two, and only the
# absent form leaves rigforge on its documented default.
assert_eq "released tier -> no ceiling key at all (it was measured on the full tier only)" \
    "$(jq -r 'has("hugepages_pool_ceiling_mb")' "$LMH/rigforge/config.json")" "false"
unset PITHEAD_RIGFORGE_DIR

echo "== unit: local_miner_pool_ceiling_mb — the #1103 ceiling and its version gate =="
# WHY A VERSION GATE AT ALL: rigforge IGNORES a config key it does not know — its
# _warn_unknown_config_keys warns and never errors, on the stated ground that "an unknown key is at
# worst a no-op, and erroring would brick fleet applies on any future rename". So declaring the
# ceiling into a tree older than the floor FAILS OPEN: the rendered config would READ as capped and
# behave exactly as it does today. A config that lies about being bounded is worse than one that
# plainly is not, which is what every case below pins.
#
# Each case is asserted on the VALUE (and, where it is the point, on the stated reason). None is
# asserted on rc: this helper returns 0 on every path by construction, so an rc table would be
# vacuous.
CEI="$SANDBOX/cei"
mkdir -p "$CEI/rigforge"
printf '1.16.0\n' >"$CEI/rigforge/VERSION"
# ⛔ PIN THE NODE COUNT FOR EVERY CASE BELOW. local_miner_numa_nodes is a REAL detection against the
# host, so without this the ceiling cases would assert 9216 on a single-node runner and 0 on a
# multi-node one — passing or failing on the topology of whoever ran the suite rather than on the
# code. `fake_lscpu` shadows lscpu on PATH; a stub that prints NOTHING stands in for "no lscpu",
# since an absent binary and a silent one are indistinguishable to this function by construction.
NUMABIN="$SANDBOX/numabin"
mkdir -p "$NUMABIN"
CEI_PATH_SAVED="$PATH"
PATH="$NUMABIN:$PATH"
fake_lscpu() { # <numa-nodes|-> <sockets|->   ('-' omits that line)
    {
        printf '#!/bin/sh\n'
        [ "$2" = "-" ] || printf 'echo "Socket(s):             %s"\n' "$2"
        [ "$1" = "-" ] || printf 'echo "NUMA node(s):          %s"\n' "$1"
    } >"$NUMABIN/lscpu"
    chmod +x "$NUMABIN/lscpu"
}
NONODES="$SANDBOX/nonodes"
mkdir -p "$NONODES"
fake_lscpu 1 1
assert_eq "full tier + the floor release -> the declared ceiling" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "9216"
printf '1.17.2\n' >"$CEI/rigforge/VERSION"
assert_eq "full tier + a NEWER release -> still declared (the gate is a floor, not an equality)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "9216"
printf '1.15.1\n' >"$CEI/rigforge/VERSION"
assert_eq "the release below the floor -> 0, because declaring it there would fail OPEN" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"
assert_contains "below the floor -> says WHY, naming the floor" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>&1 >/dev/null)" "predates 1.16.0"
# 1.9.0 is the case a LEXICAL compare gets backwards ("1.9.0" > "1.16.0" as strings). It is here to
# prove the compare is version-ordered, not string-ordered.
printf '1.9.0\n' >"$CEI/rigforge/VERSION"
assert_eq "1.9.0 -> older than 1.16.0 (a lexical compare would call this NEWER)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"
# The case sort -V alone gets WRONG, and the reason the numeric guard sits in front of the compare:
# verified directly, `printf '1.16.0\ndev\n' | sort -V | head -1` is 1.16.0, so an unguarded
# compare answers "new enough" for a tree that is nothing of the kind. That is a fail-OPEN.
printf 'dev\n' >"$CEI/rigforge/VERSION"
assert_eq "unparseable version -> 0 (fails CLOSED, where sort -V alone fails OPEN)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"
rm -f "$CEI/rigforge/VERSION"
assert_eq "no VERSION file at all -> 0" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"
# Tier narrowness. The value was derived from full-tier measurements only; the released tier holds
# no stack pages, so it has nothing to double-count and no measurement behind any number.
printf '1.16.0\n' >"$CEI/rigforge/VERSION"
printf 'released\npages=0\n' >"$CEI/released-marker"
assert_eq "released tier + a new-enough tree -> still 0 (uncapped, never guessed)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/released-marker" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"

echo "== unit: local_miner_numa_nodes mirrors RigForge's precedence, step for step (#1103) =="
# WHY THIS EXISTS: the 9216 ceiling is a SINGLE-NODE value — rigforge's requirement carries a
# 1168-page term per NUMA node (util/proposed-grub.sh L100-101 at the pinned ref 4ce29b3d), and
# EXTRA_2MB_PAGES does not scale with nodes. At NUMA=2 the requirement is 5464 pages (10,928 MB), so
# the ceiling would cap a HEALTHY box 856 pages short and rigforge would cap-and-continue: a SILENT
# under-reservation. This function has to predict the count rigforge sizes against, so it mirrors
# rigforge's precedence rather than picking a reasonable-looking source — a disagreement between the
# two puts the defect straight back, quietly.
fake_lscpu 1 1
assert_eq "lscpu says one node -> 1" \
    "$(PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_numa_nodes)" "1"
fake_lscpu 2 1
assert_eq "lscpu says two nodes -> 2 (lscpu wins, it is rigforge's first source)" \
    "$(PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_numa_nodes)" "2"
# Step 2: no lscpu answer, count sysfs nodes instead.
NODESYS="$SANDBOX/nodesys"
mkdir -p "$NODESYS/node0" "$NODESYS/node1"
fake_lscpu - -
assert_eq "no lscpu answer -> falls back to the sysfs node count" \
    "$(PITHEAD_NODE_SYS="$NODESYS" run_sourced "$CEI" local_miner_numa_nodes)" "2"
# Step 3 — THE QUIET-DEFECT PATH, and the reason the mirror has three steps and not two. A gate that
# stopped at sysfs would read 1 here and declare the ceiling, while rigforge read the SOCKET count
# and sized for four nodes. Not hypothetical: the #1103 bench guest reports Socket(s)=4 with
# NUMA node(s)=1, so the two sources genuinely disagree on real hardware.
fake_lscpu - 4
assert_eq "no lscpu nodes and no sysfs nodes -> the SOCKET count, exactly as rigforge falls back" \
    "$(PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_numa_nodes)" "4"
fake_lscpu - -
assert_eq "nothing readable anywhere -> 1, rigforge's own final default" \
    "$(PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_numa_nodes)" "1"

echo "== unit: the ceiling is declared ONLY on a single-node box (#1103) =="
fake_lscpu 1 1
# The NO-OP half: at one node the gate must not disturb what the C1/C2 bench pair measured. That
# pair ran on a NUMA=1 guest, so this case is what carries its evidence across to the gated code.
assert_eq "one node -> the measured ceiling, unchanged (the bench pair's regime)" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "9216"
# The half that proves the gate EXISTS. Without this case the suite would be green on a gate that
# did nothing, since the fixture is single-node everywhere else.
fake_lscpu 2 2
assert_eq "two nodes -> 0, uncapped rather than capped below a healthy requirement" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>/dev/null)" "0"
assert_contains "two nodes -> says WHY, naming the count it read" \
    "$(PITHEAD_HUGEPAGES_MARKER="$CEI/no-marker" PITHEAD_NODE_SYS="$NONODES" run_sourced "$CEI" local_miner_pool_ceiling_mb "$CEI/rigforge" 2>&1 >/dev/null)" "reports 2 NUMA nodes"
# And through the render path, as a CONTROLLED PAIR: the node count is the ONLY variable moved
# between these two renders. Without the positive leg, "the key is absent" cannot be told apart
# from a fixture that never armed — which is how an assertion goes green off the wrong door.
CNU="$SANDBOX/cnu"
mkdir -p "$CNU/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$CNU/config.json"
printf 'STRATUM_PORT=3333\n' >"$CNU/.env"
printf '1.16.0\n' >"$CNU/rigforge/VERSION"
fake_lscpu 1 1
PITHEAD_APPLIANCE=1 PITHEAD_RIGFORGE_DIR="$CNU/rigforge" PITHEAD_HUGEPAGES_MARKER="$CNU/no-marker" \
    PITHEAD_NODE_SYS="$NONODES" run_sourced "$CNU" render_local_miner_config >/dev/null 2>&1
assert_eq "one node -> the key IS rendered (the fixture can arm)" \
    "$(jq -r '.hugepages_pool_ceiling_mb' "$CNU/rigforge/config.json")" "9216"
fake_lscpu 2 2
PITHEAD_APPLIANCE=1 PITHEAD_RIGFORGE_DIR="$CNU/rigforge" PITHEAD_HUGEPAGES_MARKER="$CNU/no-marker" \
    PITHEAD_NODE_SYS="$NONODES" run_sourced "$CNU" render_local_miner_config >/dev/null 2>&1
assert_eq "two nodes -> the rendered config carries NO ceiling key at all" \
    "$(jq -r 'has("hugepages_pool_ceiling_mb")' "$CNU/rigforge/config.json")" "false"
assert_eq "two nodes -> the headroom hand-off is still untouched" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$CNU/rigforge/config.json")" "6144"
fake_lscpu 1 1

echo "== unit: render_local_miner_config declares the ceiling only where it is honoured (#1103) =="
RCG="$SANDBOX/rcg"
mkdir -p "$RCG/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$RCG/config.json"
printf 'STRATUM_PORT=3333\n' >"$RCG/.env"
export PITHEAD_RIGFORGE_DIR="$RCG/rigforge"
printf '1.15.1\n' >"$RCG/rigforge/VERSION"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$RCG/no-marker" run_sourced "$RCG" render_local_miner_config >/dev/null 2>&1
assert_eq "old tree -> the key is ABSENT, not present-and-zero" \
    "$(jq -r 'has("hugepages_pool_ceiling_mb")' "$RCG/rigforge/config.json")" "false"
assert_eq "old tree -> the headroom hand-off is untouched" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$RCG/rigforge/config.json")" "6144"
# The positive half of the same fixture: the ONLY variable changed is the version file, so this
# pair shows the fixture can produce the key it just asserted absent.
printf '1.16.0\n' >"$RCG/rigforge/VERSION"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$RCG/no-marker" run_sourced "$RCG" render_local_miner_config >/dev/null 2>&1
assert_eq "new-enough tree -> the key appears, same fixture, one variable moved" \
    "$(jq -r '.hugepages_pool_ceiling_mb' "$RCG/rigforge/config.json")" "9216"
assert_eq "new-enough tree -> and the pool URL is still derived as before" \
    "$(jq -r '.pools[0].url' "$RCG/rigforge/config.json")" "127.0.0.1:3333"
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

# Drop the lscpu shadow — nothing below depends on a pinned node count, and leaving a stub on
# PATH would make any later case answer to it silently.
PATH="$CEI_PATH_SAVED"

echo ""
printf 'appliance-hugepages tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
