#!/usr/bin/env bash
#
# Scheduled-run watch (#1377).
#
# The Monday run of ci.yml IS the CVE sweep: `build-images` rebuilds every image and scans the
# rebuild (#833), `sweep-shipped` scans the published digests (#1313). A scheduled run has no pull
# request, so nothing draws a person to it — and on 2026-08-17 `build-images` went red and nobody
# was told for seven days. This watcher is that run's reader.
#
# WHY IT IS NOT A JOB INSIDE ci.yml. Two reasons, both measured rather than assumed:
#
#   1. SUBJECT. The one reader ci.yml already has is `sweep-shipped-report`, and its tracking issue
#      is titled "Shipped-image CVE sweep" — a title that is also the upsert key, so it cannot be
#      widened without orphaning the existing issue and filing a duplicate on the next run. Filing
#      a `build-images` red under it would put a finding about a REBUILD of the branch inside the
#      one report whose whole premise is that it scanned the bytes users pulled, and would make its
#      "Last fully successful sweep" stamp span two different questions.
#   2. IT GENERALISES. `build-images` is the job that reddened, but it is not the only job that can.
#      Watching the RUN covers every job the schedule reaches, including ones added later — the
#      failure mode of a per-job reader is that it silently stops covering the thing it was named
#      for.
#
# REPORT-ONLY, like its two siblings. A failed sweep is reported into a tracking issue rather than
# reddening this run, because "the Monday sweep found a CVE" asks for a decision a person makes,
# and because reddening a scheduled run is precisely the notification that was proven not to work.
# This run goes red only when the WATCHER could not do its job.
#
# WHAT THIS SCRIPT IS. It does no lookups and touches no network. The workflow calls `gh` and
# leaves two JSON files in a directory; this script reads them and renders the tracking-issue body.
# Keeping the render out of the workflow is what makes it testable: `--self-test` drives the clean
# path and every refusal below through fixtures, with no network and no gh. That matters more here
# than usual, because the red path CANNOT be exercised live — staging it would mean making the
# default branch's CI genuinely fail.
#
# INCOMPLETE IS NEVER CLEAN. Every refusal below exits 1 and says UNCHECKED rather than printing a
# reassuring "no failures". A watcher with nothing to say and a watcher that has quietly died look
# identical from the Actions tab.
#
#   - the directory is missing, or holds no runs file
#   - the runs file cannot be parsed, or lists no scheduled run at all
#   - the newest scheduled run has not finished, so nothing can be said about whether it passed
#   - the newest scheduled run failed and its jobs file is missing, unparseable, or names no job
#
# NOT COVERED, deliberately, and filed as #1418: a scheduled run that never HAPPENS. This watcher
# reads the runs it can see, so a dropped cron is invisible to it in exactly the way it is
# invisible to everything else. The history table below is the human-readable half of that — a
# reader can see the gap — but nothing here decides that a gap is too long.
#
# Usage:
#   scripts/scheduled-run-watch.sh <dir>    Render the report for the JSON in <dir> on stdout.
#                                           <dir>/runs.json  = gh run list --json ... (an array)
#                                           <dir>/jobs.json  = gh run view --json jobs (an object)
#                                           rc 1 if the watch could not do its job.
#   scripts/scheduled-run-watch.sh --title  Print the tracking issue's title, nothing else.
#   scripts/scheduled-run-watch.sh --self-test
#                                           Drive the render and every refusal above through
#                                           fixtures. No network, no gh.

set -Eeuo pipefail

# THE TITLE IS A CONSTANT AND MUST NEVER BE EDITED. The workflow upserts the tracking issue by
# EXACT title match over the open issue list. Change this string and the next run silently files a
# SECOND issue instead of updating the first, then keeps both — the old one frozen at whatever it
# last said, which reads as a watch that found nothing new. Renaming the issue by hand in the web
# UI breaks it the same way.
WATCH_ISSUE_TITLE="Scheduled CI run watch (weekly report)"

# How many past scheduled runs the history table prints. It exists to make a STREAK visible: the
# second-order finding from #1419 is that a gate red for nine consecutive runs has no transition
# left to make, so it can no longer signal a new break — and that is invisible in any report that
# shows only the newest run.
HISTORY_ROWS=6

