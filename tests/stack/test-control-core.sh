# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel core domain (#1105 Phase 1, develop-v2 lane): the six black-box sections that
# build the control sandbox and drive it. First `apply` — fail-closed when the
# control channel is enabled without a dashboard password, the .env render of the control keys and
# the spool dirs, --dry-run/--porcelain previews that touch no container and leave .env alone, the
# PITHEAD_CONFIG_FILE single-invocation override, #695's contract that a symlink-invoked stack
# renders physical paths, and #556's read-only contract on both legs: the direct CLI leaves
# config.json byte-identical after a preview, and the control path does not rewrite the on-disk
# staged copy either. Then control-run-pending end to end — a valid preview claimed out of the
# spool and staged owner-only, malformed and non-v4 ids discarded with no result written, unknown
# actions and extra request keys rejected, the charset strip that stops a forged action appending a
# second line to the tamper-evidence log, and a commit with its pre-change backup and the re-own
# that keeps the operator able to read what root's apply wrote. Last, #349's audit section reads
# that log back and proves it records changed key NAMES and never a config or secret VALUE.
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS THE CONTROL SANDBOX'S BUILDER SITE, and that is what makes it standalone-sourceable
# under `set -u` rather than position-locked: build_control_sandbox() is called here, in the
# section that has always made that call, so $C, $CTRL_LOG, seed_control_env and control_config
# are established by this file instead of reached back for. Execution order is unchanged — the
# source stanza sits in the position this block vacated, so the builder runs exactly where it did.
# What DID change is who provides the sandbox to the control domains sourced after this one: they
# used to name a section of run.sh, and now they name this file. Their headers say so.
#
# ONE FILE, NOT TWO — a disclosed departure from the #1105 cut map's R12 row, which names
# test-control-apply.sh + test-control-audit.sh with the audit half self-arming. Re-derived at the
# tip, the two halves are one stateful timeline rather than two domains, and the seam the map
# proposes is the one place a split is unsafe:
# - The apply half ends by removing the result and staged files its own #556 control-path leg
#   wrote, and its comment says why: the counters below assume a clean spool. The section that
#   follows asserts the results dir holds exactly one file after a malformed id. That exact count
#   is established by a cleanup that sits across the proposed boundary.
# - An audit half armed with its own builder + seed_control_env + control_config + apply would
#   still satisfy that count sourced alone, because an empty spool yields the same one file — the
#   same number for a different reason than it holds in position. Green standalone and green in
#   position on two different mechanisms is not evidence that the arm reproduces the state; it is
#   the shape where a later change to the apply half reds only the in-position run.
# - A builder-only arm stanza is weaker still. $C is the fixed path under $SANDBOX, the builder's
#   mkdir -p only creates, its copies are static inputs, and seed_control_env/control_config are
#   DEFINED inside it and not called by it — so it binds the names under `set -u` and establishes
#   none of the state the assertions read. It would arm in name only.
# Keeping the timeline in one file retires the ordering dependency instead of documenting it,
# which is what #1105 is for, and it costs nothing: the file is under the budget generator's
# floor, so it takes no tsv row.
#
# Re-derivations, audited over this WHOLE file, this header included, with split-name-audit.py.
# That tool is lane-local and is NOT in this repo, so nothing below rests on it: each claim is
# written to be re-derived here with git and grep alone, and should be treated as a claim to check.
# - $C and $CTRL_LOG are assigned nowhere in tests/stack except inside build_control_sandbox(),
#   which this file calls above its first read of either. Self-provided, not inherited. (Strip
#   comments before the grep, and fire it on a name you know is assigned in several files first —
#   a probe that has never matched is not an instrument.)
# - $WALLET is read by the config renders below and by lib.sh's control_config() closure, and it
#   is assigned at column 1 nowhere: both sandbox builders default it as "${WALLET:-$VALID_PRIMARY}"
#   (#1305). This file's own builder call binds it, so the ordering accident that used to supply it
#   from a far-earlier val-sandbox section is retired here rather than inherited.
# - $SANDBOX and $VALID_TARI are lib.sh top-level constants, assigned at column 1 outside every
#   function. Read-only here.
# - $REQS, $RESULTS, $STAGED and $AUDIT are NOT the builder's — they are assigned in this file, as
#   plain derivations from $C, and the control domains sourced after this one read them from here.
#   That is the one ambient name-flow this cut leaves standing. It is disclosed in those files'
#   headers rather than seeded twice, because a second definition could drift from this one.
# - `line` is bound by `while IFS= read -r line`, not inherited. split-name-audit.py does not model
#   `read -r` and reports it as read-never-assigned — a tool limitation, not a dependency.

