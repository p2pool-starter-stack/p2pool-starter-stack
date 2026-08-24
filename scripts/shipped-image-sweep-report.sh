#!/usr/bin/env bash
#
# Shipped-image CVE sweep report (#1313).
#
# The Monday sweep in ci.yml rebuilds every image from the branch and scans the rebuild. That
# cannot answer the question users care about. A rebuild resolves apt at scan time, so it picks up
# archive fixes the published image never got — the sweep goes green while the bytes people are
# running still carry the CVE. It also scans the default branch, not the release. This report
# covers the other half: the images published at cut time, promoted by digest with no rebuild
# (release.sh stage 6 is `buildx imagetools create`, a re-tag), scanned exactly as published.
#
# REPORT-ONLY, and that posture is deliberate. A CVE in a shipped image is a fact to act on — it
# means "consider cutting a patch release", a decision a person makes — not a build to fail. The
# run goes red only when the sweep itself could not do its job.
#
# WHAT THIS SCRIPT IS. It does no scanning and touches no network. ci.yml's `sweep-shipped` matrix
# resolves each published tag to a digest, scans that digest with trivy, and uploads two files per
# image; this script reads that directory and renders the tracking-issue body. Keeping the render
# out of the workflow is what makes it testable — `--self-test` drives every failure mode below
# through fixtures with no docker, no network, and no GitHub.
#
# INCOMPLETE IS NEVER CLEAN. Every refusal below exits 1 and says UNCHECKED in the report rather
# than printing a reassuring zero. This is the defect class the whole currency lane exists for: a
# watcher with nothing to say and a watcher that has quietly died look identical from the Actions
# tab, and "0 findings" off a partial run is the most expensive kind of false green.
#
#   - the artifact directory is missing, or holds no scan output at all
#   - an expected image produced no report (its matrix leg failed)
#   - an unexpected image appeared (ci.yml's matrix and SWEPT_IMAGES below have drifted)
#   - a report cannot be parsed
#   - a report names an artifact that is NOT a digest reference, so the run cannot honestly claim
#     it scanned published bytes rather than a moving tag
#   - a report's artifact is a different image than the leg it arrived as
#   - the legs disagree about which release tag they swept (a cut landed mid-run)
#
# Usage:
#   scripts/shipped-image-sweep-report.sh <dir>   Render the report for the artifacts in <dir> on
#                                                  stdout. rc 1 if the sweep was incomplete.
#   scripts/shipped-image-sweep-report.sh --title  Print the tracking issue's title, nothing else.
#   scripts/shipped-image-sweep-report.sh --self-test
#                                                  Drive the render + every refusal above through
#                                                  fixtures. No network, no docker, no gh.

set -Eeuo pipefail

# THE TITLE IS A CONSTANT AND MUST NEVER BE EDITED. The workflow upserts the tracking issue by
# EXACT title match over the open issue list. Change this string and the next run silently files a
# SECOND issue instead of updating the first, then keeps both — the old one frozen at whatever it
# last said, which reads as a sweep that found nothing new. Renaming the issue by hand in the web
# UI breaks it the same way.
SWEEP_ISSUE_TITLE="Shipped-image CVE sweep (weekly report)"

# The images this report expects to find, which must match ci.yml's `sweep-shipped` matrix. The
# two lists are checked against each other at run time rather than trusted: a service added to the
# matrix and not here arrives as an unexpected file, one added here and not to the matrix arrives
# as a missing leg, and BOTH exit 1. A silently shrinking sweep is the failure this guards.
SWEPT_IMAGES="monero p2pool tor xmrig-proxy dashboard"

# Only fixable HIGH/CRITICAL are counted, the same scope ci.yml's gate uses (`ignore-unfixed`), and
# the same scope every `.trivyignore` entry is written against. It is also the only scope that maps
# to a decision: a patch release can only ship a fix that exists. Unfixed findings are left to the
# gate's own reporting rather than counted here as if someone could act on them. This is the label
# the table header prints; the jq filter below spells the same two out literally.
SEVERITY_LABEL="HIGH/CRITICAL"

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- render helpers ---------------------------------------------------------------------------

# Shorten a digest for the summary table; the full value is printed in the per-image section, so
# nothing is lost. `sha256:5da0208411…` is enough to eyeball against `docker inspect` output.
short_digest() {
    printf '%s…' "${1:0:20}"
}

