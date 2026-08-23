# shellcheck shell=bash
#
# Rig/worker domain (#1105 Phase 1, develop-v2 lane): the merge-mining rig's stratum-facing
# surface and the control channel's per-rig worker-config/worker-upgrade verbs — xmrig-proxy's
# stratum auth + donate-level knobs (#152/#173), the co-located built-in miner's opt-in announce
# of the pool URL + stratum secret to a RigForge install (#593), stratum-over-TLS render and the
# cert lifecycle a rig pins its fingerprint to (#261), and the worker-config/worker-upgrade verbs
# end to end — fail-closed resolution from the HOST's config.json only, never the intent
# (#185/#597), the accept/poll/terminal state machine against a stubbed rig control API, the
# GitHub release-tag derive + anti-beacon throttle, and the rig-refusal/timeout/stale-terminal
# edges (#597).
# Sourced by tests/stack/run.sh.
#
# Left behind, code-checked (not markers):
# - The "xmrig-proxy entrypoint: unset password appends no flag" assertion sitting inside
#   "rotate-secrets failure path" (#378, run.sh's secrets-domain sections) is a side-effect check
#   of THAT test group, not this domain — it stays there for the future secrets-domain cut.
# - The per-worker token-mask pair ("per-worker token mask + host-side restore", both the legacy
#   dashboard.workers[] and the current workers.list[] shapes, #172/#679/#506) is a NAMED
#   leave-behind, deferred to the future $C-sandbox-cluster pass per the #1252 map's "clusters
#   last" rule. It looked cleanly re-derivable — render_masked_config() only reads a valid
#   config.json, not any specific mutation history, and test-control-upgrade.sh's precedent
#   already re-derives a FRESH $C for two of its own sections. That analysis was right about
#   render_masked_config, but incomplete: a first attempt at moving this pair (re-deriving $C via
#   build_control_sandbox + control_config + apply) made the after-proof suite go 2901/1 —
#   `./pithead apply -y` on the fresh sandbox writes into $C/data/control/results/, and the LATER
#   "control-run-pending (#33)" section (still in run.sh, reading the AMBIENT $C) counts result
#   files in that same directory as part of a malformed-id assertion; the re-derivation's apply
#   calls leaked extra result files into that shared, ambient results dir and threw the count off
#   by exactly the number of applies this pair runs. That is the real $C-coupling the map's
#   "clusters last" rule is protecting against — not config.json's read-side content (which IS
#   generic), but write-side pollution of a directory a much later, still-in-run.sh section
#   counts. Moving just this pair without carrying (or isolating) every section that shares $C's
#   results/audit/staged dirs is not a clean re-derivation, so it stays with the ambient $C in
#   run.sh until the control-core/control-gates cluster is cut as a whole.
#
# Re-derivations:
# - $V / $WALLET: lib.sh's build_val_sandbox() sets both; run.sh's "config validation" black-box
#   calls it once, far earlier than the stratum/xmrig/miner-announce sections below that read
#   them — that section stays in run.sh (a generic multi-field validator, not rig-specific).
#   build_val_sandbox() is idempotent (a fixed $SANDBOX/val path, mkdir -p, template copies), so
#   calling it again here is a safe no-op re-affirm as currently sourced.
# - $DOCKER_LOG: the "apply preserves secrets + propagates" black-box sets it ($V/docker.log) and
#   stays in run.sh (a generic multi-key regression, not rig-specific).
# - The worker-config/worker-upgrade verbs below need no control-sandbox re-derivation at all:
#   each case builds its own throwaway dir under $SANDBOX and points PITHEAD_CONFIG_FILE at it,
#   never touching $C — proven by exactly this after-proof once the token-mask pair above was
#   pulled back out.
build_val_sandbox
DOCKER_LOG="$V/docker.log"

echo "== black-box: xmrig-proxy knobs (#152 stratum auth, #173 donate-level) =="
# stratum_password "auto" generates + persists a stable secret and surfaces it for rigs; an explicit
# proxy.donate_level propagates verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "proxy":{"donate_level":1}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
sp1="$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)"
case "$sp1" in ?*) ok "stratum_password auto generated a secret" ;; *) bad "stratum_password auto generated a secret" "got empty" ;; esac
assert_eq "donate-level explicit propagated" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_DONATE_LEVEL)" "1"
assert_contains "stratum auth surfaced for rigs" "$(run_sourced "$V" announce_stratum_auth 2>&1)" "Stratum authentication is ON"

