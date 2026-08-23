#!/usr/bin/env bash
#
# Self-test for has_compose_profile (#1301): the COMPOSE_PROFILES membership test run.sh's six
# local-mode gates (rigforge-control, hardening, moved-subnet, plus two lifecycle assertions) use
# instead of a literal string comparison. Standalone (not sourced by selftest.sh) so it never
# touches selftest.sh's own file-budget ceiling — see CONTRIBUTING.md's file-budget-gate entry,
# the #1258 "moved into its own file" precedent. Run directly, or via
# `make test-integration-selftest` (which runs this after selftest.sh). No server needed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/scenarios.sh
source "$HERE/scenarios.sh"

echo "== has_compose_profile: COMPOSE_PROFILES membership, not string equality (#1301) =="
# This is the load-bearing assertion for #1301: reverting has_compose_profile's body to the old
# `[ "$1" = "$2" ]` comparison flips this from PASS to FAIL on exactly this fixture — the real
# shape a standard local box renders (render_env appends local_tari/payout_confirm alongside
# local_node), not a synthetic one — because strict equality only matches when local_node is the
# ONLY active profile. That's the mutation this assertion is proving it still catches.
if has_compose_profile "local_node,local_tari,payout_confirm" local_node; then
    it_pass "membership matches local_node inside a multi-profile list (the #1301 shape)"
else
    it_fail "membership matches local_node inside a multi-profile list (the #1301 shape)" \
        "false negative — reverts to the #1301 literal-equality bug"
fi
# The simple case (no other feature on) must keep working — the fix must not regress it.
if has_compose_profile "local_node" local_node; then
    it_pass "membership matches a bare single-token list"
else
    it_fail "membership matches a bare single-token list" "false negative on the simplest case"
fi
# A genuinely remote stack (local_node absent, other profiles still present) must still skip —
# the gate must not flip into matching everything.
if has_compose_profile "payout_confirm" local_node; then
    it_fail "genuinely remote profile set is not treated as local_node" \
        "false positive on a remote-mode profile list"
else
    it_pass "genuinely remote profile set is not treated as local_node"
fi
# Membership is token-exact, not a raw substring match — a profile name that merely CONTAINS
# "local_node" must not false-positive (guards a naive unanchored `case *local_node*` rewrite).
if has_compose_profile "some_local_node_variant" local_node; then
    it_fail "membership is token-exact, not a substring match" \
        "false positive on 'some_local_node_variant'"
else
    it_pass "membership is token-exact, not a substring match"
fi
# An empty profiles string (COMPOSE_PROFILES unset/absent) must not crash or match.
if has_compose_profile "" local_node; then
    it_fail "empty profiles list is not treated as local_node" "false positive on an empty string"
else
    it_pass "empty profiles list is not treated as local_node"
fi

echo ""
echo "selftest-compose-profiles: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
