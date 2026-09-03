# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance identity domain (#1105 Phase 1, develop-v2 lane): who the appliance says it is, and
# everything the machine derives from that answer. The browsable name a headless setup resolves —
# never the bare hostname, which served a name no LAN client could look up; the ssh access derived
# from it, key-only and /run-resident, absent when disabled and refused outright when enabled with
# no key (#786); the control-runner units rendered into /run because the appliance's root is
# read-only (#791); and the TLS certificate that has to agree with the name list Caddy actually
# serves — that it exists whenever the Caddyfile names it, that its SAN list and Caddy's site list
# agree for a given identity (#1132), that appliance_site_names stays engine-free while the live
# check excludes proxy_net's gateway, that check_appliance_cert warns rather than fails when the
# engine cannot be asked, that it re-mints when the served names change and not otherwise, and
# that a wiped wizard spool re-arms so a retry keeps its TLS rather than making the console's
# printed fingerprint a lie (#1063).
# Sourced by tests/stack/run.sh.
#
# The block is contiguous and its source stanza sits at its exact former position, so execution
# order is unchanged — a pure relocation, not a regrouping.
#
# Taken deliberately, and worth naming because it is the one arguable member: the control-runner
# units rendering into /run (#791). Its topical neighbours — provision_control_runner's ownership
# and foreign-install guards — live in tests/stack/test-control-provisioning.sh, so a reader looking
# for control-runner work will find most of it there. It travels here because it is a consequence of
# the appliance's read-only root rather than of the control channel, and because it sits inside the
# contiguous run: excluding it would buy a tidier topic at the cost of the property that makes this
# cut cheap, namely that nothing executes in a different order afterwards. If a reviewer disagrees,
# moving it to a control file later is independent of this cut and costs one range.
#
# Left behind, deliberately: preflight_remote_nodes' dial-before-commit check, which follows this
# block and reads as identity-adjacent because provisioning is what consumes both. It belongs to
# the remote-node contract, not to who the machine is.
#
# `$WALLET` is read below and is not this file's to assume. lib.sh's two sandbox builders default it
# (build_val_sandbox, build_control_sandbox), and neither is called from here — so in the suite it
# survives only because an earlier run.sh section happened to build a sandbox first. Sourcing in
# place preserves that accident, which is why the suite is green with or without this line. Seed it
# from the same constant those builders use, so the file states its own dependency rather than
# inheriting one; `:-` keeps a caller's value, so nothing in the suite changes.
WALLET="${WALLET:-$VALID_PRIMARY}"

echo "== unit: headless setup resolves the appliance's browsable name, never the bare hostname =="
# 'interactive' with no terminal is an EOF that silently picked $(hostname) — the appliance's
# dashboard then served a name no LAN client resolves (a bench machine showed a BLANK page:
# pithead.local hit Caddy's empty default vhost). No tty -> the non-interactive rules decide.
RDH=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    PITHEAD_APPLIANCE=1 DASHBOARD_HOST="" resolve_dashboard_host interactive </dev/null
    printf '%s' "$HOST_IP"
)
assert_eq "no tty + appliance -> <hostname>.local" "$RDH" "$(hostname).local"
unset RDH

echo "== unit: ssh access is derived — key-only, /run-resident, absent when disabled (#786) =="
SSHSB="$SANDBOX/sshsb"
mkdir -p "$SSHSB/bin" "$SSHSB/units" "$SSHSB/run"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SSHSB/bin/systemctl"
chmod +x "$SSHSB/bin/systemctl"
ssh_run() { # <config-json>
    printf '%s' "$1" >"$SSHSB/config.json"
    (
        cd "$SSHSB" || exit
        PATH="$SSHSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        sudo() { "$@"; }
        PITHEAD_APPLIANCE=1 PITHEAD_UNIT_DIR="$SSHSB/units" PITHEAD_SSH_RUN_DIR="$SSHSB/run/ssh" \
            CONFIG_FILE="$SSHSB/config.json" provision_ssh_access
    )
}
ssh_run '{"ssh":{"enabled":true,"authorized_key":"ssh-ed25519 AAAATEST key@test"}}'
grep -q "ssh-ed25519 AAAATEST" "$SSHSB/run/ssh/authorized_keys" 2>/dev/null &&
    ok "enabled -> the key lands in the runtime dir" || bad "enabled -> the key lands in the runtime dir" "missing"
