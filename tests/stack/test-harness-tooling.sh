# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Repo-tooling self-tests (#1105 Phase 1 domain: harness core). Sourced by tests/stack/run.sh
# after lib.sh — the harness (ok/bad/assert_*, SANDBOX) is already loaded.
echo "== unit: lint-docs-voice self-test (#1441) =="
# An empty `git ls-files '*.md'` enumeration (broken glob, over-matching filter, run outside a
# checkout) used to read as a clean scan — rc 0 either way. Its --self-test runs the real script
# end to end in a throwaway repo with no tracked .md files and fails unless it refuses instead.
bash "$ROOT/scripts/lint-docs-voice.sh" --self-test >/dev/null 2>&1
assert_rc "docs-voice guard self-test passes" "$?" "0"

# The assertion above only proves anything if the script still RECOGNISES --self-test: a revert
# that drops the flag along with the guard (i.e. exactly the pre-#1441 script) makes the flag a
# silent no-op — it just runs the ordinary scan against this real checkout, which has real
# tracked docs and no banned words, and exits 0 regardless of the missing guard. That reverted
# script would pass the assertion above. So drive the guard directly too, with no dependence on
# the script knowing its own flag: an empty-enumeration repo must make the UNFLAGGED script
# refuse, not pass.
empty_repo="$SANDBOX/lint-docs-voice-empty"
mkdir -p "$empty_repo"
git init -q "$empty_repo" >/dev/null
out=$(cd "$empty_repo" && bash "$ROOT/scripts/lint-docs-voice.sh" 2>&1) && rc=0 || rc=$?
assert_rc "docs-voice guard refuses an empty prose-doc enumeration directly" "$rc" "1"
assert_contains "docs-voice refusal names the empty enumeration" "$out" "prose-doc enumeration returned zero files"

echo "== unit: lint-operator-strings self-test (#755) =="
# The operator-strings guard's frontend scanner is non-trivial awk (comment-stripping + CSS-hex-colour
# skip); a silent break would make it stop catching leaks. Its --self-test drives fixtures through the
# real scanners and fails if a planted #NNN is missed or a hex colour/comment is wrongly flagged.
bash "$ROOT/scripts/lint-operator-strings.sh" --self-test >/dev/null 2>&1
assert_rc "operator-strings guard self-test passes" "$?" "0"

echo "== unit: pin-watch self-test (#1128) =="
# The watcher's whole product is the COMPARISON: our pins do not spell versions the way upstream
# tags them (`caddy:2.11.4` vs `v2.11.4`, `minotari_node:v5.3.1-mainnet` vs `v5.6.0`), so a plain
# string compare reports two components stale every week for ever and the report gets muted — as
# useless as the scheduled workflow that lived on a non-default branch and never ran at all. Its
# --self-test drives the normalisation over the real pin spellings and drives both lookup failure
# paths, because an upstream lookup that could not run must never read as "current".
bash "$ROOT/scripts/pin-watch.sh" --self-test >/dev/null 2>&1
assert_rc "pin-watch self-test passes" "$?" "0"

echo "== unit: resolve-pins self-test (#1137) =="
# pin-watch.sh above compares VERSIONS; it does not ask whether a pinned tag@sha256 digest still
# matches what its registry serves for that tag. This is the check that does, and its --self-test
# drives the exact half-done bump #1137 is about (tag moved, old digest left in the file) red.
bash "$ROOT/scripts/resolve-pins.sh" --self-test >/dev/null 2>&1
assert_rc "resolve-pins self-test passes" "$?" "0"

echo "== unit: verify-healthcheck-scripts self-test (#1098) =="
# #1098: docker-compose.yml named a healthcheck script (xmrig-proxy-healthcheck.sh) that the
# pinned appliance images predated — the container reported unhealthy forever with nothing
# actually broken. This is the narrower, permanent guard: does each service's OWN Dockerfile
# actually place a file where compose's healthcheck looks for it. The self-test drives the
# parsers (WORKDIR resolution, COPY --from=, multi-source directory COPYs) against fixtures and
# reproduces the issue's own named mutation end to end: rename the script in a Dockerfile without
# touching compose, and the check must go red.
bash "$ROOT/scripts/verify-healthcheck-scripts.sh" --self-test >/dev/null 2>&1
assert_rc "verify-healthcheck-scripts self-test passes" "$?" "0"

