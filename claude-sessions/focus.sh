#!/bin/sh
# focus.sh PID: bring the terminal running Claude session PID to the front.
# - kitty (KITTY_PID / KITTY_WINDOW_ID in the session's environment, and kitty remote control
#   enabled): jump to the exact tab/split, then focus that kitty OS window.
# - any other terminal: walk up the process tree to the first process that owns a window.
. "$(dirname "$0")/wm.sh"
pid=$1
env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || exit 1
kpid=$(printf '%s\n' "$env" | sed -n 's/^KITTY_PID=//p')
wid=$(printf '%s\n' "$env" | sed -n 's/^KITTY_WINDOW_ID=//p')

if [ -n "$kpid" ] && [ -n "$wid" ] && command -v kitty >/dev/null; then
  sock="unix:@kitty-$kpid"
  if kitty @ --to "$sock" focus-window --match "id:$wid" >/dev/null 2>&1; then
    # The OS window's title is its active window's title, which is now ours: use it to pick the
    # right OS window when one kitty process owns several.
    title=$(kitty @ --to "$sock" ls --match "id:$wid" 2>/dev/null | jq -r '.[0].tabs[0].windows[0].title // empty')
    wm_focus_pid "$kpid" "$title"
    exit 0
  fi
fi

p=$pid
while [ -n "$p" ] && [ "$p" -gt 1 ]; do
  wm_focus_pid "$p" && exit 0
  p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
done
exit 1
