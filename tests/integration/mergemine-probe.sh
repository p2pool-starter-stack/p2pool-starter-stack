# shellcheck shell=bash
#
# The p2pool -> Tari merge-mining gRPC round-trip probe (#1397).
#
# WHY THIS EXISTS. Merge-mining is what makes Tari pay, and it is driven entirely by p2pool — a
# third-party binary — not by any client we wrote. `fakes/test_contract.py` looks like it covers
# this and does not: it drives the DASHBOARD's Tari client against `fake_tari.py`. Before this
# file, nothing at any tier observed p2pool reaching the Tari node, so a gRPC method moving
# behind an allow-list (the named risk on the Tari v5.6.0 bump, and the exact shape of #313)
# would land with every gate green.
#
# WHY TIER 4 AND NOT A FAKE. #1397 offered "drive p2pool's merge-mining client against a
# controllable fake" as the cheaper half that would also escape the sync problem. Measured at
# p2pool v4.18's source (the pinned binary we ship): there is exactly ONE creation site for
# merge-mining clients, `IMergeMiningClient::create`, and it sits inside the success callback of
# `download_block_headers4` — after `BLOCK_HEADERS_REQUIRED = 720` headers parse. So a fake would
# have to serve 720 consecutive, self-consistent Monero block headers and a live ZMQ publisher
# before the Tari fake is reached at all. That is not the cheaper half; it re-implements a synced
# monerod. Option 1 — a real box whose chain is already synced — is the one that works, and the
# release gate already runs on one.
#
# WHAT PROVES A ROUND-TRIP, AND WHAT ONLY LOOKS LIKE ONE. p2pool emits three lines. Two are
# LOCAL and prove only that the object was constructed and its threads spun:
#
#     MergeMiningClientTari event loop started
#     MergeMiningClientTari worker thread ready
#
# The third is the only assertion worth building on:
#
#     MergeMiningClientTari tari://<host:port> uses chain_id <id>
#
# because p2pool cannot know the chain_id without a successful call to the Tari node. Measured on
# the live stack, the two local lines land ~175 ms BEFORE the chain_id read, so asserting on
# either would be satisfiable with Tari unreachable — the false green this harness exists to
# kill. That is why `local-only` is its own verdict and a FAILURE, not a near-miss pass. It is
# also the most informative failure here: it says the client is up and Tari is not answering.
#
# THE LOG IS ANSI-COLOURED AND THE ESCAPES SIT MID-LINE. Measured with `cat -v` on the live
# stack, the chain_id line really reads:
#
#     ^[[0;90mMergeMiningClientTari ^[[0mtari://127.0.0.1:18142 uses chain_id ^[[0;96m01f0…
#
# `docker compose logs --no-color` suppresses DOCKER's colouring, not the application's own. A
# pattern written against the rendered text — `MergeMiningClientTari tari://.* uses chain_id` —
# therefore matches NOTHING, silently. That failure is invisible in the worst way: a probe that
# always reports "absent" looks identical to a working one right up to the moment it matters.
# Strip the escapes first, then match. The self-test carries the fired negative control.
#
# THE SIGNAL IS STARTUP-ONLY. The three lines land within ~17.5s of the container's start — at
# positions 68/69/71 of a log that had reached 83,070 lines after 30h (ONE sample, live stack,
# 2026-08-30). `--tail 200` cannot contain them on a container that has been up minutes, so this
# read is bounded by the container's own StartedAt and a head window, never by a tail.

# The startup window, in lines. The observed maximum position is 71 (one sample), so 2000 is
# ~28x headroom while still being two orders below a day-old log — "startup" stays a real bound
# rather than a name. It is a CEILING, not a cost: `head` closes the pipe, and only the matching
# lines ever cross the wire.
MM_WINDOW_LINES=2000

