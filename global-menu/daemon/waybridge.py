#!/usr/bin/env python3
"""
waybridge.py - compositor-agnostic window tracking for the Noctalia
global-menu plugin.

Implements a minimal Wayland client for the
zwlr_foreign_toplevel_management_unstable_v1 protocol by hand over the
session Wayland socket. The protocol is supported by every compositor
Noctalia runs on (Hyprland, niri, sway, river, Wayfire, labwc, MangoWC,
KWin, Umbriel, ...), so no compositor-specific IPC (hyprctl, niri msg,
swaymsg, ...) is used anywhere.

Wire protocol notes:
  * every message: u32 object id, u32 (size u16 | opcode u16), args
  * string: u32 len (incl. NUL) + bytes + NUL, padded to 4
  * array:  u32 len + raw bytes, padded to 4
  * object ids chosen by the client live in [2, 0xfeffffff]; ids chosen
    by the server are >= 0xff000000
"""

import os
import socket
import struct
import threading

MANAGER_IFACE = 'zwlr_foreign_toplevel_manager_v1'

# zwlr_foreign_toplevel_manager_v1 events
MGR_TOPLEVEL = 0
MGR_FINISHED = 1

# zwlr_foreign_toplevel_handle_v1 events
H_TITLE = 0
H_APP_ID = 1
H_OUTPUT_ENTER = 2
H_OUTPUT_LEAVE = 3
H_STATE = 4
H_DONE = 5
H_CLOSED = 6

# zwlr_foreign_toplevel_handle_v1 requests
REQ_SET_MAXIMIZED = 0
REQ_UNSET_MAXIMIZED = 1
REQ_SET_MINIMIZED = 2
REQ_UNSET_MINIMIZED = 3
REQ_ACTIVATE = 4
REQ_CLOSE = 5
REQ_SET_FULLSCREEN = 8
REQ_UNSET_FULLSCREEN = 9

# state enum values
STATE_MAXIMIZED = 0
STATE_MINIMIZED = 1
STATE_ACTIVATED = 2
STATE_FULLSCREEN = 3

# event argument signatures (after the 8-byte header).
# o = object, n = new id, s = string, u = uint, a = array, f = fixed, i = int
MGR_EVENTS = {MGR_TOPLEVEL: 'n', MGR_FINISHED: ''}
HANDLE_EVENTS = {
    H_TITLE: 's', H_APP_ID: 's', H_OUTPUT_ENTER: 'o', H_OUTPUT_LEAVE: 'o',
    H_STATE: 'a', H_DONE: '', H_CLOSED: '',
}


def socket_path():
    display = os.environ.get('WAYLAND_DISPLAY', 'wayland-0')
    if display.startswith('/'):
        return display
    runtime = os.environ.get('XDG_RUNTIME_DIR')
    if not runtime:
        return None
    return os.path.join(runtime, display)


class WaylandError(Exception):
    pass


class Toplevel(object):
    __slots__ = ('wid', 'app_id', 'title', 'maximized', 'minimized',
                 'fullscreen', 'activated')

    def __init__(self, wid):
        self.wid = wid
        self.app_id = ''
        self.title = ''
        self.maximized = False
        self.minimized = False
        self.fullscreen = False
        self.activated = False

    def summary(self):
        return {
            'app_id': self.app_id,
            'title': self.title,
            'maximized': self.maximized,
            'minimized': self.minimized,
        }


