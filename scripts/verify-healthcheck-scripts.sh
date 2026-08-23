#!/usr/bin/env bash
#
# Every script-based healthcheck docker-compose.yml names must actually exist in the image its
# own service builds (#1098).
#
# #1098: the appliance shipped a docker-compose.yml (baked from the development tree, at whatever
# commit os/build-image.sh happened to run against) naming
# /usr/local/bin/xmrig-proxy-healthcheck.sh, while the images it pins (STACK_VERSION resolves to
# the last-released tag, not the tree's HEAD) predated the script — added together in one commit,
# #904, but read from two places that can fall out of step. The container reported unhealthy
# forever with nothing actually broken. Nothing caught it because nothing compared the two halves
# of that commit against each other again later, once time (and an unrelated VERSION bump cadence)
# had put daylight between them.
#
# This is the narrower, permanent half of the fix: docker-compose.yml and each first-party
# service's own Dockerfile are two files in the SAME tree, so whether the Dockerfile's build
# actually places a script at the path compose's healthcheck names is knowable by reading both —
# no docker build, no registry, no bench. Checked on every PR, it makes "the compose CMD outruns
# the Dockerfile COPY" a same-commit failure instead of a runtime-only, appliance-only symptom.
# It does NOT, by itself, catch the STACK_VERSION/release-cadence skew #1098 actually shipped with
# (that needs a real pulled image at the pinned tag, which this script never has) — see the
# xmrig-proxy healthcheck's own CMD-SHELL fallback (docker-compose.yml) for the remedy that does.
#
# Usage:
#   scripts/verify-healthcheck-scripts.sh              Check docker-compose.yml against the tree.
#                                                        rc 1 on any healthcheck script the
#                                                        matching Dockerfile never places there.
#   scripts/verify-healthcheck-scripts.sh --self-test   Drive the parsers against fixtures,
#                                                        including the #1098 mutation. No docker.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Print "svc|build|path" for every *.sh absolute path found in a healthcheck `test` value's raw
# text. Shared by both compose spellings of `test:` below — a flow sequence (`test: ["CMD", "/p"]`)
# and a block list (`test:` / `  - CMD` / `  - "/p"`) collapse to the same joined text once their
# items are concatenated, so only one extractor is needed for either shape.
emit_healthcheck_targets() { # <svc> <build> <test-value-text>
    local svc="$1" build="$2" body="$3" path
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        printf '%s|%s|%s\n' "$svc" "$build" "$path"
    done < <(grep -oE '/[A-Za-z0-9_./-]+\.sh' <<<"$body" || true)
}

