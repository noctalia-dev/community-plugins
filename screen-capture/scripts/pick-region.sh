#!/bin/bash

# Pick a capture target and print it on stdout.
#
#   monitor:NAME          a whole monitor, captured natively at its own resolution
#   "X,Y WxH"             a region, in the compositor's logical coordinate space
#
# Exits 1 when the user cancels. Modes:
#
#   region      freeform selection
#   windows     snap to a monitor or window rectangle
#   smart       freeform with rectangles hinted; a bare click snaps to the
#               rectangle it landed in instead of producing a 1px capture
#   fullscreen  the focused monitor, no interaction
#   window      no picker at all: cycle to the window next to the cursor and
#               print its rectangle (next|prev|left|right|up|down)
#
#   --match-monitor    print monitor:NAME when the selection matches a monitor
#   --keep-freeze      leave the screen freeze running, print its pid first
#   --take-fullscreen  dismiss the open picker, take the focused monitor
#   --take-window      dismiss the open picker, take the rectangle under the cursor
#   --cancel           stop the picker this plugin owns, if any
#
# --take-* and --cancel signal only the slurp this plugin started, which is
# tracked through capture-picker-pid and capture-slurp-pid. They never match
# slurp by name, so another tool's selection is left running.
#
# The portal is deliberately not involved: it cannot pick a window on Wayland
# through gpu-screen-recorder, and its dmabuf path fails here anyway.

set -uo pipefail

# SCREEN_CAPTURE_RUNTIME_DIR redirects only this plugin's own state, so tests can
# run somewhere else. XDG_RUNTIME_DIR must not be overridden for that purpose:
# hyprctl derives its socket path from it and loses the compositor connection.
RUNTIME_DIR="${SCREEN_CAPTURE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/screen-capture}"
FULLSCREEN_MARKER="$RUNTIME_DIR/pick-fullscreen"
WINDOW_MARKER="$RUNTIME_DIR/pick-window"
PICKER_PID_FILE="$RUNTIME_DIR/capture-picker-pid"
SLURP_PID_FILE="$RUNTIME_DIR/capture-slurp-pid"
SLURP_OUTPUT="$RUNTIME_DIR/pick-selection"
SLURP_INPUT="$RUNTIME_DIR/pick-rectangles"

# Monitors rotated 90/270 swap their logical width and height.
JQ_MONITOR_GEO='
  def format_geo:
    .x as $x | .y as $y |
    (.width / .scale | floor) as $w |
    (.height / .scale | floor) as $h |
    .transform as $t |
    if ($t % 2) == 1 then
      "\($x),\($y) \($h)x\($w)"
    else
      "\($x),\($y) \($w)x\($h)"
    end;
'

mkdir -p "$RUNTIME_DIR" || exit 1
if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
  chmod 700 "$RUNTIME_DIR" || exit 1
fi

active_workspace() {
  hyprctl monitors -j | jq -r '.[] | select(.focused == true) .activeWorkspace.id'
}

# Windows hidden in the group are excluded, and duplicates are collapsed:
# slurp cannot tell two windows at the same geometry apart, and the duplicate
# would stall the Tab cycle on the first copy.
window_rects() {
  hyprctl clients -j | jq -r --arg ws "$(active_workspace)" \
    '[.[] | select(.workspace.id == ($ws | tonumber) and .hidden != true) | "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"] | unique[]'
}

monitor_rects() {
  hyprctl monitors -j | jq -r --arg ws "$(active_workspace)" "${JQ_MONITOR_GEO} .[] | select(.activeWorkspace.id == (\$ws | tonumber)) | format_geo"
}

get_rectangles() {
  monitor_rects
  window_rects
}

focused_monitor_geo() {
  hyprctl monitors -j | jq -r "${JQ_MONITOR_GEO} .[] | select(.focused == true) | format_geo"
}

