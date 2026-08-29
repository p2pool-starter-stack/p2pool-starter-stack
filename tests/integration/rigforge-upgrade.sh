# shellcheck shell=bash
#
# The RigForge one-click upgrade legs (#1002a noop, #1237 real upgrade).
#
# WHY THIS FILE EXISTS, AND WHAT WAS WRONG BEFORE (#1237)
#
# The old leg lived in run.sh and read, in full: take the rig's OWN reported version out of
# /api/state, POST it back to /api/control/worker-upgrade, assert the terminal status is "noop".
# It was documented as exercising "the real dashboard -> host-runner -> rig /upgrade route end to
# end". It cannot. It is a tautology, and the chain is short enough to state completely:
#
#   1. /api/state is build_state(app["latest_data"], ...) and build_workers copies the rig's
#      version through verbatim (xmrig_client.parse_rigforge -> infra_views._rigforge_display).
#   2. handle_worker_upgrade reads `running` from that SAME app["latest_data"] — the poll loop
#      mutates that dict in place (data_service `self.latest_data.update({...})`), it never
#      rebinds it — and short-circuits to a synchronous {"status":"noop"} when
#      parse_semver(running) == parse_semver(version).
#   3. The harness sets version FROM running. So the comparison is true by construction.
#
# The request therefore returned noop without ever reaching control_service.submit_worker_upgrade,
# the host runner, or the rig. The single assertion could only fail if the rig's reported version
# changed between the two reads — which requires a real upgrade, the one thing not under test.
# Combined with the flag (--rigforge-upgrade) that no caller sets, the gate's only upgrade
# coverage was an opt-in check that could not go red. That is this lane's subject in miniature.
#
# WHAT REPLACES IT: the precondition split
#
# The old leg had an unstated precondition — "the rig is already on latest" — and asserted a
# result that holds whether or not it is true. Make the precondition the SELECTOR instead and both
# branches become falsifiable, because each one asserts WHICH path the request took:
#
#   rig behind latest  -> the REAL upgrade. POST latest. The shortcut cannot fire (running !=
#                         version), so a 202 {"id", "status":"pending"} is itself the proof that
#                         the request left the dashboard process. Then poll to terminal, require
#                         `applied`, and require the rig to come back reporting latest AND hashing.
#                         Having put the rig on latest and verified it, run the noop leg after it:
#                         its precondition is now something we established rather than assumed.
#   otherwise          -> skip, loudly and classified. `.rigforge_update` is null for THREE
#                         different states (on latest / ahead of latest / no release cached,
#                         compute_update returns None for all of them) and nothing else in
#                         /api/state distinguishes them — `rigforge_release` is consumed by
#                         build_workers and never re-exposed. So the honest answer is "cannot
#                         tell", and the skip reason names both branches rather than picking one.
#
# On a rig already on latest this reports a classified skip where the old leg reported a pass.
# That is the point: a skip that announces itself is worth more than a green that proves nothing
# (#1083/#1444's whole argument, applied to this lane's own instrument).
#
# NOT COVERED, and it is a real limit rather than an oversight: this leg cannot exercise the
# rig's REBUILD path. rigforge#413 — XMRIG_VERSION/XMRIG_COMMIT are byte-identical at all 25
# published tags, so `rigforge.sh upgrade` takes its early return on every published release pair
# and the one-click path checks out the new tree without recompiling, regenerating config or
# reinstalling units. No pair of published tags exercises the rebuild, so no choice of tags here
# would cover it; saying so is the honest report, not a gap this file can close.
#
# Sourced by run.sh, which supplies api_state/rx/quote_arg (lib.sh), the assert_* helpers,
# it_skip_leg (skip-accounting.sh) and wait_for. Every function here is drivable standalone
# against stubs — that is the tier the mutation proofs live at (selftest-rigforge-upgrade.sh),
# not a bench.

# How long to wait for the rig to come back reporting the new version after a terminal upgrade.
# The host's own poll cap is 90s (CONTROL_WU_POLL_CAP) and it hands back "accepted" rather than a
# failure when the rig is still working, so the harness has to be able to outlast it: the rig's
# version reaches the dashboard on the per-rig summary poll, not on the upgrade result.
IT_UPGRADE_SETTLE_TIMEOUT="${IT_UPGRADE_SETTLE_TIMEOUT:-300}"

# The dashboard's own upgrade verdict for one rig, straight off /api/state: "<available>|<latest>".
# This is `rigforge_update` (#596) — the SAME {available, latest, url} the Worker Inspect button
# renders and submits — so driving it drives what a click drives, rather than a value the harness
# picked. Both fields empty when the dashboard offers no update for this rig.
_rig_update_verdict() { # <state-json> <rig> -> "<available>|<latest>"
    printf '%s' "$1" | jq -r --arg n "$2" '
        first(.workers[]? | select(.name==$n) | .rigforge_update) as $u
        | if ($u | type) == "object"
          then "\($u.available // false)|\($u.latest // "")"
          else "|" end' 2>/dev/null
}

