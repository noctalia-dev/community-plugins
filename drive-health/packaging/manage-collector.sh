#!/usr/bin/env bash
set -euo pipefail

if (( EUID != 0 )); then
  echo "Run this command through the administrator authorization dialog." >&2
  exit 1
fi

if (($# != 1)) || [[ "$1" != "start" && "$1" != "pause" ]]; then
  echo "usage: $0 {start|pause}" >&2
  exit 2
fi

service_name="noctalia-drive-health"

case "$1" in
  start)
    systemctl daemon-reload
    systemctl enable --now "$service_name.timer"
    systemctl start "$service_name.service"
    echo "Started the Noctalia Drive Health collector."
    ;;
  pause)
    systemctl disable --now "$service_name.timer"
    systemctl stop "$service_name.service"
    echo "Paused the Noctalia Drive Health collector."
    ;;
esac
