#!/usr/bin/env python3
"""Extract GIF frames to PNG so the panel can animate them.

Noctalia's `ui.image` draws only the first frame of an animated GIF, so the
plugin extracts every frame to a PNG and swaps them on a frame tick. This
script writes the PNGs and a `manifest.json` with the durations into the
directory passed by the plugin.

Usage:
    gif-frames.py <file.gif> <output_dir>
"""
from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image, ImageSequence
except Exception as exc:  # pragma: no cover - depende del sistema
    print(f"Pillow not available: {exc}", file=sys.stderr)
    raise SystemExit(2)

# Very long GIFs are trimmed to avoid filling the disk or the panel's CPU
# budget; 120 frames is more than enough for a thumbnail.
MAX_FRAMES = 120
MAX_WIDTH = 320


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: gif-frames.py <file.gif> <output_dir>", file=sys.stderr)
        return 1

    source, outdir = sys.argv[1], sys.argv[2]
    if not os.path.isfile(source):
        print(f"does not exist: {source}", file=sys.stderr)
        return 1

    os.makedirs(outdir, exist_ok=True)

    # Clear frames from a previous extraction to avoid mixing versions.
    for name in os.listdir(outdir):
        if name.startswith("frame-") and name.endswith(".png"):
            try:
                os.remove(os.path.join(outdir, name))
            except OSError:
                pass

    frames: list[str] = []
    durations: list[int] = []

    with Image.open(source) as image:
        for index, frame in enumerate(ImageSequence.Iterator(image)):
            if index >= MAX_FRAMES:
                break
            rgba = frame.convert("RGBA")
            width, height = rgba.size
            if width > MAX_WIDTH:
                new_height = max(1, round(height * MAX_WIDTH / width))
                rgba = rgba.resize((MAX_WIDTH, new_height), Image.BILINEAR)
            name = f"frame-{index:03d}.png"
            rgba.save(os.path.join(outdir, name), "PNG", optimize=True)
            frames.append(name)
            # Pillow exposes the duration in milliseconds; some GIFs use 0
            # for "as soon as possible", which we interpret as 100 ms.
            duration = int(frame.info.get("duration", 100) or 100)
            durations.append(max(20, duration))

    if not frames:
        print("the GIF produced no frames", file=sys.stderr)
        return 1

    manifest = {
        "frames": frames,
        "durations": durations,
        "mtime": int(os.path.getmtime(source)),
    }
    with open(os.path.join(outdir, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
