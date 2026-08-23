# shellcheck shell=bash
#
# Wizard + setup domain (#1105 Phase 1): the interactive wizard flows, the setup e2e paths, and
# the setup-time kernel/GRUB tuning (optimize_kernel runs inside cmd_setup). Sourced by
# tests/stack/run.sh after lib.sh.
echo "== unit: randomx_boot_params (#176) =="
# The kernel boot params pithead writes into GRUB_CMDLINE_LINUX_DEFAULT for RandomX. Guards the
# regression where the THP-disable param was PLURAL (transparent_hugepages=never) — an unrecognized
# param the kernel silently ignores, so THP was never actually disabled. The valid param is singular.
bp="$(run_sourced "$SANDBOX" randomx_boot_params)"
assert_contains "reserves 2M huge page size" "$bp" "hugepagesz=2M"
assert_contains "reserves 3072 huge pages" "$bp" "hugepages=3072"
assert_contains "disables THP (singular param)" "$bp" "transparent_hugepage=never"
case "$bp" in
*transparent_hugepages=*) bad "THP param must be singular, not the kernel-ignored plural" "got [$bp]" ;;
*) ok "THP param is singular (no plural transparent_hugepages= typo)" ;;
esac

echo "== unit: grub heal + boot-param insert (#176) =="
# A passthrough sudo so the helpers' `sudo cp` / `sudo sed -i` actually edit a sandbox grub file
# (the global stub sudo is a no-op). The helpers select GNU vs BSD sed via OS_TYPE, so this exercises
# the real transformation on both Linux CI and a macOS dev box.
GR="$SANDBOX/grub"
mkdir -p "$GR/bin"
printf '#!/usr/bin/env bash\nexec "$@"\n' >"$GR/bin/sudo"
chmod +x "$GR/bin/sudo"
run_grub() { PATH="$GR/bin:$PATH" run_sourced "$SANDBOX" "$@"; }

# heal: rewrites an existing plural typo to the singular param, then is an idempotent no-op.
g="$GR/healed"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="hugepagesz=2M hugepages=3072 transparent_hugepages=never quiet"\n' >"$g"
run_grub heal_grub_thp_typo "$g"
assert_rc "heal: rewrites plural typo (rc 0)" "$?" "0"
assert_contains "heal: file now uses singular param" "$(cat "$g")" "transparent_hugepage=never"
case "$(cat "$g")" in *transparent_hugepages=*) bad "heal: plural typo removed" "$(cat "$g")" ;; *) ok "heal: plural typo removed" ;; esac
run_grub heal_grub_thp_typo "$g"
assert_rc "heal: idempotent no-op when already singular (rc 1)" "$?" "1"

# insert: appends the params to the active line, preserving what's already there.
g="$GR/fresh"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"\n' >"$g"
run_grub append_grub_boot_params "$g"
assert_rc "insert: edits the active line (rc 0)" "$?" "0"
out="$(cat "$g")"
assert_contains "insert: keeps existing params" "$out" "quiet splash"
assert_contains "insert: adds hugepages reservation" "$out" "hugepages=3072"
assert_contains "insert: adds singular THP param" "$out" "transparent_hugepage=never"

# insert: a commented-out line is not the active form -> rc 1, file untouched (no silent reboot).
g="$GR/commented"
printf '# GRUB_CMDLINE_LINUX_DEFAULT="quiet"\nGRUB_TIMEOUT=5\n' >"$g"
before="$(cat "$g")"
run_grub append_grub_boot_params "$g"
assert_rc "insert: no active line -> rc 1" "$?" "1"
assert_eq "insert: leaves file unchanged when no active line" "$(cat "$g")" "$before"

