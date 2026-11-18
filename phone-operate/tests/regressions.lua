-- Regression checks for the phone-operate bar widget and panel.
-- The plugin uses the Lua-compatible subset of Luau. No processes are spawned.
-- Run from the repository root, for example:
--   lua phone-operate/tests/regressions.lua phone-operate widget
--   lua phone-operate/tests/regressions.lua phone-operate panel
local directory, mode = arg[1], arg[2]
assert(directory and mode, "usage: regressions.lua <plugin-dir> <widget|panel>")

local function noop() end

-- ui mock: models Noctalia's child-list requirement (a dense array of node
-- tables) so missing, nil, or boolean children fail loudly.
local function makeUi()
	return setmetatable({}, {__index = function(_, kind)
		return function(props, children)
			if children ~= nil then
				local maximum = 0
				for key in pairs(children) do
					if type(key) == "number" then maximum = math.max(maximum, key) end
				end
				for index = 1, maximum do
					assert(type(children[index]) == "table",
						"UI child " .. index .. " of " .. kind .. " is missing or not a table")
				end
			end
			return {kind = kind, props = props, children = children}
		end
	end})
end

local commonMock = {
	t = function(key) return key end,
	sendCmd = noop,
	panelId = function() return "icefish/phone-operate:main" end,
	deviceGlyph = function() return "device-mobile" end,
	batteryGlyph = function() return "battery-3" end,
	ipFromSerial = function() return nil end,
	adbCoveredByKde = function() return false end,
	selectedDevice = function() return nil end,
}

local persistenceMock = {
	loadFavorites = function() return {{number = "123", name = ""}} end,
	saveFavorites = noop,
	loadParams = function() return {max_size = 1920, bit_rate = 8, max_fps = 60} end,
	saveParams = noop,
	loadCustom = function() return nil end,
	saveCustom = noop,
	loadName = function() return nil end,
	addHistory = noop,
	loadHistory = function() return {} end,
}

local function makeRequire()
	return function(path)
		if path:find("common", 1, true) then return commonMock end
		if path:find("persistence", 1, true) then return persistenceMock end
		error("unexpected require: " .. tostring(path))
	end
end

if mode == "widget" then
	local vertical = true
	local rendered = {}
	local watchers = {}
	local env = setmetatable({
		ui = makeUi(),
		require = makeRequire(),
		barWidget = {
			isVertical = function() return vertical end,
			render = function(node) table.insert(rendered, node) end,
		},
		noctalia = {
			state = {
				get = function() return nil end,
				set = noop,
				watch = function(key, callback) watchers[key] = callback end,
			},
			getConfig = function(key)
				return ({language = "en", show_device_name = false,
					battery_display = "icon_and_percent"})[key]
			end,
			setUpdateInterval = noop,
		},
	}, {__index = _G})
	assert(loadfile(directory .. "/widget.luau", "t", env))()
	-- The script renders once at load with isVertical() == true (vertical bar).
	assert(#rendered == 1, "expected one render at load")
	assert(rendered[1].kind == "column",
		"vertical bar must render a column at load, got " .. rendered[1].kind)
	-- isVertical() loses the bar context inside state.watch callbacks and
	-- reports false there; the widget must keep its loaded orientation.
	vertical = false
	for _, callback in pairs(watchers) do callback("value") end
	env.update()
	assert(#rendered >= 3, "expected renders from watchers and update")
	for index, node in ipairs(rendered) do
		assert(node.kind == "column",
			"render " .. index .. " flip-flopped to " .. node.kind .. " on a vertical bar")
	end
	print("ok: widget keeps a steady column layout on vertical bars")
elseif mode == "panel" then
	local devices = {kdephone = {
		id = "kdephone", name = "Test phone", type = "phone", source = "kde",
		isPaired = true, isReachable = true, batteryCharge = 45, batteryCharging = true,
	}}
	local values = {
		["pc.devices"] = devices,
		["pc.order"] = {"kdephone"},
		["pc.selected"] = "kdephone",
		["pc.backend"] = {available = true, name = "KDE Connect"},
		["pc.running"] = {},
		["pc.imageMap"] = {},
		["pc.aliasMap"] = {},
		["pc.trTable"] = {},
	}
	local rendered = 0
	local env = setmetatable({
		ui = makeUi(),
		require = makeRequire(),
		panel = {render = function() rendered = rendered + 1 end, close = noop},
		noctalia = {
			state = {
				get = function(key) return values[key] end,
				set = function(key, value) values[key] = value end,
				watch = noop,
			},
			getConfig = function(key)
				return ({language = "en", enable_clipboard_action = true,
					panel_placement = "attached", show_device_name = false,
					battery_display = "icon_and_percent"})[key]
			end,
			pluginDataDir = function() return "/mock" end,
			readFile = function() return nil end,
			fileExists = function() return false end,
			json = {encode = function() return "{}" end},
			log = noop,
			notify = noop,
			notifyError = function(message) error(message) end,
			setUpdateInterval = noop,
		},
	}, {__index = _G})
	assert(loadfile(directory .. "/panel.luau", "t", env))()
	env.render()
	assert(rendered == 1, "panel did not render")
	print("ok: panel builds dense UI child lists for connected/charging devices")
else
	error("Unknown test case: " .. tostring(mode))
end
