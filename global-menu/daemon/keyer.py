#!/usr/bin/env python3
"""
keyer.py - sends keyboard shortcuts to the focused window and
activates GTK actions on the application's action bus.

Shortcut-menu items carry either a GTK action name (optionally with an
integer target and a fallback accelerator) or a GTK accelerator string
("<Ctrl><Shift>P"). Actions are activated with org.gtk.Actions.Activate
on the session bus; if the application has no action bus or refuses
the call, the fallback accelerator is typed instead. Accelerators are
synthesised with `wtype`, which uses the standard
virtual-keyboard-unstable-v1 Wayland protocol. That protocol is
supported by every compositor Noctalia runs on, so this stays
compositor-agnostic; it merely requires `wtype` on PATH.

Key names shared between GTK accelerators and XKB keysyms pass straight
through; single letters are lowercased because wtype resolves keysym
names case-sensitively for the letter range.
"""

import shutil
import subprocess
import threading

MODIFIER_MAP = {
    'ctrl': 'ctrl',
    'control': 'ctrl',
    'primary': 'ctrl',
    'shift': 'shift',
    'alt': 'alt',
    'super': 'logo',
}

NAMED_KEYS = {
    'return': 'Return', 'enter': 'Return', 'escape': 'Escape',
    'esc': 'Escape', 'tab': 'Tab', 'backspace': 'BackSpace',
    'delete': 'Delete', 'del': 'Delete', 'home': 'Home', 'end': 'End',
    'page_up': 'Page_Up', 'pageup': 'Page_Up', 'page_down': 'Page_Down',
    'pagedown': 'Page_Down', 'left': 'Left', 'up': 'Up', 'right': 'Right',
    'down': 'Down', 'print': 'Print', 'insert': 'Insert', 'menu': 'Menu',
    'space': 'space', 'kp_0': 'KP_0', 'kp_1': 'KP_1', 'kp_2': 'KP_2',
    'kp_3': 'KP_3', 'kp_4': 'KP_4', 'kp_5': 'KP_5', 'kp_6': 'KP_6',
    'kp_7': 'KP_7', 'kp_8': 'KP_8', 'kp_9': 'KP_9',
}


class Keyer(object):

    def __init__(self, log=None):
        self._log = log or (lambda msg: None)
        self._lock = threading.Lock()

    def available(self):
        return shutil.which('wtype') is not None

    def parse_accel(self, accel):
        """'<Ctrl><Shift>P' -> (['ctrl', 'shift'], 'p') or None."""
        mods = []
        rest = accel
        while rest.startswith('<'):
            end = rest.find('>')
            if end < 0:
                return None
            token = rest[1:end].lower()
            if token == 'meta':
                return None
            if token not in MODIFIER_MAP:
                return None
            mods.append(MODIFIER_MAP[token])
            rest = rest[end + 1:]
        rest = rest.strip()
        if not rest or len(rest) > 20:
            return None
        if len(rest) == 1:
            key = rest.lower() if rest.isalpha() else rest
            return mods, key
        key = NAMED_KEYS.get(rest.lower(), rest)
        return mods, key

    def send(self, accel, delay_ms=0):
        parsed = self.parse_accel(accel)
        if parsed is None:
            self._log('unparseable accelerator: %r' % accel)
            return False
        mods, key = parsed
        if delay_ms:
            timer = threading.Timer(delay_ms / 1000.0, self._type,
                                    args=(mods, key))
            timer.daemon = True
            timer.start()
        else:
            self._type(mods, key)
        return True

    def activate_action(self, bus_name, object_path, action, target=None,
                        fallback_accel=None, delay_ms=0):
        """Activate a GTK action on the application's action bus.

        Calls org.gtk.Actions.Activate at the application object path;
        if the call fails (no action bus, refused, timeout) the fallback
        accelerator is typed into the focused window instead.
        """
        if delay_ms:
            timer = threading.Timer(
                    delay_ms / 1000.0, self._activate_action,
                    args=(bus_name, object_path, action, target,
                          fallback_accel))
            timer.daemon = True
            timer.start()
        else:
            self._activate_action(bus_name, object_path, action, target,
                                  fallback_accel)

    def _activate_action(self, bus_name, object_path, action, target,
                         fallback_accel):
        try:
            from gi.repository import Gio, GLib
        except ImportError:
            self._log('gio unavailable; typing accelerator instead of '
                      'activating %r' % action)
            self._fallback_type(fallback_accel)
            return
        parameters = [] if target is None else [GLib.Variant('i', int(target))]
        try:
            bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            bus.call_sync(bus_name, object_path, 'org.gtk.Actions',
                          'Activate',
                          GLib.Variant('(sava{sv})',
                                       (action, parameters, {})),
                          None, Gio.DBusCallFlags.NONE, 2000, None)
            return
        except Exception as exc:
            self._log('action %r failed on %s: %s'
                      % (action, bus_name, exc))
        self._fallback_type(fallback_accel)

    def _fallback_type(self, accel):
        if accel:
            self.send(accel)

    def _type(self, mods, key):
        argv = ['wtype']
        for mod in mods:
            argv += ['-M', mod]
        argv += ['-P', key, '-p', key]
        for mod in reversed(mods):
            argv += ['-m', mod]
        try:
            with self._lock:
                result = subprocess.run(
                        argv, capture_output=True, timeout=5)
        except (OSError, subprocess.SubprocessError) as exc:
            self._log('wtype failed: %s' % exc)
            return
        if result.returncode != 0:
            self._log('wtype exit %d: %s' % (
                    result.returncode,
                    result.stderr.decode('utf-8', 'replace').strip()))
