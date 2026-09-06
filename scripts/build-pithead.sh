#!/usr/bin/env bash
#
# Build the shipped `pithead` CLI from its sources in lib/pithead/ (#1105 Phase 2).
#
# `pithead` is a SHIPPED ARTIFACT: a release bundle carries the single file and nothing else,
# and an operator runs `./pithead` straight out of a checkout. So the split into sources cannot
# introduce a runtime `source` — the file has to keep working as one self-contained script. It is
# therefore built by CONCATENATION: lib/pithead/*.sh in LC_ALL=C name order, byte for byte, into
# the committed `pithead`, under a banner naming this script as the generator. Both the sources
# and the artifact are committed, and the artifact is the thing that ships.
#
# That design is only honest if the two cannot drift, which is what `--check` is for: it rebuilds
# into a temporary file and refuses on any difference. `make lint` runs it, so a slice edited
# without rebuilding fails the gate rather than shipping an artifact nobody generated.
#
#   scripts/build-pithead.sh              rebuild `pithead` in place (preserves its mode)
#   scripts/build-pithead.sh --check      fail if the committed artifact is not what the sources build
#   scripts/build-pithead.sh --self-test  run this script's own fixtures, in a throwaway directory
#
# Concatenation order is the whole contract: the artifact's ordering constraints (`set -Eeuo
# pipefail` before any code, `on_err` defined before `trap on_err ERR`, the `_STACK_SOURCED`
# guard, `cd "$SCRIPT_DIR"`, `main "$@"` last) are preserved by keeping the slices in file order
# and naming them so that order is their sort order. Hence the numeric prefixes.
set -euo pipefail

ROOT="${PITHEAD_BUILD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly ROOT
readonly SRC_DIR="$ROOT/lib/pithead"
readonly ARTIFACT="$ROOT/pithead"

