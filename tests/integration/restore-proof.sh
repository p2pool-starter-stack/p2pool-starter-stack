# shellcheck shell=bash
#
# The restore proof (#971, #1085) and the image-identity check that goes with it (#272, restore side).
#
# Sourced by e2e.sh, which supplies on_bench/ok/warn/step, RESTORE_DIR, E2E_DIR and
# env_bake_verdict/control_units_verdict (lib.sh). Split out of e2e.sh rather than written there:
# the classifier below has to be drivable with no ssh and no docker, because that is the tier its
# mutation proof runs at (selftest-e2e-restore-proof.sh), and e2e.sh is at its file budget.
#
# The proof answers one question the rest of the harness cannot: after the EXIT trap has put the
# box back, is the box actually back? A restore that half-worked looks exactly as healthy as one
# that worked — that is the #971 incident, and the image check below is the same shape one layer
# further in.

# What the live stack was RUNNING, by service, before this run touched anything, and what
# deploy_branch then built. Both are image IDs, not tags: the defect they exist to catch is a tag
# that MOVED, so the tag cannot be the instrument. Empty means "not captured" — a skip, never a pass.
BASELINE_IMAGES=""
BRANCH_IMAGES=""

# The image OBJECT each running service is on. `docker ps` scopes it to the one pinned Compose
# project, so this reads the live stack whichever checkout last drove it. A re-tag does not move an
# image ID; only a rebuild or a different image does.
stack_image_census() { # -> sorted "<service>=<image-id>" lines; empty when no stack is running
    on_bench "docker ps -q --filter label=com.docker.compose.project=pithead 2>/dev/null |
        xargs -r docker inspect --format '{{index .Config.Labels \"com.docker.compose.service\"}}={{.Image}}' 2>/dev/null |
        sort" 2>/dev/null || true
}