echo "== unit: announce_local_miner hands off the stratum URL + secret only when opted in (#593) =="
# The local-miner opt-in surfaces the two values a co-located RigForge install needs (pool URL +
# stratum secret) and NOTHING else — off by default, loopback when the bind allows it, the bound
# LAN address when it doesn't (the #593 stratum_bind edge case), and RigForge-owns-tuning stated.
LM="$SANDBOX/lm"
mkdir -p "$LM"
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
# Opt-out (default): prints nothing at all.
printf '{"local_miner":{"enabled":false}}' >"$LM/config.json"
assert_eq "opt-out prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Absent block also prints nothing (default false).
printf '{}' >"$LM/config.json"
assert_eq "absent local_miner prints nothing" "$(run_sourced "$LM" announce_local_miner 2>&1)" ""
# Opt-in, 0.0.0.0 bind: loopback URL + the secret + the RigForge-owns-tuning note.
printf '{"local_miner":{"enabled":true}}' >"$LM/config.json"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "opt-in surfaces loopback pool URL" "$lm_out" "127.0.0.1:3333"
assert_contains "opt-in surfaces the stratum secret" "$lm_out" "s3cr3t"
assert_contains "opt-in states RigForge owns host tuning" "$lm_out" "RigForge"
# Custom port + specific LAN bind: target the bound address, not hardcoded loopback (#593 edge case).
printf 'STRATUM_BIND=192.168.1.9\nSTRATUM_PORT=4444\nPROXY_STRATUM_PASSWORD=s3cr3t\n' >"$LM/.env"
lm_out="$(run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "LAN bind targets the bound address:port" "$lm_out" "192.168.1.9:4444"
# No stratum password set: say so rather than printing a blank pass.
printf 'STRATUM_BIND=0.0.0.0\nSTRATUM_PORT=3333\nPROXY_STRATUM_PASSWORD=\n' >"$LM/.env"
assert_contains "no-password case is stated explicitly" "$(run_sourced "$LM" announce_local_miner 2>&1)" "none set"
# On the appliance the miner is BUILT IN: the announcement must promise the machine handles it,
# never instruct an install on a box with no shell — the exact gap that was filed as a defect.
lm_out="$(PITHEAD_APPLIANCE=1 run_sourced "$LM" announce_local_miner 2>&1)"
assert_contains "appliance: announces the built-in worker" "$lm_out" "built-in RigForge worker"
assert_not_contains "appliance: no install-it-yourself instruction" "$lm_out" "point a RigForge install"

# Re-apply: an "auto" password must be STABLE (reused, not rotated) — like the proxy token.
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum_password auto stable across apply" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_PASSWORD)" "$sp1"

echo "== black-box: stratum-over-TLS render + cert lifecycle (#261) =="
# Default: off, no cert generated. The dir var still renders (compose always mounts it :ro).
assert_eq "stratum TLS off by default" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "false"
[ ! -f "$V/data/proxy-tls/cert.pem" ] && ok "no cert generated while TLS is off" ||
    bad "no cert generated while TLS is off" "cert.pem exists"
# Knob on: real openssl generates the keypair once; key owner-only; fingerprint announced and
# STABLE across a second apply (the fingerprint is what every rig pins — regenerating it on each
# apply would break every TLS rig).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "stratum TLS renders true" "$(run_sourced "$V" env_get_file "$V/.env" PROXY_STRATUM_TLS)" "true"
[ -f "$V/data/proxy-tls/cert.pem" ] && [ -f "$V/data/proxy-tls/key.pem" ] &&
    ok "TLS keypair generated on first apply" || bad "TLS keypair generated on first apply" "missing files"
