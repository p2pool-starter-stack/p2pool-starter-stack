# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Monero+Tari domain (#1105 Phase 1, develop-v2 lane): the merge-mining stack's node-facing
# behaviour on both chains, moved as one file because p2pool merge-mines them together — monero
# flags + the p2pool entrypoint's word-splitting and Tor-loopback bridge for the Tari gRPC (#165/
# #278), monero/tari address-type validation including the #829 checksum-vs-shape split (#250/
# #845), the wallet-entrypoint view-only gen.json + healthcheck (#381/#714/#718), the payout view
# key on both chains including the Tari birthday/spend-key gating (#381/#462/#523), tari.mode
# remote (#103), the profile-deactivation reconcile a monero/tari local<->remote switch drives
# (#795 — kept here rather than split out: it is the direct consequence of the mode-switch
# sections right above it, not a separate feature), monero.rpc_lan_access/prep_blocks_threads/
# out_peers (#523/#595), and local node-credential auto-generation (#50) plus the shared
# node-credential helpers (default_node_username/generate_node_password/cred_needs_generating).
# Sourced by tests/stack/run.sh.
#
# Re-derivations (the sandbox-builder WALLET/$V trap — see #1305, still open on this lane):
# - $CB: the "config_bool" unit test builds it ($SANDBOX/cb), but that section is a
#   generic jq-coercion helper test (also exercises xvb.tor), not monero-specific, so
#   it stays where it is: tests/stack/test-unit-helpers.sh, whose stanza run.sh sources
#   before this file. Re-derived here rather than reaching back for the ambient one.
# - $V / $WALLET: both are set by lib.sh's build_val_sandbox(), which the "config validation"
#   black-box calls once, ahead of every section below that reads them — that section lives in
#   test-config.sh, sourced ahead of this file (a generic multi-field validator, not monero-specific).
#   build_val_sandbox() is idempotent (a fixed $SANDBOX/val path, mkdir -p, template copies) so
#   calling it again here is a safe no-op re-affirm as currently sourced, and makes this file correct
#   on its own if a future reorder ever moves its source line earlier than that section.
# - $DOCKER_LOG: the "apply preserves secrets + propagates" black-box sets it ($V/docker.log); it lives
#   in test-secrets.sh, sourced ahead of this file (generic multi-key regression, not monero-specific).
CB="$SANDBOX/cb"
mkdir -p "$CB"
build_val_sandbox
DOCKER_LOG="$V/docker.log"

echo "== unit: p2pool_outbound_flags — Tor-by-default for outbound P2P (#165) =="
assert_eq "default → Tor SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags false 172.28.0)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_eq "empty arg → Tor (default off)" "$(run_sourced "$SANDBOX" p2pool_outbound_flags '' 172.28.0)" "--socks5 172.28.0.25:9050 --socks5-proxy-type tor"
# clearnet opt-out → no SOCKS flags (p2pool dials peers directly, IP exposed).
assert_eq "clearnet=true → no SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags true 172.28.0)" ""
assert_eq "clearnet=yes (any truthy) → no SOCKS flags" "$(run_sourced "$SANDBOX" p2pool_outbound_flags yes 172.28.0)" ""
# Honours a custom bridge subnet (#180) — the Tor container is always .25 of the configured /24.
assert_contains "custom NETWORK_PREFIX points at its Tor (.25)" "$(run_sourced "$SANDBOX" p2pool_outbound_flags false 172.30.5)" "172.30.5.25:9050"

