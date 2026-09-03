# shellcheck shell=bash
#
# The /data migration floor after a data_migration update that FAILED its gate (#1393). os-update
# raises the floor at install time, before the migration runs; the migration hold (#851) then
# keeps the chain services down until the slot commits, so a slot that fails its gate falls back
# with the data untouched — and, before this, with the floor left raised over it, every later
# os-update below that floor refused with "/data was migrated forward" as fact. Three pieces:
# the raise now records the floor it replaces (or `none`) in `.os-data-floor.prev` BEFORE
# raising; pithead-boot's fallback boot puts the floor back from that record and ONLY from a
# record (with none the floor stays — never lowered without one); and the version guard, on a
# floor above the running version, refuses with the true premise and the open route instead of
# naming a reset. The boot half is a sourceable function driven here with files in a sandbox,
# the same shape as os_update_rollback_verdict; its two call sites sit below the sourcing
# boundary and are asserted by the script's text. Sourced by tests/stack/run.sh.

echo "== unit: os_raise_data_floor records the floor it replaces BEFORE raising (#1393) =="
DF="$SANDBOX/data-floor"
rm -rf "$DF"
mkdir -p "$DF"
raise() { # <existing floor, or ABSENT> <new floor> -> "floor=<v|absent> prev=<v|absent>"
    rm -rf "$DF/floor" "$DF/floor.prev"
    [ "$1" = ABSENT ] || printf '%s\n' "$1" >"$DF/floor"
    (
        # shellcheck disable=SC1090
        source "$STACK"
        PITHEAD_DATA_FLOOR_FILE="$DF/floor" os_raise_data_floor "$2"
    ) 2>/dev/null
    printf 'floor=%s prev=%s' "$(tr -d ' \n' 2>/dev/null <"$DF/floor" || echo absent)" \
        "$(tr -d ' \n' 2>/dev/null <"$DF/floor.prev" || echo absent)"
}
assert_eq "no floor yet: the raise lands and the record says none" "$(raise ABSENT 1.17.0)" "floor=1.17.0 prev=none"
assert_eq "an earlier floor: the raise lands and the record keeps the earlier value" "$(raise 1.10.0 1.17.0)" "floor=1.17.0 prev=1.10.0"
# A bundle floor at or below the current one raises nothing — the record is still written, so the
# fallback boot of THIS install finds one (restoring it is a no-op, which is the point).
assert_eq "a no-op raise still records the floor as it stands" "$(raise 1.17.0 1.10.0)" "floor=1.17.0 prev=1.17.0"
# Written FIRST: with the floor path unwritable (a directory in its place) the record is there
# anyway, so a crash between the two writes leaves a record equal to the live floor.
mkdir -p "$DF/floor-dir"
rm -f "$DF/floor-dir.prev"
(
    # shellcheck disable=SC1090
    source "$STACK"
    PITHEAD_DATA_FLOOR_FILE="$DF/floor-dir" os_raise_data_floor 1.17.0
) 2>/dev/null
assert_eq "the record is written before the raise (floor unwritable, record present)" \
    "$(tr -d ' \n' 2>/dev/null <"$DF/floor-dir.prev" || echo absent)" "none"
unset -f raise

echo "== unit: restore_data_floor_after_fallback — the fallback boot puts the floor back from the record, and only from a record (#1393) =="
BD="$SANDBOX/data-floor-boot"
fb() { # <marker: ABSENT|version> <record: ABSENT|EMPTY|none|version> <floor: ABSENT|version>
    #    -> "floor=.. prev=.. marker=.. said=<restored|nothing>"
    rm -rf "$BD"
    mkdir -p "$BD"
    [ "$1" = ABSENT ] || printf '%s\n' "$1" >"$BD/.os-migration-pending"
    case "$2" in
    ABSENT) ;;
    EMPTY) : >"$BD/.os-data-floor.prev" ;;
    *) printf '%s\n' "$2" >"$BD/.os-data-floor.prev" ;;
    esac
    [ "$3" = ABSENT ] || printf '%s\n' "$3" >"$BD/.os-data-floor"
    local out
    out=$(
        cd "$BD" || exit
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        restore_data_floor_after_fallback
    )
    local said=nothing
    case "$out" in *"floor is back to"*) said=restored ;; esac
    printf 'floor=%s prev=%s marker=%s said=%s' \
        "$(tr -d ' \n' 2>/dev/null <"$BD/.os-data-floor" || echo absent)" \
        "$([ -f "$BD/.os-data-floor.prev" ] && echo present || echo absent)" \
        "$([ -f "$BD/.os-migration-pending" ] && echo present || echo absent)" "$said"
}
assert_eq "fallback with a record: the floor goes back to the recorded value, marker and record consumed" \
    "$(fb 1.17.0 1.10.0 1.17.0)" "floor=1.10.0 prev=absent marker=absent said=restored"
