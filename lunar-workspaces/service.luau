-- Lunar Workspaces — background service
-- Watches Hyprland or Niri and publishes per-workspace state so the bar
-- widget can render it:
--   { ["1"] = { focused = true, urgent = false, occupied = true,
--                output = "DP-1", windows = { "firefox", "code" } }, ... }
--
-- `focused` means "active on its own monitor", not "the one globally
-- focused workspace across the whole compositor":
--   Hyprland - workspace id == that monitor's activeWorkspace.id
--   Niri     - ws.is_active (niri also exposes ws.is_focused, the single
--              globally-focused workspace across every monitor, which is
--              NOT what we want here)
-- This lets each bar instance (one per monitor) correctly highlight its
-- own active workspace even when a different monitor currently has input
-- focus, instead of only ever lighting up one workspace across the whole
-- multi-monitor setup.

local STATE_KEY = "lunar_workspaces"

local compositorSetting = noctalia.getConfig("compositor") or "auto"
local detectedCompositor = nil -- "hyprland" | "niri" | nil

local loggedError = false
local function logOnce(msg)
	if not loggedError then
		noctalia.log("Lunar Workspaces: " .. msg)
		loggedError = true
	end
end

-- Safely embeds a string as a single-quoted argument in a /bin/sh command
-- line: closes the quote, escapes a literal quote, then reopens it.
local function shellQuote(str)
	return "'" .. string.gsub(str, "'", "'\\''") .. "'"
end

-- Resolves the "compositor" setting to an actual compositor, auto-detecting
-- via env vars and available binaries when set to "auto".
local function detectCompositor()
	if compositorSetting == "hyprland" or compositorSetting == "niri" then
		return compositorSetting
	end
	if noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE") and noctalia.commandExists("hyprctl") then
		return "hyprland"
	end
	if noctalia.getenv("NIRI_SOCKET") and noctalia.commandExists("niri") then
		return "niri"
	end
	if noctalia.commandExists("hyprctl") then
		return "hyprland"
	end
	if noctalia.commandExists("niri") then
		return "niri"
	end
	return nil
end

-- Trims a window title/class down to something short enough for a tooltip
-- line. Backs the cut point off byte-by-byte while it lands mid-way through
-- a multi-byte UTF-8 sequence (a continuation byte, 0x80-0xBF), since titles
-- routinely contain non-ASCII text (accented names, CJK, emoji) and a raw
-- byte cut would otherwise emit an invalid, mangled trailing character.
local MAX_TOOLTIP_LABEL_LEN = 24
local function shortLabel(s)
	if type(s) ~= "string" or s == "" then
		return nil
	end
	if #s <= MAX_TOOLTIP_LABEL_LEN then
		return s
	end
	local cut = MAX_TOOLTIP_LABEL_LEN - 1
	while cut > 0 do
		local b = s:byte(cut + 1)
		if not b or b < 0x80 or b >= 0xC0 then
			break
		end
		cut = cut - 1
	end
	return s:sub(1, cut) .. "…"
end

-- Hyprland

local SEPARATOR = "__LUNAR_WORKSPACES_SEP__"

local hyprRefreshInFlight = false
local hyprRefreshPending = false

-- Parses one hyprctl snapshot (workspaces + activeworkspace + clients +
-- monitors) and publishes normalized workspace state.
local function publishHyprland(workspacesJson, activeJson, clientsJson, monitorsJson)
	local workspaces = noctalia.json.decode(workspacesJson)
	local active = noctalia.json.decode(activeJson)
	local clients = noctalia.json.decode(clientsJson)
	local monitors = noctalia.json.decode(monitorsJson)
	if type(workspaces) ~= "table" then
		logOnce("invalid hyprctl workspaces JSON")
		return
	end

	-- Per-monitor active workspace id, so each monitor's own bar can show
	-- its own active workspace rather than only the single globally active
	-- one. Falls back to the (single, global) activeworkspace id if the
	-- monitors call failed or came back empty for some reason.
	local activeByMonitor = {}
	if type(monitors) == "table" then
		for _, m in ipairs(monitors) do
			if m.name and m.activeWorkspace and m.activeWorkspace.id then
				activeByMonitor[m.name] = m.activeWorkspace.id
			end
		end
	end
	local globalActiveId = active and active.id

	local urgentWs = {}
	local windowsByWs = {}
	if type(clients) == "table" then
		for _, c in ipairs(clients) do
			if c.workspace and c.workspace.id then
				local wsId = c.workspace.id
				if c.urgent then
					urgentWs[wsId] = true
				end
				local label = shortLabel(c.class) or shortLabel(c.title)
				if label then
					windowsByWs[wsId] = windowsByWs[wsId] or {}
					table.insert(windowsByWs[wsId], label)
				end
			end
		end
	end

	local out = {}
	for _, ws in ipairs(workspaces) do
		local monitorActiveId = ws.monitor and activeByMonitor[ws.monitor]
		local focused
		if monitorActiveId ~= nil then
			focused = (ws.id == monitorActiveId)
		else
			focused = (ws.id == globalActiveId)
		end
		out[tostring(ws.id)] = {
			focused = focused,
			urgent = urgentWs[ws.id] == true,
			occupied = (ws.windows or 0) > 0,
			output = ws.monitor,
			windows = windowsByWs[ws.id],
		}
	end
	loggedError = false
	noctalia.state.set(STATE_KEY, out)
