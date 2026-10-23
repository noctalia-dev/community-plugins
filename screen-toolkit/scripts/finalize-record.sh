#!/usr/bin/env bash
# finalize-record.sh <input> <output> <thumb>
#
# Turn a raw recorder file into a share-ready MP4 and a preview frame:
#   - drop the first 0.1 s, where recorders put their keyframe warmup
#   - hard-mute the first 400 ms of audio (the capture-open pop) and fade
#     the next 50 ms in, so the mute does not click
#   - normalise to -14 LUFS
#   - +faststart, so the file streams without a full download
#   - write a PNG from 0.2 s for the save toast
#
# Video is stream-copied unless the first GOP carries discardable warmup
# packets: a copy can only start at a keyframe, so trimming those needs a
# re-encode. Clean recordings stay on the fast path.
#
# The input is never modified or removed — the caller deletes it once this
# exits 0. Output is written beside the destination and moved into place,
# so a failed run cannot leave a half-written file wearing the recording's
# name.
#
# Exit codes:
#   1 — missing / invalid arguments
#   2 — input file not found
#   3 — missing dependency (ffmpeg, ffprobe)
#   4 — ffmpeg failed
#
# The thumbnail is best-effort: a failure there leaves the MP4 valid and
# only costs the toast its picture.
#
# Used by: service.luau
set -euo pipefail

INPUT="${1:-}"
OUTPUT="${2:-}"
THUMB="${3:-}"

[ -n "$INPUT" ]  || { echo "ERROR: finalize-record: missing <input>"  >&2; exit 1; }
[ -n "$OUTPUT" ] || { echo "ERROR: finalize-record: missing <output>" >&2; exit 1; }
[ -n "$THUMB" ]  || { echo "ERROR: finalize-record: missing <thumb>"  >&2; exit 1; }
[ -f "$INPUT" ] || { echo "ERROR: finalize-record: file not found: $INPUT" >&2; exit 2; }

_require() {
    command -v "$1" >/dev/null 2>&1 \
        || { echo "ERROR: missing dependency: $1" >&2; exit 3; }
}
_require ffmpeg
_require ffprobe

video_codec=(-c:v copy)
if ffprobe -v error -select_streams v:0 -read_intervals %+0.2 \
        -show_entries packet=flags -of csv=p=0 "$INPUT" 2>/dev/null | grep -q D; then
    video_codec=(-c:v libx264 -preset veryfast -crf 20)
fi

audio_codec=()
if ffprobe -v error -select_streams a -show_entries stream=codec_type \
        -of csv=p=0 "$INPUT" 2>/dev/null | grep -q audio; then
    # loudnorm announces 192 kHz output; without -ar the AAC encoder writes
    # 96 kHz from a 48 kHz capture.
    audio_codec=(
        -ar 48000 -c:a aac -b:a 128k
        -af "volume=enable='lt(t,0.4)':volume=0,afade=t=in:st=0.4:d=0.05,loudnorm=I=-14:TP=-1.5:LRA=11"
    )
fi

partial="$OUTPUT.partial"
rm -f "$partial"
ffmpeg -y -loglevel error -ss 0.1 -i "$INPUT" \
    "${video_codec[@]}" "${audio_codec[@]}" \
    -movflags +faststart -f mp4 "$partial" \
    || { rm -f "$partial"; echo "ERROR: finalize-record: ffmpeg failed" >&2; exit 4; }
mv -f "$partial" "$OUTPUT" \
    || { rm -f "$partial"; echo "ERROR: finalize-record: mv failed" >&2; exit 4; }

# 0.2 s of the raw file is 0.1 s of the finalized one, so the toast shows the
# frame the video opens on rather than its warmup.
if mkdir -p "$(dirname "$THUMB")" 2>/dev/null; then
    ffmpeg -y -loglevel error -ss 0.2 -i "$INPUT" -frames:v 1 "$THUMB" 2>/dev/null \
        || { rm -f "$THUMB"; echo "WARNING: finalize-record: thumbnail failed" >&2; }
fi
exit 0
