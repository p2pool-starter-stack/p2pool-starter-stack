#!/usr/bin/env bash
#
# Build the shipped `pithead` CLI from its sources in lib/pithead/ (#1105 Phase 2).
#
# `pithead` is a SHIPPED ARTIFACT: a release bundle carries the single file and nothing else,
# and an operator runs `./pithead` straight out of a checkout. So the split into sources cannot
# introduce a runtime `source` — the file has to keep working as one self-contained script. It is
# therefore built by CONCATENATION: lib/pithead/*.sh in LC_ALL=C name order, byte for byte, into
# the committed `pithead`. Both the sources and the artifact are committed, and the artifact is
# the thing that ships.
#
# That design is only honest if the two cannot drift, which is what `--check` is for: it rebuilds
# into a temporary file and refuses on any difference. `make lint` runs it, so a slice edited
# without rebuilding fails the gate rather than shipping an artifact nobody generated.
#
#   scripts/build-pithead.sh              rebuild `pithead` in place (preserves its mode)
#   scripts/build-pithead.sh --check      fail if the committed artifact is not what the sources build
#   scripts/build-pithead.sh --self-test  run the fixtures in scripts/build-pithead-selftest.sh
#
# Concatenation order is the whole contract: the artifact's ordering constraints (`set -Eeuo
# pipefail` before any code, `on_err` defined before `trap on_err ERR`, the `_STACK_SOURCED`
# guard, `cd "$SCRIPT_DIR"`, `main "$@"` last) are preserved by keeping the slices in file order
# and naming them so that order is their sort order. Hence the numeric prefixes. `validate_ordering`
# below checks two of those invariants mechanically rather than trusting the numbering (#1463): a
# name `readonly` in two slices, and a bare `trap` target defined later than where it is installed.
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
# Cross-slice semantic ordering (#1463): concatenation preserves BYTE order (proven above, and by
# `--check`), but nothing before this proved it preserves the ordering INVARIANTS the header above
# names. Two shapes reproduce faithfully from source to artifact — they build, `--check` passes
# (source and artifact agree, because the defect is IN the source), and shellcheck is silent at
# both `--severity=warning` and `-S info` — and break only when the artifact RUNS:
#
#   - the same `readonly` name declared in two slices (a line copied to both sides of a boundary
#     instead of moved, e.g. two adjacent slices each declaring `readonly FOO="bar"`): a second
#     `readonly` on an already-readonly name is a fatal bash error the instant the artifact runs
#     ("FOO: readonly variable"), invisible to any check that never runs it.
#   - a bare `trap NAME SIG` installed before NAME is defined (a re-cut that leaves the trap's own
#     target sorting into a later slice): shellcheck resolves a direct call ahead of its
#     definition (SC2218 "This function is only defined later") but treats a trap target as an
#     opaque string, so the identical ordering mistake routed through `trap` is invisible to it at
#     any severity.
#
# Caught here by one forward scan over the slices IN BUILD ORDER, tracking every readonly name
# declared OUTSIDE a function body (at any indentation — `00-prelude.sh` declares one inside an
# `if`) and every top-level function name as each is DEFINED: a re-declared readonly name, or a
# bare trap target not yet in that set, refuses the build with the offending file:line. "Readonly"
# is by spelling, not by the bare word: `readonly NAME`, `readonly -a NAME=(…)`, `declare -r` and
# `typeset -r` all declare one, so leading flags are stripped before the name is recorded rather
# than letting a flag-carrying line drop out of the net silently. A bare trap is one identifier
# followed by any number of signal specs, so `trap f EXIT INT` is seen too. A `readonly` inside a
# function body is skipped: `local x; readonly x=…` in two functions is two independent names, not
# a collision, and recording it refused a build that runs fine. Function bodies are delimited the
# way shfmt writes them — `name() {` at column 0 opens one, `}` at column 0 closes it, and a
# `name() { …; }` one-liner opens nothing. Scoped to top-level slice order deliberately, matching
# what the build script's own header promises — it does not attempt general control-flow analysis
# (a function only ever called from inside a conditional that happens not to run first is out of
# scope, same as it is for shellcheck).
validate_ordering() {
    LC_ALL=C awk '
    function record(name) {
        if (name !~ /^[A-Za-z_][A-Za-z0-9_]*$/) return
        if (name in seen_readonly) {
            printf "build-pithead: FATAL — readonly %s is declared more than once (first %s, again %s:%d). A second `readonly` on an already-readonly name is a fatal error when the artifact RUNS, though it builds, passes --check, and is silent under shellcheck at both severities.\n", name, seen_readonly[name], FILENAME, FNR > "/dev/stderr"
            bad = 1
        } else {
            seen_readonly[name] = FILENAME ":" FNR
        }
    }
    /^[[:space:]]*(readonly|declare|typeset)[[:space:]]/ && !in_fn {
        line = $0
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+#.*/, "", line)
        n = split(line, toks, /[[:space:]]+/)
        # toks[1] is the builtin, then its -flags, then the names (or ONE NAME=value, which may
        # carry spaces). `readonly` is readonly by definition; `declare`/`typeset` only with -r.
        # -f marks a FUNCTION readonly and -p only prints: neither declares a variable.
        flags = (toks[1] == "readonly") ? "r" : ""
        for (i = 2; i <= n && toks[i] ~ /^-/; i++) flags = flags toks[i]
        if (flags ~ /r/ && flags !~ /[fp]/) {
            if (line ~ /=/) {
                name = toks[i]
                sub(/=.*/, "", name)
                record(name)
            } else {
                for (; i <= n; i++) record(toks[i])
            }
        }
    }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)/ {
        name = $0
        sub(/\(\).*/, "", name)
        defined_fns[name] = 1
        in_fn = ($0 ~ /\{[[:space:]]*(#.*)?$/)
    }
    /^\}/ { in_fn = 0 }
    /^[[:space:]]*trap[[:space:]]/ {
        line = $0
        sub(/[[:space:]]+#.*/, "", line)
        sub(/^[[:space:]]*trap[[:space:]]+/, "", line)
        # A bare target is one identifier followed by one OR MORE signal specs (`trap f EXIT INT`
        # is one trap line); a quoted command, `-`, or a `-l`/`-p` flag is not a bare target.
        if (line !~ /^[A-Za-z_][A-Za-z0-9_]*([[:space:]]+[A-Za-z0-9]+)+[[:space:]]*$/) next
        split(line, parts, /[[:space:]]+/)
        target = parts[1]
        if (!(target in defined_fns)) {
            printf "build-pithead: FATAL — trap installs %s as an ERR/EXIT/signal handler, but %s is not defined anywhere earlier in the build (at %s:%d). A trap firing before its target exists is `command not found` at RUN time, and shellcheck treats a trap target as an opaque string rather than catching it.\n", target, target, FILENAME, FNR > "/dev/stderr"
            bad = 1
        }
    }
    END { exit bad }
    ' "$@"
}

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

    # #1463: the byte-level checks above are satisfied by a build that is still semantically
    # broken (see the comment on validate_ordering). This runs on the slices IN BUILD ORDER, not
    # on the joined artifact, so it sees the same order the join below produces.
    local -a ordered_files=()
    while IFS= read -r f; do
        ordered_files+=("$f")
    done <<<"$slices"
    validate_ordering "${ordered_files[@]}" || return 1

    local i=0
    while IFS= read -r f; do
        [ "$i" -eq 0 ] || printf '\n'
        cat "$f"
        i=$((i + 1))
    done <<<"$slices"
}

write_artifact() {
    local tmp
    # Build beside the artifact, then rename over it. Two reasons, and the mode is carried across
    # explicitly so nothing is given up by not writing in place:
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
    if [ -e "$ARTIFACT" ]; then
        chmod --reference="$ARTIFACT" "$tmp"
    else
        chmod 0755 "$tmp"
    fi
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

case "${1:-}" in
"") write_artifact ;;
--check) check_artifact ;;
--self-test)
    # The fixtures live in build-pithead-selftest.sh, which runs THIS script against them (#1463
    # split, see that file's header). readlink -f first: through a symlink, `dirname "$0"` is the
    # LINK's directory and the exec would miss.
    exec bash "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/build-pithead-selftest.sh"
    ;;
*)
    echo "usage: ${BASH_SOURCE[0]##*/} [--check | --self-test]" >&2
    exit 2
    ;;
esac
