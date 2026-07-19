#!/bin/sh
set -eu

# Capture raw lsblk and smartctl JSON without interpreting device health. The
# same script is used by the unprivileged plugin fallback and the hardened root
# systemd service, keeping collection behavior identical in both paths.

LC_ALL=C
export LC_ALL

collector_version="2.0.0"
generated_at_epoch=$(date +%s)
collection_id=""
if [ -r /proc/sys/kernel/random/uuid ]; then
  IFS= read -r collection_id </proc/sys/kernel/random/uuid || collection_id=""
fi
if [ -z "$collection_id" ]; then
  uptime_field=""
  if [ -r /proc/uptime ]; then
    IFS=' ' read -r uptime_field _ </proc/uptime || uptime_field=""
  fi
  collection_id="${generated_at_epoch}-$$-${uptime_field:-unknown}"
fi

output=""
if [ "${1:-}" = "--output" ]; then
  if [ "$#" -ne 2 ] || [ -z "$2" ]; then
    echo "usage: $0 [--output PATH]" >&2
    exit 2
  fi
  output=$2
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--output PATH]" >&2
  exit 2
fi

if ! command -v lsblk >/dev/null 2>&1; then
  echo "collect_raw: lsblk is required" >&2
  exit 1
fi

if [ -n "$output" ]; then
  output_dir=$(dirname -- "$output")
  mkdir -p -- "$output_dir"
  payload_tmp=$(mktemp "$output_dir/.raw.json.XXXXXX")
else
  payload_tmp=$(mktemp "${TMPDIR:-/tmp}/noctalia-smart-raw.XXXXXX")
fi
devices_tmp=$(mktemp "${TMPDIR:-/tmp}/noctalia-smart-devices.XXXXXX")
smart_tmp=$(mktemp "${TMPDIR:-/tmp}/noctalia-smart-device.XXXXXX")

cleanup() {
  rm -f -- "$payload_tmp" "$devices_tmp" "$smart_tmp"
}
trap cleanup EXIT HUP INT TERM

lsblk --nodeps --noheadings --paths --output PATH,TYPE,ROTA >"$devices_tmp"

{
  printf '{"schema":2,"collector_version":"%s","collection_id":"%s","generated_at_epoch":%s,"lsblk":' \
    "$collector_version" "$collection_id" "$generated_at_epoch"
  lsblk --json --bytes --output \
    NAME,KNAME,PATH,PKNAME,TYPE,TRAN,ROTA,RM,HOTPLUG,SIZE,LOG-SEC,PHY-SEC,MODEL,SERIAL,FSTYPE,FSSIZE,FSUSED,FSAVAIL,MOUNTPOINTS
  printf ',"smart":['

  first=true
  if command -v smartctl >/dev/null 2>&1; then
    while read -r device device_type rotational; do
      [ "$device_type" = "disk" ] || continue
      case "$device" in
        /dev/loop*|/dev/ram*|/dev/sr*|/dev/zram*) continue ;;
      esac

      smart_device=$device
      nvme_controller=$(printf '%s\n' "$device" | sed -n 's#^\(/dev/nvme[0-9][0-9]*\)n[0-9][0-9]*$#\1#p')
      if [ -n "$nvme_controller" ]; then
        smart_device=$nvme_controller
      fi

      : >"$smart_tmp"
      if [ "$rotational" = "1" ]; then
        if smartctl --json=c --all --nocheck=standby,0 "$smart_device" >"$smart_tmp" 2>/dev/null; then
          smart_exit=0
        else
          smart_exit=$?
        fi
      else
        if smartctl --json=c --all "$smart_device" >"$smart_tmp" 2>/dev/null; then
          smart_exit=0
        else
          smart_exit=$?
        fi
      fi

      if [ "$first" = true ]; then
        first=false
      else
        printf ','
      fi
      printf '{"requested_device":"%s","exit_code":%s,"payload":' "$smart_device" "$smart_exit"
      if [ -s "$smart_tmp" ]; then
        cat "$smart_tmp"
      else
        printf '{"smartctl":{"exit_status":%s,"messages":[{"severity":"error","string":"smartctl produced no JSON output"}]}}' "$smart_exit"
      fi
      printf '}'
    done <"$devices_tmp"
  fi

  printf ']}\n'
} >"$payload_tmp"

chmod 0640 "$payload_tmp"
if [ -n "$output" ]; then
  mv -f -- "$payload_tmp" "$output"
else
  cat "$payload_tmp"
fi
