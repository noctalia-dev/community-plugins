#!/usr/bin/env python3
"""DropWall helper: transparent layer-shell drop targets, one per monitor.

Owned by dropwall_supervisor.py, which keeps one worker attached to the single
stream opened by the DropWall Noctalia service.

Protocol, one line per event on stdout:
  READY\t<n>                           n drop surfaces created
  ALIVE                               heartbeat for stream/orphan detection
  DROP\t<x>\t<y>\t<w>\t<h>\t<pid>\t<path>    image dropped; path is percent-encoded
  INVALID\t<path>                     unsupported filename extension
  MISSING\t<path>                     dropped path is not a regular file
  ERR\t<message>                      non-fatal problem
"""

import argparse
import ctypes
import fcntl
import os
import signal
import stat
import sys
import threading
import urllib.parse

# Python ignores SIGPIPE by default. Restoring the Unix behavior makes an
# orphaned helper exit on its next heartbeat when Noctalia closes the stream.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

try:
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    gi.require_version("GtkLayerShell", "0.1")
    from gi.repository import Gdk, GLib, Gtk, GtkLayerShell  # noqa: E402
except (ImportError, ValueError) as error:
    message = str(error).replace("\n", " ")
    print("ERR\tGTK dependencies could not be loaded: %s" % message, flush=True)
    raise SystemExit(2)

CSS = b"""
window { background-color: rgba(0, 0, 0, 0); }
.dropzone {
  background-color: rgba(0, 0, 0, 0);
  border: 3px dashed rgba(0, 0, 0, 0);
  border-radius: 18px;
  margin: 14px;
  transition: background-color 150ms ease, border-color 150ms ease;
}
.dropzone.hover {
  background-color: rgba(128, 128, 128, 0.16);
  border-color: rgba(255, 255, 255, 0.55);
}
"""

LAYERS = {
    "background": GtkLayerShell.Layer.BACKGROUND,
    "bottom": GtkLayerShell.Layer.BOTTOM,
}

VALID_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "bmp", "gif"}
HEARTBEAT_SECONDS = 5
EMIT_LOCK = threading.Lock()
INSTANCE_LOCK = None


def emit(line):
    with EMIT_LOCK:
        print(line, flush=True)


def arm_parent_death_signal():
    """Ask Linux to terminate us if the process that spawned us disappears."""
    parent = os.getppid()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0:  # PR_SET_PDEATHSIG
            return
        # Close the small race where the parent dies immediately before prctl.
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGTERM)
    except (AttributeError, OSError):
        # The heartbeat/SIGPIPE path remains the portable fallback.
        return


def acquire_instance_lock():
    """Keep at most one DropWall target alive in this user session."""
    global INSTANCE_LOCK

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        emit("ERR\tXDG_RUNTIME_DIR is not set")
        return False

    lock_path = os.path.join(runtime_dir, "noctalia-dropwall.lock")
    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)

    try:
        fd = os.open(lock_path, flags, 0o600)
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or not stat.S_ISREG(info.st_mode):
            raise PermissionError("unsafe lock file")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        emit("BUSY\tanother DropWall helper is already running")
        return False
    except OSError as error:
        if "fd" in locals():
            os.close(fd)
        emit("ERR\tcould not acquire the runtime lock: %s" % error)
        return False

    INSTANCE_LOCK = os.fdopen(fd, "w", encoding="ascii")
    INSTANCE_LOCK.write("%d\n" % os.getpid())
    INSTANCE_LOCK.flush()
    return True


def selection_to_path(data):
    """Extract the first local file path from a drop's selection data."""
    uris = list(data.get_uris() or [])
    if not uris:
        text = data.get_text()
        if text:
            uris = [part for part in text.split("\n") if part.strip()]
    for uri in uris:
        uri = uri.strip()
        if uri.startswith("file://"):
            parsed = urllib.parse.urlsplit(uri)
            if parsed.netloc not in ("", "localhost"):
                continue
            path = os.fsdecode(urllib.parse.unquote_to_bytes(parsed.path))
        if uri.startswith("/"):
            path = uri
        elif not uri.startswith("file://"):
            continue
        if "\0" not in path and os.path.isabs(path):
            return path
    return None


def encode_path(path):
    """Encode filesystem bytes as ASCII so filenames cannot forge events."""
    return urllib.parse.quote_from_bytes(os.fsencode(path), safe="")