echo "== p2pool entrypoint word-splits P2POOL_FLAGS into separate args (#165) =="
# Compose passes P2POOL_FLAGS as ONE env var (a `- ${VAR}` command item is a single arg, unsplit);
# the entrypoint must word-split it so a multi-flag value reaches p2pool as distinct args. A stub
# p2pool on PATH captures what it's exec'd with.
PE="$SANDBOX/p2pool-ep/bin"
mkdir -p "$PE"
cat >"$PE/p2pool" <<'STUB'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
STUB
chmod +x "$PE/p2pool"
ep_out=$(PATH="$PE:$PATH" P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" bash "$ROOT/build/p2pool/entrypoint.sh" --stratum 0.0.0.0:3333 2>&1)
assert_contains "--socks5 is its own arg" "$ep_out" "ARG=[--socks5]"
assert_contains "socks address is its own arg" "$ep_out" "ARG=[172.28.0.25:9050]"
assert_contains "proxy-type value split out" "$ep_out" "ARG=[tor]"
assert_contains "2 fixed + 5 flag tokens = ARGC 7" "$ep_out" "ARGC=7"
ep_empty=$(PATH="$PE:$PATH" P2POOL_FLAGS="" bash "$ROOT/build/p2pool/entrypoint.sh" --stratum 0.0.0.0:3333 2>&1)
assert_contains "empty P2POOL_FLAGS → no stray empty arg (ARGC=2)" "$ep_empty" "ARGC=2"

echo "== p2pool entrypoint moves the Tari merge-mine gRPC onto loopback under Tor (#278 follow-up) =="
# With --socks5 on, p2pool would dial --merge-mine tari://<private-ip> THROUGH Tor (rejected as an
# RFC1918 address → TRANSIENT_FAILURE). The entrypoint must socat-bridge that node to 127.0.0.1 and
# rewrite the URL host to the loopback IP literal. Stub socat so the test never binds a real port.
SE="$SANDBOX/socat-ep/bin"
mkdir -p "$SE"
cat >"$SE/socat" <<STUB
#!/usr/bin/env bash
printf 'SOCAT=[%s]\n' "\$*" >> "$SANDBOX/socat.log"
STUB
chmod +x "$SE/socat"
: >"$SANDBOX/socat.log"
mm_out=$(PATH="$PE:$SE:$PATH" P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" \
    bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --merge-mine tari://172.28.0.27:18142 WALLET --stratum 0.0.0.0:3333 2>&1)
assert_contains "merge-mine URL rewritten to loopback IP literal" "$mm_out" "ARG=[tari://127.0.0.1:18142]"
assert_not_contains "original private merge-mine IP no longer dialled by p2pool" "$mm_out" "ARG=[tari://172.28.0.27:18142]"
assert_contains "merge-mine wallet arg preserved" "$mm_out" "ARG=[WALLET]"
assert_contains "socat bridges loopback:18142 -> the real Tari node" "$(cat "$SANDBOX/socat.log")" "TCP-LISTEN:18142,bind=127.0.0.1,fork,reuseaddr TCP:172.28.0.27:18142"
# No SOCKS proxy → no rewrite, no bridge (clearnet mode dials the node directly, the gRPC stays put).
: >"$SANDBOX/socat.log"
mm_clear=$(PATH="$PE:$SE:$PATH" P2POOL_FLAGS="--mini" \
    bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine tari://172.28.0.27:18142 WALLET --stratum 0.0.0.0:3333 2>&1)
assert_contains "no --socks5 → merge-mine URL untouched" "$mm_clear" "ARG=[tari://172.28.0.27:18142]"
assert_eq "no --socks5 → no Tari bridge spawned" "$(cat "$SANDBOX/socat.log")" ""

echo "== p2pool entrypoint masks secret VALUES on the #273 launch line, keeps every flag NAME (#1586) =="
# `docker logs p2pool` keeps this line for the container's life, so its VALUES are the leak (#1582
# and #1585 both grew up cleaning after it). Masked values and kept flag names are ONE property.
ml_out=$(PATH="$PE:$SE:$PATH" P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --rpc-login nodeuser:nodepass --wallet 4MoneroPayout --merge-mine tari://172.28.0.27:18142 12TariPayout --onion-address examplep2pool.onion --stratum 0.0.0.0:3333 2>&1)
assert_eq "launch line masks all four secrets, keeps every flag name and --socks5" "$(printf '%s\n' "$ml_out" | sed -n 's/^\[p2pool-entrypoint\] launching: //p')" "p2pool --host 127.0.0.1 --rpc-login [redacted] --wallet [redacted] --merge-mine tari://127.0.0.1:18142 [redacted] --onion-address [redacted] --stratum 0.0.0.0:3333 --mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_contains "p2pool is still exec'd with the RAW bare tari address" "$ml_out" "ARG=[12TariPayout]"
assert_eq "--flag=VALUE masked, and --merge-mine= still masks the address AFTER it" "$(PATH="$PE:$PATH" bash "$ROOT/build/p2pool/entrypoint.sh" --wallet=4MoneroPayout --merge-mine=tari://172.28.0.27:18142 12TariPayout 2>&1 | sed -n 's/^\[p2pool-entrypoint\] launching: //p')" "p2pool --wallet=[redacted] --merge-mine=tari://172.28.0.27:18142 [redacted]"

echo "== p2pool entrypoint drops the merge-mine triple when tari.mode is off (#1855) =="
# tari.mode: off is opt-in Tari for 2.0 — no Tari surface at all, so p2pool must launch with no
# --merge-mine, no Tari gRPC URL and no Tari wallet argument. Compose still appends the fixed
# triple unconditionally (it can't drop a command item conditionally); the entrypoint strips it.
off_out=$(PATH="$PE:$PATH" TARI_MODE=off bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --merge-mine tari://172.28.0.27:18142 12TariPayout --stratum 0.0.0.0:3333 2>&1)
assert_not_contains "TARI_MODE=off → no --merge-mine flag" "$off_out" "ARG=[--merge-mine]"
assert_not_contains "TARI_MODE=off → no Tari gRPC URL" "$off_out" "ARG=[tari://172.28.0.27:18142]"
assert_not_contains "TARI_MODE=off → no Tari wallet arg" "$off_out" "ARG=[12TariPayout]"
assert_contains "TARI_MODE=off → the surrounding monero args survive" "$off_out" "ARG=[--host]"
assert_contains "TARI_MODE=off → --stratum survives" "$off_out" "ARG=[0.0.0.0:3333]"
# Control: TARI_MODE unset (today's default — nothing renders it yet) leaves the triple untouched,
# so the assertions above can't pass by the stub simply never seeing --merge-mine at all.
on_out=$(PATH="$PE:$PATH" bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --merge-mine tari://172.28.0.27:18142 12TariPayout --stratum 0.0.0.0:3333 2>&1)
assert_contains "TARI_MODE unset → --merge-mine survives" "$on_out" "ARG=[--merge-mine]"
assert_contains "TARI_MODE unset → Tari gRPC URL survives" "$on_out" "ARG=[tari://172.28.0.27:18142]"
assert_contains "TARI_MODE unset → Tari wallet arg survives" "$on_out" "ARG=[12TariPayout]"

echo "== unit: monero_prune_flag maps prune bool -> 1/0, honouring explicit false (#294) =="
# render_env + preflight both size disk off this flag; an explicit prune:false must yield 0, not the
# pruned default of 1. Missing config falls back to pruned (1).
printf '{"monero":{"prune":false}}' >"$CB/config.json"
assert_eq "explicit false -> 0" "$(run_sourced "$CB" monero_prune_flag)" "0"
printf '{"monero":{"prune":true}}' >"$CB/config.json"
assert_eq "explicit true -> 1" "$(run_sourced "$CB" monero_prune_flag)" "1"
printf '{}' >"$CB/config.json"
assert_eq "absent -> 1 (pruned default)" "$(run_sourced "$CB" monero_prune_flag)" "1"
rm -f "$CB/config.json"
assert_eq "missing config -> 1 (pruned default)" "$(run_sourced "$CB" monero_prune_flag)" "1"

# --- Wallet entrypoint (#381/#714): the view-only create-from-keys JSON must OMIT the spend key.
# monero-wallet-rpc v0.18 parses an empty-string "spendkey":"" as a secret key and aborts wallet
# creation ("failed to parse spend key secret key"), so the field's ABSENCE — not "" — is what
# lets the payout wallet build. This exercises the REAL entrypoint's write_gen_json.
echo "== unit: wallet-entrypoint view-only gen.json omits spendkey (#714) =="
# shellcheck disable=SC1090
(
    export PITHEAD_TEST_SOURCE=1
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    export GEN_JSON="$SANDBOX/wallet-gen.json" WALLET_FILE="$SANDBOX/payout-wallet"
    export MONERO_WALLET_ADDRESS="48exampleAddr" MONERO_VIEW_KEY="deadbeefdeadbeef"
    write_gen_json 3000000
)
WGEN="$(cat "$SANDBOX/wallet-gen.json")"
if printf '%s' "$WGEN" | jq -e . >/dev/null 2>&1; then ok "wallet gen.json is valid JSON (#714)"; else bad "wallet gen.json is valid JSON (#714)" "jq rejected: $WGEN"; fi
assert_eq "wallet gen.json carries the address (#381)" "$(printf '%s' "$WGEN" | jq -r .address)" "48exampleAddr"
assert_eq "wallet gen.json carries the view key (#381)" "$(printf '%s' "$WGEN" | jq -r .viewkey)" "deadbeefdeadbeef"
assert_eq "wallet gen.json scan_from_height verbatim (#381)" "$(printf '%s' "$WGEN" | jq -r .scan_from_height)" "3000000"
# THE REGRESSION GUARD: a revert to "spendkey":"" crashes monero-wallet-rpc (#714). Field must be absent.
assert_eq "wallet gen.json OMITS spendkey — monero rejects an empty one (#714)" "$(printf '%s' "$WGEN" | jq 'has("spendkey")')" "false"
# Restore height: "auto"/empty means genesis (0) so the wallet scans the FULL payout history; an
# explicit height is used verbatim to skip the long scan.
rsh() { (
    export PITHEAD_TEST_SOURCE=1 PAYOUT_SCAN_HEIGHT="$1"
    source "$ROOT/build/monero/wallet-entrypoint.sh"
    resolve_scan_height
); }
assert_eq "scan height: auto -> genesis 0 (full payout history)" "$(rsh auto)" "0"
assert_eq "scan height: empty -> genesis 0" "$(rsh '')" "0"
assert_eq "scan height: explicit block kept verbatim" "$(rsh 2500000)" "2500000"

# Wallet healthcheck (#718): during the multi-hour genesis scan monero-wallet-rpc refuses the RPC,
# so the check must tolerate an unreachable RPC WHILE the initial-scan marker is present, and turn
# strict once the RPC first answers. Stub `curl` on PATH to be the RPC up/down control.
HCBIN="$SANDBOX/hc-bin"
HCDIR="$SANDBOX/hc-wallet"
mkdir -p "$HCBIN" "$HCDIR"
mk_curl() {
    printf '#!/bin/sh\nexit %s\n' "$1" >"$HCBIN/curl"
    chmod +x "$HCBIN/curl"
}
run_hc() { (
    PATH="$HCBIN:$PATH" WALLET_DIR="$HCDIR" sh "$ROOT/build/monero/wallet-healthcheck.sh" >/dev/null 2>&1
    echo $?
); }
# RPC down + marker present (mid initial scan) -> healthy (the whole point of #718).
mk_curl 7
: >"$HCDIR/.payout-scanning"
assert_eq "healthcheck: RPC down but scanning -> healthy (#718)" "$(run_hc)" "0"
# RPC up -> healthy AND the marker is retired (scan caught up; strict from now on).
mk_curl 0
assert_eq "healthcheck: RPC up -> healthy (#718)" "$(run_hc)" "0"
if [ -f "$HCDIR/.payout-scanning" ]; then bad "healthcheck: RPC up clears the scan marker (#718)" "marker still present"; else ok "healthcheck: RPC up clears the scan marker (#718)"; fi
# RPC down + NO marker (scan already finished once) -> unhealthy: a real fault, not scan tolerance.
mk_curl 7
assert_eq "healthcheck: RPC down after scan done -> unhealthy (#718)" "$(run_hc)" "1"
# The entrypoint arms the marker on wallet creation so the grace applies from first boot.
assert_contains "wallet-entrypoint touches the scan marker on create (#718)" "$(cat "$ROOT/build/monero/wallet-entrypoint.sh")" 'touch "$SCAN_MARKER"'

echo "== unit: monero_address_type — p2pool needs a PRIMARY address, and a REAL one (#250, #829) =="
_a93="$(printf 'a%.0s' $(seq 93))"
assert_eq "monero_address_type: real 4…/95  => primary" "$(run_sourced "$SANDBOX" monero_address_type "$VALID_PRIMARY")" "primary"
assert_eq "monero_address_type: real 8…/95  => subaddress" "$(run_sourced "$SANDBOX" monero_address_type "$VALID_SUBADDR")" "subaddress"
assert_eq "monero_address_type: real 4…/106 => integrated" "$(run_sourced "$SANDBOX" monero_address_type "$VALID_INTEGRATED")" "integrated"
assert_eq "monero_address_type: 4…/94  => invalid" "$(run_sourced "$SANDBOX" monero_address_type "4$_a93")" "invalid"
assert_eq "monero_address_type: other  => invalid" "$(run_sourced "$SANDBOX" monero_address_type "1abc")" "invalid"
# The #829 class: perfect shape, wrong content. The exact harness wallet, and a single flipped
# character in an otherwise valid address — both must fail as "checksum", not pass as "primary".
_h94="$(printf 'A%.0s' $(seq 94))"
assert_eq "monero_address_type: harness 4+94×A => checksum" "$(run_sourced "$SANDBOX" monero_address_type "4$_h94")" "checksum"
assert_eq "monero_address_type: one flipped char => checksum" "$(run_sourced "$SANDBOX" monero_address_type "${VALID_PRIMARY:0:50}B${VALID_PRIMARY:51}")" "checksum"
assert_eq "monero_address_type: shape-valid 8…/95 bad checksum => checksum" "$(run_sourced "$SANDBOX" monero_address_type "8$_h94")" "checksum"
# Base58 charset: 0, O, I, l are not in the alphabet — a paste with one of them can't decode.
assert_eq "monero_address_type: non-base58 char => invalid" "$(run_sourced "$SANDBOX" monero_address_type "${VALID_PRIMARY:0:50}0${VALID_PRIMARY:51}")" "invalid"
# Network byte comes free with the decode: a checksum-valid body whose tag is integrated (19) but
# whose payload is primary-length is no mainnet address of any kind.
assert_eq "monero_address_type: valid checksum, wrong tag/length => invalid" "$(run_sourced "$SANDBOX" monero_address_type "4JMJg6ic6R584YzzMa6fUueoELZ9ZRXq9VetWzYGzKt52XU5xvqgzYnDK9URnRoJMk1j8nLwEVsaSWJ4fhdUyZijBJG8KmJ")" "invalid"
# A host whose python3 can't run the validator: the shape verdict stands alone (the
# pre-checksum behaviour — degraded, not broken, and never a false reject).
NOPY="$SANDBOX/nopy-bin"
mkdir -p "$NOPY"
printf '#!/usr/bin/env bash\nexit 127\n' >"$NOPY/python3"
chmod +x "$NOPY/python3"
assert_eq "monero_address_type: python3 unusable => shape-only primary" "$(PATH="$NOPY:$PATH" run_sourced "$SANDBOX" monero_address_type "4$_h94")" "primary"

echo "== unit: tari_address_type — DammSum over both address forms (#845) =="
assert_eq "tari_address_type: reference dual base58 => ok" "$(run_sourced "$SANDBOX" tari_address_type "$VALID_TARI")" "ok"
assert_eq "tari_address_type: same address, emoji form => ok" "$(run_sourced "$SANDBOX" tari_address_type "$VALID_TARI_EMOJI")" "ok"
assert_eq "tari_address_type: single form => ok" "$(run_sourced "$SANDBOX" tari_address_type "$VALID_TARI_SINGLE")" "ok"
assert_eq "tari_address_type: one flipped base58 char => checksum" "$(run_sourced "$SANDBOX" tari_address_type "${VALID_TARI:0:90}B")" "checksum"
_TARI_66="🍗🌊🦂🍎🐛🔱🍟🚦🦆👃🐛🎼🛵🔮💋👙💦🍷👠🦀🐺🍪🚀🎮🎩👅🐔🐉🍍🥑💔📌🚧🐊💄🎥🎓🚗🎳🐛🚿💉🌴🧢🐵🎩👾👽🎃🤡👍🔮👒👽🎵👀🚨😷🎒👂👶🍄🏰🚑🌸🍁"
assert_eq "tari_address_type: tari's invalid-checksum emoji vector => checksum" "$(run_sourced "$SANDBOX" tari_address_type "${_TARI_66}🎒")" "checksum"
assert_eq "tari_address_type: tari's invalid-emoji vector => invalid" "$(run_sourced "$SANDBOX" tari_address_type "${_TARI_66}🎅")" "invalid"
assert_eq "tari_address_type: 66-emoji (too short for dual) => invalid" "$(run_sourced "$SANDBOX" tari_address_type "$_TARI_66")" "invalid"
# A checksum-valid address for the wrong network (esmeralda byte, checksum recomputed over the
# reference keys) is a REAL address someone pasted from a testnet wallet — its own verdict.
assert_eq "tari_address_type: esmeralda address => network" "$(run_sourced "$SANDBOX" tari_address_type "f26J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Cb")" "network"
# Unknown feature bits (0x09), checksum recomputed — decodes cleanly but is no address.
assert_eq "tari_address_type: unknown feature bits => invalid" "$(run_sourced "$SANDBOX" tari_address_type "1A6J92Yow5y9UoRFd1DNujPmVFq9C1ZeiYWT95UKxz5Y1rzbfjtHg4SCZS1dk83ivzt3m2XRQHTaYUk9SwmyeCvy5Dr")" "invalid"
assert_eq "tari_address_type: old placeholder => invalid" "$(run_sourced "$SANDBOX" tari_address_type "T")" "invalid"
# No usable python3: the address is "unchecked" — accepted, degraded, never a false reject.
assert_eq "tari_address_type: python3 unusable => unchecked" "$(PATH="$NOPY:$PATH" run_sourced "$SANDBOX" tari_address_type "$VALID_TARI")" "unchecked"

echo "== unit: node credential helpers =="
assert_eq "default username is admin" "$(run_sourced "$SANDBOX" default_node_username)" "admin"
PW="$(run_sourced "$SANDBOX" generate_node_password)"
assert_eq "generated password is 32 chars" "${#PW}" "32"
assert_eq "generated password is alphanumeric" "$(printf '%s' "$PW" | tr -dc 'A-Za-z0-9')" "$PW"
PW2="$(run_sourced "$SANDBOX" generate_node_password)"
if [ "$PW" != "$PW2" ]; then ok "two generations differ"; else bad "two generations differ" "both were [$PW]"; fi
run_sourced "$SANDBOX" cred_needs_generating "" "PLACE"
assert_rc "empty needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "PLACE" "PLACE"
assert_rc "placeholder needs generating" "$?" "0"
run_sourced "$SANDBOX" cred_needs_generating "real" "PLACE"
assert_rc "real value kept" "$?" "1"

echo "== black-box: payout confirmation view key (#381) =="
# The private view key gates the view-only wallet-rpc service. Empty (default) -> feature off, no
# profile, no container. Set on a LOCAL node -> the payout_confirm profile is added, the key +
# generated wallet-rpc creds render into .env, and PAYOUT_CONFIRM_ENABLED flips true. The key is a
# secret: it must never be echoed to stdout by apply (BOTSECRET pattern), only land in the 600 .env.
VIEWKEY="$(printf 'a%.0s' $(seq 64))" # 64 hex chars — a well-formed private view key
# (1) OFF by default: no view key -> feature disabled, wallet-rpc profile absent.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "payout confirm off by default" "$(run_sourced "$V" env_get_file "$V/.env" PAYOUT_CONFIRM_ENABLED)" "false"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*payout_confirm*) bad "no wallet-rpc profile when view key unset" "payout_confirm leaked into COMPOSE_PROFILES" ;;
*) ok "no wallet-rpc profile when view key unset" ;;
esac
# (2) ON (local node): view key set -> profile added, key + creds rendered, flag true.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","view_key":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VIEWKEY" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a view key succeeds" "$?" "0"
assert_eq "payout confirm enabled renders true" "$(run_sourced "$V" env_get_file "$V/.env" PAYOUT_CONFIRM_ENABLED)" "true"
assert_eq "view key rendered into .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_VIEW_KEY)" "$VIEWKEY"
assert_contains "wallet-rpc profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "payout_confirm"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)" ] && ok "wallet-rpc password generated" || bad "wallet-rpc password generated" "empty"
# The view key must NEVER be echoed to stdout by apply — only land in the owner-only .env (#90).
case "$out" in
*"$VIEWKEY"*) bad "view key never printed by apply" "the view key leaked into apply stdout" ;;
*) ok "view key never printed by apply" ;;
esac
case "$out" in
*"$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)"*) bad "wallet-rpc password not printed" "leaked into apply stdout" ;;
*) ok "wallet-rpc password not printed" ;;
esac
# The wallet-rpc password is preserved across a re-apply (like PROXY_AUTH_TOKEN), so both containers
# keep matching creds and the wallet-rpc isn't needlessly recreated.
pw1="$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "wallet-rpc password preserved across apply" "$(run_sourced "$V" env_get_file "$V/.env" WALLET_RPC_PASSWORD)" "$pw1"
# (3) REMOTE node + view key -> refused loudly (Phase 1 is local-only; scanning a third-party node
# changes the trust story).
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p","view_key":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VIEWKEY" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "view key on a remote node rejected" "$?" "1"
assert_contains "remote view-key message names the mode" "$out" "monero.view_key"
# (4) A malformed view key (not 64 hex) is rejected before it reaches the wallet.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","view_key":"not-a-view-key"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed view key rejected" "$?" "1"
assert_contains "malformed view-key message" "$out" "64-character hex"

