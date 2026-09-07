# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# tari.mode "off" at the p2pool entrypoint (#1903): the host half (#1855) renders TARI_MODE=off
# and starts no Tari node, and the entrypoint must then drop `--merge-mine <url> <address>` from
# argv, in either spelling, and nothing else. A sibling of test-monero-tari.sh, which drives the
# same entrypoint and sits at its budget ceiling; its own stubs, so it reads nothing that file sets.
# Sourced by tests/stack/run.sh.

: "${ROOT:?}" "${SANDBOX:?}"

echo "== p2pool entrypoint drops --merge-mine when TARI_MODE=off, and only then (#1903) =="
# An argv still carrying the triple merge-mines against nothing. Both spellings strip; unset (a 1.x
# .env) or any other value leaves argv as it arrived; the Tor block sees no merge-mine URL, so it
# spawns no Tari bridge while the monerod one still comes up. The launch line is pinned for the off
# shape too: the redactor is positional, and the triple's removal shifts everything after it. A
# flag in the address slot is kept, the rule the redactor already applies to a malformed argv. The
# untouched shapes pin the token COUNT, not one token: a strip that ate the flag alone would keep
# the address and read as untouched. The "dropped" line is claimed only when a triple was removed.
TO_PE="$SANDBOX/p2pool-ep-off/bin"
TO_SE="$SANDBOX/socat-ep-off/bin"
mkdir -p "$TO_PE" "$TO_SE"
cat >"$TO_PE/p2pool" <<'STUB'
#!/usr/bin/env bash
printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=[%s]\n' "$a"; done
STUB
cat >"$TO_SE/socat" <<STUB
#!/usr/bin/env bash
printf 'SOCAT=[%s]\n' "\$*" >>"$SANDBOX/socat-off.log"
STUB
chmod +x "$TO_PE/p2pool" "$TO_SE/socat"
: >"$SANDBOX/socat-off.log"
off_out=$(PATH="$TO_PE:$TO_SE:$PATH" TARI_MODE=off P2POOL_FLAGS="--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor" bash "$ROOT/build/p2pool/entrypoint.sh" --host 172.28.0.26 --wallet 4MoneroPayout --merge-mine tari://172.28.0.27:18142 12TariPayout --stratum 0.0.0.0:3333 2>&1)
assert_not_contains "off: no --merge-mine reaches p2pool" "$off_out" "ARG=[--merge-mine]"
assert_not_contains "off: the Tari address goes with it" "$off_out" "ARG=[12TariPayout]"
assert_contains "off: the flag after the triple survives" "$off_out" "ARG=[--stratum]"
assert_eq "off: no Tari bridge, the monerod bridge still spawned" "$(grep -c 'TCP:172.28.0.27' "$SANDBOX/socat-off.log"):$(grep -c 'TCP:172.28.0.26' "$SANDBOX/socat-off.log")" "0:2"
assert_eq "off: launch line still masks the wallet, nothing after the dropped triple misread" "$(printf '%s\n' "$off_out" | sed -n 's/^\[p2pool-entrypoint\] launching: //p')" "p2pool --host 127.0.0.1 --wallet [redacted] --stratum 0.0.0.0:3333 --mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor"
assert_contains "off: --merge-mine=URL spelling strips its address too (ARGC=2)" "$(PATH="$TO_PE:$PATH" TARI_MODE=off bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine=tari://172.28.0.27:18142 12TariPayout --stratum 0.0.0.0:3333 2>&1)" "ARGC=2"
assert_contains "off: the launch says the triple was dropped" "$off_out" "dropped from the launch"
slot_out=$(PATH="$TO_PE:$PATH" TARI_MODE=off bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine tari://172.28.0.27:18142 --stratum 0.0.0.0:3333 2>&1)
assert_contains "off: a flag in the address slot is kept, not swallowed" "$slot_out" "ARG=[--stratum]"
assert_contains "off: ...and the value after that flag survives with it (ARGC=2)" "$slot_out" "ARGC=2"
local_out=$(PATH="$TO_PE:$PATH" TARI_MODE=local bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine tari://172.28.0.27:18142 12TariPayout 2>&1)
assert_contains "local (any value but off): argv untouched" "$local_out" "ARG=[12TariPayout]"
assert_contains "local: all three tokens survive (ARGC=3)" "$local_out" "ARGC=3"
unset_out=$(PATH="$TO_PE:$PATH" env -u TARI_MODE bash "$ROOT/build/p2pool/entrypoint.sh" --merge-mine tari://172.28.0.27:18142 12TariPayout 2>&1)
assert_contains "unset (a 1.x .env): argv untouched" "$unset_out" "ARG=[12TariPayout]"
assert_contains "unset: all three tokens survive (ARGC=3)" "$unset_out" "ARGC=3"
assert_not_contains "off with no triple in argv: no drop is claimed" "$(PATH="$TO_PE:$PATH" TARI_MODE=off bash "$ROOT/build/p2pool/entrypoint.sh" --stratum 0.0.0.0:3333 2>&1)" "dropped from the launch"