echo "== unit: wizard prompt count is pinned (#502 — a silently-added prompt fails this loud) =="
# Structural, not behavioral: every Enter-through default answer looks the same ("blank"), so a
# NEW prompt slipped into either function wouldn't visibly break a happy-path run — it would just
# eat one more blank line unnoticed. Pinning the count is what actually catches wizard scope creep.
core_reads=$(awk '/^wizard_ask_core\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
shape_reads=$(awk '/^wizard_ask_shape\(\) \{/,/^\}/' "$STACK" | grep -c '^\s*read -r')
assert_eq "wizard_ask_core has exactly 12 read prompts (wallets, node config, pool tier, dashboard login)" "$core_reads" "12"
assert_eq "wizard_ask_shape has exactly 6 read prompts (clearnet-sync, remote-access, alerts cluster, local-miner opt-in)" "$shape_reads" "6"

echo "== unit: wizard — Enter-through defaults skip everything but the core answers (#502) =="
# Local node, every optional prompt left blank. Proves two things at once: the core answers land
# (wallets, mode, pool tier), and nothing else does — dashboard.hashrate_drop_threshold,
# network.subnet, xvb.*, telegram.*, dashboard.onion, dashboard.auth all keep their
# config.reference.json default because the wizard never wrote them at all.
W1="$SANDBOX/wizard-defaults"
mkdir -p "$W1"
printf '%s\n%s\n\n\n\n\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$W1" run_wizard >/dev/null 2>&1
if [ -f "$W1/config.json" ]; then
    ok "wizard (defaults path) writes config.json"
else
    bad "wizard (defaults path) writes config.json" "no file at $W1/config.json"
fi
w1_cfg="$(cat "$W1/config.json" 2>/dev/null)"
assert_eq "defaults path: monero.wallet_address" "$(jq -r '.monero.wallet_address' <<<"$w1_cfg")" "$WALLET"
assert_eq "defaults path: tari.wallet_address" "$(jq -r '.tari.wallet_address' <<<"$w1_cfg")" "$VALID_TARI"
assert_eq "defaults path: monero.mode local (Enter-through)" "$(jq -r '.monero.mode' <<<"$w1_cfg")" "local"
assert_eq "defaults path: p2pool.pool Enter-through is mini (the global default)" "$(jq -r '.p2pool.pool' <<<"$w1_cfg")" "mini"
assert_eq "defaults path: local node RPC creds auto-generated (non-empty)" \
    "$([ -n "$(jq -r '.monero.node_username' <<<"$w1_cfg")" ] && [ -n "$(jq -r '.monero.node_password' <<<"$w1_cfg")" ] && echo yes)" "yes"
# The revert-proof core: config.json carries ONLY the four top-level blocks the defaults path
# writes. If a future prompt silently starts writing e.g. dashboard.hashrate_drop_threshold or
# network.subnet, this fails — a defaulted key growing a prompt shows up here even though its own
# (blank) answer looks identical to every other blank answer.
assert_eq "defaults path: top-level keys are exactly monero/tari/p2pool/dashboard, nothing else" \
    "$(jq -rc '[keys[]] | sort' <<<"$w1_cfg")" '["dashboard","monero","p2pool","tari"]'
assert_eq "defaults path: dashboard has only 'secure' — no auth/onion written" \
    "$(jq -rc '.dashboard | keys' <<<"$w1_cfg")" '["secure"]'
assert_eq "defaults path: no telegram block written" "$(jq -r 'has("telegram")' <<<"$w1_cfg")" "false"
assert_eq "defaults path: no clearnet_initial_sync written (stays the reference default)" \
    "$(jq -r '.monero | has("clearnet_initial_sync")' <<<"$w1_cfg")" "false"
assert_eq "defaults path: no local_miner block written (opt-in off, #593)" \
    "$(jq -r 'has("local_miner")' <<<"$w1_cfg")" "false"

# Opt-in to the local miner (#593): answering 'y' to the final shape prompt writes
# local_miner.enabled=true; every other answer left blank so only that key appears.
WLM="$SANDBOX/wizard-local-miner"
mkdir -p "$WLM"
printf '%s\n%s\n\n\n\n\n\n\n\ny\n' "$WALLET" "$VALID_TARI" | run_sourced "$WLM" run_wizard >/dev/null 2>&1
wlm_cfg="$(cat "$WLM/config.json" 2>/dev/null)"
assert_eq "opt-in path: local_miner.enabled written true (#593)" "$(jq -r '.local_miner.enabled' <<<"$wlm_cfg")" "true"
unset wlm_cfg

echo "== unit: wizard — remote node branch is unchanged by the ask/write split (#502) =="
# The remote-node prompts (host/RPC/ZMQ/auth) were only moved into wizard_ask_core, not touched —
# this catches the refactor breaking the variable handoff to wizard_write_config.
W3="$SANDBOX/wizard-remote"
mkdir -p "$W3"
printf '%s\n%s\nn\nnode.example.com\n\n\ny\nremoteuser\nremotepass\n\n\n\n\n\n\n' \
    "$WALLET" "$VALID_TARI" | run_sourced "$W3" run_wizard >/dev/null 2>&1
w3_cfg="$(cat "$W3/config.json" 2>/dev/null)"
assert_eq "remote path: monero.mode remote" "$(jq -r '.monero.mode' <<<"$w3_cfg")" "remote"
assert_eq "remote path: remote host set" "$(jq -r '.monero.remote.host' <<<"$w3_cfg")" "node.example.com"
assert_eq "remote path: RPC/ZMQ ports default 18081/18083" \
    "$(jq -rc '[.monero.remote.rpc_port, .monero.remote.zmq_port]' <<<"$w3_cfg")" "[18081,18083]"
assert_eq "remote path: auth creds carried through" \
    "$(jq -rc '[.monero.node_username, .monero.node_password]' <<<"$w3_cfg")" '["remoteuser","remotepass"]'
unset w3_cfg

echo "== unit: wizard — remote node WITHOUT auth + an explicit nano pool tier (#502) =="
# Two case arms neither W1 (defaults -> mini) nor W2/W3 (main / auth'd remote) reach: REMOTE_AUTH
# answered "n" (the un-auth'd remote branch skips both credential prompts, leaving them "") and
# the pool-tier case's "nano" arm. Same run_wizard helper, non-default answers on both axes.
W4="$SANDBOX/wizard-remote-noauth-nano"
mkdir -p "$W4"
printf '%s\n%s\nn\nremote2.example.com\n\n\nn\nnano\n\n\n\n\n\n' \
    "$WALLET" "$VALID_TARI" | run_sourced "$W4" run_wizard >/dev/null 2>&1
w4_cfg="$(cat "$W4/config.json" 2>/dev/null)"
assert_eq "remote-noauth path: monero.mode remote" "$(jq -r '.monero.mode' <<<"$w4_cfg")" "remote"
assert_eq "remote-noauth path: remote host set" "$(jq -r '.monero.remote.host' <<<"$w4_cfg")" "remote2.example.com"
assert_eq "remote-noauth path: declining auth leaves creds empty, not auto-generated" \
    "$(jq -rc '[.monero.node_username, .monero.node_password]' <<<"$w4_cfg")" '["",""]'
assert_eq "remote-noauth path: pool tier nano" "$(jq -r '.p2pool.pool' <<<"$w4_cfg")" "nano"
unset w4_cfg

echo "== unit: wizard — shape-question and dashboard-login answers flow into config.json (#502) =="
# The inverse of the defaults test: every optional prompt answered, proving the new logic (pool
# tier mapping, the dashboard-login cluster, and each Stage-2 cluster) actually wires through.
W2="$SANDBOX/wizard-full"
mkdir -p "$W2"
printf '%s\n%s\n\nmain\nopuser\nsuperSecret1\ny\ny\ny\nmybottoken123\n987654321\n' \
    "$WALLET" "$VALID_TARI" | run_sourced "$W2" run_wizard >/dev/null 2>&1
w2_cfg="$(cat "$W2/config.json" 2>/dev/null)"
assert_eq "full path: monero.mode local (Enter-through)" "$(jq -r '.monero.mode' <<<"$w2_cfg")" "local"
assert_eq "full path: p2pool.pool honors an explicit main" "$(jq -r '.p2pool.pool' <<<"$w2_cfg")" "main"
assert_eq "full path: stratum auth defaults on for new installs (#208)" "$(jq -r '.p2pool.stratum_password' <<<"$w2_cfg")" "auto"
# The other new-install path — `cp config.minimal.json config.json` (the bundle quick-start,
# which bypasses the wizard) — must carry the same default, or only wizard users get auth.
assert_eq "config.minimal.json ships stratum auth on (#208)" "$(jq -r '.p2pool.stratum_password' "$ROOT/config.minimal.json")" "auto"
assert_eq "full path: dashboard.auth.username set" "$(jq -r '.dashboard.auth.username' <<<"$w2_cfg")" "opuser"
assert_eq "full path: dashboard.auth.password set" "$(jq -r '.dashboard.auth.password' <<<"$w2_cfg")" "superSecret1"
assert_eq "full path: clearnet-sync cluster sets BOTH chains together" \
    "$(jq -rc '[.monero.clearnet_initial_sync, .tari.clearnet_initial_sync]' <<<"$w2_cfg")" '[true,true]'
assert_eq "full path: remote-access sets dashboard.onion.enabled" "$(jq -r '.dashboard.onion.enabled' <<<"$w2_cfg")" "true"
assert_eq "full path: telegram cluster sets enabled+token+chat_id together" \
    "$(jq -rc '[.telegram.enabled, .telegram.bot_token, .telegram.chat_id]' <<<"$w2_cfg")" '[true,"mybottoken123","987654321"]'

echo "== unit: wizard_print_pointer — closing pointer names what it deliberately didn't ask (#502) =="
pointer_out="$(run_sourced "$SANDBOX" wizard_print_pointer 2>&1)"
assert_contains "pointer mentions monero.view_key (on-chain payout confirmation)" "$pointer_out" "monero.view_key"
assert_contains "pointer mentions dashboard.energy.cost_per_kwh (#504)" "$pointer_out" "dashboard.energy.cost_per_kwh"
assert_contains "pointer mentions workers.list (per-worker overrides, #506)" "$pointer_out" "workers.list"
assert_contains "pointer points at docs/configuration.md" "$pointer_out" "docs/configuration.md"
assert_contains "pointer mentions the dashboard's config editor" "$pointer_out" "dashboard's config editor"

echo "== black-box: 'pithead setup' completes end-to-end from a wizard-produced config (#502) =="
# Everything above drives the wizard sub-functions directly (sourced). Nothing drives the actual
# command an operator runs — this is the gap. ensure_config_exists refuses a piped, non-interactive
# run OUTRIGHT when config.json is missing ([ ! -t 0 ] -> error, pithead ~L2118) — that gate is
# deliberate (don't silently generate a config from a script with no human reading the prompts), and
# it's exactly why the wizard functions were split out for testing (the comment above
# ensure_config_exists says so) rather than something to fake a tty around here. So: produce
# config.json the same piped-stdin way the wizard tests above do (proving the Q&A -> config path,
# same as W1), THEN hand it to the real `setup` command, which skips straight past that gate
# ([-f "$CONFIG_FILE"] short-circuit) and drives its own two remaining prompts (dashboard hostname,
# "start now?") from stdin like any other `read -r -p`. Same docker/sudo-stubbed sandbox as the apply
# black-box tests above; --skip-deps/--skip-optimize keep it host-safe (no apt/GRUB/sysctl edits);
# declining "start now?" stops short of actually bringing containers up.
SU="$SANDBOX/setup-e2e"
mkdir -p "$SU/build/tari" "$SU/dashboard"
: >"$SU/dashboard/Dockerfile"
cp "$STACK" "$SU/pithead"
cp "$ROOT/build/tari/config.toml.template" "$SU/build/tari/"
make_stubs "$SU/bin"
printf '%s\n%s\n\n\n\n\n\n\n\n\n' "$WALLET" "$VALID_TARI" | run_sourced "$SU" run_wizard >/dev/null 2>&1
if [ -f "$SU/config.json" ]; then ok "setup e2e: wizard stage produces config.json"; else bad "setup e2e: wizard stage produces config.json" "no file at $SU/config.json"; fi
su_out="$(cd "$SU" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SU/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
su_rc=$?
assert_rc "'pithead setup' exits 0 given an existing config.json" "$su_rc" "0"
assert_contains "'pithead setup' reports completion" "$su_out" "Deployment preparation complete"
assert_eq "'pithead setup' writes a completed .env" \
    "$(run_sourced "$SU" env_get_file "$SU/.env" DEPLOYMENT_COMPLETED)" "true"

echo "== black-box: 'pithead setup' re-run with stdin on /dev/null refuses loudly (#924) =="
# Exactly how a systemd unit or cron invokes it (no tty, stdin /dev/null): the old
# `read -r -p ... || true` turned the immediate EOF into an empty RERUN, read as decline, exit 0
# — a silent FALSE SUCCESS. The fix refuses loudly with a nonzero exit instead of proceeding: an
# unattended re-provision must never ride on the absence of a terminal, and the appliance's own
# headless paths never reach this guard (a failed provisioning attempt is not deployed).
su2_out="$(cd "$SU" && DOCKER_LOG=/dev/null PATH="$SU/bin:$PATH" ./pithead setup --skip-deps --skip-optimize </dev/null 2>&1)"
su2_rc=$?
assert_rc "headless re-run on a deployed box refuses (nonzero, no silent success)" "$su2_rc" "1"
assert_contains "the refusal says how to proceed" "$su2_out" "run './pithead setup' from a terminal"
assert_not_contains "the refusal never claims setup was skipped-as-success" "$su2_out" "Setup skipped"
unset SU su_out su_rc su2_out su2_rc

echo "== black-box: a restored coordinator's carried DEPLOYMENT_COMPLETED does not strand headless setup (#1239) =="
# Live-guest evidence (#1239): a restored coordinator's .env carries the SOURCE machine's own
# DEPLOYMENT_COMPLETED=true. Pre-fix, is_deployed() read that literally and setup()'s headless
# guard (#924, proven above) fired on the box's OWN carried marker and fatally refused before
# prepare_directories/render_env/provision_tor ever ran — `podman ps -a` on the live guest: zero
# containers, forever, with a dark dashboard and no automatic recovery. restore_apply is the ONE
# commit point both restore doors share (firstboot_consume_restore's spool channel and
# consume_preseed_restore's ESP channel, exercised here — the exact door #1239's live guest hit at
# boot), so clearing the carried marker there — a just-restored box has NOT completed deployment
# on THIS hardware — fixes both without touching setup()'s guard, which must keep refusing an
# operator re-running setup on a genuinely live box (proven immediately above, and again below).
RT="$SANDBOX/restore-stranding"
mkdir -p "$RT/build/tari" "$RT/dashboard" "$RT/data/tor" "$RT/data/dashboard"
: >"$RT/dashboard/Dockerfile"
cp "$STACK" "$RT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RT/build/tari/"
make_stubs "$RT/bin"
# make_stubs's sudo is a bare no-op — fine for setup's conditional sudo calls (writable test dirs
# skip them), but stack_backup shells to `sudo tar`/`sudo du` UNCONDITIONALLY. Same passthrough
# override the firstboot_consume_restore fixture above uses, for the same reason.
cat >"$RT/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
SUDOEOF
chmod +x "$RT/bin/sudo"
cat >"$RT/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=RTTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RT/config.json"
printf 'ONIONKEY-ORIG\n' >"$RT/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RT/data/dashboard/dashboard.db"
out="$(cd "$RT" && PATH="$RT/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore-stranding fixture: backup exits 0" "$rc" "0"
rt_archive="$(ls "$RT"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rt_archive" ] && [ -f "$rt_archive" ]; } && ok "restore-stranding fixture: encrypted archive created" || bad "restore-stranding fixture: encrypted archive created" "no .enc archive"

