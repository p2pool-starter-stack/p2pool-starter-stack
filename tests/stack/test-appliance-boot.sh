# shellcheck shell=bash
#
# Appliance boot domain (#1105 Phase 1, develop-v2 lane): what an appliance does between power-on
# and a slot it is willing to keep. The baked image store is loaded by archive digest rather than
# by tag, rebuilds itself when an interrupted write leaves it damaged, and narrates a slow load
# without narrating a fast one (#798). pithead-boot then wires the miner leg AFTER the slot commit,
# the A/B commit gate reads doctor --json rather than trusting the curl alone (#852), and the boot
# health probe asks the dashboard's own site and can tell it apart from anything else answering
# (#1140). The verdict helpers that gate the commit are here with it — os_update_rollback_verdict's
# rolled_back case, provable without a KVM boot (#1051), and revenue_container_verdict's honesty
# about syncing versus crashed (#852) — along with pithead-sync's rigforge leg, which replaces the
# program while preserving state and seeding the prebuilt. Last, the two contracts that decide what
# a bad boot is allowed to do: a boot failing its health gate reboots itself once and only once
# (#1065), and the appliance battery's release gate does not lie about what it ran (#1064).
# Sourced by tests/stack/run.sh.
#
# THIS CUT REORDERED, and that is the part worth knowing about it. When the cut was taken the block
# was not contiguous in run.sh: it was three parts, with the appliance-install and rig-miner source
# stanzas between the first and the second, and the kernel, RAUC, mkbundle and reset sections
# between the second and the third. (That describes run.sh as it stood at the cut; later cuts will
# move those neighbours, which is why it is written in the past tense rather than as a claim about
# the file you are reading today.) The source stanza was placed at the MIDDLE part's former
# position, so that part — the largest, and the one carrying the boot-order contracts — kept its
# exact place in the run. The other two moved: the image-store part later, past the two appliance
# domain files, and the health-gate part earlier, ahead of the kernel/RAUC/mkbundle/reset block.
#
# Why that is safe, argued rather than asserted. The image-store part now runs after the two
# appliance domain files instead of before them. It leaks nothing: every variable it sets and every
# helper function it defines is unset as its own section ends, so those domains cannot inherit
# anything from it, and it reads nothing they assign — both extend $PATH per call site as a command
# prefix rather than replacing this shell's, and neither leaves a name behind that this part names.
# The health-gate and release-gate part now runs before the kernel, RAUC, mkbundle and reset
# sections instead of after them. It reads only $ROOT and $SANDBOX, writes only inside its own
# subdirectory, and shares no name with that block in either direction: nothing there reads what
# this part leaves set, and nothing here reads what that block assigns.
#
# That argument is a coupling analysis, so it was checked against the run rather than trusted: the
# before and after suite logs were compared as an ORDERED sequence of section headers, not only as a
# multiset. A sorted multiset destroys order by definition, a header count cannot see a permutation
# and a log-line total cannot either, so those three instruments would pass a cut that shuffled the
# suite arbitrarily. Any later cut that moves a non-contiguous block owes the same ordered check.
#
# Left behind, deliberately: the host-installer cluster — uninstall keeping the operator's files
# and install.sh's host gate (#77 phase 1), and its download verification failing closed (#868).
# Those read names that no longer have an owner in run.sh: they survive only because a sibling
# domain file happens to build a sandbox earlier in the run, and moving them anywhere before that
# accident is retired would carry the accident along. They belong to the standalone-source sweep
# (#1387), not to this cut.
#
# Re-derivations: none, and nothing needed seeding. $ROOT, $SANDBOX and $HERE come from run.sh's
# harness, as they do for every domain file, along with lib.sh's ok, bad, assert_eq,
# assert_contains, assert_not_contains and assert_rc helpers. Every other name is assigned here.
# Two names read as ambient on a first pass and are not: PODMAN_IMAGE_PRESENT is read only in a
# defaulted expansion, so it is safe under set -u whether or not it is set; and BUILT,
# PITHEAD_EXPECT_COMMIT and expect appear only inside single-quoted bodies written out as a
# generated verify script, where they are that script's names rather than reads in this shell.
# A single-quoted body is not a read — check the quoting before believing a coupling.

echo "== unit: load_baked_images — the archive digest, not the tag, decides a load (#798) =="
# Every build tags its images identically and the engine's storage lives on /data, which
# survives reinstalls and A/B updates — so "does the tag exist" pins a machine to the first
# image it ever loaded. Both boot owners (pithead-boot and the first-boot wizard) run this ONE
# loader; the digest record beside the store is what makes a keep-reinstall or A/B update
# converge on the shipped containers.
WSB=$(mktemp -d)
mkdir -p "$WSB/images" "$WSB/bin"
printf 'v1-archive' >"$WSB/images/dashboard.tar.gz"
cat >"$WSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
  image) [ -e "${PODMAN_IMAGE_PRESENT:-/nonexistent}" ] ;;   # `image exists <ref>`
  load) exit "${PODMAN_LOAD_RC:-0}" ;;