usage() {
    sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# --- render helpers -----------------------------------------------------------------------------

# A conclusion as a table cell. `cancelled` and `timed_out` are NOT folded into failure: they mean
# the sweep did not run to completion, which is a different thing from the sweep finding something,
# and a reader deciding whether to cut a patch release needs to tell them apart.
conclusion_cell() {
    case "$1" in
    success) printf 'ok' ;;
    failure) printf '**FAILED**' ;;
    "") printf '**UNCHECKED** (no conclusion)' ;;
    *) printf '**%s**' "$1" ;;
    esac
}

render_report() {
    local dir="$1" runs newest id url created status conclusion rc=0

    printf 'The Monday run of `ci.yml` is the CVE sweep — `build-images` scans a rebuild of this\n'
    printf 'branch (#833) and `sweep-shipped` scans the published digests (#1313). A scheduled run\n'
    printf 'has no pull request, so nothing draws anyone to its red tick. This issue is its reader\n'
    printf '(#1377); it is rewritten in place every week.\n\n'

    if [ ! -d "$dir" ] || [ ! -s "$dir/runs.json" ]; then
        printf 'UNCHECKED: no run history was collected, so this report cannot say whether the\n'
        printf 'scheduled sweep ran, passed, or failed. See the run log.\n'
        return 1
    fi

    # Sort here rather than trusting gh to return newest-first: the ordering is not part of the
    # documented contract, and a report that names the wrong run as "newest" is worse than none.
    runs="$(jq -c 'sort_by(.createdAt) | reverse' "$dir/runs.json" 2>/dev/null || true)"
    if [ -z "$runs" ] || [ "$runs" = "null" ] || [ "$(printf '%s' "$runs" | jq -r 'length')" = "0" ]; then
        printf 'UNCHECKED: the run history could not be parsed, or lists no scheduled run at all.\n'
        printf 'A watcher that cannot see the runs it watches has not checked anything.\n'
        return 1
    fi

    newest="$(printf '%s' "$runs" | jq -c '.[0]')"
    id="$(printf '%s' "$newest" | jq -r '.databaseId // empty')"
    url="$(printf '%s' "$newest" | jq -r '.url // empty')"
    created="$(printf '%s' "$newest" | jq -r '.createdAt // empty')"
    status="$(printf '%s' "$newest" | jq -r '.status // empty')"
    conclusion="$(printf '%s' "$newest" | jq -r '.conclusion // empty')"

    printf '## The most recent scheduled run\n\n'
    printf '| Run | Started | Result |\n|---|---|---|\n'
    printf '| [%s](%s) | %s | %s |\n\n' "$id" "$url" "$created" "$(conclusion_cell "$conclusion")"

    if [ "$status" != "completed" ]; then
        printf 'UNCHECKED: that run has not finished (`status: %s`), so nothing here says whether\n' "${status:-unknown}"
        printf 'the sweep passed. An unfinished run is not a passing one.\n\n'
        rc=1
    elif [ "$conclusion" = "success" ]; then
        printf 'The sweep completed and found nothing it had to report.\n\n'
    else
        # Called for its OUTPUT and its rc, so it must not be captured: `rc=$(render_failed_jobs)`
        # assigns the rendered table to rc and drops it from the report — the table vanishes and
        # the exit code becomes a string. Caught by the self-test below, never by reading.
        render_failed_jobs "$dir" || rc=$?
    fi

    render_history "$runs"
    return "$rc"
}

