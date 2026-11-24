#!/usr/bin/env bash
# usage: apply.sh <vibrance 0-1023> <nvibrant-port-index (0-based), -1 = all ports>
# exit: 0 ok, 3 no usable display, 4 nvibrant failed, 5 niri has no color-matrix support, 6 niri color-matrix command failed
value=${1:-0}
idx=${2:-0}

nv_done=0 ctm_done=0 nv_found=0 ctm_found=0 err=0

for c in /sys/class/drm/card*-*; do
  [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
  # a connector's `device` points at its cardN, which holds the driver link
  card=${c#/sys/class/drm/}; card=${card%%-*}
  drv=$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null)")
  name=${c#/sys/class/drm/card*-}
  if [ "$drv" = nvidia ]; then
    nv_found=1
  else
    ctm_found=1
    ctm_outputs+=("$name")
  fi
done

if [ $nv_found = 1 ]; then
  args=()
  if [ "$idx" -lt 0 ]; then
    # one value per port; nvibrant ignores ports without a display and extra values
    for ((i = 0; i < 16; i++)); do args+=("$value"); done
  else
    for ((i = 0; i < idx; i++)); do args+=(0); done
    args+=("$value")
  fi
  nvibrant "${args[@]}" >/dev/null 2>&1 && nv_done=1 || err=4
fi

if [ $ctm_found = 1 ]; then
  if ! niri msg output --help 2>/dev/null | grep -q color-matrix; then
    [ $nv_done = 1 ] || err=5
  else
    for out in "${ctm_outputs[@]}"; do
      if [ "$value" -le 0 ]; then
        niri msg output "$out" color-matrix reset >/dev/null 2>&1 && ctm_done=1
      else
        # saturation s = 1 + value/1023; M = (1-s)*L + s*I with Rec.709 luma
        m=$(awk -v v="$value" 'BEGIN{
          s = 1 + v/1023; k = 1 - s
          lr = 0.2126; lg = 0.7152; lb = 0.0722
          printf "%.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f",
            k*lr+s, k*lg, k*lb,  k*lr, k*lg+s, k*lb,  k*lr, k*lg, k*lb+s }')
        niri msg output "$out" color-matrix set -- $m >/dev/null 2>&1 && ctm_done=1
      fi
    done
    [ $ctm_done = 1 ] || err=6
  fi
fi

[ $nv_done = 1 ] || [ $ctm_done = 1 ] && exit 0
[ $nv_found = 0 ] && [ $ctm_found = 0 ] && exit 3
exit ${err:-3}