echo "== unit: verify-healthcheck-scripts against the real tree (#1098) =="
# The self-test above proves the parsers; this proves the CURRENT docker-compose.yml and build/*
# Dockerfiles actually agree right now — the same real-tree pass release.sh and CI both get, so a
# healthcheck rename that forgets the compose side (or vice versa) fails here before it ever
# reaches an appliance.
bash "$ROOT/scripts/verify-healthcheck-scripts.sh" >/dev/null 2>&1
assert_rc "every real healthcheck script exists where its own Dockerfile promises (#1098)" "$?" "0"

echo "== unit: patch-coverage overlap self-test (#1000) =="
# diff-cover exits 0 on "No lines with coverage information" — a vacuous pass. The wrapper's
# overlap check is what turns that into a loud not-applicable pass or a real failure; its
# --self-test drives fixtures through both branches plus the file-present quiet pass.
bash "$ROOT/scripts/patch-coverage.sh" --self-test >/dev/null 2>&1
assert_rc "patch-coverage wrapper self-test passes" "$?" "0"

echo "== unit: shipped-image sweep report self-test (#1313) =="
# The weekly sweep of the PUBLISHED images renders its tracking-issue body with this script, and
# its whole job is refusing to call an image clean when it was never scanned. Every refusal —
# a missing leg, an unparseable report, an artifact that is a tag rather than a digest — is
# driven through fixtures here, with no network, no docker and no gh.
bash "$ROOT/scripts/shipped-image-sweep-report.sh" --self-test >/dev/null 2>&1
assert_rc "shipped-image sweep report self-test passes" "$?" "0"

echo "== unit: #1059 watch-report discrimination =="
# The restore leg's config.json watcher reports on PASSING runs, so its SILENCE is the load-bearing
# output — and five ways of collecting no evidence (guest unreadable, watcher never started,
# watcher killed mid-window, watch window expired) must not print what a genuinely clean window
# prints. Its --self-test drives all six outcomes, asserts each on the one sentence only it writes
# AND on the absence of the others, and runs the shipped watcher body for real against a sandbox
# file so the watcher and the report are proven against each other rather than each against an
# assumption. Lives in tests/os/ (appliance lane); driven here because tier 1 is the lowest tier
# that proves it and it needs no KVM.
bash "$ROOT/tests/os/failure-evidence.sh" --self-test >/dev/null 2>&1
assert_rc "#1059 watch-report self-test passes" "$?" "0"

echo "== unit: #1676 version-aging helper self-test =="
# tests/os/run.sh's leg 4 must make the guest claim a version OLDER than the bundle it is about to
# install, and every minor release-prep tip is x.y.0 — the shape the helper used to refuse, which
# reddened the release gate with seven reds for one cause. Its --self-test drives the three
# step-down shapes, the one version with nothing below it, and the malformed inputs it must refuse,
# each aged value checked against an independent ordering. Lives in tests/os/ (appliance lane);
# driven here because tier 1 is the lowest tier that proves it and it needs no KVM.
bash "$ROOT/tests/os/aged-version.sh" --self-test >/dev/null 2>&1
assert_rc "#1676 aged-version self-test passes" "$?" "0"

echo "== unit: #1936 wizard-state-poll self-test =="
# The RC1 battery reddened twice on one word — `no-served-config`, `served wallet: none` — where a
# timeout, a refusal and a non-JSON page all print alike (#1932, #1936). The shared /api/state
# poll now names the status, curl's rc, the read count and the body head; its --self-test drives
# the four shapes under a curl shim and asserts each reason on the exact string the log will
# carry. Lives in tests/os/ (appliance lane); driven here because tier 1 is the lowest tier that
# proves it and it needs no KVM.
bash "$ROOT/tests/os/provision-browser-submit.sh" --self-test >/dev/null 2>&1
assert_rc "#1936 wizard-state-poll self-test passes" "$?" "0"