assert_eq "TLS key is owner-only" "$(file_mode "$V/data/proxy-tls/key.pem")" "600"
assert_contains "fingerprint announced for rig pinning" "$out" "Stratum TLS is ON"
fp1="$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "cert (and its pinned fingerprint) stable across apply" \
    "$(openssl x509 -in "$V/data/proxy-tls/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)" "$fp1"
# announce_stratum_tls prints the pin in xmrig's format: 64 lowercase hex chars, no colons.
announced="$(run_sourced "$V" announce_stratum_tls 2>&1 | grep -oE '[0-9a-f]{64}' | head -1)"
assert_eq "announced fingerprint is the cert's own, xmrig format" \
    "$announced" "$(printf '%s' "$fp1" | tr -d ':' | tr '[:upper:]' '[:lower:]')"
# compose forwards the toggle and mounts the keypair dir read-only.
assert_contains "compose passes PROXY_STRATUM_TLS to the proxy (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_STRATUM_TLS=${PROXY_STRATUM_TLS'
assert_contains "compose mounts the TLS keypair dir :ro (#261)" "$(cat "$ROOT/docker-compose.yml")" 'PROXY_TLS_DIR:-./data/proxy-tls}:/tls:ro'

# ---------------------------------------------------------------------------
echo "== control channel: worker config apply fails closed (#185) =="
# control_worker_apply resolves the rig's host/token from the HOST's config.json (never the intent)
# and refuses — before dialing any rig — a bad worker name, a non-writable key, an empty change, or a
# worker missing a host or token. These are the fail-closed guards a compromised container hits.
WA="$SANDBOX/ctrl185"
mkdir -p "$WA/staged" "$WA/results" "$WA/audit"
# config.json: rig1 fully addressable (host+token), rig2 has a host but no token (bearer-mandatory).
cat >"$WA/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wa_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WA/req.json"
    PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WA/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
u1="aaaaaaaa-1111-4111-8111-111111111111"
u2="bbbbbbbb-2222-4222-8222-222222222222"
u3="cccccccc-3333-4333-8333-333333333333"
u4="dddddddd-4444-4444-8444-444444444444"
u5="eeeeeeee-5555-4555-8555-555555555555"
wa_case "$u1" "{\"id\":\"$u1\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"\",\"changes\":{\"DONATION\":2}}" "empty worker name rejected" "worker"
wa_case "$u2" "{\"id\":\"$u2\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{\"ACCESS_TOKEN\":\"x\"}}" "non-writable key rejected" "not writable"
wa_case "$u3" "{\"id\":\"$u3\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig1\",\"changes\":{}}" "empty changes rejected" "non-empty"
wa_case "$u4" "{\"id\":\"$u4\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"ghost\",\"changes\":{\"DONATION\":2}}" "unknown/hostless worker rejected" "no configured host"
wa_case "$u5" "{\"id\":\"$u5\",\"action\":\"worker-apply\",\"actor\":\"admin\",\"worker\":\"rig2\",\"changes\":{\"DONATION\":2}}" "worker without a token rejected (bearer-mandatory)" "no token"
# The intent's own host/port/token are IGNORED — resolution is from config.json only (#122). A tampered
# intent naming rig2 (no token) with an injected token still fails closed.
u6="ffffffff-6666-4666-8666-666666666666"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig2","changes":{"DONATION":2}}\n' "$u6" >"$WA/req.json"
PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_eq "worker-apply reject is audited by name only" \
    "$(jq -r '.status' "$WA/results/$u6.json")" "rejected"
assert_contains "worker-apply audit records the action, no token" \
    "$(cat "$WA/audit/control.log")" '"action":"worker-apply","status":"rejected"'
if grep -q 'tok-rig1' "$WA/audit/control.log" "$WA"/results/*.json 2>/dev/null; then
    bad "worker-apply never leaks a token to results/audit" "token found"
else
    ok "worker-apply never leaks a token to results/audit"
fi
# Per-drain dial budget (#185 hardening): with the budget exhausted, a fully-valid apply (rig1 has a
# host + token) is refused BEFORE any rig dial, so a flood can't starve the root runner.
u7="99999999-7777-4777-8777-777777777777"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u7" >"$WA/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA/config.json" run_sourced "$SANDBOX" control_process_request "$WA/req.json" "$WA" >/dev/null 2>&1
assert_contains "worker-apply over the dial budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WA/results/$u7.json")" "too many worker config changes"

# workers.list[] (#506): control_worker_apply resolves the rig's host/token the same way from the
# CURRENT shape. Reuses the budget=0 technique above — a "too many worker config changes" rejection
# (instead of "no configured host"/"no token") proves resolution succeeded BEFORE the pre-dial
# budget gate, without needing to stub the actual network dial.
WA2="$SANDBOX/ctrl506"
mkdir -p "$WA2/staged" "$WA2/results" "$WA2/audit"
cat >"$WA2/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
u8="88888888-9999-4999-8999-888888888888"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"DONATION":2}}\n' "$u8" >"$WA2/req.json"
CONTROL_WA_BUDGET=0 PITHEAD_CONFIG_FILE="$WA2/config.json" run_sourced "$SANDBOX" control_process_request "$WA2/req.json" "$WA2" >/dev/null 2>&1
assert_contains "workers.list worker-apply resolves the rig (budget rejection proves pre-dial success)" \
    "$(jq -r '.error // ""' "$WA2/results/$u8.json")" "too many worker config changes"

echo "== control channel: worker config apply ACCEPT path succeeds + is audited (#185) =="
# Mirrors the reject-path setup above, but with a stub curl standing in for the rig's control API so a
# fully-valid worker-apply actually dials, gets accepted (202 + change_id), and polls the rig's
# /status to a terminal "applied" — proving the success leg of #185, not just the fail-closed guards
# exercised above it.
WA3="$SANDBOX/ctrl185-accept"
mkdir -p "$WA3/staged" "$WA3/results" "$WA3/audit" "$WA3/bin"
cat >"$WA3/config.json" <<'EOF'
{ "dashboard": { "workers": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" }
] } }
EOF
# A minimal curl stand-in: no real network dial. Reads its own args for `-o <file>` and the trailing
# URL (curl always puts flags/headers/data before the bare URL, so the last plain token IS the URL);
# serves a canned 202 body for POST .../apply and a terminal "applied" 200 body for GET .../status —
# mirroring what a real RigForge rig's control API returns (rigforge#236's status shape).
cat >"$WA3/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-1"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-1","status":"applied","changed_keys":["pools"]}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA3/bin/curl"
u9="12121212-1212-4212-8212-121212121212"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u9" >"$WA3/req.json"
PATH="$WA3/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA3/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA3/req.json" "$WA3" >/dev/null 2>&1
assert_eq "worker-apply accept path reaches a terminal 'applied' status" \
    "$(jq -r '.status' "$WA3/results/$u9.json" 2>/dev/null)" "applied"
assert_eq "worker-apply accept path records the rig's change_id" \
    "$(jq -r '.change_id' "$WA3/results/$u9.json" 2>/dev/null)" "chg-1"
assert_eq "worker-apply accept path records the rig's changed_keys" \
    "$(jq -rc '.changed_keys' "$WA3/results/$u9.json" 2>/dev/null)" '["pools"]'
assert_contains "worker-apply accept is audited as applied" \
    "$(cat "$WA3/audit/control.log")" '"action":"worker-apply","status":"applied"'
# The rig can also end an apply terminal "failed" — it could not restore its own rollback backup
# (present since the v1.11.2 fleet floor). The poll must land it as failed-with-reason, never burn
# the 20s deadline into a vague "accepted".
WA4="$SANDBOX/ctrl185-failed"
mkdir -p "$WA4/staged" "$WA4/results" "$WA4/audit" "$WA4/bin"
cp "$WA3/config.json" "$WA4/config.json"
cat >"$WA4/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/apply)
    printf '{"change_id":"chg-2"}' >"$out"
    printf '202' ;;
*/status)
    printf '{"change_id":"chg-2","status":"failed","reason":"rollback backup unreadable: /var/lib/rigforge/backup"}' >"$out"
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$WA4/bin/curl"
u10="fafafafa-fafa-4afa-8afa-fafafafafafa"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig1","changes":{"pools":["pool.example:3333"]}}\n' "$u10" >"$WA4/req.json"
PATH="$WA4/bin:$PATH" CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$WA4/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WA4/req.json" "$WA4" >/dev/null 2>&1
assert_eq "a failed apply reaches terminal 'failed', not the poll-deadline 'accepted'" \
    "$(jq -r '.status' "$WA4/results/$u10.json" 2>/dev/null)" "failed"