echo "== black-box: Tari payout confirmation view key (#462) =="
# The Tari sibling of #381: tari.view_key + tari.spend_public_key gate the view-only tari-wallet.
# Empty (default) -> feature off, no profile. Set on a LOCAL Tari node -> the tari_payout_confirm
# profile is added, the keys render into .env, the secret file is written 600, and the view key is
# never echoed to stdout. Obvious dummy keys (all-a / all-b) so gitleaks can't mistake them.
TVIEW="$(printf 'a%.0s' $(seq 64))"  # 64 hex — a well-formed Tari private view key
TSPEND="$(printf 'b%.0s' $(seq 64))" # 64 hex — a well-formed Tari public spend key
# (1) OFF by default: no tari view key -> feature disabled, tari_payout_confirm profile absent.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari payout confirm off by default" "$(run_sourced "$V" env_get_file "$V/.env" TARI_PAYOUT_CONFIRM_ENABLED)" "false"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*tari_payout_confirm*) bad "no tari-wallet profile when view key unset" "tari_payout_confirm leaked into COMPOSE_PROFILES" ;;
*) ok "no tari-wallet profile when view key unset" ;;
esac
# (2) ON (local node): tari view key + spend key set -> profile added, keys rendered, flag true.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a tari view key succeeds" "$?" "0"
assert_eq "tari payout confirm enabled renders true" "$(run_sourced "$V" env_get_file "$V/.env" TARI_PAYOUT_CONFIRM_ENABLED)" "true"
assert_eq "tari view key rendered into .env" "$(run_sourced "$V" env_get_file "$V/.env" TARI_VIEW_KEY)" "$TVIEW"
assert_contains "tari-wallet profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "tari_payout_confirm"
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)" ] && ok "tari wallet password generated" || bad "tari wallet password generated" "empty"
# The secret file is written owner-only (600) and contains the view key; it is NOT world-readable.
secret_file="$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_SECRET_FILE)"
[ -f "$secret_file" ] && ok "tari wallet secret file written" || bad "tari wallet secret file written" "missing $secret_file"
perms="$(stat -c '%a' "$secret_file" 2>/dev/null || stat -f '%Lp' "$secret_file" 2>/dev/null)"
assert_eq "tari wallet secret file is owner-only (600)" "$perms" "600"
assert_contains "secret file carries the view key for the container" "$(cat "$secret_file")" "$TVIEW"
# The view key must NEVER be echoed to stdout by apply — only land in the owner-only .env / secret file.
case "$out" in
*"$TVIEW"*) bad "tari view key never printed by apply" "the tari view key leaked into apply stdout" ;;
*) ok "tari view key never printed by apply" ;;
esac
# The tari wallet password is preserved across a re-apply so the existing wallet DB can be reopened.
tpw1="$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "tari wallet password preserved across apply" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_PASSWORD)" "$tpw1"
# (3) A view key WITHOUT the spend key -> refused (a view-only wallet needs both).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari view key without spend key rejected" "$?" "1"
assert_contains "missing-spend-key message" "$out" "tari.spend_public_key"
# (4) A malformed tari view key (not 64 hex) is rejected before it reaches the wallet.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"nope","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed tari view key rejected" "$?" "1"
assert_contains "malformed tari view-key message" "$out" "64-character hex"
# (5) A spend key PRESENT but malformed (not 64 hex) is rejected — the require-both check keys off
# the same 64-hex shape as the view key, so a garbage spend key fails just like a missing one (#523).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"deadbeef"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "malformed tari spend key rejected" "$?" "1"
assert_contains "malformed spend-key message names spend_public_key" "$out" "tari.spend_public_key"

