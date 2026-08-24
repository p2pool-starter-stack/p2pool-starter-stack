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
# shellcheck source=tests/stack/test-harness-tooling.sh
source "$HERE/test-harness-tooling.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor.sh
source "$HERE/test-doctor.sh"

echo "== unit: docker_boot_enabled (#137) =="
# A systemctl stub on PATH; FAKE_BOOT picks which unit reports "enabled". Docker counts as
# boot-enabled if EITHER docker.service or docker.socket is enabled.
BOOT="$SANDBOX/boot"
mkdir -p "$BOOT/bin"
cat >"$BOOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "is-enabled docker.service") [ "${FAKE_BOOT:-}" = "service" ] && exit 0 || exit 1 ;;
  "is-enabled docker.socket")  [ "${FAKE_BOOT:-}" = "socket"  ] && exit 0 || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BOOT/bin/systemctl"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=service run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.service enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=socket run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "docker.socket enabled -> 0" "$?" "0"
PATH="$BOOT/bin:$PATH" FAKE_BOOT=none run_sourced "$SANDBOX" docker_boot_enabled
assert_rc "neither enabled -> 1" "$?" "1"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-upgrade.sh
source "$HERE/test-control-upgrade.sh"

# shellcheck source=tests/stack/test-release-signing.sh
source "$HERE/test-release-signing.sh"

echo "== unit: config_bool honours an explicit false (jq // false-coercion guard, #294) =="
# Regression for #294: `.x // true` returns true even when x is explicitly false (jq treats false as
# empty), which silently broke the #270 firewall opt-out (config false → .env stayed true) and
# xvb.tor=false. config_bool null-checks instead. CONFIG_FILE is the relative "config.json", so a
# fixture in the cwd is what the sourced helper reads.
CB="$SANDBOX/cb"
mkdir -p "$CB"
printf '{"network":{"tor_egress_firewall":false},"xvb":{"tor":false}}' >"$CB/config.json"
assert_eq "explicit false honoured (firewall)" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "false"
assert_eq "explicit false honoured (xvb.tor)" "$(run_sourced "$CB" config_bool '.xvb.tor' true)" "false"
printf '{"network":{"tor_egress_firewall":true}}' >"$CB/config.json"
assert_eq "explicit true honoured" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
printf '{}' >"$CB/config.json"
assert_eq "absent -> default true" "$(run_sourced "$CB" config_bool '.network.tor_egress_firewall' true)" "true"
assert_eq "absent -> default false" "$(run_sourced "$CB" config_bool '.xvb.tor' false)" "false"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-dashboard.sh
source "$HERE/test-dashboard.sh"

# shellcheck source=tests/stack/test-dashboard-onion.sh
source "$HERE/test-dashboard-onion.sh"

# shellcheck source=tests/stack/test-release.sh
source "$HERE/test-release.sh"

# The XvB tier thresholds are hard-coded in config.py (TIER_DEFAULTS) and stated explicitly in
# docs/architecture.md. Drift guard: each config value must match the doc's human form, so the
# user-facing table can't silently fall out of sync if TIER_DEFAULTS ever changes.
tier_cfg="$ROOT/dashboard/mining_dashboard/config/config.py"
tier_doc="$ROOT/docs/architecture.md"
for tier in "donor:1_000:1 kH/s" "vip:10_000:10 kH/s" "whale:100_000:100 kH/s" "mega:1_000_000:1 MH/s"; do
    t_name="${tier%%:*}"
    t_rest="${tier#*:}"
    t_val="${t_rest%%:*}"
    t_human="${t_rest#*:}"
    if grep -qE ": ${t_val}[ ,]" "$tier_cfg" && grep -qF "$t_human" "$tier_doc"; then
        ok "XvB $t_name tier: config.py $t_val matches docs '$t_human'"
    else
        bad "XvB $t_name tier docs match TIER_DEFAULTS" "config $t_val / doc '$t_human' out of sync"
    fi
done

echo "== unit: env helpers =="
printf 'A=1\nB=two\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/old.env"
printf 'A=1\nB=three\nC=4\nPROXY_AUTH_TOKEN=keep=me\n' >"$SANDBOX/new.env"
assert_eq "env_get_file reads value" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" B)" "two"
assert_eq "env_get_file value with =" "$(run_sourced "$SANDBOX" env_get_file "$SANDBOX/old.env" PROXY_AUTH_TOKEN)" "keep=me"
changed="$(run_sourced "$SANDBOX" env_changed_keys "$SANDBOX/old.env" "$SANDBOX/new.env" | sort | tr '\n' ' ')"
assert_eq "env_changed_keys finds B and C" "$changed" "B C "

echo "== unit: export_build_provenance (Issue #58) =="
# Exports the stack version (from the top-level VERSION file, whitespace-trimmed) plus git
# branch/commit for the dashboard build args — deliberately NOT written into .env, since the
# volatile commit would otherwise churn `apply`. The sandbox isn't a git repo, so branch/commit
# come back empty here; the release/dev split is unit-tested in dashboard/tests/test_version.py.
PROV="$SANDBOX/prov"
mkdir -p "$PROV"
printf '  9.9.9 \n' >"$PROV/VERSION"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$PROV" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance reads VERSION (trimmed)" "$ver" "9.9.9"
NOVER="$SANDBOX/nover"
mkdir -p "$NOVER"
# shellcheck disable=SC1090  # STACK path is dynamic by design
ver="$(cd "$NOVER" && source "$STACK" && set +e && export_build_provenance && printf '%s' "$PITHEAD_VERSION")"
assert_eq "export_build_provenance empty when no VERSION" "$ver" ""

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-cli.sh
source "$HERE/test-cli.sh"

# shellcheck source=tests/stack/test-config.sh
source "$HERE/test-config.sh"

echo "== unit: render-quadlet parity vs os/quadlet fixtures (#77 phase 1) =="
# The renderer must reproduce the spike-proven unit set byte-for-byte from the fixture env — the
# os/quadlet files ran live in the #78 spike, so any drift here needs a bench re-proof, not just
# an updated fixture.
QOUT="$SANDBOX/quadlet-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/fixture.env" "$QOUT" >/dev/null
for f in mining.network proxy.network tor.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet parity: $f" "$(diff -u "$ROOT/os/quadlet/$f" "$QOUT/$f" 2>&1 | head -c 300)" ""
done
assert_eq "remote render emits no node units" "$(find "$QOUT" -name 'monerod.container' -o -name 'tari.container' | wc -l | tr -d ' ')" "0"
# The local-node variant (bench-proven 2026-07-24): profiles on, 11 files, node units included.
QLOCAL="$SANDBOX/quadlet-local-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/local/fixture.env" "$QLOCAL" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    p2pool.container xmrig-proxy.container caddy.container docker-proxy.container \
    docker-control.container dashboard.container; do
    assert_eq "quadlet local parity: $f" "$(diff -u "$ROOT/os/quadlet/local/$f" "$QLOCAL/$f" 2>&1 | head -c 300)" ""
done
# The payout-confirm variant (bench-proven 2026-07-24): both wallet profiles, 13 files, the
# dashboard gains the payout env keys only in this set (the others stay byte-identical).
QPAY="$SANDBOX/quadlet-payout-out"
run_sourced "$SANDBOX" render_quadlet_units "$ROOT/os/quadlet/payout/fixture.env" "$QPAY" >/dev/null
for f in mining.network proxy.network tor.container monerod.container tari.container \
    wallet-rpc.container tari-wallet.container p2pool.container xmrig-proxy.container \
    caddy.container docker-proxy.container docker-control.container dashboard.container; do
    assert_eq "quadlet payout parity: $f" "$(diff -u "$ROOT/os/quadlet/payout/$f" "$QPAY/$f" 2>&1 | head -c 300)" ""
done
assert_eq "local render emits no wallet units" "$(find "$QLOCAL" -name 'wallet-rpc.container' -o -name 'tari-wallet.container' | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-doctor-appliance.sh
source "$HERE/test-doctor-appliance.sh"

echo "== unit: firstboot wizard token + spool consume (#77 phase 3) =="
# Token: pit- prefix + 6 chars from the unambiguous alphabet (never 0, O, 1, I, or l).
tok=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "token shape" "$(printf '%s' "$tok" | grep -cE '^pit-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$')" "1"
tok2=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "tokens vary" "$([ "$tok" = "$tok2" ] && echo same || echo differ)" "differ"
# Consume: a valid submission installs config.json + marks applied; an invalid one surfaces the
# error into the spool for the form and installs nothing; an empty spool is rc 2.
WSPOOL="$V/data/firstboot-test"
mkdir -p "$WSPOOL"
rm -f "$V/config.json"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"} }\n' "$WALLET" >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" && echo rc0)
assert_contains "valid submission accepted" "$out" "rc0"
assert_eq "valid submission installs config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
assert_eq "applied marker set" "$([ -f "$WSPOOL/applied" ] && echo yes)" "yes"
rm -f "$WSPOOL/applied"
printf '{ "monero": {"wallet_address":"8-not-a-primary"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"} }\n' >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "invalid submission rejected" "$out" "rc1"
assert_eq "rejection surfaces spool error" "$([ -s "$WSPOOL/error.txt" ] && echo yes)" "yes"
assert_eq "rejection leaves no candidate" "$([ -f "$WSPOOL/config.json" ] || echo gone)" "gone"
out=$(run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$WSPOOL"
# Restore the sandbox config for later sections.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
# A missing env file is a hard error, not an empty render.
out=$(run_sourced "$SANDBOX" render_quadlet_units "$SANDBOX/no-such.env" "$SANDBOX/quadlet-none" 2>&1)
assert_contains "render-quadlet missing env errors" "$out" "env file not found"

echo "== unit: firstboot_consume_restore — restore-at-setup (#909, #786 sub-issue B) =="
# A genuine encrypted backup (the same `pithead backup` #908 rides), fed through the wizard's
# restore-consume exactly as the host loop would: decrypt, verify BEFORE anything is touched,
# validate the embedded config through a copy, and land it as a normal accepted config.json —
# the SAME contract firstboot_consume_spool gives a typed submission. Physical path (#695): see
# the backup/restore black-box block above for why `pwd -P` matters here too.
RS="$(cd "$SANDBOX" && pwd -P)/restore-consume"
mkdir -p "$RS/build/tari" "$RS/data/tor" "$RS/data/dashboard" "$RS/bin"
cp "$STACK" "$RS/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"
cat >"$RS/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;; # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$RS/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$RS/bin/docker" "$RS/bin/sudo"
cat >"$RS/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RSTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$RS/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore fixture: backup exits 0" "$rc" "0"
rarchive="$(ls "$RS"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rarchive" ] && [ -f "$rarchive" ]; } && ok "restore fixture: encrypted archive created" || bad "restore fixture: encrypted archive created" "no .enc archive"

RSPOOL="$RS/data/firstboot-test"
mkdir -p "$RSPOOL"
rm -f "$RS/config.json"

# 1) Accept: the right passphrase decrypts, verifies, validates and lands config.json — settings,
# the Tor identity and the dashboard database all come back, and neither the archive nor the
# passphrase survive the attempt.
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" && echo rc0)
assert_contains "valid restore accepted" "$out" "rc0"
assert_eq "valid restore installs config.json" "$([ -f "$RS/config.json" ] && echo yes)" "yes"
assert_contains "valid restore carries the original wallet" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_eq "valid restore brings back the Caddyfile" "$(cat "$RS/Caddyfile" 2>/dev/null)" "CADDY-ORIG"
assert_eq "valid restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-ORIG"
assert_eq "applied marker set" "$([ -f "$RSPOOL/applied" ] && echo yes)" "yes"
assert_eq "the archive is consumed" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
rm -f "$RSPOOL/applied" "$RS/config.json" # clean slate for the rejection cases below

# 1b) Installer door (installer=1): the config surfaces for the credentials card, but the
# machine itself is NOT restored — decrypted keys must never rest on the stick — and the
# accepted archive + passphrase park in the carry dir for the ESP staging the install branch
# performs (the target's first boot does the real restore).
printf 'STICK-CADDY\n' >"$RS/Caddyfile"
printf 'STICK-DB\n' >"$RS/data/dashboard/dashboard.db"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
RCARRY="$RS/carry"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" 1 && echo rc0)
assert_contains "installer restore accepted" "$out" "rc0"
assert_contains "installer restore surfaces the config for the card" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_eq "installer restore does NOT restore onto the stick (Caddyfile untouched)" "$(cat "$RS/Caddyfile")" "STICK-CADDY"
assert_eq "installer restore does NOT restore onto the stick (db untouched)" "$(cat "$RS/data/dashboard/dashboard.db")" "STICK-DB"
assert_eq "accepted archive parked for the ESP carry" "$([ -f "$RCARRY/archive" ] && echo yes)" "yes"
assert_eq "passphrase parked beside it" "$(cat "$RCARRY/pass" 2>/dev/null)" "hunter2"
assert_eq "installer restore consumes the spool archive" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
rm -rf "$RCARRY"
rm -f "$RSPOOL/applied" "$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" # fixtures back to their case-1 state for the cases below
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"

# 2) Bad passphrase: rejected before anything is touched.
printf 'CORRUPTED\n' >"$RS/Caddyfile"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'not-the-passphrase' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "wrong passphrase rejected" "$out" "rc1"
assert_contains "wrong passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "assphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$RS/Caddyfile")" "CORRUPTED"
assert_eq "the archive is consumed even on rejection" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained even on rejection" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RSPOOL/error.txt"

# 3) Encrypted archive, no passphrase supplied at all.
cp "$rarchive" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "missing passphrase rejected" "$out" "rc1"
assert_contains "missing passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "passphrase"
rm -f "$RSPOOL/error.txt"

# 4) Oversize: refused on SIZE alone, before any decrypt/extract — content is irrelevant.
truncate -s 67108865 "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "oversize archive rejected" "$out" "rc1"
assert_contains "oversize archive names the cap" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "too large"
rm -f "$RSPOOL/error.txt"

# 5) Malformed: neither the encrypted magic nor gzip's — falls back exactly like a rejected
# config, never blocking setup.
printf 'garbage-not-an-archive' >"$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "malformed archive rejected" "$out" "rc1"
assert_contains "malformed archive names the problem" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "not a Pithead backup archive"
assert_eq "malformed archive leaves config.json untouched" "$([ -f "$RS/config.json" ] || echo gone)" "gone"
rm -f "$RSPOOL/error.txt"

# 6) Path-traversal / symlink defense: a well-formed gzip archive (passes the magic + integrity
# checks) whose members escape the restore set must be refused BEFORE anything is staged to "/".
# A Pithead backup is only regular files under known prefixes, so a symlink or a ".." member is an
# attack. Built with real tar so the guard faces the exact bytes it would on a box.
MAL="$RS/mal"
mkdir -p "$MAL/pithead"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"     # live file the escape would try to clobber via symlink
ln -s /etc/shadow "$MAL/pithead/Caddyfile" # symlink escape
(cd "$MAL" && tar -czf "$RSPOOL/restore-archive" pithead) 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "a symlink member is refused" "$out" "rc1"
assert_contains "the symlink refusal names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "unsafe paths or links"
assert_eq "a symlink archive touches nothing" "$(cat "$RS/Caddyfile")" "CADDY-ORIG"
rm -f "$RSPOOL/error.txt" "$RSPOOL/restore-passphrase"
# Absolute-path member (stored with a leading slash via -P): would land at /… on cp -a.
printf 'EVIL\n' >"$MAL/evil"
(cd "$MAL" && tar -Pczf "$RSPOOL/restore-archive" "$MAL/evil") 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "an absolute-path member is refused" "$out" "rc1"
rm -f "$RSPOOL/error.txt"

# 7) Nothing to consume.
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$RS"

echo "== black-box: uninstall keeps the operator's files (#77 phase 1) =="
# Self-provision a fully-rendered .env rather than relying on an earlier section's ambient one:
# this used to inherit it for free from the dashboard-auth-lifecycle black-box, which ran
# immediately before this section in the original file; that test now lives in
# test-dashboard.sh (#1105 Phase 1), sourced far earlier, so a LATER config-validation case
# (a rejected apply, whose own seed_env leaves .env at the bare pre-render baseline — no
# *_DATA_DIR keys) was the last thing to touch .env by the time this section ran. stack_uninstall
# greps .env for those keys with `pipefail` under `set -e`; zero matches makes that grep — not
# uninstall's own logic — abort the whole script. Render a real, complete .env here so this
# section proves uninstall's OWN behaviour instead of depending on a same-file predecessor.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "uninstall fixture: self-provisioned apply succeeds" "$rc" "0"
# Without confirmation: aborts, changes nothing.
touch "$V/Caddyfile"
out=$(cd "$V" && printf 'no\n' | PATH="$V/bin:$PATH" ./pithead uninstall 2>&1) || true
assert_contains "uninstall aborts without the confirm word" "$out" "Aborted"
assert_eq "aborted uninstall keeps .env" "$([ -f "$V/.env" ] && echo yes)" "yes"
# With -y: rendered files go, the operator's files stay.
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1)
assert_contains "uninstall names the kept files" "$out" "config.json"
assert_eq "uninstall removes .env" "$([ -f "$V/.env" ] || echo gone)" "gone"
assert_eq "uninstall removes Caddyfile" "$([ -f "$V/Caddyfile" ] || echo gone)" "gone"
assert_eq "uninstall keeps config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall --bogus 2>&1) || true
assert_contains "uninstall rejects unknown options" "$out" "Unknown option"
# Re-render the sandbox .env for the sections below — uninstall just deleted it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-backup.sh
source "$HERE/test-backup.sh"

echo "== unit: install.sh host gate (#77 phase 1) =="
# The installer hard-fails on the platforms the stack cannot run on, before any download.
IBIN="$SANDBOX/install-stub-bin"
mkdir -p "$IBIN"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo aarch64 ;; esac\n' >"$IBIN/uname"
chmod +x "$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-amd64" "$out" "x86_64-only"
printf '#!/bin/bash\ncase "$1" in -s) echo Darwin ;; -m) echo x86_64 ;; esac\n' >"$IBIN/uname"
out=$(PATH="$IBIN:$PATH" bash "$ROOT/install.sh" 2>&1) || true
assert_contains "install.sh refuses non-Linux" "$out" "runs on Linux"

echo "== unit: install.sh download verification fails CLOSED (#868) =="
# The two security-critical branches of the public curl installer: the bundle sha256 against the
# release manifest, and the cosign signature against the repo-pinned key. This is the path a new
# operator runs BEFORE any of the bundle's own defenses exist — a tampered bundle that gets
# extracted has already won — so a mismatch must install NOTHING. The stubs model each remote
# artifact as a file served by basename; absent file = curl -f failure, exactly the shape the
# script distinguishes (absent degrades politely, present-but-wrong is fatal).
ISB=$(mktemp -d)
mkdir -p "$ISB/bin" "$ISB/srv" "$ISB/work"
printf '#!/bin/bash\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; esac\n' >"$ISB/bin/uname"
cat >"$ISB/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
    -o)
        out="$2"
        shift 2
        ;;
    http*)
        url="$1"
        shift
        ;;
    *) shift ;;
    esac
done
src="$CURL_SRV/$(basename "$url")"
[ -f "$src" ] || exit 22
[ -n "$out" ] && cp "$src" "$out"
exit 0
EOF
# macOS has no sha256sum; shasum -a 256 prints the identical "hash  file" shape.
printf '#!/bin/bash\nif command -v /usr/bin/sha256sum >/dev/null; then exec /usr/bin/sha256sum "$@"; fi\nexec shasum -a 256 "$@"\n' >"$ISB/bin/sha256sum"
printf '#!/bin/bash\nexit "${COSIGN_RC:-0}"\n' >"$ISB/bin/cosign"
chmod +x "$ISB/bin/"*
# A canned release bundle whose pithead stub proves the handoff (install.sh exec's it).
mkdir -p "$ISB/bundle-src/pithead-x"
printf '#!/bin/bash\necho "SETUP-REACHED $*"\n' >"$ISB/bundle-src/pithead-x/pithead"
chmod +x "$ISB/bundle-src/pithead-x/pithead"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/bundle-src" pithead-x
# One invocation per scenario; PATH keeps the stubs first, cosign joins only where a test wants it.
irun() { # <dest-subdir> [env overrides via preceding assignments]
    (
        cd "$ISB/work" || exit
        CURL_SRV="$ISB/srv" PITHEAD_VERSION=v9.9.9 PITHEAD_ALLOW_ANY_DISTRO=1 \
            PITHEAD_DIR="$ISB/work/$1" PATH="$ISB/bin:$PATH" bash "$ROOT/install.sh" 2>&1
    )
}

# sha256 verified against the manifest: match proceeds to the handoff, mismatch installs NOTHING.
# The manifest line is written by release.sh's OWN producer, not a hand-copied format: this grep is
# the only integrity check a fresh install has before cosign exists on the box, and the two sides
# drifting apart would leave every appliance install silently trusting HTTPS alone (#77 phase 1,
# #1115). MUTATION PROOF: drop the backticks from append_bundle_sha256's format and "sha256 match is
# announced" goes red — install.sh finds no sha, degrades to HTTPS trust and installs anyway, which
# is the actual damage: a silent downgrade, not a visible failure.
: >"$ISB/srv/ingredients-v9.9.9.md" # it appends; write_manifest has run by then in a real cut
# shellcheck disable=SC1090
(set -- && PATH="$ISB/bin:$PATH" && source "$REL" 2>/dev/null && set +eu &&
    append_bundle_sha256 "$ISB/srv/ingredients-v9.9.9.md" "$ISB/srv/pithead.tar.gz")
