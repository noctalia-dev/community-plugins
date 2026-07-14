#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this command with sudo." >&2
  exit 1
fi

if (($# != 1)) || ! [[ "$1" =~ ^[0-9]+$ ]] || ((10#$1 < 1 || 10#$1 > 1440)); then
  echo "usage: $0 MINUTES (1-1440)" >&2
  exit 2
fi

service_name="noctalia-drive-health"
interval_minutes=$((10#$1))
dropin_dir="/etc/systemd/system/$service_name.timer.d"
dropin_path="$dropin_dir/interval.conf"
temporary=$(mktemp)
trap 'rm -f -- "$temporary"' EXIT

printf '[Timer]\nOnUnitActiveSec=\nOnUnitActiveSec=%smin\n' "$interval_minutes" >"$temporary"
install -d -m0755 "$dropin_dir"
install -m0644 "$temporary" "$dropin_path"

systemctl daemon-reload
systemctl restart "$service_name.timer"
systemctl start "$service_name.service"

echo "Noctalia full SMART refresh interval set to $interval_minutes minute(s)."
