#!/usr/bin/env bash
#
# Dependency-free test suite for pithead (no bats required).
# Mixes unit tests (sourcing pithead and calling its functions) with black-box CLI tests
# (running a sandboxed copy of pithead with docker/sudo stubbed out). Run: tests/stack/run.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-harness-tooling.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-harness-tooling.sh" && domain_ran test-harness-tooling.sh "$_d0" "$?" || domain_ran test-harness-tooling.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-doctor.sh" && domain_ran test-doctor.sh "$_d0" "$?" || domain_ran test-doctor.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-upgrade.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-upgrade.sh" && domain_ran test-control-upgrade.sh "$_d0" "$?" || domain_ran test-control-upgrade.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-upgrade-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-upgrade-lock.sh" && domain_ran test-control-upgrade-lock.sh "$_d0" "$?" || domain_ran test-control-upgrade-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-release-signing.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release-signing.sh" && domain_ran test-release-signing.sh "$_d0" "$?" || domain_ran test-release-signing.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-dashboard.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard.sh" && domain_ran test-dashboard.sh "$_d0" "$?" || domain_ran test-dashboard.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-dashboard-onion.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-dashboard-onion.sh" && domain_ran test-dashboard-onion.sh "$_d0" "$?" || domain_ran test-dashboard-onion.sh "$_d0" "$?"

# Regression (#1330): test-dashboard-onion.sh must not depend on running after test-dashboard.sh.
# A `( ... )` subshell is a fork of THIS process and inherits its whole variable table, exported
# or not — including $auth_hb64/$caddy_https, already left behind here by test-dashboard.sh's
# earlier `source` a few lines up, so a subshell guard would stay green even if this file went
# back to reading those as globals. Only a genuinely separate `bash` process is isolated: it
# inherits the environment (exported vars), never a parent shell's plain variables. $HERE isn't
# exported either, so it's passed as an argument rather than read from the environment.
# shellcheck disable=SC1090,SC2015  # STACK/HERE paths are dynamic by design
bash -c '
    set -uo pipefail
    source "$1/lib.sh"
    source "$1/test-dashboard-onion.sh" >/dev/null 2>&1
    [ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
' _ "$HERE"
assert_rc "test-dashboard-onion.sh does not depend on run.sh's source order (#1330)" "$?" "0"

# shellcheck source=tests/stack/test-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-release.sh" && domain_ran test-release.sh "$_d0" "$?" || domain_ran test-release.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-unit-helpers.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-unit-helpers.sh" && domain_ran test-unit-helpers.sh "$_d0" "$?" || domain_ran test-unit-helpers.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-cli.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-cli.sh" && domain_ran test-cli.sh "$_d0" "$?" || domain_ran test-cli.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-config.sh" && domain_ran test-config.sh "$_d0" "$?" || domain_ran test-config.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-render-quadlet.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-render-quadlet.sh" && domain_ran test-render-quadlet.sh "$_d0" "$?" || domain_ran test-render-quadlet.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor-appliance.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-doctor-appliance.sh" && domain_ran test-doctor-appliance.sh "$_d0" "$?" || domain_ran test-doctor-appliance.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-setup.sh" && domain_ran test-appliance-setup.sh "$_d0" "$?" || domain_ran test-appliance-setup.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-backup.sh" && domain_ran test-backup.sh "$_d0" "$?" || domain_ran test-backup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-install-verify.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-install-verify.sh" && domain_ran test-install-verify.sh "$_d0" "$?" || domain_ran test-install-verify.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-secrets.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-secrets.sh" && domain_ran test-secrets.sh "$_d0" "$?" || domain_ran test-secrets.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-rig-worker.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rig-worker.sh" && domain_ran test-rig-worker.sh "$_d0" "$?" || domain_ran test-rig-worker.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-status-vocabulary.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-status-vocabulary.sh" && domain_ran test-control-status-vocabulary.sh "$_d0" "$?" || domain_ran test-control-status-vocabulary.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-monero-tari.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-monero-tari.sh" && domain_ran test-monero-tari.sh "$_d0" "$?" || domain_ran test-monero-tari.sh "$_d0" "$?"

# xmrig-proxy wrapper entrypoint: optional stratum access-password (#152). The flag moved out of the
# compose command (a `${VAR:+--flag}` list element rendered a stray '' positional arg when the password
# was unset — xmrig-proxy warns `unsupported non-option argument ''`) into this wrapper, which appends
# it only when PROXY_STRATUM_PASSWORD is set. Exercise the real script with a stub xmrig-proxy on PATH
# that echoes its argv, so the set/unset branch is actually run.
XP_ENTRY="$ROOT/build/xmrig-proxy/entrypoint.sh"
xp_argv() { # <password value> -> the argv the wrapper would exec
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD="$1" sh "$XP_ENTRY" --http-no-restricted --donate-level=0
    rm -rf "$d"
}
assert_eq "xmrig-proxy entrypoint: unset password appends no flag (#152)" \
    "$(xp_argv '')" "[--http-no-restricted][--donate-level=0]"
assert_eq "xmrig-proxy entrypoint: set password appends --access-password (#152)" \
    "$(xp_argv 's3cret')" "[--http-no-restricted][--donate-level=0][--access-password=s3cret]"
# #261: the TLS cert flags append only when the toggle is on AND both keypair files exist at the
# mount (PROXY_TLS_MOUNT overrides the fixed /tls so the suite can use a temp dir).
xp_tls_argv() { # <PROXY_STRATUM_TLS value> <tls dir>
    local d
    d="$(mktemp -d)"
    printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]" "$a"; done\n' >"$d/xmrig-proxy"
    chmod +x "$d/xmrig-proxy"
    PATH="$d:$PATH" PROXY_STRATUM_PASSWORD='' PROXY_STRATUM_TLS="$1" PROXY_TLS_MOUNT="$2" sh "$XP_ENTRY" -b 0.0.0.0:3333
    rm -rf "$d"
}
XPTLS="$(mktemp -d)"
printf 'cert' >"$XPTLS/cert.pem"
printf 'key' >"$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on + keypair appends the cert flags (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333][--tls-cert=$XPTLS/cert.pem][--tls-cert-key=$XPTLS/key.pem]"
assert_eq "xmrig-proxy entrypoint: TLS off appends nothing (#261)" \
    "$(xp_tls_argv false "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -f "$XPTLS/key.pem"