end

-- Snapshots hyprctl workspaces/activeworkspace/clients/monitors in one shell
-- round trip and republishes state. Coalesces overlapping calls into one retry.
local function refreshHyprland()
	if hyprRefreshInFlight then
		hyprRefreshPending = true
		return
	end
	hyprRefreshInFlight = true

	local command = "printf '%s\\n"
		.. SEPARATOR
		.. "\\n%s\\n"
		.. SEPARATOR
		.. "\\n%s\\n"
		.. SEPARATOR
		.. "\\n%s\\n' \"$(hyprctl -j workspaces)\" \"$(hyprctl -j activeworkspace)\" \"$(hyprctl -j clients)\" \"$(hyprctl -j monitors)\""

	local started = noctalia.runAsync(command, function(result)
		hyprRefreshInFlight = false
		if result.exitCode == 0 then
			local first, firstEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", 1, true)
			local second, secondEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", firstEnd and (firstEnd + 1) or 1, true)
			local third, thirdEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", secondEnd and (secondEnd + 1) or 1, true)
			if first and second and third then
				local wsJson = string.sub(result.stdout, 1, first - 1)
				local activeJson = string.sub(result.stdout, firstEnd + 1, second - 1)
				local clientsJson = string.sub(result.stdout, secondEnd + 1, third - 1)
				local monitorsJson = string.sub(result.stdout, thirdEnd + 1)
				publishHyprland(wsJson, activeJson, clientsJson, monitorsJson)
			else
				logOnce("incomplete hyprctl snapshot")
			end
		else
			logOnce("hyprctl failed")
		end
		if hyprRefreshPending then
			hyprRefreshPending = false
			refreshHyprland()
		end
	end)

	if not started then
		hyprRefreshInFlight = false
		logOnce("could not start hyprctl snapshot")
	end
end

-- Hyprland IPC events that should trigger a state refresh.
local hyprEvents = {
	workspace = true,
	workspacev2 = true,
	createworkspace = true,
	createworkspacev2 = true,
	destroyworkspace = true,
	destroyworkspacev2 = true,
	moveworkspace = true,
	moveworkspacev2 = true,
	openwindow = true,
	closewindow = true,
	movewindow = true,
	movewindowv2 = true,
	urgent = true,
	focusedmon = true,
	focusedmonv2 = true,
}

-- Tails the Hyprland IPC socket via socat for instant updates. Falls back to
-- poll-only mode (the 60s resync tick) if socat or the socket isn't available.
local function startHyprlandEventStream()
	if not noctalia.commandExists("socat") then
		logOnce("socat unavailable; falling back to poll-only Hyprland updates")
		return
	end
	local runtimeDir = noctalia.getenv("XDG_RUNTIME_DIR")
	local signature = noctalia.getenv("HYPRLAND_INSTANCE_SIGNATURE")
	if not runtimeDir or not signature then
		logOnce("Hyprland environment unavailable; poll-only mode")
		return
	end

	local socket = shellQuote(runtimeDir .. "/hypr/" .. signature .. "/.socket2.sock")
	local command = "while true; do while [ ! -S "
		.. socket
		.. " ]; do sleep 5; done; socat -u UNIX-CONNECT:"
		.. socket
		.. " - 2>&1; sleep 5; done"

	noctalia.runStream(command, function(line)
		local event = string.match(line, "^([%a%d_]+)>>")
		if event and hyprEvents[event] then
			refreshHyprland()
		end
	end)
end

-- Niri

