#!/bin/bash
# Detect Host IP for display in the dashboard
export HOST_IP=$(ip -4 addr show | grep -v '127.0.0.1' | grep 'inet' | head -n 1 | awk '{print $2}' | cut -d/ -f1)

# Navigate into the module directory so imports (like 'from config import...') work natively
cd /app/mining_dashboard

# Run the new entry point
exec python3 -u main.py