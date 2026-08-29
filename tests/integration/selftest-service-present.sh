#!/usr/bin/env bash
#
# Self-test for service_present (#1478) — the exact-line membership test the three
# container-presence assertions in run.sh share.
#
# These cases live in their own file rather than in selftest.sh because that file sits
# exactly on its recorded budget ceiling, and ceilings only go down.
#
# Run: tests/integration/selftest-service-present.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"

echo "== service_present: exact-line membership, never substring (#1478) =="

# running_services() emits compose SERVICE NAMES one per line. Exactly one pair nests —
# "tari" inside "tari-wallet" — so that pair is the whole point of these cases. The longer
# sibling has to be IN the fixture or the assertion is blind to the bug it exists to catch.
# want: 0 = present, 1 = absent.
check() {
    local name="$1" needle="$2" hay="$3" want="$4" got
    service_present "$needle" "$hay"
    got=$?
    if [ "$got" = "$want" ]; then it_pass "$name"; else it_fail "$name" "want rc=$want, got rc=$got"; fi
}

check "a running tari-wallet does not mean tari is up" tari "$(printf 'caddy\ntari-wallet\ntor')" 1
check "tari alongside tari-wallet is still found" tari "$(printf 'caddy\ntari\ntari-wallet\ntor')" 0
check "tari alone is found" tari "$(printf 'caddy\ntari\ntor')" 0
check "the needle is a literal, not a pattern" "ta.i" "$(printf 'caddy\ntari\ntor')" 1
# The monerod direction is the one #1478 calls latent: nothing is named *monerod* today, but a
# remote-mode fixture adding a node container on the same box would arm it.
check "a neighbour named *monerod* is not monerod" monerod "$(printf 'caddy\nmonerod-remote\ntor')" 1
check "monerod itself is still found" monerod "$(printf 'caddy\nmonerod\ntor')" 0

check "nothing running -> not present" tari "" 1

echo ""
echo "selftest-service-present: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
