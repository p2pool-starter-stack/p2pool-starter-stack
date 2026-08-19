#!/usr/bin/env bash
#
# Weekly upstream-currency watch (#1128).
#
# REPORTS ONLY. It never bumps a pin and never opens a PR. That is deliberate: a Tari or monerod
# minor is a data migration to schedule, not a bump to merge — #1129 carries three one-time
# migrations and a one-way wallet-DB change. RigForge's xmrig-bump.yml opens a build-verified PR
# instead, which is right there and wrong here; the two share this shape, not this output.
#
# The pins come from scripts/release.sh's pin(), which is where the release notes read them from.
# A second list is how the gap this closes opened in the first place.
#
# One question per component: is the pinned VERSION behind upstream's latest release?
#
# NOT asked here, deliberately: whether an image pinned `tag@sha256:...` still has a digest that
# corresponds to that tag. The digest is authoritative and the tag is decoration, so a bump that
# moves the tag and leaves the digest keeps running the old image while every doc says otherwise
# — but answering it needs a registry client (two different token flows for quay.io and Docker
# Hub), which is a second source type with its own failure mode. It is its own change.
#
# UNREACHABLE IS NOT CURRENT. Every failed lookup increments a counter, the run exits non-zero,
# and the report names what could not be checked. A watcher that has silently stopped otherwise
# looks exactly like a watcher with nothing to report — which is how a scheduled workflow in this
# repo ran zero times without anyone noticing.
#
# Usage:
#   scripts/pin-watch.sh              Print the markdown report on stdout; rc 1 if anything failed.
#   scripts/pin-watch.sh --self-test  Drive the comparison logic against fixtures. No network.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Upstream release feed per component. Everything here is compared against
# `repos/<owner>/<repo>/releases/latest`, which also excludes prereleases — load-bearing, since
# tari's newest tags are v5.6.0-pre.* and proposing those onto the merge-mining leg would be worse
# than saying nothing.
#
# NOT WATCHED, on purpose, because they have no GitHub release feed: the alpine base in
# build/tor/Dockerfile, ubuntu:24.04 and python:3.11-slim. Dependabot's docker ecosystem does see
# those (it reads FROM lines), so they are covered — just not here. They are named in the report so
# their absence is a statement rather than a silence.
upstream_for() {
    case "$1" in
    monero) echo monero-project/monero ;;
    p2pool) echo SChernykh/p2pool ;;
    xmrig-proxy) echo xmrig/xmrig-proxy ;;
    tari) echo tari-project/tari ;;
    caddy) echo caddyserver/caddy ;;
    socket-proxy) echo Tecnativa/docker-socket-proxy ;;
    compose) echo docker/compose ;;
    cosign) echo sigstore/cosign ;;
    esac
}

# Our pins do not spell versions the way upstream tags them, and this is the part that decides
# whether the watcher is useful or muted: `caddy:2.11.4` vs `v2.11.4` and `xmrig-proxy 6.26.0` vs
# `v6.26.0` are CURRENT, and `minotari_node:v5.3.1-mainnet` vs `v5.6.0` is stale. A plain string
# comparison calls the first two stale every week for ever, and a watcher that cries wolf weekly
# gets ignored — exactly as useless as one that never runs.
#
# Strips, in order: an image name up to the last colon, a digest suffix, a leading `v`, and a
# `-mainnet`/`-testnet` network suffix.
norm() {
    local v="$1"
    # Digest FIRST: `${v##*:}` cuts to the LAST colon, and a digest suffix carries one — so the
    # other order turns caddy:2.11.4@sha256:abc into "abc". (Caught by the self-test below on the
    # first run, which is the only reason it is not shipping that way.)
    v="${v%%@*}"
    v="${v##*:}"
    v="${v#v}"
    v="${v%-mainnet}"
    v="${v%-testnet}"
    printf '%s' "$v"
}

# The digest half of a `tag@sha256:...` image pin; empty for a plain version string.
pinned_digest() {
    case "$1" in
    *@sha256:*) printf '%s' "${1##*@}" ;;
    esac
}

# The full image reference minus the digest, e.g. quay.io/tarilabs/minotari_node:v5.3.1-mainnet.
image_ref() {
    case "$1" in
    *@sha256:*) printf '%s' "${1%%@*}" ;;
    esac
}

# --- the two lookups. Both are wrapped so a failure is a COUNTED failure, never a quiet "current".

latest_release() { # <owner/repo> -> tag on stdout, rc 1 on any failure
    local tag
    tag=$(gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null) || return 1
    # Third-party input. A tag that is not shaped like a version must not be compared, printed into
    # an issue body, or otherwise trusted.
    printf '%s' "$tag" | grep -qE '^v?[0-9]' || return 1
    printf '%s' "$tag"
}