# Every CMD/CMD-SHELL healthcheck naming a *.sh path, alongside the service's own build context —
# read straight off the raw compose YAML (no `docker compose config` needed: none of this is
# templated, so the file on disk already carries the literal answer). One "service|build-ctx|path"
# line per (service, script) pair; a CMD-SHELL fallback that mentions the same path twice (the
# xmrig-proxy remedy below) collapses to one line via sort -u by the caller.
#
# Deliberately line-oriented rather than a real YAML parse: `services:` entries sit at 2-space
# indent, their own keys at 4, `build:`'s own `context:` at 6 when it's a block — the same shape
# every service in this file already uses, so a state machine over those three indents is exact
# for this file without pulling in a YAML library.
#
# `test:` itself has TWO valid YAML spellings and this tree is not guaranteed to only ever use
# one of them: the flow sequence every current service happens to use (`test: ["CMD", "/p"]`),
# and the block-list form (`test:` on its own line, then `  - CMD` / `  - "/p"` beneath it) —
# equally valid YAML, equally something `docker compose config` accepts today. A parser that only
# recognises the flow form makes a block-list healthcheck silently INVISIBLE to this whole check:
# not a parse error, not a red — the service just never appears in the extraction, so a missing
# script under the block-list spelling passes as if nothing needed checking at all.
extract_healthcheck_targets() { # <compose-file>
    local f="$1" line svc="" build="" in_build_block=0
    local collecting=0 collect_body=""
    while IFS= read -r line; do
        # Mid-collection: an item line is consumed here, before any other check runs, so a list
        # item that happens to look like a key (e.g. "- interval: 30s" never occurs, but a bare
        # "- /usr/local/bin/x.sh" must not be mistaken for a new service/key). A non-item line ends
        # the list — flush what was collected, then fall through: that same line may be the next
        # sibling key ("interval: 30s") or, after a dedent, a brand new service header, and both
        # still need the checks below to see it.
        if [ "$collecting" -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]](.*)$ ]]; then
                local item="${BASH_REMATCH[1]}"
                item="${item%\"}"
                item="${item#\"}"
                item="${item%\'}"
                item="${item#\'}"
                collect_body="$collect_body $item"
                continue
            fi
            emit_healthcheck_targets "$svc" "$build" "$collect_body"
            collecting=0
            collect_body=""
        fi
        if [[ "$line" =~ ^\ \ ([A-Za-z0-9_-]+):[[:space:]]*$ ]]; then
            svc="${BASH_REMATCH[1]}"
            build=""
            in_build_block=0
            continue
        fi
        [ -n "$svc" ] || continue
        if [[ "$line" =~ ^\ \ \ \ build:\ (\./[^[:space:]]+)[[:space:]]*$ ]]; then
            build="${BASH_REMATCH[1]}"
            in_build_block=0
            continue
        fi
        if [[ "$line" =~ ^\ \ \ \ build:[[:space:]]*$ ]]; then
            in_build_block=1
            continue
        fi
        if [ "$in_build_block" -eq 1 ]; then
            if [[ "$line" =~ ^\ \ \ \ \ \ context:\ (\./[^[:space:]]+)[[:space:]]*$ ]]; then
                build="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^\ \ \ \ [A-Za-z_]+: ]]; then
                in_build_block=0
            fi
        fi
        # Only services this tree actually builds carry a Dockerfile to check against — a pulled
        # third-party image (tari, caddy, the socket proxies) has none in this repo.
        [ -n "$build" ] || continue
        if [[ "$line" =~ ^[[:space:]]+test:\ \[(.*)\][[:space:]]*$ ]]; then
            emit_healthcheck_targets "$svc" "$build" "${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]+test:[[:space:]]*$ ]]; then
            collecting=1
            collect_body=""
            continue
        fi
    done <"$f"
    # EOF while still collecting (a block list as the file's last lines) must flush too.
    [ "$collecting" -eq 1 ] && emit_healthcheck_targets "$svc" "$build" "$collect_body"
    return 0
}