echo "== black-box: dashboard control channel (#33) =="
# A deployed sandbox with the control channel on: config carries a dashboard password (required)
# and dashboard.control.enabled, docker/sudo stubbed. The runner is exercised end-to-end against
# real spool files; `apply` inside it runs this same sandboxed pithead.
build_control_sandbox

# Fail-closed: enabling the control channel without a dashboard password must not validate.
seed_control_env
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan","control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "control.enabled without a password is rejected" "$rc" "1"
assert_contains "control-without-password message names the flag" "$out" "dashboard.control.enabled"

# Baseline: control enabled + password, pool main → a rendered .env with the control keys.
seed_control_env
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "baseline apply with control enabled succeeds" "$?" "0"
assert_contains "control toggle rendered to .env" "$(cat "$C/.env")" "DASHBOARD_CONTROL_ENABLED=true"
assert_contains "control spool dir rendered to .env" "$(cat "$C/.env")" "CONTROL_DIR=$C/data/control"
[ -d "$C/data/control/requests" ] && [ -d "$C/data/control/staged" ] &&
    [ -d "$C/data/control/results" ] && [ -d "$C/data/control/audit" ] &&
    ok "control spool dirs created" || bad "control spool dirs created" "missing under $C/data/control"
assert_contains "caddy access-log dir rendered to .env (#349)" "$(cat "$C/.env")" "CADDY_LOG_DIR=$C/data/caddy-logs"
[ -d "$C/data/caddy-logs" ] && ok "caddy access-log dir created (#349)" || bad "caddy access-log dir created (#349)" "missing"

echo "== black-box: apply --dry-run [--porcelain] (#33) =="
control_config mini # candidate change: pool main -> mini
cp "$C/.env" "$C/env.before"
: >"$CTRL_LOG"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run --porcelain exits 0" "$?" "0"
assert_contains "porcelain emits FLAG<TAB>KEY<TAB>MSG rows" "$out" "$(printf 'INFO\tP2POOL_FLAGS\t')"
assert_contains "porcelain row carries the describe_change message" "$out" "P2Pool sidechain changing"
if cmp -s "$C/.env" "$C/env.before"; then ok "dry-run leaves .env untouched"; else bad "dry-run leaves .env untouched" ".env changed"; fi
case "$(grep 'compose up' "$CTRL_LOG" 2>/dev/null || true)" in
"") ok "dry-run touches no container" ;;
*) bad "dry-run touches no container" "docker compose up was called" ;;
esac
[ ! -f "$C/.env.dryrun" ] && ok "dry-run staging file removed" || bad "dry-run staging file removed" ".env.dryrun left behind"
# Human (non-porcelain) preview prints the bullet form of the same row.
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>/dev/null)"
assert_contains "human dry-run prints the preview bullet" "$out" "• P2Pool sidechain changing"
# --porcelain without --dry-run is refused (it would silently look like a real apply).
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --porcelain 2>&1)"
assert_rc "--porcelain without --dry-run is rejected" "$?" "1"

# PITHEAD_CONFIG_FILE points ONE invocation at a candidate config; config.json is not consulted.
control_config main # config.json back to the applied state (no changes)
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"nano"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/alt.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" PITHEAD_CONFIG_FILE="$C/alt.json" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_contains "PITHEAD_CONFIG_FILE override is honoured" "$out" "37890" # nano's p2p port
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_eq "without the override, config.json shows no changes" "$out" ""

