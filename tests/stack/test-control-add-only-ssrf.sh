# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The approval gate (#33): the control channel's default-deny on security-sensitive changes,
# reunited into one file (#1105 R13), together with workers.list[]'s add-only exception (#893's
# click-to-adopt) and the #122 SSRF floor on what a newly-appended entry may point at
# (_control_host_is_internal). The gate's own contract is stated at its section header below.
#
# WHY ONE FILE. The add-only/SSRF battery was split out of the approval-gate section for the
# file-budget ratchet (#1105 Phase 0) while the rest stayed in run.sh, so one domain had two homes.
# R13 brings the rest here, order preserved exactly: what ran BEFORE the old source stanza sits
# above the add-only battery, what ran AFTER it sits below, run.sh sources it from that position.
#
# SELF-ARMING, AND WHY THAT IS SAFE IN POSITION. This file builds its own control sandbox and
# derives its own spool paths, so it is sourceable standalone: of the names it reads but never
# assigns, $ROOT and $VALID_TARI are top-level lib.sh constants, and $C, $CTRL_LOG and $WALLET are
# assigned inside build_control_sandbox(), which this file now calls itself. In position the arm
# changes nothing — $C is the fixed path "$SANDBOX/control", the builder's mkdir -p only creates,
# its copies are static repo inputs no earlier section rewrites, and seed_control_env/control_config
# are DEFINED inside it and never called, so it writes no config.json and touches nothing under
# data/control/; the spool paths below re-derive to the values test-control-core.sh already set, and
# the baseline this domain depends on is seeded by its own first block from the host CLI. It
# therefore does not borrow another section's ambient fixtures. An earlier header here claimed it
# shared them "exactly like test-control-deploy.sh shares its own section's"; that precedent was
# false — that file's own header states its sections are fully self-contained (#1462).
#
# WHAT OUTLIVES THE SOURCE. gate_try() and $UUID5 are defined here and not unset at the end, so they
# outlive the source as they outlived the old in-run.sh position: the editable-allowlist domain file
# run.sh sources next reads both, as test-spool-audit.sh reuses $UUID5. Hence the stanza stays put.
#
# MUTATION PROOF: reverting pithead's add-only prefix check back to "refuse any workers.list
# diff" turns the ADD-ONLY-append assertion red; reverting _control_host_is_internal's
# trailing-dot strip or narrowing its alias set back to bare "localhost" turns the
# corresponding assert_new_worker_host_refused case red (each names which). Round 5's
# resolve-and-check battery (below) names its own mutation kills at each assertion.

build_control_sandbox
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"
STAGED="$C/data/control/staged"
AUDIT="$C/data/control/audit/control.log"

echo "== black-box: approval gate default-denies security-control changes (#33 re-review) =="
# describe_change flags only the ENABLE/CHANGE direction of security controls as DEST — disabling
# dashboard auth, downgrading onion client-auth, clearing the stratum password or repointing the
# Telegram bot are all INFO rows. The gate must refuse those on the explicit sensitive-key set,
# independent of the DEST flag; a non-security change must still pass.
UUID5="55555555-5555-4555-8555-555555555555"
# Baseline: nano pool + stratum password + telegram bot + control, applied from the host CLI.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano",stratum_password:"s3cretpw"},
    telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
               control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
gate_try() { # <candidate-json-file> [confirm-token] — preview then commit via the spool; result lands in $RESULTS/$UUID5.json
    # An optional second arg carries a typed confirmation ("APPLY") on the commit, so a PERIMETER case
    # can prove the change stays refused EVEN WITH a valid token present. Omitted → token-less commit.
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
    if [ -n "${2:-}" ]; then
        printf '{"id":"%s","action":"commit","actor":"admin","confirm":"%s"}\n' "$UUID5" "$2" >"$REQS/$UUID5.json"
    else
        printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
    fi
    run_pending >/dev/null
}

