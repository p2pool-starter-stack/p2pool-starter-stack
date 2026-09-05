# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Stratum-exposure surface domain (#1772). The exposure CHECK itself — the bind x public-IP x mode
# matrix — is proven in test-doctor.sh and is not re-proven here. What this domain owns is the one
# thing that matrix cannot see: WHO READS THE VERDICT, and what the verdict is therefore allowed to
# say. Since #1736 `control_diag_doctor` runs `doctor --json` and ships every recorded message to
# the dashboard, so this check has two audiences that want different text, and one of them is a
# browser on the network.
#
# TWO CLAIMS, and they fail in opposite directions:
#   1. The doctor arms must not carry the host's public ADDRESS. `bundle_redact_log`
#      (07-support-bundle.sh) is the only redactor on that path and it keys on argv position, the
#      onion shape and the Monero shape -- it has NO IP rule, so nothing downstream removes the
#      value and it has to be absent from the message. (tests/integration/lib.sh's redact() does
#      have one, but that twin guards CI artifact uploads from a self-hosted runner, not this path.)
#   2. The APPLIANCE arm must not prescribe a remedy that operator cannot reach. Neither
#      STRATUM_BIND nor STRATUM_PASSWORD is dashboard-committable -- 42-control-policy-and-host-
#      checks.sh names the stratum password as staying host-only -- so the appliance wording states
#      the diagnosis, gives the one route that exists (the router), and stops.
# The setup console is the deliberate exception and is asserted to KEEP the address: it prints to
# the operator's own terminal on their own host, where the value is what makes the finding
# actionable, and it goes nowhere.
#
# THE ABSENCE CLAIMS NEED THE CONSOLE ROW TO BE MEANINGFUL, which is why it is not merely a nicety.
# "8.8.8.8 does not appear in the doctor output" is satisfied just as well by a broken stub whose
# address never reached ANY output. The console row is the positive control on the same instrument
# in the same file: it proves the stubbed address does reach a surface, so its absence elsewhere is
# a fact about the wording rather than about the fixture.
#
# Standalone-sourceable once tests/stack/lib.sh has been sourced; it builds its own `ip` stub rather
# than borrowing test-doctor.sh's, so neither domain can break the other by reordering.

echo "== unit: doctor's stratum-exposure verdict is worded for its surface (#1772) =="
XPBIN="$SANDBOX/xpbin"
mkdir -p "$XPBIN"
{
    printf '#!/usr/bin/env bash\n'
    printf 'cat <<'\''ADDRS'\''\n2: eth0    inet 8.8.8.8/24 scope global eth0\nADDRS\n'
} >"$XPBIN/ip"
chmod +x "$XPBIN/ip"
_xp() { STRATUM_BIND=0.0.0.0 PITHEAD_APPLIANCE="$1" PATH="$XPBIN:$PATH" run_sourced "$SANDBOX" check_stratum_exposure "$2" 2>&1; }

# THE POSITIVE CONTROL, and every ABSENT row below leans on it: the setup console names the address.
_xp_console=$(_xp 0 setup)
assert_contains "the setup console still names the address it found (#1772)" "$_xp_console" "8.8.8.8"

# The host doctor arm keeps its remedies -- it is the DIY wording -- but loses the value, because
# `dr_warn` records into DR_JSON_FILE and a host box with dashboard.control.enabled reaches the
# same browser an appliance does.
_xp_host=$(_xp 0 doctor)
assert_contains "the host doctor verdict still reports the exposure (#1772)" "$_xp_host" "public IP"
assert_not_contains "the host doctor verdict withholds the address (#1772)" "$_xp_host" "8.8.8.8"
assert_contains "the host doctor verdict keeps its host remedies (#1772)" "$_xp_host" "stratum_bind"

# The appliance arm: same finding, no value, and no remedy behind a console it does not have.
_xp_appl=$(_xp 1 doctor)
assert_contains "the appliance verdict still reports the exposure (#1772)" "$_xp_appl" "public IP"
assert_not_contains "the appliance verdict withholds the address (#1772)" "$_xp_appl" "8.8.8.8"
for _xp_h in stratum_bind stratum_password "firewall it to your LAN"; do
    assert_not_contains "the appliance verdict does not prescribe '$_xp_h' (#1772)" "$_xp_appl" "$_xp_h"
done
assert_contains "the appliance verdict names the one route that exists (#1772)" "$_xp_appl" "router"

# And the two arms must actually DIFFER. Asserting each one's content separately would stay green if
# the surface switch never flipped and both reads returned the same text.
if [ "$_xp_host" = "$_xp_appl" ]; then
    bad "the surface switch actually flips this verdict (#1772)" "host and appliance produced identical text: $_xp_host"
else
    ok "the surface switch actually flips this verdict (#1772)"
fi