esac
EOF
chmod +x "$WSB/bin/podman"
export PODMAN_LOG="$WSB/podman.log" PITHEAD_IMAGES_DIR="$WSB/images"
lbl() { PITHEAD_ENGINE=podman PATH="$WSB/bin:$PATH" run_sourced "$WSB" load_baked_images "$@"; }
WREC="$WSB/data/.loaded-dashboard.tar.gz.sha"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && ok "first boot loads the archive" ||
    bad "first boot loads the archive" "no load call"
assert_eq "the digest is recorded beside the store" \
    "$(cat "$WREC" 2>/dev/null)" "$(sha_of "$WSB/images/dashboard.tar.gz")"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && bad "an unchanged archive is not reloaded" "loaded again" ||
    ok "an unchanged archive is not reloaded"
printf 'v2-archive-different' >"$WSB/images/dashboard.tar.gz"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a changed archive reloads — the keep-reinstall and A/B update path" ||
    bad "a changed archive reloads" "no load call"
# The wizard names the image it needs: a matching record must not count when the image is gone
# (the record can outlive the storage it describes).
: >"$PODMAN_LOG"
lbl ghcr.io/x/pithead-dashboard:v0 >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a missing required image forces a load despite a matching record" ||
    bad "a missing required image forces a load" "no load call"
# A failed load leaves the old record: the next boot must retry, not skip.
WV2SHA=$(cat "$WREC")
printf 'v3-archive' >"$WSB/images/dashboard.tar.gz"
export PODMAN_LOAD_RC=1
lbl >/dev/null 2>&1
unset PODMAN_LOAD_RC
assert_eq "a failed load records nothing — the next boot retries" "$(cat "$WREC")" "$WV2SHA"
unset PODMAN_LOG PITHEAD_IMAGES_DIR
unset -f lbl sha_of
rm -rf "$WSB"
unset WSB WREC WV2SHA

echo "== unit: load_baked_images — a store damaged by an interrupted write is rebuilt =="
# An unclean reset mid-load (power cut, or the watchdog firing while slow media is written) leaves
# ZERO-LENGTH `lower` files; containers/storage then readlinks the graph root itself and EVERY
# container start fails. The digest record still matches AND the image still exists, so the two
# guards above both pass and the reload was skipped — which is what made the damage permanent and
# left an appliance unable to install from its own stick. A base layer carries no `lower` file at
# all, so a zero-length one is damage, never a legitimate state.
RSB=$(mktemp -d)
mkdir -p "$RSB/images" "$RSB/bin" "$RSB/data"
printf 'archive' >"$RSB/images/dashboard.tar.gz"
cat >"$RSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 0 ;; # the image ALWAYS exists — that is the point of this test
load) exit 0 ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$RSB/bin/podman"
export PODMAN_LOG="$RSB/podman.log" PITHEAD_IMAGES_DIR="$RSB/images" FAKE_GRAPHROOT="$RSB/store"
rbl() { PITHEAD_ENGINE=podman PATH="$RSB/bin:$PATH" run_sourced "$RSB" load_baked_images; }
# A healthy store: the base layer has NO `lower`, the layer above carries a real chain.
mk_store() {
    rm -rf "$RSB/store"
    mkdir -p "$RSB/store/overlay/base/diff" "$RSB/store/overlay/top/diff"
    printf 'l/BASE' >"$RSB/store/overlay/top/lower"
}
mk_store
printf '%s' "$(sha256sum "$RSB/images/dashboard.tar.gz" | cut -d' ' -f1)" >"$RSB/data/.loaded-dashboard.tar.gz.sha"
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay/top" ] &&
    ok "a healthy store is left alone — no needless re-pull" ||
    bad "a healthy store is left alone" "the store was rebuilt"
grep -q "load -i" "$PODMAN_LOG" &&
    bad "a healthy store still honours the digest record" "reloaded anyway" ||
    ok "a healthy store still honours the digest record"

mk_store
: >"$RSB/store/overlay/base/lower" # zero-length: the corruption itself
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay" ] &&
    bad "a damaged store is torn down" "the store survived" ||
    ok "a damaged store is torn down"
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a damaged store reloads the archive despite a matching record" ||
    bad "a damaged store reloads the archive" "no load call"
unset PODMAN_LOG PITHEAD_IMAGES_DIR FAKE_GRAPHROOT
unset -f rbl mk_store
rm -rf "$RSB"
unset RSB

