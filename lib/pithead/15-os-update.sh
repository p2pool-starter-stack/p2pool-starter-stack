# --- OS update (appliance A/B slots) ---
# The build variant stamp: debug images bake an SSH key (often the box's only management
# channel), release images are shell-less by design. The running system carries the stamp at
# /etc/pithead-variant; an update bundle carries it in its manifest's [meta.pithead] section.
# os-update compares the two, because the failure this guards is silent and one-way: a debug
# box that installs a release bundle drops SSH — the very channel driving the install — and
# recovery needs a console.

os_running_variant() { # echoes debug|release|unknown
    local v
    v=$(tr -d ' \t\r\n' 2>/dev/null <"${PITHEAD_VARIANT_FILE:-/etc/pithead-variant}" || true)
    case "$v" in debug | release) echo "$v" ;; *) echo unknown ;; esac
}

os_bundle_meta() { # $1: bundle, $2: [meta.pithead] key — echoes its value or empty, never fails
    # `rauc info --output-format=shell` is the one machine-readable format that carries the
    # manifest's [meta.*] sections on the RAUC the appliance actually ships (1.11's JSON output
    # OMITS them entirely — the json parser here read real bundles as unstamped, found by the
    # tier-4 migration leg). Verification still runs: rauc info checks the bundle signature
    # against the system keyring before printing anything. Anything unparseable degrades to
    # empty, which every consumer treats as fail-closed "unstamped".
    #
    # `|| true` on rauc's own leg: under `set -o pipefail` a signature failure makes rauc info
    # exit nonzero, and that alone — with sed/head both still succeeding on empty input — fails
    # the whole pipe. In a bare `var=$(os_bundle_meta ...)` assignment that trips `set -e` right
    # here, before any caller sees a result, which is exactly this function's own "never fails"
    # contract broken by pipefail (#1041: the actual mechanism behind the ERR trap's contentless
    # "aborted unexpectedly" — os_update's callers below never got a chance to run at all).
    { rauc info --output-format=shell "$1" 2>/dev/null || true; } |
        sed -n "s/^RAUC_META_PITHEAD_$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')='\(.*\)'\$/\1/p" |
        head -1
}

os_bundle_variant() { # $1: bundle path — echoes debug|release|unknown, never fails
    # Unknown covers both an unstamped bundle and any garbage: the gate treats unknown as
    # shell-less, so a debug box is warned before an install that might drop SSH.
    local v
    v=$(os_bundle_meta "$1" variant)
    case "$v" in debug | release) echo "$v" ;; *) echo unknown ;; esac
}

os_semver_ok() { printf '%s' "${1:-}" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; }

os_running_version() { # the OS version this checkout/slot IS — PITHEAD_VERSION, else the VERSION file
    printf '%s' "${PITHEAD_VERSION:-$(tr -d ' \t\r\n' <VERSION 2>/dev/null || true)}"
}

# The /data-resident floor: the lowest OS version that can still read the current on-disk chain
# data. Raised when a data_migration bundle installs; read back to refuse an unsafe rollback below
# it. Overridable for tests; absent means no migration has raised a floor yet (today's reality).
os_data_floor_file() { printf '%s' "${PITHEAD_DATA_FLOOR_FILE:-/data/pithead/.os-data-floor}"; }

os_data_floor() { # echoes the floor version, or empty
    local f
    f=$(os_data_floor_file)
    [ -f "$f" ] && tr -d ' \t\r\n' <"$f" 2>/dev/null || true
}

os_raise_data_floor() { # $1: new floor — raise it, never lower (a migration only ever tightens)
    local f cur
    f=$(os_data_floor_file)
    cur=$(os_data_floor)
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    # The record a fallback boot restores from (#1393): the floor as it stands BEFORE this raise,
    # or `none`. Written first, so a crash between the two leaves a record equal to the live floor
    # (restoring it is a no-op), and written even when the raise below is a no-op, so every
    # migrating install leaves one. pithead-boot consumes it: the fallback boot puts the floor
    # back from it, the commit removes it. Nothing here ever lowers the floor — only that boot,
    # with this record, does.
    printf '%s\n' "${cur:-none}" >"$f.prev"
    if [ -z "$cur" ] || { os_semver_ok "$cur" && semver_newer "$1" "$cur"; }; then
        printf '%s\n' "$1" >"$f"
    fi
}

