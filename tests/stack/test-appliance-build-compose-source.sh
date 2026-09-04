# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The compose file an appliance image ships comes from the release it names, not the tree (#1215).
# Every `image:` in docker-compose.yml is pinned by STACK_VERSION, which the appliance derives from
# its baked VERSION, so a tree ahead of that release bakes a compose file assuming image content the
# pinned tags predate (#1098: a healthcheck script the published image did not carry). build-image's
# stage_compose takes the file from the tag `v<VERSION>` when that tag exists, from the tree while
# it does not (the release being prepared), and refuses the one silent case — a clone that has the
# tag on origin but never fetched it. verify-image's compose_reference reads the COMPOSE_SOURCE stamp
# the build writes and resolves the file the shipped one must equal, refusing a stamp that is
# missing, malformed, names another version than the shipped VERSION, or names a commit the
# checkout lacks. Both helpers sit above their script's test seam and are driven here against a
# scratch git repo: no docker, no image, no network (the refuse case's "origin" is a local bare
# repo). Sourced by tests/stack/run.sh.

echo "== unit: build-image stage_compose — the compose file comes from the STACK_VERSION tag, else the tree (#1215) =="
CS="$SANDBOX/compose-source"
rm -rf "$CS"
mkdir -p "$CS"
# A repo whose tagged compose file differs from its working-tree one, so the two sources are
# distinguishable by content, and a bare "origin" that holds a tag the clone deliberately lacks.
cs_repo() {
    (
        cd "$CS" || exit 1
        git -c init.defaultBranch=main init -q origin.git --bare
        git -c init.defaultBranch=main init -q repo
        cd repo || exit 1
        git remote add origin ../origin.git
        printf 'services:\n  a:\n    image: x:${STACK_VERSION:-dev}\n' >docker-compose.yml
        git add docker-compose.yml
        git -c user.email=t@t -c user.name=t commit -q -m "release compose"
        git tag v0.0.1
        git -c user.email=t@t -c user.name=t tag -a v0.0.2 -m "on origin only"
        git push -q origin v0.0.1 v0.0.2
        git tag -d v0.0.2 >/dev/null
        printf 'services:\n  a:\n    image: x:${STACK_VERSION:-dev}\n    healthcheck: {test: [CMD, true]}\n' >docker-compose.yml
    )
}
cs_repo
cs_stage() { # <tag> <dir> -> stdout+stderr of stage_compose, then "rc=N"
    (
        tag="$1" dir="$2"
        export PITHEAD_BUILD_IMAGE_TEST=1
        set -- # `source file` with no args keeps the caller's $@ — clear it so build-image.sh's
        # own arg loop does not parse the tag as a CLI flag.
        # shellcheck disable=SC1091  # path is dynamic by design
        source "$ROOT/os/build-image.sh"
        set +e # build-image.sh sets -e for itself; the refusal's rc is the thing under test here
        cd "$CS/repo" || exit 1
        stage_compose "$tag" "$dir" 2>&1
        echo "rc=$?"
    )
}
CS_SHA=$(git -C "$CS/repo" rev-parse v0.0.1)
cs_out=$(cs_stage v0.0.1 "$CS/tagged")
assert_contains "a present tag is staged, and the line names the tag AND its commit" "$cs_out" "tag v0.0.1 $CS_SHA"
assert_contains "the tag path exits 0" "$cs_out" "rc=0"
assert_eq "the staged file is the TAG's compose file, not the tree's" \
    "$(cat "$CS/tagged/docker-compose.yml")" "$(git -C "$CS/repo" show v0.0.1:docker-compose.yml)"
assert_not_contains "the tree's newer compose content did not leak into the staged file" \
    "$(cat "$CS/tagged/docker-compose.yml")" "healthcheck"
assert_eq "the stamp file carries the same line the build prints" "$(cat "$CS/tagged/COMPOSE_SOURCE")" "tag v0.0.1 $CS_SHA"

cs_out=$(cs_stage v0.0.9 "$CS/untagged")
assert_contains "no tag anywhere (the release being prepared) stages the tree and says so" "$cs_out" "tree"
assert_contains "the tree path exits 0" "$cs_out" "rc=0"
assert_eq "the tree path ships the working tree's compose file byte for byte" \
    "$(cat "$CS/untagged/docker-compose.yml")" "$(cat "$CS/repo/docker-compose.yml")"
assert_eq "the tree path's stamp is the bare word" "$(cat "$CS/untagged/COMPOSE_SOURCE")" "tree"

cs_out=$(cs_stage v0.0.2 "$CS/unfetched")
assert_contains "a tag on origin that this clone lacks is REFUSED, not built from the tree" "$cs_out" "rc=1"
assert_contains "the refusal names the tag and the remedy" "$cs_out" "tag v0.0.2 exists on origin but not in this clone"
assert_contains "the remedy is the fetch" "$cs_out" "git fetch --tags"
assert_eq "the refusal stages nothing a later COPY could pick up" "$(ls "$CS/unfetched" 2>/dev/null)" ""