# --- self-test -----------------------------------------------------------------------------------
# The comparison logic is the whole product here; the two lookups are one `gh api` and one
# `docker` call each. Drives norm() over the real pin spellings and the failure paths over stubs.
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
    # The three spellings that would otherwise be reported stale every week for ever.
    st "a bare image tag normalises to the upstream version" "$(norm 'caddy:2.11.4')" "2.11.4"
    st "a leading v is not a version difference" "$(norm 'v6.26.0')" "6.26.0"
    st "tari's network suffix is not a version difference" \
        "$(norm 'quay.io/tarilabs/minotari_node:v5.3.1-mainnet')" "5.3.1"
    st "a digest suffix is not part of the version" \
        "$(norm 'caddy:2.11.4@sha256:aaaa')" "2.11.4"
    # And the comparison must still SEE a real gap.
    st "a real gap survives normalisation" \
        "$([ "$(norm 'v5.3.1-mainnet')" = "$(norm 'v5.6.0')" ] && echo same || echo differs)" "differs"
    # The two halves of an image pin.
    st "the digest half is extracted" "$(pinned_digest 'caddy:2.11.4@sha256:beef')" "sha256:beef"
    st "the tag half is extracted" "$(image_ref 'caddy:2.11.4@sha256:beef')" "caddy:2.11.4"
    st "a plain version pin has no digest half" "$(pinned_digest 'v4.16')" ""
    # UNREACHABLE MUST NOT READ AS CURRENT — the defect this whole script is aimed at.
    st "a release lookup that cannot run fails" \
        "$(gh() { return 1; }; latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed)" "failed"
    st "a non-version tag is refused, not compared" \
        "$(gh() { printf 'nightly'; }; latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed)" "failed"
    [ "$st_fail" = 0 ] && echo "pin-watch self-test OK"
    exit "$st_fail"
fi

# --- the report ----------------------------------------------------------------------------------

# Sourcing only defines the functions; release.sh guards its main() behind a BASH_SOURCE check.
# shellcheck source=/dev/null
(return 0 2>/dev/null) || true
set -- # release.sh's arg parser must not see ours
# shellcheck disable=SC1091
source "$ROOT/scripts/release.sh"

# The appliance rootfs COMPILES two more binaries from source, and dependabot has no ecosystem for
# an ARG consumed by wget — so nothing else can see them. They exist on the appliance lane only,
# hence the guard: on `develop` this loop is simply shorter, not wrong.
#
# BOUNDARY, stated because a silent one is what this whole issue is about: GitHub runs `schedule:`
# from the DEFAULT branch, so this only ever reads `develop`. The appliance lane's own pins stay
# unwatched until this script reaches `develop-v2` at the next twin sync. The report says so.
components="monero p2pool xmrig-proxy tari caddy socket-proxy"
[ -f "$ROOT/os/rootfs/Dockerfile" ] && components="$components compose cosign"

# release.sh's pin() is the one place pins are read from the tree; the two rootfs binaries have no
# case there because a release does not bundle them.
tree_pin() {
    case "$1" in
    compose) sed -n 's/^ARG COMPOSE_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    cosign) sed -n 's/^ARG COSIGN_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    *) pin "$1" ;;
    esac
}

failed=0
stale=0
rows=""

row() { rows="${rows}| $1 | $2 | $3 | $4 |"$'\n'; }

for component in $components; do
    raw=$(tree_pin "$component" 2>/dev/null) || raw=""
    if [ -z "$raw" ]; then
        row "$component" "—" "—" "**could not read the pin from the tree**"
        failed=$((failed + 1))
        continue
    fi
    repo=$(upstream_for "$component")
    if ! latest=$(latest_release "$repo"); then
        row "$component" "\`$(norm "$raw")\`" "—" "**upstream lookup failed — NOT checked**"
        failed=$((failed + 1))
        continue
    fi
    if [ "$(norm "$raw")" = "$(norm "$latest")" ]; then
        verdict="current"
    else
        verdict="**stale** → \`$latest\`"
        stale=$((stale + 1))
    fi
    row "$component" "\`$(norm "$raw")\`" "\`$(norm "$latest")\`" "$verdict"
done

printf '%s\n\n' "Upstream currency, checked weekly by \`scripts/pin-watch.sh\`. This never bumps anything."
printf '| component | pinned | upstream latest | |\n|---|---|---|---|\n%s\n' "$rows"
printf '%s\n' "Not watched here, because they publish no GitHub release feed: the alpine base image, \`ubuntu:24.04\`, \`python:3.11-slim\`. Dependabot's docker ecosystem reads those \`FROM\` lines and does cover them."
[ -f "$ROOT/os/rootfs/Dockerfile" ] || printf '%s\n' "The appliance lane's own pins (the rootfs docker-compose and cosign) are NOT in this table: a scheduled workflow only ever reads the default branch, and this script is not on \`develop-v2\` yet."
printf '%s\n' "Also NOT checked: whether each image pin's digest still corresponds to its tag. The digest is what actually runs, so a half-done bump is invisible to the table above."
if [ "$failed" -gt 0 ]; then
    printf '\n%s\n' "**$failed lookup(s) could not run — those rows are unchecked, not current.**"
else
    printf '\n%s\n' "_Last fully successful check: $(date -u '+%Y-%m-%d %H:%M UTC')_"
fi
printf '\n%s\n' "<!-- pin-watch: stale=$stale failed=$failed -->"

exit "$([ "$failed" -gt 0 ] && echo 1 || echo 0)"
