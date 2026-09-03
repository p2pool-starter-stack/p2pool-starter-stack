# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance rig-miner domain (#1105 Phase 1, develop-v2 lane): a machine that mines instead of
# coordinating. The rig role's pre-fill dials for a Pithead on the host side and publishes what it
# finds to the spool, failing open when it finds nothing (#797 R3); first boot consumes that
# finding, dialing the pool before anything irreversible happens; the machine-role marker is
# written and read back; and the boot leg for a role=rig machine mines rather than bringing up the
# coordinator, on both the wizard and the staged-install path (#797 R4). The built-in miner's own
# config is derived rather than authored, and provision_local_miner converges it on the boot leg
# (#796).
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Left behind, deliberately: the generic boot mechanics this domain sits among — pithead-boot's
# wiring of the miner leg after the slot commit, the A/B commit gate's read of doctor --json
# (#852), the boot health probe (#1140), the self-reboot on a failed health gate (#1065) and the
# appliance battery's release gate (#1064). Those are boot-order and release-gate contracts that
# the rig leg only happens to ride on, and the appliance-boot cut still to come needs them where
# they are; taking them here to reach a rounder size would strand that cut and put three domains
# in one file. pithead-sync's rigforge leg stays behind for the same reason — it is the sync
# path's contract rather than the miner's, and it is not contiguous with this block.
#
# Re-derivations: none. $SANDBOX comes from lib.sh, along with run_sourced and the ok, bad,
# assert_eq, assert_contains, assert_not_contains and assert_rc helpers; $PATH is extended per
# call site and never replaced. The pithead functions under test — publish_rig_defaults,
# firstboot_consume_rig, machine_role, machine_role_from_config, record_machine_role,
# render_local_miner_config, provision_local_miner and firstboot_wizard — resolve inside each
# run_sourced subshell, which sources $STACK for itself rather than relying on an ambient
# definition. Every other name is assigned here and none of them outlives the file: the $RDSB,
# $RCSB, $MRSB, $RIGL, $RPSB, $RPESP, $LMR and $LMP sandbox trees, the output captures beside them
# and the run_rig helper are unset as each section ends. The PITHEAD_* and RF_* names a section
# drives its subject with go two ways, and the assignment form decides which: one that rides as a
# command prefix never enters this shell and needs no unset, while one a section exports standalone
# persists across the commands that follow and is unset with the rest of that section's state.
# This file does both, so read the form in front of you rather than the prefix of the name.
# Nothing writes into the ambient $SANDBOX or $STACK — the calls that run against $SANDBOX publish
# to their own spool argument — and nothing outside this file reads what this one creates.

echo "== unit: publish_rig_defaults — host-side pool discovery, fail open (#797 R3) =="
# The rig role's pre-fill: the HOST dials for a Pithead and publishes the finding to the spool
# like the disk inventory. The dial is 'timeout N bash -c </dev/tcp/...' — timeout is a PATH
# stub here (like mount in the pre-fill tests), so the probe answers deterministically.
RDSB=$(mktemp -d)
mkdir -p "$RDSB/bin" "$RDSB/spool"
printf '#!/bin/bash\nexit 0\n' >"$RDSB/bin/timeout"
chmod +x "$RDSB/bin/timeout"
PITHEAD_RIG_PROBE="coordinator.lan:3333" PATH="$RDSB/bin:$PATH" \
    run_sourced "$SANDBOX" publish_rig_defaults "$RDSB/spool" >/dev/null 2>&1
assert_eq "a Pithead answering -> pool published" "$(jq -r '.pool' "$RDSB/spool/rig-defaults.json")" "coordinator.lan:3333"
assert_eq "the worker default is this machine's own name" "$(jq -r '.worker' "$RDSB/spool/rig-defaults.json")" "$(hostname)"
printf '#!/bin/bash\nexit 1\n' >"$RDSB/bin/timeout"
PITHEAD_RIG_PROBE="coordinator.lan:3333" PATH="$RDSB/bin:$PATH" \
    run_sourced "$SANDBOX" publish_rig_defaults "$RDSB/spool" >/dev/null 2>&1
