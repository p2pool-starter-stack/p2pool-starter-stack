#!/usr/bin/env bash
#
# Third-party image pin currency, at the digest level (#1137).
#
# pin-watch.sh asks "is the pinned VERSION behind upstream's latest release" and says outright that
# it does NOT ask whether a pinned `tag@sha256:...` still has a digest that matches its tag. This
# script asks exactly that second question, for every third-party image docker-compose.yml pins by
# digest: quay.io/tarilabs' tari node and wallet, tecnativa's socket-proxy, and caddy.
#
# The digest is what actually runs. A version bump that moves a tag and leaves the digest behind
# still runs the OLD image while the pin, the release notes, and every doc claim the new one — the
# exact half-done bump #1137 is about. Comparing tags (what pin-watch.sh already does) cannot catch
# it; only asking the registry what a tag resolves to right now can.
#
# Pin source is one grep over docker-compose.yml, not a hand-kept list: first-party images use
# ${PITHEAD_REGISTRY...}/${STACK_VERSION...} and are never digest-pinned, so the `@sha256:` pattern
# alone is the whole filter. A new third-party pin lands here on the next run with no edit to this
# file, and a first-party image added the same way is never mistaken for one.
#
# UNREACHABLE IS NOT CURRENT. A registry lookup that cannot complete is counted, named, and rc 1 —
# never silently treated as a match. A pin that could not be checked is UNCHECKED, not current.
#
# Usage:
#   scripts/resolve-pins.sh              Compare every digest-pinned image against its registry.
#                                         rc 1 on any mismatch OR any failed lookup.
#   scripts/resolve-pins.sh --self-test  Drive extraction + comparison against fixtures, docker
#                                         stubbed as a shell function. No network.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The one place pins are read from. Prints one "image:tag@sha256:digest" per line, sorted unique.
extract_pins() { # <compose-file>
    grep -oE 'image: [a-z0-9./_-]+:[A-Za-z0-9._-]+@sha256:[a-f0-9]{64}' "$1" | sed 's/^image: //' | sort -u
}

# Ask the registry what a tag resolves to RIGHT NOW. Shape-checked before it is trusted anywhere —
# a registry error page or an empty response must never be compared as if it were a digest. Retried
# because a registry hiccup must not fake a red; not retried past 3 tries because a hiccup that
# outlives three tries with a 2s gap is a real outage, and an outage is exactly the UNCHECKED case.
resolve_digest() { # <tag-ref> -> sha256:<64 hex> on stdout, rc 1 if never resolved to that shape
    local ref="$1" out attempt sleep_s="${RESOLVE_PINS_RETRY_SLEEP:-2}"
    for attempt in 1 2 3; do
        if out="$(docker buildx imagetools inspect "$ref" --format '{{println .Manifest.Digest}}' 2>/dev/null)"; then
            out="$(printf '%s' "$out" | tr -d '[:space:]')"
            if printf '%s' "$out" | grep -qE '^sha256:[a-f0-9]{64}$'; then
                printf '%s\n' "$out"
                return 0
            fi
        fi
        if [ "$attempt" -lt 3 ]; then
            sleep "$sleep_s"
        fi
    done
    return 1
}

