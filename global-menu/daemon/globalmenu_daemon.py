#!/usr/bin/env python3
"""
globalmenu_daemon.py - companion daemon for the Noctalia global-menu
plugin.

The Noctalia v5 plugin runtime cannot speak D-Bus or Wayland, so this
daemon does all of that work and talks to the plugin over two simple
channels:

  daemon -> plugin   JSON lines on stdout, consumed by the plugin's
                     service entry with noctalia.runStream().
  plugin -> daemon   HTTP POST on a loopback-only server; the ephemeral
                     port and a private per-session token are reported
                     in the initial hello line, and every request must
                     present the token in an X-GlobalMenu-Token header.

Menus come from (in order of preference, per focused application):
  1. com.canonical.dbusmenu  (Qt, Electron, Chromium, Firefox apps that
     registered with the AppMenu registrar)
  2. org.gtk.Menus           (GTK applications exporting a menubar)
  3. shortcut mappings       (curated menus whose items activate GTK
                             actions or synthesize keystrokes)
  4. fallback                (window + session actions)

Window tracking uses wlr-foreign-toplevel-management only - no
compositor-specific IPC anywhere.
"""

import argparse
import hmac
import json
import os
import re
import secrets
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dbus
from dbus.mainloop.glib import DBusGMainLoop
try:
    from gi.repository import Gio, GioUnix, GLib
    _DesktopAppInfo = GioUnix.DesktopAppInfo
except ImportError:
    from gi.repository import Gio, GLib
    _DesktopAppInfo = Gio.DesktopAppInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fallback import FallbackMenu                 # noqa: E402
from keyer import Keyer                           # noqa: E402
from menureader import DbusMenuReader, GtkMenuReader  # noqa: E402
from resolver import Registrar, GtkProbe          # noqa: E402
from shortcuts import ShortcutStore               # noqa: E402
from waybridge import WaylandBridge               # noqa: E402

PROTOCOL = 1
HEARTBEAT_MS = 4000
CHUNK_SIZE = 48000
RESEND_AFTER_ACTIVATE_MS = 300


class StdoutBridge(object):
    """Serialises JSON lines to stdout (main thread only)."""

    def __init__(self):
        self._lock = threading.Lock()
        self.tree_seq = 0

    def line(self, payload):
        try:
            data = json.dumps(payload)
        except (TypeError, ValueError):
            return
        with self._lock:
            sys.stdout.write(data + '\n')
            sys.stdout.flush()

    def emit_menu(self, app_id, title, source, tree, app_name=''):
        self.tree_seq += 1
        header = {'type': 'menu', 'app': app_id or '', 'title': title or '',
                  'appName': app_name or '', 'source': source,
                  'id': self.tree_seq}
        try:
            body = json.dumps(tree)
        except (TypeError, ValueError):
            body = '[]'
        if len(body) <= CHUNK_SIZE:
            header['tree'] = tree
            self.line(header)
            return
        chunks = [body[i:i + CHUNK_SIZE]
                  for i in range(0, len(body), CHUNK_SIZE)]
        header['chunks'] = len(chunks)
        for index, chunk in enumerate(chunks):
            part = dict(header)
            part['chunk'] = index
            part['body'] = chunk
            self.line(part)
            if index < len(chunks) - 1:
                # keep part ordering deterministic
                with self._lock:
                    sys.stdout.flush()


class CommandServer(BaseHTTPRequestHandler):
    daemon_ref = None

    def log_message(self, fmt, *args):
        pass

    def _reply(self, payload):
        try:
            data = json.dumps(payload).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (OSError, BrokenPipeError):
            pass

    def _deny(self):
        try:
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
        except (OSError, BrokenPipeError):
            pass

    def _authorized(self):
        """Only the plugin that spawned this daemon may talk to it.

        A binding to 127.0.0.1 alone does not separate users on a
        multi-user machine, so every request must present the private
        token from the hello line and name the loopback host.
        """
        ref = self.daemon_ref
        if ref is None or not ref.token:
            return False
        supplied = self.headers.get('X-GlobalMenu-Token', '')
        try:
            if not hmac.compare_digest(supplied.encode('utf-8'),
                                       str(ref.token).encode('utf-8')):
                return False
        except (AttributeError, UnicodeEncodeError):
            return False
        host = self.headers.get('Host', '')
        hostname = host.split(':', 1)[0].strip().lower()
        return hostname in ('127.0.0.1', 'localhost')

    def do_GET(self):
        if not self._authorized():
            self._deny()
            return
        if self.path == '/health':
            self._reply({'ok': True, 'source': self.daemon_ref.source_name})
        else:
            self._reply({'ok': False})

    def do_POST(self):
        if not self._authorized():
            self._deny()
            return
        ctype = self.headers.get('Content-Type', '').split(';', 1)[0]
        if self.path != '/cmd' or ctype.strip().lower() != 'application/json':
            self._reply({'ok': False})
            return
        try:
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else b'{}'
            request = json.loads(body.decode('utf-8'))
        except (ValueError, OSError):
            self._reply({'ok': False})
            return
        self.daemon_ref.queue_command(request)
        self._reply({'ok': True})