echo "== unit: tor healthcheck command-dependency self-test (#1372) =="
# The #1098 pair above asks whether a healthcheck script EXISTS where its Dockerfile promises. This
# asks the other half of the same contract: whether build/tor/healthcheck.sh can still RUN on
# nothing but the commands that image ships. #1372 is the case that made the gap visible — the
# Dockerfile installed `xxd` by name for one call site that busybox already served, and nothing in
# CI could see either the need or its removal. Its --self-test drives the script for real with PATH
# stripped to an allowlist of the image's commands, and drops each declared command in turn, because
# a leaking PATH would pass every case on the host's own commands and prove nothing.
bash "$ROOT/build/tor/healthcheck-selftest.sh" --self-test >/dev/null 2>&1
assert_rc "tor healthcheck runs on the commands its own image ships (#1372)" "$?" "0"

echo "== unit: wait_while_alive polls on liveness, not a tick count (#1495) =="
# The #1342 stanza's OLD shape -- a fixed tick*interval budget -- is reproduced here at a scale
# that proves the point in under a second: a holder delayed past a budget it does not owe read as
# a false "the lock is free" under load. Shown against the very shape it replaced, side by side,
# rather than asserted from a description of it.
whwa_flag="$SANDBOX/whwa-ready"
whwa_ready() { [ -e "$whwa_flag" ]; }
whwa_old_wait() { # <pid> <check-fn> <ticks> -- the fixed-budget shape #1495 removed
    local i=0
    while [ "$i" -lt "$3" ]; do
        "$2" && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
rm -f "$whwa_flag"
(
    sleep 0.4
    : >"$whwa_flag"
    sleep 2
) &
whwa_pid=$!
whwa_old_wait "$whwa_pid" whwa_ready 4 # ~0.2s budget: exhausts before the 0.4s delay lands
assert_rc "the fixed-budget shape this replaced gives up on a delayed-but-live holder" "$?" "1"
wait_while_alive "$whwa_pid" whwa_ready
assert_rc "wait_while_alive rides out the same delay because the holder is still alive" "$?" "0"
kill "$whwa_pid" 2>/dev/null
wait "$whwa_pid" 2>/dev/null

# The other half: a holder that exits WITHOUT ever satisfying CHECK must be reported as gone
# immediately, not waited out to whatever budget happens to be generous enough to cover it.
rm -f "$whwa_flag" # the first case's holder left this behind; a stale flag would satisfy CHECK for free
whwa_start="$SECONDS"
(exit 1) &
whwa_pid=$!
wait_while_alive "$whwa_pid" whwa_ready
assert_rc "gives up the moment a holder that never checks in has already died" "$?" "1"
assert_rc "and does so in under a second, not a fixed wait" \
    "$([ "$((SECONDS - whwa_start))" -lt 2 ] && echo 0 || echo 1)" "0"
unset -f whwa_ready whwa_old_wait
rm -f "$whwa_flag"

echo "== unit: every run.sh fragment refuses a direct run (#1657) =="
# A test-*.sh domain file carries no assertion primitives of its own: run one directly and its
# assert_* calls are "command not found" while the file still exits 0 for 21 of the 55 — a domain
# reporting success having executed nothing. test-backup.sh goes further and builds its fixture
# roots in the caller's working tree on the way past, because `cd "" && pwd -P` returns the cwd.
# Enumerating every fragment rather than sampling one is the whole point: the regression this
# guards against is a NEW fragment added without the marker check, and a fixed list would never
# see it. STACK_SUITE is deliberately NOT unset here — lib.sh sets it as a plain assignment and
# never exports it, so a child bash cannot inherit it; if someone ever exports it, every fragment
# stops refusing at once and this row is what says so.
frag_probe="$SANDBOX/fragment-refusal"
mkdir -p "$frag_probe"
frag_bad=""
for frag in "$ROOT"/tests/stack/test-*.sh; do
    frag_out=$(cd "$frag_probe" && bash "$frag" 2>&1) &&
        frag_bad="$frag_bad $(basename "$frag"):exited-0"
    case "$frag_out" in
    *"tests/stack/run.sh"*) ;;
    *) frag_bad="$frag_bad $(basename "$frag"):refusal-does-not-name-run.sh" ;;
    esac
