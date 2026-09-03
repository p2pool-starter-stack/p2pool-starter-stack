#!/usr/bin/env bash
# Fixtures for scripts/build-pithead.sh — every failure mode the build has, each against a
# throwaway lib/pithead/ of its own. Split out of the build script for #1463: adding the ordering
# cases took it from 437 lines to 570 against a recorded ceiling of 437, and ceilings only go down,
# so the split is the remedy docs/dev/file-budget.tsv itself documents (the same shape as
# lint-file-budget.sh / lint-file-budget-selftest.sh).
#
# Run it directly, or as `scripts/build-pithead.sh --self-test`, which execs this file. Nothing is
# sourced: every case drives the build script as a subprocess, the way `make` and an operator do.
set -euo pipefail

# readlink -f for the same reason the build's --self-test dispatch uses it: through a symlink the
# bare dirname would point at the link's directory and the sibling below would be missing.
BUILD="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)/build-pithead.sh"

# --- self-test: every failure mode against fixtures, in a throwaway directory -------------------
#
# Each case states what it proves. The two that matter most are the FIRING controls: a gate that
# only ever passes is indistinguishable from no gate at all, so the mutation cases assert both
# that the mutation actually landed in the file AND that --check went red because of it.
self_test() {
    local tmp fail=0

    _case() { # name, expected-rc, actual-rc
        if [ "$2" = "$3" ]; then
            echo "  ok   — $1"
        else
            echo "  FAIL — $1 (expected rc=$2, got rc=$3)"
            fail=1
        fi
    }

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/lib/pithead"

    # A miniature of the real thing: a prelude that carries the shebang, a middle slice, and a
    # tail, named the way the real slices are named (zero-padded, so lexical order IS the intended
    # order). This fixture deliberately does NOT discriminate lexical from numeric sorting — 00, 10
    # and 99 order identically under both — so it cannot stand as evidence for the sort algorithm.
    # Case 9 exists for that, on a fixture built to tell them apart.
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n' >"$tmp/lib/pithead/00-prelude.sh"
    printf 'middle() { :; }\n' >"$tmp/lib/pithead/10-middle.sh"
    printf 'main "$@"\n' >"$tmp/lib/pithead/99-tail.sh"

    local rc

    # 1. The build is the join, in sort order, with exactly one blank line between each pair.
    #    Compared with `cmp` on real files, NOT via `$(...)`: command substitution strips trailing
    #    newlines from both operands, which would make this case blind to any defect at the
    #    artifact's tail — a stray or missing final newline is exactly a join defect.
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n\nmiddle() { :; }\n\nmain "$@"\n' >"$tmp/expected"
    PITHEAD_BUILD_ROOT="$tmp" bash "$BUILD" >/dev/null 2>&1 || true
    if cmp -s "$tmp/pithead" "$tmp/expected"; then
        echo "  ok   — build joins the slices in sort order, one blank line between each pair"
    else
        echo "  FAIL — build did not join the slices in sort order with single blank separators"
        fail=1
    fi

    # 2. --check passes on a freshly built artifact.
    rc=0
    PITHEAD_BUILD_ROOT="$tmp" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
    _case "--check passes when artifact and sources agree" 0 "$rc"

    # 3. FIRING CONTROL, source side: mutate a slice; assert the mutation applied, then that
    #    --check goes red. Without the "applied" half a mutant that failed to write reads exactly
    #    like a gate that held.
    local before after
    before=$(cat "$tmp/lib/pithead/10-middle.sh")
    printf 'middle() { echo mutated; }\n' >"$tmp/lib/pithead/10-middle.sh"
    after=$(cat "$tmp/lib/pithead/10-middle.sh")
    if [ "$before" = "$after" ]; then
        echo "  FAIL — the source-side mutation did not change the file; its control proves nothing"
        fail=1
    fi
    rc=0
    PITHEAD_BUILD_ROOT="$tmp" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
    _case "--check FAILS when a source slice is edited without rebuilding" 1 "$rc"
    printf '%s\n' "$before" >"$tmp/lib/pithead/10-middle.sh"

    # 4. FIRING CONTROL, artifact side: the drift the gate exists to catch is someone hand-editing
    #    the shipped file, which is exactly how it was edited before Phase 2.
    before=$(cat "$tmp/pithead")
    printf 'hand_edited() { :; }\n' >>"$tmp/pithead"
    after=$(cat "$tmp/pithead")
    if [ "$before" = "$after" ]; then
        echo "  FAIL — the artifact-side mutation did not change the file; its control proves nothing"
        fail=1
    fi
    rc=0
    PITHEAD_BUILD_ROOT="$tmp" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
    _case "--check FAILS when the artifact is hand-edited" 1 "$rc"
    printf '%s\n' "$before" >"$tmp/pithead"

    # 5. An empty enumeration is refused rather than building an empty artifact.
    local empty
    empty=$(mktemp -d)
    mkdir -p "$empty/lib/pithead"
    touch "$empty/pithead"
    rc=0
    PITHEAD_BUILD_ROOT="$empty" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
    _case "--check REFUSES an empty lib/pithead (no vacuous pass)" 1 "$rc"
    rm -rf "$empty"

    # 6. A first slice without the shebang is refused: sort order and file order have diverged.
    local noshebang
    noshebang=$(mktemp -d)
    mkdir -p "$noshebang/lib/pithead"
    printf 'middle() { :; }\n' >"$noshebang/lib/pithead/00-not-the-prelude.sh"
    touch "$noshebang/pithead"
    rc=0
    PITHEAD_BUILD_ROOT="$noshebang" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
    _case "--check REFUSES when the first slice does not carry the shebang" 1 "$rc"
    rm -rf "$noshebang"

    # 7. A slice carrying the separator at either edge is refused BY NAME. This is the failure a
    #    future Phase-2 cut will actually hit: shfmt strips those blank lines, so a slice cut that
    #    way silently stops matching the artifact. Both edges, because they fail for one reason.
    local edge
    for edge in leading trailing; do
        local blank
        blank=$(mktemp -d)
        mkdir -p "$blank/lib/pithead"
        cp "$tmp/lib/pithead/00-prelude.sh" "$blank/lib/pithead/00-prelude.sh"
        if [ "$edge" = leading ]; then
            printf '\nmiddle() { :; }\n' >"$blank/lib/pithead/10-middle.sh"
        else
            printf 'middle() { :; }\n\n' >"$blank/lib/pithead/10-middle.sh"
        fi
        touch "$blank/pithead"
        rc=0
        PITHEAD_BUILD_ROOT="$blank" bash "$BUILD" --check >/dev/null 2>&1 || rc=$?
        _case "--check REFUSES a slice with a $edge blank line (the separator is the build's)" 1 "$rc"
        rm -rf "$blank"
    done

    # 8. A rebuild is idempotent and keeps the artifact's mode — an operator runs ./pithead.
    chmod 0755 "$tmp/pithead"
    PITHEAD_BUILD_ROOT="$tmp" bash "$BUILD" >/dev/null 2>&1
    if [ -x "$tmp/pithead" ]; then
        echo "  ok   — a rebuild preserves the artifact's executable bit"
    else
        echo "  FAIL — a rebuild dropped the artifact's executable bit"
        fail=1
    fi

    # 9. The slice order is LC_ALL=C LEXICAL, not numeric or version ordering. NO case above can
    #    see this: 00/10/99 sort identically under `sort` and `sort -V`, so a mutant that swapped
    #    the algorithm passes every one of them. A single-digit prefix beside a double-digit one is
    #    the smallest input that tells them apart — lexically `10-` sorts BEFORE `2-`, numerically
    #    it sorts after. That is also why the real slices are zero-padded: lexical order has to be
    #    the intended order, because lexical order is what the build uses.
    local order
    order=$(mktemp -d)
    mkdir -p "$order/lib/pithead"
    printf '#!/usr/bin/env bash\nfirst\n' >"$order/lib/pithead/00-prelude.sh"
    printf 'ten\n' >"$order/lib/pithead/10-ten.sh"
    printf 'two\n' >"$order/lib/pithead/2-two.sh"
    printf '#!/usr/bin/env bash\nfirst\n\nten\n\ntwo\n' >"$order/expected"
    PITHEAD_BUILD_ROOT="$order" bash "$BUILD" >/dev/null 2>&1 || true
    if cmp -s "$order/pithead" "$order/expected"; then
        echo "  ok   — slices are ordered by LC_ALL=C lexical sort, not a numeric or version sort"
    else
        echo "  FAIL — slice order is not LC_ALL=C lexical; a numeric/version or locale sort crept in"
        fail=1
    fi
    rm -rf "$order"

    # 10-15. The six refusals that guard a silently MALFORMED join, or a misleading diagnosis.
    #
    # Driven on the BUILD path rather than through `--check`, and each asserts THREE things: the
    # rc, the stated REASON, and that the previous artifact survived. All three are needed, because
    # **rc does not discriminate on two of the three fixtures** — which is the trap this block is
    # shaped to avoid rather than a belt-and-braces flourish:
    #
    #   - truncated (no trailing newline): rc IS the discriminating half. Delete that check and the
    #     build SUCCEEDS, rc=0, having silently lost the separator — so the case goes red.
    #   - empty, and a directory named `*.sh`: rc is VACUOUS. Delete either check and the build
    #     still fails, because `head -n 1` yields nothing for both and the leading-blank-line test
    #     trips instead. A case asserting only rc=1 would stay GREEN with the guard deleted. What
    #     those two guards actually buy is an accurate reason, so the reason is what gets asserted.
    #
    # Driving any of them through `--check` would make ALL THREE vacuous: the fixture artifact
    # cannot equal what the malformed sources build, so `--check` returns 1 on the parity
    # comparison whether or not a refusal exists.
    #
    # The artifact-survived half catches a build that writes DIRECTLY into the artifact: `>` opens
    # and truncates before the refusal is ever reached, so the operator loses `./pithead` to a
    # source typo. Stated narrowly on purpose — it does NOT discriminate rename-into-place from
    # the earlier `build >"$tmp"` + `cat "$tmp" >"$ARTIFACT"`, because under that shape `set -Eeuo
    # pipefail` aborts on the failed build before the copy runs, leaving the artifact intact too.
    #
    # NOT COVERED BY ANY CASE, and named rather than implied: the atomicity that rename actually
    # buys — an interruption (SIGKILL, full disk) part-way through writing the real artifact. That
    # needs a race to reproduce deterministically and no case here attempts it.
    #
    # dup-readonly and trap-before-def are #1463's two: both reproduce faithfully from source to
    # artifact (so a `--check`-driven case would prove nothing here either, same reasoning as
    # above), and neither is a structural defect in any ONE slice — each needs two, so both
    # override the shared 00-prelude/99-tail fixture instead of adding a lone 10-bad.sh. Case B
    # is written to fail for the right reason and not by coincidence: on_err genuinely exists in
    # the build (in 99-tail, textually AFTER the trap that targets it), so a check that merely
    # asked "does a function named on_err exist anywhere" would stay green on this fixture — only
    # a check of what is defined so far AT the trap line catches it.
    local bad desc want out
    for bad in empty truncated directory dup-readonly dup-readonly-indented dup-readonly-array dup-declare-r trap-before-def trap-before-def-multi; do
        local badroot
        badroot=$(mktemp -d)
        mkdir -p "$badroot/lib/pithead"
        printf '#!/usr/bin/env bash\nfirst\n' >"$badroot/lib/pithead/00-prelude.sh"
        printf 'last\n' >"$badroot/lib/pithead/99-tail.sh"
        case "$bad" in
        empty)
            : >"$badroot/lib/pithead/10-bad.sh"
            desc="an empty slice"
            want="is empty"
            ;;
        truncated)
            # `tail -n 1` returns this line's content, so neither blank-line edge check fires.
            printf 'no_final_newline' >"$badroot/lib/pithead/10-bad.sh"
            desc="a slice with no trailing newline"
            want="does not end with a newline"
            ;;
        directory)
            mkdir -p "$badroot/lib/pithead/10-bad.sh"
            desc="a directory named *.sh"
            want="is not a regular file"
            ;;
        dup-readonly)
            # The shape a careless re-cut produces when a line is copied to both sides of a
            # boundary instead of moved (#1463 attack A).
            printf '#!/usr/bin/env bash\nreadonly SAME="bar"\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'readonly SAME="baz"\n' >"$badroot/lib/pithead/10-bad.sh"
            desc="the same readonly name declared in two slices"
            want="is declared more than once"
            ;;
        dup-readonly-indented)
            # Indentation is not scope: a top-level `readonly` inside an `if` (the shape
            # 00-prelude.sh really has) collides with a column-0 one just the same. This is what
            # keeps the function-scope fix below from degrading into a column-0-only match.
            printf '#!/usr/bin/env bash\nif true; then\n    readonly SAME="bar"\nfi\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'readonly SAME="baz"\n' >"$badroot/lib/pithead/10-bad.sh"
            desc="the same readonly name declared in two slices, one of them indented under an if"
            want="is declared more than once"
            ;;
        dup-readonly-array)
            # A flag between the builtin and the name (`readonly -a`) must not hide the name: the
            # first scan took the flag AS the name, failed the identifier test, and dropped the
            # line silently (found in review of #1463).
            printf '#!/usr/bin/env bash\nreadonly SAME="bar"\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'readonly -a SAME=(x y)\n' >"$badroot/lib/pithead/10-bad.sh"
            desc="the same readonly name declared in two slices, once as readonly -a"
            want="is declared more than once"
            ;;
        dup-declare-r)
            # `declare -r` is `readonly` by another spelling, and was invisible for the same reason.
            printf '#!/usr/bin/env bash\ndeclare -r SAME="bar"\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'readonly SAME="baz"\n' >"$badroot/lib/pithead/10-bad.sh"
            desc="the same readonly name declared in two slices, once as declare -r"
            want="is declared more than once"
            ;;
        trap-before-def)
            # A trap installed in an earlier slice than the function it names (#1463 attack B) —
            # on_err DOES exist in this fixture, just too late to help the trap that names it.
            printf '#!/usr/bin/env bash\ntrap on_err ERR\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'middle\n' >"$badroot/lib/pithead/10-bad.sh"
            printf 'on_err() { :; }\n' >"$badroot/lib/pithead/99-tail.sh"
            desc="a bare trap target defined only in a LATER slice"
            want="is not defined anywhere earlier"
            ;;
        trap-before-def-multi)
            # The same trap naming more than one signal is still one bare trap; a regex written
            # for exactly one signal let it through (found in review of #1463).
            printf '#!/usr/bin/env bash\ntrap on_err EXIT INT\n' >"$badroot/lib/pithead/00-prelude.sh"
            printf 'middle\n' >"$badroot/lib/pithead/10-bad.sh"
            printf 'on_err() { :; }\n' >"$badroot/lib/pithead/99-tail.sh"
            desc="a bare trap target naming two signals, defined only in a LATER slice"
            want="is not defined anywhere earlier"
            ;;
        esac
        printf 'PREVIOUS-ARTIFACT\n' >"$badroot/pithead"
        rc=0
        out=$(PITHEAD_BUILD_ROOT="$badroot" bash "$BUILD" 2>&1) || rc=$?
        _case "a build REFUSES $desc" 1 "$rc"
        case "$out" in
        *"$want"*)
            echo "  ok   — and states the reason ('$want'), not a misleading one"
            ;;
        *)
            echo "  FAIL — refused $desc for the WRONG stated reason: wanted '$want', got: $out"
            fail=1
            ;;
        esac
        if [ "$(cat "$badroot/pithead")" = "PREVIOUS-ARTIFACT" ]; then
            echo "  ok   — and left the existing artifact intact"
        else
            echo "  FAIL — a refused build ($desc) overwrote or truncated the existing artifact"
            fail=1
        fi
        # The refused build must not leave its scratch file behind: it is untracked, it is not in
        # .gitignore, and `git add -A` would stage it into someone's commit.
        if [ -z "$(echo "$badroot"/.pithead.build.* 2>/dev/null | grep -v '\*')" ]; then
            echo "  ok   — and cleaned up its build temp file"
        else
            echo "  FAIL — a refused build ($desc) left $badroot/.pithead.build.* behind"
            fail=1
        fi
        rm -rf "$badroot"
    done

    # 16. The counter-example to dup-readonly: `local x; readonly x=…` in two functions across two
    #     slices is two independent, function-scoped names — the artifact runs fine — and the scan
    #     must ACCEPT it. A readonly arm that keys on the name alone refuses this build (found in
    #     review of #1463), so this case is red without function-scope tracking. No previous
    #     artifact in the fixture on purpose: a fresh build is the whole assertion.
    local scoped
    scoped=$(mktemp -d)
    mkdir -p "$scoped/lib/pithead"
    printf '#!/usr/bin/env bash\nfoo() {\n    local x\n    readonly x=1\n    echo "$x"\n}\n' >"$scoped/lib/pithead/00-a.sh"
    printf 'bar() {\n    local x\n    readonly x=2\n    echo "$x"\n}\n' >"$scoped/lib/pithead/10-b.sh"
    rc=0
    PITHEAD_BUILD_ROOT="$scoped" bash "$BUILD" >/dev/null 2>&1 || rc=$?
    _case "a build ACCEPTS the same function-local readonly name in two slices (scope, not name)" 0 "$rc"
    rm -rf "$scoped"

    # 17. The counter-example to dup-declare-r: `declare` without -r is not readonly, so the same
    #     name declared `declare -a` in two slices runs fine and must be ACCEPTED. Red under a scan
    #     that records every `declare` instead of only the -r ones.
    local plain
    plain=$(mktemp -d)
    mkdir -p "$plain/lib/pithead"
    printf '#!/usr/bin/env bash\ndeclare -a SAME=(1)\n' >"$plain/lib/pithead/00-a.sh"
    printf 'declare -a SAME=(2)\n' >"$plain/lib/pithead/10-b.sh"
    rc=0
    PITHEAD_BUILD_ROOT="$plain" bash "$BUILD" >/dev/null 2>&1 || rc=$?
    _case "a build ACCEPTS the same name declared -a (not -r) in two slices (readonly, not declare)" 0 "$rc"
    rm -rf "$plain"

    if [ "$fail" -ne 0 ]; then
        echo "build-pithead --self-test: FAILED"
        return 1
    fi
    echo "build-pithead --self-test: all cases passed"
    return 0
}

self_test
exit $?
