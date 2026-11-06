#!/usr/bin/env bash
# Usage: bash mullvad/tests/capture-fixtures.sh <label> [command ...]
# Captures `mullvad status --json` and each `get` command into fixtures/,
# scrubbing account numbers, device names, IPs and (in the status) your real city
# and coordinates. Fails if a 16-digit run survives.
# With commands (e.g. "relay get"), captures only those, without the status or the
# relay list, so a settings variant does not rewrite the shared fixtures.
set -euo pipefail

label="${1:?usage: capture-fixtures.sh <label> [command ...]}"
shift
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures"
mkdir -p "$dir"

KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Scrubs account numbers, device names, WireGuard key/dates and IPs.
# `Allowed IPs` lines and 0.0.0.0 are left intact (they are settings, not addresses).
scrub() {
  sed -E "s/[0-9]{16}/0000000000000000/g; s/(Device name:\s+).*/\1Test Device/; s/Expires at:.*/Expires at:         2030-01-01 00:00:00 +00:00/; s/(Public key:\s+)[A-Za-z0-9+\/]{43}=/\1$KEY/; s/Created [0-9-]+ [0-9:]+ [+-][0-9:]+/Created 2030-01-01 00:00:00 +00:00/; s/0\.0\.0\.0/@@ZERO@@/g; /Allowed IPs/!s/([0-9]{1,3}\.){3}[0-9]{1,3}/203.0.113.7/g; s/@@ZERO@@/0.0.0.0/g"
}

# The status's location off the VPN is where you really are: its city and
# coordinates become synthetic values (country kept, so tests can match it). A
# status through a Mullvad exit ("mullvad_exit_ip":true) names the relay, which
# is public, and is kept. `status --json` is one line, so this is per status.
scrub_location() {
  sed -E '/"mullvad_exit_ip":true/!{s/"city":"[^"]*"/"city":"Testville"/g; s/"latitude":-?[0-9.]+/"latitude":44.4/g; s/"longitude":-?[0-9.]+/"longitude":26.1/g}'
}

# Device names on `account list-devices`: first is this device, the rest are numbered.
scrub_devices() {
  awk 'NR==1 {print; next} NR==2 {print "Test Device"; next} NF {print "Other Device " (NR-2); next} {print}'
}

# Refuse to write anything when the daemon is not reachable.
if ! probe="$(mullvad status 2>&1)" && grep -qE 'Failed to connect to mullvad-daemon|Management RPC server or client error' <<<"$probe"; then
  echo "mullvad daemon is not reachable; no fixtures written" >&2
  exit 1
fi

full=1
if [ "$#" -gt 0 ]; then
  full=0
  cmds=("$@")
else
  mullvad status --json | scrub | scrub_location > "$dir/status-$label.json"
  # Only what v1 reads. v2 (DNS, tunnel options, anti-censorship, LAN sharing,
  # split tunneling) adds back "dns get" "tunnel get" "anti-censorship get"
  # "lan get" "split-tunnel list" with the specs that read them.
  cmds=(
    "relay get" "lockdown-mode get" "auto-connect get" "account get"
    "account list-devices" "custom-list list"
  )
fi
for cmd in "${cmds[@]}"; do
  # shellcheck disable=SC2086
  if [ "$cmd" = "account list-devices" ]; then
    { mullvad $cmd 2>&1 || true; } | scrub | scrub_devices > "$dir/${cmd// /-}-$label.txt"
  else
    { mullvad $cmd 2>&1 || true; } | scrub > "$dir/${cmd// /-}-$label.txt"
  fi
done

# Relay list keeps coordinates; only relay IPs are replaced.
if [ "$full" -eq 1 ]; then
  mullvad relay list | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/203.0.113.7/g; s/[0-9]{16}/0000000000000000/g' > "$dir/relay-list.txt"
fi

if grep -rE '[0-9]{16}' "$dir" | grep -vE '(^|[^0-9])0{16}([^0-9]|$)' | grep -q .; then
  echo "scrub check failed: 16-digit run found in fixtures" >&2
  exit 1
fi
echo "captured fixtures for label: $label"
