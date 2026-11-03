# Compositor helpers, sourced by focus.sh and launch.sh. Supports Hyprland (Lua and
# classic dispatch syntax), niri, sway and Umbriel: the compositors whose window list
# carries a pid. Elsewhere (GNOME, KDE, river, labwc, ...) every helper fails and the
# caller falls back. Derived from claude-sessions' wm.sh (lfdominguez, MIT); Umbriel from
# claude-cockpit (nightwatch75, MIT).

# Which compositor this is, decided once when sourced: hyprland, niri, sway, umbriel or "".
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null; then wm_kind=hyprland
elif [ -n "${NIRI_SOCKET:-}" ] && command -v niri >/dev/null; then wm_kind=niri
elif [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null; then wm_kind=sway
elif command -v umbriel >/dev/null && umbriel windows --json >/dev/null 2>&1; then wm_kind=umbriel
else wm_kind=; fi

# Pick from a JSON array of {pid, title, key, recent} candidates: prefer an exact title
# match, then the most recently focused. Prints the key.
_wm_pick() {
  jq -r --arg t "$1" 'sort_by(.recent) | (map(select(.title == $t)) + .) | .[0].key // empty'
}

# wm_load: read every toplevel once into $wm_windows, a JSON array of
# {pid, title, class, key, recent} (lower recent = more recently focused). Call it in the
# shell that uses the result, not inside $(...), or the list is read again every time.
wm_load() {
  [ -n "${wm_windows:-}" ] && return 0
  case $wm_kind in
    hyprland) wm_windows=$(hyprctl clients -j | jq -c 'map({pid, title, class, key: .address, recent: .focusHistoryID})') ;;
    niri) wm_windows=$(niri msg --json windows | jq -c 'map({pid, title, class: (.app_id // ""), key: (.id | tostring),
        recent: (if .is_focused then 0 else 1 end)})') ;;
    sway) wm_windows=$(swaymsg -t get_tree | jq -c '[.. | objects | select(.pid? and (.type == "con" or .type == "floating_con"))
        | {pid, title: (.name // ""), class: (.app_id // .window_properties.class // ""), key: (.id | tostring),
           recent: (if .focused then 0 else 1 end)}]') ;;
    umbriel) wm_windows=$(umbriel windows --json | jq -c 'map(select(.pid != null) | {pid, title: (.title // ""),
        class: (.app_id // .class // ""), key: (.id | tostring), recent: (if (.focused // false) then 0 else 1 end)})') ;;
    *) return 1 ;;
  esac
  [ -n "$wm_windows" ]
}

# wm_focus_key KEY: focus the window wm_windows reported with that key.
wm_focus_key() {
  case $wm_kind in
    # Hyprland >= 0.56 with a Lua config only accepts Lua dispatch syntax; hyprctl exits 0
    # even when a dispatch fails, so success is its "ok" reply.
    hyprland) [ "$(hyprctl dispatch "hl.dsp.focus({ window = \"address:$1\" })" 2>&1)" = ok ] \
      || [ "$(hyprctl dispatch focuswindow "address:$1" 2>&1)" = ok ] ;;
    niri) niri msg action focus-window --id "$1" >/dev/null ;;
    sway) swaymsg "[con_id=$1] focus" >/dev/null ;;
    umbriel) [[ "$1" =~ ^[0-9a-zA-Z_-]+$ ]] && umbriel msg "window-focus:$1" >/dev/null ;;
    *) return 1 ;;
  esac
}

# wm_focus_pid PID [TITLE]: focus a window owned by PID, preferring one titled TITLE.
wm_focus_pid() {
  local key
  wm_load || return 1
  key=$(printf '%s' "$wm_windows" | jq -c --argjson p "$1" 'map(select(.pid == $p))' | _wm_pick "${2:-}")
  [ -n "$key" ] && wm_focus_key "$key"
}

# wm_recent_pids CLASS: pids owning windows whose class contains CLASS, most recently
# focused first.
wm_recent_pids() {
  wm_load || return 1
  printf '%s' "$wm_windows" | jq -r --arg c "$1" 'map(select(.class | ascii_downcase | contains($c))) | sort_by(.recent)
    | reduce .[].pid as $p ([]; if index([$p]) then . else . + [$p] end) | .[]'
}