grep -q "PasswordAuthentication=no" "$SSHSB/units/ssh.service.d/pithead.conf" 2>/dev/null &&
    ok "password auth is forced OFF in the unit override" || bad "password auth is forced OFF in the unit override" "missing"
ssh_run '{"ssh":{"enabled":false}}'
[ ! -e "$SSHSB/run/ssh" ] && [ ! -e "$SSHSB/units/ssh.service.d" ] &&
    ok "disabled -> key and override are REMOVED" || bad "disabled -> key and override are REMOVED" "residue"
unset SSHSB ssh_run

echo "== unit: ssh.enabled without a public key is refused at validation =="
VSB="$SANDBOX/vsb"
mkdir -p "$VSB"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "ssh":{"enabled":true} }' "$WALLET" >"$VSB/config.json"
vout=$(
    cd "$VSB" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    log() { :; }
    CONFIG_FILE="$VSB/config.json" parse_and_validate_config 2>&1
)
assert_contains "refusal names the missing key" "$vout" "ssh.authorized_key"
unset VSB vout

echo "== unit: on the appliance, control-runner units render into /run — root is read-only (#791) =="
# /etc/systemd/system cannot take a write on the appliance (RO root by design): apply died at
# 'tee: Read-only file system' on hardware, killing the ONLY post-setup management path. /run is
# a first-class unit dir, writable, and cleared every boot — fine, because these units are
# derived and the boot path re-renders them every boot. Enablement must be --runtime for the
# same reason (no symlinks under /etc either).
PCR791="$SANDBOX/pcr791"
mkdir -p "$PCR791/bin"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR791/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR791/bin/systemctl"
chmod +x "$PCR791/bin/uname" "$PCR791/bin/systemctl"
pcr791_run() { # <PITHEAD_APPLIANCE value> — run the install branch, echo recorded sudo calls
    (
        cd "$PCR791" || exit
        PATH="$PCR791/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        # a file, not a stream: the function /dev/null's both stdout AND stderr on some calls
        sudo() { echo "sudo:$*" >>"$PCR791/calls"; }
        PITHEAD_APPLIANCE="$1" CONTROL_DIR="$PCR791/control" DASHBOARD_CONTROL_ENABLED=true provision_control_runner
    )
}
: >"$PCR791/calls"
pcr791_run 1 >/dev/null 2>&1
appl_out=$(cat "$PCR791/calls")
assert_contains "appliance -> units written under /run/systemd/system" "$appl_out" "sudo:tee /run/systemd/system/pithead-control.service"
assert_contains "appliance -> enablement is --runtime" "$appl_out" "systemctl enable --runtime --now"
: >"$PCR791/calls"
PITHEAD_UNIT_DIR="$PCR791/units" pcr791_run 0 >/dev/null 2>&1
diy_out=$(cat "$PCR791/calls")
case "$diy_out" in
*"--runtime"*) bad "DIY keeps persistent /etc enablement (no --runtime)" "$diy_out" ;;
*) ok "DIY keeps persistent /etc enablement (no --runtime)" ;;
esac
unset PCR791 pcr791_run appl_out diy_out

