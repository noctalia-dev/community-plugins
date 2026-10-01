# Compositor helpers, sourced by focus.sh / launch.sh. Supports Hyprland (classic and Lua-config
# dispatch syntax), niri and sway; elsewhere every helper fails and the caller falls back.

# Pick from a JSON array of {pid, title, key, recent} candidates: prefer an exact title match,
# then the most recently focused. Prints the key.
_wm_pick() {
  jq -r --arg t "$1" 'sort_by(.recent) | (map(select(.title == $t)) + .) | .[0].key // empty'
}

# wm_windows: JSON array of {pid, title, class, key, recent} for every toplevel (lower recent = more recent).
wm_windows() {
  if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    hyprctl clients -j | jq -c 'map({pid, title, class, key: .address, recent: .focusHistoryID})'
  elif [ -n "$NIRI_SOCKET" ]; then
    niri msg --json windows | jq -c 'map({pid, title, class: .app_id, key: (.id | tostring),
      recent: (if .is_focused then 0 else 1 end)})'
  elif [ -n "$SWAYSOCK" ]; then
    swaymsg -t get_tree | jq -c '[.. | objects | select(.pid? and (.type == "con" or .type == "floating_con"))
      | {pid, title: .name, class: (.app_id // .window_properties.class // ""), key: (.id | tostring),
         recent: (if .focused then 0 else 1 end)}]'
  else
    return 1
  fi
}

# wm_focus_key KEY: focus the window wm_windows reported with that key.
wm_focus_key() {
  if [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    # Hyprland >= 0.56 with a Lua config only accepts Lua dispatch syntax.
    [ "$(hyprctl dispatch focuswindow "address:$1" 2>&1)" = ok ] \
      || [ "$(hyprctl dispatch "hl.dsp.focus({ window = \"address:$1\" })" 2>&1)" = ok ]
  elif [ -n "$NIRI_SOCKET" ]; then
    niri msg action focus-window --id "$1" >/dev/null
  elif [ -n "$SWAYSOCK" ]; then
    swaymsg "[con_id=$1] focus" >/dev/null
  else
    return 1
  fi
}

# wm_focus_pid PID [TITLE]: focus a window owned by PID, preferring one titled TITLE.
wm_focus_pid() {
  key=$(wm_windows | jq -c --argjson p "$1" 'map(select(.pid == $p))' | _wm_pick "$2")
  [ -n "$key" ] && wm_focus_key "$key"
}

# wm_recent_pids CLASS: pids owning windows whose class contains CLASS, most recently focused first.
wm_recent_pids() {
  wm_windows | jq -r --arg c "$1" 'map(select(.class | ascii_downcase | contains($c))) | sort_by(.recent)
    | reduce .[].pid as $p ([]; if index([$p]) then . else . + [$p] end) | .[]'
}
