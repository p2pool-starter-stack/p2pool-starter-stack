#!/usr/bin/env bash
#
# Does build/tor/healthcheck.sh still run on nothing but the commands its own image ships?
#
# The #1098 guard (scripts/verify-healthcheck-scripts.sh) asks whether a healthcheck script EXISTS
# where its Dockerfile promises. This asks the other half of the same contract: whether that script
# can still RUN there. #1372 is the case that made the gap visible — build/tor/Dockerfile installed
# `xxd` by name purely for healthcheck.sh's one call site, which bought vim's CVE stream for a
# command Alpine's busybox already provides. Nothing in CI could see either the need or its removal.
#
# It is an ALLOWLIST, not a denylist: a dependency nobody declared fails here, rather than passing
# because nobody thought to ban it. Widening HC_CMDS is the point at which someone has to check the
# image really ships the new command.
#
# NAMED GAP, deliberately not approximated: this cannot prove the IMAGE's `xxd` behaves — the host's
# is vim's, the very package #1372 removed. That the pinned digest's busybox provides an `xxd` applet
# taking the same `-p -c 256` was proven inside the image on #1372, and is guarded by nothing but the
# base-image pin. What IS proven here is the script's dependency set and its logic.
#
# It lives beside the script it tests, like entrypoint.sh and healthcheck.sh live beside the
# Dockerfile, and is never COPY'd into the image — the Dockerfile copies named files only. It takes
# `--self-test` with no other mode, matching every other entry in the harness registry that drives
# it (tests/stack/test-harness-tooling.sh).
#
#   build/tor/healthcheck-selftest.sh --self-test

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HC="$HERE/healthcheck.sh"

HC_CMDS=(xxd tr grep nc) # every external command build/tor/healthcheck.sh may use
HC_HEX="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
HC_DONE='250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done"'
HC_MID='250-status/bootstrap-phase=NOTICE BOOTSTRAP PROGRESS=50 TAG=loading_descriptors'

st_fail=0
expect() { # <name> <got> <want>
    if [ "$2" = "$3" ]; then
        printf '  self-test ok: %s\n' "$1"
    else
        printf '  self-test FAIL: %s — expected [%s], got [%s]\n' "$1" "$3" "$2" >&2
        st_fail=1
    fi
}

hc_run() { # <cookie: none|empty|fixed> <control-port reply> <allowed cmd...> -> healthy|unhealthy
    local cookie="$1" reply="$2" c i d oct="" rc=0
    shift 2
    d="$(mktemp -d "$HC_D/case.XXXXXX")"
    mkdir -p "$d/bin"
    # Truncate the capture every call: a stale one read as fresh is the vacuous version of the
    # request assertion, and hc_run runs in a command substitution so it cannot hand back a path.
    : >"$HC_D/sent"
    for c in "$@"; do
        if [ "$c" = "nc" ]; then
            # Stub control port: record what the healthcheck sends, then answer as Tor would. A real
            # `nc` would dial the fixed port 9051 on the host — untestable, and a collision between
            # two concurrent suites. Shell builtins only: it runs under the same stripped PATH.
            cat >"$d/bin/nc" <<'NCSTUB'
#!/bin/sh
while IFS= read -r l; do printf '%s\n' "$l"; done >"$HC_CAP"
printf '250 OK\r\n%s\r\n250 closing connection\r\n' "$HC_REPLY"
NCSTUB
            chmod +x "$d/bin/nc"
        else
            ln -s "$(command -v "$c")" "$d/bin/$c"
        fi
    done
    # A fixed cookie, and deliberately a nasty one: bytes 0x00-0x1f include a NUL and a 0x0a, which
    # a non-binary-safe encode would truncate or mangle rather than spell as "00" and "0a".
    case "$cookie" in
    empty) : >"$d/cookie" ;;
    fixed)
        for i in $(seq 0 31); do oct="$oct$(printf '\\%03o' "$i")"; done
        printf '%b' "$oct" >"$d/cookie"
        ;;
    esac
    # /bin/sh by absolute path: with PATH stripped to the stub dir, `sh` itself is unresolvable.
    PATH="$d/bin" HC_CAP="$HC_D/sent" HC_REPLY="$reply" TOR_COOKIE_FILE="$d/cookie" \
        /bin/sh "$HC" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then printf 'healthy\n'; else printf 'unhealthy\n'; fi
}

