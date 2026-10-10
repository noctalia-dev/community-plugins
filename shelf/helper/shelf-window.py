#!/usr/bin/env python3
"""Floating drop window for the Noctalia Shelf plugin.

Noctalia plugin panels cannot take part in Wayland drag and drop, so this small
GTK4 window does it for them: files dropped on it are reported to the plugin,
and files on the shelf can be dragged out of it into any application.

The window never writes the shelf file. It reads the store the plugin passes in
(and follows changes to it), and reports every user action as one JSON object
per line on stdout. The plugin service owns the store and applies them:

    {"op": "ready"}                        process is up
    {"op": "shown"} / {"op": "hidden"}     window was shown or hidden
    {"op": "add", "paths": [...]}          files were dropped or pasted
    {"op": "remove", "paths": [...]}       files were removed from the shelf
    {"op": "clear"}                        the shelf was cleared
    {"op": "bye"}                          process is quitting

The process stays resident: closing the window hides it, so showing it again is
instant. The service drives it through the application's D-Bus actions
(org.gtk.Actions on /dev/noctalia/Shelf):

    show(s), toggle(s), configure(s)       s is the JSON options object
    hide, quit

It quits when stdout closes (the service went away) or after sitting hidden for
IDLE_QUIT_S. Starting a second copy forwards its arguments to the running one:
--toggle toggles, --hide hides, anything else shows.

Without gtk4-layer-shell the window is an ordinary toplevel the compositor
places. With it, the window is a layer surface positioned by margins from the
top-left of the output's free area (the area not reserved by bars), which is
what lets it open at the cursor and be dragged by its header.
"""

import argparse
import concurrent.futures
import ctypes.util
import json
import os
import re
import signal
import subprocess
import sys
from collections import OrderedDict

APP_ID = "dev.noctalia.Shelf"
LAYER_LIB = "libgtk4-layer-shell.so.0"


def _find_layer_shell():
    for d in ("/usr/lib64", "/usr/lib", "/usr/local/lib64", "/usr/local/lib",
              "/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu"):
        p = os.path.join(d, LAYER_LIB)
        if os.path.exists(p):
            return p
    return ctypes.util.find_library("gtk4-layer-shell")


def _maybe_reexec_with_layer_shell():
    # gtk4-layer-shell must be loaded before libwayland-client, which means
    # LD_PRELOAD for a Python process. Re-exec once with it set.
    if os.environ.get("SHELF_NO_LAYER_SHELL") or not os.environ.get("WAYLAND_DISPLAY"):
        return
    if "gtk4-layer-shell" in os.environ.get("LD_PRELOAD", ""):
        return
    lib = _find_layer_shell()
    if not lib:
        return
    env = dict(os.environ)
    env["LD_PRELOAD"] = (lib + " " + env.get("LD_PRELOAD", "")).strip()
    env["SHELF_LAYER_SHELL_TRIED"] = "1"
    os.execve(sys.executable, [sys.executable] + sys.argv, env)


if __name__ == "__main__" and not os.environ.get("SHELF_LAYER_SHELL_TRIED"):
    _maybe_reexec_with_layer_shell()

import gi  # noqa: E402

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Graphene", "1.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Graphene, Gtk, Pango  # noqa: E402

try:
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import GLibUnix  # noqa: E402
    unix_signal_add = GLibUnix.signal_add
except (ValueError, ImportError):
    unix_signal_add = GLib.unix_signal_add

try:
    import cairo  # noqa: E402
    gi.require_foreign("cairo")
except ImportError:
    cairo = None

LayerShell = None
if os.environ.get("SHELF_LAYER_SHELL_TRIED"):
    try:
        gi.require_version("Gtk4LayerShell", "1.0")
        from gi.repository import Gtk4LayerShell as LayerShell  # noqa: E402
        if not LayerShell.is_supported():
            LayerShell = None
    except (ValueError, ImportError, AttributeError):
        LayerShell = None

HOME = os.path.expanduser("~")
THUMB = 40
THUMB_DECODE = THUMB * 2       # enough pixels for a scale-2 output
WINDOW_WIDTH = 340
EDGE_GAP = 8
LIST_MAX_HEIGHT = 380
IDLE_QUIT_S = 10 * 60
PROBE_TIMEOUT_MS = 250
FULL_GRACE_MS = 40
MOVE_MIME = "application/x-noctalia-shelf-move"
DIR_COUNT_LIMIT = 1000
CACHE_SIZE = 256
POSITIONS = ["cursor", "last", "right", "left", "top", "bottom", "top_right", "top_left",
             "bottom_right", "bottom_left", "center"]


def emit(op, **fields):
    fields["op"] = op
    try:
        sys.stdout.write(json.dumps(fields) + "\n")
        sys.stdout.flush()
    except (BrokenPipeError, ValueError):
        # The service is gone; nothing we do can be saved any more.
        app = Gio.Application.get_default()
        if app is not None:
            app.quit()


# --- options ----------------------------------------------------------------

DEFAULT_OPTIONS = {
    "position": "last",
    "remove_after_drag": False,
    "close_after_drag": False,
    "colors": None,
}


def parse_options(raw):
    opts = dict(DEFAULT_OPTIONS)
    try:
        data = json.loads(raw) if raw else {}
    except ValueError:
        data = {}
    if isinstance(data, dict):
        for key in opts:
            if key in data:
                opts[key] = data[key]
    if opts["position"] not in POSITIONS:
        opts["position"] = "cursor"
    opts["remove_after_drag"] = opts["remove_after_drag"] is True
    opts["close_after_drag"] = opts["close_after_drag"] is True
    if not isinstance(opts["colors"], dict):
        opts["colors"] = None
    return opts


# --- theme ------------------------------------------------------------------

DEFAULT_COLORS = {
    "primary": "#c2c1ff",
    "on_primary": "#2a2a60",
    "surface": "#131317",
    "surface_variant": "#1f1f25",
    "on_surface": "#e5e1e7",
    "on_surface_variant": "#c7c5d0",
    "outline": "#47464f",
    "error": "#ffb4ab",
}

GTK_CSS_KEYS = {
    "accent_color": "primary",
    "accent_fg_color": "on_primary",
    "window_bg_color": "surface",
    "card_bg_color": "surface_variant",
    "window_fg_color": "on_surface",
    "destructive_bg_color": "error",
}

HEX_COLOR = re.compile(r"#[0-9a-fA-F]{6}")


def load_colors(overrides):
    colors = dict(DEFAULT_COLORS)
    # Noctalia's GTK template, when enabled, already holds the live palette.
    # The first definition of a name wins, matching how the file is generated.
    css = os.path.join(HOME, ".config/gtk-4.0/noctalia.css")
    seen = set()
    try:
        with open(css, encoding="utf-8") as fh:
            for name, value in re.findall(r"@define-color\s+(\w+)\s+(#[0-9a-fA-F]{6})", fh.read()):
                if name in GTK_CSS_KEYS and name not in seen:
                    seen.add(name)
                    colors[GTK_CSS_KEYS[name]] = value
    except OSError:
        pass
    for key, value in (overrides or {}).items():
        if key in colors and isinstance(value, str) and HEX_COLOR.fullmatch(value):
            colors[key] = value
    return colors


def rgba(hex_color, alpha):
    h = hex_color.lstrip("#")
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return f"rgba({r}, {g}, {b}, {alpha})"