echo "== black-box: tari.payout_scan_birthday validation (#523) =="
# The restore-point birthday is validated only on the view-key path (it feeds the tari-wallet). It
# is "auto" or a u16 days-since-epoch (0–65535) — a block height or an out-of-range value is a
# common mistake that must fail at apply, not silently mis-restore the wallet. Keys are valid so
# only the birthday is under test.
# (1) A non-integer birthday (a block height, say) is refused.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"height-3200000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-integer birthday rejected" "$?" "1"
assert_contains "non-integer birthday message names the field" "$out" "tari.payout_scan_birthday"
# (2) An in-range-looking but too-large birthday (> 65535, e.g. a block height) is refused.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"99999"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "out-of-range birthday rejected" "$?" "1"
assert_contains "out-of-range birthday message names the u16 ceiling" "$out" "65535"
# (3) A valid u16 birthday applies and reflects verbatim into .env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","view_key":"%s","spend_public_key":"%s","payout_scan_birthday":"1000"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "valid birthday accepted" "$?" "0"
assert_eq "valid birthday reflected into .env" "$(run_sourced "$V" env_get_file "$V/.env" TARI_WALLET_BIRTHDAY)" "1000"

echo "== black-box: tari.mode remote (#103) =="
# The Tari sibling of monero.mode remote: mirrors the Monero pattern above (host:port render,
# missing-host error, mode/view-key gating), so a third-party or fleet-shared Tari base node works
# the same way an operator already expects from Monero.

