#!/usr/bin/env python3
"""
menureader.py - reads application menus over the session bus.

Two protocols, both part of the classic Linux global menu stack:

* DbusMenuReader   com.canonical.dbusmenu - exported by Qt, Electron,
                   Chromium and Firefox apps. The app registers its menu
                   with com.canonical.AppMenu.Registrar and we read the
                   layout from the registered (sender, object path).
* GtkMenuReader    org.gtk.Menus + org.gtk.Actions - exported by GTK 3/4
                   applications that set a menubar with
                   gtk_application_set_menubar. Without a compositor
                   handing us the window properties we discover the bus
                   name and object paths by probing the focused app id.

Both build the same plain dict tree used by the bridge:
  { label, key, enabled, toggleType, toggleState, accel?, children? }
  children entries may be {"separator": True}
Activation is by the full path key ("File  »  Open  »  Recent").
"""

import functools
import time
import traceback

import dbus

from gi.repository import GLib

from treelib import Tree

from menu_item import DbusGtkMenuItem, DbusAppMenuItem

CLIENT_TIMEOUT = 2          # seconds; a frozen app must not hold us
LABEL_SEPARATOR = u'\u0020\u0020\u00bb\u0020\u0020'


def format_label(parts):
    return LABEL_SEPARATOR.join(parts)


def claim_key(item, actions):
    key, n = item.text, 2
    while key in actions:
        key = '%s  #%d' % (item.text, n)
        n += 1
    item.text = key
    return key


class BaseReader(object):

    def __init__(self, session, on_changed=None):
        self.session = session
        self.on_changed = on_changed
        self.tree = Tree()
        self.actions = {}
        self.accels = {}
        self.top_level_menus = []
        self.signal_matcher = []
        self._update_timer = 0

    # lifecycle -----------------------------------------------------------

    def start(self):
        raise NotImplementedError

    def stop(self):
        for matcher in self.signal_matcher:
            try:
                matcher.remove()
            except Exception:
                pass
        self.signal_matcher = []
        if self._update_timer:
            GLib.source_remove(self._update_timer)
            self._update_timer = 0

    # shared --------------------------------------------------------------

    def _notify(self):
        if self.on_changed is not None:
            self.on_changed()

    def schedule_refresh(self, delay_ms=200):
        if self._update_timer == 0:
            self._update_timer = GLib.timeout_add(delay_ms, self._refresh_now)

    def _refresh_now(self):
        self._update_timer = 0
        self.refresh()
        self._notify()
        return False

    def refresh(self):
        raise NotImplementedError

    def empty(self):
        root = self.tree.get_node(self.tree.root) if self.tree.root is not None else None
        return root is None or not self.tree.children(root.identifier)

    def activate(self, selection):
        action = self.actions.get(selection)
        if action is None:
            return False
        return self._activate_action(selection, action)

    def _activate_action(self, selection, action):
        raise NotImplementedError


# ---------------------------------------------------------------------------
# com.canonical.dbusmenu
# ---------------------------------------------------------------------------

