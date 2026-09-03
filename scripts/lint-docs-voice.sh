#!/usr/bin/env bash
# Fail if a banned marketing word appears in a prose doc. The banned list is the one part of the
# house voice (docs/dev/STYLE.md) that can be enforced mechanically; the rest is reviewed by humans.
set -euo pipefail

BANNED='leverage|robust|seamless|powerful|effortlessly|comprehensive|elevate|streamline|simply|unlock|empower|cutting-edge|blazing|lightning-fast'

# --- self-test: prove the empty-enumeration guard is wired into the real invocation, not just
# described (#1441). A repo with no tracked .md files is the only way to make `git ls-files '*.md'`
# return nothing without editing the glob, so this runs the actual script end to end in one, rather
# than asserting on an extracted function — nothing here would call a function-only fix broken.
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    empty="$tmp/emptyrepo"
    mkdir -p "$empty"
    git init -q "$empty" >/dev/null
    out=$(cd "$empty" && bash "$self" 2>&1) && rc=0 || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'prose-doc enumeration returned zero files'; then
        echo "  self-test ok: an empty prose-doc enumeration is refused, not read as a clean scan"
    else
        echo "  self-test FAIL: an empty prose-doc enumeration was accepted (rc=$rc): $out"
        echo "lint-docs-voice self-test FAILED"
        exit 1
    fi
    echo "lint-docs-voice self-test OK"
    exit 0
fi

# Prose docs only. Exclude the style guide itself (it lists the words), the changelog (a historical
# record), the verbatim Contributor Covenant, and vendored/third-party markdown. (The generated
# test-inventory is git-ignored now, so `git ls-files` never surfaces it — no exclusion needed, #414.)
files=$(git ls-files '*.md' |
    grep -vxE 'docs/dev/STYLE\.md|CHANGELOG\.md|THIRD_PARTY_LICENSES\.md|CODE_OF_CONDUCT\.md' |
    grep -vE '^docs/research/' | # verbatim research records: quoted sources and audit trails, not house prose
    grep -vE '(^|/)(vendor|node_modules)/' || true)

# An empty enumeration is broken, never a clean tree: the glob above matches tracked prose in any
# real checkout. A broken filter and a genuinely clean scan both report zero hits, so this refuses
# rather than pass either off as the other (same shape as lint-operator-strings.sh's
# enforce_nonempty_frontend, #1441).
if [ -z "$files" ]; then
    echo "docs voice: the prose-doc enumeration returned zero files." >&2
    echo "A broken enumeration and a clean scan both report zero hits — refusing to call either a pass." >&2
    exit 1
fi

# Filenames are space-free (git ls-files, this repo), so word-splitting into grep args is safe.
# shellcheck disable=SC2086
if hits=$(grep -rniE "$BANNED" $files); then
    echo "Banned marketing word(s) found — see docs/dev/STYLE.md:"
    echo "$hits"
    exit 1
fi

echo "docs voice OK — no banned words in $(printf '%s\n' "$files" | wc -l | tr -d ' ') prose docs"