-- Publishes normalized state from a Niri workspace list, optionally
-- enriched with a window list (workspace_id -> short labels) for tooltips.
local function publishNiri(list, windows)
	local windowsByWs = {}
	if type(windows) == "table" then
		for _, w in ipairs(windows) do
			if w.workspace_id then
				local label = shortLabel(w.app_id) or shortLabel(w.title)
				if label then
					windowsByWs[w.workspace_id] = windowsByWs[w.workspace_id] or {}
					table.insert(windowsByWs[w.workspace_id], label)
				end
			end
		end
	end

	-- `idx` is a workspace's position within its OWN output's workspace
	-- list, not a globally unique id - niri restarts idx at 1 on every
	-- monitor, so with more than one output two different workspaces can
	-- legitimately share the same idx. Merge (rather than overwrite) any
	-- entries that land on the same published key, so one monitor's
	-- workspace state can't silently clobber another's.
	local out = {}
	for _, ws in ipairs(list) do
		local idxStr = tostring(ws.idx or ws.id)
		local wsWindows = windowsByWs[ws.id]

		local existing = out[idxStr]
		if not existing then
			out[idxStr] = {
				-- is_active = active on its own monitor (what we want here).
				-- is_focused = the single globally-focused workspace across
				-- every monitor - deliberately NOT used for `focused` below.
				focused = ws.is_active == true,
				urgent = ws.is_urgent == true,
				occupied = ws.active_window_id ~= nil,
				output = ws.output,
				windows = wsWindows,
			}
		else
			existing.focused = existing.focused or (ws.is_active == true)
			existing.urgent = existing.urgent or (ws.is_urgent == true)
			existing.occupied = existing.occupied or (ws.active_window_id ~= nil)
			if ws.is_active then
				existing.output = ws.output -- prefer the currently-active monitor's identity
			end
			if wsWindows then
				existing.windows = existing.windows or {}
				for _, w in ipairs(wsWindows) do
					table.insert(existing.windows, w)
				end
			end
		end
	end
	loggedError = false
	noctalia.state.set(STATE_KEY, out)
end

-- Fetches the current workspace list and window list from niri in one shell
-- round trip and republishes state.
local function refreshNiri()
	local command = "printf '%s\\n"
		.. SEPARATOR
		.. "\\n%s\\n' \"$(niri msg --json workspaces)\" \"$(niri msg --json windows)\""

	noctalia.runAsync(command, function(result)
		if result.exitCode ~= 0 then
			logOnce("niri msg failed")
			return
		end
		local sepAt, sepEnd = string.find(result.stdout, "\n" .. SEPARATOR .. "\n", 1, true)
		if not sepAt then
			logOnce("incomplete niri snapshot")
			return
		end
		local wsJson = string.sub(result.stdout, 1, sepAt - 1)
		local windowsJson = string.sub(result.stdout, sepEnd + 1)
		local data = noctalia.json.decode(wsJson)
		local windows = noctalia.json.decode(windowsJson)
		if type(data) == "table" then
			publishNiri(data, windows)
		end
	end, 3000)
end

-- Tails niri's JSON event stream and re-snapshots on workspace changes.
local function startNiriEventStream()
	noctalia.runStream("niri msg --json event-stream", function(line)
		local ev = noctalia.json.decode(line)
		if type(ev) ~= "table" then
			return
		end
		if ev.WorkspacesChanged ~= nil or ev.WorkspaceActivated ~= nil then
			refreshNiri()
		end
	end)
end

-- Wiring

local function start()
	detectedCompositor = detectCompositor()
	if detectedCompositor == "hyprland" then
		refreshHyprland()
		startHyprlandEventStream()
	elseif detectedCompositor == "niri" then
		refreshNiri()
		startNiriEventStream()
	else
		logOnce("no supported compositor detected (hyprctl/niri not found)")
	end
end

start()

-- Periodic resync as a safety net alongside the live event streams. This
-- also catches window-title changes on niri, since there isn't a dedicated
-- event for those - only workspace/window-open/close events are.
noctalia.setUpdateInterval(60000)

function update()
	if detectedCompositor == "hyprland" then
		refreshHyprland()
	elseif detectedCompositor == "niri" then
		refreshNiri()
	else
		start() -- retry detection in case the compositor started after us
	end
end

function onConfigChanged()
	compositorSetting = noctalia.getConfig("compositor") or "auto"
	start()
end

function onOutputsChanged()
	if detectedCompositor == "hyprland" then
		refreshHyprland()
	elseif detectedCompositor == "niri" then
		refreshNiri()
	end
end
