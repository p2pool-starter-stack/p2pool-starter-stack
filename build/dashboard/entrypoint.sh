#!/bin/bash
set -e

# Retrieve the container's primary IPv4 address for dashboard binding and display
export HOST_IP=$(ip -4 addr show | grep -v '127.0.0.1' | grep 'inet' | head -n 1 | awk '{print $2}' | cut -d/ -f1)

# Navigate to the application source root to ensure Python module resolution works correctly
cd /app/mining_dashboard

# Launch the main application process
# 'exec' replaces the shell process to handle signals (SIGTERM) correctly
# '-u' forces unbuffered stdout/stderr for real-time Docker logging
exec python3 -u main.py