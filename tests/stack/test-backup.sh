# shellcheck shell=bash
#
# Backup domain (#1105 Phase 1, develop-v2 lane): the archive/restore round-trip and the
# reset-dashboard verb — stack_backup's bounded retry on a tar race (#970), the
# backup_require_items/backup_diagnose_items preflight that names a missing or dangling item
# before anything is touched and diagnoses a tar failure by its real cwd/item state (#1244), an
# absolute PITHEAD_CONFIG_FILE override archived at its real path rather than a doubled
# $PWD-prefixed one (#1244), the plaintext backup/restore round-trip including the archive-layout
# and stay-inside-the-sandbox checks (#140), the encrypted round-trip end to end — unattended
# refusal without a passphrase, --no-encrypt opt-out, env-var/prompt passphrases, wrong-passphrase
# and tamper/truncation refusals before extraction, and a failed encrypted backup leaving nothing
# behind (#374/#549), a failed plaintext backup restarting a stack that was running and removing
# the partial archive (#551), and reset-dashboard targeting the LIVE .env data dirs rather than a
# possibly-unapplied config.json, refusing to guess without them, and its final compose_up_checked
# call being if!-guarded like every other call site so a real compose failure surfaces the #180
# subnet-collision explanation instead of tripping the raw ERR trap (#139/#557/#180).
# Sourced by tests/stack/run.sh.
#
# This file merges TWO clusters that sat apart in run.sh, on either side of the installer tests and
# the secrets domain (both stay in run.sh / move to test-secrets.sh respectively): the stack_backup
# unit tests used to run first, and the backup/restore + reset-dashboard black-box tests used to run
# roughly 500 lines later, after test-rig-worker.sh's and test-monero-tari.sh's source lines. Sourcing
# this file in one place moves the second cluster earlier in execution order. Confirmed safe: every
# fixture below builds its own throwaway dir under $SANDBOX ($RB/$CJ/$BK/$FB/$R/$RD557) — nothing
# here reads or writes $V, $C, or any state a section between the two original positions left behind,
# and nothing between those two original positions reads anything this file's fixtures produce.
#
# Re-derivations (the sandbox-builder WALLET trap — see #1305, still open on this lane):
# - $WALLET: set by lib.sh's build_val_sandbox() (as the checksum-valid $VALID_PRIMARY constant), which
#   the "config validation" black-box calls once, ahead of every section below that reads it as a
#   config.json field value. That section lives in test-config.sh, sourced ahead of this file (a
#   generic multi-field validator, not a backup concern), and this file never needs $V itself (each
#   fixture above builds its own sandbox instead of reusing the shared one) — so re-deriving the bare
#   string is enough; calling the heavier build_val_sandbox() would build a $V this file never touches.
# - $VALID_TARI is a plain lib.sh top-level constant (not
#   build_val_sandbox()-scoped), so it needs no re-derivation here or anywhere else.
WALLET="$VALID_PRIMARY" # checksum-valid mainnet primary (the XMRig donation address) — see #1305

echo "== unit: stack_backup — one bounded retry on a tar race (#970) =="
# Even with the stack stopped, tar can lose a race against a teardown's last flush — exit 1
# under pipefail failed the whole backup once on the KVM bench. The fixture sudo fails the
# FIRST tar with tar's real race error, then passes through: one retry must land the archive.
RB="$(cd "$SANDBOX" && pwd -P)/backup-retry"
mkdir -p "$RB/build/tari" "$RB/data/tor" "$RB/data/dashboard" "$RB/bin"
cp "$STACK" "$RB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RB/build/tari/"
cat >"$RB/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$RB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
if [ "$1" = "tar" ] && [ ! -f "${RETRY_MARK:?}" ]; then
    : >"$RETRY_MARK"
    echo "tar: fixture-member: file changed as we read it" >&2
    exit 1
