# shellcheck shell=bash
#
# The Worker Inspect writable-key apply legs (#1236), and the reasoned refusals that go with them.
#
# The control phase used to prove the write path on ONE key. `max_temp_c` (#513) had a live readback
# in the enriched feed, so its round trip could be asserted; `pools` (#1002b) did not, so it was
# built on the dashboard's own `last_applied` record and gated behind an `IT_RIG_POOLS_PROBE` the
# harness sets nowhere. The other four writable keys had no leg at all. A gate that applies one of
# six keys is not a gate on "the writable path works" — it is a gate on max_temp_c.
#
# What changed: RigForge v1.10.0 (rigforge#253) serves the rig's own EFFECTIVE writable config on
# the enriched feed, and the dashboard re-exposes it at `GET /api/worker?name=<rig>` as
# `.rig_config` (#1235, views.py). So the harness can now read the original from the rig itself,
# derive a probe from it, and assert the rig's OWN reported value changed and was restored — no new
# env var, no direct rig dial, no new port, and no reliance on a record of what we last pushed.
#
# The settle reasoning is rigforge-apply-settle.sh's, unchanged: `.rig_config` rides the same
# per-rig poll tick as the enriched feed (data_service step 3b), which runs strictly AFTER the #185
# history reconcile (step 3a), so seeing the rig report the new value also means that change_id's
# history row is already terminal.
#
# Sourced by run.sh, which supplies wait_for (lib.sh), the assert_* helpers, rx/quote_arg, and
# _worker_apply. Every function here is drivable standalone against stubs — that is the tier the
# mutation proofs live at (selftest-rigforge-writable-keys.sh), not a bench.

# The Worker Inspect detail for a rig — `.rig_config`, `.history`, `.last_applied`, all of it.
_worker_detail() { # <rig> -> the /api/worker detail JSON
    rx "curl -fsS --max-time 10 $(quote_arg "http://127.0.0.1:8000/api/worker?name=$1")" 2>/dev/null
}

# Read one writable key out of the rig's own reported config, as compact JSON. Empty when the rig
# sent no usable config at all (`.rig_config` null — "could not read", NOT "empty"; views.py says so
# explicitly) or when this rig's RigForge predates rigforge#253 and never sends that key.
#
# `has()` rather than the shorter `// empty`, and the reason is narrower than it looks: jq treats
# only `false` and `null` as falsy, so the two forms agree on every value these six keys take today
# — a measured DONATION of 0 survives `//` intact. This is a guard against the shape, not a fix for
# a live bug. It earns its place because the allowlist is not closed: the first boolean writable key
# added upstream would make `// empty` read a legitimate `false` as "the rig never sent this", and
# that leg would then skip itself in silence — which is the exact failure this issue is about.
# (Spelled out because an earlier draft of this comment claimed `//` swallowed a 0. It does not; the
# self-test's mutation run is what caught the claim, and the control now covers the `false` case.)
_rig_config_key() { # <rig-detail-json> <key> -> the value as compact JSON, or empty
    printf '%s' "$1" | jq -c --arg k "$2" '
        if (.rig_config | type) == "object" and (.rig_config | has($k))
        then .rig_config[$k] else empty end' 2>/dev/null
}

# Predicate: the rig's OWN reported value for <key> is <want>. The generic form of _pred_feed_maxt.
_pred_rig_config_key() { # <rig> <key> <want-json>
    local v
    v="$(_rig_config_key "$(_worker_detail "$1")" "$2")"
    [ -n "$v" ] && [ "$v" = "$3" ]
}

# Settle a dial-time "accepted" against the rig's own reported config. The wrapper — parse, wait,
# promote to applied, leave a real rejected/failed/timeout alone so the caller's assert_eq reds — is
# _settle_worker_apply in rigforge-apply-settle.sh, shared with the max_temp_c leg; only the
# readback predicate is ours. Same '|'-joined output, and the same reason for that delimiter (an
# empty middle field must survive `IFS='|' read`), documented on that module.
_settle_worker_apply_key() { # <rig> <key> <want-json> <dial-result-json> -> "<status>|<ckeys>|<change_id>"
    _settle_worker_apply "$2" \
        "the rig to report $2=$3 applied (RigForge #344 async apply, #1309)" \
        "$4" _pred_rig_config_key "$1" "$2" "$3"
}