# The migration-pending marker (#851): written by os-update when a data_migration bundle installs,
# holding the version that bundle carries. On the next boot, pithead-boot and doctor read it back:
# a marker matching the RUNNING version means "this boot must not start the chain services until
# the slot commits" — the lmdb migration only runs once A/B fallback can no longer need the
# pre-migration data. A marker that does NOT match the running version is a fallback boot (the
# migrating slot failed health and the old OS is back); the old data was never touched, so it is
# ignored. pithead-boot removes the marker once the migrating slot commits.
os_migration_marker_file() { printf '%s' "${PITHEAD_MIGRATION_MARKER_FILE:-/data/pithead/.os-migration-pending}"; }

os_migration_hold_active() { # rc 0 when this boot is the held, pre-commit boot of a migrating bundle
    local f v
    f=$(os_migration_marker_file)
    [ -f "$f" ] || return 1
    v=$(tr -d ' \t\r\n' <"$f" 2>/dev/null)
    [ -n "$v" ] && [ "$v" = "$(os_running_version)" ]
}

# The version floor + downgrade refusals, shared verbatim by the `os-update` CLI and the
# dashboard's os-verify/os-install control verbs so the two doors can never drift apart. Echoes
# the refusal reason (empty = pass). A correctly-signed bundle is not automatically a safe one:
# an OLDER image re-introduces the holes the newer one fixed under our own signature, and an
# image below the /data migration floor cannot read the chain data a newer release migrated.
# Both guards fail CLOSED: a version the comparator cannot parse (a pre-release/-prep suffix,
# garbage, or an absent stamp) is not proof of safety, so it refuses rather than skips.
# semver_newer only understands clean X.Y.Z, so os_semver_ok gates every comparison.
os_update_version_guard() { # $1: bundle version, $2: allow_downgrade 0|1 — echoes refusal or nothing
    local bundle_version="$1" allow_downgrade="${2:-0}" running_version floor_file floor
    running_version=$(os_running_version)

    # The data floor is not a policy knob — installing below it strands the migrated chain data,
    # so it refuses with no override. A floor FILE that exists is authoritative: a corrupt or
    # unparseable floor, or a bundle we cannot prove is at or above it, refuses. The escape is a
    # factory reset or restoring a matching backup.
    floor_file=$(os_data_floor_file)
    if [ -f "$floor_file" ]; then
        floor=$(os_data_floor)
        if ! os_semver_ok "$floor"; then
            printf '%s' "Refusing: the /data migration floor is unreadable ('${floor:-empty}'). A corrupt floor is not permission to install over migrated chain data — restore it, or recover with a factory reset (loses the chain) or a matching backup."
            return 0
        fi
        # A floor ABOVE the running version cannot be what it claims (#1393): a slot that could not
        # read /data would not be running. Either a migrating update failed its gate and fell back
        # before its migration ran, with the floor never put back (the data is untouched), or this
        # slot was installed outside pithead below migrated data. The guard lowers nothing — only
        # pithead-boot does, with a record — so it refuses with the true premise and the open
        # route, and never names a reset or a restore as the way out of this state.
        if os_semver_ok "$running_version" && semver_newer "$floor" "$running_version" &&
            { ! os_semver_ok "$bundle_version" || semver_newer "$floor" "$bundle_version"; }; then
            printf '%s' "Refusing: the /data floor says OS >= $floor is needed to read the chain data, yet this slot runs $running_version — either a migrating update to $floor failed its gate and fell back before its migration ran (the chain data is untouched, and the floor was never put back), or this slot was installed outside pithead below migrated data. This bundle is '${bundle_version:-unstamped}'; the floor version or newer installs. Nothing needs resetting or restoring for this."
            return 0
        fi
        if ! os_semver_ok "$bundle_version" || semver_newer "$floor" "$bundle_version"; then
            printf '%s' "Refusing: /data was migrated forward and now needs OS >= $floor to read; this bundle is '${bundle_version:-unstamped}'. Installing it would strand the chain data. Recover with a factory reset (loses the chain) or by restoring a backup taken on $floor or newer."
            return 0
        fi
    fi

    # Downgrade guard: install without --allow-downgrade ONLY when the bundle is a clean release
    # semver provably newer than or equal to the running one. An older, pre-release, or unstamped
    # bundle re-opens fixed holes under a valid signature — it needs the explicit flag. Skipped
    # only when we cannot read our OWN version (a source checkout; os-update is appliance-only in
    # practice, where the running version is always the baked release stamp).
    if os_semver_ok "$running_version" &&
        { ! os_semver_ok "$bundle_version" || semver_newer "$running_version" "$bundle_version"; }; then
        if [ "$allow_downgrade" -eq 0 ]; then
            printf '%s' "Refusing a possible downgrade: bundle version '${bundle_version:-unstamped}', running $running_version. Only a clean X.Y.Z release at or newer than the running one installs without confirmation. Pass --allow-downgrade to install an older, pre-release, or unstamped bundle on purpose."
            return 0
        fi
    fi
    return 0
}