out=$(irun ok-sha)
assert_rc "verified install runs to the setup handoff" "$?" "0"
assert_contains "sha256 match is announced" "$out" "sha256 verified"
assert_contains "the extracted pithead was exec'd" "$out" "SETUP-REACHED"
printf 'bundle sha256: `%s`\n' "$(printf 'a%.0s' $(seq 64))" >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun bad-sha) && rc=0 || rc=$?
assert_rc "sha256 mismatch refuses to install" "$rc" "1"
assert_contains "the mismatch names both digests' verdict" "$out" "sha256 mismatch"
assert_eq "nothing was installed on a sha256 mismatch" "$([ -e "$ISB/work/bad-sha" ] && echo present || echo absent)" "absent"
# A manifest with no sha line (pre-v1.15) and a missing manifest both degrade politely.
printf 'no digest here\n' >"$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-sha-line)
assert_contains "manifest without a sha degrades to HTTPS trust" "$out" "carries no bundle sha256"
rm -f "$ISB/srv/ingredients-v9.9.9.md"
out=$(irun no-manifest)
assert_contains "missing manifest degrades to HTTPS trust" "$out" "No release manifest"

# cosign: a present-but-bad signature is FATAL; an absent one is a note; a signature whose
# pinned key cannot be fetched is fatal too (the cross-channel check cannot be half-done).
touch "$ISB/srv/pithead.tar.gz.sig" "$ISB/srv/cosign.pub"
out=$(irun sig-ok)
assert_rc "good signature installs" "$?" "0"
assert_contains "signature verification is announced" "$out" "signature verified"
out=$(COSIGN_RC=1 irun sig-bad) && rc=0 || rc=$?
assert_rc "bad signature refuses to install" "$rc" "1"
assert_contains "the failure names the signature" "$out" "signature verification FAILED"
assert_eq "nothing was installed on a bad signature" "$([ -e "$ISB/work/sig-bad" ] && echo present || echo absent)" "absent"
rm -f "$ISB/srv/cosign.pub"
out=$(irun sig-nokey) && rc=0 || rc=$?
assert_rc "signature without a fetchable pinned key refuses" "$rc" "1"
assert_contains "the failure names the pinned key" "$out" "pinned key could not be fetched"
rm -f "$ISB/srv/pithead.tar.gz.sig"
out=$(irun sig-absent)
assert_contains "absent signature is noted, not fatal" "$out" "No bundle signature"

# The remaining guards on the same path: an occupied target refuses before downloading, and a
# bundle with no pithead executable refuses after extraction.
mkdir -p "$ISB/work/taken"
out=$(irun taken) && rc=0 || rc=$?
assert_rc "an existing target dir refuses" "$rc" "1"
assert_contains "the refusal names the dir" "$out" "already exists"
mkdir -p "$ISB/empty/pithead-x" && touch "$ISB/empty/pithead-x/README"
tar -czf "$ISB/srv/pithead.tar.gz" -C "$ISB/empty" pithead-x
out=$(irun corrupt) && rc=0 || rc=$?
assert_rc "a bundle without a pithead executable refuses" "$rc" "1"
assert_contains "the refusal suspects corruption" "$out" "no pithead executable"
rm -rf "$ISB"
unset -f irun

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-secrets.sh
source "$HERE/test-secrets.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-rig-worker.sh
source "$HERE/test-rig-worker.sh"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-monero-tari.sh
source "$HERE/test-monero-tari.sh"

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
# shellcheck source=tests/stack/test-tor-network.sh
source "$HERE/test-tor-network.sh"

# ---------------------------------------------------------------------------
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

echo "== black-box: pre-masked prefill copy + host-side secret merge (#440) =="
# The dashboard container never mounts the raw config.json: apply/run-pending render a PRE-MASKED
# copy into the spool's masked/ leg, and the "blank secret keeps the live value" sentinel swap
# happens host-side at staging. Current state: pool mini committed above, node_password "p",
# dashboard password "a control passphrase".
MASKED="$C/data/control/masked/config.json"
[ -f "$MASKED" ] && ok "masked prefill copy rendered by apply" || bad "masked prefill copy rendered by apply" "$MASKED missing"
assert_eq "masked copy is world-readable for the container (644)" "$(file_mode "$MASKED")" "644"
assert_eq "set secret masked to the sentinel" "$(jq -c '.monero.node_password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "dashboard password masked to the sentinel" "$(jq -c '.dashboard.auth.password' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "non-secret keys survive the masking" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "mini"
case "$(cat "$MASKED")" in
*"a control passphrase"* | *'"p"'*) bad "masked copy holds no secret values" "a secret leaked into $MASKED" ;;
*) ok "masked copy holds no secret values" ;;
esac

# Staleness: a hand-edit to config.json (new BOTSECRET token) is re-masked by the next runner
# pass — run-pending freshens the copy even with an empty request spool.
jq '.telegram = {"bot_token":"BOTSECRET","chat_id":"-100123"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_pending >/dev/null
assert_eq "run-pending re-renders the masked copy" "$(jq -c '.telegram.bot_token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
case "$(cat "$MASKED")" in
*BOTSECRET*) bad "hand-edited secret never reaches the masked copy" "BOTSECRET leaked into $MASKED" ;;
*) ok "hand-edited secret never reaches the masked copy" ;;
esac

# Sync .env with the hand-edited config so the sentinel commit below only changes allowlisted
# P2POOL keys (TELEGRAM_BOT_TOKEN is deliberately NOT dashboard-committable).
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

# Host-side sentinel swap: a proposal carrying {"__secret__":true} for untouched secrets (what the
# dashboard now submits) stages with the LIVE values merged back in, and a sentinel for an UNSET
# secret collapses to "" instead of leaking a dict into config.json.
UUID5="55555555-5555-4555-8555-555555555555"
jq -n --arg w "$WALLET" --arg id "$UUID5" '{id:$id, action:"preview", actor:"admin", config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:{"__secret__":true}},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, workers:{api_token:{"__secret__":true}},
    telegram:{bot_token:{"__secret__":true},chat_id:"-100123"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:{"__secret__":true}},control:{enabled:true}}}}' >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel-carrying preview validates" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "previewed"
assert_eq "sentinel swapped for the live node password at staging" "$(jq -r '.monero.node_password' "$STAGED/$UUID5.json" 2>/dev/null)" "p"
assert_eq "sentinel swapped for the live dashboard password" "$(jq -r '.dashboard.auth.password' "$STAGED/$UUID5.json" 2>/dev/null)" "a control passphrase"
assert_eq "sentinel swapped for the live telegram token" "$(jq -r '.telegram.bot_token' "$STAGED/$UUID5.json" 2>/dev/null)" "BOTSECRET"
assert_eq "sentinel for an unset secret collapses to empty" "$(jq -r '.workers.api_token' "$STAGED/$UUID5.json" 2>/dev/null)" ""
# The container-visible legs of this round trip stay secret-free (the request carried sentinels,
# the merged copy lives only in host-only staged/).
case "$(cat "$RESULTS/$UUID5.json")$(cat "$AUDIT")" in
*BOTSECRET* | *"a control passphrase"*) bad "results/audit stay secret-free on a sentinel preview" "a live secret leaked" ;;
*) ok "results/audit stay secret-free on a sentinel preview" ;;
esac

# Commit the sentinel intent: the committed config.json carries the LIVE secrets ("blank keeps"),
# and the masked prefill copy is re-rendered to match the new state.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live node password" "$(jq -r '.monero.node_password' "$C/config.json")" "p"
assert_eq "committed config keeps the live telegram token" "$(jq -r '.telegram.bot_token' "$C/config.json")" "BOTSECRET"
assert_eq "committed config never carries a sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
assert_eq "masked copy re-rendered after the commit" "$(jq -r '.p2pool.pool' "$MASKED" 2>/dev/null)" "main"
case "$(cat "$MASKED")" in
*BOTSECRET* | *"a control passphrase"*) bad "re-rendered masked copy still holds no secrets" "a secret leaked into $MASKED" ;;
*) ok "re-rendered masked copy still holds no secrets" ;;
esac

echo "== black-box: .env line-injection guard (#33 hardening, per field) =="
# A newline in any config string that renders into .env unquoted would inject a SECOND KEY=value
# line — e.g. PITHEAD_REGISTRY=evil.tld — which the root apply then trusts for every image: pull
# (RCE). parse_and_validate_config (the chokepoint both preview dry-run and real commit run) must
# reject a control character in EVERY string leaf. Build a full valid config, then poison one field.
inject_reject() { # <label> <jq-setter expr using $v>
    jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}
         | '"$2" >"$C/config.json"
    out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
    rc=$?
    assert_rc "$1 with a newline is rejected by parse_and_validate_config" "$rc" "1"
    assert_contains "$1 rejection names the control-char guard" "$out" "control character"
}
inject_reject "node_password" '.monero.node_password=$v'
inject_reject "node_username" '.monero.node_username=$v'
inject_reject "bot_token" '(.telegram={bot_token:$v})'
inject_reject "api_token" '(.workers={api_token:$v})'
inject_reject "ping_url" '(.healthchecks={ping_url:$v})'
inject_reject "chat_id" '(.telegram={chat_id:$v})'
# Positive: legitimate tokens (no control chars) still validate.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
      telegram:{bot_token:"123456:legit-ABC_def"}, workers:{api_token:"tok_legit123"},
      healthchecks:{ping_url:"https://hc-ping.com/abc-123"},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "legitimate secrets still validate" "$?" "0"
# No second line reaches .env: a poisoned config rejected at `apply -y` never renders the attacker key.
jq -n --arg w "$WALLET" --arg v $'legit\nPITHEAD_REGISTRY=evil.tld/attacker' \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
      tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"}, telegram:{bot_token:$v},
      dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
if grep -q 'PITHEAD_REGISTRY' "$C/.env"; then bad "no injected line in .env" "PITHEAD_REGISTRY landed in .env"; else ok "rejected config injects no second .env line"; fi

echo "== black-box: control channel on a published onion requires client-auth (#33 hardening) =="
# A root-capable, funds-redirecting mutation channel must not sit behind only a brute-forceable
# password on an anonymously-reachable onion. control+onion+client_auth=false → refused.
onion_control_config() { # <onion-enabled> <client-auth> -> writes config.json
    jq -n --arg w "$WALLET" --argjson onion "$1" --argjson ca "$2" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a strong control passphrase"},
                     onion:{enabled:$onion,client_auth:$ca}, control:{enabled:true}}}' >"$C/config.json"
}
onion_control_config true false
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion without client_auth is refused" "$?" "1"
assert_contains "refusal names client_auth" "$out" "client_auth"
onion_control_config true true
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control+onion WITH client_auth validates" "$?" "0"
assert_not_contains "allowed combo raises no client_auth error" "$out" "client_auth"
# control without an onion (LAN) stays allowed — client-auth only gates the published onion.
control_config main
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "control without an onion is allowed" "$?" "0"

echo "== black-box: telegram.control fails closed on each leg (#521) =="
# telegram.control (the #338 remote /restart /apply surface) is a remotely-reachable host-control
# channel, so it refuses to enable unless the whole chain is present: dashboard.control on (the #33
# spool it rides), telegram.commands on (the bot that answers it), and at least one allow-listed
# operator id (or every command is refused and the feature is inert). Each leg must fail closed.
tg_control_config() { # <dashboard.control.enabled> <telegram.commands.enabled> <allowed_ids-json>
    jq -n --arg w "$WALLET" --argjson ctl "$1" --argjson cmds "$2" --argjson ids "$3" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
          tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"main"},
          telegram:{enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111",
                    commands:{enabled:$cmds}, control:{enabled:true,allowed_ids:$ids}},
          dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
                     control:{enabled:$ctl}}}' >"$C/config.json"
}
# Leg 1: dashboard.control off — the spool the commands ride does not exist.
tg_control_config false true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without dashboard.control is refused" "$?" "1"
assert_contains "refusal names dashboard.control.enabled" "$out" "dashboard.control.enabled is false"
# Leg 2: telegram.commands off — no bot is polling for the commands.
tg_control_config true false '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control without telegram.commands is refused" "$?" "1"
assert_contains "refusal names telegram.commands.enabled" "$out" "telegram.commands.enabled is false"
# Leg 3: allowed_ids empty — no operator could ever confirm, the feature is inert.
tg_control_config true true '[]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "telegram.control with an empty allowed_ids is refused" "$?" "1"
assert_contains "refusal names allowed_ids" "$out" "telegram.control.allowed_ids is empty"
# All three legs present — validates.
tg_control_config true true '[123456]'
out="$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run --porcelain 2>&1)"
assert_rc "fully-configured telegram.control validates" "$?" "0"
assert_not_contains "fully-configured control raises no telegram.control error" "$out" "telegram.control.enabled is true but"
# Restore the section baseline (control on, no telegram) for the tests that follow.
control_config main
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

echo "== black-box: confirm-gate — an in-scope disruptive change needs a typed APPLY (#719) =="
UUID3="33333333-3333-4333-8333-333333333333"
# Clean baseline: pool mini, clearnet off, applied.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# Candidate turns on Monero clearnet initial sync — describe_change flags this CONFIRM (#719): an
# in-scope disruptive change (host IP exposed during IBD), confirm-gated rather than host-only DEST.
preview_clearnet() {
    jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",clearnet_initial_sync:true},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
    run_pending >/dev/null
}
preview_clearnet
assert_eq "confirm-gated candidate previews destructive:true" "$(jq -r '.destructive' "$RESULTS/$UUID3.json" 2>/dev/null)" "true"
assert_contains "confirm-gated preview carries a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID3.json" 2>/dev/null)" "CONFIRM"
# Commit WITHOUT the typed confirmation is refused — and points at the confirm step, NOT a flat
# host-only #338 refusal. The in-scope change is NOT hard-refused; it just needs the acknowledgement.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit without a token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "refusal asks for the typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "type APPLY"
assert_eq "unconfirmed commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# A WRONG token is refused too — only the exact literal proceeds.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"apply"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with the wrong token is refused" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_eq "wrong-token commit did not touch config.json" "$(jq -r '.monero.clearnet_initial_sync // false' "$C/config.json")" "false"
# Commit WITH the exact typed APPLY proceeds and lands the change.
preview_clearnet
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "confirm-gated commit with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "confirmed change landed in config.json" "$(jq -r '.monero.clearnet_initial_sync' "$C/config.json")" "true"
# The audit log records it AS a dashboard-confirmed destructive change (#719): the distinct
# commit-confirmed action, carrying the changed key NAME (never a value).
assert_contains "confirmed commit audits as commit-confirmed with the key name" \
    "$(grep '"action":"commit-confirmed","status":"applied"' "$AUDIT" | tail -n 1)" "MONERO_CLEARNET_SYNC"

echo "== black-box: the typed APPLY does NOT unlock the perimeter — DEST stays host-only (#719) =="
# Type-to-confirm is UX friction, not a security control: it must never carry a PERIMETER change.
# (a) A perimeter key that never touches an allowlist (monero.rpc_lan_access -> MONERO_RPC_BIND,
# DEST) is refused even WITH the token, on the security-sensitive gate.
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",rpc_lan_access:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "perimeter RPC-LAN change is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
assert_contains "perimeter refusal is the security-sensitive gate, not the confirm step" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "security-sensitive"
assert_eq "perimeter change did not touch config.json" "$(jq -r '.monero.rpc_lan_access // false' "$C/config.json")" "false"
# (b) A confirm-KEY in its HEAVY direction (monero.prune DISABLE → full re-sync) still emits DEST
# and is refused even WITH the token — the confirm allowlist is not a blanket unlock for the key.
jq -n --arg w "$WALLET" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:true},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "prune DISABLE is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "rejected"
# #713 removed the stale #338 reference from the destructive refusal; it now names the host path.
assert_contains "prune-disable refusal names the host apply path, not stale #338 (#713)" "$(jq -r '.error' "$RESULTS/$UUID3.json" 2>/dev/null)" "Edit config.json on the host"
assert_eq "prune stays enabled after the refusal" "$(jq -r '.monero.prune' "$C/config.json")" "true"
[ ! -f "$STAGED/$UUID3.json" ] && ok "refused destructive intent cleared from staged" || bad "refused destructive intent cleared from staged" "still staged"

echo "== black-box: a dashboard-confirmed data-dir move is allowlisted to the stack data root (#728) =="
# #719 made the four *_DATA_DIR moves confirm-gated. assert_safe_dir is a BLOCKLIST, so a
# confirmed move could target any non-blocklisted absolute path (another user's home, another
# service's volume). control_approval_gate now narrows the DESTINATION to an allowlist for
# control-channel moves: only under the stack data root ($C/data) or a parent it already uses.
# The host `apply` path keeps the blocklist — a shell operator is already trusted.
UUID7="77777777-7777-4777-8777-777777777777"
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
EVIL_DIR="$SANDBOX/other-service-vol/monero" # absolute, NOT blocklisted, NOT under $C/data
preview_move() {                             # <monero.data_dir>
    jq -n --arg w "$WALLET" --arg id "$UUID7" --arg dd "$1" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID7.json"
    run_pending >/dev/null
}
# (1) A move UNDER the stack data root, confirmed with APPLY, is allowed and lands.
preview_move "$C/data/monero-v2"
assert_contains "in-root data-dir move previews a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID7.json" 2>/dev/null)" "CONFIRM"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "in-root data-dir move with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "applied"
assert_eq "in-root move landed in .env" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$C/data/monero-v2"
# (2) A move to an arbitrary non-blocklisted, non-allowed path is refused EVEN with APPLY.
preview_move "$EVIL_DIR"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "out-of-root data-dir move is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
assert_contains "refusal names the data-root allowlist" "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "outside the stack data root"
# The refusal left config.json untouched — it still carries the previously-committed in-root value
# (test 1), never the refused out-of-root path.
assert_eq "refused move did not touch config.json" "$(jq -r '.monero.data_dir // empty' "$C/config.json")" "$C/data/monero-v2"
[ ! -f "$STAGED/$UUID7.json" ] && ok "refused out-of-root move cleared from staged" || bad "refused out-of-root move cleared from staged" "still staged"
# (3) The SAME path from the HOST shell still applies — the tighter rule is control-only.
jq -n --arg w "$WALLET" --arg dd "$EVIL_DIR" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_rc "host-shell apply to the same out-of-root path succeeds" "$?" "0"
assert_eq "host-shell apply rendered the out-of-root path (blocklist, not allowlist)" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$EVIL_DIR"

echo "== black-box: a NON-destructive commit still proceeds with no token (#33) =="
# Restore a clean baseline (prune off, clearnet off) then a pool switch mini -> nano is INFO, not
# DEST/CONFIRM — it commits with no confirmation at all.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "non-destructive commit still applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "non-destructive change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "nano"

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
# dashboard.workers (#172) never renders to .env, so the env-diff allowlist can't see it — yet it
# carries per-rig hosts and API tokens (a committed attacker host would point token-bearing probes
# at it). The gate must refuse it via its explicit config-level check.
jq '.dashboard.workers=[{name:"rig1",host:"attacker.example",token:"stolen"}]' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "dashboard.workers change commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "workers refusal names dashboard.workers" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "dashboard.workers"
assert_eq "config.json keeps no worker descriptors" "$(jq -r '.dashboard.workers // "unset"' "$C/config.json")" "unset"
# workers.list[]'s add-only exception (#893's click-to-adopt) + the #122 SSRF floor on a newly
# appended entry's host — split into its own file purely for the file-budget ratchet; it shares
# this section's $C/$UUID5/gate_try exactly like test-control-deploy.sh shares its own section's.
# shellcheck source=tests/stack/test-control-add-only-ssrf.sh
source "$HERE/test-control-add-only-ssrf.sh"

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

# NO FALSE-REJECT on legacy configs: config.reference.json must be a COMPLETE superset of every path
# pithead READS, or the closed-schema guard refuses a legit config on EVERY commit. A config.json
# predating the xvb rename still carries a legacy xmrig_proxy.* block (read as an alias at pithead
# ~L3245). Seed it into the live baseline, then prove a normal on-allowlist commit
# (xvb.donation_level -> XVB_DONATION_LEVEL) still passes the gate and the legacy block round-trips.
jq '.xmrig_proxy={enabled:true,url:"na.xmrvsbeast.com:4247",donor_id:"auto"}' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.xvb.donation_level="whale"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "a commit on a config carrying a legacy xmrig_proxy block still applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the allowlisted xvb tier landed in config.json" "$(jq -r '.xvb.donation_level' "$C/config.json")" "whale"
assert_eq "the legacy xmrig_proxy block round-trips untouched" "$(jq -r '.xmrig_proxy.url' "$C/config.json")" "na.xmrvsbeast.com:4247"

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