class DbusMenuReader(BaseReader):

    def __init__(self, session, sender, menu_path, on_changed=None):
        BaseReader.__init__(self, session, on_changed)
        self.sender = sender
        self.menu_path = menu_path
        self.interface = None
        self.results = None

    def start(self):
        try:
            obj = self.session.get_object(self.sender, self.menu_path)
            self.interface = dbus.Interface(obj, 'com.canonical.dbusmenu')
            for signal, handler in (
                    ('ItemsPropertiesUpdated', self.on_actions_changed),
                    ('LayoutUpdated', self.layout_updated),
                    ('ItemActivationRequested', self.on_activation_requested)):
                self.signal_matcher.append(
                        self.interface.connect_to_signal(signal, handler))
        except dbus.exceptions.DBusException:
            self.interface = None

    def refresh(self):
        if self.interface is None:
            return
        try:
            self.results = self.interface.GetLayout(
                    0, -1, dbus.Array(signature='s'), timeout=CLIENT_TIMEOUT)
            self.collect_entries(self.results[1])
        except dbus.exceptions.DBusException:
            traceback.print_exc()
            self.clear()
            return
        if self.empty():
            self.clear()

    def clear(self):
        self.actions = {}
        self.accels = {}
        self.tree = Tree()
        self.top_level_menus = []

    def collect_entries(self, item=None, labels=None, parent=None):
        if self.results is None:
            return
        if item is None:
            item = self.results[1]
        if labels is None:
            labels = []
        menu_item = DbusAppMenuItem(item, labels)
        menu_path = labels

        if 'children-display' in item[1]:
            item_id = item[0]
            try:
                self.interface.AboutToShow(item_id, timeout=CLIENT_TIMEOUT)
            except Exception:
                pass
            try:
                self.interface.Event(item_id, 'opened', 'not used',
                                     dbus.UInt32(time.time()), timeout=CLIENT_TIMEOUT)
                item = self.interface.GetLayout(
                        item_id, -1, dbus.Array(signature='s'),
                        timeout=CLIENT_TIMEOUT)[1]
                # qt apps stay in menu open state and stop taking keys
                # unless the menu is closed again
                self.interface.Event(item_id, 'closed', 'not used',
                                     dbus.UInt32(time.time()), timeout=CLIENT_TIMEOUT)
            except dbus.exceptions.DBusException:
                pass

        if bool(menu_item.label) and menu_item.label not in ('Root', 'DBusMenuRoot'):
            menu_path = labels + [menu_item.label]

        try:
            self.tree.create_node(menu_item.label, menu_item.action, parent,
                                  data=menu_item)
        except Exception:
            return
        children = item[2] if len(item) > 2 else []
        if children:
            if not self.top_level_menus:
                self.top_level_menus = [c[1].get('label', '') for c in children]
            for child in children:
                self.collect_entries(child, menu_path, menu_item.action)
        elif bool(menu_item.label) or menu_item.separator:
            self.actions[claim_key(menu_item, self.actions)] = menu_item.action

    # dbusmenu signals -----------------------------------------------------

    def on_actions_changed(self, updated, removed):
        touched = False
        for upd in updated:
            node = self.tree.get_node(int(upd[0]))
            if node is not None:
                node.data.update_props(upd[1])
                if 'children-display' in upd[1]:
                    self.schedule_refresh()
                    return
                touched = True
        if touched:
            self.schedule_refresh(0)

    def layout_updated(self, revision, parent):
        self.schedule_refresh()

    def on_activation_requested(self, item_id, event_id):
        pass

    def _activate_action(self, selection, action):
        try:
            self.interface.Event(action, 'clicked', 0, 0, timeout=CLIENT_TIMEOUT)
            return True
        except dbus.exceptions.DBusException:
            return False


# ---------------------------------------------------------------------------
# GTK org.gtk.Menus / org.gtk.Actions
# ---------------------------------------------------------------------------