assert_contains "the failed apply carries the rig's reason" \
    "$(jq -r '.reason' "$WA4/results/$u10.json" 2>/dev/null)" "rollback backup unreadable"
assert_contains "the failed apply is audited as failed" \
    "$(cat "$WA4/audit/control.log")" '"action":"worker-apply","status":"failed"'

# ---------------------------------------------------------------------------
echo "== control channel: worker upgrade fails closed (#597) =="
# control_worker_upgrade fuses the worker-apply template (rig resolved from the HOST config, never
# the intent) with the stack-upgrade template (host-side target re-derivation, throttled). These are
# the pre-dial fail-closed guards.
WU="$SANDBOX/ctrl597"
mkdir -p "$WU/staged" "$WU/results" "$WU/audit"
cat >"$WU/config.json" <<'EOF'
{ "workers": { "list": [
    { "name": "rig1", "host": "10.0.0.9", "control_port": 8082, "token": "tok-rig1" },
    { "name": "rig2", "host": "10.0.0.8" }
] } }
EOF
wu_case() { # <uuid> <intent-json> <label> <expected-error-substring>
    printf '%s\n' "$2" >"$WU/req.json"
    PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
    local out
    out=$(jq -r '.status + "|" + (.error // "")' "$WU/results/$1.json" 2>/dev/null)
    case "$out" in
    rejected\|*"$4"*) ok "$3" ;;
    *) bad "$3" "got: $out" ;;
    esac
}
w1="aaaaaaaa-1111-4111-9111-111111111111"
w2="bbbbbbbb-2222-4222-9222-222222222222"
w3="cccccccc-3333-4333-9333-333333333333"
w4="dddddddd-4444-4444-9444-444444444444"
w5="eeeeeeee-5555-4555-9555-555555555555"
wu_case "$w1" "{\"id\":\"$w1\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"\",\"version\":\"v1.11.2\"}" "upgrade: empty worker name rejected" "worker"
wu_case "$w2" "{\"id\":\"$w2\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig1\",\"version\":\"1.11.2\"}" "upgrade: bare (non-tag) version rejected" "version"
wu_case "$w3" "{\"id\":\"$w3\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"ghost\",\"version\":\"v1.11.2\"}" "upgrade: unknown/hostless worker rejected" "no configured host"
wu_case "$w4" "{\"id\":\"$w4\",\"action\":\"worker-upgrade\",\"actor\":\"admin\",\"worker\":\"rig2\",\"version\":\"v1.11.2\"}" "upgrade: worker without a token rejected (bearer-mandatory)" "no token"
# Per-drain budget: exactly one upgrade dials per drain; over-budget rejects BEFORE the tag lookup
# (a "already in this cycle" rejection also proves rig resolution succeeded pre-dial).
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w5" >"$WU/req.json"
CONTROL_WU_BUDGET=0 PITHEAD_CONFIG_FILE="$WU/config.json" run_sourced "$SANDBOX" control_process_request "$WU/req.json" "$WU" >/dev/null 2>&1
assert_contains "upgrade over the per-drain budget is rejected (no dial)" \
    "$(jq -r '.error // ""' "$WU/results/$w5.json")" "already in this cycle"