# One reversible round trip on one writable key: apply the probe, assert the RIG reports it, assert
# the #185 history row for THAT change_id is terminal, then restore the original and assert the rig
# reports that too. The restore runs whatever the assertions said — a mid-leg red must not strand a
# borrowed production miner on a probe value.
_writable_key_round_trip() { # <rig> <key> <orig-json> <probe-json>
    local rig="$1" key="$2" orig="$3" probe="$4" res status ckeys change_id
    it_step "Worker Inspect edit: $key $orig -> $probe via /api/control/worker-apply…"
    # On the books BEFORE the write goes out — the window #1379 covers includes the apply itself.
    rig_key_mark dash "$rig" "$key" "$orig"
    res="$(_worker_apply "$rig" "$(jq -nc --arg k "$key" --argjson v "$probe" '{($k): $v}')")"
    IFS='|' read -r status ckeys change_id <<<"$(_settle_worker_apply_key "$rig" "$key" "$probe" "$res")"
    assert_eq "$key edit applied on the rig (#1236)" "$status" "applied"
    assert_contains "the rig's own config confirms $key changed (#1236)" "$ckeys" "$key"
    # Matched by change_id, not "the newest row" — #579/#604's reconciler, as the #513 leg does.
    assert_eq "$key worker-apply recorded in the per-worker history (#185/#1236)" \
        "$(_worker_detail "$rig" | jq -r --arg c "$change_id" \
            'first(.history[]? | select(.change_id == $c)) | .status // empty' 2>/dev/null)" "applied"
    it_step "reverting $key $probe -> $orig…"
    res="$(_worker_apply "$rig" "$(jq -nc --arg k "$key" --argjson v "$orig" '{($k): $v}')")"
    IFS='|' read -r status _ _ <<<"$(_settle_worker_apply_key "$rig" "$key" "$orig" "$res")"
    assert_eq "$key edit reverted on the rig (#1236)" "$status" "applied"
    # Retired only on a CONFIRMED revert. A revert that came back anything else stays on the books
    # so the EXIT trap retries it — the assertion above has already red, and trusting it to have
    # restored the rig would be trusting the thing that just told us it did not. (#1379)
    [ "$status" = "applied" ] && rig_key_clear dash "$rig" "$key"
    return 0
}

# #1236, and the refusals. Three of the six writable keys are deliberately NOT driven here, and the
# reasons are the deliverable — a stated permanent omission is worth more than a leg that is unsafe
# on borrowed hardware or one that reads as an oversight. These use it_log, not it_warn: a warn says
# "a prerequisite was missing this run", and re-reading it as a permanent decision is the confusion
# worth avoiding. (it_warn is invisible in the summary counters anyway — #1365.)
#
#   max_temp_c            already round-tripped by the #513 leg. A duplicate proves nothing.
#   autotune              disabled -> enabled starts a REAL tuning run: it moves hashrate and
#                         thermals and may not settle inside the leg's window. Not on a loan rig.
#   watchdog              enabled -> disabled removes thermal protection from a rig mining at
#                         max_temp_c=100. Brief is still real on hardware we do not own.
#   pools                 REFUSED as a self-derived round trip, and this one is a finding, not a
#                         preference: `.rig_config.pools` is LOSSY and the loss is undetectable.
#                         RigForge's own feed deletes `pass` and `tls-fingerprint` before serving
#                         (rigforge.sh _api_config_json), and the dashboard's _strip_credentials
#                         deletes them again at any depth. `pass` is load-bearing — it is the
#                         Pithead stratum password (#113), and a rig whose `pass` no longer matches
#                         is REJECTED by the proxy at login. So writing a self-read pools value back
#                         would silently strip the credential and strand a borrowed production
#                         miner, and the harness cannot even tell "this rig has no pass" from "this
#                         rig's pass was stripped on the way to me" — both read as `{"url": …}`.
#                         The operator-supplied route below stays the only honest one for pools.
run_rigforge_writable_keys() { # <rig>
    local rig="$1" detail orig probe
    it_log "   #1236: the writable keys the control phase never applied"
    # State the refusals in the RUN OUTPUT, not only in this file. A permanent, reasoned omission is
    # a deliverable of this phase, and one that is only visible to whoever opens the source reads —
    # to the operator scanning a release-gate log — exactly like an omission nobody noticed.
    it_log "   #1236: autotune and watchdog are deliberately NOT driven (a real tuning run; and dropping thermal protection on a rig at its temperature ceiling), and pools is never derived from the rig's own read (credential-stripped, #113) — see docs/dev/integration-testing.md"
    detail="$(_worker_detail "$rig")"
    if ! printf '%s' "$detail" | jq -e '(.rig_config | type) == "object"' >/dev/null 2>&1; then
        it_warn "rig '$rig' reports no writable config (.rig_config is null — 'could not read', or a RigForge older than v1.10.0/rigforge#253) — skipping the writable-key legs (#1236)"
        return 0
    fi

    # DONATION: the issue's headline key. Move it toward zero whenever it is non-zero, so the probe
    # can only ever REDUCE what a borrowed rig donates; only a rig already at 0 is nudged to 1, which
    # is RigForge's own default. Bounds are 0-100 (rigforge.sh:406), so both directions are valid.
    orig="$(_rig_config_key "$detail" DONATION)"
    if [ -z "$orig" ]; then
        it_warn "rig '$rig' reports no DONATION in its writable config — skipping that leg (can't read the original to restore it) (#1236)"
    elif ! printf '%s' "$orig" | grep -qE '^[0-9]+$'; then
        it_fail "the rig's reported DONATION is a number (#1236)" "got [$orig]"
    else
        probe=0
        [ "$orig" -eq 0 ] && probe=1
        _writable_key_round_trip "$rig" DONATION "$orig" "$probe"
    fi

    # watchdog_interval_min: a second scalar key, and the safest change on the list — the watchdog
    # stays ON, it just polls one minute further apart for the length of the leg. Bounds are 1-1440
    # (rigforge.sh:556); step away from whichever end we are on so the probe is always in range.
    orig="$(_rig_config_key "$detail" watchdog_interval_min)"
    if [ -z "$orig" ]; then
        it_warn "rig '$rig' reports no watchdog_interval_min in its writable config — skipping that leg (can't read the original to restore it) (#1236)"
    elif ! printf '%s' "$orig" | grep -qE '^[0-9]+$' || [ "$orig" -lt 1 ] || [ "$orig" -gt 1440 ]; then
        it_fail "the rig's reported watchdog_interval_min is in RigForge's 1-1440 range (#1236)" "got [$orig]"
    else
        probe=$((orig + 1))
        [ "$orig" -ge 1440 ] && probe=$((orig - 1))
        _writable_key_round_trip "$rig" watchdog_interval_min "$orig" "$probe"
    fi
}

