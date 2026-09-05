#!/usr/bin/env bash
#
# Tier-1 proof for #1030: a first boot interrupted mid-image-load must leave a record that
# survives the reset, not silence. Two pieces, proven separately (the KVM battery is where a
# real hard reset and a real read-only root would prove the whole chain end to end — see
# tests/os/hugepages-boot-verdict.sh for the sibling shape of that split):
#
#   1. os/overlay/pithead-journal-persist: the /data-backed bind mount that gives journald's
#      already-declared Storage=persistent somewhere real to write, so the journal is still
#      there to read after a reset (tests/os/verify-image.sh separately asserts the unit and
#      its ordering are baked into a built image — this proves the SCRIPT's own logic).
#   2. load_baked_images' new "Finished loading ... in Ns" line: the bracket the existing
#      heartbeat (#1028) was missing — a journal with a start line and no matching finish line,
#      for the archive that was loading, is now itself the record of what a mid-load interrupt
#      hit.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
SCRIPT="$ROOT/os/overlay/pithead-journal-persist"

echo "== unit: pithead-journal-persist binds /data onto the journal mountpoint (#1030) =="
JP="$SANDBOX/journal-persist"
mkdir -p "$JP/bin" "$JP/data-dir-parent" "$JP/target-parent"
MOUNT_LOG="$JP/mount.log"
CHOWN_LOG="$JP/chown.log"
: >"$MOUNT_LOG"
: >"$CHOWN_LOG"
cat >"$JP/bin/mount" <<EOF
#!/usr/bin/env bash
echo "mount \$*" >>"$MOUNT_LOG"
exit 0
EOF
# mountpoint answers from a marker file this test controls — real mountpoint(8) needs root to
# ever say "yes", which a tier-1 suite does not have.
cat >"$JP/bin/mountpoint" <<EOF
#!/usr/bin/env bash
[ -f "$JP/already-mounted" ] && exit 0
exit 1
EOF
# chown is stubbed (not just tolerated) so the assertion below can PROVE the call was made with
# the right owner, not just that the real chown's failure was swallowed — real chown(1) as this
# test's unprivileged user would fail either way, with or without the fix, so leaving it
# unstubbed would prove nothing.
cat >"$JP/bin/chown" <<EOF
#!/usr/bin/env bash
echo "chown \$*" >>"$CHOWN_LOG"
exit 0
EOF
chmod +x "$JP/bin/mount" "$JP/bin/mountpoint" "$JP/bin/chown"

DATA_DIR="$JP/data-dir-parent/journal"
TARGET="$JP/target-parent/journal"
rm -f "$JP/already-mounted"
out=$(PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
    sh "$SCRIPT" 2>&1)
assert_eq "the /data-side directory is created" "$([ -d "$DATA_DIR" ] && echo yes || echo no)" "yes"
assert_eq "the mountpoint directory is created (a bind mount needs an existing target)" \
    "$([ -d "$TARGET" ] && echo yes || echo no)" "yes"
# MUTATION KILL (#1030 review): drop the chown line and this goes red — chown.log stays empty,
# the exact gap the review finding pointed at (the comment claimed root:systemd-journal but
# nothing ever set it, leaving the persisted journal group root under a root:root parent).
assert_contains "the data directory is chowned to root:systemd-journal" \
    "$(cat "$CHOWN_LOG")" "root:systemd-journal $DATA_DIR"
assert_contains "mount --bind ran with the real (/data) source and the baked target" \
    "$(cat "$MOUNT_LOG")" "--bind $DATA_DIR $TARGET"
assert_contains "the script says what it bound" "$out" "bound $TARGET to $DATA_DIR"

# Idempotent: a boot that already bound it (or a unit re-run) must not mount twice.
: >"$MOUNT_LOG"
touch "$JP/already-mounted"
out=$(PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
    sh "$SCRIPT" 2>&1)
assert_eq "already mounted -> mount is not called again" "$(cat "$MOUNT_LOG")" ""
assert_contains "the script says it is already bound" "$out" "already the persistent mount"