echo "== unit: the dashboard certificate exists whenever the Caddyfile names it =="
# A machine that SKIPS the wizard (pre-seeded config, or a reinstall whose preserved /data
# already held config.json) still gets a certificate: the Caddyfile named a file only the wizard
# used to create, so Caddy answered :443 with no usable cert and the dashboard failed the TLS
# handshake outright — a bench machine looked hung while serving a broken listener.
TLSSB=$(mktemp -d)
export PITHEAD_TLS_DIR="$TLSSB/tls"
fp1=$(run_sourced "$SANDBOX" appliance_mint_cert 2>/dev/null)
[ -s "$TLSSB/tls/wizard.crt" ] && ok "mints a certificate on demand" || bad "mints a certificate on demand" "no crt"
[ -s "$TLSSB/tls/wizard.key" ] && ok "mints the matching key" || bad "mints the matching key" "no key"
assert_contains "prints a SHA-256 fingerprint" "$fp1" ":"
# Idempotent: the operator has already trusted this one, so a second call must NOT replace it.
fp2=$(run_sourced "$SANDBOX" appliance_mint_cert 2>/dev/null)
assert_eq "an existing certificate is reused, never replaced" "$fp2" "$fp1"
unset PITHEAD_TLS_DIR
rm -rf "$TLSSB"
unset TLSSB fp1 fp2

echo "== unit: the certificate SAN list and Caddy's site list agree, for a given identity (#1132) =="
# Three named disagreements this closes, all one root cause (two independent copies of the same
# expansion): (1) the cert always used `hostname` while site_hosts used dashboard.host when
# pinned; (2) pinning dashboard.host collapsed the site list to one host while the cert kept every
# address; (3) ".local" was unconditional in the cert, conditional in the site list. One shared
# builder (appliance_site_names) now feeds both consumers, so a given identity cannot produce two
# different name lists any more.
# MUTATION PROOF: hardcode site_hosts back to "$HOST_IP" in generate_caddyfile, or the old
# unconditional alt= string back into appliance_mint_cert, and every scenario below goes red.
NL=$(mktemp -d)
export PITHEAD_TLS_DIR="$NL/tls"
nl_render() { # sets $NL/Caddyfile and mints $NL/tls/wizard.crt for the given identity; prints the
    # canonical name list both consumers should agree on.
    (
        cd "$NL" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$NL_IPS"; else printf '%s' "$NL_HOSTNAME"; fi; }
        # Real (persistent) assignments, not command-prefix ones — appliance_site_names below
        # must see the SAME HOST_IP/DASHBOARD_HOST generate_caddyfile just rendered with, and a
        # prefix assignment scopes to one command only.
        # shellcheck disable=SC2034  # read by the sourced generate_caddyfile, unseen here
        DASHBOARD_SECURE=true
        # shellcheck disable=SC2034
        DASHBOARD_AUTH_HASH_B64=""
        # shellcheck disable=SC2034  # read by generate_caddyfile AND appliance_site_names, unseen here
        HOST_IP="$NL_HOST_IP"
        # shellcheck disable=SC2034
        DASHBOARD_HOST="${NL_DASHBOARD_HOST:-}"
        generate_caddyfile >/dev/null 2>&1
        appliance_site_names
    )
}
nl_assert_agreement() { # <scenario-label> — every name appliance_site_names() prints must be BOTH
    # served (in the Caddyfile) and certified (in the minted cert's SAN list).
    local names n cf cert bad_name=""
    names=$(nl_render)
    cf=$(cat "$NL/Caddyfile" 2>/dev/null)
    cert=$(openssl x509 -in "$NL/tls/wizard.crt" -noout -ext subjectAltName 2>/dev/null)
    for n in $names; do
        case "$cf" in
        *"https://$n,"* | *"https://$n "*) ;;
        *) bad_name="$n (not served)" ;;
        esac
        case ",$cert," in
        *"DNS:$n"* | *"IP:$n"* | *"IP Address:$n"*) ;;
        *) bad_name="${bad_name:+$bad_name, }$n (not certified)" ;;
        esac
    done
    if [ -n "$bad_name" ]; then
        bad "$1: every name is both served and certified" "$bad_name"
    else
        ok "$1: every name is both served and certified"
    fi
}