assert_eq "xmrig-proxy entrypoint: TLS on but keypair incomplete appends nothing (#261)" \
    "$(xp_tls_argv true "$XPTLS")" "[-b][0.0.0.0:3333]"
rm -rf "$XPTLS"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-tor-network.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-tor-network.sh" && domain_ran test-tor-network.sh "$_d0" "$?" || domain_ran test-tor-network.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-core.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-core.sh" && domain_ran test-control-core.sh "$_d0" "$?" || domain_ran test-control-core.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-secrets-masking.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-secrets-masking.sh" && domain_ran test-secrets-masking.sh "$_d0" "$?" || domain_ran test-secrets-masking.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-confirm-approval.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-confirm-approval.sh" && domain_ran test-confirm-approval.sh "$_d0" "$?" || domain_ran test-confirm-approval.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-data-management.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-data-management.sh" && domain_ran test-data-management.sh "$_d0" "$?" || domain_ran test-data-management.sh "$_d0" "$?"

# The approval gate (#33) — default-deny on security-sensitive changes — together with
# workers.list[]'s add-only exception (#893) and the #122 SSRF floor on a newly appended entry's
# host. The whole domain lives in the file and arms its own control sandbox (#1105 R13); this
# stanza sits at the position the section has always run from.
# shellcheck source=tests/stack/test-control-add-only-ssrf.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-add-only-ssrf.sh" && domain_ran test-control-add-only-ssrf.sh "$_d0" "$?" || domain_ran test-control-add-only-ssrf.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-editable-allowlist.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-editable-allowlist.sh" && domain_ran test-control-editable-allowlist.sh "$_d0" "$?" || domain_ran test-control-editable-allowlist.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-worker-config.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-worker-config.sh" && domain_ran test-worker-config.sh "$_d0" "$?" || domain_ran test-worker-config.sh "$_d0" "$?"

echo "== black-box: notification secrets masked in the prefill copy (#848) =="
# The ntfy topic URL + token are bearer credentials, and each notifications.webhooks[] entry IS a
# bearer URL (query strings carry tokens). All must be sentineled in the world-readable masked copy
# — one LEAK- marker across every set secret proves the whole set at once; a blank webhook entry and
# the non-secret notifications.tor flag must survive so the editor can still render the form.
jq '.notifications = {
    webhooks: ["https://hooks.example/LEAK-hookA", "", "https://hooks.example/LEAK-hookB"],
    ntfy: {url: "https://ntfy.example/LEAK-ntfyurl", token: "LEAK-ntfytoken"},
    tor: true}' "$C/config.json" >"$C/config.json.tmp" && mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