done
assert_eq "every tests/stack/test-*.sh refuses a direct run, naming run.sh" "$frag_bad" ""
# The row above asserts the exit status; this one asserts the consequence that status exists to
# prevent. They are not the same arm: a guard moved below a fixture-building line would still
# refuse, and only this row would notice the files it wrote on the way there.
assert_eq "no fragment writes into the caller's directory before refusing" "$(ls -A "$frag_probe")" ""

echo "== unit: verdict-line determinism — no random/measured value in a PASS line (#1325) =="
# The domain-split multiset proof diffs the sorted verdict lines of two suite runs to show a move
# changed nothing; that proof only holds if a PASSING line reads the same every run. Two did not:
# the ssh-host-keys PASS line embedded ssh-keygen's own random ed25519 fingerprint, and the
# load_baked_images heartbeat PASS line embedded a $(date +%s) measurement (seen as (1s) vs (2s)
# across two runs, same PASS both times). Each domain file runs for real below — a fresh key, a
# fresh timing — and the captured PASS text is asserted to carry neither value. The capture keeps
# only the ✓ line, and the arming row before each check asserts it is there: an empty capture (a
# domain that died before its PASS line, a renamed label, a FAIL on that row) contains neither
# value either, and would read as clean without it.
vd_id_out=$(bash -c 'set -uo pipefail; source "'"$HERE"'/lib.sh" >/dev/null 2>&1; source "'"$HERE"'/test-appliance-identity-boot.sh" 2>&1' | grep "✓.*loadable ed25519 key" | head -1)
assert_contains "the ed25519-key PASS line was captured at all (arming)" "$vd_id_out" "the generated key is a loadable ed25519 key"
assert_not_contains "the ed25519-key PASS line carries no fingerprint bytes" "$vd_id_out" "SHA256:"

vd_hb_out=$(bash -c 'set -uo pipefail; source "'"$HERE"'/lib.sh" >/dev/null 2>&1; source "'"$HERE"'/test-appliance-boot.sh" 2>&1' | grep "✓.*does not wait on the heartbeat interval")
assert_contains "the heartbeat PASS line was captured at all (arming)" "$vd_hb_out" "a fast load does not wait on the heartbeat interval"
case "$vd_hb_out" in
*[0-9]s\)*) bad "the heartbeat PASS line carries no measured elapsed value" "$vd_hb_out" ;;
*) ok "the heartbeat PASS line carries no measured elapsed value" ;;
esac
unset vd_id_out vd_hb_out

echo "== unit: scheduled-run watch self-test (#1377) =="
# The Monday CVE sweep's reader. Its red path CANNOT be exercised live — staging it would mean
# making the default branch's CI genuinely fail — so the fixtures here are the only place the
# failure branch runs at all. They also pin the distinction the watcher exists for: a sweep that
# FAILED is reported and exits 0 (a finding), while a sweep it could not read exits 1 (UNCHECKED).
bash "$ROOT/scripts/scheduled-run-watch.sh" --self-test >/dev/null 2>&1
assert_rc "scheduled-run watch self-test passes" "$?" "0"

