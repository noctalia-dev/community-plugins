--!nonstrict
-- Settings panel. Every setting the helper reports is rendered from its kind,
-- so Solaar settings this file has never heard of still get a control. Writes
-- go through the service's command channel.

local shared = require("./shared.luau")

-- A write shows at once and holds until the helper confirms it or this passes.
local PENDING_MS = 4000
-- Switching host sends the mouse to another machine, so it takes a second click.
local ARM_MS = 4000

local status = noctalia.state.get(shared.STATUS_KEY)
local selectedId = nil
local activeTab = "point"
local pending = {}
local dragging = {}
local armedHost = nil
local armedUntil = 0
local isOpen = false
local seq = 0
local render

local apps = noctalia.state.get(shared.APPS_KEY) or {}
local profileDraft = ""
local profileGen = 0
-- Destructive clicks (delete a profile, remove an All apps shortcut) confirm on a second click.
local armedAction = nil
local armedActionUntil = 0

local function blankEditor(gen)
	return {
		control = "", app = "", appOther = false, appCustom = "", mode = "shortcut",
		steps = "", gestures = { up = "", down = "", left = "", right = "" },
		gen = gen, editing = false,
	}
end
-- Inputs are seeded from here and keyed by gen, so bumping gen reseeds them.
local editor = blankEditor(0)

local function tr(key)
	return noctalia.tr(key)
end

local function now()
	return noctalia.nowMs()
end

-- The service drops commands whose nonce timestamp is too old, so a stored one
-- is never replayed after a reload.
local function send(cmd)
	seq += 1
	noctalia.state.set(shared.COMMAND_KEY, { cmd = cmd, nonce = string.format("%d-%d", math.floor(now()), seq) })
end

local function controlKey(deviceId, settingName, key)
	return tostring(deviceId) .. "|" .. tostring(settingName) .. "|" .. tostring(key or "")
end

-- A held slider wins, then an unconfirmed write, then what the helper reported.
local function shownValue(k, reported)
	if dragging[k] ~= nil then
		return dragging[k]
	end
	local p = pending[k]
	if p then
		if now() > p.untilMs or tostring(shared.valueId(reported)) == tostring(p.value) then
			pending[k] = nil
		else
			return p.value
		end
	end
	return reported
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do
		out[k] = v
	end
	return out
end

local function withShownValues(setting, deviceId)
	local shown = copy(setting)
	shown.value = shownValue(controlKey(deviceId, setting.name, nil), setting.value)
	if type(setting.keys) == "table" then
		shown.keys = {}
		for i, entry in ipairs(setting.keys) do
			local e = copy(entry)
			e.value = shownValue(controlKey(deviceId, setting.name, entry.key), entry.value)
			shown.keys[i] = e
		end
	end
	return shown
end

local function commit(deviceId, settingName, key, control, choices, raw)
	local value, shown = shared.commandValue(control, choices, raw)
	if value == nil then
		return
	end
	pending[controlKey(deviceId, settingName, key)] = { value = shown, untilMs = now() + PENDING_MS }
	send(shared.setCommand(deviceId, settingName, key, value))
	render()
end

-- fill: the control grows into its column instead of taking a fixed width.
local function controlNode(deviceId, settingName, key, control, choices, enabled, fill)
	local k = controlKey(deviceId, settingName, key)
	if control.type == "toggle" then
		return ui.toggle({
			key = k, checked = control.value, enabled = enabled,
			onChange = function(v)
				commit(deviceId, settingName, key, control, choices, v)
			end,
		})
	elseif control.type == "select" then
		return ui.select({
			key = k, options = control.options, selectedIndex = control.index, enabled = enabled,
			width = not fill and 210 or nil, flexGrow = fill and 1 or nil,
			onChange = function(index, _text)
				commit(deviceId, settingName, key, control, choices, index)
			end,
		})
	elseif control.type == "slider" then
		return ui.slider({
			key = k, min = control.min, max = control.max, step = control.step, value = control.value,
			enabled = enabled, flexGrow = 1,
			onChange = function(v)
				local _, shown = shared.commandValue(control, choices, v)
				dragging[k] = shown
				render()
			end,
			onDragEnd = function()
				local v = dragging[k]
				dragging[k] = nil
				if v ~= nil then
					commit(deviceId, settingName, key, control, choices, tostring(v))
				end
			end,
		})
	end
	return ui.label({ text = control.text or "--", color = "on_surface_variant" })
