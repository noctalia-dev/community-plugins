#!/bin/bash

# Start, stop or inspect a screen recording.
#
#   record.sh start [options]     begin recording (runs the picker if no target)
#   record.sh stop                finalize what is recording
#   record.sh status              print the current state, never blocks
#
# On success start/stop print "file=<path>" when a file exists. All progress and
# failures go to the log, never to stdout, so the caller can parse the result.
#
# The portal is not an option. gpu-screen-recorder's portal backend needs dmabuf
# EGL import, which fails here (PipeWire "alloc buffers: Invalid argument") and
# is off by default upstream for the same reason. A target is either a monitor,
# captured natively, or a region, selected with slurp.
#
# Start and stop serialize on a lock. A toggle that arrives while a picker is
# still open cancels that start instead of queueing behind it, because the user
# asked to toggle, not to queue.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PICK_SCRIPT="$SCRIPT_DIR/pick-region.sh"
readonly WEBCAM_LIST_SCRIPT="$SCRIPT_DIR/webcam-list.sh"
readonly WEBCAM_RESIZE_SCRIPT="$SCRIPT_DIR/webcam-resize.sh"

OUTPUT_DIR="${SCREEN_CAPTURE_DIR:-$HOME/Videos/Recordings}"
FILENAME_PATTERN="capture_%Y-%m-%d_%H-%M-%S"
AUDIO_SOURCE="both"
FRAME_RATE=60
FRAMERATE_MODE="cfr"
# Named preset, not a numeric QP: gpu-screen-recorder's -q only accepts a number
# in CBR mode, and the bitrate mode here defaults to QP.
QUALITY="high"
SHOW_CURSOR=true
NORMALIZE_AUDIO=true
# Whether the caller passed --normalize on this invocation. `stop` runs in its
# own process, so the run's choice is persisted to NORMALIZE_FILE and only an
# explicit flag overrides it.
NORMALIZE_EXPLICIT=false
WEBCAM="off"
WEBCAM_DEVICE=""
TARGET=""
RESOLUTION=""

# The runtime directory is per-user and 0700. What RECORDING_FILE holds is read
# back on stop and used as a path: ffmpeg writes beside it, mv replaces it, and
# rm deletes it on a failed start. A fixed name in world-writable /tmp would be a name
# any other local account could create first and point wherever it likes.
#
# SCREEN_CAPTURE_RUNTIME_DIR redirects only this plugin's own state, so tests can
# run somewhere else. XDG_RUNTIME_DIR must not be overridden for that purpose:
# hyprctl derives its socket path from it and loses the compositor connection.
RUNTIME_DIR="${SCREEN_CAPTURE_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}/screen-capture}"
RECORDING_FILE="$RUNTIME_DIR/capture-filename"
REGION_FILE="$RUNTIME_DIR/capture-region"
REC_PID_FILE="$RUNTIME_DIR/capture-pid"
WEBCAM_PID_FILE="$RUNTIME_DIR/capture-webcam-pid"
STARTING_FILE="$RUNTIME_DIR/capture-starting"
CANCEL_FILE="$RUNTIME_DIR/capture-cancel"
NORMALIZE_FILE="$RUNTIME_DIR/capture-normalize"

# How long a recorder may take to create its file. The picker is not counted:
# it waits on the user.
READY_TIMEOUT_TICKS=75
READY_TICK=0.2

LOG_FILE="${SCREEN_CAPTURE_LOG:-$RUNTIME_DIR/record.log}"

mkdir -p "$RUNTIME_DIR" || exit 1
if [[ -z ${XDG_RUNTIME_DIR:-} ]]; then
  chmod 700 "$RUNTIME_DIR" || exit 1
fi

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; }

# ── argument parsing ──────────────────────────────────────────────────────────

ACTION="${1:-status}"
[[ $# -gt 0 ]] && shift

for arg in "$@"; do
  case $arg in
  --directory=*) OUTPUT_DIR="${arg#*=}" ;;
  --filename-pattern=*) FILENAME_PATTERN="${arg#*=}" ;;
  --audio=*) AUDIO_SOURCE="${arg#*=}" ;;
  --frame-rate=*) FRAME_RATE="${arg#*=}" ;;
  --framerate-mode=*) FRAMERATE_MODE="${arg#*=}" ;;
  --quality=*) QUALITY="${arg#*=}" ;;
  --cursor=yes) SHOW_CURSOR=true ;;
  --cursor=no) SHOW_CURSOR=false ;;
  --normalize=yes) NORMALIZE_AUDIO=true; NORMALIZE_EXPLICIT=true ;;
  --normalize=no) NORMALIZE_AUDIO=false; NORMALIZE_EXPLICIT=true ;;
  --webcam=*) WEBCAM="${arg#*=}" ;;
  --webcam-device=*) WEBCAM_DEVICE="${arg#*=}" ;;
  --target=*) TARGET="${arg#*=}" ;;
  --resolution=*) RESOLUTION="${arg#*=}" ;;
  *)
    echo "unknown option: $arg" >&2
    exit 2
    ;;
  esac
