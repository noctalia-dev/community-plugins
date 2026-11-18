#!/bin/sh
# Regenerates tests/fixtures/ from the live machine, so the parser is tested
# against real nmcli output instead of a hand-written guess at it.
#
#   sh tests/capture-fixtures.sh
#
# Read-only against the live network: the one profile it creates is never
# activated (no route, no addressing change) and is deleted again at the end.
# Keep the field lists below in sync with net.luau's M.*_FIELDS constants.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dir="$here/fixtures"
mkdir -p "$dir"

INV="NAME,UUID,TYPE,DEVICE,STATE,ACTIVE"
PROF="ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.dns-search,ipv6.method,ipv6.addresses,ipv6.gateway,ipv6.dns,ipv6.dns-search"
DEV="GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS,IP6.GATEWAY,IP6.DNS"
STATUS="DEVICE,TYPE,STATE,CONNECTION"

nmcli -t -f "$INV" con show > "$dir/inventory.txt"
nmcli -t -f "$STATUS" dev status > "$dir/device-status.txt"
nmcli -t general permissions > "$dir/permissions.txt"
nmcli radio > "$dir/radio.txt"

# The first active non-loopback connection stands in for "the profile being
# edited"; its device gives the live values.
active_uuid=$(nmcli -t -f UUID,ACTIVE,TYPE con show | grep -v ':loopback:' | awk -F: '$2 == "yes" { print $1; exit }')
nmcli -t -f "$PROF" con show "$active_uuid" > "$dir/profile-dhcp.txt"
device=$(nmcli -t -f DEVICE,STATE,CONNECTION dev status | awk -F: '$2 == "connected" { print $1; exit }')
nmcli -t -f "$DEV" dev show "$device" > "$dir/device-live.txt"

# A static profile, configured but never brought up: the dummy link would win the
# default route if it were activated. Only methods that allow addressing can
# carry addresses - NM rejects the write otherwise.
#
# The profile is this script's own: if a connection of that name already exists it
# is not touched, not modified and not deleted. The name carries the pid so two
# runs cannot collide, and the trap removes it however this script exits.
PROFILE="netctl-fixture-$$"
cleanup() {
  if [ "$created" = "yes" ]; then
    nmcli con delete "$PROFILE" >/dev/null 2>&1 || true
  fi
}
created=no
trap cleanup EXIT INT TERM
if nmcli -t -f NAME con show | grep -qx "$PROFILE"; then
  echo "refusing to run: a connection named $PROFILE already exists" >&2
  exit 1
fi
nmcli con add type dummy con-name "$PROFILE" ifname netctlfix0 >/dev/null || exit 1
created=yes
nmcli con mod "$PROFILE" ipv4.method manual ipv4.addresses 10.99.0.5/24 \
  ipv4.gateway 10.99.0.1 ipv4.dns "9.9.9.9,149.112.112.112" ipv4.dns-search example.test \
  ipv6.method manual ipv6.addresses 2001:db8::5/64 ipv6.gateway 2001:db8::1 >/dev/null
nmcli -t -f "$PROF" con show "$PROFILE" > "$dir/profile-static.txt"
nmcli con delete netctl-fixture >/dev/null

# The kernel's own choice of route, which is what the widget reports.
ip -j route get 1.1.1.1 > "$dir/route-get.json"

# The Wi-Fi scan, with SSIDs replaced by stable aliases: the fixture has to keep
# the real shape (one row per BSSID, so repeated SSIDs at different signal
# strengths, the padded IN-USE column, an empty SSID for a hidden network) without
# copying a neighbourhood into a file that may get published.
nmcli -t -f "IN-USE,SSID,SIGNAL,SECURITY" dev wifi list | python3 -c '
import sys

def split_terse(line):
    values, chars, index = [], [], 0
    while index < len(line):
        char = line[index]
        if char == "\\" and index + 1 < len(line):
            chars.append(line[index + 1])
            index += 2
        elif char == ":":
            values.append("".join(chars))
            chars = []
            index += 1
        else:
            chars.append(char)
            index += 1
    values.append("".join(chars))
    return values

aliases = {}
for line in sys.stdin.read().splitlines():
    fields = split_terse(line)
    if len(fields) < 4:
        continue
    ssid = fields[1]
    if ssid and ssid not in aliases:
        aliases[ssid] = "sample-net-%d" % len(aliases)
    fields[1] = aliases.get(ssid, ssid)
    print(":".join(fields))
' > "$dir/wifi-list.txt"

echo "fixtures refreshed in $dir"
