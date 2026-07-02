#!/usr/bin/env bash
#
# build-pruned-chain.sh — one-shot builder for a pruned Monero chain alongside the
# canonical full chain, used to give the live test harness BOTH prune modes on one box.
#
# Strategy (minimal mining downtime, full chain never modified):
#   1. stop monerod            -> makes the live LMDB consistent for copying
#   2. copy full data.mdb      -> onto the CoW (btrfs) volume   [downtime window]
#   3. start monerod           -> mining resumes immediately after the copy
#   4. prune the COPY in place -> shrinks ~250G -> ~95G, full chain untouched
#
# Self-contained + idempotent-ish: logs with timestamps, writes a status sentinel,
# and always restarts monerod even if the copy fails. Designed to be run under nohup.
set -uo pipefail

SRC_DIR="${SRC_DIR:-$HOME/code/p2pool-starter-stack/data/monero}"
DST_DIR="${DST_DIR:-/mnt/chains/monero-pruned}"
PRUNE_BIN="${PRUNE_BIN:-$HOME/pithead-testbench/bin/monero-blockchain-prune}"
STATUS="${STATUS:-$HOME/pithead-testbench/status}"
CONTAINER="${CONTAINER:-monerod}"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
say() { echo "[$(ts)] $*"; }
set_status() { echo "$1" >"$STATUS"; }

say "START build-pruned-chain"
say "src=$SRC_DIR dst=$DST_DIR"
mkdir -p "$DST_DIR/lmdb"

src_mdb="$SRC_DIR/lmdb/data.mdb"
if [ ! -f "$src_mdb" ]; then
    say "FATAL: source $src_mdb not found"
    set_status "FAIL_NO_SRC"
    exit 1
fi
say "source size: $(du -h "$src_mdb" | cut -f1)"

set_status "STOPPING"
say "stopping $CONTAINER (downtime begins)"
docker stop "$CONTAINER" >/dev/null 2>&1 || { say "WARN docker stop failed (already stopped?)"; }

set_status "COPYING"
say "copy begin"
copy_start=$(date +%s)
cp "$src_mdb" "$DST_DIR/lmdb/data.mdb"
rc=$?
copy_end=$(date +%s)
say "copy done rc=$rc in $((copy_end - copy_start))s"

# Restart monerod immediately, regardless of copy outcome — minimise downtime.
set_status "RESTARTING"
say "starting $CONTAINER (downtime ends)"
docker start "$CONTAINER" >/dev/null 2>&1 || say "WARN docker start failed"

if [ $rc -ne 0 ]; then
    say "FATAL: copy failed"
    set_status "FAIL_COPY"
    exit 1
fi

set_status "PRUNING"
say "prune begin (full chain is back online; pruning the copy)"
prune_start=$(date +%s)
"$PRUNE_BIN" --data-dir "$DST_DIR" 2>&1
rc=$?
prune_end=$(date +%s)
say "prune done rc=$rc in $((prune_end - prune_start))s"
if [ $rc -ne 0 ]; then
    say "FATAL: prune failed"
    set_status "FAIL_PRUNE"
    exit 1
fi

say "pruned size: $(du -h "$DST_DIR/lmdb/data.mdb" | cut -f1)"
set_status "DONE"
say "ALL DONE"