def build_css(c):
    return f"""
window.shelf-window {{ background: transparent; padding: 0; margin: 0; border: none; box-shadow: none; }}
window.shelf-probe {{ background: rgba(0, 0, 0, 0.004); }}
/* The theme's square drop highlight; the card draws its own rounded one. */
window.shelf-window *:drop(active) {{ box-shadow: none; outline: none; border-color: transparent; }}
.shelf-card {{
  background: {c['surface']};
  color: {c['on_surface']};
  border: 1px solid {rgba(c['outline'], 0.8)};
  border-radius: 22px;
  padding: 2px 14px 14px 14px;
}}
window.shelf-window .shelf-card.drop-hover {{ border-color: {c['primary']}; }}
.shelf-grip {{ padding: 4px 0 2px 0; }}
.shelf-grip-dot {{
  min-width: 3px; min-height: 3px;
  border-radius: 999px;
  background: {rgba(c['on_surface_variant'], 0.45)};
}}
.shelf-grip:hover .shelf-grip-dot, .shelf-card.grip-hover .shelf-grip-dot,
.shelf-card.moving .shelf-grip-dot {{ background: {c['primary']}; }}
.shelf-title {{ font-weight: 700; font-size: 1.1em; }}
.shelf-count {{
  background: {rgba(c['primary'], 0.18)};
  color: {c['primary']};
  border-radius: 999px;
  padding: 1px 9px;
  font-weight: 700;
  font-size: 0.85em;
}}
.shelf-sub {{ color: {c['on_surface_variant']}; font-size: 0.85em; }}
.shelf-hint {{ color: {rgba(c['on_surface_variant'], 0.8)}; font-size: 0.8em; }}
button.shelf-icon {{
  min-width: 30px; min-height: 30px; padding: 0;
  border-radius: 999px; background: transparent; box-shadow: none; border: none;
  color: {c['on_surface_variant']};
}}
button.shelf-icon:hover {{ background: {rgba(c['on_surface'], 0.08)}; color: {c['on_surface']}; }}
button.shelf-icon.danger:hover {{ color: {c['error']}; background: {rgba(c['error'], 0.12)}; }}
.shelf-drag-all {{
  background: {c['primary']};
  color: {c['on_primary']};
  border-radius: 999px;
  padding: 5px 12px 5px 10px;
  font-weight: 700;
  font-size: 0.9em;
}}
.shelf-drag-all:hover {{ background: {rgba(c['primary'], 0.88)}; }}
.shelf-dropzone {{
  border: 2px dashed {rgba(c['on_surface_variant'], 0.35)};
  border-radius: 18px;
  padding: 26px 16px;
  background: {rgba(c['surface_variant'], 0.5)};
}}
.drop-hover .shelf-dropzone {{
  border-color: {c['primary']};
  background: {rgba(c['primary'], 0.10)};
}}
.shelf-dropzone-icon {{ color: {c['primary']}; }}
.shelf-dropzone-title {{ font-weight: 700; }}
list.shelf-list {{ background: transparent; }}
list.shelf-list > row {{
  border-radius: 14px; padding: 6px 6px 6px 8px; margin: 1px 0;
  background: transparent;
}}
list.shelf-list > row:hover {{ background: {rgba(c['on_surface'], 0.06)}; }}
list.shelf-list > row:selected {{ background: {rgba(c['primary'], 0.18)}; color: {c['on_surface']}; }}
list.shelf-list > row .row-remove {{ opacity: 0; }}
list.shelf-list > row:hover .row-remove, list.shelf-list > row:focus-within .row-remove {{ opacity: 1; }}
.row-name {{ font-weight: 600; }}
.row-meta {{ color: {c['on_surface_variant']}; font-size: 0.82em; }}
.row-missing .row-name {{ color: {c['error']}; }}
.row-thumb {{ border-radius: 10px; background: {rgba(c['surface_variant'], 0.9)}; }}
.row-thumb-icon {{ color: {c['primary']}; }}
.row-missing .row-thumb-icon {{ color: {c['error']}; }}
.drop-banner {{
  background: {c['primary']};
  color: {c['on_primary']};
  border-radius: 999px;
  padding: 6px 14px;
  font-weight: 700;
  margin: 18px;
}}
dragicon {{ background: none; box-shadow: none; border: none; }}
.drag-pill {{
  background: {c['primary']};
  color: {c['on_primary']};
  border-radius: 999px;
  padding: 6px 12px;
  font-weight: 700;
}}
"""


# --- store ------------------------------------------------------------------