done

case $WEBCAM in
off | small | medium | large) ;;
*)
  echo "invalid --webcam: $WEBCAM" >&2
  exit 2
  ;;
esac

case $QUALITY in
medium | high | very_high | ultra) ;;
*)
  echo "invalid --quality: $QUALITY (expected medium, high, very_high or ultra)" >&2
  exit 2
  ;;
esac

# `stop` runs in its own process; restore the choice the run started with unless
# the caller passed an explicit --normalize on this invocation.
if [[ $ACTION == "stop" && $NORMALIZE_EXPLICIT == false && -r $NORMALIZE_FILE ]]; then
  [[ $(<"$NORMALIZE_FILE") == "no" ]] && NORMALIZE_AUDIO=false
fi

# ── helpers ───────────────────────────────────────────────────────────────────

# gpu-screen-recorder runs under a 15-character comm name, and any executable
# sharing that prefix would match a plain pgrep. Compare the exe path instead.
recorder_pid_alive() {
  local pid="$1" exe
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
  # Linux appends this when an upgrade unlinks a running executable.
  exe=${exe% (deleted)}
  exe=${exe##*/}
  [[ $exe == "gpu-screen-recorder" || $exe == "wf-recorder" ]]
}

# The focused monitor at its own resolution, or 4K when the monitor is larger,
# so a 5K or 6K panel does not ask the encoder for more than it can hold.
default_resolution() {
  local width=0 height=0
  read -r width height < <(hyprctl monitors -j |
    jq -r '.[] | select(.focused == true) | "\(.width) \(.height)"')
  if ((width > 3840 || height > 2160)); then
    echo "3840x2160"
  else
    echo "0x0"
  fi
}

# ── webcam overlay ────────────────────────────────────────────────────────────

start_webcam_overlay() {
  local target="${1:-}"

  cleanup_webcam

  if [[ -z $WEBCAM_DEVICE ]]; then
    WEBCAM_DEVICE=$("$WEBCAM_LIST_SCRIPT" | sed -n '1s/[[:space:]].*//p')
  fi
  if [[ -z $WEBCAM_DEVICE ]]; then
    log "no webcam found"
    return 1
  fi

  # Prefer the highest 16:9 resolution the device actually offers.
  local preferred=("1280x720" "640x360")
  local capture_options="framerate=30"
  local available
  available=$(v4l2-ctl --list-formats-ext -d "$WEBCAM_DEVICE" 2>/dev/null)

  local resolution
  for resolution in "${preferred[@]}"; do
    if echo "$available" | grep -q "$resolution"; then
      capture_options="video_size=$resolution,$capture_options"
      break
    fi
  done

  # 8:9 portrait crop: the sensor is 16:9, a talking-head bubble is not.
  mpv "av://v4l2:$WEBCAM_DEVICE" \
    --profile=low-latency --untimed --no-cache \
    --demuxer-lavf-o="$capture_options" \
    '--vf=lavfi=[crop=ih*8/9:ih]' \
    --title="WebcamOverlay" --wayland-app-id="WebcamOverlay-$WEBCAM" \
    --no-border --no-audio --no-osc --osd-level=0 \
    --really-quiet 9>&- &>/dev/null &

  # Recorded by pid, never matched by name: pkill -f matches any command line
  # that merely mentions the title, which includes the shell that invoked this
  # script and the Noctalia process that started it.
  echo $! >"$WEBCAM_PID_FILE"

  # The move has to settle before the recorder starts, or the camera is recorded
  # sliding into its corner. Wait for the map rather than guessing a delay.
  local waited=0
  while ((waited < 60)) &&
    ! hyprctl clients -j | jq -e 'any(.[]; .title == "WebcamOverlay")' >/dev/null 2>&1; do
    sleep 0.05
    ((waited++))
  done

  [[ $target == region:* ]] && echo "${target#region:}" >"$REGION_FILE"

  "$WEBCAM_RESIZE_SCRIPT" "$WEBCAM" >>"$LOG_FILE" 2>&1

  sleep 0.6
}

cleanup_webcam() {
  local pid exe
  if [[ -f $WEBCAM_PID_FILE ]]; then
    pid=$(<"$WEBCAM_PID_FILE")
    if [[ $pid =~ ^[0-9]+$ ]]; then
      # Re-check the executable: the pid can be reused between the overlay
      # dying and this cleanup running.
      exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=""
      [[ ${exe##*/} == "mpv" ]] && kill "$pid" 2>/dev/null
    fi
    rm -f "$WEBCAM_PID_FILE"
  fi

  # mpv can outlive the pid we saved, and a window left behind stays visible in
  # every later recording. Matching on the window title reaches only the
  # overlay, unlike a process-name match.
  if hyprctl clients -j 2>/dev/null | jq -e 'any(.[]; .title == "WebcamOverlay")' >/dev/null 2>&1; then
    hyprctl dispatch "hl.dsp.window.close({ window = \"title:WebcamOverlay\" })" >/dev/null 2>&1 ||
      hyprctl dispatch closewindow "title:WebcamOverlay" >/dev/null 2>&1
  fi

  rm -f "$REGION_FILE"
  return 0
}

# ── recording ─────────────────────────────────────────────────────────────────

start_recording() {
  local capture_args=()

  if [[ -z $TARGET ]]; then
    TARGET=$("$PICK_SCRIPT" smart --match-monitor) || return 1
    start_cancelled && return 1
  fi

  # pick-region.sh prints "X,Y WxH" for a rectangle; accept that form directly
  # so the standalone `record.sh start` path does not need the caller to convert.
  if [[ $TARGET =~ ^(-?[0-9]+),(-?[0-9]+)[[:space:]]([0-9]+)x([0-9]+)$ ]]; then
    TARGET="region:${BASH_REMATCH[3]}x${BASH_REMATCH[4]}+${BASH_REMATCH[1]}+${BASH_REMATCH[2]}"
  fi

  log "target: $TARGET"

  case $TARGET in
  monitor:*)
    capture_args=(-w "${TARGET#monitor:}" -s "${RESOLUTION:-$(default_resolution)}")
    ;;
  region:*)
    # region:WxH+X+Y, in the logical coordinate space slurp returns.
    [[ ${TARGET#region:} =~ ^([0-9]+)x([0-9]+)\+(-?[0-9]+)\+(-?[0-9]+)$ ]] || return 1
    capture_args=(-w "${BASH_REMATCH[1]}x${BASH_REMATCH[2]}+${BASH_REMATCH[3]}+${BASH_REMATCH[4]}")
    [[ -n $RESOLUTION ]] && capture_args+=(-s "$RESOLUTION")
    ;;
  *)
    log "unusable target: $TARGET"
    return 1
    ;;
  esac

  if [[ $WEBCAM != off ]]; then
    start_webcam_overlay "$TARGET" || log "webcam overlay unavailable, continuing without it"
    start_cancelled && return 1
  fi

  mkdir -p "$OUTPUT_DIR" || {
    cleanup_webcam
    log "cannot create $OUTPUT_DIR"
    return 1
  }

  # A custom pattern may omit seconds, so two runs can land on the same name and
  # gpu-screen-recorder would overwrite the earlier file. Suffix until it is
  # free; after this the failure paths below can safely rm what they created.
  local filename base suffix=0
  base="$OUTPUT_DIR/$(date +"$FILENAME_PATTERN")"
  filename="$base.mp4"
  while [[ -e $filename ]]; do
    ((suffix++))
    filename="$base-$suffix.mp4"
  done

  local audio_devices="" audio_args=()
  [[ $AUDIO_SOURCE == "default_output" || $AUDIO_SOURCE == "both" ]] &&
    audio_devices+="default_output"
  if [[ $AUDIO_SOURCE == "default_input" || $AUDIO_SOURCE == "both" ]]; then
    # Merged into one track: separate tracks play one at a time in most players.
    [[ -n $audio_devices ]] && audio_devices+="|"
    audio_devices+="default_input"
  fi
  # Opus, not AAC: gsr 6.1.x's AAC path feeds the mp4 muxer two frames with the
  # same dts ("non monotonically increasing dts ... stream 1") and then fails to
  # write frame index 1. The first frames land in the region finalize mutes, so
  # it is inaudible, but the error is real. Opus shows no such warning.
  # finalize_recording re-encodes the audio to AAC (ffmpeg's default for mp4) no
  # matter which intermediate codec was used, so the delivered file stays AAC.
  [[ -n $audio_devices ]] && audio_args+=(-a "$audio_devices" -ac opus)

  local cursor_flag=no
  [[ $SHOW_CURSOR == true ]] && cursor_flag=yes

  rm -f "$REC_PID_FILE"

  log "exec: gpu-screen-recorder ${capture_args[*]} -k auto -f $FRAME_RATE -fm $FRAMERATE_MODE -q $QUALITY -cursor $cursor_flag ${audio_args[*]} -o $filename"

  # -fallback-cpu-encoding keeps a codec the iGPU cannot do from failing the
  # whole recording; on this GPU only H.264 and HEVC encode in hardware.
  gpu-screen-recorder "${capture_args[@]}" \
    -k auto -f "$FRAME_RATE" -fm "$FRAMERATE_MODE" -q "$QUALITY" \
    -cursor "$cursor_flag" -cr limited -fallback-cpu-encoding yes \
    "${audio_args[@]}" -o "$filename" 9>&- >>"$LOG_FILE" 2>&1 &

  local pid=$!

  local ticks=0
  while kill -0 $pid 2>/dev/null && [[ ! -f $filename ]]; do
    start_cancelled && break
    ((ticks++ > READY_TIMEOUT_TICKS)) && break
    sleep "$READY_TICK"
  done

  if start_cancelled; then
    end_recorder "$pid"
    rm -f "$filename"
    cleanup_webcam
    return 1
  fi

  if ! recorder_pid_alive "$pid"; then
    log "recorder exited before the file appeared"
    rm -f "$filename"
    cleanup_webcam
    return 1
  fi

  # The file may not exist yet if the timeout hit before it did; either way the
  # recorder is alive, so the recording is real and the name is worth saving.
  echo "$pid" >"$REC_PID_FILE"
  echo "$filename" >"$RECORDING_FILE"
  # Persist the run's audio choice for the separate `stop` process.
  if [[ $NORMALIZE_AUDIO == true ]]; then
    echo yes >"$NORMALIZE_FILE"
  else
    echo no >"$NORMALIZE_FILE"
  fi
  return 0
}

# SIGINT first: it finalizes the MP4 so the file is playable. KILL only as an
# escape hatch once the recorder has had time to close the container.
end_recorder() {
  local pid="$1" waited=0 state
  kill -INT "$pid" 2>/dev/null
  while ((waited++ < 25)); do
    # The process exits under us as soon as it has finalized, and a bare
    # redirect on a vanished proc entry prints to stderr, so test readability
    # before reading instead of trying to suppress the message.
    [[ -r /proc/$pid/stat ]] || break
    state=$(<"/proc/$pid/stat") || break
    state=${state##*) }
    [[ ${state:0:1} != "Z" ]] || break
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 0
}

# Trim the opening frame and normalize loudness in a single pass.
#
# The trim drops the PipeWire transient the mute/fade below also target, so it
# belongs to the normalize pass: with normalize off the file is copied as-is.
# The first 400ms are hard-muted because PipeWire's capture open produces a
# near-clipping transient around 130-200ms that no gentle fade-in can attenuate
# enough. The 50ms fade then avoids a click at the boundary. loudnorm declares
# 192kHz output, so without -ar the encoder writes 96kHz from a 48kHz recording.
finalize_recording() {
  local latest
  latest=$(cat "$RECORDING_FILE" 2>/dev/null)
  [[ -f $latest ]] || return

  local args=(-y)
  if [[ $NORMALIZE_AUDIO == true ]]; then
    args+=(-ss 0.1)
  fi
  args+=(-i "$latest" -c:v copy)

  if [[ $NORMALIZE_AUDIO == true ]]; then
    local probe_out=""
    local probe_rc=0
    probe_out=$(ffprobe -v error -select_streams a -show_entries stream=codec_type \
      -of csv=p=0 "$latest" 2>&1) || probe_rc=$?

    if [[ $probe_rc -ne 0 ]]; then
      log "audio probe failed, preserving original recording"
      return
    fi

    if grep -q audio <<< "$probe_out"; then
      args+=(-c:a aac -ar 48000 -af
        "volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05,loudnorm=I=-14:TP=-1.5:LRA=11")
    else
      args+=(-an)
    fi
  fi

  local processed
  processed=$(mktemp "${latest%.mp4}-processed.XXXXXX.mp4") || return 1
  if ffmpeg "${args[@]}" "$processed" -loglevel quiet 2>/dev/null; then
    mv "$processed" "$latest"
  else
    rm -f "$processed"
  fi
}

stop_recording() {
  local pid filename
  pid=""
  [[ -r $REC_PID_FILE ]] && pid=$(<"$REC_PID_FILE")

  if recorder_pid_alive "$pid"; then
    end_recorder "$pid"
  fi

  cleanup_webcam

  filename=$(cat "$RECORDING_FILE" 2>/dev/null)

  if [[ -n $filename && -f $filename ]]; then
    finalize_recording
    echo "file=$filename"
  fi

  rm -f "$RECORDING_FILE" "$REC_PID_FILE" "$NORMALIZE_FILE"
}

# A pid left behind by a recording that ended without a stop would hide the next
# one from the toggle, so status falls back to "any recorder of ours is running".
recording_active() {
  local pid
  [[ -f $REC_PID_FILE ]] || return 1
  pid=$(<"$REC_PID_FILE")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  recorder_pid_alive "$pid"
}

start_cancelled() { [[ -e $CANCEL_FILE ]]; }

# ── entry point ───────────────────────────────────────────────────────────────

case $ACTION in
status)
  if recording_active; then
    echo "state=recording"
    [[ -f $RECORDING_FILE ]] && echo "file=$(cat "$RECORDING_FILE")"
    exit 0
  fi
  # Never delete the pid file here: a start can write a fresh pid between the
  # liveness check and the rm, which would leave the new recorder untracked. A
  # stale pid is harmless because recording_active() re-checks the executable.
  if [[ -e $STARTING_FILE ]]; then
    starter=""
    [[ -r $STARTING_FILE ]] && starter=$(<"$STARTING_FILE")
    # A start that died on its own (or was killed) would otherwise report
    # "starting" forever. The file is left in place: a new start overwrites it,
    # and deleting it here could race one that just wrote a fresh pid.
    if [[ $starter =~ ^[0-9]+$ ]] && kill -0 "$starter" 2>/dev/null; then
      echo "state=starting"
      exit 0
    fi
  fi
  echo "state=idle"
  exit 0
  ;;

start | stop)
  # Background children close fd 9; the status query stays read-only so a picker
  # can never stall behind it.
  exec 9>>"$RUNTIME_DIR/capture.lock"

  if ! flock -w 1 9; then
    touch "$CANCEL_FILE"
    # Script scope, so this is a plain assignment: `local` outside a function
    # fails, leaves the variable unset, and `set -u` then aborts the script.
    starter=""
    [[ -r $STARTING_FILE ]] && starter=$(<"$STARTING_FILE")
    if [[ $starter =~ ^[0-9]+$ ]] && kill -0 "$starter" 2>/dev/null; then
      # The start may be waiting on its picker. Dismiss it so "cancel" is
      # immediate instead of waiting for the user to choose something the
      # CANCEL_FILE will then throw away.
      "$PICK_SCRIPT" --cancel
      exit 0
    fi
    # The start is gone, but its picker inherits the lock and can keep holding
    # it. Dismiss that too before waiting for the lock to be released.
    "$PICK_SCRIPT" --cancel
    flock 9 || exit 1
    [[ -e $CANCEL_FILE ]] || exit 0
    rm -f "$CANCEL_FILE"
  fi

  # A start while a recording is running is the toggle the bar widget sends:
  # it stops what is running instead of refusing to start.
  if recording_active; then
    echo "state=idle"
    stop_recording
    exit 0
  fi

  if [[ $ACTION == stop ]]; then
    echo "state=idle"
    stop_recording
    exit 0
  fi

  rm -f "$CANCEL_FILE"
  echo $$ >"$STARTING_FILE"
  if start_recording; then
    rm -f "$STARTING_FILE"
    echo "state=recording"
    echo "file=$(cat "$RECORDING_FILE" 2>/dev/null)"
    # A stop that landed between the last check and here still counts.
    if start_cancelled; then
      # Script scope, so no `local`. Read guarded files without `$(<f 2>/dev/null)`:
      # that form silently yields an empty string, which is how the recorder was
      # left running and its pid file removed underneath it.
      pid=""
      [[ -r $REC_PID_FILE ]] && pid=$(<"$REC_PID_FILE")
      [[ $pid =~ ^[0-9]+$ ]] && end_recorder "$pid"
      cleanup_webcam
      file=""
      [[ -r $RECORDING_FILE ]] && file=$(<"$RECORDING_FILE")
      [[ -n $file ]] && rm -f "$file"
      rm -f "$REC_PID_FILE" "$RECORDING_FILE" "$NORMALIZE_FILE" "$STARTING_FILE" "$CANCEL_FILE"
      echo "state=idle"
      exit 1
    fi
    exit 0
  fi

  rm -f "$STARTING_FILE" "$CANCEL_FILE"
  cleanup_webcam
  echo "state=idle"
  exit 1
  ;;

*)
  echo "usage: $(basename "$0") {start|stop|status} [--target=...] [options]" >&2
  exit 2
  ;;
esac