# (1) local (default): TARI_GRPC_ADDRESS renders the bundled node's fixed bridge IP, and local_tari
# is added to COMPOSE_PROFILES so compose actually starts it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "local tari mode applies cleanly" "$?" "0"
assert_eq "local tari renders the bundled node's gRPC address" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "172.28.0.27:18142"
assert_contains "local_tari profile added" "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" "local_tari"

# (2) remote: TARI_GRPC_ADDRESS renders host:port from tari.remote, and local_tari is OMITTED from
# COMPOSE_PROFILES so the bundled node stays off. Port defaults to 18142 when unset.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "remote tari mode applies cleanly" "$?" "0"
assert_eq "remote tari renders host:port with the default gRPC port" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "tari.example.com:18142"
case "$(run_sourced "$V" env_get_file "$V/.env" COMPOSE_PROFILES)" in
*local_tari*) bad "no local_tari profile in remote tari mode" "local_tari leaked into COMPOSE_PROFILES" ;;
*) ok "no local_tari profile in remote tari mode" ;;
esac
# A remote node still renders SOME TARI_MEM_LIMIT placeholder (compose interpolation must resolve
# even though the profiled-off tari service never uses it) rather than an empty value.
[ -n "$(run_sourced "$V" env_get_file "$V/.env" TARI_MEM_LIMIT)" ] && ok "remote tari still renders a TARI_MEM_LIMIT placeholder" || bad "remote tari still renders a TARI_MEM_LIMIT placeholder" "empty"

