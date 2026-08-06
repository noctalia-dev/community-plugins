--!nonstrict
-- W-Engine service — owns every linux-wallpaperengine process, the palette sync
-- and the cycle timer.
--
-- The panel publishes requests on noctalia.state and this entry carries them
-- out, so a cycle continues while the panel is closed and a single owner holds
-- the pid files.

local TICK_MS = 1000
local REQUEST_KEY = "w_engine_request"
local STATUS_KEY = "w_engine_status"

local WORKSHOP_PATHS = {
	"~/.steam/steam/steamapps/workshop/content/431960/",
	"~/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960/",
	"~/snap/steam/common/.local/share/steam/steamapps/workshop/content/431960/",
}

-- Persisted across reloads (pluginDataDir()/data.json).
local data = {
	personnalPath = {},
	selection = {},       -- output -> { id, ... } in the order the user picked them
	cycle = {},           -- output -> { enabled, minutes, order }
	current = {},         -- output -> id currently playing
	saved_wallpaper = {}, -- output -> the Noctalia wallpaper from before we took over
	options = {},         -- id -> { engine = {...}, properties = {...} }, see buildLaunchArgs
	defaults = {},        -- { engine = {...} } applied to every wallpaper, see optionsFor
}

-- linux-wallpaperengine switches that take no value. Stored as booleans; the
-- flag is emitted only when true.
local ENGINE_FLAGS = {
	{ key = "silent", flag = "--silent" },
	{ key = "noautomute", flag = "--noautomute" },
	{ key = "no_audio_processing", flag = "--no-audio-processing" },
	{ key = "disable_particles", flag = "--disable-particles" },
	{ key = "disable_mouse", flag = "--disable-mouse" },
	{ key = "disable_parallax", flag = "--disable-parallax" },
	{ key = "no_fullscreen_pause", flag = "--no-fullscreen-pause" },
	{ key = "fullscreen_pause_only_active", flag = "--fullscreen-pause-only-active" },
}

-- Switches taking a value. scaling and clamp bind to the preceding --bg, so they
-- are emitted right after it; the rest are process-wide.
local ENGINE_SCREEN_VALUES = {
	{ key = "scaling", flag = "--scaling" },
	{ key = "clamp", flag = "--clamp" },
}
local ENGINE_GLOBAL_VALUES = {
	{ key = "layer", flag = "--layer" },
	{ key = "fps", flag = "--fps" },
	{ key = "volume", flag = "--volume" },
}

local elapsed = {}  -- output -> seconds since that output last switched
local shuffled = {} -- output -> ids left to play in this random pass
local lastNonce = nil
local workshopRoot = nil
local rngState = 0

local function tr(key, subst)
	if subst then
		return noctalia.tr(key, subst)
	end
	return noctalia.tr(key)
end

-- ── Persistence ──────────────────────────────────────────────────────────────

local function dataPath()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/data.json"
end

local function asTable(value)
	return type(value) == "table" and value or {}
end

local function loadData()
	local path = dataPath()
	if not path then
		return
	end
	local raw = noctalia.readFile(path)
	if not raw then
		return
	end
	local decoded = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return
	end
	-- personnalPath is user-authored (see README); a file holding only that key
	-- is valid.
	data.personnalPath = asTable(decoded.personnalPath)
	data.selection = asTable(decoded.selection)
	data.cycle = asTable(decoded.cycle)
	data.current = asTable(decoded.current)
	data.saved_wallpaper = asTable(decoded.saved_wallpaper)
	data.options = asTable(decoded.options)
	data.defaults = asTable(decoded.defaults)
end

local function saveData()
	local path = dataPath()
	if not path then
		return
	end
	local encoded = noctalia.json.encode(data, true)
	if encoded then
		noctalia.writeFile(path, encoded)
	end
end

-- ── Workshop discovery ───────────────────────────────────────────────────────