fi
exec "$@"
EOF
chmod +x "$RB/bin/docker" "$RB/bin/sudo"
cat >"$RB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RB/config.json"
out="$(cd "$RB" && PATH="$RB/bin:$PATH" RETRY_MARK="$RB/first-tar-failed" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "backup survives one tar race via the retry" "$rc" "0"
assert_contains "the first failure is loud, not silent" "$out" "retrying once"
assert_eq "the retry actually ran (fixture consumed)" "$([ -f "$RB/first-tar-failed" ] && echo yes)" "yes"
rbarchive="$(ls "$RB"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rbarchive" ] && [ -s "$rbarchive" ]; } && ok "retry produced a real archive" || bad "retry produced a real archive" "no .enc archive"

echo "== unit: backup_require_items — refuses a missing/dangling required item before anything is touched (#1244) =="
# The KVM battery caught tar failing to stat config.json AFTER the stack had already been
# stopped for the backup (#1059) — a real archive attempt was thrown away and the box paid for
# a stop/start cycle it didn't need. These two functions are pulled out of stack_backup and
# sourced directly (the same pattern gate_ready/os_update_rollback_verdict use) so the refusal
# and the diagnostic dump are provable without driving tar, sudo, or the whole backup flow.
BRI="$SANDBOX/backup-require-items"
mkdir -p "$BRI"
: >"$BRI/present.txt"
ln -s "$BRI/nowhere" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/missing.txt" 2>&1)
rc=$?
assert_rc "a genuinely missing item refuses (nonzero)" "$rc" "1"
assert_contains "the refusal names the exact resolved path" "$out" "$BRI/missing.txt"
assert_contains "the refusal says what to do next" "$out" "pithead setup"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" "$BRI/dangling.txt" 2>&1)
rc=$?
assert_rc "a dangling symlink refuses the same way a missing file does" "$rc" "1"
assert_contains "the dangling-symlink refusal also names the path" "$out" "$BRI/dangling.txt"
out=$(run_sourced "$BRI" backup_require_items "$BRI/present.txt" 2>&1)
rc=$?
assert_rc "every item present passes silently" "$rc" "0"
assert_eq "nothing is printed when every required item is present" "$out" ""

echo "== unit: backup_diagnose_items — a tar failure names its cwd and each item's real state (#1244) =="
# The diagnostic half of the same fix: when tar fails anyway (both #970 retry attempts spent),
# the failure names the -C directory it ran against and what each resolved item actually was —
# so the NEXT occurrence of #1059's run-conditional vanish doesn't need another bench boot
# before anyone can look.
out=$(run_sourced "$BRI" backup_diagnose_items "/" "$BRI/present.txt" "$BRI/missing.txt" "$BRI/dangling.txt" 2>&1)
assert_contains "names the -C directory tar ran against" "$out" 'tar ran with -C "/"'
assert_contains "a present item is reported present with its own listing" "$out" "present: "
assert_contains "the present item's line names its own path" "$out" "$BRI/present.txt"
assert_contains "a missing item is called out by name" "$out" "MISSING: $BRI/missing.txt"
assert_contains "a dangling symlink is distinguished from a plain miss" "$out" "DANGLING SYMLINK: $BRI/dangling.txt"
unset BRI out rc

