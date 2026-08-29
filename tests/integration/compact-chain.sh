#!/usr/bin/env bash
#
# compact-chain.sh — build a compact pruned Monero chain from an existing chain.
#
# An in-place prune leaves the LMDB file at its full-chain high-water mark (LMDB never shrinks
# its file), so a pruned chain can sit on disk at a size its live data no longer justifies.
# `monero-blockchain-prune` rewrites the chain into a fresh DB at <data-dir>/lmdb-pruned, which
# comes out at its true compact size.
#
# DO NOT DIAGNOSE BLOAT FROM THE FILE SIZE ALONE — MEASURE THE FREELIST (#1446).
#   This bench's 258 GiB pruned chain has a freelist of 10 pages out of 67,605,667 and
#   `pages_used * 4096` == the file size: it is dense, already pruned, and this tool would spend
#   ~2.5 hours reclaiming nothing. Read `mdb_stat -ef` on an IDLE copy first. (An earlier header
#   here promised "~95 GiB of live data" — a retired expectation, never a measurement.)
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
#   The read is still a real LMDB reader on the live DB: a long read transaction pins freed pages,
#   so the LIVE data.mdb can GROW while the copy runs. Watch `df` for the whole run.
#
# Speed: it copies every block one-by-one, so it is SLOW (many HOURS for a mainnet chain). It is
# NOT a page-level copy.
#
# MDB_VERSION_MISMATCH IS THE LOCK-FILE FORMAT, NOT A PATCHED ON-DISK FORMAT (#1446).
#   The error appears while monerod HOLDS the environment; a stock LMDB tool opens an IDLE copy
#   of the same chain (both DBs are magic 0xbeefc0de, version 1). Not corruption — do not stop
#   monerod over it. An earlier header blamed "a patched LMDB"; that was wrong. Note mdb_stat
#   REWRITES lock.mdb, so control on data.mdb specifically.
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