echo "== black-box: symlink-invoked stack renders physical paths (#695) =="
# A stack managed through a deploy symlink (`current -> pithead-vX.Y.Z`) must render the same
# .env as one managed from the physical dir: SCRIPT_DIR resolves with pwd -P, so an unedited
# preview through the symlink shows zero changes and an apply never rewrites the $PWD-derived
# paths (CLEARNET_STATE_DIR & co.) to the symlink spelling.
ln -sfn "$C" "$SANDBOX/current-link"
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>/dev/null)"
assert_rc "dry-run through the symlink exits 0" "$?" "0"
assert_eq "unedited preview through the symlink shows zero changes (#695)" "$out" ""
out="$(cd "$SANDBOX/current-link" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply through the symlink succeeds" "$?" "0"
assert_contains "clearnet state dir keeps the physical path" "$(cat "$C/.env")" "CLEARNET_STATE_DIR=$C/data/clearnet-state"
assert_not_contains "the symlink spelling never reaches .env" "$(cat "$C/.env")" "current-link"
rm -f "$SANDBOX/current-link"

echo "== black-box: apply --dry-run is read-only re: node credential generation (#556) =="
# Direct CLI leg: a fresh/hand-edited local-node config with placeholder/empty creds must not have
# config.json rewritten by a --dry-run preview — the read-only contract #556 reported broken
# (persist_node_credentials was writing the freshly-generated creds back to disk).
printf '{ "monero":{"mode":"local","wallet_address":"%s","node_username":"","node_password":""},
          "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"},
          "dashboard":{"secure":true,"host":"box.lan",
                       "auth":{"username":"admin","password":"a control passphrase"},
                       "control":{"enabled":true}} }\n' "$WALLET" >"$C/config.json"
cp "$C/config.json" "$C/config.json.556before"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" NO_COLOR=1 ./pithead apply --dry-run 2>&1)"
assert_rc "dry-run with placeholder node creds still validates" "$?" "0"
if cmp -s "$C/config.json" "$C/config.json.556before"; then
    ok "dry-run leaves config.json byte-identical with placeholder node creds (#556)"
else
    bad "dry-run leaves config.json byte-identical with placeholder node creds (#556)" "config.json was rewritten"
fi
assert_contains "dry-run still previews the credential it would generate (in-memory only)" "$out" "Monero node RPC credential"
rm -f "$C/config.json.556before"

# Control-channel leg: the same blank-creds config staged through the control path must not have
# its ON-DISK STAGED COPY rewritten by the dry-run re-validation either (#556) — the same write,
# one level removed, that used to leave a generated secret sitting in data/control/staged/ and
# could dirty the diff a later commit gate re-derives from that file.
UUID0="00000000-0000-4000-8000-000000000000"
REQS0="$C/data/control/requests"
STAGED0="$C/data/control/staged"
RESULTS0="$C/data/control/results"
jq -n --arg w "$WALLET" --arg id "$UUID0" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"",node_password:""},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS0/$UUID0.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead control-run-pending >/dev/null 2>&1)
assert_eq "blank-creds preview status" "$(jq -r '.status' "$RESULTS0/$UUID0.json" 2>/dev/null)" "previewed"
assert_eq "staged copy keeps the blank node_username — not persisted (#556)" "$(jq -r '.monero.node_username' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
assert_eq "staged copy keeps the blank node_password — not persisted (#556)" "$(jq -r '.monero.node_password' "$STAGED0/$UUID0.json" 2>/dev/null)" ""
# Clean up: the result/staged counters the tests below assume start from a clean spool.
rm -f "$RESULTS0/$UUID0.json" "$STAGED0/$UUID0.json"
control_config main # restore config.json to the state control-run-pending below expects

echo "== black-box: control-run-pending (#33) =="
UUID1="11111111-1111-4111-8111-111111111111"
UUID2="22222222-2222-4222-8222-222222222222"
REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"
STAGED="$C/data/control/staged"
AUDIT="$C/data/control/audit/control.log"