echo "== unit: stack_backup — an absolute CONFIG_FILE override is archived at its real path, not a doubled one (#1244) =="
# PITHEAD_CONFIG_FILE (the control gate's staged-config preview seam) can be an ABSOLUTE path.
# Before this fix, stack_backup unconditionally prefixed $PWD onto it ("$PWD/$CONFIG_FILE"),
# which for an absolute override built a doubled, nonexistent path like
# "$PWD//tmp/staged.json" — tar would fail to stat THAT, the same shape #1059 hunted, just from
# a cause the live capture ruled out rather than the one that actually happened.
CJ="$SANDBOX/backup-cfg-override"
mkdir -p "$CJ/build/tari" "$CJ/data/tor" "$CJ/data/dashboard" "$CJ/bin"
cp "$STACK" "$CJ/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CJ/build/tari/"
cat >"$CJ/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$CJ/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$CJ/bin/docker" "$CJ/bin/sudo"
cat >"$CJ/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=CJTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
# The override candidate lives OUTSIDE $CJ entirely — a doubled "$CJ/<absolute candidate>" path
# could never coincidentally resolve to something real, so a pass here can only mean the join
# is absolute-safe, not a lucky path collision.
CJALT="$SANDBOX/backup-cfg-override-elsewhere"
mkdir -p "$CJALT"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$CJALT/candidate.json"
out=$(cd "$CJ" && PATH="$CJ/bin:$PATH" PITHEAD_CONFIG_FILE="$CJALT/candidate.json" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)
rc=$?
assert_rc "backup succeeds against an absolute CONFIG_FILE override" "$rc" "0"
cjarchive="$(ls "$CJ"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$cjarchive" ] && [ -s "$cjarchive" ]; } && ok "override archive was written" || bad "override archive was written" "no .enc archive"
# The archive's member list is the ground truth for what tar was actually told to stat: the
# override's OWN absolute path (leading / stripped, same as every other item), never a doubled
# artifact of the old $PWD-prefix bug.
cjlist=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass pass:hunter2 -in "$cjarchive" 2>/dev/null | tar -tzf - 2>/dev/null)
assert_contains "the archive carries the override's real, un-doubled path" "$cjlist" "${CJALT#/}/candidate.json"
assert_not_contains "the archive never carries a \$PWD-doubled override path" "$cjlist" "${CJ#/}${CJALT}"
unset CJ CJALT out rc cjarchive cjlist

echo "== black-box: backup -> restore round-trip (#140) =="
# backup/restore touch irreplaceable state (onion keys, the dashboard DB) and have fiddly logic
# (leading-'/' strip, the disk pre-check, stop->backup->start). They shell out only to tar/du/df/
# docker/sudo, so a full round-trip is stubbable: the docker stub reports the stack NOT running, and
# a smart sudo runs tar/du/df for real (so the archive is genuinely created/extracted) but no-ops
# chown (we can't chown to 100:101 unprivileged). The archive stores paths relative to '/', and every
# path is under the sandbox, so `restore`'s `tar -C /` can only write back inside it (asserted below).
# Use the sandbox's PHYSICAL path (pwd -P): `restore` extracts at '/', and on macOS the /var ->
# /private/var symlink would otherwise make BSD tar refuse to "extract through symlink" (Linux /tmp
# isn't symlinked, so this is a no-op there).
BK="$(cd "$SANDBOX" && pwd -P)/backup"
mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
cp "$STACK" "$BK/pithead"
cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;;   # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run backup/restore's privileged commands as the test user, except chown (can't set 100:101
# unprivileged) which is accepted as a no-op so restore doesn't abort.
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$BK/bin/docker" "$BK/bin/sudo"
cat >"$BK/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=BKTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$BK/config.json"
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$BK/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$BK/data/dashboard/dashboard.db"

# 1) Backup creates a timestamped archive. --no-encrypt keeps this #140 round-trip on the plaintext
# path (encryption is exercised in the #374 block below); an unattended run without a passphrase
# now refuses rather than downgrading, so the flag is required here.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "backup exits 0" "$rc" "0"
archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$archive" ] && [ -f "$archive" ]; } && ok "backup archive created" || bad "backup archive created" "no archive under backups/"