assert_eq "fallback with a 'none' record: the floor is removed (no earlier migration)" \
    "$(fb 1.17.0 none 1.17.0)" "floor=absent prev=absent marker=absent said=restored"
# The fail-safe direction, the load-bearing clause: a box whose failed install predates the
# record has none, and its floor is NOT lowered on a guess. The stale marker still goes.
assert_eq "fallback with NO record: the floor stays exactly as it is, the stale marker goes" \
    "$(fb 1.17.0 ABSENT 1.17.0)" "floor=1.17.0 prev=absent marker=absent said=nothing"
assert_eq "fallback with an EMPTY record: treated as no record — the floor stays" \
    "$(fb 1.17.0 EMPTY 1.17.0)" "floor=1.17.0 prev=present marker=absent said=nothing"
assert_eq "no marker: not a fallback boot, nothing is touched" \
    "$(fb ABSENT 1.10.0 1.17.0)" "floor=1.17.0 prev=present marker=absent said=nothing"
unset -f fb
rm -rf "$BD"

echo "== static: the restore is wired into the fallback branch, and the commit consumes the record (#1393) =="
# Both call sites sit below pithead-boot's sourcing boundary, so they are asserted by the text
# of the script rather than driven: the restore is the else-branch of the hold decision, and the
# commit-side marker removal names the record too, so a consumed record cannot outlive its
# migration. Text, not behaviour — said so here, and the battery's fallback leg is the tier above.
BOOT="$ROOT/os/overlay/pithead-boot"
hold_else=$(awk '/^if \[ -f \.os-migration-pending \]/{f=1} f&&/^fi$/{print; exit} f' "$BOOT")
assert_contains "the hold decision's else-branch calls the restore" "$hold_else" "restore_data_floor_after_fallback"
assert_contains "the else-branch is the NON-matching marker (hold_chain stays 0)" "$hold_else" "hold_chain=1
else"
assert_eq "the commit-side removal names the record beside the marker" \
    "$(grep -c '^ *rm -f \.os-migration-pending \.os-data-floor\.prev$' "$BOOT")" "1"

echo "== unit: os_update_version_guard — a floor ABOVE the running version refuses with the true premise, and the forward route is open (#1393) =="
guard() { # <running version> <floor, or ABSENT> <bundle version> -> the refusal, or empty
    rm -f "$DF/gfloor"
    [ "$2" = ABSENT ] || printf '%s\n' "$2" >"$DF/gfloor"
    (
        cd "$DF" || exit
        # shellcheck disable=SC1090
        source "$STACK"
        PITHEAD_VERSION="$1" PITHEAD_DATA_FLOOR_FILE="$DF/gfloor" os_update_version_guard "$3" 0
    ) 2>/dev/null
}
out=$(guard 1.17.0 2.0.0 1.10.0)
assert_contains "floor above running, bundle below: the refusal names the failed migrating update" "$out" "failed its gate and fell back before its migration ran"
assert_contains "...and the other reading, a slot installed outside pithead" "$out" "installed outside pithead below migrated data"
assert_contains "...and says the forward route is open" "$out" "the floor version or newer installs"
assert_contains "...and says nothing needs resetting or restoring" "$out" "Nothing needs resetting or restoring"
assert_not_contains "...never claims the data WAS migrated" "$out" "migrated forward"
assert_not_contains "...never names a factory reset" "$out" "factory reset"
assert_eq "floor above running, bundle AT the floor: installs (the forward route)" "$(guard 1.17.0 2.0.0 2.0.0)" ""
assert_eq "floor above running, bundle above the floor: installs" "$(guard 1.17.0 2.0.0 2.1.0)" ""
assert_contains "floor above running, unstamped bundle: still the true premise, fail-closed" "$(guard 1.17.0 2.0.0 "")" "failed its gate"
# Controls: the honest-floor path is unchanged. A floor at or below the running version IS what
# it claims, so the original refusal stands; and a running version the guard cannot read cannot
# judge the floor against it, so the original refusal stands there too.
assert_contains "floor at the running version, bundle below: the original migrated-forward refusal" "$(guard 1.17.0 1.17.0 1.10.0)" "migrated forward"
assert_contains "floor below the running version, bundle below the floor: the original refusal" "$(guard 2.1.0 2.0.0 1.10.0)" "migrated forward"
assert_contains "unreadable running version: the original refusal, not a judgement it cannot make" "$(guard dev 2.0.0 1.10.0)" "migrated forward"
assert_contains "a corrupt floor is still refused as unreadable, above or below" "$(guard 1.17.0 not-a-version 1.10.0)" "floor is unreadable"
unset -f guard
unset out hold_else BOOT
rm -rf "$DF"
unset DF BD