# The rig's own reported RigForge version off /api/state, bare (no leading v) or empty.
_rig_reported_version() { # <state-json> <rig>
    printf '%s' "$1" | jq -r --arg n "$2" \
        'first(.workers[]? | select(.name==$n) | .rigforge.version) // empty' 2>/dev/null
}

# Predicate for wait_for: the rig now reports <version> (compared bare, since the rig reports
# "1.16.0" while the release tag is "v1.16.0" — the same normalization compute_update does).
_pred_rig_version_is() { # <rig> <want-version>
    local got
    got="$(_rig_reported_version "$(api_state)" "$1")"
    [ -n "$got" ] && [ "${got#v}" = "${2#v}" ]
}

# POST one upgrade intent and hand back the raw body. Deliberately NOT -f: the interesting answers
# include the synchronous 200 noop and the 202 pending, and a shape assertion on the body is what
# tells the two apart — an -f that swallowed an error page would erase exactly that signal.
_post_worker_upgrade() { # <rig> <version> -> response body
    rx "curl -sS --max-time 15 -X POST -H 'Content-Type: application/json' -H 'X-Pithead-Control: 1' \
        --data $(quote_arg "$(jq -nc --arg w "$1" --arg v "$2" '{worker:$w,version:$v}')") \
        http://127.0.0.1:8000/api/control/worker-upgrade" 2>/dev/null
}

# Poll /api/control/result for <id> until it leaves the non-terminal vocabulary, or the deadline.
# Non-terminal is pending/running/empty; everything else is the host's answer of record
# (applied/noop/throttled/rolled_back/failed/rejected/accepted — pithead's control_worker_upgrade).
_poll_upgrade_result() { # <id> <timeout-s> -> terminal status (empty on timeout)
    local id="$1" deadline=$((SECONDS + $2)) body status
    while [ "$SECONDS" -lt "$deadline" ]; do
        sleep 5
        body="$(rx "curl -fsS --max-time 10 $(quote_arg "http://127.0.0.1:8000/api/control/result?id=$id")" 2>/dev/null)"
        status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)"
        case "$status" in "" | pending | running) continue ;; esac
        printf '%s' "$status"
        return 0
    done
    return 0
}

# The noop leg (#1002a), with its precondition ESTABLISHED rather than assumed: only ever called
# after the real leg has put the rig on <version> and verified the rig reports it.
#
# What it proves is narrow and worth proving: a repeat click on an up-to-date rig is answered by
# the dashboard synchronously and never dials the rig, so it costs the rig none of its own 6h
# anti-beacon window. The assertion is therefore on the SHAPE of the answer, not just its status —
# a synchronous noop carries no `id`, while anything that reached the host runner carries the id
# the client would poll. Asserting `status == noop` alone is what made the old leg vacuous; the
# absent id is the part that says the shortcut, and not the long way round, produced it.
_rigforge_upgrade_noop_leg() { # <rig> <version-tag>
    local body status id
    body="$(_post_worker_upgrade "$1" "$2")"
    status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)"
    id="$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)"
    assert_eq "a repeat upgrade click on an up-to-date rig answers noop (#1002a)" "$status" "noop"
    if [ -n "$id" ]; then
        it_fail "the noop answer is the dashboard's synchronous shortcut, not a rig dial (#1002a)" \
            "the response carried a pollable id [$id] — the request reached the host runner and spent the rig's throttle"
    else
        it_pass "the noop answer is the dashboard's synchronous shortcut, not a rig dial (#1002a)"
    fi
}