# The failed-job table for a run that did not succeed. Returns 1 when the jobs could not be read —
# knowing the run failed while being unable to say WHICH job failed is a half-answer, and the
# report must not present it as a whole one.
render_failed_jobs() {
    local dir="$1" failed count
    if [ ! -s "$dir/jobs.json" ]; then
        printf 'UNCHECKED: the run failed, but its job list was not collected — this report cannot\n'
        printf 'name which job failed. See the run log.\n\n'
        return 1
    fi
    failed="$(jq -r '[.jobs[]? | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != null)]' "$dir/jobs.json" 2>/dev/null || true)"
    if [ -z "$failed" ] || [ "$failed" = "null" ]; then
        printf 'UNCHECKED: the run failed, but its job list could not be parsed.\n\n'
        return 1
    fi
    count="$(printf '%s' "$failed" | jq -r 'length')"
    if [ "$count" = "0" ]; then
        printf 'UNCHECKED: the run failed, but no failing job could be identified in its job list.\n'
        printf 'The failure is real — something outside the jobs, or a job list read too early.\n\n'
        return 1
    fi
    printf '## Jobs that did not pass\n\n'
    printf '| Job | Result |\n|---|---|\n'
    printf '%s' "$failed" | jq -r '.[] | "| `\(.name)` | \(.conclusion) |"'
    printf '\n'
    return 0
}

# The history table. A single red tells a reader almost nothing; a streak tells them the gate has
# stopped being an instrument (#1419).
render_history() {
    printf '## Recent scheduled runs\n\n'
    printf '| Run | Started | Result |\n|---|---|---|\n'
    printf '%s' "$1" | jq -r --argjson n "$HISTORY_ROWS" \
        '.[:$n][] | "| [\(.databaseId)](\(.url)) | \(.createdAt) | \(if .conclusion == "success" then "ok" elif .conclusion == null or .conclusion == "" then "(no conclusion)" else "**" + .conclusion + "**" end) |"'
    printf '\n'
}

# --- entry points -------------------------------------------------------------------------------

