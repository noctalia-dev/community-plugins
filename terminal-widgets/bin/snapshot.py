#!/usr/bin/env python3
"""Screenshots of floating windows for the Noctalia panel.

The plugin writes a JSON file with the windows it wants to capture.

CAPTURE METHODS:
1. REAL WINDOW ONLY (primary): grim -T <stableId>
   Hyprland exposes a stable toplevel identifier (`stableId`). grim can
   capture that toplevel directly, regardless of which window, panel, bar or
   notification is above it. It does not touch the z-order or move anything.

2. Legacy fallback: alterzorder top -> grim -g -> alterzorder bottom
   Only when the client has no stableId. It may include layers above the
   window (layer-shell panels), which is why it is no longer preferred.

3. Last resort: exact geometry (grim -g "x,y WxH")
   It may include anything that is above the window.
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


def run_hyprctl(args: list[str], timeout: float = 3.0) -> subprocess.CompletedProcess:
    """Run hyprctl with args and return CompletedProcess."""
    return subprocess.run(
        ["hyprctl"] + args,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def raise_window(address: str) -> bool:
    """Raise the window to the top of the stack (layer top). Returns True on success."""
    try:
        result = run_hyprctl(["dispatch", "alterzorder", f"top,address:{address}"])
        return result.returncode == 0
    except Exception:
        return False


def lower_window(address: str) -> bool:
    """Lower the window to the bottom of the stack. Returns True on success."""
    try:
        result = run_hyprctl(["dispatch", "alterzorder", f"bottom,address:{address}"])
        return result.returncode == 0
    except Exception:
        return False


def capture_window_only(address: str, x: int, y: int, w: int, h: int,
                         target_w: int, target_h: int, out: str) -> bool:
    """Capture ONLY the window: raise it, capture its geometry, lower it.

    This prevents windows/layers above it from being captured.
    """
    # 1. Raise the window
    if not raise_window(address):
        return False

    # Brief pause so the compositor processes the z-order change
    time.sleep(0.05)

    try:
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
        os.close(handle)

        command = ["grim", "-g", f"{x},{y} {w}x{h}", raw]

        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=5.0,
        )
        _save_resized(raw, target_w, target_h, out)
        return True
    except Exception:
        return False
    finally:
        # 2. Restore z-order (lower the window)
        time.sleep(0.02)
        lower_window(address)
        try:
            os.unlink(raw)
        except Exception:
            pass


def capture_output_geometry(item: dict, scales: dict[str, float]) -> bool:
    """Capture by the window's exact geometry (grim -g).

    Captures the exact window rectangle in screen coordinates.
    Note: it may include things above it (other windows, layers).
    The panel avoids capturing when isCovered() detects overlap.
    """
    out = str(item["out"])
    x = int(item["x"])
    y = int(item["y"])
    w = int(item["w"])
    h = int(item["h"])
    target_w = max(16, int(item.get("width", 320)))
    target_h = max(16, int(item.get("height", 190)))

    if w <= 0 or h <= 0:
        raise ValueError("window without size")

    os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
    handle, raw = tempfile.mkstemp(prefix="fterm-", suffix=".png")
    os.close(handle)

    # Capture the EXACT window geometry (no output, geometry only)
    command = ["grim", "-g", f"{x},{y} {w}x{h}", raw]

    try:
        subprocess.run(
            command,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        _save_resized(raw, target_w, target_h, out)
    finally:
        try:
            os.unlink(raw)
        except OSError:
            pass
    return True


def output_scale(output: str, cache: dict[str, float]) -> float:
    """Output scale factor (Hyprland), 1.0 when it cannot be determined."""
    if output in cache:
        return cache[output]
    try:
        result = subprocess.run(
            ["hyprctl", "monitors", "-j"],
            capture_output=True,
            text=True,
            timeout=4.0,
        )
        monitors = json.loads(result.stdout)
    except Exception:  # noqa: BLE001 - assume scale 1 without hyprctl
        cache[output] = 1.0
        return 1.0
    if not isinstance(monitors, list):
        cache[output] = 1.0
        return 1.0
    for monitor in monitors:
        if isinstance(monitor, dict) and monitor.get("name") == output:
            try:
                scale = float(monitor.get("scale") or 1.0)
            except (TypeError, ValueError):
                scale = 1.0
            cache[output] = scale
            return scale
    cache[output] = 1.0
    return 1.0


def capture(item: dict, scales: dict[str, float]) -> None:
    """Capture a window.

    Priority:
      1. `stable_id` -> grim -T (only that window's contents).
      2. `address`   -> raise/capture/lower (legacy fallback).
      3. geometry    -> grim -g (last resort).

    If item has "current_out", also save a copy there for the main preview.
    """
    out = str(item["out"])
    x = int(item["x"])
    y = int(item["y"])
    w = int(item["w"])
    h = int(item["h"])
    target_w = max(16, int(item.get("width", 320)))
    target_h = max(16, int(item.get("height", 190)))
    current_out = item.get("current_out")
    address = item.get("address")
    stable_id = item.get("stable_id") or item.get("stableId")

    if w <= 0 or h <= 0:
        raise ValueError("window without size")

    def copy_current() -> None:
        if current_out:
            try:
                shutil.copy2(out, current_out)
            except Exception:
                pass

    # MODE 1: direct toplevel capture (window only, no layers above).
    if stable_id:
        if capture_toplevel(str(stable_id), target_w, target_h, out):
            copy_current()
            return
        # If the toplevel is not ready yet, skip this round. Capturing by
        # geometry would save the desktop or whatever is above, which is
        # exactly what we want to avoid.
        return

    # MODE 2: WINDOW-ONLY capture via z-order (clients without stableId).
    if address:
        ok = capture_window_only(address, x, y, w, h, target_w, target_h, out)
        if ok:
            copy_current()
            return
        # On failure, fall through to the fallback method

    # MODE 3: Fallback - exact geometry (may include things above)
    capture_output_geometry(item, scales)

    copy_current()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: snapshot.py <batch.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        items = json.load(handle)

    failures = 0
    scales: dict[str, float] = {}
    for item in items:
        try:
            capture(item, scales)
        except Exception as exc:  # noqa: BLE001 - one failure must not stop the batch
            failures += 1
            print(f"snapshot: {item.get('out')}: {exc}", file=sys.stderr)

    return 1 if failures and failures == len(items) else 0


if __name__ == "__main__":
    sys.exit(main())
