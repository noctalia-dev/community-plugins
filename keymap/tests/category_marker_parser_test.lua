local function stateMock()
	local values = {}
	local watchers = {}
	return values, {
		get = function(key) return values[key] end,
		set = function(key, value)
			values[key] = value
			if watchers[key] ~= nil then watchers[key](value) end
		end,
		watch = function(key, callback) watchers[key] = callback end,
	}
end

local function findCategory(snapshot, name)
	for _, category in ipairs(snapshot.categories or {}) do
		if category.name == name then return category end
	end
	return nil
end

local function assertMarkedBind(snapshot, categoryName, expectedSnippet, expectedStart, expectedEnd)
	assert(snapshot.status == "ready", categoryName .. ": snapshot not ready")
	local category = findCategory(snapshot, categoryName)
	assert(type(category) == "table", categoryName .. ": category missing")
	assert(#category.binds == 1, categoryName .. ": unexpected bind count")
	local bind = category.binds[1]
	assert(bind.raw_snippet == expectedSnippet, categoryName .. ": marker missing from provenance")
	assert(bind.start_line == expectedStart and bind.end_line == expectedEnd, categoryName .. ": line range mismatch")
	assert(bind.capabilities.category == true, categoryName .. ": category editing disabled")
end

do
	local values, state = stateMock()
	local source = table.concat({
		"-- 1. General",
		"-- Keymap bind-category: Media",
		'hl.bind("SUPER + G", hl.dsp.exec_cmd([[playerctl play-pause]]), { description = "Media action" })',
		'hl.bind("SUPER + H", hl.dsp.exec_cmd([[true]]), { description = "General action" })',
		"",
	}, "\n")
	noctalia = {
		state = state,
		getConfig = function(key)
			local config = { compositor = "hyprland", hyprland_config = "/tmp/hyprland.lua", merge_sequential = false }
			return config[key]
		end,
		getenv = function(key) return key == "HYPRLAND_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/tmp/hyprland.lua" end,
		readFile = function(path) return path == "/tmp/hyprland.lua" and source or nil end,
		commandExists = function(command) return command == "hyprctl" end,
		tr = function(key) return key end,
		runAsync = function(_command, callback)
			callback({ exitCode = 0, timedOut = false, stdout = "[]" })
			return true
		end,
		json = {
			decode = function()
				return {
					{ modmask = 64, key = "G", dispatcher = "__lua", arg = "", description = "Media action", has_description = true },
					{ modmask = 64, key = "H", dispatcher = "__lua", arg = "", description = "General action", has_description = true },
				}
			end,
		},
	}
	assert(loadfile("service.luau"))()
	local snapshot = values["keymap.snapshot"]
	assertMarkedBind(
		snapshot, "Media",
		'-- Keymap bind-category: Media\n'
			.. 'hl.bind("SUPER + G", hl.dsp.exec_cmd([[playerctl play-pause]]), { description = "Media action" })',
		2, 3
	)
	assert(#findCategory(snapshot, "General").binds == 1, "Hyprland marker leaked into following bind")
end

do
	local values, state = stateMock()
	local marker = "    // Keymap bind-category: Media"
	local bindLine = '    Mod+G hotkey-overlay-title="Media action" { spawn-sh "playerctl play-pause"; }'
	local source = table.concat({ "binds {", marker, bindLine, "}", "" }, "\n")
	noctalia = {
		state = state,
		getConfig = function(key)
			local config = { compositor = "niri", niri_config = "/tmp/config.kdl", merge_sequential = false }
			return config[key]
		end,
		getenv = function(key) return key == "NIRI_SOCKET" and "test" or "" end,
		fileExists = function(path) return path == "/tmp/config.kdl" end,
		readFile = function(path) return path == "/tmp/config.kdl" and source or nil end,
		tr = function(key) return key end,
	}
	assert(loadfile("niri_service.luau"))()
	assertMarkedBind(values["keymap.snapshot"], "Media", marker .. "\n" .. bindLine, 2, 3)
end

do
	local values, state = stateMock()
	local marker = "# Keymap bind-category: Media"
	local moved = 'bind=SUPER,G,spawn_shell,playerctl play-pause #"Media action"'
	local general = 'bind=SUPER,H,spawn_shell,true #"General action"'
	local source = table.concat({ "# General", marker, moved, general, "" }, "\n")
	noctalia = {
		state = state,
		getConfig = function(key)
			local config = { compositor = "mangowc", mangowc_config = "/tmp/mango.conf", merge_sequential = false }
			return config[key]
		end,
		getenv = function(key) return key == "MANGO_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/tmp/mango.conf" end,
		readFile = function(path) return path == "/tmp/mango.conf" and source or nil end,
		tr = function(key) return key end,
	}
	assert(loadfile("mangowc_service.luau"))()
	local snapshot = values["keymap.snapshot"]
	assertMarkedBind(snapshot, "Media", marker .. "\n" .. moved, 2, 3)
	assert(#findCategory(snapshot, "General").binds == 1, "MangoWC marker leaked into following bind")
end

print("category marker parser tests: ok")
