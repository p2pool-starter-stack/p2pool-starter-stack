#!/bin/bash
#
# Kernel Boot Parameter Calculator for RandomX Mining
#
# Analyzes hardware topology (L3 Cache, Sockets) to recommend optimal
# GRUB configuration for HugePages (1GB/2MB) and MSR registers.
#

# Parse arguments
QUIET=0
if [[ "$*" == *"-q"* ]]; then
    QUIET=1
fi

# --- 1. Hardware Topology Discovery ---

# Extract L3 Cache size and normalize to Megabytes
# Output format varies (e.g., "32M", "32768K"), so we strip non-numeric characters.
L3_RAW=$(lscpu | grep "L3 cache" | head -n 1 | awk '{print $3$4}')
L3_MB=$(echo "$L3_RAW" | sed 's/[^0-9]//g')

# Convert Kilobytes to Megabytes if necessary
if [[ "$L3_RAW" == *K* ]]; then
    L3_MB=$((L3_MB / 1024))
fi
if [[ -z "$L3_MB" ]]; then
    L3_MB=4
fi

# Detect Physical CPU Sockets (NUMA Nodes)
SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $2}')
if [[ -z "$SOCKETS" ]]; then
    SOCKETS=1
fi

# --- 2. Resource Calculation ---

# RandomX Requirement: 2MB L3 Cache per mining thread
THREADS=$((L3_MB / 2))

# 1GB HugePages: Reserve 3GB per socket for the RandomX dataset (~2080MB) + overhead
TOTAL_GB_PAGES=$((3 * SOCKETS))

# 2MB HugePages: Reserve for JIT compiler and scratchpads (128 base + 1 per thread + buffer)
TOTAL_2MB_PAGES=$((128 + THREADS + 10))

# Fallback Strategy (Pure 2MB): Covers Dataset (2080MB) + Overhead + JIT
# 1168 pages * 2MB = ~2336MB per socket (Provides ~250MB buffer for fragmentation)
BASE_2MB_PAGES=1168
TOTAL_2MB_FALLBACK=$(((BASE_2MB_PAGES * SOCKETS) + THREADS + 50))

if [[ "$*" == *"--runtime"* ]]; then
    # Check if 1GB pages are already allocated
    PAGES_1GB=0
    if [ -f /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages ]; then
        PAGES_1GB=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages || echo 0)
    fi

    if [ "$PAGES_1GB" -gt 0 ]; then
        echo "$TOTAL_2MB_PAGES"
    else
        echo "$TOTAL_2MB_FALLBACK"
    fi
    exit 0
fi

# --- 3. Configuration Generation ---

# Check for 1GB HugePage support (pdpe1gb flag)
if grep -q "pdpe1gb" /proc/cpuinfo; then
    # Strategy: Use 1GB pages for dataset, 2MB for JIT
    NEW_GRUB="quiet splash hugepagesz=1G hugepages=$TOTAL_GB_PAGES hugepagesz=2M hugepages=$TOTAL_2MB_PAGES default_hugepagesz=2M msr.allow_writes=on"
else
    # Fallback Strategy: Use only 2MB pages
    NEW_GRUB="quiet splash default_hugepagesz=2M hugepages=$TOTAL_2MB_FALLBACK msr.allow_writes=on"
fi

# --- 4. Output ---

if [ $QUIET -eq 1 ]; then
    echo "$NEW_GRUB"
else
    echo "--- Hardware Analysis ---"
    echo "L3 Cache:      ${L3_MB} MB"
    echo "CPU Sockets:   $SOCKETS"
    echo "Max Threads:   $THREADS (Based on 2MB L3/thread)"
    echo "-------------------------"
    echo "Proposed GRUB Configuration:"
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_GRUB\""
fi