# List the source slices in build order. LC_ALL=C so the order is the same everywhere: a locale
# that collates punctuation differently would silently reorder the artifact, and a reordered
# concatenation is a broken script, not a diff you would notice by eye.
list_slices() {
    local f
    for f in "$SRC_DIR"/*.sh; do
        [ -e "$f" ] || continue
        printf '%s\n' "$f"
    done | LC_ALL=C sort
}

# Join the slices with ONE blank line between each pair, and refuse the ways this can silently
# produce nonsense.
#
# The blank line is the build's job, not a slice's, and that is forced rather than chosen. `shfmt`
# strips blank lines from both ends of a file, and it reaches these slices through `make lint-sh`'s
# `git ls-files '*.sh'` glob — so a slice cannot carry the separator at either edge and stay
# format-clean. Since the artifact separates its top-level blocks with exactly one blank line
# anyway, joining on one puts the separator where both tools agree: every slice is independently
# shfmt-clean, and cutting a new slice at any blank line between two top-level blocks reproduces
# the artifact byte for byte. A boundary at two blank lines or none does NOT, and `--check` says so
# on the spot.
#
# Refusals, each guarding a way the build could look like it worked:
#   - an empty enumeration (a moved or mistyped source dir builds an empty "artifact"; every later
#     slice-move would then read as a catastrophic diff rather than as a missing directory)
#   - a first slice without the shebang (whatever sorts first carries it; if it does not, sort
#     order and file order have come apart and the artifact would not be executable)
#   - a slice with a blank first or last line, which is the separator rule above being broken —
#     caught here by name, rather than as an unexplained one-line diff from `--check`
#   - an entry that is not a regular file (a directory named `*.sh` matches the glob). This one
#     fails closed either way, so it is about the REASON given: checked before the shebang test,
#     because `head` on a directory reads as a missing shebang and sends the reader hunting a
#     sort-order bug that does not exist
#   - an EMPTY slice, named as empty rather than as "opens with a blank line", which is what the
#     leading-edge check alone would have called it
#   - a slice with no trailing newline. This one is the least obvious and the most dangerous: the
#     blank-line checks above use `tail -n 1`, which returns the last line's CONTENT for a file
#     that simply stops without a newline, so neither of them fires. The join then runs that
#     slice's last line straight into the next slice's first with NO separator at all — and once
#     that state is committed, `--check` compares the build against itself and blesses it forever.
build() {
    local slices first f last_line
    slices=$(list_slices)
    if [ -z "$slices" ]; then
        echo "build-pithead: FATAL — no source slices in $SRC_DIR. Refusing to build an empty artifact." >&2
        return 1
    fi
    # Validate every slice BEFORE the shebang check, not after. `head` on a directory prints
    # nothing and fails, so a directory named `*.sh` sorting first would otherwise be reported as
    # "does not open with the shebang" — a refusal for the wrong stated reason, which sends the
    # reader looking for a sort-order bug that is not there.
    while IFS= read -r f; do
        if [ ! -f "$f" ]; then
            echo "build-pithead: FATAL — $f is not a regular file. Only files may be slices;" \
                "a directory or device named *.sh in $SRC_DIR cannot be concatenated." >&2
            return 1
        fi
        if [ ! -s "$f" ]; then
            echo "build-pithead: FATAL — $f is empty. An empty slice cannot carry the blank-line" \
                "separator contract, and silently contributes nothing to the artifact." >&2
            return 1
        fi
        if [ -z "$(head -n 1 "$f")" ]; then
            echo "build-pithead: FATAL — $f opens with a blank line. The build supplies the blank" \
                "line between slices; a slice carrying one at its edge is also what shfmt strips." >&2
            return 1
        fi
        last_line=$(tail -n 1 "$f")
        if [ -z "$last_line" ]; then
            echo "build-pithead: FATAL — $f ends with a blank line. The build supplies the blank" \
                "line between slices; a slice carrying one at its edge is also what shfmt strips." >&2
            return 1
        fi
        # `$(...)` strips a trailing newline, so this is empty exactly when the file ends in one.
        if [ -n "$(tail -c 1 "$f")" ]; then
            echo "build-pithead: FATAL — $f does not end with a newline. The join would run its" \
                "last line into the next slice's first line with no separator between them." >&2
            return 1
        fi
    done <<<"$slices"

    first=$(printf '%s\n' "$slices" | head -n 1)
    if [ "$(head -n 1 "$first")" != "#!/usr/bin/env bash" ]; then
        echo "build-pithead: FATAL — the first slice ($first) does not open with the shebang." \
            "Sort order and file order have diverged; the built artifact would not be executable." >&2
        return 1
    fi

    # Line 2 of the artifact names its generator (deterministic — no date or host — so `--check` stays a byte comparison).
    local i=0
    while IFS= read -r f; do
        [ "$i" -eq 0 ] || printf '\n'
        cat "$f"
        i=$((i + 1))
    done <<<"$slices" | awk -v n="$(printf '%s\n' "$slices" | wc -l | tr -d ' ')" 'NR == 1 { print; printf "# GENERATED FILE — do not edit. Built from lib/pithead/*.sh (%s slices, LC_ALL=C name order) by:\n#   scripts/build-pithead.sh\n# A drifted copy fails `scripts/build-pithead.sh --check` (make lint-pithead-parity).\n", n; next } 1'
}

write_artifact() {
    local tmp
    # Build beside the artifact, then rename over it. Two reasons, and the mode is set explicitly
    # so nothing is given up by not writing in place:
    #
    #   - `cat >"$ARTIFACT"` truncates at OPEN time, before a single byte is written and whatever
    #     `set -e` does afterwards. A rebuild interrupted at that instant — Ctrl-C, a full disk, a
    #     dead $TMPDIR — leaves the operator an empty or half-written `./pithead`, which is the
    #     shipped executable. A rename either happens or does not.
    #   - bash reads a script lazily, by offset, as it executes it. Rewriting the file in place
    #     while `./pithead` is running feeds the RUNNING shell the tail of a different file; a
    #     rename leaves that process on the old inode, untouched.
    #
    # The temp file must live in the artifact's own directory: a rename is only atomic within one
    # filesystem, and `mktemp` alone would put it under /tmp, which is very often another one.
    tmp=$(mktemp "$ROOT/.pithead.build.XXXXXX")
    # EXIT, not RETURN. A RETURN trap fires on a normal return only, and the whole point of this
    # temp file is the path where the build does NOT return normally: `set -e` aborts the shell on
    # a refused build, RETURN never runs, and a 0-byte .pithead.build.XXXXXX is left in the repo
    # root. It is untracked and not in .gitignore, so the next `git add -A` would stage it.
    # shellcheck disable=SC2064  # expand now: the trap must name THIS file, not whatever $tmp is later
    trap "rm -f -- '$tmp'" EXIT
    build >"$tmp"
    # Always 0755: the artifact is tracked at that mode, an operator runs `./pithead`, release.sh
    # bundles it as-is, and `chmod --reference` (carrying a mode across) is GNU-only — macOS refuses.
    chmod 0755 "$tmp"
    mv -f "$tmp" "$ARTIFACT"
    echo "build-pithead: wrote $ARTIFACT from $(list_slices | wc -l | tr -d ' ') slice(s)."
}

check_artifact() {
    local tmp rc=0
    if [ ! -f "$ARTIFACT" ]; then
        echo "build-pithead: FAIL — $ARTIFACT does not exist." >&2
        return 1
    fi
    tmp=$(mktemp)
    build >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if ! cmp -s "$tmp" "$ARTIFACT"; then
        echo "build-pithead: FAIL — $ARTIFACT is not what lib/pithead/*.sh builds."
        echo "The sources and the shipped artifact have drifted. Edit the slice, then run:"
        echo "    scripts/build-pithead.sh"
        echo "and commit both. First differing lines:"
        diff <(cat "$ARTIFACT") <(cat "$tmp") | head -n 20 || true
        rc=1
    else
        echo "pithead parity OK — the committed artifact is exactly what $(list_slices | wc -l | tr -d ' ') slice(s) build."
    fi
    rm -f "$tmp"
    return "$rc"
}

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
    printf '#!/usr/bin/env bash\n# GENERATED FILE — do not edit. Built from lib/pithead/*.sh (3 slices, LC_ALL=C name order) by:\n#   scripts/build-pithead.sh\n# A drifted copy fails `scripts/build-pithead.sh --check` (make lint-pithead-parity).\nset -Eeuo pipefail\n\nmiddle() { :; }\n\nmain "$@"\n' >"$tmp/expected"
    PITHEAD_BUILD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || true
    if cmp -s "$tmp/pithead" "$tmp/expected"; then
        echo "  ok   — build joins the slices in sort order, one blank line between each pair"
    else
        echo "  FAIL — build did not join the slices in sort order with single blank separators"
        fail=1
    fi

    # 2. --check passes on a freshly built artifact.
    rc=0
    PITHEAD_BUILD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
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
    PITHEAD_BUILD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
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
    PITHEAD_BUILD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
    _case "--check FAILS when the artifact is hand-edited" 1 "$rc"
    printf '%s\n' "$before" >"$tmp/pithead"

    # 5. An empty enumeration is refused rather than building an empty artifact.
    local empty
    empty=$(mktemp -d)
    mkdir -p "$empty/lib/pithead"
    touch "$empty/pithead"
    rc=0
    PITHEAD_BUILD_ROOT="$empty" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
    _case "--check REFUSES an empty lib/pithead (no vacuous pass)" 1 "$rc"
    rm -rf "$empty"

    # 6. A first slice without the shebang is refused: sort order and file order have diverged.
    local noshebang
    noshebang=$(mktemp -d)
    mkdir -p "$noshebang/lib/pithead"
    printf 'middle() { :; }\n' >"$noshebang/lib/pithead/00-not-the-prelude.sh"
    touch "$noshebang/pithead"
    rc=0
    PITHEAD_BUILD_ROOT="$noshebang" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
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
        PITHEAD_BUILD_ROOT="$blank" bash "${BASH_SOURCE[0]}" --check >/dev/null 2>&1 || rc=$?
        _case "--check REFUSES a slice with a $edge blank line (the separator is the build's)" 1 "$rc"
        rm -rf "$blank"
    done

    # 8. A rebuild over an existing artifact exits 0 and leaves it executable — an operator runs
    #    ./pithead. Guarded like every other case: unguarded, `set -e` aborted the whole self-test
    #    here with both streams already redirected, so cases 9+ silently never ran (macOS, #1722).
    chmod 0755 "$tmp/pithead"
    rc=0
    PITHEAD_BUILD_ROOT="$tmp" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || rc=$?
    _case "a rebuild over an existing artifact exits 0" 0 "$rc"
    rc=0
    [ -x "$tmp/pithead" ] || rc=1
    _case "a rebuild preserves the artifact's executable bit" 0 "$rc"

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
    printf '#!/usr/bin/env bash\n# GENERATED FILE — do not edit. Built from lib/pithead/*.sh (3 slices, LC_ALL=C name order) by:\n#   scripts/build-pithead.sh\n# A drifted copy fails `scripts/build-pithead.sh --check` (make lint-pithead-parity).\nfirst\n\nten\n\ntwo\n' >"$order/expected"
    PITHEAD_BUILD_ROOT="$order" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || true
    if cmp -s "$order/pithead" "$order/expected"; then
        echo "  ok   — slices are ordered by LC_ALL=C lexical sort, not a numeric or version sort"
    else
        echo "  FAIL — slice order is not LC_ALL=C lexical; a numeric/version or locale sort crept in"
        fail=1
    fi
    rm -rf "$order"

    # 10-12. The three refusals that guard a silently MALFORMED join, or a misleading diagnosis.
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
    local bad desc want out
    for bad in empty truncated directory; do
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
        esac
        printf 'PREVIOUS-ARTIFACT\n' >"$badroot/pithead"
        rc=0
        out=$(PITHEAD_BUILD_ROOT="$badroot" bash "${BASH_SOURCE[0]}" 2>&1) || rc=$?
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

    if [ "$fail" -ne 0 ]; then
        echo "build-pithead --self-test: FAILED"
        return 1
    fi
    echo "build-pithead --self-test: all cases passed"
    return 0
}

case "${1:-}" in
"") write_artifact ;;
--check) check_artifact ;;
--self-test) self_test ;;
*)
    echo "usage: ${BASH_SOURCE[0]##*/} [--check | --self-test]" >&2
    exit 2
    ;;
esac
