#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this installer with sudo." >&2
  exit 1
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
service_name="noctalia-gustav0ar-drive-health"
target_user="${SUDO_USER:-${1:-}}"

if [[ -z "$target_user" || "$target_user" == root ]] || ! id "$target_user" >/dev/null 2>&1; then
  echo "Unable to determine the desktop user. Run with sudo, or pass the username explicitly." >&2
  exit 1
fi
target_gid="$(id -g "$target_user")"

for dependency in sh smartctl lsblk systemctl install sed mktemp id; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    echo "Missing required command: $dependency" >&2
    exit 1
  fi
done

rendered_service="$(mktemp)"
trap 'rm -f -- "$rendered_service"' EXIT
sed "s/@TARGET_GID@/$target_gid/g" \
  "$project_dir/packaging/$service_name.service.in" >"$rendered_service"

install -Dm0755 \
  "$project_dir/scripts/collect_raw.sh" \
  "/usr/local/libexec/$service_name/collect_raw.sh"
install -Dm0755 \
  "$project_dir/packaging/smart-action.sh" \
  "/usr/local/libexec/$service_name/smart-action.sh"
install -Dm0644 \
  "$rendered_service" \
  "/etc/systemd/system/$service_name.service"
install -Dm0644 \
  "$project_dir/packaging/$service_name.timer" \
  "/etc/systemd/system/$service_name.timer"

systemctl daemon-reload
systemctl enable --now "$service_name.timer"
systemctl start "$service_name.service"

# Remove files from releases before 1.2.0 only after the replacement service
# has completed successfully.
systemctl disable --now noctalia-smart-monitor.timer 2>/dev/null || true
systemctl stop noctalia-smart-monitor.service 2>/dev/null || true
rm -f \
  /etc/systemd/system/noctalia-smart-monitor.service \
  /etc/systemd/system/noctalia-smart-monitor.timer \
  /usr/local/libexec/noctalia-smart-monitor/collect_raw.sh \
  /usr/local/libexec/noctalia-smart-monitor/smart-action.sh \
  /usr/local/libexec/noctalia-smart-monitor/collect_smart.py

echo "Installed the read-only SMART collector."
echo "Cache: /run/$service_name/raw.json"
