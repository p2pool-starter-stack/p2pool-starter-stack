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
    rigforge) echo p2pool-starter-stack/rigforge ;;
    esac
}

# Our pins do not spell versions the way upstream tags them, and this is the part that decides
# whether the watcher is useful or muted: `caddy:2.11.4` vs `v2.11.4` and `xmrig-proxy 6.26.0` vs
# `v6.26.0` are CURRENT, and `minotari_node:v5.3.1-mainnet` vs `v5.6.0` is stale. A plain string
# comparison calls the first two stale every week for ever, and a watcher that cries wolf weekly
# gets ignored — exactly as useless as one that never runs.
#
# Strips, in order: a digest suffix, an image name up to the last colon, a leading `v`, and a
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

# The one lookup, wrapped so a failure is a COUNTED failure and never a quiet "current".

latest_release() { # <owner/repo> -> tag on stdout, rc 1 on any failure
    local tag
    tag=$(gh api "repos/$1/releases/latest" --jq .tag_name 2>/dev/null) || return 1
    # Third-party input. A tag that is not shaped like a version must not be compared, printed into
    # an issue body, or otherwise trusted.
    printf '%s' "$tag" | grep -qE '^v?[0-9]' || return 1
    printf '%s' "$tag"
}

# Every pin above spells a VERSION, so the release tag is directly comparable to it. RIGFORGE_REF
# does not: os/rootfs/Dockerfile pins rigforge by COMMIT so that a moved tag cannot change the bake,
# and comparing a sha against `v1.16.0` reads **stale** every week for ever — including the hour
# after a correct bump. That is a different lie from the silence this row was added to end, not a
# fix for it. So the tag is resolved to the commit it names, with the same idiom this script already
# prints in its _COMMIT warning below, and the comparison is sha against sha.
#
# The resolution is a SECOND network call, and it gets the first one's treatment: a failure returns
# rc 1 so the caller renders an unchecked row. MEASURED with both refusals removed, so this names the
# real failure rather than the one it is tempting to assume: the fall-through is not a wrong verdict
# but a CONFIDENT one — the row reads `stale`, `failed` stays 0, the run exits 0 and stamps itself
# fully successful. A watcher that has stopped working then looks exactly like one with nothing to
# report, which is the defect this script's own header says it exists to prevent.

comparable() { # <component> <owner/repo> <tag> -> the tag in that pin's spelling, rc 1 on failure
    local sha
    case "$1" in
    rigforge)
        sha=$(gh api "repos/$2/commits/$3" --jq .sha 2>/dev/null) || return 1
        # Third-party input, under the same rule as the tag itself: a value that is not shaped like
        # a commit must not be compared, and must not be printed into an issue body.
        printf '%s' "$sha" | grep -qE '^[0-9a-f]{40}$' || return 1
        printf '%s' "$sha"
        ;;
    *) printf '%s' "$3" ;;
    esac
}