class GtkMenuReader(BaseReader):

    def __init__(self, session, bus_name, app_path, win_path,
                 menubar_path, appmenu_path, on_changed=None):
        BaseReader.__init__(self, session, on_changed)
        self.bus_name = bus_name
        self.app_path = app_path
        self.win_path = win_path
        self.menubar_path = menubar_path
        self.appmenu_path = appmenu_path
        self.results = {}
        self.groups = {}
        self.menu_interfaces = {}
        self.targets = {}
        self.nodes_by_action = {}
        self.action_groups = {}
        self._node_seq = 0
        self._rebuild_id = 0

    def start(self):
        for path in filter(None, (self.menubar_path, self.appmenu_path)):
            try:
                obj = self.session.get_object(self.bus_name, path)
                interface = dbus.Interface(obj, dbus_interface='org.gtk.Menus')
            except dbus.exceptions.DBusException:
                continue
            # listen before start so no change is missed
            self.signal_matcher.append(interface.connect_to_signal(
                    'Changed', functools.partial(self.on_menus_changed, path)))
            self.menu_interfaces[path] = interface
            self.results[path] = {}
            self.groups[path] = set()
            try:
                self._sync_groups(path)
            except dbus.exceptions.DBusException:
                del self.results[path]
                self.groups.pop(path, None)
        if self.results:
            self.watch_actions()
        self.refresh()

    def refresh(self):
        for path in list(self.results):
            try:
                self._sync_groups(path)
            except dbus.exceptions.DBusException:
                pass
        self.build_tree()

    def activate(self, selection):
        action = self.actions.get(selection)
        if action is None:
            return False
        prefix, _dot, _name = action.partition('.')
        path = {'app': self.app_path, 'win': self.win_path,
                'unity': self.menubar_path}.get(prefix)
        if not path:
            return False
        target = self.targets.get(selection)
        try:
            obj = self.session.get_object(self.bus_name, path)
            interface = dbus.Interface(obj, dbus_interface='org.gtk.Actions')
            # target keeps its dbus type so it must match the action parameter
            parameter = dbus.Array([] if target is None else [target], signature='v')
            interface.Activate(action.replace(prefix + '.', '', 1), parameter,
                               dbus.Dictionary({}, signature='sv'),
                               timeout=CLIENT_TIMEOUT)
            return True
        except dbus.exceptions.DBusException:
            return False

    # org.gtk.Menus --------------------------------------------------------

    def _linked_groups(self, menus):
        groups = set()
        seen = set()
        todo = [(0, 0)]
        while todo:
            key = todo.pop()
            if key in seen:
                continue
            seen.add(key)
            groups.add(key[0])
            for item in menus.get(key, []):
                for link in (':section', ':submenu'):
                    if link in item:
                        todo.append((int(item[link][0]), int(item[link][1])))
        return groups

    def _sync_groups(self, path):
        menus = self.results[path]
        groups = self.groups[path]
        interface = self.menu_interfaces[path]
        while True:
            linked = self._linked_groups(menus)
            new = sorted(linked - groups)
            if not new:
                break
            groups.update(new)
            for group, menu, items in interface.Start(
                    dbus.Array(new, signature='u'), timeout=CLIENT_TIMEOUT):
                menus[(int(group), int(menu))] = list(items)

        dead = sorted(groups - linked)
        if dead:
            groups.difference_update(dead)
            for key in [k for k in menus if k[0] in dead]:
                del menus[key]
            try:
                interface.End(dbus.Array(dead, signature='u'), ignore_reply=True)
            except dbus.exceptions.DBusException:
                pass

    def on_menus_changed(self, path, changes):
        menus = self.results.get(path)
        if menus is None:
            return
        changed = False
        for group, menu, position, removed, added in changes:
            if group not in self.groups.get(path, ()):
                continue
            items = menus.setdefault((int(group), int(menu)), [])
            items[position:position + removed] = list(added)
            changed = True
        # gtk sends one signal per changed menu so rebuild once per burst
        if changed and not self._rebuild_id:
            self._rebuild_id = GLib.idle_add(self._rebuild)

    def _rebuild(self):
        self._rebuild_id = 0
        try:
            for path in self.results:
                self._sync_groups(path)
        except dbus.exceptions.DBusException:
            pass
        self.build_tree()
        self._notify()
        return False

    # org.gtk.Actions ------------------------------------------------------

    def _actions_path(self, prefix):
        return {'app': self.app_path, 'win': self.win_path,
                'unity': self.menubar_path}.get(prefix)

    def _action_group(self, prefix):
        if prefix in self.action_groups:
            return self.action_groups[prefix]
        path = self._actions_path(prefix)
        if not path:
            self.action_groups[prefix] = None
            return None
        try:
            obj = self.session.get_object(self.bus_name, path)
            described = dbus.Interface(obj, dbus_interface='org.gtk.Actions')
            raw = described.DescribeAll(timeout=CLIENT_TIMEOUT)
            group = {str(name): (desc[0], list(desc[2]))
                     for name, desc in raw.items()}
        except dbus.exceptions.DBusException:
            self.action_groups[prefix] = None
            return None
        self.action_groups[prefix] = group
        return group

    def _apply_action(self, item):
        prefix, dot, name = item.action.partition('.')
        group = self._action_group(prefix + dot)
        if group is None:
            return
        enabled, state = group.get(name, (False, []))
        item.enabled = bool(enabled)
        item.toggle_type = ''
        item.toggle_state = False
        item.set_toggle(state)

    def watch_actions(self):
        for prefix in ('app', 'win', 'unity'):
            path = self._actions_path(prefix)
            if not path:
                continue
            try:
                obj = self.session.get_object(self.bus_name, path)
                iface = dbus.Interface(obj, dbus_interface='org.gtk.Actions')
                self.signal_matcher.append(iface.connect_to_signal(
                        'Changed', functools.partial(
                            self.on_gtk_actions_changed, prefix)))
            except dbus.exceptions.DBusException:
                continue

    def on_gtk_actions_changed(self, prefix, removed, enabled_changed,
                               state_changed, added):
        group = self.action_groups.get(prefix)
        if group is not None:
            for name in removed:
                group.pop(name, None)
            for name, (enabled, _parameter_type, state) in added.items():
                group[name] = (enabled, list(state))
            for name, enabled in enabled_changed.items():
                group[name] = (enabled, group.get(name, (True, []))[1])
            for name, state in state_changed.items():
                group[name] = (group.get(name, (True, []))[0], [state])

        touched = False
        for name in {*removed, *enabled_changed, *state_changed, *added}:
            for node_id in self.nodes_by_action.get(prefix + '.' + name, []):
                node = self.tree.get_node(node_id)
                if node is not None:
                    self._apply_action(node.data)
                    touched = True
        if touched:
            self.schedule_refresh(0)

    # tree -----------------------------------------------------------------

    def build_tree(self):
        self.tree = Tree()
        self.tree.create_node('Root', 'Root')
        self.actions = {}
        self.targets = {}
        self.nodes_by_action = {}
        self.top_level_menus = []
        self._node_seq = 0

        menubar = self.results.get(self.menubar_path)
        if menubar:
            self.collect_entries(menubar, [], 'Root')

        app_menu = self.results.get(self.appmenu_path)
        if app_menu:
            menu_item = DbusGtkMenuItem({'label': ''})
            menu_item.app_menu = True
            node_id = self._new_node_id()
            self.tree.create_node('', node_id, 'Root', data=menu_item)
            self.collect_entries(app_menu, [''], node_id)
            if not self.tree.children(node_id):
                self.tree.remove_node(node_id)

        if not self.tree.children('Root'):
            self.tree = Tree()

    def collect_entries(self, menus, labels, parent, link=(0, 0)):
        section = (link[0], link[1])
        for menu in menus.get(section, []):
            if ':section' in menu:
                self.collect_entries(menus, labels, parent, menu[':section'])
            elif 'label' in menu:
                if len(labels) == 0:
                    self.top_level_menus.append(menu.get('label', None))

                menu_item = DbusGtkMenuItem(menu, labels)
                menu_item.section = section
                self._apply_action(menu_item)

                menu_path = labels + [menu_item.label]
                node_id = self._new_node_id()
                try:
                    self.tree.create_node(menu_item.label, node_id, parent,
                                          data=menu_item)
                except Exception:
                    continue
                if menu_item.action:
                    self.nodes_by_action.setdefault(
                            menu_item.action, []).append(node_id)

                if ':submenu' in menu:
                    self.collect_entries(menus, menu_path, node_id,
                                         menu[':submenu'])
                elif 'action' in menu:
                    key = claim_key(menu_item, self.actions)
                    self.actions[key] = menu_item.action
                    if menu_item.target is not None:
                        self.targets[key] = menu_item.target

    def _new_node_id(self):
        self._node_seq += 1
        return 'n%d' % self._node_seq

    def stop(self):
        BaseReader.stop(self)
        if self._rebuild_id:
            GLib.source_remove(self._rebuild_id)
            self._rebuild_id = 0
        for path, groups in self.groups.items():
            if not groups:
                continue
            try:
                self.menu_interfaces[path].End(
                        dbus.Array(sorted(groups), signature='u'),
                        ignore_reply=True)
            except dbus.exceptions.DBusException:
                pass
        self.groups = {}
