#!/usr/bin/env bash
#
# Self-test for the restore's image-identity check (#272, restore side) and for the restore command
# e2e.sh chooses.
#
# The defect it locks down is an ABSENCE, like #1364's. e2e.sh's own comment at deploy_branch says
# `pithead apply` "runs `compose up --pull` (never --build), so it would test whatever images were
# last built on the box, not this branch" — and the restore, at the other end of the same run, used
# exactly that pairing. On a box whose live install is a SOURCE CHECKOUT, `pithead` exports
# STACK_VERSION=dev (export_build_provenance, pithead:4149), so the baseline and the branch under
# test resolve to the SAME `:dev` tag; deploy_branch has already overwritten it, the source-checkout
# pull policy is `never`, and `apply && up` therefore brings the BRANCH back up under the baseline's
# name. Every other restore check stays green on that: the creds are read from the on-disk .env at
# runtime, monerod answers with them, and the control units name RESTORE_DIR either way. The run
# prints "restore complete."
#
# Two things are proven here, both against the SHIPPED files, never against a re-spelling:
#   1. grade_image_census classifies correctly, sourced straight out of restore-proof.sh.
#   2. restore_all, extracted out of e2e.sh and evaluated against stubs, picks `pithead upgrade` for
#      a source-checkout baseline and the cheaper `apply && up` for a release bundle.
# Then a mutation battery restores each defect in a COPY of the shipped module and requires the
# assertions to RED. A classifier that cannot fail is a grep, not a guard.
#
# Standalone (not sourced by selftest.sh), same reasoning as selftest-e2e-phases.sh. Run directly or
# via `make test-integration-selftest`. No server, no bench, no rig, no docker.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

E2E_SRC="$HERE/e2e.sh"
PROOF_SRC="$HERE/restore-proof.sh"

# Fail CLOSED: if a refactor moves the classifier out of restore-proof.sh this must go red rather
# than quietly stop testing anything — the exact shape of gate this file exists to catch.
# shellcheck source=tests/integration/restore-proof.sh
source "$PROOF_SRC"
assert_eq "restore-proof.sh actually defines grade_image_census" "$(type -t grade_image_census)" "function"

# --- Fixtures ---------------------------------------------------------------------------------
# Five services. The branch build changed only two images (tor, dashboard) — the realistic case,
# and the one that makes a whole-list comparison useless: monerod/p2pool/xmrig-proxy carry an ID
# that matches the baseline AND the branch, so "the censuses differ" says nothing about them.
BASE='dashboard=sha256:aaa
monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:ttt
xmrig-proxy=sha256:xxx'
BRANCH='dashboard=sha256:AAA
monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:TTT
xmrig-proxy=sha256:xxx'

verdict_for() { # <now-census> <service> -> the verdict word
    grade_image_census "$BASE" "$1" "$BRANCH" | sed -n "s/ $2\$//p" | head -n1
}