echo "== black-box: editable-allowlist commit round-trip, every key (#522) =="
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json — not just pass a describe_change unit check.
# Fresh baseline with each tunable at a known value so every row below is a genuine single-key
# env diff (pool flips P2POOL_FLAGS + P2POOL_PORT, both allowlisted).
jq -n --arg w "$WALLET" '{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",mem_limit:"4g",prep_blocks_threads:4},
    tari:{wallet_address:"'"$VALID_TARI"'",mem_limit:"3g"}, p2pool:{pool:"main"},
    xvb:{enabled:true,donation_level:"donor"}, telegram:{daily_summary_time:"08:00"},
    dashboard:{secure:true,host:"box.lan",tari_required:true,check_for_updates:true,timezone:"UTC",
               hashrate_drop_threshold:50,hashrate_drop_minutes:10,
               auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
roundtrip_key() { # <label> <jq-set> <jq-read> <expected>
    jq "$2" "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "$1 commit applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
    assert_eq "$1 landed in config.json" "$(jq -r "$3" "$C/config.json")" "$4"
}
roundtrip_key "XVB_ENABLED" '.xvb.enabled=false' '.xvb.enabled' "false"
roundtrip_key "XVB_DONATION_LEVEL" '.xvb.donation_level="whale"' '.xvb.donation_level' "whale"
roundtrip_key "TARI_REQUIRED" '.dashboard.tari_required=false' '.dashboard.tari_required' "false"
roundtrip_key "DASHBOARD_FAIL_CLOSED" '.dashboard.fail_closed=true' '.dashboard.fail_closed' "true"
roundtrip_key "DASHBOARD_CHECK_UPDATES" '.dashboard.check_for_updates=false' '.dashboard.check_for_updates' "false"
roundtrip_key "DASHBOARD_TZ" '.dashboard.timezone="Europe/Paris"' '.dashboard.timezone' "Europe/Paris"
roundtrip_key "MONERO_MEM_LIMIT" '.monero.mem_limit="5g"' '.monero.mem_limit' "5g"
roundtrip_key "TARI_MEM_LIMIT" '.tari.mem_limit="2g"' '.tari.mem_limit' "2g"
roundtrip_key "MONERO_PREP_THREADS" '.monero.prep_blocks_threads=8' '.monero.prep_blocks_threads' "8"
roundtrip_key "HASHRATE_DROP_THRESHOLD_PCT" '.dashboard.hashrate_drop_threshold=40' '.dashboard.hashrate_drop_threshold' "40"
roundtrip_key "HASHRATE_DROP_MINUTES" '.dashboard.hashrate_drop_minutes=15' '.dashboard.hashrate_drop_minutes' "15"
roundtrip_key "TELEGRAM_DAILY_SUMMARY_TIME" '.telegram.daily_summary_time="09:30"' '.telegram.daily_summary_time' "09:30"
roundtrip_key "P2POOL_FLAGS/P2POOL_PORT" '.p2pool.pool="mini"' '.p2pool.pool' "mini"
# The 25 allowlisted TELEGRAM_EVENT_* toggles (raffle_win added 2026-08: audit found it was the one
# event toggle missing from its siblings, all otherwise editable). wallet_changed + clearnet_exposed
# are deliberately NOT on the allowlist (tamper-evidence alarms; their refusal is asserted above),
# so they are excluded here. Each flips true->false as a single-key diff.
for ev in node_down node_recovered worker_offline worker_recovered worker_joined worker_left \
    sync_finished disk_space db_unhealthy db_reset xvb_no_share xvb_registration new_release \
    stack_online daily_summary hashrate_low hashrate_loss hugepages low_ram high_reject_rate \
    block_found payout_found payout_confirmed container_unhealthy raffle_win; do
    roundtrip_key "TELEGRAM_EVENT ${ev}" ".telegram.events.${ev}=false" ".telegram.events.${ev}" "false"
done

echo "== black-box: per-worker token mask + host-side restore, legacy dashboard.workers (#172/#679) =="
# dashboard.workers[].token is a per-rig credential living in a VARIABLE-LENGTH array — out of the
# fixed CONTROL_SECRET_PATHS walk. The masked prefill copy must sentinel each set token (extends
# the #440 property per-rig), and the staging swap must restore each sentinel from the LIVE token
# matched by worker NAME. Per-worker descriptors are never dashboard-EDITABLE (the commit gate
# refuses any dashboard.workers change, asserted above) — so this restore is exactly what lets an
# operator's OTHER edits round-trip: the workers come back as sentinels and must resolve to the
# live values unchanged, or every dashboard commit on a stack with configured workers would fail.
# Since #679 `apply` MIGRATES the legacy shape, so a live config carries dashboard.workers only
# between a hand-edit and the next apply — exactly the state the preview leg (a dry run, never
# migrates) still serves. Hand-edit to legacy and render the masked copy directly, no apply.
jq '.dashboard.workers=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}] | del(.workers.list)' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears,
#    and a token-less worker stays token-less.
assert_eq "per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second per-worker token masked to the sentinel" "$(jq -c '.dashboard.workers[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less worker stays token-less in the masked copy" "$(jq -r '.dashboard.workers[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no per-worker token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no per-worker token" ;;
esac
# 2) staging swap: a proposal that prefills the workers from the masked copy (sentinel tokens) and
#    changes only an allowlisted key stages with each token restored from live BY NAME.
UUID6="66666666-6666-4666-8666-666666666666"
jq --arg id "$UUID6" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="main")}' "$MASKED" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "previewed"
assert_eq "per-worker sentinel restored to the live token by name" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second per-worker sentinel restored by name" "$(jq -r '.dashboard.workers[2].token' "$STAGED/$UUID6.json" 2>/dev/null)" "tok_rig3secret"
assert_eq "token-less worker stays token-less at staging" "$(jq -r '.dashboard.workers[1] | has("token")' "$STAGED/$UUID6.json" 2>/dev/null)" "false"
case "$(cat "$RESULTS/$UUID6.json")$(cat "$AUDIT")" in
*tok_rig1secret* | *tok_rig3secret*) bad "results/audit stay free of the restored per-worker token" "a per-worker token leaked" ;;
*) ok "results/audit stay free of the restored per-worker token" ;;
esac
# 3) commit: workers restored to live == live, so the gate passes on the pool-only change; the
#    commit's `apply -y` then MIGRATES (#679) — the committed config keeps the live per-worker
#    tokens under workers.list[], the legacy key is gone, and the pre-migration copy sits beside.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID6" >"$REQS/$UUID6.json"
run_pending >/dev/null
assert_eq "worker-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID6.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live per-worker token (migrated to workers.list, #679)" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "commit migrated the legacy key away (#679)" "$(jq -r '.dashboard | has("workers")' "$C/config.json")" "false"
assert_eq "pre-migration copy kept through the control commit (#679)" "$(jq -r '.dashboard.workers[0].token' "$C/config.json.bak-workers" 2>/dev/null)" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"
# 4) duplicate names resolve first-declared-wins (staging only — a duplicate can't round-trip a
#    commit, since the second entry's token would flip and trip the gate). Same hand-edited
#    legacy state as above: masked copy rendered directly, no apply, so no migration yet.
jq 'del(.workers.list) | .dashboard.workers=[{name:"rig1",host:"10.0.0.5",token:"tok_first"},{name:"rig1",token:"tok_second"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
run_sourced "$C" render_masked_config "$C/data/control" >/dev/null 2>&1
UUID7="77777777-7777-4777-8777-777777777777"
jq --arg id "$UUID7" '{id:$id, action:"preview", actor:"admin", config: .}' "$MASKED" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "duplicate-name sentinel restores the first-declared token" "$(jq -r '.dashboard.workers[0].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"
assert_eq "duplicate-name second entry also resolves to first-declared" "$(jq -r '.dashboard.workers[1].token' "$STAGED/$UUID7.json" 2>/dev/null)" "tok_first"

echo "== black-box: per-worker token mask + host-side restore, workers.list[] shape (#506) =="
# Same mask/restore/commit round-trip as above, but on the CURRENT workers.list[] shape — proves
# render_masked_config and the control_preview sentinel swap key off whichever shape the live
# config actually uses, not a hardcoded dashboard.workers path. Clear the legacy key first so the
# live config carries only the new shape (both-set is refused at apply, asserted earlier).
jq 'del(.dashboard.workers) | .workers.list=[
    {name:"rig1",host:"10.0.0.5",token:"tok_rig1secret"},
    {name:"rig2"},
    {name:"rig3",token:"tok_rig3secret"}]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
# 1) masked prefill copy: each SET per-worker token is a sentinel, the raw token never appears.
assert_eq "workers.list token masked to the sentinel" "$(jq -c '.workers.list[0].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "second workers.list token masked to the sentinel" "$(jq -c '.workers.list[2].token' "$MASKED" 2>/dev/null)" '{"__secret__":true}'
assert_eq "token-less workers.list worker stays token-less in the masked copy" "$(jq -r '.workers.list[1] | has("token")' "$MASKED" 2>/dev/null)" "false"
case "$(cat "$MASKED")" in
*tok_rig1secret* | *tok_rig3secret*) bad "masked copy holds no workers.list token" "a per-worker token leaked into $MASKED" ;;
*) ok "masked copy holds no workers.list token" ;;
esac
# 2) staging swap: a proposal that prefills from the masked copy stages with each token restored
#    from live BY NAME.
UUID8="88888888-8888-4888-8888-888888888888"
jq --arg id "$UUID8" '{id:$id, action:"preview", actor:"admin", config: (.p2pool.pool="nano")}' "$MASKED" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel preview validates" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "previewed"
assert_eq "workers.list sentinel restored to the live token by name" "$(jq -r '.workers.list[0].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig1secret"
assert_eq "second workers.list sentinel restored by name" "$(jq -r '.workers.list[2].token' "$STAGED/$UUID8.json" 2>/dev/null)" "tok_rig3secret"
# 3) commit: workers.list restored to live == live, so the gate passes on the pool-only change, and
#    the committed config KEEPS the live per-worker tokens.
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID8" >"$REQS/$UUID8.json"
run_pending >/dev/null
assert_eq "workers.list-sentinel commit applies" "$(jq -r '.status' "$RESULTS/$UUID8.json" 2>/dev/null)" "applied"
assert_eq "committed config keeps the live workers.list token" "$(jq -r '.workers.list[0].token' "$C/config.json")" "tok_rig1secret"
assert_eq "committed config carries no sentinel dict" "$(jq -r '[.. | objects | select(.__secret__?)] | length' "$C/config.json")" "0"

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

echo "== black-box: audit log growth is bounded (#349) =="
# Seed the log past the 512 KiB cap, then let the runner audit one more event: the writer trims
# to the newest 2000 lines BEFORE appending, so the file shrinks instead of growing forever and
# the fresh entry is always the last line.
for _ in $(seq 1 6000); do
    printf '{"ts":"old","id":"","actor":"filler","action":"preview","status":"previewed","keys":""}\n'
done >>"$AUDIT"
[ "$(wc -c <"$AUDIT" | tr -d ' ')" -gt 524288 ] || bad "audit log seeded past the cap" "seed too small"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json" # no staged intent -> rejected, still audited
run_pending >/dev/null
audit_size="$(wc -c <"$AUDIT" | tr -d ' ')"
if [ "$audit_size" -lt 300000 ]; then
    ok "audit log trimmed back under the cap ($audit_size bytes)"
else
    bad "audit log trimmed back under the cap" "$audit_size bytes"
fi
assert_eq "trim keeps the newest entries (fresh entry is the last line)" "$(tail -n 1 "$AUDIT" | jq -r '.action')" "commit"
# Pin the line count too, not just the byte size: control_audit trims to `tail -n 2000` BEFORE
# appending the triggering entry, so the file must land at <= 2001 lines (2000 kept + the new one) —
# the "newest ~2000 lines" behavior the byte-size check above doesn't directly prove.
audit_lines="$(wc -l <"$AUDIT" | tr -d ' ')"
if [ "$audit_lines" -le 2001 ]; then
    ok "audit log trim caps the line count near the newest 2000 entries ($audit_lines lines)"
else
    bad "audit log trim caps the line count near the newest 2000 entries" "$audit_lines lines"
fi

echo "== black-box: spool intake cap + symlink refusal + stale sweep (#33 hardening) =="
UUID4="44444444-4444-4444-8444-444444444444"
# Oversized intent: refused BEFORE jq parses it (bounded root-runner DoS), no result addressed.
: >"$AUDIT"
{
    printf '{"id":"%s","action":"preview","pad":"' "$UUID4"
    head -c 70000 /dev/zero | tr '\0' a
    printf '"}\n'
} >"$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "oversized intent refused before parsing" "$(cat "$AUDIT" 2>/dev/null)" "refused-oversize"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "oversized intent gets no result file" || bad "oversized intent gets no result file" "result written"
[ ! -f "$REQS/$UUID4.json" ] && ok "oversized intent claimed out of requests/" || bad "oversized intent claimed out of requests/" "still present"
# Symlinked request: a symlink dropped in requests/ could point the root runner at any host file —
# refused, never followed (graft #437).
: >"$AUDIT"
ln -s "$C/config.json" "$REQS/$UUID4.json"
run_pending >/dev/null
assert_contains "symlinked request refused" "$(cat "$AUDIT" 2>/dev/null)" "refused-nonregular"
[ ! -f "$RESULTS/$UUID4.json" ] && ok "symlinked request gets no result" || bad "symlinked request gets no result" "result written"
rm -f "$REQS/$UUID4.json"
# Stale sweep: staged/ + requests/ files older than an hour are removed at run start.
jq -n '{}' >"$STAGED/stale.json"
touch -t 202001010000 "$STAGED/stale.json"
printf '{}' >"$REQS/stale-req.json"
touch -t 202001010000 "$REQS/stale-req.json"
run_pending >/dev/null
[ ! -f "$STAGED/stale.json" ] && ok "aged staged file swept" || bad "aged staged file swept" "still present"
[ ! -f "$REQS/stale-req.json" ] && ok "aged request file swept" || bad "aged request file swept" "still present"
# Orphaned claim sweep (#548): a `.claim.<pid>` left behind by a runner that died mid-dispatch
# (the errexit gap this issue closes) is swept the same way as stale staged/request files.
touch -t 202001010000 "$C/data/control/.claim.12345"
run_pending >/dev/null
[ ! -f "$C/data/control/.claim.12345" ] && ok "stale orphaned claim swept" || bad "stale orphaned claim swept" "still present"
# Per-run intake cap: 60 pending intents → one run claims exactly 50 and LEAVES the remainder in
# requests/ for the next path-unit fire (deterministic overflow — nothing is dropped). Invalid
# JSON bodies keep each of the 60 on the cheap discard path; they still count against the cap.
for i in $(seq 1 60); do printf 'notjson' >"$REQS/cap-$i.json"; done
out="$(run_pending)"
assert_contains "per-run cap announced after 50 intents" "$out" "per-run cap"
assert_contains "exactly 50 intents processed in one run" "$out" "Processed 50 control request(s)"
assert_eq "overflow intents left for the next run" "$(ls "$REQS" | wc -l | tr -d ' ')" "10"
out="$(run_pending)"
assert_contains "next run drains the remainder" "$out" "Processed 10 control request(s)"
assert_eq "spool empty after the second run" "$(ls "$REQS" | wc -l | tr -d ' ')" "0"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-control-deploy.sh
source "$HERE/test-control-deploy.sh"

echo "== control channel: Telegram lifecycle verbs (#338) =="
# The #33 runner dispatches the two bounded Telegram control verbs to FIXED pithead commands and
# audits them; an unknown verb is rejected and no host command runs. PITHEAD_SELF points the runner
# at a stub that only records the literal verb it was handed, so nothing real is applied/restarted.
CC="$SANDBOX/ctrl338"
mkdir -p "$CC/staged" "$CC/results" "$CC/audit"
cat >"$CC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$SELF_LOG"
exit 0
EOF
chmod +x "$CC/self"
export SELF_LOG="$CC/self.log"
export PITHEAD_SELF="$CC/self"
uid_r="11111111-1111-4111-8111-111111111111"
uid_a="22222222-2222-4222-8222-222222222222"
uid_x="33333333-3333-4333-8333-333333333333"

: >"$SELF_LOG"
printf '{"id":"%s","action":"restart","actor":"tg-7"}\n' "$uid_r" >"$CC/req_r.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_r.json" "$CC" >/dev/null 2>&1
assert_eq "restart intent runs the fixed 'restart' verb" "$(cat "$SELF_LOG")" "restart"
assert_eq "restart result is applied" "$(jq -r .status "$CC/results/$uid_r.json")" "applied"
assert_contains "restart is audited with the actor + action" \
    "$(cat "$CC/audit/control.log")" '"actor":"tg-7","action":"restart","status":"applied"'

: >"$SELF_LOG"
printf '{"id":"%s","action":"apply","actor":"tg-7"}\n' "$uid_a" >"$CC/req_a.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_a.json" "$CC" >/dev/null 2>&1
assert_eq "apply intent runs the fixed 'apply -y' verb (config re-apply, no edit)" "$(cat "$SELF_LOG")" "apply -y"
assert_eq "apply result is applied" "$(jq -r .status "$CC/results/$uid_a.json")" "applied"

: >"$SELF_LOG"
printf '{"id":"%s","action":"frobnicate","actor":"tg-7"}\n' "$uid_x" >"$CC/req_x.json"
run_sourced "$SANDBOX" control_process_request "$CC/req_x.json" "$CC" >/dev/null 2>&1
assert_eq "unknown verb rejected (bounded action set)" "$(jq -r .error "$CC/results/$uid_x.json")" "unknown action"
assert_eq "unknown verb never runs a host command" "$(cat "$SELF_LOG")" ""
unset PITHEAD_SELF SELF_LOG

# ---------------------------------------------------------------------------
echo "== control channel: backup verb (#908) =="
# control_backup generates its OWN passphrase (never accepted from the container), runs the
# real backup as a CHILD "$self backup -y" (stack_backup's own error() exits its process, which
# must not take the drain loop's other pending requests with it), and hands back a one-time kit
# through results/. A stub self reproduces stack_backup's own "Backup written to: <path>" log
# line so this stays a fast, docker-free test of the GLUE — the archive mechanics themselves are
# already covered by the backup/restore round-trip tests above (#140/#374).
BKC="$SANDBOX/ctrl908"
mkdir -p "$BKC/staged" "$BKC/results" "$BKC/audit"
cat >"$BKC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SELF_LOG:-/dev/null}"
printf '%s\n' "${PITHEAD_BACKUP_PASSPHRASE:-<empty>}" >>"${PASS_LOG:-/dev/null}"
if [ "${BACKUP_FAIL:-0}" = "1" ]; then
    echo "boom: disk full" >&2
    exit 1
fi
mkdir -p "$(dirname "$FAKE_ARCHIVE")"
printf 'FAKE-ENCRYPTED-BYTES' >"$FAKE_ARCHIVE"
echo "[pithead] Backup written to: $FAKE_ARCHIVE"
exit 0
EOF
chmod +x "$BKC/self"
export PITHEAD_SELF="$BKC/self"
export SELF_LOG="$BKC/self.log"
export PASS_LOG="$BKC/pass.log"
export CONTROL_BACKUP_KIT_TTL_S=0 # redact immediately — this block only checks the applied shape

bid1="a0a0a0a0-0000-4000-8000-000000000001"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000000.tar.gz.enc"
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid1" >"$BKC/req1.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req1.json" "$BKC" >/dev/null 2>&1
assert_eq "backup runs the fixed 'backup -y' verb (never --no-encrypt)" "$(cat "$SELF_LOG")" "backup -y"
assert_eq "backup result is applied" "$(jq -r .status "$BKC/results/$bid1.json")" "applied"
pass1="$(cat "$PASS_LOG")"
{ [ -n "$pass1" ] && [ "$pass1" != "<empty>" ]; } &&
    ok "the child gets a non-empty passphrase (via env, never argv)" ||
    bad "the child gets a non-empty passphrase (via env, never argv)" "got: $pass1"
assert_eq "the passphrase never rides argv (the child's own argv log shows only 'backup -y')" \
    "$(cat "$SELF_LOG")" "backup -y"
assert_eq "the kit names the archive by basename" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"
assert_contains "the kit lists what the archive holds" \
    "$(jq -r '.contents | join(",")' "$BKC/results/$bid1.json")" "config.json"
[ -f "$BKC/results/$bid1.tar.gz.enc" ] &&
    ok "the archive lands under results/ (the container's existing ro mount — no new bind mount)" ||
    bad "the archive lands under results/ (the container's existing ro mount — no new bind mount)" "missing"
assert_eq "the archive's content is preserved by the move into results/" \
    "$(cat "$BKC/results/$bid1.tar.gz.enc")" "FAKE-ENCRYPTED-BYTES"
assert_contains "backup is audited applied" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"applied"'
# TTL=0 above means the redaction ran synchronously before control_process_request returned.
assert_eq "the passphrase is gone once the TTL elapses (redacted in place, whether read or not)" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid1.json")" "null"
assert_contains "the redaction note explains the passphrase is gone" \
    "$(jq -r .note "$BKC/results/$bid1.json")" "no longer available"
assert_eq "the archive name survives the redaction (ciphertext stays downloadable)" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"