# One service's image ID out of a census. Empty when the census does not carry that service.
census_get() { # <census> <service>
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

# Which services came back on what. Pure — three strings in, one verdict per baseline service out,
# no ssh and no docker — so the mutation proof for it runs with no bench
# (selftest-e2e-restore-proof.sh). Graded per service because a partial overlap is the realistic
# case: a branch that changes two Dockerfiles rebuilds two images, and the other services
# legitimately carry an image ID that matches the baseline AND the branch.
#   kept     the same image object it ran before the run
#   rebuilt  different from both censuses — built from RESTORE_DIR's own tree by the restore
#   stale    the image THIS RUN built for the branch, now running under the baseline's name
#   gone     ran before the run, not running now
# `stale` is graded before `rebuilt` on purpose: an image that equals the branch's is never
# evidence of a rebuild, however different it is from the baseline.
# No `[ -n "$branch" ]` guard on the stale arm, deliberately: reaching it already requires a
# non-empty $now, so an absent branch census (a --mode check run, where deploy_branch never ran)
# fails the equality on its own. The guard was there in the first draft; it could not change any
# outcome, and the mutation battery is what showed that — an unkillable mutant is a claim about the
# code, not about the test.
# It walks the BASELINE, so a service that only exists in the after-census is not graded: the
# question here is whether what was running came back, not whether something new appeared. A new
# service is a compose-file change, which the deploy phase already exercises.
grade_image_census() { # <baseline> <now> <branch> -> "<verdict> <service>" lines
    local svc now base branch
    while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        svc="${svc%%=*}"
        base="$(census_get "$1" "$svc")"
        now="$(census_get "$2" "$svc")"
        branch="$(census_get "$3" "$svc")"
        if [ -z "$now" ]; then
            printf 'gone %s\n' "$svc"
        elif [ "$now" = "$base" ]; then
            printf 'kept %s\n' "$svc"
        elif [ "$now" = "$branch" ]; then
            printf 'stale %s\n' "$svc"
        else
            printf 'rebuilt %s\n' "$svc"
        fi
    done <<<"$1"
}

# Restore proof (#971): after the restore brings the baseline back up, prove the LIVE stack
# actually runs RESTORE_DIR's on-disk config. A pre-#921 e2e run once left the containers on
# harness-rendered creds while the on-disk .env kept the real ones — internally consistent, so it
# mined and looked healthy for a day, while every host-side RPC probe 401ed. Four checks:
#   1. The credential marker baked into the running dashboard container (docker inspect) is the
#      same line as the on-disk .env's — env_bake_verdict (lib.sh) prints verdict words only,
#      never values.
#   2. monerod answers a host-side get_info with the on-disk creds — the exact probe the incident
#      broke. Only .status is required (sync may still be re-confirming); polled briefly because
#      the containers were just recreated. The probe script travels over ssh stdin (bash -s), so
#      the creds stay on the box and the remote command string carries no shell parens.
#   3. The box-global control units still name RESTORE_DIR (#1085). deploy_branch's `pithead
#      upgrade` repoints them at E2E_DIR, and the hardening phase's teardown deletes them outright
#      when it owns them — either way the live dashboard's config edits and one-click upgrades
#      queue into a spool nothing watches, while every other signal here still reads healthy.
#      The verdict comes from RESTORE_DIR's OWN doctor, run from RESTORE_DIR. That is not a
#      preference: check_control_units compares the installed units' ExecStart against $PWD, and
#      `pithead` cd's to the directory of the binary you invoke (SCRIPT_DIR, pithead:100) — so the
#      BRANCH's copy would compare against E2E_DIR and print the OK verdict on exactly the
#      stranded box this check exists to catch. It needs RESTORE_DIR on v1.19.2+, the release that
#      added the check; anything older classifies as no-check and FAILS rather than passing quietly.
#   4. The live containers are on the images the baseline ran, or on ones rebuilt from RESTORE_DIR
#      — never on the ones this run built for the branch. Spelled out at the check itself.
# Returns 0 when all four hold.
RESTORE_PROOF_VAR="MONERO_NODE_PASSWORD"
# shellcheck disable=SC2034  # CONTROL_PROOF_FAILED is declared and read by e2e.sh, which sources
# this file; it is set here because this is where the control-channel verdict is graded.
verify_restore_proof() {
    local prc=0 disk cid baked="" verdict
    disk="$(on_bench "grep -E '^${RESTORE_PROOF_VAR}=' '$RESTORE_DIR/.env' 2>/dev/null | head -n1" || true)"
    cid="$(on_bench "docker ps -q --filter label=com.docker.compose.project=pithead --filter label=com.docker.compose.service=dashboard 2>/dev/null | head -n1" || true)"
    [ -n "$cid" ] && baked="$(on_bench "docker inspect --format '{{json .Config.Env}}' '$cid' 2>/dev/null | jq -r '.[]'" || true)"
    verdict="$(env_bake_verdict "$RESTORE_PROOF_VAR" "$disk" "$baked")"
    if [ "$verdict" = "match" ]; then
        ok "restore proof: dashboard container env matches the on-disk .env ($RESTORE_PROOF_VAR)"
    else
        warn "restore proof: $RESTORE_PROOF_VAR baked into the live dashboard container vs $RESTORE_DIR/.env: $verdict"
        prc=1
    fi

    local out deadline=$(($(date +%s) + 60))
    while :; do
        out="$(
            on_bench "cd '$RESTORE_DIR' && bash -s" <<'PROBE'
u=$(grep -E '^MONERO_NODE_USERNAME=' .env 2>/dev/null | cut -d= -f2-)
p=$(grep -E '^MONERO_NODE_PASSWORD=' .env 2>/dev/null | cut -d= -f2-)
url=$(grep -E '^MONERO_RPC_URL=' .env 2>/dev/null | cut -d= -f2-)
[ -n "$url" ] || url="http://127.0.0.1:18081"
if [ -n "$u" ]; then body=$(curl -fsS --max-time 8 --digest -u "$u:$p" "$url/get_info" 2>/dev/null)
else body=$(curl -fsS --max-time 8 "$url/get_info" 2>/dev/null); fi
printf '%s' "$body" | jq -e '.status=="OK"' >/dev/null 2>&1 && echo rpc-ok || echo rpc-fail
PROBE
        )" || true
        if [ "$out" = "rpc-ok" ]; then
            ok "restore proof: host-side get_info answers with the on-disk creds"
            break
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "restore proof: host-side get_info with the on-disk creds did NOT answer within 60s — the live monerod may be running different creds than $RESTORE_DIR/.env"
            prc=1
            break
        fi
        sleep 10
    done

    # 3. The control units must still name RESTORE_DIR (#1085). Grep the verdict, never doctor's
    #    exit code — it is 1 on ANY dr_fail, so an unrelated failure elsewhere would swamp this.
    #    It runs AFTER restore_all's `apply -y`, which converges the units (v1.19.2+), so on the
    #    ordinary #1085 path the strand is already repaired: this arm proves the box was LEFT
    #    working, it does not detect the strand (CONTROL_VERDICT_BEFORE and run.sh's ExecStart
    #    assertion do). Alone it catches a pithead too old to converge (no-check), a disabled
    #    channel where apply leaves stray units, and strands this run did not cause.
    local doc verdict_line
    doc="$(on_bench "cd '$RESTORE_DIR' && ./pithead doctor 2>/dev/null" || true)"
    verdict_line="$(printf '%s\n' "$doc" | awk '/^Dashboard control channel:/{getline; print; exit}')"
    case "$(control_units_verdict "$doc")" in
    on-target)
        # The units name the right directory. That is text; `enabled` is behaviour, and
        # provision_control_runner's `systemctl enable --now` is warn-only, so apply can return 0
        # with correctly-named units that will never fire.
        if on_bench "systemctl is-enabled pithead-control.path >/dev/null 2>&1"; then
            ok "restore proof: the control runner units point at $RESTORE_DIR, and the path unit is enabled"
        else
            warn "restore proof: the control units name $RESTORE_DIR but pithead-control.path is NOT enabled — correctly addressed and never fired."
            warn "  Repair on the box: sudo systemctl enable --now pithead-control.path"
            CONTROL_PROOF_FAILED=1
        fi
        ;;
    disabled)
        # NOT a pass. `apply` leaves the units alone when control is disabled, so this is the one
        # state in which a strand SURVIVES the restore. Look for the leftovers directly.
        if on_bench "grep -qsF 'ExecStart=$E2E_DIR/pithead' /etc/systemd/system/pithead-control.service"; then
            warn "restore proof: the control channel is disabled in $RESTORE_DIR's config, and the box-global units still name the e2e checkout ($E2E_DIR). A disabled apply does not clean them up."
            warn "  Repair on the box: sudo rm -f /etc/systemd/system/pithead-control.{path,service} && sudo systemctl daemon-reload"
            CONTROL_PROOF_FAILED=1
        else
            ok "restore proof: control channel disabled in $RESTORE_DIR, and no unit names the e2e checkout"
        fi
        ;;
    not-live)
        warn "restore proof: $RESTORE_DIR is not the live install by its own reckoning — doctor declined to grade its control channel. Units NOT proven."
        warn "  doctor said: ${verdict_line:-<no verdict line>}"
        ;;
    no-check)
        warn "restore proof: $RESTORE_DIR's doctor printed no control-channel verdict — that pithead predates the check (v1.19.2), or the box has no systemd. On a pre-v1.19.2 install the restore's own apply cannot converge the units either, so assume the box IS stranded."
        warn "  Check by hand: systemctl cat pithead-control.service"
        CONTROL_PROOF_FAILED=1
        ;;
    *)
        warn "restore proof: the control runner units do NOT point at $RESTORE_DIR — the live dashboard's config changes and one-click upgrades queue into a spool nothing reads, with nothing reporting a fault."
        warn "  doctor said: ${verdict_line:-<no verdict line>}"
        CONTROL_PROOF_FAILED=1
        ;;
    esac

    # 4. WHAT CODE IS ACTUALLY RUNNING. Checks 1-3 are all green on a stack running the BRANCH's
    #    images under the baseline's name: the creds are read from the on-disk .env at runtime, so
    #    the bake matches; monerod answers with them; and the control units name RESTORE_DIR either
    #    way. Not one of them ever looked at the image. The restore comment at #454 already warned
    #    that restoring from the wrong dir "hands the pithead project locally-built :dev images" —
    #    this is the same hazard reached from the RIGHT dir, when that dir is a source checkout and
    #    therefore shares `:dev` with the branch under test.
    #    Graded per service against two censuses, because a partial overlap is the realistic case —
    #    a branch that only changes two Dockerfiles rebuilds only two images, and the other three
    #    legitimately match both sides:
    #      same as baseline          -> restored (or never rebuilt). Fine.
    #      differs, EQUALS the branch-> the branch's image is live under the baseline's name. RED.
    #      differs from both         -> rebuilt from RESTORE_DIR's own tree. Reported, not asserted:
    #                                   "not the branch's" is a weaker claim than "built from
    #                                   RESTORE_DIR". Settling that would need the image's own build
    #                                   provenance, and the dashboard's ships empty (#1449).
    local now_images verdicts line stale=0 rebuilt=0 kept=0 gone=0
    now_images="$(stack_image_census)"
    if [ -z "$BASELINE_IMAGES" ]; then
        warn "restore proof: image identity NOT CHECKED — no baseline census was taken (nothing was running at preflight)."
    elif [ -z "$now_images" ]; then
        warn "restore proof: image identity NOT CHECKED — no stack is running to census now."
        prc=1
    else
        verdicts="$(grade_image_census "$BASELINE_IMAGES" "$now_images" "$BRANCH_IMAGES")"
        while IFS= read -r line; do
            case "$line" in
            kept\ *) kept=$((kept + 1)) ;;
            rebuilt\ *) rebuilt=$((rebuilt + 1)) ;;
            stale\ *)
                warn "restore proof: '${line#stale }' is still on the image THIS RUN BUILT for the branch — the baseline was renamed, not restored."
                stale=$((stale + 1))
                ;;
            gone\ *)
                warn "restore proof: service '${line#gone }' ran before this run and is NOT running now."
                gone=$((gone + 1))
                ;;
            esac
        done <<<"$verdicts"
        if [ "$stale" -gt 0 ] || [ "$gone" -gt 0 ]; then prc=1; fi
        if [ "$stale" -gt 0 ]; then
            warn "  $stale service(s) are running the branch under test. Rebuild the baseline by hand: cd $RESTORE_DIR && ./pithead upgrade"
        elif [ "$gone" -gt 0 ]; then
            warn "  the restore did not bring the whole baseline back — check 'pithead status' in $RESTORE_DIR."
        elif [ "$rebuilt" -gt 0 ]; then
            ok "restore proof: $kept service(s) back on their pre-run images, $rebuilt rebuilt from $RESTORE_DIR (not the branch's)"
        else
            ok "restore proof: all $kept service(s) are back on the exact images they ran before this run"
        fi
    fi
    return "$prc"
}