# --- 1. The classifier ------------------------------------------------------------------------
# Every assertion below is written so that ONE named mutation flips it; the battery at the bottom
# runs those mutations for real.
run_census_assertions() {
    echo "== grade_image_census =="

    # A faithful restore: every service back on the image it ran before.
    assert_eq "an exact restore grades every service 'kept'" \
        "$(grade_image_census "$BASE" "$BASE" "$BRANCH" | cut -d' ' -f1 | sort -u | tr '\n' ' ')" "kept "

    # THE DEFECT. The branch's images are still up under the baseline's name. Kills the mutation
    # that drops the branch census from the comparison (grading against the baseline alone): the
    # two changed services differ from the baseline either way, so a baseline-only check calls this
    # "rebuilt" and passes the run.
    assert_eq "the branch's dashboard left running is 'stale', not 'rebuilt'" \
        "$(verdict_for "$BRANCH" dashboard)" "stale"
    assert_eq "the branch's tor left running is 'stale', not 'rebuilt'" \
        "$(verdict_for "$BRANCH" tor)" "stale"

    # The other three are indistinguishable between the two censuses and must NOT be accused.
    # Kills a whole-list `[ "$now" = "$BASELINE_IMAGES" ]` comparison, which would condemn all five
    # on any difference and make the check's output useless for locating the fault.
    assert_eq "a service the branch never rebuilt is 'kept', even on a stale run" \
        "$(verdict_for "$BRANCH" monerod)" "kept"

    # A genuine rebuild from RESTORE_DIR's own tree: differs from the baseline AND from the branch.
    REBUILT='dashboard=sha256:zzz
monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:yyy
xmrig-proxy=sha256:xxx'
    assert_eq "an image built from neither census is 'rebuilt'" \
        "$(verdict_for "$REBUILT" dashboard)" "rebuilt"

    # Ordering. This image differs from the baseline and equals the branch's; 'stale' must win.
    # Kills a mutation that tests the rebuilt arm first, which would silently reclassify every
    # stale service as a legitimate rebuild — a green run on the exact failure being guarded.
    ONE_STALE='dashboard=sha256:AAA
monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:ttt
xmrig-proxy=sha256:xxx'
    assert_eq "'stale' beats 'rebuilt' when an image matches the branch" \
        "$(verdict_for "$ONE_STALE" dashboard)" "stale"

    # A service that ran before and is not running now is its own verdict, never a silent pass.
    GONE='monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:ttt
xmrig-proxy=sha256:xxx'
    assert_eq "a service that ran before and is gone now grades 'gone'" \
        "$(verdict_for "$GONE" dashboard)" "gone"
    # ...and the four that came back are still graded, so one absence does not mask the rest.
    assert_eq "the other four are still graded when one service is gone" \
        "$(grade_image_census "$BASE" "$GONE" "$BRANCH" | grep -c '^kept ')" "4"

    # An empty branch census (deploy_branch never ran — e.g. --mode check) must not turn every
    # changed image into a false 'stale'. Kills a mutation that drops the `[ -n "$branch" ]` guard,
    # where an empty branch value would equal an empty `now` and mis-grade.
    assert_eq "with no branch census, a changed image is 'rebuilt', not accused of being the branch's" \
        "$(grade_image_census "$BASE" "$BRANCH" "" | sed -n 's/ dashboard$//p')" "rebuilt"

    # census_get lives in here rather than beside the other unit assertions for a reason the
    # battery below made concrete: the classifier fixtures cannot kill a census_get mutation. The
    # service names it looks up come out of the census itself, so even an unanchored match resolves
    # each line to itself and every verdict stays correct. Only a direct assertion sees the defect,
    # so a direct assertion has to be inside the block the mutants re-run.
    echo "== census_get =="
    assert_eq "reads the id for a service" "$(census_get "$BASE" tor)" "sha256:ttt"
    assert_eq "a service not in the census reads empty" "$(census_get "$BASE" caddy)" ""
    # 'proxy' must not resolve off 'xmrig-proxy='.
    assert_eq "the service name is matched from the start of the line, not anywhere in it" \
        "$(census_get "$BASE" proxy)" ""
}
run_census_assertions

# --- 2. Which restore command e2e.sh runs -----------------------------------------------------
# The REAL restore_all out of the shipped e2e.sh, evaluated against stubs, so this reads the
# command the box would actually have been given — not a re-implementation of the decision.
RESTORE_SRC="$(sed -n '/^restore_all() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$RESTORE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "restore_all() { } "

drive_restore() { # <is-source-checkout: yes|no> -> the `cd RESTORE_DIR && ...` command string
    local cf
    cf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329  # read/called by the eval'd restore_all, which shellcheck
    # cannot follow into.
    (
        exec </dev/null
        RESTORED=0 KEEP=0 MINER_CFG_BACKUP="" RESTORE_DIR=/srv/code/baseline
        E2E_DIR=/srv/code/pithead-e2e BENCH_HOST=bench SAFETY_ARCHIVE=""
        RESTORE_PROOF_FAILED=0 CONTROL_PROOF_FAILED=0 CONTROL_VERDICT_BEFORE=""
        BASELINE_IMAGES="" BRANCH_IMAGES="" SRC_CHECKOUT="$1" CMD_FILE="$cf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        control_units_verdict() { echo on-target; }
        wait_bench_healthy() { return 0; }
        verify_restore_proof() { return 0; }
        on_bench() {
            case "$1" in
            # The source-checkout probe: answer as the fixture says, and never record it as the
            # restore command.
            "test -f "*dashboard/Dockerfile*) [ "$SRC_CHECKOUT" = yes ] && return 0 || return 1 ;;
            "cd '$RESTORE_DIR' && "*)
                printf '%s' "${1#cd \'$RESTORE_DIR\' && }" >"$CMD_FILE"
                return 0
                ;;
            esac
            return 0
        }
        eval "$RESTORE_SRC"
        restore_all
    ) >/dev/null 2>&1
    cat "$cf"
    rm -f "$cf"
}