class WaylandBridge(object):
    """Tracks toplevels and the focused window over wlr-foreign-toplevel.

    Events are marshalled onto the GLib main loop with a self-pipe so the
    reader thread never touches shared state directly.
    """

    def __init__(self, on_focus=None, on_update=None, log=None):
        self.on_focus = on_focus          # cb(app_id, title)
        self.on_update = on_update        # cb() any toplevel list change
        self._log = log or (lambda msg: None)

        self._sock = None
        self._lock = threading.Lock()
        self._next_id = 2
        self._running = False
        self._thread = None

        self.toplevels = {}          # object id -> Toplevel
        self.focused_wid = None
        self.manager_id = None
        self.manager_version = 0

        self._rfd, self._wfd = os.pipe()
        # drain() is called from the GLib main loop and must never block:
        # a blocking read here would stall heartbeats and SIGTERM handling.
        os.set_blocking(self._rfd, False)
        os.set_blocking(self._wfd, False)
        self._queue = []
        self._queue_lock = threading.Lock()

    # ------------------------------------------------------------------ pipe

    def get_watch_fd(self):
        """File descriptor that becomes readable when events are pending."""
        return self._rfd

    def drain(self):
        """Called from the GLib loop when the watch fd is readable."""
        try:
            while True:
                if not os.read(self._rfd, 4096):
                    break
        except (BlockingIOError, InterruptedError):
            pass
        except OSError:
            pass

        with self._queue_lock:
            events, self._queue = self._queue, []

        focus_changed = False
        changed = False
        for kind, payload in events:
            if kind == 'focus':
                focus_changed = True
            elif kind == 'update':
                changed = True
            elif kind == 'lost':
                # compositor socket died: nothing focused
                if self.focused_wid is not None:
                    self.focused_wid = None
                    focus_changed = True
        if focus_changed and self.on_focus:
            self.on_focus(*self.focused_summary())
        if changed and self.on_update:
            self.on_update()

    def focused_summary(self):
        win = self.toplevels.get(self.focused_wid)
        if win is None:
            return None, None
        return win.app_id, win.title

    def focused_window(self):
        return self.toplevels.get(self.focused_wid)

    # ----------------------------------------------------------------- start

    def start(self):
        if self._running:
            return True
        path = socket_path()
        if not path or not os.path.exists(path):
            self._log('wayland socket not found (%s)' % path)
            return False
        try:
            self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._sock.connect(path)
            # bind the manager before returning so callers know whether
            # toplevel tracking is actually available (and startup cannot
            # race the first resolve)
            self._handshake()
        except (OSError, WaylandError, ValueError, struct.error) as exc:
            self._log('wayland setup failed: %s' % exc)
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
            return False

        self._running = True
        self._thread = threading.Thread(target=self._run, name='wayland-bridge')
        self._thread.daemon = True
        self._thread.start()
        return True

    def stop(self):
        self._running = False
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass
        self._sock = None

    # ------------------------------------------------------------------ wire

    def _alloc_id(self):
        with self._lock:
            wid = self._next_id
            self._next_id += 1
            if self._next_id > 0xfeffffff:
                self._next_id = 2
        return wid

    def _send(self, obj_id, opcode, payload=b''):
        header = struct.pack('<II', obj_id, (len(payload) + 8) << 16 | opcode)
        with self._lock:
            try:
                self._sock.sendall(header + payload)
            except (OSError, AttributeError):
                self._log('wayland send failed')

    @staticmethod
    def _pack_string(text):
        raw = text.encode('utf-8') + b'\x00'
        pad = (-len(raw)) % 4
        return struct.pack('<I', len(raw)) + raw + b'\x00' * pad

    @staticmethod
    def _pack_uint(value):
        return struct.pack('<I', value)

    # ------------------------------------------------------ reader thread

    def _run(self):
        try:
            self._read_loop()
        except (OSError, ValueError, struct.error) as exc:
            self._log('wayland socket error: %s' % exc)
        finally:
            self.toplevels.clear()
            self.manager_id = None
            self._enqueue('lost', None)

    def _handshake(self):
        registry = self._alloc_id()
        self._send(1, 1, self._pack_uint(registry))            # get_registry
        callback = self._alloc_id()
        self._send(1, 0, self._pack_uint(callback))            # sync

        # block until the sync callback fires; collect globals meanwhile
        buf = b''
        deadline = 5.0
        import time
        start = time.time()
        # a blocking recv with no events would otherwise never reach the
        # deadline; a timeout lets us fail cleanly on compositors without
        # the protocol
        self._sock.settimeout(deadline)
        try:
            while time.time() - start < deadline:
                try:
                    chunk = self._sock.recv(65536)
                except socket.timeout:
                    break
                if not chunk:
                    raise WaylandError('connection closed during handshake')
                buf += chunk
                messages, buf = self._split_messages(buf)
                for obj_id, opcode, payload in messages:
                    if obj_id == 1 and opcode == 1:               # delete_id
                        continue
                    if obj_id == 1 and opcode == 0:               # display error
                        raise WaylandError('display error during handshake')
                    if obj_id == 2 and opcode == 0:               # registry.global
                        self._on_global(payload)
                    elif obj_id == callback and opcode == 0:      # callback.done
                        if self.manager_id is not None:
                            return
        finally:
            self._sock.settimeout(None)
        raise WaylandError('no foreign toplevel manager advertised')

    @staticmethod
    def _split_messages(buf):
        messages = []
        while len(buf) >= 8:
            obj_id, word = struct.unpack_from('<II', buf, 0)
            size = word >> 16
            opcode = word & 0xffff
            if size < 8 or len(buf) < size:
                break
            messages.append((obj_id, opcode, buf[8:size]))
            buf = buf[size:]
        return messages, buf

    def _on_global(self, payload):
        # wl_registry.global(name: uint, interface: string, version: uint)
        name, interface, version = self._parse_args('usu', payload)
        if interface != MANAGER_IFACE:
            return
        self.manager_version = min(version, 2)
        wid = self._alloc_id()
        self.manager_id = wid
        payload = (self._pack_uint(name) + self._pack_string(MANAGER_IFACE) +
                   self._pack_uint(self.manager_version) + self._pack_uint(wid))
        self._send(2, 0, payload)                             # registry.bind
        self._log('bound %s v%d' % (MANAGER_IFACE, self.manager_version))

    def _read_loop(self):
        buf = b''
        while self._running:
            try:
                chunk = self._sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            messages, buf = self._split_messages(buf)
            for obj_id, opcode, payload in messages:
                self._dispatch(obj_id, opcode, payload)
        self._log('wayland reader stopped')

    def _dispatch(self, obj_id, opcode, payload):
        if obj_id == 1:
            # wl_display: 0 = error, 1 = delete_id (safe to ignore ids)
            return
        if obj_id == self.manager_id:
            if opcode == MGR_TOPLEVEL:
                new_id = struct.unpack_from('<I', payload, 0)[0]
                self.toplevels[new_id] = Toplevel(new_id)
                self._enqueue('update', None)
            return
        win = self.toplevels.get(obj_id)
        if win is None:
            return
        if opcode == H_TITLE:
            win.title = self._parse_args('s', payload)[0]
        elif opcode == H_APP_ID:
            win.app_id = self._parse_args('s', payload)[0]
            self._maybe_focus(win)
        elif opcode == H_STATE:
            states = self._parse_args('a', payload)[0]
            values = struct.unpack('<%dI' % (len(states) // 4), states) if states else ()
            win.maximized = STATE_MAXIMIZED in values
            win.minimized = STATE_MINIMIZED in values
            win.fullscreen = STATE_FULLSCREEN in values
            was = win.activated
            win.activated = STATE_ACTIVATED in values
            if win.activated != was:
                self._maybe_focus(win)
        elif opcode == H_DONE:
            self._enqueue('update', None)
        elif opcode == H_CLOSED:
            self._enqueue('update', None)
            if self.focused_wid == obj_id:
                self.focused_wid = None
                self._enqueue('focus', None)
            self.toplevels.pop(obj_id, None)

    def _maybe_focus(self, win):
        # Only follow activation. Opening the plugin's own popup takes
        # keyboard focus away from the app, so clearing focus on
        # deactivation would hide the menus while the user is using them.
        if win.activated and self.focused_wid != win.wid:
            self.focused_wid = win.wid
            self._enqueue('focus', None)

    # ------------------------------------------------------------- helpers

    @staticmethod
    def _parse_args(signature, payload):
        values = []
        offset = 0
        for kind in signature:
            if kind in 'ounfi':
                (raw,) = struct.unpack_from('<I', payload, offset)
                values.append(raw)
                offset += 4
            elif kind == 's':
                (length,) = struct.unpack_from('<I', payload, offset)
                offset += 4
                values.append(payload[offset:offset + length - 1].decode('utf-8', 'replace'))
                offset += length
                offset += (-offset) % 4
            elif kind == 'a':
                (length,) = struct.unpack_from('<I', payload, offset)
                offset += 4
                values.append(payload[offset:offset + length])
                offset += length
                offset += (-offset) % 4
        return values

    def _enqueue(self, kind, payload):
        with self._queue_lock:
            self._queue.append((kind, payload))
        try:
            os.write(self._wfd, b'\x01')
        except OSError:
            pass

    # ------------------------------------------------------ window actions

    def _focused_id(self):
        return self.focused_wid

    def window_state(self):
        """Snapshot of the focused window's live state, or None."""
        win = self.focused_window()
        if win is None:
            return None
        return {'appId': win.app_id, 'title': win.title,
                'maximized': win.maximized, 'minimized': win.minimized,
                'fullscreen': win.fullscreen}

    def window_action(self, action):
        win = self.focused_window()
        if win is None:
            return False
        wid = win.wid
        if action == 'minimize':
            self._send(wid, REQ_SET_MINIMIZED)
        elif action == 'unminimize':
            self._send(wid, REQ_UNSET_MINIMIZED)
        elif action == 'maximize':
            self._send(wid, REQ_UNSET_MAXIMIZED if win.maximized else REQ_SET_MAXIMIZED)
        elif action == 'unmaximize':
            self._send(wid, REQ_UNSET_MAXIMIZED)
        elif action == 'fullscreen':
            # fullscreen requests exist since protocol version 2; sending
            # them to a v1-only compositor would kill the connection
            if self.manager_version < 2:
                return False
            if win.fullscreen:
                self._send(wid, REQ_UNSET_FULLSCREEN)
            else:
                # null wl_output object: fullscreen on the current output
                self._send(wid, REQ_SET_FULLSCREEN, self._pack_uint(0))
        elif action == 'unset_fullscreen':
            if self.manager_version < 2:
                return False
            self._send(wid, REQ_UNSET_FULLSCREEN)
        elif action == 'restore':
            self._send(wid, REQ_UNSET_MAXIMIZED)
            if self.manager_version >= 2:
                self._send(wid, REQ_UNSET_FULLSCREEN)
        elif action == 'close':
            self._send(wid, REQ_CLOSE)
        elif action == 'quit':
            # macOS-style Quit: close every window of the focused app,
            # not just the one in front
            return self._quit_app(win.app_id)
        else:
            return False
        return True

    def _quit_app(self, app_id):
        if not app_id:
            return False
        closed = False
        for other_id, other in list(self.toplevels.items()):
            if other.app_id == app_id:
                self._send(other_id, REQ_CLOSE)
                closed = True
        return closed

    def has_toplevels(self):
        return self.manager_id is not None
