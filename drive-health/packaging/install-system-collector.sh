#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this installer with sudo." >&2
  exit 1
fi

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
service_name="noctalia-drive-health"
target_user="${SUDO_USER:-}"
if [[ -z "$target_user" && "${PKEXEC_UID:-}" =~ ^[0-9]+$ ]]; then
  target_user="$(id -un "$PKEXEC_UID" 2>/dev/null || true)"
fi
interval_minutes=15

while (($# > 0)); do
  case "$1" in
    --interval-minutes)
      if (($# < 2)); then
        echo "--interval-minutes requires a value." >&2
        exit 2
      fi
      interval_minutes="$2"
      shift 2
      ;;
    --help)
      echo "usage: $0 [--interval-minutes 1-1440] [desktop-user]"
      exit 0
      ;;
    *)
      if [[ -n "$target_user" ]]; then
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      target_user="$1"
      shift
      ;;
  esac
done

if ! [[ "$interval_minutes" =~ ^[0-9]+$ ]] || ((10#$interval_minutes < 1 || 10#$interval_minutes > 1440)); then
  echo "Interval must be a whole number of minutes from 1 to 1440." >&2
  exit 2
fi

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
install -Dm0755 \
  "$project_dir/packaging/set-collector-interval.sh" \
  "/usr/local/libexec/$service_name/set-collector-interval.sh"
install -Dm0755 \
  "$project_dir/packaging/manage-collector.sh" \
  "/usr/local/libexec/$service_name/manage-collector.sh"
install -Dm0755 \
  "$project_dir/packaging/uninstall-system-collector.sh" \
  "/usr/local/libexec/$service_name/uninstall-collector.sh"
install -Dm0644 \
  "$rendered_service" \
  "/etc/systemd/system/$service_name.service"
install -Dm0644 \
  "$project_dir/packaging/$service_name.timer" \
  "/etc/systemd/system/$service_name.timer"

systemctl daemon-reload
systemctl enable --now "$service_name.timer"
systemctl start "$service_name.service"
/usr/local/libexec/$service_name/set-collector-interval.sh "$interval_minutes"

echo "Installed the read-only SMART collector."
echo "Cache: /run/$service_name/raw.json"