if grep -q 'tok-rig1' "$WU/audit/control.log" "$WU"/results/*.json 2>/dev/null; then
    bad "worker-upgrade never leaks a token to results/audit" "token found"
else
    ok "worker-upgrade never leaks a token to results/audit"
fi
# Anti-beacon throttle (#597, control_upgrade's lesson): a fresh lookup stamp with no cached tag
# means a recent derive attempt failed — refuse WITHOUT another GitHub/Tor dial. The curl stub
# records every invocation; it must stay unused.
WUT="$SANDBOX/ctrl597-throttle"
mkdir -p "$WUT/staged" "$WUT/results" "$WUT/audit" "$WUT/bin"
cp "$WU/config.json" "$WUT/config.json"
cat >"$WUT/bin/curl" <<EOF
#!/usr/bin/env bash
echo "dialed \$*" >>"$WUT/dials.log"
exit 7
EOF
chmod +x "$WUT/bin/curl"
touch "$WUT/staged/.rigforge-latest-stamp"
w6="ffffffff-6666-4666-9666-666666666666"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.11.2"}\n' "$w6" >"$WUT/req.json"
PATH="$WUT/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$WUT/config.json" \
    run_sourced "$SANDBOX" control_process_request "$WUT/req.json" "$WUT" >/dev/null 2>&1
assert_contains "upgrade inside the 10-min lookup window (no cached tag) is rejected" \
    "$(jq -r '.error // ""' "$WUT/results/$w6.json")" "retry in a few minutes"
assert_eq "the throttled upgrade made NO network dial" "$(cat "$WUT/dials.log" 2>/dev/null)" ""

echo "== control channel: worker upgrade drives the rig to each terminal (#597) =="
# A stub curl stands in for the rig's control API (and would catch any unexpected GitHub dial: the
# tag is pre-cached, so the only allowed URLs are the rig's /upgrade and /status). One sandbox per
# scenario; the stub's /status behaviour is parameterized via WU_STATUS_BODY, and the stale-terminal
# case serves a PREVIOUS change's terminal first to prove change_id matching.
wu_accept_case() { # <uuid> <status-body-json> <label> <expected-status>
    local dir="$SANDBOX/ctrl597-$1"
    mkdir -p "$dir/staged" "$dir/results" "$dir/audit" "$dir/bin"
    cp "$WU/config.json" "$dir/config.json"
    printf '%s' "v9.9.9" >"$dir/staged/.rigforge-latest-tag"
    cat >"$dir/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$dir/dials.log"
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status) printf '%s' '$2' >"\$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/curl"
    printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$1" >"$dir/req.json"
    PATH="$dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$dir/config.json" \
        run_sourced "$SANDBOX" control_process_request "$dir/req.json" "$dir" >/dev/null 2>&1
    assert_eq "$3" "$(jq -r '.status' "$dir/results/$1.json" 2>/dev/null)" "$4"
    WU_LAST_DIR="$dir"
}
w7="12121212-1212-4212-9212-121212121212"
wu_accept_case "$w7" '{"change_id":"chg-9","status":"applied"}' \
    "upgrade accept path reaches a terminal 'applied'" "applied"
assert_eq "applied result records the rig's change_id" \
    "$(jq -r '.change_id' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "chg-9"
assert_eq "applied result records the host-derived version" \
    "$(jq -r '.version' "$WU_LAST_DIR/results/$w7.json" 2>/dev/null)" "v9.9.9"
# #690: every runner dial (the rig POST + each /status poll) carries a response-size cap so a
# hostile rig can't stream an unbounded body into disk/memory. Proves the flag is wired, not curl's
# own enforcement (that needs a real curl against an oversized server — an e2e concern).
assert_contains "worker-upgrade rig dials carry a --max-filesize cap (#690)" \
    "$(cat "$WU_LAST_DIR/dials.log" 2>/dev/null)" "--max-filesize"
assert_contains "upgrade applied is audited" \
    "$(cat "$WU_LAST_DIR/audit/control.log")" '"action":"worker-upgrade","status":"applied"'
w8="23232323-2323-4232-9232-232323232323"
wu_accept_case "$w8" '{"change_id":"chg-9","status":"rolled_back","reason":"miner did not return live"}' \
    "upgrade rollback surfaces as rolled_back" "rolled_back"
assert_eq "rolled_back result carries the rig's reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w8.json" 2>/dev/null)" "miner did not return live"
w9="34343434-3434-4234-9234-343434343434"
wu_accept_case "$w9" '{"change_id":"chg-9","status":"failed","reason":"throttled: retry after the window"}' \
    "legacy rig (pre-v1.12.0) throttle refusal (failed+text) still maps to retry-later" "throttled"
# First-class terminals since rigforge#320 (v1.12.0): noop (already on the target) and throttled
# land their real status on the first poll — neither burns the poll cap into a vague "accepted".
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
wu_accept_case "$w17" '{"change_id":"chg-9","status":"noop","reason":"already on v9.9.9 — nothing to upgrade"}' \
    "a rig already on the target lands first-class 'noop', not the poll-cap fallback" "noop"
assert_contains "the noop result carries the rig's already-on-target reason" \
    "$(jq -r '.reason' "$WU_LAST_DIR/results/$w17.json" 2>/dev/null)" "already on v9.9.9"
w18="cdcdcdcd-cdcd-42cd-92cd-cdcdcdcdcdcd"
wu_accept_case "$w18" '{"change_id":"chg-9","status":"throttled","reason":"throttled — too soon since the last upgrade attempt"}' \
    "a first-class 'throttled' terminal lands as retry-later on the first poll" "throttled"
# A genuine failure that merely MENTIONS the throttle must stay a fault (rigforge#321's
# fail-closed refusal): only the legacy leading-"throttled" free text remaps to retry-later.
w19="dededede-dede-42de-92de-dededededede"
wu_accept_case "$w19" '{"change_id":"chg-9","status":"failed","reason":"throttle state unavailable under /var/lib/rigforge — refused (fail-closed)"}' \
    "a broken-rig failure mentioning the throttle stays 'failed', never calmed" "failed"
# An unreachable rig fails cleanly (nothing changed, rig keeps its version).
unreach_dir="$SANDBOX/ctrl597-unreach"
mkdir -p "$unreach_dir/staged" "$unreach_dir/results" "$unreach_dir/audit" "$unreach_dir/bin"
cp "$WU/config.json" "$unreach_dir/config.json"
printf '%s' "v9.9.9" >"$unreach_dir/staged/.rigforge-latest-tag"
printf '#!/usr/bin/env bash\nexit 7\n' >"$unreach_dir/bin/curl"
chmod +x "$unreach_dir/bin/curl"
w12="67676767-6767-4267-9267-676767676767"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w12" >"$unreach_dir/req.json"
PATH="$unreach_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$unreach_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$unreach_dir/req.json" "$unreach_dir" >/dev/null 2>&1
assert_contains "an unreachable rig fails cleanly (nothing changed)" \
    "$(jq -r '.status + "|" + (.error // "")' "$unreach_dir/results/$w12.json")" "failed|could not reach worker"

# A non-latest proposal is refused against the CACHED tag — before any rig dial.
wa_dir="$SANDBOX/ctrl597-notlatest"
mkdir -p "$wa_dir/staged" "$wa_dir/results" "$wa_dir/audit"
cp "$WU/config.json" "$wa_dir/config.json"
printf '%s' "v9.9.9" >"$wa_dir/staged/.rigforge-latest-tag"
w10="45454545-4545-4245-9245-454545454545"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v1.0.0"}\n' "$w10" >"$wa_dir/req.json"
CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$wa_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$wa_dir/req.json" "$wa_dir" >/dev/null 2>&1
assert_contains "a non-latest proposal is refused against the host-derived tag" \
    "$(jq -r '.error // ""' "$wa_dir/results/$w10.json")" "not the latest published RigForge release"
# Stale-terminal guard: the rig's /status first shows a PREVIOUS change's applied (no in-progress
# state, rigforge#320) — it must be ignored until OUR change_id appears.
stale_dir="$SANDBOX/ctrl597-stale"
mkdir -p "$stale_dir/staged" "$stale_dir/results" "$stale_dir/audit" "$stale_dir/bin"
cp "$WU/config.json" "$stale_dir/config.json"
printf '%s' "v9.9.9" >"$stale_dir/staged/.rigforge-latest-tag"
cat >"$stale_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"\$out"; printf '202' ;;
*/status)
    if [ -f "$stale_dir/.polled" ]; then
        printf '{"change_id":"chg-9","status":"applied"}' >"\$out"
    else
        touch "$stale_dir/.polled"
        printf '{"change_id":"chg-OLD","status":"applied"}' >"\$out"
    fi
    printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$stale_dir/bin/curl"
