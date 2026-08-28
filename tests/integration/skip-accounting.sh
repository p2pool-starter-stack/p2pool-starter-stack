# shellcheck shell=bash
#
# Skip accounting for the integration harness (#1365).
#
# This file is *sourced* by lib.sh, never executed. It exists as its own file rather than as a
# block inside lib.sh because lib.sh sits on its file-budget ceiling (docs/dev/file-budget.tsv)
# and that ratchet only moves down — the same split #1258 worked through.
#
# Skips are counted too, in three buckets, and every one is NAMED (#1365). Before this the
# harness had exactly three counter increments — IT_PASS, IT_FAIL and the scenario skip — so a
# run that dropped the whole rigforge-control phase and a run that exercised it produced
# summaries differing only in the pass count, and the pass count moves for a dozen unrelated
# reasons. The output had no way to say "this did not run", which leaves the reader unable to
# tell "checked and clean" from "never ran" — the one distinction a gate exists to make.
IT_SKIPPED=0
IT_SKIPPED_PHASES=0
IT_SKIPPED_LEGS=0
IT_SKIPPED_NAMES=""

# --- Counted skips ----------------------------------------------------------
# Each takes WHAT did not run and WHY. Both halves are load-bearing: a bare count tells the
# reader how much is missing but not what, and a run that ends "skipped legs: 6 (pools,
# auto-rollback, upgrade, #516-reflection, #516-prefill, node-down-failover)" says what it did
# not prove.
#
# A scenario skip drops one matrix row; a phase skip drops every leg under it with one line; a
# leg skip drops one assertion group. They are separate buckets rather than one total because
# they are not the same event and must not average out — losing the whole rigforge-control phase
# is not the same size of hole as losing its pools leg.
_it_skip_record() {
    IT_SKIPPED_NAMES="${IT_SKIPPED_NAMES}\n    - ${1} ${2} — ${3}"
}
it_skip_scenario() {
    IT_SKIPPED=$((IT_SKIPPED + 1))
    _it_skip_record "scenario" "$1" "$2"
    it_warn "SKIPPED scenario ${1}: ${2}"
}
it_skip_phase() {
    IT_SKIPPED_PHASES=$((IT_SKIPPED_PHASES + 1))
    _it_skip_record "PHASE   " "$1" "$2"
    it_warn "▲ SKIPPED WHOLE PHASE ${1}: ${2}"
}
it_skip_leg() {
    IT_SKIPPED_LEGS=$((IT_SKIPPED_LEGS + 1))
    _it_skip_record "leg     " "$1" "$2"
    it_warn "skipped leg ${1}: ${2}"
}

# --- The one assertion pair that is conditionally skipped ---------------------------------------
# It lives here rather than in lib.sh because its whole contract is a skip: it is the only place
# the harness suppresses assertions on the caller's say-so, and it is now the caller of
# it_skip_leg. (lib.sh sitting on its file-budget ceiling is what forced the split; this is the
# block that belonged on this side of it.)
# Mining-liveness verdict (#905/#1082), factored out of assert_running_state so selftest can
# prove --no-mining-asserts is a CONDITIONAL skip, not a permanent one: the two assertions must
# still run — and be able to go red — every time the flag is unset. Only the caller-set skip
# flag suppresses them; there is no auto-detection here (a live worker-count of zero from a
# genuinely fallen-off rig must stay indistinguishable from a parked bench unless the operator
# says so explicitly — see #1082's fail-open discussion).
assert_mining_state() { # <skip: 0|1> <workers> <hashes> <expected-workers>
    if [ "$1" = "1" ]; then
        it_skip_leg "workers online + stratum total hashes (#905/#1082)" "no miner attached to this box (--no-mining-asserts) — drop the flag (and attach a miner) to make these binding again"
        return 0
    fi
    assert_num_ge "workers online (>= $4)" "${2:-0}" "$4"
    assert_num_gt "stratum total hashes > 0" "${3:-0}" 0
}
