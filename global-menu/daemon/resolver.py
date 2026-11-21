#!/usr/bin/env python3
"""
resolver.py - links the focused window to an exported menu.

A global menu needs two things the Wayland protocol world does not hand
us directly:

1. which menus exist. Applications publish theirs in one of two ways:
   they call com.canonical.AppMenu.Registrar.RegisterWindow(windowId,
   menuObjectPath) (Qt, Electron, Chromium, Firefox under X11/XWayland),
   or they are GTK applications exporting org.gtk.Menus on the session
   bus at paths derived from their application id.

2. which menu belongs to the focused window. Registration uses X11
   window ids that Wayland does not expose to us, so instead we match
   by application identity: the registrar sender's unix PID gives us
   /proc/<pid>/cmdline and /proc/<pid>/exe; the focused toplevel's
   app_id comes from wlr-foreign-toplevel. Both sides are normalised
   (lowercased, punctuation stripped) and compared. When toplevel
   tracking is unavailable we fall back to the only registration if
   there is exactly one.

Everything here is pure session-bus + /proc + Wayland - no compositor
IPC of any kind.
"""

import os
import re
import time

import dbus
import dbus.service

from gi.repository import GLib

REGISTRAR_NAME = 'com.canonical.AppMenu.Registrar'
REGISTRAR_PATH = '/com/canonical/AppMenu/Registrar'

NEG_TTL = 30.0               # seconds a failed probe stays cached
DISCOVERED_TTL = 10.0        # seconds a found unregistered menubar is reused
# last reverse-DNS segments too generic to identify an application
_GENERIC_SEGMENTS = {'app', 'application', 'client', 'desktop', 'gui',
                     'launcher', 'main'}

_POLL_EXTERNAL_MS = 2000


def normalize(text):
    if not text:
        return ''
    return re.sub(r'[^a-z0-9]+', '', str(text).lower())


def basename(path):
    return os.path.basename(path.rstrip('/')) if path else ''


class Registration(object):

    def __init__(self, window_id, sender, menu_path):
        self.window_id = window_id
        self.sender = sender
        self.menu_path = menu_path
        self.pid = None
        self.identities = set()      # normalised identity tokens
        self.bus_names = set()       # well-known names of the sender

    def __repr__(self):
        return '<Registration %s %s pid=%s ids=%s>' % (
                self.window_id, self.menu_path, self.pid,
                sorted(self.identities))


