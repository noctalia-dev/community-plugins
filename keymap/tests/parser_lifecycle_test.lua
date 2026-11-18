-- Regression tests for the coroutine parser lifecycle: multi-tick resumes,
-- stale-generation cancellation, and merge_similar grouping correctness.
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

local function niriHost(values, state, sources, configValues)
	return {
		state = state,
		getConfig = function(key) return configValues[key] end,
		getenv = function(key) return key == "NIRI_SOCKET" and "test" or "" end,
		fileExists = function(path) return sources[path] ~= nil end,
		listDir = function() return nil end,
		readFile = function(path) return sources[path] end,
		tr = function(key, args)
			if args ~= nil and args.command ~= nil then return "Run " .. args.command end
			if args ~= nil and args.action ~= nil then return "Action " .. args.action end
			return key == "category.other" and "Other" or key
		end,
	}
end

local function pumpUntilSettled(values, maxTicks)
	local ticks = 0
	while values["keymap.snapshot"].status == "loading" and ticks < (maxTicks or 200) do
		update()
		ticks = ticks + 1
	end
	return values["keymap.snapshot"], ticks
end

-- A parse that must yield resumes across update ticks and still completes.
do
	-- os.clock that advances aggressively forces a yield at every 40-line slice.
	local fakeNow = 0
	local realClock = os.clock
	os.clock = function() fakeNow = fakeNow + 0.01 return fakeNow end

	local lines = { "binds {" }
	for index = 1, 120 do
		lines[#lines + 1] = string.format(
			'    Super+Key%d hotkey-overlay-title="Action %d" { spawn-sh "cmd%d"; }', index, index, index
		)
	end
	lines[#lines + 1] = "}"
	local values, state = stateMock()
	noctalia = niriHost(values, state, { ["/fixture/config.kdl"] = table.concat(lines, "\n") }, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	assert(loadfile("niri_service.luau"))()
	local snapshot, ticks = pumpUntilSettled(values)
	os.clock = realClock
	assert(snapshot.status == "ready", "multi-tick parse did not settle: " .. tostring(snapshot.status))
	assert(snapshot.total == 120, "multi-tick parse lost binds: " .. tostring(snapshot.total))
	assert(ticks >= 1, "parse never yielded across ticks")
end

-- A parse superseded by a compositor switch must never publish.
do
	local fakeNow = 0
	local realClock = os.clock
	os.clock = function() fakeNow = fakeNow + 0.01 return fakeNow end

	local lines = { "binds {" }
	for index = 1, 200 do
		lines[#lines + 1] = string.format(
			'    Super+Key%d hotkey-overlay-title="Action %d" { spawn-sh "cmd%d"; }', index, index, index
		)
	end
	lines[#lines + 1] = "}"
	local values, state = stateMock()
	local host = niriHost(values, state, { ["/fixture/config.kdl"] = table.concat(lines, "\n") }, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})
	noctalia = host
	assert(loadfile("niri_service.luau"))()
	assert(values["keymap.snapshot"].status == "loading", "large fixture should still be parsing after load")
	-- Simulate the user switching the compositor setting mid-parse.
	host.getConfig = function(key)
		return ({ compositor = "hyprland", niri_config = "/fixture/config.kdl" })[key]
	end
	local stale = values["keymap.snapshot"]
	onConfigChanged()
	update()
	update()
	os.clock = realClock
	assert(values["keymap.snapshot"] == stale, "superseded parse overwrote the snapshot")
end

-- merge_similar must not merge binds that share a title but run different actions.
do
	local source = [[binds {
    Super+A hotkey-overlay-title="Same title" { spawn-sh "one"; }
    Super+B hotkey-overlay-title="Same title" { spawn-sh "two"; }
    Super+W hotkey-overlay-title="Close Window" { close-window; }
    Alt+F4 hotkey-overlay-title="Close Window" { close-window; }
}]]
	local values, state = stateMock()
	noctalia = niriHost(values, state, { ["/fixture/config.kdl"] = source }, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = true,
	})
	assert(loadfile("niri_service.luau"))()
	local binds = {}
	for _, category in ipairs(values["keymap.snapshot"].categories or {}) do
		for _, bind in ipairs(category.binds or {}) do binds[#binds + 1] = bind end
	end
	assert(#binds == 3, "same-title different-action binds merged: " .. #binds)
	local merged
	for _, bind in ipairs(binds) do
		if bind.id:match("^similar:") then merged = bind end
	end
	assert(merged ~= nil, "close-window pair did not merge")
	assert(#merged.combos == 2, "merged row lost combos")
	assert(merged.activation == "press", "merged row activation wrong")
end

print("parser lifecycle tests: ok")
