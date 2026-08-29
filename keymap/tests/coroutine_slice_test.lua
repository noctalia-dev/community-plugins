-- Coroutine parser measurement tests.
--
-- The host meters each callback with a VM-level CPU interrupt, so every
-- resume of the parse coroutine must stay small on its own. Plain Lua's
-- debug.sethook does not follow coroutines, and the parse coroutine is a
-- service upvalue, so these tests wrap coroutine.create before loading the
-- service: every coroutine the service spawns gets a per-thread hook, and
-- each resume slice is metered individually.
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

-- Wrap noctalia.state.watch to capture the service's update/pump entry points.
-- The service exposes update() and (indirectly) pumpParse() as globals; we
-- meter every update() call by installing a hook on the live parse coroutine
-- right before each pump. The coroutine itself is reachable only through the
-- service's upvalues, so instead of fishing it out we measure update() as a
-- whole: with a parked parse, update() IS the resume slice.
local function makeInstrumentedHost(values, state, sources, configValues)
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

local function buildFixture(bindCount, includeCount)
	local rootLines = {}
	for index = 1, 200 do
		rootLines[#rootLines + 1] = "// stock documentation line " .. tostring(index)
	end
	rootLines[#rootLines + 1] = "binds {"
	for index = 1, bindCount do
		rootLines[#rootLines + 1] = string.format(
			'    Mod+Key%d repeat=false cooldown-ms=150 { focus-workspace %d; }', index, index
		)
	end
	rootLines[#rootLines + 1] = "}"
	for index = 1, includeCount do
		rootLines[#rootLines + 1] = string.format('include "inc%d.kdl"', index)
	end
	local sources = { ["/fixture/config.kdl"] = table.concat(rootLines, "\n") }
	for index = 1, includeCount do
		local lines = { "binds {" }
		for bind = 1, 10 do
			lines[#lines + 1] = string.format(
				'    Mod+Alt+Key%d_%d hotkey-overlay-title="Included %d %d" { spawn-sh "cmd"; }',
				index, bind, index, bind
			)
		end
		lines[#lines + 1] = "}"
		sources["/fixture/inc" .. tostring(index) .. ".kdl"] = table.concat(lines, "\n")
	end
	return sources
end

-- A large multi-file fixture must take the multi-tick path: at least one
-- coroutine yield, and every resume slice individually metered and bounded.
local function meterServiceParses(chunk)
	-- Intercept coroutine creation/resume so the service's parse coroutine
	-- carries a counting hook; debug.sethook on the caller does not follow
	-- into coroutine bodies, so this is the only way to meter slices.
	local sliceBlocks = {}
	local hooked = {}
	local realCreate = coroutine.create
	local realResume = coroutine.resume
	local blockCounter = 0
	coroutine.create = function(fn)
		local co = realCreate(fn)
		hooked[co] = true
		debug.sethook(co, function() blockCounter = blockCounter + 1 end, "", 500)
		return co
	end
	coroutine.resume = function(co, ...)
		if hooked[co] then
			blockCounter = 0
			local results = table.pack(realResume(co, ...))
			sliceBlocks[#sliceBlocks + 1] = blockCounter
			return table.unpack(results, 1, results.n)
		end
		return realResume(co, ...)
	end
	chunk()
	coroutine.create = realCreate
	coroutine.resume = realResume
	return sliceBlocks
end

-- Slices are metered in 500-instruction blocks. The host budget is wall
-- clock, not instruction count, so instead of an absolute bound we require
-- the work to be spread: every slice must stay within a modest multiple of
-- the mean, and no slice may be a runaway. The final slice runs the
-- unchunked category/merge phase, so the bound leaves it real headroom.
local function assertSliceSpread(sliceBlocks, label)
	assert(#sliceBlocks >= 2, label .. ": parse never took the multi-tick path")
	local totalSliceBlocks = 0
	for _, blocks in ipairs(sliceBlocks) do totalSliceBlocks = totalSliceBlocks + blocks end
	assert(totalSliceBlocks > 0, label .. ": slice metering recorded zero instructions; the hook is not measuring")
	local mean = totalSliceBlocks / #sliceBlocks
	for index, blocks in ipairs(sliceBlocks) do
		assert(blocks <= math.max(60, mean * 4),
			string.format("%s: resume slice %d dominates: %d blocks (mean %.1f)", label, index, blocks, mean))
	end
end

do
	local fakeNow = 0
	local realClock = os.clock
	os.clock = function() fakeNow = fakeNow + 0.0002 return fakeNow end

	local sources = buildFixture(120, 8)
	local values, state = stateMock()
	noctalia = makeInstrumentedHost(values, state, sources, {
		compositor = "niri", niri_config = "/fixture/config.kdl",
		merge_sequential = false, show_undescribed = true, merge_similar = false,
	})

	local sliceBlocks
	local function run()
		assert(loadfile("niri_service.luau"))()
		local ticks = 0
		while values["keymap.snapshot"].status == "loading" and ticks < 300 do
			update()
			ticks = ticks + 1
		end
	end
	sliceBlocks = meterServiceParses(run)
	os.clock = realClock

	local snapshot = values["keymap.snapshot"]
	assert(snapshot.status == "ready", "instrumented fixture did not settle: " .. tostring(snapshot.status))
	assert(snapshot.total == 200, "instrumented fixture lost binds: " .. tostring(snapshot.total))
	assertSliceSpread(sliceBlocks, "niri")
end

-- Identical coverage for the MangoWC coroutine parser.
do
	local fakeNow = 0
	local realClock = os.clock
	os.clock = function() fakeNow = fakeNow + 0.0002 return fakeNow end

	local lines = {}
	for index = 1, 200 do
		lines[#lines + 1] = "# stock documentation line " .. tostring(index)
	end
	for index = 1, 150 do
		lines[#lines + 1] = string.format('bind=SUPER,F%d,spawn,command-%d #"Action %d"', index, index, index)
	end
	lines[#lines + 1] = "source=./extra.conf"
	local extra = {}
	for index = 1, 60 do
		extra[#extra + 1] = string.format('bind=ALT,F%d,spawn,extra-%d #"Extra %d"', index, index, index)
	end
	local sources = {
		["/fixture/config.conf"] = table.concat(lines, "\n"),
		["/fixture/extra.conf"] = table.concat(extra, "\n"),
	}

	local values, state = stateMock()
	noctalia = {
		state = state,
		getConfig = function(key)
			return ({
				compositor = "mangowc", mangowc_config = "/fixture/config.conf",
				merge_sequential = false, merge_similar = false,
			})[key]
		end,
		getenv = function(key) return key == "MANGO_INSTANCE_SIGNATURE" and "test" or "" end,
		expandPath = function(path) return path end,
		fileExists = function(path) return sources[path] ~= nil end,
		readFile = function(path) return sources[path] end,
		tr = function(key) return key == "category.other" and "Other" or key end,
	}
	local sliceBlocks
	local function run()
		assert(loadfile("mangowc_service.luau"))()
		local ticks = 0
		while values["keymap.snapshot"].status == "loading" and ticks < 300 do
			update()
			ticks = ticks + 1
		end
	end
	sliceBlocks = meterServiceParses(run)
	os.clock = realClock

	local snapshot = values["keymap.snapshot"]
	assert(snapshot.status == "ready", "mangowc instrumented fixture did not settle: " .. tostring(snapshot.status))
	assert(snapshot.total == 210, "mangowc instrumented fixture lost binds: " .. tostring(snapshot.total))
	assertSliceSpread(sliceBlocks, "mangowc")
end

print("coroutine slice tests: ok")