assert_eq "ntfy url masked to the sentinel" "$(jq -c '.notifications.ntfy.url' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "ntfy token masked to the sentinel" "$(jq -c '.notifications.ntfy.token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "first webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[0]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "third webhook entry masked to the sentinel" "$(jq -c '.notifications.webhooks[2]' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "a blank webhook entry stays blank in the masked copy" "$(jq -r '.notifications.webhooks[1]' "$MASKED" 2>/dev/null)" ""
assert_eq "the non-secret notifications.tor flag survives" "$(jq -r '.notifications.tor' "$MASKED" 2>/dev/null)" "true"
case "$(cat "$MASKED")" in
*LEAK-*) bad "masked copy holds no notification secret" "a notification secret leaked into $MASKED" ;;
*) ok "masked copy holds no notification secret" ;;
esac

# shellcheck source=tests/stack/test-spool-audit.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-spool-audit.sh" && domain_ran test-spool-audit.sh "$_d0" "$?" || domain_ran test-spool-audit.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-deploy.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-deploy.sh" && domain_ran test-control-deploy.sh "$_d0" "$?" || domain_ran test-control-deploy.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-telegram.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-telegram.sh" && domain_ran test-control-telegram.sh "$_d0" "$?" || domain_ran test-control-telegram.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-backup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-backup.sh" && domain_ran test-control-backup.sh "$_d0" "$?" || domain_ran test-control-backup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-diagnostics.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-diagnostics.sh" && domain_ran test-control-diagnostics.sh "$_d0" "$?" || domain_ran test-control-diagnostics.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-wizard-setup.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-wizard-setup.sh" && domain_ran test-wizard-setup.sh "$_d0" "$?" || domain_ran test-wizard-setup.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-control-provisioning.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-control-provisioning.sh" && domain_ran test-control-provisioning.sh "$_d0" "$?" || domain_ran test-control-provisioning.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-identity.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity.sh" && domain_ran test-appliance-identity.sh "$_d0" "$?" || domain_ran test-appliance-identity.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-defaults.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-defaults.sh" && domain_ran test-appliance-defaults.sh "$_d0" "$?" || domain_ran test-appliance-defaults.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-install.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-install.sh" && domain_ran test-appliance-install.sh "$_d0" "$?" || domain_ran test-appliance-install.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-rig-miner.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-rig-miner.sh" && domain_ran test-appliance-rig-miner.sh "$_d0" "$?" || domain_ran test-appliance-rig-miner.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-boot.sh" && domain_ran test-appliance-boot.sh "$_d0" "$?" || domain_ran test-appliance-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-boot-remint.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-boot-remint.sh" && domain_ran test-appliance-boot-remint.sh "$_d0" "$?" || domain_ran test-appliance-boot-remint.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-cert-advisory.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-cert-advisory.sh" && domain_ran test-appliance-cert-advisory.sh "$_d0" "$?" || domain_ran test-appliance-cert-advisory.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-boot-release.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-boot-release.sh" && domain_ran test-appliance-boot-release.sh "$_d0" "$?" || domain_ran test-appliance-boot-release.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update.sh" && domain_ran test-appliance-os-update.sh "$_d0" "$?" || domain_ran test-appliance-os-update.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update-verbs.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update-verbs.sh" && domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?" || domain_ran test-appliance-os-update-verbs.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-data-floor.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-data-floor.sh" && domain_ran test-appliance-data-floor.sh "$_d0" "$?" || domain_ran test-appliance-data-floor.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-os-update-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-os-update-lock.sh" && domain_ran test-appliance-os-update-lock.sh "$_d0" "$?" || domain_ran test-appliance-os-update-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-kernel-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-kernel-boot.sh" && domain_ran test-appliance-kernel-boot.sh "$_d0" "$?" || domain_ran test-appliance-kernel-boot.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-reset.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-reset.sh" && domain_ran test-appliance-reset.sh "$_d0" "$?" || domain_ran test-appliance-reset.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-reset-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-reset-lock.sh" && domain_ran test-appliance-reset-lock.sh "$_d0" "$?" || domain_ran test-appliance-reset-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-caddyfile-optional-env.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-caddyfile-optional-env.sh" && domain_ran test-appliance-caddyfile-optional-env.sh "$_d0" "$?" || domain_ran test-appliance-caddyfile-optional-env.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-rotate-secrets-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-rotate-secrets-lock.sh" && domain_ran test-appliance-rotate-secrets-lock.sh "$_d0" "$?" || domain_ran test-appliance-rotate-secrets-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-firstboot-install-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-firstboot-install-lock.sh" && domain_ran test-appliance-firstboot-install-lock.sh "$_d0" "$?" || domain_ran test-appliance-firstboot-install-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-readonly-verbs-lock.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-readonly-verbs-lock.sh" && domain_ran test-readonly-verbs-lock.sh "$_d0" "$?" || domain_ran test-readonly-verbs-lock.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-identity-boot.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-identity-boot.sh" && domain_ran test-appliance-identity-boot.sh "$_d0" "$?" || domain_ran test-appliance-identity-boot.sh "$_d0" "$?"
# shellcheck source=tests/stack/test-appliance-machine-id-journal.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-machine-id-journal.sh" && domain_ran test-appliance-machine-id-journal.sh "$_d0" "$?" || domain_ran test-appliance-machine-id-journal.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-appliance-media.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-appliance-media.sh" && domain_ran test-appliance-media.sh "$_d0" "$?" || domain_ran test-appliance-media.sh "$_d0" "$?"

