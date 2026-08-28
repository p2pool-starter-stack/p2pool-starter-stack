#!/usr/bin/env bash
# Fail if a GitHub issue/PR number (#NNN) leaks into operator-facing output: a `pithead`
# log/warn/error/info/echo message (including describe_change's msg="..." apply-preview text), or
# a user-visible string in the dashboard's static frontend. Comments and docstrings are developer
# cross-references and stay exempt — this only walks the message text an operator actually reads
# (issue #755). Run `--self-test` to check the scanners themselves against fixtures.
set -euo pipefail

# Operator-facing message calls in a pithead-shaped shell file: the named call shapes, plus every
# describe_change msg= assignment (apply-preview text). A comment line never matches, since the
# keyword has to sit at the line start. Prints "line: text" per hit.
msg_lines() { # <file> <keyword-alternation>
    {
        grep -nE "^[[:space:]]*($2)[[:space:]]*(-[a-zA-Z]+[[:space:]]*)?\"" "$1" || true
        grep -n 'msg=' "$1" || true
        heredoc_body_lines "$1"
    }
}

# Heredoc bodies that reach the operator. The greps above only see call shapes, so show_help's
# `cat <<EOF` usage block was invisible — and a bare docs/ path sat in it through the very review
# that added the docs rule, with the linter reporting the tree clean. An opener with a redirect on
# it (`cat <<EOF >"$f"`) writes a file — a unit, a config, a template — which is not operator text,
# so the `$` anchor keeps those out. Prints "line: text" per body line, same shape as the greps.
heredoc_body_lines() { # <file>
    awk '
        /^[ \t]*cat[ \t]+<<-?[^ \t]+[ \t]*$/ {
            tag = $0
            sub(/^[ \t]*cat[ \t]+<<-?/, "", tag)
            sub(/[ \t]*$/, "", tag)
            # strip a quoted tag without writing a quote into this program
            gsub(/\042/, "", tag)
            gsub(/\047/, "", tag)
            inhd = 1
            next
        }
        inhd && $0 ~ "^[ \t]*" tag "[ \t]*$" { inhd = 0; next }
        inhd { print FNR ": " $0 }
    ' "$1"
}

# Both rules run at the same width: log/warn/error/info/echo, plus the doctor's dr_* reporters and
# the control runner's _upg_* result strings — doctor output goes on screen and _upg_* errors
# render in the dashboard's upgrade panel, so both are operator-facing same as the rest. The
# issue-number rule used to stay on the narrower original call shapes because those dr_*/_upg_*
# sites carried a dozen #NNN references that predated this linter (issue #1026); now that they're
# clean, there's nothing left for the wider match to catch them on.
NARROW='log|warn|error|info|echo'
WIDE="$NARROW|dr_ok|dr_warn|dr_fail|dr_info|_upg_reject|_upg_fail"

# Rule 1: no #NNN in operator text. A $DOCS_URL pointer is stripped first: its trailing #anchor is
# a heading link, and GitHub numbers those from numbered headings ("## 1. Prerequisites" ->
# "#1-prerequisites"), which reads as an issue reference to the pattern below and is not one.
scan_pithead() {
    msg_lines "$1" "$WIDE" | sed 's|\$DOCS_URL/[^ "]*||g' | grep -E '#[0-9]+' || true
}

