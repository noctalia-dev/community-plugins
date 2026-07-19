#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this SMART action as root." >&2
  exit 1
fi

action=${1:-}
device=${2:-}
case "$action" in
  short|long) ;;
  *)
    echo "usage: $0 {short|long} DEVICE" >&2
    exit 2
    ;;
esac

case "$device" in
  /dev/nvme[0-9]* )
    [ -c "$device" ] || { echo "Not an NVMe controller: $device" >&2; exit 2; }
    ;;
  /dev/* )
    [ -b "$device" ] || { echo "Not a block device: $device" >&2; exit 2; }
    [ "$(lsblk --nodeps --noheadings --output TYPE "$device" 2>/dev/null | tr -d ' ')" = "disk" ] \
      || { echo "SMART tests require a whole disk: $device" >&2; exit 2; }
    ;;
  *)
    echo "Device must be an absolute /dev path." >&2
    exit 2
    ;;
esac

echo "Starting the $action SMART self-test on $device"
exec smartctl --test="$action" "$device"