assert_eq "no answer -> NO pool key, the field opens empty" "$(jq -r 'has("pool")' "$RDSB/spool/rig-defaults.json")" "false"
assert_eq "no temp file beside the atomic target" "$(find "$RDSB/spool" -name '.rig-defaults*' | wc -l | tr -d ' ')" "0"
rm -rf "$RDSB"
unset RDSB

echo "== unit: firstboot_consume_rig — the pool is dialed BEFORE anything irreversible (#797 R3) =="
RCSB=$(mktemp -d)
mkdir -p "$RCSB/bin" "$RCSB/spool"
printf '#!/bin/bash\nexit 0\n' >"$RCSB/bin/timeout"
chmod +x "$RCSB/bin/timeout"

run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "no request -> rc 2 (nothing submitted)" "$?" "2"

printf '{"pool":"not-an-address"}' >"$RCSB/spool/rig-request.json"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "shapeless pool -> rc 1, rejected" "$?" "1"
assert_contains "the rejection names the format" "$(cat "$RCSB/spool/error.txt")" "host:port"
[ -f "$RCSB/rig.json" ] && bad "a rejected request lands nothing" "rig.json exists" || ok "a rejected request lands nothing"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3","stratum_password":"pw-fixture"}' >"$RCSB/spool/rig-request.json"
printf '#!/bin/bash\nexit 1\n' >"$RCSB/bin/timeout"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "unreachable pool -> rc 1 (validate before erase)" "$?" "1"
assert_contains "the failure names the endpoint" "$(cat "$RCSB/spool/error.txt")" "10.0.0.5:3333"

printf '{"pool":"10.0.0.5:3333","worker":"shed-3","stratum_password":"pw-fixture"}' >"$RCSB/spool/rig-request.json"
printf '#!/bin/bash\nexit 0\n' >"$RCSB/bin/timeout"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_rc "reachable pool -> rc 0, accepted" "$?" "0"
assert_eq "the accepted answers land host-side" "$(jq -r '.worker' "$RCSB/rig.json")" "shed-3"
assert_eq "the password rides along" "$(jq -r '.stratum_password' "$RCSB/rig.json")" "pw-fixture"
[ -f "$RCSB/spool/rig-request.json" ] && bad "the request is consumed" "still present" || ok "the request is consumed"

printf '{"pool":"10.0.0.5:3333"}' >"$RCSB/spool/rig-request.json"
PATH="$RCSB/bin:$PATH" run_sourced "$RCSB" firstboot_consume_rig "$RCSB/spool" >/dev/null 2>&1
assert_eq "no worker named -> this machine's own name" "$(jq -r '.worker' "$RCSB/rig.json")" "$(hostname)"
assert_eq "no password -> the key is omitted, not written empty" "$(jq -r 'has("stratum_password")' "$RCSB/rig.json")" "false"
rm -rf "$RCSB"
unset RCSB

echo "== unit: the machine-role marker, written and read back (#797 R3/R4) =="
MRSB=$(mktemp -d)
printf '{"local_miner":{"enabled":true}}' >"$MRSB/config.json"
assert_eq "local_miner on -> both (the role IS the switch)" "$(run_sourced "$MRSB" machine_role_from_config "$MRSB/config.json")" "both"
printf '{}' >"$MRSB/config.json"
assert_eq "no local_miner -> pithead" "$(run_sourced "$MRSB" machine_role_from_config "$MRSB/config.json")" "pithead"
rm -f "$MRSB/config.json"
assert_eq "no marker at all -> pithead (every pre-contract machine)" "$(run_sourced "$MRSB" machine_role)" "pithead"
run_sourced "$MRSB" record_machine_role rig >/dev/null 2>&1
assert_eq "the marker lands where the boot path reads it" "$(cat "$MRSB/machine-role")" "rig"
assert_eq "the boot path reads back what was written" "$(run_sourced "$MRSB" machine_role)" "rig"
printf 'nonsense\n' >"$MRSB/machine-role"
assert_eq "an unreadable marker degrades to pithead, never to rig" "$(run_sourced "$MRSB" machine_role)" "pithead"
rm -rf "$MRSB"
unset MRSB