w11="56565656-5656-4256-9256-565656565656"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w11" >"$stale_dir/req.json"
PATH="$stale_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$stale_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$stale_dir/req.json" "$stale_dir" >/dev/null 2>&1
assert_eq "a stale terminal for a PREVIOUS change_id is ignored; ours lands" \
    "$(jq -r '.status + "|" + .change_id' "$stale_dir/results/$w11.json" 2>/dev/null)" "applied|chg-9"
# Poll-cap timeout (the sec-review headline fix): the cap bounds a hostile/hung rig's hold on the
# single-threaded root drain, and hitting it must land "accepted" (queued on the rig; the #596
# badge clears on its own), never a failure. CONTROL_WU_POLL_CAP shrinks the 90s cap so this
# proves the fallback in seconds — the rig accepts (202) but its /status only ever shows a
# PREVIOUS change's terminal, so no terminal for OUR change_id arrives inside the cap.
to_dir="$SANDBOX/ctrl597-timeout"
mkdir -p "$to_dir/staged" "$to_dir/results" "$to_dir/audit" "$to_dir/bin"
cp "$WU/config.json" "$to_dir/config.json"
printf '%s' "v9.9.9" >"$to_dir/staged/.rigforge-latest-tag"
cat >"$to_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-OLD","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$to_dir/bin/curl"
w13="78787878-7878-4278-9278-787878787878"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w13" >"$to_dir/req.json"
PATH="$to_dir/bin:$PATH" CONTROL_WU_BUDGET=1 CONTROL_WU_POLL_CAP=1 PITHEAD_CONFIG_FILE="$to_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$to_dir/req.json" "$to_dir" >/dev/null 2>&1
assert_eq "hitting the poll cap lands 'accepted' (queued on the rig), not a failure" \
    "$(jq -r '.status + "|" + .change_id' "$to_dir/results/$w13.json" 2>/dev/null)" "accepted|chg-9"