def read_store(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return []  # an empty Luau table encodes as {}
    return [i["path"] for i in items if isinstance(i, dict) and isinstance(i.get("path"), str) and i["path"]]


def pretty_dir(path):
    d = os.path.dirname(path.rstrip("/")) or "/"
    if d == HOME:
        return "~"
    if d.startswith(HOME + "/"):
        return "~" + d[len(HOME):]
    return d


def display_name(path):
    name = os.path.basename(path.rstrip("/")) or path
    return name.replace("\n", " ")


def pixbuf_texture(pix):
    fmt = Gdk.MemoryFormat.R8G8B8A8 if pix.get_has_alpha() else Gdk.MemoryFormat.R8G8B8
    return Gdk.MemoryTexture.new(pix.get_width(), pix.get_height(), fmt,
                                 pix.read_pixel_bytes(), pix.get_rowstride())


def to_window(widget, window, x, y):
    """(x, y) in widget coordinates as window coordinates, or None."""
    ok, point = widget.compute_point(window, Graphene.Point().init(x, y))
    return (point.x, point.y) if ok else None


def file_list(paths):
    return Gdk.FileList.new_from_list([Gio.File.new_for_path(p) for p in paths])


def paths_from_text(text):
    paths = []
    for line in (text or "").splitlines():
        line = line.strip()
        if line.startswith("file://"):
            line = Gio.File.new_for_uri(line).get_path() or ""
        if line.startswith("/") and os.path.exists(line):
            paths.append(line)
    return paths


# --- file details (worker threads) -------------------------------------------

class Details:
    """What a row shows about a file. Built off the main thread."""

    __slots__ = ("key", "exists", "meta", "pixbuf", "gicon", "texture")

    def __init__(self, key, exists, meta, pixbuf=None, gicon=None):
        self.key = key
        self.exists = exists
        self.meta = meta
        self.pixbuf = pixbuf
        self.gicon = gicon
        self.texture = None  # made from pixbuf on the main thread


def stat_key(path):
    try:
        st = os.stat(path)
    except OSError:
        return (path, None, None)
    return (path, st.st_mtime_ns, st.st_size)


def count_entries(path):
    n = 0
    try:
        with os.scandir(path) as it:
            for _ in it:
                n += 1
                if n >= DIR_COUNT_LIMIT:
                    return f"{DIR_COUNT_LIMIT}+ items"
    except OSError:
        return "Folder"
    return f"{n} item" + ("" if n == 1 else "s")


def decode_thumb(source):
    """Square thumbnail pixbuf about THUMB_DECODE pixels wide, or None."""
    fmt, w, h = GdkPixbuf.Pixbuf.get_file_info(source)
    if fmt is None or not w or not h:
        return None
    # Scale so the short side covers the square, then crop the middle.
    scale = THUMB_DECODE / min(w, h)
    if scale < 1:
        pix = GdkPixbuf.Pixbuf.new_from_file_at_scale(source, max(1, round(w * scale)),
                                                      max(1, round(h * scale)), False)
    else:
        pix = GdkPixbuf.Pixbuf.new_from_file(source)
    pix = pix.apply_embedded_orientation() or pix
    pw, ph = pix.get_width(), pix.get_height()
    side = min(pw, ph)
    return pix.new_subpixbuf((pw - side) // 2, (ph - side) // 2, side, side).copy()


def load_details(key):
    path, mtime, _size = key
    if mtime is None:
        return Details(key, False, "Missing · " + pretty_dir(path))
    gfile = Gio.File.new_for_path(path)
    try:
        info = gfile.query_info("standard::type,standard::size,standard::symbolic-icon,standard::content-type,"
                                "thumbnail::path,thumbnail::is-valid", Gio.FileQueryInfoFlags.NONE, None)
    except GLib.Error:
        return Details(key, True, "— · " + pretty_dir(path))
    if info.get_file_type() == Gio.FileType.DIRECTORY:
        size = "Folder · " + count_entries(path)
    else:
        size = GLib.format_size(info.get_size())
    meta = f"{size} · {pretty_dir(path)}"
    thumb = info.get_attribute_byte_string("thumbnail::path")
    ctype = info.get_content_type() or ""
    source = thumb if thumb and info.get_attribute_boolean("thumbnail::is-valid") else None
    if source is None and ctype.startswith("image/") and ctype != "image/svg+xml":
        source = path
    pixbuf = None
    if source is not None:
        try:
            pixbuf = decode_thumb(source)
        except (GLib.Error, TypeError):
            pixbuf = None
    return Details(key, True, meta, pixbuf, info.get_symbolic_icon())


class DetailsLoader:
    """Loads Details on worker threads, with an LRU cache keyed by path,
    mtime, and size, so unchanged files are never decoded twice."""

    def __init__(self):
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=2, thread_name_prefix="shelf-thumb")
        self.cache = OrderedDict()
        self.waiting = {}  # path -> callbacks

    def request(self, path, callback):
        self.waiting.setdefault(path, []).append(callback)
        if len(self.waiting[path]) == 1:
            self.pool.submit(self._work, path)

    def _work(self, path):
        key = stat_key(path)
        details = self.cache.get(key)  # dict reads are safe across threads
        if details is None:
            try:
                details = load_details(key)
            except Exception as err:  # never lose the callback
                print(f"shelf: details for {path}: {err}", file=sys.stderr)
                details = Details(key, os.path.exists(path), pretty_dir(path))
        GLib.idle_add(self._deliver, path, details)

    def _deliver(self, path, details):
        if details.pixbuf is not None and details.texture is None:
            details.texture = pixbuf_texture(details.pixbuf)
            details.pixbuf = None
        self.cache[details.key] = details
        self.cache.move_to_end(details.key)
        while len(self.cache) > CACHE_SIZE:
            self.cache.popitem(last=False)
        for callback in self.waiting.pop(path, []):
            callback(details)
        return False

    def shutdown(self):
        self.pool.shutdown(wait=False, cancel_futures=True)


# --- cursor and output probe -------------------------------------------------

def monitors():
    model = Gdk.Display.get_default().get_monitors()
    return [model.get_item(i) for i in range(model.get_n_items())]


def hyprland_cursor():
    """(connector, x, y) in free-area coordinates, from hyprctl, or None."""
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"):
        return None
    try:
        pos = json.loads(subprocess.run(["hyprctl", "cursorpos", "-j"], capture_output=True,
                                        text=True, timeout=1).stdout)
        outputs = json.loads(subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True,
                                            text=True, timeout=1).stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    for m in outputs:
        scale = m.get("scale") or 1
        width, height = m["width"] / scale, m["height"] / scale
        if m.get("transform", 0) % 2:
            width, height = height, width
        if m["x"] <= pos["x"] < m["x"] + width and m["y"] <= pos["y"] < m["y"] + height:
            res_left, res_top = (list(m.get("reserved") or []) + [0, 0])[:2]  # left, top, right, bottom
            return (m["name"], pos["x"] - m["x"] - res_left, pos["y"] - m["y"] - res_top)
    return None


class Probe:
    """Finds the pointer and each output's free area.

    Wayland clients cannot read the global pointer position or the area left
    free by bars. So for a moment this maps two invisible layer surfaces per
    output, both covering it: a "free" one that keeps clear of bars (exclusive
    zone 0) and a "full" one beneath it that covers them too. The size the
    compositor gives the free surface is the free area. Whichever surface the
    pointer enters (or a drag moves over) tells where the pointer is: in
    free-area coordinates, or, when it is over a bar, in output coordinates.
    """

    def __init__(self, want_pointer, done):
        self.done = done
        self.want_pointer = want_pointer
        self.free = {}      # connector -> (width, height)
        self.pointer = None  # (connector, x, y, frame) with frame "free" or "full"
        self.pointer_at = 0
        self.windows = []
        self.finished = False
        targets = monitors()
        for monitor in targets:
            if want_pointer:
                self._surface(monitor, "full")
            self._surface(monitor, "free")
        self.started = GLib.get_monotonic_time()
        self.timer = GLib.timeout_add(8, self._poll)

    def _surface(self, monitor, frame):
        win = Gtk.Window(decorated=False)
        win.add_css_class("shelf-probe")
        LayerShell.init_for_window(win)
        LayerShell.set_namespace(win, "noctalia-shelf-probe")
        LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
        LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
        LayerShell.set_monitor(win, monitor)
        for edge in (LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT, LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM):
            LayerShell.set_anchor(win, edge, True)
        LayerShell.set_exclusive_zone(win, 0 if frame == "free" else -1)
        connector = monitor.get_connector()
        if self.want_pointer:
            def seen(_ctrl, x, y, *_):
                self._pointer(connector, x, y, frame)
            for ctrl in (Gtk.EventControllerMotion(), Gtk.DropControllerMotion()):
                ctrl.connect("enter", seen)
                ctrl.connect("motion", seen)
                win.add_controller(ctrl)
        win.connector = connector
        win.frame = frame
        win.present()
        self.windows.append(win)

    def _pointer(self, connector, x, y, frame):
        # The free surface is on top, so its reading wins when both arrive.
        if self.pointer is None or (frame == "free" and self.pointer[3] == "full"):
            self.pointer = (connector, x, y, frame)
            self.pointer_at = GLib.get_monotonic_time()

    def _poll(self):
        for win in self.windows:
            if win.frame == "free" and win.get_width() > 0 and win.get_height() > 0:
                self.free[win.connector] = (win.get_width(), win.get_height())
        sizes_known = len(self.free) == len([w for w in self.windows if w.frame == "free"])
        now = GLib.get_monotonic_time()
        if not self.want_pointer or (self.pointer is not None and self.pointer[3] == "free"):
            pointer_known = True
        else:
            # A reading from the full surface alone may just mean the free
            # one, on top, has not got the pointer yet. Give it a moment
            # before deciding the pointer is over a bar.
            pointer_known = self.pointer is not None and now - self.pointer_at > FULL_GRACE_MS * 1000
        timed_out = now - self.started > PROBE_TIMEOUT_MS * 1000
        if (sizes_known and pointer_known) or timed_out:
            self.timer = 0
            self.finish()
            return False
        return True

    def cancel(self):
        """Tears the probe down without reporting."""
        self.done = None
        self.finish()

    def finish(self):
        if self.finished:
            return
        self.finished = True
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = 0
        for win in self.windows:
            win.destroy()
        self.windows = []
        if self.done is not None:
            self.done(self)


# --- rows -------------------------------------------------------------------

class ShelfRow(Gtk.ListBoxRow):
    def __init__(self, window, path):
        super().__init__()
        self.path = path
        self.window = window
        self.details = None
        self.exists = True
        self.set_tooltip_text(path)

        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.set_child(box)

        self.thumb = Gtk.Box(width_request=THUMB, height_request=THUMB, valign=Gtk.Align.CENTER,
                             halign=Gtk.Align.CENTER, hexpand=False)
        self.thumb.add_css_class("row-thumb")
        self.thumb.set_overflow(Gtk.Overflow.HIDDEN)
        self._set_icon(Gio.ThemedIcon.new("text-x-generic-symbolic"))
        box.append(self.thumb)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1, hexpand=True, valign=Gtk.Align.CENTER)
        name = Gtk.Label(label=display_name(path), xalign=0)
        name.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        name.add_css_class("row-name")
        self.meta = Gtk.Label(label=pretty_dir(path), xalign=0)
        self.meta.set_ellipsize(Pango.EllipsizeMode.END)
        self.meta.add_css_class("row-meta")
        text.append(name)
        text.append(self.meta)
        box.append(text)

        remove = Gtk.Button(icon_name="window-close-symbolic", valign=Gtk.Align.CENTER)
        remove.add_css_class("shelf-icon")
        remove.add_css_class("danger")
        remove.add_css_class("row-remove")
        remove.set_tooltip_text("Remove from shelf")
        remove.connect("clicked", lambda *_: window.remove_paths([self.path]))
        box.append(remove)

        src = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        src.connect("prepare", self._on_prepare)
        src.connect("drag-begin", self._on_drag_begin)
        src.connect("drag-cancel", self._on_drag_cancel)
        src.connect("drag-end", self._on_drag_end)
        self.add_controller(src)
        self._drag_paths = []
        self._cancelled = False

    def refresh(self):
        self.window.loader.request(self.path, self.apply)

    def apply(self, details):
        if details is self.details:
            return
        self.details = details
        self.exists = details.exists
        self.meta.set_label(details.meta)
        if details.exists:
            self.remove_css_class("row-missing")
        else:
            self.add_css_class("row-missing")
        if details.texture is not None:
            self._set_child(Gtk.Image(paintable=details.texture, pixel_size=THUMB))
        elif not details.exists:
            self._set_icon(Gio.ThemedIcon.new("dialog-warning-symbolic"))
        else:
            self._set_icon(details.gicon or Gio.ThemedIcon.new("text-x-generic-symbolic"))

    def _set_icon(self, gicon):
        image = Gtk.Image(gicon=gicon, pixel_size=20, hexpand=True, halign=Gtk.Align.CENTER)
        image.add_css_class("row-thumb-icon")
        self._set_child(image)

    def _set_child(self, widget):
        child = self.thumb.get_first_child()
        if child is not None:
            self.thumb.remove(child)
        self.thumb.append(widget)

    def _on_prepare(self, source, x, y):
        paths = self.window.selected_paths()
        if self.path not in paths or len(paths) < 2:
            paths = [self.path]
        self._drag_paths = [p for p in paths if os.path.exists(p)]
        if not self._drag_paths:
            return None
        self.window.dragging_out = True
        return Gdk.ContentProvider.new_for_value(file_list(self._drag_paths))

    def _on_drag_begin(self, source, drag):
        self._cancelled = False
        Gtk.DragIcon.get_for_drag(drag).set_child(self.window.drag_pill(self._drag_paths))

    def _on_drag_cancel(self, source, drag, reason):
        self._cancelled = True
        self.window.dragging_out = False
        return False

    def _on_drag_end(self, source, drag, delete_data):
        self.window.dragging_out = False
        if not self._cancelled:
            self.window.after_drag_out(self._drag_paths)


