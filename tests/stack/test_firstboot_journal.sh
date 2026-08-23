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
: >"$MOUNT_LOG"
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
chmod +x "$JP/bin/mount" "$JP/bin/mountpoint"

DATA_DIR="$JP/data-dir-parent/journal"
TARGET="$JP/target-parent/journal"
rm -f "$JP/already-mounted"
out=$(PATH="$JP/bin:$PATH" PITHEAD_JOURNAL_DATA_DIR="$DATA_DIR" PITHEAD_JOURNAL_TARGET="$TARGET" \
    sh "$SCRIPT" 2>&1)
assert_eq "the /data-side directory is created" "$([ -d "$DATA_DIR" ] && echo yes || echo no)" "yes"
assert_eq "the mountpoint directory is created (a bind mount needs an existing target)" \
    "$([ -d "$TARGET" ] && echo yes || echo no)" "yes"
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