# Disable the dashboard login (auth.password:"" needs control:false to pass validation): the
# preview flags destructive:false — proof the DEST path alone would wave it through — and the
# commit must still be refused, config untouched.
jq '.dashboard.auth={username:"admin"} | .dashboard.control={enabled:false}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "auth-disable previews destructive:false (DEST alone would allow it)" \
    "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "dashboard-login disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "auth-disable refusal names the sensitive-key gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the dashboard password" "$(jq -r '.dashboard.auth.password' "$C/config.json")" "a control passphrase"
assert_eq "config.json keeps control enabled" "$(jq -r '.dashboard.control.enabled' "$C/config.json")" "true"

# Clear the stratum access password (disable direction is an INFO row) — refused.
jq 'del(.p2pool.stratum_password)' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "stratum-password disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the stratum password" "$(jq -r '.p2pool.stratum_password' "$C/config.json")" "s3cretpw"

# Repoint the Telegram bot (token change is an INFO row; the bot is the future #338 approval
# channel, so an attacker must not swap it) — refused.
jq '.telegram.bot_token="654321:evil-XYZ_abc"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "telegram bot_token repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the original bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Downgrade the onion to password-only (client_auth:false is an INFO row in every direction).
# Baseline first: onion on + client_auth on (the only combo valid with control on), applied.
jq '.dashboard.onion={enabled:true,client_auth:true}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_contains "onion baseline applied (client_auth on)" "$(cat "$C/.env")" "DASHBOARD_ONION_CLIENT_AUTH=true"
jq '.dashboard.onion.client_auth=false | .dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "onion client-auth downgrade commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps onion client-auth on" "$(jq -r '.dashboard.onion.client_auth' "$C/config.json")" "true"

# TRUE default-deny (#33 re-review round 2): the gate is an ALLOWLIST of editable keys, not a
# blocklist of sensitive ones, so a key nobody thought to enumerate still refuses. Each candidate
# below was committable under the blocklist gate — these assertions are the teeth.
# p2pool clearnet flip: dials sidechain peers over clearnet, deanonymizing the host IP, no
# auto-revert.
jq '.p2pool.clearnet=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "p2pool clearnet flip commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps p2pool on Tor" "$(jq -r '.p2pool.clearnet // false' "$C/config.json")" "false"
# XvB stats over clearnet: correlates the host IP with the payout wallet.
jq '.xvb.tor=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb tor-disable commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps xvb on Tor" "$(jq -r '.xvb.tor // true' "$C/config.json")" "true"
# Healthchecks ping-URL repoint: exfiltrates liveness / silences the dead-man's switch.
jq '.healthchecks={ping_url:"https://attacker.example/ping"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "healthchecks ping-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps healthchecks unset" "$(jq -r '.healthchecks.ping_url // "unset"' "$C/config.json")" "unset"
# The #719 perimeter, named explicitly: disabling the Tor egress firewall would let containers dial
# clearnet — it is NOT in the confirm-gated set and stays host-only. Commit WITH a valid APPLY token
# to prove the typed confirmation does not unlock the perimeter — the refusal fires before the token
# is ever examined, so it stays refused just as it does token-less (#719).
jq '.network={tor_egress_firewall:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "tor-egress-firewall disable commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tor-egress refusal is a host-only gate (the APPLY token did not unlock it)" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the tor egress firewall unset (defaults on)" "$(jq -r '.network.tor_egress_firewall // "unset"' "$C/config.json")" "unset"
# Setting a Monero view key (the #381 payout-confirm secret) reveals every incoming amount — a
# secret, host-only, never confirm-gated. Commit WITH a valid APPLY token: the perimeter gate must
# still refuse it, proving the typed confirmation is UX friction, not a security bypass (#719).
jq '.monero.view_key="deadbeef"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "monero view-key set commit is refused even with the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json gains no view key" "$(jq -r '.monero.view_key // "unset"' "$C/config.json")" "unset"
# XvB pool-URL repoint: redirects donated hashrate to an attacker's pool.
jq '.xvb.url="attacker.example:4247"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "xvb pool-url repoint commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the default xvb url" "$(jq -r '.xvb.url // "unset"' "$C/config.json")" "unset"
# The tamper-evidence alert toggles stay host-only even though sibling event toggles are
# editable: silencing WALLET_CHANGED would blind the future #338 approval channel.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "wallet-changed alert silencing is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
# An allowlisted operational toggle on the same baseline still commits.
jq '.telegram.events={node_down:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "allowlisted alert toggle still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "alert toggle landed in config.json" "$(jq -r '.telegram.events.node_down' "$C/config.json")" "false"
# dashboard.workers (#172) was the alias removed in 2.0.0 (#1832). It never rendered to .env, so
# the env-diff allowlist cannot see it, yet a committed attacker host would point token-bearing
# probes at it. Its explicit refusal went with the alias and the closed-schema check now refuses it
# as an unknown key — the same outcome by a different door, so the row is kept, not deleted.
jq '.dashboard.workers=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a removed 1.x alias commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the refusal names dashboard.workers as a schema-unknown key" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "dashboard.workers"
assert_contains "the refusal is the closed-schema door, not the descriptor door" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema"
assert_eq "config.json keeps no worker descriptors" "$(jq -r '.dashboard.workers // "unset"' "$C/config.json")" "unset"