# (3) remote with a custom grpc_port reflects verbatim.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com","grpc_port":28142}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote tari custom grpc_port reflected" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_ADDRESS)" "tari.example.com:28142"

# (4) remote mode with no host: renders an empty TARI_GRPC_ADDRESS -> p2pool/dashboard dial nothing,
# merge-mining can't start. Must abort at validation, not silently proceed.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "remote tari mode without a host rejected" "$rc" "1"
assert_contains "tari remote-host message" "$out" "tari.remote.host"

# (5) remote Tari node + tari.view_key -> refused loudly (Phase 1 is local-only for the same reason
# as Monero's #381 gate: scanning through a third-party node changes the trust story).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com"},"view_key":"%s","spend_public_key":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$TVIEW" "$TSPEND" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari view key on a remote node rejected" "$?" "1"
assert_contains "remote tari view-key message names the field" "$out" "tari.view_key"

# (6a) tari.remote.host carrying a newline is rejected. Defence-in-depth: the central control-char
# guard catches it first (a newline in ANY value would forge a second .env line), before the
# per-field is_valid_host check below even runs — so assert rejection + no forged line, not a
# field-specific message.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"1.2.3.4\\nEVIL=pwned"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari.remote.host with a newline rejected" "$?" "1"
case "$(cat "$V/.env" 2>/dev/null)" in
*EVIL=pwned*) bad "no forged .env line from a crafted host" "EVIL=pwned leaked into .env" ;;
*) ok "no forged .env line from a crafted host" ;;
esac