# Every HIGH/CRITICAL row in a trivy JSON report, as TSV: id, severity, package, installed, fixed.
# `.Results[]?` and `.Vulnerabilities[]?` are both optional-indexed on purpose — a clean image
# reports Results with no Vulnerabilities key at all, which is a legitimate zero, not a parse
# failure. A genuinely unreadable file fails in render_report() before this runs.
findings_tsv() {
    jq -r '
        [ .Results[]? | .Vulnerabilities[]? ]
        | map(select(.Severity == "HIGH" or .Severity == "CRITICAL"))
        | sort_by(.Severity, .VulnerabilityID)
        | .[]
        | [ .VulnerabilityID, .Severity, .PkgName,
            (.InstalledVersion // ""), (.FixedVersion // "") ]
        | @tsv
    ' "$1"
}

# --- the report -------------------------------------------------------------------------------

# Reads <dir>, prints the markdown body on stdout, returns 1 if the sweep was incomplete.
render_report() {
    local dir="$1"
    local rc=0
    local svc file tagfile ref tag
    local summary="" details="" problems=""
    local tag_seen="" tag_conflict=0
    local expected

    if [ ! -d "$dir" ]; then
        printf 'The sweep produced no artifact directory at all (`%s` does not exist).\n' "$dir"
        printf '\nEvery shipped image is UNCHECKED. See the run log.\n'
        return 1
    fi

    # An unexpected report means ci.yml's matrix grew and SWEPT_IMAGES did not. Catch it before
    # rendering, because the summary table below is keyed on SWEPT_IMAGES and would simply not
    # show the new image — a sweep that silently omits an image is exactly what #1313 is about.
    for file in "$dir"/sweep-*.json; do
        [ -e "$file" ] || continue
        svc="$(basename "$file" .json)"
        svc="${svc#sweep-}"
        expected=0
        for s in $SWEPT_IMAGES; do
            [ "$s" = "$svc" ] && expected=1 && break
        done
        if [ "$expected" -eq 0 ]; then
            problems="${problems}- \`$svc\` was swept but is not in this report's image list — ci.yml's \`sweep-shipped\` matrix and \`SWEPT_IMAGES\` in \`scripts/shipped-image-sweep-report.sh\` have drifted apart.
"
            rc=1
        fi
    done

    for svc in $SWEPT_IMAGES; do
        file="$dir/sweep-$svc.json"
        tagfile="$dir/sweep-$svc.tag"

        if [ ! -s "$file" ]; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\` produced no scan report; its matrix leg did not finish. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        if ! ref="$(jq -er '.ArtifactName' "$file" 2>/dev/null)"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\`'s scan report could not be parsed. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        # The whole point of the change is that we scanned published bytes. A tag reference here
        # would mean the digest resolve fell through, and reporting it as a shipped-image result
        # would be a lie of exactly the shape #1313 was filed about.
        if ! printf '%s' "$ref" | grep -Eq "/pithead-$svc@sha256:[0-9a-f]{64}\$"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\` reports artifact \`$ref\`, which is not a digest reference to \`pithead-$svc\`. Nothing here proves the published image was scanned, so it is UNCHECKED.
"
            rc=1
            continue
        fi

        if [ -s "$tagfile" ]; then
            tag="$(tr -d '[:space:]' <"$tagfile")"
            if [ -z "$tag_seen" ]; then
                tag_seen="$tag"
            elif [ "$tag" != "$tag_seen" ]; then
                tag_conflict=1
            fi
        fi

        # Captured, not piped in from a process substitution: a jq failure inside `< <(...)` is
        # invisible to `set -e`, so a report whose Results array is malformed would render as a
        # confident zero. Same rule as everywhere else here — unreadable is UNCHECKED.
        local tsv
        if ! tsv="$(findings_tsv "$file")"; then
            summary="${summary}| \`pithead-$svc\` | — | **UNCHECKED** |
"
            problems="${problems}- \`$svc\`'s findings could not be read out of its scan report. This image is UNCHECKED, not clean.
"
            rc=1
            continue
        fi

        local fixable=0 id sev pkg installed fixed rows=""
        while IFS=$'\t' read -r id sev pkg installed fixed; do
            [ -n "$id" ] || continue
            [ -n "$fixed" ] || continue
            fixable=$((fixable + 1))
            rows="${rows}| \`$id\` | $sev | \`$pkg\` | \`$installed\` | \`$fixed\` |
"
        done <<<"$tsv"

        if [ "$fixable" -eq 0 ]; then
            summary="${summary}| \`pithead-$svc\` | \`$(short_digest "${ref#*@}")\` | 0 |
"
        else
            summary="${summary}| \`pithead-$svc\` | \`$(short_digest "${ref#*@}")\` | **$fixable** |
"
            details="${details}
### \`pithead-$svc\` — $fixable fixable

Scanned \`$ref\`.

| CVE | severity | package | installed | fixed in |
| --- | --- | --- | --- | --- |
${rows}"
        fi
    done

    if [ "$tag_conflict" -eq 1 ]; then
        problems="${problems}- The legs did not sweep the same release tag, so this report mixes two releases. A cut probably landed mid-run; the next run will settle it.
"
        rc=1
    fi

    printf 'The images users actually pull, scanned as published. Each tag is resolved to a digest\n'
    printf 'first and the digest is what trivy reads, so this reports the bytes on the registry — not\n'
    printf 'a rebuild, which would resolve apt afresh and hide the very CVEs this exists to find.\n'
    if [ -n "$tag_seen" ]; then
        printf '\nRelease swept: **%s** (from `main`, scanned against `main`'"'"'s own `.trivyignore`).\n' "$tag_seen"
    fi
    printf '\n| image | digest | fixable %s |\n| --- | --- | --- |\n' "$SEVERITY_LABEL"
    printf '%s' "$summary"

    if [ -n "$problems" ]; then
        printf '\n## This sweep did not complete\n\n%s' "$problems"
    fi

    if [ -n "$details" ]; then
        printf '%s' "$details"
        printf '\nA finding here means the published image carries a CVE with a fix available. The\n'
        printf 'decision it asks for is whether to cut a patch release, so this reports and never\n'
        printf 'fails the build.\n'
    elif [ "$rc" -eq 0 ]; then
        printf '\nNo fixable HIGH/CRITICAL in any shipped image.\n'
    fi

    return "$rc"
}

# --- entry points -------------------------------------------------------------------------------

if [ "${1:-}" = "--title" ]; then
    printf '%s\n' "$SWEEP_ISSUE_TITLE"
    exit 0
fi

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

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # <dir> <service> <artifact-ref> <vuln-json-array>
    fixture() {
        mkdir -p "$1"
        jq -n --arg a "$3" --argjson v "$4" \
            '{ArtifactName: $a, Results: [{Target: "t", Vulnerabilities: $v}]}' \
            >"$1/sweep-$2.json"
        printf 'v1.20.0\n' >"$1/sweep-$2.tag"
    }
    ref_for() { printf 'ghcr.io/p2pool-starter-stack/pithead-%s@sha256:%064d' "$1" "$2"; }

    # A whole clean sweep. The green path has to be REACHABLE — a check that can only ever say
    # "incomplete" is as useless as one that only ever says "clean".
    clean="$tmp/clean"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$clean" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    out="$(render_report "$clean")" && rc=0 || rc=$?
    st "a complete clean sweep passes" "$rc" "0"
    st "a clean sweep says so" \
        "$(printf '%s' "$out" | grep -c 'No fixable HIGH/CRITICAL')" "1"
    st "every image appears in the summary" \
        "$(printf '%s' "$out" | grep -c '^| `pithead-')" "5"

    # Findings are counted, and only the FIXABLE ones.
    found="$tmp/found"
    i=1
    for s in $SWEPT_IMAGES; do
        if [ "$s" = dashboard ]; then
            fixture "$found" "$s" "$(ref_for "$s" "$i")" '[
                {"VulnerabilityID":"CVE-2026-1","Severity":"HIGH","PkgName":"libfoo",
                 "InstalledVersion":"1.0","FixedVersion":"1.1"},
                {"VulnerabilityID":"CVE-2026-2","Severity":"CRITICAL","PkgName":"libbar",
                 "InstalledVersion":"2.0","FixedVersion":"2.1"},
                {"VulnerabilityID":"CVE-2026-3","Severity":"HIGH","PkgName":"libbaz",
                 "InstalledVersion":"3.0"}
            ]'
        else
            fixture "$found" "$s" "$(ref_for "$s" "$i")" '[]'
        fi
        i=$((i + 1))
    done
    out="$(render_report "$found")" && rc=0 || rc=$?
    st "a finding is reported, not failed" "$rc" "0"
    st "only the fixable findings are counted" \
        "$(printf '%s' "$out" | grep -c '`pithead-dashboard` — 2 fixable')" "1"
    st "the unfixable finding is not in the table" \
        "$(printf '%s' "$out" | grep -c 'CVE-2026-3')" "0"
    st "the finding's own digest is named in full" \
        "$(printf '%s' "$out" | grep -c "Scanned \`$(ref_for dashboard 5)\`")" "1"

    # Every refusal. Each must exit 1 AND say UNCHECKED — a quiet zero is the bug.
    miss="$tmp/miss"
    i=1
    for s in $SWEPT_IMAGES; do
        [ "$s" = tor ] || fixture "$miss" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    out="$(render_report "$miss")" && rc=0 || rc=$?
    st "a leg that did not finish fails the run" "$rc" "1"
    st "the missing image reads UNCHECKED, never clean" \
        "$(printf '%s' "$out" | grep -c '`pithead-tor` | — | \*\*UNCHECKED\*\*')" "1"
    # On the PROBLEM TEXT, not just the UNCHECKED row. The missing-file guard and the
    # unparseable-report guard below it emit an identical summary row and an identical rc, so an
    # assertion on either of those passes whichever guard fired — deleting the missing-file check
    # outright left this whole block green until it was checked by mutation. Each guard is now
    # named by the one sentence only it writes.
    st "the missing leg is diagnosed as a leg that did not finish" \
        "$(printf '%s' "$out" | grep -c 'produced no scan report; its matrix leg did not finish')" "1"
    st "a missing leg is not misreported as an unparseable one" \
        "$(printf '%s' "$out" | grep -c 'could not be parsed')" "0"

    extra="$tmp/extra"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$extra" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    fixture "$extra" newsvc "$(ref_for newsvc 9)" '[]'
    out="$(render_report "$extra")" && rc=0 || rc=$?
    st "an image the report does not know about fails the run" "$rc" "1"
    st "the drift is named" "$(printf '%s' "$out" | grep -c 'drifted apart')" "1"

    bad="$tmp/bad"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$bad" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    printf 'not json at all' >"$bad/sweep-monero.json"
    out="$(render_report "$bad")" && rc=0 || rc=$?
    st "an unparseable report fails the run" "$rc" "1"
    st "an unparseable report reads UNCHECKED" \
        "$(printf '%s' "$out" | grep -c 'could not be parsed')" "1"
    st "an unparseable report is not misreported as a missing leg" \
        "$(printf '%s' "$out" | grep -c 'its matrix leg did not finish')" "0"

    # The load-bearing one. If the digest resolve fell through and trivy scanned a TAG, the run
    # must not claim it swept published bytes — that is #1313's own defect, one level in.
    tagref="$tmp/tagref"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$tagref" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    fixture "$tagref" p2pool "ghcr.io/p2pool-starter-stack/pithead-p2pool:v1.20.0" '[]'
    out="$(render_report "$tagref")" && rc=0 || rc=$?
    st "a tag scan is refused, not reported as a shipped-image result" "$rc" "1"
    st "the tag scan reads UNCHECKED" \
        "$(printf '%s' "$out" | grep -c 'not a digest reference')" "1"

    swap="$tmp/swap"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$swap" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    fixture "$swap" tor "$(ref_for monero 3)" '[]'
    out="$(render_report "$swap")" && rc=0 || rc=$?
    st "a leg that scanned the wrong image fails the run" "$rc" "1"

    conflict="$tmp/conflict"
    i=1
    for s in $SWEPT_IMAGES; do
        fixture "$conflict" "$s" "$(ref_for "$s" "$i")" '[]'
        i=$((i + 1))
    done
    printf 'v1.19.3\n' >"$conflict/sweep-tor.tag"
    out="$(render_report "$conflict")" && rc=0 || rc=$?
    st "legs that swept different releases fail the run" "$rc" "1"

    out="$(render_report "$tmp/nothing-here")" && rc=0 || rc=$?
    st "a missing artifact directory fails the run" "$rc" "1"
    st "a missing artifact directory does not print a clean table" \
        "$(printf '%s' "$out" | grep -c 'No fixable')" "0"

    empty="$tmp/empty"
    mkdir -p "$empty"
    out="$(render_report "$empty")" && rc=0 || rc=$?
    st "an empty artifact directory fails the run" "$rc" "1"

    # Every case above calls render_report inside an `&&` list, where bash suppresses `set -e`
    # for the whole dynamic extent of the call — so none of them can see an error-exit that only
    # bites the way CI actually invokes this: bare, in its own process. Drive the green path
    # through a real subprocess once, or the suite is proving the logic and not the script.
    out="$(bash "${BASH_SOURCE[0]}" "$clean")" && rc=0 || rc=$?
    st "the clean path survives a real subprocess invocation" "$rc" "0"
    st "the subprocess renders the same table" \
        "$(printf '%s' "$out" | grep -c '^| `pithead-')" "5"
    out="$(bash "${BASH_SOURCE[0]}" "$miss")" && rc=0 || rc=$?
    st "an incomplete sweep still exits 1 from a real subprocess" "$rc" "1"

    # The title is the upsert key; a change here silently files a second issue for ever.
    st "--title prints the constant and nothing else" \
        "$(bash "${BASH_SOURCE[0]}" --title)" "$SWEEP_ISSUE_TITLE"

    [ "$st_fail" = 0 ] && echo "shipped-image-sweep-report self-test OK"
    exit "$st_fail"
fi

if [ $# -ne 1 ] || [ "${1:0:2}" = "--" ]; then
    usage >&2
    exit 2
fi

render_report "$1"