# workers.list[] (#506): the same descriptors, but with ONE add-only
# exception — a commit may APPEND a new descriptor; every live entry must reappear byte-for-byte.
# Seed one from the host CLI (never the gate) as the baseline to protect.
jq '.workers.list=[{name:"rig1",host:"10.0.0.9",control_port:8082,token:"tok_rig1"}]' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_eq "workers.list seed applies from the host CLI" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1"

# REPOINT (the #122-class escalation add-only must never permit) and REMOVAL are both refused;
# APPEND of a brand-new second entry, rig1 byte-for-byte unchanged, is the one shape now allowed.
jq '.workers.list=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list REPOINT of an existing entry is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the seeded rig1 host after the repoint attempt" "$(jq -r '.workers.list[0].host' "$C/config.json")" "10.0.0.9"
jq '.workers.list=[]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list REMOVAL of an existing entry is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
jq '.workers.list += [{name:"rig2",host:"192.168.1.50",control_port:8082,token:"tok_rig2"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list ADD-ONLY append of a new rig is allowed" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json keeps rig1 and gains rig2" "$(jq -c '[.workers.list[].host]' "$C/config.json")" '["10.0.0.9","192.168.1.50"]'

# NEGATIVE — the #122 SSRF floor on a NEWLY appended entry (_control_host_is_internal): a
# compromised dashboard could otherwise append a phantom descriptor at this host's own loopback or
# a sibling container, then dial it (attacker bearer) via worker-apply/worker-upgrade, which
# resolves strictly from THIS config.json. A rejection never touches config.json, so rig1+rig2
# stays the baseline below — including the "localhost" family (a bare-string check misses the
# /etc/hosts aliases + root-terminated spelling; curl-verified to resolve to loopback here) and a
# numeric encoding curl's own address parser accepts identically to dotted-decimal.
assert_new_worker_host_refused() { # <host> <label>
    jq --arg h "$1" '.workers.list += [{name:"evil",host:$h,control_port:8000,token:"attacker"}]' "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "new-rig append pointed at $2 is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
}
assert_new_worker_host_refused "127.0.0.1" "loopback"
assert_new_worker_host_refused "172.28.0.5" "the stack's own docker-bridge subnet"
assert_new_worker_host_refused "localhost." "a root-terminated localhost spelling"
assert_new_worker_host_refused "LOCALHOST." "the same, uppercase"
assert_new_worker_host_refused "localhost.localdomain" "the RHEL-family /etc/hosts loopback alias"
assert_new_worker_host_refused "ip6-localhost" "the Debian-family /etc/hosts ::1 alias"
assert_new_worker_host_refused "ip6-loopback" "the Debian-family /etc/hosts ::1 alias (second name)"
assert_new_worker_host_refused "2130706433" "a bare-decimal-integer encoding of loopback"
assert_eq "config.json still has exactly rig1+rig2 after every SSRF refusal above" \
    "$(jq -r '.workers.list | length' "$C/config.json")" "2"