# Play the TARGET machine: a fresh appliance, nothing provisioned yet, the archive carried on its
# ESP exactly as the installer stages it (#909) — same channel pithead-firstboot reads at boot.
RTESP="$RT/esp"
mkdir -p "$RTESP"
cp "$rt_archive" "$RTESP/pithead-restore.enc"
printf 'hunter2' >"$RTESP/pithead-restore-pass" # test fixture, not a real secret
rm -f "$RT/config.json" "$RT/.env"
printf 'CADDY-ORIG\n' >"$RT/Caddyfile"

preseed_out=$(cd "$RT" && PATH="$RT/bin:$PATH" PITHEAD_PRESEED_DIR="$RTESP" run_sourced "$RT" consume_preseed_restore 2>&1 && echo rc0)
assert_contains "consume_preseed_restore lands the carried archive" "$preseed_out" "rc0"
assert_eq "the restored config.json carries the source wallet" \
    "$([ -f "$RT/config.json" ] && grep -q "$WALLET" "$RT/config.json" && echo yes)" "yes"
assert_eq "the restored .env's completion marker is cleared, not carried forward (#1239)" \
    "$(cd "$RT" && run_sourced "$RT" env_get_file "$RT/.env" DEPLOYMENT_COMPLETED)" "false"

# The exact live-guest reproduction: pithead-firstboot's own headless call, `setup`, against the
# just-restored .env — pre-fix this hit is_deployed()'s no-tty branch and died with the SAME
# refusal string the #924 guard test above proves for a genuinely live box; post-fix the restored
# box actually provisions, same boot.
rt_setup_out=$(cd "$RT" && PATH="$RT/bin:$PATH" DOCKER_LOG=/dev/null ./pithead setup --skip-deps --skip-optimize </dev/null 2>&1)
rt_setup_rc=$?
assert_rc "restored box's headless setup proceeds instead of refusing (#1239)" "$rt_setup_rc" "0"
assert_contains "restored box's setup actually provisions" "$rt_setup_out" "Deployment preparation complete"
assert_not_contains "restored box's setup never hits the live-box refusal" "$rt_setup_out" "Already provisioned, and re-running setup"
assert_eq "restored box ends up actually deployed" \
    "$(cd "$RT" && run_sourced "$RT" env_get_file "$RT/.env" DEPLOYMENT_COMPLETED)" "true"
