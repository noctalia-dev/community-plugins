#!/usr/bin/env python3
"""
fallback.py - the menu of last resort: window and session actions
for applications that export no menu at all.

* Window actions use wlr-foreign-toplevel (minimize / maximize / close),
  the same standard protocol the plugin already uses for focus tracking.
* Session actions use standard D-Bus interfaces every compositor
  session provides: org.freedesktop.ScreenSaver (or
  org.gnome.ScreenSaver) on the session bus for locking, and
  org.freedesktop.login1 on the system bus for suspend, reboot and
  power off.

No compositor-specific call is involved.
"""

import dbus

from gi.repository import GLib


def _session_tree():
    lock = {'label': 'Lock Screen', 'key': 'Session  »  Lock Screen',
            'enabled': True, 'toggleType': '', 'toggleState': False}
    suspend = {'label': 'Suspend', 'key': 'Session  »  Suspend',
               'enabled': True, 'toggleType': '', 'toggleState': False}
    reboot = {'label': 'Restart', 'key': 'Session  »  Restart',
              'enabled': True, 'toggleType': '', 'toggleState': False}
    poweroff = {'label': 'Shut Down', 'key': 'Session  »  Shut Down',
                'enabled': True, 'toggleType': '', 'toggleState': False}
    return [{
        'label': 'Session',
        'key': 'Session',
        'enabled': True,
        'toggleType': '',
        'toggleState': False,
        'children': [lock, suspend, {'separator': True}, reboot, poweroff],
    }]


def _window_tree(window_actions):
    window = {'label': 'Window', 'key': 'Window', 'enabled': True,
              'toggleType': '', 'toggleState': False, 'children': []}
    if window_actions:
        window['children'] = [
            {'label': 'Minimize', 'key': 'Window  »  Minimize',
             'enabled': True, 'toggleType': '', 'toggleState': False},
            {'label': 'Maximize', 'key': 'Window  »  Maximize',
             'enabled': True, 'toggleType': '', 'toggleState': False},
            {'separator': True},
            {'label': 'Close Window', 'key': 'Window  »  Close Window',
             'enabled': True, 'toggleType': '', 'toggleState': False},
        ]
    return [window]


class FallbackMenu(object):

    def __init__(self, session, wayland, on_change=None):
        self.session = session
        self.wayland = wayland
        self.on_change = on_change or (lambda: None)
        self.actions = {}
        self._system = None

    def _system_bus(self):
        """Shared system-bus connection; login1 is a system-bus service."""
        if self._system is None:
            self._system = dbus.SystemBus()
        return self._system

    def build_tree(self):
        self.actions = {}
        tree = _window_tree(self.wayland is not None and
                            self.wayland.has_toplevels())
        if self.wayland is None or not self.wayland.has_toplevels():
            tree = []
        self._register_window_actions(tree)
        session_tree = _session_tree()
        tree.extend(session_tree)
        self._register_session_actions(session_tree)
        return tree, dict(self.actions)

    def _register_window_actions(self, tree):
        for menu in tree:
            for child in menu.get('children', []):
                if child.get('separator'):
                    continue
                key = child['key']
                action = key.split(u'  »  ')[-1].strip().lower()
                mapping = {
                    'minimize': 'minimize',
                    'maximize': 'maximize',
                    'close window': 'close',
                }
                if action in mapping:
                    self.actions[key] = ('window', mapping[action])
                else:
                    child['enabled'] = False

    def _register_session_actions(self, tree):
        for menu in tree:
            for child in menu.get('children', []):
                if child.get('separator'):
                    continue
                key = child['key']
                name = key.split(u'  »  ')[-1].strip().lower()
                mapping = {
                    'lock screen': ('session', 'lock'),
                    'suspend': ('session', 'suspend'),
                    'restart': ('session', 'reboot'),
                    'shut down': ('session', 'poweroff'),
                }
                if name in mapping:
                    self.actions[key] = mapping[name]
                else:
                    child['enabled'] = False

    # ------------------------------------------------------------ actions

    def execute(self, kind, action):
        if kind == 'window':
            if self.wayland is not None:
                self.wayland.window_action(action)
                return True
            return False
        if kind == 'session':
            return self._session_action(action)
        return False

    def _session_action(self, action):
        try:
            if action == 'lock':
                for service, path in (
                        ('org.freedesktop.ScreenSaver',
                         '/org/freedesktop/ScreenSaver'),
                        ('org.gnome.ScreenSaver',
                         '/org/gnome/ScreenSaver')):
                    try:
                        obj = self.session.get_object(service, path)
                        obj.get_dbus_method('Lock')(timeout=5)
                        return True
                    except dbus.exceptions.DBusException:
                        continue
                # login1 lives on the system bus, and its Manager has no
                # Lock member; LockSessions() is the locking method
                obj = self._system_bus().get_object(
                        'org.freedesktop.login1', '/org/freedesktop/login1')
                obj.get_dbus_method('LockSessions',
                                    'org.freedesktop.login1.Manager')(timeout=5)
                return True
            obj = self._system_bus().get_object('org.freedesktop.login1',
                                                  '/org/freedesktop/login1')
            manager = dbus.Interface(obj, 'org.freedesktop.login1.Manager')
            if action == 'suspend':
                manager.Suspend(False, timeout=10)
            elif action == 'reboot':
                manager.Reboot(False, timeout=10)
            elif action == 'poweroff':
                manager.PowerOff(False, timeout=10)
            else:
                return False
            return True
        except dbus.exceptions.DBusException as exc:
            GLib.idle_add(lambda: self._log_error(exc))
            return False

    @staticmethod
    def _log_error(exc):
        print('global-menu: session action failed: %s' % exc, flush=True)
        return False
