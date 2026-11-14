#!/usr/bin/env python3
"""
shortcuts.py - shortcut menus for applications that export nothing.

Each mapping file describes one application's menu bar. A leaf item
carries either a GTK action to activate on the application's action
bus (optionally with an integer target and a fallback accelerator), a
plain GTK accelerator string that is typed into the focused window on
click, or both (the action wins, the accelerator is the fallback -
see keyer.py). Items with neither are disabled placeholders. The 293
built-in mappings ship bundled in shortcuts/apps.zip; loose *.json
files dropped in shortcuts/apps (or the user directory
~/.config/noctalia/global-menu/shortcuts/apps) override the bundled
entry with the same name outright.
"""

import json
import os
import zipfile


class ShortcutStore(object):

    def __init__(self, builtin_dir, user_dir=None, log=None):
        self.builtin_dir = builtin_dir
        self.user_dir = user_dir
        self._log = log or (lambda msg: None)
        self.mappings = {}           # app -> mapping dict
        self.warnings = []
        self.reload()

    def reload(self):
        self.mappings = {}
        self.warnings = []
        # the bundled archive loads first; a loose file with the same
        # name (shipped apps/ dir or the user directory) replaces it
        if self.builtin_dir:
            bundle = self.builtin_dir.rstrip('/') + '.zip'
            if os.path.isfile(bundle):
                self._load_bundle(bundle)
        files = {}
        if self.builtin_dir and os.path.isdir(self.builtin_dir):
            for name in sorted(os.listdir(self.builtin_dir)):
                if name.endswith('.json'):
                    files[name] = os.path.join(self.builtin_dir, name)
        if self.user_dir and os.path.isdir(self.user_dir):
            for name in sorted(os.listdir(self.user_dir)):
                if name.endswith('.json'):
                    files[name] = os.path.join(self.user_dir, name)
        for name, path in files.items():
            mapping = self._load(name, path)
            if mapping is not None:
                self.mappings[mapping.get('app', name[:-5])] = mapping

    def _load_bundle(self, bundle):
        """Load mapping JSONs straight out of apps.zip - no extraction."""
        try:
            with zipfile.ZipFile(bundle) as archive:
                for info in archive.infolist():
                    name = os.path.basename(info.filename)
                    if info.is_dir() or not name.endswith('.json'):
                        continue
                    try:
                        data = json.loads(
                                archive.read(info).decode('utf-8'))
                    except (ValueError, UnicodeDecodeError) as exc:
                        self.warnings.append('%s: %s' % (name, exc))
                        continue
                    if isinstance(data, dict) and 'menus' in data:
                        self.mappings[data.get('app', name[:-5])] = data
                    else:
                        self.warnings.append(
                                '%s: not a mapping file' % name)
        except (OSError, zipfile.BadZipFile) as exc:
            self.warnings.append('%s: %s' %
                                 (os.path.basename(bundle), exc))

    def _load(self, name, path):
        try:
            with open(path, encoding='utf-8') as handle:
                data = json.load(handle)
        except (OSError, ValueError) as exc:
            self.warnings.append('%s: %s' % (name, exc))
            return None
        if not isinstance(data, dict) or 'menus' not in data:
            self.warnings.append('%s: not a mapping file' % name)
            return None
        return data

    def match(self, identifiers):
        """identifiers: lowercase-able strings describing the focused app."""
        wanted = {str(i).lower() for i in identifiers if i}
        if not wanted:
            return None
        for app, mapping in self.mappings.items():
            ids = {str(i).lower() for i in mapping.get('identifiers', [])}
            if ids & wanted:
                return mapping
        return None

    # --------------------------------------------------------------- tree

    @staticmethod
    def build_tree(mapping):
        """Returns (tree, actions) in the bridge tree format.

        actions maps the full path key to a dict with the item's
        'accel' (fallback accelerator to type), 'action' (GTK action
        name) and 'target' (integer or None). Items with neither an
        action nor a shortcut are disabled placeholders.
        """
        tree = []
        actions = {}
        for menu in mapping.get('menus', []):
            label = str(menu.get('label', '')).strip()
            if not label:
                continue
            node = {
                'label': label,
                'key': label,
                'enabled': True,
                'toggleType': '',
                'toggleState': False,
            }
            children, menu_actions = _items_to_children(
                    menu.get('items', []), [label])
            if children:
                node['children'] = children
                tree.append(node)
            actions.update(menu_actions)
        return tree, actions


def _items_to_children(items, path):
    children = []
    actions = {}
    for item in items or []:
        if not isinstance(item, dict):
            continue
        if item.get('separator'):
            if children and not children[-1].get('separator'):
                children.append({'separator': True})
            continue
        label = str(item.get('label', '')).strip()
        if not label:
            continue
        submenu = item.get('items')
        if isinstance(submenu, list) and submenu:
            node = {
                'label': label,
                'key': LABEL_KEY_SEP.join(path + [label]),
                'enabled': True,
                'toggleType': '',
                'toggleState': False,
            }
            sub_children, sub_actions = _items_to_children(
                    submenu, path + [label])
            node['children'] = sub_children
            node['enabled'] = any(
                    c.get('enabled') for c in sub_children
                    if not c.get('separator')) or True
            children.append(node)
            actions.update(sub_actions)
            continue
        accel = str(item.get('shortcut', '') or '').strip()
        action = str(item.get('action', '') or '').strip()
        target = item.get('target')
        if 'target' in item and (isinstance(target, bool)
                                 or not isinstance(target, int)):
            # upstream requires an integer target; a bad one invalidates
            # the item entirely
            continue
        key = LABEL_KEY_SEP.join(path + [label])
        node = {
            'label': label,
            'key': key,
            'enabled': bool(accel or action),
            'toggleType': '',
            'toggleState': False,
        }
        if accel:
            node['accel'] = accel
        if action or accel:
            actions[key] = {'accel': accel,
                            'action': action,
                            'target': target}
        children.append(node)
    # trim trailing separator
    while children and children[-1].get('separator'):
        children.pop()
    return children, actions


LABEL_KEY_SEP = u'\u0020\u0020\u00bb\u0020\u0020'
