# shellcheck shell=bash
#
# The /data-floor fallback leg (#1672 — tier 4 for #1393). Sourced by tests/os/run.sh and run at the
# end of phase_provision, on the guest the migration leg just left committed: floor = this
# checkout's VERSION, chain services up, `mig_bundle` (a data_migration bundle at that version)
# already built. Proves the COMPOSITION the tier-1 rows cannot: a real migrating bundle whose
# boot gate fails, a real A/B fallback, and the previous slot's pithead-boot putting the floor
# back from the record the raise left — then the same sequence with the record deleted, which
# must leave the floor alone and make the guard refuse with the failed-update premise.
#
# HOW THE GATE IS MADE TO FAIL. The failing bundle is stamped $FLOOR_FALLBACK_VERSION, a version no
# release of this project will carry. Two consequences, both wanted: os-update treats it as a
# clean upgrade and raises the floor to it, and its slot boots deriving STACK_VERSION from that
# stamp, so `pithead up` hunts first-party image tags that were never published and cannot come
# up — exactly the effect the leg-4 note above _prev_patch_version in run.sh warns about, used on
# purpose here. pithead-boot then leaves the slot uncommitted and reboots into the previous one.
# The leg asserts the fallback by the previous boot's journal, not by the mechanism.
#
# WHY A COPIED TREE. Every bundle is stamped with the checkout's VERSION by design (mkbundle.sh:
# "deliberately has no override"), and the battery tree is frozen while it runs. So the failing
# bundle is built from a `git archive` export of HEAD with the version written into its VERSION —
# never a `git worktree`: the battery runs as root, and a root-made commit leaves root-owned
# objects in the .git every worktree on the box shares. The export has no git, so build-image
# stamps BUILD_COMMIT `unknown-dirty` and mkbundle needs PITHEAD_STALE_TARBALL_OK=1; os-update
# reads neither — only [meta.pithead]. It is signed with THIS tree's dev key (copied in) so the
# keyring baked into the guest's slots accepts it.

FLOOR_FALLBACK_VERSION=99.0.0

# $1 marker, $2 stamped version, $3 minimum_os_version -> prints the bundle path (outside
# os/rauc/build, so _build_bundle's `find | head -1` in a later phase can never pick it up).
_build_bundle_stamped() {
    local marker="$1" version="$2" floor="$3" wt out
    wt=$(mktemp -d /tmp/pithead-floor-fallback.XXXXXX) || return 1
    out=/tmp/os-floor-fallback-$marker.raucb
    {
        git archive HEAD | tar -x -C "$wt" &&
            mkdir -p "$wt/os/rauc" && cp -a os/rauc/certs "$wt/os/rauc/" &&
            printf '%s\n' "$version" >"$wt/VERSION" &&
            (
                cd "$wt" &&
                    PITHEAD_UPDATER=rauc PITHEAD_TEST_SSH_PUBKEY="$(cat "$KEY.pub")" PITHEAD_TEST_MARKER="$marker" \
                    PITHEAD_ROOTFS_TAG="pithead-os-rootfs-$marker" os/build-image.sh &&
                    PITHEAD_STALE_TARBALL_OK=1 PITHEAD_DATA_MIGRATION=true PITHEAD_MIN_OS_VERSION="$floor" \
                        os/rauc/mkbundle.sh --dev
            ) &&
            cp "$wt/os/rauc/build/update.raucb" "$out"
    } >>/tmp/os-fault-bundle.log 2>&1
    local rc=$?
    rm -rf "$wt"
    [ "$rc" = 0 ] || return 1
    printf '%s' "$out"
}

# floor|prev|marker as the guest holds them, one string, so a mismatch shows all three at once.
_floor_state() {
    _ssh "cd /data/pithead && printf '%s|%s|%s' \"\$(cat .os-data-floor 2>/dev/null)\" \"\$(cat .os-data-floor.prev 2>/dev/null)\" \"\$(cat .os-migration-pending 2>/dev/null)\"" 2>/dev/null | tr -d ' \r\n'
}

# Reboot into the just-installed slot and wait until the guest is back on the slot carrying marker
# $1 with its boot gate PASSED (the commit line in this boot's journal). The reboot is OBSERVED
# before anything is polled (#1651): the boot that issued it still carries marker $1 and a
# committed line in its own journal, so a probe it answered while shutting down satisfied the
# predicate off the OLD boot — and `-b -1` in the caller then named the wrong boot. SSH answers
# on the failing slot too, while it loads images and tries to bring the stack up, so the marker
# is what tells the two apart. $2 = seconds: a failed `up` reboots within minutes, a gate that
# loops 90 rounds takes ~15 min, and the fallback boot then re-loads images — allow for all three.
_floor_fallback_wait() {
    local deadline=$(($(date +%s) + $2)) got
    _reboot_wait reboot "$2" || return 1
    while [ "$(date +%s)" -lt "$deadline" ]; do
        got=$(SSH_TIMEOUT=20 _ssh "cat /etc/pithead-test-marker 2>/dev/null; journalctl -u pithead-boot -b 2>/dev/null | grep -c 'booted slot committed'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
        case "$got" in "$1 "[1-9]*) return 0 ;; esac
        sleep 15
    done
    return 1
}

# Install $1 through the real os-update path; prints its output, returns its rc.
_floor_os_update() {
    _stage_bundle "$1" || return 99
    _ssh "cd /data/pithead && ./pithead os-update /data/update.bundle --yes 2>&1"
}

