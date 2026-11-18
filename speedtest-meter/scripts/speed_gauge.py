#!/usr/bin/env python3
# Live speedometer worker for the Speedtest Meter panel.
#
# The Lua panel writes its live download/upload values to a small JSON file
# (first CLI arg). This worker polls that file and animates the two dials
# (download/upload) the way speedtest.net does: instead of jumping straight
# to the latest measurement, the needle/arc/tick-trail sweeps smoothly toward
# it (eased), and the center number counts up alongside the needle. Frames
# are only re-rendered while the dial is actually moving, and every re-render
# is reported to the panel over stdout with the same `ready` protocol so it
# refreshes the ui.image controls. It uses draw_graph.draw_speedometer() — the
# same ring-arc rendering core as the "processes" plugin.
#
# Args: <live_json_path> <download_png_path> <upload_png_path> <skin>

import atexit
import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from draw_graph import draw_speedometer  # noqa: E402

LIVE_FILE = sys.argv[1] if len(sys.argv) > 1 else None
DOWN_FILE = sys.argv[2] if len(sys.argv) > 2 else None
UP_FILE = sys.argv[3] if len(sys.argv) > 3 else None
SKIN = sys.argv[4] if len(sys.argv) > 4 else "dark"

PID = os.getpid()
FILES = [p for p in (LIVE_FILE, DOWN_FILE, UP_FILE) if p]

# Poll fast enough for a fluid sweep (up to ~16 frames/s), but each frame
# only redraws the dial(s) that actually moved.
POLL_INTERVAL = 0.06
# Per-poll easing toward the target: 0.42 (≈95% of the gap closed in ~0.5 s),
# the same feel as speedtest.net's needle sweep.
EASE = 0.42
# Below this gap the value is considered settled and snaps to the target, so
# a measured number keeps displaying exactly and stops re-rendering.
SETTLE_EPS = 0.35
# A frame is only drawn when the eased value moved at least this much, so a
# static dial costs nothing.
DRAW_EPS = 0.30


def cleanup():
    """Remove every generated/runtime file when the worker is stopped."""
    for path in FILES:
        try:
            if path and os.path.exists(path):
                os.remove(path)
        except OSError:
            pass


atexit.register(cleanup)


def handle_signal(signum, frame):
    raise SystemExit(0)


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def parse_accent(text, default):
    try:
        parts = [int(x.strip()) for x in str(text).split(",")]
        if len(parts) == 3 and all(0 <= v <= 255 for v in parts):
            return tuple(parts)
    except (ValueError, TypeError):
        pass
    return default


def target_percent(raw):
    try:
        return max(0.0, min(100.0, float(raw or 0)))
    except (TypeError, ValueError):
        return 0.0


def read_live():
    try:
        with open(LIVE_FILE, "r") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def draw_dial(data, kind, gauge):
    """Redraw one dial from its eased value; returns True if a frame was drawn."""
    src = data.get(kind) or {}
    target = target_percent(src.get("percent"))
    shown = gauge["shown"] + (target - gauge["shown"]) * EASE
    if abs(target - shown) < SETTLE_EPS:
        shown = target
    gauge["shown"] = shown

    if gauge["last_drawn"] is not None and abs(shown - gauge["last_drawn"]) < DRAW_EPS:
        return False

    value_text = str(src.get("value_text") or "0")
    max_raw = 0.0
    try:
        max_raw = float(data.get("max_label") or 0)
    except (TypeError, ValueError):
        max_raw = 0.0
    if max_raw > 0:
        value_text = "%.1f" % (shown / 100.0 * max_raw)
    default_accent = (120, 180, 255) if kind == "download" else (255, 185, 120)

    try:
        draw_speedometer(
            percent=shown,
            value_text=value_text,
            unit_text=str(src.get("unit") or ""),
            label_text=str(src.get("label") or ""),
            max_label=str(data.get("max_label") or ""),
            accent=parse_accent(src.get("accent"), default_accent),
            skin_name=SKIN,
            filename=gauge["file"],
        )
    except Exception as exc:  # keep looping; panel keeps its fallback
        sys.stderr.write("speedtest-gauge:error:%s\n" % exc)
        return False

    gauge["last_drawn"] = shown
    return True


def main():
    if not (LIVE_FILE and DOWN_FILE and UP_FILE):
        return

    print("speedtest-gauge:pid:%d" % PID, flush=True)

    gauges = {
        "download": {"file": DOWN_FILE, "shown": 0.0, "last_drawn": None},
        "upload": {"file": UP_FILE, "shown": 0.0, "last_drawn": None},
    }

    while True:
        data = read_live()
        if data:
            for kind, gauge in gauges.items():
                if draw_dial(data, kind, gauge):
                    print("speedtest-gauge:ready:%s" % gauge["file"], flush=True)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, SystemExit):
        pass
    except Exception as exc:
        sys.stderr.write("speedtest-gauge:fatal:%s\n" % exc)
        sys.exit(1)