local function candidateRoots()
	local roots = {}
	for _, path in ipairs(WORKSHOP_PATHS) do
		table.insert(roots, path)
	end
	for _, path in ipairs(data.personnalPath) do
		if type(path) == "string" and path ~= "" then
			if not path:match("/$") then
				path = path .. "/"
			end
			table.insert(roots, path)
		end
	end
	return roots
end

-- Several stock locations can exist at once, and last match wins, so a
-- personnalPath entry takes precedence.
local function resolveWorkshopRoot()
	local root = nil
	for _, path in ipairs(candidateRoots()) do
		if noctalia.listDir(path) then
			root = path
		end
	end
	return root
end

local function itemDir(id)
	workshopRoot = workshopRoot or resolveWorkshopRoot()
	if not workshopRoot then
		return nil
	end
	return workshopRoot .. id .. "/"
end

local function project(id)
	local dir = itemDir(id)
	if not dir then
		return nil, nil
	end
	local raw = noctalia.readFile(dir .. "project.json")
	if not raw then
		return nil, dir
	end
	local decoded = noctalia.json.decode(raw)
	if type(decoded) ~= "table" then
		return nil, dir
	end
	return decoded, dir
end

-- ── Palette sync ─────────────────────────────────────────────────────────────
--
-- Noctalia derives its palette from the wallpaper image, so setting a still that
-- represents the live wallpaper runs the configured generator, scheme, mode and
-- templates as for any other wallpaper.
--
-- The still is the Workshop preview, which Noctalia decodes directly (.jpg, .png
-- and .gif). Video wallpapers use a frame decoded with ffmpeg instead, as their
-- preview is often a stylised thumbnail rather than a frame of the video.

local function syncEnabled()
	return noctalia.getConfig("sync_colors") ~= false
end

local function shellQuote(path)
	return "'" .. noctalia.expandPath(path):gsub("'", "'\\''") .. "'"
end

local function framePath(id)
	local dir = noctalia.pluginDataDir()
	if not dir then
		return nil
	end
	return dir .. "/frames/" .. id .. ".jpg"
end

-- Calls back with a path to an image representing item `id`, or nil.
local function resolveColorSource(id, callback)
	local info, dir = project(id)
	if not dir then
		callback(nil)
		return
	end

	local preview = dir .. ((info and info.preview) or "preview.jpg")
	if not noctalia.fileExists(preview) then
		preview = nil
	end

	local kind = string.lower(tostring((info and info.type) or ""))
	local file = info and info.file
	local frame = framePath(id)
	if kind ~= "video" or type(file) ~= "string" or file == "" or not frame then
		callback(preview)
		return
	end
	if noctalia.fileExists(frame) then
		callback(frame)
		return
	end
	if not noctalia.commandExists("ffmpeg") then
		callback(preview)
		return
	end

	local dataDir = noctalia.pluginDataDir()
	if dataDir then
		noctalia.mkdirAll(dataDir .. "/frames")
	end
	-- One frame, scaled down: the generator only needs the colors. Workshop file
	-- names contain spaces and non-ASCII, so paths are quoted.
	local cmd = "ffmpeg -y -loglevel error -ss 1 -i "
		.. shellQuote(dir .. file)
		.. " -frames:v 1 -vf scale=960:-2 "
		.. shellQuote(frame)
	noctalia.runAsync(cmd, function(result)
		-- A wallpaper shorter than the seek offset produces no output and no error,
		-- so the file is the success signal rather than the exit code.
		if noctalia.fileExists(frame) then
			callback(frame)
		else
			callback(preview)
		end
	end, 20000)
end

-- Captures the Noctalia wallpaper for an output once, so stopping can restore
-- it. Later applies must not overwrite the stash with a generated still.
local function setShellWallpaper(output, path)
	if data.saved_wallpaper[output] ~= nil then
		noctalia.setWallpaper(output, path)
		return
	end
	noctalia.runAsync("noctalia msg wallpaper-get " .. output, function(result)
		local previous = noctalia.string.trim(result.stdout or "")
		if result.exitCode == 0 and previous ~= "" then
			data.saved_wallpaper[output] = previous
			saveData()
		end
		noctalia.setWallpaper(output, path)
	end, 3000)