phase_provision_floor_fallback_leg() { # $1 = the migration leg's data_migration bundle at VERSION
    local good_bundle="$1" vfail="$FLOOR_FALLBACK_VERSION" floor0 bundle out rc state
    info "floor-fallback leg — a data_migration update that fails its gate must give the /data floor back (#1393)"
    floor0=$(_ssh "cat /data/pithead/.os-data-floor 2>/dev/null" | tr -d ' \r\n')
    if [ -z "$floor0" ]; then
        bad "no /data floor on the guest before the leg — the migration leg should have left one"
        return
    fi
    ok "floor before the failing update: $floor0"
    bundle=$(_build_bundle_stamped vfail "$vfail" "$vfail") || {
        bad "the $vfail migration bundle build failed (/tmp/os-fault-bundle.log)"
        return
    }
    ok "built a data_migration bundle stamped $vfail (floor $vfail): $(basename "$bundle")"

    # ---- positive case: record present -> the fallback boot restores the floor ----
    out=$(_floor_os_update "$bundle")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        osupdate_failure_evidence "$rc" "$out"
        bad "os-update of the $vfail bundle failed on the guest — read the evidence above"
        return
    fi
    # Issue step 2, taken BEFORE any boot: the raise armed the floor at the failed bundle's
    # minimum and left the record beside it; the marker names the bundle.
    state=$(_floor_state)
    if [ "$state" = "$vfail|$floor0|$vfail" ]; then
        ok "install raised the floor to $vfail and recorded $floor0 beside it (marker $vfail)"
    else
        bad "after the install, floor|prev|marker = '$state', want '$vfail|$floor0|$vfail'"
        return
    fi
    if _floor_fallback_wait vmig 1800; then
        ok "the $vfail slot never committed — the guest is back on the previous slot with its gate passed"
    else
        bad "the guest did not come back on the previous slot with a passed gate within 30 min (marker/journal: '$(SSH_TIMEOUT=20 _ssh "cat /etc/pithead-test-marker; journalctl -u pithead-boot -b | tail -3" 2>/dev/null | tr '\n' ' ')')"
        return
    fi
    # The mechanism, from the failed boot's own journal (-b -1: the boot between the migration
    # leg's commit boot and this one). Persistent journald is what makes it readable (#1207).
    if _ssh "journalctl -u pithead-boot -b -1 2>/dev/null | grep -q 'slot left uncommitted so A/B fallback stays armed'"; then
        ok "the $vfail boot failed its gate and left the slot uncommitted (its journal says so)"
    else
        bad "the previous boot's journal has no 'slot left uncommitted' line — either the $vfail slot committed, or the journal did not persist"
    fi
    state=$(_floor_state)
    if [ "$state" = "$floor0||" ]; then
        ok "RESTORED: the floor is back to $floor0, the record and the marker are gone"
    else
        bad "after the fallback, floor|prev|marker = '$state', want '$floor0||' (#1393)"
    fi
    if _ssh "journalctl -u pithead-boot -b | grep -q 'the /data floor is back to $floor0'"; then
        ok "the fallback boot said so on the console (journal line names $floor0)"
    else
        bad "no 'floor is back to $floor0' line in the fallback boot's journal"
    fi
    # Issue step 3's last clause: a bundle at the restored floor installs again. Before the restore
    # this same install was below a $vfail floor — the negative case below proves that refusal.
    out=$(_floor_os_update "$good_bundle")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        ok "a bundle at the restored floor ($floor0) installs again through os-update"
    else
        bad "os-update refused a bundle at the restored floor $floor0 (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    fi

    # ---- negative control: record deleted before the fallback boot -> the floor stays ----
    info "negative control — the same failed update with the record deleted must leave the floor alone"
    out=$(_floor_os_update "$bundle")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        osupdate_failure_evidence "$rc" "$out"
        bad "the second os-update of the $vfail bundle failed — read the evidence above"
        return
    fi
    state=$(_floor_state)
    if [ "$state" = "$vfail|$floor0|$vfail" ]; then
        ok "second install armed the same state (floor $vfail, record $floor0, marker $vfail)"
    else
        bad "after the second install, floor|prev|marker = '$state', want '$vfail|$floor0|$vfail'"
        return
    fi
    _ssh "rm -f /data/pithead/.os-data-floor.prev"
    if _floor_fallback_wait vmig 1800; then
        ok "the $vfail slot never committed again — back on the previous slot"
    else
        bad "the guest did not come back on the previous slot within 30 min (second fallback)"
        return
    fi
    state=$(_floor_state)
    if [ "$state" = "$vfail||" ]; then
        ok "FAIL-SAFE: with no record the floor stayed at $vfail; only the marker went"
    else
        bad "after the record-less fallback, floor|prev|marker = '$state', want '$vfail||' — a floor was lowered without a record"
    fi
    # An absence, controlled: the identical grep found this line on the positive case above.
    if _ssh "journalctl -u pithead-boot -b | grep -q 'the /data floor is back to'"; then
        bad "the record-less fallback boot claims it restored the floor"
    else
        ok "the record-less fallback boot did not claim a restore"
    fi
    # The guard's honest refusal (#1393 part 3): floor above the running version, bundle below the
    # floor — names the failed-update premise and the open route, never a reset or a restore.
    out=$(_floor_os_update "$good_bundle")
    rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "a migrating update to $vfail failed its gate and fell back before its migration ran"; then
        ok "os-update refuses a bundle below the stale floor with the failed-update premise"
    else
        bad "expected a refusal naming the failed migrating update (rc $rc): $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    fi
    if printf '%s' "$out" | grep -qi 'factory.reset\|restore a\|restoring a'; then
        bad "the refusal names a reset or a restore as the way out: $(printf '%s' "$out" | tail -1)"
    else
        ok "the refusal names no reset and no restore"
    fi
}