echo "== the restore command, by baseline kind =="
SRC_CMD="$(drive_restore yes)"
BUNDLE_CMD="$(drive_restore no)"

# The fix. A source-checkout baseline shares `:dev` with the branch, so the restore must REBUILD
# from the baseline's tree. Kills the mutation that reverts the restore to `apply && up`.
assert_contains "a source-checkout baseline is restored with 'pithead upgrade'" "$SRC_CMD" "./pithead upgrade"
# ...and keeps the old pairing as a fallback, so a failed rebuild is not worse than the status quo.
assert_contains "the source-checkout restore falls back to apply/up if the rebuild fails" \
    "$SRC_CMD" "|| { ./pithead apply -y"
# A release bundle's images are versioned tags the branch never touched: rebuilding there is waste,
# and forcing it would make every release-box restore minutes longer for nothing.
assert_eq "a release-bundle baseline is NOT rebuilt" \
    "$(case "$BUNDLE_CMD" in *upgrade*) echo yes ;; *) echo no ;; esac)" "no"
assert_contains "a release-bundle baseline still gets apply + up" "$BUNDLE_CMD" "./pithead apply -y"

# --- 3. Mutation battery ----------------------------------------------------------------------
# Each entry restores a real defect in a COPY of the shipped module and requires the classifier
# assertions above to RED. A guard that survives its own defect being put back is decoration.
echo "== mutation battery: every mutant must kill at least one assertion =="
# A sed expression that matches nothing produces an unmutated copy, whose assertions all pass —
# indistinguishable from a mutant the guard survived, and the more likely of the two. So the
# mutation is asserted to have CHANGED the file before its result is believed; without this the
# battery's own failure mode is a green.
mutant_applies() { # <sed-expr> -> yes|no
    if [ "$(sed "$1" "$PROOF_SRC" | diff -q - "$PROOF_SRC" >/dev/null 2>&1 && echo same || echo differs)" = differs ]; then
        echo yes
    else echo no; fi
}
mutate_and_count_fails() { # <sed-expr> -> the number of failed assertions under the mutant
    local mutant
    [ "$(mutant_applies "$1")" = yes ] || {
        echo "MUTANT DID NOT APPLY"
        return 0
    }
    mutant="$(mktemp)"
    sed "$1" "$PROOF_SRC" >"$mutant"
    (
        IT_PASS=0 IT_FAIL=0
        # shellcheck disable=SC1090
        source "$mutant"
        run_census_assertions >/dev/null 2>&1
        printf '%s' "$IT_FAIL"
    )
    rm -f "$mutant"
}

# M1 — grade against the baseline alone, dropping the branch census. This is the pre-fix world:
# every changed image reads as a rebuild and the run passes on the defect.
assert_num_ge "M1 (no branch comparison) is killed" \
    "$(mutate_and_count_fails 's/elif \[ "$now" = "$branch" \]; then/elif false; then/')" 1
# M2 — never emit 'stale': grade a branch image as an ordinary rebuild. The first spelling of this
# mutant did not match the file at all and read as a survivor; each expression below is asserted to
# actually change the module before it is trusted (mutant_applies).
assert_num_ge "M2 (branch image graded 'rebuilt') is killed" \
    "$(mutate_and_count_fails "s/'stale %s/'rebuilt %s/")" 1
# M3 — unanchor census_get, so one service name resolves off another's line.
assert_num_ge "M3 (unanchored census_get) is killed" \
    "$(mutate_and_count_fails 's|sed -n "s/\^\$2=//p"|sed -n "s/.*$2=//p"|')" 1

echo ""
printf 'restore-proof self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
