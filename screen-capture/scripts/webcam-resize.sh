#!/bin/bash

# Size and position the webcam overlay for the current recording.
#
#   smaller | larger | reset | small | medium | large
#
# The overlay anchors to the region being recorded, not to the monitor, so a
# window capture keeps the camera inside its own frame instead of drifting off
# to a corner of a screen that is not in the file.

set -uo pipefail

readonly MARGIN=40

# Has to resolve to whatever record.sh writes; without a region the camera
# anchors to the whole monitor, which is the right fallback for a monitor or
# full-screen capture.
RUNTIME_DIR="${SCREEN_CAPTURE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/screen-capture}"
readonly REGION_FILE="$RUNTIME_DIR/capture-region"

# Hyprland 0.56 is the Lua branch: dispatchers are hl.dsp.window.<name> and the
# classic "hyprctl dispatch pin" form is gone. Try the Lua form first and fall
# back to the classic one so the script also runs on an older Hyprland.
hypr_dispatch() {
  local lua="$1"
  shift

  hyprctl dispatch "$lua" >/dev/null 2>&1 || hyprctl dispatch "$@" >/dev/null
}

action=${1:-}
case $action in
smaller | larger | reset | small | medium | large) ;;
*)
  echo "usage: $(basename "$0") <smaller|larger|reset|small|medium|large>" >&2
  exit 1
  ;;
esac

if ! client=$(hyprctl clients -j 2>/dev/null |
  jq -cer 'first(.[] | select(.title == "WebcamOverlay")) // empty' 2>/dev/null); then
  exit 0
fi

address="" current_width=0 current_height=0 monitor_id="" is_floating="" is_pinned=""
read -r address current_width current_height monitor_id is_floating is_pinned < <(
  jq -r '[.address, .size[0], .size[1], .monitor, .floating, .pinned] | @tsv' <<<"$client"
)

[[ -n $address && $current_width =~ ^[0-9]+$ && $current_height =~ ^[0-9]+$ &&
  $monitor_id =~ ^[0-9]+$ ]] || exit 0
((current_width > 0 && current_height > 0)) || exit 0

if ! monitor=$(hyprctl monitors -j 2>/dev/null |
  jq -cer --argjson id "$monitor_id" 'first(.[] | select(.id == $id)) // empty' 2>/dev/null); then
  exit 0
fi

read -r monitor_x monitor_y monitor_width monitor_height < <(
  jq -r '
    . as $monitor |
    (($monitor.transform // 0) % 2 == 1) as $rotated |
    [
      .x,
      .y,
      (((if $rotated then .height else .width end) / .scale) | floor),
      (((if $rotated then .width else .height end) / .scale) | floor)
    ] | @tsv
  ' <<<"$monitor"
)

[[ $monitor_x =~ ^-?[0-9]+$ && $monitor_y =~ ^-?[0-9]+$ &&
  $monitor_width =~ ^[0-9]+$ && $monitor_height =~ ^[0-9]+$ ]] || exit 0

anchor_x=$monitor_x
anchor_y=$monitor_y
anchor_width=$monitor_width
anchor_height=$monitor_height

if [[ -f $REGION_FILE ]] && region=$(<"$REGION_FILE"); then
  if [[ $region =~ ^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$ ]]; then
    anchor_width=${BASH_REMATCH[1]}
    anchor_height=${BASH_REMATCH[2]}
    anchor_x=${BASH_REMATCH[3]}
    anchor_y=${BASH_REMATCH[4]}
  fi
fi

# The overlay has to stay inside the region even when the region is small: a
# fixed margin does not fit a 60px-wide capture, so shrink it before sizing.
margin=$MARGIN
((anchor_width / 4 < margin)) && margin=$((anchor_width / 4))
((anchor_height / 4 < margin)) && margin=$((anchor_height / 4))
((margin < 1)) && margin=1

# A tall, narrow region cannot fit presets scaled from its own height, so cap
# the height they scale from to what the width allows. The large preset is the
# widest at 3/10 of it; scaling the whole ladder keeps small, medium and large
# distinct sizes for smaller/larger to step between.
scale_height=$anchor_height
available_width=$((anchor_width - 2 * margin))
if ((available_width <= 0)); then
  available_width=$((anchor_width / 3))
  ((available_width < 1)) && available_width=1
fi
((scale_height * 3 / 10 > available_width)) &&
  scale_height=$((available_width * 10 / 3))

# 8:9 portrait presets scaled from that height.
small_height=$(((scale_height * 9 + 25) / 50))
small_width=$(((small_height * 8 + 4) / 9))
medium_height=$(((scale_height + 2) / 4))
medium_width=$(((medium_height * 8 + 4) / 9))
large_height=$(((scale_height * 27 + 40) / 80))
large_width=$(((large_height * 8 + 4) / 9))

target_width=$current_width
target_height=$current_height
case $action in
small)
  target_width=$small_width
  target_height=$small_height
  ;;
medium | reset)
  target_width=$medium_width
  target_height=$medium_height
  ;;
large)
  target_width=$large_width
  target_height=$large_height
  ;;
smaller)
  if ((large_width < current_width)); then
    target_width=$large_width
    target_height=$large_height
  elif ((medium_width < current_width)); then
    target_width=$medium_width
    target_height=$medium_height
  elif ((small_width < current_width)); then
    target_width=$small_width
    target_height=$small_height
  fi
  ;;
larger)
  if ((small_width > current_width)); then
    target_width=$small_width
    target_height=$small_height
  elif ((medium_width > current_width)); then
    target_width=$medium_width
    target_height=$medium_height
  elif ((large_width > current_width)); then
    target_width=$large_width
    target_height=$large_height
  fi
  ;;
esac

target_x=$((anchor_x + anchor_width - target_width - margin))
target_y=$((anchor_y + anchor_height - target_height - margin))

((target_x < anchor_x + margin)) && target_x=$((anchor_x + margin))
((target_y < anchor_y + margin)) && target_y=$((anchor_y + margin))

window="address:$address"

# float and pin are dispatched rather than declared as Hyprland window rules so
# the plugin stays self-contained.
#
# Order matters. A tiled window's geometry belongs to the layout, so resize and
# move against one are silently dropped and Hyprland keeps its own size: the
# overlay has to leave the layout before it can be placed, or it ends up at its
# natural video size instead of the preset.
#
# The float dispatch is guarded by the window's actual state: the fallback is
# togglefloating, which flips rather than sets, so running it on a window that
# is already floating would put it back into the layout.
if [[ $is_floating != true ]]; then
  hyprctl dispatch "hl.dsp.window.float({ window = \"$window\" })" >/dev/null 2>&1 ||
    hyprctl dispatch togglefloating "$window" >/dev/null 2>&1
fi

hypr_dispatch \
  "hl.dsp.window.resize({ window = \"$window\", x = $target_width, y = $target_height })" \
  resizewindowpixel "exact $target_width $target_height,$window"
hypr_dispatch \
  "hl.dsp.window.move({ window = \"$window\", x = $target_x, y = $target_y })" \
  movewindowpixel "exact $target_x $target_y,$window"

# The classic fallback is a toggle, so re-pinning an already-pinned window would
# unpin it. The Lua form sets the state, but guard both for the same reason.
if [[ $is_pinned != true ]]; then
  hyprctl dispatch "hl.dsp.window.pin({ window = \"$window\" })" >/dev/null 2>&1 ||
    hyprctl dispatch pin "$window" >/dev/null 2>&1
fi
