#!/usr/bin/env bash
# usage: apply.sh <vibrance 0-1023>   (applied to every connected display)
# exit: 0 every found backend applied, 3 no usable display, 4 nvibrant failed, 5 niri has no color-matrix support,
#       6 niri color-matrix failed on every output, 7 some backends or outputs applied and some did not
value=${1:-0}

nv_done=0 ctm_done=0 nv_found=0 ctm_found=0 ctm_failed=0 err=0

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
  # One value per port; nvibrant ignores ports without a display and extra values. A single port cannot be set
  # alone: nvibrant takes positional values and resets every port it is not given, so the level goes to all.
  args=()
  for ((i = 0; i < 16; i++)); do args+=("$value"); done
  if nvibrant "${args[@]}" >/dev/null 2>&1; then nv_done=1; else err=4; fi
fi

if [ $ctm_found = 1 ]; then
  if ! niri msg output --help 2>/dev/null | grep -q color-matrix; then
    # niri cannot take the change on its outputs: a clean NVIDIA result is then only a partial one
    if [ $nv_done = 1 ]; then err=7; else err=5; fi
  else
    for out in "${ctm_outputs[@]}"; do
      if [ "$value" -le 0 ]; then
        if niri msg output "$out" color-matrix reset >/dev/null 2>&1; then ctm_done=1; else ctm_failed=1; fi
      else
        # saturation s = 1 + value/1023; M = (1-s)*L + s*I with Rec.709 luma
        m=$(awk -v v="$value" 'BEGIN{
          s = 1 + v/1023; k = 1 - s
          lr = 0.2126; lg = 0.7152; lb = 0.0722
          printf "%.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f",
            k*lr+s, k*lg, k*lb,  k*lr, k*lg+s, k*lb,  k*lr, k*lg, k*lb+s }')
        if niri msg output "$out" color-matrix set -- $m >/dev/null 2>&1; then ctm_done=1; else ctm_failed=1; fi
      fi
    done
    if [ $ctm_done = 0 ]; then err=6; elif [ $ctm_failed = 1 ]; then err=7; fi
  fi
fi

if [ $nv_found = 0 ] && [ $ctm_found = 0 ]; then exit 3; fi
# every backend that was found has to succeed for a clean 0; a partial result is reported as 7
if [ $nv_found = 1 ] && [ $nv_done = 0 ]; then exit ${err:-4}; fi
if [ $ctm_found = 1 ] && [ $ctm_done = 0 ]; then
  if [ $nv_done = 1 ]; then exit 7; fi   # NVIDIA took the change, niri did not: partial
  exit ${err:-6}
fi
if [ "${err:-0}" = 7 ] || [ $ctm_failed = 1 ]; then exit 7; fi
exit 0
