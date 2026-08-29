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
#                 owned by the SSH user UNTIL the rig takes its first control-apply — RigForge's
#                 control service runs as root and rewrites that file, and it is root-owned from
#                 then on (#1466). This comment used to say "so no sudo is involved", which was true
#                 of a rig that had never been written to and false forever after on one that had.
#                 So: unprivileged read first, `sudo -n` only as the fallback when that read FAILED,
#                 and the read's own error is no longer swallowed. The swallowing is what made this
#                 expensive — a permission-denied read and a file with no token in it both arrived
#                 as an empty string, run.sh dropped the whole write phase, and the gate printed
#                 `✓ E2E PASSED`. The two cases now report as two different sentences.
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

# BORROWED FROM THE SOURCER, declared rather than left to be discovered: `ok`, `warn`, `on_miner` and
# `on_bench` are defined in e2e.sh (:73/:74/:171/:172), which sources this file at :38 — BEFORE any of
# them exists. That is correct only because rig_supply is called from run_harness, long after. Sourcing
# this file alone and calling rig_supply gets `warn: command not found` and rc 0 — it reports nothing,
# because the warnings ARE the report. `quote_arg` is the one helper that comes from lib.sh.
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
    local read_cmd unpriv_rc=0 sudo_rc=0
    RIG_HOST="${RIG_HOST:-$MINER_HOST}"
    if [ -z "$IT_RIG_TOKEN" ]; then
        read_cmd="jq -r '.ACCESS_TOKEN // empty' $(quote_arg "$RIGFORGE_CONFIG")"
        # No `2>/dev/null` here, deliberately: the read's own error IS the diagnostic (#1466), and
        # hiding it is what let a denied read pass for a file with no token in it. Nothing in either
        # substitution may print to stdout — stdout IS the token.
        IT_RIG_TOKEN="$(on_miner "$read_cmd")" || unpriv_rc=$?
        # Escalate only when that read FAILED. A rig that is simply tokenless answers with an empty
        # string and rc 0, and re-asking under sudo would add a "a password is required" error to a
        # case that has nothing wrong with its permissions.
        #
        # The `|| IT_RIG_TOKEN=""` the line above used to carry survives HERE and only here. A failed
        # read yields no token whatever it managed to print first — ssh can drop after the rig has
        # written part of its answer, and half a token is worse than none: it dials, 401s, and the
        # operator is told the phase was supplied. On the first read that guard would be dead, because
        # this assignment overwrites a partial answer anyway; on the LAST read nothing does.
        if [ "$unpriv_rc" != 0 ]; then
            IT_RIG_TOKEN="$(on_miner "sudo -n $read_cmd")" || {
                sudo_rc=$?
                IT_RIG_TOKEN=""
            }
        fi
    fi
    if [ -z "$RIG_HOST" ]; then
        warn "write phase UNDER-SUPPLIED (#1378): no rig host — set MINER_HOST or RIG_HOST."
        return 0
    fi
    if [ -z "$IT_RIG_TOKEN" ]; then
        if [ "$unpriv_rc" != 0 ]; then
            warn "write phase UNDER-SUPPLIED (#1466): could NOT READ $RIGFORGE_CONFIG on $MINER_HOST (read rc=$unpriv_rc, sudo -n rc=$sudo_rc). The read's own error is above."
            warn "  That is NOT the same as the file having no token. A rig that has taken a control-apply leaves that file root-owned; set IT_RIG_TOKEN, or allow the SSH user passwordless sudo for the read."
        else
            warn "write phase UNDER-SUPPLIED (#1378): no token in $RIGFORGE_CONFIG on $MINER_HOST, and IT_RIG_TOKEN is unset."
        fi
        warn "  The phase then runs only if the bench baseline already pins a descriptor for this rig, and #516's feed leg cannot run at all."
        return 0
    fi
    # Dial from the BENCH, not from here: the bench is the box run.sh's legs dial, and it is the one
    # whose reachability the phase depends on. The token travels on stdin and stays there — `curl -K -`
    # reads its config from stdin, so the bearer never enters curl's argv, which is world-readable at
    # mode 444 in /proc/<curl>/cmdline for the life of the dial. run.sh's own rx() curl does put a token
    # in a bench-side argv, and that is a level this harness already accepts — but "we already have this
    # exposure" is an argument against blocking on it, not for adding another instance in new code.
    if printf 'header = "Authorization: Bearer %s"\n' "$IT_RIG_TOKEN" |
        on_bench "curl -fsS -o /dev/null --max-time 10 -K - $(quote_arg "http://$RIG_HOST:$RIG_CONTROL_PORT/status")"; then
        ok "write phase supplied: $BENCH_HOST reached the rig control API at $RIG_HOST:$RIG_CONTROL_PORT"
    else
        warn "write phase supplied but UNPROVEN (#1378): $BENCH_HOST could not reach http://$RIG_HOST:$RIG_CONTROL_PORT/status with the token."
        warn "  Passing them anyway — run.sh's legs report their own skips. Check the rig's api_allow_from, its control port, and that RigForge is up."
    fi
    return 0
}
