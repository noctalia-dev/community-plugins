#!/usr/bin/env bash
# Invoked via:  bash scripts/mpv.sh <fn> <args...>

DIR="/tmp/noctalia-ytmusic"
PIDFILE="$DIR/mpv.pid"
SOCK="$DIR/mpv.sock"
GENFILE="$DIR/mpv.gen"

mkdir -p "$DIR"

mpv_play() {   # $1=volume $2=url_file $3=title_file
  local vol="${1:-100}"
  URL=$(cat "$2")
  TITLE=$(cat "$3" 2>/dev/null)
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  sleep 0.3
  rm -f "$SOCK"
  nohup mpv "$URL" --no-video --vo=null --vd=null --audio-display=no --no-osc --no-osd-bar \
    --demuxer-max-bytes=20M --demuxer-readahead-secs=60 --really-quiet --no-terminal \
    --keep-open=yes \
    --force-media-title="$TITLE" \
    --input-ipc-server="$SOCK" --ao=pipewire \
    >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  echo $(( $(cat "$GENFILE" 2>/dev/null || echo 0) + 1 )) > "$GENFILE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && printf '' | nc -U -N -w1 "$SOCK" >/dev/null 2>&1 && break
    sleep 0.2
  done
  [ -S "$SOCK" ] && { 
    echo "READY=1"
    printf '{"command":["set_property","volume",%s]}\n' "$vol" | nc -U -N -w1 "$SOCK" >/dev/null 2>&1
  }
}

mpv_send() {   # $1=payload json
  local payload="$1"
  [ -S "$SOCK" ] || exit 0
  TMP=$(mktemp)
  printf '%s\n' "$payload" > "$TMP"
  nc -U -N -w2 "$SOCK" < "$TMP" >/dev/null 2>&1
  rm -f "$TMP"
}

mpv_kill() {
  if [ -f "$PIDFILE" ]; then
    PREV=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$PREV" ] && kill -9 "$PREV" >/dev/null 2>&1
    rm -f "$PIDFILE"
  fi
  pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  echo $(( $(cat "$GENFILE" 2>/dev/null || echo 0) + 1 )) > "$GENFILE"
  rm -f "$SOCK"
}

# Persistent push stream: one connection per mpv instance. mpv pushes
# `end-file`/`property-change` events natively; time-pos is requested once per
# second (the keep-alive loop doubles as the ticker), audio-bitrate every 10th
# tick. The owning mpv's pid is captured at start; while that instance stays
# alive the stream self-heals by reconnecting if the connection drops without
# mpv dying. When that mpv instance dies (track switch or stop) the socket is
# removed -> the loop exits and the plugin starts a fresh stream for the next
# instance.
mpv_stream() {
  local pid gen
  [ -S "$SOCK" ] || exit 0
  pid=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$pid" ] || exit 0
  gen=$(cat "$GENFILE" 2>/dev/null)
  while [ -S "$SOCK" ] && kill -0 "$pid" 2>/dev/null && [ "$(cat "$GENFILE" 2>/dev/null)" = "$gen" ]; do
    # The whole pipeline runs behind a hard timeout so a hung member (e.g. nc
    # closing the connection while the ticker's pipe never signals EOF) can
    # NEVER wedge the loop: it self-terminates and the guards re-run.
    timeout 120 bash <<EOF
{
echo '{"command":["observe_property",1,"pause"]}'
echo '{"command":["observe_property",2,"duration"]}'
echo '{"command":["observe_property",3,"eof-reached"]}'
echo '{"command":["observe_property",4,"audio-codec-name"]}'
echo '{"command":["observe_property",5,"audio-params/samplerate"]}'
i=0
while [ -S "$SOCK" ] && kill -0 "$pid" 2>/dev/null && [ "\$(cat "$GENFILE" 2>/dev/null)" = "$gen" ]; do
  echo '{"command":["get_property","time-pos"],"request_id":100}'
  if [ \$((i % 10)) -eq 0 ]; then
    echo '{"command":["get_property","audio-bitrate"],"request_id":200}'
  fi
  i=\$((i + 1))
  sleep 1
done
} | nc -U "$SOCK"
EOF
    sleep 1
  done
}

fn="${1:?fn required}"; shift
type -t "$fn" >/dev/null 2>&1 || { echo "unknown fn: $fn" >&2; exit 1; }
"$fn" "$@"