# 2) Archive layout: the irreplaceable bits are in it; blockchains are NOT (no --with-chains).
listing="$(tar -tzf "$archive" 2>/dev/null)"
assert_contains "archive has config.json" "$listing" "config.json"
assert_contains "archive has .env" "$listing" ".env"
assert_contains "archive has Caddyfile" "$listing" "Caddyfile"
assert_contains "archive has the tor onion key" "$listing" "hs_ed25519_secret_key"
assert_contains "archive has the dashboard db" "$listing" "dashboard.db"
case "$listing" in
*data/monero* | *data/p2pool/* | *data/tari*) bad "archive excludes blockchains by default" "chain data present without --with-chains" ;;
*) ok "archive excludes blockchains by default" ;;
esac
# Safety tripwire: every archived path is under the sandbox, so restore's `tar -C /` can't escape it.
sandbox_rel="${BK#/}"
escaped="$(printf '%s\n' "$listing" | grep -v '^$' | grep -v "^$sandbox_rel" || true)"
assert_eq "archive paths stay inside the sandbox" "$escaped" ""

# 3) Round-trip: corrupt/delete the live files, restore, assert the originals come back in place.
printf 'CORRUPTED\n' >"$BK/Caddyfile"
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$archive" 2>&1)"
rc=$?
assert_rc "restore exits 0" "$rc" "0"
assert_eq "restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4) Low-space pre-check (#127): a df reporting almost no free space makes backup prompt; answering
# "no" cancels and writes nothing, while --yes proceeds with a warning. The check runs BEFORE the
# stack is touched, so a cancel leaves everything as it was.
cat >"$BK/bin/df" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on' '/dev/fake 100 99 1 99% /'
EOF
chmod +x "$BK/bin/df"
rm -f "$BK"/backups/pithead-backup-*.tar.gz
# stdin answers two prompts since #374: empty passphrase (-> plaintext fallback), then 'n'.
out="$(cd "$BK" && printf '\nn\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
assert_contains "low-space prompt, then cancel" "$out" "ancelled"
leftover="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
assert_eq "cancelled backup writes no archive" "$leftover" ""
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "low-space backup proceeds with --yes" "$rc" "0"
assert_contains "low-space backup warns first" "$out" "Low free space"

echo "== black-box: encrypted backup -> restore (#374) =="
# The archive holds the stack's full secret material (onion keys, .env, dashboard DB), so backup
# encrypts by default (openssl aes-256-cbc + pbkdf2). Covered here: the unattended-without-
# passphrase REFUSAL (an automated run must never silently downgrade to plaintext), the explicit
# --no-encrypt opt-out, env-var and prompt encrypt round-trips, wrong-passphrase rejection BEFORE
# anything is touched, a tamper/truncation refusal before extraction, legacy/garbage archives, and
# that a failed encrypted backup leaves no file behind (the tar|openssl stream means no plaintext
# temp ever).
rm -f "$BK/bin/df" "$BK"/backups/pithead-backup-*

# 1a) --yes with no passphrase REFUSES (no silent plaintext downgrade for cron); writes nothing.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "unattended backup without passphrase exits non-zero" || bad "unattended backup without passphrase exits non-zero" "rc=0"
assert_contains "refusal names the missing passphrase" "$out" "PITHEAD_BACKUP_PASSPHRASE"
assert_eq "refused unattended backup writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
# 1b) --no-encrypt is the explicit plaintext opt-out (loud warning, exits 0, writes a plain archive).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "explicit --no-encrypt backup exits 0" "$rc" "0"
plain_optout="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_optout" ] && [ -f "$plain_optout" ]; } && ok "--no-encrypt writes a plaintext archive" || bad "--no-encrypt writes a plaintext archive" "no plain archive"
rm -f "$BK"/backups/pithead-backup-*

# 2) Env-var passphrase: a .enc archive with the openssl Salted__ header, no plaintext twin.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$enc_archive" ] && [ -f "$enc_archive" ]; } && ok "encrypted archive created (.enc)" || bad "encrypted archive created (.enc)" "no .enc under backups/"
assert_eq "archive starts with Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
plain_left="$(ls "$BK"/backups/*.tar.gz 2>/dev/null | head -1)"
assert_eq "no plaintext archive alongside the .enc" "$plain_left" ""
assert_contains "backup says to store the passphrase elsewhere" "$out" "passphrase"

# 3) Wrong passphrase: restore fails loudly before tar runs — live files untouched.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=wrong ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "wrong passphrase exits non-zero" || bad "wrong passphrase exits non-zero" "rc=0"
assert_contains "wrong passphrase names the cause" "$out" "rong passphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"

# 4) Right passphrase, via the prompt this time: full round-trip (archive was taken while the
# files held their -ORIG values, so restore must bring those back over the corrupted ones).
printf 'CORRUPTED\n' >"$BK/data/dashboard/dashboard.db"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && printf 'hunter2\n' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
assert_rc "encrypted restore exits 0" "$rc" "0"
assert_eq "encrypted restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
assert_eq "encrypted restore brings back the dashboard db" "$(cat "$BK/data/dashboard/dashboard.db")" "DBDATA-ORIG"
assert_eq "encrypted restore brings back the onion key" "$(cat "$BK/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-ORIG"

# 4b) Tampered/truncated ciphertext (CBC has no MAC): a flip past the first block passes the
# cheap magic pre-flight but must be caught by the full-stream verify BEFORE tar writes anything,
# so the live files survive. Truncating the archive tail simulates corruption/tampering.
printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
head -c $(($(wc -c <"$enc_archive") - 32)) "$enc_archive" >"$BK/backups/truncated.tar.gz.enc"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead restore -y "$BK/backups/truncated.tar.gz.enc" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "tampered archive exits non-zero" || bad "tampered archive exits non-zero" "rc=0"
assert_contains "tampered archive names integrity failure" "$out" "integrity"
assert_eq "tampered archive leaves live files untouched" "$(cat "$BK/Caddyfile")" "CADDY-LIVE"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated.tar.gz.enc"
# Leave the fixtures as this block found them (the round-trip above restored -ORIG) so the
# later plaintext-backup test captures -ORIG, not this test's probe value.
printf 'CADDY-ORIG\n' >"$BK/Caddyfile"

# 5) Interactive prompt path: passphrase typed twice encrypts; a mismatch aborts with no archive.
out="$(cd "$BK" && printf 'pw\npw\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
assert_rc "prompted encrypted backup exits 0" "$rc" "0"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
assert_eq "prompted backup writes Salted__" "$(head -c 8 "$enc_archive")" "Salted__"
rm -f "$BK"/backups/pithead-backup-*
out="$(cd "$BK" && printf 'pw\nother\n' | PATH="$BK/bin:$PATH" ./pithead backup 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "passphrase mismatch exits non-zero" || bad "passphrase mismatch exits non-zero" "rc=0"
assert_contains "passphrase mismatch says so" "$out" "do not match"
assert_eq "passphrase mismatch writes no archive" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""

# 6) --no-encrypt forces plaintext even with the env var set, and that legacy-format archive
# still restores through the gzip path (magic-byte detection, no flag).
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
assert_rc "--no-encrypt backup exits 0" "$rc" "0"
plain_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
{ [ -n "$plain_archive" ] && gzip -t "$plain_archive" 2>/dev/null; } && ok "--no-encrypt writes plain gzip" || bad "--no-encrypt writes plain gzip" "missing or not gzip"
printf 'CORRUPTED\n' >"$BK/Caddyfile"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$plain_archive" 2>&1)"
rc=$?
assert_rc "plaintext archive still restores" "$rc" "0"
assert_eq "plaintext restore brings back the Caddyfile" "$(cat "$BK/Caddyfile")" "CADDY-ORIG"
rm -f "$BK"/backups/pithead-backup-*

# 6b) Truncated plaintext archive (#549): mirrors the encrypted-branch tamper/truncation check
# (4b above) on the gzip path — a truncated archive must be rejected by a full-stream `tar -tzf`
# verify BEFORE extraction, with nothing written, instead of half-overwriting config.json/.env.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
plain_trunc_src="$(ls "$BK"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -1)"
config_before="$(cat "$BK/config.json")"
env_before="$(cat "$BK/.env")"
head -c "$(($(wc -c <"$plain_trunc_src") / 2))" "$plain_trunc_src" >"$BK/backups/truncated-plain.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/truncated-plain.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "truncated plaintext archive exits non-zero" || bad "truncated plaintext archive exits non-zero" "rc=0"
assert_contains "truncated plaintext archive names integrity failure" "$out" "integrity"
assert_eq "truncated plaintext archive leaves config.json untouched" "$(cat "$BK/config.json")" "$config_before"
assert_eq "truncated plaintext archive leaves .env untouched" "$(cat "$BK/.env")" "$env_before"
rm -f "$BK"/backups/pithead-backup-* "$BK/backups/truncated-plain.tar.gz"

# 7) A failed encrypted backup (openssl dies mid-stream) removes the partial archive.
cat >"$BK/bin/openssl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BK/bin/openssl"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=x ./pithead backup -y 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed encrypted backup exits non-zero" || bad "failed encrypted backup exits non-zero" "rc=0"
assert_eq "failed encrypted backup leaves nothing behind" "$(ls "$BK"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
rm -f "$BK/bin/openssl"

# 8) An archive that is neither encrypted nor gzip is refused before the overwrite prompt.
printf 'garbage-not-an-archive' >"$BK/backups/bogus.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$BK/backups/bogus.tar.gz" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "garbage archive is refused" || bad "garbage archive is refused" "rc=0"
assert_contains "garbage archive names the problem" "$out" "Not a pithead backup archive"
rm -f "$BK"/backups/bogus.tar.gz

# 9) Restore of an encrypted archive with no passphrase available (piped empty stdin) fails clean.
out="$(cd "$BK" && PATH="$BK/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
enc_archive="$(ls "$BK"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
out="$(cd "$BK" && printf '' | PATH="$BK/bin:$PATH" ./pithead restore -y "$enc_archive" 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "encrypted restore w/o passphrase exits non-zero" || bad "encrypted restore w/o passphrase exits non-zero" "rc=0"
assert_contains "encrypted restore w/o passphrase explains" "$out" "PITHEAD_BACKUP_PASSPHRASE"
rm -f "$BK"/backups/pithead-backup-*

echo "== black-box: failed plaintext backup restarts a running stack, removes the partial archive (#551) =="
# Companion to the #549 test above: a failed tar must not strand the stack stopped, nor leave a
# partial (root-owned) archive that looks like a valid backup. Shadow tar to fail unconditionally
# and simulate a RUNNING stack (was_running=1), so the failure path must call stack_up for real —
# proven here by "compose up" showing up in the docker log, not by stubbing stack_up away.
FB="$SANDBOX/failbackup"
mkdir -p "$FB/build/tari" "$FB/data/tor" "$FB/data/dashboard" "$FB/bin"
cp "$STACK" "$FB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$FB/build/tari/"
cat >"$FB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose ps --status running -q") echo cid123 ;; # non-empty -> stack treated as RUNNING
esac
exit 0
EOF
cat >"$FB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
cat >"$FB/bin/tar" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FB/bin/docker" "$FB/bin/sudo" "$FB/bin/tar"
cat >"$FB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=FBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FB/config.json"

out="$(cd "$FB" && DOCKER_LOG="$FB/docker.log" PATH="$FB/bin:$PATH" ./pithead backup -y --no-encrypt 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && ok "failed plaintext backup (running stack) exits non-zero" || bad "failed plaintext backup (running stack) exits non-zero" "rc=0"
assert_contains "failed plaintext backup names the cause" "$out" "partial archive was removed"
assert_eq "failed plaintext backup leaves no archive behind" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
assert_contains "failed plaintext backup restarts the stack" "$(cat "$FB/docker.log" 2>/dev/null)" "compose up"

echo "== black-box: reset-dashboard targets .env dirs, not config.json (#139) =="
# reset-dashboard must wipe the LIVE deployment's data dirs (from .env), not a path the user may
# have edited into config.json without applying. docker = noop; sudo only LOGS (never executes the
# rm), so we can assert what it would have targeted without deleting anything.
R="$SANDBOX/reset"
mkdir -p "$R/bin" "$R/envdir/dashboard" "$R/envdir/p2pool"
cp "$STACK" "$R/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/bin/docker"
cat >"$R/bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "[sudo] $*" >> "${SUDO_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$R/bin/docker" "$R/bin/sudo"
cat >"$R/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
DASHBOARD_DATA_DIR=$R/envdir/dashboard
P2POOL_DATA_DIR=$R/envdir/p2pool
EOF
# config.json points the data dirs somewhere ELSE (a path the running stack never used).
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"data_dir":"%s/CONFIGONLY/p2pool"}, "dashboard":{"data_dir":"%s/CONFIGONLY/dashboard"} }\n' "$WALLET" "$R" "$R" >"$R/config.json"
SUDO_LOG="$R/sudo.log"
: >"$SUDO_LOG"
out="$(cd "$R" && SUDO_LOG="$SUDO_LOG" PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard succeeds" "$rc" "0"
sudo_calls="$(cat "$SUDO_LOG")"
assert_contains "reset rm targets the .env dashboard dir" "$sudo_calls" "rm -rf $R/envdir/dashboard"
case "$sudo_calls" in *CONFIGONLY*) bad "reset must ignore the config-only data_dir" "$sudo_calls" ;; *) ok "reset ignores the config-only data_dir" ;; esac

echo "== black-box: reset-dashboard refuses to guess without .env dirs (#139) =="
printf 'DEPLOYMENT_COMPLETED=true\nCOMPOSE_PROFILES=local_node\nHOST_IP=box.lan\n' >"$R/.env"
out="$(cd "$R" && SUDO_LOG=/dev/null PATH="$R/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset refuses with no data dirs in .env" "$rc" "1"
assert_contains "reset refuse message" "$out" "refusing to guess"

echo "== black-box: reset-dashboard's final compose_up_checked is if!-guarded, not bare (#557/#180) =="
# Before #557: the last compose_up_checked call in reset_dashboard was bare (every OTHER call site
# wraps it in `if !`, per the contract at compose_up_checked's own definition). A bare call let a real
# compose failure trip errexit INSIDE compose_up_checked's own `docker compose up | tee` pipeline,
# before the #180 subnet-collision explanation printed. Real `./pithead` (not sourced) arms
# `trap on_err ERR` exactly like production, so this reproduces the actual operator experience.
RD557="$SANDBOX/reset557"
mkdir -p "$RD557/bin" "$RD557/envdir/dashboard" "$RD557/envdir/p2pool"
cp "$STACK" "$RD557/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RD557/bin/sudo"
cat >"$RD557/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose up"*)
    echo "Error response from daemon: Pool overlaps with other one on this address space" >&2
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$RD557/bin/docker" "$RD557/bin/sudo"
cat >"$RD557/.env" <<EOF
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
HOST_IP=box.lan
NETWORK_SUBNET=172.28.0.0/24
DASHBOARD_DATA_DIR=$RD557/envdir/dashboard
P2POOL_DATA_DIR=$RD557/envdir/p2pool
EOF
printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$RD557/config.json"
out="$(cd "$RD557" && PATH="$RD557/bin:$PATH" ./pithead reset-dashboard -y 2>&1)"
rc=$?
assert_rc "reset-dashboard: compose failure still exits 1 (fail-closed unchanged)" "$rc" "1"
assert_contains "reset-dashboard: #180 subnet-collision explanation reaches the operator (#557)" \
    "$out" "Docker refused the stack's bridge subnet"
assert_contains "reset-dashboard: crafted failure message names the retry command" "$out" "did NOT come back up"