end

local function firstParagraph(text)
	return (tostring(text):gsub("\n.*", ""))
end

local function settingRow(device, setting, enabled)
	local control = shared.controlFor(withShownValues(setting, device.id))
	local label = ui.label({ text = setting.label or setting.name, color = "on_surface", flexGrow = 1 })
	local caption = nil
	if setting.description and setting.description ~= "" then
		caption = ui.label({ text = firstParagraph(setting.description), fontSize = 11, color = "on_surface_variant", maxLines = 2 })
	end

	local children
	if control.type == "slider" then
		children = {
			ui.row({ gap = 8, align = "center" }, {
				label,
				ui.label({ text = tostring(control.value), color = "primary", fontWeight = "medium" }),
			}),
			controlNode(device.id, setting.name, nil, control, setting.choices, enabled),
		}
	elseif control.type == "map" then
		children = { label }
		for _, entry in ipairs(control.entries) do
			children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = entry.label, color = "on_surface_variant", flexGrow = 1 }),
				controlNode(device.id, setting.name, entry.key, entry.control, entry.choices, enabled),
			})
		end
	else
		children = {
			ui.row({ gap = 8, align = "center" }, {
				label,
				controlNode(device.id, setting.name, nil, control, setting.choices, enabled),
			}),
		}
	end
	if caption and control.type ~= "map" then
		children[#children + 1] = caption
	end
	if setting.readError and setting.readError ~= "" then
		children[#children + 1] = ui.label({ text = setting.readError, fontSize = 11, color = "error", maxLines = 2 })
	end
	return ui.column({ gap = 4 }, children)
end

local function section(title, rows)
	local children = { ui.label({ text = title, fontWeight = "semibold", color = "on_surface_variant" }) }
	for _, row in ipairs(rows) do
		children[#children + 1] = row
	end
	return ui.column({ gap = 10 }, children)
end

local function emptyNote(key)
	return ui.label({ text = tr(key), color = "on_surface_variant", maxLines = 3 })
end

local function errorNote(text)
	return ui.label({ text = text, fontSize = 11, color = "error", maxLines = 3 })
end

-- First click arms, a second click within ARM_MS runs the action.
local function armOrRun(armKey, run)
	if armedAction == armKey and now() < armedActionUntil then
		armedAction = nil
		run()
	else
		armedAction = armKey
		armedActionUntil = now() + ARM_MS
	end
	render()
end

local function isArmed(armKey)
	return armedAction == armKey and now() < armedActionUntil
end

local function settingsOn(device, tab)
	local out = {}
	for _, setting in ipairs(device.settings or {}) do
		if shared.tabFor(setting.name) == tab then
			out[#out + 1] = setting
		end
	end
	return out
end

local ACCEL_MODES = { "system", "mac" }

-- A local preference kept by the helper, not a device setting, so it is added
-- to the Pointer section by hand.
local function accelerationRow(device, enabled)
	local k = controlKey(device.id, "pointer-acceleration", nil)
	local mode = shownValue(k, shared.accelMode(status, device.id))
	local children = {
		ui.row({ gap = 8, align = "center" }, {
			ui.label({ text = tr("pointer.acceleration"), color = "on_surface", flexGrow = 1 }),
			ui.select({
				key = k, options = { tr("accel.system"), tr("accel.mac") },
				selectedIndex = mode == "mac" and 1 or 0, width = 210, enabled = enabled,
				onChange = function(index, _text)
					local picked = ACCEL_MODES[(tonumber(index) or 0) + 1]
					if picked then
						pending[k] = { value = picked, untilMs = now() + PENDING_MS }
						send(shared.pointerSet(device.id, picked))
						render()
					end
				end,
			}),
		}),
		ui.label({ text = tr("pointer.acceleration_hint"), fontSize = 11, color = "on_surface_variant", maxLines = 3 }),
	}
	local runtime = type(status.pointerRuntime) == "table" and status.pointerRuntime or {}
	if runtime.error and runtime.error ~= "" then
		children[#children + 1] = errorNote(runtime.error)
	end
	return ui.column({ gap = 4 }, children)
end

local function pointTab(device, enabled)
	local grouped = {}
	for _, setting in ipairs(settingsOn(device, "point")) do
		local id = shared.sectionFor(setting.name)
		grouped[id] = grouped[id] or {}
		table.insert(grouped[id], settingRow(device, setting, enabled))
	end
	if shared.supportsAcceleration(device) then
		grouped.pointer = grouped.pointer or {}
		table.insert(grouped.pointer, accelerationRow(device, enabled))
	end
	local body = {}
	for _, id in ipairs(shared.sectionsFor("point")) do
		if grouped[id] then
			body[#body + 1] = section(tr("section." .. id), grouped[id])
		end
	end
	if #body == 0 then
		body[1] = emptyNote("panel.empty_tab")
	end
	return body
end

-- One group per physical button, merging every per-key setting (action, mode).
local function buttonsTab(device, enabled)
	local order, groups, extra = {}, {}, {}
	for _, setting in ipairs(settingsOn(device, "buttons")) do
		local control = shared.controlFor(withShownValues(setting, device.id))
		if control.type == "map" and shared.mergesByButton(setting.name) then
			local captionKey = shared.captionKey(setting.name)
			local caption = captionKey and tr(captionKey) or (setting.label or setting.name)
			for _, entry in ipairs(control.entries) do
				local group = groups[entry.key]
				if group == nil then
					group = { label = entry.label, columns = {} }
					groups[entry.key] = group
					order[#order + 1] = entry.key
				end
				-- The helper refuses a diversion change while the button runs a shortcut.
				local locked = setting.name == "divert-keys" and shared.hasBinding(status, device.id, entry.key)
				group.columns[#group.columns + 1] = ui.column({ gap = 2, flexGrow = 1 }, {
					ui.label({ text = locked and tr("caption.mode_locked") or caption, fontSize = 11, color = "on_surface_variant" }),
					controlNode(device.id, setting.name, entry.key, entry.control, entry.choices, enabled and not locked, true),
				})
			end
		else
			extra[#extra + 1] = settingRow(device, setting, enabled)
		end
	end

	local body = {}
	for _, key in ipairs(order) do
		local group = groups[key]
		body[#body + 1] = ui.column({ gap = 6 }, {
			ui.label({ text = group.label, fontWeight = "semibold", color = "on_surface" }),
			ui.row({ gap = 10 }, group.columns),
		})
	end
	for _, row in ipairs(extra) do
		body[#body + 1] = row
	end
	if #body == 0 then
		body[1] = emptyNote("panel.empty_tab")
	end
	return body
end

local function hostName(host)
	local name = tostring(host.name or "")
	if name == "" then
		return tr("panel.host") .. " " .. tostring((host.index or 0) + 1)
	end
	return name
end

local function hostsTab(device, enabled)
	local setting = nil
	for _, s in ipairs(settingsOn(device, "hosts")) do
		setting = s
	end
	if setting == nil or type(device.hosts) ~= "table" or #device.hosts == 0 then
		return { emptyNote("panel.no_hosts") }
	end

	local rows = { emptyNote("panel.hosts_hint") }
	for _, host in ipairs(device.hosts) do
		local right
		if host.current then
			right = ui.label({ text = tr("panel.this_computer"), color = "primary" })
		elseif host.paired then
			local armKey = tostring(device.id) .. "|" .. tostring(host.index)
			local armed = armedHost == armKey and now() < armedUntil
			right = ui.button({
				text = armed and tr("panel.confirm_switch") or tr("panel.switch"),
				variant = armed and "destructive" or "outline",
				controlSize = "sm",
				enabled = enabled,
				onClick = function()
					if armedHost == armKey and now() < armedUntil then
						armedHost = nil
						send(shared.setCommand(device.id, setting.name, nil, shared.hostSwitchValue(host.index)))
					else
						armedHost = armKey
						armedUntil = now() + ARM_MS
					end
					render()
				end,
			})
		else
			right = ui.label({ text = tr("panel.empty_slot"), color = "on_surface_variant" })
		end
		rows[#rows + 1] = ui.row({ gap = 10, align = "center" }, {
			ui.label({ text = tostring((host.index or 0) + 1), fontWeight = "semibold", color = "on_surface_variant", width = 14 }),
			ui.glyph({ name = "device-laptop", size = 18, color = host.current and "primary" or "on_surface_variant" }),
			ui.label({ text = hostName(host), flexGrow = 1 }),
			right,
		})
	end
	return rows
end

local function saveProfile(device)
	local name = shared.sanitizeProfileName(profileDraft)
	if name == nil then
		return
	end
	send(shared.profileSave(device.id, name))
	profileDraft = ""
	profileGen += 1
	render()
end

local function profilesTab(device, enabled)
	local body = {}

	local profiles = shared.profilesFor(status, device.id)
	local rows = {}
	for _, profile in ipairs(profiles) do
		local armKey = "profile|" .. tostring(profile.name)
		local armed = isArmed(armKey)
		rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
			ui.glyph({ name = "bookmark", size = 16, color = "on_surface_variant" }),
			ui.label({ text = tostring(profile.name), flexGrow = 1 }),
			ui.button({
				text = tr("profiles.apply"), variant = "outline", controlSize = "sm", enabled = enabled,
				onClick = function()
					send(shared.profileApply(device.id, profile.name))
				end,
			}),
			ui.button({
				text = armed and tr("profiles.confirm_delete") or tr("profiles.delete"),
				variant = armed and "destructive" or "ghost", controlSize = "sm",
				onClick = function()
					armOrRun(armKey, function()
						send(shared.profileDelete(profile.name))
					end)
				end,
			}),
		})
	end
	if #rows == 0 then
		rows[1] = emptyNote("profiles.none")
	end
	body[#body + 1] = section(tr("section.profiles"), rows)

	local name = shared.sanitizeProfileName(profileDraft)
	local exists = false
	for _, profile in ipairs(profiles) do
		if profile.name == name then
			exists = true
		end
	end
	body[#body + 1] = section(tr("section.save_profile"), {
		ui.row({ gap = 8, align = "center" }, {
			ui.input({
				key = "profile-name-" .. tostring(profileGen), placeholder = tr("profiles.name_placeholder"),
				flexGrow = 1, enabled = enabled,
				onChange = function(v)
					profileDraft = v
					render()
				end,
				onSubmit = function(v)
					profileDraft = v
					saveProfile(device)
				end,
			}),
			ui.button({
				text = exists and tr("profiles.overwrite") or tr("profiles.save"),
				variant = "primary", controlSize = "sm", enabled = enabled and name ~= nil,
				onClick = function()
					saveProfile(device)
				end,
			}),
		}),
		ui.label({ text = tr("profiles.save_hint"), fontSize = 11, color = "on_surface_variant", maxLines = 3 }),
	})
	return body
end

local DIRECTIONS = { "up", "down", "left", "right" }
local DIRECTION_ARROWS = { up = "↑", down = "↓", left = "←", right = "→" }
local PRESETS = {
	{ "preset.copy", "CTRL+c" }, { "preset.paste", "CTRL+v" }, { "preset.undo", "CTRL+z" },
	{ "preset.back", "ALT+Left" }, { "preset.next_tab", "CTRL+Tab" },
}

local function reseed()
	editor.gen += 1
end

local function draftFromEditor()
	return {
		control = editor.control,
		app = editor.appOther and editor.appCustom or editor.app,
		appOther = editor.appOther,
		mode = editor.mode,
		shortcut = editor.steps,
		gestures = editor.gestures,
	}
end

local function editBinding(row)
	local gen = editor.gen + 1
	editor = blankEditor(gen)
	editor.control = tostring(row.control)
	editor.app = row.app or ""
	editor.mode = row.mode == "gesture" and "gesture" or "shortcut"
	editor.steps = tostring(row.shortcut or "")
	for _, dir in ipairs(DIRECTIONS) do
		editor.gestures[dir] = tostring((row.gestures or {})[dir] or "")
	end
	editor.editing = true
	render()
end

local function bindingSummary(row)
	if row.mode == "gesture" then
		local parts = { tr("shortcuts.click") .. " " .. tostring(row.shortcut or ""):gsub("\n", " → ") }
		for _, dir in ipairs(DIRECTIONS) do
			local steps = (row.gestures or {})[dir]
			if steps and steps ~= "" then
				parts[#parts + 1] = DIRECTION_ARROWS[dir] .. " " .. steps:gsub("\n", " → ")
			end
		end
		return table.concat(parts, "   ")
	end
	return (tostring(row.shortcut or ""):gsub("\n", " → "))
end

local function controlLabel(controls, key)
	for _, c in ipairs(controls) do
		if c.key == tostring(key) then
			return c.label
		end
	end
	return tr("shortcuts.control") .. " " .. tostring(key)
end

local function assignmentRows(device, controls, bindings, enabled)
	local rows = {}
	for _, row in ipairs(bindings) do
		local isDefault = (row.app or "") == ""
		local overrides = 0
		for _, other in ipairs(bindings) do
			if other.control == row.control and (other.app or "") ~= "" then
				overrides += 1
			end
		end
		local armKey = "action|" .. tostring(row.control) .. "|" .. tostring(row.app or "")
		local armed = isArmed(armKey)
		rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({
					text = controlLabel(controls, row.control) .. " · " .. (isDefault and tr("shortcuts.all_apps") or tostring(row.app)),
					fontWeight = "medium", color = "on_surface",
				}),
				ui.label({ text = bindingSummary(row), fontSize = 11, color = "on_surface_variant", maxLines = 2 }),
			}),
			ui.button({
				text = tr("shortcuts.edit"), variant = "ghost", controlSize = "sm", enabled = enabled,
				onClick = function()
					editBinding(row)
				end,
			}),
			ui.button({
				text = armed and tr("shortcuts.confirm_remove") or tr("shortcuts.remove"),
				variant = armed and "destructive" or "outline", controlSize = "sm", enabled = enabled,
				-- Removing the All apps action also drops its overrides, so that one confirms.
				onClick = function()
					local remove = function()
						send(shared.actionDelete(device.id, row))
					end
					if isDefault and overrides > 0 then
						armOrRun(armKey, remove)
					else
						remove()
					end
				end,
			}),
		})
	end
	return rows
end

local function appPicker(enabled)
	local list = {}
	local present = false
	for _, app in ipairs(apps) do
		list[#list + 1] = app
		if app == editor.app then
			present = true
		end
	end
	-- Editing an override for an app that is not open keeps it selectable.
	if editor.app ~= "" and not editor.appOther and not present then
		table.insert(list, 1, editor.app)
	end
	local options = { tr("shortcuts.all_apps") }
	local index = 0
	for i, app in ipairs(list) do
		options[#options + 1] = app
		if not editor.appOther and app == editor.app then
			index = i
		end
	end
	options[#options + 1] = tr("shortcuts.other_app")
	if editor.appOther then
		index = #list + 1
	end
	local nodes = {
		ui.select({
			key = "app-" .. tostring(editor.gen), options = options, selectedIndex = index, flexGrow = 1, enabled = enabled,
			onChange = function(i, _text)
				local n = tonumber(i) or 0
				if n == 0 then
					editor.app, editor.appOther = "", false
				elseif n == #list + 1 then
					editor.appOther = true
				else
					editor.app, editor.appOther = list[n], false
				end
				render()
			end,
		}),
	}
	if editor.appOther then
		nodes[#nodes + 1] = ui.input({
			key = "app-custom-" .. tostring(editor.gen), value = editor.appCustom,
			placeholder = tr("shortcuts.app_placeholder"), enabled = enabled,
			onChange = function(v)
				editor.appCustom = v
				render()
			end,
		})
	end
	return nodes
end

local function labelled(text, node)
	return ui.column({ gap = 4 }, {
		ui.label({ text = text, fontSize = 11, color = "on_surface_variant" }),
		node,
	})
end

local function editorSection(device, controls, bindings, enabled)
	local selected = nil
	local options, index = {}, -1
	for i, c in ipairs(controls) do
		options[i] = c.label
		if c.key == editor.control then
			index = i - 1
			selected = c
		end
	end
	if selected and not selected.gesture then
		editor.mode = "shortcut"
	end

	local nodes = {
		labelled(tr("shortcuts.button"), ui.select({
			key = "control-" .. tostring(editor.gen), options = options, selectedIndex = index,
			placeholder = tr("shortcuts.choose_button"), enabled = enabled and not editor.editing,
			onChange = function(i, _text)
				local c = controls[(tonumber(i) or 0) + 1]
				editor.control = c and c.key or ""
				render()
			end,
		})),
	}

	local appNodes = appPicker(enabled and not editor.editing)
	nodes[#nodes + 1] = labelled(tr("shortcuts.application"), ui.column({ gap = 6 }, appNodes))

	if selected and selected.gesture then
		nodes[#nodes + 1] = labelled(tr("shortcuts.mode"), ui.select({
			key = "mode-" .. tostring(editor.gen), options = { tr("mode.shortcut"), tr("mode.gesture") },
			selectedIndex = editor.mode == "gesture" and 1 or 0, enabled = enabled,
			onChange = function(i, _text)
				editor.mode = tonumber(i) == 1 and "gesture" or "shortcut"
				render()
			end,
		}))
	end

	local presets = {}
	for _, preset in ipairs(PRESETS) do
		presets[#presets + 1] = ui.button({
			text = tr(preset[1]), variant = "ghost", controlSize = "sm", enabled = enabled,
			onClick = function()
				editor.steps = preset[2]
				reseed()
				render()
			end,
		})
	end
	nodes[#nodes + 1] = labelled(editor.mode == "gesture" and tr("shortcuts.click_action") or tr("shortcuts.steps"), ui.column({ gap = 6 }, {
		ui.input({
			key = "steps-" .. tostring(editor.gen), value = editor.steps, multiline = true, height = 64,
			placeholder = tr("shortcuts.steps_placeholder"), enabled = enabled,
			onChange = function(v)
				editor.steps = v
				render()
			end,
		}),
		ui.row({ gap = 4 }, presets),
	}))

	if editor.mode == "gesture" then
		local rows = {}
		for _, dir in ipairs(DIRECTIONS) do
			rows[#rows + 1] = ui.row({ gap = 8, align = "center" }, {
				ui.label({ text = DIRECTION_ARROWS[dir] .. " " .. tr("gesture." .. dir), width = 90, color = "on_surface_variant" }),
				ui.input({
					key = "gesture-" .. dir .. "-" .. tostring(editor.gen), value = editor.gestures[dir],
					placeholder = tr("shortcuts.gesture_placeholder"), flexGrow = 1, enabled = enabled,
					onChange = function(v)
						editor.gestures[dir] = v
						render()
					end,
				}),
			})
		end
		nodes[#nodes + 1] = labelled(tr("shortcuts.gestures"), ui.column({ gap = 6 }, rows))
	end

	local ok, err = shared.validateDraft(draftFromEditor(), controls, bindings)
	local touched = editor.control ~= "" or editor.steps:match("%S") ~= nil
	-- Empty steps just keep Save disabled; saying so in red before typing is noise.
	if not ok and touched and err ~= "shortcut.empty" then
		nodes[#nodes + 1] = errorNote(tr("error." .. tostring(err)))
	end

	local buttons = {
		ui.button({
			text = editor.editing and tr("shortcuts.update") or tr("shortcuts.save"), variant = "primary",
			controlSize = "sm", enabled = enabled and ok ~= nil,
			onClick = function()
				local valid = shared.validateDraft(draftFromEditor(), controls, bindings)
				if valid then
					send(shared.actionSave(device.id, valid))
					editor = blankEditor(editor.gen + 1)
					render()
				end
			end,
		}),
	}
	if editor.editing or touched then
		buttons[#buttons + 1] = ui.button({
			text = tr("shortcuts.cancel"), variant = "ghost", controlSize = "sm",
			onClick = function()
				editor = blankEditor(editor.gen + 1)
				render()
			end,
		})
	end
	nodes[#nodes + 1] = ui.row({ gap = 8 }, buttons)
	nodes[#nodes + 1] = ui.label({ text = tr("shortcuts.help"), fontSize = 11, color = "on_surface_variant", maxLines = 4 })

	return section(editor.editing and tr("section.edit_shortcut") or tr("section.new_shortcut"), nodes)
end

local function shortcutsTab(device, enabled)
	local controls = shared.actionControls(device)
	if #controls == 0 then
		return { emptyNote("shortcuts.unsupported") }
	end
	local bindings = shared.bindingsFor(status, device.id)
	local body = {}

	local runtime = type(status.actionRuntime) == "table" and status.actionRuntime or {}
	if runtime.available == false then
		body[#body + 1] = errorNote(tr("shortcuts.no_hyprland"))
	end
	if runtime.error and runtime.error ~= "" then
		body[#body + 1] = errorNote(runtime.error)
	end

	local rows = assignmentRows(device, controls, bindings, enabled)
	if #rows == 0 then
		rows[1] = emptyNote("shortcuts.none")
	end
	body[#body + 1] = section(tr("section.assignments"), rows)
	body[#body + 1] = editorSection(device, controls, bindings, enabled)
	return body
end

local function deviceCard(device)
	local level = shared.batteryLevel(device)
	local subtitle = tr("panel.offline")
	if device.online then
		subtitle = tostring(device.connection or "")
		if device.protocol and device.protocol ~= "" then
			subtitle = subtitle .. " · " .. device.protocol
		end
	end
	local children = {
		ui.row({ gap = 10, align = "center" }, {
			ui.glyph({ name = device.online and "mouse" or "mouse-off", size = 22, color = device.online and "primary" or "on_surface_variant" }),
			ui.column({ gap = 2, flexGrow = 1 }, {
				ui.label({ text = device.name or "MX", fontSize = 15, fontWeight = "semibold" }),
				ui.label({ text = subtitle, fontSize = 11, color = "on_surface_variant" }),
			}),
			ui.label({ text = shared.batteryText(device), fontWeight = "medium", color = shared.levelRole(level) or "on_surface" }),
		}),
	}
	if device.online and level then
		children[#children + 1] = ui.progress({ progress = level / 100, fill = shared.levelRole(level) or "primary" })
	end
	return ui.column({ gap = 8 }, children)
end

local function devicePicker(device)
	local devices = status.devices or {}
	if #devices < 2 then
		return nil
	end
	local options, index = {}, 0
	for i, d in ipairs(devices) do
		options[i] = tostring(d.name or d.id)
		if d.id == device.id then
			index = i - 1
		end
	end
	return ui.select({
		options = options, selectedIndex = index,
		onChange = function(i, _text)
			local picked = devices[(tonumber(i) or 0) + 1]
			selectedId = picked and picked.id or nil
			armedHost = nil
			render()
		end,
	})
end

local function tabBar()
	local buttons = {}
	for _, tab in ipairs(shared.TABS) do
		local active = activeTab == tab
		buttons[#buttons + 1] = ui.button({
			text = tr("tab." .. tab),
			selected = active,
			variant = active and "secondary" or "ghost",
			controlSize = "sm",
			onClick = function()
				activeTab = tab
				if tab == "shortcuts" then
					send({ op = "list-apps" })
				end
				render()
			end,
		})
	end
	-- Sized to their labels: equal widths cut "Buttons & Actions" at 600 px.
	return ui.row({ gap = 6, justify = "space_between" }, buttons)
end

local function tabContent(device, code)
	if not device.online then
		return { emptyNote("panel.offline_hint") }
	end
	local enabled = code == nil and not device.readonly
	if activeTab == "buttons" then
		return buttonsTab(device, enabled)
	elseif activeTab == "hosts" then
		return hostsTab(device, enabled)
	elseif activeTab == "profiles" then
		return profilesTab(device, enabled)
	elseif activeTab == "shortcuts" then
		return shortcutsTab(device, enabled)
	end
	return pointTab(device, enabled)
end

render = function()
	if not isOpen then
		return
	end
	local code = shared.stateCode(status, os.time())
	local device = shared.pickDevice(status, selectedId)

	local top = {
		ui.row({ align = "center", justify = "space_between", gap = 8 }, {
			ui.label({ text = "MX Control", fontSize = 16, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
			ui.button({
				glyph = "refresh", variant = "ghost", tooltip = tr("panel.refresh"),
				onClick = function()
					send({ op = "refresh", device = device and device.id or nil })
				end,
			}),
			ui.button({ glyph = "close", variant = "ghost", onClick = function()
				panel.close()
			end }),
		}),
	}
	if code then
		top[#top + 1] = ui.label({ text = tr("state." .. code), color = code == "no_devices" and "on_surface_variant" or "error" })
		if code == "no_solaar" or code == "no_access" then
			top[#top + 1] = ui.label({ text = tr("hint." .. code), fontSize = 11, color = "on_surface_variant", maxLines = 4 })
		end
	end

	local body = {}
	if device then
		local picker = devicePicker(device)
		if picker then
			top[#top + 1] = picker
		end
		top[#top + 1] = deviceCard(device)
		top[#top + 1] = tabBar()
		body = tabContent(device, code)
	end

	if type(status) == "table" then
		if status.lastError and status.lastError ~= "" then
			body[#body + 1] = ui.label({ text = status.lastError, color = "error", maxLines = 3 })
		end
		local progress = status.progress
		if type(progress) == "table" and progress.phase and progress.phase ~= "idle" then
			body[#body + 1] = ui.label({ text = tr("panel.reading"), color = "on_surface_variant" })
		end
	end

	top[#top + 1] = ui.scroll({ flexGrow = 1, gap = 18 }, body)
	panel.render(ui.column({ flexGrow = 1, gap = 14 }, top))
end

noctalia.state.watch(shared.STATUS_KEY, function(value)
	status = value
	render()
end)

noctalia.state.watch(shared.APPS_KEY, function(value)
	apps = type(value) == "table" and value or {}
	render()
end)

function onOpen(_context)
	isOpen = true
	status = noctalia.state.get(shared.STATUS_KEY)
	if activeTab == "shortcuts" then
		send({ op = "list-apps" })
	end
	render()
end

function onClose()
	isOpen = false
	dragging = {}
	armedHost = nil
	armedAction = nil
end

function onKey(chord, pressed)
	if chord == "escape" and pressed then
		panel.close()
	end
end