end

local function syncPalette(output, id)
	if not syncEnabled() then
		return
	end
	resolveColorSource(id, function(path)
		if path then
			setShellWallpaper(output, path)
		end
	end)
end

local function restoreShellWallpaper(output)
	local previous = data.saved_wallpaper[output]
	data.saved_wallpaper[output] = nil
	saveData()
	if type(previous) == "string" and previous ~= "" and noctalia.fileExists(previous) then
		noctalia.setWallpaper(output, previous)
	end
end

-- ── linux-wallpaperengine processes ──────────────────────────────────────────

local function pidFile(output)
	return "/tmp/w-engine-" .. output .. ".pid"
end

-- The recorded pid for this output, when that process is still one of ours. The
-- pid file is the source of truth across script reloads.
local function livePid(output)
	local raw = noctalia.readFile(pidFile(output))
	if not raw then
		return nil
	end
	local pid = noctalia.string.trim(raw)
	if pid == "" or not tonumber(pid) then
		return nil
	end
	local cmdline = noctalia.readFile("/proc/" .. pid .. "/cmdline")
	if not cmdline then
		return nil
	end
	-- Some packages wrap the binary and exec ./linux-wallpaperengine from its own
	-- directory, so argv[0] is not always the bare name.
	if cmdline:find("linux-wallpaperengine", 1, true) then
		return pid
	end
	return nil
end

-- Options are resolved in three layers. The global defaults apply to every
-- wallpaper, a wallpaper's own engine settings override them key by key, and any
-- key still absent produces no flag, leaving linux-wallpaperengine's default.
--
--   defaults      = { engine = { silent = true, fps = 24, ... } }
--   options[id]   = { engine = { fps = 60 },
--                     properties = { embers = false, barcolor = "0.5 0.2 0.1" } }
--
-- Properties are not layered: they are declared by one wallpaper and mean
-- nothing to any other.
local function optionsFor(id)
	local engine = {}
	for key, value in pairs(asTable(data.defaults.engine)) do
		engine[key] = value
	end

	local entry = data.options[id]
	if type(entry) ~= "table" then
		return engine, {}
	end
	for key, value in pairs(asTable(entry.engine)) do
		engine[key] = value
	end
	return engine, asTable(entry.properties)
end

-- Wallpaper properties are typed in project.json but arrive here as plain Luau
-- values; the CLI wants booleans as true/false, colors as the "r g b" string the
-- panel already stores, and everything else as a bare number.
local function propertyValue(value)
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	return tostring(value)
end

local function buildLaunchArgs(output, id)
	local engine, properties = optionsFor(id)
	local args = { "--screen-root", output, "--bg", id }

	for _, spec in ipairs(ENGINE_SCREEN_VALUES) do
		local value = engine[spec.key]
		if value ~= nil and value ~= "" and value ~= "default" then
			table.insert(args, spec.flag)
			table.insert(args, tostring(value))
		end
	end
	for _, spec in ipairs(ENGINE_GLOBAL_VALUES) do
		local value = engine[spec.key]
		if value ~= nil and value ~= "" then
			table.insert(args, spec.flag)
			table.insert(args, tostring(value))
		end
	end
	for _, spec in ipairs(ENGINE_FLAGS) do
		if engine[spec.key] == true then
			table.insert(args, spec.flag)
		end
	end

	-- Sorted so a relaunch with unchanged settings produces an identical command.
	local names = {}
	for name in pairs(properties) do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in ipairs(names) do
		table.insert(args, "--set-property")
		table.insert(args, name .. "=" .. propertyValue(properties[name]))
	end

	local quoted = {}
	for _, arg in ipairs(args) do
		table.insert(quoted, "'" .. tostring(arg):gsub("'", "'\\''") .. "'")
	end
	return table.concat(quoted, " ")