# Strip SGR escape sequences. PURE.
# The ESC byte is written with bash ANSI-C quoting rather than a `\x1b` inside the sed script,
# because that spelling depends on the sed implementation and this box's text tools are shims.
mm_strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# mm_roundtrip_verdict <log text> — prints exactly one of:
#
#   roundtrip <chain_id>  p2pool read a chain_id from the Tari node: the gRPC call SUCCEEDED
#   local-only            the client was constructed, but no chain_id was ever read
#   absent                p2pool never constructed a merge-mining client at all
#
# Returns 0 ONLY for roundtrip. PURE — a function of the text alone, so the self-test drives
# every class from a fixture with no stack, no container and no network.
mm_roundtrip_verdict() {
    local plain id
    plain="$(printf '%s\n' "$1" | mm_strip_ansi)"
    # `tail -n 1` takes the newest epoch should more than one ever reach this function. The
    # capture below already bounds the read to the current container run; this is the belt to
    # that braces, and it costs nothing.
    id="$(printf '%s\n' "$plain" |
        grep -aoE 'MergeMiningClientTari tari://[^ ]+ uses chain_id [0-9a-f]{16,}' |
        tail -n 1 | awk '{print $NF}')"
    if [ -n "$id" ]; then
        printf 'roundtrip %s\n' "$id"
        return 0
    fi
    if printf '%s\n' "$plain" | grep -qa 'MergeMiningClientTari'; then
        printf 'local-only\n'
        return 1
    fi
    printf 'absent\n'
    return 1
}

# Capture the CURRENT container run's merge-mining lines. Both bounds are load-bearing:
#
#   --since <StartedAt>  excludes any EARLIER startup epoch. Docker's restart policy can restart
#                        p2pool in place, and the log then still carries the old startup's
#                        chain_id line — which would satisfy this assertion while the live client
#                        never reached Tari. StartedAt moves with the restart; the log does not.
#   head -n <window>     keeps this a startup read rather than a whole-log scan.
#
# `docker inspect` is used with --format naming ONE field. Unformatted, it prints `.Args`, which
# on this stack carries both wallet addresses, the RPC credential and the onion address; the same
# is true of the p2pool log's own argv line. Only lines matching MergeMiningClientTari cross the
# wire, so none of that is transferred here (#1582/#1585/#1586).
mm_capture_startup() {
    local started
    started="$(rx "docker inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r')"
    [ -n "$started" ] || return 1
    rx "docker compose logs --no-color --since $(quote_arg "$started") p2pool 2>&1 | head -n ${MM_WINDOW_LINES} | grep -a MergeMiningClientTari || true" 2>/dev/null
}

# The release-gate leg: PASS, FAIL, or an honest counted SKIP — never a silent green.
#
# The skip is classed `by-design` rather than `missing` on the skip-accounting test: no input,
# flag or env var to THIS harness would make the signal exist on an unsynced node, because
# p2pool does not construct the client at all until the header download completes (cycle 40
# measured zero Tari gRPC calls across five legs against absent, synced-fake and partial-fake
# monerods). Covering it means running against a synced chain, not supplying something.
assert_mergemine_roundtrip() {
    local lines verdict
    if ! monero_caught_up; then
        it_skip_leg "p2pool merge-mining gRPC round-trip (#1397)" \
            "monerod is not caught up, and p2pool constructs its merge-mining client only after the block-header download succeeds — the signal cannot exist on this run" by-design
        return 0
    fi
    if ! lines="$(mm_capture_startup)"; then
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" "could not read p2pool's container start time"
        return 0
    fi
    verdict="$(mm_roundtrip_verdict "$lines")"
    case "$verdict" in
    roundtrip*) it_pass "p2pool reached the Tari node over gRPC — ${verdict} (#1397)" ;;
    local-only)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "p2pool built its merge-mining client but never read a chain_id — the client is up and Tari is NOT answering"
        ;;
    *)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "no MergeMiningClientTari line in the first ${MM_WINDOW_LINES} lines after the container started — p2pool built no merge-mining client, or the log could not be read"
        ;;
    esac
}