# shellcheck source=tests/stack/test-rauc-loop-wait.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-rauc-loop-wait.sh" && domain_ran test-rauc-loop-wait.sh "$_d0" "$?" || domain_ran test-rauc-loop-wait.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-lifecycle.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-lifecycle.sh" && domain_ran test-lifecycle.sh "$_d0" "$?" || domain_ran test-lifecycle.sh "$_d0" "$?"

echo "== unit: doctor's remedial strings are surface-aware (#1213) =="
# Doctor's verdicts reach the dashboard verbatim now that the diagnostics verbs ship them
# (control_diag_doctor runs `doctor --json`; doctor_json emits every message as {status, message}),
# so a remedial string naming a CLI verb is a dead end on an appliance, which has no shell. Two
# instruments, because either one alone passes for the wrong reason: the switch has to actually
# FLIP, and no verdict may be left behind it.
#
# 1. The mechanism. Argument one is the DIY/host wording, argument two the appliance's; each side
#    must print its own and NOT the other's -- asserting only that the right text appears would
#    stay green if both were printed.
for _s in fail warn info; do
    out=$(PITHEAD_APPLIANCE=0 run_sourced "$SANDBOX" "dr_${_s}_surface" "DIYSIDE" "APPLIANCESIDE" 2>&1)
    assert_contains "dr_${_s}_surface off the appliance prints the host wording" "$out" "DIYSIDE"
    case "$out" in
    *APPLIANCESIDE*) bad "dr_${_s}_surface off the appliance withholds the appliance wording" "both sides printed: $out" ;;
    *) ok "dr_${_s}_surface off the appliance withholds the appliance wording" ;;
    esac
    out=$(PITHEAD_APPLIANCE=1 run_sourced "$SANDBOX" "dr_${_s}_surface" "DIYSIDE" "APPLIANCESIDE" 2>&1)
    assert_contains "dr_${_s}_surface on the appliance prints the appliance wording" "$out" "APPLIANCESIDE"
    case "$out" in
    *DIYSIDE*) bad "dr_${_s}_surface on the appliance withholds the host wording" "both sides printed: $out" ;;
    *) ok "dr_${_s}_surface on the appliance withholds the host wording" ;;
    esac
done

# 2. The #1776 site, named because the sweep below could not see it. Its verdict prescribed two
#    host-only remedies ("Move the data here" and the verb as the bare quoted word 'apply'), and
#    the literal alternation carries `\./pithead ` but no token for that quoting -- so the sweep
#    returned 0 matches over a site it fully covers, and #1213 closed with this string still plain.
#    Read off the SHIPPED artifact, the same instrument the sweep uses, so a lib/ edit that never
#    reaches `pithead` cannot pass this.
#
#    AND THIS BLOCK IS NOW THE SITE'S ONLY VERB GUARD. Converting it to dr_warn_surface takes it
#    OUT of block 3's sweep by construction -- that sweep's site pattern is `dr_warn "`, which a
#    `dr_warn_surface "` call does not match, and the exclusion is deliberate because a host
#    argument is SUPPOSED to keep its verb. So the single literal in _dd_pred_verb is all that
#    stands behind the appliance side of this one verdict. Widen it here, not there.
#
#    THE CONTROL IS NOT OPTIONAL. Both assertions below are ABSENCE claims over a grep, and an
#    absence claim goes green when the needle simply stops matching -- rename the message and this
#    passes forever while proving nothing. So the same two predicates run against a synthetic
#    PRE-FIX line first and must FAIL there.
_dd_pred_plain() { case "$1" in *dr_warn_surface*) return 1 ;; *) return 0 ;; esac }
_dd_pred_verb() { case "$1" in *"run 'apply'"*) return 0 ;; *) return 1 ;; esac }
_dd_seed="            dr_warn \"Data dir from .env not found: X=Y — a relocated/copied install re-syncs from scratch. Move the data here, or set the data_dir in config.json and run 'apply'.\""
if _dd_pred_plain "$_dd_seed" && _dd_pred_verb "$_dd_seed"; then
    ok "control: the pre-fix data-dir verdict is caught as plain AND as naming a verb (#1776)"