# (6b) A comma in tari.remote.host is rejected by is_valid_host — a comma is NOT a control char, so
# it slips past the central guard above, but it would inject socat address options in the p2pool
# entrypoint's bridge command (TCP:$_mmhost:$_mmport). This is the field-specific guard's own case.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"1.2.3.4,fork,reuseaddr"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari.remote.host with a comma rejected" "$?" "1"
assert_contains "comma-host message names the field" "$out" "tari.remote.host"

seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com","grpc_port":"18142; rm -rf"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-numeric tari.remote.grpc_port rejected" "$?" "1"
assert_contains "bad grpc_port message names the field" "$out" "tari.remote.grpc_port"

# (7) An invalid tari.mode value is rejected before it ever reaches render_env.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"bogus"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "invalid tari.mode rejected" "$?" "1"
assert_contains "invalid tari.mode message" "$out" "tari.mode must be"

echo "== black-box: profile deactivation removes the old container (#795) =="
# `compose up --remove-orphans` does not remove a profile-deactivated service's container — the
# service is still in the compose file, so compose does not count it as an orphan — and a tari
# local→remote switch left the old node running (offline, re-syncing) against a remote-mode
# config. Apply must issue an explicit `compose rm -sf` for every profile-gated service whose
# profile is off, BEFORE the recreate up. Asserted through the docker-stub call log.
# (1) Baseline, both nodes local: the reconcile list is exactly the (off) payout-confirm wallets —
# neither node container is touched.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
SWLOG="$V/docker-switch.log"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "baseline local-nodes apply exits 0" "$?" "0"
assert_contains "local nodes: only the off payout wallets reconcile" "$(cat "$SWLOG")" "compose rm -sf wallet-rpc tari-wallet"
# (2) tari local→remote (the #795 reproduction): the tari container joins the removal list. No
# re-seed — the committed local-mode .env from (1) makes this a real transition.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari local-to-remote switch applies cleanly" "$?" "0"
assert_contains "switch removes the deactivated tari container" "$(cat "$SWLOG")" "compose rm -sf tari wallet-rpc tari-wallet"
# The removal must precede the recreate up — the point is the old node never runs beside the
# remote-mode p2pool, not that it eventually disappears.
assert_contains "tari removal happens before the recreate up" "$(sed '/compose up --pull never -d --remove-orphans/q' "$SWLOG")" "compose rm -sf tari wallet-rpc tari-wallet"
# (3) monerod rides the same guard on a monero local→remote switch.
seed_env
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "monero local-to-remote switch applies cleanly" "$?" "0"
assert_contains "switch removes the deactivated monerod container" "$(cat "$SWLOG")" "compose rm -sf monerod wallet-rpc tari-wallet"
# (4) Reverse switch, tari remote→local (#822): the freshly-reactivated profile's service must be
# left alone by the reconcile — only the still-off profiles (monerod stays remote, both payout
# wallets off) reconcile — and the recreate up must run with local_tari back in the committed
# profile list, which is what brings the tari container up again. First commit a tari-remote .env
# so the switch back is a real transition.
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"remote","remote":{"host":"tari.example.com"}}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari remote baseline applies cleanly" "$?" "0"
assert_not_contains "tari remote baseline commits a profile list without local_tari" "$(grep '^COMPOSE_PROFILES=' "$V/.env")" "local_tari"
printf '{ "monero": {"mode":"remote","remote":{"host":"node.example"},"wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","mode":"local"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
: >"$SWLOG"
out="$(cd "$V" && DOCKER_LOG="$SWLOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "tari remote-to-local switch applies cleanly" "$?" "0"
# The reconcile list is exactly the still-deactivated profiles — no tari between monerod and
# wallet-rpc (the list renders in fixed map order), so the reactivated service's container is
# never touched by the removal.
assert_contains "reverse switch reconciles only the still-off profiles" "$(cat "$SWLOG")" "compose rm -sf monerod wallet-rpc tari-wallet"
assert_not_contains "reverse switch leaves the reactivated tari alone" "$(cat "$SWLOG")" "rm -sf tari "
# And the recreate up runs AFTER that reconcile with local_tari committed back into the profile
# list — that up is what (re)creates the tari container.
assert_contains "recreate up follows the reconcile" "$(sed -n '/compose rm -sf monerod wallet-rpc tari-wallet/,$p' "$SWLOG")" "compose up --pull never -d --remove-orphans"
assert_contains "reactivated profile is live for the recreate up" "$(grep '^COMPOSE_PROFILES=' "$V/.env")" "local_tari"

