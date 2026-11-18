--!nonstrict

local MANAGED_TITLE = "Noctalia Screen Mirror"

local dataDir = noctalia.pluginDataDir()
local runFile = dataDir and (dataDir .. "/mirror.run") or nil
local errorFile = dataDir and (dataDir .. "/mirror.stderr") or nil
local commandAvailable = noctalia.commandExists("wl-mirror")
local streamActive = false
local stopRequested = false
local stopMessage = nil
local notifyAfterStop = false

local status = {
	phase = "stopped",
	running = false,
	source = nil,
	destination = nil,
	available = commandAvailable and runFile ~= nil and errorFile ~= nil,
	command_available = commandAvailable,
	message = "",
}

local function tr(key, values)
	return noctalia.tr(key, values)
end

local function shellQuote(value)
	return "'" .. string.gsub(tostring(value), "'", "'\\''") .. "'"
end

local function publishStatus(phase, message)
	status.phase = phase
	status.running = phase == "running"
	status.message = message or ""
	status.available = commandAvailable and runFile ~= nil and errorFile ~= nil
	status.command_available = commandAvailable
	noctalia.state.set("mirror_status", status)
end

local function connected(name)
	if name == nil then
		return false
	end

	for _, output in ipairs(noctalia.outputs() or {}) do
		if output.name == name then
			return true
		end
	end

	return false
end

local function readMirrorError(fallback)
	if errorFile == nil then
		return fallback
	end

	local message = noctalia.string.trim(noctalia.readFile(errorFile) or "")
	return message ~= "" and message or fallback
end

local function cleanupControlFiles()
	if runFile ~= nil then
		noctalia.removeFile(runFile)
	end
	if errorFile ~= nil then
		noctalia.removeFile(errorFile)
	end
end

-- runStream owns this shell process group, so Noctalia tears down both the
-- wrapper and wl-mirror when the entry unloads. The marker provides normal
-- start/stop control; the parent check also prevents an orphan after a crash.
local function mirrorCommand(source, destination)
	local launch = "wl-mirror"
		.. " --fullscreen-output "
		.. shellQuote(destination)
		.. " --fullscreen"
		.. " --title "
		.. shellQuote(MANAGED_TITLE)
		.. " "
		.. shellQuote(source)
		.. ' >"$ERR" 2>&1 &'

	return table.concat({
		"RUN=" .. shellQuote(runFile),
		"ERR=" .. shellQuote(errorFile),
		"OWNER=$PPID",
		launch,
		"PID=$!",
		[[trap 'kill -TERM "$PID" 2>/dev/null || true' HUP INT TERM EXIT]],
		"sleep 0.15",
		[[if ! kill -0 "$PID" 2>/dev/null; then wait "$PID"; CODE=$?; printf 'failed:%s\n' "$CODE"; exit 0; fi]],
		[[printf 'started\n']],
		[[while [ -f "$RUN" ] && kill -0 "$OWNER" 2>/dev/null && kill -0 "$PID" 2>/dev/null; do sleep 0.1; done]],
		[[if [ ! -f "$RUN" ] || ! kill -0 "$OWNER" 2>/dev/null; then]],
		[[kill -TERM "$PID" 2>/dev/null || true]],
		[[ATTEMPT=0]],
		[[while kill -0 "$PID" 2>/dev/null && [ "$ATTEMPT" -lt 20 ]; do sleep 0.05; ATTEMPT=$((ATTEMPT + 1)); done]],
		[[kill -KILL "$PID" 2>/dev/null || true]],
		[[wait "$PID" 2>/dev/null || true]],
		[[trap - HUP INT TERM EXIT]],
		[[printf 'stopped\n']],
		[[else]],
		[[wait "$PID"; CODE=$?]],
		[[trap - HUP INT TERM EXIT]],
		[[printf 'exited:%s\n' "$CODE"]],
		[[fi]],
	}, "\n")
end

local function finishStopped()
	local previousSource = status.source
	local previousDestination = status.destination
	local message = stopMessage or tr("service.mirror_stopped")
	local shouldNotify = notifyAfterStop

	streamActive = false
	stopRequested = false
	stopMessage = nil
	notifyAfterStop = false
	cleanupControlFiles()

	status.source = nil
	status.destination = nil
	publishStatus("stopped", message)

	if shouldNotify then
		noctalia.notify(
			tr("title"),
			tr("notification.stopped", {
				source = previousSource or "?",
				destination = previousDestination or "?",
			})
		)
	end