else
    bad "control: the pre-fix data-dir verdict was NOT caught" "instrument cannot fail; the assertions below prove nothing"
fi

_dd_line=$(grep -n 'Data dir from .env not found' "$STACK" | head -1)
if [ -z "$_dd_line" ]; then
    bad "the data-dir verdict is present in the shipped artifact (#1776)" "no line matched -- the message was renamed and the assertions below are vacuous"
else
    ok "the data-dir verdict is present in the shipped artifact (#1776)"
    if _dd_pred_plain "$_dd_line"; then
        bad "the data-dir verdict is surface-aware (#1776)" "still a plain dr_warn: $_dd_line"
    else
        ok "the data-dir verdict is surface-aware (#1776)"
    fi
    # The host side KEEPS the verb by design (it is the DIY wording); only the appliance side must
    # not. Take the second quoted argument, the way the helper's own contract orders them.
    _dd_appl=$(printf '%s' "$_dd_line" | awk -F'"' '{print $4}')
    # ...and prove the field EXISTS before reading an absence out of it. On the pre-fix shape --
    # one quoted argument -- $4 is the empty string, _dd_pred_verb "" returns rc 1, and the row
    # below would print ok having examined nothing. Only its sibling reds that case today.
    if [ -z "$_dd_appl" ]; then
        bad "the data-dir verdict's appliance wording names no host verb (#1776)" "no second quoted argument on: $_dd_line"
    elif _dd_pred_verb "$_dd_appl"; then
        bad "the data-dir verdict's appliance wording names no host verb (#1776)" "appliance side still says run 'apply': $_dd_appl"
    else
        ok "the data-dir verdict's appliance wording names no host verb (#1776)"
    fi

    # The appliance wording NAMES which of these dirs the dashboard can repoint, so it is a claim
    # about CONTROL_DASHBOARD_CONFIRM_KEYS -- and the first draft of it ("no dashboard control
    # relocates a data directory") was false for four of the five keys the check fires on. Derive
    # both sets from the shipped artifact rather than restating them, so an allowlist change reds
    # HERE and names the string to rewrite, instead of leaving an operator a remedy they lack.
    _dd_in_set() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac }
    _dd_repointable() {
        local _k _out=''
        for _k in $1; do _dd_in_set "$_k" "$2" && _out="${_out:+$_out }$_k"; done
        printf '%s' "$_out"
    }
    _dd_all=$(sed -n 's/^ *for var in \(.*_DATA_DIR\); do$/\1/p' "$STACK" | head -1)
    _dd_conf=$(awk "/^CONTROL_DASHBOARD_CONFIRM_KEYS='/{f=1} f{print} f && /'[[:space:]]*\$/ && NR>1{exit}" "$STACK" |
        tr -d "\n'" | sed "s/^CONTROL_DASHBOARD_CONFIRM_KEYS=//;s/  */ /g;s/^ //")
    # THE CONTROL. Both rows below are equality claims over that computation, and an extractor that
    # silently returned nothing would make them agree on "" and score green. So run it once more
    # against an allowlist that DOES carry the tor key: the answer must MOVE.
    if [ "$(_dd_repointable "$_dd_all" "$_dd_conf TOR_DATA_DIR")" = "$(_dd_repointable "$_dd_all" "$_dd_conf")" ]; then
        bad "control: the repointable-set computation can give another answer (#1776)" "seeding TOR_DATA_DIR onto the allowlist did not move it; keys='$_dd_all' allow='$_dd_conf'"
    else
        ok "control: the repointable-set computation can give another answer (#1776)"
    fi
    assert_eq "the dirs doctor warns about that the dashboard CAN repoint (#1776)" \
        "$(_dd_repointable "$_dd_all" "$_dd_conf")" \
        "MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR DASHBOARD_DATA_DIR"
    assert_eq "the dirs doctor warns about that it CANNOT (#1776)" \
        "$(_dd_repointable "$_dd_all" "$(printf '%s' "$_dd_all" | tr ' ' '\n' | grep -vxF -f <(printf '%s' "$_dd_conf" | tr ' ' '\n') | tr '\n' ' ')")" \
        "TOR_DATA_DIR"
    # ...and that the wording actually carries both halves. If either row above reds, THIS is the
    # string that has to be rewritten, so name it here rather than only in the assertion text.
    case "$_dd_appl" in
    *"repointed from the config page"*) ok "the appliance wording offers the dashboard route (#1776)" ;;
    *) bad "the appliance wording offers the dashboard route (#1776)" "no config-page route in: $_dd_appl" ;;
    esac
    case "$_dd_appl" in
    *"tor data dir cannot"*) ok "the appliance wording excepts the one dir that cannot (#1776)" ;;
    *) bad "the appliance wording excepts the one dir that cannot (#1776)" "TOR_DATA_DIR is on neither allowlist and the wording does not say so: $_dd_appl" ;;
    esac
