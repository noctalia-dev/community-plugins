#!/usr/bin/env bash
# Creates virtual AP interface for concurrent client and hotspot operation
set -euo pipefail

BASE="${1:-${HOTSPOT_BASE:-}}"
if [ -z "$BASE" ]; then
    BASE=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi" && $1!~/-ap$/ && $1!~/^p2p-/ {print $1; exit}')
    [ -z "$BASE" ] && command -v iw >/dev/null 2>&1 && BASE=$(iw dev 2>/dev/null | awk '/Interface/ {if ($2 !~ /-ap$/ && $2 !~ /^p2p-/) {print $2; exit}}')
    [ -z "$BASE" ] && BASE="wlan0"
fi
BASE=$(echo "$BASE" | tr -cd 'a-zA-Z0-9_.-')

AP="${2:-${HOTSPOT_IFACE:-${BASE}-ap}}"
AP=$(echo "$AP" | tr -cd 'a-zA-Z0-9_.-')
[ -z "$AP" ] && AP="${BASE}-ap"
[ -d "/sys/class/net/${AP}" ] && { ip link set "${AP}" up 2>/dev/null || true; exit 0; }

RUN() {
    if [ "$(id -u)" -eq 0 ]; then "$@" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then sudo -n "$@" 2>/dev/null || true
    elif command -v pkexec >/dev/null 2>&1; then pkexec "$@" 2>/dev/null || true
    else "$@" 2>/dev/null || true
    fi
}

RUN iw dev "${BASE}" interface add "${AP}" type __ap
ip link set "${AP}" up 2>/dev/null || true