# slurp highlights the smallest rectangle containing the point and keeps the
# first on a tie, so overlapping candidates resolve the same way here.
resolve_rect_at() {
  local x=$1 y=$2
  local rect area
  local smallest_area=0

  RESOLVED_RECT=""

  while IFS= read -r rect; do
    [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
    ((x >= BASH_REMATCH[1] && x < BASH_REMATCH[1] + BASH_REMATCH[3] &&
      y >= BASH_REMATCH[2] && y < BASH_REMATCH[2] + BASH_REMATCH[4])) || continue

    area=$((BASH_REMATCH[3] * BASH_REMATCH[4]))
    if [[ -z $RESOLVED_RECT ]] || ((area < smallest_area)); then
      RESOLVED_RECT=$rect
      smallest_area=$area
    fi
  done

  [[ -n $RESOLVED_RECT ]]
}

# Whatever slurp is highlighting under the cursor. Monitors are fed alongside
# windows so a cursor in a gap or over the bar resolves to the monitor rather
# than to nothing.
geo_at_cursor() {
  local pos
  pos=$(hyprctl cursorpos)
  local x=${pos%,*}
  local y=${pos#*, }

  if resolve_rect_at "$x" "$y" < <(window_rects) || resolve_rect_at "$x" "$y" < <(monitor_rects); then
    echo "$RESOLVED_RECT"
  else
    focused_monitor_geo
  fi
}

# ── ownership ─────────────────────────────────────────────────────────────────

# A pid file can outlive its process and the number can be reused, so check what
# is actually running there before signalling it. For a script run through its
# shebang, /proc/<pid>/cmdline starts with the interpreter and then the script.
process_is_picker() {
  local pid=$1 comm="" arg
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  read -r comm <"/proc/$pid/comm" 2>/dev/null || true
  [[ $comm == "pick-region.sh" ]] && return 0
  while IFS= read -r -d '' arg; do
    [[ ${arg##*/} == "pick-region.sh" ]] && return 0
  done <"/proc/$pid/cmdline" 2>/dev/null
  return 1
}

owned_picker_pid() {
  local pid
  [[ -r $PICKER_PID_FILE ]] || return 1
  pid=$(<"$PICKER_PID_FILE")
  process_is_picker "$pid" || return 1
  printf '%s' "$pid"
}

process_ppid() {
  local pid=$1 key value=""
  while read -r key value; do
    if [[ $key == "PPid:" ]]; then
      printf '%s' "$value"
      return 0
    fi
  done <"/proc/$pid/status" 2>/dev/null
  return 1
}

process_is_slurp() {
  local pid=$1 comm="" arg
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  read -r comm <"/proc/$pid/comm" 2>/dev/null || true
  [[ $comm == "slurp" ]] && return 0
  while IFS= read -r -d '' arg; do
    [[ ${arg##*/} == "slurp" ]] && return 0
  done <"/proc/$pid/cmdline" 2>/dev/null
  return 1
}

# slurp is started and waited on directly by this script, so the picker is its
# parent. Checking the parent as well as the name keeps a stale pid file from
# pointing at an unrelated slurp after a crash and a pid reuse.
owned_slurp_pid() {
  local picker pid=""
  picker=$(owned_picker_pid) || return 1
  [[ -r $SLURP_PID_FILE ]] || return 1
  pid=$(<"$SLURP_PID_FILE")
  process_is_slurp "$pid" || return 1
  [[ $(process_ppid "$pid") == "$picker" ]] || return 1
  printf '%s' "$pid"
}

# Remove a pid file only when it still names the process we are releasing, so a
# slower helper cannot delete the file a newer picker just claimed.
release_pid_file() {
  local file=$1 pid=$2
  [[ -r $file && $(<"$file") == "$pid" ]] && rm -f "$file"
  return 0
}

# ── helper modes ──────────────────────────────────────────────────────────────
#
# These run while an interactive picker may already be open. They return before
# the pid files are claimed below, so they never overwrite or remove ownership
# that belongs to the running picker.

# --cancel stops the picker this plugin owns. TERM first: the picker's trap stops
# slurp and the freeze and removes its own files. If it is stuck somewhere the
# trap cannot reach, the recorded slurp is stopped as well.
if [[ ${1:-} == "--cancel" ]]; then
  picker=$(owned_picker_pid) || exit 0
  slurp=$(owned_slurp_pid) || slurp=""
  kill "$picker" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$picker" 2>/dev/null || break
    sleep 0.05
  done
  [[ -n $slurp ]] && kill "$slurp" 2>/dev/null
  if ! kill -0 "$picker" 2>/dev/null; then
    release_pid_file "$PICKER_PID_FILE" "$picker"
    [[ -n $slurp ]] && release_pid_file "$SLURP_PID_FILE" "$slurp"
  fi
  exit 0
fi

# Keyboard control while slurp is open. The helper flags its intent with a marker
# file and stops the owned slurp; slurp then exits with no selection, which is
# how pick() tells "dismissed on purpose" from "cancelled by the user".
take_target() {
  local marker=$1 slurp
  slurp=$(owned_slurp_pid) || return 1
  touch "$marker" || return 1
  if ! kill "$slurp" 2>/dev/null; then
    rm -f "$marker"
    return 1
  fi
}

if [[ ${1:-} == "--take-fullscreen" ]]; then
  take_target "$FULLSCREEN_MARKER" || exit 0
  exit 0
fi

if [[ ${1:-} == "--take-window" ]]; then
  take_target "$WINDOW_MARKER" || exit 0
  exit 0
fi

# Select a window without opening a picker at all.
#
#   pick-region.sh window next|prev|left|right|up|down
#
# Prints the target rectangle directly. This does not move a picker that is
# already open; the --take-* helpers are what act on a running selection.
# "Current" is whichever window the cursor is over, resolved with the same
# smallest-contains rule slurp applies, so navigation and an interactive pick
# never disagree about which window is selected. Reading order is top to bottom,
# then left to right.
if [[ ${1:-} == "window" ]]; then
  direction=${2:-}
  pos=$(hyprctl cursorpos)
  origin_x=${pos%,*}
  origin_y=${pos#*, }

  candidates=$(window_rects)
  [[ -n $candidates ]] || exit 1

  rects=$(while IFS= read -r rect; do
    [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
    printf '%d\t%d\t%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" "$rect"
  done <<<"$candidates" | sort -n -k1,1 -k2,2 | cut -f3-)
  [[ -n $rects ]] || exit 1

  current=""
  resolve_rect_at "$origin_x" "$origin_y" <<<"$candidates" && current=$RESOLVED_RECT

  if [[ $current =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]]; then
    origin_x=$((BASH_REMATCH[1] + BASH_REMATCH[3] / 2))
    origin_y=$((BASH_REMATCH[2] + BASH_REMATCH[4] / 2))
  fi

  target=""

  case $direction in
  next | prev)
    mapfile -t ordered <<<"$rects"
    count=${#ordered[@]}
    current_index=-1

    for i in "${!ordered[@]}"; do
      if [[ -n $current && ${ordered[i]} == "$current" ]]; then
        current_index=$i
        break
      fi
    done

    if [[ $direction == next ]]; then
      target=${ordered[$(((current_index + 1) % count))]}
    elif ((current_index == -1)); then
      target=${ordered[$((count - 1))]}
    else
      target=${ordered[$(((current_index - 1 + count) % count))]}
    fi
    ;;
  left | right | up | down)
    best_score=""

    while IFS= read -r rect; do
      [[ $rect == "$current" ]] && continue
      [[ $rect =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] || continue
      center_x=$((BASH_REMATCH[1] + BASH_REMATCH[3] / 2))
      center_y=$((BASH_REMATCH[2] + BASH_REMATCH[4] / 2))

      case $direction in
      left)  primary=$((origin_x - center_x)); perp=$((center_y - origin_y)) ;;
      right) primary=$((center_x - origin_x)); perp=$((center_y - origin_y)) ;;
      up)    primary=$((origin_y - center_y)); perp=$((center_x - origin_x)) ;;
      down)  primary=$((center_y - origin_y)); perp=$((center_x - origin_x)) ;;
      esac

      ((primary > 0)) || continue
      ((perp < 0)) && perp=$((-perp))
      score=$((primary + perp * 2))

      if [[ -z $best_score ]] || ((score < best_score)); then
        best_score=$score
        target=$rect
      fi
    done <<<"$rects"
    ;;
  *)
    exit 2
    ;;
  esac

  [[ -n $target ]] || exit 1
  echo "$target"
  exit 0
fi

# ── the picker ────────────────────────────────────────────────────────────────

MODE=smart
KEEP_FREEZE=false
MATCH_MONITOR=false

for arg in "$@"; do
  case $arg in
  --keep-freeze) KEEP_FREEZE=true ;;
  --match-monitor) MATCH_MONITOR=true ;;
  *) MODE=$arg ;;
  esac
done

SELECTION=""
SLURP_PID=""
FREEZE_PID=""
RECTANGLES=""

# Runs slurp and stores the selection in SELECTION. slurp is backgrounded so its
# pid can be recorded and waited on: with a command substitution bash blocks in
# waitpid and only runs traps after slurp exits, so a reload would leave slurp
# and the freeze running. Markers are cleared first; a --take-* helper writes one
# and stops slurp, so an empty selection with a marker present is a take.
#
# The rectangle hints go through a file because a background command's stdin is
# /dev/null unless it is redirected explicitly.
pick() {
  rm -f "$FULLSCREEN_MARKER" "$WINDOW_MARKER" "$SLURP_OUTPUT" "$SLURP_INPUT"
  : >"$SLURP_INPUT"
  [[ -n $RECTANGLES ]] && printf '%s\n' "$RECTANGLES" >"$SLURP_INPUT"

  slurp "$@" >"$SLURP_OUTPUT" 2>/dev/null <"$SLURP_INPUT" &
  SLURP_PID=$!
  echo "$SLURP_PID" >"$SLURP_PID_FILE"

  wait "$SLURP_PID" 2>/dev/null
  SLURP_PID=""

  SELECTION=""
  [[ -r $SLURP_OUTPUT ]] && SELECTION=$(<"$SLURP_OUTPUT")
  rm -f "$SLURP_OUTPUT" "$SLURP_INPUT" "$SLURP_PID_FILE"

  if [[ -z $SELECTION && -e $FULLSCREEN_MARKER ]]; then
    rm -f "$FULLSCREEN_MARKER"
    SELECTION=$(focused_monitor_geo)
  elif [[ -z $SELECTION && -e $WINDOW_MARKER ]]; then
    rm -f "$WINDOW_MARKER"
    SELECTION=$(geo_at_cursor)
  fi
}

freeze_screen() {
  hyprpicker -r -z >/dev/null 2>&1 &
  FREEZE_PID=$!
  sleep .1
}

cleanup_freeze() {
  [[ $KEEP_FREEZE == true ]] && return
  [[ -n $FREEZE_PID ]] && kill "$FREEZE_PID" 2>/dev/null
}

# Installed only by the interactive modes, after every helper above has returned,
# so a --take-* or --cancel invocation can never remove a live picker's files.
cleanup_picker() {
  [[ -n $SLURP_PID ]] && kill "$SLURP_PID" 2>/dev/null
  cleanup_freeze
  [[ -n $SLURP_PID ]] && release_pid_file "$SLURP_PID_FILE" "$SLURP_PID"
  release_pid_file "$PICKER_PID_FILE" "$$"
  rm -f "$SLURP_OUTPUT" "$SLURP_INPUT"
}

if [[ $MODE != "fullscreen" ]]; then
  echo $$ >"$PICKER_PID_FILE"
  trap cleanup_picker EXIT
  # `wait` is interruptible, so a reload or disable reaches this trap while
  # slurp is open and stops slurp and the freeze instead of leaving them behind.
  trap 'exit 143' TERM INT
fi

case "$MODE" in
region)
  freeze_screen
  pick
  ;;
windows)
  RECTANGLES=$(get_rectangles)
  freeze_screen
  pick -r
  ;;
