#!/usr/bin/env python3
"""Print audio durations (seconds) for each given file, one per line.

The panel uses this to decide whether to show the stop button, which only makes
sense for sounds longer than a few seconds (see OVERRIDE threshold in logic).
Prints one line per argument, in order: the duration in seconds with three
decimals, or "NA" when the format can't be probed.

Probes, in order of reliability: ffprobe (best for ogg/mp3/wav), mutagen (when
python3-mutagen is importable), and a header read for uncompressed .wav files.
"""

import subprocess
import sys
import wave


def probe_ffprobe(path):
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=nw=1:nk=1", path],
            check=True, capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return float(out)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        return None


def probe_mutagen(path):
    try:
        from mutagen import File as MutagenFile
        audio = MutagenFile(path)
        if audio is None:
            return None
        length = getattr(audio.info, "length", None)
        if length is None or length <= 0:
            return None
        return float(length)
    except Exception:
        return None


def probe_wav(path):
    try:
        with wave.open(path, "rb") as w:
            rate = w.getframerate()
            if rate <= 0:
                return None
            return w.getnframes() / float(rate)
    except Exception:
        return None


def main(argv):
    results = []
    for path in argv:
        duration = probe_ffprobe(path)
        if duration is None:
            duration = probe_mutagen(path)
        if duration is None and path.lower().endswith(".wav"):
            duration = probe_wav(path)
        results.append("NA" if duration is None else "{:.3f}".format(duration))
    if results:
        print("\n".join(results))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))