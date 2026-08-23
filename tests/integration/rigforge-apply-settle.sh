# shellcheck shell=bash
#
# Settle a dashboard-mediated RigForge worker-apply intent past its dial-time "accepted" (#1309).
#
# RigForge #344: the rig now answers "accepted" immediately and applies async. pithead's own host
# runner (control_worker_apply in the `pithead` CLI) caps its post-dial /status poll at 20s and,
# past that, writes an "accepted … outcome not yet observed" result verbatim — its own words: "the
# container can keep polling the rig via the next read." That next read is the dashboard's regular
# per-rig poll (data_service.py's run loop), which on the SAME poll tick both:
#   (a) refreshes the enriched feed's live watchdog value (served at /api/state, read by
#       _pred_feed_maxt in run.sh), and
#   (b) reconciles a still-"accepted" #185 worker-config history row to its real terminal status
#       (storage_service.py:reconcile_worker_config_status, #579/#604) — step 3a in that poll,
#       strictly BEFORE the enriched-feed merge at step 3b.
# So observing the feed converge to the requested max_temp_c is proof the requested key (the only
# key in a max_temp_c change) is what changed, and the #185 history row for that change_id is
# already reconciled to "applied" by the time run.sh reads it back — no direct rig dial needed
# (IT_RIG_TOKEN/RIG_HOST bench flags aren't always set: the live-box case uses the baseline's own
# workers.list[] descriptor without them), and no reliance on the dial-time result ever changing.
# Fails loudly (leaves status/ckeys at their dial-time "accepted"/empty) on a real
# rejected/failed/timeout, exactly like a "the change never actually happened" bug would.
#
# Sourced by run.sh, which supplies wait_for (lib.sh) and _pred_feed_maxt (run.sh). Fields are
# '|'-joined, not tab — `read` with IFS=tab (an IFS-whitespace character) SQUASHES an empty
# middle field instead of preserving it, misaligning every field after it; '|' can't appear in
# any of the three values, so it splits correctly even when ckeys/change_id come back empty.
_settle_worker_apply_maxt() { # <rig> <want-max_temp_c> <dial-result-json> -> "<status>|<ckeys>|<change_id>"
    local rig="$1" want="$2" res="$3" status ckeys change_id
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)"
    ckeys="$(printf '%s' "$res" | jq -r '(.changed_keys // []) | join(",")' 2>/dev/null)"
    change_id="$(printf '%s' "$res" | jq -r '.change_id // empty' 2>/dev/null)"
    if [ "$status" = "accepted" ] &&
        wait_for 90 5 "the rig to report max_temp_c=$want applied (RigForge #344 async apply, #1309)" \
            _pred_feed_maxt "$rig" "$want"; then
        status="applied"
        ckeys="max_temp_c"
    fi
    printf '%s|%s|%s' "$status" "$ckeys" "$change_id"
}