echo "== control channel: backup verb — the kit is visible before its TTL, gone after (#908) =="
# A wider TTL, checked mid-flight: the passphrase is readable for a real window (long enough for
# an ordinary dashboard poll), then null either way — "consumed or not, it's gone".
rm -f "$BKC/staged/.backup-stamp" # bid1 above already claimed the 10-minute throttle
bid2="a0a0a0a0-0000-4000-8000-000000000002"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000001.tar.gz.enc"
export CONTROL_BACKUP_KIT_TTL_S=3
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid2" >"$BKC/req2.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req2.json" "$BKC" >/dev/null 2>&1 &
bg_pid=$!
sleep 0.5 # well inside the 3s TTL — the stubbed child + write are effectively instant
mid_pass="$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)"
{ [ -n "$mid_pass" ] && [ "$mid_pass" != "null" ]; } &&
    ok "the passphrase IS present while inside the TTL window" ||
    bad "the passphrase IS present while inside the TTL window" "got: $mid_pass"
assert_eq "the kit's passphrase is exactly what the child received (same secret both ends)" \
    "$mid_pass" "$(cat "$PASS_LOG")"
wait "$bg_pid"
assert_eq "the passphrase is null once the TTL elapses" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)" "null"
[ -f "$BKC/results/$bid2.tar.gz.enc" ] &&
    ok "the archive file itself is untouched by the redaction" ||
    bad "the archive file itself is untouched by the redaction" "missing"
unset bg_pid mid_pass

echo "== control channel: backup verb — failure and throttle (#908) =="
rm -f "$BKC/staged/.backup-stamp" # bid2 above already claimed the 10-minute throttle
bid3="a0a0a0a0-0000-4000-8000-000000000003"
export CONTROL_BACKUP_KIT_TTL_S=0
export BACKUP_FAIL=1
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid3" >"$BKC/req3.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req3.json" "$BKC" >/dev/null 2>&1
assert_eq "a failed child backup is reported failed, not applied" \
    "$(jq -r .status "$BKC/results/$bid3.json")" "failed"
assert_contains "the failure carries the child's own error tail" \
    "$(jq -r .error "$BKC/results/$bid3.json")" "boom: disk full"
assert_eq "a failed backup's result never carries a passphrase field" \
    "$(jq -r 'has("passphrase")' "$BKC/results/$bid3.json")" "false"
assert_contains "the failed attempt is audited" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"failed"'
unset BACKUP_FAIL

# Throttle (mirrors #59's upgrade throttle): bid1 above already claimed the 10-minute window —
# a fourth attempt right after is refused before the passphrase is even generated.
bid4="a0a0a0a0-0000-4000-8000-000000000004"
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid4" >"$BKC/req4.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req4.json" "$BKC" >/dev/null 2>&1
assert_contains "an immediate second backup attempt is throttled" \
    "$(jq -r .error "$BKC/results/$bid4.json")" "less than 10 minutes"
assert_eq "a throttled attempt never runs the child" "$(cat "$SELF_LOG")" ""

# The request schema itself cannot carry a passphrase — control_process_request's fixed key
# allowlist (id/action/config/actor/version/worker/changes/confirm) rejects any other field
# before the action even dispatches, so the container has no field to smuggle one through.
bid5="a0a0a0a0-0000-4000-8000-000000000005"
printf '{"id":"%s","action":"backup","actor":"admin","passphrase":"leaked"}\n' "$bid5" >"$BKC/req5.json"
run_sourced "$SANDBOX" control_process_request "$BKC/req5.json" "$BKC" >/dev/null 2>&1
assert_contains "a request carrying a passphrase field is refused outright (unexpected keys)" \
    "$(jq -r .error "$BKC/results/$bid5.json")" "unexpected keys"

# Backstop: a kit whose runner was KILLED mid-TTL keeps a plaintext passphrase on /data. The next
# drain's control_redact_stale_kits must null it once past the TTL, while leaving a still-in-window
# kit and a non-kit result alone.
export CONTROL_BACKUP_KIT_TTL_S=20 # cutoff = max(2x, 120) = 120s
old_ts=$(($(date +%s) - 3600))     # an hour stale
now_ts=$(date +%s)                 # fresh
jq -n --argjson t "$old_ts" '{status:"applied",passphrase:"STRANDED-SECRET",archive:"a.enc",ts:$t}' >"$BKC/results/stale.json"
jq -n --argjson t "$now_ts" '{status:"applied",passphrase:"LIVE-SECRET",archive:"b.enc",ts:$t}' >"$BKC/results/fresh.json"
jq -n --argjson t "$old_ts" '{status:"applied",change_id:"c",ts:$t}' >"$BKC/results/other.json" # not a kit
run_sourced "$SANDBOX" control_redact_stale_kits "$BKC/results" >/dev/null 2>&1
assert_eq "a stranded kit passphrase (runner died mid-TTL) is redacted on the next drain" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/stale.json")" "null"
assert_eq "a kit still inside its window keeps its passphrase" \
    "$(jq -r '.passphrase' "$BKC/results/fresh.json")" "LIVE-SECRET"
assert_eq "a non-kit result is left untouched" \
    "$(jq -r '.change_id' "$BKC/results/other.json")" "c"
unset PITHEAD_SELF SELF_LOG PASS_LOG FAKE_ARCHIVE CONTROL_BACKUP_KIT_TTL_S bid1 bid2 bid3 bid4 bid5 pass1 old_ts now_ts

# shellcheck source=tests/stack/test-wizard-setup.sh
source "$HERE/test-wizard-setup.sh"

echo "== unit: provision_control_runner only removes units this checkout owns (#33) =="
# The pithead-control.{path,service} names are box-global, but a release bench holds several
# checkouts at once (live stack + e2e harness + bundle-smoke tmp dirs). A checkout with control
# disabled used to remove whatever units were installed — including the LIVE stack's runner,
# stranding its dashboard control requests (config editor stuck at "Previewing…"). The removal
# branch keys on the service unit's ExecStart: foreign owner → leave alone; own units → remove;
# a dangling path unit with no service file → still reaped.
PCR="$SANDBOX/pcr"
mkdir -p "$PCR/units" "$PCR/bin"
# uname stub: the OS gate reads `uname -s` at source time; report Linux so the branch runs on dev
# Macs too. systemctl stub satisfies the command -v gate.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCR/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCR/bin/systemctl"
chmod +x "$PCR/bin/uname" "$PCR/bin/systemctl"