echo "== black-box: monero.rpc_lan_access + prep_blocks_threads reflect into .env (#523) =="
# The rendered .env must match the config input. rpc_lan_access gates the monerod RPC bind: default
# (unset) keeps it localhost-only; true opens it to the LAN. prep_blocks_threads overrides the
# host-core-derived block-verification thread count verbatim when it is an integer.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "rpc_lan_access default binds monerod RPC to localhost" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_BIND)" "127.0.0.1"
# The #760 siblings default localhost-only the same way: ZMQ and the Tari gRPC publish.
assert_eq "zmq_lan_access default binds monerod ZMQ to localhost" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_BIND)" "127.0.0.1"
assert_eq "grpc_lan_access default binds tari gRPC to localhost" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_BIND)" "127.0.0.1"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","rpc_lan_access":true,"zmq_lan_access":true,"prep_blocks_threads":6}, "tari":{"wallet_address":"'"$VALID_TARI"'","grpc_lan_access":true}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "rpc_lan_access true binds monerod RPC to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_BIND)" "0.0.0.0"
assert_eq "zmq_lan_access true binds monerod ZMQ to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_BIND)" "0.0.0.0"
assert_eq "grpc_lan_access true binds tari gRPC to all interfaces" "$(run_sourced "$V" env_get_file "$V/.env" TARI_GRPC_BIND)" "0.0.0.0"
assert_eq "prep_blocks_threads override reflected verbatim" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_PREP_THREADS)" "6"

echo "== black-box: monero.out_peers renders to .env, bounds enforced (#595) =="
# Default 48 when unset (the Tor-IBD bandwidth default); an explicit value lands verbatim in
# MONERO_OUT_PEERS (each outbound peer ≈ one Tor circuit — the steady-state Tor CPU lever);
# out-of-range or non-integer values are refused before anything is written.
assert_eq "out_peers default renders 48" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_OUT_PEERS)" "48"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":32}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "out_peers 32 reflected verbatim" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_OUT_PEERS)" "32"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":"lots"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "non-integer out_peers refused" "$?" "1"
assert_contains "out_peers refusal names the bounds" "$out" "between 8 and 1024"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":4}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "below-minimum out_peers refused" "$?" "1"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","out_peers":2000}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "above-maximum out_peers refused" "$?" "1"
assert_contains "above-maximum refusal names the bounds" "$out" "between 8 and 1024"

echo "== black-box: local node creds auto-generated + persisted (#50) =="
# A local node with BLANK creds: apply must generate them, write them into .env AND back into
# config.json, and keep them stable on a second apply (don't regenerate every run).
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"","node_password":""}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_contains "auto-gen is logged" "$out" "Auto-generated missing local"
env_pass="$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_PASSWORD)"
assert_eq "blank username -> admin in .env" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" "admin"
assert_eq "generated password is 32 chars" "${#env_pass}" "32"
assert_eq "username persisted to config.json" "$(jq -r '.monero.node_username' "$V/config.json")" "admin"
assert_eq "password persisted to config.json" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "password stable across apply" "$(jq -r '.monero.node_password' "$V/config.json")" "$env_pass"

# A REMOTE node with blank creds means "no auth" — leave it empty, don't invent credentials.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com"}}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote username left blank" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_NODE_USERNAME)" ""
assert_eq "remote creds not persisted" "$(jq -r '.monero.node_username' "$V/config.json")" ""

# Custom remote rpc_port/zmq_port propagate to .env (the dashboard + p2pool read these to reach the
# node); both default to 18081/18083 but an operator can point at a node on non-standard ports.
seed_env
printf '{ "monero": {"mode":"remote","wallet_address":"%s","node_username":"","node_password":"","remote":{"host":"node.example.com","rpc_port":28081,"zmq_port":28083}}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "remote rpc_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_RPC_PORT)" "28081"
assert_eq "remote zmq_port propagated" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_PORT)" "28083"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_eq "zmq_port defaults to 18083" "$(run_sourced "$V" env_get_file "$V/.env" MONERO_ZMQ_PORT)" "18083"

seed_env
: >"$DOCKER_LOG"
out="$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PATH="$V/bin:$PATH" ./pithead logs monerod 2>&1)"
assert_contains "logs follows (-f) the named service" "$(cat "$DOCKER_LOG")" "compose logs -f monerod"
