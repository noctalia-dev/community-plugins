#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this uninstaller with sudo." >&2
  exit 1
fi

service_name="noctalia-gustav0ar-drive-health"

systemctl disable --now "$service_name.timer" 2>/dev/null || true
systemctl stop "$service_name.service" 2>/dev/null || true

rm -f \
  "/etc/systemd/system/$service_name.service" \
  "/etc/systemd/system/$service_name.timer" \
  "/usr/local/libexec/$service_name/collect_raw.sh" \
  "/usr/local/libexec/$service_name/smart-action.sh"
rm -rf "/run/$service_name"

systemctl daemon-reload
systemctl reset-failed "$service_name.service" 2>/dev/null || true

echo "Removed the Noctalia Drive Health system collector."