unset -f assert_new_worker_host_refused

# POSITIVE control: an ordinary LAN address — the feature's whole purpose — is unaffected.
jq '.workers.list += [{name:"rig3",host:"10.0.0.50",control_port:8082,token:"tok_rig3"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list append of an ordinary LAN address still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json gains the third, ordinary-LAN rig" "$(jq -r '.workers.list[2].host' "$C/config.json")" "10.0.0.50"

# #893 round 5: an independent review found the battery above was still a STRING classifier under
# the hood — it can refuse "127.0.0.1" and "localhost" by literal shape, but it can never answer
# "does THIS HOSTNAME resolve to my own loopback": this host's own Debian self-entry (a box named
# "gouda" resolves its own hostname to 127.0.1.1 via /etc/hosts — a real, everyday case, not a
# contrived one) and an attacker-controlled DNS name pointed at 127.0.0.1 both looked like "a
# genuine hostname, therefore safe" to a spelling denylist — verified live with curl and getent.
# The fix rebuilt _control_host_is_internal as RESOLVE-AND-CHECK: anything that isn't already a
# canonical IPv4 literal is resolved (both A and AAAA), and EVERY returned address is checked, not
# just the first.
#
# The harness can't do real DNS, so this battery installs a fake `getent` ahead of the real one on
# $C/bin (already on PATH for every gate_try/run_pending call in this section — see lib.sh's
# run_pending) that answers only the names mapped below in dns-map.txt, one "name ip[,ip...]" line
# each; a mapped name with no IP field simulates a resolution failure. Anything NOT in the map
# falls through to the REAL system getent untouched — this never masks an unrelated lookup, and
# every case in the battery above already ran against the real, unstubbed resolver.
GETENT_MAP="$C/dns-map.txt"
: >"$GETENT_MAP"
cat >"$C/bin/getent" <<GETENT_STUB
#!/usr/bin/env bash
# Test-only DNS stub for #893 round 5's resolve-and-check seam (tests/stack/test-control-add-only-ssrf.sh).
if [ "\$1" = "ahosts" ] && [ -f "$GETENT_MAP" ]; then
    hit=\$(awk -v n="\$2" '\$1 == n {print; exit}' "$GETENT_MAP")
    if [ -n "\$hit" ]; then
        ips="\${hit#* }"
        [ "\$ips" = "\$hit" ] && exit 2 # mapped with no IP field -> simulate a resolution failure
        IFS=',' read -r -a arr <<<"\$ips"
        for ip in "\${arr[@]}"; do printf '%s STREAM %s\n' "\$ip" "\$2"; done
        exit 0
    fi
fi
exec /usr/bin/getent "\$@"
GETENT_STUB
chmod +x "$C/bin/getent"