unset RT RTESP rt_archive preseed_out rt_setup_out rt_setup_rc

echo "== black-box: 'pithead setup' with stratum_tls in a hand-written config generates the keypair (#261) =="
# The setup path reaches compose through prepare_directories, never ensure_directories — a
# hand-written config.json with stratum_tls:true at FIRST setup must still get its cert + the
# fingerprint announcement (verifier catch: only the apply path was covered).
SUT="$SANDBOX/setup-tls"
mkdir -p "$SUT/build/tari" "$SUT/dashboard"
: >"$SUT/dashboard/Dockerfile"
cp "$STACK" "$SUT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$SUT/build/tari/"
make_stubs "$SUT/bin"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_tls":true}, "dashboard":{"secure":false} }\n' "$WALLET" >"$SUT/config.json"
sut_out="$(cd "$SUT" && printf '\nn\n' | DOCKER_LOG=/dev/null PATH="$SUT/bin:$PATH" ./pithead setup --skip-deps --skip-optimize 2>&1)"
assert_rc "setup with stratum_tls exits 0" "$?" "0"
[ -f "$SUT/data/proxy-tls/cert.pem" ] && [ -f "$SUT/data/proxy-tls/key.pem" ] &&
    ok "setup generates the TLS keypair (#261)" || bad "setup generates the TLS keypair (#261)" "missing under $SUT/data/proxy-tls"
assert_contains "setup announces the fingerprint for rig pinning" "$sut_out" "Stratum TLS is ON"
unset SUT sut_out

unset run_wizard w1_cfg w2_cfg pointer_out core_reads shape_reads