assert_contains "the timed-out result says the upgrade is still running" \
    "$(jq -r '.note // ""' "$to_dir/results/$w13.json" 2>/dev/null)" "still running on the rig"
assert_contains "the poll-cap timeout is audited as accepted" \
    "$(cat "$to_dir/audit/control.log")" '"action":"worker-upgrade","status":"accepted"'

echo "== control channel: worker upgrade derives the target tag from GitHub (#597) =="
# Every accept case above pre-caches .rigforge-latest-tag; these prove the derive itself. The
# GitHub call captures curl's STDOUT (no -o), so the stub answers the release API on stdout and
# keeps the -o/-w shape for the rig's /upgrade + /status.
gh_dir="$SANDBOX/ctrl597-derive"
mkdir -p "$gh_dir/staged" "$gh_dir/results" "$gh_dir/audit" "$gh_dir/bin"
cp "$WU/config.json" "$gh_dir/config.json"
cat >"$gh_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o) out="$2"; shift 2 ;;
    *) url="$1"; shift ;;
    esac
done
case "$url" in
*/releases/latest) printf '{"tag_name":"v9.9.9"}\n200' ;;
*/upgrade) printf '{"change_id":"chg-9"}' >"$out"; printf '202' ;;
*/status) printf '{"change_id":"chg-9","status":"applied"}' >"$out"; printf '200' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$gh_dir/bin/curl"
w14="89898989-8989-4289-9289-898989898989"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w14" >"$gh_dir/req.json"
PATH="$gh_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$gh_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$gh_dir/req.json" "$gh_dir" >/dev/null 2>&1
assert_eq "a fresh derive parses tag_name and drives the upgrade to applied" \
    "$(jq -r '.status + "|" + .version' "$gh_dir/results/$w14.json" 2>/dev/null)" "applied|v9.9.9"