os_update_needs_confirmation() { # $1: running variant, $2: bundle variant — rc 0 = confirm first
    # Consent is needed whenever an install flips the box's shell/SSH posture, in EITHER direction,
    # or when the bundle's posture can't be verified. A debug image bakes a standing root
    # authorized_keys + sshd; a release image is shell-less by design.
    #   - GAIN a shell (#854): a debug bundle onto a box that isn't already debug enables root SSH.
    #     "About to gain a management channel" needs consent as much as losing one — more so.
    #   - LOSE the shell (#819): a release/unstamped bundle onto a debug box removes the channel
    #     that is probably driving this very update; recovery then needs a console on the box.
    #   - UNVERIFIED: an unstamped bundle degrades to "unknown" and could silently BE a debug build
    #     (unparseable stamp), so never wave one through unprompted.
    local running="$1" bundle="$2"
    [ "$bundle" = "debug" ] && [ "$running" != "debug" ] && return 0 # gaining a shell
    [ "$running" = "debug" ] && [ "$bundle" != "debug" ] && return 0 # losing the shell
    [ "$bundle" = "unknown" ] && return 0                            # unverified bundle
    return 1
}

os_update() {
    local bundle="" assume_yes=0 allow_downgrade=0 arg
    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=1 ;;
        --allow-downgrade) allow_downgrade=1 ;;
        -*) error "Unknown option for os-update: $arg. Run '$0 help'." ;;
        *)
            [ -z "$bundle" ] || error "os-update takes exactly one bundle path. Run '$0 help'."
            bundle="$arg"
            ;;
        esac
    done
    [ -n "$bundle" ] || error "os-update needs the path to an update bundle (.raucb). Run '$0 help'."
    command -v rauc >/dev/null 2>&1 ||
        error "rauc is not available here — OS updates apply to the appliance image, not a checkout install."
    [ -f "$bundle" ] || error "No such bundle: $bundle"

    # Verify the bundle explicitly, before anything reads its metadata (#1041). `rauc info`
    # checks the signature against the system keyring before it prints anything, so a bad
    # signature fails right here with RAUC's own precise diagnosis on stderr (e.g. "signature
    # verification failed: Verify error: self-signed certificate" — a bundle signed by a chain
    # this machine doesn't trust). Captured explicitly rather than left to whatever later reads
    # the bundle: the dashboard's os-verify/os-install doors already run this same check
    # (os_verify_bundle_reason) before this CLI path ever runs, but the CLI's own os-update had
    # nothing playing that role, so its ERR trap fired with no diagnosis to show for it.
    local rauc_info_err rauc_rc=0
    rauc_info_err=$(rauc info "$bundle" 2>&1 >/dev/null) || rauc_rc=$?
    if [ "$rauc_rc" -ne 0 ]; then
        error "rauc could not verify this bundle.${rauc_info_err:+ rauc said: $(printf '%s' "$rauc_info_err" | tail -1 | tr -d '[:cntrl:]' | head -c 300)}"
    fi

    # Version floor + data-migration guards — the exact refusals the dashboard's os-verify/
    # os-install verbs run (os_update_version_guard, shared so the two doors never drift).
    local bundle_version bundle_min bundle_migrates running_version guard_reason
    bundle_version=$(os_bundle_meta "$bundle" version)
    bundle_min=$(os_bundle_meta "$bundle" minimum_os_version)
    bundle_migrates=$(os_bundle_meta "$bundle" data_migration)
    running_version=$(os_running_version)
    guard_reason=$(os_update_version_guard "$bundle_version" "$allow_downgrade")
    [ -z "$guard_reason" ] || error "$guard_reason"
    if [ "$allow_downgrade" -eq 1 ] && os_semver_ok "$running_version" &&
        { ! os_semver_ok "$bundle_version" || semver_newer "$running_version" "$bundle_version"; }; then
        warn "Installing a bundle that is not a verified upgrade (version '${bundle_version:-unstamped}', running $running_version) — downgrade explicitly allowed."
    fi

    local running target
    running=$(os_running_variant)
    target=$(os_bundle_variant "$bundle")
    if os_update_needs_confirmation "$running" "$target"; then
        if [ "$target" = "debug" ]; then
            # Gaining a shell — only reached when the running variant is not already debug (#854).
            warn "This bundle is a DEBUG build: it bakes in a standing root SSH key and enables sshd."
            warn "Installing it turns this shell-less box into one with a permanent root SSH backdoor."
        elif [ "$running" = "debug" ]; then
            # Losing the shell (#819): a release/unstamped bundle onto a debug box.
            warn "This system is a debug build: SSH is baked in, and it is probably the channel driving this update."
            if [ "$target" = "release" ]; then
                warn "The bundle is a release build — shell-less by design. Installing it removes SSH; recovery then needs a console on the box."
            else
                warn "The bundle carries no variant stamp — treat it as a shell-less release build. Installing it can remove SSH; recovery then needs a console on the box."
            fi
        else
            # Unverified bundle onto a non-debug box: an unparseable stamp could hide a debug build.
            warn "The bundle carries no variant stamp — its shell/SSH posture can't be verified, and it may enable root SSH. Recovery may need a console on the box."
        fi
        if [ "$assume_yes" -eq 0 ]; then
            read -r -p "Install it anyway? (y/N): " CONFIRM || true
            if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                log "OS update cancelled."
                return 1
            fi
        fi
    fi
    # Serialise the mutating half against every other pithead operation (#1482). Taken HERE and
    # deliberately not at the top of the function: everything above is read-only checking, and the
    # variant confirmation just above blocks on the operator's keystroke — holding the lock across
    # that would park every other verb for as long as nobody answers. That is the same reason
    # firstboot_wizard is not wrapped (#1391), applied one caller over. A timeout exits
    # PITHEAD_EX_LOCK_TIMEOUT, which the CLI reports itself and the dashboard's os-install runner
    # routes to a "rejected" rather than a failed install.
    mutation_lock_acquire os-update
    log "Installing OS update bundle: $bundle (running: $running, bundle: $target)"
    # Tee'd like the wizard's fatal path (#1028's idiom): a bare `rauc install` let RAUC's own
    # diagnosis (a signature mismatch, an incompatible bundle) vanish, leaving only the ERR
    # trap's generic "aborted unexpectedly" — undiagnosable on a shell-less box where the
    # console is the only output there is. The tee keeps rauc's progress on this process's own
    # stdout (the dashboard's install poller reads the percentage off that same stream) while a
    # copy lands in a scratch file this function can inspect on failure. No bundle path in the
    # error text on purpose — that is a host staging detail, and the dashboard door whitelists
    # this exact line straight into the container-visible result.
    local rauc_log
    rauc_log=$(mktemp)
    if rauc install "$bundle" 2>&1 | tee "$rauc_log"; then
        rm -f "$rauc_log"
    else
        local rauc_detail
        rauc_detail=$(grep -aE '^LastError: |^\[ERROR\] |[Ff]ailed' "$rauc_log" 2>/dev/null |
            tail -1 | tr -d '[:cntrl:]' | head -c 300) || rauc_detail=""
        rm -f "$rauc_log"
        error "rauc install failed.${rauc_detail:+ rauc said: $rauc_detail}"
    fi

    # A data_migration bundle raises the /data floor so a later rollback below it is refused. Armed
    # at install (conservative: before the migration actually runs on the new slot's next boot) —
    # the safe direction, and the only floor pithead can guarantee without executing the migration
    # itself. The marker beside it is the other half of the deadlock rule (#851): the next boot
    # reads it and withholds the chain services until the slot commits, so automatic A/B fallback
    # always lands on pre-migration data. A NON-migrating install clears any stale marker — it
    # supersedes a migrating install that never booted, and its own boot must not hold anything.
    local marker
    marker=$(os_migration_marker_file)
    if [ "$bundle_migrates" = "true" ] && os_semver_ok "$bundle_min"; then
        os_raise_data_floor "$bundle_min"
        log "Recorded /data migration floor: OS >= $bundle_min required to read chain data after this update commits."
        mkdir -p "$(dirname "$marker")" 2>/dev/null || true
        printf '%s\n' "$bundle_version" >"$marker"
        log "Marked a data migration pending: the next boot starts the chain services only after the new slot commits."
    else
        rm -f "$marker"
    fi
    mutation_lock_release
}