# --- window -----------------------------------------------------------------

class ShelfWindow(Gtk.ApplicationWindow):
    def __init__(self, app, store, opts):
        super().__init__(application=app, title="Shelf")
        self.store = store
        self.opts = opts
        self.paths = []
        self.rows = {}
        self.loader = DetailsLoader()
        self.dragging_out = False
        self.store_dirty = True
        self._reload_source = 0
        self._probe = None
        self._grip_surface = None  # see _show_grip
        self.add_css_class("shelf-window")
        self.set_default_size(WINDOW_WIDTH, -1)
        self.set_resizable(False)
        self.set_decorated(False)
        self.set_hide_on_close(True)

        # Layer-shell placement: margins from the free area's top-left on one
        # output. None until placed.
        self.output = None
        self.margin = None
        self.free_size = None
        self._move = None
        self.wanted = False  # shown, or on its way

        if LayerShell is not None:
            LayerShell.init_for_window(self)
            LayerShell.set_namespace(self, "noctalia-shelf")
            # The top layer, so the grip surface (overlay layer) is always
            # above it whatever order the two map in.
            LayerShell.set_layer(self, LayerShell.Layer.TOP)
            LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.ON_DEMAND)
            LayerShell.set_exclusive_zone(self, 0)
            LayerShell.set_anchor(self, LayerShell.Edge.LEFT, True)
            LayerShell.set_anchor(self, LayerShell.Edge.TOP, True)

        overlay = Gtk.Overlay()
        self.set_child(overlay)

        self.card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        self.card.add_css_class("shelf-card")
        self.card.set_size_request(WINDOW_WIDTH - 24, -1)
        overlay.set_child(self.card)

        self.card.append(self._grip())
        self.card.append(self._header())

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.NONE, vhomogeneous=False)
        self.stack.add_named(self._empty_state(), "empty")

        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.MULTIPLE)
        self.listbox.add_css_class("shelf-list")
        self.listbox.set_activate_on_single_click(False)
        self.listbox.connect("row-activated", self._on_row_activated)
        self._selection_signal = self.listbox.connect("selected-rows-changed", lambda *_: self._update_header())
        self.scroller = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER)
        self.scroller.set_propagate_natural_height(True)
        self.scroller.set_max_content_height(LIST_MAX_HEIGHT)
        self.scroller.set_child(self.listbox)
        self.stack.add_named(self.scroller, "list")
        self.card.append(self.stack)

        self.hint = Gtk.Label(label="Drag to any app · Ctrl-click to pick several", xalign=0.5,
                              wrap=True, justify=Gtk.Justification.CENTER)
        self.hint.add_css_class("shelf-hint")
        self.card.append(self.hint)

        self.banner = Gtk.Label(label="Drop to add to shelf", halign=Gtk.Align.CENTER, valign=Gtk.Align.END)
        self.banner.add_css_class("drop-banner")
        self.banner.set_visible(False)
        self.banner.set_can_target(False)
        overlay.add_overlay(self.banner)

        # Async target: file managers such as Nautilus often offer only MOVE,
        # which a COPY-only Gtk.DropTarget refuses. Accept any action, read the
        # file list ourselves, and always finish the drop as COPY so the source
        # never deletes the file.
        drop = Gtk.DropTargetAsync.new(None, Gdk.DragAction.COPY | Gdk.DragAction.MOVE | Gdk.DragAction.LINK)
        drop.connect("accept", self._on_drop_accept)
        drop.connect("drag-enter", self._on_drop_enter)
        drop.connect("drag-motion", lambda *_: Gdk.DragAction.COPY)
        drop.connect("drag-leave", self._on_drop_leave)
        drop.connect("drop", self._on_drop)
        overlay.add_controller(drop)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

        self._monitor = Gio.File.new_for_path(store).monitor_file(Gio.FileMonitorFlags.WATCH_MOVES, None)
        self._monitor.connect("changed", self._on_store_changed)

    # header / empty state

    def _header(self):
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        # The title area moves the window too. It holds only the title and
        # count, so it never competes with the "Drag all" source or buttons.
        titles = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8, hexpand=True)
        title = Gtk.Label(label="Shelf", xalign=0)
        title.add_css_class("shelf-title")
        titles.append(title)
        self.count = Gtk.Label(valign=Gtk.Align.CENTER)
        self.count.add_css_class("shelf-count")
        titles.append(self.count)
        self._make_movable(titles)
        self.titles = titles
        row.append(titles)

        # "Drag all" pill: a drag source, not a button, so a press-and-drag
        # carries every file (or the selection) out in one go.
        pill = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6, valign=Gtk.Align.CENTER)
        pill.add_css_class("shelf-drag-all")
        pill.append(Gtk.Image(icon_name="drag-handle-symbolic", pixel_size=14))
        self.drag_all_label = Gtk.Label(label="Drag all")
        pill.append(self.drag_all_label)
        pill.set_cursor(Gdk.Cursor.new_from_name("grab", None))
        pill.set_tooltip_text("Drag every file on the shelf into another app")
        src = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        src.connect("prepare", self._on_all_prepare)
        src.connect("drag-begin", self._on_all_begin)
        src.connect("drag-cancel", self._on_all_cancel)
        src.connect("drag-end", self._on_all_end)
        pill.add_controller(src)
        self.drag_all = pill
        self._all_paths = []
        self._all_cancelled = False
        row.append(pill)

        self.clear_btn = Gtk.Button(icon_name="edit-delete-symbolic", valign=Gtk.Align.CENTER)
        self.clear_btn.add_css_class("shelf-icon")
        self.clear_btn.add_css_class("danger")
        self.clear_btn.set_tooltip_text("Clear shelf")
        self.clear_btn.connect("clicked", lambda *_: self.clear())
        row.append(self.clear_btn)

        close = Gtk.Button(icon_name="window-close-symbolic", valign=Gtk.Align.CENTER)
        close.add_css_class("shelf-icon")
        close.set_tooltip_text("Close (Esc)")
        close.connect("clicked", lambda *_: self.dismiss())
        row.append(close)
        return row

    def _grip(self):
        """Full-width strip with a centred 3x2 dot grip; drag it to move."""
        strip = Gtk.Box(hexpand=True)
        strip.add_css_class("shelf-grip")
        dots = Gtk.Grid(row_spacing=4, column_spacing=5, halign=Gtk.Align.CENTER, hexpand=True)
        for row in range(2):
            for col in range(3):
                dot = Gtk.Box()
                dot.add_css_class("shelf-grip-dot")
                dots.attach(dot, col, row, 1, 1)
        strip.append(dots)
        self._make_movable(strip)
        self.grip_strip = strip
        return strip

    def _empty_state(self):
        zone = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        zone.add_css_class("shelf-dropzone")
        icon = Gtk.Image(icon_name="folder-download-symbolic", pixel_size=36)
        icon.add_css_class("shelf-dropzone-icon")
        zone.append(icon)
        title = Gtk.Label(label="Drop files here")
        title.add_css_class("shelf-dropzone-title")
        zone.append(title)
        sub = Gtk.Label(label="Files wait here until you drag them out.\nCtrl+V pastes copied files.",
                        justify=Gtk.Justification.CENTER, wrap=True)
        sub.add_css_class("shelf-sub")
        zone.append(sub)
        return zone

    # show / hide

    def reveal(self):
        """Shows the window, placing it first when layer shell is in use."""
        self.wanted = True
        if self.store_dirty:
            self.reload()
        for row in self.rows.values():
            row.refresh()  # pick up files deleted or changed while hidden
        if self.get_visible():
            if LayerShell is not None and self.opts["position"] == "cursor":
                self._place()  # follow the pointer when asked to open again
            self.present()
            return
        if self._probe is not None:
            return  # already on its way
        if LayerShell is None:
            self._present()
            return
        self._place(then=self._present)

    def _present(self):
        self.present()
        if self.paths:
            self.listbox.grab_focus()
        self._show_grip()

    def dismiss(self):
        self.wanted = False
        if self._probe is not None:
            self._probe.cancel()
            self._probe = None
        self._hide_grip()
        self.set_visible(False)

    # placement (layer shell only)

    def _place(self, then=None):
        position = self.opts["position"]
        saved = load_position(self.store) if position == "last" else None
        want_pointer = position == "cursor" or (position == "last" and saved is None)

        def placed(probe):
            self._probe = None
            self._apply_placement(probe, position, saved)
            if then is not None:
                then()
            elif self.get_visible():
                self._show_grip()  # it may be on another output now

        if self._probe is not None:
            self._probe.cancel()
        hypr = hyprland_cursor() if want_pointer else None
        self._probe = Probe(want_pointer and hypr is None, placed)
        if hypr is not None:
            self._probe.pointer = (hypr[0], hypr[1], hypr[2], "free")

    def _apply_placement(self, probe, position, saved):
        outputs = {m.get_connector(): m for m in monitors()}
        if not outputs:
            return
        connector = None
        if probe.pointer is not None and probe.pointer[0] in outputs:
            connector = probe.pointer[0]
        elif saved is not None and saved.get("output") in outputs:
            connector = saved["output"]
        elif self.output in outputs:
            connector = self.output
        else:
            connector = next(iter(outputs))
        monitor = outputs[connector]
        geo = monitor.get_geometry()
        free_w, free_h = probe.free.get(connector, (geo.width, geo.height))
        w, h = self._size()

        if position == "last" and saved is not None and saved.get("output") == connector:
            left, top = saved.get("left", 0), saved.get("top", 0)
        elif probe.pointer is not None and probe.pointer[0] == connector:
            _, x, y, frame = probe.pointer
            if frame == "full":
                # Over a bar, in output coordinates. Assume the reserved
                # strip is on the side the pointer is nearest, and map into
                # free-area coordinates; the clamp below does the rest.
                if x < geo.width / 2:
                    x -= geo.width - free_w
                if y < geo.height / 2:
                    y -= geo.height - free_h
            left, top = x - w / 2, y - h / 2
        else:
            left, top = preset_origin(position, free_w, free_h, w, h)

        self.output = connector
        self.free_size = (free_w, free_h)
        LayerShell.set_monitor(self, monitor)
        self._set_margin(left, top)

    def _size(self):
        # The window is not resizable, so its size is its natural size, which
        # is current even before the next frame allocates it.
        _, w, _, _ = self.measure(Gtk.Orientation.HORIZONTAL, -1)
        w = max(w, WINDOW_WIDTH)
        _, h, _, _ = self.measure(Gtk.Orientation.VERTICAL, w)
        return w, h

    def _set_margin(self, left, top):
        if LayerShell is None:
            return
        w, h = self._size()
        free_w, free_h = self.free_size or (w, h)
        left = int(max(0, min(left, free_w - w)))
        top = int(max(0, min(top, free_h - h)))
        if self.margin != (left, top):
            self.margin = (left, top)
            LayerShell.set_margin(self, LayerShell.Edge.LEFT, left)
            LayerShell.set_margin(self, LayerShell.Edge.TOP, top)
            self._sync_grip()

    def _reclamp(self):
        # The window grew or shrank; keep it inside the free area.
        if self.margin is not None and self._move is None:
            self._set_margin(*self.margin)
        self._sync_grip()
        return False

    # grip surface
    #
    # Pressing on the window and moving it under the pointer makes the
    # pointer's position on the window a moving target. So while the window
    # is shown, an invisible surface covers the output's free area above it,
    # taking input only over the grip and title. A press there keeps the
    # pointer on that surface, which never moves: its coordinates are the
    # free-area coordinates the window's margins use, and it can show a
    # grabbing hand while moving. (A drag-and-drop would hand the cursor to
    # the compositor.) Without pycairo, the widgets' own drag-and-drop move
    # is the fallback.

    def _show_grip(self):
        self._hide_grip()
        if LayerShell is None or cairo is None or self.output is None:
            return
        monitor = next((m for m in monitors() if m.get_connector() == self.output), None)
        if monitor is None:
            return
        win = Gtk.Window(decorated=False)
        win.add_css_class("shelf-probe")
        LayerShell.init_for_window(win)
        LayerShell.set_namespace(win, "noctalia-shelf-grip")
        LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
        LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
        LayerShell.set_monitor(win, monitor)
        for edge in (LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT, LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM):
            LayerShell.set_anchor(win, edge, True)
        LayerShell.set_exclusive_zone(win, 0)
        area = Gtk.Box(hexpand=True, vexpand=True)
        area.set_cursor(Gdk.Cursor.new_from_name("grab", None))
        win.set_child(area)
        hover = Gtk.EventControllerMotion()
        hover.connect("enter", lambda *_: self.card.add_css_class("grip-hover"))
        hover.connect("leave", lambda *_: self.card.remove_css_class("grip-hover"))
        win.add_controller(hover)
        gesture = Gtk.GestureDrag()
        gesture.connect("drag-begin", self._on_grip_begin)
        gesture.connect("drag-update", self._on_grip_update)
        gesture.connect("drag-end", self._on_grip_end)
        win.add_controller(gesture)
        # Start with no input at all, so it can never block the screen, then
        # aim it once the window is laid out.
        win.connect("realize", lambda w: (w.get_surface().set_input_region(cairo.Region()), self._sync_grip()))
        win.area = area
        self._grip_surface = win
        win.present()
        GLib.timeout_add(60, lambda: self._sync_grip() and False)

    def _hide_grip(self):
        win, self._grip_surface = self._grip_surface, None
        if win is not None:
            win.destroy()
        self.card.remove_css_class("grip-hover")

    def _sync_grip(self):
        """Points the grip surface's input region at the grip and title."""
        win = self._grip_surface
        if win is None or self.margin is None or win.get_surface() is None:
            return
        left, top = self.margin
        ok, title = self.titles.compute_bounds(self)
        if not ok:
            return
        # One solid block, so there is no dead gap: the full width from the
        # window's top edge down to where the title starts (grip strip and
        # the space under it), then the title row up to the buttons.
        title_top = int(title.get_y())
        title_right = int(title.get_x() + title.get_width())
        title_bottom = int(title.get_y() + title.get_height())
        rects = [
            cairo.RectangleInt(left, top, self.get_width(), title_top),
            cairo.RectangleInt(left, top + title_top, title_right, title_bottom - title_top),
        ]
        win.get_surface().set_input_region(cairo.Region(rects))
        # The region is sent with the next commit, and an invisible surface
        # never redraws on its own.
        win.area.queue_draw()

    def _on_grip_begin(self, gesture, x, y):
        if self.margin is None:
            gesture.set_state(Gtk.EventSequenceState.DENIED)
            return
        gesture.set_state(Gtk.EventSequenceState.CLAIMED)
        left, top = self.margin
        self._move = {"grab": (x - left, y - top), "surfaces": []}
        self._grip_surface.area.set_cursor(Gdk.Cursor.new_from_name("grabbing", None))
        self.card.add_css_class("moving")

    def _on_grip_update(self, gesture, dx, dy):
        if self._move is None:
            return
        ok, sx, sy = gesture.get_start_point()
        if ok:
            gx, gy = self._move["grab"]
            self._set_margin(sx + dx - gx, sy + dy - gy)

    def _on_grip_end(self, gesture, dx, dy):
        if self._grip_surface is not None:
            self._grip_surface.area.set_cursor(Gdk.Cursor.new_from_name("grab", None))
        self._on_move_end(None, None, False)

    # moving

    def _make_movable(self, widget):
        widget.set_cursor(Gdk.Cursor.new_from_name("grab", None))
        widget.set_tooltip_text("Drag to move")
        if LayerShell is None:
            # A plain toplevel: let the compositor move it.
            gesture = Gtk.GestureDrag()
            gesture.connect("drag-begin", self._on_toplevel_move)
            widget.add_controller(gesture)
            return
        # A layer surface cannot be moved by the compositor, and reading the
        # pointer off the window while the window itself moves is a feedback
        # loop. So moving is a drag-and-drop with an invisible icon: while it
        # runs, an invisible surface covers each output's free area and the
        # drag reports the pointer there, in the same coordinates the window's
        # margins use. The window goes straight to pointer minus grab point.
        src = Gtk.DragSource(actions=Gdk.DragAction.MOVE)
        src.connect("prepare", self._on_move_prepare)
        src.connect("drag-begin", self._on_move_begin)
        src.connect("drag-cancel", lambda *_: False)
        src.connect("drag-end", self._on_move_end)
        widget.add_controller(src)

    def _on_toplevel_move(self, gesture, x, y):
        surface = self.get_surface()
        point = to_window(gesture.get_widget(), self, x, y)
        if surface is not None and point is not None:
            surface.begin_move(gesture.get_device(), gesture.get_current_button(), point[0], point[1],
                               gesture.get_current_event_time())
        gesture.reset()

    def _on_move_prepare(self, source, x, y):
        if self.margin is None:
            return None
        point = to_window(source.get_widget(), self, x, y)
        if point is None:
            return None
        self._move = {"grab": point, "surfaces": []}
        return Gdk.ContentProvider.new_for_bytes(MOVE_MIME, GLib.Bytes.new(b"move"))

    def _on_move_begin(self, source, drag):
        Gtk.DragIcon.get_for_drag(drag).set_child(Gtk.Box())  # no visible icon
        self.card.add_css_class("moving")
        if self._move is None:
            return
        for monitor in monitors():
            self._move["surfaces"].append(self._move_surface(monitor))

    def _move_surface(self, monitor):
        win = Gtk.Window(decorated=False)
        win.add_css_class("shelf-probe")
        LayerShell.init_for_window(win)
        LayerShell.set_namespace(win, "noctalia-shelf-probe")
        LayerShell.set_layer(win, LayerShell.Layer.OVERLAY)
        LayerShell.set_keyboard_mode(win, LayerShell.KeyboardMode.NONE)
        LayerShell.set_monitor(win, monitor)
        for edge in (LayerShell.Edge.LEFT, LayerShell.Edge.RIGHT, LayerShell.Edge.TOP, LayerShell.Edge.BOTTOM):
            LayerShell.set_anchor(win, edge, True)
        LayerShell.set_exclusive_zone(win, 0)
        connector = monitor.get_connector()

        def moved(_ctrl, x, y):
            self._move_to(monitor, connector, win, x, y)

        # Only "motion": "enter" can report 0,0 before the first real
        # position, which would flash the window to the corner.
        motion = Gtk.DropControllerMotion()
        motion.connect("motion", moved)
        win.add_controller(motion)
        # Accept the drop so it ends cleanly instead of snapping back.
        target = Gtk.DropTargetAsync.new(Gdk.ContentFormats.new([MOVE_MIME]), Gdk.DragAction.MOVE)
        target.connect("drag-enter", lambda *_: Gdk.DragAction.MOVE)
        target.connect("drag-motion", lambda *_: Gdk.DragAction.MOVE)
        target.connect("drop", lambda _t, drop, *_: (drop.finish(Gdk.DragAction.MOVE), True)[1])
        win.add_controller(target)
        win.present()
        return win

    def _move_to(self, monitor, connector, surface, x, y):
        if self._move is None:
            return
        if connector != self.output:
            self.output = connector
            LayerShell.set_monitor(self, monitor)
        if surface.get_width() > 0:
            self.free_size = (surface.get_width(), surface.get_height())
        gx, gy = self._move["grab"]
        self._set_margin(x - gx, y - gy)

    def _on_move_end(self, source, drag, delete_data):
        self.card.remove_css_class("moving")
        move, self._move = self._move, None
        if move is None:
            return
        for win in move["surfaces"]:
            win.destroy()
        if self.margin is not None and self.output is not None:
            save_position(self.store, {"output": self.output, "left": self.margin[0], "top": self.margin[1]})

    # data

    def _on_store_changed(self, *_):
        self.store_dirty = True
        if not self.get_visible():
            return  # reload once on the next show
        if self._reload_source:
            GLib.source_remove(self._reload_source)
        self._reload_source = GLib.timeout_add(40, self._reload_timeout)

    def _reload_timeout(self):
        self._reload_source = 0
        self.reload()
        return False

    def reload(self):
        paths = read_store(self.store)
        if paths is None:
            paths = [] if not os.path.exists(self.store) else self.paths
        self.store_dirty = False
        self.show_paths(paths)

    def show_paths(self, paths):
        """Makes the list show paths, reusing the rows it already has."""
        paths = list(dict.fromkeys(paths))
        if paths == self.paths:
            self._update_header()
            return
        selected = set(self.selected_paths())
        scroll = self.scroller.get_vadjustment().get_value()
        self.listbox.handler_block(self._selection_signal)
        try:
            old = self.rows
            self.rows = {}
            for p in paths:
                row = old.pop(p, None)
                if row is None:
                    row = ShelfRow(self, p)
                    row.refresh()
                self.rows[p] = row
            for row in old.values():
                self.listbox.remove(row)
            # Reorder only when the order changed, by moving rows into place.
            current = []
            child = self.listbox.get_first_child()
            while child is not None:
                current.append(child)
                child = child.get_next_sibling()
            wanted = [self.rows[p] for p in paths]
            if current != wanted:
                for i, row in enumerate(wanted):
                    if row.get_parent() is self.listbox:
                        if row.get_index() == i:
                            continue
                        self.listbox.remove(row)
                    self.listbox.insert(row, i)
            for p, row in self.rows.items():
                if p in selected:
                    self.listbox.select_row(row)
        finally:
            self.listbox.handler_unblock(self._selection_signal)
        self.paths = list(paths)
        self.stack.set_visible_child_name("list" if self.paths else "empty")
        self.scroller.get_vadjustment().set_value(scroll)
        self._update_header()
        GLib.idle_add(self._reclamp)

    def _update_header(self):
        n = len(self.paths)
        self.count.set_label(str(n))
        self.count.set_visible(n > 0)
        sel = len(self.listbox.get_selected_rows())
        self.drag_all.set_visible(n > 0)
        self.drag_all_label.set_label(f"Drag {sel}" if sel > 1 else "Drag all")
        self.clear_btn.set_visible(n > 0)
        self.hint.set_visible(n > 0)
        if self._grip_surface is not None:
            GLib.idle_add(lambda: self._sync_grip() and False)  # the title may have changed width

    def selected_paths(self):
        return [r.path for r in self.listbox.get_selected_rows()]

    def add_paths(self, paths):
        paths = [p for p in paths if p]
        if paths:
            emit("add", paths=paths)

    def remove_paths(self, paths):
        if paths:
            emit("remove", paths=paths)
            # Show it now; the store change that follows confirms it.
            drop = set(paths)
            self.show_paths([p for p in self.paths if p not in drop])

    def clear(self):
        emit("clear")
        self.show_paths([])

    def after_drag_out(self, paths):
        if self.opts["remove_after_drag"]:
            self.remove_paths(paths)
        if self.opts["close_after_drag"]:
            self.dismiss()

    def drag_pill(self, paths):
        pill = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        pill.add_css_class("drag-pill")
        pill.append(Gtk.Image(icon_name="emblem-documents-symbolic", pixel_size=14))
        label = display_name(paths[0]) if len(paths) == 1 else f"{len(paths)} files"
        pill.append(Gtk.Label(label=label))
        return pill

    # drag all

    def _on_all_prepare(self, source, x, y):
        sel = self.selected_paths()
        paths = sel if len(sel) > 1 else self.paths
        self._all_paths = [p for p in paths if os.path.exists(p)]
        if not self._all_paths:
            return None
        self.dragging_out = True
        return Gdk.ContentProvider.new_for_value(file_list(self._all_paths))

    def _on_all_begin(self, source, drag):
        self._all_cancelled = False
        Gtk.DragIcon.get_for_drag(drag).set_child(self.drag_pill(self._all_paths))

    def _on_all_cancel(self, source, drag, reason):
        self._all_cancelled = True
        self.dragging_out = False
        return False

    def _on_all_end(self, source, drag, delete_data):
        self.dragging_out = False
        if not self._all_cancelled:
            self.after_drag_out(self._all_paths)

    # drop in

    def _on_drop_accept(self, target, drop):
        # Ignore our own drags so dragging a row across the window is a no-op.
        if (self.dragging_out or self._move is not None) and drop.get_drag() is not None:
            return False
        # Other apps offer MIME types, not the GdkFileList GType, so check
        # both. GTK deserializes either into a GdkFileList for the drop handler.
        formats = drop.get_formats()
        return (formats.contain_gtype(Gdk.FileList)
                or formats.contain_mime_type("text/uri-list")
                or formats.contain_mime_type("application/vnd.portal.filetransfer"))

    def _on_drop_enter(self, target, drop, x, y):
        self.card.add_css_class("drop-hover")
        self.banner.set_visible(bool(self.paths))
        return Gdk.DragAction.COPY

    def _on_drop_leave(self, target, drop=None):
        self.card.remove_css_class("drop-hover")
        self.banner.set_visible(False)

    def _on_drop(self, target, drop, x, y):
        self._on_drop_leave(target)

        def done(source, result):
            try:
                value = source.read_value_finish(result)
            except GLib.Error as err:
                print(f"shelf: could not read dropped files: {err.message}", file=sys.stderr)
                source.finish(0)
                return
            self.add_paths([f.get_path() for f in value.get_files() if f.get_path()])
            source.finish(Gdk.DragAction.COPY)

        drop.read_value_async(Gdk.FileList, GLib.PRIORITY_DEFAULT, None, done)
        return True

    # misc input

    def _on_row_activated(self, listbox, row):
        if os.path.exists(row.path):
            try:
                Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(row.path).get_uri(), None)
            except GLib.Error as err:
                print(f"shelf: cannot open {row.path}: {err.message}", file=sys.stderr)

    def _on_key(self, ctrl, keyval, keycode, state):
        ctrl_down = bool(state & Gdk.ModifierType.CONTROL_MASK)
        if keyval == Gdk.KEY_Escape:
            self.dismiss()
            return True
        if keyval in (Gdk.KEY_Delete, Gdk.KEY_BackSpace) and self.selected_paths():
            self.remove_paths(self.selected_paths())
            return True
        if ctrl_down and keyval in (Gdk.KEY_a, Gdk.KEY_A):
            self.listbox.select_all()
            return True
        if ctrl_down and keyval in (Gdk.KEY_c, Gdk.KEY_C):
            self._copy()
            return True
        if ctrl_down and keyval in (Gdk.KEY_v, Gdk.KEY_V):
            self._paste()
            return True
        return False

    def _copy(self):
        paths = [p for p in (self.selected_paths() or self.paths) if os.path.exists(p)]
        if not paths:
            return
        uris = [Gio.File.new_for_path(p).get_uri() for p in paths]
        gnome = ("copy\n" + "\n".join(uris)).encode()
        provider = Gdk.ContentProvider.new_union([
            Gdk.ContentProvider.new_for_value(file_list(paths)),
            Gdk.ContentProvider.new_for_bytes("x-special/gnome-copied-files", GLib.Bytes.new(gnome)),
            Gdk.ContentProvider.new_for_bytes("text/uri-list",
                                              GLib.Bytes.new(("\r\n".join(uris) + "\r\n").encode())),
        ])
        self.get_display().get_clipboard().set_content(provider)

    def _paste(self):
        clipboard = self.get_display().get_clipboard()

        def done(cb, result):
            try:
                value = cb.read_value_finish(result)
            except GLib.Error:
                cb.read_text_async(None, text_done)
                return
            if value is not None:
                self.add_paths([f.get_path() for f in value.get_files() if f.get_path()])

        def text_done(cb, result):
            try:
                text = cb.read_text_finish(result) or ""
            except GLib.Error:
                return
            self.add_paths(paths_from_text(text))

        clipboard.read_value_async(Gdk.FileList, GLib.PRIORITY_DEFAULT, None, done)


