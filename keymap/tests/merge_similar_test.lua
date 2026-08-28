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

-- MangoWC: merge_similar groups same-action binds into one read-only row.
do
	local source = table.concat({
		'bind=SUPER,W,killclient #"Close Window"',
		'bind=ALT,F4,killclient #"Close Window"',
		'bind=SUPER,F,togglefullscreen #"Fullscreen"',
		"",
	}, "\n")
	local values, state = stateMock()
	noctalia = {
		state = state,
		getConfig = function(key)
			return ({
				compositor = "mangowc", mangowc_config = "/fixture/config.conf",
				merge_sequential = false, merge_similar = true,
			})[key]
		end,
		getenv = function(key) return key == "MANGO_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/fixture/config.conf" end,
		readFile = function(path) return path == "/fixture/config.conf" and source or nil end,
		tr = function(key) return key == "category.other" and "Other" or key end,
	}
	assert(loadfile("mangowc_service.luau"))()
	local binds = {}
	for _, category in ipairs(values["keymap.snapshot"].categories or {}) do
		for _, bind in ipairs(category.binds or {}) do binds[#binds + 1] = bind end
	end
	assert(#binds == 2, "mangowc similar binds not merged, got " .. #binds)
	assert(type(binds[1].combos) == "table" and #binds[1].combos == 2, "merged row lost combos")
	assert(binds[1].combos[1].key == "W" and binds[1].combos[2].key == "F4", "merged row combo order wrong")
	assert(binds[1].capabilities.combo == false, "merged row must be read-only")
end

-- Hyprland: merge_similar groups same-action binds; watcher ignores echoes.
do
	local source = table.concat({
		'-- 1. General',
		'hl.bind("SUPER + W", hl.dsp.exec_cmd("close"), { description = "Close Window" })',
		'hl.bind("ALT + F4", hl.dsp.exec_cmd("close"), { description = "Close Window" })',
		'hl.bind("SUPER + F", hl.dsp.exec_cmd("max"), { description = "Maximize" })',
	}, "\n")
	local plain = table.concat({
		"bindd\n\tmodmask: 64\n\tsubmap: \n\tkey: W\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Close Window\n\tdispatcher: __lua\n\targ: 1\n",
		"bindd\n\tmodmask: 8\n\tsubmap: \n\tkey: F4\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Close Window\n\tdispatcher: __lua\n\targ: 2\n",
		"bindd\n\tmodmask: 64\n\tsubmap: \n\tkey: F\n\tkeycode: 0\n\tcatchall: false\n\tdescription: Maximize\n\tdispatcher: __lua\n\targ: 3\n",
	}, "\n")
	local values, state = stateMock()
	local configValues = {
		compositor = "hyprland", hyprland_config = "/fixture/hyprland.lua",
		merge_sequential = false, show_undescribed = true, merge_similar = true,
	}
	noctalia = {
		state = state,
		getConfig = function(key) return configValues[key] end,
		getenv = function(key) return key == "HYPRLAND_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/fixture/hyprland.lua" end,
		listDir = function() return nil end,
		readFile = function(path) return path == "/fixture/hyprland.lua" and source or nil end,
		commandExists = function(command) return command == "hyprctl" end,
		runAsync = function(command, callback)
			callback({ exitCode = 0, timedOut = false, stdout = command == "hyprctl binds" and plain or "invalid-json" })
			return true
		end,
		json = { decode = function() error("malformed JSON fixture") end },
		tr = function(key) return key == "category.other" and "Other" or key end,
	}
	assert(loadfile("service.luau"))()
	local binds = {}
	for _, category in ipairs(values["keymap.snapshot"].categories or {}) do
		for _, bind in ipairs(category.binds or {}) do binds[#binds + 1] = bind end
	end
	assert(#binds == 2, "hyprland similar binds not merged, got " .. #binds)
	assert(type(binds[1].combos) == "table" and #binds[1].combos == 2, "merged row lost combos")
	assert(binds[1].combos[1].key == "W" and binds[1].combos[2].key == "F4", "merged row combo order wrong")
	assert(binds[1].capabilities.combo == false, "merged row must be read-only")

	local refreshes = 0
	noctalia.state.watch("keymap.snapshot", function(snapshot)
		if snapshot.status == "ready" then refreshes = refreshes + 1 end
	end)
	-- The watcher only records intent; update() performs the refresh.
	noctalia.state.set("keymap.refresh_request", 1)
	update()
	local afterFirst = refreshes
	noctalia.state.set("keymap.refresh_request", 1)
	update()
	assert(refreshes == afterFirst, "echo of refresh_request triggered another refresh")
	noctalia.state.set("keymap.refresh_request", 2)
	update()
	assert(refreshes == afterFirst + 1, "increment did not trigger exactly one refresh")
end



-- MangoWC: merged numeric ranges keep their action, so merge_similar cannot
-- collapse two different ranges into one.
do
	local lines = {}
	for index = 1, 4 do
		lines[#lines + 1] = string.format('bind=SUPER,%d,view,%d #"Workspace %d"', index, index, index)
	end
	for index = 1, 4 do
		lines[#lines + 1] = string.format('bind=SUPER+SHIFT,%d,movetoworkspace,%d #"Move %d"', index, index, index)
	end
	local source = table.concat(lines, "\n") .. "\n"
	local values, state = stateMock()
	noctalia = {
		state = state,
		getConfig = function(key)
			return ({
				compositor = "mangowc", mangowc_config = "/fixture/config.conf",
				merge_sequential = true, merge_similar = true,
			})[key]
		end,
		getenv = function(key) return key == "MANGO_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/fixture/config.conf" end,
		readFile = function(path) return path == "/fixture/config.conf" and source or nil end,
		tr = function(key) return key == "category.other" and "Other" or key end,
	}
	assert(loadfile("mangowc_service.luau"))()
	local binds = {}
	for _, category in ipairs(values["keymap.snapshot"].categories or {}) do
		for _, bind in ipairs(category.binds or {}) do binds[#binds + 1] = bind end
	end
	assert(#binds == 2, "different mangowc ranges collapsed: " .. #binds)
	assert(binds[1].id:match("^range:") and binds[2].id:match("^range:"), "ranges lost their ids")
end

-- Hyprland: undescribed binds with unknown actions never merge.
do
	local source = table.concat({
		'hl.bind("SUPER + A", hl.dsp.exec_cmd("one"))',
		'hl.bind("SUPER + B", hl.dsp.exec_cmd("two"))',
	}, "\n")
	local plain = table.concat({
		"bindd\n\tmodmask: 64\n\tsubmap: \n\tkey: A\n\tkeycode: 0\n\tcatchall: false\n\tdescription: \n\tdispatcher: __lua\n\targ: 1\n",
		"bindd\n\tmodmask: 64\n\tsubmap: \n\tkey: B\n\tkeycode: 0\n\tcatchall: false\n\tdescription: \n\tdispatcher: __lua\n\targ: 2\n",
	}, "\n")
	local values, state = stateMock()
	noctalia = {
		state = state,
		getConfig = function(key)
			return ({
				compositor = "hyprland", hyprland_config = "/fixture/hyprland.lua",
				merge_sequential = false, show_undescribed = true, merge_similar = true,
			})[key]
		end,
		getenv = function(key) return key == "HYPRLAND_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return path == "/fixture/hyprland.lua" end,
		listDir = function() return nil end,
		readFile = function(path) return path == "/fixture/hyprland.lua" and source or nil end,
		commandExists = function(command) return command == "hyprctl" end,
		runAsync = function(command, callback)
			callback({ exitCode = 0, timedOut = false, stdout = command == "hyprctl binds" and plain or "invalid-json" })
			return true
		end,
		json = { decode = function() error("malformed JSON fixture") end },
		tr = function(key) return key end,
	}
	assert(loadfile("service.luau"))()
	local binds = {}
	for _, category in ipairs(values["keymap.snapshot"].categories or {}) do
		for _, bind in ipairs(category.binds or {}) do binds[#binds + 1] = bind end
	end
	assert(#binds == 2, "unidentifiable hyprland binds merged: " .. #binds)
end

print("merge similar extended tests: ok")
