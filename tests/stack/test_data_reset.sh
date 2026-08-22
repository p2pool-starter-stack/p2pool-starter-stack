#!/usr/bin/env bash
#
# Tier-1 proof that pithead-data-reset repairs REAL damage before it will ever decide to
# reformat (#1062). run.sh's decision-tree block drives data_reset_decision with stubbed
# repair tools that model their contracts — the right way to prove marker precedence and
# escalation order, and constitutionally unable to prove the repair itself: a stub's verdict
# proves the stub (#1086). Here the filesystem, the damage, and the repair tools are real.
# The image is a genuine ext4 filesystem, the corruption is the same two-byte superblock-magic
# wipe the tier-4 battery injects, and fsck/e2fsck/mke2fs are the system binaries the product
# runs. Only mount is stubbed — mounting needs root — and its verdict comes from the
# filesystem itself (`e2fsck -fn`: succeed only when the filesystem is genuinely clean),
# never from a counter.
#
# The image is 600 MiB, sparse, so it costs a few MiB of real disk. The size is load-bearing:
# below 512 MiB mke2fs's usage-type heuristic switches to 1 KiB blocks, and the geometry
# `mke2fs -n` computes for backup_superblocks() no longer matches what mkfs.ext4 wrote. No
# real /data — it holds two chains — is anywhere near that small, and staying above the
# threshold keeps the product's own derivation honest against this image.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
RESET="$ROOT/os/overlay/pithead-data-reset"

# e2fsprogs is the product's own dependency — without it this suite proves nothing, and a
# silently skipped gate reads as a passed one. CI must have the tools; a dev box may lack them.
for tool in mkfs.ext4 e2fsck mke2fs debugfs; do
    command -v "$tool" >/dev/null 2>&1 || {
        if [ "${CI:-}" = "1" ] || [ "${CI:-}" = "true" ]; then
            echo "FATAL: $tool is missing — e2fsprogs is required in CI" >&2
            exit 1
        fi
        echo "SKIP: $tool not available — install e2fsprogs to run the real-image data-reset suite"
        exit 0
    }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/data.img"
PAYLOAD="IRREPLACEABLE-WALLET-KEY-MATERIAL"

# The mount stub: succeed exactly when the filesystem is clean. `e2fsck -fn` opens the
# filesystem read-only and answers "no" to every repair, so its exit is a pure verdict on the
# image — the one thing a counter-driven stub could never be (#1086).
mkdir -p "$WORK/bin"
cat >"$WORK/bin/mount" <<'EOF'
#!/usr/bin/env bash
exec e2fsck -fn "${@: -2:1}" >/dev/null 2>&1
EOF
cat >"$WORK/bin/umount" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$WORK/bin/mount" "$WORK/bin/umount"

# Source the boot script (functions only — its main is guarded) and ask for the decision on
# the real image. stdout is the verdict; stderr carries the product's own escalation log.
decide() { # $1: marker path -> verdict on stdout, product log on stderr
    (
        PATH="$WORK/bin:$PATH"
        # shellcheck disable=SC1090  # product script path is derived from ROOT
        source "$RESET"
        data_reset_decision "$IMG" "$1"
    )
}

fresh_image() {
    rm -f "$IMG"
    truncate -s 600M "$IMG"
    mkfs.ext4 -q -F -L data "$IMG"
    printf '%s\n' "$PAYLOAD" >"$WORK/payload.txt"
    debugfs -w -R "write $WORK/payload.txt wallet.txt" "$IMG" >/dev/null 2>&1
}

echo "== real-image: a healthy /data is never touched =="
fresh_image
verdict=$(decide /nonexistent 2>"$WORK/healthy.log")
assert_eq "healthy filesystem, no marker -> skip" "$verdict" "skip"
assert_not_contains "no repair was even attempted on a healthy filesystem" \
    "$(cat "$WORK/healthy.log")" "escalating"

echo "== real-image: the exact damage class the issue reproduced (#1062) =="
# Zero the ext4 magic: two bytes at offset 1080 (the 1024-byte superblock padding plus
# s_magic at 0x38) — the same write tests/os/run.sh injects on the tier-4 battery. `fsck -p`
# refuses this class by definition; before #1124 the product answered reformat-wedged and
# mkfs.ext4 took the wallets, the onion keys and both chains.
dd if=/dev/zero of="$IMG" bs=1 seek=1080 count=2 conv=notrunc 2>/dev/null
e2fsck -fn "$IMG" >/dev/null 2>&1 && damaged_rc=0 || damaged_rc=$?
assert_not_contains "the injected damage is real (e2fsck refuses the image as-is)" \
    "rc=$damaged_rc" "rc=0"
verdict=$(decide /nonexistent 2>"$WORK/repair.log")
assert_eq "superblock-damaged /data that e2fsck can repair -> skip, NOT a wipe" \
    "$verdict" "skip"
assert_contains "the repair escalation engaged and reported which rung repaired it" \
    "$(cat "$WORK/repair.log")" "repaired $IMG"
assert_eq "the payload SURVIVED the repair — the data is intact, not recreated" \
    "$(debugfs -R 'cat /wallet.txt' "$IMG" 2>/dev/null)" "$PAYLOAD"

echo "== real-image: a destroyed filesystem still reaches the reformat escape =="
# No filesystem at all: every byte a hole. Every rung of the escalation must fail, and the
# verdict must fall through to reformat-wedged — a shell-less box with a truly dead /data has
# no other way back (the defect was choosing this FIRST, not having it).
truncate -s 0 "$IMG" && truncate -s 600M "$IMG"
verdict=$(decide /nonexistent 2>/dev/null)
assert_eq "no filesystem at all -> reformat-wedged (the recovery path stays reachable)" \
    "$verdict" "reformat-wedged"

echo ""
printf 'data-reset real-image tests: \033[1;32m%d passed\033[0m, ' "$PASS"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31m%d failed\033[0m\n' "$FAIL"
    exit 1
fi
printf '0 failed\n'
