#!/usr/bin/python3

import dbus


def format_label(parts):
	separator = u'\u0020\u0020\u00BB\u0020\u0020'
	return separator.join(parts)


class DbusGtkMenuItem(object):

	def __init__(self, item, path=[], enabled=True):
		self.path = path
		self.separator = False
		self.action = str(item.get('action', ''))
		self.target = item.get('target')
		self.accel = str(item.get('accel', ''))
		self.shortcut = str(item.get('shortcut', ''))
		self.label = item.get('label', '')
		self.text = format_label(self.path + [self.label])
		self.enabled = enabled
		self.toggle_type = ''
		self.toggle_state = False
		self.app_menu = False
		self.section = None

	def set_toggle(self, state):
		if not len(state):
			return
		state = state[0]
		if self.target is not None:
			self.toggle_type = 'radio'
			self.toggle_state = state == self.target
		elif isinstance(state, (bool, dbus.Boolean)):
			self.toggle_type = 'checkmark'
			self.toggle_state = bool(state)


class DbusAppMenuItem(object):

	def __init__(self, item, path=[]):
		self.path  = path
		self.action = int(item[0])
		self.accel = self.get_shorcut(item[1])
		self.separator = item[1].get('type', '') == 'separator'
		self.label = item[1].get('label', '')
		self.text = format_label(self.path + [self.label])
		self.enabled = item[1].get('enabled', True)
		self.visible = item[1].get('visible', True)
		self.toggle_state = item[1].get('toggle-state', 0) == 1
		self.toggle_type = item[1].get('toggle-type', '')
		self.icon_data = item[1].get('icon_data', bytearray())
		self.section = None
		self.children = []

	def get_shorcut(self, item):
		shortcut = item.get('shortcut', '')
		if len(shortcut) == 0:
			return shortcut

		shortcut = shortcut[0]
		ret = ''
		for i, v in enumerate(shortcut):
			ret += '<' + v + '>' if (i != len(shortcut) - 1) else v
		return ret

	def update_props(self, props):
		if 'children-display' in props:
			return
		self.enabled = props.get('enabled', self.enabled)
		self.label = props.get('label', self.label)
		self.toggle_state = bool(props.get('toggle-state', self.toggle_state))
		self.toggle_type = props.get('toggle-type', self.toggle_type)
		self.visible = props.get('visible', self.visible)
