#!/bin/bash
set -e

# We no longer dynamically fetch the LAN IP here because the dashboard 
# MUST be bound to localhost (127.0.0.1) to remain secure behind Caddy.
# The HOST_IP variable is now injected directly via docker-compose.yml.

# Fallback to localhost if the variable is somehow missing
export HOST_IP="${HOST_IP:-127.0.0.1}"

# Navigate to the application source root to ensure Python module resolution works correctly
cd /app/mining_dashboard

# Launch the main application process
# 'exec' replaces the shell process to handle signals (SIGTERM) correctly
# '-u' forces unbuffered stdout/stderr for real-time Docker logging
exec python3 -u main.py