# Every pin, resolved and verdicted. Prints one line per pin as it goes (so a hang on pin 2 of 4
# does not hide the first result) and returns non-zero if anything failed OR mismatched.
run_check() { # <compose-file>
    local compose_file="$1" pin tagref pinned live failed=0 mismatched=0
    while IFS= read -r pin; do
        [ -n "$pin" ] || continue
        tagref="${pin%@*}"
        pinned="${pin##*@}"
        if ! live="$(resolve_digest "$tagref")"; then
            printf 'UNCHECKED: %s — the registry lookup for this tag did not return a usable digest after 3 tries. This pin is unverified, not current.\n' "$tagref"
            failed=$((failed + 1))
            continue
        fi
        if [ "$live" = "$pinned" ]; then
            printf 'current: %s\n' "$tagref"
        else
            printf 'MISMATCH: %s — the registry resolves this tag to %s, docker-compose.yml pins %s. Either a version bump moved the tag and left the digest (the stack still runs the old image), or upstream re-pointed the tag. Fix the pin before cutting.\n' \
                "$tagref" "$live" "$pinned"
            mismatched=$((mismatched + 1))
        fi
    done < <(extract_pins "$compose_file")
    if [ "$((failed + mismatched))" -gt 0 ]; then
        printf '\n%s\n' "$failed lookup(s) unchecked, $mismatched pin(s) mismatched. Fix before cutting."
        return 1
    fi
    printf '\nEvery third-party image pin matches what its registry resolves that tag to.\n'
    return 0
}

# --- self-test -------------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st() { # <label> <got> <want>
        if [ "$2" = "$3" ]; then
            echo "  self-test ok: $1"
        else
            echo "  self-test FAIL: $1 (got [$2], want [$3])"
            st_fail=1
        fi
    }
    export RESOLVE_PINS_RETRY_SLEEP=0

    fx1="$(mktemp)"
    fx2="$(mktemp)"
    trap 'rm -f "$fx1" "$fx2"' EXIT

    cat >"$fx1" <<'EOF'
    image: ${PITHEAD_REGISTRY:-ghcr.io/p2pool-starter-stack}/pithead-dashboard:${STACK_VERSION:-dev}
    image: caddy:2.11.4@sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
    image: quay.io/tarilabs/minotari_node:v5.3.1-mainnet@sha256:b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
EOF
    st "extraction finds exactly the digest-pinned refs" "$(extract_pins "$fx1" | wc -l | tr -d ' ')" "2"
    st "a \${VAR} first-party image is skipped" "$(extract_pins "$fx1" | grep -c '\${' || true)" "0"

    printf 'image: caddy:2.11.4@sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\n' >"$fx2"

    docker() { printf 'sha256:a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1\n'; }
    if out="$(run_check "$fx2" 2>&1)"; then rc=0; else rc=$?; fi
    st "a matching digest resolves rc 0" "$rc" "0"

    # THE #1137 MUTATION: the tag now resolves to a NEW digest; docker-compose.yml still pins the
    # old one. Nothing about the file is malformed — this is exactly the half-done bump #1137
    # describes, and it MUST go red.
    docker() { printf 'sha256:c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3\n'; }
    if out="$(run_check "$fx2" 2>&1)"; then rc=0; else rc=$?; fi
    st "a moved tag with the old digest left behind is caught" "$rc" "1"
    st "the mismatch is named, not swallowed" "$(printf '%s' "$out" | grep -c MISMATCH)" "1"

    docker() { return 1; }
    if out="$(run_check "$fx2" 2>&1)"; then rc=0; else rc=$?; fi
    st "a resolver that cannot run fails, never current" "$rc" "1"
    st "a failed lookup is never printed as current" "$(printf '%s' "$out" | grep -c '^current:')" "0"

    docker() { printf 'not-a-digest\n'; }
    if out="$(run_check "$fx2" 2>&1)"; then rc=0; else rc=$?; fi
    st "non-sha256 resolver output is refused" "$rc" "1"
    st "garbage output is never compared as a mismatch" "$(printf '%s' "$out" | grep -c MISMATCH)" "0"

    unset -f docker

    if [ "$st_fail" = 0 ]; then
        echo "resolve-pins self-test OK"
    fi
    exit "$st_fail"
fi

# --- the check -------------------------------------------------------------------------------
compose_file="$ROOT/docker-compose.yml"
[ -f "$compose_file" ] || {
    echo "resolve-pins: docker-compose.yml not found at $compose_file" >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || {
    echo "resolve-pins: docker is required to resolve registry digests." >&2
    exit 1
}

run_check "$compose_file"
