#!/usr/bin/env python3
# Transparent sticker overlay for the reaction plugin.
#
# Shows one image (PNG/JPG, or an animated GIF as a sequence of pre-extracted
# PNG frames) above every window on the primary output with no background card
# of any kind. The surface lives on the layer-shell overlay layer, ignores input
# entirely (fully click-through) and closes itself once the requested duration
# is over.
#
# Usage:
#   reaction-overlay.py --path <file> [--frames-dir <dir>]
#                       [--position bottom_left] [--size 420]
#                       [--duration 3000] [--fade 250] [--margin 8]
#                       [--opacity 1.0] [--tag reaction]
#   reaction-overlay.py --hide [--tag reaction]
#   reaction-overlay.py --probe
#
# --size and --margin are Noctalia logical pixels; the script multiplies them
# by the ui_scale found in the Noctalia config so the sticker matches the
# shell. --duration is the total time on screen, fade included. --probe only
# checks that the dependencies import and exits: the plugin uses it to decide
# between this overlay and its panel fallback.
#
# Animated GIFs are played from the plugin's frame cache when `--frames-dir`
# points at it (see lib/gif.luau): the directory holds a `metadata.json` with
# the frame names and delays. Drawing those static frames keeps memory flat,
# where driving a GdkPixbuf animation grows it by roughly one frame per tick.

import argparse
import json
import os
import signal
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
gi.require_version("GtkLayerShell", "0.1")

import cairo  # noqa: E402
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk, GtkLayerShell  # noqa: E402

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None

POSITIONS = {
    "top_left": (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.LEFT),
    "top_center": (GtkLayerShell.Edge.TOP,),
    "top_right": (GtkLayerShell.Edge.TOP, GtkLayerShell.Edge.RIGHT),
    "center_left": (GtkLayerShell.Edge.LEFT,),
    "center": (),
    "center_right": (GtkLayerShell.Edge.RIGHT,),
    "bottom_left": (GtkLayerShell.Edge.BOTTOM, GtkLayerShell.Edge.LEFT),
    "bottom_center": (GtkLayerShell.Edge.BOTTOM,),
    "bottom_right": (GtkLayerShell.Edge.BOTTOM, GtkLayerShell.Edge.RIGHT),
    "auto": (),
}


def pid_file(tag):
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(base, "noctalia-reaction-overlay-%s.pid" % tag)


def unlink_quietly(path):
    # The previous instance removes its own pid file as it exits, so by the
    # time a newer one gets here the file is often already gone.
    try:
        os.unlink(path)
    except OSError:
        pass


def load_frameset(frames_dir):
    """Read a frame cache written by lib/gif.luau.

    Returns (paths, durations_ms, total_ms). Raises OSError/ValueError when the
    directory or its metadata.json is missing or unusable, so the caller can
    fall back to the still-image path.
    """
    meta_path = os.path.join(frames_dir, "metadata.json")
    with open(meta_path, "rb") as fh:
        meta = json.load(fh)

    names = [str(name) for name in meta["frames"]]
    durations = [max(1, int(value)) for value in meta["durations"]]
    if not names or len(durations) != len(names):
        raise ValueError("frame set is empty or inconsistent")

    paths = [os.path.join(frames_dir, name) for name in names]
    missing = [path for path in paths if not os.path.isfile(path)]
    if missing:
        raise ValueError("missing frame: %s" % missing[0])

    total_ms = sum(durations)
    return paths, durations, max(1, total_ms)


def frame_index(durations, total_ms, elapsed_ms):
    """Index of the frame shown at elapsed_ms, looping over the animation."""
    position = elapsed_ms % total_ms
    acc = 0
    for i, duration in enumerate(durations):
        acc += duration
        if position < acc:
            return i
    return len(durations) - 1


