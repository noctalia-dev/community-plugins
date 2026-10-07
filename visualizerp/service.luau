--!nonstrict
-- Scope capture service.
--
-- Runs bin/pwscope (a small PipeWire client that taps the monitor of the
-- default audio output), parses each "F" frame line and publishes the
-- waveform envelope to shared plugin state. Diagnostic lines starting with
-- '#' are forwarded to the Noctalia log. The bar widget (widget.luau) renders
-- this state; keeping the capture here means many widgets share one process.

local DATA_KEY = "viz.data"
local TARGET_KEY = "viz.target"
local STATUS_KEY = "viz.status"
local PITCH_KEY = "viz.pitch"

local function shellQuote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function number(value, fallback)
	local n = tonumber(value)
	if n == nil then
		return fallback
	end
	return n
end

local function buildCommand()
	local dir = noctalia.pluginDir() or ""
	local parts = { shellQuote(dir .. "/bin/pwscope") }

	local function opt(key, value)
		if value ~= nil and value ~= "" then
			parts[#parts + 1] = key
			parts[#parts + 1] = tostring(value)
		end
	end

	opt("--fps", number(noctalia.getConfig("fps"), 30))
	opt("--cols", number(noctalia.getConfig("cols"), 96))
	opt("--sensitivity", number(noctalia.getConfig("sensitivity"), 1.0))
	opt("--smoothing", number(noctalia.getConfig("smoothing"), 0.0))
	opt("--gate", number(noctalia.getConfig("gate"), 0.0025))
	opt("--target", noctalia.getConfig("target"))

	return table.concat(parts, " ")
end

local function onLine(line)
	if type(line) ~= "string" or line == "" then
		return
	end

	local first = line:sub(1, 1)
	if first == "#" then
		local target = line:match("^# target %(.-%)%s*:%s*(.-)%s*$")
		if target ~= nil and target ~= "" then
			noctalia.state.set(TARGET_KEY, target)
		end

		-- The helper reports the locked fundamental occasionally; it is the
		-- only place the trigger state is observable from Lua.
		local pitch = line:match("^# pitch ([%d%.]+)")
		if pitch ~= nil then
			noctalia.state.set(PITCH_KEY, tonumber(pitch))
		end

		noctalia.log("viz: " .. line)
		return
	end

	if first ~= "F" then
		return
	end

	local fields = {}
	for token in line:gmatch("%S+") do
		fields[#fields + 1] = token
	end

	-- "F seq rms peak flags min0 max0 min1 max1 ..." (5 + 2 * cols tokens)
	local count = #fields
	if count < 7 or (count - 5) % 2 ~= 0 then
		return
	end

	local upper = {}
	local lower = {}
	local cols = (count - 5) // 2

	-- "F seq rms peak flags min0 max0 min1 max1 ..."
	for i = 1, cols do
		local min = number(fields[4 + i * 2], 128) / 255
		local max = number(fields[5 + i * 2], 128) / 255
		upper[i] = max
		lower[i] = min
	end

	local flags = number(fields[5], 0)
	noctalia.state.set(DATA_KEY, {
		seq = number(fields[2], 0),
		rms = number(fields[3], 128),
		peak = number(fields[4], 128),
		silent = (flags % 2) == 1, -- bit 0 = silence gate engaged
		cols = cols,
		upper = upper,
		lower = lower,
	})
end

local function spawn()
	local command = buildCommand()
	-- runStream has no exit callback or restart policy, so the retry loop
	-- lives in one managed shell process, voxtype style. It re-runs pwscope
	-- a moment after it exits (e.g. after a PipeWire outage).
	local loop =
		"P=$PPID; while kill -0 \"$P\" 2>/dev/null; do "
		.. command
		.. "; sleep 2; done"
	if noctalia.runStream(loop, onLine) then
		noctalia.state.set(STATUS_KEY, { state = "running" })
	else
		noctalia.state.set(STATUS_KEY, { state = "error", message = "failed to start pwscope" })
		noctalia.log("viz: failed to start capture: " .. command)
	end
end

-- The helper ships as C source under native/; builds it into bin/ the first
-- time the plugin runs (or after a plugin update that does not carry a
-- prebuilt binary). Only `make` is invoked, in the plugin's own directory.
local function ensureBuilt(thenSpawn)
	local dir = noctalia.pluginDir() or ""

	local files = noctalia.listDir(dir .. "/bin")
	if files ~= nil then
		for _, name in ipairs(files) do
			if name == "pwscope" then
				thenSpawn()
				return
			end
		end
	end

	noctalia.log("viz: building native helper (make -C native)")
	noctalia.runAsync("make -C " .. shellQuote(dir .. "/native"), function(result)
		if result ~= nil and result.exitCode == 0 then
			thenSpawn()
			return
		end
		local detail = result ~= nil and result.stderr or nil
		noctalia.log("viz: helper build failed" ..
			(detail ~= nil and detail ~= "" and (": " .. detail) or ""))
		noctalia.state.set(STATUS_KEY, {
			state = "error",
			message = noctalia.tr("widget.build_failed"),
		})
	end)
end

ensureBuilt(spawn)