fi

# 3. Totality over the SHIPPED artifact. The SITES are enumerated mechanically out of the built
#    `pithead` rather than from a list kept by hand -- a hand list is blind to the site nobody
#    remembered, and this sweep found nine of those. A PLAIN dr_fail/dr_warn/dr_info literal is one
#    with no appliance side at all, so if it names a CLI verb an appliance operator is told to run
#    it. `dr_*_surface` calls do not match the pattern: their host argument is supposed to keep the
#    verb. The one exemption carries its reason in the source line itself.
#
#    KNOW WHAT THIS DOES NOT COVER. The site enumeration is mechanical; the NEEDLE list below is
#    not. It catches the verb forms doctor uses today, so a verdict phrased with a token nobody
#    listed -- a `systemctl` this file never learned, a new console noun -- passes it clean. A green
#    result here means "none of the KNOWN verb forms leaked", never "no verb leaked". Extend the
#    alternation when doctor learns a new way to tell someone to do something.
#
#    AND IT IS LITERAL-ONLY, which is the blind spot extending the alternation does NOT close. The
#    site pattern needs a quoted message on the same line, so a verdict whose text arrives in a
#    VARIABLE can never be reached by any needle: 05-doctor-checks.sh:111 (dr_warn "$(head -n 1
#    ...)", appliance-only by construction, text from the hugepages helper), 20-doctor-install-
#    checks.sh:28 (dr_warn "$msg") and 21-doctor-stack-checks.sh:261 (dr_fail "${verdict#fail:}").
#    Those three are unguarded here today and cannot be guarded here — read them by hand. One of
#    them is not merely unguarded but LEAKING: 20-doctor-install-checks.sh:28 builds a message at
#    :27 naming three remedies (firewall it to your LAN, set p2pool.stratum_bind, require a
#    p2pool.stratum_password) and an appliance operator can reach none of them — neither key is in
#    CONTROL_DASHBOARD_EDITABLE_KEYS or CONTROL_DASHBOARD_CONFIRM_KEYS. Pre-existing, not this
#    change's doing, and narrow; recorded here so the hand-read starts with the one that is wrong.
dr_verb_leaks=$(grep -nE '(dr_fail|dr_warn|dr_info) "' "$STACK" |
    grep -E "\./pithead |docker compose |docker pull |docker-compose-v2|Start the Docker daemon|sudo |systemctl|git pull" |
    grep -v "appliance-unreachable" || true)
assert_eq "no plain doctor verdict still names a CLI verb (#1213)" \
    "$(printf '%s' "$dr_verb_leaks" | grep -c . || true)" "0"
[ -n "$dr_verb_leaks" ] && printf '    leaked: %s\n' "$dr_verb_leaks" | head -12 || true

# shellcheck source=tests/stack/test-lock-reinvoke-wiring.sh disable=SC2015
_d0=$((PASS + FAIL)) && source "$HERE/test-lock-reinvoke-wiring.sh" && domain_ran test-lock-reinvoke-wiring.sh "$_d0" "$?" || domain_ran test-lock-reinvoke-wiring.sh "$_d0" "$?"

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