# Disagreement #3: auto identity, HOST_IP already the .local form (resolve_dashboard_host's own
# answer for an appliance on "auto") — both consumers must agree the .local name is IN.
NL_HOSTNAME="rig1" NL_IPS="192.168.1.20" NL_HOST_IP="rig1.local" NL_DASHBOARD_HOST=""
nl_assert_agreement "auto identity"

# Disagreements #1 and #2: dashboard.host pinned to a name that is NOT this machine's hostname.
NL_HOSTNAME="rig1" NL_IPS="192.168.1.20" NL_HOST_IP="panel.example" NL_DASHBOARD_HOST="panel.example"
nl_assert_agreement "pinned dashboard.host"
# And the negative proof that makes #1/#2 concrete: the OLD cert always carried the machine's
# other names (hostname, .local, its IPs) regardless of the pin — assert neither consumer does
# that any more, not just that the pinned name is present in both.
pcf=$(cat "$NL/Caddyfile")
pcert=$(openssl x509 -in "$NL/tls/wizard.crt" -noout -ext subjectAltName 2>/dev/null)
case "$pcf$pcert" in
*rig1*) bad "pinned dashboard.host: neither consumer names the machine's OTHER identity" "still present: $pcf | $pcert" ;;
*) ok "pinned dashboard.host: neither consumer names the machine's OTHER identity" ;;
esac

unset -f nl_render nl_assert_agreement
rm -rf "$NL"
unset PITHEAD_TLS_DIR NL NL_HOSTNAME NL_IPS NL_HOST_IP NL_DASHBOARD_HOST pcf pcert

echo "== unit: appliance_site_names stays engine-free — proxy_net's gateway is NOT excluded there (#reboot-leg-fix) =="
# #1204 already excluded mining_net's gateway here (a known config literal, \${NETWORK_PREFIX}.1).
# proxy_net's is NOT excluded here on purpose, even though it needs the SAME kind of exclusion —
# see appliance_site_names' own header. This function runs from BOTH the mint (render, always
# BEFORE \`up\` creates either bridge) and, via check_appliance_cert, doctor (always AFTER \`up\`,
# inside the boot health-gate's retry loop) — an engine call here would make its answer depend on
# whether docker/podman happened to be reachable at the exact moment it ran, and #1065 reboots the
# box on a doctor FAIL. The live exclusion belongs ONLY to check_appliance_cert, the one caller who
# can turn "engine didn't answer" into a WARN instead of a guess (next block).
AST="$SANDBOX/appliance-site-test"
mkdir -p "$AST/bin"
ast_names() {
    (
        cd "$AST" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '192.168.1.50 172.28.0.1 172.19.0.1'; else printf 'coordinator'; fi; }
        # shellcheck disable=SC2034
        HOST_IP=""
        # shellcheck disable=SC2034
        NETWORK_PREFIX="172.28.0"
        # shellcheck disable=SC2034
        DASHBOARD_EXPOSE_PUBLIC_IP="false"
        # shellcheck disable=SC2034
        DASHBOARD_HOST=""
        appliance_site_names
    )
}
ast_out="$(ast_names)"
assert_not_contains "mining_net's gateway (the known literal) stays excluded here" "$ast_out" "172.28.0.1"
assert_contains "proxy_net's gateway is NOT excluded here — that exclusion moved to doctor" "$ast_out" "172.19.0.1"
assert_contains "the real LAN address is still there" "$ast_out" "192.168.1.50"
unset -f ast_names
rm -rf "$AST"
unset AST ast_out

