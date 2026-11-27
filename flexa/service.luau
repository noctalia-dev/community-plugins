--!nonstrict
-- Flexa background service: owns the headless Python/mpv backend stream,
-- translates compact backend snapshots into `noctalia.state` updates, and
-- dispatches UI commands plus compositor IPC shortcuts.

local PLUGIN_ID = "nirikshak01/flexa"
local PANEL_ID = PLUGIN_ID .. ":player"

local pluginDir = noctalia.pluginDir() or "."
local backendPath = pluginDir .. "/flexa_backend.py"
local dataDir, dataErr = noctalia.pluginDataDir()
if not dataDir then
	dataDir = pluginDir .. "/.data"
	noctalia.mkdirAll(dataDir)
	noctalia.log("flexa: pluginDataDir fallback used: " .. tostring(dataErr))
end
local startupCfgPath = dataDir .. "/startup_config.json"

local function shq(text: string): string
	return "'" .. string.gsub(text, "'", [['\'']]) .. "'"
end

local function readSettings()
	return {
		musicDirectory = tostring(noctalia.getConfig("musicDirectory") or ""),
		recursiveScan = noctalia.getConfig("recursiveScan") ~= false,
		defaultVolume = tonumber(noctalia.getConfig("defaultVolume")) or 80,
		rememberLastTrack = noctalia.getConfig("rememberLastTrack") ~= false,
		extractArtwork = noctalia.getConfig("extractArtwork") ~= false,
	}
end

local function writeStartupConfig(cfg)
	local payload = {
		dir = cfg.musicDirectory,
		recursive = cfg.recursiveScan,
		extractArtwork = cfg.extractArtwork,
		defaultVolume = cfg.defaultVolume,
		remember = cfg.rememberLastTrack,
	}
	local encoded, err = noctalia.json.encode(payload)
	if encoded then
		noctalia.writeFile(startupCfgPath, encoded)
	else
		noctalia.log("flexa: failed to encode startup config: " .. tostring(err))
	end
end

local backendReady = false
local cmdTarget = dataDir
local pendingScan = false

local function sendBackend(payload: { [string]: any })
	if not backendReady then
		if payload.action == "scan" then
			pendingScan = true
		end
		return
	end
	local encoded, err = noctalia.json.encode(payload)
	if not encoded then
		noctalia.log("flexa: failed to encode command: " .. tostring(err))
		return
	end
	noctalia.runAsync({ "python3", backendPath, "cmd", cmdTarget, encoded }, function(res)
		if res.exitCode ~= 0 then
			noctalia.log("flexa: backend cmd failed (" .. tostring(res.exitCode) .. ") for " .. tostring(payload.action))
		end
	end)
end

local function triggerScan()
	local cfg = readSettings()
	writeStartupConfig(cfg)
	sendBackend({
		action = "scan",
		dir = cfg.musicDirectory,
		recursive = cfg.recursiveScan,
		extractArtwork = cfg.extractArtwork,
		defaultVolume = cfg.defaultVolume,
		remember = cfg.rememberLastTrack,
	})
end

local function startBackend()
	if not noctalia.commandExists("python3") then
		noctalia.notifyError(noctalia.tr("title"), "python3 is required for Flexa.")
		noctalia.state.set("backendError", "missing_python3")
		return
	end
	if not noctalia.commandExists("mpv") then
		noctalia.notifyError(noctalia.tr("title"), "mpv is required for Flexa audio playback.")
		noctalia.state.set("backendError", "missing_mpv")
		return
	end

	writeStartupConfig(readSettings())
	noctalia.state.set("backendError", nil)
	local cmd = "python3 " .. shq(backendPath) .. " serve " .. shq(dataDir)
	local ok = noctalia.runStream(cmd, function(line: string)
		local msg, err = noctalia.json.decode(line)
		if type(msg) ~= "table" then
			if err then
				noctalia.log("flexa: backend decode error: " .. tostring(err))
			end
			return
		end

		local kind = msg.type
		if kind == "ready" then
			backendReady = true
			if type(msg.sock) == "string" and msg.sock ~= "" then
				cmdTarget = msg.sock
			end
			if pendingScan then
				pendingScan = false
				triggerScan()
			end
		elseif kind == "state" then
			noctalia.state.set("playback", msg)
		elseif kind == "view" then
			if type(msg.path) == "string" and msg.path ~= "" then
				noctalia.readFileAsync(msg.path, function(contents: string?, readErr: string?)
					if contents then
						local view, decErr = noctalia.json.decode(contents)
						if type(view) == "table" then
							noctalia.state.set("view", view)
							noctalia.state.set("libraryMeta", {
								scanning = view.scanning == true,
								error = view.error,
								total = view.total or 0,
							})
						elseif decErr then
							noctalia.log("flexa: view decode error: " .. tostring(decErr))
						end
					elseif readErr then
						noctalia.log("flexa: view read error: " .. tostring(readErr))
					end
				end)
			end
		end
	end)

	if not ok then
		noctalia.notifyError(noctalia.tr("title"), "Failed to start Flexa audio backend.")
		noctalia.state.set("backendError", "spawn_failed")
	end
end

noctalia.state.watch("command", function(cmd)
	if type(cmd) ~= "table" then
		return
	end
	if cmd.action == "rescan" then
		triggerScan()
	else
		sendBackend(cmd)
	end
end)

function onConfigChanged()
	noctalia.state.set("configRev", noctalia.nowMs())
	triggerScan()
end

function onIpc(event: string, payload: string?)
	if event == "play-pause" or event == "toggle" then
		sendBackend({ action = "play-pause" })
	elseif event == "next" then
		sendBackend({ action = "next" })
	elseif event == "prev" then
		sendBackend({ action = "prev" })
	elseif event == "shuffle" then
		sendBackend({ action = "shuffle-toggle" })
	elseif event == "repeat" then
		sendBackend({ action = "repeat-cycle" })
	elseif event == "rescan" then
		triggerScan()
	elseif event == "volume-up" then
		local step = tonumber(payload) or 5
		sendBackend({ action = "volume-delta", delta = math.abs(step) })
	elseif event == "volume-down" then
		local step = tonumber(payload) or 5
		sendBackend({ action = "volume-delta", delta = -math.abs(step) })
	elseif event == "mute" then
		sendBackend({ action = "mute-toggle" })
	elseif event == "toggle-panel" then
		noctalia.togglePanel(PANEL_ID)
	end
end

function onExit(_signal: number, _reason: string)
	backendReady = false
end

startBackend()