# Preview: a valid typed intent (pool main -> mini) → previewed result + a host-side staged copy.
jq -n --arg w "$WALLET" --arg id "$UUID1" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID1.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a valid preview" "$?" "0"
[ ! -f "$REQS/$UUID1.json" ] && ok "request claimed out of requests/" || bad "request claimed out of requests/" "still present"
assert_eq "preview result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "previewed"
assert_contains "preview result carries the change row" "$(jq -r '.changes[].msg' "$RESULTS/$UUID1.json" 2>/dev/null)" "P2Pool sidechain changing"
assert_eq "pool switch alone is not destructive" "$(jq -r '.destructive' "$RESULTS/$UUID1.json" 2>/dev/null)" "false"
[ -f "$STAGED/$UUID1.json" ] && ok "candidate staged host-side" || bad "candidate staged host-side" "missing"
# The staged copy carries merged secrets — it must land owner-only (#33 re-review).
assert_eq "staged candidate is mode 600" "$(file_mode "$STAGED/$UUID1.json")" "600"
assert_contains "preview audited" "$(cat "$AUDIT" 2>/dev/null)" "\"action\":\"preview\",\"status\":\"previewed\""

# Malformed id: it would become a filename, so the request is discarded with no result at all.
printf '{"id":"../../etc/passwd","action":"preview","actor":"x","config":{}}\n' >"$REQS/evil.json"
out="$(run_pending)"
assert_rc "runner exits 0 on a malformed id" "$?" "0"
assert_contains "malformed id is called out" "$out" "malformed id"
assert_eq "no result file for a malformed id" "$(ls "$RESULTS" | wc -l | tr -d ' ')" "1"

# Well-formed but non-v4 id (version nibble 1): the loose old regex accepted any hex uuid shape;
# the tightened gate (#438) pins version 4 + RFC variant, so this must be discarded too.
printf '{"id":"11111111-1111-1111-1111-111111111111","action":"preview","actor":"x","config":{}}\n' >"$REQS/nonv4.json"
out="$(run_pending)"
assert_contains "non-v4 uuid id is discarded" "$out" "malformed id"
[ ! -f "$RESULTS/11111111-1111-1111-1111-111111111111.json" ] &&
    ok "no result file for a non-v4 id" || bad "no result file for a non-v4 id" "result written"