echo "== unit: check_appliance_cert excludes proxy_net's gateway live, engine reachable (#reboot-leg-fix) =="
# pithead-boot's real sequence: render (which mints the certificate, appliance_mint_cert) runs
# BEFORE \`up\` — neither compose bridge exists yet, so the minted certificate never covers either
# gateway. doctor's health-gate loop calls check_appliance_cert() AFTER \`up\`, when a live
# hostname -I reports both gateways. Before this fix only mining_net's (config-known prefix) was
# excluded from that later, live re-derivation; proxy_net's auto-assigned gateway (#345) was a name
# doctor then considered SERVED that the pre-\`up\`-minted certificate never covered — dr_fail on a
# perfectly healthy, still-syncing box. That FAIL is exactly the "commit gate rejected a healthy
# still-syncing stack (over-tightened)" battery assertion this fixes, and independently, exactly
# what stranded the OS-update 'updated' verdict behind a boot health gate that never passed (#1051
# — a second investigation on this same #1204 regression, folded in here; see also #1210/#1218
# below).
#
# MUTATION PROOF: delete the proxy_net leg from check_appliance_cert's engine loop and "does not
# FAIL" below goes red.
CAB="$SANDBOX/certboot"
mkdir -p "$CAB/tls" "$CAB/bin"
cat >"$CAB/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = network ] && [ "$2" = inspect ] || exit 1
case "$3" in
mining_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.28.0.0/24","Gateway":"172.28.0.1"}]}}]' ;;
proxy_net) printf '%s' '[{"IPAM":{"Config":[{"Subnet":"172.19.0.0/16","Gateway":"172.19.0.1"}]}}]' ;;
*) exit 1 ;;
esac
EOF
chmod +x "$CAB/bin/docker"
printf '{"dashboard":{"host":"auto"}}' >"$CAB/config.json"
cab_run() { # <hostname -I answer> <mint|doctor>
    (
        cd "$CAB" || exit 1
        PATH="$CAB/bin:$PATH"
        export PITHEAD_ENGINE=docker
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$CAB/tls"; }
        env_get() {
            case "$1" in
            HOST_IP) printf 'rig1.local' ;;
            *) printf '' ;;
            esac
        }
        HOST_IP="rig1.local"
        CAB_IPS="$1"
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$CAB_IPS"; else printf 'rig1'; fi; }
        if [ "$2" = mint ]; then appliance_mint_cert >/dev/null; else check_appliance_cert 2>&1; fi
    )
}
# The pre-\`up\` render/mint — only the LAN address, neither bridge exists yet.
cab_run "192.168.1.20" mint >/dev/null
# doctor, after \`up\` — both bridges now show up in hostname -I, and the engine can vouch for both.
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "doctor after \`up\` still says the cert covers every name" "$out" "covers every name"
assert_not_contains "doctor after \`up\` does not FAIL a healthy, pre-\`up\`-minted cert" "$out" "FAIL"
assert_not_contains "the engine answered, so no WARN is owed either" "$out" "WARN"

# A GENUINE mismatch must still FAIL — this fix must not neuter #1141's own coverage check. An
# address that is neither the base, localhost, nor a confirmed bridge gateway is a real gap.
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1 10.55.55.55" doctor)
assert_contains "a genuinely uncovered LAN address still FAILs (#1141 not neutered)" "$out" "FAIL"
assert_contains "the FAIL names the real gap" "$out" "10.55.55.55"

echo "== unit: check_appliance_cert WARNs (never FAILs) when the engine can't be asked — the security-review blocker =="
# Demonstrated live by the reviewer with a stubbed daemon-unreachable docker: bridge INTERFACES
# outlive an engine blip, so hostname -I keeps reporting both gateways whether or not the engine is
# there to explain them. Reading "the engine didn't answer" as "nothing to exclude" would FAIL a
# perfectly healthy box on a transient engine hiccup — worse than the pre-fix bug, because #1065
# then reboots it, and the failure now looks intermittent instead of the deterministic, explicable
# bug #1204 shipped. #1204's own philosophy for the analogous unreadable-certificate-file case: a
# TOOLING problem WARNs, a certificate found with a real problem FAILs.
#
# MUTATION PROOF: replace the "if \$engine_ok != 1" branch with "if false" (verified by hand — the
# real repro this test encodes) and this reproduces the exact regression: FAIL on a healthy box
# during an engine hiccup.
cat >"$CAB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
exit 1
EOF
chmod +x "$CAB/bin/docker"
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "engine unreachable post-\`up\` -> WARN, naming the tooling gap" "$out" "WARN"
assert_not_contains "engine unreachable post-\`up\` -> never FAILs a healthy box" "$out" "FAIL"

