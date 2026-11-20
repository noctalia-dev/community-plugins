#!/usr/bin/env python3
"""Screenshots of floating windows for the Noctalia panel.

The plugin writes a JSON file with the windows it wants to capture.

Capture method: `grim -T <stableId>`, Hyprland's stable toplevel identifier.
It captures the window buffer regardless of windows, panels, bars or
notifications above it, and does not change the window order.

When a client has no stableId, the window is skipped: capturing by geometry
would save the desktop (or whatever is above) and show it on the card. The
panel falls back to its static or mock preview in that case.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time


def _save_resized(raw: str, target_w: int, target_h: int, out: str) -> None:
    """Resize the temporary capture to the panel thumbnail size."""
    from PIL import Image

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    with Image.open(raw) as image:
        image = image.convert("RGB")
        if image.size != (target_w, target_h):
            image = image.resize((target_w, target_h), Image.LANCZOS)
        image.save(out)


def capture_toplevel(stable_id: str, target_w: int, target_h: int, out: str) -> bool:
    """Capture ONLY that window with `grim -T <stableId>`.

    It captures the toplevel buffer: it does not matter if other windows, the
    Noctalia panel, a bar or a notification are above it. It does not change
    the window order either.
    """
    handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
    os.close(handle)
    try:
        # The window may take a moment to be mapped after opening: retry a
        # couple of times before giving up.
        for attempt in range(3):
            try:
                subprocess.run(
                    ["grim", "-T", str(stable_id), raw],
                    check=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.PIPE,
                    timeout=5.0,
                )
                _save_resized(raw, target_w, target_h, out)
                return True
            except Exception:
                if attempt == 2:
                    return False
                time.sleep(0.08)
        return False
    finally:
        try:
            os.unlink(raw)
        except OSError:
            pass


def capture(item: dict) -> None:
    """Capture a window with `grim -T` when it exposes a stable ID.

    Without a stable ID the window is skipped: a geometry capture would
    include whatever is above it. The panel then keeps its static or mock
    preview for that card.
    """
    out = str(item["out"])
    target_w = max(16, int(item.get("width", 320)))
    target_h = max(16, int(item.get("height", 190)))
    current_out = item.get("current_out")
    stable_id = item.get("stable_id") or item.get("stableId")

    if not stable_id:
        return

    if capture_toplevel(str(stable_id), target_w, target_h, out) and current_out:
        try:
            shutil.copy2(out, current_out)
        except Exception:
            pass


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: snapshot.py <batch.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        items = json.load(handle)

    failures = 0
    for item in items:
        try:
            capture(item)
        except Exception as exc:  # noqa: BLE001 - one failure must not stop the batch
            failures += 1
            print(f"snapshot: {item.get('out')}: {exc}", file=sys.stderr)

    return 1 if failures and failures == len(items) else 0


if __name__ == "__main__":
    sys.exit(main())
