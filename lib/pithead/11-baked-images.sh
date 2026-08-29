# Baked container-image archives (/opt/pithead/images) are DERIVED, like every rendered file:
# they ship in the read-only slot, the engine's storage lives on /data — which survives
# reinstalls and A/B updates by design — and every release tags its images identically
# (pithead-dashboard:vX.Y.Z). Keying on "does the tag exist" therefore pins a machine to the
# first image it ever loaded: a keep-reinstall or an A/B update boots the new slot and keeps
# serving the old containers (#798, and a bench box served a weeks-old setup page for the same
# reason). The archive's digest is the honest key: load on change, record the digest beside
# the storage it describes, and let 'up' recreate containers on the image-id change. Both boot
# owners run this — pithead-boot on provisioned machines, the first-boot wizard before it
# serves — so every path converges on the shipped images, and a normal boot pays one sha256
# per archive.
# An unclean reset — a power cut, or the hardware watchdog firing while slow media is mid-write —
# can leave containers/storage with ZERO-LENGTH `lower` files. containers/storage splits an
# empty-but-present `lower` on ":" into one EMPTY element, joins that onto the graph root and
# readlinks THAT directory, so every container start dies with
# "readlink <graphroot>/overlay: invalid argument". The digest records in load_baked_images then
# report the images as already loaded, so nothing ever reloads: the damage survives every later
# boot, the wizard never serves, and the console sits on "preparing the setup page" forever. That
# is how an appliance ended up unable to install from its own stick — the store was broken by the
# reset, not by anything the wizard did. A correct BASE layer carries no `lower` file at all, so a
# zero-length one is damage, never a legitimate state.
#
# ponytail: rebuilds the WHOLE store, so a machine past provisioning re-pulls whatever is not
# baked (only the dashboard is). Fine as a floor — a store in this state starts no container at
# all, so re-pulling beats staying dead. Narrow it to the baked set if that ever bites.
repair_broken_image_store() { # $1: container engine
    local engine="$1" root
    root=$("$engine" info --format '{{.Store.GraphRoot}}' 2>/dev/null) || return 0
    { [ -n "$root" ] && [ -d "$root/overlay" ]; } || return 0
    find "$root/overlay" -maxdepth 2 -name lower -size 0 -print -quit 2>/dev/null | grep -q . || return 0
    warn "The container image store is damaged (an interrupted write left empty layer metadata) — rebuilding it."
    "$engine" rm -af >/dev/null 2>&1 || true
    rm -rf "${root:?}"
    rm -f "$PWD/data"/.loaded-*.sha
}

load_baked_images() { # $1 (optional): image ref whose absence forces a load despite a matching digest
    local required="${1:-}" dir="${PITHEAD_IMAGES_DIR:-/opt/pithead/images}"
    local engine archive sha rec recorded load_pid t0 load_rc
    engine=$(container_engine)
    # Before trusting any digest record: a record describes what was LOADED, and the check below
    # only asks whether the image still EXISTS. A store damaged as described above satisfies both
    # and still cannot run a thing, which is exactly how the failure became permanent.
    repair_broken_image_store "$engine"
    # The wizard-era record lived at a different path; retire it so an upgraded machine doesn't
    # carry a stale file forever (its absence costs one reload on the first boot after upgrading).
    rm -f "$PWD/.wizard-image-sha"
    for archive in "$dir"/*.tar.gz "$dir"/*.tar; do
        [ -f "$archive" ] || continue
        sha=$(sha256sum "$archive" 2>/dev/null | cut -d' ' -f1)
        rec="$PWD/data/.loaded-$(basename "$archive").sha"
        # `|| true`: a missing record is the normal first-boot case, not an error to trap.
        recorded=$(cat "$rec" 2>/dev/null || true)
        if [ -n "$sha" ] && [ "$sha" = "$recorded" ]; then
            # A digest record can outlive the storage it describes: when the caller names the
            # image it needs, the record only counts if that image actually exists.
            if [ -z "$required" ] || "$engine" image exists "$required" 2>/dev/null; then
                continue
            fi
        fi
        # The single slowest step of a first or post-update boot, and the one worth narrating.
        _console "Loading this build's container images ($(basename "$archive")) — the slow part..."
        mkdir -p "$PWD/data" 2>/dev/null || true
        # `podman load` prints nothing a console ever sees, and on USB media this step runs for
        # MINUTES — measured at 3m47s on the bench, behind a line promising "a minute or two".
        # A box that is working then looks exactly like a box that has hung, and it was read as
        # hung twice. A rising elapsed count is the whole fix: it is the one thing that tells
        # slow apart from stuck. 30s, so a four-minute load costs eight lines, not sixteen.
        #
        # The HEARTBEAT is what gets backgrounded, never the load: keeping the load in the
        # foreground preserves its exit status exactly, and sidesteps the zombie race that
        # polling a background pid with `kill -0` would introduce (a reaped-but-not-yet-waited
        # child still answers, so a FAST load would pay a full sleep for nothing).
        t0=$(date +%s)
        (
            while :; do
                sleep "${PITHEAD_LOAD_HEARTBEAT_SECS:-30}"
                _console "  still loading — $(($(date +%s) - t0))s elapsed, this is normal on USB media"
            done
        ) &
        load_pid=$!
        load_rc=0
        "$engine" load -i "$archive" >/dev/null 2>&1 || load_rc=$?
        # Stopped on BOTH paths, and before the branch, so no arm can leak a heartbeat that
        # narrates a load which already finished.
        kill "$load_pid" 2>/dev/null || true
        wait "$load_pid" 2>/dev/null || true
        if [ "$load_rc" -eq 0 ]; then
            printf '%s' "$sha" >"$rec" 2>/dev/null || true # unrecorded -> reloads next boot
            # #1030: the bracket the heartbeat above was missing. A journal that only ever shows
            # "Loading..." with no matching finish line, right up to the moment a boot resets, IS
            # the record that this archive is what a mid-load interrupt hit — but only if the
            # journal itself survives to be read (pithead-journal-persist.service).
            _console "Finished loading $(basename "$archive") in $(($(date +%s) - t0))s."
        else
            # No record on failure, on purpose: the next boot must retry, not skip.
            warn "Could not load the baked image archive $(basename "$archive")."
        fi
    done
    return 0
}