# The base name is NOT excused by an unreachable engine — it needs no live state to derive, so an
# uncovered base name is always a real, actionable problem.
printf 'not a certificate' >"$CAB/tls/wizard.crt"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$CAB/tls/wizard.key" \
    -out "$CAB/tls/wizard.crt" -subj "/CN=other" -addext "subjectAltName=DNS:somethingelse" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
out=$(cab_run "192.168.1.20 172.28.0.1 172.19.0.1" doctor)
assert_contains "an uncovered BASE name still FAILs even with the engine unreachable" "$out" "FAIL"
assert_contains "the FAIL names the base" "$out" "rig1.local"

# Nothing extra to explain (dashboard.host pinned collapses the auto-expansion to just the base,
# per appliance_site_names' own "an explicit pin stays a single name on purpose" rule) -> an
# unreachable engine is never even consulted, so no spurious WARN either. check_appliance_cert
# re-derives DASHBOARD_HOST from $CONFIG_FILE itself (never trusts a caller-set variable — see its
# own comment), so the pin has to be staged there, not just passed as a local override.
printf '{"dashboard":{"host":"rig1.local"}}' >"$CAB/config.json"
cab_run_pinned() {
    (
        cd "$CAB" || exit 1
        PATH="$CAB/bin:$PATH"
        export PITHEAD_ENGINE=docker
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        appliance_tls_dir() { printf '%s' "$CAB/tls"; }
        env_get() {
            case "$1" in
            HOST_IP) printf 'rig1.local' ;;
            *) printf '' ;;
            esac
        }
        HOST_IP="rig1.local"
        hostname() { if [ "${1:-}" = "-I" ]; then printf '192.168.1.20 172.28.0.1 172.19.0.1'; else printf 'rig1'; fi; }
        check_appliance_cert 2>&1
    )
}
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$CAB/tls/wizard.key" \
    -out "$CAB/tls/wizard.crt" -subj "/CN=rig1.local" -addext "subjectAltName=DNS:rig1.local" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1
out=$(cab_run_pinned)
assert_not_contains "a pinned dashboard.host is verified — no engine dependency to bypass into a WARN" "$out" "WARN"
assert_not_contains "a pinned dashboard.host that IS covered -> no FAIL" "$out" "FAIL"
unset -f cab_run cab_run_pinned
rm -rf "$CAB"
unset CAB out

echo "== unit: the certificate re-mints when the served name list changes, not otherwise (#1132) =="
# Compare, don't date-guess: the minted SAN list is derived from the certificate itself (openssl)
# and set-compared against the machine's current name list. An operator who has pinned this
# fingerprint loses that trust on every unnecessary replacement, so a re-mint must be conservative.
# MUTATION PROOF: drop the comparison (always re-mint) -> "an unchanged list does not re-mint"
# goes red. Drop the re-mint branch (never re-mint) -> "a changed list re-mints" goes red.
RM=$(mktemp -d)
export PITHEAD_TLS_DIR="$RM/tls"
RM_IPS="192.168.1.20"
rm_run() {
    (
        cd "$RM" || exit 1
        # shellcheck disable=SC1090
        source "$STACK" 2>/dev/null
        set +e
        is_appliance() { return 0; }
        hostname() { if [ "${1:-}" = "-I" ]; then printf '%s' "$RM_IPS"; else printf 'rig1'; fi; }
        appliance_mint_cert
    )
}
rm_fp1=$(rm_run 2>/dev/null)
assert_contains "mints a certificate" "$rm_fp1" ":"
rm_fp2=$(rm_run 2>/dev/null)
assert_eq "an unchanged name list does not re-mint" "$rm_fp2" "$rm_fp1"
RM_IPS="10.0.0.99" # the DHCP lease moved
rm_out=$(rm_run 2>&1)
assert_contains "a changed name list logs a re-mint" "$rm_out" "Re-minting the dashboard certificate"
rm_fp3=$(rm_run 2>/dev/null)
case "$rm_fp3" in
"$rm_fp1") bad "a changed name list re-mints" "fingerprint unchanged after the lease moved: $rm_fp3" ;;
*) ok "a changed name list re-mints" ;;
esac
rm_fp4=$(rm_run 2>/dev/null)
assert_eq "the new certificate is then stable across repeat renders" "$rm_fp4" "$rm_fp3"
unset -f rm_run
rm -rf "$RM"
unset PITHEAD_TLS_DIR RM RM_IPS rm_fp1 rm_fp2 rm_fp3 rm_fp4 rm_out

