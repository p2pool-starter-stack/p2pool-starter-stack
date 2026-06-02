#!/bin/bash
set -e

# We no longer dynamically fetch the LAN IP here because the dashboard 
# MUST be bound to localhost (127.0.0.1) to remain secure behind Caddy.
# The HOST_IP variable is now injected directly via docker-compose.yml.

# Fallback to localhost if the variable is somehow missing
export HOST_IP="${HOST_IP:-127.0.0.1}"

# Launch the application as an installed package module from /app.
# 'exec' replaces the shell process so SIGTERM is handled correctly;
# '-u' forces unbuffered stdout/stderr for real-time Docker logging.
cd /app
exec python3 -u -m mining_dashboard.main