class Registrar(object):
    """Owns com.canonical.AppMenu.Registrar and tracks registrations."""

    def __init__(self, session, on_change=None, log=None):
        self.session = session
        self.on_change = on_change or (lambda: None)
        self._log = log or (lambda msg: None)
        self.owned = False
        self.external = False
        self.registrations = {}      # window_id -> Registration
        self._pid_cache = {}         # sender -> pid
        self._no_menubar = {}        # sender -> time its probe failed
        self._discovered = {}        # app id -> (time, (sender, path))
        self._objects = []

        self._observe_name_owner()
        self._try_own()
        if not self.owned:
            self._adopt_external()

    # ------------------------------------------------------------- owning

    def _observe_name_owner(self):
        bus = self.session
        bus.add_signal_receiver(self._name_owner_changed, 'NameOwnerChanged',
                                'org.freedesktop.DBus',
                                'org.freedesktop.DBus',
                                '/org/freedesktop/DBus')

    def _name_owner_changed(self, name, old, new):
        if name == REGISTRAR_NAME:
            self._log('registrar owner changed: %s -> %s' % (old, new))
            self._retry_ownership()

    def _retry_ownership(self):
        # losing or gaining the name outside our control - re-evaluate once
        if not self.owned and not self.external:
            GLib.timeout_add(1000, self._try_own_once)

    def _try_own_once(self):
        try:
            self._try_own()
            if not self.owned:
                self._adopt_external()
        except dbus.exceptions.DBusException as exc:
            self._log('registrar ownership retry failed: %s' % exc)
        return False

    def _try_own(self):
        try:
            bus_name = dbus.service.BusName(REGISTRAR_NAME, self.session,
                                            do_not_queue=True)
        except dbus.exceptions.DBusException as exc:
            # another registrar (often appmenu-gtk-module or a daemon that
            # survived a plugin restart) owns the name: adopt it instead of
            # letting setup abort. _poll_external takes over if it dies.
            self.owned = False
            self._log('could not own %s: %s' % (REGISTRAR_NAME, exc))
            return False
        service = _RegistrarService(bus_name, self)
        self._objects.append(service)
        self.owned = True
        self._log('owning %s' % REGISTRAR_NAME)
        return True

    def _adopt_external(self):
        self.external = True
        self._log('another registrar owns %s; adopting it' % REGISTRAR_NAME)
        GLib.timeout_add(_POLL_EXTERNAL_MS, self._poll_external)
        self._poll_external()

    def _poll_external(self):
        if not self.external:
            return False
        try:
            obj = self.session.get_object(REGISTRAR_NAME, REGISTRAR_PATH)
            menus = obj.GetMenus(timeout=2)
            fresh = {}
            for window_id, (sender, path) in menus.items():
                fresh[int(window_id)] = (str(sender), str(path))
            if fresh != {w: (r.sender, r.menu_path)
                         for w, r in self.registrations.items()}:
                self._rebuild(fresh)
        except dbus.exceptions.DBusException:
            # external registrar went away - try to take over
            self.external = False
            self.registrations = {}
            GLib.timeout_add(1000, self._try_own_once)
            self.on_change()
            return False
        return True

    # -------------------------------------------------- registrar service

    def register_window(self, window_id, menu_path, sender):
        self.registrations[int(window_id)] = Registration(
                int(window_id), str(sender), str(menu_path))
        self._log('registered window %s -> %s (%s)' %
                  (window_id, menu_path, sender))
        self.on_change()

    def unregister_window(self, window_id):
        if int(window_id) in self.registrations:
            del self.registrations[int(window_id)]
            self._log('unregistered window %s' % window_id)
            self.on_change()

    def registrations_died(self, sender):
        # a bus name vanished; drop its registrations and everything
        # cached about it, so the per-sender caches stay bounded
        self._pid_cache.pop(sender, None)
        self._no_menubar.pop(sender, None)
        for app_id in [a for a, (_t, hit) in self._discovered.items()
                       if hit[0] == sender]:
            del self._discovered[app_id]
        dead = [w for w, r in self.registrations.items() if r.sender == sender]
        for window_id in dead:
            del self.registrations[window_id]
        if dead:
            self._log('%s died; dropped %d registrations' % (sender, len(dead)))
            self.on_change()

    def _rebuild(self, mapping):
        self.registrations = {w: Registration(w, s, p)
                              for w, (s, p) in mapping.items()}
        self.on_change()

    # -------------------------------------------------------- identities

    def _sender_pid(self, sender):
        if sender in self._pid_cache:
            return self._pid_cache[sender]
        pid = None
        try:
            obj = self.session.get_object('org.freedesktop.DBus',
                                          '/org/freedesktop/DBus')
            pid = int(obj.GetConnectionUnixProcessID(sender, timeout=2))
        except dbus.exceptions.DBusException:
            pid = None
        self._pid_cache[sender] = pid
        return pid

    def _identity_for(self, registration):
        if registration.identities:
            return registration.identities
        pid = registration.pid = self._sender_pid(registration.sender)
        registration.identities = self._identity_for_pid(pid)
        return registration.identities

    def _identity_for_pid(self, pid):
        tokens = set()
        if pid:
            for path in self._proc_paths(pid):
                base = basename(path)
                if base:
                    tokens.add(normalize(base))
            try:
                with open('/proc/%d/cmdline' % pid, 'rb') as handle:
                    args = handle.read().split(b'\x00')
                argv0 = args[0].decode('utf-8', 'replace') if args else ''
                if basename(argv0):
                    tokens.add(normalize(basename(argv0)))
            except OSError:
                pass
        tokens.discard('')
        return tokens

    @staticmethod
    def _proc_paths(pid):
        paths = []
        try:
            paths.append(os.path.realpath('/proc/%d/exe' % pid))
        except OSError:
            pass
        return [p for p in paths if p and p != '/']

    # ------------------------------------------------------------- match

    def match(self, app_id, title, toplevels_available):
        if not self.registrations:
            return None

        exact, loose = self._wanted(app_id)
        # a window title sometimes carries the binary name; weak signal,
        # used only if identity matching fails below

        # the whole app id first; the last reverse-DNS segment only when
        # nothing matches exactly, so two apps sharing a last segment
        # cannot take each other's menus when one of them matches exactly
        best = None
        for wanted in (exact, loose):
            if not wanted:
                continue
            for registration in self.registrations.values():
                if self._identity_for(registration) & wanted:
                    best = registration
                    break
            if best is not None:
                break

        if best is None and len(self.registrations) == 1 and \
                not toplevels_available:
            # no way to know what is focused; a single registration is
            # very likely the app the user is using
            best = next(iter(self.registrations.values()))

        return (best.sender, best.menu_path) if best else None

    @staticmethod
    def _wanted(app_id):
        """(exact, loose) identity tokens for an app id.

        exact is the whole normalised id. loose is the last segment of a
        reverse-DNS id, so 'org.kde.dolphin' or a flatpak's
        'org.mozilla.firefox' can match its 'dolphin' / 'firefox' binary;
        it stays empty when that segment is too generic to identify an
        app ('org.example.App' must not match every 'app' binary)."""
        exact = {normalize(app_id)} - {''}
        loose = set()
        if app_id and '.' in str(app_id):
            last = normalize(str(app_id).rsplit('.', 1)[-1])
            if len(last) >= 3 and last not in _GENERIC_SEGMENTS:
                loose = {last} - exact
        return exact, loose

    # ------------------------------------------------ unregistered menus

    def discover_unregistered(self, app_id):
        """Qt applications on compositors without KDE's appmenu Wayland
        protocol hide their menubar and export it at /MenuBar/<n>, but
        never call RegisterWindow, so the registrar never hears of them.
        Look for those objects on the bus connections of processes whose
        identity matches the focused app, and pick the menubar with the
        most top-level menus (the main window rather than a tool window).

        A hit is cached per app id for DISCOVERED_TTL seconds and dropped
        as soon as its bus name vanishes (registrations_died), so refocusing
        the app does not repeat the ListNames/Introspect/GetLayout round."""
        now = time.monotonic()
        cached = self._discovered.get(app_id)
        if cached is not None:
            if now - cached[0] < DISCOVERED_TTL:
                return cached[1]
            del self._discovered[app_id]

        exact, loose = self._wanted(app_id)
        if not exact and not loose:
            return None
        try:
            obj = self.session.get_object('org.freedesktop.DBus',
                                          '/org/freedesktop/DBus')
            names = obj.ListNames(dbus_interface='org.freedesktop.DBus',
                                  timeout=2)
        except dbus.exceptions.DBusException:
            return None
        # rank: an exact identity match beats a last-segment one, then
        # the menubar with more top-level menus wins
        best, rank = None, (0, 0)
        for name in names:
            name = str(name)
            if not name.startswith(':'):
                continue
            if now - self._no_menubar.get(name, -NEG_TTL) < NEG_TTL:
                continue
            pid = self._sender_pid(name)
            if not pid:
                continue
            identity = self._identity_for_pid(pid)
            tier = 2 if identity & exact else 1 if identity & loose else 0
            if not tier:
                continue
            found = False
            for path in self._menubar_paths(name):
                count = self._top_level_count(name, path)
                if count is None:
                    continue
                found = True
                if (tier, count) > rank:
                    best, rank = (name, path), (tier, count)
            if not found:
                # a hung or menu-less process: do not ask it again soon
                self._no_menubar[name] = now
        if best:
            self._discovered[app_id] = (now, best)
            self._log('unregistered menubar %s %s for %s'
                      % (best[0], best[1], app_id))
        return best

    def _menubar_paths(self, name):
        try:
            obj = self.session.get_object(name, '/MenuBar',
                                          introspect=False)
            xml = str(obj.Introspect(
                    dbus_interface='org.freedesktop.DBus.Introspectable',
                    timeout=1))
        except dbus.exceptions.DBusException:
            return []
        return ['/MenuBar/' + node
                for node in re.findall(r'<node name="(\d+)"', xml)]

    def _top_level_count(self, name, path):
        try:
            obj = self.session.get_object(name, path, introspect=False)
            layout = obj.GetLayout(0, 1, dbus.Array([], signature='s'),
                                   dbus_interface='com.canonical.dbusmenu',
                                   timeout=1)
            return len(layout[1][2])
        except (dbus.exceptions.DBusException, IndexError, TypeError):
            return None


