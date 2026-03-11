#!/bin/bash
set -e

echo "[P2Pool Init] Starting mDNS resolution wrapper..."

# Look through the arguments for any .local addresses
for arg in "$@"; do
    if [[ "$arg" == *".local" ]]; then
        echo "[P2Pool Init] Found mDNS target: $arg"
        echo "[P2Pool Init] Attempting to resolve via host Avahi daemon..."
        
        # Give DBus a moment to ensure socket readiness
        sleep 1 
        
        # Use avahi-resolve (IPv4 only) and extract just the IP address
        # This command utilizes the mounted /var/run/avahi-daemon/socket 
        RESOLVED_IP=$(avahi-resolve -n4 "$arg" | awk '{print $2}')
        
        if [ -n "$RESOLVED_IP" ]; then
            echo "[P2Pool Init] Successfully resolved $arg to $RESOLVED_IP"
            # Inject it into the container's hosts file
            echo "$RESOLVED_IP $arg" >> /etc/hosts
            echo "[P2Pool Init] Added to /etc/hosts."
        else
            echo "[P2Pool Init] WARNING: Failed to resolve $arg. P2Pool may fail to connect."
        fi
    fi
done

echo "[P2Pool Init] Launching P2Pool..."
# Execute the original p2pool binary with all the original arguments
exec p2pool "$@"