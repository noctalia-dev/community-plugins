#!/usr/bin/env python3
"""Offline test of the daemon's chunked emission + tree serialization."""

import io
import json
import sys
import threading
import types

sys.path.insert(0, '.')

# stub dbus/gi so the daemon module imports without a session bus
dbus_stub = types.ModuleType('dbus')
dbus_stub.exceptions = types.SimpleNamespace(DBusException=Exception)
dbus_service = types.ModuleType('dbus.service')
dbus_service.Object = object
dbus_service.BusName = lambda *a, **kw: None
dbus_service.method = lambda *a, **kw: (lambda fn: fn)
dbus_service.signal = lambda *a, **kw: (lambda fn: fn)
sys.modules['dbus.service'] = dbus_service
dbus_stub.service = dbus_service
dbus_stub.SessionBus = lambda: None
dbus_stub.Array = None
dbus_stub.Dictionary = None
dbus_stub.Struct = None
dbus_stub.UInt32 = None
dbus_stub.String = None
dbus_stub.ObjectPath = None
dbus_stub.Interface = None
sys.modules['dbus'] = dbus_stub
glib_mainloop = types.ModuleType('dbus.mainloop.glib')
glib_mainloop.DBusGMainLoop = lambda **kw: None
sys.modules['dbus.mainloop'] = types.ModuleType('dbus.mainloop')
sys.modules['dbus.mainloop.glib'] = glib_mainloop
gi = types.ModuleType('gi')
repository = types.ModuleType('gi.repository')


class _GLib(object):
    @staticmethod
    def idle_add(fn, *a, **kw):
        return 0

    @staticmethod
    def timeout_add(*a, **kw):
        return 0

    @staticmethod
    def io_add_watch(*a, **kw):
        return 0

    @staticmethod
    def source_remove(*a):
        pass

    MainLoop = lambda self=None: types.SimpleNamespace(run=lambda: None,
                                                       quit=lambda: None)


class _DesktopAppInfo(object):
    @staticmethod
    def new(name):
        return None


repository.GLib = _GLib
repository.Gio = types.SimpleNamespace(DesktopAppInfo=_DesktopAppInfo)
repository.GioUnix = types.SimpleNamespace(DesktopAppInfo=_DesktopAppInfo)
gi.repository = repository
sys.modules['gi'] = gi
sys.modules['gi.repository'] = repository

import importlib.util
spec = importlib.util.spec_from_file_location('gmd', 'globalmenu_daemon.py')
gmd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gmd)

# --- chunked emission ------------------------------------------------------
captured = io.StringIO()
real_stdout = sys.stdout
sys.stdout = captured
out = gmd.StdoutBridge()
big = [{'label': 'Item %d' % i, 'key': 'k%d' % i,
        'children': [{'label': 'x' * 200}]} for i in range(400)]
out.emit_menu('org.test.App', 'App', 'dbusmenu', big)
out.emit_menu('small.app', 'Small', 'fallback', [{'label': 'Session'}])
sys.stdout = real_stdout

lines = [line for line in captured.getvalue().splitlines() if line]
parsed = [json.loads(line) for line in lines]
first = parsed[0]
assert first['chunks'] > 1, 'expected chunking'
body = ''.join(p['body'] for p in parsed[:first['chunks']])
tree = json.loads(body)
assert len(tree) == len(big), 'tree must reassemble'
assert parsed[first['chunks']]['tree'], 'small menu must be unchunked'
print('chunking OK: %d parts, reassembled %d items, small unchunked'
      % (first['chunks'], len(tree)))

# --- node dict conversion ---------------------------------------------------
from treelib import Tree
from menu_item import DbusAppMenuItem

t = Tree()
root_item = DbusAppMenuItem([0, {}, []], [])
t.create_node('', 'rootnode', data=root_item)
file_item = DbusAppMenuItem([1, {'label': 'File'}, []], [])
t.create_node('File', 1, 'rootnode', data=file_item)
open_item = DbusAppMenuItem([2, {'label': 'Open', 'enabled': 1,
                                 'shortcut': [['ctrl'], 'o']}, []], ['File'])
t.create_node('Open', 2, 1, data=open_item)
sep_item = DbusAppMenuItem([3, {'type': 'separator'}, []], ['File'])
sep_item.separator = True
t.create_node('', 3, 1, data=sep_item)
quit_item = DbusAppMenuItem([4, {'label': 'Quit'}, []], ['File'])
t.create_node('Quit', 4, 1, data=quit_item)

payload = gmd.GlobalMenuDaemon.tree_payload(types.SimpleNamespace(tree=t))
assert payload[0]['label'] == 'File', payload
assert payload[0]['key'] == 'File'
kids = payload[0]['children']
assert kids[0]['label'] == 'Open' and kids[0]['accel'], kids
assert {'separator': True} in kids
assert kids[-1]['label'] == 'Quit'
assert kids[-1]['key'].startswith('File'), kids[-1]
print('tree payload OK:', json.dumps(payload)[:120], '...')

# --- wayland self-pipe drain must never block ------------------------------
from waybridge import WaylandBridge, Toplevel

bridge = WaylandBridge()
bridge._enqueue('update', None)
done = threading.Event()


def _drain():
    bridge.drain()
    done.set()


threading.Thread(target=_drain, daemon=True).start()
assert done.wait(1.0), 'WaylandBridge.drain() blocked on the self-pipe'
assert bridge._queue == [], 'drain must consume queued events'

# losing activation must not clear focus: the plugin popup steals it
win = Toplevel(7)
bridge.focused_wid = 7
win.activated = False
bridge._maybe_focus(win)
assert bridge.focused_wid == 7, 'deactivation must keep the last focused app'
print('non-blocking wayland drain + focus persistence OK')

# --- registrar ownership must fall back to adopting an existing owner ------
import resolver

class FakeSession(object):
    def add_signal_receiver(self, *args, **kwargs):
        pass

    def get_object(self, *args, **kwargs):
        return types.SimpleNamespace(GetMenus=lambda timeout=2: {})


class NameTaken(Exception):
    pass


def _busy(*args, **kwargs):
    raise NameTaken('name already owned')


original = resolver.dbus.service.BusName
resolver.dbus.service.BusName = _busy
try:
    registrar = resolver.Registrar(FakeSession())
finally:
    resolver.dbus.service.BusName = original
assert registrar.owned is False and registrar.external is True, \
    'must adopt an external registrar instead of aborting setup'
print('registrar adoption OK')

# --- friendly application names -------------------------------------------
daemon = object.__new__(gmd.GlobalMenuDaemon)
daemon._app_names = {}
assert daemon._display_app_name('org.gnome.Nautilus') == 'Nautilus'
assert daemon._display_app_name('google-chrome') == 'Google Chrome'
assert daemon._display_app_name(None) == ''
print('app display names OK')

print('ALL DAEMON TESTS PASSED')