echo "== unit: the rig boot leg — a role=rig machine mines instead of coordinating (#797 R4) =="
# A rig has no config.json, no .env, no containers and no dashboard: rig.json IS its whole
# contract. Driven against a fake rigforge.sh, like the Both role's leg — the real one compiles
# miners and tunes kernels. What this owns: the derived config (pool + worker + password), the
# invocation contract, and the refusals.
RIGL=$(mktemp -d)
mkdir -p "$RIGL/rigforge" "$RIGL/bin" "$RIGL/run" "$RIGL/journal"
cat >"$RIGL/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset} cwd=$PWD" >>"${RF_LOG:?}"
exit "${RF_RC:-0}"
EOF
chmod +x "$RIGL/rigforge/rigforge.sh"
printf '#!/usr/bin/env bash\necho "systemctl:$*" >>"${RF_LOG:?}"\n' >"$RIGL/bin/systemctl"
chmod +x "$RIGL/bin/systemctl"
# The prebuilt XMRig the image bakes and pithead-sync seeds: present means no compile, which is
# the whole no-clearnet-on-first-boot promise. Its absence is what narrates a build.
mkdir -p "$RIGL/rigforge/data/worker/xmrig/build"
: >"$RIGL/rigforge/data/worker/xmrig/build/xmrig"
chmod +x "$RIGL/rigforge/data/worker/xmrig/build/xmrig"
export RF_LOG="$RIGL/calls" PITHEAD_RIGFORGE_DIR="$RIGL/rigforge"
export PITHEAD_JOURNALD_DROPIN_DIR="$RIGL/run" PITHEAD_JOURNAL_DIR="$RIGL/journal"
run_rig() { PITHEAD_APPLIANCE=1 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" "$@"; }

printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RIGL/rig.json"
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "role=rig without the marker -> still the coordinator leg" "$?" "0"
# rig.json alone means nothing: the MARKER is what the boot path forks on. Unmarked, this is a
# coordinator with local_miner off, and the coordinator leg's job there is to stop the miner.
assert_not_contains "no marker means no rig leg ran" "$(cat "$RF_LOG")" "rigforge:"
assert_contains "unmarked -> the coordinator leg, which stops a miner it does not own" "$(cat "$RF_LOG")" "systemctl:stop xmrig.service"
run_sourced "$RIGL" record_machine_role rig >/dev/null 2>&1
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "marked rig -> rc 0" "$?" "0"
assert_contains "the marked machine runs rigforge setup in appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_contains "it runs from the synced tree on /data" "$(cat "$RF_LOG")" "cwd=$RIGL/rigforge"
assert_contains "the console names the worker and its pool" "$rigl_out" "shed-3 -> 10.0.0.5:3333"
# The derived config: rig.json's three values and nothing else. No hugepages headroom — there is
# no stack on this machine to leave room for.
assert_eq "the pool is the address the operator gave" "$(jq -r '.pools[0].url' "$RIGL/rigforge/config.json")" "10.0.0.5:3333"
assert_eq "the worker name labels the rig at the pool" "$(jq -r '.pools[0].user' "$RIGL/rigforge/config.json")" "shed-3"
assert_eq "no stratum password -> no pass key at all" "$(jq -r '.pools[0] | has("pass")' "$RIGL/rigforge/config.json")" "false"
assert_eq "no stack here -> no hugepages headroom declared" "$(jq -r 'has("hugepages_reserve_extra_mb")' "$RIGL/rigforge/config.json")" "false"
# Prebuilt-first: the seeded binary means the first boot renders, it never compiles or clones.
assert_not_contains "a seeded prebuilt narrates no build" "$rigl_out" "building it once"
# Removable-root tolerance: the journal goes to memory, because the root may be the stick the
# miner runs from — and journald has to be restarted for the setting to take.
assert_contains "journald is flipped to volatile" "$(cat "$RIGL/run/zz-rig-volatile.conf")" "Storage=volatile"
[ -d "$RIGL/journal" ] && bad "the persistent journal directory is reclaimed" "still there" ||
    ok "the persistent journal directory is reclaimed"
assert_contains "journald is restarted so the setting takes" "$(cat "$RF_LOG")" "systemctl:restart systemd-journald"
# A stratum password lands as the pool pass, and the config is re-derived every boot. Idempotent
# on the second boot: nothing left to reclaim, so journald is not restarted again.
printf '{"pool":"pithead.local:3333","worker":"shed-4","stratum_password":"s3cret"}' >"$RIGL/rig.json"
: >"$RF_LOG"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "re-run (the leg fires every boot) -> rc 0" "$?" "0"
assert_eq "the config is re-derived, not repaired" "$(jq -r '.pools[0].url' "$RIGL/rigforge/config.json")" "pithead.local:3333"
assert_eq "the stratum password lands as the pool pass" "$(jq -r '.pools[0].pass' "$RIGL/rigforge/config.json")" "s3cret"
assert_not_contains "already volatile -> journald is not restarted again" "$(cat "$RF_LOG")" "restart systemd-journald"
# No prebuilt (a wiped workspace): the operator gets told why the console is silent for minutes.
rm -rf "$RIGL/rigforge/data/worker/xmrig"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_contains "a missing prebuilt narrates the one-time build" "$rigl_out" "building it once"
# A failing setup is a failing boot leg: the caller leaves the slot uncommitted on it.
rigl_out=$(PITHEAD_APPLIANCE=1 RF_RC=1 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" provision_local_miner 2>&1)
assert_rc "failed setup -> rc 1" "$?" "1"
assert_contains "failed setup is named on the console" "$rigl_out" "did not start"
# A marker with no settings beside it: refuse, and say how to get the machine back.
rm -f "$RIGL/rig.json"
rigl_out=$(run_rig provision_local_miner 2>&1)
assert_rc "marked rig with no settings -> rc 1" "$?" "1"
assert_contains "the refusal names the way back (install again from the stick)" "$rigl_out" "install it again from the stick"
# DIY host: a no-op, marker or not — RigForge there is the operator's own install.
: >"$RF_LOG"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RIGL/rig.json"
PITHEAD_APPLIANCE=0 PATH="$RIGL/bin:$PATH" run_sourced "$RIGL" provision_local_miner >/dev/null 2>&1
assert_eq "DIY host -> touches nothing" "$(cat "$RF_LOG")" ""
unset RF_LOG PITHEAD_RIGFORGE_DIR PITHEAD_JOURNALD_DROPIN_DIR PITHEAD_JOURNAL_DIR
unset -f run_rig
rm -rf "$RIGL"
unset RIGL rigl_out

echo "== unit: a rig's first boot mines — wizard side and staged-install side (#797 R4) =="
# Both boots that ACCEPT a role end mining on that same boot: no second wizard, no reboot to
# wait for. Every LATER boot skips this unit entirely (its condition now excludes rig.json) and
# goes through pithead-boot instead.
RPSB=$(mktemp -d)
RPESP=$(mktemp -d)
mkdir -p "$RPSB/rigforge"
cat >"$RPSB/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset}" >>"${RF_LOG:?}"
EOF
chmod +x "$RPSB/rigforge/rigforge.sh"
export PITHEAD_PRESEED_DIR="$RPESP" PITHEAD_RIGFORGE_DIR="$RPSB/rigforge" RF_LOG="$RPSB/calls"
: >"$RF_LOG"
printf '{"pool":"10.0.0.5:3333","worker":"shed-3"}' >"$RPESP/pithead-rig.json"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$RPSB" firstboot_wizard 2>&1)
assert_rc "staged rig settings -> consumed, rc 0" "$?" "0"
assert_eq "the answers land beside the program" "$(jq -r '.worker' "$RPSB/rig.json")" "shed-3"
assert_eq "the role marker is written" "$(cat "$RPSB/machine-role")" "rig"
assert_contains "the console states the role and the worker" "$out" "RigForge rig"
assert_contains "the staged install mines on that first boot" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_not_contains "no wizard container is started" "$out" "Setup wizard is up"
# Spent, like the config pre-seed: settings (possibly a password) must not sit on the ESP.
[ -f "$RPESP/pithead-rig.json" ] && bad "the consumed settings leave the ESP" "still there" || ok "the consumed settings leave the ESP"
# An already-marked machine reaching this unit by hand takes the same leg, and asks nothing.
: >"$RF_LOG"
out=$(PITHEAD_INSTALL_BIN=/nonexistent run_sourced "$RPSB" firstboot_wizard 2>&1)
assert_rc "already-marked rig -> rc 0, no coordinator questions" "$?" "0"
assert_contains "the marked machine takes the rig leg too" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_not_contains "the R3 stub message is gone" "$out" "nothing mines yet"
unset PITHEAD_PRESEED_DIR PITHEAD_RIGFORGE_DIR RF_LOG
rm -rf "$RPSB" "$RPESP"
unset RPSB RPESP out

echo "== unit: render_local_miner_config — the built-in miner's config is DERIVED (#796) =="
# On the appliance, RigForge's config.json is a pure function of pithead's config.json + .env,
# rebuilt on every render like the Caddyfile: the stack's own stratum over loopback, the stratum
# password when one is set, and the stack's HugePages budget declared as headroom — the hand-off
# that makes RigForge the pool's single (grow-only) writer.
LMR=$(mktemp -d)
mkdir -p "$LMR/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$LMR/config.json"
printf 'STRATUM_PORT=3333\n' >"$LMR/.env"
export PITHEAD_RIGFORGE_DIR="$LMR/rigforge"
PITHEAD_APPLIANCE=0 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "DIY host -> nothing written" "file exists" ||
    ok "DIY host -> nothing written"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/no-marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "pool url is the stack's own stratum over loopback" \
    "$(jq -r '.pools[0].url' "$LMR/rigforge/config.json")" "127.0.0.1:3333"
assert_eq "no stratum password -> no pass key at all" \
    "$(jq -r '.pools[0] | has("pass")' "$LMR/rigforge/config.json")" "false"
assert_eq "no degrade marker -> the full budget is declared as headroom (3072 pages -> 6144 MB)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMR/rigforge/config.json")" "6144"
# #1103 superseded this: it used to assert the recorded reservation as headroom (2560 pages ->
# 5120 MB), the double-count #1103 removes — co-location is now refused outright on this
# REDUCED tier (no config); the rest of the gate is proven in test_appliance_hugepages.sh.
printf 'reduced-reservation words\npages=2560\n' >"$LMR/marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "reduced tier -> co-location refused, no config rendered (#1103)" "file exists" ||
    ok "reduced tier -> co-location refused, no config rendered (#1103)"
printf 'released-reservation words\npages=0\n' >"$LMR/marker"
PITHEAD_APPLIANCE=1 PITHEAD_HUGEPAGES_MARKER="$LMR/marker" run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "released reservation -> zero headroom (RigForge sizes for the miner alone)" \
    "$(jq -r '.hugepages_reserve_extra_mb' "$LMR/rigforge/config.json")" "0"
printf 'STRATUM_PORT=13333\nPROXY_STRATUM_PASSWORD=s3cret\n' >"$LMR/.env"
PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
assert_eq "custom stratum port lands in the pool url" \
    "$(jq -r '.pools[0].url' "$LMR/rigforge/config.json")" "127.0.0.1:13333"
assert_eq "stratum password lands as the pool pass" \
    "$(jq -r '.pools[0].pass' "$LMR/rigforge/config.json")" "s3cret"
# Derived means derived: switched off, the config goes away with the toggle.
printf '{"local_miner":{"enabled":false}}' >"$LMR/config.json"
PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config >/dev/null 2>&1
[ -f "$LMR/rigforge/config.json" ] && bad "disabled -> the derived config is removed" "still there" ||
    ok "disabled -> the derived config is removed"
# Enabled on an image that never baked the tree: warn and carry on — render must not fail.
printf '{"local_miner":{"enabled":true}}' >"$LMR/config.json"
rm -rf "$LMR/rigforge"
lmr_out=$(PITHEAD_APPLIANCE=1 run_sourced "$LMR" render_local_miner_config 2>&1)
assert_rc "missing tree -> rc 0 (render survives)" "$?" "0"
assert_contains "missing tree is named" "$lmr_out" "no RigForge tree"
unset PITHEAD_RIGFORGE_DIR
rm -rf "$LMR"
unset LMR lmr_out

echo "== unit: provision_local_miner — the boot leg converges the miner (#796) =="
# Driven against a fake rigforge.sh: the real one compiles miners and tunes kernels. What this
# owns: the invocation contract (appliance flag set, run from the tree on /data, config rendered
# first) and both convergence directions (enabled -> setup, disabled -> stop).
LMP=$(mktemp -d)
mkdir -p "$LMP/rigforge" "$LMP/bin"
cat >"$LMP/rigforge/rigforge.sh" <<'EOF'
#!/usr/bin/env bash
echo "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset} cwd=$PWD" >>"${RF_LOG:?}"
exit "${RF_RC:-0}"
EOF
chmod +x "$LMP/rigforge/rigforge.sh"
printf '#!/usr/bin/env bash\necho "systemctl:$*" >>"${RF_LOG:?}"\n' >"$LMP/bin/systemctl"
chmod +x "$LMP/bin/systemctl"
export RF_LOG="$LMP/calls" PITHEAD_RIGFORGE_DIR="$LMP/rigforge"
printf '{"local_miner":{"enabled":true}}' >"$LMP/config.json"
printf 'STRATUM_PORT=3333\n' >"$LMP/.env"
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "enabled -> rc 0" "$?" "0"
assert_contains "runs rigforge setup in appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
assert_contains "runs it from the synced tree" "$(cat "$RF_LOG")" "cwd=$LMP/rigforge"
[ -s "$LMP/rigforge/config.json" ] && ok "a missing miner config is rendered before setup" ||
    bad "a missing miner config is rendered before setup" "not written"
# Idempotent re-run (the boot leg fires EVERY boot): same config, run again — same outcome,
# setup invoked again (rigforge's own appliance mode is the idempotency owner), no error.
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "enabled re-run (second boot) -> rc 0" "$?" "0"
assert_contains "re-run invokes setup again, appliance mode" "$(cat "$RF_LOG")" "rigforge:setup appliance=1"
# Disabled: stop the service, never run setup — a dashboard toggle must not wait for a reboot.
printf '{"local_miner":{"enabled":false}}' >"$LMP/config.json"
: >"$RF_LOG"
PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "disabled -> rc 0" "$?" "0"
assert_contains "disabled -> the miner service is stopped" "$(cat "$RF_LOG")" "systemctl:stop xmrig.service"
assert_not_contains "disabled -> rigforge never runs" "$(cat "$RF_LOG")" "rigforge:"
# DIY host: a no-op in both directions — RigForge there is the operator's own install.
printf '{"local_miner":{"enabled":true}}' >"$LMP/config.json"
: >"$RF_LOG"
PITHEAD_APPLIANCE=0 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner >/dev/null 2>&1
assert_rc "DIY host -> rc 0" "$?" "0"
assert_eq "DIY host -> touches nothing" "$(cat "$RF_LOG")" ""
# A failing setup is contained: warned, rc 1, and the caller treats the stack as unaffected.
: >"$RF_LOG"
lmp_out=$(PITHEAD_APPLIANCE=1 RF_RC=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner 2>&1)
assert_rc "failed setup -> rc 1" "$?" "1"
assert_contains "failed setup names the containment" "$lmp_out" "stack itself is unaffected"
# An image that never baked the tree: enabled is a promise the image cannot keep — warn, rc 1.
rm -rf "$LMP/rigforge"
lmp_out=$(PITHEAD_APPLIANCE=1 PATH="$LMP/bin:$PATH" run_sourced "$LMP" provision_local_miner 2>&1)
assert_rc "missing tree -> rc 1" "$?" "1"
assert_contains "missing tree is named" "$lmp_out" "no RigForge tree"
unset RF_LOG PITHEAD_RIGFORGE_DIR
rm -rf "$LMP"
unset LMP lmp_out
