#!/usr/bin/env bash
# focus.sh PID: bring the terminal running Claude session PID to the front.
# - tmux (TMUX / TMUX_PANE in the session's environment): select the session's pane,
#   then focus the terminal of the most recently active client attached to it.
# - kitty (KITTY_PID / KITTY_WINDOW_ID, with kitty remote control on): jump to the exact
#   tab or split, then focus that kitty OS window.
# - anything else: walk up the process tree to the first process that owns a window.
# Exit 1 when no window could be focused (no client attached, unsupported compositor).
# Derived from claude-sessions' focus.sh (lfdominguez, MIT).
. "$(dirname "$0")/wm.sh"
pid=${1:?usage: focus.sh PID}
[[ "$pid" =~ ^[0-9]+$ ]] || exit 1

envvar() { tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p"; }

# The terminal window hosting process $1.
focus_terminal() {
  local p=$1 kpid wid sock title
  kpid=$(envvar "$p" KITTY_PID); wid=$(envvar "$p" KITTY_WINDOW_ID)
  if [ -n "$kpid" ] && [ -n "$wid" ] && command -v kitty >/dev/null; then
    sock="unix:@kitty-$kpid"
    if kitty @ --to "$sock" focus-window --match "id:$wid" >/dev/null 2>&1; then
      # The OS window's title is its active window's title, which is now ours: it picks
      # the right OS window when one kitty process owns several.
      title=$(kitty @ --to "$sock" ls --match "id:$wid" 2>/dev/null | jq -r '.[0].tabs[0].windows[0].title // empty')
      wm_focus_pid "$kpid" "$title"
      return 0
    fi
  fi
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    wm_focus_pid "$p" && return 0
    # The parent pid follows the last ")": comm (field 2) may itself contain spaces.
    p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2)
  done
  return 1
}

tmux_env=$(envvar "$pid" TMUX); pane=$(envvar "$pid" TMUX_PANE)
if [ -n "$tmux_env" ] && [ -n "$pane" ] && command -v tmux >/dev/null; then
  sock=${tmux_env%%,*}
  t() { tmux -S "$sock" "$@"; }
  session=$(t display-message -p -t "$pane" '#{session_name}' 2>/dev/null) || exit 1
  t select-window -t "$pane" 2>/dev/null; t select-pane -t "$pane" 2>/dev/null
  client=$(t list-clients -t "$session" -F '#{client_activity} #{client_pid}' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2)
  [ -n "$client" ] && focus_terminal "$client" && exit 0
  exit 1
fi

focus_terminal "$pid"