# Rule 2: no bare repo doc path in operator text (issue #1024). Release bundles ship the CLI, the
# compose file, the config files and cosign.pub — no docs/ — so a message naming a repo-relative
# doc sends the reader to a file that is not on their disk. Messages point at $DOCS_URL instead,
# which is stripped before the check so a correctly-formed pointer reads as clean.
scan_pithead_docs() {
    msg_lines "$1" "$WIDE" | sed 's|\$DOCS_URL/docs/||g' | grep -E 'docs/' || true
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

# A frontend enumeration that comes back empty is a broken enumeration, never a clean tree: the
# globs below match 28 tracked files today and have never legitimately matched none. Skipping the
# scan on empty would leave `fail` at 0 and let this script's closing line still claim the frontend
# was scanned, so a moved or renamed `web/` directory would read as clean indefinitely.
enforce_nonempty_frontend() { # <newline-separated file list>
    [ -n "$1" ] && return 0
    echo "operator strings: the dashboard frontend enumeration returned zero files." >&2
    echo "A broken enumeration and a clean scan both report zero hits — refusing to call either a pass." >&2
    echo "Check the git ls-files globs in this script against dashboard/mining_dashboard/web/." >&2
    return 1
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
    printf '%s\n' '    error "install it ($DOCS_URL/docs/getting-started.md#1-prerequisites)."' >"$tmp/anchor.sh"
    expect "a numbered heading anchor in a \$DOCS_URL pointer is not an issue reference" clean "$(scan_pithead "$tmp/anchor.sh")"
    printf '%s\n' '        dr_warn "cosign.pub missing (#376)."' >"$tmp/dr.sh"
    expect "a dr_* call carrying #NNN is flagged by the issue-number rule" hit "$(scan_pithead "$tmp/dr.sh")"
    printf '%s\n' '            _upg_fail "signature verification FAILED (#376)."' >"$tmp/upg.sh"
    expect "an _upg_* call carrying #NNN is flagged by the issue-number rule" hit "$(scan_pithead "$tmp/upg.sh")"

    printf '%s\n' '    error "set it — see docs/configuration.md."' >"$tmp/docs.sh"
    expect "operator text naming a bare repo doc path is flagged" hit "$(scan_pithead_docs "$tmp/docs.sh")"
    printf '%s\n' '        dr_warn "install it: docs/dev/releasing.md"' >"$tmp/docs-wide.sh"
    expect "the doctor/runner call shapes are covered by the docs rule" hit "$(scan_pithead_docs "$tmp/docs-wide.sh")"
    printf '%s\n' '    log "see $DOCS_URL/docs/workers.md#authentication."' '# docs/configuration.md in a comment' >"$tmp/docs-ok.sh"
    expect "a \$DOCS_URL pointer and a docs/ comment are not flagged" clean "$(scan_pithead_docs "$tmp/docs-ok.sh")"

    printf '%s\n' 'show_help() {' '    cat <<EOF' 'Tab-completion: see docs/operations.md.' 'EOF' '}' >"$tmp/heredoc.sh"
    expect "a bare doc path in a printed heredoc is flagged" hit "$(scan_pithead_docs "$tmp/heredoc.sh")"
    printf '%s\n' '    cat <<EOF >"$unit"' 'ExecStart=/usr/bin/thing --doc docs/operations.md' 'EOF' >"$tmp/heredoc-file.sh"
    expect "a redirected heredoc writes a file, not operator text" clean "$(scan_pithead_docs "$tmp/heredoc-file.sh")"
    printf '%s\n' '    cat <<EOF' 'Rendered after the fix landed (#42).' 'EOF' >"$tmp/heredoc-num.sh"
    expect "a #NNN in a printed heredoc is flagged" hit "$(scan_pithead "$tmp/heredoc-num.sh")"

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

    if enforce_nonempty_frontend "" 2>/dev/null; then
        echo "  self-test FAIL: an empty frontend enumeration was accepted"
        st_fail=1
    else echo "  self-test ok: an empty frontend enumeration is refused"; fi
    if enforce_nonempty_frontend "$tmp/hit.mjs" 2>/dev/null; then
        echo "  self-test ok: a non-empty frontend enumeration is accepted"
    else
        echo "  self-test FAIL: a non-empty frontend enumeration was refused"
        st_fail=1
    fi

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

if
    hits=$(scan_pithead_docs pithead)
    [ -n "$hits" ]
then
    echo "operator strings: repo-relative docs/ path in pithead operator text — release bundles ship no docs/."
    echo "Point at the published copy instead: \"\$DOCS_URL/docs/<file>.md#anchor\"."
    echo "$hits"
    fail=1
fi

# The static frontend, minus the *.min.js bundles.
#
# `|| true` is load-bearing and must stay. Under `set -o pipefail` an empty enumeration makes
# `grep -v` exit 1, which errexit turns into a silent death AT THIS ASSIGNMENT — before the
# refusal below can run. Swallowing that status is only safe BECAUSE the refusal checks the
# result; the two are one mechanism. Remove either and a broken enumeration stops explaining
# itself: without `|| true` the script dies anonymously, without the refusal it reports success.
files=$(git ls-files 'dashboard/mining_dashboard/web/static/*.mjs' \
    'dashboard/mining_dashboard/web/static/*.js' \
    'dashboard/mining_dashboard/web/templates/*.html' | grep -v '\.min\.js$' || true)
enforce_nonempty_frontend "$files" || exit 1

# shellcheck disable=SC2086
if
    hits=$(scan_frontend $files)
    [ -n "$hits" ]
then
    echo "operator strings: issue/PR number in a dashboard frontend user-visible string:"
    echo "$hits"
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "See CONTRIBUTING.md / docs/dev/STYLE.md — operator-facing text drops issue/PR references, comments keep them."
    exit 1
fi

echo "operator strings OK — no issue/PR numbers in pithead output or the dashboard frontend, no bare docs/ paths in pithead operator text"