if [ "${1:-}" = "--title" ]; then
    printf '%s\n' "$WATCH_ISSUE_TITLE"
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

    # <dir> <conclusion-of-newest> [older-conclusions...]
    runs_fixture() {
        local dir="$1" i=0 c
        shift
        mkdir -p "$dir"
        for c in "$@"; do
            printf '{"databaseId":%d,"url":"https://x/%d","createdAt":"2026-08-%02dT05:00:00Z","status":"completed","conclusion":"%s"}\n' \
                $((100 + i)) $((100 + i)) $((28 - i)) "$c"
            i=$((i + 1))
        done | jq -s '.' >"$dir/runs.json"
    }
    jobs_fixture() { # <dir> <name:conclusion>...
        local dir="$1" spec
        shift
        for spec in "$@"; do
            printf '{"name":"%s","conclusion":"%s"}\n' "${spec%%:*}" "${spec##*:}"
        done | jq -s '{jobs: .}' >"$dir/jobs.json"
    }

    # The GREEN path has to be REACHABLE. A check that can only ever say "incomplete" is as
    # useless as one that only ever says "clean".
    # Eight runs against HISTORY_ROWS=6, so the cap is EXERCISED rather than merely configured. A
    # fixture smaller than the cap can never tell a working limit from an absent one.
    ok="$tmp/ok"
    runs_fixture "$ok" success success success success success success success success
    out="$(render_report "$ok")" && rc=0 || rc=$?
    hist() { printf '%s' "$1" | sed -n '/## Recent scheduled runs/,$p' | grep -c '^| \['; }
    st "a passing newest run exits 0" "$rc" "0"
    st "a passing run says so" "$(printf '%s' "$out" | grep -c 'found nothing it had to report')" "1"
    st "the history table is capped at HISTORY_ROWS" "$(hist "$out")" "$HISTORY_ROWS"
    st "a clean report names no failing job" "$(printf '%s' "$out" | grep -c 'did not pass')" "0"

    # A shorter history than the cap prints what exists, not a padded table.
    short="$tmp/short"
    runs_fixture "$short" success success
    out="$(render_report "$short")" && rc=0 || rc=$?
    st "a history shorter than the cap prints only the runs it has" "$(hist "$out")" "2"

    # A failed run is REPORTED, not reddened: rc stays 0 because the WATCHER did its job. This is
    # the assertion that separates this watcher from the red tick it exists to replace.
    red="$tmp/red"
    runs_fixture "$red" failure success success
    jobs_fixture "$red" "Build image (dashboard):failure" "Shell tests:success" "Lint:skipped"
    out="$(render_report "$red")" && rc=0 || rc=$?
    st "a FAILED newest run still exits 0 — it is a finding, not a broken watcher" "$rc" "0"
    st "the failing job is named" "$(printf '%s' "$out" | grep -cF 'Build image (dashboard)')" "1"
    st "a passing job is not listed as failing" "$(printf '%s' "$out" | grep -cF '| `Shell tests` |')" "0"
    st "a SKIPPED job is not listed as failing" "$(printf '%s' "$out" | grep -cF '| `Lint` |')" "0"
    st "the newest row is marked FAILED" "$(printf '%s' "$out" | grep -c '\*\*FAILED\*\*')" "1"

    # --- the refusals. Each is pinned on the ONE input only it rejects. ---

    miss="$tmp/missing"
    out="$(render_report "$miss")" && rc=0 || rc=$?
    st "a missing directory fails" "$rc" "1"
    st "a missing directory says UNCHECKED" "$(printf '%s' "$out" | grep -c UNCHECKED)" "1"

    empty="$tmp/empty"
    mkdir -p "$empty"
    printf '[]\n' >"$empty/runs.json"
    out="$(render_report "$empty")" && rc=0 || rc=$?
    st "an empty run list fails" "$rc" "1"

    bad="$tmp/bad"
    mkdir -p "$bad"
    printf 'not json at all\n' >"$bad/runs.json"
    out="$(render_report "$bad")" && rc=0 || rc=$?
    st "an unparseable run list fails" "$rc" "1"

    # An unfinished run is the case a naive reader calls "not failed". It is UNCHECKED.
    running="$tmp/running"
    mkdir -p "$running"
    printf '[{"databaseId":1,"url":"https://x/1","createdAt":"2026-08-31T05:00:00Z","status":"in_progress","conclusion":null}]\n' >"$running/runs.json"
    out="$(render_report "$running")" && rc=0 || rc=$?
    st "an unfinished newest run fails rather than reading as passing" "$rc" "1"
    st "an unfinished run is not called a success" "$(printf '%s' "$out" | grep -c 'found nothing')" "0"

    # Knowing a run failed but not WHICH job is a half-answer and must not read as a whole one.
    nojobs="$tmp/nojobs"
    runs_fixture "$nojobs" failure success
    out="$(render_report "$nojobs")" && rc=0 || rc=$?
    st "a failed run with no jobs file fails" "$rc" "1"

    badjobs="$tmp/badjobs"
    runs_fixture "$badjobs" failure success
    printf 'nope\n' >"$badjobs/jobs.json"
    out="$(render_report "$badjobs")" && rc=0 || rc=$?
    st "a failed run with an unparseable jobs file fails" "$rc" "1"

    nofail="$tmp/nofail"
    runs_fixture "$nofail" failure success
    jobs_fixture "$nofail" "Shell tests:success"
    out="$(render_report "$nofail")" && rc=0 || rc=$?
    st "a failed run whose jobs all passed fails rather than reporting nothing" "$rc" "1"

    # Every case above calls render_report inside an `&&` list, where bash suppresses `set -e` for
    # the whole dynamic extent of the call — so none of them can see an error-exit that only bites
    # the way CI actually invokes this: bare, in its own process.
    out="$(bash "${BASH_SOURCE[0]}" "$ok")" && rc=0 || rc=$?
    st "the clean path survives a real subprocess invocation" "$rc" "0"
    out="$(bash "${BASH_SOURCE[0]}" "$red")" && rc=0 || rc=$?
    st "a reported failure survives a real subprocess invocation, still 0" "$rc" "0"
    out="$(bash "${BASH_SOURCE[0]}" "$empty")" && rc=0 || rc=$?
    st "a refusal still exits 1 from a real subprocess" "$rc" "1"

    # The title is the upsert key; a change here silently files a second issue for ever.
    st "--title prints the constant and nothing else" \
        "$(bash "${BASH_SOURCE[0]}" --title)" "$WATCH_ISSUE_TITLE"

    [ "$st_fail" = 0 ] && echo "scheduled-run-watch self-test OK"
    exit "$st_fail"
fi

if [ $# -ne 1 ] || [ "${1:0:2}" = "--" ]; then
    usage >&2
    exit 2
fi

render_report "$1"