# A rig stands down (#1817): its journal is volatile by design, and `pithead local-miner`
# reclaims /var/log/journal on every boot — a bind there turned the reclaim into an rm on a
# mountpoint, and under errexit the rig's boot verb died on it. The marker is the same file
# pithead-boot forks on, read the same way (whitespace-tolerant, the exact word).
echo "== unit: pithead-journal-persist stands down on a rig — the marker, not the bind (#1817) =="
ROLE_FILE="$JP/machine-role"
: >"$MOUNT_LOG"
rm -f "$JP/already-mounted"
printf 'rig\n' >"$ROLE_FILE"
out=$(PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
    PITHEAD_MACHINE_ROLE_FILE="$ROLE_FILE" sh "$SCRIPT" 2>&1)
assert_rc "rig marker -> rc 0 (the unit must not fail the early boot transaction)" "$?" "0"
assert_eq "rig marker -> mount is never called" "$(cat "$MOUNT_LOG")" ""
assert_contains "the script says why it stood down" "$out" "is a rig"
# Sibling controls: a coordinator marker and a near-miss both still bind — the fork is on the
# exact word, as in pithead-boot, and an absent marker (first boot) binds too.
for role in pithead rigs; do
    : >"$MOUNT_LOG"
    printf '%s\n' "$role" >"$ROLE_FILE"
    PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
        PITHEAD_MACHINE_ROLE_FILE="$ROLE_FILE" sh "$SCRIPT" >/dev/null 2>&1
    assert_contains "marker '$role' still binds" "$(cat "$MOUNT_LOG")" "--bind $DATA_DIR $TARGET"
done
: >"$MOUNT_LOG"
rm -f "$ROLE_FILE"
PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
    PITHEAD_MACHINE_ROLE_FILE="$ROLE_FILE" sh "$SCRIPT" >/dev/null 2>&1
assert_contains "no marker yet (first boot) still binds" "$(cat "$MOUNT_LOG")" "--bind $DATA_DIR $TARGET"

echo "== unit: load_baked_images narrates a FINISH, not just a start, per archive (#1030) =="
# Without this, a journal that survives a reset (the fix above) still shows only "Loading..."
# for an archive that was interrupted mid-write and a truncated load is indistinguishable from
# one that is still in progress. The finish line is the bracket.
FBJ="$SANDBOX/firstboot-journal"
mkdir -p "$FBJ/images" "$FBJ/bin" "$FBJ/data"
printf 'archive' >"$FBJ/images/dashboard.tar.gz"
cat >"$FBJ/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 1 ;;
load) exit 0 ;;
rm) exit 0 ;;
esac
EOF
chmod +x "$FBJ/bin/podman"
fbj_out=$(PITHEAD_ENGINE=podman FAKE_GRAPHROOT="" PATH="$FBJ/bin:$PATH" PITHEAD_IMAGES_DIR="$FBJ/images" \
    run_sourced "$FBJ" load_baked_images 2>&1)
assert_contains "the load still announces its start" "$fbj_out" "Loading this build's container images"
assert_contains "a successful load also announces its finish" "$fbj_out" "Finished loading dashboard.tar.gz in"
# A failed load must NOT claim a finish it never reached — the no-record-on-failure rule
# (the next boot retries) would otherwise be contradicted by the journal's own words.
rm -f "$FBJ/data/.loaded-dashboard.tar.gz.sha"
cat >"$FBJ/bin/podman" <<'EOF'
#!/usr/bin/env bash
case "$1" in
info) printf '%s\n' "${FAKE_GRAPHROOT:-}" ;;
image) exit 1 ;;
load) exit 1 ;;
rm) exit 0 ;;
esac
EOF
fbj_out=$(PITHEAD_ENGINE=podman FAKE_GRAPHROOT="" PATH="$FBJ/bin:$PATH" PITHEAD_IMAGES_DIR="$FBJ/images" \
    run_sourced "$FBJ" load_baked_images 2>&1)
assert_not_contains "a failed load reports no finish line" "$fbj_out" "Finished loading"
assert_contains "a failed load is still named as a failure" "$fbj_out" "Could not load"

echo ""
printf 'firstboot-journal tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
