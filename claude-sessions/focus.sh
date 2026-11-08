#!/bin/sh
# focus.sh PID: bring the terminal running Claude session PID to the front.
# - kitty outside tmux (KITTY_PID / KITTY_WINDOW_ID in the session's environment, and kitty remote
#   control enabled): jump to the exact tab/split, then focus that kitty OS window.
# - tmux (TMUX / TMUX_PANE in the session's environment): select the session's pane in a tmux
#   client, then focus that client's terminal window (its exact kitty tab if it runs in kitty).
# - any other terminal: walk up the process tree to the first process that owns a window.
. "$(dirname "$0")/wm.sh"

# focus_up PID: focus the window of PID or of its closest ancestor that owns one.
focus_up() {
  p=$1
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    wm_focus_pid "$p" && return 0
    # The parent pid is the second field after the ")" that ends the command name. Counting
    # fields from the start breaks on names with spaces, such as "tmux: server".
    p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2)
  done
  return 1
}

# focus_kitty PID: jump to the kitty tab/split PID runs in, from KITTY_PID / KITTY_WINDOW_ID in its
# environment, then focus that kitty OS window.
focus_kitty() {
  kenv=$(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null) || return 1
  kpid=$(printf '%s\n' "$kenv" | sed -n 's/^KITTY_PID=//p')
  wid=$(printf '%s\n' "$kenv" | sed -n 's/^KITTY_WINDOW_ID=//p')
  [ -n "$kpid" ] && [ -n "$wid" ] && command -v kitty >/dev/null || return 1
  sock="unix:@kitty-$kpid"
  kitty @ --to "$sock" focus-window --match "id:$wid" >/dev/null 2>&1 || return 1
  # The OS window's title is its active window's title, which is now ours: use it to pick the
  # right OS window when one kitty process owns several.
  title=$(kitty @ --to "$sock" ls --match "id:$wid" 2>/dev/null | jq -r '.[0].tabs[0].windows[0].title // empty')
  wm_focus_pid "$kpid" "$title"
  return 0
}

pid=$1
env=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || exit 1
tmux_env=$(printf '%s\n' "$env" | sed -n 's/^TMUX=//p')
pane=$(printf '%s\n' "$env" | sed -n 's/^TMUX_PANE=//p')

# Inside tmux, the session's KITTY_* variables come from whichever kitty window started the tmux
# server, not the one showing the session, so only trust them outside tmux.
[ -z "$tmux_env" ] && focus_kitty "$pid" && exit 0

# The tmux server is not a child of any terminal, so walking up from a session inside tmux never
# finds a window. Walk up from a tmux client instead: preferably one already showing the pane's
# session, otherwise the most recently active one, which is switched to that session.
if [ -n "$tmux_env" ] && [ -n "$pane" ] && command -v tmux >/dev/null; then
  tsock=${tmux_env%%,*}
  tab=$(printf '\t')
  session=$(tmux -S "$tsock" display-message -p -t "$pane" '#{session_name}' 2>/dev/null)
  clients=$(tmux -S "$tsock" list-clients \
    -F "#{client_activity}$tab#{client_pid}$tab#{client_name}$tab#{session_name}" 2>/dev/null | sort -rn)
  client=$(printf '%s\n' "$clients" | awk -F "$tab" -v s="$session" '$4 == s { print; exit }')
  [ -n "$client" ] || client=$(printf '%s\n' "$clients" | head -n 1)
  if [ -n "$session" ] && [ -n "$client" ]; then
    cpid=$(printf '%s\n' "$client" | cut -f2)
    cname=$(printf '%s\n' "$client" | cut -f3)
    tmux -S "$tsock" select-window -t "$pane" \; select-pane -t "$pane" \
      \; switch-client -c "$cname" -t "$pane" >/dev/null 2>&1
    # A client running in kitty carries its own kitty window's KITTY_* variables.
    focus_kitty "$cpid" && exit 0
    focus_up "$cpid" && exit 0
  fi
fi

focus_up "$pid" && exit 0
exit 1
