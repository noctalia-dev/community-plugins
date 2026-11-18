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

local function niriHost(values, state, source, configValues)
	return {
		state = state,
		getConfig = function(key) return configValues[key] end,
		getenv = function(key) return key == "NIRI_SOCKET" and "test" or "" end,
		fileExists = function(path) return path == "/fixture/config.kdl" end,
		listDir = function() return nil end,
		readFile = function(path) return path == "/fixture/config.kdl" and source or nil end,
		tr = function(key, args)
			if args ~= nil and args.command ~= nil then return "Run " .. args.command end
			if args ~= nil and args.action ~= nil then return "Action " .. args.action end
			return key == "category.other" and "Other" or key
		end,
	}
end

local function allBinds(snapshot)
	local found = {}
	for _, category in ipairs(snapshot.categories or {}) do
		for _, bind in ipairs(category.binds or {}) do
			found[#found + 1] = bind
		end
	end
	return found
end

-- merge_sequential collapses numbered workspace runs into a single range row.
do
	local source = [[binds {
    Super+1 hotkey-overlay-title="Workspace 1" { focus-workspace 1; }
    Super+2 hotkey-overlay-title="Workspace 2" { focus-workspace 2; }
    Super+3 hotkey-overlay-title="Workspace 3" { focus-workspace 3; }
    Super+4 hotkey-overlay-title="Workspace 4" { focus-workspace 4; }
    Super+Shift+1 hotkey-overlay-title="Move to Workspace 1" { move-window-to-workspace 1; }
    Super+Shift+2 hotkey-overlay-title="Move to Workspace 2" { move-window-to-workspace 2; }
    Super+Shift+3 hotkey-overlay-title="Move to Workspace 3" { move-window-to-workspace 3; }
    Super+Shift+4 hotkey-overlay-title="Move to Workspace 4" { move-window-to-workspace 4; }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = true, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	local snapshot = values["keymap.snapshot"]
	assert(snapshot.status == "ready", "sequential fixture not ready")
	local binds = allBinds(snapshot)
	assert(#binds == 2, "sequential runs not merged, got " .. #binds)
	assert(binds[1].key == "1-4", "unexpected range key " .. tostring(binds[1].key))
	assert(binds[1].description == "Workspace 1-4", "unexpected range description " .. tostring(binds[1].description))
	assert(binds[2].description == "Move to Workspace 1-4", "second run not merged")

	-- and the flag turns merging off again
	values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	assert(#allBinds(values["keymap.snapshot"]) == 8, "merge_sequential=false still merged")
end

-- show_undescribed=false drops binds with an empty or null hotkey-overlay-title.
do
	local source = [[binds {
    Super+Q hotkey-overlay-title="Close window" { close-window; }
    Super+R hotkey-overlay-title="" { spawn-sh "rofi -show run"; }
    Super+T hotkey-overlay-title=null { spawn-sh "foot"; }
    Super+Y { toggle-overview; }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = false, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	local snapshot = values["keymap.snapshot"]
	assert(snapshot.total == 1, "undescribed binds not filtered, total=" .. tostring(snapshot.total))
	assert(allBinds(snapshot)[1].description == "Close window", "wrong bind survived filtering")

	values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	assert(values["keymap.snapshot"].total == 4, "show_undescribed=true lost binds")
end

-- Ordinary single-line native spawn argv is editable without converting it to
-- spawn-sh. More elaborate KDL stays read-only, while spawn-sh keeps its
-- existing shell-command behavior.
do
	local source = [[binds {
    Super+B hotkey-overlay-title="Noctalia panel" { spawn "noctalia" "msg" "panel-toggle" "kenn/keybind-cheatsheet:cheatsheet"; }
    Super+T hotkey-overlay-title="Terminal" { spawn-sh "foot --server"; }
    Super+R hotkey-overlay-title="Raw string" { spawn r#"foot"#; }
    Super+C hotkey-overlay-title="Commented" { spawn "foot"; // preserve this comment
    }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	local binds = allBinds(values["keymap.snapshot"])
	assert(#binds == 4, "native spawn fixture lost binds")
	assert(binds[1].command == 'spawn "noctalia" "msg" "panel-toggle" "kenn/keybind-cheatsheet:cheatsheet"',
		"native spawn action was not exposed for editing")
	assert(binds[1].command_kind == "native" and binds[1].capabilities.command == true
		and binds[1].capabilities.native_spawn == true,
		"ordinary native spawn action is not editable")
	assert(binds[2].command == "foot --server" and binds[2].command_kind == "shell"
		and binds[2].capabilities.command == true and binds[2].capabilities.native_spawn == false,
		"spawn-sh command behavior changed")
	assert(binds[3].capabilities.command == false and binds[3].capabilities.native_spawn == false,
		"unsupported native spawn syntax became editable")
	assert(binds[4].capabilities.command == false and binds[4].capabilities.native_spawn == false,
		"commented native spawn action became editable")
end

-- merge_similar groups same-action binds into one read-only row.
do
	local source = [[binds {
    Super+W hotkey-overlay-title="Close Window" { close-window; }
    Alt+F4 hotkey-overlay-title="Close Window" { close-window; }
    Super+F hotkey-overlay-title="Maximize" { maximize-column; }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = true,
	})
	assert(loadfile("niri_service.luau"))()
	local binds = allBinds(values["keymap.snapshot"])
	assert(#binds == 2, "similar binds not merged, got " .. #binds)
	assert(type(binds[1].combos) == "table" and #binds[1].combos == 2, "merged row lost combos")
	assert(binds[1].combos[1].key == "W" and binds[1].combos[2].key == "F4", "merged row combo order wrong")
	assert(#binds[1].combos[1].modifiers == 1 and binds[1].combos[1].modifiers[1] == "Super", "merged row lost modifiers")
	assert(#binds[1].combos[2].modifiers == 1 and binds[1].combos[2].modifiers[1] == "Alt", "merged row lost modifiers")
	assert(binds[1].capabilities.combo == false, "merged row must be read-only")
	assert(binds[1].fingerprint == nil, "merged row must not carry provenance")

	-- the same fixture stays untouched when the flag is off
	values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	assert(#allBinds(values["keymap.snapshot"]) == 3, "merge_similar=false still merged")
end

-- The refresh watcher ignores echoes of an already-handled counter value but
-- reacts to genuine increments.
do
	local source = [[binds {
    Super+Q hotkey-overlay-title="Close window" { close-window; }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, source, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	local refreshes = 0
	noctalia.state.watch("keymap.snapshot", function(snapshot)
		if snapshot.status == "ready" then refreshes = refreshes + 1 end
	end)
	-- The watcher only records intent; update() performs the refresh.
	noctalia.state.set("keymap.refresh_request", 1)
	update()
	local afterFirst = refreshes
	-- host echo of a stale value: no new refresh
	noctalia.state.set("keymap.refresh_request", 1)
	update()
	assert(refreshes == afterFirst, "echo of refresh_request triggered another refresh")
	-- genuine increment: exactly one new refresh
	noctalia.state.set("keymap.refresh_request", 2)
	update()
	assert(refreshes == afterFirst + 1, "increment did not trigger exactly one refresh")
end

print("niri settings tests: ok")