# Unknown action / extra keys / invalid candidate config → rejected results, nothing staged.
printf '{"id":"%s","action":"exec","actor":"x"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "unknown action is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
# A malicious action string on the unknown-action path cannot forge a second line into the
# tamper-evidence audit log: the field is charset-stripped at the write chokepoint. Feed an action
# carrying a newline + a fake JSON entry, then assert every audit line is still valid JSON and no
# forged status leaked in (#349 review).
audit_before=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
# jq decodes the \n and quotes into REAL characters in the action value, so the host-side
# jq -r '.action' hands control_audit a string with an embedded newline + fake JSON object —
# the exact shape that would append a forged line without the charset strip.
jq -nc --arg id "$UUID2" '{id:$id,actor:"x",action:"evil\n{\"ts\":\"0\",\"forged\":\"yes\"}"}' >"$REQS/$UUID2.json"
run_pending >/dev/null
audit_after=$(wc -l <"$AUDIT" 2>/dev/null || echo 0)
assert_eq "forged-action intent adds exactly one audit line" "$((audit_after - audit_before))" "1"
while IFS= read -r line; do printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad "every audit line is valid JSON" "unparseable: $line"; done <"$AUDIT"
ok "every audit line is valid JSON after a forged-action intent"
assert_not_contains "no forged audit entry leaked in" "$(cat "$AUDIT")" '"forged":"yes"'
printf '{"id":"%s","action":"preview","actor":"x","config":{},"cmd":"rm -rf /"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "extra request keys are rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "unexpected keys"
jq -n --arg w "$WALLET" --arg id "$UUID2" '{id:$id, action:"preview", actor:"x", config:{
    monero:{mode:"local",wallet_address:$w}, tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"banana"},
    dashboard:{auth:{password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_eq "invalid candidate config is rejected" "$(jq -r '.status' "$RESULTS/$UUID2.json" 2>/dev/null)" "rejected"
assert_contains "rejection carries pithead's validation error" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "p2pool.pool"
[ ! -f "$STAGED/$UUID2.json" ] && ok "rejected candidate is not left staged" || bad "rejected candidate is not left staged" "staged file present"

# Commit without a staged intent → rejected (preview first).
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "commit without a staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "preview first"

# Commit of the previewed intent: backup written, apply -y ran, audit line, result applied.
: >"$CTRL_LOG"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID1" >"$REQS/$UUID1.json"
run_pending >/dev/null
assert_eq "commit result status" "$(jq -r '.status' "$RESULTS/$UUID1.json" 2>/dev/null)" "applied"
assert_eq "committed config landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "mini"
[ -f "$C/config.json.bak-control" ] &&
    assert_eq "pre-change backup kept" "$(jq -r '.p2pool.pool' "$C/config.json.bak-control")" "main" ||
    bad "pre-change backup kept" "config.json.bak-control missing"
assert_contains "commit ran the real apply (containers recreated)" "$(cat "$CTRL_LOG")" "compose up"
assert_contains "commit audited with the actor" "$(cat "$AUDIT")" "\"actor\":\"admin\",\"action\":\"commit\",\"status\":\"applied\""
[ ! -f "$STAGED/$UUID1.json" ] && ok "staged intent consumed on commit" || bad "staged intent consumed on commit" "still staged"

# Operator keeps ownership of the stack files the root runner's apply wrote (#33 v1.4): control_run_pending
# is root, so its apply would render .env root:root 0600 — unreadable to the non-root operator. The
# re-own derives the owner from config.json (operator-owned, container can't write it) so a commit
# matches a normal apply. Assert every operator-facing file is owned by config.json's owner, so a
# non-root operator can still read .env / re-render on the next apply.
cfg_uid="$(file_uid "$C/config.json")"
for reowned in ".env" "Caddyfile" "config.json.bak-control"; do
    [ -e "$C/$reowned" ] &&
        assert_eq "$reowned owned by the config.json owner after a control commit" "$(file_uid "$C/$reowned")" "$cfg_uid" ||
        bad "$reowned present after a control commit" "missing"
done

echo "== black-box: audit log records names, never values (#349) =="
# WHAT changed rides in the audit entry as env-key NAMES (main -> mini touches the p2pool keys);
# no config or secret VALUE may ever land in the log — it is mounted into the dashboard container.
assert_contains "commit audit records the changed key names" "$(cat "$AUDIT")" '"keys":"P2POOL'
assert_contains "preview audit records the changed key names" "$(grep '"status":"previewed"' "$AUDIT" | tail -n 1)" '"keys":"P2POOL'
case "$(cat "$AUDIT")" in
*"a control passphrase"* | *"$WALLET"* | *mini*) bad "audit log holds no config or secret values" "a value leaked into audit/control.log" ;;
*) ok "audit log holds no config or secret values" ;;
esac

# Expired staged intent (older than the 10-min commit window) → rejected as expired and cleared.
# Age it ~15 min: past the 10-min expiry the commit enforces, but INSIDE the 60-min stale sweep so
# the sweep leaves it for control_commit to judge (a 2020 date would be swept first, #33 hardening).
jq -n --arg id "$UUID2" '{}' >"$STAGED/$UUID2.json"
touch -t "$(date -d '15 minutes ago' +%Y%m%d%H%M 2>/dev/null || date -v-15M +%Y%m%d%H%M)" "$STAGED/$UUID2.json"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID2" >"$REQS/$UUID2.json"
run_pending >/dev/null
assert_contains "expired staged intent is rejected" "$(jq -r '.error' "$RESULTS/$UUID2.json" 2>/dev/null)" "expired"
[ ! -f "$STAGED/$UUID2.json" ] && ok "expired staged intent cleared" || bad "expired staged intent cleared" "still staged"