end

local function launch(output, id)
	local cmd = "setsid linux-wallpaperengine "
		.. buildLaunchArgs(output, id)
		.. " > /dev/null 2>&1 & echo $! > "
		.. pidFile(output)
	noctalia.runAsync(cmd, nil, 5000)
end

-- linux-wallpaperengine ignores SIGTERM and SIGINT, so stopping escalates to
-- SIGKILL after a grace period.
local function killCommand(pid)
	return "kill "
		.. pid
		.. " 2>/dev/null; n=0; while kill -0 "
		.. pid
		.. " 2>/dev/null && [ $n -lt 10 ]; do sleep 0.2; n=$((n+1)); done; kill -9 "
		.. pid
		.. " 2>/dev/null; true"
end

local function stopProcess(output, onStopped)
	local pid = livePid(output)
	if not pid then
		noctalia.removeFile(pidFile(output))
		if onStopped then
			onStopped()
		end
		return
	end
	noctalia.runAsync(killCommand(pid), function()
		noctalia.removeFile(pidFile(output))
		if onStopped then
			onStopped()
		end
	end, 6000)
end

-- ── Status published to the panel ────────────────────────────────────────────

local function cycleFor(output)
	local cycle = data.cycle[output]
	if type(cycle) ~= "table" then
		return { enabled = false, minutes = 15, order = "sequential" }
	end
	return {
		enabled = cycle.enabled == true,
		minutes = tonumber(cycle.minutes) or 15,
		order = cycle.order == "random" and "random" or "sequential",
	}
end

local function selectionFor(output)
	local ids = data.selection[output]
	return type(ids) == "table" and ids or {}
end

local function publishStatus()
	local outputs = {}
	for _, output in ipairs(noctalia.outputs()) do
		local name = output.name
		local cycle = cycleFor(name)
		local remaining = nil
		if cycle.enabled then
			remaining = math.max(0, cycle.minutes * 60 - (elapsed[name] or 0))
		end
		outputs[name] = {
			current = data.current[name],
			selection = selectionFor(name),
			cycle_enabled = cycle.enabled,
			cycle_minutes = cycle.minutes,
			cycle_order = cycle.order,
			remaining_seconds = remaining,
			restorable = data.saved_wallpaper[name] ~= nil,
		}
	end
	noctalia.state.set(STATUS_KEY, {
		outputs = outputs,
		options = data.options,
		defaults = data.defaults,
		sync_colors = syncEnabled(),
	})
end

-- ── Applying a wallpaper ─────────────────────────────────────────────────────

local function apply(output, id)
	if type(output) ~= "string" or output == "" or type(id) ~= "string" or id == "" then
		return
	end
	data.current[output] = id
	elapsed[output] = 0
	saveData()

	stopProcess(output, function()
		launch(output, id)
	end)
	syncPalette(output, id)
	publishStatus()
end

-- ── Cycling ──────────────────────────────────────────────────────────────────

local function seedRng()
	local seed = 0
	if os and os.time then
		seed = os.time()
	end
	rngState = seed % 2147483647
	if rngState <= 0 then
		rngState += 2147483646
	end
end

local function randomIndex(n)
	if n <= 1 then
		return 1
	end
	if math.random then
		return math.random(n)
	end
	rngState = (rngState * 16807) % 2147483647
	return (rngState % n) + 1
end