# --- self-test -----------------------------------------------------------------------------------
# The comparison logic is the whole product here; the lookup itself is one `gh api` call. Drives
# norm() over the real pin spellings, and both of the lookup's refusal paths over a stubbed `gh`.
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
    # UNREACHABLE MUST NOT READ AS CURRENT — the defect this whole script is aimed at.
    st "a release lookup that cannot run fails" \
        "$(
            gh() { return 1; }
            latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed
        )" "failed"
    st "a non-version tag is refused, not compared" \
        "$(
            gh() { printf 'nightly'; }
            latest_release foo/bar >/dev/null 2>&1 && echo ok || echo failed
        )" "failed"
    # A COMMIT pin cannot be compared against a TAG. What follows covers the resolution that
    # makes the rigforge row honest, and the property the sha comparison rests on.
    st "an upstream tag resolves to the commit it names" \
        "$(
            gh() { printf '%s' 4ce29b3daf063fd1b45e050649e93aa9592618e1; }
            comparable rigforge foo/bar v1.16.0
        )" "4ce29b3daf063fd1b45e050649e93aa9592618e1"
    # The issue's own requirement: a resolution that cannot run reaches the unchecked row rather than
    # any verdict at all. It is not uniquely load-bearing — see the overlap note on the next case but one.
    st "a commit resolution that cannot run fails" \
        "$(
            gh() { return 1; }
            comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
        )" "failed"
    # The two refusals below overlap on every realistic input, and a mutation round proved it: with
    # the `|| return 1` removed, this next case still failed — because an empty `sha` fails the shape
    # check too, so the shape guard silently covered for the exit-code guard's deletion. Each is now
    # pinned on the one input only IT refuses. This one is the exit code being trusted over stdout.
    st "a resolution that exits non-zero is refused even when it printed a commit" \
        "$(
            gh() {
                printf '%s' 4ce29b3daf063fd1b45e050649e93aa9592618e1
                return 1
            }
            comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
        )" "failed"
    st "an answer that is not shaped like a commit is refused, not compared" \
        "$(
            gh() { printf 'Not Found'; }
            comparable rigforge foo/bar v1.16.0 >/dev/null 2>&1 && echo ok || echo failed
        )" "failed"
    # And every version-spelled pin is still compared against the tag itself, unresolved.
    st "a version pin is compared against the tag, with no lookup at all" \
        "$(comparable caddy caddyserver/caddy v2.11.4)" "v2.11.4"
    # Both sides of that comparison go through norm(), so norm must leave a commit sha untouched.
    st "normalisation leaves a commit sha alone" \
        "$(norm 60aa883901fc74ea39ed2f21962b8ba7f96d73ba)" "60aa883901fc74ea39ed2f21962b8ba7f96d73ba"
    [ "$st_fail" = 0 ] && echo "pin-watch self-test OK"
    exit "$st_fail"
fi

# --- the report ----------------------------------------------------------------------------------

# Sourcing only defines the functions; release.sh guards its main() behind a BASH_SOURCE check.
# shellcheck source=/dev/null
set -- # release.sh's arg parser must not see ours
# shellcheck disable=SC1091
source "$ROOT/scripts/release.sh"

# The appliance rootfs builds three more things from an `ARG` — two binaries compiled from source
# and the RigForge tree fetched as a source tarball — and dependabot has no ecosystem for an ARG
# consumed by a download, so nothing else can see any of them. They exist on the appliance lane
# only, hence the guard: on `develop` this loop is simply shorter, not wrong.
#
# BOUNDARY, stated because a silent one is what this whole issue is about: GitHub runs `schedule:`
# from the DEFAULT branch, so a single-job workflow only ever reads `develop` and these two rows
# are simply absent from a run that looks complete (#1146). pin-watch.yml therefore runs this
# script TWICE — once on the triggering ref, once against an explicit `develop-v2` checkout — and
# publishes the two reports to two separate tracking issues. The report below says which it is.
components="monero p2pool xmrig-proxy tari caddy socket-proxy"
lane="the product stack"
# A real `if`, for the same reason the publish step in pin-watch.yml uses one: `[ -f X ] && var=…`
# evaluates to 1 on the develop lane, which is only safe while nothing depends on the exit status.
if [ -f "$ROOT/os/rootfs/Dockerfile" ]; then
    components="$components compose cosign rigforge"
    lane="the product stack and the appliance rootfs"
fi