def process_drop(path, geometry):
    """Validate a drop away from the GTK event loop, then report it."""
    encoded_path = encode_path(path)
    try:
        info = os.stat(path)
    except (OSError, ValueError):
        emit("MISSING\t%s" % encoded_path)
        return
    if not stat.S_ISREG(info.st_mode):
        emit("MISSING\t%s" % encoded_path)
        return

    extension = os.path.splitext(path)[1].lower().lstrip(".")
    if extension not in VALID_EXTENSIONS:
        emit("INVALID\t%s" % encoded_path)
        return

    encoded_path = encode_path(path)
    x, y, width, height = geometry
    emit("DROP\t%d\t%d\t%d\t%d\t%d\t%s" % (x, y, width, height, os.getpid(), encoded_path))


class DropWindow(Gtk.Window):
    def __init__(self, monitor, layer):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.monitor = monitor

        visual = self.get_screen().get_rgba_visual()
        if visual is not None:
            self.set_visual(visual)

        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, layer)
        GtkLayerShell.set_monitor(self, monitor)
        GtkLayerShell.set_namespace(self, "dropwall")
        for edge in (
            GtkLayerShell.Edge.LEFT,
            GtkLayerShell.Edge.RIGHT,
            GtkLayerShell.Edge.TOP,
            GtkLayerShell.Edge.BOTTOM,
        ):
            GtkLayerShell.set_anchor(self, edge, True)
        # Cover the full output, including space reserved by bars/docks.
        GtkLayerShell.set_exclusive_zone(self, -1)

        self.zone = Gtk.Box()
        self.zone.get_style_context().add_class("dropzone")
        self.add(self.zone)

        self.drag_dest_set(Gtk.DestDefaults.ALL, [], Gdk.DragAction.COPY)
        self.drag_dest_add_uri_targets()
        self.drag_dest_add_text_targets()
        self.connect("drag-motion", self.on_drag_motion)
        self.connect("drag-leave", self.on_drag_leave)
        self.connect("drag-data-received", self.on_drag_data_received)

        self.show_all()

    def on_drag_motion(self, _widget, _context, _x, _y, _time):
        self.zone.get_style_context().add_class("hover")
        return False  # let the default DestDefaults handler ack the drag

    def on_drag_leave(self, _widget, _context, _time):
        self.zone.get_style_context().remove_class("hover")

    def on_drag_data_received(self, _widget, _context, _x, _y, data, _info, _time):
        self.zone.get_style_context().remove_class("hover")
        path = selection_to_path(data)
        if not path:
            emit("ERR\tdrop carried no usable local file path")
            return
        geo = self.monitor.get_geometry()
        geometry = (geo.x, geo.y, geo.width, geo.height)
        threading.Thread(
            target=process_drop,
            args=(path, geometry),
            daemon=True,
        ).start()


class App:
    def __init__(self, layer):
        self.layer = layer
        self.windows = []
        self.rebuild_pending = False

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        display = Gdk.Display.get_default()
        display.connect("monitor-added", self.schedule_rebuild)
        display.connect("monitor-removed", self.schedule_rebuild)
        self.build_windows()
        GLib.timeout_add_seconds(HEARTBEAT_SECONDS, self.heartbeat)

    def build_windows(self):
        for win in self.windows:
            win.destroy()
        self.windows = []
        display = Gdk.Display.get_default()
        for i in range(display.get_n_monitors()):
            monitor = display.get_monitor(i)
            if monitor is not None:
                self.windows.append(DropWindow(monitor, self.layer))
        emit("READY\t%d" % len(self.windows))

    def heartbeat(self):
        emit("ALIVE")
        return True

    def schedule_rebuild(self, *_args):
        # Debounce: hotplug fires added+removed bursts during mode changes.
        if self.rebuild_pending:
            return
        self.rebuild_pending = True

        def do_rebuild():
            self.rebuild_pending = False
            self.build_windows()
            return False

        GLib.timeout_add(500, do_rebuild)


def main():
    parser = argparse.ArgumentParser(description="DropWall layer-shell drop helper")
    parser.add_argument("--layer", choices=sorted(LAYERS), default="background")
    args = parser.parse_args()

    arm_parent_death_signal()
    if not acquire_instance_lock():
        return 3

    try:
        if Gdk.Display.get_default() is None:
            emit("ERR\tcould not connect to the Wayland display")
            return 1
        if not GtkLayerShell.is_supported():
            emit("ERR\tlayer-shell is not supported by this compositor")
            return 1

        App(LAYERS[args.layer])
        Gtk.main()
        return 0
    except Exception as error:
        emit("ERR\tGTK helper startup failed: %s" % str(error).replace("\n", " "))
        return 1


if __name__ == "__main__":
    sys.exit(main())
