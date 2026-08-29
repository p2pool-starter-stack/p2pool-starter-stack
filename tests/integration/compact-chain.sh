#!/usr/bin/env bash
#
# compact-chain.sh — build a compact pruned Monero chain from an existing chain.
#
# An in-place prune leaves the LMDB file at its full-chain high-water mark (LMDB never shrinks
# its file), so a pruned chain can sit at ~270 GiB on disk while holding only ~95 GiB of live
# data. `monero-blockchain-prune` rewrites the chain into a fresh DB at <data-dir>/lmdb-pruned,
# which comes out at its true compact size.
#
# THE TOOL IS COPY-THEN-SWAP — IT DOES NOT ONLY READ THE SOURCE (#1489).
#   After building <data-dir>/lmdb-pruned it renames <data-dir>/lmdb to <data-dir>/lmdb-old and
#   moves the pruned DB into its place. The binary carries the strings "Swapping databases,
#   pre-pruning blockchain will be left in", "-old and can be removed if desired" and
#   "Blockchain pruned OK, but renaming failed". `--copy-pruned-database` does not change that:
#   its help text is "Copy database anyway if already pruned", so it lifts an early-exit guard on
#   an already-pruned source rather than selecting a copy-only mode.
#
#   So pointing this at a LIVE node's data dir renames the live chain out from under a running
#   monerod. The running process keeps its open descriptors, so nothing fails at the time — the
#   next restart silently comes up pruned, with the old chain left beside it eating disk.
#
# TO RUN IT AGAINST A LIVE CHAIN, BIND-MOUNT THE SOURCE (#1489):
#   mkdir -p <build-dir>/lmdb
#   mount --bind <live-data-dir>/lmdb <build-dir>/lmdb
#   compact-chain.sh <build-dir>
#
#   The copy still reads the live chain through LMDB's consistent snapshot, so monerod keeps
#   mining with no downtime; the final rename is refused by the kernel with EBUSY, so the live
#   chain cannot be touched, and the pruned result is left at <build-dir>/lmdb-pruned. Prove the
#   guard before you rely on it — `mv <build-dir>/lmdb <build-dir>/x` must answer "Device or
#   resource busy".
#
# Speed: it copies every block one-by-one, so it is SLOW (many HOURS for a mainnet chain). It is
# NOT a page-level copy. The generic `mdb_copy -c` does NOT work on a Monero chain: Monero ships
# a patched LMDB and stock mdb_copy rejects the on-disk format (MDB_VERSION_MISMATCH).
#
# This script ONLY runs the tool; it does not stop or start containers. It logs before/after
# sizes and writes a status sentinel.
set -uo pipefail

DATA_DIR="${1:?usage: compact-chain.sh <data-dir>}"
PRUNE_BIN="${PRUNE_BIN:-$HOME/pithead-testbench/bin/monero-blockchain-prune}"
LOG="${LOG:-$HOME/pithead-testbench/compact.log}"
STATUS="${STATUS:-$HOME/pithead-testbench/compact-status}"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() { echo "[$(ts)] $*" | tee -a "$LOG"; }

{
    echo "===== compact run $(ts) ====="
    echo "data-dir: $DATA_DIR"
    echo "--- lmdb BEFORE ---"
    ls -la "$DATA_DIR/lmdb/" 2>/dev/null
    echo "data.mdb apparent+disk:"
    du -h --apparent-size "$DATA_DIR/lmdb/data.mdb" 2>/dev/null
    du -h "$DATA_DIR/lmdb/data.mdb" 2>/dev/null
} >>"$LOG" 2>&1

echo COMPACTING >"$STATUS"
say "compaction begin (data-dir=$DATA_DIR)"
t0=$(date +%s)
"$PRUNE_BIN" --data-dir "$DATA_DIR" --copy-pruned-database >>"$LOG" 2>&1
rc=$?
t1=$(date +%s)
say "compaction done rc=$rc in $((t1 - t0))s"

{
    echo "--- lmdb AFTER ---"
    ls -la "$DATA_DIR/lmdb/" 2>/dev/null
    echo "data.mdb apparent+disk:"
    du -h --apparent-size "$DATA_DIR/lmdb/data.mdb" 2>/dev/null
    du -h "$DATA_DIR/lmdb/data.mdb" 2>/dev/null
} >>"$LOG" 2>&1

if [ $rc -eq 0 ]; then echo DONE >"$STATUS"; else echo "FAIL_rc$rc" >"$STATUS"; fi
say "status=$(cat "$STATUS")"