# Does <dockerfile>'s own build actually place a file at <target-abs-path>? Tracks WORKDIR (COPY's
# relative destinations resolve against it) and every COPY's [src...] dest — a multi-source COPY
# into a directory (dest is "." / "./" / ends in "/") checks each source's basename; a single-source
# COPY to an exact absolute filename is a rename and checks that literal path. `COPY --from=stage`
# lines are handled the same way — the source stage doesn't matter, only where THIS build's COPY
# lands the file, which is what compose's healthcheck actually runs against.
dockerfile_provides_path() { # <dockerfile> <target-abs-path>
    local df="$1" target="$2" cwd="/" line
    [ -f "$df" ] || return 1
    while IFS= read -r line; do
        if [[ "$line" =~ ^WORKDIR[[:space:]]+(.+)$ ]]; then
            local wd="${BASH_REMATCH[1]}"
            case "$wd" in
            /*) cwd="$wd" ;;
            *) cwd="${cwd%/}/$wd" ;;
            esac
            continue
        fi
        [[ "$line" =~ ^COPY[[:space:]]+(.+)$ ]] || continue
        local rest="${BASH_REMATCH[1]}" tok toks=()
        for tok in $rest; do
            case "$tok" in
            --*) ;; # --from=, --chown=, ... — never a source or destination
            *) toks+=("$tok") ;;
            esac
        done
        local n=${#toks[@]}
        [ "$n" -ge 2 ] || continue
        local dest="${toks[$((n - 1))]}" i
        for ((i = 0; i < n - 1; i++)); do
            local src="${toks[$i]}" base resolved
            base="$(basename "$src")"
            case "$dest" in
            ./ | .) resolved="${cwd%/}/${base}" ;; # cwd-relative, this build's WORKDIR — checked
            # before the general directory case below, since "./" also ends in "/" and would
            # otherwise match there first and skip the WORKDIR resolution entirely.
            */) resolved="${dest}${base}" ;; # explicit directory (abs or rel, not "./"/".")
            /*)
                if [ "$n" -eq 2 ]; then resolved="$dest"; else resolved="${dest%/}/${base}"; fi
                ;;                                       # single-src abs = rename; else a dir
            *) resolved="${cwd%/}/${dest#./}/${base}" ;; # other relative dest = a dir under cwd
            esac
            [ "$resolved" = "$target" ] && return 0
        done
    done <"$df"
    return 1
}

# Every target, checked. Prints one line per pair as it goes, mirrors resolve-pins.sh's shape.
run_check() { # <compose-file> <repo-root>
    local compose_file="$1" root="$2" line svc build path failed=0 seen=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        seen=$((seen + 1))
        svc="${line%%|*}"
        line="${line#*|}"
        build="${line%%|*}"
        path="${line#*|}"
        if dockerfile_provides_path "$root/${build#./}/Dockerfile" "$path"; then
            printf 'present: %s names %s, and %s/Dockerfile places it there\n' "$svc" "$path" "$build"
        else
            printf 'MISSING: %s names healthcheck %s, but %s/Dockerfile never COPYs a file there — this container will report unhealthy forever, not because it is broken.\n' \
                "$svc" "$path" "$build"
            failed=$((failed + 1))
        fi
    done < <(extract_healthcheck_targets "$compose_file" | sort -u)
    # As with resolve-pins.sh: a zero count is a broken extraction, not a clean bill. This file has
    # carried script-based healthchecks since #904 across five first-party services; an empty
    # result means the parser stopped matching the compose file's shape, not that there is nothing
    # to check.
    if [ "$seen" -eq 0 ]; then
        printf 'NO HEALTHCHECK SCRIPTS FOUND: %s yielded no script-based CMD/CMD-SHELL healthchecks on a built service. The extraction no longer matches the file, so nothing was checked — this is a broken gate, not a clean one.\n' "$compose_file"
        return 1
    fi
    if [ "$failed" -gt 0 ]; then
        printf '\n%s healthcheck script(s) named in docker-compose.yml but missing from the image their own service builds.\n' "$failed"
        return 1
    fi
    printf '\nEvery script-based healthcheck names a file its own Dockerfile actually places in the image.\n'
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

    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    # --- dockerfile_provides_path -------------------------------------------------------------
    cat >"$WORK/single-src.Dockerfile" <<'EOF'
FROM ubuntu:24.04
COPY healthcheck.sh /usr/local/bin/xmrig-proxy-healthcheck.sh
RUN chmod +x /usr/local/bin/xmrig-proxy-healthcheck.sh
EOF
    if dockerfile_provides_path "$WORK/single-src.Dockerfile" "/usr/local/bin/xmrig-proxy-healthcheck.sh"; then r=0; else r=1; fi
    st "single-source absolute-rename COPY is found" "$r" "0"

    # THE #1098 MUTATION, named per the issue: rename the Dockerfile's OWN destination and leave
    # compose untouched. This must go RED — that gap, undetected, is the whole bug.
    cat >"$WORK/renamed.Dockerfile" <<'EOF'
FROM ubuntu:24.04
COPY healthcheck.sh /usr/local/bin/xmrig-proxy-healthcheck-renamed.sh
RUN chmod +x /usr/local/bin/xmrig-proxy-healthcheck-renamed.sh
EOF
    if dockerfile_provides_path "$WORK/renamed.Dockerfile" "/usr/local/bin/xmrig-proxy-healthcheck.sh"; then r=0; else r=1; fi
    st "#1098 mutation: a Dockerfile rename with compose unchanged is caught" "$r" "1"

    # WORKDIR + multi-source relative COPY (the dashboard's own shape: WORKDIR /app then
    # `COPY entrypoint.sh healthcheck.sh ./`).
    cat >"$WORK/workdir.Dockerfile" <<'EOF'
FROM python:3.13-slim
WORKDIR /app
COPY entrypoint.sh healthcheck.sh ./
EOF
    if dockerfile_provides_path "$WORK/workdir.Dockerfile" "/app/healthcheck.sh"; then r=0; else r=1; fi
    st "WORKDIR-relative multi-source COPY is found" "$r" "0"
    if dockerfile_provides_path "$WORK/workdir.Dockerfile" "/app/entrypoint.sh"; then r=0; else r=1; fi
    st "WORKDIR-relative multi-source COPY finds every source, not just the last" "$r" "0"
    if dockerfile_provides_path "$WORK/workdir.Dockerfile" "/app/nonexistent.sh"; then r=0; else r=1; fi
    st "a path nothing COPYs is not found" "$r" "1"

    # A COPY --from=<stage> still lands where its destination says.
    cat >"$WORK/multistage.Dockerfile" <<'EOF'
FROM golang:1.26 AS build
RUN true
FROM debian:trixie-slim
COPY --from=build /out/tool /usr/local/bin/tool-healthcheck.sh
EOF
    if dockerfile_provides_path "$WORK/multistage.Dockerfile" "/usr/local/bin/tool-healthcheck.sh"; then r=0; else r=1; fi
    st "COPY --from=stage resolves by destination, not source stage" "$r" "0"

    # --- extract_healthcheck_targets -------------------------------------------------------
    cat >"$WORK/compose.yml" <<'EOF'
services:
  tari:
    image: quay.io/tarilabs/minotari_node:v5.3.1-mainnet
    healthcheck:
      test: ["CMD-SHELL", "ps | grep '[m]inotari_node' || exit 1"]

  xmrig-proxy:
    build: ./build/xmrig-proxy
    healthcheck:
      test: ["CMD", "/usr/local/bin/xmrig-proxy-healthcheck.sh"]

  dashboard:
    build:
      context: ./dashboard
      args:
        FOO: bar
    healthcheck:
      test: ["CMD", "/app/healthcheck.sh"]

  caddy:
    image: caddy:2.11.4
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "-T", "5", "http://127.0.0.1:2019/config/"]

  foo-blocklist:
    build: ./build/foo-blocklist
    healthcheck:
      test:
        - CMD
        - "/usr/local/bin/foo-healthcheck.sh"
EOF
    targets="$(extract_healthcheck_targets "$WORK/compose.yml" | sort)"
    st "tari (no build:, no .sh) contributes nothing" "$(grep -c '^tari|' <<<"$targets" || true)" "0"
    st "caddy's wget probe (no .sh path, no build:) contributes nothing" "$(grep -c '^caddy|' <<<"$targets" || true)" "0"
    st "xmrig-proxy's inline build: form is read" "$(grep -c '^xmrig-proxy|\./build/xmrig-proxy|/usr/local/bin/xmrig-proxy-healthcheck\.sh$' <<<"$targets" || true)" "1"
    st "dashboard's block build:/context: form is read" "$(grep -c '^dashboard|\./dashboard|/app/healthcheck\.sh$' <<<"$targets" || true)" "1"
    # THE PARSER-GAP mutation: a block-list `test:` (quoted item, on its own lines rather than a
    # flow sequence) is equally valid compose YAML. A parser that only recognises `test: [...]`
    # makes this service invisible to the whole check — not a red, just silently unchecked.
    st "block-list test: form (positive) is read" "$(grep -c '^foo-blocklist|\./build/foo-blocklist|/usr/local/bin/foo-healthcheck\.sh$' <<<"$targets" || true)" "1"

    # A second compose file, block-list form, whose script the Dockerfile does NOT provide — the
    # missing-script half of the same gap. Kept separate from $WORK/compose.yml above so the
    # "fully consistent tree passes" assertion below stays about a tree that really is consistent.
    cat >"$WORK/compose-blocklist-missing.yml" <<'EOF'
services:
  bar-blocklist:
    build: ./build/bar-blocklist
    healthcheck:
      test:
        - CMD
        - /usr/local/bin/bar-healthcheck.sh
EOF
    mkdir -p "$WORK/build/bar-blocklist"
    cat >"$WORK/build/bar-blocklist/Dockerfile" <<'EOF'
FROM ubuntu:24.04
COPY healthcheck.sh /usr/local/bin/some-other-name.sh
EOF
    if out="$(run_check "$WORK/compose-blocklist-missing.yml" "$WORK" 2>&1)"; then rc=0; else rc=$?; fi
    st "block-list form with a missing script is caught by run_check: RED" "$rc" "1"
    st "the block-list miss is named, not swallowed" "$(grep -c '^MISSING: bar-blocklist' <<<"$out")" "1"

    # --- run_check end to end, mirroring the real tree's shape -----------------------------
    mkdir -p "$WORK/build/xmrig-proxy" "$WORK/dashboard" "$WORK/build/foo-blocklist"
    printf 'FROM ubuntu:24.04\nCOPY healthcheck.sh /usr/local/bin/foo-healthcheck.sh\n' >"$WORK/build/foo-blocklist/Dockerfile"
    cp "$WORK/single-src.Dockerfile" "$WORK/build/xmrig-proxy/Dockerfile"
    cp "$WORK/workdir.Dockerfile" "$WORK/dashboard/Dockerfile"
    if out="$(run_check "$WORK/compose.yml" "$WORK" 2>&1)"; then rc=0; else rc=$?; fi
    st "a fully consistent tree passes" "$rc" "0"

    cp "$WORK/renamed.Dockerfile" "$WORK/build/xmrig-proxy/Dockerfile"
    if out="$(run_check "$WORK/compose.yml" "$WORK" 2>&1)"; then rc=0; else rc=$?; fi
    st "#1098 mutation reproduced end to end through run_check: RED" "$rc" "1"
    st "the miss is named, not swallowed" "$(grep -c '^MISSING: xmrig-proxy' <<<"$out")" "1"

    cp "$WORK/single-src.Dockerfile" "$WORK/build/xmrig-proxy/Dockerfile"
    if out="$(run_check "$WORK/compose.yml" "$WORK" 2>&1)"; then rc=0; else rc=$?; fi
    st "restoring the Dockerfile turns it back GREEN" "$rc" "0"

    # A compose file with no script-based healthchecks at all must fail loudly, not pass vacuously
    # (#1069's whole genus, same as resolve-pins.sh's own zero-pins guard).
    cat >"$WORK/empty-compose.yml" <<'EOF'
services:
  tari:
    image: quay.io/tarilabs/minotari_node:v5.3.1-mainnet
    healthcheck:
      test: ["CMD-SHELL", "ps | grep '[m]inotari_node' || exit 1"]
EOF
    if out="$(run_check "$WORK/empty-compose.yml" "$WORK" 2>&1)"; then rc=0; else rc=$?; fi
    st "zero script healthchecks found fails loudly, never passes vacuously" "$rc" "1"
    st "the empty extraction is named" "$(grep -c 'NO HEALTHCHECK SCRIPTS FOUND' <<<"$out")" "1"

    if [ "$st_fail" = 0 ]; then
        echo "verify-healthcheck-scripts self-test OK"
    fi
    exit "$st_fail"
fi

# --- the check -------------------------------------------------------------------------------
compose_file="$ROOT/docker-compose.yml"
[ -f "$compose_file" ] || {
    echo "verify-healthcheck-scripts: docker-compose.yml not found at $compose_file" >&2
    exit 1
}

run_check "$compose_file" "$ROOT"
