#!/usr/bin/env bash
# record-toast.sh <video> <thumb> <summary> [body] [play-label]
#
# Post a "recording saved" toast that carries the preview frame and a
# click-to-play action. The plugin's own notify API is text-only at every
# level, so the image and the action have to travel as freedesktop hints
# through notify-send to the shell's notification daemon.
#
# Runs until the toast is dismissed or times out (-A implies --wait): the
# selected action, if any, arrives on stdout. On "play" the video opens in
# mpv, detached.
#
# The thumbnail is deleted once notify-send returns — the daemon has read
# it by then, and the toast never re-reads the file.
#
# Without notify-send this is a silent no-op: the caller keeps its plain
# text notification, so the missing dependency costs the picture and the
# action, not the confirmation.
#
# Exit codes:
#   1 — missing / invalid arguments
#   2 — video file not found
#   3 — missing dependency (mpv, when the play action is chosen)
#   4 — notify-send failed
#   0 — also when notify-send is absent (silent no-op)
#
# Used by: service.luau
set -euo pipefail

VIDEO="${1:-}"
THUMB="${2:-}"
SUMMARY="${3:-}"
BODY="${4:-}"
PLAY_LABEL="${5:-Play in mpv}"

[ -n "$VIDEO" ]   || { echo "ERROR: record-toast: missing <video>"   >&2; exit 1; }
[ -n "$THUMB" ]   || { echo "ERROR: record-toast: missing <thumb>"   >&2; exit 1; }
[ -n "$SUMMARY" ] || { echo "ERROR: record-toast: missing <summary>" >&2; exit 1; }
[ -f "$VIDEO" ]   || { echo "ERROR: record-toast: file not found: $VIDEO" >&2; exit 2; }

command -v notify-send >/dev/null 2>&1 || exit 0

args=(-a screen-toolkit -t 10000)
if [ -f "$THUMB" ]; then
    args+=("--hint=string:image-path:$THUMB")
fi
args+=(--action="play=$PLAY_LABEL")

# An empty body is legal for notify-send; the summary then stands alone.
set +e
action=$(notify-send "${args[@]}" "$SUMMARY" ${BODY:+"$BODY"} 2>/dev/null)
rc=$?
set -e
rm -f "$THUMB"

if [ "$rc" -ne 0 ]; then
    echo "ERROR: record-toast: notify-send failed (exit $rc)" >&2
    exit 4
fi

if [ "$action" = "play" ]; then
    command -v mpv >/dev/null 2>&1 \
        || { echo "ERROR: missing dependency: mpv" >&2; exit 3; }
    # A plain `mpv ... &` would keep the daemon's stderr pipe open; setsid
    # detaches it into its own session so the caller's pipe closes at once.
    setsid mpv --no-config "$VIDEO" >/dev/null 2>&1 &
fi
exit 0
