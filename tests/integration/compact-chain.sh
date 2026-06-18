#!/usr/bin/env bash
#
# compact-chain.sh — reclaim LMDB file bloat from an already-pruned Monero chain.
#
# An in-place prune leaves the LMDB file at its full-chain high-water mark (LMDB never shrinks
# its file), so a pruned chain can sit at ~270 GiB on disk while holding only ~95 GiB of live
# data. `monero-blockchain-prune --copy-pruned-database` rewrites the chain into a fresh DB at
# <data-dir>/lmdb-pruned, which comes out at its true compact size.
#
# IMPORTANT — speed & safety:
#  * It copies every block one-by-one, so it is SLOW (multiple HOURS for a mainnet chain). It is
#    NOT a page-level copy.
#  * It only READS the source, through a consistent LMDB snapshot, so it is safe to run while
#    monerod is up and mining — zero downtime during the copy; the source is never modified.
#  * The generic `mdb_copy -c` does NOT work on a Monero chain: Monero ships a patched LMDB and
#    stock mdb_copy rejects the on-disk format (MDB_VERSION_MISMATCH). This tool is the only path.
#
# When it finishes, swap the compact copy in (brief downtime) and verify:
#   docker stop monerod
#   mv <data-dir>/lmdb <data-dir>/lmdb.bloated && mv <data-dir>/lmdb-pruned <data-dir>/lmdb
#   docker start monerod      # re-syncs the few blocks added during the copy
#   # confirm healthy (get_info: synchronized), then: rm -rf <data-dir>/lmdb.bloated
#
# This script ONLY builds the compact copy; it does not stop/start containers or swap. Logs
# before/after sizes and a status sentinel.
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
