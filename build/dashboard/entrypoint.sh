#!/bin/bash
export HOST_IP=$(ip -4 addr show | grep -v '127.0.0.1' | grep 'inet' | head -n 1 | awk '{print $2}' | cut -d/ -f1)

exec python3 -u /app/mining_status.py