assert_eq "the derived tag is cached for the next intent" \
    "$(cat "$gh_dir/staged/.rigforge-latest-tag" 2>/dev/null)" "v9.9.9"
# GitHub unreachable over Tor: refused fail-closed, nothing dialed toward the rig.
ghfail_dir="$SANDBOX/ctrl597-ghdown"
mkdir -p "$ghfail_dir/staged" "$ghfail_dir/results" "$ghfail_dir/audit" "$ghfail_dir/bin"
cp "$WU/config.json" "$ghfail_dir/config.json"
printf '#!/usr/bin/env bash\nexit 7\n' >"$ghfail_dir/bin/curl"
chmod +x "$ghfail_dir/bin/curl"
w15="9a9a9a9a-9a9a-429a-929a-9a9a9a9a9a9a"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w15" >"$ghfail_dir/req.json"
PATH="$ghfail_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghfail_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghfail_dir/req.json" "$ghfail_dir" >/dev/null 2>&1
assert_contains "an unreachable GitHub release API refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghfail_dir/results/$w15.json")" \
    "rejected|could not reach the GitHub release API over Tor"
# GitHub reachable but the response carries no usable tag: refused fail-closed.
ghjunk_dir="$SANDBOX/ctrl597-ghjunk"
mkdir -p "$ghjunk_dir/staged" "$ghjunk_dir/results" "$ghjunk_dir/audit" "$ghjunk_dir/bin"
cp "$WU/config.json" "$ghjunk_dir/config.json"
cat >"$ghjunk_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"message":"Not Found"}\n200'
exit 0
EOF
chmod +x "$ghjunk_dir/bin/curl"
w16="abababab-abab-42ab-92ab-abababababab"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w16" >"$ghjunk_dir/req.json"
PATH="$ghjunk_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$ghjunk_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$ghjunk_dir/req.json" "$ghjunk_dir" >/dev/null 2>&1
assert_contains "a release API response with no usable tag refuses fail-closed" \
    "$(jq -r '.status + "|" + (.error // "")' "$ghjunk_dir/results/$w16.json")" \
    "rejected|the GitHub release API returned no usable RigForge release tag"

# Rig refusal (non-202) — this branch is also where an old rig (< v1.11.2: no /upgrade endpoint,
# or its own version gate) surfaces its refusal. The rig's error text is attacker-influenceable
# (a compromised rig / LAN MITM), so it must be capped at 500 chars before it lands in a result.
refuse_dir="$SANDBOX/ctrl597-refuse"
mkdir -p "$refuse_dir/staged" "$refuse_dir/results" "$refuse_dir/audit" "$refuse_dir/bin"
cp "$WU/config.json" "$refuse_dir/config.json"
printf '%s' "v9.9.9" >"$refuse_dir/staged/.rigforge-latest-tag"
# 500 filler chars then a marker: the cap keeps the filler and must drop the marker.
wu_long_err="$(printf 'A%.0s' $(seq 1 500))OVERFLOW-TAIL"
cat >"$refuse_dir/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) url="\$1"; shift ;;
    esac
done
case "\$url" in
*/upgrade) printf '{"error":"$wu_long_err"}' >"\$out"; printf '403' ;;
*) printf '000' ;;
esac
exit 0
EOF
chmod +x "$refuse_dir/bin/curl"
w17="bcbcbcbc-bcbc-42bc-92bc-bcbcbcbcbcbc"
printf '{"id":"%s","action":"worker-upgrade","actor":"admin","worker":"rig1","version":"v9.9.9"}\n' "$w17" >"$refuse_dir/req.json"
PATH="$refuse_dir/bin:$PATH" CONTROL_WU_BUDGET=1 PITHEAD_CONFIG_FILE="$refuse_dir/config.json" \
    run_sourced "$SANDBOX" control_process_request "$refuse_dir/req.json" "$refuse_dir" >/dev/null 2>&1
assert_contains "a rig non-202 (incl. an old-rig < v1.11.2 refusal) is surfaced as rejected" \
    "$(jq -r '.status + "|" + (.error // "")' "$refuse_dir/results/$w17.json")" \
    "rejected|worker 'rig1' refused the upgrade (HTTP 403): AAAA"
assert_not_contains "the rig's error text is truncated at 500 chars" \
    "$(jq -r '.error // ""' "$refuse_dir/results/$w17.json")" "OVERFLOW-TAIL"