# --- saved position ---------------------------------------------------------

def position_file(store):
    return os.path.join(os.path.dirname(store), "window.json")


def load_position(store):
    try:
        with open(position_file(store), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and isinstance(data.get("left"), (int, float)) and isinstance(data.get("top"), (int, float)):
        return data
    return None


def save_position(store, data):
    path = position_file(store)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except OSError as err:
        print(f"shelf: cannot save window position: {err}", file=sys.stderr)


def preset_origin(position, free_w, free_h, w, h):
    gap = EDGE_GAP
    x = {"left": gap, "top_left": gap, "bottom_left": gap,
         "right": free_w - w - gap, "top_right": free_w - w - gap, "bottom_right": free_w - w - gap}
    y = {"top": gap, "top_left": gap, "top_right": gap,
         "bottom": free_h - h - gap, "bottom_left": free_h - h - gap, "bottom_right": free_h - h - gap}
    return x.get(position, (free_w - w) / 2), y.get(position, (free_h - h) / 2)


# --- application ------------------------------------------------------------

class ShelfApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.window = None
        self.provider = None
        self.colors = None
        self._idle_source = 0
        for name, ptype, handler in (("show", "s", self._act_show), ("toggle", "s", self._act_toggle),
                                     ("configure", "s", self._act_configure), ("hide", None, self._act_hide),
                                     ("quit", None, self._act_quit)):
            action = Gio.SimpleAction.new(name, GLib.VariantType.new(ptype) if ptype else None)
            action.connect("activate", handler)
            self.add_action(action)

    # entry points

    def do_command_line(self, command_line):
        args = parse_args(command_line.get_arguments()[1:])
        opts = parse_options(args.options)
        if self.window is None:
            # First instance: --toggle opens, --hide starts hidden.
            self._start(args.store, opts)
            if not args.hide:
                self.window.reveal()
            return 0
        self._configure(opts)
        if args.hide or (args.toggle and self.window.wanted):
            self.window.dismiss()
        else:
            self.window.reveal()
        return 0

    def _start(self, store, opts):
        self.hold()  # stay alive while the window is hidden
        self._configure(opts)
        self.window = ShelfWindow(self, store, opts)
        self.window.connect("notify::visible", self._on_visible)
        self._on_visible(self.window, None, announce=False)
        self._watch_stdout()
        for signum in (signal.SIGTERM, signal.SIGINT):
            unix_signal_add(GLib.PRIORITY_DEFAULT, signum, self._act_quit)
        emit("ready", layer_shell=LayerShell is not None)

    def _watch_stdout(self):
        # When the service goes away, the read end of our stdout closes. Quit
        # then, rather than keep a window whose actions go nowhere.
        try:
            channel = GLib.IOChannel.unix_new(sys.stdout.fileno())
        except (OSError, ValueError):
            return
        GLib.io_add_watch(channel, GLib.PRIORITY_DEFAULT, GLib.IOCondition.ERR | GLib.IOCondition.HUP,
                          lambda *_: (self.quit(), False)[1])

    def _configure(self, opts):
        if self.window is not None:
            self.window.opts = opts
        colors = load_colors(opts["colors"])
        if colors == self.colors:
            return
        self.colors = colors
        if self.provider is None:
            self.provider = Gtk.CssProvider()
            Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), self.provider,
                                                      Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self.provider.load_from_string(build_css(colors))

    def _on_visible(self, window, _pspec, announce=True):
        if not window.get_visible() and window._probe is None:
            window.wanted = False  # hidden by the compositor or close-request
        if announce:
            emit("shown" if window.get_visible() else "hidden")
        if self._idle_source:
            GLib.source_remove(self._idle_source)
            self._idle_source = 0
        if not window.get_visible():
            self._idle_source = GLib.timeout_add_seconds(IDLE_QUIT_S, self._idle_quit)

    def _idle_quit(self):
        self._idle_source = 0
        self._act_quit()
        return False

    # D-Bus actions

    def _act_show(self, _action=None, param=None):
        if self.window is not None:
            self._configure(parse_options(param.get_string() if param else ""))
            self.window.reveal()

    def _act_toggle(self, _action=None, param=None):
        if self.window is None:
            return
        if self.window.wanted:
            self.window.dismiss()
        else:
            self._act_show(None, param)

    def _act_configure(self, _action=None, param=None):
        self._configure(parse_options(param.get_string() if param else ""))

    def _act_hide(self, *_):
        if self.window is not None:
            self.window.dismiss()

    def _act_quit(self, *_):
        if self.window is not None:
            self.window.loader.shutdown()
        emit("bye")
        self.quit()
        return GLib.SOURCE_REMOVE


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="shelf-window")
    parser.add_argument("--store", required=True, help="path of the plugin's shelf.json")
    parser.add_argument("--options", default="", help="JSON object: position, remove_after_drag, "
                        "close_after_drag, colors (palette role to #rrggbb)")
    parser.add_argument("--toggle", action="store_true", help="close the running window instead of raising it")
    parser.add_argument("--hide", action="store_true", help="start hidden, or hide the running window")
    return parser.parse_args(argv)


def main():
    parse_args(sys.argv[1:])  # fail fast on bad arguments, before GTK starts
    app = ShelfApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
