#!/usr/bin/env bash
# Fail if a GitHub issue/PR number (#NNN) leaks into operator-facing output: a `pithead`
# log/warn/error/info/echo message (including describe_change's msg="..." apply-preview text), or
# a user-visible string in the dashboard's static frontend. Comments and docstrings are developer
# cross-references and stay exempt — this only walks the message text an operator actually reads
# (issue #755). Run `--self-test` to check the scanners themselves against fixtures.
set -euo pipefail

# Scan a pithead-shaped shell file: print any log/warn/error/info/echo call, or describe_change
# msg= assignment, whose string carries a #NNN. A comment line (the keyword isn't at the line
# start) never matches. Prints "line: text" per hit; silent when clean.
scan_pithead() {
    {
        grep -nE '^[[:space:]]*(log|warn|error|info|echo)[[:space:]]*(-[a-zA-Z]+[[:space:]]*)?"' "$1" || true
        grep -n 'msg=' "$1" || true
    } | grep -E '#[0-9]+' || true
}

# Scan frontend files (.mjs/.js/.html) for a #NNN in user-visible text. Strips `//` (JS) and
# `<!-- -->` (HTML, block-aware across lines) comments first — those carry developer refs, not
# operator text. A `#[0-9]+` immediately followed by another hex digit is a CSS colour running past
# where our pattern stopped (e.g. `#3fb950`), and a token of exactly 6 or 8 digits is a fully
# numeric hex colour (`#494138`, `#00000055`); both are skipped. Prints "file:line: text" per hit.
scan_frontend() {
    awk '
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
    ' "$@"
}

# --- self-test: prove the scanners catch a planted #NNN and skip the tricky exemptions ----------
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    st_fail=0
    expect() { # <desc> <hit|clean> <actual-output>
        if [ "$2" = hit ] && [ -z "$3" ]; then
            echo "  self-test FAIL: $1 (expected a hit, got none)"
            st_fail=1
        elif [ "$2" = clean ] && [ -n "$3" ]; then
            echo "  self-test FAIL: $1 (expected clean, got: $3)"
            st_fail=1
        else echo "  self-test ok: $1"; fi
    }

    printf '%s\n' 'error "bad remote (#99)"' >"$tmp/hit.sh"
    expect "pithead error carrying #NNN is flagged" hit "$(scan_pithead "$tmp/hit.sh")"
    printf '%s\n' '    msg="Switching node (#7) — recreates."' >"$tmp/msg.sh"
    expect "pithead describe_change msg= carrying #NNN is flagged" hit "$(scan_pithead "$tmp/msg.sh")"
    printf '%s\n' '    log "held until sync finishes, then starts."' '# see the spool (#42) design note' >"$tmp/clean.sh"
    expect "clean pithead + a #NNN comment is not flagged" clean "$(scan_pithead "$tmp/clean.sh")"

    printf '%s\n' 'const t = "avg window (#168)";' >"$tmp/hit.mjs"
    expect "frontend user string carrying #NNN is flagged" hit "$(scan_frontend "$tmp/hit.mjs")"
    printf '%s\n' 'const bg = "#3fb950"; const a = "#00000055";' >"$tmp/color.mjs"
    expect "CSS hex colours (6- and 8-digit) are not flagged" clean "$(scan_frontend "$tmp/color.mjs")"
    printf '%s\n' '// cross-ref #33 in a code comment' >"$tmp/comment.mjs"
    expect "a #NNN in a // comment is not flagged" clean "$(scan_frontend "$tmp/comment.mjs")"
    printf '%s\n' '<span title="hashrate (#12)">Avg</span>' >"$tmp/hit.html"
    expect "HTML user-visible #NNN is flagged" hit "$(scan_frontend "$tmp/hit.html")"
    printf '%s\n' '<!-- design ref #99 -->' >"$tmp/comment.html"
    expect "a #NNN in an HTML comment is not flagged" clean "$(scan_frontend "$tmp/comment.html")"

    [ "$st_fail" -eq 0 ] && {
        echo "lint-operator-strings self-test OK"
        exit 0
    }
    echo "lint-operator-strings self-test FAILED"
    exit 1
fi

fail=0

if
    hits=$(scan_pithead pithead)
    [ -n "$hits" ]
then
    echo "operator strings: issue/PR number in a pithead log/warn/error/info/echo call or describe_change msg=:"
    echo "$hits"
    fail=1
fi

# The static frontend, minus the *.min.js bundles.
files=$(git ls-files 'build/dashboard/mining_dashboard/web/static/*.mjs' \
    'build/dashboard/mining_dashboard/web/static/*.js' \
    'build/dashboard/mining_dashboard/web/templates/*.html' | grep -v '\.min\.js$' || true)
if [ -n "$files" ]; then
    # shellcheck disable=SC2086
    if
        hits=$(scan_frontend $files)
        [ -n "$hits" ]
    then
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