assert_resolved_worker_host_refused() { # <name> <ip-list-or-empty> <label>
    if [ -n "$2" ]; then printf '%s %s\n' "$1" "$2"; else printf '%s\n' "$1"; fi >>"$GETENT_MAP"
    jq --arg h "$1" '.workers.list += [{name:"evil-dns",host:$h,control_port:8000,token:"attacker"}]' "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "new-rig append resolving to $3 is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
}
# MUTATION KILL: narrowing _ipv4_is_sensitive's loopback case from "0 | 127" (all of 127.0.0.0/8)
# back to a single literal address turns this one red — 127.0.1.1 isn't 127.0.0.1.
assert_resolved_worker_host_refused "rig-gouda-alias" "127.0.1.1" "this host's own Debian self-entry style address (127.0.1.1)"
# MUTATION KILL: reverting _control_host_is_internal's dispatch back to the round 1-4 STRING
# classifier (drop the resolver call, fall back to "a genuine hostname is never re-checked") turns
# this one red — "attacker-dns-name" carries no denylistable spelling at all.
assert_resolved_worker_host_refused "attacker-dns-name" "127.0.0.1" "an attacker-controlled DNS name pointed at loopback"
# MUTATION KILL: same string-classifier reversion, or narrowing the 169.254.0.0/16 link-local
# check to the bare metadata address, turns this one red.
assert_resolved_worker_host_refused "metadata-alias" "169.254.169.254" "a name resolving to the cloud-metadata address"
# MUTATION KILL: checking only the FIRST resolved address (e.g. `head -1` instead of the while-read
# loop over every line) turns this one red — the public IP sorts/lists first, the loopback second.
assert_resolved_worker_host_refused "mixed-answer-name" "203.0.113.5,127.0.0.1" "a multi-answer name where only the SECOND address is sensitive"
# MUTATION KILL: flipping the resolver-failure branch from `|| return 0` (fail closed) to
# `|| return 1` (fail open — "must not resolve, so it can't be internal") turns this one red.
assert_resolved_worker_host_refused "name-that-fails-to-resolve" "" "a name resolution fails on (fail-closed)"
unset -f assert_resolved_worker_host_refused
assert_eq "config.json still has exactly rig1+rig2+rig3 after every round-5 SSRF refusal above" \
    "$(jq -r '.workers.list | length' "$C/config.json")" "3"

# POSITIVE control, round 5: a genuine LAN rig reached BY NAME (not a literal) still applies —
# resolve-and-check must not turn into "refuse every hostname". MUTATION KILL: an over-broad
# sensitivity check (e.g. refusing all of 192.168.0.0/16, not just this host's own bridge subnet)
# turns this one red.
printf 'real-lan-rig-by-name 192.168.1.77\n' >>"$GETENT_MAP"
jq '.workers.list += [{name:"rig4",host:"real-lan-rig-by-name",control_port:8082,token:"tok_rig4"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "workers.list append of a LAN address reached BY NAME still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json gains the fourth rig, resolved from its name" "$(jq -r '.workers.list[3].host' "$C/config.json")" "real-lan-rig-by-name"

# Tidy up the test-only stub so later sections in this same $C sandbox see the real system
# resolver again — nothing else in this suite calls getent today, but there's no reason to leave a
# DNS-intercepting stub lying around past the battery that needed it.
rm -f "$C/bin/getent" "$GETENT_MAP"

# dashboard.energy (#504) is the ONE config.json-only block a commit MAY change: it never renders
# to .env, so the host previews it as a normal INFO row (not the old non-committable HOST note) and
# the commit lands it in config.json. Preview first to assert the committable row + non-destructive.
jq '.dashboard.energy={cost_per_kwh:0.18,currency:"EUR",xmr_price:142.5}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy preview status" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_contains "energy preview carries a committable change row" "$(jq -r '.changes[] | select(.key=="dashboard.energy") | .flag' "$RESULTS/$UUID5.json" 2>/dev/null)" "INFO"
assert_eq "energy edit alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID5.json" 2>/dev/null)" "false"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "energy edit commits" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "energy cost landed in config.json" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
assert_eq "energy currency landed in config.json" "$(jq -r '.dashboard.energy.currency' "$C/config.json")" "EUR"
assert_contains "energy commit audits the synthetic key name (#504)" "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"

# Unedited editor round-trip (#696): the form serves the reference-merged config and posts the
# merged document back, so a save with NO edits must preview as zero changes. The live energy
# block above is partial — the merge materializes the remaining reference defaults (tari_price,
# price_feed) into the staged copy, and defaults against an absent value are the same settings,
# not an "Energy calculator settings updated" row.
UUIDE="55555555-5555-4555-8555-555555555555"
jq -s --arg id "$UUIDE" '{id:$id, action:"preview", actor:"admin",
    config:((.[0] | del(._docs)) * .[1])}' "$ROOT/config.reference.json" "$C/config.json" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip previews" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "previewed"
