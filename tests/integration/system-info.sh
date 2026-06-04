#!/usr/bin/env bash
#
# system-info.sh — snapshot the hardware/layout of a Pithead build/test server as Markdown.
# Re-run any time (no sudo, safe while the stack is live):
#   ~/pithead-testbench/system-info.sh > ~/pithead-testbench/system-info.md
#
# Lives in the repo (tests/integration/) so it is versioned; deployed onto the box for operators
# and AI agents to discover what they are working with.
set -uo pipefail

STACK_DIR="${STACK_DIR:-$HOME/code/p2pool-starter-stack}"

h()    { printf '\n## %s\n\n' "$1"; }
fence(){ printf '```\n'; cat; printf '```\n'; }

printf '# Pithead build server — system snapshot\n\n'
printf '_Host `%s` — generated %s_\n' "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S %z')"
printf '\n> Regenerate: `~/pithead-testbench/system-info.sh > ~/pithead-testbench/system-info.md`\n'

h "OS & kernel"
{
    # shellcheck disable=SC1091
    { . /etc/os-release 2>/dev/null && echo "Distro: ${PRETTY_NAME:-?}"; } || true
    echo "Kernel: $(uname -sr)"
    echo "Uptime:$(uptime -p 2>/dev/null | sed 's/^up//' || true)"
} | fence

h "CPU"
lscpu 2>/dev/null | grep -E 'Model name|^CPU\(s\)|Thread\(s\) per core|Core\(s\) per socket' | sed 's/  */ /g' | fence

h "Memory"
free -h 2>/dev/null | fence

h "Disks — ROTA 0 = SSD/NVMe (fast), 1 = HDD (slow)"
lsblk -d -o NAME,ROTA,SIZE,MODEL,TYPE 2>/dev/null | fence
printf '\n**Storage policy:** active monerod/Tari chains live on the **NVMe** (root LV). The **HDD**\n'
printf '(`/home`) is for backups / cold storage / the CoW loopback only — a chain on the HDD makes\n'
printf 'every test scenario crawl. Check `ROTA` before placing any chain.\n'

h "Filesystems"
df -hT / /home /mnt/chains 2>/dev/null | fence

h "Chains"
{
    mdir="$(readlink -f "$STACK_DIR/data/monero" 2>/dev/null)"
    tdir="$(readlink -f "$STACK_DIR/data/tari" 2>/dev/null)"
    echo "Monero : ${mdir:-?}"
    echo "         size $(du -sh "$mdir" 2>/dev/null | cut -f1)  |  MONERO_PRUNE=$(grep -E '^MONERO_PRUNE=' "$STACK_DIR/.env" 2>/dev/null | cut -d= -f2-) (1=pruned)"
    echo "Tari   : ${tdir:-?}"
    echo "         size $(du -sh "$tdir" 2>/dev/null | cut -f1)  |  archival/full (no pruning configured)"
} | fence
printf '\n_A pruned Monero chain that reads ~250 GiB on disk is LMDB free-page bloat, not a full chain;\n'
printf 'see the build-server README for the compaction procedure._\n'

h "Docker & containers"
docker --version 2>/dev/null | fence
printf '\n'
docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | fence

h "monerod version"
docker exec monerod monerod --version 2>/dev/null | head -1 | fence

h "Listening sockets — dashboard :8000 must be 127.0.0.1"
{ PATH="/usr/sbin:/sbin:$PATH"; ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E ':(8000|3333|18081|18083|37889|3344)$' | sort -u || echo "(ss not available)"; } | fence

printf '\n---\n_See `README.md` in this directory for how to run the stack and the test harness._\n'