echo "== unit: build-image --stage-only parses, and stops after staging, before the first docker step (#1215) =="
# The CI rootfs scan runs the Dockerfile itself, so it needs the staging without the build. The
# seam returns before the staging line, so the flag's parse is the driven half; the stop is asserted
# by ORDER in the script (static): after the staging echo, before the wizard image is touched.
# Mutation run: drop the case arm -> the parse row goes red; move the stop below the wizard step ->
# the order row goes red.
assert_eq "--stage-only is accepted and recorded" \
    "$( (export PITHEAD_BUILD_IMAGE_TEST=1 && set -- --stage-only && source "$ROOT/os/build-image.sh" && echo "STAGE_ONLY=${STAGE_ONLY:-unset}") 2>&1)" "STAGE_ONLY=1"
bi_line() { grep -n -F -- "$1" "$ROOT/os/build-image.sh" | head -1 | cut -d: -f1; }
l_stage=$(bi_line 'echo "==> compose file staged from: $(stage_compose "$STACK_VERSION" os/build/stage)"')
l_stop=$(bi_line 'if [ "${STAGE_ONLY:-0}" = 1 ]; then')
l_wizard=$(bi_line 'echo "==> staging wizard image $WIZARD_IMAGE"')
assert_eq "the stop sits after the staging line and before the wizard image step" \
    "$([ "${l_stage:-0}" -lt "${l_stop:-0}" ] && [ "${l_stop:-0}" -lt "${l_wizard:-0}" ] && echo ordered)" "ordered"
unset -f bi_line
unset l_stage l_stop l_wizard

echo "== unit: verify-image compose_reference — the stamp names the file the shipped compose must equal (#1215) =="
# A fake image root: only the two files the helper reads. Driven from inside the scratch repo so
# `./docker-compose.yml` and `git show` resolve against it, exactly as verify-image runs.
cs_ref() { # <stamp-line|-> <version> -> "rc=N" then the resolved file's content (if any)
    (
        stamp="$1" ver="$2"
        # shellcheck disable=SC1091  # sourcing defines the helper and returns before the checks
        source "$ROOT/tests/os/verify-image.sh"
        img="$CS/img-$RANDOM"
        mkdir -p "$img/opt/pithead"
        [ "$stamp" = "-" ] || printf '%s\n' "$stamp" >"$img/opt/pithead/COMPOSE_SOURCE"
        printf '%s\n' "$ver" >"$img/opt/pithead/VERSION"
        cd "$CS/repo" || exit 1
        out="$CS/ref-$RANDOM"
        compose_reference "$img" "$out"
        echo "rc=$?"
        cat "$out" 2>/dev/null
    )
}
assert_eq "tree stamp resolves to the working tree's compose file" \
    "$(cs_ref tree 0.0.1)" "rc=0
$(cat "$CS/repo/docker-compose.yml")"
assert_eq "tag stamp resolves to the stamped COMMIT's compose file" \
    "$(cs_ref "tag v0.0.1 $CS_SHA" 0.0.1)" "rc=0
$(git -C "$CS/repo" show v0.0.1:docker-compose.yml)"
assert_eq "a tag stamp for another version than the shipped VERSION is refused" "$(cs_ref "tag v0.0.1 $CS_SHA" 0.0.2)" "rc=1"
assert_eq "a tag stamp naming a commit this checkout lacks is refused" "$(cs_ref "tag v0.0.1 0123456789abcdef0123456789abcdef01234567" 0.0.1)" "rc=1"
assert_eq "a missing stamp is refused" "$(cs_ref - 0.0.1)" "rc=1"
assert_eq "an unknown stamp kind is refused" "$(cs_ref "registry v0.0.1" 0.0.1)" "rc=1"

echo "== wiring: the build stages, the Dockerfile copies, verify-image compares (#1215) =="
# The three scripts cannot be run together at this tier; what CAN be proven is that each end
# speaks the other's path — the shape #1064's guard failed on when the two ends disagreed.
CS_BI="$(cat "$ROOT/os/build-image.sh")"
CS_DF="$(cat "$ROOT/os/rootfs/Dockerfile")"
CS_VI="$(cat "$ROOT/tests/os/verify-image.sh")"
assert_contains "build-image stages into os/build/stage from STACK_VERSION" "$CS_BI" 'stage_compose "$STACK_VERSION" os/build/stage'
assert_contains "the Dockerfile copies the STAGED compose file" "$CS_DF" 'os/build/stage/docker-compose.yml'
assert_contains "the Dockerfile copies the stamp beside it" "$CS_DF" 'os/build/stage/COMPOSE_SOURCE'
assert_not_contains "the Dockerfile no longer copies the tree's compose file" "$CS_DF" 'VERSION docker-compose.yml'
assert_contains "verify-image compares against what the stamp resolves to, not the tree" "$CS_VI" 'compose_reference "$ROOT" "$COMPOSE_REF"'
assert_not_contains "verify-image's old tree comparison is gone" "$CS_VI" 'docker-compose.yml" ./docker-compose.yml'