echo "== unit: load_baked_images — a slow load narrates itself, a fast one stays quiet =="
# `podman load` prints nothing a console sees and runs for MINUTES on USB media (3m47s measured
# on the bench) behind a line promising "a minute or two" — so a working box looked hung, twice.
# A rising elapsed count is what tells slow apart from stuck. The load stays in the FOREGROUND
# and the heartbeat is the background job: polling a backgrounded load with `kill -0` would make
# a fast load pay a full sleep, because a finished-but-unwaited child still answers.
HSB=$(mktemp -d)
mkdir -p "$HSB/images" "$HSB/bin" "$HSB/data"
printf 'archive' >"$HSB/images/dashboard.tar.gz"
cat >"$HSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 1 ;;
load) sleep "${FAKE_LOAD_SECS:-0}" ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$HSB/bin/podman"
export PITHEAD_IMAGES_DIR="$HSB/images" FAKE_GRAPHROOT="" PITHEAD_LOAD_HEARTBEAT_SECS=1
hbl() { PITHEAD_ENGINE=podman PATH="$HSB/bin:$PATH" run_sourced "$HSB" load_baked_images 2>&1; }

export FAKE_LOAD_SECS=3
hout=$(hbl)
assert_contains "a slow load reports it is still working" "$hout" "still loading"
assert_contains "the heartbeat carries elapsed seconds" "$hout" "elapsed"

rm -f "$HSB/data/.loaded-dashboard.tar.gz.sha"
export FAKE_LOAD_SECS=0
hstart=$(date +%s)
hout=$(hbl)
hlen=$(($(date +%s) - hstart))
grep -q "still loading" <<<"$hout" &&
    bad "a fast load stays quiet" "heartbeat fired anyway" ||
    ok "a fast load stays quiet — no heartbeat for work already done"
# Assert the bound rather than printing the $(date +%s) measurement in the PASS text: a real
# elapsed reading varies run to run (seen as (1s) vs (2s), same PASS both times), which weakens the
# domain-split multiset diff that proves a move changed nothing (#1325). The measured value still
# reaches the failure detail line below, where it isn't part of that proof.
[ "$hlen" -lt 3 ] &&
    ok "a fast load does not wait on the heartbeat interval" ||
    bad "a fast load returns promptly" "took ${hlen}s"
unset PITHEAD_IMAGES_DIR FAKE_GRAPHROOT PITHEAD_LOAD_HEARTBEAT_SECS FAKE_LOAD_SECS
unset -f hbl
rm -rf "$HSB"
unset HSB hout hstart hlen