# The real upgrade leg (#1237): drive an actual version change through the product path.
_rigforge_upgrade_real_leg() { # <rig> <latest-tag>
    local rig="$1" tag="$2" body status id
    it_step "   #1237: driving a REAL upgrade to $tag through /api/control/worker-upgrade…"
    body="$(_post_worker_upgrade "$rig" "$tag")"
    status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null)"
    id="$(printf '%s' "$body" | jq -r '.id // empty' 2>/dev/null)"

    # THE assertion the old leg could not make. The rig is behind $tag, so handle_worker_upgrade's
    # already-on-this-version shortcut cannot fire; a pending status with a pollable id is proof
    # the intent left the dashboard process for the host runner. A noop here would mean the
    # shortcut fired anyway — i.e. the dashboard believes the rig is already on $tag while
    # rigforge_update says it is not — and that is a contradiction worth failing on, not skipping.
    if [ "$status" != "pending" ] || [ -z "$id" ]; then
        it_fail "a real upgrade leaves the dashboard for the host runner (#1237)" \
            "expected a 202 pending with a pollable id, got status [$status] id [$id] from [$body]"
        return 0
    fi
    it_pass "a real upgrade leaves the dashboard for the host runner (#1237)"

    status="$(_poll_upgrade_result "$id" "$IT_UPGRADE_SETTLE_TIMEOUT")"

    # The rig's own 6h anti-beacon window (rigforge#320) is rig STATE, not a product fault: a
    # recent upgrade attempt on this rig makes the real path structurally unavailable for this
    # run, and no input to this harness changes that. by-design, and loud.
    if [ "$status" = "throttled" ]; then
        it_skip_leg "real rig upgrade (#1237)" \
            "the rig refused with its own 6h anti-beacon throttle (rigforge#320) — a recent upgrade attempt on this rig makes the real path unavailable this run" \
            "by-design"
        return 0
    fi

    # "accepted" is the host's poll cap (90s) expiring, NOT a failure — pithead says so where it
    # writes it. The rig is still working and the confirmation of record is its next summary, so
    # settle against the rig itself rather than reading the cap as a red. Same promotion shape as
    # _settle_worker_apply uses for worker-apply (#1309).
    if [ "$status" = "accepted" ]; then
        it_step "   host poll cap expired with the upgrade still running — settling against the rig's own report…"
        if wait_for "$IT_UPGRADE_SETTLE_TIMEOUT" 10 "the rig to come back reporting $tag" \
            _pred_rig_version_is "$rig" "$tag"; then
            status="applied"
        fi
    fi

    if [ "$status" != "applied" ]; then
        it_fail "the one-click upgrade reaches a real applied terminal (#1237)" \
            "expected applied, got [${status:-<no terminal inside ${IT_UPGRADE_SETTLE_TIMEOUT}s>}]"
        # Deliberately the end of the leg. The readback below would red too — the rig cannot be on
        # a version the upgrade did not reach — and that second red is the SAME evidence counted
        # twice. One cause, one failure; the reader needs the count to mean something.
        return 0
    fi
    it_pass "the one-click upgrade reaches a real applied terminal (#1237)"

    # Version is a separate claim from the terminal, not a restatement of it. #1237 exists because
    # the path was never proven to bring the rig BACK: `applied` is the host's report of what the
    # rig said, while this reads what the rig now IS, on the dashboard's own summary poll.
    if wait_for "$IT_UPGRADE_SETTLE_TIMEOUT" 10 "the rig to report $tag after the upgrade" \
        _pred_rig_version_is "$rig" "$tag"; then
        it_pass "the rig comes back reporting the upgraded version $tag (#1237)"
    else
        it_fail "the rig comes back reporting the upgraded version $tag (#1237)" \
            "the rig still reports [$(_rig_reported_version "$(api_state)" "$rig")] after ${IT_UPGRADE_SETTLE_TIMEOUT}s"
    fi
}

# Dispatcher. Picks the branch from the DASHBOARD's verdict (#596 rigforge_update), which is the
# same input the Worker Inspect upgrade button uses, so the leg selects the way a user's click
# would rather than on a comparison of the harness's own devising.
run_rigforge_upgrade() { # <rig-name>
    local rig="$1" state ver avail latest
    it_log "   #1002a/#1237: the one-click RigForge upgrade path"
    state="$(api_state)"
    ver="$(_rig_reported_version "$state" "$rig")"
    # "This worker runs no RigForge at all" and "the dashboard has no newer release for it" are
    # different absences and a reader needs to tell them apart, so they are two skips with two
    # reasons rather than one catch-all.
    #
    # There is deliberately NO vX.Y.Z shape check on $ver here. The old leg needed one because it
    # proposed the rig's OWN version and so had to be able to build a valid request from it; this
    # leg proposes the release tag the dashboard supplies, and the rig's reported string is never
    # sent anywhere. A shape check would fire only where parse_semver is more permissive than the
    # regex — a pre-release like 1.16.0-rc1 — and there it would SUPPRESS a legitimate upgrade.
    # (Found by a mutation that survived: dropping the old guard changed no outcome at all.)
    if [ -z "$ver" ]; then
        it_skip_leg "rig upgrade (#1002a/#1237)" \
            "worker '$rig' reports no RigForge version at all — a plain-xmrig worker has no one-click upgrade path to drive" \
            "by-design"
        return 0
    fi
    IFS='|' read -r avail latest <<<"$(_rig_update_verdict "$state" "$rig")"

    if [ "$avail" != "true" ] || [ -z "$latest" ]; then
        # Deliberately one skip with a two-branch reason, not a guess between them: compute_update
        # returns None for "equal", "older" AND "unparseable/no cached release" alike, and nothing
        # else in /api/state tells them apart. Classed missing because that is the pessimistic
        # bucket (skip-accounting.sh) and one of the two branches genuinely is a gap — a release
        # the dashboard never fetched is an input problem, not a structural one.
        it_skip_leg "rig upgrade (#1002a/#1237)" \
            "the dashboard offers no newer RigForge release for '$rig' (reporting $ver) — it is either already on the latest published release, or the release lookup has not succeeded over Tor; /api/state cannot tell those apart" \
            "missing"
        return 0
    fi

    _rigforge_upgrade_real_leg "$rig" "$latest"
    # Only now is "the rig is on $latest" something this run established rather than assumed, which
    # is the precondition the noop leg needs to mean anything.
    _pred_rig_version_is "$rig" "$latest" && _rigforge_upgrade_noop_leg "$rig" "$latest"
}