if [ "${1:-}" != "--self-test" ]; then
    printf 'usage: %s --self-test\n' "$0" >&2
    exit 2
fi

[ -r "$HC" ] || {
    printf '  self-test FAIL: %s is missing — the check has nothing to drive\n' "$HC" >&2
    exit 1
}

HC_D="$(mktemp -d)"
trap 'rm -rf "$HC_D"' EXIT

expect "healthy on a bootstrapped control port, image commands only" \
    "$(hc_run fixed "$HC_DONE" "${HC_CMDS[@]}")" "healthy"
# The WHOLE request, not just its AUTHENTICATE line: this is the only check that pins the exact
# bytes the healthcheck speaks at the control port. (It does NOT discriminate the `tr -d` strip —
# command substitution already eats a trailing newline, so dropping `tr` leaves the hex identical.
# What catches that mutation is the drop-loop below, because `tr` stops being needed at all.)
expect "sends AUTHENTICATE <64 lowercase hex> / GETINFO / QUIT, nothing else" \
    "$(tr -d '\r' <"$HC_D/sent")" "AUTHENTICATE $HC_HEX
GETINFO status/bootstrap-phase
QUIT"
expect "unhealthy mid-bootstrap — TAG=done is the gate, not a live port" \
    "$(hc_run fixed "$HC_MID" "${HC_CMDS[@]}")" "unhealthy"
expect "unhealthy with no cookie file (control port not up yet)" \
    "$(hc_run none "$HC_DONE" "${HC_CMDS[@]}")" "unhealthy"
expect "unhealthy on an empty cookie file (written but not filled)" \
    "$(hc_run empty "$HC_DONE" "${HC_CMDS[@]}")" "unhealthy"

# The controls, and they are what makes everything above evidence rather than decoration: if PATH
# leaked to the host, every case would pass on the host's own commands and prove nothing. Each
# declared command is dropped in turn, which also refuses an over-declared allowlist — a name in
# HC_CMDS the script does not really need would keep passing here and go unnoticed.
#
# Read per-command, they are not all the same strength. `grep` and `nc` fail because the script
# genuinely cannot proceed without them. `xxd` fails only because `[ -n "$COOKIE_HEX" ]` rejects the
# empty result — `xxd -p -c 256 "$f" | tr -d '\n'` reports TR's status, so a missing xxd is not an
# error the shell sees. Drop that guard and this control flips green, which is how it was found.
for hc_drop in "${HC_CMDS[@]}"; do
    hc_subset=()
    for hc_c in "${HC_CMDS[@]}"; do [ "$hc_c" = "$hc_drop" ] || hc_subset+=("$hc_c"); done
    expect "FAILS with $hc_drop missing — the PATH isolation is real" \
        "$(hc_run fixed "$HC_DONE" "${hc_subset[@]}")" "unhealthy"
done
# ...and the over-tightening control: an extra command present must not change the verdict, or the
# checks above are really counting the allowlist rather than exercising the script.
expect "an unused extra command on PATH changes nothing" \
    "$(hc_run fixed "$HC_DONE" "${HC_CMDS[@]}" sed)" "healthy"

# The seam is only honest while the shipped default is untouched — same guard, and same reason, as
# the tor entrypoint's TORRC_OUT default in tests/stack/test-tor-network.sh.
expect "keeps /var/lib/tor/control_auth_cookie as its container default" \
    "$(grep -c '^COOKIE_FILE=${TOR_COOKIE_FILE:-/var/lib/tor/control_auth_cookie}$' "$HC")" "1"
expect "reads NO other cookie path outside that default" \
    "$(grep -vE '^\s*#' "$HC" | grep -cF '/var/lib/tor/control_auth_cookie')" "1"

exit "$st_fail"
