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
# corresponding assert_new_worker_host_refused case red (each names which).

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