echo "== unit: pithead-boot wiring — the miner leg rides AFTER the slot commit =="
# Ordering is the contract: the stack serving is the product's health and gates the A/B commit;
# the miner is a passenger that needs the stratum listening and must never delay the commit.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
mg_line=$(grep -n "mark-good" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
lm_line=$(grep -n "pithead local-miner" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$mg_line" ] && [ -n "$lm_line" ] && [ "$lm_line" -gt "$mg_line" ]; then
    ok "pithead-boot runs 'pithead local-miner' after the health-gated commit"
else
    bad "pithead-boot runs 'pithead local-miner' after the health-gated commit" \
        "mark-good@${mg_line:-none} local-miner@${lm_line:-none}"
fi
# A hung miner setup must not wedge the boot unit either — TimeoutStartSec=infinity on
# pithead-boot means || true alone cannot save it; the leg needs its own bounded clock.
grep -qE "timeout [0-9]+ \./pithead local-miner" "$BOOTSCRIPT" &&
    ok "the miner leg runs under its own timeout (boot unit has no clock of its own)" ||
    bad "the miner leg runs under its own timeout (boot unit has no clock of its own)" \
        "no 'timeout N ./pithead local-miner' in pithead-boot"

# The rig fork (#797 R4): a rig has no stack, so the role branch must come BEFORE the loader and
# must never reach render/up. It still commits its own slot — one image, one update pipeline.
rig_line=$(grep -n '^if .*machine-role' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
li_line=$(grep -n 'pithead load-images' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$rig_line" ] && [ -n "$li_line" ] && [ "$rig_line" -lt "$li_line" ]; then
    ok "the role fork precedes the container-image loader (a rig loads none)"
else
    bad "the role fork precedes the container-image loader (a rig loads none)" \
        "role@${rig_line:-none} load-images@${li_line:-none}"
fi
# A coordinator has no marker, and reading a file that is not there is a REDIRECTION failure the
# shell reports itself — `2>/dev/null` on the inner command cannot reach it. Harmless to control
# flow, but it would print "No such file or directory" into the journal of every coordinator
# boot. Existence has to be tested before the read.
grep -q '\[ -f machine-role \]' <(sed -n "${rig_line:-1}p" "$BOOTSCRIPT") &&
    ok "the marker is tested for existence before it is read (no error on every coordinator boot)" ||
    bad "the marker is tested for existence before it is read (no error on every coordinator boot)" \
        "$(sed -n "${rig_line:-1}p" "$BOOTSCRIPT")"
rig_branch=$(sed -n "${rig_line:-1},/^fi\$/p" "$BOOTSCRIPT")
grep -qE '\./pithead (up|render|load-images)' <<<"$rig_branch" &&
    bad "the rig branch starts nothing container-shaped" "it calls the stack's own commands" ||
    ok "the rig branch starts nothing container-shaped"
grep -q 'mark-good' <<<"$rig_branch" &&
    ok "a rig commits its A/B slot exactly like a coordinator" ||
    bad "a rig commits its A/B slot exactly like a coordinator" "no mark-good in the rig branch"
# The units are the other half of the fork: without the triggering condition a rig never runs
# the boot unit, and without the firstboot exclusion it re-runs the WIZARD every boot.
BOOTUNIT="$ROOT/os/overlay/pithead-boot.service"
FBUNIT="$ROOT/os/overlay/pithead-firstboot.service"
grep -q '^ConditionPathExists=|/data/pithead/machine-role' "$BOOTUNIT" &&
    grep -q '^ConditionPathExists=|/data/pithead/config.json' "$BOOTUNIT" &&
    ok "the boot unit triggers on either shape of provisioned (config.json or the role marker)" ||
    bad "the boot unit triggers on either shape of provisioned (config.json or the role marker)" \
        "$(grep -c '^ConditionPathExists=|' "$BOOTUNIT") triggering conditions"
grep -q '^ConditionPathExists=!/data/pithead/machine-role' "$FBUNIT" &&
    ok "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" ||
    bad "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" "missing"
# The marker, not rig.json: a fleet stick writes a rig's ANSWERS in flight while installing one
# onto a disk, and must stay an installer through it — only an ACCEPTED role writes the marker.
grep -q 'rig\.json' <(grep -h '^ConditionPathExists=' "$BOOTUNIT" "$FBUNIT") &&
    bad "neither unit keys on the in-flight rig.json (a stick would stop being an installer)" "it does" ||
    ok "neither unit keys on the in-flight rig.json (a stick stays an installer)"
unset BOOTSCRIPT BOOTUNIT FBUNIT mg_line lm_line rig_line li_line rig_branch

echo "== unit: the A/B commit gate consumes doctor --json, not just the curl (#852) =="
# The gate that used to be a bare curl to https://localhost/ committed any slot whose dashboard
# answered — even one whose mining services had crashed. The fix pairs the curl with doctor's
# exit code. Assert the wiring: both signals gate the same mark-good, curl first (cheap).
# BOTH signals must gate mark-good (#852): a slot whose dashboard answers but whose mining
# containers have crashed must NOT commit. This was a grep of the boot script until #1140, and the
# doctor half of that grep matched the file's own HEADER COMMENT — it stayed green with the doctor
# call deleted from the commit condition outright. The pairing now lives in gate_ready and is
# driven here with a stubbed `pithead`, so deleting either half goes red.
# Mutation run: drop the doctor call from gate_ready -> "a crashed stack does not commit" goes red;
# drop the gate_answer_is_dashboard call -> "the default vhost does not commit" goes red.
GR="$SANDBOX/gate-ready"
mkdir -p "$GR"
gr_run() { # <doctor-exit> <code> <size> -> ready|held
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"$GR/pithead"
    chmod +x "$GR/pithead"
    (
        cd "$GR" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$GR/doctor.json"
        gate_ready "$2" "$3" && echo ready || echo held
    )
}
assert_eq "dashboard serving AND doctor clean -> commit" "$(gr_run 0 200 4096)" "ready"
# #852 itself: the mining-dead-but-serving slot a curl-only gate used to mark-good.
assert_eq "a crashed stack does not commit, however well the dashboard answers" "$(gr_run 1 200 4096)" "held"
# #1140 itself: Caddy's empty default vhost must not open the door to the doctor run either.
assert_eq "the default vhost does not commit, even with doctor clean" "$(gr_run 0 200 0)" "held"
assert_eq "nothing answering does not commit" "$(gr_run 0 000 0)" "held"
assert_eq "a locked dashboard (401) with doctor clean -> commit" "$(gr_run 0 401 0)" "ready"
unset -f gr_run
unset GR

echo "== unit: the boot health probe asks the dashboard's own site, and can tell it apart (#1140) =="
# The probe used to dial https://localhost/ and accept any status but 000, on the stated belief
# that localhost is always a listed site. generate_caddyfile only adds localhost while
# dashboard.host is UNSET — pin the host and the probe reached Caddy's EMPTY DEFAULT VHOST, which
# answers 200 with no body. On the gate that decides whether an A/B update lives, and that #1065
# reboots on, "Caddy is running" was passing as "the dashboard serves".
# Two halves, both driven here: ask the right site, and recognise the right answer.
GU="$SANDBOX/gateurl"
mkdir -p "$GU"
gu_run() { # <env-body> -> "scheme|host|port"
    printf '%s\n' "$1" >"$GU/.env"
    (
        cd "$GU" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_url
    )
}
# THE #1140 CASE: a pinned dashboard.host. The site list holds that name and NOT localhost, so the
# probe has to carry it or it is talking to the default vhost.
assert_eq "a pinned host is what the probe asks for" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true')" "https|panel.example|443"
# Unpinned: HOST_IP is whatever resolve_dashboard_host chose, and it is still the first site.
assert_eq "an unpinned host still comes from the render, not a literal" \
    "$(gu_run 'HOST_IP=pithead.local
DASHBOARD_SECURE=true')" "https|pithead.local|443"
assert_eq "dashboard.secure:false -> the site is http, so the probe is too" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=false')" "http|panel.example|80"
assert_eq "a custom host port is honoured" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true
HOST_PORT=8443')" "https|panel.example|8443"
# Fail SAFE, not closed: an unreadable .env must not make this gate a permanent RED, because after
# #1065 a gate that never passes reboots a healthy box. Falling back to localhost is the old
# behaviour, and gate_answer_is_dashboard below still refuses to call the default vhost a success.
assert_eq "an .env with no HOST_IP falls back rather than dialling nothing" \
    "$(gu_run 'DASHBOARD_SECURE=true')" "https|localhost|443"
unset -f gu_run
unset GU

gad() { # <code> <size> -> accept|reject
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_answer_is_dashboard "$1" "$2" && echo accept || echo reject
    )
}
# The whole point: Caddy's empty default vhost answers 200 with a zero-length body. That is the
# answer #1140 was accepting as a healthy dashboard.
assert_eq "200 with an empty body is the default vhost -> REJECT" "$(gad 200 0)" "reject"
assert_eq "200 with a real page is the dashboard -> accept" "$(gad 200 4096)" "accept"
# Auth on: the login's 401 has no body of its own, so size alone would reject a healthy locked box.
assert_eq "401 (a healthy, locked dashboard) -> accept" "$(gad 401 0)" "accept"
# Auth OFF is supported — an empty dashboard password is the documented default — so the box that
# answers 200 with a page must pass. That is why this is not a 401 check.
assert_eq "no connection at all -> reject" "$(gad 000 0)" "reject"
assert_eq "an empty code -> reject" "$(gad '' 0)" "reject"
assert_eq "a 502 from a dead upstream -> reject" "$(gad 502 0)" "reject"
assert_eq "a redirect carrying a body -> accept" "$(gad 308 120)" "accept"
unset -f gad

# dashboard.host is validated as "a hostname or IP address" and explicitly allows colons, so HOST_IP
# can be an IPv6 literal. curl will not take one in --resolve — it rejects the WHOLE option with
# "Couldn't parse CURLOPT_RESOLVE entry" — and an unbracketed literal in the URL reads the port as
# part of the address. Either way the request fails, the gate never passes, and #1065 reboots a
# healthy box: a false RED on this gate is as bad as the false GREEN this issue is about. Measured
# against curl 8.7 before writing these.
# Mutation run: drop the *:* arm of gate_target_url -> the bracketing assertion goes red; make
# gate_resolve_spec answer for every host -> the two literal assertions go red.
# NOT run_sourced: that sources `pithead`, and these live in the boot overlay. (An assert_eq
# expecting "" would pass vacuously against a function that was never defined, so the non-empty
# assertions below are what prove the source landed.)
boot_fn() { # <function> <args...>
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        "$@"
    )
}
gtu() { boot_fn gate_target_url "$@"; }
grs() { boot_fn gate_resolve_spec "$@"; }
assert_eq "a name goes in the URL as-is" "$(gtu https panel.example 443)" "https://panel.example:443/"
assert_eq "an IPv6 literal is bracketed, or the port joins the address" \
    "$(gtu https 2001:db8::1 443)" "https://[2001:db8::1]:443/"
assert_eq "an IPv4 literal needs no brackets" "$(gtu http 192.0.2.5 80)" "http://192.0.2.5:80/"
# --resolve is for names only. It is what keeps a name's dial on loopback without the box having to
# resolve its own mDNS name; a literal is already an address and needs no lookup.
assert_eq "a name gets a --resolve spec pointing at loopback" \
    "$(grs panel.example 443)" "panel.example:443:127.0.0.1"
assert_eq "an IPv6 literal gets NO --resolve (curl cannot parse one)" "$(grs 2001:db8::1 443)" ""
assert_eq "an IPv4 literal gets no --resolve either" "$(grs 192.0.2.5 80)" ""
unset -f gtu grs boot_fn

echo "== unit: os_update_rollback_verdict — the rolled_back verdict, provable without a KVM boot (#1051) =="
# A dashboard-driven install leaves data/os-update/in-flight.json naming the version the machine
# was headed to. If THIS boot's VERSION disagrees, the bootloader already fell back — the update
# failed its health gate, and the verdict belongs in the state file now. Before #1051 this was
# inline code that only ran when pithead-boot was EXECUTED, never sourced, so no tier could ever
# drive it with a fixture — genuinely untested, at every tier, despite being promised in two
# operator-facing docs. It is pure file logic (an in-flight flag, a VERSION file, one jq call), so
# nothing here needs real firmware or a real A/B updater to prove; #1051 pulled it into a function
# for exactly that reason.
# Mutation run: flip the != to = in os_update_rollback_verdict's version check -> both assertions
# below invert (a real fallback stays silent, a real landing wrongly claims rollback).
ORV="$SANDBOX/os-rollback-verdict"
orv_run() { # <running-version> [inflight-to] -> "<outcome> <in-flight-consumed>"
    rm -rf "$ORV"
    mkdir -p "$ORV/data/os-update" "$ORV/data/control/results"
    printf '%s\n' "$1" >"$ORV/VERSION"
    # "consumed" has to mean the flag EXISTED and the function REMOVED it — checking only
    # post-call existence conflates that with "there was never a flag to remove", so the
    # no-flag case wrongly read back as consumed. had_flag pins the before state.
    local had_flag=no
    if [ -n "${2:-}" ]; then
        printf '{"from":"1.0.0","to":"%s"}\n' "$2" >"$ORV/data/os-update/in-flight.json"
        had_flag=yes
    fi
    (
        cd "$ORV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_rollback_verdict >/dev/null
    )
    local outcome consumed=no
    outcome=$(jq -r '.verdict.outcome // "none"' "$ORV/data/control/results/os-update-state.json" 2>/dev/null)
    [ "$had_flag" = yes ] && [ ! -f "$ORV/data/os-update/in-flight.json" ] && consumed=yes
    printf '%s %s' "${outcome:-none}" "$consumed"
}
assert_eq "a fallback boot (running the OLD version) writes rolled_back and consumes the flag" \
    "$(orv_run 1.2.3 1.2.4)" "rolled_back yes"
assert_eq "a landed boot (running matches the target) writes nothing here — the commit gate's success half owns it" \
    "$(orv_run 1.2.4 1.2.4)" "none no"
assert_eq "no in-flight flag at all is a no-op" "$(orv_run 1.2.3)" "none no"
unset -f orv_run
unset ORV

echo "== unit: revenue_container_verdict — commit-gate honesty, syncing vs crashed (#852) =="
# The pure classifier behind check_revenue_containers, so the commit gate's central judgement is
# tested without a running stack. Two rules it must hold:
#   1. a crashed/unhealthy CHAIN node (monerod/tari/wallets) is a fault — the slot must not commit;
#   2. a DOWN sync-gated miner (p2pool/xmrig-proxy) is the deliberate #35 hold, not a fault — so a
#      days-long initial sync still commits. Only a running-but-unhealthy miner is a fault.
rcv() { run_sourced "$SANDBOX" revenue_container_verdict "$@"; }
# Chain nodes: healthy commits, everything short of running-and-healthy holds.
assert_eq "monerod up+healthy -> ok" "$(rcv monerod running 'Up 5 minutes (healthy)')" "ok"
assert_contains "monerod exited -> fail" "$(rcv monerod exited 'Exited (0) 1 minute ago')" "fail:monerod"
assert_contains "monerod running+unhealthy -> fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)')" "fail:monerod"
assert_contains "monerod still starting -> fail (loop retries, never commits early)" "$(rcv monerod running 'Up 8 seconds (starting)')" "fail:monerod"
assert_eq "tari up+healthy -> ok" "$(rcv tari running 'Up 3 minutes (healthy)')" "ok"
assert_contains "wallet-rpc down -> fail (chain-side must be up)" "$(rcv wallet-rpc created 'Created')" "fail:wallet-rpc"
# Sync-gated miners: down is the #35 hold (ok); only running-but-unhealthy is a fault.
assert_eq "p2pool exited (sync hold) -> ok" "$(rcv p2pool exited 'Exited (0) 4 minutes ago')" "ok"
assert_eq "p2pool created (never started, held) -> ok" "$(rcv p2pool created 'Created')" "ok"
assert_eq "p2pool up+healthy -> ok" "$(rcv p2pool running 'Up 6 minutes (healthy)')" "ok"
assert_contains "p2pool running+unhealthy -> fail" "$(rcv p2pool running 'Up 30 seconds (unhealthy)')" "fail:p2pool"
assert_eq "xmrig-proxy down (sync hold) -> ok" "$(rcv xmrig-proxy exited 'Exited (0) 4 minutes ago')" "ok"
# Non-revenue containers are out of scope — the rest of doctor covers them.
assert_eq "caddy (not revenue) -> ok" "$(rcv caddy running 'Up 5 minutes')" "ok"
assert_eq "dashboard (not revenue) -> ok" "$(rcv dashboard running 'Up 5 minutes (healthy)')" "ok"
# The migration hold (#851): with chain_hold=1 a chain node is judged by the miners' rule — the
# boot path is deliberately withholding it, so down is expected and the commit must not deadlock
# on the very hold it gates. A RUNNING-but-unhealthy chain node is still a fault.
assert_eq "monerod down under the migration hold -> ok" "$(rcv monerod exited 'Exited (0) 1 minute ago' 1)" "ok"
assert_eq "tari never created under the migration hold -> ok" "$(rcv tari created 'Created' 1)" "ok"
assert_eq "wallet-rpc down under the migration hold -> ok" "$(rcv wallet-rpc exited 'Exited (0) 2 minutes ago' 1)" "ok"
assert_contains "monerod running+unhealthy under the hold -> still fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)' 1)" "fail:monerod"
assert_eq "monerod up+healthy under the hold -> ok (an early manual start is not a fault)" "$(rcv monerod running 'Up 5 minutes (healthy)' 1)" "ok"
assert_contains "the hold changes nothing for a miner" "$(rcv p2pool running 'Up 30 seconds (unhealthy)' 1)" "fail:p2pool"
unset -f rcv

echo "== unit: pithead-sync's rigforge leg — program replaced, state preserved, prebuilt seeded =="
# The baked tree is program; config.json (pithead-rendered) and the data/ workspace (the XMRig
# build cache) are state. The prebuilt binary seeds the workspace so the appliance never needs
# RigForge's clone path — github over clearnet, unreachable from a Tor-only box.
SYNCSCRIPT="$ROOT/os/overlay/pithead-sync"
SSB=$(mktemp -d)
mkdir -p "$SSB/opt-pithead" "$SSB/opt-rigforge/util" "$SSB/opt-rigforge/prebuilt/xmrig/build"
for f in pithead pithead-completion.bash VERSION docker-compose.yml \
    config.reference.json config.core-keys.json config.minimal.json cosign.pub; do
    printf 'pithead-program' >"$SSB/opt-pithead/$f"
done
printf 'program-v2' >"$SSB/opt-rigforge/rigforge.sh"
chmod +x "$SSB/opt-rigforge/rigforge.sh"
printf 'helper' >"$SSB/opt-rigforge/util/proposed-grub.sh"
printf 'bin-v2' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'commit-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'sha-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-sha256"
run_sync() {
    PITHEAD_SYNC_SRC="$SSB/opt-pithead" PITHEAD_SYNC_DST="$SSB/data/pithead" \
        PITHEAD_SYNC_RIGFORGE_SRC="$SSB/opt-rigforge" PITHEAD_SYNC_RIGFORGE_DST="$SSB/data/rigforge" \
        bash "$SYNCSCRIPT"
}
run_sync >/dev/null 2>&1
assert_rc "sync runs clean" "$?" "0"
[ -x "$SSB/data/rigforge/rigforge.sh" ] && ok "rigforge program delivered beside pithead's" ||
    bad "rigforge program delivered beside pithead's" "missing"
assert_eq "prebuilt seeded into the workspace where 'already built' finds it" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig" 2>/dev/null)" "bin-v2"
assert_eq "the commit marker rides with the seed" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/.rigforge-commit" 2>/dev/null)" "commit-B"
[ -e "$SSB/data/rigforge/prebuilt" ] && bad "prebuilt/ is a seed, never a synced tree" "synced" ||
    ok "prebuilt/ is a seed, never a synced tree"
# State survives a re-run: the rendered config and a native rebuild of the SAME pin stay put.
printf '{"pools":[{"url":"127.0.0.1:3333"}]}' >"$SSB/data/rigforge/config.json"
printf 'native-rebuild' >"$SSB/data/rigforge/data/worker/xmrig/build/xmrig"
run_sync >/dev/null 2>&1
assert_eq "config.json (state) survives the resync" \
    "$(cat "$SSB/data/rigforge/config.json")" '{"pools":[{"url":"127.0.0.1:3333"}]}'
assert_eq "a same-pin native rebuild is left alone" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "native-rebuild"
# A new pin arrives with a new image AND its new prebuilt: the cached build is replaced, so the
# on-box clone path never needs to run.
printf 'commit-C\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'bin-v3' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'program-v3' >"$SSB/opt-rigforge/rigforge.sh"
run_sync >/dev/null 2>&1
assert_eq "a new pin replaces the cached build with the new prebuilt" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "bin-v3"
assert_eq "program files are replaced wholesale" "$(cat "$SSB/data/rigforge/rigforge.sh")" "program-v3"
# An image without the bake (downgrade, older layout): the leg skips cleanly.
rm -rf "$SSB/opt-rigforge"
run_sync >/dev/null 2>&1
assert_rc "no baked tree -> the leg is skipped, sync still clean" "$?" "0"
unset -f run_sync
rm -rf "$SSB"
unset SSB SYNCSCRIPT

echo "== unit: a boot that fails its health gate reboots itself, once (#1065) =="
# The A/B design's headline promise is that a bad update reverts itself, and for the likeliest bad
# update — one that boots cleanly with a dead stack — it did not: pithead-boot left the slot
# uncommitted and exited, and the fallback is a GRUB decision GRUB does not get to make until
# something reboots. So the box sat on the broken slot with the stack down until a human pulled the
# power, while two operator docs promised otherwise.
#
# Bounded is the load-bearing half. A fault on /data survives the fallback, so both slots fail the
# same way; a machine that reboot-loops can never be looked at. And if the counter cannot be
# written the machine must NOT reboot — an unbounded loop is the one outcome worse than a stranded
# box, so the failure to persist has to fail SAFE, not open.
#
# MUTATION PROOF: drop the `[ "$n" -ge 2 ]` bound and the second-failure assertion goes red; make
# the unwritable-counter branch reboot anyway and the fail-safe assertion goes red; drop the
# rm in boot_gate_passed and the cleared-on-success assertion goes red.
BG="$SANDBOX/boot-gate"
mkdir -p "$BG"
# shellcheck disable=SC1090  # overlay path is dynamic by design
bg_run() { # <cwd> — one fail_boot in a sandbox, printing "<reboots> <counter> <stderr>"
    (
        cd "$1" 2>/dev/null || exit 1
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
    )
}
rm -f "$BG"/rebooted.*
bg_out1=$(bg_run "$BG")
bg_rebooted1=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the first failed health gate reboots the machine" "$bg_rebooted1" "1"
assert_eq "and records the attempt on /data" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "1"
assert_contains "saying why, on the console" "$bg_out1" "falls back to the previous slot"

rm -f "$BG"/rebooted.*
bg_out2=$(bg_run "$BG")
bg_rebooted2=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the fallback slot failing the same way does NOT reboot again" "$bg_rebooted2" "0"
assert_eq "the attempt is still counted" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "2"
assert_contains "and the console says the fault is not the slot" "$bg_out2" "the fault is not the slot"

# A healthy boot clears the counter, or one transient failure months ago would spend the machine's
# single rollback attempt on the update that actually needs it.
(
    cd "$BG" || exit 1
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    boot_gate_passed
)
assert_eq "a boot that commits clears the counter" "$([ -f "$BG/.boot-gate-failures" ] && echo present || echo gone)" "gone"

# Unwritable counter: the cwd is deleted out from under it, which makes the relative write fail for
# root too — a chmod would not, and this suite runs as both.
BGX="$SANDBOX/boot-gate-unwritable"
mkdir -p "$BGX"
rm -f "$BG"/rebooted.*
bg_out3=$(
    cd "$BGX" && rmdir "$BGX"
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
)
assert_eq "a counter it cannot write means it does NOT reboot" "$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_contains "and it says a reboot it cannot count is a reboot loop" "$bg_out3" "a reboot it cannot count is a reboot loop"
rm -f "$BG"/rebooted.*

# Every exit that leaves the slot uncommitted goes through the helper — a bare `exit 1` on any of
# them is the original defect back on that path alone. The rig leg's two and the coordinator's
# render, up and health gate are all of them.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
bg_bare=$(grep -cE '^[[:space:]]*(\./pithead (render|up)|timeout 1800 \./pithead local-miner).*\|\| exit 1' "$BOOTSCRIPT" || true)
assert_eq "no boot-failure path exits without arming the fallback" "$bg_bare" "0"
echo "== unit: the appliance battery's release gate does not lie about what it ran (#1064) =="
# Harness wiring, asserted here because the harness itself only runs on the KVM bench. Both halves
# are the same defect: a gate that reports success without having run. `--phase all` executed five
# of eight phases while the release checklist said it ran everything, so every cut skipped the
# power cuts, the corrupt-bundle refusal, the factory reset, the wedged-/data recovery and the
# media channel; and verify-image's stale-artifact comparison was switched off in the ONE caller
# that is not a human typing a command. MUTATION PROOF: drop a phase from the `all` arm, or drop
# the PITHEAD_EXPECT_COMMIT prefix, and the matching assertion goes red.
OSH="$(cat "$ROOT/tests/os/run.sh")"
osh_all="$(printf '%s' "$OSH" | sed -n '/^all)/,/^    ;;/p')"
for ph in boot update install provision rig media fault reset; do
    assert_contains "--phase all runs phase_$ph" "$osh_all" "phase_$ph"
done
assert_contains "the battery's own build pins the commit verify-image checks against" "$OSH" \
    'PITHEAD_EXPECT_COMMIT="$expect" tests/os/verify-image.sh'
VIS="$(cat "$ROOT/tests/os/verify-image.sh")"
# Wiring the guard on is only half of it: the two ends have to speak the same shape. build-image.sh
# stamps `git rev-parse HEAD` — the FULL sha — and the harness first handed over `--short`, so the
# equality check failed EVERY harness build. A guard that refuses everything is the same lie as one
# that refuses nothing, pointed the other way. Bench-proven on the KVM image; asserted here because
# verify-image needs a loop device and root, which tier-1 has neither of.
assert_contains "the harness hands over the full sha build-image.sh stamps" "$OSH" \
    'expect="$(git rev-parse HEAD 2>/dev/null || true)"'
assert_not_contains "the harness does not hand over a short sha the stamp never equals" "$OSH" \
    'rev-parse --short HEAD'
assert_contains "the expected-commit check matches on a prefix, so a short sha still verifies" "$VIS" \
    'case "$BUILT" in "$PITHEAD_EXPECT_COMMIT"*)'
assert_contains "a skipped check is counted, not silent" "$VIS" "SKIP=\$((SKIP + 1))"
assert_contains "skipped checks refuse to report a verified image" "$VIS" "were SKIPPED, so this is not a verified image"
unset OSH osh_all VIS