class _RegistrarService(dbus.service.Object):
    """The com.canonical.AppMenu.Registrar interface apps call."""

    def __init__(self, bus_name, owner):
        dbus.service.Object.__init__(self, bus_name, REGISTRAR_PATH)
        self.owner = owner

    @dbus.service.method(REGISTRAR_NAME, in_signature='uo',
                         sender_keyword='sender')
    def RegisterWindow(self, windowId, menuObjectPath, sender=None):
        self.owner.register_window(int(windowId), str(menuObjectPath),
                                   str(sender))

    @dbus.service.method(REGISTRAR_NAME, in_signature='u')
    def UnregisterWindow(self, windowId):
        self.owner.unregister_window(windowId)

    @dbus.service.method(REGISTRAR_NAME, in_signature='u', out_signature='so')
    def GetMenuForWindow(self, windowId):
        reg = self.owner.registrations.get(int(windowId))
        if reg:
            return dbus.Struct((dbus.String(reg.sender),
                                dbus.ObjectPath(reg.menu_path)))
        raise dbus.exceptions.DBusException(
                'com.canonical.AppMenu.Registrar.Error.NoMenuForWindow')

    @dbus.service.method(REGISTRAR_NAME, out_signature='a{u(so)}')
    def GetMenus(self):
        out = {}
        for window_id, reg in self.owner.registrations.items():
            out[dbus.UInt32(window_id)] = dbus.Struct((
                    dbus.String(reg.sender),
                    dbus.ObjectPath(reg.menu_path)))
        return out

    @dbus.service.signal(REGISTRAR_NAME, signature='uo')
    def WindowRegistered(self, windowId, menuObjectPath):
        pass

    @dbus.service.signal(REGISTRAR_NAME, signature='u')
    def WindowUnregistered(self, windowId):
        pass