def kill_previous(tag):
    """Stop a sticker that is still on screen from an earlier trigger."""
    path = pid_file(tag)
    try:
        with open(path) as fh:
            pid = int(fh.read().strip())
    except (OSError, ValueError):
        return
    if pid == os.getpid():
        return
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            cmdline = fh.read().decode(errors="replace")
    except OSError:
        unlink_quietly(path)
        return
    if "reaction-overlay" not in cmdline:
        # Stale pid from an unrelated process: never signal it.
        unlink_quietly(path)
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        unlink_quietly(path)
        return
    for _ in range(50):  # up to one second
        try:
            os.kill(pid, 0)
        except OSError:
            break
        GLib.usleep(20000)
    unlink_quietly(path)


def read_ui_scale():
    """Noctalia accessibility scale, from the GUI state first, then config."""
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    for path in (
        os.path.join(state, "noctalia", "settings.toml"),
        os.path.join(config, "noctalia", "config.toml"),
    ):
        if tomllib is None:
            break
        try:
            with open(path, "rb") as fh:
                data = tomllib.load(fh)
        except (OSError, ValueError):
            continue
        value = data.get("accessibility", {}).get("ui_scale")
        if isinstance(value, (int, float)) and value > 0:
            return float(value)
    return 1.0


class Overlay:
    def __init__(self, args):
        self.args = args
        self.start_ms = GLib.get_monotonic_time() // 1000
        self.fade_ms = max(0, min(args.fade, args.duration))
        self.base_opacity = max(0.0, min(1.0, args.opacity))

        self.frames = None  # frame paths when playing an extracted GIF
        self.durations = None  # per-frame delay in milliseconds
        self.total_ms = 0
        self.frame_pos = 0  # index of the frame currently loaded
        self.pixbuf = None  # displayed frame, or the single still image

        first = None
        if args.frames_dir:
            try:
                frames, durations, total_ms = load_frameset(args.frames_dir)
                first = GdkPixbuf.Pixbuf.new_from_file(frames[0])
                self.frames, self.durations, self.total_ms = frames, durations, total_ms
            except Exception as exc:  # noqa: BLE001 - any failure means fall back
                sys.stderr.write(
                    "reaction-overlay: frame cache unusable (%s), using --path\n" % exc
                )
                self.frames = None

        if self.frames is None:
            first = GdkPixbuf.Pixbuf.new_from_file(args.path)
        self.pixbuf = first

        if first is None:
            sys.stderr.write("reaction-overlay: cannot read image\n")
            sys.exit(2)
        scale = read_ui_scale()
        box = max(16, round(args.size * scale))
        factor = min(box / first.get_width(), box / first.get_height())
        self.win_w = max(1, round(first.get_width() * factor))
        self.win_h = max(1, round(first.get_height() * factor))
        self.margin = max(0, round(args.margin * scale))
        self.pid_path = pid_file(args.tag)

        self.win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.win.set_decorated(False)
        self.win.set_app_paintable(True)
        self.win.set_title("reaction-overlay")
        GtkLayerShell.init_for_window(self.win)
        GtkLayerShell.set_namespace(self.win, "reaction-overlay")
        GtkLayerShell.set_layer(self.win, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_keyboard_mode(self.win, GtkLayerShell.KeyboardMode.NONE)
        GtkLayerShell.set_exclusive_zone(self.win, 0)
        for edge in POSITIONS.get(args.position, ()):
            GtkLayerShell.set_anchor(self.win, edge, True)
            GtkLayerShell.set_margin(self.win, edge, self.margin)
        visual = self.win.get_screen().get_rgba_visual()
        if visual is not None:
            self.win.set_visual(visual)
        self.win.set_default_size(self.win_w, self.win_h)
        self.win.connect("destroy", Gtk.main_quit)

        self.area = Gtk.DrawingArea()
        self.area.set_size_request(self.win_w, self.win_h)
        self.area.connect("draw", self.on_draw)
        self.win.add(self.area)

    def current_alpha(self):
        if self.fade_ms <= 0:
            return self.base_opacity
        elapsed = GLib.get_monotonic_time() // 1000 - self.start_ms
        fade_start = self.args.duration - self.fade_ms
        if elapsed <= fade_start:
            return self.base_opacity
        return self.base_opacity * max(
            0.0, (self.args.duration - elapsed) / self.fade_ms
        )

    def on_draw(self, _area, cr):
        pixbuf = self.pixbuf
        if pixbuf is None:
            return False
        factor = min(
            self.win_w / pixbuf.get_width(), self.win_h / pixbuf.get_height()
        )
        width = pixbuf.get_width() * factor
        height = pixbuf.get_height() * factor
        cr.save()
        cr.translate((self.win_w - width) / 2.0, (self.win_h - height) / 2.0)
        cr.scale(factor, factor)
        Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
        cr.paint_with_alpha(self.current_alpha())
        cr.restore()
        return False

    def on_tick(self):
        now = GLib.get_monotonic_time() // 1000
        elapsed = now - self.start_ms
        if self.frames is not None:
            index = frame_index(self.durations, self.total_ms, elapsed)
            if index != self.frame_pos:
                self.frame_pos = index
                try:
                    self.pixbuf = GdkPixbuf.Pixbuf.new_from_file(self.frames[index])
                    self.area.queue_draw()
                except Exception as exc:  # noqa: BLE001 - keep the last frame
                    sys.stderr.write("reaction-overlay: frame load failed: %s\n" % exc)
        if elapsed >= self.args.duration:
            Gtk.main_quit()
            return False
        if self.current_alpha() < 1.0:
            self.area.queue_draw()
        return True

    def cleanup(self):
        try:
            with open(self.pid_path) as fh:
                if int(fh.read().strip()) == os.getpid():
                    os.unlink(self.pid_path)
        except (OSError, ValueError):
            pass

    def run(self):
        with open(self.pid_path, "w") as fh:
            fh.write(str(os.getpid()))
        self.win.show_all()
        gdk_window = self.win.get_window()
        if gdk_window is not None:
            if hasattr(gdk_window, "set_pass_through"):
                gdk_window.set_pass_through(True)
            else:
                gdk_window.input_shape_combine_region(cairo.Region(), 0, 0)
        GLib.timeout_add(16, self.on_tick)
        signal.signal(signal.SIGTERM, lambda *_: Gtk.main_quit())
        signal.signal(signal.SIGINT, lambda *_: Gtk.main_quit())
        try:
            Gtk.main()
        finally:
            self.cleanup()


def main():
    parser = argparse.ArgumentParser(description="reaction transparent sticker overlay")
    parser.add_argument("--path", default="")
    parser.add_argument("--frames-dir", default="")
    parser.add_argument("--position", default="center", choices=sorted(POSITIONS))
    parser.add_argument("--size", type=float, default=420.0)
    parser.add_argument("--duration", type=int, default=3000)
    parser.add_argument("--fade", type=int, default=250)
    parser.add_argument("--margin", type=float, default=8.0)
    parser.add_argument("--opacity", type=float, default=1.0)
    parser.add_argument("--tag", default="reaction")
    parser.add_argument("--hide", action="store_true")
    parser.add_argument("--probe", action="store_true")
    args = parser.parse_args()

    if args.probe:
        # Reaching this point already proves the imports above succeeded.
        return 0

    if args.hide:
        kill_previous(args.tag)
        return 0

    if not args.path:
        sys.stderr.write("reaction-overlay: --path is required\n")
        return 2
    kill_previous(args.tag)
    path = os.path.abspath(os.path.expanduser(args.path))
    if not os.path.isfile(path):
        sys.stderr.write("reaction-overlay: file not found: %s\n" % path)
        return 2
    args.path = path
    if args.frames_dir:
        args.frames_dir = os.path.abspath(os.path.expanduser(args.frames_dir))
    Overlay(args).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
