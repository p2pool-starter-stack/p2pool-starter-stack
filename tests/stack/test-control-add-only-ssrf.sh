# shellcheck shell=bash
#
# workers.list[]'s add-only exception (#893's click-to-adopt) + the #122 SSRF floor on what a
# newly-appended entry may point at (_control_host_is_internal). Split out of run.sh's own
# "approval gate default-denies security-control changes" section purely for the file-budget
# ratchet (#1105 Phase 0) — it shares that section's $C/$UUID5/gate_try, exactly like
# test-control-deploy.sh shares its own section's fixtures. Sourced by tests/stack/run.sh
# immediately after gate_try() is defined, before the dashboard.energy tests that follow it.
#
# MUTATION PROOF: reverting pithead's add-only prefix check back to "refuse any workers.list
# diff" turns the ADD-ONLY-append assertion red; reverting _control_host_is_internal's
# trailing-dot strip or narrowing its alias set back to bare "localhost" turns the
# corresponding assert_new_worker_host_refused case red (each names which). Round 5's
# resolve-and-check battery (below) names its own mutation kills at each assertion.

# workers.list[] (#506): same descriptors as dashboard.workers[] above, but with ONE add-only
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