# ---------------------------------------------------------------------------
# GTK application menu discovery
# ---------------------------------------------------------------------------

INTROSPECT_IFACE = 'org.freedesktop.DBus.Introspectable'


class GtkProbe(object):
    """Discovers GTK menubar export paths for an application id.

    GtkApplication exports org.gtk.Actions at the application object path
    (/org/gnome/Nautilus for app id org.gnome.Nautilus) and the menubar
    GMenuModel with org.gtk.Menus under <app path>/menus/menubar (the app
    menu, when present, under /menus/appmenu). Window actions live under
    <app path>/window/<n>. We confirm every path with a D-Bus Introspect
    before using it, so nothing is assumed.
    """

    def __init__(self, session, log=None):
        self.session = session
        self._log = log or (lambda msg: None)
        self._neg_cache = {}         # bus_name -> time of last failure

    def discover(self, app_id):
        if not app_id or '.' not in app_id:
            return None
        bus_name = app_id
        failed_at = self._neg_cache.get(bus_name)
        if failed_at is not None and time.time() - failed_at < NEG_TTL:
            return None
        try:
            owner = self.session.get_object('org.freedesktop.DBus',
                                            '/org/freedesktop/DBus')
            if not owner.NameHasOwner(bus_name, timeout=2):
                self._neg_cache[bus_name] = time.time()
                return None
        except dbus.exceptions.DBusException:
            self._neg_cache[bus_name] = time.time()
            return None

        app_path = '/' + bus_name.replace('.', '/')
        if not self._introspectable(bus_name, app_path):
            self._neg_cache[bus_name] = time.time()
            return None

        win_path = self._find_window_path(bus_name, app_path)
        menubar_path, appmenu_path = self._find_menu_paths(bus_name, app_path)
        if not menubar_path and not appmenu_path:
            self._neg_cache[bus_name] = time.time()
            return None

        self._log('gtk probe %s: bus=%s app=%s win=%s menubar=%s appmenu=%s'
                  % (app_id, bus_name, app_path, win_path, menubar_path,
                     appmenu_path))
        return {
            'bus_name': bus_name,
            'app_path': app_path,
            'win_path': win_path,
            'menubar_path': menubar_path,
            'appmenu_path': appmenu_path,
        }

    def _introspectable(self, bus_name, path):
        xml = self._introspect(bus_name, path)
        return xml is not None and 'org.gtk.Actions' in xml

    def _find_window_path(self, bus_name, app_path):
        xml = self._introspect(bus_name, app_path)
        if not xml or '/window"' not in xml and "name='window'" not in xml \
                and 'name="window"' not in xml:
            return None
        win_dir = app_path + '/window'
        xml = self._introspect(bus_name, win_dir)
        if not xml:
            return None
        for number in re.findall(r'name=["\'](\d+)["\']', xml):
            candidate = win_dir + '/' + number
            if self._introspect(bus_name, candidate) is not None:
                return candidate
        return None

    def _find_menu_paths(self, bus_name, app_path):
        candidates = []
        xml = self._introspect(bus_name, app_path)
        if xml and ('name="menus"' in xml or "name='menus'" in xml):
            menus_dir = app_path + '/menus'
            sub = self._introspect(bus_name, menus_dir)
            if sub:
                for child in re.findall(r'name=["\']([^"\']+)["\']', sub):
                    candidates.append(menus_dir + '/' + child)
        if not candidates:
            # standard GtkApplication layout, verified anyway
            candidates = [app_path + '/menus/menubar',
                          app_path + '/menus/appmenu']
        menubar_path = None
        appmenu_path = None
        for candidate in candidates:
            xml = self._introspect(bus_name, candidate)
            if not xml or 'org.gtk.Menus' not in xml:
                continue
            if candidate.endswith('/menubar'):
                menubar_path = candidate
            elif candidate.endswith('/appmenu'):
                appmenu_path = candidate
        return menubar_path, appmenu_path

    def _introspect(self, bus_name, path):
        try:
            obj = self.session.get_object(bus_name, path)
            iface = dbus.Interface(obj, INTROSPECT_IFACE)
            return str(iface.Introspect(timeout=2))
        except dbus.exceptions.DBusException:
            return None