pcr_run() { # <owner-dir|-> <run-dir> — seed units owned by owner-dir ('-' = no service file), run the removal branch from run-dir, echo sudo calls
    rm -f "$PCR/units/pithead-control.service" "$PCR/units/pithead-control.path"
    [ "$1" != "-" ] && printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCR/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=/x/requests/*.json\n' >"$PCR/units/pithead-control.path"
    (
        cd "$2" || exit
        PATH="$PCR/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        sudo() { echo "sudo:$*"; } # record instead of executing; the disable call's output is redirected in-function
        PITHEAD_UNIT_DIR="$PCR/units" DASHBOARD_CONTROL_ENABLED=false provision_control_runner
    )
}

assert_eq "foreign owner -> units left alone (no sudo rm)" "$(pcr_run /srv/code/other-checkout "$PCR")" ""
assert_contains "own units -> removed" "$(pcr_run "$PCR" "$PCR")" \
    "sudo:rm -f $PCR/units/pithead-control.path $PCR/units/pithead-control.service"
assert_contains "dangling path unit (no service file) -> still reaped" "$(pcr_run - "$PCR")" "sudo:rm -f"
# Versioned install dirs carry dots (pithead-v1.9.3). Ownership must compare the ExecStart path
# as an exact string, never a regex: with the dots read as "any char", a sibling whose path
# differs only at those positions would falsely match as our own — and get removed.
mkdir -p "$PCR/v1.9.3" "$PCR/v1x9y3"
assert_eq "foreign owner differing only at regex-dot positions -> left alone" \
    "$(pcr_run "$PCR/v1x9y3" "$PCR/v1.9.3")" ""
# One checkout, two spellings: production units carry the versioned dir in ExecStart, and an
# operator's disable apply runs through the `current` symlink. Ownership compares physical
# paths, so the unit is recognized as our own and removed — a literal $PWD compare would call
# it foreign and the disable would never converge.
mkdir -p "$PCR/versions/pithead-v1.9.3"
ln -s "$PCR/versions/pithead-v1.9.3" "$PCR/current"
assert_contains "own unit under its versioned spelling, run via the current symlink -> removed" \
    "$(pcr_run "$PCR/versions/pithead-v1.9.3" "$PCR/current")" "sudo:rm -f"
unset PCR pcr_run

echo "== unit: provision_control_runner refuses to overwrite a foreign install's units (#1190) =="
# The removal branch above got its ownership check when a disable-apply deleted the live stack's
# units; the INSTALL branch had none — any sibling checkout's apply/up with control enabled
# overwrote the box-global units and silently repointed dashboard control at itself (the
# production-stranding mechanism, this time via install instead of a failed upgrade). The guard:
# foreign owner that still exists on disk → refuse and name it; owner directory gone → adopt
# (that is how a new version takes over from a removed one); own unit → converge; unparseable
# ExecStart → leave alone, fail safe; PITHEAD_STEAL_CONTROL_UNITS=1 → deliberate takeover.
#
# Mutation proof (each ran red against its assertion with the guard intact elsewhere):
#   - drop the `[ -d "$install_owner" ]` conjunct  -> "owner directory gone -> adopted" goes red
#   - flip the `!=` ownership compare to `=`       -> "foreign existing owner -> refused" goes red
#   - drop the PITHEAD_STEAL_CONTROL_UNITS conjunct -> "steal escape -> overwritten" goes red
#   - drop the `steal` argument conjunct           -> "upgrade repoint (steal arg)" goes red
PCI="$SANDBOX/pci"
mkdir -p "$PCI/units" "$PCI/bin" "$PCI/mine" "$PCI/other"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCI/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCI/bin/systemctl"
chmod +x "$PCI/bin/uname" "$PCI/bin/systemctl"

pci_run() { # <owner-dir|-|garbage> <run-dir> [steal-env] [fn-arg] — seed a service unit, run the INSTALL branch, echo warns + recorded sudo calls
    rm -f "$PCI/units/pithead-control.service" "$PCI/units/pithead-control.path" "$PCI/calls"
    case "$1" in
    -) ;; # no pre-existing units
    garbage) printf '[Service]\nExecStart=/usr/bin/env not-ours\n' >"$PCI/units/pithead-control.service" ;;
    *) printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$1" >"$PCI/units/pithead-control.service" ;;
    esac
    (
        cd "$2" || exit
        PATH="$PCI/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        # Record instead of executing — into a side file, because the install branch redirects
        # `sudo tee`'s stdout to /dev/null, so an echoing stub would be invisible there.
        sudo() { echo "sudo:$*" >>"$PCI/calls"; }
        PITHEAD_UNIT_DIR="$PCI/units" DASHBOARD_CONTROL_ENABLED=true \
            CONTROL_DIR="$2/data/control" PITHEAD_STEAL_CONTROL_UNITS="${3:-0}" \
            provision_control_runner ${4:+"$4"} 2>&1
        cat "$PCI/calls" 2>/dev/null
    )
}

out="$(pci_run "$PCI/other" "$PCI/mine")"
assert_contains "install: foreign existing owner -> refused, names the owner" "$out" "belong to the install at $PCI/other"
assert_not_contains "install: foreign existing owner -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: foreign existing owner + steal escape -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 1)" "sudo:tee $PCI/units/pithead-control.service"
# The upgrade callsite's spelling: after a successful upgrade the OLD versioned dir still exists
# (it is the rollback), so the converge MUST take the units over — via the `steal` argument, not
# the operator env var. Without it every one-click upgrade would refuse and strand the channel.
assert_contains "install: foreign existing owner + upgrade repoint (steal arg) -> overwritten" \
    "$(pci_run "$PCI/other" "$PCI/mine" 0 steal)" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: foreign owner whose directory is gone -> adopted" \
    "$(pci_run "$PCI/long-gone" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
out="$(pci_run garbage "$PCI/mine")"
assert_contains "install: unparseable ExecStart -> left alone, says so" "$out" "not one this tool wrote"
assert_not_contains "install: unparseable ExecStart -> unit not overwritten" "$out" "sudo:tee"
assert_contains "install: own drifted unit -> converged (rewritten in place)" \
    "$(pci_run "$PCI/mine" "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
assert_contains "install: no units at all -> fresh install unaffected by the guard" \
    "$(pci_run - "$PCI/mine")" "sudo:tee $PCI/units/pithead-control.service"
unset PCI pci_run out

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

echo "== unit: preflight_remote_nodes dials before provisioning commits =="
PFSB=$(mktemp -d)
printf '{"monero":{"mode":"local"},"tari":{"mode":"local"}}' >"$PFSB/local.json"
run_sourced "$PFSB" preflight_remote_nodes "$PFSB/local.json" >/dev/null 2>&1
assert_rc "all-local config -> nothing to dial, rc 0" "$?" "0"
# 127.0.0.1:1 — reliably closed; the dial must fail fast and NAME the endpoint.
printf '{"monero":{"mode":"local"},"tari":{"mode":"remote","remote":{"host":"127.0.0.1","grpc_port":1}}}' >"$PFSB/bad.json"
out=$(run_sourced "$PFSB" preflight_remote_nodes "$PFSB/bad.json" 2>/dev/null)
assert_rc "unreachable remote Tari -> rc 1" "$?" "1"
assert_contains "failure names host and port" "$out" "127.0.0.1:1"
assert_contains "failure points at the LAN-access switch" "$out" "grpc_lan_access"
rm -rf "$PFSB"
unset PFSB out

echo "== unit: appliance defaults (tor.auto_heal) =="
# Applied only where ABSENT: an operator who wrote false meant it.
ADSB=$(mktemp -d)
printf '{"monero":{"wallet_address":"x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "absent auto_heal -> enabled" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "true"
printf '{"tor":{"auto_heal":false}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "explicit false is respected" "$(jq -r '.tor.auto_heal' "$ADSB/config.json")" "false"
printf '{"tor":{"data_dir":"/x"}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "other tor keys survive" "$(jq -r '.tor.data_dir' "$ADSB/config.json")" "/x"

# dashboard.control.enabled had NO coverage, which is how #1066 shipped. The appliance turns the
# control channel on because it has no other way in — but only behind a login, because an
# unauthenticated config editor can change the payout wallet and run `apply`, which is exactly
# what parse_and_validate_config refuses. The wizard's strip_defaults drops any answer equal to
# the reference default, and the reference has control.enabled false, so the key is absent from
# EVERY submission: injecting unconditionally built the forbidden pair on the "No login" answer
# and dead-ended first boot after the operator was told provisioning had started.
printf '{"dashboard":{"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a password present -> the control channel is turned on" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
printf '{"dashboard":{"auth":{"password":""}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "no password -> the control channel is NOT turned on (#1066)" "$(jq -r '.dashboard.control.enabled // "absent"' "$ADSB/config.json")" "absent"
printf '{"dashboard":{"control":{"enabled":false},"auth":{"password":"a-real-password"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "an explicit control.enabled false is respected" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "false"
# The whole first-boot sequence for the documented "No login" answer, in the order the appliance
# runs it. The invariant is the one the validator enforces: this machine must never hand itself a
# config carrying an enabled control channel and no password.
mkdir -p "$ADSB/spool"
printf 'none' >"$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "\"No login\" leaves the password empty, as asked" "$(jq -r '.dashboard.auth.password // ""' "$ADSB/config.json")" ""
assert_eq "\"No login\" never produces the pair the validator refuses (#1066)" \
    "$(jq -r 'if (.dashboard.control.enabled == true) and ((.dashboard.auth.password // "") == "") then "forbidden-pair" else "ok" end' "$ADSB/config.json")" "ok"
# ...and the same sequence WITH a login still ends up configurable, which is the whole reason the
# appliance turns the channel on: no shell, no ssh, no other way to change a payout address.
rm -f "$ADSB/spool/auth-mode"
printf '{"monero":{"wallet_address":"x"},"dashboard":{"auth":{"username":"admin"}}}' >"$ADSB/config.json"
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" ensure_appliance_dashboard_password "$ADSB/spool" >/dev/null 2>&1
PITHEAD_CONFIG_FILE="$ADSB/config.json" run_sourced "$ADSB" apply_appliance_defaults >/dev/null 2>&1
assert_eq "a generated login leaves the machine configurable" "$(jq -r '.dashboard.control.enabled' "$ADSB/config.json")" "true"
rm -rf "$ADSB"
unset ADSB

echo "== unit: load_baked_images — the archive digest, not the tag, decides a load (#798) =="
# Every build tags its images identically and the engine's storage lives on /data, which
# survives reinstalls and A/B updates — so "does the tag exist" pins a machine to the first
# image it ever loaded. Both boot owners (pithead-boot and the first-boot wizard) run this ONE
# loader; the digest record beside the store is what makes a keep-reinstall or A/B update
# converge on the shipped containers.
WSB=$(mktemp -d)
mkdir -p "$WSB/images" "$WSB/bin"
printf 'v1-archive' >"$WSB/images/dashboard.tar.gz"
cat >"$WSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
  image) [ -e "${PODMAN_IMAGE_PRESENT:-/nonexistent}" ] ;;   # `image exists <ref>`
  load) exit "${PODMAN_LOAD_RC:-0}" ;;
esac
EOF
chmod +x "$WSB/bin/podman"
export PODMAN_LOG="$WSB/podman.log" PITHEAD_IMAGES_DIR="$WSB/images"
lbl() { PITHEAD_ENGINE=podman PATH="$WSB/bin:$PATH" run_sourced "$WSB" load_baked_images "$@"; }
WREC="$WSB/data/.loaded-dashboard.tar.gz.sha"
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && ok "first boot loads the archive" ||
    bad "first boot loads the archive" "no load call"
assert_eq "the digest is recorded beside the store" \
    "$(cat "$WREC" 2>/dev/null)" "$(sha_of "$WSB/images/dashboard.tar.gz")"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" && bad "an unchanged archive is not reloaded" "loaded again" ||
    ok "an unchanged archive is not reloaded"
printf 'v2-archive-different' >"$WSB/images/dashboard.tar.gz"
: >"$PODMAN_LOG"
lbl >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a changed archive reloads — the keep-reinstall and A/B update path" ||
    bad "a changed archive reloads" "no load call"
# The wizard names the image it needs: a matching record must not count when the image is gone
# (the record can outlive the storage it describes).
: >"$PODMAN_LOG"
lbl ghcr.io/x/pithead-dashboard:v0 >/dev/null 2>&1
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a missing required image forces a load despite a matching record" ||
    bad "a missing required image forces a load" "no load call"
# A failed load leaves the old record: the next boot must retry, not skip.
WV2SHA=$(cat "$WREC")
printf 'v3-archive' >"$WSB/images/dashboard.tar.gz"
export PODMAN_LOAD_RC=1
lbl >/dev/null 2>&1
unset PODMAN_LOAD_RC
assert_eq "a failed load records nothing — the next boot retries" "$(cat "$WREC")" "$WV2SHA"
unset PODMAN_LOG PITHEAD_IMAGES_DIR
unset -f lbl sha_of
rm -rf "$WSB"
unset WSB WREC WV2SHA

echo "== unit: load_baked_images — a store damaged by an interrupted write is rebuilt =="
# An unclean reset mid-load (power cut, or the watchdog firing while slow media is written) leaves
# ZERO-LENGTH `lower` files; containers/storage then readlinks the graph root itself and EVERY
# container start fails. The digest record still matches AND the image still exists, so the two
# guards above both pass and the reload was skipped — which is what made the damage permanent and
# left an appliance unable to install from its own stick. A base layer carries no `lower` file at
# all, so a zero-length one is damage, never a legitimate state.
RSB=$(mktemp -d)
mkdir -p "$RSB/images" "$RSB/bin" "$RSB/data"
printf 'archive' >"$RSB/images/dashboard.tar.gz"
cat >"$RSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
echo "[podman] $*" >>"${PODMAN_LOG:-/dev/null}"
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 0 ;; # the image ALWAYS exists — that is the point of this test
load) exit 0 ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$RSB/bin/podman"
export PODMAN_LOG="$RSB/podman.log" PITHEAD_IMAGES_DIR="$RSB/images" FAKE_GRAPHROOT="$RSB/store"
rbl() { PITHEAD_ENGINE=podman PATH="$RSB/bin:$PATH" run_sourced "$RSB" load_baked_images; }
# A healthy store: the base layer has NO `lower`, the layer above carries a real chain.
mk_store() {
    rm -rf "$RSB/store"
    mkdir -p "$RSB/store/overlay/base/diff" "$RSB/store/overlay/top/diff"
    printf 'l/BASE' >"$RSB/store/overlay/top/lower"
}
mk_store
printf '%s' "$(sha256sum "$RSB/images/dashboard.tar.gz" | cut -d' ' -f1)" >"$RSB/data/.loaded-dashboard.tar.gz.sha"
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay/top" ] &&
    ok "a healthy store is left alone — no needless re-pull" ||
    bad "a healthy store is left alone" "the store was rebuilt"
grep -q "load -i" "$PODMAN_LOG" &&
    bad "a healthy store still honours the digest record" "reloaded anyway" ||
    ok "a healthy store still honours the digest record"

mk_store
: >"$RSB/store/overlay/base/lower" # zero-length: the corruption itself
: >"$PODMAN_LOG"
rbl >/dev/null 2>&1
[ -d "$RSB/store/overlay" ] &&
    bad "a damaged store is torn down" "the store survived" ||
    ok "a damaged store is torn down"
grep -q "load -i" "$PODMAN_LOG" &&
    ok "a damaged store reloads the archive despite a matching record" ||
    bad "a damaged store reloads the archive" "no load call"
unset PODMAN_LOG PITHEAD_IMAGES_DIR FAKE_GRAPHROOT
unset -f rbl mk_store
rm -rf "$RSB"
unset RSB

echo "== unit: load_baked_images — a slow load narrates itself, a fast one stays quiet =="
# `podman load` prints nothing a console sees and runs for MINUTES on USB media (3m47s measured
# on the bench) behind a line promising "a minute or two" — so a working box looked hung, twice.
# A rising elapsed count is what tells slow apart from stuck. The load stays in the FOREGROUND
# and the heartbeat is the background job: polling a backgrounded load with `kill -0` would make
# a fast load pay a full sleep, because a finished-but-unwaited child still answers.
HSB=$(mktemp -d)
mkdir -p "$HSB/images" "$HSB/bin" "$HSB/data"
printf 'archive' >"$HSB/images/dashboard.tar.gz"
cat >"$HSB/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 1 ;;
load) sleep "${FAKE_LOAD_SECS:-0}" ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$HSB/bin/podman"
export PITHEAD_IMAGES_DIR="$HSB/images" FAKE_GRAPHROOT="" PITHEAD_LOAD_HEARTBEAT_SECS=1
hbl() { PITHEAD_ENGINE=podman PATH="$HSB/bin:$PATH" run_sourced "$HSB" load_baked_images 2>&1; }

export FAKE_LOAD_SECS=3
hout=$(hbl)
assert_contains "a slow load reports it is still working" "$hout" "still loading"
assert_contains "the heartbeat carries elapsed seconds" "$hout" "elapsed"

rm -f "$HSB/data/.loaded-dashboard.tar.gz.sha"
export FAKE_LOAD_SECS=0
hstart=$(date +%s)
hout=$(hbl)
hlen=$(($(date +%s) - hstart))
printf '%s' "$hout" | grep -q "still loading" &&
    bad "a fast load stays quiet" "heartbeat fired anyway" ||
    ok "a fast load stays quiet — no heartbeat for work already done"
[ "$hlen" -lt 3 ] &&
    ok "a fast load does not wait on the heartbeat interval (${hlen}s)" ||
    bad "a fast load returns promptly" "took ${hlen}s"
unset PITHEAD_IMAGES_DIR FAKE_GRAPHROOT PITHEAD_LOAD_HEARTBEAT_SECS FAKE_LOAD_SECS
unset -f hbl
rm -rf "$HSB"
unset HSB hout hstart hlen

# shellcheck source=tests/stack/test-appliance-install.sh
source "$HERE/test-appliance-install.sh"

# shellcheck source=tests/stack/test-appliance-rig-miner.sh
source "$HERE/test-appliance-rig-miner.sh"

echo "== unit: pithead-boot wiring — the miner leg rides AFTER the slot commit =="
# Ordering is the contract: the stack serving is the product's health and gates the A/B commit;
# the miner is a passenger that needs the stratum listening and must never delay the commit.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
mg_line=$(grep -n "mark-good" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
lm_line=$(grep -n "pithead local-miner" "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$mg_line" ] && [ -n "$lm_line" ] && [ "$lm_line" -gt "$mg_line" ]; then
    ok "pithead-boot runs 'pithead local-miner' after the health-gated commit"
else
    bad "pithead-boot runs 'pithead local-miner' after the health-gated commit" \
        "mark-good@${mg_line:-none} local-miner@${lm_line:-none}"
fi
# A hung miner setup must not wedge the boot unit either — TimeoutStartSec=infinity on
# pithead-boot means || true alone cannot save it; the leg needs its own bounded clock.
grep -qE "timeout [0-9]+ \./pithead local-miner" "$BOOTSCRIPT" &&
    ok "the miner leg runs under its own timeout (boot unit has no clock of its own)" ||
    bad "the miner leg runs under its own timeout (boot unit has no clock of its own)" \
        "no 'timeout N ./pithead local-miner' in pithead-boot"

# The rig fork (#797 R4): a rig has no stack, so the role branch must come BEFORE the loader and
# must never reach render/up. It still commits its own slot — one image, one update pipeline.
rig_line=$(grep -n '^if .*machine-role' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
li_line=$(grep -n 'pithead load-images' "$BOOTSCRIPT" | head -1 | cut -d: -f1)
if [ -n "$rig_line" ] && [ -n "$li_line" ] && [ "$rig_line" -lt "$li_line" ]; then
    ok "the role fork precedes the container-image loader (a rig loads none)"
else
    bad "the role fork precedes the container-image loader (a rig loads none)" \
        "role@${rig_line:-none} load-images@${li_line:-none}"
fi
# A coordinator has no marker, and reading a file that is not there is a REDIRECTION failure the
# shell reports itself — `2>/dev/null` on the inner command cannot reach it. Harmless to control
# flow, but it would print "No such file or directory" into the journal of every coordinator
# boot. Existence has to be tested before the read.
sed -n "${rig_line:-1}p" "$BOOTSCRIPT" | grep -q '\[ -f machine-role \]' &&
    ok "the marker is tested for existence before it is read (no error on every coordinator boot)" ||
    bad "the marker is tested for existence before it is read (no error on every coordinator boot)" \
        "$(sed -n "${rig_line:-1}p" "$BOOTSCRIPT")"
rig_branch=$(sed -n "${rig_line:-1},/^fi\$/p" "$BOOTSCRIPT")
printf '%s' "$rig_branch" | grep -qE '\./pithead (up|render|load-images)' &&
    bad "the rig branch starts nothing container-shaped" "it calls the stack's own commands" ||
    ok "the rig branch starts nothing container-shaped"
printf '%s' "$rig_branch" | grep -q 'mark-good' &&
    ok "a rig commits its A/B slot exactly like a coordinator" ||
    bad "a rig commits its A/B slot exactly like a coordinator" "no mark-good in the rig branch"
# The units are the other half of the fork: without the triggering condition a rig never runs
# the boot unit, and without the firstboot exclusion it re-runs the WIZARD every boot.
BOOTUNIT="$ROOT/os/overlay/pithead-boot.service"
FBUNIT="$ROOT/os/overlay/pithead-firstboot.service"
grep -q '^ConditionPathExists=|/data/pithead/machine-role' "$BOOTUNIT" &&
    grep -q '^ConditionPathExists=|/data/pithead/config.json' "$BOOTUNIT" &&
    ok "the boot unit triggers on either shape of provisioned (config.json or the role marker)" ||
    bad "the boot unit triggers on either shape of provisioned (config.json or the role marker)" \
        "$(grep -c '^ConditionPathExists=|' "$BOOTUNIT") triggering conditions"
grep -q '^ConditionPathExists=!/data/pithead/machine-role' "$FBUNIT" &&
    ok "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" ||
    bad "the wizard window is closed by the role marker too (no wizard on a provisioned rig)" "missing"
# The marker, not rig.json: a fleet stick writes a rig's ANSWERS in flight while installing one
# onto a disk, and must stay an installer through it — only an ACCEPTED role writes the marker.
grep -h '^ConditionPathExists=' "$BOOTUNIT" "$FBUNIT" | grep -q 'rig\.json' &&
    bad "neither unit keys on the in-flight rig.json (a stick would stop being an installer)" "it does" ||
    ok "neither unit keys on the in-flight rig.json (a stick stays an installer)"
unset BOOTSCRIPT BOOTUNIT FBUNIT mg_line lm_line rig_line li_line rig_branch

echo "== unit: the A/B commit gate consumes doctor --json, not just the curl (#852) =="
# The gate that used to be a bare curl to https://localhost/ committed any slot whose dashboard
# answered — even one whose mining services had crashed. The fix pairs the curl with doctor's
# exit code. Assert the wiring: both signals gate the same mark-good, curl first (cheap).
# BOTH signals must gate mark-good (#852): a slot whose dashboard answers but whose mining
# containers have crashed must NOT commit. This was a grep of the boot script until #1140, and the
# doctor half of that grep matched the file's own HEADER COMMENT — it stayed green with the doctor
# call deleted from the commit condition outright. The pairing now lives in gate_ready and is
# driven here with a stubbed `pithead`, so deleting either half goes red.
# Mutation run: drop the doctor call from gate_ready -> "a crashed stack does not commit" goes red;
# drop the gate_answer_is_dashboard call -> "the default vhost does not commit" goes red.
GR="$SANDBOX/gate-ready"
mkdir -p "$GR"
gr_run() { # <doctor-exit> <code> <size> -> ready|held
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" >"$GR/pithead"
    chmod +x "$GR/pithead"
    (
        cd "$GR" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        BOOT_DOCTOR_JSON="$GR/doctor.json"
        gate_ready "$2" "$3" && echo ready || echo held
    )
}
assert_eq "dashboard serving AND doctor clean -> commit" "$(gr_run 0 200 4096)" "ready"
# #852 itself: the mining-dead-but-serving slot a curl-only gate used to mark-good.
assert_eq "a crashed stack does not commit, however well the dashboard answers" "$(gr_run 1 200 4096)" "held"
# #1140 itself: Caddy's empty default vhost must not open the door to the doctor run either.
assert_eq "the default vhost does not commit, even with doctor clean" "$(gr_run 0 200 0)" "held"
assert_eq "nothing answering does not commit" "$(gr_run 0 000 0)" "held"
assert_eq "a locked dashboard (401) with doctor clean -> commit" "$(gr_run 0 401 0)" "ready"
unset -f gr_run
unset GR

echo "== unit: the boot health probe asks the dashboard's own site, and can tell it apart (#1140) =="
# The probe used to dial https://localhost/ and accept any status but 000, on the stated belief
# that localhost is always a listed site. generate_caddyfile only adds localhost while
# dashboard.host is UNSET — pin the host and the probe reached Caddy's EMPTY DEFAULT VHOST, which
# answers 200 with no body. On the gate that decides whether an A/B update lives, and that #1065
# reboots on, "Caddy is running" was passing as "the dashboard serves".
# Two halves, both driven here: ask the right site, and recognise the right answer.
GU="$SANDBOX/gateurl"
mkdir -p "$GU"
gu_run() { # <env-body> -> "scheme|host|port"
    printf '%s\n' "$1" >"$GU/.env"
    (
        cd "$GU" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_url
    )
}
# THE #1140 CASE: a pinned dashboard.host. The site list holds that name and NOT localhost, so the
# probe has to carry it or it is talking to the default vhost.
assert_eq "a pinned host is what the probe asks for" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true')" "https|panel.example|443"
# Unpinned: HOST_IP is whatever resolve_dashboard_host chose, and it is still the first site.
assert_eq "an unpinned host still comes from the render, not a literal" \
    "$(gu_run 'HOST_IP=pithead.local
DASHBOARD_SECURE=true')" "https|pithead.local|443"
assert_eq "dashboard.secure:false -> the site is http, so the probe is too" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=false')" "http|panel.example|80"
assert_eq "a custom host port is honoured" \
    "$(gu_run 'HOST_IP=panel.example
DASHBOARD_SECURE=true
HOST_PORT=8443')" "https|panel.example|8443"
# Fail SAFE, not closed: an unreadable .env must not make this gate a permanent RED, because after
# #1065 a gate that never passes reboots a healthy box. Falling back to localhost is the old
# behaviour, and gate_answer_is_dashboard below still refuses to call the default vhost a success.
assert_eq "an .env with no HOST_IP falls back rather than dialling nothing" \
    "$(gu_run 'DASHBOARD_SECURE=true')" "https|localhost|443"
unset -f gu_run
unset GU

gad() { # <code> <size> -> accept|reject
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        gate_answer_is_dashboard "$1" "$2" && echo accept || echo reject
    )
}
# The whole point: Caddy's empty default vhost answers 200 with a zero-length body. That is the
# answer #1140 was accepting as a healthy dashboard.
assert_eq "200 with an empty body is the default vhost -> REJECT" "$(gad 200 0)" "reject"
assert_eq "200 with a real page is the dashboard -> accept" "$(gad 200 4096)" "accept"
# Auth on: the login's 401 has no body of its own, so size alone would reject a healthy locked box.
assert_eq "401 (a healthy, locked dashboard) -> accept" "$(gad 401 0)" "accept"
# Auth OFF is supported — an empty dashboard password is the documented default — so the box that
# answers 200 with a page must pass. That is why this is not a 401 check.
assert_eq "no connection at all -> reject" "$(gad 000 0)" "reject"
assert_eq "an empty code -> reject" "$(gad '' 0)" "reject"
assert_eq "a 502 from a dead upstream -> reject" "$(gad 502 0)" "reject"
assert_eq "a redirect carrying a body -> accept" "$(gad 308 120)" "accept"
unset -f gad

# dashboard.host is validated as "a hostname or IP address" and explicitly allows colons, so HOST_IP
# can be an IPv6 literal. curl will not take one in --resolve — it rejects the WHOLE option with
# "Couldn't parse CURLOPT_RESOLVE entry" — and an unbracketed literal in the URL reads the port as
# part of the address. Either way the request fails, the gate never passes, and #1065 reboots a
# healthy box: a false RED on this gate is as bad as the false GREEN this issue is about. Measured
# against curl 8.7 before writing these.
# Mutation run: drop the *:* arm of gate_target_url -> the bracketing assertion goes red; make
# gate_resolve_spec answer for every host -> the two literal assertions go red.
# NOT run_sourced: that sources `pithead`, and these live in the boot overlay. (An assert_eq
# expecting "" would pass vacuously against a function that was never defined, so the non-empty
# assertions below are what prove the source landed.)
boot_fn() { # <function> <args...>
    (
        cd "$SANDBOX" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        "$@"
    )
}
gtu() { boot_fn gate_target_url "$@"; }
grs() { boot_fn gate_resolve_spec "$@"; }
assert_eq "a name goes in the URL as-is" "$(gtu https panel.example 443)" "https://panel.example:443/"
assert_eq "an IPv6 literal is bracketed, or the port joins the address" \
    "$(gtu https 2001:db8::1 443)" "https://[2001:db8::1]:443/"
assert_eq "an IPv4 literal needs no brackets" "$(gtu http 192.0.2.5 80)" "http://192.0.2.5:80/"
# --resolve is for names only. It is what keeps a name's dial on loopback without the box having to
# resolve its own mDNS name; a literal is already an address and needs no lookup.
assert_eq "a name gets a --resolve spec pointing at loopback" \
    "$(grs panel.example 443)" "panel.example:443:127.0.0.1"
assert_eq "an IPv6 literal gets NO --resolve (curl cannot parse one)" "$(grs 2001:db8::1 443)" ""
assert_eq "an IPv4 literal gets no --resolve either" "$(grs 192.0.2.5 80)" ""
unset -f gtu grs boot_fn

echo "== unit: os_update_rollback_verdict — the rolled_back verdict, provable without a KVM boot (#1051) =="
# A dashboard-driven install leaves data/os-update/in-flight.json naming the version the machine
# was headed to. If THIS boot's VERSION disagrees, the bootloader already fell back — the update
# failed its health gate, and the verdict belongs in the state file now. Before #1051 this was
# inline code that only ran when pithead-boot was EXECUTED, never sourced, so no tier could ever
# drive it with a fixture — genuinely untested, at every tier, despite being promised in two
# operator-facing docs. It is pure file logic (an in-flight flag, a VERSION file, one jq call), so
# nothing here needs real firmware or a real A/B updater to prove; #1051 pulled it into a function
# for exactly that reason.
# Mutation run: flip the != to = in os_update_rollback_verdict's version check -> both assertions
# below invert (a real fallback stays silent, a real landing wrongly claims rollback).
ORV="$SANDBOX/os-rollback-verdict"
orv_run() { # <running-version> [inflight-to] -> "<outcome> <in-flight-consumed>"
    rm -rf "$ORV"
    mkdir -p "$ORV/data/os-update" "$ORV/data/control/results"
    printf '%s\n' "$1" >"$ORV/VERSION"
    # "consumed" has to mean the flag EXISTED and the function REMOVED it — checking only
    # post-call existence conflates that with "there was never a flag to remove", so the
    # no-flag case wrongly read back as consumed. had_flag pins the before state.
    local had_flag=no
    if [ -n "${2:-}" ]; then
        printf '{"from":"1.0.0","to":"%s"}\n' "$2" >"$ORV/data/os-update/in-flight.json"
        had_flag=yes
    fi
    (
        cd "$ORV" || exit 1
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        OS_INFLIGHT=data/os-update/in-flight.json
        OS_STATE_DIR=data/control/results
        os_update_rollback_verdict >/dev/null
    )
    local outcome consumed=no
    outcome=$(jq -r '.verdict.outcome // "none"' "$ORV/data/control/results/os-update-state.json" 2>/dev/null)
    [ "$had_flag" = yes ] && [ ! -f "$ORV/data/os-update/in-flight.json" ] && consumed=yes
    printf '%s %s' "${outcome:-none}" "$consumed"
}
assert_eq "a fallback boot (running the OLD version) writes rolled_back and consumes the flag" \
    "$(orv_run 1.2.3 1.2.4)" "rolled_back yes"
assert_eq "a landed boot (running matches the target) writes nothing here — the commit gate's success half owns it" \
    "$(orv_run 1.2.4 1.2.4)" "none no"
assert_eq "no in-flight flag at all is a no-op" "$(orv_run 1.2.3)" "none no"
unset -f orv_run
unset ORV

echo "== unit: revenue_container_verdict — commit-gate honesty, syncing vs crashed (#852) =="
# The pure classifier behind check_revenue_containers, so the commit gate's central judgement is
# tested without a running stack. Two rules it must hold:
#   1. a crashed/unhealthy CHAIN node (monerod/tari/wallets) is a fault — the slot must not commit;
#   2. a DOWN sync-gated miner (p2pool/xmrig-proxy) is the deliberate #35 hold, not a fault — so a
#      days-long initial sync still commits. Only a running-but-unhealthy miner is a fault.
rcv() { run_sourced "$SANDBOX" revenue_container_verdict "$@"; }
# Chain nodes: healthy commits, everything short of running-and-healthy holds.
assert_eq "monerod up+healthy -> ok" "$(rcv monerod running 'Up 5 minutes (healthy)')" "ok"
assert_contains "monerod exited -> fail" "$(rcv monerod exited 'Exited (0) 1 minute ago')" "fail:monerod"
assert_contains "monerod running+unhealthy -> fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)')" "fail:monerod"
assert_contains "monerod still starting -> fail (loop retries, never commits early)" "$(rcv monerod running 'Up 8 seconds (starting)')" "fail:monerod"
assert_eq "tari up+healthy -> ok" "$(rcv tari running 'Up 3 minutes (healthy)')" "ok"
assert_contains "wallet-rpc down -> fail (chain-side must be up)" "$(rcv wallet-rpc created 'Created')" "fail:wallet-rpc"
# Sync-gated miners: down is the #35 hold (ok); only running-but-unhealthy is a fault.
assert_eq "p2pool exited (sync hold) -> ok" "$(rcv p2pool exited 'Exited (0) 4 minutes ago')" "ok"
assert_eq "p2pool created (never started, held) -> ok" "$(rcv p2pool created 'Created')" "ok"
assert_eq "p2pool up+healthy -> ok" "$(rcv p2pool running 'Up 6 minutes (healthy)')" "ok"
assert_contains "p2pool running+unhealthy -> fail" "$(rcv p2pool running 'Up 30 seconds (unhealthy)')" "fail:p2pool"
assert_eq "xmrig-proxy down (sync hold) -> ok" "$(rcv xmrig-proxy exited 'Exited (0) 4 minutes ago')" "ok"
# Non-revenue containers are out of scope — the rest of doctor covers them.
assert_eq "caddy (not revenue) -> ok" "$(rcv caddy running 'Up 5 minutes')" "ok"
assert_eq "dashboard (not revenue) -> ok" "$(rcv dashboard running 'Up 5 minutes (healthy)')" "ok"
# The migration hold (#851): with chain_hold=1 a chain node is judged by the miners' rule — the
# boot path is deliberately withholding it, so down is expected and the commit must not deadlock
# on the very hold it gates. A RUNNING-but-unhealthy chain node is still a fault.
assert_eq "monerod down under the migration hold -> ok" "$(rcv monerod exited 'Exited (0) 1 minute ago' 1)" "ok"
assert_eq "tari never created under the migration hold -> ok" "$(rcv tari created 'Created' 1)" "ok"
assert_eq "wallet-rpc down under the migration hold -> ok" "$(rcv wallet-rpc exited 'Exited (0) 2 minutes ago' 1)" "ok"
assert_contains "monerod running+unhealthy under the hold -> still fail" "$(rcv monerod running 'Up 2 minutes (unhealthy)' 1)" "fail:monerod"
assert_eq "monerod up+healthy under the hold -> ok (an early manual start is not a fault)" "$(rcv monerod running 'Up 5 minutes (healthy)' 1)" "ok"
assert_contains "the hold changes nothing for a miner" "$(rcv p2pool running 'Up 30 seconds (unhealthy)' 1)" "fail:p2pool"
unset -f rcv

echo "== unit: pithead-sync's rigforge leg — program replaced, state preserved, prebuilt seeded =="
# The baked tree is program; config.json (pithead-rendered) and the data/ workspace (the XMRig
# build cache) are state. The prebuilt binary seeds the workspace so the appliance never needs
# RigForge's clone path — github over clearnet, unreachable from a Tor-only box.
SYNCSCRIPT="$ROOT/os/overlay/pithead-sync"
SSB=$(mktemp -d)
mkdir -p "$SSB/opt-pithead" "$SSB/opt-rigforge/util" "$SSB/opt-rigforge/prebuilt/xmrig/build"
for f in pithead pithead-completion.bash VERSION docker-compose.yml \
    config.reference.json config.core-keys.json config.minimal.json cosign.pub; do
    printf 'pithead-program' >"$SSB/opt-pithead/$f"
done
printf 'program-v2' >"$SSB/opt-rigforge/rigforge.sh"
chmod +x "$SSB/opt-rigforge/rigforge.sh"
printf 'helper' >"$SSB/opt-rigforge/util/proposed-grub.sh"
printf 'bin-v2' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'commit-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'sha-B\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-sha256"
run_sync() {
    PITHEAD_SYNC_SRC="$SSB/opt-pithead" PITHEAD_SYNC_DST="$SSB/data/pithead" \
        PITHEAD_SYNC_RIGFORGE_SRC="$SSB/opt-rigforge" PITHEAD_SYNC_RIGFORGE_DST="$SSB/data/rigforge" \
        bash "$SYNCSCRIPT"
}
run_sync >/dev/null 2>&1
assert_rc "sync runs clean" "$?" "0"
[ -x "$SSB/data/rigforge/rigforge.sh" ] && ok "rigforge program delivered beside pithead's" ||
    bad "rigforge program delivered beside pithead's" "missing"
assert_eq "prebuilt seeded into the workspace where 'already built' finds it" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig" 2>/dev/null)" "bin-v2"
assert_eq "the commit marker rides with the seed" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/.rigforge-commit" 2>/dev/null)" "commit-B"
[ -e "$SSB/data/rigforge/prebuilt" ] && bad "prebuilt/ is a seed, never a synced tree" "synced" ||
    ok "prebuilt/ is a seed, never a synced tree"
# State survives a re-run: the rendered config and a native rebuild of the SAME pin stay put.
printf '{"pools":[{"url":"127.0.0.1:3333"}]}' >"$SSB/data/rigforge/config.json"
printf 'native-rebuild' >"$SSB/data/rigforge/data/worker/xmrig/build/xmrig"
run_sync >/dev/null 2>&1
assert_eq "config.json (state) survives the resync" \
    "$(cat "$SSB/data/rigforge/config.json")" '{"pools":[{"url":"127.0.0.1:3333"}]}'
assert_eq "a same-pin native rebuild is left alone" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "native-rebuild"
# A new pin arrives with a new image AND its new prebuilt: the cached build is replaced, so the
# on-box clone path never needs to run.
printf 'commit-C\n' >"$SSB/opt-rigforge/prebuilt/xmrig/.rigforge-commit"
printf 'bin-v3' >"$SSB/opt-rigforge/prebuilt/xmrig/build/xmrig"
printf 'program-v3' >"$SSB/opt-rigforge/rigforge.sh"
run_sync >/dev/null 2>&1
assert_eq "a new pin replaces the cached build with the new prebuilt" \
    "$(cat "$SSB/data/rigforge/data/worker/xmrig/build/xmrig")" "bin-v3"
assert_eq "program files are replaced wholesale" "$(cat "$SSB/data/rigforge/rigforge.sh")" "program-v3"
# An image without the bake (downgrade, older layout): the leg skips cleanly.
rm -rf "$SSB/opt-rigforge"
run_sync >/dev/null 2>&1
assert_rc "no baked tree -> the leg is skipped, sync still clean" "$?" "0"
unset -f run_sync
rm -rf "$SSB"
unset SSB SYNCSCRIPT

echo "== unit: optimize_kernel's HugePages write is grow-only =="
# With a co-located miner the pool is shared and RigForge (grow-only by design) sizes it as the
# single writer — pithead writing its absolute 3072 on top would shrink a grown pool to the
# in-use floor and starve whichever side restarts next.
OKSB=$(mktemp -d)
mkdir -p "$OKSB/bin"
printf '#!/usr/bin/env bash\necho "sudo:$*" >>"${OKLOG:?}"\n' >"$OKSB/bin/sudo"
# OS_TYPE is readonly once sourced, so the Linux arm is selected the way pcr791 does it: a
# stubbed uname on PATH before the source.
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec /usr/bin/uname "$@"\n' >"$OKSB/bin/uname"
chmod +x "$OKSB/bin/sudo" "$OKSB/bin/uname"
export OKLOG="$OKSB/calls"
okrun() { # <pages currently in the pool> [degrade-marker file]
    printf '%s\n' "$1" >"$OKSB/nr"
    (
        cd "$OKSB" || exit
        PATH="$OKSB/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        warn() { :; }
        PITHEAD_NR_HUGEPAGES_FILE="$OKSB/nr" PITHEAD_HUGEPAGES_MARKER="${2:-$OKSB/no-marker}" \
            optimize_kernel </dev/null
    )
}
: >"$OKLOG"
okrun 100 >/dev/null 2>&1
assert_contains "a small pool is grown to the stack's budget" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=3072"
: >"$OKLOG"
okrun 4000 >/dev/null 2>&1
assert_not_contains "a larger pool (the miner's merged budget) is never shrunk" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 3072 >/dev/null 2>&1
assert_not_contains "an exact pool is left alone" "$(cat "$OKLOG")" "vm.nr_hugepages"
# The degrade cap (#977): the boot-time sizing's marker records the chosen page count, and that
# record caps the grow. Without it the wizard-accept path (setup runs as root on the appliance)
# re-inflated the pool the sizing had just shrunk, while the marker and doctor kept saying
# "reduced". A pool at the recorded size is left alone; one below it grows only to the record.
printf 'reduced-reservation words for the operator\npages=2560\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 2560 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a marker-sized pool is never re-inflated to the full budget" "$(cat "$OKLOG")" "vm.nr_hugepages"
: >"$OKLOG"
okrun 100 "$OKSB/marker" >/dev/null 2>&1
assert_contains "a pool below the record grows to the record" "$(cat "$OKLOG")" "sudo:sysctl -w vm.nr_hugepages=2560"
assert_not_contains "the grow never passes the marker's cap" "$(cat "$OKLOG")" "3072"
printf 'released-reservation words\npages=0\n' >"$OKSB/marker"
: >"$OKLOG"
okrun 0 "$OKSB/marker" >/dev/null 2>&1
assert_not_contains "a released (0-page) decision writes nothing at all" "$(cat "$OKLOG")" "vm.nr_hugepages"
unset OKLOG
unset -f okrun
rm -rf "$OKSB"
unset OKSB

# shellcheck source=tests/stack/test-appliance-os-update.sh
source "$HERE/test-appliance-os-update.sh"

# shellcheck source=tests/stack/test-appliance-os-update-verbs.sh
source "$HERE/test-appliance-os-update-verbs.sh"

# --- os/rauc stale-tarball guard (verify_tarball_commit in populate-slot.sh). A present-but-stale
# os/build/pithead-root.tar looks identical to a fresh one to `[ -s ]` — a bench deploy once
# bundled a leftover tarball from a previous session and every downstream check came up green with
# the old code running. The guard extracts the tarball's own opt/pithead/BUILD_COMMIT stamp and
# compares it to the working tree, proven here with a fabricated fixture tarball (no image build).
echo "== unit: os/rauc stale-tarball guard =="
VTC_TMP=$(mktemp -d)
# The same commit+dirty-suffix computation verify_tarball_commit does, so the "match" fixture is
# honest about the state of THIS working tree (it may itself be dirty mid-change).
VTC_HEAD_SHA=$(cd "$ROOT" && git rev-parse HEAD)
VTC_HEAD="$VTC_HEAD_SHA"
(cd "$ROOT" && git diff --quiet) || VTC_HEAD="${VTC_HEAD_SHA}-dirty"

# Build a fixture tarball with the single member the guard reads: opt/pithead/BUILD_COMMIT.
# $2=NONE fabricates a tarball with the directory but no stamp file (an old/broken build).
mk_vtc_fixture() { # $1=out-path $2=stamp-content|NONE
    local d
    d=$(mktemp -d)
    mkdir -p "$d/opt/pithead"
    [ "$2" = NONE ] || printf '%s\n' "$2" >"$d/opt/pithead/BUILD_COMMIT"
    tar -cf "$1" -C "$d" opt
    rm -rf "$d"
}
vtc() { # $1=tarball -> prints "rc=<n>"; stderr goes to $VTC_TMP/err
    (
        cd "$ROOT" || exit
        # shellcheck disable=SC1090
        . os/rauc/populate-slot.sh
        set +e
        verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}

mk_vtc_fixture "$VTC_TMP/fresh.tar" "$VTC_HEAD"
assert_eq "a tarball stamped with the current HEAD is accepted" "$(vtc "$VTC_TMP/fresh.tar")" "rc=0"

mk_vtc_fixture "$VTC_TMP/stale.tar" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
out=$(vtc "$VTC_TMP/stale.tar")
assert_eq "a tarball stamped with a foreign commit is refused" "$out" "rc=2"
err="$(cat "$VTC_TMP/err")"
assert_contains "the refusal names the tarball's stamped commit" "$err" "deadbeefcafef00dfeedfacebeeff00ddeadbeef"
assert_contains "the refusal names the working tree's commit" "$err" "$VTC_HEAD_SHA"
assert_contains "the refusal points at the override env var" "$err" "PITHEAD_STALE_TARBALL_OK"

out=$(PITHEAD_STALE_TARBALL_OK=1 vtc "$VTC_TMP/stale.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides a stale-commit refusal" "$out" "rc=0"

mk_vtc_fixture "$VTC_TMP/nostamp.tar" NONE
out=$(vtc "$VTC_TMP/nostamp.tar")
assert_eq "a tarball with no BUILD_COMMIT stamp is refused" "$out" "rc=2"
assert_contains "the refusal says no stamp was found" "$(cat "$VTC_TMP/err")" "no BUILD_COMMIT stamp"

# A checkout git cannot read (sudo on another user's tree, once the SUDO_USER fallback also
# fails) must refuse rather than silently skip the freshness check — fail closed, with the
# same explicit escape. Run from a non-repo dir with the fallback neutralized to simulate it.
vtc_norepo() { # $1=tarball -> prints "rc=<n>"; stderr to $VTC_TMP/err
    (
        cd "$VTC_TMP" || exit
        # shellcheck disable=SC1091
        . "$ROOT/os/rauc/populate-slot.sh"
        set +e
        SUDO_USER="" GIT_DIR="$VTC_TMP/no-such-repo" verify_tarball_commit "$1" 2>"$VTC_TMP/err"
        echo "rc=$?"
    )
}
out=$(vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "an unreadable working tree refuses (fail closed, never skip)" "$out" "rc=2"
assert_contains "the refusal explains git could not be read" "$(cat "$VTC_TMP/err")" "cannot read the working tree's commit"
out=$(PITHEAD_STALE_TARBALL_OK=1 vtc_norepo "$VTC_TMP/fresh.tar")
assert_eq "PITHEAD_STALE_TARBALL_OK=1 overrides the unreadable-tree refusal" "$out" "rc=0"

rm -rf "$VTC_TMP"
unset -f mk_vtc_fixture vtc vtc_norepo
unset VTC_TMP VTC_HEAD_SHA VTC_HEAD

# --- mkbundle metadata validation (fails fast, before the multi-minute image build) ---
echo "== unit: mkbundle compatibility-metadata validation =="
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=maybe bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "PITHEAD_DATA_MIGRATION must be true/false" "$?" "2"
assert_contains "the message names the field" "$out" "PITHEAD_DATA_MIGRATION"
out=$(cd "$ROOT" && PITHEAD_DATA_MIGRATION=true bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "data_migration=true without a floor is refused" "$?" "2"
assert_contains "the message asks for the migration floor" "$out" "PITHEAD_MIN_OS_VERSION"
out=$(cd "$ROOT" && PITHEAD_MIN_OS_VERSION=1.2 bash os/rauc/mkbundle.sh /dev/null 2>&1)
assert_rc "a non-semver floor is refused" "$?" "2"
assert_contains "the message names the floor field" "$out" "PITHEAD_MIN_OS_VERSION"

# ---------------------------------------------------------------------------
# os/rauc signing-material guard (resolve_signing_material in populate-slot.sh). A release build
# must name the signing key; only an explicitly-marked --dev build auto-generates a throwaway. The
# refuse logic is proven here at the shell-unit tier — sourced and called directly, no docker/loop
# image build. The guard is the safety fix: a dev cert must never become the fleet's update trust
# root because a build host happened to have one lying around.
RSM="$ROOT/os/rauc/populate-slot.sh"
RSMTMP=$(mktemp -d)
# Run the resolver in an isolated cwd (it writes os/rauc/certs/ relative to $PWD). $1=dev(0/1),
# $2=where to send stderr. Prints: rc=<n> cert=<..> key=<..> keyring=<..>
rsm() {
    local dev="$1" errto="$2" d
    d=$(mktemp -d)
    (
        cd "$d" || exit
        # shellcheck disable=SC1090
        . "$RSM"
        set +e
        resolve_signing_material "$dev" 2>"$errto"
        printf ' rc=%s cert=%s key=%s keyring=%s\n' "$?" "${RAUC_CERT:-}" "${RAUC_KEY:-}" "${RAUC_KEYRING:-}"
    )
    rm -rf "$d"
}
rsm_field() { echo "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"; }

# Release build (dev=0), no key named -> refuses, non-zero, names the env vars and --dev.
res=$(
    unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "release build with no signing key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"
assert_contains "refusal names the release key env vars" "$(cat "$RSMTMP/err")" "PITHEAD_RAUC_CERT"
assert_contains "refusal points at --dev for a throwaway key" "$(cat "$RSMTMP/err")" "--dev"

# Explicit key (dev=0) -> accepted; keyring defaults to the signing cert. Content is irrelevant to
# the guard (it checks readability, not validity), so dummy files exercise the branch openssl-free.
printf 'cert\n' >"$RSMTMP/rel-cert.pem"
printf 'key\n' >"$RSMTMP/rel-key.pem"
res=$(
    PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem"
    export PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY
    unset PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "explicit release key is accepted (rc 0)" "$(rsm_field "$res" rc)" "0"
assert_eq "the named cert is used for signing" "$(rsm_field "$res" cert)" "$RSMTMP/rel-cert.pem"
assert_eq "keyring defaults to the signing cert" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-cert.pem"

# Explicit keyring overrides the baked trust anchor (root+leaf: root baked, leaf signs).
printf 'root\n' >"$RSMTMP/rel-root.pem"
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem" PITHEAD_RAUC_KEY="$RSMTMP/rel-key.pem" PITHEAD_RAUC_KEYRING="$RSMTMP/rel-root.pem"
    rsm 0 "$RSMTMP/err"
)
assert_eq "PITHEAD_RAUC_KEYRING is what gets baked" "$(rsm_field "$res" keyring)" "$RSMTMP/rel-root.pem"

# A cert with no matching key is rejected — both halves are required.
res=$(
    export PITHEAD_RAUC_CERT="$RSMTMP/rel-cert.pem"
    unset PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
    rsm 0 "$RSMTMP/err"
)
assert_eq "cert without key refuses (rc 2)" "$(rsm_field "$res" rc)" "2"

# Dev build (dev=1) still auto-generates a throwaway — the local/bench loop is preserved.
if command -v openssl >/dev/null 2>&1; then
    res=$(
        unset PITHEAD_RAUC_CERT PITHEAD_RAUC_KEY PITHEAD_RAUC_KEYRING
        rsm 1 "$RSMTMP/err"
    )
    assert_eq "dev build auto-generates and succeeds (rc 0)" "$(rsm_field "$res" rc)" "0"
    assert_contains "dev key lands in os/rauc/certs" "$(rsm_field "$res" key)" "os/rauc/certs/key.pem"
else
    ok "dev auto-gen skipped (no openssl on this host)"
fi
rm -rf "$RSMTMP"
unset RSM RSMTMP
unset -f rsm rsm_field

echo "== black-box: config-reset clears config, keeps the chains (appliance two-tier reset) =="
# A throwaway deployment: config.json + rendered files + data dirs. docker is a noop; the reboot is
# a stub that just records that it fired, so we assert the reboot without rebooting the runner.
CR="$SANDBOX/config-reset"
mkdir -p "$CR/bin" "$CR/data/monero" "$CR/data/tor"
cp "$STACK" "$CR/pithead"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/docker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CR/bin/sudo"
chmod +x "$CR/bin/docker" "$CR/bin/sudo"
seed_cr() {
    printf '{ "monero":{"mode":"local","wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"} }\n' "$WALLET" >"$CR/config.json"
    printf 'DEPLOYMENT_COMPLETED=true\nHOST_IP=box.lan\n' >"$CR/.env"
    : >"$CR/Caddyfile"
    : >"$CR/data/monero/blockchain" # stand-in for the synced chain
    : >"$CR/data/tor/hostname"      # stand-in for the onion key material
}
# Wrong confirmation word: aborts, changes nothing.
seed_cr
out=$(cd "$CR" && printf 'nope\n' | PITHEAD_APPLIANCE=0 PATH="$CR/bin:$PATH" ./pithead config-reset 2>&1) || true
assert_contains "config-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted config-reset keeps config.json" "$([ -f "$CR/config.json" ] && echo yes)" "yes"
# -y off the appliance: config + rendered files go, data dirs stay, no reboot — just the hint.
seed_cr
rebooted="$CR/.rebooted"
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=0 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_rc "config-reset succeeds" "$?" "0"
assert_eq "config-reset removes config.json" "$([ -f "$CR/config.json" ] || echo gone)" "gone"
assert_eq "config-reset removes .env" "$([ -f "$CR/.env" ] || echo gone)" "gone"
assert_eq "config-reset removes Caddyfile" "$([ -f "$CR/Caddyfile" ] || echo gone)" "gone"
assert_eq "config-reset KEEPS the monero chain" "$([ -f "$CR/data/monero/blockchain" ] && echo kept)" "kept"
assert_eq "config-reset KEEPS the Tor onion key" "$([ -f "$CR/data/tor/hostname" ] && echo kept)" "kept"
assert_eq "config-reset off the appliance does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"
assert_contains "config-reset hints how to reconfigure" "$out" "firstboot-wizard"
# On the appliance: same wipe, but it reboots into first-boot setup.
seed_cr
rm -f "$rebooted"
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_eq "config-reset on the appliance reboots into firstboot" "$([ -f "$rebooted" ] && echo yes)" "yes"
# Already unprovisioned: nothing to reset.
out=$(cd "$CR" && PITHEAD_APPLIANCE=1 PATH="$CR/bin:$PATH" ./pithead config-reset -y 2>&1) || true
assert_contains "config-reset refuses when config.json is absent" "$out" "already unprovisioned"
out=$(cd "$CR" && PATH="$CR/bin:$PATH" ./pithead config-reset --bogus 2>&1) || true
assert_contains "config-reset rejects unknown options" "$out" "Unknown option"

echo "== black-box: factory-reset arms the boot-time wipe, appliance-only (two-tier reset) =="
FR="$SANDBOX/factory-reset"
mkdir -p "$FR/bin" "$FR/esp"
cp "$STACK" "$FR/pithead"
marker="$FR/esp/pithead-reset"
rebooted="$FR/.rebooted"
# Off the appliance: refuse, arm nothing, point at uninstall.
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=0 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset off the appliance refuses" "$out" "only runs on the appliance"
assert_eq "refused factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# Wrong confirmation word on the appliance: aborts, arms nothing.
out=$(cd "$FR" && printf 'nope\n' | PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset 2>&1) || true
assert_contains "factory-reset aborts on the wrong confirm word" "$out" "Aborted"
assert_eq "aborted factory-reset arms no marker" "$([ -f "$marker" ] || echo none)" "none"
# -y on the appliance: BATTERY — the marker is written AND the reboot fires (both, or the wipe
# either never runs or never reaches the boot that runs it).
rm -f "$marker" "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1)
assert_rc "factory-reset succeeds" "$?" "0"
assert_eq "factory-reset arms the ESP marker AND reboots" \
    "$([ -f "$marker" ] && [ -f "$rebooted" ] && echo armed-and-rebooting)" "armed-and-rebooting"
# ESP not writable: refuse loudly, reboot nothing (a box that quietly did nothing is the trap).
rm -f "$rebooted"
out=$(cd "$FR" && PITHEAD_APPLIANCE=1 PITHEAD_PRESEED_DIR="$FR/no-such-esp" PITHEAD_REBOOT_CMD="touch $rebooted" PATH="$FR/bin:$PATH" ./pithead factory-reset -y 2>&1) || true
assert_contains "factory-reset refuses when the ESP marker cannot be written" "$out" "Could not arm"
assert_eq "unarmable factory-reset does not reboot" "$([ -f "$rebooted" ] || echo no)" "no"

echo "== unit: a boot that fails its health gate reboots itself, once (#1065) =="
# The A/B design's headline promise is that a bad update reverts itself, and for the likeliest bad
# update — one that boots cleanly with a dead stack — it did not: pithead-boot left the slot
# uncommitted and exited, and the fallback is a GRUB decision GRUB does not get to make until
# something reboots. So the box sat on the broken slot with the stack down until a human pulled the
# power, while two operator docs promised otherwise.
#
# Bounded is the load-bearing half. A fault on /data survives the fallback, so both slots fail the
# same way; a machine that reboot-loops can never be looked at. And if the counter cannot be
# written the machine must NOT reboot — an unbounded loop is the one outcome worse than a stranded
# box, so the failure to persist has to fail SAFE, not open.
#
# MUTATION PROOF: drop the `[ "$n" -ge 2 ]` bound and the second-failure assertion goes red; make
# the unwritable-counter branch reboot anyway and the fail-safe assertion goes red; drop the
# rm in boot_gate_passed and the cleared-on-success assertion goes red.
BG="$SANDBOX/boot-gate"
mkdir -p "$BG"
# shellcheck disable=SC1090  # overlay path is dynamic by design
bg_run() { # <cwd> — one fail_boot in a sandbox, printing "<reboots> <counter> <stderr>"
    (
        cd "$1" 2>/dev/null || exit 1
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
    )
}
rm -f "$BG"/rebooted.*
bg_out1=$(bg_run "$BG")
bg_rebooted1=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the first failed health gate reboots the machine" "$bg_rebooted1" "1"
assert_eq "and records the attempt on /data" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "1"
assert_contains "saying why, on the console" "$bg_out1" "falls back to the previous slot"

rm -f "$BG"/rebooted.*
bg_out2=$(bg_run "$BG")
bg_rebooted2=$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "the fallback slot failing the same way does NOT reboot again" "$bg_rebooted2" "0"
assert_eq "the attempt is still counted" "$(cat "$BG/.boot-gate-failures" 2>/dev/null)" "2"
assert_contains "and the console says the fault is not the slot" "$bg_out2" "the fault is not the slot"

# A healthy boot clears the counter, or one transient failure months ago would spend the machine's
# single rollback attempt on the update that actually needs it.
(
    cd "$BG" || exit 1
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    boot_gate_passed
)
assert_eq "a boot that commits clears the counter" "$([ -f "$BG/.boot-gate-failures" ] && echo present || echo gone)" "gone"

# Unwritable counter: the cwd is deleted out from under it, which makes the relative write fail for
# root too — a chmod would not, and this suite runs as both.
BGX="$SANDBOX/boot-gate-unwritable"
mkdir -p "$BGX"
rm -f "$BG"/rebooted.*
bg_out3=$(
    cd "$BGX" && rmdir "$BGX"
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    PITHEAD_REBOOT_CMD="touch $BG/rebooted.$$" fail_boot "the stack never became healthy (serving + doctor)" 2>&1
)
assert_eq "a counter it cannot write means it does NOT reboot" "$(ls "$BG"/rebooted.* 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_contains "and it says a reboot it cannot count is a reboot loop" "$bg_out3" "a reboot it cannot count is a reboot loop"
rm -f "$BG"/rebooted.*

# Every exit that leaves the slot uncommitted goes through the helper — a bare `exit 1` on any of
# them is the original defect back on that path alone. The rig leg's two and the coordinator's
# render, up and health gate are all of them.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
bg_bare=$(grep -cE '^[[:space:]]*(\./pithead (render|up)|timeout 1800 \./pithead local-miner).*\|\| exit 1' "$BOOTSCRIPT" || true)
assert_eq "no boot-failure path exits without arming the fallback" "$bg_bare" "0"
echo "== unit: the appliance battery's release gate does not lie about what it ran (#1064) =="
# Harness wiring, asserted here because the harness itself only runs on the KVM bench. Both halves
# are the same defect: a gate that reports success without having run. `--phase all` executed five
# of eight phases while the release checklist said it ran everything, so every cut skipped the
# power cuts, the corrupt-bundle refusal, the factory reset, the wedged-/data recovery and the
# media channel; and verify-image's stale-artifact comparison was switched off in the ONE caller
# that is not a human typing a command. MUTATION PROOF: drop a phase from the `all` arm, or drop
# the PITHEAD_EXPECT_COMMIT prefix, and the matching assertion goes red.
OSH="$(cat "$ROOT/tests/os/run.sh")"
osh_all="$(printf '%s' "$OSH" | sed -n '/^all)/,/^    ;;/p')"
for ph in boot update install provision rig media fault reset; do
    assert_contains "--phase all runs phase_$ph" "$osh_all" "phase_$ph"
done
assert_contains "the battery's own build pins the commit verify-image checks against" "$OSH" \
    'PITHEAD_EXPECT_COMMIT="$expect" tests/os/verify-image.sh'
VIS="$(cat "$ROOT/tests/os/verify-image.sh")"
# Wiring the guard on is only half of it: the two ends have to speak the same shape. build-image.sh
# stamps `git rev-parse HEAD` — the FULL sha — and the harness first handed over `--short`, so the
# equality check failed EVERY harness build. A guard that refuses everything is the same lie as one
# that refuses nothing, pointed the other way. Bench-proven on the KVM image; asserted here because
# verify-image needs a loop device and root, which tier-1 has neither of.
assert_contains "the harness hands over the full sha build-image.sh stamps" "$OSH" \
    'expect="$(git rev-parse HEAD 2>/dev/null || true)"'
assert_not_contains "the harness does not hand over a short sha the stamp never equals" "$OSH" \
    'rev-parse --short HEAD'
assert_contains "the expected-commit check matches on a prefix, so a short sha still verifies" "$VIS" \
    'case "$BUILT" in "$PITHEAD_EXPECT_COMMIT"*)'
assert_contains "a skipped check is counted, not silent" "$VIS" "SKIP=\$((SKIP + 1))"
assert_contains "skipped checks refuse to report a verified image" "$VIS" "were SKIPPED, so this is not a verified image"
unset OSH osh_all VIS

echo "== unit: pithead-data-reset decides reformat-vs-skip fail-safe (wedged-/data recovery) =="
# Source the boot script (functions only — its main is guarded) and drive data_reset_decision with
# stubbed repair tools, in a subshell so its set -u / defs never leak into the suite.
#
# The stubs model each tool's REAL contract, because the old ones could not fail (#1086): `fsck` was
# `exit 0` and the mount stub succeeded on its second call whatever had run in between, so "fsck
# repairs the mount -> skip" was true of the stub and said nothing about the product. Here a
# partition carries a damage level, each tool repairs only the damage it can, and mount succeeds only
# once something actually repaired it — so the assertions below are about the escalation, not the
# harness. REPAIRABLE_BY names the tool that fixes this partition: preen, e2fsck, backup, or none.
DR="$SANDBOX/data-reset"
mkdir -p "$DR/bin"
cat >"$DR/bin/mount" <<'EOF'
#!/usr/bin/env bash
# Mounts when the partition was never damaged, or once the repair log says the right tool ran.
[ "${REPAIRABLE_BY:-none}" = "healthy" ] && exit 0
grep -qx "repaired" "${REPAIR_STATE:-/dev/null}" 2>/dev/null && exit 0
exit 1
EOF
# fsck -p: preen repairs ONLY what needs no operator decision and refuses the rest by definition —
# rc 8 with a "try an alternate superblock" hint is exactly what it does to the damage this issue is
# about (#1062). It must never be able to repair a partition the real one could not.
cat >"$DR/bin/fsck" <<'EOF'
#!/usr/bin/env bash
echo "fsck $*" >>"${REPAIR_LOG:-/dev/null}"
[ "${REPAIRABLE_BY:-none}" = "preen" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; }
exit 8
EOF
# e2fsck -y: repairs what preen refused. With -b it rebuilds the primary superblock from a backup —
# the only thing that saves a partition whose superblock is gone.
cat >"$DR/bin/e2fsck" <<'EOF'
#!/usr/bin/env bash
echo "e2fsck $*" >>"${REPAIR_LOG:-/dev/null}"
case " $* " in
*" -b "*) [ "${REPAIRABLE_BY:-none}" = "backup" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
*) [ "${REPAIRABLE_BY:-none}" = "e2fsck" ] && { echo repaired >>"${REPAIR_STATE:-/dev/null}"; exit 1; } ;;
esac
exit 8
EOF
# mke2fs -n computes the layout and writes nothing; this is the shape its backup list prints in.
cat >"$DR/bin/mke2fs" <<'EOF'
#!/usr/bin/env bash
echo "mke2fs $*" >>"${REPAIR_LOG:-/dev/null}"
printf 'Creating filesystem with 131072 4k blocks\nSuperblock backups stored on blocks:\n\t32768, 98304, 163840\n'
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$DR/bin/umount"
chmod +x "$DR/bin/mount" "$DR/bin/umount" "$DR/bin/fsck" "$DR/bin/e2fsck" "$DR/bin/mke2fs"
decide() { # $1 marker-file, $2 which tool can repair this partition (healthy|preen|e2fsck|backup|none)
    (
        export PATH="$DR/bin:$PATH"
        export REPAIRABLE_BY="$2" # exported: the stubs run as child processes
        export REPAIR_STATE="$DR/state" REPAIR_LOG="$DR/log"
        : >"$REPAIR_STATE"
        : >"$REPAIR_LOG"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        data_reset_decision "/dev/fake-data" "$1"
    )
}
touch "$DR/marker-present"
assert_eq "marker present -> reformat-requested (even if /data would mount)" "$(decide "$DR/marker-present" healthy)" "reformat-requested"
assert_eq "no marker + /data mounts clean -> skip (fail-safe: never touch a healthy partition)" "$(decide "$DR/no-marker" healthy)" "skip"
assert_eq "no marker + preen repairs the mount -> skip (a dirty filesystem is not a lost one)" "$(decide "$DR/no-marker" preen)" "skip"
# The defect (#1062): `fsck -p` refuses precisely the damage a full e2fsck recovers, so stopping
# there sent a salvageable partition — wallets, onion keys, both chains — to mkfs.ext4 -F.
assert_eq "no marker + only a full e2fsck can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" e2fsck)" "skip"
# The textbook case the issue reproduced: a corrupt primary superblock, recoverable only from a
# backup, which `fsck -p` reports by printing the very command that would have saved it.
assert_eq "no marker + only a backup superblock can repair it -> skip, NOT a wipe" "$(decide "$DR/no-marker" backup)" "skip"
assert_eq "no marker + no repair mounts it -> reformat-wedged (the box would be bricked otherwise)" "$(decide "$DR/no-marker" none)" "reformat-wedged"
# Escalation order: least destructive first, and every rung tried before the partition is erased.
decide "$DR/no-marker" none >/dev/null
dr_log="$(cat "$DR/log")"
assert_contains "preen runs first" "$dr_log" "fsck -p -t ext4 /dev/fake-data"
assert_contains "then a full e2fsck" "$dr_log" "e2fsck -y /dev/fake-data"
assert_contains "then the backup superblocks mke2fs -n reports" "$dr_log" "e2fsck -y -b 32768 /dev/fake-data"
assert_contains "the backup offsets are computed, never hardcoded" "$dr_log" "mke2fs -n /dev/fake-data"
assert_eq "the backup retry is bounded, so a destroyed filesystem cannot grind forever" "$(grep -c 'e2fsck -y -b' "$DR/log")" "2"
# A partition the FIRST tool fixes must not be handed to the later, heavier ones.
decide "$DR/no-marker" preen >/dev/null
assert_not_contains "a preen-repaired partition never reaches e2fsck" "$(cat "$DR/log")" "e2fsck"

echo "== unit: pithead-data-reset leaves evidence that /data was wiped (#1062) =="
# A reformatted box and a factory-fresh one both boot into the wizard, so without this the operator
# reads a wipe as "it reset itself" and never learns the disk may have been salvageable. The ESP is
# the only writable thing a /data reformat leaves standing.
DRW="$SANDBOX/data-reset-wipe"
mkdir -p "$DRW/esp"
(
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    record_wipe "$DRW/esp" "unrecoverable /data reinitialized — everything on it was lost"
    record_wipe "" "an ESP that would not mount must never block the recovery"
)
assert_eq "the wipe is recorded on the ESP" "$([ -f "$DRW/esp/pithead-data-wiped" ] && echo present || echo absent)" "present"
assert_contains "the record says what was lost" "$(cat "$DRW/esp/pithead-data-wiped")" "everything on it was lost"
assert_contains "the record is timestamped" "$(cat "$DRW/esp/pithead-data-wiped")" "$(date -u +%Y-)"
assert_eq "one wipe, one line" "$(wc -l <"$DRW/esp/pithead-data-wiped" | tr -d ' ')" "1"

echo "== unit: pithead-data-reset boot_disk_part resolves by PARTLABEL on the boot disk (#926) =="
# Stubbed findmnt + lsblk (the same PATH-stub shape pithead's own prefill_from_previous_install
# test uses for lsblk). findmnt always answers the fake root partition; lsblk branches on its
# first flag: -no PKNAME returns the parent disk name, -lnpo NAME,PARTLABEL lists that disk's
# partitions with their labels — never a bare/unscoped label lookup.
DRP="$SANDBOX/data-reset-partition"
mkdir -p "$DRP/bin"
printf '#!/usr/bin/env bash\necho "/dev/vda2"\n' >"$DRP/bin/findmnt"
# The stub's labels are DERIVED from the real build inputs, not hand-typed: mkimage's sgdisk line
# names the ESP, repart.d names the data partition. If either file ever changes its casing or
# name, this test fails instead of green-lighting a lookup that no longer matches reality.
DRP_ESP_LABEL=$(grep -oE '\-c 1:[a-zA-Z]+' "$ROOT/os/rauc/mkimage.sh" | cut -d: -f2)
DRP_DATA_LABEL=$(grep -oE '^Label=.*' "$ROOT/os/rootfs/repart.d/40-data.conf" | cut -d= -f2)
assert_eq "the ESP label mkimage bakes is the one data-reset looks up" "$DRP_ESP_LABEL" "esp"
assert_eq "the data label repart declares is the one data-reset looks up" "$DRP_DATA_LABEL" "data"
cat >"$DRP/bin/lsblk" <<EOF
#!/usr/bin/env bash
case "\$1" in
-no) echo "vda" ;;
-lnpo) printf '/dev/vda1 ${DRP_ESP_LABEL}\n/dev/vda4 ${DRP_DATA_LABEL}\n' ;;
esac
EOF
chmod +x "$DRP/bin/findmnt" "$DRP/bin/lsblk"
resolve() { # $1: partlabel
    (
        export PATH="$DRP/bin:$PATH"
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-data-reset"
        boot_disk_part "$1"
    )
}
assert_eq "boot_disk_part data -> the data partition on the boot disk" "$(resolve data)" "/dev/vda4"
assert_eq "boot_disk_part esp -> the ESP on the boot disk" "$(resolve esp)" "/dev/vda1"
assert_eq "boot_disk_part on a label the boot disk doesn't carry -> empty (first boot, pre-repart)" \
    "$(resolve nosuchlabel)" ""

# A container/unexpected root (mountinfo source isn't /dev/*) must fail closed, not guess.
printf '#!/usr/bin/env bash\necho "overlay"\n' >"$DRP/bin/findmnt"
out=$(
    export PATH="$DRP/bin:$PATH"
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-data-reset"
    boot_disk_part data
)
rc=$?
assert_rc "boot_disk_part on a non-/dev root -> rc 1" "$rc" "1"
assert_eq "boot_disk_part on a non-/dev root -> prints nothing" "$out" ""

echo "== unit: pithead-machine-id — restore writes THROUGH /etc/machine-id, never unmounts it =="
# The regression this pins: an earlier version unmounted /etc/machine-id before writing, which on
# a read-only-root A/B slot exposed the lower image and the write failed — leaving an empty id and
# a dead DHCP lease. The write must land in the (writable) target as-is. ETC + ID_FILE are
# overridable so this runs without touching the real /etc.
MID="$SANDBOX/machine-id"
mkdir -p "$MID"
# 1) Restore: /data holds an id, /etc has a different (systemd-transient) one -> /etc takes /data's.
printf 'fa85bfc69f0b451d95bbacf897e431ce\n' >"$MID/data-id"
printf 'ffffffffffffffffffffffffffffffff\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "restore overwrites /etc/machine-id with the persisted id" "$(cat "$MID/etc-id")" "fa85bfc69f0b451d95bbacf897e431ce"
assert_eq "restore leaves the persisted id unchanged" "$(cat "$MID/data-id")" "fa85bfc69f0b451d95bbacf897e431ce"
# 2) Adopt: /data has none yet -> adopt this boot's /etc id and persist it read-only.
rm -f "$MID/data-id"
printf 'abc0000000000000000000000000def0\n' >"$MID/etc-id"
(
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1
assert_eq "adopt persists this boot's id to /data" "$(cat "$MID/data-id" 2>/dev/null)" "abc0000000000000000000000000def0"
# 3) Nothing to adopt: /etc empty AND /data empty -> refuse loudly, persist nothing. A newline
# persisted here would satisfy [ -s ] forever and every later boot would restore garbage.
rm -f "$MID/data-id"
: >"$MID/etc-id"
if (
    export PITHEAD_MACHINE_ID_FILE="$MID/data-id" PITHEAD_MACHINE_ID_ETC="$MID/etc-id"
    sh "$ROOT/os/overlay/pithead-machine-id"
) >/dev/null 2>&1; then
    bad "empty-adopt: script must refuse when there is no id anywhere"
else
    ok "empty-adopt: refused (non-zero exit)"
fi
assert_eq "empty-adopt persists nothing" "$(cat "$MID/data-id" 2>/dev/null || echo absent)" "absent"

echo "== unit: pithead-hugepages — the RandomX reservation fits the machine's RAM (#977) =="
# The appliance bakes a 6 GiB hugepages reservation sized for the supported 16 GB machine; the
# boot-time sizing shrinks it LOUDLY on smaller RAM. The tier function is pure over a
# meminfo-shaped file, so every branch is provable here; the only thing left for the battery is
# that on the 16 GiB harness VM the sizing is a no-op (full pool intact, no marker).
HG="$SANDBOX/hugepages"
mkdir -p "$HG"
printf 'MemTotal:       16250000 kB\nMemFree:        16000000 kB\n' >"$HG/meminfo-16g"
printf 'MemTotal:       8050000 kB\n' >"$HG/meminfo-8g"
printf 'MemTotal:       4000000 kB\n' >"$HG/meminfo-4g"
printf 'MemTotal:       15728640 kB\n' >"$HG/meminfo-at-floor"
printf 'MemTotal:       15728639 kB\n' >"$HG/meminfo-under-floor"
printf 'MemTotal:       banana kB\n' >"$HG/meminfo-garbage"
printf 'MemFree:        123 kB\n' >"$HG/meminfo-no-total"

hg_want() {
    (
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-hugepages"
        hugepages_want "$1"
    )
}
assert_eq "16 GiB machine keeps the full 3072-page pool" "$(hg_want "$HG/meminfo-16g")" "3072"
assert_eq "exactly the 15 GiB floor keeps the full pool (a real 16 GB box clears it)" "$(hg_want "$HG/meminfo-at-floor")" "3072"
assert_eq "just under the floor reduces to 2560 pages (both RandomX datasets still fit)" "$(hg_want "$HG/meminfo-under-floor")" "2560"
assert_eq "8 GiB machine reduces to 2560 pages" "$(hg_want "$HG/meminfo-8g")" "2560"
assert_eq "4 GiB machine releases the reservation (0 pages)" "$(hg_want "$HG/meminfo-4g")" "0"
assert_eq "garbage MemTotal keeps the full baked pool (degrade only on evidence)" "$(hg_want "$HG/meminfo-garbage")" "3072"
assert_eq "missing MemTotal keeps the full baked pool" "$(hg_want "$HG/meminfo-no-total")" "3072"

# ONE definition, three copies: the overlay script's full value must match the CLI's
# PITHEAD_HUGEPAGES and the rootfs's baked sysctl line — drift here re-opens the silent floor.
cli_pages=$(run_sourced "$SANDBOX" eval 'echo "$PITHEAD_HUGEPAGES"')
overlay_pages=$(
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    echo "$FULL_PAGES"
)
assert_eq "overlay full pool matches the CLI's PITHEAD_HUGEPAGES" "$overlay_pages" "$cli_pages"
if grep -q "vm.nr_hugepages=$cli_pages" "$ROOT/os/rootfs/Dockerfile"; then
    ok "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)"
else
    bad "rootfs bakes the same sysctl value the CLI and overlay declare ($cli_pages)" \
        "no vm.nr_hugepages=$cli_pages line in os/rootfs/Dockerfile"
fi

# main, degraded tier: shrinks the pool file, leaves the plain-words marker doctor reads.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-8g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "low-RAM boot shrinks the pool to the reduced target" "$(cat "$HG/nr_hugepages")" "2560"
assert_contains "low-RAM boot announces the degrade on the console/journal" "$out" "below the supported 16 GB"
assert_contains "degraded marker names the supported floor in plain words" "$(cat "$HG/marker" 2>/dev/null)" "16 GB"
assert_eq "marker records the chosen page count — the authority later writers honour" \
    "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "2560"
assert_not_contains "degrade message carries no issue numbers (operator text)" "$out" "#9"

# main, too-small tier: releases the pool entirely and says the stack will not run.
printf '3072\n' >"$HG/nr_hugepages"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-4g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "far-below-floor boot releases the reservation" "$(cat "$HG/nr_hugepages")" "0"
assert_contains "far-below-floor boot says the stack will not run reliably" "$out" "will not run reliably"
assert_eq "released marker records zero pages" "$(sed -n 's/^pages=//p' "$HG/marker" 2>/dev/null)" "0"

# main, supported tier: a strict no-op — pool untouched, no marker, nothing said.
printf '3072\n' >"$HG/nr_hugepages"
rm -f "$HG/marker"
out=$(
    export PITHEAD_MEMINFO="$HG/meminfo-16g" PITHEAD_NR_HUGEPAGES_FILE="$HG/nr_hugepages" \
        PITHEAD_HUGEPAGES_MARKER="$HG/marker"
    # shellcheck disable=SC1091
    source "$ROOT/os/overlay/pithead-hugepages"
    main
)
assert_eq "supported machine leaves the baked pool alone" "$(cat "$HG/nr_hugepages")" "3072"
assert_eq "supported machine writes no degraded marker" "$(cat "$HG/marker" 2>/dev/null || echo absent)" "absent"
assert_eq "supported machine says nothing" "$out" ""

# doctor reads the marker as a WARN — never FAIL, so the A/B commit gate (which takes doctor's
# exit code) still commits a degraded-but-serving box. The words on line one are for the human;
# the pages= record under them is for the writers, and doctor must not leak it.
printf 'This machine has 7.7 GiB of RAM - below the supported 16 GB. Reduced reservation.\npages=2560\n' >"$HG/marker"
out=$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" check_hugepages_degraded 2>&1)
assert_contains "doctor surfaces the degraded-hugepages message as a WARN" "$out" "WARN"
assert_contains "doctor repeats the boot-time message verbatim" "$out" "below the supported 16 GB"
assert_not_contains "doctor never FAILs on the degrade (commit gate must still pass)" "$out" "FAIL"
assert_not_contains "doctor repeats the words, not the machine record" "$out" "pages=2560"
rc=$(
    PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" check_hugepages_degraded >/dev/null 2>&1
    echo $?
)
assert_rc "no marker, no verdict (rc 0, silent off the appliance)" "$rc" "0"

# The decision reader (hugepages_decision_pages) can only ever LOWER the budget: a corrupt
# record at or above the full pool reads as the full pool, and no marker means the full budget
# — so DIY hosts and healthy appliances keep the exact pre-#977 behavior.
printf 'words\npages=9999\n' >"$HG/marker"
assert_eq "a record above the budget is capped at the budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"
assert_eq "no marker reads as the full budget" \
    "$(PITHEAD_HUGEPAGES_MARKER="$HG/absent-marker" run_sourced "$SANDBOX" hugepages_decision_pages)" "3072"

echo "== unit: hugepages_boot_verdict — a bare boot can tell ran-and-no-op from never-ran (#1212) =="
# tests/os/run.sh's phase_boot cannot be driven from here (it needs a real KVM guest), but the
# verdict it now checks is pure text-matching over two already-observed strings
# (HugePages_Total, `systemctl is-active` output) — #1212 pulled it into
# tests/os/hugepages-boot-verdict.sh for exactly this reason: the discrimination the issue asked
# for is provable with fixtures, without a bench boot. The case that matters is the first pair
# below: the SAME HugePages_Total (3072 — the baked sysctl reserves it whether the unit ran or
# not) must verdict differently once the unit's own record disagrees.
# Mutation run: drop the is-active check and fall back to judging HugePages_Total alone -> the
# "never ran" assertion flips from fail to pass, silently reintroducing #1212.
hbv() { # <hugepages-total> <is-active-output> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/hugepages-boot-verdict.sh"
        hugepages_boot_verdict "$1" "$2"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "ran + full pool: passes" \
    "$(hbv 3072 active)" "0 hugepages sizing unit ran this boot and left the full pool intact (3072 pages)"
assert_eq "never ran + the SAME full pool: fails — the #1212 case a pool-only check missed" \
    "$(hbv 3072 inactive)" "1 hugepages sizing unit did not run this boot (is-active: inactive) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the pool is short: fails" \
    "$(hbv 2560 active)" "1 hugepages sizing unit ran but the pool is short (HugePages_Total: 2560, want >= 3072)"
assert_eq "never ran + unreadable is-active: fails, names it unreadable" \
    "$(hbv "" "")" "1 hugepages sizing unit did not run this boot (is-active: unreadable) — a full pool alone cannot prove the no-op (#1212)"
assert_eq "ran but the page count is garbage: fails cleanly, no arithmetic error" \
    "$(hbv banana active)" "1 hugepage pool unreadable at boot (HugePages_Total: banana, want >= 3072)"
unset -f hbv

echo "== unit: restore_live_state_verdict — a restore leaves proof it is RUNNING, not just unpacked (#1091) =="
# tests/os/run.sh's phase_install restore leg cannot be driven from here (it needs a real KVM
# guest, a genuine encrypted backup, and the wizard's HTTP upload path), but the verdict it now
# checks is pure text-matching over two already-observed strings (`podman ps` names, /api/state's
# live stratum wallet) — #1091 pulled it into tests/os/restore-live-state-verdict.sh for exactly
# that reason. The case that matters is the second pair below: `config.json` on disk (proven by a
# separate assertion in the battery) says nothing about whether the stack is actually RUNNING
# it — the verdict must fail that case even though the file landed.
# Mutation run: drop the live-wallet comparison and fall back to judging `podman ps` alone -> the
# "stack up but wallet never came back" and "stack up but wrong wallet" cases both flip from fail
# to pass, silently reintroducing #1091.
# The same fixture wallet tests/os/run.sh's battery uses (HARNESS_WALLET) — any well-formed
# address works here since the verdict only ever string-compares two values, never parses one.
RLV_WALLET="44MnN1f3Eto8DZYUWuE5XZNUtE3vcRzt2j6PzqWpPau34e6Cf4fAxt6X2MBmrm6F9YMEiMNjN6W4Shn4pLcfNAja621jwyg"
rlv() { # <podman-ps-names> <live-wallet> <want-wallet> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/restore-live-state-verdict.sh"
        restore_live_state_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "stack up + live wallet matches: passes" \
    "$(rlv "dashboard caddy monerod" "$RLV_WALLET" "$RLV_WALLET")" \
    "0 the restored machine's LIVE state (p2pool's own running config) carries the restored wallet — not just the unpacked archive file"
assert_eq "stack never came up: fails — the #1091 case a file-only check missed" \
    "$(rlv "" "" "$RLV_WALLET")" \
    "1 the stack never came up on the restored machine (podman ps: 'none') — config.json on disk is not proof the machine is RUNNING what was restored (#1091)"
assert_eq "stack up but live wallet never came back: fails, names it unreadable" \
    "$(rlv "dashboard caddy" "" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'none')"
assert_eq "stack up but live wallet is a fresh/different address: fails — config.json alone would have missed this too" \
    "$(rlv "dashboard caddy" "44SomeFreshUnrelatedAddress" "$RLV_WALLET")" \
    "1 the stack is up but live state's wallet is '44SomeFreshUnrelatedAddress', not the restored '$RLV_WALLET' — the restore landed a file but the running stack does not reflect it (#1091)"
assert_eq "stack up but /api/state answered literal Unknown/null: still fails, not treated as a match" \
    "$(rlv "caddy dashboard" "Unknown" "$RLV_WALLET")" \
    "1 the stack is up but live state never carried a readable stratum wallet (got 'Unknown')"
unset -f rlv
unset RLV_WALLET

echo "== unit: reinstall_prefill_verdict — a wallet match alone cannot prove which path produced it (#1038) =="
# tests/os/run.sh's reinstall pre-fill check cannot be driven from here (it needs a real KVM
# guest reinstalled over an existing install), but the verdict it now checks is pure
# text-matching over three already-observed signals (the branch's own console log line, the
# wallet match, the password-leak check) — #1038 pulled it into
# tests/os/reinstall-prefill-verdict.sh for exactly that reason: the discrimination the issue
# asked for is provable with fixtures, without a bench boot. The case that matters is the first
# pair below: a wallet match with NO console record of the branch having run (the exact shape
# #1038 found passing for four consecutive batteries) must verdict as a failure.
# Mutation run: drop the branch_logged check and judge by the wallet match alone -> the
# "branch never logged" case flips from fail to pass, silently reintroducing #1038.
rpv() { # <branch-logged> <wallet-prefilled> <password-leaked> -> "<rc> <verdict-text>"
    local out rc
    out=$(
        # shellcheck disable=SC1091
        source "$ROOT/tests/os/reinstall-prefill-verdict.sh"
        reinstall_prefill_verdict "$1" "$2" "$3"
    )
    rc=$?
    printf '%s %s' "$rc" "$out"
}
assert_eq "branch ran, wallet matched, no password: passes" \
    "$(rpv 1 1 0)" "0 reinstall pre-fill ran this boot and published the previous install's non-secret answers (secrets left out)"
assert_eq "wallet matched but the branch never logged: fails — the #1038 case a wallet-only check missed" \
    "$(rpv 0 1 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "branch ran but the wallet never reached the page: fails" \
    "$(rpv 1 0 0)" "1 the pre-fill branch ran but the previous install's wallet never reached the page"
assert_eq "branch ran, wallet matched, but a password leaked: fails" \
    "$(rpv 1 1 1)" "1 a password crossed into the reinstall page's pre-filled state"
assert_eq "neither the branch nor the wallet: fails on the branch record first" \
    "$(rpv 0 0 0)" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
assert_eq "empty inputs (unset shell vars): treated as not-logged, fails cleanly" \
    "$(rpv "" "" "")" "1 the pre-fill branch's own log line never appeared this boot — a wallet match alone cannot prove which code path produced it (#1038)"
unset -f rpv

# shellcheck source=tests/stack/test-appliance-media.sh
source "$HERE/test-appliance-media.sh"

echo "== unit: os/build-image.sh — --fresh-index flag parsing + the 404 remedy hint (#929) =="
# PITHEAD_BUILD_IMAGE_TEST makes the script return right after arg parsing (before docker), so
# these run its real argument handling and apt_fetch_failure_hint without a build.
build_image_test() {
    (
        export PITHEAD_BUILD_IMAGE_TEST=1
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh" "$@"
        [ "${FRESH_INDEX:-0}" = "1" ] && echo "FRESH_INDEX=1"
        declare -f apt_fetch_failure_hint >/dev/null && echo "HINT_FN_DEFINED"
    )
}
assert_contains "--fresh-index sets FRESH_INDEX" "$(build_image_test --fresh-index)" "FRESH_INDEX=1"
assert_not_contains "bare invocation leaves FRESH_INDEX unset" "$(build_image_test)" "FRESH_INDEX=1"
assert_contains "apt_fetch_failure_hint is defined after sourcing" "$(build_image_test)" "HINT_FN_DEFINED"

unknown_flag_out="$("$ROOT/os/build-image.sh" --bogus 2>&1 || true)"
assert_contains "unknown argument is rejected" "$unknown_flag_out" "unknown argument: --bogus"
assert_contains "unknown-argument error names --fresh-index" "$unknown_flag_out" "--fresh-index"

# --fresh-index composes with --ssh: parsed left-to-right, then --ssh's own missing-key check
# exits before docker, proving --fresh-index didn't swallow the next argument.
missing_key_out="$("$ROOT/os/build-image.sh" --fresh-index --ssh "$SANDBOX/no-such-key.pub" 2>&1 || true)"
assert_contains "--fresh-index then --ssh with a missing key still hits --ssh's own error" "$missing_key_out" "--ssh: no public key found"

# Exercise the hint function directly by sourcing the same way and calling it.
run_hint() {
    (
        local log="$1"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # `source file` with no args keeps the caller's $@ — clear it so build-image.sh's
        # own arg loop doesn't try to parse the log tail as a CLI flag.
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh"
        apt_fetch_failure_hint "$log" 2>&1
    )
}
assert_contains "404 signature triggers the --fresh-index remedy" "$(run_hint 'E: Failed to fetch ... 404  Not Found')" "--fresh-index"
assert_contains "'Unable to fetch' signature triggers the remedy" "$(run_hint 'E: Unable to fetch some archives, maybe run apt-get update')" "--fresh-index"
assert_eq "an unrelated failure prints no hint" "$(run_hint 'E: some other build error')" ""

echo "== unit: pithead-ssh-host-keys — per-machine host key on /data, generated once (#894/#980) =="
# Real ssh-keygen against a sandboxed key dir (PITHEAD_SSH_HOST_KEYS_DIR — the same env-seam
# shape pithead-machine-id carries). chown is PATH-stubbed: the suite is not root, and ownership
# on the box is systemd's root context, not logic this tier can prove. stdin is /dev/null on
# every run — the systemd condition the wedge-recovery case below depends on.
SHK="$SANDBOX/ssh-host-keys"
mkdir -p "$SHK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$SHK/bin/chown"
chmod +x "$SHK/bin/chown"
shk_key="$SHK/data-ssh/ssh_host_ed25519_key"
shk_run() {
    (
        export PATH="$SHK/bin:$PATH" PITHEAD_SSH_HOST_KEYS_DIR="$SHK/data-ssh"
        sh "$ROOT/os/overlay/pithead-ssh-host-keys" </dev/null 2>&1
    )
}
out=$(shk_run)
assert_rc "first run on an empty /data generates the key" "$?" "0"
assert_contains "generation is announced (a silent identity change is the bug class)" "$out" "generated a new host key"
shk_fp1=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp1" ] && ok "the generated key is a loadable ed25519 key ($shk_fp1)" ||
    bad "the generated key is a loadable ed25519 key" "ssh-keygen -lf failed on $shk_key"
assert_eq "key dir is owner-only (700)" "$(stat -c '%a' "$SHK/data-ssh" 2>/dev/null || stat -f '%Lp' "$SHK/data-ssh")" "700"
assert_eq "private key is owner-only (600)" "$(stat -c '%a' "$shk_key" 2>/dev/null || stat -f '%Lp' "$shk_key")" "600"
assert_eq "public key is world-readable (644)" "$(stat -c '%a' "$shk_key.pub" 2>/dev/null || stat -f '%Lp' "$shk_key.pub")" "644"
# Idempotence IS the identity contract (#894): a second start must find the key and change
# NOTHING — a regeneration here is exactly the host-key churn an A/B update must never cause.
out=$(shk_run)
assert_rc "second run exits 0" "$?" "0"
assert_not_contains "second run regenerates nothing" "$out" "generated"
assert_eq "second run leaves the key byte-identical" "$(ssh-keygen -lf "$shk_key" | awk '{print $2}')" "$shk_fp1"
# Wedge recovery: an interrupted prior run leaves an empty key file (+ stale .pub). ssh-keygen
# prompts before overwriting an existing path, and with stdin on /dev/null that prompt reads EOF
# and refuses — the script must clear the partial file first or sshd wedges forever.
: >"$shk_key"
out=$(shk_run)
assert_rc "a stale empty key file is regenerated, not wedged on the overwrite prompt" "$?" "0"
shk_fp2=$(ssh-keygen -lf "$shk_key" 2>/dev/null | awk '{print $2}')
[ -n "$shk_fp2" ] && ok "recovery produced a loadable key again" ||
    bad "recovery produced a loadable key again" "ssh-keygen -lf failed on $shk_key"

echo "== unit: pithead-mount-generator — /data + ESP follow the BOOTED disk, never a label (#926/#980) =="
# The generator against staged mountinfo files (PITHEAD_MOUNTINFO seam; GENDIR is already an
# argument). The staged lines keep the real shape — surrounding mounts, optional fields before
# the "-" separator — so the awk root-line/source extraction runs against what a kernel writes.
MG="$SANDBOX/mount-generator"
mkdir -p "$MG"
mg_run() { # $1 mountinfo file, $2 gendir
    (
        export PITHEAD_MOUNTINFO="$1"
        sh "$ROOT/os/overlay/pithead-mount-generator" "$2"
    )
}
cat >"$MG/mi-sda" <<'EOF'
24 30 0:22 / /proc rw,nosuid,nodev,noexec,relatime shared:5 - proc proc rw
29 1 8:2 / / rw,relatime shared:1 - ext4 /dev/sda2 rw,stripe=32
32 29 8:4 / /data rw,noatime shared:2 - ext4 /dev/sda4 rw
EOF
mg_run "$MG/mi-sda" "$MG/gen-sda"
assert_rc "generator succeeds on a /dev/sda2 root" "$?" "0"
mg_data=$(cat "$MG/gen-sda/data.mount" 2>/dev/null)
mg_esp=$(cat "$MG/gen-sda/boot-efi.mount" 2>/dev/null)
assert_contains "data.mount is partition 4 OF THE BOOT DISK" "$mg_data" "What=/dev/sda4"
assert_contains "data.mount mounts /data" "$mg_data" "Where=/data"
assert_contains "data.mount is ext4" "$mg_data" "Type=ext4"
assert_not_contains "data.mount never mounts by label" "$mg_data" "LABEL"
assert_contains "boot-efi.mount is partition 1 of the boot disk" "$mg_esp" "What=/dev/sda1"
assert_contains "boot-efi.mount mounts /boot/efi" "$mg_esp" "Where=/boot/efi"
assert_contains "the ESP mount is root-only (RAUC boot state lives there)" "$mg_esp" "Options=umask=0077"
assert_contains "the data mount orders before local-fs.target" "$mg_data" "Before=local-fs.target"
for u in data.mount boot-efi.mount; do
    if [ "$(readlink "$MG/gen-sda/local-fs.target.requires/$u")" = "../$u" ]; then
        ok "$u is required by local-fs.target (the boot waits for it)"
    else
        bad "$u is required by local-fs.target" "missing or wrong symlink"
    fi
done
# nvme/mmc naming: the partition number strips AND the 'p' separator comes back on the
# partition paths (nvme0n1p2 -> disk nvme0n1 -> partitions nvme0n1p4 / nvme0n1p1).
printf '29 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw\n' >"$MG/mi-nvme"
mg_run "$MG/mi-nvme" "$MG/gen-nvme"
assert_contains "an nvme root keeps the p separator: data" "$(cat "$MG/gen-nvme/data.mount")" "What=/dev/nvme0n1p4"
assert_contains "an nvme root keeps the p separator: ESP" "$(cat "$MG/gen-nvme/boot-efi.mount")" "What=/dev/nvme0n1p1"
# A root line with NO optional fields (the "-" comes right after the options) still parses —
# and vda-style names get no separator (vda2 -> vda4).
printf '29 1 254:2 / / rw,relatime - ext4 /dev/vda2 rw\n' >"$MG/mi-vda"
mg_run "$MG/mi-vda" "$MG/gen-vda"
assert_contains "a no-optional-fields root line parses (vda2 -> vda4)" "$(cat "$MG/gen-vda/data.mount")" "What=/dev/vda4"
# A container/unexpected root (source is not /dev/*) generates NOTHING rather than guessing.
printf '29 1 0:35 / / rw,relatime - overlay overlay rw\n' >"$MG/mi-ovl"
mg_run "$MG/mi-ovl" "$MG/gen-ovl"
assert_rc "a non-/dev root exits 0 (a generator must not fail the boot)" "$?" "0"
assert_eq "a non-/dev root generates no units" "$([ -e "$MG/gen-ovl" ] || echo none)" "none"

echo "== unit: os/rauc/loop-wait.sh — the partition wait demands block devices and polls its budget =="
# The negative half of the contract — all a non-root tier can prove: absent nodes and
# regular-file impostors both exhaust the poll and return 1. sleep/udevadm are function-stubbed
# so the 25-poll budget runs instantly. The positive half (real nodes appearing) runs for real
# on every image build — mkimage.sh and verify-image.sh both call this.
LW="$SANDBOX/loop-wait"
mkdir -p "$LW"
lw_run() { # $1 device path
    (
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/rauc/loop-wait.sh"
        udevadm() { :; }
        sleep() { echo x >>"$LW/sleeps"; }
        wait_loop_partitions "$1"
    )
}
: >"$LW/sleeps"
lw_run "$LW/loop0"
assert_rc "nodes that never appear -> rc 1" "$?" "1"
assert_eq "the wait polls its full 25-try budget, not a single-shot check" "$(wc -l <"$LW/sleeps" | tr -d ' ')" "25"
touch "$LW/loop0p1" "$LW/loop0p2"
lw_run "$LW/loop0"
assert_rc "regular files at p1/p2 do not satisfy the wait — block devices required" "$?" "1"

# ---------------------------------------------------------------------------
# shellcheck source=tests/stack/test-lifecycle.sh
source "$HERE/test-lifecycle.sh"

# ---------------------------------------------------------------------------
echo ""
printf 'pithead tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