-- Random plays a shuffled pass over the whole selection before reshuffling, so
-- no wallpaper repeats within a pass.
local function nextRandom(output, ids)
	local remaining = shuffled[output]
	if type(remaining) ~= "table" or #remaining == 0 then
		remaining = {}
		for _, id in ipairs(ids) do
			table.insert(remaining, id)
		end
		for i = #remaining, 2, -1 do -- Fisher-Yates
			local j = randomIndex(i)
			remaining[i], remaining[j] = remaining[j], remaining[i]
		end
		-- A fresh pass must not open on the wallpaper that just finished.
		if #remaining > 1 and remaining[1] == data.current[output] then
			remaining[1], remaining[#remaining] = remaining[#remaining], remaining[1]
		end
		shuffled[output] = remaining
	end
	return table.remove(remaining, 1)
end

local function nextSequential(output, ids)
	local current = data.current[output]
	for index, id in ipairs(ids) do
		if id == current then
			return ids[(index % #ids) + 1]
		end
	end
	return ids[1]
end

local function advance(output)
	local ids = selectionFor(output)
	if #ids == 0 then
		return
	end
	local cycle = cycleFor(output)
	local id
	if cycle.order == "random" then
		id = nextRandom(output, ids)
	else
		id = nextSequential(output, ids)
	end
	if id then
		apply(output, id)
	end
end

-- ── Requests from the panel ──────────────────────────────────────────────────

local function setCycle(output, enabled, minutes, order)
	local cycle = cycleFor(output)
	if enabled ~= nil then
		cycle.enabled = enabled == true
	end
	if tonumber(minutes) then
		cycle.minutes = math.max(1, math.floor(tonumber(minutes)))
	end
	if order == "random" or order == "sequential" then
		cycle.order = order
	end
	data.cycle[output] = cycle
	elapsed[output] = 0
	shuffled[output] = nil
	saveData()
end

local function handleRequest(request)
	if type(request) ~= "table" then
		return
	end
	if request.nonce ~= nil and request.nonce == lastNonce then
		return
	end
	lastNonce = request.nonce

	local output = request.output
	if type(output) ~= "string" or output == "" then
		output = noctalia.focusedOutputName()
	end
	if type(output) ~= "string" or output == "" then
		return
	end

	local action = request.action
	if action == "apply" then
		-- A one-shot pick takes over from any cycle on that output.
		setCycle(output, false)
		apply(output, request.id)
	elseif action == "select" then
		local ids = {}
		if type(request.ids) == "table" then
			for _, id in ipairs(request.ids) do
				if type(id) == "string" and id ~= "" then
					table.insert(ids, id)
				end
			end
		end
		data.selection[output] = ids
		shuffled[output] = nil
		saveData()
		publishStatus()
	elseif action == "cycle" then
		setCycle(output, request.enabled, request.minutes, request.order)
		local cycle = cycleFor(output)
		if cycle.enabled then
			local ids = selectionFor(output)
			if #ids == 0 then
				setCycle(output, false)
				noctalia.notify(tr("panel.title"), tr("panel.cycle_needs_selection"))
			else
				-- Start on the first pick straight away rather than leaving the
				-- previous wallpaper up for a whole interval.
				local first = cycle.order == "random" and nextRandom(output, ids) or ids[1]
				apply(output, first)
				noctalia.notify(
					tr("panel.title"),
					tr("panel.cycle_started", { count = #ids, minutes = cycle.minutes })
				)
			end
		end
		publishStatus()
	elseif action == "stop" then
		setCycle(output, false)
		data.current[output] = nil
		saveData()
		stopProcess(output, nil)
		restoreShellWallpaper(output)
		publishStatus()
	elseif action == "options" then
		-- Whole-table replace, not a merge: the panel owns the form and sends the
		-- complete state, so clearing a setting there has to clear it here.
		local id = request.id
		if type(id) == "string" and id ~= "" then
			data.options[id] = {
				engine = asTable(request.engine),
				properties = asTable(request.properties),
			}
			saveData()
			-- Options are command-line arguments, so they only take effect on a
			-- fresh process. Restart any output currently showing this wallpaper.
			if request.restart ~= false then
				for output, current in pairs(data.current) do
					if current == id then
						local target = output
						stopProcess(target, function()
							launch(target, id)
						end)
					end
				end
			end
			publishStatus()
		end
	elseif action == "defaults" then
		local previous = asTable(data.defaults.engine)
		local engine = asTable(request.engine)
		data.defaults = { engine = engine }

		-- Optionally drop per-wallpaper overrides, but only for the keys whose
		-- default actually changed. Settings the user tuned for one wallpaper and
		-- did not touch here keep their override.
		if request.clear_overrides == true then
			for key, value in pairs(engine) do
				if previous[key] ~= value then
					for _, entry in pairs(data.options) do
						if type(entry) == "table" and type(entry.engine) == "table" then
							entry.engine[key] = nil
						end
					end
				end
			end
			for key in pairs(previous) do
				if engine[key] == nil then
					for _, entry in pairs(data.options) do
						if type(entry) == "table" and type(entry.engine) == "table" then
							entry.engine[key] = nil
						end
					end
				end
			end
		end
		saveData()
		-- Every running wallpaper resolves these, so all of them restart.
		if request.restart ~= false then
			for output, id in pairs(data.current) do
				if type(id) == "string" and id ~= "" then
					local target, wallpaper = output, id
					stopProcess(target, function()
						launch(target, wallpaper)
					end)
				end
			end
		end
		publishStatus()
	elseif action == "status" then
		publishStatus()
	end
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

function update()
	local switched = false
	for _, output in ipairs(noctalia.outputs()) do
		local name = output.name
		local cycle = cycleFor(name)
		if cycle.enabled and #selectionFor(name) > 1 then
			elapsed[name] = (elapsed[name] or 0) + TICK_MS / 1000
			if elapsed[name] >= cycle.minutes * 60 then
				advance(name)
				switched = true
			end
		end
	end
	if switched then
		publishStatus()
	end
end

function onIpc(event, payload)
	-- Same verbs as the panel, for keybinds:
	--   noctalia msg plugin tadomika_ari/w-engine:start all cycle-stop
	if event == "cycle-stop" then
		handleRequest({ action = "cycle", enabled = false, output = payload })
	elseif event == "stop" then
		handleRequest({ action = "stop", output = payload })
	elseif event == "next" then
		local output = payload
		if type(output) ~= "string" or output == "" then
			output = noctalia.focusedOutputName()
		end
		if output then
			advance(output)
			publishStatus()
		end
	end
end

function onConfigChanged()
	-- Enabling the sync mid-session applies the palette for whatever is playing.
	if syncEnabled() then
		for output, id in pairs(data.current) do
			if type(id) == "string" and id ~= "" then
				syncPalette(output, id)
			end
		end
	end
	publishStatus()
end

noctalia.state.watch(REQUEST_KEY, handleRequest)

-- Sweep orphaned processes and the stale pid files left by a previous load.
--
-- Matches on the process name, which the kernel truncates to 15 characters. The
-- -f form would also match this command's own shell.
local entries = noctalia.listDir("/tmp")
if entries then
	for _, entry in ipairs(entries) do
		if entry:match("^w%-engine") then
			noctalia.removeFile("/tmp/" .. entry)
		end
	end
end

seedRng()
loadData()
workshopRoot = resolveWorkshopRoot()
noctalia.setUpdateInterval(TICK_MS)
publishStatus()

-- The sweep completes before anything relaunches; its second pass runs a second
-- after the first.
noctalia.runAsync(
	"pkill linux-wallpaper 2>/dev/null; sleep 1; pkill -KILL linux-wallpaper 2>/dev/null; true",
	function()
		-- Bring back whatever was playing before the reload, cycle included. The
		-- palette is re-synced alongside the process: the shell restores its own
		-- wallpaper on login, which drops the still we set for the live scene and
		-- leaves the colors from whatever it picked instead.
		for _, output in ipairs(noctalia.outputs()) do
			local name = output.name
			local id = data.current[name]
			if type(id) == "string" and id ~= "" then
				elapsed[name] = 0
				launch(name, id)
				syncPalette(name, id)
			end
		end
		publishStatus()
	end,
	8000
)
