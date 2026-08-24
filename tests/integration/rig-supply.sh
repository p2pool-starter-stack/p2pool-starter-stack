#!/usr/bin/env bash
#
# rig-supply.sh — resolve what the dashboard-to-rig WRITE phase needs, and PROVE it before saying so.
#
# Sourced by e2e.sh. run.sh's --rigforge-control phase reads two inputs that e2e.sh never supplied,
# and neither string appeared anywhere in that file (#1378). Unsupplied, the phase does not fail — it
# drops legs quietly, which is the shape this harness exists to stop:
#
#   * The whole phase self-skips unless the bench's baseline config already happens to pin a
#     workers.list[] descriptor for the rig (run.sh:2135-2139), taking #513/#514/#516/#517/#1002b/
#     #1236 with it. Whether that fires depends on bench state the harness does not control.
#   * #516's enriched-feed reflection leg — the one that dials the rig directly to prove the
#     rig-to-dashboard direction — can NEVER run (run.sh:2294-2296). The prefill half still prints,
#     so the section reads as covered.
#   * #517 loses the rig-poll settle fallback (run.sh:2373), so a CORRECT auto-rollback on a slow rig
#     asserts red. That makes the gap a flake source as well as a coverage hole.
#
# Both inputs default from what a borrow already holds, so the MANDATED pre-cut run (--mode targeted,
# docs/dev/releasing.md) is supplied without the operator handling a secret by hand. A fix that needed
# an env var set by hand would leave the mandated run self-skipping exactly as before.
#
#   RIG_HOST      defaults to MINER_HOST. On this bench that is a LAN name the bench resolves itself,
#                 not an ssh-config alias private to the driving machine. Passing the NAME rather than
#                 a resolved address also keeps a literal address out of argv and the log, and avoids
#                 the bracket quoting a raw IPv6 literal would need in the URL.
#   IT_RIG_TOKEN  read over the SSH the borrow already holds. /opt/rigforge/config.json is mode 600
#                 owned by the SSH user, so no sudo is involved.
#
# Neither default is TRUSTED. rig_supply dials the rig's control API from the BENCH — the box whose
# legs will dial it — and reports which case it took, because "the harness does not report which case
# it took" is half of what #1378 is about.
#
# On the token: run.sh already runs `curl -H "Authorization: Bearer $IT_RIG_TOKEN"` through rx(), which
# under --local is a plain bash -c on the bench, so a short-lived bench-side argv is a hygiene level
# this harness already accepts. What must NOT happen is the token landing in the argv of the detached
# nohup'd runner, which lives for the whole run and is world-readable in /proc/PID/cmdline. So the
# token travels on on_bench's STDIN and reaches the runner as an ENVIRONMENT entry (/proc/PID/environ
# is owner-only). It never touches the bench's disk, the SSH command string, or any log.

RIGFORGE_CONFIG="${RIGFORGE_CONFIG:-/opt/rigforge/config.json}"
# Mirrors run.sh:50. Always passed through as --rig-control-port below rather than left to match by
# luck, so an override here cannot silently dial a different port than the phase's legs do.
RIG_CONTROL_PORT="${RIG_CONTROL_PORT:-8082}"
RIG_HOST="${RIG_HOST:-}"
IT_RIG_TOKEN="${IT_RIG_TOKEN:-}"

# Resolve + prove the write phase's two inputs. ALWAYS returns 0, deliberately: the caller chains this
# with && before appending the phase flags, and an under-supplied phase must still run — its
# dashboard-side legs are real coverage, and turning a known gap into a failed release gate would be a
# worse instrument than the one we are fixing. The warnings below are the honest report.
rig_supply() {
    RIG_HOST="${RIG_HOST:-$MINER_HOST}"
    if [ -z "$IT_RIG_TOKEN" ]; then
        IT_RIG_TOKEN="$(on_miner "jq -r '.ACCESS_TOKEN // empty' $(quote_arg "$RIGFORGE_CONFIG")" 2>/dev/null)" || IT_RIG_TOKEN=""
    fi
    if [ -z "$RIG_HOST" ]; then
        warn "write phase UNDER-SUPPLIED (#1378): no rig host — set MINER_HOST or RIG_HOST."
        return 0
    fi
    if [ -z "$IT_RIG_TOKEN" ]; then
        warn "write phase UNDER-SUPPLIED (#1378): no token in $RIGFORGE_CONFIG on $MINER_HOST, and IT_RIG_TOKEN is unset."
        warn "  The phase then runs only if the bench baseline already pins a descriptor for this rig, and #516's feed leg cannot run at all."
        return 0
    fi
    # Dial from the BENCH, not from here: the bench is the box run.sh's legs dial, and it is the one
    # whose reachability the phase depends on. Token on stdin, read into the remote shell's memory.
    if printf '%s' "$IT_RIG_TOKEN" | on_bench "IFS= read -r t; curl -fsS -o /dev/null --max-time 10 -H \"Authorization: Bearer \$t\" $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/status")"; then
        ok "write phase supplied: $BENCH_HOST reached the rig control API at $RIG_HOST:$RIG_CONTROL_PORT"
    else
        warn "write phase supplied but UNPROVEN (#1378): $BENCH_HOST could not reach http://$RIG_HOST:$RIG_CONTROL_PORT/status with the token."
        warn "  Passing them anyway — run.sh's legs report their own skips. Check the rig's api_allow_from, its control port, and that RigForge is up."
    fi
    return 0
}