fullscreen)
  SELECTION=$(focused_monitor_geo)
  ;;
smart | *)
  RECTANGLES=$(get_rectangles)
  freeze_screen
  pick

  # A bare click (area < 20px^2) snaps to whichever rectangle it landed in, so
  # users don't end up with accidental 2px captures. X and Y can be negative in
  # multi-display layouts.
  if [[ $SELECTION =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]] &&
    ((BASH_REMATCH[3] * BASH_REMATCH[4] < 20)); then
    # resolve_rect_at keeps the smallest containing rectangle, so a click over a
    # window resolves to the window rather than the monitor behind it. The
    # rectangle list is monitors first, and a first-match loop would take the
    # monitor every time.
    if resolve_rect_at "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" <<<"$RECTANGLES"; then
      SELECTION=$RESOLVED_RECT
    fi
  fi
  ;;
esac

[[ $KEEP_FREEZE == true ]] && echo "$FREEZE_PID"

[[ -n $SELECTION ]] || exit 1

# A selection that covers a monitor exactly is better served by a native
# monitor capture: same kms backend, full native resolution, no scaling math.
if [[ $MATCH_MONITOR == true ]]; then
  monitor=$(hyprctl monitors -j | jq -r --arg geo "$SELECTION" \
    "${JQ_MONITOR_GEO} .[] | select(format_geo == \$geo) | .name" | head -1)
  if [[ -n $monitor ]]; then
    echo "monitor:$monitor"
    exit 0
  fi
fi

echo "$SELECTION"