echo "== unit: stage_wizard_spool re-arms a wiped spool, so a retry keeps its TLS (#1063) =="
# The accept path removes the whole spool before provisioning. Staging used to run ONCE before the
# loop, so a provisioning failure re-entered it with the certificate, the reference schema and the
# rig pre-fill gone — and wizard.py gates TLS on the cert FILE existing, so the retry served the
# setup page (payout address, dashboard password, node secrets) in CLEARTEXT while the console
# still advertised HTTPS and a fingerprint. MUTATION PROOF: stage once before the loop again and
# "a wiped spool is fully re-armed" + "the retry can still serve TLS" go red.
SWS=$(mktemp -d)
export PITHEAD_TLS_DIR="$SWS/tls"
sws_fp=$(run_sourced "$ROOT" stage_wizard_spool "$SWS/spool" 2>/dev/null)
assert_contains "staging prints the certificate fingerprint the console advertises" "$sws_fp" ":"
# data-wiped.json is checked for EXISTENCE only here (present/absent) — its content is always
# "{}" off the appliance (PITHEAD_PRESEED_DIR unset), so that assertion belongs with the
# data_wipe_note/publish_data_wipe_note tests below, not this staging-plumbing check.
for f in wizard.crt wizard.key config.reference.json rig-defaults.json data-wiped.json; do
    assert_eq "staged: $f" "$([ -s "$SWS/spool/$f" ] && echo present || echo absent)" "present"
done
# The accept path's teardown, exactly as it happens, then the retry the outer loop drives.
rm -rf "$SWS/spool"
sws_fp2=$(run_sourced "$ROOT" stage_wizard_spool "$SWS/spool" 2>/dev/null)
sws_missing=""
for f in wizard.crt wizard.key config.reference.json rig-defaults.json data-wiped.json; do
    [ -s "$SWS/spool/$f" ] || sws_missing="$sws_missing $f"
done
assert_eq "a wiped spool is fully re-armed" "${sws_missing:-none}" "none"
assert_eq "the retry can still serve TLS — the cert the container is pointed at exists" \
    "$([ -s "$SWS/spool/wizard.crt" ] && [ -s "$SWS/spool/wizard.key" ] && echo yes || echo no)" "yes"
# One machine, one certificate: the operator already trusted this fingerprint, and a retry that
# minted a fresh one would make the console's printed fingerprint a lie in the other direction.
assert_eq "the fingerprint survives the retry" "$sws_fp2" "$sws_fp"
# And the loop must actually call it per session — staging that only a caller could reach is the
# bug this fixes. MUTATION PROOF: delete the call from the loop and this goes red.
assert_contains "the wizard loop re-stages every session" "$(cat "$STACK")" 'cert_fp=$(stage_wizard_spool "$spool")'
unset PITHEAD_TLS_DIR
rm -rf "$SWS"
unset SWS sws_fp sws_fp2 sws_missing
