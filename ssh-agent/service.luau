--!nonstrict
-- Headless [[service]] entry. Owns everything Main.qml used to own: the
-- ssh-agent process, ssh-add calls, and the sessions file. Runs for the
-- whole session. Other entries (widget.luau, panel.luau) never call these
-- functions directly — Luau VMs are isolated per entry — they instead:
--   * read published data via noctalia.state.watch("status", ...)
--   * request actions by writing noctalia.state.set("command", {...})
--   * or drive it externally via: noctalia msg plugin martasskv5/ssh-agent:agent <target> <event>

local agentRunning = false
local loadingKeys = false
local loadedKeys = {}
local sessions = {}
local sshVersion = "Loading..."
local isStartupPhase = true

local function trimmed(s)
	return (tostring(s or ""):match("^%s*(.-)%s*$"))
end

local function shellQuote(text)
	return "'" .. tostring(text or ""):gsub("'", "'\\''") .. "'"
end

-- ── Settings (shared across all of this plugin's entries via getConfig) ────

local function defaultSocketPath()
	return "/tmp/ssh-agent-" .. (noctalia.getenv("USER") or "default") .. ".sock"
end

local function agentSocketPath()
	local v = trimmed(noctalia.getConfig("socket_path"))
	if v == "" then
		return defaultSocketPath()
	end
	return v
end

local function sessionsFilePath()
	local v = trimmed(noctalia.getConfig("sessions_file"))
	if v == "" then
		return "~/.ssh/sessions.json"
	end
	return v
end

local function terminalCommand()
	return trimmed(noctalia.getConfig("terminal_command"))
end

local function showNotifications()
	local v = noctalia.getConfig("show_notifications")
	if v == nil then
		return true
	end
	return v == true
end

local function autoStartMode()
	local v = trimmed(noctalia.getConfig("auto_start_mode"))
	if v == "" then
		return "connect_existing"
	end
	return v
end

local function notifyInfo(title, msg)
	if showNotifications() then
		noctalia.notify(title, msg or "")
	end
end

local function notifyError(title, msg)
	noctalia.notifyError(title, msg or "")
end

-- ── Publish state for widget.luau / panel.luau ─────────────────────────────

local function publishStatus()
	noctalia.state.set("status", {
		agent_running = agentRunning,
		loading_keys = loadingKeys,
		loaded_keys = loadedKeys,
		sessions = sessions,
		ssh_version = sshVersion,
	})
end

-- ── ssh-agent lifecycle ─────────────────────────────────────────────────────

local function extractVersionLine(output)
	for line in tostring(output or ""):gmatch("[^\r\n]+") do
		local l = trimmed(line)
		if l ~= "" then
			local lower = l:lower()
			if lower:sub(1, 6) ~= "usage:" and not lower:find("^unknown option") and not lower:find("^option requires an argument") then
				return l
			end
		end
	end
	return "Unknown"
end

local function getSshVersion()
	noctalia.runAsync(
		"if command -v ssh >/dev/null 2>&1; then ssh -V 2>&1; else echo 'Not installed'; fi",
		function(res)
			sshVersion = extractVersionLine(res.stdout ~= "" and res.stdout or res.stderr)
			publishStatus()
		end,
		5000
	)
end

local function checkAgentRunning(onDone)
	noctalia.runAsync("test -S " .. shellQuote(agentSocketPath()), function(res)
		agentRunning = res.exitCode == 0
		publishStatus()
		if onDone then
			onDone()
		end
	end, 5000)
end

local function parseLoadedKeys(text, exitCode)
	text = tostring(text or "")
	if exitCode ~= 0 then
		if text:find("The agent has no identities") or text:find("The agent has no keys") then
			loadedKeys = {}
		else
			loadedKeys = {}
			if not isStartupPhase and trimmed(text) ~= "" then
				notifyError("SSH Agent", trimmed(text))
			end
		end
		return
	end

	local keys = {}
	for line in text:gmatch("[^\r\n]+") do
		local l = trimmed(line)
		if l ~= "" then
			local bits, fingerprint, rest = l:match("^(%d+)%s+(%S+)%s+(.*)$")
			if bits then
				local name, ktype = rest:match("^(.-)%s+%(([^%)]+)%)$")
				if not name then
					name = rest
					ktype = ""
				end
				table.insert(keys, { bits = bits, fingerprint = fingerprint, name = name, type = ktype })
			end
		end
	end
	loadedKeys = keys
end

local function refreshLoadedKeys()
	loadingKeys = true
	publishStatus()
	local cmd = "SSH_AUTH_SOCK=" .. shellQuote(agentSocketPath()) .. " ssh-add -l 2>&1"
	noctalia.runAsync(cmd, function(res)
		loadingKeys = false
		parseLoadedKeys(res.stdout, res.exitCode)
		publishStatus()
	end, 8000)
end

local function refreshState()
	checkAgentRunning()
	refreshLoadedKeys()
end

local function startAgent(killPrevious)
	local sock = agentSocketPath()
	local dir = sock:match("^(.*)/[^/]*$") or "/tmp"
	local script = ""
	if killPrevious then
		script = script .. "pkill -f " .. shellQuote("ssh-agent -a " .. sock) .. " 2>/dev/null || true\n"
	end
	script = script .. "mkdir -p " .. shellQuote(dir) .. "\n"
	script = script .. "ssh-agent -a " .. shellQuote(sock) .. " >/dev/null"

	noctalia.runAsync(script, function(res)
		if res.exitCode == 0 then
			if not isStartupPhase then
				notifyInfo("SSH Agent", "Agent started")
			end
		elseif not isStartupPhase then
			local msg = trimmed(res.stderr ~= "" and res.stderr or res.stdout)
			if msg ~= "" then
				notifyError("SSH Agent", msg)
			end
		end
		refreshState()
	end, 8000)
end

local function stopAgent()
	local sock = agentSocketPath()
	noctalia.runAsync("pkill -f " .. shellQuote("ssh-agent -a " .. sock), function(res)
		if res.exitCode == 0 and not isStartupPhase then
			notifyInfo("SSH Agent", "Agent stopped")
		end
		refreshState()
	end, 5000)
end

-- ── Keys ─────────────────────────────────────────────────────────────────

local function addKey(keyPath)
	local path = noctalia.expandPath(trimmed(keyPath))
	if path == "" then
		return
	end
	local script = table.concat({
		"ASKPASS=${SSH_ASKPASS:-}",
		"if [ -z \"$ASKPASS\" ] || [ ! -x \"$ASKPASS\" ]; then",
		"  for p in /usr/bin/ksshaskpass /usr/bin/ssh-askpass /usr/lib/ssh/ssh-askpass /usr/bin/lxqt-openssh-askpass; do",
		"    if [ -x \"$p\" ]; then ASKPASS=\"$p\"; break; fi",
		"  done",
		"fi",
		"if [ -n \"$ASKPASS\" ]; then",
		"  export SSH_ASKPASS=\"$ASKPASS\"",
		"  export SSH_ASKPASS_REQUIRE=prefer",
		"fi",
		"SSH_AUTH_SOCK=" .. shellQuote(agentSocketPath()) .. " ssh-add " .. shellQuote(path) .. " 2>&1",
	}, "\n")

	-- Long timeout: an askpass GUI prompt can sit open for a while.
	noctalia.runAsync(script, function(res)
		if res.exitCode == 0 then
			notifyInfo("SSH Key Added", path)
		else
			local msg = trimmed(res.stderr ~= "" and res.stderr or res.stdout)
			notifyError("Failed to Add Key", msg ~= "" and msg or path)
		end
		refreshLoadedKeys()
	end, 60000)
end

local function removeKey(keyName)
	if not keyName or keyName == "" then
		return
	end
	local cmd = "SSH_AUTH_SOCK=" .. shellQuote(agentSocketPath()) .. " ssh-add -d " .. shellQuote(keyName) .. " 2>&1"
	noctalia.runAsync(cmd, function(res)
		if res.exitCode == 0 then
			notifyInfo("SSH Key Unloaded", keyName)
		else
			local msg = trimmed(res.stderr ~= "" and res.stderr or res.stdout)
			notifyError("Failed to Unload Key", msg ~= "" and msg or keyName)
		end
		refreshLoadedKeys()
	end, 8000)
end

local function removeAllKeys()
	local cmd = "SSH_AUTH_SOCK=" .. shellQuote(agentSocketPath()) .. " ssh-add -D 2>&1"
	noctalia.runAsync(cmd, function(res)
		if res.exitCode == 0 then
			notifyInfo("SSH Agent", "All keys removed")
		else
			notifyError("Failed to Remove Keys", trimmed(res.stderr ~= "" and res.stderr or res.stdout))
		end
		refreshLoadedKeys()
	end, 8000)
end

-- ── Sessions ─────────────────────────────────────────────────────────────

local function launchSession(session)
	if not session or trimmed(session.host or "") == "" then
		return
	end
	local user = trimmed(session.user or "")
	local host = trimmed(session.host or "")
	local destination = user ~= "" and (user .. "@" .. host) or host
	local port = trimmed(tostring(session.port or "22"))
	if port == "" then
		port = "22"
	end
	local keyPath = noctalia.expandPath(trimmed(session.key_path or ""))
	local extraArgs = trimmed(session.extra_args or "")

	local sshCmd = "ssh -p " .. shellQuote(port)
	if keyPath ~= "" then
		sshCmd = sshCmd .. " -i " .. shellQuote(keyPath)
	end
	if extraArgs ~= "" then
		sshCmd = sshCmd .. " " .. extraArgs
	end
	sshCmd = sshCmd .. " " .. shellQuote(destination)

	local wrapped = "SSH_AUTH_SOCK=" .. shellQuote(agentSocketPath()) .. " " .. sshCmd
	local term = terminalCommand()

	if term ~= "" then
		noctalia.runAsync(term .. " -e sh -lc " .. shellQuote(wrapped))
	elseif not noctalia.runInTerminal(wrapped) then
		notifyError("Launch Failed", "No terminal available to launch the session")
	end
end

local function normalizeSession(raw)
	local port = trimmed(tostring((raw and raw.port) or "22"))
	if port == "" then
		port = "22"
	end
	return {
		name = trimmed(raw and raw.name),
		host = trimmed(raw and raw.host),
		user = trimmed(raw and raw.user),
		port = port,
		key_path = trimmed(raw and raw.key_path),
		extra_args = trimmed(raw and raw.extra_args),
	}
end

local function writeSessions()
	local path = sessionsFilePath()
	local encoded = noctalia.json.encode(sessions, true)
	local expanded = noctalia.expandPath(path)
	local dir = expanded:match("^(.*)/[^/]*$")
	if dir and dir ~= "" then
		noctalia.mkdirAll(dir)
	end
	local ok, err = noctalia.writeFile(path, (encoded or "[]") .. "\n")
	if not ok then
		notifyError("Saved Sessions", err or "Failed to save sessions")
	end
end

local function upsertSession(raw)
	local session = normalizeSession(raw)
	if session.name == "" or session.host == "" then
		notifyError("Saved Sessions", "Session name and host are required")
		return
	end

	local updated = {}
	local replaced = false
	for _, s in ipairs(sessions) do
		if s.name == session.name then
			table.insert(updated, session)
			replaced = true
		else
			table.insert(updated, s)
		end
	end
	if not replaced then
		table.insert(updated, session)
	end

	sessions = updated
	writeSessions()
	notifyInfo("Saved Sessions", "Stored '" .. session.name .. "'")
	publishStatus()
end

local function deleteSession(name)
	local n = trimmed(name)
	if n == "" then
		return
	end
	local updated = {}
	for _, s in ipairs(sessions) do
		if s.name ~= n then
			table.insert(updated, s)
		end
	end
	sessions = updated
	writeSessions()
	notifyInfo("Saved Sessions", "Deleted '" .. n .. "'")
	publishStatus()
end

local function loadSessionsFromDisk()
	local path = sessionsFilePath()
	local contents = noctalia.readFile(path)
	if not contents or trimmed(contents) == "" then
		sessions = {}
		publishStatus()
		return
	end

	local decoded, err = noctalia.json.decode(trimmed(contents))
	if err or decoded == nil then
		sessions = {}
		if not isStartupPhase then
			notifyError("Saved Sessions", "Invalid JSON in sessions file")
		end
		publishStatus()
		return
	end

	if decoded.entries then
		sessions = decoded.entries
	else
		sessions = decoded
	end
	publishStatus()
end

-- ── Cross-entry command channel ─────────────────────────────────────────────
-- widget.luau / panel.luau write here; each write includes a fresh `ts` so
-- repeat commands (e.g. clicking "refresh" twice) still trigger the watcher.

noctalia.state.watch("command", function(cmd)
	if type(cmd) ~= "table" or not cmd.action then
		return
	end
	local action = cmd.action
	if action == "refresh" then
		refreshState()
	elseif action == "start-agent" then
		startAgent(cmd.kill == true)
	elseif action == "stop-agent" then
		stopAgent()
	elseif action == "add-key" then
		addKey(cmd.path)
	elseif action == "remove-key" then
		removeKey(cmd.name)
	elseif action == "remove-all-keys" then
		removeAllKeys()
	elseif action == "launch-session" then
		launchSession(cmd.session)
	elseif action == "upsert-session" then
		upsertSession(cmd.session)
	elseif action == "delete-session" then
		deleteSession(cmd.name)
	end
end)

-- ── External IPC ─────────────────────────────────────────────────────────

function onIpc(event, _payload)
	if event == "refresh" then
		refreshState()
	elseif event == "start-agent" then
		startAgent(false)
	elseif event == "stop-agent" then
		stopAgent()
	end
end

-- Plugin-level settings changed (e.g. socket path edited in Settings).
function onConfigChanged()
	refreshState()
	loadSessionsFromDisk()
end

-- ── Startup ──────────────────────────────────────────────────────────────
-- Runs once when the service loads. There's no QML Timer here, so a short
-- update() tick stands in for the old 500ms one-shot startup delay; after
-- that the service settles into a slow background sync.

refreshState()
getSshVersion()
loadSessionsFromDisk()

local ticks = 0
noctalia.setUpdateInterval(500)

function update()
	ticks += 1
	if ticks == 1 then
		local mode = autoStartMode()
		if mode == "create_new" then
			startAgent(true)
		elseif mode == "connect_existing" and not agentRunning then
			startAgent(false)
		end
		isStartupPhase = false
		noctalia.setUpdateInterval(60000) -- background sync every minute thereafter
	else
		refreshState()
	end
end
