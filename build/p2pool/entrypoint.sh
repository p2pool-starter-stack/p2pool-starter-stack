#!/bin/bash
set -euo pipefail

# P2Pool launcher. (mDNS/.local resolution was removed — point p2pool at an IP or a
# DNS-resolvable hostname; on a home LAN, use a DHCP reservation or static IP.)
exec p2pool "$@"
