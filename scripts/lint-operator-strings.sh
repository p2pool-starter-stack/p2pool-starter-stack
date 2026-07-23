#!/usr/bin/env bash
# Fail if a GitHub issue/PR number (#NNN) leaks into operator-facing output: a `pithead`
# log/warn/error/info/echo message (including describe_change's msg="..." apply-preview text), or
# a user-visible string in the dashboard's static frontend. Comments and docstrings are developer
# cross-references and stay exempt — this only walks the message text an operator actually reads
# (issue #755).
set -euo pipefail

fail=0

# --- pithead: log/warn/error/info/echo call arguments -----------------------------------------
# Comment lines (first non-space char is `#`) are excluded by requiring the call keyword to start
# the (trimmed) line.
if hits=$(grep -nE '^[[:space:]]*(log|warn|error|info|echo)[[:space:]]*(-[a-zA-Z]+[[:space:]]*)?"' pithead |
    grep -E '#[0-9]+'); then
    echo "operator strings: issue/PR number in a pithead log/warn/error/info/echo call:"
    echo "$hits"
    fail=1
fi

# --- pithead: describe_change's msg="..." (rendered in the apply preview + dashboard editor) ---
if hits=$(grep -n 'msg=' pithead | grep -E '#[0-9]+'); then
    echo "operator strings: issue/PR number in a pithead describe_change msg= (apply-preview text):"
    echo "$hits"
    fail=1
fi

# --- dashboard: user-visible strings in the static frontend (not the *.test.mjs suite) ---------
# Strips `//` (JS) and `<!-- -->` (HTML, block-aware) comments before scanning, since those carry
# developer cross-references, not operator text. A `#[0-9]+` immediately followed by another digit
# or a hex letter is a CSS colour continuing past the point our pattern stopped (e.g. `#3fb950`),
# not an issue number, so it's skipped. A match made of exactly 6 or 8 digits is a fully-numeric hex
# colour (`#494138`, `#00000055`) and is skipped too.
files=$(git ls-files 'build/dashboard/mining_dashboard/web/static/*.mjs' \
    'build/dashboard/mining_dashboard/web/static/*.js' \
    'build/dashboard/mining_dashboard/web/templates/*.html' | grep -v '\.min\.js$' || true)
if [ -n "$files" ]; then
    # shellcheck disable=SC2086
    hits=$(awk '
        {
            line = $0
            if (FILENAME ~ /\.html$/) {
                if (in_html_comment) {
                    idx = index(line, "-->")
                    if (idx > 0) { line = substr(line, idx + 3); in_html_comment = 0 }
                    else next
                }
                while ((idx = index(line, "<!--")) > 0) {
                    cend = index(substr(line, idx), "-->")
                    if (cend > 0) line = substr(line, 1, idx - 1) substr(line, idx + cend + 2)
                    else { line = substr(line, 1, idx - 1); in_html_comment = 1; break }
                }
            } else {
                idx = index(line, "//")
                if (idx > 0) line = substr(line, 1, idx - 1)
            }
            stripped = line
            sub(/^[ \t]+/, "", stripped)
            if (stripped == "") next
            rest = line
            while (match(rest, /#[0-9]+/)) {
                tok = substr(rest, RSTART, RLENGTH)
                after = substr(rest, RSTART + RLENGTH, 1)
                digits = substr(tok, 2)
                if (after !~ /[0-9a-fA-F]/ && length(digits) != 6 && length(digits) != 8) {
                    print FILENAME ":" FNR ": " $0
                    break
                }
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    ' $files)
    if [ -n "$hits" ]; then
        echo "operator strings: issue/PR number in a dashboard frontend user-visible string:"
        echo "$hits"
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "See CONTRIBUTING.md / docs/dev/STYLE.md — operator-facing text drops issue/PR references, comments keep them."
    exit 1
fi

echo "operator strings OK — no issue/PR numbers in pithead output or the dashboard frontend"