assert_eq "unedited merged round-trip shows zero changes (#696)" "$(jq -r '.changes | length' "$RESULTS/$UUIDE.json" 2>/dev/null)" "0"
# Audit leg of the same contract: committing that unedited round-trip must not record a phantom
# DASHBOARD_ENERGY key — the gate's audit comparison merges the reference defaults too (#696).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUIDE" >"$REQS/$UUIDE.json"
run_pending >/dev/null
assert_eq "unedited merged round-trip commits" "$(jq -r '.status' "$RESULTS/$UUIDE.json" 2>/dev/null)" "applied"
assert_not_contains "unedited commit audits no phantom DASHBOARD_ENERGY key (#696)" \
    "$(grep '"action":"commit","status":"applied"' "$AUDIT" | tail -n 1)" "DASHBOARD_ENERGY"
rm -f "$RESULTS/$UUIDE.json" "$STAGED/$UUIDE.json"

# NEGATIVE — the #504 security teeth: an energy edit BUNDLED with a change that is NOT on the env
# allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND) must be REFUSED. The energy exemption must
# not become a carrier for other config: the gate re-derives the env change set host-side and the
# allowlist catches the monero key even though the energy block is legitimately editable.
jq '.dashboard.energy={cost_per_kwh:0.25} | .monero.rpc_lan_access=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit bundled with a non-allowlisted key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "bundled refusal names the security-sensitive gate" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps monero LAN access off after the refusal" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
assert_eq "config.json keeps the previously-committed energy cost after the refusal" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"

# NEGATIVE — closed-schema smuggling (#33 hardening). An unrecognized config.json key renders to NO
# env var, so it emits ZERO porcelain rows: invisible to the env-diff allowlist, yet the commit's
# `cp` would persist it. The schema guard must refuse it. (a) A LEGIT energy edit bundled with a
# smuggled top-level key is refused whole, and the key never lands. (b) A config identical to live
# except for one extra key still refuses — an empty change set must not read as "clean".
jq '.dashboard.energy={cost_per_kwh:0.30} | .attacker_smuggled={payload:"pwned"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "energy edit smuggling an unknown top-level key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "smuggle refusal names the schema and the offending key" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema (attacker_smuggled"
assert_eq "config.json never gains the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
assert_eq "config.json keeps the pre-smuggle energy cost" "$(jq -r '.dashboard.energy.cost_per_kwh' "$C/config.json")" "0.18"
# Only an unknown key added — every rendered value byte-identical to live, so the porcelain is empty.
jq '.attacker_smuggled={payload:"x"}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "an otherwise-identical config with one extra key is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "empty-porcelain smuggle still names the schema guard" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "not in the schema"
assert_eq "config.json still free of the smuggled key" "$(jq -r 'has("attacker_smuggled")' "$C/config.json")" "false"
# A nested unknown key under a KNOWN block (dashboard.energy) is caught by the same guard.
jq '.dashboard.energy={cost_per_kwh:0.18,__evil:{x:1}}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a nested unknown key under a known block is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"

# A 1.x config is MIGRATED, not round-tripped (#1832) — this row asserted the opposite until 2.0.0,
# when config.reference.json listed xmrig_proxy.* so the block survived a commit untouched. Seed the
# legacy block, then prove a normal on-allowlist commit still passes AND that the apply moved it.
jq '.xmrig_proxy={enabled:true,url:"na.xmrvsbeast.com:4247",donor_id:"auto"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.xvb.donation_level="whale"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a commit on a config carrying a legacy xmrig_proxy block still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the allowlisted xvb tier landed in config.json" "$(jq -r '.xvb.donation_level' "$C/config.json")" "whale"
assert_eq "the legacy xmrig_proxy block is GONE after the migrating apply" "$(jq -r 'has("xmrig_proxy")' "$C/config.json")" "false"
assert_eq "its url landed under the current xvb name" "$(jq -r '.xvb.url' "$C/config.json")" "na.xmrvsbeast.com:4247"
assert_eq "the pre-migration copy is kept beside the config" "$(jq -r '.xmrig_proxy.url' "$C/config.json.bak-1x" 2>/dev/null)" "na.xmrvsbeast.com:4247"