# release.sh's pin() is the one place pins are read from the tree; the three rootfs `ARG`s have no
# case there because a release does not bundle them.
tree_pin() {
    case "$1" in
    compose) sed -n 's/^ARG COMPOSE_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    cosign) sed -n 's/^ARG COSIGN_VERSION=//p' "$ROOT/os/rootfs/Dockerfile" ;;
    rigforge) sed -n 's/^ARG RIGFORGE_REF=//p' "$ROOT/os/rootfs/Dockerfile" ;;
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
    # A resolution failure is its own row, with its own sentence. Sharing the string above would
    # let either guard silently cover for the other's deletion, which this repo has already shipped
    # once. The tag IS known here, so it is still reported — only the verdict is withheld.
    if ! cmp_to=$(comparable "$component" "$repo" "$latest"); then
        row "$component" "\`$(norm "$raw")\`" "\`$(norm "$latest")\`" "**upstream tag could not be resolved to a commit — NOT checked**"
        failed=$((failed + 1))
        continue
    fi
    if [ "$(norm "$raw")" = "$(norm "$cmp_to")" ]; then
        verdict="current"
    else
        verdict="**stale** → \`$latest\`"
        stale=$((stale + 1))
    fi
    row "$component" "\`$(norm "$raw")\`" "\`$(norm "$latest")\`" "$verdict"
done

printf '%s\n\n' "Upstream currency for $lane, checked weekly by \`scripts/pin-watch.sh\`. This never bumps anything."
printf '| component | pinned | upstream latest | |\n|---|---|---|---|\n%s\n' "$rows"
printf '%s\n' "Not watched here, because they publish no GitHub release feed: the alpine base image, \`ubuntu:24.04\`, \`python:3.11-slim\`. Dependabot's docker ecosystem reads those \`FROM\` lines and does cover them."
# Both arms, so this file stops being a twin-sync conflict: `develop-v2` had already turned this
# line into an if/else to carry the _COMMIT warning below, and a competing one-line rewrite here
# would collide with it on every sync. The appliance arm is dead code on `develop` and correct on
# `develop-v2`, which is the point.
if [ -f "$ROOT/os/rootfs/Dockerfile" ]; then
    # The rootfs COMPILES these two from source on a pinned Go toolchain rather than downloading a
    # release binary, so each carries a paired _COMMIT ARG and the VERSION alone decides nothing.
    # Bumping the version and leaving the commit still builds the old code — the same half-done bump
    # #1137 describes for image digests. (This warning came from the appliance-lane watcher this
    # script replaced; the fact outlived the file.)
    printf '%s\n' "\`compose\` and \`cosign\` are compiled from source in \`os/rootfs/Dockerfile\`, so each bump is TWO ARGs — the version AND its paired \`_COMMIT\`. Resolve the commit with \`gh api repos/<owner>/<repo>/commits/<tag> --jq .sha\`; bumping the version alone still builds the old code."
    # RIGFORGE_REF is the opposite spelling and needs the same idiom pointed the other way: the
    # table resolves the tag to a commit to reach its verdict, and whoever acts on a stale row has
    # to write that commit into the ARG. Saying which commit here saves them repeating the lookup.
    printf '%s\n' "\`RIGFORGE_REF\` pins a COMMIT, not a tag, so a moved tag cannot change the bake. The row above compares it against the commit its latest release points at; to bump it, write that commit — \`gh api repos/p2pool-starter-stack/rigforge/commits/<tag> --jq .sha\` — into \`ARG RIGFORGE_REF\`, release by release."
else
    printf '%s\n' "The appliance rootfs's own pins (its docker-compose, cosign and baked RigForge tree, all built from \`ARG\` values that no dependabot ecosystem can read) are NOT in this table. They are in the appliance report, which the same workflow run produces from an explicit \`develop-v2\` checkout (#1146)."
fi
printf '%s\n' "Also NOT checked: whether each image pin's digest still corresponds to its tag. The digest is what actually runs, so a half-done bump is invisible to the table above."
if [ "$failed" -gt 0 ]; then
    printf '\n%s\n' "**$failed lookup(s) could not run — those rows are unchecked, not current.**"
else
    printf '\n%s\n' "_Last fully successful check: $(date -u '+%Y-%m-%d %H:%M UTC')_"
fi
printf '\n%s\n' "<!-- pin-watch: stale=$stale failed=$failed -->"

exit "$([ "$failed" -gt 0 ] && echo 1 || echo 0)"
