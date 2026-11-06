#!/bin/bash

# Print one line per webcam that can actually capture video:
#
#   /dev/video0  Integrated_Webcam_HD
#
# Not every /dev/video* node is a camera: the same physical device exposes a
# metadata node and a capture node, and only the capture node lists a Video
# Capture capability.

set -uo pipefail

capture_capable() {
  local device="$1"

  v4l2-ctl --device "$device" --info 2>/dev/null | awk '
    /^[[:space:]]*Device Caps[[:space:]]*:/ { inspect = 1; next }
    inspect && /^[[:space:]]*Video Capture/ { found = 1 }
    END { exit !found }
  '
}

name=""
emitted=0

# v4l2-ctl prints the name on one line and the device path indented on the next.
while IFS= read -r line; do
  if [[ -n $line && $line != [[:space:]]* ]]; then
    name="$line"
    emitted=0
  elif (( ! emitted )); then
    device="${line#"${line%%[![:space:]]*}"}"

    if [[ $device == /dev/video* ]] && capture_capable "$device"; then
      emitted=1
      printf '%s  %s\n' "$device" "$name"
    fi
  fi
done < <(v4l2-ctl --list-devices 2>/dev/null)

exit 0