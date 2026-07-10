#!/usr/bin/env bash
# Fail if a banned marketing word appears in a prose doc. The banned list is the one part of the
# house voice (docs/STYLE.md) that can be enforced mechanically; the rest is reviewed by humans.
set -euo pipefail

BANNED='leverage|robust|seamless|powerful|effortlessly|comprehensive|elevate|streamline|simply|unlock|empower|cutting-edge|blazing|lightning-fast'

# Prose docs only. Exclude the style guide itself (it lists the words), the changelog (a historical
# record), the verbatim Contributor Covenant, and vendored/third-party markdown. (The generated
# test-inventory is git-ignored now, so `git ls-files` never surfaces it — no exclusion needed, #414.)
files=$(git ls-files '*.md' |
    grep -vxE 'docs/STYLE\.md|CHANGELOG\.md|THIRD_PARTY_LICENSES\.md|CODE_OF_CONDUCT\.md' |
    grep -vE '(^|/)(vendor|node_modules)/' || true)

if [ -z "$files" ]; then
    echo "docs voice: no prose docs to check"
    exit 0
fi

# Filenames are space-free (git ls-files, this repo), so word-splitting into grep args is safe.
# shellcheck disable=SC2086
if hits=$(grep -rniE "$BANNED" $files); then
    echo "Banned marketing word(s) found — see docs/STYLE.md:"
    echo "$hits"
    exit 1
fi

echo "docs voice OK — no banned words in $(printf '%s\n' "$files" | wc -l | tr -d ' ') prose docs"