# Forged-flag bypass: the container tampers its visible copy of the preview result to
# destructive:false AND sends a commit request carrying its own destructive:false field. The
# extra request key is rejected outright; a clean follow-up commit is still refused because the
# gate re-derives the change set host-side from the STAGED config — it never reads either flag.
jq '.telegram.bot_token="999999:forged-token"' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
printf '{"status":"previewed","changes":[],"destructive":false,"ts":0}\n' >"$RESULTS/$UUID5.json"
printf '{"id":"%s","action":"commit","actor":"admin","destructive":false}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "commit request smuggling a destructive flag is rejected" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "unexpected keys"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "commit after result-file tampering is still refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "tampered-flag refusal comes from the host-side re-derivation" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "security-sensitive"
assert_eq "config.json keeps the untampered bot token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "123456:legit-ABC_def"

# Sensitive keys PRESENT but UNCHANGED must not trip the gate: a plain pool-tier change on the
# same baseline (auth + onion + stratum password + telegram all set) still applies.
jq '.p2pool.pool="mini"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "non-security change on a security-laden config still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "pool tier change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"

# The node-endpoint tier (#1888), end to end through the real spool. The four endpoint keys left
# the never-committable perimeter for the confirm tier on the operator's ruling, and the host-side
# REACHABILITY PROBE is what was traded for that perimeter entry — so what has to be proven here is
# that the gate CALLS it. One variable moves per case: no token (the tier), token + an endpoint
# nothing answers on (the probe refuses), token + one that answers (it commits). Case 2 is the
# teeth — WITHOUT the probe that same commit applies — and case 3 is what stops a probe that
# refuses everything from reading as a pass.
cp "$C/config.json" "$C/nep-keep.json"
# A kernel-chosen port: two lanes may run this suite at once, so a fixed one would collide. The
# Tari leg of the probe is a bare TCP connect, so an accept()ing socket is all it needs to pass.
python3 -c 'import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(8)
sys.stdout.write("%d\n" % s.getsockname()[1])
sys.stdout.flush()
time.sleep(120)' >"$C/nep.port" &
nep_pid=$!
nep_port_ready() { [ -s "$C/nep.port" ]; }
wait_while_alive "$nep_pid" nep_port_ready
nep_live=$(tr -dc '0-9' <"$C/nep.port")
timeout 5 bash -c "</dev/tcp/127.0.0.1/$nep_live" 2>/dev/null
assert_rc "the fixture's own port really accepts (control on the fixture, not on the gate)" "$?" "0"
# Baseline: Tari on a REMOTE node that is NOT up. Monero stays local, so only the Tari leg is ever
# dialled, and `apply` itself never probes — the wizard and this gate are the only callers.
jq '.tari.mode="remote" | .tari.remote={host:"127.0.0.1",grpc_port:1}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_contains "remote-Tari baseline applied" "$(cat "$C/.env")" "TARI_GRPC_ADDRESS=127.0.0.1:1"
# 1. No token: the endpoint IS committable now, but only behind the typed confirmation.
jq '.tari.remote.grpc_port=2' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a node-endpoint change without the token is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the token-less refusal asks for the confirmation" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "type APPLY"
# 2. Token + an endpoint nothing answers on: the PROBE refuses. Without it this commit applies.
gate_try "$C/cand.json" APPLY
assert_eq "an unreachable node endpoint is refused even with the token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the refusal comes from the reachability probe" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "cannot use"
assert_eq "config.json keeps the old endpoint" "$(jq -r '.tari.remote.grpc_port' "$C/config.json")" "1"
# 3. Token + an endpoint that answers: committed. #1888's whole point — changeable on a live machine.
jq --argjson p "$nep_live" '.tari.remote.grpc_port=$p' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY
assert_eq "a reachable node endpoint commits with the token" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the new endpoint landed in config.json" "$(jq -r '.tari.remote.grpc_port' "$C/config.json")" "$nep_live"
kill "$nep_pid" 2>/dev/null
cp "$C/nep-keep.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
unset nep_pid nep_live