class GlobalMenuDaemon(object):

    def __init__(self, data_dir, shortcuts_dir, verbose=False):
        self.data_dir = data_dir
        self.shortcuts_dir = shortcuts_dir
        self.verbose = verbose

        self.out = StdoutBridge()
        self.token = secrets.token_hex(32)
        self.session = None
        self.registrar = None
        self.gtk_probe = None
        self.store = None
        self.keyer = Keyer(self.log)
        self.wayland = None
        self.fallback = None

        self.reader = None
        self.source_name = 'none'
        self.app_id = None
        self.app_title = None
        self.app_name = ''
        self.shortcut_actions = {}
        self.last_tree = []
        self._app_names = {}
        self._last_window_state = None

        self.config = {'shortcutMenus': True, 'fallbackMenus': True}
        self._http = None
        self._heartbeat_id = 0
        self._resolving = False

    # ------------------------------------------------------------- logging

    def log(self, message):
        if self.verbose:
            sys.stderr.write('[global-menu-daemon] %s\n' % message)
            sys.stderr.flush()

    # ---------------------------------------------------------------- setup

    def _display_app_name(self, app_id):
        """Human name for an app id ("org.gnome.Nautilus" -> "Files")."""
        if not app_id:
            return ''
        cached = self._app_names.get(app_id)
        if cached is not None:
            return cached
        name = ''
        for candidate in (app_id + '.desktop', app_id):
            try:
                info = _DesktopAppInfo.new(candidate)
            except Exception:
                info = None
            if info is not None:
                name = info.get_display_name() or info.get_name() or ''
                if name:
                    break
        if not name:
            tail = str(app_id).rsplit('.', 1)[-1]
            name = re.sub(r'[-_]+', ' ', tail).strip().title()
        self._app_names[app_id] = name
        return name

    def setup(self):
        DBusGMainLoop(set_as_default=True)
        try:
            self.session = dbus.SessionBus()
        except dbus.exceptions.DBusException as exc:
            self.out.line({'type': 'fatal', 'error':
                           'no session bus: %s' % exc})
            return False

        self._load_config()

        self.registrar = Registrar(self.session, on_change=self.resolve,
                                   log=self.log)
        self.gtk_probe = GtkProbe(self.session, log=self.log)

        user_shortcuts = os.path.expanduser(
                '~/.config/noctalia/global-menu/shortcuts/apps')
        self.store = ShortcutStore(self.shortcuts_dir, user_shortcuts,
                                   log=self.log)

        self.wayland = WaylandBridge(on_focus=self._on_focus_changed,
                                     on_update=self._on_windows_changed,
                                     log=self.log)
        if not self.wayland.start():
            self.wayland = None
            self.log('no wayland tracking; menus match by single '
                     'registration only')

        self.fallback = FallbackMenu(self.session, self.wayland)

        self._start_http()
        self._watch_bus_deaths()

        if self.wayland is not None:
            GLib.io_add_watch(self.wayland.get_watch_fd(), GLib.IO_IN,
                              self._on_wayland_watch)

        self._heartbeat_id = GLib.timeout_add(HEARTBEAT_MS, self._heartbeat)
        self._emit_hello()
        # publish the focused window's state (maximized/minimized/...)
        self._emit_window_state()
        # first resolve once things settle
        GLib.timeout_add(600, self.resolve)
        return True

    def _emit_hello(self):
        """The one-time handshake: port + private token for the HTTP API."""
        self.out.line({
            'type': 'hello', 'protocol': PROTOCOL,
            'port': self._http_port,
            'token': self.token,
            'features': {
                'toplevels': self.wayland is not None,
                'fullscreen': (self.wayland is not None and
                               self.wayland.has_toplevels() and
                               self.wayland.manager_version >= 2),
                'wtype': self.keyer.available(),
                'registrar': self.registrar.owned,
                'shortcuts': len(self.store.mappings),
            },
        })

    def _start_http(self):
        CommandServer.daemon_ref = self
        server = ThreadingHTTPServer(('127.0.0.1', 0), CommandServer)
        self._http = server
        self._http_port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever,
                                  name='globalmenu-http')
        thread.daemon = True
        thread.start()

    def _watch_bus_deaths(self):
        self.session.add_signal_receiver(
                self._bus_name_vanished, 'NameOwnerChanged',
                'org.freedesktop.DBus', 'org.freedesktop.DBus',
                '/org/freedesktop/DBus')

    def _bus_name_vanished(self, name, old, new):
        if name and not new and self.registrar:
            self.registrar.registrations_died(str(name))

    def _on_wayland_watch(self, _fd, _condition):
        if self.wayland:
            self.wayland.drain()
        return True

    def _on_focus_changed(self, app_id, title):
        self.resolve()

    def _on_windows_changed(self):
        GLib.idle_add(self._emit_window_state)

    def _emit_window_state(self):
        """Push focused-window state so the panel can reflect it live."""
        if self.wayland is None:
            return False
        state = self.wayland.window_state()
        if state != self._last_window_state:
            self._last_window_state = dict(state) if state else None
            self.out.line({'type': 'window', 'state':
                           self._last_window_state})
        return False

    def _heartbeat(self):
        self.out.line({'type': 'ping', 't': int(time.time() * 1000)})
        return True

    # --------------------------------------------------------------- config

    def _config_path(self):
        return os.path.join(self.data_dir, 'config.json')

    def _load_config(self):
        try:
            with open(self._config_path(), encoding='utf-8') as handle:
                stored = json.load(handle)
            if isinstance(stored, dict):
                self.config.update({k: bool(stored[k]) for k in
                                    ('shortcutMenus', 'fallbackMenus')
                                    if k in stored})
        except (OSError, ValueError):
            pass

    def _save_config(self):
        try:
            os.makedirs(self.data_dir, exist_ok=True)
            with open(self._config_path(), 'w', encoding='utf-8') as handle:
                json.dump(self.config, handle)
        except OSError:
            pass

    # ------------------------------------------------------------- commands

    def queue_command(self, request):
        GLib.idle_add(self._run_command, request)

    def _run_command(self, request):
        try:
            self.handle_command(request)
        except Exception as exc:      # never die from a bad command
            self.log('command error: %s' % exc)
        return False

    def handle_command(self, request):
        cmd = request.get('cmd')
        if cmd == 'activate':
            self.activate(request.get('key', ''))
        elif cmd == 'config':
            for key in ('shortcutMenus', 'fallbackMenus'):
                if key in request:
                    self.config[key] = bool(request[key])
            self._save_config()
            self.resolve()
        elif cmd == 'refresh':
            self.emit_current()
        elif cmd == 'reloadShortcuts':
            self.store.reload()
            self.resolve()
        elif cmd == 'window':
            if self.wayland:
                self.wayland.window_action(request.get('action', ''))
        elif cmd == 'session':
            if self.fallback:
                self.fallback.execute('session', request.get('action', ''))
        elif cmd == 'ping':
            self.out.line({'type': 'pong'})
        else:
            self.log('unknown command: %r' % cmd)

    # -------------------------------------------------------------- resolve

    def resolve(self):
        app_id, title = (None, None)
        toplevels_available = False
        if self.wayland:
            toplevels_available = self.wayland.has_toplevels()
            app_id, title = self.wayland.focused_summary()

        match = self.registrar.match(app_id, title, toplevels_available) \
                if self.registrar else None

        source = None
        reader = None

        if match:
            sender, path = match
            reader = DbusMenuReader(self.session, sender, path,
                                    on_changed=self._reader_changed)
            source = 'dbusmenu'
        else:
            probed = self.gtk_probe.discover(app_id) if app_id else None
            if probed:
                reader = GtkMenuReader(
                        self.session, probed['bus_name'], probed['app_path'],
                        probed['win_path'], probed['menubar_path'],
                        probed['appmenu_path'],
                        on_changed=self._reader_changed)
                source = 'gtk'

        if self.reader is not None and self.reader is not reader:
            try:
                self.reader.stop()
            except Exception:
                pass
        self.reader = reader
        self.source_name = source or 'none'
        self.app_id = app_id
        self.app_title = title
        self.app_name = self._display_app_name(app_id)
        self.shortcut_actions = {}
        self.last_tree = []

        if reader is not None:
            try:
                reader.start()
                reader.refresh()
                if not reader.empty():
                    self.last_tree = self.tree_payload(reader)
                    self.emit_current()
                    return False
                # menu source exists but exports nothing yet; give it a
                # short grace period before falling through
                GLib.timeout_add(1200, self._late_check, reader, source)
                return False
            except Exception:
                self.log('reader failed for %s' % app_id)
                try:
                    reader.stop()
                except Exception:
                    pass
                if self.reader is reader:
                    self.reader = None
                self.source_name = 'none'

        if app_id:
            if self.config['shortcutMenus']:
                mapping = self.store.match(self._shortcut_identifiers())
                if mapping and mapping.get('blank'):
                    self.emit_current()
                    return False
                if mapping:
                    tree, actions = self.store.build_tree(mapping)
                    if tree:
                        self.source_name = 'shortcut'
                        self.last_tree = tree
                        self.shortcut_actions = actions
                        self.emit_current()
                        return False
            if self.config['fallbackMenus']:
                tree, actions = self.fallback.build_tree()
                if tree:
                    self.source_name = 'fallback'
                    self.last_tree = tree
                    self.fallback.actions = actions
                    self.emit_current()
                    return False

        self.emit_current()
        return False

    def _late_check(self, reader, source):
        if self.reader is not reader:
            return False
        if reader.empty():
            self.resolve_fallthrough()
        else:
            self.last_tree = self.tree_payload(reader)
            self.emit_current()
        return False

    def resolve_fallthrough(self):
        """The live reader produced nothing; replace it with lower sources."""
        self.app_id, self.app_title = (None, None)
        if self.wayland:
            self.app_id, self.app_title = self.wayland.focused_summary()
        self.app_name = self._display_app_name(self.app_id)
        app_id = self.app_id
        if self.reader is not None:
            try:
                self.reader.stop()
            except Exception:
                pass
            self.reader = None
        if app_id and self.config['shortcutMenus']:
            mapping = self.store.match(self._shortcut_identifiers())
            if mapping and not mapping.get('blank'):
                tree, actions = self.store.build_tree(mapping)
                if tree:
                    self.source_name = 'shortcut'
                    self.last_tree = tree
                    self.shortcut_actions = actions
                    self.emit_current()
                    return False
        if self.config['fallbackMenus']:
            tree, actions = self.fallback.build_tree()
            if tree:
                self.source_name = 'fallback'
                self.last_tree = tree
                self.fallback.actions = actions
                self.emit_current()
                return False
        self.source_name = 'none'
        self.last_tree = []
        self.emit_current()
        return False

    def _shortcut_identifiers(self):
        identifiers = [self.app_id, self.app_title]
        if self.app_id and '.' in self.app_id:
            identifiers.append(self.app_id.rsplit('.', 1)[-1])
        return identifiers

    def _reader_changed(self):
        GLib.idle_add(self._reader_changed_idle)

    def _reader_changed_idle(self):
        if self.reader is not None and not self.reader.empty():
            self.last_tree = self.tree_payload(self.reader)
            self.emit_current()
        return False

    @staticmethod
    def tree_payload(reader):
        tree = reader.tree
        if tree.root is None:
            return []
        return _node_to_dict_children(tree, tree[tree.root])

    # ------------------------------------------------------------- activate

    def activate(self, key):
        key = str(key)
        source = self.source_name
        if source == 'dbusmenu' or source == 'gtk':
            if self.reader is not None:
                if self.reader.activate(key):
                    GLib.timeout_add(RESEND_AFTER_ACTIVATE_MS,
                                     self._reemit_after_activate)
        elif source == 'shortcut':
            entry = self.shortcut_actions.get(key)
            if entry:
                accel = entry.get('accel') or ''
                action = entry.get('action') or ''
                if action and self.app_id and '.' in self.app_id:
                    # activate on the application's own action bus; the
                    # keyer falls back to typing the accelerator if the
                    # app refuses the action or has no action bus
                    app_path = '/' + self.app_id.replace('.', '/')
                    # the plugin closes its panel first; give focus a
                    # moment to land back on the window before firing
                    self.keyer.activate_action(
                            self.app_id, app_path, action,
                            target=entry.get('target'),
                            fallback_accel=accel, delay_ms=250)
                elif accel:
                    # the plugin closes its panel first; give focus a
                    # moment to land back on the window before typing
                    self.keyer.send(accel, delay_ms=250)
        elif source == 'fallback':
            action = self.fallback.actions.get(key)
            if action:
                kind, name = action
                self.fallback.execute(kind, name)
                GLib.timeout_add(RESEND_AFTER_ACTIVATE_MS,
                                 self._reemit_after_activate)

    def _reemit_after_activate(self):
        if self.reader is not None:
            try:
                self.reader.refresh()
            except Exception:
                pass
            if not self.reader.empty():
                self.last_tree = self.tree_payload(self.reader)
        self.emit_current()
        return False

    # ----------------------------------------------------------------- emit

    def emit_current(self):
        app = self.app_id or ''
        title = self.app_title or ''
        source = self.source_name if self.last_tree else 'none'
        self.out.emit_menu(app, title, source, self.last_tree,
                           self.app_name or '')

    # ------------------------------------------------------------------ run

    def run(self):
        loop = GLib.MainLoop()

        def stop(_signum, _frame):
            GLib.idle_add(loop.quit)

        signal.signal(signal.SIGINT, stop)
        signal.signal(signal.SIGTERM, stop)

        try:
            loop.run()
        finally:
            self.shutdown()

    def shutdown(self):
        if self.reader is not None:
            try:
                self.reader.stop()
            except Exception:
                pass
        if self.wayland is not None:
            self.wayland.stop()
        if self._http is not None:
            self._http.shutdown()
            self._http.server_close()
            self._http = None
        try:
            os.unlink(os.path.join(self.data_dir, 'daemon.pid'))
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True,
                        help='persistent data directory')
    parser.add_argument('--shortcuts', required=True,
                        help='directory with built-in shortcut mappings')
    parser.add_argument('--plugin', default='amancode22/global-menu',
                        help='plugin marker used for pkill cleanup')
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()

    daemon = GlobalMenuDaemon(args.data, args.shortcuts, args.verbose)
    if not daemon.setup():
        return 1

    # pid file so the plugin can stop us on exit
    try:
        os.makedirs(args.data, exist_ok=True)
        with open(os.path.join(args.data, 'daemon.pid'), 'w') as handle:
            handle.write(str(os.getpid()))
    except OSError:
        pass

    daemon.run()
    return 0


def _node_to_dict_children(tree, node):
    out = []
    current_section = None
    for child in tree.children(node.identifier):
        data = child.data
        if not getattr(data, 'visible', True):
            continue
        if getattr(data, 'separator', False):
            out.append({'separator': True})
            continue
        section = getattr(data, 'section', None)
        if current_section is not None and section != current_section:
            out.append({'separator': True})
        current_section = section

        d = _node_to_dict(tree, child)
        if not d['label'] and 'children' not in d:
            continue
        out.append(d)
    return out


def _node_to_dict(tree, node):
    data = node.data
    d = {
        'label': str(getattr(data, 'label', '') or node.tag or ''),
        'key': str(getattr(data, 'text', '') or node.tag or ''),
        'enabled': bool(getattr(data, 'enabled', True)),
        'toggleType': str(getattr(data, 'toggle_type', '') or ''),
        'toggleState': bool(getattr(data, 'toggle_state', False)),
    }
    accel = str(getattr(data, 'accel', '') or '')
    if accel:
        d['accel'] = accel
    if getattr(data, 'app_menu', False):
        d['appMenu'] = True
    children = _node_to_dict_children(tree, node)
    if children:
        d['children'] = children
    return d


if __name__ == '__main__':
    sys.exit(main())