echo "== unit: verdict-line determinism — every PASS label, not two named lines (#1740) =="
# The two rows above pin #1709's two nondeterministic PASS lines BY NAME, and nothing looks for a
# third — N grew from one to two by discovery, so the multiset proof still rests on an enumeration
# no instrument can show is complete. A PASS verdict line is exactly `  <glyph> <label>` (lib.sh's
# ok() prints its first argument and nothing else), so a value can only reach one through the
# LABEL. That makes the whole set checkable statically, in one pass, with no sampling — which
# matters twice over. Two samples miss a value that changes only SOMETIMES: #1709's own heartbeat
# line read clean across two samples that happened to land on the same second. And the domains most
# likely to carry a measurement cannot be sampled in isolation at all — test-spool-audit.sh is a
# deliberate consumer of another domain's $C and refuses a standalone source, so there is nothing
# to run twice.
#
# So hold the set of PASS labels that interpolate ANYTHING against a reviewed expectation. Keyed on
# the interpolated NAME, not the label prose: rewording a label is routine and must not red the
# suite, while a genuinely new interpolation must. `bad` is excluded — its label prints only on the
# failure path, which no multiset proof compares.
vd_interp_names() { # <file...> -> "<basename>|<name>", once per distinct interpolated name
    awk '
    {
        stripped = $0
        sub(/^[ \t]+/, "", stripped)
        # Heredoc BODY is data, not code. Without this the fixture written a few lines below —
        # which has to contain an emitter call to be a control at all — is scanned as if it were
        # source, and the sweep reports its name against a file that never emits it. `<<<` is a
        # here-STRING and opens nothing.
        if (hd != "") { if (stripped == hd) hd = ""; next }
        if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/) && $0 !~ /<<</) {
            tag = substr($0, RSTART, RLENGTH)
            sub(/^<<-?[ \t]*/, "", tag)
            gsub(/[\047"]/, "", tag)
            hd = tag
            next
        }
        if (stripped ~ /^#/) next
        if (!match($0, /(^|[^A-Za-z0-9_])(ok|assert_eq|assert_contains|assert_not_contains|assert_rc)[ \t]+"/)) next
        rest = substr($0, RSTART + RLENGTH)
        label = ""
        n = length(rest)
        for (j = 1; j <= n; j++) {
            c = substr(rest, j, 1)
            if (c == "\\") { j++; continue }
            if (c == "\"") break
            label = label c
        }
        f = FILENAME
        sub(/^.*\//, "", f)
        while (match(label, /\$\{?[A-Za-z_][A-Za-z0-9_]*|\$\{?[0-9]+|\$[@*#]|\$\(|`/)) {
            tok = substr(label, RSTART, RLENGTH)
            label = substr(label, RSTART + RLENGTH)
            if (tok == "$(" || tok == "`") { print f "|$(cmd)"; continue }
            gsub(/[${]/, "", tok)
            print f "|" tok
        }
    }
    ' "$@" | sort -u
}
# Every entry below was read at its call site and is a loop variable over a fixed list, a count
# derived from the tree, or a value parsed out of a repo file — the same on every run of a given
# tree. The four that are NOT run-invariant are called out in #1740: test-appliance-os-update.sh's
# RIS/RIJ are absolute paths that differ per WORKTREE, and test-secrets.sh's mem/host_ram_mb come
# from /proc/meminfo MemTotal, so they differ per BOX. Both are stable across two runs in one place,
# which is exactly why sampling never found them.
#
# THE NUMBERED ENTRIES ARE A DIFFERENT CLASS AND CARRY A DIFFERENT PROOF (#1767). A label built from
# a POSITIONAL is a WRAPPER's label: what actually prints is whatever its callers pass, which this
# file cannot see. So the sweep flags the wrapper and the review has to go to the callers. Done
# mechanically — every call of the ELEVEN wrappers, with backslash continuations joined, argument
# extracted by a shell-grammar parser rather than by eye: 73 calls, 72 passing a bare string
# literal, and one passing `${ev}` from test-control-editable-allowlist.sh's loop over 25
# spelled-out event names. That one is a loop variable over a fixed list, so the whole class is
# run-invariant today.
#   * COUNT THE WRAPPERS, NOT THE ROWS. The first pass said "eight wrappers, 55 calls" because it
#     counted ROWS: a row is <file>|<index>, so test-config.sh|2 collapses three wrappers and
#     test-rig-worker.sh|3 collapses three more. Eleven and 73 are the numbers the imperative below
#     is about; auditing eight misses three. The verdict held at the wider scope, the sentence
#     supporting it did not.
#   * `lib.sh|1` is not a call site at all — it is assert_eq/assert_contains/assert_not_contains/
#     assert_rc forwarding their own <label> parameter to ok(). Every label in the suite funnels
#     through it, so it is listed for completeness and says nothing about any one domain.
# WHAT THIS ROW STILL DOES NOT PROVE: it pins the SET of interpolating labels, not the VALUES. A new
# caller handing one of these wrappers a measured value keeps the set identical and the row green —
# the caller audit above is a point-in-time reading, not a standing instrument. Re-run it when a
# wrapper gains callers; that is the residual #1740 could not close and this row does not either.
# The special-parameter class has no live site beyond $@ — no label in tests/stack uses $* or $#.
# They are seeded anyway, below, so all three characters have a control that can fail rather than
# two branches that pass by construction.
vd_expected="$(
    cat <<'VDEXP'
lib.sh|1
test-appliance-boot.sh|ph
test-appliance-identity-boot.sh|cli_pages
test-appliance-identity-boot.sh|u
test-appliance-identity.sh|1
test-appliance-identity.sh|f
test-appliance-os-update.sh|RIJ
test-appliance-os-update.sh|RIS
test-config.sh|2
test-config.sh|bad_port
test-config.sh|checked
test-config.sh|core_checked
test-control-add-only-ssrf.sh|2
test-control-add-only-ssrf.sh|3
test-control-core.sh|reowned
test-control-diagnostics.sh|_c
test-control-editable-allowlist.sh|1
test-doctor.sh|ip
test-release.sh|comp
test-release.sh|pin_rel
test-release.sh|svc
test-render-quadlet.sh|f
test-rig-worker.sh|3
test-secrets-masking.sh|1
test-secrets.sh|ev
test-secrets.sh|host_ram_mb
test-secrets.sh|mem
test-spool-audit.sh|audit_lines
test-spool-audit.sh|audit_size
test-tor-network.sh|v
test-unit-helpers.sh|t_human
test-unit-helpers.sh|t_name
test-unit-helpers.sh|t_val
VDEXP
)"
assert_eq "every PASS label that interpolates a value is one the suite has reviewed" \
    "$(vd_interp_names "$ROOT/tests/stack/lib.sh" "$ROOT"/tests/stack/test-*.sh)" "$vd_expected"

# The row above is an equality over a set, so a sweep that silently stopped matching would report
# an empty actual against a non-empty expectation and fail loudly — but it would fail naming the
# wrong cause. These three drive the extractor over a file written for the purpose, so each
# property that the row depends on is asserted separately and a break says which one went.
vd_seed="$SANDBOX/vd-interp-control"
mkdir -p "$vd_seed"
cat >"$vd_seed/test-vd-seed.sh" <<'VDSEED'
ok "a label carrying a brand new interpolation $vd_fresh_name"
ok "an escaped \$PWD is prose in a label, not an interpolation"
ok "a wrapper label built from a positional $1 and a braced one ${2}"
ok "a label splicing all of its arguments $@"
ok "a label naming $* and $# — no live site, seeded so the branch has a control"
bad "a bad-only label naming $vd_failure_only"
VDSEED
vd_ctl="$(vd_interp_names "$vd_seed/test-vd-seed.sh")"
assert_contains "the sweep reports a new interpolated PASS label (firing control)" "$vd_ctl" "vd_fresh_name"
assert_not_contains "an escaped dollar in a label is not read as interpolation" "$vd_ctl" "PWD"
assert_not_contains "a bad-only label is not held to the PASS-line rule" "$vd_ctl" "vd_failure_only"
# #1767: the positional and special-parameter alternations are the two this extractor did NOT have.
# Assert them separately from the $VAR row above, so a break says which class stopped matching.
assert_contains "the sweep reports a positional interpolation (#1767 firing control)" "$vd_ctl" "|1"
assert_contains "the sweep reports a braced positional too" "$vd_ctl" "|2"
assert_contains "the sweep reports \$@, which splices every argument" "$vd_ctl" "|@"
assert_contains "the sweep reports \$*, the other splicing parameter" "$vd_ctl" "|*"
assert_contains "the sweep reports \$#, the argument count" "$vd_ctl" "|#"
unset -f vd_interp_names
unset vd_expected vd_seed vd_ctl
