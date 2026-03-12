#!/bin/bash
set -euo pipefail

IPV4_REGEX="^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"


log() {
    local level="$1"
    shift
    if [[ "$level" == "ERROR" || "$level" == "WARN" ]]; then
        echo "[P2Pool Init] [$level] $*" >&2
    else
        echo "[P2Pool Init] [INFO] $*"
    fi
}

check_prerequisites() {
    local ready="true"

    if ! command -v avahi-resolve >/dev/null 2>&1; then
        log WARN "'avahi-resolve' command not found. Install avahi-utils."
        ready="false"
    fi

    if [[ ! -S "/var/run/avahi-daemon/socket" ]]; then
        log WARN "Avahi socket not found at /var/run/avahi-daemon/socket. Ensure it is mounted."
        ready="false"
    fi

    echo "$ready"
}

resolve_and_inject() {
    local target="$1"
    local resolved_ip=""

    log INFO "Attempting to resolve $target via host Avahi daemon..."

    for attempt in 1 2 3; do
        resolved_ip=$(avahi-resolve -n4 "$target" 2>/dev/null | awk '{print $2}' || true)
        
        [[ -n "$resolved_ip" ]] && break
        
        log WARN "Resolution attempt $attempt failed, retrying in $attempt second(s)..."
        sleep "$attempt"
    done

    if [[ -z "$resolved_ip" ]]; then
        log WARN "Failed to resolve $target after 3 attempts. P2Pool may fail to connect."
        return 0
    fi

    if [[ ! "$resolved_ip" =~ $IPV4_REGEX ]]; then
        log WARN "Resolved value '$resolved_ip' for $target is not a valid IPv4 address. Skipping."
        return 0
    fi

    log INFO "Successfully resolved $target to $resolved_ip"

    if [[ ! -w "/etc/hosts" ]]; then
        log ERROR "/etc/hosts is not writable. Ensure the container runs as root or has correct permissions."
        exit 1
    fi

    local safe_target="${target//./\.}"
    sed -i "/[[:space:]]${safe_target}\$/d" /etc/hosts 2>/dev/null || true
    
    echo "$resolved_ip $target" >> /etc/hosts
    log INFO "Cleaned old entries and added $target to /etc/hosts."
}

log INFO "Starting mDNS resolution wrapper..."

MDNS_READY=$(check_prerequisites)

for arg in "$@"; do
    if [[ "$arg" == *".local" ]]; then
        log INFO "Found mDNS target: $arg"
        
        if [[ "$MDNS_READY" == "false" ]]; then
             log WARN "Skipping resolution for $arg due to missing prerequisites."
             continue
        fi

        resolve_and_inject "$arg"
    fi
done

log INFO "Launching P2Pool..."
exec p2pool "$@"