end

local function finishFailed(fallback)
	local message = readMirrorError(fallback)

	streamActive = false
	stopRequested = false
	stopMessage = nil
	notifyAfterStop = false
	cleanupControlFiles()

	status.source = nil
	status.destination = nil
	publishStatus("error", message)
	noctalia.notifyError(tr("title"), message)
end

local function handleMirrorLine(line)
	line = noctalia.string.trim(line or "")

	if line == "started" then
		if not stopRequested then
			publishStatus("running", tr("service.mirror_active"))
			noctalia.notify(
				tr("title"),
				tr("notification.started", {
					source = status.source or "?",
					destination = status.destination or "?",
				})
			)
		end
	elseif line == "stopped" then
		finishStopped()
	elseif string.match(line, "^failed:") ~= nil then
		finishFailed(tr("service.mirror_failed"))
	elseif string.match(line, "^exited:") ~= nil then
		local exitCode = tonumber(string.match(line, "^exited:(%d+)$"))
		local userTerminated = exitCode == 0
			or exitCode == 129 -- SIGHUP
			or exitCode == 130 -- SIGINT
			or exitCode == 131 -- SIGQUIT
			or exitCode == 137 -- SIGKILL
			or exitCode == 143 -- SIGTERM

		if userTerminated then
			finishStopped()
		else
			finishFailed(tr("service.mirror_exited"))
		end
	end
end

local function stopMirror(message, notify)
	if status.phase == "stopping" then
		return
	end

	if not streamActive then
		status.source = nil
		status.destination = nil
		publishStatus("stopped", message or tr("service.mirror_stopped"))
		return
	end

	stopRequested = true
	stopMessage = message or tr("service.mirror_stopped")
	notifyAfterStop = notify == true
	publishStatus("stopping", tr("service.stopping"))

	if runFile == nil or noctalia.removeFile(runFile) ~= true then
		finishFailed(tr("service.data_unavailable"))
	end
end

local function startMirror(source, destination)
	if not commandAvailable then
		local message = tr("service.wl_mirror_missing")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
		return
	end

	if runFile == nil or errorFile == nil then
		local message = tr("service.data_unavailable")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
		return
	end

	if source == nil or destination == nil or source == destination then
		local message = tr("service.invalid_pair")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
		return
	end

	if not connected(source) or not connected(destination) then
		local message = tr("service.monitor_missing")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
		return
	end

	if streamActive or status.phase == "running" or status.phase == "starting" then
		return
	end

	local written, writeError = noctalia.writeFile(runFile, source .. "\n" .. destination .. "\n")
	if not written then
		local message = writeError or tr("service.data_unavailable")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
		return
	end
	noctalia.writeFile(errorFile, "")

	status.source = source
	status.destination = destination
	stopRequested = false
	stopMessage = nil
	notifyAfterStop = false
	publishStatus("starting", tr("service.starting"))

	streamActive = true
	local accepted = noctalia.runStream(mirrorCommand(source, destination), handleMirrorLine)
	if not accepted then
		streamActive = false
		cleanupControlFiles()
		status.source = nil
		status.destination = nil
		local message = tr("service.launch_failed")
		publishStatus("error", message)
		noctalia.notifyError(tr("title"), message)
	end
end

noctalia.state.watch("mirror_request", function(request)
	if type(request) ~= "table" then
		return
	end

	if request.action == "start" then
		startMirror(request.source, request.destination)
	elseif request.action == "stop" then
		stopMirror(tr("service.mirror_stopped"), true)
	end
end)

function onOutputsChanged()
	if
		(status.phase == "running" or status.phase == "starting")
		and (not connected(status.source) or not connected(status.destination))
	then
		stopMirror(tr("service.disconnected"), false)
	end
end

function onExit(_signal)
	if runFile ~= nil then
		noctalia.removeFile(runFile)
	end
end

cleanupControlFiles()
if not commandAvailable then
	publishStatus("error", tr("service.wl_mirror_missing"))
elseif runFile == nil or errorFile == nil then
	publishStatus("error", tr("service.data_unavailable"))
else
	publishStatus("stopped", tr("service.ready"))
end
