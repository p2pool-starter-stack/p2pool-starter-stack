# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# tari.mode "off" — merge-mining is opt-in (#1855). Its own domain rather than a section appended to
# test-monero-tari.sh: that file is a Monero+Tari NODE domain at its 582-line budget ceiling, and the
# defect class here is different — it is about a machine that does not merge-mine AT ALL, where the
# question at every assertion is "does this Tari thing stay switched off", not "does it point at the
# right node". Order-independent (#1330): it re-derives its own sandbox and its own key fixtures
# rather than reading the ones test-monero-tari.sh happens to leave ambient.
#
# THE ONE THAT MATTERS IS THE MISSING KEY. Every 1.x install merge-mines and none of them ever wrote
# tari.mode, so if the parser's default for a MISSING key ever becomes "off", every upgraded machine
# silently stops merge-mining with nothing in the logs to say why. That default is asserted here
# directly, against a config with no tari.mode at all, so the trap is a red test and not a comment.
# Sourced by tests/stack/run.sh.
build_val_sandbox
TOFF_VIEW="$(printf 'a%.0s' $(seq 64))"  # 64 hex — a well-formed Tari private view key
TOFF_SPEND="$(printf 'b%.0s' $(seq 64))" # 64 hex — a well-formed Tari public spend key

echo "== black-box: tari.mode off — merge-mining is opt-in (#1855) =="

# (1) The MIGRATION TRAP, asserted first because everything else is worthless if this regresses: a
# config with NO tari.mode key still parses as "local" and still starts the bundled node. This is
# what every 1.x config looks like.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "a config with no tari.mode applies cleanly" "$?" "0"
assert_eq "missing tari.mode still means local" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MODE)" "local"
assert_contains "missing tari.mode still starts the bundled node" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "local_tari"
assert_eq "missing tari.mode leaves Tari BLOCKING, exactly as 1.x did" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "true"

# (1b) The SIBLING that makes (1) narrow: "off" is the ONLY value that excuses a missing Tari payout
# address. The gate reads $TARI_MODE, so a default that ever drifted to "off" would let a config
# with neither key through here — silently, and looking exactly like a pass.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "no tari.mode and no tari.wallet_address is still rejected" "$?" "1"
assert_contains "and the refusal is the wallet-address one" "$out" "wallet addresses"

# (2) off: accepted, rendered, and the bundled node stays out of the profile list.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"mode":"off"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari.mode off applies cleanly" "$?" "0"
assert_eq "tari.mode off reaches the containers as TARI_MODE" "$(run_sourced "$V" env_get_file "$V/.env" TARI_MODE)" "off"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*local_tari*) bad "no local_tari profile when tari.mode is off" "local_tari leaked into COMPOSE_PROFILES" ;;
*) ok "no local_tari profile when tari.mode is off" ;;
esac

# (3) off needs no Tari payout address. A machine that does not merge-mine has nothing to be paid
# for, so requiring one would be a question the wizard must not have to ask — (2) above already
# omits tari.wallet_address entirely and applied cleanly, which is the assertion; this names it.
ok "tari.mode off does not require a tari.wallet_address (config in (2) has none)"

# (4) The three values that must never render EMPTY when off. The tari service is profile-gated
# away, but compose resolves EVERY interpolation in the file at parse time, profiled-off services
# included, so an empty value fails `compose up` outright rather than at startup.
# TARI_WALLET_ADDRESS fails worse and more quietly. p2pool's `--merge-mine tari://<addr> <wallet>`
# triple is one unquoted line in the appliance's Quadlet unit (36-quadlet-units.sh:233), and
# systemd Exec= splits on whitespace and emits no empty word — so an empty wallet does not pass an
# empty argument, it VANISHES, and p2pool reads the NEXT flag as its payout address. That is an
# argv shift, not a bad value. #1903 will drop the triple when off and retire this; it is not
# landed, so a non-empty placeholder is the guard until it is.
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" ] &&
    ok "tari.mode off still renders a TARI_GRPC_ADDRESS placeholder" ||
    bad "tari.mode off still renders a TARI_GRPC_ADDRESS placeholder" "empty"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" ] &&
    ok "tari.mode off still renders a TARI_MEM_LIMIT placeholder" ||
    bad "tari.mode off still renders a TARI_MEM_LIMIT placeholder" "empty"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_ADDRESS)" ] &&
    ok "tari.mode off still renders a TARI_WALLET_ADDRESS placeholder" ||
    bad "tari.mode off still renders a TARI_WALLET_ADDRESS placeholder" "empty — p2pool's merge-mine argv shifts"

# (4b) A machine that declined merge-mining must still MINE. TARI_REQUIRED drives the dashboard's
# sync gate, which stops p2pool and xmrig-proxy until it is satisfied; with no Tari node running,
# the Tari leg never reports synced, so a default-true flag holds an off machine at zero hashrate
# forever — the exact inverse of what its operator asked for. The config in (2) sets no
# dashboard.tari_required, so this reads the DERIVED value and not an echo of an explicit one.
# (1) above is the control: the same assertion reads "true" on a machine that did not decline.
assert_eq "tari.mode off makes Tari non-blocking, so the stack still mines Monero" "$(run_sourced "$V" env_get_file "$V/.env" TARI_REQUIRED)" "false"

# (5) A view key with tari.mode off is refused, and the message names the mode that IS set. Payout
# confirmation scans the LOCAL Tari node; with no node at all there is nothing to scan, and the old
# message said "unsupported with tari.mode: remote" — true when remote was the only other value,
# and a lie the moment a third one exists.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"mode":"off","view_key":"%s","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TOFF_VIEW" "$TOFF_SPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari view key with tari.mode off rejected" "$?" "1"
assert_contains "off view-key message names the field" "$out" "tari.view_key"
assert_contains "off view-key message names the mode that is set" "$out" "off"
case "$out" in
*"tari.mode: remote"*) bad "off view-key message does not claim the mode is remote" "the message still says \"tari.mode: remote\"" ;;
*) ok "off view-key message does not claim the mode is remote" ;;
esac

# (6) The rejection message for a bogus value names all three accepted values. test-monero-tari.sh
# already asserts a bogus value is REJECTED; what is new is that an operator reading the error can
# discover "off" from it, which is the only place the CLI tells them the mode exists.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"bogus"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "bogus tari.mode still rejected" "$?" "1"
# Labels are literal, not a loop variable: #1740 holds every PASS line to a value the suite has
# reviewed, and an interpolated label is indistinguishable from a measured one.
assert_contains 'tari.mode error offers "local"' "$out" '"local"'
assert_contains 'tari.mode error offers "remote"' "$out" '"remote"'
assert_contains 'tari.mode error offers "off"' "$out" '"off"'