# #1002b: pools, the repoint-your-hashrate key. Unchanged in substance from the leg that lived in
# run.sh, and still operator-gated for the reason above: the harness cannot read a pools value it
# could safely write back. pithead treats `pools` as opaque passthrough (WORKER_WRITABLE_KEYS checks
# the key NAME, never the value shape), so a guessed value risks a real rejected/failed instead of
# proving the round trip — the same reasoning IT_RIG_ROLLBACK_CHANGES applies to the #517 leg.
# The restore target is `.last_applied.pools`: the dashboard's record of what IT pushed, which is
# un-stripped, and the same source the real editor prefills from when the rig sends no config.
run_rigforge_pools() { # <rig>
    local rig="$1" orig_pools res status ckeys
    if [ -z "${IT_RIG_POOLS_PROBE:-}" ]; then
        it_warn "no IT_RIG_POOLS_PROBE (a JSON pools value safe to apply to rig '$rig') — skipping the pools write leg (#1002b)"
        return 0
    fi
    if ! printf '%s' "${IT_RIG_POOLS_PROBE:-}" | jq -e . >/dev/null 2>&1; then
        it_fail "IT_RIG_POOLS_PROBE is valid JSON (#1002b)" "got [${IT_RIG_POOLS_PROBE:-}]"
        return 0
    fi
    orig_pools="$(_worker_detail "$rig" | jq -c '.last_applied.pools // empty' 2>/dev/null)"
    if [ -z "$orig_pools" ]; then
        it_warn "rig '$rig' has no dashboard-applied pools on record (.last_applied.pools) — skipping the pools write leg (can't read a restorable original; the rig's own .rig_config.pools is credential-stripped and must not be written back) (#1002b)"
        return 0
    fi
    it_step "Worker Inspect edit: pools -> the operator-supplied probe via /api/control/worker-apply…"
    # The restore target is last_applied, which still carries `pass` — the same un-stripped value
    # the revert below uses, and the only one safe to write back (#113). (#1379)
    rig_key_mark dash "$rig" pools "$orig_pools"
    res="$(_worker_apply "$rig" "{\"pools\":$IT_RIG_POOLS_PROBE}")"
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)"
    ckeys="$(printf '%s' "$res" | jq -r '(.changed_keys // []) | join(",")' 2>/dev/null)"
    assert_eq "pools edit applied on the rig (#1002b)" "$status" "applied"
    assert_contains "the rig's /status confirms pools changed (#1002b)" "$ckeys" "pools"
    it_step "reverting pools to the dashboard's last-applied value…"
    res="$(_worker_apply "$rig" "{\"pools\":$orig_pools}")"
    status="$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)"
    assert_eq "pools edit reverted on the rig (#1002b)" "$status" "applied"
    [ "$status" = "applied" ] && rig_key_clear dash "$rig" pools
    return 0
}
